import AppKit
import CryptoKit
import ImageIO
import PicShotCore

/// Installed-app acceptance for appearance defaults and canvas-only shortcuts.
/// All input, text, windows, images and preferences are owned synthetic fixtures.
@MainActor enum AnnotationPreferencesUIPreviewFixture {
    static let checks: Set<String> = ["native-local-tools-panel", "remap-duplicate-reserved", "clear-reset-cancel-save",
        "immutable-editor-map", "canvas-field-ime-focus", "same-tool-color-preview", "old-import-preserves-sections",
        "import-cancel-preserves-draft", "import-write-rollback", "native-style-menu", "future-marks-only",
        "reopened-render-export", "reset-render-export", "light-dark-hit-layout", "owned-cleanup"]

    @discardableResult static func run(reportURL: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let directory = reportURL.deletingLastPathComponent(), start = Date()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PicShot-AnnotationPreferences-" + UUID().uuidString
        let defaults = try required(UserDefaults(suiteName: suite), "Isolated suite unavailable")
        let priorAppearance = NSApp.appearance
        var owners: [WeakOwner] = [], visuals: [[String: Any]] = [], events: [[String: Any]] = [], menus: [[String: Any]] = []
        var report: [String: Any] = ["schemaVersion": 1, "status": "running", "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "userPreferencesReadOrWritten": false, "globalInputPosted": false, "globalHotkeysRegistered": false,
            "permissionRequests": false, "networkUsed": false, "liveScreenCaptured": false, "ordinaryTextCaptured": false,
            "overallDeadlineSeconds": 120, "maximumRasterPixels": 4_000_000,
            "scope": "Owned AppKit events and cached content views; isolated defaults; synthetic 640x360 images",
            "memoryStabilityAssessed": false]
        defer { defaults.removePersistentDomain(forName: suite); NSApp.appearance = priorAppearance }
        do {
            report["executableSHA256"] = hash(try Data(contentsOf: required(Bundle.main.executableURL, "Executable URL absent")))
            report["infoPlistSHA256"] = hash(try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")))
            var settings: [[String: Any]] = [], imports: [[String: Any]] = [], styles: [[String: Any]] = []
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                defaults.removePersistentDomain(forName: suite)
                settings.append(try await settingsFlow(defaults, suite, mode, appearance, directory, &owners, &visuals, &events))
                imports.append(try await importFlow(defaults, suite, mode, appearance, directory, &owners, &visuals))
                defaults.removePersistentDomain(forName: suite)
                styles.append(try await styleFlow(defaults, mode, appearance, directory, &owners, &visuals, &menus))
                try require(Date().timeIntervalSince(start) < 120, "Fixture deadline exceeded")
                report["settings"] = settings; report["imports"] = imports; report["styles"] = styles
            }
            try await until({ owners.allSatisfy(\.released) }, "Owned controller/window/content retained after close")
            report["ownership"] = ["controllerCount": owners.count, "retainedControllers": owners.filter { $0.controller != nil }.count,
                "retainedWindows": owners.filter { $0.window != nil }.count, "retainedContentViews": owners.filter { $0.content != nil }.count,
                "releaseDeadlineSeconds": 4, "allOwnedWindowsClosed": true]
            report["checks"] = checks.sorted(); report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            // Save the failing owned view before close tears it down. No live-screen API.
            for (index, owner) in owners.enumerated() where owner.window?.isVisible == true {
                if let window = owner.window { _ = try? snapshot(window, "failure-\(index)", mode: "failure", directory: directory, controls: []) }
                owner.controller?.close()
            }
        }
        report["visuals"] = visuals; report["keyEvents"] = events; report["menuEvents"] = menus
        report["elapsedSeconds"] = Date().timeIntervalSince(start)
        let expectedRasters = ["default", "reopened", "reset"].flatMap { name in ["light", "dark"].map { "annotation-preferences-\(name)-\($0).png" } }
        let names = visuals.compactMap { $0["file"] as? String } + expectedRasters.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        report["fileSHA256"] = try Dictionary(uniqueKeysWithValues: names.map { ($0, hash(try Data(contentsOf: directory.appendingPathComponent($0)))) })
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try require(encoded.count <= 262_144, "Report exceeded 256 KiB")
        try encoded.write(to: reportURL, options: .atomic)
        if report["status"] as? String != "passed" { throw failure(report["error"] as? String ?? "Fixture failed") }
        return report
    }

