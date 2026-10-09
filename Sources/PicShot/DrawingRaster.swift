import Accelerate
import CoreGraphics
import Darwin
import Foundation

/// A drawing-only representation. This never changes decoding, model images, their
/// metadata, persistence, copying, reset, annotation geometry or effect inputs.
enum DrawingRasterStrategy: String, CaseIterable, Sendable {
    case reference
    case ownedSRGB8 = "owned-srgb8"
    static let productionDefault: Self = .ownedSRGB8
}

/// Selected once per process. Invalid diagnostic settings remain an error; they
/// cannot silently select a different strategy. Explicit construction is for tests.
struct DrawingRasterConfiguration: @unchecked Sendable {
    let limits: DrawingRaster.Limits
    let tracker: DrawingRasterTracker
    let failureInjection: DrawingRaster.FailureInjection
    /// Explicit test construction only. Observe the actual provider before
    /// CGImage may copy it; process/environment configurations always set nil.
    let providerObserverForTesting: ((CGDataProvider) -> Void)?
    private let selection: Result<DrawingRasterStrategy, DrawingRaster.Failure>

    init(strategy: DrawingRasterStrategy, limits: DrawingRaster.Limits = .standard,
         tracker: DrawingRasterTracker = DrawingRasterTracker(),
         failureInjection: DrawingRaster.FailureInjection = .none,
         providerObserverForTesting: ((CGDataProvider) -> Void)? = nil) {
        self.limits = limits; self.tracker = tracker; self.failureInjection = failureInjection
        self.providerObserverForTesting = providerObserverForTesting
        selection = .success(strategy)
    }
    init(environment: [String: String]) {
        limits = .standard; tracker = DrawingRasterTracker(); failureInjection = .none
        providerObserverForTesting = nil
        do { selection = .success(try Self.selection(environment: environment)) }
        catch { selection = .failure(.invalidConfiguration) }
    }
    static let process = DrawingRasterConfiguration(environment: ProcessInfo.processInfo.environment)
    func selectedStrategy() throws -> DrawingRasterStrategy { try selection.get() }
    static func selection(environment: [String: String]) throws -> DrawingRasterStrategy {
        let keys = environment.keys.filter { $0.hasPrefix("PICSHOT_DRAWING_RASTER") }
        guard keys.allSatisfy({ $0 == "PICSHOT_DRAWING_RASTER_STRATEGY" }) else {
            throw DrawingRaster.Failure.invalidConfiguration
        }
        guard let raw = environment["PICSHOT_DRAWING_RASTER_STRATEGY"] else { return .productionDefault }
        guard environment["PICSHOT_SMOKE_TEST"] == "1",
              let report = environment["PICSHOT_SMOKE_REPORT"], report.hasPrefix("/"), !report.contains("\0"),
              let strategy = DrawingRasterStrategy(rawValue: raw) else { throw DrawingRaster.Failure.invalidConfiguration }
        return strategy
    }
}

/// Scalar diagnostics only. The lifetime of each malloc allocation is distinct
/// from its public provider callback. These counts do not measure native caches,
/// vImage internal scratch, RSS, physical footprint, or volatile memory.
struct DrawingRasterSnapshot: Codable, Equatable {
    var referenceCount = 0, eligibleCount = 0, ownedCount = 0, seededContextCount = 0
    var presentationReuseCount = 0, presentationFallbackCount = 0, failureCount = 0
    var unsupportedCounts: [String: Int] = [:]
    var allocations = 0, deallocations = 0, releaseCallbacks = 0
    var allocatedBytes = 0, deallocatedBytes = 0, callbackBytes = 0
    var activeBytes = 0, peakActiveBytes = 0, seededContextBytes = 0
    var callbackSizesMatch = true
}
final class DrawingRasterTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = DrawingRasterSnapshot()
    private var reservedBytes = 0
    func snapshot() -> DrawingRasterSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    fileprivate func update(_ body: (inout DrawingRasterSnapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&value)
    }
    fileprivate func reserve(_ count: Int, maximum: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, count <= maximum, reservedBytes <= maximum - count else {
            throw DrawingRaster.Failure.admissionRefused
        }
        reservedBytes += count
    }
    fileprivate func allocated(_ count: Int) {
        update {
            $0.allocations += 1; $0.allocatedBytes += count; $0.activeBytes += count
            $0.peakActiveBytes = max($0.peakActiveBytes, $0.activeBytes)
        }
    }
    fileprivate func releaseReservation(_ count: Int) {
        lock.lock(); defer { lock.unlock() }; reservedBytes -= count
    }
    fileprivate func freed(_ count: Int) {
        update { $0.deallocations += 1; $0.deallocatedBytes += count; $0.activeBytes -= count; reservedBytes -= count }
    }
    fileprivate func callback(actual: Int, expected: Int) {
        update { $0.releaseCallbacks += 1; $0.callbackBytes += actual; $0.callbackSizesMatch = $0.callbackSizesMatch && actual == expected }
    }
}

