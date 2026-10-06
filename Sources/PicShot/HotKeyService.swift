import AppKit
import Carbon

/// Stable IDs preserve the meanings of the original three positional preferences.
/// In particular, legacy slot 2 is always History, never Restore Last Pin.
enum HotKeyAction: Int, Codable, CaseIterable {
    case capture = 0, clipboardPin = 1, history = 2, restoreLastPin = 3
    static let settingsOrder: [HotKeyAction] = [.capture, .clipboardPin, .restoreLastPin, .history]
    var title: String {
        switch self {
        case .capture: return "区域截图"
        case .clipboardPin: return "剪贴板贴图"
        case .history: return "历史记录"
        case .restoreLastPin: return "恢复上次关闭的贴图"
        }
    }
    var defaultBinding: HotKeyBinding {
        switch self {
        case .capture: return HotKeyBinding(keyCode: 18, modifiers: UInt32(controlKey))
        case .clipboardPin: return HotKeyBinding(keyCode: 19, modifiers: UInt32(controlKey))
        case .restoreLastPin: return HotKeyBinding(keyCode: 20, modifiers: UInt32(controlKey))
        case .history: return HotKeyBinding(keyCode: 4, modifiers: UInt32(cmdKey | controlKey))
        }
    }
}

struct HotKeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    static var defaults: [HotKeyBinding] { HotKeyAction.allCases.map(\.defaultBinding) }
    static let keyNames: [UInt32: String] = [18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",49:"Space",0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",50:"`",27:"-",24:"=",33:"[",30:"]",41:";",39:"'",43:",",47:".",44:"/",42:"\\"]
    var displayName: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") +
        (Self.keyNames[keyCode] ?? "键\(keyCode)")
    }
    var isValid: Bool {
        let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        return keyCode <= 127 && modifiers & ~allowed == 0 && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }
    var keyEquivalent: String {
        if keyCode == 49 { return " " }
        return Self.keyNames[keyCode]?.lowercased() ?? ""
    }
    var keyEquivalentModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }
}

struct HotKeyShortcut: Codable, Equatable {
    var action: HotKeyAction
    var binding: HotKeyBinding
}

struct HotKeyConfiguration: Equatable {
    static let preferenceKey = "hotkeyActions.v1"
    static let legacyPreferenceKey = "hotkeys"
    var shortcuts: [HotKeyShortcut]
    static var defaults: HotKeyConfiguration {
        HotKeyConfiguration(shortcuts: HotKeyAction.allCases.map { HotKeyShortcut(action: $0, binding: $0.defaultBinding) })
    }
    subscript(_ action: HotKeyAction) -> HotKeyBinding? {
        get { shortcuts.first { $0.action == action }?.binding }
        set {
            shortcuts.removeAll { $0.action == action }
            if let newValue { shortcuts.append(HotKeyShortcut(action: action, binding: newValue)); shortcuts.sort { $0.action.rawValue < $1.action.rawValue } }
        }
    }
    var validationMessage: String? {
        guard shortcuts.allSatisfy({ $0.binding.isValid }) else { return "快捷键需要包含 ⌘、⌃ 或 ⌥，并使用有效按键。" }
        guard Set(shortcuts.map(\.action)).count == shortcuts.count,
              Set(shortcuts.map(\.binding)).count == shortcuts.count else { return "快捷键不能重复，请为每个操作选择不同的组合键。" }
        return nil
    }
    static func read(from defaults: UserDefaults = .standard) -> HotKeyConfiguration {
        if let data = defaults.data(forKey: preferenceKey),
           let shortcuts = try? JSONDecoder().decode([HotKeyShortcut].self, from: data) {
            return HotKeyConfiguration(shortcuts: shortcuts)
        }
        guard let data = defaults.data(forKey: legacyPreferenceKey),
              let legacy = try? JSONDecoder().decode([HotKeyBinding].self, from: data) else { return .defaults }
        var result = HotKeyConfiguration(shortcuts: legacy.prefix(3).enumerated().compactMap { index, binding in
            HotKeyAction(rawValue: index).map { HotKeyShortcut(action: $0, binding: binding) }
        })
        // Read migration never rewrites an existing key, including Ctrl+3 assigned to History.
        // Only new actions with unused defaults are added. Missing old actions stay unassigned.
        let restore = HotKeyAction.restoreLastPin.defaultBinding
        if !result.shortcuts.contains(where: { $0.binding == restore }) { result[.restoreLastPin] = restore }
        return result
    }
    func save(to defaults: UserDefaults = .standard) throws {
        if let validationMessage { throw PicShotError.message(validationMessage) }
        defaults.set(try JSONEncoder().encode(shortcuts.sorted { $0.action.rawValue < $1.action.rawValue }), forKey: Self.preferenceKey)
    }
}

@MainActor final class HotKeyService {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onAction: ((HotKeyAction) -> Void)?
    private(set) var failures: [HotKeyAction] = []
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer -> OSStatus in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x50534854, let action = HotKeyAction(rawValue: Int(id.id) - 1) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKeyService>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { owner.onAction?(action) }; return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ configuration: HotKeyConfiguration) {
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll(); failures = []
        for shortcut in configuration.shortcuts {
            let binding = shortcut.binding
            guard binding.isValid else { failures.append(shortcut.action); continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x50534854, id: UInt32(shortcut.action.rawValue + 1))
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failures.append(shortcut.action) }
        }
    }
    func invalidate() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
