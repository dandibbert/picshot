import XCTest
import Carbon
@testable import PicShot

@MainActor final class PortableSettingsHotKeyTests: XCTestCase {
    private final class Backend: HotKeyBackend {
        var onEvent: ((UInt32, HotKeyEventPhase) -> Void)?
        var live: [UInt32: HotKeyBinding] = [:]
        var calls: [(UInt32, HotKeyBinding)] = []
        var refused: HotKeyBinding?
        var unregisters: [UInt32] = []
        var emitsSynchronously = false
        var invalidations = 0
        func register(_ binding: HotKeyBinding, id: UInt32) -> Bool {
            calls.append((id, binding))
            if binding == refused { return false }
            live[id] = binding
            if emitsSynchronously { onEvent?(id, .pressed) }
            return true
        }
        func unregister(_ id: UInt32) { unregisters.append(id); live.removeValue(forKey: id); onEvent?(id, .released) }
        func isKeyDown(_ keyCode: UInt32) -> Bool { false }
        func invalidate() { invalidations += 1; live.removeAll() }
    }

    func testImportedAvailabilityProbesAllSixAndRetiresWithoutActionAdmission() throws {
        let backend = Backend(); backend.emitsSynchronously = true
        var queued: [@MainActor () -> Void] = []
        let service = HotKeyService(backend: backend, dispatch: { queued.append($0) })
        defer { service.invalidate() }
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        var proposed = HotKeyConfiguration.defaults
        proposed[.recordingPauseResume] = HotKeyBinding(keyCode: 1, modifiers: UInt32(cmdKey))
        proposed[.recordingStopSave] = HotKeyBinding(keyCode: 2, modifiers: UInt32(cmdKey))
        try service.validateImportedAvailability(proposed)
        XCTAssertEqual(backend.calls.count, 6); XCTAssertEqual(backend.unregisters.count, 6)
        XCTAssertTrue(backend.live.isEmpty); XCTAssertTrue(queued.isEmpty); XCTAssertTrue(actions.isEmpty)
        for (id, _) in backend.calls { backend.onEvent?(id, .pressed) }
        queued.forEach { $0() }
        XCTAssertTrue(actions.isEmpty); XCTAssertFalse(service.isRecordingActive)
    }

    func testImportedAvailabilityConflictRetiresOnlyOwnedProbesAndLeavesSuspension() {
        let backend = Backend(); let service = HotKeyService(backend: backend)
        defer { service.invalidate() }
        backend.refused = HotKeyConfiguration.defaults[.history]
        XCTAssertThrowsError(try service.validateImportedAvailability(.defaults))
        XCTAssertTrue(backend.live.isEmpty)
        XCTAssertEqual(backend.unregisters.count, backend.calls.count - 1)
        let checked = backend.calls.count
        service.setRecordingActive(true)
        XCTAssertEqual(backend.calls.count, checked, "A state transition must retain the Settings suspension")
        XCTAssertTrue(backend.live.isEmpty)
    }

    func testAvailabilityRejectsUnsuspendedOrInvalidatedServiceWithoutChangingLiveBindings() {
        let backend = Backend(); let service = HotKeyService(backend: backend)
        service.register(.defaults)
        let before = backend.live; let calls = backend.calls.count
        XCTAssertThrowsError(try service.validateImportedAvailability(.defaults))
        XCTAssertEqual(backend.live, before); XCTAssertEqual(backend.calls.count, calls)
        service.invalidate()
        XCTAssertThrowsError(try service.validateImportedAvailability(.defaults))
        XCTAssertEqual(backend.calls.count, calls)
    }

    func testDuplicateImportedBindingsFailBeforeAnyProbe() {
        let backend = Backend(); let service = HotKeyService(backend: backend)
        defer { service.invalidate() }
        var proposed = HotKeyConfiguration.defaults
        proposed[.history] = proposed[.capture]
        XCTAssertThrowsError(try service.validateImportedAvailability(proposed))
        XCTAssertTrue(backend.calls.isEmpty); XCTAssertTrue(backend.live.isEmpty)
    }

    func testUnassignedImportNeedsNoRegistrationAndOldProbeIDsCannotBecomeCommands() throws {
        let backend = Backend(); let service = HotKeyService(backend: backend, dispatch: { $0() })
        defer { service.invalidate() }
        try service.validateImportedAvailability(HotKeyConfiguration(shortcuts: []))
        XCTAssertTrue(backend.calls.isEmpty)
        try service.validateImportedAvailability(.defaults)
        let old = backend.calls.map(\.0)
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        service.register(.defaults)
        for id in old { backend.onEvent?(id, .pressed) }
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(Set(old).isDisjoint(with: backend.live.keys))
    }
}
