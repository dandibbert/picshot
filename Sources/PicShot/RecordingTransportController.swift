import AppKit

/// Presentation only. The shared recording command owner remains responsible
/// for serialization, Stop precedence, saving, monitoring and session lifetime.
struct RecordingTransportSnapshot: Equatable {
    enum StatusKind: String { case recording, paused, saving, error }
    var paused = false
    var busy = false
    var canPause = false
    var canStop = false
    var elapsed: TimeInterval = 0
    var status = "录制中"
    var statusKind: StatusKind = .recording
    var pauseShortcut: String?
    var stopShortcut: String?

    var elapsedLabel: String {
        let seconds = Int(min(359_999, max(0, elapsed.isFinite ? elapsed : 0)))
        if seconds >= 3_600 { return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct RecordingTransportActions {
    var pauseResume: () -> Void
    var stopSave: () -> Void
    var expand: () -> Void
}

/// AppKit global screen points, including displays with negative origins.
/// The caller supplies the selected display's current visible frame. No screen
/// observer or polling timer is needed in this presentation layer.
enum RecordingTransportPlacement {
    static let size = CGSize(width: 300, height: 40)
    static let minimumSize = CGSize(width: 144, height: 40)

    static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite && rect.width >= minimumSize.width && rect.height >= minimumSize.height
    }

    static func clamp(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        guard isUsable(visibleFrame) else { return frame }
        let size = CGSize(width: min(Self.size.width, visibleFrame.width), height: Self.size.height)
        let x = frame.origin.x.isFinite ? frame.origin.x : visibleFrame.minX
        let y = frame.origin.y.isFinite ? frame.origin.y : visibleFrame.minY
        return CGRect(x: max(visibleFrame.minX, min(x, visibleFrame.maxX - size.width)),
                      y: max(visibleFrame.minY, min(y, visibleFrame.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    static func initial(anchor: CGRect, visibleFrame: CGRect) -> CGRect {
        let validAnchor = !anchor.isNull && !anchor.isInfinite && anchor.origin.x.isFinite &&
            anchor.origin.y.isFinite && anchor.width.isFinite && anchor.height.isFinite
        let reference = validAnchor ? anchor.standardized : visibleFrame
        let width = min(size.width, visibleFrame.width)
        let x = reference.midX - width / 2
        let below = CGRect(x: x, y: reference.minY - size.height - 8, width: width, height: size.height)
        if below.minY >= visibleFrame.minY { return clamp(below, to: visibleFrame) }
        let above = CGRect(x: x, y: reference.maxY + 8, width: width, height: size.height)
        if above.maxY <= visibleFrame.maxY { return clamp(above, to: visibleFrame) }
        return clamp(below, to: visibleFrame)
    }
}

@MainActor
final class RecordingTransportController: NSWindowController {
    private(set) var snapshot = RecordingTransportSnapshot()
    private(set) var anchor: CGRect = .zero
    private(set) var visibleFrame: CGRect = .zero
    private(set) var isRetired = false
    private var actions: RecordingTransportActions?
    private var surface: RecordingTransportView?
    private var hasPosition = false
    private var dragWindowOrigin: CGPoint?

    init(actions: RecordingTransportActions) {
        let panel = RecordingTransportPanel(contentRect: CGRect(origin: .zero, size: RecordingTransportPlacement.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.actions = actions
        super.init(window: panel)
        panel.title = "PicShot · 录屏控制"
        panel.identifier = NSUserInterfaceItemIdentifier("recording.transport")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        // App-wide ScreenCaptureKit exclusion remains the actual capture policy.
        // This flag alone is not proof of physical display-capture exclusion.
        panel.sharingType = .none
        let view = RecordingTransportView(frame: CGRect(origin: .zero, size: RecordingTransportPlacement.size))
        surface = view
        panel.contentView = view
        view.pauseButton.target = self; view.pauseButton.action = #selector(pausePressed)
        view.stopButton.target = self; view.stopButton.action = #selector(stopPressed)
        view.expandButton.target = self; view.expandButton.action = #selector(expandPressed)
        view.grip.onBegin = { [weak self] in self?.dragWindowOrigin = self?.window?.frame.origin }
        view.grip.onDelta = { [weak self] delta in
            guard let self, let origin = self.dragWindowOrigin, let window = self.window, !self.isRetired else { return }
            let proposed = CGRect(origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), size: window.frame.size)
            window.setFrame(RecordingTransportPlacement.clamp(proposed, to: self.visibleFrame), display: true)
        }
        view.grip.onEnd = { [weak self] in self?.dragWindowOrigin = nil }
        view.display(snapshot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Repeated show/hide during one take preserves the user's dragged position.
    /// Use teardown and a new controller when the recording session retires.
    func show(snapshot: RecordingTransportSnapshot, anchor: CGRect, visibleFrame: CGRect) {
        guard !isRetired, RecordingTransportPlacement.isUsable(visibleFrame) else { return }
        update(snapshot: snapshot)
        updatePlacement(anchor: anchor, visibleFrame: visibleFrame)
        window?.orderFrontRegardless()
    }

    func update(snapshot: RecordingTransportSnapshot, actions: RecordingTransportActions? = nil) {
        guard !isRetired else { return }
        self.snapshot = snapshot
        if let actions { self.actions = actions }
        surface?.display(snapshot)
    }

    func updatePlacement(anchor: CGRect, visibleFrame: CGRect, preservePosition: Bool = true) {
        guard !isRetired, let window, RecordingTransportPlacement.isUsable(visibleFrame) else { return }
        self.anchor = anchor; self.visibleFrame = visibleFrame
        surface?.grip.cancelDrag()
        let proposed = preservePosition && hasPosition ? window.frame
            : RecordingTransportPlacement.initial(anchor: anchor, visibleFrame: visibleFrame)
        window.setFrame(RecordingTransportPlacement.clamp(proposed, to: visibleFrame), display: true)
        hasPosition = true
    }

    /// Presentation changes never close the take or stop its input monitor.
    func hide() {
        surface?.grip.cancelDrag()
        window?.orderOut(nil)
    }

    func teardown() {
        guard !isRetired else { return }
        isRetired = true
        hide()
        actions = nil
        surface?.retire()
        window?.delegate = nil
        window?.contentView = nil
        window?.close()
        surface = nil
        window = nil
    }

    @objc private func pausePressed() {
        guard !isRetired, snapshot.canPause, !snapshot.busy else { return }
        actions?.pauseResume()
    }
    @objc private func stopPressed() {
        // Busy Pause must not block a Stop accepted by the shared command owner.
        guard !isRetired, snapshot.canStop else { return }
        actions?.stopSave()
    }
    @objc private func expandPressed() {
        guard !isRetired else { return }
        actions?.expand()
    }
}

@MainActor
private final class RecordingTransportPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecordingTransportView: NSView {
    let grip = RecordingTransportGrip()
    let pauseButton = RecordingTransportButton()
    let stopButton = RecordingTransportButton()
    let expandButton = RecordingTransportButton()
    let elapsedLabel = NSTextField(labelWithString: "00:00")
    let statusLabel = NSTextField(labelWithString: "录制中")
    private let indicator = NSImageView()
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("recording.transport.surface")
        setAccessibilityElement(false)
        let content: [NSView] = [grip, indicator, elapsedLabel, statusLabel, pauseButton, stopButton, expandButton]
        for view in content { addSubview(view) }
        elapsedLabel.identifier = .init("recording.transport.elapsed")
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.identifier = .init("recording.transport.status")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        indicator.setAccessibilityElement(false)
        configure(pauseButton, id: "pauseResume")
        configure(stopButton, id: "stopSave")
        configure(expandButton, id: "expand")
        expandButton.image = symbol("arrow.up.left.and.arrow.down.right", description: "展开录屏设置与效果")
        expandButton.setAccessibilityLabel("展开录屏设置与效果")
        expandButton.toolTip = "展开录屏设置与效果；保留当前录制"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func configure(_ button: NSButton, id: String) {
        button.identifier = .init("recording.transport." + id)
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.focusRingType = .exterior
        button.contentTintColor = .labelColor
    }

    private func symbol(_ name: String, description: String, size: CGFloat = 18) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    func display(_ snapshot: RecordingTransportSnapshot) {
        let pauseTitle = snapshot.paused ? "继续录屏" : "暂停录屏"
        pauseButton.image = symbol(snapshot.paused ? "play.fill" : "pause.fill", description: pauseTitle)
        pauseButton.setAccessibilityLabel(pauseTitle)
        pauseButton.toolTip = shortcutHelp(pauseTitle, shortcut: snapshot.pauseShortcut)
        pauseButton.isEnabled = snapshot.canPause && !snapshot.busy
        stopButton.image = symbol("stop.fill", description: "停止并保存 MP4")
        stopButton.contentTintColor = .systemRed
        stopButton.setAccessibilityLabel("停止并保存 MP4")
        stopButton.toolTip = shortcutHelp("停止并保存 MP4", shortcut: snapshot.stopShortcut)
        stopButton.isEnabled = snapshot.canStop
        elapsedLabel.stringValue = snapshot.elapsedLabel
        elapsedLabel.setAccessibilityLabel("已录制 " + snapshot.elapsedLabel)
        statusLabel.stringValue = snapshot.status
        statusLabel.toolTip = snapshot.status
        statusLabel.setAccessibilityLabel(snapshot.status)
        let kind = snapshot.statusKind
        let color: NSColor = kind == .error ? .systemRed : (kind == .paused ? .systemOrange : .secondaryLabelColor)
        statusLabel.textColor = color
        let name = kind == .error ? "exclamationmark.triangle.fill" :
            (kind == .saving ? "arrow.down.circle" : (kind == .paused ? "pause.circle.fill" : "record.circle.fill"))
        indicator.image = symbol(name, description: snapshot.status, size: 12)
        indicator.contentTintColor = kind == .recording || kind == .error ? .systemRed : color
        needsLayout = true
        needsDisplay = true
    }

    private func shortcutHelp(_ title: String, shortcut: String?) -> String {
        guard let shortcut, !shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title + " · 未设置快捷键" }
        return title + " · " + shortcut
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - 32) / 2
        grip.frame = CGRect(x: 4, y: y, width: 20, height: 32)
        let expandX = bounds.width - 36
        expandButton.frame = CGRect(x: expandX, y: y, width: 32, height: 32)
        stopButton.frame = CGRect(x: expandX - 36, y: y, width: 32, height: 32)
        pauseButton.frame = CGRect(x: expandX - 72, y: y, width: 32, height: 32)
        // Labels surrender space first on narrow work areas; all actions and
        // the separate drag grip retain their native hit targets down to 144pt.
        let infoWidth = max(0, pauseButton.frame.minX - 32)
        let showsInfo = infoWidth >= 68
        indicator.isHidden = !showsInfo; elapsedLabel.isHidden = !showsInfo; statusLabel.isHidden = !showsInfo
        indicator.frame = CGRect(x: 28, y: (bounds.height - 14) / 2, width: 14, height: 14)
        elapsedLabel.frame = CGRect(x: 47, y: 20, width: max(0, infoWidth - 19), height: 16)
        statusLabel.frame = CGRect(x: 47, y: 5, width: max(0, infoWidth - 19), height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: dark ? 0.17 : 0.99, alpha: 1).setFill(); path.fill()
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.16)).setStroke()
        path.lineWidth = 0.7; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    func retire() {
        grip.cancelDrag()
        grip.onBegin = nil; grip.onDelta = nil; grip.onEnd = nil
        for button in [pauseButton, stopButton, expandButton] {
            button.target = nil; button.action = nil; button.isEnabled = false
        }
    }
}

@MainActor
final class RecordingTransportButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Only this grip responds to drag handlers. There are no global/local event
/// monitors, nested event loops, screen capture operations or region mutations.
@MainActor
final class RecordingTransportGrip: NSView {
    var onBegin: (() -> Void)?
    var onDelta: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    private var start: CGPoint?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("recording.transport.grip")
        toolTip = "拖动录屏控制条；不移动录制区域"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("移动录屏控制条")
        setAccessibilityHelp(toolTip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        for x in [CGFloat(7), CGFloat(12)] {
            for y in [bounds.midY - 6, bounds.midY, bounds.midY + 6] {
                NSBezierPath(ovalIn: CGRect(x: x, y: y - 1, width: 2, height: 2)).fill()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, onBegin != nil else { return }
        start = window.convertPoint(toScreen: event.locationInWindow)
        onBegin?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        onDelta?(CGPoint(x: point.x - start.x, y: point.y - start.y))
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); cancelDrag() }
    func cancelDrag() { start = nil; onEnd?() }
}
