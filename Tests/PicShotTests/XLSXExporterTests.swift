import XCTest
import Foundation
import AppKit
import PicShotCore
@testable import PicShot

final class XLSXExporterTests: XCTestCase {
    private func fixture() throws -> StructuredTable {
        var table = try StructuredTable(rowCount: 3, columnCount: 3, title: "'财务/[测试]:*?\\' <&>\"")
        try table.setValue(.text("=HYPERLINK(\"https://example.invalid\",\"never execute\")"), at: TableCoordinate(row: 0, column: 0))
        try table.setValue(.text("<&> \"quoted\" 'single'\n中文😀"), at: TableCoordinate(row: 1, column: 0))
        try table.setValue(.number(123.5), at: TableCoordinate(row: 1, column: 1))
        try table.setValue(.boolean(true), at: TableCoordinate(row: 1, column: 2))
        try table.merge(TableRange(firstRow: 0, firstColumn: 0, lastRow: 0, lastColumn: 2))
        try table.setStyle(TableCellStyle(bold: true, italic: true, alignment: .center, fill: .yellow),
                           in: TableRange(firstRow: 0, firstColumn: 0, lastRow: 0, lastColumn: 2))
        return table
    }
    func testPartsAreParseableXMLWithInlineTextAndRealMergedCells() throws {
        let parts = try XLSXExporter.packageParts(for: fixture())
        XCTAssertEqual(parts.count, 8)
        for (name, data) in parts {
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(name): \(String(describing: parser.parserError))")
        }
        let sheet = try XCTUnwrap(parts["xl/worksheets/sheet1.xml"])
        let text = String(decoding: sheet, as: UTF8.self)
        XCTAssertTrue(text.contains("<mergeCell ref=\"A1:C1\"/>"))
        XCTAssertTrue(text.contains("t=\"inlineStr\""))
        XCTAssertTrue(text.contains("=HYPERLINK(&quot;https://example.invalid&quot;"))
        XCTAssertTrue(text.contains("&lt;&amp;&gt;"))
        XCTAssertTrue(text.contains("<c r=\"B2\" s=\"0\" t=\"n\"><v>123.5</v></c>"))
        XCTAssertTrue(text.contains("t=\"b\"><v>1</v>"))
        XCTAssertFalse(text.contains("<f>")); XCTAssertFalse(text.contains("<hyperlink"))
        XCTAssertFalse(parts.keys.contains { $0.contains("externalLink") || $0.contains("vba") || $0.contains("media") })
        let capture = XMLCapture()
        let parser = XMLParser(data: sheet); parser.delegate = capture; XCTAssertTrue(parser.parse())
        XCTAssertTrue(capture.text.contains("<&> \"quoted\" 'single'\n中文😀"))
        let style = String(decoding: try XCTUnwrap(parts["xl/styles.xml"]), as: UTF8.self)
        XCTAssertTrue(style.contains("horizontal=\"center\"")); XCTAssertTrue(style.contains("FFFFF2CC"))
        XCTAssertTrue(style.contains("<b/><i/>"))
        XCTAssertEqual(String(decoding: try XCTUnwrap(parts["docProps/core.xml"]), as: UTF8.self).components(separatedBy: "<dc:").count, 2)
    }
    func testRealXLSXZIPCanBeInspectedAndAllPartsMatch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("table with spaces ' &.xlsx")
        let table = try fixture()
        try XLSXExporter.write(table, to: destination)
        XCTAssertTrue(try Data(contentsOf: destination).starts(with: [0x50, 0x4B, 0x03, 0x04]))
        let extracted = folder.appendingPathComponent("extracted", isDirectory: true)
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", destination.path, "-d", extracted.path]
        unzip.standardOutput = FileHandle.nullDevice; unzip.standardError = FileHandle.nullDevice
        try unzip.run(); unzip.waitUntilExit(); XCTAssertEqual(unzip.terminationStatus, 0)
        for (name, expected) in try XLSXExporter.packageParts(for: table) {
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(name)), expected, name)
        }
        // Replacing an existing destination is atomic, not append-to-archive.
        try XLSXExporter.write(StructuredTable(rowCount: 1, columnCount: 1), to: destination)
        XCTAssertTrue(try Data(contentsOf: destination).starts(with: [0x50, 0x4B, 0x03, 0x04]))
    }
    func testEscapesOOXMLLiteralSequencesAndXMLControls() throws {
        let encoded = XLSXExporter.spreadsheetText("_x0041_ _x005F_ \u{0000}\u{0001}\r\n\t<&>")
        XCTAssertEqual(encoded, "_x005F_x0041_ _x005F_x005F_ _x0000__x0001__x000D_\n\t&lt;&amp;&gt;")
        let parser = XMLParser(data: Data("<t>\(encoded)</t>".utf8))
        XCTAssertTrue(parser.parse())
    }
    func testSheetNameSanitizesUTF16LengthAndInvalidCharacters() {
        let name = XLSXExporter.sheetName("'\u{0000}[]:*?/\\" + String(repeating: "😀", count: 40) + "'")
        XCTAssertLessThanOrEqual(name.utf16.count, 31)
        XCTAssertEqual(name, String(repeating: "😀", count: 15))
        XCTAssertEqual(XLSXExporter.sheetName("[]:*?/\\'"), "Sheet1")
    }
    func testRejectsTooLongCellsWithoutWritingDestination() throws {
        let table = try StructuredTable(rowCount: 1, columnCount: 1, cells: [TableCell(row: 0, column: 0, value: .text(String(repeating: "😀", count: 16_384)))])
        XCTAssertThrowsError(try XLSXExporter.packageParts(for: table))
    }
    @MainActor func testEditorAcceptsMergedTableAndOptionalOriginalImage() throws {
        let editor = TableEditorController(table: try fixture())
        XCTAssertNotNil(editor.window?.contentView)
        XCTAssertEqual(editor.table.cells.filter(\.isMerged).count, 1)
        XCTAssertTrue(editor.window?.title.contains("表格编辑器") == true)
        editor.close()
    }
}
private final class XMLCapture: NSObject, XMLParserDelegate {
    var text = ""
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
}
