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
                "stages": ["native-table-multiselect", "native-context-selection", "escape-cancel", "native-move-scale-apply", "atomic-undo-redo", "native-window-constraint-rollback", "six-native-alignments", "bounded-hide-show-resource-cycles"],
                "snapshots": ["pin-group-multiselect.png", "pin-group-transform.png"],
                "snapshotBackground": PinWorkflowSnapshot.backgroundDescription,
                "warmupCycles": 3, "cycles": 20, "releaseProbes": probes.count, "retainedControllersOrContent": 0,
                "baselineRSSBytes": baseline.residentBytes!, "peakRSSBytes": measuredStatistics.peakResidentBytes!, "finalRSSBytes": final.residentBytes!,
                "growthRSSBytes": try delta(final.residentBytes, baseline.residentBytes), "rssSamplesEveryFiveCycles": [rss[4], rss[9], rss[14], rss[19]],
                "rssAvailable": true, "lastFiveCyclesGrowthBytes": Int64(rss[19]) - Int64(rss[14]),
                "rssIsObservational": true, "captureStarted": false, "userDefaultsChanged": false,
                "desktopVisibilityPreferencesIsolated": true, "userPreferenceReadScope": "Existing manager restore-on-launch toggle reads its saved value; fixture does not change it. Desktop-visibility service is isolated",
                "alignmentCenterResidualsScreenPoints": setup.alignmentResiduals,
                "alignmentPolicy": "Sizes unchanged; edge anchors exact when representable; center origins follow the destination pixel grid and signed center residuals are reported",
                "resourceEvidence": resource,
                "boundary": "Real native controls/events and synthetic temporary pins; not a zero-leak claim or user capture test"]
    }
    private static func exerciseControls(session: PinSessionCoordinator, store: PinSessionStore, directory: URL,
                                         evidenceDirectory: URL) async throws -> (selected: Set<UUID>, assetHashes: [String: String], alignmentResiduals: [String: [String: Double]]) {
        let sample = ImageEditorRenderer.makeSampleImage()
        let a = try session.add(image: sample, title: "组合 A · 图片")
        let b = try session.add(image: sample, title: "组合 B · 旋转 / 200%")
        try session.liveControllers[b]?.applyTransform(.rotateClockwise)
        let c = try session.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(runs: [PinTextRun(text: "组合 C · 原生文字\n只改变窗口，不重新渲染图片")])), title: "组合 C · 文字"))
        let sentinel = try session.add(image: sample, title: "未选择 · 不移动")
        let ids = [a, b, c, sentinel], selected: Set<UUID> = [a, b, c]
        guard let screen = NSScreen.main?.visibleFrame else { throw failure("Native group fixture requires a connected display") }
        let frames = try initialFrames(in: screen)
        for (i, id) in ids.enumerated() {
            let value = PinPresentation(frame: PinWindowFrame(frames[i]), zoom: i == 1 ? 2 : i == 2 ? 1 : nil)
            if let pin = session.liveControllers[id] { pin.applyPresentation(value); pin.onPresentationChange?(pin.presentation) }
            if let pin = session.richControllers[id] { pin.applyPresentation(value); pin.onPresentationChange?(pin.presentation) }
        }
        try session.flushPresentationChanges()
        let original = store.index, assetHashes = try assets(in: directory)
        for id in ids {
            guard let frame = original.entry(id: id)?.presentation.frame.rect else { throw failure("Initial pin missing") }
            try require(screen.contains(frame), "Initial fixture frame is outside the actual visible screen")
        }
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
        let appliedPlan = try session.groupTransforms.plannedTransform(index: original, selectedIDs: selected,
                                                                      transform: .moveAndScale(dx: 25, dy: -15, scale: 1.25))
        let proposedPlan = try PinGroupTransformPlan(index: original, selectedIDs: selected,
                                                     transform: .moveAndScale(dx: 25, dy: -15, scale: 1.25))
        try require(proposedPlan.changes.contains { change in
            let frame = change.after.frame
            return [frame.x, frame.y, frame.width, frame.height].contains { $0 != $0.rounded() }
        }, "Positive fixture lost fractional proposal coverage")
        try require(appliedPlan.changes.allSatisfy { screen.contains($0.after.frame.rect) },
                    "Positive canonical targets exceed the actual visible screen")
        try control(NSButton.self, "pin-group-apply", in: editor.window?.contentView).performClick(nil)
        if session.groupTransforms.editor != nil {
            var diagnostic: [String: Any] = ["status": "failed", "applyOutcome": editor.applyOutcome,
                "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown", "bundlePath": Bundle.main.bundlePath,
                "snapshotBackground": PinWorkflowSnapshot.backgroundDescription,
                "indexUnchanged": store.index == original, "undoCount": session.groupTransforms.history.undoPlans.count,
                "selectedIDs": session.groupTransforms.selectedIDs.map(\.uuidString).sorted(),
                "eligibleIDs": session.groupTransformEligibleIDs.map(\.uuidString).sorted()]
            if let error = editor.lastApplyFailure { diagnostic["applyFailure"] = try object(error) }
            if let failure = session.groupTransforms.lastFailure { diagnostic["transactionFailure"] = try object(failure) }
            do { try snapshot(try window(editor), to: evidenceDirectory.appendingPathComponent("pin-group-apply-failure.png")) }
            catch { diagnostic["snapshotError"] = error.localizedDescription }
            try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidenceDirectory.appendingPathComponent("pin-group-apply-failure.json"), options: .atomic)
            let code = editor.lastApplyFailure?.code ?? "no-captured-error"
            let detail = editor.lastApplyFailure?.message ?? "No transform error was captured"
            throw failure("Apply outcome=\(editor.applyOutcome), code=\(code): \(detail); see pin-group-apply-failure.json for pre-rollback geometry")
        }
        let changed = store.index
        try require(changed == appliedPlan.applying(to: original), "Native move/scale differs from its canonical target plan")
        for change in appliedPlan.changes {
            let actual = session.liveControllers[change.id]?.presentation ?? session.richControllers[change.id]?.presentation
            try require(actual == change.after, "Applied live frame differs from committed canonical target")
        }
        try require(changed != original && changed.entry(id: sentinel) == original.entry(id: sentinel), "Group transform moved sentinel or made no change")
        try require(try assets(in: directory) == assetHashes, "Move/scale rewrote raster or source assets")
        try await settle()
        try control(NSButton.self, "pin-group-undo", in: content).performClick(nil)
        try require(store.index == original, "One native Undo did not restore all three")
        try await settle()
        try control(NSButton.self, "pin-group-redo", in: content).performClick(nil)
        try require(store.index == changed, "One native Redo did not restore all three")
        try await settle()
        try await constrainedNativeAttempt(session: session, store: store, directory: directory,
                                           evidenceDirectory: evidenceDirectory, ids: ids, textID: c, screen: screen)
        let align = try control(NSPopUpButton.self, "pin-group-align", in: content)
        var alignmentResiduals: [String: [String: Double]] = [:]
        for (index, alignment) in PinGroupAlignment.allCases.enumerated() {
            let plan = try session.groupTransforms.plannedTransform(index: store.index, selectedIDs: selected, transform: .align(alignment))
            let expected = try plan.applying(to: store.index)
            let residuals = PinGroupBackingGeometry.centerAlignmentResiduals(plan, alignment: alignment)
            if !residuals.isEmpty { alignmentResiduals[alignment.rawValue] = Dictionary(uniqueKeysWithValues: residuals.map { ($0.key.uuidString, $0.value) }) }
            for change in plan.changes {
                try require(change.after.frame.width == change.before.frame.width && change.after.frame.height == change.before.frame.height,
                            "Alignment changed a member's dimensions")
            }
            align.selectItem(at: index + 1)
            try require(align.sendAction(align.action, to: align.target), "Alignment control did not dispatch")
            try require(store.index == expected, "Native alignment result differs: " + alignment.rawValue)
            try require(store.entry(id: sentinel) == original.entry(id: sentinel), "Alignment moved sentinel")
            try await settle()
        }
        return (selected, assetHashes, alignmentResiduals)
    }
    /// Keep the original sizes and 125% operation; fit only the initial spacing.
    /// Reserve room for translation, pixel-grid rounding and later 3/-2 cycles.
    static func initialFrames(in visible: NSRect) throws -> [NSRect] {
        let width = (visible.width - 48 - 25) / 1.25
        let height = (visible.height - 48) / 1.25
        try require(width >= 340 && height >= 320, "Visible screen is too small for the unscaled mixed-pin fixture")
        let x = visible.minX + 24, y = visible.minY + 39
        var textOffset = min(365, floor(height - 160))
        if textOffset.truncatingRemainder(dividingBy: 4) == 0 { textOffset -= 1 }
        return [NSRect(x: x, y: y, width: 300, height: 180),
                NSRect(x: x + min(360, floor(width - 240)), y: y + min(75, floor(height - 320)), width: 240, height: 320),
                NSRect(x: x + min(60, floor(width - 340)), y: y + textOffset, width: 340, height: 160),
                NSRect(x: visible.maxX - 204, y: visible.minY + min(220, visible.height - 144), width: 180, height: 120)]
    }
    private static func constrainedNativeAttempt(session: PinSessionCoordinator, store: PinSessionStore, directory: URL,
                                                  evidenceDirectory: URL, ids: [UUID], textID: UUID, screen: NSRect) async throws {
        let group = session.groupTransforms, before = store.index
        let undo = group.history.undoPlans, redo = group.history.redoPlans
        let manifest = directory.appendingPathComponent("index.json")
        let manifestBytes = try Data(contentsOf: manifest), assetHashes = try assets(in: directory)
        guard let textFrame = before.entry(id: textID)?.presentation.frame.rect else { throw failure("Constraint fixture text pin missing") }
        group.showEditor()
        guard let editor = group.editor else { throw failure("Constraint inspector missing") }
        defer { editor.close() }
        // Deliberately cross the visible top while remaining mostly on this display.
        // AppKit must constrain the proposal and the exact transaction must reject it.
        try control(NSTextField.self, "pin-group-dx", in: editor.window?.contentView).stringValue = "0"
        try control(NSTextField.self, "pin-group-dy", in: editor.window?.contentView).stringValue = String(Double(screen.maxY + 32 - textFrame.maxY))
        try control(NSTextField.self, "pin-group-scale", in: editor.window?.contentView).stringValue = "100"
        try control(NSButton.self, "pin-group-apply", in: editor.window?.contentView).performClick(nil)
        try require(group.editor === editor && editor.applyOutcome == "failed" && editor.lastApplyFailure?.code == "windowConstraint",
                    "Deliberate native constraint did not reject the complete group")
        guard let diagnostic = group.lastFailure else { throw failure("Constraint rejection diagnostic missing") }
        try require(diagnostic.stage == "verify-target" && diagnostic.expected != diagnostic.actual,
                    "Constraint case did not exercise native target verification")
        try await settle(); try session.flushPresentationChanges()
        try require(store.index == before && group.history.undoPlans == undo && group.history.redoPlans == redo,
                    "Constraint rejection changed the index or history")
        for id in ids {
            let actual = session.liveControllers[id]?.presentation ?? session.richControllers[id]?.presentation
            try require(actual == before.entry(id: id)?.presentation, "Constraint rollback did not restore every selected pin and sentinel")
        }
        try require(try Data(contentsOf: manifest) == manifestBytes, "Constraint rejection rewrote the manifest")
        try require(try assets(in: directory) == assetHashes, "Constraint rejection changed asset bytes")
        let evidence: [String: Any] = ["status": "passed", "stage": "native-window-constraint-rollback",
            "transactionFailure": try object(diagnostic), "visibleFrame": try object(PinWindowFrame(screen)),
            "allFourLivePresentationsRestored": true, "indexUnchanged": true, "manifestBytesUnchanged": true,
            "undoHistoryUnchanged": true, "redoHistoryUnchanged": true, "assetsUnchanged": true]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("pin-group-window-constraint.json"), options: .atomic)
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
        try PinWorkflowSnapshot.write(view, to: url)
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
