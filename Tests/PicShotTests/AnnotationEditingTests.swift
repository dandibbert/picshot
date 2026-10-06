import XCTest
import AppKit
import CoreGraphics
@testable import PicShot

final class AnnotationEditingTests: XCTestCase {
    func testRotatedCornerResizeKeepsOppositeCornerFixed() throws {
        var annotation = rectangle(CGRect(x: 40, y: 40, width: 80, height: 40))
        annotation.rotation = .pi / 6
        let corner = CGPoint(x: 120, y: 80).applying(annotation.transform)
        let anchor = CGPoint(x: 40, y: 40).applying(annotation.transform)
        let target = CGPoint(x: 160, y: 110).applying(annotation.transform)
        let edited = annotation.edited(handle: .corner(2), from: corner, to: target, shift: false)
        let movedAnchor = CGPoint(x: edited.localBounds.minX, y: edited.localBounds.minY).applying(edited.transform)
        XCTAssertEqual(edited.id, annotation.id)
        XCTAssertEqual(edited.rotation, annotation.rotation)
        XCTAssertEqual(edited.localBounds.width, 120, accuracy: 0.001)
        XCTAssertEqual(edited.localBounds.height, 70, accuracy: 0.001)
        XCTAssertEqual(movedAnchor.x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(movedAnchor.y, anchor.y, accuracy: 0.001)
    }

    func testShiftCornerResizePreservesAspectAndCannotInvert() {
        let annotation = rectangle(CGRect(x: 20, y: 20, width: 100, height: 50))
        let resized = annotation.edited(handle: .corner(2), from: CGPoint(x: 120, y: 70), to: CGPoint(x: 180, y: 140), shift: true)
        XCTAssertEqual(resized.localBounds.width / resized.localBounds.height, 2, accuracy: 0.001)
        let crossed = annotation.edited(handle: .corner(2), from: CGPoint(x: 120, y: 70), to: CGPoint(x: 0, y: 0), shift: false)
        XCTAssertEqual(crossed.localBounds.minX, 20); XCTAssertEqual(crossed.localBounds.minY, 20)
        XCTAssertGreaterThanOrEqual(crossed.localBounds.width, 2); XCTAssertGreaterThanOrEqual(crossed.localBounds.height, 2)
    }

    func testRotatedEndpointDragKeepsOppositeEndpointFixedAndSnaps() throws {
        var annotation = ImageAnnotation(tool: .arrow, points: [CGPoint(x: 40, y: 60), CGPoint(x: 140, y: 60)])
        annotation.rotation = .pi / 2
        let start = try XCTUnwrap(annotation.points.first).applying(annotation.transform)
        let end = try XCTUnwrap(annotation.points.last).applying(annotation.transform)
        let edited = annotation.edited(handle: .end, from: end, to: CGPoint(x: 160, y: 130), shift: true)
        XCTAssertEqual(edited.rotation, 0)
        XCTAssertEqual(edited.points.first, start)
        let moved = try XCTUnwrap(edited.points.last)
        XCTAssertEqual(abs(moved.x - start.x), abs(moved.y - start.y), accuracy: 0.001)
    }

    func testHitTestingUsesActualStrokeAndInverseRotation() {
        let line = ImageAnnotation(tool: .line, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 110)], lineWidth: 2)
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 51), tolerance: 2))
        XCTAssertFalse(line.hitTest(CGPoint(x: 15, y: 100), tolerance: 2))
        var shape = rectangle(CGRect(x: 60, y: 90, width: 80, height: 20))
        shape.rotation = .pi / 2
        XCTAssertTrue(shape.hitTest(CGPoint(x: 100, y: 130), tolerance: 1))
        XCTAssertFalse(shape.hitTest(CGPoint(x: 130, y: 100), tolerance: 1))
        let arrow = ImageAnnotation(tool: .arrow, points: [CGPoint(x: 10, y: 50), CGPoint(x: 100, y: 50)], lineWidth: 6)
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 80, y: 61), tolerance: 2), "The arrowhead is selectable too")
    }

    func testRotatedFillRasterMatchesImageSpaceGeometry() throws {
        let image = try blankImage(width: 200, height: 200)
        var shape = rectangle(CGRect(x: 60, y: 90, width: 80, height: 20))
        shape.fillEnabled = true; shape.fillColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        shape.rotation = .pi / 2
        let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [shape]))
        XCTAssertEqual(try pixel(result, x: 100, y: 130), [0, 0, 255, 255])
        XCTAssertEqual(try pixel(result, x: 130, y: 100), [255, 255, 255, 255])
        XCTAssertEqual(shape.bounds.minX, 90, accuracy: 0.001)
        XCTAssertEqual(shape.bounds.minY, 60, accuracy: 0.001)
    }

    func testRoundedFillAndOpacityHaveExactInteriorPixels() throws {
        let image = try blankImage(width: 120, height: 120)
        var shape = rectangle(CGRect(x: 20, y: 20, width: 80, height: 80))
        shape.color = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        shape.fillColor = shape.color; shape.fillEnabled = true; shape.cornerRadius = 25; shape.opacity = 0.5
        let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [shape]))
        let center = try pixel(result, x: 60, y: 60)
        XCTAssertLessThanOrEqual(abs(Int(center[0]) - 127), 1)
        XCTAssertLessThanOrEqual(abs(Int(center[1]) - 127), 1)
        XCTAssertEqual(center[2], 255)
        XCTAssertEqual(try pixel(result, x: 22, y: 22), [255, 255, 255, 255])
    }

    func testDashedAndDottedStrokeRasterActuallyContainsGaps() throws {
        let image = try blankImage(width: 180, height: 100)
        for style in [AnnotationStrokeStyle.dashed, .dotted] {
            var line = ImageAnnotation(tool: .line, points: [CGPoint(x: 10, y: 50), CGPoint(x: 170, y: 50)], color: CGColor(gray: 0, alpha: 1), lineWidth: 3)
            line.strokeStyle = style
            let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [line]))
            var dark = 0, white = 0
            for x in 20..<160 {
                let value = try pixel(result, x: x, y: 50)[0]
                if value < 40 { dark += 1 }; if value > 240 { white += 1 }
            }
            XCTAssertGreaterThan(dark, 20, "\(style) must draw visible ink")
            XCTAssertGreaterThan(white, 10, "\(style) must not silently render as a solid line")
        }
    }

    func testTransformedRedactionIgnoresOpacityAndTransparentStyle() throws {
        let image = try blankImage(width: 200, height: 200)
        var redaction = ImageAnnotation(tool: .redact, points: [CGPoint(x: 60, y: 90), CGPoint(x: 140, y: 110)], color: CGColor(gray: 0, alpha: 0.01))
        redaction.rotation = .pi / 2; redaction.opacity = 0; redaction.cornerRadius = 20; redaction.strokeStyle = .dotted
        let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [redaction]))
        XCTAssertEqual(try pixel(result, x: 100, y: 130), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(result, x: 130, y: 100), [255, 255, 255, 255])
    }

    func testMultilineAndWrappedTextProduceInkOnSeparateLinesWithBackground() throws {
        let image = try blankImage(width: 240, height: 180)
        var text = ImageAnnotation(tool: .text, points: [CGPoint(x: 20, y: 20)], color: CGColor(gray: 0, alpha: 1), text: "FIRST\nSECOND")
        text.fontSize = 26; text.bold = true; text.italic = true; text.underline = true
        text.textBoxSize = CGSize(width: 180, height: 80)
        text.fillEnabled = true; text.fillColor = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [text]))
        XCTAssertEqual(try pixel(result, x: 22, y: 22), [255, 255, 0, 255])
        XCTAssertGreaterThan(try darkPixels(result, in: CGRect(x: 24, y: 60, width: 170, height: 36)), 60)
        XCTAssertGreaterThan(try darkPixels(result, in: CGRect(x: 24, y: 24, width: 170, height: 36)), 60)
        text.text = "one two three four five six seven eight"
        text.textBoxSize = CGSize(width: 90, height: 140); text.fontSize = 20; text.fillEnabled = false
        let wrapped = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [text]))
        XCTAssertGreaterThan(try darkPixels(wrapped, in: CGRect(x: 20, y: 95, width: 90, height: 65)), 40)
        XCTAssertGreaterThan(try darkPixels(wrapped, in: CGRect(x: 20, y: 25, width: 90, height: 65)), 40)
        XCTAssertEqual(try darkPixels(wrapped, in: CGRect(x: 112, y: 20, width: 100, height: 140)), 0, "Text is clipped to the editable wrapping box")
    }

    func testRotatedTextBackgroundAndBoundsStayAligned() throws {
        let image = try blankImage(width: 240, height: 240)
        var text = ImageAnnotation(tool: .text, points: [CGPoint(x: 60, y: 90)], color: CGColor(gray: 0, alpha: 1), text: "Hi")
        text.textBoxSize = CGSize(width: 120, height: 40); text.rotation = .pi / 2
        text.fillEnabled = true; text.fillColor = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [text]))
        XCTAssertEqual(text.bounds.width, 40, accuracy: 0.001); XCTAssertEqual(text.bounds.height, 120, accuracy: 0.001)
        XCTAssertEqual(try pixel(result, x: 120, y: 160), [255, 255, 0, 255])
        XCTAssertEqual(try pixel(result, x: 170, y: 110), [255, 255, 255, 255])
        XCTAssertTrue(text.hitTest(CGPoint(x: 120, y: 160), tolerance: 1))
    }

    @MainActor
    func testNativeZoomedResizeRotationDuplicateAndRepeatedUndoRedo() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.zoom = 2
            canvas.tool = .rectangle
            try drag(canvas, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 140, y: 100))
            let identifier = try XCTUnwrap(canvas.annotations.first?.id)
            canvas.tool = .select
            try drag(canvas, from: CGPoint(x: 140, y: 100), to: CGPoint(x: 180, y: 130))
            XCTAssertEqual(canvas.annotations[0].localBounds, CGRect(x: 40, y: 40, width: 140, height: 90))
            let annotation = canvas.annotations[0]
            let rotate = try XCTUnwrap(annotation.handles(zoom: canvas.zoom).first { $0.0 == .rotation }?.1)
            let center = CGPoint(x: annotation.localBounds.midX, y: annotation.localBounds.midY)
            let radius = rotate.y - center.y
            try drag(canvas, from: rotate, to: CGPoint(x: center.x - radius, y: center.y), modifiers: .shift)
            XCTAssertEqual(canvas.annotations[0].rotation, .pi / 2, accuracy: 0.001)
            try command(canvas, "d", code: 2)
            XCTAssertEqual(canvas.annotations.count, 2)
            XCTAssertNotEqual(canvas.annotations[1].id, identifier)
            XCTAssertEqual(canvas.annotations[1].rotation, .pi / 2, accuracy: 0.001)
            let completed = try XCTUnwrap(canvas.flattened())
            let completedBytes = try imageBytes(completed)
            for _ in 0..<3 {
                for _ in 0..<4 { try command(canvas, "z", code: 6) }
                XCTAssertTrue(canvas.annotations.isEmpty)
                for _ in 0..<4 { try command(canvas, "z", code: 6, shift: true) }
                XCTAssertEqual(canvas.annotations.count, 2)
                XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), completedBytes)
            }
        }
    }

    @MainActor
    func testNativeLineEndpointGestureAndNudgeUseImagePixels() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.zoom = 0.5; canvas.tool = .arrow
            try drag(canvas, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 180, y: 100))
            canvas.tool = .select
            try drag(canvas, from: CGPoint(x: 180, y: 100), to: CGPoint(x: 200, y: 150))
            XCTAssertEqual(canvas.annotations[0].points, [CGPoint(x: 40, y: 40), CGPoint(x: 200, y: 150)])
            canvas.keyDown(with: try key(canvas, "", code: 124, modifiers: .shift))
            XCTAssertEqual(canvas.annotations[0].points, [CGPoint(x: 50, y: 40), CGPoint(x: 210, y: 150)])
            try command(canvas, "z", code: 6); try command(canvas, "z", code: 6)
            XCTAssertEqual(canvas.annotations[0].points, [CGPoint(x: 40, y: 40), CGPoint(x: 180, y: 100)])
        }
    }

    @MainActor
    func testNativeEscapeCancelsTransformWithoutUndoEntryAndKeepsRedo() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.tool = .rectangle
            try drag(canvas, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 130, y: 100))
            canvas.tool = .select
            try command(canvas, "d", code: 2); try command(canvas, "z", code: 6)
            try click(canvas, CGPoint(x: 60, y: 60))
            let original = canvas.annotations[0].localBounds
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 130, y: 100)))
            canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: 200, y: 140)))
            XCTAssertNotEqual(canvas.annotations[0].localBounds, original)
            canvas.keyDown(with: try key(canvas, "\u{1b}", code: 53))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 200, y: 140)))
            XCTAssertEqual(canvas.annotations[0].localBounds, original)
            try command(canvas, "z", code: 6, shift: true)
            XCTAssertEqual(canvas.annotations.count, 2, "Escape must not consume the existing redo branch")
            try command(canvas, "z", code: 6); try command(canvas, "z", code: 6)
            XCTAssertTrue(canvas.annotations.isEmpty)
        }
    }

    @MainActor
    func testNativeInspectorFillStyleOpacityAndFontChangesAreUndoable() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.tool = .rectangle
            try drag(canvas, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 140, y: 120))
            canvas.tool = .select; try click(canvas, CGPoint(x: 60, y: 60))
            let fill: NSButton = try control("annotation.fill", editor); fill.performClick(nil)
            let details: NSButton = try control("annotation.details", editor); details.performClick(nil)
            let radius: NSTextField = try control("annotation.radius", editor); radius.doubleValue = 18
            XCTAssertTrue(radius.sendAction(radius.action, to: radius.target))
            let opacity: NSSlider = try control("annotation.opacity", editor); opacity.doubleValue = 0.4
            XCTAssertTrue(opacity.sendAction(opacity.action, to: opacity.target))
            let dash: NSPopUpButton = try control("annotation.strokeStyle", editor); dash.selectItem(at: 1)
            XCTAssertTrue(dash.sendAction(dash.action, to: dash.target))
            XCTAssertTrue(canvas.annotations[0].fillEnabled); XCTAssertEqual(canvas.annotations[0].cornerRadius, 18)
            XCTAssertEqual(canvas.annotations[0].opacity, 0.4, accuracy: 0.001)
            XCTAssertEqual(canvas.annotations[0].strokeStyle, .dashed)
            for _ in 0..<4 { try command(canvas, "z", code: 6) }
            XCTAssertFalse(canvas.annotations[0].fillEnabled); XCTAssertEqual(canvas.annotations[0].cornerRadius, 0)
            XCTAssertEqual(canvas.annotations[0].opacity, 1); XCTAssertEqual(canvas.annotations[0].strokeStyle, .solid)
            let text = ImageAnnotation(tool: .text, points: [CGPoint(x: 160, y: 100)], text: "Text")
            canvas.add(text); try click(canvas, CGPoint(x: 175, y: 110))
            let size: NSTextField = try control("annotation.fontSize", editor); size.doubleValue = 34
            XCTAssertTrue(size.sendAction(size.action, to: size.target))
            let bold: NSButton = try control("annotation.bold", editor); bold.performClick(nil)
            let font: NSPopUpButton = try control("annotation.font", editor); font.selectItem(at: 2)
            XCTAssertTrue(font.sendAction(font.action, to: font.target))
            XCTAssertEqual(canvas.annotations.last?.fontSize, 34); XCTAssertEqual(canvas.annotations.last?.bold, true)
            XCTAssertEqual(canvas.annotations.last?.fontName, "Menlo-Regular")
            try command(canvas, "z", code: 6)
            XCTAssertEqual(canvas.annotations.last?.fontName, "Helvetica")
        }
    }

    @MainActor
    func testNativeMultilineInlineTextAcceptEditCancelAndUndo() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            editor.chooseTool(.text); try click(canvas, CGPoint(x: 40, y: 100))
            XCTAssertNil(editor.window?.attachedSheet)
            let input = try XCTUnwrap(editor.activeInlineTextView)
            input.insertText("First line\n第二行", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
            input.keyDown(with: try key(canvas, "\r", code: 36, modifiers: .command))
            XCTAssertEqual(canvas.annotations.count, 1)
            XCTAssertEqual(canvas.annotations[0].text, "First line\n第二行")
            editor.chooseTool(.select)
            let box = canvas.annotations[0].localBounds
            try click(canvas, CGPoint(x: box.midX, y: box.midY), clicks: 2)
            let editingInput = try XCTUnwrap(editor.activeInlineTextView)
            editingInput.insertText("Changed\nAgain", replacementRange: NSRange(location: 0, length: editingInput.string.utf16.count))
            editingInput.keyDown(with: try key(canvas, "\r", code: 36, modifiers: .command))
            XCTAssertEqual(canvas.annotations[0].text, "Changed\nAgain")
            try command(canvas, "z", code: 6)
            XCTAssertEqual(canvas.annotations[0].text, "First line\n第二行")
            try click(canvas, CGPoint(x: box.midX, y: box.midY), clicks: 2)
            let cancelledInput = try XCTUnwrap(editor.activeInlineTextView)
            cancelledInput.string = "Must not persist"
            cancelledInput.keyDown(with: try key(canvas, "\u{1b}", code: 53))
            XCTAssertNil(editor.activeInlineTextView)
            XCTAssertEqual(canvas.annotations[0].text, "First line\n第二行")
            try command(canvas, "z", code: 6)
            XCTAssertTrue(canvas.annotations.isEmpty, "Cancel must not add a history snapshot")
        }
    }

    private func rectangle(_ rect: CGRect) -> ImageAnnotation {
        ImageAnnotation(tool: .rectangle, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], lineWidth: 2)
    }
    private func blankImage(width: Int, height: Int) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    /// Sample in the same y-up image coordinate system used by the model, independent of provider row order.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try bitmap(width: 1, height: 1)
        context.translateBy(x: CGFloat(-x), y: CGFloat(-y)); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: 4))
    }
    private func darkPixels(_ image: CGImage, in rect: CGRect) throws -> Int {
        let context = try bitmap(width: Int(rect.width), height: Int(rect.height))
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(Int(rect.width * rect.height))).filter { index in
            data[index * 4] < 100 && data[index * 4 + 1] < 100 && data[index * 4 + 2] < 100
        }.count
    }
    private func imageBytes(_ image: CGImage) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }

    @MainActor
    private func withEditor(_ body: (ImageEditorController) throws -> Void) throws {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: try blankImage(width: 320, height: 240), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.annotationCanvas.zoom = 1
        defer {
            if let sheet = editor.window?.attachedSheet { editor.window?.endSheet(sheet, returnCode: .cancel) }
            editor.close()
        }
        try body(editor)
    }
    @MainActor
    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor
    private func control<T: NSView>(_ identifier: String, _ editor: ImageEditorController) throws -> T {
        try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == identifier } as? T)
    }
    @MainActor
    private func sheetButton(_ title: String, _ sheet: NSWindow) throws -> NSButton {
        try XCTUnwrap(descendants(sheet.contentView).compactMap { $0 as? NSButton }.first { $0.title == title })
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }
    @MainActor
    private func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint,
                       modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.zoom), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                                              windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    @MainActor
    private func key(_ canvas: ImageEditorCanvas, _ value: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: value,
                                     charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
    @MainActor
    private func command(_ canvas: ImageEditorCanvas, _ value: String, code: UInt16, shift: Bool = false) throws {
        XCTAssertTrue(canvas.performKeyEquivalent(with: try key(canvas, value, code: code, modifiers: shift ? [.command, .shift] : .command)))
    }
    @MainActor
    private func click(_ canvas: ImageEditorCanvas, _ point: CGPoint, clicks: Int = 1) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point, clicks: clicks))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point, clicks: clicks))
    }
    @MainActor
    private func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start, modifiers: modifiers))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end, modifiers: modifiers))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end, modifiers: modifiers))
    }
}
