import XCTest
import Foundation
@testable import PicShot

final class LocalInferenceResourceTests: XCTestCase {
    func testOneLeaseCoversAllKindsAndStaleReleaseCannotUnlockNewOwner() throws {
        let resources = LocalInferenceResources()
        let first = try resources.acquire(.formula)
        for kind in LocalInferenceJobKind.allCases {
            XCTAssertThrowsError(try resources.acquire(kind)) {
                XCTAssertEqual($0 as? LocalInferenceResourceError, .busy)
            }
        }
        XCTAssertEqual(resources.snapshot().activeJob, .formula)
        XCTAssertTrue(resources.snapshot().lastJobs.isEmpty)
        XCTAssertTrue(resources.complete(first))
        let second = try resources.acquire(.smartErase)
        XCTAssertFalse(resources.complete(first))
        XCTAssertEqual(resources.snapshot().activeJob, .smartErase)
        XCTAssertThrowsError(try resources.acquire(.table))
        XCTAssertTrue(resources.complete(second))
        XCTAssertNil(resources.snapshot().activeJob)
    }

    func testConcurrentAcquireHasExactlyOneWinnerAndNoQueue() throws {
        let resources = LocalInferenceResources()
        let results = InferenceLeaseResults()
        DispatchQueue.concurrentPerform(iterations: 96) { index in
            do { results.won(try resources.acquire(LocalInferenceJobKind.allCases[index % 3])) }
            catch { results.rejected(error as? LocalInferenceResourceError == .busy) }
        }
        XCTAssertEqual(results.leases.count, 1)
        XCTAssertEqual(results.busyCount, 95)
        XCTAssertEqual(results.unexpectedCount, 0)
        for lease in results.leases { XCTAssertTrue(resources.complete(lease)) }
        XCTAssertNil(resources.snapshot().activeJob)
        XCTAssertEqual(resources.snapshot().lastJobs.count, 1)
    }

    func testConcurrentDuplicateCompletionCannotChangeCurrentLeaseOrMetrics() throws {
        let resources = LocalInferenceResources()
        let old = try resources.acquire(.formula)
        XCTAssertTrue(resources.complete(old))
        let previous = resources.snapshot().lastJobs
        let current = try resources.acquire(.table)
        DispatchQueue.concurrentPerform(iterations: 96) { _ in
            XCTAssertFalse(resources.complete(old))
        }
        XCTAssertEqual(resources.snapshot().activeJob, .table)
        XCTAssertEqual(resources.snapshot().lastJobs, previous)
        XCTAssertTrue(resources.complete(current))
    }

    func testBusyOperationNeverRunsOrOverwritesMetrics() async throws {
        let resources = LocalInferenceResources()
        let lease = try resources.acquire(.smartErase)
        let invoked = InferenceTestCounter()
        do {
            _ = try await resources.withJob(.formula) { _ in invoked.increment(); return 1 }
            XCTFail("A busy request must fail immediately")
        } catch { XCTAssertEqual(error as? LocalInferenceResourceError, .busy) }
        XCTAssertEqual(invoked.value, 0)
        XCTAssertTrue(resources.snapshot().lastJobs.isEmpty)
        XCTAssertTrue(resources.complete(lease))
        XCTAssertEqual(invoked.value, 0)
    }

    func testFailureTimeoutMemoryAndLaunchFailureAlwaysRelease() async throws {
        let resources = LocalInferenceResources()
        for outcome in [LocalInferenceJobOutcome.failed, .launchFailed, .timedOut, .memoryLimit, .cancelled] {
            do {
                _ = try await resources.withJob(.table) { recorder -> Int in
                    recorder.recordOutcome(outcome)
                    if outcome == .cancelled { throw CancellationError() }
                    throw InferenceTestFailure.expected
                }
                XCTFail("Fixture should fail")
            } catch { /* The gate preserves the caller's error, not its contents. */ }
            XCTAssertNil(resources.snapshot().activeJob)
            XCTAssertEqual(resources.snapshot().lastJobs.first { $0.kind == .table }?.outcome, outcome)
            let result = try await resources.withJob(.formula) { _ in 42 }
            XCTAssertEqual(result, 42)
        }
    }

