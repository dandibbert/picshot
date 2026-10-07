import Foundation

/// One saved, default-off choice. Nil defaults keeps fixtures entirely in memory.
@MainActor final class PinOCRPreferences {
    static let automaticPreferenceKey = "pins.automaticallyRecognizeText"
    nonisolated static var applicationDefaults: UserDefaults? {
        ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] == nil ? .standard : nil
    }
    let defaults: UserDefaults?
    private(set) var automaticallyRecognizeText: Bool
    init(defaults: UserDefaults? = PinOCRPreferences.applicationDefaults, initialValue: Bool = false) {
        self.defaults = defaults
        automaticallyRecognizeText = defaults?.bool(forKey: Self.automaticPreferenceKey) ?? initialValue
    }
    func select(_ enabled: Bool) {
        automaticallyRecognizeText = enabled
        defaults?.set(enabled, forKey: Self.automaticPreferenceKey)
    }
    func reload() {
        if let defaults { automaticallyRecognizeText = defaults.bool(forKey: Self.automaticPreferenceKey) }
    }
}
