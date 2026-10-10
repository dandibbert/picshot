import XCTest
import Foundation
import Carbon
import PicShotCore
@testable import PicShot

@MainActor final class PortableSettingsTests: XCTestCase {
    private enum InjectedFailure: Error { case write, registration }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "PicShot-PortableSettingsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer {
            defaults.removePersistentDomain(forName: name)
            defaults.setVolatileDomain(registration, forName: UserDefaults.registrationDomain)
        }
        try body(defaults, name)
    }

    private func domain(_ defaults: UserDefaults, _ name: String) -> NSDictionary {
        (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
    }

    private func document(_ defaults: UserDefaults) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: PortableSettingsStore(defaults: defaults).exportData()) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func changedDocument(_ defaults: UserDefaults) throws -> [String: Any] {
        var result = try document(defaults)
        var prefs = try XCTUnwrap(result["preferences"] as? [String: Any])
        prefs["appearance"] = "dark"
        prefs["screenshotDelaySeconds"] = 5
        prefs["screenshotShowsCursor"] = true
        prefs["pinDesktopVisibility"] = "currentDesktop"
        prefs["restorePinsOnLaunch"] = true
        prefs["automaticallyRecognizePinText"] = true
        prefs["historyDays"] = 60
        prefs["historyCount"] = 300
        prefs["historyMegabytes"] = 2048
        result["preferences"] = prefs
        var hotkeys = try XCTUnwrap(result["hotkeys"] as? [[String: Any]])
        for index in hotkeys.indices {
            if hotkeys[index]["action"] as? String == "recordingPauseResume" {
                hotkeys[index]["binding"] = ["keyCode": 35, "modifiers": UInt32(cmdKey | optionKey)]
            }
            if hotkeys[index]["action"] as? String == "recordingStopSave" {
                hotkeys[index]["binding"] = ["keyCode": 1, "modifiers": UInt32(cmdKey | optionKey)]
            }
        }
        result["hotkeys"] = hotkeys
        result["annotationToolOrder"] = Array(AnnotationToolbarOrder.defaults.rawIDs.reversed())
        return result
    }

    func testExportAndNoOpImportPreserveUnsetDefaultsAndSixActions() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let before = domain(defaults, name)
            let exported = try store.exportData()
            XCTAssertEqual(exported, try store.exportData(), "Export bytes must be deterministic")
            XCTAssertEqual(domain(defaults, name), before)
            let object = try document(defaults)
            XCTAssertEqual(object["format"] as? String, "picshot.preferences")
            XCTAssertEqual(object["schemaVersion"] as? Int, 1)
            let shortcuts = try XCTUnwrap(object["hotkeys"] as? [[String: Any]])
            XCTAssertEqual(shortcuts.compactMap { $0["action"] as? String },
                ["capture", "clipboardPin", "restoreLastPin", "history", "recordingPauseResume", "recordingStopSave"])
            XCTAssertTrue(shortcuts[4]["binding"] is NSNull)
            XCTAssertTrue(shortcuts[5]["binding"] is NSNull)
            let plan = try store.prepareImport(exported)
            XCTAssertFalse(plan.hasChanges); XCTAssertFalse(plan.changesHotKeys)
            XCTAssertEqual(plan.hotKeyConfiguration, HotKeyConfiguration.defaults)
            try store.apply(plan, validateHotkeys: { _ in XCTFail("Unchanged keys must not be re-registered") })
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testExportNeverEnumeratesOrExportsPrivateOrMachineLocalData() throws {
        try withDefaults { defaults, name in
            let sentinels: [String: Any] = [
                "captureHistory": "PRIVATE_SCREENSHOT_TEXT", "ocrResults": "PRIVATE_OCR_TEXT",
                "pinSession": "PRIVATE_PIN_TEXT", "apiKey": "SECRET_ACCESS_TOKEN",
                "folderBookmark": Data("PRIVATE_BOOKMARK".utf8), "NSWindow Frame Editor": "PRIVATE_WINDOW_POSITION",
                "capturePresets.v1": Data("PRIVATE_DISPLAY_ID".utf8),
                "recordingInputEffects": Data("PRIVATE_RECORDING_INPUT_OPT_IN".utf8),
                SaveWorkflowSettings.preferenceKey: try JSONEncoder().encode(SaveWorkflowSettings(
                    baseURL: URL(fileURLWithPath: "/Users/private-customer/local-folder"), autoOnFinalizedAction: true))
            ]
            for (key, value) in sentinels { defaults.set(value, forKey: key) }
            let before = domain(defaults, name)
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let text = try XCTUnwrap(String(data: store.exportData(), encoding: .utf8))
            for forbidden in Array(sentinels.keys) + ["PRIVATE_", "SECRET_", "/Users/", "baseURL", "autoOnFinalizedAction"] {
                XCTAssertFalse(text.contains(forbidden), "Leaked \(forbidden)")
            }
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testReviewIsDeterministicReadOnlyAndApplyChangesOnlyAllowlistedValues() throws {
        try withDefaults { defaults, name in
            defaults.set("keep capture contents", forKey: "captureHistory")
            let workflow = try JSONEncoder().encode(SaveWorkflowSettings(
                baseURL: URL(fileURLWithPath: "/tmp/private-local-output"), autoOnFinalizedAction: true))
            defaults.set(workflow, forKey: SaveWorkflowSettings.preferenceKey)
            let before = domain(defaults, name)
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let input = try data(changedDocument(defaults))
            let plan = try store.prepareImport(input)
            XCTAssertEqual(plan.changes, try store.prepareImport(input).changes)
            XCTAssertEqual(plan.changes.map(\.id), ["appearance", "screenshotDelaySeconds", "screenshotShowsCursor",
                "pinDesktopVisibility", "restorePinsOnLaunch", "automaticallyRecognizePinText", "historyDays",
                "historyCount", "historyMegabytes", "hotkey.4", "hotkey.5", "annotationToolOrder"])
            XCTAssertTrue(plan.changesHistoryRetention); XCTAssertTrue(plan.changesHotKeys)
            XCTAssertEqual(domain(defaults, name), before, "Review must not persist anything")
            var validations = 0
            try store.apply(plan, validateHotkeys: { configuration in
                validations += 1
                XCTAssertEqual(domain(defaults, name), before, "Registration validation precedes every write")
                XCTAssertEqual(configuration[.recordingPauseResume], HotKeyBinding(keyCode: 35, modifiers: UInt32(cmdKey | optionKey)))
            })
            XCTAssertEqual(validations, 1)
            XCTAssertEqual(AppAppearancePreference.read(from: defaults), .dark)
            XCTAssertEqual(ScreenshotPreferences.read(from: defaults), ScreenshotCaptureOptions(delay: .fiveSeconds, showsCursor: true))
            XCTAssertEqual(HistoryRetentionPreferences.read(from: defaults), HistoryRetentionPreferences(days: 60, count: 300, megabytes: 2048))
            XCTAssertEqual(HotKeyConfiguration.read(from: defaults), plan.hotKeyConfiguration)
            XCTAssertEqual(AnnotationToolbarOrder.read(from: defaults).rawIDs, Array(AnnotationToolbarOrder.defaults.rawIDs.reversed()))
            XCTAssertEqual(defaults.data(forKey: SaveWorkflowSettings.preferenceKey), workflow)
            XCTAssertEqual(defaults.string(forKey: "captureHistory"), "keep capture contents")
            XCTAssertFalse(try store.prepareImport(input).hasChanges)
            XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .conflict) }
        }
    }

    func testCancelByDiscardingReviewLeavesAllStoredValuesUntouched() throws {
        try withDefaults { defaults, name in
            defaults.set("light", forKey: AppAppearancePreference.preferenceKey)
            let before = domain(defaults, name)
            _ = try PortableSettingsStore(defaults: defaults, persistentDomainName: name).prepareImport(data(changedDocument(defaults)))
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testMalformedTruncatedWrongShapeAndExcessiveNestingNeverMutate() throws {
        try withDefaults { defaults, name in
            defaults.set("dark", forKey: AppAppearancePreference.preferenceKey)
            let before = domain(defaults, name)
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let good = try store.exportData()
            let invalid = [Data(), Data("{".utf8), Data(good.dropLast()), good + Data(" true".utf8),
                Data("[]".utf8), Data([0xff, 0xfe]),
                Data((String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18)).utf8)]
            for input in invalid {
                XCTAssertThrowsError(try store.prepareImport(input))
                XCTAssertEqual(domain(defaults, name), before)
            }
        }
    }

    func testSizeLimitIncludesWhitespaceAndBoundedFileReader() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let good = try store.exportData()
            let atLimit = good + Data(repeating: 32, count: PortableSettingsStore.maximumFileBytes - good.count)
            XCTAssertFalse(try store.prepareImport(atLimit).hasChanges)
            let oversized = atLimit + Data([32])
            XCTAssertThrowsError(try store.prepareImport(oversized)) { XCTAssertEqual($0 as? PortableSettingsError, .tooLarge) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("settings.json")
            try good.write(to: url)
            XCTAssertEqual(try PortableSettingsStore.readImportData(from: url), good)
            try oversized.write(to: url)
            XCTAssertThrowsError(try PortableSettingsStore.readImportData(from: url)) { XCTAssertEqual($0 as? PortableSettingsError, .tooLarge) }
            XCTAssertThrowsError(try PortableSettingsStore.readImportData(from: directory))
            XCTAssertTrue(domain(defaults, name).count == 0)
        }
    }

    func testDuplicateObjectKeysIncludingEscapedEquivalentsAreRejected() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let base = try XCTUnwrap(String(data: data(document(defaults)), encoding: .utf8))
            let replacements = [
                ("\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1"),
                ("\"format\":", "\"\\u0066ormat\":\"picshot.preferences\",\"format\":"),
                ("\"historyDays\":30", "\"historyDays\":30,\"historyDays\":31"),
                ("\"keyCode\":18", "\"keyCode\":18,\"keyCode\":19"),
                ("\"action\":\"capture\"", "\"action\":\"capture\",\"action\":\"capture\"")
            ]
            let before = domain(defaults, name)
            for (needle, replacement) in replacements {
                XCTAssertTrue(base.contains(needle), "The adversarial fixture must actually replace a field")
                let corrupt = Data(base.replacingOccurrences(of: needle, with: replacement).utf8)
                XCTAssertThrowsError(try store.prepareImport(corrupt)) { XCTAssertEqual($0 as? PortableSettingsError, .malformed) }
                XCTAssertEqual(domain(defaults, name), before)
            }
        }
    }

    func testFutureVersionMissingFieldsAndUnknownFieldsRejectWholeDocument() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let base = try changedDocument(defaults)
            let before = domain(defaults, name)
            var future = base; future["schemaVersion"] = 2
            XCTAssertThrowsError(try store.prepareImport(data(future))) { XCTAssertEqual($0 as? PortableSettingsError, .unsupportedVersion) }
            var wrongFormat = base; wrongFormat["format"] = "another.application"
            var missing = base; missing.removeValue(forKey: "hotkeys")
            var extra = base; extra["credentials"] = "never accepted"
            var unknownPreference = base
            var prefs = try XCTUnwrap(base["preferences"] as? [String: Any]); prefs["recordingInputEnabled"] = true
            unknownPreference["preferences"] = prefs
            var unknownBinding = base
            var hotkeys = try XCTUnwrap(base["hotkeys"] as? [[String: Any]])
            var binding = try XCTUnwrap(hotkeys[0]["binding"] as? [String: Any]); binding["characters"] = "private typed text"
            hotkeys[0]["binding"] = binding; unknownBinding["hotkeys"] = hotkeys
            for invalid in [wrongFormat, missing, extra, unknownPreference, unknownBinding] {
                XCTAssertThrowsError(try store.prepareImport(data(invalid)))
                XCTAssertEqual(domain(defaults, name), before)
            }
        }
    }

    func testInvalidPreferenceValuesAndTypesDoNotPartiallyApplyValidFields() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let base = try changedDocument(defaults)
            let before = domain(defaults, name)
            let invalid: [(String, Any)] = [("appearance", "futureTheme"), ("screenshotDelaySeconds", 2),
                ("pinDesktopVisibility", "space-identity"), ("restorePinsOnLaunch", "true"),
                ("screenshotShowsCursor", 1), ("historyDays", 0), ("historyDays", 3651),
                ("historyCount", 10001), ("historyMegabytes", 102401), ("historyCount", 1.5)]
            for (key, value) in invalid {
                var object = base
                var prefs = try XCTUnwrap(base["preferences"] as? [String: Any]); prefs[key] = value
                object["preferences"] = prefs
                XCTAssertThrowsError(try store.prepareImport(data(object)), "Accepted \(key)=\(value)")
                XCTAssertEqual(domain(defaults, name), before)
            }
        }
    }

    func testHotkeyActionCompletenessDuplicateChordsAndInvalidBindingsAreRejected() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let base = try changedDocument(defaults)
            let shortcuts = try XCTUnwrap(base["hotkeys"] as? [[String: Any]])
            let before = domain(defaults, name)
            var candidates: [[[String: Any]]] = [Array(shortcuts.dropLast()), shortcuts + [shortcuts[0]]]
            var duplicateAction = shortcuts; duplicateAction[1]["action"] = "capture"; candidates.append(duplicateAction)
            var collision = shortcuts; collision[1]["binding"] = shortcuts[0]["binding"]; candidates.append(collision)
            var unknown = shortcuts; unknown[1]["action"] = "futureAction"; candidates.append(unknown)
            var missingBinding = shortcuts; missingBinding[5].removeValue(forKey: "binding"); candidates.append(missingBinding)
            for invalidBinding in [
                ["keyCode": 128, "modifiers": Int(cmdKey)], ["keyCode": -1, "modifiers": Int(cmdKey)],
                ["keyCode": 18, "modifiers": Int(shiftKey)], ["keyCode": 18, "modifiers": 0],
                ["keyCode": 18, "modifiers": Int(cmdKey) | 1]
            ] {
                var invalid = shortcuts; invalid[0]["binding"] = invalidBinding; candidates.append(invalid)
            }
            for candidate in candidates {
                var object = base; object["hotkeys"] = candidate
                XCTAssertThrowsError(try store.prepareImport(data(object)))
                XCTAssertEqual(domain(defaults, name), before)
            }
        }
    }

    func testAllSixHotkeysCanBeExplicitlyClearedAndOptionalOrderPreservesLocalOrder() throws {
        try withDefaults { defaults, name in
            let reversed = try AnnotationToolbarOrder(rawIDs: Array(AnnotationToolbarOrder.defaults.rawIDs.reversed()))
            reversed.write(to: defaults)
            var object = try document(defaults)
            var shortcuts = try XCTUnwrap(object["hotkeys"] as? [[String: Any]])
            for index in shortcuts.indices { shortcuts[index]["binding"] = NSNull() }
            object["hotkeys"] = shortcuts; object.removeValue(forKey: "annotationToolOrder")
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(object))
            XCTAssertTrue(plan.hotKeyConfiguration.shortcuts.isEmpty)
            try store.apply(plan)
            XCTAssertTrue(HotKeyConfiguration.read(from: defaults).shortcuts.isEmpty)
            XCTAssertEqual(AnnotationToolbarOrder.read(from: defaults), reversed)
        }
    }

    func testHotkeyEntryOrderDoesNotChangeDiffOrMaterializeDefaults() throws {
        try withDefaults { defaults, name in
            var object = try document(defaults)
            let hotkeys = try XCTUnwrap(object["hotkeys"] as? [[String: Any]])
            object["hotkeys"] = Array(hotkeys.reversed())
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let before = domain(defaults, name)
            let plan = try store.prepareImport(data(object))
            XCTAssertFalse(plan.hasChanges); XCTAssertFalse(plan.changesHotKeys)
            try store.apply(plan)
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testInvalidToolbarPermutationsFailWithoutChangingOtherSettings() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let base = try changedDocument(defaults)
            let ids = AnnotationToolbarOrder.defaults.rawIDs
            var duplicate = ids; duplicate[1] = duplicate[0]
            var unknown = ids; unknown[1] = "futureTool"
            let before = domain(defaults, name)
            let invalidOrders: [Any] = [Array(ids.dropLast()), duplicate, unknown, NSNull(), "rectangle"]
            for order in invalidOrders {
                var object = base; object["annotationToolOrder"] = order
                XCTAssertThrowsError(try store.prepareImport(data(object)))
                XCTAssertEqual(domain(defaults, name), before)
            }
        }
    }

    func testThrowingRegistrationValidatorPreventsEveryWrite() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            let before = domain(defaults, name)
            var called = false
            XCTAssertThrowsError(try store.apply(plan, validateHotkeys: { _ in
                called = true; throw InjectedFailure.registration
            })) { XCTAssertTrue($0 is InjectedFailure) }
            XCTAssertTrue(called)
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testExternalValidatorIsSkippedForAppearanceOnlyImport() throws {
        try withDefaults { defaults, name in
            var object = try document(defaults)
            var prefs = try XCTUnwrap(object["preferences"] as? [String: Any]); prefs["appearance"] = "dark"
            object["preferences"] = prefs
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(object))
            XCTAssertFalse(plan.changesHotKeys)
            try store.apply(plan, validateHotkeys: { _ in XCTFail("Unchanged keys must not be probed") })
            XCTAssertEqual(AppAppearancePreference.read(from: defaults), .dark)
        }
    }

    func testStalePreviewAndDifferentStoreAreRejectedBeforeValidatorOrWrites() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            defaults.set(10, forKey: ScreenshotPreferences.delayKey)
            let afterExternalEdit = domain(defaults, name)
            XCTAssertThrowsError(try store.apply(plan, validateHotkeys: { _ in XCTFail("Stale plan reached validator") })) {
                XCTAssertEqual($0 as? PortableSettingsError, .conflict)
            }
            XCTAssertEqual(domain(defaults, name), afterExternalEdit)
            let fresh = try store.prepareImport(data(changedDocument(defaults)))
            XCTAssertThrowsError(try PortableSettingsStore(defaults: defaults, persistentDomainName: name).apply(fresh)) {
                XCTAssertEqual($0 as? PortableSettingsError, .conflict)
            }
            XCTAssertEqual(domain(defaults, name), afterExternalEdit)
        }
    }

    func testValidatorSideEffectConflictAndReentrantApplyAreRejected() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            XCTAssertThrowsError(try store.apply(plan, validateHotkeys: { _ in
                XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .conflict) }
                defaults.set(10, forKey: ScreenshotPreferences.delayKey)
            })) { XCTAssertEqual($0 as? PortableSettingsError, .conflict) }
            XCTAssertEqual(domain(defaults, name), [ScreenshotPreferences.delayKey: 10] as NSDictionary)
        }
    }

    func testOrdinaryWriteFailureRollsBackEachPrefixIncludingPreviouslyAbsentKeys() throws {
        for failBefore in 0..<11 {
            try withDefaults { defaults, name in
                defaults.set("light", forKey: AppAppearancePreference.preferenceKey)
                let legacy = try JSONEncoder().encode([HotKeyAction.capture.defaultBinding!])
                defaults.set(legacy, forKey: HotKeyConfiguration.legacyPreferenceKey)
                defaults.set(Data([1, 2, 3]), forKey: "privateBookmark")
                let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
                let plan = try store.prepareImport(data(changedDocument(defaults)))
                let before = domain(defaults, name)
                store.beforeWrite = { index in if index == failBefore { throw InjectedFailure.write } }
                XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .applyFailed) }
                XCTAssertEqual(domain(defaults, name), before, "Partial mutation after failing at \(failBefore)")
                XCTAssertNil(defaults.object(forKey: HotKeyConfiguration.preferenceKey))
                XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.legacyPreferenceKey), legacy)
                store.beforeWrite = nil
                try store.apply(plan)
                XCTAssertEqual(AppAppearancePreference.read(from: defaults), .dark, "Rolled-back plan can be retried")
            }
        }
    }

    func testRollbackPreservesPersistentAbsenceAndExplicitValuesEqualToRegisteredDefaults() throws {
        for hadPersistedAppearance in [false, true] {
            try withDefaults { defaults, name in
                defaults.register(defaults: [AppAppearancePreference.preferenceKey: "system", ScreenshotPreferences.delayKey: 0])
                if hadPersistedAppearance { defaults.set("system", forKey: AppAppearancePreference.preferenceKey) }
                let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
                let plan = try store.prepareImport(data(changedDocument(defaults)))
                let before = domain(defaults, name)
                store.beforeWrite = { index in if index == 2 { throw InjectedFailure.write } }
                XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .applyFailed) }
                XCTAssertEqual(domain(defaults, name), before, "Rollback must restore persistent presence, not just effective values")
                XCTAssertEqual(defaults.string(forKey: AppAppearancePreference.preferenceKey), "system")
                XCTAssertEqual(defaults.integer(forKey: ScreenshotPreferences.delayKey), 0)
            }
        }
    }

    func testFailureAfterFinalWriteRestoresToolbarHotkeysAndAllPreferenceValues() throws {
        try withDefaults { defaults, name in
            defaults.set("light", forKey: AppAppearancePreference.preferenceKey)
            let originalOrder = AnnotationToolbarOrder.defaults
            originalOrder.write(to: defaults)
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            let before = domain(defaults, name)
            var finalWriteObserved = false
            store.afterWrite = { index in
                if index == 10 {
                    finalWriteObserved = true
                    XCTAssertNotEqual(AnnotationToolbarOrder.read(from: defaults), originalOrder)
                    XCTAssertEqual(HotKeyConfiguration.read(from: defaults), plan.hotKeyConfiguration)
                    throw InjectedFailure.write
                }
            }
            XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .applyFailed) }
            XCTAssertTrue(finalWriteObserved)
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testCustomStoreWithoutDomainIdentityCannotClaimTransactionalWrite() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            let before = domain(defaults, name)
            XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .unknownPersistenceDomain) }
            XCTAssertEqual(domain(defaults, name), before)
        }
    }

    func testMaterializingAnEqualFallbackAfterReviewStillConflicts() throws {
        try withDefaults { defaults, name in
            defaults.register(defaults: [AppAppearancePreference.preferenceKey: "system"])
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            defaults.set("system", forKey: AppAppearancePreference.preferenceKey)
            let afterExternalEdit = domain(defaults, name)
            XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .conflict) }
            XCTAssertEqual(domain(defaults, name), afterExternalEdit)
        }
    }

    func testConflictDuringCommitRollsBackOwnedWritesAndPreservesUnrelatedWriter() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            store.beforeWrite = { index in
                if index == 1 { defaults.set(120, forKey: "historyDays") }
            }
            XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .conflict) }
            XCTAssertEqual(domain(defaults, name), ["historyDays": 120] as NSDictionary)
        }
    }

    func testRollbackNeverOverwritesAnExternalReplacementOfAnAlreadyWrittenKey() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            store.beforeWrite = { index in
                if index == 2 { defaults.set("light", forKey: AppAppearancePreference.preferenceKey) }
            }
            XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .rollbackFailed) }
            XCTAssertEqual(domain(defaults, name), [AppAppearancePreference.preferenceKey: "light"] as NSDictionary)
            XCTAssertNil(defaults.object(forKey: ScreenshotPreferences.delayKey))
        }
    }

    func testUnrelatedPrivatePreferenceChangeDoesNotInvalidateReviewOrGetOverwritten() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let plan = try store.prepareImport(data(changedDocument(defaults)))
            defaults.set("new private history", forKey: "captureHistory")
            try store.apply(plan)
            XCTAssertEqual(defaults.string(forKey: "captureHistory"), "new private history")
        }
    }
}
