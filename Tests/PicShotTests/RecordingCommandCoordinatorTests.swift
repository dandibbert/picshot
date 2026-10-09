import AppKit
import Combine
import XCTest
@testable import PicShot

@MainActor
final class RecordingCommandCoordinatorTests: XCTestCase {
    func testCaptureAnchorUsesDisplayLocalTopLeftAndAppKitNegativeOrigins() {
        let target = RecordingCommandTarget(displayID: 42, region: CGRect(x: 20, y: 30, width: 320, height: 180))
        XCTAssertEqual(target.appKitFrame(in: CGRect(x: -1440, y: -200, width: 1440, height: 900)),
                       CGRect(x: -1420, y: 490, width: 320, height: 180))
        XCTAssertEqual(target.appKitFrame(in: CGRect(x: 100, y: 900, width: 1920, height: 1080)),
                       CGRect(x: 120, y: 1770, width: 320, height: 180))
        let fullDisplay = RecordingCommandTarget(displayID: 42, region: nil)
        let frame = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(fullDisplay.appKitFrame(in: frame), frame)
    }

    func testLaterDeliberatePauseResumeUsesTheCompletedState() async throws {
        let service = CommandService()
        let owner = makeOwner(service)
        let pause = try XCTUnwrap(owner.pauseResume())
        await pause.value
        XCTAssertTrue(owner.controlState.isPaused)
        let resume = try XCTUnwrap(owner.pauseResume())
        await resume.value
        XCTAssertFalse(owner.controlState.isPaused)
        XCTAssertEqual(service.calls, ["pause", "resume"])
        owner.teardown()
    }

    func testIdleAndCountdownTransportCommandsDoNothing() async {
        for state in [RecordingControlState(), RecordingControlState(isStarting: true, countdown: 3)] {
            let service = CommandService(state: state)
            let owner = makeOwner(service)
            XCTAssertNil(owner.pauseResume())
            XCTAssertNil(owner.stopAndSave())
            await Task.yield()
            XCTAssertEqual(service.calls, [])
            owner.teardown()
        }
    }

    func testStopSupersedesPauseBeforeItsQueuedActorTurn() async throws {
        let service = CommandService()
        let owner = makeOwner(service)
        let pause = try XCTUnwrap(owner.pauseResume())
        let stop = try XCTUnwrap(owner.stopAndSave())
        XCTAssertTrue(owner.stopRequested)
        XCTAssertNil(owner.pauseResume())
        await pause.value
        _ = try await stop.value
        XCTAssertEqual(service.calls, ["stop"])
        XCTAssertFalse(owner.working)
        owner.teardown()
    }

    func testStopDrainsInFlightPauseAndDuplicatesJoinOneSaveAndPreview() async throws {
        let service = CommandService()
        service.holdPause = true
        service.holdStop = true
        let owner = makeOwner(service)
        var previews: [URL] = []
        owner.onPreview = { previews.append($0) }
        let pause = try XCTUnwrap(owner.pauseResume())
        try await until { service.pauseContinuation != nil }
        XCTAssertNil(owner.pauseResume())
        XCTAssertTrue(owner.canStop, "Saving stays available during a pending Pause")
        let first = try XCTUnwrap(owner.stopAndSave())
        let second = try XCTUnwrap(owner.stopAndSave())
        XCTAssertNil(owner.pauseResume())
        await Task.yield()
        XCTAssertEqual(service.calls, ["pause"])
        service.completePause()
        await pause.value
        try await until { service.stopContinuation != nil }
        XCTAssertEqual(service.calls, ["pause", "stop"])
        service.completeStop()
        let firstURL = try await first.value
        let secondURL = try await second.value
        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(previews, [service.savedURL])
        XCTAssertFalse(service.concurrentStop)
        XCTAssertFalse(owner.working)
        XCTAssertNil(owner.stopAndSave(), "A late duplicate cannot restart saving from idle")
        owner.teardown()
    }

