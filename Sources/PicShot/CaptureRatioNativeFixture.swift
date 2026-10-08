import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import PicShotCore

/// Opt-in native/installed evidence. Every pixel and event belongs to this fixture.
/// No ScreenCaptureKit, TCC, external application, clipboard or preference access.
@MainActor
enum CaptureRatioNativeFixture {
    private static let reportName = "capture-ratio-native.json"
    private static let maximumPixels = 4_000_000

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let savedAppearance = NSApp.appearance
        defer { NSApp.appearance = savedAppearance }
        var report: [String: Any] = [
            "schemaVersion": 1, "status": "running",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundlePath,
            "syntheticDesktop": true, "maximumFixtureRasterPixels": maximumPixels,
            "maximumConcurrentOwnedWindows": 1, "snapshotPixelsPerPoint": 1,
            "screenCaptureAttempted": false, "globalInputAttempted": false, "networkAttempted": false,
            "generalPasteboardTouched": false, "preferencesWritten": false, "TCCRequested": false,
            "limitations": [
                "Synthetic independent fractional X/Y source density, not live or physical Retina acquisition",
                "Production target-action controls and owned-view NSEvents, not global input or all AppKit event dispatch paths",
                "Scalar geometry tests cover exhaustive handles/quadrants; this installed fixture samples their production integration",
                "Bounded PNG snapshots and source comparisons allocate fixture rasters; drag checks assert production image identities, not process memory or zero allocations",
                "Owned window/controller release is bounded functional evidence, not a process-memory plateau or general leak claim"]
        ]
        var files: [String] = [], completed: [String] = []
        try write(report, directory: evidenceDirectory)
        do {
            guard let screen = NSScreen.main, let displayID = screen.displayID else { throw failure("A WindowServer display is required") }
            let points = CGSize(width: min(1000, floor(screen.frame.width)), height: min(700, floor(screen.frame.height)))
            try require(points.width >= 760 && points.height >= 600, "A display of at least 760 × 600 points is required")
            let source = try syntheticDesktop(), before = try digest(source)
            let display = CGRect(origin: screen.frame.origin, size: points)
            try source.writePNG(to: evidenceDirectory.appendingPathComponent("capture-ratio-source.png"))
            files.append("capture-ratio-source.png")
            report["sourceDigestFormat"] = "RGBA8 provider bytes including row stride; PNG hashes are separate"
            report["sourcePixelWidth"] = source.width; report["sourcePixelHeight"] = source.height
            report["pointWidth"] = points.width; report["pointHeight"] = points.height
            report["sourcePixelsPerPointX"] = CGFloat(source.width) / points.width
            report["sourcePixelsPerPointY"] = CGFloat(source.height) / points.height
            report["nativeDisplayBackingScale"] = screen.backingScaleFactor
            NSApp.appearance = NSAppearance(named: .aqua)

            let selected = try await verifySelector(source: source, display: display, directory: evidenceDirectory)
            report["selector"] = selected.report; completed.append("selectorNativeControls")
            files.append("ui-capture-ratio-selector-light.png")
            let capture = try CapturedImage.frozenPixelRegion(image: source, displayID: displayID, displayFrame: display,
                pixelFrame: selected.pixels, capturedAt: Date(timeIntervalSince1970: 1_704_164_645), aspectRatio: selected.ratio)
            try assertCrop(capture.image, source: source, topLeftPixels: selected.pixels)
            report["editor"] = try await withEditor(capture) { editor in
                try await verifyEditor(editor, source: source, directory: evidenceDirectory)
            }
            completed.append("editorRatioNumericBoundaryUndoCancel")
            files += ["ui-capture-ratio-editor-light.png", "ui-capture-ratio-editor-dark.png", "capture-ratio-base-crop.png", "capture-ratio-edited-result.png"]
            report["multiRegion"] = try await verifyMultiRegion(source: source, display: display, directory: evidenceDirectory)
            completed.append("multiRegionNativeControls"); files.append("ui-capture-ratio-multiregion.png")

            var edges: [[String: Any]] = []
            for (name, x, y) in [("top-left", 4, 4), ("top-right", source.width - 164, 4),
                                 ("bottom-left", 4, source.height - 94), ("bottom-right", source.width - 164, source.height - 94)] {
                let edge = try CapturedImage.frozenPixelRegion(image: source, displayID: displayID, displayFrame: display,
                    pixelFrame: CGRect(x: x, y: y, width: 160, height: 90))
                let filename = "ui-capture-ratio-edge-\(name).png"
                var result = try await withEditor(edge) { editor in
                    let original = editor.editorSelectionFrame
                    try click("editor.captureRatio", root: editor.window?.contentView)
                    try picker("editor.capture.ratioPreset", index: 4, root: editor.window?.contentView)
                    try require(editor.captureAspectRatio?.label == "16:9", "Edge preset control did not apply")
                    try require(close(editor.editorSelectionFrame, original), "Enabling an already-matching edge ratio moved the selected pixels")
                    try await ratioSnapshot(editor, filename: filename, directory: evidenceDirectory)
                    return ["nativePresetApplied": true, "selectionStayedAnchored": true,
                            "paletteAndToolbarInsideDisplay": true, "controlsHitTested": true]
                }
                result["edge"] = name; edges.append(result); files.append(filename)
            }
            report["edges"] = edges; completed.append("fourEdgePalettes")
            let after = try digest(source)
            try require(after == before, "Immutable synthetic source bytes changed")
            report["sourceSHA256Before"] = before; report["sourceSHA256After"] = after
            report["sourcePixelsPreserved"] = true; report["status"] = "passed"
            report["closedAndReleasedOwnedWindows"] = 7 // selector + editor + multi-region + four edges
            var fileHashes: [String: String] = [:]
            for file in files {
                let data = try Data(contentsOf: evidenceDirectory.appendingPathComponent(file))
                fileHashes[file] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            report["fileSHA256"] = fileHashes
            report["completedChecks"] = completed; report["files"] = files + [reportName]
            try write(report, directory: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedChecks"] = completed; report["files"] = files
            report["ownedWindowCleanupAttempted"] = true
            try? write(report, directory: evidenceDirectory)
            throw error
        }
    }

    private static func verifySelector(source: CGImage, display: CGRect, directory: URL) async throws
        -> (pixels: CGRect, ratio: CaptureAspectRatio, report: [String: Any]) {
        let geometry = try FrozenCaptureGeometry(pointSize: display.size, pixelWidth: source.width, pixelHeight: source.height)
        var view: RegionSelectionView? = RegionSelectionView(frame: CGRect(origin: .zero, size: display.size), frozenImage: source, geometry: geometry)
        var window: NSWindow? = host(try unwrap(view, "Missing selector"), frame: display)
        weak var weakView = view; weak var weakWindow = window
        defer { view?.discard(); detach(window); window = nil; view = nil }
        var finished: Result<CGRect, Error>?
        view?.finished = { finished = $0 }
        try await settle(window)
        try picker("capture.ratioPreset", index: CaptureAspectRatio.presets.count + 1, root: view)
        try type("capture.ratioNumerator", text: "10001", root: view, sendAction: false)
        try type("capture.ratioDenominator", text: "9", root: view, sendAction: false)
        try click("capture.ratioApply", root: view)
        try require(view?.aspectRatio == nil, "Out-of-range custom ratio changed selection state")
        try type("capture.ratioNumerator", text: "1920", root: view, sendAction: false)
        try type("capture.ratioDenominator", text: "1080", root: view, sendAction: false)
        try click("capture.ratioApply", root: view)
        try require(view?.aspectRatio?.label == "16:9", "Custom ratio did not reduce through the native controls")
        let start = CGPoint(x: display.width * 0.24, y: display.height * 0.40)
        try drag(try unwrap(view, "Missing selector"), from: start, to: CGPoint(x: start.x + 210, y: start.y + 115))
        try require(finished == nil, "Locked drag closed before numeric refinement")
        let beforeInvalid = view?.selected
        try type("capture.pixelWidth", text: "999999999999999999999", root: view)
        try require(view?.selected == beforeInvalid && finished == nil, "Overflowing numeric input mutated or finished the selection")
        try type("capture.pixelWidth", text: "321", root: view)
        var pixels = try pixelRect(try unwrap(view?.selected, "Missing rectangle"), source: source, points: display.size)
        try require(pixels.width == 320 && pixels.height == 180, "Width 321 did not snap to exact 320 × 180")
        try click("capture.ratioSwap", root: view)
        try require(view?.aspectRatio?.label == "9:16", "Native swap did not apply")
        try ownedKey(try unwrap(view, "Missing selector"), code: 6, flags: .command)
        try require(view?.aspectRatio?.label == "16:9", "Selector undo did not restore ratio")
        try ownedKey(try unwrap(view, "Missing selector"), code: 6, flags: [.command, .shift])
        try require(view?.aspectRatio?.label == "9:16", "Selector redo did not restore swap")
        try ownedKey(try unwrap(view, "Missing selector"), code: 6, flags: .command)
        try picker("capture.ratioPreset", index: 0, root: view)
        try require(view?.aspectRatio == nil, "Native Free did not unlock")
        try ownedKey(try unwrap(view, "Missing selector"), code: 6, flags: .command)
        try require(view?.aspectRatio?.label == "16:9", "Undo of unlock did not restore ratio")
        try await settle(window)
        try reachable("capture.ratioPreset", root: view)
        try reachable("capture.pixelWidth", root: view)
        try snapshot(window, filename: "ui-capture-ratio-selector-light.png", directory: directory)
        try click("capture.ratioAccept", root: view)
        _ = try unwrap(finished, "Native Use selection did not finish").get()
        pixels = try unwrap(view?.committedPixelFrame, "Selector lost exact source pixel bounds")
        let ratio = try unwrap(view?.aspectRatio, "Selector lost ratio metadata")
        try require(Int(pixels.width) * ratio.denominator == Int(pixels.height) * ratio.numerator, "Selector result is not exact")
        view?.discard(); detach(window); view = nil; window = nil
        try await released { weakView == nil && weakWindow == nil }
        return (pixels, ratio, ["customPresetSwapFreeUndoRedo": true, "invalidCustomAndNumericRefused": true, "nativeNumericSnap": true,
            "exactPixelFrame": rectJSON(pixels), "ratio": ratio.label, "nativeAccept": true,
            "ownedViewAndWindowReleased": true])
    }

    private static func verifyEditor(_ editor: ImageEditorController, source: CGImage, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas, workspace = editor.captureBoundaryWorkspace
        let root = try unwrap(editor.window?.contentView, "Missing editor root")
        try click("editor.tool.rectangle", root: root)
        try canvasDrag(canvas, from: CGPoint(x: 35, y: 35), to: CGPoint(x: 125, y: 95))
        try require(canvas.annotations.count == 1 && canvas.annotations[0].tool == .rectangle, "Native canvas drag did not create an annotation")
        let annotation = canvas.annotations[0]
        let originalFrame = editor.editorSelectionFrame
        let sx = CGFloat(source.width) / workspace.bounds.width, sy = CGFloat(source.height) / workspace.bounds.height
        let anchoredPoint = CGPoint(x: originalFrame.minX + annotation.points[0].x / sx, y: originalFrame.minY + annotation.points[0].y / sy)
        try click("editor.captureRatio", root: root)
        try type("editor.capture.pixelHeight", text: "217", root: root)
        try require(canvas.image.width == 384 && canvas.image.height == 216, "Native editor height edit did not snap to 384 × 216")
        let numericFrame = editor.editorSelectionFrame, numericImage = canvas.image
        let start = EditorBoundaryHandle.left.point(in: numericFrame)
        let target = CGPoint(x: start.x - 35, y: start.y)
        try require(workspace.hitTest(workspace.convert(start, to: workspace.superview)) === workspace, "Visible capture boundary was not hit-testable")
        workspace.mouseDown(with: try mouse(workspace, .leftMouseDown, start))
        let preview = workspace.boundaryPreviewImage
        for step in 1...5 {
            let point = CGPoint(x: start.x + (target.x - start.x) * CGFloat(step) / 5, y: start.y)
            workspace.mouseDragged(with: try mouse(workspace, .leftMouseDragged, point))
            try require(canvas.image === numericImage && workspace.boundaryPreviewImage === preview,
                        "Pointer motion replaced the selected raster or preview")
            try require(workspace.pixelSize.width * 9 == workspace.pixelSize.height * 16, "Boundary preview lost exact ratio")
        }
        workspace.mouseUp(with: try mouse(workspace, .leftMouseUp, target))
        try require(canvas.image.width * 9 == canvas.image.height * 16, "Committed boundary ratio is not exact")
        let committed = editor.editorSelectionFrame, committedImage = canvas.image
        try require(canvas.annotations[0].id == annotation.id, "Boundary resize replaced the annotation identity")
        let point = canvas.annotations[0].points[0]
        try require(abs(committed.minX + point.x / sx - anchoredPoint.x) < 1e-7 && abs(committed.minY + point.y / sy - anchoredPoint.y) < 1e-7,
                    "Boundary resize moved the annotation's source position")
        try undo(canvas)
        try require(close(editor.editorSelectionFrame, numericFrame) && canvas.image === numericImage, "Native undo did not restore the previous crop")
        let cancelStart = EditorBoundaryHandle.bottomRight.point(in: numericFrame)
        workspace.mouseDown(with: try mouse(workspace, .leftMouseDown, cancelStart))
        workspace.mouseDragged(with: try mouse(workspace, .leftMouseDragged, CGPoint(x: cancelStart.x + 30, y: cancelStart.y - 20)))
        try ownedKey(workspace, code: 53)
        workspace.mouseUp(with: try mouse(workspace, .leftMouseUp, cancelStart))
        try require(!editor.isClosed && close(editor.editorSelectionFrame, numericFrame) && canvas.image === numericImage,
                    "Escape committed or closed a boundary preview")
        try undo(canvas, redo: true)
        try require(close(editor.editorSelectionFrame, committed) && canvas.image === committedImage, "Canceled drag consumed redo")
        try picker("editor.capture.ratioPreset", index: 0, root: root)
        try require(editor.captureAspectRatio == nil && canvas.image === committedImage, "Unlock changed pixel storage")
        try undo(canvas)
        try require(editor.captureAspectRatio?.label == "16:9" && canvas.image === committedImage, "Ratio-state undo failed")
        let bottomPixels = try pixelRect(editor.editorSelectionFrame, source: source, points: workspace.bounds.size)
        let topPixels = CGRect(x: bottomPixels.minX, y: CGFloat(source.height) - bottomPixels.maxY, width: bottomPixels.width, height: bottomPixels.height)
        try assertCrop(canvas.image, source: source, topLeftPixels: topPixels)
        try canvas.image.writePNG(to: directory.appendingPathComponent("capture-ratio-base-crop.png"))
        editor.window?.appearance = NSAppearance(named: .aqua)
        try await ratioSnapshot(editor, filename: "ui-capture-ratio-editor-light.png", directory: directory)
        editor.window?.appearance = NSAppearance(named: .darkAqua)
        try await ratioSnapshot(editor, filename: "ui-capture-ratio-editor-dark.png", directory: directory)
        try require(editor.floatingSurfaceIsDark, "Native dark appearance did not reach the floating controls")
        let flattened = try unwrap(canvas.flattened(), "Could not render edited fixture")
        try flattened.writePNG(to: directory.appendingPathComponent("capture-ratio-edited-result.png"))
        return ["nativeAnnotationCreated": true, "nativeNumericHeightSnap": true, "nativeBoundaryHandleHit": true,
            "previewKeptRasterIdentities": true, "committedExactRatio": true, "annotationSourceAnchorPreserved": true,
            "oneGestureUndoRedo": true, "escapePreservedRedo": true, "ratioOnlyUndoSharedRaster": true,
            "baseCropMatchesOriginalPixels": true, "selectedPixelFrame": rectJSON(topPixels),
            "resultSHA256": try digest(flattened), "lightDarkPaletteSnapshots": true]
    }

    private static func verifyMultiRegion(source: CGImage, display: CGRect, directory: URL) async throws -> [String: Any] {
        let geometry = try CaptureSelectionGeometry(pointSize: display.size, pixelWidth: source.width, pixelHeight: source.height)
        var view: AdvancedSelectionView? = AdvancedSelectionView(frame: CGRect(origin: .zero, size: display.size), image: source, style: .multiRegion, geometry: geometry)
        var window: NSWindow? = host(try unwrap(view, "Missing multi-region view"), frame: display)
        weak var weakView = view; weak var weakWindow = window
        defer { view?.discard(); detach(window); window = nil; view = nil }
        var cancelled = false; view?.finished = { if case .failure = $0 { cancelled = true } }
        try await settle(window)
        try picker("multiCapture.ratioPreset", index: 2, root: view)
        let start = CGPoint(x: display.width * 0.20, y: display.height * 0.45)
        try drag(try unwrap(view, "Missing multi-region view"), from: start, to: CGPoint(x: start.x + 190, y: start.y + 120))
        let initial = try unwrap(view?.selection.operations, "Missing geometry")
        try require(initial.count == 1, "Native multi-region rectangle was not added")
        let initialPixels = try unwrap(view?.selection.rectanglePixelBounds(initial[0].shape.bounds), "Missing rectangle pixels")
        try require(initialPixels.width * 3 == initialPixels.height * 4, "Multi-region drag lost source ratio")
        let handle = CaptureRatioHandle.maxXMaxY.point(in: initial[0].shape.bounds)
        try drag(try unwrap(view, "Missing multi-region view"), from: handle, to: CGPoint(x: handle.x + 25, y: handle.y + 25))
        try require(view?.selection.operations.count == 1 && view?.selection.operations != initial, "Handle drag added a new operation or did not resize")
        try ownedKey(try unwrap(view, "Missing multi-region view"), code: 6, flags: .command)
        try require(view?.selection.operations == initial, "Multi-region resize undo failed")
        let cutout = CGPoint(x: start.x + 40, y: start.y + 40)
        try drag(try unwrap(view, "Missing multi-region view"), from: cutout, to: CGPoint(x: cutout.x + 45, y: cutout.y + 35), flags: .option)
        try type("capturePixelWidth", text: "97", root: view)
        let operations = try unwrap(view?.selection.operations, "Missing operations")
        try require(operations.count == 2 && operations[1].subtracts, "Native cutout did not preserve ordered subtraction")
        let pixels = try unwrap(view?.selection.rectanglePixelBounds(operations[1].shape.bounds), "Missing cutout bounds")
        try require(pixels.width == 96 && pixels.height == 72, "Multi-region numeric dimensions are not exact 4:3")
        try await settle(window)
        try reachable("multiCapture.ratioPreset", root: view)
        try reachable("capturePixelWidth", root: view)
        try snapshot(window, filename: "ui-capture-ratio-multiregion.png", directory: directory)
        try ownedKey(try unwrap(view, "Missing multi-region view"), code: 53)
        try require(cancelled && view?.selection.isCancelled == true && view?.selection.operations.isEmpty == true, "Escape did not terminally cancel multi-region capture")
        try ownedKey(try unwrap(view, "Missing multi-region view"), code: 6, flags: [.command, .shift])
        try require(view?.selection.operations.isEmpty == true, "Late redo revived canceled geometry")
        view?.discard(); detach(window); view = nil; window = nil
        try await released { weakView == nil && weakWindow == nil }
        return ["nativePresetDragAndHandle": true, "nativeResizeUndo": true, "nativeCutoutAndNumericSize": true,
            "orderedBooleanModePreserved": true, "escapeTerminalForLateRedo": true, "ownedViewAndWindowReleased": true]
    }

    private static func withEditor(_ capture: CapturedImage, body: (ImageEditorController) async throws -> [String: Any]) async throws -> [String: Any] {
        var editor: ImageEditorController? = ImageEditorController(image: capture.image, presentation: capture.presentation,
            onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, copyAction: { _ in })
        weak var weakEditor = editor; weak var weakWindow = editor?.window
        defer { editor?.close() }
        editor?.window?.appearance = NSAppearance(named: .aqua)
        editor?.showWindow(nil); editor?.window?.makeKeyAndOrderFront(nil); try await settle(editor?.window)
        let presentation = try unwrap(capture.presentation, "Missing frozen presentation")
        try require(editor?.window?.frame == presentation.displayFrame, "Frozen window moved from its original display origin")
        let initialScreenFrame = presentation.selectionFrame.offsetBy(dx: presentation.displayFrame.minX, dy: presentation.displayFrame.minY)
        try require(close(try unwrap(editor?.editorImageScreenFrame, "Missing initial image placement"), initialScreenFrame), "Initial source pixels moved on screen")
        var result = try await body(try unwrap(editor, "Missing owned editor"))
        try require(editor?.window?.frame == presentation.displayFrame, "Editing changed original display placement")
        result["originalDisplayOriginPreserved"] = true
        try click("editor.cancel", root: editor?.window?.contentView)
        try require(editor?.isClosed == true && editor?.window?.isVisible != true && editor?.window?.contentView == nil && editor?.window?.delegate == nil,
                    "Native cancel did not detach its window")
        try require(editor?.captureBoundaryWorkspace.frozenImage == nil && editor?.captureBoundaryWorkspace.boundaryPreviewImage == nil && editor?.annotationCanvas.retainedPresentationRaster == nil,
                    "Native cancel retained owned source/preview/cache references")
        editor = nil
        try await released { weakEditor == nil && weakWindow == nil }
        result["nativeCancelDetachedWindow"] = true; result["ownedControllerAndWindowReleased"] = true
        return result
    }

    private static func ratioSnapshot(_ editor: ImageEditorController, filename: String, directory: URL) async throws {
        try await settle(editor.window)
        let root = try unwrap(editor.window?.contentView, "Missing snapshot root")
        let palette: NSView = try control("editor.captureRatioPalette", root: root)
        try require(!palette.isHiddenOrHasHiddenAncestor && root.bounds.contains(editor.captureRatioPaletteFrame)
            && root.bounds.contains(editor.floatingToolbarFrame) && !editor.captureRatioPaletteFrame.intersects(editor.floatingToolbarFrame)
            && !editor.captureRatioPaletteFrame.intersects(editor.dimensionLabelFrame), "Ratio palette is clipped or overlaps other controls")
        for id in ["editor.capture.ratioPreset", "editor.capture.pixelWidth", "editor.capture.pixelHeight", "editor.capture.ratioSwap"] { try reachable(id, root: root) }
        try snapshot(editor.window, filename: filename, directory: directory)
    }
    private static func snapshot(_ window: NSWindow?, filename: String, directory: URL) throws {
        let root = try unwrap(window?.contentView, "Missing snapshot view")
        let width = Int(root.bounds.width.rounded(.up)), height = Int(root.bounds.height.rounded(.up))
        try size(width, height)
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), "Could not allocate bounded 1x snapshot")
        bitmap.size = root.bounds.size; root.cacheDisplay(in: root.bounds, to: bitmap)
        try unwrap(bitmap.cgImage, "Missing snapshot pixels").writePNG(to: directory.appendingPathComponent(filename))
    }
    private static func host(_ view: NSView, frame: CGRect) -> NSWindow {
        let window = EditorOverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating; window.contentView = view
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); return window
    }
    private static func detach(_ window: NSWindow?) {
        window?.makeFirstResponder(nil); window?.delegate = nil; window?.contentView = nil; window?.orderOut(nil); window?.close()
    }
    private static func settle(_ window: NSWindow?) async throws {
        window?.contentView?.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        window?.contentView?.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
    }
    private static func released(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(condition(), "Owned UI objects remained retained after the two-second cleanup window")
    }
    private static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    private static func control<T: NSView>(_ id: String, root: NSView?) throws -> T {
        try unwrap(descendants(root).first { $0.identifier?.rawValue == id } as? T, "Missing native control \(id)")
    }
    private static func reachable(_ id: String, root: NSView?) throws {
        let control: NSControl = try self.control(id, root: root)
        try require(control.isEnabled && !control.isHiddenOrHasHiddenAncestor && control.window != nil && control.target != nil && control.action != nil,
                    "Unreachable native control \(id)")
        let window = try unwrap(control.window, "Missing control window")
        let content = try unwrap(window.contentView, "Missing window root")
        let center = content.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), from: control)
        let hit = content.hitTest(content.convert(center, to: content.superview))
        try require(hit === control || hit?.isDescendant(of: control) == true, "Native control \(id) did not win hit testing")
    }
    private static func click(_ id: String, root: NSView?) throws {
        let button: NSButton = try control(id, root: root)
        try require(button.isEnabled && !button.isHiddenOrHasHiddenAncestor && button.target != nil && button.action != nil, "Unavailable native button \(id)")
        button.performClick(nil)
    }
    private static func send(_ widget: NSControl) throws {
        try require(widget.isEnabled && !widget.isHiddenOrHasHiddenAncestor && widget.target != nil && widget.action != nil, "Unavailable native action")
        try require(widget.sendAction(widget.action, to: widget.target), "Native target-action did not run")
    }
    private static func picker(_ id: String, index: Int, root: NSView?) throws {
        let widget: NSPopUpButton = try control(id, root: root)
        try require(index >= 0 && index < widget.numberOfItems, "Missing ratio preset index \(index)")
        widget.selectItem(at: index); try send(widget)
    }
    private static func type(_ id: String, text: String, root: NSView?, sendAction: Bool = true) throws {
        let field: NSTextField = try control(id, root: root)
        field.stringValue = text; field.currentEditor()?.string = text
        if sendAction { try send(field) }
    }
    private static func mouse(_ view: NSView, _ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Cannot create owned mouse event")
    }
    private static func drag(_ view: NSView, from start: CGPoint, to end: CGPoint, flags: NSEvent.ModifierFlags = []) throws {
        view.mouseDown(with: try mouse(view, .leftMouseDown, start, flags: flags))
        view.mouseDragged(with: try mouse(view, .leftMouseDragged, end, flags: flags))
        view.mouseUp(with: try mouse(view, .leftMouseUp, end, flags: flags))
    }
    private static func canvasDrag(_ view: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        try drag(view, from: CGPoint(x: start.x * view.zoom, y: start.y * view.displayScaleY), to: CGPoint(x: end.x * view.zoom, y: end.y * view.displayScaleY))
    }
    private static func key(_ view: NSView, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let text = code == 6 ? "z" : code == 53 ? "\u{1b}" : ""
        return try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code), "Cannot create owned key event")
    }
    private static func ownedKey(_ view: NSView, code: UInt16, flags: NSEvent.ModifierFlags = []) throws { view.keyDown(with: try key(view, code: code, flags: flags)) }
    private static func undo(_ canvas: ImageEditorCanvas, redo: Bool = false) throws {
        try require(canvas.performKeyEquivalent(with: try key(canvas, code: 6, flags: redo ? [.command, .shift] : .command)), "Native editor undo/redo was not handled")
    }
    private static func pixelRect(_ frame: CGRect, source: CGImage, points: CGSize) throws -> CGRect {
        try CaptureRatioGeometry(pointSize: points, pixelWidth: source.width, pixelHeight: source.height).sourcePixelRect(frame)
    }
    private static func assertCrop(_ crop: CGImage, source: CGImage, topLeftPixels pixels: CGRect) throws {
        try require(crop.width == Int(pixels.width) && crop.height == Int(pixels.height) && pixels.minX >= 0 && pixels.minY >= 0 && pixels.maxX <= CGFloat(source.width) && pixels.maxY <= CGFloat(source.height), "Crop extent changed")
        try require(source.bitsPerPixel == 32 && source.bitsPerComponent == 8 && crop.bitsPerPixel == 32 && crop.bitsPerComponent == 8,
                    "Pixel verification requires RGBA8 fixture images")
        let sourceData = try unwrap(source.dataProvider?.data, "Missing source bytes"), cropData = try unwrap(crop.dataProvider?.data, "Missing crop bytes")
        try require(CFDataGetLength(sourceData) >= source.bytesPerRow * source.height && CFDataGetLength(cropData) >= crop.bytesPerRow * crop.height,
                    "Pixel backing is shorter than its declared stride")
        try withExtendedLifetime((sourceData, cropData)) {
            let a = try unwrap(CFDataGetBytePtr(sourceData), "Missing source data"), b = try unwrap(CFDataGetBytePtr(cropData), "Missing crop data")
            for y in 0..<crop.height {
                let sourceOffset = (Int(pixels.minY) + y) * source.bytesPerRow + Int(pixels.minX) * 4
                for x in 0..<(crop.width * 4) where a[sourceOffset + x] != b[y * crop.bytesPerRow + x] {
                    throw failure("Frozen pixel mismatch at crop row \(y), byte \(x)")
                }
            }
        }
    }
    private static func syntheticDesktop() throws -> CGImage {
        let width = 1397, height = 911
        try size(width, height)
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Missing synthetic source context")
        let pixels = try unwrap(context.data, "Missing source raster").assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let offset = y * width * 4 + x * 4
            pixels[offset] = UInt8(28 + (x / 7 + y / 17) % 65)
            pixels[offset + 1] = UInt8(54 + (x / 11 + y / 5) % 85)
            pixels[offset + 2] = UInt8(88 + (x / 5 + y / 13) % 100); pixels[offset + 3] = 255
        } }
        context.setFillColor(CGColor(srgbRed: 0.94, green: 0.96, blue: 0.99, alpha: 1))
        context.fill(CGRect(x: 90, y: 175, width: 1060, height: 500))
        for row in 0..<7 {
            context.setFillColor(CGColor(srgbRed: row.isMultiple(of: 2) ? 0.87 : 0.94, green: 0.91, blue: 0.97, alpha: 1))
            context.fill(CGRect(x: 120, y: 200 + row * 60, width: 980, height: 38))
        }
        let title = NSAttributedString(string: "PicShot • Synthetic ratio fixture", attributes: [.font: NSFont.systemFont(ofSize: 31, weight: .semibold), .foregroundColor: NSColor.white])
        context.textPosition = CGPoint(x: 92, y: 790); CTLineDraw(CTLineCreateWithAttributedString(title), context)
        let note = NSAttributedString(string: "Original owned pixels • Fractional X/Y density • No screen capture", attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white])
        context.textPosition = CGPoint(x: 94, y: 751); CTLineDraw(CTLineCreateWithAttributedString(note), context)
        return try unwrap(context.makeImage(), "Cannot finish synthetic source")
    }
    private static func digest(_ image: CGImage) throws -> String {
        try size(image.width, image.height)
        let bytes = try unwrap(image.dataProvider?.data, "Missing digest bytes")
        return SHA256.hash(data: bytes as Data).map { String(format: "%02x", $0) }.joined()
    }
    private static func size(_ width: Int, _ height: Int) throws { try require(width > 0 && height > 0 && width <= maximumPixels / height, "Fixture raster exceeded its bound") }
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 1e-7 && abs(a.minY - b.minY) < 1e-7 && abs(a.width - b.width) < 1e-7 && abs(a.height - b.height) < 1e-7 }
    private static func rectJSON(_ rect: CGRect) -> [String: Int] { ["x": Int(rect.minX), "y": Int(rect.minY), "width": Int(rect.width), "height": Int(rect.height)] }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { guard try condition() else { throw failure(message) } }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Capture ratio native fixture: \(message)") }
    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(reportName), options: .atomic)
    }
}
