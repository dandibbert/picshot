import XCTest
@testable import PicShotCore

final class ScrollCaptureSequenceTests: XCTestCase {
    func testReverseRevisitAndLeadingExtensionOnlyContributeUnseenPixels() throws {
        for axis in ScrollAxis.allCases {
            let first = UUID(), second = UUID(), third = UUID(), leading = UUID()
            var sequence = try ScrollCaptureSequence(axis: axis, width: 120, height: 120, sourceID: first)
            let b = try XCTUnwrap(sequence.accept(advance: 40, sourceID: second))
            XCTAssertEqual(b.documentStart, 120); XCTAssertEqual(b.sourceStart, 80); XCTAssertEqual(b.length, 40)
            _ = try sequence.accept(advance: 40, sourceID: third)
            let before = sequence.blocks
            XCTAssertNil(try sequence.accept(advance: -60, sourceID: UUID()))
            XCTAssertEqual(sequence.blocks, before); XCTAssertEqual(sequence.viewportOffset, 20)
            let a = try XCTUnwrap(sequence.accept(advance: -50, sourceID: leading))
            XCTAssertEqual(a.documentStart, -30); XCTAssertEqual(a.sourceStart, 0); XCTAssertEqual(a.length, 30)
            XCTAssertEqual(sequence.blocks.map(\.sourceID), [leading, first, second, third])
            XCTAssertEqual(sequence.lowerBound, -30); XCTAssertEqual(sequence.upperBound, 200)
            let layout = try sequence.layout()
            XCTAssertEqual(layout.strips.map(\.outputStart), [0, 30, 150, 190])
            XCTAssertEqual(axis == .vertical ? layout.height : layout.width, 230)
            XCTAssertNil(try sequence.accept(advance: 100, sourceID: UUID()))
            let tail = try XCTUnwrap(sequence.accept(advance: 50, sourceID: UUID()))
            XCTAssertEqual(tail.sourceStart, 80); XCTAssertEqual(tail.length, 40)
        }
    }

    func testMiddleBlockDeletionUndoRedoCancelAndApplyPreserveSources() throws {
        var sequence = try ScrollCaptureSequence(axis: .vertical, width: 80, height: 120, sourceID: UUID())
        _ = try sequence.accept(advance: 40, sourceID: UUID())
        _ = try sequence.accept(advance: 40, sourceID: UUID())
        let originals = sequence.blocks
        var edits = ScrollSequenceEdits()
        edits.begin()
        try edits.delete(originals[1].id, from: sequence)
        XCTAssertEqual(try sequence.layout(removing: edits.removed).strips.map(\.outputStart), [0, 120])
        XCTAssertEqual(try sequence.layout(removing: edits.removed).height, 160)
        XCTAssertEqual(sequence.blocks, originals)
        edits.undo(); XCTAssertTrue(edits.removed.isEmpty); XCTAssertTrue(edits.canRedo)
        edits.redo(); XCTAssertEqual(edits.removed, [originals[1].id])
        edits.cancel(); XCTAssertTrue(edits.removed.isEmpty); XCTAssertFalse(edits.isEditing)
        edits.begin(); try edits.delete(originals[1].id, from: sequence); edits.apply()
        XCTAssertEqual(edits.removed, [originals[1].id]); XCTAssertFalse(edits.canUndo)
        edits.begin(); try edits.delete(originals[0].id, from: sequence)
        edits.cancel(); XCTAssertEqual(edits.removed, [originals[1].id])
        edits.begin(); edits.restoreAll(); XCTAssertTrue(edits.removed.isEmpty)
        edits.undo(); XCTAssertEqual(edits.removed, [originals[1].id])
        edits.apply(); XCTAssertEqual(sequence.blocks, originals)
    }

