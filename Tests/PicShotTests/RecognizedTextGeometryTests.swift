import XCTest
import CoreGraphics
@testable import PicShot

final class RecognizedTextGeometryTests: XCTestCase {
    @MainActor func testExactPhraseRangesPreserveWhitespaceAndMixedUnicode() throws {
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        XCTAssertEqual(document.substring(try XCTUnwrap(document.selection(from: 0, through: 2))), "Select exact text")
        XCTAssertEqual(document.substring(try XCTUnwrap(document.selection(from: 7, through: 3))), "中文连续词句 é 👩🏽‍💻")
        XCTAssertEqual(document.substring(try XCTUnwrap(document.selection(from: 2, through: 4))), "text\n中文连续")
        XCTAssertEqual(document.substring(document.units[6].range), "é")
        XCTAssertEqual(document.substring(document.units[7].range), "👩🏽‍💻")
        XCTAssertNil(document.selection(from: -1, through: 3))
        XCTAssertNil(document.selection(from: 0, through: 8))
    }
    func testComposedCharacterBoundariesNeverSplitUnicode() throws {
        let text = "A e\u{301} 👩🏽‍💻 中文 🇨🇳", document = RecognizedTextDocument(text: text, lines: [], units: [])
        var cursor = 0, reconstructed = ""
        while cursor < text.utf16.count {
            let next = document.boundary(after: cursor)
            let part = document.substring(NSRange(location: cursor, length: next - cursor))
            XCTAssertEqual(part.count, 1)
            XCTAssertEqual(document.boundary(before: next), cursor)
            reconstructed += part; cursor = next
        }
        XCTAssertEqual(reconstructed, text)
        XCTAssertEqual(document.boundary(before: 0), 0)
        XCTAssertEqual(document.boundary(after: text.utf16.count), text.utf16.count)
    }
    func testMalformedUTF16AndLineReferencesAreRejectedWithoutShiftingValidLine() throws {
        let text = "e\u{301}👩🏽‍💻中文", quad = try XCTUnwrap(RecognizedTextQuad(rect: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.3)))
        let full = NSRange(location: 0, length: text.utf16.count)
        let lines = [RecognizedTextLine(range: NSRange(location: 1, length: 1), quad: quad), RecognizedTextLine(range: full, quad: quad)]
        let units = [RecognizedTextUnit(range: NSRange(location: 0, length: 1), quad: quad, lineIndex: 0),
                     RecognizedTextUnit(range: NSRange(location: 2, length: 1), quad: quad, lineIndex: 1),
                     RecognizedTextUnit(range: full, quad: quad, lineIndex: 1),
                     RecognizedTextUnit(range: full, quad: quad, lineIndex: 200)]
        let document = RecognizedTextDocument(text: text, lines: lines, units: units)
        XCTAssertEqual(document.lines.count, 1); XCTAssertEqual(document.units.count, 1)
        XCTAssertEqual(document.units.first?.lineIndex, 0)
        XCTAssertEqual(document.substring(NSRange(location: Int.max, length: 1)), "")
        XCTAssertEqual(document.substring(NSRange(location: 0, length: Int.max)), "")
    }
    func testNormalizedQuadValidatesAndUsesActualRotatedPolygon() throws {
        let quad = try XCTUnwrap(RecognizedTextQuad(topLeft: CGPoint(x: 0.1, y: 0.7), topRight: CGPoint(x: 0.7, y: 0.9),
                                                  bottomRight: CGPoint(x: 0.8, y: 0.6), bottomLeft: CGPoint(x: 0.2, y: 0.4)))
        XCTAssertTrue(quad.contains(CGPoint(x: 0.45, y: 0.65)))
        XCTAssertFalse(quad.contains(CGPoint(x: 0.11, y: 0.89)), "Bounding rectangle corners are not actual glyph polygons")
        let mapped = quad.points(in: CGRect(x: -42, y: -24, width: 2000, height: 640))
        XCTAssertEqual(mapped[0].x, 158, accuracy: 0.0001)
        XCTAssertEqual(mapped[0].y, 424, accuracy: 0.0001)
        XCTAssertNil(RecognizedTextQuad(rect: CGRect(x: 2, y: 0, width: 1, height: 1)))
        XCTAssertNil(RecognizedTextQuad(rect: .zero))
        XCTAssertNil(RecognizedTextQuad(topLeft: CGPoint(x: CGFloat.nan, y: 1), topRight: .zero, bottomRight: .zero, bottomLeft: .zero))
    }
    @MainActor func testHitTestingAndNearestWordRespectImageAspectRatio() throws {
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        XCTAssertEqual(document.unit(at: CGPoint(x: 0.15, y: 0.68)), 0)
        XCTAssertNil(document.unit(at: CGPoint(x: 0.325, y: 0.68)))
        XCTAssertEqual(document.nearestUnit(to: CGPoint(x: 0.33, y: 0.69), imageSize: CGSize(width: 1200, height: 200)), 1)
        XCTAssertEqual(document.nearestUnit(to: CGPoint(x: 0.10, y: 0.18), imageSize: CGSize(width: 200, height: 2000)), 3)
    }
    func testResultsAndGeometryHaveHardBoundsWithoutSplittingFinalCharacter() throws {
        let quad = try XCTUnwrap(RecognizedTextQuad(rect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let text = String(repeating: "a", count: RecognizedTextDocument.maximumUTF16Count - 1) + "👩🏽‍💻"
        let one = NSRange(location: 0, length: 1)
        let line = RecognizedTextLine(range: one, quad: quad), unit = RecognizedTextUnit(range: one, quad: quad, lineIndex: 0)
        let document = RecognizedTextDocument(text: text, lines: Array(repeating: line, count: 600), units: Array(repeating: unit, count: 9000))
        XCTAssertEqual(document.text.utf16.count, RecognizedTextDocument.maximumUTF16Count - 1)
        XCTAssertEqual(document.lines.count, RecognizedTextDocument.maximumLines)
        XCTAssertEqual(document.units.count, RecognizedTextDocument.maximumUnits)
        XCTAssertTrue(document.isTruncated)
        XCTAssertFalse(document.text.contains("👩"))
        let result = RecognitionResult(text: document.text, barcodes: ["exact:code"], document: document, omittedBarcodeCount: 2)
        XCTAssertTrue(result.displayText.contains("仅显示部分文字"))
        XCTAssertTrue(result.displayText.contains("2 个识别码"))
        XCTAssertTrue(result.displayText.contains("exact:code"))
    }
    func testCoincidentWordQuadsRemainExactLogicalRanges() throws {
        let quad = try XCTUnwrap(RecognizedTextQuad(rect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.3)))
        let text = "共享词框", range = NSRange(location: 0, length: text.utf16.count)
        let document = RecognizedTextDocument(text: text, lines: [RecognizedTextLine(range: range, quad: quad)],
            units: [RecognizedTextUnit(range: range, quad: quad, lineIndex: 0)])
        XCTAssertTrue(quad.approximatelyEquals(quad))
        XCTAssertEqual(document.substring(document.units[0].range), text)
        XCTAssertEqual(document.units.count, 1, "Vision word precision must not be represented as guessed character boxes")
    }
}
