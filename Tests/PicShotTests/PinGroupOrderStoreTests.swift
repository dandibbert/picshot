import Foundation
import XCTest
import PicShotCore
@testable import PicShot

final class PinGroupOrderStoreTests: XCTestCase {
    private enum Injected: Error { case write }

    @MainActor func testGroupOrderPersistsAndDoesNotChangeActiveGroupMembershipOrAssetBytes() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let first = try store.createGroup(name: "First", color: .green)
        let active = try store.createGroup(name: "Saved", color: .purple)
        try store.setActiveGroup(id: active.id)
        let entry = try store.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: "Kept")), title: "Kept"))
        try store.archive(id: entry.id)
        try store.setGroupHidden(id: active.id, hidden: true)
        try store.setGroupProtected(id: active.id, protected: true)
        try store.setAllHidden(true)
        let before = store.index, files = try snapshot(directory)
        try store.moveGroup(id: active.id, offset: -1)
        var expected = before; expected.groups.swapAt(1, 2)
        XCTAssertEqual(store.index, expected)
        XCTAssertEqual(store.groups.map(\.id), [PinGroup.defaultID, active.id, first.id])
        let after = try snapshot(directory)
        XCTAssertEqual(Set(after.keys), Set(files.keys))
        for filename in entry.assetFilenames { XCTAssertEqual(after[filename], files[filename]) }
        let restored = try PinSessionStore(directory: directory)
        XCTAssertEqual(restored.index, expected)
        try restored.moveGroup(id: active.id, offset: 1)
        XCTAssertEqual(restored.index, before)
        XCTAssertEqual(try PinSessionStore(directory: directory).index, before)
    }

    @MainActor func testBoundaryAndZeroMovesDoNotWriteOrInvokeFailureSeam() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let last = try store.createGroup(name: "Last")
        let before = store.index, files = try snapshot(directory)
        var writes = 0
        store.failureInjector = { _ in writes += 1; throw Injected.write }
        try store.moveGroup(id: PinGroup.defaultID, offset: -1)
        try store.moveGroup(id: last.id, offset: 1)
        try store.moveGroup(id: last.id, offset: 0)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        for offset in [-2, 2, Int.min, Int.max] {
            XCTAssertThrowsError(try store.moveGroup(id: last.id, offset: offset)) {
                XCTAssertEqual($0 as? PinSessionError, .invalidGroupOffset)
            }
        }
        XCTAssertThrowsError(try store.moveGroup(id: UUID(), offset: -1)) {
            XCTAssertEqual($0 as? PinSessionError, .missingGroup)
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
    }

    @MainActor func testFailedGroupManifestCommitKeepsPriorOrderAndSafeBytesThenCanRetry() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let group = try store.createGroup(name: "Other")
        let before = store.index, files = try snapshot(directory)
        var fired = false
        store.failureInjector = { point in
            if point == .beforeIndexCommit { fired = true; throw Injected.write }
        }
        XCTAssertThrowsError(try store.moveGroup(id: group.id, offset: -1))
        XCTAssertTrue(fired)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        store.failureInjector = nil
        XCTAssertEqual(try PinSessionStore(directory: directory).index, before)
        try store.moveGroup(id: group.id, offset: -1)
        XCTAssertEqual(store.groups.map(\.id), [group.id, PinGroup.defaultID])
        XCTAssertEqual(try PinSessionStore(directory: directory).index, store.index)
    }

    @MainActor func testCorruptGroupManifestIsNeverOverwrittenOrCleaned() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        _ = try store.createGroup(name: "Other")
        var broken = store.index; broken.groups.append(broken.groups[0])
        let manifest = directory.appendingPathComponent("index.json")
        try JSONEncoder().encode(broken).write(to: manifest)
        let sentinel = directory.appendingPathComponent(UUID().uuidString + ".pinjson")
        try Data("unreferenced but retained on a corrupt load".utf8).write(to: sentinel)
        let before = try snapshot(directory)
        XCTAssertThrowsError(try PinSessionStore(directory: directory)) {
            XCTAssertEqual($0 as? PinSessionError, .invalidManifest)
        }
        XCTAssertEqual(try snapshot(directory), before)
    }

    @MainActor func testSymlinkManifestCannotRedirectGroupWriteOrChangeOutsideFile() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let group = try store.createGroup(name: "Other")
        let before = store.index
        let manifest = directory.appendingPathComponent("index.json")
        let savedManifest = try Data(contentsOf: manifest)
        let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: outside) }
        let safe = Data("outside safe bytes".utf8)
        try safe.write(to: outside)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        XCTAssertThrowsError(try store.moveGroup(id: group.id, offset: -1)) {
            XCTAssertEqual($0 as? PinSessionError, .unsafePath)
        }
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(try Data(contentsOf: outside), safe)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: manifest.path), outside.path)
        try FileManager.default.removeItem(at: manifest)
        try savedManifest.write(to: manifest)
        XCTAssertEqual(try PinSessionStore(directory: directory).index, before)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotGroupOrderTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
