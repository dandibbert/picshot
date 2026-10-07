import Darwin
import Foundation
import Security

enum GIFExportProcessError: LocalizedError {
    case busy, helperUnavailable, signature, invalidSource, invalidProtocol, timedOut, memoryLimit, exitUnconfirmed
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .busy: return "A GIF, WebP, or AVIF export is still running or cleaning up. Wait for it to finish or cancel."
        case .helperUnavailable: return "The signed GIF export helper is unavailable. Reinstall the complete PicShot app."
        case .signature: return "The GIF helper's bundle path or code signature could not be verified."
        case .invalidSource: return "GIF export requires a regular local, self-contained H.264 MP4 file no larger than 1 GiB (optional AAC audio)."
        case .invalidProtocol: return "The GIF helper returned an invalid or oversized response."
        case .timedOut: return "The GIF export exceeded its time limit and was stopped."
        case .memoryLimit: return "The GIF helper exceeded its memory limit and was stopped."
        case .exitUnconfirmed: return "The GIF helper has not confirmed exit. Further native exports are blocked until it exits."
        case .failed(let message): return "GIF export failed: \(message)"
        }
    }
}

/// Production always resolves the current signed app's own executable. Explicit
/// injected configurations are for process/protocol tests, never an automatic
/// development fallback or an environment-controlled executable override.
struct GIFProcessConfiguration: @unchecked Sendable {
    let executable: @Sendable () throws -> URL
    let arguments: [String]
    let wallSeconds: TimeInterval
    let residentLimitBytes: UInt64
    let stopActions: GIFProcessStopActions
    let launchDiagnosticsForTesting: GIFProcessLaunchDiagnostics?
    static var production: Self { Self(executable: { try GIFHelperExecutable.verified() }) }
    init(executable: @escaping @Sendable () throws -> URL,
         arguments: [String] = ["--picshot-gif-helper"],
         wallSeconds: TimeInterval = 300, residentLimitBytes: UInt64 = 1_073_741_824,
         stopActionsForTesting: GIFProcessStopActions? = nil,
         launchDiagnosticsForTesting: GIFProcessLaunchDiagnostics? = nil) {
        self.executable = executable; self.arguments = arguments
        self.wallSeconds = wallSeconds; self.residentLimitBytes = residentLimitBytes
        self.stopActions = stopActionsForTesting ?? .production
        self.launchDiagnosticsForTesting = launchDiagnosticsForTesting
    }
}

/// Explicit constructor-only injection permits a bounded synthetic child to
/// outlive the escalation window in tests. Production timings/signals and
/// actual Process exit observation are never replaced or environment-driven.
struct GIFProcessStopActions: Sendable {
    let terminate: @Sendable (Process) -> Void
    let kill: @Sendable (Int32) -> Void
    static let production = Self(terminate: { $0.terminate() }, kill: { _ = Darwin.kill($0, SIGKILL) })
}

enum GIFHelperExecutable {
    static func verified(bundleURL: URL = Bundle.main.bundleURL) throws -> URL {
        let bundle = bundleURL.standardizedFileURL
        guard bundle.isFileURL, bundle.pathExtension == "app" else { throw GIFExportProcessError.helperUnavailable }
        let executable = bundle.appendingPathComponent("Contents/MacOS/PicShot")
        guard bundle.resolvingSymlinksInPath().path == bundle.path, executable.resolvingSymlinksInPath().path == executable.path,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw GIFExportProcessError.signature }
        var file = stat()
        guard lstat(executable.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG else { throw GIFExportProcessError.signature }
        for url in [bundle, executable] {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
                throw GIFExportProcessError.signature
            }
        }
        return executable
    }
}

