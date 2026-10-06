import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum CapturePresetError: Error, LocalizedError, Equatable {
    case invalidName, invalidGeometry, invalidManifest, unsupportedVersion, limitReached
    case duplicateIdentifier, missingPreset, missingDisplay, ambiguousDisplay, displayChanged
    case unsafePath, loadFailed, saveFailed

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "请输入 1–64 个字符的预设名称（最多 256 字节，不能包含换行或控制字符）。"
        case .invalidGeometry: return "预设区域或显示器信息无效，请重新框选并保存。"
        case .invalidManifest: return "截图预设文件已损坏或内容无效，原文件未被覆盖。"
        case .unsupportedVersion: return "截图预设文件来自不支持的版本，原文件未被覆盖。"
        case .limitReached: return "最多保存 32 个截图预设，请先删除不需要的预设。"
        case .duplicateIdentifier: return "截图预设标识重复，无法保存。"
        case .missingPreset: return "此截图预设已不存在，请重新选择。"
        case .missingDisplay: return "此预设的显示器未连接，请连接原显示器或重新保存预设。"
        case .ambiguousDisplay: return "无法唯一识别此预设的显示器，已取消截图。"
        case .displayChanged: return "显示器位置、分辨率、缩放或旋转已改变，请重新框选并保存预设。"
        case .unsafePath: return "截图预设保存位置不安全，无法读取或修改。"
        case .loadFailed: return "无法读取截图预设，请检查本地文件权限后重试。"
        case .saveFailed: return "无法保存截图预设，请检查本地文件权限和可用空间后重试；原预设未改变。"
        }
    }
}

/// A physical display identity plus the complete coordinate configuration at save
/// time. Never persist a CGDirectDisplayID: those IDs can be reused after reconnect.
public struct CapturePresetDisplay: Codable, Equatable, Sendable {
    public let uuid: UUID
    /// Global AppKit points, Y upwards. The origin is included deliberately:
    /// moving a display in Settings invalidates existing presets, rather than
    /// silently translating an old region into a newly arranged desktop.
    public let frame: CGRect
    /// Oriented dimensions of the actual frozen source raster.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let rotationDegrees: Double

    public init(uuid: UUID, frame: CGRect, pixelWidth: Int, pixelHeight: Int, rotationDegrees: Double) throws {
        self.uuid = uuid; self.frame = frame
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.rotationDegrees = rotationDegrees
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case uuid, frame, pixelWidth, pixelHeight, rotationDegrees }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(uuid: values.decode(UUID.self, forKey: .uuid), frame: values.decode(CGRect.self, forKey: .frame),
                      pixelWidth: values.decode(Int.self, forKey: .pixelWidth), pixelHeight: values.decode(Int.self, forKey: .pixelHeight),
                      rotationDegrees: values.decode(Double.self, forKey: .rotationDegrees))
    }

    public func validate() throws {
        guard Self.finiteRectangle(frame), frame.width >= 1, frame.height >= 1,
              frame.width <= CGFloat(DisplayCompositeLayout.maximumDimension),
              frame.height <= CGFloat(DisplayCompositeLayout.maximumDimension),
              abs(frame.minX) <= 1_000_000, abs(frame.minY) <= 1_000_000,
              abs(frame.maxX) <= 1_000_000, abs(frame.maxY) <= 1_000_000,
              DisplayCompositeLayout.allowsSize(width: pixelWidth, height: pixelHeight),
              [0.0, 90.0, 180.0, 270.0].contains(rotationDegrees) else {
            throw CapturePresetError.invalidGeometry
        }
    }

    fileprivate static func finiteRectangle(_ value: CGRect) -> Bool {
        value.origin.x.isFinite && value.origin.y.isFinite && value.width.isFinite && value.height.isFinite &&
            value.minX.isFinite && value.minY.isFinite && value.maxX.isFinite && value.maxY.isFinite &&
            value.width > 0 && value.height > 0
    }
}

