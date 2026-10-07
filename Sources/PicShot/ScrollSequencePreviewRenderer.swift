import AppKit
import ImageIO
import PicShotCore

/// Preview-only renderer. It does not call renderSequence/readImage, change the edit
/// projection, or write files. ImageIO may use decoder scratch space internally; the
/// source admission bound is 24 MP, and only one source is decoded at a time.
extension ScrollImageIO {
    static func sequencePreviewTile(_ sources: [StoredScrollSource], layout: ScrollSequenceLayout,
                                    axis: ScrollAxis, request: ScrollPreviewTileRequest) throws -> CGImage {
        try Task.checkCancellation()
        try ScrollCaptureSequence.validateRaster(width: layout.width, height: layout.height)
        let outputBounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        guard !layout.strips.isEmpty, layout.strips.count <= ScrollCaptureSequence.maximumRenderedStrips,
              !sources.isEmpty, sources.count <= ScrollCaptureSequence.maximumBlocks,
              Set(sources.map(\.id)).count == sources.count,
              outputBounds.contains(request.outputRect),
              request.pixelWidth > 0, request.pixelHeight > 0,
              request.pixelWidth <= ScrollPreviewTileRequest.maximumTileDimension,
              request.pixelHeight <= ScrollPreviewTileRequest.maximumTileDimension,
              request.pixelWidth <= ScrollPreviewTileRequest.maximumTilePixels / request.pixelHeight else {
            throw ScrollSequenceError.invalidGeometry
        }
        let length = axis == .vertical ? layout.height : layout.width
        var expectedOffset = 0
        // Validate every strip, even those outside the requested region, before allocation.
        for strip in layout.strips {
            guard strip.outputStart == expectedOffset, strip.block.length > 0,
                  strip.block.length <= length - expectedOffset,
                  strip.block.sourceStart >= 0,
                  let source = sources.first(where: { $0.id == strip.block.sourceID }),
                  source.width > 0, source.height > 0,
                  source.width <= ScrollFrame.maximumDimension, source.height <= ScrollFrame.maximumDimension,
                  source.width <= ScrollFrame.maximumPixels / source.height else { throw ScrollSequenceError.invalidGeometry }
            let sourceLength = axis == .vertical ? source.height : source.width
            guard strip.block.sourceStart <= sourceLength,
                  strip.block.length <= sourceLength - strip.block.sourceStart,
                  (axis == .vertical ? source.width == layout.width : source.height == layout.height) else {
                throw ScrollSequenceError.invalidGeometry
            }
            expectedOffset += strip.block.length
        }
        guard expectedOffset == length,
              let context = CGContext(data: nil, width: request.pixelWidth, height: request.pixelHeight,
                bitsPerComponent: 8, bytesPerRow: request.pixelWidth * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ScrollSequenceError.invalidGeometry
        }
        // Sample at stable pixel centers. A tile is labeled sampled even if a small
        // source happens to fit the source-sample bound and is sampled at native size.
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setBlendMode(.copy)
        let scaleX = CGFloat(request.pixelWidth) / request.outputRect.width
        let scaleY = CGFloat(request.pixelHeight) / request.outputRect.height
        func destination(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - request.outputRect.minX) * scaleX,
                   y: (request.outputRect.maxY - rect.maxY) * scaleY,
                   width: rect.width * scaleX, height: rect.height * scaleY)
        }
        var sampledSourceID: UUID?
        var sampledSource: CGImage?
        for strip in layout.strips {
            try Task.checkCancellation()
            let stripRect = axis == .vertical
                ? CGRect(x: 0, y: strip.outputStart, width: layout.width, height: strip.block.length)
                : CGRect(x: strip.outputStart, y: 0, width: strip.block.length, height: layout.height)
            let clipped = stripRect.intersection(request.outputRect)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            guard let source = sources.first(where: { $0.id == strip.block.sourceID }) else {
                throw ScrollSequenceImageError.missingSource
            }
            try autoreleasepool {
                if sampledSourceID != source.id {
                    sampledSource = nil; sampledSourceID = nil
                    guard let input = CGImageSourceCreateWithURL(source.url as CFURL,
                            [kCGImageSourceShouldCache: false] as CFDictionary),
                          let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
                          (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == source.width,
                          (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == source.height,
                          let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: ScrollPreviewTileRequest.maximumSourceSampleDimension,
                            kCGImageSourceCreateThumbnailWithTransform: false,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary),
                          image.width <= ScrollPreviewTileRequest.maximumSourceSampleDimension,
                          image.height <= ScrollPreviewTileRequest.maximumSourceSampleDimension,
                          image.width <= ScrollPreviewTileRequest.maximumSourceSamplePixels / max(1, image.height) else {
                        throw ScrollSequenceImageError.missingSource
                    }
                    try Task.checkCancellation()
                    sampledSource = image; sampledSourceID = source.id
                }
                guard let image = sampledSource else { throw ScrollSequenceImageError.missingSource }
                let origin = strip.outputStart - strip.block.sourceStart
                let sourceRect = axis == .vertical
                    ? CGRect(x: 0, y: origin, width: source.width, height: source.height)
                    : CGRect(x: origin, y: 0, width: source.width, height: source.height)
                context.saveGState()
                context.clip(to: destination(clipped))
                context.draw(image, in: destination(sourceRect))
                context.restoreGState()
            }
        }
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw ScrollSequenceError.invalidGeometry }
        return result
    }
}