struct GIFExportProcessMetrics: Codable, Equatable, Sendable {
    var outcome = "failed"
    var lastStage = "admission"
    var elapsedSeconds: TimeInterval = 0
    var childLaunched = false
    var childExitConfirmed = false
    var terminationStatus: Int32?
    var terminationReason: String?
    var temporaryDirectoryRemoved = false
    var parentSampledPeakResidentBytes: UInt64?
    var parentResidentSampleCount = 0
    var parentSampledPeakPhysicalFootprintBytes: UInt64?
    var parentPhysicalFootprintSampleCount = 0
    var childSampledPeakResidentBytes: UInt64?
    var childResidentSampleCount = 0
    var childReportedPeakResidentBytes: UInt64?
    var childReportedPeakPhysicalFootprintBytes: UInt64?
    var childReportedResidentSampleCount = 0
    var childReportedPhysicalFootprintSampleCount = 0
    var stdoutBytes = 0
    var stderrBytes = 0
    var stderrTruncated = false
    // Bounded protocol diagnostics. Admission failures never include a source
    // path or media contents; retain the first rejecting predicate for QA.
    var helperErrorCode: String?
    var helperErrorMessage: String?
    var outputBytes: Int?
    var sourceBytes: Int64?
    var configuredWallSeconds: TimeInterval = 300
    var configuredChildResidentLimitBytes: UInt64 = 1_073_741_824
    var sampleIntervalSeconds: TimeInterval = 0.05
    let admissionScope = "one native export child shared by GIF, WebP and AVIF; independent of the model-helper gate"
    let measurementScope = "main-process RSS/footprint plus this GIF child's parent-polled RSS and child-reported RSS/footprint; sampled maxima, not kernel lifetime peaks; other helpers/framework services/GPU memory excluded"
}
struct GIFExportProcessSnapshot: Encodable, Sendable {
    let active: Bool
    let lastJob: GIFExportProcessMetrics?
}

