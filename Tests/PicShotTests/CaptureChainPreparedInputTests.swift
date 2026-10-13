import AppKit
import XCTest
import PicShotCore
@testable import PicShot

/// Prepared inputs deliberately retain the saved source reference while never
/// acquiring it. All output files and provider storage belong to this test.
@MainActor
final class CaptureChainPreparedInputTests: XCTestCase {
    func testAll15OrdersAndEveryReceiptPrefixDispatchOnlySuffixUsingIdenticalPreparedImage() async throws {
        let files = try Files(); defer { files.cleanUp() }
        let image = try raster(), expectedPixels = try SaveWorkflowUIPreviewFixture.pixels(image)
        let capture = try ChainCapture(image: image, capturedAt: Date(timeIntervalSince1970: 269), encodedBackingBytes: 37)
        let saved = try files.save(image), pinID = UUID()
        let orders = orderedSelections()
        XCTAssertEqual(orders.count, 15)
        for order in orders {
            let definition = try definition(order)
            let complete = order.map { receipt($0, saved: saved, pinID: pinID) }
            for prefixCount in 0...order.count {
                let prefix = Array(complete.prefix(prefixCount))
                var acquisitions = 0, seen: [CaptureChainOutput] = [], changes: [CaptureChainStatus] = []
                var terminals: [CaptureChainSnapshot] = []
                let check: (CGImage, CaptureChainOutput) -> Void = { actual, output in
                    XCTAssertTrue(actual === image)
                    XCTAssertEqual(try? SaveWorkflowUIPreviewFixture.pixels(actual), expectedPixels)
                    seen.append(output)
                }
                let runner = try CaptureChainRunner(definition: definition, preparedCapture: capture, receipts: prefix,
                    dependencies: .init(capture: {
                        acquisitions += 1
                        throw Failure.unexpectedAcquisition
                    }, savePNG: { check($0, .quickSavePNG); return .committed(saved) },
                    copy: { check($0, .copy) }, pin: { check($0, .pin); return pinID },
                    cancelSave: { XCTFail("A successful suffix must not cancel Save") },
                    cancelCapture: { XCTFail("Prepared input has no acquisition to cancel") }))
                runner.onChange = { changes.append($0.status) }
                runner.onTerminal = { terminals.append($0) }
                XCTAssertTrue(runner.capture?.image === image)
                XCTAssertEqual(runner.retainedBytes, image.bytesPerRow * image.height + 37)
                XCTAssertTrue(runner.snapshot.isExistingScrollImage)
                XCTAssertTrue(runner.start()); XCTAssertFalse(runner.start())
                try await until { runner.status == .completed }
                XCTAssertEqual(acquisitions, 0)
                XCTAssertEqual(seen, Array(order.dropFirst(prefixCount)))
                XCTAssertEqual(runner.receipts, complete)
                XCTAssertEqual(runner.capturedAt, capture.capturedAt)
                XCTAssertEqual(runner.definition.source, definition.source)
                XCTAssertFalse(changes.contains(.capturing))
                XCTAssertEqual(terminals.count, 1)
                XCTAssertEqual(terminals.first?.runID, runner.id)
                assertReleased(runner)
                XCTAssertFalse(runner.cancel()); XCTAssertFalse(runner.retry())
            }
        }
    }

