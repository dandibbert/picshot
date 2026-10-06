import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class PinBarcodeSelectionTests: XCTestCase {
    @MainActor func testNativeSelectionCopyKeyboardAndExplicitOpenFixture() throws {
        _ = NSApplication.shared
        let checks = try BarcodeAcceptanceFixture.verifyInteractions(image: BarcodeAcceptanceFixture.nearMissRaster())
        for key in ["nativeRegionSelection", "listSelectionSync", "keyboardNavigation", "exactUnicodeCopy", "nativeCopyShortcut", "escapeReleasesResults", "explicitValidatedOpenOnly", "isolatedPasteboard"] {
            XCTAssertEqual(checks[key] as? Bool, true, key)
        }
        XCTAssertEqual(checks["injectedOpenerCallCount"] as? Int, 1)
    }
    @MainActor func testIdlePinHasNoBarcodeControlsAndCompactResultsSyncWithSourceRegions() async throws {
        _ = NSApplication.shared
        let image = try BarcodeAcceptanceFixture.nearMissRaster(), document = BarcodeAcceptanceFixture.deterministicDocument()
        let pin = PinController(originalImage: image, currentImage: image, isModified: false, recognizeCodes: { _ in document })
        defer { pin.close() }
        XCTAssertFalse(pin.barcodeSelectionEnabled); XCTAssertNil(pin.barcodeSelectionOverlay.superview)
        XCTAssertNil(pin.barcodeWindow); XCTAssertFalse(descendants(try XCTUnwrap(pin.window?.contentView)).contains { $0 is NSButton })
        XCTAssertNotNil(pin.actionMenu?.item(withTitle: "识别")?.submenu?.item(withTitle: "识别二维码 / 条码…"))
        pin.bringForward(); pin.setBarcodeSelectionEnabled(true); try await BarcodeAcceptanceFixture.waitForPin(pin)
        let browser = try XCTUnwrap(pin.barcodeWindow), overlay = pin.barcodeSelectionOverlay
        XCTAssertFalse(browser.showsSourceImage); XCTAssertTrue(browser.preview.isHidden); XCTAssertNil(browser.preview.image)
        XCTAssertEqual(overlay.document, document); XCTAssertEqual(overlay.selectedIndex, 0)
        browser.selectResult(at: 1); XCTAssertEqual(overlay.selectedIndex, 1)
        let window = try XCTUnwrap(pin.window)
        pin.applyPresentation(PinPresentation(frame: PinWindowFrame(x: 40, y: 70, width: 320, height: 200), zoom: 2))
        let scroll = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 70, y: 25)); scroll.reflectScrolledClipView(scroll.contentView)
        let expected = try XCTUnwrap(pin.annotationPresentation?.imageFrame)
        let actual = window.convertToScreen(overlay.convert(overlay.imageRect, to: nil))
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01); XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.01); XCTAssertEqual(actual.height, expected.height, accuracy: 0.01)
        let box = try XCTUnwrap(document.results[0].quad?.bounds)
        let point = CGPoint(x: overlay.imageRect.minX + box.midX * overlay.imageRect.width, y: overlay.imageRect.minY + box.midY * overlay.imageRect.height)
        overlay.mouseDown(with: try PinTextSelectionSmokeFixture.mouse(.leftMouseDown, point: point, view: overlay))
        XCTAssertEqual(browser.selectedIndex, 0); XCTAssertEqual(browser.resultText, document.results[0].payload)
        XCTAssertNil(overlay.hitTest(CGPoint(x: overlay.imageRect.minX + 0.5 * overlay.imageRect.width, y: overlay.imageRect.midY)))
        _ = overlay.handleKeyDown(try PinTextSelectionSmokeFixture.key("", code: 53, flags: [], window: window))
        XCTAssertFalse(pin.barcodeSelectionEnabled); XCTAssertNil(pin.barcodeWindow); XCTAssertNil(overlay.document); XCTAssertNil(overlay.superview)
        XCTAssertTrue(window.isVisible)
    }
    @MainActor func testNoGeometryStillAllowsExactListCopyAndUnsafePayloadNeverOpens() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        let document = RecognizedBarcodeDocument(candidates: [RecognizedBarcode(symbology: .qr, payload: "javascript:alert('untrusted')", quad: nil)], supportedSymbologies: [.qr])
        var opened = false
        let controller = BarcodeResultController(image: try BarcodeAcceptanceFixture.nearMissRaster(), document: document, openURL: { _ in opened = true })
        defer { controller.close() }
        XCTAssertFalse(controller.offersOpen); XCTAssertTrue(controller.copySelected(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "javascript:alert('untrusted')")
        controller.openSelected(nil); XCTAssertFalse(opened)
    }
    @MainActor func testLateResultsCannotSurviveRestartHideEditOrClose() async throws {
        _ = NSApplication.shared
        let image = try BarcodeAcceptanceFixture.nearMissRaster(), document = BarcodeAcceptanceFixture.deterministicDocument(), gate = BarcodeSelectionTestGate()
        let pin = PinController(originalImage: image, currentImage: image, isModified: false, recognizeCodes: { _ in await gate.wait() })
        defer { pin.close(); Task { await gate.finishAll(document) } }
        pin.setBarcodeSelectionEnabled(true); try await waitUntil { await gate.count == 1 }
        pin.setBarcodeSelectionEnabled(false); pin.setBarcodeSelectionEnabled(true); try await waitUntil { await gate.count == 2 }
        await gate.finishFirst(document); try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(pin.barcodeIsRecognizing); XCTAssertNil(pin.barcodeWindow); XCTAssertNil(pin.barcodeSelectionOverlay.document)
        await gate.finishFirst(document); try await BarcodeAcceptanceFixture.waitForPin(pin)
        try pin.applyTransform(.rotateClockwise)
        XCTAssertFalse(pin.barcodeSelectionEnabled); XCTAssertNil(pin.barcodeWindow); XCTAssertNil(pin.barcodeSelectionOverlay.document)
        pin.setBarcodeSelectionEnabled(true); try await waitUntil { await gate.count == 1 }
        pin.hideTemporarily(); await gate.finishFirst(document); try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(pin.barcodeSelectionEnabled); XCTAssertNil(pin.barcodeWindow)
        pin.bringForward(); pin.setBarcodeSelectionEnabled(true); try await waitUntil { await gate.count == 1 }
        pin.close(); await gate.finishFirst(document); try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(pin.window?.contentView); XCTAssertNil(pin.barcodeWindow); XCTAssertNil(pin.barcodeSelectionOverlay.document)
        XCTAssertNil(pin.barcodeSelectionOverlay.onSelect); XCTAssertNil(pin.barcodeSelectionOverlay.onCopy)
    }
    @MainActor func testSpaceOCRCropAndClickThroughPreserveModeIsolation() async throws {
        _ = NSApplication.shared
        let image = try BarcodeAcceptanceFixture.nearMissRaster(), document = BarcodeAcceptanceFixture.deterministicDocument()
        let text = PinTextSelectionSmokeFixture.deterministicDocument()
        let pin = PinController(originalImage: image, currentImage: image, isModified: false,
                                recognizeForSelection: { _ in RecognitionResult(text: text.text, barcodes: [], document: text) }, recognizeCodes: { _ in document })
        defer { pin.close() }
        pin.bringForward(); pin.setBarcodeSelectionEnabled(true); try await BarcodeAcceptanceFixture.waitForPin(pin)
        let overlay = pin.barcodeSelectionOverlay
        _ = overlay.handleKeyDown(try PinTextSelectionSmokeFixture.key(" ", code: 49, flags: [], window: try XCTUnwrap(pin.window)))
        XCTAssertNotNil(pin.annotationEditor); XCTAssertFalse(pin.barcodeSelectionEnabled); XCTAssertNil(pin.barcodeWindow)
        pin.annotationEditor?.close(); pin.setBarcodeSelectionEnabled(true); try await BarcodeAcceptanceFixture.waitForPin(pin)
        pin.setTextSelectionEnabled(true)
        XCTAssertFalse(pin.barcodeSelectionEnabled); XCTAssertNil(pin.barcodeWindow)
        try await waitUntil { !pin.textSelectionIsRecognizing }
        XCTAssertTrue(pin.textSelectionEnabled); XCTAssertEqual(pin.textSelectionOverlay.document, text)
        pin.setBarcodeSelectionEnabled(true); try await BarcodeAcceptanceFixture.waitForPin(pin)
        XCTAssertFalse(pin.textSelectionEnabled); XCTAssertNil(pin.textSelectionOverlay.document)
        try pin.cropImage(to: CGRect(x: 10, y: 10, width: 200, height: 100))
        XCTAssertFalse(pin.barcodeSelectionEnabled); XCTAssertNil(pin.barcodeWindow)
        pin.setBarcodeSelectionEnabled(true); try await BarcodeAcceptanceFixture.waitForPin(pin)
        var presentation = pin.presentation; presentation.clickThrough = true; pin.applyPresentation(presentation)
        XCTAssertFalse(pin.barcodeSelectionEnabled); pin.setBarcodeSelectionEnabled(true); XCTAssertFalse(pin.barcodeSelectionEnabled)
        pin.restore(); pin.setBarcodeSelectionEnabled(true); XCTAssertTrue(pin.barcodeSelectionEnabled)
    }
    @MainActor func testFailedPersistenceKeepsCurrentCodeSelection() async throws {
        _ = NSApplication.shared
        let image = try BarcodeAcceptanceFixture.nearMissRaster(), document = BarcodeAcceptanceFixture.deterministicDocument()
        let pin = PinController(originalImage: image, currentImage: image, isModified: false, recognizeCodes: { _ in document })
        defer { pin.close() }
        pin.setBarcodeSelectionEnabled(true); try await BarcodeAcceptanceFixture.waitForPin(pin)
        pin.barcodeWindow?.selectResult(at: 1)
        pin.onPixelChange = { _, _ in throw PicShotError.message("Disk full") }
        XCTAssertThrowsError(try pin.applyTransform(.invert))
        XCTAssertTrue(pin.barcodeSelectionEnabled); XCTAssertEqual(pin.barcodeSelectionOverlay.selectedIndex, 1)
        XCTAssertTrue(pin.currentImage === image); XCTAssertEqual(pin.barcodeWindow?.resultText, document.results[1].payload)
    }
    @MainActor func testGroupSwitchDoesNotRestoreBarcodeMode() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PinBarcodeGroup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory), coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        defer { try? coordinator.prepareForTermination() }
        let id = try coordinator.add(image: BarcodeAcceptanceFixture.nearMissRaster()), other = try store.createGroup(name: "Other")
        let old = try XCTUnwrap(coordinator.liveControllers[id]); old.setBarcodeSelectionEnabled(true)
        try coordinator.switchGroup(id: other.id)
        XCTAssertFalse(old.barcodeSelectionEnabled); XCTAssertNil(old.barcodeWindow); XCTAssertNil(old.barcodeSelectionOverlay.document)
        try coordinator.switchGroup(id: PinGroup.defaultID)
        let restored = try XCTUnwrap(coordinator.liveControllers[id]); XCTAssertFalse(restored === old)
        XCTAssertFalse(restored.barcodeSelectionEnabled); XCTAssertNil(restored.barcodeSelectionOverlay.superview)
    }
    @MainActor func testOCRMoreMenuOpensExistingTypedResultsOnlyWhenSupplied() throws {
        _ = NSApplication.shared
        var requests = 0
        let withCodes = TextResultController(text: "OCR and codes", onBarcodes: { requests += 1 })
        let withoutCodes = TextResultController(text: "OCR only")
        defer { withCodes.close(); withoutCodes.close() }
        func item(in controller: TextResultController) -> NSMenuItem? {
            guard let content = controller.window?.contentView else { return nil }
            return descendants(content).compactMap { $0 as? NSPopUpButton }.flatMap { $0.itemArray }.first { $0.title == "二维码 / 条码结果…" }
        }
        let route = try XCTUnwrap(item(in: withCodes)); XCTAssertNil(item(in: withoutCodes))
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(route.action), to: route.target, from: route)); XCTAssertEqual(requests, 1)
        withCodes.close()
        _ = NSApp.sendAction(try XCTUnwrap(route.action), to: route.target, from: route)
        XCTAssertEqual(requests, 1, "Closing OCR must release and disable its barcode callback")
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let value = await condition(); XCTAssertTrue(value)
    }
}

private actor BarcodeSelectionTestGate {
    private var waiting: [CheckedContinuation<RecognizedBarcodeDocument, Never>] = []
    var count: Int { waiting.count }
    func wait() async -> RecognizedBarcodeDocument { await withCheckedContinuation { waiting.append($0) } }
    func finishFirst(_ document: RecognizedBarcodeDocument) { if !waiting.isEmpty { waiting.removeFirst().resume(returning: document) } }
    func finishAll(_ document: RecognizedBarcodeDocument) { while !waiting.isEmpty { finishFirst(document) } }
}
