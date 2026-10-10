import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor private final class LocalShortcutTestApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}

/// Actual owned AppKit windows, responders, field editors, marked text and events.
/// No global event delivery, real screen capture, input monitoring or TCC changes.
@MainActor final class LocalAnnotationShortcutNativeTests: XCTestCase {
    private var interactionTrace: LocalShortcutInteractionTrace?

    func testOwnedCanvasRoutesPhysicalRemapShiftAndRejectsRepeatAndGlobalModifiers() throws {
        try withApplicationLoop { [self] in
            let settings = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
                .replacing(.ellipse, with: .init(keyCode: 15, modifiers: 1))
            let editor = try makeEditor(settings); defer { editor.close() }
            let window = try XCTUnwrap(editor.window), canvas = editor.annotationCanvas
            try send(window, code: 15, characters: "q") // physical R on a different layout
            XCTAssertEqual(canvas.tool, .rectangle)
            try send(window, code: 15, characters: "Q", flags: .shift); XCTAssertEqual(canvas.tool, .ellipse)
            let excludedModifiers: [NSEvent.ModifierFlags] = [.command, .control, .option, [.command, .shift], .function]
            for flags in excludedModifiers {
                editor.chooseTool(.arrow); window.sendEvent(try key(window, code: 15, characters: "r", flags: flags))
                XCTAssertEqual(canvas.tool, .arrow)
            }
            window.sendEvent(try key(window, code: 15, characters: "r", repeatKey: true)); XCTAssertEqual(canvas.tool, .arrow)
            try send(window, code: 15, characters: "r", flags: .capsLock); XCTAssertEqual(canvas.tool, .rectangle)
            XCTAssertTrue(canvas.annotations.isEmpty)
        }
    }

    func testSavedConfigurationAffectsNextEditorAndExplicitDefaultsStayIsolated() throws {
        try withApplicationLoop { [self] in
            let (defaults, suite) = try preferences(); defer { defaults.removePersistentDomain(forName: suite) }
            let original = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
            try original.write(to: defaults)
            let first = try makeEditor(nil, defaults: defaults); defer { first.close() }
            let changed = try original.replacing(.rectangle, with: .init(keyCode: 11)); try changed.write(to: defaults)
            XCTAssertEqual(first.localShortcuts, original)
            try send(try XCTUnwrap(first.window), code: 15, characters: "r"); XCTAssertEqual(first.annotationCanvas.tool, .rectangle)
            let second = try makeEditor(nil, defaults: defaults); defer { second.close() }
            try send(try XCTUnwrap(second.window), code: 15, characters: "r"); XCTAssertEqual(second.annotationCanvas.tool, .arrow)
            try send(try XCTUnwrap(second.window), code: 11, characters: "b"); XCTAssertEqual(second.annotationCanvas.tool, .rectangle)
            let explicit = try makeEditor(.defaults, defaults: defaults); defer { explicit.close() }
            XCTAssertEqual(explicit.localShortcuts, .defaults)
            try send(try XCTUnwrap(explicit.window), code: 11, characters: "b"); XCTAssertEqual(explicit.annotationCanvas.tool, .arrow)
        }
    }

