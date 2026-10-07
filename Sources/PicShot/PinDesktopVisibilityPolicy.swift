import AppKit
import PicShotCore

extension PinDesktopVisibility {
    var title: String { self == .allDesktops ? "所有桌面" : "当前桌面" }
    static let explanation = "应用于所有贴图。当前模式仅在窗口所在桌面显示，不主动搬移已有贴图；激活可能切回该桌面。位置由 macOS 管理，重启不恢复原桌面。"
}

/// Collection behaviors are public AppKit preferences, never proof of physical
/// Mission Control placement. No Space IDs, polling, windows or pixels are retained.
@MainActor enum PinDesktopVisibilityPolicy {
    static func behavior(_ mode: PinDesktopVisibility, preserving original: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var result = original
        result.remove([.canJoinAllSpaces, .moveToActiveSpace])
        if mode == .allDesktops { result.insert(.canJoinAllSpaces) }
        // The zero-valued default is one assigned Space, without activation-follow.
        return result
    }

    /// Mutate only Space participation; retain fullscreen, cycling, level, alpha,
    /// frame, focus, click-through and document state. Do not order/activate a window.
    static func apply(_ mode: PinDesktopVisibility, to window: NSWindow?) {
        guard let window else { return }
        window.collectionBehavior = behavior(mode, preserving: window.collectionBehavior)
        for child in window.childWindows ?? [] { apply(mode, to: child) }
        if let sheet = window.attachedSheet, !(window.childWindows ?? []).contains(where: { $0 === sheet }) {
            apply(mode, to: sheet)
        }
    }

    /// An export created after its parent was configured must inherit the same scope
    /// before being shown. Only these three flags are inherited, not arbitrary styles.
    static func inheritSpaceBehavior(from parent: NSWindow, to child: NSWindow) {
        let scope: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace, .fullScreenAuxiliary]
        var value = child.collectionBehavior
        value.remove(scope); value.formUnion(parent.collectionBehavior.intersection(scope))
        child.collectionBehavior = value
    }
}

/// One coordinator-owned preference service. It owns no controllers, notifications,
/// windows, tasks, images or decode caches; nil defaults is an isolated fixture mode.
@MainActor final class PinDesktopVisibilityService {
    private let defaults: UserDefaults?
    private(set) var mode: PinDesktopVisibility
    init(defaults: UserDefaults? = .standard, initialMode: PinDesktopVisibility = .defaultMode) {
        self.defaults = defaults
        mode = defaults.map { PinDesktopVisibility.read(from: $0) } ?? initialMode
    }
    func select(_ mode: PinDesktopVisibility) {
        guard self.mode != mode else { return }
        self.mode = mode
        if let defaults { mode.save(to: defaults) }
    }
    func reload() { if let defaults { mode = .read(from: defaults) } }
}

/// A retained menu target with a weak controller callback. The same real controls
/// serve image and rich pins, so new managed content kinds inherit this route.
@MainActor final class PinDesktopVisibilityMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "所有贴图的桌面")
    var onSelect: ((PinDesktopVisibility) -> Void)? { didSet { refresh() } }
    var mode: PinDesktopVisibility = .defaultMode { didSet { refresh() } }
    override init() {
        super.init()
        menu.delegate = self; menu.autoenablesItems = false
        for (index, mode) in PinDesktopVisibility.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.identifier = NSUserInterfaceItemIdentifier("pin.desktopVisibility." + mode.rawValue)
            item.toolTip = PinDesktopVisibility.explanation
            menu.addItem(item)
        }
        refresh()
    }
    func add(to parent: NSMenu) {
        let item = parent.addItem(withTitle: menu.title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("pin.desktopVisibility"); item.submenu = menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }
    private func refresh() {
        for item in menu.items {
            item.state = PinDesktopVisibility.allCases[item.tag] == mode ? .on : .off
            item.isEnabled = onSelect != nil
        }
    }
    @objc private func selectMode(_ sender: NSMenuItem) {
        guard PinDesktopVisibility.allCases.indices.contains(sender.tag) else { return }
        onSelect?(PinDesktopVisibility.allCases[sender.tag])
        refresh()
    }
    func invalidate() { onSelect = nil; menu.delegate = nil; menu.items.forEach { $0.target = nil; $0.isEnabled = false } }
}
