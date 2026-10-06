import AppKit
import CoreText
import PicShotCore

/// Local synthetic evidence only: real Apple Vision on rendered fixtures, native view events,
/// and isolated-pasteboard drag payload consumption. This never captures screens or posts global input.
@MainActor enum PinTextSelectionSmokeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        guard evidenceDirectory.isFileURL else { throw failure("Evidence directory must be local") }
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-PinText-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        var stages: [String] = []
        let baseline = await RecognitionService.resourceSnapshot()
        let raster = try visionRaster()
        try raster.writePNG(to: evidenceDirectory.appendingPathComponent("pin-text-vision-input.png"))
        let recognized = try await RecognitionService.recognize(raster)
        guard let document = recognized.document, document.units.count >= 3,
              recognized.text.lowercased().contains("capture") else { throw failure("Apple Vision did not read the Latin fixture: " + recognized.text) }
        try require(document.units.allSatisfy { !$0.quad.bounds.isEmpty && !$0.range.isEmptyRange }, "Vision geometry was empty")
        stages.append("real-apple-vision-rendered-latin-fixture")
        guard let rotated = PinImageRenderer.render(image: raster, transform: .rotateCounterclockwise) else { throw failure("Orientation fixture failed") }
        let oriented = try await RecognitionService.recognize(rotated, options: RecognitionOptions(orientation: .right))
        try require(oriented.text.lowercased().contains("capture"), "Oriented raster did not recognize its text")
        stages.append("real-vision-explicit-image-orientation")

        var mixedText = "", mixedRan = false
        if (try? RecognitionService.supportedLanguages().contains("zh-Hans")) == true {
            let mixed = try visionRaster(lines: ["本地文字识别", "Café 中文 👩🏽‍💻"], fontName: "PingFangSC-Regular")
            try mixed.writePNG(to: evidenceDirectory.appendingPathComponent("pin-text-mixed-input.png"))
            mixedText = try await RecognitionService.recognize(mixed, options: RecognitionOptions(language: "zh-Hans")).text
            mixedRan = true
            stages.append("real-vision-mixed-rendered-fixture-observational")
        }

        let pin = PinController(originalImage: raster, currentImage: raster, isModified: false, recognizeForSelection: { _ in recognized })
        defer { pin.close() }
        pin.bringForward(); pin.setTextSelectionEnabled(true)
        try await waitForSelection(pin)
        let overlay = pin.textSelectionOverlay
        try require(overlay.document == document, "Pin did not install the current recognition geometry")
        overlay.select(document.selection(from: 0, through: min(2, document.units.count - 1))!)
        try snapshot(try required(pin.window, "Pin window missing"), to: evidenceDirectory.appendingPathComponent("pin-text-selection.png"))
        stages.append("shown-pin-overlay-and-exact-phrase-highlight")
        let content = try required(pin.window?.contentView, "Pin content missing")
        let scroll = try required(descendants(content).compactMap { $0 as? NSScrollView }.first, "Pin scroll missing")
        let frame = pin.window?.frame ?? .zero
        pin.applyPresentation(PinPresentation(frame: PinWindowFrame(frame), zoom: 2))
        scroll.contentView.scroll(to: CGPoint(x: 42, y: 24)); scroll.reflectScrolledClipView(scroll.contentView)
        let imageFrame = try required(pin.annotationPresentation?.imageFrame, "Image frame missing")
        let overlayFrame = try required(pin.window, "Pin missing").convertToScreen(overlay.convert(overlay.imageRect, to: nil))
        try require(abs(imageFrame.minX - overlayFrame.minX) < 0.01 && abs(imageFrame.minY - overlayFrame.minY) < 0.01 &&
                    abs(imageFrame.width - overlayFrame.width) < 0.01 && abs(imageFrame.height - overlayFrame.height) < 0.01,
                    "Zoomed/scrolled overlay no longer matched the image")
        try pin.applyTransform(.flipHorizontal)
        try require(!pin.textSelectionEnabled && overlay.document == nil && overlay.superview == nil, "Pixel edit left stale text")
        pin.close()
        stages.append("zoom-scroll-coordinate-match-and-edit-invalidation")

        let interactions = try verifyInteractions()
        stages.append("native-mouse-keyboard-isolated-copy-and-drag-payload")
        stages.append("native-text-view-consumes-exact-payload-and-cancel-clears-drag-state")

        var probes: [PinTextReleaseProbe] = []
        for _ in 0..<12 {
            let probe = try await releaseCycle(raster: raster, recognized: recognized)
            probes.append(probe)
        }
        try await requireReleased(probes)
        stages.append("twelve-mode-hide-close-and-release-cycles")
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var settled = await RecognitionService.resourceSnapshot()
        while (settled.activeJobs > baseline.activeJobs || settled.waitingJobs > baseline.waitingJobs), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000); settled = await RecognitionService.resourceSnapshot()
        }
        try require(settled.activeJobs <= baseline.activeJobs && settled.waitingJobs <= baseline.waitingJobs, "Recognition jobs did not settle")
        try FileManager.default.removeItem(at: temporary)
        let cleaned = !FileManager.default.fileExists(atPath: temporary.path)
        try require(cleaned, "Temporary OCR fixture directory remains")
        return [
            "status": "passed", "stages": stages,
            "captureStarted": false, "screenshotUploaded": false, "userDefaultsChanged": false,
            "generalPasteboardChanged": false, "globalInputPosted": false,
            "realAppleVisionRan": true, "visionSource": "locally rendered synthetic CoreText image",
            "visionRecognizedText": recognized.text, "visionLineCount": document.lines.count, "visionUnitCount": document.units.count,
            "mixedFixtureRan": mixedRan, "mixedRecognizedTextObservational": mixedText,
            "multilingualAccuracyProven": false, "physicalDeviceCaptureVerified": false,
            "actualExternalApplicationDropVerified": false,
            "dragTransport": "native NSEvent handlers and NSDraggingItem writer; isolated pasteboard read by NSTextView; no physical drag session",
            "interactionChecks": interactions, "releaseCycleCount": probes.count,
            "retainedControllersOrOverlays": probes.filter { !$0.isReleased }.count,
            "recognitionJobsSettled": true, "activeJobsAfter": settled.activeJobs, "waitingJobsAfter": settled.waitingJobs,
            "maximumActiveRecognitionJobs": 2, "maximumWaitingRecognitionJobs": 4,
            "maximumDocumentUTF16": RecognizedTextDocument.maximumUTF16Count,
            "maximumGeometryUnits": RecognizedTextDocument.maximumUnits,
            "temporaryDirectoryRemoved": cleaned,
            "evidenceFiles": ["pin-text-vision-input.png", "pin-text-selection.png"] + (mixedRan ? ["pin-text-mixed-input.png"] : []),
            "scope": "Synthetic native fixture evidence, not real-device OCR accuracy, arbitrary layout fidelity, physical external-app drag, or a zero-leak claim"
        ]
    }

    static func deterministicDocument() -> RecognizedTextDocument {
        let text = "Select exact text\n中文连续词句 é 👩🏽‍💻"
        let source = text as NSString
        let first = source.range(of: "Select exact text"), second = source.range(of: "中文连续词句 é 👩🏽‍💻")
        let lines = [RecognizedTextLine(range: first, quad: RecognizedTextQuad(rect: CGRect(x: 0.08, y: 0.60, width: 0.82, height: 0.16))!),
                     RecognizedTextLine(range: second, quad: RecognizedTextQuad(rect: CGRect(x: 0.08, y: 0.20, width: 0.82, height: 0.16))!)]
        let tokens: [(String, CGFloat, CGFloat, Int)] = [("Select", 0.08, 0.22, 0), ("exact", 0.35, 0.20, 0), ("text", 0.60, 0.18, 0),
            ("中文", 0.08, 0.17, 1), ("连续", 0.26, 0.17, 1), ("词句", 0.44, 0.17, 1), ("é", 0.67, 0.08, 1), ("👩🏽‍💻", 0.80, 0.10, 1)]
        return RecognizedTextDocument(text: text, lines: lines, units: tokens.map { token in
            RecognizedTextUnit(range: source.range(of: token.0), quad: RecognizedTextQuad(rect: CGRect(x: token.1, y: token.3 == 0 ? 0.60 : 0.20, width: token.2, height: 0.16))!, lineIndex: token.3)
        })
    }

    static func visionRaster(lines: [String] = ["PicShot Local Capture", "Select exact text"], fontName: String = "Helvetica-Bold") throws -> CGImage {
        guard let context = CGContext(data: nil, width: 1000, height: 320, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Raster allocation failed") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 320))
        let font = CTFontCreateWithName(fontName as CFString, 58, nil)
        for (index, line) in lines.prefix(2).enumerated() {
            let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 36, y: 215 - index * 120)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        return try required(context.makeImage(), "Raster construction failed")
    }

    /// Uses actual AppKit mouse/key event values and production handlers. The sole seam prevents
    /// a system-wide drag/clipboard mutation inside unattended CI and exposes the exact writer.
    static func verifyInteractions() throws -> [String: Any] {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 600, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PinTextFixtureOverlay(frame: CGRect(x: 0, y: 0, width: 600, height: 300), pasteboard: pasteboard)
        window.contentView = view; view.imageRect = view.bounds; view.document = deterministicDocument()
        defer { view.releaseResources(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        let document = deterministicDocument()
        let start = CGPoint(x: 110, y: 204), end = CGPoint(x: 280, y: 204)
        view.mouseDown(with: try mouse(.leftMouseDown, point: start, view: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: end, view: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: end, view: view))
        try require(view.selectedText == "Select exact", "Phrase mouse selection changed exact text")
        _ = view.handleKeyDown(try key("c", code: 8, flags: [.command], window: window))
        try require(pasteboard.string(forType: .string) == "Select exact", "Copy shortcut changed exact text")
        view.mouseDown(with: try mouse(.leftMouseDown, point: start, view: view))
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: CGPoint(x: 125, y: 200), view: view))
        try require(view.isDraggingText && view.dragCount == 1, "Native drag threshold failed")
        try require(pasteboard.string(forType: .string) == "Select exact", "Drag writer changed exact text")
        let target = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 80))
        target.isRichText = false; target.isEditable = true
        try require(target.readSelection(from: pasteboard, type: .string) && target.string == "Select exact", "Native text target did not consume exact drag payload")
        view.finishDragging()
        try require(!view.isDraggingText && view.selectedText == "Select exact", "Cancelled drag lost text or retained drag state")
        view.select(document.units[7].range)
        _ = view.handleKeyDown(try key("", code: 123, flags: [.shift], window: window))
        try require(view.selectedRange?.length == 0, "Shift-left split an emoji composed sequence")
        _ = view.handleKeyDown(try key("", code: 124, flags: [.shift], window: window))
        try require(view.selectedText == "👩🏽‍💻", "Shift-right did not restore exact emoji")
        view.select(document.selection(from: 3, through: 7)!)
        _ = view.handleKeyDown(try key("c", code: 8, flags: [.command], window: window))
        try require(pasteboard.string(forType: .string) == "中文连续词句 é 👩🏽‍💻", "Mixed Unicode copy was not exact")
        var exited = false; view.onExit = { exited = true; view.clearSelection() }
        _ = view.handleKeyDown(try key("", code: 53, flags: [], window: window))
        try require(exited && view.selectedRange == nil, "Escape did not cancel selection")
        view.isHidden = true
        try require(view.hitTest(start) == nil, "Disabled overlay intercepted pin movement")
        return ["phraseMouseSelection": true, "copyShortcutExact": true, "dragWriterExact": true,
                "nativeTextTargetRead": true, "dragCancellation": true, "unicodeKeyboardBoundaries": true,
                "escapeCancellation": true, "disabledOverlayPassThrough": true, "dragCount": view.dragCount]
    }

    private static func releaseCycle(raster: CGImage, recognized: RecognitionResult) async throws -> PinTextReleaseProbe {
        let controller = autoreleasepool {
            let controller = PinController(originalImage: raster, currentImage: raster, isModified: false, recognizeForSelection: { _ in recognized })
            controller.bringForward(); controller.setTextSelectionEnabled(true)
            return controller
        }
        try await waitForSelection(controller)
        return try autoreleasepool {
            let probe = PinTextReleaseProbe(controller)
            controller.textSelectionOverlay.selectAll(nil)
            controller.setTextSelectionEnabled(false)
            try require(controller.textSelectionOverlay.document == nil && controller.textSelectionOverlay.superview == nil, "Disabling retained geometry")
            controller.setTextSelectionEnabled(true); controller.hideTemporarily()
            try require(!controller.textSelectionEnabled && !controller.textSelectionIsRecognizing, "Hiding left a job attached")
            controller.close()
            return probe
        }
    }
    private static func waitForSelection(_ controller: PinController) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while controller.textSelectionIsRecognizing, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!controller.textSelectionIsRecognizing && controller.textSelectionOverlay.document != nil, "Pin recognition did not finish")
    }
    private static func requireReleased(_ probes: [PinTextReleaseProbe]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !probes.allSatisfy(\.isReleased), ProcessInfo.processInfo.systemUptime < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { continuation.resume() } }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(probes.allSatisfy(\.isReleased), "Closed OCR pin controller or overlay retained")
    }
    static func mouse(_ type: NSEvent.EventType, point: CGPoint, view: NSView, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try required(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1), "Mouse event construction failed")
    }
    static func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try required(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code), "Key event construction failed")
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        window.displayIfNeeded()
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Snapshot allocation failed") }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage, let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Snapshot PNG allocation failed") }
        // cacheDisplay omits the window background. Resolve it in the window appearance;
        // borderless pin transparency remains intentional, while ordinary panels stay legible.
        window.effectiveAppearance.performAsCurrentDrawingAppearance { context.setFillColor(window.backgroundColor.cgColor) }
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try required(context.makeImage(), "Snapshot PNG encoding failed").writePNG(to: url)
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func required<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Pin text selection fixture: " + message) }
}

@MainActor private final class PinTextFixtureOverlay: PinTextSelectionOverlay {
    let pasteboard: NSPasteboard
    private(set) var dragCount = 0
    init(frame: CGRect, pasteboard: NSPasteboard) { self.pasteboard = pasteboard; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func copy(_ sender: Any?) { copySelection(to: pasteboard) }
    override func startTextDrag(_ item: NSDraggingItem, event: NSEvent) {
        guard let writer = item.item as? NSPasteboardWriting else { return }
        pasteboard.clearContents(); pasteboard.writeObjects([writer]); dragCount += 1
    }
}

@MainActor private final class PinTextReleaseProbe {
    weak var controller: PinController?
    weak var overlay: PinTextSelectionOverlay?
    weak var content: NSView?
    init(_ controller: PinController) { self.controller = controller; overlay = controller.textSelectionOverlay; content = controller.window?.contentView }
    var isReleased: Bool { autoreleasepool { controller == nil && overlay == nil && content == nil } }
}

private extension NSRange { var isEmptyRange: Bool { length == 0 } }
