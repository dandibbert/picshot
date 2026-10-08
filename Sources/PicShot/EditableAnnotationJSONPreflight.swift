import Foundation

/// A no-tree JSON pass applies byte, nesting, token, string, array and aggregate
/// point limits BEFORE JSONDecoder allocates the value model. It rejects unknown
/// or duplicate members and schema keys with escape sequences. The schema uses
/// only ASCII member names; value strings retain normal JSON Unicode escapes.
enum EditableAnnotationJSONPreflight {
    static let maximumDepth = 12
    static let maximumNodes = 600_000
    private indirect enum Shape {
        case object(String), list(Shape, Int, Int), string(Int), number, bool, optional(Shape)
        static var point: Self { .list(.number, 2, 2) }
        static var size: Self { .list(.number, 2, 2) }
        static var rect: Self { .list(.point, 2, 2) }
        var isOptional: Bool { if case .optional = self { return true }; return false }
    }
    private static let schema: [String: [String: Shape]] = [
        "document": [
            "format": .string(128), "version": .number, "coordinates": .string(128),
            "documentID": .string(64), "originalAssetID": .string(64), "baseAssetID": .string(64),
            "originalPixelWidth": .number, "originalPixelHeight": .number,
            "basePixelWidth": .number, "basePixelHeight": .number,
            "baseCropInOriginal": .optional(.rect), "cropViewportInBase": .optional(.rect),
            "baseProvenance": .string(64), "capturedAt": .number, "captureTimeZoneIdentifier": .string(768),
            "captureTimestampKnown": .bool,
            "annotations": .list(.object("annotation"), 0, 2_048),
            "numberSequence": .object("sequence"), "outputDecoration": .object("decoration")
        ],
        "annotation": [
            "id": .string(256),
            "tool": .string(256),
            "points": .list(.point, 1, 2_048),
            "color": .object("color"),
            "lineWidth": .number,
            "text": .string(98304),
            "number": .number,
            "numberStyle": .string(256),
            "numberComment": .string(12288),
            "numberCommentSize": .size,
            "rotation": .number,
            "opacity": .number,
            "strokeStyle": .string(256),
            "lineCap": .string(256),
            "lineJoin": .string(256),
            "startArrowEnabled": .bool,
            "endArrowEnabled": .optional(.bool),
            "startArrowhead": .string(256),
            "endArrowhead": .string(256),
            "fillEnabled": .bool,
            "fillColor": .object("color"),
            "cornerRadius": .number,
            "fontName": .string(1536),
            "fontSize": .optional(.number),
            "bold": .bool,
            "italic": .bool,
            "underline": .bool,
            "textOutlineEnabled": .bool,
            "textOutlineColor": .object("color"),
            "textOutlineWidth": .number,
            "textBoxSize": .optional(.size),
            "eraserMode": .string(256),
            "spotlightShape": .string(256),
            "spotlightDim": .number,
            "spotlightBorder": .bool,
            "watermarkPlacement": .string(256),
            "watermarkSpacing": .number,
            "watermarkTemplate": .string(12288),
            "frozenTimestamp": .number,
            "frozenTimeZoneIdentifier": .string(768),
            "timestampIsCaptureDate": .bool,
            "magnifierSource": .optional(.rect),
            "magnifierScale": .number,
            "magnifierShape": .string(256),
            "magnifierConnector": .string(256),
            "magnifierSmooth": .bool,
            "magnifierShowsAnnotations": .bool,
            "magnifierShadow": .bool,
            "arcStartAngle": .number,
            "arcSweepAngle": .number,
            "freehandSmoothing": .bool,
            "freehandConstraint": .number,
            "freehandCorners": .list(.number, 0, 2_048),
            "freehandWasSimplified": .bool,
            "highlighterMode": .string(256),
            "highlighterBlend": .string(256),
            "mosaicLink": .optional(.object("mosaic"))
        ],
        "color": ["space": .string(256), "components": .list(.number, 2, 4)],
        "sequence": ["nextValue": .number, "isExhausted": .bool, "closesGapsOnDelete": .bool],
        "mosaic": ["groupID": .string(64), "additionID": .string(64), "rootAdditionID": .string(64),
            "target": .rect, "includedTargets": .list(.rect, 0, 25), "excludedTargets": .list(.rect, 0, 25),
            "synchronizes": .bool],
        "decoration": ["enabled": .bool, "cornerRadius": .number, "borderEnabled": .bool,
            "borderWidth": .number, "borderColor": .object("decorationColor"), "shadowEnabled": .bool,
            "shadowBlur": .number, "shadowOffsetX": .number, "shadowOffsetY": .number, "shadowOpacity": .number],
        "decorationColor": ["red": .number, "green": .number, "blue": .number, "alpha": .number]
    ]