/// Metadata only: a preset never saves a desktop image, window title, process name,
/// or Accessibility element. Pixel coordinates are the source of truth.
public struct CapturePreset: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameCharacters = 64
    public static let maximumNameBytes = 256
    public let id: UUID
    public let name: String
    public let delay: ScreenshotDelay
    public let display: CapturePresetDisplay
    /// Display-local points, Y downwards, exactly derived from pixelFrame.
    public let topLeftFrame: CGRect
    /// Integral CGImage source pixels, Y downwards. Never re-round on invocation.
    public let pixelFrame: CGRect

    public init(id: UUID = UUID(), name: String, delay: ScreenshotDelay, display: CapturePresetDisplay,
                topLeftFrame: CGRect, pixelFrame: CGRect) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { throw CapturePresetError.invalidName }
        try display.validate()
        guard CapturePresetDisplay.finiteRectangle(pixelFrame),
              [pixelFrame.origin.x, pixelFrame.origin.y, pixelFrame.width, pixelFrame.height].allSatisfy({ $0.rounded() == $0 }),
              pixelFrame.minX >= 0, pixelFrame.minY >= 0,
              pixelFrame.maxX <= CGFloat(display.pixelWidth), pixelFrame.maxY <= CGFloat(display.pixelHeight) else {
            throw CapturePresetError.invalidGeometry
        }
        let scaleX = CGFloat(display.pixelWidth) / display.frame.width
        let scaleY = CGFloat(display.pixelHeight) / display.frame.height
        let canonical = CGRect(x: pixelFrame.minX / scaleX, y: pixelFrame.minY / scaleY,
                               width: pixelFrame.width / scaleX, height: pixelFrame.height / scaleY)
        // Accept only floating-point representation noise, never an extra pixel
        // or rounding to a logical point. Save the canonical value after checking.
        guard canonical.width >= 2, canonical.height >= 2,
              CapturePresetDisplay.finiteRectangle(topLeftFrame),
              zip([topLeftFrame.origin.x, topLeftFrame.origin.y, topLeftFrame.width, topLeftFrame.height],
                  [canonical.origin.x, canonical.origin.y, canonical.width, canonical.height])
                .allSatisfy({ abs($0.0 - $0.1) <= 1e-9 }) else { throw CapturePresetError.invalidGeometry }
        self.id = id; self.name = name; self.delay = delay; self.display = display
        self.topLeftFrame = canonical; self.pixelFrame = pixelFrame
    }

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maximumNameCharacters && name.utf8.count <= maximumNameBytes &&
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
    }

    /// Requires exactly one matching stable identity and an unchanged complete
    /// configuration. Call again after countdown and immediately before cropping.
    @discardableResult public func resolveDisplay(in displays: [CapturePresetDisplay]) throws -> CapturePresetDisplay {
        guard displays.count <= DisplayCompositeLayout.maximumDisplays else { throw CapturePresetError.ambiguousDisplay }
        let matches = displays.filter { $0.uuid == display.uuid }
        guard !matches.isEmpty else { throw CapturePresetError.missingDisplay }
        guard matches.count == 1 else { throw CapturePresetError.ambiguousDisplay }
        guard matches[0] == display else { throw CapturePresetError.displayChanged }
        return matches[0]
    }

    public func replacing(name: String? = nil, delay: ScreenshotDelay? = nil) throws -> CapturePreset {
        try CapturePreset(id: id, name: name ?? self.name, delay: delay ?? self.delay, display: display,
                          topLeftFrame: topLeftFrame, pixelFrame: pixelFrame)
    }

    private enum CodingKeys: String, CodingKey { case id, name, delaySeconds, display, topLeftFrame, pixelFrame }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedName = try values.decode(String.self, forKey: .name)
        guard Self.validName(savedName) else { throw CapturePresetError.invalidManifest }
        guard let delay = ScreenshotDelay(rawValue: try values.decode(Int.self, forKey: .delaySeconds)) else {
            throw CapturePresetError.invalidManifest
        }
        try self.init(id: values.decode(UUID.self, forKey: .id), name: savedName, delay: delay,
                      display: values.decode(CapturePresetDisplay.self, forKey: .display),
                      topLeftFrame: values.decode(CGRect.self, forKey: .topLeftFrame),
                      pixelFrame: values.decode(CGRect.self, forKey: .pixelFrame))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
        try values.encode(delay.rawValue, forKey: .delaySeconds); try values.encode(display, forKey: .display)
        try values.encode(topLeftFrame, forKey: .topLeftFrame); try values.encode(pixelFrame, forKey: .pixelFrame)
    }
}

/// The manifest is intentionally tiny and versioned independently of screenshot
/// preferences. Reject a whole malformed catalog instead of dropping entries.
public struct CapturePresetIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumPresets = 32
    public static let maximumBytes = 128 * 1_024
    public let version: Int
    public let presets: [CapturePreset]

    public init(presets: [CapturePreset] = []) throws {
        guard presets.count <= Self.maximumPresets else { throw CapturePresetError.limitReached }
        guard Set(presets.map(\.id)).count == presets.count else { throw CapturePresetError.duplicateIdentifier }
        version = Self.schemaVersion; self.presets = presets
    }

    private enum CodingKeys: String, CodingKey { case version, presets }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.schemaVersion else {
            throw CapturePresetError.unsupportedVersion
        }
        // Bound element decoding as well as disk bytes; don't materialize an
        // unbounded array of malicious records before checking its count.
        var records = try values.nestedUnkeyedContainer(forKey: .presets)
        if let count = records.count, count > Self.maximumPresets { throw CapturePresetError.limitReached }
        var presets: [CapturePreset] = []
        while !records.isAtEnd {
            guard presets.count < Self.maximumPresets else { throw CapturePresetError.limitReached }
            presets.append(try records.decode(CapturePreset.self))
        }
        try self.init(presets: presets)
    }
}
