import XCTest
import AppKit
import Carbon
import PicShotCore
@testable import PicShot

final class SettingsAndMenuTests: XCTestCase {
    private func preferences() -> (UserDefaults, String) {
        let name = "PicShot-SettingsAndMenuTests-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    func testNewDefaultsUseControlOneTwoAndRestoreThreeWhileHistoryStaysSeparate() {
        let config = HotKeyConfiguration.defaults
        XCTAssertEqual(config[.capture], HotKeyBinding(keyCode: 18, modifiers: UInt32(controlKey)))
        XCTAssertEqual(config[.clipboardPin], HotKeyBinding(keyCode: 19, modifiers: UInt32(controlKey)))
        XCTAssertEqual(config[.restoreLastPin], HotKeyBinding(keyCode: 20, modifiers: UInt32(controlKey)))
        XCTAssertEqual(config[.history], HotKeyBinding(keyCode: 4, modifiers: UInt32(cmdKey | controlKey)))
        XCTAssertNil(config.validationMessage)
    }
    func testLegacyCustomBindingsKeepTheirActionsAndAreNotOverwrittenOnRead() throws {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let legacy = [HotKeyBinding(keyCode: 0, modifiers: UInt32(cmdKey | controlKey)), HotKeyBinding(keyCode: 35, modifiers: UInt32(cmdKey | controlKey)), HotKeyBinding(keyCode: 4, modifiers: UInt32(cmdKey | controlKey))]
        let data = try JSONEncoder().encode(legacy); defaults.set(data, forKey: HotKeyConfiguration.legacyPreferenceKey)
        let config = HotKeyConfiguration.read(from: defaults)
        XCTAssertEqual(config[.capture], legacy[0]); XCTAssertEqual(config[.clipboardPin], legacy[1]); XCTAssertEqual(config[.history], legacy[2])
        XCTAssertEqual(config[.restoreLastPin], HotKeyAction.restoreLastPin.defaultBinding)
        XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.legacyPreferenceKey), data)
        XCTAssertNil(defaults.object(forKey: HotKeyConfiguration.preferenceKey))
    }
    func testLegacyControlThreeForHistoryIsNeverReassignedToRestore() throws {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let legacy = [HotKeyAction.capture.defaultBinding, HotKeyAction.clipboardPin.defaultBinding, HotKeyAction.restoreLastPin.defaultBinding]
        defaults.set(try JSONEncoder().encode(legacy), forKey: HotKeyConfiguration.legacyPreferenceKey)
        let config = HotKeyConfiguration.read(from: defaults)
        XCTAssertEqual(config[.history], legacy[2]); XCTAssertNil(config[.restoreLastPin]); XCTAssertNil(config.validationMessage)
    }
    func testPartialLegacyAndClearedActionsAreSafeAndRemainUnassigned() throws {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode([HotKeyAction.capture.defaultBinding]), forKey: HotKeyConfiguration.legacyPreferenceKey)
        var config = HotKeyConfiguration.read(from: defaults)
        XCTAssertNil(config[.clipboardPin]); XCTAssertNil(config[.history])
        config[.restoreLastPin] = nil; try config.save(to: defaults)
        XCTAssertEqual(HotKeyConfiguration.read(from: defaults), config)
    }
    func testShortcutValidationRejectsDuplicatesAndNoModifierBeforeWriting() throws {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        var config = HotKeyConfiguration.defaults; try config.save(to: defaults)
        let data = defaults.data(forKey: HotKeyConfiguration.preferenceKey)
        config[.capture] = config[.clipboardPin]; XCTAssertNotNil(config.validationMessage); XCTAssertThrowsError(try config.save(to: defaults))
        XCTAssertEqual(defaults.data(forKey: HotKeyConfiguration.preferenceKey), data)
        config = .defaults; config[.capture] = HotKeyBinding(keyCode: 18, modifiers: UInt32(shiftKey))
        XCTAssertNotNil(config.validationMessage)
        config[.capture] = HotKeyBinding(keyCode: 999, modifiers: UInt32(cmdKey)); XCTAssertNotNil(config.validationMessage)
    }
    func testShortcutDisplayAndNativeMenuModifiersAgree() {
        let key = HotKeyBinding(keyCode: 18, modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(key.displayName, "⌃⌥⇧⌘1"); XCTAssertEqual(key.keyEquivalent, "1")
        XCTAssertEqual(key.keyEquivalentModifiers, [.control, .option, .shift, .command])
    }
    func testMenuGroupsExposeEveryCommandOnceAndKeepHistorySeparateFromRestore() {
        let commands = StatusMenuLayout.groups.flatMap { $0 }
        XCTAssertEqual(Set(commands), Set(StatusMenuCommand.allCases)); XCTAssertEqual(commands.count, Set(commands).count)
        XCTAssertEqual(StatusMenuLayout.groups[1], [.clipboardPin, .restoreLastPin, .morePins])
        XCTAssertEqual(StatusMenuCommand.restoreLastPin.hotKeyAction, .restoreLastPin)
        XCTAssertEqual(StatusMenuCommand.history.hotKeyAction, .history)
        XCTAssertEqual(StatusMenuLayout.groups[2], [.pinGroups])
    }
    @MainActor func testSettingsSidebarSupportsEveryWiredCategoryAndSmokeDoesNotReadAppearance() throws {
        _ = NSApplication.shared
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: AppAppearancePreference.preferenceKey)
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        AppAppearancePreference.applySaved(isSmoke: false, defaults: defaults)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        defaults.set("light", forKey: AppAppearancePreference.preferenceKey)
        AppAppearancePreference.applySaved(isSmoke: true, defaults: defaults)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        let controller = SettingsController(onChange: {}, defaults: defaults, isSmoke: true)
        defer { controller.close() }
        XCTAssertEqual(controller.window?.contentView?.frame.width, 800)
        XCTAssertEqual(SettingsCategory.allCases.count, 6)
        for category in SettingsCategory.allCases {
            controller.selectCategory(category); controller.window?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.selectedCategory, category)
        }
        XCTAssertEqual(AppAppearancePreference.read(from: defaults), .light)
    }
}
