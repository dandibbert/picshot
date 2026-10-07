import AppKit
import PicShotCodecCore

@MainActor
enum ImageDecodeLargeAttributionFixture {
    enum Mode: String, CaseIterable { case prepare, productionControl = "production-control", isolatedDecode = "isolated-decode", nativeUIControl = "native-ui-control", nativeUIIsolated = "native-ui-isolated" }
    struct Request: Equatable { let mode: Mode; let profile: ImageDecodeDiagnosticProfile; let inputDirectory: URL?; let timingEnabled: Bool }
    private static var claimed = false
    static func request(_ environment: [String: String]) throws -> Request? {
        let prefix = "PICSHOT_IMAGE_DECODE_LARGE_", keys = Set(environment.keys.filter { $0.hasPrefix(prefix) })
        if keys.isEmpty { return nil }
        guard keys.isSubset(of: [prefix + "MODE", prefix + "PROFILE", prefix + "INPUT_DIRECTORY", prefix + "TIMING"]),
              environment[prefix + "TIMING"] == nil || environment[prefix + "TIMING"] == "3",
              let mode = environment[prefix + "MODE"].flatMap(Mode.init(rawValue:)),
              let profile = environment[prefix + "PROFILE"].flatMap(ImageDecodeDiagnosticProfile.init(rawValue:)),
              (mode != .prepare) == (environment[prefix + "INPUT_DIRECTORY"] != nil),
              !environment.keys.contains(where: { $0.hasPrefix("PICSHOT_IMAGE_DRAW_") || $0.hasPrefix("PICSHOT_IMAGE_RELIEF_") || $0.hasPrefix("PICSHOT_IMAGE_BACKING_") || $0.hasPrefix("PICSHOT_CODEC_ATTRIBUTION_") || $0.hasPrefix("PICSHOT_GIF_DIAGNOSTIC_") }),
              environment["PICSHOT_UI_PREVIEW_ONLY"] != "1", environment["PICSHOT_SMOKE_GIF_RESOURCES"] != "1" else { throw ImageDecodeDiagnosticError.invalidProtocol }
        if mode == .nativeUIControl || mode == .nativeUIIsolated { guard profile == .fiveK else { throw ImageDecodeDiagnosticError.invalidInput } }
        let path = environment[prefix + "INPUT_DIRECTORY"]
        if let path, !path.hasPrefix("/") { throw ImageDecodeDiagnosticError.invalidInput }
        return .init(mode: mode, profile: profile, inputDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) }, timingEnabled: environment[prefix + "TIMING"] == "3")
    }
    static func runIfRequested(evidenceDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [String: Any]? {
        guard let request = try request(environment) else { return nil }
        guard !claimed else { throw ImageDecodeDiagnosticError.invalidProtocol }; claimed = true
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        if request.mode == .prepare { return try ImageDecodeLargeSupport.prepare(profile: request.profile, directory: evidenceDirectory) }
        let input = try ImageDecodeLargeSupport.input(profile: request.profile, directory: request.inputDirectory!)
        if request.mode == .nativeUIControl || request.mode == .nativeUIIsolated {
            return try await ImageDecodeLargeUIFixture.run(input: input, isolated: request.mode == .nativeUIIsolated, directory: evidenceDirectory, timingEnabled: request.timingEnabled)
        }
        return try await measured(input: input, isolated: request.mode == .isolatedDecode, directory: evidenceDirectory, timingEnabled: request.timingEnabled)
    }
    private static func measured(input: ImageDecodeLargeInput, isolated: Bool, directory: URL, timingEnabled: Bool) async throws -> [String: Any] {
        let mode = isolated ? Mode.isolatedDecode.rawValue : Mode.productionControl.rawValue
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 180
        let profile = input.profile, providers = ImageDrawAllocationTracker(maximumAllocations: 14, allocationBytes: input.profile.rasterBytes)
        let destinationTracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: input.profile.rasterBytes)
        var destination: ImageDrawDestination?
        defer { destination?.close() }
        let sampler = ImageDecodeMemorySampler(); defer { sampler.stop() }
        var report = ImageDecodeLargeSupport.base(mode: mode, input: input), cycles: [ImageDecodeLargeCycle] = []
        if timingEnabled { report["timingInstrumentationVersion"] = 3 }
        let output = directory.appendingPathComponent("image-decode-large-\(mode).json")
        do {
            let existing = await CodecExportProcessService.shared.snapshot()
            guard !existing.active, existing.lastJob == nil, ImageExportController.activeSessionCount == 0, ImageExportService.queue.operationCount == 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
            report["warmupCycles"] = 2; report["measuredCycles"] = 12; report["armDeadlineSeconds"] = 180; report["requiredOuterDeadlineSeconds"] = 200
            report["beforeDestinationPreparation"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            destination = try ImageDrawDestination(width: profile.previewWidth, height: profile.previewHeight, tracker: destinationTracker)
            report["afterDestinationPreparation"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            for ordinal in 0..<14 {
                try ImageDecodeLargeSupport.check(deadline, sampler: sampler)
                if ordinal == 2 { report["baselineAfterWarmup"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe()) }
                let before = try ImageDecodeLargeSupport.observe(), begin = ProcessInfo.processInfo.systemUptime
                let cycleSampler = ImageDecodeMemorySampler(); defer { cycleSampler.stop() }
                var raw: Data?, child: ImageDecodeProcessMetrics?
                if isolated {
                    let process = ImageDecodeDiagnosticProcess(mode: .decode, profile: profile, timingEnabled: timingEnabled)
                    do {
                        raw = try await withTaskCancellationHandler { try await Task.detached { try autoreleasepool { try process.run(png: input.png, armDeadline: deadline) } }.value } onCancel: { process.cancel() }
                        child = process.snapshot()
                        guard child!.exitConfirmed, child!.cleanupConfirmed, child!.admissionReleased, raw == input.reference else { throw ImageDecodeDiagnosticError.outputMismatch }
                    } catch { report["failedChild"] = try? ImageDecodeLargeSupport.object(process.snapshot()); throw error }
                }
                let beforeImage = try ImageDecodeLargeSupport.observe()
                let draw: ImageDecodeLargeDraw = try autoreleasepool {
                    let create = ProcessInfo.processInfo.systemUptime
                    let image = isolated ? try ImageDecodeLargeRaster.ownedImage(raw!, profile: profile, tracker: providers) : try ImageExportService.preview(data: input.png, format: .png)
                    guard image.width == profile.previewWidth, image.height == profile.previewHeight, image.bytesPerRow <= 4_194_304 / image.height else { throw ImageDecodeDiagnosticError.invalidInput }
                    let creationSeconds = ProcessInfo.processInfo.systemUptime - create
                    let beforeDraw = try ImageDecodeLargeSupport.observe()
                    let pixels = try destination!.drawAndValidate(image, reference: input.reference, tolerance: 0)
                    let validated = ProcessInfo.processInfo.systemUptime, after = try ImageDecodeLargeSupport.observe()
                    withExtendedLifetime(image) { }
                    return .init(imageCreationSeconds: creationSeconds, drawSeconds: pixels.drawSeconds, validationSeconds: pixels.validationSeconds,
                        pixelsSHA256: pixels.sha256, maximumDifference: pixels.maximumDifference, validatedBytes: profile.rasterBytes,
                        validatedUptimeSeconds: validated, beforeDraw: beforeDraw, afterDraw: after)
                }
                raw = nil
                let afterPool = try ImageDecodeLargeSupport.observe(), lifecycle = ProcessInfo.processInfo.systemUptime - begin
                try await ImageDecodeLargeSupport.settle(0.18, deadline: deadline)
                let settled = try ImageDecodeLargeSupport.observe(); cycleSampler.stop()
                cycles.append(.init(index: ordinal < 2 ? ordinal + 1 : ordinal - 1, isWarmup: ordinal < 2, before: before, beforeImageCreation: beforeImage,
                    draw: draw, afterPool: afterPool, settled: settled, process: child, timeToValidatedPixelsSeconds: draw.validatedUptimeSeconds - begin,
                    fullLifecycleSeconds: lifecycle, observedCycleSeconds: ProcessInfo.processInfo.systemUptime - begin,
                    parentPeaks: cycleSampler.snapshot(), providerLifetime: isolated ? providers.snapshot() : nil))
            }
            try await ImageDecodeLargeSupport.settle(0.5, deadline: deadline)
            report["beforeDestinationClose"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            destination?.close(); destination = nil
            try await ImageDecodeLargeSupport.settle(0.5, deadline: deadline)
            report["afterDestinationClose"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            sampler.stop(); withExtendedLifetime(input) { }
            report["warmups"] = try cycles.filter(\.isWarmup).map { try ImageDecodeLargeSupport.object($0) }
            report["cycles"] = try cycles.filter { !$0.isWarmup }.map { try ImageDecodeLargeSupport.object($0) }
            report["completedDraws"] = 14; report["completedExactPixelChecks"] = 14
            report["helperInvocations"] = isolated ? 14 : 0; report["maximumObservedChildConcurrency"] = isolated ? 1 : 0
            report["ownedJobsRemaining"] = 0; report["parentPeaks"] = try ImageDecodeLargeSupport.object(sampler.snapshot())
            report["destinationLifetime"] = try ImageDecodeLargeSupport.object(destinationTracker.snapshot())
            if isolated { report["providerLifetime"] = try ImageDecodeLargeSupport.object(providers.snapshot()) }
            try ImageDecodeLargeSupport.check(deadline, sampler: sampler)
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started; report["status"] = "observed"
            try ImageDecodeLargeSupport.write(report, to: output); return report
        } catch {
            destination?.close(); sampler.stop(); report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedCycles"] = try? cycles.map { try ImageDecodeLargeSupport.object($0) }
            try? ImageDecodeLargeSupport.write(report, to: output); throw error
        }
    }
}
struct ImageDecodeLargeDraw: Encodable {
    let imageCreationSeconds: Double, drawSeconds: Double, validationSeconds: Double
    let pixelsSHA256: String, maximumDifference: Int, validatedBytes: Int
    let validatedUptimeSeconds: Double
    let beforeDraw: ImageDecodeMemoryReading, afterDraw: ImageDecodeMemoryReading
}
struct ImageDecodeLargeCycle: Encodable {
    let index: Int, isWarmup: Bool
    let before: ImageDecodeMemoryReading, beforeImageCreation: ImageDecodeMemoryReading
    let draw: ImageDecodeLargeDraw
    let afterPool: ImageDecodeMemoryReading, settled: ImageDecodeMemoryReading
    let process: ImageDecodeProcessMetrics?
    let timeToValidatedPixelsSeconds: Double, fullLifecycleSeconds: Double, observedCycleSeconds: Double
    let parentPeaks: ImageDecodeMemoryPeaks, providerLifetime: ImageDrawAllocationSnapshot?
}
