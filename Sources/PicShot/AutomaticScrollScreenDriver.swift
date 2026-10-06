import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import PicShotCore

/// The only production input emitter. It never requests or changes Accessibility access,
/// activates another app, moves the pointer, clicks, or posts before the coordinator starts.
@MainActor
final class AutomaticScrollScreenDriver: AutomaticScrollDriver {
    let displayID: CGDirectDisplayID
    let region: CGRect // Display-local logical points, top-left origin.
    let displayBounds: CGRect
    let screenSize: CGSize
    let targetPoint: CGPoint // Global Quartz logical coordinates, including negative origins.
    private let accept: (CGImage) async throws -> AutomaticScrollSample
    private var target: Target?

    struct Target: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        let bounds: CGRect
    }

    init(displayID: CGDirectDisplayID, region: CGRect, screenSize: CGSize,
         accept: @escaping (CGImage) async throws -> AutomaticScrollSample) throws {
        let bounds = CGDisplayBounds(displayID)
        let localBounds = CGRect(origin: .zero, size: screenSize)
        guard region.width >= 8, region.height >= 16, localBounds.contains(region),
              bounds.width == screenSize.width, bounds.height == screenSize.height else {
            throw CaptureError.invalidRegion
        }
        self.displayID = displayID
        self.region = region
        self.screenSize = screenSize
        displayBounds = bounds
        targetPoint = try AutomaticScrollGeometry.targetPoint(region: region, displayBounds: bounds)
        self.accept = accept
    }

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    func checkPermission() throws {
        guard Self.hasAccessibilityPermission else {
            throw CaptureError.failed("Automatic scrolling needs Accessibility access. Enable PicShot yourself in System Settings → Privacy & Security → Accessibility, then press Start again. Manual capture still works without it.")
        }
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.screenPermission }
    }

    func validateTarget() throws {
        try Task.checkCancellation()
        try checkPermission()
        guard CGDisplayBounds(displayID) == displayBounds,
              NSScreen.screens.contains(where: { $0.displayID == displayID && $0.frame.size == screenSize }) else {
            throw CaptureError.failed("The selected display changed or disconnected. Start a new scrolling capture.")
        }
        target = try Self.checkedTarget(windowAtTarget(), locked: target, at: targetPoint,
                                        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                        ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Window identity is a preflight safety check, not writable scroll-event metadata.
    /// Keep this policy separate from OS lookup so synthetic tests can exercise failures
    /// without activating apps, reading the screen, changing TCC, or posting input.
    static func checkedTarget(_ current: Target?, locked: Target?, at point: CGPoint,
                              frontmostPID: pid_t?, ownPID: pid_t) throws -> Target {
        guard let current, current.pid > 0, current.pid != ownPID,
              current.windowID != kCGNullWindowID,
              point.x.isFinite, point.y.isFinite,
              current.bounds.origin.x.isFinite, current.bounds.origin.y.isFinite,
              current.bounds.size.width.isFinite, current.bounds.size.height.isFinite,
              current.bounds.size.width > 0, current.bounds.size.height > 0,
              current.bounds.contains(point), frontmostPID == current.pid else {
            throw CaptureError.failed("The target app must be frontmost, with the center of the selected region unobstructed. Return to it during the countdown, or use manual capture.")
        }
        if let locked, locked != current {
            throw CaptureError.failed("The target window moved, changed, or was covered. Automatic input stopped. Accepted frames are safe; start over or continue manually.")
        }
        return current
    }

    func scroll(axis: ScrollAxis, points: Int) throws {
        try validateTarget()
        guard let target else { throw CaptureError.invalidRegion }
        let event = try Self.makeScrollEvent(axis: axis, points: points, location: targetPoint)
        // postToPid selects the validated process, while location carries the fixed target
        // point. The window ID is checked above, not encoded in mouse-specific CGEvent
        // fields: native scroll-wheel construction ignores those fields. How each app
        // routes this event to a view still requires live-app acceptance testing.
        event.postToPid(target.pid)
    }

    static func makeScrollEvent(axis: ScrollAxis, points: Int, location: CGPoint) throws -> CGEvent {
        guard (1...240).contains(points), location.x.isFinite, location.y.isFinite,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: axis == .vertical ? -Int32(points) : 0,
                                  wheel2: axis == .horizontal ? -Int32(points) : 0, wheel3: 0) else {
            throw CaptureError.failed("The bounded scroll event could not be created.")
        }
        event.location = location
        event.flags = []
        return event
    }

    func capture() async throws -> AutomaticScrollSample {
        try validateTarget()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        // Excluding PicShot permits visible nonactivating Pause/Stop controls without
        // burning those controls into the screenshot or hiding the target application.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApps.isEmpty else {
            throw CaptureError.failed("PicShot could not exclude its controls from the screenshot. Automatic capture stopped; use manual capture instead.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        try validateTarget()
        let pixels = try AutomaticScrollGeometry.pixelRect(region: region, logicalSize: screenSize,
                                                           pixelWidth: image.width, pixelHeight: image.height)
        guard let crop = image.cropping(to: pixels) else { throw CaptureError.invalidRegion }
        return try await accept(crop)
    }

    private func windowAtTarget() -> Target? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Window server order is front-to-back. Never skip a popup/own window over the
        // target to pretend that input would reach the intended underlying window.
        for window in windows {
            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary), bounds.contains(targetPoint),
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01 else { continue }
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let identifier = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return Target(pid: pid, windowID: identifier, bounds: bounds)
        }
        return nil
    }
}

/// Nonactivating controls keep the selected application frontmost. Closing the HUD is Stop.
@MainActor
final class AutomaticScrollControls: NSWindowController, NSWindowDelegate {
    var pauseOrResume: (() -> Void)?
    var stop: (() -> Void)?
    private let label = NSTextField(labelWithString: "Starting…")
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    init(targetPoint: CGPoint, displayBounds: CGRect) {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 90),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "PicShot · Automatic scrolling"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        pauseButton.target = self; pauseButton.action = #selector(togglePause)
        stopButton.target = self; stopButton.action = #selector(stopPressed)
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [label, pauseButton, stopButton])
        row.orientation = .horizontal; row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                row.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
        }
        // Quartz → AppKit, using the primary display's logical height (not NSScreen.main,
        // which follows focus). Choose the opposite edge from the fixed target point.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let above = targetPoint.y > displayBounds.midY
        let quartzY = above ? displayBounds.minY + 12 : displayBounds.maxY - panel.frame.height - 12
        let quartzX = max(displayBounds.minX, displayBounds.maxX - panel.frame.width - 12)
        panel.setFrameOrigin(CGPoint(x: quartzX, y: primaryHeight - quartzY - panel.frame.height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(text: String, paused: Bool, canResume: Bool) {
        label.stringValue = text
        pauseButton.title = paused ? "Resume (3s)" : "Pause"
        pauseButton.isEnabled = !paused || canResume
    }
    @objc private func togglePause() { pauseOrResume?() }
    @objc private func stopPressed() { stop?() }
    func windowWillClose(_ notification: Notification) { stop?() }
}
