import Foundation
import Combine
import XCTest
import PicShotCore
@testable import PicShot

@MainActor final class TextScriptStoreTests: XCTestCase {
    private enum Injected: Error { case failed }

    func testOpenNeverCreatesExampleAndSavePersistsOnlyAuthoredSourceAndExplicitSelection() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TextScriptStore(directory: directory)
        XCTAssertTrue(store.definitions.isEmpty); XCTAssertNil(store.selectedID)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let draft = try definition(1, source: #"return 'User deliberately authored literal';"#)
        _ = try draft.replacing(source: "return 'Unsaved edit';")
        try store.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest(directory).path))
        try store.add(draft)
        XCTAssertNil(store.selectedID); XCTAssertNil(try TextScriptStore(directory: directory).selectedID)
        try store.select(id: draft.id)
        let restored = try TextScriptStore(directory: directory)
        XCTAssertEqual(restored.index, store.index); XCTAssertEqual(restored.definition(id: draft.id)?.source, draft.source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest(directory))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "definitions", "selectedID"])
        let record = try XCTUnwrap((object["definitions"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(record.keys), ["id", "name", "source"])
        XCTAssertEqual(record["source"] as? String, draft.source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [TextScriptStore.manifestFilename])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("chains.json").path))
    }

    func testAtomicSaveAndSelectionPublishOnlyAfterCommittedBytesAndRollbackEveryMutation() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TextScriptStore(directory: directory), first = try definition(1), second = try definition(2)
        try store.add(first, select: true)
        let before = store.index, bytes = try Data(contentsOf: manifest(directory))
        var published: [TextScriptIndex] = []
        let path = manifest(directory)
        let subscription = store.$index.dropFirst().sink { next in
            published.append(next)
            XCTAssertEqual(try? JSONDecoder().decode(TextScriptIndex.self, from: Data(contentsOf: path)), next)
        }
        defer { subscription.cancel() }
        var attempts = 0
        store.beforeManifestCommit = { attempts += 1; throw Injected.failed }
        XCTAssertThrowsError(try store.add(second, select: true)) { XCTAssertEqual($0 as? TextScriptCatalogError, .saveFailed) }
        XCTAssertThrowsError(try store.update(first.replacing(source: "return text.toUpperCase();"), select: true))
        XCTAssertThrowsError(try store.remove(id: first.id))
        XCTAssertThrowsError(try store.select(id: nil))
        XCTAssertEqual(attempts, 4); XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertEqual(try TextScriptStore(directory: directory).index, before)
        store.beforeManifestCommit = nil
        try store.add(second, select: true)
        XCTAssertEqual(published.count, 1); XCTAssertEqual(published[0].selectedID, second.id)
        XCTAssertEqual(store.definitions, [first, second])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [TextScriptStore.manifestFilename])
    }

    func testUpdateOrderDeleteAndSelectionRemainOneAtomicCatalog() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TextScriptStore(directory: directory), first = try definition(1), second = try definition(2)
        try store.add(first, select: true); try store.add(second)
        let update = try first.replacing(name: "Renamed", source: "return text.trim();")
        try store.update(update)
        XCTAssertEqual(store.definitions, [update, second]); XCTAssertEqual(store.selectedID, first.id)
        try store.update(id: second.id, source: "return text.toUpperCase();")
        XCTAssertEqual(store.definitions[1].id, second.id)
        try store.remove(id: second.id); XCTAssertEqual(store.selectedID, first.id)
        try store.remove(id: first.id); XCTAssertNil(store.selectedID); XCTAssertTrue(store.definitions.isEmpty)
        XCTAssertEqual(try TextScriptStore(directory: directory).index, store.index)
    }

    func testCorruptionUnknownPayloadKeysDuplicateKeysAndUnsupportedVersionPreserveDiskAndMemory() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TextScriptStore(directory: directory), first = try definition(1)
        try store.add(first, select: true)
        let before = store.index, healthy = try Data(contentsOf: manifest(directory))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        var unknown = raw; unknown["ocrText"] = "Runtime data must not fit this schema"
        var badID = raw; badID["id"] = "not-a-uuid"
        var largeSource = raw; largeSource["source"] = String(repeating: "x", count: 16_385)
        let objects: [[String: Any]] = [
            ["version": 1, "definitions": [raw, raw]], ["version": 1, "definitions": [unknown]],
            ["version": 1, "definitions": [badID]], ["version": 1, "definitions": [largeSource]],
            ["version": 1, "definitions": [], "selectedID": first.id.uuidString],
            ["version": 1, "definitions": [raw], "result": "not allowed"],
            ["version": 1, "definitions": Array(repeating: raw, count: 33)]
        ]
        var invalid = try objects.map { (try JSONSerialization.data(withJSONObject: $0), TextScriptCatalogError.invalidManifest) }
        invalid += [
            (Data("{bad JSON".utf8), .invalidManifest),
            (Data(repeating: 32, count: TextScriptIndex.maximumBytes + 1), .invalidManifest),
            (Data(#"{"version":99,"definitions":[]}"#.utf8), .unsupportedVersion),
            (Data(#"{"version":1,"version":1,"definitions":[]}"#.utf8), .invalidManifest),
            (Data(#"{"version":1,"\u0076ersion":1,"definitions":[]}"#.utf8), .invalidManifest),
            (Data(#"{"version":1,"definitions":[],"selectedID":null,"selectedID":null}"#.utf8), .invalidManifest),
            (Data(#"{"version":1,"definitions":[{"id":"20000000-0000-0000-0000-000000000001","name":"A","source":"return text;","source":"return 'other';"}]}"#.utf8), .invalidManifest),
            (Data(#"{"version":1,"definitions":[[[[[[[[[[]]]]]]]]]]}"#.utf8), .invalidManifest)
        ]
        for (data, expected) in invalid {
            try data.write(to: manifest(directory))
            XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? TextScriptCatalogError, expected) }
            XCTAssertThrowsError(try store.update(id: first.id, name: "Cannot replace corrupt catalog")) {
                XCTAssertEqual($0 as? TextScriptCatalogError, expected)
            }
            XCTAssertThrowsError(try TextScriptStore(directory: directory)) {
                XCTAssertEqual($0 as? TextScriptCatalogError, expected)
            }
            XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(directory)), data)
        }
        try healthy.write(to: manifest(directory)); try store.reload(); XCTAssertEqual(store.index, before)
    }

    func testCapacityAndEncodedByteLimitRejectWithoutTruncatingOrReplacingCatalog() throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TextScriptStore(directory: directory)
        for i in 1...32 { try store.add(definition(i)) }
        let before = store.index, bytes = try Data(contentsOf: manifest(directory))
        XCTAssertThrowsError(try store.add(definition(33))) { XCTAssertEqual($0 as? TextScriptCatalogError, .limitReached) }
        XCTAssertThrowsError(try store.add(store.definitions[0])) { XCTAssertEqual($0 as? TextScriptCatalogError, .duplicateIdentifier) }
        XCTAssertThrowsError(try store.update(definition(99))) { XCTAssertEqual($0 as? TextScriptCatalogError, .missingDefinition) }
        XCTAssertThrowsError(try store.remove(id: UUID())) { XCTAssertEqual($0 as? TextScriptCatalogError, .missingDefinition) }
        XCTAssertThrowsError(try store.select(id: UUID())) { XCTAssertEqual($0 as? TextScriptCatalogError, .invalidSelection) }
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(directory)), bytes)
        // JSON escaping can exceed 1 MiB even when every body is <=16 KiB.
        let costlySource = String(repeating: "\u{0001}", count: 16_384)
        var sawBound = false
        for saved in before.definitions {
            let previous = store.index, previousBytes = try Data(contentsOf: manifest(directory))
            do { try store.update(saved.replacing(source: costlySource)) }
            catch {
                XCTAssertEqual(error as? TextScriptCatalogError, .catalogTooLarge)
                XCTAssertEqual(store.index, previous); XCTAssertEqual(try Data(contentsOf: manifest(directory)), previousBytes)
                sawBound = true; break
            }
        }
        XCTAssertTrue(sawBound)
        XCTAssertLessThanOrEqual(try Data(contentsOf: manifest(directory)).count, TextScriptIndex.maximumBytes)
        XCTAssertEqual(try TextScriptStore(directory: directory).index, store.index)
    }

    func testMissingDirectoryAndCorruptManifestCannotErasePreviouslyPublishedCatalog() throws {
        let parent = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("catalog"), moved = parent.appendingPathComponent("moved")
        let store = try TextScriptStore(directory: directory), first = try definition(1)
        try store.add(first, select: true)
        let before = store.index, bytes = try Data(contentsOf: manifest(directory))
        try FileManager.default.moveItem(at: directory, to: moved)
        XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? TextScriptCatalogError, .loadFailed) }
        XCTAssertThrowsError(try store.select(id: nil)) { XCTAssertEqual($0 as? TextScriptCatalogError, .saveFailed) }
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(moved)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.moveItem(at: moved, to: directory)
        try FileManager.default.removeItem(at: manifest(directory)); try store.reload()
        XCTAssertTrue(store.definitions.isEmpty); XCTAssertNil(store.selectedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest(directory).path))
    }

    func testSymlinkAndDirectoryManifestsCannotRedirectReadOrMutation() throws {
        let parent = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("catalog")
        let store = try TextScriptStore(directory: directory), first = try definition(1)
        try store.add(first, select: true)
        let before = store.index
        let outside = parent.appendingPathComponent("outside.json"), bytes = Data("untouched".utf8)
        try bytes.write(to: outside); try FileManager.default.removeItem(at: manifest(directory))
        try FileManager.default.createSymbolicLink(at: manifest(directory), withDestinationURL: outside)
        XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? TextScriptCatalogError, .unsafePath) }
        XCTAssertThrowsError(try store.remove(id: first.id)) { XCTAssertEqual($0 as? TextScriptCatalogError, .unsafePath) }
        XCTAssertEqual(store.index, before); XCTAssertEqual(try Data(contentsOf: outside), bytes)
        try FileManager.default.removeItem(at: outside)
        XCTAssertThrowsError(try store.select(id: nil)) { XCTAssertEqual($0 as? TextScriptCatalogError, .unsafePath) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        try FileManager.default.removeItem(at: manifest(directory))
        try FileManager.default.createDirectory(at: manifest(directory), withIntermediateDirectories: true)
        XCTAssertThrowsError(try TextScriptStore(directory: directory)) { XCTAssertEqual($0 as? TextScriptCatalogError, .unsafePath) }
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try TextScriptStore(directory: alias)) { XCTAssertEqual($0 as? TextScriptCatalogError, .unsafePath) }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-TextScriptStore-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
    }
    private func manifest(_ directory: URL) -> URL { directory.appendingPathComponent(TextScriptStore.manifestFilename) }
    private func definition(_ index: Int, source: String = "return text;") throws -> TextScriptDefinition {
        try TextScriptDefinition(id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!,
                                 name: "脚本 \(index)", source: source)
    }
}
