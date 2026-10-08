import CoreGraphics
import Darwin
import Foundation

/// Storage for the final editor render only. Source/model images, intermediate
/// effect snapshots, crop/export and presentation storage are not changed.
enum RendererStorageStrategy: String, CaseIterable, Sendable {
    case native
    case ownedSRGB8 = "owned-srgb8"
    static let productionDefault: Self = .native
}

struct RendererStorageConfiguration: @unchecked Sendable {
    let limits: RendererStorage.Limits
    let tracker: RendererStorageTracker
    let failureInjection: RendererStorage.FailureInjection
    private let selection: Result<RendererStorageStrategy, RendererStorage.Failure>

    init(strategy: RendererStorageStrategy, limits: RendererStorage.Limits = .standard,
         tracker: RendererStorageTracker = RendererStorageTracker(),
         failureInjection: RendererStorage.FailureInjection = .none) {
        self.limits = limits; self.tracker = tracker; self.failureInjection = failureInjection
        selection = .success(strategy)
    }
    init(environment: [String: String]) {
        limits = .standard; tracker = RendererStorageTracker(); failureInjection = .none
        do { selection = .success(try Self.selection(environment: environment)) }
        catch { selection = .failure(.invalidConfiguration) }
    }
    static let process = RendererStorageConfiguration(environment: ProcessInfo.processInfo.environment)
    func selectedStrategy() throws -> RendererStorageStrategy { try selection.get() }
    static func selection(environment: [String: String]) throws -> RendererStorageStrategy {
        let keys = environment.keys.filter { $0.hasPrefix("PICSHOT_RENDERER_STORAGE") }
        guard keys.allSatisfy({ $0 == "PICSHOT_RENDERER_STORAGE_STRATEGY" }) else {
            throw RendererStorage.Failure.invalidConfiguration
        }
        guard let raw = environment["PICSHOT_RENDERER_STORAGE_STRATEGY"] else { return .productionDefault }
        guard environment["PICSHOT_SMOKE_TEST"] == "1",
              let report = environment["PICSHOT_SMOKE_REPORT"], report.hasPrefix("/"), !report.contains("\0"),
              let strategy = RendererStorageStrategy(rawValue: raw) else { throw RendererStorage.Failure.invalidConfiguration }
        return strategy
    }
}

/// These are scalar ownership/stage counts, not RSS, footprint, CoreGraphics
/// internal copies, effect snapshots, native caches or presentation storage.
struct RendererStorageSnapshot: Codable, Equatable {
    var attemptCount = 0, nativeCount = 0, eligibleCount = 0
    var seedCount = 0, drawCount = 0, publishCount = 0, failureCount = 0
    var unsupportedCounts: [String: Int] = [:]
    var allocations = 0, deallocations = 0, releaseCallbacks = 0
    var allocatedBytes = 0, deallocatedBytes = 0, callbackBytes = 0
    var activeBytes = 0, peakActiveBytes = 0
    var callbackSizesMatch = true
}
final class RendererStorageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RendererStorageSnapshot()
    private var reservedBytes = 0
    func snapshot() -> RendererStorageSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    fileprivate func update(_ body: (inout RendererStorageSnapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&value)
    }
    fileprivate func reserve(_ count: Int, maximum: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, count <= maximum, reservedBytes <= maximum - count else {
            throw RendererStorage.Failure.admissionRefused
        }
        reservedBytes += count
    }
    fileprivate func releaseReservation(_ count: Int) {
        lock.lock(); defer { lock.unlock() }; reservedBytes -= count
    }
    fileprivate func allocated(_ count: Int) {
        update {
            $0.allocations += 1; $0.allocatedBytes += count; $0.activeBytes += count
            $0.peakActiveBytes = max($0.peakActiveBytes, $0.activeBytes)
        }
    }
    fileprivate func freed(_ count: Int) {
        update { $0.deallocations += 1; $0.deallocatedBytes += count; $0.activeBytes -= count; reservedBytes -= count }
    }
    fileprivate func callback(actual: Int, expected: Int) {
        update {
            $0.releaseCallbacks += 1; $0.callbackBytes += actual
            $0.callbackSizesMatch = $0.callbackSizesMatch && actual == expected
        }
    }
}

