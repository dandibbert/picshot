import AppKit
import Darwin
import PicShotCore

/// Synthetic, temporary-store verification for the packaged app's explicit smoke path.
/// Uses real shown AppKit windows, but never captures the screen or writes user defaults.
@MainActor enum PinSessionSmokeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        guard evidenceDirectory.isFileURL else { throw failure("Evidence directory must be a local URL") }
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let directory = files.temporaryDirectory.appendingPathComponent("PicShot-PinSession-Smoke-" + UUID().uuidString,
                                                                         isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store)
        defer { try? coordinator.prepareForTermination() }
        var callbackErrors: [String] = []
        coordinator.onError = { callbackErrors.append($0.localizedDescription) }
        let sample = ImageEditorRenderer.makeSampleImage()
        var probes: [PinSessionSmokeProbe] = []
        var stages: [String] = []

        // Create, edit, and persist presentation independently from pixels.
        let id = try coordinator.add(image: sample, title: "设计稿 · 裁剪与归档示例")
        let original = try entry(store, id: id).original
        try withPin(coordinator, id: id) { controller in
            try require(controller.window?.isVisible == true, "New pin window was not shown")
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
            let frame = CGRect(x: visible.minX + 40, y: visible.minY + 60, width: 520, height: 380)
            let presentation = PinPresentation(frame: PinWindowFrame(frame), opacity: 0.72, zoom: 0.5,
                                               clickThrough: true, locked: true)
                .normalized(screens: [PinWindowFrame(visible)])
            controller.applyPresentation(presentation)
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: controller.window))
            try controller.cropImage(to: CGRect(x: 40, y: 70, width: 840, height: 470))
            controller.window?.displayIfNeeded()
        }
        try coordinator.flushPresentationChanges()
        try await settleShownPin(coordinator, id: id)
        let edited = try entry(store, id: id)
        try require(edited.original == original && edited.current.filename != original.filename,
                    "Edit did not preserve a separate original raster")
        try require(edited.current.width == 840 && edited.current.height == 470, "Edited raster dimensions differ")
        let expectedPresentation = edited.presentation
        try require(abs(expectedPresentation.opacity - 0.72) < 0.005 && expectedPresentation.zoom == 0.5 &&
                    expectedPresentation.clickThrough && expectedPresentation.locked,
                    "Requested opacity/zoom/click-through/lock was not applied and saved")
        let expectedAssets = Set(edited.assets.map(\.filename))
        try require(try assetNames(directory) == expectedAssets, "Unexpected assets after first edit")
        stages.append("create-presentation-edit")

        // Hidden windows must release controllers and content after AppKit yields.
        let hidden = try probe(coordinator, id: id); probes.append(hidden)
        try coordinator.hideCurrentGroup()
        try await requireReleased([hidden], context: "hide")
        try require(coordinator.liveControllers.isEmpty && store.entry(id: id)?.isVisible == true,
                    "Hiding archived or retained the live pin")
        try coordinator.showCurrentGroup()
        try await settleShownPin(coordinator, id: id)
        try verifyRestoredPin(coordinator, id: id, expected: edited)
        try require(try assetNames(directory) == expectedAssets, "Hide/show rewrote pixels")
        stages.append("hide-show-release")

        // Switch away and back, keeping each group's open state without hidden image buffers.
        let group = try store.createGroup(name: "工作参考", color: .purple)
        let switched = try probe(coordinator, id: id); probes.append(switched)
        try coordinator.switchGroup(id: group.id)
        try await requireReleased([switched], context: "group-switch-away")
        try require(coordinator.liveControllers.isEmpty && store.entry(id: id)?.isVisible == true,
                    "Switching groups altered the old pin's open state")
        let otherID = try coordinator.add(image: sample, title: "另一组 · 原始参考")
        try await settleShownPin(coordinator, id: otherID)
        let other = try probe(coordinator, id: otherID); probes.append(other)
        try coordinator.switchGroup(id: PinGroup.defaultID)
        try await requireReleased([other], context: "group-switch-back")
        try await settleShownPin(coordinator, id: id)
        try require(Set(coordinator.liveControllers.keys) == [id], "Inactive group loaded a controller")
        try verifyRestoredPin(coordinator, id: id, expected: edited)
        stages.append("group-switch-preserves-open-state")

        // Ordinary close archives; Show/Recover must not silently reopen history.
        let archived = try closePin(coordinator, id: id); probes.append(archived)
        try await requireReleased([archived], context: "archive")
        try require(store.entry(id: id)?.isVisible == false, "Closing a pin did not archive it")
        try require(Set(try entry(store, id: id).assets.map(\.filename)) == expectedAssets,
                    "Archiving lost original/current assets")
        try coordinator.showCurrentGroup(); try coordinator.recoverCurrentGroup()
        try require(coordinator.liveControllers.isEmpty, "Show/Recover reopened archived history")
        stages.append("close-archives-assets")

        // A native manager preview shows both a current pin and an archived edited item.
        let companionID = try coordinator.add(image: sample, title: "对照 · 当前会话")
        try await saveManagerPreview(store: store, archivedID: id,
                                     destination: evidenceDirectory.appendingPathComponent("pin-groups.png"))
        stages.append("native-group-history-preview")

        try coordinator.openPin(id: id)
        try await settleShownPin(coordinator, id: id)
        try verifyRestoredPin(coordinator, id: id, expected: edited)
        try require(store.entry(id: id)?.isVisible == true, "Reopen did not reactivate the archive")
        let reopenedProbe = try probe(coordinator, id: id)
        try coordinator.openPin(id: id)
        try require(coordinator.liveControllers[id] === reopenedProbe.controller,
                    "Repeated reopen duplicated the pin controller")
        try require(coordinator.liveControllers.count == 2, "Unexpected live count after archive reopen")
        stages.append("reopen-original-current-presentation")

        // Leave a mixture of open, archived, and inactive-group entries for a new store.
        let companion = try closePin(coordinator, id: companionID); probes.append(companion)
        try await requireReleased([companion], context: "archive-companion")
        let termination = try probe(coordinator, id: id); probes.append(termination)
        try coordinator.prepareForTermination()
        try await requireReleased([termination], context: "termination")
        try require(store.entry(id: id)?.isVisible == true && store.entry(id: companionID)?.isVisible == false,
                    "Termination changed a prior open/archive state")
        let restoredStore = try PinSessionStore(directory: directory)
        let restored = PinSessionCoordinator(store: restoredStore)
        defer { try? restored.prepareForTermination() }
        restored.onError = { callbackErrors.append($0.localizedDescription) }
        try restored.restoreOnLaunch(enabled: false, isSmoke: false)
        try restored.restoreOnLaunch(enabled: true, isSmoke: true)
        try require(restored.liveControllers.isEmpty, "Launch/smoke guard restored a window")
        // Deliberately exercise restoration against this temporary store only.
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        try await settleShownPin(restored, id: id)
        try require(Set(restored.liveControllers.keys) == [id], "New store restored archives or inactive groups")
        try require(restoredStore.entry(id: otherID)?.isVisible == true &&
                    restoredStore.entry(id: companionID)?.isVisible == false, "Stored visibility did not survive reload")
        try verifyRestoredPin(restored, id: id, expected: edited)
        try require(presentationMatches(try entry(restoredStore, id: id).presentation, expectedPresentation),
                    "Saved presentation did not survive new-store restoration")
        stages.append("new-store-restoration-and-launch-guards")

        // Explicit manager-style removal is separate from archival and deletes both PNGs.
        let removed = try probe(restored, id: id); probes.append(removed)
        try restoredStore.remove(id: id)
        try restored.reconcileVisiblePins()
        try await requireReleased([removed], context: "explicit-remove")
        try require(restoredStore.entry(id: id) == nil, "Explicit removal left a saved entry")
        for filename in expectedAssets {
            try require(!files.fileExists(atPath: directory.appendingPathComponent(filename).path),
                        "Explicit removal left a pin asset")
        }
        stages.append("explicit-remove-deletes-assets")

        // This is a separate session metric, not a replacement for the editor/pin harness.
        let cycleID = try restored.add(image: sample, title: "会话循环 · 合成样例")
        let cycleAsset = try entry(restoredStore, id: cycleID).original.filename
        let warmupCount = 3, cycleCount = 20
        for _ in 0..<warmupCount { probes += try await cycle(restored, id: cycleID) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let baseline = residentBytes()
        var peak = baseline
        var samples: [UInt64] = []
        var windowCounts: [Int] = []
        for index in 0..<cycleCount {
            probes += try await cycle(restored, id: cycleID)
            let rss = residentBytes(); peak = max(peak, rss)
            if (index + 1) % 5 == 0 {
                samples.append(rss); windowCounts.append(autoreleasepool { NSApp.windows.count })
            }
            try require(restored.liveControllers.count == 1 && restoredStore.entries.count <= restoredStore.policy.maxPins,
                        "Session cycle exceeded live/store bounds")
            try require(restoredStore.entry(id: cycleID)?.original.filename == cycleAsset,
                        "A presentation-only cycle rewrote the original asset")
        }
        let finalPin = try probe(restored, id: cycleID); probes.append(finalPin)
        try restored.hideAll()
        try await requireReleased(probes, context: "all-session-cycles")
        restoredStore.clearThumbnailCache()
        try await Task.sleep(nanoseconds: 150_000_000)
        let final = residentBytes()
        let retainedPanels = autoreleasepool { probes.filter { $0.window != nil }.count }
        try require(callbackErrors.isEmpty, "Lifecycle callback errors: " + callbackErrors.joined(separator: "; "))
        try restored.prepareForTermination()
        stages.append("twenty-hide-archive-reopen-cycles")
        try files.removeItem(at: directory)
        try require(!files.fileExists(atPath: directory.path), "Temporary session directory was not removed")

        return [
            "status": "passed", "stages": stages, "captureStarted": false, "userDefaultsChanged": false,
            "storeLocation": "unique temporary directory", "temporaryDirectoryRemoved": true,
            "preview": "pin-groups.png", "originalWidth": original.width, "originalHeight": original.height,
            "editedWidth": edited.current.width, "editedHeight": edited.current.height,
            "maximumLivePins": PinSessionCoordinator.maximumLivePins,
            "maximumStoredPinsIncludingArchives": store.policy.maxPins,
            "maximumStoredPixelsIncludingOriginals": store.policy.maxPixelCount,
            "maximumStoredBytes": store.policy.maxDiskBytes,
            "cycleCount": cycleCount, "warmupCycleCount": warmupCount,
            "releaseProbeCount": probes.count, "retainedPinControllersOrContent": 0,
            "retainedEmptyAppKitPanels": retainedPanels,
            "rssAvailable": baseline > 0 && final > 0, "rssIsObservational": true,
            "baselineRSSBytes": baseline, "peakRSSBytes": peak, "finalRSSBytes": final,
            "growthRSSBytes": Int64(final) - Int64(baseline),
            "rssSamplesEveryFiveCycles": samples, "windowCountsEveryFiveCycles": windowCounts,
            "lastFiveCyclesGrowthBytes": Int64(samples.last ?? final) - Int64(samples.dropLast().last ?? baseline),
            "resourceScope": "3 warm-up plus 20 synthetic session hide/show/archive/reopen cycles, with real shown windows and weak controller/content release checks; process RSS is observational, not a zero-leak claim"
        ]
    }

    private static func cycle(_ coordinator: PinSessionCoordinator, id: UUID) async throws -> [PinSessionSmokeProbe] {
        let hidden = try probe(coordinator, id: id)
        try coordinator.hideCurrentGroup()
        try await requireReleased([hidden], context: "cycle-hide")
        try require(coordinator.store.entry(id: id)?.isVisible == true, "Cycle hide archived the pin")
        try coordinator.showCurrentGroup()
        try await settleShownPin(coordinator, id: id)
        let archived = try closePin(coordinator, id: id)
        try await requireReleased([archived], context: "cycle-archive")
        try require(coordinator.store.entry(id: id)?.isVisible == false, "Cycle close failed to archive")
        try coordinator.openPin(id: id)
        try await settleShownPin(coordinator, id: id)
        return [hidden, archived]
    }

    private static func saveManagerPreview(store: PinSessionStore, archivedID: UUID, destination: URL) async throws {
        let manager = PinGroupsController(store: store)
        defer {
            manager.onSessionChange = nil; manager.onOpenPin = nil
            manager.close(); store.clearThumbnailCache()
        }
        // No preference controls are invoked. Selection only loads bounded thumbnails.
        manager.showWindow(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard let window = manager.window, window.isVisible, let content = window.contentView,
              let table = descendant(NSTableView.self, in: content) else {
            throw failure("Native pin manager was not shown")
        }
        let listed = store.entries.filter { $0.groupID == store.index.activeGroupID }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        guard let row = listed.firstIndex(where: { $0.id == archivedID }), table.numberOfRows == listed.count else {
            throw failure("Pin manager did not list the archived item")
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        try await Task.sleep(nanoseconds: 50_000_000)
        window.displayIfNeeded()
        try require(store.cachedThumbnailCount > 0 && store.thumbnailCacheCost <= 12 * 1_024 * 1_024,
                    "Manager preview did not use bounded thumbnail storage")
        try snapshot(window, to: destination)
    }

    private static func settleShownPin(_ coordinator: PinSessionCoordinator, id: UUID) async throws {
        // Let AppKit process a shown window before the next lifecycle transition.
        try await Task.sleep(nanoseconds: 30_000_000)
        try withPin(coordinator, id: id) { controller in
            try require(controller.window?.isVisible == true && controller.window?.contentView != nil,
                        "Native pin window was not visible after yielding")
            controller.window?.displayIfNeeded()
        }
    }

    private static func verifyRestoredPin(_ coordinator: PinSessionCoordinator, id: UUID,
                                          expected: PinSessionEntry) throws {
        try withPin(coordinator, id: id) { controller in
            try require(controller.window?.isVisible == true, "Restored pin window was not shown")
            try require(controller.image.width == expected.original.width && controller.image.height == expected.original.height,
                        "Restored original dimensions differ")
            try require(controller.currentImage.width == expected.current.width && controller.currentImage.height == expected.current.height,
                        "Restored edited dimensions differ")
            try require(presentationMatches(controller.presentation, expected.presentation), "Restored presentation differs")
        }
    }
    private static func presentationMatches(_ a: PinPresentation, _ b: PinPresentation) -> Bool {
        a.locked == b.locked && a.clickThrough == b.clickThrough && a.zoom == b.zoom && abs(a.opacity - b.opacity) < 0.005 &&
            abs(a.frame.x - b.frame.x) <= 1 && abs(a.frame.y - b.frame.y) <= 1 &&
            abs(a.frame.width - b.frame.width) <= 1 && abs(a.frame.height - b.frame.height) <= 1
    }
    private static func entry(_ store: PinSessionStore, id: UUID) throws -> PinSessionEntry {
        guard let entry = store.entry(id: id) else { throw failure("Missing saved pin") }; return entry
    }
    private static func withPin(_ coordinator: PinSessionCoordinator, id: UUID,
                                _ operation: (PinController) throws -> Void) throws {
        try autoreleasepool {
            guard let controller = coordinator.liveControllers[id] else { throw failure("Missing live pin") }
            try operation(controller)
        }
    }
    private static func probe(_ coordinator: PinSessionCoordinator, id: UUID) throws -> PinSessionSmokeProbe {
        try autoreleasepool {
            guard let controller = coordinator.liveControllers[id] else { throw failure("Cannot probe missing pin") }
            return PinSessionSmokeProbe(controller)
        }
    }
    private static func closePin(_ coordinator: PinSessionCoordinator, id: UUID) throws -> PinSessionSmokeProbe {
        try autoreleasepool {
            guard let controller = coordinator.liveControllers[id] else { throw failure("Cannot close missing pin") }
            let probe = PinSessionSmokeProbe(controller); controller.close(); return probe
        }
    }
    private static func requireReleased(_ probes: [PinSessionSmokeProbe], context: String) async throws {
        // At least one run-loop yield is mandatory, even when ARC releases synchronously.
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let released = autoreleasepool {
                probes.allSatisfy { $0.controller == nil && $0.content == nil &&
                    ($0.window == nil || ($0.window?.contentView == nil && $0.window?.delegate == nil && $0.window?.isVisible == false)) }
            }
            if released { return }
        }
        let retained = autoreleasepool { probes.filter { $0.controller != nil || $0.content != nil }.count }
        throw failure("\(context) retained pin controller/content or attached panel after yields (owned: \(retained))")
    }
    private static func assetNames(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(PinRasterAsset.isSafeFilename))
    }
    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews { if let result = descendant(type, in: child) { return result } }
        return nil
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else { throw failure("Missing manager content") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Native snapshot unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage, image.width >= 680, image.height >= 400,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw failure("Native manager snapshot encoding failed")
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { context.setFillColor(window.backgroundColor.cgColor) }
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let output = context.makeImage() else { throw failure("Missing native snapshot pixels") }
        try output.writePNG(to: url)
    }
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    private static func failure(_ message: String) -> Error { PicShotError.message("Pin-session smoke: " + message) }
}

@MainActor private final class PinSessionSmokeProbe {
    weak var controller: PinController?
    weak var window: NSWindow?
    weak var content: NSView?
    init(_ controller: PinController) {
        self.controller = controller; window = controller.window; content = controller.window?.contentView
    }
}
