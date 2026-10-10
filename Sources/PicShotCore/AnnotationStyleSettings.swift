import Foundation

/// Appearance preferences only. This format never contains an annotation or document.
/// Keep this explicit allowlist independent from annotation/archive Codable models.
public struct AnnotationStyleSettings: Equatable, Codable, Sendable {
    public static let preferenceKey = "annotationStyles.v1"
    public static let maximumEncodedBytes = 32 * 1_024
    public static let defaults = AnnotationStyleSettings()
    public static let version = 1

    public enum Tool: String, CaseIterable, Codable, Sendable {
        case rectangle, ellipse, arrow, line, freehand, text, number, highlighter
        case redact, blur, pixelate, eraser, spotlight, watermark, magnifier, arc, sector, polyline
        public var title: String {
            switch self {
            case .rectangle: return "矩形"
            case .ellipse: return "椭圆"
            case .arrow: return "箭头"
            case .line: return "直线"
            case .freehand: return "画笔"
            case .text: return "文字"
            case .number: return "序号"
            case .highlighter: return "高亮"
            case .redact: return "遮盖"
            case .blur: return "模糊"
            case .pixelate: return "马赛克"
            case .eraser: return "橡皮擦"
            case .spotlight: return "聚光灯"
            case .watermark: return "水印"
            case .magnifier: return "放大镜"
            case .arc: return "圆弧"
            case .sector: return "扇形"
            case .polyline: return "折线"
            }
        }

        /// Geometry, content, sequence counters, source regions and links are excluded.
        public var allowedFields: Set<Field> {
            let stroke: Set<Field> = [.color, .lineWidth, .opacity, .strokeStyle]
            let fill: Set<Field> = [.fillEnabled, .fillColor]
            let font: Set<Field> = [.fontName, .fontSize, .bold, .italic, .underline]
            let outline: Set<Field> = [.textOutlineEnabled, .textOutlineColor, .textOutlineWidth]
            let pencil: Set<Field> = [.freehandSmoothing, .freehandConstraint]
            switch self {
            case .rectangle: return stroke.union(fill).union([.cornerRadius])
            case .ellipse, .sector: return stroke.union(fill)
            case .arc: return stroke
            case .arrow, .line, .polyline:
                return stroke.union([.lineCap, .lineJoin, .startArrowEnabled, .endArrowEnabled, .startArrowhead, .endArrowhead])
            case .freehand: return stroke.union(pencil)
            case .text: return font.union(outline).union(fill).union([.color, .opacity, .cornerRadius])
            case .number: return [.color, .lineWidth, .opacity, .numberStyle, .fontSize]
            case .highlighter: return pencil.union([.color, .lineWidth, .opacity, .highlighterMode, .highlighterBlend])
            // New redactions always use solid opaque black. Saving a selected
            // redaction must never weaken the existing creation policy.
            case .redact: return []
            case .blur, .pixelate: return [.lineWidth, .opacity]
            case .eraser: return [.lineWidth, .eraserMode]
            case .spotlight: return [.color, .lineWidth, .spotlightShape, .spotlightDim, .spotlightBorder]
            case .watermark: return font.union(outline).union([.color, .opacity, .watermarkPlacement, .watermarkSpacing])
            case .magnifier: return [.color, .lineWidth, .magnifierScale, .magnifierShape, .magnifierConnector,
                                     .magnifierSmooth, .magnifierShowsAnnotations, .magnifierShadow]
            }
        }
    }

