#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Metadata only. Pixels live in the session directory and are loaded on demand.
public enum PinGroupColor: String, Codable, CaseIterable, Sendable {
    case gray, blue, green, orange, purple, red
}

public struct PinGroup: Codable, Identifiable, Equatable, Sendable {
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public let id: UUID
    public var name: String
    public var color: PinGroupColor
    public var isHidden: Bool
    /// Protected groups count toward every quota, but are never automatically evicted.
    public var isProtected: Bool

    public init(id: UUID = UUID(), name: String, color: PinGroupColor = .blue,
                isHidden: Bool = false, isProtected: Bool = false) {
        self.id = id; self.name = name; self.color = color
        self.isHidden = isHidden; self.isProtected = isProtected
    }
}

public struct PinWindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 80, y: Double = 80, width: Double = 680, height: Double = 480) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && abs(x) <= 10_000_000 && abs(y) <= 10_000_000 &&
            width > 0 && height > 0 && width <= 100_000 && height <= 100_000
    }

    /// Fits the complete pin window onto an available display.
    /// Handles removed displays, negative display origins, and smaller replacement screens.
    public func recovered(in screens: [PinWindowFrame]) -> PinWindowFrame {
        let frame = isValid ? self : PinWindowFrame()
        let validScreens = screens.filter(\.isValid)
        guard !validScreens.isEmpty else { return frame }
        func overlap(_ screen: PinWindowFrame) -> Double {
            max(0, min(frame.x + frame.width, screen.x + screen.width) - max(frame.x, screen.x)) *
                max(0, min(frame.y + frame.height, screen.y + screen.height) - max(frame.y, screen.y))
        }
        func distance(_ screen: PinWindowFrame) -> Double {
            let dx = frame.x + frame.width / 2 - screen.x - screen.width / 2
            let dy = frame.y + frame.height / 2 - screen.y - screen.height / 2
            return dx * dx + dy * dy
        }
        var screen = validScreens[0]
        for candidate in validScreens.dropFirst() {
            if overlap(candidate) > overlap(screen) ||
                (overlap(candidate) == overlap(screen) && distance(candidate) < distance(screen)) { screen = candidate }
        }
        let width = min(max(32, frame.width), screen.width)
        let height = min(max(24, frame.height), screen.height)
        return PinWindowFrame(x: min(max(frame.x, screen.x), screen.x + screen.width - width),
                              y: min(max(frame.y, screen.y), screen.y + screen.height - height),
                              width: width, height: height)
    }
}

public struct PinPresentation: Codable, Equatable, Sendable {
    public var frame: PinWindowFrame
    public var opacity: Double
    /// nil means fit to the window; otherwise this is a pixel-to-point display scale.
    public var zoom: Double?
    public var clickThrough: Bool
    public var locked: Bool
    public init(frame: PinWindowFrame = PinWindowFrame(), opacity: Double = 1, zoom: Double? = nil,
                clickThrough: Bool = false, locked: Bool = false) {
        self.frame = frame; self.opacity = opacity; self.zoom = zoom
        self.clickThrough = clickThrough; self.locked = locked
    }
    public func normalized(screens: [PinWindowFrame]? = nil) -> PinPresentation {
        var result = self
        result.frame = frame.isValid ? frame : PinWindowFrame()
        if let screens { result.frame = result.frame.recovered(in: screens) }
        result.opacity = opacity.isFinite ? min(1, max(0.15, opacity)) : 1
        if let zoom { result.zoom = zoom.isFinite && zoom > 0 ? min(4, max(0.25, zoom)) : nil }
        return result
    }
}

public struct PinRasterAsset: Codable, Equatable, Sendable {
    public let filename: String
    public let width: Int
    public let height: Int
    public let byteCount: Int64
    public let sha256: String?
    public init(filename: String, width: Int, height: Int, byteCount: Int64, sha256: String? = nil) {
        self.filename = filename; self.width = width; self.height = height; self.byteCount = byteCount; self.sha256 = sha256
    }
    public static func isSafeFilename(_ filename: String) -> Bool {
        guard filename.count == 40, filename.hasSuffix(".png") else { return false }
        let stem = String(filename.dropLast(4))
        return UUID(uuidString: stem)?.uuidString.lowercased() == stem.lowercased()
    }
    public var isValid: Bool {
        Self.isSafeFilename(filename) && width > 0 && height > 0 && height <= 32_000_000 &&
            width <= 32_000_000 / height && byteCount > 0 && byteCount <= 536_870_912 &&
            (sha256.map(EditableCaptureAsset.isValidDigest) ?? true)
    }
    public var pixelCount: Int64 {
        guard width > 0, height > 0, Int64(width) <= Int64.max / Int64(height) else { return Int64.max }
        return Int64(width) * Int64(height)
    }
}

