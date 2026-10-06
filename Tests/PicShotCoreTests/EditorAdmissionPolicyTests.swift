import XCTest
@testable import PicShotCore

final class EditorAdmissionPolicyTests: XCTestCase {
    func testDefaultWindowLimitAndReopeningAfterClose() {
        let policy = EditorAdmissionPolicy()
        XCTAssertNil(policy.refusal(existingRasterBytes: Array(repeating: 1, count: 5), incomingRasterBytes: 1))
        XCTAssertEqual(policy.refusal(existingRasterBytes: Array(repeating: 1, count: 6), incomingRasterBytes: 1), .windowLimit)
        XCTAssertNil(policy.refusal(existingRasterBytes: Array(repeating: 1, count: 5), incomingRasterBytes: 1))
    }

    func testExactBudgetAndAccumulatedExistingRasters() {
        let policy = EditorAdmissionPolicy(maximumRasterBytes: 100)
        XCTAssertNil(policy.refusal(existingRasterBytes: [40, 30], incomingRasterBytes: 30))
        XCTAssertEqual(policy.refusal(existingRasterBytes: [40, 30], incomingRasterBytes: 31), .rasterBudget)
        XCTAssertEqual(policy.refusal(existingRasterBytes: [101], incomingRasterBytes: 0), .rasterBudget)
    }

    func testOverflowAndInvalidAccountingFailClosed() {
        let policy = EditorAdmissionPolicy()
        XCTAssertEqual(EditorAdmissionPolicy.rasterBytes(bytesPerRow: Int.max, height: 2), Int.max)
        XCTAssertEqual(EditorAdmissionPolicy.rasterBytes(bytesPerRow: -1, height: 2), Int.max)
        XCTAssertEqual(EditorAdmissionPolicy.sum([Int.max, 1]), Int.max)
        XCTAssertEqual(EditorAdmissionPolicy.sum([-1, 0]), Int.max)
        XCTAssertEqual(policy.refusal(existingRasterBytes: [Int.max, 1], incomingRasterBytes: 1), .rasterBudget)
        XCTAssertEqual(policy.refusal(existingRasterBytes: [], incomingRasterBytes: -1), .rasterBudget)
    }

    @MainActor
    func testRepeatedCaptureFocusesBeforeHideOrCaptureAndPreservesEdits() {
        let gate = FrozenEditorCaptureAdmission<Editor>()
        let editor = Editor(); editor.unsavedEdits = ["rectangle", "text"]
        gate.register(editor)
        var events: [String] = []
        func requestCapture(busy: Bool = false) {
            guard gate.shouldStart(isBusy: busy, isClosed: { $0.closed }, focus: { candidate in
                XCTAssertTrue(candidate === editor); events.append("focus")
            }) else { return }
            events.append("hide")
            events.append("capture")
        }
        requestCapture(); requestCapture(); requestCapture(busy: true)
        XCTAssertEqual(events, ["focus", "focus", "focus"])
        XCTAssertEqual(editor.unsavedEdits, ["rectangle", "text"])
        gate.editorDidClose(editor)
        requestCapture()
        XCTAssertEqual(events, ["focus", "focus", "focus", "hide", "capture"])
    }

    @MainActor
    func testBusyAndActuallyClosedEditorAdmission() {
        let gate = FrozenEditorCaptureAdmission<Editor>()
        let editor = Editor(); gate.register(editor); editor.closed = true
        XCTAssertFalse(gate.shouldStart(isBusy: true, isClosed: { $0.closed }, focus: { _ in XCTFail("Closed editor must not focus") }))
        XCTAssertNil(gate.activeEditor)
        XCTAssertTrue(gate.shouldStart(isBusy: false, isClosed: { $0.closed }, focus: { _ in XCTFail() }))
    }

    @MainActor
    func testGateIsWeakAndOldCloseCannotClearReplacement() {
        let gate = FrozenEditorCaptureAdmission<Editor>()
        var editor: Editor? = Editor(); weak var probe = editor
        gate.register(editor!); editor = nil
        XCTAssertNil(probe); XCTAssertNil(gate.activeEditor)
        let previous = Editor(), next = Editor()
        gate.register(previous); gate.editorDidClose(previous); gate.register(next)
        gate.editorDidClose(previous)
        XCTAssertTrue(gate.activeEditor === next)
    }

    func testBatchRefusalsProduceOneNoticeAndReset() {
        var notices = EditorAdmissionNotices()
        notices.beginBatch()
        for _ in 0..<50 { XCTAssertFalse(notices.recordRefusal()) }
        XCTAssertEqual(notices.endBatch(), 50)
        XCTAssertEqual(notices.endBatch(), 0)
        notices.beginBatch(); XCTAssertEqual(notices.endBatch(), 0)
        XCTAssertTrue(notices.recordRefusal())
    }

    func testNestedImportBatchOnlyReportsAtOuterEnd() {
        var notices = EditorAdmissionNotices()
        notices.beginBatch(); XCTAssertFalse(notices.recordRefusal())
        notices.beginBatch(); XCTAssertFalse(notices.recordRefusal())
        XCTAssertEqual(notices.endBatch(), 0)
        XCTAssertEqual(notices.endBatch(), 2)
    }

    private final class Editor {
        var closed = false
        var unsavedEdits: [String] = []
    }
}
