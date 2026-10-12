import Foundation
import XCTest
@testable import PicShotCore

final class CaptureChainTests: XCTestCase {
    private let presetID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    func testEveryOrderedSubsetRoundTripsWithoutSortingOrRepeatingOutputs() throws {
        let outputs = CaptureChainOutput.allCases
        var orders: [[CaptureChainOutput]] = []
        for first in outputs {
            orders.append([first])
            for second in outputs where second != first {
                orders.append([first, second])
                for third in outputs where third != first && third != second {
                    orders.append([first, second, third])
                }
            }
        }
        XCTAssertEqual(orders.count, 15)
        for order in orders {
            for source in [CaptureChainSource.region, .preset(presetID)] {
                let saved = try CaptureChainDefinition(name: "有序输出", source: source, outputs: order)
                let index = try CaptureChainIndex(definitions: [saved], selectedID: saved.id)
                let restored = try JSONDecoder().decode(CaptureChainIndex.self, from: JSONEncoder().encode(index))
                XCTAssertEqual(restored, index)
                XCTAssertEqual(restored.definitions[0].outputs, order)
                XCTAssertEqual(restored.definitions[0].source, source)
                XCTAssertEqual(restored.selectedID, saved.id)
            }
        }
    }

    func testNameBoundsTrimOnlySafeInputAndLoadedNamesAreAlreadyCanonical() throws {
        XCTAssertEqual(try definition(name: "  已保存  ").name, "已保存")
        XCTAssertEqual(try definition(name: String(repeating: "x", count: 64)).name.count, 64)
        XCTAssertEqual(try definition(name: String(repeating: "😀", count: 64)).name.utf8.count, 256)
        let tooManyBytes = String(repeating: "e\u{301}\u{301}", count: 64)
        XCTAssertEqual(tooManyBytes.count, 64)
        XCTAssertGreaterThan(tooManyBytes.utf8.count, 256)
        for invalid in ["", "   ", "a\nb", "\nname", "name\n", "\tname", "a\u{0}b", "a\u{2028}b",
                        String(repeating: "x", count: 65), tooManyBytes] {
            XCTAssertThrowsError(try definition(name: invalid)) { XCTAssertEqual($0 as? CaptureChainError, .invalidName) }
        }
        var object = try object(definition())
        for invalid in [" padded ", "bad\nname", "", tooManyBytes] {
            object["name"] = invalid
            XCTAssertThrowsError(try decodeDefinition(object))
        }
    }

    func testInvalidOutputsUnknownValuesAndSourcePayloadsAreRejected() throws {
        let invalidOutputs: [[CaptureChainOutput]] = [[], [.copy, .copy], [.pin, .copy, .pin], [.copy, .pin, .quickSavePNG, .copy]]
        for outputs in invalidOutputs {
            XCTAssertThrowsError(try definition(outputs: outputs)) { XCTAssertEqual($0 as? CaptureChainError, .invalidOutputs) }
        }
        let original = try object(definition())
        let invalidOutputNames: [[String]] = [[], ["copy", "copy"], ["copy", "runScript"], ["pin", "copy", "quickSavePNG", "pin"]]
        for outputs in invalidOutputNames {
            var changed = original; changed["outputs"] = outputs
            XCTAssertThrowsError(try decodeDefinition(changed))
        }
        let invalidSources: [[String: Any]] = [
            [:], ["kind": "window"], ["kind": "preset"], ["kind": "preset", "presetID": "not-a-uuid"],
            ["kind": "region", "presetID": presetID.uuidString], ["kind": "region", "presetID": NSNull()],
            ["kind": "region", "script": "echo forbidden"], ["kind": "preset", "presetID": presetID.uuidString, "path": "/tmp/image.png"]
        ]
        for source in invalidSources {
            var changed = original; changed["source"] = source
            XCTAssertThrowsError(try decodeDefinition(changed))
        }
    }

    func testUnknownKeysAtEveryObjectLevelAndMissingRequiredFieldsFailClosed() throws {
        let original = try object(definition())
        for unknown in ["image", "savedURL", "pinID", "receipts", "runtimeState", "version"] {
            var changed = original; changed[unknown] = "unexpected"
            XCTAssertThrowsError(try decodeDefinition(changed)) { XCTAssertEqual($0 as? CaptureChainError, .invalidManifest) }
        }
        for required in ["id", "name", "source", "outputs"] {
            var changed = original; changed.removeValue(forKey: required)
            XCTAssertThrowsError(try decodeDefinition(changed))
        }
        var index: [String: Any] = ["version": 1, "definitions": [original], "selectedID": original["id"]!]
        index["runtimeState"] = "completed"
        XCTAssertThrowsError(try decodeIndex(index)) { XCTAssertEqual($0 as? CaptureChainError, .invalidManifest) }
        index.removeValue(forKey: "runtimeState"); index.removeValue(forKey: "version")
        XCTAssertThrowsError(try decodeIndex(index))
        XCTAssertThrowsError(try decodeIndex(["version": 1]))
    }

