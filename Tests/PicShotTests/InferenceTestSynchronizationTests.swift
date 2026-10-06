import XCTest
import Foundation

final class InferenceTestSynchronizationTests: XCTestCase {
    func testOpenBeforeRegistrationAndRepeatedOpenAreSafe() async throws {
        let latch = InferenceTestLatch()
        latch.open(); latch.open()
        try await latch.wait(phase: "already open latch")
        XCTAssertEqual(latch.waitingCount, 0)
    }

    func testAllRegisteredWaitersResumeWithoutOverwritingOneAnother() async throws {
        let latch = InferenceTestLatch()
        let tasks = (0..<12).map { index in
            InferenceTestOperation {
                try await latch.wait(phase: "multiple waiter \(index)")
                return index
            }
        }
        defer { latch.open(); tasks.forEach { $0.cancel() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while latch.waitingCount < tasks.count {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw InferenceTestSynchronizationError.timedOut("all test waiters registered")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        latch.open(); latch.open()
        for (index, task) in tasks.enumerated() {
            let value = try await task.value(phase: "multiple waiter completed")
            XCTAssertEqual(value, index)
        }
        XCTAssertEqual(latch.waitingCount, 0)
    }

    func testConcurrentOpenRegistrationRacesAlwaysComplete() async throws {
        for index in 0..<128 {
            let latch = InferenceTestLatch()
            let task = InferenceTestOperation {
                try await latch.wait(phase: "open/register race \(index)")
                return index
            }
            defer { latch.open(); task.cancel() }
            DispatchQueue.global(qos: .userInitiated).async { latch.open() }
            if index.isMultiple(of: 2) { latch.open() }
            let value = try await task.value(phase: "open/register race completed")
            XCTAssertEqual(value, index)
            XCTAssertEqual(latch.waitingCount, 0)
        }
    }

    func testAbsentSignalFailsWithBoundedPhaseDiagnosticThenCanOpen() async throws {
        let latch = InferenceTestLatch()
        do {
            try await latch.wait(timeout: 0.02, phase: "intentional missing signal")
            XCTFail("A missing signal must time out")
        } catch {
            guard let synchronizationError = error as? InferenceTestSynchronizationError,
                  case .timedOut(let phase) = synchronizationError else {
                return XCTFail("Unexpected failure: \(error)")
            }
            XCTAssertEqual(phase, "intentional missing signal")
        }
        XCTAssertEqual(latch.waitingCount, 0)
        latch.open()
        try await latch.wait(phase: "latch after timeout")
    }

    func testConcurrentTimeoutOpenOwnExactlyOneResume() async throws {
        for index in 0..<32 {
            let latch = InferenceTestLatch()
            let task = InferenceTestOperation {
                do {
                    try await latch.wait(timeout: 0.002, phase: "timeout/open race \(index)")
                    return true
                } catch InferenceTestSynchronizationError.timedOut(_) {
                    return false // Either outcome is valid at this exact deadline.
                }
            }
            defer { latch.open(); task.cancel() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.002) { latch.open() }
            _ = try await task.value(phase: "timeout/open race completed exactly once")
            latch.open()
            try await latch.wait(phase: "opened after timeout/open race")
            XCTAssertEqual(latch.waitingCount, 0)
        }
    }

    func testCancelledFixtureKeepsWaitingButItsObserverIsBounded() async throws {
        let release = InferenceTestLatch()
        let task = InferenceTestOperation {
            try await release.wait(phase: "cancelled fixture explicitly released")
            return 7
        }
        defer { release.open(); task.cancel() }
        task.cancel()
        do {
            _ = try await task.value(timeout: 0.02, phase: "intentional blocked completion")
            XCTFail("Cancellation must not falsely signal fixture cleanup")
        } catch {
            guard let synchronizationError = error as? InferenceTestSynchronizationError,
                  case .timedOut(let phase) = synchronizationError else {
                return XCTFail("Unexpected failure: \(error)")
            }
            XCTAssertEqual(phase, "intentional blocked completion")
        }
        release.open()
        let value = try await task.value(phase: "cancelled fixture actually finished")
        XCTAssertEqual(value, 7)
    }
}
