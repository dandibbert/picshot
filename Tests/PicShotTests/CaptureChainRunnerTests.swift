import AppKit
import XCTest
import PicShotCore
@testable import PicShot

/// Synthetic selections, continuation barriers and private canonical temp files.
/// No desktop acquisition, general clipboard, editor, history or live pin store.
@MainActor
final class CaptureChainRunnerTests: XCTestCase {
    func testEveryOrderedSelectionUsesOneCaptureAndIdenticalPixels() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source(), expectedPixels = try pixels(image)
        let capturedAt = Date(timeIntervalSince1970: 42), pinID = UUID()
        let choices: [CaptureChainOutput] = [.quickSavePNG, .copy, .pin]
        var selections = choices.map { [$0] }
        for first in choices {
            for second in choices where second != first {
                selections.append([first, second])
                for third in choices where third != first && third != second {
                    selections.append([first, second, third])
                }
            }
        }
        XCTAssertEqual(selections.count, 15)
        for outputs in selections {
            var captures = 0, seen: [CaptureChainOutput] = [], terminals: [CaptureChainSnapshot] = []
            let check: (CGImage, CaptureChainOutput) -> Void = { actual, output in
                XCTAssertTrue(actual === image)
                XCTAssertEqual(try? self.pixels(actual), expectedPixels)
                seen.append(output)
            }
            let runner = CaptureChainRunner(definition: try definition(outputs), dependencies: .init(
                capture: { captures += 1; return try ChainCapture(image: image, capturedAt: capturedAt, encodedBackingBytes: 19) },
                savePNG: { actual in
                    check(actual, .quickSavePNG)
                    do { return .committed(try fixture.save(actual)) }
                    catch { return .failed(.operation(error)) }
                },
                copy: { check($0, .copy) }, pin: { check($0, .pin); return pinID },
                cancelSave: { XCTFail("Successful chain must not cancel a save") }))
            runner.onTerminal = { terminals.append($0) }
            XCTAssertTrue(runner.start()); XCTAssertFalse(runner.start())
            try await until { runner.status.isTerminal }
            XCTAssertEqual(runner.status, .completed)
            XCTAssertEqual(captures, 1); XCTAssertEqual(seen, outputs)
            XCTAssertEqual(runner.receipts.map(\.output), outputs)
            XCTAssertEqual(runner.capturedAt, capturedAt)
            XCTAssertEqual(terminals.count, 1); XCTAssertEqual(terminals.first?.runID, runner.id)
            assertReleased(runner)
            XCTAssertFalse(runner.retry()); XCTAssertFalse(runner.cancel()); XCTAssertFalse(runner.start())
            XCTAssertEqual(terminals.count, 1)
            for receipt in runner.receipts {
                switch receipt.value {
                case .saved(let url, let bytes):
                    XCTAssertEqual(try Data(contentsOf: url).count, bytes)
                    XCTAssertEqual(try pixels(SaveWorkflowUIPreviewFixture.decode(url)), expectedPixels)
                case .copied: XCTAssertEqual(receipt.output, .copy)
                case .pinned(let savedID): XCTAssertEqual(savedID, pinID)
                }
            }
        }
    }

    func testSaveThenCopyFailureRetriesOnlyTheUnfinishedSuffix() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source(), originalPixels = try pixels(image)
        var captures = 0, saves = 0, copies = 0, pins = 0
        let runner = CaptureChainRunner(definition: try definition([.quickSavePNG, .copy, .pin]), dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: image, encodedBackingBytes: 27) },
            savePNG: { actual in
                XCTAssertTrue(actual === image); saves += 1
                do { return .committed(try fixture.save(actual)) } catch { return .failed(.operation(error)) }
            }, copy: { actual in
                XCTAssertTrue(actual === image); XCTAssertEqual(try self.pixels(actual), originalPixels)
                copies += 1
                if copies == 1 { throw FixtureError.output }
            }, pin: { actual in XCTAssertTrue(actual === image); pins += 1; return UUID() }, cancelSave: {}))
        XCTAssertTrue(runner.start())
        try await until { runner.status.canRetry }
        XCTAssertEqual(runner.status, .failed(index: 1, message: FixtureError.output.localizedDescription))
        XCTAssertEqual(runner.retainedBytes, image.bytesPerRow * image.height + 27)
        XCTAssertTrue(runner.capture?.image === image); XCTAssertTrue(runner.blocksCapture)
        XCTAssertEqual(runner.receipts.map(\.output), [.quickSavePNG])
        XCTAssertEqual(pins, 0); XCTAssertFalse(runner.start())
        let saved = runner.receipts
        XCTAssertTrue(runner.retry()); XCTAssertFalse(runner.retry()); XCTAssertFalse(runner.start())
        try await until { runner.status == .completed }
        XCTAssertEqual(captures, 1); XCTAssertEqual(saves, 1); XCTAssertEqual(copies, 2); XCTAssertEqual(pins, 1)
        XCTAssertEqual(Array(runner.receipts.prefix(1)), saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count, 1)
        assertReleased(runner)
    }

    func testPinThenSaveFailureNeverDuplicatesTheCommittedPin() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source(), pinnedID = UUID()
        var captures = 0, pins = 0, saves = 0, copies = 0
        let runner = CaptureChainRunner(definition: try definition([.pin, .quickSavePNG, .copy]), dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: image) },
            savePNG: { actual in
                XCTAssertTrue(actual === image); saves += 1
                if saves == 1 { return .failed(.operation(FixtureError.output)) }
                do { return .committed(try fixture.save(actual)) } catch { return .failed(.operation(error)) }
            }, copy: { _ in copies += 1 }, pin: { _ in pins += 1; return pinnedID }, cancelSave: {}))
        XCTAssertTrue(runner.start())
        try await until { runner.status.canRetry }
        XCTAssertEqual(runner.receipts, [.init(output: .pin, value: .pinned(pinnedID))])
        XCTAssertEqual(copies, 0); XCTAssertTrue(runner.retry())
        try await until { runner.status == .completed }
        XCTAssertEqual(captures, 1); XCTAssertEqual(pins, 1); XCTAssertEqual(saves, 2); XCTAssertEqual(copies, 1)
        assertReleased(runner)
    }

    func testRepeatedOutputFailureReplacesBoundedErrorAndCancelReleasesPixels() async throws {
        let image = try source()
        var attempts = 0, captures = 0, terminals = 0
        let runner = CaptureChainRunner(definition: try definition([.copy, .pin]), dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: image) }, savePNG: { _ in XCTFail(); return .cancelled },
            copy: { _ in attempts += 1; throw NSError(domain: "fixture", code: attempts,
                userInfo: [NSLocalizedDescriptionKey: String(repeating: "failure ", count: 10_000)]) },
            pin: { _ in XCTFail("A failed preceding output must stop Pin"); return UUID() }, cancelSave: {}))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start())
        for expectedAttempts in 1...4 {
            try await until { runner.status.canRetry }
            XCTAssertEqual(attempts, expectedAttempts)
            guard case .failed(let index, let message) = runner.status else { return XCTFail() }
            XCTAssertEqual(index, 0); XCTAssertLessThanOrEqual(message.utf8.count, 4_098)
            XCTAssertTrue(runner.receipts.isEmpty); XCTAssertTrue(runner.capture?.image === image)
            XCTAssertFalse(runner.isAttemptRunning); XCTAssertTrue(runner.blocksCapture)
            if expectedAttempts < 4 { XCTAssertTrue(runner.retry()); XCTAssertFalse(runner.retry()) }
        }
        XCTAssertEqual(captures, 1); XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.cancel())
        XCTAssertEqual(runner.status, .cancelled); XCTAssertEqual(terminals, 1)
        assertReleased(runner)
    }

    func testCaptureErrorAndCaptureCancellationAreTerminalWithoutOutputs() async throws {
        let cases: [(Error, CaptureChainStatus)] = [
            (FixtureError.capture, .captureFailed(message: FixtureError.capture.localizedDescription)),
            (CancellationError(), .cancelled),
            (CaptureError.cancelled, .cancelled)
        ]
        for (error, expectedStatus) in cases {
            var captures = 0, terminals = 0
            let runner = CaptureChainRunner(definition: try definition([.copy]), dependencies: .init(
                capture: { captures += 1; throw error }, savePNG: { _ in XCTFail(); return .cancelled },
                copy: { _ in XCTFail() }, pin: { _ in XCTFail(); return UUID() }, cancelSave: {}))
            runner.onTerminal = { _ in terminals += 1 }
            XCTAssertTrue(runner.start())
            try await until { runner.status.isTerminal }
            XCTAssertEqual(runner.status, expectedStatus)
            XCTAssertEqual(captures, 1); XCTAssertEqual(terminals, 1)
            XCTAssertTrue(runner.receipts.isEmpty); XCTAssertNil(runner.capturedAt)
            XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry()); XCTAssertFalse(runner.cancel())
            XCTAssertEqual(terminals, 1)
            assertReleased(runner)
        }
    }

    func testRegionEscapeCancellationDrainsSelectionAndRetiresExactlyOnce() async throws {
        let gate = Gate<Void>(), counter = CaptureTestProviderCounter()
        var captures = 0, terminalSnapshots: [CaptureChainSnapshot] = []
        let runner = CaptureChainRunner(definition: try definition([.copy]), dependencies: .init(
            capture: {
                captures += 1
                let selecting = try ChainCapture(image:
                    CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter))
                await gate.wait()
                withExtendedLifetime(selecting) {}
                throw CaptureError.cancelled
            }, savePNG: { _ in XCTFail(); return .cancelled }, copy: { _ in XCTFail() },
            pin: { _ in XCTFail(); return UUID() }, cancelSave: { XCTFail() }))
        runner.onTerminal = { [weak runner] snapshot in
            terminalSnapshots.append(snapshot)
            XCTAssertEqual(snapshot.status, .cancelled)
            XCTAssertEqual(snapshot.retainedBytes, 0)
            XCTAssertNil(runner?.capture); XCTAssertFalse(runner?.isAttemptRunning == true)
        }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertEqual(counter.liveBytes, 8 * 8 * 4)
        XCTAssertEqual(runner.status, .capturing); XCTAssertTrue(runner.blocksCapture)
        XCTAssertTrue(terminalSnapshots.isEmpty)
        XCTAssertTrue(gate.resolve(()))
        try await until { runner.status == .cancelled && counter.liveBytes == 0 }
        XCTAssertEqual(captures, 1); XCTAssertEqual(counter.deallocations, 1)
        XCTAssertEqual(terminalSnapshots.count, 1); XCTAssertEqual(terminalSnapshots.first?.runID, runner.id)
        XCTAssertTrue(runner.receipts.isEmpty); XCTAssertNil(runner.capturedAt)
        XCTAssertFalse(runner.cancel()); XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry())
        XCTAssertFalse(gate.resolve(())); XCTAssertEqual(terminalSnapshots.count, 1)
        assertReleased(runner)
    }

    func testImmediateCancelPreventsCaptureAndDuplicateCommands() async throws {
        var captures = 0, captureCancels = 0
        let runner = CaptureChainRunner(definition: try definition([.copy]), dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: self.source()) },
            savePNG: { _ in XCTFail(); return .cancelled }, copy: { _ in XCTFail() },
            pin: { _ in XCTFail(); return UUID() }, cancelSave: {}, cancelCapture: { captureCancels += 1 }))
        XCTAssertTrue(runner.start()); XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry())
        XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.cancel()); XCTAssertFalse(runner.start())
        XCTAssertEqual(runner.status, .cancelling)
        XCTAssertTrue(runner.blocksCapture); XCTAssertTrue(runner.isAttemptRunning)
        try await until { runner.status == .cancelled }
        XCTAssertEqual(captures, 0); XCTAssertEqual(captureCancels, 1)
        assertReleased(runner)
    }

    func testSuspendedCaptureDrainsAndRejectsItsLateImageAfterCancel() async throws {
        let gate = Gate<ChainCapture>(), counter = CaptureTestProviderCounter()
        var captureCancels = 0, terminals = 0
        let runner = CaptureChainRunner(definition: try definition([.copy]), dependencies: .init(
            capture: { await gate.wait() }, savePNG: { _ in XCTFail(); return .cancelled },
            copy: { _ in XCTFail() }, pin: { _ in XCTFail(); return UUID() }, cancelSave: {},
            cancelCapture: { captureCancels += 1 }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.retry()); XCTAssertFalse(runner.start())
        XCTAssertEqual(runner.status, .cancelling); XCTAssertEqual(terminals, 0)
        XCTAssertEqual(captureCancels, 1); XCTAssertTrue(runner.isAttemptRunning)
        try autoreleasepool {
            XCTAssertTrue(gate.resolve(try ChainCapture(image:
                CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter))))
        }
        try await until { runner.status == .cancelled && counter.liveBytes == 0 }
        XCTAssertEqual(counter.deallocations, 1); XCTAssertEqual(terminals, 1)
        XCTAssertNil(runner.capturedAt); XCTAssertTrue(runner.receipts.isEmpty)
        assertReleased(runner)
    }

    func testCommittedSaveWinsCancellationBeforeDeliveryAndStopsLaterOutputs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source(), gate = Gate<SaveWorkflowTerminalOutcome>()
        var summary: SaveWorkflowSummary?, saves = 0, saveCancels = 0, terminals = 0
        let runner = CaptureChainRunner(definition: try definition([.quickSavePNG, .copy, .pin]), dependencies: .init(
            capture: { try ChainCapture(image: image) }, savePNG: { actual in
                saves += 1
                do { summary = try fixture.save(actual) } catch { return .failed(.operation(error)) }
                return await gate.wait()
            }, copy: { _ in XCTFail("Copy must not follow a cancelled committed save") },
            pin: { _ in XCTFail(); return UUID() }, cancelSave: { saveCancels += 1 }))
        runner.onTerminal = { result in
            terminals += 1
            XCTAssertEqual(result.retainedBytes, 0); XCTAssertEqual(result.receipts.count, 1)
        }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        let committed = try XCTUnwrap(summary), bytes = try Data(contentsOf: committed.savedURL)
        XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.cancel())
        XCTAssertEqual(runner.status, .cancelling); XCTAssertGreaterThan(runner.retainedBytes, 0)
        XCTAssertEqual(terminals, 0); XCTAssertEqual(saveCancels, 1)
        XCTAssertTrue(gate.resolve(.committed(committed)))
        try await until { runner.status == .cancelled }
        XCTAssertEqual(saves, 1); XCTAssertEqual(terminals, 1)
        XCTAssertEqual(runner.receipts, [.init(output: .quickSavePNG,
            value: .saved(committed.savedURL, byteCount: committed.byteCount))])
        XCTAssertEqual(try Data(contentsOf: committed.savedURL), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count, 1)
        assertReleased(runner)
    }

    func testCancelledOrFailedSaveDrainKeepsReservationUntilItReturns() async throws {
        for outcome in [SaveWorkflowTerminalOutcome.cancelled, .failed(.timedOut)] {
            let gate = Gate<SaveWorkflowTerminalOutcome>(), counter = CaptureTestProviderCounter()
            var saveCancels = 0, terminals = 0
            let runner = CaptureChainRunner(definition: try definition([.quickSavePNG, .copy]), dependencies: .init(
                capture: { try ChainCapture(image: CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter)) },
                savePNG: { _ in await gate.wait() }, copy: { _ in XCTFail() },
                pin: { _ in XCTFail(); return UUID() }, cancelSave: { saveCancels += 1 }))
            runner.onTerminal = { _ in terminals += 1 }
            XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
            XCTAssertEqual(counter.liveBytes, 8 * 8 * 4)
            XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.retry())
            XCTAssertEqual(runner.retainedBytes, 8 * 8 * 4)
            XCTAssertEqual(terminals, 0); XCTAssertEqual(saveCancels, 1)
            XCTAssertTrue(gate.resolve(outcome))
            try await until { runner.status == .cancelled && counter.liveBytes == 0 }
            XCTAssertEqual(counter.deallocations, 1); XCTAssertEqual(terminals, 1)
            XCTAssertTrue(runner.receipts.isEmpty)
            assertReleased(runner)
        }
    }

    func testSavePickerCancelPreservesEarlierPinReceiptAndEndsTheRun() async throws {
        let image = try source(), pinnedID = UUID()
        let runner = CaptureChainRunner(definition: try definition([.pin, .quickSavePNG, .copy]), dependencies: .init(
            capture: { try ChainCapture(image: image) }, savePNG: { _ in .cancelled },
            copy: { _ in XCTFail() }, pin: { _ in pinnedID }, cancelSave: {}))
        XCTAssertTrue(runner.start()); try await until { runner.status == .cancelled }
        XCTAssertEqual(runner.receipts, [.init(output: .pin, value: .pinned(pinnedID))])
        XCTAssertFalse(runner.retry()); assertReleased(runner)
    }

    func testSynchronousReentrantCancelRecordsCopyOrPinBeforeStopping() async throws {
        let image = try source(), pinnedID = UUID()
        for output in [CaptureChainOutput.copy, .pin] {
            weak var current: CaptureChainRunner?
            let runner = CaptureChainRunner(definition: try definition([output, .quickSavePNG]), dependencies: .init(
                capture: { try ChainCapture(image: image) }, savePNG: { _ in XCTFail(); return .cancelled },
                copy: { _ in XCTAssertTrue(current?.cancel() == true) },
                pin: { _ in XCTAssertTrue(current?.cancel() == true); return pinnedID }, cancelSave: {}))
            current = runner
            XCTAssertTrue(runner.start()); try await until { runner.status == .cancelled }
            XCTAssertEqual(runner.receipts, [.init(output: output,
                value: output == .copy ? .copied : .pinned(pinnedID))])
            assertReleased(runner)
        }
    }

    func testCancelFromStatusCallbackPreventsNextDispatch() async throws {
        let image = try source()
        var copies = 0, pins = 0
        let runner = CaptureChainRunner(definition: try definition([.copy, .pin]), dependencies: .init(
            capture: { try ChainCapture(image: image) }, savePNG: { _ in XCTFail(); return .cancelled },
            copy: { _ in copies += 1 }, pin: { _ in pins += 1; return UUID() }, cancelSave: {}))
        runner.onChange = { [weak runner] snapshot in
            if snapshot.status == .running(index: 1) { XCTAssertTrue(runner?.cancel() == true) }
        }
        XCTAssertTrue(runner.start()); try await until { runner.status == .cancelled }
        XCTAssertEqual(copies, 1); XCTAssertEqual(pins, 0)
        XCTAssertEqual(runner.receipts, [.init(output: .copy, value: .copied)])
        assertReleased(runner)
    }

    func testReentrantRetryCannotBeClearedByTheOlderAttemptReturning() async throws {
        let image = try source(), gate = Gate<SaveWorkflowTerminalOutcome>()
        var captures = 0, copies = 0, failures = 0
        let runner = CaptureChainRunner(definition: try definition([.copy, .quickSavePNG]), dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: image) }, savePNG: { _ in await gate.wait() },
            copy: { _ in copies += 1; if copies == 1 { throw FixtureError.output } },
            pin: { _ in XCTFail(); return UUID() }, cancelSave: {}))
        runner.onChange = { [weak runner] snapshot in
            if snapshot.status.canRetry {
                failures += 1
                XCTAssertTrue(runner?.retry() == true)
                XCTAssertFalse(runner?.retry() == true)
            }
        }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertEqual(captures, 1); XCTAssertEqual(copies, 2); XCTAssertEqual(failures, 1)
        XCTAssertTrue(runner.isAttemptRunning); XCTAssertEqual(runner.status, .running(index: 1))
        XCTAssertEqual(runner.receipts, [.init(output: .copy, value: .copied)])
        XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry())
        XCTAssertTrue(runner.cancel()); XCTAssertEqual(runner.status, .cancelling)
        XCTAssertTrue(gate.resolve(.cancelled)); try await until { runner.status == .cancelled }
        assertReleased(runner)
    }

    func testSuccessfulRetirementReleasesClosureOwnersAndOldRunnerCannotAffectNewRun() async throws {
        let oldCounter = CaptureTestProviderCounter(), newGate = Gate<ChainCapture>()
        var oldTerminalCalls = 0
        weak var weakOwner: ClosureOwner?
        var first: CaptureChainRunner!
        do {
            let owner = ClosureOwner()
            weakOwner = owner
            first = CaptureChainRunner(definition: try definition([.copy]), dependencies: .init(
                capture: { [owner] in
                    _ = owner
                    return try ChainCapture(image: CaptureTestProviderCounter.image(width: 8, height: 8, counter: oldCounter))
                }, savePNG: { _ in XCTFail(); return .cancelled }, copy: { _ in },
                pin: { _ in XCTFail(); return UUID() }, cancelSave: {}))
            first.onTerminal = { [owner] _ in _ = owner; oldTerminalCalls += 1 }
        }
        XCTAssertNotNil(weakOwner); XCTAssertTrue(first.start())
        try await until { first.status == .completed && weakOwner == nil && oldCounter.liveBytes == 0 }
        XCTAssertEqual(oldCounter.deallocations, 1); XCTAssertEqual(oldTerminalCalls, 1)
        assertReleased(first)
        let second = CaptureChainRunner(definition: try definition([.copy]), dependencies: .init(
            capture: { await newGate.wait() }, savePNG: { _ in XCTFail(); return .cancelled },
            copy: { _ in }, pin: { _ in XCTFail(); return UUID() }, cancelSave: {}))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(second.start()); try await until { newGate.isWaiting }
        XCTAssertFalse(first.cancel()); XCTAssertFalse(first.retry()); XCTAssertFalse(first.start())
        XCTAssertEqual(second.status, .capturing); XCTAssertTrue(second.isAttemptRunning)
        XCTAssertEqual(oldTerminalCalls, 1)
        XCTAssertTrue(newGate.resolve(try ChainCapture(image: source())))
        try await until { second.status == .completed }
        assertReleased(second)
    }

    func testDetachedSelectionDoesNotRetainFrozenDesktopWhileOutputIsPending() async throws {
        let frozen = CaptureTestProviderCounter(), gate = Gate<SaveWorkflowTerminalOutcome>()
        let capturedAt = Date(timeIntervalSince1970: 123)
        let runner = CaptureChainRunner(definition: try definition([.quickSavePNG]), dependencies: .init(
            capture: {
                try autoreleasepool {
                    let desktop = try CaptureTestProviderCounter.image(width: 16, height: 16, counter: frozen)
                    let selected = try CapturedImage.frozenPixelRegion(image: desktop, displayID: 0,
                        displayFrame: CGRect(x: 0, y: 0, width: 16, height: 16),
                        pixelFrame: CGRect(x: 2, y: 3, width: 8, height: 8), capturedAt: capturedAt)
                    return try ChainCapture(image: selected.image, capturedAt: selected.capturedAt)
                }
            }, savePNG: { _ in await gate.wait() }, copy: { _ in XCTFail() },
            pin: { _ in XCTFail(); return UUID() }, cancelSave: {}))
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting && frozen.liveBytes == 0 }
        XCTAssertEqual(frozen.deallocations, 1)
        XCTAssertEqual(runner.retainedBytes, 8 * 8 * 4); XCTAssertEqual(runner.capturedAt, capturedAt)
        XCTAssertEqual(runner.capture?.image.width, 8); XCTAssertEqual(runner.capture?.image.height, 8)
        XCTAssertTrue(runner.cancel()); XCTAssertTrue(gate.resolve(.cancelled))
        try await until { runner.status == .cancelled }
        assertReleased(runner)
    }

    func testRetainedCaptureUsesExistingRecoveryByteLimits() throws {
        let image = try source(), rasterBytes = image.bytesPerRow * image.height
        let capture = try ChainCapture(image: image, encodedBackingBytes: 123)
        XCTAssertEqual(capture.retainedBytes, rasterBytes + 123)
        XCTAssertTrue(capture.image === image)
        XCTAssertThrowsError(try ChainCapture(image: image, encodedBackingBytes: -1))
        XCTAssertThrowsError(try ChainCapture(image: image,
            encodedBackingBytes: CaptureRecoveryPolicy.maximumEncodedBytes + 1))
    }

    func testSavedDefinitionBytesNeverAcquireRuntimeStateAcrossFailureRetryAndCancel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try CaptureChainStore(directory: fixture.root.appendingPathComponent("definitions"))
        let savedDefinition = try definition([.pin, .copy]), pinID = UUID(), image = try source()
        try store.add(savedDefinition); try store.select(id: savedDefinition.id)
        let manifest = store.directory.appendingPathComponent(CaptureChainStore.manifestFilename)
        let originalBytes = try Data(contentsOf: manifest)
        var captures = 0, pins = 0, copies = 0
        let runner = CaptureChainRunner(definition: savedDefinition, dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: image) },
            savePNG: { _ in XCTFail(); return .cancelled },
            copy: { _ in copies += 1; throw FixtureError.output },
            pin: { _ in pins += 1; return pinID }, cancelSave: {}))
        XCTAssertTrue(runner.start()); try await until { runner.status.canRetry }
        XCTAssertEqual(try Data(contentsOf: manifest), originalBytes)
        XCTAssertTrue(runner.retry()); try await until { runner.status.canRetry }
        XCTAssertEqual(try Data(contentsOf: manifest), originalBytes)
        XCTAssertTrue(runner.cancel()); assertReleased(runner)
        XCTAssertEqual(try Data(contentsOf: manifest), originalBytes)
        XCTAssertEqual(try CaptureChainStore(directory: store.directory).index, store.index)
        XCTAssertEqual(captures, 1); XCTAssertEqual(pins, 1); XCTAssertEqual(copies, 2)
        XCTAssertEqual(runner.receipts, [.init(output: .pin, value: .pinned(pinID))])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path),
            [CaptureChainStore.manifestFilename])
    }

    private func definition(_ outputs: [CaptureChainOutput]) throws -> CaptureChainDefinition {
        try CaptureChainDefinition(name: "Fixture chain", source: .region, outputs: outputs)
    }

    private func source() throws -> CGImage { try SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8) }
    private func pixels(_ image: CGImage) throws -> Data { try SaveWorkflowUIPreviewFixture.pixels(image) }
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "Capture chain did not reach the expected deterministic barrier")
    }

    private func assertReleased(_ runner: CaptureChainRunner, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(runner.capture, file: file, line: line)
        XCTAssertEqual(runner.retainedBytes, 0, file: file, line: line)
        XCTAssertEqual(runner.snapshot.retainedBytes, 0, file: file, line: line)
        XCTAssertFalse(runner.blocksCapture, file: file, line: line)
        XCTAssertFalse(runner.isAttemptRunning, file: file, line: line)
        XCTAssertNil(runner.onChange, file: file, line: line)
        XCTAssertNil(runner.onTerminal, file: file, line: line)
    }

    private enum FixtureError: LocalizedError {
        case capture, output
        var errorDescription: String? {
            switch self {
            case .capture: return "Fixture capture failed"
            case .output: return "Fixture output failed"
            }
        }
    }

    private final class ClosureOwner {}

    /// Completion is explicitly controlled, including uncooperative cancellation.
    /// No result is retained after resume, so provider cleanup remains observable.
    @MainActor private final class Gate<Value> {
        private var continuation: CheckedContinuation<Value, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                precondition(self.continuation == nil)
                self.continuation = continuation
            }
        }
        @discardableResult func resolve(_ value: Value) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: value)
            return true
        }
    }

    @MainActor private struct Fixture {
        let root: URL
        init() throws {
            root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-CaptureChainRunner-" + UUID().uuidString)
        }
        func save(_ image: CGImage) throws -> SaveWorkflowSummary {
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init())
            return SaveWorkflowSummary(try SaveWorkflowService.publish(artifact,
                to: root.appendingPathComponent(UUID().uuidString + ".png")))
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
