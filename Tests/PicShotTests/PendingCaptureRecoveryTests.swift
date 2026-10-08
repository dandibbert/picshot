import AppKit
import XCTest
import PicShotCore
@testable import PicShot

final class PendingCaptureRecoveryTests: XCTestCase {
    @MainActor func testHistoryFailurePlusEditorRefusalKeepsOriginalPixelsAndDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(directory: root)
        history.failureInjector = { if $0 == .beforeIndexCommit { throw CaptureRecoveryError.writeFailed } }
        let recovery = PendingCaptureRecovery(), image = try raster(), date = Date(timeIntervalSince1970: 42)
        let result = CapturedImage(image: image, presentation: nil, capturedAt: date, encodedBackingBytes: 123)
        let before = try pixels(image)
        var attemptedEditors = 0
        let outcome = try CaptureCompletion.finish(result, title: "fixture", recovery: recovery,
            saveHistory: { try history.add($0.image, title: $1, capturedAt: $0.capturedAt) },
            openEditor: { _ in attemptedEditors += 1; return false }, reportHistoryError: { _ in XCTFail("Pending panel reports failure itself") })
        XCTAssertEqual(outcome, .pending); XCTAssertEqual(attemptedEditors, 1); XCTAssertTrue(history.records.isEmpty)
        let pending = try XCTUnwrap(recovery.pending)
        XCTAssertTrue(pending.image === image); XCTAssertEqual(try pixels(pending.image), before)
        XCTAssertEqual(pending.capturedAt, date)
        XCTAssertEqual(recovery.retainedBytes, image.bytesPerRow * image.height + 123)
        XCTAssertTrue(recovery.blocksCapture)
        XCTAssertThrowsError(try CaptureCompletion.finish(result, title: "replacement", recovery: recovery,
            saveHistory: { _, _ in XCTFail("Must refuse before replacing original") },
            openEditor: { _ in XCTFail(); return true }, reportHistoryError: { _ in XCTFail() }))
        XCTAssertEqual(recovery.pending?.id, pending.id)
    }

    @MainActor func testCountAndBudgetRefusalsRetryOnlyAfterCapacityReturns() throws {
        for existing in [[1, 1, 1, 1, 1, 1], [90]] {
            let recovery = PendingCaptureRecovery(), result = CapturedImage(image: try raster(), presentation: nil)
            let policy = EditorAdmissionPolicy(maximumRasterBytes: 100)
            let outcome = try CaptureCompletion.finish(result, title: "fixture", recovery: recovery,
                saveHistory: { _, _ in throw CaptureRecoveryError.writeFailed },
                openEditor: { _ in policy.refusal(existingRasterBytes: existing, incomingRasterBytes: 20) == nil },
                reportHistoryError: { _ in XCTFail() })
            XCTAssertEqual(outcome, .pending)
            let id = recovery.pending?.id
            XCTAssertFalse(recovery.retryEditor { _ in false }); XCTAssertEqual(recovery.pending?.id, id)
            var handedOff: CGImage?
            XCTAssertTrue(recovery.retryEditor { capture in handedOff = capture.image; return true })
            XCTAssertTrue(handedOff === result.image); XCTAssertNil(recovery.pending); XCTAssertEqual(recovery.retainedBytes, 0)
        }
    }

    @MainActor func testSuccessfulHistoryOrEditorAvoidsFalsePendingAndPreservesHistoryErrors() throws {
        for (historySucceeds, editorSucceeds) in [(true, true), (true, false), (false, true)] {
            let recovery = PendingCaptureRecovery(); var notices = 0
            let outcome = try CaptureCompletion.finish(CapturedImage(image: try raster(), presentation: nil), title: "fixture", recovery: recovery,
                saveHistory: { _, _ in if !historySucceeds { throw CaptureRecoveryError.writeFailed } },
                openEditor: { _ in editorSucceeds }, reportHistoryError: { _ in notices += 1 })
            XCTAssertEqual(outcome, editorSucceeds ? .editor : .history)
            XCTAssertNil(recovery.pending); XCTAssertEqual(notices, historySucceeds ? 0 : 1)
        }
    }

    @MainActor func testFailedOrCancelledSaveCannotResolveAndStaleSuccessIsIgnored() throws {
        let recovery = try pending(), id = try XCTUnwrap(recovery.pending?.id)
        recovery.savePickerCancelled(); XCTAssertEqual(recovery.pending?.id, id)
        for error in [CaptureRecoveryError.writeFailed as Error, CancellationError()] {
            XCTAssertNotNil(recovery.beginSave()); XCTAssertNil(recovery.beginSave())
            XCTAssertFalse(recovery.discard()); XCTAssertFalse(recovery.retryEditor { _ in XCTFail(); return true })
            recovery.finishSave(id: UUID(), result: .success(URL(fileURLWithPath: "/wrong.png")))
            XCTAssertTrue(recovery.isSaving); XCTAssertEqual(recovery.pending?.id, id)
            recovery.finishSave(id: id, result: .failure(error))
            XCTAssertFalse(recovery.isSaving); XCTAssertEqual(recovery.pending?.id, id)
        }
        XCTAssertNotNil(recovery.beginSave())
        recovery.finishSave(id: id, result: .success(URL(fileURLWithPath: "/saved.png")))
        XCTAssertNil(recovery.pending); XCTAssertEqual(recovery.retainedBytes, 0)
    }

    @MainActor func testPendingReleasesFrozenInputAndSelectedPixelsSurviveUntilDiscard() throws {
        let recovery = PendingCaptureRecovery(), frozen = CaptureTestProviderCounter()
        var expectedSelected = Data()
        try autoreleasepool {
            let source = try CaptureTestProviderCounter.image(width: 16, height: 16, counter: frozen)
            let result = try CapturedImage.frozenPixelRegion(image: source, displayID: 0,
                displayFrame: CGRect(x: 0, y: 0, width: 16, height: 16), pixelFrame: CGRect(x: 1, y: 2, width: 8, height: 8),
                capturedAt: Date(timeIntervalSince1970: 99))
            expectedSelected = try pixels(result.image)
            try recovery.retain(PendingCapture(result, title: "fixture"), error: CaptureRecoveryError.writeFailed)
        }
        XCTAssertEqual(frozen.callbacks, 1, "Pending must not retain the supplied frozen desktop provider")
        XCTAssertEqual(frozen.deallocations, 1); XCTAssertEqual(frozen.liveBytes, 0)
        XCTAssertEqual(recovery.pending?.capturedAt, Date(timeIntervalSince1970: 99))
        XCTAssertEqual(try pixels(XCTUnwrap(recovery.pending?.image)), expectedSelected)
        XCTAssertEqual(recovery.retainedBytes, 8 * 8 * 4)
        XCTAssertTrue(recovery.discard()); XCTAssertNil(recovery.pending)
        XCTAssertEqual(recovery.retainedBytes, 0); XCTAssertFalse(recovery.blocksCapture)
    }

    @MainActor private func pending() throws -> PendingCaptureRecovery {
        let recovery = PendingCaptureRecovery()
        try recovery.retain(PendingCapture(CapturedImage(image: try raster(), presentation: nil), title: "fixture"),
                            error: CaptureRecoveryError.writeFailed)
        return recovery
    }
    private func raster(_ width: Int = 8, _ height: Int = 8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}