    public enum Field: String, CaseIterable, Sendable {
        case color, lineWidth, opacity, strokeStyle, lineCap, lineJoin
        case startArrowEnabled, endArrowEnabled, startArrowhead, endArrowhead
        case fillEnabled, fillColor, cornerRadius, fontName, fontSize, bold, italic, underline
        case textOutlineEnabled, textOutlineColor, textOutlineWidth, numberStyle
        case eraserMode, spotlightShape, spotlightDim, spotlightBorder
        case watermarkPlacement, watermarkSpacing, magnifierScale, magnifierShape, magnifierConnector
        case magnifierSmooth, magnifierShowsAnnotations, magnifierShadow
        case freehandSmoothing, freehandConstraint, highlighterMode, highlighterBlend
        public var title: String {
            switch self {
            case .color: return "颜色"
            case .lineWidth: return "线宽"
            case .opacity: return "不透明度"
            case .strokeStyle: return "线型"
            case .lineCap: return "端点"
            case .lineJoin: return "连接"
            case .startArrowEnabled: return "起点箭头"
            case .endArrowEnabled: return "终点箭头"
            case .startArrowhead: return "起点形状"
            case .endArrowhead: return "终点形状"
            case .fillEnabled: return "填充"
            case .fillColor: return "填充色"
            case .cornerRadius: return "圆角"
            case .fontName: return "字体"
            case .fontSize: return "字号"
            case .bold: return "粗体"
            case .italic: return "斜体"
            case .underline: return "下划线"
            case .textOutlineEnabled: return "文字描边"
            case .textOutlineColor: return "描边色"
            case .textOutlineWidth: return "描边宽度"
            case .numberStyle: return "序号格式"
            case .eraserMode: return "橡皮模式"
            case .spotlightShape: return "聚光形状"
            case .spotlightDim: return "外部暗度"
            case .spotlightBorder: return "聚光边框"
            case .watermarkPlacement: return "水印位置"
            case .watermarkSpacing: return "水印间距"
            case .magnifierScale: return "放大倍数"
            case .magnifierShape: return "放大镜形状"
            case .magnifierConnector: return "连接线"
            case .magnifierSmooth: return "平滑像素"
            case .magnifierShowsAnnotations: return "包含标注"
            case .magnifierShadow: return "阴影"
            case .freehandSmoothing: return "平滑笔迹"
            case .freehandConstraint: return "直线吸附角度"
            case .highlighterMode: return "高亮形状"
            case .highlighterBlend: return "高亮混合"
            }
        }
    }

    /// Only fixed-size colors, finite numbers, flags and small enumerated strings.
    public enum Value: Equatable, Codable, Sendable {
        case number(Double), flag(Bool), choice(String), color(red: Double, green: Double, blue: Double, alpha: Double)

