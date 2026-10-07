import Foundation
import Darwin
import PicShotCodecCore

struct ImageDecodeChildPhase: Encodable, Sendable {
    let child: ImageDecodeDiagnosticEvent
    let parentAtReceipt: ImageDecodeMemoryReading
    let childObservedRunning: Bool
    let receiptSkewSeconds: Double
}
struct ImageDecodeProcessMetrics: Encodable, Sendable {
    var outcome = "failed", lastStage = "admission"
    var childPID: Int32?, terminationStatus: Int32?
    var terminationReason: String?, jobDirectory: String?
    var childLaunched = false, exitConfirmed = false, cleanupConfirmed = false, admissionReleased = false
    var cancelRequested = false, cancelWriteReturn: Int?, terminateSent = false, killReturn: Int32?
    var sawPostDecodeReady = false, outputExistedBeforeCleanup = false
    var stdoutBytes = 0, stderrBytes = 0, stderrTruncated = false
    var childPolledResidentPeakBytes: UInt64?, childPolledResidentSamples = 0
    var phases: [ImageDecodeChildPhase] = []
    var terminal: ImageDecodeDiagnosticEvent?
    var signatureSeconds = 0.0, stagingSeconds = 0.0, launchThroughExitSeconds = 0.0, rawReadAndHashSeconds = 0.0, cleanupSeconds = 0.0, elapsedSeconds = 0.0
}
/// Dedicated diagnostic supervisor. No executable override, shell, export
/// protocol change, or lease release while the owned child may still write.
final class ImageDecodeDiagnosticProcess: @unchecked Sendable {
    enum Mode: Equatable, Sendable { case decode, cancelAfterDecode, timeoutAfterDecode }
    private let lock = NSLock(), mode: Mode
    private var cancelled = false, metrics = ImageDecodeProcessMetrics()
    init(mode: Mode) { self.mode = mode }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func snapshot() -> ImageDecodeProcessMetrics { lock.lock(); defer { lock.unlock() }; return metrics }
    private func update(_ f: (inout ImageDecodeProcessMetrics) -> Void) { lock.lock(); f(&metrics); lock.unlock() }
    /// Called only after real exit, pipe EOF and strict event decoding/ordering.
    static func terminalFailure(_ event: ImageDecodeDiagnosticEvent?, normalExit: Bool, status: Int32) throws -> ImageDecodeDiagnosticError? {
        guard let event, event.kind == .error else { return nil }
        guard normalExit, status == 1, event.phase == "failed", let error = event.error else { throw ImageDecodeDiagnosticError.invalidProtocol }
        return error
    }
    func run(png: Data, armDeadline: Double) throws -> Data? {
        let started = ProcessInfo.processInfo.systemUptime
        defer { update { $0.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started } }
        guard let lease = NativeExportAdmission.shared.acquire() else { throw CodecExportProcessError.busy }
        var job: ImageDecodeDiagnosticJob?, process: Process?
        var stagingFailure: ImageDecodeDiagnosticCreationFailure?
        var exited = false, launched = false
        defer {
            if let stagingFailure {
                let removed = stagingFailure.retryOwnedCleanup()
                update { $0.cleanupConfirmed = removed }
                if removed { NativeExportAdmission.shared.release(lease); update { $0.admissionReleased = true } }
                else { NativeExportAdmission.shared.retainUntilRecovered(lease) { stagingFailure.retryOwnedCleanup() } }
            } else if !launched || exited {
                let cleanupStart = ProcessInfo.processInfo.systemUptime
                let removed = job?.removeAfterExit() ?? true
                update { $0.cleanupConfirmed = removed; $0.cleanupSeconds = ProcessInfo.processInfo.systemUptime - cleanupStart }
                if removed { NativeExportAdmission.shared.release(lease); update { $0.admissionReleased = true } }
                else if let job { NativeExportAdmission.shared.retainUntilRecovered(lease) { job.removeAfterExit() } }
            } else if let process, let job {
                NativeExportAdmission.shared.retainUntilRecovered(lease) {
                    guard !process.isRunning else { return false }
                    process.waitUntilExit(); return job.removeAfterExit()
                }
            }
        }
        func check() throws {
            if isCancelled { throw ImageDecodeDiagnosticError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < armDeadline else { throw ImageDecodeDiagnosticError.deadline }
        }
        do {
            try check()
            update { $0.lastStage = "signatureValidation" }
            let signatureStart = ProcessInfo.processInfo.systemUptime
            let executable = try CodecHelperExecutable.verified()
            update { $0.signatureSeconds = ProcessInfo.processInfo.systemUptime - signatureStart }
            try check()
            let stagingStart = ProcessInfo.processInfo.systemUptime
            let files: ImageDecodeDiagnosticJob
            do { files = try ImageDecodeDiagnosticJob.create(png: png, mode: mode == .decode ? .decode : .holdAfterDecode, check: check) }
            catch let failure as ImageDecodeDiagnosticCreationFailure {
                stagingFailure = failure; update { $0.jobDirectory = failure.directory.path }; throw failure
            }
            job = files; update { $0.jobDirectory = files.directory.path; $0.stagingSeconds = ProcessInfo.processInfo.systemUptime - stagingStart; $0.lastStage = "launch" }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            defer {
                try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
                try? errors.fileHandleForReading.close(); try? errors.fileHandleForWriting.close()
            }
            let child = Process(); process = child
            child.executableURL = executable; child.arguments = [ImageDecodeDiagnosticLimits.argument]
            child.currentDirectoryURL = files.directory
            child.environment = ["HOME": NSHomeDirectory(), "TMPDIR": files.directory.path, "LANG": "en_US.UTF-8"]
            child.standardInput = input; child.standardOutput = output; child.standardError = errors
            let inputFD = input.fileHandleForWriting.fileDescriptor
            for fd in [inputFD, output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
            }
            guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
            try check()
            let launchStart = ProcessInfo.processInfo.systemUptime
            try child.run(); launched = true
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            update { $0.childLaunched = true; $0.childPID = child.processIdentifier; $0.lastStage = "childRunning" }
            var decoder = ImageDecodeDiagnosticEventDecoder(), outClosed = false, errClosed = false
            var sequence = ImageDecodeDiagnosticEventSequence(holdsAfterDecode: mode != .decode)
            var failure: ImageDecodeDiagnosticError?, stoppingAt: Double?, terminal: ImageDecodeDiagnosticEvent?
            var buffer = [UInt8](repeating: 0, count: 4_096)
            func drain(_ fd: Int32, stderr: Bool) {
                for _ in 0..<40 {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n == 0 { if stderr { errClosed = true } else { outClosed = true }; return }
                    if n < 0 { if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { failure = failure ?? .invalidProtocol }; return }
                    if stderr {
                        update { $0.stderrBytes += n; if $0.stderrBytes > ImageDecodeDiagnosticLimits.stderrBytes { $0.stderrTruncated = true } }
                        if snapshot().stderrTruncated { failure = failure ?? .invalidProtocol }
                    } else {
                        update { $0.stdoutBytes += n }
                        do {
                            for event in try decoder.consume(Data(buffer.prefix(n))) {
                                guard event.childPID == child.processIdentifier else { throw ImageDecodeDiagnosticError.invalidProtocol }
                                try sequence.consume(event)
                                let parentReading = ImageDecodeMemoryReading.current()
                                guard parentReading.usable else { throw ImageDecodeDiagnosticError.failed }
                                let pair = ImageDecodeChildPhase(child: event, parentAtReceipt: parentReading, childObservedRunning: child.isRunning,
                                    receiptSkewSeconds: max(0, ProcessInfo.processInfo.systemUptime - event.uptimeSeconds))
                                update { $0.phases.append(pair) }
                                if event.kind == .ready {
                                    guard mode != .decode, !snapshot().sawPostDecodeReady, event.rawBytes == ImageDecodeDiagnosticLimits.rasterBytes else { throw ImageDecodeDiagnosticError.invalidProtocol }
                                    update { $0.sawPostDecodeReady = true }
                                    if mode == .cancelAfterDecode { cancel() }
                                }
                                if event.kind == .result || event.kind == .error { terminal = event; update { $0.terminal = event } }
                            }
                        } catch { failure = failure ?? .invalidProtocol }
                    }
                }
            }
            while child.isRunning {
                if !outClosed { drain(output.fileHandleForReading.fileDescriptor, stderr: false) }
                if !errClosed { drain(errors.fileHandleForReading.fileDescriptor, stderr: true) }
                let now = ProcessInfo.processInfo.systemUptime
                var info = proc_taskinfo()
                let count = proc_pidinfo(child.processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
                if count == MemoryLayout<proc_taskinfo>.size {
                    update { $0.childPolledResidentSamples += 1; $0.childPolledResidentPeakBytes = max($0.childPolledResidentPeakBytes ?? 0, info.pti_resident_size) }
                    if info.pti_resident_size > ImageDecodeDiagnosticLimits.residentWatchdogBytes { failure = failure ?? .memoryLimit }
                }
                if isCancelled { failure = failure ?? .cancelled }
                if now >= min(launchStart + ImageDecodeDiagnosticLimits.childWorkSeconds, armDeadline) { failure = failure ?? .deadline }
                if failure != nil {
                    if stoppingAt == nil {
                        stoppingAt = now
                        let result = ImageDecodeDiagnosticLimits.cancelLine.withUnsafeBytes { Darwin.write(inputFD, $0.baseAddress!, $0.count) }
                        update { $0.cancelRequested = true; $0.cancelWriteReturn = result }
                    }
                    if now - stoppingAt! >= 0.3, !snapshot().terminateSent { child.terminate(); update { $0.terminateSent = true } }
                    if now - stoppingAt! >= 0.8, snapshot().killReturn == nil, child.isRunning { let result = kill(child.processIdentifier, SIGKILL); update { $0.killReturn = result } }
                }
                if now - launchStart >= ImageDecodeDiagnosticLimits.exitSeconds, child.isRunning { throw ImageDecodeDiagnosticError.exitUnconfirmed }
                if child.isRunning { Thread.sleep(forTimeInterval: 0.005) }
            }
            child.waitUntilExit(); exited = true
            update { $0.exitConfirmed = true; $0.terminationStatus = child.terminationStatus; $0.terminationReason = child.terminationReason == .exit ? "exit" : "uncaughtSignal"
                $0.launchThroughExitSeconds = ProcessInfo.processInfo.systemUptime - launchStart; $0.lastStage = "pipeDrain" }
            let drainDeadline = min(armDeadline, ProcessInfo.processInfo.systemUptime + 0.5)
            while (!outClosed || !errClosed) && ProcessInfo.processInfo.systemUptime < drainDeadline {
                if !outClosed { drain(output.fileHandleForReading.fileDescriptor, stderr: false) }
                if !errClosed { drain(errors.fileHandleForReading.fileDescriptor, stderr: true) }
                if !outClosed || !errClosed { Thread.sleep(forTimeInterval: 0.005) }
            }
            update { $0.outputExistedBeforeCleanup = files.outputExists() }
            guard outClosed, errClosed else { throw ImageDecodeDiagnosticError.invalidProtocol }
            try decoder.finish()
            if mode != .decode {
                if let failure, failure != .cancelled && failure != .deadline { throw failure }
                if let error = try Self.terminalFailure(terminal, normalExit: child.terminationReason == .exit, status: child.terminationStatus),
                   !snapshot().sawPostDecodeReady || (error != .cancelled && error != .deadline) { throw error }
                guard child.terminationReason == .exit, child.terminationStatus == 1,
                      snapshot().sawPostDecodeReady, !files.outputExists(), let terminal, terminal.kind == .error,
                      terminal.error == .cancelled || terminal.error == .deadline else { throw ImageDecodeDiagnosticError.invalidProtocol }
                if mode == .cancelAfterDecode {
                    guard snapshot().cancelRequested, terminal.error == .cancelled else { throw ImageDecodeDiagnosticError.invalidProtocol }
                    update { $0.outcome = "cancelled-after-decode" }
                } else {
                    guard terminal.error == .deadline || failure == .deadline else { throw ImageDecodeDiagnosticError.invalidProtocol }
                    update { $0.outcome = "deadline-after-decode" }
                }
                return nil
            }
            if let failure { throw failure }; try check()
            if let error = try Self.terminalFailure(terminal, normalExit: child.terminationReason == .exit, status: child.terminationStatus) { throw error }
            guard child.terminationReason == .exit, child.terminationStatus == 0, let terminal, terminal.kind == .result,
                  let digest = terminal.rawSHA256, let peaks = terminal.peaks,
                  peaks.residentBytes <= ImageDecodeDiagnosticLimits.residentWatchdogBytes,
                  peaks.footprintBytes <= ImageDecodeDiagnosticLimits.residentWatchdogBytes else { throw ImageDecodeDiagnosticError.invalidProtocol }
            update { $0.lastStage = "rawReadAndHash" }
            let readStart = ProcessInfo.processInfo.systemUptime
            let raw = try files.readRaw(sha256: digest, check: check)
            update { $0.rawReadAndHashSeconds = ProcessInfo.processInfo.systemUptime - readStart; $0.outcome = "decoded"; $0.lastStage = "cleanup" }
            return raw
        } catch {
            update { $0.outcome = ((error as? ImageDecodeDiagnosticError) ?? .failed).rawValue }
            throw error
        }
    }
}

/// Errors may terminate any valid prefix, including admission before PNG read.
/// A valid error code never excuses an out-of-order or malformed event stream.
struct ImageDecodeDiagnosticEventSequence {
    private let phases: [String]
    private var index = 0, finished = false
    init(holdsAfterDecode: Bool) {
        phases = ["beforePNGRead", "imageCreated", "rasterDrawn", "afterContextRelease"] +
            (holdsAfterDecode ? ["heldAfterDecode"] : ["outputClosed", "afterDecodePool"])
    }
    mutating func consume(_ event: ImageDecodeDiagnosticEvent) throws {
        guard !finished else { throw ImageDecodeDiagnosticError.invalidProtocol }
        switch event.kind {
        case .phase, .ready:
            guard index < phases.count, event.phase == phases[index],
                  (event.kind == .ready) == (event.phase == "heldAfterDecode") else { throw ImageDecodeDiagnosticError.invalidProtocol }
            index += 1
        case .result:
            guard index == phases.count, phases.last == "afterDecodePool", event.phase == "complete" else { throw ImageDecodeDiagnosticError.invalidProtocol }
            finished = true
        case .error:
            guard event.phase == "failed", event.error != nil else { throw ImageDecodeDiagnosticError.invalidProtocol }
            finished = true
        }
    }
}
