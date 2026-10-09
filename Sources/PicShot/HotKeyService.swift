import AppKit
import Carbon

/// Stable IDs preserve the meanings of the original three positional preferences.
/// In particular, legacy slot 2 is always History, never Restore Last Pin.
enum HotKeyAction: Int, Codable, CaseIterable {
    case capture = 0, clipboardPin = 1, history = 2, restoreLastPin = 3
    case recordingPauseResume = 4, recordingStopSave = 5
    static let settingsOrder: [HotKeyAction] = [.capture, .clipboardPin, .restoreLastPin, .history, .recordingPauseResume, .recordingStopSave]
    var requiresActiveRecording: Bool { self == .recordingPauseResume || self == .recordingStopSave }
    var title: String {
        switch self {
        case .capture: return "区域截图"
        case .clipboardPin: return "剪贴板贴图"
        case .history: return "历史记录"
        case .restoreLastPin: return "恢复上次关闭的贴图"
        case .recordingPauseResume: return "录屏暂停 / 继续"
        case .recordingStopSave: return "录屏停止并保存"
        }
    }
    var defaultBinding: HotKeyBinding? {
        switch self {
        case .capture: return HotKeyBinding(keyCode: 18, modifiers: UInt32(controlKey))
        case .clipboardPin: return HotKeyBinding(keyCode: 19, modifiers: UInt32(controlKey))
        case .restoreLastPin: return HotKeyBinding(keyCode: 20, modifiers: UInt32(controlKey))
        case .history: return HotKeyBinding(keyCode: 4, modifiers: UInt32(cmdKey | controlKey))
        case .recordingPauseResume, .recordingStopSave: return nil
        }
    }
}

struct HotKeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    static var defaults: [HotKeyBinding] { HotKeyAction.allCases.compactMap(\.defaultBinding) }
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
        HotKeyConfiguration(shortcuts: HotKeyAction.allCases.compactMap { action in
            action.defaultBinding.map { HotKeyShortcut(action: action, binding: $0) }
        })
    }
    /// Exact configured chords, including while suspended/idle or unavailable in Carbon.
    /// Input-effect suppression uses this rather than successful registrations.
    var transportBindings: Set<HotKeyBinding> {
        Set(shortcuts.filter { $0.action.requiresActiveRecording }.map(\.binding))
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
        if let restore = HotKeyAction.restoreLastPin.defaultBinding,
           !result.shortcuts.contains(where: { $0.binding == restore }) { result[.restoreLastPin] = restore }
        return result
    }
    func save(to defaults: UserDefaults = .standard) throws {
        if let validationMessage { throw PicShotError.message(validationMessage) }
        defaults.set(try JSONEncoder().encode(shortcuts.sorted { $0.action.rawValue < $1.action.rawValue }), forKey: Self.preferenceKey)
    }
}

enum HotKeyEventPhase: Equatable { case pressed, released }

/// Native tests inject this seam; they never register actual system shortcuts.
@MainActor protocol HotKeyBackend: AnyObject {
    var onEvent: ((UInt32, HotKeyEventPhase) -> Void)? { get set }
    func register(_ binding: HotKeyBinding, id: UInt32) -> Bool
    func unregister(_ id: UInt32)
    func isKeyDown(_ keyCode: UInt32) -> Bool
    func invalidate()
}

@MainActor private final class CarbonHotKeyBackend: HotKeyBackend {
    private static let signature: OSType = 0x50534854
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    var onEvent: ((UInt32, HotKeyEventPhase) -> Void)?

