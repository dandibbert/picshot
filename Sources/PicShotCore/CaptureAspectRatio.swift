#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

public enum CaptureAspectRatioError: Error, LocalizedError, Equatable {
    case invalidRatio

    public var errorDescription: String? {
        "请输入 1 至 10000 的整数比例。"
    }
}

/// A source-pixel width:height ratio. Reducing it makes every permitted size an
/// integer multiple of the smallest pair, without approximating the ratio.
public struct CaptureAspectRatio: Equatable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int, denominator: Int) throws {
        guard (1...10_000).contains(numerator), (1...10_000).contains(denominator) else {
            throw CaptureAspectRatioError.invalidRatio
        }
        var a = numerator, b = denominator
        while b != 0 { (a, b) = (b, a % b) }
        self.numerator = numerator / a
        self.denominator = denominator / a
    }

    private init(reducedNumerator: Int, reducedDenominator: Int) {
        numerator = reducedNumerator
        denominator = reducedDenominator
    }

    public var swapped: CaptureAspectRatio {
        CaptureAspectRatio(reducedNumerator: denominator, reducedDenominator: numerator)
    }

    public var label: String { "\(numerator):\(denominator)" }

    public static let presets: [CaptureAspectRatio] = [
        CaptureAspectRatio(reducedNumerator: 1, reducedDenominator: 1),
        CaptureAspectRatio(reducedNumerator: 4, reducedDenominator: 3),
        CaptureAspectRatio(reducedNumerator: 3, reducedDenominator: 2),
        CaptureAspectRatio(reducedNumerator: 16, reducedDenominator: 9),
        CaptureAspectRatio(reducedNumerator: 9, reducedDenominator: 16)
    ]
}

public enum CaptureRatioAxis: Equatable, Sendable { case width, height }

/// Names refer to numerical coordinates, independent of whether a view is flipped.
public enum CaptureRatioHandle: CaseIterable, Equatable, Sendable {
    case minXMinY, minY, maxXMinY, maxX, maxXMaxY, maxY, minXMaxY, minX
}

