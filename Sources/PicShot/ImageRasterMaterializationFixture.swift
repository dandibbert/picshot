import AppKit
import CryptoKit
import Darwin
import ImageIO

/// Opt-in draw/materialization comparison. No production preview defaults change.
@MainActor
enum ImageRasterMaterializationFixture {
    static let reportProtocol = "image-raster-materialization-v1"
    static let width = 768, height = 576, warmupCycles = 2, measuredCycles = 12
    static let rasterBytes = width * height * 4
    static let pixelTolerance = 2
    static let cooperativeDeadlineSeconds: TimeInterval = 45
    static let requiredOuterDeadlineSeconds: TimeInterval = 60
    static let maximumEncodedBytes = 8 * 1_024 * 1_024
    static let maximumReportBytes = 1_024 * 1_024
    static let manifestName = "image-draw-inputs.json"
    private static var claimed = false
    enum Mode: String, CaseIterable, Sendable {
        case prepareInputs = "prepare-inputs", productionDraw = "production-draw"
        case imageIONoCacheDraw = "imageio-no-cache-draw", ownedRGBADraw = "owned-rgba-draw"
    }
    struct Request: Equatable { let mode: Mode; let inputDirectory: URL? }

    static func request(environment: [String: String]) throws -> Request? {
        let prefix = "PICSHOT_IMAGE_DRAW_"
        let keys = Set(environment.keys.filter { $0.hasPrefix(prefix) })
        if keys.isEmpty { return nil }
        try require(keys.isSubset(of: [prefix + "MODE", prefix + "INPUT_DIRECTORY"]), "Dimensions, counts, tolerance, and deadlines cannot be overridden")
        guard let raw = environment[prefix + "MODE"], let mode = Mode(rawValue: raw) else { throw imageDrawFailure("Explicit draw diagnostic mode required") }
        try require(environment["PICSHOT_IMAGE_RELIEF_MODE"] == nil && environment["PICSHOT_IMAGE_BACKING_MODE"] == nil &&
                    environment["PICSHOT_CODEC_ATTRIBUTION_MODE"] == nil && environment["PICSHOT_GIF_DIAGNOSTIC_MODE"] == nil &&
                    environment["PICSHOT_UI_PREVIEW_ONLY"] != "1" && environment["PICSHOT_SMOKE_GIF_RESOURCES"] != "1", "Draw comparison needs a separate process")
        let path = environment[prefix + "INPUT_DIRECTORY"]
        try require((mode != .prepareInputs) == (path != nil), "Comparison arms require separately prepared inputs")
        if let path { try require(path.hasPrefix("/"), "Input directory must be an absolute local path") }
        return Request(mode: mode, inputDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }
    static func runIfRequested(evidenceDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [String: Any]? {
        guard let request = try request(environment: environment) else { return nil }
        try require(!claimed && evidenceDirectory.isFileURL, "One draw diagnostic per fresh process")
        claimed = true
        if request.mode == .prepareInputs { return try prepare(evidenceDirectory: evidenceDirectory) }
        return try await compare(request: request, evidenceDirectory: evidenceDirectory)
    }
    private static func prepare(evidenceDirectory: URL) throws -> [String: Any] {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let report: [String: Any] = try autoreleasepool {
            let source = try CodecExportResourceFixture.fixture(width: width, height: height)
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: source), options: ImageExportOptions(format: .png))
            let raw = try CodecExportResourceFixture.raster(artifact.firstPreview)
            try require(raw.count == rasterBytes, "Prepared raw dimensions differ")
            try ImageExportService.publish(artifact, to: evidenceDirectory.appendingPathComponent("image-draw-input.png"))
            try raw.write(to: evidenceDirectory.appendingPathComponent("image-draw-reference.rgba"), options: .withoutOverwriting)
            return ["protocol": reportProtocol, "status": "prepared", "mode": Mode.prepareInputs.rawValue,
                "sourceCommit": sourceCommit, "architecture": architecture, "processIdentifier": Int(getpid()),
                "syntheticSource": true, "sourceWidth": width, "sourceHeight": height,
                "pngFilename": "image-draw-input.png", "pngBytes": artifact.byteCount, "pngSHA256": digest(artifact.data),
                "rawFilename": "image-draw-reference.rgba", "rawBytes": raw.count, "rawSHA256": digest(raw),
                "rawLayout": "8bpc, 32bpp, width*4 row bytes, premultipliedLast, byteOrder32Big, sRGB",
                "captureStarted": false, "networkAttempted": false]
        }
        try write(report, to: evidenceDirectory.appendingPathComponent(manifestName)); return report
    }

