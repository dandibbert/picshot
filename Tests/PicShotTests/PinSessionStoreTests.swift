import XCTest
import AppKit
import CoreGraphics
import PicShotCore
@testable import PicShot

final class PinSessionStoreTests: XCTestCase {
    @MainActor func testDiskRestoreKeepsOriginalEditedImageAndPresentation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try image(width: 12, height: 8, red: 1)
        let edited = try image(width: 7, height: 5, red: 0)
        let store = try PinSessionStore(directory: directory)
        let group = try store.createGroup(name: "设计", color: .purple)
        try store.setActiveGroup(id: group.id)
        let presentation = PinPresentation(frame: PinWindowFrame(x: -1200, y: 42, width: 460, height: 360),
                                           opacity: 0.4, zoom: 2, clickThrough: true, locked: true)
        let entry = try store.add(image: original, title: "参考", presentation: presentation)
        try store.replaceImage(edited, id: entry.id)
        let restored = try PinSessionStore(directory: directory)
        let saved = try XCTUnwrap(restored.entry(id: entry.id))
        XCTAssertEqual(saved.groupID, group.id); XCTAssertEqual(saved.presentation, presentation)
        XCTAssertEqual(saved.original.filename, entry.original.filename)
        XCTAssertNotEqual(saved.original.filename, saved.current.filename)
        XCTAssertEqual(restored.image(id: entry.id, original: true)?.width, 12)
        XCTAssertEqual(restored.image(id: entry.id, original: true)?.height, 8)
        XCTAssertEqual(restored.image(id: entry.id)?.width, 7)
        XCTAssertEqual(restored.image(id: entry.id)?.height, 5)
        XCTAssertEqual(try pngFiles(directory).count, 2)
        XCTAssertEqual(restored.visibleEntries.map(\.id), [entry.id])
    }

    @MainActor func testResetAndExplicitRemovalCleanOnlySessionAssets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appendingPathComponent("reference.png")
        try Data("leave me".utf8).write(to: unrelated)
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(image: image())
        try store.replaceImage(image(width: 5, height: 3), id: entry.id)
        let editedName = try XCTUnwrap(store.entry(id: entry.id)?.current.filename)
        try store.resetImage(id: entry.id)
        XCTAssertEqual(store.entry(id: entry.id)?.current, entry.original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(editedName).path))
        XCTAssertEqual(store.image(id: entry.id)?.width, 10)
        try store.remove(id: entry.id)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.original.filename).path))
        XCTAssertEqual(try String(contentsOf: unrelated), "leave me")
        try store.remove(id: entry.id) // Repeated close is harmless.
        XCTAssertTrue(try PinSessionStore(directory: directory).entries.isEmpty)
    }

    @MainActor func testDeleteGroupReassignsAndPersistsWithoutDeletingImages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let group = try store.createGroup(name: "组一", color: .green)
        try store.setActiveGroup(id: group.id)
        let entry = try store.add(image: image())
        try store.setGroupProtected(id: group.id, protected: true)
        try store.setGroupHidden(id: group.id, hidden: true)
        try store.deleteGroup(id: group.id)
        let restored = try PinSessionStore(directory: directory)
        XCTAssertEqual(restored.entry(id: entry.id)?.groupID, PinGroup.defaultID)
        XCTAssertEqual(restored.index.activeGroupID, PinGroup.defaultID)
        XCTAssertNotNil(restored.image(id: entry.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.original.filename).path))
        XCTAssertThrowsError(try restored.deleteGroup(id: PinGroup.defaultID))
    }

    @MainActor func testMoveRenameHideShowAndSwitchSurviveRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(image: image())
        let group = try store.createGroup(name: "One")
        try store.renameGroup(id: group.id, name: "Two", color: .orange)
        try store.movePin(id: entry.id, to: group.id)
        try store.renamePin(id: entry.id, title: "Example")
        XCTAssertTrue(store.visibleEntries.isEmpty)
        try store.setActiveGroup(id: group.id)
        XCTAssertEqual(store.visibleEntries.map(\.id), [entry.id])
        try store.setGroupHidden(id: group.id, hidden: true)
        XCTAssertTrue(store.visibleEntries.isEmpty)
        try store.showActiveGroup(); XCTAssertEqual(store.visibleEntries.count, 1)
        try store.setAllHidden(true)
        let restored = try PinSessionStore(directory: directory)
        XCTAssertTrue(restored.index.allHidden); XCTAssertTrue(restored.visibleEntries.isEmpty)
        XCTAssertEqual(restored.groups.last?.name, "Two"); XCTAssertEqual(restored.groups.last?.color, .orange)
        XCTAssertEqual(restored.entry(id: entry.id)?.title, "Example")
        try restored.showActiveGroup(); XCTAssertEqual(restored.visibleEntries.count, 1)
        XCTAssertEqual(try pngFiles(directory).count, 1)
    }

    @MainActor func testCorruptManifestIsNotOverwrittenAndImagesAreNotCleaned() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(image: image())
        let manifest = directory.appendingPathComponent("index.json")
        let corrupt = Data("{not json".utf8); try corrupt.write(to: manifest)
        XCTAssertThrowsError(try PinSessionStore(directory: directory)) { XCTAssertEqual($0 as? PinSessionError, .invalidManifest) }
        XCTAssertEqual(try Data(contentsOf: manifest), corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.original.filename).path))
    }

    @MainActor func testTraversalManifestCannotReadOrDeleteAnOutsideImage() async throws {
        let parent = try temporaryDirectory(), directory = parent.appendingPathComponent("session")
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside.png")
        try image().writePNG(to: outside)
        let before = try Data(contentsOf: outside)
        let store = try PinSessionStore(directory: directory)
        var malicious = store.index
        malicious.entries = [PinSessionEntry(original: PinRasterAsset(filename: "../outside.png", width: 10, height: 10, byteCount: Int64(before.count)))]
        let manifest = directory.appendingPathComponent("index.json")
        let encoded = try JSONEncoder().encode(malicious); try encoded.write(to: manifest)
        XCTAssertThrowsError(try PinSessionStore(directory: directory)) { XCTAssertEqual($0 as? PinSessionError, .unsafePath) }
        XCTAssertEqual(try Data(contentsOf: outside), before)
        XCTAssertEqual(try Data(contentsOf: manifest), encoded)
    }

    @MainActor func testSymbolicAssetAndManifestPathsAreRejectedWithoutTouchingTheirTargets() async throws {
        let parent = try temporaryDirectory(), directory = parent.appendingPathComponent("session")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(image: image())
        let outside = parent.appendingPathComponent("outside.png")
        try image().writePNG(to: outside)
        let originalBytes = try Data(contentsOf: outside)
        let assetURL = directory.appendingPathComponent(entry.original.filename)
        try FileManager.default.removeItem(at: assetURL)
        try FileManager.default.createSymbolicLink(at: assetURL, withDestinationURL: outside)
        XCTAssertThrowsError(try PinSessionStore(directory: directory)) { XCTAssertEqual($0 as? PinSessionError, .unsafePath) }
        XCTAssertNil(store.image(id: entry.id))
        XCTAssertEqual(try Data(contentsOf: outside), originalBytes)
        let manifest = directory.appendingPathComponent("index.json")
        let externalManifest = parent.appendingPathComponent("outside.json")
        try Data("external".utf8).write(to: externalManifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: externalManifest)
        XCTAssertThrowsError(try PinSessionStore(directory: directory)) { XCTAssertEqual($0 as? PinSessionError, .unsafePath) }
        XCTAssertEqual(try String(contentsOf: externalManifest), "external")
        try FileManager.default.removeItem(at: externalManifest)
        XCTAssertThrowsError(try PinSessionStore(directory: directory)) { XCTAssertEqual($0 as? PinSessionError, .unsafePath) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalManifest.path))
    }

    @MainActor func testMissingAndCorruptPNGEntriesAreDroppedWithoutRasterDecode() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let missing = try store.add(image: image())
        let corrupt = try store.add(image: image())
        let good = try store.add(image: image())
        try FileManager.default.removeItem(at: directory.appendingPathComponent(missing.original.filename))
        try Data("not png".utf8).write(to: directory.appendingPathComponent(corrupt.original.filename))
        let restored = try PinSessionStore(directory: directory)
        XCTAssertEqual(restored.entries.map(\.id), [good.id])
        XCTAssertNotNil(restored.image(id: good.id))
        XCTAssertEqual(try pngFiles(directory).count, 1)
    }

    @MainActor func testHealthyReloadRemovesOrphanAndTemporaryAssetsButLeavesOtherFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(image: image())
        let orphan = directory.appendingPathComponent(UUID().uuidString + ".png")
        let temporary = directory.appendingPathComponent(".pin-write-" + UUID().uuidString + ".png")
        let other = directory.appendingPathComponent("notes.txt")
        for file in [orphan, temporary, other] { try Data("stale".utf8).write(to: file) }
        let restored = try PinSessionStore(directory: directory)
        XCTAssertNotNil(restored.image(id: entry.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    @MainActor func testProtectedAndLivePinCapacityFailuresLeaveManifestAndAssetsUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = PinSessionPolicy(maxPins: 1)
        let store = try PinSessionStore(directory: directory, policy: policy)
        let entry = try store.add(image: image())
        try store.setGroupProtected(id: PinGroup.defaultID, protected: true)
        let manifest = directory.appendingPathComponent("index.json")
        let before = try Data(contentsOf: manifest)
        XCTAssertThrowsError(try store.add(image: image())) { XCTAssertEqual($0 as? PinSessionError, .capacityExceeded) }
        XCTAssertEqual(store.entries.map(\.id), [entry.id]); XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertEqual(try pngFiles(directory).count, 1)
        try store.setGroupProtected(id: PinGroup.defaultID, protected: false)
        XCTAssertThrowsError(try store.add(image: image(), protecting: [entry.id]))
        XCTAssertEqual(store.entries.map(\.id), [entry.id]); XCTAssertEqual(try pngFiles(directory).count, 1)
        let replacement = try store.add(image: image())
        XCTAssertEqual(store.entries.map(\.id), [replacement.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.original.filename).path))
        XCTAssertEqual(try pngFiles(directory).count, 1)
    }

    @MainActor func testEditedRasterBudgetFailurePreservesOriginalAndCurrent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPixelCount: 150))
        let entry = try store.add(image: image(width: 10, height: 10))
        XCTAssertThrowsError(try store.replaceImage(image(width: 8, height: 8), id: entry.id)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertEqual(store.entry(id: entry.id)?.current, entry.original)
        XCTAssertEqual(try pngFiles(directory).count, 1)
        try store.replaceImage(image(width: 5, height: 10), id: entry.id)
        XCTAssertEqual(try pngFiles(directory).count, 2)
        XCTAssertEqual(store.image(id: entry.id)?.width, 5)
    }

    @MainActor func testFailedManifestCommitRollsBackNewPNGAndInMemoryMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(image: image())
        let before = store.index
        let manifest = directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.add(image: image()))
        XCTAssertThrowsError(try store.replaceImage(image(width: 6, height: 6), id: entry.id))
        XCTAssertThrowsError(try store.updatePresentation(PinPresentation(opacity: 0.4), id: entry.id))
        XCTAssertEqual(store.index, before); XCTAssertEqual(try pngFiles(directory).count, 1)
        XCTAssertNotNil(store.image(id: entry.id))
    }

    @MainActor func testThumbnailUsesBoundedPreviewAndCanReleaseItsCache() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(image: image(width: 1600, height: 600))
        let first = try XCTUnwrap(store.thumbnail(id: entry.id))
        XCTAssertLessThanOrEqual(first.size.width, 512); XCTAssertLessThanOrEqual(first.size.height, 512)
        XCTAssertTrue(store.thumbnail(id: entry.id) === first)
        store.clearThumbnailCache()
        XCTAssertFalse(store.thumbnail(id: entry.id) === first)
        XCTAssertEqual(store.image(id: entry.id)?.width, 1600)
    }

    @MainActor func testThumbnailCacheHasHardByteAndCountBounds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let raster = try image(width: 600, height: 600)
        for _ in 0..<20 {
            let entry = try store.add(image: raster)
            XCTAssertNotNil(store.thumbnail(id: entry.id))
            XCTAssertLessThanOrEqual(store.thumbnailCacheCost, 12 * 1_024 * 1_024)
            XCTAssertLessThanOrEqual(store.cachedThumbnailCount, 24)
        }
        store.clearThumbnailCache()
        XCTAssertEqual(store.thumbnailCacheCost, 0); XCTAssertEqual(store.cachedThumbnailCount, 0)
    }

    @MainActor func testPresentationRecoveryMakesClickThroughPinReachableWithoutChangingSavedIntent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let saved = PinPresentation(frame: PinWindowFrame(x: 9000, y: -4000, width: 600, height: 400),
                                    opacity: 0.3, zoom: 0.5, clickThrough: true, locked: true)
        let entry = try store.add(image: image(), presentation: saved)
        let screen = CGRect(x: 0, y: 20, width: 1440, height: 850)
        let recovered = try XCTUnwrap(store.recoveredPresentation(id: entry.id, screens: [screen]))
        XCTAssertTrue(screen.contains(recovered.frame.rect)); XCTAssertEqual(recovered.opacity, 0.3)
        XCTAssertTrue(recovered.clickThrough); XCTAssertTrue(recovered.locked)
        XCTAssertEqual(store.entry(id: entry.id)?.presentation, saved)
    }

    @MainActor func testGroupManagerCanCloseAndReopenWithoutChangingSavedPinsOrRetainingItself() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(image: image())
        var controller: PinGroupsController? = PinGroupsController(store: store)
        weak var weakController = controller
        XCTAssertNotNil(controller?.window?.contentView)
        controller?.close(); controller?.reload()
        XCTAssertEqual(store.entries.map(\.id), [entry.id])
        XCTAssertNotNil(controller?.window?.contentView)
        controller = nil
        XCTAssertNil(weakController, "The Combine subscription must not retain the manager")
    }

    private func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotPinTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func pngFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { PinRasterAsset.isSafeFilename($0.lastPathComponent) }
    }
    private func image(width: Int = 10, height: Int = 10, red: CGFloat = 0.5) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
