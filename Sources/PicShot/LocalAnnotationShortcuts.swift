import AppKit

/// Local editor bindings are deliberately disjoint from global hotkeys. Only
/// physical letter/digit keys, optionally with Shift, can select a tool.
struct LocalAnnotationShortcutBinding: Codable, Equatable, Hashable {
    let keyCode: UInt16
    /// 0 = no modifiers, 1 = Shift. This is a portable mask, not AppKit/Carbon bits.
    let modifiers: UInt8
    static let shift: UInt8 = 1
    static let keyNames: [UInt16: String] = [0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 25:"9", 26:"7", 28:"8", 29:"0", 31:"O", 32:"U", 34:"I", 35:"P", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M"]
    var displayName: String { (modifiers == Self.shift ? "⇧" : "") + (Self.keyNames[keyCode] ?? "保留键") }

    init(keyCode: UInt16, modifiers: UInt8 = 0) { self.keyCode = keyCode; self.modifiers = modifiers }
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }
    init(from decoder: Decoder) throws {
        try LocalShortcutCodingKey.require(decoder, keys: ["keyCode", "modifiers"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try values.decode(UInt16.self, forKey: .keyCode)
        modifiers = try values.decode(UInt8.self, forKey: .modifiers)
        try validate()
    }
    func validate() throws {
        guard modifiers <= Self.shift else { throw LocalAnnotationShortcutError.reservedModifiers }
        guard keyCode != 0 else { throw LocalAnnotationShortcutError.numberCommentKey }
        guard Self.keyNames[keyCode] != nil else { throw LocalAnnotationShortcutError.reservedKey }
    }
    /// No event characters, text/AX values, global monitors or permissions.
    static func capture(_ event: NSEvent) throws -> Self {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard flags.subtracting(.shift).isEmpty else { throw LocalAnnotationShortcutError.reservedModifiers }
        let binding = Self(keyCode: event.keyCode, modifiers: flags.contains(.shift) ? shift : 0)
        try binding.validate(); return binding
    }
}

struct LocalAnnotationShortcut: Codable, Equatable {
    let tool: ImageEditorTool
    let binding: LocalAnnotationShortcutBinding
    init(tool: ImageEditorTool, binding: LocalAnnotationShortcutBinding) { self.tool = tool; self.binding = binding }
    private enum CodingKeys: String, CodingKey { case tool, binding }
    init(from decoder: Decoder) throws {
        try LocalShortcutCodingKey.require(decoder, keys: ["tool", "binding"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .tool)
        guard let tool = ImageEditorTool(rawValue: name) else { throw LocalAnnotationShortcutError.malformed }
        self.tool = tool
        binding = try values.decode(LocalAnnotationShortcutBinding.self, forKey: .binding)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tool.rawValue, forKey: .tool); try values.encode(binding, forKey: .binding)
    }
}

/// Missing bindings are explicit clears. Build 185 had no tool-selection keys,
/// so default/reset is an empty map; its existing edit commands are untouched.
struct LocalAnnotationShortcutSettings: Codable, Equatable {
    static let preferenceKey = "annotation.localShortcuts.v1"
    static let maximumDataBytes = 8 * 1_024
    static let defaults = try! Self(bindings: [])
    let schemaVersion: Int
    let bindings: [LocalAnnotationShortcut]
    var summary: String {
        bindings.isEmpty ? "未设置" : bindings.map { "\($0.tool.title)：\($0.binding.displayName)" }.joined(separator: "、")
    }
    init(bindings: [LocalAnnotationShortcut]) throws {
        schemaVersion = 1
        self.bindings = bindings.sorted { $0.tool.rawValue < $1.tool.rawValue }
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, bindings }
    init(from decoder: Decoder) throws {
        try LocalShortcutCodingKey.require(decoder, keys: ["schemaVersion", "bindings"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw LocalAnnotationShortcutError.unsupportedVersion }
        var list = try values.nestedUnkeyedContainer(forKey: .bindings)
        var decoded: [LocalAnnotationShortcut] = []
        while !list.isAtEnd {
            guard decoded.count < ImageEditorTool.allCases.count else { throw LocalAnnotationShortcutError.tooManyBindings }
            decoded.append(try list.decode(LocalAnnotationShortcut.self))
        }
        bindings = decoded.sorted { $0.tool.rawValue < $1.tool.rawValue }
        try validate()
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw LocalAnnotationShortcutError.unsupportedVersion }
        guard bindings.count <= ImageEditorTool.allCases.count else { throw LocalAnnotationShortcutError.tooManyBindings }
        var tools = Set<ImageEditorTool>(), keys = Set<LocalAnnotationShortcutBinding>()
        for item in bindings {
            try item.binding.validate()
            guard tools.insert(item.tool).inserted else { throw LocalAnnotationShortcutError.duplicateTool }
            guard keys.insert(item.binding).inserted else { throw LocalAnnotationShortcutError.duplicateKey(item.binding.displayName) }
        }
    }
    subscript(_ tool: ImageEditorTool) -> LocalAnnotationShortcutBinding? { bindings.first { $0.tool == tool }?.binding }
    func tool(for binding: LocalAnnotationShortcutBinding) -> ImageEditorTool? { bindings.first { $0.binding == binding }?.tool }
    func replacing(_ tool: ImageEditorTool, with binding: LocalAnnotationShortcutBinding?) throws -> Self {
        var result = bindings.filter { $0.tool != tool }
        if let binding { result.append(LocalAnnotationShortcut(tool: tool, binding: binding)) }
        return try Self(bindings: result)
    }
    func encodedData() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumDataBytes else { throw LocalAnnotationShortcutError.tooLarge }
        return data
    }
    /// Use this byte entry point for stored JSON. A surrounding portable document
    /// must run its duplicate-key preflight before decoding this Codable value.
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumDataBytes else { throw LocalAnnotationShortcutError.tooLarge }
        var scanner = LocalShortcutJSONKeyScanner(data: data)
        try scanner.validate()
        return try JSONDecoder().decode(Self.self, from: data)
    }
    static func read(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preferenceKey), let value = try? decode(data) else { return .defaults }
        return value
    }
    func write(to defaults: UserDefaults = .standard) throws { defaults.set(try encodedData(), forKey: Self.preferenceKey) }
}