/// One process-wide GIF lease. Cancellation does not free admission until exit
/// and cleanup are confirmed. An unkillable child keeps the gate closed; later
/// calls may observe its eventual exit and finish only that owned cleanup.
actor GIFExportProcessService {
    static let shared = GIFExportProcessService()
    private let configuration: GIFProcessConfiguration
    private var active: GIFProcessJob?
    private var admissionToken: UUID?
    private var lastJob: GIFExportProcessMetrics?
    init(configuration: GIFProcessConfiguration = .production) { self.configuration = configuration }

    func export(sourceURL: URL, destinationURL: URL? = nil, options: GIFExportOptions = .init(),
                frameExtraction: GIFFrameExtraction = .asynchronous,
                trimStage: OwnedVideoExportStage? = nil,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        refreshStrandedJob()
        try options.validate(); try Task.checkCancellation()
        guard active == nil, let lease = NativeExportAdmission.shared.acquire() else { throw GIFExportProcessError.busy }
        admissionToken = lease
        let configuration = self.configuration
        let job = GIFProcessJob(configuration: configuration)
        active = job
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try Self.run(sourceURL: sourceURL, destinationURL: destinationURL, options: options,
                                 extraction: frameExtraction, trimStage: trimStage, configuration: configuration, job: job, progress: progress)
                }.value
            } onCancel: { job.cancel() }
            complete(job); return result
        } catch {
            complete(job); throw error
        }
    }
    func snapshot() -> GIFExportProcessSnapshot {
        refreshStrandedJob()
        return GIFExportProcessSnapshot(active: active != nil, lastJob: lastJob)
    }
    private func complete(_ job: GIFProcessJob) {
        guard active === job else { return }
        lastJob = job.snapshot()
        if (!lastJob!.childLaunched || lastJob!.childExitConfirmed) && lastJob!.temporaryDirectoryRemoved {
            active = nil
            if let admissionToken { NativeExportAdmission.shared.release(admissionToken) }
            admissionToken = nil
        } else {
            job.markStranded()
            if let admissionToken { NativeExportAdmission.shared.retainUntilRecovered(admissionToken) {
                let state = job.snapshot()
                if (!state.childLaunched || state.childExitConfirmed) && state.temporaryDirectoryRemoved { return true }
                return job.finishStrandedCleanupIfExited()
            } }
        }
    }
    private func refreshStrandedJob() {
        guard let active, active.isStranded else { return }
        let state = active.snapshot()
        guard ((!state.childLaunched || state.childExitConfirmed) && state.temporaryDirectoryRemoved) || active.finishStrandedCleanupIfExited() else { return }
        lastJob = active.snapshot(); self.active = nil
        if let admissionToken { NativeExportAdmission.shared.release(admissionToken) }
        admissionToken = nil
    }

    private nonisolated static func run(sourceURL: URL, destinationURL: URL?, options: GIFExportOptions,
        extraction: GIFFrameExtraction, trimStage: OwnedVideoExportStage?, configuration: GIFProcessConfiguration, job: GIFProcessJob,
        progress: (@Sendable (Double) -> Void)?) throws -> URL {
        let started = ProcessInfo.processInfo.systemUptime
        defer { job.update { $0.elapsedSeconds = max(0, ProcessInfo.processInfo.systemUptime - started) } }
        var directory: OwnedGIFJobDirectory?
        var ownedDestinationDirectory: OwnedGIFOutputDirectory?
        var completed = false
        defer {
            let state = job.snapshot()
            if !state.childLaunched || state.childExitConfirmed {
                let jobRemoved = directory?.cleanup() ?? true
                let removed = jobRemoved && (completed || (ownedDestinationDirectory?.cleanupEmpty() ?? true))
                job.update { $0.temporaryDirectoryRemoved = removed }
            }
        }
        do {
            try job.checkCancellation()
            guard configuration.wallSeconds.isFinite, configuration.wallSeconds > 0,
                  configuration.residentLimitBytes > 0 else { throw GIFExportProcessError.invalidProtocol }
            job.update { $0.lastStage = "executableValidation" }
            configuration.launchDiagnosticsForTesting?.record(.executableValidationStarted)
            let executable = try autoreleasepool { try configuration.executable() }
            guard ProcessInfo.processInfo.systemUptime < started + configuration.wallSeconds else { throw GIFExportProcessError.timedOut }
            job.update { $0.lastStage = "destinationPreparation" }
            configuration.launchDiagnosticsForTesting?.record(.destinationPreparationStarted)
            let destination: URL
            if let destinationURL {
                guard destinationURL.isFileURL else { throw GIFExportProcessError.invalidSource }
                destination = destinationURL.standardizedFileURL
            } else {
                let root = try OwnedGIFOutputDirectory.create(in: FileManager.default.temporaryDirectory)
                ownedDestinationDirectory = root; destination = root.url.appendingPathComponent("recording.gif")
                job.setOwnedDestinationDirectory(root)
            }
            guard removalConfirmed(destination) else { throw GIFExportError.destinationExists }
            let ownedJob: OwnedGIFJobDirectory
            if let trimStage {
                ownedJob = try trimStage.makeSiblingGIFJob(sourceURL: sourceURL, destinationURL: destination)
            } else {
                ownedJob = try OwnedGIFJobDirectory.create(in: destination.deletingLastPathComponent())
            }
            let jobDirectory = ownedJob.url
            directory = ownedJob; job.setDirectory(ownedJob, ownedDestinationDirectory: ownedDestinationDirectory)
            job.update { $0.lastStage = "sourceSnapshot" }
            configuration.launchDiagnosticsForTesting?.record(.sourceSnapshotStarted)
            try copySource(sourceURL, to: jobDirectory.appendingPathComponent("source.mp4"), job: job,
                           deadline: started + configuration.wallSeconds)
            try ownedJob.recordSource()
            if let trimStage { try trimStage.validateGIFPaths(sourceURL: sourceURL, destinationURL: destination) }
            try job.checkCancellation()
            configuration.launchDiagnosticsForTesting?.record(.processConfigurationStarted)
            let request = GIFHelperRequest(options: options, frameExtraction: extraction)
            let inputData = try GIFHelperProtocol.encodeRequestLine(request)
            let input = Pipe(), output = Pipe(), errors = Pipe()
            let process = Process()
            process.executableURL = executable; process.arguments = configuration.arguments
            process.currentDirectoryURL = jobDirectory
            // Never inherit smoke/recovery/helper-test selectors, model paths,
            // DYLD overrides, credentials, or the user's environment wholesale.
            process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": jobDirectory.path, "LANG": "en_US.UTF-8"]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            let reader = GIFProcessPipeState(progressLimit: options.maximumFrames + 2)
            reader.start(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
            defer { reader.close() }
            job.update { $0.lastStage = "helperLaunch" }
            configuration.launchDiagnosticsForTesting?.record(.processRunStarted)
            do { try process.run() }
            catch {
                configuration.launchDiagnosticsForTesting?.record(.processRunFailed)
                reader.closeWriters(output: output, errors: errors); throw error
            }
            job.setProcess(process)
            configuration.launchDiagnosticsForTesting?.record(.processRunSucceeded)
            try? input.fileHandleForReading.close()
            reader.closeWriters(output: output, errors: errors)
            defer { try? input.fileHandleForWriting.close() }
            // Fail closed if nonblocking/SIGPIPE safety cannot be established.
            // Never risk delivering an early-exit SIGPIPE to the main app.
            configuration.launchDiagnosticsForTesting?.record(.requestPipeConfigurationStarted)
            let inputFD = input.fileHandleForWriting.fileDescriptor
            let inputFlags = fcntl(inputFD, F_GETFL)
            let inputSafe = inputFlags >= 0 && fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 &&
                fcntl(inputFD, F_SETFL, inputFlags | O_NONBLOCK) == 0
            var failure: Error?
            if inputSafe {
                configuration.launchDiagnosticsForTesting?.record(.requestPipeReady)
                configuration.launchDiagnosticsForTesting?.record(.requestWriteStarted)
                do {
                    try input.fileHandleForWriting.write(contentsOf: inputData)
                    configuration.launchDiagnosticsForTesting?.record(.requestWriteSucceeded)
                } catch {
                    configuration.launchDiagnosticsForTesting?.record(.requestWriteFailed)
                    failure = GIFExportProcessError.failed("The helper request pipe closed before setup completed.")
                }
            } else {
                configuration.launchDiagnosticsForTesting?.record(.requestPipeFailed)
                failure = GIFExportProcessError.failed("The helper control pipe could not be configured safely.")
                try? input.fileHandleForWriting.close()
            }
            var stopStarted: TimeInterval?
            var sentTerminate = false, sentKill = false
            job.update { $0.lastStage = "helperRunning" }
            configuration.launchDiagnosticsForTesting?.record(.helperRunning)
            while process.isRunning {
                let now = ProcessInfo.processInfo.systemUptime
                sample(job: job, child: process.processIdentifier)
                let snapshot = reader.snapshot()
                job.recordPipe(snapshot)
                if failure == nil, let error = snapshot.failure { failure = error }
                if job.isCancelled || Task.isCancelled { job.cancel(); failure = CancellationError() }
                if failure == nil, now - started >= configuration.wallSeconds { failure = GIFExportProcessError.timedOut }
                let metrics = job.snapshot()
                if failure == nil, (metrics.childSampledPeakResidentBytes ?? 0) > configuration.residentLimitBytes ||
                    (metrics.childReportedPeakResidentBytes ?? 0) > configuration.residentLimitBytes {
                    failure = GIFExportProcessError.memoryLimit
                }
                if failure == nil {
                    for value in reader.takeProgress() where value < 1 {
                        progress?(value)
                        if job.isCancelled || Task.isCancelled { job.cancel(); failure = CancellationError(); break }
                    }
                }
                if failure != nil {
                    if stopStarted == nil {
                        stopStarted = now
                        if inputSafe { try? input.fileHandleForWriting.write(contentsOf: Data("{\"cancel\":true}\n".utf8)) }
                    }
                    let elapsed = now - stopStarted!
                    if elapsed >= 0.3, !sentTerminate { configuration.stopActions.terminate(process); sentTerminate = true }
                    if elapsed >= 0.8, !sentKill, process.isRunning { configuration.stopActions.kill(process.processIdentifier); sentKill = true }
                    if elapsed >= 3.8, process.isRunning {
                        job.update { $0.outcome = "exitUnconfirmed" }
                        throw GIFExportProcessError.exitUnconfirmed
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit() // Already observed exited; never an unbounded running-child wait.
            job.recordExit(process)
            job.update { $0.lastStage = "helperResponse" }
            configuration.launchDiagnosticsForTesting?.record(.helperResponse)
            let drainDeadline = ProcessInfo.processInfo.systemUptime + 1
            while !reader.snapshot().finished, ProcessInfo.processInfo.systemUptime < drainDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let response = reader.snapshot(); job.recordPipe(response)
            sample(job: job, child: nil)
            if failure == nil, ProcessInfo.processInfo.systemUptime >= started + configuration.wallSeconds {
                failure = GIFExportProcessError.timedOut
            }
            if job.isCancelled || Task.isCancelled { job.cancel(); throw CancellationError() }
            if let failure { throw failure }
            if let error = response.failure { throw error }
            guard response.finished else { throw GIFExportProcessError.invalidProtocol }
            for value in reader.takeProgress() where value < 1 {
                progress?(value)
                try job.checkCancellation()
            }
            if let terminal = response.terminal, terminal.kind == .error { throw mappedError(terminal) }
            guard process.terminationStatus == 0, process.terminationReason == .exit else {
                throw GIFExportProcessError.failed("The helper exited unexpectedly with status \(process.terminationStatus).")
            }
            guard let terminal = response.terminal, terminal.kind == .result,
                  let bytes = terminal.outputBytes, bytes > 0, bytes <= GIFHelperLimits.outputBytes,
                  response.lastProgress == 1, response.progressCount >= 3,
                  let frames = terminal.frameCount, frames == response.progressCount - 2,
                  let duration = terminal.duration, duration.isFinite, duration > 0,
                  frames <= options.maximumFrames, duration <= options.maximumDuration + 0.011 else {
                throw GIFExportProcessError.invalidProtocol
            }
            let statistics = job.snapshot()
            guard statistics.childResidentSampleCount > 0, statistics.childReportedResidentSampleCount > 0 else {
                throw GIFExportProcessError.failed("The helper completed without usable child memory observations.")
            }
            if (statistics.childSampledPeakResidentBytes ?? 0) > configuration.residentLimitBytes ||
                (statistics.childReportedPeakResidentBytes ?? 0) > configuration.residentLimitBytes { throw GIFExportProcessError.memoryLimit }
            let result = jobDirectory.appendingPathComponent("result.gif")
            job.update { $0.lastStage = "outputVerification" }
            try validateOutput(result, expectedBytes: bytes, expectedFrames: frames, duration: duration, options: options) {
                try job.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < started + configuration.wallSeconds else { throw GIFExportProcessError.timedOut }
            }
            try job.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < started + configuration.wallSeconds else { throw GIFExportProcessError.timedOut }
            // The private job and destination remain on the same filesystem.
            // A trim job is beside its caller's stage, never nested inside it.
            if let trimStage { try trimStage.validateGIFPaths(sourceURL: sourceURL, destinationURL: destination) }
            job.update { $0.lastStage = "publication" }
            try FileManager.default.moveItem(at: result, to: destination)
            completed = true
            job.markPublished()
            try trimStage?.recordGIF()
            job.update { $0.outputBytes = bytes; $0.outcome = "succeeded" }
            job.update { $0.lastStage = "stagingCleanup" }
            guard ownedJob.cleanup() else { throw GIFExportProcessError.failed("GIF staging cleanup could not be confirmed.") }
            job.update { $0.temporaryDirectoryRemoved = true }
            job.update { $0.lastStage = "complete" }
            sample(job: job, child: nil)
            progress?(1) // Never report completion before actual publication/cleanup.
            return destination
        } catch {
            let outcome: String
            if error is CancellationError { outcome = "cancelled" }
            else if let specific = error as? GIFExportProcessError {
                switch specific { case .timedOut: outcome = "timedOut"; case .memoryLimit: outcome = "memoryLimit"
                case .exitUnconfirmed: outcome = "exitUnconfirmed"; default: outcome = "failed" }
            } else { outcome = "failed" }
            job.update { $0.outcome = outcome }
            throw error
        }
    }

    private nonisolated static func copySource(_ source: URL, to target: URL, job: GIFProcessJob, deadline: TimeInterval) throws {
        guard source.isFileURL else { throw GIFExportProcessError.invalidSource }
        let values = try source.resourceValues(forKeys: [.volumeIsLocalKey, .isSymbolicLinkKey])
        guard values.volumeIsLocal == true, values.isSymbolicLink != true else { throw GIFExportProcessError.invalidSource }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw GIFExportProcessError.invalidSource }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= GIFHelperLimits.sourceBytes else { throw GIFExportProcessError.invalidSource }
        let targetDescriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard targetDescriptor >= 0 else { throw GIFExportProcessError.invalidSource }
        let output = FileHandle(fileDescriptor: targetDescriptor, closeOnDealloc: true); defer { try? output.close() }
        var copied: Int64 = 0
        while true {
            try job.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GIFExportProcessError.timedOut }
            let count: Int = try autoreleasepool {
                let data = try input.read(upToCount: 1_048_576) ?? Data()
                guard copied + Int64(data.count) <= GIFHelperLimits.sourceBytes else { throw GIFExportProcessError.invalidSource }
                if !data.isEmpty { try output.write(contentsOf: data) }
                return data.count
            }
            if count == 0 { break }
            copied += Int64(count)
            job.recordParent(GIFResourceMemoryReading.current())
        }
        guard copied == info.st_size else { throw GIFExportProcessError.invalidSource }
        try output.synchronize()
        job.update { $0.sourceBytes = copied }
    }
    private nonisolated static func validateOutput(_ url: URL, expectedBytes: Int, expectedFrames: Int,
                                                  duration: Double, options: GIFExportOptions,
                                                  check: @escaping () throws -> Void) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw GIFExportProcessError.invalidProtocol }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size == expectedBytes, info.st_size >= 14,
              info.st_size <= GIFHelperLimits.outputBytes else { throw GIFExportProcessError.invalidProtocol }
        try GIFOutputVerification.validate(file: file, bytes: expectedBytes, expectedFrames: expectedFrames,
                                           expectedDuration: duration, options: options, check: check)
    }
    private nonisolated static func sample(job: GIFProcessJob, child: Int32?) {
        job.recordParent(GIFResourceMemoryReading.current())
        guard let child else { return }
        var info = proc_taskinfo()
        let count = proc_pidinfo(child, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        if count == Int32(MemoryLayout<proc_taskinfo>.size) { job.recordChildRSS(info.pti_resident_size) }
    }
    private nonisolated static func mappedError(_ event: GIFHelperEvent) -> Error {
        switch event.errorCode {
        case "cancelled": return CancellationError()
        case "deadline": return GIFExportProcessError.timedOut
        case "memoryLimit": return GIFExportProcessError.memoryLimit
        case "invalidOptions": return GIFExportError.invalidOptions
        case "invalidSource": return GIFExportProcessError.invalidSource
        case "noVideo": return GIFExportError.noVideo
        case "tooLarge": return GIFExportError.tooLarge
        case "unsupportedTransparency": return GIFExportError.unsupportedTransparency
        case "protocol", "invalidJobDirectory": return GIFExportProcessError.invalidProtocol
        default: return GIFExportProcessError.failed(event.errorMessage ?? "The helper failed without a message.")
        }
    }
    fileprivate nonisolated static func removalConfirmed(_ url: URL) -> Bool {
        var value = stat(); return lstat(url.path, &value) != 0 && errno == ENOENT
    }
}

