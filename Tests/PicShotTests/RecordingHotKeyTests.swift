import XCTest
import AppKit
import Carbon
import Combine
@testable import PicShot

final class RecordingHotKeyTests: XCTestCase {
    private let pause = HotKeyBinding(keyCode: 35, modifiers: UInt32(cmdKey | controlKey))
    private let stop = HotKeyBinding(keyCode: 1, modifiers: UInt32(cmdKey | controlKey))

    private func configured() -> HotKeyConfiguration {
        var configuration = HotKeyConfiguration.defaults
        configuration[.recordingPauseResume] = pause
        configuration[.recordingStopSave] = stop
        return configuration
    }
    private func preferences() -> (UserDefaults, String) {
        let name = "PicShot-RecordingHotKeyTests-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testAppendedActionIDsAndUnassignedTransportDefaultsPreserveOriginalDefaults() {
        XCTAssertEqual(HotKeyAction.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(HotKeyAction.settingsOrder, [.capture, .clipboardPin, .restoreLastPin, .history, .recordingPauseResume, .recordingStopSave])
        XCTAssertEqual(HotKeyBinding.defaults.count, 4)
        XCTAssertEqual(HotKeyConfiguration.defaults.shortcuts.map(\.action), [.capture, .clipboardPin, .history, .restoreLastPin])
        for action in [HotKeyAction.recordingPauseResume, .recordingStopSave] {
            XCTAssertNil(action.defaultBinding)
            XCTAssertNil(HotKeyConfiguration.defaults[action])
            XCTAssertTrue(action.requiresActiveRecording)
        }
    }

    func testLegacyPartialAndCurrentPreferencesNeverAssignTransportOrFillExplicitClears() throws {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(HotKeyConfiguration.read(from: defaults), .defaults)
        let legacy = [try XCTUnwrap(HotKeyAction.capture.defaultBinding)]
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: HotKeyConfiguration.legacyPreferenceKey)
        let migrated = HotKeyConfiguration.read(from: defaults)
        XCTAssertEqual(migrated[.capture], legacy[0])
        XCTAssertNil(migrated[.clipboardPin]); XCTAssertNil(migrated[.history])
        XCTAssertEqual(migrated[.restoreLastPin], HotKeyAction.restoreLastPin.defaultBinding)
        XCTAssertTrue(migrated.transportBindings.isEmpty)
        XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.legacyPreferenceKey), legacyData)
        XCTAssertNil(defaults.data(forKey: HotKeyConfiguration.preferenceKey))

        // Every subset of the four old action records is valid current-format
        // data: missing records are intentional clears, not migration gaps.
        for mask in 0..<16 {
            let shortcuts = HotKeyConfiguration.defaults.shortcuts.filter { mask & (1 << $0.action.rawValue) != 0 }
            let partial = HotKeyConfiguration(shortcuts: shortcuts)
            try partial.save(to: defaults)
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), partial)
            XCTAssertTrue(HotKeyConfiguration.read(from: defaults).transportBindings.isEmpty)
        }
    }

    func testTransportRemapClearAndExactSuppressionBindingsRoundTrip() throws {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        var configuration = configured()
        XCTAssertEqual(configuration.transportBindings, Set([pause, stop]))
        XCTAssertFalse(configuration.transportBindings.contains(try XCTUnwrap(configuration[.capture])))
        try configuration.save(to: defaults)
        XCTAssertEqual(HotKeyConfiguration.read(from: defaults), configuration)
        let remapped = HotKeyBinding(keyCode: 7, modifiers: UInt32(cmdKey | optionKey))
        configuration[.recordingPauseResume] = remapped
        configuration[.recordingStopSave] = nil
        configuration[.capture] = nil
        try configuration.save(to: defaults)
        let read = HotKeyConfiguration.read(from: defaults)
        XCTAssertEqual(read.transportBindings, Set([remapped]))
        XCTAssertNil(read[.recordingStopSave]); XCTAssertNil(read[.capture])
        XCTAssertEqual(read[.history], HotKeyConfiguration.defaults[.history])
        XCTAssertEqual(read[.recordingPauseResume]?.displayName, "⌥⌘X")
    }

    func testTransportConflictsRejectSaveWithoutOverwritingStoredConfiguration() throws {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        try configured().save(to: defaults)
        let before = defaults.data(forKey: HotKeyConfiguration.preferenceKey)
        var duplicate = configured()
        duplicate[.recordingPauseResume] = duplicate[.capture]
        XCTAssertNotNil(duplicate.validationMessage)
        XCTAssertThrowsError(try duplicate.save(to: defaults))
        duplicate = configured(); duplicate[.recordingStopSave] = pause
        XCTAssertThrowsError(try duplicate.save(to: defaults))
        XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.preferenceKey), before)
    }

    @MainActor func testOnlyActiveTakeRegistersTransportAndRepeatedPausedStateKeepsRegistration() throws {
        let backend = RecordingHotKeyBackendFixture()
        let service = HotKeyService(backend: backend, dispatch: { $0() }); defer { service.invalidate() }
        service.register(configured())
        XCTAssertEqual(Set(backend.bindings.values), Set(HotKeyBinding.defaults))
        XCTAssertNil(backend.id(for: pause)); XCTAssertNil(backend.id(for: stop))
        service.setRecordingActive(false) // Idle and countdown are both inactive.
        XCTAssertEqual(backend.bindings.count, 4)
        service.setRecordingActive(true)
        XCTAssertEqual(backend.bindings.count, 6)
        let id = try XCTUnwrap(backend.id(for: pause))
        service.setRecordingActive(true) // Pause remains the same active take.
        XCTAssertEqual(backend.id(for: pause), id)
        service.setRecordingActive(false)
        XCTAssertEqual(backend.bindings.count, 4)
        XCTAssertNil(backend.id(for: pause)); XCTAssertNil(backend.id(for: stop))
    }

    @MainActor func testHeldPressFiresOnceUntilReleaseForBothTransportActions() throws {
        let backend = RecordingHotKeyBackendFixture()
        let service = HotKeyService(backend: backend, dispatch: { $0() }); defer { service.invalidate() }
        service.register(configured()); service.setRecordingActive(true)
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        for (binding, action) in [(pause, HotKeyAction.recordingPauseResume), (stop, .recordingStopSave)] {
            let id = try XCTUnwrap(backend.id(for: binding))
            for _ in 0..<20 { backend.emit(id, .pressed) }
            XCTAssertEqual(actions.filter { $0 == action }.count, 1)
            service.setRecordingActive(true)
            backend.emit(id, .pressed)
            XCTAssertEqual(actions.filter { $0 == action }.count, 1)
            backend.emit(id, .released); backend.emit(id, .pressed)
            XCTAssertEqual(actions.filter { $0 == action }.count, 2)
        }
    }

    @MainActor func testSettingsEmptyConfigurationStaysEmptyThroughLifecycleChangesUntilRestored() throws {
        let backend = RecordingHotKeyBackendFixture()
        let queue = RecordingHotKeyDispatchFixture()
        let service = HotKeyService(backend: backend, dispatch: queue.enqueue); defer { service.invalidate() }
        service.register(configured()); service.setRecordingActive(true)
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        let old = try XCTUnwrap(backend.id(for: pause)); backend.emit(old, .pressed)
        service.register(HotKeyConfiguration(shortcuts: []))
        service.setRecordingActive(false); service.setRecordingActive(true)
        XCTAssertTrue(backend.bindings.isEmpty)
        backend.emit(old, .released); backend.emit(old, .pressed); queue.drain()
        XCTAssertTrue(actions.isEmpty)
        service.register(configured())
        XCTAssertEqual(backend.bindings.count, 6)
        backend.emit(try XCTUnwrap(backend.id(for: pause)), .pressed); queue.drain()
        XCTAssertEqual(actions, [.recordingPauseResume])
    }

    @MainActor func testPublishedActiveValuesPreserveSameTurnSessionBoundaryAndSettingsSuspension() throws {
        let backend = RecordingHotKeyBackendFixture()
        let queue = RecordingHotKeyDispatchFixture()
        let service = HotKeyService(backend: backend, dispatch: queue.enqueue); defer { service.invalidate() }
        let lifecycle = RecordingHotKeyLifecycleFixture()
        var published: [Bool] = [], storedDuringDelivery: [Bool] = []
        // Exercise the actual Combine @Published willSet contract used by
        // AppMain. Re-reading the backing property or coalescing onto another
        // queue would lose the false/true boundary driven below.
        let observation = lifecycle.$isRecording.removeDuplicates().sink { [weak service] active in
            MainActor.assumeIsolated {
                published.append(active)
                storedDuringDelivery.append(lifecycle.isRecording)
                service?.setRecordingActive(active)
            }
        }
        defer { observation.cancel() }
        service.register(configured())
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        XCTAssertEqual(backend.bindings.count, 4)
        lifecycle.isRecording = true
        let previous = try XCTUnwrap(backend.id(for: pause))
        backend.emit(previous, .pressed)
        lifecycle.isRecording = true // Paused/repeated active publication.
        XCTAssertEqual(backend.id(for: pause), previous)
        lifecycle.isRecording = false
        XCTAssertEqual(backend.bindings.count, 4)
        lifecycle.isRecording = true // Restart within this same main-actor turn.
        let restarted = try XCTUnwrap(backend.id(for: pause))
        XCTAssertNotEqual(previous, restarted)
        XCTAssertEqual(published, [false, true, false, true])
        XCTAssertEqual(storedDuringDelivery, [false, false, true, false])
        backend.emit(previous, .released); backend.emit(previous, .pressed)
        queue.drain(); XCTAssertTrue(actions.isEmpty)
        backend.emit(restarted, .pressed); queue.drain()
        XCTAssertEqual(actions, [.recordingPauseResume])

        service.register(HotKeyConfiguration(shortcuts: []))
        lifecycle.isRecording = false; lifecycle.isRecording = true
        XCTAssertTrue(service.isRecordingActive)
        XCTAssertTrue(backend.bindings.isEmpty, "Settings suspension must survive publisher-driven restart")
        service.register(configured())
        XCTAssertEqual(backend.bindings.count, 6)
        backend.emit(try XCTUnwrap(backend.id(for: stop)), .pressed); queue.drain()
        XCTAssertEqual(actions, [.recordingPauseResume, .recordingStopSave])

        observation.cancel(); service.invalidate()
        let deliveredCount = published.count
        lifecycle.isRecording = false; lifecycle.isRecording = true
        XCTAssertEqual(published.count, deliveredCount)
        XCTAssertTrue(backend.bindings.isEmpty)
    }

    @MainActor func testRemapRejectsQueuedAndNativeStalePressAndReleaseEvents() throws {
        let backend = RecordingHotKeyBackendFixture()
        let queue = RecordingHotKeyDispatchFixture()
        let service = HotKeyService(backend: backend, dispatch: queue.enqueue); defer { service.invalidate() }
        var configuration = configured()
        service.register(configuration); service.setRecordingActive(true)
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        let old = try XCTUnwrap(backend.id(for: pause)); backend.emit(old, .pressed)
        let remap = HotKeyBinding(keyCode: 7, modifiers: UInt32(controlKey | optionKey))
        configuration[.recordingPauseResume] = remap; service.register(configuration)
        let current = try XCTUnwrap(backend.id(for: remap))
        XCTAssertNotEqual(old, current)
        backend.emit(old, .pressed); queue.drain(); XCTAssertTrue(actions.isEmpty)
        backend.emit(current, .pressed)
        backend.emit(old, .released) // A stale release must not unlock the current key.
        backend.emit(current, .pressed); queue.drain()
        XCTAssertEqual(actions, [.recordingPauseResume])
        backend.emit(current, .released); backend.emit(current, .pressed); queue.drain()
        XCTAssertEqual(actions, [.recordingPauseResume, .recordingPauseResume])
    }

    @MainActor func testSessionBoundaryRejectsQueuedCommandsAndAlreadyHeldNewRegistration() throws {
        let backend = RecordingHotKeyBackendFixture()
        let queue = RecordingHotKeyDispatchFixture()
        let service = HotKeyService(backend: backend, dispatch: queue.enqueue); defer { service.invalidate() }
        service.register(configured()); service.setRecordingActive(true)
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        let previous = try XCTUnwrap(backend.id(for: stop)); backend.emit(previous, .pressed)
        backend.downKeys.insert(stop.keyCode)
        service.setRecordingActive(false); service.setRecordingActive(true)
        let current = try XCTUnwrap(backend.id(for: stop)); XCTAssertNotEqual(previous, current)
        backend.emit(previous, .released); backend.emit(current, .pressed); queue.drain()
        XCTAssertTrue(actions.isEmpty)
        backend.downKeys.remove(stop.keyCode)
        backend.emit(current, .released); backend.emit(current, .pressed); queue.drain()
        XCTAssertEqual(actions, [.recordingStopSave])
    }

    @MainActor func testAlreadyHeldKeyDoesNotFireAgainAfterSettingsRestore() throws {
        let backend = RecordingHotKeyBackendFixture()
        let service = HotKeyService(backend: backend, dispatch: { $0() }); defer { service.invalidate() }
        service.register(configured()); service.setRecordingActive(true)
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        backend.emit(try XCTUnwrap(backend.id(for: pause)), .pressed)
        backend.downKeys.insert(pause.keyCode)
        service.register(HotKeyConfiguration(shortcuts: [])); service.register(configured())
        let restored = try XCTUnwrap(backend.id(for: pause))
        backend.emit(restored, .pressed)
        XCTAssertEqual(actions, [.recordingPauseResume])
        backend.downKeys.remove(pause.keyCode)
        backend.emit(restored, .released); backend.emit(restored, .pressed)
        XCTAssertEqual(actions, [.recordingPauseResume, .recordingPauseResume])
    }

    @MainActor func testRegistrationFailuresCoverUnavailableInvalidAndConflictingChords() {
        let backend = RecordingHotKeyBackendFixture(); backend.unavailable.insert(pause)
        let service = HotKeyService(backend: backend, dispatch: { $0() }); defer { service.invalidate() }
        service.register(configured()); XCTAssertTrue(service.failures.isEmpty)
        service.setRecordingActive(true)
        XCTAssertEqual(service.failures, [.recordingPauseResume])
        XCTAssertNil(backend.id(for: pause)); XCTAssertNotNil(backend.id(for: stop))
        backend.unavailable.removeAll()
        var invalid = configured()
        invalid[.recordingPauseResume] = invalid[.capture]
        invalid[.recordingStopSave] = HotKeyBinding(keyCode: 999, modifiers: UInt32(cmdKey))
        service.register(invalid)
        XCTAssertEqual(Set(service.failures), Set([.capture, .recordingPauseResume, .recordingStopSave]))
        XCTAssertEqual(backend.bindings.count, 3)
        var duplicate = configured()
        duplicate.shortcuts.append(HotKeyShortcut(action: .recordingPauseResume, binding: pause))
        service.register(duplicate)
        XCTAssertEqual(service.failures, [.recordingPauseResume])
        XCTAssertEqual(backend.bindings.count, 5)
        service.register(configured())
        XCTAssertTrue(service.failures.isEmpty); XCTAssertEqual(backend.bindings.count, 6)
    }

    @MainActor func testInvalidateClearsRegistrationsAndRejectsQueuedAndCapturedCallbacks() throws {
        let backend = RecordingHotKeyBackendFixture()
        let queue = RecordingHotKeyDispatchFixture()
        let service = HotKeyService(backend: backend, dispatch: queue.enqueue)
        service.register(configured()); service.setRecordingActive(true)
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        let id = try XCTUnwrap(backend.id(for: pause)); backend.emit(id, .pressed)
        let capturedCallback = backend.onEvent
        backend.onUnregister = { capturedCallback?($0, .released); capturedCallback?($0, .pressed) }
        service.invalidate(); service.invalidate()
        capturedCallback?(id, .released); capturedCallback?(id, .pressed); queue.drain()
        service.register(configured()); service.setRecordingActive(true)
        XCTAssertTrue(actions.isEmpty); XCTAssertTrue(backend.bindings.isEmpty)
        XCTAssertNil(backend.onEvent); XCTAssertEqual(backend.invalidations, 1)
        XCTAssertFalse(service.isRecordingActive)
    }

    @MainActor func testCleanupAfterOwnerReleaseDoesNotKeepServiceAlive() async throws {
        let backend = RecordingHotKeyBackendFixture()
        let queue = RecordingHotKeyDispatchFixture()
        let cleaned = expectation(description: "backend released its registrations")
        backend.onInvalidate = { cleaned.fulfill() }
        var service: HotKeyService? = HotKeyService(backend: backend, dispatch: queue.enqueue)
        weak var weakService = service
        service?.register(configured()); service?.setRecordingActive(true)
        backend.emit(try XCTUnwrap(backend.id(for: pause)), .pressed)
        service = nil
        XCTAssertNil(weakService)
        await fulfillment(of: [cleaned], timeout: 2)
        queue.drain()
        XCTAssertTrue(backend.bindings.isEmpty); XCTAssertNil(backend.onEvent)
    }

    @MainActor func testRepeatedReconfigurationBoundsLiveRegistrationsAndPreservesLegacyActions() throws {
        let backend = RecordingHotKeyBackendFixture()
        let service = HotKeyService(backend: backend, dispatch: { $0() }); defer { service.invalidate() }
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        for _ in 0..<40 {
            service.register(configured()); service.setRecordingActive(true)
            XCTAssertEqual(backend.bindings.count, 6)
            for action in [HotKeyAction.capture, .clipboardPin, .history, .restoreLastPin] {
                let binding = try XCTUnwrap(configured()[action])
                let id = try XCTUnwrap(backend.id(for: binding))
                backend.emit(id, .pressed); backend.emit(id, .released)
                XCTAssertEqual(actions.last, action)
            }
            service.setRecordingActive(false); XCTAssertEqual(backend.bindings.count, 4)
        }
        XCTAssertEqual(backend.maximumLiveCount, 6)
        XCTAssertEqual(Set(backend.allocatedIDs).count, backend.allocatedIDs.count)
    }
}

