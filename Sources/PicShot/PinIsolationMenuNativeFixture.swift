import AppKit
import CryptoKit
import PicShotCore

/// Installed-app acceptance for the compact catalog's real context menu. All
/// input and pixels belong to synthetic windows in this process; no global input
/// or desktop capture. Coordinator state is checked separately from menu receipt.
@MainActor enum PinIsolationMenuNativeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let started = ProcessInfo.processInfo.systemUptime
        var report: [String: Any] = ["schema": 1, "status": "running",
            "scope": "Owned native group-manager context menu, real coordinator, synthetic image and rich pins",
            "inputRoute": "owned-nextEvent-sendEvent/native-context-menu-tracking",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "overallDeadlineSeconds": 120, "menuDeadlineSeconds": 2, "ownershipDeadlineSeconds": 4,
            "maximumRasterPixels": 4_000_000, "cyclesPerAppearance": 4,
            "networkUsed": false, "globalInputPosted": false, "permissionRequests": false,
            "userPreferencesWritten": false, "liveScreenCaptured": false, "memoryStabilityAssessed": false,
            "globalHotkeysRegistered": false, "ordinaryTextCaptured": false]
        let reportURL = evidenceDirectory.appendingPathComponent("pin-isolation-menu.json")
        var modes: [[String: Any]] = [], owners: [WeakOwner] = []
        do {
            report["executableSHA256"] = try Bundle.main.executableURL.map(fileHash) ?? "unavailable"
            let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
            report["infoPlistSHA256"] = FileManager.default.fileExists(atPath: plist.path) ? try fileHash(plist) : "unavailable-in-test-host"
            try require(NSApp.isRunning && NSApp.isActive && NSScreen.main != nil, "An active native app loop is required")
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                modes.append(try await flow(mode, appearance, evidenceDirectory, &owners))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while owners.contains(where: { !$0.released }), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            report["ownership"] = owners.map(\.receipt)
            report["resourceCounts"] = ["observedOwners": owners.count, "releasedOwners": owners.filter(\.released).count,
                                        "appearanceCount": modes.count, "completedIsolateRestoreCycles": 8]
            try require(owners.allSatisfy(\.released), "Owned controller, content or window retained after four seconds")
            let hashes = modes.compactMap { ($0["visual"] as? [String: Any])?["sha256"] as? String }
            try require(hashes.count == 2 && hashes[0] != hashes[1], "Light/dark native pixels are identical or absent")
            try require(ProcessInfo.processInfo.systemUptime - started < 120, "Overall native isolation deadline exceeded")
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["modes"] = modes; report["ownership"] = owners.map(\.receipt)
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try? write(report, to: reportURL)
            throw error
        }
        report["modes"] = modes; report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        try write(report, to: reportURL)
        return report
    }

    private static func flow(_ mode: String, _ appearance: NSAppearance.Name, _ output: URL,
                             _ owners: inout [WeakOwner]) async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-IsolationMenu-" + UUID().uuidString)
        let store = try PinSessionStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = PinSessionCoordinator(store: store,
            desktopVisibilityService: PinDesktopVisibilityService(defaults: nil), ocrPreferences: PinOCRPreferences(defaults: nil))
        defer { try? session.prepareForTermination() }
        let current = try store.createGroup(name: "当前参考", color: .purple)
        let other = try store.createGroup(name: "另一组", color: .green)
        try store.setActiveGroup(id: current.id)
        let image = ImageEditorRenderer.makeSampleImage()
        let imageID = try session.add(image: image, title: "图片参考")
        let textID = try session.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: "隔离文字\nNative rich pin 🖼️")), title: "文字参考"))
        let siblingID = try session.add(image: image, title: "其他显示项")
        let archivedID = try store.add(image: image, title: "归档项", groupID: current.id).id
        try store.archive(id: archivedID)
        let foreignID = try store.add(image: image, title: "其他组项目", groupID: other.id).id
        try session.flushPresentationChanges()
        let manager = PinGroupsController(store: store, transforms: session.groupTransforms)
        defer { manager.close() }
        let window = try required(manager.window, "Group window absent")
        owners.append(WeakOwner(manager, label: mode + ".manager"))
        for (id, controller) in session.liveControllers { owners.append(WeakOwner(controller, label: mode + ".image." + id.uuidString)) }
        for (id, controller) in session.richControllers { owners.append(WeakOwner(controller, label: mode + ".rich." + id.uuidString)) }
        var isolateCalls = 0, restoreCalls = 0, showCalls = 0, openCalls = 0
        var errors: [String] = [], changeErrors: [Error] = [], errorModalStates: [Bool] = []
        manager.onChangeError = { errors.append($0.localizedDescription); changeErrors.append($0); errorModalStates.append(NSApp.modalWindow != nil) }
        session.onError = { errors.append($0.localizedDescription) }
        manager.onIsolatePins = { [weak session] ids in isolateCalls += 1; try session?.isolatePins(ids) }
        manager.onRestoreIsolatedPins = { [weak session] in restoreCalls += 1; try session?.restoreVisibilityIsolation() }
        manager.visibilityIsolationAvailable = { [weak session] in session?.hasVisibilityIsolation == true }
        manager.visiblePinIDsForIsolation = { [weak session] in session?.visiblePinIDsForIsolation ?? [] }
        manager.onShowGroup = { [weak session] in showCalls += 1; try session?.showCurrentGroup() }
        manager.onOpenPin = { _ in openCalls += 1 }
        manager.onSessionChange = { [weak session] in do { try session?.reconcileVisiblePins() } catch { errors.append(error.localizedDescription) } }
        window.appearance = NSAppearance(named: appearance); window.animationBehavior = .none
        manager.showWindow(nil); try show(window)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 680, height: 600)), display: true)
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); window.center()
        let table: NSTableView = try control("pin-group-entries", in: window)
        let menu = try required(table.menu, "Table context menu absent")
        let isolate = try item("pin-group-isolate-selected", in: menu)
        let restore = try item("pin-group-restore-isolation", in: menu)
        try require(isolate.title == "仅显示所选贴图" && restore.title == "恢复隔离前显示", "Isolation menu labels changed")
        let identifiers = Set(descendants(window.contentView).compactMap { $0.identifier?.rawValue })
        let oldIDs: Set<String> = ["pin-group-picker", "pin-group-order", "pin-group-heading", "pin-group-entries", "pin-group-move-pin",
            "pin-group-show", "pin-group-hide-all", "pin-group-open-pin", "pin-group-rename-pin", "pin-group-remove-pin",
            "pin-group-transform", "pin-group-align", "pin-group-undo", "pin-group-redo"]
        try require(oldIDs.isSubset(of: identifiers), "An existing compact control identifier was lost")
        var rows: [[String: Any]] = [], cycles: [[String: Any]] = []
        let modeURL = output.appendingPathComponent("pin-isolation-menu-" + mode + ".json")
        var result: [String: Any] = ["appearance": mode, "oldControlIDs": oldIDs.sorted(), "minimumWindowSize": [680, 600]]
        func checkpoint() throws {
            result["menuEvents"] = rows; result["cycles"] = cycles
            result["isolateCallbacks"] = isolateCalls; result["restoreCallbacks"] = restoreCalls
            result["showCallbacks"] = showCalls; result["openCallbacks"] = openCalls
            result["errors"] = errors; result["errorModalStates"] = errorModalStates
            result["liveIDs"] = session.livePinIDs.map(\.uuidString).sorted()
            result["visibleIDs"] = session.visiblePinIDsForIsolation.map(\.uuidString).sorted()
            result["selectedIDs"] = manager.selectedPinIDs.map(\.uuidString).sorted()
            result["isolationActive"] = session.hasVisibilityIsolation
            try write(result, to: modeURL)
        }
        func track(_ id: String, cancel: Bool, enabled: Bool, phase: String, pixels: Bool = false) async throws {
            try show(window)
            rows.append(try await context(table: table, id: id, cancel: cancel, expectedEnabled: enabled,
                output: output, stem: "pin-isolation-menu-" + mode + "-" + phase, captureMenu: pixels))
            try checkpoint()
        }
        do {
            table.deselectAll(nil)
            try await track("pin-group-isolate-selected", cancel: true, enabled: false, phase: "empty")
            try require(isolateCalls == 0 && restoreCalls == 0, "Empty selection dispatched isolation")
            let selected: Set<UUID> = [imageID, textID]
            try select(selected, table: table, store: store)
            let before = try manifest(store), assets = try assetHashes(root), entries = store.index
            let originalControllers = controllerIdentities(session), originalVisible: Set<UUID> = [imageID, textID, siblingID]
            try require(session.visiblePinIDsForIsolation == originalVisible, "Initial live visibility mismatch")
            result["visual"] = try pixels(window, name: "pin-isolation-manager-" + mode + ".png", in: output, compact: true)
            try await track("pin-group-isolate-selected", cancel: true, enabled: true, phase: "cancel", pixels: true)
            try require(!session.hasVisibilityIsolation && session.visiblePinIDsForIsolation == originalVisible && isolateCalls == 0,
                        "Escape changed isolation or dispatched a callback")
            try require(manager.selectedPinIDs == selected, "Right-click/Escape replaced the multi-selection")
            // Repeated native tracking proves callbacks and controller identity;
            // it is not a claim about whole-process or framework memory leakage.
            for cycle in 0..<4 {
                try await track("pin-group-isolate-selected", cancel: false, enabled: true, phase: "isolate-\(cycle)", pixels: cycle == 0)
                let isolated = visibility(session)
                cycles.append(["cycle": cycle, "phase": "isolated", "visibility": isolated,
                    "selectionPreserved": manager.selectedPinIDs == selected, "sameControllers": controllerIdentities(session) == originalControllers,
                    "manifestUnchanged": try manifest(store) == before, "assetsUnchanged": try assetHashes(root) == assets, "entriesUnchanged": store.index == entries])
                try checkpoint()
                try require(session.hasVisibilityIsolation && session.visiblePinIDsForIsolation == selected, "Isolate did not hide the unselected live pin")
                try require(manager.selectedPinIDs == selected && controllerIdentities(session) == originalControllers, "Isolate lost selection/controller identity")
                try require(session.richControllers[textID]?.kind == .text && session.liveControllers[imageID] != nil, "Image/rich controller types changed")
                if cycle == 0 {
                    manager.onRestoreIsolatedPins = { restoreCalls += 1; throw failure("injected-restore-refusal") }
                    try await track("pin-group-restore-isolation", cancel: false, enabled: true, phase: "restore-refusal")
                    try require(errors.count == 1 && errorModalStates == [false] && NSApp.modalWindow == nil &&
                                session.hasVisibilityIsolation && session.visiblePinIDsForIsolation == selected && manager.selectedPinIDs == selected,
                                "Restore refusal lost active isolation/selection or entered a modal error")
                    manager.onRestoreIsolatedPins = { [weak session] in restoreCalls += 1; try session?.restoreVisibilityIsolation() }
                }
                try await track("pin-group-restore-isolation", cancel: false, enabled: true, phase: "restore-\(cycle)", pixels: cycle == 0)
                cycles.append(["cycle": cycle, "phase": "restored", "visibility": visibility(session),
                    "selectionPreserved": manager.selectedPinIDs == selected, "sameControllers": controllerIdentities(session) == originalControllers,
                    "manifestUnchanged": try manifest(store) == before, "assetsUnchanged": try assetHashes(root) == assets, "entriesUnchanged": store.index == entries])
                try checkpoint()
                try require(!session.hasVisibilityIsolation && session.visiblePinIDsForIsolation == originalVisible, "Restore did not restore prior native visibility")
                try require(manager.selectedPinIDs == selected && controllerIdentities(session) == originalControllers, "Restore lost selection/controller identity")
                try require(try manifest(store) == before && assetHashes(root) == assets && store.index == entries, "Temporary isolation persisted or mutated assets")
            }
            try await track("pin-group-restore-isolation", cancel: true, enabled: false, phase: "restore-inactive")
            // Inject only the operation failure; the real menu still owns dispatch.
            manager.onIsolatePins = { _ in isolateCalls += 1; throw failure("injected-isolation-refusal") }
            try await track("pin-group-isolate-selected", cancel: false, enabled: true, phase: "refusal")
            try require(errors.count == 2 && errorModalStates == [false, false] && NSApp.modalWindow == nil,
                        "Isolation refusal did not use the injected nonmodal error handler")
            try require(manager.selectedPinIDs == selected && session.visiblePinIDsForIsolation == originalVisible && !session.hasVisibilityIsolation,
                        "Refused command changed selection or visibility")
            manager.onIsolatePins = { [weak session] ids in isolateCalls += 1; try session?.isolatePins(ids) }
            try await track("pin-group-isolate-selected", cancel: false, enabled: true, phase: "before-show")
            let showButton: NSButton = try control("pin-group-show", in: window)
            try PortableSettingsUIPreviewFixture.click(showButton)
            try await settle()
            try require(showCalls == 1 && !session.hasVisibilityIsolation && session.visiblePinIDsForIsolation == originalVisible,
                        "Explicit Show did not go through the coordinator and end isolation")
            try select([archivedID], table: table, store: store)
            try await track("pin-group-isolate-selected", cancel: true, enabled: false, phase: "archived")
            try require(!session.livePinIDs.contains(archivedID) && openCalls == 0, "Archive context menu loaded a pin")
            // An entry moved while the menu rows are stale cannot isolate another group.
            try select([siblingID], table: table, store: store)
            try store.movePin(id: siblingID, to: other.id)
            menu.delegate?.menuNeedsUpdate?(menu)
            try require(!isolate.isEnabled, "Foreign stale table row enabled isolation")
            try session.reconcileVisiblePins(); manager.reload()
            try select([imageID], table: table, store: store)
            try session.hideCurrentGroup(); manager.reload()
            try select([imageID], table: table, store: store)
            try await track("pin-group-isolate-selected", cancel: true, enabled: false, phase: "hidden")
            try require(session.livePinIDs.isEmpty && !session.livePinIDs.contains(foreignID) && openCalls == 0,
                        "Hidden/foreign context menu opened content")
            try session.showCurrentGroup(); manager.reload(); try show(window)
            for (id, controller) in session.liveControllers { owners.append(WeakOwner(controller, label: mode + ".reopened-image." + id.uuidString)) }
            for (id, controller) in session.richControllers { owners.append(WeakOwner(controller, label: mode + ".reopened-rich." + id.uuidString)) }
            result["groupPromptCancellations"] = try groupPromptResponses(manager, store: store, duplicateName: other.name,
                saveDuplicate: false, changeErrors: { changeErrors }, output: output, mode: mode)
            try checkpoint()
            result["groupPromptCollisions"] = try groupPromptResponses(manager, store: store, duplicateName: other.name,
                saveDuplicate: true, changeErrors: { changeErrors }, output: output, mode: mode)
            try checkpoint()
            try require(isolateCalls == 6 && restoreCalls == 5 && errors.count == 4 && errorModalStates == [false, false, false, false], "Unexpected context-menu callback counts")
            result["status"] = "passed"; try checkpoint()
            return result
        } catch {
            result["status"] = "failed"; result["error"] = error.localizedDescription
            try? checkpoint(); throw error
        }
    }

    private static func select(_ ids: Set<UUID>, table: NSTableView, store: PinSessionStore) throws {
        let entries = store.entries.filter { $0.groupID == store.index.activeGroupID }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        let rows = entries.indices.filter { ids.contains(entries[$0].id) }
        try require(rows.count == ids.count && !rows.isEmpty, "Selection rows missing")
        _ = try PortableSettingsUIPreviewFixture.clickRow(rows[0], in: table)
        for row in rows.dropFirst() {
            table.scrollRowToVisible(row)
            _ = try ownedClick(table, row: row, right: false, modifiers: .command)
        }
        try require(table.selectedRowIndexes == IndexSet(rows), "Native Command-click did not retain the requested rows")
    }

    private static func context(table: NSTableView, id: String, cancel: Bool, expectedEnabled: Bool,
                                output: URL, stem: String, captureMenu: Bool) async throws -> [String: Any] {
        let menu = try required(table.menu, "Context menu missing"), window = try required(table.window, "Context owner missing")
        menu.delegate?.menuNeedsUpdate?(menu)
        let target = try item(id, in: menu)
        try require(target.isEnabled == expectedEnabled, "Context enabled state differs: " + id)
        let selection = table.selectedRowIndexes
        let probe = ContextProbe(menu: menu, table: table, target: target, cancel: cancel,
                                 output: output, stem: stem, captureMenu: captureMenu)
        let previous = menu.delegate; probe.previous = previous; menu.delegate = probe
        probe.start()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak probe] _ in MainActor.assumeIsolated { probe?.tick() } }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); probe.finish(); menu.delegate = previous }
        // Right-click an unselected row when possible; the command must keep
        // the existing multi-selection instead of targeting that row implicitly.
        let row = (0..<table.numberOfRows).first { !selection.contains($0) } ?? max(0, table.selectedRow)
        table.scrollRowToVisible(row)
        probe.mouse = try ownedClick(table, row: row, right: true)
        probe.returnedAt = ProcessInfo.processInfo.systemUptime - probe.started
        while !probe.complete && !probe.failed && ProcessInfo.processInfo.systemUptime < probe.deadline { try await settle(10_000_000) }
        var receipt = probe.receipt
        receipt["windowNumber"] = window.windowNumber; receipt["selectionBefore"] = Array(selection)
        receipt["selectionAfter"] = Array(table.selectedRowIndexes); receipt["expectedEnabled"] = expectedEnabled
        try write(receipt, to: output.appendingPathComponent(stem + "-event.json"))
        try require(probe.complete && !probe.failed && probe.returnedAt <= 2 && (cancel || probe.returnVerified),
                    "Native context tracking failed: " + stem)
        try require(table.selectedRowIndexes == selection, "Context command changed the table selection")
        return receipt
    }

    /// Same identity-checked post/dequeue/send route as clickRow, extended only
    /// for owned right clicks and Command multi-selection in this fixture.
    private static func ownedClick(_ table: NSTableView, row: Int, right: Bool,
                                   modifiers: NSEvent.ModifierFlags = []) throws -> [String: Any] {
        let window = try required(table.window, "Table window missing"), root = try required(window.contentView, "Table root missing")
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let frame = table.rect(ofRow: row), point = CGPoint(x: frame.midX, y: frame.midY)
        try require(table.visibleRect.contains(point), "Owned table click is outside its viewport")
        let location = table.convert(point, to: nil)
        let hit = root.hitTest(root.convert(root.convert(location, from: nil), to: root.superview))
        try require(hit === table || hit?.isDescendant(of: table) == true, "Owned table target obscured")
        let down = try required(NSEvent.mouseEvent(with: right ? .rightMouseDown : .leftMouseDown, location: location,
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1), "Mouse down missing")
        let up = try required(NSEvent.mouseEvent(with: right ? .rightMouseUp : .leftMouseUp, location: location,
            modifierFlags: modifiers, timestamp: down.timestamp + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0), "Mouse up missing")
        let clock = try required(down.cgEvent?.timestamp, "Owned mouse clock missing")
        NSApp.postEvent(down, atStart: true)
        let owned = try required(NSApp.nextEvent(matching: right ? .rightMouseDown : .leftMouseDown,
            until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true), "Owned mouse not dequeued")
        guard clock > 0 && owned.cgEvent?.timestamp == clock && owned.type == down.type &&
            owned.windowNumber == window.windowNumber && owned.locationInWindow == location &&
            owned.eventNumber == down.eventNumber && owned.clickCount == 1 && owned.modifierFlags == modifiers else {
            NSApp.postEvent(owned, atStart: true); throw failure("Foreign event restored before native input")
        }
        let current = try required(NSApp.currentEvent, "Native current event missing")
        try require(current.cgEvent?.timestamp == clock && current.windowNumber == window.windowNumber && current.type == owned.type &&
                    current.locationInWindow == owned.locationInWindow && current.modifierFlags == owned.modifierFlags &&
                    current.eventNumber == owned.eventNumber && current.clickCount == owned.clickCount,
                    "Native current event differs from owned input")
        let receipt: [String: Any] = ["route": "owned-nextEvent-sendEvent", "type": Int(owned.type.rawValue),
            "windowNumber": owned.windowNumber, "quartzTimestamp": clock, "currentQuartzTimestamp": current.cgEvent!.timestamp,
            "hitTestVerified": true, "sameEventIdentity": true, "location": [location.x, location.y], "modifiers": modifiers.rawValue,
            "eventNumber": down.eventNumber, "clickCount": down.clickCount,
            "dequeuedQuartzTimestamp": owned.cgEvent!.timestamp, "dequeuedType": Int(owned.type.rawValue),
            "dequeuedWindowNumber": owned.windowNumber, "dequeuedLocation": [owned.locationInWindow.x, owned.locationInWindow.y],
            "dequeuedModifiers": owned.modifierFlags.rawValue, "dequeuedEventNumber": owned.eventNumber, "dequeuedClickCount": owned.clickCount,
            "currentType": Int(current.type.rawValue), "currentWindowNumber": current.windowNumber,
            "currentLocation": [current.locationInWindow.x, current.locationInWindow.y], "currentModifiers": current.modifierFlags.rawValue,
            "currentEventNumber": current.eventNumber, "currentClickCount": current.clickCount]
        NSApp.postEvent(up, atStart: true); NSApp.sendEvent(owned)
        return receipt
    }

    private static func groupPromptResponses(_ manager: PinGroupsController, store: PinSessionStore,
                                              duplicateName: String, saveDuplicate: Bool, changeErrors: () -> [Error],
                                              output: URL, mode: String) throws -> [[String: Any]] {
        let window = try required(manager.window, "Group prompt owner missing")
        var receipts: [[String: Any]] = []
        for id in ["pin-group-add", "pin-group-rename"] {
            let before = try manifest(store), index = store.index, errorCount = changeErrors().count
            var timer: Timer?, observed = false, clicked = false, promptError: Error?
            manager.onGroupPromptPrepared = { alert in
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                timer = Timer(timeInterval: 0.02, repeats: true) { [weak alert] _ in
                    MainActor.assumeIsolated {
                        guard let alert else { timer?.invalidate(); return }
                        guard !clicked && promptError == nil else { return }
                        guard ProcessInfo.processInfo.systemUptime < deadline else {
                            promptError = failure("Owned group prompt timed out")
                            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
                            timer?.invalidate(); return
                        }
                        guard NSApp.modalWindow === alert.window && alert.window.isVisible else { return }
                        do {
                            observed = true
                            let field = try required(descendants(alert.accessoryView).compactMap { $0 as? NSTextField }.first, "Group name field missing")
                            let editor = try required(field.currentEditor() as? NSTextView, "Group prompt field editor missing")
                            editor.insertText(duplicateName, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                            try require(editor.string == duplicateName, "Duplicate-name draft is not visible in the native field")
                            let button = try required(alert.buttons.first { $0.title == (saveDuplicate ? "保存" : "取消") }, "Group response button missing")
                            try PortableSettingsUIPreviewFixture.click(button); clicked = true; timer?.invalidate()
                        } catch {
                            promptError = error
                            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
                            timer?.invalidate()
                        }
                    }
                }
                if let timer { RunLoop.main.add(timer, forMode: .modalPanel) }
            }
            defer { timer?.invalidate(); timer = nil; manager.onGroupPromptPrepared = nil }
            let button: NSButton = try control(id, in: window)
            try PortableSettingsUIPreviewFixture.click(button)
            if let promptError { throw promptError }
            let after = try manifest(store), feedback = Array(changeErrors().dropFirst(errorCount))
            var receipt: [String: Any] = ["controlID": id, "promptObserved": observed,
                "draftWasExistingGroupName": true, "manifestUnchanged": after == before,
                "groupIDsUnchanged": store.groups.map(\.id) == index.groups.map(\.id), "indexUnchanged": store.index == index]
            if saveDuplicate {
                receipt["nativeSaveClicked"] = clicked
                receipt["errorCount"] = feedback.count
                receipt["errorCase"] = (feedback.first as? PinSessionError) == .duplicateGroupName ? "duplicateGroupName" : "unexpected"
                receipt["feedback"] = feedback.first?.localizedDescription ?? "missing"
                receipt["errorModal"] = NSApp.modalWindow != nil
            } else { receipt["nativeCancelClicked"] = clicked }
            receipts.append(receipt)
            let operation = saveDuplicate ? "collision" : "cancel"
            try write(receipt, to: output.appendingPathComponent("pin-isolation-menu-" + mode + "-" + id + "-" + operation + ".json"))
            try require(observed && clicked && NSApp.modalWindow == nil && store.index == index && after == before,
                        "Duplicate group-name response changed the stored group or left a modal prompt")
            if saveDuplicate {
                try require(feedback.count == 1 && (feedback.first as? PinSessionError) == .duplicateGroupName &&
                            feedback.first?.localizedDescription == PinSessionError.duplicateGroupName.localizedDescription,
                            "Native Save did not report the exact duplicate-group-name feedback")
            } else { try require(feedback.isEmpty, "Cancelled group draft reported an error") }
        }
        return receipts
    }

    @MainActor private final class ContextProbe: NSObject, NSMenuDelegate {
        weak var menu: NSMenu?, table: NSTableView?, target: NSMenuItem?, previous: NSMenuDelegate?
        let started = ProcessInfo.processInfo.systemUptime
        var deadline: TimeInterval { started + 2 }
        let cancel: Bool, output: URL, stem: String, captureMenu: Bool
        let existingWindows: Set<Int>
        var began = 0, ended = 0, opened = false, closed = false, failed = false, posted = 0
        var lastKey: UInt16?, returnVerified = false, returnedAt = TimeInterval.infinity
        var mouse: [String: Any] = [:], menuPixels: [String: Any] = ["status": "not-requested"]
        private var beginElapsed: TimeInterval?, endElapsed: TimeInterval?, openElapsed: TimeInterval?, closeElapsed: TimeInterval?
        private var returnElapsed: TimeInterval?, returnItemID: String?
        private var beginIdentity = false, endIdentity = false, openIdentity = false, closeIdentity = false
        private var returnIdentity = false, returnEnabled = false, returnHighlighted = false
        private var observers: [NSObjectProtocol] = []
        private var entered = false, pixelAttempted = false, cancellationIssued = false
        var complete: Bool {
            began == 1 && ended == 1 && beginIdentity && endIdentity &&
                (beginElapsed ?? .infinity) <= 2 && (endElapsed ?? .infinity) <= 2 &&
                (endElapsed ?? -.infinity) >= (beginElapsed ?? .infinity) &&
                (cancel || (closed && closeIdentity && returnVerified && returnIdentity &&
                    (returnElapsed ?? .infinity) <= 2 && (closeElapsed ?? .infinity) <= 2 &&
                    (closeElapsed ?? -.infinity) >= (returnElapsed ?? .infinity)))
        }
        init(menu: NSMenu, table: NSTableView, target: NSMenuItem, cancel: Bool, output: URL, stem: String, captureMenu: Bool) {
            self.menu = menu; self.table = table; self.target = target; self.cancel = cancel
            self.output = output; self.stem = stem; self.captureMenu = captureMenu
            existingWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)); super.init()
        }
        var receipt: [String: Any] {
            ["itemID": target?.identifier?.rawValue ?? "missing", "cancelledWithEscape": cancel && lastKey == 53,
             "opened": opened, "closed": closed, "trackingBeginCount": began, "trackingEndCount": ended,
             "exactOwnedMenu": menu != nil && table?.menu === menu && target?.menu === menu && (menu?.delegate as AnyObject?) === self,
             "returnHighlightVerified": returnVerified, "postedKeyCount": posted, "lastKeyCode": lastKey.map(Int.init) ?? -1,
             "failed": failed, "clickReturnedSeconds": returnedAt.isFinite ? returnedAt : -1, "deadlineSeconds": 2,
             "trackingBeginElapsedSeconds": beginElapsed.map { $0 as Any } ?? NSNull(),
             "trackingEndElapsedSeconds": endElapsed.map { $0 as Any } ?? NSNull(),
             "trackingIdentityVerified": beginIdentity && endIdentity,
             "delegateOpenElapsedSeconds": openElapsed.map { $0 as Any } ?? NSNull(), "delegateOpenIdentityVerified": openIdentity,
             "delegateCloseElapsedSeconds": closeElapsed.map { $0 as Any } ?? NSNull(), "delegateCloseIdentityVerified": closeIdentity,
             "returnHighlightElapsedSeconds": returnElapsed.map { $0 as Any } ?? NSNull(),
             "returnTargetMenuIdentityVerified": returnIdentity, "returnTargetEnabled": returnEnabled,
             "returnTargetHighlighted": returnHighlighted, "returnHighlightedItemID": returnItemID.map { $0 as Any } ?? NSNull(),
             "failureCancellationIssued": cancellationIssued, "mouseDispatch": mouse, "menuPixels": menuPixels]
        }
        func start() {
            guard let menu else { failed = true; return }
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: menu, queue: nil) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, let actual = note.object as? NSMenu, actual === self.menu,
                              self.table?.menu === actual, (actual.delegate as AnyObject?) === self else { self?.failed = true; return }
                        let elapsed = ProcessInfo.processInfo.systemUptime - self.started
                        if elapsed > 2 { self.failed = true }
                        if note.name == NSMenu.didBeginTrackingNotification {
                            self.began += 1
                            if self.beginElapsed == nil { self.beginElapsed = elapsed; self.beginIdentity = true }
                            if self.ended != 0 { self.failed = true }
                        } else {
                            self.ended += 1
                            if self.endElapsed == nil { self.endElapsed = elapsed; self.endIdentity = true }
                        }
                        if self.began != 1 || self.ended > 1 { self.failed = true }
                    }
                })
            }
        }
        func finish() {
            if !complete { cancelOwnedTracking() }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        }
        private func cancelOwnedTracking() {
            guard !cancellationIssued, !complete, let menu, table?.menu === menu,
                  (menu.delegate as AnyObject?) === self else { return }
            cancellationIssued = true; menu.cancelTrackingWithoutAnimation()
        }
        private func owns(_ menu: NSMenu) -> Bool {
            menu === self.menu && table?.menu === menu && (menu.delegate as AnyObject?) === self
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard owns(menu), ProcessInfo.processInfo.systemUptime <= deadline else { failed = true; return }
            previous?.menuNeedsUpdate?(menu)
        }
        func menuWillOpen(_ menu: NSMenu) {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard owns(menu), openElapsed == nil else { failed = true; return }
            openElapsed = elapsed; openIdentity = true; opened = true
            if elapsed > 2 { failed = true }
            previous?.menuWillOpen?(menu)
        }
        func menuDidClose(_ menu: NSMenu) {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard owns(menu), closeElapsed == nil else { failed = true; return }
            closeElapsed = elapsed; closeIdentity = true; closed = true
            if elapsed > 2 { failed = true }
            previous?.menuDidClose?(menu)
        }
        func tick() {
            guard !complete else { return }
            guard !failed && ProcessInfo.processInfo.systemUptime < deadline && posted < 40 else {
                failed = true; cancelOwnedTracking(); return
            }
            guard began == 1 && ended == 0 && !entered, let menu, let table, let target,
                  table.menu === menu, target.menu === menu, (menu.delegate as AnyObject?) === self,
                  let window = table.window else { return }
            if captureMenu && !pixelAttempted {
                pixelAttempted = true
                // Only public owned AppKit windows; some macOS versions host
                // menu pixels outside this list. Keep that limitation explicit.
                let candidates = NSApp.windows.filter {
                    $0.isVisible && !existingWindows.contains($0.windowNumber) && $0 !== window &&
                        NSStringFromClass(type(of: $0)).localizedCaseInsensitiveContains("menu")
                }
                if candidates.count == 1, let native = candidates.first, native.contentView != nil {
                    do {
                        menuPixels = try pixels(native, name: stem + "-native-menu.png", in: output, compact: false)
                        menuPixels["ownedWindowClass"] = NSStringFromClass(type(of: native))
                        menuPixels["observation"] = "single-new-owned-menu-window-during-exact-menu-tracking"
                    }
                    catch { menuPixels = ["status": "unavailable", "reason": error.localizedDescription] }
                } else { menuPixels = ["status": "unavailable", "reason": "Native menu is not exposed as one owned AppKit content window", "candidateCount": candidates.count] }
            }
            let selected = menu.highlightedItem === target && target.isHighlighted && target.isEnabled
            let code: UInt16 = cancel ? 53 : selected ? 36 : 125
            let characters = cancel ? "\u{1b}" : selected ? "\r" : "\u{f701}"
            let now = ProcessInfo.processInfo.systemUptime
            guard now <= deadline, owns(menu), target.menu === menu else { failed = true; cancelOwnedTracking(); return }
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { failed = true; return }
            if !cancel && selected {
                returnElapsed = now - started; returnIdentity = true; returnEnabled = target.isEnabled
                returnHighlighted = target.isHighlighted && menu.highlightedItem === target
                returnItemID = target.identifier?.rawValue
                returnVerified = returnEnabled && returnHighlighted
            }
            entered = cancel || selected; lastKey = code; posted += 1
            NSApp.postEvent(event, atStart: true)
        }
    }

    private static func pixels(_ window: NSWindow, name: String, in directory: URL, compact: Bool) throws -> [String: Any] {
        let view = try required(window.contentView, "Owned pixels need a content view")
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try require(width > 0 && height > 0 && width <= 4_000_000 / height, "Owned pixel bound exceeded")
        let bitmap = try required(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Owned bitmap allocation failed")
        bitmap.size = view.bounds.size
        let colorSpace = try required(CGColorSpace(name: CGColorSpace.sRGB), "Owned color space missing")
        let context = try required(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Owned composition allocation failed")
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let image = bitmap.cgImage { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        let image = try required(context.makeImage(), "Owned composed image missing")
        let data = try required(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "Owned PNG encoding failed")
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        var result: [String: Any] = ["status": "captured", "file": name, "sha256": hash(data), "pixelWidth": width,
            "pixelHeight": height, "windowNumber": window.windowNumber, "windowFrame": rect(window.frame), "contentBounds": rect(view.bounds),
            "opaqueWindowBackgroundComposited": true]
        if compact {
            let transformIDs: Set<String> = ["pin-group-transform", "pin-group-align", "pin-group-undo", "pin-group-redo"]
            let controls = descendants(view).compactMap { $0 as? NSButton }.filter {
                !$0.isHiddenOrHasHiddenAncestor && !transformIDs.contains($0.identifier?.rawValue ?? "")
            }
            let visible = try required(window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame, "Owned display frame missing")
            let frames = controls.map { $0.convert($0.bounds, to: view) }
            var noOverlap = true
            for first in frames.indices {
                for second in frames.indices where second > first {
                    if frames[first].insetBy(dx: 0.5, dy: 0.5).intersects(frames[second].insetBy(dx: 0.5, dy: 0.5)) { noOverlap = false }
                }
            }
            let allVisible = visible.insetBy(dx: -1, dy: -1).contains(window.frame) && frames.allSatisfy {
                view.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0)
            }
            let geometry: [[String: Any]] = controls.map { button in
                let frame = button.convert(button.bounds, to: view), minimum = button.cell?.cellSize ?? .zero
                let hit = view.hitTest(button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: view.superview))
                return ["id": button.identifier?.rawValue ?? button.title, "frame": rect(frame),
                        "minimumSize": [minimum.width, minimum.height], "hitTest": hit === button || hit?.isDescendant(of: button) == true]
            }
            result["controls"] = geometry
            result["visibleFrame"] = rect(visible); result["fullVisibleFramesChecked"] = allVisible
            result["controlsDoNotOverlap"] = noOverlap
            result["controlGeometryScope"] = "catalog-header-visibility-item-actions-restore-checkbox"
            try write(result, to: directory.appendingPathComponent(name + ".json"))
            try require(window.frame.size == NSSize(width: 680, height: 600), "Compact outer frame changed")
            try require(allVisible && noOverlap, "Compact catalog controls clipped or overlapping")
            for button in controls {
                let frame = button.convert(button.bounds, to: view)
                try require(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) && frame.width >= 18 && frame.height >= 18,
                            "Compact control clipped or below its original hit-target minimum")
                let minimum = button.cell?.cellSize ?? .zero
                try require(frame.width + 1 >= minimum.width && frame.height + 1 >= minimum.height, "Compact control title does not fit")
                let hit = view.hitTest(button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: view.superview))
                try require(hit === button || hit?.isDescendant(of: button) == true, "Compact control obscured")
            }
        }
        return result
    }
    private static func controllerIdentities(_ session: PinSessionCoordinator) -> [UUID: ObjectIdentifier] {
        var values = session.liveControllers.mapValues { ObjectIdentifier($0) }
        for (id, controller) in session.richControllers { values[id] = ObjectIdentifier(controller) }; return values
    }
    private static func visibility(_ session: PinSessionCoordinator) -> [[String: Any]] {
        let windows = session.liveControllers.mapValues(\.window).merging(session.richControllers.mapValues(\.window)) { first, _ in first }
        return windows.sorted { $0.key.uuidString < $1.key.uuidString }.map { ["id": $0.key.uuidString, "visible": $0.value?.isVisible == true] }
    }
    private static func assetHashes(_ root: URL) throws -> [String: String] {
        var values: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent != "index.json" {
            values[file.lastPathComponent] = try hash(Data(contentsOf: file))
        }; return values
    }
    private static func manifest(_ store: PinSessionStore) throws -> Data { try Data(contentsOf: store.directory.appendingPathComponent("index.json")) }
    private static func item(_ id: String, in menu: NSMenu) throws -> NSMenuItem { try required(menu.items.first { $0.identifier?.rawValue == id }, "Menu item absent: " + id) }
    private static func control<T: NSControl>(_ id: String, in window: NSWindow) throws -> T { try required(descendants(window.contentView).first { $0.identifier?.rawValue == id } as? T, "Control absent: " + id) }
    private static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func fileHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var value = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { value.update(data: data) }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private static func show(_ window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !window.isKeyWindow && ProcessInfo.processInfo.systemUptime < deadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        try require(window.isKeyWindow, "Owned window did not become key")
    }
    private static func settle(_ nanoseconds: UInt64 = 50_000_000) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
    private static func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try require(data.count <= 262_144, "Native evidence exceeds 256 KiB")
        try data.write(to: url, options: .atomic)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw failure(message) } }
    private static func required<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> NSError { NSError(domain: "PicShot.IsolationMenuFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    @MainActor private final class WeakOwner {
        weak var controller: NSWindowController?, window: NSWindow?, content: NSView?
        let label: String
        init(_ controller: NSWindowController, label: String) { self.controller = controller; window = controller.window; content = window?.contentView; self.label = label }
        var released: Bool { controller == nil && window == nil && content == nil }
        var receipt: [String: Any] { ["label": label, "controllerReleased": controller == nil, "windowReleased": window == nil, "contentReleased": content == nil] }
    }
}
