import AppKit
import PicShotCore

/// Presentation state only. The session owner remains responsible for captures,
/// permissions, retries, serialization, edits and saving the accepted sequence.
struct LiveScrollCaptureSnapshot: Equatable {
    enum StatusKind: String { case capturing, paused, warning, error, finishing }
    var pixelWidth = 0
    var pixelHeight = 0
    var acceptedFrames = 0
    var status = "滚动页面以继续拼接"
    var statusKind: StatusKind = .capturing
    var paused = false
    var busy = false
    var canFinish = false
    var canCopy = false
    var canPause = true
    var showsAutoScroll = true
    var canAutoScroll = false
    var autoScrolling = false
    var axis: ScrollAxis = .vertical
    var canChangeAxis = true
    var showsReverseCrop = false
    var reverseCrop = false
    var canMoveRegion = true
    var canImport = true

    var dimensions: String { "\(max(0, pixelWidth)) × \(max(0, pixelHeight)) px" }
}

struct LiveScrollCaptureActions {
    var finishEdit: () -> Void = {}
    var copy: () -> Void = {}
    var pauseResume: () -> Void = {}
    var autoScroll: () -> Void = {}
    var changeAxis: (ScrollAxis) -> Void = { _ in }
    var reverseCrop: (Bool) -> Void = { _ in }
    var moveRegion: () -> Void = {}
    var importImages: () -> Void = {}
    var help: () -> Void = {}
    var cancel: () -> Void = {}
    var onClose: () -> Void = {}
}

/// Three small native surfaces over the live target, with no activation or input
/// monitors. Neither hiding nor teardown discards or finishes the owner's session.
@MainActor
final class LiveScrollCaptureController: NSObject, NSWindowDelegate {
    private(set) var snapshot = LiveScrollCaptureSnapshot()
    private(set) var placement: LiveScrollCaptureGeometry.Placement?
    private(set) var isRetired = false
    private(set) var toolbarWindow: NSPanel?
    private(set) var outlineWindow: NSPanel?
    private(set) var previewWindow: NSPanel?
    private var surface: LiveScrollToolbarView?
    private var preview: LiveScrollThumbnailView?
    private var actions: LiveScrollCaptureActions?
    private var isShown = false
    private var cancellationRequested = false
    private var closeRequested = false

    /// Supply these to capture filters where application-wide exclusion is absent.
    /// sharingType.none is defense in depth, not SCK display-capture exclusion.
    var captureExcludedWindowIDs: [CGWindowID] {
        [toolbarWindow, outlineWindow, previewWindow].compactMap { window in
            guard let number = window?.windowNumber, number > 0 else { return nil }
            return CGWindowID(number)
        }
    }

