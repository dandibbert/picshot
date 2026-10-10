import Foundation
import CoreFoundation
import PicShotCore

enum PortableSettingsError: LocalizedError, Equatable {
    case tooLarge, malformed, unsupportedVersion, invalidValues, conflict, unknownPersistenceDomain, applyFailed, rollbackFailed

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "设置文件不能超过 64 KiB。"
        case .malformed: return "设置文件格式无效，包含重复、未知或缺失的字段。未更改任何设置。"
        case .unsupportedVersion: return "不支持此设置文件版本。未更改任何设置。"
        case .invalidValues: return "设置文件包含无效值、重复快捷键或无效标注样式／工具顺序。未更改任何设置。"
        case .conflict: return "设置在预览后发生了更改，请重新导入并检查差异。"
        case .unknownPersistenceDomain: return "无法确定此自定义设置存储的位置，未保存导入内容。"
        case .applyFailed: return "未能保存导入的设置；本次已写入的设置已还原。"
        case .rollbackFailed: return "保存期间设置被其他来源修改，无法完整还原。请重新打开设置并检查。"
        }
    }
}

struct PortableSettingsChange: Equatable {
    let id: String
    let label: String
    let oldValue: String
    let newValue: String
    var summary: String { "\(label)：\(oldValue) → \(newValue)" }
}

/// An immutable review, bound to the store and values that produced it.
struct PortableSettingsImportPlan {
    let changes: [PortableSettingsChange]
    let hotKeyConfiguration: HotKeyConfiguration
    let changesHotKeys: Bool
    var hasChanges: Bool { !changes.isEmpty }
    var summary: String { changes.map(\.summary).joined(separator: "\n") }
    var changesHistoryRetention: Bool { changes.contains { $0.id.hasPrefix("history") } }
    fileprivate let owner: UUID
    fileprivate let generation: UInt64
    fileprivate let baseline: [String: PortableStoredValue]
    fileprivate let persistentBaseline: [String: PortableStoredValue]?
    fileprivate let mutations: [PortableSettingsMutation]
}

/// Offline, allowlisted settings only. No arbitrary defaults enumeration, capture or
/// OCR content, history entries, credentials, bookmarks, local paths, window frames,
/// save-workflow destinations/automatic writes, or recording-input opt-ins enter
/// the portable document. Persistence snapshots retain only allowlisted keys.
///
/// Apply is a synchronous main-actor logical transaction: it checks its review
/// baseline, validates hotkeys before writes, and restores touched raw values after
/// ordinary failure. UserDefaults offers no crash-durable multi-key transaction or
/// cross-process isolation. This does not make later history pruning transactional.
@MainActor final class PortableSettingsStore {
    nonisolated static let maximumFileBytes = 64 * 1_024
    private let defaults: UserDefaults
    private let persistentDomainName: String?
    private let identity = UUID()
    private var generation: UInt64 = 0
    private var applying = false
    /// Test seam for a failure immediately before a numbered preference write.
    var beforeWrite: ((Int) throws -> Void)?
    /// Covers ordinary post-write failure, including the final write, in tests.
    var afterWrite: ((Int) throws -> Void)?

    /// Foundation does not expose a custom UserDefaults suite's name. Inject it
    /// for custom stores so rollback can distinguish absence from fallback values.
    init(defaults: UserDefaults = .standard, persistentDomainName: String? = nil) {
        self.defaults = defaults
        if let persistentDomainName, !persistentDomainName.isEmpty { self.persistentDomainName = persistentDomainName }
        else if defaults === UserDefaults.standard {
            self.persistentDomainName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        } else { self.persistentDomainName = nil }
    }

