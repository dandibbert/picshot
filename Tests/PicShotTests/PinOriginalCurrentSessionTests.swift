import XCTest
import AppKit
import Combine
import PicShotCore
@testable import PicShot

final class PinOriginalCurrentSessionTests: XCTestCase {
    @MainActor func testDecoratedAddPublishesOneCompletePairAndReloadsExactPixels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let group = try store.createGroup(name: "Decorated", color: .purple)
        try store.setGroupHidden(id: group.id, hidden: true)
        try store.setAllHidden(true)
        let original = try image(width: 12, height: 8, seed: 1)
        let current = try image(width: 20, height: 14, seed: 2)
        let sourcePixels = try pixels(original), decoratedPixels = try pixels(current)
        let presentation = PinPresentation(frame: PinWindowFrame(x: 12, y: 34, width: 320, height: 240),
                                           opacity: 0.7, zoom: 2, clickThrough: true, locked: true)
        var publications: [PinSessionIndex] = []
        let subscription = store.$index.dropFirst().sink { publications.append($0) }
        defer { subscription.cancel() }

        let entry = try store.add(originalImage: original, currentImage: current, title: "  Decorated source  ",
                                  groupID: group.id, presentation: presentation, revealingGroup: true)

        XCTAssertEqual(publications, [store.index], "A new decorated pin must never publish an original-only entry")
        XCTAssertEqual(entry.title, "Decorated source")
        XCTAssertEqual(entry.groupID, group.id)
        XCTAssertEqual(entry.presentation, presentation)
        XCTAssertNotEqual(entry.original.filename, entry.current.filename)
        XCTAssertEqual(entry.assets.count, 2)
        XCTAssertEqual(store.index.activeGroupID, group.id)
        XCTAssertFalse(store.index.allHidden)
        XCTAssertFalse(try XCTUnwrap(store.groups.first { $0.id == group.id }).isHidden)
        XCTAssertEqual(try files(directory), Set(["index.json"] + entry.assetFilenames))
        XCTAssertEqual(try pixels(original), sourcePixels, "Persisting the decorated output must not mutate its source")
        XCTAssertEqual(try pixels(current), decoratedPixels)

