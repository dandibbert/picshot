import AppKit
import Combine
import XCTest
import PicShotCore
@testable import PicShot

/// Owned AppKit windows and native menu target/action dispatch. No capture, global
/// input events, persistent preferences, or permission changes are involved.
@MainActor final class PinGroupOrderNativeTests: XCTestCase {
    func testReorderPreservesGroupAndPinIDsAcrossReloadCloseAndReopen() async throws {
        let f = try fixture(); defer { f.close() }
        let before = f.store.index, selected = Set(f.pinIDs.prefix(2))
        try select(selected, in: f)
        let earlier = try orderItem("earlier", in: f.controller)
        try invoke(earlier)
        XCTAssertEqual(f.store.groups.map(\.id), [f.groupIDs[0], f.groupIDs[2], f.groupIDs[1], f.groupIDs[3]])
        XCTAssertEqual(f.store.index.activeGroupID, f.groupIDs[2])
        XCTAssertEqual(f.controller.selectedPinIDs, selected)
        XCTAssertEqual(f.store.entries, before.entries)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: f.store.groups.map { ($0.id, $0) }),
                       Dictionary(uniqueKeysWithValues: before.groups.map { ($0.id, $0) }))
        assertPickerIDs(f)
        f.controller.reload()
        try await drainPublishedReloads()
        XCTAssertEqual(f.controller.selectedPinIDs, selected)
        f.controller.close(); f.controller.showWindow(nil)
        XCTAssertEqual(f.controller.selectedPinIDs, selected)
        assertPickerIDs(f)
        let reloaded = try PinSessionStore(directory: f.directory)
        XCTAssertEqual(reloaded.index, f.store.index)
        let reopened = PinGroupsController(store: reloaded); defer { reopened.close() }
        let picker = try popup("pin-group-picker", in: reopened)
        XCTAssertEqual(picker.itemArray.compactMap { $0.representedObject as? UUID }, f.store.groups.map(\.id))
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, f.groupIDs[2])
    }

    func testRapidRepeatedMovesPreserveLiveTransformSelectionAndCommitExactlyOnce() async throws {
        let f = try fixture(includeTransforms: true); defer { f.close() }
        let before = f.store.index, selected = Set(f.pinIDs.prefix(2)), assets = try assetBytes(f.directory)
        try select(selected, in: f)
        XCTAssertEqual(f.session?.groupTransforms.selectedIDs, selected)
        var publications = 0, reconciliations = 0
        let subscription = f.store.$index.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        f.controller.onSessionChange = { [weak session = f.session] in
            reconciliations += 1
            guard let session else { XCTFail("Group-order reconciliation lost its session"); return }
            do { try session.reconcileVisiblePins() }
            catch { XCTFail("Group-order reconciliation failed: \(error)") }
        }
        let earlier = try orderItem("earlier", in: f.controller), later = try orderItem("later", in: f.controller)
        for _ in 0..<20 {
            try invoke(earlier); XCTAssertEqual(f.store.groups[1].id, f.groupIDs[2])
            try invoke(later); XCTAssertEqual(f.store.groups[2].id, f.groupIDs[2])
        }
        try await drainPublishedReloads()
        XCTAssertEqual(publications, 40); XCTAssertEqual(reconciliations, 40)
        XCTAssertEqual(f.store.index, before)
        XCTAssertEqual(f.controller.selectedPinIDs, selected)
        XCTAssertEqual(f.session?.groupTransforms.selectedIDs, selected)
        XCTAssertEqual(try assetBytes(f.directory), assets)
        XCTAssertEqual(try PinSessionStore(directory: f.directory).index, before)
        assertPickerIDs(f)
    }

    func testArchivedAndHiddenPinSelectionsSurviveOrderReloadWithoutOpeningPins() async throws {
        let f = try fixture(includeTransforms: true); defer { f.close() }
        try f.store.archive(id: f.pinIDs[0]); try f.session?.reconcileVisiblePins()
        f.controller.reload()
        let selected = Set(f.pinIDs.prefix(2))
        for hidden in [false, true] {
            if hidden {
                try f.store.setGroupHidden(id: f.groupIDs[2], hidden: true)
                try f.session?.reconcileVisiblePins(); f.controller.reload()
            }
            try select(selected, in: f)
            let before = f.store.index, liveIDs = f.session?.livePinIDs
            XCTAssertTrue(f.session?.groupTransforms.selectedIDs.isEmpty == true)
            try invoke(try orderItem("earlier", in: f.controller))
            try await drainPublishedReloads()
            XCTAssertEqual(f.controller.selectedPinIDs, selected)
            XCTAssertTrue(f.session?.groupTransforms.selectedIDs.isEmpty == true)
            XCTAssertEqual(f.session?.livePinIDs, liveIDs)
            XCTAssertEqual(f.store.entries, before.entries)
            XCTAssertEqual(f.store.index.activeGroupID, before.activeGroupID)
            XCTAssertEqual(f.store.groups.first { $0.id == f.groupIDs[2] }?.isHidden, hidden)
            try invoke(try orderItem("later", in: f.controller))
        }
    }

    func testBoundariesDisableActionsAndRejectStaleDispatchWithoutWriting() throws {
        let f = try fixture(); defer { f.close() }
        let earlier = try orderItem("earlier", in: f.controller), later = try orderItem("later", in: f.controller)
        try invoke(earlier); try invoke(earlier)
        XCTAssertEqual(f.store.groups.first?.id, f.groupIDs[2]); XCTAssertFalse(earlier.isEnabled)
        XCTAssertTrue(later.isEnabled)
        var attempts = 0, changes = 0
        f.store.failureInjector = { if $0 == .beforeIndexCommit { attempts += 1 } }
        f.controller.onSessionChange = { changes += 1 }
        let firstBytes = try Data(contentsOf: f.directory.appendingPathComponent("index.json"))
        try invoke(earlier, evenIfDisabled: true)
        XCTAssertEqual(attempts, 0); XCTAssertEqual(changes, 0)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("index.json")), firstBytes)
        for _ in 0..<3 { try invoke(later) }
        XCTAssertEqual(f.store.groups.last?.id, f.groupIDs[2]); XCTAssertFalse(later.isEnabled)
        XCTAssertTrue(earlier.isEnabled)
        let lastBytes = try Data(contentsOf: f.directory.appendingPathComponent("index.json"))
        attempts = 0; changes = 0
        try invoke(later, evenIfDisabled: true)
        XCTAssertEqual(attempts, 0); XCTAssertEqual(changes, 0)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("index.json")), lastBytes)
    }

    func testSingleDefaultGroupKeepsReachableDisabledOrderMenuAndExistingProtection() throws {
        try requireDisplay()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GroupOrder-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        try store.setGroupProtected(id: PinGroup.defaultID, protected: true)
        let controller = PinGroupsController(store: store); defer { controller.close() }
        let popup = try popup("pin-group-order", in: controller)
        XCTAssertTrue(popup.isEnabled)
        for direction in ["earlier", "later"] {
            let item = try orderItem(direction, in: controller)
            XCTAssertFalse(item.isEnabled); try invoke(item, evenIfDisabled: true)
        }
        XCTAssertEqual(store.groups.count, 1); XCTAssertEqual(store.groups.first?.id, PinGroup.defaultID)
        XCTAssertEqual(store.groups.first?.isProtected, true)
        let delete = descendants(controller.window?.contentView).compactMap { $0 as? NSButton }.first { $0.title == "删除组…" }
        XCTAssertEqual(delete?.isEnabled, false)
    }

    func testDefaultAndProtectedGroupsCanMoveWithoutChangingMembershipOrFlags() throws {
        let f = try fixture(); defer { f.close() }
        let before = f.store.index
        XCTAssertEqual(f.store.groups[2].isProtected, true)
        try invoke(try orderItem("earlier", in: f.controller))
        try invoke(try orderItem("earlier", in: f.controller))
        XCTAssertEqual(f.store.groups.first?.id, f.groupIDs[2])
        let picker = try popup("pin-group-picker", in: f.controller)
        picker.select(try XCTUnwrap(picker.itemArray.first { $0.representedObject as? UUID == PinGroup.defaultID }))
        try invoke(picker)
        XCTAssertEqual(f.store.index.activeGroupID, PinGroup.defaultID)
        try invoke(try orderItem("later", in: f.controller))
        XCTAssertEqual(f.store.groups[2].id, PinGroup.defaultID)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: f.store.groups.map { ($0.id, $0) }),
                       Dictionary(uniqueKeysWithValues: before.groups.map { ($0.id, $0) }))
        XCTAssertEqual(f.store.entries, before.entries)
        let delete = descendants(f.controller.window?.contentView).compactMap { $0 as? NSButton }.first { $0.title == "删除组…" }
        XCTAssertEqual(delete?.isEnabled, false, "Reordering does not relax default-group deletion protection")
    }

    func testFailedAtomicCommitReportsErrorAndPreservesOrderSelectionAndFilesThenRetries() async throws {
        let f = try fixture(); defer { f.close() }
        let selected = Set(f.pinIDs.prefix(2)); try select(selected, in: f)
        let before = f.store.index, manifest = try Data(contentsOf: f.directory.appendingPathComponent("index.json"))
        let assets = try assetBytes(f.directory)
        var errors: [Error] = [], changes = 0, publications = 0
        var handlerModalStates: [Bool] = []
        f.controller.onChangeError = {
            errors.append($0)
            handlerModalStates.append(NSApp.modalWindow != nil)
        }
        f.controller.onSessionChange = { changes += 1 }
        let subscription = f.store.$index.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        f.store.failureInjector = { if $0 == .beforeIndexCommit { throw Failure.write } }
        let earlier = try orderItem("earlier", in: f.controller)
        XCTAssertNil(NSApp.modalWindow, "Injected failure starts without a modal dialog")
        try invoke(earlier)
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(errors.first as? Failure, .write)
        XCTAssertEqual(handlerModalStates, [false], "The injected handler receives the error without inherited modal presentation")
        XCTAssertNil(NSApp.modalWindow, "Injected error handling must not leave a modal dialog")
        XCTAssertEqual(changes, 0); XCTAssertEqual(publications, 0)
        XCTAssertEqual(f.store.index, before); XCTAssertEqual(f.controller.selectedPinIDs, selected)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("index.json")), manifest)
        XCTAssertEqual(try assetBytes(f.directory), assets)
        f.controller.reload(); try await drainPublishedReloads()
        XCTAssertEqual(f.controller.selectedPinIDs, selected); assertPickerIDs(f)
        f.store.failureInjector = nil
        try invoke(earlier)
        XCTAssertEqual(changes, 1); XCTAssertEqual(publications, 1)
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(f.controller.selectedPinIDs, selected)
        XCTAssertEqual(f.store.groups[1].id, f.groupIDs[2])
        XCTAssertEqual(try PinSessionStore(directory: f.directory).index, f.store.index)
    }

    func testPickerAndPinDestinationResolveIDsWhenPublishedOrderReloadIsPending() throws {
        let f = try fixture(); defer { f.close() }
        let picker = try popup("pin-group-picker", in: f.controller)
        let destination = try XCTUnwrap(picker.itemArray.first { $0.representedObject as? UUID == f.groupIDs[1] })
        try f.store.moveGroup(id: f.groupIDs[2], offset: -1)
        picker.select(destination); try invoke(picker)
        XCTAssertEqual(f.store.index.activeGroupID, f.groupIDs[1], "A pending reload must not reinterpret the old row index")

        try f.store.setActiveGroup(id: f.groupIDs[2]); f.controller.reload()
        try select([f.pinIDs[0]], in: f)
        let move = try popup("pin-group-move-pin", in: f.controller)
        let target = try XCTUnwrap(move.itemArray.first { $0.representedObject as? UUID == f.groupIDs[1] })
        let before = f.store.entries
        try f.store.moveGroup(id: f.groupIDs[1], offset: -1)
        move.select(target); try invoke(move)
        XCTAssertEqual(f.store.entry(id: f.pinIDs[0])?.groupID, f.groupIDs[1])
        XCTAssertEqual(f.store.entries.filter { $0.id != f.pinIDs[0] }, before.filter { $0.id != f.pinIDs[0] })
        XCTAssertEqual(f.store.index.activeGroupID, f.groupIDs[2])
    }

    func testStaleOrderMenuCannotMoveAnotherActiveGroup() throws {
        let f = try fixture(); defer { f.close() }
        let oldItem = try orderItem("earlier", in: f.controller)
        try f.store.setActiveGroup(id: f.groupIDs[1])
        let before = f.store.index
        try invoke(oldItem)
        XCTAssertEqual(f.store.index, before)
        assertPickerIDs(f)
        XCTAssertEqual(oldItem.representedObject as? UUID, f.groupIDs[1])
    }

    func testMinimumWindowGeometryAndNativeHitTargetsInBothThemesAfterReorder() throws {
        try Self.withApplicationLoop { [self] in
            let trace = GroupOrderLayoutTrace()
            let f = try fixture(includeTransforms: true); defer { f.close() }
            trace.capture(f.controller, store: f.store, phase: "original.constructed")
            // Maximum permitted names must not expand or obscure the compact header.
            for (position, id) in f.groupIDs.enumerated() {
                let name = String(repeating: "长", count: 47) + ["甲", "乙", "丙", "丁"][position]
                try f.store.renameGroup(id: id, name: name, color: nil)
            }
            f.controller.reload(); f.controller.showWindow(nil)
            let window = try XCTUnwrap(f.controller.window)
            trace.capture(f.controller, store: f.store, phase: "original.shown")
            window.animationBehavior = .none
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                for size in [NSSize(width: 680, height: 600), NSSize(width: 780, height: 640), NSSize(width: 680, height: 600)] {
                    let prefix = "original.\(appearance.rawValue).\(Int(size.width))x\(Int(size.height))"
                    trace.capture(f.controller, store: f.store, phase: prefix + ".beforeResize")
                    var frame = window.frame; frame.size = size; window.setFrame(frame, display: true)
                    trace.capture(f.controller, store: f.store, phase: prefix + ".afterResize")
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    trace.capture(f.controller, store: f.store, phase: prefix + ".afterLayout")
                    XCTAssertEqual(window.frame.size, size)
                    try assertHeaderHitTargets(f.controller)
                    try assertActionRowHitTargets(f.controller)
                    try invoke(try orderItem("earlier", in: f.controller))
                    trace.capture(f.controller, store: f.store, phase: prefix + ".afterEarlier")
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    try assertHeaderHitTargets(f.controller)
                    try assertActionRowHitTargets(f.controller)
                    try invoke(try orderItem("later", in: f.controller))
                    trace.capture(f.controller, store: f.store, phase: prefix + ".afterLater")
                    assertPickerIDs(f)
                }
            }
            f.controller.close()
            let previousAppearance = NSApp.appearance
            defer { NSApp.appearance = previousAppearance }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                try traceInstalledLayout(appearance, trace: trace)
            }
            trace.emit("complete", ["diagnosticOnly": true, "installerAcceptance": false])
        }
    }

    /// Isolates installed manager data/selection/layout using the existing owned
    /// host. Menu mutations retain this test's native target/action route; this
    /// is not evidence for installed menu tracking or four-second release gates.
    private func traceInstalledLayout(_ appearance: NSAppearance.Name, trace: GroupOrderLayoutTrace) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GroupLayout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let active = try store.createGroup(name: "文字与参考", color: .purple)
        _ = try store.createGroup(name: "稍后查看", color: .green)
        try store.setActiveGroup(id: active.id)
        let initial = PinTextContent(text: PinManagementSmokeFixture.initialText)
        let text = try store.add(rich: PreparedRichPin(document: PinRichDocument(text: initial), title: "文字便笺"))
        let html = PinTextContent(runs: [PinTextRun(text: "Keep bold", bold: true), PinTextRun(text: " 与 HTML", italic: true)], importedHTML: true)
        let htmlEntry = try store.add(rich: PreparedRichPin(document: PinRichDocument(text: html), title: "HTML 参考"))
        let image = try store.add(image: ImageEditorRenderer.makeSampleImage(), title: "图片参考")
        // Same model-visible order as the installed draft-save/rename sequence.
        try store.updateText(id: text.id, content: PinTextContent(text: PinManagementSmokeFixture.savedText), expectedContent: initial)
        try store.renamePin(id: text.id, title: "文字已命名 🧪")
        try store.renamePin(id: image.id, title: "图片已命名 🖼️")
        XCTAssertEqual(image.current.width, 960); XCTAssertEqual(image.current.height, 600)
        let manager = PinGroupsController(store: store)
        defer { manager.close() }
        let window = try XCTUnwrap(manager.window)
        let prefix = "installedShape.\(appearance.rawValue)"
        let resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak window, weak trace] _ in
            MainActor.assumeIsolated {
                if let window, let trace { trace.window(window, event: "didResize") }
            }
        }
        defer { NotificationCenter.default.removeObserver(resizeObserver) }
        func capture(_ stage: String) { trace.capture(manager, store: store, phase: prefix + "." + stage, details: true) }
        func layout(_ stage: String) {
            capture(stage + ".beforeLayout")
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            capture(stage + ".afterLayout")
        }
        func drain(_ stage: String) {
            capture(stage + ".beforeRunLoop")
            // Finite observation only: at most 20 default-mode slices / 50 ms.
            // No menu tracking, waiting for a desired size, or forced resize.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.05
            var slices = 0
            while slices < 20 && ProcessInfo.processInfo.systemUptime < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
                slices += 1
            }
            capture(stage + ".afterRunLoop")
            trace.emit("runLoopSlices", ["count": slices, "maximum": 20, "budgetSeconds": 0.05])
        }
        trace.emit("fixture", ["appearance": appearance.rawValue, "transformsSupplied": false,
            "inputWidth": 960, "inputHeight": 600, "expectedSelectedID": image.id.uuidString,
            "menuRoute": "existing-test-native-target-action", "rowRoute": "owned-nextEvent-sendEvent",
            "maximumRunLoopSlicesPerBoundary": 20, "originalMenuDeadlineSecondsUnchanged": 2,
            "originalReleaseDeadlineSecondsUnchanged": 4, "outerTestDeadlineSecondsUnchanged": 420])
        capture("constructed")
        capture("beforeShow")
        manager.showWindow(nil)
        capture("afterShow")
        capture("beforeResize")
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 680, height: 600)), display: true)
        capture("afterResize")
        layout("initial")
        window.center()
        capture("afterCenter")
        XCTAssertEqual(window.frame.size, NSSize(width: 680, height: 600))
        let table = try XCTUnwrap(descendants(window.contentView).first { $0.identifier?.rawValue == "pin-group-entries" } as? NSTableView)
        capture("beforeRealRowSelection")
        let selection = try PortableSettingsUIPreviewFixture.clickRow(1, in: table)
        capture("afterRealRowSelection")
        trace.emit("rowSelection", ["requestedRow": 1, "selectedRow": table.selectedRow,
            "dispatchRoute": selection["dispatchRoute"] as? String ?? "missing",
            "targetPointVisible": selection["targetPointVisible"] as? Bool ?? false])
        XCTAssertEqual(manager.selectedPinIDs, [image.id])
        layout("selected"); drain("selected")
        let beforeEntries = store.entries
        var callbacks = 0
        manager.onSessionChange = { callbacks += 1 }
        for (index, step) in [("earlier", false), ("earlier", true), ("later", false), ("later", false), ("later", true)].enumerated() {
            let stage = "order\(index).\(step.0)"
            let item = try orderItem(step.0, in: manager)
            XCTAssertEqual(item.isEnabled, !step.1)
            capture(stage + ".beforeAction")
            if !step.1 { try invoke(item) }
            else { trace.emit("disabledBoundary", ["item": step.0, "actionSent": false]) }
            capture(stage + ".afterAction")
            layout(stage); drain(stage)
            XCTAssertEqual(manager.selectedPinIDs, [image.id])
            XCTAssertEqual(table.selectedRow, 1)
            XCTAssertEqual(store.index.activeGroupID, active.id)
            XCTAssertEqual(store.entries, beforeEntries)
        }
        XCTAssertEqual(callbacks, 3)
        capture("beforeExplicitReload")
        manager.reload()
        capture("afterExplicitReload")
        layout("reload"); drain("reload")
        capture("final")
        // Diagnostic failure is preserved. Never resize again to make this pass.
        XCTAssertEqual(window.frame.size, NSSize(width: 680, height: 600))
        try assertActionRowHitTargets(manager)
        try exercisePreviewTransitions(manager, store: store, sampleID: image.id, textID: text.id, htmlID: htmlEntry.id,
            appearance: appearance, trace: trace)
    }

    private func exercisePreviewTransitions(_ manager: PinGroupsController, store: PinSessionStore,
        sampleID: UUID, textID: UUID, htmlID: UUID, appearance: NSAppearance.Name, trace: GroupOrderLayoutTrace) throws {
        let window = try XCTUnwrap(manager.window), root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "pin-group-entries" } as? NSTableView)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? NSImageView }.first { !$0.isDescendant(of: table) })
        let previewStack = try XCTUnwrap(descendants(root).compactMap { $0 as? NSStackView }.first { $0.views.contains { $0 === preview } })
        let details = try XCTUnwrap(previewStack.views.compactMap { $0 as? NSTextField }.first)
        var targets: [(name: String, id: UUID, color: [CGFloat]?)] = []
        for (name, width, height, color) in [
            ("portrait", 240, 960, [CGFloat(0.92), 0.08, 0.12]),
            ("landscape", 960, 240, [CGFloat(0.08), 0.82, 0.16]),
            ("small", 24, 12, [CGFloat(0.10), 0.20, 0.94])
        ] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let entry = try store.add(image: XCTUnwrap(context.makeImage()), title: "Preview " + name)
            targets.append((name, entry.id, color))
        }
        targets += [("sample", sampleID, nil), ("plain-text", textID, nil), ("imported-html", htmlID, nil)]
        manager.reload()
        let before = store.index, assets = try assetBytes(store.directory)
        let manifest = try Data(contentsOf: store.directory.appendingPathComponent("index.json"))
        // Traverse all source types, then repeat crossings between image and text
        // to expose stale raster/selection or accumulated minimum-height state.
        for (step, targetIndex) in [3, 0, 1, 2, 4, 5, 0, 4, 2, 1, 3, 5].enumerated() {
            let target = targets[targetIndex]
            let prefix = "previewTransition.\(appearance.rawValue).\(step).\(target.name)"
            func capture(_ stage: String) { trace.capture(manager, store: store, phase: prefix + "." + stage) }
            let sorted = store.entries.filter { $0.groupID == store.index.activeGroupID }.sorted {
                $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
            }
            let row = try XCTUnwrap(sorted.firstIndex { $0.id == target.id })
            capture("beforeRealRowSelection")
            let receipt = try PortableSettingsUIPreviewFixture.clickRow(row, in: table)
            capture("afterRealRowSelection")
            XCTAssertEqual(manager.selectedPinIDs, [target.id]); XCTAssertEqual(table.selectedRow, row)
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            capture("afterLayout")
            XCTAssertEqual(window.frame.size, NSSize(width: 680, height: 600))
            let deadline = ProcessInfo.processInfo.systemUptime + 0.05
            var slices = 0
            while slices < 20 && ProcessInfo.processInfo.systemUptime < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
                slices += 1
            }
            capture("afterRunLoop")
            XCTAssertEqual(window.frame.size, NSSize(width: 680, height: 600))
            XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 680, height: 572))
            XCTAssertEqual(manager.selectedPinIDs, [target.id]); XCTAssertEqual(table.selectedRow, row)
            let entry = try XCTUnwrap(store.entry(id: target.id)), image = try XCTUnwrap(preview.image)
            XCTAssertTrue(image === store.thumbnail(id: target.id), "Preview must use the selected pin's actual thumbnail")
            XCTAssertEqual(preview.imageScaling, .scaleProportionallyUpOrDown)
            XCTAssertEqual(preview.bounds.width, 270, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(preview.bounds.height, 160)
            XCTAssertFalse(preview.isHiddenOrHasHiddenAncestor); XCTAssertFalse(details.isHiddenOrHasHiddenAncestor)
            let previewFrame = preview.convert(preview.bounds, to: root), detailFrame = details.convert(details.bounds, to: root)
            XCTAssertTrue(root.bounds.contains(previewFrame)); XCTAssertTrue(root.bounds.contains(detailFrame))
            XCTAssertFalse(previewFrame.intersects(detailFrame), "Preview artwork cannot obscure its detail label")
            XCTAssertTrue(details.stringValue.contains(entry.title))
            let detailNeed = try XCTUnwrap(details.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: details.bounds.width, height: 4_096))
            XCTAssertGreaterThanOrEqual(details.bounds.height + 1, detailNeed.height, "Selected details remain fully visible")
            let pixels = try previewPixelEvidence(preview, expectedColor: target.color, richText: targetIndex >= 4)
            trace.emit("previewTransition", ["step": step, "kind": target.name, "selectedID": target.id.uuidString,
                "requestedRow": row, "selectedRow": table.selectedRow,
                "dispatchRoute": receipt["dispatchRoute"] as? String ?? "missing",
                "sourceSize": [entry.current.width, entry.current.height], "thumbnailSize": [image.size.width, image.size.height],
                "previewSize": [preview.bounds.width, preview.bounds.height],
                "detailSize": [details.bounds.width, details.bounds.height], "requiredDetailHeight": detailNeed.height,
                "runLoopSlices": slices, "pixels": pixels])
            XCTAssertEqual(store.index, before, "Selection and layout must not mutate saved content or metadata")
        }
        XCTAssertEqual(try assetBytes(store.directory), assets)
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("index.json")), manifest)
        try assertActionRowHitTargets(manager)
    }

    /// Measures pixels produced by the actual native preview view, not a separate
    /// image.draw implementation. Saturated fixtures distinguish artwork from
    /// both theme backgrounds and make stale-image transitions observable.
    private func previewPixelEvidence(_ preview: NSImageView, expectedColor: [CGFloat]?, richText: Bool) throws -> [String: Any] {
        let image = try XCTUnwrap(preview.image), bounds = preview.bounds
        XCTAssertGreaterThan(image.size.width, 0); XCTAssertGreaterThan(image.size.height, 0)
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let expected = NSRect(x: bounds.midX - image.size.width * scale / 2, y: bounds.midY - image.size.height * scale / 2,
            width: image.size.width * scale, height: image.size.height * scale)
        let width = Int(ceil(bounds.width)), height = Int(ceil(bounds.height))
        guard width > 0, height > 0, width <= 1_000_000 / height else {
            XCTFail("Native preview raster exceeds its one-million-pixel bound")
            return ["bounded": false]
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        bitmap.size = bounds.size
        preview.effectiveAppearance.performAsCurrentDrawingAppearance { preview.cacheDisplay(in: bounds, to: bitmap) }
        var minX = width, minY = height, maxX = -1, maxY = -1, matches = 0, dark = 0, light = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                if let expectedColor, abs(color.redComponent - expectedColor[0]) < 0.09,
                   abs(color.greenComponent - expectedColor[1]) < 0.09, abs(color.blueComponent - expectedColor[2]) < 0.09 {
                    matches += 1; minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
                // The centered aspect-fit rectangle is symmetric under bitmap
                // row orientation, so this interior excludes letterbox pixels.
                if expected.insetBy(dx: 4, dy: 4).contains(NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.4 { dark += 1 }
                    if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8 { light += 1 }
                }
            }
        }
        var evidence: [String: Any] = ["bitmapSize": [width, height],
            "expectedAspectFit": [expected.minX, expected.minY, expected.width, expected.height],
            "sourceAspectRatio": image.size.width / image.size.height, "matchingPixels": matches,
            "darkInteriorPixels": dark, "lightInteriorPixels": light]
        if expectedColor != nil {
            XCTAssertGreaterThan(matches, 100, "Actual native preview must draw the current fixture's pixels")
            let actual = NSRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(max(0, maxX - minX + 1)), height: CGFloat(max(0, maxY - minY + 1)))
            XCTAssertEqual(actual.width, expected.width, accuracy: 2, "Artwork must retain its native aspect-fit width")
            XCTAssertEqual(actual.height, expected.height, accuracy: 2, "Artwork must retain its native aspect-fit height")
            XCTAssertEqual(actual.midX, expected.midX, accuracy: 1)
            XCTAssertEqual(actual.midY, expected.midY, accuracy: 1)
            evidence["actualColoredPixelBounds"] = [actual.minX, actual.minY, actual.width, actual.height]
            evidence["actualAspectRatio"] = actual.width / max(1, actual.height)
        }
        if richText {
            XCTAssertGreaterThan(dark, 5, "Native rich preview must contain rendered text")
            XCTAssertGreaterThan(light, 100, "Native rich preview must contain its saved poster background")
        }
        return evidence
    }

    private enum Failure: Error, Equatable { case write }
    private func fixture(includeTransforms: Bool = false) throws -> PinGroupOrderFixture {
        try requireDisplay()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GroupOrder-" + UUID().uuidString)
        do {
            // Load names saved by older versions: equal names still ensure every
            // operation depends on identity, without creating a new duplicate.
            let first = PinGroup(name: "同名", color: .blue)
            let selected = PinGroup(name: "同名", color: .purple)
            let last = PinGroup(name: "尾组", color: .green)
            var legacy = PinSessionIndex(); legacy.groups += [first, selected, last]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            let store = try PinSessionStore(directory: directory)
            XCTAssertEqual(store.index, legacy)
            try store.setGroupProtected(id: selected.id, protected: true)
            try store.setGroupHidden(id: last.id, hidden: true)
            let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            let image = try XCTUnwrap(context.makeImage())
            var pins: [UUID] = []
            for name in ["One", "Two", "Three"] { pins.append(try store.add(image: image, title: name, groupID: selected.id).id) }
            _ = try store.add(image: image, title: "Default sentinel", groupID: PinGroup.defaultID)
            _ = try store.add(image: image, title: "Other sentinel", groupID: first.id)
            _ = try store.add(image: image, title: "Hidden sentinel", groupID: last.id)
            try store.setActiveGroup(id: selected.id)
            let session = includeTransforms ? PinSessionCoordinator(store: store, presentWindows: false,
                desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
                ocrPreferences: PinOCRPreferences(defaults: nil)) : nil
            try session?.reconcileVisiblePins()
            let controller = PinGroupsController(store: store, transforms: session?.groupTransforms)
            if let session {
                controller.onSessionChange = { [weak session] in
                    guard let session else { XCTFail("Group-order fixture lost its session"); return }
                    do { try session.reconcileVisiblePins() }
                    catch { XCTFail("Group-order fixture reconciliation failed: \(error)") }
                }
            }
            return PinGroupOrderFixture(directory: directory, store: store, controller: controller, session: session,
                           groupIDs: [PinGroup.defaultID, first.id, selected.id, last.id], pinIDs: pins)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    private func select(_ ids: Set<UUID>, in f: PinGroupOrderFixture) throws {
        let table = try XCTUnwrap(descendants(f.controller.window?.contentView).first { $0.identifier?.rawValue == "pin-group-entries" } as? NSTableView)
        let entries = f.store.entries.filter { $0.groupID == f.store.index.activeGroupID }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        table.selectRowIndexes(IndexSet(entries.indices.filter { ids.contains(entries[$0].id) }), byExtendingSelection: false)
        XCTAssertEqual(f.controller.selectedPinIDs, ids)
    }
    private func assertPickerIDs(_ f: PinGroupOrderFixture, file: StaticString = #filePath, line: UInt = #line) {
        for identifier in ["pin-group-picker", "pin-group-move-pin"] {
            guard let picker = try? popup(identifier, in: f.controller) else { XCTFail("Missing \(identifier)", file: file, line: line); continue }
            XCTAssertEqual(picker.itemArray.compactMap { $0.representedObject as? UUID }, f.store.groups.map(\.id), file: file, line: line)
            XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, f.store.index.activeGroupID, file: file, line: line)
            XCTAssertEqual(picker.toolTip, picker.selectedItem?.title, "Full selected label remains available", file: file, line: line)
        }
    }
    private func orderItem(_ direction: String, in controller: PinGroupsController) throws -> NSMenuItem {
        try XCTUnwrap(try popup("pin-group-order", in: controller).itemArray.first { $0.identifier?.rawValue == "pin-group-order-" + direction })
    }
    private func popup(_ id: String, in controller: PinGroupsController) throws -> NSPopUpButton {
        try XCTUnwrap(descendants(controller.window?.contentView).first { $0.identifier?.rawValue == id } as? NSPopUpButton)
    }
    private func invoke(_ item: NSMenuItem, evenIfDisabled: Bool = false) throws {
        if !evenIfDisabled { XCTAssertTrue(item.isEnabled) }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }
    private func invoke(_ control: NSControl) throws {
        XCTAssertTrue(control.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control))
    }
    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private func assetBytes(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.lastPathComponent != "index.json" {
            result[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return result
    }
    private func drainPublishedReloads() async throws { try await Task.sleep(nanoseconds: 50_000_000) }
    private func requireDisplay() throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Native group-order tests require WindowServer") }
    }
    private func assertHeaderHitTargets(_ controller: PinGroupsController) throws {
        let root = try XCTUnwrap(controller.window?.contentView)
        let heading = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "pin-group-heading" } as? NSStackView)
        let controls = heading.views.compactMap { $0 as? NSButton }
        XCTAssertEqual(controls.filter { $0 is NSPopUpButton }.count, 2)
        for (index, control) in controls.enumerated() {
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
            XCTAssertGreaterThanOrEqual(control.bounds.height, 20)
            XCTAssertGreaterThanOrEqual(control.bounds.width, 24)
            if let picker = control as? NSPopUpButton, picker.identifier?.rawValue == "pin-group-picker" {
                XCTAssertEqual(picker.toolTip, picker.selectedItem?.title)
                XCTAssertTrue(picker.toolTip?.contains(String(repeating: "长", count: 48)) == true)
            }
            let fullFrame = control.convert(control.bounds, to: root)
            if control.identifier?.rawValue == "pin-group-order" {
                let required = try XCTUnwrap(control.cell?.cellSize)
                XCTAssertGreaterThanOrEqual(fullFrame.width + 1, required.width)
                XCTAssertGreaterThanOrEqual(fullFrame.height + 1, required.height)
                XCTAssertEqual((control as? NSPopUpButton)?.item(at: 0)?.title, "排序")
            }
            XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(fullFrame), "Control must stay within content: \(control)")
            XCTAssertTrue(heading.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: heading)))
            for x in [control.bounds.minX + 2, control.bounds.midX, control.bounds.maxX - 2] {
                let point = NSPoint(x: x, y: control.bounds.midY)
                for receiver in [root, heading] {
                    let hit = receiver.hitTest(control.convert(point, to: receiver.superview))
                    XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true, "Native hit target differs: \(control)")
                }
            }
            for other in controls.dropFirst(index + 1) {
                let overlap = fullFrame.intersection(other.convert(other.bounds, to: root))
                XCTAssertTrue(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5, "Full control frames overlap")
            }
        }
    }

    private func assertActionRowHitTargets(_ controller: PinGroupsController) throws {
        let root = try XCTUnwrap(controller.window?.contentView)
        for ids in [["pin-group-show", "pin-group-hide-all"],
                    ["pin-group-open-pin", "pin-group-rename-pin", "pin-group-remove-pin"]] {
            let controls = try ids.map { id in try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == id } as? NSButton) }
            var prior: CGRect?
            for control in controls {
                let frame = control.convert(control.bounds, to: root)
                XCTAssertTrue(root.bounds.contains(frame))
                if let prior { XCTAssertGreaterThanOrEqual(frame.minX - prior.maxX, 2 - 0.01, "Native full-frame gap") }
                prior = frame
                let visible = root.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
                for x in [visible.minX + 1, visible.midX, visible.maxX - 1] {
                    let hit = root.hitTest(root.convert(NSPoint(x: x, y: visible.midY), to: root.superview))
                    XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true, "Native visible button edge is owned")
                }
                // Rounded-control padding need not activate the button. It must
                // never resolve to a neighboring action after the spacing fix.
                for x in [frame.minX + 0.5, frame.maxX - 0.5] {
                    let hit = root.hitTest(root.convert(NSPoint(x: x, y: frame.midY), to: root.superview))
                    for sibling in controls where sibling !== control {
                        XCTAssertFalse(hit === sibling || hit?.isDescendant(of: sibling) == true, "Padding hit a neighboring action")
                    }
                }
            }
        }
    }

    /// Same owned-loop admission used by LocalAnnotationShortcutNativeTests.
    /// Reuse a running application and never stop or reconfigure another host.
    static func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Native group-order tests require WindowServer") }
        if NSApp.isRunning { try body(); return }
        _ = try XCTUnwrap(NSApp.modalWindow == nil && NSApp.delegate == nil ? true : nil,
            "Standalone group-order host unexpectedly has a modal window or delegate")
        _ = try XCTUnwrap(UserDefaults.standard.object(forKey: "NSOpen") == nil ? true : nil,
            "Standalone group-order host unexpectedly has a file-open request")
        let originalPolicy = NSApp.activationPolicy(), state = GroupOrderApplicationLoop()
        defer {
            state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
            if NSApp.activationPolicy() != originalPolicy { _ = NSApp.setActivationPolicy(originalPolicy) }
            XCTAssertEqual(NSApp.activationPolicy(), originalPolicy)
        }
        if originalPolicy == .prohibited {
            _ = try XCTUnwrap(NSApp.setActivationPolicy(.accessory) ? true : nil, "Owned AppKit host must be activatable")
        }
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        func finish(_ result: Result<Void, Error>) {
            guard state.acceptsCallbacks, state.result == nil else { return }
            state.result = result; state.timer?.invalidate(); state.timer = nil
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
                            state.timer?.invalidate(); state.timer = nil
                            finish(Result { try body() })
                        }
                        else if ProcessInfo.processInfo.systemUptime >= deadline {
                            finish(.failure(NSError(domain: "PicShot.GroupOrderUITestHost", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Owned application did not become active within one second"])))
                        }
                    }
                }
                state.timer = timer; RunLoop.main.add(timer, forMode: .default)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain()); NSApp.run()
        state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
        XCTAssertFalse(NSApp.isRunning)
        try XCTUnwrap(state.result, "Owned AppKit loop exited before the test completed").get()
    }
}