    func testQueuedResumeCannotUndoAcceptedStop() async throws {
        let service = CommandService(state: RecordingControlState(isRecording: true, isPaused: true))
        let owner = makeOwner(service)
        let resume = try XCTUnwrap(owner.pauseResume())
        let stop = try XCTUnwrap(owner.stopAndSave())
        await resume.value
        _ = try await stop.value
        XCTAssertEqual(service.calls, ["stop"])
        XCTAssertFalse(service.controlState.isRecording)
        owner.teardown()
    }

    func testPauseFailureStillAllowsAcceptedStopAndPreservesSavedURL() async throws {
        let service = CommandService()
        service.holdPause = true
        let owner = makeOwner(service)
        let pause = try XCTUnwrap(owner.pauseResume())
        try await until { service.pauseContinuation != nil }
        let stop = try XCTUnwrap(owner.stopAndSave())
        service.completePause(failure: .pause)
        await pause.value
        let saved = try await stop.value
        XCTAssertEqual(saved, service.savedURL)
        XCTAssertEqual(owner.routing.output, saved)
        XCTAssertFalse(service.concurrentStop)
        XCTAssertEqual(service.cancelCount, 0)
        owner.teardown()
    }

    func testFailedSaveProtectsPendingTakeAndRetryDoesNotDiscard() async throws {
        let service = CommandService()
        service.stopFailure = .preservation
        let owner = makeOwner(service)
        var previews = 0
        owner.onPreview = { _ in previews += 1 }
        let stop = try XCTUnwrap(owner.stopAndSave())
        do { _ = try await stop.value; XCTFail("Injected save failure must propagate") }
        catch CommandFailure.preservation { }
        XCTAssertTrue(owner.controlState.hasPendingTake)
        XCTAssertTrue(owner.controlState.blocksClosing)
        XCTAssertFalse(owner.controlState.canStart)
        XCTAssertFalse(owner.canStop)
        XCTAssertNotNil(owner.failure)
        XCTAssertEqual(previews, 0)
        XCTAssertEqual(service.cancelCount, 0)
        let retry = try XCTUnwrap(owner.retryPreservation())
        await retry.value
        XCTAssertEqual(service.preservationCalls, 1)
        XCTAssertTrue(owner.controlState.canStart)
        XCTAssertEqual(service.cancelCount, 0)
        owner.teardown()
    }

    func testAutomaticOutputOpensOnceEvenBeforeCoalescedStateRefresh() async throws {
        let service = CommandService()
        let owner = makeOwner(service)
        var previews: [URL] = []
        owner.onPreview = { previews.append($0) }
        service.controlState = RecordingControlState(isStopping: true)
        service.output.send(service.savedURL)
        service.output.send(service.savedURL)
        XCTAssertEqual(previews, [service.savedURL])
        service.controlState = RecordingControlState()
        try await until { !owner.state.hasSessionActivity }
        XCTAssertEqual(owner.routing.output, service.savedURL)
        XCTAssertEqual(service.calls, [])
        owner.teardown()
    }

    func testRestartSuppressesPreviousPreviewAndKeepsItsURLAfterNewTake() async throws {
        let service = CommandService()
        let owner = makeOwner(service)
        var previews: [URL] = []
        owner.onPreview = { previews.append($0) }
        let restart = try XCTUnwrap(owner.restart(discard: false, delay: 0))
        await restart.value
        XCTAssertEqual(previews, [])
        XCTAssertEqual(owner.routing.previousTake, service.savedURL)
        XCTAssertTrue(owner.controlState.isRecording)
        owner.showPreview(service.savedURL)
        XCTAssertEqual(previews, [], "Previous preview must not cover active capture")
        let new = URL(fileURLWithPath: "/synthetic-command-tests/new.mp4")
        service.controlState = RecordingControlState()
        service.output.send(new)
        XCTAssertEqual(previews, [new])
        XCTAssertEqual(owner.routing.previousTake, service.savedURL)
        XCTAssertEqual(owner.routing.output, new)
        owner.teardown()
    }