private final class GIFProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics = GIFExportProcessMetrics()
    private var cancelled = false
    private var stranded = false
    private var published = false
    private var process: Process?
    private var directory: OwnedGIFJobDirectory?
    private var ownedDestinationDirectory: OwnedGIFOutputDirectory?
    init(configuration: GIFProcessConfiguration) {
        metrics.configuredWallSeconds = configuration.wallSeconds
        metrics.configuredChildResidentLimitBytes = configuration.residentLimitBytes
    }
    func update(_ body: (inout GIFExportProcessMetrics) -> Void) { lock.lock(); defer { lock.unlock() }; body(&metrics) }
    func snapshot() -> GIFExportProcessMetrics { lock.lock(); defer { lock.unlock() }; return metrics }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func checkCancellation() throws { if isCancelled || Task.isCancelled { cancel(); throw CancellationError() } }
    func setProcess(_ value: Process) { lock.lock(); defer { lock.unlock() }; process = value; metrics.childLaunched = true }
    func setOwnedDestinationDirectory(_ value: OwnedGIFOutputDirectory) {
        lock.lock(); defer { lock.unlock() }; ownedDestinationDirectory = value
    }
    func setDirectory(_ value: OwnedGIFJobDirectory, ownedDestinationDirectory: OwnedGIFOutputDirectory?) {
        lock.lock(); defer { lock.unlock() }; directory = value; self.ownedDestinationDirectory = ownedDestinationDirectory
    }
    func recordExit(_ process: Process) {
        update { $0.childExitConfirmed = true; $0.terminationStatus = process.terminationStatus
            $0.terminationReason = process.terminationReason == .exit ? "exit" : "uncaughtSignal" }
    }
    func recordParent(_ value: GIFResourceMemoryReading) {
        update {
            if let bytes = value.residentBytes { $0.parentSampledPeakResidentBytes = max($0.parentSampledPeakResidentBytes ?? bytes, bytes); $0.parentResidentSampleCount += 1 }
            if let bytes = value.physicalFootprintBytes { $0.parentSampledPeakPhysicalFootprintBytes = max($0.parentSampledPeakPhysicalFootprintBytes ?? bytes, bytes); $0.parentPhysicalFootprintSampleCount += 1 }
        }
    }
    func recordChildRSS(_ bytes: UInt64) {
        update { $0.childSampledPeakResidentBytes = max($0.childSampledPeakResidentBytes ?? bytes, bytes); $0.childResidentSampleCount += 1 }
    }
    func recordPipe(_ value: GIFProcessPipeSnapshot) {
        update {
            $0.stdoutBytes = value.stdoutBytes; $0.stderrBytes = value.stderrBytes; $0.stderrTruncated = value.stderrTruncated
            $0.childReportedPeakResidentBytes = value.childPeakRSS; $0.childReportedPeakPhysicalFootprintBytes = value.childPeakFootprint
            $0.childReportedResidentSampleCount = value.childRSSCount; $0.childReportedPhysicalFootprintSampleCount = value.childFootprintCount
            if value.terminal?.kind == .error {
                $0.helperErrorCode = value.terminal?.errorCode
                $0.helperErrorMessage = value.terminal?.errorMessage
            }
        }
    }
    func markStranded() { lock.lock(); stranded = true; lock.unlock() }
    func markPublished() { lock.lock(); published = true; lock.unlock() }
    var isStranded: Bool { lock.lock(); defer { lock.unlock() }; return stranded }
    func finishStrandedCleanupIfExited() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stranded else { return false }
        if let process {
            guard !process.isRunning else { return false }
            process.waitUntilExit()
            metrics.childExitConfirmed = true; metrics.terminationStatus = process.terminationStatus
            metrics.terminationReason = process.terminationReason == .exit ? "exit" : "uncaughtSignal"
        }
        let jobRemoved = directory?.cleanup() ?? true
        metrics.temporaryDirectoryRemoved = jobRemoved && (published || (ownedDestinationDirectory?.cleanupEmpty() ?? true))
        guard metrics.temporaryDirectoryRemoved else { return false }
        // Cross-format recovery can finish before this actor is called again.
        // Keep only its accounting marker, not open directory/process handles.
        directory = nil; process = nil; ownedDestinationDirectory = nil
        // Keep the recovery marker until the owning actor observes completion.
        // The shared admission may reclaim this job before that actor wakes.
        return true
    }
}

