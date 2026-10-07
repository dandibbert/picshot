import XCTest
import AppKit
@testable import PicShot

final class AnnotationFreehandInteractionTests: XCTestCase {
    @MainActor
    func testClickTinyReverseAndMouseUpOnlyEndpointAtNonuniformZoom() throws {
        _ = NSApplication.shared
        for tool in [ImageEditorTool.freehand, .highlighter] {
            let canvas = ImageEditorCanvas(image: ImageEditorRenderer.makeSampleImage())
            canvas.tool = tool; canvas.zoom = 2; canvas.verticalZoom = 1.5
            var snapshots = 0; canvas.onWillChange = { snapshots += 1 }
            let first = CGPoint(x: 300, y: 220), end = CGPoint(x: 30, y: 40)
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, first))
            canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: 140, y: 100)))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
            XCTAssertEqual(canvas.annotations.count, 1); XCTAssertEqual(snapshots, 1)
            XCTAssertEqual(canvas.annotations[0].points.first, first); XCTAssertEqual(canvas.annotations[0].points.last, end)
            for last in [first, CGPoint(x: first.x + 0.1, y: first.y + 0.1)] {
                canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, first))
                canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, last))
                XCTAssertEqual(canvas.annotations.last?.points.last, last)
            }
            XCTAssertEqual(canvas.annotations.count, 3); XCTAssertEqual(snapshots, 3)
            XCTAssertNil(canvas.pendingFreehand)
        }
    }

    @MainActor
    func testEscapeToolChangeAndContentReplacementDiscardDraftWithoutHistory() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: ImageEditorRenderer.makeSampleImage())
        var snapshots = 0; canvas.onWillChange = { snapshots += 1 }
        for cancellation in 0..<3 {
            canvas.tool = .freehand
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 30, y: 30)))
            canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: 100, y: 100)))
            XCTAssertNotNil(canvas.pendingFreehand); XCTAssertTrue(canvas.annotations.isEmpty)
            if cancellation == 0 { canvas.keyDown(with: try key(canvas, code: 53)) }
            else if cancellation == 1 { canvas.tool = .highlighter }
            else { canvas.setContent(image: canvas.image, annotations: []) }
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 120, y: 120)))
            XCTAssertNil(canvas.pendingFreehand); XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertEqual(snapshots, 0)
        }
    }

    @MainActor
    func testShiftFromMouseDownKeepsOneReversibleEndpointInEveryMode() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: ImageEditorRenderer.makeSampleImage()); canvas.tool = .freehand
        for mode in AnnotationPencilConstraint.allCases {
            canvas.style.freehandConstraint = mode
            let start = CGPoint(x: 450, y: 300), end = CGPoint(x: 60, y: 90)
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start, flags: .shift))
            for point in [CGPoint(x: 800, y: 580), CGPoint(x: 300, y: 410), end] {
                canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, point, flags: .shift))
            }
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end, flags: .shift))
            let mark = try XCTUnwrap(canvas.annotations.last)
            XCTAssertEqual(mark.points.count, 2); XCTAssertEqual(mark.points.first, start)
            let expected = AnnotationFreehandGeometry.constrained(end, from: start, mode: mode,
                extent: CGRect(x: 0, y: 0, width: canvas.image.width, height: canvas.image.height))
            XCTAssertEqual(try XCTUnwrap(mark.points.last).x, expected.x, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(mark.points.last).y, expected.y, accuracy: 0.001)
        }
    }

    @MainActor
    func testVisiblePaletteModeChangeCancelsPendingFreehand() throws {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded()
        defer { editor.close() }
        editor.chooseTool(.highlighter)
        let canvas = editor.annotationCanvas
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 40, y: 40)))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: 140, y: 100)))
        let picker = try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "annotation.highlighterMode" } as? NSPopUpButton)
        XCTAssertFalse(picker.isHiddenOrHasHiddenAncestor)
        picker.selectItem(withTitle: AnnotationHighlighterMode.rectangle.title)
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 170, y: 110)))
        XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertNil(canvas.pendingFreehand)
        XCTAssertEqual(canvas.style.highlighterMode, .rectangle)
    }

    @MainActor
    private func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor
    private func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @MainActor
    private func key(_ canvas: ImageEditorCanvas, code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
}
