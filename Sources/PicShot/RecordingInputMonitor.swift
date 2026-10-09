import AppKit
import ApplicationServices
import Carbon
import Combine

// Apple event-monitor semantics (main thread, global excludes own app, explicit removal):
// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html
// Secure input is observed only; never change another app's secure-input state:
// https://developer.apple.com/library/archive/technotes/tn2150/_index.html

struct RecordingInputPermissions: Equatable {
    var inputMonitoring: Bool
    var accessibility: Bool
    static let unknown = RecordingInputPermissions(inputMonitoring: false, accessibility: false)
}

/// No AX value, selected text, title, description, or application content is read.
/// An unrecognized/inaccessible focus is never accepted for shortcut display.
enum RecordingInputFocusContext: Equatable {
    case ordinary, secure, unknown

    static func classify(role: String?, subrole: String?, subroleReadable: Bool) -> Self {
        guard let role else { return .unknown }
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return .secure }
        guard subroleReadable else { return .unknown }
        let roles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXButton", "AXCheckBox",
            "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXTable", "AXOutline",
            "AXRow", "AXCell", "AXList", "AXImage", "AXScrollArea", "AXWebArea", "AXWindow", "AXGroup"]
        guard roles.contains(role) else { return .unknown }
        // Additional, unrecognized semantics must be inspected before allowing
        // them. The empty subrole is a documented absence, not a failed query.
        let subroles: Set<String> = ["", "AXSearchField", "AXStandardWindow", "AXDialog", "AXSystemDialog",
            "AXTableRow", "AXOutlineRow", "AXCloseButton", "AXMinimizeButton", "AXZoomButton"]
        guard subroles.contains(subrole ?? "") else { return .unknown }
        return .ordinary
    }
}

/// Only scalar input metadata crosses the native event boundary. Never retain
/// NSEvent/CGEvent objects or request event character strings.
struct RecordingInputObservation {
    enum Kind {
        case click(RecordingInputClickButton)
        case scroll(deltaX: CGFloat, deltaY: CGFloat)
        case shortcut(keyCode: UInt16, modifiers: RecordingShortcutModifiers)
    }
    var kind: Kind
    var point: CGPoint?
    var timestamp: TimeInterval
}

@MainActor
struct RecordingInputMonitorDependencies {
    var permissions: () -> RecordingInputPermissions
    var secureInputEnabled: () -> Bool
    var focusedContext: () -> RecordingInputFocusContext
    var install: (NSEvent.EventTypeMask, @escaping @MainActor (RecordingInputObservation) -> Void) -> Any?
    var remove: (Any) -> Void
    var scheduleHealthCheck: (@escaping @MainActor () -> Void) -> (() -> Void)
    var clock: () -> TimeInterval

    static var live: Self {
        Self(permissions: {
            RecordingInputPermissions(inputMonitoring: CGPreflightListenEventAccess(), accessibility: AXIsProcessTrusted())
        }, secureInputEnabled: { IsSecureEventInputEnabled() }, focusedContext: readFocusedContext,
        install: { mask, receive in
            // Apple documents both event-monitor handlers as main-thread calls.
            // Global monitoring intentionally excludes PicShot's own controls,
            // because those windows are already excluded from the movie.
            NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
                MainActor.assumeIsolated {
                    guard let observation = observation(from: event) else { return }
                    receive(observation)
                }
            }
        }, remove: { NSEvent.removeMonitor($0) }, scheduleHealthCheck: { check in
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { check() }
            }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }, clock: { ProcessInfo.processInfo.systemUptime })
    }

    private static func readFocusedContext() -> RecordingInputFocusContext {
        guard AXIsProcessTrusted() else { return .unknown }
        let system = AXUIElementCreateSystemWide()
        // Bound unresponsive third-party accessibility servers. Failure is a
        // privacy denial, never a reason to query text or broaden permissions.
        guard AXUIElementSetMessagingTimeout(system, 0.05) == .success else { return .unknown }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown }
        let focused = unsafeBitCast(value, to: AXUIElement.self)
        guard AXUIElementSetMessagingTimeout(focused, 0.05) == .success else { return .unknown }
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return .unknown }
        var subroleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subroleValue)
        let readable = result == .success || result == .attributeUnsupported || result == .noValue
        return .classify(role: role, subrole: subroleValue as? String, subroleReadable: readable)
    }

    private static func observation(from event: NSEvent) -> RecordingInputObservation? {
        let kind: RecordingInputObservation.Kind
        switch event.type {
        case .leftMouseDown: kind = .click(.left)
        case .rightMouseDown: kind = .click(.right)
        case .otherMouseDown: kind = .click(.other)
        case .scrollWheel: kind = .scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        case .keyDown:
            // Option-only and Shift-only combinations can produce normal text.
            // Reject those before even reading a key code or querying focus.
            guard !event.isARepeat, event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else { return nil }
            var modifiers: RecordingShortcutModifiers = []
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            guard let shortcut = RecordingInputShortcut(keyCode: event.keyCode, modifiers: modifiers) else { return nil }
            kind = .shortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
        default: return nil
        }
        // CGEvent retains the event's original location. NSEvent.mouseLocation
        // would instead attach a delayed click to the current cursor position.
        var point: CGPoint?
        if case .shortcut = kind { point = nil }
        else {
            guard let quartzPoint = event.cgEvent?.location,
                  let primary = NSScreen.screens.first(where: {
                      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
                  }) else { return nil }
            point = RecordingInputMonitor.appKitPoint(quartzPoint: quartzPoint, primaryScreenTop: primary.frame.maxY)
        }
        return RecordingInputObservation(kind: kind, point: point, timestamp: event.timestamp)
    }
}

