import AppKit
import Carbon
import CryptoKit
import PicShotCore

/// Real owned AppKit windows and local files, with exclusively isolated defaults.
/// Mouse events are delivered only to these windows, never through a global tap.
@MainActor enum PortableSettingsUIPreviewFixture {
    static let checks: Set<String> = ["export-saved-values", "file-round-trip", "preview-read-only",
        "cancel-preserves-draft", "apply-once-closes", "duplicate-apply-ignored", "stale-preview-rejected",
        "os-conflict-rejected", "write-failure-rollback", "malformed-no-sheet", "parent-close-dismisses-sheet",
        "native-toolbar-reorder", "native-sidebar-selection", "light-dark-full-frame-layout"]

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let start = Date(), files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-Portable-UI-" + UUID().uuidString)
        let suite = "PicShot-Portable-UI-" + UUID().uuidString
        let donorSuite = suite + "-donor"
        let defaults = try required(UserDefaults(suiteName: suite), "Isolated preferences unavailable")
        let donor = try required(UserDefaults(suiteName: donorSuite), "Isolated donor unavailable")
        let appearance = NSApp.appearance
        defer {
            defaults.removePersistentDomain(forName: suite); donor.removePersistentDomain(forName: donorSuite)
            NSApp.appearance = appearance; try? files.removeItem(at: root)
        }
        var report: [String: Any] = ["schemaVersion": 1, "status": "running",
            "bundlePath": Bundle.main.bundlePath,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "userPreferencesReadOrWritten": false, "globalHotkeysRegistered": false,
            "globalInputPosted": false, "permissionRequests": false, "networkUsed": false,
            "liveScreenCaptured": false, "canonicalTemporaryRoot": true,
            "snapshotScope": "cached complete owned native content views; no live desktop capture",
            "interactionRoute": "NSView.hitTest and local NSEvent mouseDown with queued owned-window mouseUp",
            "overallDeadlineSeconds": 120]
        do {
            AppAppearancePreference.dark.save(to: donor)
            ScreenshotPreferences.save(.init(delay: .threeSeconds, showsCursor: true), to: donor)
            var hotkeys = HotKeyConfiguration.defaults
            hotkeys[.capture] = HotKeyBinding(keyCode: 6, modifiers: UInt32(cmdKey | controlKey))
            try hotkeys.save(to: donor)
            var order = AnnotationToolbarOrder.defaults; order.move(.rectangle, by: 1); order.write(to: donor)
            let incoming = try PortableSettingsStore(defaults: donor).exportData()
            let importedURL = root.appendingPathComponent("import.json")
            try incoming.write(to: importedURL, options: .atomic)
            let readback = try PortableSettingsStore.readImportData(from: importedURL)
            try require(readback == incoming, "File import readback changed bytes")
            var visuals: [[String: Any]] = []
            for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                defaults.removePersistentDomain(forName: suite)
                defaults.set("excluded-synthetic-path", forKey: "portable-fixture-excluded")
                NSApp.appearance = NSAppearance(named: name)
                var callbacks = 0, writes = 0, probes = 0
                let controller = SettingsController(onChange: { callbacks += 1 }, defaults: defaults, isSmoke: false,
                    validateImportedHotkeys: { _ in probes += 1 }, defaultsDomainName: suite)
                defer { controller.close() }
                let window = try show(controller, appearance: name)
                try select(.annotations, in: controller)
                try clickRow(1, in: controller.annotationToolbarView.tableView)
                try click(controller.annotationToolbarView.moveDownButton)
                let draft = controller.annotationToolbarView.draft
                try require(draft != .defaults && AnnotationToolbarOrder.read(from: defaults) == .defaults,
                            "Native toolbar action failed to keep a draft")
                visuals.append(try visual(window, category: "annotations", mode: mode, directory: evidenceDirectory))
                try select(.configuration, in: controller)
                let before = domain(defaults, suite)
                let exportURL = root.appendingPathComponent("export-" + mode + ".json")
                try controller.exportPortableSettings(to: exportURL)
                let exported = try PortableSettingsStore.readImportData(from: exportURL)
                try require(exported == (try controller.portableSettingsStore.exportData()), "Export included draft values")
                try require(!(try controller.portableSettingsStore.prepareImport(exported)).hasChanges, "Export failed same-store round trip")
                if mode == "light" { try exported.write(to: evidenceDirectory.appendingPathComponent("portable-settings-export.json"), options: .atomic) }
                visuals.append(try visual(window, category: "configuration", mode: mode, directory: evidenceDirectory))
                var review: PortableSettingsReviewController? = try controller.reviewPortableSettingsImport(readback)
                try await until({ window.attachedSheet === review?.window }, "Import review did not attach")
                review?.window?.appearance = NSAppearance(named: name)
                try require(review!.plan.hasChanges && review!.plan.changesHotKeys, "Incoming synthetic changes absent")
                try require(sameDomain(before, defaults, suite) && callbacks == 0 && probes == 0,
                            "Opening preview changed persisted values or probed hotkeys")
                visuals.append(try visual(try required(review?.window, "Review window missing"), category: "review", mode: mode, directory: evidenceDirectory))
                try click(review!.cancelButton)
                try await until({ controller.portableImportReview == nil && window.attachedSheet == nil }, "Cancel retained sheet")
                try require(sameDomain(before, defaults, suite) && controller.annotationToolbarView.draft == draft && callbacks == 0,
                            "Cancel changed saved preferences or existing annotation draft")
                review = try controller.reviewPortableSettingsImport(readback)
                controller.portableSettingsStore.beforeWrite = { _ in writes += 1 }
                try click(review!.applyButton)
                try await until({ !window.isVisible && window.attachedSheet == nil }, "Apply did not close settings/sheet")
                try require(callbacks == 1 && probes == 1 && writes > 1 && controller.portableImportReview == nil,
                            "Apply did not commit exactly once")
                try require(try controller.portableSettingsStore.exportData() == incoming, "Imported saved values differ from file")
                let committedWrites = writes
                review!.applyButton.performClick(nil) // Deliberately invoke a stale retained action after the sheet closes.
                try require(callbacks == 1 && probes == 1 && writes == committedWrites, "Duplicate Apply committed again")
                report["commitObservation" + mode.capitalized] = ["callbacks": callbacks, "hotkeyValidations": probes,
                    "preferenceWrites": writes, "duplicateAdditionalWrites": writes - committedWrites]
                review = nil
            }
            report["visuals"] = visuals
            report["failureCases"] = try await rejectionCases(defaults: defaults, suite: suite, incoming: incoming)
            report["resourceCycles"] = try await cycles(defaults: defaults, suite: suite, incoming: incoming, deadline: start.addingTimeInterval(120))
            report["checks"] = checks.sorted()
            report["fileRoundTrip"] = ["readbackByteCount": readback.count, "readbackMatchesWritten": true,
                "savedOnlyExport": true, "maximumFileBytes": PortableSettingsStore.maximumFileBytes]
            let names = ["portable-settings-export.json"] + visuals.compactMap { $0["file"] as? String }
            report["fileSHA256"] = try Dictionary(uniqueKeysWithValues: names.map {
                ($0, hash(try Data(contentsOf: evidenceDirectory.appendingPathComponent($0))))
            })
            report["status"] = "passed"; report["elapsedSeconds"] = Date().timeIntervalSince(start)
            try require(Date() < start.addingTimeInterval(120), "Portable fixture exceeded bounded deadline")
            try write(report, to: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["elapsedSeconds"] = Date().timeIntervalSince(start)
            try? write(report, to: evidenceDirectory); throw error
        }
    }

    private static func rejectionCases(defaults: UserDefaults, suite: String, incoming: Data) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        for kind in ["stale", "os-conflict", "rollback", "malformed", "parent-close"] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set("keep", forKey: "portable-fixture-excluded")
            var changes = 0, probes = 0, writes = 0
            let controller = SettingsController(onChange: { changes += 1 }, defaults: defaults, isSmoke: false,
                validateImportedHotkeys: { _ in
                    probes += 1
                    if kind == "os-conflict" { throw PicShotError.message("Injected OS shortcut conflict") }
                }, defaultsDomainName: suite)
            defer { controller.close() }
            let window = try show(controller, appearance: .aqua)
            try select(.configuration, in: controller)
            if kind == "malformed" {
                do { try controller.reviewPortableSettingsImport(Data("{malformed}".utf8)); throw failure("Malformed import opened a review") }
                catch is PortableSettingsError { }
                try require(controller.portableImportReview == nil && window.attachedSheet == nil && changes == 0, "Malformed import left a sheet")
                results.append(["case": kind, "preserved": true, "sheetOpened": false]); continue
            }
            let review = try controller.reviewPortableSettingsImport(incoming)
            if kind == "parent-close" {
                controller.close()
                try await until({ controller.portableImportReview == nil && window.attachedSheet == nil && review.window?.isVisible != true }, "Parent close retained its owned review")
                try require(changes == 0, "Parent close applied import")
                results.append(["case": kind, "preserved": true, "ownedSheetDismissed": true]); continue
            }
            if kind == "stale" { defaults.set(5, forKey: ScreenshotPreferences.delayKey) }
            let before = domain(defaults, suite)
            controller.portableSettingsStore.beforeWrite = { index in
                writes += 1
                if kind == "rollback" && index == 1 { throw PicShotError.message("Injected write failure") }
            }
            try click(review.applyButton)
            try require(sameDomain(before, defaults, suite) && changes == 0 && controller.portableImportReview === review,
                        "Rejected import changed stored preferences or closed review: " + kind)
            try require(!review.errorLabel.stringValue.isEmpty && window.isVisible && window.attachedSheet === review.window,
                        "Rejected import failed to show its error: " + kind)
            if kind == "stale" { try require(probes == 0 && writes == 0, "Stale plan reached writes/probes") }
            if kind == "os-conflict" { try require(probes == 1 && writes == 0, "Conflict reached writes") }
            if kind == "rollback" { try require(probes == 1 && writes == 2, "Rollback injection did not follow one write") }
            results.append(["case": kind, "preserved": true, "callbacks": changes, "writeAttempts": writes,
                            "hotkeyValidations": probes, "errorVisible": true])
            try click(review.cancelButton)
            try await until({ window.attachedSheet == nil }, "Failed review did not cancel")
        }
        return results
    }

    private static func cycles(defaults: UserDefaults, suite: String, incoming: Data, deadline: Date) async throws -> [String: Any] {
        var rows: [[String: Any]] = [], refs: [PortableSettingsWeakOwner] = []
        for index in 0..<14 {
            try require(Date() < deadline, "Ownership cycle deadline exceeded")
            defaults.removePersistentDomain(forName: suite)
            var changes = 0
            var controller: SettingsController? = SettingsController(onChange: { changes += 1 }, defaults: defaults, isSmoke: false, defaultsDomainName: suite)
            _ = try show(controller!, appearance: .aqua)
            controller!.selectCategory(.configuration)
            var review: PortableSettingsReviewController? = try controller!.reviewPortableSettingsImport(incoming)
            let owners = [PortableSettingsWeakOwner(controller!), PortableSettingsWeakOwner(review!)]
            refs += owners
            let apply = index % 2 == 1
            try click(apply ? review!.applyButton : review!.cancelButton)
            controller?.close(); review = nil; controller = nil
            try await until({ owners.allSatisfy(\.released) }, "Owned settings/review objects retained after cycle \(index)", seconds: 4)
            try require(changes == (apply ? 1 : 0), "Repeated action callback mismatch")
            rows.append(["index": index, "warmup": index < 2, "action": apply ? "apply" : "cancel",
                         "callbacks": changes, "releasedControllers": 2, "releasedWindows": 2, "releasedContentViews": 2])
        }
        try require(refs.allSatisfy(\.released), "Previously closed owner became retained")
        return ["warmupCycles": 2, "measuredCycles": 12, "rows": rows, "releaseProbeCount": refs.count,
            "retainedControllers": refs.filter { $0.controller != nil }.count,
            "retainedWindows": refs.filter { $0.window != nil }.count,
            "retainedContentViews": refs.filter { $0.content != nil }.count,
            "releaseDeadlinePerCycleSeconds": 4, "memoryStabilityAssessed": false,
            "scope": "Two warmups plus twelve alternating open/review/cancel or apply/close cycles; weak references only, no process-memory or zero-leak claim"]
    }

    static func show(_ controller: SettingsController, appearance: NSAppearance.Name) throws -> NSWindow {
        let window = try required(controller.window, "Settings window missing")
        window.appearance = NSAppearance(named: appearance); window.animationBehavior = .none
        controller.showWindow(nil); window.center(); window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return window
    }

    static func select(_ category: SettingsCategory, in controller: SettingsController) throws {
        let root = try required(controller.window?.contentView, "Settings content missing")
        let index = try required(SettingsCategory.allCases.firstIndex(of: category), "Unknown category")
        let button = try required(descendants(root).compactMap { $0 as? SettingsSidebarButton }
            .first { $0.tag == index }, "Sidebar target missing")
        try click(button); try require(controller.selectedCategory == category, "Native sidebar selection failed")
        root.layoutSubtreeIfNeeded()
    }

    static func click(_ button: NSButton) throws {
        try require(button.isEnabled && !button.isHiddenOrHasHiddenAncestor, "Native button unavailable: " + button.title)
        try mouseClick(button, point: CGPoint(x: button.bounds.midX, y: button.bounds.midY))
    }

    static func clickRow(_ row: Int, in table: NSTableView) throws {
        table.scrollRowToVisible(row); table.layoutSubtreeIfNeeded()
        let rect = table.rect(ofRow: row)
        try mouseClick(table, point: CGPoint(x: rect.midX, y: rect.midY))
        try require(table.selectedRow == row, "Native table row selection failed")
    }

    private static func mouseClick(_ view: NSView, point: CGPoint) throws {
        let window = try required(view.window, "Mouse target has no window")
        let root = try required(window.contentView, "Mouse root absent")
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let location = view.convert(point, to: nil)
        let local = root.convert(location, from: nil)
        let hit = root.hitTest(root.convert(local, to: root.superview))
        try require(hit === view || hit?.isDescendant(of: view) == true, "Native mouse target obscured")
        let down = try required(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1), "Mouse-down unavailable")
        let up = try required(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: down.timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0), "Mouse-up unavailable")
        NSApp.postEvent(up, atStart: true)
        view.mouseDown(with: down)
    }

    static func layout(_ window: NSWindow) throws -> [String: Any] {
        let root = try required(window.contentView, "Layout root absent")
        let visible = try required(window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame, "Native display absent")
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try require(visible.insetBy(dx: -1, dy: -1).contains(window.frame), "Full native window is outside usable display: \(window.frame)")
        let views = descendants(root).filter { !$0.isHiddenOrHasHiddenAncestor }
        let buttons = views.compactMap { $0 as? NSButton }
        var rows: [[String: Any]] = [], frames: [(id: String, title: String, frame: CGRect)] = []
        for (index, button) in buttons.enumerated() {
            let id = button.identifier?.rawValue ?? "button.\(index)"
            let frame = button.convert(button.bounds, to: root)
            let screen = window.convertToScreen(button.convert(button.bounds, to: nil))
            try require(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) && visible.insetBy(dx: -1, dy: -1).contains(screen),
                        "Full control frame is clipped: " + button.title)
            try require(frame.width >= 20 && frame.height >= 18, "Unreadable button extent")
            let required = button.cell?.cellSize ?? .zero
            try require(frame.width + 1 >= required.width && frame.height + 1 >= required.height, "Button title does not fit: " + button.title)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let hit = root.hitTest(root.convert(center, to: root.superview))
            try require(hit === button || hit?.isDescendant(of: button) == true, "Control not hit-testable: " + button.title)
            for other in frames {
                try require(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(other.frame.insetBy(dx: 0.5, dy: 0.5)),
                    "Visible native controls overlap: \(other.id) [\(other.title)] fullFrame=\(other.frame) and \(id) [\(button.title)] fullFrame=\(frame)")
            }
            frames.append((id, button.title, frame))
            rows.append(["id": id, "title": button.title,
                "frame": rect(frame), "screenFrame": rect(screen), "enabled": button.isEnabled,
                "hitTest": true, "readable": true, "minimumSize": [required.width, required.height]])
        }
        var labelCount = 0
        for label in views.compactMap({ $0 as? NSTextField }) where !label.stringValue.isEmpty {
            // Table/document rows are deliberately scrollable; their viewport is
            // checked below. Do not pretend offscreen rows are visible controls.
            var ancestor = label.superview, outsideViewport = false
            while let item = ancestor {
                if let clip = item as? NSClipView, !clip.bounds.contains(label.convert(label.bounds, to: clip)) { outsideViewport = true }
                ancestor = item.superview
            }
            if outsideViewport { continue }
            let frame = label.convert(label.bounds, to: root)
            try require(root.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Visible text is clipped: " + label.stringValue)
            let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000)) ?? .zero
            try require(frame.height + 2 >= size.height && (label.font?.pointSize ?? 0) >= 11, "Visible text is too small/truncated")
            if label.cell?.wraps != true { try require(frame.width + 2 >= size.width, "Visible single-line text is truncated") }
            labelCount += 1
        }
        for scroll in views.compactMap({ $0 as? NSScrollView }) {
            let frame = scroll.convert(scroll.bounds, to: root)
            try require(root.bounds.contains(frame) && frame.width >= 200 && frame.height >= 100, "Review/table viewport is clipped")
        }
        try require(!buttons.isEmpty && labelCount > 0, "Layout omitted native controls/text")
        return ["windowFrame": rect(window.frame), "visibleFrame": rect(visible), "contentBounds": rect(root.bounds),
            "controls": rows, "readableLabelCount": labelCount, "fullVisibleFramesChecked": true,
            "controlsDoNotOverlap": true, "scrollViewportsChecked": true]
    }

    /// Deliberately unvalidated observations survive a strict layout rejection.
    /// Every rectangle is the actual complete bounds converted to owned content
    /// and screen coordinates; alignment rectangles are never substituted.
    private static func rawGeometry(_ window: NSWindow, root: NSView) -> [String: Any] {
        let views = descendants(root).filter { !$0.isHiddenOrHasHiddenAncestor }
        let buttons = views.compactMap { $0 as? NSButton }
        let controls = views.compactMap { $0 as? NSControl }
        let rows: [[String: Any]] = controls.enumerated().map { index, control in
            let frame = control.convert(control.bounds, to: root)
            let screen = window.convertToScreen(control.convert(control.bounds, to: nil))
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let hit = root.hitTest(root.convert(center, to: root.superview))
            var row: [String: Any] = ["id": control.identifier?.rawValue ?? "control.\(index)",
                "class": String(describing: type(of: control)), "fullFrame": rect(frame),
                "fullScreenFrame": rect(screen), "visibleRect": rect(control.visibleRect),
                "enabled": control.isEnabled, "hitTest": hit === control || hit?.isDescendant(of: control) == true]
            let insets = control.alignmentRectInsets
            row["alignmentInsetsTopLeftBottomRight"] = [insets.top, insets.left, insets.bottom, insets.right]
            row["frameInSuperview"] = rect(control.frame)
            row["alignmentRectangleInSuperview"] = rect(control.alignmentRect(forFrame: control.frame))
            if let button = control as? NSButton {
                let buttonIndex = buttons.firstIndex { $0 === button } ?? index
                row["id"] = button.identifier?.rawValue ?? "button.\(buttonIndex)"
                row["title"] = button.title
                let size = button.cell?.cellSize ?? .zero
                row["minimumSize"] = [size.width, size.height]
            } else if let label = control as? NSTextField { row["text"] = label.stringValue }
            return row
        }
        var result: [String: Any] = ["windowFrame": rect(window.frame), "contentBounds": rect(root.bounds),
            "controls": rows, "geometryValidated": false,
            "scope": "Unvalidated complete frames from this owned synthetic window only; cached content PNG, no desktop capture"]
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame { result["visibleFrame"] = rect(visible) }
        return result
    }

    private static func visual(_ window: NSWindow, category: String, mode: String, directory: URL) throws -> [String: Any] {
        let view = try required(window.contentView, "Snapshot content missing")
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let stem = "portable-settings-" + category + "-" + mode
        let name = stem + ".png", geometryName = stem + "-geometry.json"
        let geometryURL = directory.appendingPathComponent(geometryName)
        var diagnostic = rawGeometry(window, root: view)
        diagnostic["category"] = category; diagnostic["appearance"] = mode
        diagnostic["snapshotFile"] = name; diagnostic["status"] = "layout-not-yet-validated"
        try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: geometryURL, options: .atomic)
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try require(width > 0 && height > 0 && width <= 4_000_000 / height, "Owned snapshot exceeds pixel bound")
        let bitmap = try required(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Owned bitmap allocation failed")
        bitmap.size = view.bounds.size
        let context = try required(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Opaque owned composition failed")
        var cached = false
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let image = bitmap.cgImage {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); cached = true
            }
        }
        try require(cached, "Owned cached pixels unavailable")
        let image = try required(context.makeImage(), "Owned composited image missing")
        let data = try required(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "Owned PNG unavailable")
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        // Keep both the full owned PNG and raw frames before applying the gate.
        // A rejected layout is evidence of failure, never a passed visual row.
        var result: [String: Any]
        do {
            result = try layout(window)
            diagnostic["status"] = "passed"; diagnostic["geometryValidated"] = true
        } catch {
            diagnostic["status"] = "failed"; diagnostic["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
                .write(to: geometryURL, options: .atomic)
            throw failure(error.localizedDescription + "; owned-window evidence: " + name + ", " + geometryName)
        }
        try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: geometryURL, options: .atomic)
        result["category"] = category; result["appearance"] = mode; result["file"] = name
        result["pixelWidth"] = width; result["pixelHeight"] = height
        result["opaqueWindowBackgroundComposited"] = true; return result
    }

    private static func domain(_ defaults: UserDefaults, _ suite: String) -> NSDictionary { (defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary }
    private static func sameDomain(_ before: NSDictionary, _ defaults: UserDefaults, _ suite: String) -> Bool { before.isEqual(domain(defaults, suite)) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func until(_ condition: () -> Bool, _ text: String, seconds: TimeInterval = 4) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), text)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ text: String) throws { if try !condition() { throw failure(text) } }
    private static func required<T>(_ value: T?, _ text: String) throws -> T { guard let value else { throw failure(text) }; return value }
    private static func failure(_ text: String) -> NSError { NSError(domain: "PortableSettingsUIFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private static func write(_ report: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("portable-settings-ui.json"), options: .atomic)
    }
}

@MainActor private final class PortableSettingsWeakOwner {
    weak var controller: NSWindowController?
    weak var window: NSWindow?
    weak var content: NSView?
    init(_ controller: NSWindowController) { self.controller = controller; window = controller.window; content = controller.window?.contentView }
    var released: Bool { controller == nil && window == nil && content == nil }
}