    /// Bounded even for a file that grows after the panel's metadata check.
    static func readImportData(from url: URL) throws -> Data {
        guard url.isFileURL else { throw PortableSettingsError.malformed }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw PortableSettingsError.malformed }
        guard (values.fileSize ?? 0) <= maximumFileBytes else { throw PortableSettingsError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw PortableSettingsError.tooLarge }
        return data
    }

    func exportData() throws -> Data {
        let document = try currentDocument()
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumFileBytes else { throw PortableSettingsError.tooLarge }
        return data
    }

    func prepareImport(_ data: Data) throws -> PortableSettingsImportPlan {
        guard !applying else { throw PortableSettingsError.conflict }
        let incoming = try PortableSettingsDocument.decode(data)
        let baseline = snapshot()
        let current = try currentDocument()
        let changes = incoming.changes(from: current)
        let mutations = try incoming.mutations(from: current)
        return PortableSettingsImportPlan(changes: changes, hotKeyConfiguration: incoming.hotKeyConfiguration,
            changesHotKeys: incoming.hotKeyConfiguration != current.hotKeyConfiguration,
            owner: identity, generation: generation, baseline: baseline,
            persistentBaseline: persistentSnapshot(), mutations: mutations)
    }

    /// The owner may probe OS registrations here. A throwing validator rejects the
    /// entire import before persistence. The owner owns any registration cleanup.
    func apply(_ plan: PortableSettingsImportPlan,
               validateHotkeys: (HotKeyConfiguration) throws -> Void = { _ in }) throws {
        guard !applying, plan.owner == identity, plan.generation == generation,
              matches(plan.baseline), persistentSnapshot() == plan.persistentBaseline else { throw PortableSettingsError.conflict }
        guard plan.mutations.isEmpty || plan.persistentBaseline != nil else { throw PortableSettingsError.unknownPersistenceDomain }
        applying = true
        defer { applying = false }
        if plan.changesHotKeys { try validateHotkeys(plan.hotKeyConfiguration) }
        guard matches(plan.baseline), persistentSnapshot() == plan.persistentBaseline else { throw PortableSettingsError.conflict }

        var expected = plan.baseline
        var expectedPersistent = plan.persistentBaseline
        var written: [PortableSettingsMutation] = []
        do {
            for (index, mutation) in plan.mutations.enumerated() {
                try beforeWrite?(index)
                guard matches(expected), persistentSnapshot() == expectedPersistent else { throw PortableSettingsError.conflict }
                // Track before calling set so an ordinary failed write is covered.
                written.append(mutation)
                defaults.set(mutation.value, forKey: mutation.key)
                expected[mutation.key] = PortableStoredValue(mutation.value)
                expectedPersistent?[mutation.key] = PortableStoredValue(mutation.value)
                try afterWrite?(index)
                guard matches(expected), persistentSnapshot() == expectedPersistent else { throw PortableSettingsError.applyFailed }
            }
            generation &+= 1
        } catch {
            var restored = true
            for mutation in written.reversed() {
                let now = persistentSnapshot()?[mutation.key]
                let before = plan.persistentBaseline![mutation.key]!
                // Do not overwrite another writer's newly observed value.
                guard now == PortableStoredValue(mutation.value) || now == before else {
                    restored = false; continue
                }
                if let value = before.value { defaults.set(value, forKey: mutation.key) }
                else { defaults.removeObject(forKey: mutation.key) }
                if persistentSnapshot()?[mutation.key] != before { restored = false }
            }
            guard restored else { throw PortableSettingsError.rollbackFailed }
            if error as? PortableSettingsError == .conflict { throw PortableSettingsError.conflict }
            throw PortableSettingsError.applyFailed
        }
    }

    private static var observedKeys: [String] {
        [AppAppearancePreference.preferenceKey, ScreenshotPreferences.delayKey, ScreenshotPreferences.cursorKey,
         PinDesktopVisibility.preferenceKey, PinSessionStore.restorePreferenceKey, PinOCRPreferences.automaticPreferenceKey,
         "historyDays", "historyCount", "historyMB", HotKeyConfiguration.preferenceKey,
         HotKeyConfiguration.legacyPreferenceKey, AnnotationToolbarOrder.preferenceKey,
         AnnotationStyleSettings.preferenceKey, LocalAnnotationShortcutSettings.preferenceKey]
    }

    private func snapshot() -> [String: PortableStoredValue] {
        Dictionary(uniqueKeysWithValues: Self.observedKeys.map { ($0, PortableStoredValue(defaults.object(forKey: $0))) })
    }

    private func matches(_ values: [String: PortableStoredValue]) -> Bool {
        values.allSatisfy { PortableStoredValue(defaults.object(forKey: $0.key)) == $0.value }
    }

    private func persistentSnapshot() -> [String: PortableStoredValue]? {
        guard let persistentDomainName else { return nil }
        let domain = defaults.persistentDomain(forName: persistentDomainName) ?? [:]
        return Dictionary(uniqueKeysWithValues: Self.observedKeys.map { ($0, PortableStoredValue(domain[$0])) })
    }

    private func currentDocument() throws -> PortableSettingsDocument {
        let hotkeys = HotKeyConfiguration.read(from: defaults)
        guard hotkeys.validationMessage == nil else { throw PortableSettingsError.invalidValues }
        let capture = ScreenshotPreferences.read(from: defaults)
        let history = HistoryRetentionPreferences.read(from: defaults)
        return PortableSettingsDocument(format: PortableSettingsDocument.formatIdentifier, schemaVersion: 1,
            preferences: PortableSettingsPreferences(
                appearance: AppAppearancePreference.read(from: defaults).rawValue,
                screenshotDelaySeconds: capture.delay.rawValue, screenshotShowsCursor: capture.showsCursor,
                pinDesktopVisibility: PinDesktopVisibility.read(from: defaults).rawValue,
                restorePinsOnLaunch: defaults.bool(forKey: PinSessionStore.restorePreferenceKey),
                automaticallyRecognizePinText: defaults.bool(forKey: PinOCRPreferences.automaticPreferenceKey),
                historyDays: history.days, historyCount: history.count, historyMegabytes: history.megabytes),
            hotkeys: PortableHotKeyAction.allCases.map { PortableSettingsHotKey(action: $0, binding: hotkeys[$0.localAction]) },
            annotationToolOrder: AnnotationToolbarOrder.read(from: defaults).rawIDs,
            annotationStyles: AnnotationStyleSettings.read(from: defaults),
            annotationShortcuts: LocalAnnotationShortcutSettings.read(from: defaults))
    }
}

