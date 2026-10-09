import AppKit
import SwiftUI

/// Renders the production SwiftUI controls in a real 440-point native window.
/// Permissions are injected; no recording session, live monitor, OS permission
/// request, global event posting, or desktop capture is involved.
@MainActor
enum RecordingInputControlsPreviewFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var report: [String: Any] = ["status": "running", "contentWidthPoints": 440,
            "injectedPermissions": true, "recordingStarted": false, "screenCaptureStarted": false,
            "permissionRequested": false, "globalInputPosted": false, "nativeMonitorRegistrations": 0,
            "scope": "Native cached SwiftUI layout; interaction passes only when supported AppKit accessibility actions change the real monitor options",
            "snapshotPixelsPerPoint": 1]
        do {
            var appearances: [[String: Any]] = []
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                appearances.append(try await preview(name: name, appearance: appearance, directory: evidenceDirectory))
                report["appearances"] = appearances
            }
            let verified = appearances.allSatisfy { $0["interactionStatus"] as? String == "passed" }
            report["status"] = verified ? "passed" : "layout-only"
            report["interactionStatus"] = verified ? "passed" : "pending"
            try write(report, directory: evidenceDirectory)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? write(report, directory: evidenceDirectory)
            throw error
        }
    }

    private static func preview(name: String, appearance: NSAppearance.Name, directory: URL) async throws -> [String: Any] {
        let probe = PermissionProbe()
        let monitor = RecordingInputMonitor(state: RecordingInputEffectsState(), dependencies: probe.dependencies)
        let host = NSHostingView(rootView: RecordingInputEffectsControls(monitor: monitor)
            .padding(12).frame(width: 440, height: 100, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PicShot · Synthetic input permissions"
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close(); monitor.endSession() }
        try await settle(window)
        try require(!monitor.options.isEnabled && probe.permissionChecks == 0,
                    "Opening default-off controls inspected permissions or changed options")
        var files: [String] = []
        func save(_ state: String, window target: NSWindow? = nil) throws {
            let filename = "recording-input-\(state)-\(name).png"
            try snapshot(target ?? window, to: directory.appendingPathComponent(filename))
            files.append(filename)
        }
        try save("default-off")
        let identifiers = ["clicks", "scrolls", "shortcuts", "help"].map { "recording-input-" + $0 }
        var result: [String: Any] = ["appearance": name, "defaultOff": true, "initialPermissionChecks": 0,
                                   "interactionStatus": "pending", "layoutStatus": "pending"]
        do {
            result["defaultOffGeometry"] = try geometry(identifiers, in: window, hitTest: true)
            try require(element("recording-input-status", in: window) == nil, "Default-off status should be absent")
            let toggles: [(String, WritableKeyPath<RecordingInputEffectsOptions, Bool>)] = [
                ("clicks", \.clicks), ("scrolls", \.scrolls), ("shortcuts", \.shortcuts)]
            var presses = 0
            for (suffix, keyPath) in toggles {
                // Repeated native presses must change only this option, and must
                // return to off before enabling it for the denied-state preview.
                for enabled in [true, false, true] {
                    var expected = monitor.options; expected[keyPath: keyPath] = enabled
                    try press("recording-input-" + suffix, in: window)
                    try await settle(window)
                    try require(monitor.options == expected, "Native \(suffix) press did not update only its bound option")
                    presses += 1
                }
            }
            result["nativeTogglePresses"] = presses
            result["deniedGeometry"] = try geometry(identifiers + ["recording-input-status"], in: window, hitTest: false)
            try require(monitor.permissions == .unknown, "Injected denied permission did not reach the controls")
            try require(status(in: window).contains("输入监控"), "Denied controls omitted input-monitoring guidance")
            try save("denied")

            let previousWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
            try press("recording-input-help", in: window)
            try await settle(window)
            let candidates = NSApp.windows.filter { !previousWindows.contains(ObjectIdentifier($0)) } + (window.childWindows ?? [])
            guard let help = candidates.first(where: { element("recording-input-refresh", in: $0) != nil }) else {
                throw RouteUnavailable(reason: "Help opened, but its refresh control was not exposed by the supported native accessibility route")
            }
            defer { help.close() }
            try await settle(help)
            result["helpGeometry"] = try geometry(["recording-input-refresh"], in: help, hitTest: true)
            try save("help-denied", window: help)
            let checksBeforeRefresh = probe.permissionChecks
            probe.permissions = .init(inputMonitoring: true, accessibility: true)
            try press("recording-input-refresh", in: help)
            try await settle(help)
            try require(probe.permissionChecks > checksBeforeRefresh && monitor.permissions == probe.permissions,
                        "Native refresh did not read the injected granted permission")
            try save("help-allowed", window: help)
            try press("recording-input-help", in: window)
            try await settle(window)
            try require(!help.isVisible, "Native help toggle did not dismiss its popover")
            result["allowedGeometry"] = try geometry(identifiers + ["recording-input-status"], in: window, hitTest: false)
            try require(status(in: window).contains("开始 / 继续录制"), "Allowed idle controls omitted recording-lifecycle guidance")
            try save("allowed")
            result["interactionStatus"] = "passed"; result["layoutStatus"] = "passed"
            result["helpAndRefreshVerified"] = true
        } catch let unavailable as RouteUnavailable {
            // Model injection here produces layout evidence only. It must never
            // be counted as successful interaction with a native control.
            result["interactionStatus"] = "pending"; result["reason"] = unavailable.reason
            monitor.options = .init(clicks: true, scrolls: true, shortcuts: true)
            probe.permissions = .unknown; monitor.refreshPermissions()
            try await settle(window); try save("denied")
            probe.permissions = .init(inputMonitoring: true, accessibility: true); monitor.refreshPermissions()
            try await settle(window); try save("allowed")
        }
        try require(!monitor.isMonitoring && probe.installCalls == 0 && probe.removeCalls == 0 && probe.healthChecks == 0,
                    "Idle input controls attempted to install a monitor or timer")
        result["files"] = Array(Set(files)).sorted()
        result["injectedPermissionChecks"] = probe.permissionChecks
        result["nativeMonitorRegistrations"] = 0
        return result
    }

    /// Only public method-based AppKit accessibility APIs, scoped to the owned
    /// fixture window. SwiftUI implementation classes are neither named nor cast.
    private static func element(_ identifier: String, in window: NSWindow) -> (any NSAccessibilityProtocol)? {
        var pending: [Any] = [window]
        if let view = window.contentView { pending.append(view) }
        var visited = Set<ObjectIdentifier>()
        while let value = pending.popLast() {
            guard let node = value as? any NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(node)).inserted else { continue }
            if node.accessibilityIdentifier() == identifier { return node }
            pending.append(contentsOf: node.accessibilityChildren() ?? [])
        }
        return nil
    }

    private static func press(_ identifier: String, in window: NSWindow) throws {
        guard let node = element(identifier, in: window), node.isAccessibilityEnabled(),
              node.isAccessibilitySelectorAllowed(#selector(NSAccessibilityProtocol.accessibilityPerformPress)),
              node.accessibilityPerformPress() else {
            throw RouteUnavailable(reason: "Supported native accessibility press unavailable for " + identifier)
        }
    }

    private static func status(in window: NSWindow) -> String {
        guard let node = element("recording-input-status", in: window) else { return "" }
        return [node.accessibilityLabel(), node.accessibilityTitle(), node.accessibilityValue() as? String]
            .compactMap { $0 }.joined(separator: " ")
    }

    private static func geometry(_ identifiers: [String], in window: NSWindow, hitTest: Bool) throws -> [[String: Any]] {
        guard let view = window.contentView else { throw failure("Missing native content view") }
        let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
        var frames: [CGRect] = [], output: [[String: Any]] = []
        for identifier in identifiers {
            guard let node = element(identifier, in: window) else {
                throw RouteUnavailable(reason: "Supported accessibility geometry unavailable for " + identifier)
            }
            let frame = node.accessibilityFrame()
            try require(!frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0 &&
                        bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Control is clipped or outside native content: " + identifier)
            try require(!frames.contains { other in
                let overlap = other.intersection(frame)
                return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
            }, "Native control frames overlap: " + identifier)
            if hitTest {
                var hit = view.accessibilityHitTest(CGPoint(x: frame.midX, y: frame.midY)) as? any NSAccessibilityProtocol
                var visited = Set<ObjectIdentifier>(), matches = false
                while let candidate = hit, visited.insert(ObjectIdentifier(candidate)).inserted {
                    if candidate.accessibilityIdentifier() == identifier { matches = true; break }
                    hit = candidate.accessibilityParent() as? any NSAccessibilityProtocol
                }
                guard matches else { throw RouteUnavailable(reason: "Native accessibility hit target could not be verified for " + identifier) }
            }
            frames.append(frame)
            output.append(["identifier": identifier, "x": frame.minX - bounds.minX, "y": frame.minY - bounds.minY,
                           "width": frame.width, "height": frame.height, "insideContent": true,
                           "nonoverlapping": true, "nativeHitTargetVerified": hitTest])
        }
        return output
    }

    private static func settle(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }

    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else { throw failure("Missing snapshot content") }
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        guard width > 0, height > 0, width <= 600, height <= 800,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4, bitsPerPixel: 32) else { throw failure("Snapshot exceeded compact fixture bounds") }
        bitmap.size = view.bounds.size
        window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let cached = bitmap.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw failure("Cannot compose native snapshot") }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cached, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw failure("Cannot encode native snapshot") }
        try png.write(to: url, options: .atomic)
    }

    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("recording-input-controls.json"), options: .atomic)
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Recording input controls: " + message) }
    private struct RouteUnavailable: Error { let reason: String }

    @MainActor private final class PermissionProbe {
        var permissions = RecordingInputPermissions.unknown
        var permissionChecks = 0, installCalls = 0, removeCalls = 0, healthChecks = 0
        var dependencies: RecordingInputMonitorDependencies {
            .init(permissions: { self.permissionChecks += 1; return self.permissions },
                  secureInputEnabled: { false }, focusedContext: { .ordinary },
                  install: { _, _ in self.installCalls += 1; return nil }, remove: { _ in self.removeCalls += 1 },
                  scheduleHealthCheck: { _ in self.healthChecks += 1; return {} }, clock: { 100 })
        }
    }
}
