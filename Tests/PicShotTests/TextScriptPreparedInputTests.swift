import AppKit
import PicShotCore
import PicShotTextScriptCore
import XCTest
@testable import PicShot

/// Generated rasters and text only. Prepared runs share the existing OCR,
/// transform and checked Copy contract without capture or helper processes.
@MainActor final class TextScriptPreparedInputTests: XCTestCase {
    func testPreparedEntryPreservesIdentityTimestampAndStartsAtRecognitionWithoutAcquisition() async throws {
        let image = try raster(), capturedAt = Date(timeIntervalSince1970: 280), runID = UUID()
        let capture = try ChainCapture(image: image, capturedAt: capturedAt, encodedBackingBytes: 13)
        let script = try definition()
        var captures = 0, events: [String] = [], snapshots: [CaptureChainSnapshot] = [], terminals = 0
        let runner = try CaptureChainRunner(textScript: script, preparedCapture: capture, dependencies: .init(
            capture: { captures += 1; throw Failure.unexpectedAcquisition },
            recognize: { actual in
                XCTAssertTrue(actual === image); events.append("recognize")
                return .init(text: "recognized fixture")
            }, transform: { source, text, _ in
                XCTAssertEqual(source, script.source); XCTAssertEqual(text, "recognized fixture")
                events.append("transform"); return .succeeded("prepared fixture 🐈")
            }, copy: { text in
                XCTAssertEqual(text, "prepared fixture 🐈"); events.append("copy")
            }, cleanupComplete: { _ in XCTFail("Successful transform has no cleanup reservation"); return false },
            cancelCapture: { XCTFail("Prepared text cannot cancel acquisition") }), id: runID)
        runner.onChange = { snapshots.append($0) }; runner.onTerminal = { _ in terminals += 1 }
        XCTAssertEqual(runner.id, runID); XCTAssertEqual(runner.status, .idle)
        XCTAssertTrue(runner.capture?.image === image)
        XCTAssertEqual(runner.capture?.capturedAt, capturedAt)
        XCTAssertEqual(runner.capture?.encodedBackingBytes, 13)
        XCTAssertEqual(runner.capture?.retainedBytes, capture.retainedBytes)
        XCTAssertEqual(runner.retainedBytes, capture.retainedBytes + script.source.utf8.count)
        XCTAssertEqual(runner.definition.id, script.id); XCTAssertEqual(runner.definition.name, script.name)
        XCTAssertEqual(runner.definition.source, .region); XCTAssertEqual(runner.definition.outputs, [.copy])
        XCTAssertTrue(runner.isTextScript); XCTAssertTrue(runner.isExistingScrollImage)
        XCTAssertFalse(runner.retry()); XCTAssertTrue(runner.start())
        XCTAssertEqual(runner.status, .preparingText(.recognize))
        XCTAssertEqual(snapshots.first?.status, .preparingText(.recognize))
        XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry())
        try await until { runner.status == .completed }
        XCTAssertEqual(captures, 0); XCTAssertEqual(events, ["recognize", "transform", "copy"])
        XCTAssertEqual(terminals, 1); XCTAssertTrue(runner.receipts.isEmpty)
        XCTAssertEqual(runner.textReceipt, ChainTextCopyReceipt(characterCount: "prepared fixture 🐈".count))
        XCTAssertTrue(snapshots.allSatisfy { $0.runID == runID && $0.capturedAt == capturedAt &&
            $0.isTextScript && $0.isExistingScrollImage })
        XCTAssertFalse(snapshots.contains { $0.status == .capturing || $0.status == .running(index: 0) })
        assertReleased(runner)
    }

    func testSuccessfulRecognitionReleasesPreparedProviderBeforeTransformCompletes() async throws {
        let counter = CaptureTestProviderCounter(), gate = Gate<ChainTextTransformResult>()
        defer { gate.resolve(.cancelled(cleanupPending: false)) }
        var snapshots: [CaptureChainSnapshot] = [], copies = 0
        let runner = try autoreleasepool {
            try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image:
                CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter)), dependencies: .init(
                    capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                    recognize: { _ in .init(text: "fixture OCR") }, transform: { _, _, _ in await gate.wait() },
                    copy: { _ in copies += 1 }, cleanupComplete: { _ in XCTFail(); return false }))
        }
        runner.onChange = { snapshots.append($0) }
        XCTAssertEqual(counter.liveBytes, 8 * 8 * 4)
        XCTAssertTrue(runner.start())
        try await until { gate.isWaiting && counter.liveBytes == 0 }
        XCTAssertEqual(runner.status, .preparingText(.transform)); XCTAssertNil(runner.capture)
        XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1)
        XCTAssertEqual(runner.retainedBytes, "return text;fixture OCR".utf8.count)
        XCTAssertEqual(runner.retainedBytes, runner.retainedTextBytes)
        XCTAssertTrue(runner.blocksCapture); XCTAssertEqual(copies, 0)
        XCTAssertTrue(gate.resolve(.succeeded("fixture output")))
        try await until { runner.status == .completed }
        XCTAssertEqual(copies, 1); XCTAssertEqual(snapshots.last?.retainedBytes, 0)
        XCTAssertEqual(counter.deallocations, 1); assertReleased(runner)
    }

    func testCopyRefusalRetriesOnlyCachedTransformedTextWithoutAcquisitionOCROrHelper() async throws {
        let image = try raster(), capturedAt = Date(timeIntervalSince1970: 281)
        let output = "cached output 🐈", source = "return text;"
        var script = try definition(source: source)
        var captures = 0, recognitions = 0, transforms = 0, copies: [String] = [], terminals = 0
        let runner = try CaptureChainRunner(textScript: script, preparedCapture: ChainCapture(image: image,
            capturedAt: capturedAt), dependencies: .init(
                capture: { captures += 1; throw Failure.unexpectedAcquisition },
                recognize: { actual in
                    XCTAssertTrue(actual === image); recognitions += 1; return .init(text: "fixture OCR")
                }, transform: { actualSource, text, _ in
                    XCTAssertEqual(actualSource, source); XCTAssertEqual(text, "fixture OCR")
                    transforms += 1; return .succeeded(output)
                }, copy: { text in copies.append(text); if copies.count == 1 { throw Failure.copyRefused } },
                cleanupComplete: { _ in XCTFail(); return false }))
        runner.onTerminal = { _ in terminals += 1 }
        script = try TextScriptDefinition(id: script.id, name: "Changed fixture", source: "throw text;")
        XCTAssertTrue(runner.start()); try await until { runner.status.canRetry }
        XCTAssertEqual(runner.status, .textFailed(.copy, .clipboardRejected))
        XCTAssertEqual(runner.definition.name, "Prepared text fixture")
        XCTAssertNil(runner.capture); XCTAssertNil(runner.textReceipt)
        XCTAssertEqual(runner.retainedTextBytes, output.utf8.count)
        XCTAssertEqual(runner.capturedAt, capturedAt); XCTAssertTrue(runner.blocksCapture)
        XCTAssertFalse(runner.start()); XCTAssertTrue(runner.retry()); XCTAssertFalse(runner.retry())
        try await until { runner.status == .completed }
        XCTAssertEqual(captures, 0); XCTAssertEqual(recognitions, 1); XCTAssertEqual(transforms, 1)
        XCTAssertEqual(copies, [output, output]); XCTAssertEqual(terminals, 1)
        XCTAssertEqual(runner.textReceipt, ChainTextCopyReceipt(characterCount: output.count)); assertReleased(runner)
    }

    func testRecognitionFailureRetriesSamePreparedRasterAndTimestampWithoutAcquisition() async throws {
        let image = try raster(), capturedAt = Date(timeIntervalSince1970: 282)
        let capture = try ChainCapture(image: image, capturedAt: capturedAt, encodedBackingBytes: 9)
        var captures = 0, recognitions = 0, transforms = 0, copies = 0
        let runner = try CaptureChainRunner(textScript: definition(), preparedCapture: capture, dependencies: .init(
            capture: { captures += 1; throw Failure.unexpectedAcquisition },
            recognize: { actual in
                XCTAssertTrue(actual === image); recognitions += 1
                if recognitions == 1 { throw Failure.recognition }
                return .init(text: "fixture OCR")
            }, transform: { _, _, _ in transforms += 1; return .succeeded("fixture output") },
            copy: { _ in copies += 1 }, cleanupComplete: { _ in XCTFail(); return false }))
        XCTAssertTrue(runner.start()); try await until { runner.status.canRetry }
        XCTAssertEqual(runner.status, .textFailed(.recognize, .recognitionFailed))
        XCTAssertTrue(runner.capture?.image === image); XCTAssertEqual(runner.capturedAt, capturedAt)
        XCTAssertEqual(runner.capture?.encodedBackingBytes, 9)
        XCTAssertEqual(runner.retainedBytes, capture.retainedBytes + "return text;".utf8.count)
        XCTAssertTrue(runner.retry()); XCTAssertFalse(runner.retry())
        try await until { runner.status == .completed }
        XCTAssertEqual(captures, 0); XCTAssertEqual(recognitions, 2); XCTAssertEqual(transforms, 1)
        XCTAssertEqual(copies, 1); XCTAssertEqual(runner.capturedAt, capturedAt); assertReleased(runner)
    }

    func testImmediateCancelReleasesPreparedInputWithoutAnyDependencyDispatch() async throws {
        let counter = CaptureTestProviderCounter()
        var terminals = 0
        let runner = try autoreleasepool {
            try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image:
                CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter)), dependencies: .init(
                    capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                    recognize: { _ in XCTFail(); return .init(text: "unused") },
                    transform: { _, _, _ in XCTFail(); return .succeeded("unused") },
                    copy: { _ in XCTFail() }, cleanupComplete: { _ in XCTFail(); return false },
                    cancelCapture: { XCTFail("Prepared input has no acquisition to cancel") }))
        }
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); XCTAssertEqual(runner.status, .preparingText(.recognize))
        XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.cancel())
        XCTAssertEqual(runner.status, .cancelling); XCTAssertTrue(runner.blocksCapture)
        XCTAssertNil(runner.capture); XCTAssertEqual(runner.retainedTextBytes, 0)
        try await until { runner.status == .cancelled && counter.liveBytes == 0 }
        XCTAssertEqual(terminals, 1); XCTAssertEqual(counter.deallocations, 1); assertReleased(runner)
    }

    func testCancelAtEachPreparedTextPhasePreventsThatDispatch() async throws {
        for phase in [ChainTextPhase.recognize, .transform, .copy] {
            var recognitions = 0, transforms = 0, copies = 0, terminals = 0
            let runner = try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image: raster()),
                dependencies: .init(capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                    recognize: { _ in recognitions += 1; return .init(text: "fixture OCR") },
                    transform: { _, _, _ in transforms += 1; return .succeeded("fixture output") },
                    copy: { _ in copies += 1 }, cleanupComplete: { _ in XCTFail(); return false },
                    cancelCapture: { XCTFail("Prepared input has no acquisition to cancel") }))
            runner.onChange = { [weak runner] snapshot in
                if snapshot.status == .preparingText(phase) {
                    XCTAssertTrue(runner?.cancel() == true); XCTAssertFalse(runner?.cancel() == true)
                }
            }
            runner.onTerminal = { _ in terminals += 1 }
            XCTAssertTrue(runner.start()); try await until { runner.status == .cancelled }
            XCTAssertEqual(recognitions, phase == .recognize ? 0 : 1)
            XCTAssertEqual(transforms, phase == .copy ? 1 : 0); XCTAssertEqual(copies, 0)
            XCTAssertEqual(terminals, 1); XCTAssertNil(runner.textReceipt); assertReleased(runner)
        }
    }

    func testCancelDuringPreparedRecognitionDrainsProviderAndRejectsLateText() async throws {
        let counter = CaptureTestProviderCounter(), gate = Gate<ChainTextRecognition>()
        defer { gate.resolve(.init(text: "unused")) }
        var terminals = 0
        let runner = try autoreleasepool {
            try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image:
                CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter)), dependencies: .init(
                    capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                    recognize: { image in
                        let result = await gate.wait()
                        withExtendedLifetime(image) {}
                        return result
                    }, transform: { _, _, _ in XCTFail(); return .succeeded("unused") },
                    copy: { _ in XCTFail() }, cleanupComplete: { _ in XCTFail(); return false },
                    cancelCapture: { XCTFail("Prepared OCR cannot cancel acquisition") }))
        }
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.cancel())
        XCTAssertNil(runner.capture); XCTAssertEqual(runner.retainedBytes, 0)
        XCTAssertGreaterThan(counter.liveBytes, 0, "The OCR dependency still owns its in-flight raster")
        XCTAssertEqual(terminals, 0); XCTAssertTrue(runner.blocksCapture); XCTAssertTrue(runner.isAttemptRunning)
        XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry()); XCTAssertFalse(runner.checkTextCleanup())
        XCTAssertTrue(gate.resolve(.init(text: "late fixture OCR")))
        try await until { runner.status == .cancelled && counter.liveBytes == 0 }
        XCTAssertFalse(gate.resolve(.init(text: "duplicate fixture OCR")))
        XCTAssertEqual(terminals, 1); XCTAssertNil(runner.textReceipt)
        XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1); assertReleased(runner)
    }

    func testCancelDuringPreparedTransformRejectsLateSuccessAndClearsText() async throws {
        let gate = Gate<ChainTextTransformResult>()
        defer { gate.resolve(.cancelled(cleanupPending: false)) }
        var terminals = 0
        let runner = try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image: raster()),
            dependencies: .init(capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                recognize: { _ in .init(text: "fixture OCR") }, transform: { _, _, _ in await gate.wait() },
                copy: { _ in XCTFail() }, cleanupComplete: { _ in XCTFail(); return false },
                cancelCapture: { XCTFail("Prepared transform cannot cancel acquisition") }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertNil(runner.capture); XCTAssertGreaterThan(runner.retainedTextBytes, 0)
        XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.cancel())
        XCTAssertEqual(runner.retainedBytes, 0); XCTAssertTrue(runner.blocksCapture)
        XCTAssertTrue(runner.isAttemptRunning); XCTAssertEqual(terminals, 0)
        XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry())
        XCTAssertTrue(gate.resolve(.succeeded("late fixture output")))
        try await until { runner.status == .cancelled }
        XCTAssertEqual(terminals, 1); XCTAssertNil(runner.textReceipt); assertReleased(runner)
    }

    func testPreparedTransformCleanupRequiresOwnedReleaseBeforeRetryWithCachedOCRAndFreshID() async throws {
        var captures = 0, recognitions = 0, copies = 0
        var requests: [UUID] = [], observed: [UUID] = [], released: Set<UUID> = []
        let runner = try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image: raster()),
            dependencies: .init(capture: { captures += 1; throw Failure.unexpectedAcquisition },
                recognize: { _ in recognitions += 1; return .init(text: "cached fixture OCR") },
                transform: { source, text, request in
                    XCTAssertEqual(source, "return text;"); XCTAssertEqual(text, "cached fixture OCR")
                    requests.append(request)
                    return requests.count == 1 ? .failed(.runtime(.pipesUnconfirmed), cleanupPending: true) :
                        .succeeded("accepted fixture output")
                }, copy: { _ in copies += 1 },
                cleanupComplete: { request in observed.append(request); return released.contains(request) }))
        XCTAssertTrue(runner.start())
        try await until { runner.status == .waitingForTextCleanup(.runtime(.pipesUnconfirmed)) }
        let firstRequest = try XCTUnwrap(requests.first)
        XCTAssertNil(runner.capture); XCTAssertNil(runner.textReceipt)
        XCTAssertEqual(runner.retainedTextBytes, "return text;cached fixture OCR".utf8.count)
        XCTAssertTrue(runner.blocksCapture); XCTAssertTrue(runner.isAttemptRunning)
        XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry())
        released.insert(UUID()); XCTAssertFalse(runner.checkTextCleanup())
        XCTAssertEqual(copies, 0); XCTAssertEqual(requests.count, 1)
        released.insert(firstRequest); XCTAssertTrue(runner.checkTextCleanup())
        XCTAssertEqual(runner.status, .textFailed(.transform, .runtime(.pipesUnconfirmed)))
        XCTAssertFalse(runner.isAttemptRunning); XCTAssertNil(runner.textReceipt)
        XCTAssertEqual(Set(observed), Set([firstRequest])); XCTAssertFalse(runner.checkTextCleanup())
        XCTAssertTrue(runner.retry()); XCTAssertFalse(runner.retry()); XCTAssertFalse(runner.start())
        try await until { runner.status == .completed }
        XCTAssertEqual(captures, 0); XCTAssertEqual(recognitions, 1); XCTAssertEqual(copies, 1)
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(Set(requests).count, 2); assertReleased(runner)
    }

    func testCancelBeforePreparedHelperFailureWaitsForThatRequestsOwnedCleanup() async throws {
        let gate = Gate<ChainTextTransformResult>()
        defer { gate.resolve(.cancelled(cleanupPending: false)) }
        var request: UUID?, observed: [UUID] = [], released: Set<UUID> = [], terminals = 0
        let runner = try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image: raster()),
            dependencies: .init(capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                recognize: { _ in .init(text: "fixture OCR") },
                transform: { _, _, id in request = id; return await gate.wait() }, copy: { _ in XCTFail() },
                cleanupComplete: { id in observed.append(id); return released.contains(id) },
                cancelCapture: { XCTFail("Prepared helper cannot cancel acquisition") }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        let ownedRequest = try XCTUnwrap(request)
        XCTAssertTrue(runner.cancel())
        XCTAssertTrue(gate.resolve(.failed(.runtime(.exitUnconfirmed), cleanupPending: true)))
        // An observed probe proves the late result installed its cleanup lease.
        try await until { _ = runner.checkTextCleanup(); return !observed.isEmpty }
        XCTAssertEqual(runner.status, .cancelling); XCTAssertEqual(runner.retainedBytes, 0)
        XCTAssertTrue(runner.blocksCapture); XCTAssertTrue(runner.isAttemptRunning); XCTAssertEqual(terminals, 0)
        XCTAssertFalse(runner.cancel()); XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry())
        released.insert(UUID()); XCTAssertFalse(runner.checkTextCleanup())
        XCTAssertEqual(Set(observed), Set([ownedRequest])); XCTAssertEqual(terminals, 0)
        released.insert(ownedRequest); XCTAssertTrue(runner.checkTextCleanup())
        XCTAssertEqual(runner.status, .cancelled); XCTAssertEqual(terminals, 1)
        XCTAssertNil(runner.textReceipt); XCTAssertFalse(runner.checkTextCleanup()); assertReleased(runner)
    }

    func testPreparedSynchronousCopySuccessThenCancelKeepsReceiptAndOneTerminal() async throws {
        weak var current: CaptureChainRunner?
        let output = "accepted fixture 🐈"
        var copies = 0, terminals: [CaptureChainSnapshot] = []
        let runner = try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image: raster()),
            dependencies: .init(capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                recognize: { _ in .init(text: "fixture OCR") }, transform: { _, _, _ in .succeeded(output) },
                copy: { text in
                    XCTAssertEqual(text, output); copies += 1
                    XCTAssertTrue(current?.cancel() == true); XCTAssertFalse(current?.cancel() == true)
                    XCTAssertFalse(current?.start() == true); XCTAssertFalse(current?.retry() == true)
                }, cleanupComplete: { _ in XCTFail(); return false },
                cancelCapture: { XCTFail("Prepared Copy cannot cancel acquisition") }))
        current = runner; runner.onTerminal = { terminals.append($0) }
        XCTAssertTrue(runner.start()); try await until { runner.status == .cancelled }
        XCTAssertEqual(copies, 1); XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(runner.textReceipt, ChainTextCopyReceipt(characterCount: output.count))
        XCTAssertEqual(terminals.first?.textReceipt, runner.textReceipt)
        XCTAssertEqual(terminals.first?.status, .cancelled); XCTAssertTrue(runner.receipts.isEmpty)
        XCTAssertFalse(runner.cancel()); XCTAssertFalse(runner.checkTextCleanup()); assertReleased(runner)
    }

    func testStalePreparedCommandsAndDuplicateResultsCannotAffectSuccessorOrExposeText() async throws {
        let firstGate = Gate<ChainTextTransformResult>(), secondGate = Gate<ChainTextTransformResult>()
        defer {
            firstGate.resolve(.cancelled(cleanupPending: false))
            secondGate.resolve(.cancelled(cleanupPending: false))
        }
        var firstTerminals = 0, secondTerminals = 0, secondCopies = 0, snapshots: [CaptureChainSnapshot] = []
        let first = try CaptureChainRunner(textScript: definition(source: "return 'PRIVATE_SOURCE';"),
            preparedCapture: ChainCapture(image: raster()), dependencies: .init(
                capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                recognize: { _ in .init(text: "PRIVATE_OCR") }, transform: { _, _, _ in await firstGate.wait() },
                copy: { _ in XCTFail() }, cleanupComplete: { _ in XCTFail(); return false }))
        first.onChange = { snapshots.append($0) }; first.onTerminal = { _ in firstTerminals += 1 }
        XCTAssertTrue(first.start()); try await until { firstGate.isWaiting }
        XCTAssertTrue(first.cancel()); XCTAssertTrue(firstGate.resolve(.succeeded("PRIVATE_OUTPUT")))
        try await until { first.status == .cancelled }
        let oldSnapshot = first.snapshot
        let second = try CaptureChainRunner(textScript: definition(), preparedCapture: ChainCapture(image: raster()),
            dependencies: .init(capture: { XCTFail(); throw Failure.unexpectedAcquisition },
                recognize: { _ in .init(text: "fixture OCR") }, transform: { _, _, _ in await secondGate.wait() },
                copy: { _ in secondCopies += 1 }, cleanupComplete: { _ in XCTFail(); return false }))
        second.onChange = { snapshots.append($0) }; second.onTerminal = { _ in secondTerminals += 1 }
        XCTAssertNotEqual(first.id, second.id); XCTAssertTrue(second.start())
        try await until { secondGate.isWaiting }
        XCTAssertFalse(first.start()); XCTAssertFalse(first.retry()); XCTAssertFalse(first.cancel())
        XCTAssertFalse(first.checkTextCleanup()); XCTAssertFalse(firstGate.resolve(.succeeded("PRIVATE_DUPLICATE")))
        XCTAssertFalse(second.start()); XCTAssertFalse(second.retry())
        XCTAssertEqual(first.snapshot, oldSnapshot); XCTAssertEqual(second.status, .preparingText(.transform))
        XCTAssertEqual(secondCopies, 0); XCTAssertTrue(secondGate.resolve(.succeeded("fixture output")))
        try await until { second.status == .completed }
        XCTAssertFalse(secondGate.resolve(.succeeded("duplicate fixture output")))
        XCTAssertEqual(first.snapshot, oldSnapshot); XCTAssertEqual(firstTerminals, 1)
        XCTAssertEqual(secondTerminals, 1); XCTAssertEqual(secondCopies, 1)
        for snapshot in snapshots {
            XCTAssertFalse(String(reflecting: snapshot).contains("PRIVATE_"))
            XCTAssertTrue(snapshot.isTextScript); XCTAssertTrue(snapshot.isExistingScrollImage)
            XCTAssertTrue(snapshot.receipts.isEmpty)
        }
        assertReleased(first); assertReleased(second)
    }

    private func definition(source: String = "return text;") throws -> TextScriptDefinition {
        try TextScriptDefinition(name: "Prepared text fixture", source: source)
    }
    private func raster() throws -> CGImage { try SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8) }
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "Prepared text run did not reach its deterministic barrier")
    }
    private func assertReleased(_ runner: CaptureChainRunner, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(runner.capture, file: file, line: line)
        XCTAssertEqual(runner.retainedBytes, 0, file: file, line: line)
        XCTAssertEqual(runner.retainedTextBytes, 0, file: file, line: line)
        XCTAssertFalse(runner.blocksCapture, file: file, line: line)
        XCTAssertFalse(runner.isAttemptRunning, file: file, line: line)
        XCTAssertNil(runner.onChange, file: file, line: line); XCTAssertNil(runner.onTerminal, file: file, line: line)
        XCTAssertFalse(runner.start(), file: file, line: line); XCTAssertFalse(runner.retry(), file: file, line: line)
        XCTAssertFalse(runner.cancel(), file: file, line: line); XCTAssertFalse(runner.checkTextCleanup(), file: file, line: line)
    }
    private enum Failure: Error { case unexpectedAcquisition, recognition, copyRefused }

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
}
