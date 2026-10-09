import AppKit
import SwiftUI

/// Exercises production controls in owned native windows, with injected
/// permissions and an explicitly synthetic, unavailable capture target. This
/// fixture never starts recording, installs a monitor or asks the OS for access.
@MainActor
enum RecordingInputControlsPreviewFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var report: [String: Any] = ["status": "running", "contentWidthPoints": 440,
            "injectedPermissions": true, "recordingStarted": false, "screenCaptureStarted": false,
            "permissionRequested": false, "globalInputPosted": false, "nativeMonitorRegistrations": 0,
            "scope": "Owned native NSButton target/actions and NSView hit testing in isolated controls and the complete idle recording panel; synthetic target and injected permissions only",
            "interactionRoute": "NSButton.performClick", "hitTestRoute": "NSView.hitTest",
            "snapshotPixelsPerPoint": 1]
        do {
            var appearances: [[String: Any]] = []
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let ownership = OwnershipProbe()
                report["phase"] = "isolated-" + name
                var result = try await isolatedPreview(name: name, appearance: appearance,
                    directory: evidenceDirectory, ownership: ownership)
                let index = appearances.count
                result["appearanceStatus"] = "in-progress"
                appearances.append(result); report["appearances"] = appearances
                report["phase"] = "full-panel-" + name
                result["fullPanel"] = try await fullPanelPreview(name: name, appearance: appearance,
                    directory: evidenceDirectory, ownership: ownership)
                appearances[index] = result; report["appearances"] = appearances
                report["phase"] = "representable-lifecycle-" + name
                result["representableLifecycle"] = try await verifyRepresentableUpdates(appearance: appearance, ownership: ownership)
                appearances[index] = result; report["appearances"] = appearances
                report["phase"] = "ownership-" + name
                result["ownership"] = try await verifyReleased(ownership)
                result["appearanceStatus"] = "passed"
                appearances[index] = result; report["appearances"] = appearances
            }
            // Missing native controls, interaction, geometry or cleanup throw.
            // There is deliberately no layout-only or model-injection pass.
            report["status"] = "passed"
            report["phase"] = "complete"
            report["interactionStatus"] = "passed"
            try write(report, directory: evidenceDirectory)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? write(report, directory: evidenceDirectory)
            throw error
        }
    }

    private static func isolatedPreview(name: String, appearance: NSAppearance.Name, directory: URL,
                                        ownership: OwnershipProbe) async throws -> [String: Any] {
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
        ownership.observe(monitor, name: "isolated.monitor")
        ownership.observe(host, name: "isolated.host")
        defer { dispose(window); monitor.endSession() }
        window.center(); window.makeKeyAndOrderFront(nil)
        return try await exercise(window: window, monitor: monitor, probe: probe, name: name,
                                  prefix: "recording-input", directory: directory, ownership: ownership)
    }

    private static func fullPanelPreview(name: String, appearance: NSAppearance.Name, directory: URL,
                                         ownership: OwnershipProbe) async throws -> [String: Any] {
        let probe = PermissionProbe()
        var syntheticTargetChecks = 0
        let service = RecordingService(screenPermissionCheck: {
            syntheticTargetChecks += 1
            throw PicShotError.message("合成预览目标：未连接显示器，不会开始屏幕采集。")
        }, inputMonitorDependencies: probe.dependencies)
        var panelFrames: [String: CGRect] = [:]
        let controller = RecordingPanelController(service: service, capture: CaptureService(),
            previewLayoutObserver: { panelFrames = $0 })
        guard let window = controller.window else { throw failure("Missing complete recording panel") }
        window.title = "PicShot · Synthetic idle recording panel"
        window.appearance = NSAppearance(named: appearance)
        ownership.observe(service.inputMonitor, name: "fullPanel.monitor")
        if let host = window.contentView { ownership.observe(host, name: "fullPanel.host") }
        defer { dispose(window); service.inputMonitor.endSession() }
        controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        try await settle(window)
        try require(window.contentView?.bounds.size == CGSize(width: 480, height: 490),
                    "Complete idle recording panel changed its compact 480×490 content size")
        try require(syntheticTargetChecks == 1, "Complete panel did not stop at its injected synthetic display check")
        var result = try await exercise(window: window, monitor: service.inputMonitor, probe: probe,
                                       name: name, prefix: "recording-panel", directory: directory, ownership: ownership,
                                       panelGeometry: { try panelGeometry(panelFrames, in: window) })
        try require(!service.isRecording && !service.isStarting && !service.camera.requested &&
                    !service.overlay.drawing && !service.overlay.cameraEditing && syntheticTargetChecks == 1,
                    "Idle panel interaction changed camera/annotation state or attempted recording")
        result["contentWidthPoints"] = 480; result["contentHeightPoints"] = 490
        result["syntheticTarget"] = true; result["syntheticTargetChecks"] = syntheticTargetChecks
        result["cameraRequested"] = false; result["recordingStarted"] = false
        return result
    }

    private static func exercise(window: NSWindow, monitor: RecordingInputMonitor, probe: PermissionProbe,
                                 name: String, prefix: String, directory: URL,
                                 ownership: OwnershipProbe,
                                 panelGeometry: (() throws -> [[String: Any]])? = nil) async throws -> [String: Any] {
        try await settle(window)
        let initialOptions = RecordingInputEffectsOptions()
        try require(monitor.options == initialOptions && probe.permissionChecks == 0,
                    "Opening default-off controls inspected permissions or changed options")
        var files: [String] = []
        var geometryFiles: [String] = []
        var roundTrips: [[String: Any]] = []
        var phase = "default-off"
        var completed = false
        defer {
            if !completed {
                // Preserve the current owned window even if an intermediate
                // target/action or option assertion fails before the next state.
                try? snapshot(window, to: directory.appendingPathComponent("\(prefix)-failed-\(name).png"))
                try? writeGeometryMeasurements(["clicks", "scrolls", "shortcuts", "help", "status"].map { "recording-input-" + $0 },
                    in: window, phase: phase, to: directory.appendingPathComponent("\(prefix)-failed-\(name)-geometry.json"))
                let partial: [String: Any] = ["status": "failed-partial", "phase": phase,
                    "appearance": name, "context": prefix, "completedOptionActions": roundTrips,
                    "options": ["clicks": monitor.options.clicks, "scrolls": monitor.options.scrolls,
                                "shortcuts": monitor.options.shortcuts],
                    "savedSnapshots": files, "savedGeometry": geometryFiles,
                    "permissionChecks": probe.permissionChecks, "nativeMonitorRegistrations": probe.installCalls]
                try? JSONSerialization.data(withJSONObject: partial, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("\(prefix)-failed-\(name)-progress.json"), options: .atomic)
            }
        }
        var panelSectionGeometry: [String: Any] = [:]
        func save(_ state: String, window target: NSWindow? = nil) throws {
            let filename = "\(prefix)-\(state)-\(name).png"
            phase = state
            let measuredWindow = target ?? window
            // Capture real pixels and exact native rectangles before any
            // strict geometry assertion can abort this state.
            try snapshot(measuredWindow, to: directory.appendingPathComponent(filename))
            files.append(filename)
            let geometryFilename = "\(prefix)-\(state)-\(name)-geometry.json"
            let measuredIDs = target == nil ? ["clicks", "scrolls", "shortcuts", "help", "status"] : ["refresh"]
            try writeGeometryMeasurements(measuredIDs.map { "recording-input-" + $0 }, in: measuredWindow,
                phase: state, to: directory.appendingPathComponent(geometryFilename))
            geometryFiles.append(geometryFilename)
            if target == nil, let panelGeometry { panelSectionGeometry[state] = try panelGeometry() }
        }
        let identifiers = ["clicks", "scrolls", "shortcuts", "help"].map { "recording-input-" + $0 }
        var result: [String: Any] = ["appearance": name, "defaultOff": true, "initialPermissionChecks": 0,
                                   "interactionRoute": "NSButton.performClick", "hitTestRoute": "NSView.hitTest"]
        try save("default-off")
        result["defaultOffGeometry"] = try geometry(identifiers, in: window, hitTest: true)
        try require(nativeViews("recording-input-status", in: window).isEmpty, "Default-off status should be absent")
        for identifier in identifiers { try observeButton(identifier, in: window, prefix: prefix, ownership: ownership) }
        let toggles: [(String, WritableKeyPath<RecordingInputEffectsOptions, Bool>)] = [
            ("clicks", \.clicks), ("scrolls", \.scrolls), ("shortcuts", \.shortcuts)]
        func toggle(_ suffix: String, keyPath: WritableKeyPath<RecordingInputEffectsOptions, Bool>, enabled: Bool) async throws {
            phase = "toggle-\(suffix)-\(enabled)"
            var expected = monitor.options; expected[keyPath: keyPath] = enabled
            try press("recording-input-" + suffix, in: window)
            try await settle(window)
            try require(monitor.options == expected, "Native \(suffix) press did not update only its bound option")
            for (other, otherKeyPath) in toggles {
                let button = try button("recording-input-" + other, in: window)
                try require(button.state == (expected[keyPath: otherKeyPath] ? .on : .off),
                            "Native checkbox state did not follow its updated binding: " + other)
            }
            roundTrips.append(["control": suffix, "enabled": enabled,
                               "clicks": expected.clicks, "scrolls": expected.scrolls, "shortcuts": expected.shortcuts])
        }
        for (suffix, keyPath) in toggles {
            for enabled in [true, false, true] { try await toggle(suffix, keyPath: keyPath, enabled: enabled) }
        }
        try save("denied")
        result["deniedGeometry"] = try geometry(identifiers + ["recording-input-status"], in: window, hitTest: true)
        try require(monitor.permissions == .unknown, "Injected denied permission did not reach the controls")
        try require(try status(in: window).contains("输入监控"), "Denied controls omitted input-monitoring guidance")

        phase = "open-help"
        let help = try await openHelp(in: window)
        defer { dispose(help) }
        try observeButton("recording-input-refresh", in: help, prefix: prefix + ".help", ownership: ownership)
        try save("help-denied", window: help)
        result["helpGeometry"] = try geometry(["recording-input-refresh"], in: help, hitTest: true)
        let checksBeforeRefresh = probe.permissionChecks
        probe.permissions = .init(inputMonitoring: true, accessibility: true)
        try press("recording-input-refresh", in: help)
        try await settle(help); try await settle(window)
        try save("help-allowed", window: help)
        try require(probe.permissionChecks == checksBeforeRefresh + 1 && monitor.permissions == probe.permissions,
                    "Native refresh did not read the injected granted permission exactly once")
        try press("recording-input-help", in: window)
        try await settle(window)
        try require(!help.isVisible, "Native help toggle did not dismiss its popover")
        try save("allowed")
        result["allowedGeometry"] = try geometry(identifiers + ["recording-input-status"], in: window, hitTest: true)
        try require(try status(in: window).contains("开始 / 继续录制"), "Allowed idle controls omitted recording-lifecycle guidance")

        // Reopen the same production help path and verify refresh can revoke
        // permissions too. No model option assignment substitutes for a click.
        phase = "reopen-help"
        let reopenedHelp = try await openHelp(in: window, previouslyOwned: help)
        defer { if reopenedHelp !== help { dispose(reopenedHelp) } }
        try observeButton("recording-input-refresh", in: reopenedHelp, prefix: prefix + ".reopenedHelp", ownership: ownership)
        let checksBeforeDeniedRefresh = probe.permissionChecks
        probe.permissions = .unknown
        try press("recording-input-refresh", in: reopenedHelp)
        try await settle(reopenedHelp); try await settle(window)
        try require(probe.permissionChecks == checksBeforeDeniedRefresh + 1 && monitor.permissions == .unknown,
                    "Reopened native refresh did not read the injected denial exactly once")
        try require(try status(in: window).contains("输入监控"), "Revoked permission did not update the native status")
        try press("recording-input-help", in: window)
        try await settle(window)
        try require(!reopenedHelp.isVisible, "Reopened help did not dismiss")
        for (suffix, keyPath) in toggles { try await toggle(suffix, keyPath: keyPath, enabled: false) }
        try require(monitor.options == initialOptions && nativeViews("recording-input-status", in: window).isEmpty,
                    "Native option round trip failed to restore the default-off controls")
        try save("restored-off")
        result["restoredOffGeometry"] = try geometry(identifiers, in: window, hitTest: true)
        try require(!monitor.isMonitoring && probe.installCalls == 0 && probe.removeCalls == 0 &&
                    probe.healthChecks == 0 && probe.focusChecks == 0 && probe.secureInputChecks == 0,
                    "Idle input controls attempted live monitoring or focus inspection")
        result["status"] = "passed"; result["interactionStatus"] = "passed"; result["layoutStatus"] = "passed"
        result["nativeTogglePresses"] = roundTrips.count; result["optionRoundTrips"] = roundTrips
        result["finalOptionsMatchInitial"] = true
        result["helpAndRefreshVerified"] = true; result["nativeHelpPresses"] = 4; result["nativeRefreshPresses"] = 2
        result["files"] = files; result["geometryFiles"] = geometryFiles
        result["injectedPermissionChecks"] = probe.permissionChecks
        result["nativeMonitorRegistrations"] = 0
        if !panelSectionGeometry.isEmpty { result["panelSectionGeometry"] = panelSectionGeometry }
        completed = true
        return result
    }

    private static func openHelp(in window: NSWindow, previouslyOwned: NSWindow? = nil) async throws -> NSWindow {
        let previousWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        try press("recording-input-help", in: window)
        try await settle(window)
        // Only windows created by this exact owned action, attached to our
        // owned window, or previously verified as this fixture's help qualify.
        // A reused popover need not reappear as a new NSApp window.
        let candidates = NSApp.windows.filter { !previousWindows.contains(ObjectIdentifier($0)) } +
            (window.childWindows ?? []) + [previouslyOwned].compactMap { $0 }
        guard let help = candidates.first(where: { $0.isVisible && !nativeViews("recording-input-refresh", in: $0).isEmpty }) else {
            throw failure("Native help action did not expose its owned refresh button")
        }
        try await settle(help)
        return help
    }

    /// Traverse actual NSViews only, scoped to our own content. These stable
    /// identifiers belong to the production input controls, not SwiftUI classes.
    private static func nativeViews(_ identifier: String, in window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        var pending = [root], result: [NSView] = []
        while let view = pending.popLast() {
            if view.identifier?.rawValue == identifier { result.append(view) }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    private static func nativeView(_ identifier: String, in window: NSWindow) throws -> NSView {
        let matches = nativeViews(identifier, in: window)
        guard matches.count == 1, let view = matches.first,
              view.accessibilityIdentifier() == identifier else {
            throw failure("Expected exactly one identified native control: " + identifier)
        }
        return view
    }

    private static func button(_ identifier: String, in window: NSWindow) throws -> NSButton {
        guard let button = try nativeView(identifier, in: window) as? NSButton,
              button.isEnabled, !button.isHiddenOrHasHiddenAncestor, button.target != nil, button.action != nil else {
            throw failure("Missing enabled native target/action button: " + identifier)
        }
        return button
    }

    private static func press(_ identifier: String, in window: NSWindow) throws {
        _ = try geometry([identifier], in: window, hitTest: true)
        try button(identifier, in: window).performClick(nil)
    }

    private static func status(in window: NSWindow) throws -> String {
        guard let label = try nativeView("recording-input-status", in: window) as? NSTextField else {
            throw failure("Missing native input status label")
        }
        return label.stringValue
    }

    private static func observeButton(_ identifier: String, in window: NSWindow, prefix: String,
                                      ownership: OwnershipProbe) throws {
        let control = try button(identifier, in: window)
        ownership.observe(control, name: prefix + "." + identifier)
        if let target = control.target { ownership.observe(target as AnyObject, name: prefix + "." + identifier + ".coordinator") }
    }

    /// Bounded observations of the named native controls only. These are raw
    /// measurements, not a pass; complete view frames remain the strict gate.
    private static func writeGeometryMeasurements(_ identifiers: [String], in window: NSWindow,
                                                   phase: String, to url: URL) throws {
        guard let root = window.contentView else { throw failure("Missing geometry snapshot content") }
        var rows: [[String: Any]] = []
        var measuredFrames: [(String, CGRect)] = []
        for identifier in identifiers {
            let matches = nativeViews(identifier, in: window)
            var views: [[String: Any]] = []
            for view in matches.prefix(2) {
                let frame = topLeftFrame(view.convert(view.bounds, to: root), in: root)
                let alignment = view.alignmentRect(forFrame: view.frame)
                let alignmentInRoot = view.superview?.convert(alignment, to: root) ?? alignment
                let insets = view.alignmentRectInsets
                var row: [String: Any] = ["frame": measuredRect(frame),
                    "alignmentFrame": measuredRect(topLeftFrame(alignmentInRoot, in: root)),
                    "alignmentInsets": ["top": measuredScalar(insets.top), "left": measuredScalar(insets.left),
                                        "bottom": measuredScalar(insets.bottom), "right": measuredScalar(insets.right)],
                    "intrinsicSize": ["width": measuredScalar(view.intrinsicContentSize.width),
                                      "height": measuredScalar(view.intrinsicContentSize.height)],
                    "hidden": view.isHiddenOrHasHiddenAncestor]
                if let control = view as? NSControl, let cell = control.cell {
                    row["cellDrawingFrame"] = measuredRect(topLeftFrame(view.convert(cell.drawingRect(forBounds: view.bounds), to: root), in: root))
                }
                if let button = view as? NSButton { row["enabled"] = button.isEnabled; row["state"] = button.state.rawValue }
                views.append(row); measuredFrames.append((identifier, frame))
            }
            rows.append(["identifier": identifier, "matchCount": matches.count, "views": views])
        }
        var intersections: [[String: Any]] = []
        for index in measuredFrames.indices {
            for other in measuredFrames.indices where other > index {
                let overlap = measuredFrames[index].1.intersection(measuredFrames[other].1)
                if !overlap.isNull && overlap.width > 0 && overlap.height > 0 {
                    intersections.append(["first": measuredFrames[index].0, "second": measuredFrames[other].0,
                                          "intersection": measuredRect(overlap)])
                }
            }
        }
        let measurement: [String: Any] = ["status": "measured-before-validation", "phase": phase,
            "coordinateSystem": "top-left", "contentBounds": measuredRect(CGRect(origin: .zero, size: root.bounds.size)),
            "controls": rows, "intersections": intersections]
        try JSONSerialization.data(withJSONObject: measurement, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private static func measuredScalar(_ value: CGFloat) -> Any {
        value.isFinite ? Double(value) as Any : String(describing: value) as Any
    }

    private static func measuredRect(_ rect: CGRect) -> [String: Any] {
        ["x": measuredScalar(rect.minX), "y": measuredScalar(rect.minY),
         "width": measuredScalar(rect.width), "height": measuredScalar(rect.height)]
    }

    private static func geometry(_ identifiers: [String], in window: NSWindow, hitTest: Bool) throws -> [[String: Any]] {
        guard let root = window.contentView else { throw failure("Missing native content view") }
        var frames: [CGRect] = [], output: [[String: Any]] = []
        for identifier in identifiers {
            let view = try nativeView(identifier, in: window)
            let frame = view.convert(view.bounds, to: root)
            try require(!frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0 &&
                        root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) && !view.isHiddenOrHasHiddenAncestor,
                        "Control is clipped or outside native content: " + identifier)
            try require(!frames.contains { other in
                let overlap = other.intersection(frame)
                return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
            }, "Native control frames overlap: " + identifier)
            let verifiesHitTarget = hitTest && view is NSButton
            if verifiesHitTarget {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let hit = root.hitTest(root.convert(center, to: root.superview))
                try require(hit === view || hit?.isDescendant(of: view) == true,
                            "Native hit target did not reach the visible control: " + identifier)
            }
            frames.append(frame)
            let contentFrame = topLeftFrame(frame, in: root)
            output.append(["identifier": identifier, "x": contentFrame.minX, "y": contentFrame.minY,
                           "width": frame.width, "height": frame.height, "insideContent": true,
                           "nonoverlapping": true, "nativeHitTargetVerified": verifiesHitTarget,
                           "accessibilityIdentifierVerified": true])
        }
        return output
    }

    private static func topLeftFrame(_ frame: CGRect, in root: NSView) -> CGRect {
        CGRect(x: frame.minX - root.bounds.minX,
               y: root.isFlipped ? frame.minY - root.bounds.minY : root.bounds.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    private static func panelGeometry(_ frames: [String: CGRect], in window: NSWindow) throws -> [[String: Any]] {
        guard let root = window.contentView else { throw failure("Missing full panel content") }
        let names = ["options", "start", "divider", "effects", "status", "previewHint", "privacyHint"]
        try require(Set(frames.keys) == Set(names), "Complete panel did not report all seven idle sections")
        let bounds = CGRect(origin: .zero, size: CGSize(width: 480, height: 490))
        var previous: [CGRect] = [], output: [[String: Any]] = []
        for name in names {
            guard let frame = frames[name] else { throw failure("Missing panel section: " + name) }
            try require(!frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0 &&
                        bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Panel section is clipped: " + name)
            try require(!previous.contains { other in
                let overlap = frame.intersection(other)
                return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
            }, "Panel sections overlap: " + name)
            if let last = previous.last { try require(frame.minY >= last.maxY - 0.5, "Panel section order changed: " + name) }
            previous.append(frame)
            output.append(["section": name, "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                           "insideContent": true, "nonoverlapping": true, "coordinateSystem": "top-left"])
        }
        guard let effects = frames["effects"] else { throw failure("Missing effects section") }
        for identifier in ["clicks", "scrolls", "shortcuts", "help", "status"].map({ "recording-input-" + $0 }) {
            for view in nativeViews(identifier, in: window) {
                let frame = topLeftFrame(view.convert(view.bounds, to: root), in: root)
                try require(effects.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                            "Input control escaped the panel's effects section: " + identifier)
            }
        }
        return output
    }

    private static func verifyRepresentableUpdates(appearance: NSAppearance.Name,
                                                   ownership: OwnershipProbe) async throws -> [String: Any] {
        final class Value { var enabled = false }
        let first = Value(), second = Value()
        func checkbox(_ value: Value) -> RecordingInputCheckbox {
            RecordingInputCheckbox(title: "点击", identifier: "recording-input-lifecycle-checkbox",
                                   isOn: Binding(get: { value.enabled }, set: { value.enabled = $0 }))
        }
        let checkboxHost = NSHostingView(rootView: checkbox(first))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "PicShot · Synthetic control lifecycle"
        window.appearance = NSAppearance(named: appearance)
        window.contentView = checkboxHost
        window.center(); window.orderFront(nil)
        defer { dispose(window) }
        ownership.observe(checkboxHost, name: "lifecycle.checkboxHost")
        try await settle(window)
        try observeButton("recording-input-lifecycle-checkbox", in: window, prefix: "lifecycle", ownership: ownership)
        let checkboxIdentity = try controlIdentity(button("recording-input-lifecycle-checkbox", in: window))
        try press("recording-input-lifecycle-checkbox", in: window)
        try require(first.enabled, "Native lifecycle checkbox did not update its initial binding")
        checkboxHost.rootView = checkbox(second)
        try await settle(window)
        try require(try controlIdentity(button("recording-input-lifecycle-checkbox", in: window)) == checkboxIdentity,
                    "Checkbox or coordinator was recreated instead of updating its binding")
        try require(try button("recording-input-lifecycle-checkbox", in: window).state == .off,
                    "Reused checkbox did not reflect its replacement binding")
        try press("recording-input-lifecycle-checkbox", in: window)
        try require(first.enabled && second.enabled, "Reused checkbox retained a stale binding")
        second.enabled = false
        checkboxHost.rootView = checkbox(second)
        try await settle(window)
        try require(try controlIdentity(button("recording-input-lifecycle-checkbox", in: window)) == checkboxIdentity,
                    "Checkbox or coordinator was recreated instead of updating external state")
        try require(try button("recording-input-lifecycle-checkbox", in: window).state == .off && first.enabled,
                    "External binding update did not reach the native checkbox")

        var firstCalls = 0, secondCalls = 0
        let actionHost = NSHostingView(rootView: RecordingInputActionButton(title: "重新检查", identifier: "recording-input-lifecycle-action") {
            firstCalls += 1
        }.disabled(false))
        window.contentView = actionHost
        ownership.observe(actionHost, name: "lifecycle.actionHost")
        try await settle(window)
        try observeButton("recording-input-lifecycle-action", in: window, prefix: "lifecycle", ownership: ownership)
        let actionIdentity = try controlIdentity(button("recording-input-lifecycle-action", in: window))
        try press("recording-input-lifecycle-action", in: window)
        try require(firstCalls == 1, "Initial native lifecycle action did not run")
        actionHost.rootView = RecordingInputActionButton(title: "更新检查", identifier: "recording-input-lifecycle-action") {
            secondCalls += 1
        }.disabled(true)
        try await settle(window)
        guard let disabled = try nativeView("recording-input-lifecycle-action", in: window) as? NSButton else {
            throw failure("Missing disabled native lifecycle button")
        }
        try require(try controlIdentity(disabled) == actionIdentity,
                    "Action button or coordinator was recreated instead of updating disable state")
        try require(!disabled.isEnabled && disabled.title == "更新检查", "Native action ignored its updated title or inherited disable")
        disabled.performClick(nil)
        try require(firstCalls == 1 && secondCalls == 0, "Disabled native action ran a callback")
        actionHost.rootView = RecordingInputActionButton(title: "更新检查", identifier: "recording-input-lifecycle-action") {
            secondCalls += 1
        }.disabled(false)
        try await settle(window)
        try require(try controlIdentity(button("recording-input-lifecycle-action", in: window)) == actionIdentity,
                    "Action button or coordinator was recreated instead of updating its closure")
        try press("recording-input-lifecycle-action", in: window)
        try require(firstCalls == 1 && secondCalls == 1, "Reused native action retained a stale closure")
        return ["status": "passed", "replacementBindingVerified": true, "externalStateVerified": true,
                "replacementActionVerified": true, "inheritedDisableVerified": true,
                "nativeControlAndCoordinatorReuseVerified": true]
    }

    private static func controlIdentity(_ button: NSButton) throws -> [ObjectIdentifier] {
        guard let target = button.target else { throw failure("Native lifecycle button has no coordinator") }
        return [ObjectIdentifier(button), ObjectIdentifier(target as AnyObject)]
    }

    private static func dispose(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private static func verifyReleased(_ ownership: OwnershipProbe) async throws -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + 3
        while !ownership.retained.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(ownership.retained.isEmpty, "Fixture retained native ownership after detach/close: " + ownership.retained.joined(separator: ", "))
        return ["status": "passed", "weakProbeCount": ownership.objects.count, "retainedObjects": 0,
                "releaseMilliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1_000,
                "deadlineMilliseconds": 3_000]
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

    @MainActor private final class OwnershipProbe {
        var objects: [WeakObject] = []
        func observe(_ value: AnyObject, name: String) { objects.append(WeakObject(value, name: name)) }
        var retained: [String] { objects.filter { $0.value != nil }.map(\.name) }
    }
    private final class WeakObject {
        weak var value: AnyObject?
        let name: String
        init(_ value: AnyObject, name: String) { self.value = value; self.name = name }
    }

    @MainActor private final class PermissionProbe {
        var permissions = RecordingInputPermissions.unknown
        var permissionChecks = 0, installCalls = 0, removeCalls = 0, healthChecks = 0
        var secureInputChecks = 0, focusChecks = 0
        var dependencies: RecordingInputMonitorDependencies {
            .init(permissions: { self.permissionChecks += 1; return self.permissions },
                  secureInputEnabled: { self.secureInputChecks += 1; return false },
                  focusedContext: { self.focusChecks += 1; return .ordinary },
                  install: { _, _ in self.installCalls += 1; return nil }, remove: { _ in self.removeCalls += 1 },
                  scheduleHealthCheck: { _ in self.healthChecks += 1; return {} }, clock: { 100 })
        }
    }
}