enum RendererStorage {
    struct Limits: Sendable {
        var maximumDimension = 32_768
        var maximumOwnedBytes = 400_000_000
        /// Source row storage plus final destination. Does not bound framework scratch.
        var maximumWorkingBytes = 800_000_000
        /// Includes all published providers and renders using this tracker.
        var maximumActiveOwnedBytes = 800_000_000
        static let standard = Limits()
    }
    enum Failure: Error, Equatable {
        case invalidConfiguration, invalidBounds, storageOverflow, admissionRefused, cancelled
        case allocationFailed, contextFailed, changedDestination, annotationFailed, providerFailed, imageFailed
        case injectedAllocation, injectedContext, injectedSeed, injectedDraw, injectedProvider, injectedImage
    }
    enum FailureInjection: Sendable { case none, allocation, context, seed, draw, provider, image }
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

    /// A provider owns this object only. In particular it cannot retain a source,
    /// CGContext, annotations, configuration or a closure which can mutate bytes.
    private final class Bytes {
        let pointer: UnsafeMutableRawPointer, count: Int
        let tracker: RendererStorageTracker
        init(count: Int, configuration: RendererStorageConfiguration) throws {
            tracker = configuration.tracker; self.count = count
            try tracker.reserve(count, maximum: configuration.limits.maximumActiveOwnedBytes)
            if configuration.failureInjection == .allocation {
                tracker.releaseReservation(count); throw Failure.injectedAllocation
            }
            guard let pointer = calloc(1, count) else {
                tracker.releaseReservation(count); throw Failure.allocationFailed
            }
            self.pointer = pointer; tracker.allocated(count)
        }
        deinit { free(pointer); tracker.freed(count) }
    }

