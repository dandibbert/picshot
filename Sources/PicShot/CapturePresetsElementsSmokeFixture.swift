import AppKit
import ApplicationServices
import PicShotCore

/// Authored desktop pixels and native AppKit events. No screen capture or OS
/// permission prompt. Real own-app AX is reported separately and may be skipped.
@MainActor enum CapturePresetsElementsSmokeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Capture-Preset-Fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try coordinateImage(width: 1280, height: 800)
        let displayBounds = CGRect(x: -640, y: -180, width: 640, height: 400)
        let frozenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let localHit = CGRect(x: 60.25, y: 60.75, width: 92.5, height: 44.25)
        let localParent = CGRect(x: 40, y: 40, width: 300, height: 220)
        let localChild = CGRect(x: 75, y: 75, width: 45, height: 20)
        let context = CaptureElementContext(displayBounds: displayBounds, windows: [], frozenAt: frozenAt,
            initiallyEnabled: true, provider: FixtureCaptureElements(displayBounds: displayBounds,
                frames: [localHit, localParent, localChild]))
        let geometry = try FrozenCaptureGeometry(pointSize: displayBounds.size, pixelWidth: image.width, pixelHeight: image.height)
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: displayBounds.size), frozenImage: image,
                                       geometry: geometry, elementContext: context)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 120, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "PicShot 元素选择验证 · 合成图像"
        window.contentView = view; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        defer { view.discard(); window.close() }
        var selected: CGRect?, cancelled = false
        view.finished = { result in
            switch result { case .success(let frame): selected = frame; case .failure: cancelled = true }
        }
        let point = CGPoint(x: 90, y: 85)
        view.mouseMoved(with: try mouse(.mouseMoved, point: point, view: view))
        try await waitUntil { view.elementPreviewFrame == localHit }
        let elementButtonLayout = try verifyElementButtonLayout(view)
        try click("capture.elements.parent", in: view)
        guard view.elementPreviewFrame == localParent else { throw failure("Native parent button did not select the parent") }
        view.keyDown(with: try key(125, "\u{F701}", view: view))
        guard view.elementPreviewFrame == localHit else { throw failure("Child key did not restore the hit element") }
        try click("capture.elements.child", in: view)
        guard view.elementPreviewFrame == localChild else { throw failure("Native child button did not select the child") }
        view.keyDown(with: try key(6, "z", view: view, flags: .command))
        guard view.elementPreviewFrame == localHit else { throw failure("Traversal undo did not restore the previous element") }
        try snapshot(window, to: evidenceDirectory.appendingPathComponent("capture-elements-native.png"))
        view.mouseDown(with: try mouse(.leftMouseDown, point: point, view: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: point, view: view))
        guard selected == localHit else { throw failure("Click did not accept the element rectangle") }
        let aligned = try geometry.alignedSelection(localHit)
        let crop = try CapturedImage.frozenPixelRegion(image: image, displayID: 17,
            displayFrame: CGRect(x: -640, y: 180, width: 640, height: 400), pixelFrame: aligned.pixelFrame, capturedAt: frozenAt)
        let checkedPixels = try verifyPixels(crop.image, sourceFrame: aligned.pixelFrame)
        try crop.image.writePNG(to: evidenceDirectory.appendingPathComponent("capture-elements-pixels.png"))
        selected = nil
        // Exercise the real Tab hide route before drawing through the control
        // band. Never bypass hit testing or relax the exact Retina result.
        view.keyDown(with: try key(48, "\t", view: view))
        view.layoutSubtreeIfNeeded()
        guard try find("capture.ratioSurface", in: view, as: NSVisualEffectView.self).isHidden,
              view.hitTest(view.convert(CGPoint(x: 300, y: 120), to: view.superview)) === view else {
            throw failure("Tab did not make the manual fallback target reachable")
        }
        view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: 300, y: 120), view: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 350.5, y: 160.5), view: view))
        guard selected == CGRect(x: 300, y: 120, width: 50.5, height: 40.5) else { throw failure("Manual rectangle fallback did not preserve Retina geometry") }
        view.keyDown(with: try key(48, "\t", view: view))
        view.keyDown(with: try key(53, "\u{1b}", view: view))
        guard cancelled else { throw failure("Escape did not cancel element selection") }
        view.discard(); window.orderOut(nil)

        let store = try CapturePresetStore(directory: directory)
        let display = try CapturePresetDisplay(uuid: UUID(), frame: CGRect(x: -640, y: 180, width: 640, height: 400),
                                              pixelWidth: image.width, pixelHeight: image.height, rotationDegrees: 0)
        let first = try CapturePreset(name: "元素区域", delay: .threeSeconds, display: display,
                                      topLeftFrame: aligned.topLeftFrame, pixelFrame: aligned.pixelFrame)
        let second = try CapturePreset(name: "第二个矩形", delay: .fiveSeconds, display: display,
                                       topLeftFrame: CGRect(x: 260, y: 120, width: 140, height: 100),
                                       pixelFrame: CGRect(x: 520, y: 240, width: 280, height: 200))
        try store.add(first); try store.add(second)
        let reloaded = try CapturePresetStore(directory: directory)
        guard reloaded.presets == [first, second] else { throw failure("Two named rectangles/delays did not survive store recreation") }
        let controller = CapturePresetController(store: reloaded)
        defer { controller.close() }
        var invoked: UUID?, createName: String?, createDelay: ScreenshotDelay?, cancelCount = 0
        controller.onInvoke = { invoked = $0.id }
        controller.onCreate = { createName = $0; createDelay = $1 }
        controller.onCancel = { cancelCount += 1 }
        controller.showWindow(nil)
        guard let root = controller.window?.contentView else { throw failure("Preset manager has no native content") }
        let table = try find("capture-preset-list", in: root, as: NSTableView.self)
        let field = try find("capture-preset-name", in: root, as: NSTextField.self)
        let delay = try find("capture-preset-delay", in: root, as: NSPopUpButton.self)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        field.stringValue = "改名后的元素区域"; delay.selectItem(withTag: 10)
        try click("capture-preset-update", in: root)
        guard reloaded.presets[0].name == "改名后的元素区域", reloaded.presets[0].delay == .tenSeconds else { throw failure("Native preset rename/delay route failed") }
        try snapshot(try unwrap(controller.window, "Preset manager window disappeared"), to: evidenceDirectory.appendingPathComponent("capture-presets-native.png"))
        try click("capture-preset-invoke", in: root)
        guard invoked == first.id, controller.window?.isVisible == false else { throw failure("Preset invocation did not hide manager and call selected preset") }
        controller.showWindow(nil)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try click("capture-preset-delete", in: root)
        guard reloaded.presets.count == 1, reloaded.presets[0].id == first.id else { throw failure("Native preset delete route failed") }
        field.stringValue = "第三个矩形"; delay.selectItem(withTag: 5)
        try click("capture-preset-create", in: root)
        guard createName == "第三个矩形", createDelay == .fiveSeconds, controller.window?.isVisible == false else { throw failure("Preset create callback did not preserve its per-call options") }
        controller.showWindow(nil); try click("capture-preset-cancel", in: root)
        guard cancelCount == 1 else { throw failure("Preset cancel route did not cancel its owner") }
        controller.close()

        let realAX = try await ownApplicationAXCheck()
        let report: [String: Any] = [
            "status": "passed", "screenCaptureStarted": false, "permissionRequested": false,
            "inputEventsPosted": false, "syntheticNativeEvents": true,
            "fakeProvider": ["parentChild": true, "traversalUndo": true, "clickAccept": true,
                             "manualFallback": true, "escape": true, "frozenPixelsChecked": checkedPixels,
                             "elementButtonLayout": elementButtonLayout,
                             "screenshotFrozenAt": frozenAt.timeIntervalSince1970],
            "presets": ["persistedRectangles": 2, "recreatedStore": true, "nativeRenameDelay": true,
                        "nativeDelete": true, "nativeCreateInvokeCancelCallbacks": true],
            "realOwnApplicationAX": realAX,
            "externalAcceptance": "Foreign applications, TCC setup, physical Retina/multi-display changes and real delayed screen acquisition remain separate acceptance",
            "files": ["capture-elements-native.png", "capture-elements-pixels.png", "capture-presets-native.png"]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("capture-presets-elements.json"), options: .atomic)
        return report
    }

    /// Tests the official AX hit-test on a genuine own-process NSButton only if
    /// the current app already has permission. No prompt or settings mutation.
    private static func ownApplicationAXCheck() async throws -> [String: Any] {
        guard let screen = NSScreen.main, let displayID = screen.displayID,
              let primary = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) else {
            return ["status": "skipped-no-native-display", "permissionRequested": false]
        }
        let frame = CGRect(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.midY - 90, width: 360, height: 180)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "PicShot 自身辅助功能验证"; window.isReleasedWhenClosed = false
        let button = NSButton(title: "原生元素验证", target: nil, action: nil)
        button.frame = CGRect(x: 80, y: 60, width: 200, height: 40)
        button.setAccessibilityIdentifier("picshot.capture.own-ax-fixture")
        window.contentView?.addSubview(button); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let appPoint = window.convertPoint(toScreen: button.convert(CGPoint(x: 100, y: 20), to: nil))
        let quartz = CGPoint(x: appPoint.x, y: primary.frame.maxY - appPoint.y)
        var request = CaptureElementRequest(point: quartz, displayBounds: CGDisplayBounds(displayID),
                                             windows: CaptureElementWindow.visible(), frozenAt: Date())
        request.permitsOwnProcessForFixture = true
        let result = await AXCaptureElementProvider().snapshot(request, cancellation: CaptureElementCancellation())
        switch result {
        case .snapshot(let snapshot):
            guard snapshot.nodes.contains(where: { $0.role == (kAXButtonRole as String) && $0.frame.contains(quartz) }) else {
                throw failure("Genuine own-app AX hit-test did not include the native button")
            }
            return ["status": "passed", "provider": "official-AXUIElementCopyElementAtPosition", "nodes": snapshot.nodes.count,
                    "permissionRequested": false, "foreignApplicationsTested": false]
        case .unavailable(let reason):
            return ["status": reason == .permission ? "skipped-no-existing-accessibility-permission" : "unavailable-own-app-ax",
                    "reason": reason.rawValue, "permissionRequested": false, "foreignApplicationsTested": false]
        }
    }

    static func coordinateImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8(x % 251); bytes[offset + 1] = UInt8(y % 251)
            bytes[offset + 2] = UInt8((x + y) % 251); bytes[offset + 3] = 255
        } }
        let provider = try unwrap(CGDataProvider(data: Data(bytes) as CFData), "No authored pixel provider")
        return try unwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent), "No authored image")
    }
    private static func verifyPixels(_ image: CGImage, sourceFrame: CGRect) throws -> Int {
        guard image.width == Int(sourceFrame.width), image.height == Int(sourceFrame.height),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw failure("Preset crop dimensions differ from integral pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try unwrap(context.data, "No crop bytes").assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height { for x in 0..<image.width {
            let offset = (y * image.width + x) * 4, sx = x + Int(sourceFrame.minX), sy = y + Int(sourceFrame.minY)
            guard bytes[offset] == UInt8(sx % 251), bytes[offset + 1] == UInt8(sy % 251),
                  bytes[offset + 2] == UInt8((sx + sy) % 251), bytes[offset + 3] == 255 else { throw failure("Frozen selected pixel mismatch") }
        } }
        return image.width * image.height
    }
    private static func mouse(_ type: NSEvent.EventType, point: CGPoint, view: NSView) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "No native mouse event")
    }
    private static func key(_ code: UInt16, _ value: String, view: NSView, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: value, charactersIgnoringModifiers: value,
            isARepeat: false, keyCode: code), "No native key event")
    }
    private static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { descendants($0) } }
    private static func verifyElementButtonLayout(_ view: RegionSelectionView) throws -> [[String: Any]] {
        view.layoutSubtreeIfNeeded()
        var frames: [CGRect] = [], result: [[String: Any]] = []
        for id in ["capture.elements.toggle", "capture.elements.parent", "capture.elements.child"] {
            let button = try find(id, in: view, as: NSButton.self)
            let frame = view.convert(button.bounds, from: button)
            guard button.window === view.window, !button.isHiddenOrHasHiddenAncestor,
                  frame.width >= 50, frame.height >= 20, view.bounds.contains(frame),
                  !frames.contains(where: { $0.intersects(frame) }) else {
                throw failure("Element controls overlap, clip or have no reachable frame: " + id)
            }
            let point = view.convert(CGPoint(x: frame.midX, y: frame.midY), to: view.superview)
            let hit = view.hitTest(point)
            guard hit === button || hit?.isDescendant(of: button) == true else {
                throw failure("Native hit testing cannot reach element control: " + id)
            }
            frames.append(frame)
            result.append(["identifier": id, "frame": NSStringFromRect(frame), "hitTargetVerified": true])
        }
        return result
    }
    private static func find<T: NSView>(_ id: String, in view: NSView, as type: T.Type) throws -> T {
        try unwrap(descendants(view).first(where: { $0.identifier?.rawValue == id }) as? T, "Missing native control \(id)")
    }
    private static func click(_ id: String, in view: NSView) throws {
        let button = try find(id, in: view, as: NSButton.self)
        guard button.isEnabled, button.action != nil, button.target != nil else { throw failure("Disabled/unconnected native button \(id)") }
        button.performClick(nil)
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw failure("Element query did not update the native preview")
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else { throw failure("No snapshot view") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "No native bitmap")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try unwrap(bitmap.cgImage, "Empty native bitmap")
        try evidenceImage(image, for: window).writePNG(to: url)
    }

    /// cacheDisplay can leave AppKit's titled-window background transparent.
    /// Composite that system surface for the preset manager, but preserve genuine
    /// alpha from borderless capture overlays and other intentionally clear windows.
    static func evidenceImage(_ image: CGImage, for window: NSWindow) throws -> CGImage {
        guard window.isOpaque || window.styleMask.contains(.titled) else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("No evidence compositor") }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { context.setFillColor(window.backgroundColor.cgColor) }
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try unwrap(context.makeImage(), "No evidence image")
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Capture presets/elements fixture: \(message)") }
}

private struct FixtureCaptureElements: CaptureElementProviding {
    let displayBounds: CGRect
    let frames: [CGRect]
    func snapshot(_ request: CaptureElementRequest, cancellation: CaptureElementCancellation) async -> CaptureElementResult {
        guard !cancellation.isCancelled else { return .unavailable(.cancelled) }
        let global = frames.map { $0.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY) }
        return .snapshot(CaptureElementSnapshot(nodes: [
            CaptureElementNode(frame: global[0], role: "AXButton", parent: 1, children: [2]),
            CaptureElementNode(frame: global[1], role: "AXGroup", parent: nil, children: [0]),
            CaptureElementNode(frame: global[2], role: "AXStaticText", parent: 0, children: [])
        ], hit: 0, sampledAt: request.frozenAt.addingTimeInterval(0.2), frozenAt: request.frozenAt, point: request.point))
    }
}