    func testCannotDeleteLastBlockOrUnknownBlockAndNewEditDropsRedo() throws {
        var sequence = try ScrollCaptureSequence(axis: .horizontal, width: 120, height: 80, sourceID: UUID())
        _ = try sequence.accept(advance: 30, sourceID: UUID())
        var edits = ScrollSequenceEdits(); edits.begin()
        try edits.delete(sequence.blocks[0].id, from: sequence)
        XCTAssertThrowsError(try edits.delete(sequence.blocks[1].id, from: sequence)) {
            XCTAssertEqual($0 as? ScrollSequenceError, .emptySelection)
        }
        let removed = edits.removed
        XCTAssertThrowsError(try edits.delete(UUID(), from: sequence))
        XCTAssertEqual(edits.removed, removed)
        edits.undo(); XCTAssertTrue(edits.canRedo)
        try edits.delete(sequence.blocks[1].id, from: sequence)
        XCTAssertFalse(edits.canRedo)
        XCTAssertEqual(try sequence.layout(removing: edits.removed).width, 120)
        XCTAssertThrowsError(try sequence.layout(removing: [UUID()]))
    }

    func testLimitsAndInvalidMotionLeaveSequenceUnchanged() throws {
        var sequence = try ScrollCaptureSequence(axis: .vertical, width: 80, height: 120, sourceID: UUID())
        for _ in 1..<ScrollCaptureSequence.maximumBlocks { _ = try sequence.accept(advance: 1, sourceID: UUID()) }
        let blocks = sequence.blocks, offset = sequence.viewportOffset
        XCTAssertThrowsError(try sequence.accept(advance: 1, sourceID: UUID())) {
            XCTAssertEqual($0 as? ScrollSequenceError, .blockLimit)
        }
        XCTAssertEqual(sequence.blocks, blocks); XCTAssertEqual(sequence.viewportOffset, offset)
        XCTAssertNil(try sequence.accept(advance: -1, sourceID: UUID()), "A revisit needs no additional block even at the limit")
        for advance in [Int.min, Int.max, 120, -120, 0] {
            XCTAssertThrowsError(try sequence.accept(advance: advance, sourceID: UUID()))
        }
        XCTAssertThrowsError(try ScrollCaptureSequence.validateRaster(width: 32_769, height: 1))
        XCTAssertThrowsError(try ScrollCaptureSequence.validateRaster(width: Int.max, height: Int.max))
        XCTAssertThrowsError(try ScrollCaptureSequence.validateRaster(width: 10_000, height: 6_001))
        XCTAssertNoThrow(try ScrollCaptureSequence.validateRaster(width: 10_000, height: 6_000))
        XCTAssertThrowsError(try ScrollCaptureSequence(axis: .vertical, width: 0, height: 100, sourceID: UUID()))
    }

    func testRasterLimitPreservesPriorCaptureAndCutsDoNotRelaxCaptureLimit() throws {
        var sequence = try ScrollCaptureSequence(axis: .vertical, width: 2_000, height: 12_000, sourceID: UUID())
        _ = try sequence.accept(advance: 10_000, sourceID: UUID())
        let original = sequence.blocks
        XCTAssertThrowsError(try sequence.accept(advance: 9_000, sourceID: UUID())) {
            XCTAssertEqual($0 as? ScrollStitchError, .pixelLimit)
        }
        XCTAssertEqual(sequence.blocks, original); XCTAssertEqual(sequence.viewportOffset, 10_000)
        var edits = ScrollSequenceEdits(); edits.begin(); try edits.delete(original[0].id, from: sequence); edits.apply()
        XCTAssertEqual(try sequence.layout(removing: edits.removed).height, 10_000)
        XCTAssertThrowsError(try sequence.accept(advance: 9_000, sourceID: UUID()))
    }
    private func threeBlocks(axis: ScrollAxis = .vertical) throws -> ScrollCaptureSequence {
        var sequence = try ScrollCaptureSequence(axis: axis, width: 120, height: 120, sourceID: UUID())
        _ = try sequence.accept(advance: 40, sourceID: UUID())
        _ = try sequence.accept(advance: 40, sourceID: UUID())
        return sequence
    }

    private func move(_ advance: Int, sequence: inout ScrollCaptureSequence,
                      edits: inout ScrollSequenceEdits) throws {
        var next = sequence, projected = edits
        _ = try next.accept(advance: advance, sourceID: UUID())
        try projected.captureMoved(sequence: next, advance: advance)
        sequence = next; edits = projected
    }