    static func render(image: CGImage, annotations: [ImageAnnotation],
                       configuration: RendererStorageConfiguration,
                       drawingRaster: DrawingRasterConfiguration,
                       isCancelled: () -> Bool = { false },
                       effectPatchRenderer: ImageEditorRenderer.EffectPatchRenderer = ImageEditorRenderer.renderEffectPatch) throws -> CGImage {
        configuration.tracker.update { $0.attemptCount += 1 }
        do {
            try cancellation(isCancelled)
            let strategy = try configuration.selectedStrategy()
            let unsupported = strategy == .ownedSRGB8 ? DrawingRaster.unsupported(image) : nil
            if strategy == .native || unsupported != nil {
                configuration.tracker.update {
                    $0.nativeCount += 1
                    if strategy == .ownedSRGB8, let unsupported { $0.unsupportedCounts[unsupported.rawValue, default: 0] += 1 }
                }
                return try renderNative(image: image, annotations: annotations, configuration: configuration,
                    drawingRaster: drawingRaster, isCancelled: isCancelled, effectPatchRenderer: effectPatchRenderer)
            }
            configuration.tracker.update { $0.eligibleCount += 1 }
            let count = try admittedStorage(width: image.width, height: image.height,
                sourceBytesPerRow: image.bytesPerRow, sourceBitsPerPixel: image.bitsPerPixel, limits: configuration.limits)
            let bytes = try Bytes(count: count, configuration: configuration)
            // This function has no callback that receives a mutable context or
            // pointer. The mutable context dies before publication; immutable
            // effect snapshots may outlive the draw through effectPatchRenderer.
            try autoreleasepool {
                try drawOwned(image: image, annotations: annotations, bytes: bytes, configuration: configuration,
                    drawingRaster: drawingRaster, isCancelled: isCancelled, effectPatchRenderer: effectPatchRenderer)
            }
            try cancellation(isCancelled)
            if configuration.failureInjection == .provider { throw Failure.injectedProvider }
            let retained = Unmanaged.passRetained(bytes)
            guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: bytes.pointer, size: count,
                releaseData: { info, _, size in
                    guard let info else { return }
                    let owner = Unmanaged<Bytes>.fromOpaque(info).takeRetainedValue()
                    owner.tracker.callback(actual: size, expected: owner.count)
                }) else { retained.release(); throw Failure.providerFailed }
            if configuration.failureInjection == .image { throw Failure.injectedImage }
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let result = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: image.width * 4, space: color, bitmapInfo: bitmapInfo,
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Failure.imageFailed }
            try cancellation(isCancelled)
            configuration.tracker.update { $0.publishCount += 1 }
            return result
        } catch {
            configuration.tracker.update { $0.failureCount += 1 }
            if error as? DrawingRaster.Failure == .cancelled { throw Failure.cancelled }
            throw error
        }
    }

    /// The control is the pre-experiment allocation/snapshot path, including for
    /// unsupported source layouts. Only the final renderer calls this helper.
    private static func renderNative(image: CGImage, annotations: [ImageAnnotation],
        configuration: RendererStorageConfiguration, drawingRaster: DrawingRasterConfiguration,
        isCancelled: () -> Bool, effectPatchRenderer: ImageEditorRenderer.EffectPatchRenderer) throws -> CGImage {
        guard ImageEditorRenderer.allowsRasterSize(width: image.width, height: image.height),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: color, bitmapInfo: bitmapInfo.rawValue) else {
            throw Failure.contextFailed
        }
        try cancellation(isCancelled)
        try DrawingRaster.seedFreshSRGB8Context(context, from: image, configuration: drawingRaster, isCancelled: isCancelled)
        configuration.tracker.update { $0.seedCount += 1 }
        try cancellation(isCancelled)
        let extent = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        guard ImageEditorRenderer.drawAnnotations(annotations, in: context, extent: extent, baseImage: image,
            effectPatchRenderer: effectPatchRenderer) else { throw Failure.annotationFailed }
        configuration.tracker.update { $0.drawCount += 1 }
        try cancellation(isCancelled)
        guard let result = context.makeImage() else { throw Failure.imageFailed }
        try cancellation(isCancelled)
        configuration.tracker.update { $0.publishCount += 1 }
        return result
    }

    /// Deliberately returns Void: neither mutable context nor raw storage can
    /// escape its rendering scope. Intermediate makeImage calls stay unchanged.
    private static func drawOwned(image: CGImage, annotations: [ImageAnnotation], bytes: Bytes,
        configuration: RendererStorageConfiguration, drawingRaster: DrawingRasterConfiguration,
        isCancelled: () -> Bool, effectPatchRenderer: ImageEditorRenderer.EffectPatchRenderer) throws {
        if configuration.failureInjection == .context { throw Failure.injectedContext }
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: bytes.pointer, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: color, bitmapInfo: bitmapInfo.rawValue) else {
            throw Failure.contextFailed
        }
        try cancellation(isCancelled)
        if configuration.failureInjection == .seed {
            bytes.pointer.storeBytes(of: UInt8(0xA5), as: UInt8.self); throw Failure.injectedSeed
        }
        try DrawingRaster.seedFreshSRGB8Context(context, from: image, configuration: drawingRaster, isCancelled: isCancelled)
        configuration.tracker.update { $0.seedCount += 1 }
        try cancellation(isCancelled)
        let extent = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        guard ImageEditorRenderer.drawAnnotations(annotations, in: context, extent: extent, baseImage: image,
            effectPatchRenderer: effectPatchRenderer) else { throw Failure.annotationFailed }
        if configuration.failureInjection == .draw { throw Failure.injectedDraw }
        configuration.tracker.update { $0.drawCount += 1 }
        try cancellation(isCancelled)
        context.flush()
        guard context.data == bytes.pointer, context.width == image.width, context.height == image.height,
              context.bytesPerRow == image.width * 4, context.bitsPerComponent == 8, context.bitsPerPixel == 32,
              context.bitmapInfo == bitmapInfo, context.colorSpace?.name == CGColorSpace.sRGB else {
            throw Failure.changedDestination
        }
    }

    /// Integer-only admission is independently testable without constructing an
    /// enormous image or allocation. Every product/sum is checked before calloc.
    static func admittedStorage(width: Int, height: Int, sourceBytesPerRow: Int,
        sourceBitsPerPixel: Int, limits: Limits) throws -> Int {
        guard width > 0, height > 0, sourceBytesPerRow > 0, sourceBitsPerPixel > 0,
              limits.maximumDimension > 0, limits.maximumOwnedBytes > 0,
              limits.maximumWorkingBytes > 0, limits.maximumActiveOwnedBytes > 0 else { throw Failure.invalidBounds }
        let (row, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (sourceRowBits, bitsOverflow) = width.multipliedReportingOverflow(by: sourceBitsPerPixel)
        let (roundedBits, roundingOverflow) = sourceRowBits.addingReportingOverflow(7)
        let (count, countOverflow) = row.multipliedReportingOverflow(by: height)
        let (sourceCount, sourceOverflow) = sourceBytesPerRow.multipliedReportingOverflow(by: height)
        let (work, workOverflow) = sourceCount.addingReportingOverflow(count)
        guard !rowOverflow, !bitsOverflow, !roundingOverflow, !countOverflow, !sourceOverflow, !workOverflow else {
            throw Failure.storageOverflow
        }
        guard sourceBytesPerRow >= roundedBits / 8 else { throw Failure.invalidBounds }
        guard ImageEditorRenderer.allowsRasterSize(width: width, height: height),
              width <= limits.maximumDimension, height <= limits.maximumDimension,
              count <= limits.maximumOwnedBytes, work <= limits.maximumWorkingBytes,
              count <= limits.maximumActiveOwnedBytes else { throw Failure.admissionRefused }
        return count
    }
    private static func cancellation(_ isCancelled: () -> Bool) throws { if isCancelled() { throw Failure.cancelled } }
}
