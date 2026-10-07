import XCTest
@testable import PicShotCore

final class NumberedCalloutSequenceTests: XCTestCase {
    func testFormattingBoundariesDoNotWrapOrUseSubtractiveRomanIncorrectly() {
        for (value, label) in [(1, "A"), (7, "G"), (26, "Z"), (27, "AA"), (52, "AZ"), (53, "BA"), (702, "ZZ"), (703, "AAA"), (3999, "EWU")] {
            XCTAssertEqual(NumberedCalloutStyle.alphabetic.label(for: value), label)
        }
        for (value, label) in [(1, "I"), (4, "IV"), (7, "VII"), (9, "IX"), (40, "XL"), (49, "XLIX"), (90, "XC"), (400, "CD"), (900, "CM"), (3999, "MMMCMXCIX")] {
            XCTAssertEqual(NumberedCalloutStyle.roman.label(for: value), label)
        }
        XCTAssertEqual(NumberedCalloutStyle.decimal.label(for: Int.min), "1")
        XCTAssertEqual(NumberedCalloutStyle.roman.label(for: Int.max), "MMMCMXCIX")
        for style in NumberedCalloutStyle.allCases {
            XCTAssertEqual(Set((1...3999).map { style.label(for: $0) }).count, 3999)
            XCTAssertLessThanOrEqual((1...3999).map { style.label(for: $0).count }.max()!, 15)
        }
    }

    func testManualSevenDeletionUndoSnapshotAndIndependentDocuments() {
        var sequence = NumberedCalloutSequence(); sequence.setNext(7)
        let before = sequence
        sequence.didInsert(7); sequence.didInsert(8); sequence.didInsert(9)
        XCTAssertEqual(sequence.nextValue, 10)
        sequence.didDelete(8)
        XCTAssertEqual(sequence.nextValue, 10, "Default deletion leaves holes and does not reuse a serial")
        let inserted = sequence
        sequence.closesGapsOnDelete = true; sequence.didDelete(8)
        XCTAssertEqual(sequence.nextValue, 9)
        sequence = inserted; XCTAssertEqual(sequence.nextValue, 10)
        sequence = before; XCTAssertEqual(sequence.nextValue, 7)
        XCTAssertEqual(NumberedCalloutSequence().nextValue, 1)
    }

    func testExhaustionHasNoSilentDuplicateAndCanBeExplicitlyResetOrClosedGap() {
        var sequence = NumberedCalloutSequence(); sequence.setNext(Int.max)
        XCTAssertEqual(sequence.nextValue, 3999); XCTAssertFalse(sequence.isExhausted)
        sequence.didInsert(3999); XCTAssertTrue(sequence.isExhausted)
        sequence.didDelete(3999); XCTAssertTrue(sequence.isExhausted)
        sequence.closesGapsOnDelete = true; sequence.didDelete(3999)
        XCTAssertFalse(sequence.isExhausted); XCTAssertEqual(sequence.nextValue, 3999)
        sequence.setNext(Int.min); XCTAssertEqual(sequence.nextValue, 1)
    }

    func testCommentBudgetPreservesScalarsAndBoundsCombiningCharacters() {
        let text = "步骤七 · مرحبا · Привет · 👩🏽‍💻\n次の手順"
        XCTAssertEqual(NumberedCalloutSequence.boundedComment(text), text)
        let bounded = NumberedCalloutSequence.boundedComment(String(repeating: "a\u{301}", count: 20_000))
        XCTAssertEqual(bounded.utf16.count, 2048)
        let astral = NumberedCalloutSequence.boundedComment(String(repeating: "a", count: 2047) + "😀")
        XCTAssertEqual(astral.utf16.count, 2047); XCTAssertFalse(astral.contains("�"))
    }
}
