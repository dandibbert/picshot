import AppKit
import XCTest
@testable import PicShot

/// Owned NSWindows and native control/event paths only. These tests never request
/// Screen Recording/Accessibility or inject input into another application's UI.
@MainActor final class EditableAnnotationUITests: XCTestCase {
    func testCropReopenRetainsEveryLayerAndMatchesFullRenderThenCropPixels() throws {
        _ = NSApplication.shared
        let source = try EditableUIFixtures.source()
        let marks = EditableUIFixtures.marks()
        let editor = EditableUIFixtures.editor(source)
        defer { editor.close() }
        editor.annotationCanvas.setContent(image: source, annotations: marks)
        editor.annotationCanvas.setNextNumber(27)
        editor.annotationCanvas.setNumberClosesGaps(true)
        let before = try editor.editablePayload()
        let crop = CGRect(x: 48, y: 32, width: 192, height: 128)
        let full = try XCTUnwrap(ImageEditorRenderer.render(image: source, annotations: marks))
        let reference = try XCTUnwrap(ImageEditorRenderer.crop(image: full, to: crop))
        editor.annotationCanvas.cropRect = crop
        EditableUIFixtures.action("applyCrop", editor)
        XCTAssertTrue(editor.annotationCanvas.image === source)
        XCTAssertEqual(editor.annotationCanvas.annotations.map(\.id), marks.map(\.id))
        XCTAssertEqual(editor.annotationCanvas.cropViewportInBase, crop)
        XCTAssertEqual(try EditableUIFixtures.bytes(XCTUnwrap(editor.annotationCanvas.flattened())), try EditableUIFixtures.bytes(reference))
        var payload = try editor.editablePayload()
        XCTAssertEqual(payload.document.baseAssetID, before.document.baseAssetID)
        XCTAssertEqual(payload.document.numberSequence, before.document.numberSequence)
        // The exact same saved representation is used for restore, not an in-memory shortcut.
        payload.document = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(payload.document))
        let reopened = EditableUIFixtures.editor(source); defer { reopened.close() }
        try reopened.restoreEditablePayload(payload)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(reopened.editablePayload().document),
                       try EditableAnnotationDocumentCodec.encode(payload.document))
        XCTAssertEqual(try EditableUIFixtures.bytes(XCTUnwrap(reopened.annotationCanvas.flattened())), try EditableUIFixtures.bytes(reference))
        XCTAssertEqual(reopened.retainedUndoRasterCount, 0)
        let uncropMenu = try XCTUnwrap(reopened.annotationCanvas.menu)
        let uncropIndex = try XCTUnwrap(uncropMenu.items.firstIndex { $0.identifier?.rawValue == "editor.restoreFullCrop" })
        uncropMenu.performActionForItem(at: uncropIndex)
        XCTAssertNil(reopened.annotationCanvas.cropViewportInBase)
        XCTAssertEqual(try EditableUIFixtures.bytes(XCTUnwrap(reopened.annotationCanvas.flattened())), try EditableUIFixtures.bytes(full))
        EditableUIFixtures.action("undoEdit", reopened)
        XCTAssertEqual(reopened.annotationCanvas.cropViewportInBase, crop)
        XCTAssertEqual(editor.retainedUndoRasterCount, 1)
        EditableUIFixtures.action("undoEdit", editor)
        XCTAssertNil(editor.annotationCanvas.cropViewportInBase)
        XCTAssertEqual(try EditableUIFixtures.bytes(XCTUnwrap(editor.annotationCanvas.flattened())), try EditableUIFixtures.bytes(full))
        EditableUIFixtures.action("redoEdit", editor)
        XCTAssertEqual(editor.annotationCanvas.cropViewportInBase, crop)
    }

    func testNestedNativeCropAndHitCoordinatesAtFractionalIndependentScales() throws {
        let source = try EditableUIFixtures.source()
        let editor = EditableUIFixtures.editor(source, apply: { _, _ in })
        defer { editor.close() }
        let crop = CGRect(x: 40, y: 24, width: 220, height: 150)
        editor.annotationCanvas.cropRect = crop; EditableUIFixtures.action("applyCrop", editor)
        let placement = PinEditorPresentation(viewportFrame: CGRect(x: 80.5, y: 200.25, width: 330, height: 187.5),
            imageFrame: CGRect(x: 80.5, y: 200.25, width: 330, height: 187.5), opacity: 0.7, level: .floating)
        XCTAssertTrue(editor.showPinned(placement))
        let canvas = editor.annotationCanvas
        XCTAssertEqual(canvas.zoom, 1.5, accuracy: 0.0001)
        XCTAssertEqual(canvas.displayScaleY, 1.25, accuracy: 0.0001)
        XCTAssertEqual(canvas.bounds.minX, crop.minX * 1.5, accuracy: 0.0001)
        XCTAssertEqual(canvas.bounds.minY, crop.minY * 1.25, accuracy: 0.0001)
        try EditableUIFixtures.click("editor.tool.rectangle", editor: editor)
        try EditableUIFixtures.drag(canvas, from: CGPoint(x: 72, y: 48), to: CGPoint(x: 140, y: 100))
        let mark = try XCTUnwrap(canvas.annotations.last)
        XCTAssertEqual(mark.points, [CGPoint(x: 72, y: 48), CGPoint(x: 140, y: 100)])
        editor.chooseTool(.select)
        try EditableUIFixtures.drag(canvas, from: CGPoint(x: 94, y: 49), to: CGPoint(x: 102, y: 57))
        XCTAssertEqual(canvas.annotations.last?.id, mark.id)
        XCTAssertEqual(canvas.annotations.last?.points.first, CGPoint(x: 80, y: 56))
        XCTAssertTrue(canvas.performKeyEquivalent(with: try EditableUIFixtures.key(canvas, "z", code: 6, modifiers: .command)))
        XCTAssertEqual(canvas.annotations.last?.points, mark.points)
        editor.chooseTool(.crop)
        try EditableUIFixtures.drag(canvas, from: CGPoint(x: 64, y: 40), to: CGPoint(x: 200, y: 136))
        canvas.keyDown(with: try EditableUIFixtures.key(canvas, "\r", code: 36))
        XCTAssertEqual(canvas.cropViewportInBase, CGRect(x: 64, y: 40, width: 136, height: 96))
        XCTAssertTrue(canvas.image === source)
        XCTAssertEqual(canvas.annotations.last?.id, mark.id)
        XCTAssertTrue(canvas.performKeyEquivalent(with: try EditableUIFixtures.key(canvas, "z", code: 6, modifiers: .command)))
        XCTAssertEqual(canvas.cropViewportInBase, crop)
        XCTAssertEqual(editor.editorImageScreenFrame?.width ?? 0, placement.imageFrame.width, accuracy: 0.001)
    }

    func testSavePinAndApplyOnlyReportSuccessAfterDurableCallback() throws {
        enum Refusal: Error { case expected }
        for route in ["saveResult", "pinResult", "applyResult"] {
            let source = try EditableUIFixtures.source()
            var allow = false, attempts = 0, commits = 0, errors = 0
            let commit: (CGImage, EditableCapturePayload) throws -> Void = { image, payload in
                attempts += 1; try payload.validate(currentImage: image)
                guard allow else { throw Refusal.expected }
                commits += 1
            }
            let editor = ImageEditorController(image: source, onSave: { _ in XCTFail("Legacy save") },
                onPin: { _ in XCTFail("Legacy pin") }, onOCR: { _ in },
                onSaveEditable: commit, onPinEditable: commit, onApplyEditable: commit)
            defer { editor.close() }
            editor.onOutputError = { _ in errors += 1 }
            editor.annotationCanvas.add(EditableUIFixtures.marks()[0])
            let saved = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
            EditableUIFixtures.action(route, editor)
            XCTAssertEqual(attempts, 1); XCTAssertEqual(commits, 0); XCTAssertEqual(errors, 1)
            XCTAssertFalse(editor.isClosed)
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document), saved)
            XCTAssertEqual(editor.retainedUndoRasterCount, 1)
            allow = true; EditableUIFixtures.action(route, editor)
            XCTAssertEqual(commits, 1)
            XCTAssertEqual(editor.isClosed, route == "applyResult")
        }
    }

    func testRepeatedCropUndoRedoUsesOneSharedSourceAndReleasesNativeEditors() async throws {
        let source = try EditableUIFixtures.source(width: 1920, height: 1080)
        for _ in 0..<12 {
            weak var controllerProbe: ImageEditorController?
            weak var canvasProbe: ImageEditorCanvas?
            weak var viewProbe: NSView?
            try autoreleasepool {
                let editor = EditableUIFixtures.editor(source)
                controllerProbe = editor; canvasProbe = editor.annotationCanvas; viewProbe = editor.window?.contentView
                editor.annotationCanvas.add(EditableUIFixtures.marks()[0])
                for index in 0..<24 {
                    editor.annotationCanvas.cropRect = CGRect(x: 10 + index, y: 10 + index, width: 600, height: 400)
                    EditableUIFixtures.action("applyCrop", editor)
                    XCTAssertTrue(editor.annotationCanvas.image === source)
                    XCTAssertLessThanOrEqual(editor.retainedUndoRasterCount, 1)
                    EditableUIFixtures.action("undoEdit", editor); EditableUIFixtures.action("redoEdit", editor)
                }
                XCTAssertLessThanOrEqual(editor.estimatedAdmissionRasterBytes, source.bytesPerRow * source.height * 2)
                let payload = try editor.editablePayload()
                XCTAssertTrue(payload.baseImage === source)
                editor.close()
                XCTAssertNil(editor.window?.contentView); XCTAssertNil(editor.annotationCanvas.retainedPresentationRaster)
                XCTAssertEqual(editor.retainedUndoRasterCount, 0)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertNil(controllerProbe); XCTAssertNil(canvasProbe); XCTAssertNil(viewProbe)
        }
    }

    func testLegacyRasterHasNoInventedLayersAndCaptureTimestampRoundTrips() throws {
        let source = try EditableUIFixtures.source()
        let editor = EditableUIFixtures.editor(source); defer { editor.close() }
        var payload = try editor.editablePayload()
        XCTAssertTrue(payload.document.annotations.isEmpty)
        XCTAssertEqual(payload.document.baseProvenance, .legacyRaster)
        payload.document.capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        payload.document.captureTimeZoneIdentifier = "Asia/Shanghai"
        payload.document.captureTimestampKnown = true
        let reopened = EditableUIFixtures.editor(source); defer { reopened.close() }
        try reopened.restoreEditablePayload(payload)
        let mark = reopened.annotationCanvas.makeAnnotation(tool: .watermark, points: [CGPoint(x: 30, y: 30)])
        XCTAssertEqual(mark.frozenTimestamp, payload.document.capturedAt)
        XCTAssertEqual(mark.frozenTimeZoneIdentifier, "Asia/Shanghai")
        XCTAssertTrue(mark.timestampIsCaptureDate)
        XCTAssertEqual(mark.watermarkTemplate, "PicShot · $yyyy-MM-dd HH:mm:ss$")
    }
}

