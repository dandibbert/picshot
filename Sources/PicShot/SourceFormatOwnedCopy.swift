import Accelerate
import CoreGraphics
import Darwin
import Foundation

/// Diagnostic candidate only: no production decoder calls this helper.
/// A same-format vImage copy avoids the any-to-any conversion step, but native
/// sample tests must qualify each layout before any production adoption.
/// https://developer.apple.com/documentation/accelerate/vimagebuffer_initwithcgimage(_:_:_:_:_:)
enum SourceFormatOwnedCopy {
    struct Limits {
        let maximumDimension: Int
        let maximumOwnedBytes: Int
        /// Source row storage plus the destination, not a process-memory limit.
        let maximumCopyWorkBytes: Int
    }
    enum UnsupportedReason: String {
        case imageMask, decodeArray, colorSpace, floatingPoint, componentDepth, channelLayout, byteOrder
    }
    enum Outcome {
        case owned(image: CGImage, bytes: Int)
        case unchanged(image: CGImage, reason: UnsupportedReason)
        var image: CGImage {
            switch self { case .owned(let image, _), .unchanged(let image, _): return image }
        }
    }
    enum Failure: Error, Equatable {
        case invalidBounds, storageOverflow, admissionRefused, cancelled, allocationFailed
        case copyFailed(Int), mutatedBuffer, mutatedFormat, providerFailed, imageFailed, changedMetadata
    }

    /// The callback owns only destination storage and optional scalar lifetime
    /// accounting. It never retains the source image, provider, format or data.
    private final class Bytes {
        let pointer: UnsafeMutableRawPointer, count: Int
        let tracker: ImageDrawAllocationTracker?
        init(count: Int, tracker: ImageDrawAllocationTracker?) throws {
            try tracker?.reserve(count)
            guard let pointer = calloc(1, count) else {
                tracker?.freed(count) // Balance the accepted reservation on allocation failure.
                throw Failure.allocationFailed
            }
            self.pointer = pointer; self.count = count; self.tracker = tracker
        }
        deinit { free(pointer); tracker?.freed(count) }
        func callback(_ size: Int) { tracker?.callback(size: size) }
    }

