import AppKit
import PicShotCore

enum SettingsCategory: String, CaseIterable {
    case appearance, capture, save, annotations, pins, history, shortcuts, configuration
    var title: String {
        switch self {
        case .appearance: return "外观"
        case .capture: return "截图"
        case .save: return "保存与命名"
        case .annotations: return "标注工具"
        case .pins: return "贴图"
        case .history: return "历史记录"
        case .shortcuts: return "快捷键 / 动作"
        case .configuration: return "配置文件"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .capture: return "viewfinder"
        case .save: return "folder.badge.plus"
        case .annotations: return "pencil.and.outline"
        case .pins: return "pin"
        case .history: return "clock"
        case .shortcuts: return "command"
        case .configuration: return "arrow.triangle.2.circlepath"
        }
    }
}

extension AppAppearancePreference {
    var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var appKitAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
    @MainActor static func applySaved(isSmoke: Bool, defaults: UserDefaults = .standard) {
        // Smoke snapshots use an explicit deterministic appearance and never read user preferences.
        guard !isSmoke else { return }
        NSApp.appearance = read(from: defaults).appKitAppearance
    }
}

@MainActor final class SettingsSidebarButton: NSButton {
    var isCurrent = false { didSet { needsDisplay = true; updateLayer() } }
    override var wantsUpdateLayer: Bool { true }
    init(category: SettingsCategory) {
        super.init(frame: .zero)
        title = "  " + category.title; image = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading; imageScaling = .scaleProportionallyDown
        alignment = .left; font = .systemFont(ofSize: 13); isBordered = false
        setButtonType(.momentaryPushIn); wantsLayer = true; layer?.cornerRadius = 6
        setAccessibilityLabel(category.title)
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = (isCurrent ? NSColor(calibratedRed: 0.20, green: 0.53, blue: 1, alpha: 1) : .clear).cgColor
        contentTintColor = isCurrent ? .white : .labelColor
    }
}

@MainActor final class SettingsCardView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.cornerRadius = 8; layer?.borderWidth = 0.5 }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
