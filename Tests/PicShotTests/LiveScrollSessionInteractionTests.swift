import XCTest
import AppKit
import PicShotCore
@testable import PicShot

/// Owned native controls and synthetic acquisition only: no capture permissions,
/// global input, clipboard writes, or real-time waits for the capture budget.
@MainActor
final class LiveScrollSessionInteractionTests: XCTestCase {
    func testRealSourceLimitIsTerminalKeepsAllOutputRoutesAndLastExactPixels() async throws {
        try await withSession(seed: Self.sourceLimitImage(origin: 0), allOutputRoutes: true) { session, source, _, output, clock in
            let toolbar = try Self.toolbar(session)
            clock.now += 37
            try await Self.fillSourceLimit(session, source: source)
            let accepted = session.stateForVerification
            let document = await session.documentSnapshotForResourceVerification()
            let before = try XCTUnwrap(document)
            let preview = try XCTUnwrap(Self.thumbnail(session).image)
            source.offer(try Self.sourceLimitImage(origin: accepted.viewportOffset + 1))
            try await Self.waitUntil { session.captureLimitReachedForVerification && source.completedDrains == 1 }
            XCTAssertEqual(session.snapshotForVerification.status, "已满100段，请完成")
            XCTAssertEqual(session.snapshotForVerification.statusKind, .paused)
            try Self.assertTerminalControls(session)
            try Self.assertAllOutputRoutes(session)
            try Self.assertStatusVisibleAndRetainEvidence(session, phase: "scroll-state-source-limit")

            let sampled = session.sampledFramesForVerification
            for _ in 0..<3 { try Self.dispatchStaleAcquisitionActions(session) }
            source.offer(try Self.sourceLimitImage(origin: accepted.viewportOffset + 2))
            clock.now += 10_000
            XCTAssertEqual(source.pauseCalls, 1); XCTAssertEqual(source.resumeCalls, 0); XCTAssertEqual(source.moveCalls, 0)
            XCTAssertEqual(session.sampledFramesForVerification, sampled)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 37)
            XCTAssertEqual(session.stateForVerification.acceptedObservations, 100)
            XCTAssertEqual(session.stateForVerification.committedSources, 100)
            XCTAssertEqual(session.stateForVerification.viewportOffset, accepted.viewportOffset)
            XCTAssertEqual(session.snapshotForVerification.axis, .vertical)
            XCTAssertEqual(session.snapshotForVerification.status, "已满100段，请完成")
            XCTAssertTrue(try Self.thumbnail(session).image === preview)
            let after = await session.documentSnapshotForResourceVerification()
            XCTAssertEqual(after, before)

            // Opening either existing choice route must remain possible at the
            // acquisition cap. Cancelling the choice does not reopen capture.
            try Self.dispatchMenu(session, "imageChain")
            let chainChoice = try XCTUnwrap(session.chainChoiceAlertForVerification)
            chainChoice.cancel()
            try await Self.waitUntil { !session.snapshotForVerification.busy }
            try Self.dispatchMenu(session, "textScript")
            let textChoice = try XCTUnwrap(session.textChoiceAlertForVerification)
            textChoice.cancel()
            try await Self.waitUntil { !session.snapshotForVerification.busy }
            try Self.assertAllOutputRoutes(session)

            // Checked recipients reject delivery without discarding the spool.
            // Save cancellation must also leave the same terminal acquisition.
            output.rejectDelivery = true
            try PortableSettingsUIPreviewFixture.click(toolbar.copyButton)
            try await Self.waitUntil { output.copies == 1 && !session.snapshotForVerification.busy }
            try Self.assertTerminalControls(session)
            try Self.dispatchMenu(session, "pin")
            try await Self.waitUntil { output.pins == 1 && !session.snapshotForVerification.busy }
            try Self.assertTerminalControls(session)
            try Self.dispatchMenu(session, "quickSave")
            try await Self.waitUntil { output.saves == 1 && !session.snapshotForVerification.busy }
            try Self.assertTerminalControls(session)
            try Self.assertAllOutputRoutes(session)
            for _ in 0..<3 { try Self.dispatchStaleAcquisitionActions(session) }
            XCTAssertEqual(source.resumeCalls, 0); XCTAssertEqual(source.moveCalls, 0)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 37)
            XCTAssertEqual(session.sampledFramesForVerification, sampled)
            XCTAssertTrue(session.captureLimitReachedForVerification)