    func testRangeProjectionSplitsSourcesPreservingIdentityAndExactCropCoordinates() throws {
        for axis in ScrollAxis.allCases {
            let sequence = try threeBlocks(axis: axis), originals = sequence.blocks
            let layout = try sequence.layout(within: 10..<185, excluding: [30..<50, 110..<130, 150..<170])
            XCTAssertEqual(layout.strips.map(\.block.id), [originals[0].id, originals[0].id, originals[1].id, originals[2].id])
            XCTAssertEqual(layout.strips.map(\.block.sourceID), [originals[0].sourceID, originals[0].sourceID,
                                                              originals[1].sourceID, originals[2].sourceID])
            XCTAssertEqual(layout.strips.map(\.block.documentStart), [10, 50, 130, 170])
            XCTAssertEqual(layout.strips.map(\.block.sourceStart), [10, 50, 90, 90])
            XCTAssertEqual(layout.strips.map(\.block.length), [20, 60, 20, 15])
            XCTAssertEqual(layout.strips.map(\.outputStart), [0, 20, 80, 100])
            XCTAssertEqual(axis == .vertical ? layout.height : layout.width, 115)
            XCTAssertEqual(sequence.blocks, originals)
        }
    }

    func testRangeProjectionCoalescesCutsAndSafelyClipsExtremeEndpoints() throws {
        let sequence = try threeBlocks()
        let projection = try sequence.layout(within: Int.min..<Int.max,
                                             excluding: [20..<40, 30..<50, 50..<60, -100 ..< -10, 200..<Int.max])
        XCTAssertEqual(projection.strips.map(\.block.documentStart), [0, 60, 120, 160])
        XCTAssertEqual(projection.height, 160)
        XCTAssertEqual(try sequence.layout(within: Int.min..<Int.max), try sequence.layout())
        XCTAssertThrowsError(try sequence.layout(within: 200..<300)) {
            XCTAssertEqual($0 as? ScrollSequenceError, .emptySelection)
        }
        XCTAssertThrowsError(try sequence.layout(excluding: [Int.min..<Int.max])) {
            XCTAssertEqual($0 as? ScrollSequenceError, .emptySelection)
        }
        XCTAssertThrowsError(try sequence.layout(removing: [UUID()], within: 0..<10)) {
            XCTAssertEqual($0 as? ScrollSequenceError, .unknownBlock)
        }
    }

    func testPositiveDirectionReverseCropForwardRestoreAndViewportFloor() throws {
        for axis in ScrollAxis.allCases {
            var sequence = try ScrollCaptureSequence(axis: axis, width: 120, height: 120, sourceID: UUID())
            var edits = ScrollSequenceEdits()
            XCTAssertFalse(edits.autoCropEnabled)
            try edits.setAutoCropEnabled(true, sequence: sequence)
            try move(40, sequence: &sequence, edits: &edits)
            try move(40, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, 0..<200); XCTAssertEqual(edits.establishedDirection, 1)
            let originals = sequence.blocks
            try move(-30, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, 0..<170); XCTAssertEqual(edits.establishedDirection, 1)
            try move(20, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, 0..<190)
            XCTAssertEqual(sequence.blocks, originals, "Forward restoration reuses retained source coverage")
            try move(-70, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, 0..<120); XCTAssertNil(edits.establishedDirection)
            try move(-20, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, -20..<120); XCTAssertEqual(edits.establishedDirection, -1)
            try move(30, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, 10..<130); XCTAssertNil(edits.establishedDirection)
        }
    }

    func testNegativeDirectionReverseCropForwardRestoreAndViewportFloor() throws {
        for axis in ScrollAxis.allCases {
            var sequence = try ScrollCaptureSequence(axis: axis, width: 120, height: 120, sourceID: UUID())
            var edits = ScrollSequenceEdits()
            try edits.setAutoCropEnabled(true, sequence: sequence)
            try move(-40, sequence: &sequence, edits: &edits)
            try move(-40, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, -80..<120); XCTAssertEqual(edits.establishedDirection, -1)
            let originals = sequence.blocks
            try move(30, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, -50..<120); XCTAssertEqual(edits.establishedDirection, -1)
            try move(-20, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, -70..<120)
            XCTAssertEqual(sequence.blocks, originals)
            try move(70, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, 0..<120); XCTAssertNil(edits.establishedDirection)
            try move(20, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, 0..<140); XCTAssertEqual(edits.establishedDirection, 1)
            try move(-30, sequence: &sequence, edits: &edits)
            XCTAssertEqual(edits.activeRange, -10..<110); XCTAssertNil(edits.establishedDirection)
        }
    }

