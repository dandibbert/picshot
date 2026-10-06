import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PicShotCodecCore

/// Explicit straight-alpha, top-to-bottom RGBA8 sRGB. Lossless export preserves
/// these normalized semantic pixels; no hidden RGB is recovered at zero alpha.
struct CodecRaster {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) throws {
        try CodecExportLimits.validateStillDimensions(width: width, height: height)
        guard rgba.count == width * height * 4 else { throw CodecExportFailure(.invalidSource) }
        self.width = width; self.height = height; self.rgba = rgba
    }
    init(image: CGImage, preserveAlpha: Bool = true, isCancelled: () -> Bool = { false }) throws {
        try CodecExportLimits.validateStillDimensions(width: image.width, height: image.height)
        width = image.width; height = image.height
        let w = width, h = height
        rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
        let success = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard success else { throw CodecExportFailure(.invalidSource) }
        try Self.normalizePremultiplied(&rgba, width: w, height: h, preserveAlpha: preserveAlpha, isCancelled: isCancelled)
    }
    static func normalizePremultiplied(_ rgba: inout [UInt8], width: Int, height: Int, preserveAlpha: Bool,
                                      isCancelled: () -> Bool = { false }) throws {
        try CodecExportLimits.validateStillDimensions(width: width, height: height)
        guard rgba.count == width * height * 4 else { throw CodecExportFailure(.invalidSource) }
        for y in 0..<height {
            guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
            for x in 0..<width {
                let offset = (y * width + x) * 4, alpha = Int(rgba[offset + 3])
                for channel in 0..<3 {
                    let premultiplied = min(alpha, Int(rgba[offset + channel]))
                    rgba[offset + channel] = preserveAlpha
                        ? UInt8(alpha == 0 ? 0 : min(255, (premultiplied * 255 + alpha / 2) / alpha))
                        : UInt8(min(255, premultiplied + 255 - alpha))
                }
                if !preserveAlpha { rgba[offset + 3] = 255 }
            }
        }
    }
    func image() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CodecExportFailure(.invalidOutput) }
        return image
    }
    static func readFrozenPNG(files: CodecJobFiles, preserveAlpha: Bool, isCancelled: () -> Bool) throws -> Self {
        let fd = try files.openSource()
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        let data = try CodecFileIO.read(handle, maximum: CodecExportLimits.stillInputBytes, isCancelled: isCancelled)
        try files.validateSourceIdentity()
        try validatePNGHeader(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        else { throw CodecExportFailure(.invalidSource) }
        try CodecExportLimits.validateStillDimensions(width: width, height: height)
        guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height else { throw CodecExportFailure(.invalidSource) }
        return try Self(image: image, preserveAlpha: preserveAlpha, isCancelled: isCancelled)
    }
    static func validatePNGHeader(_ data: Data) throws {
        guard data.count >= 33, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(data[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { throw CodecExportFailure(.invalidSource) }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        try CodecExportLimits.validateStillDimensions(width: Int(width), height: Int(height))
    }
}
