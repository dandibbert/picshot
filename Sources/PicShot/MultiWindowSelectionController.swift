import AppKit
import PicShotCore

@MainActor
final class MultiWindowSelectionController: NSObject, NSWindowDelegate {
    private(set) var selection: MultiWindowSelection
    private(set) var panels: [MultiWindowSelectionPanel] = []
    private(set) var views: [MultiWindowSelectionView] = []
    private var continuation: CheckedContinuation<[MultiWindowDescriptor], Error>?
    private var sessionID: UUID?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var deadline: TimeInterval = 0
    private let screens: [MultiWindowSelectionScreen]
    private let validate: () throws -> Void

    init(windows: [MultiWindowDescriptor], screens: [MultiWindowSelectionScreen], validate: @escaping () throws -> Void) {
        selection = MultiWindowSelection(windows: windows); self.screens = screens; self.validate = validate
    }
    var isSelecting: Bool { continuation != nil }

    func select() async throws -> [MultiWindowDescriptor] {
        guard sessionID == nil else { throw CaptureError.busy }
        guard !selection.windows.isEmpty, !screens.isEmpty else { throw MultiWindowCaptureError.empty }
        try Task.checkCancellation(); try validate()
        let id = UUID(); sessionID = id
        deadline = ProcessInfo.processInfo.systemUptime + MultiWindowCaptureLimits.selectionSeconds
        defer { tearDown(); sessionID = nil }
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { completion in
                continuation = completion
                show(session: id)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CaptureError.cancelled), session: id) } }
        try Task.checkCancellation(); try validate()
        return result
    }

    private func show(session: UUID) {
        let pointer = NSEvent.mouseLocation
        let controlScreen = screens.first(where: { $0.appKitFrame.contains(pointer) })?.id ?? screens[0].id
        for screen in screens {
            let panel = MultiWindowSelectionPanel(contentRect: screen.appKitFrame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.delegate = self
            panel.level = .screenSaver; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.ignoresMouseEvents = false
            panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = MultiWindowSelectionView(frame: CGRect(origin: .zero, size: screen.appKitFrame.size), screen: screen,
                selection: selection, hasControls: screen.id == controlScreen)
            view.onClick = { [weak self] point, cycle in self?.click(point, cycle: cycle) }
            view.onKey = { [weak self] event in self?.key(event) }
            view.onCapture = { [weak self] in self?.capture() }
            view.onCancel = { [weak self] in self?.finish(.failure(CaptureError.cancelled), session: session) }
            panel.contentView = view; panels.append(panel); views.append(view)
            panel.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        if let index = screens.firstIndex(where: { $0.id == controlScreen }) {
            panels[index].makeKeyAndOrderFront(nil); panels[index].makeFirstResponder(views[index])
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSession(session) }
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish(.failure(CaptureError.cancelled), session: session) }
        }
    }
    private func checkSession(_ session: UUID) {
        guard sessionID == session, continuation != nil else { return }
        do {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
            try validate()
        } catch { finish(.failure(error), session: session) }
    }
    private func click(_ point: CGPoint, cycle: Bool) {
        do {
            try validate()
            guard let id = selection.focus(at: point, cycle: cycle) else { return }
            // Option-click cycles overlapping candidates without toggling them;
            // Space then adds/removes the focused window, including covered ones.
            if !cycle { try selection.toggle(id) }
            refresh()
        } catch { handle(error) }
    }
    private func key(_ event: NSEvent) {
        switch event.keyCode {
        case 53: if let id = sessionID { finish(.failure(CaptureError.cancelled), session: id) }
        case 36, 76: capture()
        case 48: selection.focusNext(backwards: event.modifierFlags.contains(.shift)); refresh()
        case 49:
            do { try validate(); if let id = selection.focusedID { try selection.toggle(id) }; refresh() }
            catch { handle(error) }
        default: break
        }
    }
    private func capture() {
        guard let id = sessionID else { return }
        do {
            try validate()
            _ = try MultiWindowCaptureLayout(frontToBack: selection.selected)
            finish(.success(selection.selected), session: id)
        } catch { handle(error) }
    }
    private func handle(_ error: Error) {
        if let error = error as? MultiWindowCaptureError, [.empty, .windowLimit, .pixelLimit].contains(error) {
            views.forEach { $0.showNotice(error.localizedDescription) }
        } else if let id = sessionID { finish(.failure(error), session: id) }
    }
    private func refresh() { views.forEach { $0.update(selection) } }
    func cancel() { if let id = sessionID { finish(.failure(CaptureError.cancelled), session: id) } }
    func windowWillClose(_ notification: Notification) { cancel() }
    private func finish(_ result: Result<[MultiWindowDescriptor], Error>, session: UUID) {
        guard sessionID == session, let completion = continuation else { return }
        continuation = nil; tearDown(); completion.resume(with: result)
    }
    private func tearDown() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        for panel in panels { panel.delegate = nil; panel.orderOut(nil); panel.close() }
        views.forEach { $0.onClick = nil; $0.onKey = nil; $0.onCapture = nil; $0.onCancel = nil }
        panels.removeAll(); views.removeAll()
    }
}