enum DrawingRaster {
    struct Limits: Sendable {
        var maximumDimension = 32_768
        var maximumOwnedBytes = 400_000_000
        /// Source row storage plus this destination, including destination padding.
        var maximumWorkingBytes = 800_000_000
        /// Bound all simultaneously live owned providers sharing this tracker.
        var maximumActiveOwnedBytes = 800_000_000
        static let standard = Limits()
    }
    enum UnsupportedReason: String, Codable, Sendable {
        case imageMask, decodeArray, colorSpace, floatingPoint, componentDepth, channelLayout, byteOrder, bitmapFlags
    }
    enum Outcome: Equatable, Sendable {
        case reference
        case unchanged(UnsupportedReason)
        case owned(bytes: Int)
        case seededContext(bytes: Int)
        case presentationFallback
    }
    struct Representation {
        let image: CGImage
        let outcome: Outcome
    }
    enum Failure: Error, Equatable {
        case invalidConfiguration, invalidBounds, storageOverflow, admissionRefused, cancelled
        case invalidDestination, allocationFailed, conversionFailed(Int), mutatedBuffer, mutatedFormat, providerFailed, imageFailed
        case injectedConversion, injectedProvider
    }
    enum FailureInjection: Sendable { case none, conversion, provider }
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

    private final class Bytes {
        let pointer: UnsafeMutableRawPointer, count: Int
        let tracker: DrawingRasterTracker
        init(count: Int, configuration: DrawingRasterConfiguration) throws {
            tracker = configuration.tracker; self.count = count
            try tracker.reserve(count, maximum: configuration.limits.maximumActiveOwnedBytes)
            guard let pointer = calloc(1, count) else { tracker.releaseReservation(count); throw Failure.allocationFailed }
            self.pointer = pointer; tracker.allocated(count)
        }
        deinit { free(pointer); tracker.freed(count) }
    }