        public init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) { self = .flag(flag); return }
            if let number = try? single.decode(Double.self), number.isFinite { self = .number(number); return }
            if let choice = try? single.decode(String.self), choice.utf8.count <= 32 { self = .choice(choice); return }
            var array = try decoder.unkeyedContainer()
            if let count = array.count, count != 4 { throw ValidationError.invalidValue }
            let red = try array.decode(Double.self), green = try array.decode(Double.self)
            let blue = try array.decode(Double.self), alpha = try array.decode(Double.self)
            guard array.isAtEnd, [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ValidationError.invalidValue
            }
            self = .color(red: red, green: green, blue: blue, alpha: alpha)
        }
        public func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .number(let value): try single.encode(value)
            case .flag(let value): try single.encode(value)
            case .choice(let value): try single.encode(value)
            case .color(let red, let green, let blue, let alpha): try single.encode([red, green, blue, alpha])
            }
        }
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidVersion, invalidKeys, invalidValue, invalidToolFields, duplicateTool, tooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidVersion: return "标注样式版本不受支持"
            case .invalidKeys: return "标注样式包含未知字段"
            case .invalidValue: return "标注样式数值或选项无效"
            case .invalidToolFields: return "标注样式包含不适用于此工具的字段"
            case .duplicateTool: return "同一工具只能保存一个默认样式"
            case .tooLarge: return "标注样式设置超出大小限制"
            }
        }
    }

    public struct Style: Equatable, Codable, Sendable {
        public let tool: Tool
        public let values: [Field: Value]
        public var summary: String {
            let fields = Field.allCases.compactMap { field -> String? in
                guard let value = values[field] else { return nil }
                let text: String
                switch value {
                case .flag(let flag): text = flag ? "开" : "关"
                case .number(let number): text = String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), number)
                case .color(let r, let g, let b, let a):
                    text = String(format: "#%02X%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), Int((a * 255).rounded()))
                case .choice(let choice):
                    let titles = ["solid": "实线", "dashed": "虚线", "dotted": "点线", "round": "圆", "butt": "平端", "square": "方端",
                                  "miter": "尖角", "bevel": "斜角", "open": "开放", "filledTriangle": "实心三角", "outlineTriangle": "空心三角",
                                  "diamond": "菱形", "circle": "圆点", "Helvetica": "无衬线", "TimesNewRomanPSMT": "衬线", "Menlo-Regular": "等宽",
                                  "decimal": "数字", "alphabetic": "字母", "roman": "罗马数字", "brush": "画笔", "rectangle": "矩形", "ellipse": "椭圆",
                                  "tiled": "平铺", "bottomRight": "右下", "bottomLeft": "左下", "topRight": "右上", "topLeft": "左上", "topCenter": "上中",
                                  "bottomCenter": "下中", "center": "居中", "line": "线段", "edges": "边框连线", "none": "无", "freehand": "画笔",
                                  "translucent": "半透明", "multiply": "正片叠底"]
                    text = titles[choice] ?? choice
                }
                return field.title + " " + text
            }
            return tool.title + "：" + (fields.isEmpty ? (tool == .redact ? "原始外观（不透明黑色）" : "原始外观") : fields.joined(separator: "，"))
        }
        public init(tool: Tool, values: [Field: Value]) throws {
            guard Set(values.keys).isSubset(of: tool.allowedFields) else { throw ValidationError.invalidToolFields }
            for (field, value) in values { guard Self.valid(value, field: field, tool: tool) else { throw ValidationError.invalidValue } }
            self.tool = tool; self.values = values
        }
        private static func valid(_ value: Value, field: Field, tool: Tool) -> Bool {
            switch (field, value) {
            case (.color, .color(let r, let g, let b, let a)), (.fillColor, .color(let r, let g, let b, let a)),
                 (.textOutlineColor, .color(let r, let g, let b, let a)):
                return [r, g, b, a].allSatisfy { $0.isFinite && (0...1).contains($0) }
            case (.fillEnabled, .flag), (.bold, .flag), (.italic, .flag), (.underline, .flag),
                 (.startArrowEnabled, .flag), (.endArrowEnabled, .flag), (.textOutlineEnabled, .flag),
                 (.spotlightBorder, .flag), (.magnifierSmooth, .flag), (.magnifierShowsAnnotations, .flag),
                 (.magnifierShadow, .flag), (.freehandSmoothing, .flag): return true
            case (.lineWidth, .number(let n)):
                let range: ClosedRange<Double> = tool == .number ? 3.5...20 : tool == .eraser ? 4...256 :
                    [.freehand, .highlighter].contains(tool) ? 1...256 : 1...64
                return n.isFinite && range.contains(n)
            case (.opacity, .number(let n)): return n.isFinite && (0.05...1).contains(n)
            case (.cornerRadius, .number(let n)): return n.isFinite && (0...500).contains(n)
            case (.fontSize, .number(let n)): return n.isFinite && (8...(tool == .number ? 72 : 300)).contains(n)
            case (.textOutlineWidth, .number(let n)): return n.isFinite && (0.5...8).contains(n)
            case (.spotlightDim, .number(let n)): return n.isFinite && (0...1).contains(n)
            case (.watermarkSpacing, .number(let n)): return n.isFinite && (0...1_000).contains(n)
            case (.magnifierScale, .number(let n)): return n.isFinite && (1...8).contains(n)
            case (.freehandConstraint, .number(let n)): return [0, 5, 10, 15, 30, 45].contains(n)
            case (.strokeStyle, .choice(let s)): return ["solid", "dashed", "dotted"].contains(s)
            case (.lineCap, .choice(let s)): return ["round", "butt", "square"].contains(s)
            case (.lineJoin, .choice(let s)): return ["round", "miter", "bevel"].contains(s)
            case (.startArrowhead, .choice(let s)), (.endArrowhead, .choice(let s)):
                return ["open", "filledTriangle", "outlineTriangle", "diamond", "circle"].contains(s)
            case (.fontName, .choice(let s)): return ["Helvetica", "TimesNewRomanPSMT", "Menlo-Regular"].contains(s)
            case (.numberStyle, .choice(let s)): return ["decimal", "alphabetic", "roman"].contains(s)
            case (.eraserMode, .choice(let s)): return ["brush", "rectangle"].contains(s)
            case (.spotlightShape, .choice(let s)), (.magnifierShape, .choice(let s)): return ["rectangle", "ellipse"].contains(s)
            case (.watermarkPlacement, .choice(let s)):
                return ["tiled", "bottomRight", "bottomLeft", "topRight", "topLeft", "topCenter", "bottomCenter", "center"].contains(s)
            case (.magnifierConnector, .choice(let s)): return ["line", "dotted", "edges", "none"].contains(s)
            case (.highlighterMode, .choice(let s)): return ["rectangle", "freehand"].contains(s)
            case (.highlighterBlend, .choice(let s)): return ["translucent", "multiply"].contains(s)
            default: return false
            }
        }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            try Self.requireKeys(container, ["tool", "values"])
            let tool = try container.decode(Tool.self, forKey: Key("tool"))
            let fields = try container.nestedContainer(keyedBy: Key.self, forKey: Key("values"))
            guard fields.allKeys.count <= tool.allowedFields.count else { throw ValidationError.invalidToolFields }
            var values: [Field: Value] = [:]
            for key in fields.allKeys {
                guard let field = Field(rawValue: key.stringValue), tool.allowedFields.contains(field) else { throw ValidationError.invalidKeys }
                values[field] = try fields.decode(Value.self, forKey: key)
            }
            try self.init(tool: tool, values: values)
        }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(tool, forKey: Key("tool"))
            var fields = container.nestedContainer(keyedBy: Key.self, forKey: Key("values"))
            for (field, value) in values { try fields.encode(value, forKey: Key(field.rawValue)) }
        }
        private static func requireKeys(_ container: KeyedDecodingContainer<Key>, _ expected: Set<String>) throws {
            guard Set(container.allKeys.map(\.stringValue)) == expected else { throw ValidationError.invalidKeys }
        }
    }

    public private(set) var styles: [Style]
    public var summary: String { styles.isEmpty ? "原始默认样式" : styles.map { $0.tool.title }.joined(separator: "、") }
    public init() { styles = [] }
    public init(styles: [Style]) throws {
        guard styles.count <= Tool.allCases.count else { throw ValidationError.tooLarge }
        guard Set(styles.map(\.tool)).count == styles.count else { throw ValidationError.duplicateTool }
        self.styles = Tool.allCases.compactMap { tool in styles.first { $0.tool == tool } }
    }
    public func style(for tool: Tool) -> Style? { styles.first { $0.tool == tool } }
    public mutating func save(_ style: Style) {
        styles.removeAll { $0.tool == style.tool }; styles.append(style)
        styles = Tool.allCases.compactMap { tool in styles.first { $0.tool == tool } }
    }
    public mutating func reset(_ tool: Tool) { styles.removeAll { $0.tool == tool } }

    /// Both local preference ingestion and portable-config ingestion validate before use.
    /// Local invalid data fails atomically to original defaults, without rewriting it.
    public static func read(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: preferenceKey), let result = try? decode(data) else { return .defaults }
        return result
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw ValidationError.tooLarge }
        var guardrail = AnnotationStyleJSONGuard(data: data); try guardrail.validate()
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw ValidationError.tooLarge }
        return data
    }
    public func write(to defaults: UserDefaults) throws {
        let data = try encoded()
        if styles.isEmpty { defaults.removeObject(forKey: Self.preferenceKey) }
        else { defaults.set(data, forKey: Self.preferenceKey) }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["version", "styles"] else { throw ValidationError.invalidKeys }
        guard try container.decode(Int.self, forKey: Key("version")) == Self.version else { throw ValidationError.invalidVersion }
        var array = try container.nestedUnkeyedContainer(forKey: Key("styles"))
        if let count = array.count, count > Tool.allCases.count { throw ValidationError.tooLarge }
        var styles: [Style] = []
        while !array.isAtEnd {
            guard styles.count < Tool.allCases.count else { throw ValidationError.tooLarge }
            styles.append(try array.decode(Style.self))
        }
        try self.init(styles: styles)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Self.version, forKey: Key("version")); try container.encode(styles, forKey: Key("styles"))
    }
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}

