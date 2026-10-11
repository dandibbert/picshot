import Foundation
import XCTest
import PicShotCore
@testable import PicShot

final class PinGroupNameStoreTests: XCTestCase {
    private enum Injected: Error, Equatable { case write }

    @MainActor func testDuplicateCreateAndRenameNeverReachCommitOrChangeMemoryDiskOrAssets() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try fixture(directory)
        let before = store.index, files = try snapshot(directory)
        var writes = 0
        store.failureInjector = { _ in writes += 1; throw Injected.write }
        for name in ["Café", " CAFE\u{0301}\n", "\u{00a0}café\u{3000}"] {
            XCTAssertThrowsError(try store.createGroup(name: name, color: .red)) {
                XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
            }
            XCTAssertThrowsError(try store.renameGroup(id: before.groups[2].id, name: name, color: .red)) {
                XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
            }
            XCTAssertEqual(store.index, before)
            XCTAssertEqual(try snapshot(directory), files)
        }
        XCTAssertEqual(writes, 0)
        store.failureInjector = nil
        XCTAssertEqual(try PinSessionStore(directory: directory).index, before)
        XCTAssertEqual(try snapshot(directory), files)
    }

    @MainActor func testFailedUniqueCreateKeepsPriorSessionAndFilesThenRetriesSuccessfully() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try fixture(directory)
        let before = store.index, files = try snapshot(directory)
        var writes = 0
        store.failureInjector = { point in
            if point == .beforeIndexCommit { writes += 1; throw Injected.write }
        }
        XCTAssertThrowsError(try store.createGroup(name: "New", color: .red)) {
            XCTAssertEqual($0 as? Injected, .write)
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        store.failureInjector = nil
        XCTAssertEqual(try PinSessionStore(directory: directory).index, before)
        let created = try store.createGroup(name: " New ", color: .red)
        var expected = before; expected.groups.append(created)
        XCTAssertEqual(created.name, "New"); XCTAssertEqual(created.color, .red)
        XCTAssertEqual(store.index, expected)
        XCTAssertEqual(try PinSessionStore(directory: directory).index, expected)
        try assertAssetsUnchanged(directory, before: files)
    }

    @MainActor func testFailedUniqueRenameKeepsPriorNameColorIdentityAndFilesThenRetries() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try fixture(directory)
        let before = store.index, files = try snapshot(directory), id = store.groups[1].id
        var writes = 0
        store.failureInjector = { point in
            if point == .beforeIndexCommit { writes += 1; throw Injected.write }
        }
        XCTAssertThrowsError(try store.renameGroup(id: id, name: "Renamed", color: .red)) {
            XCTAssertEqual($0 as? Injected, .write)
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        store.failureInjector = nil
        XCTAssertEqual(try PinSessionStore(directory: directory).index, before)
        try store.renameGroup(id: id, name: " Renamed ", color: .red)
        var expected = before; expected.groups[1].name = "Renamed"; expected.groups[1].color = .red
        XCTAssertEqual(store.index, expected)
        XCTAssertEqual(try PinSessionStore(directory: directory).index, expected)
        try assertAssetsUnchanged(directory, before: files)
    }

    @MainActor func testLegacyDuplicateLoadKeepsNamesIDsMembershipContentAndOrder() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = try fixture(directory)
        var legacy = original.index; legacy.groups[2].name = "  CAFE\u{0301}  "
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(legacy).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        let files = try snapshot(directory)
        let loaded = try PinSessionStore(directory: directory)
        XCTAssertEqual(loaded.index, legacy)
        XCTAssertEqual(loaded.groups.map { Array($0.name.utf8) }, legacy.groups.map { Array($0.name.utf8) })
        XCTAssertEqual(try snapshot(directory), files)
        XCTAssertEqual(try PinSessionStore(directory: directory).index, legacy)

        try loaded.renameGroup(id: legacy.groups[1].id, name: "Café")
        XCTAssertEqual(loaded.index, legacy)
        XCTAssertEqual(try snapshot(directory), files)
        try loaded.renameGroup(id: legacy.groups[1].id, name: "Café", color: .red)
        var expected = legacy; expected.groups[1].color = .red
        XCTAssertEqual(loaded.index, expected)
        XCTAssertEqual(try PinSessionStore(directory: directory).index, expected)
        try assertAssetsUnchanged(directory, before: files)

        let retained = loaded.index, retainedFiles = try snapshot(directory)
        XCTAssertThrowsError(try loaded.createGroup(name: "café")) {
            XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
        }
        XCTAssertThrowsError(try loaded.renameGroup(id: PinGroup.defaultID, name: "café", color: .green)) {
            XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
        }
        XCTAssertEqual(loaded.index, retained)
        XCTAssertEqual(try snapshot(directory), retainedFiles)
        try loaded.moveGroup(id: legacy.groups[2].id, offset: -1)
        expected.groups.swapAt(1, 2)
        XCTAssertEqual(loaded.index, expected)
        XCTAssertEqual(try PinSessionStore(directory: directory).index, expected)
        try assertAssetsUnchanged(directory, before: files)
    }

    @MainActor func testLegacyUnchangedNormalizedNameStillRollsBackFailedColorCommit() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = try fixture(directory)
        var legacy = original.index; legacy.groups[2].name = "CAFE\u{0301}"
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        let loaded = try PinSessionStore(directory: directory)
        let before = loaded.index, files = try snapshot(directory)
        var writes = 0
        loaded.failureInjector = { point in
            if point == .beforeIndexCommit { writes += 1; throw Injected.write }
        }
        XCTAssertThrowsError(try loaded.renameGroup(id: legacy.groups[1].id, name: "cafe\u{0301}", color: .red)) {
            XCTAssertEqual($0 as? Injected, .write)
        }
        XCTAssertEqual(writes, 1, "The unchanged normalized name must be allowed through to persistence")
        XCTAssertEqual(loaded.index, before); XCTAssertEqual(try snapshot(directory), files)
        loaded.failureInjector = nil
        XCTAssertEqual(try PinSessionStore(directory: directory).index, before)
        try loaded.renameGroup(id: legacy.groups[1].id, name: "cafe\u{0301}", color: .red)
        var expected = before; expected.groups[1].name = "cafe\u{0301}"; expected.groups[1].color = .red
        XCTAssertEqual(loaded.index, expected)
        XCTAssertEqual(Array(loaded.groups[1].name.utf8), Array("cafe\u{0301}".utf8))
        XCTAssertEqual(try PinSessionStore(directory: directory).index, expected)
        try assertAssetsUnchanged(directory, before: files)
    }

    @MainActor private func fixture(_ directory: URL) throws -> PinSessionStore {
        let store = try PinSessionStore(directory: directory)
        let group = try store.createGroup(name: "Café", color: .purple)
        _ = try store.createGroup(name: "Other", color: .green)
        try store.setActiveGroup(id: group.id)
        _ = try store.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: "Keep open")), title: "Open"))
        let archived = try store.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: "Keep archived")), title: "Archived"))
        try store.archive(id: archived.id)
        try store.setGroupHidden(id: group.id, hidden: true)
        try store.setGroupProtected(id: group.id, protected: true)
        try store.setAllHidden(true)
        return store
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotGroupNameTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    private func assertAssetsUnchanged(_ directory: URL, before: [String: Data], file: StaticString = #filePath, line: UInt = #line) throws {
        let after = try snapshot(directory)
        XCTAssertEqual(Set(after.keys), Set(before.keys), file: file, line: line)
        for (name, data) in before where name != "index.json" {
            XCTAssertEqual(after[name], data, name, file: file, line: line)
        }
    }
}