/// Owns exactly one global monitor and one lightweight health timer while an
/// enabled, permitted recording is active. No event history lives here: only
/// the bounded, expiring value state is shared with preview and writer.
@MainActor
final class RecordingInputMonitor: ObservableObject {
    @Published var options = RecordingInputEffectsOptions() {
        didSet {
            guard options != oldValue else { return }
            state.setOptions(options)
            // Explicit opt-in may inspect current authorization while idle;
            // it still cannot install a monitor before recording starts.
            if options.isEnabled, sessionToken == nil || isPaused { permissions = dependencies.permissions() }
            rebuildMonitoring()
        }
    }
    @Published private(set) var permissions = RecordingInputPermissions.unknown
    @Published private(set) var isMonitoring = false
    @Published private(set) var privacySuppressed = false
    @Published private(set) var installationFailed = false
    private let state: RecordingInputEffectsState
    private let dependencies: RecordingInputMonitorDependencies
    private var monitor: Any?
    private var cancelHealthCheck: (() -> Void)?
    private var generation = UUID()
    private var sessionToken: UUID?
    private var frame: CGRect = .zero
    private var isPaused = false
    private var acceptingEventsSince: TimeInterval = 0

    init(state: RecordingInputEffectsState, dependencies: RecordingInputMonitorDependencies? = nil) {
        self.state = state
        self.dependencies = dependencies ?? .live
        // Construction and default-off sessions do not install observers,
        // check global permissions, or request any OS authorization.
    }

    func beginSession(frame: CGRect, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        endSession()
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, time.isFinite, time >= 0 else { return }
        self.frame = frame
        sessionToken = state.beginSession(options: options, at: time)
        rebuildMonitoring()
    }

    func setPaused(_ paused: Bool, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard sessionToken != nil else { return }
        isPaused = paused
        removeMonitoring()
        state.setPaused(paused, at: time)
        if !paused { rebuildMonitoring() }
    }

    func endSession() {
        removeMonitoring()
        sessionToken = nil; frame = .zero; isPaused = false
        privacySuppressed = false; installationFailed = false
        state.endSession()
    }

    /// Read-only refresh. OS permission prompts/settings changes are never
    /// invoked here or by any recording lifecycle path.
    func refreshPermissions() {
        let latest = dependencies.permissions()
        let changed = latest != permissions
        if changed { state.clearEvents(at: dependencies.clock()) }
        permissions = latest
        if sessionToken != nil, !isPaused, options.isEnabled, changed || installationFailed || !isMonitoring { rebuildMonitoring() }
    }

