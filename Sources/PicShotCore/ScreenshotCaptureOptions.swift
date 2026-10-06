import Foundation

public enum ScreenshotDelay: Int, CaseIterable, Sendable {
    case none = 0, threeSeconds = 3, fiveSeconds = 5, tenSeconds = 10

    /// A task-owned, cancellation-aware delay. No screen access, timer, or detached
    /// task is created. Cancellation must also be checked by the capture afterward.
    public func wait() async throws {
        try await wait { nanoseconds in try await Task.sleep(nanoseconds: nanoseconds) }
    }

    func wait(sleep: (UInt64) async throws -> Void) async throws {
        try Task.checkCancellation()
        if rawValue > 0 { try await sleep(UInt64(rawValue) * 1_000_000_000) }
        try Task.checkCancellation()
    }
}

public struct ScreenshotCaptureOptions: Equatable, Sendable {
    public var delay: ScreenshotDelay
    /// Applied only to display and all-display ScreenCaptureKit screenshots.
    /// The system region/window selector retains its existing cursor behavior.
    public var showsCursor: Bool
    public init(delay: ScreenshotDelay = .none, showsCursor: Bool = false) {
        self.delay = delay
        self.showsCursor = showsCursor
    }
}

public enum ScreenshotPreferences {
    public static let delayKey = "screenshotDelaySeconds"
    public static let cursorKey = "screenshotShowsCursor"

    public static var options: ScreenshotCaptureOptions {
        get { read(from: .standard) }
        set { save(newValue, to: .standard) }
    }

    public static func read(from defaults: UserDefaults) -> ScreenshotCaptureOptions {
        ScreenshotCaptureOptions(delay: ScreenshotDelay(rawValue: defaults.integer(forKey: delayKey)) ?? .none,
                                 showsCursor: defaults.bool(forKey: cursorKey))
    }

    public static func save(_ options: ScreenshotCaptureOptions, to defaults: UserDefaults) {
        defaults.set(options.delay.rawValue, forKey: delayKey)
        defaults.set(options.showsCursor, forKey: cursorKey)
    }
}