            output.rejectDelivery = false
            try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
            try await Self.waitUntil { session.isClosedForVerification }
            let expected = try Self.sourceLimitImage(origin: 0, length: accepted.viewportOffset + 200)
            let actual = try XCTUnwrap(output.image)
            XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(try Self.pixels(actual), try Self.pixels(expected))
            XCTAssertEqual(output.finishes, 1)
            XCTAssertEqual(output.copies, 1); XCTAssertEqual(output.pins, 1); XCTAssertEqual(output.saves, 1)
            XCTAssertEqual(output.automaticEvents, 0)
        }
    }

    func testRealSourceLimitHeldDrainRejectsStaleAcquisitionAndCancelCannotResurrect() async throws {
        try await withSession(seed: Self.sourceLimitImage(origin: 0)) { session, source, _, output, clock in
            try await Self.fillSourceLimit(session, source: source)
            let accepted = session.stateForVerification
            let controls = try XCTUnwrap(session.controlsForVerification)
            var closes = 0
            session.onClose = { closes += 1 }
            clock.now += 19
            source.holdDrain = true
            source.offer(try Self.sourceLimitImage(origin: accepted.viewportOffset + 1))
            try await Self.waitUntil { source.hasPendingDrain }
            XCTAssertTrue(session.captureLimitReachedForVerification)
            for _ in 0..<3 { try Self.dispatchStaleAcquisitionActions(session) }
            XCTAssertEqual(source.pauseCalls, 1); XCTAssertEqual(source.resumeCalls, 0); XCTAssertEqual(source.moveCalls, 0)
            clock.now += 9_000
            XCTAssertEqual(session.activeCaptureDurationForVerification, 19)
            let beforeClose = session.snapshotForVerification
            session.cancel()
            XCTAssertTrue(controls.isRetired); XCTAssertNil(session.controlsForVerification)
            XCTAssertFalse(session.isClosedForVerification); XCTAssertEqual(closes, 0)
            source.releaseDrain(); source.releaseDrain()
            try await Self.waitUntil { session.isClosedForVerification }
            XCTAssertEqual(source.completedDrains, 1); XCTAssertEqual(source.stopCalls, 1)
            XCTAssertEqual(source.resumeCalls, 0); XCTAssertEqual(source.moveCalls, 0)
            XCTAssertEqual(session.snapshotForVerification, beforeClose)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 19)
            XCTAssertEqual(output.finishes + output.copies, 0); XCTAssertEqual(closes, 1)
        }
    }

    func testOrdinaryDocumentFailureRemainsRecoverableAndDoesNotConsumeTerminalLimit() async throws {
        try await withSession { session, source, seed, output, clock in
            source.nextFailure = LiveScrollDocument.Failure.writeFailed
            clock.now += 11
            source.offer(seed)
            try await Self.waitUntil { session.snapshotForVerification.statusKind == .error }
            XCTAssertFalse(session.captureLimitReachedForVerification)
            XCTAssertTrue(session.snapshotForVerification.canPause)
            XCTAssertTrue(session.snapshotForVerification.canMoveRegion)
            XCTAssertTrue(session.snapshotForVerification.canChangeAxis)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 11)
            clock.now += 5_000
            let toolbar = try Self.toolbar(session)
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { !session.snapshotForVerification.paused && !session.snapshotForVerification.busy }
            XCTAssertEqual(source.resumeCalls, 1)
            XCTAssertFalse(session.captureLimitReachedForVerification)
            clock.now += 2
            XCTAssertEqual(session.activeCaptureDurationForVerification, 13)
            try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
            try await Self.waitUntil { session.isClosedForVerification }
            XCTAssertEqual(output.finishes, 1)
            XCTAssertEqual(try Self.pixels(XCTUnwrap(output.image)), try Self.pixels(seed))
        }
    }

    func testExplicitPauseSurvivesSeededAxisChangeUntilOneExplicitContinueAndFinishPixelsStayExact() async throws {
        for continueBeforeFinish in [false, true] {
            try await withSession { session, source, seed, output, clock in
                let toolbar = try Self.toolbar(session)
                clock.now += 23
                try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
                try await Self.waitUntil { session.snapshotForVerification.paused && !session.snapshotForVerification.busy }
                clock.now += 5_000
                try Self.dispatchMenu(session, "axis.horizontal")
                try await Self.waitUntil { session.snapshotForVerification.axis == .horizontal && !session.snapshotForVerification.busy }
                let paused = session.snapshotForVerification
                XCTAssertTrue(paused.paused); XCTAssertEqual(paused.statusKind, .paused)
                XCTAssertEqual(paused.status, "方向已切换，仍暂停")
                XCTAssertFalse(paused.autoScrolling); XCTAssertFalse(paused.canAutoScroll)
                XCTAssertFalse(paused.previewPositionVerified)
                XCTAssertTrue(paused.canFinish); XCTAssertTrue(paused.canCopy); XCTAssertTrue(paused.canPause)
                XCTAssertEqual(paused.acceptedFrames, 1)
                XCTAssertEqual(source.resumeCalls, 0)
                XCTAssertEqual(source.operations, ["pause", "pause"])
                XCTAssertEqual(toolbar.pauseButton.accessibilityLabel(), "继续捕获")
                XCTAssertEqual(session.activeCaptureDurationForVerification, 23)
                clock.now += 8_000
                XCTAssertEqual(session.activeCaptureDurationForVerification, 23)
                if !continueBeforeFinish {
                    try Self.assertStatusVisibleAndRetainEvidence(session, phase: "scroll-state-paused-axis")
                } else {
                    // Repeated stale Continue dispatch during its held resume
                    // cannot start a second resume or advance the active clock.
                    source.holdResume = true
                    try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
                    try await Self.waitUntil { source.hasPendingResume }
                    for _ in 0..<3 { try Self.dispatchButton(toolbar.pauseButton) }
                    clock.now += 9_000
                    XCTAssertEqual(source.resumeCalls, 1)
                    XCTAssertEqual(session.activeCaptureDurationForVerification, 23)
                    source.releaseResume(); source.releaseResume()
                    try await Self.waitUntil { !session.snapshotForVerification.paused && !session.snapshotForVerification.busy }
                    XCTAssertEqual(source.resumeCalls, 1)
                    XCTAssertEqual(source.completedResumes, 1)
                    XCTAssertFalse(session.snapshotForVerification.autoScrolling)
                    clock.now += 7
                    XCTAssertEqual(session.activeCaptureDurationForVerification, 30)
                }
                try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
                try await Self.waitUntil { session.isClosedForVerification }
                XCTAssertEqual(output.finishes, 1); XCTAssertEqual(output.copies, 0)
                XCTAssertEqual(try Self.pixels(XCTUnwrap(output.image)), try Self.pixels(seed))
            }
        }
    }

    func testActiveSeededAxisChangeResumesOnceAndMultiFrameAxisChangeIsRejected() async throws {
        try await withSession { session, source, seed, output, clock in
            clock.now += 31
            source.holdResume = true
            try Self.dispatchMenu(session, "axis.horizontal")
            try await Self.waitUntil { source.hasPendingResume }
            clock.now += 8_000
            XCTAssertEqual(session.activeCaptureDurationForVerification, 31)
            try Self.dispatchMenu(session, "axis.horizontal", requireEnabled: false)
            source.releaseResume(); source.releaseResume()
            try await Self.waitUntil { session.snapshotForVerification.axis == .horizontal && !session.snapshotForVerification.busy }
            XCTAssertFalse(session.snapshotForVerification.paused)
            XCTAssertEqual(source.operations, ["pause", "resume"])
            XCTAssertEqual(source.resumeCalls, 1); XCTAssertEqual(source.completedResumes, 1)
            clock.now += 3
            XCTAssertEqual(session.activeCaptureDurationForVerification, 34)
            try PortableSettingsUIPreviewFixture.click(Self.toolbar(session).finishButton)
            try await Self.waitUntil { session.isClosedForVerification }
            XCTAssertEqual(output.finishes, 1)
            XCTAssertEqual(try Self.pixels(XCTUnwrap(output.image)), try Self.pixels(seed))
        }
        try await withSession(seed: Self.sourceLimitImage(origin: 0)) { session, source, _, output, _ in
            source.offer(try Self.sourceLimitImage(origin: 24))
            try await Self.waitUntil { session.snapshotForVerification.acceptedFrames == 2 }
            let before = session.snapshotForVerification
            XCTAssertFalse(before.canChangeAxis)
            for _ in 0..<3 { try Self.dispatchMenu(session, "axis.horizontal", requireEnabled: false) }
            XCTAssertEqual(session.snapshotForVerification, before)
            XCTAssertEqual(source.pauseCalls, 0); XCTAssertEqual(source.resumeCalls, 0)
            try PortableSettingsUIPreviewFixture.click(Self.toolbar(session).finishButton)
            try await Self.waitUntil { session.isClosedForVerification }
            XCTAssertEqual(try Self.pixels(XCTUnwrap(output.image)), try Self.pixels(Self.sourceLimitImage(origin: 0, length: 224)))
        }
    }

    func testCancelDuringAxisDrainOrHeldResumeCannotResurrectSeededSession() async throws {
        for boundary in ["paused-drain", "active-drain", "active-resume"] {
            try await withSession { session, source, _, output, clock in
                var closes = 0
                session.onClose = { closes += 1 }
                clock.now += 41
                if boundary == "paused-drain" {
                    try PortableSettingsUIPreviewFixture.click(Self.toolbar(session).pauseButton)
                    try await Self.waitUntil { session.snapshotForVerification.paused && !session.snapshotForVerification.busy }
                }
                source.holdDrain = boundary != "active-resume"
                source.holdResume = boundary == "active-resume"
                try Self.dispatchMenu(session, "axis.horizontal")
                try await Self.waitUntil { source.hasPendingDrain || source.hasPendingResume }
                let beforeClose = session.snapshotForVerification
                let controls = try XCTUnwrap(session.controlsForVerification)
                session.cancel()
                XCTAssertTrue(controls.isRetired); XCTAssertNil(session.controlsForVerification)
                XCTAssertFalse(session.isClosedForVerification); XCTAssertEqual(closes, 0)
                clock.now += 7_000
                source.releaseDrain(); source.releaseDrain(); source.releaseResume(); source.releaseResume()
                try await Self.waitUntil { session.isClosedForVerification }
                XCTAssertEqual(source.resumeCalls, boundary == "active-resume" ? 1 : 0)
                XCTAssertEqual(source.stopCalls, 1)
                XCTAssertEqual(session.snapshotForVerification, beforeClose)
                XCTAssertEqual(session.activeCaptureDurationForVerification, 41)
                XCTAssertEqual(output.finishes + output.copies, 0); XCTAssertEqual(closes, 1)
            }
        }
    }

    func testLongPauseExcludesDrainAndIdleTimeAndExactActiveLimitKeepsCopyAndFinish() async throws {
        try await withSession { session, source, seed, output, clock in
            let toolbar = try Self.toolbar(session)
            clock.now += 179
            source.holdDrain = true
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { source.hasPendingDrain }
            clock.now += 4_000
            XCTAssertEqual(session.activeCaptureDurationForVerification, 179)
            source.releaseDrain()
            try await Self.waitUntil { !session.snapshotForVerification.busy }
            clock.now += 8_000
            XCTAssertEqual(session.activeCaptureDurationForVerification, 179)

            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { !session.snapshotForVerification.paused && !session.snapshotForVerification.busy }
            XCTAssertEqual(source.resumeCalls, 1)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 179)
            XCTAssertFalse(session.captureLimitReachedForVerification)
            try await Self.waitUntil { source.mailbox.counters.waitingReaders == 1 }
            clock.now += 1
            source.offer(seed) // Wake the normal sampling loop, without waiting 180 seconds.
            try await Self.waitUntil { session.captureLimitReachedForVerification && source.pauseCalls == 2 }
            try await Self.waitUntil { session.snapshotForVerification.statusKind == .paused }
            try Self.assertTerminalControls(session)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 180)
            clock.now += 9_000
            XCTAssertEqual(session.activeCaptureDurationForVerification, 180)
            toolbar.pauseButton.performClick(nil)
            XCTAssertEqual(source.resumeCalls, 1)

            try PortableSettingsUIPreviewFixture.click(toolbar.copyButton)
            try await Self.waitUntil { session.isClosedForVerification }
            XCTAssertEqual(output.copies, 1); XCTAssertEqual(output.finishes, 0)
            XCTAssertEqual(try Self.pixels(XCTUnwrap(output.image)), try Self.pixels(seed))
        }
    }

    func testContinueAtExactly180ActiveSecondsCannotResumeSource() async throws {
        try await withSession { session, source, _, _, clock in
            let toolbar = try Self.toolbar(session)
            clock.now += 180
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { session.snapshotForVerification.paused && !session.snapshotForVerification.busy }
            clock.now += 6_000
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            XCTAssertTrue(session.captureLimitReachedForVerification)
            XCTAssertEqual(source.resumeCalls, 0)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 180)
            try Self.assertTerminalControls(session)
        }
    }

    func testEarlyHandleReleaseAppliesOnceAfterDrainAndExcludesMovementTime() async throws {
        try await withSession { session, source, _, output, clock in
            let handle = try Self.handle(session)
            let original = source.region
            let preview = try XCTUnwrap(Self.thumbnail(session).image)
            let start = try Self.handleCenter(handle)
            clock.now += 17
            source.holdDrain = true
            try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
            try await Self.waitUntil { source.hasPendingDrain }
            try Self.pointer(.leftMouseDragged, handle: handle, screenPoint: start.offsetBy(dx: 20, dy: -35))
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start)
            clock.now += 10_000
            XCTAssertFalse(handle.isDragging)
            XCTAssertTrue(session.snapshotForVerification.busy)
            XCTAssertFalse(session.snapshotForVerification.previewPositionVerified)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 17)
            XCTAssertEqual(source.region, original)
            XCTAssertEqual(source.moveCalls, 0); XCTAssertEqual(source.resumeCalls, 0)
            XCTAssertTrue(try Self.thumbnail(session).image === preview)

            source.releaseDrain(); source.releaseDrain()
            try await Self.waitUntil { !session.snapshotForVerification.busy && !session.snapshotForVerification.paused }
            XCTAssertEqual(source.region, original.offsetBy(dx: 0, dy: 60))
            XCTAssertEqual(source.operations, ["pause", "move", "resume"])
            XCTAssertEqual(session.activeCaptureDurationForVerification, 17)
            XCTAssertFalse(session.snapshotForVerification.previewPositionVerified)
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 80, dy: -90))
            handle.cancelOperation(nil)
            XCTAssertEqual(source.moveCalls, 1); XCTAssertEqual(source.resumeCalls, 1)
            XCTAssertEqual(output.finishes + output.copies, 0)
        }
    }

    func testCancelledHandleRollsBackAndRepeatedCompletionCannotApplyOrResumeTwice() async throws {
        try await withSession { session, source, _, _, _ in
            let controls = try XCTUnwrap(session.controlsForVerification)
            let handle = try Self.handle(session)
            let original = source.region
            let outline = controls.outlineWindow?.frame
            let start = try Self.handleCenter(handle)
            let staleEnd = handle.end
            source.holdDrain = true
            try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
            try await Self.waitUntil { source.hasPendingDrain }
            try Self.pointer(.leftMouseDragged, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
            XCTAssertNotEqual(controls.outlineWindow?.frame, outline)
            handle.cancelOperation(nil)
            XCTAssertEqual(controls.outlineWindow?.frame, outline)
            handle.cancelOperation(nil); staleEnd?(start)
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
            XCTAssertEqual(source.region, original)
            XCTAssertEqual(source.moveCalls, 0); XCTAssertEqual(source.resumeCalls, 0)

            source.releaseDrain()
            try await Self.waitUntil { !session.snapshotForVerification.busy && !session.snapshotForVerification.paused }
            staleEnd?(start); staleEnd?(nil); source.releaseDrain()
            XCTAssertEqual(source.operations, ["pause", "resume"])
            XCTAssertEqual(source.region, original)
            XCTAssertEqual(controls.outlineWindow?.frame, outline)
            XCTAssertTrue(session.snapshotForVerification.canFinish)
            XCTAssertFalse(session.snapshotForVerification.previewPositionVerified)
        }
    }

    func testCloseDuringHeldDragDrainMakesLateCompletionInert() async throws {
        try await withSession { session, source, _, output, _ in
            var closes = 0
            session.onClose = { closes += 1 }
            let controls = try XCTUnwrap(session.controlsForVerification)
            let handle = try Self.handle(session)
            let start = try Self.handleCenter(handle)
            let original = source.region
            let staleEnd = handle.end
            source.holdDrain = true
            try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
            try await Self.waitUntil { source.hasPendingDrain }
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
            let beforeClose = session.snapshotForVerification
            session.cancel()
            XCTAssertTrue(controls.isRetired)
            XCTAssertNil(session.controlsForVerification)
            XCTAssertFalse(session.isClosedForVerification)
            XCTAssertEqual(closes, 0)
            XCTAssertEqual(output.finishes + output.copies, 0)
            source.releaseDrain(); source.releaseDrain()
            try await Self.waitUntil { source.completedDrains == 1 && session.isClosedForVerification }
            XCTAssertEqual(closes, 1)
            staleEnd?(start); handle.cancelOperation(nil)
            XCTAssertEqual(source.region, original)
            XCTAssertEqual(source.moveCalls, 0); XCTAssertEqual(source.resumeCalls, 0)
            XCTAssertEqual(source.stopCalls, 1)
            XCTAssertEqual(output.finishes + output.copies, 0)
            XCTAssertEqual(session.snapshotForVerification, beforeClose)
            XCTAssertNil(session.controlsForVerification)
            XCTAssertNil(handle.begin); XCTAssertNil(handle.move); XCTAssertNil(handle.end)
            XCTAssertEqual(closes, 1)
        }
    }

    func testCloseDuringHeldResumeCannotPublishAfterMoveOrRejectedMoveRecovery() async throws {
        for rejectMove in [false, true] {
            try await withSession { session, source, _, output, clock in
                var closes = 0
                session.onClose = { closes += 1 }
                let handle = try Self.handle(session)
                let start = try Self.handleCenter(handle)
                let original = source.region
                clock.now += 33
                source.holdResume = true
                source.failure = rejectMove ? .move : nil
                try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
                try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
                try await Self.waitUntil { source.hasPendingResume }
                clock.now += 9_000
                XCTAssertEqual(session.activeCaptureDurationForVerification, 33)
                let beforeClose = session.snapshotForVerification
                session.cancel()
                XCTAssertNil(session.controlsForVerification)
                XCTAssertFalse(session.isClosedForVerification)
                XCTAssertEqual(closes, 0)
                XCTAssertEqual(output.finishes + output.copies, 0)
                source.releaseResume(); source.releaseResume()
                try await Self.waitUntil { source.completedResumes == 1 && session.isClosedForVerification }
                XCTAssertEqual(closes, 1)
                XCTAssertEqual(source.moveCalls, 1); XCTAssertEqual(source.resumeCalls, 1)
                XCTAssertEqual(source.region, rejectMove ? original : original.offsetBy(dx: 0, dy: 60))
                XCTAssertEqual(source.stopCalls, 1)
                XCTAssertEqual(session.activeCaptureDurationForVerification, 33)
                XCTAssertEqual(session.snapshotForVerification, beforeClose)
                XCTAssertEqual(output.finishes + output.copies, 0)
                XCTAssertNil(session.controlsForVerification)
                XCTAssertEqual(closes, 1)
            }
        }
    }

    func testDragPauseMoveAndResumeFailuresRetainLastPreviewAndFinishPixels() async throws {
        for failure in [Failure.pause, .move, .resume] {
            try await withSession { session, source, seed, output, _ in
                let before = session.snapshotForVerification
                let preview = try XCTUnwrap(Self.thumbnail(session).image)
                let original = source.region
                source.failure = failure
                let handle = try Self.handle(session)
                let start = try Self.handleCenter(handle)
                try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
                try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
                try await Self.waitUntil {
                    session.snapshotForVerification.statusKind == .error && !session.snapshotForVerification.busy
                }
                let failed = session.snapshotForVerification
                XCTAssertEqual(failed.acceptedFrames, before.acceptedFrames)
                XCTAssertEqual(failed.pixelWidth, before.pixelWidth); XCTAssertEqual(failed.pixelHeight, before.pixelHeight)
                XCTAssertTrue(failed.canFinish); XCTAssertTrue(failed.canCopy)
                XCTAssertFalse(failed.previewPositionVerified)
                XCTAssertTrue(try Self.thumbnail(session).image === preview)
                XCTAssertEqual(source.region, failure == .resume ? original.offsetBy(dx: 0, dy: 60) : original)
                XCTAssertEqual(source.resumeCalls, failure == .pause ? 0 : 1)
                XCTAssertEqual(failed.paused, failure != .move)
                XCTAssertEqual(output.finishes + output.copies, 0)

                source.failure = nil
                let toolbar = try Self.toolbar(session)
                if failure == .move {
                    // The move failed but restoring the old source succeeded.
                    // A real click must do the Pause action advertised by the UI.
                    XCTAssertEqual(toolbar.pauseButton.accessibilityLabel(), "暂停捕获")
                    XCTAssertEqual(toolbar.pauseButton.toolTip, "暂停捕获")
                    XCTAssertEqual(toolbar.statusLabel.stringValue, failed.status)
                    let pauses = source.pauseCalls
                    try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
                    try await Self.waitUntil {
                        session.snapshotForVerification.paused && !session.snapshotForVerification.busy
                    }
                    XCTAssertEqual(source.pauseCalls, pauses + 1)
                    XCTAssertEqual(source.resumeCalls, 1)
                    XCTAssertEqual(toolbar.pauseButton.accessibilityLabel(), "继续捕获")
                    XCTAssertFalse(session.snapshotForVerification.autoScrolling)
                    XCTAssertEqual(session.snapshotForVerification.pixelWidth, before.pixelWidth)
                    XCTAssertEqual(session.snapshotForVerification.pixelHeight, before.pixelHeight)
                    XCTAssertTrue(try Self.thumbnail(session).image === preview)
                } else {
                    XCTAssertEqual(toolbar.pauseButton.accessibilityLabel(), "重试捕获")
                }
                try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
                try await Self.waitUntil { session.isClosedForVerification }
                XCTAssertEqual(output.finishes, 1); XCTAssertEqual(output.copies, 0)
                XCTAssertEqual(try Self.pixels(XCTUnwrap(output.image)), try Self.pixels(seed))
            }
        }
    }

    private func withSession(seed suppliedSeed: CGImage? = nil, allOutputRoutes: Bool = false,
                             _ body: (LiveScrollSessionController, Source, CGImage, Output, Clock) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for session controls") }
        let seed = try suppliedSeed ?? Self.image()
        let source = Source(displayBounds: screen.frame, size: CGSize(width: seed.width, height: seed.height))
        let output = Output(), clock = Clock()
        let chainDefinition = try CaptureChainDefinition(name: "Owned source-cap image route", source: .region, outputs: [.copy])
        let textDefinition = try TextScriptDefinition(name: "Owned source-cap text route", source: "return text;")
        let chainDependencies: LiveScrollChainDependencies? = allOutputRoutes ? .init(definitions: { [chainDefinition] }, run: { _, _ in
            XCTFail("Choice-only coverage must not run an image chain"); throw Failure.output
        }, cancel: { _ in }) : nil
        let textDependencies: LiveScrollTextDependencies? = allOutputRoutes ? .init(definitions: { [textDefinition] }, start: { _, _, _, _, _ in
            XCTFail("Choice-only coverage must not run a text script"); throw Failure.output
        }, cancel: { _ in }) : nil
        let session = LiveScrollSessionController(onComplete: { output.image = $0; output.finishes += 1 },
            onImport: { XCTFail("This regression must not open an importer") },
            onCopy: { output.image = $0; output.copies += 1; if output.rejectDelivery { throw Failure.output } },
            onPin: allOutputRoutes ? { output.image = $0; output.pins += 1; if output.rejectDelivery { throw Failure.output } } : nil,
            saveDestination: allOutputRoutes ? output : nil, monotonicNow: { clock.now },
            automaticScrollPermission: { true }, automaticScrollInput: { _ in output.automaticEvents += 1 },
            chainDependencies: chainDependencies, textDependencies: textDependencies)
        do {
            try await session.startForVerification(source: source, screen: screen)
            source.offer(seed)
            try await Self.waitUntil { session.snapshotForVerification.acceptedFrames == 1 }
            try await body(session, source, seed, output, clock)
        } catch {
            source.releaseDrain(); source.releaseResume()
            await session.closeForVerification()
            throw error
        }
        source.releaseDrain(); source.releaseResume()
        await session.closeForVerification()
        XCTAssertTrue(session.isClosedForVerification)
    }

    private static func fillSourceLimit(_ session: LiveScrollSessionController, source: Source) async throws {
        // The exact immutable 100-source sequence already proven by
        // LiveScrollAssemblerTransactionTests, now through production sampling.
        source.offer(try sourceLimitImage(origin: 24))
        try await waitUntil { session.stateForVerification.committedSources == 2 }
        for count in 3...100 {
            source.offer(try sourceLimitImage(origin: 24 + (count - 2) * 96))
            try await waitUntil { session.stateForVerification.committedSources == count }
            XCTAssertEqual(session.stateForVerification.acceptedObservations, count)
        }
        XCTAssertFalse(session.captureLimitReachedForVerification)
        XCTAssertTrue(session.snapshotForVerification.canAutoScroll)
        let document = await session.documentSnapshotForResourceVerification()
        XCTAssertEqual(document?.sourceCount, 100)
    }

    private static func assertAllOutputRoutes(_ session: LiveScrollSessionController) throws {
        let state = session.snapshotForVerification
        XCTAssertTrue(state.canFinish); XCTAssertTrue(state.canCopy)
        XCTAssertTrue(state.canQuickSave); XCTAssertTrue(state.canPin)
        XCTAssertTrue(state.canApplyImageChain); XCTAssertTrue(state.canApplyTextScript)
        for suffix in ["quickSave", "pin", "imageChain", "textScript"] {
            XCTAssertTrue(try menuItem(session, suffix).isEnabled, suffix)
        }
    }

    private static func dispatchStaleAcquisitionActions(_ session: LiveScrollSessionController) throws {
        let toolbar = try toolbar(session)
        // Native target/action dispatch deliberately bypasses NSControl's
        // disabled-click filter, as a queued/stale action would.
        try dispatchButton(toolbar.pauseButton); try dispatchButton(toolbar.autoButton)
        for suffix in ["moveRegion", "axis.horizontal", "axis.vertical"] {
            try dispatchMenu(session, suffix, requireEnabled: false)
        }
        let handle = try handle(session), start = try handleCenter(handle)
        XCTAssertFalse(handle.begin?(start) ?? false)
        handle.end?(start.offsetBy(dx: 10, dy: -20)); handle.end?(nil)
    }

    private static func dispatchButton(_ button: NSButton) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
    }

    private static func menuItem(_ session: LiveScrollSessionController, _ suffix: String) throws -> NSMenuItem {
        try XCTUnwrap(toolbar(session).moreButton.menu?.items.first { $0.identifier?.rawValue == "scroll.live." + suffix })
    }

    private static func dispatchMenu(_ session: LiveScrollSessionController, _ suffix: String,
                                     requireEnabled: Bool = true) throws {
        let item = try menuItem(session, suffix)
        if requireEnabled { XCTAssertTrue(item.isEnabled, suffix) }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    private static func assertStatusVisibleAndRetainEvidence(_ session: LiveScrollSessionController, phase: String) throws {
        let window = try XCTUnwrap(session.controlsForVerification?.toolbarWindow)
        let toolbar = try toolbar(session), label = toolbar.statusLabel
        let previousAppearance = window.appearance
        defer { window.appearance = previousAppearance; toolbar.needsDisplay = true; window.displayIfNeeded() }
        if let path = ProcessInfo.processInfo.environment["PICSHOT_SCROLL_GUIDANCE_EVIDENCE"], !path.isEmpty {
            _ = try CaptureChainUIPreviewFixture.captureOwnedEvidence(window: window, phase: phase,
                evidenceDirectory: URL(fileURLWithPath: path, isDirectory: true))
        }
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            toolbar.needsDisplay = true; label.needsDisplay = true
            let layout = try CaptureChainUIPreviewFixture.assertLayout(window: window, phase: phase + "-" + mode)
            XCTAssertEqual(toolbar.bounds.size, LiveScrollCaptureGeometry.toolbarSize)
            XCTAssertEqual(label.bounds.size, CGSize(width: 275, height: 16))
            XCTAssertEqual(label.font?.pointSize, 11)
            XCTAssertEqual(label.stringValue, session.snapshotForVerification.status)
            XCTAssertEqual(label.textColor, .systemOrange)
            let cell = try XCTUnwrap(label.cell), full = cell.cellSize
            XCTAssertGreaterThan(full.width, 0); XCTAssertGreaterThan(full.height, 0)
            XCTAssertLessThanOrEqual(full.width, label.bounds.width, "Complete status must be visible in \(mode)")
            XCTAssertLessThanOrEqual(full.height, label.bounds.height)
            XCTAssertLessThanOrEqual(cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: 10_000)).height,
                                     label.bounds.height)
            let controls = try XCTUnwrap(layout["controls"] as? [[String: Any]])
            let status = try XCTUnwrap(controls.first { $0["id"] as? String == "scroll.live.status" })
            XCTAssertEqual(status["fullFrameContained"] as? Bool, true)
            XCTAssertEqual(status["textFits"] as? Bool, true)
            XCTAssertEqual(status["intentionalTruncation"] as? Bool, false)
        }
    }

    private static func assertTerminalControls(_ session: LiveScrollSessionController) throws {
        let state = session.snapshotForVerification, toolbar = try Self.toolbar(session)
        XCTAssertTrue(state.paused); XCTAssertFalse(state.busy)
        XCTAssertFalse(state.autoScrolling)
        XCTAssertFalse(state.canPause); XCTAssertFalse(state.canMoveRegion); XCTAssertFalse(state.canAutoScroll)
        XCTAssertFalse(state.canChangeAxis)
        XCTAssertTrue(state.canFinish); XCTAssertTrue(state.canCopy)
        XCTAssertFalse(toolbar.pauseButton.isEnabled); XCTAssertFalse(toolbar.autoButton.isEnabled)
        XCTAssertFalse(try handle(session).isEnabled)
        XCTAssertTrue(toolbar.finishButton.isEnabled); XCTAssertTrue(toolbar.copyButton.isEnabled)
        XCTAssertFalse(try XCTUnwrap(toolbar.moreButton.menu?.items.first {
            $0.identifier?.rawValue == "scroll.live.moveRegion"
        }).isEnabled)
        for suffix in ["axis.horizontal", "axis.vertical"] {
            XCTAssertFalse(try menuItem(session, suffix).isEnabled)
        }
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for the synthetic session transition")
                throw Failure.timedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private static func toolbar(_ session: LiveScrollSessionController) throws -> LiveScrollToolbarView {
        try XCTUnwrap(session.controlsForVerification?.toolbarWindow?.contentView as? LiveScrollToolbarView)
    }
    private static func thumbnail(_ session: LiveScrollSessionController) throws -> LiveScrollThumbnailView {
        try XCTUnwrap(session.controlsForVerification?.previewWindow?.contentView as? LiveScrollThumbnailView)
    }
    private static func handle(_ session: LiveScrollSessionController) throws -> LiveScrollRegionDragHandle {
        try XCTUnwrap(session.controlsForVerification?.handleWindow?.contentView as? LiveScrollRegionDragHandle)
    }
    private static func handleCenter(_ view: NSView) throws -> CGPoint {
        let frame = try XCTUnwrap(view.window).frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    private static func pointer(_ type: NSEvent.EventType, handle: LiveScrollRegionDragHandle, screenPoint: CGPoint) throws {
        let window = try XCTUnwrap(handle.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: handle.mouseDown(with: event)
        case .leftMouseDragged: handle.mouseDragged(with: event)
        case .leftMouseUp: handle.mouseUp(with: event)
        default: XCTFail("Unsupported owned pointer event")
        }
    }
    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 200, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 200))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1)); context.fill(CGRect(x: 7, y: 13, width: 29, height: 83))
        return try XCTUnwrap(context.makeImage())
    }
    /// Same absolute-coordinate texture as the proven assembler source-limit
    /// fixture; expected output is generated independently of strip assembly.
    private static func sourceLimitImage(origin: Int, length: Int = 200) throws -> CGImage {
        let width = 24, height = length
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            var value = UInt64(y + origin + 10_000) &* 0x9e3779b185ebca87
            value ^= UInt64(x) &* 0xc2b2ae3d27d4eb4f
            value ^= 7
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            let pixel = UInt8(value % 216 + 20), index = (y * width + x) * 4
            data[index] = pixel; data[index + 1] = pixel; data[index + 2] = pixel
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private static func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private enum Failure: Error, Equatable { case pause, move, resume, output, timedOut }
    @MainActor private final class Clock { var now: TimeInterval = 1_000 }
    @MainActor private final class Output: LiveScrollSaveDestination {
        var image: CGImage?
        var finishes = 0, copies = 0, pins = 0, saves = 0, automaticEvents = 0
        var rejectDelivery = false
        func save(image: CGImage, parent: NSWindow?) async throws {
            self.image = image; saves += 1
            throw CancellationError()
        }
        func cancel() { }
    }

    @MainActor private final class Source: LiveScrollFrameSource {
        var region = CGRect(x: 20, y: 30, width: 64, height: 200)
        let displayBounds: CGRect
        var target: LiveScrollScreenSource.Target? { nil }
        let mailbox = LiveScrollFrameMailbox<LiveScrollScreenSource.Frame>()
        var automaticScrollWatermark: LiveScrollFrameWatermark? { mailbox.frameWatermark }
        var failure: Failure?
        var nextFailure: Error?
        var holdDrain = false
        var holdResume = false
        var hasPendingDrain: Bool { drain != nil }
        var hasPendingResume: Bool { resumption != nil }
        private(set) var pauseCalls = 0, resumeCalls = 0, moveCalls = 0, stopCalls = 0, completedDrains = 0
        private(set) var completedResumes = 0
        private(set) var operations: [String] = []
        private var generation: UInt64 = 0, sequence: UInt64 = 0
        private var running = false, stopped = false
        private var drain: CheckedContinuation<Void, Never>?
        private var resumption: CheckedContinuation<Void, Never>?

        init(displayBounds: CGRect, size: CGSize) { self.displayBounds = displayBounds; region.size = size }
        func start() async throws {
            guard !stopped else { throw LiveScrollSourceError.stopped }
            generation &+= 1; running = true
            mailbox.activate(generation: generation, width: Int(region.width), height: Int(region.height))
        }
        func resume() async throws {
            resumeCalls += 1; operations.append("resume")
            if failure == .resume { throw Failure.resume }
            try await start()
            if holdResume {
                holdResume = false
                await withCheckedContinuation { resumption = $0 }
            }
            completedResumes += 1
        }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            let token = generation
            let frame = try await mailbox.next(generation: token, timeout: timeout)
            try Task.checkCancellation()
            guard running, generation == token else { throw CancellationError() }
            if let failure = nextFailure { nextFailure = nil; throw failure }
            return frame
        }
        func offer(_ image: CGImage) {
            sequence &+= 1
            mailbox.offer(.init(image: image, sequence: sequence, generation: generation,
                timestamp: TimeInterval(sequence), region: region), generation: generation, sequence: sequence)
        }
        func pauseAndDrain() async throws {
            pauseCalls += 1; operations.append("pause"); halt()
            if holdDrain {
                holdDrain = false
                await withCheckedContinuation { drain = $0 }
            }
            completedDrains += 1
            if failure == .pause { throw Failure.pause }
        }
        func releaseDrain() {
            let pending = drain; drain = nil; pending?.resume()
        }
        func releaseResume() {
            let pending = resumption; resumption = nil; pending?.resume()
        }
        func stop() async throws {
            stopCalls += 1; stopped = true; halt()
            // Deliberately leave an already-held drain outstanding so the test
            // can complete it after retirement and exercise stale-task guards.
        }
        func moveRegion(to proposed: CGRect) throws {
            moveCalls += 1; operations.append("move")
            if failure == .move { throw Failure.move }
            guard !running, !stopped, drain == nil else { throw CaptureError.busy }
            region = proposed
        }
        func validateTarget() throws { }
        private func halt() {
            let token = generation
            running = false; generation &+= 1; mailbox.close(generation: token)
        }
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
