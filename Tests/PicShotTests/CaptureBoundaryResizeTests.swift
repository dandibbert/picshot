import XCTest
import AppKit
@testable import PicShot

final class CaptureBoundaryResizeTests: XCTestCase {
    func testAllEightBoundaryHandlesHitAndPreserveOppositeEdges() {
        let frame = CGRect(x: 100, y: 80, width: 500, height: 300), bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        for handle in EditorBoundaryHandle.allCases { XCTAssertEqual(EditorBoundaryHandle.hit(at: handle.point(in: frame), frame: frame), handle) }
        XCTAssertNil(EditorBoundaryHandle.hit(at: CGPoint(x: 200, y: 200), frame: frame))
        let left = EditorBoundaryHandle.left.resized(frame, to: CGPoint(x: 50, y: 900), in: bounds)
        XCTAssertEqual(left, CGRect(x: 50, y: 80, width: 550, height: 300))
        let clamped = EditorBoundaryHandle.topRight.resized(frame, to: CGPoint(x: 2000, y: 2000), in: bounds)
        XCTAssertEqual(clamped, CGRect(x: 100, y: 80, width: 900, height: 620))
        let inverted = EditorBoundaryHandle.bottomLeft.resized(frame, to: CGPoint(x: 2000, y: 2000), in: bounds)
        XCTAssertEqual(inverted.size, CGSize(width: 2, height: 2))
    }
    func testRetinaRecropPreservesRasterizedEditsAndMaterializesOnlyCrop() throws {
        let frozen = try solid(width: 200, height: 160, color: CGColor(gray: 1, alpha: 1))
        let old = FrozenCapturePresentation(frozenImage: frozen, displayID: 7, displayFrame: CGRect(x: -100, y: 50, width: 100, height: 80), selectionFrame: CGRect(x: 20, y: 20, width: 40, height: 30))
        let editedBase = try solid(width: 80, height: 60, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let next = try EditorBoundaryRenderer.recrop(CGRect(x: 10.25, y: 9.75, width: 60.5, height: 50.5), presentation: old, previousImage: editedBase)
        let frame = try XCTUnwrap(next.presentation?.selectionFrame)
        XCTAssertEqual(frame, CGRect(x: 10, y: 9.5, width: 61, height: 51))
        XCTAssertEqual(next.image.width, 122); XCTAssertEqual(next.image.height, 102)
        XCTAssertEqual(next.image.bytesPerRow, 122 * 4)
        XCTAssertEqual(CFDataGetLength(try XCTUnwrap(next.image.dataProvider?.data)), 122 * 102 * 4)
        XCTAssertEqual(try pixel(next.image, x: 0, y: 0), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(next.image, x: 25, y: 30), [255, 0, 0, 255], "Previously flattened edits must survive expansion")
    }
    @MainActor
    func testNativeBoundaryDragUsesPreviewThenOneUndoableCommit() throws {
        let editor = try makeEditor(); defer { editor.close() }
        let canvas = editor.annotationCanvas, workspace = editor.captureBoundaryWorkspace
        var annotation = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 100)])
        annotation.rotation = .pi / 6; canvas.add(annotation)
        let originalImage = canvas.image, originalFrame = editor.editorSelectionFrame
        let point = EditorBoundaryHandle.left.point(in: originalFrame)
        workspace.mouseDown(with: try event(.leftMouseDown, workspace, point))
        for step in 1...10 {
            workspace.mouseDragged(with: try event(.leftMouseDragged, workspace, CGPoint(x: point.x - CGFloat(step) * 4, y: point.y)))
            XCTAssertTrue(canvas.image === originalImage, "Mouse moves must not allocate/replace the selected raster")
            XCTAssertEqual(canvas.annotations[0].points, annotation.points)
        }
        XCTAssertTrue(canvas.isHidden); XCTAssertNotNil(workspace.boundaryPreviewImage)
        workspace.mouseUp(with: try event(.leftMouseUp, workspace, CGPoint(x: point.x - 40, y: point.y)))
        XCTAssertFalse(canvas.isHidden); XCTAssertNil(workspace.boundaryPreviewImage)
        XCTAssertEqual(editor.editorSelectionFrame.minX, originalFrame.minX - 40)
        XCTAssertEqual(canvas.annotations[0].points[0].x, annotation.points[0].x + 40)
        XCTAssertEqual(canvas.annotations[0].rotation, annotation.rotation)
        XCTAssertEqual(canvas.annotations[0].id, annotation.id)
        XCTAssertEqual(editor.editorSelectionFrame.minX + canvas.annotations[0].points[0].x, originalFrame.minX + annotation.points[0].x)
        try command(canvas, "z", code: 6)
        XCTAssertTrue(canvas.image === originalImage); XCTAssertEqual(editor.editorSelectionFrame, originalFrame)
        XCTAssertEqual(canvas.annotations[0].points, annotation.points)
        try command(canvas, "z", code: 6)
        XCTAssertTrue(canvas.annotations.isEmpty, "One resize gesture must add exactly one undo state")
    }
    @MainActor
    func testNativeEscapeCancelsBoundaryPreviewWithoutConsumingRedo() throws {
        let editor = try makeEditor(); defer { editor.close() }
        let canvas = editor.annotationCanvas, workspace = editor.captureBoundaryWorkspace
        canvas.add(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 100)]))
        try command(canvas, "z", code: 6)
        let originalImage = canvas.image, originalFrame = editor.editorSelectionFrame
        let point = EditorBoundaryHandle.bottomRight.point(in: originalFrame)
        workspace.mouseDown(with: try event(.leftMouseDown, workspace, point))
        workspace.mouseDragged(with: try event(.leftMouseDragged, workspace, CGPoint(x: point.x + 25, y: point.y - 30)))
        workspace.keyDown(with: try key(workspace, "\u{1b}", code: 53))
        workspace.mouseUp(with: try event(.leftMouseUp, workspace, CGPoint(x: point.x + 25, y: point.y - 30)))
        XCTAssertEqual(editor.editorSelectionFrame, originalFrame); XCTAssertTrue(canvas.image === originalImage)
        XCTAssertFalse(canvas.isHidden); XCTAssertNil(workspace.boundaryPreviewImage)
        XCTAssertTrue(editor.window?.isVisible == true, "Escape cancels this gesture, not the whole editor")
        try command(canvas, "z", code: 6, shift: true)
        XCTAssertEqual(canvas.annotations.count, 1, "Cancelled selection resize must leave redo intact")
    }
    @MainActor
    func testNoMovementDoesNotCreateUndoAndCloseDiscardsPreview() throws {
        let editor = try makeEditor()
        let canvas = editor.annotationCanvas, workspace = editor.captureBoundaryWorkspace
        canvas.add(ImageAnnotation(tool: .arrow, points: [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 100)]))
        let point = EditorBoundaryHandle.top.point(in: editor.editorSelectionFrame)
        workspace.mouseDown(with: try event(.leftMouseDown, workspace, point))
        workspace.mouseUp(with: try event(.leftMouseUp, workspace, point))
        try command(canvas, "z", code: 6); XCTAssertTrue(canvas.annotations.isEmpty)
        workspace.mouseDown(with: try event(.leftMouseDown, workspace, point))
        workspace.mouseDragged(with: try event(.leftMouseDragged, workspace, CGPoint(x: point.x, y: point.y + 20)))
        editor.close()
        XCTAssertNil(workspace.boundaryPreviewImage); XCTAssertFalse(workspace.isResizingBoundary)
        XCTAssertNil(editor.window?.contentView)
    }
    @MainActor
    private func makeEditor() throws -> ImageEditorController {
        _ = NSApplication.shared
        let source = ImageEditorRenderer.makeSampleImage()
        let capture = try CapturedImage.frozenRegion(image: source, displayID: 7, displayFrame: CGRect(x: 0, y: 0, width: 960, height: 600), selection: CGRect(x: 120, y: 100, width: 600, height: 300))
        let editor = ImageEditorController(image: capture.image, presentation: capture.presentation, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded(); return editor
    }
    @MainActor private func event(_ type: NSEvent.EventType, _ view: NSView, _ point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @MainActor private func key(_ view: NSView, _ value: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
    @MainActor private func command(_ canvas: ImageEditorCanvas, _ value: String, code: UInt16, shift: Bool = false) throws {
        XCTAssertTrue(canvas.performKeyEquivalent(with: try key(canvas, value, code: code, flags: shift ? [.command, .shift] : .command)))
    }
    private func solid(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height)); return try XCTUnwrap(context.makeImage())
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.translateBy(x: CGFloat(-x), y: CGFloat(-y)); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }
}