    private static func compare(request: Request, evidenceDirectory: URL) async throws -> [String: Any] {
        try require(request.mode != .prepareInputs && request.inputDirectory != nil, "Invalid comparison request")
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let output = evidenceDirectory.appendingPathComponent("image-draw-\(request.mode.rawValue).json")
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + cooperativeDeadlineSeconds
        let destinationTracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: rasterBytes)
        let providerTracker = ImageDrawAllocationTracker(maximumAllocations: warmupCycles + measuredCycles, allocationBytes: rasterBytes)
        var destination: ImageDrawDestination?
        defer { destination?.close() }
        var cycles: [ImageDrawCycle] = []
        cycles.reserveCapacity(warmupCycles + measuredCycles)
        var report: [String: Any] = ["protocol": reportProtocol, "status": "running", "diagnosticOnly": true,
            "mode": request.mode.rawValue, "sourceCommit": sourceCommit, "architecture": architecture, "processIdentifier": Int(getpid()),
            "bundlePath": Bundle.main.bundlePath, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceWidth": width, "sourceHeight": height, "warmupCycles": warmupCycles, "measuredCycles": measuredCycles,
            "rasterBytes": rasterBytes, "pixelTolerance": pixelTolerance,
            "cooperativeDeadlineSeconds": cooperativeDeadlineSeconds, "requiredOuterDeadlineSeconds": requiredOuterDeadlineSeconds,
            "captureStarted": false, "networkAttempted": false, "allocatorReliefCalls": 0,
            "scope": "Every cycle creates an image, actually draws it 1:1 into the same preallocated destination, then reads and validates all RGBA bytes. No lazy/no-draw result is accepted as a remedy",
            "destinationScope": "One owned sRGB RGBA destination allocation/context before warmup; clear then copy-blend draw, no interpolation, flush call and full byte readback each cycle; no destination makeImage snapshots",
            "inputScope": "Separately prepared immutable PNG plus canonical production-preview raw reference retained once. Raw-provider arm makes one measured owned RGBA copy per cycle",
            "providerScope": "Public release callbacks instrument raw-owned source providers only; ImageIO providers are not instrumented. Callback/deallocation counts do not prove physical-memory reclamation",
            "memoryScope": ImageBackingTaskVMReading.scope,
            "bookkeepingScope": "Bounded scalar reports; no per-cycle image, decoded Data, or destination snapshot arrays. Successful JSON writes happen after all memory observations",
            "interpretation": "Observed draw, pixel, callback, time and VM-accounting evidence only; no automatic fix, leak/no-leak, zero-cost, large-input or production recommendation"]
        let sampler = GIFResourceMemorySampler(); defer { sampler.stop() }
        do {
            try await inactive(deadline)
            let input = try readInputs(request.inputDirectory!)
            report["inputPreparationProcessIdentifier"] = input.producerPID
            report["immutablePNGSHA256"] = input.pngSHA
            report["immutableRawSHA256"] = input.rawSHA
            report["beforeDestinationPreparation"] = try object(try observed())
            destination = try ImageDrawDestination(width: width, height: height, tracker: destinationTracker)
            report["afterDestinationPreparation"] = try object(try observed())
            report["destinationAllocationBytes"] = rasterBytes
            for i in 1...warmupCycles { cycles.append(try await cycle(i, warmup: true, mode: request.mode, input: input, destination: destination!, providers: providerTracker, deadline: deadline)) }
            let baseline = try observed()
            for i in 1...measuredCycles { cycles.append(try await cycle(i, warmup: false, mode: request.mode, input: input, destination: destination!, providers: providerTracker, deadline: deadline)) }
            try await wait(seconds: 0.5, deadline: deadline); try await inactive(deadline)
            let delayed = try observed()
            let providersBeforeClose = providerTracker.snapshot()
            destination?.close(); destination = nil
            try await inactive(deadline)
            let afterClose = try observed()
            try await wait(seconds: 0.5, deadline: deadline); try await inactive(deadline)
            let afterCloseDelay = try observed()
            sampler.stop()
            try require(try digest(read(input.pngURL, maximum: maximumEncodedBytes)) == input.pngSHA &&
                        digest(read(input.rawURL, maximum: rasterBytes)) == input.rawSHA, "Immutable inputs changed")
            withExtendedLifetime(input) { }
            let measured = cycles.filter { !$0.isWarmup }
            report["baselineAfterWarmup"] = try object(baseline)
            report["warmups"] = try cycles.filter(\.isWarmup).map { try object($0) }
            report["cycles"] = try measured.map { try object($0) }
            report["residentTrend"] = try object(CodecAttributionTrend(baseline: baseline.residentBytes,
                settled: measured.map { $0.settled.residentBytes }, peaks: measured.map { $0.memory.peakResidentBytes }))
            report["physicalFootprintTrend"] = try object(CodecAttributionTrend(baseline: baseline.physicalFootprintBytes,
                settled: measured.map { $0.settled.physicalFootprintBytes }, peaks: measured.map { $0.memory.peakPhysicalFootprintBytes }))
            report["halfSecondAfterFinalCycleDestinationLive"] = try object(delayed)
            report["afterDestinationOwnerDropped"] = try object(afterClose)
            report["halfSecondAfterDestinationOwnerDropped"] = try object(afterCloseDelay)
            report["destinationLifetime"] = try object(destinationTracker.snapshot())
            if request.mode == .ownedRGBADraw {
                report["rawProviderLifetimeBeforeDestinationClose"] = try object(providersBeforeClose)
                report["rawProviderLifetimeAfterDestinationClose"] = try object(providerTracker.snapshot())
            }
            report["completedDraws"] = cycles.count; report["completedFullPixelValidations"] = cycles.count
            report["retainedCycleImages"] = 0; report["helperInvocations"] = 0; report["ownedTemporaryMediaFiles"] = 0
            report["immutableInputsUnchanged"] = true; report["destinationOwnerDropped"] = true
            report["wholeRunSampledMemory"] = try object(sampler.snapshot())
            try check(deadline)
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started; report["status"] = "observed"
            try write(report, to: output); return report
        } catch {
            destination?.close(); destination = nil; sampler.stop()
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedCycles"] = try? cycles.map { try object($0) }
            report["destinationLifetime"] = try? object(destinationTracker.snapshot())
            report["rawProviderLifetime"] = try? object(providerTracker.snapshot())
            try? write(report, to: output); throw error
        }
    }
    private static func cycle(_ index: Int, warmup: Bool, mode: Mode, input: ImageDrawInput,
                              destination: ImageDrawDestination, providers: ImageDrawAllocationTracker,
                              deadline: TimeInterval) async throws -> ImageDrawCycle {
        try await inactive(deadline)
        let sampler = GIFResourceMemorySampler(); defer { sampler.stop() }
        let before = try observed()
        let workload = try autoreleasepool { try perform(mode: mode, png: input.png, raw: input.raw, destination: destination, providers: providers) }
        let afterPool = try observed()
        for _ in 0..<3 { try await wait(seconds: 0.06, deadline: deadline); try await inactive(deadline) }
        let settled = try observed(); sampler.stop()
        return ImageDrawCycle(index: index, isWarmup: warmup, before: before, workload: workload, afterAutoreleasePool: afterPool,
            settled: settled, memory: sampler.snapshot(), fixtureScopeExited: true,
            rawProviderLifetime: mode == .ownedRGBADraw ? providers.snapshot() : nil)
    }
    static func perform(mode: Mode, png: Data, raw: Data, destination: ImageDrawDestination,
                        providers: ImageDrawAllocationTracker) throws -> ImageDrawWorkload {
        try require(mode != .prepareInputs && raw.count == rasterBytes && !png.isEmpty && png.count <= maximumEncodedBytes, "Invalid bounded draw inputs")
        let start = ProcessInfo.processInfo.systemUptime
        let image: CGImage
        var source: CGImageSource?
        switch mode {
        case .productionDraw: image = try ImageExportService.preview(data: png, format: .png)
        case .imageIONoCacheDraw:
            let decoded = try noCacheImage(png); source = decoded.source; image = decoded.image
        case .ownedRGBADraw: image = try ownedImage(raw, tracker: providers)
        case .prepareInputs: throw imageDrawFailure("Preparation is not a measured draw mode")
        }
        let createSeconds = ProcessInfo.processInfo.systemUptime - start
        try require(image.width == width && image.height == height && image.bytesPerRow <= ImageExportLimits.standard.maximumPreviewBytes / image.height,
                    "Image dimensions/preview-byte limit differs")
        let beforeDraw = try observed()
        let result = try destination.drawAndValidate(image, reference: raw, tolerance: pixelTolerance)
        let afterDraw = try observed()
        withExtendedLifetime((image, source)) { }
        return ImageDrawWorkload(imageCreationSeconds: createSeconds, drawAndFlushSeconds: result.drawSeconds,
            pixelValidationSeconds: result.validationSeconds, totalOperationSeconds: createSeconds + result.drawSeconds + result.validationSeconds,
            workloadWallSeconds: ProcessInfo.processInfo.systemUptime - start,
            width: image.width, height: image.height, actualDrawCount: 1, validatedRGBABytes: rasterBytes,
            maximumAbsoluteChannelDifference: result.maximumDifference, pixelsWithinTolerance: true, pixelsSHA256: result.sha256,
            beforeDrawImageLive: beforeDraw, afterDrawAndReadbackImageLive: afterDraw)
    }
    /// The documented options apply to full-image creation. This is permitted
    /// only after exact small PNG metadata checks; it is not a large-image path.
    static func noCacheImage(_ data: Data) throws -> (source: CGImageSource, image: CGImage) {
        guard data.count > 0, data.count <= maximumEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == ImageExportFormat.png.contentType.identifier,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              p[kCGImagePropertyPixelWidth] as? Int == width, p[kCGImagePropertyPixelHeight] as? Int == height,
              p[kCGImagePropertyDepth] as? Int == 8, (p[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false, kCGImageSourceShouldAllowFloat: false] as CFDictionary),
              image.width == width, image.height == height, image.bitsPerComponent == 8,
              image.bytesPerRow <= ImageExportLimits.standard.maximumPreviewBytes / image.height else { throw imageDrawFailure("No-cache input failed fixed PNG/dimension/depth/orientation bounds") }
        return (source, image)
    }
    static func ownedImage(_ raw: Data, tracker: ImageDrawAllocationTracker) throws -> CGImage {
        try require(raw.count == rasterBytes, "Raw provider input must be exactly one fixed RGBA raster")
        let bytes = try ImageDrawOwnedBytes(count: rasterBytes, copying: raw, tracker: tracker)
        let retained = Unmanaged.passRetained(bytes)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: UnsafeRawPointer(bytes.pointer), size: rasterBytes,
            releaseData: { info, _, size in
                guard let info else { return }
                let bytes = Unmanaged<ImageDrawOwnedBytes>.fromOpaque(info).takeRetainedValue()
                bytes.noteCallback(size: size)
            }) else { retained.release(); throw imageDrawFailure("Owned raw provider creation failed") }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: ImageDrawDestination.bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw imageDrawFailure("Owned raw image creation failed") }
        return image
    }
    private static func readInputs(_ directory: URL) throws -> ImageDrawInput {
        try autoreleasepool {
            guard let m = try JSONSerialization.jsonObject(with: read(directory.appendingPathComponent(manifestName), maximum: 32 * 1_024)) as? [String: Any],
                  m["protocol"] as? String == reportProtocol, m["status"] as? String == "prepared", m["syntheticSource"] as? Bool == true,
                  m["sourceCommit"] as? String == sourceCommit, m["architecture"] as? String == architecture,
                  m["sourceWidth"] as? Int == width, m["sourceHeight"] as? Int == height,
                  m["pngFilename"] as? String == "image-draw-input.png", m["rawFilename"] as? String == "image-draw-reference.rgba",
                  let pngCount = m["pngBytes"] as? Int, m["rawBytes"] as? Int == rasterBytes,
                  let pngSHA = m["pngSHA256"] as? String, let rawSHA = m["rawSHA256"] as? String,
                  let pid = m["processIdentifier"] as? Int, pid != Int(getpid()) else { throw imageDrawFailure("Matching separate-process PNG/raw input manifest required") }
            let pngURL = directory.appendingPathComponent("image-draw-input.png"), rawURL = directory.appendingPathComponent("image-draw-reference.rgba")
            let png = try read(pngURL, maximum: maximumEncodedBytes), raw = try read(rawURL, maximum: rasterBytes)
            try require(png.count == pngCount && raw.count == rasterBytes && digest(png) == pngSHA && digest(raw) == rawSHA, "Prepared input bytes/hash differ")
            return ImageDrawInput(pngURL: pngURL, rawURL: rawURL, png: png, raw: raw, pngSHA: pngSHA, rawSHA: rawSHA, producerPID: pid)
        }
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, v.isRegularFile == true, v.isSymbolicLink != true, let n = v.fileSize, n > 0, n <= maximum else { throw imageDrawFailure("Input exceeds regular-file bound") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: n + 1) ?? Data()
        try require(data.count == n, "Input changed during read"); return data
    }
    private static func inactive(_ deadline: TimeInterval) async throws {
        try check(deadline)
        let state = await CodecExportProcessService.shared.snapshot()
        try require(!state.active && state.lastJob == nil && ImageExportController.activeSessionCount == 0 && ImageExportService.queue.operationCount == 0, "Export/helper activity contaminates draw control")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { autoreleasepool { c.resume() } } }
        await Task.yield(); try check(deadline)
    }
    private static func wait(seconds: TimeInterval, deadline: TimeInterval) async throws {
        try check(deadline); try require(ProcessInfo.processInfo.systemUptime + seconds <= deadline, "Wait exceeds diagnostic deadline")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); try check(deadline)
    }
    private static func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation(); try require(ProcessInfo.processInfo.systemUptime < deadline, "Cooperative deadline exceeded; launcher must bound native stalls")
    }
    private static func observed() throws -> ImageBackingMemoryReading {
        let value = ImageBackingMemoryReading.current(); try require(value.residentBytes != nil && value.physicalFootprintBytes != nil, "Self Mach RSS/footprint unavailable"); return value
    }
    private static var sourceCommit: String { Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown" }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw imageDrawFailure("Invalid report object") }; return value
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try require(data.count <= maximumReportBytes, "Diagnostic report exceeds 1 MiB")
        try data.write(to: url, options: .atomic)
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw imageDrawFailure(message) } }
}

