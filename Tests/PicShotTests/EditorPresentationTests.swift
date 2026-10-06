import XCTest
import AppKit
@testable import PicShot

final class EditorPresentationTests: XCTestCase {
    func testFloatingStripRightAlignsBelowSelection() {
        let frames = EditorFloatingLayout.frames(selection: CGRect(x: 200, y: 220, width: 720, height: 420),
            available: CGRect(x: 0, y: 0, width: 1200, height: 800), toolbarSize: CGSize(width: 690, height: 40),
            paletteSize: CGSize(width: 410, height: 38), activeToolOffset: 80)
        XCTAssertEqual(frames.toolbar.maxX, 920)
        XCTAssertEqual(frames.toolbar.maxY, 212)
        XCTAssertEqual(frames.toolbar.height, 40)
        XCTAssertEqual(frames.palette.maxY, frames.toolbar.minY - 8)
        XCTAssertFalse(frames.isAbove)
    }
    func testBottomEdgeFlipsStripAndPaletteAboveWithoutMovingSelection() {
        let selection = CGRect(x: 850, y: 8, width: 310, height: 220)
        let frames = EditorFloatingLayout.frames(selection: selection,
            available: CGRect(x: 0, y: 0, width: 1200, height: 800), toolbarSize: CGSize(width: 690, height: 40),
            paletteSize: CGSize(width: 420, height: 38), activeToolOffset: 520)
        XCTAssertTrue(frames.isAbove)
        XCTAssertEqual(frames.toolbar.minY, selection.maxY + 8)
        XCTAssertGreaterThan(frames.palette.minY, frames.toolbar.maxY)
        XCTAssertLessThanOrEqual(frames.palette.maxX, 1190)
    }
    func testTinySelectionAtTopLeftKeepsControlsInsideDisplay() {
        let available = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frames = EditorFloatingLayout.frames(selection: CGRect(x: 1, y: 575, width: 20, height: 20),
            available: available, toolbarSize: CGSize(width: 690, height: 40), paletteSize: CGSize(width: 480, height: 38), activeToolOffset: 40)
        XCTAssertTrue(available.contains(frames.toolbar)); XCTAssertTrue(available.contains(frames.palette))
    }

