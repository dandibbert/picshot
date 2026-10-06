import AppKit
import CoreGraphics
import CryptoKit

/// Installed-app evidence from original synthetic pixels. Native AppKit controls
/// and canvas NSEvents exercise the same model and flattened output as the UI.
@MainActor
enum AnnotationPathsPreviewFixture {
    private static let maximumPixels = 4_000_000
    private static let reportName = "annotation-paths-preview.json"

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        var report: [String: Any] = [
            "status": "running", "syntheticDesktop": true,
            "scope": "Original 1x synthetic source; native AppKit controls, canvas NSEvents, vector edits, undo/redo and flattened raster pixels",
            "sourcePixelsPerPoint": 1, "snapshotPixelsPerPoint": 1,
            "screenCaptureAttempted": false, "audioCaptureAttempted": false, "cameraCaptureAttempted": false,
            "ocrInferenceAttempted": false, "networkAttempted": false, "preferencesWritten": false,
            "maximumFixtureRasterPixels": maximumPixels, "maximumConcurrentOwnedEditors": 1,
            "maximumPolylinePoints": ImageAnnotation.maximumPolylinePoints,
            "limitations": ["Synthetic 1x fixture, not live capture or Retina acquisition", "NSEvents delivered to owned canvas, not physical-input routing", "Release checks cover owned UI/cache references; no process-memory or leak claim"]
        ]
        var completed: [String] = [], files: [String] = []
        do {
            guard let screen = NSScreen.main, let displayID = screen.displayID else { throw failure("No WindowServer display") }
            let size = CGSize(width: min(1_180, floor(screen.frame.width)), height: min(760, floor(screen.frame.height)))
            guard size.width >= 760, size.height >= 600 else { throw failure("A native display of at least 760 by 600 points is needed") }
            let source = try whiteImage(size: size), sourceDigest = try digest(source)
            let frame = CGRect(origin: screen.frame.origin, size: size)
            let selection = CGRect(x: 40, y: 90, width: size.width - 80, height: size.height - 240)
            let captured = try CapturedImage.frozenRegion(image: source, displayID: displayID, displayFrame: frame,
                selection: selection, capturedAt: Date(timeIntervalSince1970: 1_704_164_645))
            report["desktopPixelWidth"] = source.width; report["desktopPixelHeight"] = source.height
            report["resultPixelWidth"] = captured.image.width; report["resultPixelHeight"] = captured.image.height
            report["nativeDisplayBackingScale"] = screen.backingScaleFactor
            NSApp.appearance = NSAppearance(named: .aqua)
            report["arcs"] = try await withEditor(captured, name: "arcs", directory: evidenceDirectory) { editor in
                try await verifyArcs(editor, directory: evidenceDirectory)
            }
            completed.append("arcs"); files += ["ui-annotation-arcs.png", "annotation-arcs-result.png"]
            report["polyline"] = try await withEditor(captured, name: "polyline", directory: evidenceDirectory) { editor in
                try await verifyPolyline(editor, directory: evidenceDirectory)
            }
            completed.append("polyline"); files += ["ui-annotation-polyline-draft.png", "ui-annotation-polyline-edit.png", "annotation-polyline-result.png"]
            report["pointLimit"] = try await withEditor(captured, name: "polyline-limit", directory: evidenceDirectory) { editor in
                try choose(.polyline, editor)
                let canvas = editor.annotationCanvas
                for index in 0..<ImageAnnotation.maximumPolylinePoints {
                    let x = 8 + CGFloat(index) * (CGFloat(canvas.image.width) - 16) / CGFloat(ImageAnnotation.maximumPolylinePoints - 1)
                    try canvasClick(canvas, CGPoint(x: x, y: index.isMultiple(of: 2) ? 20 : 40))
                }
                guard canvas.pendingPolylinePointCount == 0, canvas.annotations.count == 1,
                      canvas.annotations[0].points.count == ImageAnnotation.maximumPolylinePoints else { throw failure("Native path did not finish at its point bound") }
                try undo(canvas); guard canvas.annotations.isEmpty else { throw failure("Bounded path did not commit one undo state") }
                try undo(canvas, redo: true)
                return ["nativePointLimitAutoFinish": true, "singleUndoState": true, "committedPointCount": canvas.annotations[0].points.count]
            }
            completed.append("pointLimit"); files.append("annotation-polyline-limit-result.png")
            var edges: [[String: Any]] = []
            for (name, x, y) in [("top-left", CGFloat(8), CGFloat(8)), ("top-right", size.width - 188, CGFloat(8)),
                                 ("bottom-left", CGFloat(8), size.height - 128), ("bottom-right", size.width - 188, size.height - 128)] {
                let edgeCapture = try CapturedImage.frozenRegion(image: source, displayID: displayID, displayFrame: frame,
                    selection: CGRect(x: x, y: y, width: 180, height: 120))
                let filename = "ui-annotation-path-edge-\(name).png"
                var edge = try await withEditor(edgeCapture, name: "path-edge-\(name)", directory: evidenceDirectory) { editor in
                    let originalFrame = editor.annotationCanvas.frame, originalSelection = editor.editorSelectionFrame
                    try choose(.sector, editor)
                    try field("annotation.arcStart", value: "15", editor)
                    try field("annotation.arcSweep", value: "240", editor)
                    try drag(editor.annotationCanvas, from: CGPoint(x: 12, y: 12), to: CGPoint(x: 155, y: 100))
                    guard editor.annotationCanvas.frame == originalFrame, editor.editorSelectionFrame == originalSelection else {
                        throw failure("Path palette moved the frozen image at \(name)")
                    }
                    try await snapshot(editor, filename: filename, controls: ["annotation.arcStart", "annotation.arcSweep"], directory: evidenceDirectory)
                    return ["frozenImageAnchored": true, "paletteInsideWorkspace": true, "toolbarPaletteDoNotOverlap": true]
                }
                edge["edge"] = name; edges.append(edge)
                files += [filename, "annotation-path-edge-\(name)-result.png"]
            }
            report["edges"] = edges; completed.append("edgePlacement")
            guard try digest(source) == sourceDigest else { throw failure("Original source pixels were changed") }
            report["status"] = "passed"; report["originalRasterPreserved"] = true; report["allOwnedEditorsClosed"] = true
            report["completedChecks"] = completed; report["files"] = files + [reportName]
            try write(report, directory: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedChecks"] = completed; report["ownedEditorCleanupAttempted"] = true
            try? write(report, directory: evidenceDirectory); throw error
        }
    }

