import Foundation

/// A zero-based address. A covered address resolves to its merged cell's anchor.
public struct TableCoordinate: Codable, Hashable, Sendable {
    public var row: Int
    public var column: Int
    public init(row: Int, column: Int) { self.row = row; self.column = column }
    public var spreadsheetReference: String { "\(Self.columnName(column))\(row + 1)" }
    public static func columnName(_ index: Int) -> String {
        guard index >= 0, index < Int.max else { return "?" }
        var n = index + 1, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
}

/// Inclusive bounds, deliberately not silently normalized by init. Mutations validate them.
public struct TableRange: Codable, Equatable, Sendable {
    public var firstRow: Int
    public var firstColumn: Int
    public var lastRow: Int
    public var lastColumn: Int
    public init(firstRow: Int, firstColumn: Int, lastRow: Int, lastColumn: Int) {
        self.firstRow = firstRow; self.firstColumn = firstColumn
        self.lastRow = lastRow; self.lastColumn = lastColumn
    }
    public init(_ a: TableCoordinate, _ b: TableCoordinate) {
        self.init(firstRow: min(a.row, b.row), firstColumn: min(a.column, b.column),
                  lastRow: max(a.row, b.row), lastColumn: max(a.column, b.column))
    }
    public func contains(_ address: TableCoordinate) -> Bool {
        address.row >= firstRow && address.row <= lastRow && address.column >= firstColumn && address.column <= lastColumn
    }
    public func contains(_ other: TableRange) -> Bool {
        firstRow <= other.firstRow && firstColumn <= other.firstColumn && lastRow >= other.lastRow && lastColumn >= other.lastColumn
    }
    public func intersects(_ other: TableRange) -> Bool {
        firstRow <= other.lastRow && lastRow >= other.firstRow && firstColumn <= other.lastColumn && lastColumn >= other.firstColumn
    }
    public var spreadsheetReference: String {
        let a = TableCoordinate(row: firstRow, column: firstColumn).spreadsheetReference
        let b = TableCoordinate(row: lastRow, column: lastColumn).spreadsheetReference
        return a == b ? a : "\(a):\(b)"
    }
}

/// Text is never interpreted as a formula, even if it starts with '='.
public enum TableCellValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    public var displayText: String {
        switch self {
        case .text(let text): return text
        case .number(let number): return String(number)
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        }
    }
}

public enum TableCellAlignment: String, Codable, CaseIterable, Hashable, Sendable { case left, center, right }
public enum TableCellFill: String, Codable, CaseIterable, Hashable, Sendable {
    case none, yellow, blue, green, gray
    public var rgbHex: String? {
        switch self {
        case .none: return nil
        case .yellow: return "FFF2CC"
        case .blue: return "DDEBF7"
        case .green: return "E2F0D9"
        case .gray: return "E7E6E6"
        }
    }
}
public struct TableCellStyle: Codable, Hashable, Sendable {
    public var bold: Bool
    public var italic: Bool
    public var alignment: TableCellAlignment
    public var fill: TableCellFill
    public init(bold: Bool = false, italic: Bool = false, alignment: TableCellAlignment = .left, fill: TableCellFill = .none) {
        self.bold = bold; self.italic = italic; self.alignment = alignment; self.fill = fill
    }
}

/// Only anchors are stored. IDs survive insertion, deletion and moving an anchor.
public struct TableCell: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public var value: TableCellValue
    public var style: TableCellStyle
    public init(id: UUID = UUID(), row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1,
                value: TableCellValue = .text(""), style: TableCellStyle = TableCellStyle()) {
        self.id = id; self.row = row; self.column = column; self.rowSpan = rowSpan; self.columnSpan = columnSpan
        self.value = value; self.style = style
    }
    public var coordinate: TableCoordinate { TableCoordinate(row: row, column: column) }
    public var range: TableRange {
        TableRange(firstRow: row, firstColumn: column, lastRow: row + rowSpan - 1, lastColumn: column + columnSpan - 1)
    }
    public var isMerged: Bool { rowSpan > 1 || columnSpan > 1 }
}

public enum StructuredTableError: Error, LocalizedError, Equatable {
    case invalidDimensions, outOfBounds, invalidSpan, overlappingCells, duplicateCellID, partialMerge, invalidNumber, cannotDeleteLastRow, cannotDeleteLastColumn
    public var errorDescription: String? {
        switch self {
        case .invalidDimensions: return "表格大小无效：最多 10,000 行、256 列及 250,000 个位置。"
        case .outOfBounds: return "所选单元格超出表格范围。"
        case .invalidSpan: return "合并单元格的行列跨度无效。"
        case .overlappingCells: return "单元格跨度重叠。"
        case .duplicateCellID: return "单元格标识重复。"
        case .partialMerge: return "选择范围只包含了部分合并单元格。请扩大选择或先拆分。"
        case .invalidNumber: return "数字必须是有效的有限数值。"
        case .cannotDeleteLastRow: return "表格至少需要保留一行。"
        case .cannotDeleteLastColumn: return "表格至少需要保留一列。"
        }
    }
}