    func testAlreadyCancelledTaskAcquiresNothing() async throws {
        let resources = LocalInferenceResources()
        let ready = InferenceTestLatch()
        let invoked = InferenceTestCounter()
        let task = Task {
            await ready.wait()
            return try await resources.withJob(.formula) { _ in invoked.increment(); return 1 }
        }
        task.cancel()
        await ready.open()
        do { _ = try await task.value; XCTFail("Pre-cancelled task must not launch work") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(invoked.value, 0)
        XCTAssertNil(resources.snapshot().activeJob)
        XCTAssertTrue(resources.snapshot().lastJobs.isEmpty)
    }

    func testCancellationKeepsLeaseUntilNonCooperativeWorkerActuallyUnwinds() async throws {
        let resources = LocalInferenceResources()
        let entered = InferenceTestLatch(), mayFinish = InferenceTestLatch()
        let task = Task {
            try await resources.withJob(.smartErase) { recorder in
                recorder.willCreateTemporaryDirectory()
                await entered.open()
                // Simulates a detached child still exiting/cleaning up. A task
                // cancellation must not hand its lease to another model yet.
                await mayFinish.wait()
                recorder.recordCleanup(confirmed: true)
                return 1
            }
        }
        await entered.wait()
        task.cancel()
        XCTAssertEqual(resources.snapshot().activeJob, .smartErase)
        XCTAssertThrowsError(try resources.acquire(.formula)) {
            XCTAssertEqual($0 as? LocalInferenceResourceError, .busy)
        }
        await mayFinish.open()
        do { _ = try await task.value; XCTFail("Late successful result must be discarded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(resources.snapshot().activeJob)
        let last = try XCTUnwrap(resources.snapshot().lastJobs.first)
        XCTAssertEqual(last.outcome, .cancelled)
        XCTAssertEqual(last.temporaryDirectoryCleanup, .confirmed)
        let next = try await resources.withJob(.table) { _ in 2 }
        XCTAssertEqual(next, 2)
    }

    func testRepeatedAcquireCancelRacesCannotStrandGate() async throws {
        let resources = LocalInferenceResources()
        for _ in 0..<128 {
            let task = Task.detached {
                try await resources.withJob(.formula) { _ in
                    await Task.yield()
                    return 1
                }
            }
            task.cancel()
            do { _ = try await task.value }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(resources.snapshot().activeJob)
        }
        _ = try await resources.withJob(.smartErase) { _ in 1 }
        XCTAssertNil(resources.snapshot().activeJob)
    }

    func testGateDoesNotRetainOperationOrItsInputs() async throws {
        let resources = LocalInferenceResources()
        weak var weakInput: InferenceTestInput?
        do {
            let input = InferenceTestInput()
            weakInput = input
            let result = try await resources.withJob(.formula) { [input] _ in input.value }
            XCTAssertEqual(result, 7)
        }
        XCTAssertNil(weakInput)
        XCTAssertEqual(resources.snapshot().lastJobs.count, 1)
    }
}

private enum InferenceTestFailure: Error { case expected }
private final class InferenceTestInput: @unchecked Sendable { let value = 7 }

private actor InferenceTestLatch {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        let waiting = continuation; continuation = nil
        waiting?.resume()
    }
}

private final class InferenceTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class InferenceLeaseResults: @unchecked Sendable {
    private let lock = NSLock()
    private var wins: [LocalInferenceResources.Lease] = []
    private var busy = 0, unexpected = 0
    func won(_ lease: LocalInferenceResources.Lease) { lock.lock(); defer { lock.unlock() }; wins.append(lease) }
    func rejected(_ expected: Bool) {
        lock.lock(); defer { lock.unlock() }
        if expected { busy += 1 } else { unexpected += 1 }
    }
    var leases: [LocalInferenceResources.Lease] { lock.lock(); defer { lock.unlock() }; return wins }
    var busyCount: Int { lock.lock(); defer { lock.unlock() }; return busy }
    var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
}
