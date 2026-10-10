import AppKit
import Carbon
import PicShotCore
import XCTest
@testable import PicShot

@MainActor private final class SettingsTestApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}

@MainActor final class PortableSettingsUITests: XCTestCase {
    private func isolated(_ body: @escaping @MainActor (UserDefaults, String, Data) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "PicShot-PortableSettingsUITests-" + UUID().uuidString, donorSuite = suite + "-donor"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), donor = try XCTUnwrap(UserDefaults(suiteName: donorSuite))
        let appearance = NSApp.appearance
        defer { defaults.removePersistentDomain(forName: suite); donor.removePersistentDomain(forName: donorSuite); NSApp.appearance = appearance }
        AppAppearancePreference.dark.save(to: donor)
        ScreenshotPreferences.save(.init(delay: .threeSeconds, showsCursor: true), to: donor)
        var keys = HotKeyConfiguration.defaults
        keys[.capture] = .init(keyCode: 6, modifiers: UInt32(cmdKey | controlKey)); try keys.save(to: donor)
        let incoming = try PortableSettingsStore(defaults: donor, persistentDomainName: donorSuite).exportData()
        try withApplicationLoop { try body(defaults, suite, incoming) }
    }

    private func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        // Never stop or reconfigure an application loop owned by another host.
        if NSApp.isRunning { try body(); return }
        _ = try XCTUnwrap(NSApp.modalWindow == nil && NSApp.delegate == nil ? true : nil,
            "Standalone UI host unexpectedly has a modal window or application delegate")
        _ = try XCTUnwrap(UserDefaults.standard.object(forKey: "NSOpen") == nil ? true : nil,
            "Standalone UI host unexpectedly has a file-open request")
        let originalPolicy = NSApp.activationPolicy()
        recordHostState("before-preparation")
        let state = SettingsTestApplicationLoop()
        defer {
            state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
            if NSApp.activationPolicy() != originalPolicy { _ = NSApp.setActivationPolicy(originalPolicy) }
            XCTAssertEqual(NSApp.activationPolicy(), originalPolicy)
            recordHostState("policy-restored")
        }
        if originalPolicy == .prohibited {
            _ = try XCTUnwrap(NSApp.setActivationPolicy(.accessory) ? true : nil,
                "Native Settings interaction requires an activatable owned application")
        }
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0))
        func finish(_ result: Result<Void, Error>) {
            guard state.acceptsCallbacks, state.result == nil else { return }
            state.timer?.invalidate(); state.timer = nil; state.result = result
            NSApp.stop(nil); NSApp.postEvent(wake, atStart: true)
        }
        // A main-queue callback may already own XCTest's stack. Schedule on
        // the run loop so recursive main-queue draining is not required.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode) {
            MainActor.assumeIsolated {
                guard state.acceptsCallbacks else { return }
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard state.acceptsCallbacks, state.result == nil else { return }
                        if NSApp.isRunning && !state.activationRequested {
                            state.activationRequested = true
                            NSApp.activate(ignoringOtherApps: true)
                            self.recordHostState("owned-loop-started")
                        }
                        if NSApp.isRunning && NSApp.isActive {
                            state.timer?.invalidate(); state.timer = nil
                            self.recordHostState("body-admitted")
                            finish(Result { try body() })
                        } else if ProcessInfo.processInfo.systemUptime >= deadline {
                            self.recordHostState("host-readiness-failed")
                            finish(.failure(NSError(domain: "PicShot.SettingsUITestHost", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Owned application loop did not become active within one second"])))
                        }
                    }
                }
                state.timer = timer; RunLoop.main.add(timer, forMode: .default)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        NSApp.run()
        state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
        recordHostState("owned-loop-returned")
        XCTAssertFalse(NSApp.isRunning)
        try XCTUnwrap(state.result, "Owned application loop exited before its test body completed").get()
    }

    private func recordHostState(_ phase: String, window: NSWindow? = nil) {
        let observation: [String: Any] = ["phase": phase, "test": name,
            "applicationIsActive": NSApp.isActive,
            "applicationIsRunning": NSApp.isRunning, "activationPolicy": NSApp.activationPolicy().rawValue,
            "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? -1,
            "ownedWindowNumber": window?.windowNumber ?? -1, "ownedWindowIsKey": window?.isKeyWindow ?? false]
        if let data = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]) {
            print("PortableSettings native host: " + String(decoding: data, as: UTF8.self))
        }
    }

    private func readyWindow(_ controller: SettingsController, appearance: NSAppearance.Name) throws -> NSWindow {
        let window = try PortableSettingsUIPreviewFixture.show(controller, appearance: appearance)
        recordHostState("owned-window-ready", window: window)
        return window
    }

    func testNativeCancelPreservesSavedDomainAndExistingAnnotationDraft() throws {
        try isolated { defaults, suite, incoming in
            var changes = 0, validations = 0
            let controller = SettingsController(onChange: { changes += 1 }, defaults: defaults, isSmoke: false,
                validateImportedHotkeys: { _ in validations += 1 }, defaultsDomainName: suite)
            defer { controller.close() }
            let window = try self.readyWindow(controller, appearance: .aqua)
            try PortableSettingsUIPreviewFixture.select(.annotations, in: controller)
            let evidence = ProcessInfo.processInfo.environment["CI"] == "true"
                ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
                    .appendingPathComponent("dist/evidence/portable-settings-native-events", isDirectory: true) : nil
            try PortableSettingsUIPreviewFixture.clickRow(1, in: controller.annotationToolbarView.tableView,
                                                       failureEvidenceDirectory: evidence)
            try PortableSettingsUIPreviewFixture.click(controller.annotationToolbarView.moveDownButton)
            let draft = controller.annotationToolbarView.draft
            XCTAssertNotEqual(draft, .defaults)
            let saved = defaults.persistentDomain(forName: suite) ?? [:]
            try PortableSettingsUIPreviewFixture.select(.configuration, in: controller)
            let review = try controller.reviewPortableSettingsImport(incoming)
            XCTAssertTrue(review.plan.hasChanges); XCTAssertTrue(window.attachedSheet === review.window)
            XCTAssertEqual(validations, 0); XCTAssertEqual(changes, 0)
            XCTAssertTrue((saved as NSDictionary).isEqual(defaults.persistentDomain(forName: suite) ?? [:]))
            try PortableSettingsUIPreviewFixture.click(review.cancelButton)
            XCTAssertNil(controller.portableImportReview)
            XCTAssertEqual(controller.annotationToolbarView.draft, draft)
            XCTAssertTrue((saved as NSDictionary).isEqual(defaults.persistentDomain(forName: suite) ?? [:]))
            XCTAssertEqual(changes, 0)
        }
    }

    func testApplyCommitsExactlyOnceAndIgnoresRetainedClosedButton() throws {
        try isolated { defaults, suite, incoming in
            var changes = 0, validations = 0, writes = 0
            let controller = SettingsController(onChange: { changes += 1 }, defaults: defaults, isSmoke: false,
                validateImportedHotkeys: { _ in validations += 1 }, defaultsDomainName: suite)
            defer { controller.close() }
            let window = try self.readyWindow(controller, appearance: .aqua)
            let review = try controller.reviewPortableSettingsImport(incoming)
            controller.portableSettingsStore.beforeWrite = { _ in writes += 1 }
            try PortableSettingsUIPreviewFixture.click(review.applyButton)
            XCTAssertEqual(changes, 1); XCTAssertEqual(validations, 1); XCTAssertGreaterThan(writes, 1)
            XCTAssertFalse(window.isVisible); XCTAssertNil(controller.portableImportReview)
            XCTAssertEqual(try controller.portableSettingsStore.exportData(), incoming)
            let count = writes; review.applyButton.performClick(nil)
            XCTAssertEqual(changes, 1); XCTAssertEqual(validations, 1); XCTAssertEqual(writes, count)
        }
    }

    func testStaleOSConflictAndInjectedWriteFailureLeaveReviewAndRawDomainIntact() throws {
        for kind in ["stale", "os", "write"] {
            try isolated { defaults, suite, incoming in
                defaults.set("keep-unrelated", forKey: "unrelated")
                var changes = 0, attempts = 0
                let controller = SettingsController(onChange: { changes += 1 }, defaults: defaults, isSmoke: false,
                    validateImportedHotkeys: { _ in if kind == "os" { throw PortableSettingsError.conflict } }, defaultsDomainName: suite)
                defer { controller.close() }
                let window = try self.readyWindow(controller, appearance: .aqua)
                let review = try controller.reviewPortableSettingsImport(incoming)
                if kind == "stale" { defaults.set(5, forKey: ScreenshotPreferences.delayKey) }
                let before = defaults.persistentDomain(forName: suite) ?? [:]
                controller.portableSettingsStore.beforeWrite = { index in
                    attempts += 1
                    if kind == "write" && index == 1 { throw PortableSettingsError.applyFailed }
                }
                try PortableSettingsUIPreviewFixture.click(review.applyButton)
                XCTAssertTrue((before as NSDictionary).isEqual(defaults.persistentDomain(forName: suite) ?? [:]), kind)
                XCTAssertEqual(changes, 0); XCTAssertTrue(controller.portableImportReview === review)
                XCTAssertTrue(window.isVisible); XCTAssertFalse(review.errorLabel.stringValue.isEmpty)
                XCTAssertEqual(attempts, kind == "write" ? 2 : 0)
            }
        }
    }

    func testMalformedImportNeverAttachesAndParentCloseDismissesValidReview() throws {
        try isolated { defaults, suite, incoming in
            let controller = SettingsController(onChange: { XCTFail("Closing must not apply") }, defaults: defaults, isSmoke: false, defaultsDomainName: suite)
            defer { controller.close() }
            let window = try self.readyWindow(controller, appearance: .aqua)
            XCTAssertThrowsError(try controller.reviewPortableSettingsImport(Data("{}".utf8)))
            XCTAssertNil(controller.portableImportReview); XCTAssertNil(window.attachedSheet)
            let review = try controller.reviewPortableSettingsImport(incoming)
            XCTAssertTrue(window.attachedSheet === review.window)
            controller.close(); XCTAssertNil(controller.portableImportReview)
            XCTAssertFalse(review.window?.isVisible ?? true)
            XCTAssertNil(review.window?.sheetParent)
        }
    }

    func testExportUsesSavedValuesAndFileReadbackDoesNotPersistDraft() throws {
        try isolated { defaults, suite, _ in
            let root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-Portable-FileTest-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let controller = SettingsController(onChange: {}, defaults: defaults, isSmoke: false, defaultsDomainName: suite)
            defer { controller.close() }
            var order = AnnotationToolbarOrder.defaults; order.move(.ellipse, by: 1)
            controller.annotationToolbarView.apply(order: order)
            let url = root.appendingPathComponent("settings.json")
            try controller.exportPortableSettings(to: url)
            let bytes = try PortableSettingsStore.readImportData(from: url)
            XCTAssertEqual(bytes, try controller.portableSettingsStore.exportData())
            XCTAssertFalse(try controller.portableSettingsStore.prepareImport(bytes).hasChanges)
            XCTAssertEqual(AnnotationToolbarOrder.read(from: defaults), .defaults)
            XCTAssertLessThanOrEqual(bytes.count, PortableSettingsStore.maximumFileBytes)
        }
    }

    func testFullVisibleFramesAndReadableControlsInLightAndDark() throws {
        try isolated { defaults, suite, incoming in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let controller = SettingsController(onChange: {}, defaults: defaults, isSmoke: false, defaultsDomainName: suite)
                defer { controller.close() }
                let window = try self.readyWindow(controller, appearance: appearance)
                for category in [SettingsCategory.annotations, .configuration] {
                    try PortableSettingsUIPreviewFixture.select(category, in: controller)
                    XCTAssertEqual(try PortableSettingsUIPreviewFixture.layout(window)["fullVisibleFramesChecked"] as? Bool, true)
                }
                let review = try controller.reviewPortableSettingsImport(incoming)
                review.window?.appearance = NSAppearance(named: appearance)
                let opening = try PortableSettingsUIPreviewFixture.reviewOpeningLayout(review)
                XCTAssertEqual(opening["checkMoment"] as? String, "immediately-after-opening-before-any-scroll")
                XCTAssertEqual((opening["firstChangeLabels"] as? [[String: Any]])?.count, 3)
                XCTAssertEqual(try PortableSettingsUIPreviewFixture.layout(XCTUnwrap(review.window))["controlsDoNotOverlap"] as? Bool, true)
                review.cancel()
            }
        }
    }
}
