import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import PicShotCore
import PicShotFormulaRenderCore
@testable import PicShot

/// Runs in the existing XCTest AppKit host. No app delegate, launch workflow,
/// file-open request, screen capture, or replacement application loop is installed.
@MainActor final class PinIsolationSurfaceTests: XCTestCase {
    func testImageIsolationKeepsWindowPixelsEditableContentAndExactPresentation() throws {
        try requireDisplay()
        let source = try raster(), pin = PinController(image: source, defaults: nil)
        defer { pin.close() }
        pin.configureEditableCapture(available: true, load: { nil })
        pin.applySavedTitle("Preserved image")
        pin.applyPresentation(PinPresentation(frame: PinWindowFrame(x: 120, y: 140, width: 320, height: 180),
            opacity: 0.4, zoom: 2, clickThrough: true, locked: true))
        pin.showWindow(nil)
        let window = try XCTUnwrap(pin.window), content = try XCTUnwrap(window.contentView)
        let before = pin.presentation, desktop = pin.desktopVisibility
        var changes = 0, closes = 0
        pin.onPresentationChange = { _ in changes += 1 }; pin.onPixelChange = { _, _ in changes += 1 }
        pin.onClose = { closes += 1 }
        for _ in 0..<20 {
            XCTAssertTrue(pin.canHideForVisibilityIsolation)
            try pin.setVisibilityIsolated(true); try pin.setVisibilityIsolated(true)
            XCTAssertTrue(pin.isVisibilityIsolated); XCTAssertFalse(window.isVisible)
            XCTAssertFalse(pin.canHideForVisibilityIsolation); XCTAssertFalse(pin.canParticipateInGroupTransform)
            pin.showWindow(nil); pin.bringForward(); pin.restore(); XCTAssertFalse(window.isVisible)
            XCTAssertTrue(pin.window === window); XCTAssertTrue(window.contentView === content)
            XCTAssertTrue(pin.currentImage === source); XCTAssertTrue(pin.image === source)
            XCTAssertTrue(pin.hasEditableCapture); XCTAssertEqual(pin.pinTitle, "Preserved image")
            XCTAssertEqual(pin.presentation, before); XCTAssertEqual(pin.desktopVisibility, desktop)
            try pin.setVisibilityIsolated(false); try pin.setVisibilityIsolated(false)
            XCTAssertFalse(pin.isVisibilityIsolated); XCTAssertTrue(window.isVisible)
            XCTAssertTrue(window.contentView === content); XCTAssertEqual(pin.presentation, before)
        }
        XCTAssertEqual(changes, 0); XCTAssertEqual(closes, 0)
    }

    func testIsolationDoesNotRestoreOrdinarilyHiddenOrPreviouslyInvisibleImagePins() throws {
        try requireDisplay()
        let pin = PinController(image: try raster(), defaults: nil); defer { pin.close() }
        let window = try XCTUnwrap(pin.window)
        try pin.setVisibilityIsolated(true); try pin.setVisibilityIsolated(false)
        XCTAssertFalse(window.isVisible, "Reversal only restores the prior visibility")
        pin.showWindow(nil); try pin.setVisibilityIsolated(true)
        pin.hideTemporarily()
        XCTAssertFalse(pin.isVisibilityIsolated); XCTAssertFalse(pin.canHideForVisibilityIsolation)
        try pin.setVisibilityIsolated(false); XCTAssertFalse(window.isVisible)
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        pin.showWindow(nil); XCTAssertTrue(window.isVisible)
        XCTAssertTrue(pin.canHideForVisibilityIsolation)
    }

