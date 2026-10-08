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
    func captureForEditing(mode: CaptureMode, options: ScreenshotCaptureOptions = .init(), elementSelection: Bool = false) async throws -> CapturedImage {
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
        let elementContext = CaptureElementContext(displayBounds: CGDisplayBounds(displayID),
                                                   windows: CaptureElementWindow.visible(), frozenAt: capturedAt,
                                                   initiallyEnabled: elementSelection)
        let controller = RegionSelectionController(screen: currentScreen, frozenImage: frozen, elementContext: elementContext)
        selection = controller
        defer { selection = nil }
        let rectangle = try await controller.select()
        try Task.checkCancellation()
        try watcher.validate(snapshot: snapshot)
        if let pixels = controller.selectionPixelFrame {
            return try CapturedImage.frozenPixelRegion(image: frozen, displayID: displayID,
                displayFrame: displayFrame, pixelFrame: pixels, capturedAt: capturedAt, aspectRatio: controller.selectionRatio)
        }
        return try CapturedImage.frozenRegion(image: frozen, displayID: displayID,
                                              displayFrame: displayFrame, selection: rectangle, capturedAt: capturedAt)
    }

    /// Choose a rectangle immediately; the chosen delay belongs only to this
    /// named preset and never changes ScreenshotPreferences or runs a countdown.
    func createPreset(name: String, delay: ScreenshotDelay) async throws -> CapturePreset {
        guard CapturePreset.validName(name.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CapturePresetError.invalidName
        }
        let capture = try await captureForEditing(mode: .region)
        try Task.checkCancellation()
        guard let presentation = capture.presentation,
              let screen = NSScreen.screens.first(where: { $0.displayID == presentation.displayID }),
              screen.frame == presentation.displayFrame else { throw CapturePresetError.displayChanged }
        let display = try Self.presetDisplay(screen: screen, pixelWidth: presentation.frozenImage.width,
                                             pixelHeight: presentation.frozenImage.height)
        let geometry = try FrozenCaptureGeometry(pointSize: presentation.displayFrame.size,
                                                 pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight)
        let frame = presentation.selectionFrame
        // Presentation was already pixel aligned. Round back to its exact stored
        // integral source pixels rather than floor/ceil the point representation.
        let scaleX = CGFloat(display.pixelWidth) / display.frame.width
        let scaleY = CGFloat(display.pixelHeight) / display.frame.height
        let pixels = CGRect(x: (frame.minX * scaleX).rounded(),
                            y: ((display.frame.height - frame.maxY) * scaleY).rounded(),
                            width: (frame.width * scaleX).rounded(), height: (frame.height * scaleY).rounded())
        let aligned = try geometry.selectionForPixels(pixels)
        return try CapturePreset(name: name, delay: delay, display: display,
                                 topLeftFrame: aligned.topLeftFrame, pixelFrame: aligned.pixelFrame)
    }

    /// Stable identity and unchanged geometry are checked before delay, before
    /// screen access, before SCK acquisition and again before the pixel crop.
    func capturePreset(_ preset: CapturePreset, showsCursor: Bool = false) async throws -> CapturedImage {
        guard !isCapturing, selection == nil else { throw CaptureError.busy }
        isCapturing = true
        defer { isCapturing = false }
        try Task.checkCancellation()
        let watcher = try DisplayConfigurationWatcher(), snapshot = DisplaySystemSnapshot.current()
        let screen = try Self.resolvePresetScreen(preset)
        guard let displayID = screen.displayID else { throw CapturePresetError.missingDisplay }
        try await preset.delay.wait()
        try watcher.validate(snapshot: snapshot)
        _ = try Self.resolvePresetScreen(preset)
        try Self.requireScreenPermission()
        try Task.checkCancellation()
        try watcher.validate(snapshot: snapshot)
        _ = try Self.resolvePresetScreen(preset)
        let frozen = try await captureDisplayImmediately(displayID: displayID, showsCursor: showsCursor,
            expectedPixels: CGSize(width: preset.display.pixelWidth, height: preset.display.pixelHeight), validateTarget: {
                try watcher.validate(snapshot: snapshot)
                guard try Self.resolvePresetScreen(preset).displayID == displayID else { throw CapturePresetError.displayChanged }
            })
        let capturedAt = Date()
        try watcher.validate(snapshot: snapshot)
        _ = try Self.resolvePresetScreen(preset)
        return try CapturedImage.frozenPixelRegion(image: frozen, displayID: displayID, displayFrame: preset.display.frame,
                                                   pixelFrame: preset.pixelFrame, capturedAt: capturedAt)
    }

    private static func resolvePresetScreen(_ preset: CapturePreset) throws -> NSScreen {
        // Unknown UUIDs are never replaced with NSScreen.main or the pointer screen.
        let screens = try NSScreen.screens.map { screen in (screen, try presetDisplay(screen: screen)) }
        try preset.resolveDisplay(in: screens.map { $0.1 })
        guard let screen = screens.first(where: { $0.1.uuid == preset.display.uuid })?.0 else { throw CapturePresetError.missingDisplay }
        return screen
    }

    static func presetDisplay(screen: NSScreen, pixelWidth: Int? = nil, pixelHeight: Int? = nil) throws -> CapturePresetDisplay {
        guard let displayID = screen.displayID, CGDisplayIsActive(displayID) != 0,
              let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { throw CapturePresetError.missingDisplay }
        let string = CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String
        guard let uuid = UUID(uuidString: string) else { throw CapturePresetError.missingDisplay }
        let width = (screen.frame.width * screen.backingScaleFactor).rounded()
        let height = (screen.frame.height * screen.backingScaleFactor).rounded()
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= CGFloat(DisplayCompositeLayout.maximumDimension), height <= CGFloat(DisplayCompositeLayout.maximumDimension) else {
            throw CapturePresetError.invalidGeometry
        }
        return try CapturePresetDisplay(uuid: uuid, frame: screen.frame, pixelWidth: pixelWidth ?? Int(width),
                                         pixelHeight: pixelHeight ?? Int(height), rotationDegrees: CGDisplayRotation(displayID))
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

    private func captureDisplayImmediately(displayID: CGDirectDisplayID, showsCursor: Bool, expectedPixels: CGSize? = nil,
                                           validateTarget: (() throws -> Void)? = nil) async throws -> CGImage {
        try validateTarget?()
        let watcher = try DisplayConfigurationWatcher()
        let systemLayout = DisplaySystemSnapshot.current()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        try watcher.validate(snapshot: systemLayout)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let descriptor = try displayDescriptor(display, filter: filter)
        if let expectedPixels {
            guard expectedPixels == CGSize(width: descriptor.pixelWidth, height: descriptor.pixelHeight) else { throw CapturePresetError.displayChanged }
        }
        try validateTarget?()
        let image = try await captureFrame(filter: filter, display: descriptor, showsCursor: showsCursor)
        try watcher.validate(snapshot: systemLayout)
        try validateTarget?()
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
    private let elementContext: CaptureElementContext?
    private var panel: SelectionPanel?
    private var selectionView: RegionSelectionView?
    private var continuation: CheckedContinuation<CGRect, Error>?
    private var sessionID: UUID?
    private var screenObserver: NSObjectProtocol?
    var isSelecting: Bool { continuation != nil }
    private(set) var selectionRatio: CaptureAspectRatio?
    private(set) var selectionPixelFrame: CGRect?

    init(screen: NSScreen, frozenImage: CGImage? = nil, elementContext: CaptureElementContext? = nil) {
        self.screen = screen
        self.frozenImage = frozenImage
        self.elementContext = elementContext
    }

    func select() async throws -> CGRect {
        guard sessionID == nil else { throw CaptureError.busy }
        try Task.checkCancellation()
        let geometry = try frozenImage.map {
            try FrozenCaptureGeometry(pointSize: screen.frame.size, pixelWidth: $0.width, pixelHeight: $0.height)
        }
        selectionRatio = nil; selectionPixelFrame = nil
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
                panel.acceptsMouseMovedEvents = true
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                               frozenImage: frozenImage, geometry: geometry, elementContext: elementContext)
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
        if case .success = result {
            selectionRatio = selectionView?.aspectRatio
            selectionPixelFrame = selectionView?.committedPixelFrame
        }
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

@MainActor
final class RegionSelectionView: NSView {
    var finished: ((Result<CGRect, Error>) -> Void)?
    private var frozenImage: NSImage?
    private let geometry: FrozenCaptureGeometry?
    private let elementContext: CaptureElementContext?
    private let elementSession: CaptureElementSession?
    private var elementEnabled = false
    private var elementMessage = ""
    private var elementButtons: [NSButton] = []
    private var tracking: NSTrackingArea?
    private var lastHover: CGPoint?
    private var elementClickFrame: CGRect?
    private var start: CGPoint?
    private(set) var selected: CGRect = .zero
    private(set) var aspectRatio: CaptureAspectRatio?
    private(set) var committedPixelFrame: CGRect?
    private let ratioControls = CaptureRatioControls(prefix: "capture")
    private let ratioSurface = NSVisualEffectView()
    private let ratioAccept = NSButton()
    private var ratioControlsHidden = false
    private var precisionEditing = false
    private var cancelled = false
    private var resizeHandle: CaptureRatioHandle?
    private var dragOriginal: CGRect = .zero
    private struct RatioSnapshot {
        let rectangle: CGRect
        let ratio: CaptureAspectRatio?
        let precision: Bool
    }
    private var undoStates: [RatioSnapshot] = []
    private var redoStates: [RatioSnapshot] = []
    private var dragSnapshot: RatioSnapshot?
    private var ratioGeometry: CaptureRatioGeometry? {
        guard let geometry else { return nil }
        return try? CaptureRatioGeometry(pointSize: geometry.pointSize, pixelWidth: geometry.pixelWidth, pixelHeight: geometry.pixelHeight)
    }
    private(set) var elementPreviewFrame: CGRect?
    var elementStatusMessage: String { elementMessage }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, frozenImage: CGImage? = nil, geometry: FrozenCaptureGeometry? = nil,
         elementContext: CaptureElementContext? = nil) {
        self.frozenImage = frozenImage.map { NSImage(cgImage: $0, size: frame.size) }
        self.geometry = geometry
        self.elementContext = elementContext
        elementSession = elementContext.map { CaptureElementSession(provider: $0.provider) }
        super.init(frame: frame)
        if geometry != nil { configureRatioControls() }
        if let elementContext {
            elementEnabled = elementContext.initiallyEnabled
            for (title, identifier, action) in [("元素选择 E", "capture.elements.toggle", #selector(toggleElements)),
                    ("上一级 ↑", "capture.elements.parent", #selector(parentElement)),
                    ("下一级 ↓", "capture.elements.child", #selector(childElement))] {
                let button = NSButton(title: title, target: self, action: action)
                button.identifier = NSUserInterfaceItemIdentifier(identifier)
                button.bezelStyle = .rounded; button.controlSize = .small
                button.setAccessibilityLabel(title); addSubview(button); elementButtons.append(button)
            }
            elementSession?.changed = { [weak self] result in
                guard let self, self.elementEnabled, self.aspectRatio == nil, self.start == nil else { return }
                switch result {
                case .snapshot: self.elementMessage = "元素边界为稍后的辅助功能信息；截图像素保持冻结"
                case .unavailable(let reason): self.elementMessage = reason.message
                }
                self.refreshElementPreview()
            }
            elementMessage = elementEnabled ? "移动指针选择元素；拖动仍可选择矩形" : ""
            refreshElementControls()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if geometry != nil {
            let width = min(440, max(1, bounds.width - 16)), height = min(118, max(1, bounds.height - 16))
            ratioSurface.frame = CGRect(x: max(8, (bounds.width - width) / 2), y: 8, width: width, height: height)
            ratioSurface.isHidden = ratioControlsHidden || bounds.width < 320 || bounds.height < 180
        }
        let widths: [CGFloat] = [102, 94, 94], gap: CGFloat = 6
        let total = widths.reduce(0, +) + gap * 2
        var x = max(8, (bounds.width - total) / 2)
        for (index, button) in elementButtons.enumerated() {
            button.frame = CGRect(x: x, y: max(0, bounds.height - 42), width: widths[index], height: 28)
            x += widths[index] + gap
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    func discard() {
        elementSession?.stop(); elementPreviewFrame = nil; elementClickFrame = nil
        finished = nil; frozenImage = nil; start = nil; selected = .zero; cancelled = true
        undoStates.removeAll(); redoStates.removeAll(); dragSnapshot = nil
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if geometry != nil, !ratioSurface.isHidden { addCursorRect(ratioSurface.frame, cursor: .arrow) }
    }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        elementSession?.invalidate(); elementPreviewFrame = nil; lastHover = nil; needsDisplay = true
    }
    func hover(at point: CGPoint) {
        guard finished != nil, elementEnabled, aspectRatio == nil, start == nil, bounds.contains(point),
              !elementButtons.contains(where: { $0.frame.contains(point) }),
              geometry == nil || ratioSurface.isHidden || !ratioSurface.frame.contains(point), let elementContext else { return }
        if let lastHover, abs(lastHover.x - point.x) < 0.5, abs(lastHover.y - point.y) < 0.5 { return }
        lastHover = point; elementPreviewFrame = nil
        elementMessage = "正在查询元素；可随时拖动选择矩形"
        elementSession?.request(CaptureElementRequest(
            point: point.applying(CGAffineTransform(translationX: elementContext.displayBounds.minX, y: elementContext.displayBounds.minY)),
            displayBounds: elementContext.displayBounds, windows: elementContext.windows, frozenAt: elementContext.frozenAt))
        refreshElementControls(); needsDisplay = true
    }
    @objc private func toggleElements() {
        elementEnabled.toggle(); elementSession?.invalidate(); elementPreviewFrame = nil; lastHover = nil
        elementMessage = elementEnabled ? (aspectRatio == nil ? "移动指针选择元素；需要在系统设置中手动开启辅助功能权限" : "比例锁定时拖动选择矩形；选择 Free 后可使用元素选择") : ""
        refreshElementControls(); needsDisplay = true; window?.makeFirstResponder(self)
    }
    @objc private func parentElement() { traverseElement(parent: true) }
    @objc private func childElement() { traverseElement(parent: false) }
    private func traverseElement(parent: Bool) {
        guard elementEnabled, aspectRatio == nil, start == nil, elementSession?.traverse(parent: parent) == true else { return }
        refreshElementPreview(); window?.makeFirstResponder(self)
    }
    private func refreshElementPreview() {
        if aspectRatio == nil, let node = elementSession?.selectedNode, let elementContext {
            elementPreviewFrame = CaptureElementGeometry.localFrame(node.frame, displayBounds: elementContext.displayBounds)
        } else { elementPreviewFrame = nil }
        refreshElementControls(); needsDisplay = true
    }
    private func refreshElementControls() {
        guard elementButtons.count == 3 else { return }
        elementButtons[0].state = elementEnabled ? .on : .off
        elementButtons[1].isEnabled = aspectRatio == nil && elementEnabled && elementSession?.selectedNode?.parent != nil
        elementButtons[2].isEnabled = aspectRatio == nil && elementEnabled && !(elementSession?.selectedNode?.children.isEmpty ?? true)
    }
    override func mouseDown(with event: NSEvent) {
        guard finished != nil, !cancelled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard geometry == nil || ratioSurface.isHidden || !ratioSurface.frame.contains(point) else { return }
        window?.makeFirstResponder(self)
        dragSnapshot = snapshot
        resizeHandle = precisionEditing && !selected.isEmpty ? CaptureRatioHandle.hit(at: point, frame: selected) : nil
        dragOriginal = selected
        start = point
        elementClickFrame = aspectRatio == nil ? elementPreviewFrame.flatMap { $0.contains(point) ? $0 : nil } : nil
        elementSession?.invalidate(); elementPreviewFrame = nil
        if resizeHandle == nil { selected = .zero }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !cancelled, let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        if hypot(end.x - start.x, end.y - start.y) >= 3 { elementClickFrame = nil }
        else if aspectRatio != nil, resizeHandle == nil { selected = .zero; refreshRatioControls(); needsDisplay = true; return }
        do {
            if let ratio = aspectRatio, let ratioGeometry {
                selected = try resizeHandle.map { try ratioGeometry.resize(dragOriginal, handle: $0, to: end, ratio: ratio) }
                    ?? ratioGeometry.drag(from: start, to: end, ratio: ratio)
            } else if let resizeHandle {
                selected = resizeHandle.freelyResized(dragOriginal, to: end, in: bounds)
            } else {
                selected = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
            }
            refreshRatioControls()
        } catch {
            if resizeHandle == nil { selected = .zero }
            ratioControls.showError(error.localizedDescription)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !cancelled, start != nil else { return }
        mouseDragged(with: event)
        let rectangle = elementClickFrame ?? selected
        start = nil; resizeHandle = nil; elementClickFrame = nil; lastHover = nil
        if let previous = dragSnapshot, rectangle != previous.rectangle { remember(previous) }
        dragSnapshot = nil
        guard rectangle.width >= 2, rectangle.height >= 2 else { return }
        selected = rectangle
        if precisionEditing { refreshRatioControls(); needsDisplay = true }
        else { commitSelection(rectangle) }
    }
    private func commitSelection(_ rectangle: CGRect) {
        guard !cancelled else { return }
        if let geometry {
            if precisionEditing {
                guard let ratioGeometry, let pixels = try? ratioGeometry.sourcePixelRect(rectangle),
                      let aligned = try? geometry.selectionForPixels(pixels) else {
                    ratioControls.showError("Select at least 2 × 2 points inside this display"); return
                }
                if let aspectRatio, pixels.width * CGFloat(aspectRatio.denominator) != pixels.height * CGFloat(aspectRatio.numerator) {
                    ratioControls.showError("选区像素不符合比例，请重新绘制选区"); return
                }
                committedPixelFrame = pixels
                finished?(.success(aligned.topLeftFrame))
            } else {
                guard (try? geometry.alignedSelection(rectangle)) != nil else { return }
                finished?(.success(rectangle))
            }
        } else { finished?(.success(rectangle.integral.intersection(bounds))) }
    }
    override func cancelOperation(_ sender: Any?) {
        guard !cancelled else { return }
        cancelled = true; finished?(.failure(CaptureError.cancelled))
    }
    override func rightMouseDown(with event: NSEvent) { cancelOperation(nil) }
    override func keyDown(with event: NSEvent) {
        guard !cancelled else { return }
        if event.keyCode == 53 { cancelOperation(nil) }
        else if event.keyCode == 48, geometry != nil {
            ratioControlsHidden.toggle(); needsLayout = true; layoutSubtreeIfNeeded(); window?.invalidateCursorRects(for: self)
        }
        else if event.charactersIgnoringModifiers?.lowercased() == "z", event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) { redoRatioSelection() }
            else if !undoStates.isEmpty || start != nil { undoRatioSelection() }
            else if elementSession?.undoTraversal() == true { refreshElementPreview() }
        } else if precisionEditing, !selected.isEmpty, [123, 124, 125, 126].contains(event.keyCode) {
            nudgeSelection(event)
        } else if event.keyCode == 126 { parentElement() }
        else if event.keyCode == 125 { childElement() }
        else if event.charactersIgnoringModifiers?.lowercased() == "e", !event.modifierFlags.contains(.command), elementContext != nil { toggleElements() }
        else if [UInt16(36), 76].contains(event.keyCode) {
            if precisionEditing, !selected.isEmpty { commitSelection(selected) }
            else if aspectRatio == nil, let frame = elementPreviewFrame { commitSelection(frame) }
        } else { super.keyDown(with: event) }
    }
    private var snapshot: RatioSnapshot { RatioSnapshot(rectangle: selected, ratio: aspectRatio, precision: precisionEditing) }
    private func remember(_ previous: RatioSnapshot) {
        if undoStates.count == 64 { undoStates.removeFirst() }
        undoStates.append(previous); redoStates.removeAll()
    }
    private func restore(_ state: RatioSnapshot) {
        selected = state.rectangle; aspectRatio = state.ratio; precisionEditing = state.precision
        elementSession?.invalidate(); elementPreviewFrame = nil; elementClickFrame = nil; lastHover = nil; refreshElementControls()
        refreshRatioControls(); needsDisplay = true; window?.makeFirstResponder(self)
    }
    private func undoRatioSelection() {
        if start != nil, let previous = dragSnapshot { start = nil; resizeHandle = nil; dragSnapshot = nil; restore(previous); return }
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(snapshot); restore(previous)
    }
    private func redoRatioSelection() {
        guard start == nil, let next = redoStates.popLast() else { return }
        undoStates.append(snapshot); restore(next)
    }
    @objc private func acceptRatioSelection() { if !selected.isEmpty { commitSelection(selected) } }
    private func configureRatioControls() {
        ratioSurface.material = .hudWindow; ratioSurface.blendingMode = .withinWindow; ratioSurface.state = .active
        ratioSurface.wantsLayer = true; ratioSurface.layer?.cornerRadius = 8
        addSubview(ratioSurface)
        ratioAccept.title = "使用选区 · Return"; ratioAccept.target = self; ratioAccept.action = #selector(acceptRatioSelection)
        ratioAccept.identifier = .init("capture.ratioAccept"); ratioAccept.bezelStyle = .rounded; ratioAccept.controlSize = .small
        ratioAccept.isEnabled = false
        let stack = NSStackView(views: [ratioControls, ratioAccept]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false; ratioSurface.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: ratioSurface.leadingAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: ratioSurface.topAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: ratioSurface.trailingAnchor, constant: -8)])
        ratioControls.onRatio = { [weak self] ratio in self?.setAspectRatio(ratio) ?? false }
        ratioControls.onSize = { [weak self] w, h, axis in self?.setPixelSize(width: w, height: h, axis: axis) ?? false }
        ratioControls.onCancel = { [weak self] in self?.cancelOperation(nil) }
    }
    @discardableResult
    func setAspectRatio(_ ratio: CaptureAspectRatio?) -> Bool {
        guard !cancelled, start == nil, let ratioGeometry else { return false }
        do {
            if let ratio, selected.isEmpty { _ = try ratioGeometry.fitting(bounds, ratio: ratio) }
            let next: CGRect
            if let ratio, !selected.isEmpty { next = try ratioGeometry.fitting(selected, ratio: ratio) } else { next = selected }
            if ratio != aspectRatio || next != selected || !precisionEditing { remember(snapshot) }
            aspectRatio = ratio; selected = next; precisionEditing = true
            elementSession?.invalidate(); elementPreviewFrame = nil; elementClickFrame = nil; lastHover = nil
            refreshElementControls()
            window?.makeFirstResponder(self); refreshRatioControls(); needsDisplay = true; return true
        } catch { ratioControls.showError(error.localizedDescription); return false }
    }
    @discardableResult
    func setPixelSize(width: Int, height: Int, axis: CaptureRatioAxis) -> Bool {
        guard !cancelled, start == nil, !selected.isEmpty, let geometry, let ratioGeometry else { return false }
        do {
            let next: CGRect
            if let aspectRatio { next = try ratioGeometry.sized(selected, pixels: axis == .width ? width : height, axis: axis, ratio: aspectRatio) }
            else {
                let previous = try ratioGeometry.sourcePixelRect(selected)
                let pixels = CGRect(x: max(0, min(previous.minX, CGFloat(geometry.pixelWidth) - CGFloat(width))),
                                    y: max(0, min(previous.minY, CGFloat(geometry.pixelHeight) - CGFloat(height))), width: CGFloat(width), height: CGFloat(height))
                next = try geometry.selectionForPixels(pixels).topLeftFrame
            }
            if next != selected { remember(snapshot); selected = next }
            precisionEditing = true; window?.makeFirstResponder(self); refreshRatioControls(); needsDisplay = true; return true
        } catch { ratioControls.showError(error.localizedDescription); return false }
    }
    private func refreshRatioControls() {
        let pixels = ratioGeometry.flatMap { try? $0.sourcePixelRect(selected) }
        ratioControls.display(ratio: aspectRatio, pixels: pixels?.size)
        ratioAccept.isEnabled = pixels != nil && start == nil && !cancelled
    }
    private func nudgeSelection(_ event: NSEvent) {
        guard start == nil, event.modifierFlags.intersection([.command, .control]).isEmpty,
              let geometry, let ratioGeometry, let pixels = try? ratioGeometry.sourcePixelRect(selected) else { return }
        let amount = event.modifierFlags.contains(.shift) ? 10 : 1
        let dx = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
        let dy = event.keyCode == 126 ? -amount : event.keyCode == 125 ? amount : 0
        if event.modifierFlags.contains(.option) {
            let axis: CaptureRatioAxis = dx == 0 ? .height : .width
            let stepX = aspectRatio?.numerator ?? 1, stepY = aspectRatio?.denominator ?? 1
            _ = setPixelSize(width: Int(pixels.width) + dx * stepX, height: Int(pixels.height) + dy * stepY, axis: axis)
        } else {
            let moved = CGRect(x: max(0, min(CGFloat(geometry.pixelWidth) - pixels.width, pixels.minX + CGFloat(dx))),
                               y: max(0, min(CGFloat(geometry.pixelHeight) - pixels.height, pixels.minY + CGFloat(dy))), width: pixels.width, height: pixels.height)
            if let frame = try? geometry.selectionForPixels(moved).topLeftFrame, frame != selected {
                remember(snapshot); selected = frame; refreshRatioControls(); needsDisplay = true
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if let frozenImage { drawFrozen(frozenImage) }
        NSColor.black.withAlphaComponent(0.40).setFill(); bounds.fill()
        let preview = selected.isEmpty ? (elementPreviewFrame ?? selected) : selected
        let aligned: FrozenCaptureGeometry.Selection?
        if precisionEditing, let pixels = ratioGeometry.flatMap({ try? $0.sourcePixelRect(preview) }) {
            aligned = try? geometry?.selectionForPixels(pixels)
        } else { aligned = try? geometry?.alignedSelection(preview, minimumPointSize: 0) }
        let outlineFrame = aligned?.topLeftFrame ?? preview
        if !outlineFrame.isEmpty, !outlineFrame.isNull {
            NSGraphicsContext.saveGraphicsState()
            if let frozenImage { NSBezierPath(rect: outlineFrame).addClip(); drawFrozen(frozenImage) }
            else {
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.clear.setFill(); outlineFrame.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: outlineFrame); outline.lineWidth = 1.5; outline.stroke()
            let handles: [CaptureRatioHandle] = precisionEditing ? CaptureRatioHandle.allCases : [.minXMinY, .maxXMinY, .minXMaxY, .maxXMaxY]
            for point in handles.map({ $0.point(in: outlineFrame) }) {
                let handle = NSBezierPath(rect: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
                NSColor.white.setFill(); handle.fill(); NSColor.systemBlue.setStroke(); handle.lineWidth = 1; handle.stroke()
            }
        }
        let text: String
        if let aligned { text = "\(Int(aligned.pixelFrame.width)) × \(Int(aligned.pixelFrame.height)) px" + (aspectRatio.map { " · \($0.label) 精确 · Return 确认" } ?? "") }
        else if !selected.isEmpty { text = "\(Int(selected.width)) × \(Int(selected.height)) pt" }
        else { text = "拖动选择截图区域 · Esc 或右键取消" }
        drawLabel(text, at: CGPoint(x: outlineFrame.isEmpty ? bounds.midX : outlineFrame.minX,
                                    y: outlineFrame.isEmpty ? 28 : (outlineFrame.minY >= 42 ? outlineFrame.minY - 34 : outlineFrame.maxY + 8)),
                  centered: outlineFrame.isEmpty)
        if elementEnabled, !elementMessage.isEmpty {
            drawLabel(elementMessage, at: CGPoint(x: bounds.midX, y: max(4, bounds.height - 76)), centered: true)
        }
    }
    private func drawLabel(_ text: String, at point: CGPoint, centered: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = min(max(0, bounds.width - 16), size.width + 18)
        let x = centered ? point.x - width / 2 : point.x
        let label = CGRect(x: max(8, min(bounds.width - width - 8, x)), y: max(8, min(bounds.height - 34, point.y)), width: width, height: 26)
        NSColor(calibratedWhite: 0.10, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(in: label.insetBy(dx: 9, dy: 5), withAttributes: attributes)
    }
    private func drawFrozen(_ image: NSImage) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }
}
