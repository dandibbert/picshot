import Darwin
import Foundation
import Security
import CryptoKit
import CoreGraphics
import ImageIO
import PicShotCodecCore

enum CodecExportProcessError: LocalizedError {
    case busy, helperUnavailable, signature, invalidSource, invalidProtocol, timedOut, memoryLimit, exitUnconfirmed
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .busy: return "另一个 GIF / WebP / AVIF 导出仍在运行或清理，请稍后重试。"
        case .helperUnavailable: return "The signed Codec export helper is unavailable. Reinstall the complete PicShot app."
        case .signature: return "The Codec helper's bundle path or code signature could not be verified."
        case .invalidSource: return "Codec export requires a frozen PNG of at most 16 million pixels, or a local self-contained H.264 MP4 of at most 1 GiB."
        case .invalidProtocol: return "The Codec helper returned an invalid or oversized response."
        case .timedOut: return "The Codec export exceeded its time limit and was stopped."
        case .memoryLimit: return "The codec helper exceeded its sampled memory watchdog threshold and was stopped."
        case .exitUnconfirmed: return "The Codec helper has not confirmed exit. Further Codec exports are blocked until it exits."
        case .failed(let message): return "Codec export failed: \(message)"
        }
    }
}

/// The legacy route exists only for explicit matched diagnostic configurations.
/// There is no user preference or ambient environment override.
enum CodecPNGStagingMode: String, Codable, Sendable {
    case verifiedBytesOnly, legacyPreview
}

/// Production always resolves the current signed app's own executable. Explicit
/// injected configurations are for process/protocol tests, never an automatic
/// development fallback or an environment-controlled executable override.
struct CodecProcessConfiguration: @unchecked Sendable {
    let executable: @Sendable () throws -> URL
    let arguments: [String]
    let wallSeconds: TimeInterval
    let residentLimitBytes: UInt64
    let pngStagingMode: CodecPNGStagingMode
    let collectStagedPNGIdentityForDiagnostics: Bool
    let stagedPNGForDiagnostics: (@Sendable (URL) throws -> Void)?
    static var production: Self { Self(executable: { try CodecHelperExecutable.verified() }) }
    init(executable: @escaping @Sendable () throws -> URL,
         arguments: [String] = [],
         wallSeconds: TimeInterval = 300, residentLimitBytes: UInt64 = 1_073_741_824,
         pngStagingMode: CodecPNGStagingMode = .verifiedBytesOnly,
         collectStagedPNGIdentityForDiagnostics: Bool = false,
         stagedPNGForDiagnostics: (@Sendable (URL) throws -> Void)? = nil) {
        self.executable = executable; self.arguments = arguments
        self.wallSeconds = wallSeconds; self.residentLimitBytes = residentLimitBytes
        self.pngStagingMode = pngStagingMode; self.stagedPNGForDiagnostics = stagedPNGForDiagnostics
        self.collectStagedPNGIdentityForDiagnostics = collectStagedPNGIdentityForDiagnostics
    }
}

struct CodecHelperValidationTiming: Codable, Sendable {
    let phase: String
    let startedUptimeSeconds: Double, elapsedSeconds: Double
    let securityStatus: Int32?
}

enum CodecHelperExecutable {
    static func verified(bundleURL: URL = Bundle.main.bundleURL,
                         timing: (@Sendable (CodecHelperValidationTiming) -> Void)? = nil) throws -> URL {
        let pathStarted = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
        let bundle = bundleURL.standardizedFileURL
        guard bundle.isFileURL, bundle.pathExtension == "app" else { throw CodecExportProcessError.helperUnavailable }
        let executable = bundle.appendingPathComponent("Contents/Helpers/PicShotCodecHelper")
        guard bundle.resolvingSymlinksInPath().path == bundle.path, executable.resolvingSymlinksInPath().path == executable.path,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw CodecExportProcessError.signature }
        var file = stat()
        guard lstat(executable.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_nlink == 1 else { throw CodecExportProcessError.signature }
        if let timing { timing(.init(phase: "pathAndIdentity", startedUptimeSeconds: pathStarted,
                                     elapsedSeconds: ProcessInfo.processInfo.systemUptime - pathStarted, securityStatus: nil)) }
        for (index, url) in [bundle, executable].enumerated() {
            let name = index == 0 ? "app" : "helper"
            var code: SecStaticCode?
            let createStarted = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
            let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
            if let timing { timing(.init(phase: name + "CodeObject", startedUptimeSeconds: createStarted,
                                         elapsedSeconds: ProcessInfo.processInfo.systemUptime - createStarted, securityStatus: createStatus)) }
            guard createStatus == errSecSuccess, let code else { throw CodecExportProcessError.signature }
            let checkStarted = timing == nil ? 0 : ProcessInfo.processInfo.systemUptime
            let checkStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil)
            if let timing { timing(.init(phase: name + "Validity", startedUptimeSeconds: checkStarted,
                                         elapsedSeconds: ProcessInfo.processInfo.systemUptime - checkStarted, securityStatus: checkStatus)) }
            guard checkStatus == errSecSuccess else { throw CodecExportProcessError.signature }
        }
        return executable
    }
}