fileprivate struct PortableStoredValue: Equatable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.value, rhs.value) {
        case (nil, nil): return true
        case let (left as NSObject, right as NSObject):
            if let a = left as? NSNumber, let b = right as? NSNumber,
               (CFGetTypeID(a) == CFBooleanGetTypeID()) != (CFGetTypeID(b) == CFBooleanGetTypeID()) { return false }
            return left.isEqual(right)
        default: return false
        }
    }
}

fileprivate struct PortableSettingsMutation {
    let key: String
    let value: Any
}

private enum PortableHotKeyAction: String, Codable, CaseIterable {
    case capture, clipboardPin, restoreLastPin, history, recordingPauseResume, recordingStopSave
    var localAction: HotKeyAction {
        switch self {
        case .capture: return .capture
        case .clipboardPin: return .clipboardPin
        case .restoreLastPin: return .restoreLastPin
        case .history: return .history
        case .recordingPauseResume: return .recordingPauseResume
        case .recordingStopSave: return .recordingStopSave
        }
    }
}

private struct PortableSettingsHotKey: Codable, Equatable {
    let action: PortableHotKeyAction
    let binding: HotKeyBinding?
    private enum CodingKeys: String, CodingKey { case action, binding }
    init(action: PortableHotKeyAction, binding: HotKeyBinding?) { self.action = action; self.binding = binding }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(PortableHotKeyAction.self, forKey: .action)
        binding = try container.decode(HotKeyBinding?.self, forKey: .binding)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        // Explicit null distinguishes an unassigned shortcut from a missing action.
        try container.encode(binding, forKey: .binding)
    }
}

