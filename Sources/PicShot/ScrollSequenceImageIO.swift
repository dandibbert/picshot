import AppKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// Only this metadata is retained per capture. The original PNG is never overwritten by cuts.
struct StoredScrollSource: Sendable {
    let id: UUID
    let url: URL
    let width: Int
    let height: Int
    let byteCount: Int64
}

enum ScrollSequenceImageError: Error, LocalizedError {
    case missingSource, changedSource, storageLimit, writeFailed
    var errorDescription: String? {
        switch self {
        case .storageLimit: return "This session reached its 512 MB temporary-storage limit. Finish this image and start another."
        case .writeFailed: return "The temporary scroll image could not be written."
        case .missingSource: return "A temporary scroll source is missing. Start a new capture."
        case .changedSource: return "Previously captured content changed. Return to a stable page and capture again; the original image has been kept."
        }
    }
}

private final class BoundedScrollPNGWriter {
    let handle: FileHandle
    let limit: Int64
    var written: Int64 = 0
    var failure: Error?
    init(url: URL, limit: Int64) throws { handle = try FileHandle(forWritingTo: url); self.limit = limit }
    func put(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        guard failure == nil else { return 0 }
        if Task.isCancelled { failure = CancellationError(); return 0 }
        guard count >= 0, Int64(count) <= limit - written else { failure = ScrollSequenceImageError.storageLimit; return 0 }
        do {
            // The encoder owns this buffer for this synchronous callback. Do not copy a
            // potentially large compressed chunk merely to send it to the file descriptor.
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer), count: count, deallocator: .none)
            try handle.write(contentsOf: data)
            written += Int64(count)
            return count
        } catch { failure = error; return 0 }
    }
}

