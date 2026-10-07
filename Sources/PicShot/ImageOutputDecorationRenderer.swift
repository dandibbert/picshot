import Accelerate
import CoreGraphics
import Foundation

/// Measures only allocations owned by this renderer, not process RSS or native
/// ColorSync/vImage scratch. A probe retains no images or conversion workspaces.
final class ImageOutputDecorationResourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0, peak = 0, allocations = 0
    var currentBytes: Int { lock.lock(); defer { lock.unlock() }; return current }
    var peakBytes: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var allocationCount: Int { lock.lock(); defer { lock.unlock() }; return allocations }
    fileprivate func acquired(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        current += bytes; peak = max(peak, current); allocations += 1
    }
    fileprivate func released(_ bytes: Int) { lock.lock(); current -= bytes; lock.unlock() }
}

private final class DecorationBuffer {
    let pointer: UnsafeMutableRawPointer
    let count: Int
    let probe: ImageOutputDecorationResourceProbe?
    init(count: Int, probe: ImageOutputDecorationResourceProbe?) throws {
        guard count > 0, let pointer = calloc(1, count) else { throw ImageOutputDecorationError.allocationFailed }
        self.pointer = pointer; self.count = count; self.probe = probe; probe?.acquired(count)
    }
    deinit { free(pointer); probe?.released(count) }
}

/// Pure output projection. Input pixels/providers are never mutated. No cache is
/// retained: one RGBA output and at most two one-channel shadow buffers plus
/// bounded native convolution scratch. A CGDataProvider owns the final RGBA
/// allocation and releases it with the returned image.
enum ImageOutputDecorationRenderer {
    struct PreviewSource: @unchecked Sendable {
        let image: CGImage
        let scale: Double
    }

