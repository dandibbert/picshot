import Foundation

public enum MultiWindowCaptureError: Error, LocalizedError, Equatable {
    case empty, noWindows, windowLimit, invalidWindow, changed, pixelLimit, incomplete, finished, deadline, diskLimit
    public var errorDescription: String? {
        switch self {
        case .empty: return "请至少选择一个窗口。"
        case .noWindows: return "当前桌面没有可截图的窗口，请打开窗口后重试。"
        case .windowLimit: return "一次最多选择 8 个窗口。"
        case .invalidWindow: return "无法截取此窗口，请选择其他窗口。"
        case .changed: return "所选窗口或屏幕在截图过程中发生变化，请重新截图。"
        case .pixelLimit: return "所选窗口超出截图尺寸上限，请减少窗口或缩小窗口后重试。"
        case .incomplete: return "未能完整截取所选窗口，本次截图未保存。"
        case .finished: return "本次窗口截图已结束。"
        case .deadline: return "窗口截图超时，请重新截图。"
        case .diskLimit: return "临时磁盘空间不足，无法截取窗口。"
        }
    }
}

public enum MultiWindowCaptureLimits {
    public static let windows = 8
    public static let inventory = 1_024
    public static let dimension = 16_384
    public static let framePixels = 16_000_000
    public static let totalInputPixels = 64_000_000
    public static let outputPixels = 32_000_000
    /// App-owned canvas + admitted source raster + explicit normalization raster.
    /// Decoder/framework scratch and mapped PNG bytes are measured separately.
    public static let ownedRasterBytes = 192_000_000
    public static let temporaryBytes = 80 * 1_024 * 1_024
    public static let acquisitionSeconds: TimeInterval = 20
    public static let selectionSeconds: TimeInterval = 180
    public static func allows(width: Int, height: Int, pixels: Int) -> Bool {
        width > 0 && height > 0 && width <= dimension && height <= dimension && width <= pixels / height
    }
}

/// Quartz global logical points (top-left origin). Source identity includes the
/// owning process incarnation; z-order is represented by inventory array order.
public struct MultiWindowDescriptor: Equatable, Sendable {
    public let id: UInt32
    public let ownerPID: Int32
    public let ownerStartedAt: TimeInterval
    public let label: String
    public let bounds: CGRect
    /// Upper bound from displays intersecting this window. The actual backing
    /// raster can use a lower density; it is checked before decoding/composition.
    public let maximumScale: CGFloat
    public let maximumWidth: Int
    public let maximumHeight: Int

    public init(id: UInt32, ownerPID: Int32, ownerStartedAt: TimeInterval, label: String, bounds: CGRect, maximumScale: CGFloat) throws {
        guard id != 0, ownerPID > 0, ownerStartedAt.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite, bounds.maxX.isFinite, bounds.maxY.isFinite,
              bounds.width >= 2, bounds.height >= 2,
              maximumScale.isFinite, maximumScale >= 1, maximumScale <= 4 else { throw MultiWindowCaptureError.invalidWindow }
        let width = (bounds.width * maximumScale).rounded(.up)
        let height = (bounds.height * maximumScale).rounded(.up)
        guard width <= CGFloat(MultiWindowCaptureLimits.dimension), height <= CGFloat(MultiWindowCaptureLimits.dimension),
              width <= CGFloat(MultiWindowCaptureLimits.framePixels) / height else { throw MultiWindowCaptureError.pixelLimit }
        self.id = id; self.ownerPID = ownerPID; self.ownerStartedAt = ownerStartedAt
        self.label = String(label.prefix(160)); self.bounds = bounds; self.maximumScale = maximumScale
        maximumWidth = Int(width); maximumHeight = Int(height)
    }

    public func matchesSource(_ other: Self) -> Bool {
        id == other.id && ownerPID == other.ownerPID && ownerStartedAt == other.ownerStartedAt &&
        bounds == other.bounds && maximumScale == other.maximumScale &&
        maximumWidth == other.maximumWidth && maximumHeight == other.maximumHeight
    }

    public func validateRaster(width: Int, height: Int) throws {
        guard MultiWindowCaptureLimits.allows(width: width, height: height, pixels: MultiWindowCaptureLimits.framePixels),
              width <= maximumWidth, height <= maximumHeight,
              width >= Int(bounds.width.rounded(.down)), height >= Int(bounds.height.rounded(.down)),
              abs(CGFloat(width) / bounds.width - CGFloat(height) / bounds.height) <= 1 / min(bounds.width, bounds.height) else {
            throw MultiWindowCaptureError.changed
        }
    }
}

public struct MultiWindowPlacement: Equatable, Sendable {
    public let window: MultiWindowDescriptor
    public let pixelBounds: CGRect
}

public struct MultiWindowCaptureLayout: Equatable, Sendable {
    public let desktopBounds: CGRect
    public let pixelsPerPoint: CGFloat
    public let width: Int
    public let height: Int
    /// Back-to-front, irrespective of selection click order.
    public let placements: [MultiWindowPlacement]
    public let maximumInputPixels: Int

