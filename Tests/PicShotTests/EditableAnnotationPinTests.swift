import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor final class EditableAnnotationPinTests: XCTestCase {
    func testHiddenPreviewPreservesCropDecorationAndNormalCopyNeverExportsSource() async throws {
        let fixture = try Fixture(decorated: true); defer { fixture.close() }
        let pin = try XCTUnwrap(fixture.session.liveControllers[fixture.id])
        let saved = fixture.store.index
        let reopenedStore = try PinSessionStore(directory: fixture.directory)
        let loaded = try XCTUnwrap(reopenedStore.editablePayload(id: fixture.id))
        let replayEditor = EditableUIFixtures.editor(loaded.baseImage)
        defer { replayEditor.close() }
        try replayEditor.restoreEditablePayload(loaded)
        let replay = try ImageOutputDecorationRenderer.project(flattened: XCTUnwrap(replayEditor.annotationCanvas.flattened()),
            decoration: replayEditor.outputDecoration)
        XCTAssertEqual(try EditableUIFixtures.bytes(replay),
            try EditableUIFixtures.bytes(XCTUnwrap(reopenedStore.image(id: fixture.id))),
            "The persisted current raster must exactly equal rendering the restored layers, viewport and decoration")
        replayEditor.close()
        try pin.setAnnotationsHidden(true); try await drain(pin)
        XCTAssertTrue(pin.annotationsHidden)
        XCTAssertEqual(pin.displayedImage.width, fixture.current.width)
        XCTAssertEqual(pin.displayedImage.height, fixture.current.height)
        let expected = try ImageOutputDecorationRenderer.project(flattened: EditableCapturePresentation.visibleBase(fixture.payload),
            decoration: fixture.payload.document.outputDecoration)
        XCTAssertEqual(try EditableUIFixtures.bytes(pin.displayedImage), try EditableUIFixtures.bytes(expected))
        XCTAssertNotEqual(try EditableUIFixtures.bytes(pin.displayedImage), try EditableUIFixtures.bytes(pin.currentImage))
        XCTAssertEqual(fixture.store.index, saved, "Preview visibility must never rewrite saved layers or pixels")
        XCTAssertEqual(pin.retainedEditableBaseCount, 0)
        XCTAssertEqual(pin.retainedAnnotationPreviewCount, 1)
        // Real keyboard copy on the pin remains the annotated projection while hidden.
        let canvas = try pinCanvas(pin)
        canvas.keyDown(with: try EditableUIFixtures.key(canvas, "c", code: 8, modifiers: .command))
        let png = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        let copied = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
        XCTAssertEqual(try EditableUIFixtures.bytes(copied), try EditableUIFixtures.bytes(fixture.current))
        EditableUIFixtures.action("copyOriginal", pin)
        let original = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(NSPasteboard.general.data(forType: .png)))?.cgImage)
        XCTAssertEqual(try EditableUIFixtures.bytes(original), try EditableUIFixtures.bytes(fixture.source))
        try pin.setAnnotationsHidden(false)
        XCTAssertTrue(pin.displayedImage === pin.currentImage)
        XCTAssertEqual(pin.retainedAnnotationPreviewCount, 0)
    }

    func testSpaceReopensSavedLayersCancelRestoresHiddenPreviewAndApplyCommitsFirst() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let pin = try XCTUnwrap(fixture.session.liveControllers[fixture.id])
        pin.showWindow(nil)
        try pin.setAnnotationsHidden(true)
        let canvas = try pinCanvas(pin)
        canvas.keyDown(with: try EditableUIFixtures.key(canvas, " ", code: 49))
        var editor = try XCTUnwrap(pin.annotationEditor)
        XCTAssertEqual(editor.annotationCanvas.annotations.map(\.id), fixture.payload.document.annotations.map(\.id))
        XCTAssertEqual(editor.annotationCanvas.cropViewportInBase, fixture.payload.document.cropViewportInBase)
        XCTAssertFalse(pin.annotationsHidden)
        editor.annotationCanvas.add(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 70, y: 80), CGPoint(x: 100, y: 105)]))
        editor.annotationCanvas.keyDown(with: try EditableUIFixtures.key(editor.annotationCanvas, "\u{1b}", code: 53))
        XCTAssertNil(pin.annotationEditor); XCTAssertTrue(pin.annotationsHidden)
        XCTAssertEqual(try fixture.store.editablePayload(id: fixture.id)?.document.annotations.count, fixture.payload.document.annotations.count)
        XCTAssertEqual(try EditableUIFixtures.bytes(pin.currentImage), try EditableUIFixtures.bytes(fixture.current))

        canvas.keyDown(with: try EditableUIFixtures.key(canvas, " ", code: 49))
        editor = try XCTUnwrap(pin.annotationEditor)
        editor.annotationCanvas.add(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 70, y: 80), CGPoint(x: 100, y: 105)]))
        let draft = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
        let manifest = fixture.directory.appendingPathComponent("index.json")
        let manifestBytes = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        var errors = 0; pin.onAnnotationError = { _ in errors += 1 }
        try EditableUIFixtures.click("editor.applyToPin", editor: editor)
        XCTAssertEqual(errors, 1); XCTAssertTrue(pin.annotationEditor === editor); XCTAssertFalse(editor.isClosed)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document), draft)
        XCTAssertEqual(try EditableUIFixtures.bytes(pin.currentImage), try EditableUIFixtures.bytes(fixture.current))
        try FileManager.default.removeItem(at: manifest); try manifestBytes.write(to: manifest, options: .atomic)
        try EditableUIFixtures.click("editor.applyToPin", editor: editor)
        XCTAssertNil(pin.annotationEditor); XCTAssertFalse(pin.annotationsHidden)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(XCTUnwrap(fixture.store.editablePayload(id: fixture.id)).document), draft)
        XCTAssertEqual(try EditableUIFixtures.bytes(XCTUnwrap(fixture.store.image(id: fixture.id))), try EditableUIFixtures.bytes(pin.currentImage))
    }

    func testHiddenCloseReopenAndRestartAlwaysRevealSavedDocumentWithoutRasterCaches() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let before = try EditableAnnotationDocumentCodec.encode(fixture.payload.document)
        var old: PinController? = fixture.session.liveControllers[fixture.id]
        weak var probe = old
        try old?.setAnnotationsHidden(true)
        old?.close(); old = nil
        try fixture.session.openPin(id: fixture.id)
        let reopened = try XCTUnwrap(fixture.session.liveControllers[fixture.id])
        XCTAssertFalse(reopened.annotationsHidden); XCTAssertTrue(reopened.hasEditableCapture)
        XCTAssertEqual(reopened.retainedEditableBaseCount, 0); XCTAssertEqual(reopened.retainedAnnotationPreviewCount, 0)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(probe)
        try fixture.session.prepareForTermination()
        let restoredStore = try PinSessionStore(directory: fixture.directory)
        let restored = PinSessionCoordinator(store: restoredStore, presentWindows: false)
        defer { try? restored.prepareForTermination() }
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        let restarted = try XCTUnwrap(restored.liveControllers[fixture.id])
        XCTAssertFalse(restarted.annotationsHidden)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(XCTUnwrap(restoredStore.editablePayload(id: fixture.id)).document), before)
        XCTAssertEqual(try EditableUIFixtures.bytes(restarted.currentImage), try EditableUIFixtures.bytes(fixture.current))
    }

    func testRepeatedHideShowSpaceCancelHasBoundedPreviewAndReleasesEachEditor() async throws {
        let fixture = try Fixture(decorated: true); defer { fixture.close() }
        let pin = try XCTUnwrap(fixture.session.liveControllers[fixture.id])
        pin.showWindow(nil)
        let bytes = try EditableAnnotationDocumentCodec.encode(fixture.payload.document)
        for _ in 0..<16 {
            try pin.setAnnotationsHidden(true); try await drain(pin)
            XCTAssertEqual(pin.retainedAnnotationPreviewCount, 1); XCTAssertEqual(pin.retainedEditableBaseCount, 0)
            weak var editorProbe: ImageEditorController?
            weak var contentProbe: NSView?
            try autoreleasepool {
                let canvas = try pinCanvas(pin)
                canvas.keyDown(with: try EditableUIFixtures.key(canvas, " ", code: 49))
                let editor = try XCTUnwrap(pin.annotationEditor)
                editorProbe = editor; contentProbe = editor.window?.contentView
                XCTAssertEqual(editor.retainedUndoRasterCount, 0)
                XCTAssertEqual(pin.retainedAnnotationPreviewCount, 0)
                try EditableUIFixtures.click("editor.cancel", editor: editor)
                XCTAssertNil(pin.annotationEditor)
            }
            try await drain(pin)
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertNil(editorProbe); XCTAssertNil(contentProbe)
            try pin.setAnnotationsHidden(false)
            XCTAssertEqual(pin.retainedAnnotationPreviewCount, 0)
            XCTAssertEqual(pin.retainedEditableBaseCount, 0)
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(XCTUnwrap(fixture.store.editablePayload(id: fixture.id)).document), bytes)
        }
        XCTAssertFalse(EditorOutputProjection.shared.isBusy)
    }

    func testPinCropRoutesToEditableViewportAndFlatteningTransformHasHonestProvenance() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let pin = try XCTUnwrap(fixture.session.liveControllers[fixture.id])
        pin.showWindow(nil)
        EditableUIFixtures.action("toggleCrop", pin)
        let editor = try XCTUnwrap(pin.annotationEditor)
        XCTAssertEqual(editor.annotationCanvas.tool, .crop)
        XCTAssertEqual(editor.annotationCanvas.annotations.map(\.id), fixture.payload.document.annotations.map(\.id))
        editor.close()
        let menu = try XCTUnwrap(pin.actionMenu)
        for submenu in menu.items.compactMap(\.submenu) { pin.menuNeedsUpdate(submenu) }
        let processing = try XCTUnwrap(menu.items.first { $0.title == "图像处理" }?.submenu)
        XCTAssertTrue(processing.items.first?.title.contains("合并标注") == true)
        try pin.applyTransform(.invert)
        let transformed = try XCTUnwrap(fixture.store.editablePayload(id: fixture.id))
        XCTAssertEqual(transformed.document.baseProvenance, .derivedRaster)
        XCTAssertTrue(transformed.document.annotations.isEmpty)
        XCTAssertNil(transformed.document.cropViewportInBase)
        XCTAssertEqual(transformed.document.outputDecoration, .none)
        XCTAssertEqual(try EditableUIFixtures.bytes(transformed.baseImage), try EditableUIFixtures.bytes(pin.currentImage))
        XCTAssertEqual(try EditableUIFixtures.bytes(pin.image), try EditableUIFixtures.bytes(fixture.source))
        try pin.restoreOriginalImage()
        XCTAssertFalse(pin.hasEditableCapture)
        XCTAssertNil(try fixture.store.editablePayload(id: fixture.id))
        XCTAssertEqual(try EditableUIFixtures.bytes(pin.currentImage), try EditableUIFixtures.bytes(fixture.source))
    }

    func testMissingEditableAssetsRefuseReopenAndKeepSavedRaster() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let pin = try XCTUnwrap(fixture.session.liveControllers[fixture.id])
        pin.configureEditableCapture(available: true, load: { nil })
        var errors = 0; pin.onAnnotationError = { _ in errors += 1 }
        pin.showAnnotations()
        XCTAssertNil(pin.annotationEditor); XCTAssertEqual(errors, 1)
        XCTAssertThrowsError(try pin.setAnnotationsHidden(true))
        XCTAssertFalse(pin.annotationsHidden)
        XCTAssertEqual(try EditableUIFixtures.bytes(pin.currentImage), try EditableUIFixtures.bytes(fixture.current))
    }

    private func pinCanvas(_ pin: PinController) throws -> PinCanvas {
        try XCTUnwrap(EditableUIFixtures.descendants(pin.window?.contentView).compactMap { $0 as? PinCanvas }.first)
    }
    private func drain(_ pin: PinController) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while pin.annotationVisibilityIsPending && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(pin.annotationVisibilityIsPending)
    }

    @MainActor private final class Fixture {
        let directory: URL
        let store: PinSessionStore
        let session: PinSessionCoordinator
        let source: CGImage
        let current: CGImage
        let payload: EditableCapturePayload
        let id: UUID
        init(decorated: Bool = false) throws {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("editable-pin-" + UUID().uuidString)
            source = try EditableUIFixtures.source()
            let editor = EditableUIFixtures.editor(source); defer { editor.close() }
            editor.annotationCanvas.setContent(image: source, annotations: EditableUIFixtures.marks())
            editor.annotationCanvas.cropRect = CGRect(x: 48, y: 32, width: 192, height: 128)
            EditableUIFixtures.action("applyCrop", editor)
            if decorated {
                _ = try editor.applyOutputDecoration(ImageOutputDecoration(enabled: true, cornerRadius: 9,
                    borderEnabled: true, borderWidth: 2, shadowEnabled: true, shadowBlur: 2,
                    shadowOffsetX: 4, shadowOffsetY: 3))
            }
            payload = try editor.editablePayload()
            current = try ImageOutputDecorationRenderer.project(flattened: XCTUnwrap(editor.annotationCanvas.flattened()),
                decoration: payload.document.outputDecoration)
            store = try PinSessionStore(directory: directory)
            session = PinSessionCoordinator(store: store, presentWindows: false,
                makeImageController: { PinController(originalImage: $0, currentImage: $1, isModified: $2, defaults: nil) })
            id = try session.add(originalImage: source, currentImage: current, editable: payload)
        }
        func close() { try? session.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
    }
}
