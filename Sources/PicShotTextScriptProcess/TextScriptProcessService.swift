import Darwin
import Foundation
import Security
import PicShotTextScriptCore

public enum TextScriptProcessOutcome: String, Codable, Sendable {
    case succeeded, helperRejected, busy, cancelled, invalidRequest, signature
    case launchFailed, invalidProtocol, timedOut, memoryLimit, monitorFailed
    case abnormalExit, exitUnconfirmed, pipesUnconfirmed
}

/// Receipts contain identity, counts, timing, and fixed codes only. Never source,
/// recognized text, returned text, stderr, exception strings, or source hashes.
public struct TextScriptProcessMetrics: Codable, Sendable {
    public var requestID: UUID
    public var outcome: TextScriptProcessOutcome = .invalidRequest
    public var childLaunched = false
    public var childPID: Int32?
    public var childExitConfirmed = false
    public var pipesDrained = false
    public var admissionReleased = false
    public var terminationStatus: Int32?
    public var terminationReason: String?
    public var terminateSent = false
    public var killSent = false
    public var elapsedSeconds = 0.0
    public var launchSeconds: Double?
    public var requestSentSeconds: Double?
    public var exitObservedSeconds: Double?
    public var cleanupSeconds: Double?
    public var acceptedSeconds: Double?
    public var sampledPeakResidentBytes: UInt64?
    public var residentSamples = 0
    public var residentObservationFailures = 0
    public var maximumResidentSampleGapSeconds = 0.0
    public var stdinBytes = 0
    public var stdoutBytes = 0
    public var stderrBytes = 0
    public var discardedResponseBytes = 0
    public var retainedResponseBytesAfterFinish = 0
    public var responseIdentityMatched = false
    public var pipeDescriptorsCloseOnExec = false
    public var parentEndpointsNonblocking = false
    public var inputSuppressesSIGPIPE = false
    public var signature: TextScriptSignatureReceipt?
    public let acceptanceDeadlineSeconds = 3.0
    public let rssLimitBytes: UInt64 = 256 * 1_024 * 1_024
    public let rssSampleIntervalSeconds = 0.05
    public let terminateGraceSeconds = 0.25
    public let killedObservationSeconds = 0.75
    public let observationScope = "parent-polled child RSS; sampled maximum, not a hard allocation cap"
}

public struct TextScriptSignatureReceipt: Codable, Sendable {
    public let appIdentifier: String
    public let helperIdentifier: String
    public let helperCDHash: String
    public let helperEntitlements: [String]
    public let appAndHelperStrictlyValidated: Bool
}

public struct TextScriptProcessResult: Sendable {
    public let response: TextScriptResponse?
    public let metrics: TextScriptProcessMetrics
}

public struct TextScriptProcessSnapshot: Sendable {
    public let occupied: Bool
    public let metrics: TextScriptProcessMetrics?
}

/// An explicit gate-only seam. It cannot be selected by JavaScript, environment,
/// request fields, or a failed production launch. Production always resolves its
/// own signed app's fixed helper path.
#if TEXT_SCRIPT_GATE
public struct TextScriptNativeGateOptions: Sendable {
    public var transportMode: String?
    public var failResidentObservation = false
    public var hideExitObservation = false
    public var killAfterRequest = false
    public var withholdRequest = false
    public var onRequestSent: (@Sendable () -> Void)?
    public init() {}
}
#endif

