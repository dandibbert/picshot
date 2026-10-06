import AppKit
import PicShotCore

enum StatusMenuCommand: String, CaseIterable {
    case capture, moreCapture, scroll, record, recoverRecordings, cancelCapture
    case clipboardPin, restoreLastPin, morePins, pinGroups, history, settings, quit
    var title: String {
        switch self {
        case .capture: return "区域截图"
        case .moreCapture: return "更多截图"
        case .scroll: return "滚动长截图…"
        case .record: return "录屏…"
        case .recoverRecordings: return "恢复未完成的录屏…"
        case .cancelCapture: return "取消当前截图"
        case .clipboardPin: return "剪贴板贴图"
        case .restoreLastPin: return "恢复上次关闭的贴图"
        case .morePins: return "其他贴图"
        case .pinGroups: return "贴图组"
        case .history: return "历史记录"
        case .settings: return "设置…"
        case .quit: return "退出 PicShot"
        }
    }
    var symbol: String? {
        switch self {
        case .capture: return "viewfinder"
        case .clipboardPin: return "pin"
        case .restoreLastPin: return "arrow.uturn.backward"
        case .pinGroups: return "square.stack"
        case .history: return "clock"
        case .settings: return "gearshape"
        default: return nil
        }
    }
    var hotKeyAction: HotKeyAction? {
        switch self { case .capture: return .capture; case .clipboardPin: return .clipboardPin; case .restoreLastPin: return .restoreLastPin; case .history: return .history; default: return nil }
    }
}

enum StatusMenuLayout {
    static let groups: [[StatusMenuCommand]] = [
        [.capture, .moreCapture, .scroll, .record, .recoverRecordings, .cancelCapture],
        [.clipboardPin, .restoreLastPin, .morePins],
        [.pinGroups], [.history, .settings], [.quit]
    ]
}

@MainActor extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === status?.menu { rebuildStatusMenu(menu) }
    }
    func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems(); menu.autoenablesItems = false
        let keys = HotKeyConfiguration.read()
        for (index, group) in StatusMenuLayout.groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in group {
                let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
                item.target = self; item.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
                if let symbol = command.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                if let action = command.hotKeyAction, let binding = keys[action] {
                    item.keyEquivalent = binding.keyEquivalent; item.keyEquivalentModifierMask = binding.keyEquivalentModifiers
                    // Unknown physical keys remain visible without inventing an equivalent character.
                    if item.keyEquivalent.isEmpty { item.title += "  " + binding.displayName }
                }
                switch command {
                case .capture: item.action = #selector(region)
                case .moreCapture: item.submenu = additionalCaptureMenu()
                case .scroll: item.action = #selector(scroll)
                case .record: item.action = #selector(record)
                case .recoverRecordings: item.action = #selector(recoverRecordings)
                case .cancelCapture: item.action = #selector(cancelCapture); item.isEnabled = busy
                case .clipboardPin: item.action = #selector(pastePin)
                case .restoreLastPin: item.action = #selector(restoreLastClosedPin); item.isEnabled = pinSession?.store.index.lastArchivedEntry != nil
                case .morePins:
                    let sub = NSMenu(title: command.title)
                    for (title, action) in [("文件或文件夹贴图…", #selector(importFilePin)), ("动态 GIF / WebP 贴图…", #selector(importAnimationPin)), ("颜色贴图…", #selector(createColorPin))] { sub.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
                    item.submenu = sub
                case .pinGroups: item.submenu = pinGroupsMenu()
                case .history: item.action = #selector(showMain)
                case .settings: item.action = #selector(settings)
                case .quit: item.action = #selector(NSApplication.terminate(_:)); item.target = NSApp; item.keyEquivalent = "q"; item.keyEquivalentModifierMask = .command
                }
                menu.addItem(item)
                if command == .settings, let failures = hotKeys?.failures, !failures.isEmpty {
                    let warning = menu.addItem(withTitle: "快捷键不可用：" + failures.map(\.title).joined(separator: "、"), action: #selector(settings), keyEquivalent: "")
                    warning.target = self; warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                }
            }
        }
    }
    func additionalCaptureMenu() -> NSMenu {
        let menu = NSMenu(title: "更多截图")
        for (title, action) in [("跨屏区域截图（系统选区）", #selector(systemRegion)), ("窗口截图", #selector(windowCapture)), ("当前屏幕", #selector(full)), ("所有屏幕合成", #selector(allScreens))] { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        menu.addItem(.separator())
        for (title, action) in [("多选区域（可减选）", #selector(multiRegionCapture)), ("多边形选区", #selector(polygonCapture)), ("自由形状选区", #selector(freehandCapture))] { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        return menu
    }
    private func pinGroupsMenu() -> NSMenu {
        let menu = NSMenu(title: "贴图组"); menu.autoenablesItems = false
        if let pinSession {
            let label = NSMenuItem(title: "贴图组 · 显示 / 历史", action: nil, keyEquivalent: ""); label.isEnabled = false; menu.addItem(label)
            for group in PinGroupMenuSummary.make(index: pinSession.store.index, livePinIDs: pinSession.livePinIDs) {
                let item = NSMenuItem(title: "\(group.name)    \(group.countLabel)", action: #selector(selectPinGroup(_:)), keyEquivalent: "")
                item.state = group.isCurrent ? .on : .off; item.target = self; item.representedObject = group.id.uuidString
                item.image = groupColorImage(group.color); menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let manage = menu.addItem(withTitle: "管理贴图组与历史…", action: #selector(managePinGroups), keyEquivalent: ""); manage.target = self; manage.isEnabled = pinSession != nil
        menu.addItem(.separator())
        for (title, action) in [("显示当前贴图组", #selector(showPins)), ("恢复当前贴图组（位置、透明度与鼠标）", #selector(restorePins)), ("隐藏当前贴图组", #selector(hideCurrentPins)), ("隐藏所有贴图", #selector(hidePins))] { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        return menu
    }
    private func groupColorImage(_ color: PinGroupColor) -> NSImage {
        let fill: NSColor
        switch color { case .gray: fill = .systemGray; case .blue: fill = .systemBlue; case .green: fill = .systemGreen; case .orange: fill = .systemOrange; case .purple: fill = .systemPurple; case .red: fill = .systemRed }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            fill.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill(); return true
        }
        image.isTemplate = false; return image
    }
    @objc func selectPinGroup(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String, let id = UUID(uuidString: string) else { return }
        do { try pinSession?.switchGroup(id: id) } catch { showError(error) }
    }
    @objc func restoreLastClosedPin() {
        do { if try pinSession?.restoreLastClosedPin() == nil { NSSound.beep() } } catch { showError(error) }
    }
    @objc func multiRegionCapture() { startAdvanced(.multiRegion) }
    @objc func polygonCapture() { startAdvanced(.polygon) }
    @objc func freehandCapture() { startAdvanced(.freehand) }
}