    /// One ephemeral full-color normalization is released before returning the
    /// small preview source. Scaling a CGImage through an NSImage/CGContext here
    /// can retain a second decoded full-color cache for each edited snapshot.
    static func previewSource(image: CGImage, maximumDimension: Int = 512,
                              cancellation: ImageExportCancellation,
                              resourceProbe: ImageOutputDecorationResourceProbe? = nil) throws -> PreviewSource {
        try cancellation.check()
        guard maximumDimension > 0, maximumDimension <= 1_024,
              image.width > 0, image.height > 0,
              image.width <= ImageOutputDecorationLimits.standard.maximumDimension,
              image.height <= ImageOutputDecorationLimits.standard.maximumDimension,
              image.width <= ImageOutputDecorationLimits.standard.maximumPixels / image.height else {
            throw ImageOutputDecorationError.tooLarge
        }
        let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
        return try autoreleasepool {
            let count = image.width * image.height * 4, smallCount = width * height * 4
            guard count <= ImageOutputDecorationLimits.standard.maximumWorkingBytes - smallCount else {
                throw ImageOutputDecorationError.tooLarge
            }
            let input = try DecorationBuffer(count: count, probe: resourceProbe)
            let output = try DecorationBuffer(count: smallCount, probe: resourceProbe)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                        CGImageAlphaInfo.premultipliedLast.rawValue), renderingIntent: .defaultIntent) else {
                throw ImageOutputDecorationError.conversionFailed
            }
            var source = vImage_Buffer(data: input.pointer, height: vImagePixelCount(image.height), width: vImagePixelCount(image.width), rowBytes: image.width * 4)
            let error = withExtendedLifetime(space) {
                vImageBuffer_InitWithCGImage(&source, &format, nil, image, vImage_Flags(kvImageNoAllocate))
            }
            try cancellation.check()
            guard error == kvImageNoError, source.data == input.pointer,
                  source.width == vImagePixelCount(image.width), source.height == vImagePixelCount(image.height),
                  source.rowBytes == image.width * 4 else { throw ImageOutputDecorationError.conversionFailed }
            var destination = vImage_Buffer(data: output.pointer, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            let flags = vImage_Flags(kvImageHighQualityResampling)
            let required = vImageScale_ARGB8888(&source, &destination, nil, flags | vImage_Flags(kvImageGetTempBufferSize))
            guard required >= 0 else { throw ImageOutputDecorationError.conversionFailed }
            guard required <= ImageOutputDecorationLimits.standard.maximumWorkingBytes - count - smallCount else {
                throw ImageOutputDecorationError.tooLarge
            }
            let scratch = required > 0 ? try DecorationBuffer(count: required, probe: resourceProbe) : nil
            guard vImageScale_ARGB8888(&source, &destination, scratch?.pointer, flags) == kvImageNoError else {
                throw ImageOutputDecorationError.conversionFailed
            }
            try cancellation.check()
            let owner = Unmanaged.passRetained(output).toOpaque()
            guard let provider = CGDataProvider(dataInfo: owner, data: output.pointer, size: output.count,
                releaseData: { info, _, _ in if let info { Unmanaged<DecorationBuffer>.fromOpaque(info).release() } }) else {
                Unmanaged<DecorationBuffer>.fromOpaque(owner).release(); throw ImageOutputDecorationError.allocationFailed
            }
            guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space, bitmapInfo: format.bitmapInfo, provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ImageOutputDecorationError.conversionFailed }
            try cancellation.check()
            return PreviewSource(image: image, scale: scale)
        }
    }

    static func project(flattened image: CGImage, decoration: ImageOutputDecoration,
                        cancellation: ImageExportCancellation = ImageExportCancellation(),
                        limits: ImageOutputDecorationLimits = .standard,
                        resourceProbe: ImageOutputDecorationResourceProbe? = nil) throws -> CGImage {
        try cancellation.check()
        if !decoration.enabled { return image }
        try decoration.validate()
        if decoration.isIdentity { return image }
        let layout = try ImageOutputDecorationLayout.make(width: image.width, height: image.height,
                                                          decoration: decoration, limits: limits)
        return try autoreleasepool {
            let output = try DecorationBuffer(count: layout.width * layout.height * 4, probe: resourceProbe)
            try cancellation.check()
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                        CGImageAlphaInfo.premultipliedLast.rawValue), renderingIntent: .defaultIntent) else {
                throw ImageOutputDecorationError.conversionFailed
            }
            // vImage accepts a padded row stride; write only the original image
            // rectangle. No raw input-provider offsets or extra RGBA snapshot.
            let rowBytes = layout.width * 4
            let start = output.pointer.advanced(by: layout.top * rowBytes + layout.left * 4)
            var destination = vImage_Buffer(data: start, height: vImagePixelCount(image.height),
                width: vImagePixelCount(image.width), rowBytes: rowBytes)
            let result = withExtendedLifetime(colorSpace) {
                vImageBuffer_InitWithCGImage(&destination, &format, nil, image, vImage_Flags(kvImageNoAllocate))
            }
            try cancellation.check()
            guard result == kvImageNoError, destination.data == start,
                  destination.width == vImagePixelCount(image.width), destination.height == vImagePixelCount(image.height),
                  destination.rowBytes == rowBytes else { throw ImageOutputDecorationError.conversionFailed }
            try applyShapeAndBorder(output, imageWidth: image.width, imageHeight: image.height,
                                    layout: layout, decoration: decoration, cancellation: cancellation)
            if decoration.hasShadow {
                try applyShadow(output, layout: layout, decoration: decoration, cancellation: cancellation,
                                limits: limits, probe: resourceProbe)
            }
            try cancellation.check()
            // This owner is transferred exactly once; the input image is never
            // retained by the output provider or by a global conversion cache.
            let owner = Unmanaged.passRetained(output).toOpaque()
            guard let provider = CGDataProvider(dataInfo: owner, data: output.pointer, size: output.count,
                releaseData: { info, _, _ in
                    if let info { Unmanaged<DecorationBuffer>.fromOpaque(info).release() }
                }) else {
                Unmanaged<DecorationBuffer>.fromOpaque(owner).release()
                throw ImageOutputDecorationError.allocationFailed
            }
            guard let projected = CGImage(width: layout.width, height: layout.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
                bitmapInfo: format.bitmapInfo, provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent) else { throw ImageOutputDecorationError.conversionFailed }
            try cancellation.check()
            return projected
        }
    }

    private static func applyShapeAndBorder(_ output: DecorationBuffer, imageWidth: Int, imageHeight: Int,
        layout: ImageOutputDecorationLayout, decoration: ImageOutputDecoration,
        cancellation: ImageExportCancellation) throws {
        let pixels = output.pointer.assumingMemoryBound(to: UInt8.self)
        let width = Double(imageWidth), height = Double(imageHeight)
        let border = layout.borderWidth
        let color = decoration.borderColor
        for y in 0..<imageHeight {
            if y % 32 == 0 { try cancellation.check() }
            for x in 0..<imageWidth {
                let outer = coverage(x: Double(x), y: Double(y), left: 0, top: 0, width: width, height: height, radius: layout.radius)
                let inner = border > 0 ? coverage(x: Double(x), y: Double(y), left: border, top: border,
                    width: max(0, width - 2 * border), height: max(0, height - 2 * border), radius: max(0, layout.radius - border)) : outer
                let ringAlpha = max(0, outer - inner) * (decoration.hasBorder ? color.alpha : 0)
                let sourceWeight = outer - ringAlpha
                if sourceWeight == 1 && ringAlpha == 0 { continue }
                let index = ((y + layout.top) * layout.width + x + layout.left) * 4
                pixels[index] = byte(Double(pixels[index]) * sourceWeight + color.red * 255 * ringAlpha)
                pixels[index + 1] = byte(Double(pixels[index + 1]) * sourceWeight + color.green * 255 * ringAlpha)
                pixels[index + 2] = byte(Double(pixels[index + 2]) * sourceWeight + color.blue * 255 * ringAlpha)
                pixels[index + 3] = byte(Double(pixels[index + 3]) * sourceWeight + 255 * ringAlpha)
            }
        }
    }

    private static func applyShadow(_ output: DecorationBuffer, layout: ImageOutputDecorationLayout,
        decoration: ImageOutputDecoration, cancellation: ImageExportCancellation,
        limits: ImageOutputDecorationLimits, probe: ImageOutputDecorationResourceProbe?) throws {
        let count = layout.width * layout.height
        let first = try DecorationBuffer(count: count, probe: probe)
        let second = try DecorationBuffer(count: count, probe: probe)
        let pixels = output.pointer.assumingMemoryBound(to: UInt8.self)
        let mask = first.pointer.assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> Double {
            guard x >= 0, y >= 0, x < layout.width, y < layout.height else { return 0 }
            return Double(pixels[(y * layout.width + x) * 4 + 3])
        }
        // Sample the ACTUAL rounded/bordered alpha, so disjoint windows and
        // transparent holes cast their own silhouettes, never a solid rectangle.
        for y in 0..<layout.height {
            if y % 32 == 0 { try cancellation.check() }
            let sourceY = Double(y) - decoration.shadowOffsetY, y0 = Int(floor(sourceY)), fy = sourceY - Double(y0)
            for x in 0..<layout.width {
                let sourceX = Double(x) - decoration.shadowOffsetX, x0 = Int(floor(sourceX)), fx = sourceX - Double(x0)
                mask[y * layout.width + x] = byte(
                    alpha(x0, y0) * (1 - fx) * (1 - fy) + alpha(x0 + 1, y0) * fx * (1 - fy) +
                    alpha(x0, y0 + 1) * (1 - fx) * fy + alpha(x0 + 1, y0 + 1) * fx * fy)
            }
        }
        var source = vImage_Buffer(data: first.pointer, height: vImagePixelCount(layout.height), width: vImagePixelCount(layout.width), rowBytes: layout.width)
        var destination = vImage_Buffer(data: second.pointer, height: source.height, width: source.width, rowBytes: source.rowBytes)
        if layout.shadowBoxRadius > 0 {
            let kernel = UInt32(layout.shadowBoxRadius * 2 + 1)
            let flags = vImage_Flags(kvImageBackgroundColorFill)
            let required = vImageBoxConvolve_Planar8(&source, &destination, nil, 0, 0, kernel, kernel, 0,
                flags | vImage_Flags(kvImageGetTempBufferSize))
            guard required >= 0 else { throw ImageOutputDecorationError.conversionFailed }
            guard required <= limits.maximumWorkingBytes - layout.workingBytes else { throw ImageOutputDecorationError.tooLarge }
            let scratch = required > 0 ? try DecorationBuffer(count: required, probe: probe) : nil
            for _ in 0..<3 {
                try cancellation.check()
                let error = vImageBoxConvolve_Planar8(&source, &destination, scratch?.pointer, 0, 0, kernel, kernel, 0, flags)
                guard error == kvImageNoError else { throw ImageOutputDecorationError.conversionFailed }
                swap(&source, &destination)
            }
        }
        try cancellation.check()
        let blurred = source.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<layout.height {
            if y % 32 == 0 { try cancellation.check() }
            for x in 0..<layout.width {
                let index = y * layout.width + x, pixel = index * 4
                // Premultiplied black behind the decorated image changes alpha
                // only. Fully opaque interiors retain every normalized byte.
                let alpha = Double(pixels[pixel + 3])
                pixels[pixel + 3] = byte(alpha + Double(blurred[index]) * decoration.shadowOpacity * (1 - alpha / 255))
            }
        }
    }

    private static func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, value.rounded()))) }

    /// Only boundary pixels need 4×4 subpixel samples. Integral straight edges
    /// and unmodified interiors resolve exactly; no full-size coverage raster.
    private static func coverage(x: Double, y: Double, left: Double, top: Double,
                                 width: Double, height: Double, radius: Double) -> Double {
        guard width > 0, height > 0, x + 1 > left, y + 1 > top, x < left + width, y < top + height else { return 0 }
        let right = left + width, bottom = top + height
        let r = min(radius, min(width, height) / 2)
        func inside(_ px: Double, _ py: Double) -> Bool {
            guard px >= left, py >= top, px <= right, py <= bottom else { return false }
            let dx = max(0, max(left + r - px, px - (right - r)))
            let dy = max(0, max(top + r - py, py - (bottom - r)))
            return dx * dx + dy * dy <= r * r
        }
        if inside(x, y), inside(x + 1, y), inside(x, y + 1), inside(x + 1, y + 1) { return 1 }
        var hits = 0
        for sy in 0..<4 { for sx in 0..<4 {
            if inside(x + (Double(sx) + 0.5) / 4, y + (Double(sy) + 0.5) / 4) { hits += 1 }
        } }
        return Double(hits) / 16
    }
}
