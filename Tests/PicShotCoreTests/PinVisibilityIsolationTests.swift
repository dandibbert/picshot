import XCTest
@testable import PicShotCore

final class PinVisibilityIsolationTests: XCTestCase {
    private let group = UUID()
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testFirstBeginCapturesOnlyActualVisibleLivePins() throws {
        var state = PinVisibilityIsolation()
        let unloaded = UUID(), archived = UUID(), foreign = UUID()
        let change = try state.begin(groupID: group, liveIDs: [a, b, c], visibleIDs: [a, b],
                                     persistentlyVisibleIDs: [a, b, c, unloaded], selectedIDs: [a])
        XCTAssertEqual(change.hideIDs, [b])
        XCTAssertTrue(change.revealIDs.isEmpty)
        XCTAssertEqual(state.groupID, group)
        XCTAssertEqual(state.restoreIDs, [a, b])
        XCTAssertEqual(state.hiddenIDs, [b])
        for unavailable in [c, unloaded, archived, foreign] {
            assertRejected(.invalidSelection, state: &state) { candidate in
                _ = try candidate.begin(groupID: self.group, liveIDs: [self.a, self.b, self.c], visibleIDs: [self.a],
                                        persistentlyVisibleIDs: [self.a, self.b, self.c, unloaded], selectedIDs: [unavailable])
            }
        }
        let restored = try state.restore(groupID: group, liveIDs: [a, b, c], visibleIDs: [a],
                                         persistentlyVisibleIDs: [a, b, c, unloaded])
        XCTAssertEqual(restored.revealIDs, [b])
        XCTAssertTrue(restored.hideIDs.isEmpty)
        assertEmpty(state)
    }

