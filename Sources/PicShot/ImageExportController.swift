import AppKit

/// Compact, shared export sheet for editor, pin, original and history images.
/// At most two immutable sessions and one global encoder can be alive at once.
@MainActor
final class ImageExportController: NSWindowController, NSWindowDelegate, NSOpenSavePanelDelegate {
    private static var active: [ObjectIdentifier: ImageExportController] = [:]
    static var activeSessionCount: Int { active.count }
    static let maximumSessions = 2
    private var snapshot: ImageExportSnapshot?
    let accessory = ExportFormatAccessory()
    let previewView = ImageExportPreviewView()
    let statusLabel = NSTextField(wrappingLabelWithString: "正在编码…")
    let pageLabel = NSTextField(labelWithString: "")
    let saveButton = NSButton(title: "保存…", target: nil, action: nil)
    private let previousButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let cancellation = ImageExportCancellation()
    private var previewCancellation = ImageExportCancellation()
    private var previewOperation: Operation?
    private var pageOperation: Operation?
    private var previewInput: ImageExportJobInput<ImageExportSnapshot>?
    private var pageInput: ImageExportJobInput<ImageExportArtifact>?
    private var saveInput: ImageExportJobInput<ImageExportArtifact>?
    private let encoder: ImageExportEncoder
    private var debounce: Task<Void, Never>?
    private var generation = 0
    private var pageGeneration = 0
    private var parentObserver: NSObjectProtocol?
    private weak var parentWindow: NSWindow?
    private var savePanel: NSSavePanel?
    private let suggestedName: String
    private var onSaved: ((URL) -> Void)?
    private var fittingWindow = false
    private var layoutVisibleFrame: CGRect?
    private(set) var latestArtifact: ImageExportArtifact?
    private(set) var previewPage = 0
    private(set) var isClosed = false
    private(set) var isSaving = false
    /// First page is in the artifact; retain at most one additional decoded page.
    private var cachedPage: (index: Int, image: CGImage)?