public struct PinSessionEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var groupID: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var original: PinRasterAsset
    public var current: PinRasterAsset
    public var presentation: PinPresentation
    public var richContent: PinRichAsset?
    public var editableCapture: EditableCaptureAsset?
    /// false means archived in pin history. Group visibility is a separate concern.
    public var isVisible: Bool
    /// Actual close order. Older archives without this metadata are never guessed from creation/update dates.
    public var archiveSequence: UInt64?
    public init(id: UUID = UUID(), groupID: UUID = PinGroup.defaultID, title: String = "贴图",
                createdAt: Date = Date(), updatedAt: Date = Date(), original: PinRasterAsset,
                current: PinRasterAsset? = nil, presentation: PinPresentation = PinPresentation(),
                isVisible: Bool = true, richContent: PinRichAsset? = nil, archiveSequence: UInt64? = nil, editableCapture: EditableCaptureAsset? = nil) {
        self.id = id; self.groupID = groupID; self.title = title
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.original = original; self.current = current ?? original; self.presentation = presentation
        self.isVisible = isVisible; self.richContent = richContent; self.archiveSequence = archiveSequence; self.editableCapture = editableCapture
    }
    private enum CodingKeys: String, CodingKey {
        case id, groupID, title, createdAt, updatedAt, original, current, presentation, isVisible, richContent, archiveSequence, editableCapture
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  groupID: try values.decode(UUID.self, forKey: .groupID),
                  title: try values.decode(String.self, forKey: .title),
                  createdAt: try values.decode(Date.self, forKey: .createdAt),
                  updatedAt: try values.decode(Date.self, forKey: .updatedAt),
                  original: try values.decode(PinRasterAsset.self, forKey: .original),
                  current: try values.decode(PinRasterAsset.self, forKey: .current),
                  presentation: try values.decode(PinPresentation.self, forKey: .presentation),
                  // Schema-1 sessions before pin history implicitly had every pin open.
                  isVisible: try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
                  richContent: try values.decodeIfPresent(PinRichAsset.self, forKey: .richContent),
                  archiveSequence: try values.decodeIfPresent(UInt64.self, forKey: .archiveSequence),
                  editableCapture: try values.decodeIfPresent(EditableCaptureAsset.self, forKey: .editableCapture))
    }
    public var assetFilenames: [String] { assets.map(\.filename) + (richContent.map { [$0.filename] } ?? []) + (editableCapture.map { [$0.documentFilename] } ?? []) }
    public var storedByteCount: Int64 { assets.reduce(0) { $0 + $1.byteCount } + (richContent?.byteCount ?? 0) + (editableCapture?.documentByteCount ?? 0) }
    public var contentLabel: String {
        switch richContent?.kind { case .text: return "文字 / HTML"; case .files: return "文件引用"; case .color: return "颜色"; case .animation: return "动态图片"; case .latex: return "LaTeX 公式"; case nil: return "图片" }
    }
    public var assets: [PinRasterAsset] {
        var values = original.filename == current.filename ? [original] : [original, current]
        if let editableCapture {
            for raster in editableCapture.rasters where !values.contains(where: { $0.filename == raster.filename }) { values.append(raster.pinAsset) }
        }
        return values
    }
}

public enum PinSessionError: LocalizedError, Equatable {
    case invalidManifest, unsupportedVersion, unsafePath, capacityExceeded, missingGroup, missingPin
    case invalidName, tooManyGroups, cannotDeleteDefault, invalidImage, stalePinContent, invalidGroupOffset
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "贴图会话文件已损坏。原文件未被覆盖，请检查或备份后重新建立会话。"
        case .unsupportedVersion: return "此贴图会话来自较新版本，未修改已有文件。请更新 PicShot 后重试。"
        case .unsafePath: return "贴图会话包含不安全的文件路径，已停止读取。"
        case .capacityExceeded: return "贴图会话达到数量、像素或磁盘上限。请关闭一些贴图、移除保存项，或取消组保护后重试。"
        case .missingGroup: return "找不到此贴图组，请刷新后重试。"
        case .missingPin: return "找不到此贴图，请刷新后重试。"
        case .invalidName: return "请输入非空名称（组名最多 48 字，贴图名称最多 120 字）。"
        case .tooManyGroups: return "最多可创建 32 个贴图组。"
        case .cannotDeleteDefault: return "默认组不能删除。"
        case .invalidImage: return "图片无法保存或读取。每张贴图最多支持 3200 万像素。"
        case .stalePinContent: return "此文字贴图已更新，请重新打开编辑器后重试。"
        case .invalidGroupOffset: return "贴图组每次只能向前或向后移动一位。"
        }
    }
}

