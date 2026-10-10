import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class AnnotationToolbarOrderUITests: XCTestCase {
    func testDraftMoveSelectionResetAndCancelNeverWritePreferences() throws {
        _ = NSApplication.shared
        let (defaults, name) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let original = try reversedOrder(); original.write(to: defaults)
        let view = AnnotationToolbarSettingsView(order: .read(from: defaults))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 520, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.selectedFamily, .crop); XCTAssertFalse(view.moveUpButton.isEnabled)
        XCTAssertEqual(view.tableView.accessibilityLabel(), "标注工具顺序")
        var changes = 0; view.onChange = { changes += 1 }
        view.moveDownButton.performClick(nil)
        XCTAssertEqual(view.selectedFamily, .crop); XCTAssertEqual(view.tableView.selectedRow, 1)
        XCTAssertTrue(view.selectionLabel.stringValue.contains("2 / 14")); XCTAssertEqual(changes, 1)
        view.moveUpButton.performClick(nil); XCTAssertEqual(view.draft, original)
        view.selectFamily(.rectangle); XCTAssertFalse(view.moveDownButton.isEnabled)
        view.restoreDefaultsButton.performClick(nil)
        XCTAssertEqual(view.draft, .defaults); XCTAssertEqual(view.selectedFamily, .rectangle)
        XCTAssertFalse(view.restoreDefaultsButton.isEnabled)
        XCTAssertEqual(AnnotationToolbarOrder.read(from: defaults), original, "Reset is still only a draft")
        view.apply(order: original)
        XCTAssertEqual(view.selectedFamily, .rectangle); XCTAssertEqual(changes, 3, "Import/replacement must not look like a user move")
        window.close()
        let reopened = AnnotationToolbarSettingsView(order: .read(from: defaults))
        XCTAssertEqual(reopened.draft, original, "Discarding the view discards its unsaved draft")
        reopened.selectFamily(.crop); reopened.moveDownButton.performClick(nil)
        reopened.draft.write(to: defaults)
        XCTAssertEqual(AnnotationToolbarSettingsView(order: .read(from: defaults)).draft, reopened.draft)
    }

    func testExplicitOrderAndNilDefaultsAreDeterministic() throws {
        try requireDisplay()
        let (defaults, name) = try isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let custom = try reversedOrder(); custom.write(to: defaults)
        let source = try sourceImage()
        let configured = ImageEditorController(image: source, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, defaults: defaults)
        let isolated = ImageEditorController(image: source, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, defaults: nil)
        let overridden = ImageEditorController(image: source, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, toolbarOrder: .defaults, defaults: defaults)
        defer { configured.close(); isolated.close(); overridden.close() }
        XCTAssertEqual(configured.toolbarOrder, custom)
        XCTAssertEqual(isolated.toolbarOrder, .defaults); XCTAssertEqual(overridden.toolbarOrder, .defaults)
    }

    func testDefaultAndCustomToolbarOrderAndHitTargetsSurviveResize() async throws {
        try requireDisplay()
        for order in [AnnotationToolbarOrder.defaults, try reversedOrder()] {
            let editor = ImageEditorController(image: try sourceImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, toolbarOrder: order, defaults: nil)
            defer { editor.close() }
            editor.showWindow(nil)
            for width in [1440.0, 760, 1000, 760, 1440] {
                editor.window?.setContentSize(CGSize(width: width, height: 600)); try await settle(editor)
                try assertToolbar(editor, order: order, allFamiliesVisible: width == 1440)
            }
            if order == .defaults {
                editor.window?.setContentSize(CGSize(width: 760, height: 600)); try await settle(editor)
                for id in ["rectangle", "arrow", "text"] {
                    XCTAssertNotNil(visibleControls(editor).first { $0.identifier?.rawValue == "editor.tool." + id })
                }
            }
        }
    }

    func testNarrowNegativeOriginCaptureKeepsOutputActionsAndAllToolsWithoutChangingLayers() async throws {
        try requireDisplay()
        _ = try await CaptureUIPreviewFixture.waitForDisplayGeometryQuiet()
        let order = try reversedOrder()
        let source = try SaveWorkflowUIPreviewFixture.sourceImage(width: 480, height: 640)
        let captured = try CapturedImage.frozenRegion(image: source, displayID: 93,
            displayFrame: CGRect(x: -960, y: -180, width: 480, height: 640),
            selection: CGRect(x: 50, y: 170, width: 350, height: 230))
        let editor = ImageEditorController(image: captured.image, presentation: captured.presentation,
            onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, onTranslate: { _ in }, toolbarOrder: order, defaults: nil)
        defer { editor.close() }
        editor.showWindow(nil); try await settle(editor)
        try assertToolbar(editor, order: order)
        try assertOutputControls(editor, pinID: "editor.pin")
        let annotation = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 12, y: 14), CGPoint(x: 100, y: 80)])
        editor.annotationCanvas.add(annotation)
        let payloadBefore = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
        try selectEveryOverflowTool(editor)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document), payloadBefore)
        XCTAssertEqual(editor.annotationCanvas.annotations.first?.id, annotation.id)
        try assertToolbar(editor, order: order)
    }

    func testReorderedPrimaryAndAdjacentSubtoolActionsKeepTheirIdentity() async throws {
        try requireDisplay()
        let order = try reversedOrder()
        let editor = ImageEditorController(image: try sourceImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, toolbarOrder: order, defaults: nil)
        defer { editor.close() }
        editor.window?.setContentSize(CGSize(width: 1440, height: 700)); editor.showWindow(nil); try await settle(editor)
        for family in order.families {
            let button = try XCTUnwrap(visibleControls(editor).first { $0.identifier?.rawValue == "editor.tool." + family.rawValue } as? NSButton)
            button.performClick(nil); XCTAssertEqual(editor.annotationCanvas.tool, family.editorTool)
        }
        for (menuID, tools) in [("editor.shapeSubtools", [ImageEditorTool.ellipse, .arc, .sector]),
                                ("editor.lineSubtools", [.line, .polyline]),
                                ("editor.mosaicSubtools", [.pixelate, .blur, .redact])] {
            let menu = try XCTUnwrap(visibleControls(editor).first { $0.identifier?.rawValue == menuID } as? NSPopUpButton)
            for tool in tools {
                let item = try XCTUnwrap(menu.menu?.items.first { $0.identifier?.rawValue == "editor.subtool." + tool.rawValue })
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
                XCTAssertEqual(editor.annotationCanvas.tool, tool)
            }
        }
        let shape = try XCTUnwrap(visibleControls(editor).first { $0.identifier?.rawValue == "editor.tool.ellipse" } as? NSButton)
        shape.performClick(nil); XCTAssertEqual(editor.annotationCanvas.tool, .sector, "A reordered family retains its last advanced subtool")
        XCTAssertTrue(editor.annotationCanvas.annotations.isEmpty)
        try assertToolbar(editor, order: order, allFamiliesVisible: true)
    }

    func testVeryNarrowNegativeOriginPinKeepsGeometryAndOutputHitTargets() async throws {
        try requireDisplay()
        let order = try reversedOrder(), source = try sourceImage()
        let screen = CGRect(x: -680, y: -200, width: 340, height: 640)
        let viewport = CGRect(x: -650, y: -50, width: 280, height: 180)
        let imageFrame = CGRect(x: -680, y: -80, width: 640, height: 360)
        let editor = ImageEditorController(image: source, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in },
            onApply: { _ in true }, toolbarOrder: order, defaults: nil)
        defer { editor.close() }
        XCTAssertTrue(editor.showPinned(PinEditorPresentation(viewportFrame: viewport, imageFrame: imageFrame, opacity: 0.7, level: .floating), availableScreenFrame: screen))
        try await settle(editor); try assertToolbar(editor, order: order)
        try assertOutputControls(editor, pinID: "editor.applyToPin")
        XCTAssertEqual(editor.pinnedViewportScreenFrame, viewport)
        XCTAssertEqual(editor.editorImageScreenFrame, imageFrame)
        let root = try XCTUnwrap(editor.window?.contentView)
        let toolbar = try toolbar(in: editor)
        let screenToolbar = try XCTUnwrap(editor.window).convertToScreen(toolbar.convert(toolbar.bounds, to: nil))
        XCTAssertTrue(screen.insetBy(dx: -1, dy: -1).contains(screenToolbar))
        XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(toolbar.frame))
        try selectEveryOverflowTool(editor)
        XCTAssertTrue(editor.annotationCanvas.annotations.isEmpty)
        XCTAssertEqual(editor.pinnedViewportScreenFrame, viewport); XCTAssertEqual(editor.editorImageScreenFrame, imageFrame)
    }

    private func assertToolbar(_ editor: ImageEditorController, order: AnnotationToolbarOrder,
                               allFamiliesVisible: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        let toolbar = try toolbar(in: editor), root = try XCTUnwrap(editor.window?.contentView)
        let controls = toolbar.views.filter { !$0.isHidden && $0 is NSControl }
        let primary = controls.filter { $0.identifier?.rawValue.hasPrefix("editor.tool.") == true }
        let visibleIDs = primary.compactMap { $0.identifier?.rawValue.components(separatedBy: ".").last }
        let expected = order.rawIDs.filter { visibleIDs.contains($0) }
        XCTAssertEqual(visibleIDs, expected, file: file, line: line)
        if allFamiliesVisible { XCTAssertEqual(visibleIDs, order.rawIDs, file: file, line: line) }
        if order != .defaults {
            XCTAssertEqual(visibleIDs, Array(order.rawIDs.prefix(visibleIDs.count)), "Custom overflow must remove a suffix", file: file, line: line)
        }
        for (family, menuID) in [("ellipse", "editor.shapeSubtools"), ("line", "editor.lineSubtools"), ("pixelate", "editor.mosaicSubtools")] {
            if let primaryIndex = controls.firstIndex(where: { $0.identifier?.rawValue == "editor.tool." + family }) {
                XCTAssertLessThan(primaryIndex + 1, controls.count, file: file, line: line)
                XCTAssertEqual(controls[primaryIndex + 1].identifier?.rawValue, menuID, file: file, line: line)
            } else { XCTAssertFalse(controls.contains { $0.identifier?.rawValue == menuID }, file: file, line: line) }
        }
        for (index, control) in controls.enumerated() {
            let frame = control.convert(control.bounds, to: toolbar)
            XCTAssertTrue(toolbar.bounds.insetBy(dx: -1, dy: -1).contains(frame), control.identifier?.rawValue ?? "", file: file, line: line)
            XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: root)), file: file, line: line)
            let center = CGPoint(x: control.bounds.midX, y: control.bounds.midY)
            let hit = toolbar.hitTest(control.convert(center, to: toolbar.superview))
            XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true, control.identifier?.rawValue ?? "", file: file, line: line)
            for later in controls.dropFirst(index + 1) {
                let overlap = frame.intersection(later.convert(later.bounds, to: toolbar))
                XCTAssertTrue(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5,
                    "Overlapping targets: \(control.identifier?.rawValue ?? "") / \(later.identifier?.rawValue ?? "")", file: file, line: line)
            }
        }
        let overflow = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "editor.more" } as? NSPopUpButton)
        let tools = (overflow.menu?.items ?? []).filter { $0.identifier?.rawValue.hasPrefix("editor.overflow.tool.") == true }
        XCTAssertEqual(tools.count, ImageEditorTool.allCases.count, file: file, line: line)
        XCTAssertEqual(Set(tools.map(\.tag)), Set(ImageEditorTool.allCases.indices), file: file, line: line)
        XCTAssertTrue(tools.allSatisfy { $0.target === editor && $0.action != nil && $0.isEnabled }, file: file, line: line)
    }

    private func assertOutputControls(_ editor: ImageEditorController, pinID: String) throws {
        let visible = visibleControls(editor).compactMap { $0.identifier?.rawValue }
        for id in ["editor.ocr", pinID, "editor.save", "editor.saveActions", "editor.cancel", "editor.copy", "editor.more"] {
            XCTAssertTrue(visible.contains(id), "Required action missing: " + id)
        }
    }
    private func selectEveryOverflowTool(_ editor: ImageEditorController) throws {
        let popup = try XCTUnwrap(try toolbar(in: editor).views.first { $0.identifier?.rawValue == "editor.more" } as? NSPopUpButton)
        for item in (popup.menu?.items ?? []).filter({ $0.identifier?.rawValue.hasPrefix("editor.overflow.tool.") == true }) {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(editor.annotationCanvas.tool, ImageEditorTool.allCases[item.tag])
        }
    }
    private func toolbar(in editor: ImageEditorController) throws -> NSStackView {
        try XCTUnwrap(editor.window?.contentView?.subviews.first { $0.identifier?.rawValue == "editor.floatingToolbar" } as? NSStackView,
                      String(describing: editor.nativeToolbarDiagnostics()))
    }
    private func visibleControls(_ editor: ImageEditorController) -> [NSView] {
        ((try? toolbar(in: editor).views) ?? []).filter { !$0.isHidden && $0 is NSControl }
    }
    private func settle(_ editor: ImageEditorController) async throws {
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
    }
    private func requireDisplay() throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Native toolbar tests require WindowServer") }
    }
    private func reversedOrder() throws -> AnnotationToolbarOrder {
        try AnnotationToolbarOrder(rawIDs: Array(AnnotationToolbarOrder.defaults.rawIDs.reversed()))
    }
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "PicShot-AnnotationToolbarOrderUITests-" + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }
    private func sourceImage() throws -> CGImage { try SaveWorkflowUIPreviewFixture.sourceImage(width: 640, height: 360) }
}