    init() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer -> OSStatus in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            // The application event target delivers on the main event loop. Do not
            // retain the owner in deferred Carbon work; service dispatch is weak.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<CarbonHotKeyBackend>.fromOpaque(pointer).takeUnretainedValue()
                return owner.receive(event)
            }
        }, UInt32(types.count), &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
        }
    }
    private func receive(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == Self.signature, refs[id.id] != nil else { return OSStatus(eventNotHandledErr) }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed): onEvent?(id.id, .pressed)
        case UInt32(kEventHotKeyReleased): onEvent?(id.id, .released)
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
    func register(_ binding: HotKeyBinding, id: UInt32) -> Bool {
        guard handler != nil, refs[id] == nil else { return false }
        var ref: EventHotKeyRef?
        let identity = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, identity, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            if let ref { UnregisterEventHotKey(ref) }
            return false
        }
        refs[id] = ref
        return true
    }
    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }
    func isKeyDown(_ keyCode: UInt32) -> Bool {
        // A one-key state snapshot prevents an already-held chord from firing
        // again when Settings closes or a new session becomes active. No tap,
        // monitor, polling loop, or permission request is installed here.
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }
    func invalidate() {
        onEvent = nil
        refs.values.forEach { UnregisterEventHotKey($0) }; refs.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    deinit {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor final class HotKeyService {
    private final class Generation {}
    // Runtime IDs are distinct from persisted action IDs. Never reuse an ID in
    // this process, so an old Carbon event cannot acquire a new action meaning.
    // The scalar saturates rather than wrapping; at most six entries are live.
    private static var nextRuntimeID: UInt32? = 1
    private let backend: any HotKeyBackend
    private let dispatch: (@escaping @MainActor () -> Void) -> Void
    private var configuration = HotKeyConfiguration(shortcuts: [])
    private var generation = Generation()
    private var registrations: [UInt32: HotKeyAction] = [:]
    private var held: Set<UInt32> = []
    private var invalidated = false
    private(set) var isRecordingActive = false
    private(set) var failures: [HotKeyAction] = []
    var onAction: ((HotKeyAction) -> Void)?

    init(backend: (any HotKeyBackend)? = nil,
         dispatch: @escaping (@escaping @MainActor () -> Void) -> Void = { callback in DispatchQueue.main.async { callback() } }) {
        self.backend = backend ?? CarbonHotKeyBackend()
        self.dispatch = dispatch
        self.backend.onEvent = { [weak self] id, phase in self?.receive(id, phase: phase) }
    }
    func register(_ configuration: HotKeyConfiguration) {
        guard !invalidated else { return }
        // An explicit empty configuration is a Settings suspension. Lifecycle
        // changes must never fall back to persisted preferences or defaults.
        self.configuration = configuration
        rebuildRegistrations()
    }
    /// True throughout one active take, including Pause. False for idle,
    /// countdown and finishing. A repeated value preserves held-key state.
    func setRecordingActive(_ active: Bool) {
        guard !invalidated, active != isRecordingActive else { return }
        isRecordingActive = active
        rebuildRegistrations()
    }
    private func rebuildRegistrations() {
        removeRegistrations()
        failures = []
        for action in HotKeyAction.allCases where isRecordingActive || !action.requiresActiveRecording {
            let choices = configuration.shortcuts.filter { $0.action == action }
            guard let shortcut = choices.first else { continue }
            let binding = shortcut.binding
            guard choices.count == 1, binding.isValid,
                  configuration.shortcuts.filter({ $0.binding == binding }).count == 1,
                  let id = Self.nextRuntimeID else { failures.append(action); continue }
            Self.nextRuntimeID = id == .max ? nil : id + 1
            guard backend.register(binding, id: id) else { failures.append(action); continue }
            registrations[id] = action
            if backend.isKeyDown(binding.keyCode) { held.insert(id) }
        }
    }
    private func receive(_ id: UInt32, phase: HotKeyEventPhase) {
        guard !invalidated, let action = registrations[id] else { return }
        if phase == .released { held.remove(id); return }
        guard held.insert(id).inserted else { return }
        let admittedGeneration = generation
        dispatch { [weak self] in
            guard let self, !self.invalidated, self.generation === admittedGeneration,
                  self.registrations[id] == action,
                  self.isRecordingActive || !action.requiresActiveRecording else { return }
            self.onAction?(action)
        }
    }
    private func removeRegistrations() {
        generation = Generation()
        let ids = Array(registrations.keys)
        registrations.removeAll(); held.removeAll()
        // Clear admission first, including if an injected backend synchronously
        // delivers a pending release during unregister.
        ids.forEach { backend.unregister($0) }
    }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; isRecordingActive = false
        removeRegistrations(); failures = []; onAction = nil
        backend.invalidate()
    }
    deinit {
        if !invalidated {
            let backend = backend
            Task { @MainActor in backend.invalidate() }
        }
    }
}