    func testPreparedReceiptValidationRejectsOutOfOrderMismatchedAndOverlongPrefixesBeforeDispatch() throws {
        let files = try Files(); defer { files.cleanUp() }
        let image = try raster(), saved = try files.save(image), pinID = UUID()
        let capture = try ChainCapture(image: image)
        let definition = try definition([.quickSavePNG, .copy, .pin])
        let save = receipt(.quickSavePNG, saved: saved, pinID: pinID)
        let copy = receipt(.copy, saved: saved, pinID: pinID)
        let pin = receipt(.pin, saved: saved, pinID: pinID)
        let invalid: [[CaptureChainReceipt]] = [
            [copy], [pin], [save, pin], [save, save], [save, copy, pin, pin],
            [.init(output: .quickSavePNG, value: .copied)],
            [.init(output: .quickSavePNG, value: .pinned(pinID))],
            [.init(output: .quickSavePNG, value: .saved(saved.savedURL, byteCount: -1))],
            [save, .init(output: .copy, value: .saved(saved.savedURL, byteCount: saved.byteCount))],
            [save, .init(output: .copy, value: .pinned(pinID))],
            [save, copy, .init(output: .pin, value: .copied)],
            [save, copy, .init(output: .pin, value: .saved(saved.savedURL, byteCount: saved.byteCount))]
        ]
        for prefix in invalid {
            XCTAssertThrowsError(try CaptureChainRunner.validateReceiptPrefix(prefix, definition: definition))
            XCTAssertThrowsError(try CaptureChainRunner(definition: definition, preparedCapture: capture,
                receipts: prefix, dependencies: unexpectedDependencies()))
        }
        for prefix in [[], [save], [save, copy], [save, copy, pin]] {
            XCTAssertNoThrow(try CaptureChainRunner.validateReceiptPrefix(prefix, definition: definition))
        }
    }

    func testCancellationAtEveryOutputBoundaryContinuesWithFreshRunIDAndNoPrefixReplay() async throws {
        let files = try Files(); defer { files.cleanUp() }
        let image = try raster(), capture = try ChainCapture(image: image), saved = try files.save(image), pinID = UUID()
        for order in orderedSelections().filter({ $0.count == 3 }) {
            for boundary in order.indices {
                let definition = try definition(order)
                var seen: [CaptureChainOutput] = [], captures = 0
                let dependencies = CaptureChainRunner.Dependencies(capture: {
                    captures += 1; throw Failure.unexpectedAcquisition
                }, savePNG: { actual in
                    XCTAssertTrue(actual === image); seen.append(.quickSavePNG); return .committed(saved)
                }, copy: { actual in XCTAssertTrue(actual === image); seen.append(.copy) },
                pin: { actual in XCTAssertTrue(actual === image); seen.append(.pin); return pinID }, cancelSave: {})
                let first = try CaptureChainRunner(definition: definition, preparedCapture: capture, dependencies: dependencies)
                first.onChange = { [weak first] snapshot in
                    if snapshot.status == .running(index: boundary) { XCTAssertTrue(first?.cancel() == true) }
                }
                XCTAssertTrue(first.start())
                try await until { first.status == .cancelled }
                XCTAssertEqual(seen, Array(order.prefix(boundary)))
                XCTAssertEqual(first.receipts.map(\.output), Array(order.prefix(boundary)))
                let prefix = first.receipts
                let successor = try CaptureChainRunner(definition: definition, preparedCapture: capture,
                    receipts: prefix, dependencies: dependencies)
                XCTAssertNotEqual(first.id, successor.id)
                XCTAssertTrue(successor.start())
                XCTAssertFalse(first.start()); XCTAssertFalse(first.retry()); XCTAssertFalse(first.cancel())
                try await until { successor.status == .completed }
                XCTAssertEqual(seen, order)
                XCTAssertEqual(Array(successor.receipts.prefix(prefix.count)), prefix)
                XCTAssertEqual(captures, 0)
                assertReleased(first); assertReleased(successor)
            }
        }
    }

    func testEachFailedOutputReentrantRetryPreservesCommittedPrefixAndNeverAcquires() async throws {
        let files = try Files(); defer { files.cleanUp() }
        let image = try raster(), capture = try ChainCapture(image: image), saved = try files.save(image), pinID = UUID()
        let order: [CaptureChainOutput] = [.quickSavePNG, .copy, .pin]
        for failureIndex in order.indices {
            var calls: [CaptureChainOutput] = [], failures = 0, retried = false
            let check: (CGImage, CaptureChainOutput) throws -> Void = { actual, output in
                XCTAssertTrue(actual === image); calls.append(output)
                if output == order[failureIndex] && failures == 0 { failures += 1; throw Failure.output }
            }
            let runner = try CaptureChainRunner(definition: definition(order), preparedCapture: capture,
                dependencies: .init(capture: { XCTFail(); throw Failure.unexpectedAcquisition }, savePNG: { actual in
                    do { try check(actual, .quickSavePNG); return .committed(saved) }
                    catch { return .failed(.operation(error)) }
                }, copy: { try check($0, .copy) }, pin: { try check($0, .pin); return pinID }, cancelSave: {}))
            runner.onChange = { [weak runner] snapshot in
                if case .failed(let index, _) = snapshot.status {
                    XCTAssertEqual(index, failureIndex)
                    XCTAssertEqual(snapshot.receipts.map(\.output), Array(order.prefix(failureIndex)))
                    XCTAssertFalse(retried); retried = true
                    XCTAssertTrue(runner?.retry() == true)
                    XCTAssertFalse(runner?.retry() == true)
                }
            }
            XCTAssertTrue(runner.start()); try await until { runner.status == .completed }
            var expected = order; expected.insert(order[failureIndex], at: failureIndex)
            XCTAssertEqual(calls, expected); XCTAssertEqual(failures, 1); XCTAssertTrue(retried)
            XCTAssertEqual(runner.receipts.map(\.output), order)
            assertReleased(runner)
        }
    }

