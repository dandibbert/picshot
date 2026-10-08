import AppKit
import CoreText
import ImageIO
import PicShotCore

/// Actual AppKit selector panels, hit testing, NSEvents and button actions over
/// an owned synthetic backdrop. Inventory, screens, permission and input pixels
/// are injected. Evidence caches ONLY these owned views, never desktop pixels.
/// This does not establish real capture, TCC or physical multi-monitor behavior.
@MainActor
enum MultiWindowCaptureNativeFixture {
    static func verify(evidenceDirectory: URL? = nil) async throws -> [String: Any] {
        guard let screen = MultiWindowSelectionScreen.current().first else { throw MultiWindowCaptureError.invalidWindow }
        if let evidenceDirectory { try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true) }
        let previousAppearance = NSApp.appearance
        let factor = min(1, min(screen.appKitFrame.width / 800, screen.appKitFrame.height / 600))
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: screen.quartzFrame.minX + (x * factor).rounded(), y: screen.quartzFrame.minY + (y * factor).rounded(),
                   width: max(20, (width * factor).rounded()), height: max(20, (height * factor).rounded()))
        }
        let first = try MultiWindowDescriptor(id: 101, ownerPID: 9001, ownerStartedAt: 1, label: "Synthetic · Capture plan",
            bounds: rect(80, 90, 360, 230), maximumScale: 1)
        let second = try MultiWindowDescriptor(id: 202, ownerPID: 9002, ownerStartedAt: 2, label: "Synthetic · Color reference",
            bounds: rect(240, 165, 360, 230), maximumScale: 1)
        let sources = [first, second]
        // These two small oracle images intentionally remain in this fixture.
        // Production capture uses a sequential one-frame provider instead.
        let pixels = try Dictionary(uniqueKeysWithValues: sources.map { ($0.id, try image($0)) })
        let backdropView = MultiWindowOwnedBackdrop(frame: CGRect(origin: .zero, size: screen.appKitFrame.size), screen: screen,
            windows: sources, images: pixels)
        let backdrop = NSWindow(contentRect: screen.appKitFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false; backdrop.isOpaque = true; backdrop.hasShadow = false
        backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        backdrop.ignoresMouseEvents = true; backdrop.contentView = backdropView
        backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil); backdrop.close(); NSApp.appearance = previousAppearance }
        var inventory = sources, captures: [UInt32] = [], permissionChecks = 0
        let provider = MultiWindowCaptureProviders(permission: { permissionChecks += 1 }, screens: { [screen] }, inventory: { _ in inventory },
            displayValidator: { {} }, frame: { source, _ in
                captures.append(source.id)
                guard let image = pixels[source.id] else { throw MultiWindowCaptureError.incomplete }; return image
            })
        let controller = MultiWindowCaptureController(providers: provider)
        var cleanupChecks = 0, completedCaptures = 0, cancelledSessions = 0
        var checkedPixels = 0, transparentPixels = 0, translucentPixels = 0, overlapPixels = 0
        var evidence: [String] = []
        var retiredSelectors: [WeakMultiWindowSelector] = []
        var retiredPanels: [WeakMultiWindowPanel] = []

        // Capture twice on the same controller with four interrupted sessions in
        // between. Both appearances use the real selector and real compositor.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            inventory = sources; captures.removeAll()
            NSApp.appearance = NSAppearance(named: appearance); backdrop.appearance = NSApp.appearance
            backdropView.needsDisplay = true
            let task = Task { try await controller.capture() }
            do {
                let selector = try await awaitSelector(controller)
                guard let view = selector.views.first else { throw MultiWindowCaptureError.incomplete }
                retiredSelectors.append(WeakMultiWindowSelector(selector))
                retiredPanels.append(contentsOf: selector.panels.map { WeakMultiWindowPanel($0) })
                selector.panels.forEach { $0.appearance = NSApp.appearance }
                let firstPoint = CGPoint(x: first.bounds.minX + 16, y: first.bounds.minY + 16)
                try await assertWindowHit(view, quartz: firstPoint)
                try click(view, quartz: firstPoint)
                guard selector.selection.selectedIDs == [first.id] else { throw MultiWindowCaptureError.incomplete }
                try click(view, quartz: CGPoint(x: second.bounds.minX + 16, y: second.bounds.minY + 16), flags: .option)
                try key(view, code: 49, value: " ")
                guard selector.selection.selectedIDs == Set(sources.map(\.id)) else { throw MultiWindowCaptureError.incomplete }
                try key(view, code: 49, value: " ")
                guard selector.selection.selectedIDs == [first.id] else { throw MultiWindowCaptureError.incomplete }
                try key(view, code: 49, value: " ")
                if let evidenceDirectory {
                    try await Task.sleep(nanoseconds: 60_000_000)
                    let name = appearance == .aqua ? "multi-window-selection-light.png" : "multi-window-selection-dark.png"
                    try writePNG(ownedSelectionEvidence(backdrop: backdropView, selector: view), to: evidenceDirectory.appendingPathComponent(name))
                    evidence.append(name)
                }
                view.captureButton.performClick(nil)
                let output = try await task.value
                let check = try validatePixels(output, sources: sources, images: pixels)
                checkedPixels += check.checked; transparentPixels += check.transparent
                translucentPixels += check.translucent; overlapPixels += check.overlap
                guard captures == [second.id, first.id], !selector.isSelecting, selector.panels.isEmpty,
                      selector.views.isEmpty, controller.activeSelector == nil else { throw MultiWindowCaptureError.incomplete }
                if let evidenceDirectory, completedCaptures == 0 {
                    let name = "multi-window-composed-rgba.png"
                    try writePNG(output, to: evidenceDirectory.appendingPathComponent(name)); evidence.append(name)
                }
                try assertObserverCleanup(selector)
                cleanupChecks += 1; completedCaptures += 1
            } catch { task.cancel(); _ = try? await task.value; throw error }

            if appearance == .aqua {
                for mode in 0..<4 {
                    captures.removeAll(); inventory = sources
                    let pending = Task { try await controller.capture() }
                    do {
                        let selector = try await awaitSelector(controller)
                        guard let view = selector.views.first else { throw MultiWindowCaptureError.incomplete }
                        retiredSelectors.append(WeakMultiWindowSelector(selector))
                        retiredPanels.append(contentsOf: selector.panels.map { WeakMultiWindowPanel($0) })
                        switch mode {
                        case 0: try key(view, code: 53, value: "\u{1b}")
                        case 1: view.cancelButton.performClick(nil)
                        case 2: pending.cancel()
                        default: inventory = []; try key(view, code: 36, value: "\r")
                        }
                        do { _ = try await pending.value; throw MultiWindowCaptureError.incomplete }
                        catch CaptureError.cancelled {}
                        catch is CancellationError {}
                        catch MultiWindowCaptureError.changed where mode == 3 {}
                        guard captures.isEmpty, selector.panels.isEmpty, selector.views.isEmpty, !selector.isSelecting,
                              controller.activeSelector == nil else { throw MultiWindowCaptureError.incomplete }
                        try assertObserverCleanup(selector)
                        cleanupChecks += 1; cancelledSessions += 1
                    } catch { pending.cancel(); _ = try? await pending.value; throw error }
                }
            }
        }
        // There must be no selector/panel ownership left. Wait beyond the old
        // 250ms timer interval: stale timer/observer work may not restart capture.
        let callsAtCompletion = permissionChecks
        try await Task.sleep(nanoseconds: 300_000_000)
        guard permissionChecks == callsAtCompletion, controller.activeSelector == nil,
              retiredSelectors.allSatisfy({ $0.value == nil }), retiredPanels.allSatisfy({ $0.value?.isVisible != true }) else {
            throw MultiWindowCaptureError.incomplete
        }
        backdrop.orderOut(nil); backdrop.close()
        guard !backdrop.isVisible else { throw MultiWindowCaptureError.incomplete }
        return ["status": "passed", "source": "owned synthetic backdrop; injected inventory, display, permission and RGBA providers",
                "nativeActions": ["WindowServer hit test", "mouse select", "Option-click overlap", "Space deselect/reselect", "Capture button", "Escape", "Cancel button", "task cancellation", "window closure"],
                "permissionRequested": false, "realDesktopCaptured": false, "permissionProviderChecks": permissionChecks,
                "physicalMultiMonitorValidated": false, "systemScreenshotCommandInvoked": false,
                "completedCapturesSameController": completedCaptures, "cancelledSessionsSameController": cancelledSessions,
                "cleanupChecks": cleanupChecks, "clearedObserverTimerContinuationChecks": cleanupChecks, "retainedSelectors": retiredSelectors.filter { $0.value != nil }.count,
                "visibleRetiredPanels": retiredPanels.filter { $0.value?.isVisible == true }.count,
                "ownedBackdropClosed": !backdrop.isVisible, "inactiveTimerWindowMilliseconds": 300,
                "latePermissionProviderCalls": permissionChecks - callsAtCompletion,
                "exactRGBAPixelsChecked": checkedPixels, "transparentPixelsChecked": transparentPixels,
                "translucentPixelsChecked": translucentPixels, "overlapPixelsChecked": overlapPixels,
                "evidenceFiles": evidence,
                "evidenceMethod": "native owned-view cache composited over owned backdrop; no WindowServer pixel read"]
    }

    private static func validatePixels(_ output: CGImage, sources: [MultiWindowDescriptor], images: [UInt32: CGImage]) throws
        -> (checked: Int, transparent: Int, translucent: Int, overlap: Int) {
        let layout = try MultiWindowCaptureLayout(frontToBack: sources)
        guard output.width == layout.width, output.height == layout.height else { throw MultiWindowCaptureError.incomplete }
        let sourceBytes = try Dictionary(uniqueKeysWithValues: images.map { ($0.key, try bytes($0.value)) })
        let result = try bytes(output)
        var transparent = 0, translucent = 0, overlap = 0
        for y in 0..<output.height { for x in 0..<output.width {
            var expected: (UInt8, UInt8, UInt8, UInt8) = (0,0,0,0)
            var hits = 0
            for placement in layout.placements {
                let rect = placement.pixelBounds
                guard rect.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)),
                      let data = sourceBytes[placement.window.id], let image = images[placement.window.id] else { continue }
                hits += 1
                let offset = ((y - Int(rect.minY)) * image.width + x - Int(rect.minX)) * 4
                let source = (data[offset], data[offset+1], data[offset+2], data[offset+3])
                if source.3 == 255 { expected = source }
                else if source.3 != 0 {
                    // Semitransparent samples are intentionally placed over a
                    // transparent gap, so the exact expected RGBA is unchanged.
                    guard expected.3 == 0 else { throw MultiWindowCaptureError.incomplete }
                    expected = source
                }
            }
            let offset = (y * output.width + x) * 4
            guard result[offset] == expected.0, result[offset+1] == expected.1,
                  result[offset+2] == expected.2, result[offset+3] == expected.3 else { throw MultiWindowCaptureError.incomplete }
            if expected.3 == 0 { transparent += 1 }
            if expected.3 > 0 && expected.3 < 255 { translucent += 1 }
            if hits == 2 { overlap += 1 }
        } }
        guard transparent > 0, translucent > 0, overlap > 0 else { throw MultiWindowCaptureError.incomplete }
        return (output.width * output.height, transparent, translucent, overlap)
    }
    private static func assertObserverCleanup(_ selector: MultiWindowSelectionController) throws {
        // This source-scoped fixture intentionally inspects the existing private
        // optional tokens rather than changing the production selector API.
        let state = Dictionary(uniqueKeysWithValues: Mirror(reflecting: selector).children.compactMap { child -> (String, Any)? in
            guard let label = child.label else { return nil }; return (label, child.value)
        })
        for name in ["continuation", "timer", "observer", "sessionID"] {
            guard let value = state[name] else { throw MultiWindowCaptureError.incomplete }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle == .optional, mirror.children.isEmpty else { throw MultiWindowCaptureError.incomplete }
        }
    }
    private static func bytes(_ image: CGImage) throws -> [UInt8] {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { throw MultiWindowCaptureError.incomplete }
        var result: [UInt8] = []; result.reserveCapacity(image.width * image.height * 4)
        for y in 0..<image.height { result.append(contentsOf: UnsafeBufferPointer(start: pointer.advanced(by: y * image.bytesPerRow), count: image.width * 4)) }
        return result
    }
    private static func ownedSelectionEvidence(backdrop: NSView, selector: NSView) throws -> CGImage {
        let background = try cache(backdrop), overlay = try cache(selector)
        guard background.width == overlay.width, background.height == overlay.height,
              let context = CGContext(data: nil, width: background.width, height: background.height, bitsPerComponent: 8,
                bytesPerRow: background.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw MultiWindowCaptureError.incomplete }
        let bounds = CGRect(x: 0, y: 0, width: background.width, height: background.height)
        context.draw(background, in: bounds); context.draw(overlay, in: bounds)
        guard let image = context.makeImage() else { throw MultiWindowCaptureError.incomplete }; return image
    }
    private static func cache(_ view: NSView) throws -> CGImage {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: Int(view.bounds.width) * 4, bitsPerPixel: 32) else { throw MultiWindowCaptureError.incomplete }
        rep.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { throw MultiWindowCaptureError.incomplete }; return image
    }
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw MultiWindowCaptureError.incomplete }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MultiWindowCaptureError.incomplete }
    }
    private static func awaitSelector(_ controller: MultiWindowCaptureController) async throws -> MultiWindowSelectionController {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < until {
            if let selector = controller.activeSelector, selector.isSelecting, !selector.views.isEmpty { return selector }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw MultiWindowCaptureError.deadline
    }
    private static func assertWindowHit(_ view: MultiWindowSelectionView, quartz: CGPoint) async throws {
        guard let window = view.window, !window.ignoresMouseEvents else { throw MultiWindowCaptureError.incomplete }
        let local = CGPoint(x: quartz.x - view.screen.quartzFrame.minX,
                            y: view.screen.appKitFrame.height - (quartz.y - view.screen.quartzFrame.minY))
        let point = window.convertPoint(toScreen: view.convert(local, to: nil))
        let until = ProcessInfo.processInfo.systemUptime + 1
        repeat {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); window.displayIfNeeded()
            if NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber,
               view.hitTest(local) === view { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while ProcessInfo.processInfo.systemUptime < until
        throw MultiWindowCaptureError.incomplete
    }
    private static func click(_ view: MultiWindowSelectionView, quartz: CGPoint, flags: NSEvent.ModifierFlags = []) throws {
        let local = CGPoint(x: quartz.x - view.screen.quartzFrame.minX,
                            y: view.screen.appKitFrame.height - (quartz.y - view.screen.quartzFrame.minY))
        guard let window = view.window, let event = NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(local, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw MultiWindowCaptureError.incomplete }
        view.mouseDown(with: event)
    }
    private static func key(_ view: MultiWindowSelectionView, code: UInt16, value: String) throws {
        guard let window = view.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code) else { throw MultiWindowCaptureError.incomplete }
        view.keyDown(with: event)
    }
    private static func image(_ source: MultiWindowDescriptor) throws -> CGImage {
        let width = Int(source.bounds.width), height = Int(source.bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            var value: [UInt8]
            if x < 4 || x >= width - 4 || y >= height - 4 { value = [0,0,0,0] }
            else if y < 5 { value = [48,80,112,128] }
            else if y < 35 { value = [32,42,62,255] }
            else if x < 72 { value = [224,231,241,255] }
            else if y > 70 && y < 130 && x > 92 && x < width - 22 {
                value = source.id == 101 ? [47,113,225,255] : [18,153,135,255]
            } else if y > 148 && y % 24 < 5 && x > 92 && x < width - 32 { value = [154,170,194,255] }
            else { value = [247,249,252,255] }
            let offset = (y * width + x) * 4
            for channel in 0..<4 { pixels[offset+channel] = value[channel] }
        } }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let base = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw MultiWindowCaptureError.incomplete }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let title = source.id == 101 ? "Capture plan" : "Color reference"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 13, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]) as CFAttributedString)
        context.textPosition = CGPoint(x: 18, y: height - 26); CTLineDraw(line, context)
        guard let result = context.makeImage() else { throw MultiWindowCaptureError.incomplete }; return result
    }
}