@MainActor enum EditableUIFixtures {
    static func editor(_ image: CGImage, apply: ((CGImage, EditableCapturePayload) throws -> Void)? = nil) -> ImageEditorController {
        _ = NSApplication.shared
        return ImageEditorController(image: image, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, onApplyEditable: apply)
    }
    static func source(width: Int = 320, height: Int = 240) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        for y in stride(from: 0, to: height, by: 8) { for x in stride(from: 0, to: width, by: 8) {
            context.setFillColor(CGColor(srgbRed: Double((x + y) % 255) / 255,
                green: Double((x * 7 + y) % 255) / 255, blue: Double((y * 11 + x) % 255) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 8, height: 8))
        } }
        return try XCTUnwrap(context.makeImage())
    }
    static func marks() -> [ImageAnnotation] {
        var redaction = ImageAnnotation(tool: .redact, points: [CGPoint(x: 72, y: 58), CGPoint(x: 118, y: 94)])
        redaction.color = CGColor(gray: 0, alpha: 1)
        var blur = ImageAnnotation(tool: .blur, points: [CGPoint(x: 28, y: 14), CGPoint(x: 108, y: 64)], lineWidth: 5)
        blur.rotation = 0.12
        var lens = ImageAnnotation(tool: .magnifier, points: [CGPoint(x: 156, y: 60), CGPoint(x: 225, y: 122)])
        lens.magnifierSource = CGRect(x: 260, y: 180, width: 30, height: 26)
        lens.magnifierScale = 2; lens.magnifierSmooth = false
        var spotlight = ImageAnnotation(tool: .spotlight, points: [CGPoint(x: 30, y: 18), CGPoint(x: 260, y: 185)])
        spotlight.spotlightDim = 0.27
        let eraser = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 58, y: 74), CGPoint(x: 130, y: 74)], lineWidth: 9)
        let group = UUID(), addition = UUID()
        let targets = [CGRect(x: 132, y: 120, width: 32, height: 26), CGRect(x: 202, y: 124, width: 32, height: 26)]
        let linked = targets.map { rect -> ImageAnnotation in
            var mark = ImageAnnotation(tool: .pixelate, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)])
            mark.mosaicLink = AutomaticMosaicLink(groupID: group, additionID: addition, rootAdditionID: addition,
                target: rect, includedTargets: targets, excludedTargets: [CGRect(x: 10, y: 190, width: 32, height: 26)], synchronizes: true)
            return mark
        }
        return [redaction, blur, lens, spotlight, eraser] + linked
    }
    static func bytes(_ image: CGImage) throws -> [UInt8] { try EditorOutputDecorationNativeFixture.raster(image) }
    static func action(_ name: String, _ target: AnyObject) {
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString(name), to: target, from: nil))
    }
    static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    static func click(_ identifier: String, editor: ImageEditorController) throws {
        let root = try XCTUnwrap(editor.window?.contentView)
        let button = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == identifier } as? NSButton)
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor); XCTAssertTrue(button.isEnabled)
        let point = root.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        let hit = try XCTUnwrap(root.hitTest(point))
        XCTAssertTrue(hit === button || hit.isDescendant(of: button))
        button.performClick(nil)
    }
    static func key(_ view: NSView, _ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    static func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown {
                let root = try XCTUnwrap(canvas.window?.contentView)
                let hit = root.hitTest(root.convert(location, from: nil))
                XCTAssertTrue(hit === canvas || hit?.isDescendant(of: canvas) == true)
                canvas.mouseDown(with: event)
            } else if type == .leftMouseDragged { canvas.mouseDragged(with: event) }
            else { canvas.mouseUp(with: event) }
        }
    }
}
