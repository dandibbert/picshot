import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// Full-screen capture uses the display beneath the pointer, including its Retina scale.
enum CaptureMode: String, CaseIterable, Identifiable {
    case region, fullScreen, window
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: return "Region"
        case .fullScreen: return "Full Screen"
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

    func capture(mode: CaptureMode) async throws -> CGImage {
        guard !isCapturing else { throw CaptureError.busy }
        isCapturing = true
        defer { isCapturing = false }
        try Task.checkCancellation()
        try Self.requireScreenPermission()
        switch mode {
        case .fullScreen:
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            guard let displayID = screen?.displayID else { throw CaptureError.noDisplay }
            return try await captureDisplay(displayID: displayID)
        case .region, .window:
            return try await captureInteractively(mode: mode)
        }
    }

    /// Capture a particular monitor without relying on monitor ordering or a fixed 2× scale.
    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        try Self.requireScreenPermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return image
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
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
private final class RegionSelectionController: NSObject, NSWindowDelegate {
    private let screen: NSScreen
    private var panel: SelectionPanel?
    private var continuation: CheckedContinuation<CGRect, Error>?

    init(screen: NSScreen) { self.screen = screen }

    func select() async throws -> CGRect {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.delegate = self
                panel.level = .screenSaver
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.finished = { [weak self] result in self?.finish(result) }
                panel.contentView = view
                panel.makeFirstResponder(view)
                self.panel = panel
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                NSCursor.crosshair.push()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CaptureError.cancelled)) }
        }
    }

    func windowWillClose(_ notification: Notification) { finish(.failure(CaptureError.cancelled)) }

    private func finish(_ result: Result<CGRect, Error>) {
        guard let completion = continuation else { return }
        continuation = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        NSCursor.pop()
        completion.resume(with: result)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class RegionSelectionView: NSView {
    var finished: ((Result<CGRect, Error>) -> Void)?
    private var start: CGPoint?
    private var selected: CGRect = .zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
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
        if selected.width >= 2, selected.height >= 2 { finished?(.success(selected.integral.intersection(bounds))) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finished?(.failure(CaptureError.cancelled)) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        if !selected.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            selected.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selected)
            outline.lineWidth = 2
            outline.stroke()
        }
        let text = selected.isEmpty ? "Drag to select the recording area · Esc to cancel" : "\(Int(selected.width)) × \(Int(selected.height)) points · Release to confirm"
        (text as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
    }
}