    func testFailedRestartPresentsSavedFirstTakeExactlyOnce() async throws {
        let service = CommandService()
        service.restartFailure = true
        let owner = makeOwner(service)
        var previews: [URL] = []
        owner.onPreview = { previews.append($0) }
        let restart = try XCTUnwrap(owner.restart(discard: false, delay: 0))
        await restart.value
        XCTAssertEqual(previews, [service.savedURL])
        XCTAssertEqual(owner.routing.previousTake, service.savedURL)
        service.output.send(service.savedURL)
        XCTAssertEqual(previews.count, 1)
        XCTAssertNotNil(owner.failure)
        owner.teardown()
    }

    func testLateOldOutputCannotOpenPreviewOverNewRecording() async throws {
        let service = CommandService()
        let owner = makeOwner(service)
        var previews: [URL] = []
        owner.onPreview = { previews.append($0) }
        let stop = try XCTUnwrap(owner.stopAndSave())
        _ = try await stop.value
        let start = try XCTUnwrap(owner.start(displayID: 42, options: .init(), delay: 0) { nil })
        await start.value
        service.output.send(service.savedURL)
        await Task.yield()
        XCTAssertEqual(previews, [service.savedURL])
        XCTAssertTrue(owner.controlState.isRecording)
        owner.teardown()
    }

    func testCountdownCancelDrainsStartWithoutStartingOrStoppingMedia() async throws {
        let service = CommandService(state: RecordingControlState())
        let owner = makeOwner(service)
        let start = try XCTUnwrap(owner.start(displayID: 42, options: .init(), delay: 30) { nil })
        try await until { service.startContinuation != nil }
        XCTAssertTrue(owner.controlState.canCancelCountdown)
        XCTAssertNil(owner.pauseResume())
        XCTAssertNil(owner.stopAndSave())
        let cancel = try XCTUnwrap(owner.cancelCountdown())
        await cancel.value
        await start.value
        XCTAssertEqual(service.calls, ["start", "cancel"])
        XCTAssertFalse(owner.controlState.blocksClosing)
        XCTAssertNil(owner.routing.output)
        owner.teardown()
    }

    func testQuitJoinsStopAndWaitsForPendingPause() async throws {
        let service = CommandService()
        service.holdPause = true
        let owner = makeOwner(service)
        let pause = try XCTUnwrap(owner.pauseResume())
        try await until { service.pauseContinuation != nil }
        let stop = try XCTUnwrap(owner.stopAndSave())
        let quitting = Task { try await owner.saveForTermination() }
        await Task.yield()
        XCTAssertEqual(service.calls, ["pause"])
        service.completePause()
        await pause.value
        _ = try await stop.value
        try await quitting.value
        XCTAssertEqual(service.calls, ["pause", "stop"])
        XCTAssertFalse(service.concurrentStop)
        owner.teardown()
    }

    func testTeardownDetachesObserversWithoutCancellingAcceptedSave() async throws {
        let service = CommandService()
        service.holdStop = true
        var owner: RecordingCommandCoordinator? = makeOwner(service)
        weak var weakOwner = owner
        var previews = 0
        owner?.onPreview = { _ in previews += 1 }
        let stop = try XCTUnwrap(owner?.stopAndSave())
        try await until { service.stopContinuation != nil }
        XCTAssertEqual(service.changeSubscriptions, 1)
        XCTAssertEqual(service.outputSubscriptions, 1)
        owner?.teardown()
        XCTAssertEqual(service.changeSubscriptions, 0)
        XCTAssertEqual(service.outputSubscriptions, 0)
        owner = nil
        service.completeStop()
        _ = try await stop.value
        try await until { weakOwner == nil }
        XCTAssertEqual(service.calls, ["stop"])
        XCTAssertEqual(previews, 0)
        XCTAssertEqual(service.cancelCount, 0)
    }

