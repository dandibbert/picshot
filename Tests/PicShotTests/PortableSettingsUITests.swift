import AppKit
import Carbon
import PicShotCore
import XCTest
@testable import PicShot

@MainActor final class PortableSettingsUITests: XCTestCase {
    private func isolated(_ body: (UserDefaults, String, Data) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "PicShot-PortableSettingsUITests-" + UUID().uuidString, donorSuite = suite + "-donor"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), donor = try XCTUnwrap(UserDefaults(suiteName: donorSuite))
        let appearance = NSApp.appearance
        defer { defaults.removePersistentDomain(forName: suite); donor.removePersistentDomain(forName: donorSuite); NSApp.appearance = appearance }
        AppAppearancePreference.dark.save(to: donor)
        ScreenshotPreferences.save(.init(delay: .threeSeconds, showsCursor: true), to: donor)
        var keys = HotKeyConfiguration.defaults
        keys[.capture] = .init(keyCode: 6, modifiers: UInt32(cmdKey | controlKey)); try keys.save(to: donor)
        try body(defaults, suite, PortableSettingsStore(defaults: donor, persistentDomainName: donorSuite).exportData())
    }

    func testNativeCancelPreservesSavedDomainAndExistingAnnotationDraft() throws {
        try isolated { defaults, suite, incoming in
            var changes = 0, validations = 0
            let controller = SettingsController(onChange: { changes += 1 }, defaults: defaults, isSmoke: false,
                validateImportedHotkeys: { _ in validations += 1 }, defaultsDomainName: suite)
            defer { controller.close() }
            let window = try PortableSettingsUIPreviewFixture.show(controller, appearance: .aqua)
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
            let window = try PortableSettingsUIPreviewFixture.show(controller, appearance: .aqua)
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
                let window = try PortableSettingsUIPreviewFixture.show(controller, appearance: .aqua)
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
            let window = try PortableSettingsUIPreviewFixture.show(controller, appearance: .aqua)
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
                let window = try PortableSettingsUIPreviewFixture.show(controller, appearance: appearance)
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
