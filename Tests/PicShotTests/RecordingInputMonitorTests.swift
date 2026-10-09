import XCTest
import AppKit
@testable import PicShot

@MainActor
final class RecordingInputMonitorTests: XCTestCase {
    private let frame = CGRect(x: -1_000, y: -400, width: 600, height: 400)

    func testDefaultOffNeverProbesAndIdleOptInNeverInstallsGlobalInput() {
        let fixture = InputMonitorFixture()
        let state = RecordingInputEffectsState()
        let monitor = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        XCTAssertFalse(monitor.options.isEnabled)
        XCTAssertEqual(fixture.permissionChecks, 0)
        monitor.beginSession(frame: frame, at: fixture.now)
        XCTAssertEqual(fixture.permissionChecks, 0)
        XCTAssertTrue(fixture.masks.isEmpty)
        XCTAssertTrue(fixture.healthCallbacks.isEmpty)
        monitor.endSession()
        monitor.options.clicks = true
        XCTAssertEqual(fixture.permissionChecks, 1, "Explicit idle opt-in may inspect existing permission, without installing a monitor")
        XCTAssertTrue(fixture.masks.isEmpty)
    }

    func testDeniedPermissionFailsClosedWithoutInstallingOrScheduling() {
        let fixture = InputMonitorFixture()
        fixture.permissions = .init(inputMonitoring: false, accessibility: false)
        let state = RecordingInputEffectsState()
        let monitor = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        monitor.options = .init(clicks: true, scrolls: true, shortcuts: true)
        monitor.beginSession(frame: frame, at: fixture.now)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(monitor.permissions, fixture.permissions)
        XCTAssertTrue(fixture.masks.isEmpty)
        XCTAssertTrue(fixture.healthCallbacks.isEmpty)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        // No permission-request function exists on the injected boundary. A
        // later user-triggered check can observe a grant without requesting it.
        fixture.permissions = .init(inputMonitoring: true, accessibility: true)
        monitor.refreshPermissions()
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertEqual(fixture.masks.count, 1)
        monitor.endSession()
    }

    func testMissingAccessibilityInstallsOnlyRequestedPointerCategories() {
        let fixture = InputMonitorFixture()
        fixture.permissions.accessibility = false
        let monitor = RecordingInputMonitor(state: RecordingInputEffectsState(), dependencies: fixture.dependencies)
        monitor.options = .init(clicks: false, scrolls: true, shortcuts: true)
        monitor.beginSession(frame: frame, at: fixture.now)
        XCTAssertEqual(fixture.masks, [.scrollWheel])
        XCTAssertTrue(monitor.isMonitoring)
        monitor.options = .init(shortcuts: true)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(fixture.removed.count, 1)
        XCTAssertEqual(fixture.cancelledHealthChecks, 1)
        monitor.endSession()
    }

    func testNegativeDisplayCoordinatesUseOriginalEventPointAndIgnoreOutsideRegion() throws {
        let fixture = InputMonitorFixture()
        let state = RecordingInputEffectsState()
        let monitor = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        monitor.options.clicks = true
        monitor.beginSession(frame: frame, at: fixture.now)
        // The primary's top is 900 logical points. This click lies on a screen
        // below and left of it, independently of that display's Retina scale.
        let capturedPoint = RecordingInputMonitor.appKitPoint(quartzPoint: CGPoint(x: -700, y: 1_100), primaryScreenTop: 900)
        XCTAssertEqual(capturedPoint, CGPoint(x: -700, y: -200))
        fixture.now = 100.4
        fixture.emit(.init(kind: .click(.right), point: capturedPoint, timestamp: 100.1))
        fixture.emit(.init(kind: .click(.left), point: CGPoint(x: 20, y: 20), timestamp: 100.2))
        fixture.emit(.init(kind: .click(.left), point: CGPoint(x: -CGFloat.infinity, y: -200), timestamp: 100.3))
        let event = try XCTUnwrap(state.snapshot(at: fixture.now).events.only)
        XCTAssertEqual(event.timestamp, 100.1, "Delayed callback must preserve capture time")
        XCTAssertEqual(event.kind, .click(button: .right, normalizedPoint: CGPoint(x: 0.5, y: 0.5)))
        monitor.endSession()
    }