    func testCommittedSaveBeforeCancelDrainRemainsInContinuationAndDoesNotSaveAgain() async throws {
        let files = try Files(); defer { files.cleanUp() }
        let image = try raster(), capture = try ChainCapture(image: image), gate = Gate<SaveWorkflowTerminalOutcome>()
        defer { gate.resolve(.cancelled) }
        var committed: SaveWorkflowSummary?, saves = 0, copies = 0, pins = 0, saveCancels = 0
        let definition = try definition([.quickSavePNG, .copy, .pin])
        let dependencies = CaptureChainRunner.Dependencies(capture: { XCTFail(); throw Failure.unexpectedAcquisition },
            savePNG: { actual in
                XCTAssertTrue(actual === image); saves += 1
                do { committed = try files.save(actual) } catch { return .failed(.operation(error)) }
                return await gate.wait()
            }, copy: { actual in XCTAssertTrue(actual === image); copies += 1 },
            pin: { actual in XCTAssertTrue(actual === image); pins += 1; return UUID() },
            cancelSave: { saveCancels += 1 })
        let first = try CaptureChainRunner(definition: definition, preparedCapture: capture, dependencies: dependencies)
        XCTAssertTrue(first.start()); try await until { gate.isWaiting }
        let saved = try XCTUnwrap(committed), originalBytes = try Data(contentsOf: saved.savedURL)
        XCTAssertTrue(first.cancel()); XCTAssertFalse(first.cancel())
        XCTAssertEqual(first.status, .cancelling); XCTAssertEqual(first.retainedBytes, capture.retainedBytes)
        XCTAssertTrue(first.isAttemptRunning); XCTAssertEqual(saveCancels, 1)
        XCTAssertEqual(copies, 0); XCTAssertEqual(pins, 0)
        XCTAssertTrue(gate.resolve(.committed(saved)))
        try await until { first.status == .cancelled }
        XCTAssertEqual(first.receipts, [receipt(.quickSavePNG, saved: saved, pinID: UUID())])
        let second = try CaptureChainRunner(definition: definition, preparedCapture: capture,
            receipts: first.receipts, dependencies: dependencies)
        XCTAssertNotEqual(first.id, second.id); XCTAssertTrue(second.start())
        try await until { second.status == .completed }
        XCTAssertEqual(saves, 1); XCTAssertEqual(copies, 1); XCTAssertEqual(pins, 1)
        XCTAssertEqual(try Data(contentsOf: saved.savedURL), originalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.root.path).count, 1)
        XCTAssertFalse(gate.resolve(.cancelled))
        assertReleased(first); assertReleased(second)
    }

    func testPinThenSavePickerCancellationContinuesOnlySaveAndCopy() async throws {
        let files = try Files(); defer { files.cleanUp() }
        let image = try raster(), capture = try ChainCapture(image: image), saved = try files.save(image), pinID = UUID()
        let definition = try definition([.pin, .quickSavePNG, .copy])
        var pins = 0, saves = 0, copies = 0
        let dependencies = CaptureChainRunner.Dependencies(capture: { XCTFail(); throw Failure.unexpectedAcquisition },
            savePNG: { actual in
                XCTAssertTrue(actual === image); saves += 1
                return saves == 1 ? .cancelled : .committed(saved)
            }, copy: { actual in XCTAssertTrue(actual === image); copies += 1 },
            pin: { actual in XCTAssertTrue(actual === image); pins += 1; return pinID }, cancelSave: {})
        let first = try CaptureChainRunner(definition: definition, preparedCapture: capture, dependencies: dependencies)
        XCTAssertTrue(first.start()); try await until { first.status == .cancelled }
        XCTAssertEqual(first.receipts, [.init(output: .pin, value: .pinned(pinID))])
        let second = try CaptureChainRunner(definition: definition, preparedCapture: capture,
            receipts: first.receipts, dependencies: dependencies)
        XCTAssertTrue(second.start()); try await until { second.status == .completed }
        XCTAssertEqual(pins, 1); XCTAssertEqual(saves, 2); XCTAssertEqual(copies, 1)
        XCTAssertEqual(second.receipts.first, first.receipts.first)
        assertReleased(first); assertReleased(second)
    }

    func testFinalCommitReentrantCancelHasCompleteReceiptAndPreparedReplayDispatchesNothing() async throws {
        let files = try Files(); defer { files.cleanUp() }
        let image = try raster(), capture = try ChainCapture(image: image), saved = try files.save(image), pinID = UUID()
        for output in [CaptureChainOutput.quickSavePNG, .copy, .pin] {
            let definition = try definition([output])
            weak var active: CaptureChainRunner?
            var outputs = 0, terminals = 0
            let commit: (CGImage) -> Void = { actual in
                XCTAssertTrue(actual === image); outputs += 1
                XCTAssertTrue(active?.cancel() == true)
            }
            let runner = try CaptureChainRunner(definition: definition, preparedCapture: capture,
                dependencies: .init(capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                    savePNG: { commit($0); return .committed(saved) }, copy: commit,
                    pin: { commit($0); return pinID }, cancelSave: {}))
            active = runner; runner.onTerminal = { _ in terminals += 1 }
            XCTAssertTrue(runner.start()); try await until { runner.status == .cancelled }
            XCTAssertEqual(runner.receipts, [receipt(output, saved: saved, pinID: pinID)])
            XCTAssertEqual(terminals, 1); XCTAssertEqual(outputs, 1)
            let completed = try CaptureChainRunner(definition: definition, preparedCapture: capture,
                receipts: runner.receipts, dependencies: unexpectedDependencies())
            XCTAssertNotEqual(completed.id, runner.id)
            XCTAssertTrue(completed.start()); try await until { completed.status == .completed }
            XCTAssertEqual(completed.receipts, runner.receipts)
            assertReleased(runner); assertReleased(completed)
        }
    }

    func testSharedCheckpointProviderSurvivesCancelledSaveOnlyUntilBothOwnersRelease() async throws {
        let counter = CaptureTestProviderCounter(), gate = Gate<SaveWorkflowTerminalOutcome>()
        defer { gate.resolve(.cancelled) }
        var checkpoint: ChainCapture? = try autoreleasepool {
            try ChainCapture(image: CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter),
                capturedAt: Date(timeIntervalSince1970: 269), encodedBackingBytes: 13)
        }
        let runner = try CaptureChainRunner(definition: definition([.quickSavePNG, .copy]),
            preparedCapture: XCTUnwrap(checkpoint), dependencies: .init(
                capture: { XCTFail(); throw Failure.unexpectedAcquisition }, savePNG: { _ in await gate.wait() },
                copy: { _ in XCTFail() }, pin: { _ in XCTFail(); return UUID() }, cancelSave: {}))
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertEqual(counter.liveBytes, 8 * 8 * 4)
        XCTAssertEqual(runner.retainedBytes, 8 * 8 * 4 + 13)
        XCTAssertTrue(runner.capture?.image === checkpoint?.image)
        XCTAssertTrue(runner.cancel())
        XCTAssertTrue(runner.isAttemptRunning); XCTAssertEqual(counter.deallocations, 0)
        XCTAssertTrue(gate.resolve(.cancelled)); try await until { runner.status == .cancelled }
        assertReleased(runner)
        XCTAssertEqual(counter.liveBytes, 8 * 8 * 4, "The scroll checkpoint still owns the exact provider")
        XCTAssertEqual(counter.deallocations, 0)
        checkpoint = nil
        try await until { counter.liveBytes == 0 }
        XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1)
    }

    func testPreparedCompletionReleasesProviderWithoutKeepingImageInTerminalSnapshot() async throws {
        let counter = CaptureTestProviderCounter()
        var snapshots: [CaptureChainSnapshot] = [], copied = 0
        let runner = try autoreleasepool {
            try CaptureChainRunner(definition: definition([.copy]), preparedCapture: ChainCapture(image:
                CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter)), dependencies: .init(
                    capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                    savePNG: { _ in XCTFail(); return .cancelled }, copy: { _ in copied += 1 },
                    pin: { _ in XCTFail(); return UUID() }, cancelSave: {}))
        }
        runner.onTerminal = { snapshots.append($0) }
        XCTAssertTrue(runner.start()); try await until { runner.status == .completed && counter.liveBytes == 0 }
        XCTAssertEqual(copied, 1); XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1)
        XCTAssertEqual(snapshots.count, 1); XCTAssertEqual(snapshots.first?.retainedBytes, 0)
        XCTAssertEqual(snapshots.first?.receipts, [.init(output: .copy, value: .copied)])
        assertReleased(runner)
    }

    private func orderedSelections() -> [[CaptureChainOutput]] {
        let choices: [CaptureChainOutput] = [.quickSavePNG, .copy, .pin]
        var result = choices.map { [$0] }
        for first in choices { for second in choices where first != second {
            result.append([first, second])
            for third in choices where third != first && third != second { result.append([first, second, third]) }
        } }
        return result
    }

    private func definition(_ outputs: [CaptureChainOutput]) throws -> CaptureChainDefinition {
        // This preset intentionally does not exist. Existing-image execution
        // must preserve metadata without consulting or capturing its source.
        try CaptureChainDefinition(name: "Prepared long screenshot", source: .preset(UUID()), outputs: outputs)
    }

    private func receipt(_ output: CaptureChainOutput, saved: SaveWorkflowSummary, pinID: UUID) -> CaptureChainReceipt {
        switch output {
        case .quickSavePNG: return .init(output: output, value: .saved(saved.savedURL, byteCount: saved.byteCount))
        case .copy: return .init(output: output, value: .copied)
        case .pin: return .init(output: output, value: .pinned(pinID))
        }
    }

    private func unexpectedDependencies() -> CaptureChainRunner.Dependencies {
        .init(capture: { XCTFail("Prepared input acquired a new screenshot"); throw Failure.unexpectedAcquisition },
            savePNG: { _ in XCTFail("Unexpected Save replay"); return .cancelled },
            copy: { _ in XCTFail("Unexpected Copy replay") },
            pin: { _ in XCTFail("Unexpected Pin replay"); return UUID() }, cancelSave: {},
            cancelCapture: { XCTFail("Prepared input cancelled unrelated acquisition") })
    }

    private func raster() throws -> CGImage { try SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8) }
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "Prepared chain did not reach its explicit output barrier")
    }
    private func assertReleased(_ runner: CaptureChainRunner, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(runner.capture, file: file, line: line)
        XCTAssertEqual(runner.retainedBytes, 0, file: file, line: line)
        XCTAssertFalse(runner.isAttemptRunning, file: file, line: line)
        XCTAssertFalse(runner.blocksCapture, file: file, line: line)
        XCTAssertNil(runner.onChange, file: file, line: line); XCTAssertNil(runner.onTerminal, file: file, line: line)
    }
    private enum Failure: Error { case unexpectedAcquisition, output }

    @MainActor private final class Gate<Value> {
        private var continuation: CheckedContinuation<Value, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                precondition(self.continuation == nil); self.continuation = continuation
            }
        }
        @discardableResult func resolve(_ value: Value) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil; continuation.resume(returning: value); return true
        }
    }
    @MainActor private struct Files {
        let root: URL
        init() throws { root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-PreparedChain-" + UUID().uuidString) }
        func save(_ image: CGImage) throws -> SaveWorkflowSummary {
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init())
            return SaveWorkflowSummary(try SaveWorkflowService.publish(artifact,
                to: root.appendingPathComponent(UUID().uuidString + ".png")))
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
