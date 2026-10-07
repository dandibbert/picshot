import Foundation

/// Global policy for managed pins, not a persisted identifier for a macOS Space.
/// Existing installs have no key and retain their previous all-desktops behavior.
public enum PinDesktopVisibility: String, CaseIterable, Sendable {
    case allDesktops
    case currentDesktop

    public static let preferenceKey = "pinDesktopVisibility"
    public static let defaultMode: Self = .allDesktops

    public static func read(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? defaultMode
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}
