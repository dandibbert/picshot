import AppKit
import XCTest
import PicShotCore
@testable import PicShot

/// Owned NSWindow events only: no screen acquisition, global event posting or TCC.
/// These fixtures require macOS/WindowServer and are not portable execution proof.
final class CaptureRatioInteractionTests: XCTestCase {
    @MainActor
    func testInitialPickerHidesUnusedDimensionsAndConfirmationUntilSelection() throws {
        _ = NSApplication.shared
        let source = try image(width: 1280, height: 800)
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 640, height: 400), pixelWidth: 1280, pixelHeight: 800)
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), frozenImage: source, geometry: geometry)
        let window = host(view); defer { view.discard(); window.close() }
        view.finished = { _ in }
        let controls = try XCTUnwrap(descendants(view).compactMap { $0 as? CaptureRatioControls }.first)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(controls.preset.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(controls.widthField.isHiddenOrHasHiddenAncestor)
        let initialAccept = descendants(view).first { $0.identifier?.rawValue == "capture.ratioAccept" }
        XCTAssertTrue(initialAccept?.isHiddenOrHasHiddenAncestor ?? true)
        XCTAssertTrue(view.hitTest(view.convert(CGPoint(x: 300, y: 120), to: view.superview)) === view)
        XCTAssertTrue(view.setAspectRatio(try CaptureAspectRatio(numerator: 16, denominator: 9)))
        try drag(view, CGPoint(x: 100, y: 180), CGPoint(x: 260, y: 270))
        view.layoutSubtreeIfNeeded()
        let accept = try XCTUnwrap(descendants(view).first { $0.identifier?.rawValue == "capture.ratioAccept" } as? NSButton)
        XCTAssertFalse(controls.widthField.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(accept.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(accept.isEnabled)
    }

    @MainActor
    func testFrozenSelectorLocksEveryQuadrantAndCarriesExactPixelsAtFractionalDensity() throws {
        _ = NSApplication.shared
        let source = try image(width: 1397, height: 911)
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 1000, height: 700), pixelWidth: source.width, pixelHeight: source.height)
        let aspect = try CaptureAspectRatio(numerator: 16, denominator: 9)
        for dx in [-1.0, 1.0] { for dy in [-1.0, 1.0] {
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize), frozenImage: source, geometry: geometry)
            let window = host(view); defer { view.discard(); window.close() }
            var result: CGRect?
            view.finished = { result = try? $0.get() }
            XCTAssertTrue(view.setAspectRatio(aspect))
            let start = CGPoint(x: 500.25, y: 350.25), end = CGPoint(x: 500.25 + dx * 100, y: 350.25 + dy * 70)
            try drag(view, start, end)
            XCTAssertNil(result, "Locked selection stays available for numeric refinement before Return")
            view.keyDown(with: try key(view, code: 36))
            let pixels = try XCTUnwrap(view.committedPixelFrame)
            XCTAssertEqual(pixels.width * 9, pixels.height * 16)
            let selected = try XCTUnwrap(result)
            XCTAssertEqual(selected, try geometry.selectionForPixels(pixels).topLeftFrame)
            let capture = try CapturedImage.frozenPixelRegion(image: source, displayID: 3,
                displayFrame: CGRect(x: -1100, y: 75, width: 1000, height: 700), pixelFrame: pixels, aspectRatio: view.aspectRatio)
            XCTAssertEqual(capture.image.width, Int(pixels.width)); XCTAssertEqual(capture.image.height, Int(pixels.height))
            XCTAssertEqual(capture.presentation?.aspectRatio, aspect)
            XCTAssertEqual(capture.presentation?.displayFrame.origin, CGPoint(x: -1100, y: 75))
            XCTAssertTrue(capture.presentation?.frozenImage === source)
            XCTAssertEqual(try pixel(capture.image, x: 0, y: 0), color(x: Int(pixels.minX), y: Int(pixels.minY)))
        } }
    }

    @MainActor
    func testSelectorPresetCustomSwapUnlockNumericUndoAndRedoUseNativeControls() throws {
        _ = NSApplication.shared
        let source = try image(width: 1000, height: 700)
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 1000, height: 700), pixelWidth: 1000, pixelHeight: 700)
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize), frozenImage: source, geometry: geometry)
        let window = host(view); defer { view.discard(); window.close() }
        var completed = 0; view.finished = { _ in completed += 1 }
        let controls = try XCTUnwrap(descendants(view).compactMap { $0 as? CaptureRatioControls }.first)
        controls.preset.selectItem(at: CaptureAspectRatio.presets.count + 1)
        send(controls.preset)
        controls.numerator.stringValue = "1920"; controls.numerator.currentEditor()?.string = "1920"
        controls.denominator.stringValue = "1080"
        try button("capture.ratioApply", in: view).performClick(nil)
        XCTAssertEqual(view.aspectRatio?.label, "16:9")
        try drag(view, CGPoint(x: 300, y: 300), CGPoint(x: 490, y: 410))
        controls.widthField.stringValue = "97"; controls.heightField.stringValue = "108"
        send(controls.widthField)
        XCTAssertEqual(view.selected.size, CGSize(width: 96, height: 54))
        try button("capture.ratioSwap", in: view).performClick(nil)
        XCTAssertEqual(view.aspectRatio?.label, "9:16")
        XCTAssertEqual(view.selected.width * 16, view.selected.height * 9)
        view.keyDown(with: try key(view, code: 6, flags: .command))
        XCTAssertEqual(view.aspectRatio?.label, "16:9"); XCTAssertEqual(view.selected.size, CGSize(width: 96, height: 54))
        view.keyDown(with: try key(view, code: 6, flags: [.command, .shift]))
        XCTAssertEqual(view.aspectRatio?.label, "9:16")
        controls.preset.selectItem(at: 0); send(controls.preset)
        XCTAssertNil(view.aspectRatio)
        controls.widthField.stringValue = "101"; controls.heightField.stringValue = "73"
        send(controls.widthField)
        XCTAssertEqual(view.selected.size, CGSize(width: 101, height: 73)); XCTAssertEqual(completed, 0)
        view.keyDown(with: try key(view, code: 53))
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(view.setAspectRatio(try CaptureAspectRatio(numerator: 1, denominator: 1)))
        view.keyDown(with: try key(view, code: 36)); XCTAssertEqual(completed, 1)
    }

    @MainActor
    func testSelectorRejectsInvalidCustomAndHugeNumericWithoutChangingSelection() throws {
        _ = NSApplication.shared
        let source = try image(width: 1000, height: 700)
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 1000, height: 700), pixelWidth: 1000, pixelHeight: 700)
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize), frozenImage: source, geometry: geometry)
        let window = host(view); defer { view.discard(); window.close() }
        view.finished = { _ in }
        XCTAssertTrue(view.setAspectRatio(try CaptureAspectRatio(numerator: 4, denominator: 3)))
        try drag(view, CGPoint(x: 300, y: 300), CGPoint(x: 460, y: 420))
        let original = view.selected, ratio = view.aspectRatio
        let controls = try XCTUnwrap(descendants(view).compactMap { $0 as? CaptureRatioControls }.first)
        for value in ["0", "-1", "1.5", "10001", "9999999999999999999999999"] {
            controls.preset.selectItem(at: CaptureAspectRatio.presets.count + 1); send(controls.preset)
            controls.numerator.stringValue = value; controls.numerator.currentEditor()?.string = value; controls.denominator.stringValue = "9"
            try button("capture.ratioApply", in: view).performClick(nil)
            XCTAssertEqual(view.selected, original); XCTAssertEqual(view.aspectRatio, ratio)
        }
        XCTAssertFalse(view.setPixelSize(width: Int.max, height: Int.max, axis: .width))
        XCTAssertFalse(view.setPixelSize(width: 0, height: 2, axis: .width))
        XCTAssertFalse(view.setAspectRatio(try CaptureAspectRatio(numerator: 10000, denominator: 9999)))
        XCTAssertEqual(view.selected, original); XCTAssertEqual(view.aspectRatio, ratio)
        view.keyDown(with: try key(view, code: 124))
        XCTAssertEqual(view.selected.minX, original.minX + 1)
        view.keyDown(with: try key(view, code: 124, flags: .option))
        XCTAssertEqual(view.selected.width, original.width + 4)
        XCTAssertEqual(view.selected.height, original.height + 3)
    }

    @MainActor
    func testSelectorEscapeDuringLockedDragCancelsEntireCapture() throws {
        _ = NSApplication.shared
        let source = try image(width: 1000, height: 700)
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 1000, height: 700), pixelWidth: 1000, pixelHeight: 700)
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize), frozenImage: source, geometry: geometry)
        let window = host(view); defer { view.discard(); window.close() }
        var failures = 0
        view.finished = { if case .failure = $0 { failures += 1 } }
        XCTAssertTrue(view.setAspectRatio(try CaptureAspectRatio(numerator: 1, denominator: 1)))
        view.mouseDown(with: try mouse(.leftMouseDown, view, CGPoint(x: 300, y: 300)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, view, CGPoint(x: 400, y: 400)))
        view.keyDown(with: try key(view, code: 53))
        view.mouseUp(with: try mouse(.leftMouseUp, view, CGPoint(x: 400, y: 400)))
        view.keyDown(with: try key(view, code: 36)); XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testMultiRegionRatioDragResizeCutoutNumericAndUndoPreserveOperationOrder() throws {
        _ = NSApplication.shared
        let source = try image(width: 1400, height: 1050)
        let geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 1000, height: 700), pixelWidth: source.width, pixelHeight: source.height)
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize), image: source, style: .multiRegion, geometry: geometry)
        let window = host(view); defer { view.discard(); window.close() }
        XCTAssertTrue(view.setAspectRatio(try CaptureAspectRatio(numerator: 4, denominator: 3)))
        try drag(view, CGPoint(x: 200, y: 300), CGPoint(x: 400, y: 450))
        let first = view.selection.operations
        XCTAssertEqual(first.count, 1)
        let firstPixels = try XCTUnwrap(view.selection.rectanglePixelBounds(first[0].shape.bounds))
        XCTAssertEqual(firstPixels.width * 3, firstPixels.height * 4)
        let handle = CaptureRatioHandle.maxXMaxY.point(in: first[0].shape.bounds)
        try drag(view, handle, CGPoint(x: handle.x + 40, y: handle.y + 40))
        XCTAssertEqual(view.selection.operations.count, 1)
        XCTAssertNotEqual(view.selection.operations, first)
        view.keyDown(with: try key(view, code: 6, flags: .command))
        XCTAssertEqual(view.selection.operations, first)
        view.keyDown(with: try key(view, code: 6, flags: [.command, .shift]))
        XCTAssertNotEqual(view.selection.operations, first)
        try drag(view, CGPoint(x: 240, y: 340), CGPoint(x: 280, y: 380), flags: .option)
        XCTAssertEqual(view.selection.operations.count, 2); XCTAssertTrue(view.selection.operations[1].subtracts)
        let width = try field("capturePixelWidth", in: view), height = try field("capturePixelHeight", in: view)
        width.stringValue = "97"; height.stringValue = "73"; send(width)
        let cutout = try XCTUnwrap(view.selection.rectanglePixelBounds(view.selection.operations[1].shape.bounds))
        XCTAssertEqual(cutout.size, CGSize(width: 96, height: 72))
        XCTAssertTrue(view.selection.operations[1].subtracts)
        XCTAssertTrue(view.setAspectRatio(nil))
        view.keyDown(with: try key(view, code: 6, flags: .command))
        XCTAssertEqual(view.aspectRatio?.label, "4:3")
        let before = view.selection.operations
        view.cancelOperation(nil)
        XCTAssertTrue(view.selection.isCancelled)
        XCTAssertFalse(view.setAspectRatio(nil))
        view.keyDown(with: try key(view, code: 6, flags: [.command, .shift]))
        XCTAssertTrue(view.selection.operations.isEmpty); XCTAssertEqual(before.count, 2)
    }

    @MainActor
    func testMultiRegionClickStillSelectsPriorShapeWhileLockIsActive() throws {
        _ = NSApplication.shared
        var geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 1000, height: 700), pixelWidth: 1000, pixelHeight: 700)
        try geometry.append(.rectangle(CGRect(x: 100, y: 300, width: 120, height: 90)))
        try geometry.append(.rectangle(CGRect(x: 400, y: 300, width: 120, height: 90)))
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize), image: try image(width: 1000, height: 700), style: .multiRegion, geometry: geometry)
        let window = host(view); defer { view.discard(); window.close() }
        XCTAssertTrue(view.setAspectRatio(try CaptureAspectRatio(numerator: 4, denominator: 3)))
        try drag(view, CGPoint(x: 160, y: 345), CGPoint(x: 160, y: 345))
        XCTAssertEqual(view.selectedOperationIndex, 0); XCTAssertEqual(view.selection.operations.count, 2)
    }

    @MainActor
    func testEveryNativeBoundaryHandleKeepsExactRatioAndPreviewSharesRaster() throws {
        for handle in EditorBoundaryHandle.allCases {
            let editor = try makeEditor(); defer { editor.close() }
            let canvas = editor.annotationCanvas, workspace = editor.captureBoundaryWorkspace
            let initial = editor.editorSelectionFrame, original = canvas.image
            let start = handle.point(in: initial)
            let end = CGPoint(x: start.x + (start.x < initial.midX ? -25 : 25), y: start.y + (start.y < initial.midY ? -20 : 20))
            workspace.mouseDown(with: try mouse(.leftMouseDown, workspace, start))
            let preview = workspace.boundaryPreviewImage
            for step in 1...5 {
                let current = CGPoint(x: start.x + (end.x - start.x) * CGFloat(step) / 5,
                                      y: start.y + (end.y - start.y) * CGFloat(step) / 5)
                workspace.mouseDragged(with: try mouse(.leftMouseDragged, workspace, current))
                XCTAssertTrue(canvas.image === original)
                XCTAssertTrue(workspace.boundaryPreviewImage === preview, "Dragging must reuse the original crop preview")
                XCTAssertEqual(workspace.pixelSize.width * 9, workspace.pixelSize.height * 16)
            }
            workspace.mouseUp(with: try mouse(.leftMouseUp, workspace, end))
            XCTAssertEqual(canvas.image.width * 9, canvas.image.height * 16)
            XCTAssertEqual(editor.captureAspectRatio?.label, "16:9")
            XCTAssertNotEqual(editor.editorSelectionFrame, initial)
            try undo(editor)
            XCTAssertEqual(editor.editorSelectionFrame, initial); XCTAssertTrue(canvas.image === original)
            XCTAssertEqual(editor.captureAspectRatio?.label, "16:9")
            try undo(editor, redo: true)
            XCTAssertEqual(canvas.image.width * 9, canvas.image.height * 16)
        }
    }

    @MainActor
    func testBoundaryRatioOnlyUndoSharesImageAndCancelPreservesRedoAndAnchors() throws {
        let editor = try makeEditor(); defer { editor.close() }
        let canvas = editor.annotationCanvas, workspace = editor.captureBoundaryWorkspace
        var mark = ImageAnnotation(tool: .arrow, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 50)])
        mark.rotation = 0.2; canvas.add(mark)
        let original = canvas.image, frame = editor.editorSelectionFrame
        XCTAssertTrue(editor.setCaptureAspectRatio(nil))
        XCTAssertTrue(canvas.image === original)
        try undo(editor); XCTAssertEqual(editor.captureAspectRatio?.label, "16:9"); XCTAssertTrue(canvas.image === original)
        let start = EditorBoundaryHandle.left.point(in: frame)
        workspace.mouseDown(with: try mouse(.leftMouseDown, workspace, start))
        workspace.mouseDragged(with: try mouse(.leftMouseDragged, workspace, CGPoint(x: start.x - 50, y: start.y)))
        workspace.keyDown(with: try key(workspace, code: 53))
        workspace.mouseUp(with: try mouse(.leftMouseUp, workspace, start))
        XCTAssertEqual(editor.editorSelectionFrame, frame); XCTAssertTrue(canvas.image === original)
        XCTAssertEqual(canvas.annotations[0].points, mark.points)
        try undo(editor, redo: true); XCTAssertNil(editor.captureAspectRatio)
        XCTAssertTrue(editor.setCaptureAspectRatio(try CaptureAspectRatio(numerator: 4, denominator: 3)))
        let after = editor.editorSelectionFrame
        let sx = CGFloat(workspace.frozenImage!.width) / workspace.bounds.width
        let sy = CGFloat(workspace.frozenImage!.height) / workspace.bounds.height
        XCTAssertEqual(after.minX + canvas.annotations[0].points[0].x / sx, frame.minX + mark.points[0].x / sx, accuracy: 1e-7)
        XCTAssertEqual(after.minY + canvas.annotations[0].points[0].y / sy, frame.minY + mark.points[0].y / sy, accuracy: 1e-7)
        XCTAssertEqual(canvas.annotations[0].id, mark.id); XCTAssertEqual(canvas.annotations[0].rotation, mark.rotation)
    }

    @MainActor
    func testEditorPaletteIsReachableAtEdgesAndDoesNotChangeAnnotationShapeTools() throws {
        let editor = try makeEditor(); defer { editor.close() }
        let root = try XCTUnwrap(editor.window?.contentView)
        try button("editor.captureRatio", in: root).performClick(nil)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        let palette = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "editor.captureRatioPalette" })
        XCTAssertFalse(palette.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(root.bounds.contains(editor.captureRatioPaletteFrame))
        XCTAssertFalse(editor.captureRatioPaletteFrame.intersects(editor.floatingToolbarFrame))
        XCTAssertFalse(editor.captureRatioPaletteFrame.intersects(editor.dimensionLabelFrame))
        let controls = try XCTUnwrap(descendants(palette).compactMap { $0 as? CaptureRatioControls }.first)
        controls.heightField.stringValue = "181"; send(controls.heightField)
        XCTAssertEqual(editor.annotationCanvas.image.height, 180)
        XCTAssertEqual(editor.annotationCanvas.image.width, 320)
        editor.chooseTool(.rectangle)
        XCTAssertTrue(palette.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(editor.annotationCanvas.tool, .rectangle)
        XCTAssertEqual(editor.captureAspectRatio?.label, "16:9")
        XCTAssertFalse(editor.setCapturePixelSize(width: Int.max, height: 20, axis: .width))
        XCTAssertEqual(editor.annotationCanvas.image.width, 320)
    }

    func testFractionalBoundaryCropUsesExactPixelsAndPreservesFrozenSourceBytes() throws {
        let source = try image(width: 1397, height: 911)
        let sourceBytes = try XCTUnwrap(source.dataProvider?.data)
        let aspect = try CaptureAspectRatio(numerator: 16, denominator: 9)
        let capture = try CapturedImage.frozenPixelRegion(image: source, displayID: 7,
            displayFrame: CGRect(x: -1000, y: 100, width: 1000, height: 700),
            pixelFrame: CGRect(x: 101, y: 97, width: 320, height: 180), aspectRatio: aspect)
        let presentation = try XCTUnwrap(capture.presentation)
        let geometry = try CaptureRatioGeometry(pointSize: presentation.displayFrame.size, pixelWidth: source.width, pixelHeight: source.height)
        let frame = try geometry.resize(presentation.selectionFrame, handle: .maxXMaxY,
            to: CGPoint(x: presentation.selectionFrame.maxX + 50, y: presentation.selectionFrame.maxY + 50), ratio: aspect)
        let output = try EditorBoundaryRenderer.recrop(frame, presentation: presentation, previousImage: capture.image)
        let expected = try geometry.sourcePixelRect(frame)
        XCTAssertEqual(output.image.width, Int(expected.width)); XCTAssertEqual(output.image.height, Int(expected.height))
        XCTAssertEqual(output.image.width * 9, output.image.height * 16)
        XCTAssertEqual(output.image.bytesPerRow, output.image.width * 4)
        XCTAssertEqual(CFDataGetLength(try XCTUnwrap(output.image.dataProvider?.data)), output.image.width * output.image.height * 4)
        XCTAssertEqual(try XCTUnwrap(source.dataProvider?.data) as Data, sourceBytes as Data)
        XCTAssertTrue(output.presentation?.frozenImage === source)
        XCTAssertEqual(output.presentation?.displayFrame, presentation.displayFrame)
        XCTAssertThrowsError(try CapturedImage.frozenPixelRegion(image: source, displayID: 7,
            displayFrame: presentation.displayFrame, pixelFrame: CGRect(x: 1, y: 1, width: 321, height: 180), aspectRatio: aspect))
    }

    @MainActor
    private func makeEditor() throws -> ImageEditorController {
        _ = NSApplication.shared
        let source = try image(width: 1397, height: 911)
        let capture = try CapturedImage.frozenPixelRegion(image: source, displayID: 7,
            displayFrame: CGRect(x: -1000, y: 100, width: 1000, height: 700), pixelFrame: CGRect(x: 320, y: 340, width: 320, height: 180),
            aspectRatio: CaptureAspectRatio(numerator: 16, denominator: 9))
        let editor = ImageEditorController(image: capture.image, presentation: capture.presentation, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded(); return editor
    }
    @MainActor private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; view.layoutSubtreeIfNeeded(); return window
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func field(_ id: String, in view: NSView) throws -> NSTextField {
        try XCTUnwrap(descendants(view).first { $0.identifier?.rawValue == id } as? NSTextField)
    }
    @MainActor private func button(_ id: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).first { $0.identifier?.rawValue == id } as? NSButton)
    }
    @MainActor private func send(_ control: NSControl) { _ = control.sendAction(control.action, to: control.target) }
    @MainActor private func mouse(_ type: NSEvent.EventType, _ view: NSView, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @MainActor private func drag(_ view: NSView, _ from: CGPoint, _ to: CGPoint, flags: NSEvent.ModifierFlags = []) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, view, from, flags: flags))
        view.mouseDragged(with: try mouse(.leftMouseDragged, view, to, flags: flags))
        view.mouseUp(with: try mouse(.leftMouseUp, view, to, flags: flags))
    }
    @MainActor private func key(_ view: NSView, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let value = code == 6 ? "z" : ""
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
    @MainActor private func undo(_ editor: ImageEditorController, redo: Bool = false) throws {
        XCTAssertTrue(editor.annotationCanvas.performKeyEquivalent(with: try key(editor.annotationCanvas, code: 6, flags: redo ? [.command, .shift] : .command)))
    }
    private func image(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes.append(contentsOf: color(x: x, y: y)) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func color(x: Int, y: Int) -> [UInt8] { [UInt8((x * 3 + 17) % 256), UInt8((y * 7 + 31) % 256), UInt8((x + y * 2 + 43) % 256), 255] }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        return try withExtendedLifetime(data) {
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            return Array(UnsafeBufferPointer(start: bytes.advanced(by: y * image.bytesPerRow + x * 4), count: 4))
        }
    }
}
