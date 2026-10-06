import Foundation

/// Rich content is additive: legacy image pins retain their original/current PNGs.
/// Payloads are owned by the session; file pins contain references, never file contents.
public enum PinContentKind: String, Codable, Sendable { case text, files, color, animation }

public struct PinRichAsset: Codable, Equatable, Sendable {
    public let kind: PinContentKind
    public let filename: String
    public let byteCount: Int64
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public static let maximumDocumentBytes = 1_048_576
    public static let maximumAnimationBytes = 16_777_216
    public static let maximumFramePixels = 4_000_000
    public static let maximumFrames = 300
    public static let maximumTotalFramePixels = 120_000_000
    public init(kind: PinContentKind, filename: String, byteCount: Int64, width: Int = 0, height: Int = 0, frameCount: Int = 0) {
        self.kind = kind; self.filename = filename; self.byteCount = byteCount
        self.width = width; self.height = height; self.frameCount = frameCount
    }
    public static func isSafeFilename(_ name: String) -> Bool {
        let suffix = name.hasSuffix(".pinjson") ? ".pinjson" : name.hasSuffix(".gif") ? ".gif" : name.hasSuffix(".webp") ? ".webp" : ""
        guard !suffix.isEmpty else { return false }
        let stem = String(name.dropLast(suffix.count))
        return stem.count == 36 && UUID(uuidString: stem)?.uuidString.lowercased() == stem.lowercased()
    }
    public var isValid: Bool {
        guard Self.isSafeFilename(filename), byteCount > 0 else { return false }
        if kind != .animation {
            return filename.hasSuffix(".pinjson") && byteCount <= Int64(Self.maximumDocumentBytes) && width == 0 && height == 0 && frameCount == 0
        }
        guard filename.hasSuffix(".gif") || filename.hasSuffix(".webp"), byteCount <= Int64(Self.maximumAnimationBytes),
              width > 0, height > 0, height <= Self.maximumFramePixels, width <= Self.maximumFramePixels / height,
              frameCount >= 2, frameCount <= Self.maximumFrames else { return false }
        return width * height <= Self.maximumTotalFramePixels / frameCount
    }
    /// Two-frame working allowance; the player never keeps a decoded frame array.
    public var workingPixelCount: Int64 { kind == .animation && isValid ? Int64(width * height) * 2 : 0 }
}

public struct PinTextRun: Codable, Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false) {
        self.text = text; self.bold = bold; self.italic = italic; self.code = code
    }
}
public struct PinTextContent: Codable, Equatable, Sendable {
    public static let maximumUTF8Bytes = 262_144
    public static let maximumRuns = 4_096
    public var runs: [PinTextRun]
    public var importedHTML: Bool
    public init(runs: [PinTextRun], importedHTML: Bool = false) { self.runs = runs; self.importedHTML = importedHTML }
    public init(text: String) { self.init(runs: [PinTextRun(text: text)]) }
    public var plainText: String { runs.map(\.text).joined() }
    public var isValid: Bool {
        !runs.isEmpty && runs.count <= Self.maximumRuns &&
            runs.reduce(0, { $0 + $1.text.utf8.count }) <= Self.maximumUTF8Bytes && !plainText.isEmpty
    }
}

public struct PinFileReference: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public init(path: String, name: String, isDirectory: Bool) { self.path = path; self.name = name; self.isDirectory = isDirectory }
    public var isValid: Bool {
        path.hasPrefix("/") && path.utf8.count <= 4_096 && !path.contains("\0") &&
            !name.isEmpty && name.utf8.count <= 1_024 && !name.contains("\0")
    }
}

public struct PinRGBColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public var hex: String {
        String(format: alpha == 255 ? "#%02X%02X%02X" : "#%02X%02X%02X%02X", Int(red), Int(green), Int(blue), Int(alpha))
    }
    public var rgb: String {
        alpha == 255 ? "rgb(\(red), \(green), \(blue))" : String(format: "rgba(%d, %d, %d, %.3f)", Int(red), Int(green), Int(blue), Double(alpha) / 255)
    }
    public static func parse(_ input: String) -> PinRGBColor? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            let digits = String(value.dropFirst())
            guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
            guard let number = UInt32(expanded, radix: 16) else { return nil }
            let hasAlpha = expanded.count == 8
            return PinRGBColor(red: UInt8((number >> (hasAlpha ? 24 : 16)) & 255), green: UInt8((number >> (hasAlpha ? 16 : 8)) & 255),
                               blue: UInt8((number >> (hasAlpha ? 8 : 0)) & 255), alpha: hasAlpha ? UInt8(number & 255) : 255)
        }
        let lower = value.lowercased()
        let rgba = lower.hasPrefix("rgba(")
        guard rgba || lower.hasPrefix("rgb("), lower.hasSuffix(")") else { return nil }
        let parts = lower.dropFirst(rgba ? 5 : 4).dropLast().split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (rgba ? 4 : 3), let red = UInt8(parts[0]), let green = UInt8(parts[1]), let blue = UInt8(parts[2]) else { return nil }
        var alpha: UInt8 = 255
        if rgba { guard let number = Double(parts[3]), number.isFinite, (0...1).contains(number) else { return nil }; alpha = UInt8((number * 255).rounded()) }
        return PinRGBColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

