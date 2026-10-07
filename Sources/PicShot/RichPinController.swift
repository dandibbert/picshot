import AppKit
import ImageIO
import PicShotCore
import PicShotFormulaRenderCore
import SwiftUI
import UniformTypeIdentifiers

/// One sequential decoder per live animation. ImageIO caching is disabled and evicted
/// after each decode. There is no decoded frame list or persistent hidden player.
actor RichPinFrameDecoder {
    private var source: CGImageSource?
    private let asset: PinRichAsset
    init(data: Data, asset: PinRichAsset) throws {
        guard asset.kind == .animation, asset.isValid, data.count == Int(asset.byteCount),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw RichPinError.invalidAnimation }
        self.source = source; self.asset = asset
    }
    func frame(at index: Int) throws -> (CGImage, Double) {
        guard let source, (0..<asset.frameCount).contains(index) else { throw RichPinError.invalidAnimation }
        return try autoreleasepool {
            guard let image = CGImageSourceCreateImageAtIndex(source, index,
                [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == asset.width, image.height == asset.height else { throw RichPinError.invalidAnimation }
            let delay = RichPinAnimationInfo.delay(source: source, index: index)
            CGImageSourceRemoveCacheAtIndex(source, index)
            return (image, delay)
        }
    }
    func release() { source = nil }
}

@MainActor final class RichPinController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSMenuItemValidation, NSPopoverDelegate, NSOpenSavePanelDelegate {
    var onClose: (() -> Void)?
    var onToggleGroupSelection: (() -> Void)?
    var onShowGroupTransform: (() -> Void)?
    private(set) var isGroupSelected = false
    var canParticipateInGroupTransform: Bool {
        !closed && !locked && !hasActiveLaTeXEditorOrRender && window?.ignoresMouseEvents != true
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
    var onRichChange: ((PreparedRichPin) throws -> Void)?
    let kind: PinContentKind
    private(set) var richDocument: PinRichDocument?
    private let asset: PinRichAsset
    private let textView = NSTextView()
    private let fileTable = NSTableView()
    private let imageView = RichPinImageView()
    private var statusMessage = ""
    private var plainText = false
    private var decoder: RichPinFrameDecoder?
    private var playback: Task<Void, Never>?
    private var nextFrame = 0
    private var closed = false
    private var applyingPresentation = false
    private var locked = false
    private var textScale = 1.0
    private var playing = false
    private(set) var latexModel: LaTeXPinModel?
    private var latexPopover: NSPopover?
    private(set) var latexSavePanel: NSSavePanel?
    private var latexSavePanelObservers: [NSObjectProtocol] = []
    private var latexSavePanelFitTask: Task<Void, Never>?
    private var fittingLaTeXSavePanel = false
    /// Scalar lifecycle evidence; never retains the chooser or its callback targets.
    var hasLaTeXSavePanelCallbacks: Bool { !latexSavePanelObservers.isEmpty || latexSavePanelFitTask != nil }
    private var latexSaveGeneration = UUID()
    private var latexSaveCancellation: ImageExportCancellation?
    private var latexSaveInput: ImageExportJobInput<Data>?
    private var latexSaveTask: Task<Void, Never>?
    private var latexSaveInProgress: Bool { latexSavePanel != nil || latexSaveTask != nil }
    var hasActiveLaTeXEditorOrRender: Bool { latexPopover?.isShown == true || latexModel?.working == true || latexSaveInProgress }
    var latexEditorContentView: NSView? { latexPopover?.contentViewController?.view }
    /// The validated decoded raster is the pixel authority. NSImage.size is in
    /// points; CGImage extraction from that view can choose a display-sized result.
    /// The view also owns one explicit NSBitmapImageRep, which may copy backing
    /// storage. Both bounded raster owners are replaced together and cleared on
    /// close; framework representation cost is measured by the native resource gate.
    private(set) var displayedLaTeXRaster: CGImage?

    init(asset: PinRichAsset, data: Data, title: String, renderedImage: CGImage? = nil) throws {
        self.asset = asset; kind = asset.kind
        guard asset.isValid, data.count == Int(asset.byteCount) else { throw RichPinError.invalidContent }
        let decodedDocument: PinRichDocument?
        if asset.kind != .animation {
            let value = try JSONDecoder().decode(PinRichDocument.self, from: data)
            guard value.isValid, value.kind == asset.kind else { throw RichPinError.invalidContent }
            decodedDocument = value
        } else { decodedDocument = nil }
        if asset.kind == .latex {
            guard let renderedImage, renderedImage.width > 0, renderedImage.height > 0,
                  renderedImage.width <= FormulaRenderLimits.dimension, renderedImage.height <= FormulaRenderLimits.dimension,
                  renderedImage.width <= FormulaRenderLimits.pixels / renderedImage.height else { throw RichPinError.invalidContent }
        }
        richDocument = decodedDocument
        let panel = PinPanel(contentRect: NSRect(origin: .zero, size: RichPinController.initialSize(asset: asset, richDocument: decodedDocument)),
                             styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = title; panel.level = .floating; panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.delegate = self; panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = PinDesktopVisibilityPolicy.behavior(desktopVisibility, preserving: [.fullScreenAuxiliary])
        panel.hasShadow = true; panel.backgroundColor = kind == .latex ? .white : .textBackgroundColor
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: kind == .color ? 220 : (kind == .latex ? 32 : 180), height: kind == .color ? 116 : (kind == .latex ? 24 : 64)); panel.center()
        if asset.kind == .animation { decoder = try RichPinFrameDecoder(data: data, asset: asset) }
        if let content = decodedDocument?.latex, let renderedImage {
            let model = LaTeXPinModel(content: content)
            latexModel = model
            model.onCancelSaving = { [weak self] in self?.cancelLaTeXSave() }
            setLaTeXRaster(renderedImage, scale: content.scale)
            model.onCommit = { [weak self] prepared in
                guard let self, !self.closed, let save = self.onRichChange else { throw CancellationError() }
                let document = try JSONDecoder().decode(PinRichDocument.self, from: prepared.data)
                try save(prepared)
                self.richDocument = document
                self.setLaTeXRaster(prepared.poster, scale: document.latex?.scale ?? 1)
            }
            let scale = Double(content.scale)
            let width = Double(renderedImage.width) / scale, height = Double(renderedImage.height) / scale
            let fit = min(1, 680 / max(width, height))
            panel.setContentSize(NSSize(width: max(32, width * fit + 12), height: max(24, height * fit + 12)))
        }
        buildInterface(panel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { playback?.cancel() }

    private func setLaTeXRaster(_ raster: CGImage, scale: Int) {
        displayedLaTeXRaster = raster
        let pointSize = NSSize(width: Double(raster.width) / Double(scale), height: Double(raster.height) / Double(scale))
        // Keep source pixel dimensions explicit and independent of NSImage's
        // logical point size; do not resample the source into a display-sized image.
        let representation = NSBitmapImageRep(cgImage: raster)
        representation.size = pointSize
        let image = NSImage(size: pointSize); image.addRepresentation(representation)
        imageView.usesIntrinsicImageSize = false
        imageView.image = image
    }

    private static func initialSize(asset: PinRichAsset, richDocument: PinRichDocument?) -> NSSize {
        switch asset.kind {
        case .animation:
            let scale = min(1, 680 / CGFloat(max(asset.width, asset.height)))
            return NSSize(width: max(180, CGFloat(asset.width) * scale), height: max(64, CGFloat(asset.height) * scale))
        case .latex: return NSSize(width: 320, height: 120)
        case .color: return NSSize(width: 280, height: 148)
        case .files: return NSSize(width: 380, height: max(80, min(340, CGFloat(richDocument?.files?.count ?? 1) * 56 + 16)))
        case .text:
            let text = richDocument?.text?.plainText ?? ""
            let box = (text as NSString).boundingRect(with: NSSize(width: 496, height: 500), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 16)])
            return NSSize(width: min(520, max(240, ceil(box.width) + 28)), height: min(360, max(72, ceil(box.height) + 28)))
        }
    }

    private func buildInterface(_ panel: NSWindow) {
        let content: NSView
        switch kind {
        case .text:
            textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
            textView.isAutomaticLinkDetectionEnabled = false; textView.isAutomaticDataDetectionEnabled = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.frame = NSRect(x: 0, y: 0, width: 496, height: 200)
            textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay; scroll.documentView = textView; content = scroll
            statusMessage = richDocument?.text?.importedHTML == true ? "HTML 安全子集；外部资源、脚本、链接与 CSS 不加载" : "选择文字复制；拖动边缘移动贴图"
            renderText()
        case .files:
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")); column.title = "文件引用"
            column.width = 360; column.minWidth = 140; fileTable.addTableColumn(column)
            fileTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            fileTable.headerView = nil; fileTable.rowHeight = 56; fileTable.allowsMultipleSelection = true
            fileTable.dataSource = self; fileTable.delegate = self
            fileTable.target = self; fileTable.doubleAction = #selector(openFiles)
            fileTable.setDraggingSourceOperationMask(.copy, forLocal: false)
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay; scroll.documentView = fileTable; content = scroll
            statusMessage = "文件引用；双击打开，拖动所选文件可复制引用；不保存文件内容"
        case .color:
            let color = richDocument!.color!
            let swatch = RichPinBackgroundView(); swatch.wantsLayer = true
            swatch.layer?.backgroundColor = NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha) / 255).cgColor
            swatch.setAccessibilityLabel("颜色样本 " + color.hex)
            let label = NSTextField(labelWithString: color.hex + "\n" + color.rgb)
            label.isSelectable = true; label.font = .monospacedSystemFont(ofSize: 18, weight: .regular); label.alignment = .center
            let stack = NSStackView(views: [swatch, label]); stack.orientation = .vertical; stack.spacing = 12
            swatch.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 36).isActive = true
            content = stack
            statusMessage = "sRGB；右键复制 HEX 或 RGB"
        case .latex:
            imageView.imageScaling = .scaleProportionallyUpOrDown; content = imageView
            imageView.setAccessibilityLabel("渲染后的 LaTeX 贴图")
            statusMessage = "右键编辑 LaTeX、复制源码或导出；原公式与排版结果已保存"
        case .animation:
            imageView.imageScaling = .scaleProportionallyUpOrDown; content = imageView
            statusMessage = "\(asset.width) × \(asset.height) · \(asset.frameCount) 帧；右键暂停或复制当前帧"
        }
        let menu = makeActionMenu()
        let root = RichPinBackgroundView()
        // This view backing also appears in native view snapshots. Never flatten it
        // into the saved PNG: transparent black glyphs need contrast in dark mode.
        if kind == .latex { root.previewBackingColor = .white }
        root.addSubview(content); panel.contentView = root
        root.menu = menu; content.menu = menu; textView.menu = menu; fileTable.menu = menu; imageView.menu = menu
        root.toolTip = statusMessage + (kind == .latex ? "（白色仅用于显示，不改变导出透明度）" : "")
        content.translatesAutoresizingMaskIntoConstraints = false
        let inset: CGFloat = kind == .animation || kind == .color ? 0 : 6
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: kind == .color ? -16 : -inset)
        ])
    }

    private func makeActionMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        let select = menu.addItem(withTitle: "加入组合选择", action: #selector(toggleGroupSelection), keyEquivalent: "")
        select.target = self; select.identifier = NSUserInterfaceItemIdentifier("pin-group-select")
        select.toolTip = "组合移动 / 缩放请使用菜单；直接拖动或拉伸仍只改变当前贴图"
        let transform = menu.addItem(withTitle: "组合移动 / 缩放…", action: #selector(showGroupTransform), keyEquivalent: "")
        transform.target = self; transform.identifier = NSUserInterfaceItemIdentifier("pin-group-transform")
        menu.addItem(.separator())
        func item(_ title: String, _ action: Selector, in targetMenu: NSMenu? = nil) -> NSMenuItem {
            let result = (targetMenu ?? menu).addItem(withTitle: title, action: action, keyEquivalent: "")
            result.target = self; return result
        }
        switch kind {
        case .text:
            _ = item("复制所选文字", #selector(copySelectedText)); _ = item("复制全文", #selector(copyContent))
            _ = item("纯文本显示", #selector(changeTextStyle))
            let sizeMenu = NSMenu(title: "文字大小"); sizeMenu.delegate = self
            for (index, title) in ["小字", "标准", "大字", "特大"].enumerated() {
                item(title, #selector(changeTextSize(_:)), in: sizeMenu).tag = index
            }
            menu.addItem(withTitle: "文字大小", action: nil, keyEquivalent: "").submenu = sizeMenu
        case .files:
            _ = item("复制引用", #selector(copyContent)); _ = item("打开所选", #selector(openFiles)); _ = item("在访达显示", #selector(revealFiles))
        case .color:
            _ = item("复制 HEX", #selector(copyContent)); _ = item("复制 RGB", #selector(copyRGB))
        case .latex:
            _ = item("编辑 LaTeX…", #selector(editLaTeX)); _ = item("撤销公式修改", #selector(undoLaTeX))
            _ = item("复制 LaTeX", #selector(copyContent))
            let formats = NSMenu(title: "复制排版结果"); formats.delegate = self
            for (index, format) in [FormulaRenderFormat.png, .svg, .mathML, .pdf].enumerated() {
                item(format.label, #selector(copyLaTeXFormat(_:)), in: formats).tag = index
            }
            menu.addItem(withTitle: "复制排版结果", action: nil, keyEquivalent: "").submenu = formats
            let save = NSMenu(title: "导出公式"); save.delegate = self
            for (index, format) in FormulaRenderFormat.allCases.enumerated() {
                item(format.label + "…", #selector(saveLaTeXFormat(_:)), in: save).tag = index
            }
            menu.addItem(withTitle: "导出公式", action: nil, keyEquivalent: "").submenu = save
        case .animation:
            _ = item("暂停", #selector(togglePlayback)); _ = item("复制当前帧", #selector(copyContent))
        }
        menu.addItem(.separator())
        let alpha = NSMenu(title: "不透明度"); alpha.delegate = self
        for percent in [100, 80, 60, 40, 20, 15] { item("\(percent)%", #selector(changeOpacity(_:)), in: alpha).tag = percent }
        menu.addItem(withTitle: "不透明度", action: nil, keyEquivalent: "").submenu = alpha
        desktopVisibilityMenu.add(to: menu)
        _ = item("锁定", #selector(toggleLock)); _ = item("鼠标穿透（菜单栏恢复当前组）", #selector(clickThrough))
        menu.addItem(.separator()); let close = item("关闭", #selector(closePin)); close.keyEquivalent = "\u{1b}"; close.keyEquivalentModifierMask = []
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(toggleGroupSelection) {
                item.isHidden = onToggleGroupSelection == nil
                item.state = isGroupSelected ? .on : .off
                item.title = isGroupSelected ? "移出组合选择" : "加入组合选择"
            }
            if item.action == #selector(showGroupTransform) { item.isHidden = onShowGroupTransform == nil }
            if item.action == #selector(toggleLock) { item.state = locked ? .on : .off }
            if item.action == #selector(changeTextStyle) { item.state = plainText ? .on : .off }
            if item.action == #selector(changeTextSize(_:)) { item.state = [0.85, 1, 1.3, 1.7][item.tag] == textScale ? .on : .off }
            if item.action == #selector(changeOpacity(_:)) { item.state = abs(Double(window?.alphaValue ?? 1) - Double(item.tag) / 100) < 0.005 ? .on : .off }
            if item.action == #selector(undoLaTeX) { item.isEnabled = latexModel?.canUndo == true }
            if item.action == #selector(saveLaTeXFormat(_:)) { item.isEnabled = latexModel?.working == false && !latexSaveInProgress }
            if item.action == #selector(copyLaTeXFormat(_:)) { item.isEnabled = item.tag == 0 || (latexModel?.working == false && !latexSaveInProgress) }
            if item.action == #selector(togglePlayback) { item.title = playing ? "暂停" : "播放" }
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undoLaTeX) { return latexModel?.canUndo == true }
        if item.action == #selector(saveLaTeXFormat(_:)) { return latexModel?.working == false && !latexSaveInProgress }
        if item.action == #selector(copyLaTeXFormat(_:)) { return item.tag == 0 || (latexModel?.working == false && !latexSaveInProgress) }
        return true
    }
    @objc private func closePin() { close() }
    @objc private func copySelectedText() {
        let range = textView.selectedRange(); guard range.length > 0 else { copyContent(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString((textView.string as NSString).substring(with: range), forType: .string)
    }
    private func renderText() {
        guard let text = richDocument?.text else { return }
        let result = NSMutableAttributedString(string: "")
        let runs = plainText ? [PinTextRun(text: text.plainText)] : text.runs
        for run in runs {
            var font = run.code ? NSFont.monospacedSystemFont(ofSize: CGFloat(16 * textScale), weight: run.bold ? .bold : .regular) : NSFont.systemFont(ofSize: CGFloat(16 * textScale), weight: run.bold ? .bold : .regular)
            if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        textView.textStorage?.setAttributedString(result)
    }
    @objc private func changeTextStyle() { plainText.toggle(); renderText() }
    @objc private func changeTextSize(_ sender: NSMenuItem) {
        let values = [0.85, 1, 1.3, 1.7]
        guard values.indices.contains(sender.tag) else { return }
        textScale = values[sender.tag]; renderText(); presentationDidChange()
    }
    @objc private func copyContent() {
        let pasteboard = NSPasteboard.general
        switch kind {
        case .text:
            guard let text = richDocument?.text else { return }
            pasteboard.clearContents(); pasteboard.setString(text.plainText, forType: .string)
            if !plainText, let data = try? textView.attributedString().data(from: NSRange(location: 0, length: textView.attributedString().length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pasteboard.setData(data, forType: .rtf)
            }
        case .files:
            let urls = selectedFiles(fallbackToAll: true).map { URL(fileURLWithPath: $0.path) as NSURL }
            guard !urls.isEmpty else { return }; pasteboard.clearContents(); pasteboard.writeObjects(urls)
        case .color:
            pasteboard.clearContents(); pasteboard.setString(richDocument?.color?.hex ?? "", forType: .string)
        case .latex: latexModel?.copySource()
        case .animation:
            if let image = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { copyImage(image) }
        }
    }
    @objc func editLaTeX() {
        guard !closed, let model = latexModel else { return }
        if latexPopover?.isShown == true { return }
        let popover = NSPopover(); popover.behavior = .semitransient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: LaTeXPinEditorView(model: model, dismiss: { [weak self] in self?.latexPopover?.close() }))
        latexPopover = popover
        window?.makeKeyAndOrderFront(nil)
        popover.show(relativeTo: imageView.bounds, of: imageView, preferredEdge: .maxY)
    }
    func popoverDidClose(_ notification: Notification) {
        latexModel?.discardDraft(); latexPopover?.delegate = nil; latexPopover?.contentViewController = nil; latexPopover = nil
    }
    /// Called before moving a pin between Space policies; never leave a detached editor/render.
    func dismissLaTeXEditor() { cancelLaTeXSave(); latexModel?.discardDraft(); latexPopover?.close() }
    @objc private func undoLaTeX() { latexModel?.undo(); editLaTeX() }
    @objc private func copyLaTeXFormat(_ item: NSMenuItem) {
        let formats: [FormulaRenderFormat] = [.png, .svg, .mathML, .pdf]
        guard formats.indices.contains(item.tag) else { return }
        let format = formats[item.tag]
        if format == .png { copyLaTeXPNG(); return }
        latexModel?.export(format) { data in
            let board = NSPasteboard.general; board.clearContents()
            let type: NSPasteboard.PasteboardType = format == .pdf ? .pdf : NSPasteboard.PasteboardType(format == .svg ? UTType.svg.identifier : "public.mathml")
            board.setData(data, forType: type)
            if format == .svg || format == .mathML, let text = String(data: data, encoding: .utf8) { board.setString(text, forType: .string) }
        }
        editLaTeX() // Makes progress, cancellation and renderer errors visible in the same compact editor.
    }
    func copyLaTeXPNG(to pasteboard: NSPasteboard = .general) {
        guard !closed, let image = displayedLaTeXRaster,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        pasteboard.clearContents(); pasteboard.setData(data, forType: .png)
    }
    @objc private func saveLaTeXFormat(_ item: NSMenuItem) {
        guard FormulaRenderFormat.allCases.indices.contains(item.tag) else { return }
        beginLaTeXSave(FormulaRenderFormat.allCases[item.tag])
    }
    /// Retained asynchronous chooser: close/hide/genuine desktop changes cancel it.
    /// The same-mode preference path leaves the chooser and draft untouched.
    func beginLaTeXSave(_ format: FormulaRenderFormat) {
        guard !closed, !latexSaveInProgress, latexModel?.working == false,
              let window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "公式." + format.fileExtension
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.title = "保存公式新副本"; panel.prompt = "保存新副本"
        panel.message = "请选择尚未使用的文件名；已有文件和保存的公式不会被覆盖。"
        panel.delegate = self
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        PinDesktopVisibilityPolicy.inheritSpaceBehavior(from: window, to: panel)
        let generation = UUID(); latexSaveGeneration = generation; latexSavePanel = panel
        // A sheet can move a small edge-positioned parent to make room. Use a
        // retained, independent native chooser instead, with real child ownership
        // and its own screen-clamped frame; the pin's frame is never modified.
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel, !self.closed, self.latexSaveGeneration == generation,
                  self.latexSavePanel === panel else { return }
            let destination = response == .OK ? panel.url : nil
            self.detachLaTeXSavePanel(panel)
            panel.orderOut(nil)
            guard let destination else { return }
            do { try self.saveLaTeX(format, to: destination) }
            catch { showError(error) }
        }
        guard latexSavePanel === panel, latexSaveGeneration == generation else { return }
        window.addChildWindow(panel, ordered: .above)
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue, window.level.rawValue + 1))
        for (observed, names) in [(window, [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification]),
                                  (panel as NSWindow, [NSWindow.didMoveNotification, NSWindow.didResizeNotification])] {
            for name in names {
                latexSavePanelObservers.append(NotificationCenter.default.addObserver(forName: name, object: observed, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleLaTeXSavePanelFit() }
                })
            }
        }
        fitLaTeXSavePanel(centerOnPin: true)
        scheduleLaTeXSavePanelFit()
    }
    private func scheduleLaTeXSavePanelFit() {
        guard !closed, latexSavePanel != nil, !fittingLaTeXSavePanel, latexSavePanelFitTask == nil else { return }
        latexSavePanelFitTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
            guard let self else { return }; self.latexSavePanelFitTask = nil
            self.fitLaTeXSavePanel()
        }
    }
    private func fitLaTeXSavePanel(centerOnPin: Bool = false) {
        guard !closed, !fittingLaTeXSavePanel, let panel = latexSavePanel, let parent = window,
              let visible = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        fittingLaTeXSavePanel = true; defer { fittingLaTeXSavePanel = false }
        let safe = visible.insetBy(dx: min(8, visible.width / 20), dy: min(8, visible.height / 20))
        var frame = panel.frame
        guard frame.width > 0, frame.height > 0, safe.width > 0, safe.height > 0 else { return }
        frame.size.width = min(frame.width, safe.width); frame.size.height = min(frame.height, safe.height)
        if centerOnPin { frame.origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2) }
        frame.origin.x = max(safe.minX, min(frame.minX, safe.maxX - frame.width))
        frame.origin.y = max(safe.minY, min(frame.minY, safe.maxY - frame.height))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
    private func detachLaTeXSavePanel(_ panel: NSSavePanel) {
        latexSavePanelFitTask?.cancel(); latexSavePanelFitTask = nil
        for observer in latexSavePanelObservers { NotificationCenter.default.removeObserver(observer) }
        latexSavePanelObservers.removeAll()
        panel.parent?.removeChildWindow(panel); panel.delegate = nil
        if latexSavePanel === panel { latexSavePanel = nil }
    }
    /// Picker approval and native publication/cancellation fixtures share this route.
    /// Bind the approved physical destination before any renderer or queue delay.
    func saveLaTeX(_ format: FormulaRenderFormat, to url: URL) throws {
        guard !closed, !latexSaveInProgress, latexModel?.working == false else { throw CancellationError() }
        guard let lease = LaTeXPinSaveLease.acquire() else {
            throw PicShotError.message("公式保存任务达到保护上限，请完成或取消现有任务后重试。")
        }
        let destination = try RawPinArtifactDestination(url)
        let generation = UUID(); latexSaveGeneration = generation
        if format == .png, let image = displayedLaTeXRaster,
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            publishLaTeX(data, format: format, to: destination, generation: generation, lease: lease); return
        }
        latexModel?.export(format) { [weak self] data in
            self?.publishLaTeX(data, format: format, to: destination, generation: generation, lease: lease)
        }
        if format != .latex { editLaTeX() }
    }
    func panel(_ sender: Any, validate url: URL) throws { try ImageExportService.requireUnoccupied(url) }
    private func publishLaTeX(_ data: Data, format: FormulaRenderFormat, to destination: RawPinArtifactDestination,
                              generation: UUID, lease: LaTeXPinSaveLease) {
        guard !closed, latexSaveGeneration == generation, latexSaveTask == nil else { return }
        guard data.count <= FormulaRenderLimits.resultBytes else { showError(FormulaRenderError.invalidOutput); return }
        let input = ImageExportJobInput(data), token = ImageExportCancellation()
        latexSaveInput = input; latexSaveCancellation = token
        latexModel?.beginSaving()
        latexSaveTask = Task { [weak self] in
            var saveError: String?
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    ImageExportService.queue.addOperation {
                        defer { lease.release() }
                        guard let bytes = input.take(), !token.isCancelled else {
                            continuation.resume(throwing: CancellationError()); return
                        }
                        do {
                            try LaTeXPinExport.publish(bytes, format: format, to: destination, cancellation: token)
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } catch is CancellationError { saveError = "已取消；原贴图与已完成文件会保留。" }
            catch { saveError = error.localizedDescription }
            guard let self, self.latexSaveGeneration == generation else { return }
            self.latexSaveInput = nil; self.latexSaveCancellation = nil; self.latexSaveTask = nil
            self.latexModel?.finishSaving(error: saveError)
        }
        editLaTeX()
    }
    private func cancelLaTeXSave() {
        latexSaveGeneration = UUID()
        if let panel = latexSavePanel {
            detachLaTeXSavePanel(panel); panel.cancel(nil); panel.orderOut(nil)
        }
        latexSaveCancellation?.cancel(); latexSaveInput?.clear(); latexSaveTask?.cancel()
        latexSaveCancellation = nil; latexSaveInput = nil; latexSaveTask = nil
        if latexModel?.saving == true { latexModel?.finishSaving(cancelled: true) }
    }
    @objc private func copyRGB() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(richDocument?.color?.rgb ?? "", forType: .string) }
    private func selectedFiles(fallbackToAll: Bool = false) -> [PinFileReference] {
        let files = richDocument?.files ?? []
        if fileTable.selectedRowIndexes.isEmpty { return fallbackToAll ? files : [] }
        return fileTable.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0] : nil }
    }
    private func selectedExistingURLs() -> [URL] {
        let files = selectedFiles()
        guard !files.isEmpty else { NSSound.beep(); return [] }
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { showError(RichPinError.unavailableFile); return [] }
        return files.map { URL(fileURLWithPath: $0.path) }
    }
    @objc private func openFiles() { for url in selectedExistingURLs() { if !NSWorkspace.shared.open(url) { showError(RichPinError.unavailableFile); break } } }
    @objc private func revealFiles() { let urls = selectedExistingURLs(); if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) } }
    func numberOfRows(in tableView: NSTableView) -> Int { richDocument?.files?.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let files = richDocument?.files, files.indices.contains(row) else { return nil }
        let file = files[row]
        let rowView = NSView()
        let icon = NSImageView(image: NSImage(systemSymbolName: file.isDirectory ? "folder" : "doc", accessibilityDescription: file.isDirectory ? "文件夹" : "文件")!)
        let name = NSTextField(labelWithString: file.name); name.font = .systemFont(ofSize: 14); name.lineBreakMode = .byTruncatingMiddle
        let path = NSTextField(labelWithString: file.path); path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor; path.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [name, path]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        rowView.addSubview(icon); rowView.addSubview(labels)
        icon.translatesAutoresizingMaskIntoConstraints = false; labels.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34), icon.heightAnchor.constraint(equalToConstant: 38),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), labels.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: rowView.centerYAnchor), name.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor), path.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor)
        ])
        rowView.toolTip = file.path; return rowView
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let files = richDocument?.files, files.indices.contains(row) else { return nil }
        return URL(fileURLWithPath: files[row].path) as NSURL
    }
    @objc private func togglePlayback() { if playing { pausePlayback() } else { startPlayback() } }
    func startPlayback() {
        guard !closed, !playing, let decoder else { return }
        playing = true
        playback = Task { [weak self, decoder] in
            do {
                while !Task.isCancelled {
                    guard let index = self?.nextFrame else { break }
                    let (image, delay) = try await decoder.frame(at: index)
                    guard !Task.isCancelled, self?.closed == false else { break }
                    self?.imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    if let count = self?.asset.frameCount { self?.nextFrame = (index + 1) % count }
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                self?.playing = false
                self?.statusMessage = error.localizedDescription
                self?.window?.contentView?.toolTip = error.localizedDescription
                showError(error)
            }
        }
    }
    func pausePlayback() { playing = false; playback?.cancel(); playback = nil }
    @objc private func changeOpacity(_ sender: NSMenuItem) { window?.alphaValue = min(1, max(0.15, Double(sender.tag) / 100)); presentationDidChange() }
    @objc private func toggleLock() {
        locked.toggle(); window?.isMovable = !locked
        if locked { window?.styleMask.remove(.resizable) } else { window?.styleMask.insert(.resizable) }
        presentationDidChange()
    }
    @objc private func clickThrough() { window?.ignoresMouseEvents = true; presentationDidChange() }
    /// Metadata-only: never reconstruct a controller or decode/render content.
    func applyDesktopVisibility(_ mode: PinDesktopVisibility) {
        guard !closed else { return }
        if mode != desktopVisibility { dismissLaTeXEditor() }
        desktopVisibility = mode; desktopVisibilityMenu.mode = mode
        PinDesktopVisibilityPolicy.apply(mode, to: window)
    }

    var presentation: PinPresentation {
        PinPresentation(frame: PinWindowFrame(window?.frame ?? .zero), opacity: Double(window?.alphaValue ?? 1),
                        zoom: kind == .text ? textScale : nil, clickThrough: window?.ignoresMouseEvents ?? false, locked: locked).normalized()
    }
    func applyPresentation(_ value: PinPresentation) {
        guard !closed else { return }; applyingPresentation = true; defer { applyingPresentation = false }
        let value = value.normalized(); window?.setFrame(value.frame.rect, display: true)
        window?.alphaValue = value.opacity
        locked = value.locked; window?.isMovable = !locked
        if locked { window?.styleMask.remove(.resizable) } else { window?.styleMask.insert(.resizable) }
        window?.ignoresMouseEvents = value.clickThrough
        if kind == .text, textScale != (value.zoom ?? 1) {
            textScale = value.zoom ?? 1
            renderText()
        }
    }
    private func presentationDidChange() { if !closed && !applyingPresentation { onPresentationChange?(presentation) } }
    func windowDidMove(_ notification: Notification) { presentationDidChange() }
    func windowDidResize(_ notification: Notification) { presentationDidChange() }
    func windowWillClose(_ notification: Notification) {
        // An owned save panel can also deliver window-delegate notifications.
        // Its dismissal must never close/archive the owning pin.
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        finishClose()
    }
    override func close() { finishClose(); super.close() }
    private func finishClose() {
        guard !closed else { return }; closed = true
        let callback = onClose
        onClose = nil; onPresentationChange = nil; onToggleGroupSelection = nil; onShowGroupTransform = nil; onRichChange = nil
        onDesktopVisibilityChange = nil; desktopVisibilityMenu.invalidate()
        cancelLaTeXSave()
        latexModel?.close(); latexModel = nil
        latexPopover?.delegate = nil; latexPopover?.close(); latexPopover?.contentViewController = nil; latexPopover = nil
        pausePlayback()
        if let decoder { Task { await decoder.release() } }; decoder = nil
        callback?()
        displayedLaTeXRaster = nil
        fileTable.dataSource = nil; fileTable.delegate = nil; fileTable.menu = nil; imageView.image = nil; imageView.menu = nil; textView.menu = nil
        textView.textStorage?.setAttributedString(NSAttributedString(string: "")); richDocument = nil
        window?.delegate = nil; window?.contentView = nil
    }
}

/// Empty margins and image surfaces are drag targets; text selection and file drag-out remain native.
@MainActor private final class RichPinBackgroundView: NSView {
    var previewBackingColor: NSColor?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let previewBackingColor { previewBackingColor.setFill(); NSBezierPath(rect: bounds).fill() }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if window?.isMovable == true { window?.performDrag(with: event) }
    }
}
@MainActor private final class RichPinImageView: NSImageView {
    var usesIntrinsicImageSize = true { didSet { invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize: NSSize {
        usesIntrinsicImageSize ? super.intrinsicContentSize : NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if window?.isMovable == true { window?.performDrag(with: event) }
    }
}