    @MainActor
    func testNativeToolbarDrivesToolContextAndVisibleSwatches() throws {
        let editor = makeEditor(); defer { editor.close() }
        editor.showWindow(nil)
        let rectangle = try button("editor.tool.rectangle", editor)
        rectangle.performClick(nil)
        XCTAssertEqual(editor.annotationCanvas.tool, .rectangle)
        XCTAssertEqual(rectangle.state, .on)
        XCTAssertTrue(editor.contextualPaletteVisible)
        XCTAssertEqual(editor.floatingToolbarFrame.height, 40)
        XCTAssertLessThan(editor.floatingToolbarFrame.width, editor.window!.contentView!.bounds.width)
        for index in 0..<8 { XCTAssertFalse(try button("annotation.swatch.\(index)", editor).isHiddenOrHasHiddenAncestor) }
        try button("annotation.swatch.4", editor).performClick(nil)
        XCTAssertEqual(editor.annotationCanvas.style.color, NSColor.systemBlue.cgColor)
        try button("editor.tool.select", editor).performClick(nil)
        XCTAssertFalse(editor.contextualPaletteVisible)
        try button("editor.tool.text", editor).performClick(nil)
        XCTAssertTrue(editor.contextualPaletteVisible)
        XCTAssertFalse(try view("annotation.fontSize", editor).isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "annotation.strokeStyle" }?.isHiddenOrHasHiddenAncestor ?? true)
        XCTAssertFalse(descendants(editor.window?.contentView).contains { $0.identifier?.rawValue == "editor.translate" })
    }

    @MainActor
    func testOptionalTranslationIsRealCallbackAndPinApplyFailureKeepsEditorOpen() throws {
        _ = NSApplication.shared
        var translated = false, applied = false, allowApply = false, closed = false
        let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in XCTFail("Apply mode must not create a pin") }, onOCR: { _ in }, onTranslate: { _ in translated = true }, onApply: { _ in applied = true; return allowApply })
        defer { editor.close() }
        editor.onClose = { closed = true }; editor.showWindow(nil)
        try button("editor.translate", editor).performClick(nil); XCTAssertTrue(translated)
        XCTAssertFalse(descendants(editor.window?.contentView).contains { $0.identifier?.rawValue == "editor.pin" })
        try button("editor.applyToPin", editor).performClick(nil)
        XCTAssertTrue(applied); XCTAssertTrue(editor.window?.isVisible == true); XCTAssertFalse(closed)
        allowApply = true; try button("editor.applyToPin", editor).performClick(nil)
        XCTAssertTrue(closed); XCTAssertFalse(editor.window?.isVisible == true)
    }

    @MainActor
    func testInlineStyleChangesStayInlineAndCancelWithoutAnnotation() throws {
        let editor = makeEditor(); defer { editor.close() }
        editor.showWindow(nil); editor.chooseTool(.text)
        editor.beginInlineText(at: CGPoint(x: 60, y: 300), editing: nil)
        let input = try XCTUnwrap(editor.activeInlineTextView)
        input.string = "Inline\n多行"
        try button("annotation.swatch.4", editor).performClick(nil)
        try button("annotation.bold", editor).performClick(nil)
        XCTAssertTrue(editor.activeInlineTextView === input)
        XCTAssertNil(editor.window?.attachedSheet)
        XCTAssertTrue(editor.annotationCanvas.annotations.isEmpty)
        editor.finishInlineText(commit: false)
        XCTAssertNil(editor.activeInlineTextView)
        XCTAssertTrue(editor.annotationCanvas.annotations.isEmpty)
    }

    @MainActor
    func testInlineAcceptCommitsStylesAndNewlineIntoSingleAnnotation() throws {
        let editor = makeEditor(); defer { editor.close() }
        editor.showWindow(nil); editor.chooseTool(.text)
        editor.beginInlineText(at: CGPoint(x: 60, y: 300), editing: nil)
        let input = try XCTUnwrap(editor.activeInlineTextView)
        input.string = "One\n二"
        try button("annotation.swatch.4", editor).performClick(nil)
        try button("annotation.bold", editor).performClick(nil)
        editor.finishInlineText(commit: true)
        let annotation = try XCTUnwrap(editor.annotationCanvas.annotations.first)
        XCTAssertEqual(annotation.text, "One\n二"); XCTAssertTrue(annotation.bold)
        XCTAssertEqual(annotation.color, NSColor.systemBlue.cgColor)
        XCTAssertNotNil(annotation.textBoxSize)
        try button("editor.undo", editor).performClick(nil)
        XCTAssertTrue(editor.annotationCanvas.annotations.isEmpty)
        try button("editor.redo", editor).performClick(nil)
        XCTAssertEqual(editor.annotationCanvas.annotations.first?.text, "One\n二")
    }

    @MainActor
    func testFrozenEditorPreservesRealOriginAndOverlayClosesOnDisplayChange() throws {
        _ = NSApplication.shared
        let frozen = ImageEditorRenderer.makeSampleImage()
        let capture = try CapturedImage.frozenRegion(image: frozen, displayID: 99,
            displayFrame: CGRect(x: -960, y: 180, width: 960, height: 600), selection: CGRect(x: 140, y: 110, width: 680, height: 280))
        let presentation = try XCTUnwrap(capture.presentation)
        let editor = ImageEditorController(image: capture.image, presentation: presentation, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        defer { editor.close() }
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.window?.frame, presentation.displayFrame)
        XCTAssertEqual(editor.editorSelectionFrame, presentation.selectionFrame)
        XCTAssertEqual(editor.annotationCanvas.frame, presentation.selectionFrame)
        XCTAssertLessThan(editor.window!.level.rawValue, NSWindow.Level.modalPanel.rawValue, "Save/color panels must be able to appear above the frozen editor")
        var closed = false; editor.onClose = { closed = true }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let until = Date().addingTimeInterval(2)
        while !closed, Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(closed); XCTAssertFalse(editor.window?.isVisible == true)
    }

    @MainActor
    func testRepeatedEditorCloseCallsCompletionOnlyOnce() {
        let editor = makeEditor(); var closes = 0
        editor.onClose = { closes += 1 }; editor.showWindow(nil)
        editor.close(); editor.close()
        XCTAssertEqual(closes, 1)
    }

    @MainActor
    private func makeEditor() -> ImageEditorController {
        _ = NSApplication.shared
        return ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
    }
    @MainActor
    private func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    @MainActor
    private func view(_ id: String, _ editor: ImageEditorController) throws -> NSView {
        try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == id })
    }
    @MainActor
    private func button(_ id: String, _ editor: ImageEditorController) throws -> NSButton {
        try XCTUnwrap(view(id, editor) as? NSButton)
    }
}
