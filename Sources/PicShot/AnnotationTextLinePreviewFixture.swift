import AppKit
import CoreGraphics
import CryptoKit
import ImageIO

/// Opt-in native evidence over authored pixels. No screen capture, external input,
/// clipboard, preferences, recognition, or network activity is needed.
@MainActor
enum AnnotationTextLinePreviewFixture {
    private static let maximumPixels = 4_000_000
    private static let reportName = "annotation-text-line-preview.json"

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        var report: [String: Any] = ["status": "running", "syntheticDesktop": true,
            "scope": "Native owned AppKit controls and NSEvents; line styles, multilingual text outline, undo/cancel, PNG roundtrip and 760-point compact palettes",
            "maximumFixtureRasterPixels": maximumPixels, "maximumConcurrentOwnedEditors": 1,
            "screenCaptureAttempted": false, "networkAttempted": false, "preferencesWritten": false,
            "generalPasteboardUsed": false, "sourcePixelsPerPoint": 1, "snapshotPixelsPerPoint": 1,
            "limitations": ["Synthetic 1x source, not live capture, physical input or Retina acquisition", "AppKit text input is unrotated while editing; committed canvas and export share the rotated CoreText renderer", "Owned reference cleanup is not a process-memory or leak measurement"]]
        var files: [String] = [], themes: [[String: Any]] = [], edges: [[String: Any]] = []
        do {
            guard let screen = NSScreen.main, let displayID = screen.displayID,
                  screen.frame.width >= 760, screen.frame.height >= 600 else { throw failure("A 760 by 600 point WindowServer display is required") }
            let source = try whiteImage(size: CGSize(width: 760, height: 600)), sourceDigest = try digest(source)
            let frame = CGRect(origin: screen.frame.origin, size: CGSize(width: 760, height: 600))
            report["desktopPixelWidth"] = 760; report["desktopPixelHeight"] = 600
            report["nativeDisplayBackingScale"] = screen.backingScaleFactor
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                let captured = try CapturedImage.frozenRegion(image: source, displayID: displayID, displayFrame: frame,
                    selection: CGRect(x: 40, y: 90, width: 680, height: 360), capturedAt: Date(timeIntervalSince1970: 1_704_164_645))
                var evidence = try await withEditor(captured, name: theme, directory: evidenceDirectory) { editor in
                    let line = try await verifyLine(editor, theme: theme, directory: evidenceDirectory)
                    let text = try await verifyText(editor, theme: theme, directory: evidenceDirectory)
                    return ["line": line, "text": text]
                }
                evidence["appearance"] = theme; themes.append(evidence)
                files += ["ui-textline-line-\(theme).png", "ui-textline-text-\(theme).png", "ui-textline-inline-\(theme).png", "textline-\(theme)-result.png"]
            }
            for (index, position) in [("top-left", CGPoint(x: 8, y: 8)), ("top-right", CGPoint(x: 572, y: 8)),
                                      ("bottom-left", CGPoint(x: 8, y: 472)), ("bottom-right", CGPoint(x: 572, y: 472))].enumerated() {
                let theme = index.isMultiple(of: 2) ? "light" : "dark"
                NSApp.appearance = NSAppearance(named: index.isMultiple(of: 2) ? .aqua : .darkAqua)
                let captured = try CapturedImage.frozenRegion(image: source, displayID: displayID, displayFrame: frame,
                    selection: CGRect(origin: position.1, size: CGSize(width: 180, height: 120)))
                var evidence = try await withEditor(captured, name: position.0, directory: evidenceDirectory) { editor in
                    let canvas = editor.annotationCanvas, originalFrame = canvas.frame, selection = editor.editorSelectionFrame
                    if index < 2 {
                        try choose(.arrow, editor); try click("annotation.startArrow", editor)
                        try picker("annotation.startArrowhead", title: AnnotationArrowhead.diamond.title, editor)
                        try picker("annotation.endArrowhead", title: AnnotationArrowhead.filledTriangle.title, editor)
                        try drag(canvas, from: CGPoint(x: 25, y: 35), to: CGPoint(x: 145, y: 80))
                        try click("annotation.details", editor)
                        try await snapshot(editor, filename: "ui-textline-edge-\(position.0).png",
                            controls: ["annotation.startArrowhead", "annotation.endArrowhead", "annotation.lineCap", "annotation.lineJoin"], directory: evidenceDirectory)
                    } else {
                        try choose(.text, editor); try canvasClick(canvas, CGPoint(x: 15, y: 100))
                        let input = try unwrap(editor.activeInlineTextView, "Missing edge text input")
                        input.insertText("边缘 Edge", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
                        try click("annotation.textOutline", editor); try click("annotation.fill", editor)
                        input.keyDown(with: try key(canvas, code: 36, value: "\r", flags: .command))
                        try await snapshot(editor, filename: "ui-textline-edge-\(position.0).png",
                            controls: ["annotation.textOutline", "annotation.textOutlineColor", "annotation.textOutlineWidth", "annotation.fill"], directory: evidenceDirectory)
                    }
                    guard canvas.frame == originalFrame, editor.editorSelectionFrame == selection else { throw failure("Style palette moved the captured image at an edge") }
                    return ["frozenImageAnchored": true, "paletteInsideWorkspace": true, "requiredControlsInsidePalette": true, "toolbarPaletteDoNotOverlap": true]
                }
                evidence["edge"] = position.0; evidence["appearance"] = theme; edges.append(evidence)
                files += ["ui-textline-edge-\(position.0).png", "textline-\(position.0)-result.png"]
            }
            guard try digest(source) == sourceDigest else { throw failure("Authored source pixels changed") }
            report["status"] = "passed"; report["themes"] = themes; report["edges"] = edges
            report["originalRasterPreserved"] = true; report["allOwnedEditorsClosed"] = true
            report["files"] = files + [reportName]; try write(report, directory: evidenceDirectory)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["themes"] = themes; report["edges"] = edges; report["files"] = files
            try? write(report, directory: evidenceDirectory); throw error
        }
    }

    private static func withEditor(_ captured: CapturedImage, name: String, directory: URL,
        body: (ImageEditorController) async throws -> [String: Any]) async throws -> [String: Any] {
        var saves = 0, otherCallbacks = 0, closes = 0
        var saveError: Error?, savedDigest: String?
        let url = directory.appendingPathComponent("textline-\(name)-result.png")
        let editor = ImageEditorController(image: captured.image, presentation: captured.presentation,
            onSave: { image in
                saves += 1
                do { try image.writePNG(to: url); savedDigest = try digest(image) } catch { saveError = error }
            }, onPin: { _ in otherCallbacks += 1 }, onOCR: { _ in otherCallbacks += 1 })
        editor.onClose = { closes += 1 }; defer { editor.close() }
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil); try await settle(editor)
        let baseDigest = try digest(captured.image)
        guard editor.annotationCanvas.zoom == 1, editor.annotationCanvas.displayScaleY == 1 else { throw failure("Fixture lost 1x placement") }
        var result = try await body(editor)
        let finalDigest = try digest(raster(editor.annotationCanvas))
        try menuAction("保存到历史", editor)
        if let saveError { throw saveError }
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "Missing saved PNG")
        let decoded = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "Cannot decode saved PNG")
        guard saves == 1, savedDigest == finalDigest, try digest(decoded) == finalDigest, otherCallbacks == 0 else { throw failure("Native save/PNG roundtrip differs from the displayed renderer") }
        try choose(.polyline, editor); try canvasClick(editor.annotationCanvas, CGPoint(x: 8, y: 8))
        try click("editor.cancel", editor)
        guard editor.isClosed, editor.window?.isVisible != true, editor.window?.contentView == nil, editor.window?.delegate == nil,
              editor.captureBoundaryWorkspace.frozenImage == nil, editor.annotationCanvas.retainedPresentationRaster == nil,
              editor.annotationCanvas.pendingPolylinePointCount == 0, editor.activeInlineTextView == nil,
              closes == 1, saves == 1, otherCallbacks == 0, try digest(captured.image) == baseDigest else { throw failure("Cancel did not release owned UI/draft/cache or preserve input") }
        result["nativeSaveCallbackCount"] = saves; result["flattenedSHA256"] = finalDigest
        result["pngRoundtripPixelIdentical"] = true; result["nativeCancelPreservedInput"] = true
        result["ownedWindowDetachedOnClose"] = true; result["pendingPathReleasedOnClose"] = true
        result["presentationCacheReleasedOnClose"] = true; result["resultFile"] = url.lastPathComponent
        return result
    }

    private static func verifyLine(_ editor: ImageEditorController, theme: String, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas, sourceDigest = try digest(canvas.image)
        try choose(.polyline, editor); try click("annotation.swatch.6", editor)
        try picker("annotation.lineWidth", title: "10", editor)
        try click("annotation.startArrow", editor); try click("annotation.endArrow", editor)
        try picker("annotation.startArrowhead", title: AnnotationArrowhead.diamond.title, editor)
        try picker("annotation.endArrowhead", title: AnnotationArrowhead.filledTriangle.title, editor)
        try picker("annotation.lineCap", title: AnnotationLineCap.square.title, editor)
        try picker("annotation.lineJoin", title: AnnotationLineJoin.miter.title, editor)
        let opacity: NSSlider = try control("annotation.opacity", editor)
        opacity.doubleValue = 0.5; try send(opacity)
        for point in [CGPoint(x: 30, y: 55), CGPoint(x: 100, y: 175), CGPoint(x: 190, y: 70), CGPoint(x: 275, y: 175)] { try canvasClick(canvas, point) }
        guard canvas.pendingPolylinePointCount == 4, canvas.annotations.isEmpty, try digest(raster(canvas)) == sourceDigest else { throw failure("Uncommitted styled path leaked into export") }
        try click("annotation.finishPolyline", editor)
        guard canvas.annotations.count == 1, canvas.annotations[0].startArrowEnabled,
              canvas.annotations[0].effectiveEndArrowEnabled, canvas.annotations[0].lineCap == .square,
              canvas.annotations[0].lineJoin == .miter else { throw failure("Native style controls did not reach committed path") }
        let initialRaster = try raster(canvas), initial = try digest(initialRaster)
        let alphaCheck = try bitmap(width: initialRaster.width, height: initialRaster.height)
        alphaCheck.draw(initialRaster, in: CGRect(x: 0, y: 0, width: initialRaster.width, height: initialRaster.height))
        let alphaPixels = try unwrap(alphaCheck.data, "Missing translucent line pixels").assumingMemoryBound(to: UInt8.self)
        let darkest = stride(from: 0, to: alphaCheck.bytesPerRow * alphaCheck.height, by: 4).map { alphaPixels[$0] }.min() ?? 255
        guard darkest >= 126, darkest <= 129 else { throw failure("Translucent shaft and closed heads do not composite exactly once") }
        for _ in 0..<2 {
            try undo(canvas); guard canvas.annotations.isEmpty, try digest(raster(canvas)) == sourceDigest else { throw failure("Styled path undo failed") }
            try undo(canvas, redo: true); guard try digest(raster(canvas)) == initial else { throw failure("Styled path redo pixels differ") }
        }
        // Cancel a new styled draft without erasing the previous committed object.
        try canvasClick(canvas, CGPoint(x: 30, y: 230)); try canvasClick(canvas, CGPoint(x: 120, y: 280))
        try click("annotation.cancelPolyline", editor)
        guard canvas.annotations.count == 1, canvas.pendingPolylinePointCount == 0, try digest(raster(canvas)) == initial else { throw failure("Cancel committed a new path") }
        try choose(.select, editor); try canvasClick(canvas, CGPoint(x: 100, y: 175))
        try picker("annotation.endArrowhead", title: AnnotationArrowhead.outlineTriangle.title, editor)
        let edited = try digest(raster(canvas)); guard edited != initial else { throw failure("Selected head form did not change real pixels") }
        try undo(canvas); try canvasClick(canvas, CGPoint(x: 100, y: 175))
        try cancelDrag(canvas, from: CGPoint(x: 100, y: 175), to: CGPoint(x: 130, y: 210))
        guard try digest(raster(canvas)) == initial, !editor.isClosed else { throw failure("Cancelled styled vertex drag changed committed pixels") }
        try undo(canvas, redo: true)
        guard try digest(raster(canvas)) == edited else { throw failure("Cancelled style drag consumed redo") }
        try canvasClick(canvas, CGPoint(x: 100, y: 175))
        try await snapshot(editor, filename: "ui-textline-line-\(theme).png",
            controls: ["annotation.startArrowhead", "annotation.endArrowhead", "annotation.lineCap", "annotation.lineJoin"], directory: directory)
        return ["nativeEndpointAndStrokeControls": true, "draftExcludedFromExport": true, "translucentLineCompositedOnce": true,
            "twoUndoRedoCyclesPixelIdentical": true, "cancelledDraftPreservesCommittedPath": true,
            "selectedHeadEditChangesPixels": true, "cancelledVertexDragPreservesRedo": true, "committedPointCount": 4]
    }

    private static func verifyText(_ editor: ImageEditorController, theme: String, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas
        try choose(.text, editor); try canvasClick(canvas, CGPoint(x: 350, y: 280))
        let input = try unwrap(editor.activeInlineTextView, "Missing native inline text input")
        input.insertText("Flow → 世界\nمرحبا · 한글", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        try field("annotation.fontSize", value: "24", editor); try click("annotation.bold", editor)
        try click("annotation.underline", editor); try click("annotation.textOutline", editor)
        try field("annotation.textOutlineWidth", value: "2", editor)
        let outlineColor: NSColorWell = try control("annotation.textOutlineColor", editor)
        outlineColor.color = NSColor(srgbRed: 0.1, green: 0.4, blue: 1, alpha: 1); try send(outlineColor)
        try click("annotation.fill", editor)
        let fillColor: NSColorWell = try control("annotation.fillColor", editor)
        fillColor.color = NSColor(srgbRed: 1, green: 0.94, blue: 0.65, alpha: 1); try send(fillColor)
        guard input.typingAttributes[.strokeWidth] != nil,
              input.textStorage?.attribute(.strokeColor, at: 0, effectiveRange: nil) != nil else { throw failure("Inline input lost outline typing/existing-text attributes") }
        input.keyDown(with: try key(canvas, code: 36, value: "\r", flags: .command))
        guard canvas.annotations.count == 2, canvas.annotations[1].textOutlineEnabled, canvas.annotations[1].fillEnabled,
              canvas.annotations[1].text.contains("世界"), canvas.annotations[1].text.contains("مرحبا") else { throw failure("Native multilingual outlined text did not commit") }
        try choose(.select, editor)
        let text = canvas.annotations[1], center = CGPoint(x: text.localBounds.midX, y: text.localBounds.midY)
        try canvasClick(canvas, center); try click("annotation.details", editor)
        try field("annotation.rotation", value: "17", editor)
        let rotated = try digest(raster(canvas))
        try undo(canvas)
        let beforeCancel = try digest(raster(canvas))
        try canvasClick(canvas, center, clicks: 2)
        let cancelled = try unwrap(editor.activeInlineTextView, "Cannot re-edit selected outlined text")
        cancelled.insertText("Must not persist 不保存", replacementRange: NSRange(location: 0, length: cancelled.string.utf16.count))
        try field("annotation.textOutlineWidth", value: "3", editor)
        let liveWidth: NSTextField = try control("annotation.textOutlineWidth", editor)
        guard liveWidth.doubleValue == 3 else { throw failure("Inline inspector displayed stale committed outline width") }
        try await snapshot(editor, filename: "ui-textline-inline-\(theme).png", controls: ["annotation.textOutlineWidth", "annotation.textOutlineColor"], directory: directory)
        cancelled.keyDown(with: try key(canvas, code: 53, value: "\u{1b}"))
        guard editor.activeInlineTextView == nil, try digest(raster(canvas)) == beforeCancel,
              canvas.annotations[1].textOutlineWidth == 2 else { throw failure("Cancelled text/style edit mutated the original") }
        try undo(canvas, redo: true)
        guard try digest(raster(canvas)) == rotated else { throw failure("Cancelled inline style edit consumed redo") }
        try canvasClick(canvas, center, clicks: 2)
        let editing = try unwrap(editor.activeInlineTextView, "Cannot re-edit rotated outlined text")
        editing.insertText("Edited 第一行\nالعربية → 日本語", replacementRange: NSRange(location: 0, length: editing.string.utf16.count))
        try field("annotation.textOutlineWidth", value: "3", editor)
        editing.keyDown(with: try key(canvas, code: 36, value: "\r", flags: .command))
        guard canvas.annotations.count == 2, canvas.annotations[1].id == text.id,
              canvas.annotations[1].textOutlineWidth == 3, canvas.annotations[1].rotation != 0 else { throw failure("Continued text editing lost identity, rotation or stroke width") }
        let final = try digest(raster(canvas))
        guard final != rotated else { throw failure("Committed text edit did not change exported pixels") }
        for _ in 0..<2 {
            try undo(canvas); guard try digest(raster(canvas)) == rotated else { throw failure("Outlined text undo pixels differ") }
            try undo(canvas, redo: true); guard try digest(raster(canvas)) == final else { throw failure("Outlined text redo pixels differ") }
        }
        try canvasClick(canvas, center)
        try await snapshot(editor, filename: "ui-textline-text-\(theme).png",
            controls: ["annotation.textOutline", "annotation.textOutlineColor", "annotation.textOutlineWidth", "annotation.fill", "annotation.fontSize"], directory: directory)
        return ["nativeMultilingualInlineInput": true, "independentOutlineAndBackground": true,
            "inlineTypingAndExistingTextOutline": true, "inlineInspectorUsesCurrentStyle": true,
            "continuedEditPreservesIdentityAndRotation": true, "cancelledTextAndStylePreservesRedo": true,
            "twoUndoRedoCyclesPixelIdentical": true, "textBoxWidth": canvas.annotations[1].localBounds.width]
    }
    private static func snapshot(_ editor: ImageEditorController, filename: String, controls: [String], directory: URL) async throws {
        try await settle(editor)
        let view = try unwrap(editor.window?.contentView, "Missing native content view")
        guard editor.contextualPaletteVisible, view.bounds.contains(editor.contextualPaletteFrame), view.bounds.contains(editor.floatingToolbarFrame),
              !editor.contextualPaletteFrame.intersects(editor.floatingToolbarFrame) else { throw failure("Path palette/toolbar is clipped or overlaps") }
        for id in controls {
            let widget: NSControl = try control(id, editor)
            guard widget.isEnabled, !widget.isHiddenOrHasHiddenAncestor, widget.target != nil, widget.action != nil,
                  editor.contextualPaletteFrame.insetBy(dx: -1, dy: -1).contains(widget.convert(widget.bounds, to: view)) else { throw failure("Native control \(id) is unreachable or clipped") }
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
    private static func failure(_ message: String) -> Error { PicShotError.message("Native annotation text/line preview: \(message)") }
}