    func testExpandCollapseAndDisplayChangesRetainOneOwnerWithoutClosingSession() async throws {
        _ = NSApplication.shared
        let service = CommandService(state: RecordingControlState())
        let owner = makeOwner(service)
        let transport = TransportProbe()
        var installations = 0
        var removals = 0
        let inputDependencies = RecordingInputMonitorDependencies(
            permissions: { RecordingInputPermissions(inputMonitoring: true, accessibility: true) },
            secureInputEnabled: { false }, focusedContext: { .ordinary },
            install: { _, _ in installations += 1; return NSObject() },
            remove: { _ in removals += 1 }, scheduleHealthCheck: { _ in { } }, clock: { 100 })
        let nativeService = RecordingService(screenPermissionCheck: { throw CommandFailure.noScreen },
            inputMonitorDependencies: inputDependencies)
        nativeService.inputMonitor.options.clicks = true
        nativeService.inputMonitor.beginSession(frame: CGRect(x: 20, y: 30, width: 320, height: 180), at: 100)
        defer { nativeService.inputMonitor.endSession() }
        var controller: RecordingPanelController? = RecordingPanelController(service: nativeService, capture: CaptureService(),
            commands: owner, transportFactory: { transport.actions = $0; return transport }, presentWindows: false)
        weak var weakController = controller
        controller?.expandControls()
        var windowCloses = 0
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: controller?.window, queue: .main) { _ in windowCloses += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let start = try XCTUnwrap(owner.start(displayID: CGMainDisplayID(), options: .init(), delay: 0) {
            CGRect(x: 20, y: 30, width: 320, height: 180)
        })
        await start.value
        XCTAssertEqual(controller?.presentation, .compact)
        XCTAssertEqual(transport.showCount, 1)
        controller?.setTransportShortcutLabels(pause: "⌃⌥P", stop: "⌃⌥S")
        XCTAssertEqual(transport.snapshot?.pauseShortcut, "⌃⌥P")
        XCTAssertEqual(transport.snapshot?.stopShortcut, "⌃⌥S")
        for _ in 0..<10 {
            transport.actions?.expand()
            XCTAssertEqual(controller?.presentation, .expanded)
            controller?.collapseToTransport()
            XCTAssertEqual(controller?.presentation, .compact)
        }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(transport.placementCount, 2)
        XCTAssertEqual(transport.placementPreservation, [false, true])
        XCTAssertTrue(transport.preservedPosition)
        XCTAssertEqual(windowCloses, 0)
        XCTAssertTrue(nativeService.inputMonitor.isMonitoring)
        XCTAssertEqual(installations, 1, "All registrations are injected; presentation never replaces the monitor")
        XCTAssertEqual(removals, 0, "Expand/collapse must not end input monitoring")
        XCTAssertEqual(service.calls, ["start"])
        XCTAssertTrue(service.controlState.isRecording)
        XCTAssertEqual(service.changeSubscriptions, 1)
        XCTAssertEqual(service.outputSubscriptions, 1)
        controller?.teardown()
        XCTAssertEqual(transport.teardownCount, 1)
        let placements = transport.placementCount
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(transport.placementCount, placements)
        XCTAssertEqual(service.changeSubscriptions, 0)
        XCTAssertEqual(service.outputSubscriptions, 0)
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertEqual(service.cancelCount, 0)
    }

    func testControllerReleaseCleansObserversWithoutExplicitTeardown() async throws {
        _ = NSApplication.shared
        let service = CommandService(state: RecordingControlState())
        let transport = TransportProbe()
        weak var weakOwner: RecordingCommandCoordinator?
        weak var weakController: RecordingPanelController?
        autoreleasepool {
            let owner = makeOwner(service)
            weakOwner = owner
            let nativeService = RecordingService(screenPermissionCheck: { throw CommandFailure.noScreen })
            let controller = RecordingPanelController(service: nativeService, capture: CaptureService(),
                commands: owner, transportFactory: { transport.actions = $0; return transport }, presentWindows: false)
            weakController = controller
        }
        try await until { weakOwner == nil && weakController == nil }
        XCTAssertEqual(transport.teardownCount, 1)
        XCTAssertEqual(service.changeSubscriptions, 0)
        XCTAssertEqual(service.outputSubscriptions, 0)
        let placements = transport.placementCount
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(transport.placementCount, placements)
    }

