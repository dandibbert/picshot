import XCTest
import Foundation
import Carbon
@testable import PicShot

final class CaptureChainHotKeyTests: XCTestCase {
    private let chain = HotKeyBinding(keyCode: 8, modifiers: UInt32(cmdKey | optionKey))
    private let pause = HotKeyBinding(keyCode: 35, modifiers: UInt32(cmdKey | controlKey))
    private let stop = HotKeyBinding(keyCode: 1, modifiers: UInt32(cmdKey | controlKey))

    // Deliberately limited to the enum understood by stable214/experimental241.
    // Decoding this type would fail for the entire array if action 6 leaked in.
    private enum PreviousAction: Int, Codable {
        case capture = 0, clipboardPin = 1, history = 2, restoreLastPin = 3
        case recordingPauseResume = 4, recordingStopSave = 5
    }
    private struct PreviousShortcut: Codable, Equatable {
        let action: PreviousAction
        let binding: HotKeyBinding
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "PicShot-CaptureChainHotKeyTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }
    private func configured() -> HotKeyConfiguration {
        var configuration = HotKeyConfiguration.defaults
        configuration[.recordingPauseResume] = pause
        configuration[.recordingStopSave] = stop
        configuration[.runSelectedCaptureChain] = chain
        return configuration
    }
    private func previousShortcuts(_ defaults: UserDefaults) throws -> [PreviousShortcut] {
        try JSONDecoder().decode([PreviousShortcut].self,
            from: XCTUnwrap(defaults.data(forKey: HotKeyConfiguration.preferenceKey)))
    }

