import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor
final class LiveScrollChainTransactionTests: XCTestCase {
    func testCancelledAttemptExtendsOnlyMatchingPrefixAndKeepsFrozenIdentitiesAndRaster() throws {
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8)
        let capture = try ChainCapture(image: image, capturedAt: Date(timeIntervalSince1970: 269), encodedBackingBytes: 17)
        let definition = try CaptureChainDefinition(name: "Frozen definition", source: .preset(UUID()), outputs: [.pin, .copy, .quickSavePNG])
        let pin = CaptureChainReceipt(output: .pin, value: .pinned(UUID()))
        let copy = CaptureChainReceipt(output: .copy, value: .copied)
        let sessionID = UUID(), revisionID = UUID(), transactionID = UUID(), firstID = UUID(), secondID = UUID()
        var transaction = try LiveScrollChainTransaction(sessionID: sessionID, generation: 7,
            revisionID: revisionID, transactionID: transactionID, capture: capture, definition: definition)
        try transaction.accept(snapshot(definition, runID: firstID, status: .cancelled, receipts: [pin]), runID: firstID)
        XCTAssertFalse(transaction.isComplete)
        try transaction.accept(snapshot(definition, runID: secondID, status: .cancelled, receipts: [pin, copy]), runID: secondID)
        XCTAssertEqual(transaction.receipts, [pin, copy]); XCTAssertFalse(transaction.isComplete)
        XCTAssertEqual(transaction.sessionID, sessionID); XCTAssertEqual(transaction.generation, 7)
        XCTAssertEqual(transaction.transactionID, transactionID); XCTAssertEqual(transaction.revisionID, revisionID)
        XCTAssertEqual(transaction.definition, definition); XCTAssertTrue(transaction.capture.image === image)
        XCTAssertEqual(transaction.capture.retainedBytes, image.bytesPerRow * image.height + 17)
        XCTAssertEqual(transaction.capture.capturedAt, capture.capturedAt)
        XCTAssertTrue(transaction.committedDescription.contains("当时的成功写入"))
        guard case .pinned(let pinID) = pin.value else { return XCTFail() }
        XCTAssertTrue(transaction.committedDescription.contains(pinID.uuidString))
    }

    func testStaleNonterminalWrongModeDefinitionAndRewrittenReceiptCallbacksLeaveCheckpointUntouched() throws {
        let capture = try ChainCapture(image: SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8))
        let definition = try CaptureChainDefinition(name: "Original", source: .region, outputs: [.quickSavePNG, .copy, .pin])
        let saved = CaptureChainReceipt(output: .quickSavePNG,
            value: .saved(URL(fileURLWithPath: "/tmp/owned-original.png"), byteCount: 19))
        let copy = CaptureChainReceipt(output: .copy, value: .copied)
        let currentID = UUID(), oldID = UUID()
        var transaction = try LiveScrollChainTransaction(sessionID: UUID(), generation: 2,
            capture: capture, definition: definition, receipts: [saved])
        let changed = try CaptureChainDefinition(id: definition.id, name: "Changed", source: definition.source, outputs: definition.outputs)
        let invalid = [
            snapshot(definition, runID: oldID, status: .cancelled, receipts: [saved, copy]),
            snapshot(changed, runID: currentID, status: .cancelled, receipts: [saved, copy]),
            snapshot(definition, runID: currentID, status: .failed(index: 1, message: "Still active"), receipts: [saved]),
            snapshot(definition, runID: currentID, status: .cancelled, receipts: [saved], prepared: false),
            snapshot(definition, runID: currentID, status: .cancelled, receipts: []),
            snapshot(definition, runID: currentID, status: .cancelled, receipts: [
                .init(output: .quickSavePNG, value: .saved(URL(fileURLWithPath: "/tmp/rewritten.png"), byteCount: 19))]),
            snapshot(definition, runID: currentID, status: .cancelled, receipts: [saved, .init(output: .pin, value: .pinned(UUID()))]),
            snapshot(definition, runID: currentID, status: .cancelled, receipts: [saved, .init(output: .copy, value: .pinned(UUID()))])
        ]
        for callback in invalid {
            XCTAssertThrowsError(try transaction.accept(callback, runID: currentID))
            XCTAssertEqual(transaction.receipts, [saved])
            XCTAssertEqual(transaction.definition, definition)
            XCTAssertTrue(transaction.capture.image === capture.image)
        }
        try transaction.accept(snapshot(definition, runID: currentID, status: .cancelled, receipts: [saved, copy]), runID: currentID)
        XCTAssertEqual(transaction.receipts, [saved, copy])
    }

    func testFullCommittedPrefixIsCompleteDespiteCancellationAndNewTransactionIntentionallyResetsOnlyReceipts() throws {
        let capture = try ChainCapture(image: SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8))
        let definition = try CaptureChainDefinition(name: "Copy and pin", source: .region, outputs: [.copy, .pin])
        let receipts: [CaptureChainReceipt] = [.init(output: .copy, value: .copied), .init(output: .pin, value: .pinned(UUID()))]
        let runID = UUID()
        var original = try LiveScrollChainTransaction(sessionID: UUID(), generation: 3, capture: capture, definition: definition)
        try original.accept(snapshot(definition, runID: runID, status: .cancelled, receipts: receipts), runID: runID)
        XCTAssertTrue(original.isComplete)
        let replacement = try LiveScrollChainTransaction(sessionID: original.sessionID, generation: original.generation,
            revisionID: original.revisionID, capture: original.capture, definition: original.definition)
        XCTAssertNotEqual(replacement.transactionID, original.transactionID)
        XCTAssertEqual(replacement.revisionID, original.revisionID)
        XCTAssertTrue(replacement.capture.image === original.capture.image)
        XCTAssertTrue(replacement.receipts.isEmpty); XCTAssertFalse(replacement.isComplete)
        XCTAssertEqual(original.receipts, receipts)
    }

    private func snapshot(_ definition: CaptureChainDefinition, runID: UUID, status: CaptureChainStatus,
                          receipts: [CaptureChainReceipt], prepared: Bool = true) -> CaptureChainSnapshot {
        .init(runID: runID, definition: definition, status: status, receipts: receipts,
            capturedAt: Date(timeIntervalSince1970: 269), retainedBytes: 0, isExistingScrollImage: prepared)
    }
}
