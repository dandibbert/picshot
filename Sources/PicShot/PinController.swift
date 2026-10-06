import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// Pixel edits are independent from a pin's presentation zoom, opacity, and position.
enum PinTransform: CaseIterable {
    case rotateClockwise, rotateCounterclockwise, flipHorizontal, flipVertical, grayscale, invert

    var title: String {
        switch self {
        case .rotateClockwise: return "向右旋转 90°"
        case .rotateCounterclockwise: return "向左旋转 90°"
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
        case .rotateCounterclockwise: output = source.oriented(.left)
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
    init(original: CGImage, current: CGImage, isModified: Bool) {
        self.original = original; self.current = current; self.isModified = isModified
    }

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
    /// Invoked before accepting an edit. A persistence failure leaves the live image unchanged.
    var onPixelChange: ((CGImage, Bool) throws -> Void)?
    var onPresentationChange: ((PinPresentation) -> Void)?
    var currentImage: CGImage { state.current }
    private var state: PinImageState
    private var pixelRevision: UInt = 0
    private let canvas = PinCanvas()
    private let scrollView = NSScrollView()
    private var fixedZoom: CGFloat?
    private var locked = false
    private var closed = false
    private var updatingLayout = false
    private var applyingPresentation = false
    private(set) weak var imageExportController: ImageExportController?
    private var exportInProgress: Bool { imageExportController?.isClosed == false }
    private(set) var annotationEditor: ImageEditorController?
    private var annotationGeneration = UUID()
    private var restorePinAfterAnnotations = false
    private var temporarilyHidden = false
    private(set) var recognitionWindow: TextResultController?
    private var recognitionTask: Task<Void, Never>?
    private var recognitionGeneration = UUID()
    private let recognizeForSelection: @Sendable (CGImage) async throws -> RecognitionResult
    let textSelectionOverlay = PinTextSelectionOverlay()
    private var textSelectionTask: Task<Void, Never>?
    private var textSelectionGeneration = UUID()
    private var textSelectionControl: NSButton?
    private(set) var textSelectionEnabled = false
    private(set) var textSelectionIsRecognizing = false
    private(set) var textSelectionStatus = ""
    private let recognizeCodes: @Sendable (CGImage) async throws -> RecognizedBarcodeDocument
    let barcodeSelectionOverlay = BarcodeSelectionOverlay()
    private(set) var barcodeWindow: BarcodeResultController?
    private var barcodeTask: Task<Void, Never>?
    private var barcodeGeneration = UUID()
    private var barcodeControl: NSButton?
    private(set) var barcodeSelectionEnabled = false
    private(set) var barcodeIsRecognizing = false
    private(set) var barcodeStatus = ""
    var actionMenu: NSMenu? { canvas.menu }

    convenience init(image: CGImage) {
        self.init(originalImage: image, currentImage: image, isModified: false)
    }

    init(originalImage: CGImage, currentImage: CGImage, isModified: Bool,
         recognizeForSelection: @escaping @Sendable (CGImage) async throws -> RecognitionResult = { try await RecognitionService.recognize($0) },
         recognizeCodes: @escaping @Sendable (CGImage) async throws -> RecognizedBarcodeDocument = { try await RecognitionService.recognizeBarcodes($0) }) {
        self.recognizeForSelection = recognizeForSelection; self.recognizeCodes = recognizeCodes
        image = originalImage
        state = PinImageState(original: originalImage, current: currentImage, isModified: isModified)
        let scale = min(1, 680 / CGFloat(max(currentImage.width, currentImage.height)))
        let size = NSSize(width: max(32, CGFloat(currentImage.width) * scale), height: max(24, CGFloat(currentImage.height) * scale))
        let panel = PinPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.delegate = self
        panel.isExcludedFromWindowsMenu = true; panel.hasShadow = true
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 32, height: 24)
        panel.center()

        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .overlay; scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder; scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false; scrollView.documentView = canvas
        canvas.image = currentImage
        canvas.onCrop = { [weak self] rectangle in self?.applyCrop(rectangle) }
        canvas.onCancelCrop = { [weak self] in self?.setCropping(false) }
        canvas.onAnnotate = { [weak self] in self?.showAnnotations() }
        canvas.onClose = { [weak self] in self?.close() }
        canvas.onCopy = { [weak self] in self?.copyPin() }
        canvas.onToggleTextSelection = { [weak self] in self?.toggleTextSelection() }
        textSelectionOverlay.onExit = { [weak self] in self?.setTextSelectionEnabled(false) }
        textSelectionOverlay.onAnnotate = { [weak self] in self?.showAnnotations() }
        canvas.textSelectionOverlay = textSelectionOverlay
        barcodeSelectionOverlay.onExit = { [weak self] in self?.setBarcodeSelectionEnabled(false) }
        barcodeSelectionOverlay.onAnnotate = { [weak self] in self?.showAnnotations() }
        barcodeSelectionOverlay.onSelect = { [weak self] in self?.barcodeWindow?.selectResult(at: $0, notify: false) }
        barcodeSelectionOverlay.onCopy = { [weak self] in self?.barcodeWindow?.copySelected(to: .general) }
        canvas.barcodeSelectionOverlay = barcodeSelectionOverlay
        canvas.menu = makeActionMenu()
        textSelectionOverlay.menu = canvas.menu
        canvas.setAccessibilityLabel("图片贴图，空格标注，Command Shift T 选择文字，右键显示操作")
        let root = NSView(); root.addSubview(scrollView); panel.contentView = root
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor), scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor), scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        panel.initialFirstResponder = canvas
        root.layoutSubtreeIfNeeded(); updateLayout(); updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeActionMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        let recognition = NSMenu(title: "识别")
        let selection = addItem("选择图片文字", action: #selector(toggleTextSelection), key: "t", to: recognition)
        selection.keyEquivalentModifierMask = [.command, .shift]
        addItem("识别二维码 / 条码…", action: #selector(toggleBarcodeSelection), to: recognition)
        recognition.addItem(.separator())
        addItem("识别文字…", action: #selector(recognizeText), to: recognition)
        addItem("直接复制识别文本", action: #selector(copyRecognizedText), to: recognition)
        recognition.delegate = self
        addItem("下次直接复制文本", action: #selector(toggleDirectCopy), to: recognition)
        menu.addItem(withTitle: "识别", action: nil, keyEquivalent: "").submenu = recognition
        let processing = NSMenu(title: "图像处理"); processing.delegate = self
        for (index, transform) in PinTransform.allCases.enumerated() {
            let item = addItem(transform.title, action: #selector(transformImage(_:)), to: processing)
            item.tag = index
        }
        processing.addItem(.separator())
        let alpha = NSMenu(title: "不透明度"); alpha.delegate = self
        for percent in [100, 80, 60, 40, 20, 15] {
            let item = addItem("\(percent)%", action: #selector(selectOpacity(_:)), to: alpha); item.tag = percent
        }
        processing.addItem(withTitle: "不透明度", action: nil, keyEquivalent: "").submenu = alpha
        addItem("重置所有处理", action: #selector(resetImage), to: processing)
        menu.addItem(withTitle: "图像处理", action: nil, keyEquivalent: "").submenu = processing
        addItem("复制当前图像", action: #selector(copyPin), to: menu)
        addItem("当前图像另存为…", action: #selector(savePin), to: menu)
        menu.addItem(.separator())
        addItem("标注", action: #selector(showAnnotations), key: " ", to: menu)
        addItem("裁剪当前图片…", action: #selector(toggleCrop), to: menu)
        let zoom = NSMenu(title: "缩放"); zoom.delegate = self
        for (index, title) in ["适合窗口", "25%", "50%", "100%", "200%", "400%"].enumerated() {
            let item = addItem(title, action: #selector(selectZoom(_:)), to: zoom); item.tag = index
        }
        menu.addItem(withTitle: "缩放", action: nil, keyEquivalent: "").submenu = zoom
        addItem("鼠标穿透（菜单栏恢复当前组）", action: #selector(clickThrough), to: menu)
        addItem("窗口阴影", action: #selector(toggleShadow), to: menu)
        addItem("窗口置顶", action: #selector(toggleFloating), to: menu)
        menu.addItem(.separator())
        let original = NSMenu(title: "原始图片")
        addItem("复制原始图片", action: #selector(copyOriginal), to: original)
        addItem("原始图片另存为…", action: #selector(saveOriginal), to: original)
        menu.addItem(withTitle: "原始图片", action: nil, keyEquivalent: "").submenu = original
        addItem("锁定", action: #selector(toggleLock), to: menu)
        addItem("关闭", action: #selector(closePin), key: "\u{1b}", to: menu)
        return menu
    }

    @discardableResult private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self; item.keyEquivalentModifierMask = []; return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(toggleTextSelection) {
                item.state = textSelectionEnabled ? .on : .off
                item.title = textSelectionIsRecognizing ? "正在识别文字（取消）" : "选择图片文字"
            }
            if item.action == #selector(toggleBarcodeSelection) {
                item.state = barcodeSelectionEnabled ? .on : .off
                item.title = barcodeIsRecognizing ? "正在识别码（取消）" : "识别二维码 / 条码…"
            }
            if item.action == #selector(toggleDirectCopy) { item.state = TextResultController.copyDirectlyNextTime ? .on : .off }
            if item.action == #selector(toggleLock) { item.state = locked ? .on : .off }
            if item.action == #selector(toggleCrop) { item.state = canvas.isCropping ? .on : .off }
            if item.action == #selector(toggleShadow) { item.state = window?.hasShadow == true ? .on : .off }
            if item.action == #selector(toggleFloating) { item.state = window?.level == .floating ? .on : .off }
            if item.action == #selector(selectOpacity(_:)) { item.state = abs(Double(window?.alphaValue ?? 1) - Double(item.tag) / 100) < 0.005 ? .on : .off }
            if item.action == #selector(selectZoom(_:)) {
                let scales: [CGFloat?] = [nil, 0.25, 0.5, 1, 2, 4]
                item.state = scales[item.tag] == fixedZoom ? .on : .off
            }
        }
    }

    /// Both rectangles are in screen points, including the pin's current zoom and scroll offset.
    var annotationPresentation: PinEditorPresentation? {
        guard !closed, let window else { return nil }
        updateLayout()
        let clip = scrollView.contentView
        return PinEditorPresentation(viewportFrame: window.convertToScreen(clip.convert(clip.bounds, to: nil)),
                                     imageFrame: window.convertToScreen(canvas.convert(canvas.imageRect, to: nil)),
                                     opacity: window.alphaValue, level: window.level)
    }

    @objc func showAnnotations() {
        guard !closed, !temporarilyHidden, !exportInProgress else { return }
        if let annotationEditor { annotationEditor.showWindow(nil); annotationEditor.window?.makeKeyAndOrderFront(nil); return }
        guard let anchor = annotationPresentation else { return }
        setTextSelectionEnabled(false); setBarcodeSelectionEnabled(false)
        setCropping(false)
        let generation = UUID(); annotationGeneration = generation
        var editingRevision = pixelRevision
        let apply: (CGImage) -> Bool = { [weak self] image in
            guard let self, !self.closed, !self.temporarilyHidden, self.annotationGeneration == generation,
                  self.annotationEditor != nil, !self.exportInProgress else { return false }
            guard self.pixelRevision == editingRevision else {
                showError(PicShotError.message("贴图已在其他操作中更改。当前标注仍可复制或导出；请重新打开标注后再应用到贴图。")); return false
            }
            do {
                try self.applyAnnotatedImage(image); editingRevision = self.pixelRevision; return true
            } catch { showError(error); return false }
        }
        let editor = ImageEditorController(image: state.current, onSave: { [weak self] image in
            if apply(image) { self?.annotationEditor?.close() }
        }, onPin: { _ = apply($0) }, onOCR: { [weak self] image in
            guard let self, self.annotationGeneration == generation, self.annotationEditor != nil else { return }
            self.recognize(image, copyDirectly: false)
        }, onApply: apply)
        restorePinAfterAnnotations = window?.isVisible == true
        editor.onClose = { [weak self, weak editor] in
            guard let self, self.annotationGeneration == generation, self.annotationEditor === editor else { return }
            self.annotationEditor = nil
            let shouldRestore = self.restorePinAfterAnnotations && !self.closed && !self.temporarilyHidden
            self.restorePinAfterAnnotations = false
            if shouldRestore { self.bringForward() }
        }
        annotationEditor = editor
        guard editor.showPinned(anchor) else {
            dismissAnnotations(restoringPin: false); return
        }
        // Keep the original window's saved frame/opacity unchanged while its canvas is being edited.
        if editor.window?.isVisible == true { window?.orderOut(nil) }
    }

    override func showWindow(_ sender: Any?) {
        guard !closed else { return }
        temporarilyHidden = false
        if let annotationEditor {
            annotationEditor.showWindow(sender); annotationEditor.window?.makeKeyAndOrderFront(sender)
        } else { super.showWindow(sender) }
    }

    /// Bring forward the currently visible surface without showing a second copy behind the editor.
    func bringForward() {
        guard !closed else { return }
        showWindow(nil)
        let surface = annotationEditor?.window ?? window
        surface?.makeKeyAndOrderFront(nil); surface?.orderFrontRegardless()
    }

    /// Fallback (non-session) pins remain reusable while all auxiliary editing windows are dismissed.
    func hideTemporarily() {
        guard !closed else { return }
        temporarilyHidden = true
        imageExportController?.cancelExport(); imageExportController = nil
        setTextSelectionEnabled(false); setBarcodeSelectionEnabled(false)
        dismissAnnotations(restoringPin: false)
        recognitionGeneration = UUID(); recognitionTask?.cancel(); recognitionTask = nil
        recognitionWindow?.close(); recognitionWindow = nil
        window?.orderOut(nil)
    }

    private func dismissAnnotations(restoringPin: Bool) {
        let shouldRestore = restoringPin && restorePinAfterAnnotations && !closed && !temporarilyHidden
        annotationGeneration = UUID(); restorePinAfterAnnotations = false
        let editor = annotationEditor; annotationEditor = nil
        editor?.onClose = nil; editor?.close()
        if shouldRestore { bringForward() }
    }

    /// Keep persistence transactional when flattening the shared annotation editor.
    func applyAnnotatedImage(_ image: CGImage) throws {
        guard !closed, !exportInProgress else { return }
        guard PinImageRenderer.allowsRasterSize(width: image.width, height: image.height) else { throw renderFailure }
        try acceptImageState(PinImageState(original: state.original, current: image, isModified: true))
    }

    @objc private func toggleTextSelection() { setTextSelectionEnabled(!textSelectionEnabled) }

    /// Explicit per-pin mode; never enabled by restoration, group changes or merely opening a pin.
    func setTextSelectionEnabled(_ enabled: Bool) {
        if enabled {
            guard !closed, !temporarilyHidden, annotationEditor == nil, !exportInProgress,
                  window?.ignoresMouseEvents != true, !textSelectionEnabled else { return }
        }
        if enabled { setBarcodeSelectionEnabled(false) }
        textSelectionGeneration = UUID(); textSelectionTask?.cancel(); textSelectionTask = nil
        textSelectionIsRecognizing = false; textSelectionEnabled = enabled
        textSelectionOverlay.document = nil
        textSelectionOverlay.isHidden = !enabled
        textSelectionControl?.removeFromSuperview(); textSelectionControl = nil
        if !enabled {
            textSelectionStatus = ""; textSelectionOverlay.removeFromSuperview()
            if window?.firstResponder === textSelectionOverlay { window?.makeFirstResponder(canvas) }
            return
        }
        setCropping(false)
        textSelectionOverlay.frame = canvas.bounds; textSelectionOverlay.autoresizingMask = [.width, .height]
        textSelectionOverlay.imageRect = canvas.imageRect
        canvas.addSubview(textSelectionOverlay)
        window?.makeFirstResponder(canvas)
        let control = NSButton(title: "识别中 · Esc 取消", target: self, action: #selector(toggleTextSelection))
        control.controlSize = .small; control.bezelStyle = .rounded
        control.setAccessibilityLabel("退出图片文字选择")
        control.toolTip = "文字识别完全在本机运行；按 Esc 退出，空格标注"
        if let root = window?.contentView {
            root.addSubview(control); control.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([control.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
                                         control.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -5)])
        }
        textSelectionControl = control; textSelectionIsRecognizing = true; textSelectionStatus = "识别中"
        let generation = textSelectionGeneration, revision = pixelRevision, source = state.current
        let provider = recognizeForSelection
        textSelectionTask = Task { [weak self] in
            do {
                let result = try await provider(source)
                guard !Task.isCancelled, let self, !self.closed, !self.temporarilyHidden,
                      self.textSelectionEnabled, self.textSelectionGeneration == generation, self.pixelRevision == revision else { return }
                self.textSelectionTask = nil; self.textSelectionIsRecognizing = false
                self.textSelectionOverlay.document = result.document
                let hasText = result.document?.units.isEmpty == false
                self.textSelectionStatus = hasText ? (result.document?.isTruncated == true ? "部分文字 · 已达上限" : "拖选文字 · 选中后可拖出") : "未找到可选文字"
                self.textSelectionControl?.title = hasText ? (result.document?.isTruncated == true ? "部分文字 · 退出" : "选字 · 退出") : "未找到文字 · 退出"
                self.textSelectionControl?.toolTip = self.textSelectionStatus + "；⌘C 复制，拖动已选文字到其他应用；Esc 退出"
                self.window?.makeFirstResponder(self.textSelectionOverlay)
            } catch is CancellationError {
                guard let self, self.textSelectionGeneration == generation else { return }
                self.setTextSelectionEnabled(false)
            } catch {
                guard !Task.isCancelled, let self, !self.closed, self.textSelectionGeneration == generation else { return }
                self.textSelectionTask = nil; self.textSelectionIsRecognizing = false
                self.textSelectionStatus = "识别失败"
                self.textSelectionControl?.title = "识别失败 · 退出"
                self.textSelectionControl?.toolTip = error.localizedDescription
            }
        }
    }

    @objc private func toggleBarcodeSelection() { setBarcodeSelectionEnabled(!barcodeSelectionEnabled) }

    /// Opt-in, transient mode. It is intentionally absent from persisted pin presentation.
    func setBarcodeSelectionEnabled(_ enabled: Bool) {
        if enabled {
            guard !closed, !temporarilyHidden, annotationEditor == nil, !exportInProgress,
                  window?.ignoresMouseEvents != true, !barcodeSelectionEnabled else { return }
            setTextSelectionEnabled(false)
        }
        barcodeGeneration = UUID(); barcodeTask?.cancel(); barcodeTask = nil
        barcodeIsRecognizing = false; barcodeSelectionEnabled = enabled
        barcodeSelectionOverlay.document = nil; barcodeSelectionOverlay.isHidden = !enabled
        barcodeControl?.removeFromSuperview(); barcodeControl = nil
        barcodeWindow?.onClose = nil; barcodeWindow?.close(); barcodeWindow = nil
        if !enabled {
            barcodeStatus = ""; barcodeSelectionOverlay.removeFromSuperview()
            if window?.firstResponder === barcodeSelectionOverlay { window?.makeFirstResponder(canvas) }
            return
        }
        setCropping(false)
        barcodeSelectionOverlay.frame = canvas.bounds; barcodeSelectionOverlay.autoresizingMask = [.width, .height]
        barcodeSelectionOverlay.imageRect = canvas.imageRect; canvas.addSubview(barcodeSelectionOverlay)
        window?.makeFirstResponder(canvas)
        let control = NSButton(title: "识别码中 · Esc 取消", target: self, action: #selector(toggleBarcodeSelection))
        control.controlSize = .small; control.bezelStyle = .rounded; control.setAccessibilityLabel("退出识别码选择")
        if let root = window?.contentView {
            root.addSubview(control); control.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([control.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
                                         control.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -5)])
        }
        barcodeControl = control; barcodeIsRecognizing = true; barcodeStatus = "识别中"
        let generation = barcodeGeneration, revision = pixelRevision, source = state.current, provider = recognizeCodes
        barcodeTask = Task { [weak self] in
            do {
                let document = try await provider(source)
                guard !Task.isCancelled, let self, !self.closed, !self.temporarilyHidden, self.barcodeSelectionEnabled,
                      self.barcodeGeneration == generation, self.pixelRevision == revision else { return }
                self.barcodeTask = nil; self.barcodeIsRecognizing = false
                self.barcodeSelectionOverlay.document = document
                self.barcodeStatus = document.statusText
                self.barcodeControl?.title = document.results.isEmpty ? "未找到码 · 退出" : "\(document.results.count) 个码 · 退出"
                self.barcodeControl?.toolTip = document.statusText
                let browser = BarcodeResultController(image: source, document: document, showsSourceImage: false)
                browser.onSelect = { [weak self] index in
                    guard let self, self.barcodeGeneration == generation else { return }
                    self.barcodeSelectionOverlay.selectResult(at: index, notify: false)
                    if let box = document.results[index].quad?.bounds {
                        let imageRect = self.canvas.imageRect
                        let region = CGRect(x: imageRect.minX + box.minX * imageRect.width, y: imageRect.minY + box.minY * imageRect.height,
                                            width: box.width * imageRect.width, height: box.height * imageRect.height)
                        self.barcodeSelectionOverlay.scrollToVisible(region.insetBy(dx: -16, dy: -16))
                    }
                }
                browser.onClose = { [weak self] in
                    guard let self, self.barcodeGeneration == generation else { return }
                    self.barcodeWindow = nil
                    self.setBarcodeSelectionEnabled(false)
                }
                self.barcodeWindow = browser
                self.barcodeSelectionOverlay.selectResult(at: document.results.isEmpty ? nil : 0, notify: false)
                if let pinWindow = self.window, let resultWindow = browser.window {
                    let screen = pinWindow.screen?.visibleFrame ?? pinWindow.frame
                    let width = resultWindow.frame.width, height = resultWindow.frame.height
                    let preferredX = pinWindow.frame.maxX + 12 + width <= screen.maxX ? pinWindow.frame.maxX + 12 : pinWindow.frame.minX - width - 12
                    resultWindow.setFrameOrigin(CGPoint(x: min(max(preferredX, screen.minX), max(screen.minX, screen.maxX - width)),
                                                       y: min(max(pinWindow.frame.maxY - height, screen.minY), max(screen.minY, screen.maxY - height))))
                }
                browser.showWindow(nil); browser.window?.makeKeyAndOrderFront(nil)
            } catch is CancellationError {
                guard let self, self.barcodeGeneration == generation else { return }
                self.setBarcodeSelectionEnabled(false)
            } catch {
                guard !Task.isCancelled, let self, !self.closed, self.barcodeGeneration == generation else { return }
                self.barcodeTask = nil; self.barcodeIsRecognizing = false; self.barcodeStatus = "识别失败"
                self.barcodeControl?.title = "识别失败 · 退出"; self.barcodeControl?.toolTip = error.localizedDescription
            }
        }
    }

    @objc private func toggleDirectCopy() { UserDefaults.standard.set(!TextResultController.copyDirectlyNextTime, forKey: TextResultController.directCopyPreferenceKey) }
    @objc private func recognizeText() { recognize(state.current, copyDirectly: false) }
    @objc private func copyRecognizedText() { recognize(state.current, copyDirectly: true) }
    private func recognize(_ image: CGImage, copyDirectly: Bool) {
        guard !closed, !temporarilyHidden else { return }
        recognitionTask?.cancel()
        let generation = UUID(); recognitionGeneration = generation
        recognitionTask = Task { [weak self] in
            do {
                let result = try await RecognitionService.recognize(image)
                guard !Task.isCancelled, let self, !self.closed, self.recognitionGeneration == generation else { return }
                self.recognitionTask = nil
                if (copyDirectly || TextResultController.copyDirectlyNextTime), !result.displayText.isEmpty {
                    TextResultController.copyToPasteboard(result.displayText); return
                }
                self.recognitionWindow?.close()
                let resultWindow = TextResultController(text: result.displayText, sourceImage: image)
                resultWindow.onClose = { [weak self] in self?.recognitionWindow = nil }
                self.recognitionWindow = resultWindow
                resultWindow.showWindow(nil); resultWindow.window?.makeKeyAndOrderFront(nil)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, self?.closed == false, self?.recognitionGeneration == generation else { return }
                self?.recognitionTask = nil; showError(error)
            }
        }
    }

    @objc private func transformImage(_ sender: NSMenuItem) {
        guard PinTransform.allCases.indices.contains(sender.tag) else { return }
        do { try applyTransform(PinTransform.allCases[sender.tag]) } catch { showError(error) }
    }
    func applyTransform(_ transform: PinTransform) throws {
        guard !closed, !exportInProgress else { return }
        var next = state
        guard next.apply(transform) else { throw renderFailure }
        try acceptImageState(next)
    }
    private func applyCrop(_ rectangle: CGRect) {
        do { try cropImage(to: rectangle) } catch { showError(error) }
    }
    func cropImage(to rectangle: CGRect) throws {
        guard !closed, !exportInProgress else { return }
        var next = state
        guard next.crop(to: rectangle) else { throw renderFailure }
        try acceptImageState(next)
    }
    @objc private func resetImage() {
        do { try restoreOriginalImage() } catch { showError(error) }
    }
    func restoreOriginalImage() throws {
        guard !closed, !exportInProgress, state.isModified else { return }
        var next = state; next.reset()
        try acceptImageState(next)
    }
    private func acceptImageState(_ next: PinImageState) throws {
        try onPixelChange?(next.current, !next.isModified)
        let previousSize = CGSize(width: state.current.width, height: state.current.height)
        state = next; pixelRevision &+= 1
        setTextSelectionEnabled(false); setBarcodeSelectionEnabled(false)
        recognitionGeneration = UUID(); recognitionTask?.cancel(); recognitionTask = nil
        recognitionWindow?.close(); recognitionWindow = nil
        setCropping(false); canvas.image = state.current
        if fixedZoom == nil, !locked, previousSize != CGSize(width: state.current.width, height: state.current.height), let window {
            let screen = window.screen?.visibleFrame ?? window.frame
            let scale = min(canvas.zoom, min(screen.width / CGFloat(state.current.width), screen.height / CGFloat(state.current.height)))
            let size = NSSize(width: max(32, CGFloat(state.current.width) * scale), height: max(24, CGFloat(state.current.height) * scale))
            var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
        updateLayout(); updateTitle()
    }
    private var renderFailure: Error {
        PicShotError.message("无法处理此图片。贴图变换最多支持 3200 万像素；也可能内存不足。原图和当前图片未改变。")
    }

    @objc private func toggleCrop() {
        guard !exportInProgress else { return }
        if canvas.isCropping, let rectangle = canvas.selection, rectangle.width >= 1, rectangle.height >= 1 { applyCrop(rectangle) }
        else { setCropping(!canvas.isCropping) }
    }
    private func setCropping(_ value: Bool) {
        if value { setTextSelectionEnabled(false); setBarcodeSelectionEnabled(false) }
        canvas.isCropping = value; canvas.selection = nil
        canvas.toolTip = value ? "拖动选择，按 Return 裁剪，Esc 取消" : nil
        if value { window?.makeFirstResponder(canvas) }
        updateTitle()
    }
    @objc private func copyPin() { copyImage(state.current) }
    @objc private func copyOriginal() { copyImage(image) }
    @objc private func savePin() { save(original: false) }
    @objc private func saveOriginal() { save(original: true) }
    private func save(original: Bool) {
        guard !closed, !temporarilyHidden, let window else { return }
        if exportInProgress { imageExportController?.window?.makeKeyAndOrderFront(nil); return }
        setTextSelectionEnabled(false); setBarcodeSelectionEnabled(false); setCropping(false)
        imageExportController = ImageExportController.present(image: original ? image : state.current, from: window,
                                                              suggestedName: original ? "PicShot-original" : "PicShot-pin")
    }

    @objc private func selectOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = min(1, max(0.15, Double(sender.tag) / 100)); presentationDidChange()
    }
    @objc private func selectZoom(_ sender: NSMenuItem) {
        let scales: [CGFloat?] = [nil, 0.25, 0.5, 1, 2, 4]
        guard scales.indices.contains(sender.tag) else { return }
        fixedZoom = scales[sender.tag]; updateLayout(); updateTitle(); presentationDidChange()
    }
    @objc private func toggleShadow() { window?.hasShadow.toggle() }
    @objc private func toggleFloating() { window?.level = window?.level == .floating ? .normal : .floating }
    @objc private func toggleLock() {
        locked.toggle(); window?.isMovable = !locked
        if locked { window?.styleMask.remove(.resizable) } else { window?.styleMask.insert(.resizable) }
        updateTitle(); presentationDidChange()
    }
    @objc private func clickThrough() { setTextSelectionEnabled(false); setBarcodeSelectionEnabled(false); setCropping(false); annotationEditor?.close(); window?.ignoresMouseEvents = true; presentationDidChange() }
    @objc private func closePin() { close() }

    var presentation: PinPresentation {
        PinPresentation(frame: PinWindowFrame(window?.frame ?? .zero), opacity: Double(window?.alphaValue ?? 1),
                        zoom: fixedZoom.map { Double($0) }, clickThrough: window?.ignoresMouseEvents ?? false,
                        locked: locked).normalized()
    }

    /// Restoring metadata must not generate persistence events or rewrite image assets.
    func applyPresentation(_ value: PinPresentation) {
        guard !closed else { return }
        dismissAnnotations(restoringPin: true)
        applyingPresentation = true
        defer { applyingPresentation = false }
        let value = value.normalized()
        // Set the frame before locking; NSWindow may enforce its content minimum size.
        window?.setFrame(value.frame.rect, display: true)
        window?.alphaValue = value.opacity
        fixedZoom = value.zoom.map { CGFloat($0) }
        locked = value.locked; window?.isMovable = !locked
        if locked { window?.styleMask.remove(.resizable) } else { window?.styleMask.insert(.resizable) }
        if value.clickThrough { setTextSelectionEnabled(false); setBarcodeSelectionEnabled(false) }
        window?.ignoresMouseEvents = value.clickThrough
        updateLayout(); updateTitle()
    }
    private func presentationDidChange() {
        guard !closed, !applyingPresentation else { return }
        onPresentationChange?(presentation)
    }

    /// Leaves a way back from click-through, extreme opacity, or a removed display.
    /// Zoom and lock are preserved; only recovery restores opacity and mouse interaction.
    func restore(screens: [CGRect]? = nil) {
        guard !closed else { return }
        let screens = screens ?? NSScreen.screens.map(\.visibleFrame)
        var value = presentation.normalized(screens: screens.map { PinWindowFrame($0) })
        value.clickThrough = false; value.opacity = 1
        applyPresentation(value); presentationDidChange()
        showWindow(nil); window?.orderFrontRegardless()
    }
    func windowDidMove(_ notification: Notification) { presentationDidChange() }
    func windowDidResize(_ notification: Notification) { updateLayout(); updateTitle(); presentationDidChange() }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true
        imageExportController?.cancelExport(); imageExportController = nil
        setTextSelectionEnabled(false); textSelectionOverlay.releaseResources()
        setBarcodeSelectionEnabled(false); barcodeSelectionOverlay.releaseResources()
        recognitionGeneration = UUID(); recognitionTask?.cancel(); recognitionTask = nil
        dismissAnnotations(restoringPin: false)
        recognitionWindow?.onClose = nil; recognitionWindow?.close(); recognitionWindow = nil
        canvas.onCrop = nil; canvas.onCancelCrop = nil
        canvas.onAnnotate = nil; canvas.onClose = nil; canvas.onCopy = nil; canvas.onToggleTextSelection = nil
        canvas.textSelectionOverlay = nil; canvas.barcodeSelectionOverlay = nil
        let completion = onClose
        onClose = nil; onPixelChange = nil; onPresentationChange = nil
        completion?()
        // AppKit can keep the last closed utility panel cached after this controller dies.
        // Pins are single-use: sever its view/image graph without changing ARC ownership.
        let closingWindow = notification.object as? NSWindow ?? window
        closingWindow?.makeFirstResponder(nil)
        canvas.image = nil; canvas.menu = nil; canvas.selection = nil
        scrollView.documentView = nil
        closingWindow?.contentView = nil
        closingWindow?.delegate = nil
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
        textSelectionOverlay.frame = canvas.bounds; textSelectionOverlay.imageRect = canvas.imageRect
        barcodeSelectionOverlay.frame = canvas.bounds; barcodeSelectionOverlay.imageRect = canvas.imageRect
        canvas.needsDisplay = true
    }
}

/// Borderless pins still need keyboard focus for Space, Escape, and crop confirmation.
@MainActor final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor private final class PinCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1
    var isCropping = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var selection: CGRect? { didSet { needsDisplay = true } }
    var onCrop: ((CGRect) -> Void)?
    var onCancelCrop: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onToggleTextSelection: (() -> Void)?
    weak var textSelectionOverlay: PinTextSelectionOverlay?
    weak var barcodeSelectionOverlay: BarcodeSelectionOverlay?
    private var anchor: CGPoint?
    override var acceptsFirstResponder: Bool { true }

    var imageRect: CGRect {
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
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = zoom > 1 ? .none : .high
        context.draw(image, in: imageRect)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(1); context.stroke(imageRect.insetBy(dx: 0.5, dy: 0.5))
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
        window?.makeKey(); window?.makeFirstResponder(self)
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
    @objc func copy(_ sender: Any?) {
        if let textSelectionOverlay, textSelectionOverlay.superview != nil { textSelectionOverlay.copy(sender) }
        else if let barcodeSelectionOverlay, barcodeSelectionOverlay.superview != nil { barcodeSelectionOverlay.copy(sender) }
        else { onCopy?() }
    }
    override func selectAll(_ sender: Any?) {
        if let textSelectionOverlay, textSelectionOverlay.superview != nil { textSelectionOverlay.selectAll(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if !isCropping, let barcodeSelectionOverlay, barcodeSelectionOverlay.superview != nil,
           barcodeSelectionOverlay.handleKeyDown(event) { return }
        if !isCropping, let textSelectionOverlay, textSelectionOverlay.superview != nil,
           textSelectionOverlay.handleKeyDown(event) { return }
        if !isCropping, event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "t" { onToggleTextSelection?(); return }
        if isCropping && event.keyCode == 53 { anchor = nil; onCancelCrop?(); return }
        if isCropping && (event.keyCode == 36 || event.keyCode == 76) {
            if let selection { onCrop?(selection) } else { NSSound.beep() }
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 49 { onAnnotate?(); return }
            if event.keyCode == 53 { onClose?(); return }
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { onCopy?(); return }
        super.keyDown(with: event)
    }
}