public final class TextScriptProcessService: @unchecked Sendable {
    public static let shared = TextScriptProcessService()
    private let bundleURL: URL
    #if TEXT_SCRIPT_GATE
    private let gate: TextScriptNativeGateOptions
    public init(bundleURL: URL, gate: TextScriptNativeGateOptions) {
        self.bundleURL = bundleURL; self.gate = gate
    }
    #endif
    public init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
        #if TEXT_SCRIPT_GATE
        self.gate = TextScriptNativeGateOptions()
        #endif
    }

    public func execute(_ request: TextScriptRequest) async -> TextScriptProcessResult {
        let job = TextScriptOwnedJob(requestID: request.requestID)
        guard TextScriptAdmission.shared.acquire(job) else {
            job.metrics.outcome = .busy
            return TextScriptProcessResult(response: nil, metrics: job.metrics)
        }
        if Task.isCancelled { job.cancel() }
        var result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                self.supervise(request, job: job)
            }.value
        } onCancel: { job.cancel() }
        if job.isCancelled, result.metrics.outcome == .succeeded || result.metrics.outcome == .helperRejected {
            job.metrics.outcome = .cancelled; job.metrics.acceptedSeconds = nil
            result = TextScriptProcessResult(response: nil, metrics: job.metrics)
        }
        let released = TextScriptAdmission.shared.finish(job)
        var metrics = result.metrics
        metrics.admissionReleased = released
        return TextScriptProcessResult(response: result.response, metrics: metrics)
    }

    public static func snapshot() -> TextScriptProcessSnapshot {
        TextScriptAdmission.shared.snapshot()
    }

    #if TEXT_SCRIPT_GATE
    public static func restoreNativeGateObservation() { TextScriptAdmission.shared.restoreObservation() }
    public static func verifiedHelperForNativeGate(bundleURL: URL) throws -> (URL, TextScriptSignatureReceipt) {
        try TextScriptExecutable.verify(bundle: bundleURL, filename: "PicShotTextScriptHelper", identifier: "com.picshot.TextScriptHelper")
    }
    #endif

    private func supervise(_ request: TextScriptRequest, job: TextScriptOwnedJob) -> TextScriptProcessResult {
        let started = ProcessInfo.processInfo.systemUptime
        #if TEXT_SCRIPT_GATE
        job.observationWithheld = gate.hideExitObservation
        #endif
        var response: TextScriptResponse?
        var failure: TextScriptProcessOutcome?
        var stoppingAt: Double?
        var nextSample = started
        var lastSample: Double?
        var stdinOffset = 0
        let inputData: Data
        do { inputData = try TextScriptProtocol.encodeRequest(request) }
        catch { return finish(.invalidRequest) }
        if job.isCancelled { return finish(.cancelled) }
        let executable: URL
        do {
            var filename = "PicShotTextScriptHelper", identifier = "com.picshot.TextScriptHelper"
            #if TEXT_SCRIPT_GATE
            if gate.transportMode != nil {
                filename = "PicShotTextScriptTransportFixture"
                identifier = "com.picshot.TextScriptTransportFixture"
            }
            #endif
            let checked = try TextScriptExecutable.verify(bundle: bundleURL, filename: filename, identifier: identifier)
            executable = checked.0; job.metrics.signature = checked.1
        } catch { return finish(.signature) }
        if job.isCancelled { return finish(.cancelled) }
        if ProcessInfo.processInfo.systemUptime - started >= 3 { return finish(.timedOut) }

        let input = Pipe(), output = Pipe(), errors = Pipe()
        let pipes = TextScriptPipes(input: input, output: output, errors: errors)
        job.pipes = pipes
        guard pipes.configure() else { pipes.closeAll(); return finish(.invalidProtocol) }
        job.metrics.pipeDescriptorsCloseOnExec = true
        job.metrics.parentEndpointsNonblocking = true
        job.metrics.inputSuppressesSIGPIPE = true
        let process = Process()
        process.executableURL = executable
        process.arguments = []
        #if TEXT_SCRIPT_GATE
        if let mode = gate.transportMode { process.arguments = [mode] }
        #endif
        // Do not inherit DYLD variables, credentials, arbitrary helper selectors,
        // HOME overrides, or request content in arguments/environment/files.
        process.environment = ["LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        do { try process.run() }
        catch { pipes.closeAll(); return finish(.launchFailed) }
        job.process = process
        job.metrics.childLaunched = true; job.metrics.childPID = process.processIdentifier
        job.metrics.launchSeconds = ProcessInfo.processInfo.systemUptime - started
        pipes.closeChildEnds()
        var killedByFixture = false

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            pipes.drain()
            job.metrics.stdoutBytes = pipes.stdoutCount; job.metrics.stderrBytes = pipes.stderrCount
            if pipes.failed, failure == nil { failure = .invalidProtocol }
            if job.isCancelled { failure = .cancelled }
            if failure == nil, now - started >= 3 { failure = .timedOut }

            var exitVisible = !process.isRunning
            #if TEXT_SCRIPT_GATE
            if gate.hideExitObservation { exitVisible = false }
            #endif
            if exitVisible {
                job.recordExit(started: started)
            } else if failure == nil, now >= nextSample {
                var reading = Self.residentBytes(pid: process.processIdentifier)
                #if TEXT_SCRIPT_GATE
                if gate.failResidentObservation { reading = nil }
                #endif
                if let reading, reading > 0 {
                    job.metrics.sampledPeakResidentBytes = max(job.metrics.sampledPeakResidentBytes ?? reading, reading)
                    job.metrics.residentSamples += 1
                    if let lastSample {
                        job.metrics.maximumResidentSampleGapSeconds = max(job.metrics.maximumResidentSampleGapSeconds, now - lastSample)
                    }
                    lastSample = now
                    if reading > 256 * 1_024 * 1_024 { failure = .memoryLimit }
                } else {
                    // An exit racing proc_pidinfo is not a zero-memory sample.
                    // Require at least one earlier successful observation; fail
                    // closed when still running or observations were absent.
                    var hasExited = !process.isRunning
                    #if TEXT_SCRIPT_GATE
                    if gate.hideExitObservation || gate.failResidentObservation { hasExited = false }
                    #endif
                    if hasExited { job.recordExit(started: started) }
                    else { job.metrics.residentObservationFailures += 1; failure = .monitorFailed }
                }
                nextSample = now + 0.05
            }

            if failure == nil, !job.metrics.childExitConfirmed, !pipes.inputClosed {
                var withhold = false
                #if TEXT_SCRIPT_GATE
                withhold = gate.withholdRequest
                #endif
                if !withhold {
                    if !pipes.write(inputData, offset: &stdinOffset) { failure = .invalidProtocol }
                    job.metrics.stdinBytes = stdinOffset
                    if stdinOffset == inputData.count {
                        pipes.closeInput(); job.metrics.requestSentSeconds = now - started
                        #if TEXT_SCRIPT_GATE
                        gate.onRequestSent?()
                        #endif
                    }
                }
            }
            #if TEXT_SCRIPT_GATE
            if gate.killAfterRequest, pipes.inputClosed, !killedByFixture, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL); killedByFixture = true
            }
            #endif
            if let failure {
                if stoppingAt == nil {
                    stoppingAt = now; pipes.closeInput()
                    if process.isRunning { process.terminate(); job.metrics.terminateSent = true }
                }
                if now - stoppingAt! >= 0.25, !job.metrics.killSent, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL); job.metrics.killSent = true
                }
                if job.metrics.childExitConfirmed, pipes.drained { return finish(failure) }
                if now - stoppingAt! >= 1.0 {
                    // Preserve process and read endpoints in the global lease.
                    // No new child is admitted until later genuine observation
                    // confirms owned exit AND both EOFs. Failure is never success.
                    if !job.metrics.childExitConfirmed { return finish(.exitUnconfirmed) }
                    return finish(.pipesUnconfirmed)
                }
            } else if job.metrics.childExitConfirmed, pipes.drained {
                guard job.metrics.residentSamples > 0 else { return finish(.monitorFailed) }
                guard process.terminationReason == .exit, process.terminationStatus == 0 else { return finish(.abnormalExit) }
                guard ProcessInfo.processInfo.systemUptime - started < 3 else { return finish(.timedOut) }
                if job.isCancelled { return finish(.cancelled) }
                do {
                    response = try TextScriptProtocol.decodeResponse(pipes.stdout, for: request)
                    job.metrics.responseIdentityMatched = response?.requestID == request.requestID
                } catch { return finish(.invalidProtocol) }
                guard ProcessInfo.processInfo.systemUptime - started < 3 else { response = nil; return finish(.timedOut) }
                if job.isCancelled { response = nil; return finish(.cancelled) }
                job.metrics.acceptedSeconds = ProcessInfo.processInfo.systemUptime - started
                return finish(response?.status == .success ? .succeeded : .helperRejected)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }

        func finish(_ outcome: TextScriptProcessOutcome) -> TextScriptProcessResult {
            job.metrics.outcome = outcome
            job.metrics.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
            if let stoppingAt { job.metrics.cleanupSeconds = ProcessInfo.processInfo.systemUptime - stoppingAt }
            job.metrics.pipesDrained = job.pipes?.drained ?? true
            if let pipes = job.pipes {
                job.metrics.discardedResponseBytes = pipes.stdout.count
                pipes.discardOutput()
                job.metrics.retainedResponseBytesAfterFinish = pipes.stdout.count
            }
            if !job.metrics.childLaunched { job.pipes?.closeAll(); job.metrics.pipesDrained = true }
            if job.releasable { job.pipes?.closeAll() }
            if outcome != .succeeded && outcome != .helperRejected { response = nil }
            return TextScriptProcessResult(response: response, metrics: job.metrics)
        }
    }

    private static func residentBytes(pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size, info.pti_resident_size > 0 else { return nil }
        return info.pti_resident_size
    }
}