    func testArbitraryBandDeletionMapsCompactedPixelsAcrossSourcesAndPreviousCuts() throws {
        for axis in ScrollAxis.allCases {
            let sequence = try threeBlocks(axis: axis), originals = sequence.blocks
            var edits = ScrollSequenceEdits(); edits.begin()
            try edits.deleteBand(90..<145, from: sequence)
            XCTAssertEqual(edits.excludedRanges, [90..<145])
            let first = try edits.layout(for: sequence)
            XCTAssertEqual(first.strips.map(\.block.documentStart), [0, 145, 160])
            XCTAssertEqual(first.strips.map(\.block.sourceStart), [0, 105, 80])
            XCTAssertEqual(first.strips.map(\.block.length), [90, 15, 40])
            try edits.deleteBand(80..<110, from: sequence)
            XCTAssertEqual(edits.excludedRanges, [80..<165], "A compact band maps through the existing 55-pixel gap")
            let second = try edits.layout(for: sequence)
            XCTAssertEqual(second.strips.map(\.block.documentStart), [0, 165])
            XCTAssertEqual(second.strips.map(\.block.sourceStart), [0, 85])
            XCTAssertEqual(second.strips.map(\.outputStart), [0, 80])
            XCTAssertEqual(sequence.blocks, originals)
            edits.undo(); XCTAssertEqual(try edits.layout(for: sequence), first)
            edits.redo(); XCTAssertEqual(try edits.layout(for: sequence), second)
            edits.cancel(); XCTAssertEqual(try edits.layout(for: sequence), try sequence.layout())
        }
    }

    func testUserCutsPersistThroughReverseRestorationModeTogglesAndCoverageRecovery() throws {
        var sequence = try ScrollCaptureSequence(axis: .vertical, width: 120, height: 120, sourceID: UUID())
        var edits = ScrollSequenceEdits()
        try edits.setAutoCropEnabled(true, sequence: sequence)
        try move(40, sequence: &sequence, edits: &edits); try move(40, sequence: &sequence, edits: &edits)
        edits.begin(); try edits.deleteBand(130..<150, from: sequence); edits.apply()
        try move(-30, sequence: &sequence, edits: &edits)
        XCTAssertEqual(try edits.layout(for: sequence).height, 150)
        try move(20, sequence: &sequence, edits: &edits)
        XCTAssertEqual(try edits.layout(for: sequence).height, 170)
        XCTAssertEqual(edits.excludedRanges, [130..<150])
        try edits.setAutoCropEnabled(false, sequence: sequence)
        XCTAssertEqual(try edits.layout(for: sequence).height, 180); XCTAssertNil(edits.establishedDirection)
        try edits.setAutoCropEnabled(true, sequence: sequence)
        XCTAssertEqual(edits.activeRange, 0..<200); XCTAssertEqual(edits.excludedRanges, [130..<150])
        try move(1, sequence: &sequence, edits: &edits)
        try move(-11, sequence: &sequence, edits: &edits)
        XCTAssertEqual(edits.activeRange, 0..<180)
        edits.begin(); let before = try edits.layout(for: sequence)
        try edits.restoreCapturedCoverage(sequence: sequence)
        XCTAssertEqual(edits.activeRange, 0..<200); XCTAssertEqual(edits.excludedRanges, [130..<150])
        XCTAssertEqual(try edits.layout(for: sequence).height, 180)
        edits.undo(); XCTAssertEqual(try edits.layout(for: sequence), before)
        edits.redo(); XCTAssertEqual(edits.activeRange, 0..<200)
        edits.cancel(); XCTAssertEqual(try edits.layout(for: sequence), before)
    }

