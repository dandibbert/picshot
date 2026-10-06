import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class PinTextSelectionTests: XCTestCase {
    @MainActor func testNativeMouseKeyboardCopyDragPayloadAndCancellationFixture() throws {
        _ = NSApplication.shared
        let checks = try PinTextSelectionSmokeFixture.verifyInteractions()
        XCTAssertEqual(checks["dragCount"] as? Int, 1)
        for key in ["phraseMouseSelection", "copyShortcutExact", "dragWriterExact", "nativeTextTargetRead", "dragCancellation", "unicodeKeyboardBoundaries", "escapeCancellation", "disabledOverlayPassThrough"] {
            XCTAssertEqual(checks[key] as? Bool, true, key)
        }
    }
    @MainActor func testIdlePinIsImageOnlyAndExplicitModeFollowsCurrentImageRect() async throws {
        _ = NSApplication.shared
        let image = try PinTextSelectionSmokeFixture.visionRaster(), document = PinTextSelectionSmokeFixture.deterministicDocument()
        let result = RecognitionResult(text: document.text, barcodes: [], document: document)
        let controller = PinController(originalImage: image, currentImage: image, isModified: false, recognizeForSelection: { _ in result })
        defer { controller.close() }
        XCTAssertFalse(controller.textSelectionEnabled); XCTAssertNil(controller.textSelectionOverlay.superview)
        XCTAssertFalse(descendants(try XCTUnwrap(controller.window?.contentView)).contains { $0 is NSButton })
        let item = try XCTUnwrap(controller.actionMenu?.item(withTitle: "识别")?.submenu?.item(withTitle: "选择图片文字"))
        XCTAssertEqual(item.keyEquivalent, "t"); XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        controller.bringForward(); controller.setTextSelectionEnabled(true)
        try await waitUntil { !controller.textSelectionIsRecognizing }
        XCTAssertEqual(controller.textSelectionOverlay.document, document)
        let window = try XCTUnwrap(controller.window)
        controller.applyPresentation(PinPresentation(frame: PinWindowFrame(x: 40, y: 70, width: 320, height: 200), zoom: 2))
        let scroll = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 55, y: 32)); scroll.reflectScrolledClipView(scroll.contentView)
        let expected = try XCTUnwrap(controller.annotationPresentation?.imageFrame)
        let overlay = controller.textSelectionOverlay
        let actual = window.convertToScreen(overlay.convert(overlay.imageRect, to: nil))
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01); XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01)
        XCTAssertEqual(actual.size.width, expected.size.width, accuracy: 0.01); XCTAssertEqual(actual.size.height, expected.size.height, accuracy: 0.01)
        overlay.keyDown(with: try PinTextSelectionSmokeFixture.key("", code: 53, flags: [], window: window))
        XCTAssertFalse(controller.textSelectionEnabled); XCTAssertNil(overlay.document); XCTAssertNil(overlay.superview)
        XCTAssertTrue(window.isVisible, "Escape exits OCR instead of closing the pin")
    }
    @MainActor func testLateRecognitionCannotReplaceNewModeOrSurviveEditHideAndClose() async throws {
        _ = NSApplication.shared
        let image = try PinTextSelectionSmokeFixture.visionRaster(), document = PinTextSelectionSmokeFixture.deterministicDocument()
        let result = RecognitionResult(text: document.text, barcodes: [], document: document)
        let gate = PinTextTestGate()
        let controller = PinController(originalImage: image, currentImage: image, isModified: false, recognizeForSelection: { _ in await gate.wait() })
        defer { controller.close(); Task { await gate.finishAll(result) } }
        controller.setTextSelectionEnabled(true)
        try await waitUntil { await gate.count == 1 }
        controller.setTextSelectionEnabled(false); controller.setTextSelectionEnabled(true)
        try await waitUntil { await gate.count == 2 }
        await gate.finishFirst(result)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(controller.textSelectionIsRecognizing); XCTAssertNil(controller.textSelectionOverlay.document)
        await gate.finishFirst(result)
        try await waitUntil { !controller.textSelectionIsRecognizing }
        XCTAssertEqual(controller.textSelectionOverlay.document, document)
        try controller.applyTransform(.rotateClockwise)
        XCTAssertFalse(controller.textSelectionEnabled); XCTAssertNil(controller.textSelectionOverlay.document)
        controller.setTextSelectionEnabled(true); try await waitUntil { await gate.count == 1 }
        controller.hideTemporarily(); await gate.finishFirst(result)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(controller.textSelectionEnabled); XCTAssertNil(controller.textSelectionOverlay.document)
        controller.bringForward(); controller.setTextSelectionEnabled(true); try await waitUntil { await gate.count == 1 }
        controller.close(); await gate.finishFirst(result)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(controller.window?.contentView); XCTAssertNil(controller.textSelectionOverlay.document)
        XCTAssertNil(controller.textSelectionOverlay.onExit)
    }
    @MainActor func testCropClickThroughAndSpacePreserveOtherPinBehavior() async throws {
        _ = NSApplication.shared
        let image = try PinTextSelectionSmokeFixture.visionRaster(), document = PinTextSelectionSmokeFixture.deterministicDocument()
        let result = RecognitionResult(text: document.text, barcodes: [], document: document)
        let controller = PinController(originalImage: image, currentImage: image, isModified: false, recognizeForSelection: { _ in result })
        defer { controller.close() }
        controller.bringForward(); controller.setTextSelectionEnabled(true)
        try await waitUntil { !controller.textSelectionIsRecognizing }
        controller.textSelectionOverlay.keyDown(with: try PinTextSelectionSmokeFixture.key(" ", code: 49, flags: [], window: try XCTUnwrap(controller.window)))
        XCTAssertNotNil(controller.annotationEditor); XCTAssertFalse(controller.textSelectionEnabled)
        controller.annotationEditor?.close()
        controller.setTextSelectionEnabled(true); try await waitUntil { !controller.textSelectionIsRecognizing }
        try controller.cropImage(to: CGRect(x: 10, y: 10, width: 200, height: 100))
        XCTAssertFalse(controller.textSelectionEnabled); XCTAssertTrue(controller.image === image)
        XCTAssertEqual(controller.currentImage.width, 200)
        controller.setTextSelectionEnabled(true); try await waitUntil { !controller.textSelectionIsRecognizing }
        var presentation = controller.presentation; presentation.clickThrough = true
        controller.applyPresentation(presentation)
        XCTAssertFalse(controller.textSelectionEnabled); XCTAssertNil(controller.textSelectionOverlay.document)
        controller.setTextSelectionEnabled(true); XCTAssertFalse(controller.textSelectionEnabled)
        controller.restore(); controller.setTextSelectionEnabled(true)
        XCTAssertTrue(controller.textSelectionEnabled)
    }
    @MainActor func testFailedPixelPersistencePreservesCurrentSelection() async throws {
        _ = NSApplication.shared
        let image = try PinTextSelectionSmokeFixture.visionRaster(), document = PinTextSelectionSmokeFixture.deterministicDocument()
        let result = RecognitionResult(text: document.text, barcodes: [], document: document)
        let controller = PinController(originalImage: image, currentImage: image, isModified: false, recognizeForSelection: { _ in result })
        defer { controller.close() }
        controller.setTextSelectionEnabled(true); try await waitUntil { !controller.textSelectionIsRecognizing }
        controller.textSelectionOverlay.selectAll(nil)
        controller.onPixelChange = { _, _ in throw PicShotError.message("Disk full") }
        XCTAssertThrowsError(try controller.applyTransform(.invert))
        XCTAssertTrue(controller.textSelectionEnabled)
        XCTAssertEqual(controller.textSelectionOverlay.document, document)
        XCTAssertEqual(controller.textSelectionOverlay.selectedText, document.text)
        XCTAssertTrue(controller.currentImage === image)
    }
    @MainActor func testGroupSwitchClosesSelectionWithoutRestoringItsMode() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PinTextGroup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory), coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        defer { try? coordinator.prepareForTermination() }
        let id = try coordinator.add(image: PinTextSelectionSmokeFixture.visionRaster()), group = try store.createGroup(name: "Other")
        let old = try XCTUnwrap(coordinator.liveControllers[id])
        old.setTextSelectionEnabled(true)
        try coordinator.switchGroup(id: group.id)
        XCTAssertFalse(old.textSelectionEnabled); XCTAssertNil(old.textSelectionOverlay.document)
        XCTAssertNil(old.window?.contentView)
        try coordinator.switchGroup(id: PinGroup.defaultID)
        let restored = try XCTUnwrap(coordinator.liveControllers[id])
        XCTAssertFalse(restored === old); XCTAssertFalse(restored.textSelectionEnabled)
        XCTAssertNil(restored.textSelectionOverlay.document)
    }
    @MainActor func testClosedPinsReleaseControllerContentAndOverlayRepeatedly() async throws {
        _ = NSApplication.shared
        let image = try PinTextSelectionSmokeFixture.visionRaster(), document = PinTextSelectionSmokeFixture.deterministicDocument()
        let result = RecognitionResult(text: document.text, barcodes: [], document: document)
        for _ in 0..<6 {
            let (probe, overlay) = try await closeProbedController(image: image, result: result)
            try await probe.assertReleased()
            XCTAssertNil(overlay.value)
        }
    }
    @MainActor private func closeProbedController(image: CGImage, result: RecognitionResult) async throws -> (ClosedAuxiliaryWindowProbe, WeakPinTextOverlay) {
        let controller = autoreleasepool {
            let controller = PinController(originalImage: image, currentImage: image, isModified: false, recognizeForSelection: { _ in result })
            controller.setTextSelectionEnabled(true)
            return controller
        }
        try await waitUntil { !controller.textSelectionIsRecognizing }
        return try autoreleasepool {
            let probe = try ClosedAuxiliaryWindowProbe(controller), overlay = WeakPinTextOverlay(controller.textSelectionOverlay)
            controller.close(); probe.assertDetached()
            XCTAssertNil(controller.textSelectionOverlay.document); XCTAssertNil(controller.textSelectionOverlay.superview)
            return (probe, overlay)
        }
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }
}

private actor PinTextTestGate {
    private var waiting: [CheckedContinuation<RecognitionResult, Never>] = []
    var count: Int { waiting.count }
    func wait() async -> RecognitionResult { await withCheckedContinuation { waiting.append($0) } }
    func finishFirst(_ result: RecognitionResult) { if !waiting.isEmpty { waiting.removeFirst().resume(returning: result) } }
    func finishAll(_ result: RecognitionResult) { while !waiting.isEmpty { finishFirst(result) } }
}

@MainActor private final class WeakPinTextOverlay {
    weak var value: PinTextSelectionOverlay?
    init(_ value: PinTextSelectionOverlay) { self.value = value }
}