private enum TextScriptExecutable {
    static func verify(bundle: URL, filename: String, identifier: String) throws -> (URL, TextScriptSignatureReceipt) {
        enum Invalid: Error { case signature }
        let app = bundle.standardizedFileURL
        let helper = app.appendingPathComponent("Contents/Helpers/" + filename)
        guard app.isFileURL, app.pathExtension == "app", app.resolvingSymlinksInPath() == app,
              helper.resolvingSymlinksInPath() == helper, FileManager.default.isExecutableFile(atPath: helper.path) else { throw Invalid.signature }
        var info = stat()
        guard lstat(helper.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Invalid.signature }
        var records: [[String: Any]] = []
        for url in [app, helper] {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw Invalid.signature }
            var copied: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &copied) == errSecSuccess,
                  let dictionary = copied as? [String: Any] else { throw Invalid.signature }
            records.append(dictionary)
        }
        let outer = records[0], inner = records[1]
        guard let appID = outer[kSecCodeInfoIdentifier as String] as? String, !appID.isEmpty,
              inner[kSecCodeInfoIdentifier as String] as? String == identifier,
              let entitlements = inner[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              Set(entitlements.keys) == ["com.apple.security.app-sandbox"],
              let sandbox = entitlements["com.apple.security.app-sandbox"] as? NSNumber,
              CFGetTypeID(sandbox) == CFBooleanGetTypeID(), sandbox.boolValue,
              let hash = inner[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty,
              (outer[kSecCodeInfoTeamIdentifier as String] as? String) == (inner[kSecCodeInfoTeamIdentifier as String] as? String) else { throw Invalid.signature }
        return (helper, TextScriptSignatureReceipt(appIdentifier: appID, helperIdentifier: identifier,
            helperCDHash: hash.map { String(format: "%02x", $0) }.joined(),
            helperEntitlements: entitlements.keys.sorted(), appAndHelperStrictlyValidated: true))
    }
}