    private static func settingsFlow(_ defaults: UserDefaults, _ suite: String, _ mode: String, _ appearance: NSAppearance.Name,
        _ directory: URL, _ owners: inout [WeakOwner], _ visuals: inout [[String: Any]], _ events: inout [[String: Any]]) async throws -> [String: Any] {
        let original = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
        try original.write(to: defaults)
        var completed = false
        let first = try editor(defaults, appearance, &owners); defer { close(first, completed, "settings-editor-" + mode, directory) }
        var callbacks = 0
        let controller = SettingsController(onChange: { callbacks += 1 }, defaults: defaults, isSmoke: false, defaultsDomainName: suite)
        owners.append(WeakOwner(controller)); defer { close(controller, completed, "settings-" + mode, directory) }
        let window = try PortableSettingsUIPreviewFixture.show(controller, appearance: appearance)
        try PortableSettingsUIPreviewFixture.select(.localTools, in: controller)
        let view = controller.localAnnotationShortcutsView
        let row = try required(ImageEditorTool.allCases.firstIndex(of: .rectangle), "Rectangle row absent")
        var selection = try PortableSettingsUIPreviewFixture.clickRow(row, in: view.tableView, failureEvidenceDirectory: directory)
        selection["appearance"] = mode
        func capture(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws {
            try PortableSettingsUIPreviewFixture.click(view.captureButton)
            try require(view.captureButton.isRecording && window.firstResponder === view.captureButton, "Recorder did not own first responder")
            events.append(try key(window, code, text, flags, purpose: "recorder-" + mode))
        }
        try capture(11, "b")
        try require(view.draft[.rectangle] == .init(keyCode: 11) && LocalAnnotationShortcutSettings.read(from: defaults) == original, "Remap escaped draft")
        let ellipse = try required(ImageEditorTool.allCases.firstIndex(of: .ellipse), "Ellipse row absent")
        _ = try PortableSettingsUIPreviewFixture.clickRow(ellipse, in: view.tableView, failureEvidenceDirectory: directory)
        let before = view.draft
        try capture(11, "b")
        try require(view.draft == before && view.captureButton.isRecording && view.statusLabel.stringValue.contains("已分配"), "Duplicate was accepted or undisclosed")
        for (code, text, flags) in [(UInt16(0), "a", NSEvent.ModifierFlags()), (36, "\r", []), (8, "c", .command)] {
            events.append(try key(window, code, text, flags, purpose: "reserved-" + mode))
            try require(view.draft == before && view.captureButton.isRecording && window.isVisible, "Reserved key changed draft or closed settings")
        }
        events.append(try key(window, 53, "\u{1b}", purpose: "cancel-recording-" + mode))
        try require(!view.captureButton.isRecording && view.draft == before, "Escape failed to cancel recording")
        try capture(15, "R", .shift); try require(view.draft[.ellipse] == .init(keyCode: 15, modifiers: 1), "Shift binding missing")
        try PortableSettingsUIPreviewFixture.click(view.clearButton); try require(view.draft[.ellipse] == nil, "Clear failed")
        try PortableSettingsUIPreviewFixture.click(view.restoreDefaultsButton); try require(view.draft == .defaults, "Reset failed")
        _ = try PortableSettingsUIPreviewFixture.clickRow(row, in: view.tableView, failureEvidenceDirectory: directory)
        try capture(11, "b")
        visuals.append(try snapshot(window, "shortcuts", mode: mode, directory: directory))
        try PortableSettingsUIPreviewFixture.click(try control("settings.cancel", window))
        try require(LocalAnnotationShortcutSettings.read(from: defaults) == original && callbacks == 0 && !window.isVisible, "Settings Cancel saved a draft")
        let saved = SettingsController(onChange: { callbacks += 1 }, defaults: defaults, isSmoke: false, defaultsDomainName: suite)
        owners.append(WeakOwner(saved)); defer { close(saved, completed, "settings-save-" + mode, directory) }
        let savedWindow = try PortableSettingsUIPreviewFixture.show(saved, appearance: appearance)
        try PortableSettingsUIPreviewFixture.select(.localTools, in: saved)
        _ = try PortableSettingsUIPreviewFixture.clickRow(row, in: saved.localAnnotationShortcutsView.tableView, failureEvidenceDirectory: directory)
        try PortableSettingsUIPreviewFixture.click(saved.localAnnotationShortcutsView.captureButton)
        events.append(try key(savedWindow, 11, "b", purpose: "save-remap-" + mode))
        try PortableSettingsUIPreviewFixture.click(try control("settings.save", savedWindow))
        try require(callbacks == 1 && !savedWindow.isVisible && LocalAnnotationShortcutSettings.read(from: defaults)[.rectangle] == .init(keyCode: 11), "Save did not persist exactly once")
        try show(try required(first.window, "First editor absent")); first.window?.makeFirstResponder(first.annotationCanvas)
        events.append(try key(first.window!, 15, "r", purpose: "old-map-" + mode))
        try require(first.localShortcuts == original && first.annotationCanvas.tool == .rectangle, "Open editor map mutated")
        let next = try editor(defaults, appearance, &owners); defer { close(next, completed, "focus-" + mode, directory) }
        let nextWindow = try required(next.window, "Next editor absent"), canvas = next.annotationCanvas
        events.append(try key(nextWindow, 15, "r", purpose: "removed-map-" + mode)); try require(canvas.tool == .arrow, "Next editor kept removed binding")
        events.append(try key(nextWindow, 11, "b", purpose: "new-map-" + mode)); try require(canvas.tool == .rectangle, "Next editor missed saved binding")
        try choose(.arrow, next)
        let field = NSTextField(frame: CGRect(x: 20, y: 20, width: 150, height: 24)); nextWindow.contentView?.addSubview(field)
        try require(nextWindow.makeFirstResponder(field), "Field focus failed")
        let text = try required(nextWindow.firstResponder as? NSTextView, "Native field editor absent")
        events.append(try key(nextWindow, 11, "b", purpose: "field-focus-" + mode))
        try require(text.isFieldEditor && text.string == "b" && canvas.tool == .arrow, "Typing routed to a canvas tool")
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try require(text.hasMarkedText(), "Synthetic IME marked text absent")
        events.append(try key(nextWindow, 11, "b", purpose: "ime-focus-" + mode))
        try require(canvas.tool == .arrow && canvas.annotations.isEmpty, "IME input changed canvas")
        text.unmarkText(); nextWindow.makeFirstResponder(canvas); field.removeFromSuperview()
        completed = true
        return ["appearance": mode, "rowSelection": selection, "remap": true, "duplicateRejected": true, "reservedRejected": true,
            "clearReset": true, "cancelPreserved": true, "saveCallbacks": callbacks, "immutableOldEditor": true,
            "newEditorMap": true, "fieldTypingPreserved": true, "markedIMEPreserved": true]
    }

    private static func importFlow(_ defaults: UserDefaults, _ suite: String, _ mode: String, _ appearance: NSAppearance.Name,
        _ directory: URL, _ owners: inout [WeakOwner], _ visuals: inout [[String: Any]]) async throws -> [String: Any] {
        var old = AnnotationStyleAdapter.original(tool: .rectangle, captureTimestampKnown: true)
        old.color = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let store = AnnotationStylePresetStore(defaults: defaults); try store.save(old)
        let baseline = try PortableSettingsStore(defaults: defaults, persistentDomainName: suite).exportData()
        var blue = old; blue.color = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1); try store.save(blue)
        try LocalAnnotationShortcutSettings.defaults.replacing(.ellipse, with: .init(keyCode: 15)).write(to: defaults)
        let incoming = try PortableSettingsStore(defaults: defaults).exportData()
        let reset = PortableSettingsStore(defaults: defaults, persistentDomainName: suite); try reset.apply(reset.prepareImport(baseline))
        var callbacks = 0, writes = 0
        let controller = SettingsController(onChange: { callbacks += 1 }, defaults: defaults, isSmoke: false, defaultsDomainName: suite)
        var completed = false
        owners.append(WeakOwner(controller)); defer { close(controller, completed, "import-" + mode, directory) }
        let window = try PortableSettingsUIPreviewFixture.show(controller, appearance: appearance)
        // A pre-existing local draft must survive both import cancellation and failure.
        let draft = try controller.localAnnotationShortcutsView.draft.replacing(.rectangle, with: .init(keyCode: 17))
        controller.localAnnotationShortcutsView.apply(settings: draft)
        try PortableSettingsUIPreviewFixture.select(.configuration, in: controller)
        let before = domain(defaults, suite)
        let review = try controller.reviewPortableSettingsImport(incoming); owners.append(WeakOwner(review))
        try await until({ window.attachedSheet === review.window }, "Import sheet absent")
        review.window?.appearance = NSAppearance(named: appearance)
        let change = try required(review.plan.changes.first { $0.id == "annotationStyle.rectangle" }, "Same-tool color change omitted")
        try require(change.oldValue != change.newValue && change.oldValue.contains("FF0000") && change.newValue.contains("0000FF"), "Preview hides color details")
        try require(domain(defaults, suite).isEqual(before) && callbacks == 0, "Opening preview wrote preferences")
        var visual = try snapshot(try required(review.window, "Review window absent"), "import", mode: mode, directory: directory)
        visual["openingReview"] = try PortableSettingsUIPreviewFixture.reviewOpeningLayout(review)
        visuals.append(visual)
        try PortableSettingsUIPreviewFixture.click(review.cancelButton)
        try await until({ window.attachedSheet == nil }, "Cancelled import sheet retained")
        try require(domain(defaults, suite).isEqual(before) && controller.localAnnotationShortcutsView.draft == draft, "Import Cancel changed draft")
        let rejected = try controller.reviewPortableSettingsImport(incoming); owners.append(WeakOwner(rejected))
        controller.portableSettingsStore.afterWrite = { index in writes += 1; if index == 1 { throw failure("Injected annotation preference write failure") } }
        try PortableSettingsUIPreviewFixture.click(rejected.applyButton)
        try require(writes == 2 && domain(defaults, suite).isEqual(before) && callbacks == 0 && !rejected.errorLabel.stringValue.isEmpty,
            "Rollback failed to restore both preference sections")
        try require(controller.localAnnotationShortcutsView.draft == draft && window.attachedSheet === rejected.window, "Rejected import discarded draft/review")
        try PortableSettingsUIPreviewFixture.click(rejected.cancelButton)
        try await until({ window.attachedSheet == nil }, "Rejected import did not cancel")
        var legacy = try required(JSONSerialization.jsonObject(with: baseline) as? [String: Any], "Legacy seed invalid")
        legacy.removeValue(forKey: "annotationStyles"); legacy.removeValue(forKey: "annotationShortcuts")
        let compatible = try controller.portableSettingsStore.prepareImport(JSONSerialization.data(withJSONObject: legacy))
        try require(!compatible.hasChanges, "Old settings would clear the new sections")
        controller.portableSettingsStore.afterWrite = nil; try controller.portableSettingsStore.apply(compatible)
        try require(domain(defaults, suite).isEqual(before), "Old settings cleared saved sections")
        completed = true
        return ["appearance": mode, "oldValue": change.oldValue, "newValue": change.newValue, "colorDetailVisible": true,
            "previewReadOnly": true, "cancelPreservedDraft": true, "rollbackPreservedDraft": true, "rollbackWriteCount": writes,
            "rollbackErrorVisible": true, "oldMissingSectionsPreserved": true, "callbacks": callbacks]
    }

