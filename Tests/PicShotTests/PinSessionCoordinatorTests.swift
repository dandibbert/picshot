import XCTest
import AppKit
import Combine
import PicShotCore
@testable import PicShot

final class PinSessionCoordinatorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @MainActor func testExplicitCloseArchivesSessionEntryAndDetachesCachedWindow() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Drain construction and close temporaries before testing controller ownership.
        let (id, probe) = try autoreleasepool { () throws -> (UUID, ClosedPinLifetimeProbe) in
            let id = try coordinator.add(image: image())
            let controller = try XCTUnwrap(coordinator.liveControllers[id])
            let probe = try ClosedPinLifetimeProbe(controller)
            controller.close()
            XCTAssertNil(controller.onClose); XCTAssertNil(controller.onPixelChange)
            XCTAssertNil(controller.onPresentationChange)
            XCTAssertNil(probe.window.contentView); XCTAssertNil(probe.window.delegate)
            controller.close() // Repeated close is harmless.
            return (id, probe)
        }
        try await assertReleased(probe)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertEqual(store.entry(id: id)?.isVisible, false)
        XCTAssertNotNil(store.image(id: id)); XCTAssertEqual(try pngNames(directory).count, 1)
        XCTAssertTrue(store.visibleEntries.isEmpty)
    }

    @MainActor func testSwitchFlushesPresentationAndReleasesOldControllerWithoutDeletingPin() async throws {
        let (directory, store, coordinator) = try fixture(debounce: 30_000_000_000)
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let other = try store.createGroup(name: "Other")
        let (id, expected, probe) = try autoreleasepool { () throws -> (UUID, PinPresentation, ClosedPinLifetimeProbe) in
            let id = try coordinator.add(image: image())
            let controller = try XCTUnwrap(coordinator.liveControllers[id])
            let probe = try ClosedPinLifetimeProbe(controller)
            let before = try XCTUnwrap(store.entry(id: id)?.presentation)
            controller.applyPresentation(examplePresentation())
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: probe.window))
            let expected = controller.presentation
            XCTAssertEqual(store.entry(id: id)?.presentation, before, "Moves must be debounced")
            try coordinator.switchGroup(id: other.id)
            XCTAssertNil(probe.window.contentView); XCTAssertNil(probe.window.delegate)
            return (id, expected, probe)
        }
        try await assertReleased(probe)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertEqual(store.entry(id: id)?.presentation, expected)
        XCTAssertEqual(store.entry(id: id)?.isVisible, true)
        try autoreleasepool {
            try coordinator.switchGroup(id: PinGroup.defaultID)
            XCTAssertEqual(coordinator.liveControllers.count, 1)
            XCTAssertEqual(coordinator.liveControllers[id]?.presentation, expected)
        }
        XCTAssertEqual(try pngNames(directory).count, 1)
    }

    @MainActor func testRepeatedHideShowDoesNotDuplicateWindowsOrRetainHiddenImages() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try autoreleasepool { try coordinator.add(image: image()) }
        let asset = try XCTUnwrap(store.entry(id: id)?.original)
        var closed: [ClosedPinLifetimeProbe] = []
        for _ in 0..<16 {
            let probe = try autoreleasepool { () throws -> ClosedPinLifetimeProbe in
                let controller = try XCTUnwrap(coordinator.liveControllers[id])
                let probe = try ClosedPinLifetimeProbe(controller)
                try coordinator.hideCurrentGroup()
                return probe
            }
            closed.append(probe)
            try await assertReleased(probe)
            XCTAssertTrue(coordinator.liveControllers.isEmpty)
            XCTAssertEqual(store.entry(id: id)?.original, asset)
            XCTAssertEqual(store.entry(id: id)?.isVisible, true)
            try autoreleasepool {
                try coordinator.showCurrentGroup()
                let first = try XCTUnwrap(coordinator.liveControllers[id])
                try coordinator.showCurrentGroup(); try coordinator.reconcileVisiblePins()
                XCTAssertTrue(coordinator.liveControllers[id] === first)
                XCTAssertEqual(coordinator.liveControllers.count, 1)
            }
        }
        let last = try autoreleasepool { () throws -> ClosedPinLifetimeProbe in
            let probe = try ClosedPinLifetimeProbe(XCTUnwrap(coordinator.liveControllers[id]))
            try coordinator.hideAll()
            return probe
        }
        closed.append(last)
        for probe in closed { try await assertReleased(probe) }
        XCTAssertTrue(store.index.allHidden); XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertEqual(try pngNames(directory), [asset.filename])
    }

    @MainActor func testRestorationLoadsDistinctOriginalAndCurrentAndResetUsesOriginalAsset() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let entry = try store.add(image: image(width: 12, height: 8))
        try store.replaceImage(image(width: 5, height: 3), id: entry.id)
        try coordinator.restoreOnLaunch(enabled: true, isSmoke: false)
        let controller = try XCTUnwrap(coordinator.liveControllers[entry.id])
        XCTAssertEqual(controller.image.width, 12); XCTAssertEqual(controller.image.height, 8)
        XCTAssertEqual(controller.currentImage.width, 5); XCTAssertEqual(controller.currentImage.height, 3)
        XCTAssertTrue(controller.window?.title.contains("已修改") == true)
        try controller.restoreOriginalImage()
        XCTAssertTrue(controller.currentImage === controller.image)
        XCTAssertEqual(store.entry(id: entry.id)?.current, entry.original)
        XCTAssertEqual(try pngNames(directory), [entry.original.filename])
        XCTAssertFalse(controller.window?.title.contains("已修改") == true)
    }

    @MainActor func testPresentationWritesNeverRewritePixelsAndActualEditsDo() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image(width: 12, height: 8))
        let controller = try XCTUnwrap(coordinator.liveControllers[id])
        let original = try XCTUnwrap(store.entry(id: id)?.original)
        let originalBytes = try Data(contentsOf: directory.appendingPathComponent(original.filename))
        controller.applyPresentation(examplePresentation())
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: controller.window))
        try coordinator.flushPresentationChanges()
        XCTAssertEqual(store.entry(id: id)?.presentation, controller.presentation)
        XCTAssertEqual(try pngNames(directory), [original.filename])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(original.filename)), originalBytes)
        try controller.applyTransform(.rotateClockwise)
        let edited = try XCTUnwrap(store.entry(id: id)?.current)
        XCTAssertNotEqual(edited.filename, original.filename)
        XCTAssertEqual(edited.width, 8); XCTAssertEqual(edited.height, 12)
        XCTAssertEqual(try pngNames(directory).count, 2)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: controller.window))
        try coordinator.flushPresentationChanges()
        XCTAssertEqual(store.entry(id: id)?.current.filename, edited.filename)
        try controller.restoreOriginalImage()
        XCTAssertEqual(try pngNames(directory), [original.filename])
        let afterReset = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        try controller.restoreOriginalImage() // An unmodified reset must not write anything.
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), afterReset)
    }

    @MainActor func testFailedPixelPersistenceRollsBackLiveEdit() async throws {
        let (directory, store, coordinator) = try fixture(policy: PinSessionPolicy(maxPixelCount: 150))
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image())
        let controller = try XCTUnwrap(coordinator.liveControllers[id])
        let original = controller.currentImage
        let before = store.index
        XCTAssertThrowsError(try controller.applyTransform(.rotateClockwise)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertTrue(controller.currentImage === original)
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(try pngNames(directory).count, 1)
    }

    @MainActor func testLivePinsCannotBeEvictedButHiddenUnprotectedPinsCan() async throws {
        let (directory, store, coordinator) = try fixture(policy: PinSessionPolicy(maxPins: 1))
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let firstID = try coordinator.add(image: image())
        XCTAssertThrowsError(try coordinator.add(image: image())) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertEqual(Set(coordinator.liveControllers.keys), [firstID])
        XCTAssertNotNil(store.entry(id: firstID))
        try coordinator.hideAll()
        let secondID = try coordinator.add(image: image())
        XCTAssertNil(store.entry(id: firstID)); XCTAssertNotNil(store.entry(id: secondID))
        XCTAssertEqual(Set(coordinator.liveControllers.keys), [secondID])
        XCTAssertEqual(try pngNames(directory).count, 1)
    }

    @MainActor func testLaunchPreferenceAndSmokeGuardsNeverRestoreWindows() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let active = try store.add(image: image())
        let group = try store.createGroup(name: "Hidden")
        _ = try store.add(image: image(), groupID: group.id)
        try store.setGroupHidden(id: group.id, hidden: true)
        try coordinator.restoreOnLaunch(enabled: false, isSmoke: false)
        try coordinator.restoreOnLaunch(enabled: true, isSmoke: true)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertEqual(store.cachedThumbnailCount, 0)
        try coordinator.restoreOnLaunch(enabled: true, isSmoke: false)
        XCTAssertEqual(Set(coordinator.liveControllers.keys), [active.id])
        let controller = try XCTUnwrap(coordinator.liveControllers[active.id])
        try coordinator.restoreOnLaunch(enabled: true, isSmoke: false)
        XCTAssertTrue(coordinator.liveControllers[active.id] === controller)
    }

    @MainActor func testNewPinDoesNotImplicitlyRestorePreviousLaunchSession() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let previous = try store.add(image: image())
        try coordinator.restoreOnLaunch(enabled: false, isSmoke: false)
        let newID = try coordinator.add(image: image())
        XCTAssertEqual(Set(coordinator.liveControllers.keys), [newID])
        try coordinator.showCurrentGroup()
        XCTAssertEqual(Set(coordinator.liveControllers.keys), [previous.id, newID])
    }

    @MainActor func testOffscreenRestorePreservesIntentAndRecoveryRestoresMouseAndOpacity() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        var saved = examplePresentation()
        saved.frame.x = 12_000; saved.frame.y = -9_000
        let entry = try store.add(image: image(), presentation: saved)
        try coordinator.restoreOnLaunch(enabled: true, isSmoke: false)
        let controller = try XCTUnwrap(coordinator.liveControllers[entry.id])
        XCTAssertTrue(screen.contains(controller.presentation.frame.rect))
        XCTAssertEqual(controller.presentation.opacity, saved.opacity)
        XCTAssertTrue(controller.presentation.clickThrough); XCTAssertTrue(controller.presentation.locked)
        XCTAssertEqual(controller.presentation.zoom, saved.zoom)
        try coordinator.recoverCurrentGroup()
        XCTAssertTrue(screen.contains(controller.presentation.frame.rect))
        XCTAssertEqual(controller.presentation.opacity, 1)
        XCTAssertFalse(controller.presentation.clickThrough); XCTAssertTrue(controller.presentation.locked)
        XCTAssertEqual(controller.presentation.zoom, saved.zoom)
        XCTAssertEqual(store.entry(id: entry.id)?.presentation, controller.presentation)
    }

    @MainActor func testManagerMoveDeleteGroupAndRemoveReconcileWithoutStaleCallbacks() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image())
        let group = try store.createGroup(name: "Move destination")
        let oldController = try XCTUnwrap(coordinator.liveControllers[id])
        try store.movePin(id: id, to: group.id)
        try coordinator.reconcileVisiblePins()
        XCTAssertTrue(coordinator.liveControllers.isEmpty); XCTAssertNotNil(store.entry(id: id))
        XCTAssertNil(oldController.onClose); XCTAssertNil(oldController.onPixelChange)
        try coordinator.switchGroup(id: group.id)
        let moved = try XCTUnwrap(coordinator.liveControllers[id])
        XCTAssertFalse(moved === oldController)
        oldController.close() // A closed old window cannot delete its restored replacement.
        XCTAssertNotNil(store.entry(id: id))
        try store.deleteGroup(id: group.id)
        try coordinator.reconcileVisiblePins()
        XCTAssertEqual(store.entry(id: id)?.groupID, PinGroup.defaultID)
        XCTAssertTrue(coordinator.liveControllers[id] === moved)
        try store.remove(id: id)
        try coordinator.reconcileVisiblePins()
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertNil(moved.window?.contentView)
    }

    @MainActor func testTerminationSavesPendingMoveAndPreservesSessionOnDisk() async throws {
        let (directory, store, coordinator) = try fixture(debounce: 30_000_000_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (id, expected, probe) = try autoreleasepool { () throws -> (UUID, PinPresentation, ClosedPinLifetimeProbe) in
            let id = try coordinator.add(image: image())
            let controller = try XCTUnwrap(coordinator.liveControllers[id])
            let probe = try ClosedPinLifetimeProbe(controller)
            controller.applyPresentation(examplePresentation())
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: probe.window))
            let expected = controller.presentation
            try coordinator.prepareForTermination()
            XCTAssertNil(probe.window.contentView)
            return (id, expected, probe)
        }
        try await assertReleased(probe)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertNotNil(store.entry(id: id))
        let reopened = try PinSessionStore(directory: directory)
        XCTAssertEqual(reopened.entry(id: id)?.presentation, expected)
        XCTAssertEqual(reopened.entry(id: id)?.isVisible, true)
        try coordinator.prepareForTermination() // Idempotent.
        try coordinator.showCurrentGroup()
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
    }

    @MainActor func testDebouncedCallbackDoesNotRetainCoordinatorOrController() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        weak var weakCoordinator: PinSessionCoordinator?
        weak var weakController: PinController?
        weak var weakWindow: NSWindow?
        defer { weakWindow?.close() }
        let id = try autoreleasepool { () throws -> UUID in
            var coordinator: PinSessionCoordinator? = PinSessionCoordinator(store: store, presentWindows: false,
                                                                           debounceNanoseconds: 30_000_000_000)
            weakCoordinator = coordinator
            let id = try XCTUnwrap(coordinator?.add(image: image()))
            weakController = coordinator?.liveControllers[id]
            weakWindow = weakController?.window
            coordinator?.liveControllers[id]?.windowDidMove(Notification(name: NSWindow.didMoveNotification))
            // Intentionally no prepareForTermination/close: this tests weak callback ownership.
            coordinator = nil
            return id
        }
        try await drainAppKitUntil { weakCoordinator == nil && weakController == nil }
        XCTAssertNil(weakCoordinator, "The debounce task and controller callbacks must capture weakly")
        XCTAssertNil(weakController, "The cancelled 30-second debounce must not retain a pin")
        XCTAssertNotNil(store.entry(id: id))
    }

    @MainActor func testDebounceEventuallyCommitsLatestPresentationOnly() async throws {
        let (directory, store, coordinator) = try fixture(debounce: 5_000_000)
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image())
        let controller = try XCTUnwrap(coordinator.liveControllers[id])
        for offset in 0..<5 {
            var value = examplePresentation(); value.frame.x += Double(offset * 20)
            controller.applyPresentation(value)
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: controller.window))
        }
        let expected = controller.presentation
        let committed = expectation(description: "Latest pin presentation committed")
        let subscription = store.$index.dropFirst().first { $0.entry(id: id)?.presentation == expected }
            .sink { _ in committed.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [committed], timeout: 3)
        XCTAssertEqual(store.entry(id: id)?.presentation, expected)
        XCTAssertEqual(try pngNames(directory).count, 1)
    }

    @MainActor func testFailedCloseArchiveReportsErrorAndPreservesRecoverableAssets() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image())
        var receivedError: Error?
        coordinator.onError = { receivedError = $0 }
        let before = store.index
        coordinator.liveControllers[id]?.applyPresentation(examplePresentation())
        let manifest = directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        coordinator.liveControllers[id]?.close()
        XCTAssertNotNil(receivedError)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertEqual(store.index, before, "Neither archive state nor the final frame may partially commit")
        XCTAssertEqual(store.entry(id: id)?.isVisible, true)
        XCTAssertNotNil(store.entry(id: id)); XCTAssertNotNil(store.image(id: id))
    }

    @MainActor func testCorruptSiblingDoesNotPreventRecoveryOfHealthyPins() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let good = try store.add(image: image(), presentation: examplePresentation())
        let bad = try store.add(image: image())
        try FileManager.default.removeItem(at: directory.appendingPathComponent(bad.original.filename))
        XCTAssertThrowsError(try coordinator.recoverCurrentGroup())
        let controller = try XCTUnwrap(coordinator.liveControllers[good.id])
        XCTAssertFalse(controller.presentation.clickThrough)
        XCTAssertEqual(controller.presentation.opacity, 1)
        XCTAssertNil(coordinator.liveControllers[bad.id])
        controller.applyPresentation(examplePresentation())
        XCTAssertThrowsError(try coordinator.openPin(id: good.id))
        XCTAssertTrue(coordinator.liveControllers[good.id] === controller)
        XCTAssertTrue(controller.presentation.clickThrough, "Show/reopen must preserve saved presentation")
        XCTAssertEqual(controller.presentation.opacity, examplePresentation().opacity)
    }

    @MainActor func testCloseAfterGroupBecomesHiddenPreservesEntryBeforeReconciliation() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image())
        let old = try XCTUnwrap(coordinator.liveControllers[id])
        try store.setGroupHidden(id: PinGroup.defaultID, hidden: true)
        old.close()
        XCTAssertNotNil(store.entry(id: id)); XCTAssertNotNil(store.image(id: id))
        XCTAssertEqual(store.entry(id: id)?.isVisible, true)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        try coordinator.showCurrentGroup()
        XCTAssertNotNil(coordinator.liveControllers[id])
        let restored = try XCTUnwrap(coordinator.liveControllers[id])
        let other = try store.createGroup(name: "Inactive close")
        try store.setActiveGroup(id: other.id)
        restored.close()
        XCTAssertEqual(store.entry(id: id)?.isVisible, true)
        XCTAssertNotNil(store.entry(id: id)); XCTAssertTrue(coordinator.liveControllers.isEmpty)
    }

    @MainActor func testAddRevealsHiddenGroupInTheSameCommit() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        try store.setGroupHidden(id: PinGroup.defaultID, hidden: true)
        try store.setAllHidden(true)
        let id = try coordinator.add(image: image())
        XCTAssertFalse(store.index.allHidden)
        XCTAssertFalse(try XCTUnwrap(store.groups.first).isHidden)
        XCTAssertEqual(store.visibleEntries.map(\.id), [id])
        XCTAssertNotNil(coordinator.liveControllers[id])
        let reopened = try PinSessionStore(directory: directory)
        XCTAssertEqual(reopened.index, store.index)
    }

    @MainActor func testFailedAddRollsBackPinEvictionAndGroupVisibilityTogether() async throws {
        let (directory, store, coordinator) = try fixture(policy: PinSessionPolicy(maxPins: 1))
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let previous = try store.add(image: image())
        try store.setGroupHidden(id: PinGroup.defaultID, hidden: true)
        try store.setAllHidden(true)
        let before = store.index
        let manifest = directory.appendingPathComponent("index.json")
        let originalManifest = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try coordinator.add(image: image()))
        XCTAssertEqual(store.index, before)
        XCTAssertTrue(store.index.allHidden)
        XCTAssertTrue(try XCTUnwrap(store.groups.first).isHidden)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertEqual(try pngNames(directory), [previous.original.filename])
        XCTAssertNotNil(store.image(id: previous.id))
        // The failed write left the existing assets intact and the old manifest reusable.
        try FileManager.default.removeItem(at: manifest)
        try originalManifest.write(to: manifest)
        XCTAssertEqual(try PinSessionStore(directory: directory).index, before)
    }

    @MainActor func testCloseArchiveReopenPreservesOriginalEditedPixelsAndPresentation() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let (id, presentation, assets, probe) = try autoreleasepool { () throws -> (UUID, PinPresentation, [PinRasterAsset], ClosedPinLifetimeProbe) in
            let id = try coordinator.add(image: image(width: 12, height: 8))
            let controller = try XCTUnwrap(coordinator.liveControllers[id])
            try controller.cropImage(to: CGRect(x: 0, y: 0, width: 5, height: 3))
            controller.applyPresentation(examplePresentation())
            let presentation = controller.presentation
            let assets = try XCTUnwrap(store.entry(id: id)?.assets)
            let probe = try ClosedPinLifetimeProbe(controller)
            controller.close()
            return (id, presentation, assets, probe)
        }
        try await assertReleased(probe)
        XCTAssertEqual(store.entry(id: id)?.isVisible, false)
        XCTAssertEqual(store.entry(id: id)?.presentation, presentation)
        XCTAssertEqual(store.entry(id: id)?.assets, assets)
        try autoreleasepool {
            try coordinator.showCurrentGroup()
            try coordinator.recoverCurrentGroup()
            XCTAssertTrue(coordinator.liveControllers.isEmpty, "Show/Recover must not reopen archived history")
            try coordinator.openPin(id: id)
            let restored = try XCTUnwrap(coordinator.liveControllers[id])
            XCTAssertEqual(store.entry(id: id)?.isVisible, true)
            XCTAssertEqual(restored.presentation, presentation)
            XCTAssertEqual(restored.image.width, 12); XCTAssertEqual(restored.image.height, 8)
            XCTAssertEqual(restored.currentImage.width, 5); XCTAssertEqual(restored.currentImage.height, 3)
            XCTAssertEqual(try pngNames(directory), Set(assets.map(\.filename)))
            try coordinator.openPin(id: id)
            XCTAssertTrue(coordinator.liveControllers[id] === restored)
            XCTAssertEqual(coordinator.liveControllers.count, 1)
        }
    }

    @MainActor func testArchivePersistsAcrossLaunchAndGroupChangesUntilExplicitReopen() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let archivedID = try coordinator.add(image: image())
        coordinator.liveControllers[archivedID]?.close()
        let openID = try coordinator.add(image: image())
        let group = try store.createGroup(name: "Archive independence")
        try coordinator.switchGroup(id: group.id)
        try coordinator.switchGroup(id: PinGroup.defaultID)
        XCTAssertEqual(Set(coordinator.liveControllers.keys), [openID])
        XCTAssertEqual(store.entry(id: archivedID)?.isVisible, false)
        try coordinator.prepareForTermination()
        let reopenedStore = try PinSessionStore(directory: directory)
        let nextLaunch = PinSessionCoordinator(store: reopenedStore, presentWindows: false)
        defer { try? nextLaunch.prepareForTermination() }
        try nextLaunch.restoreOnLaunch(enabled: true, isSmoke: false)
        XCTAssertEqual(Set(nextLaunch.liveControllers.keys), [openID])
        XCTAssertEqual(reopenedStore.entry(id: archivedID)?.isVisible, false)
        try nextLaunch.openPin(id: archivedID)
        XCTAssertEqual(Set(nextLaunch.liveControllers.keys), [openID, archivedID])
    }

    @MainActor func testExplicitManagerRemovalDeletesArchivedImagesSeparatelyFromClose() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image(width: 12, height: 8))
        try coordinator.liveControllers[id]?.applyTransform(.rotateClockwise)
        coordinator.liveControllers[id]?.close()
        XCTAssertEqual(store.entry(id: id)?.isVisible, false)
        XCTAssertEqual(try pngNames(directory).count, 2)
        try store.remove(id: id)
        try coordinator.reconcileVisiblePins()
        XCTAssertNil(store.entry(id: id)); XCTAssertTrue(try pngNames(directory).isEmpty)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertThrowsError(try coordinator.openPin(id: id))
    }

    @MainActor func testFailedReopenRollsBackVisibilityAndActiveGroupAtomically() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image())
        coordinator.liveControllers[id]?.close()
        try store.setGroupHidden(id: PinGroup.defaultID, hidden: true)
        let other = try store.createGroup(name: "Current")
        try store.setActiveGroup(id: other.id); try store.setAllHidden(true)
        let before = store.index
        let manifest = directory.appendingPathComponent("index.json")
        let originalManifest = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try coordinator.openPin(id: id))
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(store.entry(id: id)?.isVisible, false)
        XCTAssertTrue(coordinator.liveControllers.isEmpty)
        XCTAssertNotNil(store.image(id: id)); XCTAssertEqual(try pngNames(directory).count, 1)
        try FileManager.default.removeItem(at: manifest); try originalManifest.write(to: manifest)
        try coordinator.openPin(id: id)
        XCTAssertEqual(store.entry(id: id)?.isVisible, true)
        XCTAssertEqual(store.index.activeGroupID, PinGroup.defaultID)
        XCTAssertFalse(store.index.allHidden)
        XCTAssertFalse(try XCTUnwrap(store.groups.first).isHidden)
        XCTAssertNotNil(coordinator.liveControllers[id])
    }

    @MainActor func testArchivedEntriesStillCountTowardBoundAndProtectedGroupsRemainProtected() async throws {
        let (directory, store, coordinator) = try fixture(policy: PinSessionPolicy(maxPins: 1))
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let archivedID = try coordinator.add(image: image())
        coordinator.liveControllers[archivedID]?.close()
        XCTAssertEqual(store.entries.count, 1); XCTAssertEqual(store.entry(id: archivedID)?.isVisible, false)
        try store.setGroupProtected(id: PinGroup.defaultID, protected: true)
        XCTAssertThrowsError(try coordinator.add(image: image()))
        XCTAssertNotNil(store.entry(id: archivedID)); XCTAssertTrue(coordinator.liveControllers.isEmpty)
        try store.setGroupProtected(id: PinGroup.defaultID, protected: false)
        let replacement = try coordinator.add(image: image())
        XCTAssertNil(store.entry(id: archivedID)); XCTAssertNotNil(store.entry(id: replacement))
        XCTAssertEqual(store.entries.count, 1); XCTAssertEqual(coordinator.liveControllers.count, 1)
    }

    @MainActor func testRepeatedCloseArchiveReopenKeepsSingleControllerAndOriginalAssets() async throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try autoreleasepool { try coordinator.add(image: image()) }
        let original = try XCTUnwrap(store.entry(id: id)?.original)
        var closed: [ClosedPinLifetimeProbe] = []
        for _ in 0..<12 {
            let probe = try autoreleasepool { () throws -> ClosedPinLifetimeProbe in
                let controller = try XCTUnwrap(coordinator.liveControllers[id])
                let probe = try ClosedPinLifetimeProbe(controller)
                controller.close()
                return probe
            }
            closed.append(probe)
            try await assertReleased(probe)
            XCTAssertTrue(coordinator.liveControllers.isEmpty)
            XCTAssertEqual(store.entry(id: id)?.isVisible, false)
            XCTAssertEqual(try pngNames(directory), [original.filename])
            try autoreleasepool {
                try coordinator.showCurrentGroup()
                XCTAssertTrue(coordinator.liveControllers.isEmpty)
                try coordinator.openPin(id: id)
                XCTAssertEqual(store.entry(id: id)?.isVisible, true)
                XCTAssertEqual(coordinator.liveControllers.count, 1)
                XCTAssertEqual(store.entry(id: id)?.original, original)
            }
        }
        for probe in closed { try await assertReleased(probe) }
    }

    /// AppKit can enqueue temporary autoreleased owners during window construction/close.
    /// The callers scope all those operations in pools; this additionally lets pending main
    /// queue/run-loop work finish. A genuine reference cycle still fails after one second.
    @MainActor private func drainAppKitUntil(_ released: @MainActor () -> Bool) async throws {
        for _ in 0..<40 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
            if autoreleasepool(invoking: { released() }) { return }
        }
    }
    @MainActor private func assertReleased(_ probe: ClosedPinLifetimeProbe,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        try await drainAppKitUntil { probe.controller == nil && probe.content == nil }
        XCTAssertNil(probe.controller, "Closed pin still has a strong owner after scoped pools and run-loop drain", file: file, line: line)
        XCTAssertNil(probe.content, "Closed pin retained its original content/view graph", file: file, line: line)
        // Deliberately keep the window strongly alive, like an AppKit cached panel.
        XCTAssertNil(probe.window.contentView, file: file, line: line)
        XCTAssertNil(probe.window.delegate, file: file, line: line)
        XCTAssertFalse(probe.window.isVisible, file: file, line: line)
    }

    @MainActor private func fixture(policy: PinSessionPolicy = PinSessionPolicy(),
                                   debounce: UInt64 = 250_000_000) throws -> (URL, PinSessionStore, PinSessionCoordinator) {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        let store = try PinSessionStore(directory: directory, policy: policy)
        let screen = self.screen
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false,
                                                debounceNanoseconds: debounce, screens: { [screen] })
        return (directory, store, coordinator)
    }
    private func examplePresentation() -> PinPresentation {
        PinPresentation(frame: PinWindowFrame(x: 100, y: 120, width: 480, height: 320),
                        opacity: 0.4, zoom: 2, clickThrough: true, locked: true)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotPinCoordinator-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func pngNames(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(PinRasterAsset.isSafeFilename))
    }
    private func image(width: Int = 10, height: Int = 10) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

/// A strong cached window must not keep the closed controller or its former content alive.
@MainActor private final class ClosedPinLifetimeProbe {
    weak var controller: PinController?
    weak var content: NSView?
    let window: NSWindow
    init(_ controller: PinController) throws {
        self.controller = controller
        window = try XCTUnwrap(controller.window)
        content = window.contentView
    }
}
