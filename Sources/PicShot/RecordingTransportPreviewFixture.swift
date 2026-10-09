import AppKit

/// Native presentation acceptance, using injected snapshots and callbacks only.
/// No RecordingService, stream, TCC request, event monitor or global event is
/// created. The owner can include this in its installed UI-preview run.
@MainActor
enum RecordingTransportPreviewFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var report: [String: Any] = ["status": "running", "interactionRoute": "NSButton.performClick",
            "hitTestRoute": "NSView.hitTest", "dragRoute": "local NSView mouseDown/mouseDragged/mouseUp",
            "recordingStarted": false, "permissionRequested": false, "globalInputPosted": false,
            "nativeMonitorRegistrations": 0, "productionTimers": 0, "productionObservers": 0,
            "captureExclusion": "sharingType.none asserted; physical ScreenCaptureKit exclusion not tested",
            "snapshotPixelsPerPoint": 1, "contentWidthPoints": 300, "contentHeightPoints": 40]
        do {
            var appearances: [[String: Any]] = []
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let ownership = Ownership()
                report["phase"] = name
                var result = try autoreleasepool {
                    try exercise(name: name, appearance: appearance, directory: evidenceDirectory, ownership: ownership)
                }
                result["ownership"] = try await verifyReleased(ownership)
                appearances.append(result)
                report["appearances"] = appearances
                try write(report, directory: evidenceDirectory)
            }
            report["placement"] = try verifyPlacement()
            let ownership = Ownership()
            for _ in 0..<8 {
                autoreleasepool {
                    let owner = ActionProbe()
                    let controller = RecordingTransportController(actions: owner.actions)
                    observe(controller, owner: owner, ownership: ownership)
                    controller.show(snapshot: active, anchor: CGRect(x: 40, y: 80, width: 320, height: 240),
                                    visibleFrame: screenBounds)
                    controller.hide(); controller.teardown(); controller.teardown()
                }
            }
            report["repeatedRetirement"] = try await verifyReleased(ownership)
            report["retirementCycles"] = 8
            report["status"] = "passed"; report["phase"] = "complete"
            try write(report, directory: evidenceDirectory)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? write(report, directory: evidenceDirectory)
            throw error
        }
    }

    private static var active: RecordingTransportSnapshot {
        RecordingTransportSnapshot(canPause: true, canStop: true, elapsed: 83,
            pauseShortcut: "⌥⌘P", stopShortcut: "⌥⌘S")
    }
    private static var screenBounds: CGRect { NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800) }

    private static func exercise(name: String, appearance: NSAppearance.Name, directory: URL,
                                 ownership: Ownership) throws -> [String: Any] {
        let owner = ActionProbe()
        let controller = RecordingTransportController(actions: owner.actions)
        owner.controller = controller
        observe(controller, owner: owner, ownership: ownership)
        defer { controller.teardown() }
        guard let window = controller.window, let view = window.contentView as? RecordingTransportView else {
            throw failure("Missing native transport")
        }
        window.appearance = NSAppearance(named: appearance)
        let screen = screenBounds
        let anchor = CGRect(x: screen.midX - 160, y: screen.midY - 60, width: 320, height: 200)
        controller.show(snapshot: active, anchor: anchor, visibleFrame: screen)
        try require(window.sharingType == .none && !window.styleMask.contains(.closable), "Unexpected close or sharing policy")
        try require(!window.isMovable && !window.isMovableByWindowBackground, "Window-wide dragging was enabled")
        var states: [[String: Any]] = []
        states.append(try capture("recording", appearance: name, window: window, directory: directory))
        let initialOrigin = window.frame.origin
        view.pauseButton.performClick(nil)
        try require(owner.pauseCalls == 1 && owner.stopCalls == 0, "Pause did not reach its injected owner once")
        var snapshot = active
        snapshot.paused = true; snapshot.statusKind = .paused; snapshot.status = "已暂停"
        controller.update(snapshot: snapshot)
        try require(view.pauseButton.accessibilityLabel() == "继续录屏" && view.pauseButton.isEnabled, "Pause did not become Resume")
        try require(window.frame.origin == initialOrigin, "Live state update moved the strip")
        states.append(try capture("paused", appearance: name, window: window, directory: directory))
        view.pauseButton.performClick(nil)
        try require(owner.pauseCalls == 2, "Resume did not use the same owner route")

        snapshot.busy = true; snapshot.canStop = true; snapshot.status = "正在暂停…"
        controller.update(snapshot: snapshot)
        view.pauseButton.performClick(nil); view.stopButton.performClick(nil)
        try require(owner.pauseCalls == 2 && owner.stopCalls == 1 && view.stopButton.isEnabled,
                    "Busy Pause blocked Stop or allowed another Pause")
        snapshot.statusKind = .saving; snapshot.status = "正在保存…"; snapshot.canStop = false
        controller.update(snapshot: snapshot)
        view.pauseButton.performClick(nil); view.stopButton.performClick(nil)
        try require(owner.pauseCalls == 2 && owner.stopCalls == 1, "Disabled save-state controls invoked actions")
        states.append(try capture("saving", appearance: name, window: window, directory: directory))

        let replacement = ActionProbe()
        replacement.controller = controller
        ownership.add(replacement, "replacement.owner")
        snapshot.busy = false; snapshot.canPause = false; snapshot.canStop = true
        snapshot.statusKind = .error; snapshot.status = "保存失败 · 展开查看"
        snapshot.pauseShortcut = nil; snapshot.stopShortcut = "⇧⌘S"
        controller.update(snapshot: snapshot, actions: replacement.actions)
        try require(view.pauseButton.toolTip?.contains("未设置快捷键") == true && view.stopButton.toolTip?.contains("⇧⌘S") == true,
                    "Shortcut help retained old bindings")
        view.stopButton.performClick(nil)
        try require(replacement.stopCalls == 1 && owner.stopCalls == 1, "Action update retained the old owner")
        states.append(try capture("error", appearance: name, window: window, directory: directory))

        let drag = try verifyDrag(controller, view: view, window: window, screen: screen)
        let draggedOrigin = window.frame.origin
        view.expandButton.performClick(nil)
        try require(replacement.expandCalls == 1 && !window.isVisible && replacement.stopCalls == 1,
                    "Expand failed to hide presentation or invoked Stop")
        controller.show(snapshot: active, anchor: anchor.offsetBy(dx: 80, dy: 50), visibleFrame: screen)
        try require(window.frame.origin == draggedOrigin && window.isVisible, "Collapse/reopen lost the dragged anchor")

        // Old control references cannot dispatch after teardown, even if a
        // delayed client attempts a native click. No timer/observer is installed.
        controller.teardown()
        view.pauseButton.performClick(nil); view.stopButton.performClick(nil); view.expandButton.performClick(nil)
        try require(replacement.stopCalls == 1 && replacement.expandCalls == 1 && controller.window == nil,
                    "Retired controls dispatched an action or retained their window")
        try require(view.pauseButton.target == nil && view.stopButton.target == nil && view.expandButton.target == nil,
                    "Retirement retained a native button target")
        return ["status": "passed", "appearance": name, "states": states,
                "initialPauseCalls": owner.pauseCalls, "initialStopCalls": owner.stopCalls,
                "replacementStopCalls": replacement.stopCalls, "replacementExpandCalls": replacement.expandCalls,
                "busyStopVerified": true, "replacementActionsVerified": true, "shortcutUpdatesVerified": true,
                "expandHideRestoreVerified": true, "retiredActionsVerified": true, "drag": drag]
    }

    private static func verifyDrag(_ controller: RecordingTransportController, view: RecordingTransportView,
                                   window: NSWindow, screen: CGRect) throws -> [String: Any] {
        let before = window.frame
        let start = window.convertPoint(toScreen: view.grip.convert(CGPoint(x: 10, y: 16), to: nil))
        view.grip.mouseDown(with: try event(.leftMouseDown, point: start, window: window))
        let destination = CGPoint(x: start.x + 37, y: start.y - 21)
        view.grip.mouseDragged(with: try event(.leftMouseDragged, point: destination, window: window))
        view.grip.mouseUp(with: try event(.leftMouseUp, point: destination, window: window))
        let expected = RecordingTransportPlacement.clamp(before.offsetBy(dx: 37, dy: -21), to: screen)
        try require(window.frame == expected && window.frame != before, "Grip drag did not move only the strip")
        let afterGrip = window.frame
        for button in [view.pauseButton, view.stopButton, view.expandButton] {
            try require(!button.mouseDownCanMoveWindow, "A button permits background window drag")
            button.mouseDragged(with: try event(.leftMouseDragged, point: destination, window: window))
            try require(window.frame == afterGrip, "A button drag moved the strip")
        }
        let edgeStart = window.convertPoint(toScreen: view.grip.convert(CGPoint(x: 10, y: 16), to: nil))
        view.grip.mouseDown(with: try event(.leftMouseDown, point: edgeStart, window: window))
        let edge = CGPoint(x: screen.maxX + 2_000, y: screen.minY - 2_000)
        view.grip.mouseDragged(with: try event(.leftMouseDragged, point: edge, window: window))
        view.grip.mouseUp(with: try event(.leftMouseUp, point: edge, window: window))
        try require(screen.contains(window.frame), "Edge drag escaped the chosen work area")
        let clipped = window.frame
        view.grip.mouseDown(with: try event(.leftMouseDown, point: edgeStart, window: window))
        controller.hide()
        view.grip.mouseDragged(with: try event(.leftMouseDragged, point: edge, window: window))
        try require(window.frame == clipped, "Hidden grip retained an in-flight drag")
        controller.show(snapshot: controller.snapshot, anchor: controller.anchor, visibleFrame: screen)
        return ["status": "passed", "visibleFrame": rect(screen), "before": rect(before),
                "afterGrip": rect(afterGrip), "afterClamp": rect(clipped),
                "buttonDragDidNotMove": true, "hideCancelledDrag": true, "regionMutationAvailable": false]
    }

    private static func event(_ type: NSEvent.EventType, point: CGPoint, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1) else { throw failure("Cannot construct local drag event") }
        return event
    }

    private static func capture(_ state: String, appearance: String, window: NSWindow, directory: URL) throws -> [String: Any] {
        guard let view = window.contentView as? RecordingTransportView else { throw failure("Missing native content") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let stem = "recording-transport-" + state + "-" + appearance
        let pngName = stem + ".png", geometryName = stem + "-geometry.json"
        let controls: [NSView] = [view.grip, view.elapsedLabel, view.statusLabel, view.pauseButton, view.stopButton, view.expandButton]
        let measurements: [[String: Any]] = controls.map {
            ["identifier": $0.identifier?.rawValue ?? "", "frame": rect($0.convert($0.bounds, to: view)),
             "hidden": $0.isHiddenOrHasHiddenAncestor]
        }
        // Persist raw frames and pixels before assertions, including on failure.
        let raw: [String: Any] = ["status": "measured-before-validation", "windowFrame": rect(window.frame),
            "contentBounds": rect(view.bounds), "coordinateSystem": "AppKit bottom-left", "controls": measurements]
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(geometryName), options: .atomic)
        try snapshot(view, to: directory.appendingPathComponent(pngName))
        var frames: [CGRect] = []
        for control in controls where !control.isHidden {
            let frame = control.convert(control.bounds, to: view)
            try require(frame.width > 0 && frame.height > 0 && view.bounds.contains(frame), "Control is clipped")
            try require(!frames.contains(where: { $0.intersects(frame) }), "Controls overlap")
            frames.append(frame)
            if control is NSButton || control is RecordingTransportGrip {
                let point = view.convert(CGPoint(x: frame.midX, y: frame.midY), to: view.superview)
                let hit = view.hitTest(point)
                try require(hit === control || hit?.isDescendant(of: control) == true, "Native hit test missed its control")
            }
        }
        for button in [view.pauseButton, view.stopButton, view.expandButton] {
            try require(button.image != nil && !(button.accessibilityLabel() ?? "").isEmpty && !(button.toolTip ?? "").isEmpty,
                        "Missing symbol, accessible label or tooltip")
        }
        try require(view.bounds.size == RecordingTransportPlacement.size, "Normal transport is not 300 × 40 points")
        return ["state": state, "file": pngName, "geometryFile": geometryName, "layoutStatus": "passed",
                "hitTestStatus": "passed", "pauseEnabled": view.pauseButton.isEnabled, "stopEnabled": view.stopButton.isEnabled]
    }

    private static func snapshot(_ view: NSView, to url: URL) throws {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        guard width > 0, width <= 300, height == 40,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32) else { throw failure("Cannot allocate bounded UI snapshot") }
        bitmap.size = view.bounds.size
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Cannot encode UI PNG") }
        try png.write(to: url, options: .atomic)
    }

    private static func verifyPlacement() throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for screen in [CGRect(x: 0, y: 24, width: 1_280, height: 776),
                       CGRect(x: -1_920, y: -480, width: 1_920, height: 1_056),
                       CGRect(x: -600, y: 900, width: 180, height: 400)] {
            for anchor in [screen, CGRect(x: screen.minX, y: screen.minY, width: 40, height: 40),
                           CGRect(x: screen.maxX - 10, y: screen.maxY - 10, width: 10, height: 10)] {
                let frame = RecordingTransportPlacement.initial(anchor: anchor, visibleFrame: screen)
                try require(screen.contains(frame), "Initial placement escaped its visible frame")
                let clamped = RecordingTransportPlacement.clamp(frame.offsetBy(dx: -10_000, dy: 10_000), to: screen)
                try require(screen.contains(clamped), "Negative-origin edge clamp escaped its visible frame")
                rows.append(["visibleFrame": rect(screen), "anchor": rect(anchor), "initial": rect(frame), "clamped": rect(clamped)])
            }
        }
        return rows
    }

    private static func observe(_ controller: RecordingTransportController, owner: ActionProbe, ownership: Ownership) {
        ownership.add(controller, "controller"); ownership.add(owner, "owner")
        if let window = controller.window { ownership.add(window, "window") }
        if let view = controller.window?.contentView as? RecordingTransportView {
            let views: [(String, NSView)] = [("surface", view), ("grip", view.grip), ("pause", view.pauseButton),
                                            ("stop", view.stopButton), ("expand", view.expandButton)]
            for (name, value) in views { ownership.add(value, name) }
        }
    }
    private static func verifyReleased(_ ownership: Ownership) async throws -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        while !ownership.retained.isEmpty && ProcessInfo.processInfo.systemUptime - start < 3 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try require(ownership.retained.isEmpty, "Retained transport objects: " + ownership.retained.joined(separator: ", "))
        let releaseMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        try require(releaseMilliseconds <= 3_000, "Transport retirement exceeded its three-second deadline")
        return ["status": "passed", "weakProbeCount": ownership.objects.count, "retainedObjects": 0,
                "releaseMilliseconds": releaseMilliseconds, "deadlineMilliseconds": 3_000]
    }
    private static func rect(_ value: CGRect) -> [String: CGFloat] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("recording-transport.json"), options: .atomic)
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Recording transport: " + message) }

    @MainActor private final class ActionProbe {
        weak var controller: RecordingTransportController?
        var pauseCalls = 0, stopCalls = 0, expandCalls = 0
        var actions: RecordingTransportActions {
            RecordingTransportActions(pauseResume: { self.pauseCalls += 1 }, stopSave: { self.stopCalls += 1 },
                expand: { self.expandCalls += 1; self.controller?.hide() })
        }
    }
    private final class Ownership {
        var objects: [WeakObject] = []
        func add(_ value: AnyObject, _ name: String) { objects.append(WeakObject(value, name: name)) }
        var retained: [String] { objects.filter { $0.value != nil }.map(\.name) }
    }
    private final class WeakObject {
        weak var value: AnyObject?
        let name: String
        init(_ value: AnyObject, name: String) { self.value = value; self.name = name }
    }
}