    func testImageAnnotationRenameAndExportRefuseBeforeDiscardingTheirDrafts() throws {
        try requireDisplay()
        let pin = PinController(image: try raster(), defaults: nil); defer { pin.close() }
        pin.onRename = { _, _ in }; pin.showWindow(nil)
        pin.showAnnotations()
        let editor = try XCTUnwrap(pin.annotationEditor)
        editor.annotationCanvas.add(ImageAnnotation(tool: .rectangle,
            points: [CGPoint(x: 4, y: 4), CGPoint(x: 28, y: 20)]))
        let draft = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
        let editorVisible = editor.window?.isVisible
        XCTAssertFalse(pin.window?.isVisible == true)
        XCTAssertEqual(editorVisible, true)
        XCTAssertTrue(pin.hasVisibleSurfaceForVisibilityIsolation, "An ordered-out source pin must not hide its visible editor from admission")
        XCTAssertFalse(pin.canHideForVisibilityIsolation)
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        XCTAssertFalse(pin.isVisibilityIsolated); XCTAssertTrue(pin.annotationEditor === editor)
        XCTAssertEqual(editor.window?.isVisible, editorVisible)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document), draft)
        editor.close()
        pin.renamePin()
        let rename = try XCTUnwrap(pin.renameController)
        rename.nameField.stringValue = "Unsaved rename"
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        XCTAssertTrue(pin.renameController === rename); XCTAssertFalse(rename.completed)
        XCTAssertEqual(rename.nameField.stringValue, "Unsaved rename")
        rename.close()
        let menu = try XCTUnwrap(pin.actionMenu)
        try invoke(try XCTUnwrap(menu.item(withTitle: "当前图像另存为…")))
        let export = try XCTUnwrap(pin.imageExportController)
        XCTAssertFalse(export.isClosed); XCTAssertFalse(pin.canHideForVisibilityIsolation)
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        XCTAssertTrue(pin.imageExportController === export); XCTAssertFalse(export.isClosed)
        export.cancelExport()
        XCTAssertTrue(pin.canHideForVisibilityIsolation)
    }

    func testRichTextIsolationPreservesStorageSelectionAndRefusesLiveTextAndRenameDrafts() throws {
        try requireDisplay()
        let pin = try textPin(); defer { pin.close() }
        pin.onUpdateText = { _, _ in }; pin.onRename = { _, _ in }
        pin.showWindow(nil)
        pin.editPlainText()
        let editor = try XCTUnwrap(pin.textEditController)
        editor.textView.string = "Unsaved multiline\n草稿 🐱"
        let draft = editor.textView.string
        XCTAssertFalse(pin.canHideForVisibilityIsolation)
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        XCTAssertTrue(pin.textEditController === editor); XCTAssertEqual(editor.textView.string, draft)
        XCTAssertFalse(editor.completed)
        editor.close()
        pin.renamePin()
        let rename = try XCTUnwrap(pin.renameController)
        rename.nameField.stringValue = "Unsaved title"
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        XCTAssertEqual(rename.nameField.stringValue, "Unsaved title"); XCTAssertFalse(rename.completed)
        rename.close()
        pin.applyPresentation(PinPresentation(frame: PinWindowFrame(x: 150, y: 160, width: 340, height: 160),
            opacity: 0.6, zoom: 1.3, clickThrough: true, locked: true))
        pin.textDisplayView.setSelectedRange(NSRange(location: 0, length: 5))
        let selection = pin.textDisplayView.selectedRange(), storage = pin.textDisplayView.textStorage
        let document = pin.richDocument, presentation = pin.presentation
        let window = try XCTUnwrap(pin.window), content = window.contentView
        var changes = 0
        pin.onPresentationChange = { _ in changes += 1 }; pin.onRichChange = { _ in changes += 1 }
        for _ in 0..<20 {
            try pin.setVisibilityIsolated(true)
            XCTAssertFalse(window.isVisible); XCTAssertTrue(pin.isVisibilityIsolated)
            pin.showWindow(nil); XCTAssertFalse(window.isVisible)
            try pin.setVisibilityIsolated(false)
            XCTAssertTrue(window.isVisible); XCTAssertTrue(window.contentView === content)
            XCTAssertTrue(pin.textDisplayView.textStorage === storage)
            XCTAssertEqual(pin.textDisplayView.selectedRange(), selection)
            XCTAssertEqual(pin.richDocument, document); XCTAssertEqual(pin.presentation, presentation)
        }
        XCTAssertEqual(changes, 0)
    }

    func testLaTeXIsolationPreservesDormantDraftAndRefusesEditorRenderAndSave() throws {
        try requireDisplay()
        let pin = try latexPin(); defer { pin.close() }
        pin.showWindow(nil)
        let model = try XCTUnwrap(pin.latexModel), raster = try XCTUnwrap(pin.displayedLaTeXRaster)
        let document = pin.richDocument, before = pin.presentation
        model.source = "x + unsaved"
        try pin.setVisibilityIsolated(true); try pin.setVisibilityIsolated(false)
        XCTAssertTrue(pin.latexModel === model); XCTAssertEqual(model.source, "x + unsaved")
        XCTAssertTrue(pin.displayedLaTeXRaster === raster)
        XCTAssertEqual(pin.richDocument, document); XCTAssertEqual(pin.presentation, before)
        pin.editLaTeX()
        let editor = try XCTUnwrap(pin.latexEditorContentView)
        XCTAssertTrue(pin.hasActiveLaTeXEditorOrRender)
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        XCTAssertTrue(pin.latexEditorContentView === editor); XCTAssertEqual(model.source, "x + unsaved")
        pin.dismissLaTeXEditor()
        model.source = "y + unsaved"
        model.apply() // Admission is synchronous; cancellation precedes any helper execution.
        XCTAssertTrue(model.working); XCTAssertFalse(pin.canHideForVisibilityIsolation)
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        XCTAssertTrue(model.working); model.cancel()
        pin.beginLaTeXSave(.latex)
        let chooser = try XCTUnwrap(pin.latexSavePanel)
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
        XCTAssertTrue(pin.latexSavePanel === chooser); XCTAssertTrue(pin.hasLaTeXSavePanelCallbacks)
        pin.dismissLaTeXEditor()
        XCTAssertTrue(pin.canHideForVisibilityIsolation)
    }

    func testAnimationIsolationRestoresPriorPlaybackWithoutReplacingItsFrameOrWindow() async throws {
        try requireDisplay()
        let prepared = try PreparedRichPin(animation: gif(), title: "Animation")
        let pin = try RichPinController(asset: prepared.asset, data: prepared.data, title: prepared.title)
        defer { pin.close() }
        pin.showWindow(nil); pin.startPlayback()
        let window = try XCTUnwrap(pin.window)
        let imageView = try XCTUnwrap(descendants(window.contentView).compactMap { $0 as? NSImageView }.first)
        try await waitUntil { imageView.image != nil }
        let frame = imageView.image, content = window.contentView, before = pin.presentation
        XCTAssertTrue(pin.isAnimationPlaying)
        try pin.setVisibilityIsolated(true); try pin.setVisibilityIsolated(true)
        XCTAssertFalse(pin.isAnimationPlaying); XCTAssertFalse(window.isVisible)
        pin.startPlayback(); XCTAssertFalse(pin.isAnimationPlaying)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(imageView.image === frame)
        try pin.setVisibilityIsolated(false)
        XCTAssertTrue(pin.isAnimationPlaying); XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.contentView === content); XCTAssertEqual(pin.presentation, before)
        pin.pausePlayback()
        try pin.setVisibilityIsolated(true); try pin.setVisibilityIsolated(false)
        XCTAssertFalse(pin.isAnimationPlaying, "A paused animation must stay paused")
        try pin.setVisibilityIsolated(true); pin.close()
        try pin.setVisibilityIsolated(false); pin.startPlayback()
        XCTAssertFalse(pin.isAnimationPlaying); XCTAssertFalse(pin.isVisibilityIsolated)
        XCTAssertNil(window.contentView); XCTAssertNil(imageView.image)
        XCTAssertThrowsError(try pin.setVisibilityIsolated(true))
    }

    func testIsolationCancelsUncooperativeOCRAndResumesOnlyAfterReveal() async throws {
        try requireDisplay()
        let source = try raster(), gate = IsolationRecognitionGate(), scheduler = PinOCRScheduler()
        let expected = recognitionResult()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeWithOptions: { _, _ in await gate.wait() }, defaults: nil, ocrScheduler: scheduler)
        defer { pin.close() }
        pin.applyAutomaticOCR(true); pin.showWindow(nil)
        try await waitUntil { await gate.callCount == 1 }
        try pin.setVisibilityIsolated(true)
        XCTAssertEqual(pin.ocrSession.state, .suspended)
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 0)
        await gate.finishAll(expected)
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertNil(pin.textSelectionOverlay.document); XCTAssertEqual(pin.ocrSourceReadCount, 1)
        XCTAssertEqual(pin.ocrSession.state, .suspended)
        pin.applyAutomaticOCR(true); pin.showWindow(nil)
        XCTAssertEqual(pin.ocrSourceReadCount, 1)
        try pin.setVisibilityIsolated(false)
        try await waitUntil { await gate.callCount == 2 }
        await gate.finishAll(expected)
        try await waitUntil { pin.textSelectionOverlay.document != nil }
        XCTAssertEqual(pin.ocrSession.state, .ready)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 2)
        try pin.setVisibilityIsolated(true); pin.close()
        XCTAssertEqual(pin.ocrSession.state, .closed); XCTAssertFalse(pin.isVisibilityIsolated)
        XCTAssertNil(pin.window?.contentView); XCTAssertNil(pin.textSelectionOverlay.document)
    }

    func testReadyOCRSelectionAndResultPanelSurviveIsolationWithoutTakingFocus() async throws {
        try requireDisplay()
        let source = try raster(), expected = recognitionResult(), scheduler = PinOCRScheduler()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeForSelection: { _ in expected }, defaults: nil, ocrScheduler: scheduler)
        let sentinel = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 220, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        sentinel.isReleasedWhenClosed = false
        defer { pin.close(); sentinel.close() }
        pin.showWindow(nil); pin.setTextSelectionEnabled(true)
        try await waitUntil { pin.textSelectionOverlay.document != nil }
        pin.showRecognizedText(); try await waitUntil { pin.recognitionWindow != nil }
        let result = try XCTUnwrap(pin.recognitionWindow), resultWindow = try XCTUnwrap(result.window)
        pin.textSelectionOverlay.selectAll(nil)
        let range = pin.textSelectionOverlay.selectedRange, document = pin.textSelectionOverlay.document
        let resultText = result.resultText, content = resultWindow.contentView
        try pin.setVisibilityIsolated(true)
        XCTAssertFalse(resultWindow.isVisible); XCTAssertTrue(pin.recognitionWindow === result)
        XCTAssertTrue(resultWindow.contentView === content); XCTAssertEqual(result.resultText, resultText)
        XCTAssertEqual(pin.textSelectionOverlay.document, document)
        XCTAssertEqual(pin.textSelectionOverlay.selectedRange, range); XCTAssertTrue(pin.textSelectionEnabled)
        sentinel.makeKeyAndOrderFront(nil)
        let keyWindow = NSApp.keyWindow
        try pin.setVisibilityIsolated(false)
        try await waitUntil { pin.ocrSession.state == .ready }
        XCTAssertTrue(resultWindow.isVisible); XCTAssertTrue(pin.recognitionWindow === result)
        XCTAssertEqual(pin.textSelectionOverlay.selectedRange, range)
        XCTAssertEqual(result.resultText, resultText); XCTAssertTrue(NSApp.keyWindow === keyWindow)
        // A result surface can outlive a manually ordered-out source window.
        pin.window?.orderOut(nil)
        XCTAssertTrue(pin.hasVisibleSurfaceForVisibilityIsolation)
        try pin.setVisibilityIsolated(true); XCTAssertFalse(resultWindow.isVisible)
        try pin.setVisibilityIsolated(false)
        XCTAssertFalse(pin.window?.isVisible == true); XCTAssertTrue(resultWindow.isVisible)
        XCTAssertTrue(pin.recognitionWindow === result)
    }

    func testReadyBarcodePanelAndOverlaySurviveIsolation() async throws {
        try requireDisplay()
        let source = try raster()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false, defaults: nil,
            recognizeCodes: { _ in RecognizedBarcodeDocument(candidates: [], supportedSymbologies: []) })
        defer { pin.close() }
        pin.showWindow(nil); pin.setBarcodeSelectionEnabled(true)
        try await waitUntil { pin.barcodeWindow != nil }
        let panel = try XCTUnwrap(pin.barcodeWindow), window = try XCTUnwrap(panel.window)
        let content = window.contentView, document = pin.barcodeSelectionOverlay.document
        try pin.setVisibilityIsolated(true)
        XCTAssertTrue(pin.barcodeSelectionEnabled); XCTAssertFalse(window.isVisible)
        XCTAssertTrue(pin.barcodeWindow === panel); XCTAssertEqual(pin.barcodeSelectionOverlay.document, document)
        try pin.setVisibilityIsolated(false)
        XCTAssertTrue(window.isVisible); XCTAssertTrue(pin.barcodeWindow === panel)
        XCTAssertTrue(window.contentView === content); XCTAssertTrue(pin.barcodeSelectionEnabled)
    }

    func testRepeatedIsolationWaitsForCancelledBarcodeProviderBeforeStartingAnother() async throws {
        try requireDisplay()
        let source = try raster(), gate = IsolationBarcodeGate()
        let expected = RecognizedBarcodeDocument(candidates: [], supportedSymbologies: [])
        let pin = PinController(originalImage: source, currentImage: source, isModified: false, defaults: nil,
            recognizeCodes: { _ in await gate.wait() })
        defer { pin.close() }
        pin.showWindow(nil); pin.setBarcodeSelectionEnabled(true)
        try await waitUntil { await gate.callCount == 1 }
        for _ in 0..<20 {
            try pin.setVisibilityIsolated(true); try pin.setVisibilityIsolated(false)
        }
        let count = await gate.callCount
        XCTAssertEqual(count, 1, "An uncooperative cancelled provider must retain the sole in-flight slot")
        XCTAssertTrue(pin.barcodeSelectionEnabled); XCTAssertTrue(pin.barcodeIsRecognizing)
        await gate.finishAll(expected)
        try await waitUntil { await gate.callCount == 2 }
        XCTAssertNil(pin.barcodeWindow, "Cancelled results cannot create a late panel")
        await gate.finishAll(expected)
        try await waitUntil { pin.barcodeWindow != nil }
        XCTAssertFalse(pin.barcodeIsRecognizing)
        try pin.setVisibilityIsolated(true); pin.close()
        XCTAssertNil(pin.barcodeWindow); XCTAssertNil(pin.barcodeSelectionOverlay.document)
    }

    func testMenusRequireCallbacksAndCurrentEligibilityAndCloseClearsThem() throws {
        try requireDisplay()
        let image = PinController(image: try raster(), defaults: nil), rich = try textPin()
        defer { image.close(); rich.close() }
        image.showWindow(nil); rich.showWindow(nil)
        let imageMenu = try XCTUnwrap(image.actionMenu), richMenu = try XCTUnwrap(rich.window?.contentView?.menu)
        var calls = 0, selected = false, active = false
        for menu in [imageMenu, richMenu] {
            menu.update()
            for id in isolationMenuIDs {
                let item = try menuItem(id, in: menu)
                XCTAssertFalse(item.isEnabled); try invoke(item); XCTAssertEqual(calls, 0)
            }
        }
        image.onIsolateThisPin = { calls += 1 }; rich.onIsolateThisPin = { calls += 1 }
        image.onIsolateSelectedPins = { calls += 1 }; rich.onIsolateSelectedPins = { calls += 1 }
        image.onRestoreVisibilityIsolation = { calls += 1 }; rich.onRestoreVisibilityIsolation = { calls += 1 }
        image.canIsolateSelectedPins = { selected }; rich.canIsolateSelectedPins = { selected }
        image.hasVisibilityIsolation = { active }; rich.hasVisibilityIsolation = { active }
        for menu in [imageMenu, richMenu] {
            menu.update()
            XCTAssertTrue(try menuItem(isolationMenuIDs[0], in: menu).isEnabled)
            XCTAssertFalse(try menuItem(isolationMenuIDs[1], in: menu).isEnabled)
            XCTAssertFalse(try menuItem(isolationMenuIDs[2], in: menu).isEnabled)
            try invoke(try menuItem(isolationMenuIDs[0], in: menu))
        }
        XCTAssertEqual(calls, 2)
        selected = true; active = true
        for menu in [imageMenu, richMenu] {
            menu.update()
            for id in isolationMenuIDs { XCTAssertTrue(try menuItem(id, in: menu).isEnabled) }
            try invoke(try menuItem(isolationMenuIDs[1], in: menu))
            try invoke(try menuItem(isolationMenuIDs[2], in: menu))
        }
        XCTAssertEqual(calls, 6)
        // A stale enabled menu item must recheck the query when invoked.
        selected = false; active = false
        for menu in [imageMenu, richMenu] {
            try invoke(try menuItem(isolationMenuIDs[1], in: menu))
            try invoke(try menuItem(isolationMenuIDs[2], in: menu))
        }
        XCTAssertEqual(calls, 6)
        try image.setVisibilityIsolated(true); try rich.setVisibilityIsolated(true)
        image.close(); rich.close()
        XCTAssertNil(image.onIsolateThisPin); XCTAssertNil(image.onIsolateSelectedPins)
        XCTAssertNil(image.onRestoreVisibilityIsolation); XCTAssertNil(image.canIsolateSelectedPins); XCTAssertNil(image.hasVisibilityIsolation)
        XCTAssertNil(rich.onIsolateThisPin); XCTAssertNil(rich.onIsolateSelectedPins)
        XCTAssertNil(rich.onRestoreVisibilityIsolation); XCTAssertNil(rich.canIsolateSelectedPins); XCTAssertNil(rich.hasVisibilityIsolation)
        for menu in [imageMenu, richMenu] {
            for id in isolationMenuIDs { try invoke(try menuItem(id, in: menu)) }
        }
        XCTAssertEqual(calls, 6)
    }

    private let isolationMenuIDs = ["pin-visibility-isolate-this", "pin-visibility-isolate-selected", "pin-visibility-restore"]
    private func requireDisplay() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Native pin surfaces require an AppKit display") }
    }
    private func raster(red: CGFloat = 0.3) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32)); return try XCTUnwrap(context.makeImage())
    }
    private func textPin() throws -> RichPinController {
        let prepared = try PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: "Saved text\n原文 🐱")), title: "Text")
        return try RichPinController(asset: prepared.asset, data: prepared.data, title: prepared.title)
    }
    private func latexPin() throws -> RichPinController {
        let image = try raster(), request = FormulaRenderRequest(latex: "x")
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let result = FormulaRenderResult(latex: "x", svg: "<svg />", mathML: "<math ><mi>x</mi></math>",
            png: png, pdf: Data("%PDF-isolation-fixture".utf8), width: 64, height: 32, pointWidth: 32, pointHeight: 16)
        let prepared = try PreparedRichPin(formula: request, result: result)
        return try RichPinController(asset: prepared.asset, data: prepared.data, title: prepared.title, renderedImage: prepared.poster)
    }
    private func gif() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for red in [CGFloat(0.2), CGFloat(0.8)] {
            CGImageDestinationAddImage(destination, try raster(red: red),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    private func recognitionResult() -> RecognitionResult {
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        return RecognitionResult(text: document.text, barcodes: [], document: document)
    }
    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private func menuItem(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == identifier })
    }
    private func invoke(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !(await condition()), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let ready = await condition(); XCTAssertTrue(ready, file: file, line: line)
    }
}

private actor IsolationRecognitionGate {
    private(set) var callCount = 0
    private var waiters: [CheckedContinuation<RecognitionResult, Never>] = []
    func wait() async -> RecognitionResult {
        callCount += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func finishAll(_ result: RecognitionResult) {
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume(returning: result) }
    }
}

private actor IsolationBarcodeGate {
    private(set) var callCount = 0
    private var waiters: [CheckedContinuation<RecognizedBarcodeDocument, Never>] = []
    func wait() async -> RecognizedBarcodeDocument {
        callCount += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func finishAll(_ result: RecognizedBarcodeDocument) {
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume(returning: result) }
    }
}
