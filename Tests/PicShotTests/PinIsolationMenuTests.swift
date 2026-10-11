import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor final class PinIsolationMenuTests: XCTestCase {
    func testNativeContextMenusEscapeCompactPixelsAndCoordinatorVisibility() async throws {
        let output = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-IsolationMenuEvidence-" + UUID().uuidString)
        // Failed evidence remains available for the native runner's diagnostics.
        try await withApplicationLoop {
            let report = try await PinIsolationMenuNativeFixture.verify(evidenceDirectory: output)
            XCTAssertEqual(report["status"] as? String, "passed")
            XCTAssertEqual((report["modes"] as? [[String: Any]])?.count, 2)
        }
        try FileManager.default.removeItem(at: output)
    }

    func testMissingCallbacksAndStaleVisibleMembershipDisableIsolation() throws {
        try requireDisplay()
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-IsolationMenuState-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let pin = try store.add(image: ImageEditorRenderer.makeSampleImage())
        let manager = PinGroupsController(store: store); defer { manager.close() }
        let table = try XCTUnwrap(descendants(manager.window?.contentView).first { $0.identifier?.rawValue == "pin-group-entries" } as? NSTableView)
        let menu = try XCTUnwrap(table.menu)
        let isolate = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "pin-group-isolate-selected" })
        let restore = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "pin-group-restore-isolation" })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertFalse(isolate.isEnabled); XCTAssertFalse(restore.isEnabled)
        manager.onIsolatePins = { _ in XCTFail("Validation must not dispatch isolation") }
        manager.onRestoreIsolatedPins = { XCTFail("Validation must not dispatch restore") }
        manager.visiblePinIDsForIsolation = { [pin.id] }
        manager.visibilityIsolationAvailable = { false }
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertTrue(isolate.isEnabled); XCTAssertFalse(restore.isEnabled)
        manager.visiblePinIDsForIsolation = { [] }
        menu.delegate?.menuNeedsUpdate?(menu); XCTAssertFalse(isolate.isEnabled)
        manager.visiblePinIDsForIsolation = { [pin.id] }
        try store.archive(id: pin.id)
        menu.delegate?.menuNeedsUpdate?(menu); XCTAssertFalse(isolate.isEnabled, "Stale visible callbacks cannot revive an archive")
        manager.visibilityIsolationAvailable = { true }
        menu.delegate?.menuNeedsUpdate?(menu); XCTAssertTrue(restore.isEnabled)
        XCTAssertEqual(manager.selectedPinIDs, [pin.id])
    }

    func testExplicitShowKeepsDefaultStoreFallbackWhenNoCoordinatorCallbackExists() async throws {
        try await withApplicationLoop {
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-IsolationMenuShow-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try PinSessionStore(directory: directory)
            try store.setAllHidden(true)
            let manager = PinGroupsController(store: store); defer { manager.close() }
            manager.onChangeError = { XCTFail("Default Show failed: \($0)") }
            manager.showWindow(nil)
            let button = try XCTUnwrap(self.descendants(manager.window?.contentView).first { $0.identifier?.rawValue == "pin-group-show" } as? NSButton)
            try PortableSettingsUIPreviewFixture.click(button)
            XCTAssertFalse(store.index.allHidden)
            XCTAssertEqual(store.groups.first?.isHidden, false)
        }
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private func requireDisplay() throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Native pin isolation menus require WindowServer") }
    }

    /// Reuse a running app; only start/stop the otherwise unowned XCTest app.
    /// This is the same bounded host admission as the existing native pin tests.
    private func withApplicationLoop(_ body: @escaping @MainActor () async throws -> Void) async throws {
        try requireDisplay()
        if NSApp.isRunning { try await body(); return }
        XCTAssertNil(NSApp.modalWindow); XCTAssertNil(NSApp.delegate)
        guard NSApp.modalWindow == nil && NSApp.delegate == nil else { throw Failure.foreignHost }
        let previousPolicy = NSApp.activationPolicy(), state = LoopState()
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        defer {
            state.timer?.invalidate(); state.timer = nil; state.task?.cancel(); state.task = nil
            if NSApp.activationPolicy() != previousPolicy { _ = NSApp.setActivationPolicy(previousPolicy) }
        }
        if previousPolicy == .prohibited { XCTAssertTrue(NSApp.setActivationPolicy(.accessory)) }
        func finish(_ result: Result<Void, Error>) {
            guard state.result == nil else { return }
            state.result = result; state.timer?.invalidate(); NSApp.stop(nil); NSApp.postEvent(wake, atStart: true)
        }
        // Suspend XCTest's MainActor job before entering the native loop. This
        // leaves the main queue free for the fixture's async continuations.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                MainActor.assumeIsolated {
                    let deadline = ProcessInfo.processInfo.systemUptime + 1
                    state.timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            if !state.activationRequested { state.activationRequested = true; NSApp.activate(ignoringOtherApps: true) }
                            if NSApp.isRunning && NSApp.isActive {
                                state.timer?.invalidate(); state.timer = nil
                                state.task = Task { @MainActor in
                                    do { try await body(); finish(.success(())) }
                                    catch { finish(.failure(error)) }
                                }
                            } else if ProcessInfo.processInfo.systemUptime >= deadline { finish(.failure(Failure.activation)) }
                        }
                    }
                    if let timer = state.timer { RunLoop.main.add(timer, forMode: .default) }
                    NSApp.run()
                    continuation.resume(with: state.result ?? .failure(Failure.earlyExit))
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
    private enum Failure: Error { case foreignHost, activation, earlyExit }
    @MainActor private final class LoopState {
        var timer: Timer?, task: Task<Void, Never>?, result: Result<Void, Error>?
        var activationRequested = false
    }
}
