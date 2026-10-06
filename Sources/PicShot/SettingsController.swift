import AppKit
import Carbon
import PicShotCore

@MainActor final class SettingsController: NSWindowController {
    private let change: () -> Void
    private let defaults: UserDefaults
    private let savesPreferences: Bool
    private var shortcuts: HotKeyConfiguration
    private let unavailableShortcuts: [HotKeyAction]
    private let heading = NSTextField(labelWithString: "")
    private let content = NSStackView()
    private var categoryButtons: [SettingsCategory: SettingsSidebarButton] = [:]
    private var shortcutButtons: [HotKeyAction: ShortcutButton] = [:]
    private var retentionFields: [NSTextField] = []
    private let appearance = NSPopUpButton(frame: .zero, pullsDown: false)
    private let screenshotDelay = NSPopUpButton(frame: .zero, pullsDown: false)
    private let screenshotCursor = NSButton(checkboxWithTitle: "屏幕截图包含鼠标指针", target: nil, action: nil)
    private let restorePins = NSButton(checkboxWithTitle: "启动时恢复上次显示的贴图组", target: nil, action: nil)
    private(set) var selectedCategory: SettingsCategory = .appearance

    init(onChange: @escaping () -> Void, defaults: UserDefaults = .standard, isSmoke: Bool? = nil, unavailableShortcuts: [HotKeyAction] = []) {
        let safeMode = isSmoke ?? (ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] != nil)
        change = onChange; self.defaults = defaults; savesPreferences = !safeMode; self.unavailableShortcuts = unavailableShortcuts
        shortcuts = safeMode ? .defaults : HotKeyConfiguration.read(from: defaults)
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "PicShot 设置"; window.isReleasedWhenClosed = false; window.center()
        window.identifier = NSUserInterfaceItemIdentifier("picshot.settings")
        configureValues(safeMode: safeMode)
        buildLayout(in: window)
        selectCategory(.appearance)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configureValues(safeMode: Bool) {
        appearance.addItems(withTitles: AppAppearancePreference.allCases.map(\.title))
        let currentAppearance = safeMode ? AppAppearancePreference.system : .read(from: defaults)
        appearance.selectItem(at: AppAppearancePreference.allCases.firstIndex(of: currentAppearance) ?? 0)
        let options = safeMode ? ScreenshotCaptureOptions() : ScreenshotPreferences.read(from: defaults)
        screenshotDelay.addItems(withTitles: ["无延时", "3 秒", "5 秒", "10 秒"])
        for (index, delay) in ScreenshotDelay.allCases.enumerated() { screenshotDelay.item(at: index)?.tag = delay.rawValue }
        screenshotDelay.selectItem(withTag: options.delay.rawValue); screenshotCursor.state = options.showsCursor ? .on : .off
        restorePins.state = !safeMode && defaults.bool(forKey: PinSessionStore.restorePreferenceKey) ? .on : .off
        let retention = safeMode ? HistoryRetentionPreferences() : .read(from: defaults)
        for value in [retention.days, retention.count, retention.megabytes] {
            let field = NSTextField(string: String(value)); field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 110).isActive = true
            retentionFields.append(field)
        }
        for action in HotKeyAction.settingsOrder {
            let button = ShortcutButton(binding: shortcuts[action]); button.widthAnchor.constraint(equalToConstant: 210).isActive = true
            button.onChange = { [weak self] binding in self?.shortcuts[action] = binding }
            button.setAccessibilityLabel(action.title + "快捷键")
            shortcutButtons[action] = button
        }
    }

    private func buildLayout(in window: NSWindow) {
        guard let root = window.contentView else { return }
        let sidebar = NSVisualEffectView(); sidebar.material = .sidebar; sidebar.blendingMode = .withinWindow; sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sidebar)
        let sidebarStack = NSStackView(); sidebarStack.orientation = .vertical; sidebarStack.alignment = .leading; sidebarStack.spacing = 6
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(sidebarStack)
        for (index, category) in SettingsCategory.allCases.enumerated() {
            let button = SettingsSidebarButton(category: category); button.tag = index; button.target = self; button.action = #selector(selectSidebar(_:))
            sidebarStack.addArrangedSubview(button); button.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
            categoryButtons[category] = button
        }
        let branding = NSTextField(labelWithString: "PicShot"); branding.font = .systemFont(ofSize: 11, weight: .medium); branding.textColor = .tertiaryLabelColor
        branding.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(branding)
        let divider = NSBox(); divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(divider)
        heading.font = .systemFont(ofSize: 21, weight: .medium); heading.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(heading)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 16; content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        let footerLine = NSBox(); footerLine.boxType = .separator; footerLine.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footerLine)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSettings)); cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings)); save.keyEquivalent = "\r"
        let footer = NSStackView(views: [cancel, save]); footer.spacing = 10; footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        let footnote = NSTextField(labelWithString: "更改在保存后生效"); footnote.font = .systemFont(ofSize: 11); footnote.textColor = .secondaryLabelColor
        footnote.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footnote)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 160),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22), sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10), sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            branding.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20), branding.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1), divider.topAnchor.constraint(equalTo: root.topAnchor), divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            heading.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 26), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: heading.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 22), content.bottomAnchor.constraint(lessThanOrEqualTo: footerLine.topAnchor, constant: -20),
            footerLine.leadingAnchor.constraint(equalTo: heading.leadingAnchor), footerLine.trailingAnchor.constraint(equalTo: content.trailingAnchor), footerLine.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -62),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            footnote.leadingAnchor.constraint(equalTo: heading.leadingAnchor), footnote.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
    }

    @objc private func selectSidebar(_ sender: NSButton) {
        guard SettingsCategory.allCases.indices.contains(sender.tag) else { return }
        selectCategory(SettingsCategory.allCases[sender.tag])
    }
    func selectCategory(_ category: SettingsCategory) {
        window?.makeFirstResponder(nil)
        selectedCategory = category; heading.stringValue = category.title
        for (key, button) in categoryButtons { button.isCurrent = key == category }
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        switch category {
        case .appearance:
            addGroup("界面主题", rows: [row("颜色模式", control: appearance)])
            addNote("跟随系统会自动匹配 macOS 的浅色或深色外观。主题应用于设置、历史记录及其他使用系统外观的窗口。")
        case .capture:
            addGroup("截图选项", rows: [row("开始截图前延时", control: screenshotDelay), screenshotCursor])
            addNote("鼠标指针选项用于单屏和全部屏幕截图。区域截图使用冻结画面选区；窗口和跨屏区域截图使用系统选择器。")
            addGroup("多屏合成", rows: [note("全部屏幕按最高像素密度合成，低密度屏幕会放大，屏幕间隙透明。最多 6400 万像素；屏幕依次采集，并非同一瞬间。")])
        case .pins:
            addGroup("启动与会话", rows: [restorePins, note("默认关闭。贴图自动保存在本机；关闭贴图会将它归档，隐藏和切换贴图组保留会话状态。")])
            addGroup("贴图历史", rows: [note("恢复上次关闭的贴图会按实际关闭顺序重新打开。已有的旧版归档项仍可在“贴图组与历史”中选择打开。")])
            addNote("含归档最多保存 20 项、1 亿工作像素、512 MiB；最多同时显示 20 项。恢复当前组还可找回鼠标穿透、低透明度或屏幕外的贴图。")
        case .history:
            addGroup("历史保留上限", rows: [row("最多天数", control: retentionFields[0], suffix: "天"), row("最多截图", control: retentionFields[1], suffix: "张"), row("最大磁盘空间", control: retentionFields[2], suffix: "MB")])
            addNote("保存后按上限清理未收藏的截图。收藏不会自动删除，但仍计入限额；收藏占满空间时会停止添加新历史。")
            addGroup("存储说明", rows: [note("录屏原文件保存在“电影 / PicShot”，不计入截图历史。贴图会话拥有独立的本机存储与上限。")])
        case .shortcuts:
            var rows: [NSView] = []
            for action in HotKeyAction.settingsOrder {
                guard let button = shortcutButtons[action] else { continue }
                let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "清除快捷键") ?? NSImage(), target: self, action: #selector(clearShortcut(_:)))
                clear.tag = action.rawValue; clear.isBordered = false; clear.contentTintColor = .secondaryLabelColor
                clear.toolTip = "清除“\(action.title)”的快捷键"; clear.widthAnchor.constraint(equalToConstant: 24).isActive = true
                let pair = NSStackView(views: [button, clear]); pair.spacing = 8
                rows.append(row(action.title, control: pair))
            }
            addGroup("全局快捷键", rows: rows)
            if !unavailableShortcuts.isEmpty { addNote("以下快捷键当前不可用，请更换组合键：" + unavailableShortcuts.map(\.title).joined(separator: "、")) }
            addNote("点击后按组合键；至少包含 ⌘、⌃ 或 ⌥。Esc 取消录入。已有自定义键保持原来的操作含义。设置窗口打开期间暂停全局快捷键，关闭后恢复。")
        }
    }

    private func row(_ title: String, control: NSView, suffix: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 166).isActive = true
        let row = NSStackView(views: [label, control]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        if let suffix { let units = NSTextField(labelWithString: suffix); units.textColor = .secondaryLabelColor; row.addArrangedSubview(units) }
        return row
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func addNote(_ text: String) {
        let label = note(text); content.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    private func addGroup(_ title: String, rows: [NSView]) {
        let group = SettingsCardView(frame: .zero); group.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title); titleLabel.font = .systemFont(ofSize: 13, weight: .semibold); stack.addArrangedSubview(titleLabel)
        for (index, row) in rows.enumerated() {
            if index > 0 { let line = NSBox(); line.boxType = .separator; stack.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            stack.addArrangedSubview(row)
            if let label = row as? NSTextField, label.cell?.wraps == true { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        group.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: group.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -14)])
        content.addArrangedSubview(group); group.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    @objc private func clearShortcut(_ sender: NSButton) {
        guard let action = HotKeyAction(rawValue: sender.tag) else { return }
        shortcuts[action] = nil; shortcutButtons[action]?.setBinding(nil)
    }
    @objc private func cancelSettings() { close() }
    @objc private func saveSettings() {
        window?.makeFirstResponder(nil)
        let values = retentionFields.compactMap { Int($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 3 else { selectCategory(.history); showError(PicShotError.message("请填写有效的整数。")); return }
        let retention = HistoryRetentionPreferences(days: values[0], count: values[1], megabytes: values[2])
        guard retention.isValid else { selectCategory(.history); showError(PicShotError.message("请填写有效的正数（最多 3650 天、10000 张、102400 MB）。")); return }
        if let error = shortcuts.validationMessage { selectCategory(.shortcuts); showError(PicShotError.message(error)); return }
        // Rendering/test modes can inspect every panel without changing the user's preferences.
        guard savesPreferences else { close(); return }
        do { try shortcuts.save(to: defaults) } catch { showError(error); return }
        _ = retention.save(to: defaults)
        ScreenshotPreferences.save(ScreenshotCaptureOptions(delay: ScreenshotDelay(rawValue: screenshotDelay.selectedTag()) ?? .none, showsCursor: screenshotCursor.state == .on), to: defaults)
        defaults.set(restorePins.state == .on, forKey: PinSessionStore.restorePreferenceKey)
        let choice = AppAppearancePreference.allCases[max(0, appearance.indexOfSelectedItem)]
        choice.save(to: defaults); NSApp.appearance = choice.appKitAppearance
        change(); close()
    }
}

@MainActor final class ShortcutButton: NSButton {
    private(set) var binding: HotKeyBinding?
    var onChange: ((HotKeyBinding?) -> Void)?
    private(set) var listening = false
    init(binding: HotKeyBinding?) {
        self.binding = binding; super.init(frame: .zero)
        target = self; action = #selector(begin); bezelStyle = .rounded; updateTitle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    func setBinding(_ value: HotKeyBinding?) { binding = value; listening = false; updateTitle() }
    @objc private func begin() { listening = true; title = "按组合键…"; window?.makeFirstResponder(self) }
    override func resignFirstResponder() -> Bool { listening = false; updateTitle(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard listening else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard listening else { super.keyDown(with: event); return }
        if event.keyCode == 53 { listening = false; updateTitle(); return }
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }; if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }; if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        binding = HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers); listening = false; onChange?(binding); updateTitle()
    }
    private func updateTitle() { title = binding?.displayName ?? "点击设置快捷键" }
}

/// Give shortcut recording first refusal before Escape, Return, or menu equivalents.
@MainActor private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let button = firstResponder as? ShortcutButton, button.listening {
            button.keyDown(with: event); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