@MainActor
final class MultiWindowSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class MultiWindowSelectionView: NSView {
    let screen: MultiWindowSelectionScreen
    private(set) var selection: MultiWindowSelection
    private let controls = NSVisualEffectView()
    private let count = NSTextField(labelWithString: "")
    private let focused = NSTextField(labelWithString: "")
    private let help = NSTextField(labelWithString: "点击选/减选 · Tab 切换 · 空格勾选 · ⌥点击重叠窗口 · Esc 取消")
    let captureButton = NSButton(title: "截图 ↩", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    var onClick: ((CGPoint, Bool) -> Void)?
    var onKey: ((NSEvent) -> Void)?
    var onCapture: (() -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(frame: CGRect, screen: MultiWindowSelectionScreen, selection: MultiWindowSelection, hasControls: Bool) {
        self.screen = screen; self.selection = selection
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("multiWindow.selection")
        if hasControls {
            controls.material = .hudWindow; controls.blendingMode = .withinWindow; controls.state = .active
            controls.wantsLayer = true; controls.layer?.cornerRadius = 9; controls.layer?.masksToBounds = true
            addSubview(controls)
            for field in [count, focused, help] { controls.addSubview(field) }
            count.font = .boldSystemFont(ofSize: 13); focused.font = .systemFont(ofSize: 12)
            focused.lineBreakMode = .byTruncatingTail; help.font = .systemFont(ofSize: 10); help.textColor = .secondaryLabelColor
            for button in [captureButton, cancelButton] { button.bezelStyle = .rounded; button.target = self; controls.addSubview(button) }
            captureButton.action = #selector(capture); cancelButton.action = #selector(cancel)
            captureButton.identifier = NSUserInterfaceItemIdentifier("multiWindow.capture")
            cancelButton.identifier = NSUserInterfaceItemIdentifier("multiWindow.cancel")
            captureButton.setAccessibilityLabel("合成所选窗口"); cancelButton.setAccessibilityLabel("取消窗口截图")
        }
        update(selection)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ selection: MultiWindowSelection) {
        self.selection = selection
        count.stringValue = "已选 \(selection.selectedIDs.count) / \(MultiWindowCaptureLimits.windows) 个窗口"
        focused.stringValue = selection.windows.first(where: { $0.id == selection.focusedID })?.label ?? "选择窗口"
        captureButton.isEnabled = !selection.selectedIDs.isEmpty
        setAccessibilityLabel(count.stringValue + "；" + focused.stringValue)
        needsDisplay = true; needsLayout = true
    }
    func showNotice(_ message: String) { focused.stringValue = message; NSSound.beep() }
    override func layout() {
        super.layout()
        let width = min(510, max(1, bounds.width - 24))
        // Capture-adjacent strip stays on-screen, near the focused window's lower
        // edge when there is room; no image dashboard or desktop raster is built.
        let target = selection.windows.first(where: { $0.id == selection.focusedID }).map { screen.localRect(fromQuartz: $0.bounds) }
        let x = min(max(12, (target?.midX ?? bounds.midX) - width / 2), max(12, bounds.width - width - 12))
        let y = min(max(12, (target?.minY ?? 90) - 86), max(12, bounds.height - 88))
        controls.frame = CGRect(x: x, y: y, width: width, height: 76)
        count.frame = CGRect(x: 12, y: 48, width: max(1, width - 176), height: 19)
        focused.frame = CGRect(x: 12, y: 28, width: max(1, width - 24), height: 18)
        help.frame = CGRect(x: 12, y: 8, width: max(1, width - 24), height: 16)
        captureButton.frame = CGRect(x: max(0, width - 92), y: 43, width: 82, height: 28)
        cancelButton.frame = CGRect(x: max(0, width - 157), y: 43, width: 60, height: 28)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        onClick?(screen.quartzPoint(fromLocal: point), event.modifierFlags.contains(.option))
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        // A completely transparent pixel can be click-through in WindowServer,
        // even with ignoresMouseEvents=false. A barely visible wash gives the
        // entire selector a native mouse hit region without freezing the desktop.
        NSColor.black.withAlphaComponent(0.015).setFill(); bounds.fill()
        for window in selection.windows.reversed() where selection.selectedIDs.contains(window.id) || selection.focusedID == window.id {
            let rect = screen.localRect(fromQuartz: window.bounds).insetBy(dx: 1, dy: 1)
            guard rect.intersects(bounds) else { continue }
            let selected = selection.selectedIDs.contains(window.id)
            (selected ? NSColor.systemBlue : NSColor.systemOrange).setStroke()
            let border = NSBezierPath(rect: rect); border.lineWidth = selected ? 3 : 2
            if !selected { border.setLineDash([5, 4], count: 2, phase: 0) }; border.stroke()
            let label = (selected ? "✓ " : "") + window.label
            let textRect = CGRect(x: max(4, rect.minX + 6), y: min(bounds.height - 24, rect.maxY - 24), width: min(360, rect.width - 12), height: 20)
            if textRect.width > 20 {
                NSColor.black.withAlphaComponent(0.78).setFill(); NSBezierPath(roundedRect: textRect.insetBy(dx: -3, dy: -2), xRadius: 3, yRadius: 3).fill()
                (label as NSString).draw(in: textRect, withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
            }
        }
    }
    @objc private func capture() { onCapture?() }
    @objc private func cancel() { onCancel?() }
}