struct CodecExportProcessMetrics: Codable, Equatable, Sendable {
    var outcome = "failed"
    var lastStage = "admission"
    var elapsedSeconds: TimeInterval = 0
    var childLaunched = false
    var childProcessIdentifier: Int32?
    var helperExecutablePath: String?
    var pngStagingMode: String?
    var sourceSHA256: String?
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
    var verifiedWidth: Int?
    var verifiedHeight: Int?
    var verifiedFrameCount: Int?
    var verifiedDuration: Double?
    var sourceBytes: Int64?
    var configuredWallSeconds: TimeInterval = 300
    var configuredChildResidentLimitBytes: UInt64 = 1_073_741_824
    var sampleIntervalSeconds: TimeInterval = 0.05
    let admissionScope = "one native export child shared by GIF, WebP and AVIF; independent of the model-helper gate"
    let measurementScope = "main-process RSS/footprint plus this codec child's parent-polled RSS and child-reported RSS/footprint; sampled maxima, not a hard quota or kernel lifetime peaks; other helpers/framework services/GPU memory excluded"
}
struct CodecExportProcessSnapshot: Encodable, Sendable {
    let active: Bool
    let lastJob: CodecExportProcessMetrics?
}

/// One process-wide codec lease. Cancellation does not free admission until exit
/// and cleanup are confirmed. An unkillable child keeps the gate closed; later
/// calls may observe its eventual exit and finish only that owned cleanup.
actor CodecExportProcessService {
    static let shared = CodecExportProcessService()
    private let configuration: CodecProcessConfiguration
    private var active: CodecProcessJob?
    private var admissionToken: UUID?
    private var lastJob: CodecExportProcessMetrics?
    init(configuration: CodecProcessConfiguration = .production) { self.configuration = configuration }

    func export(sourceURL: URL, destinationURL: URL? = nil, options: CodecExportRequest,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let result = try await perform(source: .file(sourceURL), destination: destinationURL, options: options,
                                      publish: true, progress: progress)
        guard let url = result.destination else { throw CodecExportProcessError.invalidProtocol }; return url
    }
    /// Animation callers may own a trim-staging directory. The helper always
    /// reads its independent private source copy, never a file in that stage.
    func prepareAnimation(sourceURL: URL, options: CodecExportRequest,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> CodecPreparedArtifact {
        guard options.kind == .animation else { throw CodecExportProcessError.invalidSource }
        return try await perform(source: .file(sourceURL), destination: nil, options: options, publish: false, progress: progress)
    }
    func prepare(snapshot: ImageExportSnapshot, options: CodecExportRequest,
                 progress: (@Sendable (Double) -> Void)? = nil) async throws -> CodecPreparedArtifact {
        guard options.kind == .still else { throw CodecExportProcessError.invalidSource }
        return try await perform(source: .image(snapshot), destination: nil, options: options, publish: false, progress: progress)
    }
    private func perform(source: CodecProcessSource, destination: URL?, options: CodecExportRequest,
                         publish: Bool, progress: (@Sendable (Double) -> Void)?) async throws -> CodecPreparedArtifact {
        refreshStrandedJob()
        try options.validate(); try Task.checkCancellation()
        guard active == nil, let lease = NativeExportAdmission.shared.acquire() else { throw CodecExportProcessError.busy }
        admissionToken = lease
        let configuration = self.configuration, job = CodecProcessJob(configuration: configuration)
        active = job
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try Self.run(source: source, destinationURL: destination, options: options, publish: publish,
                                 configuration: configuration, job: job, progress: progress)
                }.value
            } onCancel: { job.cancel() }
            complete(job); return result
        } catch { complete(job); throw error }
    }
    func snapshot() -> CodecExportProcessSnapshot {
        refreshStrandedJob()
        return CodecExportProcessSnapshot(active: active != nil, lastJob: lastJob)
    }
    private func complete(_ job: CodecProcessJob) {
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

    private nonisolated static func run(source: CodecProcessSource, destinationURL: URL?, options: CodecExportRequest,
        publish: Bool, configuration: CodecProcessConfiguration, job: CodecProcessJob,
        progress: (@Sendable (Double) -> Void)?) throws -> CodecPreparedArtifact {
        let started = ProcessInfo.processInfo.systemUptime
        defer { job.update { $0.elapsedSeconds = max(0, ProcessInfo.processInfo.systemUptime - started) } }
        var directory: URL?
        var ownedDestinationDirectory: URL?
        var completed = false
        defer {
            let state = job.snapshot()
            if !state.childLaunched || state.childExitConfirmed {
                if let directory { job.cleanup(directory) }
                let removed = directory.map(removalConfirmed) ?? true
                job.update { $0.temporaryDirectoryRemoved = removed }
                if !completed, let ownedDestinationDirectory { try? FileManager.default.removeItem(at: ownedDestinationDirectory) }
            }
        }
        do {
            try job.checkCancellation()
            guard configuration.wallSeconds.isFinite, configuration.wallSeconds > 0, configuration.wallSeconds <= CodecExportLimits.wallSeconds,
                  configuration.residentLimitBytes > 0, configuration.residentLimitBytes <= CodecExportLimits.residentBytes else { throw CodecExportProcessError.invalidProtocol }
            job.update { $0.lastStage = "executableValidation" }
            let executable = try autoreleasepool { try configuration.executable() }
            job.update { $0.helperExecutablePath = executable.path }
            guard ProcessInfo.processInfo.systemUptime < started + configuration.wallSeconds else { throw CodecExportProcessError.timedOut }
            job.update { $0.lastStage = "destinationPreparation" }
            let destination: URL?
            // Codec bytes are validated into bounded Data and later published
            // exclusively. Unlike GIF's move path, no same-volume job is needed.
            // Keep the child independent of any caller-owned trim staging so
            // an unconfirmed exit cannot force the caller to retain that stage.
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            if publish, let destinationURL {
                guard destinationURL.isFileURL, destinationURL.pathExtension.lowercased() == options.format.rawValue else {
                    throw ImageExportError.invalidDestination
                }
                destination = destinationURL.standardizedFileURL
                try ImageExportService.requireUnoccupied(destination!)
            } else {
                destination = nil
            }
            let jobDirectory = try CodecTemporaryJob.create(in: root)
            directory = jobDirectory; job.setDirectory(jobDirectory, ownedDestinationDirectory: nil)
            job.update { $0.lastStage = "sourceSnapshot" }
            let inputURL = jobDirectory.appendingPathComponent(options.inputName)
            switch source {
            case .file(let url):
                try copySource(url, to: inputURL, maximumBytes: options.inputByteLimit, job: job,
                               deadline: started + configuration.wallSeconds)
            case .image(let snapshot):
                try CodecExportLimits.validateStillDimensions(width: snapshot.image.width, height: snapshot.image.height)
                var limits = ImageExportLimits.standard
                limits.maximumSourcePixels = CodecExportLimits.stillPixels
                limits.maximumEncodedBytes = CodecExportLimits.stillInputBytes
                job.update { $0.pngStagingMode = configuration.pngStagingMode.rawValue }
                let stagedBytes: Data
                switch configuration.pngStagingMode {
                case .verifiedBytesOnly:
                    let png = try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot,
                                                        cancellation: job.cancellation, limits: limits)
                    try job.checkCancellation()
                    try png.write(to: inputURL, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
                    job.update { $0.sourceBytes = Int64(png.count) }
                    stagedBytes = png
                case .legacyPreview:
                    // Preserve the original artifact and uses through staging;
                    // do not force its lifetime longer for the diagnostic control.
                    let png = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(),
                                                        cancellation: job.cancellation, limits: limits)
                    try job.checkCancellation()
                    try png.data.write(to: inputURL, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
                    job.update { $0.sourceBytes = Int64(png.data.count) }
                    stagedBytes = png.data
                }
                if configuration.collectStagedPNGIdentityForDiagnostics {
                    let sourceHash = SHA256.hash(data: stagedBytes).map { String(format: "%02x", $0) }.joined()
                    job.update { $0.sourceSHA256 = sourceHash }
                }
                try configuration.stagedPNGForDiagnostics?(inputURL)
            }
            try job.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < started + configuration.wallSeconds else { throw CodecExportProcessError.timedOut }
            let jobFiles = try CodecJobFiles.validate(directory: jobDirectory, request: options)
            job.setFiles(jobFiles)
            let inputData = try CodecExportProtocol.encodeRequestLine(options)
            let input = Pipe(), output = Pipe(), errors = Pipe()
            let process = Process()
            process.executableURL = executable; process.arguments = configuration.arguments
            process.currentDirectoryURL = jobDirectory
            // Never inherit smoke/recovery/helper-test selectors, model paths,
            // DYLD overrides, credentials, or the user's environment wholesale.
            process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": jobDirectory.path, "LANG": "en_US.UTF-8"]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            let reader = CodecProcessPipeState(progressLimit: CodecExportLimits.progressEvents)
            reader.start(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
            defer { reader.close() }
            job.update { $0.lastStage = "helperLaunch" }
            do { try process.run() }
            catch { reader.closeWriters(output: output, errors: errors); throw error }
            job.setProcess(process)
            job.update { $0.childProcessIdentifier = process.processIdentifier }
            // Observe the child before sending its request. Small encodes can
            // finish before the first 50 ms supervisor iteration.
            sample(job: job, child: process.processIdentifier)
            try? input.fileHandleForReading.close()
            reader.closeWriters(output: output, errors: errors)
            defer { try? input.fileHandleForWriting.close() }
            // Fail closed if nonblocking/SIGPIPE safety cannot be established.
            // Never risk delivering an early-exit SIGPIPE to the main app.
            let inputFD = input.fileHandleForWriting.fileDescriptor
            let inputFlags = fcntl(inputFD, F_GETFL)
            let inputSafe = inputFlags >= 0 && fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 &&
                fcntl(inputFD, F_SETFL, inputFlags | O_NONBLOCK) == 0
            var failure: Error?
            if inputSafe {
                do { try input.fileHandleForWriting.write(contentsOf: inputData) }
                catch { failure = CodecExportProcessError.failed("The helper request pipe closed before setup completed.") }
            } else {
                failure = CodecExportProcessError.failed("The helper control pipe could not be configured safely.")
                try? input.fileHandleForWriting.close()
            }
            var stopStarted: TimeInterval?
            var sentTerminate = false, sentKill = false
            job.update { $0.lastStage = "helperRunning" }
            while process.isRunning {
                let now = ProcessInfo.processInfo.systemUptime
                sample(job: job, child: process.processIdentifier)
                let snapshot = reader.snapshot()
                job.recordPipe(snapshot)
                if failure == nil, let error = snapshot.failure { failure = error }
                if job.isCancelled || Task.isCancelled { job.cancel(); failure = CancellationError() }
                if failure == nil, now - started >= configuration.wallSeconds { failure = CodecExportProcessError.timedOut }
                let metrics = job.snapshot()
                if failure == nil, (metrics.childSampledPeakResidentBytes ?? 0) > configuration.residentLimitBytes ||
                    (metrics.childReportedPeakResidentBytes ?? 0) > configuration.residentLimitBytes ||
                    (metrics.childReportedPeakPhysicalFootprintBytes ?? 0) > configuration.residentLimitBytes {
                    failure = CodecExportProcessError.memoryLimit
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
                        if inputSafe { try? input.fileHandleForWriting.write(contentsOf: CodecExportProtocol.cancelLine) }
                    }
                    let elapsed = now - stopStarted!
                    if elapsed >= 0.3, !sentTerminate { process.terminate(); sentTerminate = true }
                    if elapsed >= 0.8, !sentKill, process.isRunning { _ = kill(process.processIdentifier, SIGKILL); sentKill = true }
                    if elapsed >= 3.8, process.isRunning {
                        job.update { $0.outcome = "exitUnconfirmed" }
                        throw CodecExportProcessError.exitUnconfirmed
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit() // Already observed exited; never an unbounded running-child wait.
            job.recordExit(process)
            job.update { $0.lastStage = "helperResponse" }
            let drainDeadline = ProcessInfo.processInfo.systemUptime + 1
            while !reader.snapshot().finished, ProcessInfo.processInfo.systemUptime < drainDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let response = reader.snapshot(); job.recordPipe(response)
            sample(job: job, child: nil)
            if failure == nil, ProcessInfo.processInfo.systemUptime >= started + configuration.wallSeconds {
                failure = CodecExportProcessError.timedOut
            }
            if job.isCancelled || Task.isCancelled { job.cancel(); throw CancellationError() }
            if let failure { throw failure }
            if let error = response.failure { throw error }
            guard response.finished else { throw CodecExportProcessError.invalidProtocol }
            for value in reader.takeProgress() where value < 1 {
                progress?(value)
                try job.checkCancellation()
            }
            if let terminal = response.terminal, terminal.kind == .error { throw mappedError(terminal) }
            guard process.terminationStatus == 0, process.terminationReason == .exit else {
                throw CodecExportProcessError.failed("The helper exited unexpectedly with status \(process.terminationStatus).")
            }
            guard let terminal = response.terminal, terminal.kind == .result, response.lastProgress == 1,
                  response.progressCount >= 2 else { throw CodecExportProcessError.invalidProtocol }
            try terminal.validate(for: options)
            guard let bytes = terminal.outputBytes, let width = terminal.width, let height = terminal.height,
                  let frames = terminal.frameCount, let duration = terminal.duration, let previewBytes = terminal.previewBytes,
                  let digest = terminal.sha256 else { throw CodecExportProcessError.invalidProtocol }
            let statistics = job.snapshot()
            // A valid tiny helper may exit between spawn and proc_pidinfo. Its
            // authenticated terminal still supplies native sampled observations;
            // preserve missing parent-polled samples as missing, never zero.
            guard statistics.childReportedResidentSampleCount > 0, statistics.childReportedPeakResidentBytes != nil else {
                throw CodecExportProcessError.failed("The helper completed without usable child memory observations.")
            }
            if (statistics.childSampledPeakResidentBytes ?? 0) > configuration.residentLimitBytes ||
                (statistics.childReportedPeakResidentBytes ?? 0) > configuration.residentLimitBytes ||
                (statistics.childReportedPeakPhysicalFootprintBytes ?? 0) > configuration.residentLimitBytes {
                throw CodecExportProcessError.memoryLimit
            }
            job.update { $0.lastStage = "outputVerification" }
            let data = try readOwned(jobDirectory.appendingPathComponent(options.outputName), expectedBytes: bytes,
                                     limit: options.outputByteLimit, descriptor: try jobFiles.openOutput(), job: job, deadline: started + configuration.wallSeconds)
            try validateMagic(data, format: options.format)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                throw CodecExportProcessError.invalidProtocol
            }
            let previewData = try readOwned(jobDirectory.appendingPathComponent("preview.png"), expectedBytes: previewBytes,
                                            limit: CodecExportLimits.previewBytes, descriptor: try jobFiles.openPreview(), job: job, deadline: started + configuration.wallSeconds)
            let preview = try validatePreview(previewData, width: width, height: height)
            if case .image(let snapshot) = source {
                guard snapshot.image.width == width, snapshot.image.height == height else { throw CodecExportProcessError.invalidProtocol }
            }
            try job.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < started + configuration.wallSeconds else { throw CodecExportProcessError.timedOut }
            var saved = destination
            if publish {
                if saved == nil {
                    let outputRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                        .appendingPathComponent("PicShot-Codec-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    ownedDestinationDirectory = outputRoot
                    saved = outputRoot.appendingPathComponent("export." + options.format.rawValue)
                }
                job.update { $0.lastStage = "publication" }
                let format: ImageExportFormat = options.format == .webp ? .webp : .avif
                let imageOptions = ImageExportOptions(format: format, quality: Double(options.quality) / 100,
                    lossless: options.lossless, preserveAlpha: options.preserveAlpha, alphaQuality: Double(options.alphaQuality) / 100)
                let artifact = ImageExportArtifact(data: data, options: imageOptions, width: width, height: height,
                                                   pageCount: 1, firstPreview: preview, sourceURL: source.url)
                try ImageExportService.publish(artifact, to: saved!, cancellation: job.cancellation, beforeCommit: {
                    guard ProcessInfo.processInfo.systemUptime < started + configuration.wallSeconds else { throw CodecExportProcessError.timedOut }
                })
                job.markPublished()
            }
            completed = true
            job.update { $0.outputBytes = bytes; $0.verifiedWidth = width; $0.verifiedHeight = height; $0.verifiedFrameCount = frames; $0.verifiedDuration = duration
                $0.outcome = "succeeded"; $0.lastStage = "stagingCleanup" }
            job.cleanup(jobDirectory)
            guard removalConfirmed(jobDirectory) else { throw CodecExportProcessError.failed("Codec staging cleanup could not be confirmed.") }
            job.update { $0.temporaryDirectoryRemoved = true; $0.lastStage = "complete" }
            sample(job: job, child: nil)
            progress?(1)
            return CodecPreparedArtifact(data: data, preview: preview, width: width, height: height,
                                         frameCount: frames, duration: duration, destination: saved)
        } catch {
            let outcome: String
            if error is CancellationError { outcome = "cancelled" }
            else if let specific = error as? CodecExportProcessError {
                switch specific { case .timedOut: outcome = "timedOut"; case .memoryLimit: outcome = "memoryLimit"
                case .exitUnconfirmed: outcome = "exitUnconfirmed"; default: outcome = "failed" }
            } else { outcome = "failed" }
            job.update { $0.outcome = outcome }
            throw error
        }
    }

    private nonisolated static func copySource(_ source: URL, to target: URL, maximumBytes: Int64, job: CodecProcessJob, deadline: TimeInterval) throws {
        guard source.isFileURL else { throw CodecExportProcessError.invalidSource }
        let values = try source.resourceValues(forKeys: [.volumeIsLocalKey, .isSymbolicLinkKey])
        guard values.volumeIsLocal == true, values.isSymbolicLink != true else { throw CodecExportProcessError.invalidSource }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CodecExportProcessError.invalidSource }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { throw CodecExportProcessError.invalidSource }
        let targetDescriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard targetDescriptor >= 0 else { throw CodecExportProcessError.invalidSource }
        let output = FileHandle(fileDescriptor: targetDescriptor, closeOnDealloc: true); defer { try? output.close() }
        var copied: Int64 = 0
        while true {
            try job.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodecExportProcessError.timedOut }
            let count: Int = try autoreleasepool {
                let data = try input.read(upToCount: 1_048_576) ?? Data()
                guard copied + Int64(data.count) <= maximumBytes else { throw CodecExportProcessError.invalidSource }
                if !data.isEmpty { try output.write(contentsOf: data) }
                return data.count
            }
            if count == 0 { break }
            copied += Int64(count)
            job.recordParent(GIFResourceMemoryReading.current())
        }
        var final = stat()
        guard copied == info.st_size, fstat(descriptor, &final) == 0,
              final.st_dev == info.st_dev, final.st_ino == info.st_ino, final.st_size == info.st_size,
              final.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
        else { throw CodecExportProcessError.invalidSource }
        try output.synchronize()
        job.update { $0.sourceBytes = copied }
    }
    private nonisolated static func readOwned(_ url: URL, expectedBytes: Int, limit: Int, descriptor fd: Int32,
        job: CodecProcessJob, deadline: TimeInterval) throws -> Data {
        guard fd >= 0 else { throw CodecExportProcessError.invalidProtocol }
        defer { Darwin.close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_uid == geteuid(), initial.st_nlink == 1, expectedBytes > 0,
              expectedBytes <= limit, initial.st_size == expectedBytes else { throw CodecExportProcessError.invalidProtocol }
        var result = Data(); result.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count < expectedBytes {
            try job.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodecExportProcessError.timedOut }
            let count = Darwin.read(fd, &buffer, min(buffer.count, expectedBytes - result.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodecExportProcessError.invalidProtocol }
            result.append(contentsOf: buffer.prefix(count)); job.recordParent(GIFResourceMemoryReading.current())
        }
        var final = stat(), path = stat()
        guard fstat(fd, &final) == 0, lstat(url.path, &path) == 0,
              final.st_dev == initial.st_dev, final.st_ino == initial.st_ino, final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              path.st_dev == final.st_dev, path.st_ino == final.st_ino, path.st_nlink == 1 else { throw CodecExportProcessError.invalidProtocol }
        return result
    }
    static func validateMagic(_ data: Data, format: CodecExportFormat) throws {
        if format == .webp {
            guard data.count >= 20, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8) else {
                throw CodecExportProcessError.invalidProtocol
            }
            let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[4 + $1]) << UInt32(8 * $1) }
            guard UInt64(size) + 8 == data.count else { throw CodecExportProcessError.invalidProtocol }
        } else {
            guard data.count >= 24, data[4..<8] == Data("ftyp".utf8) else { throw CodecExportProcessError.invalidProtocol }
            let box = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[$1]) }
            guard box >= 24, box <= min(data.count, 4096), box % 4 == 0 else { throw CodecExportProcessError.invalidProtocol }
            let brands = [Data(data[8..<12])] + stride(from: 16, to: Int(box), by: 4).map { Data(data[$0..<($0 + 4)]) }
            guard brands.contains(Data("avif".utf8)), !brands.contains(Data("avis".utf8)) else { throw CodecExportProcessError.invalidProtocol }
        }
    }
    static func validatePreview(_ data: Data, width: Int, height: Int) throws -> CGImage {
        try CodecExportLimits.validateStillDimensions(width: width, height: height)
        guard data.starts(with: Data([137,80,78,71,13,10,26,10])), data.count <= CodecExportLimits.previewBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= CodecExportLimits.previewDimension, h <= CodecExportLimits.previewDimension,
              w <= CodecExportLimits.previewBytes / 4 / h else { throw CodecExportProcessError.invalidProtocol }
        // Match the helper's exact two permitted raster plans, including its
        // smaller fallback for incompressible PNG. Never accept a source-sized
        // or arbitrary unrelated thumbnail merely because it fits the byte cap.
        let expectedSize = [CodecExportLimits.previewDimension, 1_000].contains { dimension in
            let scale = min(1, Double(dimension) / Double(max(width, height)))
            return w == max(1, Int((Double(width) * scale).rounded())) &&
                h == max(1, Int((Double(height) * scale).rounded()))
        }
        guard expectedSize,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.bytesPerRow <= CodecExportLimits.previewBytes / image.height else { throw CodecExportProcessError.invalidProtocol }
        return image
    }
    private nonisolated static func sample(job: CodecProcessJob, child: Int32?) {
        job.recordParent(GIFResourceMemoryReading.current())
        guard let child else { return }
        var info = proc_taskinfo()
        let count = proc_pidinfo(child, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        if count == Int32(MemoryLayout<proc_taskinfo>.size) { job.recordChildRSS(info.pti_resident_size) }
    }
    private nonisolated static func mappedError(_ event: CodecExportResponse) -> Error {
        switch event.errorCode {
        case .cancelled: return CancellationError()
        case .deadline: return CodecExportProcessError.timedOut
        case .memoryLimit: return CodecExportProcessError.memoryLimit
        default: return CodecExportFailure(event.errorCode ?? .failed)
        }
    }
    fileprivate nonisolated static func removalConfirmed(_ url: URL) -> Bool {
        var value = stat(); return lstat(url.path, &value) != 0 && errno == ENOENT
    }
}

