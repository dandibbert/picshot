import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor private final class PinTextTestApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}

/// Owned AppKit windows and native button/key routes. These author executable
/// macOS coverage; source inspection on another platform is not a native pass.
@MainActor final class PinTextEditNativeTests: XCTestCase {
    func testContextActionSavePersistsBeforeDisplayInLightAndDark() throws {
        try withApplicationLoop { [self] in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let original = PinTextContent(text: "Saved original\n原文 🐱")
                let pin = try makePin(original, appearance: appearance); defer { pin.close() }
                var committed = original, calls = 0
                pin.onUpdateText = { next, expected in
                    calls += 1
                    XCTAssertEqual(expected, original); XCTAssertEqual(pin.richDocument?.text, original)
                    XCTAssertEqual(pin.textDisplayView.string, original.plainText)
                    pin.textEditController?.saveDraft() // Reentrant Save must coalesce.
                    committed = next
                }
                try activate("pin-text-edit", on: pin)
                let editor = try XCTUnwrap(pin.textEditController), window = try XCTUnwrap(editor.window)
                try show(window); XCTAssertTrue(window.firstResponder === editor.textView)
                XCTAssertTrue(try XCTUnwrap(pin.window).attachedSheet === window)
                XCTAssertFalse(pin.canParticipateInGroupTransform)
                XCTAssertFalse(editor.textView.allowsUndo); XCTAssertNil(editor.textView.undoManager)
                let replacement = "First line\n多行中文 👩🏽‍💻\nLast 🐱"
                replace(editor.textView, with: replacement)
                XCTAssertEqual(editor.textView.string, replacement)
                XCTAssertEqual(committed, original); XCTAssertEqual(pin.textDisplayView.string, original.plainText)
                try assertVisibleControls(editor)
                try PortableSettingsUIPreviewFixture.click(editor.saveButton)
                XCTAssertEqual(calls, 1); XCTAssertEqual(committed.plainText, replacement)
                XCTAssertEqual(pin.richDocument?.text, committed); XCTAssertEqual(pin.textDisplayView.string, replacement)
                XCTAssertNil(pin.textEditController); XCTAssertNil(pin.window?.attachedSheet)
                XCTAssertTrue(editor.completed); XCTAssertNil(editor.saveButton.target)
                editor.saveDraft(); XCTAssertEqual(calls, 1)
                XCTAssertTrue(pin.canParticipateInGroupTransform)
                let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                pin.copyText(to: board); XCTAssertEqual(board.string(forType: .string), replacement)
            }
        }
    }

    func testDiskFailureKeepsDraftAndSavedCopyUntilExplicitRetry() throws {
        try withApplicationLoop { [self] in
            let original = PinTextContent(text: "original")
            let pin = try makePin(original); defer { pin.close() }
            var failed = true, calls = 0, saved = original
            pin.onUpdateText = { next, expected in
                calls += 1; XCTAssertEqual(expected, original)
                if failed { throw CocoaError(.fileWriteOutOfSpace) }; saved = next
            }
            try activate("pin-text-edit", on: pin)
            let editor = try XCTUnwrap(pin.textEditController); try show(try XCTUnwrap(editor.window))
            let draft = "unsaved\n草稿 🧑‍🚀"; replace(editor.textView, with: draft)
            let selection = NSRange(location: 2, length: 3); editor.textView.setSelectedRange(selection)
            try PortableSettingsUIPreviewFixture.click(editor.saveButton)
            XCTAssertFalse(editor.completed); XCTAssertFalse(editor.isSaving); XCTAssertTrue(editor.saveButton.isEnabled)
            XCTAssertFalse(editor.errorLabel.stringValue.isEmpty); XCTAssertEqual(editor.textView.string, draft)
            XCTAssertEqual(editor.textView.selectedRange(), selection)
            XCTAssertEqual(saved, original); XCTAssertEqual(pin.richDocument?.text, original)
            XCTAssertEqual(pin.textDisplayView.string, original.plainText)
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            pin.copyText(to: board); XCTAssertEqual(board.string(forType: .string), original.plainText)
            failed = false; try PortableSettingsUIPreviewFixture.click(editor.saveButton)
            XCTAssertEqual(calls, 2); XCTAssertEqual(saved.plainText, draft); XCTAssertNil(pin.textEditController)
        }
    }

    func testCancelEscapeWindowCloseAndOwnerCloseDiscardWithoutSaving() throws {
        try withApplicationLoop { [self] in
            let original = PinTextContent(text: "original")
            let pin = try makePin(original); defer { pin.close() }
            var calls = 0; pin.onUpdateText = { _, _ in calls += 1 }
            for route in 0..<4 {
                try show(try XCTUnwrap(pin.window)); try activate("pin-text-edit", on: pin)
                let editor = try XCTUnwrap(pin.textEditController), window = try XCTUnwrap(editor.window)
                try show(window); replace(editor.textView, with: "discard me 🐱")
                switch route {
                case 0: try PortableSettingsUIPreviewFixture.click(editor.cancelButton)
                case 1: try send(window, code: 53, characters: "\u{1b}")
                case 2: window.performClose(nil)
                default: pin.dismissTextEditors()
                }
                XCTAssertTrue(editor.completed); XCTAssertNil(pin.textEditController)
                XCTAssertNil(pin.window?.attachedSheet); XCTAssertNil(editor.window?.contentView)
                XCTAssertEqual(editor.textView.string, ""); XCTAssertEqual(editor.history.retainedHistoryBytes, 0)
                editor.saveDraft(); XCTAssertEqual(calls, 0); XCTAssertEqual(pin.richDocument?.text, original)
            }
            try activate("pin-text-edit", on: pin)
            let retained = try XCTUnwrap(pin.textEditController)
            pin.close(); retained.saveDraft()
            XCTAssertTrue(retained.completed); XCTAssertNil(retained.onDismiss)
            XCTAssertNil(pin.richDocument); XCTAssertNil(pin.onUpdateText); XCTAssertNil(pin.onRename)
            XCTAssertEqual(calls, 0)
        }
    }

    func testMarkedInputSurvivesSaveAndEscapeUntilCommitted() throws {
        try withApplicationLoop { [self] in
            let pin = try makePin(PinTextContent(text: "base")); defer { pin.close() }
            var saved: PinTextContent?
            pin.onUpdateText = { next, _ in saved = next }
            try activate("pin-text-edit", on: pin)
            let editor = try XCTUnwrap(pin.textEditController), window = try XCTUnwrap(editor.window)
            try show(window); editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
            editor.textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(editor.textView.hasMarkedText()); XCTAssertEqual(editor.history.current.text, "base")
            try send(window, code: 1, characters: "s", flags: .command)
            XCTAssertTrue(editor.textView.hasMarkedText()); XCTAssertNil(saved); XCTAssertFalse(editor.completed)
            XCTAssertFalse(editor.errorLabel.stringValue.isEmpty)
            XCTAssertFalse(window.performKeyEquivalent(with: try key(window, code: 53, characters: "\u{1b}")), "Input method must get first refusal on Escape")
            XCTAssertFalse(editor.completed)
            editor.textView.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(editor.textView.hasMarkedText()); XCTAssertEqual(editor.textView.string, "base字")
            try send(window, code: 36, characters: "\r")
            XCTAssertEqual(editor.textView.string, "base字\n"); XCTAssertNil(saved)
            try send(window, code: 1, characters: "s", flags: .command)
            XCTAssertEqual(saved?.plainText, "base字\n"); XCTAssertNil(pin.textEditController)
        }
    }

    func testUTF8LimitInvalidInputAndEmptySaveKeepOriginal() throws {
        try withApplicationLoop { [self] in
            let original = PinTextContent(text: String(repeating: "🐱", count: PinTextContent.maximumUTF8Bytes / 4))
            let pin = try makePin(original); defer { pin.close() }
            var calls = 0; pin.onUpdateText = { _, _ in calls += 1 }
            try activate("pin-text-edit", on: pin)
            let editor = try XCTUnwrap(pin.textEditController); try show(try XCTUnwrap(editor.window))
            editor.textView.setSelectedRange(NSRange(location: (original.plainText as NSString).length, length: 0))
            editor.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(editor.textView.string, original.plainText); XCTAssertFalse(editor.errorLabel.stringValue.isEmpty)
            editor.textView.insertText("\0", replacementRange: NSRange(location: 0, length: 2))
            XCTAssertEqual(editor.textView.string, original.plainText); XCTAssertFalse(editor.errorLabel.stringValue.isEmpty)
            replace(editor.textView, with: "")
            try PortableSettingsUIPreviewFixture.click(editor.saveButton)
            XCTAssertFalse(editor.completed); XCTAssertFalse(editor.errorLabel.stringValue.isEmpty); XCTAssertEqual(calls, 0)
            XCTAssertEqual(pin.richDocument?.text, original)
            replace(editor.textView, with: original.plainText)
            editor.textView.setSelectedRange(NSRange(location: (original.plainText as NSString).length, length: 0))
            editor.textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(editor.textView.hasMarkedText())
            editor.textView.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(editor.textView.hasMarkedText()); XCTAssertEqual(editor.textView.string, original.plainText)
            XCTAssertFalse(editor.errorLabel.stringValue.isEmpty); XCTAssertEqual(calls, 0)
        }
    }

    func testOversizedMarkedReplacementAndInsertLeaveCompositionAndHistoryUntouched() throws {
        try withApplicationLoop { [self] in
            let original = PinTextContent(text: String(repeating: "a", count: PinTextContent.maximumUTF8Bytes))
            let pin = try makePin(original); defer { pin.close() }
            var calls = 0; pin.onUpdateText = { _, _ in calls += 1 }
            try activate("pin-text-edit", on: pin)
            let editor = try XCTUnwrap(pin.textEditController), window = try XCTUnwrap(editor.window)
            try show(window)
            editor.textView.setSelectedRange(NSRange(location: (original.plainText as NSString).length, length: 0))
            // This valid provisional composition uses the entire 16 KiB allowance.
            let marked = String(repeating: "拼", count: PinTextEditController.provisionalAllowanceUTF8Bytes / 3) + "a"
            XCTAssertEqual(marked.utf8.count, PinTextEditController.provisionalAllowanceUTF8Bytes)
            editor.textView.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(editor.textView.hasMarkedText())
            XCTAssertEqual(editor.textView.string.utf8.count, PinTextEditController.maximumProvisionalUTF8Bytes)
            let before = editor.textView.string, range = editor.textView.markedRange(), selection = editor.textView.selectedRange()
            let current = editor.history.current, undo = editor.history.undoStates, redo = editor.history.redoStates
            // Input itself fits the ceiling; replacing the existing composition
            // would exceed total live draft capacity by exactly one byte.
            let rejected = marked + "x"
            editor.textView.setMarkedText(rejected, selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(editor.textView.string, before); XCTAssertEqual(editor.textView.markedRange(), range)
            XCTAssertEqual(editor.textView.selectedRange(), selection); XCTAssertTrue(editor.textView.hasMarkedText())
            XCTAssertEqual(editor.history.current, current); XCTAssertEqual(editor.history.undoStates, undo); XCTAssertEqual(editor.history.redoStates, redo)
            XCTAssertFalse(editor.errorLabel.stringValue.isEmpty)
            editor.textView.insertText(NSAttributedString(string: rejected), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(editor.textView.string, before); XCTAssertEqual(editor.textView.markedRange(), range)
            XCTAssertEqual(editor.textView.selectedRange(), selection); XCTAssertTrue(editor.textView.hasMarkedText())
            XCTAssertEqual(editor.history.current, current); XCTAssertEqual(editor.history.undoStates, undo); XCTAssertEqual(editor.history.redoStates, redo)
            XCTAssertEqual(pin.richDocument?.text, original); XCTAssertEqual(calls, 0)
            // A smaller explicit replacement still commits normally after both refusals.
            editor.textView.insertText("edited 中文 🐱", replacementRange: NSRange(location: 0, length: (before as NSString).length))
            XCTAssertFalse(editor.textView.hasMarkedText()); XCTAssertEqual(editor.textView.string, "edited 中文 🐱")
            XCTAssertEqual(editor.history.current.text, "edited 中文 🐱"); XCTAssertEqual(editor.history.undoStates.count, 1)
            XCTAssertEqual(calls, 0)
        }
    }

    func testRenameFieldBoundsMarkedInputAndPasteWithoutChangingSavedNameLimit() throws {
        try withApplicationLoop { [self] in
            let pin = try makePin(PinTextContent(text: "Original content")); defer { pin.close() }
            var calls = 0, saved = pin.pinTitle
            pin.onRename = { next, _ in calls += 1; saved = next }
            try activate("pin-rename", on: pin)
            let editor = try XCTUnwrap(pin.renameController), window = try XCTUnwrap(editor.window)
            try show(window)
            let field = try XCTUnwrap(editor.nameField.currentEditor() as? PinDraftTextView)
            replace(field, with: "Name")
            field.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let before = field.string, range = field.markedRange(), selection = field.selectedRange()
            let tooLarge = String(repeating: "a", count: PinRenameController.maximumDraftUTF8Bytes - 3)
            field.setMarkedText(tooLarge, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(field.string, before); XCTAssertEqual(field.markedRange(), range); XCTAssertEqual(field.selectedRange(), selection)
            XCTAssertTrue(field.hasMarkedText()); XCTAssertFalse(editor.errorLabel.stringValue.isEmpty)
            field.insertText(tooLarge, replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(field.string, before); XCTAssertEqual(field.markedRange(), range); XCTAssertEqual(field.selectedRange(), selection)
            XCTAssertTrue(field.hasMarkedText()); XCTAssertNil(field.undoManager); XCTAssertFalse(field.allowsUndo)
            field.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(field.hasMarkedText()); XCTAssertEqual(field.string, "Name字")
            let boundary = String(repeating: "n", count: PinRenameController.maximumDraftUTF8Bytes)
            replace(field, with: boundary); XCTAssertEqual(field.string, boundary)
            field.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(field.string, boundary); XCTAssertFalse(editor.errorLabel.stringValue.isEmpty)
            try PortableSettingsUIPreviewFixture.click(editor.saveButton)
            XCTAssertEqual(calls, 0); XCTAssertFalse(editor.completed); XCTAssertEqual(saved, "Original title")
            XCTAssertFalse(editor.errorLabel.stringValue.isEmpty, "The 120-character saved-name limit must remain enforced")
            let valid = String(repeating: "字", count: 120)
            replace(field, with: valid); try PortableSettingsUIPreviewFixture.click(editor.saveButton)
            XCTAssertEqual(saved, valid); XCTAssertEqual(calls, 1); XCTAssertNil(pin.renameController)
            XCTAssertEqual(pin.richDocument?.text?.plainText, "Original content")
        }
    }

    func testNativeUndoRedoUsesBoundedHistoryAndPreservesUnicode() throws {
        try withApplicationLoop { [self] in
            let pin = try makePin(PinTextContent(text: "原文")); defer { pin.close() }
            pin.onUpdateText = { _, _ in }
            try activate("pin-text-edit", on: pin)
            let editor = try XCTUnwrap(pin.textEditController), window = try XCTUnwrap(editor.window)
            try show(window); replace(editor.textView, with: "草稿 🐱\nsecond")
            XCTAssertTrue(editor.undoButton.isEnabled)
            try PortableSettingsUIPreviewFixture.click(editor.undoButton)
            XCTAssertEqual(editor.textView.string, "原文")
            XCTAssertTrue(window.makeFirstResponder(editor.textView))
            try send(window, code: 6, characters: "z", flags: [.command, .shift])
            XCTAssertEqual(editor.textView.string, "草稿 🐱\nsecond")
            try send(window, code: 6, characters: "z", flags: .command)
            XCTAssertEqual(editor.textView.string, "原文"); XCTAssertNil(editor.textView.undoManager)
            for index in 0..<30 { replace(editor.textView, with: "\(index) " + String(repeating: "🐱", count: 16_000)) }
            XCTAssertLessThanOrEqual(editor.history.undoStates.count + editor.history.redoStates.count, PinTextDraftHistory.maximumLevels)
            XCTAssertLessThanOrEqual(editor.history.retainedHistoryBytes, PinTextDraftHistory.maximumHistoryBytes)
        }
    }

    func testImportedRichTextCannotEditButRenameKeepsSelectionAndFormatting() throws {
        try withApplicationLoop { [self] in
            let rich = PinTextContent(runs: [PinTextRun(text: "Rich ", bold: true), PinTextRun(text: "中文 🐱", italic: true)], importedHTML: true)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let pin = try makePin(rich, appearance: appearance); defer { pin.close() }
                pin.onUpdateText = { _, _ in XCTFail("Imported text must never flatten") }
                let menu = try XCTUnwrap(pin.textDisplayView.menu)
                let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "pin-text-edit" })
                XCTAssertFalse(pin.validateMenuItem(item)); pin.editPlainText(); XCTAssertNil(pin.textEditController)
                XCTAssertTrue(menu.items.contains { $0.identifier?.rawValue == "pin-text-readonly" })
                let selection = NSRange(location: 0, length: 4); pin.textDisplayView.setSelectedRange(selection)
                let before = NSAttributedString(attributedString: pin.textDisplayView.attributedString())
                var fail = true, calls = 0, savedTitle = pin.pinTitle
                pin.onRename = { next, expected in
                    calls += 1; XCTAssertEqual(expected, "Original title")
                    if fail { throw CocoaError(.fileWriteOutOfSpace) }; savedTitle = next
                }
                try activate("pin-rename", on: pin)
                let editor = try XCTUnwrap(pin.renameController), window = try XCTUnwrap(editor.window)
                try show(window); XCTAssertFalse(pin.canParticipateInGroupTransform)
                let field = try XCTUnwrap(editor.nameField.currentEditor() as? NSTextView)
                XCTAssertTrue(window.firstResponder === field); replace(field, with: "新的名称 🐱")
                try assertVisibleControls(editor)
                try PortableSettingsUIPreviewFixture.click(editor.saveButton)
                XCTAssertFalse(editor.errorLabel.stringValue.isEmpty); XCTAssertEqual(pin.pinTitle, "Original title")
                XCTAssertEqual(pin.textDisplayView.selectedRange(), selection); XCTAssertEqual(pin.textDisplayView.attributedString(), before)
                fail = false; try PortableSettingsUIPreviewFixture.click(editor.saveButton)
                XCTAssertEqual(savedTitle, "新的名称 🐱"); XCTAssertEqual(pin.pinTitle, savedTitle); XCTAssertEqual(calls, 2)
                XCTAssertEqual(pin.richDocument?.text, rich); XCTAssertEqual(pin.textDisplayView.selectedRange(), selection)
                XCTAssertEqual(pin.textDisplayView.attributedString(), before); XCTAssertNil(pin.renameController)
            }
        }
    }

    func testOwnerClosedDuringCallbackCannotBeResurrected() throws {
        try withApplicationLoop { [self] in
            let pin = try makePin(PinTextContent(text: "original"))
            var calls = 0
            pin.onUpdateText = { _, _ in calls += 1; pin.close() }
            try activate("pin-text-edit", on: pin)
            let editor = try XCTUnwrap(pin.textEditController); try show(try XCTUnwrap(editor.window))
            replace(editor.textView, with: "new")
            try PortableSettingsUIPreviewFixture.click(editor.saveButton)
            XCTAssertEqual(calls, 1); XCTAssertTrue(editor.completed); XCTAssertNil(pin.richDocument)
            XCTAssertNil(pin.window?.contentView); XCTAssertNil(pin.textEditController)
            editor.saveDraft(); XCTAssertEqual(calls, 1)
        }
    }

    private func makePin(_ content: PinTextContent, appearance: NSAppearance.Name = .aqua) throws -> RichPinController {
        let prepared = try PreparedRichPin(document: PinRichDocument(text: content), title: "Original title")
        let pin = try RichPinController(asset: prepared.asset, data: prepared.data, title: prepared.title)
        do { let window = try XCTUnwrap(pin.window); window.appearance = NSAppearance(named: appearance); try show(window); return pin }
        catch { pin.close(); throw error }
    }
    private func activate(_ id: String, on pin: RichPinController) throws {
        let menu = try XCTUnwrap(pin.textDisplayView.menu)
        menu.update()
        let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == id })
        XCTAssertTrue(pin.validateMenuItem(item)); XCTAssertTrue(item.isEnabled)
        let index = menu.index(of: item); XCTAssertGreaterThanOrEqual(index, 0)
        menu.performActionForItem(at: index)
    }
    private func replace(_ view: NSTextView, with text: String) {
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    private func assertVisibleControls(_ editor: PinDraftSheetController) throws {
        let window = try XCTUnwrap(editor.window), root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let controls: [NSView] = [editor.saveButton, editor.cancelButton, editor.errorLabel]
        for control in controls {
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
            let rect = control.convert(control.bounds, to: root)
            XCTAssertGreaterThan(rect.width, 0); XCTAssertGreaterThan(rect.height, 0)
            XCTAssertTrue(root.bounds.contains(rect), "Owned draft control clipped: \(control.identifier?.rawValue ?? "unknown")")
        }
    }
    private func show(_ window: NSWindow) throws {
        window.animationBehavior = .none; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !window.isKeyWindow, ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        _ = try XCTUnwrap(window.isKeyWindow ? true : nil, "Owned pin draft window did not become key within one second")
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    private func key(_ window: NSWindow, code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    private func send(_ window: NSWindow, code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws {
        let event = try key(window, code: code, characters: characters, flags: flags)
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
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
        let state = PinTextTestApplicationLoop()
        defer {
            state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
            if NSApp.activationPolicy() != originalPolicy { _ = NSApp.setActivationPolicy(originalPolicy) }
            XCTAssertEqual(NSApp.activationPolicy(), originalPolicy)
            recordHostState("policy-restored")
        }
        if originalPolicy == .prohibited {
            _ = try XCTUnwrap(NSApp.setActivationPolicy(.accessory) ? true : nil,
                "Native pin text editor interaction requires an activatable owned application")
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
            print("PinTextEdit native host: " + String(decoding: data, as: UTF8.self))
        }
    }

}