/// Public release callbacks own the retained lease. Counters contain no images,
/// raw buffers, or pointers. A deallocation call does not guarantee RSS falls.
final class ImageDrawAllocationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumAllocations: Int, allocationBytes: Int
    private var value = ImageDrawAllocationSnapshot()
    init(maximumAllocations: Int, allocationBytes: Int) { self.maximumAllocations = maximumAllocations; self.allocationBytes = allocationBytes }
    func reserve(_ bytes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard bytes == allocationBytes, value.allocations < maximumAllocations else { throw imageDrawFailure("Owned raster allocation budget exceeded") }
        value.allocations += 1; value.activeBytes += bytes; value.peakActiveBytes = max(value.peakActiveBytes, value.activeBytes)
    }
    func callback(size: Int) { lock.lock(); value.releaseCallbacks += 1; value.callbackSizesMatch = value.callbackSizesMatch && size == allocationBytes; lock.unlock() }
    func freed(_ bytes: Int) { lock.lock(); value.deallocations += 1; value.activeBytes -= bytes; lock.unlock() }
    func snapshot() -> ImageDrawAllocationSnapshot { lock.lock(); defer { lock.unlock() }; return value }
}
struct ImageDrawAllocationSnapshot: Encodable, Equatable {
    var allocations = 0, releaseCallbacks = 0, deallocations = 0, activeBytes = 0, peakActiveBytes = 0
    var callbackSizesMatch = true
}
private final class ImageDrawOwnedBytes {
    let pointer: UnsafeMutableRawPointer, count: Int
    private let tracker: ImageDrawAllocationTracker
    init(count: Int, copying data: Data?, tracker: ImageDrawAllocationTracker) throws {
        if let data, data.count != count { throw imageDrawFailure("Owned buffer byte count mismatch") }
        try tracker.reserve(count)
        self.count = count; self.tracker = tracker
        pointer = .allocate(byteCount: count, alignment: 64)
        if let data { data.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: count) } }
        else { pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count) }
    }
    func noteCallback(size: Int) { tracker.callback(size: size) }
    deinit { pointer.deallocate(); tracker.freed(count) }
}
final class ImageDrawDestination {
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    private var context: CGContext?
    private let width: Int, height: Int, byteCount: Int
    init(width: Int, height: Int, tracker: ImageDrawAllocationTracker) throws {
        guard width > 0, height > 0, width <= 1024, height <= 1024, width <= (4 * 1_024 * 1_024) / 4 / height else { throw imageDrawFailure("Destination dimensions exceed 4 MiB") }
        self.width = width; self.height = height; byteCount = width * height * 4
        let bytes = try ImageDrawOwnedBytes(count: byteCount, copying: nil, tracker: tracker)
        let retained = Unmanaged.passRetained(bytes)
        guard let context = CGContext(data: bytes.pointer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Self.bitmapInfo.rawValue,
            releaseCallback: { info, _ in
                guard let info else { return }
                let bytes = Unmanaged<ImageDrawOwnedBytes>.fromOpaque(info).takeRetainedValue()
                bytes.noteCallback(size: bytes.count)
            }, releaseInfo: retained.toOpaque()) else { retained.release(); throw imageDrawFailure("Owned destination creation failed") }
        self.context = context
        context.interpolationQuality = .none; context.setBlendMode(.copy)
    }
    func close() { context = nil }
    func drawAndValidate(_ image: CGImage, reference: Data, tolerance: Int) throws -> ImageDrawPixels {
        guard let context, let data = context.data, image.width == width, image.height == height,
              reference.count == byteCount, (0...2).contains(tolerance) else { throw imageDrawFailure("Invalid or closed destination/readback") }
        let drawStart = ProcessInfo.processInfo.systemUptime
        data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); context.flush()
        let drawSeconds = ProcessInfo.processInfo.systemUptime - drawStart
        let validateStart = ProcessInfo.processInfo.systemUptime
        let actual = data.assumingMemoryBound(to: UInt8.self)
        var maximumDifference = 0
        reference.withUnsafeBytes { raw in
            let expected = raw.bindMemory(to: UInt8.self)
            for i in 0..<byteCount { maximumDifference = max(maximumDifference, abs(Int(actual[i]) - Int(expected[i]))) }
        }
        // This view borrows the preallocated destination; it does not copy or own it.
        let view = Data(bytesNoCopy: data, count: byteCount, deallocator: .none)
        let sha = SHA256.hash(data: view).map { String(format: "%02x", $0) }.joined()
        let validationSeconds = ProcessInfo.processInfo.systemUptime - validateStart
        guard maximumDifference <= tolerance else { throw imageDrawFailure("Drawn RGBA pixels exceed reference tolerance") }
        return ImageDrawPixels(sha256: sha, maximumDifference: maximumDifference, drawSeconds: drawSeconds, validationSeconds: validationSeconds)
    }
}
struct ImageDrawPixels { let sha256: String; let maximumDifference: Int; let drawSeconds: TimeInterval; let validationSeconds: TimeInterval }
struct ImageDrawWorkload: Encodable {
    let imageCreationSeconds: TimeInterval, drawAndFlushSeconds: TimeInterval, pixelValidationSeconds: TimeInterval, totalOperationSeconds: TimeInterval
    let workloadWallSeconds: TimeInterval
    let width: Int, height: Int, actualDrawCount: Int, validatedRGBABytes: Int, maximumAbsoluteChannelDifference: Int
    let pixelsWithinTolerance: Bool
    let pixelsSHA256: String
    let beforeDrawImageLive: ImageBackingMemoryReading, afterDrawAndReadbackImageLive: ImageBackingMemoryReading
}
private struct ImageDrawInput { let pngURL: URL; let rawURL: URL; let png: Data; let raw: Data; let pngSHA: String; let rawSHA: String; let producerPID: Int }
private struct ImageDrawCycle: Encodable {
    let index: Int; let isWarmup: Bool; let before: ImageBackingMemoryReading; let workload: ImageDrawWorkload
    let afterAutoreleasePool: ImageBackingMemoryReading, settled: ImageBackingMemoryReading
    let memory: GIFResourceMemoryStatistics; let fixtureScopeExited: Bool; let rawProviderLifetime: ImageDrawAllocationSnapshot?
}
private func imageDrawFailure(_ message: String) -> Error { PicShotError.message("Image draw attribution: " + message) }
