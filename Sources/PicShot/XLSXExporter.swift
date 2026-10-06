import Foundation
import PicShotCore

/// A real Office Open XML workbook, without formulas, external links, macros, user names or source images.
/// Format references: https://learn.microsoft.com/office/open-xml/spreadsheet/structure-of-a-spreadsheetml-document
/// and https://learn.microsoft.com/dotnet/api/documentformat.openxml.spreadsheet.cell
/// /usr/bin/zip is included with macOS; no shell, downloaded executable or Excel installation is used.
enum XLSXExporter {
    enum ExportError: Error, LocalizedError {
        case cellTooLong(String), archiveFailed, invalidDestination
        var errorDescription: String? {
            switch self {
            case .cellTooLong(let reference): return "\(reference) 超过 Excel 单元格的 32,767 字符限制。请缩短后再导出。"
            case .archiveFailed: return "无法生成 XLSX 压缩包。"
            case .invalidDestination: return "请选择本机 XLSX 文件保存位置。"
            }
        }
    }

    static func write(_ table: StructuredTable, to destination: URL) throws {
        guard destination.isFileURL else { throw ExportError.invalidDestination }
        let parts = try packageParts(for: table)
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("PicShot-XLSX-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        for (name, data) in parts {
            let url = directory.appendingPathComponent(name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        let archive = directory.appendingPathComponent("Workbook.xlsx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-X", archive.path] + parts.keys.sorted()
        // Quiet mode plus /dev/null avoids blocking on a full pipe on a failed invocation.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.archiveFailed }
        let data = try Data(contentsOf: archive)
        guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw ExportError.archiveFailed }
        try data.write(to: destination, options: .atomic)
    }

    /// Also exposed internally for structural tests; every path here is a constant, never user input.
    static func packageParts(for table: StructuredTable) throws -> [String: Data] {
        var styles: [TableCellStyle] = [TableCellStyle()]
        var styleIndices: [TableCellStyle: Int] = [styles[0]: 0]
        for cell in table.cells where styleIndices[cell.style] == nil {
            styleIndices[cell.style] = styles.count; styles.append(cell.style)
        }
        let namespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var rows: [String] = []
        var cursor = 0
        for row in 0..<table.rowCount {
            var cells = ""
            while cursor < table.cells.count, table.cells[cursor].row == row {
                let cell = table.cells[cursor]
                let reference = cell.coordinate.spreadsheetReference
                let start = "<c r=\"\(reference)\" s=\"\(styleIndices[cell.style] ?? 0)\""
                switch cell.value {
                case .text(let text):
                    guard text.utf16.count <= 32_767 else { throw ExportError.cellTooLong(reference) }
                    cells += start + " t=\"inlineStr\"><is><t xml:space=\"preserve\">\(spreadsheetText(text))</t></is></c>"
                case .number(let value):
                    guard value.isFinite else { throw StructuredTableError.invalidNumber }
                    cells += start + " t=\"n\"><v>\(String(value))</v></c>"
                case .boolean(let value):
                    cells += start + " t=\"b\"><v>\(value ? "1" : "0")</v></c>"
                }
                cursor += 1
            }
            rows.append("<row r=\"\(row + 1)\" ht=\"24\" customHeight=\"1\">\(cells)</row>")
        }
        let merged = table.cells.filter(\.isMerged)
        let merges = merged.isEmpty ? "" : "<mergeCells count=\"\(merged.count)\">" + merged.map { "<mergeCell ref=\"\($0.range.spreadsheetReference)\"/>" }.joined() + "</mergeCells>"
        let sheet = "<worksheet xmlns=\"\(namespace)\"><dimension ref=\"\(table.fullRange.spreadsheetReference)\"/><sheetViews><sheetView workbookViewId=\"0\"/></sheetViews><sheetFormatPr defaultRowHeight=\"24\"/><cols><col min=\"1\" max=\"\(table.columnCount)\" width=\"22\" customWidth=\"1\"/></cols><sheetData>\(rows.joined())</sheetData>\(merges)</worksheet>"
        let workbook = "<workbook xmlns=\"\(namespace)\" xmlns:r=\"\(relationships)\"><bookViews><workbookView/></bookViews><sheets><sheet name=\"\(spreadsheetText(sheetName(table.title)))\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        let contentTypes = """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
        """
        let rootRelations = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\(relationships)/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="\(relationships)/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="\(relationships)/extended-properties" Target="docProps/app.xml"/></Relationships>
        """.replacingOccurrences(of: "\(relationships)/metadata/core-properties", with: "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties")
        let workbookRelations = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\(relationships)/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="\(relationships)/styles" Target="styles.xml"/></Relationships>
        """
        // Deliberately omit local paths, times, account names, original pixels and OCR provenance.
        let core = "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator>PicShot</dc:creator></cp:coreProperties>"
        let app = "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>PicShot</Application></Properties>"
        let raw = ["[Content_Types].xml": contentTypes, "_rels/.rels": rootRelations,
                   "xl/workbook.xml": workbook, "xl/_rels/workbook.xml.rels": workbookRelations,
                   "xl/worksheets/sheet1.xml": sheet, "xl/styles.xml": stylesXML(styles),
                   "docProps/core.xml": core, "docProps/app.xml": app]
        return raw.mapValues { Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + $0).utf8) }
    }

    private static func stylesXML(_ styles: [TableCellStyle]) -> String {
        let fonts = (0..<4).map { i in
            "<font>\(i & 1 != 0 ? "<b/>" : "")\(i & 2 != 0 ? "<i/>" : "")<sz val=\"11\"/><color rgb=\"FF202020\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        }.joined()
        let fills: [TableCellFill] = [.yellow, .blue, .green, .gray]
        let fillXML = "<fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>" + fills.map {
            "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\($0.rgbHex!)\"/><bgColor indexed=\"64\"/></patternFill></fill>"
        }.joined()
        let formats = styles.map { style in
            let font = (style.bold ? 1 : 0) + (style.italic ? 2 : 0)
            let fill = fills.firstIndex(of: style.fill).map { $0 + 2 } ?? 0
            return "<xf numFmtId=\"0\" fontId=\"\(font)\" fillId=\"\(fill)\" borderId=\"1\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\" applyAlignment=\"1\"><alignment horizontal=\"\(style.alignment.rawValue)\" vertical=\"center\" wrapText=\"1\"/></xf>"
        }.joined()
        let border = ["left", "right", "top", "bottom"].map { "<\($0) style=\"thin\"><color rgb=\"FFD0D0D0\"/></\($0)>" }.joined()
        return "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"4\">\(fonts)</fonts><fills count=\"6\">\(fillXML)</fills><borders count=\"2\"><border><left/><right/><top/><bottom/><diagonal/></border><border>\(border)<diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"\(styles.count)\">\(formats)</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
    }

    static func sheetName(_ input: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\").union(.controlCharacters)
        let clean = String(String.UnicodeScalarView(input.unicodeScalars.filter { !forbidden.contains($0) && $0.value != 0xFFFE && $0.value != 0xFFFF }))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'")))
        var result = ""
        for character in clean {
            guard result.utf16.count + String(character).utf16.count <= 31 else { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        return result.isEmpty ? "Sheet1" : result
    }
    private static func xml(_ input: String) -> String {
        input.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    /// Escape literal OOXML escape sequences before encoding disallowed XML 1.0 characters.
    /// CR is escaped because XML parsers normalize a literal CR to LF.
    static func spreadsheetText(_ input: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "_(x[0-9A-Fa-f]{4}_)")
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let literalSafe = pattern.stringByReplacingMatches(in: input, range: range, withTemplate: "_x005F_$1")
        var safe = ""
        for scalar in literalSafe.unicodeScalars {
            let n = scalar.value
            if n == 0xD || (n < 0x20 && n != 0x9 && n != 0xA) || n == 0xFFFE || n == 0xFFFF {
                safe += String(format: "_x%04X_", n)
            } else { safe.unicodeScalars.append(scalar) }
        }
        return xml(safe)
    }
}