private struct GIFProcessPipeSnapshot {
    let failure: Error?
    let terminal: GIFHelperEvent?
    let lastProgress: Double?
    let progressCount: Int
    let stdoutBytes: Int
    let stderrBytes: Int
    let stderrTruncated: Bool
    let finished: Bool
    let childPeakRSS: UInt64?
    let childPeakFootprint: UInt64?
    let childRSSCount: Int
    let childFootprintCount: Int
}

/// Constant-space pipe draining. The only queue is at most maximumFrames+2
/// progress scalars; never buffers media, the full stdout stream, or unbounded
/// stderr. Reader queues do not invoke UI/progress callbacks.
private final class GIFProcessPipeState: @unchecked Sendable {
    private let lock = NSLock()
    private let progressLimit: Int
    private var pending = Data()
    private var progress: [Double] = []
    private var lastProgress: Double?
    private var progressCount = 0
    private var stdoutBytes = 0, stderrBytes = 0
    private var stderrPrefix = Data()
    private var stdoutDone = false, stderrDone = false
    private var failure: Error?
    private var terminal: GIFHelperEvent?
    private var childPeakRSS: UInt64?, childPeakFootprint: UInt64?
    private var childRSSCount = 0, childFootprintCount = 0
    private var stopping = false
    init(progressLimit: Int) { self.progressLimit = progressLimit }
    func start(stdout: FileHandle, stderr: FileHandle) {
        DispatchQueue(label: "PicShot.GIF.stdout").async { self.read(stdout, isError: false) }
        DispatchQueue(label: "PicShot.GIF.stderr").async { self.read(stderr, isError: true) }
    }
    func closeWriters(output: Pipe, errors: Pipe) { try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close() }
    // Each reader alone owns/closes its fd. Closing from another queue could
    // race a read against a reused descriptor; the nonblocking poll bounds the
    // stop observation without cross-thread close or a detached blocked read.
    func close() { lock.lock(); stopping = true; lock.unlock() }
    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    private func read(_ handle: FileHandle, isError: Bool) {
        defer {
            try? handle.close()
            lock.lock(); defer { lock.unlock() }
            if isError { stderrDone = true }
            else { stdoutDone = true; if !pending.isEmpty, failure == nil { failure = GIFExportProcessError.invalidProtocol } }
        }
        do {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw GIFExportProcessError.invalidProtocol
            }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while !shouldStop {
                var polling = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&polling, 1, 50)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0, polling.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                    throw GIFExportProcessError.invalidProtocol
                }
                if ready == 0 { continue }
                // FileHandle.read(upToCount:) can wait for a full requested
                // chunk or EOF. POSIX read forwards a short progress line now,
                // while the helper is still alive and cancellation can act.
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else { throw GIFExportProcessError.invalidProtocol }
                autoreleasepool {
                    let data = Data(buffer.prefix(count))
                    lock.lock(); consume(data, isError: isError); lock.unlock()
                }
            }
        } catch {
            lock.lock(); if failure == nil { failure = GIFExportProcessError.invalidProtocol }; lock.unlock()
        }
    }
    private func consume(_ data: Data, isError: Bool) {
        if isError {
            stderrBytes = min(Int.max - data.count, stderrBytes) + data.count
            let remaining = max(0, GIFHelperLimits.stderrBytes - stderrPrefix.count)
            stderrPrefix.append(data.prefix(remaining)); return
        }
        guard stdoutBytes <= GIFHelperLimits.stdoutBytes - data.count else { failure = GIFExportProcessError.invalidProtocol; return }
        stdoutBytes += data.count
        guard failure == nil else { return }
        for byte in data {
            if byte == 10 {
                do {
                    guard pending.count + 1 <= GIFHelperLimits.eventBytes else { throw GIFExportProcessError.invalidProtocol }
                    try autoreleasepool { try accept(GIFHelperProtocol.decodeEventLine(pending)) }
                }
                catch { failure = GIFExportProcessError.invalidProtocol }
                pending.removeAll(keepingCapacity: true)
                if failure != nil { return }
            } else {
                guard pending.count < GIFHelperLimits.eventBytes else { failure = GIFExportProcessError.invalidProtocol; return }
                pending.append(byte)
            }
        }
    }
    private func accept(_ event: GIFHelperEvent) throws {
        guard terminal == nil else { throw GIFExportProcessError.invalidProtocol }
        if let bytes = event.residentBytes { childPeakRSS = max(childPeakRSS ?? bytes, bytes); childRSSCount += 1 }
        if let bytes = event.physicalFootprintBytes { childPeakFootprint = max(childPeakFootprint ?? bytes, bytes); childFootprintCount += 1 }
        if let bytes = event.sampledPeakResidentBytes { childPeakRSS = max(childPeakRSS ?? bytes, bytes) }
        if let bytes = event.sampledPeakPhysicalFootprintBytes { childPeakFootprint = max(childPeakFootprint ?? bytes, bytes) }
        if let count = event.residentSampleCount { childRSSCount = max(childRSSCount, count) }
        if let count = event.physicalFootprintSampleCount { childFootprintCount = max(childFootprintCount, count) }
        switch event.kind {
        case .progress:
            guard let fraction = event.fraction, fraction.isFinite, (0...1).contains(fraction),
                  fraction >= (lastProgress ?? 0), (lastProgress != nil || fraction == 0),
                  progressCount < progressLimit else { throw GIFExportProcessError.invalidProtocol }
            lastProgress = fraction; progressCount += 1; progress.append(fraction)
        case .memory: break
        case .result, .error: terminal = event
        }
    }
    func takeProgress() -> [Double] { lock.lock(); defer { lock.unlock() }; let values = progress; progress.removeAll(keepingCapacity: true); return values }
    func snapshot() -> GIFProcessPipeSnapshot {
        lock.lock(); defer { lock.unlock() }
        return GIFProcessPipeSnapshot(failure: failure, terminal: terminal, lastProgress: lastProgress,
            progressCount: progressCount, stdoutBytes: stdoutBytes, stderrBytes: stderrBytes,
            stderrTruncated: stderrBytes > GIFHelperLimits.stderrBytes, finished: stdoutDone && stderrDone,
            childPeakRSS: childPeakRSS, childPeakFootprint: childPeakFootprint, childRSSCount: childRSSCount, childFootprintCount: childFootprintCount)
    }
}
