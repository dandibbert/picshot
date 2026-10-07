import AppKit
import CoreText
import CryptoKit
import PicShotCore

/// Installed-app acceptance of production region matching, native review/actions,
/// and flattened export. All input pixels are authored locally. No screen read,
/// global events, clipboard access, preferences, network, or new OS permissions.
@MainActor enum AutomaticMosaicWorkflowSmokeFixture {
    static let overallDeadlineSeconds: Double = 240
    static let warmupCycles = 2
    static let measuredCycles = 12
    static let sourceWidth = 720, sourceHeight = 480
    /// Top-left source pixels, deliberately odd positions. The third is a small
    /// color variant; the fourth contains a removed glyph stroke and must fail.
    static let authoredRegions = [CGRect(x: 31, y: 37, width: 144, height: 48),
                                  CGRect(x: 287, y: 123, width: 144, height: 48),
                                  CGRect(x: 497, y: 301, width: 144, height: 48)]
    static let nearNonmatch = CGRect(x: 59, y: 329, width: 144, height: 48)

    static func verify(evidenceDirectory: URL, includeResourceCycles: Bool = true) async throws -> [String: Any] {
        _ = NSApplication.shared
        try require(evidenceDirectory.isFileURL && NSScreen.main != nil, "Local evidence directory and WindowServer required")
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + overallDeadlineSeconds
        _ = try await CaptureUIPreviewFixture.waitForDisplayGeometryQuiet()
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let raster = try authoredRaster(), sourceBefore = try rgba(raster)
        try raster.writePNG(to: evidenceDirectory.appendingPathComponent("automatic-mosaic-input.png"))
        let calls = AutomaticMosaicActualCallCounter()
        let functional = try await verifyControls(raster: raster, calls: calls, directory: evidenceDirectory, deadline: deadline)
        let functionalCalls = calls.started
        let resources: [String: Any]
        if includeResourceCycles { resources = try await verifyResources(raster: raster, calls: calls, deadline: deadline) }
        else { resources = ["status": "not-run", "reason": "includeResourceCycles=false; early native UI/export evidence only",
                            "warmupCycles": 0, "completedMeasuredCycles": 0, "actualMatcherCalls": 0] }
        let resourceCalls = calls.started - functionalCalls
        let largeImageTimings: [String: Any]
        if includeResourceCycles { largeImageTimings = try await verifyLargeImageTimings(tileSource: raster, deadline: deadline) }
        else { largeImageTimings = ["status": "not-run", "reason": "Full installed release acceptance only", "completedSearches": 0] }
        let sourceAfter = try rgba(raster)
        try require(sourceBefore == sourceAfter && calls.active == 0, "Source bytes changed or matcher remains active")
        let files = ["automatic-mosaic-input.png", "automatic-mosaic-review-light.png", "automatic-mosaic-review-dark.png",
                     "automatic-mosaic-edge.png", "automatic-mosaic-redact.png", "automatic-mosaic-redact-excluded.png",
                     "automatic-mosaic-blur.png", "automatic-mosaic-pixelate.png"]
        var hashes: [String: String] = [:]
        for name in files { hashes[name] = sha(try Data(contentsOf: evidenceDirectory.appendingPathComponent(name))) }
        try checkDeadline(deadline)
        let report: [String: Any] = [
            "status": "passed", "schemaVersion": 1,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown", "bundlePath": Bundle.main.bundlePath,
            "overallDeadlineSeconds": overallDeadlineSeconds, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "includeResourceCycles": includeResourceCycles, "actualProductionMatcherRan": true,
            "actualFunctionalMatcherCalls": functionalCalls, "actualResourceMatcherCalls": resourceCalls,
            "sourceWidth": sourceWidth, "sourceHeight": sourceHeight, "sourceRGBAHashBefore": sha(sourceBefore),
            "sourceRGBAHashAfter": sha(sourceAfter), "sourceByteIdentityVerified": true,
            "authoredRepeatRects": authoredRegions.map(rectangleObject), "authoredNearNonmatchRect": rectangleObject(nearNonmatch),
            "controls": functional.controls, "exports": functional.exports, "resourceEvidence": resources, "largeImageTimings": largeImageTimings,
            "evidenceFiles": files, "fileSHA256": hashes, "snapshotBackground": PinWorkflowSnapshot.backgroundDescription,
            "screenCaptureStarted": false, "permissionRequests": false, "networkUsed": false, "globalInputPosted": false,
            "generalPasteboardReadOrWritten": false, "standardUserDefaultsChanged": false, "physicalRetinaVerified": false,
            "externalApplicationVerified": false, "arbitraryImageAccuracyVerified": false, "zeroLeakClaim": false,
            "scope": "720×480 authored CoreText name/icon/color/alpha raster; real conservative same-size matcher; native seed/select/find/review/include/apply/sync/undo/crop/edit/cancel/close paths and PNG exports. Delayed stale callbacks contain actual matcher results. Full only:2 warmups+12 measured small match/review/apply/close cycles, followed by separate one-shot4K/5K release matcher timings. Self-process sampled RSS/footprint can miss transients; excludes sustained large-image performance, WindowServer/GPU totals, plateau, zero leaks, physical Retina and arbitrary-image accuracy. Blur/pixelate are cosmetic only."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("automatic-mosaic-workflow.json"), options: .atomic)
        return report
    }

