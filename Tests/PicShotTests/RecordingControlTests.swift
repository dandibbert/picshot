import XCTest
@testable import PicShot

final class RecordingControlTests: XCTestCase {
    func testIdleControlsAllowStartAndCloseWithoutAnExitOperation() {
        let state = RecordingControlState()
        XCTAssertTrue(state.canStart)
        XCTAssertFalse(state.optionsDisabled)
        XCTAssertFalse(state.blocksClosing)
        XCTAssertFalse(state.canPauseOrStop)
        XCTAssertFalse(state.canCancelCountdown)
        XCTAssertEqual(state.terminationAction, .none)
    }

    func testRecordingAndPausedRecordingBothSaveOnQuitAndBlockClosing() {
        for paused in [false, true] {
            let state = RecordingControlState(isRecording: true, isPaused: paused)
            XCTAssertTrue(state.hasSessionActivity)
            XCTAssertTrue(state.blocksClosing)
            XCTAssertTrue(state.optionsDisabled)
            XCTAssertTrue(state.canPauseOrStop)
            XCTAssertFalse(state.canStart)
            XCTAssertFalse(state.canCancelCountdown)
            XCTAssertEqual(state.terminationAction, .save)
        }
    }

    func testStartStopRestartAndLocalOperationsDisableConflictingControls() {
        let states = [
            RecordingControlState(isStarting: true),
            RecordingControlState(isRestarting: true),
            RecordingControlState(isStopping: true),
            RecordingControlState(isWorking: true),
            RecordingControlState(isRecording: true, isRestarting: true),
            RecordingControlState(isRecording: true, isWorking: true)
        ]
        for state in states {
            XCTAssertFalse(state.canStart)
            XCTAssertFalse(state.canPauseOrStop)
            XCTAssertTrue(state.optionsDisabled)
            XCTAssertTrue(state.blocksClosing)
        }
    }

    func testCountdownCancellationRemainsEnabledInsideBusyStartAndRestart() {
        for restarting in [false, true] {
            let state = RecordingControlState(isStarting: true, isRestarting: restarting,
                countdown: 3, isWorking: true)
            XCTAssertTrue(state.canCancelCountdown)
            XCTAssertTrue(state.blocksClosing)
            XCTAssertFalse(state.canPauseOrStop)
            XCTAssertFalse(state.canStart)
            XCTAssertEqual(state.terminationAction, .cancelCountdown)
        }
    }

    func testCountdownCancellationNeverCancelsAStartedOrSavingMovie() {
        for state in [
            RecordingControlState(isStarting: true),
            RecordingControlState(isRecording: true, isStarting: true, countdown: 1),
            RecordingControlState(isStarting: true, isStopping: true, countdown: 1)
        ] {
            XCTAssertFalse(state.canCancelCountdown)
            XCTAssertEqual(state.terminationAction, .save)
        }
    }

    func testManualStopAndPublishedAutomaticStopOpenTheSameMovieOnce() {
        var policy = RecordingPreviewRoutingPolicy()
        let url = movie("first")
        XCTAssertEqual(policy.receive(url, suppressPreview: false), url)
        XCTAssertNil(policy.receive(url, suppressPreview: false))
        XCTAssertEqual(policy.output, url)
        XCTAssertEqual(policy.lastPresented, url)
    }

    func testSuccessfulRestartRetainsPreviousTakeWithoutCoveringNewCapture() {
        var policy = RecordingPreviewRoutingPolicy()
        let previous = movie("previous")
        XCTAssertNil(policy.receive(previous, suppressPreview: true))
        XCTAssertNil(policy.lastPresented)
        XCTAssertNil(policy.finishRestart(previous: previous, captureRemainsActive: true))
        XCTAssertEqual(policy.previousTake, previous)
        XCTAssertEqual(policy.output, previous)
        XCTAssertNil(policy.pendingPreview)
        XCTAssertNil(policy.lastPresented)
        let new = movie("new")
        XCTAssertEqual(policy.receive(new, suppressPreview: false), new)
        XCTAssertEqual(policy.previousTake, previous)
        XCTAssertEqual(policy.output, new)
    }