    func testTrimEntryUndoRecoversAutoCroppedEdgeAndCancelRestoresExactBaseline() throws {
        var sequence = try ScrollCaptureSequence(axis: .vertical, width: 120, height: 120, sourceID: UUID())
        var edits = ScrollSequenceEdits()
        try edits.setAutoCropEnabled(true, sequence: sequence)
        try move(40, sequence: &sequence, edits: &edits); try move(40, sequence: &sequence, edits: &edits)
        edits.begin(); try edits.deleteBand(25..<35, from: sequence); edits.apply()
        try move(-30, sequence: &sequence, edits: &edits)
        let baseline = try edits.layout(for: sequence), baselineRange = edits.activeRange
        edits.begin(); XCTAssertTrue(edits.canUndo)
        edits.undo(); XCTAssertEqual(edits.activeRange, 0..<200)
        XCTAssertEqual(edits.excludedRanges, [25..<35])
        try edits.deleteBand(100..<130, from: sequence)
        try edits.setAutoCropEnabled(false, sequence: sequence)
        edits.cancel()
        XCTAssertTrue(edits.autoCropEnabled); XCTAssertEqual(edits.activeRange, baselineRange)
        XCTAssertEqual(edits.establishedDirection, 1); XCTAssertEqual(edits.excludedRanges, [25..<35])
        XCTAssertEqual(try edits.layout(for: sequence), baseline)
        edits.begin(); edits.undo(); XCTAssertEqual(edits.activeRange, 0..<200, "Cancel also restores the entry Undo stack")
    }

    func testExplicitDirectionResetChangesNextCaptureInterpretationWithoutRestoringCuts() throws {
        var sequence = try ScrollCaptureSequence(axis: .vertical, width: 120, height: 120, sourceID: UUID())
        var edits = ScrollSequenceEdits()
        try edits.setAutoCropEnabled(true, sequence: sequence)
        try move(40, sequence: &sequence, edits: &edits); try move(40, sequence: &sequence, edits: &edits)
        edits.begin(); try edits.deleteBand(20..<30, from: sequence); edits.apply()
        edits.resetCaptureDirection()
        XCTAssertNil(edits.establishedDirection); XCTAssertEqual(edits.activeRange, 0..<200)
        try move(-20, sequence: &sequence, edits: &edits)
        XCTAssertEqual(edits.establishedDirection, -1)
        XCTAssertEqual(edits.activeRange, 0..<200, "A restarted negative run extends toward the leading edge instead of reverse-cropping the trailing edge")
        XCTAssertEqual(edits.excludedRanges, [20..<30])
        try edits.captureMoved(sequence: sequence, advance: 0)
        XCTAssertEqual(edits.establishedDirection, -1, "An unchanged sample does not reset capture direction")
    }

    func testProjectionFailuresAreTransactionalWhenViewportWouldContainOnlyUserCuts() throws {
        var sequence = try ScrollCaptureSequence(axis: .vertical, width: 120, height: 120, sourceID: UUID())
        var edits = ScrollSequenceEdits()
        try edits.setAutoCropEnabled(true, sequence: sequence)
        try move(40, sequence: &sequence, edits: &edits); try move(40, sequence: &sequence, edits: &edits)
        edits.begin(); try edits.deleteBand(0..<120, from: sequence); edits.apply()
        let baseline = try edits.layout(for: sequence), blocks = sequence.blocks
        XCTAssertThrowsError(try move(-80, sequence: &sequence, edits: &edits)) {
            XCTAssertEqual($0 as? ScrollSequenceError, .emptySelection)
        }
        XCTAssertEqual(sequence.viewportOffset, 80); XCTAssertEqual(sequence.blocks, blocks)
        XCTAssertEqual(edits.activeRange, 0..<200); XCTAssertEqual(edits.establishedDirection, 1)
        XCTAssertEqual(try edits.layout(for: sequence), baseline)
        for advance in [Int.min, Int.max, 120, -120] {
            XCTAssertThrowsError(try edits.captureMoved(sequence: sequence, advance: advance))
        }
        XCTAssertEqual(try edits.layout(for: sequence), baseline)
    }

