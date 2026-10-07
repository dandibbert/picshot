import Foundation
import CoreGraphics

/// Output-only pixel metadata. Never bake this into the captured image or use it
/// to translate annotation coordinates. Store this value in the editor snapshot.
struct ImageOutputDecoration: Equatable, Sendable {
    struct Color: Equatable, Sendable {
        var red: Double = 1
        var green: Double = 1
        var blue: Double = 1
        var alpha: Double = 1
        fileprivate var isValid: Bool {
            [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
    }
    var enabled = false
    var cornerRadius: Double = 0
    var borderEnabled = false
    var borderWidth: Double = 1
    var borderColor = Color()
    var shadowEnabled = false
    /// Approximate Gaussian sigma in source pixels, implemented as three bounded
    /// box passes of radius ceil(blur). Its exact support is 3 * ceil(blur).
    var shadowBlur: Double = 12
    /// Positive right/down, independent of AppKit/annotation y-up coordinates.
    var shadowOffsetX: Double = 0
    var shadowOffsetY: Double = 6
    var shadowOpacity: Double = 0.3
    static let none = Self()

    var hasBorder: Bool { enabled && borderEnabled && borderWidth > 0 && borderColor.alpha > 0 }
    var hasShadow: Bool { enabled && shadowEnabled && shadowOpacity > 0 }
    var isIdentity: Bool { !enabled || (cornerRadius == 0 && !hasBorder && !hasShadow) }

    func validate() throws {
        guard cornerRadius.isFinite, (0...4_096).contains(cornerRadius),
              borderWidth.isFinite, (0...128).contains(borderWidth), borderColor.isValid,
              shadowBlur.isFinite, (0...64).contains(shadowBlur),
              shadowOffsetX.isFinite, (-128...128).contains(shadowOffsetX),
              shadowOffsetY.isFinite, (-128...128).contains(shadowOffsetY),
              shadowOpacity.isFinite, (0...1).contains(shadowOpacity) else {
            throw ImageOutputDecorationError.invalidOptions
        }
    }

    /// Preview applies the same renderer to a bounded thumbnail. Pixel lengths
    /// scale together; the final output always uses the unscaled metadata.
    func scaled(by factor: Double) -> Self {
        var result = self
        result.cornerRadius *= factor; result.borderWidth *= factor
        result.shadowBlur *= factor; result.shadowOffsetX *= factor; result.shadowOffsetY *= factor
        return result
    }
}

struct ImageOutputDecorationLimits {
    var maximumDimension = 32_768
    var maximumPixels = 100_000_000
    var maximumWorkingBytes = 512 * 1_024 * 1_024
    var maximumPadding = 512
    static let standard = Self()
    func validate() throws {
        guard maximumDimension > 0, maximumDimension <= Self.standard.maximumDimension,
              maximumPixels > 0, maximumPixels <= Self.standard.maximumPixels,
              maximumWorkingBytes >= 4, maximumWorkingBytes <= Self.standard.maximumWorkingBytes,
              maximumPadding >= 0, maximumPadding <= Self.standard.maximumPadding else {
            throw ImageOutputDecorationError.invalidOptions
        }
    }
}

struct ImageOutputDecorationLayout: Equatable {
    let width: Int
    let height: Int
    let left: Int
    let right: Int
    let top: Int
    let bottom: Int
    let radius: Double
    let borderWidth: Double
    let shadowBoxRadius: Int
    /// Known RGBA + mask allocations. Renderer queries native temporary storage
    /// and admits that too within maximumWorkingBytes before convolution.
    let workingBytes: Int
    /// Pixel rectangle in bottom-left coordinates; metadata does not move the
    /// editor's image. Only the exported projection uses this placement.
    var imageRect: CGRect {
        CGRect(x: left, y: bottom, width: width - left - right, height: height - top - bottom)
    }

    static func make(width: Int, height: Int, decoration: ImageOutputDecoration,
                     limits: ImageOutputDecorationLimits = .standard) throws -> Self {
        try limits.validate()
        guard width > 0, height > 0, width <= limits.maximumDimension, height <= limits.maximumDimension,
              width <= limits.maximumPixels / height else { throw ImageOutputDecorationError.tooLarge }
        // Disabled metadata is inert, including stale fields from older builds.
        if decoration.enabled { try decoration.validate() }
        let radius = decoration.enabled ? min(decoration.cornerRadius, Double(min(width, height)) / 2) : 0
        let border = decoration.hasBorder ? min(decoration.borderWidth, Double(min(width, height)) / 2) : 0
        let box = decoration.hasShadow ? Int(ceil(decoration.shadowBlur)) : 0
        let support = decoration.hasShadow ? Double(3 * box + 1) : 0
        func padding(_ offset: Double) throws -> Int {
            let value = ceil(max(0, support + offset))
            guard value.isFinite, value <= Double(limits.maximumPadding) else { throw ImageOutputDecorationError.tooLarge }
            return Int(value)
        }
        let left = try decoration.hasShadow ? padding(-decoration.shadowOffsetX) : 0
        let right = try decoration.hasShadow ? padding(decoration.shadowOffsetX) : 0
        let top = try decoration.hasShadow ? padding(-decoration.shadowOffsetY) : 0
        let bottom = try decoration.hasShadow ? padding(decoration.shadowOffsetY) : 0
        let outputWidth = width + left + right, outputHeight = height + top + bottom
        guard outputWidth <= limits.maximumDimension, outputHeight <= limits.maximumDimension,
              outputWidth <= limits.maximumPixels / outputHeight else { throw ImageOutputDecorationError.tooLarge }
        let count = outputWidth * outputHeight
        let bytesPerPixel = decoration.hasShadow ? 6 : 4
        guard count <= limits.maximumWorkingBytes / bytesPerPixel else { throw ImageOutputDecorationError.tooLarge }
        return Self(width: outputWidth, height: outputHeight, left: left, right: right, top: top, bottom: bottom,
                    radius: radius, borderWidth: border, shadowBoxRadius: box, workingBytes: count * bytesPerPixel)
    }
}

enum ImageOutputDecorationError: LocalizedError {
    case invalidOptions, tooLarge, allocationFailed, conversionFailed
    var errorDescription: String? {
        switch self {
        case .invalidOptions: return "圆角、边框或阴影参数无效。"
        case .tooLarge: return "装饰后的图片超过尺寸或内存上限，请减小阴影或先裁剪。"
        case .allocationFailed: return "无法分配图片装饰所需的内存。"
        case .conversionFailed: return "无法生成图片装饰，原图保持不变。"
        }
    }
}

/// A palette transaction holds values only. Owner records ONE undo checkpoint
/// before applying a changed value; cancel/close never calls the apply callback.
struct ImageOutputDecorationDraft {
    let original: ImageOutputDecoration
    var value: ImageOutputDecoration
    private(set) var isFinished = false
    init(_ original: ImageOutputDecoration) { self.original = original; value = original }
    mutating func reset() { guard !isFinished else { return }; value = .none }
    mutating func apply() throws -> ImageOutputDecoration? {
        guard !isFinished else { return nil }
        if value.enabled { try value.validate() }
        isFinished = true
        return value == original ? nil : value
    }
    mutating func cancel() { isFinished = true; value = original }
}