private struct PortableSettingsPreferences: Codable, Equatable {
    let appearance: String
    let screenshotDelaySeconds: Int
    let screenshotShowsCursor: Bool
    let pinDesktopVisibility: String
    let restorePinsOnLaunch: Bool
    let automaticallyRecognizePinText: Bool
    let historyDays: Int
    let historyCount: Int
    let historyMegabytes: Int

    static let keys: Set<String> = ["appearance", "screenshotDelaySeconds", "screenshotShowsCursor",
        "pinDesktopVisibility", "restorePinsOnLaunch", "automaticallyRecognizePinText",
        "historyDays", "historyCount", "historyMegabytes"]

    func validate() throws {
        guard AppAppearancePreference(rawValue: appearance) != nil,
              ScreenshotDelay(rawValue: screenshotDelaySeconds) != nil,
              PinDesktopVisibility(rawValue: pinDesktopVisibility) != nil,
              HistoryRetentionPreferences(days: historyDays, count: historyCount, megabytes: historyMegabytes).isValid
        else { throw PortableSettingsError.invalidValues }
    }
}

private struct PortableSettingsDocument: Codable {
    static let formatIdentifier = "picshot.preferences"
    let format: String
    let schemaVersion: Int
    let preferences: PortableSettingsPreferences
    let hotkeys: [PortableSettingsHotKey]
    let annotationToolOrder: [String]?
    /// Absent optional sections preserve local settings when importing older files.
    let annotationStyles: AnnotationStyleSettings?
    let annotationShortcuts: LocalAnnotationShortcutSettings?