    func testDisjointRangeLimitAndInvalidBandsLeavePriorProjectionUntouched() throws {
        let sequence = try ScrollCaptureSequence(axis: .vertical, width: 8, height: 800, sourceID: UUID())
        var edits = ScrollSequenceEdits(); edits.begin()
        for index in 0..<100 { try edits.deleteBand((index + 1)..<(index + 2), from: sequence) }
        XCTAssertEqual(edits.excludedRanges.count, 100)
        let before = try edits.layout(for: sequence), cuts = edits.excludedRanges
        XCTAssertEqual(before.strips.count, 101)
        XCTAssertThrowsError(try edits.deleteBand(101..<102, from: sequence)) {
            XCTAssertEqual($0 as? ScrollSequenceError, .rangeLimit)
        }
        for range in [Int.min..<0, (Int.max - 1)..<Int.max, 0..<0] {
            XCTAssertThrowsError(try edits.deleteBand(range, from: sequence))
        }
        XCTAssertThrowsError(try edits.deleteBand(0..<before.height, from: sequence)) {
            XCTAssertEqual($0 as? ScrollSequenceError, .emptySelection)
        }
        XCTAssertEqual(edits.excludedRanges, cuts); XCTAssertEqual(try edits.layout(for: sequence), before)
        XCTAssertEqual(ScrollCaptureSequence.maximumRenderedStrips, 300)
        XCTAssertThrowsError(try sequence.layout(excluding: (0..<101).map { ($0 * 2)..<($0 * 2 + 1) })) {
            XCTAssertEqual($0 as? ScrollSequenceError, .rangeLimit)
        }
    }

    func testWholeBlockRemovalStillRemovesAllFragmentsAndRestoreAllPreservesActiveRange() throws {
        let sequence = try threeBlocks()
        var edits = ScrollSequenceEdits(); try edits.setAutoCropEnabled(true, sequence: sequence)
        edits.begin(); try edits.deleteBand(20..<40, from: sequence)
        try edits.delete(sequence.blocks[0].id, from: sequence)
        XCTAssertEqual(try edits.layout(for: sequence).height, 80)
        edits.restoreAll()
        XCTAssertTrue(edits.removed.isEmpty); XCTAssertTrue(edits.excludedRanges.isEmpty)
        XCTAssertEqual(edits.activeRange, 0..<200); XCTAssertEqual(try edits.layout(for: sequence).height, 200)
    }

    func testUndoHistoryIsBoundedButCapturedCoverageCanStillBeRestored() throws {
        let sequence = try threeBlocks()
        var edits = ScrollSequenceEdits()
        for index in 0..<150 { try edits.setAutoCropEnabled(index % 2 == 0, sequence: sequence) }
        edits.begin()
        var count = 0
        while edits.canUndo { edits.undo(); count += 1; XCTAssertLessThanOrEqual(count, 128) }
        XCTAssertEqual(count, 128)
        try edits.restoreCapturedCoverage(sequence: sequence)
        XCTAssertEqual(try edits.layout(for: sequence), try sequence.layout())
        edits.cancel()
        XCTAssertFalse(edits.autoCropEnabled)
        edits.begin(); XCTAssertTrue(edits.canUndo, "Cancel restores the bounded baseline history")
    }


    func testProjectedViewportFloorResetsDirectionWithoutChangingExplicitCutsOrCoverage() throws {
        var sequence = try ScrollCaptureSequence(axis: .vertical, width: 120, height: 120, sourceID: UUID())
        var edits = ScrollSequenceEdits()
        try edits.setAutoCropEnabled(true, sequence: sequence)
        try move(40, sequence: &sequence, edits: &edits); try move(40, sequence: &sequence, edits: &edits)
        edits.begin(); try edits.deleteBand(20..<80, from: sequence); edits.apply()
        XCTAssertEqual(try edits.layout(for: sequence).height, 140)
        try move(-20, sequence: &sequence, edits: &edits)
        XCTAssertEqual(edits.activeRange, 0..<180)
        XCTAssertEqual(edits.excludedRanges, [20..<80])
        XCTAssertEqual(try edits.layout(for: sequence).height, 120)
        XCTAssertNil(edits.establishedDirection)
        let layout = try edits.layout(for: sequence)
        try edits.captureMoved(sequence: sequence, advance: 0)
        XCTAssertEqual(try edits.layout(for: sequence), layout)
        XCTAssertNil(edits.establishedDirection)
    }

}
