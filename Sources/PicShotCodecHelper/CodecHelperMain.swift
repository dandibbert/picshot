import Foundation
import Darwin
import PicShotCodecCore

@main
enum PicShotCodecHelper {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == [ImageDecodeDiagnosticLimits.argument] { exit(ImageDecodeDiagnostic.run()) }
        exit(run(arguments: arguments))
    }

    /// The parent starts one signed, bundle-relative helper per request. No
    /// NSApplication, capture controller, model, network or login is initialized.
    static func run(arguments: [String]) -> Int32 {
        _ = signal(SIGPIPE, SIG_IGN); _ = umask(0o077)
        // A hard wall backstop can stop an uncooperative native call, notably
        // libavif's completed-buffer API. It is independent of the run loop.
        DispatchQueue(label: "PicShot.CodecHelper.deadline").asyncAfter(deadline: .now() + CodecExportLimits.wallSeconds + 3) {
            Darwin._exit(70)
        }
        let cpuSeconds = rlim_t(Int(CodecExportLimits.wallSeconds) * max(1, ProcessInfo.processInfo.activeProcessorCount))
        var cpu = rlimit(rlim_cur: cpuSeconds, rlim_max: cpuSeconds + 5)
        _ = setrlimit(RLIMIT_CPU, &cpu)
        var fileSize = rlimit(rlim_cur: rlim_t(CodecExportLimits.stillOutputBytes), rlim_max: rlim_t(CodecExportLimits.stillOutputBytes))
        _ = setrlimit(RLIMIT_FSIZE, &fileSize)
        let writer = CodecResponseWriter()
        let state = CodecHelperRunState()
        var files: CodecJobFiles?
        do {
            try validateArguments(arguments)
            try makeNonblocking(STDIN_FILENO); try makeNonblocking(STDOUT_FILENO)
            let parent = getppid()
            guard parent > 1 else { throw CodecExportFailure(.cancelled) }
            let started = ProcessInfo.processInfo.systemUptime
            var nextSample = started
            var decoder = CodecExportInputDecoder(), stdinOpen = true
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while !state.isComplete {
                let now = ProcessInfo.processInfo.systemUptime
                if now - started >= CodecExportLimits.wallSeconds { state.cancel(.deadline) }
                if getppid() != parent || (kill(parent, 0) != 0 && errno == ESRCH) {
                    state.markParentLost(); state.cancel(.cancelled)
                }
                if now >= nextSample {
                    let reading = CodecMemoryReading.current()
                    writer.record(reading)
                    if (reading.residentBytes ?? 0) > CodecExportLimits.residentBytes ||
                        (reading.physicalFootprintBytes ?? 0) > CodecExportLimits.residentBytes { state.cancel(.memoryLimit) }
                    nextSample = now + CodecExportLimits.sampleIntervalSeconds
                }
                if stdinOpen, !state.isCancelled {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if count > 0 {
                        do {
                            for message in try decoder.consume(Data(buffer.prefix(count))) {
                                switch message {
                                case .request(let request):
                                    let job = try CodecJobFiles.validate(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true), request: request)
                                    files = job
                                    let task = Task.detached(priority: .utility) {
                                        await export(request, files: job, writer: writer, state: state)
                                    }
                                    state.install(task)
                                case .cancel: state.cancel(.cancelled)
                                }
                            }
                        } catch { state.cancel((error as? CodecExportFailure)?.code ?? .protocolViolation) }
                    } else if count == 0 {
                        stdinOpen = false; state.markParentLost()
                        do {
                            try decoder.finish()
                            // Even a complete request requires the parent's
                            // control pipe to remain open until child exit.
                            state.cancel(.cancelled)
                        } catch { state.cancel(.protocolViolation) }
                    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { state.cancel(.protocolViolation) }
                }
                if state.isCancelled, !state.hasTask { state.complete(.init(kind: .error, errorCode: state.cancellationCode)) }
                if let cancelledAt = state.cancelledAt, now - cancelledAt >= CodecExportLimits.cancellationGraceSeconds {
                    try? writer.finish(.init(kind: .error, errorCode: state.cancellationCode))
                    if state.parentWasLost { files?.cleanupAfterParentLoss() }
                    // Returning while AVIF still writes would permit racing
                    // teardown. Terminate this disposable process immediately.
                    Darwin._exit(70)
                }
                if !state.isComplete {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                    if !state.isComplete { Thread.sleep(forTimeInterval: 0.002) }
                }
            }
            if getppid() != parent { state.markParentLost() }
            var response = state.response
            // Drain the bounded control tail before publishing success. A very
            // fast encode must not outrun an already queued cancel or EOF.
            if stdinOpen {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 {
                    state.markParentLost(); response = .init(kind: .error, errorCode: .cancelled)
                } else if count > 0 {
                    do {
                        let messages = try decoder.consume(Data(buffer.prefix(count)))
                        guard !messages.isEmpty else { throw CodecExportFailure(.protocolViolation) }
                        for message in messages {
                            guard case .cancel = message else { throw CodecExportFailure(.protocolViolation) }
                        }
                        try decoder.finish()
                        response = .init(kind: .error, errorCode: .cancelled)
                    } catch { response = .init(kind: .error, errorCode: .protocolViolation) }
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    response = .init(kind: .error, errorCode: .protocolViolation)
                }
            }
            try writer.finish(response)
            if state.parentWasLost { files?.cleanupAfterParentLoss() }
            return response.kind == .result ? 0 : 1
        } catch {
            try? writer.finish(.init(kind: .error, errorCode: (error as? CodecExportFailure)?.code ?? .failed))
            if state.parentWasLost { files?.cleanupAfterParentLoss() }
            return 64
        }
    }
    static func validateArguments(_ arguments: [String]) throws {
        guard arguments.isEmpty else { throw CodecExportFailure(.protocolViolation) }
    }
    private static func makeNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CodecExportFailure(.protocolViolation) }
    }
    private static func export(_ request: CodecExportRequest, files: CodecJobFiles,
                               writer: CodecResponseWriter, state: CodecHelperRunState) async {
        do {
            try Task.checkCancellation()
            try writer.progress(0)
            let width: Int, height: Int, frames: Int, duration: Double
            let cancelled = { state.isCancelled || Task.isCancelled }
            if request.kind == .still {
                let dimensions = try CodecStillEncoder.encode(files: files, request: request, isCancelled: cancelled,
                    progress: { try writer.progress($0) })
                width = dimensions.width; height = dimensions.height; frames = 1; duration = 0
            } else {
                let result = try await AnimatedWebPEncoder.encode(files: files, request: request, isCancelled: cancelled,
                    progress: { try writer.progress(0.05 + 0.8 * $0) })
                width = result.width; height = result.height; frames = result.frameCount; duration = result.duration
            }
            try Task.checkCancellation()
            try writer.progress(0.9)
            let verified = try CodecEncodedPreview.verifyAndWrite(files: files, request: request, width: width, height: height,
                frames: frames, duration: duration, isCancelled: cancelled)
            try files.validateSourceIdentity()
            guard !cancelled() else { throw CodecExportFailure(.cancelled) }
            let result = CodecExportResponse(kind: .result, format: request.format, outputBytes: try files.validateOutput(),
                width: width, height: height, frameCount: frames, duration: duration, previewBytes: verified.previewBytes, sha256: verified.sha256)
            try result.validate(for: request)
            try writer.progress(1)
            state.complete(result)
        } catch {
            let code = state.isCancelled ? state.cancellationCode : (error is CancellationError ? .cancelled : (error as? CodecExportFailure)?.code ?? .failed)
            state.complete(.init(kind: .error, errorCode: code))
        }
    }
}

