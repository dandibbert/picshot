import Foundation
import CoreGraphics

/// All points use Vision's normalized, bottom-left-origin coordinates in the oriented raster.
/// Accurate Vision OCR supplies word precision. We never fabricate character widths.
struct RecognizedTextQuad: Sendable, Equatable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    init?(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (-0.01...1.01).contains($0.x) && (-0.01...1.01).contains($0.y) }) else { return nil }
        func clipped(_ p: CGPoint) -> CGPoint { CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y))) }
        self.topLeft = clipped(topLeft); self.topRight = clipped(topRight)
        self.bottomRight = clipped(bottomRight); self.bottomLeft = clipped(bottomLeft)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let clippedPoints = self.points
        let doubledArea = clippedPoints.indices.reduce(CGFloat.zero) { sum, index in
            let a = clippedPoints[index], b = clippedPoints[(index + 1) % clippedPoints.count]
            return sum + a.x * b.y - b.x * a.y
        }
        guard abs(doubledArea) > 0.0000000001 else { return nil }
    }

    init?(rect: CGRect) {
        self.init(topLeft: CGPoint(x: rect.minX, y: rect.maxY), topRight: CGPoint(x: rect.maxX, y: rect.maxY),
                  bottomRight: CGPoint(x: rect.maxX, y: rect.minY), bottomLeft: CGPoint(x: rect.minX, y: rect.minY))
    }

    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
    var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }
    func points(in imageRect: CGRect) -> [CGPoint] {
        points.map { CGPoint(x: imageRect.minX + $0.x * imageRect.width, y: imageRect.minY + $0.y * imageRect.height) }
    }
    func contains(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        let vertices = points
        var positive = false, negative = false
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            positive = positive || cross > 0.00000001; negative = negative || cross < -0.00000001
        }
        return !(positive && negative)
    }
    func approximatelyEquals(_ other: Self) -> Bool {
        zip(points, other.points).allSatisfy { abs($0.0.x - $0.1.x) < 0.00005 && abs($0.0.y - $0.1.y) < 0.00005 }
    }
}

struct RecognizedTextUnit: Sendable, Equatable {
    /// Exact UTF-16 range in the document, never an estimated offset from pixel width.
    var range: NSRange
    let quad: RecognizedTextQuad
    let lineIndex: Int
}
struct RecognizedTextLine: Sendable, Equatable {
    let range: NSRange
    let quad: RecognizedTextQuad
}

struct RecognizedTextDocument: Sendable, Equatable {
    static let maximumLines = 512
    static let maximumUTF16Count = 32_768
    static let maximumUnits = 8_192
    let text: String
    let lines: [RecognizedTextLine]
    let units: [RecognizedTextUnit]
    let isTruncated: Bool
    /// Composed-character boundaries make keyboard selection safe for emoji, CJK and combining marks.
    let boundaries: [Int]

    init(text: String, lines: [RecognizedTextLine], units: [RecognizedTextUnit], isTruncated: Bool = false) {
        var bounded = "", offsets = [0], count = 0
        for character in text {
            let part = String(character), length = part.utf16.count
            guard count + length <= Self.maximumUTF16Count else { break }
            bounded += part; count += length; offsets.append(count)
        }
        self.text = bounded; boundaries = offsets
        let validOffsets = Set(offsets)
        func valid(_ range: NSRange) -> Bool {
            range.location >= 0 && range.length > 0 && range.location <= count && range.length <= count - range.location &&
                validOffsets.contains(range.location) && validOffsets.contains(NSMaxRange(range))
        }
        var boundedLines: [RecognizedTextLine] = [], lineMap: [Int: Int] = [:]
        for (index, line) in lines.prefix(Self.maximumLines).enumerated() where valid(line.range) {
            lineMap[index] = boundedLines.count; boundedLines.append(line)
        }
        self.lines = boundedLines
        // Preserve logical text order, independent of the baseline direction of each quad.
        self.units = units.prefix(Self.maximumUnits).compactMap { unit in
            guard valid(unit.range), let mapped = lineMap[unit.lineIndex] else { return nil }
            return RecognizedTextUnit(range: unit.range, quad: unit.quad, lineIndex: mapped)
        }.sorted { $0.range.location < $1.range.location }
        self.isTruncated = isTruncated || bounded != text || lines.count > Self.maximumLines || units.count > Self.maximumUnits
    }

    func substring(_ range: NSRange) -> String {
        guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location, let indices = Range(range, in: text) else { return "" }
        return String(text[indices])
    }
    func selection(from first: Int, through last: Int) -> NSRange? {
        guard units.indices.contains(first), units.indices.contains(last) else { return nil }
        let start = min(units[first].range.location, units[last].range.location)
        let end = max(NSMaxRange(units[first].range), NSMaxRange(units[last].range))
        return NSRange(location: start, length: end - start)
    }
    func unit(at point: CGPoint) -> Int? {
        // Prefer the smallest true polygon when OCR produces nested/overlapping boxes.
        units.indices.filter { units[$0].quad.contains(point) }.min {
            units[$0].quad.bounds.width * units[$0].quad.bounds.height < units[$1].quad.bounds.width * units[$1].quad.bounds.height
        }
    }
    func nearestUnit(to point: CGPoint, imageSize: CGSize) -> Int? {
        if let hit = unit(at: point) { return hit }
        // Pixel-space distance avoids bias on very wide or tall screenshots.
        return units.indices.min { distance(point, to: units[$0].quad.bounds, imageSize: imageSize) < distance(point, to: units[$1].quad.bounds, imageSize: imageSize) }
    }
    private func distance(_ point: CGPoint, to rect: CGRect, imageSize: CGSize) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX) * imageSize.width
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY) * imageSize.height
        return dx * dx + dy * dy
    }
    func boundary(before offset: Int) -> Int { boundaries.last(where: { $0 < offset }) ?? 0 }
    func boundary(after offset: Int) -> Int { boundaries.first(where: { $0 > offset }) ?? text.utf16.count }
}
