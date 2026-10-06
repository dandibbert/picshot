import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import PicShot

final class ImageEditorTests: XCTestCase {
    func testSampleFixtureHasExpectedDimensions() {
        let image = ImageEditorRenderer.makeSampleImage()
        XCTAssertEqual(image.width, 960)
        XCTAssertEqual(image.height, 600)
        XCTAssertNotNil(image.dataProvider?.data)
    }

    func testEmptyRenderPreservesDimensionsAndPixels() throws {
        let original = try makeImage(width: 40, height: 30, color: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: []))
        XCTAssertEqual(rendered.width, 40)
        XCTAssertEqual(rendered.height, 30)
        XCTAssertEqual(try rgba(rendered, x: 20, y: 15), try rgba(original, x: 20, y: 15))
    }

    func testRedactionIsOpaqueEvenWhenChosenColorIsTransparent() throws {
        let original = try makeImage(width: 40, height: 40, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let annotation = ImageAnnotation(tool: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: CGColor(gray: 0, alpha: 0.1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [annotation]))
        XCTAssertEqual(try rgba(rendered, x: 20, y: 20), [0, 0, 0, 255])
        XCTAssertEqual(try rgba(rendered, x: 2, y: 2), [255, 0, 0, 255])
        // Raster output must remain independent from subsequent model changes.
        var editedAnnotation = annotation
        editedAnnotation.points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertEqual(try rgba(rendered, x: 20, y: 20), [0, 0, 0, 255])
        XCTAssertNotEqual(editedAnnotation.bounds, annotation.bounds)
    }

    func testHighlighterKeepsUnderlyingPixelsVisible() throws {
        let original = try makeImage(width: 40, height: 40, color: CGColor(gray: 1, alpha: 1))
        let marker = ImageAnnotation(tool: .highlighter, points: [CGPoint(x: 8, y: 8), CGPoint(x: 32, y: 32)], color: CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [marker]))
        let pixel = try rgba(rendered, x: 20, y: 20)
        XCTAssertGreaterThan(pixel[2], 100)
        XCTAssertLessThan(pixel[2], 240)
        XCTAssertEqual(pixel[3], 255)
    }

    func testAnnotationOrderIsFlattenedInOrder() throws {
        let original = try makeImage(width: 40, height: 40, color: CGColor(gray: 1, alpha: 1))
        let points = [CGPoint(x: 5, y: 5), CGPoint(x: 35, y: 35)]
        let red = ImageAnnotation(tool: .redact, points: points, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let blue = ImageAnnotation(tool: .redact, points: points, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [red, blue]))
        XCTAssertEqual(try rgba(rendered, x: 20, y: 20), [0, 0, 255, 255])
    }

    func testEveryDrawingToolRendersWithoutChangingExtent() throws {
        let image = ImageEditorRenderer.makeSampleImage()
        for tool in ImageEditorTool.allCases {
            let annotation = ImageAnnotation(tool: tool, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250)], text: "Test 文字", number: 2)
            let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [annotation]), "\(tool)")
            XCTAssertEqual(result.width, image.width, "\(tool)")
            XCTAssertEqual(result.height, image.height, "\(tool)")
        }
    }

    func testCropClipsToImageAndRejectsEmptyRegion() throws {
        let image = try makeImage(width: 100, height: 80, color: CGColor(gray: 1, alpha: 1))
        let cropped = try XCTUnwrap(ImageEditorRenderer.crop(image: image, to: CGRect(x: -10, y: 20, width: 50, height: 100)))
        XCTAssertEqual(cropped.width, 40)
        XCTAssertEqual(cropped.height, 60)
        XCTAssertNil(ImageEditorRenderer.crop(image: image, to: CGRect(x: 200, y: 200, width: 10, height: 10)))
        XCTAssertNil(ImageEditorRenderer.crop(image: image, to: .zero))
    }

    func testCropUsesBottomLeftAnnotationCoordinates() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 80, bitsPerComponent: 8, bytesPerRow: 60 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 40, width: 60, height: 40))
        let original = try XCTUnwrap(context.makeImage())
        let bottom = try XCTUnwrap(ImageEditorRenderer.crop(image: original, to: CGRect(x: 0, y: 0, width: 60, height: 40)))
        XCTAssertEqual(try rgba(bottom, x: 30, y: 20), [255, 0, 0, 255])
    }

    func testFiltersChangeOnlyTheSelectedRegion() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 80 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        for y in stride(from: 0, to: 80, by: 2) {
            for x in stride(from: 0, to: 80, by: 2) {
                context.setFillColor(CGColor(gray: ((x / 2 + y / 2) % 2 == 0) ? 0 : 1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        let original = try XCTUnwrap(context.makeImage())
        for tool in [ImageEditorTool.blur, .pixelate] {
            let annotation = ImageAnnotation(tool: tool, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)])
            let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [annotation]))
            XCTAssertEqual(try rgba(rendered, x: 5, y: 5), try rgba(original, x: 5, y: 5))
            var foundChangedPixel = false
            for x in 30..<50 {
                if try rgba(rendered, x: x, y: 40) != rgba(original, x: x, y: 40) { foundChangedPixel = true }
            }
            XCTAssertTrue(foundChangedPixel, "\(tool) must affect pixels inside the selected area")
        }
    }

    func testRasterAllocationLimitRejectsOversizedAndOverflowingDimensions() {
        XCTAssertTrue(ImageEditorRenderer.allowsRasterSize(width: 10_000, height: 10_000))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: 10_001, height: 10_000))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: Int.max, height: 2))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: Int.max / 4, height: 8))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: 0, height: 2))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: 1, height: -2))
    }

    func testHistoryBudgetCountsSharedImagesOnlyOnce() throws {
        let first = try makeImage(width: 4, height: 4, color: CGColor(gray: 0, alpha: 1))
        let second = try makeImage(width: 4, height: 4, color: CGColor(gray: 1, alpha: 1))
        let bytes = first.bytesPerRow * first.height + second.bytesPerRow * second.height
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: [first, first, second], maximumBytes: bytes), 0)
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: [first, first, second], maximumBytes: bytes, maximumSnapshots: 2), 1)
    }

    func testHistoryBudgetEvictsOldestDistinctImages() throws {
        let first = try makeImage(width: 4, height: 4, color: CGColor(gray: 0, alpha: 1))
        let second = try makeImage(width: 4, height: 4, color: CGColor(gray: 1, alpha: 1))
        let third = try makeImage(width: 4, height: 4, color: CGColor(gray: 0.5, alpha: 1))
        let bytes = second.bytesPerRow * second.height + third.bytesPerRow * third.height
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: [first, second, third], maximumBytes: bytes), 1)
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: [first, second, third], maximumBytes: 1), 2)
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: []), 0)
    }

    func testCropMaterializesOnlyItsVisibleRaster() throws {
        let image = try makeImage(width: 200, height: 160, color: CGColor(gray: 1, alpha: 1))
        let crop = try XCTUnwrap(ImageEditorRenderer.crop(image: image, to: CGRect(x: 20, y: 20, width: 8, height: 10)))
        XCTAssertEqual(crop.bytesPerRow, crop.width * 4)
        let data = try XCTUnwrap(crop.dataProvider?.data)
        XCTAssertEqual(CFDataGetLength(data), 8 * 10 * 4)
    }

    func testTranslationPreservesIdentityAndText() {
        let original = ImageAnnotation(tool: .text, points: [CGPoint(x: 10, y: 20)], text: "Label")
        let moved = original.translated(by: CGSize(width: 14, height: -8))
        XCTAssertEqual(moved.id, original.id)
        XCTAssertEqual(moved.text, "Label")
        XCTAssertEqual(moved.points.first, CGPoint(x: 24, y: 12))
        XCTAssertEqual(original.points.first, CGPoint(x: 10, y: 20))
    }

    @MainActor
    func testRasterExportsCanBeReopenedWithoutSourceLayers() throws {
        let original = try makeImage(width: 40, height: 40, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let redaction = ImageAnnotation(tool: .redact, points: [CGPoint(x: 5, y: 5), CGPoint(x: 35, y: 35)], color: CGColor(gray: 0, alpha: 1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [redaction]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (format, ext) in ["png", "jpg", "tiff"].enumerated() {
            let url = directory.appendingPathComponent("redacted.\(ext)")
            try ImageEditorController.writeFlattened(rendered, to: url, format: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            let reopened = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(reopened.width, 40)
            let pixel = try rgba(reopened, x: 20, y: 20)
            XCTAssertLessThan(pixel[0], 8, "\(ext) redaction must remain black")
            XCTAssertLessThan(pixel[1], 8)
            XCTAssertLessThan(pixel[2], 8)
        }
        let pdfURL = directory.appendingPathComponent("redacted.pdf")
        try ImageEditorController.writeFlattened(rendered, to: pdfURL, format: 3)
        let pdf = try XCTUnwrap(CGPDFDocument(pdfURL as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 40, height: 40))
    }

    @MainActor
    func testNativeMouseDrawMoveDeleteAndKeyboardUndoRedo() throws {
        try withInteractiveEditor { editor in
            let canvas = editor.annotationCanvas
            try clickTool(.rectangle, in: editor)
            try drag(canvas, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 100, y: 90))
            XCTAssertEqual(canvas.annotations.count, 1)
            let original = try XCTUnwrap(canvas.annotations.first)
            XCTAssertEqual(original.bounds, CGRect(x: 20, y: 30, width: 80, height: 60))

            try clickTool(.select, in: editor)
            try drag(canvas, from: CGPoint(x: 40, y: 50), to: CGPoint(x: 60, y: 70))
            XCTAssertEqual(canvas.annotations.first?.id, original.id)
            XCTAssertEqual(canvas.annotations.first?.bounds, CGRect(x: 40, y: 50, width: 80, height: 60))
            canvas.keyDown(with: try keyEvent(canvas, key: "\u{7f}", code: 51))
            XCTAssertTrue(canvas.annotations.isEmpty)

            XCTAssertTrue(canvas.performKeyEquivalent(with: try keyEvent(canvas, key: "z", code: 6, modifiers: .command)))
            XCTAssertEqual(canvas.annotations.first?.bounds, CGRect(x: 40, y: 50, width: 80, height: 60))
            XCTAssertTrue(canvas.performKeyEquivalent(with: try keyEvent(canvas, key: "z", code: 6, modifiers: .command)))
            XCTAssertEqual(canvas.annotations.first?.bounds, original.bounds)
            XCTAssertTrue(canvas.performKeyEquivalent(with: try keyEvent(canvas, key: "z", code: 6, modifiers: [.command, .shift])))
            XCTAssertEqual(canvas.annotations.first?.bounds, CGRect(x: 40, y: 50, width: 80, height: 60))
        }
    }

    @MainActor
    func testNativeZoomedShiftDragDirectFreehandAndMoreMenu() throws {
        try withInteractiveEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.zoom = 2
            try clickTool(.rectangle, in: editor)
            try drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), modifiers: .shift)
            XCTAssertEqual(canvas.annotations.first?.bounds, CGRect(x: 10, y: 10, width: 50, height: 50))

            // Freehand is a first-class icon in the floating strip. Exercise its
            // real control rather than the removed text-based tool picker.
            try clickTool(.freehand, in: editor)
            XCTAssertEqual(canvas.zoom, 2)
            canvas.mouseDown(with: try mouseEvent(canvas, kind: .leftMouseDown, point: CGPoint(x: 160, y: 30)))
            canvas.mouseDragged(with: try mouseEvent(canvas, kind: .leftMouseDragged, point: CGPoint(x: 170, y: 45)))
            canvas.mouseDragged(with: try mouseEvent(canvas, kind: .leftMouseDragged, point: CGPoint(x: 180, y: 20)))
            canvas.mouseUp(with: try mouseEvent(canvas, kind: .leftMouseUp, point: CGPoint(x: 180, y: 20)))
            XCTAssertEqual(canvas.annotations.count, 2)
            XCTAssertEqual(canvas.annotations.last?.points.last, CGPoint(x: 180, y: 20))
            XCTAssertEqual(canvas.annotations.last?.tool, .freehand)
            XCTAssertEqual(canvas.annotations.last?.points.first, CGPoint(x: 160, y: 30))
            XCTAssertEqual(Array(try XCTUnwrap(canvas.annotations.last).points.suffix(2)),
                           [CGPoint(x: 170, y: 45), CGPoint(x: 180, y: 20)])

            // Overflow entries now own their target/action. Dispatch through the
            // actual NSMenu item, including its tool tag, and keep zoom unchanged.
            let more = try XCTUnwrap(allSubviews(editor.window?.contentView).compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == "editor.more" })
            XCTAssertTrue(more.isEnabled); XCTAssertFalse(more.isHiddenOrHasHiddenAncestor)
            let menu = try XCTUnwrap(more.menu)
            let index = try XCTUnwrap(menu.items.firstIndex { $0.title == ImageEditorTool.ellipse.title })
            XCTAssertNotNil(menu.items[index].target); XCTAssertNotNil(menu.items[index].action)
            menu.performActionForItem(at: index)
            XCTAssertEqual(canvas.tool, .ellipse); XCTAssertEqual(canvas.zoom, 2)
            try drag(canvas, from: CGPoint(x: 10, y: 140), to: CGPoint(x: 90, y: 190), modifiers: .shift)
            XCTAssertEqual(canvas.annotations.count, 3)
            XCTAssertEqual(canvas.annotations.last?.tool, .ellipse)
            XCTAssertEqual(canvas.annotations.last?.bounds, CGRect(x: 10, y: 140, width: 50, height: 50))
            XCTAssertTrue(canvas.performKeyEquivalent(with: try keyEvent(canvas, key: "z", code: 6, modifiers: .command)))
            XCTAssertEqual(canvas.annotations.count, 2)
            XCTAssertEqual(canvas.annotations.last?.tool, .freehand)
        }
    }

    @MainActor
    func testNativeCropReturnAndUndoRestoreOriginalImage() throws {
        try withInteractiveEditor { editor in
            let canvas = editor.annotationCanvas
            try clickTool(.crop, in: editor)
            try drag(canvas, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 130, y: 100))
            XCTAssertEqual(canvas.cropRect, CGRect(x: 10, y: 20, width: 120, height: 80))
            canvas.keyDown(with: try keyEvent(canvas, key: "\r", code: 36))
            XCTAssertEqual(canvas.image.width, 120)
            XCTAssertEqual(canvas.image.height, 80)
            XCTAssertNil(canvas.cropRect)
            XCTAssertTrue(canvas.performKeyEquivalent(with: try keyEvent(canvas, key: "z", code: 6, modifiers: .command)))
            XCTAssertEqual(canvas.image.width, 320)
            XCTAssertEqual(canvas.image.height, 240)
        }
    }

    @MainActor
    func testNativeSelectedStyleControlsAndTextDoubleClickRequest() throws {
        try withInteractiveEditor { editor in
            let canvas = editor.annotationCanvas
            try clickTool(.rectangle, in: editor)
            try drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 80))
            try clickTool(.select, in: editor)
            canvas.mouseDown(with: try mouseEvent(canvas, kind: .leftMouseDown, point: CGPoint(x: 30, y: 30)))
            canvas.mouseUp(with: try mouseEvent(canvas, kind: .leftMouseUp, point: CGPoint(x: 30, y: 30)))
            let color = try XCTUnwrap(allSubviews(editor.window?.contentView).compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == "annotation.color" })
            color.color = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            XCTAssertTrue(color.sendAction(color.action, to: color.target))
            XCTAssertEqual(canvas.annotations.first?.color, color.color.cgColor)
            let width = try XCTUnwrap(allSubviews(editor.window?.contentView).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "annotation.lineWidth" })
            width.selectItem(withTitle: "6")
            XCTAssertTrue(width.sendAction(width.action, to: width.target))
            XCTAssertEqual(canvas.annotations.first?.lineWidth, 6)

            let text = ImageAnnotation(tool: .text, points: [CGPoint(x: 160, y: 120)], text: "Original")
            canvas.add(text)
            var requestedID: UUID?
            canvas.onRequestText = { _, id in requestedID = id }
            canvas.mouseDown(with: try mouseEvent(canvas, kind: .leftMouseDown, point: CGPoint(x: 165, y: 125), clicks: 2))
            canvas.mouseUp(with: try mouseEvent(canvas, kind: .leftMouseUp, point: CGPoint(x: 165, y: 125), clicks: 2))
            XCTAssertEqual(requestedID, text.id)
            canvas.updateText(id: text.id, text: "Revised")
            XCTAssertEqual(canvas.annotations.last?.text, "Revised")
            XCTAssertTrue(canvas.performKeyEquivalent(with: try keyEvent(canvas, key: "z", code: 6, modifiers: .command)))
            XCTAssertEqual(canvas.annotations.last?.text, "Original")
        }
    }

    @MainActor
    private func withInteractiveEditor(_ body: (ImageEditorController) throws -> Void) throws {
        _ = NSApplication.shared
        let image = try makeImage(width: 320, height: 240, color: CGColor(gray: 1, alpha: 1))
        let editor = ImageEditorController(image: image, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.annotationCanvas.zoom = 1
        defer { editor.close() }
        try body(editor)
    }

    @MainActor
    private func allSubviews(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { allSubviews($0) }
    }

    @MainActor
    private func clickTool(_ tool: ImageEditorTool, in editor: ImageEditorController) throws {
        let button = try XCTUnwrap(allSubviews(editor.window?.contentView).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "editor.tool.\(tool.rawValue)" })
        XCTAssertTrue(button.isEnabled); XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
        button.performClick(nil)
        XCTAssertEqual(editor.annotationCanvas.tool, tool)
        XCTAssertEqual(button.state, .on)
    }

    @MainActor
    private func mouseEvent(_ canvas: ImageEditorCanvas, kind: NSEvent.EventType, point: CGPoint,
                            modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.zoom), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: location, modifierFlags: modifiers, timestamp: 0,
                                              windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
                                              eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    @MainActor
    private func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint,
                      modifiers: NSEvent.ModifierFlags = []) throws {
        canvas.mouseDown(with: try mouseEvent(canvas, kind: .leftMouseDown, point: start, modifiers: modifiers))
        canvas.mouseDragged(with: try mouseEvent(canvas, kind: .leftMouseDragged, point: end, modifiers: modifiers))
        canvas.mouseUp(with: try mouseEvent(canvas, kind: .leftMouseUp, point: end, modifiers: modifiers))
    }

    @MainActor
    private func keyEvent(_ canvas: ImageEditorCanvas, key: String, code: UInt16,
                          modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: key,
                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    private func makeImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 4))
    }
}
