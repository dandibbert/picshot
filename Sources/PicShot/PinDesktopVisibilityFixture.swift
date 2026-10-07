import AppKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// Real AppKit controls and collection behaviors with synthetic content. This is
/// deliberately NOT a Mission Control test: it never creates/switches a Space.
@MainActor enum PinDesktopVisibilityFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let directory = files.temporaryDirectory.appendingPathComponent("PicShot-DesktopVisibility-" + UUID().uuidString)
        let suite = "PicShot-DesktopVisibility-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw failure("Isolated defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite); try? files.removeItem(at: directory) }
        let service = PinDesktopVisibilityService(defaults: defaults)
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, desktopVisibilityService: service)
        defer { try? coordinator.prepareForTermination() }
        var errors: [String] = []
        coordinator.onError = { errors.append($0.localizedDescription) }
        let rasterRelease = DesktopRasterReleaseProbe()
        let imageID = try autoreleasepool { try coordinator.add(image: trackedRaster(release: rasterRelease), title: "桌面范围 · 图片") }
        let richIDs = try autoreleasepool { () throws -> [UUID] in
            let documents = [PinRichDocument(text: PinTextContent(runs: [PinTextRun(text: "所有贴图 · 同一桌面范围", bold: true)])),
                PinRichDocument(files: [PinFileReference(path: directory.appendingPathComponent("fixture-reference.txt").path, name: "fixture-reference.txt", isDirectory: false)]),
                PinRichDocument(color: PinRGBColor(red: 30, green: 150, blue: 220))]
            var ids = try documents.enumerated().map { try coordinator.add(rich: PreparedRichPin(document: $0.element, title: "桌面范围 · \($0.offset)")) }
            ids.append(try coordinator.add(rich: PreparedRichPin(animation: gif(), title: "桌面范围 · 动画")))
            return ids
        }
        try require(coordinator.livePinCount == 5 && service.mode == .allDesktops, "Legacy default changed")
        // Stop animation for deterministic identity/layout checks. Scope changes must
        // not create another decoder, restart playback or replace its controller.
        coordinator.richControllers.values.forEach { $0.pausePlayback() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(coordinator.liveControllers[imageID]?.window?.isVisible == true, "Image pin not shown")
        let expected = try autoreleasepool { () throws -> [UUID: PinPresentation] in
            var presentations: [UUID: PinPresentation] = [:]
            for (offset, id) in ([imageID] + richIDs).enumerated() {
                let frame = PinWindowFrame(x: 60 + Double(offset * 20), y: 90 + Double(offset * 20), width: 380, height: 190)
                let value = PinPresentation(frame: frame, opacity: 0.65, zoom: nil, clickThrough: true, locked: true)
                if let controller = coordinator.liveControllers[id] {
                    controller.applyPresentation(value); controller.onPresentationChange?(controller.presentation)
                    presentations[id] = controller.presentation
                }
                if let controller = coordinator.richControllers[id] {
                    controller.applyPresentation(value); controller.onPresentationChange?(controller.presentation)
                    presentations[id] = controller.presentation
                }
            }
            try coordinator.flushPresentationChanges()
            return presentations
        }
        let before = try diskContents(directory)
        try autoreleasepool {
            let pin = try required(coordinator.liveControllers[imageID], "Image missing")
            let original = pin.image, current = pin.currentImage
            let imageIdentity = ObjectIdentifier(pin)
            let richIdentity = coordinator.richControllers.mapValues(ObjectIdentifier.init)
            for _ in 0..<12 {
                // Exercise actual NSMenuItem target/action routes, from both kinds.
                try select(.currentDesktop, control: pin.desktopVisibilityMenu)
                try verifyFlags(coordinator, mode: .currentDesktop)
                let rich = try required(coordinator.richControllers[richIDs[0]], "Text missing")
                try select(.allDesktops, control: rich.desktopVisibilityMenu)
                try verifyFlags(coordinator, mode: .allDesktops)
                try require(ObjectIdentifier(pin) == imageIdentity && pin.image === original && pin.currentImage === current, "Mode switch replaced image/controller")
                try require(coordinator.richControllers.mapValues(ObjectIdentifier.init) == richIdentity, "Mode switch recreated rich controllers")
            }
            try select(.currentDesktop, control: pin.desktopVisibilityMenu)
            try require(pin.presentation == expected[imageID], "Mode changed image presentation")
            for (id, controller) in coordinator.richControllers { try require(controller.presentation == expected[id], "Mode changed rich presentation") }
        }
        try coordinator.flushPresentationChanges()
        try require(try diskContents(directory) == before, "Mode changed session bytes/assets")
        try require(PinDesktopVisibilityService(defaults: defaults).mode == .currentDesktop, "Preference did not persist")

        // Render real settings and content views, no screen capture or menu simulation.
        let settings = SettingsController(onChange: {}, defaults: defaults, isSmoke: true)
        settings.selectCategory(.pins)
        settings.pinDesktopVisibility.selectItem(at: PinDesktopVisibility.allCases.firstIndex(of: .currentDesktop)!)
        settings.showWindow(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        try snapshot(try required(settings.window, "Settings missing"), to: evidenceDirectory.appendingPathComponent("pin-desktop-settings.png"))
        try require(settings.pinDesktopVisibility.window != nil && settings.pinDesktopVisibility.visibleRect.height > 0, "Settings control not visible")
        settings.close()
        try snapshot(try required(coordinator.richControllers[richIDs[0]]?.window, "Text missing"), to: evidenceDirectory.appendingPathComponent("pin-desktop-current-text.png"))

        // Annotation uses a replacement panel, configured before it appears; changing
        // scope while editing must not reopen the image behind the editor or lose work.
        try autoreleasepool {
            let pin = try required(coordinator.liveControllers[imageID], "Image missing")
            var normal = pin.presentation; normal.clickThrough = false; normal.locked = false
            pin.applyPresentation(normal); pin.showAnnotations()
            let editor = try required(pin.annotationEditor, "Annotation editor missing")
            try require(editor.window?.collectionBehavior.contains(.canJoinAllSpaces) == false, "Annotation did not inherit current mode")
            coordinator.setDesktopVisibility(.allDesktops)
            try require(pin.annotationEditor === editor && editor.window?.collectionBehavior.contains(.canJoinAllSpaces) == true, "Mode replaced or missed editor")
            try require(pin.window?.isVisible == false, "Mode revealed duplicate image behind editor")
            coordinator.setDesktopVisibility(.currentDesktop)
            try require(editor.window?.collectionBehavior.contains(.canJoinAllSpaces) == false, "Editor scope did not return to current")
        }
        var probes = try autoreleasepool { try ownedProbes(coordinator) }
        try coordinator.hideCurrentGroup()
        try await requireReleased(probes)
        let rasterDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !rasterRelease.released, ProcessInfo.processInfo.systemUptime < rasterDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try require(rasterRelease.released, "Closed image/annotation retained original provider pixels")
        try require(coordinator.livePinCount == 0, "Hidden group retained controllers")
        coordinator.setDesktopVisibility(.allDesktops)
        try require(coordinator.livePinCount == 0, "Mode change reopened hidden pins")
        try coordinator.showCurrentGroup(); try verifyFlags(coordinator, mode: .allDesktops)
        let other = try store.createGroup(name: "范围切换测试")
        probes += try autoreleasepool { try ownedProbes(coordinator) }
        try coordinator.switchGroup(id: other.id); try await requireReleased(probes)
        coordinator.setDesktopVisibility(.currentDesktop)
        try require(coordinator.livePinCount == 0, "Mode change opened inactive group")
        try coordinator.switchGroup(id: PinGroup.defaultID); try verifyFlags(coordinator, mode: .currentDesktop)
        let closedProbe = try autoreleasepool { () throws -> DesktopWindowProbe in
            let pin = try required(coordinator.liveControllers[imageID], "Image missing")
            let probe = try DesktopWindowProbe(pin); pin.close(); return probe
        }
        probes.append(closedProbe); try await requireReleased(probes)
        try require(try coordinator.restoreLastClosedPin() == imageID, "Restore-last-close failed")
        try verifyFlags(coordinator, mode: .currentDesktop)
        try coordinator.recoverCurrentGroup(); try verifyFlags(coordinator, mode: .currentDesktop)
        for controller in coordinator.liveControllers.values { try require(controller.presentation.opacity == 1 && !controller.presentation.clickThrough, "Recovery not usable") }
        for controller in coordinator.richControllers.values { try require(controller.presentation.opacity == 1 && !controller.presentation.clickThrough, "Rich recovery not usable") }
        probes += try autoreleasepool { try ownedProbes(coordinator) }
        try coordinator.prepareForTermination(); try await requireReleased(probes)
        let restored = PinSessionCoordinator(store: try PinSessionStore(directory: directory), desktopVisibilityService: PinDesktopVisibilityService(defaults: defaults))
        defer { try? restored.prepareForTermination() }
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        try require(restored.livePinCount == 5, "Launch restoration lost pins")
        try verifyFlags(restored, mode: .currentDesktop)
        probes += try autoreleasepool { try ownedProbes(restored) }
        try restored.prepareForTermination(); try await requireReleased(probes)
        try require(errors.isEmpty, "Controller callback errors: \(errors)")
        return ["status": "passed", "toggledInPlace": true, "closedControllersReleased": true,
                "contentKinds": ["image", "text", "files", "color", "animation"], "contextActionCount": 25, "inPlaceToggleCount": 27,
                "scope": "Real AppKit flags, target/action menus, Settings view, metadata and lifecycle over synthetic local content",
                "physicalSpacesVerified": false, "snapshotBackground": PinWorkflowSnapshot.backgroundDescription, "physicalSpacesAcceptance": "NOT RUN: two desktops, fullscreen, two displays and Stage Manager require an interactive macOS session",
                "screenCaptureAttempted": false, "userPreferencesReadOrWritten": false,
                "sessionBytesUnchangedByToggle": true, "noActivationFollowFlag": true, "originalRasterProviderReleased": true,
                "snapshots": ["pin-desktop-settings.png", "pin-desktop-current-text.png"]]
    }

    private static func select(_ mode: PinDesktopVisibility, control: PinDesktopVisibilityMenu) throws {
        control.menuNeedsUpdate(control.menu)
        let item = try required(control.menu.items.first { $0.identifier?.rawValue == "pin.desktopVisibility." + mode.rawValue }, "Context control missing")
        try require(item.isEnabled && NSApp.sendAction(try required(item.action, "Control action missing"), to: item.target, from: item), "Context action failed")
        try require(item.state == .on && control.mode == mode, "Context selection not refreshed")
    }
    private static func verifyFlags(_ coordinator: PinSessionCoordinator, mode: PinDesktopVisibility) throws {
        let windows = coordinator.liveControllers.values.compactMap(\.window) + coordinator.richControllers.values.compactMap(\.window)
        try require(windows.count == coordinator.livePinCount && coordinator.desktopVisibility == mode, "Live count/mode mismatch")
        for window in windows {
            try require(window.collectionBehavior.contains(.canJoinAllSpaces) == (mode == .allDesktops), "Wrong Space flag")
            try require(!window.collectionBehavior.contains(.moveToActiveSpace), "Unexpected activation-follow")
            try require(window.collectionBehavior.contains(.fullScreenAuxiliary), "Fullscreen compatibility lost")
        }
    }
    private static func ownedProbes(_ coordinator: PinSessionCoordinator) throws -> [DesktopWindowProbe] {
        var result = try coordinator.liveControllers.values.map { try DesktopWindowProbe($0) }
        result += try coordinator.richControllers.values.map { try DesktopWindowProbe($0) }
        for pin in coordinator.liveControllers.values {
            if let editor = pin.annotationEditor { result.append(try DesktopWindowProbe(editor)) }
        }
        return result
    }
    private static func requireReleased(_ probes: [DesktopWindowProbe]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !autoreleasepool(invoking: { probes.allSatisfy(\.released) }), ProcessInfo.processInfo.systemUptime < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { continuation.resume() } }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try require(probes.allSatisfy(\.released), "Closed controller/content retained after bounded run-loop drain")
        for probe in probes { try require(probe.window.contentView == nil && !probe.window.isVisible && probe.window.delegate == nil, "Closed owned window not detached") }
    }
    private static func diskContents(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return result
    }
    /// Public CGDataProvider release callback checks the actual owned backing,
    /// avoiding unsupported assumptions about weak references to CF image objects.
    private static func trackedRaster(release: DesktopRasterReleaseProbe) throws -> CGImage {
        let width = 380, height = 190, count = width * height * 4
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        let pixels = storage.bindMemory(to: UInt8.self, capacity: count)
        for offset in stride(from: 0, to: count, by: 4) {
            pixels[offset] = 40; pixels[offset + 1] = 130; pixels[offset + 2] = 200; pixels[offset + 3] = 255
        }
        let retained = Unmanaged.passRetained(release)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: storage, size: count, releaseData: { info, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
            if let info { Unmanaged<DesktopRasterReleaseProbe>.fromOpaque(info).takeRetainedValue().markReleased() }
        }) else {
            storage.deallocate(); retained.release(); throw failure("Tracked provider allocation failed")
        }
        return try required(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent), "Tracked raster failed")
    }
    private static func raster(red: CGFloat = 0.15) throws -> CGImage {
        let context = try required(CGContext(data: nil, width: 380, height: 190, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Raster allocation failed")
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 380, height: 190))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)); context.fill(CGRect(x: 28, y: 28, width: 120, height: 80))
        return try required(context.makeImage(), "Raster failed")
    }
    private static func gif() throws -> Data {
        let data = NSMutableData()
        let destination = try required(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil), "GIF allocation failed")
        for red in [CGFloat(0.2), 0.8] { CGImageDestinationAddImage(destination, try raster(red: red), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary) }
        try require(CGImageDestinationFinalize(destination), "GIF encoding failed"); return data as Data
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        window.displayIfNeeded()
        let view = try required(window.contentView, "Snapshot view missing")
        try PinWorkflowSnapshot.write(view, to: url)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw failure(message) } }
    private static func required<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Pin desktop visibility fixture: " + message) }
}

@MainActor private final class DesktopWindowProbe {
    weak var controller: NSWindowController?
    weak var content: NSView?
    let window: NSWindow
    init(_ controller: NSWindowController) throws {
        guard let window = controller.window else { throw PicShotError.message("Missing fixture window") }
        self.controller = controller; self.window = window; content = window.contentView
    }
    var released: Bool { controller == nil && content == nil }
}

/// The provider may release on a render thread, outside the main actor.
private final class DesktopRasterReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var released: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func markReleased() { lock.lock(); value = true; lock.unlock() }
}