public struct PinSessionPolicy: Equatable, Sendable {
    /// Includes open, hidden-group and archived entries; archiving never bypasses quota.
    public let maxPins: Int
    /// Includes original and edited rasters, counted once when they share the same file.
    public let maxPixelCount: Int64
    public let maxDiskBytes: Int64
    public init(maxPins: Int = 20, maxPixelCount: Int64 = 100_000_000, maxDiskBytes: Int64 = 536_870_912) {
        self.maxPins = min(20, max(1, maxPins))
        self.maxPixelCount = min(100_000_000, max(1, maxPixelCount))
        self.maxDiskBytes = min(536_870_912, max(1, maxDiskBytes))
    }
    public func fits(_ entries: [PinSessionEntry]) -> Bool {
        guard entries.count <= maxPins else { return false }
        var pixels: Int64 = 0, bytes: Int64 = 0
        for entry in entries {
            if let rich = entry.richContent {
                guard rich.isValid, rich.byteCount <= maxDiskBytes - bytes, rich.workingPixelCount <= maxPixelCount - pixels else { return false }
                bytes += rich.byteCount; pixels += rich.workingPixelCount
            }
            if let editable = entry.editableCapture {
                guard editable.isValid, editable.documentByteCount <= maxDiskBytes - bytes else { return false }
                bytes += editable.documentByteCount
            }
            for asset in entry.assets {
                guard asset.isValid, asset.pixelCount <= maxPixelCount - pixels,
                      asset.byteCount <= maxDiskBytes - bytes else { return false }
                pixels += asset.pixelCount; bytes += asset.byteCount
            }
        }
        return true
    }

    /// Live pins and protected groups cannot be silently evicted. New/updated pins must fit.
    /// Other pins are retained most-recently-used first, across all groups, including hidden ones.
    public func retaining(_ index: PinSessionIndex, requiring required: Set<UUID> = [],
                          protecting protected: Set<UUID> = []) throws -> [PinSessionEntry] {
        let protectedGroups = Set(index.groups.filter(\.isProtected).map(\.id))
        let ordered = index.entries.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        let mandatory = ordered.filter { required.contains($0.id) || protected.contains($0.id) || protectedGroups.contains($0.groupID) }
        guard fits(mandatory) else { throw PinSessionError.capacityExceeded }
        var kept = mandatory
        let mandatoryIDs = Set(mandatory.map(\.id))
        for entry in ordered where !mandatoryIDs.contains(entry.id) {
            if fits(kept + [entry]) { kept.append(entry) }
        }
        let keptIDs = Set(kept.map(\.id))
        return ordered.filter { keptIDs.contains($0.id) }
    }
}

