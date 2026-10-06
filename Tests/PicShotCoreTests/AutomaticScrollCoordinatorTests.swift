import XCTest
@testable import PicShotCore

/// Synthetic driver coverage only: no system input, TCC changes, or live app capture.
@MainActor
final class AutomaticScrollCoordinatorTests: XCTestCase {
    private enum Failure: Error, LocalizedError {
        case permission, targetChanged, overlap, disk
        var errorDescription: String? {
            switch self {
            case .permission: return "Accessibility denied"
            case .targetChanged: return "Target changed"
            case .overlap: return "No reliable overlap"
            case .disk: return "Disk full"
            }
        }
    }

    private final class Driver: AutomaticScrollDriver {
        var events: [(ScrollAxis, Int)] = []
        var captureCount = 0
        var validations = 0
        var permissionDenied = false
        var targetChanged = false
        var results: [Result<AutomaticScrollSample, Failure>] = [.success(.accepted(totalFrames: 1))]
        var captureBody: (() async throws -> AutomaticScrollSample)?
        var onScroll: (() -> Void)?
        func checkPermission() throws { if permissionDenied { throw Failure.permission } }
        func validateTarget() throws {
            validations += 1
            try checkPermission()
            if targetChanged { throw Failure.targetChanged }
        }
        func scroll(axis: ScrollAxis, points: Int) throws { events.append((axis, points)); onScroll?() }
        func capture() async throws -> AutomaticScrollSample {
            captureCount += 1
            if let captureBody { return try await captureBody() }
            if results.isEmpty { return .duplicate }
            return try results.removeFirst().get()
        }
    }