    func testVersionDuplicateIdentifiersCountAndSelectionAreStrict() throws {
        let saved = try definition(), record = try object(saved)
        XCTAssertThrowsError(try decodeIndex(["version": 999, "definitions": []])) {
            XCTAssertEqual($0 as? CaptureChainError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try CaptureChainIndex(definitions: [saved, saved])) {
            XCTAssertEqual($0 as? CaptureChainError, .duplicateIdentifier)
        }
        XCTAssertThrowsError(try decodeIndex(["version": 1, "definitions": [record, record]])) {
            XCTAssertEqual($0 as? CaptureChainError, .duplicateIdentifier)
        }
        let missing = UUID()
        XCTAssertThrowsError(try CaptureChainIndex(definitions: [saved], selectedID: missing)) {
            XCTAssertEqual($0 as? CaptureChainError, .invalidSelection)
        }
        XCTAssertThrowsError(try decodeIndex(["version": 1, "definitions": [record], "selectedID": missing.uuidString])) {
            XCTAssertEqual($0 as? CaptureChainError, .invalidSelection)
        }
        XCTAssertThrowsError(try decodeIndex(["version": 1, "definitions": [record], "selectedID": "invalid"]))
        let definitions = try (0..<33).map { try definition(name: "Chain \($0)") }
        XCTAssertEqual(try CaptureChainIndex(definitions: Array(definitions.prefix(32))).definitions.count, 32)
        XCTAssertThrowsError(try CaptureChainIndex(definitions: definitions)) { XCTAssertEqual($0 as? CaptureChainError, .limitReached) }
        XCTAssertThrowsError(try decodeIndex(["version": 1, "definitions": Array(repeating: record, count: 33)])) {
            XCTAssertEqual($0 as? CaptureChainError, .limitReached)
        }
        XCTAssertNil(try CaptureChainIndex(definitions: [saved]).selectedID)
        XCTAssertNil(try decodeIndex(["version": 1, "definitions": [record], "selectedID": NSNull()]).selectedID)
    }

    func testReplacementPreservesIdentityAndDuplicateNamesAreIndependent() throws {
        let original = try definition()
        let updated = try original.replacing(name: "新名称", source: .preset(presetID), outputs: [.pin, .copy])
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.name, "新名称"); XCTAssertEqual(updated.source, .preset(presetID))
        XCTAssertEqual(updated.outputs, [.pin, .copy]); XCTAssertEqual(try original.replacing(), original)
        let duplicateName = try definition(name: original.name)
        XCTAssertEqual(try CaptureChainIndex(definitions: [original, duplicateName]).definitions.count, 2)
        XCTAssertNotEqual(original.id, duplicateName.id)
    }

    func testEncodedShapeContainsDefinitionMetadataOnly() throws {
        let saved = try definition(source: .preset(presetID), outputs: [.pin, .quickSavePNG, .copy])
        let index = try CaptureChainIndex(definitions: [saved], selectedID: saved.id)
        let indexObject = try object(index)
        XCTAssertEqual(Set(indexObject.keys), Set(["version", "definitions", "selectedID"]))
        let definitions = try XCTUnwrap(indexObject["definitions"] as? [[String: Any]])
        XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(Set(definitions[0].keys), Set(["id", "name", "source", "outputs"]))
        let source = try XCTUnwrap(definitions[0]["source"] as? [String: Any])
        XCTAssertEqual(Set(source.keys), Set(["kind", "presetID"]))
        XCTAssertEqual(source["kind"] as? String, "preset")
        XCTAssertEqual(source["presetID"] as? String, presetID.uuidString)
        XCTAssertEqual(definitions[0]["outputs"] as? [String], ["pin", "quickSavePNG", "copy"])
        XCTAssertEqual(Set(try object(CaptureChainSource.region).keys), Set(["kind"]))
    }

    private func definition(name: String = "截图链", source: CaptureChainSource = .region,
                            outputs: [CaptureChainOutput] = [.quickSavePNG, .copy, .pin]) throws -> CaptureChainDefinition {
        try CaptureChainDefinition(name: name, source: source, outputs: outputs)
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func decodeDefinition(_ value: [String: Any]) throws -> CaptureChainDefinition {
        try JSONDecoder().decode(CaptureChainDefinition.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func decodeIndex(_ value: [String: Any]) throws -> CaptureChainIndex {
        try JSONDecoder().decode(CaptureChainIndex.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