    func testFieldEditorMarkedTextAndInlineAnnotationKeepTypingWithoutToolChanges() throws {
        try withApplicationLoop { [self] in
            let settings = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
            let editor = try makeEditor(settings); defer { editor.close() }
            let window = try XCTUnwrap(editor.window), canvas = editor.annotationCanvas
            let field = NSTextField(frame: CGRect(x: 20, y: 20, width: 160, height: 24))
            try XCTUnwrap(window.contentView).addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let text = try XCTUnwrap(window.firstResponder as? NSTextView); XCTAssertTrue(text.isFieldEditor)
            try send(window, code: 15, characters: "r")
            XCTAssertEqual(text.string, "r"); XCTAssertEqual(canvas.tool, .arrow)
            text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(text.hasMarkedText())
            XCTAssertFalse(canvas.handleLocalToolShortcut(try key(window, code: 15, characters: "r")))
            try send(window, code: 15, characters: "r"); XCTAssertEqual(canvas.tool, .arrow)
            text.unmarkText(); window.makeFirstResponder(canvas); field.removeFromSuperview()
            editor.chooseTool(.text)
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 100, y: 100)))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 100, y: 100)))
            let inline = try XCTUnwrap(editor.activeInlineTextView)
            XCTAssertTrue(window.firstResponder === inline)
            try send(window, code: 15, characters: "r"); XCTAssertEqual(inline.string, "r"); XCTAssertEqual(canvas.tool, .text)
            inline.setMarkedText("字", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(inline.hasMarkedText())
            XCTAssertFalse(canvas.handleLocalToolShortcut(try key(window, code: 15, characters: "r")))
            XCTAssertTrue(canvas.annotations.isEmpty)
        }
    }

    func testExistingNumberCommentEnterDeleteArrowAndCommandActionsRemainUnchanged() throws {
        try withApplicationLoop { [self] in
            let settings = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
                .replacing(.ellipse, with: .init(keyCode: 8)).replacing(.line, with: .init(keyCode: 1)).replacing(.freehand, with: .init(keyCode: 6))
                .replacing(.sector, with: .init(keyCode: 12))
            let editor = try makeEditor(settings); defer { editor.close() }
            let window = try XCTUnwrap(editor.window), canvas = editor.annotationCanvas
            canvas.add(ImageAnnotation(tool: .number, points: [CGPoint(x: 100, y: 100)]))
            // Preserve build185's character-based A command on alternate layouts:
            // an assigned physical Q producing "a" still edits the selected comment.
            try send(window, code: 12, characters: "a")
            XCTAssertNotNil(canvas.activeNumberCommentInput); XCTAssertEqual(canvas.tool, .arrow)
            canvas.finishNumberComment(commit: false)
            try send(window, code: 0, characters: "a"); XCTAssertNotNil(canvas.activeNumberCommentInput)
            try send(window, code: 15, characters: "r"); XCTAssertEqual(canvas.activeNumberCommentInput?.string, "r")
            XCTAssertEqual(canvas.tool, .arrow)
            canvas.finishNumberComment(commit: false); editor.chooseTool(.select)
            let before = try XCTUnwrap(canvas.selectedAnnotation?.points.first)
            try send(window, code: 124, characters: ""); XCTAssertEqual(canvas.selectedAnnotation?.points.first?.x, before.x + 1)
            try send(window, code: 126, characters: "", flags: .shift); XCTAssertEqual(canvas.selectedAnnotation?.points.first?.y, before.y + 10)
            try send(window, code: 36, characters: "\r"); XCTAssertNotNil(canvas.activeNumberCommentInput)
            canvas.finishNumberComment(commit: false); window.makeFirstResponder(canvas)
            var copy = 0, save = 0, undo = 0, redo = 0
            canvas.onCopy = { copy += 1 }; canvas.onExport = { save += 1 }; canvas.onUndo = { undo += 1 }; canvas.onRedo = { redo += 1 }
            let commands: [(UInt16, String, NSEvent.ModifierFlags)] = [(8, "c", .command), (1, "s", .command), (6, "z", .command), (6, "z", [.command, .shift])]
            for (code, characters, flags) in commands {
                XCTAssertTrue(window.performKeyEquivalent(with: try key(window, code: code, characters: characters, flags: flags)))
            }
            XCTAssertEqual([copy, save, undo, redo], [1, 1, 1, 1]); XCTAssertEqual(canvas.tool, .select)
            try send(window, code: 51, characters: ""); XCTAssertTrue(canvas.annotations.isEmpty)
        }
    }

    func testActiveDrawingPolylineCropAndAutomaticReviewKeepTheirDrafts() throws {
        try withApplicationLoop { [self] in
            let settings = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
            let editor = try makeEditor(settings); defer { editor.close() }
            let window = try XCTUnwrap(editor.window), canvas = editor.annotationCanvas
            editor.chooseTool(.freehand)
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 50, y: 50)))
            let pending = try XCTUnwrap(canvas.pendingFreehand?.id)
            try send(window, code: 15, characters: "r"); XCTAssertEqual(canvas.pendingFreehand?.id, pending); XCTAssertEqual(canvas.tool, .freehand)
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 100, y: 90)))
            editor.chooseTool(.polyline)
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 40, y: 40)))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 40, y: 40)))
            let points = canvas.pendingPolylinePointCount; XCTAssertGreaterThan(points, 0)
            try send(window, code: 15, characters: "r"); XCTAssertEqual(canvas.pendingPolylinePointCount, points); XCTAssertEqual(canvas.tool, .polyline)
            canvas.cancelPolyline(); editor.chooseTool(.crop)
            let crop = CGRect(x: 20, y: 20, width: 100, height: 90); canvas.cropRect = crop
            try send(window, code: 15, characters: "r"); XCTAssertEqual(canvas.cropRect, crop); XCTAssertEqual(canvas.tool, .crop)
            editor.chooseTool(.arrow); canvas.automaticMosaicDrawHandler = { _ in }
            try send(window, code: 15, characters: "r"); XCTAssertEqual(canvas.tool, .arrow)
            canvas.automaticMosaicDrawHandler = nil
            try send(window, code: 15, characters: "r"); XCTAssertEqual(canvas.tool, .rectangle)
        }
    }

    func testNativeSheetMenuAndOtherWindowBlockCanvasShortcutRouting() throws {
        try withApplicationLoop { [self] in
            let settings = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
            let editor = try makeEditor(settings); defer { editor.close() }
            let window = try XCTUnwrap(editor.window), canvas = editor.annotationCanvas
            let other = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false; defer { other.close() }
            try show(other)
            XCTAssertFalse(canvas.handleLocalToolShortcut(try key(window, code: 15, characters: "r")))
            try show(window); window.makeFirstResponder(canvas)
            XCTAssertFalse(canvas.handleLocalToolShortcut(try key(other, code: 15, characters: "r")))
            let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet)
            XCTAssertNotNil(window.attachedSheet)
            XCTAssertFalse(canvas.handleLocalToolShortcut(try key(window, code: 15, characters: "r")))
            window.endSheet(sheet); sheet.orderOut(nil); sheet.close()
            try show(window); window.makeFirstResponder(canvas)
            let menu = NSMenu(title: "Owned shortcut test"); menu.addItem(withTitle: "Fixture", action: nil, keyEquivalent: "")
            let event = try key(window, code: 15, characters: "r")
            var observedTracking = false, routed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                observedTracking = true; routed = canvas.handleLocalToolShortcut(event); menu.cancelTracking()
            }
            _ = menu.popUp(positioning: nil, at: CGPoint(x: 100, y: 100), in: canvas)
            XCTAssertTrue(observedTracking); XCTAssertFalse(routed); XCTAssertEqual(canvas.tool, .arrow)
            try show(window); window.makeFirstResponder(canvas)
            try send(window, code: 15, characters: "r"); XCTAssertEqual(canvas.tool, .rectangle)
        }
    }

    func testRegionCaptureDoesNotDispatchEditorBindings() throws {
        try withApplicationLoop { [self] in
            let settings = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15))
            let editor = try makeEditor(settings); defer { editor.close() }
            let image = ImageEditorRenderer.makeSampleImage()
            let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 960, height: 600), pixelWidth: 960, pixelHeight: 600)
            let selector = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 960, height: 600), frozenImage: image, geometry: geometry)
            let capture = NSWindow(contentRect: selector.frame, styleMask: [.titled], backing: .buffered, defer: false)
            capture.isReleasedWhenClosed = false; capture.contentView = selector
            defer { selector.discard(); capture.close() }
            var captures = 0; selector.finished = { _ in captures += 1 }
            try show(capture); XCTAssertTrue(capture.makeFirstResponder(selector))
            try send(capture, code: 15, characters: "r")
            XCTAssertEqual(editor.annotationCanvas.tool, .arrow); XCTAssertEqual(captures, 0)
            XCTAssertFalse(editor.annotationCanvas.handleLocalToolShortcut(try key(capture, code: 15, characters: "r")))
        }
    }

    func testDraftNativeRecordingRemapDuplicateReservedCancelClearAndResetHitTargets() throws {
        try withApplicationLoop { [self] in
            let view = LocalAnnotationShortcutSettingsView(settings: .defaults), window = try hostDraft(view)
            defer { window.close() }
            // Diagnostic only: observe the same immediate sequence without sleeps,
            // retries, changed assertions or a different AppKit dispatch route.
            let trace = LocalShortcutInteractionTrace(view: view)
            interactionTrace = trace
            let previousChange = view.onChange, previousStatus = view.captureButton.onStatus
            view.onChange = { previousChange?(); trace.record("draft-onChange") }
            view.captureButton.onStatus = { message, error in
                previousStatus?(message, error)
                trace.record(error ? "recorder-status-error" : "recorder-status")
            }
            defer {
                view.onChange = previousChange; view.captureButton.onStatus = previousStatus
                interactionTrace = nil; trace.emit(test: name)
            }
            trace.record("sequence-start")
            view.selectTool(.rectangle)
            try nativeClick(view.captureButton); XCTAssertTrue(view.captureButton.isRecording)
            try send(window, code: 15, characters: "r")
            XCTAssertEqual(view.draft[.rectangle], .init(keyCode: 15)); XCTAssertFalse(view.captureButton.isRecording)
            try nativeClick(view.captureButton); try send(window, code: 11, characters: "b")
            XCTAssertEqual(view.draft[.rectangle], .init(keyCode: 11))
            view.selectTool(.ellipse); try nativeClick(view.captureButton)
            try send(window, code: 11, characters: "b")
            XCTAssertNil(view.draft[.ellipse]); XCTAssertTrue(view.captureButton.isRecording); XCTAssertTrue(view.statusLabel.stringValue.contains("已分配"))
            let reserved: [(UInt16, NSEvent.ModifierFlags)] = [(0, []), (123, []), (36, []), (8, .command), (18, .control), (15, .option)]
            for (code, flags) in reserved {
                XCTAssertTrue(window.performKeyEquivalent(with: try key(window, code: code, characters: "", flags: flags)))
                XCTAssertNil(view.draft[.ellipse]); XCTAssertTrue(view.captureButton.isRecording)
            }
            try send(window, code: 53, characters: ""); XCTAssertFalse(view.captureButton.isRecording); XCTAssertNil(view.draft[.ellipse])
            try nativeClick(view.captureButton); try send(window, code: 15, characters: "R", flags: .shift)
            XCTAssertEqual(view.draft[.ellipse], .init(keyCode: 15, modifiers: 1))
            try nativeClick(view.clearButton); XCTAssertNil(view.draft[.ellipse])
            view.selectTool(.rectangle); try nativeClick(view.captureButton); try send(window, code: 51, characters: "")
            XCTAssertEqual(view.draft, .defaults)
            try nativeClick(view.captureButton); try send(window, code: 15, characters: "r")
            try nativeClick(view.restoreDefaultsButton); XCTAssertEqual(view.draft, .defaults)
            XCTAssertFalse(view.restoreDefaultsButton.isEnabled); XCTAssertFalse(view.clearButton.isEnabled)
            let root = try XCTUnwrap(window.contentView)
            let controls = [view.captureButton as NSButton, view.clearButton, view.restoreDefaultsButton]
            for button in controls {
                XCTAssertEqual(button.alignmentRect(forFrame: button.frame), button.frame)
                XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)))
                for x in [button.bounds.minX + 2, button.bounds.midX, button.bounds.maxX - 2] {
                    let point = button.convert(CGPoint(x: x, y: button.bounds.midY), to: root.superview)
                    let hit = root.hitTest(point)
                    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
                }
            }
            for index in 0..<(controls.count - 1) {
                let a = controls[index].convert(controls[index].bounds, to: root)
                let b = controls[index + 1].convert(controls[index + 1].bounds, to: root)
                XCTAssertFalse(a.intersects(b), "Complete control frames must not overlap")
            }
        }
    }

    func testDraftCancelSaveAndLossOfFocusNeverWriteAnUnacceptedKey() throws {
        try withApplicationLoop { [self] in
            let (defaults, suite) = try preferences(); defer { defaults.removePersistentDomain(forName: suite) }
            let original = try LocalAnnotationShortcutSettings.defaults.replacing(.rectangle, with: .init(keyCode: 15)); try original.write(to: defaults)
            let view = LocalAnnotationShortcutSettingsView(settings: .read(from: defaults)), window = try hostDraft(view)
            defer { window.close() }
            view.selectTool(.rectangle); try nativeClick(view.captureButton); try send(window, code: 11, characters: "b")
            XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults), original)
            view.apply(settings: .read(from: defaults)); XCTAssertEqual(view.draft, original)
            try nativeClick(view.captureButton); window.makeFirstResponder(view.tableView)
            XCTAssertFalse(view.captureButton.isRecording)
            try send(window, code: 17, characters: "t"); XCTAssertEqual(view.draft, original)
            view.selectTool(.rectangle); try nativeClick(view.captureButton)
            let other = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 180, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false; defer { other.close() }
            try show(other); XCTAssertFalse(view.captureButton.isRecording)
            try show(window); try send(window, code: 17, characters: "t"); XCTAssertEqual(view.draft, original)
            view.selectTool(.rectangle); try nativeClick(view.captureButton); try send(window, code: 11, characters: "b")
            try view.draft.write(to: defaults)
            XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults)[.rectangle], .init(keyCode: 11))
            try nativeClick(view.restoreDefaultsButton)
            window.close()
            XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults)[.rectangle], .init(keyCode: 11), "Closing abandons Reset draft")
        }
    }

    private func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        _ = NSApplication.shared
        // Never stop or reconfigure an application loop owned by another host.
        if NSApp.isRunning { try body(); return }
        _ = try XCTUnwrap(NSApp.modalWindow == nil && NSApp.delegate == nil ? true : nil,
            "Standalone UI host unexpectedly has a modal window or application delegate")
        _ = try XCTUnwrap(UserDefaults.standard.object(forKey: "NSOpen") == nil ? true : nil,
            "Standalone UI host unexpectedly has a file-open request")
        let originalPolicy = NSApp.activationPolicy()
        recordHostState("before-preparation")
        let state = LocalShortcutTestApplicationLoop()
        defer {
            state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
            if NSApp.activationPolicy() != originalPolicy { _ = NSApp.setActivationPolicy(originalPolicy) }
            XCTAssertEqual(NSApp.activationPolicy(), originalPolicy)
            recordHostState("policy-restored")
        }
        if originalPolicy == .prohibited {
            _ = try XCTUnwrap(NSApp.setActivationPolicy(.accessory) ? true : nil,
                "Native local-shortcut interaction requires an activatable owned application")
        }
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0))
        func finish(_ result: Result<Void, Error>) {
            guard state.acceptsCallbacks, state.result == nil else { return }
            state.timer?.invalidate(); state.timer = nil; state.result = result
            NSApp.stop(nil); NSApp.postEvent(wake, atStart: true)
        }
        // A main-queue callback may already own XCTest's stack. Schedule on
        // the run loop so recursive main-queue draining is not required.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                guard state.acceptsCallbacks else { return }
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard state.acceptsCallbacks, state.result == nil else { return }
                        if NSApp.isRunning && !state.activationRequested {
                            state.activationRequested = true
                            NSApp.activate(ignoringOtherApps: true)
                            self.recordHostState("owned-loop-started")
                        }
                        if NSApp.isRunning && NSApp.isActive {
                            state.timer?.invalidate(); state.timer = nil
                            self.recordHostState("body-admitted")
                            finish(Result { try body() })
                        } else if ProcessInfo.processInfo.systemUptime >= deadline {
                            self.recordHostState("host-readiness-failed")
                            finish(.failure(NSError(domain: "PicShot.LocalShortcutUITestHost", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Owned application loop did not become active within one second"])))
                        }
                    }
                }
                state.timer = timer; RunLoop.main.add(timer, forMode: .default)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        NSApp.run()
        state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
        recordHostState("owned-loop-returned")
        XCTAssertFalse(NSApp.isRunning)
        try XCTUnwrap(state.result, "Owned application loop exited before its test body completed").get()
    }

    private func recordHostState(_ phase: String, window: NSWindow? = nil) {
        let observation: [String: Any] = ["phase": phase, "test": name,
            "applicationIsActive": NSApp.isActive,
            "applicationIsRunning": NSApp.isRunning, "activationPolicy": NSApp.activationPolicy().rawValue,
            "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? -1,
            "ownedWindowNumber": window?.windowNumber ?? -1, "ownedWindowIsKey": window?.isKeyWindow ?? false]
        if let data = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]) {
            print("LocalAnnotationShortcut native host: " + String(decoding: data, as: UTF8.self))
        }
    }

    private func preferences() throws -> (UserDefaults, String) {
        let name = "PicShot.LocalAnnotationShortcutNativeTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }
    private func makeEditor(_ settings: LocalAnnotationShortcutSettings?, defaults: UserDefaults? = nil) throws -> ImageEditorController {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Owned AppKit shortcuts fixture requires WindowServer") }
        let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, localShortcuts: settings, defaults: defaults)
        editor.showWindow(nil); let window = try XCTUnwrap(editor.window)
        do {
            try show(window); XCTAssertTrue(window.makeFirstResponder(editor.annotationCanvas)); return editor
        } catch { editor.close(); throw error }
    }
    private func show(_ window: NSWindow) throws {
        _ = NSApplication.shared
        window.animationBehavior = .none; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !window.isKeyWindow, ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        recordHostState("owned-window-readiness", window: window)
        _ = try XCTUnwrap(window.isKeyWindow ? true : nil,
            "Owned local-shortcut window did not become key within one second")
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    private func hostDraft(_ view: NSView) throws -> NSWindow {
        _ = NSApplication.shared
        let window = LocalShortcutDraftFixtureWindow(contentRect: CGRect(x: 40, y: 40, width: 570, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView); view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), view.topAnchor.constraint(equalTo: root.topAnchor, constant: 18)])
        do { try show(window); return window }
        catch { window.close(); throw error }
    }
    private func key(_ window: NSWindow, code: UInt16, characters: String, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code))
        interactionTrace?.record("created-key", supplied: event)
        return event
    }
    private func send(_ window: NSWindow, code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws {
        let event = try key(window, code: code, characters: characters, flags: flags)
        interactionTrace?.record("before-key", supplied: event)
        let handled = window.performKeyEquivalent(with: event)
        interactionTrace?.record("after-key-equivalent", supplied: event, detail: handled ? "handled" : "unhandled")
        if !handled { window.sendEvent(event) }
        interactionTrace?.record("after-key", supplied: event)
    }
    private func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func nativeClick(_ button: NSButton) throws {
        guard let trace = interactionTrace else { try PortableSettingsUIPreviewFixture.click(button); return }
        trace.record("before-click", button: button)
        // Exact existing PortableSettingsUIPreviewFixture button route, expanded
        // here only to capture the supplied down/up identities. In particular,
        // keep direct mouseDown, event numbers, +0.01 release clock and no wait.
        _ = try XCTUnwrap(button.isEnabled && !button.isHiddenOrHasHiddenAncestor ? true : nil, "Native button unavailable")
        let point = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        let window = try XCTUnwrap(button.window), root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let location = button.convert(point, to: nil)
        let local = root.convert(location, from: nil)
        let hit = root.hitTest(root.convert(local, to: root.superview))
        _ = try XCTUnwrap(hit === button || hit?.isDescendant(of: button) == true ? true : nil, "Native mouse target obscured")
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: down.timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        trace.record("supplied-mouse-down", button: button, supplied: down)
        trace.record("supplied-mouse-up", button: button, supplied: up)
        NSApp.postEvent(up, atStart: true)
        trace.record("before-direct-mouseDown", button: button, supplied: down)
        button.mouseDown(with: down)
        trace.record("after-direct-mouseDown", button: button, supplied: down)
    }
}

