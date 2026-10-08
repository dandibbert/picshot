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
    var onEditablePixelChange: ((CGImage, EditableCapturePayload) throws -> Void)?
    var onAnnotationError: ((Error) -> Void)?
    private var loadEditableCapture: ((PinEditableWork) throws -> EditableCapturePayload?)?
    private var editableWorkAdmission: ((PinEditableWork, EditableCapturePayload?) throws -> Void)?
    private var annotationEditorSharedOriginalBytes = 0
    private var transientEditableCapture: EditableCapturePayload?
    private(set) var hasEditableCapture = false
    private(set) var annotationsHidden = false
    private var hiddenAnnotationPreview: CGImage?
    private var visibilityTicket: EditorOutputProjection.Ticket?
    private var visibilityGeneration = UUID()
    var annotationVisibilityIsPending: Bool { visibilityTicket != nil }
    /// Display-only hiding never changes any copy/save/OCR source.
    var displayedImage: CGImage { hiddenAnnotationPreview ?? state.current }
    var retainedAnnotationPreviewCount: Int { hiddenAnnotationPreview == nil ? 0 : 1 }
    var retainedEditableBaseCount: Int { transientEditableCapture == nil ? 0 : 1 }
    var retainedRasterImagesForAdmission: [CGImage] {
        [state.original, state.current] + [hiddenAnnotationPreview,
            transientEditableCapture?.originalImage, transientEditableCapture?.baseImage].compactMap { $0 }
    }
    var estimatedOutputProjectionReservationBytes: Int {
        EditorAdmissionPolicy.sum([visibilityTicket?.reservedBytes ?? 0,
            annotationEditor?.estimatedOutputProjectionReservationBytes ?? 0])
    }
    var estimatedRetainedRasterBytes: Int {
        // A pin editor reuses the immutable original. Its editor estimate already
        // includes it, so do not charge those same owned bytes twice.
        let editorBytes = max(0, (annotationEditor?.estimatedAdmissionRasterBytes ?? 0) - annotationEditorSharedOriginalBytes)
        return EditorAdmissionPolicy.sum([EditorRasterEstimate.retainedBytes(retainedRasterImagesForAdmission),
            editorBytes, visibilityTicket?.reservedBytes ?? 0])
    }

    func configureEditableCapture(available: Bool, load: @escaping () throws -> EditableCapturePayload?) {
        configureEditableCapture(available: available, loadForWork: { _ in try load() })
    }
    func configureEditableCapture(available: Bool,
        loadForWork: @escaping (PinEditableWork) throws -> EditableCapturePayload?,
        admission: ((PinEditableWork, EditableCapturePayload?) throws -> Void)? = nil) {
        hasEditableCapture = available; loadEditableCapture = loadForWork; editableWorkAdmission = admission
        transientEditableCapture = nil; revealAnnotations()
    }
    private func editableCapture(for work: PinEditableWork = .readOnly) throws -> EditableCapturePayload? {
        guard hasEditableCapture else { return nil }
        guard let payload = try loadEditableCapture?(work) ?? transientEditableCapture else {
            throw PicShotError.message("可编辑标注文件缺失。当前图片仍可复制或导出。")
        }
        try payload.validate(currentImage: state.current)
        return payload
    }
    private func admitEditableOperation(_ work: PinEditableWork, payload: EditableCapturePayload?) throws {
        if let editableWorkAdmission { try editableWorkAdmission(work, payload); return }
        let document = payload?.document, base = payload?.baseImage ?? state.current
        if PinEditableAdmission.requiresProjection(work, document: document), EditorOutputProjection.shared.isBusy {
            throw EditorOutputProjectionError.busy
        }
        let additional = PinEditableAdmission.additionalImages(payload.map { [$0.originalImage, $0.baseImage] } ?? [],
            alreadyOwned: retainedRasterImagesForAdmission)
        let workBytes = try PinEditableAdmission.workBytes(work, document: document, baseWidth: base.width, baseHeight: base.height)
        _ = try PinEditableAdmission.remaining(limit: EditorAdmissionPolicy().maximumRasterBytes,
            retained: estimatedRetainedRasterBytes, reportedProjection: estimatedOutputProjectionReservationBytes,
            globalProjection: EditorOutputProjection.shared.reservedBytes,
            work: EditorAdmissionPolicy.sum([additional, workBytes]))
    }
    private func annotationError(_ error: Error) {
        if let onAnnotationError { onAnnotationError(error) } else { showError(error) }
    }

    var onToggleGroupSelection: (() -> Void)?
    var onShowGroupTransform: (() -> Void)?
    private(set) var isGroupSelected = false
    var canParticipateInGroupTransform: Bool {
        !closed && !temporarilyHidden && annotationEditor == nil && !exportInProgress && !locked && window?.ignoresMouseEvents != true
    }
    func setGroupSelected(_ selected: Bool) {
        isGroupSelected = selected
        window?.contentView?.wantsLayer = true
        window?.contentView?.layer?.borderWidth = selected ? 2 : 0
        window?.contentView?.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    @objc private func toggleGroupSelection() { onToggleGroupSelection?() }
    @objc private func showGroupTransform() { onShowGroupTransform?() }
    var onPresentationChange: ((PinPresentation) -> Void)?
    var onDesktopVisibilityChange: ((PinDesktopVisibility) -> Void)? {
        didSet { desktopVisibilityMenu.onSelect = onDesktopVisibilityChange }
    }
    private(set) var desktopVisibility: PinDesktopVisibility = .defaultMode
    let desktopVisibilityMenu = PinDesktopVisibilityMenu()
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
    private let recognizeForSelection: PinOCRSession.Recognizer
    private let defaults: UserDefaults?
    private let ocrScheduler: PinOCRScheduler?
    var onAutomaticOCRChange: ((Bool) -> Void)?
    private(set) var automaticOCREnabled = false
    private var automaticSelectionDismissed = false
    private var selectionKey: PinOCRKey?
    private var recognitionLinkKey: PinOCRKey?
    private var recognitionPanelGeneration = UUID()
    private var exportCloseObserver: NSObjectProtocol?
    private var ocrModeTransition = false
    private(set) var ocrSourceReadCount = 0
    private(set) lazy var ocrSession = PinOCRSession(revision: pixelRevision, scheduler: ocrScheduler,
        imageProvider: { [weak self] in
            guard let self, !self.closed, !self.temporarilyHidden else { return nil }
            self.ocrSourceReadCount += 1
            return self.state.current
        }, recognize: recognizeForSelection)
    let textSelectionOverlay = PinTextSelectionOverlay()
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

    convenience init(image: CGImage, defaults: UserDefaults? = PinOCRPreferences.applicationDefaults) {
        self.init(originalImage: image, currentImage: image, isModified: false, defaults: defaults)
    }

    init(originalImage: CGImage, currentImage: CGImage, isModified: Bool,
         recognizeForSelection: (@Sendable (CGImage) async throws -> RecognitionResult)? = nil,
         recognizeWithOptions: PinOCRSession.Recognizer? = nil,
         defaults: UserDefaults? = PinOCRPreferences.applicationDefaults,
         ocrScheduler: PinOCRScheduler? = nil,
         recognizeCodes: @escaping @Sendable (CGImage) async throws -> RecognizedBarcodeDocument = { try await RecognitionService.recognizeBarcodes($0) }) {
        if let recognizeWithOptions { self.recognizeForSelection = recognizeWithOptions }
        else if let recognizeForSelection { self.recognizeForSelection = { image, _ in try await recognizeForSelection(image) } }
        else { self.recognizeForSelection = { try await RecognitionService.recognize($0, options: $1) } }
        self.recognizeCodes = recognizeCodes; self.defaults = defaults; self.ocrScheduler = ocrScheduler
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
        panel.collectionBehavior = PinDesktopVisibilityPolicy.behavior(desktopVisibility, preserving: [.fullScreenAuxiliary])
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
        panel.onCopyAllText = { [weak self] in self?.copyAllRecognizedText() }
        panel.onToggleTextSelection = { [weak self] in self?.toggleTextSelection() }
        textSelectionOverlay.onExit = { [weak self] in self?.setTextSelectionEnabled(false) }
        textSelectionOverlay.onAnnotate = { [weak self] in self?.showAnnotations() }
        textSelectionOverlay.onSelectionChange = { [weak self] ranges in self?.sendSelectionToResult(ranges) }
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
        ocrSession.onChange = { [weak self] in self?.ocrSessionDidChange() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeActionMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        let select = menu.addItem(withTitle: "加入组合选择", action: #selector(toggleGroupSelection), keyEquivalent: "")
        select.target = self; select.identifier = NSUserInterfaceItemIdentifier("pin-group-select")
        select.toolTip = "组合移动 / 缩放请使用菜单；直接拖动或拉伸仍只改变当前贴图"
        let transform = menu.addItem(withTitle: "组合移动 / 缩放…", action: #selector(showGroupTransform), keyEquivalent: "")
        transform.target = self; transform.identifier = NSUserInterfaceItemIdentifier("pin-group-transform")
        menu.addItem(.separator())
        let recognition = NSMenu(title: "识别")
        let selection = addItem("选择图片文字", action: #selector(toggleTextSelection), key: "t", to: recognition)
        selection.keyEquivalentModifierMask = [.command, .shift]
        addItem("识别二维码 / 条码…", action: #selector(toggleBarcodeSelection), to: recognition)
        recognition.addItem(.separator())
        addItem("识别文字…", action: #selector(recognizeText), to: recognition)
        let copyAll = addItem("复制全部识别文字", action: #selector(copyRecognizedText), key: "c", to: recognition)
        copyAll.keyEquivalentModifierMask = [.command, .shift]
        copyAll.identifier = NSUserInterfaceItemIdentifier("pin.ocr.copyAll")
        let automatic = addItem("自动识别贴图文字", action: #selector(toggleAutomaticOCR), to: recognition)
        automatic.identifier = NSUserInterfaceItemIdentifier("pin.ocr.automatic")
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
        let currentCopy = addItem("复制当前图像", action: #selector(copyPin), to: menu)
        let currentSave = addItem("当前图像另存为…", action: #selector(savePin), to: menu)
        currentCopy.toolTip = "复制已保存的标注结果；临时隐藏标注不影响复制"
        currentSave.toolTip = "保存已保存的标注结果；临时隐藏标注不影响导出"
        menu.addItem(.separator())
        addItem("标注", action: #selector(showAnnotations), key: " ", to: menu)
        let visibility = addItem("临时隐藏标注（仅显示）", action: #selector(toggleAnnotationsHidden), to: menu)
        visibility.identifier = NSUserInterfaceItemIdentifier("pin.annotations.visibility")
        visibility.toolTip = "仅切换屏幕预览；复制、保存和识别仍使用已保存的标注结果。原始图片操作位于独立子菜单。"
        addItem("裁剪当前图片…", action: #selector(toggleCrop), to: menu)
        let zoom = NSMenu(title: "缩放"); zoom.delegate = self
        for (index, title) in ["适合窗口", "25%", "50%", "100%", "200%", "400%"].enumerated() {
            let item = addItem(title, action: #selector(selectZoom(_:)), to: zoom); item.tag = index
        }
        menu.addItem(withTitle: "缩放", action: nil, keyEquivalent: "").submenu = zoom
        addItem("鼠标穿透（菜单栏恢复当前组）", action: #selector(clickThrough), to: menu)
        addItem("窗口阴影", action: #selector(toggleShadow), to: menu)
        addItem("窗口置顶", action: #selector(toggleFloating), to: menu)
        desktopVisibilityMenu.add(to: menu)
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
            if item.action == #selector(transformImage(_:)), PinTransform.allCases.indices.contains(item.tag) {
                item.title = PinTransform.allCases[item.tag].title + (hasEditableCapture ? "（合并标注）" : "")
                item.toolTip = hasEditableCapture ? "处理已保存的当前图像并合并已有标注；原始图片仍可单独复制或重置。" : nil
            }
            if item.action == #selector(toggleCrop) {
                item.title = hasEditableCapture ? "裁剪（保留可编辑标注）…" : "裁剪当前图片…"
            }
            if item.action == #selector(toggleAnnotationsHidden) {
                item.isHidden = !hasEditableCapture
                item.isEnabled = !closed && annotationEditor == nil && !exportInProgress
                item.state = annotationsHidden ? .on : .off
                item.title = annotationVisibilityIsPending ? "取消隐藏标注预览" : (annotationsHidden ? "显示标注（仅显示）" : "临时隐藏标注（仅显示）")
            }
            if item.action == #selector(toggleGroupSelection) {
                item.isHidden = onToggleGroupSelection == nil
                item.state = isGroupSelected ? .on : .off
                item.title = isGroupSelected ? "移出组合选择" : "加入组合选择"
            }
            if item.action == #selector(showGroupTransform) { item.isHidden = onShowGroupTransform == nil }
            if item.action == #selector(toggleTextSelection) {
                item.state = textSelectionEnabled ? .on : .off
                item.title = textSelectionIsRecognizing ? "正在识别文字（取消）" : "选择图片文字"
            }
            if item.action == #selector(toggleBarcodeSelection) {
                item.state = barcodeSelectionEnabled ? .on : .off
                item.title = barcodeIsRecognizing ? "正在识别码（取消）" : "识别二维码 / 条码…"
            }
            if item.action == #selector(toggleDirectCopy) { item.state = defaults?.bool(forKey: TextResultController.directCopyPreferenceKey) == true ? .on : .off }
            if item.action == #selector(toggleAutomaticOCR) { item.state = automaticOCREnabled ? .on : .off }
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
        guard let projectedAnchor = annotationPresentation else { return }
        let payload: EditableCapturePayload?
        let anchor: PinEditorPresentation
        do {
            payload = try editableCapture(for: .editor)
            try admitEditableOperation(.editor, payload: payload)
            anchor = try payload.map { try EditableCapturePresentation.editorPlacement(for: $0.document, projected: projectedAnchor) } ?? projectedAnchor
        } catch { annotationError(error); return }
        let restoreHiddenOnCancel = annotationsHidden
        let startingRevision = pixelRevision
        revealAnnotations()
        ocrModeTransition = true
        defer { ocrModeTransition = false; refreshAutomaticOCR() }
        suspendOCR(); setBarcodeSelectionEnabled(false); setCropping(false)
        let generation = UUID(); annotationGeneration = generation
        var editingRevision = pixelRevision
        let apply: (CGImage, EditableCapturePayload) throws -> Void = { [weak self] image, draft in
            guard let self, !self.closed, !self.temporarilyHidden, self.annotationGeneration == generation,
                  self.annotationEditor != nil, !self.exportInProgress else { throw CancellationError() }
            guard self.pixelRevision == editingRevision else {
                throw PicShotError.message("贴图已在其他操作中更改。当前标注仍可复制或导出；请重新打开标注后再应用到贴图。")
            }
            try self.applyEditableImage(image, editable: draft); editingRevision = self.pixelRevision
        }
        let editor = ImageEditorController(image: payload?.baseImage ?? state.current,
            onSave: { _ in }, onPin: { _ in }, onOCR: { [weak self] image in
                guard let self, self.annotationGeneration == generation, self.annotationEditor != nil else { return }
                self.recognizeAnnotationImage(image)
            }, onSaveEditable: { [weak self] image, draft in
                try apply(image, draft); self?.annotationEditor?.close()
            }, onPinEditable: apply, onApplyEditable: apply)
        do {
            if let payload { try editor.restoreEditablePayload(payload) }
            else { editor.useOriginalImage(state.original) }
        } catch { editor.close(); annotationError(error); return }
        editor.onOutputError = { [weak self] error in self?.annotationError(error) }
        restorePinAfterAnnotations = window?.isVisible == true
        editor.onClose = { [weak self, weak editor] in
            guard let self, self.annotationGeneration == generation, self.annotationEditor === editor else { return }
            self.annotationEditor = nil; self.annotationEditorSharedOriginalBytes = 0
            if restoreHiddenOnCancel && self.pixelRevision == startingRevision && !self.closed && !self.temporarilyHidden {
                do { try self.setAnnotationsHidden(true) } catch { self.annotationError(error) }
            }
            let shouldRestore = self.restorePinAfterAnnotations && !self.closed && !self.temporarilyHidden
            self.restorePinAfterAnnotations = false
            if shouldRestore { self.bringForward() }
        }
        let editorOriginal = payload?.originalImage ?? state.original
        annotationEditorSharedOriginalBytes = editorOriginal === state.original
            ? EditorRasterEstimate.retainedBytes([state.original]) : 0
        annotationEditor = editor
        guard editor.showPinned(anchor, desktopVisibility: desktopVisibility) else {
            dismissAnnotations(restoringPin: false); return
        }
        // Keep the original window's saved frame/opacity unchanged while its canvas is being edited.
        if editor.window?.isVisible == true { window?.orderOut(nil) }
    }

    override func showWindow(_ sender: Any?) {
        guard !closed else { return }
        let wasHidden = temporarilyHidden || window?.isVisible != true
        temporarilyHidden = false
        if wasHidden { automaticSelectionDismissed = false }
        if let annotationEditor {
            annotationEditor.showWindow(sender); annotationEditor.window?.makeKeyAndOrderFront(sender)
        } else {
            // Restoring a group must not activate each pin or move keyboard focus.
            window?.orderFront(sender)
            refreshAutomaticOCR()
        }
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
        revealAnnotations(); suspendOCR()
        imageExportController?.cancelExport(); imageExportController = nil
        setBarcodeSelectionEnabled(false)
        dismissAnnotations(restoringPin: false)
        window?.orderOut(nil)
    }

    private func dismissAnnotations(restoringPin: Bool) {
        let shouldRestore = restoringPin && restorePinAfterAnnotations && !closed && !temporarilyHidden
        annotationGeneration = UUID(); restorePinAfterAnnotations = false
        let editor = annotationEditor; annotationEditor = nil; annotationEditorSharedOriginalBytes = 0
        editor?.onClose = nil; editor?.close()
        if shouldRestore { bringForward() }
    }

    /// Keep persistence transactional when flattening the shared annotation editor.
    func applyAnnotatedImage(_ image: CGImage) throws {
        guard !closed, !exportInProgress else { return }
        guard PinImageRenderer.allowsRasterSize(width: image.width, height: image.height) else { throw renderFailure }
        try acceptImageState(PinImageState(original: state.original, current: image, isModified: true))
    }

    func applyEditableImage(_ image: CGImage, editable payload: EditableCapturePayload) throws {
        guard !closed, !exportInProgress else { throw CancellationError() }
        guard PinImageRenderer.allowsRasterSize(width: image.width, height: image.height) else { throw renderFailure }
        try payload.validate(currentImage: image)
        try acceptImageState(PinImageState(original: state.original, current: image, isModified: true), editable: payload)
    }

    @objc private func toggleAnnotationsHidden() {
        do { try setAnnotationsHidden(!annotationsHidden && !annotationVisibilityIsPending) }
        catch { annotationError(error) }
    }

    /// Temporary preview only. We intentionally do not persist visibility:
    /// reopening a pin always starts with its saved annotated output visible.
    func setAnnotationsHidden(_ hidden: Bool) throws {
        guard !closed, annotationEditor == nil, !exportInProgress else { throw CancellationError() }
        if !hidden { revealAnnotations(); return }
        guard !annotationsHidden, visibilityTicket == nil else { return }
        guard let payload = try editableCapture(for: .hiddenPreview) else { return }
        try admitEditableOperation(.hiddenPreview, payload: payload)
        let document = payload.document
        let base = try EditableCapturePresentation.visibleBase(payload)
        if document.outputDecoration.isIdentity {
            try installHiddenPreview(base); return
        }
        let service = EditorOutputProjection.shared
        let ticket = try service.reserve(width: base.width, height: base.height, decoration: document.outputDecoration)
        do {
            guard let input = ImageEditorRenderer.render(image: base, annotations: []) else { throw ImageOutputDecorationError.allocationFailed }
            let generation = UUID(); visibilityGeneration = generation; visibilityTicket = ticket
            try service.start(ticket, image: input) { [weak self, weak ticket] result in
                guard let self, let ticket, self.visibilityTicket === ticket else { return }
                self.visibilityTicket = nil
                defer { if !self.closed { self.updateTitle(); self.refreshAutomaticOCR() } }
                guard !self.closed, self.visibilityGeneration == generation, !ticket.cancellation.isCancelled else { return }
                do { try self.installHiddenPreview(result.get()) }
                catch { if !(error is CancellationError) { self.annotationError(error) } }
            }
        } catch {
            visibilityTicket = nil; service.abandon(ticket); throw error
        }
    }
    private func installHiddenPreview(_ preview: CGImage) throws {
        guard preview.width == state.current.width, preview.height == state.current.height else {
            throw EditorOutputProjectionError.invalidOwner
        }
        // Avoid selecting text at coordinates whose visible contents were hidden.
        suspendOCR(); setBarcodeSelectionEnabled(false); setCropping(false)
        hiddenAnnotationPreview = preview; annotationsHidden = true; canvas.image = preview
        updateLayout(); updateTitle()
    }
    private func revealAnnotations() {
        visibilityGeneration = UUID(); visibilityTicket?.cancel()
        // Cancel retains the lease until its completion drains, blocking another
        // hide request from queuing an unbounded sequence of full-size projections.
        hiddenAnnotationPreview = nil; annotationsHidden = false; canvas.image = state.current
        if !closed { updateLayout(); updateTitle(); refreshAutomaticOCR() }
    }

    @objc private func toggleTextSelection() { setTextSelectionEnabled(!textSelectionEnabled) }

    /// Explicit actions may focus the overlay; automatic completion never does.
    func setTextSelectionEnabled(_ enabled: Bool) {
        if !enabled {
            automaticSelectionDismissed = true
            disableTextSelection()
            return
        }
        if annotationsHidden || annotationVisibilityIsPending { revealAnnotations() }
        guard canRecognize, !textSelectionEnabled else { return }
        automaticSelectionDismissed = false
        setBarcodeSelectionEnabled(false); setCropping(false)
        ocrSession.resume()
        prepareTextSelection(focus: true)
        let generation = textSelectionGeneration, key = ocrSession.key
        ocrSession.request(.selection) { [weak self] result in
            guard let self, !self.closed, self.canRecognize, self.textSelectionEnabled,
                  self.textSelectionGeneration == generation, self.ocrSession.key == key else { return }
            switch result {
            case .success(let result): self.installSelection(result, key: key, focus: true)
            case .failure(is CancellationError): self.disableTextSelection()
            case .failure(let error):
                self.textSelectionIsRecognizing = false; self.textSelectionStatus = "识别失败"
                self.textSelectionControl?.title = "识别失败 · 退出"
                self.textSelectionControl?.toolTip = error.localizedDescription
            }
        }
    }

    private var canRecognize: Bool {
        !closed && !temporarilyHidden && !annotationsHidden && !annotationVisibilityIsPending && !ocrModeTransition && annotationEditor == nil && !exportInProgress && window?.ignoresMouseEvents != true
    }
    private var automaticOCREligible: Bool {
        canRecognize && window?.isVisible == true && !canvas.isCropping && !barcodeSelectionEnabled
    }
    func applyAutomaticOCR(_ enabled: Bool) {
        guard !closed else { return }
        let changed = automaticOCREnabled != enabled
        automaticOCREnabled = enabled
        if changed { automaticSelectionDismissed = false }
        if !enabled {
            // A changed preference ends background demand, including a queued restore.
            if changed { suspendOCR() }
            if canRecognize { ocrSession.resume() }
        } else { refreshAutomaticOCR() }
    }
    @objc private func toggleAutomaticOCR() {
        let enabled = !automaticOCREnabled
        if let onAutomaticOCRChange { onAutomaticOCRChange(enabled) }
        else { applyAutomaticOCR(enabled) }
    }
    private func refreshAutomaticOCR() {
        guard automaticOCREligible else { return }
        ocrSession.resume()
        guard automaticOCREnabled, !automaticSelectionDismissed else { return }
        if let result = ocrSession.cachedResult { installSelection(result, key: ocrSession.key, focus: false) }
        else { ocrSession.scheduleAutomatic() }
    }
    private func ocrSessionDidChange() {
        let key = ocrSession.key
        if selectionKey != nil && selectionKey != key {
            selectionKey = nil; textSelectionOverlay.document = nil
            textSelectionIsRecognizing = textSelectionEnabled
        }
        guard canRecognize, !canvas.isCropping, !barcodeSelectionEnabled else { return }
        guard let result = ocrSession.cachedResult else {
            if textSelectionEnabled {
                textSelectionIsRecognizing = ocrSession.state == .queued || ocrSession.state == .recognizing
                if ocrSession.state == .failed {
                    textSelectionStatus = "识别失败"; textSelectionControl?.title = "识别失败 · 退出"
                } else if textSelectionIsRecognizing {
                    textSelectionStatus = "识别中"; textSelectionControl?.title = "识别中 · Esc 取消"
                }
            }
            return
        }
        if textSelectionEnabled || (automaticOCREnabled && automaticOCREligible && !automaticSelectionDismissed) {
            installSelection(result, key: key, focus: false)
        }
    }
    private func prepareTextSelection(focus: Bool) {
        if textSelectionEnabled { return }
        textSelectionGeneration = UUID(); textSelectionEnabled = true; textSelectionIsRecognizing = true
        textSelectionStatus = "识别中"
        textSelectionOverlay.isHidden = false
        textSelectionOverlay.frame = canvas.bounds; textSelectionOverlay.autoresizingMask = [.width, .height]
        textSelectionOverlay.imageRect = canvas.imageRect; canvas.addSubview(textSelectionOverlay)
        if focus { window?.makeFirstResponder(canvas) }
        let control = NSButton(title: "识别中 · Esc 取消", target: self, action: #selector(toggleTextSelection))
        control.controlSize = .small; control.bezelStyle = .rounded
        control.setAccessibilityLabel("退出图片文字选择")
        if let root = window?.contentView {
            root.addSubview(control); control.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([control.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
                                         control.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -5)])
        }
        textSelectionControl = control
    }
    private func installSelection(_ result: RecognitionResult, key: PinOCRKey, focus: Bool) {
        guard key == ocrSession.key, key.revision == pixelRevision else { return }
        prepareTextSelection(focus: focus)
        if selectionKey != key || textSelectionOverlay.document != result.document {
            selectionKey = key; textSelectionOverlay.document = result.document
        }
        textSelectionIsRecognizing = false
        let hasText = result.document?.units.isEmpty == false
        textSelectionStatus = hasText ? (result.document?.isTruncated == true ? "部分文字 · 已达上限" : "拖选文字 · 选中后可拖出") : "未找到可选文字"
        textSelectionControl?.title = hasText ? (result.document?.isTruncated == true ? "部分文字 · 退出" : "选字 · 退出") : "未找到文字 · 退出"
        textSelectionControl?.toolTip = textSelectionStatus + "；⌘C 复制所选，⌘⇧C 复制全部；Esc 退出"
        if focus { window?.makeFirstResponder(textSelectionOverlay) }
    }
    private func disableTextSelection() {
        textSelectionGeneration = UUID(); textSelectionEnabled = false; textSelectionIsRecognizing = false
        ocrSession.cancelRequest(for: .selection)
        selectionKey = nil; textSelectionOverlay.document = nil; textSelectionOverlay.isHidden = true
        textSelectionControl?.removeFromSuperview(); textSelectionControl = nil; textSelectionStatus = ""
        textSelectionOverlay.removeFromSuperview()
        if window?.firstResponder === textSelectionOverlay { window?.makeFirstResponder(canvas) }
    }
    private func closeRecognitionWindow() {
        recognitionGeneration = UUID(); recognitionPanelGeneration = UUID()
        recognitionTask?.cancel(); recognitionTask = nil; recognitionLinkKey = nil
        recognitionWindow?.onSourceSelection = nil; recognitionWindow?.onClose = nil
        recognitionWindow?.close(); recognitionWindow = nil
    }
    private func suspendOCR() {
        disableTextSelection(); closeRecognitionWindow(); ocrSession.suspend()
    }
    private func sendSelectionToResult(_ ranges: [NSRange]) {
        guard canRecognize, let panel = recognitionWindow, let document = textSelectionOverlay.document,
              selectionKey == ocrSession.key, recognitionLinkKey == ocrSession.key,
              ocrSession.cachedResult?.document == document, panel.resultDocument == document else { return }
        panel.selectSourceRanges(ranges, document: document)
    }

    @objc private func toggleBarcodeSelection() { setBarcodeSelectionEnabled(!barcodeSelectionEnabled) }

    /// Opt-in, transient mode. It is intentionally absent from persisted pin presentation.
    func setBarcodeSelectionEnabled(_ enabled: Bool) {
        if enabled {
            if annotationsHidden || annotationVisibilityIsPending { revealAnnotations() }
            guard !closed, !temporarilyHidden, annotationEditor == nil, !exportInProgress,
                  window?.ignoresMouseEvents != true, !barcodeSelectionEnabled else { return }
            suspendOCR()
        }
        barcodeGeneration = UUID(); barcodeTask?.cancel(); barcodeTask = nil
        barcodeIsRecognizing = false; barcodeSelectionEnabled = enabled
        barcodeSelectionOverlay.document = nil; barcodeSelectionOverlay.isHidden = !enabled
        barcodeControl?.removeFromSuperview(); barcodeControl = nil
        barcodeWindow?.onClose = nil; barcodeWindow?.close(); barcodeWindow = nil
        if !enabled {
            barcodeStatus = ""; barcodeSelectionOverlay.removeFromSuperview()
            if window?.firstResponder === barcodeSelectionOverlay { window?.makeFirstResponder(canvas) }
            refreshAutomaticOCR()
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
                PinDesktopVisibilityPolicy.apply(self.desktopVisibility, to: browser.window)
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

    @objc private func toggleDirectCopy() {
        guard let defaults else { return }
        defaults.set(!defaults.bool(forKey: TextResultController.directCopyPreferenceKey), forKey: TextResultController.directCopyPreferenceKey)
    }
    @objc private func recognizeText() { showRecognizedText() }
    @objc private func copyRecognizedText() { copyAllRecognizedText() }
    func showRecognizedText() { recognizeCurrentPin(copyDirectly: defaults?.bool(forKey: TextResultController.directCopyPreferenceKey) == true, pasteboard: .general) }
    func copyAllRecognizedText(to pasteboard: NSPasteboard = .general) { recognizeCurrentPin(copyDirectly: true, pasteboard: pasteboard) }

    private func recognizeCurrentPin(copyDirectly: Bool, pasteboard: NSPasteboard) {
        if annotationsHidden || annotationVisibilityIsPending { revealAnnotations() }
        guard canRecognize, !canvas.isCropping, !barcodeSelectionEnabled else { return }
        recognitionTask?.cancel(); recognitionTask = nil
        let generation = UUID(); recognitionGeneration = generation
        ocrSession.resume()
        let session = ocrSession, key = session.key
        recognitionTask = Task { [weak self] in
            do {
                let result = try await session.result(for: copyDirectly ? .copyAll : .resultWindow)
                guard !Task.isCancelled, let self, self.canRecognize, self.recognitionGeneration == generation,
                      self.pixelRevision == key.revision, session.key == key else { return }
                self.recognitionTask = nil
                if copyDirectly {
                    if !result.displayText.isEmpty { TextResultController.copyToPasteboard(result.displayText, pasteboard: pasteboard) }
                    return
                }
                self.presentRecognitionResult(result, key: key)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, self?.canRecognize == true, self?.recognitionGeneration == generation else { return }
                self?.recognitionTask = nil; showError(error)
            }
        }
    }
    private func presentRecognitionResult(_ result: RecognitionResult, key: PinOCRKey) {
        recognitionWindow?.onClose = nil; recognitionWindow?.close()
        let session = ocrSession, panelGeneration = UUID()
        recognitionPanelGeneration = panelGeneration
        automaticSelectionDismissed = false
        installSelection(result, key: key, focus: false)
        let panel = TextResultController(result: result, options: key.options, onRecognize: { [weak self, weak session] options in
            guard let session, self?.canRecognize == true, self?.pixelRevision == key.revision,
                  self?.recognitionPanelGeneration == panelGeneration else { throw CancellationError() }
            self?.recognitionLinkKey = nil
            self?.automaticSelectionDismissed = false
            self?.prepareTextSelection(focus: false)
            let result = try await session.result(for: .resultWindow, options: options)
            guard !Task.isCancelled, let self, self.canRecognize, self.pixelRevision == key.revision,
                  self.recognitionPanelGeneration == panelGeneration, session.key.options == options else { throw CancellationError() }
            self.recognitionLinkKey = session.key
            return result
        }, defaults: defaults)
        recognitionWindow = panel; recognitionLinkKey = key
        panel.onSourceSelection = { [weak self, weak panel] document, ranges in
            guard let self, let panel, self.recognitionWindow === panel, self.canRecognize,
                  self.pixelRevision == key.revision, self.recognitionLinkKey == self.ocrSession.key,
                  self.selectionKey == self.ocrSession.key, self.ocrSession.cachedResult?.document == document,
                  self.textSelectionOverlay.document == document else { return }
            self.textSelectionOverlay.setLinkedSelection(ranges)
        }
        panel.onClose = { [weak self, weak panel] in
            guard let self, self.recognitionWindow === panel else { return }
            self.recognitionWindow = nil; self.recognitionLinkKey = nil
        }
        if let document = textSelectionOverlay.document, selectionKey == key {
            panel.selectSourceRanges(textSelectionOverlay.selectedRange.map { [$0] } ?? [], document: document)
        }
        PinDesktopVisibilityPolicy.apply(desktopVisibility, to: panel.window)
        panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil)
    }
    /// The annotation preview is an unsaved, independent source and cannot use the pin's cache.
    private func recognizeAnnotationImage(_ image: CGImage) {
        guard !closed, !temporarilyHidden, annotationEditor != nil else { return }
        recognitionTask?.cancel()
        let generation = UUID(); recognitionGeneration = generation
        recognitionTask = Task { [weak self] in
            do {
                let result = try await RecognitionService.recognize(image)
                guard !Task.isCancelled, let self, !self.closed, self.recognitionGeneration == generation else { return }
                self.recognitionTask = nil
                if self.defaults?.bool(forKey: TextResultController.directCopyPreferenceKey) == true, !result.displayText.isEmpty {
                    TextResultController.copyToPasteboard(result.displayText); return
                }
                self.recognitionWindow?.close()
                let panel = TextResultController(result: result, sourceImage: image, defaults: self.defaults)
                panel.onClose = { [weak self] in self?.recognitionWindow = nil }
                self.recognitionWindow = panel
                PinDesktopVisibilityPolicy.apply(self.desktopVisibility, to: panel.window)
                panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil)
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
        if var editable = try editableCapture() {
            editable.document.baseAssetID = UUID()
            editable.document.basePixelWidth = next.current.width; editable.document.basePixelHeight = next.current.height
            editable.document.baseCropInOriginal = nil; editable.document.cropViewportInBase = nil
            editable.document.baseProvenance = .derivedRaster
            editable.document.annotations = []; editable.document.outputDecoration = .none
            editable.baseImage = next.current
            try acceptImageState(next, editable: editable)
        } else { try acceptImageState(next) }
    }
    private func applyCrop(_ rectangle: CGRect) {
        do { try cropImage(to: rectangle) } catch { showError(error) }
    }
    func cropImage(to rectangle: CGRect) throws {
        guard !closed, !exportInProgress else { return }
        guard !hasEditableCapture else {
            throw PicShotError.message("请在标注编辑器中裁剪，以保留图层和效果来源。")
        }
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
    private func acceptImageState(_ next: PinImageState, editable: EditableCapturePayload? = nil) throws {
        if let editable {
            if let onEditablePixelChange { try onEditablePixelChange(next.current, editable) }
            else if onPixelChange != nil { throw PicShotError.message("此贴图尚未连接可编辑标注存储。当前编辑未丢失。") }
        } else { try onPixelChange?(next.current, !next.isModified) }
        // Commit completed: only now replace pixels, layer availability and preview.
        hasEditableCapture = editable != nil
        transientEditableCapture = loadEditableCapture == nil ? editable : nil
        revealAnnotations()
        let previousSize = CGSize(width: state.current.width, height: state.current.height)
        ocrModeTransition = true
        defer { ocrModeTransition = false; refreshAutomaticOCR() }
        state = next; pixelRevision &+= 1
        suspendOCR(); ocrSession.update(revision: pixelRevision)
        automaticSelectionDismissed = false
        setBarcodeSelectionEnabled(false)
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
        if hasEditableCapture {
            showAnnotations(); annotationEditor?.chooseTool(.crop); return
        }
        if canvas.isCropping, let rectangle = canvas.selection, rectangle.width >= 1, rectangle.height >= 1 { applyCrop(rectangle) }
        else { setCropping(!canvas.isCropping) }
    }
    private func setCropping(_ value: Bool) {
        canvas.isCropping = value
        if value { revealAnnotations(); suspendOCR(); setBarcodeSelectionEnabled(false) }
        canvas.selection = nil
        canvas.toolTip = value ? "拖动选择，按 Return 裁剪，Esc 取消" : nil
        if value { window?.makeFirstResponder(canvas) }
        updateTitle()
        if !value { refreshAutomaticOCR() }
    }
    @objc private func copyPin() { copyImage(state.current) }
    @objc private func copyOriginal() { copyImage(image) }
    @objc private func savePin() { save(original: false) }
    @objc private func saveOriginal() { save(original: true) }
    private func save(original: Bool) {
        guard !closed, !temporarilyHidden, let window else { return }
        if exportInProgress { imageExportController?.window?.makeKeyAndOrderFront(nil); return }
        ocrModeTransition = true
        defer { ocrModeTransition = false; refreshAutomaticOCR() }
        suspendOCR(); setBarcodeSelectionEnabled(false); setCropping(false)
        // Disable eligibility before creating the owned export window.
        ocrSession.suspend()
        imageExportController = ImageExportController.present(image: original ? image : state.current, from: window,
                                                              suggestedName: original ? "PicShot-original" : "PicShot-pin")
        if let exportCloseObserver { NotificationCenter.default.removeObserver(exportCloseObserver) }; exportCloseObserver = nil
        if let exportWindow = imageExportController?.window {
            exportCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: exportWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.imageExportController = nil
                    if let observer = self.exportCloseObserver { NotificationCenter.default.removeObserver(observer) }; self.exportCloseObserver = nil
                    self.refreshAutomaticOCR()
                }
            }
        } else { refreshAutomaticOCR() }
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
    @objc private func clickThrough() { window?.ignoresMouseEvents = true; suspendOCR(); setBarcodeSelectionEnabled(false); setCropping(false); annotationEditor?.close(); presentationDidChange() }
    @objc private func closePin() { close() }

    /// Metadata-only: never reconstruct a controller or decode/render content.
    func applyDesktopVisibility(_ mode: PinDesktopVisibility) {
        guard !closed else { return }
        desktopVisibility = mode; desktopVisibilityMenu.mode = mode
        PinDesktopVisibilityPolicy.apply(mode, to: window)
        PinDesktopVisibilityPolicy.apply(mode, to: annotationEditor?.window)
        PinDesktopVisibilityPolicy.apply(mode, to: recognitionWindow?.window)
        PinDesktopVisibilityPolicy.apply(mode, to: barcodeWindow?.window)
        PinDesktopVisibilityPolicy.apply(mode, to: imageExportController?.window)
    }

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
        window?.ignoresMouseEvents = value.clickThrough
        if value.clickThrough { suspendOCR(); setBarcodeSelectionEnabled(false) }
        updateLayout(); updateTitle(); refreshAutomaticOCR()
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
        revealAnnotations(); transientEditableCapture = nil; loadEditableCapture = nil; editableWorkAdmission = nil; hasEditableCapture = false
        onEditablePixelChange = nil; onAnnotationError = nil
        if let exportCloseObserver { NotificationCenter.default.removeObserver(exportCloseObserver) }; exportCloseObserver = nil
        imageExportController?.cancelExport(); imageExportController = nil
        disableTextSelection(); ocrSession.close(); textSelectionOverlay.releaseResources()
        setBarcodeSelectionEnabled(false); barcodeSelectionOverlay.releaseResources()
        recognitionGeneration = UUID(); recognitionTask?.cancel(); recognitionTask = nil
        dismissAnnotations(restoringPin: false)
        recognitionWindow?.onClose = nil; recognitionWindow?.close(); recognitionWindow = nil
        canvas.onCrop = nil; canvas.onCancelCrop = nil
        canvas.onAnnotate = nil; canvas.onClose = nil; canvas.onCopy = nil; canvas.onToggleTextSelection = nil
        canvas.textSelectionOverlay = nil; canvas.barcodeSelectionOverlay = nil
        let completion = onClose
        onClose = nil; onPixelChange = nil; onPresentationChange = nil; onToggleGroupSelection = nil; onShowGroupTransform = nil
        onDesktopVisibilityChange = nil; onAutomaticOCRChange = nil; desktopVisibilityMenu.invalidate()
        (window as? PinPanel)?.onCopyAllText = nil; (window as? PinPanel)?.onToggleTextSelection = nil
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
        let edited = (state.isModified ? " · 已修改" : "") + (annotationsHidden ? " · 标注仅预览隐藏，复制/保存仍含标注" : "")
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
    var onCopyAllText: (() -> Void)?
    var onToggleTextSelection: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": if let onCopyAllText { onCopyAllText(); return true }
            case "t": if let onToggleTextSelection { onToggleTextSelection(); return true }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
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