@MainActor private final class RecordingHotKeyBackendFixture: HotKeyBackend {
    var onEvent: ((UInt32, HotKeyEventPhase) -> Void)?
    var onUnregister: ((UInt32) -> Void)?
    var onInvalidate: (() -> Void)?
    var bindings: [UInt32: HotKeyBinding] = [:]
    var unavailable: Set<HotKeyBinding> = []
    var downKeys: Set<UInt32> = []
    var allocatedIDs: [UInt32] = []
    var maximumLiveCount = 0
    var invalidations = 0
    func register(_ binding: HotKeyBinding, id: UInt32) -> Bool {
        allocatedIDs.append(id)
        guard !unavailable.contains(binding) else { return false }
        bindings[id] = binding; maximumLiveCount = max(maximumLiveCount, bindings.count)
        return true
    }
    func unregister(_ id: UInt32) { bindings.removeValue(forKey: id); onUnregister?(id) }
    func isKeyDown(_ keyCode: UInt32) -> Bool { downKeys.contains(keyCode) }
    func invalidate() { invalidations += 1; bindings.removeAll(); onEvent = nil; onInvalidate?() }
    func id(for binding: HotKeyBinding) -> UInt32? { bindings.first { $0.value == binding }?.key }
    func emit(_ id: UInt32, _ phase: HotKeyEventPhase) { onEvent?(id, phase) }
}

@MainActor private final class RecordingHotKeyDispatchFixture {
    private var pending: [@MainActor () -> Void] = []
    func enqueue(_ callback: @escaping @MainActor () -> Void) { pending.append(callback) }
    func drain() {
        let callbacks = pending; pending.removeAll()
        callbacks.forEach { $0() }
    }
}

@MainActor private final class RecordingHotKeyLifecycleFixture: ObservableObject {
    @Published var isRecording = false
}
