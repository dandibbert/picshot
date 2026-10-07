import AppKit
import CryptoKit
import PicShotCore

/// Opt-in, bounded observations of owned editors over one authored raster.
/// Vectors are injected directly: native gesture/control semantics are covered
/// by the separate functional fixtures, not by this resource workload.
@MainActor
enum AnnotationDetailResourceFixture {
    private static let width = 720, height = 480
    private static let warmupCycles = 2, measuredCycles = 12
    private static let overallDeadlineSeconds = 120.0
    private static let maximumPointsPerMark = 128, maximumTotalPoints = 256
    private static let maximumTextUTF16PerMark = 128
    private static let settlingDelaySeconds = 0.15

    static func verify() async throws -> [String: Any] {
        _ = NSApplication.shared
        let began = ProcessInfo.processInfo.systemUptime
        let deadline = began + overallDeadlineSeconds
        try checkDeadline(deadline)
        try require(NSScreen.main != nil, "A WindowServer display is required")
        // Source creation/hash precede all memory boundaries; no second source
        // or annotation-bearing image is kept by the fixture between cycles.
        let source = try autoreleasepool { try syntheticSource() }
        let sourceHash = try autoreleasepool { try digest(source) }
        var probes: [AnnotationDetailReleaseProbe] = []
        var renderHashes: [String] = []
        var warmupSettled: [GIFResourceMemoryReading] = []
        var settled: [GIFResourceMemoryReading] = []
        var endpoints: [[String: Int]] = []
        let beforeWarmup = try observedMemory()
        let warmupSampler = GIFResourceMemorySampler()
        defer { warmupSampler.stop() }
        for index in 0..<warmupCycles {
            let result = try cycle(source: source, sourceHash: sourceHash, deadline: deadline)
            probes.append(result.probe); renderHashes.append(result.renderHash)
            try await released(probes, deadline: deadline)
            try await settle(deadline: deadline)
            warmupSampler.sample(); warmupSettled.append(try observedMemory())
            endpoints.append(endpoint(cycle: index + 1, probes: probes))
        }
        let warmupStatistics = try stoppedStatistics(warmupSampler)
        let baseline = try observedMemory()
        let measuredStart = ProcessInfo.processInfo.systemUptime
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        for index in 0..<measuredCycles {
            let result = try cycle(source: source, sourceHash: sourceHash, deadline: deadline)
            probes.append(result.probe); renderHashes.append(result.renderHash)
            try await released(probes, deadline: deadline)
            try await settle(deadline: deadline)
            sampler.sample(); settled.append(try observedMemory())
            endpoints.append(endpoint(cycle: warmupCycles + index + 1, probes: probes))
        }
        let measuredEnd = try required(settled.last, "Measured endpoints absent")
        let measuredElapsed = ProcessInfo.processInfo.systemUptime - measuredStart
        try await released(probes, deadline: deadline)
        try await settle(deadline: deadline)
        sampler.sample()
        let final = try observedMemory(), statistics = try stoppedStatistics(sampler)
        let finalSourceHash = try autoreleasepool { try digest(source) }
        try require(finalSourceHash == sourceHash && Set(renderHashes).count == 1,
                    "Source or identical-workload render changed")
        try checkDeadline(deadline)
        let rss = settled.map { Int64($0.residentBytes!) }
        let footprint = settled.map { Int64($0.physicalFootprintBytes!) }
        return [
            "status": "passed", "observationsComplete": true,
            "warmupCycles": warmupCycles, "measuredCycles": measuredCycles,
            "completedMeasuredCycles": settled.count, "completedRenderCycles": probes.count,
            "sourceWidth": width, "sourceHeight": height, "sourceBytes": width * height * 4,
            "sourceSHA256Before": sourceHash, "sourceSHA256After": finalSourceHash,
            "sourceByteIdentityVerified": true, "renderSHA256PerCycle": renderHashes,
            "sameAuthoredRasterEachCycle": true, "sameVectorsEachCycle": true,
            "vectorSetup": "direct setContent injection; production canvas preview and flattened renderer",
            "nativeGestureActionsExercisedInResourceLoop": false,
            "representativeStyles": ["smoothed-pencil", "multiply-freehand-marker", "outlined-multilingual-text",
                                     "diamond-and-filled-triangle-arrow", "numbered-comment-and-leader"],
            "marksPerCycle": 5, "pointsPerCycle": 45,
            "maximumPointsPerMark": maximumPointsPerMark, "maximumTotalPoints": maximumTotalPoints,
            "maximumTextUTF16PerMark": maximumTextUTF16PerMark,
            "maximumRasterPixels": width * height, "maximumConcurrentOwnedEditors": 1,
            "fixedInputRasterCountAtBaselineAndEveryCycleEnd": 1,
            "liveEditorsAtBaselineAndEveryCycleEnd": 0, "activeJobsAtBaselineAndEveryCycleEnd": 0,
            "fixtureOwnedOutputRastersAtBaselineAndEveryCycleEnd": 0,
            "asyncAnnotationJobsStarted": 0, "cycleEndStates": endpoints,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval,
            "settlingDelaySeconds": settlingDelaySeconds,
            "overallDeadlineSeconds": overallDeadlineSeconds,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
            "measuredElapsedSeconds": measuredElapsed,
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
            "beforeWarmup": try object(beforeWarmup), "baselineAfterWarmup": try object(baseline),
            "settledAfterWarmups": try warmupSettled.map { try object($0) },
            "warmupSampledMemory": try object(warmupStatistics), "sampledMemory": try object(statistics),
            "settledAfterCycles": try settled.map { try object($0) }, "afterMeasuredCycles": try object(measuredEnd),
            "finalAfterCleanup": try object(final),
            "residentGrowthFromWarmupBytes": rss[11] - Int64(baseline.residentBytes!),
            "physicalFootprintGrowthFromWarmupBytes": footprint[11] - Int64(baseline.physicalFootprintBytes!),
            "residentLastIntervalGrowthBytes": rss[11] - rss[10],
            "physicalFootprintLastIntervalGrowthBytes": footprint[11] - footprint[10],
            "residentLateThreeIntervalGrowthBytes": (9...11).map { rss[$0] - rss[$0 - 1] },
            "physicalFootprintLateThreeIntervalGrowthBytes": (9...11).map { footprint[$0] - footprint[$0 - 1] },
            "residentCleanupDeltaBytes": Int64(final.residentBytes!) - rss[11],
            "physicalFootprintCleanupDeltaBytes": Int64(final.physicalFootprintBytes!) - footprint[11],
            "lateIntervalCycles": 1, "warmupReleaseProbes": warmupCycles, "measuredReleaseProbes": measuredCycles,
            "retainedObjects": probes.reduce(0) { $0 + $1.retainedCount }, "releaseEvidence": releaseObject(probes),
            "snapshotsInsideMeasuredLoop": 0, "pngEncodesInsideMeasuredLoop": 0,
            "screenCaptureStarted": false, "permissionRequests": false, "globalInputPosted": false,
            "networkUsed": false, "generalPasteboardUsed": false, "standardDefaultsWritten": false,
            "memoryPressureOrSystemSettingsChanged": false, "allocatorPurgeAttempted": false,
            "memoryIsObservational": true, "stabilityAssessed": false, "zeroLeakClaim": false,
            "scope": "2 warmups + 12 measured show/inject/preview/flatten/close cycles, each with the same 720x480 authored source and five bounded style vectors. Every cycle releases its scoped images and owned editor; weak controller/canvas/content probes reach zero before sampling. Only one constant source raster remains owned by this fixture at endpoints; renderer/CoreText/AppKit caches are not counted as fixture ownership. No PNG or screenshot is encoded in the loop. All settled readings and late increments are retained; the existing 50 ms sampler retains counters/peaks, not raw timer samples. Self-process RSS/footprint is observational and can miss transients; excludes WindowServer/GPU totals, large-image performance, native gesture semantics, plateau and zero leaks."
        ]
    }