/// Matches the parent SettingsWindow's recorder-first contract. Integration tests
/// additionally exercise the actual SettingsController Save/Cancel boundary.
@MainActor private final class LocalShortcutDraftFixtureWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let button = firstResponder as? LocalAnnotationShortcutCaptureButton, button.isRecording { button.keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Bounded test-only scalar trace. It never changes a target/action, reads event
/// characters or spins the run loop. Printing is deferred until the sequence ends
/// so logging I/O cannot repair the rapid-click timing under investigation.
@MainActor private final class LocalShortcutInteractionTrace {
    private weak var view: LocalAnnotationShortcutSettingsView?
    private var rows: [[String: Any]] = []
    private var truncated = false
    init(view: LocalAnnotationShortcutSettingsView) { self.view = view }
    func record(_ phase: String, button: NSButton? = nil, supplied: NSEvent? = nil, detail: String? = nil) {
        guard rows.count < 160 else { truncated = true; return }
        guard let view else { return }
        let window = view.window, responder = window?.firstResponder
        var row: [String: Any] = ["index": rows.count, "phase": phase,
            "observedAt": ProcessInfo.processInfo.systemUptime,
            "selectedRow": view.tableView.selectedRow, "selectedTool": view.selectedTool?.rawValue ?? "none",
            "draftBindings": view.draft.bindings.map { ["tool": $0.tool.rawValue, "keyCode": $0.binding.keyCode, "modifiers": $0.binding.modifiers] as [String: Any] },
            "captureBinding": view.captureButton.binding.map { ["keyCode": $0.keyCode, "modifiers": $0.modifiers] as [String: Any] } ?? [:],
            "recording": view.captureButton.isRecording, "captureEnabled": view.captureButton.isEnabled,
            "clearEnabled": view.clearButton.isEnabled, "resetEnabled": view.restoreDefaultsButton.isEnabled,
            "windowNumber": window?.windowNumber ?? -1, "windowIsKey": window?.isKeyWindow ?? false,
            "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? -1, "applicationIsActive": NSApp.isActive,
            "applicationIsRunning": NSApp.isRunning,
            "firstResponderClass": responder.map { String(describing: type(of: $0)) } ?? "none",
            "firstResponderIdentifier": (responder as? NSView)?.identifier?.rawValue ?? "none",
            "currentEvent": eventFields(NSApp.currentEvent), "suppliedEvent": eventFields(supplied)]
        if let detail { row["detail"] = detail }
        if let button {
            row["button"] = button.identifier?.rawValue ?? "unknown"
            row["action"] = button.action.map(NSStringFromSelector) ?? "none"
            row["targetClass"] = button.target.map { String(describing: type(of: $0)) } ?? "none"
            row["buttonHighlighted"] = button.cell?.isHighlighted ?? false
            row["buttonFrameInWindow"] = NSStringFromRect(button.convert(button.bounds, to: nil))
        }
        rows.append(row)
    }
    private func eventFields(_ event: NSEvent?) -> [String: Any] {
        guard let event else { return ["present": false] }
        var value: [String: Any] = ["present": true, "type": Int(event.type.rawValue),
            "windowNumber": event.windowNumber, "timestamp": event.timestamp,
            "quartzTimestamp": event.cgEvent.map { $0.timestamp as Any } ?? NSNull(),
            "location": [event.locationInWindow.x, event.locationInWindow.y],
            "modifiers": event.modifierFlags.rawValue]
        if [.keyDown, .keyUp, .flagsChanged].contains(event.type) {
            value["keyCode"] = event.keyCode
            if event.type != .flagsChanged { value["isRepeat"] = event.isARepeat }
        }
        if [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) {
            value["eventNumber"] = event.eventNumber; value["clickCount"] = event.clickCount
        }
        return value
    }
    func emit(test: String) {
        let value: [String: Any] = ["test": test, "rows": rows, "truncated": truncated,
            "maximumRows": 160, "route": "unchanged-direct-button-mouseDown", "ordinaryTextRead": false]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 262_144 else {
            XCTFail("Local shortcut interaction trace exceeded its 256 KiB bound or could not encode"); return
        }
        print("LocalAnnotationShortcut interaction trace: " + String(decoding: data, as: UTF8.self))
        XCTAssertFalse(truncated, "Local shortcut interaction trace exhausted its row bound")
    }
}
