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

    @MainActor func testRecordingShortcutButtonsCaptureCancelRemapClearAndSave() throws {
        _ = NSApplication.shared
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let originalAppearance = NSApp.appearance; defer { NSApp.appearance = originalAppearance }
        var changes = 0
        let controller = SettingsController(onChange: { changes += 1 }, defaults: defaults, isSmoke: false)
        defer { controller.close() }
        controller.selectCategory(.shortcuts)
        let window = try XCTUnwrap(controller.window)
        let views = descendants(try XCTUnwrap(window.contentView))
        let pause = try XCTUnwrap(views.first { $0.identifier?.rawValue == "settings.shortcut.4" } as? ShortcutButton)
        let stop = try XCTUnwrap(views.first { $0.identifier?.rawValue == "settings.shortcut.5" } as? ShortcutButton)
        XCTAssertNil(pause.binding); XCTAssertNil(stop.binding)
        XCTAssertEqual(views.compactMap { $0 as? ShortcutButton }.count, 6)

        func press(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
        }
        pause.performClick(nil); XCTAssertTrue(pause.listening)
        try press(35, characters: "p", modifiers: [.command, .control])
        let first = HotKeyBinding(keyCode: 35, modifiers: UInt32(cmdKey | controlKey))
        XCTAssertEqual(pause.binding, first); XCTAssertFalse(pause.listening)
        pause.performClick(nil); try press(53, characters: "\u{1b}", modifiers: [])
        XCTAssertEqual(pause.binding, first); XCTAssertFalse(pause.listening)
        pause.performClick(nil); try press(7, characters: "x", modifiers: [.command, .option])
        let remapped = HotKeyBinding(keyCode: 7, modifiers: UInt32(cmdKey | optionKey))
        XCTAssertEqual(pause.binding, remapped)
        stop.performClick(nil); try press(1, characters: "s", modifiers: [.command, .control])
        let clearStop = try XCTUnwrap(views.first { $0.identifier?.rawValue == "settings.shortcut.clear.5" } as? NSButton)
        clearStop.performClick(nil); XCTAssertNil(stop.binding)
        XCTAssertNil(defaults.data(forKey: HotKeyConfiguration.preferenceKey), "Draft edits must not persist before Save")
        let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存设置" })
        save.performClick(nil)
        XCTAssertEqual(changes, 1)
        let saved = HotKeyConfiguration.read(from: defaults)
        XCTAssertEqual(saved[.recordingPauseResume], remapped); XCTAssertNil(saved[.recordingStopSave])
        for action in [HotKeyAction.capture, .clipboardPin, .history, .restoreLastPin] {
            XCTAssertEqual(saved[action], HotKeyConfiguration.defaults[action])
        }
    }

    @MainActor func testSixShortcutRowsAndUnavailableHelpFitSettingsInLightAndDark() throws {
        _ = NSApplication.shared
        let controller = SettingsController(onChange: {}, isSmoke: true, unavailableShortcuts: HotKeyAction.allCases)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            controller.selectCategory(.shortcuts); root.layoutSubtreeIfNeeded()
            let views = descendants(root)
            let shortcuts = views.compactMap { $0 as? ShortcutButton }
            XCTAssertEqual(shortcuts.count, 6)
            let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存设置" })
            let saveFrame = root.convert(save.bounds, from: save)
            for button in shortcuts {
                let frame = root.convert(button.bounds, from: button)
                XCTAssertTrue(root.bounds.contains(frame), "Shortcut is clipped: \(button.identifier?.rawValue ?? "unknown")")
                XCTAssertGreaterThan(frame.minY, saveFrame.maxY)
                XCTAssertGreaterThanOrEqual(frame.height, 20)
            }
            let help = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("当前不可用，请更换") })
            let helpFrame = root.convert(help.bounds, from: help)
            XCTAssertTrue(root.bounds.contains(helpFrame))
            XCTAssertGreaterThan(helpFrame.minY, saveFrame.maxY)
        }
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
