import XCTest
import AppKit
@testable import PicShot

final class AnnotationPathInteractionTests: XCTestCase {
    @MainActor
    func testDraftShiftSnapsAndShortensAtImageEdgeWithoutLosingAngle() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: ImageEditorRenderer.makeSampleImage()); canvas.tool = .polyline
        try click(canvas, CGPoint(x: 940, y: 570))
        try click(canvas, CGPoint(x: 960, y: 600), flags: .shift)
        let points = try XCTUnwrap(canvas.pendingPolyline).points
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[1].x, 960, accuracy: 0.0001)
        XCTAssertEqual(points[1].y, 590, accuracy: 0.0001)
        XCTAssertEqual(points[1].x - points[0].x, points[1].y - points[0].y, accuracy: 0.0001)
        canvas.finishPolyline(); XCTAssertEqual(canvas.annotations.count, 1)
    }

    @MainActor
    func testOneVertexFinishAndBackspaceAreNoOpsForCommittedHistory() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: ImageEditorRenderer.makeSampleImage()); canvas.tool = .polyline
        var snapshots = 0; canvas.onWillChange = { snapshots += 1 }
        try click(canvas, CGPoint(x: 20, y: 20)); canvas.finishPolyline()
        XCTAssertEqual(snapshots, 0); XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertNil(canvas.pendingPolyline)
        try click(canvas, CGPoint(x: 20, y: 20)); canvas.removeLastPolylineVertex()
        XCTAssertEqual(snapshots, 0); XCTAssertEqual(canvas.pendingPolylinePointCount, 0)
        try click(canvas, CGPoint(x: 20, y: 20)); try click(canvas, CGPoint(x: 80, y: 50))
        canvas.finishPolyline(); XCTAssertEqual(snapshots, 1); XCTAssertEqual(canvas.annotations.count, 1)
        try click(canvas, CGPoint(x: 150, y: 150)); canvas.removeLastPolylineVertex()
        XCTAssertEqual(snapshots, 1); XCTAssertEqual(canvas.annotations.count, 1)
    }

    @MainActor
    func testPolylineHoverNeverBecomesUnclickedCommittedVertex() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: ImageEditorRenderer.makeSampleImage()); canvas.tool = .polyline
        try click(canvas, CGPoint(x: 20, y: 20)); try click(canvas, CGPoint(x: 80, y: 80))
        canvas.mouseMoved(with: try mouse(canvas, .mouseMoved, CGPoint(x: 300, y: 200)))
        canvas.finishPolyline()
        XCTAssertEqual(canvas.annotations[0].points, [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)])
        XCTAssertEqual(canvas.pendingPolylinePointCount, 0)
    }

    @MainActor
    func testDragBuildsInitialSegmentWithoutCommittingAndNoDuplicateClicks() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: ImageEditorRenderer.makeSampleImage()); canvas.tool = .polyline
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 30, y: 30)))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: 140, y: 120)))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 140, y: 120)))
        XCTAssertEqual(canvas.pendingPolylinePointCount, 2); XCTAssertTrue(canvas.annotations.isEmpty)
        try click(canvas, CGPoint(x: 140, y: 120)); XCTAssertEqual(canvas.pendingPolylinePointCount, 2)
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 143, y: 123), clicks: 2))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 143, y: 123), clicks: 2))
        XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.annotations[0].points.count, 2, "Second-click jitter must not create a tiny extra segment")
        XCTAssertEqual(canvas.annotations[0].points.last, CGPoint(x: 140, y: 120))
    }

    @MainActor
    func testOutputActionFinishesDraftButCancelDoesNotSave() throws {
        _ = NSApplication.shared
        var outputs: [CGImage] = []
        let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { outputs.append($0) }, onPin: { _ in }, onOCR: { _ in })
        defer { editor.close() }
        editor.showWindow(nil); editor.chooseTool(.polyline)
        let canvas = editor.annotationCanvas
        try click(canvas, CGPoint(x: 40, y: 40)); try click(canvas, CGPoint(x: 220, y: 140))
        let more = try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "editor.more" } as? NSPopUpButton)
        let menu = try XCTUnwrap(more.menu)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "保存到历史" })
        menu.performActionForItem(at: index)
        XCTAssertEqual(outputs.count, 1); XCTAssertEqual(canvas.annotations.count, 1); XCTAssertEqual(canvas.pendingPolylinePointCount, 0)
        try click(canvas, CGPoint(x: 60, y: 60))
        let cancel = try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "editor.cancel" } as? NSButton)
        cancel.performClick(nil)
        XCTAssertEqual(outputs.count, 1); XCTAssertEqual(canvas.annotations.count, 1); XCTAssertEqual(canvas.pendingPolylinePointCount, 0)
        XCTAssertTrue(editor.isClosed); XCTAssertNil(canvas.retainedPresentationRaster)
    }

    @MainActor
    func testSubtoolMenuUpdatesDirectFamilyButtonAndCanReturnToEllipse() throws {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        defer { editor.close() }; editor.showWindow(nil)
        let controls = descendants(editor.window?.contentView)
        let popup = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "editor.shapeSubtools" } as? NSPopUpButton)
        let button = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "editor.tool.ellipse" } as? NSButton)
        for tool in [ImageEditorTool.arc, .sector, .ellipse] {
            let menu = try XCTUnwrap(popup.menu), index = try XCTUnwrap(popup.menu?.items.firstIndex { $0.title == tool.title })
            menu.performActionForItem(at: index)
            XCTAssertEqual(editor.annotationCanvas.tool, tool)
            XCTAssertEqual(button.tag, ImageEditorTool.allCases.firstIndex(of: tool))
            XCTAssertNotNil(button.image); XCTAssertEqual(button.toolTip, tool.title)
            editor.chooseTool(.select); button.performClick(nil)
            XCTAssertEqual(editor.annotationCanvas.tool, tool, "Direct family button retains the last explicitly selected subtool")
        }
    }

    @MainActor
    func testPathPalettesAndDraftKeepPinnedZoomPanCoordinatesAnchored() throws {
        _ = NSApplication.shared
        let placement = PinEditorPresentation(viewportFrame: CGRect(x: 200, y: 180, width: 320, height: 200),
            imageFrame: CGRect(x: 120, y: 135, width: 480, height: 300), opacity: 0.65, level: .floating)
        let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, onApply: { _ in true })
        defer { editor.close() }; XCTAssertTrue(editor.showPinned(placement))
        for tool in [ImageEditorTool.arc, .sector, .polyline] {
            editor.chooseTool(tool)
            XCTAssertEqual(editor.editorImageScreenFrame, placement.imageFrame)
            XCTAssertEqual(editor.pinnedViewportScreenFrame, placement.viewportFrame)
        }
        try click(editor.annotationCanvas, CGPoint(x: 220, y: 150))
        try click(editor.annotationCanvas, CGPoint(x: 520, y: 380))
        XCTAssertEqual(editor.editorImageScreenFrame, placement.imageFrame)
        editor.annotationCanvas.finishPolyline()
        XCTAssertEqual(editor.editorImageScreenFrame, placement.imageFrame)
        XCTAssertEqual(editor.pinnedViewportScreenFrame, placement.viewportFrame)
        XCTAssertEqual(editor.annotationCanvas.alphaValue, 0.65, accuracy: 0.001)
    }

    @MainActor
    private func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    @MainActor
    private func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    @MainActor
    private func click(_ canvas: ImageEditorCanvas, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point, flags: flags))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point, flags: flags))
    }
}
