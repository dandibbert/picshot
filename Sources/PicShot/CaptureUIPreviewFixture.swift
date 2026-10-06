import AppKit
import CoreGraphics
import CoreText

/// Native UI evidence on an original, explicitly labeled synthetic desktop.
/// Never requests screen permission, reads desktop pixels, runs OCR, or changes
/// preferences. This verifies presentation and editing, not screen capture/TCC.
@MainActor
enum CaptureUIPreviewFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
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
        try drag(canvas, from: CGPoint(x: CGFloat(canvas.image.width) * 0.045, y: CGFloat(canvas.image.height) * 0.70),
                 to: CGPoint(x: CGFloat(canvas.image.width) * 0.72, y: CGFloat(canvas.image.height) * 0.91))
        guard canvas.annotations.count == 1, canvas.annotations[0].tool == .rectangle else { throw failure("Native rectangle gesture did not create its model annotation") }
        try click("editor.tool.arrow", in: light)
        try drag(canvas, from: CGPoint(x: CGFloat(canvas.image.width) * 0.63, y: CGFloat(canvas.image.height) * 0.28),
                 to: CGPoint(x: CGFloat(canvas.image.width) * 0.79, y: CGFloat(canvas.image.height) * 0.54))
        try click("editor.tool.rectangle", in: light)
        try await settle(light.window)
        try checkControls(light)
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
        input.insertText("Native text\n图上直接编辑", replacementRange: NSRange(location: 0, length: 0))
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
        light.close()

        NSApp.appearance = NSAppearance(named: .darkAqua)
        let dark = editor(captured)
        try click("editor.tool.rectangle", in: dark)
        try drag(dark.annotationCanvas, from: CGPoint(x: CGFloat(captured.image.width) * 0.06, y: CGFloat(captured.image.height) * 0.70),
                 to: CGPoint(x: CGFloat(captured.image.width) * 0.72, y: CGFloat(captured.image.height) * 0.90))
        try await settle(dark.window)
        try checkPlacement(dark, presentation: presentation); try checkControls(dark)
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
        pins.last?.close()
        let ocrSource = editor(captured)
        try click("editor.ocr", in: ocrSource)
        guard let resultWindow = results.last?.window, ocrCallbacks == 1 else { throw failure("OCR result callback did not open its native panel") }
        try await settle(resultWindow)
        try snapshot(resultWindow, to: evidenceDirectory.appendingPathComponent("ui-ocr-result.png"))
        results.last?.close()

        return ["status": "passed", "scope": "Native AppKit editor/pin/text-result rendering on a labeled synthetic desktop; no screen pixels, TCC, OCR inference, network, or preference writes",
                "syntheticDesktop": true, "screenCaptureAttempted": false, "ocrInferenceAttempted": false,
                "displayPointWidth": points.width, "displayPointHeight": points.height,
                "backingScale": screen.backingScaleFactor, "sourcePixelWidth": desktop.width, "sourcePixelHeight": desktop.height,
                "rectangleGesture": true, "inlineCancel": true, "inlineCommit": true, "appearanceRestoredOnExit": true,
                "edgeClamping": true, "nativePinCallbackCount": pinCallbacks, "nativeOCRCallbackCount": ocrCallbacks,
                "saveCallbackCount": saveCallbacks,
                "files": ["ui-capture-rectangle-light.png", "ui-capture-text-light.png", "ui-capture-rectangle-dark.png", "ui-capture-edge.png", "ui-pin-image-only.png", "ui-ocr-result.png"]]
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
        try image.writePNG(to: url)
    }
    private static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    private static func button(_ id: String, in editor: ImageEditorController) throws -> NSButton {
        try unwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == id } as? NSButton, "Missing native control \(id)")
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
    private static func key(_ canvas: ImageEditorCanvas, code: UInt16, value: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
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