    /// A detached presentation/snapshot provider. This is intentionally never
    /// installed into an original/current/base model slot. Inputs can be decoded
    /// with any source-format policy; only the exact approved drawing layouts enter.
    static func prepare(_ source: CGImage, configuration: DrawingRasterConfiguration = .process,
                        isCancelled: () -> Bool = { false }) throws -> Representation {
        do {
            try cancellation(isCancelled)
            if let outcome = try nativeOutcome(source, configuration: configuration) {
                return Representation(image: source, outcome: outcome)
            }
            guard source.width > 0, source.width <= Int.max / 4 else { throw Failure.invalidBounds }
            let rowBytes = source.width * 4
            let count = try admittedStorage(source, destinationRowBytes: rowBytes, limits: configuration.limits)
            let bytes = try Bytes(count: count, configuration: configuration)
            try convert(source, into: bytes.pointer, rowBytes: rowBytes,
                        configuration: configuration, isCancelled: isCancelled)
            if configuration.failureInjection == .provider { throw Failure.injectedProvider }
            let retained = Unmanaged.passRetained(bytes)
            guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: bytes.pointer, size: count,
                releaseData: { info, _, size in
                    guard let info else { return }
                    let owner = Unmanaged<Bytes>.fromOpaque(info).takeRetainedValue()
                    owner.tracker.callback(actual: size, expected: owner.count)
                }) else { retained.release(); throw Failure.providerFailed }
            configuration.providerObserverForTesting?(provider)
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: source.width, height: source.height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: rowBytes, space: color, bitmapInfo: bitmapInfo,
                    provider: provider, decode: nil, shouldInterpolate: source.shouldInterpolate,
                    intent: source.renderingIntent) else { throw Failure.imageFailed }
            try cancellation(isCancelled)
            configuration.tracker.update { $0.ownedCount += 1 }
            return Representation(image: image, outcome: .owned(bytes: count))
        } catch { configuration.tracker.update { $0.failureCount += 1 }; throw error }
    }

    /// Only call before any draw/clip/transform on a fresh, tightly packed sRGB8
    /// context. No full-size intermediate image is created. Failure poisons the
    /// destination: callers must discard it and must not publish partial pixels.
    @discardableResult
    static func seedFreshSRGB8Context(_ context: CGContext, from source: CGImage,
        configuration: DrawingRasterConfiguration = .process,
        isCancelled: () -> Bool = { false }) throws -> Outcome {
        do {
            try cancellation(isCancelled)
            if let outcome = try nativeOutcome(source, configuration: configuration) {
                context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
                try cancellation(isCancelled)
                return outcome
            }
            guard context.width == source.width, context.height == source.height,
                  context.bitsPerComponent == 8, context.bitsPerPixel == 32,
                  context.bitmapInfo == bitmapInfo,
                  context.colorSpace?.name == CGColorSpace.sRGB,
                  context.ctm == .identity, let pointer = context.data else { throw Failure.invalidDestination }
            let count = try admittedStorage(source, destinationRowBytes: context.bytesPerRow, limits: configuration.limits)
            try convert(source, into: pointer, rowBytes: context.bytesPerRow,
                        configuration: configuration, isCancelled: isCancelled)
            configuration.tracker.update { $0.seededContextCount += 1; $0.seededContextBytes += count }
            return .seededContext(bytes: count)
        } catch { configuration.tracker.update { $0.failureCount += 1 }; throw error }
    }

    /// Return the original native path for unsupported representations. In
    /// particular P3, 16-bit, custom/linear/device profiles and decode arrays must
    /// never be rounded to sRGB8 merely because they are being presented.
    static func unsupported(_ image: CGImage) -> UnsupportedReason? {
        if image.isMask { return .imageMask }
        if image.decode != nil { return .decodeArray }
        guard let color = image.colorSpace, color.model == .rgb, color.numberOfComponents == 3,
              color.name == CGColorSpace.sRGB else { return .colorSpace }
        if image.bitmapInfo.contains(.floatComponents) { return .floatingPoint }
        guard image.bitsPerComponent == 8 else { return .componentDepth }
        let channels: Int
        switch image.alphaInfo {
        case .none: channels = 3
        case .first, .last, .premultipliedFirst, .premultipliedLast, .noneSkipFirst, .noneSkipLast: channels = 4
        default: return .channelLayout
        }
        guard image.bitsPerPixel == channels * 8 else { return .channelLayout }
        let known = CGBitmapInfo.alphaInfoMask.rawValue | CGBitmapInfo.byteOrderMask.rawValue
        guard image.bitmapInfo.rawValue & ~known == 0 else { return .bitmapFlags }
        let orders: [CGBitmapInfo] = channels == 4 ? [.byteOrderDefault, .byteOrder32Big, .byteOrder32Little] : [.byteOrderDefault]
        guard orders.contains(image.bitmapInfo.intersection(.byteOrderMask)) else { return .byteOrder }
        return nil
    }
    private static func nativeOutcome(_ source: CGImage, configuration: DrawingRasterConfiguration) throws -> Outcome? {
        guard try configuration.selectedStrategy() == .ownedSRGB8 else {
            configuration.tracker.update { $0.referenceCount += 1 }; return .reference
        }
        if let reason = unsupported(source) {
            configuration.tracker.update { $0.unsupportedCounts[reason.rawValue, default: 0] += 1 }
            return .unchanged(reason)
        }
        configuration.tracker.update { $0.eligibleCount += 1 }; return nil
    }
    static func admittedStorage(_ source: CGImage, destinationRowBytes: Int, limits: Limits) throws -> Int {
        guard source.width > 0, source.height > 0, source.width <= Int.max / 4,
              source.bitsPerPixel > 0, source.width <= (Int.max - 7) / source.bitsPerPixel,
              destinationRowBytes >= source.width * 4,
              source.bytesPerRow >= (source.width * source.bitsPerPixel + 7) / 8,
              limits.maximumDimension > 0, limits.maximumOwnedBytes > 0,
              limits.maximumWorkingBytes > 0, limits.maximumActiveOwnedBytes > 0 else { throw Failure.invalidBounds }
        let (sourceCount, sourceOverflow) = source.bytesPerRow.multipliedReportingOverflow(by: source.height)
        let (count, overflow) = destinationRowBytes.multipliedReportingOverflow(by: source.height)
        let (work, workOverflow) = sourceCount.addingReportingOverflow(count)
        guard !sourceOverflow, !overflow, !workOverflow else { throw Failure.storageOverflow }
        guard source.width <= limits.maximumDimension, source.height <= limits.maximumDimension,
              count <= limits.maximumOwnedBytes, work <= limits.maximumWorkingBytes else { throw Failure.admissionRefused }
        return count
    }
    private static func cancellation(_ isCancelled: () -> Bool) throws { if isCancelled() { throw Failure.cancelled } }
    private static func convert(_ source: CGImage, into pointer: UnsafeMutableRawPointer, rowBytes: Int,
        configuration: DrawingRasterConfiguration, isCancelled: () -> Bool) throws {
        try cancellation(isCancelled)
        // Public API conversion honors source alpha/order and uses the same
        // destination color/intent as the independent fresh-context reference.
        guard let color = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.invalidDestination }
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(color), bitmapInfo: bitmapInfo, version: 0,
            decode: nil, renderingIntent: .defaultIntent)
        var destination = vImage_Buffer(data: pointer, height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width), rowBytes: rowBytes)
        if configuration.failureInjection == .conversion {
            // Partial writes deliberately exercise fail-closed caller behavior.
            pointer.storeBytes(of: UInt8(0xA5), as: UInt8.self)
            throw Failure.injectedConversion
        }
        let error = withExtendedLifetime((source, color)) {
            vImageBuffer_InitWithCGImage(&destination, &format, nil, source, vImage_Flags(kvImageNoAllocate))
        }
        try cancellation(isCancelled)
        guard error == kvImageNoError else { throw Failure.conversionFailed(Int(error)) }
        guard destination.data == pointer, destination.width == vImagePixelCount(source.width),
              destination.height == vImagePixelCount(source.height), destination.rowBytes == rowBytes else { throw Failure.mutatedBuffer }
        guard format.bitsPerComponent == 8, format.bitsPerPixel == 32, format.bitmapInfo == bitmapInfo,
              format.version == 0, format.decode == nil, format.renderingIntent == .defaultIntent,
              format.colorSpace?.takeUnretainedValue() === color else { throw Failure.mutatedFormat }
    }
}

/// One view owns one representation for its current immutable image. Same-image
/// layout/zoom/redraw does not convert again. A failed attempt keeps correct
/// source pixels, records fallback, and is not retried until identity changes.
@MainActor final class DrawingRasterPresentationCache {
    let configuration: DrawingRasterConfiguration
    private var source: CGImage?
    private(set) var representation: DrawingRaster.Representation?
    var retainedBytes: Int {
        if case .owned(let bytes)? = representation?.outcome { return bytes }; return 0
    }
    init(configuration: DrawingRasterConfiguration = .process) { self.configuration = configuration }
    func image(for image: CGImage) -> CGImage {
        if source === image, let representation {
            configuration.tracker.update { $0.presentationReuseCount += 1 }; return representation.image
        }
        clear()
        source = image
        do { representation = try DrawingRaster.prepare(image, configuration: configuration) }
        catch {
            configuration.tracker.update { $0.presentationFallbackCount += 1 }
            representation = .init(image: image, outcome: .presentationFallback)
        }
        return representation!.image
    }
    func clear() { representation = nil; source = nil }
}