    private func rebuildMonitoring() {
        removeMonitoring()
        installationFailed = false
        guard sessionToken != nil, !isPaused, options.isEnabled else { return }
        let latest = dependencies.permissions()
        if latest != permissions { state.clearEvents(at: dependencies.clock()) }
        permissions = latest
        // Conservatively require current Input Monitoring permission even for
        // mouse events; global key monitoring additionally requires AX trust.
        guard permissions.inputMonitoring else { state.clearEvents(at: dependencies.clock()); return }
        var mask: NSEvent.EventTypeMask = []
        if options.clicks { mask.formUnion([.leftMouseDown, .rightMouseDown, .otherMouseDown]) }
        if options.scrolls { mask.insert(.scrollWheel) }
        if options.shortcuts, permissions.accessibility { mask.insert(.keyDown) }
        guard !mask.isEmpty else { state.clearEvents(at: dependencies.clock()); return }
        let installedGeneration = generation
        acceptingEventsSince = dependencies.clock()
        monitor = dependencies.install(mask) { [weak self] observation in
            self?.receive(observation, generation: installedGeneration)
        }
        guard monitor != nil else { installationFailed = true; state.clearEvents(at: dependencies.clock()); return }
        isMonitoring = true
        cancelHealthCheck = dependencies.scheduleHealthCheck { [weak self] in
            guard let self, self.generation == installedGeneration else { return }
            self.checkHealth()
        }
    }

    private func removeMonitoring() {
        // Invalidate before remove: queued/injected callbacks from an older
        // generation cannot repopulate state after pause, stop, or re-enable.
        generation = UUID()
        if let monitor { dependencies.remove(monitor) }
        monitor = nil
        cancelHealthCheck?(); cancelHealthCheck = nil
        isMonitoring = false
    }

    private func checkHealth() {
        guard sessionToken != nil, !isPaused, options.isEnabled else { return }
        let current = dependencies.permissions()
        if current != permissions {
            permissions = current; state.clearEvents(at: dependencies.clock()); rebuildMonitoring(); return
        }
        if dependencies.secureInputEnabled() {
            privacySuppressed = true; state.clearEvents(at: dependencies.clock())
        } else if options.shortcuts, permissions.accessibility {
            privacySuppressed = dependencies.focusedContext() != .ordinary
            if privacySuppressed { state.clearEvents(at: dependencies.clock()) }
        } else { privacySuppressed = false }
    }

    private func receive(_ observation: RecordingInputObservation, generation observedGeneration: UUID) {
        guard observedGeneration == generation, isMonitoring, !isPaused, let token = sessionToken,
              observation.timestamp.isFinite, observation.timestamp >= acceptingEventsSince else { return }
        let now = dependencies.clock()
        guard now.isFinite, observation.timestamp <= now + 0.01,
              now - observation.timestamp <= RecordingInputEffectsState.maximumLifetime else { return }
        // Recheck permission at the observation boundary as well as on the
        // timer. Revocation must not admit one final callback into the movie.
        let current = dependencies.permissions()
        guard current == permissions else {
            permissions = current; state.clearEvents(at: dependencies.clock()); rebuildMonitoring(); return
        }
        guard !dependencies.secureInputEnabled() else {
            privacySuppressed = true; state.clearEvents(at: dependencies.clock()); return
        }
        switch observation.kind {
        case .click(let button):
            guard options.clicks, let point = normalizedPoint(observation.point) else { return }
            state.recordClick(button: button, normalizedPoint: point, at: observation.timestamp, token: token)
        case .scroll(let deltaX, let deltaY):
            guard options.scrolls, let point = normalizedPoint(observation.point) else { return }
            state.recordScroll(deltaX: deltaX, deltaY: deltaY, normalizedPoint: point, at: observation.timestamp, token: token)
        case .shortcut(let keyCode, let modifiers):
            guard options.shortcuts, permissions.accessibility,
                  modifiers.contains(.command) || modifiers.contains(.control) else { return }
            privacySuppressed = dependencies.focusedContext() != .ordinary
            guard !privacySuppressed else { state.clearEvents(at: dependencies.clock()); return }
            state.recordShortcut(keyCode: keyCode, modifiers: modifiers, at: observation.timestamp, token: token)
        }
    }

    private func normalizedPoint(_ point: CGPoint?) -> CGPoint? {
        guard let point, point.x.isFinite, point.y.isFinite, frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    nonisolated static func appKitPoint(quartzPoint: CGPoint, primaryScreenTop: CGFloat) -> CGPoint {
        CGPoint(x: quartzPoint.x, y: primaryScreenTop - quartzPoint.y)
    }

    deinit {
        // Normal stop/close paths tear down synchronously. This is only a
        // defensive fallback; callbacks capture the owner weakly.
        let dependencies = dependencies, monitor = monitor, cancelHealthCheck = cancelHealthCheck
        state.endSession()
        Task { @MainActor in
            if let monitor { dependencies.remove(monitor) }
            cancelHealthCheck?()
        }
    }
}