    private static func styleFlow(_ defaults: UserDefaults, _ mode: String, _ appearance: NSAppearance.Name, _ directory: URL,
        _ owners: inout [WeakOwner], _ visuals: inout [[String: Any]], _ menus: inout [[String: Any]]) async throws -> [String: Any] {
        var completed = false
        let first = try editor(defaults, appearance, &owners); defer { close(first, completed, "styles-" + mode, directory) }
        try choose(.rectangle, first); try draw(first, from: CGPoint(x: 70, y: 70), to: CGPoint(x: 210, y: 160))
        let base = try rendered(first), original = try digest(base)
        try base.writePNG(to: directory.appendingPathComponent("annotation-preferences-default-\(mode).png"))
        let old = try required(first.annotationCanvas.annotations.first, "Default mark absent")
        try PortableSettingsUIPreviewFixture.click(try control("annotation.swatch.4", first.window!))
        menus.append(try popup(try control("annotation.lineWidth", first.window!), title: "10", mode: mode))
        menus.append(try popup(try control("annotation.savedStyles", first.window!), id: "annotation.savedStyles.save", mode: mode))
        let saved = try required(AnnotationStyleSettings.read(from: defaults).style(for: .rectangle), "Native menu failed to save style")
        try require(saved.values[.lineWidth] == .number(10) && first.annotationCanvas.hasSavedStyle(for: .rectangle), "Native saved style wrong")
        try PortableSettingsUIPreviewFixture.click(try control("annotation.swatch.1", first.window!))
        menus.append(try popup(try control("annotation.savedStyles", first.window!), id: "annotation.savedStyles.restore", mode: mode))
        try require(try AnnotationStyleAdapter.capture(first.annotationCanvas.style) == saved, "Restore did not restore future style")
        try require(first.annotationCanvas.annotations.first?.id == old.id && (try digest(rendered(first))) == original, "Style preferences edited an existing mark")
        var visual = try snapshot(first.window!, "styles", mode: mode, directory: directory,
            controls: descendants(first.window!.contentView).compactMap { $0 as? NSControl }.filter { $0.identifier?.rawValue.hasPrefix("annotation.") == true && !$0.isHiddenOrHasHiddenAncestor })
        let bounds = try required(first.window?.contentView?.bounds, "Editor content absent")
        try require(first.contextualPaletteVisible && bounds.contains(first.contextualPaletteFrame) && bounds.contains(first.floatingToolbarFrame)
            && !first.contextualPaletteFrame.intersects(first.floatingToolbarFrame), "Compact style palette overlaps toolbar or leaves workspace")
        visual["paletteFrame"] = rect(first.contextualPaletteFrame); visual["toolbarFrame"] = rect(first.floatingToolbarFrame)
        visuals.append(visual)
        first.close()
        let reopened = try editor(defaults, appearance, &owners); defer { close(reopened, completed, "reopened-" + mode, directory) }
        try choose(.rectangle, reopened); try draw(reopened, from: CGPoint(x: 70, y: 70), to: CGPoint(x: 210, y: 160))
        let savedPixels = try rendered(reopened), changed = try digest(savedPixels)
        try require(changed != original && (try AnnotationStyleAdapter.capture(reopened.annotationCanvas.annotations[0])) == saved, "Reopened mark missed saved style")
        let export = directory.appendingPathComponent("annotation-preferences-reopened-\(mode).png")
        var exported: CGImage?
        reopened.requestOutput(for: .history) { exported = $0 }
        let output = try required(exported, "Actual output route returned no image")
        try output.writePNG(to: export)
        let source = try required(CGImageSourceCreateWithURL(export as CFURL, nil), "Cannot reopen PNG")
        let decoded = try required(CGImageSourceCreateImageAtIndex(source, 0, nil), "Cannot decode PNG")
        try require(try digest(output) == changed && digest(decoded) == changed, "Reopened export pixels differ")
        menus.append(try popup(try control("annotation.savedStyles", reopened.window!), id: "annotation.savedStyles.reset", mode: mode))
        try require(!reopened.annotationCanvas.hasSavedStyle(for: .rectangle) && (try digest(rendered(reopened))) == changed, "Reset edited existing saved-style layer")
        reopened.close()
        let reset = try editor(defaults, appearance, &owners); defer { close(reset, completed, "reset-" + mode, directory) }
        try choose(.rectangle, reset); try draw(reset, from: CGPoint(x: 70, y: 70), to: CGPoint(x: 210, y: 160))
        let resetPixels = try rendered(reset); try require(try digest(resetPixels) == original, "Reset/reopen changed original rendering")
        try resetPixels.writePNG(to: directory.appendingPathComponent("annotation-preferences-reset-\(mode).png"))
        for editor in [first, reopened, reset] { editor.close(); try require(editor.isClosed && editor.window?.contentView == nil && editor.window?.delegate == nil, "Editor close retained owned content") }
        completed = true
        return ["appearance": mode, "existingLayerUnchanged": true, "savedStyleRestored": true, "futureMarksOnly": true,
            "reopenedStyleMatches": true, "nativeOutputPNGExact": true, "resetRestoresOriginal": true, "defaultLineWidth": old.lineWidth, "savedLineWidth": 10,
            "defaultPixelSHA256": original, "reopenedPixelSHA256": changed, "resetPixelSHA256": try digest(resetPixels)]
    }

