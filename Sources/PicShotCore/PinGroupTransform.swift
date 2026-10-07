import Foundation

public enum PinGroupTransformError: LocalizedError, Equatable {
    case invalidSelection, unavailablePin, stalePresentation, invalidGeometry, windowConstraint
    public var errorDescription: String? {
        switch self {
        case .invalidSelection: return "请选择同组内 2 至 20 个正在显示的贴图。"
        case .unavailablePin: return "所选贴图已关闭、隐藏、锁定、启用鼠标穿透或正在编辑 / 导出。请重新选择；本次未移动任何贴图。"
        case .stalePresentation: return "所选贴图已更改，请重新选择后重试；本次未移动任何贴图。"
        case .invalidGeometry: return "请输入有效的位移和比例；缩放为 25% 至 400%，窗口不能小于最小尺寸。"
        case .windowConstraint: return "系统无法应用此窗口尺寸，已恢复全部原位置。"
        }
    }
}

/// Screen-point geometry only: rotating/editing image pixels never happens here.
public enum PinGroupAlignment: String, CaseIterable, Sendable {
    case left, right, top, bottom, horizontalCenter, verticalCenter
    public var title: String {
        switch self {
        case .left: return "左对齐"
        case .right: return "右对齐"
        case .top: return "顶对齐"
        case .bottom: return "底对齐"
        case .horizontalCenter: return "水平居中"
        case .verticalCenter: return "垂直居中"
        }
    }
}

public enum PinGroupTransform: Equatable, Sendable {
    /// Scale about the collective bottom-left corner, then translate in macOS screen points.
    /// Positive dy moves upward. Zoom, image pixels and rich text size stay unchanged.
    case moveAndScale(dx: Double, dy: Double, scale: Double)
    case align(PinGroupAlignment)
}

public struct PinGroupPresentationChange: Equatable, Sendable {
    public let id: UUID
    public let before: PinPresentation
    public let after: PinPresentation
}

/// Bounded value snapshots contain UUIDs and presentation metadata, never controllers,
/// thumbnails, rendered pixels, asset bytes, or a whole session index.
public struct PinGroupTransformPlan: Equatable, Sendable {
    public static let maximumSelection = 20
    public let groupID: UUID
    public let changes: [PinGroupPresentationChange]
    public var ids: Set<UUID> { Set(changes.map(\.id)) }
    public var isNoOp: Bool { changes.allSatisfy { $0.before == $0.after } }

    public init(index: PinSessionIndex, selectedIDs: Set<UUID>, transform: PinGroupTransform) throws {
        guard (2...Self.maximumSelection).contains(selectedIDs.count) else { throw PinGroupTransformError.invalidSelection }
        let visibleEntries = index.visibleEntries
        guard Set(visibleEntries.map(\.id)).count == visibleEntries.count else { throw PinGroupTransformError.invalidSelection }
        let visible = Dictionary(uniqueKeysWithValues: visibleEntries.map { ($0.id, $0) })
        let entries = try selectedIDs.sorted { $0.uuidString < $1.uuidString }.map { id -> PinSessionEntry in
            guard let entry = visible[id], !entry.presentation.locked, !entry.presentation.clickThrough else {
                throw PinGroupTransformError.unavailablePin
            }
            guard entry.presentation == entry.presentation.normalized() else { throw PinGroupTransformError.invalidGeometry }
            return entry
        }
        let frames = entries.map(\.presentation.frame)
        let minX = frames.map(\.x).min()!, minY = frames.map(\.y).min()!
        let maxX = frames.map { $0.x + $0.width }.max()!, maxY = frames.map { $0.y + $0.height }.max()!
        groupID = index.activeGroupID
        changes = try entries.map { entry in
            var after = entry.presentation
            var frame = after.frame
            switch transform {
            case let .moveAndScale(dx, dy, scale):
                guard dx.isFinite, dy.isFinite, scale.isFinite, (0.25...4).contains(scale) else {
                    throw PinGroupTransformError.invalidGeometry
                }
                frame.x = minX + (frame.x - minX) * scale + dx
                frame.y = minY + (frame.y - minY) * scale + dy
                frame.width *= scale; frame.height *= scale
            case let .align(alignment):
                switch alignment {
                case .left: frame.x = minX
                case .right: frame.x = maxX - frame.width
                case .top: frame.y = maxY - frame.height
                case .bottom: frame.y = minY
                case .horizontalCenter: frame.x = (minX + maxX - frame.width) / 2
                case .verticalCenter: frame.y = (minY + maxY - frame.height) / 2
                }
            }
            guard frame.isValid, frame.width >= 32, frame.height >= 24 else { throw PinGroupTransformError.invalidGeometry }
            after.frame = frame
            return PinGroupPresentationChange(id: entry.id, before: entry.presentation, after: after)
        }
    }

    /// Optimistic, all-or-nothing metadata transaction. No stale member is skipped.
    /// Hidden/archived, moved-group, removed, or independently changed members reject
    /// the complete group, including undo/redo. Unselected entries remain byte-identical.
    public func applying(to index: PinSessionIndex, forward: Bool = true) throws -> PinSessionIndex {
        guard index.activeGroupID == groupID else { throw PinGroupTransformError.unavailablePin }
        let visible = Set(index.visibleEntries.map(\.id))
        var next = index
        for change in changes {
            guard visible.contains(change.id), let position = index.entries.firstIndex(where: { $0.id == change.id }),
                  !index.entries[position].presentation.locked, !index.entries[position].presentation.clickThrough else {
                throw PinGroupTransformError.unavailablePin
            }
            let expected = forward ? change.before : change.after
            guard index.entries[position].presentation == expected else { throw PinGroupTransformError.stalePresentation }
            next.entries[position].presentation = forward ? change.after : change.before
        }
        return next
    }
}

/// At most 32 operations × 20 small metadata pairs. History is deliberately transient;
/// committed frames survive restart, but selection and undo do not.
public struct PinGroupTransformHistory: Sendable {
    public static let maximumOperations = 32
    public private(set) var undoPlans: [PinGroupTransformPlan] = []
    public private(set) var redoPlans: [PinGroupTransformPlan] = []
    public init() {}
    public mutating func record(_ plan: PinGroupTransformPlan) {
        guard !plan.isNoOp else { return }
        undoPlans.append(plan); redoPlans.removeAll()
        if undoPlans.count > Self.maximumOperations { undoPlans.removeFirst(undoPlans.count - Self.maximumOperations) }
    }
    /// Call only after the associated atomic store write succeeds.
    public mutating func didUndo() { if let plan = undoPlans.popLast() { redoPlans.append(plan) } }
    public mutating func didRedo() { if let plan = redoPlans.popLast() { undoPlans.append(plan) } }
    public mutating func invalidate(id: UUID) {
        undoPlans.removeAll { $0.ids.contains(id) }; redoPlans.removeAll { $0.ids.contains(id) }
    }
    public mutating func clear() { undoPlans.removeAll(); redoPlans.removeAll() }
}
