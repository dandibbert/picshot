import AppKit
import CoreGraphics

/// Nonactivating controls are excluded by the passive capture driver. Closing means Stop,
/// retaining the accepted sequence. A paused move always needs a separate explicit Resume.
@MainActor
final class ManualScrollControls: NSWindowController, NSWindowDelegate {
    var pauseOrResume: (() -> Void)?
    var move: (() -> Void)?
    var stop: (() -> Void)?
    private let label = NSTextField(labelWithString: "准备连续捕获…")
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let moveButton = NSButton(title: "移动选区", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)

    init(displayBounds: CGRect) {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 430, height: 74),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "PicShot · 手动连续捕获"
        panel.identifier = NSUserInterfaceItemIdentifier("scroll.manualPanel")
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 11)
        for (button, identifier) in [(pauseButton, "pause"), (moveButton, "move"), (stopButton, "stop")] {
            button.identifier = NSUserInterfaceItemIdentifier("scroll.manual." + identifier)
            button.controlSize = .small; button.bezelStyle = .rounded; button.target = self
        }
        pauseButton.action = #selector(togglePause); moveButton.action = #selector(movePressed)
        stopButton.action = #selector(stopPressed)
        let row = NSStackView(views: [pauseButton, moveButton, stopButton])
        row.orientation = .horizontal; row.spacing = 8
        let stack = NSStackView(views: [label, row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                label.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        panel.setFrameOrigin(CGPoint(x: displayBounds.maxX - panel.frame.width - 12,
                                     y: primaryHeight - displayBounds.maxY + 12))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(text: String, paused: Bool, retry: Bool, ready: Bool) {
        label.stringValue = text; label.toolTip = text
        pauseButton.title = retry ? "重试" : (paused ? "继续" : "暂停")
        pauseButton.isEnabled = !paused || ready
        moveButton.isEnabled = paused && ready
    }
    func detach() { window?.delegate = nil; pauseOrResume = nil; move = nil; stop = nil; close() }
    @objc private func togglePause() { pauseOrResume?() }
    @objc private func movePressed() { move?() }
    @objc private func stopPressed() { stop?() }
    func windowWillClose(_ notification: Notification) { stop?() }
}

/// A fixed-size rectangle mover. Its coordinate system is display-local top-left points.
/// Escape, display changes, close, cancellation and focus loss all leave the region intact.
@MainActor
final class ManualScrollRegionMover: NSObject, NSWindowDelegate {
    private var panel: ManualRegionPanel?
    private var continuation: CheckedContinuation<CGRect, Error>?
    private var token: UUID?
    private var observer: NSObjectProtocol?

    func choose(screen: NSScreen, region: CGRect) async throws -> CGRect {
        guard token == nil else { throw CaptureError.busy }
        try Task.checkCancellation()
        let current = UUID(); token = current
        defer { tearDown(); token = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let panel = ManualRegionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.delegate = self
                panel.level = .screenSaver; panel.backgroundColor = .clear; panel.isOpaque = false
                panel.hasShadow = false; panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                let view = ManualScrollRegionMoveView(frame: CGRect(origin: .zero, size: screen.frame.size), region: region)
                view.finished = { [weak self] result in self?.finish(result, token: current) }
                panel.contentView = view; self.panel = panel
                observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.finish(.failure(CaptureError.noDisplay), token: current) }
                }
                panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), token: current) }
        }
    }

    func cancel() { if let token { finish(.failure(CancellationError()), token: token) } }
    private func finish(_ result: Result<CGRect, Error>, token: UUID) {
        guard self.token == token, let completion = continuation else { return }
        continuation = nil; tearDown(); completion.resume(with: result)
    }
    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        (panel?.contentView as? ManualScrollRegionMoveView)?.finished = nil
        panel?.delegate = nil; panel?.orderOut(nil); panel?.close(); panel?.contentView = nil; panel = nil
    }
    func windowWillClose(_ notification: Notification) { cancel() }
    func windowDidResignKey(_ notification: Notification) { cancel() }
}

private final class ManualRegionPanel: NSPanel { override var canBecomeKey: Bool { true } }

@MainActor
final class ManualScrollRegionMoveView: NSView {
    private(set) var region: CGRect
    var finished: ((Result<CGRect, Error>) -> Void)?
    private var dragStart: CGPoint?
    private var originalOrigin: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, region: CGRect) {
        self.region = region; super.init(frame: frame)
        setAccessibilityLabel("移动固定尺寸选区。拖动改变位置，回车确认，Escape取消。尺寸、显示器和目标窗口不变。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill(); bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: region); border.lineWidth = 2; border.stroke()
        let text = "已暂停 · 拖动固定选区 · 回车确认 · Esc取消\n\(Int(region.width)) × \(Int(region.height))点 · 同一显示器和目标窗口"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let box = CGRect(x: 20, y: 20, width: min(600, bounds.width - 40), height: 56)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text.draw(in: box.insetBy(dx: 10, dy: 8), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil); originalOrigin = region.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = originalOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        region.origin = CGPoint(x: max(0, min(bounds.width - region.width, origin.x + current.x - start.x)),
                                y: max(0, min(bounds.height - region.height, origin.y + current.y - start.y)))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); dragStart = nil; originalOrigin = nil }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: finished?(.success(region))
        case 53: finished?(.failure(CaptureError.cancelled))
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { finished?(.failure(CaptureError.cancelled)) }
}