    var hotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(shortcuts: hotkeys.compactMap { shortcut in
            shortcut.binding.map { HotKeyShortcut(action: shortcut.action.localAction, binding: $0) }
        }.sorted { $0.action.rawValue < $1.action.rawValue })
    }

    func validate() throws {
        guard format == Self.formatIdentifier else { throw PortableSettingsError.malformed }
        guard schemaVersion == 1 else { throw PortableSettingsError.unsupportedVersion }
        try preferences.validate()
        guard hotkeys.count == PortableHotKeyAction.allCases.count,
              Set(hotkeys.map(\.action)) == Set(PortableHotKeyAction.allCases),
              hotKeyConfiguration.validationMessage == nil else { throw PortableSettingsError.invalidValues }
        if let annotationToolOrder {
            do { _ = try AnnotationToolbarOrder(rawIDs: annotationToolOrder) }
            catch { throw PortableSettingsError.invalidValues }
        }
        do {
            if let annotationStyles { _ = try annotationStyles.encoded() }
            try annotationShortcuts?.validate()
        } catch { throw PortableSettingsError.invalidValues }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= PortableSettingsStore.maximumFileBytes else { throw PortableSettingsError.tooLarge }
        do {
            var scanner = PortableJSONKeyScanner(data: data)
            try scanner.validate()
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else { throw PortableSettingsError.malformed }
            try requireKeys(root, required: ["format", "schemaVersion", "preferences", "hotkeys"],
                optional: ["annotationToolOrder", "annotationStyles", "annotationShortcuts"])
            guard let preferences = root["preferences"] as? [String: Any],
                  let hotkeys = root["hotkeys"] as? [[String: Any]] else { throw PortableSettingsError.malformed }
            try requireKeys(preferences, required: PortableSettingsPreferences.keys)
            for shortcut in hotkeys {
                try requireKeys(shortcut, required: ["action", "binding"])
                if !(shortcut["binding"] is NSNull) {
                    guard let binding = shortcut["binding"] as? [String: Any] else { throw PortableSettingsError.malformed }
                    try requireKeys(binding, required: ["keyCode", "modifiers"])
                }
            }
            if let order = root["annotationToolOrder"], !(order is [String]) { throw PortableSettingsError.malformed }
            // Null is not an omitted section. The nested strict Codable models
            // validate their schema, keys, primitive types and bounded allowlists.
            for key in ["annotationStyles", "annotationShortcuts"] {
                if let value = root[key], !(value is [String: Any]) { throw PortableSettingsError.malformed }
            }
            let document = try JSONDecoder().decode(Self.self, from: data)
            try document.validate()
            return document
        } catch let error as PortableSettingsError { throw error }
        catch { throw PortableSettingsError.malformed }
    }

    private static func requireKeys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw PortableSettingsError.malformed }
    }

    @MainActor func changes(from old: Self) -> [PortableSettingsChange] {
        var result: [PortableSettingsChange] = []
        func add(_ id: String, _ label: String, _ before: String, _ after: String) {
            if before != after { result.append(PortableSettingsChange(id: id, label: label, oldValue: before, newValue: after)) }
        }
        func yesNo(_ value: Bool) -> String { value ? "开启" : "关闭" }
        func appearance(_ raw: String) -> String { AppAppearancePreference(rawValue: raw)?.title ?? raw }
        func desktop(_ raw: String) -> String { PinDesktopVisibility(rawValue: raw)?.title ?? raw }
        let a = old.preferences, b = preferences
        add("appearance", "界面主题", appearance(a.appearance), appearance(b.appearance))
        add("screenshotDelaySeconds", "截图延时", "\(a.screenshotDelaySeconds) 秒", "\(b.screenshotDelaySeconds) 秒")
        add("screenshotShowsCursor", "截图鼠标指针", yesNo(a.screenshotShowsCursor), yesNo(b.screenshotShowsCursor))
        add("pinDesktopVisibility", "贴图桌面范围", desktop(a.pinDesktopVisibility), desktop(b.pinDesktopVisibility))
        add("restorePinsOnLaunch", "启动时恢复贴图", yesNo(a.restorePinsOnLaunch), yesNo(b.restorePinsOnLaunch))
        add("automaticallyRecognizePinText", "自动识别贴图文字", yesNo(a.automaticallyRecognizePinText), yesNo(b.automaticallyRecognizePinText))
        add("historyDays", "历史保留天数", String(a.historyDays), String(b.historyDays))
        add("historyCount", "历史保留张数", String(a.historyCount), String(b.historyCount))
        add("historyMegabytes", "历史大小上限", "\(a.historyMegabytes) MB", "\(b.historyMegabytes) MB")
        for action in HotKeyAction.settingsOrder {
            add("hotkey.\(action.rawValue)", action.title, old.hotKeyConfiguration[action]?.displayName ?? "未设置", hotKeyConfiguration[action]?.displayName ?? "未设置")
        }
        if let annotationToolOrder {
            func titles(_ ids: [String]) -> String { ids.map { ImageEditorTool(rawValue: $0)?.title ?? $0 }.joined(separator: "、") }
            add("annotationToolOrder", "标注工具顺序", titles(old.annotationToolOrder ?? []), titles(annotationToolOrder))
        }
        if let annotationStyles {
            let before = old.annotationStyles ?? .defaults
            for tool in AnnotationStyleSettings.Tool.allCases {
                let prior = before.styles.first { $0.tool == tool }
                let next = annotationStyles.styles.first { $0.tool == tool }
                if prior != next {
                    result.append(PortableSettingsChange(id: "annotationStyle.\(tool.rawValue)",
                        label: "\(tool.title)默认样式", oldValue: prior?.summary ?? "原始默认样式",
                        newValue: next?.summary ?? "原始默认样式"))
                }
            }
        }
        if let annotationShortcuts, annotationShortcuts != old.annotationShortcuts {
            result.append(PortableSettingsChange(id: "annotationShortcuts", label: "标注工具快捷键",
                oldValue: (old.annotationShortcuts ?? .defaults).summary, newValue: annotationShortcuts.summary))
        }
        return result
    }

    @MainActor func mutations(from old: Self) throws -> [PortableSettingsMutation] {
        var result: [PortableSettingsMutation] = []
        func add<T: Equatable>(_ key: String, _ before: T, _ after: T) {
            if before != after { result.append(PortableSettingsMutation(key: key, value: after)) }
        }
        let a = old.preferences, b = preferences
        add(AppAppearancePreference.preferenceKey, a.appearance, b.appearance)
        add(ScreenshotPreferences.delayKey, a.screenshotDelaySeconds, b.screenshotDelaySeconds)
        add(ScreenshotPreferences.cursorKey, a.screenshotShowsCursor, b.screenshotShowsCursor)
        add(PinDesktopVisibility.preferenceKey, a.pinDesktopVisibility, b.pinDesktopVisibility)
        add(PinSessionStore.restorePreferenceKey, a.restorePinsOnLaunch, b.restorePinsOnLaunch)
        add(PinOCRPreferences.automaticPreferenceKey, a.automaticallyRecognizePinText, b.automaticallyRecognizePinText)
        add("historyDays", a.historyDays, b.historyDays)
        add("historyCount", a.historyCount, b.historyCount)
        add("historyMB", a.historyMegabytes, b.historyMegabytes)
        if hotKeyConfiguration != old.hotKeyConfiguration {
            result.append(PortableSettingsMutation(key: HotKeyConfiguration.preferenceKey,
                value: try JSONEncoder().encode(hotKeyConfiguration.shortcuts)))
        }
        if let annotationToolOrder, annotationToolOrder != old.annotationToolOrder {
            result.append(PortableSettingsMutation(key: AnnotationToolbarOrder.preferenceKey, value: annotationToolOrder))
        }
        if let annotationStyles, annotationStyles != old.annotationStyles {
            result.append(PortableSettingsMutation(key: AnnotationStyleSettings.preferenceKey,
                value: try annotationStyles.encoded()))
        }
        if let annotationShortcuts, annotationShortcuts != old.annotationShortcuts {
            result.append(PortableSettingsMutation(key: LocalAnnotationShortcutSettings.preferenceKey,
                value: try annotationShortcuts.encodedData()))
        }
        return result
    }
}

