import AppKit
import Foundation

/// Bounded installed-app observation of the *real* export sheet/encoding/
/// decoded-preview/publication/close path. Uses the existing Mach task sampler;
/// owned-reference counters supplement, never replace, RSS/footprint evidence.
@MainActor
enum ImageExportResourceFixture {
    enum Profile: String {
        case installed = "installed-1440x900-four-cycles"
        case quickTest = "unit-160x100-two-cycles"
        var width: Int { self == .installed ? 1_440 : 160 }
        var height: Int { self == .installed ? 900 : 100 }
        var measuredCycles: Int { self == .installed ? 4 : 2 }
    }
    private static let formats: [ImageExportFormat] = [.png, .jpeg, .bmp, .pdf]
    private static let reportName = "image-export-resource.json"

    static func verify(evidenceDirectory: URL, profile: Profile = .installed) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Export-Resource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        var report: [String: Any] = [
            "status": "running", "profile": profile.rawValue,
            "sourceWidth": profile.width, "sourceHeight": profile.height,
            "warmupCycles": 1, "measuredCycles": profile.measuredCycles,
            "formatsPerCycle": formats.map(\.title), "serialExportsPerCycle": formats.count,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval,
            "memoryScope": "Main-process Mach RSS and physical footprint; excludes WindowServer, GPU and other processes",
            "peakScope": "50 ms timer plus explicit boundary samples during source creation, encoding, byte-derived preview, saving, closing and cleanup; sampled maxima can miss short native peaks and are not kernel lifetime peaks",
            "cleanupScope": "Weak controller release, real active-session count, shared OperationQueue count, and owned temporary-file cleanup after every serial export and cycle; these do not measure all native allocations",
            "resourceScope": "One warm-up followed by repeated fixed medium-resolution cycles. Measurements and deltas are observational; no pass threshold, plateau, zero-leak, maximum-resolution or long-running claim",
            "diskScope": "One private temporary output at a time, removed after the exact-byte-count save check; no source file is written",
            "sourceProvenance": "Deterministic original synthetic RGBA color pattern",
            "maximumSourcePixels": ImageExportLimits.standard.maximumSourcePixels,
            "maximumEncodedBytes": ImageExportLimits.standard.maximumEncodedBytes,
            "maximumDecodedPreviewBytesPerPage": ImageExportLimits.standard.maximumPreviewBytes,
            "maximumConcurrentEncoders": ImageExportService.queue.maxConcurrentOperationCount,
            "cooperativeDeadlineSeconds": 120, "outerTimeoutScope": "Installed smoke launcher owns timeout for non-preemptible native calls",
            "networkAttempted": false, "screenCaptureAttempted": false, "preferencesWritten": false,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "temporaryDirectoryRemoved": false
        ]
        do {
            try await drain(deadline: deadline)
            guard ImageExportController.activeSessionCount == 0 else { throw failure("Other export sessions would contaminate resource observation") }
            report["beforeWarmup"] = try object(GIFResourceMemoryReading.current())
            report["phase"] = "warmup"
            let warmup = try await cycle(index: 0, directory: directory, profile: profile, deadline: deadline)
            report["warmup"] = warmup.report
            let baseline = GIFResourceMemoryReading.current()
            guard baseline.residentBytes != nil, baseline.physicalFootprintBytes != nil else { throw failure("Main-process RSS or physical-footprint measurement is unavailable") }
            report["baselineAfterWarmup"] = try object(baseline)
            var cycles: [[String: Any]] = [], readings: [GIFResourceMemoryReading] = []
            for index in 1...profile.measuredCycles {
                report["phase"] = "measured-cycle-\(index)"
                let run = try await cycle(index: index, directory: directory, profile: profile, deadline: deadline)
                cycles.append(run.report); readings.append(run.settled)
                report["cycles"] = cycles
                try write(report, directory: evidenceDirectory)
            }
            report["settledAfterCycles"] = try readings.map { try object($0) }
            report["residentGrowthFromWarmupBytes"] = readings.map { delta($0.residentBytes, baseline.residentBytes) }
            report["physicalFootprintGrowthFromWarmupBytes"] = readings.map { delta($0.physicalFootprintBytes, baseline.physicalFootprintBytes) }
            report["residentLastIntervalGrowthBytes"] = delta(readings.last?.residentBytes, readings.dropLast().last?.residentBytes)
            report["physicalFootprintLastIntervalGrowthBytes"] = delta(readings.last?.physicalFootprintBytes, readings.dropLast().last?.physicalFootprintBytes)
            report["completedMeasuredCycles"] = cycles.count
            report["activeSessionsAfterAllCycles"] = ImageExportController.activeSessionCount
            report["queuedOrRunningJobsAfterAllCycles"] = ImageExportService.queue.operationCount
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw failure("Resource fixture left an output or partial file") }
            try FileManager.default.removeItem(at: directory)
            report["temporaryDirectoryRemoved"] = true; report["phase"] = "complete"; report["status"] = "observed"
            try write(report, directory: evidenceDirectory)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["activeSessionsAtFailure"] = ImageExportController.activeSessionCount
            report["queuedOrRunningJobsAtFailure"] = ImageExportService.queue.operationCount
            do { try FileManager.default.removeItem(at: directory); report["temporaryDirectoryRemoved"] = true }
            catch { report["cleanupError"] = error.localizedDescription }
            try? write(report, directory: evidenceDirectory)
            throw error
        }
    }

    private static func cycle(index: Int, directory: URL, profile: Profile, deadline: TimeInterval) async throws
        -> (report: [String: Any], settled: GIFResourceMemoryReading) {
        try check(deadline)
        let before = GIFResourceMemoryReading.current(), sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        // Each helper returns only small metadata and a weak reference. Source,
        // snapshot, encoded bytes and preview images leave scope before settling.
        var outputs: [[String: Any]] = [], released = 0
        for format in formats {
            let result = try await exportOne(format: format, directory: directory, profile: profile, deadline: deadline, sampler: sampler)
            try await drain(deadline: deadline)
            autoreleasepool { }
            try await Task.sleep(nanoseconds: 60_000_000)
            let alive = result.controller.value != nil
            guard !alive, ImageExportController.activeSessionCount == 0 else { throw failure("Closed export controller/session was retained") }
            var entry = result.report
            entry["controllerReleased"] = !alive
            entry["activeSessionsAfterClose"] = ImageExportController.activeSessionCount
            entry["queuedOrRunningJobsAfterClose"] = ImageExportService.queue.operationCount
            entry["ownedTemporaryFilesAfterDelete"] = try FileManager.default.contentsOfDirectory(atPath: directory.path).count
            outputs.append(entry); released += 1; sampler.sample()
        }
        // Multiple settled observations per cycle, rather than inferring a
        // plateau from one sample or from weak-reference counts.
        var settledSamples: [[String: Any]] = []
        for _ in 0..<3 {
            try check(deadline); try await Task.sleep(nanoseconds: 80_000_000)
            autoreleasepool { }
            sampler.sample(); settledSamples.append(try object(GIFResourceMemoryReading.current()))
        }
        sampler.stop()
        let metrics = sampler.snapshot(), settled = GIFResourceMemoryReading.current()
        guard metrics.residentSampleCount > 0, metrics.physicalFootprintSampleCount > 0 else { throw failure("Resource sampler did not obtain both RSS and footprint") }
        return (["index": index, "isWarmup": index == 0,
            "before": try object(before), "sampledMemory": try object(metrics), "settledSamples": settledSamples,
            "settledAfterCleanup": try object(settled), "exports": outputs,
            "controllerCreationCount": formats.count, "observedControllerReleaseCount": released,
            "completedEncodePreviewSaveJobs": outputs.count,
            "activeSessionsAfterCycle": ImageExportController.activeSessionCount,
            "queuedOrRunningJobsAfterCycle": ImageExportService.queue.operationCount,
            "ownedTemporaryFilesAfterCycle": try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started], settled)
    }

    private static func exportOne(format: ImageExportFormat, directory: URL, profile: Profile,
                                  deadline: TimeInterval, sampler: GIFResourceMemorySampler) async throws
        -> (report: [String: Any], controller: ImageExportWeakController) {
        try check(deadline)
        let source = try autoreleasepool { try makeSource(width: profile.width, height: profile.height) }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        guard let controller = ImageExportController.present(image: source, from: parent) else { throw failure("Export sheet could not open") }
        let weak = ImageExportWeakController(controller)
        defer { controller.cancelExport() }
        controller.accessory.picker.selectItem(at: format.rawValue)
        guard controller.accessory.picker.sendAction(controller.accessory.picker.action, to: controller.accessory.picker.target) else { throw failure("Format control did not dispatch") }
        if format == .pdf {
            controller.accessory.paper.selectItem(at: ImageExportPaper.a4.rawValue)
            guard controller.accessory.paper.sendAction(controller.accessory.paper.action, to: controller.accessory.paper.target) else { throw failure("Paper control did not dispatch") }
        }
        while controller.latestArtifact == nil && !controller.isClosed {
            try check(deadline); try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let artifact = controller.latestArtifact else { throw failure("Resource-cycle preview failed") }
        sampler.sample()
        let bytes = artifact.byteCount, pages = artifact.pageCount
        let previewBytes = artifact.firstPreview.bytesPerRow * artifact.firstPreview.height
        let destination = directory.appendingPathComponent("one-output.\(format.filenameExtension)")
        try await controller.savePrepared(to: destination)
        sampler.sample()
        let savedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard savedSize == bytes, controller.isClosed else { throw failure("Saved output size or closed-session state differs") }
        try FileManager.default.removeItem(at: destination)
        return (["format": format.title, "encodedBytes": bytes, "previewDecodedBytes": previewBytes,
                 "pdfPageCount": pages, "savedBytesMatchPreviewCount": true, "outputDeleted": true], weak)
    }

    private static func makeSource(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw failure("Synthetic source allocation failed") }
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8((x / 8 * 17 + y / 8 * 13) % 256)
            bytes[offset + 1] = UInt8((x / 8 * 7 + y / 8 * 31) % 256)
            bytes[offset + 2] = UInt8((x / 8 * 23 + y / 8 * 3) % 256); bytes[offset + 3] = 255
        } }
        guard let result = context.makeImage() else { throw failure("Synthetic source image failed") }; return result
    }
    private static func drain(deadline: TimeInterval) async throws {
        while ImageExportService.queue.operationCount > 0 { try check(deadline); try await Task.sleep(nanoseconds: 20_000_000) }
    }
    private static func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw failure("Resource fixture exceeded cooperative deadline") }
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }
    private static func delta(_ value: UInt64?, _ baseline: UInt64?) -> Any {
        guard let value, let baseline else { return NSNull() }
        return Int64(value) - Int64(baseline)
    }
    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(reportName), options: .atomic)
    }
    private static func failure(_ message: String) -> Error { PicShotError.message("Image export resource observation: \(message)") }
}

@MainActor private final class ImageExportWeakController {
    weak var value: ImageExportController?
    init(_ value: ImageExportController) { self.value = value }
}
