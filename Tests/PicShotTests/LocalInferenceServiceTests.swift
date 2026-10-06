import XCTest
import Foundation
import AppKit
import Darwin
import PicShotFormulaRenderCore
@testable import PicShot

/// Uses system sleep processes as lifecycle fixtures, never an unsigned model
/// helper. Signed bundle-relative helper resolution remains production-only.
final class LocalInferenceServiceTests: XCTestCase {
    func testEveryHeavyServiceRejectsTheSameOccupiedGateBeforePreparingInputs() async throws {
        let resources = LocalInferenceResources()
        let lease = try resources.acquire(.smartErase)
        defer { resources.complete(lease) }
        let image = try Self.image()
        let directory = URL(fileURLWithPath: "/unused-private-model-path")
        let ml = MLHelperService(resources: resources)
        let erase = SmartEraseProcessService(resources: resources)
        do {
            _ = try await ml.formula(image: image, modelDirectory: directory)
            XCTFail("Formula must share erase's gate")
        } catch { XCTAssertEqual(error as? LocalInferenceResourceError, .busy) }
        do {
            _ = try await ml.table(image: image, modelDirectory: directory)
            XCTFail("Table must share erase's gate")
        } catch { XCTAssertEqual(error as? LocalInferenceResourceError, .busy) }
        do {
            _ = try await erase.erase(image: image, mask: Data(), modelDirectory: directory)
            XCTFail("Erase must fail before touching the intentionally invalid mask")
        } catch { XCTAssertEqual(error as? LocalInferenceResourceError, .busy) }
        XCTAssertEqual(resources.snapshot().activeJob, .smartErase)
        XCTAssertTrue(resources.snapshot().lastJobs.isEmpty)
        XCTAssertTrue(LocalInferenceResourceError.busy.localizedDescription.contains("公式"))
        XCTAssertTrue(LocalInferenceResourceError.busy.localizedDescription.contains("表格"))
        XCTAssertTrue(LocalInferenceResourceError.busy.localizedDescription.contains("智能消除"))
    }