        let restored = try PinSessionStore(directory: directory)
        XCTAssertEqual(restored.index, store.index)
        XCTAssertEqual(try pixels(XCTUnwrap(restored.image(id: entry.id, original: true))), sourcePixels)
        XCTAssertEqual(try pixels(XCTUnwrap(restored.image(id: entry.id))), decoratedPixels)
        XCTAssertEqual(restored.image(id: entry.id, original: true)?.width, 12)
        XCTAssertEqual(restored.image(id: entry.id)?.width, 20)
        XCTAssertEqual(try files(directory), Set(["index.json"] + entry.assetFilenames))
    }

    @MainActor func testEqualDimensionsDoNotConflateDifferentSourceAndCurrentPixels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = try image(width: 8, height: 8, seed: 11)
        let current = try image(width: 8, height: 8, seed: 22)
        XCTAssertNotEqual(try pixels(original), try pixels(current))
        let entry = try store.add(originalImage: original, currentImage: current)
        let restored = try PinSessionStore(directory: directory)
        XCTAssertEqual(try pixels(XCTUnwrap(restored.image(id: entry.id, original: true))), try pixels(original))
        XCTAssertEqual(try pixels(XCTUnwrap(restored.image(id: entry.id))), try pixels(current))
        XCTAssertNotEqual(entry.original.filename, entry.current.filename)
    }

    @MainActor func testLegacyAndSharedImageAddsStoreAndBudgetOneAssetEach() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPins: 2, maxPixelCount: 192))
        let original = try image(width: 12, height: 8)
        let legacy = try store.add(image: original)
        let shared = try store.add(originalImage: original, currentImage: original, protecting: [legacy.id])
        XCTAssertEqual(store.entries.count, 2)
        for entry in [legacy, shared] {
            XCTAssertEqual(entry.original, entry.current)
            XCTAssertEqual(entry.assets.count, 1)
        }
        XCTAssertEqual(try files(directory), Set(["index.json", legacy.original.filename, shared.original.filename]))
        XCTAssertEqual(try PinSessionStore(directory: directory, policy: store.policy).index, store.index)
    }

    @MainActor func testPixelBudgetsCountBothAssetsAndRollBackEitherRasterFailure() throws {
        // Both individually fit but their sum fails; then source/current individually exceed the cap.
        for (originalWidth, currentWidth, limit) in [(10, 5, 149), (16, 1, 150), (1, 16, 150)] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPixelCount: Int64(limit)))
            let original = try image(width: originalWidth, height: 10)
            let current = try image(width: currentWidth, height: 10, seed: 2)
            let before = store.index, beforeFiles = try fileBytes(directory)
            var publications = 0
            let subscription = store.$index.dropFirst().sink { _ in publications += 1 }
            defer { subscription.cancel() }

            XCTAssertThrowsError(try store.add(originalImage: original, currentImage: current, revealingGroup: true)) {
                XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
            }
            XCTAssertEqual(store.index, before)
            XCTAssertEqual(try fileBytes(directory), beforeFiles, "Failed admission must remove every staged PNG and temporary file")
            XCTAssertEqual(publications, 0)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPixelCount: 150))
        let entry = try store.add(originalImage: image(width: 10, height: 10), currentImage: image(width: 5, height: 10))
        XCTAssertEqual(entry.assets.reduce(0) { $0 + $1.pixelCount }, 150, "The inclusive boundary must admit the complete pair")
    }

    @MainActor func testDiskBudgetCountsBothPNGsAndDoesNotEvictExistingPinOnFailure() throws {
        let directory = try temporaryDirectory(), probeDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: probeDirectory)
        }
        let original = try image(width: 16, height: 12, seed: 1)
        let current = try image(width: 20, height: 14, seed: 2)
        let probe = try PinSessionStore(directory: probeDirectory)
        let pair = try probe.add(originalImage: original, currentImage: current)
        let limit = pair.storedByteCount - 1
        XCTAssertLessThanOrEqual(pair.original.byteCount, limit)
        XCTAssertLessThanOrEqual(pair.current.byteCount, limit)
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxDiskBytes: limit))
        let previous = try store.add(image: image(width: 1, height: 1))
        let before = store.index, beforeFiles = try fileBytes(directory)

        XCTAssertThrowsError(try store.add(originalImage: original, currentImage: current)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(try fileBytes(directory), beforeFiles)
        XCTAssertNotNil(store.image(id: previous.id))
        XCTAssertEqual(try PinSessionStore(directory: directory, policy: store.policy).index, before)
    }

    @MainActor func testSecondPNGExceedingDiskLimitRemovesAlreadyStagedOriginal() throws {
        let directory = try temporaryDirectory(), probeDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: probeDirectory)
        }
        let original = try image(width: 2, height: 2)
        let current = try image(width: 64, height: 64, seed: 3)
        let probe = try PinSessionStore(directory: probeDirectory)
        let pair = try probe.add(originalImage: original, currentImage: current)
        let limit = pair.current.byteCount - 1
        XCTAssertLessThan(pair.original.byteCount, limit)
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxDiskBytes: limit))
        let before = store.index, beforeFiles = try fileBytes(directory)

        XCTAssertThrowsError(try store.add(originalImage: original, currentImage: current)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(try fileBytes(directory), beforeFiles)
    }

    @MainActor func testPairAtExactDiskLimitSucceedsAndEvictsOnlyAfterCommit() throws {
        let directory = try temporaryDirectory(), probeDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: probeDirectory)
        }
        let original = try image(width: 12, height: 8), current = try image(width: 14, height: 10, seed: 2)
        let probe = try PinSessionStore(directory: probeDirectory)
        let pair = try probe.add(originalImage: original, currentImage: current)
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPins: 1, maxDiskBytes: pair.storedByteCount))
        let previous = try store.add(image: image(width: 1, height: 1))
        let entry = try store.add(originalImage: original, currentImage: current)
        XCTAssertEqual(entry.storedByteCount, pair.storedByteCount)
        XCTAssertNil(store.entry(id: previous.id))
        XCTAssertEqual(store.entries, [entry])
        XCTAssertEqual(try files(directory), Set(["index.json"] + entry.assetFilenames))
        XCTAssertEqual(try PinSessionStore(directory: directory, policy: store.policy).index, store.index)
    }

    @MainActor func testCoordinatorKeepsOriginalAndDecoratedPixelsAcrossCloseAndLaunchThenReset() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let session = coordinator(store)
        defer { try? session.prepareForTermination() }
        let original = try image(width: 12, height: 8), current = try image(width: 20, height: 14, seed: 2)
        let id = try session.add(originalImage: original, currentImage: current)
        let first = try XCTUnwrap(session.liveControllers[id])
        XCTAssertTrue(first.image === original)
        XCTAssertTrue(first.currentImage === current)
        let entry = try XCTUnwrap(store.entry(id: id))
        let sourcePNG = try Data(contentsOf: directory.appendingPathComponent(entry.original.filename))
        first.close()
        XCTAssertEqual(store.entry(id: id)?.isVisible, false)
        try session.openPin(id: id)
        let reopened = try XCTUnwrap(session.liveControllers[id])
        XCTAssertEqual(try pixels(reopened.image), try pixels(original))
        XCTAssertEqual(try pixels(reopened.currentImage), try pixels(current))
        try session.prepareForTermination()

        let restoredStore = try PinSessionStore(directory: directory)
        let restored = coordinator(restoredStore)
        defer { try? restored.prepareForTermination() }
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        let controller = try XCTUnwrap(restored.liveControllers[id])
        XCTAssertEqual(try pixels(controller.image), try pixels(original))
        XCTAssertEqual(try pixels(controller.currentImage), try pixels(current))
        try controller.restoreOriginalImage()
        XCTAssertEqual(try pixels(controller.currentImage), try pixels(original), "Restored decorated pins must retain their modified state")
        XCTAssertEqual(restoredStore.entry(id: id)?.original, entry.original)
        XCTAssertEqual(restoredStore.entry(id: id)?.current, entry.original)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(entry.original.filename)), sourcePNG)
        XCTAssertEqual(try files(directory), Set(["index.json", entry.original.filename]))
    }

    @MainActor func testNewDecoratedPinCanImmediatelyResetWhileUnmodifiedAddsSharePixels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let session = coordinator(store)
        defer { try? session.prepareForTermination() }
        let original = try image(width: 12, height: 8), current = try image(width: 20, height: 14, seed: 2)
        let decoratedID = try session.add(originalImage: original, currentImage: current)
        let decorated = try XCTUnwrap(session.liveControllers[decoratedID])
        try decorated.restoreOriginalImage()
        XCTAssertTrue(decorated.currentImage === original, "The initial controller must know its decorated output is modified")
        XCTAssertEqual(store.entry(id: decoratedID)?.original, store.entry(id: decoratedID)?.current)

        let sharedID = try session.add(originalImage: original, currentImage: original)
        let legacyID = try session.add(image: original)
        for id in [sharedID, legacyID] {
            let controller = try XCTUnwrap(session.liveControllers[id])
            XCTAssertTrue(controller.image === original)
            XCTAssertTrue(controller.currentImage === original)
            let before = try fileBytes(directory)
            try controller.restoreOriginalImage()
            XCTAssertEqual(try fileBytes(directory), before, "Unmodified reset must not rewrite the session")
            XCTAssertEqual(store.entry(id: id)?.assets.count, 1)
        }
        XCTAssertEqual(try files(directory).count, 4)
    }

    @MainActor func testFailedCoordinatorCommitRollsBackBothPNGsEvictionAndVisibility() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPins: 1))
        let previous = try store.add(image: image(width: 2, height: 2))
        try store.setGroupHidden(id: PinGroup.defaultID, hidden: true)
        try store.setAllHidden(true)
        let before = store.index, beforeFiles = try fileBytes(directory)
        let manifest = directory.appendingPathComponent("index.json")
        let originalManifest = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        var candidate: PinController?
        let session = coordinator(store) { original, current, modified in
            XCTAssertTrue(modified)
            let controller = PinController(originalImage: original, currentImage: current, isModified: modified, defaults: nil)
            candidate = controller
            return controller
        }
        defer { try? session.prepareForTermination() }
        var publications = 0
        let subscription = store.$index.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }

        XCTAssertThrowsError(try session.add(originalImage: image(width: 12, height: 8), currentImage: image(width: 20, height: 14)))
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(session.liveControllers.isEmpty)
        XCTAssertNotNil(candidate)
        XCTAssertNil(candidate?.window?.contentView, "The rejected controller must close before the add error escapes")
        XCTAssertEqual(try files(directory), Set(beforeFiles.keys))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(previous.original.filename)), beforeFiles[previous.original.filename])
        try FileManager.default.removeItem(at: manifest)
        try originalManifest.write(to: manifest)
        XCTAssertEqual(try fileBytes(directory), beforeFiles)
        XCTAssertEqual(try PinSessionStore(directory: directory, policy: store.policy).index, before)
    }

    @MainActor func testDecoratedAddCannotEvictLiveOrProtectedPins() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPins: 1))
        let session = coordinator(store)
        defer { try? session.prepareForTermination() }
        let id = try session.add(image: image(width: 2, height: 2))
        let live = try XCTUnwrap(session.liveControllers[id])
        let before = store.index, beforeFiles = try fileBytes(directory)
        let original = try image(width: 12, height: 8), current = try image(width: 20, height: 14)
        XCTAssertThrowsError(try session.add(originalImage: original, currentImage: current)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertTrue(session.liveControllers[id] === live)
        XCTAssertEqual(session.livePinCount, 1)
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(try fileBytes(directory), beforeFiles)

        live.close()
        try store.setGroupProtected(id: PinGroup.defaultID, protected: true)
        let protectedIndex = store.index, protectedFiles = try fileBytes(directory)
        XCTAssertThrowsError(try session.add(originalImage: original, currentImage: current)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertTrue(session.liveControllers.isEmpty)
        XCTAssertEqual(store.index, protectedIndex)
        XCTAssertEqual(try fileBytes(directory), protectedFiles)
    }

    @MainActor private func coordinator(_ store: PinSessionStore,
                                       makeController: (@MainActor (CGImage, CGImage, Bool) -> PinController)? = nil) -> PinSessionCoordinator {
        _ = NSApplication.shared
        return PinSessionCoordinator(store: store, presentWindows: false,
                                     desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
                                     ocrPreferences: PinOCRPreferences(defaults: nil),
                                     makeImageController: makeController,
                                     screens: { [CGRect(x: 0, y: 0, width: 1440, height: 900)] })
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotOriginalCurrent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func files(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private func fileBytes(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: files(directory).map { name in
            (name, try Data(contentsOf: directory.appendingPathComponent(name)))
        })
    }

    private func image(width: Int, height: Int, seed: UInt32 = 1) throws -> CGImage {
        // Opaque sRGB bytes make exact lossless comparison independent of PNG storage layout.
        var value = seed
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            for channel in 0..<3 {
                value = value &* 1_664_525 &+ 1_013_904_223
                rgba[offset + channel] = UInt8(truncatingIfNeeded: value >> 24)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try Data(bytes: XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}