/// A validated rectangular grid with explicit row/column spans and bounded allocation.
public struct StructuredTable: Codable, Equatable, Sendable {
    public static let maximumRows = 10_000
    public static let maximumColumns = 256
    public static let maximumPositions = 250_000
    public private(set) var rowCount: Int
    public private(set) var columnCount: Int
    public private(set) var cells: [TableCell]
    public var title: String
    private var owners: [Int]

    /// Missing positions become empty cells; malformed or overlapping supplied spans are rejected.
    public init(rowCount: Int, columnCount: Int, cells: [TableCell] = [], title: String = "表格") throws {
        guard rowCount > 0, columnCount > 0, rowCount <= Self.maximumRows,
              columnCount <= Self.maximumColumns, rowCount <= Self.maximumPositions / columnCount else {
            throw StructuredTableError.invalidDimensions
        }
        self.rowCount = rowCount; self.columnCount = columnCount; self.title = title
        self.cells = cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        owners = Array(repeating: -1, count: rowCount * columnCount)
        var ids = Set<UUID>()
        for (index, cell) in self.cells.enumerated() {
            guard cell.row >= 0, cell.column >= 0, cell.row < rowCount, cell.column < columnCount,
                  cell.rowSpan > 0, cell.columnSpan > 0,
                  cell.rowSpan <= rowCount - cell.row, cell.columnSpan <= columnCount - cell.column else { throw StructuredTableError.invalidSpan }
            guard ids.insert(cell.id).inserted else { throw StructuredTableError.duplicateCellID }
            try Self.validate(cell.value)
            for r in cell.row..<(cell.row + cell.rowSpan) {
                for c in cell.column..<(cell.column + cell.columnSpan) {
                    let slot = r * columnCount + c
                    guard owners[slot] == -1 else { throw StructuredTableError.overlappingCells }
                    owners[slot] = index
                }
            }
        }
        for r in 0..<rowCount {
            for c in 0..<columnCount where owners[r * columnCount + c] == -1 {
                owners[r * columnCount + c] = self.cells.count
                self.cells.append(TableCell(row: r, column: c))
            }
        }
        // Keep stable row-major ordering for consumers, rebuilding the inexpensive lookup once.
        self.cells.sort { ($0.row, $0.column) < ($1.row, $1.column) }
        for (i, cell) in self.cells.enumerated() {
            for r in cell.row..<(cell.row + cell.rowSpan) {
                for c in cell.column..<(cell.column + cell.columnSpan) { owners[r * columnCount + c] = i }
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case rowCount, columnCount, cells, title }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(rowCount: values.decode(Int.self, forKey: .rowCount), columnCount: values.decode(Int.self, forKey: .columnCount),
                      cells: values.decode([TableCell].self, forKey: .cells), title: values.decode(String.self, forKey: .title))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rowCount, forKey: .rowCount); try values.encode(columnCount, forKey: .columnCount)
        try values.encode(cells, forKey: .cells); try values.encode(title, forKey: .title)
    }
    public func cell(at address: TableCoordinate) -> TableCell? {
        guard address.row >= 0, address.column >= 0, address.row < rowCount, address.column < columnCount else { return nil }
        return cells[owners[address.row * columnCount + address.column]]
    }
    public func cell(id: UUID) -> TableCell? { cells.first { $0.id == id } }
    public var fullRange: TableRange { TableRange(firstRow: 0, firstColumn: 0, lastRow: rowCount - 1, lastColumn: columnCount - 1) }
    public func validate(_ range: TableRange) throws {
        guard range.firstRow >= 0, range.firstColumn >= 0, range.lastRow >= range.firstRow,
              range.lastColumn >= range.firstColumn, range.lastRow < rowCount, range.lastColumn < columnCount else { throw StructuredTableError.outOfBounds }
    }
    public mutating func setValue(_ value: TableCellValue, at address: TableCoordinate) throws {
        guard cell(at: address) != nil else { throw StructuredTableError.outOfBounds }
        try Self.validate(value)
        cells[owners[address.row * columnCount + address.column]].value = value
    }
    public mutating func setStyle(_ style: TableCellStyle, in range: TableRange) throws {
        try validate(range)
        for i in cells.indices where range.intersects(cells[i].range) { cells[i].style = style }
    }
    /// Expand a selection to include the entire span of every intersecting merged cell.
    public func expandedRange(_ range: TableRange) throws -> TableRange {
        try validate(range)
        var result = range, changed = true
        while changed {
            changed = false
            for cell in cells where cell.isMerged && result.intersects(cell.range) && !result.contains(cell.range) {
                result = TableRange(firstRow: min(result.firstRow, cell.row), firstColumn: min(result.firstColumn, cell.column),
                                    lastRow: max(result.lastRow, cell.range.lastRow), lastColumn: max(result.lastColumn, cell.range.lastColumn))
                changed = true
            }
        }
        return result
    }
    /// Keep the top-left ID/style; retain all nonempty values in row-major order, separated by newlines.
    @discardableResult public mutating func merge(_ range: TableRange) throws -> TableCell {
        try validate(range)
        let selected = cells.filter { range.intersects($0.range) }
        guard selected.allSatisfy({ range.contains($0.range) }) else { throw StructuredTableError.partialMerge }
        guard var merged = cell(at: TableCoordinate(row: range.firstRow, column: range.firstColumn)) else { throw StructuredTableError.outOfBounds }
        if selected.count == 1 { return merged }
        merged.rowSpan = range.lastRow - range.firstRow + 1; merged.columnSpan = range.lastColumn - range.firstColumn + 1
        let nonempty = selected.filter { !$0.value.displayText.isEmpty }
        if nonempty.count == 1 { merged.value = nonempty[0].value }
        else { merged.value = .text(nonempty.map { $0.value.displayText }.joined(separator: "\n")) }
        try replace(rows: rowCount, columns: columnCount, cells: cells.filter { !range.intersects($0.range) } + [merged])
        return merged
    }
    /// The original value/ID stays at the top-left; newly uncovered cells are empty with the same style.
    public mutating func split(at address: TableCoordinate) throws {
        guard var anchor = cell(at: address) else { throw StructuredTableError.outOfBounds }
        guard anchor.isMerged else { return }
        let original = anchor
        anchor.rowSpan = 1; anchor.columnSpan = 1
        var replacement = cells.filter { $0.id != original.id } + [anchor]
        for r in original.row..<(original.row + original.rowSpan) {
            for c in original.column..<(original.column + original.columnSpan) where r != original.row || c != original.column {
                replacement.append(TableCell(row: r, column: c, style: original.style))
            }
        }
        try replace(rows: rowCount, columns: columnCount, cells: replacement)
    }
    /// Inserting through a span expands it; insertion before its anchor moves it intact.
    public mutating func insertRow(at index: Int) throws {
        guard index >= 0, index <= rowCount else { throw StructuredTableError.outOfBounds }
        var result = cells
        for i in result.indices {
            if result[i].row >= index { result[i].row += 1 }
            else if result[i].row + result[i].rowSpan > index { result[i].rowSpan += 1 }
        }
        try replace(rows: rowCount + 1, columns: columnCount, cells: result)
    }
    public mutating func insertColumn(at index: Int) throws {
        guard index >= 0, index <= columnCount else { throw StructuredTableError.outOfBounds }
        var result = cells
        for i in result.indices {
            if result[i].column >= index { result[i].column += 1 }
            else if result[i].column + result[i].columnSpan > index { result[i].columnSpan += 1 }
        }
        try replace(rows: rowCount, columns: columnCount + 1, cells: result)
    }
    /// Deleting an anchor row of a multirow cell keeps its ID/value at the surviving top-left.
    public mutating func deleteRow(at index: Int) throws {
        guard index >= 0, index < rowCount else { throw StructuredTableError.outOfBounds }
        guard rowCount > 1 else { throw StructuredTableError.cannotDeleteLastRow }
        var result: [TableCell] = []
        for var cell in cells {
            if cell.row > index { cell.row -= 1 }
            else if cell.row + cell.rowSpan > index {
                if cell.rowSpan == 1 { continue }; cell.rowSpan -= 1
            }
            result.append(cell)
        }
        try replace(rows: rowCount - 1, columns: columnCount, cells: result)
    }
    public mutating func deleteColumn(at index: Int) throws {
        guard index >= 0, index < columnCount else { throw StructuredTableError.outOfBounds }
        guard columnCount > 1 else { throw StructuredTableError.cannotDeleteLastColumn }
        var result: [TableCell] = []
        for var cell in cells {
            if cell.column > index { cell.column -= 1 }
            else if cell.column + cell.columnSpan > index {
                if cell.columnSpan == 1 { continue }; cell.columnSpan -= 1
            }
            result.append(cell)
        }
        try replace(rows: rowCount, columns: columnCount - 1, cells: result)
    }
    /// TSV represents covered positions as empty. Spreadsheet-safe text prefixes dangerous inputs
    /// with an apostrophe before quoting; XLSX retains original text without this transport prefix.
    public func tsv(in range: TableRange? = nil, spreadsheetSafe: Bool = true) throws -> String {
        let range = range ?? fullRange
        try validate(range)
        return (range.firstRow...range.lastRow).map { row in
            (range.firstColumn...range.lastColumn).map { column -> String in
                guard let cell = cell(at: TableCoordinate(row: row, column: column)), cell.row == row, cell.column == column else { return "" }
                var text = cell.value.displayText
                if spreadsheetSafe, case .text = cell.value,
                   let first = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)).first, "=+-@".contains(first) { text = "'" + text }
                if text.contains("\t") || text.contains("\n") || text.contains("\r") || text.contains("\"") {
                    text = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return text
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
    private static func validate(_ value: TableCellValue) throws {
        if case .number(let n) = value, !n.isFinite { throw StructuredTableError.invalidNumber }
    }
    private mutating func replace(rows: Int, columns: Int, cells: [TableCell]) throws {
        self = try StructuredTable(rowCount: rows, columnCount: columns, cells: cells, title: title)
    }
}