    private func fastSleep(_ seconds: TimeInterval) async throws {
        // Normal countdown/settling yields without wall time. The independent watchdog
        // remains suspended until cancellation, so it cannot overtake an immediate fixture.
        if seconds >= 10 { try await Task.sleep(nanoseconds: 10_000_000_000) }
        else { try Task.checkCancellation(); await Task.yield() }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testNoInputOrCaptureBeforeExplicitStart() async throws {
        let driver = Driver()
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        await Task.yield()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(driver.captureCount, 0)
        XCTAssertTrue(driver.events.isEmpty)
        XCTAssertEqual(driver.validations, 0)
    }

    func testCountdownPrecedesBaselineAndBoundedDuplicateRetries() async throws {
        let driver = Driver()
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        var countdowns: [Int] = []
        coordinator.onChange = { state in
            if case .countdown(let value) = state {
                countdowns.append(value)
                XCTAssertTrue(driver.events.isEmpty)
                XCTAssertEqual(driver.captureCount, 0)
            }
        }
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.noMovement))
        XCTAssertTrue(countdowns.contains(3)); XCTAssertTrue(countdowns.contains(2)); XCTAssertTrue(countdowns.contains(1))
        XCTAssertEqual(driver.events.count, 2)
        XCTAssertEqual(driver.captureCount, 7) // Baseline + 2 × (sample + 2 settle retries).
        XCTAssertEqual(coordinator.acceptedFrames, 1)
    }

    func testHorizontalEventsUseConfiguredBoundedStep() async throws {
        let driver = Driver()
        var config = AutomaticScrollConfiguration(); config.stepPoints = 47; config.maximumScrollEvents = 1
        let coordinator = AutomaticScrollCoordinator(axis: .horizontal, configuration: config, driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(driver.events.count, 1)
        XCTAssertEqual(driver.events.first?.0, .horizontal)
        XCTAssertEqual(driver.events.first?.1, 47)
        XCTAssertEqual(coordinator.state, .finished(.eventLimit))
    }

    func testLateSettlingFrameIsAcceptedWithoutExtraScroll() async throws {
        let driver = Driver()
        driver.results = [.success(.accepted(totalFrames: 1)), .success(.duplicate), .success(.accepted(totalFrames: 2))]
        var config = AutomaticScrollConfiguration(); config.maximumFrames = 2
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, configuration: config, driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.frameLimit))
        XCTAssertEqual(driver.events.count, 1)
        XCTAssertEqual(driver.captureCount, 3)
    }

    func testFrameLimitFromExistingManualFramesPostsNothing() async throws {
        let driver = Driver(); driver.results = [.success(.duplicate)]
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, initialFrameCount: 100, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.frameLimit))
        XCTAssertTrue(driver.events.isEmpty)
        XCTAssertEqual(driver.captureCount, 0)
    }

    func testPermissionDenialAndInvalidBoundsStartNothing() async throws {
        let driver = Driver(); driver.permissionDenied = true
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        coordinator.start()
        XCTAssertEqual(coordinator.state, .failed("Accessibility denied"))
        XCTAssertFalse(coordinator.hasPendingOperation)
        XCTAssertTrue(driver.events.isEmpty); XCTAssertEqual(driver.captureCount, 0)
        var config = AutomaticScrollConfiguration(); config.stepPoints = Int.max
        let invalid = AutomaticScrollCoordinator(axis: .vertical, configuration: config, driver: Driver(), sleep: fastSleep)
        invalid.start()
        XCTAssertEqual(invalid.state, .failed("Invalid automatic-scroll safety limits."))
    }

    func testStopDuringCountdownCannotPostOrCapture() async throws {
        let driver = Driver()
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        coordinator.start(); coordinator.stop(); coordinator.stop()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.stopped))
        XCTAssertTrue(driver.events.isEmpty); XCTAssertEqual(driver.captureCount, 0)
    }

    func testSynchronousStopAtScrollingNotificationPreventsEvent() async throws {
        let driver = Driver()
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        coordinator.onChange = { state in if state == .scrolling { coordinator.stop() } }
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.stopped))
        XCTAssertTrue(driver.events.isEmpty)
        coordinator.onChange = nil
    }

    func testPauseResumeRecapturesBaselineAndWaitsForOldCaptureToDrain() async throws {
        let driver = Driver()
        var held: CheckedContinuation<AutomaticScrollSample, Never>?
        driver.captureBody = { await withCheckedContinuation { held = $0 } }
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { held != nil }
        coordinator.pause(); coordinator.resume() // A late old result must drain first.
        XCTAssertEqual(coordinator.state, .paused)
        XCTAssertTrue(coordinator.hasPendingOperation)
        held?.resume(returning: .accepted(totalFrames: 91)); held = nil
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.acceptedFrames, 0)
        XCTAssertTrue(driver.events.isEmpty)
        driver.captureBody = nil
        driver.results = [.success(.accepted(totalFrames: 1))]
        var resumedCountdown = false
        coordinator.onChange = { state in
            if case .countdown = state { resumedCountdown = true }
            if state == .scrolling { coordinator.stop() }
        }
        coordinator.resume()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertTrue(resumedCountdown)
        XCTAssertEqual(driver.captureCount, 2)
        XCTAssertEqual(coordinator.acceptedFrames, 1)
        XCTAssertTrue(driver.events.isEmpty)
        coordinator.onChange = nil
    }

    func testStopIgnoresNoncooperativeLateCapture() async throws {
        let driver = Driver()
        var held: CheckedContinuation<AutomaticScrollSample, Never>?
        driver.captureBody = { await withCheckedContinuation { held = $0 } }
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { held != nil }
        coordinator.stop()
        held?.resume(returning: .accepted(totalFrames: 42)); held = nil
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.stopped))
        XCTAssertEqual(coordinator.acceptedFrames, 0)
        XCTAssertTrue(driver.events.isEmpty)
    }

    func testTargetChangesAndRevokedPermissionStopBeforeNextEvent() async throws {
        for revokePermission in [false, true] {
            let driver = Driver()
            driver.onScroll = {
                if revokePermission { driver.permissionDenied = true } else { driver.targetChanged = true }
            }
            let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
            coordinator.start()
            try await waitUntil { !coordinator.hasPendingOperation }
            XCTAssertEqual(driver.events.count, 1)
            XCTAssertEqual(driver.captureCount, 1)
            XCTAssertEqual(coordinator.state, .failed(revokePermission ? "Accessibility denied" : "Target changed"))
            driver.onScroll = nil
        }
    }

    func testOverlapAndStorageFailuresNeverAppendOrRetryInput() async throws {
        for failure in [Failure.overlap, Failure.disk] {
            let driver = Driver()
            driver.results = [.success(.accepted(totalFrames: 1)), .failure(failure)]
            let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
            coordinator.start()
            try await waitUntil { !coordinator.hasPendingOperation }
            XCTAssertEqual(coordinator.state, .failed(failure.localizedDescription))
            XCTAssertEqual(driver.events.count, 1)
            XCTAssertEqual(coordinator.acceptedFrames, 1)
            XCTAssertEqual(driver.captureCount, 2)
        }
    }

    func testCancellationDuringEventDoesNotOverwriteTerminalState() async throws {
        let driver = Driver()
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        driver.onScroll = { coordinator.cancel() }
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.stopped))
        XCTAssertEqual(driver.events.count, 1)
        XCTAssertEqual(driver.captureCount, 1)
        driver.onScroll = nil
    }

    func testCancelBeforeStartPermanentlyPreventsInput() async throws {
        let driver = Driver()
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
        coordinator.cancel(); coordinator.start(); coordinator.resume()
        await Task.yield()
        XCTAssertEqual(coordinator.state, .finished(.stopped))
        XCTAssertEqual(driver.captureCount, 0)
        XCTAssertTrue(driver.events.isEmpty)
    }

    func testConservativeStitchErrorsAreVisibleWithoutBlindAppend() async throws {
        for failure in [ScrollStitchError.noOverlap, .ambiguousOverlap, .differentDimensions, .insufficientTexture, .pixelLimit] {
            let driver = Driver()
            driver.captureBody = {
                if driver.captureCount == 1 { return .accepted(totalFrames: 1) }
                throw failure
            }
            let coordinator = AutomaticScrollCoordinator(axis: .vertical, driver: driver, sleep: fastSleep)
            coordinator.start()
            try await waitUntil { !coordinator.hasPendingOperation }
            XCTAssertEqual(coordinator.state, .failed(failure.localizedDescription))
            XCTAssertEqual(coordinator.acceptedFrames, 1)
            XCTAssertEqual(driver.events.count, 1)
            driver.captureBody = nil
        }
    }

    func testDurationLimitIncludesCountdownAndPause() async throws {
        let driver = Driver()
        var clock: TimeInterval = 0
        var config = AutomaticScrollConfiguration(); config.maximumDuration = 2
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, configuration: config, driver: driver,
            now: { clock }, sleep: { seconds in clock += seconds; await Task.yield() })
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.timeLimit))
        XCTAssertTrue(driver.events.isEmpty); XCTAssertEqual(driver.captureCount, 0)
    }

    func testCaptureTimeoutIsVisibleEvenWhenDriverIgnoresCancellation() async throws {
        let driver = Driver()
        var held: CheckedContinuation<AutomaticScrollSample, Never>?
        driver.captureBody = { await withCheckedContinuation { held = $0 } }
        var config = AutomaticScrollConfiguration(); config.captureTimeout = 0.02
        let coordinator = AutomaticScrollCoordinator(axis: .vertical, configuration: config, driver: driver,
            sleep: { seconds in
                if seconds == 1 { await Task.yield() }
                else { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            })
        coordinator.start()
        try await waitUntil { held != nil }
        try await waitUntil { if case .failed = coordinator.state { return true }; return false }
        XCTAssertTrue(coordinator.hasPendingOperation)
        XCTAssertTrue(driver.events.isEmpty)
        held?.resume(returning: .accepted(totalFrames: 1)); held = nil
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.acceptedFrames, 0)
        XCTAssertEqual(coordinator.state, .failed("A screen capture timed out. Accepted frames have been kept."))
    }
}
