import AppKit
import CryptoKit
import PicShotCore

/// Bounded acceptance in the installed app. Synthetic pins live in a private
/// temporary session. Input targets only owned AppKit windows; no desktop capture.
@MainActor enum PinManagementSmokeFixture {
    static let initialText = "Original note\n原始文字 🖼️"
    static let savedText = "Updated first line\n第二行：中文与 emoji 🧪✨\nThird line stays separate"
    static let checks: Set<String> = ["text-cancel-preserves-output", "text-save-reload-reopen", "text-undo-redo-bounded",
        "text-refusal-preserves-draft", "html-never-flattened", "image-and-text-direct-rename", "rename-cancel-refusal-duplicate",
        "native-group-order-boundaries-selection", "light-dark-complete-layout", "finite-owned-retirement"]
    private static let deadlineSeconds = 120.0
    private static let route = "PortableSettingsUIPreviewFixture.click/owned-hitTest-mouseDown"
    private static var diagnostic: PhaseDiagnostic?
    private static func trace(_ phase: String, _ fields: [String: Any] = [:]) { diagnostic?.record(phase, fields) }

    // Opt-in synthetic-fixture observation only. Direct descriptor writes retain
    // the last entered call even when a nested AppKit tracking loop never returns.
    // No user content, new input, waiting, acceptance predicate or timeout changes.
    @MainActor private final class PhaseDiagnostic {
        private let handle: FileHandle
        private let started = ProcessInfo.processInfo.systemUptime
        private var bytes = 0, rows = 0
        private var writeSeconds = 0.0
        private var failed = false
        init?(directory: String) {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("pin-phases.jsonl")
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let file = try? FileHandle(forWritingTo: url) else { return nil }
            handle = file
            record("diagnosticOpened", ["pid": Int(ProcessInfo.processInfo.processIdentifier),
                "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
                "maximumBytes": 262_144, "maximumRows": 2_048, "maximumRowBytes": 2_048,
                "syntheticDataOnly": true, "synchronousWritesAssessedAsOverhead": true])
        }
        func record(_ phase: String, _ fields: [String: Any]) {
            guard !failed, rows < 2_048 else { return }
            var row = fields
            row["phase"] = phase; row["sequence"] = rows
            row["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
            row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            row["priorWriteSeconds"] = writeSeconds
            guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                  data.count < 2_048, bytes + data.count + 1 <= 262_144 else {
                failed = true; FileHandle.standardError.write(Data("Pin diagnostic reached its finite byte/row bound\n".utf8)); return
            }
            data.append(10)
            let begin = ProcessInfo.processInfo.systemUptime
            do { try handle.write(contentsOf: data); bytes += data.count; rows += 1 }
            catch { failed = true; FileHandle.standardError.write(Data("Pin diagnostic descriptor write failed\n".utf8)) }
            writeSeconds += ProcessInfo.processInfo.systemUptime - begin
        }
        func close() {
            record("diagnosticClosed", ["writtenBytesBeforeClose": bytes, "writtenRowsBeforeClose": rows, "writeFailed": failed])
            try? handle.close()
        }
    }

