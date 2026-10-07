import XCTest
import Foundation
import Darwin
@testable import PicShot

final class ImageDecodeTerminationLatchTests: XCTestCase {
    func testRealFastExitHasExactlyOneMatchingCallback() throws {
        try withOwnedProcess("/usr/bin/true") { process, latch, deadline in
            XCTAssertNotNil(process.terminationHandler)
            XCTAssertEqual(latch.snapshot(), ImageDecodeTerminationObservation())
            let launched = ProcessInfo.processInfo.systemUptime
            try process.run()
            let result = try completion(process, latch, deadline)
            XCTAssertEqual(result.callbackCount, 1)
            XCTAssertEqual(result.childPID, process.processIdentifier)
            XCTAssertEqual(result.terminationStatus, 0)
            XCTAssertEqual(result.terminationReason, Process.TerminationReason.exit.rawValue)
            XCTAssertEqual(result.callbackObservedNotRunning, true)
            let entered = try XCTUnwrap(result.callbackEnteredUptimeSeconds)
            let published = try XCTUnwrap(result.callbackPublishedUptimeSeconds)
            XCTAssertGreaterThanOrEqual(entered, launched)
            XCTAssertGreaterThanOrEqual(published, entered)
            XCTAssertLessThanOrEqual(published, ProcessInfo.processInfo.systemUptime)
            // Publication is persistent, not a consumable one-waiter signal.
            XCTAssertTrue(latch.wait(untilUptimeSeconds: ProcessInfo.processInfo.systemUptime))
            XCTAssertEqual(try latch.validateCompletion(for: process), result)
            let bytes = try JSONEncoder().encode(result)
            XCTAssertLessThan(bytes.count, 1_024)
            XCTAssertEqual(try JSONDecoder().decode(ImageDecodeTerminationObservation.self, from: bytes), result)
        }
    }

    func testRealNonzeroExitIsCompletionEvidenceNotSuccess() throws {
        try withOwnedProcess("/usr/bin/false") { process, latch, deadline in
            try process.run()
            let result = try completion(process, latch, deadline)
            XCTAssertEqual(result.callbackCount, 1)
            XCTAssertEqual(result.terminationStatus, 1)
            XCTAssertEqual(result.terminationReason, Process.TerminationReason.exit.rawValue)
        }
    }

    func testCallbackValidationDoesNotReleaseCallerHeldAdmissionLease() throws {
        let admission = NativeExportAdmission.shared
        let lease = try XCTUnwrap(admission.acquire(), "The test must own its admission lease")
        defer { admission.release(lease) }
        try withOwnedProcess("/usr/bin/true") { process, latch, deadline in
            try process.run()
            _ = try completion(process, latch, deadline)
            let unexpectedLease = admission.acquire()
            defer { if let unexpectedLease { admission.release(unexpectedLease) } }
            XCTAssertNil(unexpectedLease, "Callback evidence must not release the caller's admission lease")
        }
    }

    func testRealLaunchFailureDoesNotFabricateCallback() throws {
        let missing = "/nonexistent/PicShot-Termination-Latch-" + UUID().uuidString
        try withOwnedProcess(missing) { process, latch, deadline in
            XCTAssertThrowsError(try process.run())
            XCTAssertFalse(process.isRunning)
            XCTAssertFalse(latch.wait(untilUptimeSeconds: min(deadline, ProcessInfo.processInfo.systemUptime + 0.05)))
            XCTAssertEqual(latch.snapshot(), ImageDecodeTerminationObservation())
            assertError(.callbackMissing) { try latch.validateCompletion(for: process) }
        }
    }

    func testRealOwnedSleepTerminationIsBoundedAndMatching() throws {
        try withOwnedProcess("/bin/sleep", arguments: ["10"]) { process, latch, deadline in
            try process.run()
            XCTAssertTrue(process.isRunning)
            XCTAssertEqual(latch.snapshot().callbackCount, 0)
            process.terminate()
            let result = try completion(process, latch, deadline)
            XCTAssertEqual(result.callbackCount, 1)
            XCTAssertEqual(result.terminationReason, Process.TerminationReason.uncaughtSignal.rawValue)
            XCTAssertEqual(result.terminationStatus, SIGTERM)
        }
    }

    func testRunningOwnedChildAndMissingCallbackAreRejected() throws {
        try withOwnedProcess("/bin/sleep", arguments: ["10"]) { process, latch, _ in
            try process.run()
            assertError(.callbackMissing) { try latch.validateCompletion(for: process) }
            let injected = ImageDecodeTerminationLatch()
            injected.recordCallback(childPID: process.processIdentifier, terminationStatus: 0,
                terminationReason: Process.TerminationReason.exit.rawValue,
                observedNotRunning: true, enteredUptimeSeconds: ProcessInfo.processInfo.systemUptime)
            assertError(.processStillRunning) { try injected.validateCompletion(for: process) }
            XCTAssertTrue(process.isRunning, "Validation must not terminate or release the owned child")
        }
    }

