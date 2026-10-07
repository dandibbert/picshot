import AppKit
import PicShotCore

@MainActor
struct MultiWindowCaptureProviders {
    var permission: () throws -> Void
    var screens: () -> [MultiWindowSelectionScreen]
    var inventory: ([MultiWindowSelectionScreen]) throws -> [MultiWindowDescriptor]
    var displayValidator: () throws -> (() throws -> Void)
    var frame: (MultiWindowDescriptor, TimeInterval) async throws -> CGImage

    static var live: Self {
        Self(permission: {
            // Never grants or changes TCC; the existing capture permission message
            // explains the required screen recording permission to the user.
            guard CGPreflightScreenCaptureAccess() else { throw CaptureError.screenPermission }
        }, screens: { MultiWindowSelectionScreen.current() }, inventory: { try MultiWindowInventory.current(screens: $0) }, displayValidator: {
            let watcher = try DisplayConfigurationWatcher(), snapshot = DisplaySystemSnapshot.current()
            return { try watcher.validate(snapshot: snapshot) }
        }, frame: { try await MultiWindowScreenshotCommand.capture($0, deadline: $1) })
    }
}

@MainActor
final class MultiWindowCaptureController {
    private var sessionID: UUID?
    private(set) var activeSelector: MultiWindowSelectionController?
    private let providers: MultiWindowCaptureProviders
    init(providers: MultiWindowCaptureProviders? = nil) { self.providers = providers ?? .live }

    func capture(options: ScreenshotCaptureOptions = .init()) async throws -> CGImage {
        guard sessionID == nil else { throw CaptureError.busy }
        sessionID = UUID()
        defer { activeSelector?.cancel(); activeSelector = nil; sessionID = nil }
        try await options.delay.wait()
        try Task.checkCancellation(); try providers.permission()
        let validateDisplay = try providers.displayValidator()
        let screens = providers.screens()
        guard !screens.isEmpty else { throw CaptureError.noDisplay }
        let windows = try providers.inventory(screens)
        guard !windows.isEmpty else { throw MultiWindowCaptureError.noWindows }
        // Cursor preferences are intentionally not claimed for individual window
        // capture. Only selected window content enters the transparent canvas.
        let validateSelection: () throws -> Void = {
            try Task.checkCancellation(); try validateDisplay(); try self.providers.permission()
            let current = try self.providers.inventory(screens)
            guard self.providers.screens() == screens, current.count == windows.count,
                  zip(current, windows).allSatisfy({ pair in pair.0.matchesSource(pair.1) }) else { throw MultiWindowCaptureError.changed }
        }
        let selector = MultiWindowSelectionController(windows: windows, screens: screens, validate: validateSelection)
        activeSelector = selector
        let selected = try await selector.select()
        activeSelector = nil
        try Task.checkCancellation()
        let layout = try MultiWindowCaptureLayout(frontToBack: selected)
        let deadline = ProcessInfo.processInfo.systemUptime + MultiWindowCaptureLimits.acquisitionSeconds
        return try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline, validate: {
            try validateDisplay(); try self.providers.permission()
            guard self.providers.screens() == screens else { throw MultiWindowCaptureError.changed }
            try layout.validate(frontToBack: self.providers.inventory(screens))
        }, frame: providers.frame)
    }
}
