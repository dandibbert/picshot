// Structure placement and IoU/distance ordering adapted from RapidAI/RapidTable.
// Copyright (c) 2022 PaddlePaddle Authors. All Rights Reserved.
// Licensed under Apache-2.0. See docs/TABLE_MODEL.md.
// Modified for PicShot: reject malformed spans/holes and preserve uncertain OCR separately.
import Foundation
import PicShotCore

struct SLANetParsedTable {
    var rows: Int
    var columns: Int
    var cells: [TableCell]
}

extension SLANetPlus {
    static func parse(_ tokens: [String]) throws -> SLANetParsedTable {
        var row = 0, column = 0, columns = 0, inRow = false
        var section: String?, sawBody = false, sawHead = false
        var occupied = Set<TableCoordinate>(), cells: [TableCell] = []
        var index = 0
        func malformed(_ reason: String) -> TableRecognitionError { .unsupportedStructure(reason) }
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "<thead>", "<tbody>":
                guard !inRow, section == nil else { throw malformed("nested section") }
                if token == "<thead>" {
                    guard !sawHead, !sawBody else { throw malformed("out-of-order header") }; sawHead = true
                } else {
                    guard !sawBody else { throw malformed("duplicate body") }; sawBody = true
                }
                section = token
            case "</thead>", "</tbody>":
                guard !inRow, section == token.replacingOccurrences(of: "/", with: "") else { throw malformed("unbalanced section") }
                section = nil
            case "<tr>":
                guard !inRow, row < StructuredTable.maximumRows else { throw malformed("nested or excessive rows") }
                inRow = true; column = 0
            case "</tr>":
                guard inRow else { throw malformed("unexpected row end") }
                inRow = false; row += 1
            case "<td></td>", "<td":
                guard inRow else { throw malformed("cell outside row") }
                var rowSpan = 1, columnSpan = 1
                var foundRowSpan = false, foundColumnSpan = false
                if token == "<td" {
                    index += 1
                    while index < tokens.count, tokens[index] != ">" {
                        let attribute = tokens[index]
                        if attribute.hasPrefix(" rowspan=\""), !foundRowSpan,
                           let span = Int(attribute.dropFirst(10).dropLast()), (2...20).contains(span) {
                            rowSpan = span; foundRowSpan = true
                        } else if attribute.hasPrefix(" colspan=\""), !foundColumnSpan,
                                  let span = Int(attribute.dropFirst(10).dropLast()), (2...20).contains(span) {
                            columnSpan = span; foundColumnSpan = true
                        } else { throw malformed("invalid or duplicate cell span") }
                        index += 1
                    }
                    guard index + 1 < tokens.count, tokens[index] == ">", tokens[index + 1] == "</td>" else {
                        throw malformed("unclosed cell")
                    }
                    index += 1
                }
                while occupied.contains(TableCoordinate(row: row, column: column)) { column += 1 }
                guard column + columnSpan <= StructuredTable.maximumColumns,
                      row + rowSpan <= StructuredTable.maximumRows else { throw malformed("table exceeds editor limits") }
                for r in row..<(row + rowSpan) {
                    for c in column..<(column + columnSpan) {
                        guard occupied.insert(TableCoordinate(row: r, column: c)).inserted else { throw malformed("overlapping cell spans") }
                    }
                }
                cells.append(TableCell(row: row, column: column, rowSpan: rowSpan, columnSpan: columnSpan,
                                       style: TableCellStyle(bold: section == "<thead>")))
                column += columnSpan; columns = max(columns, column)
            default: throw malformed("unsupported token \(token)")
            }
            index += 1
        }
        guard !inRow, section == nil, row > 0, columns > 0, !cells.isEmpty else { throw malformed("incomplete table") }
        guard row <= StructuredTable.maximumPositions / columns,
              cells.allSatisfy({ $0.row + $0.rowSpan <= row }), occupied.count == row * columns else {
            throw malformed("incomplete rectangular grid or span beyond final row")
        }
        return SLANetParsedTable(rows: row, columns: columns, cells: cells)
    }

    static func match(parsed: SLANetParsedTable, boxes: [TableOCRBox], cellScores: [Double],
                      confidence: Double, ocr: [TableOCRObservation]) throws -> TableRecognitionResult {
        var assigned = [[TableOCRObservation]](repeating: [], count: boxes.count)
        var unmatched: [TableOCRObservation] = []
        for observation in ocr {
            guard !observation.text.isEmpty, observation.box.isValid, observation.confidence.isFinite,
                  observation.confidence >= 0.30, observation.confidence <= 1 else {
                unmatched.append(observation); continue
            }
            // Upstream maximizes IoU then minimizes corner distance. Require a majority of the
            // OCR box inside the cell as an additional safeguard against cross-cell text lines.
            let candidates = boxes.indices.compactMap { index -> (Int, Double, Double)? in
                let overlap = boxes[index].intersectionArea(observation.box)
                guard overlap / observation.box.area >= 0.50 else { return nil }
                return (index, boxes[index].iou(observation.box), boxes[index].distance(observation.box))
            }.sorted { a, b in a.1 == b.1 ? a.2 < b.2 : a.1 > b.1 }
            guard let best = candidates.first, best.1 > 0 else { unmatched.append(observation); continue }
            if candidates.count > 1, candidates[1].1 >= best.1 * 0.95 {
                unmatched.append(observation); continue
            }
            assigned[best.0].append(observation)
        }
        var cells = parsed.cells, evidence: [RecognizedTableCell] = []
        for index in cells.indices {
            cells[index].value = .text(readingOrderText(assigned[index]))
            evidence.append(RecognizedTableCell(coordinate: cells[index].coordinate, box: boxes[index],
                                                structureConfidence: cellScores[index],
                                                ocrConfidence: assigned[index].map(\.confidence).min()))
        }
        var warnings: [String] = ["合并单元格、行列数量与文字请人工核对，模型置信度不代表正确。"]
        if confidence < 0.85 { warnings.append("表格结构置信度较低，请检查合并单元格。") }
        if cellScores.contains(where: { $0 < 0.60 }) { warnings.append("部分单元格结构不确定，请检查行列跨度。") }
        if !unmatched.isEmpty { warnings.append("\(unmatched.count) 段文字无法可靠匹配单元格，已保留供人工核对。") }
        if assigned.allSatisfy(\.isEmpty) { warnings.append("已识别结构，但没有可靠匹配的文字。请核对原图。") }
        if assigned.joined().contains(where: { $0.confidence < 0.80 }) { warnings.append("部分文字识别置信度较低，请核对原图。") }
        let table = try StructuredTable(rowCount: parsed.rows, columnCount: parsed.columns, cells: cells, title: "识别的表格")
        return TableRecognitionResult(table: table, structureConfidence: confidence, cells: evidence,
                                      unmatchedOCR: unmatched, warnings: warnings)
    }

    static func readingOrderText(_ observations: [TableOCRObservation]) -> String {
        let ordered = observations.sorted { a, b in
            a.box.midY == b.box.midY ? a.box.x < b.box.x : a.box.midY < b.box.midY
        }
        var lines: [[TableOCRObservation]] = []
        for item in ordered {
            if let index = lines.indices.last,
               let anchor = lines[index].first,
               abs(anchor.box.midY - item.box.midY) <= min(anchor.box.height, item.box.height) * 0.5 {
                lines[index].append(item)
            } else { lines.append([item]) }
        }
        return lines.map { line in
            line.sorted { $0.box.x < $1.box.x }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }
}