    private static func makeEditor(raster: CGImage, calls: AutomaticMosaicActualCallCounter,
                                   gate: AutomaticMosaicActualCompletionGate? = nil) -> ImageEditorController {
        let editor = ImageEditorController(image: raster, onSave: { _ in calls.outputCallbacks += 1 },
            onPin: { _ in calls.outputCallbacks += 1 }, onOCR: { _ in calls.outputCallbacks += 1 },
            copyAction: { _ in calls.outputCallbacks += 1 })
        // The seam wraps the exact production matcher. It cannot supply invented
        // candidates; the optional gate delays only an already completed result.
        editor.automaticMosaicFind = { image, seed in
            calls.started += 1; calls.active += 1
            defer { calls.active -= 1 }
            let result = try await calls.matcher.findMatches(in: image, seed: seed)
            calls.completed += 1
            if let gate { await gate.waitAfterActualMatch() }
            return result
        }
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        editor.show(near: CGRect(x: visible.midX - CGFloat(raster.width) / 2,
                                y: visible.midY - CGFloat(raster.height) / 2,
                                width: CGFloat(raster.width), height: CGFloat(raster.height)))
        return editor
    }
    private static func drawSeed(_ editor: ImageEditorController, tool: ImageEditorTool) throws {
        try nativeTool(tool, in: editor)
        try drag(editor.annotationCanvas, rect: canvasRect(authoredRegions[0]))
        try require(editor.annotationCanvas.annotations.count == 1, "Seed gesture failed")
        try require(editor.annotationCanvas.annotations[0].localBounds.standardized.integral == canvasRect(authoredRegions[0]),
                    "Native gesture does not cover the exact authored seed pixel bounds")
        try nativeTool(.select, in: editor)
        try click("annotation.automaticMosaic", in: editor)
    }
    private static func ready(_ editor: ImageEditorController, deadline: Double) async throws {
        try await waitUntil(deadline: deadline, detail: "Production matcher completion") { !editor.automaticMosaicIsComputing }
        let state = try required(editor.automaticMosaicReviewState, "Review disappeared")
        try require(state.phase == .ready, "Matcher refused workload: " + state.message)
        try require(state.candidates.count == 3 && state.includedCount == 3 && !state.truncated, "Expected exactly three authored repeats")
        if !authoredRegions.allSatisfy({ rect in state.candidates.filter { $0.rect == canvasRect(rect) }.count == 1 }) {
            let originalSeed = authoredRegions[0]
            let direct = try await AutomaticMosaicMatcher().findMatches(in: editor.annotationCanvas.image,
                seed: .init(x: Int(originalSeed.minX), y: Int(originalSeed.minY), width: Int(originalSeed.width), height: Int(originalSeed.height)))
            let directBoxes = direct.candidates.map { "\($0.rect.x),\($0.rect.y),\($0.rect.width),\($0.rect.height)" }.joined(separator: ";")
            throw failure("Matcher lost/duplicated expected region; drawn seed=" + NSStringFromRect(state.seed.localBounds)
                + "; reviewed=" + state.candidates.map { NSStringFromRect($0.rect) }.joined(separator: ";")
                + "; expected=" + authoredRegions.map { NSStringFromRect(canvasRect($0)) }.joined(separator: ";")
                + "; zoom=\(editor.annotationCanvas.zoom),\(editor.annotationCanvas.displayScaleY); direct source candidates=" + directBoxes)
        }
        try require(!state.candidates.contains { $0.rect == canvasRect(nearNonmatch) }, "Changed glyph was treated as repeated content")
    }
    private static func verifyControls(raster: CGImage, calls: AutomaticMosaicActualCallCounter, directory: URL, deadline: Double)
        async throws -> (controls: [String: Any], exports: [[String: Any]]) {
        var exports: [[String: Any]] = []
        for (mode, tool) in [("redact", ImageEditorTool.redact), ("redact-excluded", .redact), ("blur", .blur), ("pixelate", .pixelate)] {
            var editor: ImageEditorController? = makeEditor(raster: raster, calls: calls)
            let probe = AutomaticMosaicWorkflowReleaseProbe(editor!)
            defer { editor?.close() }
            try drawSeed(editor!, tool: tool)
            try await ready(editor!, deadline: deadline)
            probe.observeReview(editor!.automaticMosaicReviewSurface)
            try require(editor!.annotationCanvas.annotations.count == 1, "Review mutated annotations before Apply")
            try verifyOutputBlocked(editor!, calls: calls)
            if mode == "redact" {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    editor!.window?.appearance = NSAppearance(named: appearance)
                    try await settle(editor!, deadline: deadline)
                    try verifyControlFrames(editor!)
                    try PinWorkflowSnapshot.write(try required(editor!.window?.contentView, "Review content absent"),
                        to: directory.appendingPathComponent("automatic-mosaic-review-\(name).png"))
                }
            }
            // Navigate to an exact known candidate using actual next/include controls.
            for _ in 0..<3 {
                let state = try required(editor!.automaticMosaicReviewState, "Review missing while navigating")
                if state.candidates[state.selectedIndex].rect == canvasRect(authoredRegions[2]) { break }
                try click("mosaic.review.next", in: editor!)
            }
            let target = try required(editor!.automaticMosaicReviewState, "Review selection missing")
            try require(target.candidates[target.selectedIndex].rect == canvasRect(authoredRegions[2]), "Native navigation missed target")
            try verifyFocusedCandidateVisible(editor!)
            try click("mosaic.review.include", in: editor!)
            try require(editor!.automaticMosaicReviewState?.includedCount == 2, "Native exclusion failed")
            if mode != "redact-excluded" {
                try click("mosaic.review.include", in: editor!)
                try require(editor!.automaticMosaicReviewState?.includedCount == 3, "Native reinclusion failed")
            }
            try click("mosaic.review.apply", in: editor!)
            let regions = mode == "redact-excluded" ? Array(authoredRegions.prefix(2)) : authoredRegions
            try require(editor!.automaticMosaicReviewState == nil && editor!.annotationCanvas.annotations.count == regions.count,
                        "Apply did not create included regions only")
            try verifyOutputRestored(editor!, calls: calls)
            exports.append(try export(editor!, mode: mode, regions: regions, directory: directory))
            let committedIDs = editor!.annotationCanvas.annotations.map(\.id)
            try click("editor.undo", in: editor!)
            try require(editor!.annotationCanvas.annotations.count == 1 && editor!.annotationCanvas.annotations[0].mosaicLink == nil,
                        "Apply was not one undo step")
            try click("editor.redo", in: editor!)
            try require(editor!.annotationCanvas.annotations.map(\.id) == committedIDs, "Redo did not restore exact group")
            if mode == "redact" { try verifySync(editor!) }
            editor!.close(); editor = nil
            try await released([probe], calls: calls, deadline: deadline)
        }
        let edges = try await verifyEdges(raster: raster, calls: calls, directory: directory, deadline: deadline)
        let races = try await verifyInvalidation(raster: raster, calls: calls, deadline: deadline)
        return (["status": "passed", "productionActionsUsed": true,
                 "checks": ["native-seed-drag", "selected-seed-find", "review-before-apply", "native-candidate-exclude-include",
                            "excluded-candidate-preserved", "near-nonmatch-excluded", "apply-one-undo-step", "undo-redo",
                            "sync-add-on", "sync-add-off", "sync-delete-on", "sync-delete-off", "crop-invalidates-review",
                            "edit-invalidates-review", "cancel-discards-preview", "close-discards-preview",
                            "stale-completion-ignored", "native-edge-controls", "light-dark-native-png",
                            "review-blocks-output", "apply-cancel-restores-output", "focused-candidate-visible"],
                 "staleRaceUsesRealMatcherResult": true, "staleCallbacksRejected": races,
                 "staleRaceBoundary": "actual matcher completed; result delivery held until after invalidation",
                 "activeScanCancellationVerifiedHere": false,
                 "edgePlacements": edges, "finalActiveJobs": calls.active], exports)
    }

    private static func verifySync(_ editor: ImageEditorController) throws {
        let canvas = editor.annotationCanvas
        try nativeTool(.select, in: editor)
        let seed = canvasRect(authoredRegions[0])
        try select(canvas, at: CGPoint(x: seed.midX, y: seed.midY))
        try require(canvas.selectedAnnotation?.mosaicLink?.synchronizes == true, "Applied sync default absent")
        try click("annotation.mosaicAdd", in: editor)
        try drag(canvas, rect: CGRect(x: seed.minX + 8, y: seed.minY + 5, width: 21, height: 9))
        try require(canvas.annotations.count == 6, "Sync-on correction was not added at every included origin")
        let group = try required(canvas.selectedAnnotation?.mosaicLink?.additionID, "Correction group absent")
        try require(canvas.annotations.filter { $0.mosaicLink?.additionID == group }.count == 3, "Correction linkage missing")
        try key(canvas, code: 51, value: "\u{7f}")
        try require(canvas.annotations.count == 3, "Sync-on delete did not remove corresponding corrections")
        try click("editor.undo", in: editor)
        try require(canvas.annotations.count == 6, "Sync delete undo failed")
        try click("editor.redo", in: editor)
        try require(canvas.annotations.count == 3, "Sync delete redo failed")
        try select(canvas, at: CGPoint(x: seed.midX, y: seed.midY))
        try click("annotation.mosaicSync", in: editor)
        try require(canvas.annotations.allSatisfy { $0.mosaicLink?.synchronizes == false }, "Sync-off toggle failed")
        try click("annotation.mosaicAdd", in: editor)
        try drag(canvas, rect: CGRect(x: seed.minX + 9, y: seed.minY + 6, width: 19, height: 8))
        try require(canvas.annotations.count == 4, "Sync-off correction changed other regions")
        try key(canvas, code: 51, value: "\u{7f}")
        try require(canvas.annotations.count == 3, "Sync-off delete changed other corrections")
        try select(canvas, at: CGPoint(x: seed.midX, y: seed.midY))
        try key(canvas, code: 51, value: "\u{7f}")
        try require(canvas.annotations.count == 2, "Sync-off seed deletion propagated")
        try click("editor.undo", in: editor)
        try require(canvas.annotations.count == 3, "Local deletion undo failed")
    }

    private static func verifyEdges(raster: CGImage, calls: AutomaticMosaicActualCallCounter, directory: URL, deadline: Double) async throws -> [String] {
        let visible = try required(NSScreen.main, "No native display").visibleFrame
        var placements: [String] = []
        for label in ["top-left", "top-right", "bottom-left", "bottom-right"] {
            var editor: ImageEditorController? = makeEditor(raster: raster, calls: calls)
            let probe = AutomaticMosaicWorkflowReleaseProbe(editor!)
            defer { editor?.close() }
            let window = try required(editor!.window, "Edge window absent")
            let size = window.frame.size
            try require(size.width <= visible.width && size.height <= visible.height, "Native display cannot contain test editor")
            window.setFrameOrigin(CGPoint(x: label.hasSuffix("left") ? visible.minX : visible.maxX - size.width,
                                          y: label.hasPrefix("top") ? visible.maxY - size.height : visible.minY))
            // Exercise the native direct-draw automatic menu route as well.
            let menu = try required(descendants(window.contentView).compactMap { $0 as? NSPopUpButton }.flatMap { $0.itemArray }
                .first { $0.identifier?.rawValue == "editor.automaticMosaic" }, "Automatic native menu absent")
            try require(NSApp.sendAction(try required(menu.action, "Automatic action absent"), to: menu.target, from: menu), "Automatic menu failed")
            try drag(editor!.annotationCanvas, rect: canvasRect(authoredRegions[0]))
            try await ready(editor!, deadline: deadline); probe.observeReview(editor!.automaticMosaicReviewSurface)
            try require(editor!.annotationCanvas.annotations.isEmpty, "Direct automatic drawing committed before review")
            try await settle(editor!, deadline: deadline)
            try verifyControlFrames(editor!)
            try verifyFocusedCandidateVisible(editor!)
            for id in ["mosaic.review.apply", "mosaic.review.cancel", "mosaic.review.include", "mosaic.review.sync", "mosaic.review.add"] {
                let value = try control(id, in: editor!)
                let screenRect = window.convertToScreen(value.convert(value.bounds, to: nil))
                try require(visible.insetBy(dx: -0.5, dy: -0.5).contains(screenRect), "Control off screen at " + label + ": " + id)
            }
            if label == "bottom-right" { try PinWorkflowSnapshot.write(try required(window.contentView, "Edge content absent"), to: directory.appendingPathComponent("automatic-mosaic-edge.png")) }
            try click("mosaic.review.cancel", in: editor!)
            try require(editor!.automaticMosaicReviewState == nil && editor!.annotationCanvas.annotations.isEmpty, "Cancel retained direct preview")
            try verifyOutputRestored(editor!, calls: calls)
            placements.append(label); editor!.close(); editor = nil
            try await released([probe], calls: calls, deadline: deadline)
        }
        return placements
    }

    private static func verifyControlFrames(_ editor: ImageEditorController) throws {
        let root = try required(editor.window?.contentView, "Native root missing")
        for id in ["mosaic.review.previous", "mosaic.review.next", "mosaic.review.include", "mosaic.review.add",
                   "mosaic.review.sync", "mosaic.review.apply", "mosaic.review.cancel"] {
            let value = try control(id, in: editor)
            try require(value.isEnabled && !value.isHiddenOrHasHiddenAncestor && value.target != nil && value.action != nil,
                        "Inactive native review control: " + id)
            let frame = root.convert(value.bounds, from: value)
            try require(frame.width >= 16 && frame.height >= 12 && root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Clipped native review control: " + id)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let hit = root.hitTest(center)
            try require(hit === value || hit?.isDescendant(of: value) == true, "Review control fails native hit test: " + id)
        }
    }
    private static func verifyFocusedCandidateVisible(_ editor: ImageEditorController) throws {
        let root = try required(editor.window?.contentView, "Native root missing")
        let state = try required(editor.automaticMosaicReviewState, "Focused candidate missing")
        let canvas = editor.annotationCanvas, rect = state.candidates[state.selectedIndex].rect
        let candidate = root.convert(CGRect(x: rect.minX * canvas.zoom, y: rect.minY * canvas.displayScaleY,
            width: rect.width * canvas.zoom, height: rect.height * canvas.displayScaleY), from: canvas)
        let panel = root.convert(editor.automaticMosaicReviewSurface.bounds, from: editor.automaticMosaicReviewSurface)
        try require(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(candidate) && !candidate.intersects(panel),
                    "Review covers/clips focused candidate")
    }

    private static func verifyOutputBlocked(_ editor: ImageEditorController, calls: AutomaticMosaicActualCallCounter) throws {
        let before = calls.outputCallbacks
        for id in ["editor.copy", "editor.save", "editor.pin", "editor.ocr"] {
            let value = try control(id, in: editor)
            try require(!value.isEnabled, "Review left output control enabled: " + id)
        }
        let copy = try control("editor.copy", in: editor)
        // Exercise the responder shortcut and the production selector guard;
        // our private callback counts output without touching any pasteboard.
        _ = editor.annotationCanvas.performKeyEquivalent(with: try copyKey(editor.annotationCanvas))
        try require(NSApp.sendAction(try required(copy.action, "Copy action absent"), to: copy.target, from: copy), "Copy guard dispatch failed")
        try require(calls.outputCallbacks == before, "Unreviewed output escaped through copy shortcut/action")
    }
    private static func verifyOutputRestored(_ editor: ImageEditorController, calls: AutomaticMosaicActualCallCounter) throws {
        let before = calls.outputCallbacks
        try click("editor.copy", in: editor)
        try require(calls.outputCallbacks == before + 1, "Apply/Cancel did not restore production output")
    }
    private static func copyKey(_ canvas: ImageEditorCanvas) throws -> NSEvent {
        try required(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8), "Native copy shortcut unavailable")
    }

    private static func verifyInvalidation(raster: CGImage, calls: AutomaticMosaicActualCallCounter, deadline: Double) async throws -> Int {
        var rejected = 0
        for action in ["cancel", "crop", "edit", "close"] {
            let gate = AutomaticMosaicActualCompletionGate()
            var editor: ImageEditorController? = makeEditor(raster: raster, calls: calls, gate: gate)
            let probe = AutomaticMosaicWorkflowReleaseProbe(editor!)
            defer { gate.release(); editor?.close() }
            try drawSeed(editor!, tool: .redact)
            try await waitUntil(deadline: deadline, detail: "Actual matcher finished before stale gate") { gate.holdingActualResult }
            try require(editor!.automaticMosaicReviewState?.phase == .searching && editor!.annotationCanvas.annotations.count == 1,
                        "Gate bypassed actual searching state")
            probe.observeReview(editor!.automaticMosaicReviewSurface)
            switch action {
            case "cancel": try click("mosaic.review.cancel", in: editor!)
            case "crop":
                try nativeTool(.crop, in: editor!)
                try drag(editor!.annotationCanvas, rect: CGRect(x: 10, y: 10, width: 690, height: 450))
                try click("editor.applyCrop", in: editor!)
                try require(editor!.annotationCanvas.image.width == 690 && editor!.annotationCanvas.image.height == 450, "Native crop did not change source revision")
            case "edit":
                try nativeTool(.rectangle, in: editor!)
                try drag(editor!.annotationCanvas, rect: CGRect(x: 250, y: 240, width: 80, height: 40))
                try require(editor!.annotationCanvas.annotations.count == 2, "Native edit did not change revision")
            default: editor!.close()
            }
            let count = editor!.annotationCanvas.annotations.count, identity = ObjectIdentifier(editor!.annotationCanvas.image)
            try require(editor!.automaticMosaicReviewState == nil, "Invalidation retained review: " + action)
            gate.release()
            try await waitUntil(deadline: deadline, detail: "Stale actual result returned") { calls.active == 0 }
            try await settle(deadline: deadline)
            try require(editor!.automaticMosaicReviewState == nil && !editor!.automaticMosaicIsComputing &&
                        editor!.annotationCanvas.annotations.count == count && ObjectIdentifier(editor!.annotationCanvas.image) == identity,
                        "Stale actual result resurrected/changed editor after " + action)
            if action == "close" { try require(editor!.isClosed && editor!.window?.contentView == nil, "Closed editor resurrected content") }
            rejected += 1; editor!.close(); editor = nil
            try await released([probe], calls: calls, deadline: deadline)
        }
        return rejected
    }

    private static func verifyResources(raster: CGImage, calls: AutomaticMosaicActualCallCounter, deadline: Double) async throws -> [String: Any] {
        let initialCalls = calls.started, initialCompleted = calls.completed
        let beforeWarmup = try observedMemory(), warmupSampler = GIFResourceMemorySampler()
        defer { warmupSampler.stop() }
        var warmupProbes: [AutomaticMosaicWorkflowReleaseProbe] = []
        for _ in 0..<warmupCycles {
            warmupProbes.append(try await actualCycle(raster: raster, calls: calls, deadline: deadline))
            try await released(warmupProbes, calls: calls, deadline: deadline); try await settle(deadline: deadline)
        }
        let warmupStatistics = try stoppedStatistics(warmupSampler), baseline = try observedMemory()
        let started = ProcessInfo.processInfo.systemUptime, sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        var measuredProbes: [AutomaticMosaicWorkflowReleaseProbe] = [], settled: [GIFResourceMemoryReading] = []
        for _ in 0..<measuredCycles {
            measuredProbes.append(try await actualCycle(raster: raster, calls: calls, deadline: deadline))
            try await released(measuredProbes, calls: calls, deadline: deadline); try await settle(deadline: deadline)
            sampler.sample(); settled.append(try observedMemory())
        }
        let measuredEnd = try required(settled.last, "Measured resource endpoints absent"), probes = warmupProbes + measuredProbes
        try await released(probes, calls: calls, deadline: deadline); try await settle(deadline: deadline)
        sampler.sample()
        let final = try observedMemory(), statistics = try stoppedStatistics(sampler)
        try require(calls.started - initialCalls == warmupCycles + measuredCycles && calls.completed - initialCompleted == warmupCycles + measuredCycles && calls.active == 0,
                    "Resource cycle did not perform exactly one actual match")
        let rss = settled.map { Int64($0.residentBytes!) }, footprint = settled.map { Int64($0.physicalFootprintBytes!) }
        return ["status": "passed", "observationsComplete": true, "warmupCycles": warmupCycles,
                "measuredCycles": measuredCycles, "completedMeasuredCycles": settled.count,
                "actualMatcherCalls": calls.started - initialCalls, "appliedCycles": warmupCycles + measuredCycles,
                "sameAuthoredRasterEachCycle": true, "fixedInputRasterCountAtBaselineAndEveryCycleEnd": 1,
                "liveEditorsAtBaselineAndEveryCycleEnd": 0, "activeJobsAtBaselineAndEveryCycleEnd": calls.active,
                "sampleIntervalSeconds": GIFResourceMemorySampler.interval, "settlingDelaySeconds": 0.15,
                "measuredElapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
                "beforeWarmup": try object(beforeWarmup), "baselineAfterWarmup": try object(baseline),
                "warmupSampledMemory": try object(warmupStatistics), "sampledMemory": try object(statistics),
                "settledAfterCycles": try settled.map { try object($0) }, "afterMeasuredCycles": try object(measuredEnd),
                "finalAfterCleanup": try object(final),
                "residentGrowthFromWarmupBytes": rss[11] - Int64(baseline.residentBytes!),
                "physicalFootprintGrowthFromWarmupBytes": footprint[11] - Int64(baseline.physicalFootprintBytes!),
                "residentLastIntervalGrowthBytes": rss[11] - rss[10],
                "physicalFootprintLastIntervalGrowthBytes": footprint[11] - footprint[10],
                "residentLateThreeIntervalGrowthBytes": (9...11).map { rss[$0] - rss[$0 - 1] },
                "physicalFootprintLateThreeIntervalGrowthBytes": (9...11).map { footprint[$0] - footprint[$0 - 1] },
                "residentCleanupDeltaBytes": Int64(final.residentBytes!) - rss[11],
                "physicalFootprintCleanupDeltaBytes": Int64(final.physicalFootprintBytes!) - footprint[11],
                "lateIntervalCycles": 1, "warmupReleaseProbes": warmupProbes.count, "measuredReleaseProbes": measuredProbes.count,
                "retainedObjects": probes.reduce(0) { $0 + $1.retainedCount }, "releaseEvidence": releaseObject(probes),
                "snapshotsInsideMeasuredLoop": 0, "memoryPressureOrSystemSettingsChanged": false,
                "memoryIsObservational": true, "stabilityAssessed": false,
                "scope": "2 warmups + 12 measured native show/seed/select/match/review/Apply/flatten/close cycles. Equal zero-live-editor/zero-active-job boundaries retain one constant720×480 authored CGImage and the constant matcher/counter. Each flattened result is checked and released inside its cycle; no PNG or screenshot in measured loop. Existing self-process sampler, not WindowServer/GPU totals, plateau or zero-leak proof."]
    }
    private static func actualCycle(raster: CGImage, calls: AutomaticMosaicActualCallCounter, deadline: Double) async throws -> AutomaticMosaicWorkflowReleaseProbe {
        try checkDeadline(deadline)
        let before = calls.started
        var editor: ImageEditorController? = autoreleasepool { makeEditor(raster: raster, calls: calls) }
        let probe = AutomaticMosaicWorkflowReleaseProbe(editor!)
        defer { editor?.close() }
        try drawSeed(editor!, tool: .redact)
        try await ready(editor!, deadline: deadline); probe.observeReview(editor!.automaticMosaicReviewSurface)
        try click("mosaic.review.apply", in: editor!)
        try require(editor!.annotationCanvas.annotations.count == 3 && editor!.automaticMosaicReviewState == nil && calls.started == before + 1,
                    "Resource cycle failed actual match/review/apply")
        try autoreleasepool {
            let output = try required(editor!.annotationCanvas.flattened(), "Resource production export failed")
            try require(output.width == raster.width && output.height == raster.height, "Resource export extent changed")
        }
        editor!.close(); editor = nil
        return probe
    }
    private static func released(_ probes: [AutomaticMosaicWorkflowReleaseProbe], calls: AutomaticMosaicActualCallCounter, deadline: Double) async throws {
        try await waitUntil(deadline: deadline, detail: "Controller/content/review/matcher release") {
            probes.allSatisfy { $0.retainedCount == 0 } && calls.active == 0
        }
    }
    private static func releaseObject(_ probes: [AutomaticMosaicWorkflowReleaseProbe]) -> [String: Int] {
        ["probeCount": probes.count, "retainedControllers": probes.filter { $0.controller != nil }.count,
         "retainedCanvases": probes.filter { $0.canvas != nil }.count, "retainedContentViews": probes.filter { $0.content != nil }.count,
         "retainedReviewSurfaces": probes.filter { $0.review != nil }.count]
    }

    private static func verifyLargeImageTimings(tileSource: CGImage, deadline: Double) async throws -> [String: Any] {
        #if DEBUG
        throw failure("Full installed matcher timing requires a release build; the production8-second budget is never relaxed")
        #else
        var runs: [[String: Any]] = []
        for (label, width, height) in [("4k", 3840, 2160), ("5k", 5120, 2880)] {
            try checkDeadline(deadline)
            runs.append(try await largeImageTiming(label: label, width: width, height: height, tileSource: tileSource))
        }
        return ["status": "passed", "completedSearches": runs.count, "buildMode": "release", "runs": runs,
                "productionDeadlineSeconds": 8, "resourceCycleMeasurementIncluded": false,
                "scope": "One actual production match per size, with real conversion+scan inside the unchanged8-second service deadline. Separate authored-source construction timing. Exact geometry, close nonmatch rejection and source backing byte identity checked. One-shot timings do not establish sustained large-image performance."]
        #endif
    }
    private static func largeImageTiming(label: String, width: Int, height: Int, tileSource: CGImage) async throws -> [String: Any] {
        let seed = CGRect(x: 31, y: 47, width: 144, height: 48)
        let targets = [CGRect(x: 1919, y: 1081, width: 144, height: 48),
                       CGRect(x: width - 159, y: height - 71, width: 144, height: 48)]
        let decoy = CGRect(x: 113, y: 157, width: 144, height: 48)
        let creationStarted = ProcessInfo.processInfo.systemUptime
        let image: CGImage = try autoreleasepool {
            let small = try required(tileSource.dataProvider?.data, "Small authored source data missing") as Data
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(211 + (x / 23) % 19)
                pixels[offset + 1] = UInt8(215 + (y / 17) % 17)
                pixels[offset + 2] = UInt8(225 + ((x + y) / 29) % 13)
            } }
            for (source, destination) in zip(authoredRegions + [nearNonmatch], [seed] + targets + [decoy]) {
                for y in 0..<48 { for x in 0..<144 {
                    let from = ((Int(source.minY) + y) * sourceWidth + Int(source.minX) + x) * 4
                    let to = ((Int(destination.minY) + y) * width + Int(destination.minX) + x) * 4
                    for component in 0..<4 { pixels[to + component] = small[from + component] }
                } }
            }
            return try required(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: try required(CGDataProvider(data: Data(pixels) as CFData), "Large source provider missing"),
                decode: nil, shouldInterpolate: false, intent: .defaultIntent), "Large source construction failed")
        }
        let constructionSeconds = ProcessInfo.processInfo.systemUptime - creationStarted
        let before = sha(try required(image.dataProvider?.data, "Large source bytes missing") as Data)
        let matcher = AutomaticMosaicMatcher(), started = ProcessInfo.processInfo.systemUptime
        let result = try await matcher.findMatches(in: image, seed: RepeatedRegionPixelRect(x: 31, y: 47, width: 144, height: 48))
        let matchingSeconds = ProcessInfo.processInfo.systemUptime - started
        let after = sha(try required(image.dataProvider?.data, "Large source bytes lost") as Data)
        try require(before == after && matchingSeconds > 0 && matchingSeconds < 8 && !result.truncated && result.candidates.count == 2,
                    "Large match failed deadline, source identity or complete result count")
        for rect in targets {
            try require(result.candidates.filter { $0.rect.x == Int(rect.minX) && $0.rect.y == Int(rect.minY) && $0.rect.width == 144 && $0.rect.height == 48 }.count == 1,
                        "Large match geometry incorrect")
        }
        try require(!result.candidates.contains { $0.rect.x == Int(decoy.minX) && $0.rect.y == Int(decoy.minY) }, "Large changed glyph accepted")
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "other"
        #endif
        return ["profile": label, "status": "passed", "outcome": "completed", "actualProductionMatcherRan": true,
                "architecture": architecture, "sourceWidth": width, "sourceHeight": height, "sourceBytes": width * height * 4,
                "templateBytes": 144 * 48 * 4, "seed": rectangleObject(seed), "expectedTargets": targets.map(rectangleObject),
                "nearNonmatch": rectangleObject(decoy), "constructionSeconds": constructionSeconds,
                "conversionAndSearchSeconds": matchingSeconds, "productionDeadlineSeconds": 8,
                "sourceSHA256Before": before, "sourceSHA256After": after, "sourceByteIdentityVerified": true,
                "examinedOrigins": result.examinedOrigins, "truncated": result.truncated,
                "candidates": result.candidates.map { ["rect": [$0.rect.x, $0.rect.y, $0.rect.width, $0.rect.height], "confidence": $0.confidence] as [String: Any] },
                "algorithmOwnedScratchBudgetBytes": RepeatedRegionMatchLimits.maximumScratchBytes,
                "scratchBudgetExcludes": "Original CGImage backing, CGContext internals, and UI/WindowServer allocations"]
    }

    static func authoredRaster() throws -> CGImage {
        let tileWidth = 144, tileHeight = 48
        let tile = try required(CGContext(data: nil, width: tileWidth, height: tileHeight, bitsPerComponent: 8,
            bytesPerRow: tileWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Tile context unavailable")
        tile.setFillColor(CGColor(srgbRed: 0.92, green: 0.96, blue: 0.98, alpha: 1))
        tile.fill(CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight))
        tile.setFillColor(CGColor(srgbRed: 0.13, green: 0.39, blue: 0.73, alpha: 1))
        tile.fillEllipse(in: CGRect(x: 6, y: 14, width: 20, height: 20))
        tile.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.18, alpha: 1))
        tile.fill(CGRect(x: 12, y: 20, width: 8, height: 8))
        let text = NSAttributedString(string: "Mika Chen", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.08, green: 0.14, blue: 0.22, alpha: 1)])
        tile.textPosition = CGPoint(x: 32, y: 19)
        CTLineDraw(CTLineCreateWithAttributedString(text), tile)
        // Alpha is part of the matching input, including the transparent strip.
        tile.setBlendMode(.copy)
        tile.setFillColor(CGColor(srgbRed: 0.35, green: 0.7, blue: 0.3, alpha: 0.5))
        tile.fill(CGRect(x: 136, y: 0, width: 8, height: 48))
        let tileBytes = Array(UnsafeBufferPointer(start: try required(tile.data, "Tile bytes unavailable").assumingMemoryBound(to: UInt8.self), count: tileWidth * tileHeight * 4))
        var pixels = [UInt8](repeating: 255, count: sourceWidth * sourceHeight * 4)
        for y in 0..<sourceHeight { for x in 0..<sourceWidth {
            let i = (y * sourceWidth + x) * 4
            pixels[i] = UInt8(211 + (x / 23) % 19)
            pixels[i + 1] = UInt8(215 + (y / 17) % 17)
            pixels[i + 2] = UInt8(225 + ((x + y) / 29) % 13)
        } }
        for (index, rect) in (authoredRegions + [nearNonmatch]).enumerated() {
            for y in 0..<tileHeight { for x in 0..<tileWidth {
                let from = (y * tileWidth + x) * 4, to = ((Int(rect.minY) + y) * sourceWidth + Int(rect.minX) + x) * 4
                for c in 0..<4 { pixels[to + c] = tileBytes[from + c] }
                if index == 2 && pixels[to + 3] == 255 {
                    for c in 0..<3 { pixels[to + c] = UInt8(min(255, Int(pixels[to + c]) + 2)) }
                }
            } }
        }
        // Delete one actual dark glyph pixel (and its immediate neighbor), not
        // an unrelated random patch. Conservative matching must reject this.
        let dark = try required((0..<(tileWidth * tileHeight)).first { p in
            let x = p % tileWidth
            return x >= 32 && x < 125 && tileBytes[p * 4] < 50 && tileBytes[p * 4 + 3] == 255
        }, "Authored name has no dark glyph stroke")
        let bad = ((Int(nearNonmatch.minY) + dark / tileWidth) * sourceWidth + Int(nearNonmatch.minX) + dark % tileWidth) * 4
        for offset in [0, 4] { pixels[bad + offset] = 235; pixels[bad + offset + 1] = 245; pixels[bad + offset + 2] = 250 }
        let provider = try required(CGDataProvider(data: Data(pixels) as CFData), "Source provider unavailable")
        return try required(CGImage(width: sourceWidth, height: sourceHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: sourceWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent), "Source image unavailable")
    }

    private static func canvasRect(_ sourceRect: CGRect, height: Int = sourceHeight) -> CGRect {
        CGRect(x: sourceRect.minX, y: CGFloat(height) - sourceRect.maxY, width: sourceRect.width, height: sourceRect.height)
    }
    private static func rectangleObject(_ rect: CGRect) -> [Int] { [Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)] }
    private static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func rgba(_ image: CGImage) throws -> Data {
        let context = try required(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "RGBA context unavailable")
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try required(context.data, "RGBA bytes unavailable"), count: image.width * image.height * 4)
    }
    private static func export(_ editor: ImageEditorController, mode: String, regions: [CGRect], directory: URL) throws -> [String: Any] {
        let image = try required(editor.annotationCanvas.flattened(), "Production flatten failed")
        let before = try rgba(editor.annotationCanvas.image), after = try rgba(image)
        try require(before.count == sourceWidth * sourceHeight * 4 && before.count == after.count, "Export dimensions changed")
        var matched = 0, exterior = 0, changed = 0, mismatches = 0
        let opaque = mode.hasPrefix("redact")
        for y in 0..<sourceHeight { for x in 0..<sourceWidth {
            let offset = (y * sourceWidth + x) * 4
            let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            if regions.contains(where: { $0.contains(point) }) {
                matched += 1
                if before[offset..<(offset + 4)] != after[offset..<(offset + 4)] { changed += 1 }
                if opaque { try require(after[offset] == 0 && after[offset + 1] == 0 && after[offset + 2] == 0 && after[offset + 3] == 255, "Redaction left source/color/alpha at \(x),\(y)") }
            } else {
                exterior += 1
                if before[offset..<(offset + 4)] != after[offset..<(offset + 4)] { mismatches += 1 }
            }
        } }
        try require(matched > 0 && exterior > 0 && changed > 0 && mismatches == 0, "Export changed exterior or did not apply")
        let name = "automatic-mosaic-\(mode).png"
        try image.writePNG(to: directory.appendingPathComponent(name))
        return ["mode": mode, "file": name, "appliedRects": regions.map(rectangleObject), "nativeApply": true,
                "flattenedRasterOnly": true, "securityClaim": opaque, "matchedPixelsChecked": matched,
                "exteriorPixelsChecked": exterior, "exteriorMismatches": mismatches, "changedMatchedPixels": changed]
    }

    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func control(_ id: String, in editor: ImageEditorController) throws -> NSControl {
        try required(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == id } as? NSControl,
                     "Missing native control: " + id)
    }
    private static func click(_ id: String, in editor: ImageEditorController) throws {
        let value = try control(id, in: editor)
        try require(value.isEnabled && !value.isHiddenOrHasHiddenAncestor, "Unavailable native control: " + id)
        if let button = value as? NSButton { button.performClick(nil) }
        else { try require(NSApp.sendAction(try required(value.action, "Control action absent"), to: value.target, from: value), "Control action failed: " + id) }
    }
    private static func nativeTool(_ tool: ImageEditorTool, in editor: ImageEditorController) throws {
        if tool != .blur { try click("editor.tool." + tool.rawValue, in: editor); return }
        let menu = try required(descendants(editor.window?.contentView).compactMap { $0 as? NSPopUpButton }
            .flatMap { $0.itemArray }.first { $0.title.contains("模糊") }, "Blur native menu absent")
        try require(NSApp.sendAction(try required(menu.action, "Blur action absent"), to: menu.target, from: menu), "Native blur failed")
    }
    private static func pointer(_ canvas: ImageEditorCanvas, type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
        let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil)
        return try required(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Native pointer unavailable")
    }
    private static func drag(_ canvas: ImageEditorCanvas, rect: CGRect) throws {
        // Choose points safely inside the first/last pixels. The production
        // outward integral selection must still equal the exact authored mask;
        // exact edge coordinates are numerically ambiguous after AppKit transforms.
        let start = CGPoint(x: rect.minX + 0.125, y: rect.minY + 0.125)
        let end = CGPoint(x: rect.maxX - 0.125, y: rect.maxY - 0.125)
        canvas.mouseDown(with: try pointer(canvas, type: .leftMouseDown, point: start))
        canvas.mouseDragged(with: try pointer(canvas, type: .leftMouseDragged, point: end))
        canvas.mouseUp(with: try pointer(canvas, type: .leftMouseUp, point: end))
    }
    private static func select(_ canvas: ImageEditorCanvas, at point: CGPoint) throws {
        canvas.mouseDown(with: try pointer(canvas, type: .leftMouseDown, point: point))
        canvas.mouseUp(with: try pointer(canvas, type: .leftMouseUp, point: point))
    }
    private static func key(_ canvas: ImageEditorCanvas, code: UInt16, value: String, flags: NSEvent.ModifierFlags = []) throws {
        canvas.keyDown(with: try required(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
            characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code), "Native key unavailable"))
    }
    private static func settle(_ editor: ImageEditorController? = nil, deadline: Double) async throws {
        try checkDeadline(deadline)
        editor?.window?.contentView?.layoutSubtreeIfNeeded(); editor?.window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        try checkDeadline(deadline)
    }
    private static func waitUntil(deadline: Double, detail: String, condition: () -> Bool) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 20)
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < end, "Timed out: " + detail)
            try Task.checkCancellation(); try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func checkDeadline(_ deadline: Double) throws {
        try Task.checkCancellation(); try require(ProcessInfo.processInfo.systemUptime < deadline, "Overall deadline exceeded")
    }
    private static func observedMemory() throws -> GIFResourceMemoryReading {
        let sample = GIFResourceMemoryReading.current()
        try require((sample.residentBytes ?? 0) > 0 && (sample.physicalFootprintBytes ?? 0) > 0 &&
                    sample.residentBytes! <= UInt64(Int64.max) && sample.physicalFootprintBytes! <= UInt64(Int64.max), "Memory sample unavailable")
        return sample
    }
    private static func stoppedStatistics(_ sampler: GIFResourceMemorySampler) throws -> GIFResourceMemoryStatistics {
        sampler.stop(); let value = sampler.snapshot(), count = value.timerTickCount + value.boundarySampleCount
        try require(value.timerTickCount > 0 && value.residentSampleCount == count && value.physicalFootprintSampleCount == count &&
                    value.failedResidentSampleCount == 0 && value.failedPhysicalFootprintSampleCount == 0, "Memory samples incomplete")
        return value
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try required(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any], "Evidence encoding failed")
    }
    private static func required<T>(_ value: T?, _ detail: String) throws -> T { guard let value else { throw failure(detail) }; return value }
    private static func require(_ value: Bool, _ detail: String) throws { if !value { throw failure(detail) } }
    private static func failure(_ detail: String) -> Error { PicShotError.message("Automatic mosaic acceptance: " + detail) }
}

@MainActor private final class AutomaticMosaicActualCallCounter {
    let matcher = AutomaticMosaicMatcher()
    var started = 0, completed = 0, active = 0
    var outputCallbacks = 0
}

/// This gate never produces a match. Cancellation is deliberately ignored after
/// the real matcher finishes, so the production generation/revision guard must
/// discard its stale completion. No gate is used in resource measurements.
@MainActor private final class AutomaticMosaicActualCompletionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var holdingActualResult = false
    private var released = false
    func waitAfterActualMatch() async {
        holdingActualResult = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor private final class AutomaticMosaicWorkflowReleaseProbe {
    weak var controller: ImageEditorController?
    weak var canvas: ImageEditorCanvas?
    weak var content: NSView?
    weak var review: NSView?
    init(_ controller: ImageEditorController) {
        self.controller = controller; canvas = controller.annotationCanvas; content = controller.window?.contentView
    }
    func observeReview(_ view: NSView?) { review = view }
    var retainedCount: Int { autoreleasepool { [controller as AnyObject?, canvas, content, review].compactMap { $0 }.count } }
}
