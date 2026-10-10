import XCTest
import AppKit
@testable import PicShot

final class PinTextDraftHistoryTests: XCTestCase {
    func testCombinedHistoryHasExplicitLevelAndPayloadCapsAcrossUndoRedoAndBranch() {
        var history = PinTextDraftHistory("initial")
        for index in 0..<100 {
            history.record("\(index) " + String(repeating: "🐱", count: 24_000), selection: NSRange(location: 2, length: 0))
            assertBounded(history)
        }
        let latest = history.current
        for _ in 0..<20 { _ = history.undo(); assertBounded(history) }
        for _ in 0..<20 { _ = history.redo(); assertBounded(history) }
        XCTAssertEqual(history.current, latest)
        XCTAssertTrue(history.undo())
        history.record("different branch 中文", selection: NSRange(location: 0, length: 2))
        XCTAssertTrue(history.redoStates.isEmpty); assertBounded(history)
        history.clear(); XCTAssertEqual(history.current.text, ""); XCTAssertEqual(history.retainedHistoryBytes, 0)
    }
    func testSmallEditsStopAtTwelveLevelsWithoutBreakingCurrentSelection() {
        var history = PinTextDraftHistory("0")
        for index in 1...30 { history.record(String(index), selection: NSRange(location: 1, length: 0)) }
        XCTAssertEqual(history.undoStates.count, 12)
        for _ in 0..<12 { XCTAssertTrue(history.undo()); assertBounded(history) }
        XCTAssertFalse(history.undo()); XCTAssertEqual(history.current.text, "18")
        for _ in 0..<12 { XCTAssertTrue(history.redo()); assertBounded(history) }
        XCTAssertEqual(history.current.text, "30"); XCTAssertEqual(history.current.selection, NSRange(location: 1, length: 0))
    }
    private func assertBounded(_ history: PinTextDraftHistory, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(history.undoStates.count + history.redoStates.count, PinTextDraftHistory.maximumLevels, file: file, line: line)
        XCTAssertLessThanOrEqual(history.retainedHistoryBytes, PinTextDraftHistory.maximumHistoryBytes, file: file, line: line)
    }
}