/// Scalar-only selection geometry. Sizes and anchors are calculated in source
/// pixels, then converted back to points using independent horizontal/vertical
/// densities. This type never reads or allocates an image, mask or pixel array.
public struct CaptureRatioGeometry: Sendable {
    public let pointSize: CGSize
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pointSize: CGSize, pixelWidth: Int, pixelHeight: Int) throws {
        guard pointSize.width.isFinite, pointSize.height.isFinite,
              pointSize.width >= 1, pointSize.height >= 1,
              pointSize.width <= CGFloat(CaptureSelectionGeometry.maximumDimension),
              pointSize.height <= CGFloat(CaptureSelectionGeometry.maximumDimension),
              CaptureSelectionGeometry.allowsSourceSize(width: pixelWidth, height: pixelHeight) else {
            throw CaptureSelectionError.invalidCanvas
        }
        self.pointSize = pointSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var pixelsPerPointX: CGFloat { CGFloat(pixelWidth) / pointSize.width }
    public var pixelsPerPointY: CGFloat { CGFloat(pixelHeight) / pointSize.height }

    /// Rounds edges to their nearest source pixels after clipping to the canvas.
    /// In particular, a floating-point round trip cannot add an enclosing pixel.
    /// This is also useful when enabling the lock on a previously free rectangle.
    public func sourcePixelRect(_ points: CGRect) throws -> CGRect {
        try validate(points)
        let rectangle = points.standardized
        let x0 = (max(0, min(CGFloat(pixelWidth), rectangle.minX * pixelsPerPointX))).rounded()
        let x1 = (max(0, min(CGFloat(pixelWidth), rectangle.maxX * pixelsPerPointX))).rounded()
        let y0 = (max(0, min(CGFloat(pixelHeight), rectangle.minY * pixelsPerPointY))).rounded()
        let y1 = (max(0, min(CGFloat(pixelHeight), rectangle.maxY * pixelsPerPointY))).rounded()
        guard x1 > x0, y1 > y0 else { throw CaptureSelectionError.invalidShape }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Converts source pixel bounds to points. Invalid or excessively large input
    /// returns null; valid geometry never requires an unsafe integer conversion.
    public func pointRect(_ pixels: CGRect) -> CGRect {
        guard (try? validate(pixels)) != nil else { return .null }
        let rectangle = pixels.standardized
        return CGRect(x: rectangle.minX / pixelsPerPointX, y: rectangle.minY / pixelsPerPointY,
                      width: rectangle.width / pixelsPerPointX, height: rectangle.height / pixelsPerPointY)
    }

    /// The snapped start stays fixed. The larger normalized drag extent drives
    /// the size; the ratio multiple is rounded and constrained to available space.
    public func drag(from start: CGPoint, to end: CGPoint, ratio: CaptureAspectRatio) throws -> CGRect {
        let anchor = try sourcePixelPoint(start)
        let pointer = try sourcePixelPoint(end)
        // Use the unsnapped direction so a subpixel gesture keeps its quadrant.
        let directionX = end.x < start.x ? -1 : 1
        let directionY = end.y < start.y ? -1 : 1
        return try corner(anchor: anchor, pointer: pointer, directionX: directionX,
                          directionY: directionY, ratio: ratio)
    }

    /// Corners retain their opposite corner, and cannot flip through it. Side
    /// handles retain their opposite edge and the perpendicular center, allowing
    /// at most half a pixel of center rounding plus a shift needed to stay on-screen.
    public func resize(_ original: CGRect, handle: CaptureRatioHandle, to point: CGPoint,
                       ratio: CaptureAspectRatio) throws -> CGRect {
        let rectangle = try sourcePixelRect(original)
        let pointer = try sourcePixelPoint(point)
        switch handle {
        case .minXMinY:
            return try corner(anchor: CGPoint(x: rectangle.maxX, y: rectangle.maxY), pointer: pointer,
                              directionX: -1, directionY: -1, ratio: ratio)
        case .maxXMinY:
            return try corner(anchor: CGPoint(x: rectangle.minX, y: rectangle.maxY), pointer: pointer,
                              directionX: 1, directionY: -1, ratio: ratio)
        case .maxXMaxY:
            return try corner(anchor: CGPoint(x: rectangle.minX, y: rectangle.minY), pointer: pointer,
                              directionX: 1, directionY: 1, ratio: ratio)
        case .minXMaxY:
            return try corner(anchor: CGPoint(x: rectangle.maxX, y: rectangle.minY), pointer: pointer,
                              directionX: -1, directionY: 1, ratio: ratio)
        case .minX, .maxX:
            let growsPositive = handle == .maxX
            let anchor = growsPositive ? rectangle.minX : rectangle.maxX
            let available = growsPositive ? pixelWidth - Int(anchor) : Int(anchor)
            let requested = max(0, growsPositive ? pointer.x - anchor : anchor - pointer.x)
            let multiple = try boundedMultiple(requested / CGFloat(ratio.numerator), ratio: ratio,
                                               availableWidth: available, availableHeight: pixelHeight)
            let width = ratio.numerator * multiple, height = ratio.denominator * multiple
            let x = growsPositive ? Int(anchor) : Int(anchor) - width
            let y = centeredOrigin(rectangle.midY, length: height, limit: pixelHeight)
            return try result(x: x, y: y, width: width, height: height)
        case .minY, .maxY:
            let growsPositive = handle == .maxY
            let anchor = growsPositive ? rectangle.minY : rectangle.maxY
            let available = growsPositive ? pixelHeight - Int(anchor) : Int(anchor)
            let requested = max(0, growsPositive ? pointer.y - anchor : anchor - pointer.y)
            let multiple = try boundedMultiple(requested / CGFloat(ratio.denominator), ratio: ratio,
                                               availableWidth: pixelWidth, availableHeight: available)
            let width = ratio.numerator * multiple, height = ratio.denominator * multiple
            let x = centeredOrigin(rectangle.midX, length: width, limit: pixelWidth)
            let y = growsPositive ? Int(anchor) : Int(anchor) - height
            return try result(x: x, y: y, width: width, height: height)
        }
    }

    /// Numeric edits round to the nearest exact ratio multiple. An impossible
    /// request is rejected; only the origin may move to accommodate the new size.
    public func sized(_ original: CGRect, pixels: Int, axis: CaptureRatioAxis,
                      ratio: CaptureAspectRatio) throws -> CGRect {
        let rectangle = try sourcePixelRect(original)
        let unit = axis == .width ? ratio.numerator : ratio.denominator
        let limit = axis == .width ? pixelWidth : pixelHeight
        let density = axis == .width ? pixelsPerPointX : pixelsPerPointY
        // Validate before converting or performing integer multiplication, even
        // when a caller passes Int.min / Int.max from a numeric input field.
        guard pixels > 0, pixels <= limit, CGFloat(pixels) >= 2 * density else {
            throw CaptureSelectionError.invalidShape
        }
        let multiple = Int((CGFloat(pixels) / CGFloat(unit)).rounded())
        guard multiple >= minimumMultiple(ratio),
              multiple <= min(pixelWidth / ratio.numerator, pixelHeight / ratio.denominator) else {
            throw CaptureSelectionError.invalidShape
        }
        return try positioned(rectangle, multiple: multiple, ratio: ratio)
    }

    /// Enabling or changing a lock chooses the closest width-based ratio multiple
    /// that fits the canvas/output limits, retaining the origin wherever possible.
    public func fitting(_ original: CGRect, ratio: CaptureAspectRatio) throws -> CGRect {
        let rectangle = try sourcePixelRect(original)
        let multiple = try boundedMultiple(rectangle.width / CGFloat(ratio.numerator), ratio: ratio,
                                           availableWidth: pixelWidth, availableHeight: pixelHeight)
        return try positioned(rectangle, multiple: multiple, ratio: ratio)
    }

    private func sourcePixelPoint(_ point: CGPoint) throws -> CGPoint {
        guard valid(point.x), valid(point.y) else { throw CaptureSelectionError.invalidShape }
        return CGPoint(x: max(0, min(CGFloat(pixelWidth), point.x * pixelsPerPointX)).rounded(),
                       y: max(0, min(CGFloat(pixelHeight), point.y * pixelsPerPointY)).rounded())
    }

    private func corner(anchor: CGPoint, pointer: CGPoint, directionX: Int, directionY: Int,
                        ratio: CaptureAspectRatio) throws -> CGRect {
        let dx = max(0, (pointer.x - anchor.x) * CGFloat(directionX))
        let dy = max(0, (pointer.y - anchor.y) * CGFloat(directionY))
        let widthAvailable = directionX > 0 ? pixelWidth - Int(anchor.x) : Int(anchor.x)
        let heightAvailable = directionY > 0 ? pixelHeight - Int(anchor.y) : Int(anchor.y)
        let requested = max(dx / CGFloat(ratio.numerator), dy / CGFloat(ratio.denominator))
        let multiple = try boundedMultiple(requested, ratio: ratio,
                                           availableWidth: widthAvailable, availableHeight: heightAvailable)
        let width = ratio.numerator * multiple, height = ratio.denominator * multiple
        let x = Int(anchor.x) - (directionX < 0 ? width : 0)
        let y = Int(anchor.y) - (directionY < 0 ? height : 0)
        return try result(x: x, y: y, width: width, height: height)
    }

    private func minimumMultiple(_ ratio: CaptureAspectRatio) -> Int {
        max(1, max(Int(ceil(2 * pixelsPerPointX / CGFloat(ratio.numerator))),
                   Int(ceil(2 * pixelsPerPointY / CGFloat(ratio.denominator)))))
    }

    private func maximumMultiple(_ ratio: CaptureAspectRatio, width: Int, height: Int) -> Int {
        // Logarithmic in the bounded dimension, with no raster-sized storage.
        // Division-based preflight avoids computing a possibly overflowing area.
        var low = 0, high = min(width / ratio.numerator, height / ratio.denominator)
        while low < high {
            let candidate = low + (high - low + 1) / 2
            if CaptureSelectionGeometry.allowsOutputSize(width: ratio.numerator * candidate,
                                                        height: ratio.denominator * candidate) {
                low = candidate
            } else {
                high = candidate - 1
            }
        }
        return low
    }

    private func boundedMultiple(_ requested: CGFloat, ratio: CaptureAspectRatio,
                                 availableWidth: Int, availableHeight: Int) throws -> Int {
        let minimum = minimumMultiple(ratio)
        let maximum = maximumMultiple(ratio, width: availableWidth, height: availableHeight)
        guard maximum >= minimum else { throw CaptureSelectionError.invalidShape }
        // Clamp before integer conversion; only already validated source-pixel
        // extents reach this helper, and the final integer is at most 32,768.
        return Int(max(CGFloat(minimum), min(CGFloat(maximum), requested.rounded())))
    }

    private func positioned(_ original: CGRect, multiple: Int, ratio: CaptureAspectRatio) throws -> CGRect {
        let width = ratio.numerator * multiple, height = ratio.denominator * multiple
        return try result(x: max(0, min(Int(original.minX), pixelWidth - width)),
                          y: max(0, min(Int(original.minY), pixelHeight - height)), width: width, height: height)
    }

    private func centeredOrigin(_ center: CGFloat, length: Int, limit: Int) -> Int {
        Int(max(0, min(CGFloat(limit - length), (center - CGFloat(length) / 2).rounded())))
    }

    private func result(x: Int, y: Int, width: Int, height: Int) throws -> CGRect {
        guard x >= 0, y >= 0, width <= pixelWidth - x, height <= pixelHeight - y,
              CGFloat(width) >= 2 * pixelsPerPointX, CGFloat(height) >= 2 * pixelsPerPointY else {
            throw CaptureSelectionError.invalidShape
        }
        guard CaptureSelectionGeometry.allowsOutputSize(width: width, height: height) else {
            throw CaptureSelectionError.pixelLimit
        }
        return pointRect(CGRect(x: x, y: y, width: width, height: height))
    }

    private func valid(_ value: CGFloat) -> Bool { value.isFinite && abs(value) <= 1_000_000_000 }

    private func validate(_ rectangle: CGRect) throws {
        guard valid(rectangle.origin.x), valid(rectangle.origin.y),
              valid(rectangle.width), valid(rectangle.height),
              valid(rectangle.origin.x + rectangle.width), valid(rectangle.origin.y + rectangle.height) else {
            throw CaptureSelectionError.invalidShape
        }
    }
}