/// Single process-wide reservation shared by every service instance. The job
/// survives a caller cancellation, service deallocation, and an unknown exit.
private final class TextScriptAdmission: @unchecked Sendable {
    static let shared = TextScriptAdmission()
    private let lock = NSLock()
    private var active: TextScriptOwnedJob?
    func acquire(_ job: TextScriptOwnedJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        recover()
        guard active == nil else { return false }
        active = job; return true
    }
    func finish(_ job: TextScriptOwnedJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active === job else { return false }
        job.finishSupervisor()
        if job.releasable { active = nil }
        return job.releasable
    }
    func snapshot() -> TextScriptProcessSnapshot {
        lock.lock(); defer { lock.unlock() }
        recover()
        // Metrics are only read after the supervisor ends; active mutable state
        // stays private so observers cannot race updates.
        return TextScriptProcessSnapshot(occupied: active != nil,
            metrics: active?.supervisorFinished == true ? active?.metrics : nil)
    }
    private func recover() {
        guard let active, active.supervisorFinished else { return }
        #if TEXT_SCRIPT_GATE
        guard !active.observationWithheld else { return }
        #endif
        // Gate-only withheld observation is deliberately recoverable through
        // actual Foundation ownership, never a fabricated successful receipt.
        if let process = active.process, !process.isRunning { active.recordExit(started: nil) }
        active.pipes?.drain()
        active.metrics.pipesDrained = active.pipes?.drained ?? true
        if active.releasable { active.pipes?.closeAll(); self.active = nil }
    }
    #if TEXT_SCRIPT_GATE
    func restoreObservation() {
        lock.lock(); defer { lock.unlock() }
        if active?.supervisorFinished == true { active?.observationWithheld = false; recover() }
    }
    #endif
}

