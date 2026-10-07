import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class AutomaticPinOCRIntegrationTests: XCTestCase {
    @MainActor private func image() throws -> CGImage { try PinTextSelectionSmokeFixture.visionRaster() }
    @MainActor private func result() -> RecognitionResult {
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        return RecognitionResult(text: document.text, barcodes: [], document: document)
    }
    @MainActor private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !(await condition()), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let ready = await condition(); XCTAssertTrue(ready, file: file, line: line)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    @MainActor private func perform(_ title: String, in menu: NSMenu) throws {
        let item = try XCTUnwrap(menu.items.first { $0.title == title })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    @MainActor func testAutomaticShowKeepsFocusAndBothPasteboardsWithDirectCopyEnabled() async throws {
        _ = NSApplication.shared
        let suite = "PinOCR-AutoFocus-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: TextResultController.directCopyPreferenceKey)
        let source = try image(), expected = result(), gate = AutomaticOCRGate(), scheduler = PinOCRScheduler()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeWithOptions: { _, options in try await gate.wait(options) }, defaults: defaults, ocrScheduler: scheduler)
        let sentinel = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sentinel.isReleasedWhenClosed = false
        let field = NSTextField(string: "keep typing"); sentinel.contentView = field
        sentinel.makeKeyAndOrderFront(nil); sentinel.makeFirstResponder(field)
        let keyWindow = NSApp.keyWindow, responder = sentinel.firstResponder
        let clipboard = NSPasteboard.withUniqueName(); clipboard.setString("private sentinel", forType: .string)
        let generalCount = NSPasteboard.general.changeCount, privateCount = clipboard.changeCount
        defer { pin.close(); sentinel.close(); clipboard.releaseGlobally() }
        pin.applyAutomaticOCR(true); pin.showWindow(nil)
        let pinResponder = pin.window?.firstResponder
        try await waitUntil { await gate.count == 1 }
        await gate.finishFirst(expected)
        try await waitUntil { pin.textSelectionOverlay.document != nil }
        XCTAssertTrue(NSApp.keyWindow === keyWindow); XCTAssertTrue(sentinel.firstResponder === responder)
        XCTAssertTrue(pin.window?.firstResponder === pinResponder)
        XCTAssertNil(pin.recognitionWindow)
        XCTAssertEqual(NSPasteboard.general.changeCount, generalCount)
        XCTAssertEqual(clipboard.changeCount, privateCount)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 1)
    }

    @MainActor func testAutomaticSelectionCopyAllAndResultDialogReuseOneRecognition() async throws {
        _ = NSApplication.shared
        let source = try image(), expected = result(), counter = AutomaticOCRCounter(), scheduler = PinOCRScheduler()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeWithOptions: { _, options in await counter.record(options, result: expected) }, defaults: nil, ocrScheduler: scheduler)
        let clipboard = NSPasteboard.withUniqueName(); defer { pin.close(); clipboard.releaseGlobally() }
        pin.applyAutomaticOCR(true); pin.showWindow(nil)
        try await waitUntil { pin.textSelectionEnabled && !pin.textSelectionIsRecognizing }
        pin.setTextSelectionEnabled(true)
        pin.copyAllRecognizedText(to: clipboard)
        try await waitUntil { clipboard.string(forType: .string) == expected.displayText }
        pin.showRecognizedText(); try await waitUntil { pin.recognitionWindow != nil }
        XCTAssertEqual(pin.recognitionWindow?.resultText, expected.displayText)
        pin.textSelectionOverlay.selectAll(nil)
        XCTAssertEqual(pin.recognitionWindow?.selectedSourceRanges, [NSRange(location: 0, length: expected.text.utf16.count)])
        let count = await counter.count; XCTAssertEqual(count, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 1)
        let menu = try XCTUnwrap(pin.actionMenu?.item(withTitle: "识别")?.submenu)
        let copy = try XCTUnwrap(menu.item(withTitle: "复制全部识别文字"))
        XCTAssertEqual(copy.keyEquivalent, "c"); XCTAssertEqual(copy.keyEquivalentModifierMask, [.command, .shift])
        let selection = try XCTUnwrap(menu.item(withTitle: "选择图片文字"))
        XCTAssertEqual(selection.keyEquivalent, "t"); XCTAssertEqual(selection.keyEquivalentModifierMask, [.command, .shift])
    }

    @MainActor func testEscapeSuppressesAutomaticReentryUntilLaterShowOrExplicitAction() async throws {
        _ = NSApplication.shared
        let source = try image(), expected = result(), scheduler = PinOCRScheduler()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeForSelection: { _ in expected }, defaults: nil, ocrScheduler: scheduler)
        defer { pin.close() }
        pin.applyAutomaticOCR(true); pin.showWindow(nil)
        try await waitUntil { pin.textSelectionEnabled }
        let window = try XCTUnwrap(pin.window)
        pin.textSelectionOverlay.keyDown(with: try PinTextSelectionSmokeFixture.key("", code: 53, flags: [], window: window))
        XCTAssertFalse(pin.textSelectionEnabled); XCTAssertTrue(window.isVisible)
        pin.applyAutomaticOCR(true); pin.showWindow(nil)
        pin.ocrSession.onChange?()
        XCTAssertFalse(pin.textSelectionEnabled, "An already-visible show or observer refresh must respect Escape")
        pin.hideTemporarily(); pin.showWindow(nil)
        try await waitUntil { pin.textSelectionEnabled }
        pin.setTextSelectionEnabled(false); pin.setTextSelectionEnabled(true)
        XCTAssertTrue(pin.textSelectionEnabled)
    }

    @MainActor func testLanguageRerunUsesSessionAndOldPanelSelectionsCannotHighlightDuringRerun() async throws {
        _ = NSApplication.shared
        let source = try image(), expected = result(), gate = AutomaticOCRGate(), scheduler = PinOCRScheduler()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeWithOptions: { _, options in try await gate.wait(options) }, defaults: nil, ocrScheduler: scheduler)
        let clipboard = NSPasteboard.withUniqueName(); defer { pin.close(); clipboard.releaseGlobally() }
        pin.showWindow(nil); pin.setTextSelectionEnabled(true)
        try await waitUntil { await gate.count == 1 }; await gate.finishFirst(expected)
        try await waitUntil { !pin.textSelectionIsRecognizing }
        pin.showRecognizedText(); try await waitUntil { pin.recognitionWindow != nil }
        let panel = try XCTUnwrap(pin.recognitionWindow), document = try XCTUnwrap(expected.document)
        // A copy request must not invalidate the already-open dialog's language provider.
        pin.copyAllRecognizedText(to: clipboard)
        try await waitUntil { clipboard.string(forType: .string) == expected.displayText }
        let picker = try XCTUnwrap(descendants(try XCTUnwrap(panel.window?.contentView)).compactMap { $0 as? NSPopUpButton }.first { $0.toolTip?.contains("语言") == true })
        guard let english = picker.itemArray.first(where: { ($0.representedObject as? String) == "en-US" }) else { throw XCTSkip("English Vision language unavailable") }
        picker.select(english); XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        try await waitUntil { await gate.count == 1 }
        XCTAssertNil(pin.textSelectionOverlay.document)
        panel.onSourceSelection?(document, [NSRange(location: 0, length: 3)])
        XCTAssertNil(pin.textSelectionOverlay.linkedSelectionRanges)
        var rerunResult = expected; rerunResult.omittedBarcodeCount = 1
        await gate.finishFirst(rerunResult)
        try await waitUntil { pin.ocrSession.key.options.language == "en-US" && pin.textSelectionOverlay.document != nil }
        try await waitUntil { panel.resultText == rerunResult.displayText }
        panel.onSourceSelection?(document, [NSRange(location: 0, length: 3)])
        XCTAssertEqual(pin.textSelectionOverlay.linkedSelectionRanges, [NSRange(location: 0, length: 3)])
        let options = await gate.seen; XCTAssertEqual(options.count, 2)
        XCTAssertNil(options[0].language); XCTAssertEqual(options[1].language, "en-US")
        pin.copyAllRecognizedText(to: clipboard)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 2)
    }

    @MainActor func testPixelRevisionClosesLinkedPanelAndRejectsUncooperativeOldOCR() async throws {
        _ = NSApplication.shared
        let source = try image(), expected = result(), gate = AutomaticOCRGate(), scheduler = PinOCRScheduler()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeWithOptions: { _, options in try await gate.wait(options) }, defaults: nil, ocrScheduler: scheduler)
        defer { pin.close() }
        pin.applyAutomaticOCR(true); pin.showWindow(nil)
        try await waitUntil { await gate.count == 1 }
        try pin.applyTransform(.rotateClockwise)
        XCTAssertNil(pin.textSelectionOverlay.document); XCTAssertEqual(pin.ocrSession.key.revision, 1)
        await gate.finishFirst(expected)
        try await waitUntil { await gate.count == 1 }
        XCTAssertNil(pin.textSelectionOverlay.document, "Old source geometry must not appear during the new request")
        await gate.finishFirst(expected); try await waitUntil { pin.textSelectionEnabled }
        pin.showRecognizedText(); try await waitUntil { pin.recognitionWindow != nil }
        let oldPanel = try XCTUnwrap(pin.recognitionWindow)
        try pin.cropImage(to: CGRect(x: 0, y: 0, width: 120, height: 80))
        XCTAssertNil(pin.recognitionWindow); XCTAssertNil(oldPanel.onSourceSelection)
        XCTAssertNil(oldPanel.window?.contentView)
        pin.hideTemporarily()
        await gate.finishAll(expected)
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertNil(pin.textSelectionOverlay.document); XCTAssertNil(pin.ocrSession.cachedResult)
    }

    @MainActor func testHideCancelsPendingCopyWithoutWritingPrivatePasteboard() async throws {
        _ = NSApplication.shared
        let source = try image(), expected = result(), gate = AutomaticOCRGate(), scheduler = PinOCRScheduler()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeWithOptions: { _, options in try await gate.wait(options) }, defaults: nil, ocrScheduler: scheduler)
        let clipboard = NSPasteboard.withUniqueName(); clipboard.setString("keep this", forType: .string)
        let changeCount = clipboard.changeCount
        defer { pin.close(); clipboard.releaseGlobally() }
        pin.showWindow(nil); pin.copyAllRecognizedText(to: clipboard)
        try await waitUntil { await gate.count == 1 }
        pin.hideTemporarily(); await gate.finishAll(expected)
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertEqual(clipboard.changeCount, changeCount); XCTAssertEqual(clipboard.string(forType: .string), "keep this")
        XCTAssertNil(pin.recognitionWindow); XCTAssertNil(pin.ocrSession.cachedResult)
    }

    @MainActor func testRestoreTwentyPinsQueuesWeaklyAndCloseCancelsAllDemand() async throws {
        _ = NSApplication.shared
        let source = try image(), expected = result(), gate = AutomaticOCRGate(), scheduler = PinOCRScheduler()
        var pins: [PinController] = []
        for _ in 0..<20 {
            let pin = PinController(originalImage: source, currentImage: source, isModified: false,
                recognizeWithOptions: { _, options in try await gate.wait(options) }, defaults: nil, ocrScheduler: scheduler)
            pins.append(pin); pin.applyAutomaticOCR(true); pin.showWindow(nil)
        }
        try await waitUntil { await gate.count == 1 }
        XCTAssertEqual(scheduler.resourceSnapshot.activeJobs, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.automaticJobs, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 19)
        XCTAssertEqual(pins.reduce(0) { $0 + $1.ocrSourceReadCount }, 1, "Queued restore work must not read or capture the 19 waiting rasters")
        let probes = pins.map { AutomaticOCRWeakPin($0) }
        pins.forEach { $0.close() }; pins.removeAll()
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 0)
        await gate.finishAll(expected)
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 && probes.allSatisfy { $0.value == nil } }
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.releasedJobs, 1)
    }

    @MainActor func testModalModesAndClickThroughSuspendUntilEligibleAgain() async throws {
        _ = NSApplication.shared
        let source = try image(), expected = result(), scheduler = PinOCRScheduler()
        let pin = PinController(originalImage: source, currentImage: source, isModified: false,
            recognizeForSelection: { _ in expected }, defaults: nil, ocrScheduler: scheduler,
            recognizeCodes: { _ in RecognizedBarcodeDocument(candidates: [], supportedSymbologies: []) })
        defer { pin.close() }
        pin.applyAutomaticOCR(true); pin.showWindow(nil); try await waitUntil { pin.textSelectionEnabled }
        let menu = try XCTUnwrap(pin.actionMenu)
        try perform("裁剪当前图片…", in: menu)
        XCTAssertEqual(pin.ocrSession.state, .suspended); XCTAssertNil(pin.ocrSession.cachedResult)
        try perform("裁剪当前图片…", in: menu); try await waitUntil { pin.textSelectionEnabled }
        pin.showAnnotations(); XCTAssertEqual(pin.ocrSession.state, .suspended)
        XCTAssertNil(pin.ocrSession.cachedResult); pin.annotationEditor?.close()
        try await waitUntil { pin.textSelectionEnabled }
        pin.setBarcodeSelectionEnabled(true); XCTAssertEqual(pin.ocrSession.state, .suspended)
        pin.setBarcodeSelectionEnabled(false); try await waitUntil { pin.textSelectionEnabled }
        var presentation = pin.presentation; presentation.clickThrough = true; pin.applyPresentation(presentation)
        XCTAssertEqual(pin.ocrSession.state, .suspended); XCTAssertNil(pin.ocrSession.cachedResult)
        pin.restore(); try await waitUntil { pin.textSelectionEnabled }
        try perform("当前图像另存为…", in: menu)
        XCTAssertNotNil(pin.imageExportController); XCTAssertEqual(pin.ocrSession.state, .suspended)
        pin.imageExportController?.cancelExport(); try await waitUntil { pin.textSelectionEnabled }
    }

    @MainActor func testWholeCoordinatorLaunchRestoreShowAndRecoveryPreserveOtherWindowFocus() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PinOCR-PassiveRestore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory), expected = result(), counter = AutomaticOCRCounter(), scheduler = PinOCRScheduler()
        let source = try image()
        let first = try store.add(image: source, title: "First", presentation: PinPresentation(frame: PinWindowFrame(x: 60, y: 60, width: 260, height: 100)), revealingGroup: true)
        let second = try store.add(image: source, title: "Second", presentation: PinPresentation(frame: PinWindowFrame(x: 80, y: 80, width: 260, height: 100)), revealingGroup: true)
        let coordinator = PinSessionCoordinator(store: store, desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
            ocrPreferences: PinOCRPreferences(defaults: nil, initialValue: true),
            makeImageController: { original, current, modified in
                PinController(originalImage: original, currentImage: current, isModified: modified,
                    recognizeWithOptions: { _, options in await counter.record(options, result: expected) }, defaults: nil, ocrScheduler: scheduler)
            })
        let other = NSWindow(contentRect: NSRect(x: 400, y: 80, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let field = NSTextField(string: "typing in another window"); other.contentView = field
        other.makeKeyAndOrderFront(nil); other.makeFirstResponder(field)
        let keyWindow = NSApp.keyWindow, responder = other.firstResponder
        let clipboardCount = NSPasteboard.general.changeCount
        defer { try? coordinator.prepareForTermination(); other.close() }
        try coordinator.restoreOnLaunch(enabled: true, isSmoke: false)
        try await waitUntil { coordinator.liveControllers.count == 2 && coordinator.liveControllers.values.allSatisfy { $0.textSelectionEnabled } }
        XCTAssertTrue(NSApp.keyWindow === keyWindow); XCTAssertTrue(other.firstResponder === responder)
        XCTAssertEqual(Set(coordinator.liveControllers.keys), Set([first.id, second.id]))
        XCTAssertTrue(coordinator.liveControllers.values.allSatisfy { $0.recognitionWindow == nil })
        try coordinator.hideCurrentGroup(); try coordinator.showCurrentGroup()
        try await waitUntil { coordinator.liveControllers.values.allSatisfy { $0.textSelectionEnabled } }
        try coordinator.recoverCurrentGroup()
        XCTAssertTrue(NSApp.keyWindow === keyWindow); XCTAssertTrue(other.firstResponder === responder)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 4)
    }

    @MainActor func testDefaultOffNilPreferencesAndSettingsSmokeAreIsolated() throws {
        _ = NSApplication.shared
        let suite = "PinOCR-Preferences-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PinOCRPreferences(defaults: defaults)
        XCTAssertFalse(preferences.automaticallyRecognizeText)
        preferences.select(true); XCTAssertTrue(PinOCRPreferences(defaults: defaults).automaticallyRecognizeText)
        let isolated = PinOCRPreferences(defaults: nil); XCTAssertFalse(isolated.automaticallyRecognizeText)
        isolated.select(true); isolated.reload(); XCTAssertTrue(isolated.automaticallyRecognizeText)
        let smoke = SettingsController(onChange: { XCTFail("Smoke must not apply preferences") }, defaults: defaults, isSmoke: true)
        smoke.selectCategory(.pins); XCTAssertEqual(smoke.automaticPinOCR.state, .off)
        smoke.automaticPinOCR.state = .off
        let save = try XCTUnwrap(descendants(try XCTUnwrap(smoke.window?.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "保存设置" })
        save.performClick(nil)
        XCTAssertTrue(defaults.bool(forKey: PinOCRPreferences.automaticPreferenceKey))
    }

    @MainActor func testSettingsSavePersistsAutomaticChoiceAndInvokesLiveReload() throws {
        _ = NSApplication.shared
        let suite = "PinOCR-SettingsSave-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousAppearance = NSApp.appearance
        defer { defaults.removePersistentDomain(forName: suite); NSApp.appearance = previousAppearance }
        let preferences = PinOCRPreferences(defaults: defaults)
        var changes = 0
        let settings = SettingsController(onChange: { changes += 1; preferences.reload() }, defaults: defaults, isSmoke: false)
        defer { settings.close() }
        settings.selectCategory(.pins); XCTAssertEqual(settings.automaticPinOCR.state, .off)
        settings.automaticPinOCR.state = .on
        let save = try XCTUnwrap(descendants(try XCTUnwrap(settings.window?.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "保存设置" })
        save.performClick(nil)
        XCTAssertEqual(changes, 1); XCTAssertTrue(preferences.automaticallyRecognizeText)
        XCTAssertTrue(defaults.bool(forKey: PinOCRPreferences.automaticPreferenceKey))
    }

    @MainActor func testSavedPreferencePropagatesOnlyToLivePinsAndHiddenGroupsStayUnloaded() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PinOCR-Live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory), preferences = PinOCRPreferences(defaults: nil)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false,
            desktopVisibilityService: PinDesktopVisibilityService(defaults: nil), ocrPreferences: preferences)
        defer { try? coordinator.prepareForTermination() }
        let id = try coordinator.add(image: image()), live = try XCTUnwrap(coordinator.liveControllers[id])
        coordinator.setAutomaticOCR(true); XCTAssertTrue(live.automaticOCREnabled)
        XCTAssertEqual(live.ocrSession.state, .idle, "Unpresented fixtures must not launch automatic OCR")
        try coordinator.hideCurrentGroup(); XCTAssertEqual(coordinator.livePinCount, 0)
        coordinator.setAutomaticOCR(false); coordinator.reloadOCRPreferences(); XCTAssertEqual(coordinator.livePinCount, 0)
        try coordinator.showCurrentGroup(); XCTAssertFalse(try XCTUnwrap(coordinator.liveControllers[id]).automaticOCREnabled)
    }
}

private actor AutomaticOCRCounter {
    private(set) var count = 0
    func record(_ options: RecognitionOptions, result: RecognitionResult) -> RecognitionResult { count += 1; return result }
}
private actor AutomaticOCRGate {
    private var waiting: [CheckedContinuation<RecognitionResult, Error>] = []
    private(set) var seen: [RecognitionOptions] = []
    var count: Int { waiting.count }
    func wait(_ options: RecognitionOptions) async throws -> RecognitionResult {
        seen.append(options)
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func finishFirst(_ result: RecognitionResult) { if !waiting.isEmpty { waiting.removeFirst().resume(returning: result) } }
    func finishAll(_ result: RecognitionResult) { while !waiting.isEmpty { finishFirst(result) } }
}
@MainActor private final class AutomaticOCRWeakPin {
    weak var value: PinController?
    init(_ value: PinController) { self.value = value }
}
