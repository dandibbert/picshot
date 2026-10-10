import AppKit
import XCTest
@testable import PicShot

final class LocalAnnotationShortcutTests: XCTestCase {
    func testDefaultsPreserveAllPreviouslyUnassignedToolKeys() throws {
        let defaults = LocalAnnotationShortcutSettings.defaults
        XCTAssertEqual(defaults.schemaVersion, 1); XCTAssertTrue(defaults.bindings.isEmpty)
        for tool in ImageEditorTool.allCases { XCTAssertNil(defaults[tool]) }
        XCTAssertEqual(try LocalAnnotationShortcutSettings.decode(defaults.encodedData()), defaults)
    }

    func testRemappingClearAndShiftDistinctionRoundTrip() throws {
        let r = LocalAnnotationShortcutBinding(keyCode: 15), shifted = LocalAnnotationShortcutBinding(keyCode: 15, modifiers: 1)
        var value = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: r)
        value = try value.replacing(.ellipse, with: shifted)
        XCTAssertEqual(value[.rectangle]?.displayName, "R"); XCTAssertEqual(value[.ellipse]?.displayName, "⇧R")
        XCTAssertEqual(value.tool(for: r), .rectangle); XCTAssertEqual(value.tool(for: shifted), .ellipse)
        value = try value.replacing(.rectangle, with: LocalAnnotationShortcutBinding(keyCode: 11))
        XCTAssertNil(value.tool(for: r))
        value = try value.replacing(.ellipse, with: nil)
        XCTAssertEqual(try LocalAnnotationShortcutSettings.decode(value.encodedData()), value)
        XCTAssertEqual(try value.replacing(.rectangle, with: nil), .defaults)
    }

    func testDuplicateToolsAndBindingsAreRejectedWithoutReplacingOriginal() throws {
        let r = LocalAnnotationShortcutBinding(keyCode: 15), b = LocalAnnotationShortcutBinding(keyCode: 11)
        let original = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: r)
        XCTAssertThrowsError(try original.replacing(.ellipse, with: r)) { error in
            XCTAssertEqual(error as? LocalAnnotationShortcutError, .duplicateKey("R"))
        }
        XCTAssertEqual(original[.rectangle], r); XCTAssertNil(original[.ellipse])
        XCTAssertThrowsError(try LocalAnnotationShortcutSettings(bindings: [.init(tool: .rectangle, binding: r), .init(tool: .rectangle, binding: b)]))
    }

    func testReservedCommandsNavigationNumberCommentAndModifierMasksAreRejected() throws {
        for code in [UInt16(0), 36, 76, 53, 51, 117, 123, 124, 125, 126, 48, 49, 50, 127, 65535] {
            XCTAssertThrowsError(try LocalAnnotationShortcutBinding(keyCode: code).validate(), "\(code)")
        }
        for mask in [UInt8(2), 4, 8, 16, 255] { XCTAssertThrowsError(try LocalAnnotationShortcutBinding(keyCode: 15, modifiers: mask).validate()) }
        for code in LocalAnnotationShortcutBinding.keyNames.keys where code != 0 {
            XCTAssertNoThrow(try LocalAnnotationShortcutBinding(keyCode: code).validate())
            XCTAssertNoThrow(try LocalAnnotationShortcutBinding(keyCode: code, modifiers: 1).validate())
        }
    }

    func testStrictCodableRejectsUnknownMissingAndInvalidNestedValues() throws {
        let valid = #"{"schemaVersion":1,"bindings":[{"tool":"rectangle","binding":{"keyCode":15,"modifiers":0}}]}"#
        let malformed = [valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"unknown\":false"),
            valid.replacingOccurrences(of: "\"tool\":\"rectangle\"", with: "\"tool\":\"rectangle\",\"text\":\"hidden\""),
            valid.replacingOccurrences(of: "\"keyCode\":15", with: "\"keyCode\":15,\"unknown\":0"),
            valid.replacingOccurrences(of: "\"keyCode\":15", with: "\"keyCode\":true"),
            valid.replacingOccurrences(of: "\"keyCode\":15", with: "\"keyCode\":\"15\""),
            valid.replacingOccurrences(of: "\"keyCode\":15", with: "\"keyCode\":15.5"),
            valid.replacingOccurrences(of: "\"keyCode\":15", with: "\"keyCode\":-1"),
            valid.replacingOccurrences(of: "\"keyCode\":15", with: "\"keyCode\":65536"),
            valid.replacingOccurrences(of: ",\"modifiers\":0", with: ""),
            valid.replacingOccurrences(of: "\"modifiers\":0", with: "\"modifiers\":null"),
            valid.replacingOccurrences(of: "\"modifiers\":0", with: "\"modifiers\":2"),
            valid.replacingOccurrences(of: "rectangle", with: "unknownTool"),
            valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
            valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
            #"{"schemaVersion":1,"bindings":null}"#]
        for text in malformed {
            XCTAssertThrowsError(try LocalAnnotationShortcutSettings.decode(Data(text.utf8)), text)
            XCTAssertThrowsError(try JSONDecoder().decode(LocalAnnotationShortcutSettings.self, from: Data(text.utf8)), text)
        }
    }

    func testDuplicateObjectKeysEscapedKeysAndBindingCountAreBounded() throws {
        let duplicates = [#"{"schemaVersion":1,"schemaVersion":1,"bindings":[]}"#,
            #"{"schemaVersion":1,"schema\u0056ersion":1,"bindings":[]}"#,
            #"{"schemaVersion":1,"bindings":[{"tool":"rectangle","tool":"ellipse","binding":{"keyCode":15,"modifiers":0}}]}"#,
            #"{"schemaVersion":1,"bindings":[{"tool":"rectangle","binding":{"keyCode":15,"keyCode":17,"modifiers":0}}]}"#]
        for text in duplicates { XCTAssertThrowsError(try LocalAnnotationShortcutSettings.decode(Data(text.utf8))) }
        let item = #"{"tool":"rectangle","binding":{"keyCode":15,"modifiers":0}}"#
        let repeated = "{\"schemaVersion\":1,\"bindings\":[" + Array(repeating: item, count: 21).joined(separator: ",") + "]}"
        XCTAssertThrowsError(try LocalAnnotationShortcutSettings.decode(Data(repeated.utf8)))
        XCTAssertThrowsError(try LocalAnnotationShortcutSettings.decode(Data(repeating: 32, count: LocalAnnotationShortcutSettings.maximumDataBytes + 1)))
        XCTAssertThrowsError(try LocalAnnotationShortcutSettings.decode(Data((String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32)).utf8)))
    }

    func testPreferencePersistenceFallbackAndResetNeverTouchGlobalConfiguration() throws {
        let suite = "PicShot.LocalAnnotationShortcutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        try HotKeyConfiguration.defaults.save(to: defaults)
        let global = defaults.data(forKey: HotKeyConfiguration.preferenceKey)
        XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults), .defaults)
        XCTAssertNil(defaults.object(forKey: LocalAnnotationShortcutSettings.preferenceKey))
        let custom = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
        try custom.write(to: defaults); XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults), custom)
        defaults.set(Data("{\"schemaVersion\":1,\"schemaVersion\":1,\"bindings\":[]}".utf8), forKey: LocalAnnotationShortcutSettings.preferenceKey)
        XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults), .defaults)
        try LocalAnnotationShortcutSettings.defaults.write(to: defaults)
        XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults), .defaults)
        XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.preferenceKey), global)
    }
}
