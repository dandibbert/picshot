import Foundation

public enum AppAppearancePreference: String, CaseIterable, Sendable {
    case system, light, dark
    public static let preferenceKey = "appAppearance"
    public static func read(from defaults: UserDefaults) -> AppAppearancePreference {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }
    public func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.preferenceKey) }
}

public struct HistoryRetentionPreferences: Equatable, Sendable {
    public var days: Int
    public var count: Int
    public var megabytes: Int
    public init(days: Int = 30, count: Int = 200, megabytes: Int = 1024) {
        self.days = days; self.count = count; self.megabytes = megabytes
    }
    public var isValid: Bool { (1...3650).contains(days) && (1...10000).contains(count) && (1...102400).contains(megabytes) }
    public static func read(from defaults: UserDefaults) -> HistoryRetentionPreferences {
        func positive(_ key: String, fallback: Int) -> Int {
            let value = defaults.integer(forKey: key); return value > 0 ? value : fallback
        }
        return HistoryRetentionPreferences(days: positive("historyDays", fallback: 30), count: positive("historyCount", fallback: 200), megabytes: positive("historyMB", fallback: 1024))
    }
    /// Validation belongs before any preference write, so a malformed field cannot partially save.
    public func save(to defaults: UserDefaults) -> Bool {
        guard isValid else { return false }
        defaults.set(days, forKey: "historyDays"); defaults.set(count, forKey: "historyCount"); defaults.set(megabytes, forKey: "historyMB")
        return true
    }
}

/// The numerator reflects actual live windows, rather than persisted launch-restoration intent.
/// The denominator includes all stored items in the group, including archived history.
public struct PinGroupMenuSummary: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let color: PinGroupColor
    public let isCurrent: Bool
    public let visibleCount: Int
    public let historyCount: Int
    public var countLabel: String { "\(visibleCount)/\(historyCount)" }
    public static func make(index: PinSessionIndex, livePinIDs: Set<UUID>) -> [PinGroupMenuSummary] {
        index.groups.map { group in
            let entries = index.entries.filter { $0.groupID == group.id }
            return PinGroupMenuSummary(id: group.id, name: group.name, color: group.color,
                                       isCurrent: group.id == index.activeGroupID,
                                       visibleCount: entries.filter { livePinIDs.contains($0.id) }.count,
                                       historyCount: entries.count)
        }
    }
}

public enum AppLaunchPresentation {
    public static func showsHistory(isSmoke: Bool) -> Bool { isSmoke }
    public static func usesMenuBarOnly(isSmoke: Bool) -> Bool { !isSmoke }
}