@MainActor private struct PinGroupOrderFixture {
    let directory: URL
    let store: PinSessionStore
    let controller: PinGroupsController
    let session: PinSessionCoordinator?
    let groupIDs: [UUID]
    let pinIDs: [UUID]
    func close() {
        controller.close(); try? session?.prepareForTermination()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private final class GroupOrderApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}

/// Descriptor writes are unbuffered. The observer retains only scalar snapshots,
/// never an AppKit object or constraint. Fitting queries are explicitly bracketed
/// because observation can itself cause AppKit to consult its layout engine.
@MainActor private final class GroupOrderLayoutTrace {
    private var rows = 0, bytes = 0, exceeded = false
    private var lastConstraints: [String: String] = [:]
    private let started = ProcessInfo.processInfo.systemUptime
    private var phase = "starting"

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        guard !exceeded else { return }
        var record = fields
        record["diagnostic"] = "pin-group-layout"
        record["event"] = event; record["phase"] = phase; record["sequence"] = rows
        record["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              data.count <= 8_192, rows < 16_384, bytes + data.count + 1 <= 8_388_608 else {
            exceeded = true
            FileHandle.standardError.write(Data("PIN_LAYOUT_TRACE_BOUND_EXCEEDED\n".utf8))
            XCTFail("Layout diagnostic exceeded its finite scalar evidence budget")
            return
        }
        data.append(10); FileHandle.standardError.write(data)
        rows += 1; bytes += data.count
    }