/// JSONDecoder/JSONSerialization accept duplicate object keys. Scan the original
/// bounded bytes first, comparing decoded keys (including escaped equivalents).
/// The decoder remains responsible for complete scalar, Unicode and number syntax.
private struct PortableJSONKeyScanner {
    let bytes: [UInt8]
    var position = 0
    init(data: Data) { bytes = Array(data) }

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard position == bytes.count else { throw PortableSettingsError.malformed }
    }
    private mutating func whitespace() {
        while position < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[position]) { position += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1; return true
    }
    private mutating func string() throws -> String {
        whitespace()
        guard position < bytes.count, bytes[position] == 34 else { throw PortableSettingsError.malformed }
        let start = position
        position += 1
        while position < bytes.count {
            let byte = bytes[position]; position += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
            if byte == 92 {
                guard position < bytes.count else { throw PortableSettingsError.malformed }
                position += 1
            }
        }
        throw PortableSettingsError.malformed
    }
    private mutating func value(depth: Int) throws {
        guard depth <= 16 else { throw PortableSettingsError.malformed }
        whitespace()
        guard position < bytes.count else { throw PortableSettingsError.malformed }
        switch bytes[position] {
        case 123:
            position += 1
            var keys = Set<String>()
            if take(125) { return }
            repeat {
                let key = try string()
                guard keys.insert(key).inserted, take(58) else { throw PortableSettingsError.malformed }
                try value(depth: depth + 1)
                if take(125) { return }
                guard take(44) else { throw PortableSettingsError.malformed }
            } while true
        case 91:
            position += 1
            if take(93) { return }
            repeat {
                try value(depth: depth + 1)
                if take(93) { return }
                guard take(44) else { throw PortableSettingsError.malformed }
            } while true
        case 34: _ = try string()
        default:
            let start = position
            while position < bytes.count, ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[position]) { position += 1 }
            guard position > start else { throw PortableSettingsError.malformed }
        }
    }
}
