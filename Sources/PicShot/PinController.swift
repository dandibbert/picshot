import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Pixel edits are independent from a pin's presentation zoom, opacity, and position.
enum PinTransform: CaseIterable {
    case rotateClockwise, flipHorizontal, flipVertical, grayscale, invert

    var title: String {
        switch self {
        case .rotateClockwise: return "顺时针旋转 90°"
        case .flipHorizontal: return "水平翻转"
        case .flipVertical: return "垂直翻转"
        case .grayscale: return "灰度"
        case .invert: return "反色"
        }
    }
}

/// Stateless raster helpers. Crops use image pixels with a bottom-left origin.
/// Allocation checks happen before rendering; no intermediate image history is cached.
enum PinImageRenderer {
    static let maximumRasterPixels = 32_000_000
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let filterContext = CIContext(options: [.cacheIntermediates: false])

    static func allowsRasterSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= Int.max / 4 && width <= maximumRasterPixels / height
    }

    static func render(image: CGImage, transform: PinTransform) -> CGImage? {
        guard allowsRasterSize(width: image.width, height: image.height) else { return nil }
        let source = CIImage(cgImage: image)
        let output: CIImage
        switch transform {
        case .rotateClockwise: output = source.oriented(.right)
        case .flipHorizontal: output = source.oriented(.upMirrored)
        case .flipVertical: output = source.oriented(.downMirrored)
        case .grayscale: output = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .invert: output = source.applyingFilter("CIColorInvert")
        }
        // Eager materialization prevents successive edits retaining a deferred CIImage graph.
        return filterContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace, deferred: false)
    }

    static func crop(image: CGImage, to rectangle: CGRect) -> CGImage? {
        guard [rectangle.origin.x, rectangle.origin.y, rectangle.size.width, rectangle.size.height].allSatisfy({ $0.isFinite }),
              rectangle.width != 0, rectangle.height != 0 else { return nil }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rectangle.standardized.intersection(extent)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let region = clipped.integral.intersection(extent)
        let width = Int(region.width), height = Int(region.height)
        guard allowsRasterSize(width: width, height: height),
              let part = image.cropping(to: CGRect(x: region.minX, y: CGFloat(image.height) - region.maxY,
                                                   width: region.width, height: region.height)),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        // Re-rasterize the crop so it cannot retain a chain of earlier transformed images.
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Exactly two retained image versions, regardless of the number of edits.
struct PinImageState {
    let original: CGImage
    private(set) var current: CGImage
    private(set) var isModified = false

    init(image: CGImage) { original = image; current = image }

    @discardableResult mutating func apply(_ transform: PinTransform) -> Bool {
        guard let rendered = PinImageRenderer.render(image: current, transform: transform) else { return false }
        current = rendered; isModified = true
        return true
    }

    @discardableResult mutating func crop(to rectangle: CGRect) -> Bool {
        guard let rendered = PinImageRenderer.crop(image: current, to: rectangle) else { return false }
        current = rendered; isModified = true
        return true
    }

    mutating func reset() { current = original; isModified = false }
}

@MainActor final class PinController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    /// Original capture, kept compatible with the application's pin bookkeeping.
    let image: CGImage
    var onClose: (() -> Void)?
    var currentImage: CGImage { state.current }
    private var state: PinImageState
    private let canvas = PinCanvas()
    private let scrollView = NSScrollView()
    private let zoomPicker = NSPopUpButton()
    private let opacity = NSSlider(value: 1, minValue: 0.15, maxValue: 1, target: nil, action: nil)
    private let cropButton = NSButton()
    private var fixedZoom: CGFloat?
    private var locked = false
    private var closed = false
    private var updatingLayout = false
    private var exportPanel: NSSavePanel?
    private let toolbarHeight: CGFloat = 36

    init(image: CGImage) {
        self.image = image
        state = PinImageState(image: image)
        let scale = min(1, 680 / CGFloat(max(image.width, image.height)))
        let size = NSSize(width: max(344, CGFloat(image.width) * scale), height: max(120, CGFloat(image.height) * scale) + 36)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 344, height: 116)
        panel.center()

        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true; scrollView.borderType = .noBorder
        scrollView.drawsBackground = false; scrollView.documentView = canvas
        canvas.image = image
        canvas.onCrop = { [weak self] rectangle in self?.applyCrop(rectangle) }
        canvas.onCancelCrop = { [weak self] in self?.setCropping(false) }
        canvas.onSelectionChanged = { [weak self] in self?.updateCropButton() }
        canvas.menu = makeActionMenu()

        let copy = button(symbol: "doc.on.doc", title: "复制当前图片", action: #selector(copyPin))
        let save = button(symbol: "square.and.arrow.down", title: "保存当前图片为 PNG", action: #selector(savePin))
        let actions = NSPopUpButton(frame: .zero, pullsDown: true)
        actions.bezelStyle = .texturedRounded; actions.controlSize = .small
        let actionMenu = makeActionMenu()
        let heading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        heading.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "更多贴图操作")
        actionMenu.insertItem(heading, at: 0); actions.menu = actionMenu
        actions.toolTip = "旋转、翻转、滤镜、原图、锁定与鼠标穿透"
        actions.setAccessibilityLabel("更多贴图操作")
        configure(cropButton, symbol: "crop", title: "裁剪：拖动选择，回车确认，Esc 取消", action: #selector(toggleCrop))
        zoomPicker.addItems(withTitles: ["适合", "25%", "50%", "100%", "200%", "400%"])
        zoomPicker.target = self; zoomPicker.action = #selector(changeZoom(_:))
        zoomPicker.controlSize = .small; zoomPicker.toolTip = "显示缩放；复制和保存仍使用当前图片像素"
        zoomPicker.setAccessibilityLabel("贴图缩放")
        opacity.target = self; opacity.action = #selector(changeOpacity(_:)); opacity.controlSize = .small
        opacity.toolTip = "窗口不透明度 15%–100%；不会改变导出的图片"
        opacity.setAccessibilityLabel("贴图不透明度")
        let alphaIcon = NSImageView(image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "不透明度")!)
        let bar = NSStackView(views: [copy, save, actions, cropButton, zoomPicker, alphaIcon, opacity])
        bar.orientation = .horizontal; bar.spacing = 5
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let root = NSView(); root.addSubview(scrollView); root.addSubview(bar); panel.contentView = root
        scrollView.translatesAutoresizingMaskIntoConstraints = false; bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor), scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor), scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor), bar.heightAnchor.constraint(equalToConstant: toolbarHeight),
            actions.widthAnchor.constraint(equalToConstant: 42), zoomPicker.widthAnchor.constraint(equalToConstant: 72),
            alphaIcon.widthAnchor.constraint(equalToConstant: 16), opacity.widthAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])
        root.layoutSubtreeIfNeeded(); updateLayout(); updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.title = ""; button.target = self; button.action = action
        button.bezelStyle = .texturedRounded; button.controlSize = .small
        button.toolTip = title; button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }
    private func button(symbol: String, title: String, action: Selector) -> NSButton {
        let result = NSButton(); configure(result, symbol: symbol, title: title, action: action); return result
    }

    private func makeActionMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        for (index, transform) in PinTransform.allCases.enumerated() {
            let item = menu.addItem(withTitle: transform.title, action: #selector(transformImage(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
        }
        menu.addItem(.separator())
        for (title, action) in [("裁剪当前图片…", #selector(toggleCrop)), ("恢复原图", #selector(resetImage)),
                                ("复制当前图片", #selector(copyPin)), ("保存当前图片为 PNG…", #selector(savePin)),
                                ("复制原始图片", #selector(copyOriginal)), ("保存原始图片为 PNG…", #selector(saveOriginal))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        for (title, action) in [("适合窗口", #selector(fitToWindow)), ("100% 像素尺寸", #selector(actualSize)),
                                ("锁定位置与窗口大小", #selector(toggleLock)), ("鼠标穿透（菜单栏恢复所有贴图）", #selector(clickThrough)),
                                ("关闭贴图", #selector(closePin))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(toggleLock) { item.state = locked ? .on : .off }
            if item.action == #selector(toggleCrop) { item.state = canvas.isCropping ? .on : .off }
        }
    }

    @objc private func transformImage(_ sender: NSMenuItem) {
        guard PinTransform.allCases.indices.contains(sender.tag), exportPanel == nil else { return }
        guard state.apply(PinTransform.allCases[sender.tag]) else { reportRenderFailure(); return }
        imageDidChange()
    }
    private func applyCrop(_ rectangle: CGRect) {
        guard exportPanel == nil else { return }
        guard state.crop(to: rectangle) else { reportRenderFailure(); return }
        imageDidChange()
    }
    @objc private func resetImage() { guard exportPanel == nil else { return }; state.reset(); imageDidChange() }
    private func imageDidChange() {
        setCropping(false); canvas.image = state.current
        updateLayout(); updateTitle()
    }
    private func reportRenderFailure() {
        showError(PicShotError.message("无法处理此图片。贴图变换最多支持 3200 万像素；也可能内存不足。原图和当前图片未改变。"))
    }

    @objc private func toggleCrop() {
        guard exportPanel == nil else { return }
        if canvas.isCropping, let rectangle = canvas.selection, rectangle.width >= 1, rectangle.height >= 1 { applyCrop(rectangle) }
        else { setCropping(!canvas.isCropping) }
    }
    private func setCropping(_ value: Bool) {
        canvas.isCropping = value; canvas.selection = nil
        if value { window?.makeFirstResponder(canvas) }
        updateCropButton(); updateTitle()
    }
    private func updateCropButton() {
        let ready = canvas.isCropping && canvas.selection != nil
        cropButton.image = NSImage(systemSymbolName: ready ? "checkmark" : "crop", accessibilityDescription: ready ? "应用裁剪" : "裁剪")
        cropButton.state = canvas.isCropping ? .on : .off
    }

    @objc private func copyPin() { copyImage(state.current) }
    @objc private func copyOriginal() { copyImage(image) }
    @objc private func savePin() { save(original: false) }
    @objc private func saveOriginal() { save(original: true) }
    private func save(original: Bool) {
        guard let window, exportPanel == nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.canCreateDirectories = true
        panel.title = original ? "保存原始图片" : "保存当前图片"
        panel.nameFieldStringValue = original ? "PicShot-original.png" : "PicShot-pin.png"
        exportPanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.exportPanel = nil
            guard !self.closed, response == .OK, let url = panel?.url else { return }
            do { try (original ? self.image : self.state.current).writePNG(to: url) }
            catch { showError(error) }
        }
    }

    @objc private func changeOpacity(_ sender: NSSlider) { window?.alphaValue = sender.doubleValue }
    @objc private func changeZoom(_ sender: NSPopUpButton) {
        let scales: [CGFloat?] = [nil, 0.25, 0.5, 1, 2, 4]
        guard scales.indices.contains(sender.indexOfSelectedItem) else { return }
        fixedZoom = scales[sender.indexOfSelectedItem]; updateLayout(); updateTitle()
    }
    @objc private func fitToWindow() { fixedZoom = nil; zoomPicker.selectItem(at: 0); updateLayout(); updateTitle() }
    @objc private func actualSize() { fixedZoom = 1; zoomPicker.selectItem(at: 3); updateLayout(); updateTitle() }
    @objc private func toggleLock() {
        locked.toggle(); window?.isMovable = !locked
        if locked { window?.styleMask.remove(.resizable) } else { window?.styleMask.insert(.resizable) }
        updateTitle()
    }
    @objc private func clickThrough() { setCropping(false); window?.ignoresMouseEvents = true }
    @objc private func closePin() { close() }

    /// Always leaves a way back from click-through, extreme opacity, or an offscreen pin.
    func restore() {
        window?.ignoresMouseEvents = false; window?.alphaValue = 1; opacity.doubleValue = 1
        window?.center(); showWindow(nil); window?.orderFrontRegardless()
    }
    func windowDidResize(_ notification: Notification) { updateLayout(); updateTitle() }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true
        exportPanel?.cancel(nil); exportPanel = nil
        canvas.onCrop = nil; canvas.onCancelCrop = nil; canvas.onSelectionChanged = nil
        let completion = onClose; onClose = nil; completion?()
    }

    private func updateTitle() {
        let suffix = canvas.isCropping ? " · 拖动选择，回车裁剪 / Esc 取消" : (locked ? " · 已锁定" : "")
        let edited = state.isModified ? " · 已修改" : ""
        window?.title = "贴图 · \(state.current.width) × \(state.current.height) · \(Int((canvas.zoom * 100).rounded()))%\(edited)\(suffix)"
    }
    private func updateLayout() {
        guard !updatingLayout else { return }; updatingLayout = true; defer { updatingLayout = false }
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let zoom = fixedZoom ?? min(1, min(viewport.width / CGFloat(state.current.width), viewport.height / CGFloat(state.current.height)))
        canvas.zoom = max(CGFloat.leastNonzeroMagnitude, zoom)
        canvas.setFrameSize(NSSize(width: max(viewport.width, CGFloat(state.current.width) * canvas.zoom),
                                   height: max(viewport.height, CGFloat(state.current.height) * canvas.zoom)))
        canvas.needsDisplay = true
    }
}

@MainActor private final class PinCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1
    var isCropping = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var selection: CGRect? { didSet { needsDisplay = true; onSelectionChanged?() } }
    var onCrop: ((CGRect) -> Void)?
    var onCancelCrop: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    private var anchor: CGPoint?
    override var acceptsFirstResponder: Bool { true }

    private var imageRect: CGRect {
        guard let image else { return .zero }
        let size = CGSize(width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, (location.x - imageRect.minX) / zoom), CGFloat(image?.width ?? 0)),
                       y: min(max(0, (location.y - imageRect.minY) / zoom), CGFloat(image?.height ?? 0)))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = zoom > 1 ? .none : .high
        context.draw(image, in: imageRect)
        guard isCropping, let selection else { return }
        let visibleSelection = CGRect(x: imageRect.minX + selection.minX * zoom, y: imageRect.minY + selection.minY * zoom,
                                      width: selection.width * zoom, height: selection.height * zoom)
        context.saveGState()
        context.addRect(imageRect); context.addRect(visibleSelection); context.clip(using: .evenOdd)
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor); context.fill(imageRect)
        context.restoreGState()
        context.setLineWidth(1); context.setStrokeColor(NSColor.white.cgColor)
        context.setLineDash(phase: 0, lengths: [5, 3]); context.stroke(visibleSelection)
    }
    override func resetCursorRects() { if isCropping { addCursorRect(imageRect, cursor: .crosshair) } }
    override func mouseDown(with event: NSEvent) {
        if !isCropping {
            if window?.isMovable == true { window?.performDrag(with: event) }
            return
        }
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self); anchor = imagePoint(event); selection = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard isCropping, let anchor else { return }
        let point = imagePoint(event)
        let rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        selection = rect.width >= 1 && rect.height >= 1 ? rect : nil
        autoscroll(with: event)
    }
    override func mouseUp(with event: NSEvent) { anchor = nil }
    override func keyDown(with event: NSEvent) {
        if isCropping && event.keyCode == 53 { anchor = nil; onCancelCrop?(); return }
        if isCropping && (event.keyCode == 36 || event.keyCode == 76) {
            if let selection { onCrop?(selection) } else { NSSound.beep() }
            return
        }
        super.keyDown(with: event)
    }
}
