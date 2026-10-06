import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Canonical 8-bit premultiplied sRGB RGBA pixels. Unselected bytes are copied
/// verbatim from this raster after inference; the model cannot repaint them.
public struct SmartEraseRaster {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        try SmartEraseMask.validateDimensions(width: width, height: height)
        guard rgba.count == width * height * 4 else { throw SmartEraseError.invalidInput }
        self.width = width; self.height = height; self.rgba = rgba
    }
    public init(image: CGImage) throws {
        try SmartEraseMask.validateDimensions(width: image.width, height: image.height)
        width = image.width; height = image.height
        rgba = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard success else { throw SmartEraseError.invalidInput }
    }
    public func image() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw SmartEraseError.invalidOutput }
        return image
    }
    public static func readImage(_ url: URL) throws -> CGImage {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= SmartEraseLimits.imageBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw SmartEraseError.invalidInput }
        try SmartEraseMask.validateDimensions(width: width, height: height)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw SmartEraseError.invalidInput }
        return image
    }
    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw SmartEraseError.invalidOutput }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= SmartEraseLimits.imageBytes else { throw SmartEraseError.invalidOutput }
        return data as Data
    }

    /// Bilinear sampling with edge replication preserves aspect ratio in a
    /// square context crop; rectangular images are padded instead of stretched.
    public func sample(x: Double, y: Double, channel: Int) -> Double {
        let px = max(0, min(Double(width - 1), x)), py = max(0, min(Double(height - 1), y))
        let x0 = Int(px), y0 = Int(py), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let dx = px - Double(x0), dy = py - Double(y0)
        let a = Double(rgba[(y0 * width + x0) * 4 + channel])
        let b = Double(rgba[(y0 * width + x1) * 4 + channel])
        let c = Double(rgba[(y1 * width + x0) * 4 + channel])
        let d = Double(rgba[(y1 * width + x1) * 4 + channel])
        return (a * (1 - dx) + b * dx) * (1 - dy) + (c * (1 - dx) + d * dx) * dy
    }

    public func compositing(prediction: SmartEraseRaster, mask: Data, crop: SmartEraseCrop) throws -> SmartEraseRaster {
        guard mask.count == width * height, prediction.width == SmartEraseLimits.modelSide,
              prediction.height == SmartEraseLimits.modelSide, crop.side > 0 else { throw SmartEraseError.invalidOutput }
        var result = self
        let scale = Double(SmartEraseLimits.modelSide) / Double(crop.side)
        for (index, value) in mask.enumerated() where value > 0 {
            let x = (Double(index % width - crop.x) + 0.5) * scale - 0.5
            let y = (Double(index / width - crop.y) + 0.5) * scale - 0.5
            let alpha = Double(rgba[index * 4 + 3]) / 255
            for channel in 0..<3 {
                let sample = prediction.sample(x: x, y: y, channel: channel) * alpha
                guard sample.isFinite else { throw SmartEraseError.invalidOutput }
                result.rgba[index * 4 + channel] = UInt8(max(0, min(255, sample.rounded())))
            }
        }
        return result
    }
}
