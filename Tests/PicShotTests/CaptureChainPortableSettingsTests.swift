import XCTest
import Foundation
import Carbon
@testable import PicShot

@MainActor final class CaptureChainPortableSettingsTests: XCTestCase {
    private let chain = HotKeyBinding(keyCode: 8, modifiers: UInt32(cmdKey | optionKey))
    private let replacement = HotKeyBinding(keyCode: 7, modifiers: UInt32(cmdKey | optionKey))
    private enum Failure: Error { case write }
    private enum PreviousAction: Int, Decodable {
        case capture = 0, clipboardPin = 1, history = 2, restoreLastPin = 3
        case recordingPauseResume = 4, recordingStopSave = 5
    }
    private struct PreviousShortcut: Decodable {
        let action: PreviousAction
        let binding: HotKeyBinding
    }

    private func withDefaults(_ body: (UserDefaults, String, PortableSettingsStore) throws -> Void) rethrows {
        let name = "PicShot-CaptureChainPortableSettingsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name, PortableSettingsStore(defaults: defaults, persistentDomainName: name))
    }
    private func configureCompanion(_ defaults: UserDefaults) throws {
        var configuration = HotKeyConfiguration.defaults
        configuration[.runSelectedCaptureChain] = chain
        try configuration.save(to: defaults)
    }
    private func object(_ store: PortableSettingsStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
    }
    private func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func changedImport(_ store: PortableSettingsStore, history: HotKeyBinding? = nil) throws -> Data {
        var document = try object(store)
        var preferences = try XCTUnwrap(document["preferences"] as? [String: Any])
        preferences["appearance"] = "dark"; document["preferences"] = preferences
        var hotkeys = try XCTUnwrap(document["hotkeys"] as? [[String: Any]])
        for index in hotkeys.indices {
            let binding: HotKeyBinding?
            switch hotkeys[index]["action"] as? String {
            case "history": binding = history ?? replacement
            case "recordingPauseResume": binding = HotKeyBinding(keyCode: 35, modifiers: UInt32(cmdKey | controlKey))
            case "recordingStopSave": binding = HotKeyBinding(keyCode: 1, modifiers: UInt32(cmdKey | controlKey))
            default: binding = nil
            }
            if let binding { hotkeys[index]["binding"] = ["keyCode": binding.keyCode, "modifiers": binding.modifiers] }
        }
        document["hotkeys"] = hotkeys
        return try encoded(document)
    }
    private func domain(_ defaults: UserDefaults, _ name: String) -> NSDictionary {
        (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
    }

    func testExportRemainsIdenticalSixActionDocumentWithLocalCompanion() throws {
        try withDefaults { defaults, name, store in
            let before = try store.exportData()
            try configureCompanion(defaults)
            let persisted = domain(defaults, name)
            XCTAssertEqual(try store.exportData(), before)
            let document = try object(store)
            let hotkeys = try XCTUnwrap(document["hotkeys"] as? [[String: Any]])
            XCTAssertEqual(hotkeys.compactMap { $0["action"] as? String },
                ["capture", "clipboardPin", "restoreLastPin", "history", "recordingPauseResume", "recordingStopSave"])
            let plan = try store.prepareImport(before)
            XCTAssertFalse(plan.hasChanges); XCTAssertFalse(plan.changesHotKeys)
            XCTAssertEqual(plan.hotKeyConfiguration[.runSelectedCaptureChain], chain)
            try store.apply(plan, validateHotkeys: { _ in XCTFail("Unchanged shortcuts must not be re-registered") })
            XCTAssertEqual(domain(defaults, name), persisted)
        }
    }

    func testSixActionImportValidatesMergedRuntimeAndWritesOnlyOldDecodableArray() throws {
        try withDefaults { defaults, name, store in
            try configureCompanion(defaults)
            let companion = defaults.data(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey)
            let before = domain(defaults, name)
            let plan = try store.prepareImport(changedImport(store))
            XCTAssertEqual(plan.hotKeyConfiguration.shortcuts.count, 7)
            XCTAssertEqual(plan.hotKeyConfiguration[.runSelectedCaptureChain], chain)
            XCTAssertFalse(plan.changes.contains { $0.id == "hotkey.6" })
            var validations = 0
            try store.apply(plan, validateHotkeys: { proposed in
                validations += 1
                XCTAssertEqual(proposed[.runSelectedCaptureChain], chain)
                XCTAssertEqual(proposed.shortcuts.count, 7)
                XCTAssertNil(proposed.validationMessage)
                XCTAssertEqual(domain(defaults, name), before)
            })
            XCTAssertEqual(validations, 1)
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), plan.hotKeyConfiguration)
            XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey), companion)
            let stored = try XCTUnwrap(defaults.data(forKey: HotKeyConfiguration.preferenceKey))
            let previous = try JSONDecoder().decode([PreviousShortcut].self, from: stored)
            XCTAssertEqual(previous.map(\.action.rawValue), [0, 1, 2, 3, 4, 5])
        }
    }

    func testExplicitlyClearingEveryPortableActionPreservesCompanion() throws {
        try withDefaults { defaults, _, store in
            try configureCompanion(defaults)
            let companion = defaults.data(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey)
            var document = try object(store)
            var hotkeys = try XCTUnwrap(document["hotkeys"] as? [[String: Any]])
            for index in hotkeys.indices { hotkeys[index]["binding"] = NSNull() }
            document["hotkeys"] = hotkeys
            let plan = try store.prepareImport(encoded(document))
            XCTAssertEqual(plan.hotKeyConfiguration.shortcuts, [HotKeyShortcut(action: .runSelectedCaptureChain, binding: chain)])
            try store.apply(plan)
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), plan.hotKeyConfiguration)
            XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey), companion)
            let stored = try XCTUnwrap(defaults.data(forKey: HotKeyConfiguration.preferenceKey))
            XCTAssertTrue(try JSONDecoder().decode([PreviousShortcut].self, from: stored).isEmpty)
        }
    }

    func testImportedChordConflictWithLocalCompanionRejectsBeforeAnyWrite() throws {
        try withDefaults { defaults, name, store in
            try configureCompanion(defaults)
            let before = domain(defaults, name)
            store.beforeWrite = { _ in XCTFail("A conflicting import must never start writing") }
            XCTAssertThrowsError(try store.prepareImport(changedImport(store, history: chain))) {
                XCTAssertEqual($0 as? PortableSettingsError, .invalidValues)
            }
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testPortableVersionOneRejectsLocalSeventhActionAndChainFields() throws {
        try withDefaults { defaults, name, store in
            try configureCompanion(defaults)
            let before = domain(defaults, name)
            let base = try object(store)
            var seventh = base
            var hotkeys = try XCTUnwrap(base["hotkeys"] as? [[String: Any]])
            hotkeys.append(["action": "runSelectedCaptureChain", "binding": NSNull()])
            seventh["hotkeys"] = hotkeys
            var localBinding = base
            localBinding[HotKeyConfiguration.selectedCaptureChainPreferenceKey] = ["keyCode": chain.keyCode, "modifiers": chain.modifiers]
            var selection = base; selection["selectedCaptureChainID"] = UUID().uuidString
            var definitions = base; definitions["captureChains"] = [Any]()
            for document in [seventh, localBinding, selection, definitions] {
                XCTAssertThrowsError(try store.prepareImport(encoded(document)))
                XCTAssertEqual(domain(defaults, name), before)
            }
        }
    }

    func testCompanionAvailabilityFailureRejectsEntireImportBeforeWrites() throws {
        try withDefaults { defaults, name, store in
            try configureCompanion(defaults)
            let before = domain(defaults, name)
            let plan = try store.prepareImport(changedImport(store))
            let backend = CaptureChainImportHotKeyBackend(refused: chain)
            let service = HotKeyService(backend: backend, dispatch: { $0() })
            defer { service.invalidate() }
            var actions: [HotKeyAction] = []; service.onAction = { actions.append($0) }
            XCTAssertThrowsError(try store.apply(plan, validateHotkeys: service.validateImportedAvailability))
            XCTAssertEqual(backend.attempted.count, 7)
            XCTAssertEqual(backend.attempted.last, chain)
            XCTAssertTrue(backend.live.isEmpty); XCTAssertTrue(actions.isEmpty)
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testAssignedRemappedOrClearedCompanionInvalidatesReviewedImport() throws {
        for change in 0..<3 {
            try withDefaults { defaults, name, store in
                if change != 0 { try configureCompanion(defaults) }
                let plan = try store.prepareImport(changedImport(store))
                if change == 2 { defaults.removeObject(forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey) }
                else {
                    defaults.set(try JSONEncoder().encode(change == 0 ? chain : replacement),
                        forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey)
                }
                let afterExternalChange = domain(defaults, name)
                XCTAssertThrowsError(try store.apply(plan, validateHotkeys: { _ in XCTFail("Stale preview must be rejected before probes") })) {
                    XCTAssertEqual($0 as? PortableSettingsError, .conflict)
                }
                XCTAssertEqual(domain(defaults, name), afterExternalChange)
            }
        }
    }

    func testCompanionChangeDuringAvailabilityCheckInvalidatesReviewBeforeWrites() throws {
        try withDefaults { defaults, name, store in
            try configureCompanion(defaults)
            let plan = try store.prepareImport(changedImport(store))
            var expected = defaults.persistentDomain(forName: name) ?? [:]
            let changed = try JSONEncoder().encode(replacement)
            expected[HotKeyConfiguration.selectedCaptureChainPreferenceKey] = changed
            XCTAssertThrowsError(try store.apply(plan, validateHotkeys: { proposed in
                XCTAssertEqual(proposed[.runSelectedCaptureChain], chain)
                defaults.set(changed, forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey)
            })) { XCTAssertEqual($0 as? PortableSettingsError, .conflict) }
            XCTAssertEqual(domain(defaults, name), expected as NSDictionary)
        }
    }

    func testFailedCommitRollsBackOldArrayAndLeavesCompanionExactlyIntact() throws {
        try withDefaults { defaults, name, store in
            try configureCompanion(defaults)
            let before = domain(defaults, name)
            let plan = try store.prepareImport(changedImport(store))
            var hotkeyWriteObserved = false
            store.afterWrite = { index in
                if index == 1 {
                    hotkeyWriteObserved = true
                    XCTAssertEqual(HotKeyConfiguration.read(from: defaults), plan.hotKeyConfiguration)
                    throw Failure.write
                }
            }
            XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .applyFailed) }
            XCTAssertTrue(hotkeyWriteObserved)
            XCTAssertEqual(domain(defaults, name), before)
            store.afterWrite = nil
            try store.apply(plan)
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), plan.hotKeyConfiguration)
        }
    }

    func testConcurrentCompanionWriteRollsBackOnlyImportedValuesAndPreservesNewBinding() throws {
        try withDefaults { defaults, name, store in
            try configureCompanion(defaults)
            let plan = try store.prepareImport(changedImport(store))
            var expected = defaults.persistentDomain(forName: name) ?? [:]
            let changed = try JSONEncoder().encode(replacement)
            expected[HotKeyConfiguration.selectedCaptureChainPreferenceKey] = changed
            store.beforeWrite = { index in
                if index == 1 { defaults.set(changed, forKey: HotKeyConfiguration.selectedCaptureChainPreferenceKey) }
            }
            XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .conflict) }
            XCTAssertEqual(domain(defaults, name), expected as NSDictionary)
        }
    }
}

@MainActor private final class CaptureChainImportHotKeyBackend: HotKeyBackend {
    var onEvent: ((UInt32, HotKeyEventPhase) -> Void)?
    let refused: HotKeyBinding
    var live: [UInt32: HotKeyBinding] = [:]
    var attempted: [HotKeyBinding] = []
    init(refused: HotKeyBinding) { self.refused = refused }
    func register(_ binding: HotKeyBinding, id: UInt32) -> Bool {
        attempted.append(binding)
        guard binding != refused else { return false }
        live[id] = binding; onEvent?(id, .pressed); return true
    }
    func unregister(_ id: UInt32) { live.removeValue(forKey: id) }
    func isKeyDown(_ keyCode: UInt32) -> Bool { false }
    func invalidate() { live.removeAll(); onEvent = nil }
}