    func testFailedRestartReplaysSavedTakeOnlyWhenNothingRemainsActive() {
        var policy = RecordingPreviewRoutingPolicy()
        let saved = movie("saved-before-failure")
        XCTAssertNil(policy.receive(saved, suppressPreview: true))
        XCTAssertEqual(policy.finishRestart(previous: nil, captureRemainsActive: false), saved)
        XCTAssertEqual(policy.previousTake, saved)
        XCTAssertNil(policy.finishRestart(previous: nil, captureRemainsActive: false))
        XCTAssertNil(policy.receive(saved, suppressPreview: false))
    }

    func testInterruptedRestartNeverReplaysWhileAnyCaptureRemains() {
        for state in [
            RecordingControlState(isRecording: true),
            RecordingControlState(isRecording: true, isPaused: true),
            RecordingControlState(isStarting: true, countdown: 1),
            RecordingControlState(isStopping: true),
            RecordingControlState(isRestarting: true)
        ] {
            var policy = RecordingPreviewRoutingPolicy()
            let url = movie("suppressed")
            XCTAssertNil(policy.receive(url, suppressPreview: true))
            XCTAssertNil(policy.finishRestart(previous: nil, captureRemainsActive: state.hasSessionActivity))
            XCTAssertEqual(policy.previousTake, url)
            XCTAssertNil(policy.pendingPreview)
        }
    }

    func testDiscardRestartDoesNotInventOutputOrLoseAnEarlierSavedTake() {
        var policy = RecordingPreviewRoutingPolicy()
        XCTAssertNil(policy.finishRestart(previous: nil, captureRemainsActive: true))
        XCTAssertNil(policy.output)
        XCTAssertNil(policy.previousTake)
        let saved = movie("previously-saved")
        XCTAssertNil(policy.receive(saved, suppressPreview: true))
        XCTAssertNil(policy.finishRestart(previous: saved, captureRemainsActive: true))
        XCTAssertNil(policy.finishRestart(previous: nil, captureRemainsActive: true))
        XCTAssertEqual(policy.previousTake, saved)
        XCTAssertEqual(policy.output, saved)
    }

    func testRapidlyFinishedNewTakeWinsThePreviewButPreservesReturnedOldTake() {
        var policy = RecordingPreviewRoutingPolicy()
        let old = movie("old"), new = movie("new")
        XCTAssertNil(policy.receive(old, suppressPreview: true))
        XCTAssertNil(policy.receive(new, suppressPreview: true))
        XCTAssertEqual(policy.finishRestart(previous: old, captureRemainsActive: false), new)
        XCTAssertEqual(policy.previousTake, old)
        XCTAssertEqual(policy.output, new)
    }

    func testRepeatedRestartsUpdateThePreviousTakeWithoutReplayingOldMovies() {
        var policy = RecordingPreviewRoutingPolicy()
        for index in 0..<20 {
            let url = movie("take-\(index)")
            XCTAssertNil(policy.receive(url, suppressPreview: true))
            XCTAssertNil(policy.finishRestart(previous: url, captureRemainsActive: true))
            XCTAssertEqual(policy.previousTake, url)
            XCTAssertNil(policy.lastPresented)
        }
    }

    @MainActor
    func testExitSavesRecordingAndPausedRecordingWithoutCallingDiscard() async throws {
        for paused in [false, true] {
            var state = RecordingControlState(isRecording: true, isPaused: paused)
            var saves = 0
            try await RecordingTerminationCoordinator.finish(snapshot: { state },
                cancelCountdown: { XCTFail("Quit must not discard an active or paused recording") },
                save: { saves += 1; state = RecordingControlState() })
            XCTAssertEqual(saves, 1)
            XCTAssertFalse(state.hasSessionActivity)
        }
    }

    @MainActor
    func testExitRechecksCountdownThatEndedWhileConfirmationWasOpen() async throws {
        var state = RecordingControlState(isStarting: true, countdown: 1)
        XCTAssertEqual(state.terminationAction, .cancelCountdown)
        state = RecordingControlState(isRecording: true)
        var saved = false
        try await RecordingTerminationCoordinator.finish(snapshot: { state },
            cancelCountdown: { XCTFail("Countdown already ended; the movie must be saved") },
            save: { saved = true; state = RecordingControlState() })
        XCTAssertTrue(saved)
    }