@MainActor private final class MultiWindowOwnedBackdrop: NSView {
    let screen: MultiWindowSelectionScreen
    let windows: [MultiWindowDescriptor]
    let images: [UInt32: CGImage]
    init(frame: CGRect, screen: MultiWindowSelectionScreen, windows: [MultiWindowDescriptor], images: [UInt32: CGImage]) {
        self.screen = screen; self.windows = windows; self.images = images; super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(calibratedRed: dark ? 0.07 : 0.88, green: dark ? 0.10 : 0.93, blue: dark ? 0.17 : 0.98, alpha: 1).setFill(); bounds.fill()
        let headline = "PicShot · Multi-window capture"
        (headline as NSString).draw(at: CGPoint(x: 32, y: bounds.height - 36), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.labelColor])
        ("OWNED SYNTHETIC WINDOWS · Injected pixels · No desktop capture" as NSString).draw(at: CGPoint(x: 32, y: bounds.height - 59),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        for window in windows.reversed() {
            guard let image = images[window.id] else { continue }
            NSGraphicsContext.current?.cgContext.draw(image, in: screen.localRect(fromQuartz: window.bounds))
        }
    }
}
@MainActor private final class WeakMultiWindowSelector {
    weak var value: MultiWindowSelectionController?
    init(_ value: MultiWindowSelectionController) { self.value = value }
}
@MainActor private final class WeakMultiWindowPanel {
    weak var value: MultiWindowSelectionPanel?
    init(_ value: MultiWindowSelectionPanel) { self.value = value }
}
