import AppKit
import PicShotCore

/// Source-scoped native interaction fixture: actual AppKit windows, NSEvents and
/// button actions, but explicit synthetic inventory/screens/pixels. This does NOT
/// invoke the screenshot command, screen recording/AX permissions, or desktop
/// pixel access and must not be reported as physical multi-monitor/TCC coverage.
@MainActor
enum MultiWindowCaptureNativeFixture {
    static func verify() async throws -> [String: Any] {
        guard let screen = MultiWindowSelectionScreen.current().first else { throw MultiWindowCaptureError.invalidWindow }
        let first = try MultiWindowDescriptor(id: 101, ownerPID: 9001, ownerStartedAt: 1, label: "Synthetic front window",
            bounds: CGRect(x: screen.quartzFrame.minX + 70, y: screen.quartzFrame.minY + 70, width: 120, height: 80), maximumScale: 1)
        let second = try MultiWindowDescriptor(id: 202, ownerPID: 9002, ownerStartedAt: 2, label: "Synthetic back window",
            bounds: CGRect(x: screen.quartzFrame.minX + 140, y: screen.quartzFrame.minY + 100, width: 120, height: 80), maximumScale: 1)
        let sources = [first, second]
        var inventory = sources, captures: [UInt32] = [], permissionChecks = 0
        let provider = MultiWindowCaptureProviders(permission: { permissionChecks += 1 }, screens: { [screen] }, inventory: { _ in inventory },
            displayValidator: { {} }, frame: { source, _ in captures.append(source.id); return try image(source) })
        let controller = MultiWindowCaptureController(providers: provider)
        let task = Task { try await controller.capture() }
        do {
            let selector = try await awaitSelector(controller)
            guard let view = selector.views.first else { throw MultiWindowCaptureError.incomplete }
            try await assertWindowHit(view, quartz: CGPoint(x: first.bounds.minX + 8, y: first.bounds.minY + 8))
            try click(view, quartz: CGPoint(x: first.bounds.minX + 8, y: first.bounds.minY + 8))
            guard selector.selection.selectedIDs == [first.id] else { throw MultiWindowCaptureError.incomplete }
            try click(view, quartz: CGPoint(x: second.bounds.minX + 8, y: second.bounds.minY + 8), flags: .option)
            try key(view, code: 49, value: " ")
            guard selector.selection.selectedIDs == Set(sources.map(\.id)) else { throw MultiWindowCaptureError.incomplete }
            try key(view, code: 49, value: " ")
            guard selector.selection.selectedIDs == [first.id] else { throw MultiWindowCaptureError.incomplete }
            try key(view, code: 49, value: " ")
            view.captureButton.performClick(nil)
            let output = try await task.value
            guard output.width == 190, output.height == 110, captures == [second.id, first.id],
                  !selector.isSelecting, selector.panels.isEmpty, controller.activeSelector == nil else { throw MultiWindowCaptureError.incomplete }
        } catch { task.cancel(); _ = try? await task.value; throw error }

        // Escape, the real Cancel button, external task cancellation, and changed
        // inventory all dismiss the same live selector and start zero captures.
        for mode in 0..<4 {
            captures.removeAll(); inventory = sources
            let pending = Task { try await controller.capture() }
            do {
                let selector = try await awaitSelector(controller)
                guard let view = selector.views.first else { throw MultiWindowCaptureError.incomplete }
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
                guard captures.isEmpty, selector.panels.isEmpty, !selector.isSelecting,
                      controller.activeSelector == nil else { throw MultiWindowCaptureError.incomplete }
            } catch { pending.cancel(); _ = try? await pending.value; throw error }
        }
        return ["status": "passed", "source": "injected inventory, display, permission and RGBA frame providers",
                "nativeActions": ["native transparent-area hit test", "mouse select", "Option-click overlap", "Space deselect/reselect", "Capture button", "Escape", "Cancel button", "task cancellation", "window closure"],
                "permissionRequested": false, "realDesktopCaptured": false, "permissionProviderChecks": permissionChecks,
                "physicalMultiMonitorValidated": false, "systemScreenshotCommandInvoked": false]
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
        // Deliver a native NSEvent to the selector's actual NSView input path;
        // this does not synthesize a global event or require Accessibility access.
        view.mouseDown(with: event)
    }
    private static func key(_ view: MultiWindowSelectionView, code: UInt16, value: String) throws {
        guard let window = view.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code) else { throw MultiWindowCaptureError.incomplete }
        view.keyDown(with: event)
    }
    private static func image(_ source: MultiWindowDescriptor) throws -> CGImage {
        let width = Int(source.bounds.width), height = Int(source.bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8((x + Int(source.id)) % 256); bytes[offset + 1] = UInt8((y * 3) % 256)
            bytes[offset + 2] = 90; bytes[offset + 3] = 255
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw MultiWindowCaptureError.incomplete }
        return image
    }
}
