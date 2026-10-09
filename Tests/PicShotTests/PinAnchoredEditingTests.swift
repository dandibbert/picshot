import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class PinAnchoredEditingTests: XCTestCase {
    @MainActor func testAnchoredEditorKeepsZoomPanAndImageAtExactScreenCoordinates() throws {
        _ = NSApplication.shared
        let controller = PinController(image: try raster()); defer { controller.close() }
        let saved = PinPresentation(frame: PinWindowFrame(x: 140, y: 160, width: 240, height: 140), opacity: 0.55, zoom: 2)
        controller.applyPresentation(saved); controller.bringForward()
        let originalWindow = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(originalWindow.contentView)
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 36, y: 24)); scroll.reflectScrolledClipView(scroll.contentView)
        let expected = try XCTUnwrap(controller.annotationPresentation)
        XCTAssertEqual(expected.imageFrame.width, 640, accuracy: 0.01)
        XCTAssertLessThan(expected.imageFrame.minX, expected.viewportFrame.minX)
        let before = controller.presentation
        controller.showAnnotations()
        let editor = try XCTUnwrap(controller.annotationEditor), editorWindow = try XCTUnwrap(editor.window)
        XCTAssertFalse(originalWindow.isVisible); XCTAssertTrue(editorWindow.isVisible)
        XCTAssertFalse(editorWindow.styleMask.contains(.titled)); XCTAssertFalse(editorWindow.isOpaque)
        XCTAssertTrue(editorWindow.canBecomeKey); XCTAssertNil(editor.captureBoundaryWorkspace.frozenImage)
        XCTAssertEqual(editorWindow.backgroundColor.alphaComponent, 0, accuracy: 0.001)
        let actualImage = editorWindow.convertToScreen(editor.annotationCanvas.convert(editor.annotationCanvas.bounds, to: nil))
        assertRect(actualImage, equals: expected.imageFrame)
        assertRect(try XCTUnwrap(editor.editorImageScreenFrame), equals: expected.imageFrame)
        assertRect(try XCTUnwrap(editor.pinnedViewportScreenFrame), equals: expected.viewportFrame)
        XCTAssertEqual(editor.annotationCanvas.alphaValue, expected.opacity, accuracy: 0.001)
        XCTAssertEqual(controller.presentation, before, "Editing must not overwrite the pin's saved frame, zoom, or opacity")
        controller.bringForward()
        XCTAssertFalse(originalWindow.isVisible, "Reopening a live pin must bring its editor forward without duplicating its image")
        editor.close()
        XCTAssertNil(controller.annotationEditor); XCTAssertTrue(originalWindow.isVisible)
        XCTAssertEqual(controller.presentation, before)
    }

    @MainActor func testApplyCommitsOnlyOnceAndCancelLeavesPinPixelsUntouched() throws {
        _ = NSApplication.shared
        let source = try raster(), controller = PinController(image: source); defer { controller.close() }
        controller.bringForward()
        var commits = 0, legacyCommits = 0
        controller.onPixelChange = { _, isOriginal in XCTAssertFalse(isOriginal); legacyCommits += 1 }
        var expectedError: String?, errors: [String] = []
        controller.onAnnotationError = { error in
            errors.append(error.localizedDescription)
            if let expectedError { XCTAssertEqual(error.localizedDescription, expectedError) }
            else { XCTFail("Unexpected annotation error: \(error.localizedDescription)") }
        }
        controller.showAnnotations()
        var editor = try XCTUnwrap(controller.annotationEditor)
        editor.annotationCanvas.add(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 80)]))
        editor.close()
        XCTAssertEqual(commits, 0); XCTAssertTrue(controller.currentImage === source)
        XCTAssertEqual(legacyCommits, 0); XCTAssertTrue(errors.isEmpty)
        controller.showAnnotations(); editor = try XCTUnwrap(controller.annotationEditor)
        editor.annotationCanvas.add(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 30, y: 30), CGPoint(x: 120, y: 90)]))
        let apply = try XCTUnwrap(descendants(try XCTUnwrap(editor.window?.contentView)).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "editor.applyToPin" })
        let draft = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
        // Editable Apply must not flatten its layers into the legacy raster-only callback.
        let refusal = "此贴图尚未连接可编辑标注存储。当前编辑未丢失。"
        expectedError = refusal
        apply.performClick(nil)
        XCTAssertEqual(errors, [refusal])
        expectedError = nil; errors.removeAll()
        XCTAssertEqual(commits, 0); XCTAssertEqual(legacyCommits, 0)
        XCTAssertTrue(controller.currentImage === source); XCTAssertTrue(controller.image === source)
        XCTAssertTrue(controller.annotationEditor === editor); XCTAssertFalse(editor.isClosed)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document), draft)

        // Connect editable persistence and retry the same live draft.
        var committedDraft: Data?
        controller.onEditablePixelChange = { image, payload in
            try payload.validate(currentImage: image)
            XCTAssertTrue(payload.originalImage === source)
            XCTAssertTrue(controller.currentImage === source, "Pixels change only after persistence succeeds")
            committedDraft = try EditableAnnotationDocumentCodec.encode(payload.document)
            commits += 1
        }
        apply.performClick(nil)
        XCTAssertTrue(errors.isEmpty); XCTAssertEqual(legacyCommits, 0)
        XCTAssertEqual(committedDraft, draft)
        XCTAssertEqual(commits, 1); XCTAssertFalse(controller.currentImage === source)
        XCTAssertTrue(controller.image === source); XCTAssertNil(controller.annotationEditor)
        XCTAssertTrue(controller.window?.isVisible == true)
        editor.close(); XCTAssertEqual(commits, 1)
        XCTAssertEqual(legacyCommits, 0); XCTAssertTrue(errors.isEmpty)
    }

    @MainActor func testExplicitHideInvalidatesLateCloseAndNeverResurrectsPin() throws {
        _ = NSApplication.shared
        let controller = PinController(image: try raster()); defer { controller.close() }
        var commits = 0; controller.onPixelChange = { _, _ in commits += 1 }
        controller.bringForward(); controller.showAnnotations()
        let oldEditor = try XCTUnwrap(controller.annotationEditor), lateClose = oldEditor.onClose
        let editorWindow = try XCTUnwrap(oldEditor.window)
        let oldApply = try XCTUnwrap(descendants(try XCTUnwrap(editorWindow.contentView)).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "editor.applyToPin" })
        controller.hideTemporarily()
        XCTAssertNil(controller.annotationEditor); XCTAssertFalse(editorWindow.isVisible)
        XCTAssertNil(editorWindow.contentView); XCTAssertNil(editorWindow.delegate)
        lateClose?(); oldApply.performClick(nil)
        XCTAssertEqual(commits, 0); XCTAssertFalse(controller.window?.isVisible ?? true)
        controller.showAnnotations(); XCTAssertNil(controller.annotationEditor, "A hidden fallback pin cannot reopen its editor implicitly")
        controller.bringForward(); controller.showAnnotations()
        let replacement = try XCTUnwrap(controller.annotationEditor)
        lateClose?()
        XCTAssertTrue(controller.annotationEditor === replacement)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        replacement.close(); XCTAssertTrue(controller.window?.isVisible == true)
    }

    @MainActor func testGroupSwitchClosesAnchoredSurfacesWithoutReopeningHiddenSession() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PinAnchoredEditingTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        defer { try? coordinator.prepareForTermination() }
        let id = try coordinator.add(image: raster()), other = try store.createGroup(name: "Other")
        let controller = try XCTUnwrap(coordinator.liveControllers[id])
        controller.bringForward(); controller.showAnnotations()
        let editor = try XCTUnwrap(controller.annotationEditor), lateClose = editor.onClose
        let pinWindow = try XCTUnwrap(controller.window), editorWindow = try XCTUnwrap(editor.window)
        try coordinator.switchGroup(id: other.id)
        lateClose?()
        XCTAssertNil(coordinator.liveControllers[id]); XCTAssertTrue(store.entry(id: id)?.isVisible == true)
        XCTAssertFalse(pinWindow.isVisible); XCTAssertFalse(editorWindow.isVisible)
        XCTAssertNil(pinWindow.contentView); XCTAssertNil(editorWindow.contentView)
        try coordinator.switchGroup(id: PinGroup.defaultID)
        let replacement = try XCTUnwrap(coordinator.liveControllers[id])
        XCTAssertFalse(replacement === controller); XCTAssertNil(replacement.annotationEditor)
        lateClose?(); XCTAssertFalse(pinWindow.isVisible)
    }

    @MainActor private func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
    private func assertRect(_ actual: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.01, file: file, line: line)
    }
    private func raster() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180)); return try XCTUnwrap(context.makeImage())
    }
}