    func testRepeatedBeginRetainsOriginalBaselineAndReplacesKeptSubset() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        let second = try begin(&state, visible: [a], selected: [b, c])
        XCTAssertEqual(second.hideIDs, [a])
        XCTAssertEqual(second.revealIDs, [b, c])
        XCTAssertEqual(state.restoreIDs, [a, b, c])
        XCTAssertEqual(state.hiddenIDs, [a])
        let repeated = try begin(&state, visible: [b, c], selected: [b, c])
        XCTAssertTrue(repeated.isNoOp)
        XCTAssertEqual(state.restoreIDs, [a, b, c])
        XCTAssertEqual(state.hiddenIDs, [a])
        let restored = try restore(&state, visible: [b, c])
        XCTAssertEqual(restored.revealIDs, [a])
        assertEmpty(state)
        XCTAssertTrue(try restore(&state, visible: [a, b, c]).isNoOp)
    }

    func testSelectingEveryVisiblePinIsNoOpAndStillHasOnlyOneBaseline() throws {
        var state = PinVisibilityIsolation()
        XCTAssertTrue(try begin(&state, visible: [a, b, c], selected: [a, b, c]).isNoOp)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.restoreIDs, [a, b, c])
        XCTAssertTrue(state.hiddenIDs.isEmpty)
        _ = try begin(&state, visible: [a, b, c], selected: [c])
        XCTAssertEqual(try restore(&state, visible: [c]).revealIDs, [a, b])
        assertEmpty(state)
    }

    func testNewlyCreatedPinsStayVisibleAndJoinLaterIsolationAndRestore() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        try state.registerCreatedPins(groupID: group, liveIDs: [a, b, c, d], visibleIDs: [a, d],
                                      persistentlyVisibleIDs: [a, b, c, d], createdIDs: [d])
        XCTAssertEqual(state.restoreIDs, [a, b, c, d])
        XCTAssertEqual(state.hiddenIDs, [b, c])
        let change = try state.begin(groupID: group, liveIDs: [a, b, c, d], visibleIDs: [a, d],
                                     persistentlyVisibleIDs: [a, b, c, d], selectedIDs: [b])
        XCTAssertEqual(change.hideIDs, [a, d])
        XCTAssertEqual(change.revealIDs, [b])
        let restored = try state.restore(groupID: group, liveIDs: [a, b, c, d], visibleIDs: [b],
                                         persistentlyVisibleIDs: [a, b, c, d])
        XCTAssertEqual(restored.revealIDs, [a, c, d])
        assertEmpty(state)
    }

    func testRestoreDoesNotTouchANewPinWhichIsAlreadyVisible() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        try state.registerCreatedPins(groupID: group, liveIDs: [a, b, c, d], visibleIDs: [a, d],
                                      persistentlyVisibleIDs: [a, b, c, d], createdIDs: [d])
        let restored = try state.restore(groupID: group, liveIDs: [a, b, c, d], visibleIDs: [a, d],
                                         persistentlyVisibleIDs: [a, b, c, d])
        XCTAssertEqual(restored.revealIDs, [b, c])
        XCTAssertFalse(restored.revealIDs.contains(d))
    }

    func testReopenedHistoryNeverJoinsTheExistingBaselineImplicitly() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        assertRejected(.invalidSelection, state: &state) { candidate in
            _ = try candidate.begin(groupID: self.group, liveIDs: [self.a, self.b, self.c, self.d], visibleIDs: [self.a, self.d],
                                    persistentlyVisibleIDs: [self.a, self.b, self.c, self.d], selectedIDs: [self.d])
        }
        let change = try state.begin(groupID: group, liveIDs: [a, b, c, d], visibleIDs: [a, d],
                                     persistentlyVisibleIDs: [a, b, c, d], selectedIDs: [b])
        XCTAssertEqual(change.hideIDs, [a])
        XCTAssertEqual(change.revealIDs, [b])
        XCTAssertEqual(state.restoreIDs, [a, b, c])
        XCTAssertEqual(try state.restore(groupID: group, liveIDs: [a, b, c, d], visibleIDs: [b, d],
                                         persistentlyVisibleIDs: [a, b, c, d]).revealIDs, [a, c])
    }

    func testRestoreFiltersClosedDeletedMovedAndPersistentlyHiddenPins() throws {
        var state = PinVisibilityIsolation()
        _ = try state.begin(groupID: group, liveIDs: [a, b, c, d], visibleIDs: [a, b, c, d],
                            persistentlyVisibleIDs: [a, b, c, d], selectedIDs: [a])
        // b no longer has a live controller; c is now archived/moved/hidden.
        let restored = try state.restore(groupID: group, liveIDs: [a, c, d], visibleIDs: [a],
                                         persistentlyVisibleIDs: [a, d])
        XCTAssertEqual(restored.revealIDs, [d])
        assertEmpty(state)
    }

    func testPrunedOrRemovedIDsDoNotReturnWhenSameUUIDBecomesLiveAgain() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        state.remove(id: b)
        try state.prune(groupID: group, liveIDs: [a, c], persistentlyVisibleIDs: [a])
        XCTAssertEqual(state.restoreIDs, [a])
        XCTAssertTrue(state.hiddenIDs.isEmpty)
        assertRejected(.invalidSelection, state: &state) { candidate in
            _ = try self.begin(&candidate, visible: [self.a, self.b, self.c], selected: [self.b])
        }
        XCTAssertTrue(try restore(&state, visible: [a, b, c]).isNoOp)
        assertEmpty(state)
    }

    func testRemovingLastMemberKeepsEmptyIsolationUntilExplicitRestore() throws {
        var state = PinVisibilityIsolation()
        _ = try state.begin(groupID: group, liveIDs: [a], visibleIDs: [a], persistentlyVisibleIDs: [a, c], selectedIDs: [a])
        state.remove(id: a)
        assertActiveWithoutMembers(state)
        state.remove(id: c)
        assertActiveWithoutMembers(state)
        // Saved-but-unloaded c must never become a restoration target.
        XCTAssertTrue(try state.restore(groupID: group, liveIDs: [], visibleIDs: [], persistentlyVisibleIDs: [c]).isNoOp)
        assertEmpty(state)
    }

    func testPruningEveryMemberRetainsSuppressionAcrossRepeatedReconciliation() throws {
        var state = PinVisibilityIsolation()
        _ = try state.begin(groupID: group, liveIDs: [a, b], visibleIDs: [a, b],
                            persistentlyVisibleIDs: [a, b, c], selectedIDs: [a])
        // Both original surfaces have closed/deleted/moved, while c remains saved
        // but unloaded. Repeated reconcile must continue seeing an active state.
        for _ in 0..<3 {
            try state.prune(groupID: group, liveIDs: [], persistentlyVisibleIDs: [c])
            assertActiveWithoutMembers(state)
        }
        // Even if another path later displays c, it cannot silently seed a new
        // baseline while this empty isolation is still active.
        assertRejected(.invalidSelection, state: &state) { candidate in
            _ = try candidate.begin(groupID: self.group, liveIDs: [self.c], visibleIDs: [self.c],
                                    persistentlyVisibleIDs: [self.c], selectedIDs: [self.c])
        }
        try state.prune(groupID: group, liveIDs: [c], persistentlyVisibleIDs: [c])
        assertActiveWithoutMembers(state)
        XCTAssertTrue(try state.restore(groupID: group, liveIDs: [c], visibleIDs: [], persistentlyVisibleIDs: [c]).isNoOp)
        assertEmpty(state)
    }

    func testEmptyIsolationRejectsForeignGroupUntilExplicitInvalidation() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        try state.prune(groupID: group, liveIDs: [], persistentlyVisibleIDs: [])
        assertActiveWithoutMembers(state)
        let other = UUID()
        assertRejected(.invalidContext, state: &state) { candidate in
            _ = try candidate.restore(groupID: other, liveIDs: [self.d], visibleIDs: [self.d], persistentlyVisibleIDs: [self.d])
        }
        state.invalidate()
        assertEmpty(state)
        _ = try state.begin(groupID: other, liveIDs: [d], visibleIDs: [d], persistentlyVisibleIDs: [d], selectedIDs: [d])
        XCTAssertEqual(state.groupID, other)
        XCTAssertEqual(state.restoreIDs, [d])
    }

    func testEmptyIsolationCanAdmitExplicitNewlyCreatedPins() throws {
        var state = PinVisibilityIsolation()
        _ = try state.begin(groupID: group, liveIDs: [a], visibleIDs: [a], persistentlyVisibleIDs: [a, c], selectedIDs: [a])
        state.remove(id: a)
        assertActiveWithoutMembers(state)
        try state.registerCreatedPins(groupID: group, liveIDs: [b, d], visibleIDs: [b, d],
                                      persistentlyVisibleIDs: [b, c, d], createdIDs: [b, d])
        XCTAssertEqual(state.restoreIDs, [b, d])
        XCTAssertTrue(state.hiddenIDs.isEmpty)
        let change = try state.begin(groupID: group, liveIDs: [b, d], visibleIDs: [b, d],
                                     persistentlyVisibleIDs: [b, c, d], selectedIDs: [d])
        XCTAssertEqual(change.hideIDs, [b])
        XCTAssertTrue(change.revealIDs.isEmpty)
        XCTAssertEqual(try state.restore(groupID: group, liveIDs: [b, d], visibleIDs: [d],
                                         persistentlyVisibleIDs: [b, c, d]).revealIDs, [b])
        assertEmpty(state)
    }

    func testPruningOrRemovingWhileInactiveDoesNotStartIsolation() throws {
        var state = PinVisibilityIsolation()
        try state.prune(groupID: group, liveIDs: [], persistentlyVisibleIDs: [c])
        state.remove(id: c)
        assertEmpty(state)
        _ = try state.begin(groupID: group, liveIDs: [d], visibleIDs: [d], persistentlyVisibleIDs: [d], selectedIDs: [d])
        XCTAssertEqual(state.restoreIDs, [d])
    }

    func testInvalidSelectionFailsBeforePruningOrAnyOtherMutation() throws {
        var state = PinVisibilityIsolation()
        assertRejected(.invalidSelection, state: &state) { candidate in
            _ = try self.begin(&candidate, visible: [self.a, self.b, self.c], selected: [])
        }
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        let invalidSelections: [Set<UUID>] = [[], [b], [a, d]]
        for selection in invalidSelections {
            assertRejected(.invalidSelection, state: &state) { candidate in
                _ = try candidate.begin(groupID: self.group, liveIDs: [self.a, self.c], visibleIDs: [self.a],
                                        persistentlyVisibleIDs: [self.a, self.c], selectedIDs: selection)
            }
        }
        XCTAssertEqual(state.restoreIDs, [a, b, c])
        XCTAssertEqual(state.hiddenIDs, [b, c])
    }

    func testInvalidVisibilitySnapshotsFailBeforeMutation() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        assertRejected(.invalidContext, state: &state) { candidate in
            _ = try candidate.begin(groupID: self.group, liveIDs: [self.a], visibleIDs: [self.a, self.b],
                                    persistentlyVisibleIDs: [self.a, self.b], selectedIDs: [self.a])
        }
        assertRejected(.invalidContext, state: &state) { candidate in
            _ = try candidate.restore(groupID: self.group, liveIDs: [self.a, self.b, self.c], visibleIDs: [self.a],
                                      persistentlyVisibleIDs: [self.b, self.c])
        }
    }

    func testPreviouslyVisibleSurfaceHiddenElsewhereIsNotRevealed() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        // a disappeared without this isolation hiding it. It cannot be revealed
        // by a later selection, even if persistent visibility still permits it.
        assertRejected(.invalidSelection, state: &state) { candidate in
            _ = try self.begin(&candidate, visible: [], selected: [self.a])
        }
        XCTAssertEqual(try restore(&state, visible: []).revealIDs, [b, c])
    }

    func testRestoreLeavesAlreadyVisibleSurfacesUntouched() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        // A separate display operation made b visible again.
        XCTAssertEqual(try restore(&state, visible: [a, b]).revealIDs, [c])
    }

    func testForeignGroupCannotBeginRegisterPruneOrRestoreOriginalBaseline() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        let other = UUID()
        assertRejected(.invalidContext, state: &state) { candidate in
            _ = try candidate.begin(groupID: other, liveIDs: [self.d], visibleIDs: [self.d],
                                    persistentlyVisibleIDs: [self.d], selectedIDs: [self.d])
        }
        assertRejected(.invalidContext, state: &state) { candidate in
            try candidate.registerCreatedPins(groupID: other, liveIDs: [self.d], visibleIDs: [self.d],
                                               persistentlyVisibleIDs: [self.d], createdIDs: [self.d])
        }
        assertRejected(.invalidContext, state: &state) { candidate in
            try candidate.prune(groupID: other, liveIDs: [self.d], persistentlyVisibleIDs: [self.d])
        }
        assertRejected(.invalidContext, state: &state) { candidate in
            _ = try candidate.restore(groupID: other, liveIDs: [self.d], visibleIDs: [self.d], persistentlyVisibleIDs: [self.d])
        }
    }

    func testGroupSwitchAndExplicitHideInvalidationCannotLaterRevealOldGroup() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        state.invalidate()
        assertEmpty(state)
        XCTAssertTrue(try restore(&state, visible: []).isNoOp)
        let other = UUID()
        _ = try state.begin(groupID: other, liveIDs: [d], visibleIDs: [d], persistentlyVisibleIDs: [d], selectedIDs: [d])
        XCTAssertEqual(state.restoreIDs, [d])
        state.invalidate()
        XCTAssertTrue(try restore(&state, visible: []).isNoOp)
    }

    func testAllOrGroupPersistentHideAlsoPreventsRevealWithoutLifecyclePrune() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        let restored = try state.restore(groupID: group, liveIDs: [a, b, c], visibleIDs: [], persistentlyVisibleIDs: [])
        XCTAssertTrue(restored.isNoOp)
        assertEmpty(state)
    }

    func testNewPinRegistrationRejectsInactiveDuplicateAndUnavailableIDsAtomically() throws {
        var state = PinVisibilityIsolation()
        assertRejected(.inactive, state: &state) { candidate in
            try candidate.registerCreatedPins(groupID: self.group, liveIDs: [self.d], visibleIDs: [self.d],
                                               persistentlyVisibleIDs: [self.d], createdIDs: [self.d])
        }
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        let invalidCreatedSets: [Set<UUID>] = [[], [a], [b], [d], [a, d]]
        for created in invalidCreatedSets {
            assertRejected(.invalidCreatedPins, state: &state) { candidate in
                try candidate.registerCreatedPins(groupID: self.group, liveIDs: [self.a, self.b, self.c, self.d],
                                                   visibleIDs: [self.a], persistentlyVisibleIDs: [self.a, self.b, self.c, self.d],
                                                   createdIDs: created)
            }
        }
    }

    func testTwentyPinLimitAndCreationAtLimit() throws {
        let ids = (0..<PinVisibilityIsolation.maximumPins).map { _ in UUID() }
        let all = Set(ids), initial = Set(ids.dropLast()), selected: Set<UUID> = [ids[0]]
        var state = PinVisibilityIsolation()
        _ = try state.begin(groupID: group, liveIDs: initial, visibleIDs: initial,
                            persistentlyVisibleIDs: all, selectedIDs: selected)
        try state.registerCreatedPins(groupID: group, liveIDs: all, visibleIDs: selected.union([ids.last!]),
                                      persistentlyVisibleIDs: all, createdIDs: [ids.last!])
        XCTAssertEqual(state.restoreIDs.count, 20)
        XCTAssertEqual(state.hiddenIDs.count, 18)
        let overflow = all.union([UUID()])
        assertRejected(.capacityExceeded, state: &state) { candidate in
            _ = try candidate.begin(groupID: self.group, liveIDs: overflow, visibleIDs: selected,
                                    persistentlyVisibleIDs: overflow, selectedIDs: selected)
        }
        assertRejected(.capacityExceeded, state: &state) { candidate in
            try candidate.registerCreatedPins(groupID: self.group, liveIDs: overflow, visibleIDs: overflow,
                                               persistentlyVisibleIDs: overflow, createdIDs: overflow.subtracting(all))
        }
        assertRejected(.capacityExceeded, state: &state) { candidate in
            try candidate.prune(groupID: self.group, liveIDs: overflow, persistentlyVisibleIDs: overflow)
        }
        assertRejected(.capacityExceeded, state: &state) { candidate in
            _ = try candidate.restore(groupID: self.group, liveIDs: overflow, visibleIDs: selected, persistentlyVisibleIDs: overflow)
        }
        XCTAssertEqual(try state.restore(groupID: group, liveIDs: all, visibleIDs: selected.union([ids.last!]),
                                         persistentlyVisibleIDs: all).revealIDs, initial.subtracting(selected))
        assertEmpty(state)
    }

    func testAnOverLimitInitialBeginDoesNotCaptureAnyState() throws {
        let ids = Set((0...PinVisibilityIsolation.maximumPins).map { _ in UUID() })
        var state = PinVisibilityIsolation()
        assertRejected(.capacityExceeded, state: &state) { candidate in
            _ = try candidate.begin(groupID: self.group, liveIDs: ids, visibleIDs: ids,
                                    persistentlyVisibleIDs: ids, selectedIDs: [ids.first!])
        }
        assertEmpty(state)
    }

    func testCallerCanRejectAPlannedChangeWithoutCommittingItsBaseline() throws {
        var state = PinVisibilityIsolation()
        _ = try begin(&state, visible: [a, b, c], selected: [a])
        let before = state
        var candidate = state
        let change = try begin(&candidate, visible: [a], selected: [b])
        XCTAssertEqual(change.hideIDs, [a])
        XCTAssertNotEqual(candidate, state)
        // Admission notices a's active editor/export and discards candidate.
        XCTAssertEqual(state, before)
        XCTAssertEqual(try restore(&state, visible: [a]).revealIDs, [b, c])
    }

    func testEveryRepeatedSubsetRestoresExactlyOriginalStillLiveBaseline() throws {
        let ids = [a, b, c, d], all = Set(ids)
        for firstMask in 1..<16 {
            for secondMask in 1..<16 {
                let first = Set(ids.enumerated().compactMap { firstMask & (1 << $0.offset) == 0 ? nil : $0.element })
                let second = Set(ids.enumerated().compactMap { secondMask & (1 << $0.offset) == 0 ? nil : $0.element })
                var state = PinVisibilityIsolation()
                let initial = try state.begin(groupID: group, liveIDs: all, visibleIDs: all,
                                               persistentlyVisibleIDs: all, selectedIDs: first)
                XCTAssertEqual(initial.hideIDs, all.subtracting(first))
                let repeated = try state.begin(groupID: group, liveIDs: all, visibleIDs: first,
                                                persistentlyVisibleIDs: all, selectedIDs: second)
                XCTAssertEqual(repeated.hideIDs, first.subtracting(second))
                XCTAssertEqual(repeated.revealIDs, second.subtracting(first))
                XCTAssertTrue(repeated.hideIDs.isDisjoint(with: repeated.revealIDs))
                XCTAssertEqual(first.subtracting(repeated.hideIDs).union(repeated.revealIDs), second)
                XCTAssertEqual(state.restoreIDs, all)
                XCTAssertEqual(state.hiddenIDs, all.subtracting(second))
                let restored = try state.restore(groupID: group, liveIDs: all, visibleIDs: second, persistentlyVisibleIDs: all)
                XCTAssertEqual(second.union(restored.revealIDs), all)
                XCTAssertTrue(restored.hideIDs.isEmpty)
                assertEmpty(state)
            }
        }
    }

    private func begin(_ state: inout PinVisibilityIsolation, visible: Set<UUID>, selected: Set<UUID>) throws -> PinVisibilityIsolationChange {
        try state.begin(groupID: group, liveIDs: [a, b, c], visibleIDs: visible,
                        persistentlyVisibleIDs: [a, b, c], selectedIDs: selected)
    }

    private func restore(_ state: inout PinVisibilityIsolation, visible: Set<UUID>) throws -> PinVisibilityIsolationChange {
        try state.restore(groupID: group, liveIDs: [a, b, c], visibleIDs: visible, persistentlyVisibleIDs: [a, b, c])
    }

    private func assertRejected(_ expected: PinVisibilityIsolationError, state: inout PinVisibilityIsolation,
                                file: StaticString = #filePath, line: UInt = #line,
                                _ operation: (inout PinVisibilityIsolation) throws -> Void) {
        let before = state
        XCTAssertThrowsError(try operation(&state), file: file, line: line) { error in
            XCTAssertEqual(error as? PinVisibilityIsolationError, expected, file: file, line: line)
        }
        XCTAssertEqual(state, before, file: file, line: line)
    }

    private func assertEmpty(_ state: PinVisibilityIsolation, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(state.isActive, file: file, line: line)
        XCTAssertNil(state.groupID, file: file, line: line)
        XCTAssertTrue(state.restoreIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(state.hiddenIDs.isEmpty, file: file, line: line)
    }

    private func assertActiveWithoutMembers(_ state: PinVisibilityIsolation, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.isActive, file: file, line: line)
        XCTAssertEqual(state.groupID, group, file: file, line: line)
        XCTAssertTrue(state.restoreIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(state.hiddenIDs.isEmpty, file: file, line: line)
    }
}