private final class TextScriptOwnedJob: @unchecked Sendable {
    let cancellationLock = NSLock()
    private var cancelled = false
    private var finished = false
    var metrics: TextScriptProcessMetrics
    var process: Process?
    var pipes: TextScriptPipes?
    #if TEXT_SCRIPT_GATE
    var observationWithheld = false
    #endif
    init(requestID: UUID) { metrics = TextScriptProcessMetrics(requestID: requestID) }
    func cancel() { cancellationLock.lock(); cancelled = true; cancellationLock.unlock() }
    var isCancelled: Bool { cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancelled }
    func finishSupervisor() { cancellationLock.lock(); finished = true; cancellationLock.unlock() }
    var supervisorFinished: Bool { cancellationLock.lock(); defer { cancellationLock.unlock() }; return finished }
    var releasable: Bool { (!metrics.childLaunched || metrics.childExitConfirmed) && metrics.pipesDrained }
    func recordExit(started: Double?) {
        guard let process, !process.isRunning else { return }
        // No waitUntilExit on a running process, and no indefinite wait call at
        // all: isRunning false is Foundation's observed owned-process exit.
        metrics.childExitConfirmed = true
        metrics.terminationStatus = process.terminationStatus
        metrics.terminationReason = process.terminationReason == .exit ? "exit" : "uncaughtSignal"
        if metrics.exitObservedSeconds == nil, let started {
            metrics.exitObservedSeconds = ProcessInfo.processInfo.systemUptime - started
        }
    }
}

/// All endpoints are owned by one supervisor. Every operation is nonblocking,
/// stdout storage is bounded, stderr is count-only, and each drain pass has a
/// byte budget so continuous output cannot starve deadline/RSS checks.
private final class TextScriptPipes {
    let input: Pipe, output: Pipe, errors: Pipe
    var inputClosed = false
    var stdoutEOF = false, stderrEOF = false
    var stdout = Data()
    var stdoutCount = 0, stderrCount = 0
    var failed = false
    var discardResponse = false
    var childEndsClosed = false
    init(input: Pipe, output: Pipe, errors: Pipe) { self.input = input; self.output = output; self.errors = errors }
    var drained: Bool { stdoutEOF && stderrEOF }
    func configure() -> Bool {
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                       output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] {
            let fd = handle.fileDescriptor, flags = fcntl(handle.fileDescriptor, F_GETFD)
            guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0,
                  fcntl(fd, F_GETFD) & FD_CLOEXEC != 0 else { return false }
        }
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(fd, F_GETFL) & O_NONBLOCK != 0 else { return false }
        }
        return fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 &&
            fcntl(input.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1
    }
    func closeChildEnds() {
        guard !childEndsClosed else { return }; childEndsClosed = true
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
    }
    func closeInput() { if !inputClosed { inputClosed = true; try? input.fileHandleForWriting.close() } }
    func closeAll() {
        closeChildEnds(); closeInput()
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
    }
    func discardOutput() { stdout.removeAll(keepingCapacity: false); discardResponse = true }
    func write(_ data: Data, offset: inout Int) -> Bool {
        guard !inputClosed, offset < data.count else { return offset == data.count }
        let count = data.withUnsafeBytes { bytes in
            Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: offset), min(16_384, data.count - offset))
        }
        if count > 0 { offset += count; return true }
        return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
    }
    func drain() {
        if !stdoutEOF { read(output.fileHandleForReading.fileDescriptor, isError: false) }
        if !stderrEOF { read(errors.fileHandleForReading.fileDescriptor, isError: true) }
    }
    private func read(_ fd: Int32, isError: Bool) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { if isError { stderrEOF = true } else { stdoutEOF = true }; return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                failed = true; return
            }
            if isError { stderrCount = min(Int.max - count, stderrCount) + count }
            else {
                stdoutCount = min(Int.max - count, stdoutCount) + count
                if stdoutCount > 256 * 1_024 { failed = true }
                else if !failed && !discardResponse { stdout.append(contentsOf: buffer.prefix(count)) }
            }
        }
    }
}
