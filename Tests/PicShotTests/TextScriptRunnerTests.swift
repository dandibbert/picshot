import AppKit
import PicShotCore
import PicShotTextScriptCore
import XCTest
@testable import PicShot

/// All data are generated. Continuations expose cancellation/cleanup barriers;
/// no desktop capture, helper launch, general pasteboard or production catalog.
@MainActor final class TextScriptRunnerTests: XCTestCase {
    func testCopyRefusalRetriesOnlyFrozenOutputAndCommitsOnce() async throws {
        let image = try image(), text = "ABC-1\nABC-2 🐈", source = "return text;"
        var captures = 0, recognitions = 0, transforms = 0, copies: [String] = [], terminals = 0
        var saved = try definition(source: source)
        let runner = try CaptureChainRunner(textScript: saved, dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: image) },
            recognize: { actual in
                recognitions += 1; XCTAssertTrue(actual === image)
                return ChainTextRecognition(text: "private OCR")
            }, transform: { frozen, recognized, _ in
                transforms += 1; XCTAssertEqual(frozen, source); XCTAssertEqual(recognized, "private OCR")
                return .succeeded(text)
            }, copy: { output in
                copies.append(output)
                if copies.count == 1 { throw SecretError() }
            }, cleanupComplete: { _ in XCTFail("Successful helper must not poll cleanup"); return false }))
        runner.onTerminal = { _ in terminals += 1 }
        saved = try TextScriptDefinition(id: saved.id, name: "Changed after launch", source: "throw text;")
        XCTAssertTrue(runner.start()); XCTAssertFalse(runner.start())
        try await until { runner.status.canRetry }
        XCTAssertEqual(runner.status, .textFailed(.copy, .clipboardRejected))
        XCTAssertEqual(runner.snapshot.definition.name, "Fixture text action")
        XCTAssertNil(runner.textReceipt); XCTAssertTrue(runner.receipts.isEmpty)
        XCTAssertNil(runner.capture)
        XCTAssertEqual(runner.retainedTextBytes, text.utf8.count)
        XCTAssertTrue(runner.blocksCapture); XCTAssertFalse(runner.isAttemptRunning)
        XCTAssertTrue(runner.retry()); XCTAssertFalse(runner.retry())
        try await until { runner.status == .completed }
        XCTAssertEqual(captures, 1); XCTAssertEqual(recognitions, 1); XCTAssertEqual(transforms, 1)
        XCTAssertEqual(copies, [text, text]); XCTAssertEqual(terminals, 1)
        XCTAssertEqual(runner.textReceipt, ChainTextCopyReceipt(characterCount: text.count))
        XCTAssertTrue(runner.receipts.isEmpty)
        assertReleased(runner)
    }

    func testOCRFailureRetriesTheIdenticalCaptureThenDropsPixels() async throws {
        let image = try image()
        var captures = 0, recognitions = 0, transforms = 0, copies = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: image, encodedBackingBytes: 9) },
            recognize: { actual in
                XCTAssertTrue(actual === image); recognitions += 1
                if recognitions == 1 { throw SecretError() }
                return ChainTextRecognition(text: "recognized")
            }, transform: { _, _, _ in transforms += 1; return .succeeded("prepared") },
            copy: { _ in copies += 1 }, cleanupComplete: { _ in false }))
        XCTAssertTrue(runner.start()); try await until { runner.status.canRetry }
        XCTAssertEqual(runner.status, .textFailed(.recognize, .recognitionFailed))
        XCTAssertTrue(runner.capture?.image === image)
        XCTAssertEqual(runner.retainedBytes, image.bytesPerRow * image.height + 9 + "return text;".utf8.count)
        XCTAssertTrue(runner.retry()); try await until { runner.status == .completed }
        XCTAssertEqual(captures, 1); XCTAssertEqual(recognitions, 2); XCTAssertEqual(transforms, 1); XCTAssertEqual(copies, 1)
        assertReleased(runner)
    }

    func testTransformFailureRetriesFrozenOCRAndSourceWithFreshAttemptIdentity() async throws {
        var captures = 0, recognitions = 0, requests: [UUID] = [], copies = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: self.image()) },
            recognize: { _ in recognitions += 1; return ChainTextRecognition(text: "stable OCR") },
            transform: { source, text, request in
                XCTAssertEqual(source, "return text;"); XCTAssertEqual(text, "stable OCR")
                requests.append(request)
                return requests.count == 1 ? .failed(.script(.scriptException), cleanupPending: false) : .succeeded("stable output")
            }, copy: { _ in copies += 1 }, cleanupComplete: { _ in false }))
        XCTAssertTrue(runner.start()); try await until { runner.status.canRetry }
        XCTAssertEqual(runner.status, .textFailed(.transform, .script(.scriptException)))
        XCTAssertNil(runner.capture); XCTAssertEqual(runner.retainedTextBytes, "return text;stable OCR".utf8.count)
        XCTAssertTrue(runner.retry()); try await until { runner.status == .completed }
        XCTAssertEqual(captures, 1); XCTAssertEqual(recognitions, 1); XCTAssertEqual(copies, 1)
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(Set(requests).count, 2)
        assertReleased(runner)
    }

    func testEmptyTruncatedAndOversizedOCRFailBeforeTransformationOrCopy() async throws {
        let cases: [(ChainTextRecognition, ChainTextFailure)] = [
            (.init(text: ""), .emptyRecognition), (.init(text: "private", truncated: true), .truncatedRecognition),
            (.init(text: String(repeating: "🐈", count: 16_385)), .oversizedRecognition)
        ]
        for (recognition, expected) in cases {
            let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
                capture: { try ChainCapture(image: self.image()) }, recognize: { _ in recognition },
                transform: { _, _, _ in XCTFail(); return .succeeded("unexpected") },
                copy: { _ in XCTFail() }, cleanupComplete: { _ in false }))
            XCTAssertTrue(runner.start()); try await until { runner.status.canRetry }
            XCTAssertEqual(runner.status, .textFailed(.recognize, expected))
            XCTAssertNil(runner.textReceipt); XCTAssertNotNil(runner.capture)
            XCTAssertTrue(runner.cancel()); assertReleased(runner)
        }
    }

    func testEmptyAndOversizedTransformedOutputFailBeforeCopy() async throws {
        for (output, failure) in [("", ChainTextFailure.emptyOutput),
                                  (String(repeating: "🐈", count: 16_385), .oversizedOutput)] {
            let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
                capture: { try ChainCapture(image: self.image()) }, recognize: { _ in .init(text: "recognized") },
                transform: { _, _, _ in .succeeded(output) }, copy: { _ in XCTFail() }, cleanupComplete: { _ in false }))
            XCTAssertTrue(runner.start()); try await until { runner.status.canRetry }
            XCTAssertEqual(runner.status, .textFailed(.transform, failure)); XCTAssertNil(runner.textReceipt)
            XCTAssertTrue(runner.cancel()); assertReleased(runner)
        }
    }

    func testCaptureFailureNeverRetainsArbitraryExceptionDescription() async throws {
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { throw SecretError() }, recognize: { _ in XCTFail(); return .init(text: "unused") },
            transform: { _, _, _ in XCTFail(); return .succeeded("unused") },
            copy: { _ in XCTFail() }, cleanupComplete: { _ in false }))
        XCTAssertTrue(runner.start()); try await until { runner.status.isTerminal }
        XCTAssertEqual(runner.status, .captureFailed(message: ChainTextFailure.captureFailed.message))
        XCTAssertFalse(String(reflecting: runner.snapshot).contains("PRIVATE_PAYLOAD"))
        assertReleased(runner)
    }

    func testImmediateCancelDoesNotStartCapture() async throws {
        var cancels = 0, terminals = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { XCTFail(); return try ChainCapture(image: self.image()) },
            recognize: { _ in XCTFail(); return .init(text: "unused") },
            transform: { _, _, _ in XCTFail(); return .succeeded("unused") }, copy: { _ in XCTFail() },
            cleanupComplete: { _ in XCTFail(); return false }, cancelCapture: { cancels += 1 }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.cancel())
        XCTAssertEqual(runner.status, .cancelling); XCTAssertTrue(runner.blocksCapture)
        try await until { runner.status == .cancelled }
        XCTAssertEqual(cancels, 1); XCTAssertEqual(terminals, 1); assertReleased(runner)
    }

    func testCancelledCaptureRejectsLateImageAndKeepsOwnerUntilDrain() async throws {
        let gate = Gate<ChainCapture>(), counter = CaptureTestProviderCounter()
        var terminals = 0, cancels = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { await gate.wait() }, recognize: { _ in XCTFail(); return .init(text: "unused") },
            transform: { _, _, _ in XCTFail(); return .succeeded("unused") }, copy: { _ in XCTFail() },
            cleanupComplete: { _ in false }, cancelCapture: { cancels += 1 }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertTrue(runner.cancel()); XCTAssertEqual(terminals, 0); XCTAssertTrue(runner.blocksCapture)
        XCTAssertFalse(runner.start()); XCTAssertFalse(runner.retry())
        try autoreleasepool {
            XCTAssertTrue(gate.resolve(try ChainCapture(image: CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter))))
        }
        try await until { runner.status == .cancelled && counter.liveBytes == 0 }
        XCTAssertEqual(cancels, 1); XCTAssertEqual(terminals, 1); XCTAssertNil(runner.capturedAt)
        XCTAssertEqual(counter.deallocations, 1); assertReleased(runner)
    }

    func testCancelledOCRDrainsImageAndRejectsLateText() async throws {
        let gate = Gate<ChainTextRecognition>(), counter = CaptureTestProviderCounter()
        var terminals = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { try ChainCapture(image: CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter)) },
            recognize: { image in
                let result = await gate.wait()
                withExtendedLifetime(image) {}
                return result
            }, transform: { _, _, _ in XCTFail(); return .succeeded("unused") },
            copy: { _ in XCTFail() }, cleanupComplete: { _ in false }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertTrue(runner.cancel()); XCTAssertNil(runner.capture); XCTAssertEqual(runner.retainedTextBytes, 0)
        XCTAssertEqual(terminals, 0); XCTAssertTrue(runner.blocksCapture)
        XCTAssertGreaterThan(counter.liveBytes, 0, "The actual OCR dependency must still drain its image")
        XCTAssertTrue(gate.resolve(.init(text: "late private OCR")))
        try await until { runner.status == .cancelled && counter.liveBytes == 0 }
        XCTAssertEqual(terminals, 1); XCTAssertNil(runner.textReceipt); assertReleased(runner)
    }

    func testCancelDuringScriptRejectsLateSuccess() async throws {
        let gate = Gate<ChainTextTransformResult>()
        var terminals = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { try ChainCapture(image: self.image()) }, recognize: { _ in .init(text: "private OCR") },
            transform: { _, _, _ in await gate.wait() }, copy: { _ in XCTFail() }, cleanupComplete: { _ in false }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertTrue(runner.cancel()); XCTAssertTrue(runner.blocksCapture); XCTAssertEqual(terminals, 0)
        XCTAssertEqual(runner.retainedTextBytes, 0); XCTAssertFalse(runner.retry())
        XCTAssertTrue(gate.resolve(.succeeded("late output")))
        try await until { runner.status == .cancelled }
        XCTAssertNil(runner.textReceipt); XCTAssertEqual(terminals, 1); assertReleased(runner)
    }

    func testUnconfirmedHelperCleanupBlocksRetryAndRetirementUntilOwnedRelease() async throws {
        var request: UUID?, observed: [UUID] = [], released = false, transforms = 0, copies = 0, terminals = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { try ChainCapture(image: self.image()) }, recognize: { _ in .init(text: "private OCR") },
            transform: { _, _, id in
                request = id; transforms += 1
                return .failed(.runtime(.exitUnconfirmed), cleanupPending: true)
            }, copy: { _ in copies += 1 }, cleanupComplete: { id in observed.append(id); return released }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start())
        try await until { runner.status == .waitingForTextCleanup(.runtime(.exitUnconfirmed)) }
        XCTAssertTrue(runner.blocksCapture); XCTAssertTrue(runner.isAttemptRunning)
        XCTAssertFalse(runner.retry()); XCTAssertFalse(runner.start()); XCTAssertFalse(runner.checkTextCleanup())
        XCTAssertTrue(runner.cancel()); XCTAssertFalse(runner.cancel())
        XCTAssertEqual(runner.status, .cancelling); XCTAssertEqual(runner.retainedBytes, 0)
        XCTAssertEqual(terminals, 0); XCTAssertFalse(runner.checkTextCleanup())
        released = true
        XCTAssertTrue(runner.checkTextCleanup()); XCTAssertEqual(runner.status, .cancelled)
        XCTAssertEqual(Set(observed), Set([try XCTUnwrap(request)]))
        XCTAssertEqual(transforms, 1); XCTAssertEqual(copies, 0); XCTAssertEqual(terminals, 1)
        XCTAssertFalse(runner.checkTextCleanup()); assertReleased(runner)
    }

    func testCleanupReleaseAfterFailureOffersRetryWithoutConvertingToSuccess() async throws {
        var released = false, captures = 0, recognitions = 0, transforms = 0, copies = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { captures += 1; return try ChainCapture(image: self.image()) },
            recognize: { _ in recognitions += 1; return .init(text: "cached OCR") },
            transform: { _, text, _ in
                XCTAssertEqual(text, "cached OCR"); transforms += 1
                return transforms == 1 ? .failed(.runtime(.pipesUnconfirmed), cleanupPending: true) : .succeeded("new accepted result")
            }, copy: { _ in copies += 1 }, cleanupComplete: { _ in released }))
        XCTAssertTrue(runner.start())
        try await until { runner.status == .waitingForTextCleanup(.runtime(.pipesUnconfirmed)) }
        XCTAssertNil(runner.textReceipt); XCTAssertFalse(runner.status.canRetry)
        released = true; XCTAssertTrue(runner.checkTextCleanup())
        XCTAssertEqual(runner.status, .textFailed(.transform, .runtime(.pipesUnconfirmed)))
        XCTAssertEqual(copies, 0); XCTAssertNil(runner.textReceipt); XCTAssertTrue(runner.blocksCapture)
        XCTAssertTrue(runner.retry()); try await until { runner.status == .completed }
        XCTAssertEqual(captures, 1); XCTAssertEqual(recognitions, 1); XCTAssertEqual(transforms, 2); XCTAssertEqual(copies, 1)
        assertReleased(runner)
    }

    func testCancelBeforeHelperFailureStillAcquiresCleanupReservation() async throws {
        let gate = Gate<ChainTextTransformResult>()
        var released = false, terminals = 0
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { try ChainCapture(image: self.image()) }, recognize: { _ in .init(text: "OCR") },
            transform: { _, _, _ in await gate.wait() }, copy: { _ in XCTFail() }, cleanupComplete: { _ in released }))
        runner.onTerminal = { _ in terminals += 1 }
        XCTAssertTrue(runner.start()); try await until { gate.isWaiting }
        XCTAssertTrue(runner.cancel())
        XCTAssertTrue(gate.resolve(.failed(.runtime(.exitUnconfirmed), cleanupPending: true)))
        try await until { !gate.isWaiting && runner.status == .cancelling && runner.isAttemptRunning }
        // Yield until the continuation's failure has reached cleanup ownership.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(terminals, 0); XCTAssertTrue(runner.blocksCapture); XCTAssertFalse(runner.retry())
        XCTAssertFalse(runner.checkTextCleanup()); released = true
        try await until { runner.checkTextCleanup() || runner.status == .cancelled }
        XCTAssertEqual(terminals, 1); assertReleased(runner)
    }

    func testReentrantCancelAfterAcknowledgedCopyStillRecordsOneReceipt() async throws {
        weak var current: CaptureChainRunner?
        var terminals: [CaptureChainSnapshot] = []
        let output = "accepted 🐈"
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { try ChainCapture(image: self.image()) }, recognize: { _ in .init(text: "OCR") },
            transform: { _, _, _ in .succeeded(output) }, copy: { _ in
                XCTAssertTrue(current?.cancel() == true); XCTAssertFalse(current?.retry() == true)
            }, cleanupComplete: { _ in false }))
        current = runner; runner.onTerminal = { terminals.append($0) }
        XCTAssertTrue(runner.start()); try await until { runner.status == .cancelled }
        XCTAssertEqual(runner.textReceipt?.characterCount, output.count)
        XCTAssertEqual(terminals.count, 1); XCTAssertEqual(terminals.first?.textReceipt, runner.textReceipt)
        assertReleased(runner)
    }

    func testCancelAtEachPreparationCallbackPreventsThatDispatch() async throws {
        for phase in [ChainTextPhase.recognize, .transform, .copy] {
            var recognized = 0, transformed = 0, copied = 0
            let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
                capture: { try ChainCapture(image: self.image()) },
                recognize: { _ in recognized += 1; return .init(text: "OCR") },
                transform: { _, _, _ in transformed += 1; return .succeeded("output") },
                copy: { _ in copied += 1 }, cleanupComplete: { _ in false }))
            runner.onChange = { [weak runner] snapshot in
                if snapshot.status == .preparingText(phase) { XCTAssertTrue(runner?.cancel() == true) }
            }
            XCTAssertTrue(runner.start()); try await until { runner.status == .cancelled }
            XCTAssertEqual(recognized, phase == .recognize ? 0 : 1)
            XCTAssertEqual(transformed, phase == .copy ? 1 : 0)
            XCTAssertEqual(copied, 0); XCTAssertNil(runner.textReceipt); assertReleased(runner)
        }
    }

    func testReentrantRetryDoesNotLoseTheNewAttempt() async throws {
        var copies = 0, retried = false
        let runner = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { try ChainCapture(image: self.image()) }, recognize: { _ in .init(text: "OCR") },
            transform: { _, _, _ in .succeeded("output") }, copy: { _ in
                copies += 1; if copies == 1 { throw SecretError() }
            }, cleanupComplete: { _ in false }))
        runner.onChange = { [weak runner] snapshot in
            if snapshot.status.canRetry { retried = runner?.retry() == true }
        }
        XCTAssertTrue(runner.start()); try await until { runner.status == .completed }
        XCTAssertTrue(retried); XCTAssertEqual(copies, 2); XCTAssertNotNil(runner.textReceipt); assertReleased(runner)
    }

    func testOldCancelledRunCannotAffectAnotherOwnerOrRetainSensitiveSnapshotValues() async throws {
        let gate = Gate<ChainTextTransformResult>()
        var firstTerminals = 0, secondCopies = 0
        let first = try CaptureChainRunner(textScript: definition(source: "return 'PRIVATE_SOURCE';"), dependencies: .init(
            capture: { try ChainCapture(image: self.image()) }, recognize: { _ in .init(text: "PRIVATE_OCR") },
            transform: { _, _, _ in await gate.wait() }, copy: { _ in XCTFail() }, cleanupComplete: { _ in false }))
        first.onTerminal = { _ in firstTerminals += 1 }
        XCTAssertTrue(first.start()); try await until { gate.isWaiting }; XCTAssertTrue(first.cancel())
        XCTAssertTrue(gate.resolve(.succeeded("PRIVATE_OUTPUT")))
        try await until { first.status == .cancelled }
        let oldSnapshot = first.snapshot
        let second = try CaptureChainRunner(textScript: definition(), dependencies: .init(
            capture: { try ChainCapture(image: self.image()) }, recognize: { _ in .init(text: "OCR") },
            transform: { _, _, _ in .succeeded("output") }, copy: { _ in secondCopies += 1 }, cleanupComplete: { _ in false }))
        XCTAssertTrue(second.start()); XCTAssertFalse(first.cancel()); XCTAssertFalse(first.retry())
        XCTAssertFalse(gate.resolve(.succeeded("another stale output")))
        try await until { second.status == .completed }
        XCTAssertEqual(first.snapshot, oldSnapshot); XCTAssertEqual(firstTerminals, 1); XCTAssertEqual(secondCopies, 1)
        for snapshot in [oldSnapshot, second.snapshot] {
            XCTAssertFalse(String(reflecting: snapshot).contains("PRIVATE_"))
            XCTAssertEqual(snapshot.retainedBytes, 0); XCTAssertEqual(snapshot.retainedTextBytes, 0)
            XCTAssertTrue(snapshot.isTextScript); XCTAssertEqual(snapshot.definition.source, .region)
            XCTAssertEqual(snapshot.definition.outputs, [.copy]); XCTAssertTrue(snapshot.receipts.isEmpty)
        }
        assertReleased(first); assertReleased(second)
    }

    private func definition(source: String = "return text;") throws -> TextScriptDefinition {
        try TextScriptDefinition(name: "Fixture text action", source: source)
    }
    private func image() throws -> CGImage { try SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8) }
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "Text chain did not reach its deterministic barrier")
    }
    private func assertReleased(_ runner: CaptureChainRunner, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(runner.capture, file: file, line: line)
        XCTAssertEqual(runner.retainedBytes, 0, file: file, line: line)
        XCTAssertEqual(runner.retainedTextBytes, 0, file: file, line: line)
        XCTAssertFalse(runner.blocksCapture, file: file, line: line)
        XCTAssertFalse(runner.isAttemptRunning, file: file, line: line)
        XCTAssertNil(runner.onChange, file: file, line: line); XCTAssertNil(runner.onTerminal, file: file, line: line)
        XCTAssertFalse(runner.start(), file: file, line: line); XCTAssertFalse(runner.retry(), file: file, line: line)
    }
    private struct SecretError: LocalizedError {
        var errorDescription: String? { "PRIVATE_PAYLOAD" }
    }
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
