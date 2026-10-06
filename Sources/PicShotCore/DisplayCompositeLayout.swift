import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum DisplayCompositeError: Error, LocalizedError, Equatable {
    case noDisplays, invalidDisplay, duplicateDisplay, pixelLimit, layoutChanged, incomplete, finished
    public var errorDescription: String? {
        switch self {
        case .noDisplays: return "No displays are available to capture."
        case .invalidDisplay: return "The display geometry or pixel density is unsupported. Start a new capture."
        case .duplicateDisplay: return "The display list contains duplicate identifiers. Start a new capture."
        case .pixelLimit: return "The combined desktop exceeds 64 million pixels or 32,768 pixels on one side. Reduce the display resolution or capture one display."
        case .layoutChanged: return "The display arrangement, rotation, resolution, or connection changed during capture. Start a new capture."
        case .incomplete: return "The combined screenshot is incomplete. Start a new capture."
        case .finished: return "This screenshot has already finished or been cancelled."
        }
    }
}

/// Bounds use global Quartz logical points: X rightwards, Y downwards. Negative
/// origins are valid. The frame supplied by ScreenCaptureKit is ALREADY oriented;
/// rotation is snapshot metadata, never a request to rotate those pixels again.
public struct DisplayCaptureDescriptor: Equatable, Sendable {
    public let id: UInt32
    public let bounds: CGRect
    public let pixelsPerPoint: CGFloat
    public let rotationDegrees: Double
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(id: UInt32, bounds: CGRect, pixelsPerPoint: CGFloat, rotationDegrees: Double = 0) throws {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 1, bounds.height >= 1,
              bounds.minX.isFinite, bounds.minY.isFinite, bounds.maxX.isFinite, bounds.maxY.isFinite,
              pixelsPerPoint.isFinite, pixelsPerPoint > 0,
              rotationDegrees.isFinite else { throw DisplayCompositeError.invalidDisplay }
        let width = (bounds.width * pixelsPerPoint).rounded()
        let height = (bounds.height * pixelsPerPoint).rounded()
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= CGFloat(DisplayCompositeLayout.maximumDimension),
              height <= CGFloat(DisplayCompositeLayout.maximumDimension),
              width <= CGFloat(DisplayCompositeLayout.maximumPixels) / height else {
            throw DisplayCompositeError.pixelLimit
        }
        self.id = id
        self.bounds = bounds
        self.pixelsPerPoint = pixelsPerPoint
        self.rotationDegrees = rotationDegrees
        pixelWidth = Int(width)
        pixelHeight = Int(height)
    }
}

public struct DisplayCompositePlacement: Equatable, Sendable {
    public let display: DisplayCaptureDescriptor
    /// Output pixels, top-left origin. Common rounded edges prevent seams between
    /// adjacent displays even when their logical coordinates or scale are fractional.
    public let pixelBounds: CGRect
}

public struct DisplayCompositeLayout: Equatable, Sendable {
    public static let maximumPixels = 64_000_000
    public static let maximumDimension = 32_768
    public static let maximumDisplays = 64
    public let desktopBounds: CGRect
    public let pixelsPerPoint: CGFloat
    public let width: Int
    public let height: Int
    /// Stable ID order determines overlap precedence, including mirrored displays.
    public let placements: [DisplayCompositePlacement]

    public init(displays: [DisplayCaptureDescriptor]) throws {
        guard !displays.isEmpty else { throw DisplayCompositeError.noDisplays }
        guard displays.count <= Self.maximumDisplays else { throw DisplayCompositeError.invalidDisplay }
        guard Set(displays.map(\.id)).count == displays.count else { throw DisplayCompositeError.duplicateDisplay }
        let ordered = displays.sorted { $0.id < $1.id }
        let minX = ordered.map { $0.bounds.minX }.min()!
        let minY = ordered.map { $0.bounds.minY }.min()!
        let maxX = ordered.map { $0.bounds.maxX }.max()!
        let maxY = ordered.map { $0.bounds.maxY }.max()!
        let density = ordered.map(\.pixelsPerPoint).max()!
        let pixelWidth = ((maxX - minX) * density).rounded()
        let pixelHeight = ((maxY - minY) * density).rounded()
        // Check finite values and division BEFORE integer conversion/allocation.
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth >= 1, pixelHeight >= 1,
              pixelWidth <= CGFloat(Self.maximumDimension), pixelHeight <= CGFloat(Self.maximumDimension),
              pixelWidth <= CGFloat(Self.maximumPixels) / pixelHeight else { throw DisplayCompositeError.pixelLimit }
        desktopBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        pixelsPerPoint = density
        width = Int(pixelWidth)
        height = Int(pixelHeight)
        placements = ordered.map { display in
            let left = ((display.bounds.minX - minX) * density).rounded()
            let top = ((display.bounds.minY - minY) * density).rounded()
            let right = ((display.bounds.maxX - minX) * density).rounded()
            let bottom = ((display.bounds.maxY - minY) * density).rounded()
            return DisplayCompositePlacement(display: display,
                pixelBounds: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        guard placements.allSatisfy({ $0.pixelBounds.width >= 1 && $0.pixelBounds.height >= 1 }) else {
            throw DisplayCompositeError.invalidDisplay
        }
    }

    public static func allowsSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumDimension && height <= maximumDimension && width <= maximumPixels / height
    }

    public func validate(displays: [DisplayCaptureDescriptor]) throws {
        guard displays.sorted(by: { $0.id < $1.id }) == placements.map(\.display) else {
            throw DisplayCompositeError.layoutChanged
        }
    }
}
