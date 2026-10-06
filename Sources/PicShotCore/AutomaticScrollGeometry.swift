import Foundation

/// Screen-independent coordinate policy. Region and display bounds are logical points;
/// screenshots may have independent X/Y pixel scales on each selected display.
public enum AutomaticScrollGeometry {
    public static func targetPoint(region: CGRect, displayBounds: CGRect) throws -> CGPoint {
        try validate(region: region, logicalSize: displayBounds.size)
        guard displayBounds.origin.x.isFinite, displayBounds.origin.y.isFinite else {
            throw ScrollStitchError.invalidPixels
        }
        return CGPoint(x: displayBounds.minX + region.midX, y: displayBounds.minY + region.midY)
    }

    public static func pixelRect(region: CGRect, logicalSize: CGSize, pixelWidth: Int, pixelHeight: Int) throws -> CGRect {
        try validate(region: region, logicalSize: logicalSize)
        guard pixelWidth > 0, pixelHeight > 0 else { throw ScrollStitchError.invalidPixels }
        let xScale = CGFloat(pixelWidth) / logicalSize.width
        let yScale = CGFloat(pixelHeight) / logicalSize.height
        let result = CGRect(x: region.minX * xScale, y: region.minY * yScale,
                            width: region.width * xScale, height: region.height * yScale).integral
        let pixelBounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        // Integral rounding can expand a fractional region by one pixel, but never crop
        // another display or return an empty rectangle at the selected display's edge.
        let clipped = result.intersection(pixelBounds)
        guard !clipped.isNull, !clipped.isEmpty else { throw ScrollStitchError.invalidPixels }
        return clipped
    }

    private static func validate(region: CGRect, logicalSize: CGSize) throws {
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0,
              region.origin.x.isFinite, region.origin.y.isFinite,
              region.size.width.isFinite, region.size.height.isFinite, region.size.width > 0, region.size.height > 0,
              CGRect(origin: .zero, size: logicalSize).contains(region) else {
            throw ScrollStitchError.invalidPixels
        }
    }
}
