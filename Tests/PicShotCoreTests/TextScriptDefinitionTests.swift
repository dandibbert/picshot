import Foundation
import XCTest
@testable import PicShotCore

final class TextScriptDefinitionTests: XCTestCase {
    func testSourceAndNameBoundariesCountUTF8WithoutTruncatingSavedLiterals() throws {
        let source = String(repeating: "🐱", count: 4_096)
        XCTAssertEqual(source.utf8.count, TextScriptDefinition.maximumSourceBytes)
        let saved = try TextScriptDefinition(name: String(repeating: "🐱", count: 64), source: source)
        XCTAssertEqual(saved.source, source); XCTAssertEqual(saved.name.utf8.count, 256)
        XCTAssertThrowsError(try saved.replacing(source: source + "a")) {
            XCTAssertEqual($0 as? TextScriptCatalogError, .invalidSource)
        }
        XCTAssertThrowsError(try saved.replacing(name: saved.name + "x")) {
            XCTAssertEqual($0 as? TextScriptCatalogError, .invalidName)
        }
        // A grapheme may contain many scalars; the byte bound is independent.
        let largeGrapheme = "a" + String(repeating: "\u{0301}", count: 128)
        XCTAssertEqual(largeGrapheme.count, 1)
        XCTAssertThrowsError(try saved.replacing(name: largeGrapheme))
        for name in ["", "  ", "line\nbreak", "tab\tname", "NUL\0", "line\u{2028}break"] {
            XCTAssertThrowsError(try saved.replacing(name: name))
        }
        for source in ["", " \n\t ", String(repeating: "x", count: 16_385)] {
            XCTAssertThrowsError(try saved.replacing(source: source))
        }
        let literal = #"return 'Deliberately authored OCR/output-looking literal'; // \\"#
        let definition = try TextScriptDefinition(name: "  手写脚本  ", source: literal)
        XCTAssertEqual(definition.name, "手写脚本"); XCTAssertEqual(definition.source, literal)
        XCTAssertEqual(try JSONDecoder().decode(TextScriptDefinition.self, from: JSONEncoder().encode(definition)), definition)
    }

    func testExactDefinitionAndCatalogSchemasContainOnlyDeliberatelySavedFields() throws {
        let value = try TextScriptDefinition(name: "Issue IDs", source: "return text;")
        let index = try TextScriptIndex(definitions: [value], selectedID: value.id)
        let data = try JSONEncoder().encode(index)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "definitions", "selectedID"])
        let entries = try XCTUnwrap(object["definitions"] as? [[String: Any]])
        XCTAssertEqual(Set(entries[0].keys), ["id", "name", "source"])
        XCTAssertEqual(try JSONDecoder().decode(TextScriptIndex.self, from: data), index)
        for field in ["ocrText", "result", "image", "path", "receipts", "outputs", "actions", "runtime"] {
            var record = entries[0]; record[field] = "Rejected payload"
            XCTAssertThrowsError(try JSONDecoder().decode(TextScriptDefinition.self, from: JSONSerialization.data(withJSONObject: record)), field)
            var catalog = object; catalog[field] = "Rejected payload"
            XCTAssertThrowsError(try JSONDecoder().decode(TextScriptIndex.self, from: JSONSerialization.data(withJSONObject: catalog)), field)
        }
        for field in ["id", "name", "source"] {
            var record = entries[0]; record.removeValue(forKey: field)
            XCTAssertThrowsError(try JSONDecoder().decode(TextScriptDefinition.self, from: JSONSerialization.data(withJSONObject: record)))
        }
        for id in ["invalid", "", "00000000-0000-0000-0000"] {
            var record = entries[0]; record["id"] = id
            XCTAssertThrowsError(try JSONDecoder().decode(TextScriptDefinition.self, from: JSONSerialization.data(withJSONObject: record)))
        }
        var unnormalized = entries[0]; unnormalized["name"] = " leading whitespace"
        XCTAssertThrowsError(try JSONDecoder().decode(TextScriptDefinition.self, from: JSONSerialization.data(withJSONObject: unnormalized)))
    }

    func testIndexRejectsUnsupportedVersionMissingRequiredFieldsDuplicateIDsAndInvalidSelection() throws {
        let value = try TextScriptDefinition(name: "Example", source: "return text;")
        XCTAssertThrowsError(try TextScriptIndex(definitions: [value, value])) {
            XCTAssertEqual($0 as? TextScriptCatalogError, .duplicateIdentifier)
        }
        XCTAssertThrowsError(try TextScriptIndex(definitions: [value], selectedID: UUID())) {
            XCTAssertEqual($0 as? TextScriptCatalogError, .invalidSelection)
        }
        let values = try (1...32).map { try TextScriptDefinition(name: "Script \($0)", source: "return text;") }
        XCTAssertEqual(try TextScriptIndex(definitions: values).definitions.count, 32)
        XCTAssertThrowsError(try TextScriptIndex(definitions: values + [value])) {
            XCTAssertEqual($0 as? TextScriptCatalogError, .limitReached)
        }
        for json in [#"{"definitions":[]}"#, #"{"version":1}"#, #"{"version":true,"definitions":[]}"#,
                     #"{"version":1,"definitions":[],"selectedID":"bad"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(TextScriptIndex.self, from: Data(json.utf8)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(TextScriptIndex.self, from: Data(#"{"version":2,"definitions":[]}"#.utf8))) {
            XCTAssertEqual($0 as? TextScriptCatalogError, .unsupportedVersion)
        }
        let empty = try TextScriptIndex()
        XCTAssertNil(empty.selectedID)
        XCTAssertEqual(try JSONDecoder().decode(TextScriptIndex.self, from: JSONEncoder().encode(empty)), empty)
    }
}
