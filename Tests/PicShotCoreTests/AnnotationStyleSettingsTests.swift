import XCTest
import Foundation
@testable import PicShotCore

final class AnnotationStyleSettingsTests: XCTestCase {
    private typealias Settings = AnnotationStyleSettings
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PicShot-AnnotationStyles-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
    private func decode(_ json: String) throws -> Settings { try Settings.decode(Data(json.utf8)) }
    private func style(_ tool: Settings.Tool, _ values: [Settings.Field: Settings.Value]) throws -> Settings.Style {
        try .init(tool: tool, values: values)
    }

    func testUnsetDefaultsAreEmptyAndReadingDoesNotWrite() throws {
        try withDefaults { defaults in
            XCTAssertEqual(Settings.read(from: defaults), .defaults)
            XCTAssertNil(defaults.object(forKey: Settings.preferenceKey))
            XCTAssertEqual(try Settings.defaults.encoded(), Data(#"{"styles":[],"version":1}"#.utf8))
            XCTAssertEqual(Settings.defaults.summary, "原始默认样式")
        }
    }

    func testSaveReadReplaceResetIsBoundedAndExactToolOnly() throws {
        try withDefaults { defaults in
            let arrow = try style(.arrow, [.lineWidth: .number(10), .endArrowEnabled: .flag(false)])
            let line = try style(.line, [.lineWidth: .number(3)])
            var settings = Settings(); settings.save(arrow); settings.save(line)
            try settings.write(to: defaults)
            XCTAssertEqual(Settings.read(from: defaults), settings)
            XCTAssertEqual(settings.style(for: .arrow), arrow)
            XCTAssertNil(settings.style(for: .polyline))
            let replacement = try style(.arrow, [.lineWidth: .number(12)])
            for _ in 0..<100 { settings.save(replacement) }
            XCTAssertEqual(settings.styles.count, 2)
            settings.reset(.arrow); try settings.write(to: defaults)
            XCTAssertNil(Settings.read(from: defaults).style(for: .arrow))
            XCTAssertEqual(Settings.read(from: defaults).style(for: .line), line)
            settings.reset(.line); try settings.write(to: defaults)
            XCTAssertNil(defaults.object(forKey: Settings.preferenceKey))
        }
    }

    func testAllToolsHaveOneSlotAndStableEncodingRegardlessOfInsertionOrder() throws {
        let entries = try Settings.Tool.allCases.map { try style($0, [:]) }
        let a = try Settings(styles: entries), b = try Settings(styles: Array(entries.reversed()))
        XCTAssertEqual(a.styles.count, 18)
        XCTAssertEqual(try a.encoded(), try b.encoded())
        XCTAssertEqual(try Settings.decode(a.encoded()), a)
        XCTAssertThrowsError(try Settings(styles: entries + [entries[0]]))
        XCTAssertThrowsError(try Settings(styles: [entries[0], entries[0]]))
        XCTAssertNil(Settings.Tool(rawValue: "select")); XCTAssertNil(Settings.Tool(rawValue: "crop"))
    }

    func testAppearanceAllowlistRejectsContentGeometryAndCrossToolFields() throws {
        let forbidden = ["id", "points", "text", "number", "numberComment", "numberCommentSize", "rotation", "textBoxSize",
                         "watermarkTemplate", "frozenTimestamp", "frozenTimeZoneIdentifier", "timestampIsCaptureDate",
                         "magnifierSource", "mosaicLink", "crop", "freehandCorners", "freehandWasSimplified", "arcStartAngle", "arcSweepAngle"]
        for key in forbidden {
            XCTAssertNil(Settings.Field(rawValue: key))
            XCTAssertThrowsError(try decode("{\"version\":1,\"styles\":[{\"tool\":\"text\",\"values\":{\"\(key)\":\"PRIVATE_CONTENT\"}}]}"), key)
        }
        XCTAssertThrowsError(try style(.arrow, [.fontSize: .number(24)]))
        XCTAssertThrowsError(try style(.watermark, [.fillEnabled: .flag(true)]))
        XCTAssertThrowsError(try style(.redact, [.opacity: .number(0.5)]))
        XCTAssertThrowsError(try style(.redact, [.color: .color(red: 1, green: 0, blue: 0, alpha: 0)]))
        XCTAssertThrowsError(try style(.spotlight, [.opacity: .number(0.5)]))
        XCTAssertThrowsError(try style(.magnifier, [.opacity: .number(0.5)]))
        XCTAssertEqual(Settings.Tool.redact.allowedFields, [])
    }

    func testRejectsMalformedKeysTypesVersionDuplicateKeysAndUnboundedPayloads() throws {
        let invalid = [
            "null", "[]", "{}", #"{"version":2,"styles":[]}"#,
            #"{"version":true,"styles":[]}"#, #"{"version":1,"styles":[],"text":"private"}"#,
            #"{"version":1,"styles":[{"tool":"select","values":{}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{},"text":"private"}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"lineWidth":"4"}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"lineWidth":true}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"lineWidth":null}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"endArrowEnabled":1}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"color":[1,0,0]}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"color":[1,0,0,1,1]}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"color":{"r":1,"g":0,"b":0,"a":1}}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"strokeStyle":"unknown"}}]}"#,
            #"{"version":1,"styles":[{"tool":"text","values":{"fontName":"PRIVATE_MESSAGE"}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{}},{"tool":"arrow","values":{}}]}"#,
            #"{"version":1,"styles":[],"version":1}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"lineWidth":4,"lineWidth":5}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"lineWidth":4,"line\u0057idth":5}}]}"#,
            #"{"version":1,"styles":[{"tool":"arrow","values":{"color":[[[[[[[[1]]]]]]]]}}]}"#,
            "{\"version\":1,\"styles\":[{\"tool\":\"text\",\"values\":{\"fontName\":\"" + String(repeating: "x", count: 10_000) + "\"}}]}"
        ]
        for json in invalid { XCTAssertThrowsError(try decode(json), String(json.prefix(180))) }
        let tooMany = #"{"version":1,"styles":["# + Array(repeating: #"{"tool":"arrow","values":{}}"#, count: 19).joined(separator: ",") + "]}"
        XCTAssertThrowsError(try decode(tooMany))
        XCTAssertThrowsError(try Settings.decode(Data(repeating: 32, count: Settings.maximumEncodedBytes + 1)))
    }

    func testUnknownAndCorruptPreferencesFailClosedWithoutRewritingData() throws {
        try withDefaults { defaults in
            let invalid: [Any] = ["wrong type", Data("invalid".utf8), Data(#"{"version":99,"styles":[]}"#.utf8), Data(repeating: 32, count: Settings.maximumEncodedBytes + 1)]
            for value in invalid {
                defaults.set(value, forKey: Settings.preferenceKey)
                let before = defaults.object(forKey: Settings.preferenceKey) as? NSObject
                XCTAssertEqual(Settings.read(from: defaults), .defaults)
                XCTAssertEqual(defaults.object(forKey: Settings.preferenceKey) as? NSObject, before)
            }
        }
    }

    func testNumericBoundsAndEnumsMatchToolDomainsAndRejectNonfiniteValues() throws {
        for n in [Double.nan, .infinity, -.infinity, -1, 0, 65] { XCTAssertThrowsError(try style(.arrow, [.lineWidth: .number(n)])) }
        for n in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertThrowsError(try style(.text, [.color: .color(red: n, green: 0, blue: 0, alpha: 1)]))
        }
        XCTAssertNoThrow(try style(.freehand, [.lineWidth: .number(256), .freehandConstraint: .number(45)]))
        XCTAssertThrowsError(try style(.freehand, [.lineWidth: .number(257)]))
        XCTAssertThrowsError(try style(.freehand, [.freehandConstraint: .number(22)]))
        XCTAssertThrowsError(try style(.number, [.lineWidth: .number(3), .fontSize: .number(300)]))
        XCTAssertNoThrow(try style(.number, [.lineWidth: .number(3.5), .fontSize: .number(72), .numberStyle: .choice("roman")]))
        XCTAssertThrowsError(try style(.magnifier, [.magnifierScale: .number(9)]))
        XCTAssertThrowsError(try style(.text, [.textOutlineWidth: .number(0)]))
        XCTAssertThrowsError(try style(.watermark, [.watermarkSpacing: .number(1_001)]))
    }

    func testSummaryDistinguishesSameToolAppearanceWithoutRawUntrustedContent() throws {
        let red = try style(.arrow, [.lineWidth: .number(4), .color: .color(red: 1, green: 0, blue: 0, alpha: 1)])
        let blue = try style(.arrow, [.lineWidth: .number(12), .color: .color(red: 0, green: 0, blue: 1, alpha: 0.5)])
        XCTAssertNotEqual(red.summary, blue.summary)
        XCTAssertTrue(red.summary.contains("箭头")); XCTAssertTrue(red.summary.contains("颜色 #FF0000FF"))
        XCTAssertTrue(blue.summary.contains("#0000FF80")); XCTAssertTrue(blue.summary.contains("线宽 12"))
    }
}
