#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

public enum CaptureSelectionError: Error, LocalizedError, Equatable {
    case invalidCanvas, invalidShape, emptySelection, pixelLimit, complexityLimit, cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidCanvas: return "The display dimensions changed or are unsupported. Start a new capture."
        case .invalidShape: return "Draw a selection at least 2 × 2 points."
        case .emptySelection: return "The selection is empty or too small. Select at least 4 square points."
        case .pixelLimit: return "The selected image would exceed 32 million pixels. Select a smaller area."
        case .complexityLimit: return "This selection has too many shapes or points. Undo or clear it and try again."
        case .cancelled: return "Capture cancelled."
        }
    }
}

/// Every point is display-local, with (0, 0) at the TOP LEFT. No desktop origin or
/// assumed 2× Retina factor enters this model. X and Y scales are derived separately.
public enum CaptureSelectionShape: Equatable, Sendable {
    case rectangle(CGRect)
    case polygon([CGPoint])

    public var bounds: CGRect {
        switch self {
        case .rectangle(let rectangle): return rectangle.standardized
        case .polygon(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}

public struct CaptureSelectionOperation: Equatable, Sendable {
    public let shape: CaptureSelectionShape
    public let subtracts: Bool
    public init(shape: CaptureSelectionShape, subtracts: Bool = false) {
        self.shape = shape
        self.subtracts = subtracts
    }
}

/// An 8-bit, top-row-first coverage plane cropped to its actual nonzero bounds.
/// Alpha is binary, evaluated at pixel centers: no neighboring unselected pixels
/// are sampled into the export. The array includes transparent gaps and holes.
public struct CaptureSelectionMask: Sendable {
    public let pixelBounds: CGRect
    public let width: Int
    public let height: Int
    public let alpha: [UInt8]
    public let selectedPixelCount: Int
}

public struct CaptureSelectionGeometry: Sendable {
    public static let maximumOutputPixels = 32_000_000
    public static let maximumSourcePixels = 64_000_000
    public static let maximumDimension = 32_768
    public static let maximumOperations = 128
    public static let maximumPoints = 8_192

    public let pointSize: CGSize
    public let pixelWidth: Int
    public let pixelHeight: Int
    public private(set) var operations: [CaptureSelectionOperation] = []
    public private(set) var isCancelled = false

    public init(pointSize: CGSize, pixelWidth: Int, pixelHeight: Int) throws {
        guard pointSize.width.isFinite, pointSize.height.isFinite,
              pointSize.width >= 1, pointSize.height >= 1,
              pointSize.width <= CGFloat(Self.maximumDimension),
              pointSize.height <= CGFloat(Self.maximumDimension),
              Self.allowsSourceSize(width: pixelWidth, height: pixelHeight) else {
            throw CaptureSelectionError.invalidCanvas
        }
        self.pointSize = pointSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public static func allowsSourceSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumDimension && height <= maximumDimension &&
            width <= maximumSourcePixels / height
    }

    public static func allowsOutputSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumDimension && height <= maximumDimension &&
            width <= maximumOutputPixels / height
    }

    public var pixelsPerPointX: CGFloat { CGFloat(pixelWidth) / pointSize.width }
    public var pixelsPerPointY: CGFloat { CGFloat(pixelHeight) / pointSize.height }

    /// Pointer coordinates are display-local, top-left based. The outer right and
    /// bottom edges refer to the last pixel, never one pixel beyond the source.
    public func pixelCoordinate(at point: CGPoint) -> CapturePixelCoordinate? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return CapturePixelCoordinate(
            x: Int(max(0, min(CGFloat(pixelWidth - 1), floor(point.x * pixelsPerPointX)))),
            y: Int(max(0, min(CGFloat(pixelHeight - 1), floor(point.y * pixelsPerPointY)))))
    }

    /// Exact pixel-center coverage, matching rectangle rasterization. This avoids
    /// reporting an extra pixel for fractional point bounds on scaled displays.
    public func rectanglePixelBounds(_ rectangle: CGRect) -> CGRect? {
        guard rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
              rectangle.width.isFinite, rectangle.height.isFinite else { return nil }
        let rectangle = rectangle.standardized
        let x0 = ceil(max(0, min(CGFloat(pixelWidth), rectangle.minX * pixelsPerPointX - 0.5)))
        let x1 = ceil(max(0, min(CGFloat(pixelWidth), rectangle.maxX * pixelsPerPointX - 0.5)))
        let y0 = ceil(max(0, min(CGFloat(pixelHeight), rectangle.minY * pixelsPerPointY - 0.5)))
        let y1 = ceil(max(0, min(CGFloat(pixelHeight), rectangle.maxY * pixelsPerPointY - 0.5)))
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Snaps a rectangle to whole source pixels, then moves it, or moves its
    /// bottom/right edges when resizing. Deltas are source pixels, not points.
    /// Arithmetic is clamped before integer conversion, including extreme input.
    public mutating func nudgeRectangle(at index: Int, deltaX: Int, deltaY: Int, resizing: Bool = false) throws {
        let rectangle = try editablePixelRectangle(at: index)
        var edited = rectangle
        if resizing {
            edited.size.width = max(minimumRectanglePixelWidth,
                                    min(CGFloat(pixelWidth) - rectangle.minX, rectangle.width + CGFloat(deltaX)))
            edited.size.height = max(minimumRectanglePixelHeight,
                                     min(CGFloat(pixelHeight) - rectangle.minY, rectangle.height + CGFloat(deltaY)))
        } else {
            edited.origin.x = max(0, min(CGFloat(pixelWidth) - rectangle.width, rectangle.minX + CGFloat(deltaX)))
            edited.origin.y = max(0, min(CGFloat(pixelHeight) - rectangle.height, rectangle.minY + CGFloat(deltaY)))
        }
        try replaceRectangle(at: index, pixelBounds: edited)
    }

    /// Applies exact dimensions. If necessary, moves the rectangle back inside
    /// this display so the requested dimensions are preserved rather than clipped.
    public mutating func setRectanglePixelSize(at index: Int, width: Int, height: Int) throws {
        let rectangle = try editablePixelRectangle(at: index)
        guard CGFloat(width) >= minimumRectanglePixelWidth, CGFloat(height) >= minimumRectanglePixelHeight,
              width <= pixelWidth, height <= pixelHeight else { throw CaptureSelectionError.invalidShape }
        try replaceRectangle(at: index, pixelBounds: CGRect(
            x: min(rectangle.minX, CGFloat(pixelWidth - width)),
            y: min(rectangle.minY, CGFloat(pixelHeight - height)), width: CGFloat(width), height: CGFloat(height)))
    }

    public mutating func removeOperation(at index: Int) throws {
        guard !isCancelled else { throw CaptureSelectionError.cancelled }
        guard operations.indices.contains(index) else { throw CaptureSelectionError.invalidShape }
        operations.remove(at: index)
    }

    private var minimumRectanglePixelWidth: CGFloat { ceil(2 * pixelsPerPointX) }
    private var minimumRectanglePixelHeight: CGFloat { ceil(2 * pixelsPerPointY) }

    private func editablePixelRectangle(at index: Int) throws -> CGRect {
        guard !isCancelled else { throw CaptureSelectionError.cancelled }
        guard operations.indices.contains(index), case .rectangle(let rectangle) = operations[index].shape,
              var pixelBounds = rectanglePixelBounds(rectangle) else {
            throw CaptureSelectionError.invalidShape
        }
        // Fractional display scales can give a 2-point drag fewer than 2 points
        // of pixel-center coverage. Let precision editing repair that tiny draft.
        pixelBounds.size.width = max(minimumRectanglePixelWidth, pixelBounds.width)
        pixelBounds.size.height = max(minimumRectanglePixelHeight, pixelBounds.height)
        pixelBounds.origin.x = min(pixelBounds.minX, CGFloat(pixelWidth) - pixelBounds.width)
        pixelBounds.origin.y = min(pixelBounds.minY, CGFloat(pixelHeight) - pixelBounds.height)
        return pixelBounds
    }

    private mutating func replaceRectangle(at index: Int, pixelBounds: CGRect) throws {
        let rectangle = CGRect(x: pixelBounds.minX / pixelsPerPointX, y: pixelBounds.minY / pixelsPerPointY,
                               width: pixelBounds.width / pixelsPerPointX, height: pixelBounds.height / pixelsPerPointY)
        // The edit does not change operation order, Boolean mode or complexity.
        operations[index] = CaptureSelectionOperation(shape: .rectangle(rectangle), subtracts: operations[index].subtracts)
    }

    public mutating func append(_ shape: CaptureSelectionShape, subtracts: Bool = false) throws {
        guard !isCancelled else { throw CaptureSelectionError.cancelled }
        guard operations.count < Self.maximumOperations else { throw CaptureSelectionError.complexityLimit }
        func valid(_ value: CGFloat) -> Bool { value.isFinite && abs(value) <= 1_000_000_000 }
        switch shape {
        case .rectangle(let rectangle):
            guard valid(rectangle.origin.x), valid(rectangle.origin.y),
                  valid(rectangle.width), valid(rectangle.height) else { throw CaptureSelectionError.invalidShape }
        case .polygon(let points):
            guard points.count >= 3, points.allSatisfy({ valid($0.x) && valid($0.y) }) else {
                throw CaptureSelectionError.invalidShape
            }
            guard points.count <= Self.maximumPoints else { throw CaptureSelectionError.complexityLimit }
        }
        let totalPoints = operations.reduce(0) { count, operation in
            if case .polygon(let points) = operation.shape { return count + points.count }
            return count + 4
        }
        let newPoints: Int
        if case .polygon(let points) = shape { newPoints = points.count } else { newPoints = 4 }
        guard totalPoints + newPoints <= Self.maximumPoints else { throw CaptureSelectionError.complexityLimit }
        let clipped = shape.bounds.intersection(CGRect(origin: .zero, size: pointSize))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { throw CaptureSelectionError.invalidShape }
        operations.append(CaptureSelectionOperation(shape: shape, subtracts: subtracts))
    }

    public mutating func undo() { if !isCancelled && !operations.isEmpty { operations.removeLast() } }
    public mutating func clear() { operations.removeAll(keepingCapacity: false) }

    /// Terminal for this draft. A late input event cannot revive a cancelled selection.
    public mutating func cancel() {
        isCancelled = true
        clear()
    }

    /// Conservative preflight bounds. Subtractions do not enlarge them. Allocation is
    /// limited BEFORE rasterizing; a giant box with a tiny surviving hole is rejected.
    public func enclosingPixelBounds() throws -> CGRect {
        guard !isCancelled else { throw CaptureSelectionError.cancelled }
        let canvas = CGRect(origin: .zero, size: pointSize)
        var bounds = CGRect.null
        for operation in operations where !operation.subtracts {
            bounds = bounds.union(operation.shape.bounds.intersection(canvas))
        }
        guard !bounds.isNull, !bounds.isEmpty else { throw CaptureSelectionError.emptySelection }
        let sx = CGFloat(pixelWidth) / pointSize.width, sy = CGFloat(pixelHeight) / pointSize.height
        let left = max(0, Int(floor(bounds.minX * sx))), top = max(0, Int(floor(bounds.minY * sy)))
        let right = min(pixelWidth, Int(ceil(bounds.maxX * sx))), bottom = min(pixelHeight, Int(ceil(bounds.maxY * sy)))
        guard Self.allowsOutputSize(width: right - left, height: bottom - top) else {
            throw CaptureSelectionError.pixelLimit
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Ordered Boolean composition: add unions with the existing mask; subtract
    /// removes from it. Adding again can restore an earlier subtracted area.
    /// Polygon fill uses the even-odd rule, including concave/self-crossing paths.
    public func rasterized() throws -> CaptureSelectionMask {
        try Task.checkCancellation()
        let bounds = try enclosingPixelBounds()
        let width = Int(bounds.width), height = Int(bounds.height)
        let sx = CGFloat(pixelWidth) / pointSize.width, sy = CGFloat(pixelHeight) / pointSize.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        try alpha.withUnsafeMutableBufferPointer { buffer in
            for operation in operations {
                try Task.checkCancellation()
                let value: UInt8 = operation.subtracts ? 0 : 255
                switch operation.shape {
                case .rectangle(let rectangle):
                    let rect = rectangle.standardized
                    // Pixel-center coverage, clamped before converting to integer.
                    let x0 = Int(ceil(max(0, min(CGFloat(width), rect.minX * sx - bounds.minX - 0.5))))
                    let x1 = Int(ceil(max(0, min(CGFloat(width), rect.maxX * sx - bounds.minX - 0.5))))
                    let y0 = Int(ceil(max(0, min(CGFloat(height), rect.minY * sy - bounds.minY - 0.5))))
                    let y1 = Int(ceil(max(0, min(CGFloat(height), rect.maxY * sy - bounds.minY - 0.5))))
                    if x1 > x0, y1 > y0 {
                        for y in y0..<y1 {
                            if y % 64 == 0 { try Task.checkCancellation() }
                            for x in x0..<x1 { buffer[y * width + x] = value }
                        }
                    }
                case .polygon(let vertices):
                    let points = vertices.map { CGPoint(x: $0.x * sx - bounds.minX, y: $0.y * sy - bounds.minY) }
                    let shapeBounds = operation.shape.bounds
                    let firstRow = Int(ceil(max(0, min(CGFloat(height), shapeBounds.minY * sy - bounds.minY - 0.5))))
                    let lastRow = Int(ceil(max(0, min(CGFloat(height), shapeBounds.maxY * sy - bounds.minY - 0.5))))
                    var crossings: [CGFloat] = []
                    crossings.reserveCapacity(points.count)
                    for y in firstRow..<lastRow {
                        if y % 32 == 0 { try Task.checkCancellation() }
                        crossings.removeAll(keepingCapacity: true)
                        let scanY = CGFloat(y) + 0.5
                        var previous = points[points.count - 1]
                        for point in points {
                            // Half-open vertical intervals count vertices exactly once.
                            if (point.y > scanY) != (previous.y > scanY) {
                                crossings.append(point.x + (scanY - point.y) * (previous.x - point.x) / (previous.y - point.y))
                            }
                            previous = point
                        }
                        crossings.sort()
                        var index = 0
                        while index + 1 < crossings.count {
                            let left = Int(ceil(max(0, min(CGFloat(width), crossings[index] - 0.5))))
                            let right = Int(ceil(max(0, min(CGFloat(width), crossings[index + 1] - 0.5))))
                            if right > left { for x in left..<right { buffer[y * width + x] = value } }
                            index += 2
                        }
                    }
                }
            }
        }
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        for y in 0..<height {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<width where alpha[y * width + x] != 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
            }
        }
        let croppedWidth = maxX - minX + 1, croppedHeight = maxY - minY + 1
        guard maxX >= minX, maxY >= minY,
              CGFloat(croppedWidth) / sx >= 2, CGFloat(croppedHeight) / sy >= 2,
              CGFloat(count) / (sx * sy) >= 4 else { throw CaptureSelectionError.emptySelection }
        if croppedWidth != width || croppedHeight != height {
            var cropped = [UInt8](repeating: 0, count: croppedWidth * croppedHeight)
            for y in 0..<croppedHeight {
                if y % 64 == 0 { try Task.checkCancellation() }
                let sourceOffset = (minY + y) * width + minX
                cropped.replaceSubrange(y * croppedWidth..<(y + 1) * croppedWidth,
                                        with: alpha[sourceOffset..<sourceOffset + croppedWidth])
            }
            alpha = cropped
        }
        return CaptureSelectionMask(pixelBounds: CGRect(x: Int(bounds.minX) + minX, y: Int(bounds.minY) + minY,
                                                         width: croppedWidth, height: croppedHeight),
                                    width: croppedWidth, height: croppedHeight, alpha: alpha, selectedPixelCount: count)
    }
}