    /// A synchronous autorelease pool bounds all per-cycle strong references;
    /// defer closes the owned window even on cancellation/deadline/render failure.
    private static func cycle(source: CGImage, sourceHash: String, deadline: Double) throws
        -> (probe: AnnotationDetailReleaseProbe, renderHash: String) {
        try autoreleasepool {
            try checkDeadline(deadline)
            let editor = ImageEditorController(image: source, onSave: { _ in }, onPin: { _ in },
                                              onOCR: { _ in }, copyAction: { _ in })
            defer { editor.close() }
            let probe = AnnotationDetailReleaseProbe(editor)
            editor.window?.appearance = NSAppearance(named: .aqua)
            editor.window?.setContentSize(NSSize(width: 760, height: 600))
            editor.showWindow(nil)
            try require(editor.window?.isVisible == true, "Owned editor did not show")
            let vectors = try annotations()
            editor.annotationCanvas.setContent(image: source, annotations: vectors)
            try require(editor.annotationCanvas.image === source && !editor.automaticMosaicIsComputing,
                        "Cycle replaced input or started a background job")
            editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
            let renderHash = try autoreleasepool {
                let output = try required(editor.annotationCanvas.flattened(), "Flattened render failed")
                let preview = try required(editor.annotationCanvas.rasterForBoundaryPreview(), "Preview render failed")
                try require(output.width == width && output.height == height && preview.width == width && preview.height == height,
                            "Rendered dimensions changed")
                let hash = try digest(output)
                try require(hash != sourceHash && hash == digest(preview), "Render unchanged or preview differs")
                return hash
            }
            try checkDeadline(deadline)
            editor.close()
            try require(editor.isClosed && editor.window?.isVisible != true && editor.window?.contentView == nil
                        && editor.window?.delegate == nil && !editor.automaticMosaicIsComputing
                        && editor.automaticMosaicReviewState == nil && editor.activeInlineTextView == nil
                        && editor.annotationCanvas.activeNumberCommentInput == nil
                        && editor.annotationCanvas.pendingFreehand == nil && editor.annotationCanvas.pendingPolylinePointCount == 0
                        && editor.annotationCanvas.retainedPresentationRaster == nil
                        && editor.captureBoundaryWorkspace.frozenImage == nil && editor.captureBoundaryWorkspace.boundaryPreviewImage == nil,
                        "Close retained owned UI, draft, job or presentation cache")
            return (probe, renderHash)
        }
    }