    func testPreparationQuitWithoutCancellationHandlerFailsClosed() async {
        let state = RecordingControlState(isWorking: true, isSelectingRegion: true)
        do {
            try await RecordingTerminationCoordinator.finish(snapshot: { state },
                cancelCountdown: { XCTFail("Selection is not a countdown") },
                save: { XCTFail("Selection has no media") })
            XCTFail("A caller without preparation cancellation cannot approve Quit")
        } catch RecordingError.busy { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testQuitCancelsAndDrainsPendingSelectorWithoutEnteringService() async throws {
        let service = CommandService(state: RecordingControlState())
        let owner = makeOwner(service)
        let selector = CommandSelector()
        let start = try XCTUnwrap(owner.start(displayID: 42, options: .init(), delay: 0) {
            try await selector.select()
        })
        try await until { selector.continuation != nil }
        XCTAssertEqual(owner.controlState.terminationAction, .cancelPreparation)
        XCTAssertTrue(owner.controlState.hasSessionActivity)
        XCTAssertTrue(owner.controlState.blocksClosing)
        XCTAssertNil(owner.pauseResume())
        XCTAssertNil(owner.stopAndSave())
        try await RecordingTerminationCoordinator.finish(snapshot: { owner.controlState },
            cancelCountdown: { XCTFail("No service countdown was created") },
            save: { XCTFail("No recording exists to save") },
            cancelPreparation: { try await owner.cancelStartForTermination() })
        await start.value
        XCTAssertTrue(selector.cancellationObserved)
        XCTAssertTrue(selector.drained)
        XCTAssertEqual(service.calls, [])
        XCTAssertFalse(owner.controlState.blocksClosing)
        owner.teardown()
    }

    func testLateSuccessfulSelectorAfterQuitCannotStartCaptureAndQuitWaitsForDrain() async throws {
        let service = CommandService(state: RecordingControlState())
        let owner = makeOwner(service)
        let selector = CommandSelector()
        selector.finishOnCancel = false
        let start = try XCTUnwrap(owner.start(displayID: 42, options: .init(), delay: 0) {
            try await selector.select()
        })
        try await until { selector.continuation != nil }
        var quitFinished = false
        let quitting = Task {
            try await RecordingTerminationCoordinator.finish(snapshot: { owner.controlState },
                cancelCountdown: { XCTFail("No service countdown was created") },
                save: { XCTFail("Cancellation must prevent service start") },
                cancelPreparation: { try await owner.cancelStartForTermination() })
            quitFinished = true
        }
        try await until { selector.cancellationObserved }
        XCTAssertFalse(quitFinished, "Quit cannot reply before the selector releases its window")
        XCTAssertTrue(owner.controlState.isSelectingRegion)
        XCTAssertEqual(service.calls, [])
        // A pending mouse-up may win against the selector's cancel callback.
        selector.finish(.success(CGRect(x: 10, y: 20, width: 320, height: 180)))
        try await quitting.value
        await start.value
        XCTAssertTrue(quitFinished)
        XCTAssertTrue(selector.drained)
        XCTAssertEqual(service.calls, [], "The post-selection cancellation barrier must prevent capture")
        XCTAssertNil(owner.routing.output)
        XCTAssertFalse(owner.controlState.hasSessionActivity)
        owner.teardown()
    }

    func testPreparationQuitRechecksCompletedSelectorAndSavesAcceptedTake() async throws {
        let service = CommandService(state: RecordingControlState())
        let owner = makeOwner(service)
        let selector = CommandSelector()
        let start = try XCTUnwrap(owner.start(displayID: 42, options: .init(), delay: 0) {
            try await selector.select()
        })
        try await until { selector.continuation != nil }
        XCTAssertEqual(owner.controlState.terminationAction, .cancelPreparation)
        // Simulate selection completing while the Quit confirmation is open.
        selector.finish(.success(CGRect(x: 10, y: 20, width: 320, height: 180)))
        await start.value
        try await owner.cancelStartForTermination()
        XCTAssertEqual(service.calls, ["start", "stop"])
        XCTAssertEqual(service.cancelCount, 0, "An accepted take must be saved, never cancelled")
        XCTAssertEqual(owner.routing.output, service.savedURL)
        XCTAssertFalse(selector.cancellationObserved)
        owner.teardown()
    }

    func testPreparationQuitRechecksSelectorThatAdvancedIntoCountdown() async throws {
        let service = CommandService(state: RecordingControlState())
        let owner = makeOwner(service)
        let selector = CommandSelector()
        let start = try XCTUnwrap(owner.start(displayID: 42, options: .init(), delay: 30) {
            try await selector.select()
        })
        try await until { selector.continuation != nil }
        XCTAssertEqual(owner.controlState.terminationAction, .cancelPreparation)
        selector.finish(.success(CGRect(x: 10, y: 20, width: 320, height: 180)))
        try await until { service.startContinuation != nil }
        try await owner.cancelStartForTermination()
        await start.value
        XCTAssertEqual(service.calls, ["start", "cancel"])
        XCTAssertEqual(service.cancelCount, 1)
        XCTAssertNil(owner.routing.output)
        XCTAssertFalse(selector.cancellationObserved)
        owner.teardown()
    }

    func testNewTakeResetsAnchorWhileSameTakeCollapsePreservesPlacement() async throws {
        _ = NSApplication.shared
        let service = CommandService(state: RecordingControlState())
        let owner = makeOwner(service)
        let transport = TransportProbe()
        let previews = RecordingPreviewWindowStore(presentWindows: false)
        let nativeService = RecordingService(screenPermissionCheck: { throw CommandFailure.noScreen })
        let controller = RecordingPanelController(service: nativeService, capture: CaptureService(), previews: previews,
            commands: owner, transportFactory: { transport.actions = $0; return transport }, presentWindows: false)
        defer { controller.teardown(); previews.closeAll() }
        let first = try XCTUnwrap(owner.start(displayID: CGMainDisplayID(), options: .init(), delay: 0) {
            CGRect(x: 20, y: 30, width: 320, height: 180)
        })
        await first.value
        XCTAssertEqual(transport.placementPreservation, [false])
        controller.expandControls(); controller.collapseToTransport()
        XCTAssertEqual(transport.placementPreservation, [false], "Same-take collapse uses show with preserved position")
        let stop = try XCTUnwrap(owner.stopAndSave())
        _ = try await stop.value
        let second = try XCTUnwrap(owner.start(displayID: CGMainDisplayID(), options: .init(), delay: 0) {
            CGRect(x: 120, y: 130, width: 320, height: 180)
        })
        await second.value
        XCTAssertEqual(transport.placementPreservation, [false, false])
        XCTAssertEqual(owner.target?.region?.origin, CGPoint(x: 120, y: 130))
        controller.expandControls(); controller.collapseToTransport()
        XCTAssertEqual(transport.placementPreservation, [false, false])
        XCTAssertTrue(service.controlState.isRecording)
    }

    func testStopClosesInputAdmissionImmediatelyAndHeldResumeCannotReopenIt() async throws {
        for heldResume in [false, true] {
            var installs = 0
            var removes = 0
            var callbacks: [@MainActor (RecordingInputObservation) -> Void] = []
            let dependencies = RecordingInputMonitorDependencies(
                permissions: { RecordingInputPermissions(inputMonitoring: true, accessibility: true) },
                secureInputEnabled: { false }, focusedContext: { .ordinary },
                install: { _, callback in installs += 1; callbacks.append(callback); return NSObject() },
                remove: { _ in removes += 1 }, scheduleHealthCheck: { _ in { } }, clock: { 100.2 })
            let nativeService = RecordingService(screenPermissionCheck: {
                XCTFail("Input-admission regression must never request screen capture")
                throw CommandFailure.noScreen
            }, inputMonitorDependencies: dependencies)
            let monitor = nativeService.inputMonitor
            let effects = nativeService.composition.inputEffects
            monitor.options.clicks = true
            monitor.beginSession(frame: CGRect(x: 0, y: 0, width: 320, height: 180), at: 100)
            defer { monitor.endSession() }
            let observation = RecordingInputObservation(kind: .click(.left),
                point: CGPoint(x: 100, y: 100), timestamp: 100.2)
            callbacks.last?(observation)
            XCTAssertTrue(monitor.isMonitoring)
            XCTAssertEqual(effects.snapshot(at: 100.2).events.count, 1)

            let service = CommandService()
            service.holdPause = heldResume
            service.holdStop = true
            service.onCloseInputAdmission = { nativeService.closeInputAdmissionForStop() }
            service.onPauseTransitionCompleted = { monitor.setPaused($0, at: 100.3) }
            if heldResume {
                monitor.setPaused(true, at: 100.2)
                service.controlState.isPaused = true
            }
            let owner = makeOwner(service)
            var previews: [URL] = []
            owner.onPreview = { previews.append($0) }
            var resume: Task<Void, Never>?
            if heldResume {
                resume = try XCTUnwrap(owner.pauseResume())
                try await until { service.pauseContinuation != nil }
            }
            let stop = try XCTUnwrap(owner.stopAndSave())
            let duplicate = try XCTUnwrap(owner.stopAndSave())
            // No await between Stop admission and these assertions: removal and
            // effect clearing must happen before the save Task gets an actor turn.
            XCTAssertEqual(service.admissionCloseCount, 1)
            XCTAssertFalse(monitor.isMonitoring)
            XCTAssertTrue(effects.snapshot(at: 100.2).events.isEmpty)
            XCTAssertEqual(installs, 1)
            XCTAssertEqual(removes, 1)
            callbacks.last?(observation)
            XCTAssertTrue(effects.snapshot(at: 100.2).events.isEmpty)
            if heldResume {
                XCTAssertEqual(service.calls, ["resume"])
                service.completePause()
                await resume?.value
                XCTAssertFalse(monitor.isMonitoring, "Late Resume cannot restore a closed session token")
                XCTAssertEqual(installs, 1, "Resume completion must not add a new listener after Stop")
            }
            try await until { service.stopContinuation != nil }
            XCTAssertEqual(service.calls, heldResume ? ["resume", "stop"] : ["stop"])
            XCTAssertFalse(service.concurrentStop)
            service.completeStop()
            _ = try await stop.value
            _ = try await duplicate.value
            XCTAssertEqual(previews, [service.savedURL])
            XCTAssertEqual(service.admissionCloseCount, 1)
            XCTAssertEqual(installs, 1)
            XCTAssertEqual(removes, 1)
            XCTAssertFalse(monitor.isMonitoring)
            XCTAssertTrue(effects.snapshot(at: 100.3).events.isEmpty)
            owner.teardown()
        }
    }

    private func makeOwner(_ service: CommandService) -> RecordingCommandCoordinator {
        let owner = RecordingCommandCoordinator(service: service)
        owner.startObserving()
        return owner
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw RecordingError.failed("Injected recording command did not settle") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private enum CommandFailure: Error { case pause, preservation, restart, noScreen }

@MainActor
private final class CommandService: RecordingCommandService {
    var controlState: RecordingControlState { willSet { changes.send() } }
    var elapsed: TimeInterval = 4
    var error: String?
    let changes = PassthroughSubject<Void, Never>()
    let output = CurrentValueSubject<URL?, Never>(nil)
    var changeSubscriptions = 0
    var outputSubscriptions = 0
    var calls: [String] = []
    var holdPause = false
    var holdStop = false
    var stopFailure: CommandFailure?
    var restartFailure = false
    var concurrentStop = false
    var pauseContinuation: CheckedContinuation<Void, Error>?
    var stopContinuation: CheckedContinuation<Void, Error>?
    var startContinuation: CheckedContinuation<Void, Error>?
    var preservationCalls = 0
    var cancelCount = 0
    var admissionCloseCount = 0
    var onCloseInputAdmission: (() -> Void)?
    var onPauseTransitionCompleted: ((Bool) -> Void)?
    let savedURL = URL(fileURLWithPath: "/synthetic-command-tests/saved.mp4")

    init(state: RecordingControlState = RecordingControlState(isRecording: true)) { controlState = state }
    var commandChanges: AnyPublisher<Void, Never> {
        changes.handleEvents(receiveSubscription: { [weak self] _ in self?.changeSubscriptions += 1 },
            receiveCancel: { [weak self] in self?.changeSubscriptions -= 1 }).eraseToAnyPublisher()
    }
    var commandOutput: AnyPublisher<URL?, Never> {
        output.handleEvents(receiveSubscription: { [weak self] _ in self?.outputSubscriptions += 1 },
            receiveCancel: { [weak self] in self?.outputSubscriptions -= 1 }).eraseToAnyPublisher()
    }
    func start(displayID: CGDirectDisplayID, region: CGRect?, options: RecordingOptions, delay: TimeInterval) async throws {
        calls.append("start")
        output.send(nil)
        if delay > 0 {
            controlState = RecordingControlState(isStarting: true, countdown: Int(delay))
            try await withCheckedThrowingContinuation { startContinuation = $0 }
        }
        controlState = RecordingControlState(isRecording: true)
    }
    func pause() async throws { try await transition(paused: true) }
    func resume() async throws { try await transition(paused: false) }
    private func transition(paused: Bool) async throws {
        calls.append(paused ? "pause" : "resume")
        if holdPause { try await withCheckedThrowingContinuation { pauseContinuation = $0 } }
        controlState.isPaused = paused
        onPauseTransitionCompleted?(paused)
    }
    func completePause(failure: CommandFailure? = nil) {
        let continuation = pauseContinuation
        pauseContinuation = nil
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
    }
    func closeInputAdmissionForStop() {
        admissionCloseCount += 1
        onCloseInputAdmission?()
    }
    func stop() async throws -> URL {
        calls.append("stop")
        concurrentStop = concurrentStop || pauseContinuation != nil
        controlState = RecordingControlState(isStopping: true)
        if holdStop { try await withCheckedThrowingContinuation { stopContinuation = $0 } }
        if let stopFailure {
            controlState = RecordingControlState(hasPendingTake: true)
            throw stopFailure
        }
        output.send(savedURL)
        controlState = RecordingControlState()
        return savedURL
    }
    func completeStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }
    func restart(discardUnfinished: Bool, delay: TimeInterval) async throws -> URL? {
        calls.append(discardUnfinished ? "discard-restart" : "save-restart")
        controlState = RecordingControlState(isRestarting: true)
        if !discardUnfinished { output.send(savedURL) }
        if restartFailure {
            controlState = RecordingControlState()
            throw CommandFailure.restart
        }
        controlState = RecordingControlState(isRecording: true)
        return discardUnfinished ? nil : savedURL
    }
    func cancel() async {
        calls.append("cancel")
        cancelCount += 1
        controlState = RecordingControlState()
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }
    func retryPendingTakePreservation(presentRecovery: Bool) async throws {
        preservationCalls += 1
        controlState = RecordingControlState()
    }
}

@MainActor
private final class TransportProbe: RecordingTransportPresenting {
    var actions: RecordingTransportActions?
    var snapshot: RecordingTransportSnapshot?
    var showCount = 0
    var placementCount = 0
    var teardownCount = 0
    var preservedPosition = false
    var placementPreservation: [Bool] = []
    func show(snapshot: RecordingTransportSnapshot, anchor: CGRect, visibleFrame: CGRect) {
        showCount += 1
        self.snapshot = snapshot
    }
    func update(snapshot: RecordingTransportSnapshot, actions: RecordingTransportActions?) {
        self.snapshot = snapshot
        if let actions { self.actions = actions }
    }
    func updatePlacement(anchor: CGRect, visibleFrame: CGRect, preservePosition: Bool) {
        placementCount += 1
        preservedPosition = preservePosition
        placementPreservation.append(preservePosition)
    }
    func hide() { }
    func teardown() { teardownCount += 1; actions = nil }
}

@MainActor
private final class CommandSelector {
    var continuation: CheckedContinuation<CGRect?, Error>?
    var cancellationObserved = false
    var finishOnCancel = true
    var drained = false

    func select() async throws -> CGRect? {
        defer { drained = true }
        // Deliberately omit a post-result cancellation check here: the shared
        // command owner must enforce its own barrier before entering capture.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in
                self.cancellationObserved = true
                if self.finishOnCancel { self.finish(.failure(CaptureError.cancelled)) }
            }
        }
    }

    func finish(_ result: Result<CGRect?, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
