import AppKit
import PicShotCore
import XCTest
@testable import PicShot

@MainActor final class TextScriptControllerTests: XCTestCase {
    func testNativeNewSaveDiscardSelectionAndDeleteRemainExplicit() throws {
        try withApplicationLoop { [self] in
            let f = try fixture(); defer { f.close() }
            var writes = 0; f.store.beforeManifestCommit = { writes += 1 }
            try ready(f.controller)
            XCTAssertTrue(f.store.definitions.isEmpty); XCTAssertEqual(writes, 0)
            try click("create", in: f.controller)
            let source: NSTextView = try view("source", in: f.controller)
            let name: NSTextField = try view("name", in: f.controller)
            XCTAssertEqual(source.string, TextScriptController.exampleSource)
            XCTAssertEqual(writes, 0); XCTAssertFalse(try button("run", in: f.controller).isEnabled)
            name.selectText(nil)
            let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
            editor.insertText("工单编号", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            let literal = #"return 'Deliberately saved author literal';"#
            f.controller.window?.makeFirstResponder(source)
            source.insertText(literal, replacementRange: NSRange(location: 0, length: (source.string as NSString).length))
            XCTAssertEqual(writes, 0); XCTAssertTrue(f.store.definitions.isEmpty)
            try click("save", in: f.controller)
            XCTAssertEqual(writes, 1)
            let saved = try XCTUnwrap(f.store.definitions.first)
            XCTAssertEqual(saved.name, "工单编号"); XCTAssertEqual(saved.source, literal)
            XCTAssertEqual(f.store.selectedID, saved.id)
            XCTAssertEqual(try TextScriptStore(directory: f.directory).index, f.store.index)
            XCTAssertTrue(try button("run", in: f.controller).isEnabled)
            f.controller.window?.makeFirstResponder(source)
            source.insertText("return 'Unsaved literal';", replacementRange: NSRange(location: 0, length: (source.string as NSString).length))
            XCTAssertEqual(f.store.definition(id: saved.id), saved); XCTAssertEqual(writes, 1)
            try click("discard", in: f.controller)
            XCTAssertEqual(source.string, literal); XCTAssertEqual(writes, 1)
            try click("delete", in: f.controller)
            XCTAssertEqual(writes, 2); XCTAssertTrue(f.store.definitions.isEmpty); XCTAssertNil(f.store.selectedID)
            XCTAssertEqual(source.string, ""); XCTAssertFalse(try button("run", in: f.controller).isEnabled)
        }
    }

    func testNativeCommandSaveWhileNameIsFirstResponderCommitsOnceAndRestoresControls() throws {
        try withApplicationLoop { [self] in
            let f = try fixture()
            defer { f.store.beforeManifestCommit = nil; f.close() }
            try ready(f.controller)
            try click("create", in: f.controller)
            let window = try XCTUnwrap(f.controller.window)
            let name: NSTextField = try view("name", in: f.controller)
            let source: NSTextView = try view("source", in: f.controller)
            let saveButton = try button("save", in: f.controller)
            let discardButton = try button("discard", in: f.controller)
            let runButton = try button("run", in: f.controller)
            name.selectText(nil)
            let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
            let savedName = "键盘保存工单脚本"
            editor.insertText(savedName, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.string, savedName); XCTAssertFalse(editor.hasMarkedText())
            XCTAssertTrue(saveButton.isEnabled); XCTAssertFalse(runButton.isEnabled)
            XCTAssertTrue(f.store.definitions.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifest(f).path))
            let save = try textKey(window, "s", code: 1, flags: .command)
            var writes = 0, runs = 0
            f.controller.onRun = { _, _ in runs += 1 }
            f.store.beforeManifestCommit = {
                writes += 1
                XCTAssertFalse(saveButton.isEnabled); XCTAssertFalse(name.isEnabled)
                // A synchronous duplicate command during the atomic write must
                // stay blocked by isSaving, including after focus resignation.
                XCTAssertTrue(window.performKeyEquivalent(with: save))
            }
            // Do not move focus or click Save: this exercises the field editor's
            // synchronous resignation when Save disables the name field.
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(window.performKeyEquivalent(with: save))
            XCTAssertEqual(writes, 1); XCTAssertEqual(runs, 0)
            let saved = try XCTUnwrap(f.store.definitions.first)
            XCTAssertEqual(saved.name, savedName); XCTAssertEqual(saved.source, TextScriptController.exampleSource)
            XCTAssertEqual(f.store.selectedID, saved.id)
            XCTAssertEqual(try TextScriptStore(directory: f.directory).index, f.store.index)
            XCTAssertEqual(name.stringValue, savedName); XCTAssertEqual(source.string, saved.source)
            XCTAssertTrue(name.isEnabled); XCTAssertTrue(source.isEditable); XCTAssertTrue(runButton.isEnabled)
            XCTAssertFalse(saveButton.isEnabled); XCTAssertFalse(discardButton.isEnabled)
            XCTAssertTrue(f.controller.requestApplicationTermination())
            XCTAssertTrue(window.performKeyEquivalent(with: save)); XCTAssertEqual(writes, 1)
        }
    }