    init(actions: LiveScrollCaptureActions) {
        self.actions = actions
        super.init()
        let toolbar = makePanel(identifier: "scroll.live.toolbar", clickThrough: false)
        let outline = makePanel(identifier: "scroll.live.outline", clickThrough: true)
        let thumbnail = makePanel(identifier: "scroll.live.preview", clickThrough: true)
        let view = LiveScrollToolbarView(frame: CGRect(origin: .zero, size: LiveScrollCaptureGeometry.toolbarSize))
        let thumbnailView = LiveScrollThumbnailView(frame: CGRect(x: 0, y: 0, width: 112, height: 240))
        toolbar.contentView = view; outline.contentView = LiveScrollOutlineView(frame: .zero)
        thumbnail.contentView = thumbnailView
        toolbar.delegate = self
        toolbarWindow = toolbar; outlineWindow = outline; previewWindow = thumbnail
        surface = view; preview = thumbnailView
        for (button, selector) in [(view.finishButton, #selector(finishPressed)), (view.copyButton, #selector(copyPressed)),
                                  (view.pauseButton, #selector(pausePressed)), (view.autoButton, #selector(autoPressed)),
                                  (view.cancelButton, #selector(cancelPressed))] {
            button.target = self; button.action = selector
        }
        // NSPopUpButton already has an empty native menu. Install our owned
        // menu once, then keep that identity during live capture updates.
        view.moreButton.menu = makeMoreMenu()
        update(snapshot: snapshot)
    }

    private func makePanel(identifier: String, clickThrough: Bool) -> NSPanel {
        let panel = LiveScrollPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = .init(identifier)
        panel.title = "PicShot · 滚动截图"
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = !clickThrough; panel.ignoresMouseEvents = clickThrough
        panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.sharingType = .none
        return panel
    }

    /// targetFrame and visibleFrame are global AppKit coordinates, not capture pixels.
    func show(snapshot: LiveScrollCaptureSnapshot, targetFrame: CGRect, visibleFrame: CGRect) {
        guard !isRetired else { return }
        update(snapshot: snapshot)
        updatePlacement(targetFrame: targetFrame, visibleFrame: visibleFrame)
        guard placement != nil else { return }
        isShown = true
        outlineWindow?.orderFrontRegardless()
        if placement?.preview.isEmpty == false { previewWindow?.orderFrontRegardless() }
        toolbarWindow?.orderFrontRegardless()
    }

    func update(snapshot: LiveScrollCaptureSnapshot, actions: LiveScrollCaptureActions? = nil) {
        guard !isRetired else { return }
        self.snapshot = snapshot
        if let actions { self.actions = actions }
        surface?.display(snapshot)
        if surface?.moreButton.menu == nil { surface?.moreButton.menu = makeMoreMenu() }
        updateMoreMenu()
        (outlineWindow?.contentView as? LiveScrollOutlineView)?.statusKind = snapshot.statusKind
        preview?.setAccessibilityLabel("滚动拼接预览，\(snapshot.dimensions)，绿色框表示当前页面位置")
    }

    /// One independently owned bounded raster only. Neither the source image nor
    /// any full-resolution stitched output is retained by this presentation layer.
    func updatePreview(image: CGImage?, viewportFraction: CGRect) {
        guard !isRetired else { return }
        preview?.update(image: image, viewportFraction: viewportFraction)
    }

    func updatePreview(image: NSImage, viewportFraction: CGRect) {
        guard !isRetired else { return }
        preview?.update(image: image, viewportFraction: viewportFraction)
    }

    func updatePlacement(targetFrame: CGRect, visibleFrame: CGRect) {
        guard !isRetired else { return }
        guard let next = LiveScrollCaptureGeometry.placement(target: targetFrame, visibleFrame: visibleFrame) else {
            hide(); placement = nil; return
        }
        placement = next
        toolbarWindow?.setFrame(next.toolbar, display: true)
        // Stroke is wholly outside the captured region. The panel is transparent
        // and click-through, including the empty center covering the target.
        outlineWindow?.setFrame(targetFrame.insetBy(dx: -3, dy: -3), display: true)
        if next.preview.isEmpty { previewWindow?.orderOut(nil) }
        else {
            previewWindow?.setFrame(next.preview, display: true)
            if isShown { previewWindow?.orderFrontRegardless() }
        }
        surface?.needsLayout = true
    }

    func hide() {
        isShown = false
        for panel in [toolbarWindow, outlineWindow, previewWindow] { panel?.orderOut(nil) }
    }

    /// Explicit user cancellation only; the owner decides how to retain accepted
    /// pixels. Repeated clicks/close callbacks dispatch one cancellation at most.
    func cancel() {
        guard !isRetired, !cancellationRequested, !closeRequested else { return }
        cancellationRequested = true
        actions?.cancel()
    }
    func close() {
        guard !isRetired, !closeRequested, !cancellationRequested else { return }
        closeRequested = true
        actions?.onClose()
    }
    func windowWillClose(_ notification: Notification) { close() }

    func teardown() {
        guard !isRetired else { return }
        isRetired = true; hide(); actions = nil
        surface?.retire(); preview?.update(image: nil as CGImage?, viewportFraction: .zero)
        for panel in [toolbarWindow, outlineWindow, previewWindow] {
            panel?.delegate = nil; panel?.contentView = nil; panel?.close()
        }
        surface = nil; preview = nil
        toolbarWindow = nil; outlineWindow = nil; previewWindow = nil
        placement = nil
    }

    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let anchor = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        anchor.image = liveScrollSymbol("ellipsis", title: "更多滚动截图选项")
        menu.addItem(anchor)
        func add(_ title: String, _ action: Selector, id: String, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.identifier = .init("scroll.live." + id); item.isEnabled = enabled
            menu.addItem(item); return item
        }
        add("移动选区…", #selector(movePressed), id: "moveRegion", enabled: snapshot.canMoveRegion && !snapshot.busy)
        menu.addItem(.separator())
        let vertical = add("纵向滚动", #selector(verticalPressed), id: "axis.vertical", enabled: snapshot.canChangeAxis && !snapshot.busy)
        vertical.state = snapshot.axis == .vertical ? .on : .off
        let horizontal = add("横向滚动", #selector(horizontalPressed), id: "axis.horizontal", enabled: snapshot.canChangeAxis && !snapshot.busy)
        horizontal.state = snapshot.axis == .horizontal ? .on : .off
        if snapshot.showsReverseCrop {
            let reverse = add("反向自动裁剪", #selector(reversePressed), id: "reverseCrop", enabled: !snapshot.busy)
            reverse.state = snapshot.reverseCrop ? .on : .off
        }
        menu.addItem(.separator())
        add("导入图片…", #selector(importPressed), id: "import", enabled: snapshot.canImport && !snapshot.busy)
        add("滚动截图帮助", #selector(helpPressed), id: "help")
        return menu
    }

    private func updateMoreMenu() {
        // Keep the same menu while it is open. Frequent capture updates must not
        // replace native tracking with a different menu underneath the pointer.
        guard let menu = surface?.moreButton.menu else { return }
        let reverseItem = menu.items.first { $0.identifier?.rawValue == "scroll.live.reverseCrop" }
        if snapshot.showsReverseCrop, reverseItem == nil,
           let axisIndex = menu.items.firstIndex(where: { $0.identifier?.rawValue == "scroll.live.axis.horizontal" }) {
            let item = NSMenuItem(title: "反向自动裁剪", action: #selector(reversePressed), keyEquivalent: "")
            item.target = self; item.identifier = .init("scroll.live.reverseCrop")
            menu.insertItem(item, at: axisIndex + 1)
        } else if !snapshot.showsReverseCrop, let reverseItem { menu.removeItem(reverseItem) }
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "scroll.live.moveRegion": item.isEnabled = snapshot.canMoveRegion && !snapshot.busy
            case "scroll.live.axis.vertical":
                item.isEnabled = snapshot.canChangeAxis && !snapshot.busy
                item.state = snapshot.axis == .vertical ? .on : .off
            case "scroll.live.axis.horizontal":
                item.isEnabled = snapshot.canChangeAxis && !snapshot.busy
                item.state = snapshot.axis == .horizontal ? .on : .off
            case "scroll.live.reverseCrop":
                item.isEnabled = !snapshot.busy; item.state = snapshot.reverseCrop ? .on : .off
            case "scroll.live.import": item.isEnabled = snapshot.canImport && !snapshot.busy
            default: break
            }
        }
    }

    @objc private func finishPressed() { if !isRetired && snapshot.canFinish && !snapshot.busy { actions?.finishEdit() } }
    @objc private func copyPressed() { if !isRetired && snapshot.canCopy && !snapshot.busy { actions?.copy() } }
    @objc private func pausePressed() { if !isRetired && snapshot.canPause && !snapshot.busy { actions?.pauseResume() } }
    @objc private func autoPressed() { if !isRetired && snapshot.canAutoScroll && !snapshot.busy { actions?.autoScroll() } }
    @objc private func cancelPressed() { cancel() }
    @objc private func verticalPressed() { if !isRetired && snapshot.canChangeAxis && !snapshot.busy { actions?.changeAxis(.vertical) } }
    @objc private func horizontalPressed() { if !isRetired && snapshot.canChangeAxis && !snapshot.busy { actions?.changeAxis(.horizontal) } }
    @objc private func reversePressed() { if !isRetired && snapshot.showsReverseCrop && !snapshot.busy { actions?.reverseCrop(!snapshot.reverseCrop) } }
    @objc private func movePressed() { if !isRetired && snapshot.canMoveRegion && !snapshot.busy { actions?.moveRegion() } }
    @objc private func importPressed() { if !isRetired && snapshot.canImport && !snapshot.busy { actions?.importImages() } }
    @objc private func helpPressed() { if !isRetired { actions?.help() } }
}

@MainActor
private final class LiveScrollPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private func liveScrollSymbol(_ name: String, title: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: title)?
        .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
}

@MainActor
final class LiveScrollToolbarView: NSView {
    let finishButton = LiveScrollButton()
    let copyButton = LiveScrollButton()
    let pauseButton = LiveScrollButton()
    let autoButton = LiveScrollButton()
    let moreButton = LiveScrollMoreButton(frame: .zero, pullsDown: true)
    let cancelButton = LiveScrollButton()
    let dimensionLabel = NSTextField(labelWithString: "0 × 0 px")
    let statusLabel = NSTextField(labelWithString: "滚动页面以继续拼接")
    private let statusIndicator = NSImageView()
    private var showsAutoScroll = true
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = .init("scroll.live.surface")
        for view in [finishButton, copyButton, pauseButton, autoButton, moreButton, cancelButton,
                     dimensionLabel, statusLabel, statusIndicator] as [NSView] { addSubview(view) }
        for (button, id, symbol, title) in [
            (finishButton, "finish", "checkmark", "完成并编辑"), (copyButton, "copy", "square.on.square", "复制长截图"),
            (pauseButton, "pauseResume", "pause.fill", "暂停捕获"), (autoButton, "autoScroll", "arrow.down.to.line", "自动滚动"),
            (cancelButton, "cancel", "xmark", "取消滚动截图")
        ] {
            button.identifier = .init("scroll.live." + id)
            button.setButtonType(.momentaryChange); button.isBordered = false
            button.imagePosition = .imageOnly; button.imageScaling = .scaleNone
            button.image = liveScrollSymbol(symbol, title: title)
            button.setAccessibilityLabel(title); button.toolTip = title
            button.contentTintColor = .labelColor
        }
        finishButton.title = "完成并编辑"; finishButton.imagePosition = .imageLeading
        finishButton.font = .systemFont(ofSize: 12, weight: .medium)
        finishButton.contentTintColor = .systemGreen
        moreButton.identifier = .init("scroll.live.more")
        moreButton.isBordered = false; moreButton.imagePosition = .imageOnly
        moreButton.imageScaling = .scaleNone
        (moreButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        moreButton.setAccessibilityLabel("更多滚动截图选项"); moreButton.toolTip = "移动选区 · 方向 · 导入 · 帮助"
        dimensionLabel.identifier = .init("scroll.live.dimensions")
        dimensionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.identifier = .init("scroll.live.status")
        statusLabel.font = .systemFont(ofSize: 11)
        for label in [dimensionLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        }
        statusIndicator.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func display(_ snapshot: LiveScrollCaptureSnapshot) {
        dimensionLabel.stringValue = snapshot.dimensions
        dimensionLabel.setAccessibilityLabel("已拼接尺寸 \(snapshot.dimensions)，\(max(0, snapshot.acceptedFrames)) 帧")
        dimensionLabel.toolTip = dimensionLabel.accessibilityLabel()
        statusLabel.stringValue = snapshot.status; statusLabel.toolTip = snapshot.status
        statusLabel.setAccessibilityLabel(snapshot.status)
        let warning = snapshot.statusKind == .warning || snapshot.statusKind == .paused
        let error = snapshot.statusKind == .error
        statusLabel.textColor = error ? .systemRed : (warning ? .systemOrange : .secondaryLabelColor)
        statusIndicator.image = liveScrollSymbol(error || warning ? "exclamationmark.circle.fill" : "circle.fill", title: snapshot.status)
        statusIndicator.contentTintColor = error ? .systemRed : (warning ? .systemOrange : .systemGreen)
        let title = error ? "重试捕获" : (snapshot.paused ? "继续捕获" : "暂停捕获")
        pauseButton.image = liveScrollSymbol(error ? "arrow.clockwise" : (snapshot.paused ? "play.fill" : "pause.fill"), title: title)
        pauseButton.setAccessibilityLabel(title); pauseButton.toolTip = title
        pauseButton.isEnabled = snapshot.canPause && !snapshot.busy
        finishButton.isEnabled = snapshot.canFinish && !snapshot.busy
        copyButton.isEnabled = snapshot.canCopy && !snapshot.busy
        showsAutoScroll = snapshot.showsAutoScroll
        autoButton.isHidden = !showsAutoScroll; autoButton.isEnabled = snapshot.canAutoScroll && !snapshot.busy
        autoButton.contentTintColor = snapshot.autoScrolling ? .systemGreen : .labelColor
        autoButton.toolTip = snapshot.autoScrolling ? "停止自动滚动" : (snapshot.canAutoScroll ? "自动滚动" : "自动滚动需要辅助功能权限")
        autoButton.setAccessibilityLabel(snapshot.autoScrolling ? "停止自动滚动" : "自动滚动")
        moreButton.isEnabled = true; cancelButton.isEnabled = true
        moreButton.toolTip = snapshot.showsReverseCrop ? "移动选区 · 方向 · 反向裁剪 · 导入 · 帮助" : "移动选区 · 方向 · 导入 · 帮助"
        needsLayout = true; needsDisplay = true
    }

    override func layout() {
        super.layout()
        dimensionLabel.frame = CGRect(x: 10, y: bounds.height - 22, width: bounds.width - 20, height: 16)
        statusIndicator.frame = CGRect(x: 10, y: bounds.height - 37, width: 10, height: 10)
        statusLabel.frame = CGRect(x: 25, y: bounds.height - 40, width: bounds.width - 35, height: 16)
        if bounds.width >= LiveScrollCaptureGeometry.toolbarSize.width {
            finishButton.frame = CGRect(x: 8, y: 8, width: 104, height: 34)
            var x: CGFloat = 116
            for button in [copyButton, pauseButton, autoButton, moreButton, cancelButton] as [NSView] where !button.isHidden {
                button.frame = CGRect(x: x, y: 8, width: 34, height: 34); x += 38
            }
        } else {
            finishButton.frame = CGRect(x: 8, y: 46, width: 104, height: 34)
            copyButton.frame = CGRect(x: bounds.width - 42, y: 46, width: 34, height: 34)
            var x: CGFloat = 8
            for button in [pauseButton, autoButton, moreButton, cancelButton] as [NSView] where !button.isHidden {
                button.frame = CGRect(x: x, y: 8, width: 34, height: 34); x += 38
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) { drawLiveScrollSurface(bounds, appearance: effectiveAppearance) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    func retire() {
        for button in [finishButton, copyButton, pauseButton, autoButton, cancelButton] {
            button.target = nil; button.action = nil; button.isEnabled = false
        }
        moreButton.menu?.cancelTracking()
        moreButton.menu?.items.forEach { $0.target = nil; $0.action = nil }
        moreButton.menu = nil; moreButton.isEnabled = false
    }
}

@MainActor
final class LiveScrollButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, alphaValue > 0,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
}

@MainActor
final class LiveScrollMoreButton: NSPopUpButton {
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }
    override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, alphaValue > 0,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
}

@MainActor
private final class LiveScrollOutlineView: NSView {
    var statusKind: LiveScrollCaptureSnapshot.StatusKind = .capturing { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = statusKind == .error ? .systemRed :
            ((statusKind == .warning || statusKind == .paused) ? .systemOrange : .systemGreen)
        color.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 2; border.stroke()
    }
}

@MainActor
func drawLiveScrollSurface(_ rect: CGRect, appearance: NSAppearance) {
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
    NSColor(calibratedWhite: dark ? 0.17 : 0.99, alpha: 1).setFill(); path.fill()
    (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.16)).setStroke()
    path.lineWidth = 0.7; path.stroke()
}
