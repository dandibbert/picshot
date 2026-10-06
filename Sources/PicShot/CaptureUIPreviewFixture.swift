import AppKit
import CoreGraphics
import CoreText

/// Native UI evidence on an original, explicitly labeled synthetic desktop.
/// Never requests screen permission, reads desktop pixels, runs OCR, or changes
/// preferences. This verifies presentation and editing, not screen capture/TCC.
@MainActor
enum CaptureUIPreviewFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        let displaySetup = try await waitForDisplayGeometryQuiet()
        guard let screen = NSScreen.main, let displayID = screen.displayID else { throw failure("No WindowServer display for native UI evidence") }
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let previousAppearance = NSApp.appearance
        var editors: [ImageEditorController] = []
        var pins: [PinController] = []
        var results: [TextResultController] = []
        defer {
            editors.forEach { $0.close() }; pins.forEach { $0.close() }; results.forEach { $0.close() }
            NSApp.appearance = previousAppearance
        }
        let desktop = try syntheticDesktop(screen: screen)
        let points = screen.frame.size
        let sourceSelection = CGRect(x: points.width * 0.10, y: points.height * 0.19,
                                     width: points.width * 0.80, height: points.height * 0.57)
        let captured = try CapturedImage.frozenRegion(image: desktop, displayID: displayID,
                                                      displayFrame: screen.frame, selection: sourceSelection)
        guard let presentation = captured.presentation else { throw failure("Synthetic crop lost its origin") }
        var saveCallbacks = 0, pinCallbacks = 0, ocrCallbacks = 0
        let save: (CGImage) -> Void = { image in
            saveCallbacks += 1
            try? image.writePNG(to: evidenceDirectory.appendingPathComponent("ui-synthetic-edited-result.png"))
        }
        let pin: (CGImage) -> Void = { image in
            pinCallbacks += 1
            let controller = PinController(image: image); pins.append(controller); controller.showWindow(nil)
        }
        let ocr: (CGImage) -> Void = { _ in
            ocrCallbacks += 1
            let controller = TextResultController(text: "Synthetic text result fixture\n\nCapture, annotate, and keep a detail nearby.\n原生文字结果面板 · 此文本为测试数据，未运行 OCR。",
                                                  title: "PicShot · Synthetic OCR UI preview")
            results.append(controller); controller.showWindow(nil)
        }
        func editor(_ image: CapturedImage) -> ImageEditorController {
            let controller = ImageEditorController(image: image.image, presentation: image.presentation,
                                                   onSave: save, onPin: pin, onOCR: ocr)
            editors.append(controller); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            return controller
        }

        NSApp.appearance = NSAppearance(named: .aqua)
        let light = editor(captured)
        try await settle(light.window)
        try checkPlacement(light, presentation: presentation)
        try click("editor.tool.rectangle", in: light)
        try click("annotation.swatch.0", in: light)
        let canvas = light.annotationCanvas
        try drag(canvas, from: CGPoint(x: CGFloat(canvas.image.width) * 0.045, y: CGFloat(canvas.image.height) * 0.78),
                 to: CGPoint(x: CGFloat(canvas.image.width) * 0.72, y: CGFloat(canvas.image.height) * 0.97))
        guard canvas.annotations.count == 1, canvas.annotations[0].tool == .rectangle else { throw failure("Native rectangle gesture did not create its model annotation") }
        try click("editor.tool.arrow", in: light)
        try drag(canvas, from: CGPoint(x: CGFloat(canvas.image.width) * 0.63, y: CGFloat(canvas.image.height) * 0.28),
                 to: CGPoint(x: CGFloat(canvas.image.width) * 0.79, y: CGFloat(canvas.image.height) * 0.54))
        try click("editor.tool.rectangle", in: light)
        try await settle(light.window)
        try checkControls(light)
        guard !light.floatingSurfaceIsDark, light.toolbarSymbolPointSize >= 17 else { throw failure("Light theme or symbol sizing did not apply") }
        try snapshot(light.window, to: evidenceDirectory.appendingPathComponent("ui-capture-rectangle-light.png"))

        // Use the toolbar, then native canvas mouse input, then actual NSTextView
        // accept/cancel keyboard paths. The preview remains a real editable view.
        try click("editor.tool.text", in: light)
        let textPoint = CGPoint(x: CGFloat(canvas.image.width) * 0.52, y: CGFloat(canvas.image.height) * 0.65)
        let initialCount = canvas.annotations.count
        try canvasClick(canvas, at: textPoint)
        guard let cancelled = light.activeInlineTextView else { throw failure("Text tool did not open inline input") }
        cancelled.insertText("This edit must be cancelled", replacementRange: NSRange(location: 0, length: 0))
        cancelled.keyDown(with: try key(canvas, code: 53, value: "\u{1b}"))
        guard light.activeInlineTextView == nil, canvas.annotations.count == initialCount else { throw failure("Inline cancel changed the model") }
        try canvasClick(canvas, at: textPoint)
        guard let input = light.activeInlineTextView else { throw failure("Repeated text tool did not reopen inline input") }
        input.insertText("Native text", replacementRange: NSRange(location: 0, length: 0))
        input.keyDown(with: try key(canvas, code: 36, value: "\r"))
        guard light.activeInlineTextView === input, canvas.annotations.count == initialCount else { throw failure("Return unexpectedly committed inline text") }
        input.insertText("图上直接编辑", replacementRange: input.selectedRange())
        try click("annotation.bold", in: light)
        try await settle(light.window)
        guard light.window?.attachedSheet == nil, light.activeInlineTextView != nil else { throw failure("Inline text unexpectedly became modal") }
        try snapshot(light.window, to: evidenceDirectory.appendingPathComponent("ui-capture-text-light.png"))
        input.keyDown(with: try key(canvas, code: 36, value: "\r", flags: .command))
        guard light.activeInlineTextView == nil, canvas.annotations.count == initialCount + 1,
              canvas.annotations.last?.text == "Native text\n图上直接编辑", canvas.annotations.last?.bold == true else { throw failure("Inline accept did not commit styled text") }
        _ = try unwrap(canvas.flattened(), "Cannot flatten native editor fixture")
        let more = try unwrap(descendants(light.window?.contentView).first { $0.identifier?.rawValue == "editor.more" } as? NSPopUpButton, "Missing native overflow menu")
        let saveItem = try unwrap(more.menu?.items.first { $0.title == "保存到历史" }, "Missing native save callback action")
        guard let action = saveItem.action, NSApp.sendAction(action, to: saveItem.target, from: saveItem),
              saveCallbacks == 1, FileManager.default.fileExists(atPath: evidenceDirectory.appendingPathComponent("ui-synthetic-edited-result.png").path) else {
            throw failure("Native save callback did not export the synthetic edited fixture")
        }
        let resizeEvidence = try await verifyBoundaryResize(light, presentation: presentation, evidenceDirectory: evidenceDirectory)
        light.close()

        NSApp.appearance = NSAppearance(named: .darkAqua)
        let dark = editor(captured)
        try click("editor.tool.rectangle", in: dark)
        try drag(dark.annotationCanvas, from: CGPoint(x: CGFloat(captured.image.width) * 0.06, y: CGFloat(captured.image.height) * 0.78),
                 to: CGPoint(x: CGFloat(captured.image.width) * 0.72, y: CGFloat(captured.image.height) * 0.97))
        try await settle(dark.window)
        try checkPlacement(dark, presentation: presentation); try checkControls(dark)
        guard dark.floatingSurfaceIsDark else { throw failure("Dark appearance did not reach native floating surfaces") }
        try snapshot(dark.window, to: evidenceDirectory.appendingPathComponent("ui-capture-rectangle-dark.png"))
        dark.close()

        NSApp.appearance = NSAppearance(named: .aqua)
        let edgeCapture = try CapturedImage.frozenRegion(image: desktop, displayID: displayID, displayFrame: screen.frame,
            selection: CGRect(x: points.width * 0.62, y: points.height * 0.71, width: points.width * 0.34, height: points.height * 0.25))
        let edge = editor(edgeCapture)
        try click("editor.tool.rectangle", in: edge)
        try await settle(edge.window)
        try checkPlacement(edge, presentation: try unwrap(edgeCapture.presentation, "Missing edge placement")); try checkControls(edge)
        guard edge.floatingToolbarFrame.minY > edge.editorSelectionFrame.maxY else { throw failure("Bottom-edge toolbar did not flip above selection") }
        try snapshot(edge.window, to: evidenceDirectory.appendingPathComponent("ui-capture-edge.png"))
        edge.close()

        // Output actions below invoke the exact native editor buttons and callback
        // plumbing. OCR receives labeled fixture text, never a recognition claim.
        let pinSource = editor(captured)
        try click("editor.pin", in: pinSource)
        guard let pinWindow = pins.last?.window, pinCallbacks == 1 else { throw failure("Pin action did not open a native image pin") }
        try await settle(pinWindow)
        try snapshot(pinWindow, to: evidenceDirectory.appendingPathComponent("ui-pin-image-only.png"))
        let pinController = try unwrap(pins.last, "Missing native pin controller")
        let pinImageBefore = pinController.currentImage
        let pinStateBefore = pinController.presentation
        let pinAnchor = try unwrap(pinController.annotationPresentation, "Pin has no exact annotation geometry")
        let pinCanvas = try unwrap(descendants(pinWindow.contentView).compactMap { $0 as? NSScrollView }.first?.documentView,
                                   "Pin has no native canvas for its Space handler")
        pinWindow.makeFirstResponder(pinCanvas)
        pinCanvas.keyDown(with: try key(pinCanvas, code: 49, value: " "))
        let pinEditor = try unwrap(pinController.annotationEditor, "Space did not open the pin annotation surface")
        guard !pinWindow.isVisible, pinEditor.window?.isVisible == true,
              pinEditor.window?.styleMask.contains(.titled) == false,
              pinEditor.captureBoundaryWorkspace.frozenImage == nil,
              sameFrame(pinEditor.editorImageScreenFrame, pinAnchor.imageFrame),
              sameFrame(pinEditor.pinnedViewportScreenFrame, pinAnchor.viewportFrame) else {
            throw failure("Space editor did not preserve the real pin anchor")
        }
        try click("editor.tool.rectangle", in: pinEditor)
        try drag(pinEditor.annotationCanvas,
                 from: CGPoint(x: CGFloat(pinImageBefore.width) * 0.045, y: CGFloat(pinImageBefore.height) * 0.78),
                 to: CGPoint(x: CGFloat(pinImageBefore.width) * 0.72, y: CGFloat(pinImageBefore.height) * 0.97))
        guard pinEditor.annotationCanvas.annotations.count == 1 else { throw failure("Anchored pin editor did not accept native drawing") }
        try await settle(pinEditor.window)
        try snapshot(pinEditor.window, to: evidenceDirectory.appendingPathComponent("ui-pin-annotation.png"))
        try click("editor.cancel", in: pinEditor)
        guard pinController.annotationEditor == nil, pinWindow.isVisible,
              pinController.currentImage === pinImageBefore, pinController.presentation == pinStateBefore else {
            throw failure("Cancelling the anchored editor changed or hid the original pin")
        }
        pins.last?.close()
        let ocrSource = editor(captured)
        try click("editor.ocr", in: ocrSource)
        guard let resultWindow = results.last?.window, ocrCallbacks == 1 else { throw failure("OCR result callback did not open its native panel") }
        try await settle(resultWindow)
        try snapshot(resultWindow, to: evidenceDirectory.appendingPathComponent("ui-ocr-result.png"))
        let priorResultAppearance = resultWindow.appearance
        let originalResultText = results.last?.resultText
        resultWindow.appearance = NSAppearance(named: .darkAqua)
        try await settle(resultWindow)
        guard resultWindow.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
              results.last?.resultText == originalResultText else { throw failure("Dark OCR fixture changed its text or ignored appearance") }
        try snapshot(resultWindow, to: evidenceDirectory.appendingPathComponent("ui-ocr-result-dark.png"))
        resultWindow.appearance = priorResultAppearance
        results.last?.close()

        return ["status": "passed", "scope": "Native AppKit editor/pin/text-result rendering on a labeled synthetic desktop; no screen pixels, TCC, OCR inference, network, or preference writes",
                "syntheticDesktop": true, "screenCaptureAttempted": false, "ocrInferenceAttempted": false,
                "displaySetup": displaySetup,
                "displayPointWidth": points.width, "displayPointHeight": points.height,
                "backingScale": screen.backingScaleFactor, "sourcePixelWidth": desktop.width, "sourcePixelHeight": desktop.height,
                "rectangleGesture": true, "inlineCancel": true, "inlineCommit": true, "appearanceRestoredOnExit": true,
                "edgeClamping": true, "nativePinCallbackCount": pinCallbacks, "nativeOCRCallbackCount": ocrCallbacks,
                "saveCallbackCount": saveCallbacks, "captureResizeEvidence": resizeEvidence,
                "pinSpaceAnchoredEditing": true, "pinAnnotationCancelPreservedImageAndPresentation": true,
                "ocrDarkAppearance": true,
                "files": ["ui-capture-rectangle-light.png", "ui-capture-text-light.png", "ui-capture-rectangle-dark.png", "ui-capture-edge.png", "ui-pin-image-only.png", "ui-ocr-result.png", "ui-capture-resized.png", "ui-pin-annotation.png", "ui-ocr-result-dark.png"]]
    }

    /// Smoke launches are regular applications and may still be receiving Dock /
    /// display-layout events. Establish bounded quiet BEFORE freezing geometry.
    /// Once an editor exists its real display-change cancellation stays active;
    /// this setup never retries or skips a failed control assertion.
    static func waitForDisplayGeometryQuiet(quietInterval: TimeInterval = 0.4,
                                           timeout: TimeInterval = 3) async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let state = DisplaySetupState(started: started)
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    state.notifications += 1; state.lastChange = ProcessInfo.processInfo.systemUptime
                }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        var previous = displayGeometrySignature()
        var geometryChanges = 0, samples = 0
        while true {
            try Task.checkCancellation()
            let geometry = displayGeometrySignature()
            let now = ProcessInfo.processInfo.systemUptime
            samples += 1
            if geometry != previous { geometryChanges += 1; previous = geometry; state.lastChange = now }
            if now - state.lastChange >= quietInterval {
                return ["quietIntervalSeconds": quietInterval, "elapsedSeconds": now - started,
                        "notifications": state.notifications, "geometryChanges": geometryChanges, "geometrySamples": samples]
            }
            guard now - started < timeout else {
                throw failure("Display geometry did not settle before synthetic capture (notifications=\(state.notifications), geometryChanges=\(geometryChanges), samples=\(samples))")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private final class DisplaySetupState {
        var lastChange: TimeInterval
        var notifications = 0
        init(started: TimeInterval) { lastChange = started }
    }
    private static func displayGeometrySignature() -> [String] {
        NSScreen.screens.map {
            "\($0.displayID ?? 0):\(NSStringFromRect($0.frame)):\(NSStringFromRect($0.visibleFrame)):\($0.backingScaleFactor)"
        }.sorted()
    }

    private static func verifyBoundaryResize(_ editor: ImageEditorController, presentation: FrozenCapturePresentation,
                                             evidenceDirectory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas, workspace = editor.captureBoundaryWorkspace
        let originalImage = canvas.image, originalFrame = editor.editorSelectionFrame, originalAnnotations = canvas.annotations
        guard !originalAnnotations.isEmpty else { throw failure("Resize fixture needs existing editable annotations") }
        try click("editor.tool.rectangle", in: editor)
        let start = EditorBoundaryHandle.left.point(in: originalFrame)
        let distance = min(32, originalFrame.minX / 2)
        guard distance >= 2 else { throw failure("Synthetic selection has no resize margin") }
        let target = CGPoint(x: start.x - distance, y: start.y)
        let requested = EditorBoundaryHandle.left.resized(originalFrame, to: target, in: workspace.bounds)
        let expectedFrame = try EditorBoundaryRenderer.alignedFrame(requested, presentation: presentation)
        let hit = workspace.hitTest(workspace.convert(start, to: workspace.superview))
        guard hit === workspace else { throw failure("Visible capture boundary handle failed native hit testing") }
        workspace.mouseDown(with: try pointer(workspace, type: .leftMouseDown, point: start))
        for step in 1...4 {
            let point = CGPoint(x: start.x - distance * CGFloat(step) / 4, y: start.y)
            workspace.mouseDragged(with: try pointer(workspace, type: .leftMouseDragged, point: point))
            guard canvas.image === originalImage, sameAnnotations(canvas.annotations, originalAnnotations),
                  canvas.isHidden, workspace.boundaryPreviewImage != nil else {
                throw failure("Resize preview materialized a new raster or changed the model during mouse motion")
            }
        }
        workspace.mouseUp(with: try pointer(workspace, type: .leftMouseUp, point: target))
        let resizedImage = canvas.image
        let expectedWidth = Int((expectedFrame.width * CGFloat(presentation.frozenImage.width) / presentation.displayFrame.width).rounded())
        let expectedHeight = Int((expectedFrame.height * CGFloat(presentation.frozenImage.height) / presentation.displayFrame.height).rounded())
        let offset = EditorBoundaryRenderer.annotationOffset(from: originalFrame, to: expectedFrame, presentation: presentation)
        let translated = originalAnnotations.map { $0.translated(by: offset) }
        guard !(resizedImage === originalImage), sameFrame(editor.editorSelectionFrame, expectedFrame),
              resizedImage.width == expectedWidth, resizedImage.height == expectedHeight,
              resizedImage.bytesPerRow == expectedWidth * 4,
              CFDataGetLength(try unwrap(resizedImage.dataProvider?.data, "Resized image has no pixel provider")) == expectedWidth * expectedHeight * 4,
              sameAnnotations(canvas.annotations, translated), !canvas.isHidden, workspace.boundaryPreviewImage == nil else {
            throw failure("Committed native boundary resize did not produce an independent pixel-aligned crop")
        }
        try click("editor.undo", in: editor)
        guard canvas.image === originalImage, sameFrame(editor.editorSelectionFrame, originalFrame),
              sameAnnotations(canvas.annotations, originalAnnotations) else { throw failure("Resize undo did not restore original pixels and placement") }
        // A second undo must reach the preceding text edit, not a mouse-move
        // snapshot. Redo the text and leave the resize itself available to redo.
        try click("editor.undo", in: editor)
        guard canvas.annotations.count == originalAnnotations.count - 1 else { throw failure("A single resize gesture added multiple undo states") }
        try click("editor.redo", in: editor)
        guard sameAnnotations(canvas.annotations, originalAnnotations) else { throw failure("Pre-resize text redo failed") }
        let cancelStart = EditorBoundaryHandle.bottom.point(in: editor.editorSelectionFrame)
        let cancelTarget = CGPoint(x: cancelStart.x, y: cancelStart.y - min(18, cancelStart.y / 2))
        workspace.mouseDown(with: try pointer(workspace, type: .leftMouseDown, point: cancelStart))
        workspace.mouseDragged(with: try pointer(workspace, type: .leftMouseDragged, point: cancelTarget))
        workspace.keyDown(with: try key(workspace, code: 53, value: "\u{1b}"))
        workspace.mouseUp(with: try pointer(workspace, type: .leftMouseUp, point: cancelTarget))
        guard canvas.image === originalImage, sameFrame(editor.editorSelectionFrame, originalFrame),
              sameAnnotations(canvas.annotations, originalAnnotations), !canvas.isHidden,
              !workspace.isResizingBoundary, workspace.boundaryPreviewImage == nil,
              editor.window?.isVisible == true else { throw failure("Escape did not cancel only the boundary gesture") }
        try click("editor.redo", in: editor)
        guard canvas.image === resizedImage, sameFrame(editor.editorSelectionFrame, expectedFrame),
              sameAnnotations(canvas.annotations, translated) else { throw failure("Cancelled boundary resize consumed the redo branch") }
        try await settle(editor.window); try checkControls(editor)
        try snapshot(editor.window, to: evidenceDirectory.appendingPathComponent("ui-capture-resized.png"))
        return ["nativeHandleHitTest": true, "dragPreviewReusesRaster": true, "independentPixelAlignedCommit": true,
                "annotationPlacementPreserved": true, "oneUndoStatePerGesture": true,
                "escapeRestoresWithoutConsumingRedo": true, "pixelWidth": expectedWidth, "pixelHeight": expectedHeight,
                "previewMouseMoves": 4, "selectionFrame": [expectedFrame.minX, expectedFrame.minY, expectedFrame.width, expectedFrame.height]]
    }
    private static func sameFrame(_ actual: CGRect?, _ expected: CGRect) -> Bool {
        guard let actual else { return false }
        return abs(actual.minX - expected.minX) < 0.01 && abs(actual.minY - expected.minY) < 0.01 &&
               abs(actual.width - expected.width) < 0.01 && abs(actual.height - expected.height) < 0.01
    }
    private static func sameAnnotations(_ actual: [ImageAnnotation], _ expected: [ImageAnnotation]) -> Bool {
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { pair in
            pair.0.id == pair.1.id && pair.0.tool == pair.1.tool && pair.0.points == pair.1.points &&
            pair.0.rotation == pair.1.rotation && pair.0.text == pair.1.text
        }
    }
    private static func pointer(_ view: NSView, type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Cannot make boundary pointer input")
    }

    private static func checkPlacement(_ editor: ImageEditorController, presentation: FrozenCapturePresentation) throws {
        guard editor.window?.frame == presentation.displayFrame,
              editor.editorSelectionFrame == presentation.selectionFrame,
              editor.annotationCanvas.frame == presentation.selectionFrame else { throw failure("Editor moved genuine crop placement") }
    }
    private static func checkControls(_ editor: ImageEditorController) throws {
        let bounds = try unwrap(editor.window?.contentView?.bounds, "No editor content")
        guard editor.floatingToolbarFrame.height == 40,
              bounds.insetBy(dx: -0.5, dy: -0.5).contains(editor.floatingToolbarFrame),
              editor.contextualPaletteVisible,
              !editor.floatingToolbarFrame.intersects(editor.contextualPaletteFrame),
              !editor.dimensionLabelFrame.intersects(editor.floatingToolbarFrame),
              !editor.dimensionLabelFrame.intersects(editor.contextualPaletteFrame),
              bounds.insetBy(dx: -0.5, dy: -0.5).contains(editor.contextualPaletteFrame) else { throw failure("Floating native controls extend beyond the display") }
        for id in ["editor.tool.rectangle", "editor.tool.text", "editor.ocr", "editor.pin", "editor.save", "editor.cancel", "editor.copy", "annotation.swatch.0"] {
            let control = try button(id, in: editor)
            guard control.isEnabled, !control.isHiddenOrHasHiddenAncestor, control.target != nil, control.action != nil else { throw failure("Unreachable native control: \(id)") }
        }
    }
    private static func settle(_ window: NSWindow?) async throws {
        window?.contentView?.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 180_000_000)
        window?.contentView?.layoutSubtreeIfNeeded(); window?.displayIfNeeded()
    }
    private static func snapshot(_ window: NSWindow?, to url: URL) throws {
        guard let window, let view = window.contentView else { throw failure("Missing native window for \(url.lastPathComponent)") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Native bitmap unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage, image.width > 0, image.height > 0 else { throw failure("Empty native bitmap") }
        // Titled AppKit content views can leave their system background outside
        // cacheDisplay's alpha. Resolve and composite that native background for
        // evidence; genuinely transparent pin/editor windows retain their alpha.
        if window.isOpaque || window.styleMask.contains(.titled) {
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Native background composite unavailable") }
            window.effectiveAppearance.performAsCurrentDrawingAppearance { context.setFillColor(window.backgroundColor.cgColor) }
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            try unwrap(context.makeImage(), "Native background composite is empty").writePNG(to: url)
        } else { try image.writePNG(to: url) }
    }
    private static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    private static func button(_ id: String, in editor: ImageEditorController) throws -> NSButton {
        if let control = descendants(editor.window?.contentView).first(where: { $0.identifier?.rawValue == id }) as? NSButton { return control }
        let data = (try? JSONSerialization.data(withJSONObject: editor.nativeToolbarDiagnostics(), options: [.sortedKeys])) ?? Data()
        let diagnostic = String(decoding: data.prefix(16_384), as: UTF8.self)
        throw failure("Missing native control \(id); bounded native hierarchy: \(diagnostic)")
    }
    private static func click(_ id: String, in editor: ImageEditorController) throws { try button(id, in: editor).performClick(nil) }
    private static func mouse(_ canvas: ImageEditorCanvas, type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
        let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil)
        return try unwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Cannot make native pointer input")
    }
    private static func canvasClick(_ canvas: ImageEditorCanvas, at point: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, type: .leftMouseDown, point: point))
        canvas.mouseUp(with: try mouse(canvas, type: .leftMouseUp, point: point))
    }
    private static func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, type: .leftMouseDown, point: start))
        canvas.mouseDragged(with: try mouse(canvas, type: .leftMouseDragged, point: end))
        canvas.mouseUp(with: try mouse(canvas, type: .leftMouseUp, point: end))
    }
    private static func key(_ canvas: NSView, code: UInt16, value: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: value,
            charactersIgnoringModifiers: value, isARepeat: false, keyCode: code), "Cannot make native keyboard input")
    }
    private static func syntheticDesktop(screen: NSScreen) throws -> CGImage {
        let size = screen.frame.size, scale = screen.backingScaleFactor
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, Int64(width) * Int64(height) <= 64_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Synthetic desktop exceeds raster bounds") }
        context.scaleBy(x: scale, y: scale)
        fill(context, CGRect(origin: .zero, size: size), color: CGColor(srgbRed: 0.12, green: 0.20, blue: 0.27, alpha: 1))
        fill(context, CGRect(x: 0, y: size.height - 32, width: size.width, height: 32), color: CGColor(srgbRed: 0.08, green: 0.13, blue: 0.18, alpha: 1))
        text("PicShot    Synthetic desktop preview", at: CGPoint(x: 24, y: size.height - 23), size: 13, color: CGColor(gray: 1, alpha: 1), context: context)
        text("ORIGINAL FIXTURE • NO DESKTOP PIXELS CAPTURED", at: CGPoint(x: 24, y: 35), size: 13, color: CGColor(gray: 0.87, alpha: 1), context: context)
        let paper = CGRect(x: size.width * 0.07, y: size.height * 0.15, width: size.width * 0.86, height: size.height * 0.72)
        fill(context, paper, color: CGColor(srgbRed: 0.965, green: 0.972, blue: 0.985, alpha: 1))
        let left = size.width * 0.15, top = size.height * 0.75
        text("A little clarity, wherever you work.", at: CGPoint(x: left, y: top), size: max(22, size.width * 0.029), color: CGColor(srgbRed: 0.10, green: 0.15, blue: 0.22, alpha: 1), context: context, bold: true)
        text("Capture a detail. Add a note. Keep it in view.", at: CGPoint(x: left, y: top - 36), size: 18, color: CGColor(srgbRed: 0.32, green: 0.39, blue: 0.46, alpha: 1), context: context)
        let cardY = size.height * 0.31, cardHeight = size.height * 0.27, gap = size.width * 0.024, cardWidth = size.width * 0.215
        let colors = [CGColor(srgbRed: 0.20, green: 0.68, blue: 0.72, alpha: 1), CGColor(srgbRed: 0.99, green: 0.70, blue: 0.30, alpha: 1), CGColor(srgbRed: 0.58, green: 0.52, blue: 0.88, alpha: 1)]
        for index in 0..<3 {
            let x = left + CGFloat(index) * (cardWidth + gap)
            let card = CGRect(x: x, y: cardY, width: cardWidth, height: cardHeight)
            fill(context, card, color: .init(gray: 1, alpha: 1))
            let art = CGRect(x: x + 14, y: cardY + cardHeight * 0.30, width: cardWidth - 28, height: cardHeight * 0.60)
            fill(context, art, color: colors[index])
            context.setFillColor(CGColor(gray: 1, alpha: 0.8)); context.fillEllipse(in: art.insetBy(dx: art.width * 0.27, dy: art.height * 0.16))
            text(["Capture", "Annotate", "Keep nearby"][index], at: CGPoint(x: x + 16, y: cardY + 20), size: 18, color: CGColor(srgbRed: 0.12, green: 0.18, blue: 0.26, alpha: 1), context: context, bold: true)
        }
        return try unwrap(context.makeImage(), "Cannot materialize synthetic desktop")
    }
    private static func fill(_ context: CGContext, _ rect: CGRect, color: CGColor) { context.setFillColor(color); context.fill(rect) }
    private static func text(_ string: String, at point: CGPoint, size: CGFloat, color: CGColor, context: CGContext, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        context.textMatrix = .identity; context.textPosition = point; CTLineDraw(line, context)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Native capture UI preview: \(message)") }
}
