import AppKit
import Foundation
import XCTest
import PicShotCore
@testable import PicShot

final class PinTextUpdateStoreTests: XCTestCase {
    private enum Injected: Error { case write }

    @MainActor func testSaveReloadReplacesTextAndPosterKeepingPinStateAndOtherEntries() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let other = try addText("Unrelated saved text", to: store)
        let group = try store.createGroup(name: "Saved", color: .purple)
        try store.setActiveGroup(id: group.id)
        let original = PinTextContent(text: "Original text")
        let entry = try store.add(rich: PreparedRichPin(document: PinRichDocument(text: original), title: "Keep this title"),
            presentation: PinPresentation(frame: PinWindowFrame(x: -900, y: 42, width: 420, height: 240),
                opacity: 0.4, zoom: 2, clickThrough: true, locked: true))
        try store.archive(id: entry.id)
        try store.setGroupHidden(id: group.id, hidden: true)
        try store.setGroupProtected(id: group.id, protected: true)
        try store.setAllHidden(true)
        let before = store.index, beforeFiles = try snapshot(directory)
        let cached = try XCTUnwrap(store.thumbnail(id: entry.id))
        let replacement = PinTextContent(text: "Replacement text\n中文 👩🏽‍💻 e\u{301}\n  exact spacing  ")
        try store.updateText(id: entry.id, content: replacement, expectedContent: original)
        let saved = try XCTUnwrap(store.entry(id: entry.id))
        let previous = try XCTUnwrap(before.entry(id: entry.id))
        var expected = previous
        expected.richContent = saved.richContent; expected.original = saved.original; expected.current = saved.current
        expected.updatedAt = saved.updatedAt
        XCTAssertEqual(saved, expected)
        XCTAssertEqual(saved.original, saved.current)
        XCTAssertNotEqual(saved.original.filename, previous.original.filename)
        XCTAssertNotEqual(saved.richContent?.filename, previous.richContent?.filename)
        XCTAssertEqual(saved.original.width, 480); XCTAssertEqual(saved.original.height, 280)
        XCTAssertEqual(store.groups, before.groups)
        XCTAssertEqual(store.index.activeGroupID, before.activeGroupID); XCTAssertEqual(store.index.allHidden, before.allHidden)
        XCTAssertEqual(store.entries.map(\.id), before.entries.map(\.id))
        XCTAssertEqual(store.entry(id: other.id), before.entry(id: other.id))
        XCTAssertEqual(try content(entry.id, in: store), replacement)
        XCTAssertFalse(try XCTUnwrap(store.thumbnail(id: entry.id)) === cached)
        for filename in previous.assetFilenames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
        }
        let afterFiles = try snapshot(directory)
        for filename in other.assetFilenames { XCTAssertEqual(afterFiles[filename], beforeFiles[filename]) }
        XCTAssertNotEqual(afterFiles[saved.original.filename], beforeFiles[previous.original.filename])
        XCTAssertEqual(Set(afterFiles.keys), Set(store.entries.flatMap(\.assetFilenames) + ["index.json"]))
        let reopened = try PinSessionStore(directory: directory)
        XCTAssertEqual(reopened.index, store.index)
        XCTAssertEqual(try content(entry.id, in: reopened), replacement)
    }

    @MainActor func testDraftReadCancelAndUnchangedSaveNeverWrite() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = PinTextContent(text: "Unchanged")
        let entry = try addText(original, to: store)
        let before = store.index, files = try snapshot(directory)
        var writes = 0
        store.failureInjector = { _ in writes += 1; throw Injected.write }
        var draft = try content(entry.id, in: store)
        draft.runs[0].text = "Cancelled draft"
        XCTAssertNotEqual(draft, original)
        // A discarded value has no storage lifecycle or hidden write to cancel.
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        try store.updateText(id: entry.id, content: original, expectedContent: original)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
    }

    @MainActor func testInvalidOversizedAndUnsupportedReplacementNeverTouchSafeFiles() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = PinTextContent(text: "Safe original")
        let entry = try addText(original, to: store)
        let before = store.index, files = try snapshot(directory)
        let invalid = [PinTextContent(text: ""), PinTextContent(runs: []),
            PinTextContent(text: String(repeating: "a", count: PinTextContent.maximumUTF8Bytes + 1)),
            PinTextContent(text: String(repeating: "字", count: PinTextContent.maximumUTF8Bytes / 3 + 1)),
            PinTextContent(runs: Array(repeating: PinTextRun(text: "x"), count: PinTextContent.maximumRuns + 1)),
            PinTextContent(runs: [PinTextRun(text: "HTML")], importedHTML: true),
            PinTextContent(runs: [PinTextRun(text: "Styled", bold: true)]), PinTextContent(text: "a\0b"),
            PinTextContent(text: String(repeating: "\u{1}", count: PinTextContent.maximumUTF8Bytes))]
        var writes = 0; store.failureInjector = { _ in writes += 1 }
        for candidate in invalid {
            XCTAssertThrowsError(try store.updateText(id: entry.id, content: candidate, expectedContent: original))
            XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        }
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testExactUTF8AndRunLimitsAndWhitespaceRemainSupported() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        var current = PinTextContent(text: "Original")
        let entry = try addText(current, to: store)
        let atByteLimit = PinTextContent(text: String(repeating: "字", count: PinTextContent.maximumUTF8Bytes / 3) + "a")
        XCTAssertEqual(atByteLimit.plainText.utf8.count, PinTextContent.maximumUTF8Bytes)
        for replacement in [atByteLimit,
            PinTextContent(runs: Array(repeating: PinTextRun(text: "x"), count: PinTextContent.maximumRuns)),
            PinTextContent(text: " \t\n ")] {
            try store.updateText(id: entry.id, content: replacement, expectedContent: current)
            XCTAssertEqual(try content(entry.id, in: store), replacement)
            current = replacement
        }
    }

    @MainActor func testImportedHTMLAndStyledOriginalsRemainByteForByteUnchanged() throws {
        for original in [PinTextContent(runs: [PinTextRun(text: "HTML", bold: true)], importedHTML: true),
                         PinTextContent(runs: [PinTextRun(text: "Styled", italic: true)])] {
            let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try PinSessionStore(directory: directory)
            let entry = try addText(original, to: store)
            let before = store.index, files = try snapshot(directory)
            XCTAssertThrowsError(try store.updateText(id: entry.id, content: PinTextContent(text: "Replacement"), expectedContent: original))
            XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
            XCTAssertEqual(try content(entry.id, in: PinSessionStore(directory: directory)), original)
        }
    }

    @MainActor func testStaleDraftCannotOverwriteNewTextEvenWhenReplacementMatchesCurrent() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = PinTextContent(text: "Original"), current = PinTextContent(text: "New saved text")
        let entry = try addText(original, to: store)
        try store.updateText(id: entry.id, content: current, expectedContent: original)
        let before = store.index, files = try snapshot(directory)
        for replacement in [PinTextContent(text: "Stale draft"), current] {
            XCTAssertThrowsError(try store.updateText(id: entry.id, content: replacement, expectedContent: original)) {
                XCTAssertEqual($0 as? PinSessionError, .stalePinContent)
            }
            XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        }
    }

    @MainActor func testCapacityFailureKeepsEveryUnprotectedPinAndAllPriorSafeBytes() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let seed = try PinSessionStore(directory: directory)
        let original = PinTextContent(text: String(repeating: "x", count: 100_000))
        let entry = try addText(original, to: seed)
        let unrelated = try addText(String(repeating: "y", count: 100_000), to: seed)
        let budget = seed.entries.reduce(Int64(0)) { $0 + $1.storedByteCount }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxDiskBytes: budget))
        let before = store.index, files = try snapshot(directory)
        let replacement = PinTextContent(text: String(repeating: "x", count: 150_000))
        XCTAssertLessThan(Int64(try JSONEncoder().encode(PinRichDocument(text: replacement)).count), budget)
        XCTAssertThrowsError(try store.updateText(id: entry.id, content: replacement, expectedContent: original)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        XCTAssertNotNil(store.entry(id: unrelated.id))
        XCTAssertEqual(try content(entry.id, in: PinSessionStore(directory: directory)), original)
    }

    @MainActor func testEveryDurableBoundaryRollsBackPayloadPosterManifestAndAllowsRetry() throws {
        for boundary in [CaptureAssetWritePoint.rasterWritten, .documentWritten, .beforeIndexCommit] {
            let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let store = try PinSessionStore(directory: directory)
            let original = PinTextContent(text: "Safe text"), replacement = PinTextContent(text: "New text")
            let entry = try addText(original, to: store)
            let before = store.index, files = try snapshot(directory)
            let cached = try XCTUnwrap(store.thumbnail(id: entry.id))
            var fired = false
            store.failureInjector = { point in
                if point == boundary { fired = true; throw Injected.write }
            }
            XCTAssertThrowsError(try store.updateText(id: entry.id, content: replacement, expectedContent: original))
            XCTAssertTrue(fired)
            XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
            XCTAssertTrue(try XCTUnwrap(store.thumbnail(id: entry.id)) === cached)
            XCTAssertEqual(try content(entry.id, in: store), original)
            store.failureInjector = nil
            try store.updateText(id: entry.id, content: replacement, expectedContent: original)
            XCTAssertEqual(try content(entry.id, in: PinSessionStore(directory: directory)), replacement)
        }
    }

    @MainActor func testAlteredNewPayloadIsRejectedEvenWhenItStillDecodesAsValidText() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = PinTextContent(text: "Original")
        let entry = try addText(original, to: store)
        let before = store.index, files = try snapshot(directory)
        var fired = false
        store.failureInjector = { point in
            guard point == .documentWritten else { return }
            fired = true
            let newFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "pinjson" && files[$0.lastPathComponent] == nil }
            let payload = try XCTUnwrap(newFiles.first)
            XCTAssertEqual(newFiles.count, 1)
            let bytes = try Data(contentsOf: payload)
            var altered = try JSONDecoder().decode(PinRichDocument.self, from: bytes)
            altered.text = PinTextContent(text: "Tampered")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let changed = try encoder.encode(altered)
            XCTAssertEqual(changed.count, bytes.count)
            XCTAssertTrue(altered.isValid)
            try changed.write(to: payload)
        }
        XCTAssertThrowsError(try store.updateText(id: entry.id, content: PinTextContent(text: "New text"), expectedContent: original))
        XCTAssertTrue(fired)
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
        XCTAssertEqual(try content(entry.id, in: store), original)
    }

    @MainActor func testRealManifestWriteFailureDoesNotLoseOldPayloadOrLeaveNewFiles() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = PinTextContent(text: "Safe text")
        let entry = try addText(original, to: store)
        let before = store.index, files = try snapshot(directory)
        let manifest = directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.updateText(id: entry.id, content: PinTextContent(text: "New text"), expectedContent: original))
        XCTAssertEqual(store.index, before)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(names), Set(files.keys))
        for filename in entry.assetFilenames {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(filename)), files[filename])
        }
        try FileManager.default.removeItem(at: manifest)
        try XCTUnwrap(files["index.json"]).write(to: manifest)
        XCTAssertEqual(try content(entry.id, in: PinSessionStore(directory: directory)), original)
    }

    @MainActor func testCorruptExistingTextCannotBeOverwrittenByEditor() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = PinTextContent(text: "Safe original")
        let entry = try addText(original, to: store)
        let rich = try XCTUnwrap(entry.richContent)
        let payload = directory.appendingPathComponent(rich.filename)
        let damaged = Data(repeating: 0x78, count: Int(rich.byteCount))
        try damaged.write(to: payload)
        let before = store.index, files = try snapshot(directory)
        XCTAssertThrowsError(try store.updateText(id: entry.id, content: PinTextContent(text: "New text"), expectedContent: original))
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
    }

    @MainActor func testSymlinkedExistingPayloadIsRejectedWithoutChangingOutsideBytes() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = PinTextContent(text: "Safe original")
        let entry = try addText(original, to: store)
        let before = store.index
        let payload = directory.appendingPathComponent(try XCTUnwrap(entry.richContent).filename)
        let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pinjson")
        defer { try? FileManager.default.removeItem(at: outside) }
        let safe = try Data(contentsOf: payload)
        try safe.write(to: outside)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertThrowsError(try store.updateText(id: entry.id, content: PinTextContent(text: "New text"), expectedContent: original)) {
            XCTAssertEqual($0 as? PinSessionError, .unsafePath)
        }
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(names))
        XCTAssertEqual(try Data(contentsOf: outside), safe)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: payload.path), outside.path)
    }

    @MainActor func testMissingPinAndNonTextPinCannotBeEdited() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let color = try store.add(rich: PreparedRichPin(document: PinRichDocument(color: PinRGBColor(red: 1, green: 2, blue: 3)), title: "Color"))
        let files = try snapshot(directory), before = store.index
        let content = PinTextContent(text: "Text")
        XCTAssertThrowsError(try store.updateText(id: UUID(), content: content, expectedContent: content)) {
            XCTAssertEqual($0 as? PinSessionError, .missingPin)
        }
        XCTAssertThrowsError(try store.updateText(id: color.id, content: content, expectedContent: content))
        XCTAssertEqual(store.index, before); XCTAssertEqual(try snapshot(directory), files)
    }

    @MainActor private func addText(_ text: String, to store: PinSessionStore) throws -> PinSessionEntry {
        try addText(PinTextContent(text: text), to: store)
    }
    @MainActor private func addText(_ content: PinTextContent, to store: PinSessionStore) throws -> PinSessionEntry {
        try store.add(rich: PreparedRichPin(document: PinRichDocument(text: content), title: "Text"))
    }
    @MainActor private func content(_ id: UUID, in store: PinSessionStore) throws -> PinTextContent {
        try XCTUnwrap(JSONDecoder().decode(PinRichDocument.self, from: store.richData(id: id)).text)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotTextUpdateTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