    func testPauseResumeAndEndInvalidateOldCallbacksAndClearEvents() {
        let fixture = InputMonitorFixture()
        let state = RecordingInputEffectsState()
        let monitor = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        monitor.options.clicks = true
        monitor.beginSession(frame: frame, at: fixture.now)
        fixture.now = 100.1; fixture.emit(click(at: fixture.now))
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)
        fixture.now = 100.2; monitor.setPaused(true, at: fixture.now)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(fixture.removed.count, 1)
        XCTAssertEqual(fixture.cancelledHealthChecks, 1)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        fixture.emit(click(at: fixture.now), callback: 0)
        fixture.healthCallbacks[0]()
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        fixture.now = 101; monitor.setPaused(false, at: fixture.now)
        fixture.now = 101.1
        fixture.emit(click(at: 101.1), callback: 0)
        fixture.emit(click(at: 100.5), callback: 1)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty, "Both retired callbacks and input captured during pause are rejected")
        fixture.emit(click(at: fixture.now), callback: 1)
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)
        monitor.endSession()
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(fixture.removed.count, 2)
        XCTAssertEqual(fixture.cancelledHealthChecks, 2)
        fixture.emit(click(at: 101.1), callback: 1)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
    }

    func testRestartAndDisableCannotReviveAnOlderGeneration() {
        let fixture = InputMonitorFixture()
        let state = RecordingInputEffectsState()
        let monitor = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        monitor.options.clicks = true
        monitor.beginSession(frame: frame, at: fixture.now)
        monitor.options = .init()
        XCTAssertFalse(monitor.isMonitoring)
        fixture.now = 101; fixture.emit(click(at: 101), callback: 0)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        monitor.options.clicks = true
        fixture.now = 102; monitor.beginSession(frame: frame, at: fixture.now)
        fixture.now = 102.1
        fixture.emit(click(at: fixture.now), callback: 0)
        fixture.emit(click(at: fixture.now), callback: 1)
        fixture.healthCallbacks[0]()
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        fixture.emit(click(at: fixture.now), callback: 2)
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)
        monitor.endSession()
    }

    func testPermissionRevocationAtCallbackAndHealthCheckRemovesMonitor() {
        let fixture = InputMonitorFixture()
        let state = RecordingInputEffectsState()
        let monitor = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        monitor.options.clicks = true
        monitor.beginSession(frame: frame, at: fixture.now)
        fixture.now = 100.1; fixture.emit(click(at: fixture.now))
        fixture.permissions.inputMonitoring = false
        fixture.now = 100.2; fixture.emit(click(at: fixture.now))
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(fixture.removed.count, 1)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        fixture.permissions.inputMonitoring = true; monitor.refreshPermissions()
        XCTAssertTrue(monitor.isMonitoring)
        fixture.now = 100.3; fixture.emit(click(at: fixture.now))
        fixture.permissions.inputMonitoring = false
        fixture.healthCallbacks.last?()
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(fixture.removed.count, 2)
        XCTAssertEqual(fixture.cancelledHealthChecks, 2)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        monitor.endSession()

        // Explicit refresh can observe AX revocation before a callback or health
        // tick. Pointer monitoring stays permitted, but its new generation must
        // not keep compositing a shortcut captured before revocation.
        fixture.permissions = .init(inputMonitoring: true, accessibility: true)
        fixture.now = 200
        monitor.options = .init(clicks: true, shortcuts: true)
        monitor.beginSession(frame: frame, at: fixture.now)
        fixture.now = 200.1; fixture.emit(shortcut(at: fixture.now))
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)
        let retiredCallback = fixture.callbacks.count - 1
        fixture.permissions.accessibility = false
        fixture.now = 200.2; monitor.refreshPermissions()
        XCTAssertFalse(monitor.permissions.accessibility)
        XCTAssertTrue(monitor.isMonitoring, "Permitted pointer monitoring continues")
        XCTAssertFalse(fixture.masks.last?.contains(.keyDown) ?? true)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty,
                      "Future compositions must not retain a pre-revocation shortcut")
        fixture.healthCallbacks.last?()
        fixture.emit(shortcut(at: fixture.now), callback: retiredCallback)
        fixture.emit(shortcut(at: fixture.now))
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        fixture.now = 200.3; fixture.emit(click(at: fixture.now))
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)

        // An option-driven reinstall also probes permissions. setOptions alone
        // retains shortcuts because their user preference is still enabled.
        fixture.permissions.accessibility = true
        monitor.refreshPermissions()
        fixture.now = 200.4; fixture.emit(shortcut(at: fixture.now))
        XCTAssertTrue(state.snapshot(at: fixture.now).events.contains {
            if case .shortcut = $0.kind { return true }
            return false
        })
        fixture.permissions.accessibility = false
        fixture.now = 200.5; monitor.options.scrolls = true
        XCTAssertFalse(monitor.permissions.accessibility)
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertFalse(fixture.masks.last?.contains(.keyDown) ?? true)
        XCTAssertTrue(fixture.masks.last?.contains(.scrollWheel) ?? false)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty,
                      "Permission changes detected during reinstall must also clear old effects")
        fixture.now = 200.6; fixture.emit(click(at: fixture.now))
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)
        monitor.endSession()
    }

    func testSecureAndUnknownFocusSuppressShortcutsAndDiscardTheirQueuedEvents() {
        let fixture = InputMonitorFixture()
        let state = RecordingInputEffectsState()
        let monitor = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        monitor.options = .init(clicks: true, shortcuts: true)
        monitor.beginSession(frame: frame, at: fixture.now)
        fixture.now = 100.1; fixture.emit(shortcut(at: fixture.now))
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)
        fixture.focus = .secure
        fixture.now = 100.2; fixture.emit(shortcut(at: fixture.now))
        XCTAssertTrue(monitor.privacySuppressed)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        fixture.focus = .unknown
        fixture.now = 100.3; fixture.emit(shortcut(at: fixture.now))
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        fixture.focus = .ordinary
        fixture.now = 100.4; fixture.emit(shortcut(at: 100.25))
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty, "Context clear advances event acceptance boundary")
        fixture.emit(shortcut(at: fixture.now))
        XCTAssertFalse(monitor.privacySuppressed)
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)
        fixture.secureInput = true
        fixture.now = 100.5; fixture.emit(click(at: fixture.now))
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty, "System secure input suppresses all new effects")
        fixture.secureInput = false
        fixture.now = 100.6; fixture.emit(shortcut(at: fixture.now))
        fixture.focus = .secure
        fixture.healthCallbacks.last?()
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty, "Health check clears a badge when focus changes without a new key")
        monitor.endSession()
    }

    func testOrdinaryTypingOptionTextAndUnknownKeyCodesNeverBecomeEffects() {
        let fixture = InputMonitorFixture()
        let state = RecordingInputEffectsState()
        let monitor = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        monitor.options.shortcuts = true
        monitor.beginSession(frame: frame, at: fixture.now)
        fixture.now = 100.1
        let typingModifiers: [RecordingShortcutModifiers] = [[], .shift, .option, [.option, .shift]]
        for flags in typingModifiers {
            fixture.emit(.init(kind: .shortcut(keyCode: 0, modifiers: flags), point: nil, timestamp: fixture.now))
        }
        fixture.emit(.init(kind: .shortcut(keyCode: 65_535, modifiers: .command), point: nil, timestamp: fixture.now))
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        fixture.emit(shortcut(at: fixture.now))
        XCTAssertEqual(state.snapshot(at: fixture.now).events.count, 1)
        monitor.endSession()
    }

    func testFocusRolePolicyFailsClosedWithoutReadingAnyContent() {
        XCTAssertEqual(RecordingInputFocusContext.classify(role: "AXTextField", subrole: "AXSecureTextField", subroleReadable: true), .secure)
        XCTAssertEqual(RecordingInputFocusContext.classify(role: "AXSecureTextField", subrole: nil, subroleReadable: false), .secure)
        XCTAssertEqual(RecordingInputFocusContext.classify(role: nil, subrole: nil, subroleReadable: false), .unknown)
        XCTAssertEqual(RecordingInputFocusContext.classify(role: "CustomPasswordControl", subrole: nil, subroleReadable: true), .unknown)
        XCTAssertEqual(RecordingInputFocusContext.classify(role: "AXTextField", subrole: "CustomPrivateField", subroleReadable: true), .unknown)
        XCTAssertEqual(RecordingInputFocusContext.classify(role: "AXTextField", subrole: nil, subroleReadable: false), .unknown)
        XCTAssertEqual(RecordingInputFocusContext.classify(role: "AXTextField", subrole: nil, subroleReadable: true), .ordinary)
        XCTAssertEqual(RecordingInputFocusContext.classify(role: "AXTextArea", subrole: "", subroleReadable: true), .ordinary)
    }

    func testFailedInstallationCanBeExplicitlyRetriedAndInvalidFramesNeverInstall() {
        let fixture = InputMonitorFixture()
        let monitor = RecordingInputMonitor(state: RecordingInputEffectsState(), dependencies: fixture.dependencies)
        monitor.options.clicks = true
        monitor.beginSession(frame: .zero, at: fixture.now)
        monitor.beginSession(frame: frame, at: .nan)
        XCTAssertTrue(fixture.masks.isEmpty)
        fixture.installSucceeds = false
        monitor.beginSession(frame: frame, at: fixture.now)
        XCTAssertTrue(monitor.installationFailed)
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertTrue(fixture.healthCallbacks.isEmpty)
        fixture.installSucceeds = true
        monitor.refreshPermissions()
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertFalse(monitor.installationFailed)
        monitor.endSession()
    }

    func testNativeCallbacksDoNotRetainOwnerAndFallbackDeinitClearsState() async throws {
        let fixture = InputMonitorFixture()
        let state = RecordingInputEffectsState()
        var monitor: RecordingInputMonitor? = RecordingInputMonitor(state: state, dependencies: fixture.dependencies)
        weak var owner = monitor
        monitor?.options.clicks = true
        monitor?.beginSession(frame: frame, at: fixture.now)
        fixture.now = 100.1; fixture.emit(click(at: fixture.now))
        monitor = nil
        XCTAssertNil(owner)
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
        // Defensive cleanup dispatches to the main actor if the final owner is
        // released off-actor. Normal lifecycle teardown is synchronous above.
        for _ in 0..<100 where fixture.removed.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(fixture.removed.count, 1)
        XCTAssertEqual(fixture.cancelledHealthChecks, 1)
        fixture.emit(click(at: fixture.now))
        fixture.healthCallbacks[0]()
        XCTAssertTrue(state.snapshot(at: fixture.now).events.isEmpty)
    }

    private func click(at time: TimeInterval) -> RecordingInputObservation {
        .init(kind: .click(.left), point: CGPoint(x: -700, y: -200), timestamp: time)
    }
    private func shortcut(at time: TimeInterval) -> RecordingInputObservation {
        .init(kind: .shortcut(keyCode: 8, modifiers: .command), point: nil, timestamp: time)
    }
}