public struct PinRichDocument: Codable, Equatable, Sendable {
    public var kind: PinContentKind
    public var text: PinTextContent?
    public var files: [PinFileReference]?
    public var color: PinRGBColor?
    public init(text: PinTextContent) { kind = .text; self.text = text }
    public init(files: [PinFileReference]) { kind = .files; self.files = files }
    public init(color: PinRGBColor) { kind = .color; self.color = color }
    public var isValid: Bool {
        switch kind {
        case .text: return text?.isValid == true && files == nil && color == nil
        case .files: return text == nil && color == nil && files.map { !$0.isEmpty && $0.count <= 64 && $0.allSatisfy(\.isValid) } == true
        case .color: return text == nil && files == nil && color != nil
        case .animation: return false
        }
    }
}

/// Deliberately small offline HTML reader. No WebKit, URL resolution, CSS, scripts,
/// attachments, entity DTDs, or network-capable document importer is invoked.
public enum PinOfflineHTML {
    public static func parse(_ html: String) -> PinTextContent? {
        guard !html.isEmpty, html.utf8.count <= PinTextContent.maximumUTF8Bytes else { return nil }
        var runs: [PinTextRun] = []
        var bold = 0, italic = 0, code = 0
        var suppressed: [String] = []
        let blocked: Set<String> = ["script", "style", "iframe", "object", "embed", "svg", "math", "head", "template"]
        var outputBytes = 0, exceededLimit = false
        func append(_ value: String) {
            guard !value.isEmpty else { return }
            guard outputBytes + value.utf8.count <= PinTextContent.maximumUTF8Bytes,
                  runs.count < PinTextContent.maximumRuns else { exceededLimit = true; return }
            outputBytes += value.utf8.count
            let run = PinTextRun(text: value, bold: bold > 0, italic: italic > 0, code: code > 0)
            if let last = runs.last, last.bold == run.bold, last.italic == run.italic, last.code == run.code {
                runs[runs.count - 1].text += value
            } else { runs.append(run) }
        }
        var position = html.startIndex
        while position < html.endIndex {
            if html[position] != "<" {
                let end = html[position...].firstIndex(of: "<") ?? html.endIndex
                if suppressed.isEmpty { append(decodeEntities(String(html[position..<end]))) }
                position = end; continue
            }
            guard let end = html[position...].firstIndex(of: ">") else {
                if suppressed.isEmpty { append(String(html[position...])) }; break
            }
            let raw = html[html.index(after: position)..<end].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            position = html.index(after: end)
            let closing = raw.hasPrefix("/")
            let name = String((closing ? raw.dropFirst() : raw[...]).prefix { $0.isASCII && ($0.isLetter || $0.isNumber) })
            if blocked.contains(name) {
                if closing { if let last = suppressed.lastIndex(of: name) { suppressed.removeSubrange(last...) } }
                else if !raw.hasSuffix("/") { if suppressed.count < 32 { suppressed.append(name) } }
                continue
            }
            guard suppressed.isEmpty else { continue }
            let delta = closing ? -1 : 1
            switch name {
            case "b", "strong": bold = max(0, min(32, bold + delta))
            case "i", "em": italic = max(0, min(32, italic + delta))
            case "code", "pre": code = max(0, min(32, code + delta)); if name == "pre" { append("\n") }
            case "br", "p", "div", "tr", "h1", "h2", "h3", "h4", "blockquote": append("\n")
            case "li": append(closing ? "\n" : "\n• ")
            case "td", "th": if closing { append("\t") }
            default: break
            }
        }
        let result = PinTextContent(runs: runs, importedHTML: true)
        return !exceededLimit && result.isValid ? result : nil
    }
    private static func decodeEntities(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var output = "", cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "&", let end = text[cursor...].prefix(14).firstIndex(of: ";") {
                let entity = String(text[text.index(after: cursor)..<end])
                var replacement = named[entity]
                if entity.hasPrefix("#") {
                    let hex = entity.lowercased().hasPrefix("#x")
                    if let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(number), number != 0 {
                        replacement = String(scalar)
                    }
                }
                if let replacement { output += replacement; cursor = text.index(after: end); continue }
            }
            output.append(text[cursor]); cursor = text.index(after: cursor)
        }
        return output
    }
}