    public init(frontToBack windows: [MultiWindowDescriptor]) throws {
        guard !windows.isEmpty else { throw MultiWindowCaptureError.empty }
        guard windows.count <= MultiWindowCaptureLimits.windows else { throw MultiWindowCaptureError.windowLimit }
        guard Set(windows.map(\.id)).count == windows.count else { throw MultiWindowCaptureError.invalidWindow }
        let minX = windows.map { $0.bounds.minX }.min()!, minY = windows.map { $0.bounds.minY }.min()!
        let maxX = windows.map { $0.bounds.maxX }.max()!, maxY = windows.map { $0.bounds.maxY }.max()!
        let scale = windows.map(\.maximumScale).max()!
        let w = ((maxX - minX) * scale).rounded(), h = ((maxY - minY) * scale).rounded()
        guard w.isFinite, h.isFinite, w >= 1, h >= 1,
              w <= CGFloat(MultiWindowCaptureLimits.dimension), h <= CGFloat(MultiWindowCaptureLimits.dimension),
              w <= CGFloat(MultiWindowCaptureLimits.outputPixels) / h else { throw MultiWindowCaptureError.pixelLimit }
        let inputPixels = windows.reduce(0) { $0 + $1.maximumWidth * $1.maximumHeight }
        guard inputPixels <= MultiWindowCaptureLimits.totalInputPixels else { throw MultiWindowCaptureError.pixelLimit }
        desktopBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        pixelsPerPoint = scale; width = Int(w); height = Int(h); maximumInputPixels = inputPixels
        placements = windows.reversed().map { window in
            let left = ((window.bounds.minX - minX) * scale).rounded(), top = ((window.bounds.minY - minY) * scale).rounded()
            let right = ((window.bounds.maxX - minX) * scale).rounded(), bottom = ((window.bounds.maxY - minY) * scale).rounded()
            return MultiWindowPlacement(window: window, pixelBounds: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
    }

    /// The diagnostic normalized renderer owns an additional tightly packed RGBA
    /// source. Reject impossible maximum-density layouts before allocating the
    /// output. Actual row padding is checked again before normalization.
    public func validateNormalizedRasterBudget() throws {
        for placement in placements {
            _ = try normalizedRasterBytes(width: placement.window.maximumWidth,
                height: placement.window.maximumHeight, bytesPerRow: placement.window.maximumWidth * 4)
        }
    }

    public func normalizedRasterBytes(width sourceWidth: Int, height sourceHeight: Int, bytesPerRow: Int) throws -> Int {
        guard MultiWindowCaptureLimits.allows(width: sourceWidth, height: sourceHeight, pixels: MultiWindowCaptureLimits.framePixels),
              bytesPerRow > 0, bytesPerRow <= MultiWindowCaptureLimits.framePixels * 4 / sourceHeight else {
            throw MultiWindowCaptureError.pixelLimit
        }
        let canvas = width * height * 4, source = bytesPerRow * sourceHeight, normalized = sourceWidth * sourceHeight * 4
        guard source <= MultiWindowCaptureLimits.ownedRasterBytes - canvas,
              normalized <= MultiWindowCaptureLimits.ownedRasterBytes - canvas - source else {
            throw MultiWindowCaptureError.pixelLimit
        }
        return canvas + source + normalized
    }

    /// Unselected windows may appear/disappear, but selected identities, geometry,
    /// density and relative z-order must still match. A mismatch aborts everything.
    public func validate(frontToBack current: [MultiWindowDescriptor]) throws {
        let expected = placements.reversed().map(\.window), ids = Set(expected.map(\.id))
        let selected = current.filter { ids.contains($0.id) }
        guard selected.count == expected.count, zip(selected, expected).allSatisfy({ pair in pair.0.matchesSource(pair.1) }) else {
            throw MultiWindowCaptureError.changed
        }
    }
}

public struct MultiWindowSelection: Sendable {
    public let windows: [MultiWindowDescriptor]
    public private(set) var selectedIDs: Set<UInt32> = []
    public private(set) var focusedID: UInt32?
    public var selected: [MultiWindowDescriptor] { windows.filter { selectedIDs.contains($0.id) } }
    public init(windows: [MultiWindowDescriptor]) { self.windows = windows; focusedID = windows.first?.id }
    public mutating func toggle(_ id: UInt32) throws {
        guard windows.contains(where: { $0.id == id }) else { throw MultiWindowCaptureError.invalidWindow }
        focusedID = id
        if selectedIDs.remove(id) == nil {
            guard selectedIDs.count < MultiWindowCaptureLimits.windows else { throw MultiWindowCaptureError.windowLimit }
            selectedIDs.insert(id)
        }
    }
    public mutating func focusNext(backwards: Bool = false) {
        guard !windows.isEmpty else { return }
        let index = windows.firstIndex { $0.id == focusedID } ?? 0
        focusedID = windows[(index + (backwards ? windows.count - 1 : 1)) % windows.count].id
    }
    public mutating func focus(at point: CGPoint, cycle: Bool) -> UInt32? {
        let hits = windows.filter { $0.bounds.contains(point) }
        guard !hits.isEmpty else { return nil }
        if cycle, let index = hits.firstIndex(where: { $0.id == focusedID }) { focusedID = hits[(index + 1) % hits.count].id }
        else { focusedID = hits[0].id }
        return focusedID
    }
}