    private static func annotations() throws -> [ImageAnnotation] {
        var pencilPoints: [CGPoint] = []
        for index in 0..<24 {
            let x: CGFloat = CGFloat(28 + index * 12)
            let y: CGFloat = CGFloat(390 + (index % 4) * 10)
            pencilPoints.append(CGPoint(x: x, y: y))
        }
        var pencil = ImageAnnotation(tool: .freehand, points: pencilPoints)
        pencil.lineWidth = 6; pencil.freehandSmoothing = true
        var markerPoints: [CGPoint] = []
        for index in 0..<16 {
            let x: CGFloat = CGFloat(35 + index * 18)
            let y: CGFloat = CGFloat(300 + (index % 3) * 8)
            markerPoints.append(CGPoint(x: x, y: y))
        }
        var marker = ImageAnnotation(tool: .highlighter, points: markerPoints)
        marker.lineWidth = 24; marker.freehandSmoothing = true
        marker.highlighterMode = .freehand; marker.highlighterBlend = .multiply
        marker.color = CGColor(srgbRed: 1, green: 0.8, blue: 0.12, alpha: 1)
        var text = ImageAnnotation(tool: .text, points: [CGPoint(x: 365, y: 335)])
        text.text = "Flow → 世界\nمرحبا · 한글"; text.fontSize = 24
        text.textBoxSize = CGSize(width: 310, height: 115)
        text.textOutlineEnabled = true; text.textOutlineWidth = 2
        text.textOutlineColor = CGColor(srgbRed: 0.1, green: 0.4, blue: 1, alpha: 1)
        text.fillEnabled = true
        var arrow = ImageAnnotation(tool: .arrow, points: [CGPoint(x: 390, y: 180), CGPoint(x: 640, y: 255)])
        arrow.startArrowEnabled = true; arrow.endArrowEnabled = true
        arrow.startArrowhead = .diamond; arrow.endArrowhead = .filledTriangle
        arrow.lineWidth = 8; arrow.lineCap = .square; arrow.lineJoin = .miter; arrow.opacity = 0.7
        var number = ImageAnnotation(tool: .number, points: [CGPoint(x: 70, y: 130), CGPoint(x: 220, y: 210)])
        number.number = 27; number.numberStyle = .alphabetic
        number.numberComment = "步骤七 · مرحبا · 👩🏽‍💻\n確認して次へ"
        number.numberCommentSize = CGSize(width: 230, height: 80)
        let result = [pencil, marker, text, arrow, number]
        try require(result.count == 5 && result.reduce(0, { $0 + $1.points.count }) == 45
                    && result.reduce(0, { $0 + $1.points.count }) <= maximumTotalPoints,
                    "Vector count exceeds fixture cap")
        for mark in result {
            try require(mark.points.count <= maximumPointsPerMark
                        && mark.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x < CGFloat(width) && $0.y >= 0 && $0.y < CGFloat(height) }
                        && mark.text.utf16.count <= maximumTextUTF16PerMark
                        && mark.numberComment.utf16.count <= maximumTextUTF16PerMark,
                        "Vector point/text extent exceeds fixture cap")
        }
        return result
    }

    private static func syntheticSource() throws -> CGImage {
        let context = try required(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Source allocation failed")
        context.setFillColor(CGColor(srgbRed: 0.87, green: 0.92, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.21, blue: 0.32, alpha: 1))
        context.fill(CGRect(x: 20, y: 275, width: 320, height: 85))
        return try required(context.makeImage(), "Source raster creation failed")
    }
    private static func digest(_ image: CGImage) throws -> String {
        let data = try required(image.dataProvider?.data, "Raster bytes unavailable")
        return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
    }
    private static func endpoint(cycle: Int, probes: [AnnotationDetailReleaseProbe]) -> [String: Int] {
        ["cycle": cycle, "fixedInputRasterCount": 1, "liveEditors": probes.filter { $0.controller != nil }.count,
         "activeJobs": probes.filter { $0.controller?.automaticMosaicIsComputing == true }.count,
         "fixtureOwnedOutputRasters": 0, "retainedObjects": probes.reduce(0) { $0 + $1.retainedCount }]
    }
    private static func releaseObject(_ probes: [AnnotationDetailReleaseProbe]) -> [String: Int] {
        ["probeCount": probes.count, "retainedControllers": probes.filter { $0.controller != nil }.count,
         "retainedCanvases": probes.filter { $0.canvas != nil }.count,
         "retainedContentViews": probes.filter { $0.content != nil }.count]
    }
    private static func released(_ probes: [AnnotationDetailReleaseProbe], deadline: Double) async throws {
        let releaseDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 10)
        while probes.contains(where: { $0.retainedCount != 0 }) {
            try checkDeadline(releaseDeadline)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try checkDeadline(deadline)
    }
    private static func settle(deadline: Double) async throws {
        try checkDeadline(deadline)
        try await Task.sleep(nanoseconds: 150_000_000)
        try checkDeadline(deadline)
    }
    private static func checkDeadline(_ deadline: Double) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Fixture deadline exceeded")
    }
    private static func observedMemory() throws -> GIFResourceMemoryReading {
        let value = GIFResourceMemoryReading.current()
        try require((value.residentBytes ?? 0) > 0 && (value.physicalFootprintBytes ?? 0) > 0
                    && value.residentBytes! <= UInt64(Int64.max) && value.physicalFootprintBytes! <= UInt64(Int64.max),
                    "RSS/physical footprint sample unavailable")
        return value
    }
    private static func stoppedStatistics(_ sampler: GIFResourceMemorySampler) throws -> GIFResourceMemoryStatistics {
        sampler.stop()
        let value = sampler.snapshot(), count = value.timerTickCount + value.boundarySampleCount
        try require(value.timerTickCount > 0 && value.boundarySampleCount > 0
                    && value.residentSampleCount == count && value.physicalFootprintSampleCount == count
                    && value.failedResidentSampleCount == 0 && value.failedPhysicalFootprintSampleCount == 0,
                    "Incomplete sampled memory observations")
        return value
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try required(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any], "Evidence encoding failed")
    }
    private static func required<T>(_ value: T?, _ detail: String) throws -> T {
        guard let value else { throw PicShotError.message("Annotation resources: " + detail) }; return value
    }
    private static func require(_ value: Bool, _ detail: String) throws {
        if !value { throw PicShotError.message("Annotation resources: " + detail) }
    }
}

@MainActor private final class AnnotationDetailReleaseProbe {
    weak var controller: ImageEditorController?
    weak var canvas: ImageEditorCanvas?
    weak var content: NSView?
    init(_ controller: ImageEditorController) {
        self.controller = controller; canvas = controller.annotationCanvas; content = controller.window?.contentView
    }
    var retainedCount: Int { autoreleasepool { [controller as AnyObject?, canvas, content].compactMap { $0 }.count } }
}
