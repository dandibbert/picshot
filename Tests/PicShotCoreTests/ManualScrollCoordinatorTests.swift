import XCTest
@testable import PicShotCore

/// Synthetic passive captures only. These tests never read a screen, post input, or alter TCC.
@MainActor
final class ManualScrollCoordinatorTests: XCTestCase {
    private enum Failure: Error, LocalizedError, Equatable {
        case permission, disk
        var errorDescription: String? { self == .permission ? "Screen Recording denied" : "Disk full" }
    }

    private final class Driver: ManualScrollDriver {
        var observations: [ManualScrollObservation] = []
        var lastObservation: ManualScrollObservation?
        var pendingObservation: ManualScrollObservation?
        var acceptedObservations: [ManualScrollObservation] = []
        var permissionDenied = false
        var validationError: Error?
        var captureCount = 0
        var acceptCount = 0
        var validations = 0
        var discarded = 0
        var activeCaptures = 0
        var peakCaptures = 0
        var captureBody: (() async throws -> ManualScrollObservation)?
        var acceptBody: (() async throws -> ManualScrollSample)?
        func checkPermission() throws { if permissionDenied { throw Failure.permission } }
        func validateTarget() throws {
            validations += 1
            try checkPermission()
            if let validationError { throw validationError }
        }
        func capture() async throws -> ManualScrollObservation {
            captureCount += 1
            activeCaptures += 1; peakCaptures = max(peakCaptures, activeCaptures)
            defer { activeCaptures -= 1 }
            let next: ManualScrollObservation
            if let captureBody { next = try await captureBody() }
            else if !observations.isEmpty { next = observations.removeFirst() }
            else { next = try XCTUnwrap(lastObservation) }
            // Deliberately allow stale pending data so tests verify coordinator draining.
            pendingObservation = next; lastObservation = next
            return next
        }
        func acceptStableCapture() async throws -> ManualScrollSample {
            acceptCount += 1
            if let acceptBody { return try await acceptBody() }
            acceptedObservations.append(try XCTUnwrap(pendingObservation))
            return .accepted(totalFrames: acceptedObservations.count)
        }
        func discardPendingCapture() { pendingObservation = nil; discarded += 1 }
    }

    private func observation(_ value: UInt8, width: Int = 80, height: Int = 120) throws -> ManualScrollObservation {
        try ManualScrollObservation(width: width, height: height, rgbaSHA256: Array(repeating: value, count: 32))
    }

    private func config(samples: Int = 8) -> ManualScrollConfiguration {
        var result = ManualScrollConfiguration()
        result.countdownSeconds = 0
        result.maximumSamples = samples
        return result
    }

    private func fastSleep(_ seconds: TimeInterval) async throws {
        // Long operation watchdogs stay suspended. Sampling/countdown yield deterministically.
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

    func testObservationRejectsUnboundedGeometryAndMalformedDigest() throws {
        for (width, height, bytes) in [(0, 1, 32), (1, -1, 32), (Int.max, Int.max, 32),
                                       (32_769, 1, 32), (6_001, 4_000, 32), (80, 120, 31), (80, 120, 33)] {
            XCTAssertThrowsError(try ManualScrollObservation(width: width, height: height,
                                                             rgbaSHA256: Array(repeating: 0, count: bytes)))
        }
        XCTAssertNoThrow(try ManualScrollObservation(width: 6_000, height: 4_000, rgbaSHA256: Array(repeating: 0, count: 32)))
        XCTAssertNotEqual(try observation(1), try observation(1, width: 81))
        XCTAssertNotEqual(try observation(1), try observation(2))
    }

    func testConstructionAndCancelBeforeStartPerformNoCaptureOrValidation() async throws {
        let driver = Driver()
        let coordinator = ManualScrollCoordinator(driver: driver, sleep: fastSleep)
        await Task.yield()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(driver.captureCount, 0); XCTAssertEqual(driver.validations, 0)
        coordinator.cancel(); coordinator.start(); coordinator.resume()
        await Task.yield()
        XCTAssertEqual(coordinator.state, .finished(.stopped))
        XCTAssertEqual(driver.captureCount, 0); XCTAssertEqual(driver.acceptCount, 0)
    }

    func testConsecutiveStabilityAndStationarySuppressionRequireNoFurtherClicks() async throws {
        let driver = Driver(), a = try observation(1), b = try observation(2), c = try observation(3)
        driver.observations = [a, b, b, b, c, c, c, c]
        let coordinator = ManualScrollCoordinator(configuration: config(), driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.sampleLimit))
        XCTAssertEqual(driver.acceptedObservations, [b, c], "Unstable first sample and stationary repeats never append")
        XCTAssertEqual(coordinator.acceptedFrames, 2); XCTAssertEqual(coordinator.sampledFrames, 8)
        XCTAssertEqual(driver.peakCaptures, 1); XCTAssertNil(driver.pendingObservation)
    }