    @MainActor
    func testIdleExitDoesNotTouchRecordingStorage() async throws {
        try await RecordingTerminationCoordinator.finish(snapshot: { RecordingControlState() },
            cancelCountdown: { XCTFail("Idle exit must not cancel") },
            save: { XCTFail("Idle exit must not save") })
    }

    @MainActor
    func testSaveFailurePreventsSuccessfulExit() async {
        enum SaveFailure: Error { case expected }
        do {
            try await RecordingTerminationCoordinator.finish(
                snapshot: { RecordingControlState(isRecording: true, isPaused: true) },
                cancelCountdown: { XCTFail("A failed save is not permission to discard") },
                save: { throw SaveFailure.expected })
            XCTFail("Quit must not succeed if saving fails")
        } catch SaveFailure.expected { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testCancelledSaveCannotAuthorizeExitWhileRecordingRemainsActive() async {
        do {
            try await RecordingTerminationCoordinator.finish(
                snapshot: { RecordingControlState(isRecording: true) },
                cancelCountdown: { XCTFail("Must not discard") },
                save: { throw CancellationError() })
            XCTFail("Active recording must block exit")
        } catch RecordingError.busy { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testExitWaitsForPendingRestartCleanupAfterSaving() async throws {
        var state = RecordingControlState(isRestarting: true, isStopping: true)
        var cleanup: Task<Void, Never>?
        var saved = false
        try await RecordingTerminationCoordinator.finish(snapshot: { state },
            cancelCountdown: { XCTFail("An already saving take must not be cancelled") },
            save: {
                saved = true
                state.isStopping = false
                cleanup = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    state.isRestarting = false
                }
            })
        await cleanup?.value
        XCTAssertTrue(saved)
        XCTAssertFalse(state.hasSessionActivity)
    }

    @MainActor
    func testQuitDuringRealServiceCountdownCancelsWithoutScreenPermission() async throws {
        let service = serviceWithoutScreenAccess()
        let starting = Task { try await service.start(displayID: 0, delay: 30) }
        try await waitUntil { service.controlState.canCancelCountdown }
        try await RecordingTerminationCoordinator.finish(snapshot: { service.controlState },
            cancelCountdown: { await service.cancel() },
            save: { XCTFail("An unstarted countdown has no movie to save") })
        do { try await starting.value; XCTFail("Quit must cancel pending capture") }
        catch is CancellationError { }
        XCTAssertFalse(service.controlState.hasSessionActivity)
        XCTAssertNil(service.countdown)
        XCTAssertNil(service.outputURL)
        XCTAssertNil(service.error)
    }

    @MainActor
    func testQuitDuringRealServiceRestartCountdownDrainsBothStartGenerations() async throws {
        let service = serviceWithoutScreenAccess()
        let starting = Task { try await service.start(displayID: 0, delay: 30) }
        try await waitUntil { service.countdown == 30 }
        let restarting = Task { try await service.restart(delay: 29) }
        try await waitUntil { service.isRestarting && service.countdown == 29 }
        try await RecordingTerminationCoordinator.finish(snapshot: { service.controlState },
            cancelCountdown: { await service.cancel() },
            save: { XCTFail("Restart countdown must cancel without creating a stream") })
        _ = await starting.result
        do { _ = try await restarting.value; XCTFail("Quit must cancel restart") }
        catch is CancellationError { }
        XCTAssertFalse(service.controlState.hasSessionActivity)
        XCTAssertNil(service.countdown)
        XCTAssertNil(service.error)
    }

    private func movie(_ name: String) -> URL {
        URL(fileURLWithPath: "/test-recordings/\(name).mp4")
    }

    @MainActor
    private func serviceWithoutScreenAccess() -> RecordingService {
        RecordingService(screenPermissionCheck: {
            XCTFail("Recording control tests must never request real screen access")
            throw RecordingError.failed("Live capture is forbidden in recording control tests.")
        })
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw RecordingError.failed("Recording control state did not settle.") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