@MainActor
private final class InputMonitorFixture {
    var permissions = RecordingInputPermissions(inputMonitoring: true, accessibility: true)
    var permissionChecks = 0
    var secureInput = false
    var focus = RecordingInputFocusContext.ordinary
    var installSucceeds = true
    var now: TimeInterval = 100
    var masks: [NSEvent.EventTypeMask] = []
    var callbacks: [@MainActor (RecordingInputObservation) -> Void] = []
    var removed: [Int] = []
    var healthCallbacks: [@MainActor () -> Void] = []
    var cancelledHealthChecks = 0

    var dependencies: RecordingInputMonitorDependencies {
        .init(permissions: { self.permissionChecks += 1; return self.permissions },
            secureInputEnabled: { self.secureInput }, focusedContext: { self.focus },
            install: { mask, callback in
                self.masks.append(mask); self.callbacks.append(callback)
                return self.installSucceeds ? self.callbacks.count as Any : nil
            }, remove: { self.removed.append($0 as! Int) },
            scheduleHealthCheck: { callback in
                self.healthCallbacks.append(callback)
                return { self.cancelledHealthChecks += 1 }
            }, clock: { self.now })
    }

    func emit(_ observation: RecordingInputObservation, callback index: Int? = nil) {
        callbacks[index ?? callbacks.count - 1](observation)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