    private static func withEditor(_ captured: CapturedImage, name: String, directory: URL,
        body: (ImageEditorController) async throws -> [String: Any]) async throws -> [String: Any] {
        var saves = 0, otherCallbacks = 0, closes = 0
        var saveError: Error?, savedDigest: String?
        let url = directory.appendingPathComponent("annotation-\(name)-result.png")
        let editor = ImageEditorController(image: captured.image, presentation: captured.presentation,
            onSave: { image in
                saves += 1
                do { try image.writePNG(to: url); savedDigest = try digest(image) } catch { saveError = error }
            }, onPin: { _ in otherCallbacks += 1 }, onOCR: { _ in otherCallbacks += 1 })
        editor.onClose = { closes += 1 }
        defer { editor.close() }
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil); try await settle(editor)
        let baseDigest = try digest(captured.image)
        guard editor.annotationCanvas.zoom == 1, editor.annotationCanvas.displayScaleY == 1 else { throw failure("Fixture lost 1x native placement") }
        var result = try await body(editor)
        let finalDigest = try digest(unwrap(editor.annotationCanvas.flattened(), "Cannot flatten native result"))
        try menuAction("保存到历史", editor)
        if let saveError { throw saveError }
        guard saves == 1, savedDigest == finalDigest, otherCallbacks == 0 else { throw failure("Native save did not receive the flattened path pixels") }
        // A pending path must be released too when the whole editor is canceled.
        try choose(.polyline, editor); try canvasClick(editor.annotationCanvas, CGPoint(x: 8, y: 8))
        try click("editor.cancel", editor)
        guard editor.isClosed, editor.window?.isVisible != true, editor.window?.contentView == nil, editor.window?.delegate == nil,
              editor.captureBoundaryWorkspace.frozenImage == nil, editor.annotationCanvas.retainedPresentationRaster == nil,
              editor.annotationCanvas.pendingPolylinePointCount == 0, closes == 1, saves == 1, otherCallbacks == 0,
              try digest(captured.image) == baseDigest else { throw failure("Native path editor did not release owned UI/draft/cache or preserve the source") }
        result["nativeSaveCallbackCount"] = saves; result["flattenedSHA256"] = finalDigest
        result["nativeCancelPreservedInput"] = true; result["ownedWindowDetachedOnClose"] = true
        result["pendingPathReleasedOnClose"] = true; result["presentationCacheReleasedOnClose"] = true
        result["resultFile"] = url.lastPathComponent
        return result
    }

    private static func verifyArcs(_ editor: ImageEditorController, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas, original = try digest(canvas.image)
        let w = CGFloat(canvas.image.width), h = CGFloat(canvas.image.height)
        try choose(.arc, editor); try click("annotation.swatch.6", editor)
        try picker("annotation.lineWidth", title: "6", editor)
        try field("annotation.arcStart", value: "0", editor); try field("annotation.arcSweep", value: "180", editor)
        try drag(canvas, from: CGPoint(x: w * 0.08, y: h * 0.18), to: CGPoint(x: w * 0.42, y: h * 0.82))
        guard canvas.annotations.count == 1, canvas.annotations[0].tool == .arc else { throw failure("Native arc was not created") }
        var arc = canvas.annotations[0]
        let initial = try raster(canvas), initialDigest = try digest(initial)
        let top = AnnotationArcGeometry.point(in: arc.localBounds, angle: .pi / 2)
        guard try pixel(initial, top)[0] < 16,
              try pixel(initial, CGPoint(x: arc.localBounds.midX, y: arc.localBounds.midY)) == [255, 255, 255, 255] else {
            throw failure("Open arc pixels unexpectedly filled its center or omitted its curve")
        }
        for _ in 0..<2 {
            try undo(canvas); guard canvas.annotations.isEmpty, try digest(raster(canvas)) == original else { throw failure("Arc undo changed original pixels") }
            try undo(canvas, redo: true); guard try digest(raster(canvas)) == initialDigest else { throw failure("Arc redo raster changed") }
        }
        try choose(.select, editor)
        try canvasClick(canvas, top)
        try field("annotation.rotation", value: "25", editor)
        arc = canvas.annotations[0]
        let oldStart = arc.arcStartPoint.applying(arc.transform), oldEnd = arc.arcEndPoint.applying(arc.transform)
        let target = AnnotationArcGeometry.point(in: arc.localBounds, angle: .pi * 1.25).applying(arc.transform)
        try drag(canvas, from: oldEnd, to: target)
        guard close(canvas.annotations[0].arcStartPoint.applying(canvas.annotations[0].transform), oldStart),
              close(canvas.annotations[0].arcEndPoint.applying(canvas.annotations[0].transform), target) else { throw failure("Rotated angle drag moved the opposite endpoint") }
        let edited = try digest(raster(canvas))
        try undo(canvas)
        let beforeCancel = try digest(raster(canvas))
        arc = canvas.annotations[0]
        // Undo clears selection, so select the visible curve before exercising a handle.
        try canvasClick(canvas, arc.arcEndPoint.applying(arc.transform))
        try cancelDrag(canvas, from: arc.arcEndPoint.applying(arc.transform), to: target)
        guard !editor.isClosed, try digest(raster(canvas)) == beforeCancel else { throw failure("Escape committed an angle drag") }
        try undo(canvas, redo: true)
        guard try digest(raster(canvas)) == edited else { throw failure("Canceled angle drag destroyed redo") }
        try choose(.sector, editor)
        try field("annotation.arcStart", value: "0", editor); try field("annotation.arcSweep", value: "90", editor)
        try click("annotation.fill", editor)
        let fill: NSColorWell = try control("annotation.fillColor", editor)
        fill.color = NSColor(srgbRed: 0.12, green: 0.48, blue: 0.92, alpha: 1); try send(fill)
        try drag(canvas, from: CGPoint(x: w * 0.54, y: h * 0.18), to: CGPoint(x: w * 0.92, y: h * 0.82))
        guard canvas.annotations.count == 2, canvas.annotations[1].tool == .sector, canvas.annotations[1].fillEnabled else { throw failure("Native filled sector was not created") }
        let sector = canvas.annotations[1], box = sector.localBounds
        let inside = try pixel(raster(canvas), CGPoint(x: box.midX + box.width * 0.12, y: box.midY + box.height * 0.12))
        let outside = try pixel(raster(canvas), CGPoint(x: box.midX - box.width * 0.12, y: box.midY + box.height * 0.12))
        guard inside[2] > 220, inside[0] < 50, outside == [255, 255, 255, 255] else { throw failure("Sector fill did not match its angular region") }
        try field("annotation.arcSweep", value: "-240", editor)
        guard canvas.annotations[1].effectiveArcSweep < 0 else { throw failure("Clockwise sweep field was ignored") }
        try undo(canvas); try undo(canvas, redo: true)
        try choose(.select, editor)
        try canvasClick(canvas, canvas.annotations[1].arcStartPoint.applying(canvas.annotations[1].transform))
        try await snapshot(editor, filename: "ui-annotation-arcs.png", controls: ["annotation.arcStart", "annotation.arcSweep", "annotation.fill"], directory: directory)
        return ["nativeSubtoolsReachable": true, "openArcHasNoRadialFill": true, "sectorFillMatchesAnglePixels": true,
            "twoUndoRedoCyclesPixelIdentical": true, "rotatedEndpointKeepsOppositeFixed": true,
            "cancelledAngleDragPreservesRedo": true, "negativeSweepEditable": true, "committedAnnotationCount": canvas.annotations.count]
    }

    private static func verifyPolyline(_ editor: ImageEditorController, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas, original = try digest(canvas.image)
        let w = CGFloat(canvas.image.width), h = CGFloat(canvas.image.height)
        let points = [CGPoint(x: w * 0.10, y: h * 0.20), CGPoint(x: w * 0.33, y: h * 0.73),
                      CGPoint(x: w * 0.57, y: h * 0.30), CGPoint(x: w * 0.82, y: h * 0.77)]
        try choose(.polyline, editor); try click("annotation.swatch.6", editor)
        for point in points.prefix(3) { try canvasClick(canvas, point) }
        try picker("annotation.lineWidth", title: "6", editor)
        canvas.mouseMoved(with: try mouse(canvas, .mouseMoved, points[3]))
        guard canvas.annotations.isEmpty, canvas.pendingPolylinePointCount == 3,
              canvas.pendingPolyline?.lineWidth == 6, try digest(raster(canvas)) == original else { throw failure("Unfinished polyline leaked into saved pixels/history or ignored live style") }
        try await snapshot(editor, filename: "ui-annotation-polyline-draft.png", controls: ["annotation.finishPolyline", "annotation.cancelPolyline", "annotation.lineWidth"], directory: directory)
        canvas.keyDown(with: try key(canvas, code: 51, value: "\u{7f}"))
        guard canvas.pendingPolylinePointCount == 2 else { throw failure("Backspace did not remove one draft vertex") }
        try canvasClick(canvas, points[2]); try undo(canvas)
        guard canvas.pendingPolylinePointCount == 2, canvas.annotations.isEmpty else { throw failure("Draft Command-Z altered committed history") }
        try canvasClick(canvas, points[2]); try canvasClick(canvas, points[3]); try canvasClick(canvas, points[3], clicks: 2)
        guard canvas.pendingPolylinePointCount == 0, canvas.annotations.count == 1, canvas.annotations[0].points.count == points.count,
              zip(canvas.annotations[0].points, points).allSatisfy({ close($0.0, $0.1) }) else {
            throw failure("Double-click did not finish one path without duplicate vertices")
        }
        let committed = try digest(raster(canvas))
        for _ in 0..<2 {
            try undo(canvas); guard canvas.annotations.isEmpty else { throw failure("Polyline used multiple undo states") }
            try canvasClick(canvas, points[0]); try canvasClick(canvas, points[1])
            canvas.keyDown(with: try key(canvas, code: 53, value: "\u{1b}"))
            guard !editor.isClosed, canvas.pendingPolylinePointCount == 0, try digest(raster(canvas)) == original else { throw failure("Escape did not discard only the unfinished path") }
            try undo(canvas, redo: true)
            guard try digest(raster(canvas)) == committed else { throw failure("Cancel destroyed polyline redo pixels") }
        }
        try canvasClick(canvas, CGPoint(x: 25, y: 25)); try canvasClick(canvas, CGPoint(x: 80, y: 25))
        try click("annotation.cancelPolyline", editor)
        guard canvas.annotations.count == 1, canvas.pendingPolylinePointCount == 0 else { throw failure("Native Cancel button committed a path") }
        try canvasClick(canvas, CGPoint(x: 25, y: 25)); try canvasClick(canvas, CGPoint(x: 80, y: 25))
        canvas.keyDown(with: try key(canvas, code: 36, value: "\r"))
        guard canvas.annotations.count == 2 else { throw failure("Return did not finish the path") }
        try undo(canvas)
        try canvasClick(canvas, CGPoint(x: 25, y: 25)); try canvasClick(canvas, CGPoint(x: 80, y: 25))
        try click("annotation.finishPolyline", editor)
        guard canvas.annotations.count == 2 else { throw failure("Native Finish button did not commit the path") }
        try undo(canvas)
        // The last canceled path must not become a stray vertex when changing tools.
        try canvasClick(canvas, CGPoint(x: 25, y: 25)); try choose(.select, editor)
        guard canvas.pendingPolylinePointCount == 0, canvas.annotations.count == 1 else { throw failure("Tool change committed an unfinished path") }
        try canvasClick(canvas, points[1])
        try field("annotation.rotation", value: "15", editor)
        let rotated = canvas.annotations[0], world = rotated.points.map { $0.applying(rotated.transform) }
        let target = CGPoint(x: world[2].x + 35, y: world[2].y + 18)
        try drag(canvas, from: world[2], to: target)
        guard canvas.annotations[0].rotation == 0, close(canvas.annotations[0].points[2], target),
              zip(canvas.annotations[0].points, world).enumerated().allSatisfy({ $0.offset == 2 || close($0.element.0, $0.element.1) }) else {
            throw failure("Rotated vertex drag displaced unrelated vertices")
        }
        let edited = try digest(raster(canvas))
        try undo(canvas)
        try canvasClick(canvas, world[1])
        try cancelDrag(canvas, from: world[2], to: target)
        try undo(canvas, redo: true)
        guard try digest(raster(canvas)) == edited else { throw failure("Canceled vertex drag changed redo") }
        try canvasClick(canvas, target)
        try picker("annotation.strokeStyle", title: AnnotationStrokeStyle.dashed.title, editor)
        let dashed = try digest(raster(canvas)); guard dashed != edited else { throw failure("Native dashed polyline did not change pixels") }
        try undo(canvas); guard try digest(raster(canvas)) == edited else { throw failure("Polyline style undo did not restore solid pixels") }
        try undo(canvas, redo: true); guard try digest(raster(canvas)) == dashed else { throw failure("Polyline style redo was not deterministic") }
        try canvasClick(canvas, target)
        try await snapshot(editor, filename: "ui-annotation-polyline-edit.png", controls: ["annotation.strokeStyle", "annotation.rotation"], directory: directory)
        return ["nativeSubtoolsReachable": true, "draftExcludedFromExport": true, "backspaceAndCommandZRemoveOneVertex": true,
            "doubleClickNoDuplicateVertex": true, "returnAndFinishButtonCommit": true, "cancelAndToolSwitchDiscardDraft": true,
            "twoUndoRedoCyclesPixelIdentical": true, "escapePreservesRedo": true, "rotatedVertexKeepsOthersFixed": true,
            "cancelledVertexDragPreservesRedo": true, "dashStyleUndoRedoPixelIdentical": true, "committedPointCount": canvas.annotations[0].points.count]
    }

    private static func snapshot(_ editor: ImageEditorController, filename: String, controls: [String], directory: URL) async throws {
        try await settle(editor)
        let view = try unwrap(editor.window?.contentView, "Missing native content view")
        guard editor.contextualPaletteVisible, view.bounds.contains(editor.contextualPaletteFrame), view.bounds.contains(editor.floatingToolbarFrame),
              !editor.contextualPaletteFrame.intersects(editor.floatingToolbarFrame) else { throw failure("Path palette/toolbar is clipped or overlaps") }
        for id in controls {
            let widget: NSControl = try control(id, editor)
            guard widget.isEnabled, !widget.isHiddenOrHasHiddenAncestor, widget.target != nil, widget.action != nil else { throw failure("Native control \(id) is unreachable") }
        }
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try checkSize(width: width, height: height)
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Cannot allocate bounded native snapshot")
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try unwrap(bitmap.cgImage, "Missing view pixels")
        guard image.width == width, image.height == height else { throw failure("Snapshot exceeded 1x dimensions") }
        try image.writePNG(to: directory.appendingPathComponent(filename))
    }
    private static func settle(_ editor: ImageEditorController) async throws {
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 40_000_000)
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
    }
    private static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    private static func control<T: NSView>(_ id: String, _ editor: ImageEditorController) throws -> T {
        try unwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == id } as? T, "Missing control \(id)")
    }
    private static func click(_ id: String, _ editor: ImageEditorController) throws {
        let button: NSButton = try control(id, editor)
        guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { throw failure("Unavailable native button \(id)") }
        button.performClick(nil)
    }
    private static func choose(_ tool: ImageEditorTool, _ editor: ImageEditorController) throws {
        let family = tool.isArcTool ? "editor.shapeSubtools" : (tool == .polyline ? "editor.lineSubtools" : "")
        if !family.isEmpty, let menu = descendants(editor.window?.contentView).first(where: { $0.identifier?.rawValue == family }) as? NSPopUpButton,
           !menu.isHiddenOrHasHiddenAncestor, let items = menu.menu, let index = items.items.firstIndex(where: { $0.title == tool.title }) {
            items.performActionForItem(at: index)
        } else if let button = descendants(editor.window?.contentView).first(where: { $0.identifier?.rawValue == "editor.tool.\(tool.rawValue)" }) as? NSButton,
                  !button.isHiddenOrHasHiddenAncestor { button.performClick(nil) }
        else { try menuAction(tool.title, editor) }
        guard editor.annotationCanvas.tool == tool else { throw failure("Native subtool selection failed for \(tool.rawValue)") }
    }
    private static func menuAction(_ title: String, _ editor: ImageEditorController) throws {
        let more: NSPopUpButton = try control("editor.more", editor)
        guard let menu = more.menu, let index = menu.items.firstIndex(where: { $0.title == title }),
              menu.items[index].target != nil, menu.items[index].action != nil else { throw failure("Missing native menu action \(title)") }
        menu.performActionForItem(at: index)
    }
    private static func send(_ control: NSControl) throws {
        guard control.isEnabled, !control.isHiddenOrHasHiddenAncestor, control.target != nil, control.action != nil,
              control.sendAction(control.action, to: control.target) else { throw failure("Native control rejected its action") }
    }
    private static func field(_ id: String, value: String, _ editor: ImageEditorController) throws {
        let widget: NSTextField = try control(id, editor); widget.stringValue = value; try send(widget)
    }
    private static func picker(_ id: String, title: String, _ editor: ImageEditorController) throws {
        let widget: NSPopUpButton = try control(id, editor)
        guard widget.item(withTitle: title) != nil else { throw failure("Missing picker value \(title)") }
        widget.selectItem(withTitle: title); try send(widget)
    }
    private static func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: 1), "Cannot create native mouse event")
    }
    private static func key(_ canvas: ImageEditorCanvas, code: UInt16, value: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: value, charactersIgnoringModifiers: value,
            isARepeat: false, keyCode: code), "Cannot create native key event")
    }
    private static func canvasClick(_ canvas: ImageEditorCanvas, _ point: CGPoint, clicks: Int = 1) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point, clicks: clicks)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point, clicks: clicks))
    }
    private static func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start)); canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }
    private static func cancelDrag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start)); canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end))
        canvas.keyDown(with: try key(canvas, code: 53, value: "\u{1b}")); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }
    private static func undo(_ canvas: ImageEditorCanvas, redo: Bool = false) throws {
        guard canvas.performKeyEquivalent(with: try key(canvas, code: 6, value: "z", flags: redo ? [.command, .shift] : .command)) else {
            throw failure("Native undo/redo key was not handled")
        }
    }
    private static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }
    private static func raster(_ canvas: ImageEditorCanvas) throws -> CGImage { try unwrap(canvas.flattened(), "Cannot flatten canvas") }
    private static func checkSize(width: Int, height: Int) throws {
        guard width > 0, height > 0, height <= maximumPixels, width <= maximumPixels / height else { throw failure("Fixture exceeded its raster bound") }
    }
    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        try checkSize(width: width, height: height)
        return try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Cannot allocate fixture raster")
    }
    private static func whiteImage(size: CGSize) throws -> CGImage {
        let context = try bitmap(width: Int(size.width), height: Int(size.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        return try unwrap(context.makeImage(), "Cannot create synthetic white source")
    }
    private static func pixel(_ image: CGImage, _ point: CGPoint) throws -> [UInt8] {
        let context = try bitmap(width: 1, height: 1); context.translateBy(x: -floor(point.x), y: -floor(point.y))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try unwrap(context.data, "Missing pixel data").assumingMemoryBound(to: UInt8.self), count: 4))
    }
    private static func digest(_ image: CGImage) throws -> String {
        let context = try bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = Data(bytes: try unwrap(context.data, "Missing raster data"), count: context.bytesPerRow * context.height)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(reportName), options: .atomic)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Native annotation paths preview: \(message)") }
}
