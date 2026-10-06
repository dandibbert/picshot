import XCTest
import PicShotCore
@testable import PicShotTableEngine

final class SLANetPlusTests: XCTestCase {
    private let empty = TableOCRBox(x: 0, y: 0, width: 1, height: 1)

    private func output(_ tokens: [String], boxes: [[Float]], confidence: Float = 0.99,
                        width: Int = 200, height: Int = 100, ocr: [TableOCRObservation] = []) throws -> TableRecognitionResult {
        let sequence = tokens + ["eos"], classes = SLANetPlus.vocabulary.count
        var probabilities = [Float](repeating: (1 - confidence) / Float(classes - 1), count: sequence.count * classes)
        var geometry = [Float](repeating: 0, count: sequence.count * 8), cell = 0
        for (step, token) in sequence.enumerated() {
            let index = try XCTUnwrap(SLANetPlus.vocabulary.firstIndex(of: token))
            probabilities[step * classes + index] = confidence
            if token == "<td" || token == "<td></td>" {
                geometry.replaceSubrange((step * 8)..<(step * 8 + 8), with: boxes[cell]); cell += 1
            }
        }
        return try SLANetPlus.decode(boundingBoxes: geometry, boxShape: [1, Int64(sequence.count), 8],
                                    structureProbabilities: probabilities, probabilityShape: [1, Int64(sequence.count), 50],
                                    imageWidth: width, imageHeight: height, ocr: ocr)
    }
    private func box(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> [Float] {
        [x, y, x + w, y, x + w, y + h, x, y + h]
    }

    func testPinnedModelContract() {
        XCTAssertEqual(SLANetPlus.vocabulary.count, 50)
        XCTAssertEqual(SLANetPlus.vocabulary[7], "<td")
        XCTAssertEqual(SLANetPlus.vocabulary[10], " colspan=\"2\"")
        XCTAssertEqual(SLANetPlus.vocabulary[29], " rowspan=\"2\"")
        XCTAssertEqual(SLANetPlus.vocabulary[48], "<td></td>")
        XCTAssertEqual(SLANetPlus.vocabulary[49], "eos")
        XCTAssertEqual(SLANetPlus.modelByteCount, 7_758_305)
    }

    func testPreprocessBGRNormalizationAndZeroPadding() throws {
        let input = try SLANetPlus.preprocess(width: 2, height: 1, bgrBytes: [255, 0, 127, 255, 0, 127])
        XCTAssertEqual(input.shape, [1, 3, 488, 488])
        XCTAssertEqual(input.resizedWidth, 488); XCTAssertEqual(input.resizedHeight, 244)
        XCTAssertEqual(input.values[0], (1 - 0.485) / 0.229, accuracy: 0.00001)
        XCTAssertEqual(input.values[488 * 488], -0.456 / 0.224, accuracy: 0.00001)
        XCTAssertEqual(input.values[488 * 488 * 2], (Float(127) / 255 - 0.406) / 0.225, accuracy: 0.00001)
        for channel in 0..<3 { XCTAssertEqual(input.values[channel * 488 * 488 + 244 * 488], 0) }
    }

    func testRejectsInvalidOrExtremeImage() {
        XCTAssertThrowsError(try SLANetPlus.preprocess(width: 0, height: 1, bgrBytes: []))
        XCTAssertThrowsError(try SLANetPlus.preprocess(width: Int.max, height: Int.max, bgrBytes: []))
        XCTAssertThrowsError(try SLANetPlus.preprocess(width: 1, height: 1000, bgrBytes: [UInt8](repeating: 0, count: 3000)))
    }

    func testPreservesColspanAndHeaderAndText() throws {
        let tokens = ["<thead>", "<tr>", "<td", " colspan=\"2\"", ">", "</td>", "</tr>", "</thead>",
                      "<tbody>", "<tr>", "<td></td>", "<td></td>", "</tr>", "</tbody>"]
        let text = [TableOCRObservation(text: "Header", confidence: 0.99, box: TableOCRBox(x: 30, y: 8, width: 130, height: 25)),
                    TableOCRObservation(text: "=SUM(A1)", confidence: 0.99, box: TableOCRBox(x: 10, y: 60, width: 75, height: 20)),
                    TableOCRObservation(text: "中文", confidence: 0.98, box: TableOCRBox(x: 125, y: 60, width: 50, height: 20))]
        let result = try output(tokens, boxes: [box(0, 0, 1, 0.25), box(0, 0.25, 0.5, 0.25), box(0.5, 0.25, 0.5, 0.25)], ocr: text)
        XCTAssertEqual(result.table.rowCount, 2); XCTAssertEqual(result.table.columnCount, 2)
        XCTAssertEqual(result.table.cells.count, 3)
        let header = try XCTUnwrap(result.table.cell(at: TableCoordinate(row: 0, column: 0)))
        XCTAssertEqual(header.columnSpan, 2); XCTAssertEqual(header.value, .text("Header")); XCTAssertTrue(header.style.bold)
        XCTAssertEqual(result.table.cell(at: TableCoordinate(row: 1, column: 0))?.value, .text("=SUM(A1)"))
        XCTAssertEqual(result.table.cell(at: TableCoordinate(row: 1, column: 1))?.value, .text("中文"))
        XCTAssertTrue(result.unmatchedOCR.isEmpty)
    }

    func testRowspanSkipsOccupiedPositions() throws {
        let result = try output(["<tr>", "<td", " rowspan=\"2\"", ">", "</td>", "<td></td>", "</tr>",
                                 "<tr>", "<td></td>", "</tr>"],
                                boxes: [box(0, 0, 0.5, 0.5), box(0.5, 0, 0.5, 0.25), box(0.5, 0.25, 0.5, 0.25)])
        XCTAssertEqual(result.table.cells.map(\.rowSpan), [2, 1, 1])
        XCTAssertEqual(result.table.cell(at: TableCoordinate(row: 1, column: 0))?.row, 0)
        XCTAssertEqual(result.table.cells.last?.column, 1)
    }

    func testNonsquareGeometryUsesLongestEdgeForBothAxes() throws {
        let result = try output(["<tr>", "<td></td>", "</tr>"], boxes: [box(0.1, 0.05, 0.8, 0.4)])
        XCTAssertEqual(result.cells[0].box.x, 20, accuracy: 0.0001)
        XCTAssertEqual(result.cells[0].box.y, 10, accuracy: 0.0001)
        XCTAssertEqual(result.cells[0].box.height, 80, accuracy: 0.0001)
    }

    func testUnmatchedAndAmbiguousOCRIsRetained() throws {
        let uncertain = TableOCRObservation(text: "uncertain", confidence: 0.1, box: empty)
        let outside = TableOCRObservation(text: "caption", confidence: 1, box: TableOCRBox(x: 300, y: 200, width: 10, height: 10))
        let crossCell = TableOCRObservation(text: "spans two cells", confidence: 1, box: TableOCRBox(x: 0, y: 30, width: 200, height: 20))
        let result = try output(["<tr>", "<td></td>", "<td></td>", "</tr>"], boxes: [box(0, 0, 0.5, 0.5), box(0.5, 0, 0.5, 0.5)], ocr: [uncertain, outside, crossCell])
        XCTAssertEqual(result.unmatchedOCR, [uncertain, outside, crossCell])
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testRejectsLowConfidenceAndInvalidGeometry() throws {
        XCTAssertThrowsError(try output(["<tr>", "<td></td>", "</tr>"], boxes: [box(0, 0, 1, 0.5)], confidence: 0.4))
        XCTAssertThrowsError(try output(["<tr>", "<td></td>", "</tr>"], boxes: [[Float](repeating: 0, count: 8)]))
    }

    func testRejectsMalformedSpansAndRaggedGrid() throws {
        XCTAssertThrowsError(try SLANetPlus.parse(["<tr>", "<td", " rowspan=\"2\"", ">", "</td>", "</tr>"]))
        XCTAssertThrowsError(try SLANetPlus.parse(["<tr>", "<td", " colspan=\"2\"", " colspan=\"3\"", ">", "</td>", "</tr>"]))
        XCTAssertThrowsError(try SLANetPlus.parse(["<tr>", "<td></td>", "<td></td>", "</tr>", "<tr>", "<td></td>", "</tr>"]))
        XCTAssertThrowsError(try SLANetPlus.parse(["<tr>", "<td></td>"]))
    }

    func testRejectsTensorTruncationAndMissingEOS() throws {
        XCTAssertThrowsError(try SLANetPlus.decode(boundingBoxes: [], boxShape: [1, 1, 8], structureProbabilities: [],
                                                  probabilityShape: [1, 1, 50], imageWidth: 200, imageHeight: 100, ocr: []))
        var probabilities = [Float](repeating: 0, count: 50); probabilities[5] = 1
        XCTAssertThrowsError(try SLANetPlus.decode(boundingBoxes: [Float](repeating: 0, count: 8), boxShape: [1, 1, 8],
                                                  structureProbabilities: probabilities, probabilityShape: [1, 1, 50],
                                                  imageWidth: 200, imageHeight: 100, ocr: [])) { error in
            XCTAssertEqual(error as? TableRecognitionError, .incompleteSequence)
        }
    }

    func testTextReadingOrderAndCodableRoundTrip() throws {
        let observations = [TableOCRObservation(text: "line2", confidence: 1, box: TableOCRBox(x: 10, y: 50, width: 50, height: 20)),
                            TableOCRObservation(text: "right", confidence: 1, box: TableOCRBox(x: 80, y: 10, width: 50, height: 20)),
                            TableOCRObservation(text: "left", confidence: 1, box: TableOCRBox(x: 10, y: 10, width: 50, height: 20))]
        let result = try output(["<tr>", "<td></td>", "</tr>"], boxes: [box(0, 0, 1, 0.5)], ocr: observations)
        XCTAssertEqual(result.table.cells[0].value, .text("left right\nline2"))
        XCTAssertEqual(try JSONDecoder().decode(TableRecognitionResult.self, from: JSONEncoder().encode(result)), result)
    }
}