    /// This synchronous boundary checks cancellation at three fences; vImage
    /// itself is synchronous and is not interrupted while copying.
    static func copy(_ source: CGImage, limits: Limits,
        tracker: ImageDrawAllocationTracker? = nil, isCancelled: () -> Bool = { false }) throws -> Outcome {
        try cancellation(isCancelled)
        _ = try validStorage(width: source.width, height: source.height,
            bitsPerPixel: source.bitsPerPixel, bytesPerRow: source.bytesPerRow)
        if let reason = unsupported(source) { return .unchanged(image: source, reason: reason) }
        let byteCount = try checkedStorage(width: source.width, height: source.height,
            bitsPerPixel: source.bitsPerPixel, bytesPerRow: source.bytesPerRow, limits: limits)
        guard let color = source.colorSpace else { throw Failure.changedMetadata }
        let bytes = try Bytes(count: byteCount, tracker: tracker)
        // Populate every field explicitly. The color-space reference is borrowed
        // only for this synchronous scope; no color-space replacement is wanted.
        var format = vImage_CGImageFormat(bitsPerComponent: UInt32(source.bitsPerComponent),
            bitsPerPixel: UInt32(source.bitsPerPixel), colorSpace: Unmanaged.passUnretained(color),
            bitmapInfo: source.bitmapInfo, version: 0, decode: nil, renderingIntent: source.renderingIntent)
        var buffer = vImage_Buffer(data: bytes.pointer, height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width), rowBytes: source.bytesPerRow)
        let error = withExtendedLifetime((source, color)) {
            vImageBuffer_InitWithCGImage(&buffer, &format, nil, source, vImage_Flags(kvImageNoAllocate))
        }
        try cancellation(isCancelled)
        guard error == kvImageNoError else { throw Failure.copyFailed(Int(error)) }
        guard buffer.data == bytes.pointer, buffer.width == vImagePixelCount(source.width), buffer.height == vImagePixelCount(source.height),
              buffer.rowBytes == source.bytesPerRow else { throw Failure.mutatedBuffer }
        guard format.bitsPerComponent == UInt32(source.bitsPerComponent), format.bitsPerPixel == UInt32(source.bitsPerPixel),
              format.bitmapInfo == source.bitmapInfo, format.version == 0, format.decode == nil,
              format.renderingIntent == source.renderingIntent,
              format.colorSpace?.takeUnretainedValue() === color else { throw Failure.mutatedFormat }
        let retained = Unmanaged.passRetained(bytes)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: bytes.pointer, size: byteCount,
            releaseData: { info, _, count in
                guard let info else { return }
                let owner = Unmanaged<Bytes>.fromOpaque(info).takeRetainedValue()
                owner.callback(count)
            }) else { retained.release(); throw Failure.providerFailed }
        guard let image = CGImage(width: source.width, height: source.height,
            bitsPerComponent: source.bitsPerComponent, bitsPerPixel: source.bitsPerPixel,
            bytesPerRow: source.bytesPerRow, space: color, bitmapInfo: source.bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: source.shouldInterpolate,
            intent: source.renderingIntent) else { throw Failure.imageFailed }
        guard metadataMatches(source, image) else { throw Failure.changedMetadata }
        try cancellation(isCancelled)
        return .owned(image: image, bytes: byteCount)
    }

    /// Validate source shape before classifying it. Destination admission is
    /// separate: a valid unsupported image allocates nothing and remains usable
    /// even when it exceeds the owned-copy budget.
    private static func validStorage(width: Int, height: Int, bitsPerPixel: Int, bytesPerRow: Int) throws -> Int {
        guard width > 0, height > 0, bitsPerPixel > 0, bytesPerRow > 0 else { throw Failure.invalidBounds }
        let (rowBits, bitsOverflow) = width.multipliedReportingOverflow(by: bitsPerPixel)
        let (roundedBits, roundingOverflow) = rowBits.addingReportingOverflow(7)
        let (bytes, storageOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !bitsOverflow, !roundingOverflow, !storageOverflow else { throw Failure.storageOverflow }
        guard bytesPerRow >= roundedBits / 8 else { throw Failure.invalidBounds }
        return bytes
    }
    static func checkedStorage(width: Int, height: Int, bitsPerPixel: Int, bytesPerRow: Int,
        limits: Limits) throws -> Int {
        let bytes = try validStorage(width: width, height: height, bitsPerPixel: bitsPerPixel, bytesPerRow: bytesPerRow)
        guard limits.maximumDimension > 0, limits.maximumOwnedBytes > 0, limits.maximumCopyWorkBytes > 0 else {
            throw Failure.invalidBounds
        }
        let (workBytes, overflow) = bytes.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw Failure.storageOverflow }
        guard width <= limits.maximumDimension, height <= limits.maximumDimension,
              bytes <= limits.maximumOwnedBytes, workBytes <= limits.maximumCopyWorkBytes else { throw Failure.admissionRefused }
        return bytes
    }
    private static func cancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw Failure.cancelled }
    }
    private static func unsupported(_ image: CGImage) -> UnsupportedReason? {
        if image.isMask { return .imageMask }
        if image.decode != nil { return .decodeArray }
        guard let color = image.colorSpace, color.model == .rgb, color.numberOfComponents == 3 else { return .colorSpace }
        if image.bitmapInfo.contains(.floatComponents) { return .floatingPoint }
        guard image.bitsPerComponent == 8 || image.bitsPerComponent == 16 else { return .componentDepth }
        let channels: Int
        switch image.alphaInfo {
        case .none: channels = 3
        case .first, .last, .premultipliedFirst, .premultipliedLast, .noneSkipFirst, .noneSkipLast: channels = 4
        default: return .channelLayout
        }
        guard image.bitsPerPixel == image.bitsPerComponent * channels else { return .channelLayout }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let permitted: [CGBitmapInfo] = image.bitsPerComponent == 16
            ? [.byteOrderDefault, .byteOrder16Big, .byteOrder16Little]
            : (channels == 4 ? [.byteOrderDefault, .byteOrder32Big, .byteOrder32Little] : [.byteOrderDefault])
        guard permitted.contains(order) else { return .byteOrder }
        let known = CGBitmapInfo.alphaInfoMask.rawValue | CGBitmapInfo.byteOrderMask.rawValue
        guard image.bitmapInfo.rawValue & ~known == 0 else { return .channelLayout }
        return nil
    }
    static func metadataMatches(_ source: CGImage, _ image: CGImage) -> Bool {
        source.width == image.width && source.height == image.height
            && source.bitsPerComponent == image.bitsPerComponent && source.bitsPerPixel == image.bitsPerPixel
            && source.bytesPerRow == image.bytesPerRow && source.bitmapInfo == image.bitmapInfo
            && source.alphaInfo == image.alphaInfo && source.colorSpace === image.colorSpace
            && source.renderingIntent == image.renderingIntent && source.shouldInterpolate == image.shouldInterpolate
            && source.decode == nil && image.decode == nil && !source.isMask && !image.isMask
    }
}
