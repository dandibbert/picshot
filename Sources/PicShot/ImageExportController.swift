import AppKit

/// Compact, shared owned export window for editor, pin, original and history images.
/// At most two immutable sessions are admitted. The serial ImageIO/PDF queue
/// and the shared GIF/WebP/AVIF child lease are separate and may overlap.
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
    let retryButton = NSButton(title: "重试", target: nil, action: nil)
    let quickSaveButton = NSButton(title: "快速保存", target: nil, action: nil)
    let saveCopyButton = NSButton(title: "保存并复制", target: nil, action: nil)
    private let saveWorkflow: SaveWorkflowPresenter?
    private let previousButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let cancellation = ImageExportCancellation()
    private var previewCancellation = ImageExportCancellation()
    private var previewOperation: Operation?
    private var codecTask: Task<Void, Never>?
    private var pageOperation: Operation?
    private var previewInput: ImageExportJobInput<ImageExportSnapshot>?
    private var pageInput: ImageExportJobInput<ImageExportArtifact>?
    private var saveInput: ImageExportJobInput<ImageExportArtifact>?
    private let encoder: ImageExportEncoder
    private let bundledEncoder: ImageExportBundledEncoder
    private var debounce: Task<Void, Never>?
    private var generation = 0
    private var pageGeneration = 0
    private var parentObserver: NSObjectProtocol?
    private var parentLayoutObservers: [NSObjectProtocol] = []
    private weak var parentWindow: NSWindow?
    private var savePanel: NSSavePanel?
    private let suggestedName: String
    private var onSaved: ((URL) -> Void)?
    private var fittingWindow = false
    private var layoutVisibleFrame: CGRect?
    private var windowFitTask: Task<Void, Never>?
    private(set) var latestArtifact: ImageExportArtifact?
    private(set) var previewPage = 0
    private(set) var isClosed = false
    private(set) var isSaving = false
    /// First page is in the artifact; retain at most one additional decoded page.
    private var cachedPage: (index: Int, image: CGImage)?

    @discardableResult
    static func present(image: CGImage, from parent: NSWindow, suggestedName: String = "PicShot",
                        sourceURL: URL? = nil, saveWorkflow: SaveWorkflowPresenter? = nil,
                        onSaved: ((URL) -> Void)? = nil) -> ImageExportController? {
        if let existing = active.values.first(where: { $0.parentWindow === parent }) {
            existing.window?.makeKeyAndOrderFront(nil); return existing
        }
        guard active.count < maximumSessions, parent.attachedSheet == nil else {
            showError(PicShotError.message("请先完成或关闭当前导出窗口。")); return nil
        }
        do {
            let controller = try ImageExportController(image: image, suggestedName: suggestedName, sourceURL: sourceURL, onSaved: onSaved, saveWorkflow: saveWorkflow)
            active[ObjectIdentifier(controller)] = controller
            controller.parentWindow = parent
            controller.parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: parent, queue: .main) { [weak controller] _ in
                    MainActor.assumeIsolated { controller?.cancelExport() }
                }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                controller.parentLayoutObservers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak controller] _ in
                    MainActor.assumeIsolated { controller?.scheduleWindowFit() }
                })
            }
            controller.fitWindow(to: parent.screen?.visibleFrame)
            if let window = controller.window {
                // Sheets retain AppKit's parent-titlebar anchor even when that
                // places a large export below the visible desktop. An owned
                // child has explicit screen-clamped geometry for small pins,
                // borderless captures and ordinary windows alike.
                window.setFrameOrigin(CGPoint(x: parent.frame.midX - window.frame.width / 2,
                                              y: parent.frame.midY - window.frame.height / 2))
                PinDesktopVisibilityPolicy.inheritSpaceBehavior(from: parent, to: window)
                parent.addChildWindow(window, ordered: .above)
                var level = parent.level.rawValue, ancestor: NSWindow? = parent
                for _ in 0..<8 {
                    guard let next = ancestor?.sheetParent ?? ancestor?.parent else { break }
                    level = max(level, next.level.rawValue); ancestor = next
                }
                window.level = NSWindow.Level(rawValue: level < Int.max ? level + 1 : level)
                controller.fitWindow(to: parent.screen?.visibleFrame)
                window.makeKeyAndOrderFront(nil)
                controller.scheduleWindowFit()
            }
            controller.requestPreview()
            return controller
        } catch { showError(error); return nil }
    }

    /// Internal construction supports native control/close fixtures without a
    /// filesystem picker. Production callers use present to enforce admission.
    init(image: CGImage, suggestedName: String = "PicShot", sourceURL: URL? = nil, onSaved: ((URL) -> Void)? = nil,
         saveWorkflow: SaveWorkflowPresenter? = nil, encoder: @escaping ImageExportEncoder = { snapshot, options, token in
             try ImageExportService.encode(snapshot: snapshot, options: options, cancellation: token)
         }, bundledEncoder: @escaping ImageExportBundledEncoder = { snapshot, options in
             try await ImageExportService.encodeBundled(snapshot: snapshot, options: options)
         }) throws {
        self.encoder = encoder; self.bundledEncoder = bundledEncoder; self.saveWorkflow = saveWorkflow ?? SaveWorkflowPresenter.application
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
        retryButton.target = self; retryButton.action = #selector(retryPreview)
        retryButton.identifier = NSUserInterfaceItemIdentifier("export.retry"); retryButton.isHidden = true
        quickSaveButton.target = self; quickSaveButton.action = #selector(quickSavePrepared)
        saveCopyButton.target = self; saveCopyButton.action = #selector(saveAndCopyPrepared)
        quickSaveButton.identifier = .init("export.quickSave"); saveCopyButton.identifier = .init("export.saveCopy")
        quickSaveButton.isHidden = saveWorkflow == nil; saveCopyButton.isHidden = saveWorkflow == nil
        saveCopyButton.toolTip = "复制实际保存的编码数据；WebP / AVIF / PDF 是否可粘贴为图片取决于目标应用。"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spinner, spacer, retryButton, quickSaveButton, saveCopyButton, cancel, saveButton]); actions.spacing = 8
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

    /// Image pixels never participate in the export window's fitting size. Keep the
    /// preferred 620×550 content rectangle, shrinking it for the actual usable
    /// desktop, and clamp both standalone and parent-owned windows on screen.
    func fitWindow(to visibleFrame: CGRect? = nil) {
        guard let window, !isClosed, !fittingWindow else { return }
        fittingWindow = true; defer { fittingWindow = false }
        layoutVisibleFrame = visibleFrame
        let usable = visibleFrame ?? parentWindow?.screen?.visibleFrame ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let inset: CGFloat = window.parent == nil ? 12 : 20
        let safe = usable.insetBy(dx: min(inset, usable.width / 20), dy: min(inset, usable.height / 20))
        let chrome = max(0, window.frame.height - window.contentRect(forFrameRect: window.frame).height)
        let size = CGSize(width: min(620, max(1, safe.width)), height: min(550, max(1, safe.height - chrome)))
        // A non-resizable export should not silently enlarge when a decoded
        // image is assigned, or when format/page/quality controls change.
        window.contentMinSize = size; window.contentMaxSize = size
        // Avoid redundant size changes while its parent is moving.
        if window.contentView?.bounds.size != size { window.setContentSize(size) }
        window.contentView?.layoutSubtreeIfNeeded()
        var frame = window.frame
        frame.origin.x = max(safe.minX, min(frame.minX, safe.maxX - frame.width))
        frame.origin.y = max(safe.minY, min(frame.minY, safe.maxY - frame.height))
        if window.frame != frame { window.setFrame(frame, display: false) }
    }
    func windowDidChangeScreen(_ notification: Notification) { fitWindow(); scheduleWindowFit() }
    func windowDidMove(_ notification: Notification) {
        guard !fittingWindow else { return }
        if window?.parent != nil { scheduleWindowFit() }
        else { fitWindow(to: layoutVisibleFrame) }
    }
    private func scheduleWindowFit() {
        guard !isClosed, windowFitTask == nil else { return }
        // Child movement can follow its parent's notification. Coalesce a
        // bounded post-layout fit without moving the parent or taking over its
        // delegate; no polling loop or image retention.
        windowFitTask = Task { @MainActor [weak self] in
            await Task.yield()
            for delay in [UInt64(0), 100_000_000, 300_000_000] {
                if delay > 0 { do { try await Task.sleep(nanoseconds: delay) } catch { return } }
                guard !Task.isCancelled, let self, !self.isClosed else { return }
                self.fitWindow(to: self.parentWindow?.screen?.visibleFrame ?? self.layoutVisibleFrame)
            }
            self?.windowFitTask = nil
        }
    }

    func requestPreview() {
        guard !isClosed, !isSaving, let snapshot else { return }
        generation += 1; pageGeneration += 1
        debounce?.cancel(); previewCancellation.cancel(); previewOperation?.cancel(); pageOperation?.cancel(); codecTask?.cancel(); codecTask = nil
        previewOperation = nil; pageOperation = nil; debounce = nil
        previewInput?.clear(); pageInput?.clear(); previewInput = nil; pageInput = nil
        previewCancellation = ImageExportCancellation()
        latestArtifact = nil; cachedPage = nil; previewPage = 0; previewView.image = nil
        saveButton.isEnabled = false; retryButton.isHidden = true; statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = accessory.options.format.usesBundledCodec
            ? "正在准备独立编码…若其他导出正在运行，将等待最多 5 分钟，可随时取消"
            : "正在编码完整图片…"
        spinner.startAnimation(nil); refreshPageControls()
        let options = accessory.options, token = previewCancellation, current = generation, encoder = encoder, bundledEncoder = bundledEncoder
        let input = ImageExportJobInput(snapshot); previewInput = input
        let job = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 160_000_000) } catch { return }
            guard !Task.isCancelled, !token.isCancelled, let self, !self.isClosed, current == self.generation else { return }
            if options.format.usesBundledCodec {
                self.codecTask = Task { @MainActor [weak self] in
                    guard let snapshot = input.take(), !token.isCancelled else { return }
                    let result: Result<ImageExportArtifact, Error>
                    do { result = .success(try await bundledEncoder(snapshot, options)) }
                    catch { result = .failure(error) }
                    guard let self, !self.isClosed, current == self.generation, !token.isCancelled, !Task.isCancelled else { return }
                    self.codecTask = nil; self.debounce = nil; self.previewInput = nil
                    self.spinner.stopAnimation(nil)
                    switch result {
                    case .success(let artifact):
                        self.latestArtifact = artifact; self.previewView.image = artifact.firstPreview.nsImage
                        self.saveButton.isEnabled = true; self.showSize(artifact); self.refreshPageControls()
                    case .failure(let error):
                        self.statusLabel.textColor = .systemRed; self.statusLabel.stringValue = error.localizedDescription
                        self.retryButton.isHidden = false
                    }
                }
                return
            }
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
        let alpha = artifact.options.retainsAlpha ? "" : " · 透明区域合成白底"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "实际编码 \(size)（\(artifact.byteCount) 字节） · \(artifact.width) × \(artifact.height)\(alpha)\n预览来自待保存文件；保存不再重新编码"
    }
    private func refreshPageControls() {
        quickSaveButton.isEnabled = latestArtifact != nil && !isSaving && !isClosed
        saveCopyButton.isEnabled = quickSaveButton.isEnabled
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

    @objc private func quickSavePrepared() { savePreparedUsingWorkflow(copy: false) }
    @objc private func saveAndCopyPrepared() { savePreparedUsingWorkflow(copy: true) }
    private func savePreparedUsingWorkflow(copy: Bool) {
        guard !isClosed, !isSaving, let artifact = latestArtifact, let saveWorkflow else { return }
        isSaving = true; accessory.setControlsEnabled(false); saveButton.isEnabled = false; refreshPageControls()
        guard let job = saveWorkflow.save(artifact: artifact, copy: copy, from: window, onSaved: { [weak self] saved in
            guard let self, !self.isClosed else { return }
            if saved.clipboardOutcome == .failed || saved.clipboardOutcome == .cancelledAfterSave {
                self.statusLabel.stringValue = "文件已保存，复制未完成；原文件和导出内容仍保留。"; return
            }
            let callback = self.onSaved; self.onSaved = nil; self.finish(); callback?(saved.savedURL)
        }) else { isSaving = false; accessory.setControlsEnabled(true); saveButton.isEnabled = true; refreshPageControls(); return }
        let existingClose = job.onClose
        job.onClose = { [weak self] in
            existingClose?()
            guard let self, !self.isClosed else { return }
            self.isSaving = false; self.accessory.setControlsEnabled(true); self.saveButton.isEnabled = self.latestArtifact != nil
            self.refreshPageControls()
        }
    }
    @objc private func retryPreview() { requestPreview() }
    @objc func cancelExport() { cancellation.cancel(); finish() }
    func windowWillClose(_ notification: Notification) { cancellation.cancel(); finish() }
    private func finish() {
        guard !isClosed else { return }; isClosed = true
        windowFitTask?.cancel(); windowFitTask = nil
        previewCancellation.cancel(); previewOperation?.cancel(); pageOperation?.cancel(); debounce?.cancel(); codecTask?.cancel(); codecTask = nil
        previewOperation = nil; pageOperation = nil; debounce = nil; snapshot = nil
        previewInput?.clear(); pageInput?.clear(); saveInput?.clear()
        previewInput = nil; pageInput = nil; saveInput = nil
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }; parentObserver = nil
        parentLayoutObservers.forEach { NotificationCenter.default.removeObserver($0) }; parentLayoutObservers.removeAll()
        if let savePanel { savePanel.cancel(nil) }; savePanel = nil
        accessory.onChange = nil; latestArtifact = nil; cachedPage = nil; previewView.image = nil; saveButton.isEnabled = false
        retryButton.isHidden = true; retryButton.isEnabled = false
        if let window {
            window.parent?.removeChildWindow(window)
            window.level = .normal
            window.orderOut(nil); window.delegate = nil; window.contentView = nil; window.close()
        }
        parentWindow = nil
        onSaved = nil; Self.active.removeValue(forKey: ObjectIdentifier(self))
    }
}

