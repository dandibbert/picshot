import Foundation

public enum PinVisibilityIsolationError: LocalizedError, Equatable, Sendable {
    case invalidSelection, invalidContext, inactive, invalidCreatedPins, capacityExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidSelection: return "请选择当前组内仍可用的贴图；本次未更改显示状态。"
        case .invalidContext: return "贴图分组或显示状态已更改，请重新选择；本次未更改显示状态。"
        case .inactive: return "当前没有临时显示隔离。"
        case .invalidCreatedPins: return "新增贴图的显示状态已更改；本次未更改临时显示隔离。"
        case .capacityExceeded: return "临时显示隔离最多支持 20 个已加载的贴图。"
        }
    }
}

/// A delta for already-live surfaces. Applying it must never create controllers,
/// reopen saved entries, alter membership/content/positions, or write persistence.
public struct PinVisibilityIsolationChange: Equatable, Sendable {
    public let hideIDs: Set<UUID>
    public let revealIDs: Set<UUID>
    public var isNoOp: Bool { hideIDs.isEmpty && revealIDs.isEmpty }

    fileprivate init(hideIDs: Set<UUID> = [], revealIDs: Set<UUID> = []) {
        self.hideIDs = hideIDs
        self.revealIDs = revealIDs
    }
}

/// One transient, bounded visibility baseline, containing UUIDs only. The caller
/// supplies current live/visible UUIDs for `groupID`, and persistent visibility for
/// that same group. Persistent visibility may include saved but unloaded entries;
/// those entries are never admitted merely because they are in that set.
///
/// Compute changes on a copy if applying them may be refused (for example because
/// a surface to hide has an active editor/export), then commit the copy only after
/// admission. An unsuccessful call leaves this value exactly unchanged.
public struct PinVisibilityIsolation: Equatable, Sendable {
    public static let maximumPins = 20
    public private(set) var groupID: UUID?
    /// The first actual visible set plus explicitly registered new pins, pruned as
    /// members close, leave the group, or lose persistent visibility permission.
    public private(set) var restoreIDs: Set<UUID> = []
    /// Only surfaces hidden by this isolation, never unrelated hidden surfaces.
    public private(set) var hiddenIDs: Set<UUID> = []
    /// Remains true even after every member is removed, so ordinary reconciliation
    /// continues suppressing implicit loads until explicit restore/invalidation.
    public var isActive: Bool { groupID != nil }

    public init() {}

    /// First begin captures only actual visible, live IDs. Repeated begin keeps
    /// the original baseline and changes the subset without stacking undo states.
    /// A loaded/reopened history entry must not be passed as a newly created pin.
    public mutating func begin(groupID: UUID, liveIDs: Set<UUID>, visibleIDs: Set<UUID>,
                               persistentlyVisibleIDs: Set<UUID>, selectedIDs: Set<UUID>) throws -> PinVisibilityIsolationChange {
        try validate(groupID: groupID, liveIDs: liveIDs, visibleIDs: visibleIDs,
                     persistentlyVisibleIDs: persistentlyVisibleIDs)
        let permitted = liveIDs.intersection(persistentlyVisibleIDs)
        let eligible = isActive ? restoreIDs.intersection(permitted) : visibleIDs
        let previouslyHidden = hiddenIDs.intersection(eligible)
        guard !selectedIDs.isEmpty,
              selectedIDs.isSubset(of: eligible.intersection(visibleIDs.union(previouslyHidden))) else {
            throw PinVisibilityIsolationError.invalidSelection
        }
        let hide = eligible.intersection(visibleIDs).subtracting(selectedIDs)
        let reveal = previouslyHidden.intersection(selectedIDs).subtracting(visibleIDs)
        self.groupID = groupID
        restoreIDs = eligible
        hiddenIDs = previouslyHidden.union(hide).subtracting(selectedIDs)
        return PinVisibilityIsolationChange(hideIDs: hide, revealIDs: reveal)
    }

