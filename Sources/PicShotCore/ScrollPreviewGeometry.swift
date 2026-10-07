import Foundation

/// Preview coordinates are output pixels after edits. Document coordinates only enter
/// through `project`; a removed band never reappears in hit testing or viewport overlays.
public enum ScrollPreviewGeometry {
    public static func project(_ documentRange: Range<Int>, into layout: ScrollSequenceLayout) -> [Range<Int>] {
        layout.strips.compactMap { strip in
            let start = max(documentRange.lowerBound, strip.block.documentStart)
            let end = min(documentRange.upperBound, strip.block.documentStart + strip.block.length)
            guard end > start else { return nil }
            let outputStart = strip.outputStart + start - strip.block.documentStart
            return outputStart..<(outputStart + end - start)
        }
    }

    public static func fitScale(output: CGSize, viewport: CGRect) -> CGFloat {
        guard output.width > 0, output.height > 0, viewport.width > 0, viewport.height > 0 else { return 0 }
        return min(viewport.width / output.width, viewport.height / output.height)
    }

    public static func imageRect(output: CGSize, viewport: CGRect, scale: CGFloat, center: CGPoint) -> CGRect {
        guard scale.isFinite, scale > 0 else { return .zero }
        let center = clampedCenter(center, output: output, viewport: viewport, scale: scale)
        return CGRect(x: viewport.midX - center.x * scale, y: viewport.midY - center.y * scale,
                      width: output.width * scale, height: output.height * scale)
    }

    public static func clampedCenter(_ center: CGPoint, output: CGSize, viewport: CGRect, scale: CGFloat) -> CGPoint {
        guard scale.isFinite, scale > 0 else { return CGPoint(x: output.width / 2, y: output.height / 2) }
        func clamp(_ value: CGFloat, length: CGFloat, visible: CGFloat) -> CGFloat {
            guard value.isFinite, length > visible else { return length / 2 }
            return min(length - visible / 2, max(visible / 2, value))
        }
        return CGPoint(x: clamp(center.x, length: output.width, visible: viewport.width / scale),
                       y: clamp(center.y, length: output.height, visible: viewport.height / scale))
    }

    public static func visibleOutput(imageRect: CGRect, viewport: CGRect, output: CGSize) -> CGRect {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        let intersection = imageRect.intersection(viewport)
        guard !intersection.isNull, !intersection.isEmpty else { return .zero }
        return CGRect(x: (intersection.minX - imageRect.minX) * output.width / imageRect.width,
                      y: (intersection.minY - imageRect.minY) * output.height / imageRect.height,
                      width: intersection.width * output.width / imageRect.width,
                      height: intersection.height * output.height / imageRect.height)
    }

    public static func pixel(at point: CGPoint, imageRect: CGRect, length: Int, axis: ScrollAxis) -> Int? {
        guard length > 0, imageRect.width > 0, imageRect.height > 0,
              point.x.isFinite, point.y.isFinite else { return nil }
        let fraction = axis == .vertical ? (point.y - imageRect.minY) / imageRect.height
                                         : (point.x - imageRect.minX) / imageRect.width
        return Int(min(CGFloat(length - 1), max(0, floor(fraction * CGFloat(length)))))
    }

    /// Integer destination pixels whose centers lie in the half-open output band.
    /// Shared edges get the same integer boundary on both sides, including exact ties.
    /// This avoids CoreGraphics independently rounding adjacent fractional clip edges.
    public static func sampledPixelRange(_ range: Range<Int>, requestStart: Int,
                                         requestLength: Int, pixelLength: Int) -> Range<Int> {
        guard requestLength > 0, requestLength <= ScrollCaptureSequence.maximumOutputDimension,
              pixelLength > 0, pixelLength <= ScrollPreviewTileRequest.maximumTileDimension,
              requestStart >= 0, requestStart <= ScrollCaptureSequence.maximumOutputDimension - requestLength else { return 0..<0 }
        func boundary(_ coordinate: Int) -> Int {
            let clipped = min(requestStart + requestLength, max(requestStart, coordinate))
            let delta = clipped - requestStart
            // ceil(delta * pixelLength / requestLength - 0.5), evaluated as exact
            // bounded integer arithmetic: products <= 67,108,864; numerator <= 67,141,631.
            return (2 * delta * pixelLength + requestLength - 1) / (2 * requestLength)
        }
        return boundary(range.lowerBound)..<boundary(range.upperBound)
    }

    public static func bandRect(_ range: Range<Int>, imageRect: CGRect, length: Int, axis: ScrollAxis) -> CGRect {
        guard length > 0 else { return .zero }
        let scale = (axis == .vertical ? imageRect.height : imageRect.width) / CGFloat(length)
        return axis == .vertical
            ? CGRect(x: imageRect.minX, y: imageRect.minY + CGFloat(range.lowerBound) * scale,
                     width: imageRect.width, height: CGFloat(range.count) * scale)
            : CGRect(x: imageRect.minX + CGFloat(range.lowerBound) * scale, y: imageRect.minY,
                     width: CGFloat(range.count) * scale, height: imageRect.height)
    }
}

/// One visible-region raster, never the entire stitched output. Values are source pixels,
/// not points. Sampling is intentionally explicit: detail remains a sampled preview.
public struct ScrollPreviewTileRequest: Sendable, Equatable {
    public static let maximumTileDimension = 1_024
    public static let maximumTilePixels = 1_048_576
    public static let maximumSourceSampleDimension = 2_048
    public static let maximumSourceSamplePixels = 4_194_304
    public static let maximumCachedTiles = 1
    public static let maximumConcurrentJobs = 1
    public let outputRect: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(outputSize: CGSize, visibleRect: CGRect, displayScale: CGFloat) throws {
        guard outputSize.width.isFinite, outputSize.height.isFinite,
              outputSize.width > 0, outputSize.height > 0,
              outputSize.width.rounded() == outputSize.width, outputSize.height.rounded() == outputSize.height,
              outputSize.width <= CGFloat(ScrollCaptureSequence.maximumOutputDimension),
              outputSize.height <= CGFloat(ScrollCaptureSequence.maximumOutputDimension),
              visibleRect.origin.x.isFinite, visibleRect.origin.y.isFinite,
              visibleRect.width.isFinite, visibleRect.height.isFinite,
              visibleRect.width > 0, visibleRect.height > 0,
              displayScale.isFinite, displayScale > 0 else { throw ScrollSequenceError.invalidGeometry }
        try ScrollCaptureSequence.validateRaster(width: Int(ceil(outputSize.width)), height: Int(ceil(outputSize.height)))
        let clipped = visibleRect.intersection(CGRect(origin: .zero, size: outputSize))
        guard !clipped.isNull, !clipped.isEmpty else { throw ScrollSequenceError.invalidGeometry }
        // Integral source boundaries make neighboring fractional gestures stable. The
        // drawing transform keeps this padded tile aligned to exact output coordinates.
        let region = clipped.integral.intersection(CGRect(origin: .zero, size: outputSize))
        let sampleScale = min(1, min(displayScale, CGFloat(Self.maximumTileDimension) / max(region.width, region.height)))
        self.outputRect = region
        self.pixelWidth = max(1, Int(ceil(region.width * sampleScale)))
        self.pixelHeight = max(1, Int(ceil(region.height * sampleScale)))
    }
}