    func testAbsentCompanionIsUnassignedAndDoesNotChangeAnyOriginalDefault() throws {
        try withDefaults { defaults, _ in
            XCTAssertEqual(HotKeyAction.runSelectedCaptureChain.rawValue, 6)
            XCTAssertNil(HotKeyAction.runSelectedCaptureChain.defaultBinding)
            XCTAssertFalse(HotKeyAction.runSelectedCaptureChain.requiresActiveRecording)
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), .defaults)
            XCTAssertNil(HotKeyConfiguration.read(from: defaults)[.runSelectedCaptureChain])
            try HotKeyConfiguration.defaults.save(to: defaults)
            XCTAssertNil(defaults.object(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey))
            XCTAssertEqual(try previousShortcuts(defaults).map(\.action.rawValue), [0, 1, 2, 3])
        }
    }

    func testSevenRuntimeActionsRoundTripAsSixLegacyActionsAndIndependentCompanion() throws {
        try withDefaults { defaults, _ in
            let configuration = configured()
            try configuration.save(to: defaults)
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), configuration)
            let previous = try previousShortcuts(defaults)
            XCTAssertEqual(previous.map(\.action.rawValue), [0, 1, 2, 3, 4, 5])
            for shortcut in previous {
                XCTAssertEqual(shortcut.binding, configuration[try XCTUnwrap(HotKeyAction(rawValue: shortcut.action.rawValue))])
            }
            let companion = try XCTUnwrap(defaults.data(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey))
            XCTAssertEqual(try JSONDecoder().decode(HotKeyBinding.self, from: companion), chain)
            XCTAssertEqual(configuration.transportBindings, Set([pause, stop]))
        }
    }

    func testClearingCompanionPreservesAllSixLegacyBindings() throws {
        try withDefaults { defaults, _ in
            var configuration = configured()
            try configuration.save(to: defaults)
            let previous = try previousShortcuts(defaults)
            configuration[.runSelectedCaptureChain] = nil
            try configuration.save(to: defaults)
            XCTAssertEqual(try previousShortcuts(defaults), previous)
            XCTAssertNil(defaults.object(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey))
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), configuration)
        }
    }

    func testAllLegacyExplicitClearSubsetsRemainClearedWithAssignedCompanion() throws {
        try withDefaults { defaults, _ in
            let complete = configured()
            for mask in 0..<64 {
                let configuration = HotKeyConfiguration(shortcuts: complete.shortcuts.filter {
                    $0.action == .runSelectedCaptureChain || mask & (1 << $0.action.rawValue) != 0
                })
                try configuration.save(to: defaults)
                XCTAssertEqual(HotKeyConfiguration.read(from: defaults), configuration)
                XCTAssertEqual(try previousShortcuts(defaults).map(\.action.rawValue),
                    (0..<6).filter { mask & (1 << $0) != 0 })
            }
        }
    }

    func testOlderBuildChangingLegacyPayloadPreservesLocalCompanionOnReturn() throws {
        try withDefaults { defaults, _ in
            try configured().save(to: defaults)
            let companion = defaults.data(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey)
            let changed = HotKeyBinding(keyCode: 7, modifiers: UInt32(cmdKey | optionKey))
            // Older Settings writes only its supported array, including clears.
            let previous = [PreviousShortcut(action: .capture, binding: changed)]
            defaults.set(try JSONEncoder().encode(previous), forKey: HotKeyConfiguration.preferenceKey)
            let read = HotKeyConfiguration.read(from: defaults)
            XCTAssertEqual(read[.capture], changed)
            XCTAssertEqual(read[.runSelectedCaptureChain], chain)
            XCTAssertEqual(read.shortcuts.count, 2)
            XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey), companion)
            XCTAssertEqual(try previousShortcuts(defaults), previous)
        }
    }

    func testLegacyMigrationPreservesHistorySlotClearsAndCompanionWithoutWrites() throws {
        try withDefaults { defaults, name in
            let legacy = [try XCTUnwrap(HotKeyAction.capture.defaultBinding),
                          try XCTUnwrap(HotKeyAction.clipboardPin.defaultBinding),
                          try XCTUnwrap(HotKeyAction.restoreLastPin.defaultBinding)]
            defaults.set(try JSONEncoder().encode(legacy), forKey: HotKeyConfiguration.legacyPreferenceKey)
            defaults.set(try JSONEncoder().encode(chain), forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey)
            let before = (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
            let migrated = HotKeyConfiguration.read(from: defaults)
            XCTAssertEqual(migrated[.history], legacy[2])
            XCTAssertNil(migrated[.restoreLastPin])
            XCTAssertEqual(migrated[.runSelectedCaptureChain], chain)
            XCTAssertTrue(migrated.transportBindings.isEmpty)
            XCTAssertEqual((defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary, before)

            defaults.set(try JSONEncoder().encode(Array(legacy.prefix(1))), forKey: HotKeyConfiguration.legacyPreferenceKey)
            let partial = HotKeyConfiguration.read(from: defaults)
            XCTAssertNil(partial[.clipboardPin]); XCTAssertNil(partial[.history])
            XCTAssertEqual(partial[.restoreLastPin], HotKeyAction.restoreLastPin.defaultBinding)
            XCTAssertEqual(partial[.runSelectedCaptureChain], chain)
            XCTAssertNil(defaults.object(forKey: HotKeyConfiguration.preferenceKey))
        }
    }

    func testCombinedConflictInvalidChordAndDuplicateActionRejectBothPreferenceWrites() throws {
        try withDefaults { defaults, name in
            let complete = configured()
            try complete.save(to: defaults)
            let before = (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
            var conflict = complete
            conflict[.capture] = chain
            var invalid = complete
            invalid[.runSelectedCaptureChain] = HotKeyBinding(keyCode: 999, modifiers: UInt32(cmdKey))
            var duplicate = complete
            duplicate.shortcuts.append(HotKeyShortcut(action: .runSelectedCaptureChain,
                binding: HotKeyBinding(keyCode: 7, modifiers: UInt32(cmdKey))))
            for configuration in [conflict, invalid, duplicate] {
                XCTAssertThrowsError(try configuration.save(to: defaults))
                XCTAssertEqual((defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary, before)
            }
        }
    }

    func testMalformedCompanionDoesNotDestroyLegacyBindingsOrRewritePreferences() throws {
        try withDefaults { defaults, name in
            var legacy = configured(); legacy[.runSelectedCaptureChain] = nil
            try legacy.save(to: defaults)
            defaults.set(Data("{broken".utf8), forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey)
            let before = (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), legacy)
            XCTAssertEqual((defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary, before)
        }
    }

    @MainActor func testInvalidationDiscardsQueuedChainOnlyAndPreservesHeldStateAndRecordingCallbacks() throws {
        let backend = CaptureChainHotKeyBackend()
        let queue = CaptureChainHotKeyDispatch()
        let service = HotKeyService(backend: backend, dispatch: queue.enqueue)
        defer { service.invalidate() }
        service.register(configured()); service.setRecordingActive(true)
        let chainID = try XCTUnwrap(backend.id(for: chain))
        let pauseID = try XCTUnwrap(backend.id(for: pause))
        let stopID = try XCTUnwrap(backend.id(for: stop))
        let liveBefore = backend.bindings, registrationCount = backend.registrations, removalCount = backend.removals
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        backend.emit(chainID, .pressed); backend.emit(pauseID, .pressed); backend.emit(stopID, .pressed)
        service.invalidateSelectedCaptureChainCommands()
        queue.drain()
        XCTAssertEqual(actions, [.recordingPauseResume, .recordingStopSave])
        XCTAssertEqual(backend.bindings, liveBefore)
        XCTAssertEqual(backend.registrations, registrationCount); XCTAssertEqual(backend.removals, removalCount)
        for _ in 0..<20 { backend.emit(chainID, .pressed) }
        queue.drain()
        XCTAssertEqual(actions, [.recordingPauseResume, .recordingStopSave], "Invalidation must not rearm an already-held key")
        backend.emit(chainID, .released); backend.emit(chainID, .pressed); queue.drain()
        XCTAssertEqual(actions, [.recordingPauseResume, .recordingStopSave, .runSelectedCaptureChain])
    }

    @MainActor func testImmediateSuccessBoundaryRejectsOldQueuedRunAndAdmitsIntentionalNewPress() throws {
        let backend = CaptureChainHotKeyBackend()
        let queue = CaptureChainHotKeyDispatch()
        let service = HotKeyService(backend: backend, dispatch: queue.enqueue)
        defer { service.invalidate() }
        service.register(configured()); service.setRecordingActive(true)
        let chainID = try XCTUnwrap(backend.id(for: chain))
        let pauseID = try XCTUnwrap(backend.id(for: pause))
        var actions: [HotKeyAction] = []
        service.onAction = { action in
            actions.append(action)
            if action == .runSelectedCaptureChain {
                service.invalidateSelectedCaptureChainCommands() // Synchronous admission.
                service.invalidateSelectedCaptureChainCommands() // Zero-delay successful retirement.
            }
        }
        backend.emit(chainID, .pressed); backend.emit(chainID, .released)
        backend.emit(chainID, .pressed); backend.emit(pauseID, .pressed)
        queue.drain()
        XCTAssertEqual(actions, [.runSelectedCaptureChain, .recordingPauseResume])
        backend.emit(chainID, .pressed); queue.drain()
        XCTAssertEqual(actions.count, 2)
        backend.emit(chainID, .released); backend.emit(chainID, .pressed); queue.drain()
        XCTAssertEqual(actions, [.runSelectedCaptureChain, .recordingPauseResume, .runSelectedCaptureChain])
    }

    @MainActor func testRunReceivedDuringActiveChainCannotCrossItsRetirementBoundary() throws {
        let backend = CaptureChainHotKeyBackend()
        let queue = CaptureChainHotKeyDispatch()
        let service = HotKeyService(backend: backend, dispatch: queue.enqueue)
        defer { service.invalidate() }
        service.register(configured()); service.setRecordingActive(true)
        let chainID = try XCTUnwrap(backend.id(for: chain))
        let stopID = try XCTUnwrap(backend.id(for: stop))
        var actions: [HotKeyAction] = []
        service.onAction = { action in
            actions.append(action)
            if action == .runSelectedCaptureChain { service.invalidateSelectedCaptureChainCommands() }
        }
        backend.emit(chainID, .pressed); queue.drain()
        XCTAssertEqual(actions, [.runSelectedCaptureChain])
        backend.emit(chainID, .released); backend.emit(chainID, .pressed)
        backend.emit(stopID, .pressed)
        service.invalidateSelectedCaptureChainCommands() // The active run finishes before these callbacks deliver.
        queue.drain()
        XCTAssertEqual(actions, [.runSelectedCaptureChain, .recordingStopSave])
        backend.emit(chainID, .released); backend.emit(chainID, .pressed); queue.drain()
        XCTAssertEqual(actions, [.runSelectedCaptureChain, .recordingStopSave, .runSelectedCaptureChain])
    }

    @MainActor func testCompanionConflictPreventsBothRegistrationsWithoutARecordingSession() throws {
        let backend = CaptureChainHotKeyBackend()
        let service = HotKeyService(backend: backend, dispatch: { $0() })
        defer { service.invalidate() }
        var configuration = configured()
        configuration[.runSelectedCaptureChain] = configuration[.capture]
        service.register(configuration)
        XCTAssertEqual(Set(service.failures), Set([.capture, .runSelectedCaptureChain]))
        XCTAssertEqual(backend.bindings.count, 3)
        service.register(configured())
        XCTAssertTrue(service.failures.isEmpty)
        XCTAssertEqual(backend.bindings.count, 5)
        var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
        backend.emit(try XCTUnwrap(backend.id(for: chain)), .pressed)
        XCTAssertEqual(actions, [.runSelectedCaptureChain])
    }
}

@MainActor private final class CaptureChainHotKeyBackend: HotKeyBackend {
    var onEvent: ((UInt32, HotKeyEventPhase) -> Void)?
    var bindings: [UInt32: HotKeyBinding] = [:]
    var registrations = 0
    var removals = 0
    func register(_ binding: HotKeyBinding, id: UInt32) -> Bool {
        registrations += 1; bindings[id] = binding; return true
    }
    func unregister(_ id: UInt32) { removals += 1; bindings.removeValue(forKey: id) }
    func isKeyDown(_ keyCode: UInt32) -> Bool { false }
    func invalidate() { bindings.removeAll(); onEvent = nil }
    func id(for binding: HotKeyBinding) -> UInt32? { bindings.first { $0.value == binding }?.key }
    func emit(_ id: UInt32, _ phase: HotKeyEventPhase) { onEvent?(id, phase) }
}

@MainActor private final class CaptureChainHotKeyDispatch {
    private var pending: [@MainActor () -> Void] = []
    func enqueue(_ callback: @escaping @MainActor () -> Void) { pending.append(callback) }
    func drain() {
        let callbacks = pending; pending.removeAll()
        callbacks.forEach { $0() }
    }
}
