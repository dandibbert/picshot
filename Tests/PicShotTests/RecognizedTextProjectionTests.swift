import XCTest
import CoreGraphics
@testable import PicShot

final class RecognizedTextProjectionTests: XCTestCase {
    func testOnlyExactUTF16OCRPrefixHasProvenance() {
        let document = makeDocument("重复 👩🏽‍💻 e\u{301}，")
        let appendix = "\n\n识别码：\n重复 👩🏽‍💻 e\u{301}，\n[结果已省略]"
        let projection = RecognizedTextProjection(text: document.text + appendix, document: document)
        XCTAssertEqual(projection.sourceRanges(for: [whole(projection.text)]), [whole(document.text)])
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: document.text.utf16.count, length: appendix.utf16.count)]), [])
        let decomposed = makeDocument("e\u{301}")
        XCTAssertTrue(RecognizedTextProjection(text: "é", document: decomposed).spans.isEmpty,
                      "Canonical equivalence does not establish equal UTF-16 offsets")
        XCTAssertTrue(RecognizedTextProjection(text: "prefix " + document.text, document: document).spans.isEmpty)
    }

    func testJoinLinesPreservesRepeatedWordsPunctuationAndGraphemes() {
        let document = makeDocument("  Same 👩🏽‍💻，\r\n\r\n 同词 e\u{301} \nSame")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        projection.joinLines()
        XCTAssertEqual(projection.text, "Same 👩🏽‍💻， 同词 e\u{301} Same")
        let output = (projection.text as NSString).range(of: "Same", options: .backwards)
        let source = (document.text as NSString).range(of: "Same", options: .backwards)
        XCTAssertEqual(projection.sourceRanges(for: [output]), [source])
        for token in ["👩🏽‍💻", "，", "同词", "e\u{301}"] {
            XCTAssertEqual(projection.sourceRanges(for: [(projection.text as NSString).range(of: token)]), [(document.text as NSString).range(of: token)])
        }
        let separator = NSRange(location: (projection.text as NSString).range(of: "，").upperBound, length: 1)
        XCTAssertTrue(projection.sourceRanges(for: [separator]).isEmpty)
    }

    func testRemoveEmptyLinesKeepsIndentationAndDoesNotMapSynthesizedNewline() {
        let document = makeDocument("  One \n \t\n\r\n Two \n")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        projection.removeEmptyLines()
        XCTAssertEqual(projection.text, "  One \n Two ")
        XCTAssertEqual(projection.sourceRanges(for: [(projection.text as NSString).range(of: " Two ")]), [(document.text as NSString).range(of: " Two ")])
        XCTAssertTrue(projection.sourceRanges(for: [(projection.text as NSString).range(of: "\n")]).isEmpty)
    }

    func testInsertedIdenticalWordsAndReplacementsNeverAcquireProvenance() {
        let document = makeDocument("same same")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        XCTAssertTrue(projection.replace(NSRange(location: 0, length: 0), with: "same "))
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: 0, length: 4)]), [])
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: 5, length: 4)]), [NSRange(location: 0, length: 4)])
        XCTAssertTrue(projection.replace(NSRange(location: 5, length: 4), with: "same"))
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: 5, length: 4)]), [], "Even same-value replacement is a user edit")
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: 10, length: 4)]), [NSRange(location: 5, length: 4)])
    }

    func testDeletingMiddlePreservesDisjointSourceRanges() {
        let document = makeDocument("alpha MIDDLE omega")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        XCTAssertTrue(projection.replace((document.text as NSString).range(of: "MIDDLE "), with: ""))
        XCTAssertEqual(projection.text, "alpha omega")
        XCTAssertEqual(projection.sourceRanges(for: [whole(projection.text)]), [NSRange(location: 0, length: 6), NSRange(location: 13, length: 5)])
        XCTAssertEqual(projection.outputRanges(for: [(document.text as NSString).range(of: "MIDDLE")]), [])
    }

    func testSourceSelectionSkipsInsertedOutputText() {
        let document = makeDocument("abcd")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        XCTAssertTrue(projection.replace(NSRange(location: 2, length: 0), with: "NEW"))
        XCTAssertEqual(projection.outputRanges(for: [whole(document.text)]), [NSRange(location: 0, length: 2), NSRange(location: 5, length: 2)])
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: 2, length: 3)]), [])
    }

    func testCombiningAndZWJInsertionDropsAbsorbedGrapheme() {
        var combining = RecognizedTextProjection(text: "e!", document: makeDocument("e!"))
        XCTAssertTrue(combining.replace(NSRange(location: 1, length: 0), with: "\u{301}"))
        XCTAssertEqual(combining.sourceRanges(for: [whole(combining.text)]), [NSRange(location: 1, length: 1)])
        var emoji = RecognizedTextProjection(text: "👩!", document: makeDocument("👩!"))
        XCTAssertTrue(emoji.replace(NSRange(location: 2, length: 0), with: "\u{200D}💻"))
        XCTAssertEqual(emoji.sourceRanges(for: [whole(emoji.text)]), [NSRange(location: 2, length: 1)])
    }

    func testInvalidOrPartialUTF16RangesAreRejected() {
        let document = makeDocument("👩🏽‍💻 e\u{301}")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        XCTAssertTrue(projection.sourceRanges(for: [NSRange(location: 1, length: 1)]).isEmpty)
        XCTAssertTrue(projection.sourceRanges(for: [NSRange(location: Int.max, length: Int.max)]).isEmpty)
        XCTAssertTrue(projection.outputRanges(for: [NSRange(location: -1, length: 1)]).isEmpty)
        XCTAssertFalse(projection.replace(NSRange(location: 0, length: Int.max), with: "bad"))
        XCTAssertEqual(projection.text, document.text)
    }

    func testUntrackedReplacementAndRestoredTextStayUnmappedUntilNewRecognition() {
        let document = makeDocument("same")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        projection.invalidate(to: "same")
        XCTAssertTrue(projection.sourceRanges(for: [whole(projection.text)]).isEmpty)
        projection = RecognizedTextProjection(text: document.text, document: document)
        XCTAssertEqual(projection.sourceRanges(for: [whole(projection.text)]), [whole(document.text)])
    }

    func testOversizedEditedTextDisablesOnlyMappingAndDoesNotReenableOnShrink() {
        let document = makeDocument("source")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        let large = String(repeating: "X", count: RecognizedTextProjection.maximumMappedUTF16Count)
        XCTAssertTrue(projection.replace(NSRange(location: 0, length: 0), with: large))
        XCTAssertTrue(projection.mappingLimitReached); XCTAssertTrue(projection.spans.isEmpty)
        XCTAssertEqual(projection.text.utf16.count, large.utf16.count + document.text.utf16.count)
        XCTAssertTrue(projection.replace(NSRange(location: 0, length: large.utf16.count), with: ""))
        XCTAssertTrue(projection.mappingLimitReached); XCTAssertTrue(projection.sourceRanges(for: [whole(projection.text)]).isEmpty)
        XCTAssertFalse(RecognizedTextProjection(text: large).mappingLimitReached, "Plain text panels have no OCR mapping contract")
    }

    func testRepeatedLayoutAndUnicodeEditKeepsEveryMappedSpanExact() {
        let document = makeDocument(" a e\u{301} \n\n b 👩🏽‍💻 \n c， ")
        var projection = RecognizedTextProjection(text: document.text, document: document)
        projection.removeEmptyLines(); projection.joinLines(); projection.joinLines()
        XCTAssertTrue(projection.replace((projection.text as NSString).range(of: "b"), with: "新"))
        for span in projection.spans {
            XCTAssertTrue((projection.text as NSString).substring(with: span.output).utf16.elementsEqual(document.substring(span.source).utf16))
            XCTAssertTrue(document.boundaries.contains(span.source.location)); XCTAssertTrue(document.boundaries.contains(span.source.upperBound))
        }
        XCTAssertTrue(projection.sourceRanges(for: [(projection.text as NSString).range(of: "新")]).isEmpty)
    }

    func testManyInsertedLinesAndMaximumFragmentedSpansKeepExactLayoutProvenance() {
        // A normal layout operation creates the maximum supported fragmentation without
        // injecting test-only state. Large inserted text then places 16384 nonempty lines
        // and 16384 blank lines before those 4096 distinct source spans.
        let count = RecognizedTextProjection.maximumSpans, insertedLines = 16_384
        let document = makeDocument(String(repeating: "  a  \n", count: count))
        var projection = RecognizedTextProjection(text: document.text, document: document)
        projection.removeEmptyLines()
        XCTAssertEqual(projection.spans.count, count); XCTAssertFalse(projection.mappingLimitReached)
        XCTAssertTrue(projection.replace(NSRange(location: 0, length: 0), with: String(repeating: "x\n\n", count: insertedLines)))
        XCTAssertLessThan(projection.text.utf16.count, RecognizedTextProjection.maximumMappedUTF16Count)
        projection.removeEmptyLines()
        XCTAssertEqual(projection.text.components(separatedBy: "\n").count, insertedLines + count)
        XCTAssertEqual(projection.spans.count, count); XCTAssertFalse(projection.mappingLimitReached)
        let prefixLength = insertedLines * 2
        XCTAssertTrue(projection.sourceRanges(for: [NSRange(location: 0, length: prefixLength)]).isEmpty)
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: prefixLength + 2, length: 1)]), [NSRange(location: 2, length: 1)])
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: prefixLength + (count - 1) * 6 + 2, length: 1)]),
                       [NSRange(location: (count - 1) * 6 + 2, length: 1)])
        projection.joinLines()
        XCTAssertEqual(projection.text, String(repeating: "x ", count: insertedLines) + Array(repeating: "a", count: count).joined(separator: " "))
        XCTAssertEqual(projection.spans.count, count); XCTAssertFalse(projection.mappingLimitReached)
        XCTAssertEqual(projection.sourceRanges(for: [NSRange(location: prefixLength + (count - 1) * 2, length: 1)]),
                       [NSRange(location: (count - 1) * 6 + 2, length: 1)])
    }

    func testLayoutSpanBudgetDisablesMappingWithoutDroppingText() {
        let lines = RecognizedTextProjection.maximumSpans + 1
        let document = makeDocument(String(repeating: "a\n", count: lines))
        var projection = RecognizedTextProjection(text: document.text, document: document)
        projection.joinLines()
        XCTAssertEqual(projection.text, Array(repeating: "a", count: lines).joined(separator: " "))
        XCTAssertTrue(projection.mappingLimitReached); XCTAssertTrue(projection.spans.isEmpty)
        projection.removeEmptyLines()
        XCTAssertEqual(projection.text.utf16.count, lines * 2 - 1)
        XCTAssertTrue(projection.mappingLimitReached); XCTAssertTrue(projection.sourceRanges(for: [whole(projection.text)]).isEmpty)
    }

    func testDocumentInitializerEnforcesSourceOrderForOverlaySweep() throws {
        let text = "alpha beta gamma", full = whole(text)
        let left = try XCTUnwrap(RecognizedTextQuad(rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2)))
        let right = try XCTUnwrap(RecognizedTextQuad(rect: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2)))
        let document = RecognizedTextDocument(text: text, lines: [RecognizedTextLine(range: full, quad: left)], units: [
            RecognizedTextUnit(range: NSRange(location: 11, length: 5), quad: left, lineIndex: 0),
            RecognizedTextUnit(range: NSRange(location: 0, length: 5), quad: right, lineIndex: 0),
            RecognizedTextUnit(range: NSRange(location: 6, length: 4), quad: left, lineIndex: 0),
            RecognizedTextUnit(range: NSRange(location: 0, length: 10), quad: left, lineIndex: 0)
        ])
        XCTAssertEqual(document.units.map { $0.range.location }, [0, 0, 6, 11])
        XCTAssertEqual(document.units.last?.quad, left, "Geometric/RTL positions do not replace logical source order")
    }

    private func makeDocument(_ text: String) -> RecognizedTextDocument { RecognizedTextDocument(text: text, lines: [], units: []) }
    private func whole(_ text: String) -> NSRange { NSRange(location: 0, length: text.utf16.count) }
}