extension ScrollImageIO {
    /// The encoder cannot write even one byte beyond remaining session storage. Failed or
    /// canceled encodes remove their partial file; source PNGs are never overwritten.
    static func writeBoundedPNG(_ image: CGImage, to url: URL, maximumBytes: Int64) throws {
        guard maximumBytes > 0 else { throw ScrollSequenceImageError.storageLimit }
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ScrollSequenceImageError.writeFailed
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: url) } }
        let writer = try BoundedScrollPNGWriter(url: url, limit: maximumBytes)
        defer { try? writer.handle.close() }
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            return Unmanaged<BoundedScrollPNGWriter>.fromOpaque(info).takeUnretainedValue().put(bytes, count: count)
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(writer).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil) else {
            throw ScrollSequenceImageError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        let finalized = CGImageDestinationFinalize(destination)
        if let failure = writer.failure { throw failure }
        guard finalized, writer.written > 0 else { throw ScrollSequenceImageError.writeFailed }
        try Task.checkCancellation()
        try writer.handle.synchronize()
        completed = true
    }

    /// Verify the overlap against immutable contributed strips, not just the last viewport.
    /// Decode one source at a time; a revisit never retains or writes another full image.
    static func validateSequenceOverlap(_ candidate: ScrollFrame, image candidateImage: CGImage, sequence: ScrollCaptureSequence,
                                        viewportOffset: Int, sources: [StoredScrollSource]) throws {
        let start = viewportOffset
        let end = start + (sequence.axis == .vertical ? candidate.height : candidate.width)
        for block in sequence.blocks {
            let lower = max(start, block.documentStart), upper = min(end, block.documentStart + block.length)
            guard upper > lower else { continue }
            try Task.checkCancellation()
            guard let stored = sources.first(where: { $0.id == block.sourceID }) else { throw ScrollSequenceImageError.missingSource }
            try autoreleasepool {
                let image = try readImage(at: stored.url)
                guard image.width == stored.width, image.height == stored.height else { throw ScrollSequenceImageError.missingSource }
                let original = try luminance(image)
                do {
                    _ = try ScrollStitcher.validateAlignedOverlap(previous: original,
                        previousStart: block.sourceStart + lower - block.documentStart,
                        next: candidate, nextStart: lower - start, length: upper - lower, axis: sequence.axis)
                    try verifyColorOverlap(original: image, originalStart: block.sourceStart + lower - block.documentStart,
                                           candidate: candidateImage, candidateStart: lower - start,
                                           length: upper - lower, axis: sequence.axis)
                } catch is CancellationError { throw CancellationError() }
                catch { throw ScrollSequenceImageError.changedSource }
            }
        }
    }

    /// Luminance establishes motion; bounded RGBA tiles also protect equal-luminance
    /// color/alpha changes in retained content. At most two 128×128 comparison buffers
    /// are alive, rather than extra full-size RGBA copies of both frames.
    private static func verifyColorOverlap(original: CGImage, originalStart: Int,
                                           candidate: CGImage, candidateStart: Int,
                                           length: Int, axis: ScrollAxis) throws {
        let cross = axis == .vertical ? original.width : original.height
        var channelErrors = [UInt64](repeating: 0, count: 4), totalPixels: UInt64 = 0
        var bandErrors = [UInt64](repeating: 0, count: 64 * 4)
        var bandCounts = [UInt64](repeating: 0, count: 64)
        for along in stride(from: 0, to: length, by: 128) {
            for across in stride(from: 0, to: cross, by: 128) {
                try Task.checkCancellation()
                let amount = min(128, length - along), span = min(128, cross - across)
                let aRect = axis == .vertical
                    ? CGRect(x: across, y: originalStart + along, width: span, height: amount)
                    : CGRect(x: originalStart + along, y: across, width: amount, height: span)
                let bRect = axis == .vertical
                    ? CGRect(x: across, y: candidateStart + along, width: span, height: amount)
                    : CGRect(x: candidateStart + along, y: across, width: amount, height: span)
                let a = try colorTile(original, rectangle: aRect), b = try colorTile(candidate, rectangle: bRect)
                guard a.count == b.count else { throw ScrollSequenceImageError.changedSource }
                let tileWidth = axis == .vertical ? span : amount
                for pixel in 0..<(a.count / 4) {
                    let x = pixel % tileWidth, y = pixel / tileWidth
                    let pixelAlong = along + (axis == .vertical ? y : x)
                    let pixelAcross = across + (axis == .vertical ? x : y)
                    let band = min(7, pixelAlong * 8 / length) * 8 + min(7, pixelAcross * 8 / cross)
                    for channel in 0..<4 {
                        let index = pixel * 4 + channel
                        let difference = abs(Int(a[index]) - Int(b[index]))
                        guard difference <= 24 else { throw ScrollSequenceImageError.changedSource }
                        channelErrors[channel] += UInt64(difference)
                        bandErrors[band * 4 + channel] += UInt64(difference)
                    }
                    bandCounts[band] += 1
                }
                totalPixels += UInt64(a.count / 4)
            }
        }
        guard totalPixels > 0, channelErrors.allSatisfy({ Double($0) / Double(totalPixels) <= 7 }) else {
            throw ScrollSequenceImageError.changedSource
        }
        for band in 0..<64 where bandCounts[band] > 0 {
            for channel in 0..<4 {
                guard Double(bandErrors[band * 4 + channel]) / Double(bandCounts[band]) <= 14 else {
                    throw ScrollSequenceImageError.changedSource
                }
            }
        }
    }

    private static func colorTile(_ image: CGImage, rectangle: CGRect) throws -> [UInt8] {
        let width = Int(rectangle.width), height = Int(rectangle.height)
        guard width > 0, width <= 128, height > 0, height <= 128,
              let crop = image.cropping(to: rectangle) else { throw ScrollSequenceError.invalidGeometry }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ScrollSequenceError.invalidGeometry
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    static func sequenceThumbnail(_ sources: [StoredScrollSource], layout: ScrollSequenceLayout,
                                  axis: ScrollAxis) throws -> CGImage {
        try drawSequence(sources, layout: layout, axis: axis, thumbnail: true)
    }

    static func renderSequence(_ sources: [StoredScrollSource], layout: ScrollSequenceLayout,
                               axis: ScrollAxis) throws -> CGImage {
        try drawSequence(sources, layout: layout, axis: axis, thumbnail: false)
    }

    private static func drawSequence(_ sources: [StoredScrollSource], layout: ScrollSequenceLayout,
                                     axis: ScrollAxis, thumbnail: Bool) throws -> CGImage {
        try ScrollCaptureSequence.validateRaster(width: layout.width, height: layout.height)
        guard !layout.strips.isEmpty, layout.strips.count <= ScrollCaptureSequence.maximumRenderedStrips,
              sources.count <= ScrollCaptureSequence.maximumBlocks else { throw ScrollSequenceError.invalidGeometry }
        let scale = thumbnail ? min(1, 800 / Double(max(layout.width, layout.height))) : 1
        let width = max(1, Int(ceil(Double(layout.width) * scale)))
        let height = max(1, Int(ceil(Double(layout.height) * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollStitchError.pixelLimit }
        context.interpolationQuality = thumbnail ? .high : .none
        var expectedOffset = 0
        var decodedSourceID: UUID?
        var decodedSource: CGImage? // One source only; split strips reuse its decode.
        for strip in layout.strips {
            try Task.checkCancellation()
            let block = strip.block
            guard strip.outputStart == expectedOffset, block.length > 0, block.sourceStart >= 0,
                  let source = sources.first(where: { $0.id == block.sourceID }),
                  source.width > 0, source.height > 0,
                  source.width <= ScrollFrame.maximumDimension, source.height <= ScrollFrame.maximumDimension,
                  source.width <= ScrollFrame.maximumPixels / source.height else { throw ScrollSequenceError.invalidGeometry }
            let sourceLength = axis == .vertical ? source.height : source.width
            guard block.sourceStart <= sourceLength, block.length <= sourceLength - block.sourceStart,
                  (axis == .vertical ? source.width == layout.width : source.height == layout.height),
                  block.length <= (axis == .vertical ? layout.height : layout.width) - expectedOffset else {
                throw ScrollSequenceError.invalidGeometry
            }
            expectedOffset += block.length
            try autoreleasepool {
                if decodedSourceID != source.id {
                    decodedSource = nil // Release the previous full decode before loading another.
                    decodedSourceID = nil
                    if thumbnail {
                        guard let input = CGImageSourceCreateWithURL(source.url as CFURL, nil),
                              let decoded = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceThumbnailMaxPixelSize: 800,
                                kCGImageSourceCreateThumbnailWithTransform: false
                              ] as CFDictionary) else { throw ScrollSequenceImageError.missingSource }
                        decodedSource = decoded
                    } else {
                        let image = try readImage(at: source.url)
                        guard image.width == source.width, image.height == source.height else { throw ScrollSequenceImageError.missingSource }
                        decodedSource = image
                    }
                    decodedSourceID = source.id
                }
                guard let image = decodedSource else { throw ScrollSequenceImageError.missingSource }
                // The exact same source crop and compacted destination drive preview and export.
                // Clipping avoids holding a second giant crop image alongside the source decode.
                let origin = strip.outputStart - block.sourceStart
                let destination: CGRect
                let clip: CGRect
                if axis == .vertical {
                    destination = CGRect(x: 0, y: Double(layout.height - origin - source.height) * scale,
                                         width: Double(source.width) * scale, height: Double(source.height) * scale)
                    clip = CGRect(x: 0, y: Double(layout.height - strip.outputStart - block.length) * scale,
                                  width: Double(layout.width) * scale, height: Double(block.length) * scale)
                } else {
                    destination = CGRect(x: Double(origin) * scale, y: 0,
                                         width: Double(source.width) * scale, height: Double(source.height) * scale)
                    clip = CGRect(x: Double(strip.outputStart) * scale, y: 0,
                                  width: Double(block.length) * scale, height: Double(layout.height) * scale)
                }
                context.saveGState(); context.clip(to: clip)
                context.draw(image, in: destination)
                context.restoreGState()
            }
        }
        guard expectedOffset == (axis == .vertical ? layout.height : layout.width),
              let image = context.makeImage() else { throw ScrollSequenceError.invalidGeometry }
        return image
    }
}