/// WebP/AVIF require the signed bundled helper; native writers are never substituted.
@MainActor
final class ExportFormatAccessory: NSView {
    let picker = NSPopUpButton()
    let quality = NSSlider(value: 94, minValue: 1, maxValue: 100, target: nil, action: nil)
    let qualityValue = NSTextField(labelWithString: "94%")
    let lossless = NSButton(checkboxWithTitle: "无损", target: nil, action: nil)
    let preserveAlpha = NSButton(checkboxWithTitle: "保留透明度", target: nil, action: nil)
    let alphaQuality = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let alphaQualityValue = NSTextField(labelWithString: "100%")
    let paper = NSPopUpButton()
    let orientation = NSPopUpButton()
    let margin = NSPopUpButton()
    let pagination = NSPopUpButton()
    var onChange: (() -> Void)?
    private let pdfRow = NSStackView()
    private let qualityRow = NSStackView()
    private let codecRow = NSStackView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var enabled = true
    var options: ImageExportOptions {
        ImageExportOptions(format: ImageExportFormat(rawValue: picker.indexOfSelectedItem) ?? .png,
            quality: quality.doubleValue / 100, lossless: lossless.state == .on,
            preserveAlpha: preserveAlpha.state == .on, alphaQuality: alphaQuality.doubleValue / 100,
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
        lossless.identifier = NSUserInterfaceItemIdentifier("export.lossless")
        preserveAlpha.identifier = NSUserInterfaceItemIdentifier("export.preserveAlpha"); preserveAlpha.state = .on
        alphaQuality.identifier = NSUserInterfaceItemIdentifier("export.alphaQuality"); alphaQuality.isContinuous = true
        alphaQuality.widthAnchor.constraint(equalToConstant: 90).isActive = true
        codecRow.setViews([lossless, preserveAlpha, NSTextField(labelWithString: "透明度质量"), alphaQuality, alphaQualityValue], in: .leading)
        codecRow.spacing = 8; stack.addArrangedSubview(codecRow)
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        let controls: [NSControl] = [picker, quality, paper, orientation, margin, pagination, lossless, preserveAlpha, alphaQuality]
        for control in controls { control.target = self; control.action = #selector(changed) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        qualityRow.isHidden = selected.format != .jpeg && !selected.format.usesBundledCodec
        codecRow.isHidden = !selected.format.usesBundledCodec
        alphaQualityValue.stringValue = "\(Int(alphaQuality.doubleValue.rounded()))%"
        lossless.isEnabled = enabled; preserveAlpha.isEnabled = enabled
        alphaQuality.isEnabled = enabled && !selected.lossless && selected.preserveAlpha
        note.stringValue = selected.format.usesBundledCodec
            ? "独立编码进程 · 上限 1600 万像素 / 128 MiB · 关闭透明度时合成白底\n" + (selected.lossless ? "无损模式：颜色与透明度质量设为无损（滑块不参与编码）" : "有损模式：颜色与透明度分别按质量压缩")
            : "PNG / TIFF 保留透明度 · JPEG / BMP / PDF 合成白底"
        pdfRow.isHidden = selected.format != .pdf
        picker.isEnabled = enabled; quality.isEnabled = enabled && !(selected.format.usesBundledCodec && selected.lossless); paper.isEnabled = enabled
        orientation.isEnabled = enabled && selected.paper != .image
        margin.isEnabled = enabled && selected.paper != .image
        pagination.isEnabled = enabled && selected.paper != .image
    }
}

/// NSImageView normally advertises the decoded image's pixel-sized intrinsic
/// dimensions. That can enlarge an Auto Layout NSWindow far beyond the display.
/// This view is sized exclusively by the compact export panel's layout constraints.
@MainActor
final class ImageExportPreviewView: NSImageView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
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