final class CodecHelperRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var terminal: CodecExportResponse?
    private var cancellation: CodecExportErrorCode?
    private var cancellationTime: TimeInterval?
    private var lostParent = false
    var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return terminal != nil }
    var hasTask: Bool { lock.lock(); defer { lock.unlock() }; return task != nil }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancellation != nil }
    var cancelledAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return cancellationTime }
    var parentWasLost: Bool { lock.lock(); defer { lock.unlock() }; return lostParent }
    var cancellationCode: CodecExportErrorCode { lock.lock(); defer { lock.unlock() }; return cancellation ?? .cancelled }
    var response: CodecExportResponse {
        lock.lock(); defer { lock.unlock() }
        return terminal ?? .init(kind: .error, errorCode: cancellation ?? .failed)
    }
    func markParentLost() { lock.lock(); lostParent = true; lock.unlock() }
    func install(_ task: Task<Void, Never>) {
        lock.lock(); self.task = task; let stop = cancellation != nil; lock.unlock()
        if stop { task.cancel() }
    }
    func cancel(_ code: CodecExportErrorCode) {
        lock.lock()
        if cancellation == nil, terminal == nil { cancellation = code; cancellationTime = ProcessInfo.processInfo.systemUptime }
        let active = task; lock.unlock(); active?.cancel()
    }
    func complete(_ response: CodecExportResponse) {
        lock.lock(); defer { lock.unlock() }
        guard terminal == nil else { return }
        terminal = cancellation.map { .init(kind: .error, errorCode: $0) } ?? response
    }
}