    func testRendererDoesNotAcquireHeavyGateAndKeepsItsSeparateCap() async throws {
        // The unit-test runner is not a packaged PicShot.app. Reaching the
        // renderer's own bundle check proves it wasn't rejected by the gate.
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            throw XCTSkip("This assertion requires the ordinary swift-test bundle")
        }
        let resources = LocalInferenceResources.shared
        let lease = try resources.acquire(.formula)
        defer { resources.complete(lease) }
        do {
            _ = try await FormulaRenderService().render(FormulaRenderRequest(latex: "x"))
            XCTFail("Unit tests must not silently find a signed packaged helper")
        } catch {
            guard let renderError = error as? FormulaRenderError, case .helperUnavailable = renderError else {
                return XCTFail("Expected renderer bundle validation, got \(error)")
            }
        }
        XCTAssertEqual(resources.snapshot().activeJob, .formula)
        XCTAssertEqual(FormulaRenderLimits.residentBytes, 268_435_456)
    }

    func testBothControlsPreventLaunchAfterCancellation() {
        for harness in InferenceProcessHarness.makeAll() {
            harness.cancel(); harness.cancel()
            let process = Self.sleepProcess()
            XCTAssertThrowsError(try harness.start(process)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(process.isRunning)
            XCTAssertTrue(harness.isCancelled())
        }
    }

    func testBothControlsTerminateAndReapOnRepeatedCancellation() throws {
        for harness in InferenceProcessHarness.makeAll() {
            let process = Self.sleepProcess()
            try harness.start(process)
            XCTAssertTrue(process.isRunning)
            harness.cancel(); harness.cancel()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                harness.stop(); Thread.sleep(forTimeInterval: 0.02)
            }
            let leaked = process.isRunning
            if leaked { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            XCTAssertFalse(leaked, "Cancellation left a child running for \(harness.kind)")
            XCTAssertFalse(process.isRunning)
            harness.cancel(); harness.stop() // Safe after Foundation reaped the child.
        }
    }

    func testConcurrentStartCancelRacesNeverLeaveAChildRunning() throws {
        for _ in 0..<12 {
            for harness in InferenceProcessHarness.makeAll() {
                let process = Self.sleepProcess()
                let errors = InferenceProcessStartErrors()
                DispatchQueue.concurrentPerform(iterations: 2) { index in
                    if index == 0 {
                        do { try harness.start(process) }
                        catch { errors.record(isCancellation: error is CancellationError) }
                    } else {
                        harness.cancel()
                    }
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    harness.stop(); Thread.sleep(forTimeInterval: 0.01)
                }
                let leaked = process.isRunning
                if leaked { kill(process.processIdentifier, SIGKILL) }
                // Failed/cancelled launches have no PID and must not be waited on.
                if process.processIdentifier > 0 { process.waitUntilExit() }
                XCTAssertFalse(leaked)
                XCTAssertEqual(errors.unexpectedCount, 0)
                XCTAssertTrue(harness.isCancelled())
            }
        }
    }

    func testRepeatedProcessLaunchFailureReleasesLeaseForBothHelpers() async throws {
        let resources = LocalInferenceResources()
        for _ in 0..<3 {
            for harness in InferenceProcessHarness.makeAll() {
                do {
                    _ = try await resources.withJob(harness.kind) { recorder -> Int in
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/nonexistent-picshot-test-\(UUID().uuidString)")
                        do { try harness.start(process) }
                        catch { recorder.recordOutcome(.launchFailed); throw error }
                        return 1
                    }
                    XCTFail("Missing executable must fail")
                } catch { /* An actual Foundation process-launch failure. */ }
                XCTAssertNil(resources.snapshot().activeJob)
                let last = try XCTUnwrap(resources.snapshot().lastJobs.first { $0.kind == harness.kind })
                XCTAssertEqual(last.outcome, .launchFailed)
                XCTAssertFalse(last.childLaunched)
                XCTAssertFalse(last.childExitConfirmed)
                XCTAssertNil(last.sampledPeakResidentBytes)
            }
        }
    }

    func testCancellationHoldsLeaseThroughActualChildExitAndPrivateDirectoryCleanup() async throws {
        for harness in InferenceProcessHarness.makeAll() {
            let resources = LocalInferenceResources()
            let launched = expectation(description: "\(harness.kind) fixture launched")
            let exited = expectation(description: "\(harness.kind) fixture exited")
            let allowCleanup = DispatchSemaphore(value: 0)
            // Always unblock the detached fixture, even if an assertion fails.
            defer { allowCleanup.signal() }
            let task = Task {
                try await resources.withJob(harness.kind) { recorder in
                    try await withTaskCancellationHandler(operation: {
                        try await Task.detached { () throws -> Int in
                            let fm = FileManager.default
                            let directory = fm.temporaryDirectory.appendingPathComponent("picshot-inference-fixture-\(UUID().uuidString)")
                            recorder.willCreateTemporaryDirectory()
                            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                            defer {
                                try? fm.removeItem(at: directory)
                                recorder.recordCleanup(confirmed: LocalInferenceResources.removalIsConfirmed(at: directory))
                            }
                            let process = Self.sleepProcess()
                            try harness.start(process); recorder.recordLaunch(); launched.fulfill()
                            let deadline = ProcessInfo.processInfo.systemUptime + 5
                            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                                if harness.isCancelled() { harness.stop() }
                                var info = proc_taskinfo()
                                let read = proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
                                recorder.recordResidentBytes(read == Int32(MemoryLayout<proc_taskinfo>.size) ? info.pti_resident_size : nil)
                                Thread.sleep(forTimeInterval: 0.01)
                            }
                            let leaked = process.isRunning
                            if leaked { kill(process.processIdentifier, SIGKILL) }
                            process.waitUntilExit()
                            recorder.recordExit(status: process.terminationStatus, reason: process.terminationReason == .exit ? .exit : .uncaughtSignal)
                            exited.fulfill()
                            // Hold cleanup long enough for the test to check
                            // ownership even after the child has already exited.
                            _ = allowCleanup.wait(timeout: .now() + 5)
                            if leaked { throw InferenceProcessFixtureError.didNotExit }
                            if harness.isCancelled() { throw CancellationError() }
                            return 1
                        }.value
                    }, onCancel: { harness.cancel() })
                }
            }
            await fulfillment(of: [launched], timeout: 3)
            task.cancel()
            await fulfillment(of: [exited], timeout: 4)
            XCTAssertEqual(resources.snapshot().activeJob, harness.kind)
            XCTAssertTrue(resources.snapshot().lastJobs.isEmpty)
            XCTAssertThrowsError(try resources.acquire(.table)) {
                XCTAssertEqual($0 as? LocalInferenceResourceError, .busy)
            }
            allowCleanup.signal()
            do { _ = try await task.value; XCTFail("Cancelled fixture should fail") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(resources.snapshot().activeJob)
            let last = try XCTUnwrap(resources.snapshot().lastJobs.first)
            XCTAssertEqual(last.outcome, .cancelled)
            XCTAssertTrue(last.childLaunched)
            XCTAssertTrue(last.childExitConfirmed)
            XCTAssertNotNil(last.childElapsedSeconds)
            XCTAssertEqual(last.temporaryDirectoryCleanup, .confirmed)
        }
    }

    private static func sleepProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}

private enum InferenceProcessFixtureError: Error { case didNotExit }
private struct InferenceProcessHarness: Sendable {
    let kind: LocalInferenceJobKind
    let start: @Sendable (Process) throws -> Void
    let cancel: @Sendable () -> Void
    let stop: @Sendable () -> Void
    let isCancelled: @Sendable () -> Bool

    static func makeAll() -> [InferenceProcessHarness] {
        let ml = MLProcessControl(), erase = SmartEraseProcessControl()
        return [
            InferenceProcessHarness(kind: .formula, start: { try ml.start($0) }, cancel: { ml.cancel() },
                                    stop: { ml.stop() }, isCancelled: { ml.isCancelled }),
            InferenceProcessHarness(kind: .smartErase, start: { try erase.start($0) }, cancel: { erase.cancel() },
                                    stop: { erase.stop() }, isCancelled: { erase.isCancelled })
        ]
    }
}

private final class InferenceProcessStartErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var unexpected = 0
    func record(isCancellation: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !isCancellation { unexpected += 1 }
    }
    var unexpectedCount: Int { lock.lock(); defer { lock.unlock() }; return unexpected }
}