    @discardableResult
    static func present(image: CGImage, from parent: NSWindow, suggestedName: String = "PicShot",
                        sourceURL: URL? = nil, onSaved: ((URL) -> Void)? = nil) -> ImageExportController? {
        if let existing = active.values.first(where: { $0.parentWindow === parent }) {
            existing.window?.makeKeyAndOrderFront(nil); return existing
        }
        guard active.count < maximumSessions, parent.attachedSheet == nil else {
            showError(PicShotError.message("请先完成或关闭当前导出窗口。")); return nil
        }
        do {
            let controller = try ImageExportController(image: image, suggestedName: suggestedName, sourceURL: sourceURL, onSaved: onSaved)
            active[ObjectIdentifier(controller)] = controller
            controller.parentWindow = parent
            controller.parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: parent, queue: .main) { [weak controller] _ in
                    MainActor.assumeIsolated { controller?.cancelExport() }
                }
            controller.fitWindow(to: parent.screen?.visibleFrame)
            if let window = controller.window {
                parent.beginSheet(window)
                controller.fitWindow(to: parent.screen?.visibleFrame)
            }
            controller.requestPreview()
            return controller
        } catch { showError(error); return nil }
    }

    /// Internal construction supports native control/close fixtures without a
    /// filesystem picker. Production callers use present to enforce admission.
    init(image: CGImage, suggestedName: String = "PicShot", sourceURL: URL? = nil, onSaved: ((URL) -> Void)? = nil,
         encoder: @escaping ImageExportEncoder = { snapshot, options, token in
             try ImageExportService.encode(snapshot: snapshot, options: options, cancellation: token)
         }) throws {
        self.encoder = encoder
        snapshot = try ImageExportSnapshot(image: image, sourceURL: sourceURL)
        self.suggestedName = (suggestedName as NSString).deletingPathExtension
        self.onSaved = onSaved
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 550),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "导出图片"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        buildInterface(); fitWindow()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        guard let root = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        accessory.onChange = { [weak self] in self?.requestPreview() }
        stack.addArrangedSubview(accessory)
        previewView.imageScaling = .scaleProportionallyUpOrDown; previewView.imageAlignment = .alignCenter
        previewView.identifier = NSUserInterfaceItemIdentifier("export.preview")
        previewView.wantsLayer = true; previewView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        stack.addArrangedSubview(previewView)
        let pages = NSStackView(views: [previousButton, pageLabel, nextButton]); pages.spacing = 8
        previousButton.target = self; previousButton.action = #selector(previousPage)
        nextButton.target = self; nextButton.action = #selector(nextPage)
        previousButton.identifier = NSUserInterfaceItemIdentifier("export.previousPage")
        nextButton.identifier = NSUserInterfaceItemIdentifier("export.nextPage")
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(pages)
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.maximumNumberOfLines = 3
        statusLabel.identifier = NSUserInterfaceItemIdentifier("export.status")
        stack.addArrangedSubview(statusLabel)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelExport)); cancel.keyEquivalent = "\u{1b}"
        cancel.identifier = NSUserInterfaceItemIdentifier("export.cancel")
        saveButton.target = self; saveButton.action = #selector(chooseDestination); saveButton.keyEquivalent = "\r"
        saveButton.identifier = NSUserInterfaceItemIdentifier("export.save"); saveButton.isEnabled = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spinner, spacer, cancel, saveButton]); actions.spacing = 10
        stack.addArrangedSubview(actions)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            accessory.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewView.widthAnchor.constraint(equalTo: stack.widthAnchor), previewView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor), spinner.widthAnchor.constraint(equalToConstant: 16)
        ])
        refreshPageControls()
    }

    /// Image pixels never participate in the sheet's fitting size. Keep the
    /// preferred 620×550 content rectangle, shrinking it for the actual usable
    /// desktop, and clamp both standalone windows and attached sheets on screen.
    func fitWindow(to visibleFrame: CGRect? = nil) {
        guard let window, !fittingWindow else { return }
        fittingWindow = true; defer { fittingWindow = false }
        layoutVisibleFrame = visibleFrame
        let usable = visibleFrame ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let safe = usable.insetBy(dx: min(12, usable.width / 20), dy: min(12, usable.height / 20))
        let chrome = max(0, window.frame.height - window.contentRect(forFrameRect: window.frame).height)
        let size = CGSize(width: min(620, max(1, safe.width)), height: min(550, max(1, safe.height - chrome)))
        // A non-resizable sheet should not silently enlarge when a decoded
        // image is assigned, or when format/page/quality controls change.
        window.contentMinSize = size; window.contentMaxSize = size
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.x = max(safe.minX, min(frame.minX, safe.maxX - frame.width))
        frame.origin.y = max(safe.minY, min(frame.minY, safe.maxY - frame.height))
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func windowDidChangeScreen(_ notification: Notification) { fitWindow() }
    func windowDidMove(_ notification: Notification) {
        // AppKit may reposition a sheet after beginSheet or when its small/edge
        // parent moves. Reapply the same usable-screen constraint after that move.
        fitWindow(to: layoutVisibleFrame)
    }

    func requestPreview() {
        guard !isClosed, !isSaving, let snapshot else { return }
        generation += 1; pageGeneration += 1
        debounce?.cancel(); previewCancellation.cancel(); previewOperation?.cancel(); pageOperation?.cancel()
        previewOperation = nil; pageOperation = nil; debounce = nil
        previewInput?.clear(); pageInput?.clear(); previewInput = nil; pageInput = nil
        previewCancellation = ImageExportCancellation()
        latestArtifact = nil; cachedPage = nil; previewPage = 0; previewView.image = nil
        saveButton.isEnabled = false; statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "正在编码完整图片…"; spinner.startAnimation(nil); refreshPageControls()
        let options = accessory.options, token = previewCancellation, current = generation, encoder = encoder
        let input = ImageExportJobInput(snapshot); previewInput = input
        let job = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 160_000_000) } catch { return }
            guard !Task.isCancelled, !token.isCancelled, let self, !self.isClosed, current == self.generation else { return }
            let operation = BlockOperation { [weak self] in
                guard let snapshot = input.take(), !token.isCancelled else { return }
                let result: Result<ImageExportArtifact, Error> = Result {
                    try autoreleasepool { try encoder(snapshot, options, token) }
                }
                guard !token.isCancelled else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isClosed, current == self.generation, !token.isCancelled else { return }
                    self.previewOperation = nil; self.debounce = nil; self.previewInput = nil
                    self.spinner.stopAnimation(nil)
                    switch result {
                    case .success(let artifact):
                        self.latestArtifact = artifact; self.previewView.image = artifact.firstPreview.nsImage
                        self.saveButton.isEnabled = true; self.showSize(artifact); self.refreshPageControls()
                    case .failure(let error):
                        self.statusLabel.textColor = .systemRed; self.statusLabel.stringValue = error.localizedDescription
                    }
                }
            }
            self.previewOperation = operation; ImageExportService.queue.addOperation(operation)
        }
        debounce = job
    }

    private func showSize(_ artifact: ImageExportArtifact) {
        let size = ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .binary)
        let alpha = artifact.options.format.preservesAlpha ? "" : " · 透明区域合成白底"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "实际编码 \(size)（\(artifact.byteCount) 字节） · \(artifact.width) × \(artifact.height)\(alpha)\n预览来自待保存文件；保存不再重新编码"
    }
    private func refreshPageControls() {
        let count = latestArtifact?.pageCount ?? 0
        pageLabel.stringValue = count > 0 ? "第 \(previewPage + 1) / \(count) 页" : ""
        previousButton.isEnabled = previewPage > 0 && !isSaving
        nextButton.isEnabled = previewPage + 1 < count && !isSaving
        previousButton.isHidden = count < 2; nextButton.isHidden = count < 2; pageLabel.isHidden = count < 2
    }
    @objc private func previousPage() { showPage(previewPage - 1) }
    @objc private func nextPage() { showPage(previewPage + 1) }
    func showPage(_ page: Int) {
        guard !isClosed, !isSaving, let artifact = latestArtifact, (0..<artifact.pageCount).contains(page) else { return }
        pageOperation?.cancel(); pageOperation = nil; pageInput?.clear(); pageInput = nil
        pageGeneration += 1; let currentPageGeneration = pageGeneration, current = generation
        previewPage = page; refreshPageControls()
        if page == 0 { previewView.image = artifact.firstPreview.nsImage; return }
        if let cachedPage, cachedPage.index == page { previewView.image = cachedPage.image.nsImage; return }
        previewView.image = nil
        let token = previewCancellation, input = ImageExportJobInput(artifact)
        pageInput = input
        let operation = BlockOperation { [weak self] in
            guard let artifact = input.take(), !token.isCancelled else { return }
            let result = Result { try autoreleasepool { try ImageExportService.preview(data: artifact.data, format: .pdf, page: page) } }
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, self.generation == current, self.pageGeneration == currentPageGeneration,
                      !token.isCancelled else { return }
                self.pageOperation = nil; self.pageInput = nil
                switch result {
                case .success(let image): self.cachedPage = (page, image); self.previewView.image = image.nsImage
                case .failure(let error): self.statusLabel.textColor = .systemRed; self.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
        pageOperation = operation; ImageExportService.queue.addOperation(operation)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        try ImageExportService.requireUnoccupied(url)
    }

    @objc private func chooseDestination() {
        guard !isClosed, !isSaving, savePanel == nil, let artifact = latestArtifact, let window else { return }
        let panel = NSSavePanel(); panel.title = "保存新副本"; panel.prompt = "保存新副本"
        panel.nameFieldLabel = "新副本名称："; panel.message = "请选择尚未使用的文件名；原图和已有文件不会被覆盖。"
        panel.delegate = self
        panel.allowedContentTypes = [artifact.options.format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName + "." + artifact.options.format.filenameExtension
        savePanel = panel; saveButton.isEnabled = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; self.savePanel = nil
            guard !self.isClosed else { return }
            guard response == .OK, let url = panel.url else { self.saveButton.isEnabled = self.latestArtifact != nil; return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.savePrepared(to: url) }
                catch is CancellationError { }
                catch {
                    guard !self.isClosed else { return }
                    self.statusLabel.textColor = .systemRed; self.statusLabel.stringValue = error.localizedDescription
                    self.saveButton.isEnabled = self.latestArtifact != nil
                }
            }
        }
    }

    /// The installed fixture and normal picker share this exact publication path.
    func savePrepared(to url: URL) async throws {
        guard !isClosed, !isSaving, latestArtifact != nil else { throw CancellationError() }
        let input = ImageExportJobInput(latestArtifact!); saveInput = input
        isSaving = true; accessory.setControlsEnabled(false); saveButton.isEnabled = false
        refreshPageControls(); spinner.startAnimation(nil); statusLabel.stringValue = "正在安全保存…"
        let token = cancellation
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ImageExportService.queue.addOperation {
                    guard let artifact = input.take(), !token.isCancelled else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    do { try ImageExportService.publish(artifact, to: url, cancellation: token); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
            // Publication won its cancellation fence. The complete file exists.
            let callback = onSaved; onSaved = nil
            finish(); callback?(url)
        } catch {
            saveInput?.clear(); saveInput = nil
            isSaving = false; spinner.stopAnimation(nil); accessory.setControlsEnabled(true); refreshPageControls()
            throw error
        }
    }

    @objc func cancelExport() { cancellation.cancel(); finish() }
    func windowWillClose(_ notification: Notification) { cancellation.cancel(); finish() }
    private func finish() {
        guard !isClosed else { return }; isClosed = true
        previewCancellation.cancel(); previewOperation?.cancel(); pageOperation?.cancel(); debounce?.cancel()
        previewOperation = nil; pageOperation = nil; debounce = nil; snapshot = nil
        previewInput?.clear(); pageInput?.clear(); saveInput?.clear()
        previewInput = nil; pageInput = nil; saveInput = nil
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }; parentObserver = nil
        if let savePanel { savePanel.cancel(nil) }; savePanel = nil
        accessory.onChange = nil; latestArtifact = nil; cachedPage = nil; previewView.image = nil; saveButton.isEnabled = false
        if let window {
            if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
            window.orderOut(nil); window.delegate = nil; window.close()
        }
        onSaved = nil; Self.active.removeValue(forKey: ObjectIdentifier(self))
    }
}

