import Foundation
import PicShotCodecCore

/// Explicit synthetic installed acceptance. Call the original input fixture
/// first; its media, assertions and privacy boundaries are neither replaced nor
/// weakened here. The separate native reader must pass before acceptance.
@MainActor
enum RecordingInputExportSmokeFixture {
    private typealias Oracle = RecordingInputExportOracle
    static let cooperativeDeadlineSeconds = 120.0
    enum Route: String, CaseIterable { case mp4, gif, webpLossless, webpLossy }

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        try Oracle.require(evidenceDirectory.isFileURL, "Evidence must be a local directory")
        let files = FileManager.default
        for name in Oracle.mediaNames + [Oracle.reportName, Oracle.independentReportName] {
            try Oracle.require(!files.fileExists(atPath: evidenceDirectory.appendingPathComponent(name).path),
                               "Refusing to replace existing derived witness: \(name)")
        }
        let source = evidenceDirectory.appendingPathComponent("recording-input.mp4")
        let priorURL = evidenceDirectory.appendingPathComponent("recording-input.json")
        let priorData = try Oracle.boundedData(priorURL, maximum: Oracle.maximumReportBytes)
        guard let prior = try JSONSerialization.jsonObject(with: priorData) as? [String: Any] else {
            throw NSError(domain: "PicShot.RecordingInputExport", code: 9)
        }
        try Oracle.require(prior["status"] as? String == "passed" && prior["decodedFrames"] as? Int == 22,
                           "The unchanged original input fixture must pass first")
        let sourceHash = try Oracle.hash(source)
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-Recording-Input-Export-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Children use independently owned, copied jobs. This private fixture
        // root is never a child's working directory or an unconfirmed live job.
        defer { try? files.removeItem(at: root) }
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + cooperativeDeadlineSeconds
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let range = try VideoTrimRange(start: Oracle.start, end: Oracle.end, sourceDuration: 2.2)
        var report: [String: Any] = [
            "schemaVersion": 1, "status": "running", "profile": "synthetic-recording-input-derived",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "sourceFile": "recording-input.mp4", "sourceSHA256": sourceHash,
            "selectedStartSeconds": Oracle.start, "selectedEndSeconds": Oracle.end,
            "selectedDurationSeconds": Oracle.duration, "animationFrameRate": Oracle.animationFPS,
            "expectedAnimationFrames": Oracle.animationFrames, "width": Oracle.width, "height": Oracle.height,
            "captureStarted": false, "permissionRequested": false, "globalInputPosted": false,
            "regionRelocationTested": false, "typedTextCaptured": false,
            "maximumMediaBytes": Oracle.maximumFileBytes, "maximumReportBytes": Oracle.maximumReportBytes,
            "maximumDecodedRGBABytesPerFrame": Oracle.width * Oracle.height * 4,
            "maximumStoredFrameObservations": Oracle.sourceFrames + Oracle.selectedFrames + Oracle.animationFrames,
            "maximumStoredPacketTimingsPerMovie": Oracle.sourceFrames,
            "cooperativeDeadlineSeconds": cooperativeDeadlineSeconds,
            "independentValidationRequired": true, "independentReport": Oracle.independentReportName,
            "webPPixelValidation": "pending separate PSCodecAnimationNext reader; ImageIO is not an all-frame WebP oracle",
            "samplingScope": "41 animation request ticks and format-specific stored delays; actual selected-MP4 sample times are recorded separately",
            "pixelToleranceScope": "decoded source and selected H.264 frames, never pristine desktop RGB; codec feature counts/centroids plus per-region RGB error",
            "resourceScope": "bounded synthetic jobs, sequential frame reads and scalar observations; existing child caps unchanged; no sustained RSS or hardware capture claim",
            "temporaryDirectoryRemoved": false
        ]
        report["coldParentMemory"] = try Oracle.object(GIFResourceMemoryReading.current())
        let reportURL = evidenceDirectory.appendingPathComponent(Oracle.reportName)
        do {
            try Oracle.check(deadline)
            let original = try await Oracle.movie(source, selected: false, deadline: deadline)
            report["sourceDecode"] = ["frames": original.frameCount, "duration": original.duration, "rawPacketEnd": original.rawPacketEnd,
                "packetTiming": try Oracle.object(original.packetTiming)]
            var exports: [[String: Any]] = []
            for (route, name) in zip(Route.allCases, Oracle.mediaNames) {
                try Oracle.check(deadline)
                let output = evidenceDirectory.appendingPathComponent(name)
                _ = try await export(route, source: source, output: output, range: range)
                try Oracle.check(deadline)
                let data = try Oracle.boundedData(output)
                var result: [String: Any] = ["route": route.rawValue, "file": name, "bytes": data.count,
                                             "sha256": try Oracle.hash(output)]
                if route != .mp4 { result["process"] = try await process(route, requireLaunched: true) }
                try Oracle.require(try Oracle.hash(source) == sourceHash, "Export modified original input bytes")
                try noStages(evidenceDirectory)
                exports.append(result)
                if route == .mp4 { report["parentMemoryAfterFirstTrim"] = try Oracle.object(GIFResourceMemoryReading.current()) }
            }
            report["lateParentMemory"] = try Oracle.object(GIFResourceMemoryReading.current())
            report["exports"] = exports
            let selectedURL = evidenceDirectory.appendingPathComponent(Oracle.mediaNames[0])
            let selected = try await Oracle.movie(selectedURL, selected: true, source: original, deadline: deadline)
            report["selectedMP4"] = ["frames": selected.frameCount, "duration": selected.duration,
                                      "rawPacketEnd": selected.rawPacketEnd, "packetTiming": try Oracle.object(selected.packetTiming), "sourceFrameIndices": selected.observations.map(\.index)]
            report["gifFrames"] = try Oracle.object(Oracle.gif(evidenceDirectory.appendingPathComponent(Oracle.mediaNames[1]),
                selectedURL: selectedURL, selected: selected, deadline: deadline))
            report["destinationSentinels"] = try await sentinels(source: source, root: root, range: range, deadline: deadline)
            report["cancellations"] = try await cancellations(source: source, root: root, range: range, deadline: deadline)
            try Oracle.require(try Oracle.hash(source) == sourceHash, "Failure/cancellation checks modified original bytes")
            try Oracle.require(try Oracle.boundedData(priorURL, maximum: Oracle.maximumReportBytes) == priorData,
                               "Original159 input report changed")
            try noStages(evidenceDirectory); try noStages(root)
            try files.removeItem(at: root)
            report["temporaryDirectoryRemoved"] = true
            sampler.stop()
            report["finalParentMemory"] = try Oracle.object(GIFResourceMemoryReading.current())
            report["parentMemorySamples"] = try Oracle.object(sampler.snapshot())
            report["sourcePreserved"] = true; report["original159ReportPreserved"] = true
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            report["status"] = "exported-awaiting-independent-validation"
            try Oracle.write(report, to: reportURL)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            report["gifProcessActive"] = await GIFExporter.processResourceSnapshot().active
            report["codecProcessActive"] = await CodecExportProcessService.shared.snapshot().active
            // Do not remove child-owned jobs: services retain their admission
            // leases until actual exit. Only this fixture-owned root is removed.
            do { try files.removeItem(at: root); report["temporaryDirectoryRemoved"] = true }
            catch { report["cleanupError"] = error.localizedDescription }
            try? Oracle.write(report, to: reportURL)
            throw error
        }
    }

    static func options(lossless: Bool) -> CodecExportRequest {
        CodecExportRequest(kind: .animation, format: .webp, quality: 80, lossless: lossless,
            animation: .init(frameRate: Oracle.animationFPS, maximumDimension: Oracle.width,
                             maximumFrames: Oracle.animationFrames, maximumDuration: 3))
    }
    static var gifOptions: GIFExportOptions {
        .init(frameRate: Double(Oracle.animationFPS), maximumDimension: Oracle.width,
              maximumDuration: 3, maximumFrames: Oracle.animationFrames)
    }
    private static func export(_ route: Route, source: URL, output: URL, range: VideoTrimRange,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let destination = try VideoExportDestination(url: output, preserving: source)
        switch route {
        case .mp4: return try await VideoTrimExporter.export(sourceURL: source, destination: destination, range: range, progress: progress)
        case .gif: return try await VideoTrimExporter.exportGIF(sourceURL: source, destination: destination, range: range, options: gifOptions, progress: progress)
        case .webpLossless, .webpLossy:
            return try await VideoTrimExporter.exportWebP(sourceURL: source, destination: destination, range: range,
                options: options(lossless: route == .webpLossless), progress: progress)
        }
    }
    private static func process(_ route: Route, requireLaunched: Bool) async throws -> Any {
        if route == .gif {
            let state = await GIFExporter.processResourceSnapshot()
            try Oracle.require(!state.active, "GIF helper exit remains unconfirmed")
            guard let job = state.lastJob else { throw NSError(domain: "PicShot.RecordingInputExport", code: 10) }
            try Oracle.require(!requireLaunched || job.childLaunched, "GIF child did not launch")
            try Oracle.require(job.childExitConfirmed && job.temporaryDirectoryRemoved, "GIF child cleanup remains unconfirmed")
            return try Oracle.object(job)
        }
        let state = await CodecExportProcessService.shared.snapshot()
        try Oracle.require(!state.active, "Codec helper exit remains unconfirmed")
        guard let job = state.lastJob else { throw NSError(domain: "PicShot.RecordingInputExport", code: 11) }
        try Oracle.require(!requireLaunched || job.childLaunched, "Codec child did not launch")
        try Oracle.require(job.childExitConfirmed && job.temporaryDirectoryRemoved, "Codec child cleanup remains unconfirmed")
        return try Oracle.object(job)
    }
    private static func noStages(_ root: URL) throws {
        try Oracle.require(!FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".picshot-") },
                           "Owned exporter stage remains after confirmed helper exit")
    }
    private static func sentinels(source: URL, root: URL, range: VideoTrimRange, deadline: Double) async throws -> [[String: Any]] {
        let sentinel = Data("existing destination must survive derived input export".utf8)
        var results: [[String: Any]] = []
        for route in Route.allCases {
            try Oracle.check(deadline)
            let output = root.appendingPathComponent("existing-\(route.rawValue).\(route == .mp4 ? "mp4" : route == .gif ? "gif" : "webp")")
            try sentinel.write(to: output, options: .withoutOverwriting)
            do { _ = try await export(route, source: source, output: output, range: range); throw NSError(domain: "ExpectedSentinelRejection", code: 1) }
            catch VideoTrimError.destinationExists { }
            try Oracle.require(try Data(contentsOf: output) == sentinel, "Existing destination sentinel changed")
            try noStages(root)
            results.append(["route": route.rawValue, "existingDestinationPreserved": true])
        }
        return results
    }
    private static func cancellations(source: URL, root: URL, range: VideoTrimRange, deadline: Double) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        for route in Route.allCases {
            let phases = route == .mp4 ? ["trim-start"] : ["trim-start", "helper-progress", "before-publication"]
            for phase in phases {
                try Oracle.check(deadline)
                let output = root.appendingPathComponent("cancel-\(route.rawValue)-\(phase).\(route == .mp4 ? "mp4" : route == .gif ? "gif" : "webp")")
                let cancellation = RecordingInputExportCancellation()
                let task = Task {
                    try await export(route, source: source, output: output, range: range) { value in
                        if phase == "trim-start" ? value == 0
                            : phase == "before-publication" ? value >= 0.99
                            : value > (route == .gif ? 0.4 : 0.25) && value < 0.99 { cancellation.request() }
                    }
                }
                cancellation.install { task.cancel() }
                defer { cancellation.clear(); task.cancel() }
                do { _ = try await task.value; throw NSError(domain: "ExpectedExportCancellation", code: 1) }
                catch is CancellationError { }
                try Oracle.check(deadline)
                try Oracle.require(cancellation.requested && !FileManager.default.fileExists(atPath: output.path),
                                   "Cancelled export published or missed the requested checkpoint")
                var result: [String: Any] = ["route": route.rawValue, "phase": phase, "destinationAbsent": true]
                if phase != "trim-start" { result["process"] = try await process(route, requireLaunched: true) }
                try noStages(root)
                results.append(result)
            }
        }
        return results
    }
}

/// Handles cancellation requested before task installation without retaining
/// the operation after completion. Does not modify any production seam.
private final class RecordingInputExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var stopped = false
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func install(_ action: @escaping () -> Void) {
        lock.lock(); self.action = action; let invoke = stopped; lock.unlock()
        if invoke { action() }
    }
    func request() {
        lock.lock(); stopped = true; let action = action; lock.unlock()
        action?()
    }
    func clear() { lock.lock(); action = nil; lock.unlock() }
}
