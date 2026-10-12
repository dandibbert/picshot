import AppKit
import PicShotTextScriptCore
import XCTest
@testable import PicShot

@MainActor final class TextScriptClipboardTests: XCTestCase {
    func testExactUnicodeTextIsWrittenOnceAfterClear() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("previous", forType: .string))
        let previousCount = board.changeCount, text = "ABC-1\n猫 🐈 e\u{301}"
        var writes = 0
        try CheckedTextClipboard.copy(text, pasteboard: board, writer: { target, value in
            writes += 1; XCTAssertTrue(target === board); XCTAssertEqual(value, text)
            XCTAssertNil(target.string(forType: .string)); XCTAssertGreaterThan(target.changeCount, previousCount)
            return target.setString(value, forType: .string)
        })
        XCTAssertEqual(writes, 1); XCTAssertEqual(board.string(forType: .string), text)
    }

    func testEmptyAndOversizedTextPreserveAllPriorClipboardContents() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let png = Data([1, 2, 3]), previous = "must survive validation failure"
        XCTAssertTrue(board.setString(previous, forType: .string)); XCTAssertTrue(board.setData(png, forType: .png))
        let previousCount = board.changeCount
        var writes = 0
        for (text, failure) in [("", ChainTextFailure.emptyOutput),
                                (String(repeating: "A", count: TextScriptLimits.outputUTF16Units + 1), .oversizedOutput),
                                (String(repeating: "🐈", count: TextScriptLimits.outputUTF16Units / 2 + 1), .oversizedOutput)] {
            XCTAssertThrowsError(try CheckedTextClipboard.copy(text, pasteboard: board,
                writer: { _, _ in writes += 1; return true })) { XCTAssertEqual($0 as? ChainTextFailure, failure) }
            XCTAssertEqual(board.changeCount, previousCount); XCTAssertEqual(board.string(forType: .string), previous)
            XCTAssertEqual(board.data(forType: .png), png)
        }
        XCTAssertEqual(writes, 0)
    }

    func testFalseAcknowledgementIsFailureAndMayRetryTheSameText() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("previous", forType: .string))
        let text = "approved output"
        var writes = 0
        XCTAssertThrowsError(try CheckedTextClipboard.copy(text, pasteboard: board, writer: { _, value in
            writes += 1; XCTAssertEqual(value, text); return false
        })) { XCTAssertEqual($0 as? ChainTextFailure, .clipboardRejected) }
        XCTAssertEqual(writes, 1); XCTAssertNil(board.string(forType: .string))
        try CheckedTextClipboard.copy(text, pasteboard: board)
        XCTAssertEqual(board.string(forType: .string), text)
    }

    func testExactUTF16BoundaryAllowsSupplementaryCharactersAndWhitespace() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        for text in [String(repeating: "🐈", count: TextScriptLimits.outputUTF16Units / 2), " \n\t"] {
            try CheckedTextClipboard.copy(text, pasteboard: board)
            XCTAssertEqual(board.string(forType: .string), text)
        }
    }
}