    @discardableResult static func run(reportURL: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let start = Date(), directory = reportURL.deletingLastPathComponent(), files = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PICSHOT_PIN_UI_DIAGNOSTIC_DIRECTORY"] {
            diagnostic = PhaseDiagnostic(directory: path)
        }
        defer { diagnostic?.close(); diagnostic = nil }
        trace("fixtureEntered")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-PinManagement-" + UUID().uuidString)
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance; try? files.removeItem(at: temporary) }
        var owners: [WeakOwner] = [], visuals: [[String: Any]] = [], actions: [[String: Any]] = []
        var report: [String: Any] = ["schemaVersion": 1, "status": "running",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "overallDeadlineSeconds": deadlineSeconds, "maximumRasterPixels": 4_000_000,
            "userPreferencesWritten": false, "preferenceReadScope": "group manager reads restorePinSessionOnLaunch only",
            "globalInputPosted": false, "globalHotkeysRegistered": false, "permissionRequests": false,
            "networkUsed": false, "liveScreenCaptured": false, "ordinaryTextCaptured": false,
            "memoryStabilityAssessed": false, "canonicalTemporaryRoot": true,
            "scope": "Synthetic managed pins; owned local AppKit events and cached complete content views; weak ownership only"]
        do {
            report["executableSHA256"] = hash(try Data(contentsOf: required(Bundle.main.executableURL, "Executable absent")))
            report["infoPlistSHA256"] = hash(try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")))
            var flows: [[String: Any]] = []
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try require(Date().timeIntervalSince(start) < deadlineSeconds, "Overall deadline exceeded")
                trace("appearanceFlowEnter", ["appearance": mode])
                NSApp.appearance = NSAppearance(named: appearance)
                flows.append(try await flow(mode, temporary.appendingPathComponent(mode), directory, &owners, &visuals, &actions))
                trace("appearanceFlowReturn", ["appearance": mode])
            }
            report["flows"] = flows
            trace("resourceCyclesEnter")
            report["resourceCycles"] = try await cycles(temporary.appendingPathComponent("cycles"), &owners, deadline: start.addingTimeInterval(deadlineSeconds))
            trace("resourceCyclesReturn")
            try await until({ owners.allSatisfy(\.released) }, "Owned controller/window/content retained")
            report["ownership"] = ["controllerCount": owners.count, "retainedControllers": owners.filter { $0.controller != nil }.count,
                "retainedWindows": owners.filter { $0.window != nil }.count, "retainedContentViews": owners.filter { $0.content != nil }.count,
                "releaseDeadlineSeconds": 4, "allOwnedWindowsClosed": true]
            report["checks"] = checks.sorted(); report["status"] = "passed"
        } catch {
            trace("fixtureCaughtError", ["type": String(describing: type(of: error))])
            report["status"] = "failed"; report["error"] = error.localizedDescription
            for owner in owners { owner.controller?.close() }
        }
        report["visuals"] = visuals; report["actions"] = actions
        report["elapsedSeconds"] = Date().timeIntervalSince(start)
        let expected = ["draft", "text-rename", "image-rename", "order", "poster-before", "poster-after"].flatMap { category in
            ["light", "dark"].map { "pin-management-\(category)-\($0).png" }
        } + ["before", "after"].flatMap { stage in ["light", "dark"].map { "pin-management-text-\(stage)-\($0).json" } }
        let names = expected.filter { files.fileExists(atPath: directory.appendingPathComponent($0).path) }
        let fileData = try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        try require(fileData.allSatisfy { $0.count <= 1_048_576 } && fileData.reduce(0, { $0 + $1.count }) <= 4_194_304, "Evidence byte budget exceeded")
        report["fileSHA256"] = Dictionary(uniqueKeysWithValues: zip(names, fileData).map { ($0.0, hash($0.1)) })
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try require(encoded.count <= 262_144, "Report exceeds 256 KiB")
        trace("reportWriteEnter")
        try encoded.write(to: reportURL, options: .atomic)
        trace("reportWriteReturn")
        try require(report["status"] as? String == "passed", report["error"] as? String ?? "Native fixture failed")
        try require(Date().timeIntervalSince(start) < deadlineSeconds, "Overall deadline exceeded")
        return report
    }

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        try await run(reportURL: evidenceDirectory.appendingPathComponent("pin-management.json"))
    }

    private static func coordinator(_ store: PinSessionStore) -> PinSessionCoordinator {
        PinSessionCoordinator(store: store, desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
            ocrPreferences: PinOCRPreferences(defaults: nil))
    }

    private static func flow(_ mode: String, _ root: URL, _ directory: URL, _ owners: inout [WeakOwner],
                             _ visuals: inout [[String: Any]], _ actions: inout [[String: Any]]) async throws -> [String: Any] {
        let store = try PinSessionStore(directory: root), session = coordinator(store)
        defer { try? session.prepareForTermination() }
        var errors: [String] = []; session.onError = { errors.append($0.localizedDescription) }
        let group = try store.createGroup(name: "文字与参考", color: .purple)
        _ = try store.createGroup(name: "稍后查看", color: .green)
        try store.setActiveGroup(id: group.id)
        let textID = try session.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: initialText)), title: "文字便笺"))
        let html = PinTextContent(runs: [PinTextRun(text: "Keep bold", bold: true), PinTextRun(text: " 与 HTML", italic: true)], importedHTML: true)
        let htmlID = try session.add(rich: PreparedRichPin(document: PinRichDocument(text: html), title: "HTML 参考"))
        let imageID = try session.add(image: ImageEditorRenderer.makeSampleImage(), title: "图片参考")
        let text = try required(session.richControllers[textID], "Managed text absent")
        let htmlPin = try required(session.richControllers[htmlID], "Managed HTML absent")
        let image = try required(session.liveControllers[imageID], "Managed image absent")
        owners += [WeakOwner(text), WeakOwner(htmlPin), WeakOwner(image)]
        try session.flushPresentationChanges()
        let before = try required(store.entry(id: textID), "Text entry absent")
        let htmlBefore = try entryHash(store, htmlID), imageBefore = try entryHash(store, imageID)
        let originalData = try store.richData(id: textID), originalPoster = try poster(store, textID)
        try originalData.write(to: directory.appendingPathComponent("pin-management-text-before-\(mode).json"), options: .atomic)
        try originalPoster.write(to: directory.appendingPathComponent("pin-management-poster-before-\(mode).png"), options: .atomic)
        htmlPin.editPlainText()
        htmlPin.window?.contentView?.menu?.update()
        try require(htmlPin.textEditController == nil && htmlPin.richDocument?.text == html, "HTML opened a flattening editor")
        try require(htmlPin.window?.contentView?.menu?.items.contains { $0.identifier?.rawValue == "pin-text-edit" && $0.isEnabled } != true,
                    "HTML offered enabled plain-text editing")

        try show(text.window)
        text.editPlainText()
        let cancelled = try required(text.textEditController, "Text action did not open draft"); owners.append(WeakOwner(cancelled))
        text.editPlainText(); try require(text.textEditController === cancelled, "Repeated edit duplicated draft")
        try replace(cancelled.textView, with: "Cancelled\n取消 🛑")
        try click(cancelled.cancelButton, "text-cancel", mode, &actions)
        try await until({ text.textEditController == nil && text.window?.attachedSheet == nil }, "Cancel retained draft")
        try require(try store.richData(id: textID) == originalData && poster(store, textID) == originalPoster && entryHash(store, textID) == digest(before), "Cancel mutated persisted text")
        try output(text, expected: initialText)

        text.editPlainText()
        let draft = try required(text.textEditController, "Second draft absent"); owners.append(WeakOwner(draft))
        try replace(draft.textView, with: savedText)
        try click(draft.undoButton, "text-undo", mode, &actions)
        try require(draft.textView.string == initialText, "Native undo did not restore initial text")
        try click(draft.redoButton, "text-redo", mode, &actions)
        try require(draft.textView.string == savedText, "Native redo did not restore complete text")
        let historyLevels = draft.history.undoStates.count + draft.history.redoStates.count
        let historyBytes = draft.history.retainedHistoryBytes
        try require(historyLevels <= 12 && historyBytes <= 524_288 && draft.textView.undoManager == nil, "Draft history unbounded")
        visuals.append(try snapshot(try required(draft.window, "Draft window absent"), "draft", mode, directory,
            controls: [draft.undoButton, draft.redoButton, draft.cancelButton, draft.saveButton], textView: draft.textView))
        try click(draft.saveButton, "text-save", mode, &actions)
        try await until({ text.textEditController == nil && text.window?.attachedSheet == nil }, "Save retained draft")
        let saved = try required(store.entry(id: textID), "Saved text absent")
        let savedData = try store.richData(id: textID), savedPoster = try poster(store, textID)
        let committedManifest = try manifest(store)
        draft.saveDraft(); draft.saveButton.performClick(nil)
        try require(try manifest(store) == committedManifest, "Stale Save committed twice")
        try require(before.id == saved.id && before.groupID == saved.groupID && before.title == saved.title && before.presentation == saved.presentation,
                    "Text Save changed identity, group, title or presentation")
        try output(text, expected: savedText)
        try require(savedData != originalData && savedPoster != originalPoster, "Save failed to replace JSON/poster")
        try require(try entryHash(store, htmlID) == htmlBefore && entryHash(store, imageID) == imageBefore, "Text edit mutated another pin")
        try savedData.write(to: directory.appendingPathComponent("pin-management-text-after-\(mode).json"), options: .atomic)
        try savedPoster.write(to: directory.appendingPathComponent("pin-management-poster-after-\(mode).png"), options: .atomic)

        let savedCallback = text.onUpdateText
        var refused = 0
        text.onUpdateText = { _, _ in refused += 1; throw failure("Injected bounded persistence refusal") }
        text.editPlainText()
        let rejected = try required(text.textEditController, "Refusal draft absent"); owners.append(WeakOwner(rejected))
        try replace(rejected.textView, with: "Keep this unsaved draft\n保留 🧷")
        try click(rejected.saveButton, "text-refused-save", mode, &actions)
        try require(refused == 1 && !rejected.errorLabel.stringValue.isEmpty && rejected.textView.string == "Keep this unsaved draft\n保留 🧷" && text.textEditController === rejected,
                    "Refused save lost draft/error")
        try require(try store.richData(id: textID) == savedData && poster(store, textID) == savedPoster && manifest(store) == committedManifest, "Refusal mutated safe output")
        try output(text, expected: savedText)
        try click(rejected.cancelButton, "text-refused-cancel", mode, &actions)
        text.onUpdateText = savedCallback
        try await until({ text.textEditController == nil && text.window?.attachedSheet == nil }, "Rejected draft retained")

        trace("textRenameEnter", ["appearance": mode])
        let textRename = try await rename(kind: "text", id: textID, store: store, window: text.window,
            open: { text.renamePin() }, current: { text.renameController }, title: { text.pinTitle },
            getCallback: { text.onRename }, setCallback: { text.onRename = $0 }, mode, directory, &owners, &visuals, &actions)
        trace("textRenameReturn", ["appearance": mode])
        trace("imageRenameEnter", ["appearance": mode])
        let imageRename = try await rename(kind: "image", id: imageID, store: store, window: image.window,
            open: { image.renamePin() }, current: { image.renameController }, title: { image.pinTitle },
            getCallback: { image.onRename }, setCallback: { image.onRename = $0 }, mode, directory, &owners, &visuals, &actions)
        trace("imageRenameReturn", ["appearance": mode])
        try require(try entryHash(store, htmlID) == htmlBefore && htmlPin.richDocument?.text == html, "HTML content changed")
        trace("orderFlowEnter", ["appearance": mode])
        let order = try await orderFlow(store, group.id, mode, directory, &owners, &visuals)
        trace("orderFlowReturn", ["appearance": mode])
        let textBeforeClose = try required(store.entry(id: textID), "Text before close absent")
        text.close()
        try await until({ session.richControllers[textID] == nil }, "Close did not retire managed text")
        try require(store.entry(id: textID)?.isVisible == false, "Close did not archive text")
        try session.prepareForTermination()
        let reloadedStore = try PinSessionStore(directory: root), reopenedSession = coordinator(reloadedStore)
        defer { try? reopenedSession.prepareForTermination() }
        try reopenedSession.openPin(id: textID)
        let reopened = try required(reopenedSession.richControllers[textID], "Reload/reopen absent")
        for controller in reopenedSession.richControllers.values { owners.append(WeakOwner(controller)) }
        for controller in reopenedSession.liveControllers.values { owners.append(WeakOwner(controller)) }
        let reopenedIdentity = ObjectIdentifier(reopened)
        try reopenedSession.openPin(id: textID)
        try require(reopenedSession.richControllers[textID].map(ObjectIdentifier.init) == reopenedIdentity, "Repeated reopen duplicated controller")
        try output(reopened, expected: savedText)
        let reloaded = try required(reloadedStore.entry(id: textID), "Reloaded entry absent")
        try require(reloaded.id == textBeforeClose.id && reloaded.groupID == textBeforeClose.groupID && reloaded.title == textBeforeClose.title && reloaded.presentation == textBeforeClose.presentation,
                    "Reload changed title/group/presentation")
        try require(try reloadedStore.richData(id: textID) == savedData && poster(reloadedStore, textID) == savedPoster, "Reload changed bytes")
        try require(reloadedStore.groups.map(\.id) == store.groups.map(\.id) && errors.isEmpty, "Reload order or coordinator callback failed")
        try reopenedSession.prepareForTermination()
        return ["appearance": mode, "text": ["id": textID.uuidString, "groupID": group.id.uuidString,
            "initialText": initialText, "savedText": savedText, "beforeIdentity": identity(before), "afterIdentity": identity(saved),
            "cancelPreserved": true, "refusalPreserved": true, "refusalCount": refused, "duplicateAdditionalWrites": 0,
            "copyDisplayPersistedAgree": true, "reopenedMatches": true, "reopenControllerStable": true,
            "otherPinsUnchanged": true, "htmlImported": true, "htmlEditorUnavailable": true,
            "beforeDataSHA256": hash(originalData), "afterDataSHA256": hash(savedData),
            "beforePosterSHA256": hash(originalPoster), "afterPosterSHA256": hash(savedPoster),
            "historyLevels": historyLevels, "historyBytes": historyBytes, "maximumHistoryLevels": 12, "maximumHistoryBytes": 524_288,
            "appKitUndoDisabled": true], "renames": [textRename, imageRename], "order": order]
    }

    private static func rename(kind: String, id: UUID, store: PinSessionStore, window: NSWindow?, open: () -> Void,
        current: () -> PinRenameController?, title: () -> String, getCallback: () -> ((String, String) throws -> Void)?,
        setCallback: (((String, String) throws -> Void)?) -> Void, _ mode: String, _ directory: URL,
        _ owners: inout [WeakOwner], _ visuals: inout [[String: Any]], _ actions: inout [[String: Any]]) async throws -> [String: Any] {
        try show(window)
        let original = try required(store.entry(id: id), "Rename entry absent"), beforeManifest = try manifest(store)
        let initialTitle = title(), renamed = kind == "text" ? "文字已命名 🧪" : "图片已命名 🖼️"
        var callbackCount = 0
        let callback = try required(getCallback(), "Managed rename callback absent")
        setCallback { value, expected in callbackCount += 1; try callback(value, expected) }
        defer { setCallback(callback) }
        open(); let cancelled = try required(current(), "Rename did not open"); owners.append(WeakOwner(cancelled))
        open(); try require(current() === cancelled, "Repeated rename duplicated sheet")
        try field(cancelled, "Discarded name")
        try click(cancelled.cancelButton, "\(kind)-rename-cancel", mode, &actions)
        try await until({ current() == nil && window?.attachedSheet == nil }, "Rename cancel retained sheet")
        try require(try callbackCount == 0 && title() == initialTitle && manifest(store) == beforeManifest, "Rename cancel committed")
        var refused = 0
        setCallback { _, _ in refused += 1; throw failure("Injected rename refusal") }
        open(); let failed = try required(current(), "Failed rename absent"); owners.append(WeakOwner(failed))
        try field(failed, renamed)
        try click(failed.saveButton, "\(kind)-rename-refused-save", mode, &actions)
        try require(try refused == 1 && current() === failed && !failed.errorLabel.stringValue.isEmpty && title() == initialTitle && manifest(store) == beforeManifest,
                    "Rename failure lost safe title/draft")
        try require((failed.nameField.currentEditor()?.string ?? failed.nameField.stringValue) == renamed, "Rename failure erased draft")
        try click(failed.cancelButton, "\(kind)-rename-refused-cancel", mode, &actions)
        try await until({ current() == nil && window?.attachedSheet == nil }, "Failed rename cancel retained sheet")
        setCallback { value, expected in callbackCount += 1; try callback(value, expected) }
        open(); let saved = try required(current(), "Rename save absent"); owners.append(WeakOwner(saved))
        try field(saved, renamed)
        visuals.append(try snapshot(try required(saved.window, "Rename window absent"), "\(kind)-rename", mode, directory,
            controls: [saved.nameField, saved.cancelButton, saved.saveButton]))
        try click(saved.saveButton, "\(kind)-rename-save", mode, &actions)
        try await until({ current() == nil && window?.attachedSheet == nil }, "Rename save retained sheet")
        let committed = try manifest(store)
        saved.saveDraft(); saved.saveButton.performClick(nil)
        let result = try required(store.entry(id: id), "Renamed entry absent")
        try require(try callbackCount == 1 && title() == renamed && result.title == renamed && manifest(store) == committed, "Rename did not commit exactly once")
        var normalized = result; normalized.title = original.title
        try require(normalized == original, "Rename changed content/presentation metadata")
        return ["kind": kind, "id": id.uuidString, "beforeTitle": initialTitle, "afterTitle": renamed,
            "callbacks": callbackCount, "refusalCount": refused, "duplicateAdditionalWrites": 0,
            "cancelPreserved": true, "refusalPreserved": true, "sameSheetOnRepeat": true, "contentPresentationUnchanged": true]
    }

    private static func orderFlow(_ store: PinSessionStore, _ active: UUID, _ mode: String, _ directory: URL,
                                 _ owners: inout [WeakOwner], _ visuals: inout [[String: Any]]) async throws -> [String: Any] {
        trace("groupManagerInitEnter", ["appearance": mode])
        let manager = PinGroupsController(store: store); owners.append(WeakOwner(manager)); defer { manager.close() }
        trace("groupManagerInitReturn", ["appearance": mode])
        let window = try required(manager.window, "Group window absent")
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 680, height: 600)), display: true)
        window.center(); manager.showWindow(nil); try show(window)
        let table: NSTableView = try control("pin-group-entries", window)
        let order: NSPopUpButton = try control("pin-group-order", window)
        let picker: NSPopUpButton = try control("pin-group-picker", window)
        trace("groupSelectionEnter", ["appearance": mode])
        let selection = try PortableSettingsUIPreviewFixture.clickRow(1, in: table)
        trace("groupSelectionReturn", ["appearance": mode])
        let selected = manager.selectedPinIDs
        try require(selected.count == 1, "Native selected pin absent")
        var states = [store.groups.map { $0.id.uuidString }], menuEvents: [[String: Any]] = [], callbackCount = 0
        manager.onSessionChange = { callbackCount += 1 }
        let beforeEntries = try digest(store.entries), initialActive = store.index.activeGroupID
        for (item, boundary) in [("earlier", false), ("earlier", true), ("later", false), ("later", false), ("later", true)] {
            let orderBefore = store.groups.map { $0.id.uuidString }, callbacksBefore = callbackCount
            trace("groupPopupEnter", ["appearance": mode, "item": item, "boundary": boundary, "index": menuEvents.count])
            do { menuEvents.append(try await popup(order, id: "pin-group-order-" + item, boundary: boundary)) }
            catch {
                let state: [String: Any] = ["requestedItem": "pin-group-order-" + item, "boundary": boundary,
                    "orderBefore": orderBefore, "orderAfter": store.groups.map { $0.id.uuidString },
                    "callbacksBefore": callbacksBefore, "callbacksAfter": callbackCount,
                    "activeGroupID": store.index.activeGroupID.uuidString,
                    "selectedPinIDs": manager.selectedPinIDs.map(\.uuidString).sorted(), "selectedRow": table.selectedRow]
                let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                try require(data.count <= 16_384, "Order failure state byte budget exceeded")
                throw failure(error.localizedDescription + " | orderState=" + String(decoding: data, as: UTF8.self))
            }
            trace("groupPopupReturn", ["appearance": mode, "item": item, "boundary": boundary, "completedCount": menuEvents.count])
            try require(store.index.activeGroupID == active && manager.selectedPinIDs == selected && table.selectedRow == 1,
                        "Group order lost active group/selected pin")
            try require(try digest(store.entries) == beforeEntries, "Group order changed pins")
            states.append(store.groups.map { $0.id.uuidString })
        }
        try require(callbackCount == 3 && initialActive == active, "Group boundary invoked mutation")
        let identities = try required(selection["eventIdentity"] as? [String: Any], "Table identity absent")
        let expected = try required(identities["expected"] as? [String: Any], "Expected table event absent")
        let dequeued = try required(identities["dequeued"] as? [String: Any], "Dequeued table event absent")
        let result: [String: Any] = ["activeGroupID": active.uuidString, "selectedPinIDs": selected.map(\.uuidString).sorted(), "states": states,
            "menuEvents": menuEvents, "callbacks": callbackCount, "entriesUnchanged": true, "selectionPreserved": true,
            "pickerOrder": picker.itemArray.compactMap { ($0.representedObject as? UUID)?.uuidString },
            "minimumWindowSize": [680, 600], "rowSelection": ["requestedRow": selection["requestedRow"]!,
                "selectedRowAfter": selection["selectedRowAfter"]!, "windowNumber": selection["windowNumber"]!,
                "ownedWindowIsKey": identities["ownedWindowIsKey"]!, "sameQuartzTimestamp": identities["sameQuartzTimestamp"]!,
                "expectedQuartzTimestamp": expected["quartzTimestampNanoseconds"]!, "dequeuedQuartzTimestamp": dequeued["quartzTimestampNanoseconds"]!,
                "eventType": expected["type"]!, "dispatchRoute": selection["dispatchRoute"]!, "targetPointVisible": selection["targetPointVisible"]!]]
        // Preserve UUID transitions and actual input receipts before a visual
        // assertion can prevent the final combined report from being written.
        let functional: [String: Any] = ["sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "appearance": mode, "status": "functional-sequence-complete-layout-pending", "order": result]
        let functionalData = try JSONSerialization.data(withJSONObject: functional, options: [.sortedKeys])
        try require(functionalData.count <= 131_072, "Order transition receipt byte bound")
        try functionalData.write(to: directory.appendingPathComponent("pin-management-order-functional-\(mode).json"), options: .atomic)
        let controls = descendants(window.contentView).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        trace("groupSnapshotEnter", ["appearance": mode])
        visuals.append(try snapshot(window, "order", mode, directory, controls: controls))
        trace("groupSnapshotReturn", ["appearance": mode])
        return result
    }

    private static func cycles(_ root: URL, _ owners: inout [WeakOwner], deadline: Date) async throws -> [String: Any] {
        let store = try PinSessionStore(directory: root)
        let entry = try store.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: initialText)), title: "循环文字"))
        var rows: [[String: Any]] = []
        let kinds = ["text-cancel", "text-save", "rename-cancel", "rename-save", "text-parent-close", "rename-parent-close"]
        for index in 0..<12 {
            try require(Date() < deadline, "Ownership deadline exceeded")
            let kind = kinds[index % kinds.count]
            let result = try autoreleasepool { try cycle(store, entry.id, index, kind) }
            owners += result.probes
            try await until({ result.probes.allSatisfy(\.released) }, "Owned cycle objects retained at cycle \(index)")
            rows.append(["index": index, "warmup": index < 2, "action": kind, "callbacks": result.commits,
                "releasedControllers": 2, "releasedWindows": 2, "releasedContentViews": 2])
        }
        try require(owners.allSatisfy(\.released), "Previously closed owner retained")
        return ["warmupCycles": 2, "measuredCycles": 10, "rows": rows, "releaseProbeCount": 24,
            "releaseDeadlineSeconds": 4, "maximumHistoryLevels": 12, "maximumHistoryBytes": 524_288]
    }

    private static func cycle(_ store: PinSessionStore, _ id: UUID, _ index: Int, _ kind: String) throws -> (probes: [WeakOwner], commits: Int) {
        let controller = try RichPinController(asset: required(store.entry(id: id)?.richContent, "Cycle asset absent"),
            data: store.richData(id: id), title: store.entry(id: id)!.title)
        defer { controller.close() }
        var commits = 0
        controller.onUpdateText = { content, expected in commits += 1; try store.updateText(id: id, content: content, expectedContent: expected) }
        controller.onRename = { title, expected in
            try require(store.entry(id: id)?.title == expected, "Cycle title stale")
            commits += 1; try store.renamePin(id: id, title: title)
        }
        try show(controller.window)
        let text = kind.hasPrefix("text")
        if text { controller.editPlainText() } else { controller.renamePin() }
        let draft = try required(text ? controller.textEditController as PinDraftSheetController? : controller.renameController as PinDraftSheetController?, "Cycle draft absent")
        let probes = [WeakOwner(controller), WeakOwner(draft)]
        if let edit = draft as? PinTextEditController { try replace(edit.textView, with: "Cycle \(index)\n循环 🧪") }
        if let rename = draft as? PinRenameController { try field(rename, "循环 \(index)") }
        if kind.hasSuffix("parent-close") { controller.close() }
        else { try PortableSettingsUIPreviewFixture.click(kind.hasSuffix("save") ? draft.saveButton : draft.cancelButton) }
        controller.close()
        try require(commits == (kind.hasSuffix("save") ? 1 : 0), "Cycle commit count changed")
        return (probes, commits)
    }

    private static func snapshot(_ window: NSWindow, _ category: String, _ mode: String, _ directory: URL,
                                 controls: [NSControl], textView: NSTextView? = nil) throws -> [String: Any] {
        let root = try required(window.contentView, "Snapshot root absent")
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let width = Int(ceil(root.bounds.width)), height = Int(ceil(root.bounds.height))
        try require(width > 0 && height > 0 && width <= 4_000_000 / height, "Snapshot pixel bound")
        let bitmap = try required(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Snapshot allocation")
        bitmap.size = root.bounds.size
        let context = try required(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Snapshot context")
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.cacheDisplay(in: root.bounds, to: bitmap); context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let image = bitmap.cgImage { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        let name = "pin-management-\(category)-\(mode).png"
        try required(context.makeImage(), "Snapshot missing").writePNG(to: directory.appendingPathComponent(name))
        let visible = try required(window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame, "Display absent")
        try require(visible.insetBy(dx: -1, dy: -1).contains(window.frame), "Window outside visible display")
        // Keep failure geometry before any assertion can discard the snapshot.
        // Native button frames, alignment rectangles and cell drawing rectangles
        // are separate evidence; acceptance below still checks the full frames.
        var geometry: [[String: Any]] = [], intersections: [[String: Any]] = []
        let fullFrames = controls.map { $0.convert($0.bounds, to: root) }
        let alignmentFrames = controls.map { control in
            root.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
        }
        for (index, control) in controls.enumerated() {
            let frame = fullFrames[index], point = CGPoint(x: frame.midX, y: frame.midY)
            let hit = root.hitTest(root.convert(point, to: root.superview))
            let insets = control.alignmentRectInsets
            let drawing = control.convert(control.cell?.drawingRect(forBounds: control.bounds) ?? control.bounds, to: root)
            let minimumSize = control.cell?.cellSize ?? .zero
            let title = (control as? NSButton)?.title ?? ""
            geometry.append(["id": control.identifier?.rawValue ?? "button.\(index)", "title": title,
                "minimumSize": [minimumSize.width, minimumSize.height], "availableSize": [frame.width, frame.height], "frame": rect(frame),
                "alignmentRect": rect(alignmentFrames[index]), "cellDrawingRect": rect(drawing),
                "alignmentInsets": ["top": insets.top, "left": insets.left, "bottom": insets.bottom, "right": insets.right],
                "centerHitClass": hit.map { NSStringFromClass(type(of: $0)) } ?? "none",
                "centerHitID": hit?.identifier?.rawValue ?? "none",
                "centerHitIsControlOrDescendant": hit === control || hit?.isDescendant(of: control) == true])
            for previous in 0..<index {
                let overlap = fullFrames[previous].insetBy(dx: 0.5, dy: 0.5).intersection(frame.insetBy(dx: 0.5, dy: 0.5))
                if !overlap.isNull && !overlap.isEmpty {
                    let alignmentOverlap = alignmentFrames[previous].intersection(alignmentFrames[index])
                    intersections.append(["firstID": controls[previous].identifier?.rawValue ?? "button.\(previous)",
                        "secondID": control.identifier?.rawValue ?? "button.\(index)", "fullFrameIntersection": rect(overlap),
                        "alignmentIntersects": !alignmentOverlap.isNull && !alignmentOverlap.isEmpty,
                        "alignmentIntersection": alignmentOverlap.isNull ? [] : rect(alignmentOverlap)])
                }
            }
        }
        let geometryData = try JSONSerialization.data(withJSONObject: ["category": category, "appearance": mode,
            "contentBounds": rect(root.bounds), "controls": geometry, "intersections": intersections], options: [.sortedKeys])
        try require(geometryData.count <= 32_768, "Failure geometry byte budget exceeded")
        FileHandle.standardError.write(Data("Pin management snapshot geometry: ".utf8))
        FileHandle.standardError.write(geometryData); FileHandle.standardError.write(Data([10]))
        let failureGeometry = " | geometry=" + String(decoding: geometryData, as: UTF8.self)
        var rows: [[String: Any]] = [], frames: [CGRect] = []
        for (index, control) in controls.enumerated() {
            let frame = control.convert(control.bounds, to: root), point = CGPoint(x: frame.midX, y: frame.midY)
            let hit = root.hitTest(root.convert(point, to: root.superview))
            let fieldEditor = (control as? NSTextField)?.currentEditor()
            let editorHit = fieldEditor.map { hit === $0 || hit?.isDescendant(of: $0) == true } ?? false
            let size = control.cell?.cellSize ?? .zero
            try require(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) && frame.width >= 18 && frame.height >= 18, "Control clipped" + failureGeometry)
            try require(hit === control || hit?.isDescendant(of: control) == true || editorHit, "Control obscured" + failureGeometry)
            try require(frame.width + 1 >= size.width && frame.height + 1 >= size.height,
                        "Control text does not fit: id=\(control.identifier?.rawValue ?? "button.\(index)") title=\((control as? NSButton)?.title ?? "") required=\(size) available=\(frame.size)" + failureGeometry)
            try require(frames.allSatisfy { !$0.insetBy(dx: 0.5, dy: 0.5).intersects(frame.insetBy(dx: 0.5, dy: 0.5)) }, "Controls overlap" + failureGeometry)
            rows.append(["id": control.identifier?.rawValue ?? "button.\(index)", "frame": rect(frame), "minimumSize": [size.width, size.height], "hitTest": true])
            frames.append(frame)
        }
        var textEvidence: [String: Any] = [:]
        if let textView {
            let scroll = try required(textView.enclosingScrollView, "Draft viewport absent")
            let frame = scroll.convert(scroll.bounds, to: root)
            textView.layoutManager?.ensureLayout(for: try required(textView.textContainer, "Text container absent"))
            let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            try require(root.bounds.contains(frame) && frame.width >= 300 && frame.height >= 120 && used.height + 16 <= scroll.contentSize.height, "Draft text/viewport clipped")
            textEvidence = ["text": textView.string, "viewportFrame": rect(frame), "usedTextHeight": used.height,
                "viewportHeight": scroll.contentSize.height, "fullTextFits": true]
        }
        return ["category": category, "appearance": mode, "file": name, "pixelWidth": width, "pixelHeight": height,
            "windowFrame": rect(window.frame), "visibleFrame": rect(visible), "contentBounds": rect(root.bounds), "controls": rows,
            "fullVisibleFramesChecked": true, "controlsDoNotOverlap": true, "opaqueWindowBackgroundComposited": true, "text": textEvidence]
    }

    private static func popup(_ button: NSPopUpButton, id: String, boundary: Bool) async throws -> [String: Any] {
        let menu = try required(button.menu, "Order menu absent"), window = try required(button.window, "Order window absent")
        menu.delegate?.menuNeedsUpdate?(menu)
        let item = try required(menu.items.first { $0.identifier?.rawValue == id }, "Order item absent")
        try require(item.isEnabled != boundary, "Order boundary enabled state incorrect")
        let probe = MenuProbe(menu: menu, window: window, button: button, item: item, boundary: boundary), previous = menu.delegate
        probe.previous = previous; menu.delegate = probe
        probe.startTrackingObservations()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak probe] _ in MainActor.assumeIsolated { probe?.tick() } }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            if probe.timedOut || ((probe.trackingBeginCount > 0 || probe.opened) && !probe.trackingComplete) {
                probe.cancelOwnedTracking(reason: "deferred-failure-cleanup")
            }
            probe.stopTrackingObservations()
            menu.delegate = previous
        }
        trace("popupMouseDownEnter", ["item": id, "boundary": boundary, "windowNumber": window.windowNumber])
        try PortableSettingsUIPreviewFixture.clickMenuButton(button) { event, hit, identity in
            try probe.recordMouseDispatch(event, hit: hit, identity: identity)
        }
        trace("popupMouseDownReturn", ["item": id, "boundary": boundary, "windowNumber": window.windowNumber])
        try await probe.observeTrackingAfterClick()
        let receipt = try JSONSerialization.data(withJSONObject: probe.evidence, options: [.sortedKeys])
        try require(receipt.count <= 32_768, "Order probe receipt byte budget exceeded")
        FileHandle.standardError.write(Data("Pin management menu probe: ".utf8))
        FileHandle.standardError.write(receipt); FileHandle.standardError.write(Data([10]))
        try require(probe.trackingComplete && (boundary || probe.closed) && !probe.timedOut && probe.activated == !boundary,
                    "Native order tracking failed | probe=" + String(decoding: receipt, as: UTF8.self))
        return ["itemID": id, "boundary": boundary, "enabled": !boundary,
            "activated": probe.activated, "postedKeyCount": probe.posted, "timeoutSeconds": 2, "windowNumber": window.windowNumber,
            "dispatchRoute": "owned-nextEvent-sendEvent/native-menu-tracking",
            "mouseDispatch": try required(probe.mouseDispatch, "Owned menu mouse dispatch receipt absent"), "disabledDismissedWithEscape": boundary && probe.lastPostedKeyCode == 53 && probe.posted == 1,
            "lastPostedKeyCode": Int(try required(probe.lastPostedKeyCode, "Owned menu key absent")),
            "trackingBeginCount": probe.trackingBeginCount, "trackingEndCount": probe.trackingEndCount,
            "trackingIdentityVerified": probe.trackingIdentityVerified,
            "trackingBeginElapsedSeconds": try required(probe.trackingBeginElapsed, "Menu tracking begin time absent"),
            "trackingEndElapsedSeconds": try required(probe.trackingEndElapsed, "Menu tracking end time absent"),
            "trackingEndedBeforeClickReturn": probe.trackingEndedBeforeClickReturn,
            "delegateOpenObserved": probe.opened, "delegateOpenIdentityVerified": probe.openMenuIdentityVerified,
            "delegateOpenElapsedSeconds": probe.openedElapsed.map { $0 as Any } ?? NSNull(),
            "delegateCloseObserved": probe.closed, "delegateCloseIdentityVerified": probe.closeMenuIdentityVerified,
            "delegateCloseElapsedSeconds": probe.closedElapsed.map { $0 as Any } ?? NSNull(),
            "highlightObservation": "exact-owned-menu-current-state",
            "returnHighlightVerified": probe.returnHighlightVerified,
            "returnHighlightElapsedSeconds": probe.returnHighlightElapsed.map { $0 as Any } ?? NSNull(),
            "returnHighlightedItemID": probe.returnHighlightedItemID.map { $0 as Any } ?? NSNull(),
            "returnTargetEnabled": probe.returnTargetEnabled,
            "returnTargetHighlighted": probe.returnTargetHighlighted,
            "returnTargetMenuIdentityVerified": probe.returnTargetMenuIdentityVerified,
            "delegateHighlightEvents": probe.delegateHighlightEvents,
            "clickReturnElapsedSeconds": try required(probe.clickReturnElapsed, "Menu click return time absent"),
            "lifecycleObservation": "exact-root-menu-begin-end-notifications"]
    }

    private static func click(_ button: NSButton, _ name: String, _ mode: String, _ actions: inout [[String: Any]]) throws {
        let number = try required(button.window?.windowNumber, "Action window absent"), id = button.identifier?.rawValue ?? ""
        try require(number > 0 && !id.isEmpty, "Action identity absent")
        trace("buttonMouseDownEnter", ["appearance": mode, "action": name, "controlID": id, "windowNumber": number])
        try PortableSettingsUIPreviewFixture.click(button)
        trace("buttonMouseDownReturn", ["appearance": mode, "action": name, "controlID": id, "windowNumber": number])
        actions.append(["appearance": mode, "action": name, "controlID": id, "windowNumber": number, "route": route, "hitTest": true])
    }
    private static func replace(_ view: NSTextView, with text: String) throws {
        try require(view.window?.makeFirstResponder(view) == true, "Draft first responder absent")
        view.insertText(text, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        try require(view.string == text, "Native text insertion changed content")
    }
    private static func field(_ draft: PinRenameController, _ text: String) throws {
        try require(draft.window?.makeFirstResponder(draft.nameField) == true, "Rename first responder absent")
        if let editor = draft.nameField.currentEditor() as? NSTextView { try replace(editor, with: text) }
        else { throw failure("Rename field editor absent") }
    }
    private static func output(_ controller: RichPinController, expected: String) throws {
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        controller.copyText(to: pasteboard)
        try require(pasteboard.string(forType: .string) == expected && controller.textDisplayView.string == expected && controller.richDocument?.text?.plainText == expected,
                    "Display/copy/model text mismatch")
    }
    private static func identity(_ entry: PinSessionEntry) -> [String: Any] {
        ["id": entry.id.uuidString, "groupID": entry.groupID.uuidString, "title": entry.title,
         "presentationSHA256": (try? digest(entry.presentation)) ?? "invalid"]
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return hash(try encoder.encode(value)) }
    private static func entryHash(_ store: PinSessionStore, _ id: UUID) throws -> String { try digest(required(store.entry(id: id), "Entry absent")) }
    private static func poster(_ store: PinSessionStore, _ id: UUID) throws -> Data {
        try Data(contentsOf: store.directory.appendingPathComponent(required(store.entry(id: id), "Poster entry absent").current.filename))
    }
    private static func manifest(_ store: PinSessionStore) throws -> Data { try Data(contentsOf: store.directory.appendingPathComponent("index.json")) }
    private static func show(_ value: NSWindow?) throws {
        let window = try required(value, "Owned window absent")
        window.animationBehavior = .none; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !window.isKeyWindow && ProcessInfo.processInfo.systemUptime < deadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        try require(window.isKeyWindow, "Owned window did not become key")
    }
    private static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    private static func control<T: NSControl>(_ id: String, _ window: NSWindow) throws -> T { try required(descendants(window.contentView).first { $0.identifier?.rawValue == id } as? T, "Control absent: " + id) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func rect(_ frame: CGRect) -> [CGFloat] { [frame.minX, frame.minY, frame.width, frame.height] }
    private static func until(_ condition: () -> Bool, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), message)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw failure(message) } }
    private static func required<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Pin management fixture: " + message) }

    @MainActor private final class WeakOwner {
        weak var controller: NSWindowController?; weak var window: NSWindow?; weak var content: NSView?
        init(_ owner: NSWindowController) { controller = owner; window = owner.window; content = owner.window?.contentView }
        var released: Bool { controller == nil && window == nil && content == nil }
    }
    @MainActor private final class MenuProbe: NSObject, NSMenuDelegate {
        weak var menu: NSMenu?; weak var window: NSWindow?; weak var target: NSMenuItem?
        weak var button: NSPopUpButton?
        weak var previous: NSMenuDelegate?
        let boundary: Bool; private let started: TimeInterval, deadline: TimeInterval
        var opened = false, closed = false, activated = false, timedOut = false, posted = 0
        private(set) var openMenuIdentityVerified = false
        private(set) var openedElapsed: TimeInterval?
        private(set) var closeMenuIdentityVerified = false
        private(set) var closedBeforeClickReturn = false
        private(set) var clickReturnElapsed: TimeInterval?, closedElapsed: TimeInterval?
        private(set) var trackingBeginCount = 0, trackingEndCount = 0
        private(set) var trackingIdentityVerified = false, trackingEndedBeforeClickReturn = false
        private(set) var trackingBeginElapsed: TimeInterval?, trackingEndElapsed: TimeInterval?
        private(set) var lastPostedKeyCode: UInt16?
        private var trackingBeginIdentityVerified = false
        private var trackingObservers: [NSObjectProtocol] = []
        var trackingComplete: Bool { trackingBeginCount == 1 && trackingEndCount == 1 && trackingIdentityVerified }
        var trackingActive: Bool { trackingBeginCount == 1 && trackingEndCount == 0 && trackingBeginIdentityVerified }
        private var highlighted: NSMenuItem?, entered = false
        private(set) var returnHighlightVerified = false, returnTargetEnabled = false
        private(set) var returnTargetHighlighted = false, returnTargetMenuIdentityVerified = false
        private(set) var returnHighlightElapsed: TimeInterval?, returnHighlightedItemID: String?
        private(set) var delegateHighlightEvents: [[String: Any]] = []
        private(set) var mouseDispatch: [String: Any]?
        private var cancellationIssued = false, cancellationCallCount = 0
        private var cancellationReason: String?
        private var ownedTrackingEndObserved = false
        private var ownedTrackingEndElapsed: TimeInterval?
        private var events: [[String: Any]] = [], omittedEvents = 0
        var evidence: [String: Any] {
            ["requestedItem": target?.identifier?.rawValue ?? "none", "boundary": boundary,
             "opened": opened, "closed": closed, "activated": activated, "timedOut": timedOut,
             "posted": posted, "entered": entered, "highlightedItem": highlighted?.identifier?.rawValue ?? "none",
             "highlightIsTarget": highlighted === target, "targetEnabled": target?.isEnabled ?? false,
             "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started, "timeoutSeconds": 2,
             "maximumPostedEvents": 40, "maximumTraceEvents": 96, "omittedTraceEvents": omittedEvents,
             "windowNumber": window?.windowNumber ?? -1, "windowIsKey": window?.isKeyWindow ?? false,
             "nativeHighlightedItem": menu?.highlightedItem?.identifier?.rawValue ?? "none",
             "nativeHighlightIsTarget": target != nil && menu?.highlightedItem === target,
             "nativeTargetIsHighlighted": target?.isHighlighted ?? false,
             "popupSelectedItem": button?.selectedItem?.identifier?.rawValue ?? "none",
             "popupSelectedItemIndex": button?.indexOfSelectedItem ?? -1,
             "returnHighlightVerified": returnHighlightVerified,
             "returnHighlightElapsedSeconds": returnHighlightElapsed.map { $0 as Any } ?? NSNull(),
             "returnHighlightedItemID": returnHighlightedItemID.map { $0 as Any } ?? NSNull(),
             "returnTargetEnabled": returnTargetEnabled, "returnTargetHighlighted": returnTargetHighlighted,
             "returnTargetMenuIdentityVerified": returnTargetMenuIdentityVerified,
             "delegateHighlightEvents": delegateHighlightEvents,
             "failureCancellationIssued": cancellationIssued, "failureCancellationCallCount": cancellationCallCount,
             "failureCancellationReason": cancellationReason.map { $0 as Any } ?? NSNull(),
             "ownedTrackingEndObserved": ownedTrackingEndObserved,
             "ownedTrackingEndElapsedSeconds": ownedTrackingEndElapsed.map { $0 as Any } ?? NSNull(),
             "closedBeforeClickReturn": closedBeforeClickReturn, "closeMenuIdentityVerified": closeMenuIdentityVerified,
             "openMenuIdentityVerified": openMenuIdentityVerified,
             "openedElapsedSeconds": openedElapsed.map { $0 as Any } ?? NSNull(),
             "clickReturnElapsedSeconds": clickReturnElapsed.map { $0 as Any } ?? NSNull(),
             "closedElapsedSeconds": closedElapsed.map { $0 as Any } ?? NSNull(),
             "trackingBeginCount": trackingBeginCount, "trackingEndCount": trackingEndCount,
             "trackingIdentityVerified": trackingIdentityVerified, "trackingEndedBeforeClickReturn": trackingEndedBeforeClickReturn,
             "trackingBeginElapsedSeconds": trackingBeginElapsed.map { $0 as Any } ?? NSNull(),
             "trackingEndElapsedSeconds": trackingEndElapsed.map { $0 as Any } ?? NSNull(),
             "applicationIsActive": NSApp.isActive, "events": events]
        }
        func recordMouseDispatch(_ event: NSEvent, hit: NSView?, identity: [String: Any]) throws {
            let now = ProcessInfo.processInfo.systemUptime
            let current = try PinManagementSmokeFixture.required(NSApp.currentEvent, "Owned popup current event absent")
            let button = try PinManagementSmokeFixture.required(button, "Owned popup button absent")
            let window = try PinManagementSmokeFixture.required(window, "Owned popup window absent")
            let expected = try PinManagementSmokeFixture.required(identity["expected"] as? [String: Any], "Expected mouse identity absent")
            let expectedClock = try PinManagementSmokeFixture.required(expected["quartzTimestampNanoseconds"] as? UInt64, "Expected mouse clock absent")
            let dequeuedClock = try PinManagementSmokeFixture.required(event.cgEvent?.timestamp, "Dequeued mouse clock absent")
            let currentClock = try PinManagementSmokeFixture.required(current.cgEvent?.timestamp, "Current mouse clock absent")
            let location = event.locationInWindow
            let expectedLocation = try PinManagementSmokeFixture.required(expected["location"] as? [CGFloat], "Expected mouse location absent")
            let currentLocation = current.locationInWindow
            let hitVerified = hit === button || hit?.isDescendant(of: button) == true
            let valid = now <= deadline && mouseDispatch == nil && window.isKeyWindow && hitVerified &&
                expectedClock > 0 && expectedClock == dequeuedClock && dequeuedClock == currentClock &&
                event.type == .leftMouseDown && current.type == .leftMouseDown &&
                event.windowNumber == window.windowNumber && current.windowNumber == window.windowNumber &&
                event.eventNumber == 1 && current.eventNumber == event.eventNumber &&
                event.clickCount == 1 && current.clickCount == event.clickCount &&
                event.modifierFlags.isEmpty && current.modifierFlags == event.modifierFlags &&
                expectedLocation == [location.x, location.y] && currentLocation == location
            let receipt: [String: Any] = ["route": "owned-nextEvent-sendEvent", "elapsedSeconds": now - started,
                "eventType": Int(event.type.rawValue), "windowNumber": event.windowNumber,
                "eventNumber": event.eventNumber, "clickCount": event.clickCount, "modifierFlags": event.modifierFlags.rawValue,
                "expectedQuartzTimestamp": expectedClock, "dequeuedQuartzTimestamp": dequeuedClock, "currentQuartzTimestamp": currentClock,
                "expectedLocation": expectedLocation, "dequeuedLocation": [location.x, location.y],
                "currentLocation": [currentLocation.x, currentLocation.y], "currentEventType": Int(current.type.rawValue),
                "currentWindowNumber": current.windowNumber, "currentEventNumber": current.eventNumber,
                "currentClickCount": current.clickCount, "currentModifierFlags": current.modifierFlags.rawValue,
                "ownedWindowIsKey": window.isKeyWindow, "hitTestVerified": hitVerified]
            PinManagementSmokeFixture.trace("popupApplicationMouseDispatch", ["requestedItem": target?.identifier?.rawValue ?? "none",
                "valid": valid, "mouseDispatch": receipt])
            guard valid else {
                timedOut = true
                // The helper restored a foreign dequeue before reaching us. This
                // guard owns its matching dequeue and stops before sendEvent.
                throw PinManagementSmokeFixture.failure("Owned popup current-event identity mismatch")
            }
            mouseDispatch = receipt
        }

        func startTrackingObservations() {
            guard let menu, trackingObservers.isEmpty else { timedOut = true; return }
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                let token = NotificationCenter.default.addObserver(forName: name, object: menu, queue: nil) { [weak self] note in
                    MainActor.assumeIsolated { self?.observeTracking(note) }
                }
                trackingObservers.append(token)
            }
        }
        func stopTrackingObservations() {
            for token in trackingObservers { NotificationCenter.default.removeObserver(token) }
            trackingObservers.removeAll()
        }
        private func observeTracking(_ note: Notification) {
            let now = ProcessInfo.processInfo.systemUptime
            guard let actual = note.object as? NSMenu, actual === menu,
                  (actual.delegate as AnyObject?) === self else {
                timedOut = true; record("foreignTrackingRejected"); return
            }
            // Keep actual owned cleanup evidence even when it is too late to
            // satisfy the original input/lifecycle deadline. Never clear failure.
            if note.name == NSMenu.didEndTrackingNotification {
                ownedTrackingEndObserved = true; ownedTrackingEndElapsed = now - started
            }
            guard now <= deadline else { timedOut = true; record("lateTrackingRejected"); return }
            if note.name == NSMenu.didBeginTrackingNotification {
                trackingBeginCount += 1
                guard trackingBeginCount == 1 && trackingEndCount == 0 else {
                    timedOut = true; record("duplicateOrReorderedBeginRejected"); return
                }
                trackingBeginIdentityVerified = true; trackingBeginElapsed = now - started; record("trackingBegan")
            } else if note.name == NSMenu.didEndTrackingNotification {
                trackingEndCount += 1
                guard trackingBeginCount == 1 && trackingEndCount == 1 && trackingBeginIdentityVerified else {
                    timedOut = true; record("duplicateOrReorderedEndRejected"); return
                }
                trackingIdentityVerified = true; trackingEndElapsed = now - started; record("trackingEnded")
            } else { timedOut = true; record("unknownTrackingRejected") }
        }
        // The documented root-menu end notification covers Escape cancellation
        // without an action. Enabled selections also retain the delegate-close
        // requirement. Both observations use the original pre-click deadline.
        func observeTrackingAfterClick() async throws {
            clickReturnElapsed = ProcessInfo.processInfo.systemUptime - started
            closedBeforeClickReturn = closed; trackingEndedBeforeClickReturn = trackingComplete; record("clickReturned")
            while trackingBeginCount == 1 && (!trackingComplete || (!boundary && !closed)) && !timedOut {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                try await Task.sleep(nanoseconds: max(1, UInt64(min(0.01, remaining) * 1_000_000_000)))
            }
            // Judge actual event timestamps, not a later task-resumption time.
            if !trackingComplete || (!boundary && !closed) ||
                (clickReturnElapsed ?? TimeInterval.infinity) > 2 {
                timedOut = true; record("trackingObservationFailed"); cancelOwnedTracking(reason: "tracking-observation-failed")
            }
        }
        func cancelOwnedTracking(reason: String) {
            guard !cancellationIssued, !trackingComplete, let menu,
                  (menu.delegate as AnyObject?) === self else { return }
            cancellationIssued = true; cancellationCallCount += 1; cancellationReason = reason
            record("cancelWithoutAnimationEnter")
            menu.cancelTrackingWithoutAnimation()
            record("cancelWithoutAnimationReturn")
        }
        private func record(_ kind: String, code: UInt16? = nil) {
            guard events.count < 96 else { omittedEvents += 1; return }
            PinManagementSmokeFixture.trace("menuProbeEvent", ["event": kind, "probeElapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "requestedItem": target?.identifier?.rawValue ?? "none", "boundary": boundary,
                "menuIdentity": menu.map { String(describing: ObjectIdentifier($0)) } ?? "none",
                "delegateIsProbe": (menu?.delegate as AnyObject?) === self,
                "windowNumber": window?.windowNumber ?? -1,
                "nativeHighlightedItem": menu?.highlightedItem?.identifier?.rawValue ?? "none",
                "nativeHighlightIsTarget": target != nil && menu?.highlightedItem === target,
                "nativeTargetEnabled": target?.isEnabled ?? false,
                "nativeTargetIsHighlighted": target?.isHighlighted ?? false,
                "delegateHighlightedItem": highlighted?.identifier?.rawValue ?? "none",
                "popupSelectedItem": button?.selectedItem?.identifier?.rawValue ?? "none",
                "popupSelectedItemIndex": button?.indexOfSelectedItem ?? -1,
                "failureCancellationIssued": cancellationIssued, "failureCancellationCallCount": cancellationCallCount,
                "failureCancellationReason": cancellationReason.map { $0 as Any } ?? NSNull(),
                "ownedTrackingEndObserved": ownedTrackingEndObserved,
                "opened": opened, "closed": closed, "entered": entered, "timedOut": timedOut,
                "trackingBeginCount": trackingBeginCount, "trackingEndCount": trackingEndCount,
                "posted": posted, "syntheticKeyCode": code.map(Int.init) ?? -1])
            events.append(["event": kind, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "highlightedItem": highlighted?.identifier?.rawValue ?? "none", "highlightIsTarget": highlighted === target,
                "entered": entered, "posted": posted, "syntheticKeyCode": code.map(Int.init) ?? -1])
        }
        init(menu: NSMenu, window: NSWindow, button: NSPopUpButton, item: NSMenuItem, boundary: Bool) {
            self.menu = menu; self.window = window; self.button = button; target = item; self.boundary = boundary
            let now = ProcessInfo.processInfo.systemUptime; started = now; deadline = now + 2
            super.init(); record("created")
        }
        func menuNeedsUpdate(_ menu: NSMenu) { record("needsUpdate"); previous?.menuNeedsUpdate?(menu) }
        func menuWillOpen(_ menu: NSMenu) {
            let now = ProcessInfo.processInfo.systemUptime
            guard menu === self.menu && (menu.delegate as AnyObject?) === self && now <= deadline else {
                timedOut = true; record("foreignOrLateOpenRejected"); return
            }
            opened = true; openMenuIdentityVerified = true; openedElapsed = now - started
            record("willOpen"); previous?.menuWillOpen?(menu)
        }
        func menuDidClose(_ menu: NSMenu) {
            guard menu === self.menu && (menu.delegate as AnyObject?) === self else {
                timedOut = true; record("foreignCloseRejected"); return
            }
            let now = ProcessInfo.processInfo.systemUptime
            closeMenuIdentityVerified = true; closedElapsed = now - started; closed = true
            if now > deadline { timedOut = true }
            activated = !boundary && entered && returnHighlightVerified
            record("didClose"); previous?.menuDidClose?(menu)
        }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            let now = ProcessInfo.processInfo.systemUptime
            guard menu === self.menu, (menu.delegate as AnyObject?) === self, now <= deadline,
                  delegateHighlightEvents.count < 96 else {
                timedOut = true; record("foreignLateOrExcessHighlightRejected"); return
            }
            highlighted = item
            delegateHighlightEvents.append(["itemID": (item?.identifier?.rawValue).map { $0 as Any } ?? NSNull(),
                "elapsedSeconds": now - started, "ownedMenuIdentityVerified": true])
            record(item == nil ? "willHighlightNil" : "willHighlightItem")
            previous?.menu?(menu, willHighlight: item)
        }
        func tick() {
            record("tick")
            guard !trackingComplete else { return }
            if timedOut { cancelOwnedTracking(reason: "latched-failure"); return }
            if ProcessInfo.processInfo.systemUptime >= deadline || posted >= 40 {
                timedOut = true; record("timeout"); cancelOwnedTracking(reason: "original-time-or-event-limit"); return
            }
            guard !closed, trackingActive, !entered, let window, let menu, let target else { return }
            let ownedTarget = button?.menu === menu && target.menu === menu && (menu.delegate as AnyObject?) === self
            guard ownedTarget else { timedOut = true; record("target-menu-identity-rejected"); cancelOwnedTracking(reason: "target-menu-identity"); return }
            let select = menu.highlightedItem === target && target.isHighlighted && target.isEnabled
            let code: UInt16 = boundary ? 53 : (select ? 36 : 125)
            let text = boundary ? "\u{1b}" : (select ? "\r" : "\u{f701}")
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { timedOut = true; record("eventCreationFailed"); cancelOwnedTracking(reason: "event-creation"); return }
            if !boundary && select {
                returnHighlightVerified = true; returnHighlightElapsed = ProcessInfo.processInfo.systemUptime - started
                returnHighlightedItemID = target.identifier?.rawValue
                returnTargetEnabled = target.isEnabled; returnTargetHighlighted = target.isHighlighted
                returnTargetMenuIdentityVerified = ownedTarget
                record("nativeReturnHighlightVerified")
            }
            entered = boundary || select; posted += 1; lastPostedKeyCode = code
            record("postedKey", code: code); NSApp.postEvent(event, atStart: true)
        }
    }
}
