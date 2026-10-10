import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class AnnotationStylePresetTests: XCTestCase {
    private let points = [CGPoint(x: 20, y: 60), CGPoint(x: 100, y: 60)]
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PicShot-AnnotationStylePresetTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
    private func original(_ tool: ImageEditorTool) -> ImageAnnotation {
        AnnotationStyleAdapter.original(tool: tool, captureTimestampKnown: true)
    }

    func testNoSavedPreferencesRetainOriginalCreationDefaultsAndLegacyCarryover() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: try blank(), captureDate: Date(timeIntervalSince1970: 123))
        for tool in ImageEditorTool.allCases where ![.select, .crop].contains(tool) {
            let mark = canvas.makeAnnotation(tool: tool, points: points)
            XCTAssertEqual(mark.lineWidth, 4, tool.rawValue)
            XCTAssertEqual(mark.effectiveFontSize, 20, tool.rawValue)
            XCTAssertEqual(mark.opacity, 1, tool.rawValue)
            XCTAssertTrue(mark.freehandSmoothing, tool.rawValue)
            XCTAssertEqual(mark.highlighterMode, .freehand); XCTAssertEqual(mark.highlighterBlend, .multiply)
            XCTAssertEqual(mark.effectiveEndArrowEnabled, tool == .arrow)
            XCTAssertEqual(mark.color, tool == .redact ? CGColor(gray: 0, alpha: 1) : NSColor.systemRed.cgColor)
        }
        canvas.style.lineWidth = 10; canvas.style.color = NSColor.blue.cgColor
        canvas.tool = .rectangle
        XCTAssertEqual(canvas.makeAnnotation(tool: .rectangle, points: points).lineWidth, 10)
        XCTAssertEqual(canvas.style.color, NSColor.blue.cgColor)
        canvas.tool = .text; XCTAssertEqual(canvas.style.lineWidth, 10)
        let editing = ImageEditorCanvas(image: try blank())
        XCTAssertEqual(editing.makeAnnotation(tool: .watermark, points: points).watermarkTemplate, "PicShot · 编辑于 $yyyy-MM-dd HH:mm:ss$")
    }

    func testSaveEveryDrawingToolPersistsAppearanceOnlyAndFreshMarksOwnTheirMetadata() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let store = AnnotationStylePresetStore(defaults: defaults)
            for tool in ImageEditorTool.allCases where ![.select, .crop].contains(tool) {
                var source = original(tool)
                source.points = [CGPoint(x: 11_111, y: 22_222)]
                source.text = "PRIVATE_TEXT"; source.number = 333; source.numberComment = "PRIVATE_COMMENT"
                source.watermarkTemplate = "PRIVATE_WATERMARK"; source.rotation = 0.7
                source.textBoxSize = CGSize(width: 333, height: 444)
                source.magnifierSource = CGRect(x: 99, y: 88, width: 77, height: 66)
                source.frozenTimestamp = Date(timeIntervalSince1970: 777_777)
                source.frozenTimeZoneIdentifier = "PRIVATE_ZONE"; source.freehandCorners = [123, 456]
                source.arcStartAngle = 1; source.arcSweepAngle = 1
                try store.save(source)
            }
            let data = try XCTUnwrap(defaults.data(forKey: AnnotationStyleSettings.preferenceKey))
            XCTAssertLessThan(data.count, AnnotationStyleSettings.maximumEncodedBytes)
            let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(encoded.contains("PRIVATE_"))
            func allKeys(_ value: Any) -> Set<String> {
                if let object = value as? [String: Any] {
                    return Set(object.keys).union(object.values.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) })
                }
                if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) } }
                return []
            }
            let keys = allKeys(try JSONSerialization.jsonObject(with: data))
            for prohibited in ["points", "text", "number", "numberComment", "watermarkTemplate", "rotation", "textBoxSize", "magnifierSource", "frozenTimestamp", "frozenTimeZoneIdentifier", "mosaicLink", "freehandCorners", "arcStartAngle", "arcSweepAngle"] {
                XCTAssertFalse(keys.contains(prohibited), prohibited)
            }
            let canvas = ImageEditorCanvas(image: try blank(), captureDate: Date(timeIntervalSince1970: 123), timeZone: TimeZone(secondsFromGMT: 0)!, styleDefaults: defaults)
            for tool in ImageEditorTool.allCases where ![.select, .crop].contains(tool) {
                let mark = canvas.makeAnnotation(tool: tool, points: points, text: "fresh input")
                XCTAssertEqual(mark.points, points)
                XCTAssertEqual(mark.text, "fresh input"); XCTAssertEqual(mark.numberComment, "")
                XCTAssertEqual(mark.number, 1); XCTAssertEqual(mark.rotation, 0)
                XCTAssertNil(mark.magnifierSource); XCTAssertNil(mark.mosaicLink); XCTAssertNil(mark.textBoxSize)
                XCTAssertTrue(mark.freehandCorners.isEmpty)
                XCTAssertEqual(mark.frozenTimestamp, Date(timeIntervalSince1970: 123))
                XCTAssertEqual(mark.frozenTimeZoneIdentifier, "GMT")
                XCTAssertEqual(mark.watermarkTemplate, "PicShot · $yyyy-MM-dd HH:mm:ss$")
                XCTAssertEqual(mark.arcStartAngle, 0); XCTAssertEqual(mark.arcSweepAngle, .pi * 1.5)
            }
        }
    }

    func testSavedToolIsolationRestoreResetAndFreshEditorPersistence() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let canvas = ImageEditorCanvas(image: try blank(), styleDefaults: defaults)
            var arrow = original(.arrow); arrow.color = NSColor.blue.cgColor; arrow.lineWidth = 12; arrow.endArrowhead = .diamond
            try canvas.saveDefaultStyle(from: arrow)
            XCTAssertTrue(canvas.hasSavedStyle(for: .arrow)); XCTAssertFalse(canvas.hasSavedStyle(for: .line))
            XCTAssertEqual(canvas.makeAnnotation(tool: .arrow, points: points).lineWidth, 12)
            canvas.style.lineWidth = 24
            canvas.tool = .line
            XCTAssertEqual(canvas.makeAnnotation(tool: .line, points: points).lineWidth, 4)
            XCTAssertEqual(canvas.style.color, NSColor.systemRed.cgColor)
            canvas.tool = .arrow; XCTAssertEqual(canvas.style.lineWidth, 24)
            canvas.restoreSavedStyle(for: .arrow); XCTAssertEqual(canvas.style.lineWidth, 12)
            let fresh = ImageEditorCanvas(image: try blank(), styleDefaults: defaults)
            XCTAssertEqual(fresh.style.lineWidth, 12); XCTAssertEqual(fresh.style.endArrowhead, .diamond)
            try canvas.resetDefaultStyle(for: .arrow)
            XCTAssertFalse(canvas.hasSavedStyle(for: .arrow)); XCTAssertEqual(canvas.style.lineWidth, 4)
            XCTAssertTrue(canvas.makeAnnotation(tool: .arrow, points: points).effectiveEndArrowEnabled)
            XCTAssertEqual(ImageEditorCanvas(image: try blank(), styleDefaults: defaults).style.lineWidth, 4)
            XCTAssertNil(defaults.object(forKey: AnnotationStyleSettings.preferenceKey))
        }
    }

    func testMultipleOpenEditorsSaveAndResetWithoutDroppingAnotherTool() throws {
        try withDefaults { defaults in
            let a = AnnotationStylePresetStore(defaults: defaults), b = AnnotationStylePresetStore(defaults: defaults)
            var arrow = original(.arrow); arrow.lineWidth = 10
            var text = original(.text); text.fontSize = 28
            try a.save(arrow); try b.save(text)
            XCTAssertEqual(a.settings.styles.count, 2)
            try a.reset(.arrow)
            XCTAssertEqual(b.style(for: .text)?.values[.fontSize], .number(28))
            XCTAssertNil(b.style(for: .arrow))
        }
    }

    func testSettingsActionsDoNotChangeExistingSelectionPixelsOrUndoAndKeepDraftUntouched() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: try blank())
        let old = canvas.makeAnnotation(tool: .arrow, points: points)
        canvas.add(old)
        let before = try pixels(XCTUnwrap(canvas.flattened()))
        var changes = 0; canvas.onWillChange = { changes += 1 }
        var saved = old; saved.color = NSColor.blue.cgColor; saved.lineWidth = 12
        try canvas.saveDefaultStyle(from: saved)
        canvas.restoreSavedStyle(for: .arrow); try canvas.resetDefaultStyle(for: .arrow)
        XCTAssertEqual(changes, 0); XCTAssertEqual(canvas.selectedAnnotation?.id, old.id)
        XCTAssertEqual(canvas.annotations.first?.lineWidth, old.lineWidth)
        XCTAssertEqual(try pixels(XCTUnwrap(canvas.flattened())), before)
        canvas.tool = .polyline
        try click(canvas, CGPoint(x: 20, y: 20)); try click(canvas, CGPoint(x: 80, y: 30))
        let draft = try XCTUnwrap(canvas.pendingPolyline)
        var preset = original(.polyline); preset.lineWidth = 16
        try canvas.saveDefaultStyle(from: preset)
        canvas.restoreSavedStyle(for: .polyline); try canvas.resetDefaultStyle(for: .polyline)
        XCTAssertEqual(canvas.pendingPolyline?.id, draft.id)
        XCTAssertEqual(canvas.pendingPolyline?.lineWidth, draft.lineWidth)
        XCTAssertEqual(canvas.pendingPolyline?.points, draft.points)
        XCTAssertEqual(changes, 0)
        canvas.cancelPolyline()
        XCTAssertNil(canvas.pendingPolyline); XCTAssertEqual(canvas.annotations.count, 1)
    }

    func testActualMouseCreationUsesSavedStylesAndChangesRealPixels() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let store = AnnotationStylePresetStore(defaults: defaults)
            var line = original(.line); line.color = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1); line.lineWidth = 12
            var rectangle = original(.rectangle); rectangle.fillEnabled = true
            rectangle.fillColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            try store.save(line); try store.save(rectangle)
            let canvas = ImageEditorCanvas(image: try blank(), styleDefaults: defaults)
            canvas.tool = .line
            try drag(canvas, from: points[0], to: points[1])
            XCTAssertEqual(canvas.annotations.count, 1); XCTAssertEqual(canvas.annotations[0].lineWidth, 12)
            XCTAssertEqual(try pixel(XCTUnwrap(canvas.flattened()), x: 60, y: 60), [0, 0, 255, 255])
            XCTAssertEqual(try pixel(XCTUnwrap(canvas.flattened()), x: 60, y: 64), [0, 0, 255, 255])
            canvas.setContent(image: try blank(), annotations: [])
            canvas.tool = .rectangle
            try drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 100))
            XCTAssertEqual(canvas.annotations.count, 1); XCTAssertTrue(canvas.annotations[0].fillEnabled)
            XCTAssertEqual(try pixel(XCTUnwrap(canvas.flattened()), x: 60, y: 60), [0, 255, 0, 255])
            try canvas.resetDefaultStyle(for: .rectangle)
            let original = canvas.makeAnnotation(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100)])
            XCTAssertFalse(original.fillEnabled)
            XCTAssertEqual(try pixel(XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [original])), x: 60, y: 60), [255, 255, 255, 255])
        }
    }

    func testOriginalAndResetStylesHaveExactCreationPixelsForEveryDrawingTool() throws {
        _ = NSApplication.shared
        let image = try blank(), date = Date(timeIntervalSince1970: 123)
        let canvas = ImageEditorCanvas(image: image, captureDate: date, timeZone: TimeZone(secondsFromGMT: 0)!)
        for tool in ImageEditorTool.allCases where ![.select, .crop].contains(tool) {
            let area = [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100)]
            let before = canvas.makeAnnotation(tool: tool, points: area, text: "Abc")
            try canvas.saveDefaultStyle(from: before)
            try canvas.resetDefaultStyle(for: tool)
            let after = canvas.makeAnnotation(tool: tool, points: area, text: "Abc")
            XCTAssertEqual(try pixels(XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [before]))),
                           try pixels(XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [after]))), tool.rawValue)
        }
    }

    func testSavedTextAppearanceRoundTripsIntoRealRenderingWithoutCopyingText() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            var source = original(.text)
            source.text = "PRIVATE_TEXT"; source.fontName = "Menlo-Regular"; source.fontSize = 24
            source.bold = true; source.italic = true; source.underline = true
            source.color = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1); source.opacity = 0.7
            source.fillEnabled = true; source.fillColor = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1); source.cornerRadius = 6
            source.textOutlineEnabled = true; source.textOutlineWidth = 2
            source.textOutlineColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            try AnnotationStylePresetStore(defaults: defaults).save(source)
            let image = try blank(), canvas = ImageEditorCanvas(image: image, styleDefaults: defaults)
            let mark = canvas.makeAnnotation(tool: .text, points: [CGPoint(x: 10, y: 40)], text: "Hello")
            var expected = source; expected.points = mark.points; expected.text = "Hello"
            XCTAssertEqual(mark.text, "Hello"); XCTAssertTrue(mark.bold && mark.italic && mark.underline && mark.fillEnabled && mark.textOutlineEnabled)
            XCTAssertEqual(try pixels(XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [mark]))),
                           try pixels(XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [expected]))))
            XCTAssertNotEqual(try pixels(XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [mark]))), try pixels(image))
        }
    }

    func testInvalidAppearanceSaveDoesNotReplacePreviouslySavedStyle() throws {
        try withDefaults { defaults in
            let store = AnnotationStylePresetStore(defaults: defaults)
            try store.save(original(.text))
            let before = defaults.data(forKey: AnnotationStyleSettings.preferenceKey)
            var invalid = original(.text); invalid.fontName = "PRIVATE_FONT_STRING"
            XCTAssertThrowsError(try store.save(invalid))
            invalid = original(.text); invalid.opacity = .infinity
            XCTAssertThrowsError(try store.save(invalid))
            XCTAssertEqual(defaults.data(forKey: AnnotationStyleSettings.preferenceKey), before)
        }
    }

    func testRequiredEffectsStillFailClosedAndOpaqueToolsCannotPersistTransparency() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: try blank())
        var blur = original(.blur); blur.lineWidth = 12
        try canvas.saveDefaultStyle(from: blur)
        canvas.effectPatchRenderer = { _, _ in nil }
        canvas.add(canvas.makeAnnotation(tool: .blur, points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 80)]))
        XCTAssertNil(canvas.flattened())
        var redact = original(.redact); redact.color = CGColor(gray: 1, alpha: 0); redact.opacity = 0.05
        try canvas.saveDefaultStyle(from: redact)
        let safe = canvas.makeAnnotation(tool: .redact, points: points)
        XCTAssertEqual(safe.color, CGColor(gray: 0, alpha: 1)); XCTAssertEqual(safe.opacity, 1)
        XCTAssertEqual(try AnnotationStyleAdapter.capture(redact).values, [:])
        for tool in [ImageEditorTool.spotlight, .magnifier] {
            var appearance = original(tool); appearance.opacity = 0.05
            try canvas.saveDefaultStyle(from: appearance)
            XCTAssertEqual(canvas.makeAnnotation(tool: tool, points: points).opacity, 1)
        }
    }

    func testInspectorMenuIsCompactToolSpecificAndRoutesToFutureDefaultsOnly() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let editor = ImageEditorController(image: try blank(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, defaults: defaults)
            defer { editor.close() }; editor.showWindow(nil)
            var mark = original(.rectangle); mark.points = [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)]
            mark.lineWidth = 12; mark.fillEnabled = true; editor.annotationCanvas.add(mark)
            editor.chooseTool(.select)
            let menu = try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "annotation.savedStyles" } as? NSPopUpButton)
            let save = try XCTUnwrap(menu.itemArray.first { $0.identifier?.rawValue == "annotation.savedStyles.save" })
            let restore = try XCTUnwrap(menu.itemArray.first { $0.identifier?.rawValue == "annotation.savedStyles.restore" })
            let reset = try XCTUnwrap(menu.itemArray.first { $0.identifier?.rawValue == "annotation.savedStyles.reset" })
            XCTAssertEqual(menu.item(at: 0)?.title, "样式")
            XCTAssertEqual(menu.item(at: 0)?.tag, -1)
            XCTAssertTrue(save.title.contains("矩形")); XCTAssertFalse(restore.isEnabled)
            let before = try pixels(XCTUnwrap(editor.annotationCanvas.flattened()))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(save.action), to: save.target, from: save))
            XCTAssertEqual(menu.item(at: 0)?.title, "样式", "Save must not replace the pull-down title")
            XCTAssertTrue(restore.isEnabled)
            XCTAssertNotNil(AnnotationStyleSettings.read(from: defaults).style(for: .rectangle))
            XCTAssertNil(AnnotationStyleSettings.read(from: defaults).style(for: .arrow))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(restore.action), to: restore.target, from: restore))
            XCTAssertEqual(menu.item(at: 0)?.title, "样式", "Restore must not replace the pull-down title")
            XCTAssertEqual(editor.annotationCanvas.makeAnnotation(tool: .rectangle, points: points).lineWidth, 12)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reset.action), to: reset.target, from: reset))
            XCTAssertEqual(menu.item(at: 0)?.title, "样式", "Reset must not replace the pull-down title")
            XCTAssertEqual(editor.annotationCanvas.makeAnnotation(tool: .rectangle, points: points).lineWidth, 4)
            XCTAssertFalse(restore.isEnabled)
            XCTAssertEqual(editor.annotationCanvas.annotations.first?.id, mark.id)
            XCTAssertEqual(try pixels(XCTUnwrap(editor.annotationCanvas.flattened())), before)
            XCTAssertEqual(menu.item(at: 0)?.title, "样式", "Action refresh must preserve the visible pull-down title")
            XCTAssertLessThanOrEqual(menu.fittingSize.width, 60)
            editor.chooseTool(.crop); XCTAssertFalse(editor.contextualPaletteVisible)
        }
    }

    func testExplicitSaveSurvivesEditorCancellationWithoutSavingAnnotationContent() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            var outputs = 0
            let editor = ImageEditorController(image: try blank(), onSave: { _ in outputs += 1 }, onPin: { _ in }, onOCR: { _ in }, defaults: defaults)
            defer { editor.close() }; editor.showWindow(nil)
            editor.annotationCanvas.style.lineWidth = 16
            let menu = try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "annotation.savedStyles" } as? NSPopUpButton)
            let save = try XCTUnwrap(menu.itemArray.first { $0.identifier?.rawValue == "annotation.savedStyles.save" })
            // Refresh the displayed future style after changing it in this fixture.
            editor.chooseTool(.arrow)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(save.action), to: save.target, from: save))
            let cancel = try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "editor.cancel" } as? NSButton)
            cancel.performClick(nil)
            XCTAssertTrue(editor.isClosed); XCTAssertEqual(outputs, 0)
            XCTAssertEqual(ImageEditorCanvas(image: try blank(), styleDefaults: defaults).style.lineWidth, 16)
        }
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }

    private func blank() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 128 * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        return try XCTUnwrap(context.makeImage())
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: CGFloat(-x), y: CGFloat(-y)); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }
    private func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func click(_ canvas: ImageEditorCanvas, _ point: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point))
    }
    private func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start)); canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }
}