    func testStableSampleCountIsConsecutiveAndFullColorSignatureMatters() async throws {
        let driver = Driver(), a = try observation(1), colorChange = try observation(2)
        driver.observations = [a, a, colorChange, colorChange, colorChange]
        var configuration = config(samples: 5); configuration.stableSamples = 3
        let coordinator = ManualScrollCoordinator(configuration: configuration, driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(driver.acceptedObservations, [colorChange])
        XCTAssertEqual(driver.acceptCount, 1)
    }

    func testDuplicateDoesNotAppendOrStopMonitoring() async throws {
        let driver = Driver(), a = try observation(1), b = try observation(2)
        driver.observations = [a, a, a, b, b, b]
        driver.acceptBody = {
            if driver.acceptCount == 1 { throw ScrollStitchError.duplicate }
            return .accepted(totalFrames: 2)
        }
        let coordinator = ManualScrollCoordinator(configuration: config(samples: 6), driver: driver,
                                                   initialFrameCount: 1, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(driver.acceptCount, 2)
        XCTAssertEqual(coordinator.acceptedFrames, 2)
        XCTAssertEqual(coordinator.state, .finished(.sampleLimit))
        driver.acceptBody = nil
    }

    func testPersistentMotionPausesWithRecoveryGuidanceWithoutAccepting() async throws {
        let driver = Driver()
        driver.observations = try (1...5).map { try observation(UInt8($0)) }
        var configuration = config(); configuration.maximumUnstableSamples = 4
        let coordinator = ManualScrollCoordinator(configuration: configuration, driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        guard case .recoverable(let message) = coordinator.state else { return XCTFail("Changing screen must pause") }
        XCTAssertTrue(message.contains("停止滚动")); XCTAssertTrue(message.contains("动画"))
        XCTAssertEqual(driver.captureCount, 4); XCTAssertEqual(driver.acceptCount, 0)
        XCTAssertTrue(coordinator.canResume); XCTAssertNil(driver.pendingObservation)
    }

    func testUncertainSeamsAreRecoverableButStorageAndPixelLimitsAreTerminal() async throws {
        let recoverableFailures: [Error] = [ScrollStitchError.noOverlap, ScrollStitchError.ambiguousOverlap,
                                           ScrollStitchError.insufficientTexture, ScrollStitchError.differentDimensions,
                                           ManualScrollRecoveryError(message: "Target is obscured")]
        for failure in recoverableFailures {
            let driver = Driver(); driver.observations = [try observation(1)]
            driver.acceptBody = { throw failure }
            let coordinator = ManualScrollCoordinator(configuration: config(), driver: driver,
                                                       initialFrameCount: 2, sleep: fastSleep)
            coordinator.start()
            try await waitUntil { !coordinator.hasPendingOperation }
            XCTAssertEqual(coordinator.state, .recoverable(failure.localizedDescription))
            XCTAssertTrue(coordinator.canResume); XCTAssertEqual(coordinator.acceptedFrames, 2)
            XCTAssertEqual(driver.captureCount, 2); XCTAssertEqual(driver.acceptCount, 1)
        }
        let terminalFailures: [Error] = [ScrollStitchError.pixelLimit, Failure.disk]
        for failure in terminalFailures {
            let driver = Driver(); driver.observations = [try observation(1)]
            driver.acceptBody = { throw failure }
            let coordinator = ManualScrollCoordinator(configuration: config(), driver: driver,
                                                       initialFrameCount: 2, sleep: fastSleep)
            coordinator.start()
            try await waitUntil { !coordinator.hasPendingOperation }
            XCTAssertEqual(coordinator.state, .failed(failure.localizedDescription))
            XCTAssertFalse(coordinator.canResume); XCTAssertEqual(coordinator.acceptedFrames, 2)
            XCTAssertNil(driver.pendingObservation)
        }
    }

    func testRecoverableTargetValidationDoesNotCaptureAndCanRetry() async throws {
        let driver = Driver()
        driver.validationError = ManualScrollRecoveryError(message: "Target moved")
        driver.observations = [try observation(1)]
        let coordinator = ManualScrollCoordinator(configuration: config(samples: 2), driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .recoverable("Target moved"))
        XCTAssertEqual(driver.captureCount, 0)
        driver.validationError = nil
        coordinator.resume()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(driver.acceptCount, 1); XCTAssertEqual(coordinator.acceptedFrames, 1)
    }

    func testFrameAndSampleBudgetsCannotBeResetByResume() async throws {
        let driver = Driver(); driver.observations = [try observation(1)]
        var configuration = config(); configuration.maximumFrames = 2
        driver.acceptBody = { .accepted(totalFrames: 2) }
        let coordinator = ManualScrollCoordinator(configuration: configuration, driver: driver,
                                                   initialFrameCount: 1, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.frameLimit)); XCTAssertEqual(driver.captureCount, 2)
        coordinator.resume(); coordinator.start()
        XCTAssertEqual(driver.captureCount, 2)
        let full = ManualScrollCoordinator(driver: Driver(), initialFrameCount: 100, sleep: fastSleep)
        full.start()
        try await waitUntil { !full.hasPendingOperation }
        XCTAssertEqual(full.state, .finished(.frameLimit)); XCTAssertEqual(full.sampledFrames, 0)
    }

    func testPermissionDenialAndInvalidConfigurationStartNothing() async throws {
        let driver = Driver(); driver.permissionDenied = true
        let denied = ManualScrollCoordinator(driver: driver, sleep: fastSleep)
        denied.start()
        XCTAssertEqual(denied.state, .failed("Screen Recording denied")); XCTAssertEqual(driver.captureCount, 0)
        var configurations = [ManualScrollConfiguration]()
        var invalid = config(); invalid.maximumFrames = 101; configurations.append(invalid)
        invalid = config(); invalid.sampleInterval = .nan; configurations.append(invalid)
        invalid = config(); invalid.sampleInterval = 0; configurations.append(invalid)
        invalid = config(); invalid.operationTimeout = .infinity; configurations.append(invalid)
        invalid = config(); invalid.stableSamples = 1; configurations.append(invalid)
        invalid = config(); invalid.maximumSamples = Int.max; configurations.append(invalid)
        for configuration in configurations {
            let bad = ManualScrollCoordinator(configuration: configuration, driver: Driver(), sleep: fastSleep)
            bad.start()
            XCTAssertEqual(bad.state, .failed("连续手动捕获安全限制无效。")); XCTAssertFalse(bad.hasPendingOperation)
        }
        let badCount = ManualScrollCoordinator(driver: Driver(), initialFrameCount: -1, sleep: fastSleep)
        badCount.start()
        XCTAssertEqual(badCount.state, .failed("连续手动捕获安全限制无效。"))
    }

    func testPauseDrainsLateCaptureBeforeMoveAndResume() async throws {
        let driver = Driver(), a = try observation(1), moved = try observation(2)
        var held: CheckedContinuation<ManualScrollObservation, Never>?
        driver.captureBody = { await withCheckedContinuation { held = $0 } }
        let coordinator = ManualScrollCoordinator(configuration: config(samples: 3), driver: driver,
                                                   initialFrameCount: 1, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { held != nil }
        coordinator.pause(); coordinator.resume()
        XCTAssertEqual(coordinator.state, .paused); XCTAssertFalse(coordinator.canResume)
        XCTAssertTrue(coordinator.hasPendingOperation); XCTAssertEqual(driver.captureCount, 1)
        held?.resume(returning: a); held = nil
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertTrue(coordinator.canResume); XCTAssertNil(driver.pendingObservation)
        XCTAssertEqual(coordinator.acceptedFrames, 1); XCTAssertEqual(driver.acceptCount, 0)
        driver.captureBody = nil; driver.observations = [moved, moved]
        driver.acceptBody = { .accepted(totalFrames: 2) }
        coordinator.resume()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(driver.captureCount, 3); XCTAssertEqual(driver.acceptCount, 1)
        XCTAssertEqual(driver.peakCaptures, 1); XCTAssertEqual(coordinator.acceptedFrames, 2)
        XCTAssertEqual(coordinator.state, .finished(.sampleLimit))
    }

    func testResumeResamplesStationaryViewportWithoutResettingAcceptedAnchor() async throws {
        let driver = Driver(); driver.observations = [try observation(1)]
        let coordinator = ManualScrollCoordinator(configuration: config(samples: 4), driver: driver, sleep: fastSleep)
        var paused = false
        coordinator.onChange = { state in
            if state == .waiting && !paused { paused = true; coordinator.pause() }
        }
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(driver.acceptCount, 1); XCTAssertEqual(coordinator.acceptedFrames, 1)
        driver.acceptBody = { .duplicate }
        coordinator.resume()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(driver.acceptCount, 2); XCTAssertEqual(coordinator.acceptedFrames, 1)
        XCTAssertEqual(driver.captureCount, 4)
        coordinator.onChange = nil
    }

    func testStopDuringNoncooperativeAcceptanceRejectsLateCountAndDrains() async throws {
        let driver = Driver(); driver.observations = [try observation(1)]
        var held: CheckedContinuation<ManualScrollSample, Never>?
        driver.acceptBody = { await withCheckedContinuation { held = $0 } }
        let coordinator = ManualScrollCoordinator(configuration: config(), driver: driver,
                                                   initialFrameCount: 1, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { held != nil }
        coordinator.stop(); coordinator.stop(); coordinator.resume()
        XCTAssertEqual(coordinator.state, .finished(.stopped)); XCTAssertTrue(coordinator.hasPendingOperation)
        held?.resume(returning: .accepted(totalFrames: 2)); held = nil
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .finished(.stopped)); XCTAssertEqual(coordinator.acceptedFrames, 1)
        XCTAssertEqual(driver.captureCount, 2); XCTAssertEqual(driver.acceptCount, 1)
        XCTAssertNil(driver.pendingObservation)
    }

    func testSynchronousStopNotificationsCannotStartCaptureOrAcceptance() async throws {
        for stopState in [ManualScrollState.sampling, .matching] {
            let driver = Driver(); driver.observations = [try observation(1)]
            let coordinator = ManualScrollCoordinator(configuration: config(), driver: driver, sleep: fastSleep)
            coordinator.onChange = { state in if state == stopState { coordinator.stop() } }
            coordinator.start()
            try await waitUntil { !coordinator.hasPendingOperation }
            XCTAssertEqual(coordinator.state, .finished(.stopped)); XCTAssertEqual(driver.acceptCount, 0)
            XCTAssertEqual(driver.captureCount, stopState == .sampling ? 0 : 2)
            coordinator.onChange = nil
        }
    }

    func testCountdownAndPausedTimeConsumeOriginalDeadline() async throws {
        let driver = Driver(); driver.observations = [try observation(1)]
        var instant: TimeInterval = 0
        var configuration = config(); configuration.countdownSeconds = 3; configuration.maximumDuration = 2
        let countdown = ManualScrollCoordinator(configuration: configuration, driver: driver, now: { instant },
                                                sleep: { seconds in instant += seconds; await Task.yield() })
        countdown.start()
        try await waitUntil { !countdown.hasPendingOperation }
        XCTAssertEqual(countdown.state, .finished(.timeLimit)); XCTAssertEqual(driver.captureCount, 0)
        instant = 0; configuration = config(); configuration.maximumDuration = 30
        let paused = ManualScrollCoordinator(configuration: configuration, driver: driver, now: { instant }, sleep: fastSleep)
        paused.onChange = { state in if state == .waiting { paused.pause() } }
        paused.start()
        try await waitUntil { !paused.hasPendingOperation }
        instant = 31; paused.resume()
        try await waitUntil { !paused.hasPendingOperation }
        XCTAssertEqual(paused.state, .finished(.timeLimit)); XCTAssertEqual(driver.captureCount, 2)
        paused.onChange = nil
    }

    func testTimeoutRejectsNoncooperativeCaptureAndDoesNotReleaseWhileInUse() async throws {
        let driver = Driver(), a = try observation(1)
        var held: CheckedContinuation<ManualScrollObservation, Never>?
        driver.captureBody = { await withCheckedContinuation { held = $0 } }
        var configuration = config(); configuration.operationTimeout = 0.02
        let coordinator = ManualScrollCoordinator(configuration: configuration, driver: driver,
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        coordinator.start()
        try await waitUntil { held != nil }
        try await waitUntil { if case .failed = coordinator.state { return true }; return false }
        XCTAssertTrue(coordinator.hasPendingOperation); XCTAssertFalse(coordinator.canResume)
        XCTAssertEqual(driver.discarded, 0, "An active native job owns its pending capture until it drains")
        held?.resume(returning: a); held = nil
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .failed("屏幕捕获或匹配超时，已保留捕获内容。"))
        XCTAssertEqual(driver.acceptCount, 0); XCTAssertNil(driver.pendingObservation)
    }

    func testRevokedPermissionCannotReachNextCapture() async throws {
        let driver = Driver(); driver.observations = [try observation(1)]
        let coordinator = ManualScrollCoordinator(configuration: config(), driver: driver, sleep: fastSleep)
        coordinator.onChange = { state in if state == .waiting { driver.permissionDenied = true } }
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .failed("Screen Recording denied"))
        XCTAssertEqual(driver.captureCount, 2); XCTAssertEqual(coordinator.acceptedFrames, 1)
        coordinator.onChange = nil
    }

    func testStartCountsDownButExplicitResumeUsesFreshStableSamplesImmediately() async throws {
        let driver = Driver(); driver.observations = [try observation(1)]
        var configuration = config(samples: 4); configuration.countdownSeconds = 3
        let coordinator = ManualScrollCoordinator(configuration: configuration, driver: driver, sleep: fastSleep)
        var countdowns: [Int] = [], didPause = false
        coordinator.onChange = { state in
            if case .countdown(let value) = state {
                countdowns.append(value); XCTAssertEqual(driver.captureCount, 0)
            }
            if state == .waiting && !didPause { didPause = true; coordinator.pause() }
        }
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertTrue(countdowns.contains(3)); XCTAssertTrue(countdowns.contains(2)); XCTAssertTrue(countdowns.contains(1))
        let originalCountdowns = countdowns
        driver.acceptBody = { .duplicate }
        coordinator.resume()
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(countdowns, originalCountdowns)
        XCTAssertEqual(driver.captureCount, 4); XCTAssertEqual(driver.acceptCount, 2)
        coordinator.onChange = nil
    }

    func testIncompleteStabilityRunsCannotResetInstabilityWorkBudget() async throws {
        let driver = Driver(), a = try observation(1), b = try observation(2)
        driver.observations = [a, a, b, b, a, a]
        var configuration = config(); configuration.stableSamples = 3; configuration.maximumUnstableSamples = 5
        let coordinator = ManualScrollCoordinator(configuration: configuration, driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        guard case .recoverable = coordinator.state else { return XCTFail("Interrupted stable runs must still be bounded") }
        XCTAssertEqual(driver.captureCount, 5); XCTAssertEqual(driver.acceptCount, 0)
    }

    func testUnexpectedSDKCancellationRemainsRecoverable() async throws {
        let driver = Driver(); driver.captureBody = { throw CancellationError() }
        let coordinator = ManualScrollCoordinator(configuration: config(), driver: driver, sleep: fastSleep)
        coordinator.start()
        try await waitUntil { !coordinator.hasPendingOperation }
        guard case .recoverable = coordinator.state else { return XCTFail("SDK cancellation cannot leave a dead running state") }
        XCTAssertTrue(coordinator.canResume); XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(driver.acceptCount, 0); XCTAssertNil(driver.pendingObservation)
    }

    func testAcceptanceTimeoutAlsoDrainsBeforeDiscardingAndRejectsLateCount() async throws {
        let driver = Driver(); driver.observations = [try observation(1)]
        var held: CheckedContinuation<ManualScrollSample, Never>?
        driver.acceptBody = { await withCheckedContinuation { held = $0 } }
        var configuration = config(); configuration.operationTimeout = 0.02; configuration.sampleInterval = 0.05
        let coordinator = ManualScrollCoordinator(configuration: configuration, driver: driver,
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        coordinator.start()
        try await waitUntil { held != nil }
        try await waitUntil { if case .failed = coordinator.state { return true }; return false }
        XCTAssertTrue(coordinator.hasPendingOperation); XCTAssertNotNil(driver.pendingObservation)
        held?.resume(returning: .accepted(totalFrames: 1)); held = nil
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.acceptedFrames, 0); XCTAssertNil(driver.pendingObservation)
        XCTAssertEqual(coordinator.state, .failed("屏幕捕获或匹配超时，已保留捕获内容。"))
    }
}
