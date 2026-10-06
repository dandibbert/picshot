import Foundation
import CoreGraphics

/// A deliberately small, bounded SVG outline reader, not an HTML/SVG document loader.
/// MathJax's pinned TeX glyphs use these path commands. Arcs/URLs/fonts are never loaded.
public enum FormulaRenderSVGPath {
    public static func parse(_ source: String, segmentBudget: inout Int) throws -> CGPath {
        guard source.utf8.count <= 100_000 else { throw FormulaRenderError.invalidOutput }
        var scanner = Scanner(bytes: Array(source.utf8))
        let path = CGMutablePath()
        var command: UInt8 = 0, previous: UInt8 = 0
        var current = CGPoint.zero, start = CGPoint.zero
        var quadratic: CGPoint?, cubic: CGPoint?
        while !scanner.atEnd {
            if let letter = scanner.command() { command = letter }
            guard command != 0, segmentBudget > 0 else { throw FormulaRenderError.invalidOutput }
            segmentBudget -= 1
            let lower = command | 32
            let relative = command >= 97
            let origin = relative ? current : .zero
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x + origin.x, y: y + origin.y) }
            switch lower {
            case 109: // M; following pairs implicitly become L.
                current = try point(scanner.number(), scanner.number())
                path.move(to: current); start = current; command = relative ? 108 : 76
            case 108:
                current = try point(scanner.number(), scanner.number()); path.addLine(to: current)
            case 104:
                current.x = try scanner.number() + origin.x; path.addLine(to: current)
            case 118:
                current.y = try scanner.number() + origin.y; path.addLine(to: current)
            case 113:
                let control = try point(scanner.number(), scanner.number())
                current = try point(scanner.number(), scanner.number())
                path.addQuadCurve(to: current, control: control); quadratic = control
            case 116:
                let control: CGPoint
                if (previous == 113 || previous == 116), let quadratic {
                    control = CGPoint(x: 2 * current.x - quadratic.x, y: 2 * current.y - quadratic.y)
                } else { control = current }
                current = try point(scanner.number(), scanner.number())
                path.addQuadCurve(to: current, control: control); quadratic = control
            case 99:
                let first = try point(scanner.number(), scanner.number())
                let second = try point(scanner.number(), scanner.number())
                current = try point(scanner.number(), scanner.number())
                path.addCurve(to: current, control1: first, control2: second); cubic = second
            case 115:
                let first: CGPoint
                if (previous == 99 || previous == 115), let cubic {
                    first = CGPoint(x: 2 * current.x - cubic.x, y: 2 * current.y - cubic.y)
                } else { first = current }
                let second = try point(scanner.number(), scanner.number())
                current = try point(scanner.number(), scanner.number())
                path.addCurve(to: current, control1: first, control2: second); cubic = second
            case 122:
                path.closeSubpath(); current = start; command = 0
            default: throw FormulaRenderError.unsupported("不支持的 SVG 轮廓命令")
            }
            if lower != 113 && lower != 116 { quadratic = nil }
            if lower != 99 && lower != 115 { cubic = nil }
            previous = lower
        }
        guard !path.isEmpty else { throw FormulaRenderError.invalidOutput }
        return path
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        mutating func skip() {
            while index < bytes.count && [9, 10, 13, 32, 44].contains(bytes[index]) { index += 1 }
        }
        var atEnd: Bool { mutating get { skip(); return index == bytes.count } }
        mutating func command() -> UInt8? {
            skip(); guard index < bytes.count else { return nil }
            let byte = bytes[index]
            guard (65...90).contains(byte) || (97...122).contains(byte) else { return nil }
            index += 1; return byte
        }
        mutating func number() throws -> Double {
            skip(); let start = index
            if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            var digits = 0
            while index < bytes.count && (48...57).contains(bytes[index]) { digits += 1; index += 1 }
            if index < bytes.count && bytes[index] == 46 {
                index += 1
                while index < bytes.count && (48...57).contains(bytes[index]) { digits += 1; index += 1 }
            }
            guard digits > 0 else { throw FormulaRenderError.invalidOutput }
            if index < bytes.count && (bytes[index] == 69 || bytes[index] == 101) {
                index += 1
                if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
                let exponentStart = index
                while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
                guard index > exponentStart else { throw FormulaRenderError.invalidOutput }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)),
                  value.isFinite, abs(value) <= 1_000_000 else { throw FormulaRenderError.invalidOutput }
            return value
        }
    }
}