    /// Call only for explicit user-created additions that are already visible.
    /// They stay visible now and participate in later isolation/restore. A repeat
    /// registration, an unavailable ID, or an invalid context changes nothing.
    public mutating func registerCreatedPins(groupID: UUID, liveIDs: Set<UUID>, visibleIDs: Set<UUID>,
                                             persistentlyVisibleIDs: Set<UUID>, createdIDs: Set<UUID>) throws {
        try validate(groupID: groupID, liveIDs: liveIDs, visibleIDs: visibleIDs,
                     persistentlyVisibleIDs: persistentlyVisibleIDs)
        guard isActive else { throw PinVisibilityIsolationError.inactive }
        guard !createdIDs.isEmpty, createdIDs.isSubset(of: visibleIDs), createdIDs.isDisjoint(with: restoreIDs) else {
            throw PinVisibilityIsolationError.invalidCreatedPins
        }
        let permitted = liveIDs.intersection(persistentlyVisibleIDs)
        restoreIDs = restoreIDs.intersection(permitted).union(createdIDs)
        hiddenIDs.formIntersection(restoreIDs)
    }

    /// Reconcile lifecycle changes before a later restore. IDs removed here can
    /// never rejoin the baseline merely by becoming live or visible again. An
    /// exhausted baseline retains its group context and implicit-load suppression.
    public mutating func prune(groupID: UUID, liveIDs: Set<UUID>, persistentlyVisibleIDs: Set<UUID>) throws {
        try validate(groupID: groupID, liveIDs: liveIDs, visibleIDs: [],
                     persistentlyVisibleIDs: persistentlyVisibleIDs)
        restoreIDs.formIntersection(liveIDs.intersection(persistentlyVisibleIDs))
        hiddenIDs.formIntersection(restoreIDs)
    }

    /// Call as a pin closes, is deleted, or moves to another group. In particular,
    /// a later reopen of the same saved UUID must not restore this membership.
    /// Removing the final member does not end the active isolation.
    public mutating func remove(id: UUID) {
        restoreIDs.remove(id)
        hiddenIDs.remove(id)
    }

    /// Restore only surfaces this isolation hid and which remain live/permitted
    /// in its group. Selected/new surfaces already visible are not touched.
    /// An empty isolation reveals nothing and ends its temporary group context;
    /// calling restore while inactive is also a safe no-op.
    public mutating func restore(groupID: UUID, liveIDs: Set<UUID>, visibleIDs: Set<UUID>,
                                 persistentlyVisibleIDs: Set<UUID>) throws -> PinVisibilityIsolationChange {
        try validate(groupID: groupID, liveIDs: liveIDs, visibleIDs: visibleIDs,
                     persistentlyVisibleIDs: persistentlyVisibleIDs)
        let reveal = hiddenIDs.intersection(restoreIDs).intersection(liveIDs)
            .intersection(persistentlyVisibleIDs).subtracting(visibleIDs)
        invalidate()
        return PinVisibilityIsolationChange(revealIDs: reveal)
    }

    /// Required for a group switch or explicit group/all hide. This discards
    /// temporary state without revealing anything, including a previously hidden
    /// group. Switching back cannot revive the discarded baseline.
    public mutating func invalidate() {
        groupID = nil
        restoreIDs.removeAll()
        hiddenIDs.removeAll()
    }

    private func validate(groupID: UUID, liveIDs: Set<UUID>, visibleIDs: Set<UUID>,
                          persistentlyVisibleIDs: Set<UUID>) throws {
        guard liveIDs.count <= Self.maximumPins else { throw PinVisibilityIsolationError.capacityExceeded }
        guard self.groupID == nil || self.groupID == groupID,
              visibleIDs.isSubset(of: liveIDs), visibleIDs.isSubset(of: persistentlyVisibleIDs) else {
            throw PinVisibilityIsolationError.invalidContext
        }
    }
}