    func testDuplicateCallbackPreservesFirstScalarsAndRejectsCompletion() throws {
        try withOwnedProcess("/usr/bin/true") { process, latch, deadline in
            try process.run()
            let first = try completion(process, latch, deadline)
            latch.recordCallback(childPID: Int32.max, terminationStatus: 99,
                terminationReason: Process.TerminationReason.uncaughtSignal.rawValue,
                observedNotRunning: false, enteredUptimeSeconds: ProcessInfo.processInfo.systemUptime)
            var expected = first
            expected.callbackCount = 2
            XCTAssertEqual(latch.snapshot(), expected)
            XCTAssertTrue(latch.wait(untilUptimeSeconds: deadline))
            assertError(.multipleCallbacks(2)) { try latch.validateCompletion(for: process) }
        }
    }

    func testMismatchedPIDStatusAndReasonAreExplicitlyRejected() throws {
        try withOwnedProcess("/usr/bin/true") { process, actual, deadline in
            try process.run()
            _ = try completion(process, actual, deadline)
            let pid = process.processIdentifier
            let otherPID: Int32 = pid == Int32.max ? pid - 1 : pid + 1
            let exit = Process.TerminationReason.exit.rawValue
            let signal = Process.TerminationReason.uncaughtSignal.rawValue
            for (recordedPID, status, reason, error) in [
                (otherPID, Int32(0), exit, ImageDecodeTerminationLatchError.processIdentifierMismatch(expected: pid, observed: otherPID)),
                (pid, Int32(19), exit, .terminationStatusMismatch(expected: 0, observed: 19)),
                (pid, Int32(0), signal, .terminationReasonMismatch(expected: exit, observed: signal))
            ] {
                let injected = ImageDecodeTerminationLatch()
                injected.recordCallback(childPID: recordedPID, terminationStatus: status, terminationReason: reason,
                    observedNotRunning: true, enteredUptimeSeconds: ProcessInfo.processInfo.systemUptime)
                assertError(error) { try injected.validateCompletion(for: process) }
            }
        }
    }

    func testMalformedScalarRecordsAreExplicitlyRejected() throws {
        try withOwnedProcess("/usr/bin/true") { process, actual, deadline in
            try process.run()
            _ = try completion(process, actual, deadline)
            let pid = process.processIdentifier, exit = Process.TerminationReason.exit.rawValue
            let now = ProcessInfo.processInfo.systemUptime
            let cases: [(Int32, Int32?, Int?, Bool, Double, ImageDecodeTerminationLatchError)] = [
                (0, 0, exit, true, now, .malformedObservation),
                (pid, nil, exit, true, now, .malformedObservation),
                (pid, 0, nil, true, now, .malformedObservation),
                (pid, 0, Int.max, true, now, .malformedObservation),
                (pid, nil, nil, false, now, .callbackObservedRunning),
                (pid, 0, exit, true, .nan, .malformedObservation),
                (pid, 0, exit, true, .infinity, .malformedObservation),
                (pid, 0, exit, true, -1, .malformedObservation),
                (pid, 0, exit, true, now + 60, .malformedObservation)
            ]
            for (recordedPID, status, reason, notRunning, entered, error) in cases {
                let injected = ImageDecodeTerminationLatch()
                injected.recordCallback(childPID: recordedPID, terminationStatus: status, terminationReason: reason,
                    observedNotRunning: notRunning, enteredUptimeSeconds: entered)
                assertError(error) { try injected.validateCompletion(for: process) }
            }
        }
    }

    func testCannotInstallAfterRunOrReplaceAnExistingHandler() throws {
        try withOwnedProcess("/bin/sleep", arguments: ["10"]) { process, _, _ in
            assertError(.terminationHandlerAlreadyInstalled) { try ImageDecodeTerminationLatch.install(on: process) }
            try process.run()
            assertError(.processAlreadyLaunched) { try ImageDecodeTerminationLatch.install(on: process) }
        }
    }

