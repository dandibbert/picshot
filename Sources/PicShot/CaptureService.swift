import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import PicShotCore

/// Full Screen uses the pointer display; All Screens composites the desktop at a uniform density.
enum CaptureMode: String, CaseIterable, Identifiable {
    case region, fullScreen, allScreens, window
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: return "Region"
        case .fullScreen: return "Full Screen"
        case .allScreens: return "All Screens"
        case .window: return "Window"
        }
    }
}

enum CaptureError: LocalizedError {
    case cancelled, busy, screenPermission, noDisplay, invalidRegion, failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Capture cancelled."
        case .busy: return "A capture or selection is already in progress."
        case .screenPermission:
            return "Allow PicShot in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen PicShot if macOS asks. No screen content is captured until you start a capture."
        case .noDisplay: return "The selected display is no longer connected. Choose a display and try again."
        case .invalidRegion: return "Select a region at least 2 × 2 points inside one display."
        case .failed(let message): return "Couldn’t capture the screen: \(message)"
        }
    }
}

@MainActor
final class CaptureService {
    private var isCapturing = false
    private var selection: RegionSelectionController?

    /// Called only as a consequence of a user-initiated capture or recording action.
    static func requireScreenPermission() throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.screenPermission
        }
    }

    /// The default region flow owns both the immutable desktop and its crop.
    /// Other modes deliberately carry no guessed screen placement information.
    func captureForEditing(mode: CaptureMode, options: ScreenshotCaptureOptions = .init()) async throws -> CapturedImage {
        guard mode == .region else {
            return CapturedImage(image: try await capture(mode: mode, options: options), presentation: nil)
        }
        guard !isCapturing, selection == nil else { throw CaptureError.busy }
        isCapturing = true
        defer { isCapturing = false }
        try await options.delay.wait()
        try Task.checkCancellation()
        try Self.requireScreenPermission()
        try Task.checkCancellation()

        let watcher = try DisplayConfigurationWatcher()
        let snapshot = DisplaySystemSnapshot.current()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let displayID = screen.displayID else { throw CaptureError.noDisplay }
        let displayFrame = screen.frame
        let displayScale = screen.backingScaleFactor
        // Check hardware mode and SCK's descriptor before its screenshot request.
        // A frozen desktop is never acquired first and rejected only afterward.
        let mode = CGDisplayCopyDisplayMode(displayID)
        guard DisplayCompositeLayout.allowsSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID)),
              mode.map({ DisplayCompositeLayout.allowsSize(width: $0.pixelWidth, height: $0.pixelHeight) }) ?? true else {
            throw DisplayCompositeError.pixelLimit
        }
        let frozen = try await captureDisplayImmediately(displayID: displayID, showsCursor: options.showsCursor)
        let capturedAt = Date() // Freeze pixel-acquisition time before the user selects a region.
        try watcher.validate(snapshot: snapshot)
        guard let currentScreen = NSScreen.screens.first(where: { $0.displayID == displayID }),
              currentScreen.frame == displayFrame, currentScreen.backingScaleFactor == displayScale else {
            throw DisplayCompositeError.layoutChanged
        }
        let controller = RegionSelectionController(screen: currentScreen, frozenImage: frozen)
        selection = controller
        defer { selection = nil }
        let rectangle = try await controller.select()
        try Task.checkCancellation()
        try watcher.validate(snapshot: snapshot)
        return try CapturedImage.frozenRegion(image: frozen, displayID: displayID,
                                              displayFrame: displayFrame, selection: rectangle, capturedAt: capturedAt)
    }

    /// The caller owns this task and may cancel it during delay, selection, or SCK
    /// capture. No permission request or pixel access happens during the delay.
    /// Its legacy region path remains available as the explicit cross-display
    /// system-selector fallback; normal screenshots use captureForEditing.
    func capture(mode: CaptureMode, options: ScreenshotCaptureOptions = .init()) async throws -> CGImage {
        guard !isCapturing, selection == nil else { throw CaptureError.busy }
        isCapturing = true
        defer { isCapturing = false }
        try await options.delay.wait()
        try Task.checkCancellation()
        try Self.requireScreenPermission()
        try Task.checkCancellation()
        switch mode {
        case .fullScreen:
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            guard let displayID = screen?.displayID else { throw CaptureError.noDisplay }
            return try await captureDisplayImmediately(displayID: displayID, showsCursor: options.showsCursor)
        case .allScreens:
            return try await captureAllDisplays(showsCursor: options.showsCursor)
        case .region, .window:
            // Cursor inclusion is intentionally not claimed for Apple's interactive
            // selector; only display-based SCK capture consumes showsCursor.
            return try await captureInteractively(mode: mode)
        }
    }

    /// Explicit defaults keep advanced/scroll capture immediate and cursor-free.
    /// A user screenshot menu should pass ScreenshotPreferences.options instead.
    func captureDisplay(displayID: CGDirectDisplayID, options: ScreenshotCaptureOptions = .init()) async throws -> CGImage {
        guard !isCapturing, selection == nil else { throw CaptureError.busy }
        isCapturing = true
        defer { isCapturing = false }
        try await options.delay.wait()
        try Task.checkCancellation()
        try Self.requireScreenPermission()
        try Task.checkCancellation()
        return try await captureDisplayImmediately(displayID: displayID, showsCursor: options.showsCursor)
    }

    private func captureDisplayImmediately(displayID: CGDirectDisplayID, showsCursor: Bool) async throws -> CGImage {
        let watcher = try DisplayConfigurationWatcher()
        let systemLayout = DisplaySystemSnapshot.current()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        try watcher.validate(snapshot: systemLayout)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let descriptor = try displayDescriptor(display, filter: filter)
        let image = try await captureFrame(filter: filter, display: descriptor, showsCursor: showsCursor)
        try watcher.validate(snapshot: systemLayout)
        return image
    }

    private func captureAllDisplays(showsCursor: Bool) async throws -> CGImage {
        let watcher = try DisplayConfigurationWatcher()
        let systemLayout = DisplaySystemSnapshot.current()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        try watcher.validate(snapshot: systemLayout)
        // Only lightweight filters/geometry are retained, never a frame array.
        var filters: [CGDirectDisplayID: SCContentFilter] = [:]
        var descriptors: [DisplayCaptureDescriptor] = []
        for display in content.displays {
            // Hardware-mirrored secondary displays are not drawable. Their active
            // primary supplies the shared desktop, instead of rejecting the setup
            // or trying to acquire an unavailable framebuffer.
            if CGDisplayIsActive(display.displayID) == 0 {
                let primary = CGDisplayMirrorsDisplay(display.displayID)
                guard primary != kCGNullDirectDisplay, CGDisplayIsActive(primary) != 0,
                      content.displays.contains(where: { $0.displayID == primary }) else {
                    throw DisplayCompositeError.layoutChanged
                }
                continue
            }
            guard filters[display.displayID] == nil else { throw DisplayCompositeError.duplicateDisplay }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            descriptors.append(try displayDescriptor(display, filter: filter))
            filters[display.displayID] = filter
        }
        guard Set(systemLayout.displays.filter(\.isActive).map(\.id)).isSubset(of: Set(descriptors.map(\.id))) else {
            throw DisplayCompositeError.layoutChanged
        }
        // Full composite size is guarded BEFORE any canvas or screenshot allocation.
        let layout = try DisplayCompositeLayout(displays: descriptors)
        return try await SequentialDisplayCapture.capture(layout: layout, validate: {
            try watcher.validate(snapshot: systemLayout)
        }, frame: { descriptor in
            guard let filter = filters[descriptor.id] else { throw DisplayCompositeError.layoutChanged }
            return try await self.captureFrame(filter: filter, display: descriptor, showsCursor: showsCursor)
        })
    }

    private func displayDescriptor(_ display: SCDisplay, filter: SCContentFilter) throws -> DisplayCaptureDescriptor {
        let bounds = CGDisplayBounds(display.displayID)
        // Quartz bounds and SCK content are both post-rotation logical dimensions.
        // Never silently rotate, stretch, or substitute a disconnected display.
        guard CGDisplayIsActive(display.displayID) != 0,
              bounds.size == filter.contentRect.size else { throw DisplayCompositeError.layoutChanged }
        return try DisplayCaptureDescriptor(id: display.displayID, bounds: bounds,
                                            pixelsPerPoint: CGFloat(filter.pointPixelScale),
                                            rotationDegrees: CGDisplayRotation(display.displayID))
    }

    private func captureFrame(filter: SCContentFilter, display: DisplayCaptureDescriptor, showsCursor: Bool) async throws -> CGImage {
        try Task.checkCancellation()
        let configuration = Self.displayConfiguration(for: display, showsCursor: showsCursor)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        // SCScreenshotManager has no cancellation API on macOS 14. An in-flight
        // system request may finish, but cancellation discards it and no next frame,
        // editor, or history write starts. The owning task retains the busy guard.
        try Task.checkCancellation()
        guard image.width == display.pixelWidth, image.height == display.pixelHeight else {
            throw DisplayCompositeError.layoutChanged
        }
        return image
    }

    static func displayConfiguration(for display: DisplayCaptureDescriptor, showsCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = display.pixelWidth
        configuration.height = display.pixelHeight
        configuration.showsCursor = showsCursor
        return configuration
    }

    /// Region for recording: display-local logical points, with origin at the TOP LEFT.
    /// Unlike screenshot selection, this does not create or read a screenshot.
    func selectRegion(displayID: CGDirectDisplayID) async throws -> CGRect {
        guard selection == nil, !isCapturing else { throw CaptureError.busy }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let controller = RegionSelectionController(screen: screen)
        selection = controller
        defer { selection = nil }
        return try await controller.select()
    }

    private func captureInteractively(mode: CaptureMode) async throws -> CGImage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.png")
        // Apple's selector handles arbitrary monitor arrangements, Retina pixels, Escape,
        // window shadows, and click/drag interaction. -o removes window shadows.
        let arguments = ["-x", "-i", mode == .window ? "-w" : "-s", "-o", "-t", "png", url.path]
        let command = ScreenshotCommand()
        let status = try await withTaskCancellationHandler {
            try await command.run(arguments: arguments)
        } onCancel: {
            command.cancel()
        }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: url.path) else {
            // screencapture uses a nonzero exit status for Escape, without an image.
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.screenPermission }
            throw CaptureError.cancelled
        }
        guard status == 0,
              let image = CGImage.read(url: url) else {
            throw CaptureError.failed("The system screenshot could not be decoded.")
        }
        return image
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Process state is protected independently of the main actor so task cancellation can
/// terminate the selector immediately, including cancellation before process launch.
private final class ScreenshotCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            child.arguments = arguments
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            process = child
            do {
                try child.run()
                lock.unlock()
            } catch {
                process = nil
                lock.unlock()
                continuation.resume(throwing: CaptureError.failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
}

@MainActor
final class RegionSelectionController: NSObject, NSWindowDelegate {
    private let screen: NSScreen
    private let frozenImage: CGImage?
    private var panel: SelectionPanel?
    private var selectionView: RegionSelectionView?
    private var continuation: CheckedContinuation<CGRect, Error>?
    private var sessionID: UUID?
    private var screenObserver: NSObjectProtocol?
    var isSelecting: Bool { continuation != nil }

    init(screen: NSScreen, frozenImage: CGImage? = nil) {
        self.screen = screen
        self.frozenImage = frozenImage
    }

    func select() async throws -> CGRect {
        guard sessionID == nil else { throw CaptureError.busy }
        try Task.checkCancellation()
        let geometry = try frozenImage.map {
            try FrozenCaptureGeometry(pointSize: screen.frame.size, pixelWidth: $0.width, pixelHeight: $0.height)
        }
        let session = UUID()
        sessionID = session
        defer { tearDown(); sessionID = nil }
        let rectangle = try await withTaskCancellationHandler {
            // Cancellation may arrive after the first check, before registration.
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.delegate = self
                panel.level = .screenSaver
                panel.backgroundColor = frozenImage == nil ? .clear : .black
                panel.isOpaque = frozenImage != nil
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                               frozenImage: frozenImage, geometry: geometry)
                view.finished = { [weak self] result in self?.finish(result, session: session) }
                panel.contentView = view
                self.panel = panel
                selectionView = view
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.finish(.failure(CaptureError.noDisplay), session: session) }
                }
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
                NSCursor.crosshair.set()
            }
        } onCancel: {
            // A queued callback from the prior selection must not close a new one.
            Task { @MainActor [weak self] in self?.finish(.failure(CaptureError.cancelled), session: session) }
        }
        try Task.checkCancellation()
        return rectangle
    }

    func cancel() {
        guard let session = sessionID else { return }
        finish(.failure(CaptureError.cancelled), session: session)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        cancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        cancel()
    }

    private func finish(_ result: Result<CGRect, Error>, session: UUID) {
        guard sessionID == session, let completion = continuation else { return }
        continuation = nil
        tearDown()
        completion.resume(with: result)
    }

    private func tearDown() {
        let wasKeyWindow = panel?.isKeyWindow == true
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        selectionView?.discard()
        selectionView = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel?.contentView = nil
        panel = nil
        if wasKeyWindow { NSCursor.arrow.set() }
        // Cursor rects belong to the window. Never push a global cursor that can
        // leak across Escape, application switching, display changes, or a retry.
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class RegionSelectionView: NSView {
    var finished: ((Result<CGRect, Error>) -> Void)?
    private var frozenImage: NSImage?
    private let geometry: FrozenCaptureGeometry?
    private var start: CGPoint?
    private var selected: CGRect = .zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, frozenImage: CGImage? = nil, geometry: FrozenCaptureGeometry? = nil) {
        self.frozenImage = frozenImage.map { NSImage(cgImage: $0, size: frame.size) }
        self.geometry = geometry
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func discard() {
        finished = nil
        frozenImage = nil
        start = nil
        selected = .zero
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        guard finished != nil else { return }
        start = convert(event.locationInWindow, from: nil)
        selected = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selected = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selected.width >= 2, selected.height >= 2 else { return }
        if let geometry {
            // Retain the unsnapped rectangle as input. Preview and final crop use
            // the same single alignment, without a second floating-point rounding.
            guard (try? geometry.alignedSelection(selected)) != nil else { return }
            finished?(.success(selected))
        } else {
            // The recording API still returns display-local, top-left points.
            finished?(.success(selected.integral.intersection(bounds)))
        }
    }
    override func cancelOperation(_ sender: Any?) { finished?(.failure(CaptureError.cancelled)) }
    override func rightMouseDown(with event: NSEvent) { cancelOperation(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if let frozenImage { drawFrozen(frozenImage) }
        NSColor.black.withAlphaComponent(0.40).setFill()
        bounds.fill()
        let aligned = try? geometry?.alignedSelection(selected, minimumPointSize: 0)
        let outlineFrame = aligned?.topLeftFrame ?? selected
        if !outlineFrame.isEmpty, !outlineFrame.isNull {
            NSGraphicsContext.saveGraphicsState()
            if let frozenImage {
                NSBezierPath(rect: outlineFrame).addClip()
                drawFrozen(frozenImage)
            } else {
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.clear.setFill()
                outlineFrame.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: outlineFrame)
            outline.lineWidth = 1.5
            outline.stroke()
            for point in [CGPoint(x: outlineFrame.minX, y: outlineFrame.minY), CGPoint(x: outlineFrame.maxX, y: outlineFrame.minY),
                          CGPoint(x: outlineFrame.minX, y: outlineFrame.maxY), CGPoint(x: outlineFrame.maxX, y: outlineFrame.maxY)] {
                let handle = NSBezierPath(rect: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
                NSColor.white.setFill(); handle.fill()
                NSColor.systemBlue.setStroke(); handle.lineWidth = 1; handle.stroke()
            }
        }
        let text: String
        if let aligned {
            text = "\(Int(aligned.pixelFrame.width)) × \(Int(aligned.pixelFrame.height)) px"
        } else if !selected.isEmpty {
            text = "\(Int(selected.width)) × \(Int(selected.height)) pt"
        } else {
            text = "拖动选择截图区域 · Esc 或右键取消"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = size.width + 18
        let x = outlineFrame.isEmpty ? (bounds.width - width) / 2 : outlineFrame.minX
        let y = outlineFrame.isEmpty ? 28 : (outlineFrame.minY >= 42 ? outlineFrame.minY - 34 : outlineFrame.maxY + 8)
        let label = CGRect(x: max(8, min(bounds.width - width - 8, x)),
                           y: max(8, min(bounds.height - 34, y)), width: width, height: 26)
        NSColor(calibratedWhite: 0.10, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: label.minX + 9, y: label.minY + 5), withAttributes: attributes)
    }

    private func drawFrozen(_ image: NSImage) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }
}