private final class CodecProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics = CodecExportProcessMetrics()
    let cancellation = ImageExportCancellation()
    private var stranded = false
    private var published = false
    private var process: Process?
    private var directory: URL?
    private var ownedDestinationDirectory: URL?
    private var files: CodecJobFiles?
    func setFiles(_ value: CodecJobFiles) { lock.lock(); files = value; lock.unlock() }
    func cleanup(_ directory: URL) {
        lock.lock(); let files = files; lock.unlock()
        if let files { files.cleanupAfterParentLoss() } else { CodecTemporaryJob.removeOwned(directory) }
    }
    init(configuration: CodecProcessConfiguration) {
        metrics.configuredWallSeconds = configuration.wallSeconds
        metrics.configuredChildResidentLimitBytes = configuration.residentLimitBytes
    }
    func update(_ body: (inout CodecExportProcessMetrics) -> Void) { lock.lock(); defer { lock.unlock() }; body(&metrics) }
    func snapshot() -> CodecExportProcessMetrics { lock.lock(); defer { lock.unlock() }; return metrics }
    func cancel() { cancellation.cancel() }
    var isCancelled: Bool { cancellation.isCancelled }
    func checkCancellation() throws { if isCancelled || Task.isCancelled { cancel(); throw CancellationError() } }
    func setProcess(_ value: Process) { lock.lock(); defer { lock.unlock() }; process = value; metrics.childLaunched = true }
    func setDirectory(_ value: URL, ownedDestinationDirectory: URL?) {
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
    func recordPipe(_ value: CodecProcessPipeSnapshot) {
        update {
            $0.stdoutBytes = value.stdoutBytes; $0.stderrBytes = value.stderrBytes; $0.stderrTruncated = value.stderrTruncated
            $0.childReportedPeakResidentBytes = value.childPeakRSS; $0.childReportedPeakPhysicalFootprintBytes = value.childPeakFootprint
            $0.childReportedResidentSampleCount = value.childRSSCount; $0.childReportedPhysicalFootprintSampleCount = value.childFootprintCount
            if value.terminal?.kind == .error {
                $0.helperErrorCode = value.terminal?.errorCode?.rawValue
                $0.helperErrorMessage = nil
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
        if let files { files.cleanupAfterParentLoss() } else if let directory { CodecTemporaryJob.removeOwned(directory) }
        metrics.temporaryDirectoryRemoved = directory.map(CodecExportProcessService.removalConfirmed) ?? true
        if !published, let ownedDestinationDirectory { try? FileManager.default.removeItem(at: ownedDestinationDirectory) }
        guard metrics.temporaryDirectoryRemoved else { return false }
        // Keep the recovery marker until the owning actor observes completion.
        // The shared admission may reclaim this job before that actor wakes.
        return true
    }
}

private struct CodecProcessPipeSnapshot {
    let failure: Error?
    let terminal: CodecExportResponse?
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
private final class CodecProcessPipeState: @unchecked Sendable {
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
    private var terminal: CodecExportResponse?
    private var childPeakRSS: UInt64?, childPeakFootprint: UInt64?
    private var childRSSCount = 0, childFootprintCount = 0
    private var stopping = false
    init(progressLimit: Int) { self.progressLimit = progressLimit }
    func start(stdout: FileHandle, stderr: FileHandle) {
        DispatchQueue(label: "PicShot.Codec.stdout").async { self.read(stdout, isError: false) }
        DispatchQueue(label: "PicShot.Codec.stderr").async { self.read(stderr, isError: true) }
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
            else { stdoutDone = true; if !pending.isEmpty, failure == nil { failure = CodecExportProcessError.invalidProtocol } }
        }
        do {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw CodecExportProcessError.invalidProtocol
            }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while !shouldStop {
                var polling = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&polling, 1, 50)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0, polling.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                    throw CodecExportProcessError.invalidProtocol
                }
                if ready == 0 { continue }
                // FileHandle.read(upToCount:) can wait for a full requested
                // chunk or EOF. POSIX read forwards a short progress line now,
                // while the helper is still alive and cancellation can act.
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else { throw CodecExportProcessError.invalidProtocol }
                autoreleasepool {
                    let data = Data(buffer.prefix(count))
                    lock.lock(); consume(data, isError: isError); lock.unlock()
                }
            }
        } catch {
            lock.lock(); if failure == nil { failure = CodecExportProcessError.invalidProtocol }; lock.unlock()
        }
    }
    private func consume(_ data: Data, isError: Bool) {
        if isError {
            stderrBytes = min(Int.max - data.count, stderrBytes) + data.count
            let remaining = max(0, CodecExportLimits.stderrBytes - stderrPrefix.count)
            stderrPrefix.append(data.prefix(remaining)); return
        }
        guard stdoutBytes <= CodecExportLimits.stdoutBytes - data.count else { failure = CodecExportProcessError.invalidProtocol; return }
        stdoutBytes += data.count
        guard failure == nil else { return }
        for byte in data {
            if byte == 10 {
                do {
                    guard pending.count + 1 <= CodecExportLimits.eventBytes else { throw CodecExportProcessError.invalidProtocol }
                    try autoreleasepool { try accept(CodecExportProtocol.decodeResponseLine(pending)) }
                }
                catch { failure = CodecExportProcessError.invalidProtocol }
                pending.removeAll(keepingCapacity: true)
                if failure != nil { return }
            } else {
                guard pending.count < CodecExportLimits.eventBytes else { failure = CodecExportProcessError.invalidProtocol; return }
                pending.append(byte)
            }
        }
    }
    private func accept(_ event: CodecExportResponse) throws {
        guard terminal == nil else { throw CodecExportProcessError.invalidProtocol }
        if let bytes = event.sampledPeakResidentBytes { childPeakRSS = max(childPeakRSS ?? bytes, bytes) }
        if let bytes = event.sampledPeakPhysicalFootprintBytes { childPeakFootprint = max(childPeakFootprint ?? bytes, bytes) }
        if let count = event.residentSampleCount { childRSSCount = max(childRSSCount, count) }
        if let count = event.physicalFootprintSampleCount { childFootprintCount = max(childFootprintCount, count) }
        switch event.kind {
        case .progress:
            guard let fraction = event.fraction, fraction.isFinite, (0...1).contains(fraction),
                  fraction >= (lastProgress ?? 0), (lastProgress != nil || fraction == 0),
                  progressCount < progressLimit else { throw CodecExportProcessError.invalidProtocol }
            lastProgress = fraction; progressCount += 1; progress.append(fraction)
        case .result, .error: terminal = event
        }
    }
    func takeProgress() -> [Double] { lock.lock(); defer { lock.unlock() }; let values = progress; progress.removeAll(keepingCapacity: true); return values }
    func snapshot() -> CodecProcessPipeSnapshot {
        lock.lock(); defer { lock.unlock() }
        return CodecProcessPipeSnapshot(failure: failure, terminal: terminal, lastProgress: lastProgress,
            progressCount: progressCount, stdoutBytes: stdoutBytes, stderrBytes: stderrBytes,
            stderrTruncated: stderrBytes > CodecExportLimits.stderrBytes, finished: stdoutDone && stderrDone,
            childPeakRSS: childPeakRSS, childPeakFootprint: childPeakFootprint, childRSSCount: childRSSCount, childFootprintCount: childFootprintCount)
    }
}

private enum CodecProcessSource: @unchecked Sendable {
    case file(URL), image(ImageExportSnapshot)
    var url: URL? { switch self { case .file(let url): return url.standardizedFileURL.resolvingSymlinksInPath(); case .image(let value): return value.sourceURL } }
}
struct CodecPreparedArtifact: @unchecked Sendable {
    let data: Data
    let preview: CGImage
    let width: Int
    let height: Int
    let frameCount: Int
    let duration: Double
    let destination: URL?
}
