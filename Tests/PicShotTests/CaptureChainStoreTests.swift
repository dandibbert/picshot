import Foundation
import Combine
import XCTest
import PicShotCore
@testable import PicShot

final class CaptureChainStoreTests: XCTestCase {
    private enum Injected: Error { case write }

    @MainActor func testOpeningAndEditingDraftsNeverCreateManifestOrSelectFirstDefinition() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory)
        let draft = try definition(index: 1)
        _ = try draft.replacing(name: "Unsaved draft", outputs: [.copy])
        try store.reload()
        XCTAssertTrue(store.definitions.isEmpty); XCTAssertNil(store.selectedID)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try store.add(draft)
        XCTAssertNil(store.selectedID)
        XCTAssertNil(try CaptureChainStore(directory: directory).selectedID)
    }

    @MainActor func testOrderedDefinitionsSourcesAndExplicitSelectionSurviveReloadWithMetadataOnly() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory)
        let presetID = UUID()
        let first = try definition(index: 1, outputs: [.pin, .quickSavePNG, .copy])
        let second = try definition(index: 2, source: .preset(presetID), outputs: [.copy, .pin])
        try store.add(first); try store.add(second); try store.select(id: second.id)
        let restored = try CaptureChainStore(directory: directory)
        XCTAssertEqual(restored.index, store.index)
        XCTAssertEqual(restored.definitions, [first, second]); XCTAssertEqual(restored.selectedID, second.id)
        XCTAssertEqual(restored.definition(id: first.id)?.outputs, [.pin, .quickSavePNG, .copy])
        XCTAssertEqual(restored.definition(id: second.id)?.source, .preset(presetID))
        // There is intentionally no preset-store dependency: unavailable references
        // remain stored and explainable instead of silently changing their source.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [CaptureChainStore.manifestFilename])
        let bytes = try Data(contentsOf: manifest(directory))
        XCTAssertLessThan(bytes.count, CaptureChainIndex.maximumBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "definitions", "selectedID"]))
        let entries = try XCTUnwrap(object["definitions"] as? [[String: Any]])
        for entry in entries {
            XCTAssertEqual(Set(entry.keys), Set(["id", "name", "source", "outputs"]))
        }
        XCTAssertEqual(entries[0]["outputs"] as? [String], ["pin", "quickSavePNG", "copy"])
        let source = try XCTUnwrap(entries[1]["source"] as? [String: Any])
        XCTAssertEqual(Set(source.keys), Set(["kind", "presetID"]))
    }

    @MainActor func testUpdatesPreserveOrderIdentityAndSelectionAndClearSelectionOnlyExplicitly() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory)
        let first = try definition(index: 1), second = try definition(index: 2)
        try store.add(first); try store.add(second); try store.select(id: first.id)
        try store.update(id: first.id, name: "Renamed", source: .preset(UUID()), outputs: [.copy, .quickSavePNG])
        let changed = try XCTUnwrap(store.definition(id: first.id))
        XCTAssertEqual(changed.id, first.id); XCTAssertEqual(changed.name, "Renamed")
        XCTAssertEqual(changed.outputs, [.copy, .quickSavePNG])
        XCTAssertEqual(store.definitions, [changed, second]); XCTAssertEqual(store.selectedID, first.id)
        let replacedSecond = try second.replacing(name: "Renamed", outputs: [.pin])
        try store.update(replacedSecond)
        XCTAssertEqual(store.definitions, [changed, replacedSecond])
        XCTAssertEqual(try CaptureChainStore(directory: directory).index, store.index)
        try store.select(id: nil)
        XCTAssertNil(store.selectedID); XCTAssertNil(try CaptureChainStore(directory: directory).selectedID)
    }

    @MainActor func testManifestIsCommittedBeforePublishingAndFailedWritesPublishNothing() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory)
        let first = try definition(index: 1), second = try definition(index: 2)
        try store.add(first); try store.select(id: first.id)
        let before = store.index, bytes = try Data(contentsOf: manifest(directory))
        let savedManifest = manifest(directory)
        var publications: [CaptureChainIndex] = []
        let subscription = store.$index.dropFirst().sink { published in
            publications.append(published)
            do {
                let disk = try JSONDecoder().decode(CaptureChainIndex.self, from: Data(contentsOf: savedManifest))
                XCTAssertEqual(disk, published)
            } catch { XCTFail("Published a catalog without committed bytes: \(error)") }
        }
        defer { subscription.cancel() }
        var attempts = 0
        store.beforeManifestCommit = { attempts += 1; throw Injected.write }
        XCTAssertThrowsError(try store.add(second)) { XCTAssertEqual($0 as? CaptureChainError, .saveFailed) }
        XCTAssertThrowsError(try store.update(id: first.id, name: "Not committed")) { XCTAssertEqual($0 as? CaptureChainError, .saveFailed) }
        XCTAssertThrowsError(try store.select(id: nil)) { XCTAssertEqual($0 as? CaptureChainError, .saveFailed) }
        XCTAssertThrowsError(try store.remove(id: first.id)) { XCTAssertEqual($0 as? CaptureChainError, .saveFailed) }
        XCTAssertEqual(attempts, 4); XCTAssertTrue(publications.isEmpty)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(directory)), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [CaptureChainStore.manifestFilename])
        XCTAssertEqual(try CaptureChainStore(directory: directory).index, before)
        store.beforeManifestCommit = nil
        try store.add(second)
        XCTAssertEqual(publications, [store.index]); XCTAssertEqual(store.definitions, [first, second])
    }

    @MainActor func testDeletingSelectedDefinitionClearsSelectionInSameCommitAndUnselectedDeletePreservesIt() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory)
        let first = try definition(index: 1), second = try definition(index: 2)
        try store.add(first); try store.add(second); try store.select(id: first.id)
        try store.remove(id: second.id)
        XCTAssertEqual(store.selectedID, first.id)
        let before = store.index, bytes = try Data(contentsOf: manifest(directory))
        store.beforeManifestCommit = { throw Injected.write }
        XCTAssertThrowsError(try store.remove(id: first.id))
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(directory)), bytes)
        store.beforeManifestCommit = nil
        try store.remove(id: first.id)
        let restored = try CaptureChainStore(directory: directory)
        XCTAssertTrue(store.definitions.isEmpty); XCTAssertNil(store.selectedID)
        XCTAssertEqual(restored.index, store.index)
    }

    @MainActor func testInvalidMutationsAndCapacityPreserveDiskAndMemory() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory)
        for value in 1...32 { try store.add(definition(index: value)) }
        try store.select(id: store.definitions[0].id)
        let before = store.index, bytes = try Data(contentsOf: manifest(directory))
        XCTAssertThrowsError(try store.add(definition(index: 33))) { XCTAssertEqual($0 as? CaptureChainError, .limitReached) }
        XCTAssertThrowsError(try store.add(before.definitions[0])) { XCTAssertEqual($0 as? CaptureChainError, .duplicateIdentifier) }
        XCTAssertThrowsError(try store.update(id: before.definitions[0].id, name: "\n")) { XCTAssertEqual($0 as? CaptureChainError, .invalidName) }
        XCTAssertThrowsError(try store.update(id: before.definitions[0].id, outputs: [.pin, .pin])) {
            XCTAssertEqual($0 as? CaptureChainError, .invalidOutputs)
        }
        XCTAssertThrowsError(try store.update(definition(index: 99))) { XCTAssertEqual($0 as? CaptureChainError, .missingDefinition) }
        XCTAssertThrowsError(try store.update(id: UUID(), name: "Missing")) { XCTAssertEqual($0 as? CaptureChainError, .missingDefinition) }
        XCTAssertThrowsError(try store.remove(id: UUID())) { XCTAssertEqual($0 as? CaptureChainError, .missingDefinition) }
        XCTAssertThrowsError(try store.select(id: UUID())) { XCTAssertEqual($0 as? CaptureChainError, .invalidSelection) }
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(directory)), bytes)
    }

    @MainActor func testCorruptUnknownOversizedAndUnsupportedFilesRejectReloadAndWritesWithoutLosingState() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory), first = try definition(index: 1)
        try store.add(first); try store.select(id: first.id)
        let before = store.index, healthy = try Data(contentsOf: manifest(directory))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        var unknownOutput = raw; unknownOutput["outputs"] = ["copy", "script"]
        var duplicateOutput = raw; duplicateOutput["outputs"] = ["pin", "pin"]
        var unknownKey = raw; unknownKey["image"] = "not allowed"
        var invalidSource = raw; invalidSource["source"] = ["kind": "preset", "presetID": "invalid"]
        let objects: [[String: Any]] = [
            ["version": 1, "definitions": [raw, raw]], ["version": 1, "definitions": [unknownOutput]],
            ["version": 1, "definitions": [duplicateOutput]], ["version": 1, "definitions": [unknownKey]],
            ["version": 1, "definitions": [invalidSource]], ["version": 1, "definitions": [], "selectedID": first.id.uuidString],
            ["version": 1, "definitions": [raw], "receipts": []], ["version": 1, "definitions": Array(repeating: raw, count: 33)]
        ]
        var invalid = try objects.map { (try JSONSerialization.data(withJSONObject: $0), CaptureChainError.invalidManifest) }
        invalid += [(Data("{bad JSON".utf8), .invalidManifest),
                    (Data(repeating: 32, count: CaptureChainIndex.maximumBytes + 1), .invalidManifest),
                    (Data("{\"version\":999,\"definitions\":[]}".utf8), .unsupportedVersion)]
        for (bytes, expected) in invalid {
            try bytes.write(to: manifest(directory))
            XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? CaptureChainError, expected) }
            XCTAssertThrowsError(try store.update(id: first.id, name: "Cannot overwrite corruption")) {
                XCTAssertEqual($0 as? CaptureChainError, expected)
            }
            XCTAssertThrowsError(try CaptureChainStore(directory: directory)) { XCTAssertEqual($0 as? CaptureChainError, expected) }
            XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(directory)), bytes)
        }
        try healthy.write(to: manifest(directory)); try store.reload()
        XCTAssertEqual(store.index, before)
    }

    @MainActor func testMissingManifestReloadClearsDefinitionsAndSelectionWithoutWritingAReplacement() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory), first = try definition(index: 1)
        try store.add(first); try store.select(id: first.id)
        try FileManager.default.removeItem(at: manifest(directory))
        try store.reload()
        XCTAssertTrue(store.definitions.isEmpty); XCTAssertNil(store.selectedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest(directory).path))
    }

    @MainActor func testUnavailableDirectoryKeepsCatalogAndDoesNotRecreateOrReplaceFiles() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("catalog", isDirectory: true)
        let moved = parent.appendingPathComponent("temporarily-unavailable", isDirectory: true)
        let store = try CaptureChainStore(directory: directory), first = try definition(index: 1)
        try store.add(first); try store.select(id: first.id)
        let before = store.index, bytes = try Data(contentsOf: manifest(directory))
        try FileManager.default.moveItem(at: directory, to: moved)
        XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? CaptureChainError, .loadFailed) }
        XCTAssertThrowsError(try store.select(id: nil)) { XCTAssertEqual($0 as? CaptureChainError, .saveFailed) }
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(moved)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.moveItem(at: moved, to: directory)
        try store.reload(); XCTAssertEqual(store.index, before)
    }

    @MainActor func testSymlinkAndDanglingSymlinkManifestsCannotRedirectReadOrMutation() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("catalog", isDirectory: true)
        let store = try CaptureChainStore(directory: directory), first = try definition(index: 1)
        try store.add(first); try store.select(id: first.id)
        let before = store.index
        let outside = parent.appendingPathComponent("outside.json"), safe = Data("outside remains untouched".utf8)
        try safe.write(to: outside); try FileManager.default.removeItem(at: manifest(directory))
        try FileManager.default.createSymbolicLink(at: manifest(directory), withDestinationURL: outside)
        XCTAssertThrowsError(try CaptureChainStore(directory: directory)) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
        XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
        XCTAssertThrowsError(try store.remove(id: first.id)) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: outside), safe)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: manifest(directory).path), outside.path)
        try FileManager.default.removeItem(at: outside)
        XCTAssertThrowsError(try store.select(id: nil)) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
        XCTAssertThrowsError(try CaptureChainStore(directory: directory)) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
        XCTAssertEqual(store.index, before); XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    @MainActor func testSymlinkDirectoriesAndDirectoryManifestAreRejected() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let actual = parent.appendingPathComponent("actual", isDirectory: true), alias = parent.appendingPathComponent("alias", isDirectory: true)
        let store = try CaptureChainStore(directory: actual), first = try definition(index: 1)
        try store.add(first)
        let before = store.index, bytes = try Data(contentsOf: manifest(actual))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        XCTAssertThrowsError(try CaptureChainStore(directory: alias)) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: actual, to: moved)
        try FileManager.default.createSymbolicLink(at: actual, withDestinationURL: moved)
        XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
        XCTAssertThrowsError(try store.update(id: first.id, name: "Rejected")) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(moved)), bytes)
        try FileManager.default.removeItem(at: manifest(moved))
        try FileManager.default.createDirectory(at: manifest(moved), withIntermediateDirectories: true)
        XCTAssertThrowsError(try CaptureChainStore(directory: moved)) { XCTAssertEqual($0 as? CaptureChainError, .unsafePath) }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotChainTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.standardizedFileURL.resolvingSymlinksInPath()
    }
    @MainActor private func manifest(_ directory: URL) -> URL { directory.appendingPathComponent(CaptureChainStore.manifestFilename) }
    private func definition(index: Int, source: CaptureChainSource = .region,
                            outputs: [CaptureChainOutput] = [.quickSavePNG, .copy, .pin]) throws -> CaptureChainDefinition {
        try CaptureChainDefinition(id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!,
                                   name: "截图链 \(index)", source: source, outputs: outputs)
    }
}
