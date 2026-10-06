import XCTest
@testable import PicShotCore

final class StructuredTableTests: XCTestCase {
    private func address(_ row: Int, _ column: Int) -> TableCoordinate { TableCoordinate(row: row, column: column) }
    private func range(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) -> TableRange {
        TableRange(firstRow: r1, firstColumn: c1, lastRow: r2, lastColumn: c2)
    }
    func testFillsUncoveredSlotsAndRejectsInvalidSpans() throws {
        let table = try StructuredTable(rowCount: 3, columnCount: 3, cells: [TableCell(row: 0, column: 0, rowSpan: 2, columnSpan: 2, value: .text("Header"))])
        XCTAssertEqual(table.cells.count, 6)
        XCTAssertEqual(table.cell(at: address(0, 0))?.id, table.cell(at: address(1, 1))?.id)
        XCTAssertEqual(table.cell(at: address(2, 2))?.value, .text(""))
        XCTAssertNil(table.cell(at: address(-1, 0)))
        XCTAssertThrowsError(try StructuredTable(rowCount: 0, columnCount: 2))
        XCTAssertThrowsError(try StructuredTable(rowCount: Int.max, columnCount: Int.max))
        XCTAssertThrowsError(try StructuredTable(rowCount: 2, columnCount: 2, cells: [TableCell(row: 0, column: 0, rowSpan: Int.max)]))
        XCTAssertThrowsError(try StructuredTable(rowCount: 2, columnCount: 2, cells: [TableCell(row: 0, column: 0, rowSpan: 2), TableCell(row: 1, column: 0)]))
        let id = UUID()
        XCTAssertThrowsError(try StructuredTable(rowCount: 1, columnCount: 2, cells: [TableCell(id: id, row: 0, column: 0), TableCell(id: id, row: 0, column: 1)]))
    }
    func testMergeKeepsTextOrderAndSplitKeepsTopLeftIdentityAndStyle() throws {
        var table = try StructuredTable(rowCount: 2, columnCount: 3)
        try table.setValue(.text("one"), at: address(0, 0))
        try table.setValue(.text("two"), at: address(0, 1))
        try table.setValue(.text("three"), at: address(1, 0))
        let style = TableCellStyle(bold: true, fill: .blue)
        try table.setStyle(style, in: range(0, 0, 1, 1))
        let originalID = try XCTUnwrap(table.cell(at: address(0, 0))).id
        let merged = try table.merge(range(0, 0, 1, 1))
        XCTAssertEqual(merged.id, originalID)
        XCTAssertEqual(merged.value, .text("one\ntwo\nthree"))
        XCTAssertEqual(table.cells.count, 3)
        XCTAssertEqual(table.cell(at: address(1, 1))?.id, originalID)
        try table.split(at: address(1, 1))
        XCTAssertEqual(table.cells.count, 6)
        XCTAssertEqual(table.cell(at: address(0, 0))?.id, originalID)
        XCTAssertEqual(table.cell(at: address(0, 0))?.value, merged.value)
        XCTAssertEqual(table.cell(at: address(1, 1))?.value, .text(""))
        XCTAssertEqual(table.cell(at: address(1, 1))?.style, style)
    }
    func testPartialSpanMergeRejectedTransactionallyAndExpansionIsTransitive() throws {
        var table = try StructuredTable(rowCount: 4, columnCount: 4, cells: [
            TableCell(row: 0, column: 0, rowSpan: 2, columnSpan: 2),
            TableCell(row: 1, column: 2, rowSpan: 2, columnSpan: 2)
        ])
        let before = table
        XCTAssertThrowsError(try table.merge(range(0, 0, 0, 2))) { XCTAssertEqual($0 as? StructuredTableError, .partialMerge) }
        XCTAssertEqual(table, before)
        XCTAssertEqual(try table.expandedRange(range(0, 1, 0, 2)), range(0, 0, 2, 3))
        try table.merge(try table.expandedRange(range(0, 1, 0, 2)))
        XCTAssertEqual(table.cell(at: address(2, 3))?.range, range(0, 0, 2, 3))
    }
    func testInsertionThroughSpansAndDeletionOfAnchorsPreserveReferences() throws {
        let id = UUID()
        var table = try StructuredTable(rowCount: 4, columnCount: 4, cells: [
            TableCell(id: id, row: 1, column: 1, rowSpan: 2, columnSpan: 2, value: .text("stable"))
        ])
        let unaffectedID = try XCTUnwrap(table.cell(at: address(3, 3))).id
        try table.insertRow(at: 2); try table.insertColumn(at: 2)
        XCTAssertEqual(table.cell(id: id)?.range, range(1, 1, 3, 3))
        XCTAssertEqual(table.cell(id: unaffectedID)?.coordinate, address(4, 4))
        try table.deleteRow(at: 1); try table.deleteColumn(at: 1)
        XCTAssertEqual(table.cell(id: id)?.range, range(1, 1, 2, 2))
        XCTAssertEqual(table.cell(id: id)?.value, .text("stable"))
        try table.insertRow(at: 1); try table.insertColumn(at: 1)
        XCTAssertEqual(table.cell(id: id)?.range, range(2, 2, 3, 3))
        try table.deleteRow(at: 3); try table.deleteColumn(at: 3)
        XCTAssertEqual(table.cell(id: id)?.range, range(2, 2, 2, 2))
        try table.deleteRow(at: 2)
        XCTAssertNil(table.cell(id: id))
    }
    func testAppendRowsColumnsAndRejectDeletingFinalDimensions() throws {
        var table = try StructuredTable(rowCount: 1, columnCount: 1)
        let before = table
        XCTAssertThrowsError(try table.deleteRow(at: 0))
        XCTAssertThrowsError(try table.deleteColumn(at: 0))
        XCTAssertEqual(table, before)
        try table.insertRow(at: 1); try table.insertColumn(at: 1)
        XCTAssertEqual(table.rowCount, 2); XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.cells.count, 4)
        XCTAssertEqual(table.cell(at: address(0, 0))?.id, before.cells[0].id)
        XCTAssertThrowsError(try table.insertRow(at: -1))
        XCTAssertThrowsError(try table.insertColumn(at: 3))
    }
    func testTypedValuesRequireExplicitChoiceAndRejectNonfiniteNumbers() throws {
        var table = try StructuredTable(rowCount: 1, columnCount: 3)
        try table.setValue(.text("=SUM(A1:A2)"), at: address(0, 0))
        try table.setValue(.number(-42.5), at: address(0, 1))
        try table.setValue(.boolean(true), at: address(0, 2))
        XCTAssertEqual(table.cell(at: address(0, 0))?.value, .text("=SUM(A1:A2)"))
        let before = table
        XCTAssertThrowsError(try table.setValue(.number(.infinity), at: address(0, 0)))
        XCTAssertThrowsError(try table.setValue(.number(.nan), at: address(0, 0)))
        XCTAssertEqual(before, table)
        XCTAssertEqual(try table.tsv(), "'=SUM(A1:A2)\t-42.5\tTRUE")
    }
    func testTSVQuotesMultilineTabsAndFormulaLikeText() throws {
        var table = try StructuredTable(rowCount: 2, columnCount: 3)
        try table.setValue(.text("a\tb\n\"c\""), at: address(0, 0))
        try table.setValue(.text(" @SUM(1)"), at: address(0, 1))
        try table.setValue(.text("safe"), at: address(1, 0))
        try table.merge(range(1, 0, 1, 1))
        XCTAssertEqual(try table.tsv(), "\"a\tb\n\"\"c\"\"\"\t' @SUM(1)\t\nsafe\t\t")
        XCTAssertEqual(try table.tsv(in: range(0, 1, 0, 1), spreadsheetSafe: false), " @SUM(1)")
    }
    func testCodableRoundTripValidatesAndPreservesIdentities() throws {
        var table = try StructuredTable(rowCount: 3, columnCount: 3, title: "测试")
        try table.setValue(.boolean(false), at: address(0, 0))
        try table.merge(range(0, 0, 1, 1))
        try table.insertColumn(at: 1)
        let data = try JSONEncoder().encode(table)
        XCTAssertEqual(try JSONDecoder().decode(StructuredTable.self, from: data), table)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["columnCount"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(StructuredTable.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testRepeatedSpanEditsLeaveEveryCoordinateOwnedExactlyOnce() throws {
        var table = try StructuredTable(rowCount: 6, columnCount: 6)
        try table.merge(range(0, 0, 2, 2)); try table.merge(range(3, 3, 5, 5))
        for _ in 0..<20 {
            try table.insertRow(at: 1); try table.insertColumn(at: 4)
            try table.deleteRow(at: 2); try table.deleteColumn(at: 3)
            let reconstructed = try StructuredTable(rowCount: table.rowCount, columnCount: table.columnCount, cells: table.cells)
            XCTAssertEqual(reconstructed.cells, table.cells)
            XCTAssertEqual(Set(table.cells.map(\.id)).count, table.cells.count)
            for row in 0..<table.rowCount { for column in 0..<table.columnCount {
                let point = address(row, column)
                XCTAssertEqual(table.cells.filter { $0.range.contains(point) }.count, 1)
                XCTAssertNotNil(table.cell(at: point))
            } }
        }
    }
    func testSpreadsheetReferences() {
        XCTAssertEqual(TableCoordinate.columnName(0), "A")
        XCTAssertEqual(TableCoordinate.columnName(25), "Z")
        XCTAssertEqual(TableCoordinate.columnName(26), "AA")
        XCTAssertEqual(TableCoordinate.columnName(255), "IV")
        XCTAssertEqual(range(0, 0, 2, 27).spreadsheetReference, "A1:AB3")
    }
}
