import AppKit
import CryptoKit
import PicShotCore
import PicShotFormulaRenderCore

/// Opt-in installed-app gate. Real bundled renderer, shown native pin/popover, private
/// pasteboard and temporary catalog only. Never asks for capture access or downloads models.
@MainActor enum LaTeXPinSmokeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-LaTeXPin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, desktopVisibilityService: PinDesktopVisibilityService(defaults: nil))
        defer { try? coordinator.prepareForTermination() }
        let original = FormulaRenderRequest(latex: #"\frac{a^2+b^2}{\sqrt{1+x}}=\sum_{n=1}^{N}n"#, fontSize: 32)
        let setup = try await exerciseEditorAndExports(coordinator: coordinator, store: store, original: original, evidenceDirectory: evidenceDirectory)
        let id = setup.id, stableFiles = setup.stableFiles, exportSizes = setup.exportSizes
        let stableAssets = try assets(in: directory)
        store.clearThumbnailCache()
        try await settle()
        // The UI/render helper has returned. Its PNG/PDF/SVG result, old controller,
        // model and editor views are out of scope before warm-up and measurement.
        var warmupProbes: [LaTeXPinReleaseProbe] = [], measuredProbes: [LaTeXPinReleaseProbe] = []
        let beforeWarmup = try observedMemory(), warmupSampler = GIFResourceMemorySampler()
        defer { warmupSampler.stop() }
        for _ in 0..<2 { try await cycle(coordinator, store: store, id: id, source: original.latex, probes: &warmupProbes) }
        let warmupStatistics = try stoppedStatistics(warmupSampler)
        try require(warmupProbes.count == 4 && coordinator.livePinCount == 1, "Formula warm-up boundary/probe count mismatch")
        let baseline = try observedMemory(), measuredStarted = ProcessInfo.processInfo.systemUptime, sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        var settled: [GIFResourceMemoryReading] = []; settled.reserveCapacity(12)
        for _ in 0..<12 {
            try await cycle(coordinator, store: store, id: id, source: original.latex, probes: &measuredProbes)
            sampler.sample(); settled.append(try observedMemory())
        }
        guard let measuredEnd = settled.last else { throw failure("Measured formula cycle observations missing") }
        try require(try assets(in: directory) == stableAssets, "Formula lifecycle changed source/raster bytes")
        let teardownProbe = try probe(coordinator, id: id)
        try require(measuredProbes.count == 24, "Formula measured probe count mismatch")
        try coordinator.hideCurrentGroup(); store.clearThumbnailCache()
        try await released(teardownProbe)
        try require(coordinator.livePinCount == 0, "Formula final cleanup retained a live pin")
        try require(try assets(in: directory) == stableAssets, "Formula final cleanup changed source/raster bytes")
        sampler.sample()
        let final = try observedMemory(), measuredStatistics = try stoppedStatistics(sampler)
        let measuredElapsed = ProcessInfo.processInfo.systemUptime - measuredStarted
        let probes = warmupProbes + measuredProbes + [teardownProbe]
        let retainedControllers = probes.filter { $0.controller != nil }.count
        let retainedContent = probes.filter { $0.content != nil }.count
        let retainedModels = probes.filter { $0.model != nil }.count
        try require(retainedControllers == 0 && retainedContent == 0 && retainedModels == 0, "Formula lifecycle retained owned objects")
        let rss = settled.map { $0.residentBytes! }, footprint = settled.map { $0.physicalFootprintBytes! }
        let resource: [String: Any] = [
            "observationsComplete": true, "warmupCycles": 2, "measuredCycles": 12, "completedMeasuredCycles": settled.count,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval, "measuredElapsedSeconds": measuredElapsed,
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
            "beforeWarmup": try object(beforeWarmup), "baselineAfterWarmup": try object(baseline),
            "warmupSampledMemory": try object(warmupStatistics), "sampledMemory": try object(measuredStatistics),
            "settledAfterCycles": try settled.map { try object($0) }, "afterMeasuredCycles": try object(measuredEnd),
            "finalAfterCleanup": try object(final), "livePinsAtBaselineAndCycleEnds": 1, "livePinsAfterCleanup": coordinator.livePinCount,
            "residentGrowthFromWarmupBytes": try delta(measuredEnd.residentBytes, baseline.residentBytes),
            "physicalFootprintGrowthFromWarmupBytes": try delta(measuredEnd.physicalFootprintBytes, baseline.physicalFootprintBytes),
            "residentCleanupDeltaBytes": try delta(final.residentBytes, measuredEnd.residentBytes),
            "physicalFootprintCleanupDeltaBytes": try delta(final.physicalFootprintBytes, measuredEnd.physicalFootprintBytes),
            "residentLastIntervalGrowthBytes": Int64(rss[11]) - Int64(rss[10]),
            "physicalFootprintLastIntervalGrowthBytes": Int64(footprint[11]) - Int64(footprint[10]),
            "residentLateThreeIntervalGrowthBytes": (9...11).map { Int64(rss[$0]) - Int64(rss[$0 - 1]) },
            "physicalFootprintLateThreeIntervalGrowthBytes": (9...11).map { Int64(footprint[$0]) - Int64(footprint[$0 - 1]) },
            "lateIntervalCycles": 1, "warmupReleaseProbes": warmupProbes.count, "measuredReleaseProbes": measuredProbes.count,
            "finalTeardownReleaseProbes": 1, "retainedControllers": retainedControllers, "retainedContentViews": retainedContent,
            "retainedSourceModels": retainedModels, "assetsUnchanged": true, "assetDigests": stableAssets,
            "assetDigestFormat": "byte-count:SHA-256; index.json excluded because archive/presentation metadata changes",
            "fixtureRequestedRendersDuringCycles": 0,
            "memoryIsObservational": true, "stabilityAssessed": false,
            "scope": "Main PicShot process, 2 warm-ups then 12 measured hide/show/close/reopen cycles; no fixture-requested rendering in these cycles. Timer continues through asset-hash validation and final hide/cleanup. Real helper render/edit/export and late-cancel checks occur outside this phase. Not a whole-system, WindowServer, GPU or helper total; sampled peaks can miss transients. No plateau or zero-leak inference"
        ]
        try coordinator.showCurrentGroup()
        try require(store.entry(id: id)?.assetFilenames == stableFiles, "Restore unexpectedly rerendered/replaced source assets")
        guard let closing = coordinator.richControllers[id], let closingModel = closing.latexModel else { throw failure("Missing close test pin") }
        closingModel.source = "e^{i\\pi}+1=0"; closingModel.apply(); closing.close()
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(closingModel.committed == nil && closing.displayedLaTeXRaster == nil && source(store, id: id) == original.latex,
                    "Late close completion changed saved formula")
        try coordinator.openPin(id: id)
        try coordinator.prepareForTermination()
        let restoredStore = try PinSessionStore(directory: directory)
        let restored = PinSessionCoordinator(store: restoredStore, desktopVisibilityService: PinDesktopVisibilityService(defaults: nil))
        defer { try? restored.prepareForTermination() }
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        try require(restored.richControllers[id]?.richDocument?.latex?.source == original.latex && restored.livePinCount == 1,
                    "New-store formula restoration failed")
        let report: [String: Any] = [
            "status": "passed", "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "actualBundledRenderer": true, "nativeEditableSource": true, "sourceCopyVerified": true,
            "atomicSourceRasterEdit": true, "invalidDraftPreservesLastValid": true, "undoVerified": true,
            "cancelAndClosePreserveSavedSource": true, "restoreWithoutAutomaticRendering": true,
            "cycles": 12, "warmupCycles": 2, "maximumUndoSourceEntries": LaTeXPinModel.maximumUndoEntries,
            "exportBytes": exportSizes, "previews": ["latex-managed-pin.png", "latex-inline-editor.png",
                "latex-managed-pin-light.png", "latex-managed-pin-dark.png", "latex-inline-editor-light.png", "latex-inline-editor-dark.png"],
            "pinPreviewBacking": "White presentation backing in both appearances; exported alpha is unchanged",
            "snapshotBackground": PinWorkflowSnapshot.backgroundDescription,
            "screenCaptureStarted": false, "modelDownloaded": false,
            "desktopVisibilityPreferencesIsolated": true, "formulaSaveChooserGeometry": setup.chooserEvidence,
            "resourceEvidence": resource,
            "recognitionScope": "Existing recognized/editable LaTeX uses the same prepared-pin route; this fixture performs no OCR/model inference",
            "resourceScope": "Two explicit warm-ups plus twelve measured lifecycle cycles with continuous parent RSS/physical footprint, weak controller/content/model release and unchanged source/raster hashes; no leak or stability verdict"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("latex-managed-pin.json"), options: .atomic)
        return report
    }
    private static func exerciseEditorAndExports(coordinator: PinSessionCoordinator, store: PinSessionStore,
                                                  original: FormulaRenderRequest, evidenceDirectory: URL) async throws
        -> (id: UUID, stableFiles: [String]?, exportSizes: [String: Int], chooserEvidence: [String: Any]) {
        let rendered = try await FormulaRenderService.shared.render(original)
        let id = try coordinator.add(rich: PreparedRichPin(formula: original, result: rendered))
        try await Task.sleep(nanoseconds: 80_000_000)
        guard let pin = coordinator.richControllers[id], let model = pin.latexModel else { throw failure("Managed formula pin missing") }
        let nativeImageView: NSImageView?
        if let view = pin.window?.contentView { nativeImageView = descendant(NSImageView.self, in: view) } else { nativeImageView = nil }
        let viewImage = nativeImageView?.image
        let pointSizedReconstruction = viewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        var displayEvidence: [String: Any] = [
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundlePath,
            "windowVisible": pin.window?.isVisible == true, "viewHasImage": viewImage != nil,
            "expectedPixelWidth": rendered.width, "expectedPixelHeight": rendered.height,
            "actualPixelWidth": pin.displayedLaTeXRaster?.width as Any? ?? NSNull(),
            "actualPixelHeight": pin.displayedLaTeXRaster?.height as Any? ?? NSNull(),
            "renderScale": original.scale,
            "pointSizedExtractionWidth": pointSizedReconstruction?.width as Any? ?? NSNull(),
            "pointSizedExtractionHeight": pointSizedReconstruction?.height as Any? ?? NSNull(),
            "representationPixels": viewImage?.representations.prefix(8).map { ["width": $0.pixelsWide, "height": $0.pixelsHigh] } ?? []
        ]
        if let size = viewImage?.size { displayEvidence["imagePointSize"] = ["width": Double(size.width), "height": Double(size.height)] }
        try JSONSerialization.data(withJSONObject: displayEvidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("latex-initial-display.json"), options: .atomic)
        try require(pin.window?.isVisible == true, "Managed formula window was not visible; see latex-initial-display.json")
        try require(viewImage != nil, "Managed formula view had no image; see latex-initial-display.json")
        try require(pin.displayedLaTeXRaster?.width == rendered.width && pin.displayedLaTeXRaster?.height == rendered.height,
                    "Validated formula raster dimensions changed; see latex-initial-display.json")
        try snapshot(pin.window?.contentView, to: evidenceDirectory.appendingPathComponent("latex-managed-pin.png"))
        pin.editLaTeX()
        try await Task.sleep(nanoseconds: 100_000_000)
        guard let content = pin.latexEditorContentView, let editor = descendant(NSTextView.self, in: content) else { throw failure("Native editable source control missing") }
        let edited = #"\int_0^1 x^2\,dx=\frac{1}{3}"#
        editor.selectAll(nil); editor.insertText(edited, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(model.source == edited, "Native text editor did not update draft source")
        model.fontSize = 48; model.transparent = true
        try snapshot(content, to: evidenceDirectory.appendingPathComponent("latex-inline-editor.png"))
        model.apply(); await model.waitUntilIdle()
        try require(model.committed?.source == edited && source(store, id: id) == edited, "Edited source was not committed")
        // Transparent exported pixels remain transparent. The pin's white presentation
        // backing keeps black mathematical glyphs readable under both system appearances.
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(nanoseconds: 80_000_000)
            let suffix = dark ? "dark" : "light"
            try snapshot(pin.window?.contentView, to: evidenceDirectory.appendingPathComponent("latex-managed-pin-" + suffix + ".png"))
            try snapshot(pin.latexEditorContentView, to: evidenceDirectory.appendingPathComponent("latex-inline-editor-" + suffix + ".png"))
            try require(pin.window?.backgroundColor == NSColor.white && model.committed?.transparent == true,
                        "Preview backing or retained transparent export option changed")
        }
        NSApp.appearance = oldAppearance
        let validFiles = store.entry(id: id)?.assetFilenames
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        model.copySource(to: board)
        try require(board.string(forType: .string) == edited, "Copy source lost editable LaTeX")
        model.source = #"\frac{"#; model.apply(); await model.waitUntilIdle()
        try require(model.source == #"\frac{"# && model.committed?.source == edited && store.entry(id: id)?.assetFilenames == validFiles,
                    "Invalid edit discarded draft or last valid saved pair")
        model.discardDraft(); model.source = "z"; model.apply(); model.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(source(store, id: id) == edited, "Cancelled render altered saved source")
        model.undo(); await model.waitUntilIdle()
        try require(model.committed?.source == original.latex && source(store, id: id) == original.latex, "Source undo failed")
        model.source = String(repeating: "x", count: FormulaRenderLimits.latexBytes + 1)
        try require(!model.canApply, "LaTeX bound not enforced")
        model.discardDraft()
        var exportSizes: [String: Int] = [:]
        for format in FormulaRenderFormat.allCases {
            var bytes: Data?
            model.export(format) { bytes = $0 }; await model.waitUntilIdle()
            guard let bytes, !bytes.isEmpty else { throw failure("Missing committed export " + format.label) }
            exportSizes[format.rawValue] = bytes.count
            try bytes.write(to: evidenceDirectory.appendingPathComponent("latex-pin-export." + format.fileExtension), options: .atomic)
        }
        pin.dismissLaTeXEditor()
        let chooserEvidence = try await verifySaveChooser(pin)
        let stableFiles = store.entry(id: id)?.assetFilenames
        // Retaining this old model intentionally proves close clears its owned content/history.
        try coordinator.hideCurrentGroup()
        try require(model.isClosed && model.committed == nil && model.source.isEmpty && model.undoSources.isEmpty,
                    "Hide retained editor source/history")
        try require(pin.displayedLaTeXRaster == nil && pin.richDocument == nil && pin.window?.contentView == nil,
                    "Hide retained pin image/document/content")
        try coordinator.showCurrentGroup()
        return (id, stableFiles, exportSizes, chooserEvidence)
    }
    private static func cycle(_ coordinator: PinSessionCoordinator, store: PinSessionStore, id: UUID,
                              source expectedSource: String, probes: inout [LaTeXPinReleaseProbe]) async throws {
        let hidden = try probe(coordinator, id: id)
        try coordinator.hideCurrentGroup()
        try require(coordinator.livePinCount == 0, "Hide retained a live formula pin")
        try await released(hidden)
        try coordinator.showCurrentGroup(); try await settle()
        let archived = try probe(coordinator, id: id)
        try require(coordinator.richControllers[id]?.latexModel?.working == false &&
                    coordinator.richControllers[id]?.latexModel?.saving == false, "Restore unexpectedly started work")
        autoreleasepool { coordinator.richControllers[id]?.close() }
        try require(store.entry(id: id)?.isVisible == false && coordinator.livePinCount == 0, "Close failed to archive/release formula")
        try await released(archived)
        try coordinator.openPin(id: id); try await settle()
        try require(coordinator.livePinCount == 1 && source(store, id: id) == expectedSource &&
                    coordinator.richControllers[id]?.latexModel?.working == false &&
                    coordinator.richControllers[id]?.latexModel?.saving == false,
                    "Reopen duplicated, lost or unexpectedly started formula work")
        probes += [hidden, archived]
    }
    private static func probe(_ coordinator: PinSessionCoordinator, id: UUID) throws -> LaTeXPinReleaseProbe {
        try autoreleasepool {
            guard let controller = coordinator.richControllers[id], let content = controller.window?.contentView,
                  let model = controller.latexModel else { throw failure("Formula release probe needs live owned content/model") }
            return LaTeXPinReleaseProbe(controller: controller, content: content, model: model)
        }
    }
    private static func released(_ probe: LaTeXPinReleaseProbe) async throws {
        for _ in 0..<20 {
            try await settle()
            if probe.controller == nil && probe.content == nil && probe.model == nil { return }
        }
        throw failure("Formula controller/content/source model did not release after hide or close")
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 60_000_000) }
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
    /// Real remote-backed NSSavePanel geometry, not fabricated/cached panel pixels.
    private static func verifySaveChooser(_ pin: RichPinController) async throws -> [String: Any] {
        guard let window = pin.window, let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            throw failure("Save chooser placement requires a real screen")
        }
        let compactFrame = NSRect(x: visible.minX + 8, y: visible.maxY - 72 - 8, width: 180, height: 72)
        var value = pin.presentation; value.frame = PinWindowFrame(compactFrame)
        pin.applyPresentation(value); pin.onPresentationChange?(pin.presentation)
        let before = window.frame
        try require(before == compactFrame, "Native pin did not accept the explicit compact edge fixture frame")
        pin.beginLaTeXSave(.latex)
        defer { pin.dismissLaTeXEditor() }
        guard let panel = pin.latexSavePanel else { throw failure("Formula Save chooser missing") }
        var previousFrame: NSRect?, stableObservations = 0
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if panel.isVisible && panel.sheetParent === window && panel.frame.width > 0 && panel.frame.height > 0 {
                stableObservations = previousFrame == panel.frame ? stableObservations + 1 : 1
                previousFrame = panel.frame
                if stableObservations >= 3 { break }
            } else { previousFrame = nil; stableObservations = 0 }
        }
        let chooserFrame = panel.frame
        try require(stableObservations >= 3 && panel.isVisible && panel.sheetParent === window,
                    "Formula Save chooser did not reach stable visible/owned geometry")
        try require(visible.contains(chooserFrame), "Compact edge formula Save chooser extends off-screen")
        try require(window.frame == before, "Showing formula Save chooser moved the pin")
        pin.dismissLaTeXEditor()
        for _ in 0..<30 { if !panel.isVisible && window.attachedSheet == nil { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        try require(!panel.isVisible && window.attachedSheet == nil && pin.latexSavePanel == nil,
                    "Cancelled formula Save chooser left an orphan sheet")
        try require(window.frame == before, "Cancelling formula Save chooser moved the pin")
        func rect(_ frame: NSRect) -> [String: Double] {
            ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
        }
        return ["status": "passed", "nativeWindowGeometryOnly": true, "pixelsCaptured": false,
                "compactRequestedFrame": rect(compactFrame), "stableVisibleFrameObservations": stableObservations,
                "pinBefore": rect(before), "pinAfterCancel": rect(window.frame), "chooserFrame": rect(chooserFrame),
                "screenVisibleFrame": rect(visible), "chooserWasVisible": true, "ownedSheetVerified": true,
                "fullyOnScreen": true, "pinFrameUnchanged": true, "cancelledWithoutOrphanSheet": true]
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
    private static func source(_ store: PinSessionStore, id: UUID) -> String? {
        guard let bytes = try? store.richData(id: id), let document = try? JSONDecoder().decode(PinRichDocument.self, from: bytes) else { return nil }
        return document.latex?.source
    }
    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews { if let found = descendant(type, in: child) { return found } }
        return nil
    }
    private static func snapshot(_ view: NSView?, to url: URL) throws {
        guard let view else { throw failure("Missing native preview view") }
        try PinWorkflowSnapshot.write(view, to: url)
    }
    private static func require(_ condition: Bool, _ detail: String) throws { if !condition { throw failure(detail) } }
    private static func failure(_ detail: String) -> Error { PicShotError.message("LaTeX pin acceptance: " + detail) }
}

@MainActor private final class LaTeXPinReleaseProbe {
    weak var controller: RichPinController?
    weak var content: NSView?
    weak var model: LaTeXPinModel?
    init(controller: RichPinController, content: NSView, model: LaTeXPinModel) {
        self.controller = controller; self.content = content; self.model = model
    }
}