    func testNativeCommandSaveFailureWhileNameIsFirstResponderPreservesDraftAndRetriesAtomically() throws {
        try withApplicationLoop { [self] in
            let original = try definition(), f = try fixture([original])
            defer { f.store.beforeManifestCommit = nil; f.close() }
            try ready(f.controller)
            let window = try XCTUnwrap(f.controller.window)
            let name: NSTextField = try view("name", in: f.controller)
            let source: NSTextView = try view("source", in: f.controller)
            let saveButton = try button("save", in: f.controller)
            let discardButton = try button("discard", in: f.controller)
            let runButton = try button("run", in: f.controller)
            let before = f.store.index, bytes = try Data(contentsOf: manifest(f))
            let savedName = "失败后重试的名称"
            let draftName = "  " + savedName + "  "
            name.selectText(nil)
            let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
            editor.insertText(draftName, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.string, draftName); XCTAssertFalse(editor.hasMarkedText())
            let save = try textKey(window, "s", code: 1, flags: .command)
            var attempts = 0, accepted = 0, fail = true
            f.store.beforeManifestCommit = {
                attempts += 1
                if fail { throw TextScriptCatalogError.saveFailed }
                accepted += 1
            }
            XCTAssertTrue(window.performKeyEquivalent(with: save))
            XCTAssertEqual(attempts, 1); XCTAssertEqual(accepted, 0)
            XCTAssertEqual(f.store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(f)), bytes)
            XCTAssertEqual(try TextScriptStore(directory: f.directory).index, before)
            XCTAssertEqual(name.stringValue, draftName); XCTAssertEqual(source.string, original.source)
            XCTAssertTrue(name.isEnabled); XCTAssertTrue(source.isEditable)
            XCTAssertTrue(saveButton.isEnabled); XCTAssertTrue(discardButton.isEnabled); XCTAssertFalse(runButton.isEnabled)
            let status: NSTextField = try view("status", in: f.controller)
            XCTAssertEqual(status.stringValue, TextScriptCatalogError.saveFailed.errorDescription)
            XCTAssertFalse(f.controller.requestApplicationTermination())
            fail = false
            name.selectText(nil)
            let retryEditor = try XCTUnwrap(name.currentEditor() as? NSTextView)
            XCTAssertTrue(window.firstResponder === retryEditor)
            XCTAssertEqual(retryEditor.string, draftName); XCTAssertFalse(retryEditor.hasMarkedText())
            XCTAssertTrue(window.performKeyEquivalent(with: save))
            XCTAssertEqual(attempts, 2); XCTAssertEqual(accepted, 1)
            let saved = try XCTUnwrap(f.store.definition(id: original.id))
            XCTAssertEqual(saved.name, savedName); XCTAssertEqual(saved.source, original.source)
            XCTAssertEqual(name.stringValue, savedName)
            XCTAssertEqual(f.store.definitions, [saved]); XCTAssertEqual(f.store.selectedID, original.id)
            XCTAssertEqual(try TextScriptStore(directory: f.directory).index, f.store.index)
            XCTAssertTrue(name.isEnabled); XCTAssertTrue(source.isEditable); XCTAssertTrue(runButton.isEnabled)
            XCTAssertFalse(saveButton.isEnabled); XCTAssertFalse(discardButton.isEnabled)
            XCTAssertTrue(f.controller.requestApplicationTermination())
            XCTAssertTrue(window.performKeyEquivalent(with: save)); XCTAssertEqual(attempts, 2)
        }
    }

    func testFailedSaveRetainsExactDraftAndUsesOnlyFixedDiagnostics() throws {
        let original = try definition(), f = try fixture([original]); defer { f.close() }
        let source: NSTextView = try view("source", in: f.controller)
        let unsaved = "return 'this literal is not saved';"
        source.string = unsaved; changed(source, in: f.controller)
        let before = f.store.index, bytes = try Data(contentsOf: manifest(f))
        f.store.beforeManifestCommit = { throw NSError(domain: "PRIVATE_THROWN_SOURCE", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_USER_TEXT"]) }
        try press("save", in: f.controller)
        XCTAssertEqual(source.string, unsaved); XCTAssertEqual(f.store.index, before)
        XCTAssertEqual(try Data(contentsOf: manifest(f)), bytes)
        let status: NSTextField = try view("status", in: f.controller)
        XCTAssertEqual(status.stringValue, TextScriptCatalogError.saveFailed.errorDescription)
        XCTAssertFalse(status.stringValue.contains("PRIVATE")); XCTAssertEqual(status.textColor, .systemRed)
        XCTAssertFalse(try button("run", in: f.controller).isEnabled)
        f.controller.showError(NSError(domain: "PRIVATE_THROWN_SOURCE", code: 8,
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_USER_TEXT"]))
        XCTAssertEqual(status.stringValue, "操作未完成，请重试。")
        f.store.beforeManifestCommit = nil; try press("save", in: f.controller)
        XCTAssertEqual(f.store.definition(id: original.id)?.source, unsaved)
    }

    func testDirtySelectionCloseAndQuitKeepDraftUntilSaveOrDiscard() throws {
        try withApplicationLoop { [self] in
            let first = try definition(), second = try definition(name: "Second")
            let f = try fixture([first, second]); defer { f.close() }
            try ready(f.controller)
            let source: NSTextView = try view("source", in: f.controller)
            let table: NSTableView = try view("list", in: f.controller)
            var closed = 0; f.controller.onClose = { _ in closed += 1 }
            let before = f.store.index, bytes = try Data(contentsOf: manifest(f))
            source.string = "return 'unsaved';"; changed(source, in: f.controller)
            XCTAssertFalse(f.controller.tableView(table, shouldSelectRow: 1))
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            XCTAssertEqual(table.selectedRow, 0); XCTAssertEqual(source.string, "return 'unsaved';")
            f.controller.window?.performClose(nil); f.controller.close()
            XCTAssertTrue(f.controller.window?.isVisible == true); XCTAssertEqual(closed, 0)
            XCTAssertFalse(f.controller.requestApplicationTermination())
            XCTAssertEqual(source.string, "return 'unsaved';"); XCTAssertEqual(f.store.index, before)
            XCTAssertEqual(try Data(contentsOf: manifest(f)), bytes)
            try click("discard", in: f.controller)
            XCTAssertEqual(source.string, first.source); XCTAssertTrue(f.controller.requestApplicationTermination())
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            XCTAssertEqual(f.store.selectedID, second.id)
            XCTAssertEqual(try TextScriptStore(directory: f.directory).selectedID, second.id)
            source.string = "return text.trim();"; changed(source, in: f.controller)
            XCTAssertFalse(f.controller.requestApplicationTermination())
            try click("save", in: f.controller)
            XCTAssertTrue(f.controller.requestApplicationTermination())
            f.controller.window?.performClose(nil)
            XCTAssertFalse(f.controller.window?.isVisible ?? true); XCTAssertEqual(closed, 1)
            f.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: f.controller.window))
            XCTAssertEqual(closed, 1)
        }
    }

    func testNewDraftIsNotAutoSavedByCloseQuitSelectionOrReopen() throws {
        // Diagnostic-only fixed lifecycle markers. Direct stderr writes avoid
        // stdout buffering; no name, source, draft or runtime text is logged.
        let diagnostic = ProcessInfo.processInfo.environment["PICSHOT_TEXT_SCRIPT_LIFECYCLE_DIAGNOSTIC"] == "1"
        func phase(_ label: String, _ controller: TextScriptController? = nil) {
            guard diagnostic else { return }
            let application: NSApplication? = NSApp
            let running = application?.isRunning == true ? 1 : 0
            let active = application?.isActive == true ? 1 : 0
            let policy = application?.activationPolicy().rawValue ?? -1
            let visible: Int
            if let window = controller?.window { visible = window.isVisible ? 1 : 0 } else { visible = -1 }
            let line = "PICSHOT_TEXT_SCRIPT_LIFECYCLE phase=\(label) pid=\(ProcessInfo.processInfo.processIdentifier) running=\(running) active=\(active) policy=\(policy) visible=\(visible)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        phase("fixture-before")
        let f = try fixture()
        defer {
            phase("original-close-before", f.controller)
            f.close()
            phase("original-close-after", f.controller)
        }
        phase("fixture-after", f.controller)
        phase("first-new-before", f.controller)
        try press("create", in: f.controller)
        phase("first-new-after", f.controller)
        let source: NSTextView = try view("source", in: f.controller)
        phase("first-quit-before", f.controller)
        XCTAssertFalse(f.controller.requestApplicationTermination())
        phase("first-quit-after", f.controller)
        phase("dirty-close-before", f.controller)
        f.controller.close()
        phase("dirty-close-after", f.controller)
        XCTAssertEqual(source.string, TextScriptController.exampleSource)
        XCTAssertTrue(try TextScriptStore(directory: f.directory).definitions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest(f).path))
        phase("unsaved-assertions-after", f.controller)
        phase("discard-before", f.controller)
        try press("discard", in: f.controller)
        phase("discard-after", f.controller)
        XCTAssertEqual(source.string, "")
        phase("discarded-quit-before", f.controller)
        XCTAssertTrue(f.controller.requestApplicationTermination())
        phase("discarded-quit-after", f.controller)
        phase("second-new-before", f.controller)
        try press("create", in: f.controller)
        phase("second-new-after", f.controller)
        phase("save-before", f.controller)
        try press("save", in: f.controller)
        phase("save-after", f.controller)
        phase("saved-quit-before", f.controller)
        XCTAssertTrue(f.controller.requestApplicationTermination())
        phase("saved-quit-after", f.controller)
        phase("restored-init-before", f.controller)
        let restored = TextScriptController(store: try TextScriptStore(directory: f.directory))
        defer {
            phase("restored-close-before", restored)
            restored.close()
            phase("restored-close-after", restored)
        }
        phase("restored-init-after", restored)
        let restoredSource: NSTextView = try view("source", in: restored)
        XCTAssertEqual(restoredSource.string, TextScriptController.exampleSource)
        phase("restored-assertions-after", restored)
    }

    func testRunRequiresSavedCleanDefinitionAndCoalescesQueuedRequests() async throws {
        let original = try definition(), f = try fixture([original]); defer { f.close() }
        let source: NSTextView = try view("source", in: f.controller)
        var commands: [(UUID, UInt64)] = []
        f.controller.onRun = { commands.append(($0, $1)) }
        source.string = "return 'not saved';" // Even before its notification.
        try press("run", in: f.controller)
        await drainCommands(); XCTAssertTrue(commands.isEmpty)
        changed(source, in: f.controller); try press("discard", in: f.controller)
        try press("run", in: f.controller); try press("run", in: f.controller)
        await drainCommands()
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands[0].0, original.id)
        XCTAssertTrue(f.controller.isCurrentCommand(commands[0].1))
        XCTAssertFalse(try button("run", in: f.controller).isEnabled)
        f.controller.setRunActive(true)
        XCTAssertFalse(try button("save", in: f.controller).isEnabled)
        XCTAssertFalse(try button("create", in: f.controller).isEnabled)
        XCTAssertFalse(source.isEditable)
        try press("run", in: f.controller); await drainCommands(); XCTAssertEqual(commands.count, 1)
        f.controller.setRunActive(false)
        try press("run", in: f.controller); await drainCommands(); XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(f.store.definition(id: original.id), original)
    }

    func testQueuedRunInvalidatesForChangedCatalogCloseAndSupersedingEdits() async throws {
        let original = try definition(), f = try fixture([original]); defer { f.close() }
        var commands = 0; f.controller.onRun = { _, _ in commands += 1 }
        try press("run", in: f.controller)
        let generation = f.controller.commandGeneration
        try f.store.update(id: original.id, source: "return text.trim();")
        XCTAssertFalse(f.controller.isCurrentCommand(generation))
        await drainCommands(); XCTAssertEqual(commands, 0)
        let source: NSTextView = try view("source", in: f.controller)
        XCTAssertEqual(source.string, "return text.trim();")
        try press("run", in: f.controller); f.controller.close()
        await drainCommands(); XCTAssertEqual(commands, 0)
        f.controller.present(); try press("run", in: f.controller)
        source.string = "return 'raw pending edit';" // Guard even missing a delegate callback.
        await drainCommands(); XCTAssertEqual(commands, 0)
        XCTAssertTrue(try button("discard", in: f.controller).isEnabled, "A rejected queued command must release its pending reservation")
        try press("discard", in: f.controller)
        try press("run", in: f.controller); await drainCommands(); XCTAssertEqual(commands, 1)
    }

    func testExternalUpdateCannotReplaceDirtySourceOrExecuteStaleSavedVersion() async throws {
        let original = try definition(), f = try fixture([original]); defer { f.close() }
        let source: NSTextView = try view("source", in: f.controller)
        source.string = "return 'local draft';"; changed(source, in: f.controller)
        try f.store.update(id: original.id, source: "return 'new disk definition';")
        await drainCommands()
        XCTAssertEqual(source.string, "return 'local draft';")
        XCTAssertFalse(try button("run", in: f.controller).isEnabled)
        try press("discard", in: f.controller)
        XCTAssertEqual(source.string, "return 'new disk definition';")
        try f.store.remove(id: original.id); await drainCommands()
        XCTAssertEqual(source.string, ""); XCTAssertFalse(try button("run", in: f.controller).isEnabled)
    }

    func testNativePasteIMEAndNameLimitsRejectBeforeChangingTextOrMarkedRange() throws {
        try withApplicationLoop { [self] in
            let original = try definition(), f = try fixture([original]); defer { f.close() }
            try ready(f.controller)
            let source: NSTextView = try view("source", in: f.controller)
            let before = f.store.index, bytes = try Data(contentsOf: manifest(f))
            f.controller.window?.makeFirstResponder(source)
            source.insertText(String(repeating: "🐱", count: 4_096), replacementRange: NSRange(location: 0, length: (source.string as NSString).length))
            XCTAssertEqual(source.string.utf8.count, 16_384)
            let full = source.string, selected = source.selectedRange()
            source.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(source.string, full); XCTAssertEqual(source.selectedRange(), selected)
            let status: NSTextField = try view("status", in: f.controller)
            XCTAssertTrue(status.stringValue.contains("未加入")); XCTAssertEqual(status.textColor, .systemRed)
            // Marked input must be rejected before AppKit destroys a valid
            // existing composition. Use multibyte text for both paths.
            source.insertText("return text;", replacementRange: NSRange(location: 0, length: (source.string as NSString).length))
            source.setSelectedRange(NSRange(location: (source.string as NSString).length, length: 0))
            source.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(source.hasMarkedText())
            let marked = source.markedRange(), composition = source.string, compositionSelection = source.selectedRange()
            XCTAssertFalse(try button("save", in: f.controller).isEnabled)
            XCTAssertFalse(try button("run", in: f.controller).isEnabled)
            try press("save", in: f.controller); try press("run", in: f.controller)
            source.setMarkedText(String(repeating: "界", count: 6_000), selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(source.string, composition); XCTAssertEqual(source.markedRange(), marked)
            XCTAssertEqual(source.selectedRange(), compositionSelection); XCTAssertTrue(source.hasMarkedText())
            XCTAssertFalse(f.controller.requestApplicationTermination())
            XCTAssertTrue(source.hasMarkedText()); XCTAssertEqual(source.string, composition)
            XCTAssertEqual(f.store.index, before); XCTAssertEqual(try Data(contentsOf: manifest(f)), bytes)
            try click("discard", in: f.controller)
            XCTAssertFalse(source.hasMarkedText()); XCTAssertEqual(source.string, original.source)
            XCTAssertTrue(f.controller.requestApplicationTermination())
            // The actual shared field editor has its own 64-character/256-byte
            // bound and cannot grow an unbounded name before Save.
            let name: NSTextField = try view("name", in: f.controller)
            name.selectText(nil)
            let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
            let long = String(repeating: "🐱", count: 64)
            editor.insertText(long, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            XCTAssertEqual(editor.string, long)
            let nameSelection = editor.selectedRange()
            editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(editor.string, long); XCTAssertEqual(editor.selectedRange(), nameSelection)
            editor.insertText(String(repeating: "a", count: 100_000), replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            XCTAssertEqual(editor.string, long)
            editor.insertText("line\nbreak", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            XCTAssertEqual(editor.string, long)
            XCTAssertEqual(f.store.index, before)
            try click("discard", in: f.controller)
            XCTAssertEqual(name.stringValue, original.name)
        }
    }

    func testBoundedSourceUndoRedoPreservesExactLimitAndClearsOnSaveDiscardAndLoad() throws {
        try withApplicationLoop { [self] in
            let original = try TextScriptDefinition(name: "Undo boundary", source: String(repeating: "a", count: 16_384))
            let second = try definition(name: "Another script")
            let f = try fixture([original, second]); defer { f.close() }
            try ready(f.controller)
            let window = try XCTUnwrap(f.controller.window)
            let source: NSTextView = try view("source", in: f.controller)
            window.makeFirstResponder(source)
            source.setSelectedRange(NSRange(location: 2, length: 5))
            let replacement = String(repeating: "🐱", count: 4_095) + "abcd"
            XCTAssertEqual(replacement.utf8.count, 16_384)
            source.insertText(replacement, replacementRange: NSRange(location: 0, length: (source.string as NSString).length))
            let replacementSelection = source.selectedRange()
            XCTAssertEqual(source.string, replacement)
            XCTAssertEqual(f.controller.sourceUndoRetainedBytesForVerification, 16_384)
            let undo = try textKey(window, "z", code: 6, flags: .command)
            let redo = try textKey(window, "z", code: 6, flags: [.command, .shift])
            XCTAssertTrue(window.performKeyEquivalent(with: undo))
            XCTAssertEqual(source.string, original.source); XCTAssertEqual(source.selectedRange(), NSRange(location: 2, length: 5))
            XCTAssertTrue(window.performKeyEquivalent(with: redo))
            XCTAssertEqual(source.string, replacement); XCTAssertEqual(source.selectedRange(), replacementSelection)
            let retained = f.controller.sourceUndoRetainedBytesForVerification
            source.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(source.string, replacement); XCTAssertEqual(f.controller.sourceUndoRetainedBytesForVerification, retained)
            try click("save", in: f.controller)
            XCTAssertEqual(f.store.definition(id: original.id)?.source, replacement)
            XCTAssertEqual(f.controller.sourceUndoRetainedBytesForVerification, 0)
            window.makeFirstResponder(source)
            XCTAssertTrue(window.performKeyEquivalent(with: undo)); XCTAssertEqual(source.string, replacement)
            source.insertText("return text;", replacementRange: NSRange(location: 0, length: (source.string as NSString).length))
            XCTAssertGreaterThan(f.controller.sourceUndoRetainedBytesForVerification, 0)
            source.setSelectedRange(NSRange(location: (source.string as NSString).length, length: 0))
            source.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let marked = source.string, markedRange = source.markedRange()
            XCTAssertTrue(window.performKeyEquivalent(with: undo))
            XCTAssertEqual(source.string, marked); XCTAssertEqual(source.markedRange(), markedRange)
            let menuUndo = try XCTUnwrap(source.menu?.items.first)
            XCTAssertFalse(f.controller.validateMenuItem(menuUndo))
            try click("discard", in: f.controller)
            XCTAssertEqual(source.string, replacement); XCTAssertEqual(f.controller.sourceUndoRetainedBytesForVerification, 0)
            let table: NSTableView = try view("list", in: f.controller)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            XCTAssertEqual(source.string, second.source); XCTAssertEqual(f.controller.sourceUndoRetainedBytesForVerification, 0)
            window.makeFirstResponder(source)
            XCTAssertTrue(window.performKeyEquivalent(with: redo)); XCTAssertEqual(source.string, second.source)
        }
    }

    func testUndoHistoryHasBoundedLevelsAndBytesAcrossRepeatedNearLimitEdits() {
        var history = TextScriptDraftHistory()
        let original = String(repeating: "a", count: 16_384)
        history.reset(original)
        for value in 1...30 {
            let next = String(repeating: "a", count: 16_382) + String(format: "%02d", value)
            history.record(next, selection: NSRange(location: 16_384, length: 0))
            XCTAssertLessThanOrEqual(history.undoStates.count + history.redoStates.count, TextScriptDraftHistory.maximumLevels)
            XCTAssertLessThanOrEqual(history.retainedBytes, TextScriptDraftHistory.maximumHistoryBytes)
        }
        let last = history.current.text
        var undone = 0
        while history.undo() { undone += 1; XCTAssertLessThanOrEqual(history.retainedBytes, TextScriptDraftHistory.maximumHistoryBytes) }
        XCTAssertEqual(undone, 12)
        var redone = 0
        while history.redo() { redone += 1; XCTAssertLessThanOrEqual(history.retainedBytes, TextScriptDraftHistory.maximumHistoryBytes) }
        XCTAssertEqual(redone, 12); XCTAssertEqual(history.current.text, last)
        history.record(String(repeating: "x", count: 16_385), selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(history.current.text, last)
        history.reset("return text;")
        XCTAssertEqual(history.retainedBytes, 0); XCTAssertFalse(history.undo()); XCTAssertFalse(history.redo())
    }

    func testNativeEscapeAndCommandSaveRespectCompositionAndDirtyClose() throws {
        try withApplicationLoop { [self] in
            let f = try fixture([definition()]); defer { f.close() }
            try ready(f.controller)
            let window = try XCTUnwrap(f.controller.window)
            let source: NSTextView = try view("source", in: f.controller)
            window.makeFirstResponder(source)
            source.setSelectedRange(NSRange(location: (source.string as NSString).length, length: 0))
            source.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let before = f.store.index, composition = source.string
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertFalse(window.performKeyEquivalent(with: escape))
            XCTAssertTrue(source.hasMarkedText()); XCTAssertEqual(source.string, composition)
            let save = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
            XCTAssertTrue(window.performKeyEquivalent(with: save))
            XCTAssertEqual(f.store.index, before); XCTAssertTrue(source.hasMarkedText())
            source.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(source.hasMarkedText())
            XCTAssertTrue(window.performKeyEquivalent(with: escape))
            XCTAssertTrue(window.isVisible); XCTAssertEqual(f.store.index, before)
            XCTAssertTrue(window.performKeyEquivalent(with: save))
            XCTAssertEqual(f.store.definitions[0].source, source.string)
            XCTAssertTrue(window.performKeyEquivalent(with: escape)); XCTAssertFalse(window.isVisible)
        }
    }

    func testRunStaysDisabledWhileNativeSourceOrNameIsBeingEditedEvenWhenClean() throws {
        try withApplicationLoop { [self] in
            let f = try fixture([definition()]); defer { f.close() }
            try ready(f.controller)
            let source: NSTextView = try view("source", in: f.controller)
            f.controller.window?.makeFirstResponder(source)
            XCTAssertFalse(try button("run", in: f.controller).isEnabled)
            var runs = 0; f.controller.onRun = { _, _ in runs += 1 }
            try press("run", in: f.controller)
            XCTAssertEqual(runs, 0)
            let table: NSTableView = try view("list", in: f.controller)
            f.controller.window?.makeFirstResponder(table)
            XCTAssertTrue(try button("run", in: f.controller).isEnabled)
            let name: NSTextField = try view("name", in: f.controller)
            name.selectText(nil)
            XCTAssertFalse(try button("run", in: f.controller).isEnabled)
            f.controller.window?.makeFirstResponder(table)
            XCTAssertTrue(try button("run", in: f.controller).isEnabled)
        }
    }

    func testNativeLightDarkControlsFitFullFramesAtMinimumSizeAndLongNamesRemainAccessible() throws {
        try withApplicationLoop { [self] in
            let long = String(repeating: "长名称", count: 20)
            let f = try fixture([definition(name: long)]); defer { f.close() }
            let window = try XCTUnwrap(f.controller.window)
            window.setContentSize(NSSize(width: 600, height: 560))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                try ready(f.controller, appearance: appearance)
                let root = try XCTUnwrap(window.contentView)
                let controls = try ["create", "save", "discard", "delete", "run", "close", "name"].map {
                    try view($0, in: f.controller) as NSControl
                }
                let frames = controls.map { $0.convert($0.bounds, to: root) }
                for (control, frame) in zip(controls, frames) {
                    XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertTrue(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), control.identifier?.rawValue ?? "")
                    XCTAssertFalse(control.accessibilityLabel()?.isEmpty ?? true)
                }
                for i in frames.indices {
                    for j in frames.indices where j > i {
                        XCTAssertFalse(frames[i].insetBy(dx: 0.5, dy: 0.5).intersects(frames[j].insetBy(dx: 0.5, dy: 0.5)))
                    }
                }
                for id in ["list-scroll", "source-scroll", "signature", "status", "route", "byte-count"] {
                    let control: NSView = try view(id, in: f.controller)
                    XCTAssertTrue(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(control.convert(control.bounds, to: root)), id)
                }
                let name: NSTextField = try view("name", in: f.controller)
                XCTAssertEqual(name.stringValue, long); XCTAssertEqual(name.toolTip, long)
                XCTAssertEqual(name.accessibilityValue() as? String, long)
                let table: NSTableView = try view("list", in: f.controller)
                let cell = try XCTUnwrap(f.controller.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSTextField)
                XCTAssertEqual(cell.toolTip, long); XCTAssertEqual(cell.accessibilityLabel(), long)
                let signature: NSTextField = try view("signature", in: f.controller)
                XCTAssertEqual(signature.stringValue, "function transform(text) {")
                XCTAssertFalse(signature.isEditable)
            }
        }
    }

    private struct Fixture {
        let directory: URL
        let store: TextScriptStore
        let controller: TextScriptController
        @MainActor func close() {
            controller.onRun = nil; controller.onClose = nil; controller.invalidateCommands()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func fixture(_ definitions: [TextScriptDefinition] = []) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-TextScriptUI-" + UUID().uuidString)
        let store = try TextScriptStore(directory: directory)
        for (index, definition) in definitions.enumerated() { try store.add(definition, select: index == 0) }
        return Fixture(directory: directory, store: store, controller: TextScriptController(store: store))
    }
    private func definition(name: String = "工作文字") throws -> TextScriptDefinition {
        try TextScriptDefinition(name: name, source: "return text;")
    }
    private func manifest(_ f: Fixture) -> URL { f.directory.appendingPathComponent(TextScriptStore.manifestFilename) }
    private func view<T: NSView>(_ suffix: String, in controller: TextScriptController) throws -> T {
        let root = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "text-script-" + suffix } as? T)
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func button(_ suffix: String, in controller: TextScriptController) throws -> NSButton { try view(suffix, in: controller) }
    private func press(_ suffix: String, in controller: TextScriptController) throws {
        let button = try button(suffix, in: controller)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
    }
    private func click(_ suffix: String, in controller: TextScriptController) throws {
        try PortableSettingsUIPreviewFixture.click(button(suffix, in: controller))
    }
    private func changed(_ source: NSTextView, in controller: TextScriptController) {
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: source))
    }
    private func drainCommands() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func textKey(_ window: NSWindow, _ value: String, code: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
    private func ready(_ controller: TextScriptController, appearance: NSAppearance.Name = .aqua) throws {
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: appearance); window.animationBehavior = .none
        controller.present(); NSApp.activate(ignoringOtherApps: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !window.isKeyWindow, ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        _ = try XCTUnwrap(window.isKeyWindow ? true : nil, "Owned text-script window did not become key")
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }

    private func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        _ = NSApplication.shared
        if NSApp.isRunning { try body(); return }
        _ = try XCTUnwrap(NSApp.modalWindow == nil && NSApp.delegate == nil ? true : nil,
            "Standalone UI host unexpectedly has a modal window or application delegate")
        _ = try XCTUnwrap(UserDefaults.standard.object(forKey: "NSOpen") == nil ? true : nil,
            "Standalone UI host unexpectedly has a file-open request")
        let originalPolicy = NSApp.activationPolicy(), state = TextScriptTestApplicationLoop()
        defer {
            state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
            if NSApp.activationPolicy() != originalPolicy { _ = NSApp.setActivationPolicy(originalPolicy) }
            XCTAssertEqual(NSApp.activationPolicy(), originalPolicy)
        }
        if originalPolicy == .prohibited {
            _ = try XCTUnwrap(NSApp.setActivationPolicy(.accessory) ? true : nil,
                "Native text-script interaction requires an activatable owned application")
        }
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        func finish(_ result: Result<Void, Error>) {
            guard state.acceptsCallbacks, state.result == nil else { return }
            state.timer?.invalidate(); state.timer = nil; state.result = result
            NSApp.stop(nil); NSApp.postEvent(wake, atStart: true)
        }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                guard state.acceptsCallbacks else { return }
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard state.acceptsCallbacks, state.result == nil else { return }
                        if NSApp.isRunning && !state.activationRequested {
                            state.activationRequested = true; NSApp.activate(ignoringOtherApps: true)
                        }
                        if NSApp.isRunning && NSApp.isActive {
                            state.timer?.invalidate(); state.timer = nil; finish(Result { try body() })
                        } else if ProcessInfo.processInfo.systemUptime >= deadline {
                            finish(.failure(NSError(domain: "PicShot.TextScriptUITestHost", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Owned application loop did not become active within one second"])))
                        }
                    }
                }
                state.timer = timer; RunLoop.main.add(timer, forMode: .default)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain()); NSApp.run()
        state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
        XCTAssertFalse(NSApp.isRunning)
        try XCTUnwrap(state.result, "Owned application loop exited before its test body completed").get()
    }
}

@MainActor private final class TextScriptTestApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}