public struct PinSessionIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 3
    public var version: Int
    public var groups: [PinGroup]
    public var entries: [PinSessionEntry]
    public var activeGroupID: UUID
    public var allHidden: Bool
    public init(groups: [PinGroup] = [PinGroup(id: PinGroup.defaultID, name: "默认", color: .gray)],
                entries: [PinSessionEntry] = [], activeGroupID: UUID = PinGroup.defaultID, allHidden: Bool = false) {
        version = entries.contains(where: { $0.editableCapture != nil }) ? 3 : (entries.contains(where: { $0.richContent != nil }) ? 2 : 1); self.groups = groups; self.entries = entries
        self.activeGroupID = activeGroupID; self.allHidden = allHidden
    }
    public var visibleEntries: [PinSessionEntry] {
        guard !allHidden, let active = groups.first(where: { $0.id == activeGroupID }), !active.isHidden else { return [] }
        return entries.filter { $0.groupID == activeGroupID && $0.isVisible }
    }
    public func entry(id: UUID) -> PinSessionEntry? { entries.first { $0.id == id } }
    public var lastArchivedEntry: PinSessionEntry? {
        entries.filter { !$0.isVisible && $0.archiveSequence != nil }.max { ($0.archiveSequence ?? 0) < ($1.archiveSequence ?? 0) }
    }
    public var nextArchiveSequence: UInt64 { (entries.compactMap(\.archiveSequence).max() ?? 0) + 1 }


    /// Strictly reject unknown schemas, traversal, duplicate identities and unreasonable metadata.
    /// Presentation values are independently recoverable, so normalize them rather than lose a pin.
    public func validated() throws -> PinSessionIndex {
        guard (1...Self.schemaVersion).contains(version) else { throw PinSessionError.unsupportedVersion }
        guard !groups.isEmpty, groups.count <= 32, entries.count <= 256,
              Set(groups.map(\.id)).count == groups.count, Set(entries.map(\.id)).count == entries.count,
              groups.contains(where: { $0.id == PinGroup.defaultID }), groups.contains(where: { $0.id == activeGroupID })
        else { throw PinSessionError.invalidManifest }
        for group in groups {
            guard Self.validName(group.name, limit: 48) else { throw PinSessionError.invalidManifest }
        }
        let groupIDs = Set(groups.map(\.id))
        let sequences = entries.compactMap(\.archiveSequence)
        guard sequences.allSatisfy({ $0 > 0 && $0 < UInt64.max }), Set(sequences).count == sequences.count else { throw PinSessionError.invalidManifest }
        var filenames = Set<String>()
        var result = self
        for i in entries.indices {
            let entry = entries[i]
            guard groupIDs.contains(entry.groupID), Self.validName(entry.title, limit: 120),
                  entry.createdAt.timeIntervalSince1970.isFinite, entry.updatedAt.timeIntervalSince1970.isFinite
            else { throw PinSessionError.invalidManifest }
            if let rich = entry.richContent {
                guard PinRichAsset.isSafeFilename(rich.filename) else { throw PinSessionError.unsafePath }
                guard version >= 2, rich.isValid, filenames.insert(rich.filename.lowercased()).inserted,
                      entry.original == entry.current else { throw PinSessionError.invalidManifest }
                if rich.kind == .latex {
                    guard entry.current.width <= 4_096, entry.current.height <= 4_096,
                          entry.current.pixelCount <= 4_194_304 else { throw PinSessionError.invalidManifest }
                }
            }
            if let editable = entry.editableCapture {
                guard EditableCaptureAsset.isSafeDocumentFilename(editable.documentFilename) else { throw PinSessionError.unsafePath }
                guard version >= 3, entry.richContent == nil, editable.isValid,
                      editable.original.pinAsset == entry.original, editable.current?.pinAsset == entry.current,
                      filenames.insert(editable.documentFilename.lowercased()).inserted else { throw PinSessionError.invalidManifest }
                for raster in editable.rasters {
                    for image in [entry.original, entry.current] where image.filename == raster.filename {
                        guard image == raster.pinAsset else { throw PinSessionError.invalidManifest }
                    }
                }
            }
            if entry.original.filename == entry.current.filename && entry.original != entry.current { throw PinSessionError.invalidManifest }
            for asset in entry.assets {
                guard PinRasterAsset.isSafeFilename(asset.filename) else { throw PinSessionError.unsafePath }
                guard asset.isValid, filenames.insert(asset.filename.lowercased()).inserted else { throw PinSessionError.invalidManifest }
            }
            result.entries[i].presentation = entry.presentation.normalized()
        }
        return result
    }
    public static func validName(_ name: String, limit: Int) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= limit &&
            name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    @discardableResult public mutating func createGroup(name: String, color: PinGroupColor = .blue) throws -> PinGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name, limit: 48) else { throw PinSessionError.invalidName }
        guard groups.count < 32 else { throw PinSessionError.tooManyGroups }
        let group = PinGroup(name: name, color: color); groups.append(group); return group
    }
    public mutating func renameGroup(id: UUID, name: String, color: PinGroupColor? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name, limit: 48) else { throw PinSessionError.invalidName }
        guard let i = groups.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingGroup }
        groups[i].name = name; if let color { groups[i].color = color }
    }
    /// Moves an existing group one slot in the persisted array. The default group
    /// keeps its identity and deletion protection even when it is not the first row.
    public mutating func moveGroup(id: UUID, offset: Int) throws {
        // Validate without assigning the normalized copy: ordering must not alter any
        // presentation, membership, active selection, or visibility metadata.
        _ = try validated()
        guard (-1...1).contains(offset) else { throw PinSessionError.invalidGroupOffset }
        guard let position = groups.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingGroup }
        let destination = position + offset
        guard offset != 0, groups.indices.contains(destination) else { return }
        groups.swapAt(position, destination)
    }
    /// Removing a group never removes its pins or images; entries move to the default group.
    public mutating func deleteGroup(id: UUID) throws {
        guard id != PinGroup.defaultID else { throw PinSessionError.cannotDeleteDefault }
        guard groups.contains(where: { $0.id == id }) else { throw PinSessionError.missingGroup }
        for i in entries.indices where entries[i].groupID == id { entries[i].groupID = PinGroup.defaultID }
        groups.removeAll { $0.id == id }
        if activeGroupID == id { activeGroupID = PinGroup.defaultID }
    }
    public mutating func movePin(id: UUID, to groupID: UUID) throws {
        guard groups.contains(where: { $0.id == groupID }) else { throw PinSessionError.missingGroup }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
        entries[i].groupID = groupID
    }
}
