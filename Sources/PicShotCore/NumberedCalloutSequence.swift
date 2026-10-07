import Foundation

/// Document-local numbering. There is deliberately no preference or global counter.
/// All three display modes share the same bounded, positive integer domain.
public enum NumberedCalloutStyle: String, CaseIterable, Sendable {
    case decimal, alphabetic, roman

    public var title: String {
        switch self { case .decimal: return "1, 2, 3"; case .alphabetic: return "A, B, C"; case .roman: return "I, II, III" }
    }

    public func label(for value: Int) -> String {
        var remaining = NumberedCalloutSequence.clamp(value)
        switch self {
        case .decimal: return String(remaining)
        case .alphabetic:
            var result = ""
            repeat {
                remaining -= 1
                result = String(UnicodeScalar(65 + remaining % 26)!) + result
                remaining /= 26
            } while remaining > 0
            return result
        case .roman:
            var result = ""
            for (number, symbol) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
                (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"),
                (5, "V"), (4, "IV"), (1, "I")] {
                while remaining >= number { result += symbol; remaining -= number }
            }
            return result
        }
    }
}

public struct NumberedCalloutSequence: Equatable, Sendable {
    public static let maximumValue = 3_999
    public static let maximumMarks = 512
    public static let maximumCommentUTF16 = 2_048
    public private(set) var nextValue = 1
    public private(set) var isExhausted = false
    public var closesGapsOnDelete = false
    public init() {}

    public static func clamp(_ value: Int) -> Int { min(maximumValue, max(1, value)) }
    public mutating func setNext(_ value: Int) { nextValue = Self.clamp(value); isExhausted = false }
    public mutating func didInsert(_ value: Int) {
        let value = Self.clamp(value)
        nextValue = min(Self.maximumValue, value + 1)
        isExhausted = value == Self.maximumValue
    }
    public mutating func didDelete(_ value: Int) {
        guard closesGapsOnDelete else { return }
        let value = Self.clamp(value)
        if isExhausted { isExhausted = false }
        else if nextValue > value { nextValue -= 1 }
    }

    /// Bounds the UTF-16 payload without splitting a Unicode scalar, including emoji.
    /// The scan itself is bounded even for adversarial combining-character input.
    public static func boundedComment(_ text: String) -> String {
        var result = String.UnicodeScalarView(), count = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            guard count + width <= maximumCommentUTF16 else { break }
            result.append(scalar); count += width
        }
        return String(result)
    }
}
