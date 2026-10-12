import AppKit
import PicShotCore
import XCTest
@testable import PicShot

@MainActor final class CaptureChainControllerTests: XCTestCase {
    func testNativeDraftSaveCancelSelectionReorderAndDeleteAreDeliberate() throws {
        try withApplicationLoop {
            let f = try self.fixture(); defer { f.close() }
            var writes = 0; f.store.beforeManifestCommit = { writes += 1 }
            try self.ready(f.controller)
            try self.click("create", in: f.controller)
            let name: NSTextField = try self.view("name", in: f.controller)
            name.stringValue = "工作截图"; self.edited(name, in: f.controller)
            try self.click("output-copy", in: f.controller)
            try self.click("output-pin", in: f.controller)
            try self.click("up-pin", in: f.controller)
            XCTAssertEqual(writes, 0); XCTAssertTrue(f.store.definitions.isEmpty)
            let run: NSButton = try self.view("run", in: f.controller)
            XCTAssertFalse(run.isEnabled)
            try self.click("save", in: f.controller)
            XCTAssertEqual(writes, 1); XCTAssertNil(f.store.selectedID)
            let definition = try XCTUnwrap(f.store.definitions.first)
            XCTAssertEqual(definition.outputs, [.quickSavePNG, .pin, .copy])
            try self.click("select", in: f.controller)
            XCTAssertEqual(writes, 2); XCTAssertEqual(f.store.selectedID, definition.id)
            name.stringValue = "未保存名称"; self.edited(name, in: f.controller)
            XCTAssertEqual(f.store.definitions.first?.name, "工作截图")
            try self.click("discard", in: f.controller)
            XCTAssertEqual(name.stringValue, "工作截图"); XCTAssertEqual(writes, 2)
            name.stringValue = "重命名截图"; self.edited(name, in: f.controller)
            try self.click("save", in: f.controller)
            XCTAssertEqual(writes, 3); XCTAssertEqual(f.store.definitions.first?.id, definition.id)
            XCTAssertEqual(try CaptureChainStore(directory: f.directory).definitions.first?.name, "重命名截图")
            try self.click("delete", in: f.controller)
            XCTAssertEqual(writes, 4); XCTAssertTrue(f.store.definitions.isEmpty); XCTAssertNil(f.store.selectedID)
        }
    }

