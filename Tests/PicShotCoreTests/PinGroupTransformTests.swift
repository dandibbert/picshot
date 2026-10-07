import XCTest
@testable import PicShotCore

final class PinGroupTransformTests: XCTestCase {
    func testThreeVariedFramesMoveScaleWithNegativeOriginsAndSentinelUnchanged() throws {
        let index = fixture(), ids = selection(index)
        let plan = try PinGroupTransformPlan(index: index, selectedIDs: ids, transform: .moveAndScale(dx: -75, dy: 30, scale: 1.5))
        let result = try plan.applying(to: index)
        XCTAssertEqual(result.entries[3], index.entries[3])
        for i in 0..<3 {
            let before = index.entries[i], after = result.entries[i]
            XCTAssertEqual(after.presentation.frame.width, before.presentation.frame.width * 1.5)
            XCTAssertEqual(after.presentation.frame.height, before.presentation.frame.height * 1.5)
            XCTAssertEqual(after.presentation.frame.x, -575 + (before.presentation.frame.x + 500) * 1.5)
            XCTAssertEqual(after.presentation.frame.y, -270 + (before.presentation.frame.y + 300) * 1.5)
            XCTAssertEqual(after.presentation.zoom, before.presentation.zoom)
            XCTAssertEqual(after.presentation.opacity, before.presentation.opacity)
            XCTAssertEqual(after.original, before.original); XCTAssertEqual(after.current, before.current)
        }
        XCTAssertEqual(try plan.applying(to: result, forward: false), index)
        XCTAssertEqual(try plan.applying(to: plan.applying(to: result, forward: false)), result)
    }
    func testEveryAlignmentUsesCollectiveBoundsAndPreservesSizes() throws {
        let index = fixture()
        for alignment in PinGroupAlignment.allCases {
            let plan = try PinGroupTransformPlan(index: index, selectedIDs: selection(index), transform: .align(alignment))
            let result = try plan.applying(to: index), frames = result.entries.prefix(3).map(\.presentation.frame)
            let anchors = frames.map { frame -> Double in
                switch alignment {
                case .left: return frame.x
                case .right: return frame.x + frame.width
                case .top: return frame.y + frame.height
                case .bottom: return frame.y
                case .horizontalCenter: return frame.x + frame.width / 2
                case .verticalCenter: return frame.y + frame.height / 2
                }
            }
            XCTAssertTrue(anchors.allSatisfy { $0 == anchors[0] })
            for i in 0..<3 {
                XCTAssertEqual(frames[i].width, index.entries[i].presentation.frame.width)
                XCTAssertEqual(frames[i].height, index.entries[i].presentation.frame.height)
            }
            XCTAssertEqual(result.entries[3], index.entries[3])
        }
    }
    func testStaleMissingClosedHiddenLockedAndClickThroughRejectWholeGroup() throws {
        let index = fixture()
        let plan = try PinGroupTransformPlan(index: index, selectedIDs: selection(index), transform: .align(.left))
        let mutations: [(inout PinSessionIndex) -> Void] = [
            { $0.entries.remove(at: 1) }, { $0.entries[1].isVisible = false },
            { $0.entries[1].presentation.locked = true }, { $0.entries[1].presentation.clickThrough = true },
            { $0.entries[1].presentation.frame.x += 1 }, { $0.entries[1].presentation.zoom = 3 },
            { $0.allHidden = true }, { $0.groups[0].isHidden = true },
            { $0.entries[1].groupID = UUID() }, { $0.activeGroupID = UUID() }
        ]
        for mutate in mutations {
            var changed = index; mutate(&changed); let before = changed
            XCTAssertThrowsError(try plan.applying(to: changed))
            XCTAssertEqual(changed, before)
        }
        var staleUndo = try plan.applying(to: index); staleUndo.entries[1].presentation.frame.y += 4
        XCTAssertThrowsError(try plan.applying(to: staleUndo, forward: false))
    }
    func testSelectionAndGeometryLimitsRejectRatherThanNormalizeOrDropMembers() throws {
        let index = fixture(), ids = selection(index)
        for bad in [Set<UUID>(), Set([index.entries[0].id]), ids.union([UUID()])] {
            XCTAssertThrowsError(try PinGroupTransformPlan(index: index, selectedIDs: bad, transform: .align(.left)))
        }
        let tooMany = PinSessionIndex(entries: (0..<21).map { _ in entry() })
        XCTAssertThrowsError(try PinGroupTransformPlan(index: tooMany, selectedIDs: Set(tooMany.entries.map(\.id)), transform: .align(.left)))
        for operation in [PinGroupTransform.moveAndScale(dx: .nan, dy: 0, scale: 1), .moveAndScale(dx: 0, dy: .infinity, scale: 1),
                          .moveAndScale(dx: 0, dy: 0, scale: .nan), .moveAndScale(dx: 0, dy: 0, scale: 0.24),
                          .moveAndScale(dx: 0, dy: 0, scale: 4.01), .moveAndScale(dx: 20_000_000, dy: 0, scale: 1)] {
            XCTAssertThrowsError(try PinGroupTransformPlan(index: index, selectedIDs: ids, transform: operation))
        }
        var tiny = index; tiny.entries[0].presentation.frame.width = 40
        XCTAssertThrowsError(try PinGroupTransformPlan(index: tiny, selectedIDs: ids, transform: .moveAndScale(dx: 0, dy: 0, scale: 0.25)))
        var invalid = index; invalid.entries[1].presentation.frame.x = .nan
        XCTAssertThrowsError(try PinGroupTransformPlan(index: invalid, selectedIDs: ids, transform: .align(.left)))
    }
    func testCanonicalTargetsPreserveExactSourcesMetadataSentinelAndReplay() throws {
        var index = fixture()
        // A non-grid source must never be rounded into agreement with a stale store.
        index.entries[0].presentation.frame.x += 0.125
        let proposed = try PinGroupTransformPlan(index: index, selectedIDs: selection(index),
                                                transform: .moveAndScale(dx: 0.375, dy: -0.625, scale: 1.25))
        var calls = 0
        let plan = try proposed.canonicalizingTargetFrames { frame in
            calls += 1
            let x = frame.x.rounded(), y = frame.y.rounded()
            return PinWindowFrame(x: x, y: y, width: (frame.x + frame.width).rounded() - x,
                                  height: (frame.y + frame.height).rounded() - y)
        }
        XCTAssertEqual(calls, 3); XCTAssertEqual(plan.groupID, proposed.groupID); XCTAssertEqual(plan.ids, proposed.ids)
        XCTAssertNotEqual(plan, proposed)
        for (canonical, raw) in zip(plan.changes, proposed.changes) {
            XCTAssertEqual(canonical.before, raw.before)
            var restoredFrame = canonical.after; restoredFrame.frame = raw.after.frame
            XCTAssertEqual(restoredFrame, raw.after, "Only proposed frame geometry may change")
        }
        let committed = try plan.applying(to: index)
        XCTAssertEqual(committed.entries[3], index.entries[3])
        XCTAssertEqual(try plan.applying(to: committed, forward: false), index)
        XCTAssertEqual(try plan.applying(to: plan.applying(to: committed, forward: false)), committed)
        var staleSource = index; staleSource.entries[0].presentation.frame.x += 0.001
        XCTAssertThrowsError(try plan.applying(to: staleSource)) { XCTAssertEqual($0 as? PinGroupTransformError, .stalePresentation) }
        var staleTarget = committed; staleTarget.entries[0].presentation.frame.y += 0.001
        XCTAssertThrowsError(try plan.applying(to: staleTarget, forward: false)) { XCTAssertEqual($0 as? PinGroupTransformError, .stalePresentation) }
        var history = PinGroupTransformHistory(); history.record(plan)
        XCTAssertEqual(history.undoPlans, [plan]); history.didUndo()
        XCTAssertEqual(history.redoPlans, [plan]); history.didRedo()
        XCTAssertEqual(history.undoPlans, [plan])
    }
    func testTargetCanonicalizationRejectsInvalidGeometryAndLeavesNoOpSourcesExact() throws {
        var index = fixture(); index.entries[0].presentation.frame.x += 0.125
        let noOp = try PinGroupTransformPlan(index: index, selectedIDs: selection(index), transform: .moveAndScale(dx: 0, dy: 0, scale: 1))
        XCTAssertEqual(try noOp.canonicalizingTargetFrames { _ in
            XCTFail("An unchanged source is not a proposed target"); throw PinGroupTransformError.invalidGeometry
        }, noOp)
        let proposed = try PinGroupTransformPlan(index: index, selectedIDs: selection(index), transform: .align(.left))
        for frame in [PinWindowFrame(x: .nan), PinWindowFrame(y: .infinity), PinWindowFrame(width: 31), PinWindowFrame(height: 23)] {
            XCTAssertThrowsError(try proposed.canonicalizingTargetFrames { _ in frame }) {
                XCTAssertEqual($0 as? PinGroupTransformError, .invalidGeometry)
            }
        }
        XCTAssertThrowsError(try proposed.canonicalizingTargetFrames { _ in throw PinGroupTransformError.windowConstraint }) {
            XCTAssertEqual($0 as? PinGroupTransformError, .windowConstraint)
        }
        XCTAssertEqual(try proposed.applying(to: index, forward: true).entries[3], index.entries[3])
    }
    func testHistoryIsBoundedAtomicAndContainsOnlyValueSnapshots() throws {
        var index = fixture(), history = PinGroupTransformHistory()
        let ids = selection(index)
        for _ in 0..<100 {
            let plan = try PinGroupTransformPlan(index: index, selectedIDs: ids, transform: .moveAndScale(dx: 1, dy: 2, scale: 1))
            index = try plan.applying(to: index); history.record(plan)
        }
        XCTAssertEqual(history.undoPlans.count, 32)
        for _ in 0..<32 {
            let plan = try XCTUnwrap(history.undoPlans.last)
            index = try plan.applying(to: index, forward: false); history.didUndo()
        }
        XCTAssertTrue(history.undoPlans.isEmpty); XCTAssertEqual(history.redoPlans.count, 32)
        for _ in 0..<32 {
            let plan = try XCTUnwrap(history.redoPlans.last)
            index = try plan.applying(to: index); history.didRedo()
        }
        XCTAssertTrue(history.redoPlans.isEmpty); XCTAssertEqual(history.undoPlans.count, 32)
        history.invalidate(id: index.entries[3].id); XCTAssertEqual(history.undoPlans.count, 32)
        history.invalidate(id: index.entries[0].id); XCTAssertTrue(history.undoPlans.isEmpty)
        let noOp = try PinGroupTransformPlan(index: index, selectedIDs: ids, transform: .moveAndScale(dx: 0, dy: 0, scale: 1))
        history.record(noOp); XCTAssertTrue(history.undoPlans.isEmpty)
    }
    func testRestartPersistsOnlyCommittedFramesAndDoesNotRestoreUndoOrSelection() throws {
        let index = fixture()
        let plan = try PinGroupTransformPlan(index: index, selectedIDs: selection(index), transform: .align(.top))
        let changed = try plan.applying(to: index)
        let restarted = try JSONDecoder().decode(PinSessionIndex.self, from: JSONEncoder().encode(changed)).validated()
        XCTAssertEqual(restarted, changed)
        XCTAssertTrue(PinGroupTransformHistory().undoPlans.isEmpty)
        let uncommitted = try PinGroupTransformPlan(index: restarted, selectedIDs: selection(index), transform: .align(.bottom))
        XCTAssertFalse(uncommitted.isNoOp)
        XCTAssertEqual(try JSONDecoder().decode(PinSessionIndex.self, from: JSONEncoder().encode(changed)), restarted)
    }
    private func selection(_ index: PinSessionIndex) -> Set<UUID> { Set(index.entries.prefix(3).map(\.id)) }
    private func fixture() -> PinSessionIndex {
        let frames = [PinWindowFrame(x: -500, y: -300, width: 320, height: 240),
                      PinWindowFrame(x: -80, y: 30, width: 240, height: 480),
                      PinWindowFrame(x: 250, y: -100, width: 500, height: 180),
                      PinWindowFrame(x: 700, y: 200, width: 90, height: 100)]
        return PinSessionIndex(entries: frames.enumerated().map { i, frame in
            var result = entry(); result.presentation = PinPresentation(frame: frame, opacity: 0.5 + Double(i) / 10, zoom: [nil, 2, 0.5, 1][i]); return result
        })
    }
    private func entry() -> PinSessionEntry {
        PinSessionEntry(original: PinRasterAsset(filename: UUID().uuidString + ".png", width: 32, height: 16, byteCount: 128))
    }
}