/// JSONDecoder accepts duplicate object keys. Preferences use the same strict
/// contract as portable import: reject duplicates, excessive nesting and tokens
/// before decoding. Input bytes are bounded before this scanner is constructed.
private struct AnnotationStyleJSONGuard {
    private let bytes: [UInt8]
    private var position = 0
    init(data: Data) { bytes = Array(data) }
    mutating func validate() throws {
        try value(depth: 0); whitespace()
        guard position == bytes.count else { throw AnnotationStyleSettings.ValidationError.invalidValue }
    }
    private mutating func whitespace() {
        while position < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[position]) { position += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1; return true
    }
    private mutating func string() throws -> String {
        whitespace()
        guard position < bytes.count, bytes[position] == 34 else { throw AnnotationStyleSettings.ValidationError.invalidValue }
        let start = position; position += 1
        while position < bytes.count {
            guard position - start <= 256 else { throw AnnotationStyleSettings.ValidationError.tooLarge }
            let byte = bytes[position]; position += 1
            if byte == 34 {
                let string = try JSONDecoder().decode(String.self, from: Data(bytes[start..<position]))
                guard string.utf8.count <= 32 else { throw AnnotationStyleSettings.ValidationError.tooLarge }
                return string
            }
            if byte == 92 { guard position < bytes.count else { throw AnnotationStyleSettings.ValidationError.invalidValue }; position += 1 }
        }
        throw AnnotationStyleSettings.ValidationError.invalidValue
    }
    private mutating func value(depth: Int) throws {
        guard depth <= 6 else { throw AnnotationStyleSettings.ValidationError.tooLarge }
        whitespace()
        guard position < bytes.count else { throw AnnotationStyleSettings.ValidationError.invalidValue }
        switch bytes[position] {
        case 123:
            position += 1
            var keys = Set<String>()
            if take(125) { return }
            repeat {
                let key = try string()
                guard keys.count < AnnotationStyleSettings.Field.allCases.count,
                      keys.insert(key).inserted, take(58) else { throw AnnotationStyleSettings.ValidationError.invalidKeys }
                try value(depth: depth + 1)
                if take(125) { return }
                guard take(44) else { throw AnnotationStyleSettings.ValidationError.invalidValue }
            } while true
        case 91:
            position += 1; var count = 0
            if take(93) { return }
            repeat {
                guard count < AnnotationStyleSettings.Tool.allCases.count else { throw AnnotationStyleSettings.ValidationError.tooLarge }
                count += 1; try value(depth: depth + 1)
                if take(93) { return }
                guard take(44) else { throw AnnotationStyleSettings.ValidationError.invalidValue }
            } while true
        case 34: _ = try string()
        default:
            let start = position
            while position < bytes.count, ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[position]) {
                position += 1
                guard position - start <= 64 else { throw AnnotationStyleSettings.ValidationError.tooLarge }
            }
            guard position > start else { throw AnnotationStyleSettings.ValidationError.invalidValue }
        }
    }
}
