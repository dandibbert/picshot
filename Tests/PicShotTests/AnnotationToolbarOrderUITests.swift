import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class AnnotationToolbarOrderUITests: XCTestCase {
    private var retainedToolbarEvidence: String?
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
            try clickPrimaryTool(button, in: editor); XCTAssertEqual(editor.annotationCanvas.tool, family.editorTool)
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
        // Measure full frames and both dispatch routes before validation. A
        // failed assertion must retain unmodified observations and owned pixels.
        let measurements = toolbarMeasurements(editor, toolbar: toolbar, root: root, controls: controls)
        let evidence = measurements.failures.isEmpty ? "" : retainToolbarEvidence(measurements.value, root: root)
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
            let id = control.identifier?.rawValue ?? String(describing: type(of: control))
            XCTAssertTrue(toolbar.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                "toolbar-containment: \(id) fullFrame=\(frame) toolbarBounds=\(toolbar.bounds) \(evidence)", file: file, line: line)
            XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: root)),
                "content-containment: \(id) fullFrame=\(control.convert(control.bounds, to: root)) contentBounds=\(root.bounds) \(evidence)", file: file, line: line)
            let center = CGPoint(x: control.bounds.midX, y: control.bounds.midY)
            let hit = toolbar.hitTest(control.convert(center, to: toolbar.superview))
            XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true,
                "toolbar-center-hit: \(id) returned=\(hitDescription(hit)) fullFrame=\(frame) \(evidence)", file: file, line: line)
            let rootHit = root.hitTest(control.convert(center, to: root.superview))
            XCTAssertTrue(rootHit === control || rootHit?.isDescendant(of: control) == true,
                "content-center-hit: \(id) returned=\(hitDescription(rootHit)) fullFrame=\(control.convert(control.bounds, to: root)) \(evidence)", file: file, line: line)
            for later in controls.dropFirst(index + 1) {
                let overlap = frame.intersection(later.convert(later.bounds, to: toolbar))
                XCTAssertTrue(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5,
                    "full-frame-overlap: \(id) \(frame) / \(later.identifier?.rawValue ?? "") \(later.convert(later.bounds, to: toolbar)) intersection=\(overlap) \(evidence)", file: file, line: line)
            }
        }
        let overflow = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "editor.more" } as? NSPopUpButton)
        let tools = (overflow.menu?.items ?? []).filter { $0.identifier?.rawValue.hasPrefix("editor.overflow.tool.") == true }
        XCTAssertEqual(tools.count, ImageEditorTool.allCases.count, file: file, line: line)
        XCTAssertEqual(Set(tools.map(\.tag)), Set(ImageEditorTool.allCases.indices), file: file, line: line)
        XCTAssertTrue(tools.allSatisfy { $0.target === editor && $0.action != nil && $0.isEnabled }, file: file, line: line)
    }

    /// AppKit hitTest points are in the receiving view's superview coordinates.
    /// Full control bounds remain the acceptance rectangle; alignment/cell
    /// rectangles below are evidence only and never replace that rectangle.
    private func toolbarMeasurements(_ editor: ImageEditorController, toolbar: NSStackView, root: NSView,
                                     controls: [NSView]) -> (value: [String: Any], failures: [String]) {
        func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
        func point(_ value: CGPoint) -> [CGFloat] { [value.x, value.y] }
        var failures: [String] = [], rows: [[String: Any]] = [], intersections: [[String: Any]] = []
        for (index, control) in controls.enumerated() {
            let id = control.identifier?.rawValue ?? "control.\(index)", insets = control.alignmentRectInsets
            let frame = control.convert(control.bounds, to: toolbar), rootFrame = control.convert(control.bounds, to: root)
            let center = CGPoint(x: control.bounds.midX, y: control.bounds.midY)
            let toolbarPoint = control.convert(center, to: toolbar.superview), rootPoint = control.convert(center, to: root.superview)
            let toolbarHit = toolbar.hitTest(toolbarPoint), rootHit = root.hitTest(rootPoint)
            let selfHit = control.hitTest(control.convert(center, to: control.superview))
            let toolbarInside = toolbar.bounds.insetBy(dx: -1, dy: -1).contains(frame)
            let contentInside = root.bounds.insetBy(dx: -1, dy: -1).contains(rootFrame)
            let toolbarHits = toolbarHit === control || toolbarHit?.isDescendant(of: control) == true
            let contentHits = rootHit === control || rootHit?.isDescendant(of: control) == true
            for (kind, passed) in [("toolbar-containment", toolbarInside), ("content-containment", contentInside),
                                   ("toolbar-center-hit", toolbarHits), ("content-center-hit", contentHits)] where !passed {
                failures.append(kind + ": " + id)
            }
            var row: [String: Any] = ["id": id, "class": String(describing: type(of: control)),
                "fullFrameInToolbar": rect(frame), "fullFrameInContent": rect(rootFrame),
                "frameInSuperview": rect(control.frame), "bounds": rect(control.bounds), "visibleRect": rect(control.visibleRect),
                "alignmentRectangleInSuperview": rect(control.alignmentRect(forFrame: control.frame)),
                "alignmentInsetsTopLeftBottomRight": [insets.top, insets.left, insets.bottom, insets.right],
                "hidden": control.isHidden, "hiddenAncestor": control.isHiddenOrHasHiddenAncestor,
                "toolbarContainment": toolbarInside, "contentContainment": contentInside,
                "centerInControl": point(center), "centerInToolbarSuperview": point(toolbarPoint), "centerInContentSuperview": point(rootPoint),
                "toolbarHit": hitDescription(toolbarHit), "contentHit": hitDescription(rootHit), "selfHit": hitDescription(selfHit),
                "toolbarHitMatches": toolbarHits, "contentHitMatches": contentHits]
            if let window = editor.window { row["fullScreenFrame"] = rect(window.convertToScreen(control.convert(control.bounds, to: nil))) }
            if let button = control as? NSButton {
                row["enabled"] = button.isEnabled; row["bordered"] = button.isBordered
                row["symbolAccessibilityLabel"] = button.accessibilityLabel() ?? ""
                row["cellDrawingRectangle"] = button.cell.map { rect($0.drawingRect(forBounds: button.bounds)) } ?? []
            }
            rows.append(row)
            for later in controls.dropFirst(index + 1) {
                let overlap = frame.intersection(later.convert(later.bounds, to: toolbar))
                if !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5 {
                    let laterID = later.identifier?.rawValue ?? ""
                    failures.append("full-frame-overlap: " + id + " / " + laterID)
                    intersections.append(["first": id, "second": laterID, "intersectionInToolbar": rect(overlap)])
                }
            }
        }
        return (["status": "measured-before-validation", "test": name, "toolbarOrder": editor.toolbarOrder.rawIDs,
                 "coordinateSystem": "native AppKit points; hit inputs in receiver superview coordinates",
                 "contentBounds": rect(root.bounds), "toolbarBounds": rect(toolbar.bounds), "toolbarFrame": rect(toolbar.frame),
                 "controls": rows, "intersections": intersections, "failures": failures,
                 "controllerDiagnostics": editor.nativeToolbarDiagnostics()], failures)
    }

    /// SwiftPM does not reliably retain XCTest attachments, so also save under
    /// the existing focused/QA artifact directory. Only this test's synthetic
    /// owned content is cached; no desktop or unrelated window is captured.
    private func retainToolbarEvidence(_ value: [String: Any], root: NSView) -> String {
        if let retainedToolbarEvidence { return retainedToolbarEvidence }
        // At most one attempt per failing method, including retention failures.
        // Four methods use this path: <= 4 * (4 MiB PNG + 256 KiB JSON).
        retainedToolbarEvidence = "evidence-retention-failed"
        let testName = name.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let stem = "\(ProcessInfo.processInfo.processIdentifier)-\(String(testName))"
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("dist/focused-test-shards/annotation-toolbar-evidence", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 256 * 1024 else {
                XCTFail("toolbar-evidence: geometry exceeds 256 KiB cap"); return "evidence-retention-failed"
            }
            let jsonURL = directory.appendingPathComponent(stem + ".json"); try data.write(to: jsonURL, options: .atomic)
            retainedToolbarEvidence = "evidence=" + jsonURL.path
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = stem + ".json"; attachment.lifetime = .keepAlways; add(attachment)
            // Match other native fixtures: one raster pixel per AppKit point,
            // retaining the complete owned window without a Retina multiplier.
            guard root.bounds.width.isFinite, root.bounds.height.isFinite,
                  root.bounds.width > 0, root.bounds.height > 0,
                  root.bounds.width <= 4_000_000, root.bounds.height <= 4_000_000 else {
                XCTFail("toolbar-evidence: invalid owned content bounds; geometry at \(jsonURL.path)"); return jsonURL.path
            }
            let width = Int(root.bounds.width.rounded(.up)), height = Int(root.bounds.height.rounded(.up))
            guard width > 0, height > 0, width <= 4_000_000 / height,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32) else {
                XCTFail("toolbar-evidence: owned content bitmap unavailable; geometry at \(jsonURL.path)"); return jsonURL.path
            }
            bitmap.size = root.bounds.size
            root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                XCTFail("toolbar-evidence: owned content PNG unavailable; geometry at \(jsonURL.path)"); return jsonURL.path
            }
            guard png.count <= 4 * 1024 * 1024 else {
                XCTFail("toolbar-evidence: owned content PNG exceeds 4 MiB cap; geometry at \(jsonURL.path)"); return jsonURL.path
            }
            let pngURL = directory.appendingPathComponent(stem + ".png"); try png.write(to: pngURL, options: .atomic)
            let picture = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            picture.name = stem + ".png"; picture.lifetime = .keepAlways; add(picture)
            print("ANNOTATION_TOOLBAR_EVIDENCE json=\(jsonURL.path) png=\(pngURL.path)")
            return "evidence=" + jsonURL.path
        } catch {
            XCTFail("toolbar-evidence: retention failed: \(error)")
            return "evidence-retention-failed"
        }
    }

    private func hitDescription(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return (view.identifier?.rawValue ?? "unidentified") + " (" + String(describing: type(of: view)) + ")"
    }

    private func clickPrimaryTool(_ button: NSButton, in editor: ImageEditorController) throws {
        let window = try XCTUnwrap(editor.window), root = try XCTUnwrap(window.contentView)
        // The inset corner also belongs to the existing 32-point target, even
        // when it contains no SF Symbol pixels. Do not use performClick here.
        let local = CGPoint(x: button.bounds.minX + 3, y: button.bounds.minY + 3)
        let rootHit = root.hitTest(button.convert(local, to: root.superview))
        guard rootHit === button || rootHit?.isDescendant(of: button) == true else {
            let toolbar = try toolbar(in: editor), controls = visibleControls(editor)
            var evidence = toolbarMeasurements(editor, toolbar: toolbar, root: root, controls: controls).value
            evidence["cornerHitFailure"] = ["id": button.identifier?.rawValue ?? "", "localPoint": [local.x, local.y], "returned": hitDescription(rootHit)]
            let path = retainToolbarEvidence(evidence, root: root)
            XCTFail("primary-corner-hit: \(button.identifier?.rawValue ?? "") returned=\(hitDescription(rootHit)) \(path)")
            return
        }
        let location = button.convert(local, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true); button.mouseDown(with: down)
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
