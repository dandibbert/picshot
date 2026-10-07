import Accelerate
import CoreGraphics
import CryptoKit
import Foundation
import PicShotCore

/// Full-frame observation conversion uses CGImage, never raw provider offsets.
/// One caller-owned RGBA allocation is retained for this workspace's fixed extent.
/// kvImageNoAllocate applies to that destination, not vImage/ColorSync caches or
/// temporary storage. Actual footprint and volatile backing still need measuring.
final class ManualScrollVImageObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let metadataLock = NSLock()
    private var storage: UnsafeMutableRawPointer?
    private var width = 0
    private var height = 0
    private var byteCount = 0

    deinit { free(storage) }

    var allocatedByteCount: Int {
        // MainActor diagnostics must never wait for conversion/hash to finish.
        metadataLock.lock(); defer { metadataLock.unlock() }
        return byteCount
    }

    func observation(_ image: CGImage) throws -> ManualScrollObservation {
        try withNormalizedPixels(image) { pixels in
            let rowBytes = image.width * 4
            var hash = SHA256()
            for start in stride(from: 0, to: image.height, by: 64) {
                try Task.checkCancellation()
                let offset = start * rowBytes, count = min(64, image.height - start) * rowBytes
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: pixels[offset..<offset + count]))
            }
            try Task.checkCancellation()
            return try ManualScrollObservation(width: image.width, height: image.height,
                                               rgbaSHA256: Array(hash.finalize()))
        }
    }

    /// Borrowed pixels are valid only during this synchronous closure. Native tests
    /// compare every byte with the independent, unchanged CGContext reference.
    func withNormalizedPixels<Result>(_ image: CGImage,
                                      _ consume: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        try Task.checkCancellation()
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        return try autoreleasepool {
            let imageWidth = image.width, imageHeight = image.height
            guard imageWidth > 0, imageHeight > 0,
                  imageWidth <= ScrollFrame.maximumDimension, imageHeight <= ScrollFrame.maximumDimension,
                  imageWidth <= ScrollFrame.maximumPixels / imageHeight else {
                throw ScrollStitchError.invalidPixels
            }
            let rowBytes = imageWidth * 4, count = rowBytes * imageHeight
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                    colorSpace: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                        CGImageAlphaInfo.premultipliedLast.rawValue), renderingIntent: .defaultIntent) else {
                throw ScrollStitchError.invalidPixels
            }
            if storage != nil {
                guard width == imageWidth, height == imageHeight else { throw ScrollStitchError.differentDimensions }
            } else {
                guard let allocated = malloc(count) else { throw ScrollStitchError.invalidPixels }
                storage = allocated; width = imageWidth; height = imageHeight
                metadataLock.lock(); byteCount = count; metadataLock.unlock()
            }
            guard let storage else { throw ScrollStitchError.invalidPixels }
            // Match the reference's empty destination, including transparent input.
            // This is the destination only; no source provider is read or rewritten.
            memset(storage, 0, count)
            var destination = vImage_Buffer(data: storage, height: vImagePixelCount(imageHeight),
                                           width: vImagePixelCount(imageWidth), rowBytes: rowBytes)
            let error = withExtendedLifetime(colorSpace) {
                vImageBuffer_InitWithCGImage(&destination, &format, nil, image, vImage_Flags(kvImageNoAllocate))
            }
            try Task.checkCancellation()
            // Keep ownership in storage, independent of the in/out buffer struct:
            // failure may clear its data pointer. Never free the borrowed descriptor.
            guard error == kvImageNoError else {
                throw NSError(domain: "PicShot.ManualScrollVImage", code: Int(error), userInfo: [
                    NSLocalizedDescriptionKey: "无法读取当前画面。已接受的片段保持不变，请停止后重新选择截图区域。"
                ])
            }
            guard destination.data == storage,
                  destination.width == vImagePixelCount(imageWidth),
                  destination.height == vImagePixelCount(imageHeight), destination.rowBytes == rowBytes else {
                throw ScrollStitchError.invalidPixels
            }
            let result = try consume(UnsafeRawBufferPointer(start: storage, count: count))
            try Task.checkCancellation()
            return result
        }
    }
}