    static func validate(_ data: Data) throws {
        guard !data.isEmpty else { throw EditableAnnotationDocumentError.invalidJSON }
        guard data.count <= EditableAnnotationDocumentCodec.maximumFileBytes else { throw EditableAnnotationDocumentError.tooLarge }
        try data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self))
            try parser.value(.object("document"), depth: 0)
            parser.whitespace()
            guard parser.index == parser.bytes.count else { throw EditableAnnotationDocumentError.invalidJSON }
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        var nodes = 0
        var totalPoints = 0
        var totalCorners = 0
        var totalStringBytes = 0

        mutating func whitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { guard take(byte) else { throw EditableAnnotationDocumentError.invalidJSON } }
        }
        mutating func value(_ shape: Shape, depth: Int, field: String? = nil) throws {
            guard depth <= maximumDepth, nodes < maximumNodes else { throw EditableAnnotationDocumentError.tooLarge }
            nodes += 1; whitespace()
            if case .optional(let child) = shape {
                if index < bytes.count && bytes[index] == 110 { try literal("null") }
                else { try value(child, depth: depth, field: field) }
                return
            }
            switch shape {
            case .object(let kind): try object(kind, depth: depth)
            case .list(let child, let minimum, let maximum):
                guard take(91) else { throw EditableAnnotationDocumentError.invalidJSON }
                whitespace(); var count = 0
                if !take(93) {
                    repeat {
                        guard count < maximum else { throw EditableAnnotationDocumentError.tooLarge }
                        if field == "points" {
                            totalPoints += 1
                            guard totalPoints <= EditableAnnotationDocumentCodec.maximumTotalPoints else {
                                throw EditableAnnotationDocumentError.tooLarge
                            }
                        }
                        if field == "freehandCorners" {
                            totalCorners += 1
                            guard totalCorners <= EditableAnnotationDocumentCodec.maximumTotalPoints else {
                                throw EditableAnnotationDocumentError.tooLarge
                            }
                        }
                        try value(child, depth: depth + 1); count += 1; whitespace()
                        if take(93) { break }
                        guard take(44) else { throw EditableAnnotationDocumentError.invalidJSON }
                    } while true
                }
                guard count >= minimum else { throw EditableAnnotationDocumentError.invalidJSON }
            case .string(let maximum): _ = try string(maximum: maximum, isKey: false)
            case .number: try number()
            case .bool:
                if index < bytes.count && bytes[index] == 116 { try literal("true") }
                else { try literal("false") }
            case .optional: break
            }
        }

        mutating func object(_ kind: String, depth: Int) throws {
            guard take(123), let fields = schema[kind] else { throw EditableAnnotationDocumentError.invalidJSON }
            var seen = Set<String>()
            whitespace()
            if !take(125) {
                repeat {
                    whitespace()
                    let range = try string(maximum: 64, isKey: true)
                    let key = String(decoding: bytes[range], as: UTF8.self)
                    guard let shape = fields[key], seen.insert(key).inserted else {
                        throw EditableAnnotationDocumentError.invalidDocument
                    }
                    whitespace(); guard take(58) else { throw EditableAnnotationDocumentError.invalidJSON }
                    whitespace(); let start = index
                    try value(shape, depth: depth + 1, field: key)
                    if kind == "document", key == "version" {
                        guard String(decoding: bytes[start..<index], as: UTF8.self) == "1" else {
                            throw EditableAnnotationDocumentError.unsupportedVersion
                        }
                    }
                    whitespace(); if take(125) { break }
                    guard take(44) else { throw EditableAnnotationDocumentError.invalidJSON }
                } while true
            }
            guard fields.allSatisfy({ seen.contains($0.key) || $0.value.isOptional }) else {
                throw EditableAnnotationDocumentError.invalidDocument
            }
        }

        mutating func string(maximum: Int, isKey: Bool) throws -> Range<Int> {
            guard take(34) else { throw EditableAnnotationDocumentError.invalidJSON }
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 34 {
                    let result = start..<index; index += 1
                    totalStringBytes += result.count
                    guard totalStringBytes <= 4 * 1_024 * 1_024 else { throw EditableAnnotationDocumentError.tooLarge }
                    return result
                }
                guard index - start < maximum else { throw EditableAnnotationDocumentError.tooLarge }
                guard byte >= 32 else { throw EditableAnnotationDocumentError.invalidJSON }
                index += 1
                if byte == 92 {
                    guard !isKey, index < bytes.count else { throw EditableAnnotationDocumentError.invalidJSON }
                    let escaped = bytes[index]; index += 1
                    if escaped == 117 {
                        let scalar = try unicodeEscape()
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard take(92), take(117), (0xDC00...0xDFFF).contains(try unicodeEscape()) else {
                                throw EditableAnnotationDocumentError.invalidJSON
                            }
                        } else if (0xDC00...0xDFFF).contains(scalar) { throw EditableAnnotationDocumentError.invalidJSON }
                    } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escaped) {
                        throw EditableAnnotationDocumentError.invalidJSON
                    }
                } else if isKey && !(byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte >= 48 && byte <= 57) {
                    throw EditableAnnotationDocumentError.invalidJSON
                } else if byte >= 128 { try utf8Continuation(after: byte) }
                guard index - start <= maximum else { throw EditableAnnotationDocumentError.tooLarge }
            }
            throw EditableAnnotationDocumentError.invalidJSON
        }

        mutating func unicodeEscape() throws -> UInt16 {
            var result: UInt16 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw EditableAnnotationDocumentError.invalidJSON }
                let hex = bytes[index]; index += 1
                let digit: UInt16
                switch hex {
                case 48...57: digit = UInt16(hex - 48)
                case 65...70: digit = UInt16(hex - 65 + 10)
                case 97...102: digit = UInt16(hex - 97 + 10)
                default: throw EditableAnnotationDocumentError.invalidJSON
                }
                result = result * 16 + digit
            }
            return result
        }

        mutating func utf8Continuation(after lead: UInt8) throws {
            let count: Int
            switch lead {
            case 0xC2...0xDF: count = 1
            case 0xE0...0xEF: count = 2
            case 0xF0...0xF4: count = 3
            default: throw EditableAnnotationDocumentError.invalidJSON
            }
            for offset in 0..<count {
                guard index < bytes.count else { throw EditableAnnotationDocumentError.invalidJSON }
                let next = bytes[index]; index += 1
                guard (0x80...0xBF).contains(next),
                      !(offset == 0 && ((lead == 0xE0 && next < 0xA0) || (lead == 0xED && next > 0x9F) ||
                                       (lead == 0xF0 && next < 0x90) || (lead == 0xF4 && next > 0x8F))) else {
                    throw EditableAnnotationDocumentError.invalidJSON
                }
            }
        }

        mutating func number() throws {
            let start = index
            _ = take(45)
            if !take(48) {
                guard index < bytes.count, (49...57).contains(bytes[index]) else { throw EditableAnnotationDocumentError.invalidJSON }
                repeat { index += 1 } while index < bytes.count && (48...57).contains(bytes[index]) && index - start <= 64
            }
            if take(46) {
                let fraction = index
                while index < bytes.count && (48...57).contains(bytes[index]) && index - start <= 64 { index += 1 }
                guard index > fraction else { throw EditableAnnotationDocumentError.invalidJSON }
            }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                let exponent = index
                while index < bytes.count && (48...57).contains(bytes[index]) && index - start <= 64 { index += 1 }
                guard index > exponent else { throw EditableAnnotationDocumentError.invalidJSON }
            }
            guard index - start <= 64 else { throw EditableAnnotationDocumentError.tooLarge }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
                throw EditableAnnotationDocumentError.invalidDocument
            }
        }
    }
}