    func testPresetReferenceIsExplicitAndMissingPresetNeverBecomesRegion() throws {
        let preset = try makePreset()
        let definition = try CaptureChainDefinition(name: "预设截图", source: .preset(preset.id), outputs: [.copy])
        let f = try fixture(definition: definition, presets: [preset]); defer { f.close() }
        let picker: NSPopUpButton = try view("source", in: f.controller)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, preset.id)
        f.controller.setPresets([])
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, preset.id)
        XCTAssertTrue(picker.titleOfSelectedItem?.contains("不可用") == true)
        let run: NSButton = try view("run", in: f.controller)
        XCTAssertFalse(run.isEnabled)
        XCTAssertEqual(f.store.definitions.first?.source, .preset(preset.id))
        picker.selectItem(at: 0); try dispatch(picker)
        XCTAssertEqual(f.store.definitions.first?.source, .preset(preset.id), "A draft source never writes automatically")
        try press("save", in: f.controller)
        XCTAssertEqual(f.store.definitions.first?.source, .region)
    }

    func testFailedSaveKeepsDraftAndSavedDefinitionWithActionableStatus() throws {
        let f = try fixture(definition: definition()); defer { f.close() }
        let before = f.store.index, name: NSTextField = try view("name", in: f.controller)
        name.stringValue = "待保存名称"; edited(name, in: f.controller)
        f.store.beforeManifestCommit = { throw CaptureChainError.saveFailed }
        try press("save", in: f.controller)
        XCTAssertEqual(f.store.index, before); XCTAssertEqual(name.stringValue, "待保存名称")
        let status: NSTextField = try view("status", in: f.controller)
        XCTAssertTrue(status.stringValue.contains("无法保存截图链")); XCTAssertEqual(status.textColor, .systemRed)
        let run: NSButton = try view("run", in: f.controller)
        XCTAssertFalse(run.isEnabled)
        f.store.beforeManifestCommit = nil; try press("save", in: f.controller)
        XCTAssertEqual(f.store.definitions.first?.name, "待保存名称")
    }

    func testUnsavedDraftBlocksButtonAndTableRunWithoutWriting() async throws {
        let f = try fixture(definition: definition()); defer { f.close() }
        var invocations = 0; f.controller.onRun = { _, _ in invocations += 1 }
        let saved = f.store.index
        let name: NSTextField = try view("name", in: f.controller)
        // Guard the actual field value even before its delegate notification.
        name.stringValue = "未保存"
        try press("run", in: f.controller)
        let table: NSTableView = try view("list", in: f.controller)
        try dispatch(table, action: table.doubleAction)
        await drainCommands()
        XCTAssertEqual(invocations, 0); XCTAssertEqual(f.store.index, saved)
        edited(name, in: f.controller); try press("discard", in: f.controller)
        try press("run", in: f.controller); try press("run", in: f.controller)
        await drainCommands()
        XCTAssertEqual(invocations, 1); XCTAssertEqual(f.store.index, saved)
    }

    func testQueuedRunInvalidatesOnSelectionChangeAndFreshRunRemainsAvailable() async throws {
        let definition = try definition(), f = try fixture(definition: definition); defer { f.close() }
        var commands: [(UUID, UInt64)] = []
        f.controller.onRun = { commands.append(($0, $1)) }
        try press("run", in: f.controller)
        let oldGeneration = f.controller.commandGeneration
        try f.store.select(id: definition.id)
        XCTAssertFalse(f.controller.isCurrentCommand(oldGeneration))
        await drainCommands(); XCTAssertTrue(commands.isEmpty)
        try press("run", in: f.controller); await drainCommands()
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands.first?.0, definition.id)
        XCTAssertTrue(f.controller.isCurrentCommand(try XCTUnwrap(commands.first?.1)))
    }

    func testCaptureFailureRestoresManagerAndKeepsCatalogUnchanged() throws {
        let definition = try definition(), f = try fixture(definition: definition); defer { f.close() }
        let before = try Data(contentsOf: f.directory.appendingPathComponent(CaptureChainStore.manifestFilename))
        f.controller.present(); let runID = UUID()
        f.controller.update(snapshot: snapshot(definition, id: runID, status: .capturing))
        XCTAssertFalse(f.controller.window?.isVisible ?? true)
        let name: NSTextField = try view("name", in: f.controller)
        XCTAssertFalse(name.isEnabled)
        f.controller.update(snapshot: snapshot(definition, id: runID, status: .captureFailed(message: "显示器已改变")))
        XCTAssertTrue(f.controller.window?.isVisible == true); XCTAssertTrue(name.isEnabled)
        let status: NSTextField = try view("run-status", in: f.controller)
        XCTAssertTrue(status.stringValue.contains("显示器已改变")); XCTAssertTrue(status.stringValue.contains("重新运行"))
        let run: NSButton = try view("run", in: f.controller)
        XCTAssertTrue(run.isEnabled)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent(CaptureChainStore.manifestFilename)), before)
    }

    func testRetryOnlyTargetsDisplayedFailedRunAndReceiptsSurviveCompletion() async throws {
        let definition = try definition(), f = try fixture(definition: definition); defer { f.close() }
        let runID = UUID(), receipt = CaptureChainReceipt(output: .quickSavePNG,
            value: .saved(URL(fileURLWithPath: "/tmp/chain.png"), byteCount: 120))
        f.controller.update(snapshot: snapshot(definition, id: runID,
            status: .failed(index: 1, message: "复制失败"), receipts: [receipt], bytes: 256))
        var retries: [UUID] = []
        f.controller.onRetry = { id, generation in
            XCTAssertTrue(f.controller.isCurrentCommand(generation)); retries.append(id)
            f.controller.update(snapshot: self.snapshot(definition, id: id, status: .running(index: 1), receipts: [receipt], bytes: 256))
        }
        try press("retry", in: f.controller); try press("retry", in: f.controller)
        await drainCommands(); XCTAssertEqual(retries, [runID])
        let complete = [receipt, CaptureChainReceipt(output: .copy, value: .copied)]
        f.controller.update(snapshot: snapshot(definition, id: runID, status: .completed, receipts: complete))
        XCTAssertEqual(f.controller.displayedSnapshot?.receipts, complete)
        XCTAssertEqual(f.controller.displayedSnapshot?.retainedBytes, 0)
        let save: NSTextField = try view("receipt-0", in: f.controller)
        let copy: NSTextField = try view("receipt-1", in: f.controller)
        XCTAssertTrue(save.stringValue.contains("/tmp/chain.png")); XCTAssertTrue(copy.stringValue.contains("已复制"))
        let run: NSButton = try view("run", in: f.controller)
        XCTAssertTrue(run.isEnabled, "Completion reopens admission without closing the receipt window")
        XCTAssertFalse(String(decoding: try Data(contentsOf: f.directory.appendingPathComponent(CaptureChainStore.manifestFilename)), as: UTF8.self).contains("chain.png"))
        f.controller.onRetry = nil
    }

    func testCloseIsRunScopedAndLateCancellationNeverReopensWindow() async throws {
        let definition = try definition(), f = try fixture(definition: definition); defer { f.close() }
        let oldID = UUID(), newID = UUID()
        var closed: [UUID?] = []; f.controller.onClose = { id, _ in closed.append(id) }
        f.controller.present()
        f.controller.update(snapshot: snapshot(definition, id: oldID, status: .failed(index: 0, message: "保存失败"), bytes: 256))
        try press("close", in: f.controller); await drainCommands()
        XCTAssertEqual(closed.count, 1); XCTAssertEqual(closed.first!, oldID)
        f.controller.update(snapshot: snapshot(definition, id: oldID, status: .cancelled))
        XCTAssertFalse(f.controller.window?.isVisible ?? true)
        // Closing the old receipt still names the old run, even when admission
        // is immediately reused. The root checks that ID before cancellation.
        f.controller.present(); try press("close", in: f.controller)
        f.controller.update(snapshot: snapshot(definition, id: newID, status: .capturing))
        await drainCommands(); XCTAssertEqual(closed.count, 2); XCTAssertEqual(closed.last!, oldID)
        f.controller.update(snapshot: snapshot(definition, id: newID, status: .running(index: 0), bytes: 256))
        XCTAssertFalse(f.controller.window?.isVisible ?? true)
        f.controller.present(); XCTAssertTrue(f.controller.window?.isVisible == true)
    }

    func testCloseCancelsOldRunExactlyOnceEvenIfManagerIsImmediatelyReleased() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-ChainClose-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureChainStore(directory: directory), definition = try definition()
        try store.add(definition)
        var controller: CaptureChainController? = CaptureChainController(store: store)
        weak var weakController = controller
        let oldID = UUID(), newID = UUID()
        var activeID = oldID, cancelled: [UUID] = []
        controller?.onClose = { id, _ in if let id, id == activeID { cancelled.append(id) } }
        controller?.update(snapshot: snapshot(definition, id: oldID, status: .running(index: 0), bytes: 256))
        controller?.present(); controller?.window?.close(); controller = nil
        XCTAssertEqual(cancelled, [oldID]); XCTAssertNil(weakController)
        activeID = newID
        XCTAssertEqual(cancelled, [oldID], "Retiring the old manager cannot cancel the new run")
    }

    func testNativeEscapeClosesFailedSessionAndSendsItsRunIdentityOnce() throws {
        try withApplicationLoop {
            let definition = try self.definition(), f = try self.fixture(definition: definition); defer { f.close() }
            let runID = UUID(); var closed: [UUID?] = []
            f.controller.onClose = { id, _ in closed.append(id) }
            f.controller.update(snapshot: self.snapshot(definition, id: runID, status: .failed(index: 0, message: "保存失败"), bytes: 256))
            try self.ready(f.controller)
            let window = try XCTUnwrap(f.controller.window)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertFalse(window.isVisible); XCTAssertEqual(closed.count, 1); XCTAssertEqual(closed.first!, runID)
            f.controller.update(snapshot: self.snapshot(definition, id: runID, status: .cancelled))
            XCTAssertFalse(window.isVisible)
        }
    }

    func testCancelDispatchesOnceAndRetainsCompletedSideEffectInSummary() async throws {
        let definition = try definition(), f = try fixture(definition: definition); defer { f.close() }
        let runID = UUID(), receipt = CaptureChainReceipt(output: .quickSavePNG,
            value: .saved(URL(fileURLWithPath: "/tmp/saved-before-cancel.png"), byteCount: 120))
        f.controller.update(snapshot: snapshot(definition, id: runID, status: .running(index: 1), receipts: [receipt], bytes: 256))
        var cancellations = 0
        f.controller.onCancel = { id, _ in
            XCTAssertEqual(id, runID); cancellations += 1
            f.controller.update(snapshot: self.snapshot(definition, id: id, status: .cancelling, receipts: [receipt], bytes: 256))
        }
        try press("cancel", in: f.controller); try press("cancel", in: f.controller)
        await drainCommands(); XCTAssertEqual(cancellations, 1)
        f.controller.update(snapshot: snapshot(definition, id: runID, status: .cancelled, receipts: [receipt]))
        let summary: NSTextField = try view("run-status", in: f.controller)
        XCTAssertTrue(summary.stringValue.contains("仍然保留"))
        XCTAssertEqual(f.controller.displayedSnapshot?.receipts, [receipt])
        f.controller.onCancel = nil
    }

    func testSameRunProgressCannotDropOrDuplicateCancellationRequest() async throws {
        let definition = try definition(), f = try fixture(definition: definition); defer { f.close() }
        let runID = UUID(); var cancelled: [UUID] = []
        f.controller.onCancel = { id, _ in cancelled.append(id) }
        f.controller.update(snapshot: snapshot(definition, id: runID, status: .running(index: 0), bytes: 256))
        try press("cancel", in: f.controller)
        f.controller.update(snapshot: snapshot(definition, id: runID, status: .running(index: 1), bytes: 256))
        try press("cancel", in: f.controller)
        await drainCommands(); XCTAssertEqual(cancelled, [runID])
        let cancel: NSButton = try view("cancel", in: f.controller)
        XCTAssertFalse(cancel.isEnabled)
    }

    func testNativeSecondClickAndKeyAutorepeatCannotStartAnotherCompletedRun() async throws {
        let definition = try definition(), f = try fixture(definition: definition); defer { f.close() }
        var invocations = 0
        f.controller.onRun = { _, _ in
            invocations += 1
            f.controller.update(snapshot: self.snapshot(definition, id: UUID(), status: .completed))
        }
        try press("run", in: f.controller); await drainCommands(); XCTAssertEqual(invocations, 1)
        let button: NSButton = try view("run", in: f.controller), window = try XCTUnwrap(f.controller.window)
        let double = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        button.mouseDown(with: double)
        let repeatKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
        button.keyDown(with: repeatKey); XCTAssertFalse(button.performKeyEquivalent(with: repeatKey))
        await drainCommands(); XCTAssertEqual(invocations, 1)
        try press("run", in: f.controller); await drainCommands(); XCTAssertEqual(invocations, 2)
        f.controller.onRun = nil
    }

    func testLightAndDarkUseFullNonoverlappingFramesAndAccessibleLongNames() throws {
        try withApplicationLoop {
            let definition = try self.definition(), f = try self.fixture(definition: definition); defer { f.close() }
            for mode in [NSAppearance.Name.aqua, .darkAqua] {
                try self.ready(f.controller, appearance: mode)
                if f.controller.displayedSnapshot != nil { try self.press("manage", in: f.controller) }
                let window = try XCTUnwrap(f.controller.window)
                try self.checkedLayout(window, mode: mode.rawValue + "-manager")
                let content = try XCTUnwrap(window.contentView)
                let name: NSTextField = try self.view("name", in: f.controller)
                let source: NSPopUpButton = try self.view("source", in: f.controller)
                XCTAssertTrue(name.isDescendant(of: content) && source.isDescendant(of: content))
                XCTAssertEqual(name.bounds.width, source.bounds.width, accuracy: 0.001,
                    "The cross-row width relationship must survive native manager construction")
                f.controller.update(snapshot: self.snapshot(definition, id: UUID(), status: .failed(index: 1, message: "复制失败"),
                    receipts: [.init(output: .quickSavePNG, value: .saved(URL(fileURLWithPath: "/tmp/a.png"), byteCount: 120))], bytes: 256))
                try self.checkedLayout(window, mode: mode.rawValue + "-failed")
                f.controller.update(snapshot: self.snapshot(definition, id: UUID(), status: .completed,
                    receipts: [.init(output: .quickSavePNG, value: .saved(URL(fileURLWithPath: "/tmp/a.png"), byteCount: 120)), .init(output: .copy, value: .copied)]))
                try self.checkedLayout(window, mode: mode.rawValue + "-completed")
            }
            let longName = String(repeating: "长名称", count: 20)
            let long = try CaptureChainDefinition(name: longName, source: .region, outputs: [.copy])
            try f.store.add(long); try f.store.select(id: long.id); f.controller.present()
            try self.press("manage", in: f.controller)
            let current: NSTextField = try self.view("current", in: f.controller)
            XCTAssertEqual(current.toolTip, "当前：" + longName)
            XCTAssertEqual(current.accessibilityLabel(), "当前：" + longName)
            let table: NSTableView = try self.view("list", in: f.controller)
            let cell = try XCTUnwrap(f.controller.tableView(table, viewFor: table.tableColumns.first, row: 1) as? NSTextField)
            XCTAssertTrue(cell.toolTip?.contains(longName) == true)
            XCTAssertTrue(cell.accessibilityLabel()?.contains(longName) == true)
            try self.checkedLayout(try XCTUnwrap(f.controller.window), mode: "long-names")
        }
    }

    private struct Fixture {
        let directory: URL
        let store: CaptureChainStore
        let controller: CaptureChainController
        @MainActor func close() {
            controller.onRun = nil; controller.onRetry = nil; controller.onCancel = nil; controller.onClose = nil
            controller.close(); controller.invalidateCommands()
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func fixture(definition: CaptureChainDefinition? = nil, presets: [CapturePreset] = []) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-ChainUI-" + UUID().uuidString)
        let store = try CaptureChainStore(directory: directory)
        if let definition { try store.add(definition) }
        let controller = CaptureChainController(store: store, presets: presets)
        if definition != nil {
            let table: NSTableView = try view("list", in: controller)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        return Fixture(directory: directory, store: store, controller: controller)
    }
    private func definition() throws -> CaptureChainDefinition {
        try CaptureChainDefinition(name: "工作截图", source: .region, outputs: [.quickSavePNG, .copy])
    }
    private func makePreset() throws -> CapturePreset {
        let display = try CapturePresetDisplay(uuid: UUID(), frame: .init(x: 0, y: 0, width: 800, height: 600),
            pixelWidth: 800, pixelHeight: 600, rotationDegrees: 0)
        return try CapturePreset(name: "工作区域", delay: .none, display: display,
            topLeftFrame: .init(x: 10, y: 20, width: 200, height: 100),
            pixelFrame: .init(x: 10, y: 20, width: 200, height: 100))
    }
    private func snapshot(_ definition: CaptureChainDefinition, id: UUID, status: CaptureChainStatus,
                          receipts: [CaptureChainReceipt] = [], bytes: Int = 0) -> CaptureChainSnapshot {
        CaptureChainSnapshot(runID: id, definition: definition, status: status, receipts: receipts,
            capturedAt: receipts.isEmpty ? nil : Date(timeIntervalSince1970: 1), retainedBytes: bytes)
    }
    private func view<T: NSView>(_ suffix: String, in controller: CaptureChainController) throws -> T {
        let root = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "capture-chain-" + suffix } as? T)
    }
    private func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
    private func dispatch(_ control: NSControl, action: Selector? = nil) throws {
        let action = try XCTUnwrap(action ?? control.action)
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control))
    }
    private func press(_ suffix: String, in controller: CaptureChainController) throws {
        let button: NSButton = try view(suffix, in: controller); try dispatch(button)
    }
    private func click(_ suffix: String, in controller: CaptureChainController) throws {
        let button: NSButton = try view(suffix, in: controller); try PortableSettingsUIPreviewFixture.click(button)
    }
    private func edited(_ field: NSTextField, in controller: CaptureChainController) {
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    private func drainCommands() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func ready(_ controller: CaptureChainController, appearance: NSAppearance.Name = .aqua) throws {
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: appearance); window.animationBehavior = .none
        controller.present(); NSApp.activate(ignoringOtherApps: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !window.isKeyWindow, ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        _ = try XCTUnwrap(window.isKeyWindow ? true : nil, "Owned capture-chain window did not become key")
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    private func checkedLayout(_ window: NSWindow, mode: String) throws {
        do {
            let result = try CaptureChainUIPreviewFixture.assertLayout(window: window, phase: mode)
            XCTAssertEqual(result["fullVisibleFramesChecked"] as? Bool, true)
            XCTAssertEqual(result["controlsDoNotOverlap"] as? Bool, true)
        } catch {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-ChainUI-Failure-" + UUID().uuidString)
            _ = try? CaptureChainUIPreviewFixture.captureOwnedEvidence(window: window, phase: mode, evidenceDirectory: directory)
            throw error
        }
    }

    /// The established native-test host contract: borrow an existing loop, or
    /// own/stop only the loop started here and always restore activation policy.
    private func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        _ = NSApplication.shared
        if NSApp.isRunning { try body(); return }
        _ = try XCTUnwrap(NSApp.modalWindow == nil && NSApp.delegate == nil ? true : nil,
            "Standalone UI host unexpectedly has a modal window or application delegate")
        _ = try XCTUnwrap(UserDefaults.standard.object(forKey: "NSOpen") == nil ? true : nil,
            "Standalone UI host unexpectedly has a file-open request")
        let originalPolicy = NSApp.activationPolicy(), state = CaptureChainTestApplicationLoop()
        defer {
            state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
            if NSApp.activationPolicy() != originalPolicy { _ = NSApp.setActivationPolicy(originalPolicy) }
            XCTAssertEqual(NSApp.activationPolicy(), originalPolicy)
        }
        if originalPolicy == .prohibited {
            _ = try XCTUnwrap(NSApp.setActivationPolicy(.accessory) ? true : nil,
                "Native capture-chain interaction requires an activatable owned application")
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
                            finish(.failure(NSError(domain: "PicShot.CaptureChainUITestHost", code: 1,
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

@MainActor private final class CaptureChainTestApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}