    func testRetainedLatchDoesNotRetainCompletedProcessAndBothRelease() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        weak var weakProcess: Process?
        weak var weakLatch: ImageDecodeTerminationLatch?
        var retainedLatch: ImageDecodeTerminationLatch?
        try autoreleasepool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            let latch = try ImageDecodeTerminationLatch.install(on: process)
            weakProcess = process
            weakLatch = latch
            retainedLatch = latch
            defer { cleanup(process, latch, deadline: deadline) }
            try process.run()
            _ = try completion(process, latch, deadline - 0.5)
        }
        while weakProcess != nil, ProcessInfo.processInfo.systemUptime < deadline { settleFrameworkRelease() }
        XCTAssertNil(weakProcess, "The latch must not own the completed Process through its callback")
        XCTAssertNotNil(retainedLatch)
        retainedLatch = nil
        while weakLatch != nil, ProcessInfo.processInfo.systemUptime < deadline { settleFrameworkRelease() }
        XCTAssertNil(weakLatch, "Releasing Process and owner must also release the handler's latch")
    }

    func testUnlaunchedAndFailedLaunchReleaseWithoutCallback() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        for attemptLaunch in [false, true] {
            weak var weakProcess: Process?
            weak var weakLatch: ImageDecodeTerminationLatch?
            try autoreleasepool {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/nonexistent/PicShot-Termination-Latch-" + UUID().uuidString)
                let latch = try ImageDecodeTerminationLatch.install(on: process)
                weakProcess = process
                weakLatch = latch
                defer { cleanup(process, latch, deadline: deadline) }
                if attemptLaunch { XCTAssertThrowsError(try process.run()) }
                XCTAssertEqual(latch.snapshot().callbackCount, 0)
            }
            while weakProcess != nil || weakLatch != nil, ProcessInfo.processInfo.systemUptime < deadline { settleFrameworkRelease() }
            XCTAssertNil(weakProcess, "An absent callback must not retain an unlaunched Process")
            XCTAssertNil(weakLatch, "An absent callback must not retain its scalar latch")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime, deadline)
    }

    func testConcurrentScalarPublicationsCountEveryCallbackWithoutGrowingOrSignalingTwice() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let latch = ImageDecodeTerminationLatch(), writers = DispatchGroup()
        let entered = ProcessInfo.processInfo.systemUptime
        for _ in 0..<32 {
            writers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                latch.recordCallback(childPID: 123, terminationStatus: 0,
                    terminationReason: Process.TerminationReason.exit.rawValue,
                    observedNotRunning: true, enteredUptimeSeconds: entered)
                _ = latch.snapshot()
                writers.leave()
            }
        }
        XCTAssertTrue(latch.wait(untilUptimeSeconds: deadline))
        XCTAssertEqual(writers.wait(timeout: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime)), .success)
        let snapshot = latch.snapshot()
        XCTAssertEqual(snapshot.callbackCount, 32)
        XCTAssertEqual(snapshot.childPID, 123)
        XCTAssertEqual(snapshot.callbackEnteredUptimeSeconds, entered)
        XCTAssertLessThan(try JSONEncoder().encode(snapshot).count, 1_024)
        assertError(.multipleCallbacks(32)) { try latch.validateCompletion(for: Process()) }
    }

    func testAbsentCallbackWaitReturnsAtDeadline() {
        let started = ProcessInfo.processInfo.systemUptime
        let latch = ImageDecodeTerminationLatch()
        XCTAssertFalse(latch.wait(untilUptimeSeconds: started + 0.02))
        XCTAssertFalse(latch.wait(untilUptimeSeconds: .infinity))
        XCTAssertFalse(latch.wait(untilUptimeSeconds: .nan))
        XCTAssertEqual(latch.snapshot().callbackCount, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    /// One absolute three-second budget includes normal execution and cleanup.
    /// No test calls waitUntilExit or launches a shell. A failed assertion cannot
    /// skip killing the exact still-running child created by this helper.
    private func withOwnedProcess(_ executable: String, arguments: [String] = [],
                                  body: (Process, ImageDecodeTerminationLatch, Double) throws -> Void) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let latch = try ImageDecodeTerminationLatch.install(on: process)
        defer { cleanup(process, latch, deadline: deadline) }
        try body(process, latch, deadline - 0.5)
    }

    private func completion(_ process: Process, _ latch: ImageDecodeTerminationLatch,
                            _ deadline: Double) throws -> ImageDecodeTerminationObservation {
        guard latch.wait(untilUptimeSeconds: deadline) else {
            let state = process.isRunning ? "child still running" : "child stopped but callback absent"
            XCTFail("Owned PID \(process.processIdentifier): \(state) at the callback deadline; cleanup has a separate reserved budget")
            throw TestFailure.callbackDeadline
        }
        return try latch.validateCompletion(for: process)
    }

    private func cleanup(_ process: Process, _ latch: ImageDecodeTerminationLatch, deadline: Double) {
        if process.isRunning {
            let ownedPID = process.processIdentifier
            if ownedPID > 0 { _ = kill(ownedPID, SIGKILL) }
            _ = latch.wait(untilUptimeSeconds: deadline)
        }
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertFalse(process.isRunning, "The owned child must exit within the cleanup budget")
    }

    // ARC evidence is collected after exit, allowing Foundation's launching-
    // thread notification/release work to run within the same absolute budget.
    // The callback wait and supervisor candidate never use this run-loop settle.
    private func settleFrameworkRelease() {
        autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        Thread.sleep(forTimeInterval: 0.001)
    }

    private func assertError<T>(_ expected: ImageDecodeTerminationLatchError,
                                file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? ImageDecodeTerminationLatchError, expected, file: file, line: line)
        }
    }

    private enum TestFailure: Error { case callbackDeadline }
}
