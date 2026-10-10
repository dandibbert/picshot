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
            XCTAssertNoThrow(try session?.reconcileVisiblePins())
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
        f.controller.presentError = { errors.append($0) }
        f.controller.onSessionChange = { changes += 1 }
        let subscription = f.store.$index.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        f.store.failureInjector = { if $0 == .beforeIndexCommit { throw Failure.write } }
        let earlier = try orderItem("earlier", in: f.controller)
        try invoke(earlier)
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(errors.first as? Failure, .write)
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
        try withApplicationLoop { [self] in
            let f = try fixture(includeTransforms: true); defer { f.close() }
            // Maximum permitted names must not expand or obscure the compact header.
            for id in f.groupIDs { try f.store.renameGroup(id: id, name: String(repeating: "长", count: 48), color: nil) }
            f.controller.reload(); f.controller.showWindow(nil)
            let window = try XCTUnwrap(f.controller.window)
            window.animationBehavior = .none
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                for size in [NSSize(width: 680, height: 600), NSSize(width: 780, height: 640), NSSize(width: 680, height: 600)] {
                    var frame = window.frame; frame.size = size; window.setFrame(frame, display: true)
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    XCTAssertEqual(window.frame.size, size)
                    try assertHeaderHitTargets(f.controller)
                    try invoke(try orderItem("earlier", in: f.controller))
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    try assertHeaderHitTargets(f.controller)
                    try invoke(try orderItem("later", in: f.controller))
                    assertPickerIDs(f)
                }
            }
        }
    }

    private enum Failure: Error, Equatable { case write }
    private func fixture(includeTransforms: Bool = false) throws -> PinGroupOrderFixture {
        try requireDisplay()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GroupOrder-" + UUID().uuidString)
        let store = try PinSessionStore(directory: directory)
        do {
            // Equal names ensure every operation depends on identity, not visible text.
            let first = try store.createGroup(name: "同名", color: .blue)
            let selected = try store.createGroup(name: "同名", color: .purple)
            let last = try store.createGroup(name: "尾组", color: .green)
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
            controller.onSessionChange = { [weak session] in XCTAssertNoThrow(try session?.reconcileVisiblePins()) }
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
            let fullFrame = control.convert(control.bounds, to: root)
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

    /// Same owned-loop admission used by LocalAnnotationShortcutNativeTests.
    /// Reuse a running application and never stop or reconfigure another host.
    private func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        try requireDisplay()
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
