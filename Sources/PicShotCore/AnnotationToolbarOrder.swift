import Foundation

/// Presentation-only preference. IDs are independent of annotation document
/// serialization, and a valid order always contains every primary family once.
public struct AnnotationToolbarOrder: Equatable, Codable, Sendable {
    public enum Family: String, CaseIterable, Codable, Sendable {
        // Preserve the compact toolbar's original order for new installations.
        case rectangle, ellipse, freehand, arrow, text, number, pixelate
        case redact, eraser, spotlight, line, highlighter, select, crop
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case unknownID(String)
        case duplicateID(String)
        case missingIDs([String])
        public var errorDescription: String? {
            switch self {
            case .unknownID(let id): return "未知标注工具：\(id)"
            case .duplicateID(let id): return "标注工具重复：\(id)"
            case .missingIDs(let ids): return "缺少标注工具：" + ids.joined(separator: "、")
            }
        }
    }

    public static let preferenceKey = "annotationToolbarOrder"
    public static let defaults = AnnotationToolbarOrder(validatedFamilies: Family.allCases)
    public private(set) var families: [Family]
    public var rawIDs: [String] { families.map(\.rawValue) }

    private init(validatedFamilies: [Family]) { families = validatedFamilies }

    public init(rawIDs: [String]) throws {
        var seen = Set<Family>(), result: [Family] = []
        for id in rawIDs {
            guard let family = Family(rawValue: id) else { throw ValidationError.unknownID(id) }
            guard seen.insert(family).inserted else { throw ValidationError.duplicateID(id) }
            result.append(family)
        }
        let missing = Family.allCases.filter { !seen.contains($0) }
        guard missing.isEmpty else { throw ValidationError.missingIDs(missing.map(\.rawValue)) }
        families = result
    }

    public init(families: [Family]) throws { try self.init(rawIDs: families.map(\.rawValue)) }

    /// Local malformed/obsolete preferences fall back atomically; they are not
    /// partially repaired or written back. Import uses the throwing initializer.
    public static func read(from defaults: UserDefaults) -> Self {
        guard let values = defaults.object(forKey: preferenceKey) as? [String],
              let order = try? Self(rawIDs: values) else { return .defaults }
        return order
    }

    public func write(to defaults: UserDefaults) { defaults.set(rawIDs, forKey: Self.preferenceKey) }

    /// Moving a selected family changes only its position. An invalid move is a
    /// no-op, including offsets large enough to overflow an integer addition.
    @discardableResult
    public mutating func move(_ family: Family, by offset: Int) -> Bool {
        guard let source = families.firstIndex(of: family) else { return false }
        let (destination, overflow) = source.addingReportingOverflow(offset)
        guard !overflow, families.indices.contains(destination), destination != source else { return false }
        families.remove(at: source); families.insert(family, at: destination)
        return true
    }

    /// Keep the accepted default toolbar's compact visibility. A custom order
    /// gives earlier families priority, hiding whole groups from the right.
    public var overflowPriority: [Family] {
        guard self == .defaults else { return Array(families.reversed()) }
        let original: [Family] = [.ellipse, .line, .highlighter, .select, .crop, .spotlight, .eraser]
        return original + families.reversed().filter { !original.contains($0) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawIDs: container.decode([String].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawIDs)
    }
}
