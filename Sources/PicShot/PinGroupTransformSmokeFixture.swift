import AppKit
import CryptoKit
import PicShotCore

/// Real AppKit controls/events and view-backed snapshots. Runs only in the explicit
/// packaged smoke path, using synthetic pixels and an isolated temporary session.
@MainActor enum PinGroupTransformSmokeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("PicShot-PinGroup-Smoke-" + UUID().uuidString)
        defer { try? files.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let session = PinSessionCoordinator(store: store, desktopVisibilityService: PinDesktopVisibilityService(defaults: nil))
        defer { try? session.prepareForTermination() }
        var errors: [String] = []
        session.onError = { errors.append($0.localizedDescription) }
        let setup = try await exerciseControls(session: session, store: store, directory: directory, evidenceDirectory: evidenceDirectory)
        let selected = setup.selected, assetHashes = setup.assetHashes
        store.clearThumbnailCache()
        try await settle()
        // Functional UI setup has returned: no source image, export bytes, table,
        // manager or initial inspector locals are retained across the resource phase.
        var warmupProbes: [PinGroupReleaseProbe] = [], measuredProbes: [PinGroupReleaseProbe] = []
        let beforeWarmup = try observedMemory(), warmupSampler = GIFResourceMemorySampler()
        defer { warmupSampler.stop() }
        for _ in 0..<3 { try await cycle(session, selected: selected, probes: &warmupProbes) }
        let warmupStatistics = try stoppedStatistics(warmupSampler)
        try require(warmupProbes.count == 15 && session.livePinCount == 4, "Group warm-up boundary/probe count mismatch")
        let baseline = try observedMemory(), measuredStarted = ProcessInfo.processInfo.systemUptime, sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        var settled: [GIFResourceMemoryReading] = []
        settled.reserveCapacity(20)
        for _ in 0..<20 {
            try await cycle(session, selected: selected, probes: &measuredProbes)
            sampler.sample(); settled.append(try observedMemory())
            try require(session.groupTransforms.history.undoPlans.count <= 32, "Undo history exceeded bound")
            try require(session.livePinCount == 4, "Cycle reopened archives or duplicated controllers")
        }
        guard let measuredEnd = settled.last else { throw failure("Measured cycle observations missing") }
        try require(try assets(in: directory) == assetHashes, "Resource cycles changed asset bytes")
        let teardownProbes = try pinProbes(session)
        try require(measuredProbes.count == 100 && teardownProbes.count == 4, "Group measured/teardown probe count mismatch")
        try session.hideAll(); store.clearThumbnailCache()
        try await released(teardownProbes)
        try require(session.livePinCount == 0, "Final teardown retained live pins")
        try require(try assets(in: directory) == assetHashes, "Final cleanup changed asset bytes")
        sampler.sample()
        let final = try observedMemory(), measuredStatistics = try stoppedStatistics(sampler)
        let measuredElapsed = ProcessInfo.processInfo.systemUptime - measuredStarted
        try require(errors.isEmpty, "Unexpected callbacks: " + errors.joined(separator: "; "))
        let probes = warmupProbes + measuredProbes + teardownProbes
        let retainedControllers = probes.filter { $0.controller != nil }.count
        let retainedContent = probes.filter { $0.content != nil }.count
        try require(retainedControllers == 0 && retainedContent == 0, "Group cycles retained closed controllers/content")
        let rss = settled.map { $0.residentBytes! }, footprint = settled.map { $0.physicalFootprintBytes! }
        let resource: [String: Any] = [
            "observationsComplete": true, "warmupCycles": 3, "measuredCycles": 20, "completedMeasuredCycles": settled.count,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval, "measuredElapsedSeconds": measuredElapsed,
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
            "beforeWarmup": try object(beforeWarmup), "baselineAfterWarmup": try object(baseline),
            "warmupSampledMemory": try object(warmupStatistics), "sampledMemory": try object(measuredStatistics),
            "settledAfterCycles": try settled.map { try object($0) }, "afterMeasuredCycles": try object(measuredEnd),
            "finalAfterCleanup": try object(final), "livePinsAtBaselineAndCycleEnds": 4, "livePinsAfterCleanup": session.livePinCount,
            "residentGrowthFromWarmupBytes": try delta(measuredEnd.residentBytes, baseline.residentBytes),
            "physicalFootprintGrowthFromWarmupBytes": try delta(measuredEnd.physicalFootprintBytes, baseline.physicalFootprintBytes),
            "residentCleanupDeltaBytes": try delta(final.residentBytes, measuredEnd.residentBytes),
            "physicalFootprintCleanupDeltaBytes": try delta(final.physicalFootprintBytes, measuredEnd.physicalFootprintBytes),
            "residentLastIntervalGrowthBytes": Int64(rss[19]) - Int64(rss[18]),
            "physicalFootprintLastIntervalGrowthBytes": Int64(footprint[19]) - Int64(footprint[18]),
            "residentLateThreeIntervalGrowthBytes": (17...19).map { Int64(rss[$0]) - Int64(rss[$0 - 1]) },
            "physicalFootprintLateThreeIntervalGrowthBytes": (17...19).map { Int64(footprint[$0]) - Int64(footprint[$0 - 1]) },
            "lateIntervalCycles": 1, "warmupReleaseProbes": warmupProbes.count, "measuredReleaseProbes": measuredProbes.count,
            "finalTeardownReleaseProbes": teardownProbes.count, "retainedControllers": retainedControllers,
            "retainedContentViews": retainedContent, "assetsUnchanged": true, "assetDigests": assetHashes,
            "assetDigestFormat": "byte-count:SHA-256; index.json excluded because archive/presentation metadata changes",
            "memoryIsObservational": true, "stabilityAssessed": false,
            "scope": "Main PicShot process, 3 warm-ups then 20 measured transform/undo/inspector/hide/show cycles. Timer remains active through asset-hash validation, final hide and cleanup. Not a whole-system, WindowServer, GPU or helper total; sampled peaks can miss transients. No plateau or zero-leak inference"
        ]
        return ["status": "passed", "selectedPins": 3, "unselectedSentinels": 1,
                "mixedKinds": ["image", "rotated-image-fixed-zoom", "text"],
                "stages": ["native-table-multiselect", "native-context-selection", "escape-cancel", "native-move-scale-apply", "atomic-undo-redo", "six-native-alignments", "bounded-hide-show-resource-cycles"],
                "snapshots": ["pin-group-multiselect.png", "pin-group-transform.png"],
                "warmupCycles": 3, "cycles": 20, "releaseProbes": probes.count, "retainedControllersOrContent": 0,
                "baselineRSSBytes": baseline.residentBytes!, "peakRSSBytes": measuredStatistics.peakResidentBytes!, "finalRSSBytes": final.residentBytes!,
                "growthRSSBytes": try delta(final.residentBytes, baseline.residentBytes), "rssSamplesEveryFiveCycles": [rss[4], rss[9], rss[14], rss[19]],
                "rssAvailable": true, "lastFiveCyclesGrowthBytes": Int64(rss[19]) - Int64(rss[14]),
                "rssIsObservational": true, "captureStarted": false, "userDefaultsChanged": false,
                "desktopVisibilityPreferencesIsolated": true, "userPreferenceReadScope": "Existing manager restore-on-launch toggle reads its saved value; fixture does not change it. Desktop-visibility service is isolated",
                "resourceEvidence": resource,
                "boundary": "Real native controls/events and synthetic temporary pins; not a zero-leak claim or user capture test"]
    }
    private static func exerciseControls(session: PinSessionCoordinator, store: PinSessionStore, directory: URL,
                                         evidenceDirectory: URL) async throws -> (selected: Set<UUID>, assetHashes: [String: String]) {
        let sample = ImageEditorRenderer.makeSampleImage()
        let a = try session.add(image: sample, title: "组合 A · 图片")
        let b = try session.add(image: sample, title: "组合 B · 旋转 / 200%")
        try session.liveControllers[b]?.applyTransform(.rotateClockwise)
        let c = try session.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(runs: [PinTextRun(text: "组合 C · 原生文字\n只改变窗口，不重新渲染图片")])), title: "组合 C · 文字"))
        let sentinel = try session.add(image: sample, title: "未选择 · 不移动")
        let ids = [a, b, c, sentinel], selected: Set<UUID> = [a, b, c]
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frames = [NSRect(x: screen.minX + 30, y: screen.minY + 55, width: 300, height: 180),
                      NSRect(x: screen.minX + 390, y: screen.minY + 130, width: 240, height: 320),
                      NSRect(x: screen.minX + 90, y: screen.minY + 420, width: 340, height: 160),
                      NSRect(x: screen.minX + 740, y: screen.minY + 220, width: 180, height: 120)]
        for (i, id) in ids.enumerated() {
            let value = PinPresentation(frame: PinWindowFrame(frames[i]), zoom: i == 1 ? 2 : i == 2 ? 1 : nil)
            if let pin = session.liveControllers[id] { pin.applyPresentation(value); pin.onPresentationChange?(pin.presentation) }
            if let pin = session.richControllers[id] { pin.applyPresentation(value); pin.onPresentationChange?(pin.presentation) }
        }
        try session.flushPresentationChanges()
        let original = store.index, assetHashes = try assets(in: directory)
        let manager = PinGroupsController(store: store, transforms: session.groupTransforms)
        defer { manager.close() }
        manager.showWindow(nil)
        try await settle()
        guard let content = manager.window?.contentView, let table = descendant(NSTableView.self, in: content) else { throw failure("Manager table missing") }
        try require(table.allowsMultipleSelection, "Native manager table is not multiselect")
        let listed = store.entries.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        table.selectRowIndexes(IndexSet(listed.indices.filter { selected.contains(listed[$0].id) }), byExtendingSelection: false)
        try require(session.groupTransforms.selectedIDs == selected, "Native table selected wrong stable IDs")
        // Dispatch the real context menu action, twice, rather than calling the model.
        try contextSelection(session, id: a)
        try require(!session.groupTransforms.selectedIDs.contains(a), "Context action failed to deselect pin")
        try contextSelection(session, id: a)
        try require(session.groupTransforms.selectedIDs == selected, "Context action failed to reselect pin")
        try await settle()
        try snapshot(try window(manager), to: evidenceDirectory.appendingPathComponent("pin-group-multiselect.png"))

        try control(NSButton.self, "pin-group-transform", in: content).performClick(nil)
        guard let cancelledEditor = session.groupTransforms.editor else { throw failure("Transform button did not open inspector") }
        try control(NSTextField.self, "pin-group-dx", in: cancelledEditor.window?.contentView).stringValue = "500"
        // Native Escape key-equivalent invokes the actual Cancel control.
        guard let editorWindow = cancelledEditor.window,
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: editorWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { throw failure("Cannot create native Escape event") }
        try require(editorWindow.performKeyEquivalent(with: escape), "Native Escape did not reach Cancel")
        try require(session.groupTransforms.editor == nil && store.index == original, "Cancel changed group frames")

        try control(NSButton.self, "pin-group-transform", in: content).performClick(nil)
        guard let editor = session.groupTransforms.editor else { throw failure("Inspector did not reopen") }
        try control(NSTextField.self, "pin-group-dx", in: editor.window?.contentView).stringValue = "25"
        try control(NSTextField.self, "pin-group-dy", in: editor.window?.contentView).stringValue = "-15"
        try control(NSTextField.self, "pin-group-scale", in: editor.window?.contentView).stringValue = "125"
        try snapshot(try window(editor), to: evidenceDirectory.appendingPathComponent("pin-group-transform.png"))
        try control(NSButton.self, "pin-group-apply", in: editor.window?.contentView).performClick(nil)
        try require(session.groupTransforms.editor == nil, "Apply failed or inspector remained open")
        let changed = store.index
        try require(changed != original && changed.entry(id: sentinel) == original.entry(id: sentinel), "Group transform moved sentinel or made no change")
        try require(try assets(in: directory) == assetHashes, "Move/scale rewrote raster or source assets")
        try await settle()
        try control(NSButton.self, "pin-group-undo", in: content).performClick(nil)
        try require(store.index == original, "One native Undo did not restore all three")
        try await settle()
        try control(NSButton.self, "pin-group-redo", in: content).performClick(nil)
        try require(store.index == changed, "One native Redo did not restore all three")
        try await settle()
        let align = try control(NSPopUpButton.self, "pin-group-align", in: content)
        for (index, alignment) in PinGroupAlignment.allCases.enumerated() {
            let plan = try PinGroupTransformPlan(index: store.index, selectedIDs: selected, transform: .align(alignment))
            let expected = try plan.applying(to: store.index)
            align.selectItem(at: index + 1)
            try require(align.sendAction(align.action, to: align.target), "Alignment control did not dispatch")
            try require(store.index == expected, "Native alignment result differs: " + alignment.rawValue)
            try require(store.entry(id: sentinel) == original.entry(id: sentinel), "Alignment moved sentinel")
            try await settle()
        }
        return (selected, assetHashes)
    }
    private static func contextSelection(_ session: PinSessionCoordinator, id: UUID) throws {
        try autoreleasepool {
            guard let pin = session.liveControllers[id], let menu = pin.actionMenu,
                  let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "pin-group-select" }) else { throw failure("Pin context selection action missing") }
            menu.performActionForItem(at: index)
        }
    }
    private static func cycle(_ session: PinSessionCoordinator, selected: Set<UUID>, probes: inout [PinGroupReleaseProbe]) async throws {
        try session.groupTransforms.setSelection(selected)
        try session.groupTransforms.transform(.moveAndScale(dx: 3, dy: -2, scale: 1))
        try session.groupTransforms.undo()
        var closed = try pinProbes(session)
        let inspector = try autoreleasepool { () throws -> PinGroupReleaseProbe in
            session.groupTransforms.showEditor()
            guard let editor = session.groupTransforms.editor else { throw failure("Cycle inspector missing") }
            let probe = try PinGroupReleaseProbe(editor)
            try control(NSButton.self, "pin-group-cancel", in: editor.window?.contentView).performClick(nil)
            return probe
        }
        closed.append(inspector)
        try session.hideAll()
        try await released(closed)
        try require(session.livePinCount == 0, "Hide retained live pin entries")
        probes.append(contentsOf: closed)
        try session.showCurrentGroup(); try await settle()
        try require(session.groupTransforms.selectedIDs.isEmpty && !session.groupTransforms.canUndo, "Hide retained stale selection/undo")
    }
    private static func pinProbes(_ session: PinSessionCoordinator) throws -> [PinGroupReleaseProbe] {
        try autoreleasepool {
            try session.liveControllers.values.map { try PinGroupReleaseProbe($0) } + session.richControllers.values.map { try PinGroupReleaseProbe($0) }
        }
    }
    private static func released(_ probes: [PinGroupReleaseProbe]) async throws {
        for _ in 0..<20 {
            try await settle()
            if probes.allSatisfy({ $0.controller == nil && $0.content == nil }) { return }
        }
        throw failure("Closed group controllers/content did not release")
    }
    private static func assets(in directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent != "index.json" {
            result[url.lastPathComponent] = try autoreleasepool {
                let data = try Data(contentsOf: url)
                return "\(data.count):" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 60_000_000) }
    private static func window(_ controller: NSWindowController) throws -> NSWindow { guard let result = controller.window else { throw failure("Missing window") }; return result }
    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = descendant(type, in: child) { return match } }; return nil
    }
    private static func control<T: NSView>(_ type: T.Type, _ id: String, in view: NSView?) throws -> T {
        func find(_ view: NSView) -> T? {
            if let match = view as? T, view.identifier?.rawValue == id { return match }
            for child in view.subviews { if let match = find(child) { return match } }; return nil
        }
        guard let view, let control = find(view) else { throw failure("Missing native control " + id) }; return control
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        guard window.isVisible, let view = window.contentView else { throw failure("Snapshot requires a real shown window") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("No native bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw failure("No native snapshot pixels") }; try image.writePNG(to: url)
    }
    private static func observedMemory() throws -> GIFResourceMemoryReading {
        let reading = GIFResourceMemoryReading.current()
        guard let rss = reading.residentBytes, let footprint = reading.physicalFootprintBytes,
              rss > 0, footprint > 0, rss <= UInt64(Int64.max), footprint <= UInt64(Int64.max) else {
            throw failure("Required main-process RSS/physical-footprint observation missing")
        }
        return reading
    }
    private static func stoppedStatistics(_ sampler: GIFResourceMemorySampler) throws -> GIFResourceMemoryStatistics {
        sampler.stop(); let value = sampler.snapshot(), total = value.timerTickCount + value.boundarySampleCount
        guard value.timerTickCount > 0, value.residentSampleCount == total, value.physicalFootprintSampleCount == total,
              value.failedResidentSampleCount == 0, value.failedPhysicalFootprintSampleCount == 0,
              let rss = value.peakResidentBytes, let footprint = value.peakPhysicalFootprintBytes, rss > 0, footprint > 0 else {
            throw failure("Continuous RSS/footprint incomplete: timer=\(value.timerTickCount), boundary=\(value.boundarySampleCount), RSS valid/failed=\(value.residentSampleCount)/\(value.failedResidentSampleCount), footprint valid/failed=\(value.physicalFootprintSampleCount)/\(value.failedPhysicalFootprintSampleCount)")
        }
        return value
    }
    private static func delta(_ current: UInt64?, _ previous: UInt64?) throws -> Int64 {
        guard let current, let previous, current <= UInt64(Int64.max), previous <= UInt64(Int64.max) else {
            throw failure("Required comparable memory boundary missing")
        }
        return Int64(current) - Int64(previous)
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw failure("Memory evidence encoding failed")
        }
        return object
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Pin group-transform smoke: " + message) }
}
@MainActor private final class PinGroupReleaseProbe {
    weak var controller: NSWindowController?
    weak var content: NSView?
    init(_ controller: NSWindowController) throws {
        guard let content = controller.window?.contentView else { throw PicShotError.message("Group release probe requires live content") }
        self.controller = controller; self.content = content
    }
}
