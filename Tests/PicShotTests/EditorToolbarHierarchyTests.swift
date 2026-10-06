import AppKit
import XCTest
@testable import PicShot

/// Real AppKit hierarchy checks, including the new save popup. No control is
/// substituted and the installed capture fixture's rectangle assertion remains.
@MainActor
final class EditorToolbarHierarchyTests: XCTestCase {
    func testCoreToolsAndSaveChevronStayAttachedAcrossRepeatedNativeResize() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Native toolbar hierarchy requires WindowServer") }
        let suite = "PicShot-ToolbarHierarchy-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let presenter = SaveWorkflowPresenter(defaults: defaults)
        for configured in [false, true] {
            let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in },
                onOCR: { _ in }, saveWorkflow: configured ? presenter : nil)
            defer { editor.close() }
            editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            for width in [760.0, 1080, 820, 760, 1000] {
                editor.window?.setContentSize(CGSize(width: width, height: 540))
                try await settle(editor)
                try assertHierarchy(editor)
                let rectangle = try control("editor.tool.rectangle", editor) as? NSButton
                try XCTUnwrap(rectangle).performClick(nil)
                XCTAssertEqual(editor.annotationCanvas.tool, .rectangle)
                XCTAssertEqual((editor.saveActions.cell as? NSPopUpButtonCell)?.arrowPosition, .noArrow)
                XCTAssertEqual(editor.saveActions.bounds.width, 19, accuracy: 0.5)
                XCTAssertEqual(editor.saveActions.bounds.height, 32, accuracy: 0.5)
                XCTAssertEqual(editor.saveActions.alignmentRect(forFrame: editor.saveActions.frame), editor.saveActions.frame)
                XCTAssertEqual(editor.saveActions.frame(forAlignmentRect: editor.saveActions.frame), editor.saveActions.frame)
                XCTAssertNotNil(editor.saveActions.item(at: 0)?.image)
                let hitPoint = CGPoint(x: editor.saveActions.frame.midX, y: editor.saveActions.frame.midY)
                XCTAssertTrue(editor.saveActions.hitTest(hitPoint) === editor.saveActions)
            }
            editor.close()
        }
    }

    func testSyntheticCaptureSetupWaitsForDisplayNotificationQuiet() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Native display setup requires WindowServer") }
        let setup = Task { try await CaptureUIPreviewFixture.waitForDisplayGeometryQuiet(quietInterval: 0.25, timeout: 2) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let notifiedAt = ProcessInfo.processInfo.systemUptime
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let result = try await setup.value
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result["notifications"] as? Int), 1)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - notifiedAt, 0.25)
    }

    func testFrozenToolbarContainsCoreControlsAndDisplayChangeStillCancels() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Native frozen toolbar requires WindowServer") }
        _ = try await CaptureUIPreviewFixture.waitForDisplayGeometryQuiet()
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 960, height: 640)
        let captured = try CapturedImage.frozenRegion(image: image, displayID: 99,
            displayFrame: CGRect(x: 0, y: 0, width: 960, height: 640), selection: CGRect(x: 96, y: 120, width: 768, height: 360))
        let editor = ImageEditorController(image: captured.image, presentation: captured.presentation,
            onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        defer { editor.close() }
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        try await settle(editor); try assertHierarchy(editor)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while !editor.isClosed && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(editor.isClosed, "Safety cancellation on display changes must remain")
        let diagnostic = editor.nativeToolbarDiagnostics()
        XCTAssertEqual(diagnostic["editorClosed"] as? Bool, true)
        XCTAssertEqual(diagnostic["hasContentView"] as? Bool, false)
    }
    private func assertHierarchy(_ editor: ImageEditorController) throws {
        let diagnostics = String(describing: editor.nativeToolbarDiagnostics())
        XCTAssertFalse(editor.isClosed, diagnostics)
        let root = try XCTUnwrap(editor.window?.contentView, diagnostics)
        let toolbar = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "editor.floatingToolbar" } as? NSStackView, diagnostics)
        let required = ["editor.tool.rectangle", "editor.tool.arrow", "editor.tool.text", "editor.ocr", "editor.pin",
                        "editor.save", "editor.saveActions", "editor.cancel", "editor.copy"]
        for id in required {
            let view = try control(id, editor)
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, id + ": " + diagnostics)
            XCTAssertTrue(view.window === editor.window, id + ": " + diagnostics)
            XCTAssertFalse(toolbar.detachedViews.contains { $0 === view }, id + ": " + diagnostics)
            XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(view.convert(view.bounds, to: root)), id + ": " + diagnostics)
        }
    }
    private func settle(_ editor: ImageEditorController) async throws {
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 180_000_000)
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
    }
    private func control(_ id: String, _ editor: ImageEditorController) throws -> NSView {
        let diagnostic = id + ": " + String(describing: editor.nativeToolbarDiagnostics())
        let root = try XCTUnwrap(editor.window?.contentView, diagnostic)
        return try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == id }, diagnostic)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