    func window(_ window: NSWindow, event: String) {
        emit(event, ["frame": rect(window.frame), "contentBounds": rect(window.contentView?.bounds ?? .zero),
            "contentLayoutRect": rect(window.contentLayoutRect),
            "minimumSize": size(window.minSize), "contentMinimumSize": size(window.contentMinSize),
            "visible": window.isVisible, "key": window.isKeyWindow,
            "windowNumber": window.windowNumber, "applicationRunning": NSApp.isRunning,
            "applicationActive": NSApp.isActive])
    }

    func capture(_ controller: PinGroupsController, store: PinSessionStore, phase: String, details: Bool = false) {
        self.phase = phase
        guard let window = controller.window, let root = window.contentView else {
            emit("missingWindow"); return
        }
        self.window(window, event: "beforeObservation")
        var nodes: [(path: String, view: NSView)] = []
        func walk(_ view: NSView, _ path: String) {
            guard nodes.count < 256 else { return }
            nodes.append((path, view))
            for (index, child) in view.subviews.enumerated() { walk(child, path + ".\(index)") }
        }
        walk(root, "root")
        let byIdentity = Dictionary(uniqueKeysWithValues: nodes.map { (ObjectIdentifier($0.view), $0.path) })
        XCTAssertLessThan(nodes.count, 256, "Layout view census reached its evidence bound")
        func itemName(_ item: Any?) -> String {
            guard let item else { return "none" }
            if let view = item as? NSView, let path = byIdentity[ObjectIdentifier(view)] { return path }
            return String(describing: type(of: item))
        }
        let table = nodes.compactMap { $0.view as? NSTableView }.first
        let visibleRows = table.map { $0.rows(in: $0.visibleRect) } ?? NSRange(location: 0, length: 0)
        let selected = controller.selectedPinIDs.map(\.uuidString).sorted()
        emit("selection", ["selectedPinIDs": selected,
            "activeGroupID": store.index.activeGroupID.uuidString,
            "groupOrder": store.groups.map { $0.id.uuidString },
            "selectedRow": table?.selectedRow ?? -1, "rowCount": table?.numberOfRows ?? 0,
            "visibleRowLocation": visibleRows.location, "visibleRowCount": visibleRows.length,
            "tableVisibleRect": rect(table?.visibleRect ?? .zero), "viewCount": nodes.count,
            "rootFittingSize": size(root.fittingSize)])
        guard details else { self.window(window, event: "afterObservation"); return }
        var constraintCount = 0, requiredCount = 0
        for node in nodes {
            let view = node.view
            let isTableChild = table.map { view !== $0 && view.isDescendant(of: $0) } ?? false
            // Visible table cells are covered by the row-range observation. Keep
            // detail focused on the container, stack rows and preview controls.
            guard !isTableChild else { continue }
            var fields: [String: Any] = ["path": node.path, "class": String(describing: type(of: view)),
                "identifier": view.identifier?.rawValue ?? "none", "frame": rect(view.frame),
                "bounds": rect(view.bounds), "hidden": view.isHidden, "hiddenAncestor": view.isHiddenOrHasHiddenAncestor,
                "fittingSize": size(view.fittingSize), "intrinsicSize": size(view.intrinsicContentSize),
                "needsLayout": view.needsLayout, "needsUpdateConstraints": view.needsUpdateConstraints,
                "ambiguousLayout": view.hasAmbiguousLayout,
                "verticalHugging": view.contentHuggingPriority(for: .vertical).rawValue,
                "verticalCompressionResistance": view.contentCompressionResistancePriority(for: .vertical).rawValue,
                "horizontalHugging": view.contentHuggingPriority(for: .horizontal).rawValue,
                "horizontalCompressionResistance": view.contentCompressionResistancePriority(for: .horizontal).rawValue]
            if let stack = view as? NSStackView {
                fields["stackOrientation"] = stack.orientation.rawValue
                fields["stackSpacing"] = stack.spacing
                fields["stackViewCount"] = stack.views.count
                fields["stackVisibleViewCount"] = stack.views.filter { !$0.isHiddenOrHasHiddenAncestor }.count
                fields["stackDetachedCount"] = stack.detachedViews.count
            }
            if let preview = view as? NSImageView {
                fields["imageSize"] = size(preview.image?.size ?? .zero)
                fields["imageScaling"] = preview.imageScaling.rawValue
            }
            if let label = view as? NSTextField {
                fields["textUTF8Count"] = label.stringValue.utf8.count
                fields["explicitLineCount"] = label.stringValue.split(separator: "\n", omittingEmptySubsequences: false).count
                fields["maximumLines"] = label.maximumNumberOfLines
                fields["cellSize"] = size(label.cell?.cellSize ?? .zero)
                fields["cellSizeForCurrentBounds"] = size(label.cell?.cellSize(forBounds: label.bounds) ?? .zero)
            }
            emit("view", fields)
            // Emit each constraint when first observed or changed. Scalar counts
            // on every snapshot make missing/truncated coverage explicit.
            let constraints = view.constraints.filter(\.isActive)
            XCTAssertLessThanOrEqual(constraints.count, 256, "Per-view constraint evidence bound")
            for (index, constraint) in constraints.prefix(256).enumerated() {
                constraintCount += 1
                if constraint.priority == .required { requiredCount += 1 }
                let record: [String: Any] = ["owner": node.path, "index": index,
                    "firstItem": itemName(constraint.firstItem), "firstAttribute": constraint.firstAttribute.rawValue,
                    "relation": constraint.relation.rawValue, "secondItem": itemName(constraint.secondItem),
                    "secondAttribute": constraint.secondAttribute.rawValue, "multiplier": constraint.multiplier,
                    "constant": constraint.constant, "priority": constraint.priority.rawValue,
                    "identifier": constraint.identifier ?? "none"]
                let key = phase.components(separatedBy: ".").prefix(2).joined(separator: ".") + ":" + node.path + ":\(index)"
                let encoded = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "invalid"
                if lastConstraints[key] != encoded {
                    lastConstraints[key] = encoded; emit("constraint", record)
                }
            }
            if view === root || view is NSStackView || view is NSImageView {
                let vertical = view.constraintsAffectingLayout(for: .vertical)
                XCTAssertLessThanOrEqual(vertical.count, 128, "Vertical constraint evidence bound")
                emit("verticalConstraints", ["path": node.path, "count": vertical.count,
                    "requiredCount": vertical.filter { $0.priority == .required }.count,
                    "constantSum": vertical.reduce(CGFloat(0)) { $0 + $1.constant },
                    "positiveConstants": vertical.prefix(128).filter { $0.constant > 0 }.map(\.constant),
                    "priorities": vertical.prefix(128).map { $0.priority.rawValue }])
            }
        }
        emit("constraintCounts", ["active": constraintCount, "required": requiredCount,
            "scalarConstraintCacheCount": lastConstraints.count])
        self.window(window, event: "afterObservation")
    }

    private func rect(_ value: NSRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private func size(_ value: NSSize) -> [CGFloat] { [value.width, value.height] }
}