    private static func editor(_ defaults: UserDefaults, _ appearance: NSAppearance.Name, _ owners: inout [WeakOwner]) throws -> ImageEditorController {
        let context = try bitmap(640, 360); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        let controller = ImageEditorController(image: try required(context.makeImage(), "Synthetic image absent"), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in },
            saveWorkflow: SaveWorkflowPresenter(defaults: defaults, isSmoke: true), copyAction: { _ in }, defaults: defaults)
        owners.append(WeakOwner(controller))
        let window = try required(controller.window, "Editor window absent")
        window.appearance = NSAppearance(named: appearance)
        let visible = try required(NSScreen.main?.visibleFrame, "WindowServer display absent")
        window.setFrame(CGRect(x: visible.midX - min(1000, visible.width)/2, y: visible.midY - min(680, visible.height)/2,
            width: min(1000, visible.width), height: min(680, visible.height)), display: true)
        controller.showWindow(nil); try show(window); try require(window.makeFirstResponder(controller.annotationCanvas), "Canvas focus failed")
        return controller
    }
    private static func choose(_ tool: ImageEditorTool, _ editor: ImageEditorController) throws {
        try PortableSettingsUIPreviewFixture.click(try control("editor.tool." + tool.rawValue, editor.window!))
        try require(editor.annotationCanvas.tool == tool, "Native tool click failed")
    }
    private static func draw(_ editor: ImageEditorController, from start: CGPoint, to end: CGPoint) throws {
        let canvas = editor.annotationCanvas, window = try required(canvas.window, "Canvas window absent")
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil)
            if type == .leftMouseDown {
                let root = try required(window.contentView, "Canvas root absent"), local = rootPoint(location, window)
                let hit = root.hitTest(root.convert(local, to: root.superview)); try require(hit === canvas, "Synthetic drawing hit a palette instead of canvas")
            }
            window.sendEvent(try required(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1), "Canvas mouse unavailable"))
        }
        try require(editor.annotationCanvas.annotations.count == 1, "Native gesture did not create exactly one mark")
    }

    /// Use the actual application event loop. Quartz integer nanoseconds are the
    /// identity clock; AppKit may round the floating-point seconds on enqueue.
    private static func key(_ window: NSWindow, _ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = [], purpose: String) throws -> [String: Any] {
        try require(window.isKeyWindow, "Key target is not the owned key window")
        let event = try keyEvent(window, code, text, flags), stamp = try required(event.cgEvent?.timestamp, "Key clock absent")
        NSApp.postEvent(event, atStart: true)
        let owned = try required(NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true), "Owned key not dequeued")
        guard owned.type == .keyDown, owned.windowNumber == window.windowNumber, owned.keyCode == code,
              owned.modifierFlags == event.modifierFlags, owned.cgEvent?.timestamp == stamp else {
            NSApp.postEvent(owned, atStart: true); throw failure("Unexpected key restored without dispatch")
        }
        NSApp.sendEvent(owned)
        return ["purpose": purpose, "keyCode": Int(code), "modifiers": flags.rawValue, "windowNumber": window.windowNumber,
            "ownedQuartzTimestamp": stamp, "dequeuedQuartzTimestamp": owned.cgEvent!.timestamp, "ownedWindowIsKey": true,
            "dispatchRoute": "NSApplication.nextEvent/sendEvent", "eventType": Int(owned.type.rawValue)]
    }
    fileprivate static func keyEvent(_ window: NSWindow, _ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try required(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code), "Key unavailable")
    }
    private static func popup(_ button: NSPopUpButton, id: String? = nil, title: String? = nil, mode: String) throws -> [String: Any] {
        let menu = try required(button.menu, "Popup menu absent"), window = try required(button.window, "Popup window absent")
        let item = try required(menu.items.first { id != nil ? $0.identifier?.rawValue == id : $0.title == title }, "Popup item absent")
        try require(item.isEnabled, "Popup item disabled")
        let observer = MenuProbe(menu: menu, window: window, target: item), prior = menu.delegate
        menu.delegate = observer
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak observer] _ in MainActor.assumeIsolated { observer?.tick() } }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); menu.delegate = prior }
        try PortableSettingsUIPreviewFixture.click(button)
        try require(observer.opened && observer.closed && observer.activated && !observer.timedOut, "Native popup tracking did not activate requested item")
        return ["appearance": mode, "controlID": button.identifier?.rawValue ?? "", "itemID": id ?? "width.\(title ?? "")",
            "opened": observer.opened, "closed": observer.closed, "nativeKeyboardSelection": observer.activated,
            "postedKeyCount": observer.posted, "timeoutSeconds": 2, "dispatchRoute": "owned-mouseDown/native-menu-tracking"]
    }

    private static func snapshot(_ window: NSWindow, _ category: String, mode: String, directory: URL, controls: [NSControl]? = nil) throws -> [String: Any] {
        let view = try required(window.contentView, "Snapshot root absent"); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let width = Int(ceil(view.bounds.width)), height = Int(ceil(view.bounds.height)), name = "annotation-preferences-\(category)-\(mode).png"
        let context = try bitmap(width, height)
        let rep = try required(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), "Snapshot allocation failed")
        rep.size = view.bounds.size
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep); context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let image = rep.cgImage { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        try required(context.makeImage(), "Snapshot image absent").writePNG(to: directory.appendingPathComponent(name))
        let raw: [String: Any] = ["windowFrame": rect(window.frame), "contentBounds": rect(view.bounds),
            "controls": descendants(view).compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.identifier != nil }.prefix(80).map {
                ["id": $0.identifier!.rawValue, "frame": rect($0.convert($0.bounds, to: view))] as [String: Any]
            }, "geometryValidated": false, "snapshotFile": name]
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name.replacingOccurrences(of: ".png", with: "-geometry.json")), options: .atomic)
        // PNG precedes every strict layout gate, so failures retain inspectable pixels.
        var result: [String: Any]
        if let controls {
            var frames: [CGRect] = [], rows: [[String: Any]] = []
            for control in controls {
                let frame = control.convert(control.bounds, to: view), center = CGPoint(x: frame.midX, y: frame.midY)
                let hit = view.hitTest(view.convert(center, to: view.superview))
                try require(view.bounds.contains(frame) && frame.width >= 16 && frame.height >= 16, "Style control clipped")
                try require(hit === control || hit?.isDescendant(of: control) == true, "Style control obscured")
                try require(frames.allSatisfy { !$0.insetBy(dx: 0.5, dy: 0.5).intersects(frame.insetBy(dx: 0.5, dy: 0.5)) }, "Style controls overlap")
                rows.append(["id": control.identifier?.rawValue ?? "", "frame": rect(frame), "hitTest": true]); frames.append(frame)
            }
            result = ["controls": rows, "contentBounds": rect(view.bounds), "controlsDoNotOverlap": true, "fullVisibleFramesChecked": true]
        } else { result = try PortableSettingsUIPreviewFixture.layout(window) }
        result["category"] = category; result["appearance"] = mode; result["file"] = name
        result["pixelWidth"] = width; result["pixelHeight"] = height; result["opaqueWindowBackgroundComposited"] = true
        return result
    }
    private static func show(_ window: NSWindow) throws {
        window.animationBehavior = .none; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !window.isKeyWindow && ProcessInfo.processInfo.systemUptime < deadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        try require(window.isKeyWindow, "Owned window did not become key"); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    private static func rendered(_ editor: ImageEditorController) throws -> CGImage { try required(editor.annotationCanvas.flattened(), "Renderer failed") }
    private static func close(_ controller: NSWindowController, _ completed: Bool, _ name: String, _ directory: URL) {
        if !completed, let window = controller.window, window.isVisible {
            _ = try? snapshot(window.attachedSheet ?? window, "failure-" + name, mode: "failure", directory: directory, controls: [])
        }
        controller.close()
    }
    private static func bitmap(_ width: Int, _ height: Int) throws -> CGContext {
        try require(width > 0 && height > 0 && width <= 4_000_000 / height, "Raster bound exceeded")
        return try required(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Bitmap unavailable")
    }
    private static func digest(_ image: CGImage) throws -> String {
        let context = try bitmap(image.width, image.height); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return hash(Data(bytes: try required(context.data, "Raster bytes absent"), count: context.bytesPerRow * context.height))
    }
    private static func domain(_ defaults: UserDefaults, _ suite: String) -> NSDictionary { (defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary }
    private static func rootPoint(_ location: CGPoint, _ window: NSWindow) -> CGPoint { window.contentView!.convert(location, from: nil) }
    private static func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    private static func control<T: NSControl>(_ id: String, _ window: NSWindow) throws -> T { try required(descendants(window.contentView).first { $0.identifier?.rawValue == id } as? T, "Control absent: " + id) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func until(_ condition: () -> Bool, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), message)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ text: String) throws { if try !condition() { throw failure(text) } }
    private static func required<T>(_ value: T?, _ text: String) throws -> T { guard let value else { throw failure(text) }; return value }
    private static func failure(_ text: String) -> Error { PicShotError.message("Annotation preferences fixture: " + text) }

    @MainActor private final class WeakOwner {
        weak var controller: NSWindowController?; weak var window: NSWindow?; weak var content: NSView?
        init(_ controller: NSWindowController) { self.controller = controller; window = controller.window; content = controller.window?.contentView }
        var released: Bool { controller == nil && window == nil && content == nil }
    }
    /// A scoped menu delegate plus a two-second native tracking timer; no event tap,
    /// process observer, global input delivery, menu callback or performAction shortcut.
    @MainActor private final class MenuProbe: NSObject, NSMenuDelegate {
        weak var menu: NSMenu?; weak var window: NSWindow?; weak var target: NSMenuItem?
        var opened = false, closed = false, activated = false, timedOut = false, posted = 0
        private var highlighted: NSMenuItem?, entered = false
        private let deadline = ProcessInfo.processInfo.systemUptime + 2
        init(menu: NSMenu, window: NSWindow, target: NSMenuItem) { self.menu = menu; self.window = window; self.target = target }
        func menuWillOpen(_ menu: NSMenu) { opened = true }
        func menuDidClose(_ menu: NSMenu) { closed = true; activated = entered && highlighted === target }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { if let item { highlighted = item } }
        func tick() {
            guard !closed else { return }
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; menu?.cancelTracking(); return }
            guard opened, !entered, let window else { return }
            let select = highlighted === target
            if let event = try? AnnotationPreferencesUIPreviewFixture.keyEvent(window, select ? 36 : 125, select ? "\r" : "\u{f701}") {
                entered = select; posted += 1; NSApp.postEvent(event, atStart: true)
            }
        }
    }
}
