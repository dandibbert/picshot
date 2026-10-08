import Foundation
import CoreGraphics
import ImageIO
import PicShotCore

/// System-selector PNGs keep the existing 100M-pixel/128MiB-file contract.
/// Header cost is checked before image creation; uncached-image stride is
/// checked before application drawing. ImageIO can still allocate/decode internally.
/// The output owns exactly one encoded Data reference through its ImageIO image;
/// no readback/copy of the full provider, raster clone, or thumbnail is requested.
enum SystemCaptureDecoder {
    static func read(url: URL, capturedAt: Date = Date()) throws -> CapturedImage {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= CaptureRecoveryPolicy.maximumEncodedBytes else {
            throw CaptureRecoveryError.unsupportedBacking
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: CaptureRecoveryPolicy.maximumEncodedBytes + 1) ?? Data()
        guard data.count == size,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let depth = properties[kCGImagePropertyDepth] as? Int,
              CaptureRecoveryPolicy.allowsSystemHeader(width: width, height: height, depth: depth, encodedBytes: data.count)
        else { throw CaptureRecoveryError.unsupportedBacking }
        // Request no cache, then refuse actual row stride/component layout before
        // application drawing. This flag is not proof against internal ImageIO
        // decoding/allocation during image creation; private costs remain outside
        // the managed backing reservation and require native measurement.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == width, image.height == height,
              image.bitsPerComponent > 0, image.bitsPerComponent <= 16, image.bitsPerPixel <= 64,
              CaptureRecoveryPolicy.retainedBytes(rasterBytes: EditorRasterEstimate.retainedBytes([image]),
                                                  encodedBytes: data.count) != nil else {
            throw CaptureRecoveryError.unsupportedBacking
        }
        return CapturedImage(image: image, presentation: nil, capturedAt: capturedAt, encodedBackingBytes: data.count)
    }
}