enum LocalAnnotationShortcutError: LocalizedError, Equatable {
    case malformed, unsupportedVersion, tooLarge, tooManyBindings, duplicateTool, duplicateKey(String)
    case reservedModifiers, reservedKey, numberCommentKey
    var errorDescription: String? {
        switch self {
        case .malformed: return "标注快捷键格式无效，含未知、重复或缺失字段。"
        case .unsupportedVersion: return "不支持此标注快捷键版本。"
        case .tooLarge, .tooManyBindings: return "标注快捷键数据超出限制。"
        case .duplicateTool: return "同一标注工具不能重复设置。"
        case .duplicateKey(let label): return "\(label) 已分配给其他工具，请先清除原有绑定。"
        case .reservedModifiers: return "仅支持字母或数字键，可加 Shift；Command、Control、Option 留给系统与全局快捷键。"
        case .reservedKey: return "此键保留给画布操作或导航；请选择字母或数字键。"
        case .numberCommentKey: return "A 保留用于编辑序号备注，请选择其他键。"
        }
    }
}

private struct LocalShortcutCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func require(_ decoder: Decoder, keys: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard Set(values.allKeys.map(\.stringValue)) == keys else { throw LocalAnnotationShortcutError.malformed }
    }
}

/// Reject duplicate keys before Foundation discards them, including escaped keys.
/// Input bytes and recursion are bounded before any value model is allocated.
private struct LocalShortcutJSONKeyScanner {
    let bytes: [UInt8]
    var position = 0
    init(data: Data) { bytes = Array(data) }
    mutating func validate() throws {
        try value(depth: 0); whitespace()
        guard position == bytes.count else { throw LocalAnnotationShortcutError.malformed }
    }
    private mutating func whitespace() { while position < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[position]) { position += 1 } }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace(); guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1; return true
    }
    private mutating func string() throws -> String {
        whitespace(); guard position < bytes.count, bytes[position] == 34 else { throw LocalAnnotationShortcutError.malformed }
        let start = position; position += 1
        while position < bytes.count {
            let byte = bytes[position]; position += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
            if byte == 92 {
                guard position < bytes.count else { throw LocalAnnotationShortcutError.malformed }; position += 1
            }
        }
        throw LocalAnnotationShortcutError.malformed
    }
    private mutating func value(depth: Int) throws {
        guard depth <= 8 else { throw LocalAnnotationShortcutError.malformed }
        whitespace(); guard position < bytes.count else { throw LocalAnnotationShortcutError.malformed }
        switch bytes[position] {
        case 123:
            position += 1; var keys = Set<String>()
            if take(125) { return }
            repeat {
                let key = try string()
                guard keys.insert(key).inserted, take(58) else { throw LocalAnnotationShortcutError.malformed }
                try value(depth: depth + 1)
                if take(125) { return }
                guard take(44) else { throw LocalAnnotationShortcutError.malformed }
            } while true
        case 91:
            position += 1; if take(93) { return }
            repeat {
                try value(depth: depth + 1)
                if take(93) { return }
                guard take(44) else { throw LocalAnnotationShortcutError.malformed }
            } while true
        case 34: _ = try string()
        default:
            let start = position
            while position < bytes.count, ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[position]) { position += 1 }
            guard position > start else { throw LocalAnnotationShortcutError.malformed }
        }
    }
}

/// Scope is an owned canvas's keyDown, never an application/global event monitor.
/// Native menu notifications cover tracking even when AppKit's run-loop mode is
/// not exposed (for example a fixture dispatching an owned window event).
@MainActor final class LocalAnnotationShortcutContext: NSObject {
    private var trackingMenus = Set<ObjectIdentifier>()
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func menuBegan(_ note: Notification) { if let menu = note.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) } }
    @objc private func menuEnded(_ note: Notification) { if let menu = note.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) } }
    func allows(_ event: NSEvent, canvas: NSView) -> Bool {
        guard event.type == .keyDown, !event.isARepeat, let window = canvas.window,
              window.isKeyWindow, window.firstResponder === canvas,
              event.windowNumber == window.windowNumber,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              trackingMenus.isEmpty, RunLoop.current.currentMode != .eventTracking else { return false }
        // All text responders (including field editors and marked/IME text) fail
        // the exact canvas-identity requirement above. No text value is inspected.
        return true
    }
}
