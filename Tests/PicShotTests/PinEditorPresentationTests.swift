import XCTest
import AppKit
@testable import PicShot

final class PinEditorPresentationTests: XCTestCase {
    @MainActor
    func testPinEditorPreservesViewportZoomPanOpacityAndUsesBorderlessKeyWindow() throws {
        _ = NSApplication.shared
        let placement = PinEditorPresentation(viewportFrame: CGRect(x: 200, y: 180, width: 320, height: 200),
            imageFrame: CGRect(x: 120, y: 135, width: 480, height: 300), opacity: 0.65, level: .floating)
        let editor = makeEditor(); defer { editor.close() }
        XCTAssertTrue(editor.showPinned(placement))
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.pinnedViewportScreenFrame, placement.viewportFrame)
        XCTAssertEqual(editor.editorImageScreenFrame, placement.imageFrame)
        XCTAssertEqual(editor.annotationCanvas.alphaValue, 0.65, accuracy: 0.001)
        XCTAssertEqual(editor.window?.styleMask, .borderless)
        XCTAssertTrue(editor.window?.canBecomeKey == true)
        XCTAssertFalse(editor.window?.isOpaque == true)
        XCTAssertEqual(editor.window?.backgroundColor, .clear)
        XCTAssertEqual(editor.window?.level, placement.level)
        XCTAssertTrue(editor.captureBoundaryWorkspace.transparentBackground)
        XCTAssertNil(editor.captureBoundaryWorkspace.frozenImage)
        XCTAssertTrue(editor.annotationCanvas.superview?.layer?.masksToBounds == true)
        let viewportInWindow = editor.captureBoundaryWorkspace.selectionFrame
        let viewportOnScreen = try XCTUnwrap(editor.window).convertToScreen(viewportInWindow)
        XCTAssertEqual(viewportOnScreen, placement.viewportFrame)
    }
    @MainActor
    func testToolContextChangesDoNotShiftPinnedImageOrCommitInlineInput() throws {
        _ = NSApplication.shared
        let placement = PinEditorPresentation(viewportFrame: CGRect(x: 100, y: 180, width: 360, height: 225),
            imageFrame: CGRect(x: 100, y: 180, width: 360, height: 225), opacity: 1, level: .floating)
        let editor = makeEditor(); defer { editor.close() }; XCTAssertTrue(editor.showPinned(placement))
        for tool in [ImageEditorTool.rectangle, .text, .arrow, .crop] {
            editor.chooseTool(tool)
            XCTAssertEqual(editor.editorImageScreenFrame, placement.imageFrame)
            XCTAssertEqual(editor.pinnedViewportScreenFrame, placement.viewportFrame)
        }
        editor.chooseTool(.text); editor.beginInlineText(at: CGPoint(x: 100, y: 300), editing: nil)
        let input = try XCTUnwrap(editor.activeInlineTextView); input.string = "Pinned text"
        let bold = try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "annotation.bold" } as? NSButton)
        bold.performClick(nil)
        XCTAssertTrue(editor.activeInlineTextView === input)
        XCTAssertTrue(editor.annotationCanvas.annotations.isEmpty)
        XCTAssertEqual(editor.editorImageScreenFrame, placement.imageFrame)
    }
    @MainActor
    func testInvalidPinGeometryDoesNotReplaceExistingWindow() {
        let editor = makeEditor(); defer { editor.close() }; let originalWindow = editor.window
        let invalid = PinEditorPresentation(viewportFrame: .zero, imageFrame: .zero, opacity: 1, level: .floating)
        XCTAssertFalse(editor.showPinned(invalid)); XCTAssertTrue(editor.window === originalWindow)
        XCTAssertNil(editor.pinnedViewportScreenFrame)
    }
    @MainActor
    private func makeEditor() -> ImageEditorController {
        _ = NSApplication.shared
        return ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, onApply: { _ in true })
    }
    @MainActor private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
}