/// Only real encoders are offered. WebP/AVIF remain an explicit capability gap
/// until the native probe (or a reviewed bundled codec) verifies actual output.
@MainActor
final class ExportFormatAccessory: NSView {
    let picker = NSPopUpButton()
    let quality = NSSlider(value: 94, minValue: 1, maxValue: 100, target: nil, action: nil)
    let qualityValue = NSTextField(labelWithString: "94%")
    let paper = NSPopUpButton()
    let orientation = NSPopUpButton()
    let margin = NSPopUpButton()
    let pagination = NSPopUpButton()
    var onChange: (() -> Void)?
    private let pdfRow = NSStackView()
    private let qualityRow = NSStackView()
    private var enabled = true
    var options: ImageExportOptions {
        ImageExportOptions(format: ImageExportFormat(rawValue: picker.indexOfSelectedItem) ?? .png,
            quality: quality.doubleValue / 100,
            paper: ImageExportPaper(rawValue: paper.indexOfSelectedItem) ?? .image,
            orientation: ImageExportOrientation(rawValue: orientation.indexOfSelectedItem) ?? .portrait,
            margin: Double(margin.selectedItem?.tag ?? 24),
            pagination: ImageExportPagination(rawValue: pagination.indexOfSelectedItem) ?? .vertical)
    }
    override init(frame frameRect: NSRect = NSRect(x: 0, y: 0, width: 584, height: 104)) {
        super.init(frame: frameRect)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        picker.addItems(withTitles: ImageExportFormat.allCases.map(\.title)); picker.identifier = NSUserInterfaceItemIdentifier("export.format")
        paper.addItems(withTitles: ImageExportPaper.allCases.map(\.title)); paper.identifier = NSUserInterfaceItemIdentifier("export.paper")
        orientation.addItems(withTitles: ["纵向纸张", "横向纸张"]); orientation.identifier = NSUserInterfaceItemIdentifier("export.orientation")
        for points in [0, 12, 24, 36, 54, 72] { margin.addItem(withTitle: "\(points) pt"); margin.lastItem?.tag = points }
        margin.selectItem(withTag: 24); margin.identifier = NSUserInterfaceItemIdentifier("export.margin")
        pagination.addItems(withTitles: ["纵向分页", "横向分页"]); pagination.identifier = NSUserInterfaceItemIdentifier("export.pagination")
        quality.identifier = NSUserInterfaceItemIdentifier("export.quality"); quality.isContinuous = true
        qualityRow.setViews([NSTextField(labelWithString: "质量"), quality, qualityValue], in: .leading); qualityRow.spacing = 7
        let first = NSStackView(views: [NSTextField(labelWithString: "格式"), picker, qualityRow]); first.spacing = 10
        stack.addArrangedSubview(first)
        pdfRow.setViews([paper, orientation, NSTextField(labelWithString: "边距"), margin, pagination], in: .leading); pdfRow.spacing = 6
        stack.addArrangedSubview(pdfRow)
        let note = NSTextField(labelWithString: "PNG / TIFF 保留透明度 · WebP / AVIF 编码尚未提供")
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        let controls: [NSControl] = [picker, quality, paper, orientation, margin, pagination]
        for control in controls { control.target = self; control.action = #selector(changed) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            quality.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            quality.widthAnchor.constraint(lessThanOrEqualToConstant: 160), picker.widthAnchor.constraint(equalToConstant: 110)
        ])
        let preferredQualityWidth = quality.widthAnchor.constraint(equalToConstant: 160)
        preferredQualityWidth.priority = .defaultHigh; preferredQualityWidth.isActive = true
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { updateControls(); onChange?() }
    func setControlsEnabled(_ value: Bool) { enabled = value; updateControls() }
    private func updateControls() {
        let selected = options
        qualityValue.stringValue = "\(Int(quality.doubleValue.rounded()))%"
        qualityRow.isHidden = selected.format != .jpeg
        pdfRow.isHidden = selected.format != .pdf
        picker.isEnabled = enabled; quality.isEnabled = enabled; paper.isEnabled = enabled
        orientation.isEnabled = enabled && selected.paper != .image
        margin.isEnabled = enabled && selected.paper != .image
        pagination.isEnabled = enabled && selected.paper != .image
    }
}

/// NSImageView normally advertises the decoded image's pixel-sized intrinsic
/// dimensions. That can enlarge an Auto Layout NSWindow far beyond the display.
/// This view is sized exclusively by the compact sheet's layout constraints.
@MainActor
final class ImageExportPreviewView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    var displayedImageRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Draw into the exact aspect-fit rectangle exposed to the fixture. The
        // source NSImage still comes only from independently decoded export bytes.
        guard let image else { return }
        image.draw(in: displayedImageRect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}
