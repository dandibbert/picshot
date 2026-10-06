import AppKit
import PicShotCore

/// Final-output jobs are application-owned and survive capture-editor close.
/// Count and estimated retained-input admission precede snapshot allocation;
/// encoded output is separately bounded and this is not a total RSS quota.
@MainActor
final class SaveWorkflowPresenter {
    /// Installed only by the real application. Test/smoke controllers require an
    /// explicitly injected isolated presenter and never fall back to user data.
    static weak var application: SaveWorkflowPresenter?
    static let maximumJobs = 2
    static let maximumRetainedInputBytes = 256 * 1_024 * 1_024
    private let defaults: UserDefaults
    private let isSmoke: Bool
    private(set) var controllers: [SaveWorkflowController] = []
    var activeJobCount: Int { controllers.filter { !$0.jobDrained }.count }
    var retainedInputBytes: Int { controllers.reduce(0) { $0 + ($1.jobDrained ? $1.retainedClipboardBytes : $1.reservedInputBytes) } }
    var onSettings: ((NSWindow?) -> Void)?
    var onPresent: ((SaveWorkflowController) -> Void)?
    var clipboardCopier: ((Data, String) -> Bool)?
    /// Set only by isolated native fixtures; production does not log paths.
    var directoryDiagnostic: ((SaveWorkflowDirectoryDiagnostic) -> Void)?
    init(defaults: UserDefaults = .standard, isSmoke: Bool = false) { self.defaults = defaults; self.isSmoke = isSmoke }
    func cancelAll() { for controller in controllers { controller.cancel() } }
    func canAdmit(inputBytes: Int) -> Bool {
        inputBytes > 0 && controllers.count < Self.maximumJobs && inputBytes <= Self.maximumRetainedInputBytes - retainedInputBytes
    }
    @discardableResult
    func save(image: CGImage, copy: Bool = false, automatic: Bool = false, from parent: NSWindow? = nil,
              onSaved: ((SaveWorkflowResult) -> Void)? = nil) -> SaveWorkflowController? {
        guard !isSmoke else { return nil }
        let settings = SaveWorkflowSettings.read(from: defaults)
        if automatic && !settings.shouldAutomaticallySave(for: .finalizedAction) { return nil }
        return present(settings: settings, image: image, artifact: nil, copy: copy, automatic: automatic, parent: parent, onSaved: onSaved)
    }
    @discardableResult
    func save(artifact: ImageExportArtifact, copy: Bool, from parent: NSWindow? = nil,
              onSaved: ((SaveWorkflowResult) -> Void)? = nil) -> SaveWorkflowController? {
        guard !isSmoke else { return nil }
        return present(settings: .read(from: defaults), image: nil, artifact: artifact, copy: copy, automatic: false, parent: parent, onSaved: onSaved)
    }
    private func present(settings: SaveWorkflowSettings, image: CGImage?, artifact: ImageExportArtifact?, copy: Bool,
                         automatic: Bool, parent: NSWindow?, onSaved: ((SaveWorkflowResult) -> Void)?) -> SaveWorkflowController? {
        let reservation: Int
        if let image {
            guard image.width > 0, image.height > 0, image.width <= ImageExportLimits.standard.maximumSourcePixels / image.height else {
                showError(ImageExportError.sourceTooLarge); return nil
            }
            reservation = image.width * image.height * 4
        } else if let artifact { reservation = artifact.byteCount + artifact.firstPreview.bytesPerRow * artifact.firstPreview.height }
        else { return nil }
        guard canAdmit(inputBytes: reservation) else {
            showError(PicShotError.message("保存任务达到保护上限（最多两项、256 MiB 待保存内容）。这次操作未创建额外副本；请完成或取消现有任务后重试。")); return nil
        }
        do {
            let controller = try SaveWorkflowController(image: image, artifact: artifact, settings: settings, defaults: defaults,
                copyAfterSaving: copy, quietAutomatic: automatic, reservedInputBytes: reservation, copier: clipboardCopier, directoryDiagnostic: directoryDiagnostic, onSaved: onSaved)
            controllers.append(controller)
            controller.onClose = { [weak self, weak controller] in
                guard let controller, controller.jobDrained else { return }; self?.controllers.removeAll { $0 === controller }
            }
            controller.onDrained = { [weak self, weak controller] in
                guard let controller, controller.state == .closed else { return }; self?.controllers.removeAll { $0 === controller }
            }
            if !automatic { controller.attach(to: parent); controller.revealForDecision() }
            onPresent?(controller); controller.start(); return controller
        } catch { showError(error); return nil }
    }
}

struct SaveWorkflowSummary {
    let savedURL: URL
    let byteCount: Int
    let clipboardOutcome: SaveWorkflowClipboardOutcome
    init(_ result: SaveWorkflowResult) { savedURL = result.savedURL; byteCount = result.byteCount; clipboardOutcome = result.clipboardOutcome }
}

@MainActor
final class SaveWorkflowController: NSWindowController, NSWindowDelegate {
    enum State: Equatable { case ready, choosingFolder, encoding, saving, collision, completed, failed, closed }
    private(set) var state: State = .ready
    private(set) var result: SaveWorkflowSummary?
    private(set) var jobDrained = false
    let reservedInputBytes: Int
    let quietAutomatic: Bool
    private var savedForCopy: SaveWorkflowResult?
    var retainedClipboardBytes: Int { savedForCopy?.byteCount ?? 0 }
    let statusLabel = NSTextField(wrappingLabelWithString: "准备保存最终图片…")
    let closeButton = NSButton(title: "取消", target: nil, action: nil)
    let retryCopyButton = NSButton(title: "重试复制", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let defaults: UserDefaults
    private var settings: SaveWorkflowSettings
    private var snapshot: ImageExportSnapshot?
    private var artifact: ImageExportArtifact?
    private let copyAfterSaving: Bool
    private let copier: ((Data, String) -> Bool)?
    private let directoryDiagnostic: ((SaveWorkflowDirectoryDiagnostic) -> Void)?
    private let token = ImageExportCancellation()
    private var input: ImageExportJobInput<ImageExportSnapshot>?
    private var saveInput: ImageExportJobInput<ImageExportArtifact>?
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var timedOut = false
    private var callback: ((SaveWorkflowResult) -> Void)?
    private weak var parentWindow: NSWindow?
    private var parentObserver: NSObjectProtocol?
    var onClose: (() -> Void)?
    var onDrained: (() -> Void)?
    var onFolderPanelShown: ((NSOpenPanel) -> Void)?
    var onCollisionShown: ((NSAlert) -> Void)?
    var onSavePanelShown: ((NSSavePanel) -> Void)?
    private(set) var folderPanel: NSOpenPanel?
    private(set) var collisionAlert: NSAlert?
    private(set) var savePanel: NSSavePanel?

    init(image: CGImage?, artifact: ImageExportArtifact?, settings: SaveWorkflowSettings, defaults: UserDefaults,
         copyAfterSaving: Bool, quietAutomatic: Bool = false, reservedInputBytes: Int = 0,
         copier: ((Data, String) -> Bool)? = nil, directoryDiagnostic: ((SaveWorkflowDirectoryDiagnostic) -> Void)? = nil,
         onSaved: ((SaveWorkflowResult) -> Void)? = nil) throws {
        guard (image != nil) != (artifact != nil) else { throw SaveWorkflowError.invalidArtifact }
        self.defaults = defaults; self.settings = settings; self.copyAfterSaving = copyAfterSaving
        self.copier = copier; self.directoryDiagnostic = directoryDiagnostic; callback = onSaved; self.artifact = artifact
        self.quietAutomatic = quietAutomatic; self.reservedInputBytes = reservedInputBytes
        if let image { snapshot = try ImageExportSnapshot(image: image) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = copyAfterSaving ? "保存并复制" : "快速保存"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        statusLabel.maximumNumberOfLines = 3; statusLabel.identifier = .init("saveWorkflow.status"); stack.addArrangedSubview(statusLabel)
        let note = NSTextField(wrappingLabelWithString: "只保存已合成的最终结果。已有文件不会被替换；取消不会修改原图。")
        if copyAfterSaving, let artifact, artifact.options.format != .png {
            note.stringValue = "复制实际保存格式的编码数据。WebP / AVIF / PDF 能否作为图片粘贴取决于目标应用；未提供通用 PNG 剪贴板兼容层。"
        }
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.maximumNumberOfLines = 3; stack.addArrangedSubview(note)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        closeButton.target = self; closeButton.action = #selector(cancel); closeButton.keyEquivalent = "\u{1b}"; closeButton.identifier = .init("saveWorkflow.cancel")
        retryCopyButton.target = self; retryCopyButton.action = #selector(retryCopy); retryCopyButton.isHidden = true; retryCopyButton.identifier = .init("saveWorkflow.retryCopy")
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spinner, spacer, retryCopyButton, closeButton]); row.spacing = 8; stack.addArrangedSubview(row)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -16),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor), row.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func start() {
        guard state == .ready else { return }; spinner.startAnimation(nil)
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
            guard let self, self.result == nil, self.state != .closed else { return }
            self.timedOut = true; self.token.cancel(); self.input?.clear(); self.saveInput?.clear(); self.task?.cancel()
            self.statusLabel.stringValue = "保存超过 5 分钟，已请求取消；原图和已完成文件会保留。"
            self.state = .failed; self.spinner.stopAnimation(nil); self.cancelPanels(); self.revealForDecision()
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.snapshot = nil; self.artifact = nil; self.input?.clear(); self.saveInput?.clear()
                self.task = nil; self.jobDrained = true
                let done = self.onDrained; self.onDrained = nil; done?()
            }
            do {
                try self.token.check()
                if self.settings.baseURL == nil {
                    guard let selected = await self.chooseFolder() else { throw CancellationError() }
                    try self.token.check()
                    let approved = try SaveWorkflowService.resolveApprovedDirectory(selected)
                    self.settings.baseURL = approved; try self.settings.save(to: self.defaults)
                }
                try self.token.check()
                let prepared = try await self.prepareArtifact(); try self.token.check(); self.snapshot = nil
                let context = SaveWorkflowContext(width: prepared.width, height: prepared.height,
                    counter: try SaveWorkflowCounter.next(in: self.defaults), timeZoneIdentifier: TimeZone.current.identifier)
                var behavior: SaveWorkflowCollisionBehavior? = nil, selectedURL: URL?
                while true {
                    try self.token.check(); self.state = .saving; self.statusLabel.stringValue = "正在保存完整文件…"
                    do {
                        let saved = try await self.publish(prepared, context: context, behavior: behavior, selectedURL: selectedURL)
                        let outcome = self.copyAfterSaving ? SaveWorkflowService.copySaved(saved, cancellation: self.token, copier: self.copier) : saved
                        self.result = SaveWorkflowSummary(outcome); self.savedForCopy = outcome.clipboardOutcome == .failed ? outcome : nil
                        self.deadline?.cancel(); self.deadline = nil
                        if self.state != .closed { self.showResult() }
                        self.callback?(outcome); self.callback = nil
                        if self.quietAutomatic && outcome.clipboardOutcome != .failed { self.cancel() }
                        return
                    } catch SaveWorkflowError.collision(let url) {
                        switch await self.resolveCollision(url) {
                        case .alertFirstButtonReturn: behavior = .keepBoth
                        case .alertSecondButtonReturn:
                            guard let choice = await self.chooseAnother(prepared, current: url) else { throw CancellationError() }
                            selectedURL = try SaveWorkflowService.resolveApprovedDirectory(choice.deletingLastPathComponent()).appendingPathComponent(choice.lastPathComponent)
                            behavior = .ask
                        default: throw CancellationError()
                        }
                    }
                }
            } catch is CancellationError {
                if !self.timedOut { self.cancel() }
            } catch {
                if self.state != .closed {
                    self.state = .failed; self.spinner.stopAnimation(nil); self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = error.localizedDescription + "\n原图仍然保留，可关闭后重试。"; self.closeButton.title = "关闭"
                    self.revealForDecision()
                }
            }
            self.deadline?.cancel(); self.deadline = nil
        }
    }
    private func prepareArtifact() async throws -> ImageExportArtifact {
        if let artifact { return artifact }
        guard let snapshot else { throw SaveWorkflowError.invalidArtifact }
        state = .encoding; statusLabel.stringValue = "正在编码最终 PNG…"
        let holder = ImageExportJobInput(snapshot), token = token; input = holder
        return try await withCheckedThrowingContinuation { continuation in
            ImageExportService.queue.addOperation {
                guard let frozen = holder.take() else { continuation.resume(throwing: CancellationError()); return }
                do { continuation.resume(returning: try autoreleasepool { try ImageExportService.encode(snapshot: frozen, options: .init(), cancellation: token) }) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func publish(_ artifact: ImageExportArtifact, context: SaveWorkflowContext,
                         behavior: SaveWorkflowCollisionBehavior?, selectedURL: URL?) async throws -> SaveWorkflowResult {
        let holder = ImageExportJobInput(artifact), settings = settings, token = token; saveInput = holder
        let hooks = SaveWorkflowTestHooks(directoryFailure: directoryDiagnostic)
        return try await withCheckedThrowingContinuation { continuation in
            ImageExportService.queue.addOperation {
                guard let artifact = holder.take() else { continuation.resume(throwing: CancellationError()); return }
                do {
                    let result: SaveWorkflowResult
                    if let selectedURL { result = try SaveWorkflowService.publish(artifact, to: selectedURL, collisionBehavior: behavior ?? .ask, cancellation: token, testHooks: hooks) }
                    else { result = try SaveWorkflowService.publish(artifact, settings: settings, context: context, collisionBehavior: behavior, cancellation: token, testHooks: hooks) }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func chooseFolder() async -> URL? {
        state = .choosingFolder; statusLabel.stringValue = "请选择快速保存目录，此选择会记入保存设置。"
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.title = "选择快速保存文件夹"; panel.prompt = "使用此文件夹"; folderPanel = panel
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window!) { [weak self] response in self?.folderPanel = nil; continuation.resume(returning: response == .OK ? panel.url : nil) }
            DispatchQueue.main.async { [weak self] in self?.onFolderPanelShown?(panel) }
        }
    }
    private func resolveCollision(_ url: URL) async -> NSApplication.ModalResponse {
        guard state != .closed, let window else { return .cancel }
        state = .collision; spinner.stopAnimation(nil); revealForDecision()
        let alert = NSAlert(); alert.messageText = "已存在同名文件"; alert.informativeText = url.lastPathComponent + "\n原文件不会被替换，请选择接下来的操作。"
        alert.addButton(withTitle: "保留两者"); alert.addButton(withTitle: "选择其他名称…"); alert.addButton(withTitle: "取消"); collisionAlert = alert
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { [weak self] response in self?.collisionAlert = nil; continuation.resume(returning: response) }
            DispatchQueue.main.async { [weak self] in self?.onCollisionShown?(alert) }
        }
    }
    private func chooseAnother(_ artifact: ImageExportArtifact, current: URL) async -> URL? {
        guard state != .closed, let window else { return nil }
        let panel = NSSavePanel(); panel.title = "保存新副本"; panel.prompt = "保存新副本"
        panel.message = "已有文件不会被替换；冲突时将重新询问。"; panel.allowedContentTypes = [artifact.options.format.contentType]
        panel.directoryURL = current.deletingLastPathComponent(); panel.nameFieldStringValue = current.lastPathComponent; savePanel = panel
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { [weak self] response in self?.savePanel = nil; continuation.resume(returning: response == .OK ? panel.url : nil) }
            DispatchQueue.main.async { [weak self] in self?.onSavePanelShown?(panel) }
        }
    }
    private func showResult() {
        guard let result else { return }; state = .completed; spinner.stopAnimation(nil); closeButton.title = "完成"
        let tail: String
        switch result.clipboardOutcome {
        case .copied: tail = "已复制同一份编码文件内容"
        case .failed: tail = "复制失败，已保存的文件仍然保留，可重试复制"
        case .cancelledAfterSave: tail = "文件已完成保存；关闭操作取消了后续复制"
        case .notRequested: tail = "文件已安全保存"
        }
        statusLabel.toolTip = result.savedURL.path
        statusLabel.stringValue = result.savedURL.path + "\n" + tail; retryCopyButton.isHidden = result.clipboardOutcome != .failed
    }
    @objc private func retryCopy() {
        guard let savedForCopy, state == .completed else { return }
        let outcome = SaveWorkflowService.copySaved(savedForCopy, copier: copier)
        result = SaveWorkflowSummary(outcome); self.savedForCopy = outcome.clipboardOutcome == .failed ? outcome : nil; showResult()
    }
    func attach(to parent: NSWindow?) {
        detachFromParent(); guard let parent, let window else { return }
        parentWindow = parent; parent.addChildWindow(window, ordered: .above)
        var effectiveLevel = parent.level.rawValue, ancestor: NSWindow? = parent
        for _ in 0..<8 {
            guard let next = ancestor?.sheetParent ?? ancestor?.parent else { break }
            effectiveLevel = max(effectiveLevel, next.level.rawValue); ancestor = next
        }
        window.level = NSWindow.Level(rawValue: effectiveLevel < Int.max ? effectiveLevel + 1 : effectiveLevel)
        parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detachFromParent() }
        }
    }
    private func detachFromParent() {
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }; parentObserver = nil
        if let window { parentWindow?.removeChildWindow(window); window.level = .normal }; parentWindow = nil
    }
    func revealForDecision() { guard state != .closed else { return }; showWindow(nil); window?.center(); window?.makeKeyAndOrderFront(nil) }
    private func cancelPanels() {
        folderPanel?.cancel(nil); savePanel?.cancel(nil)
        if let alert = collisionAlert, let window { window.endSheet(alert.window, returnCode: .alertThirdButtonReturn) }
    }
    @objc func cancel() {
        guard state != .closed else { return }; token.cancel(); task?.cancel(); deadline?.cancel(); deadline = nil
        input?.clear(); saveInput?.clear(); snapshot = nil; artifact = nil; savedForCopy = nil; callback = nil
        cancelPanels(); detachFromParent(); state = .closed; window?.delegate = nil; window?.close()
        if task == nil { jobDrained = true; let drained = onDrained; onDrained = nil; drained?() }
        let completion = onClose; onClose = nil; completion?()
    }
    func windowWillClose(_ notification: Notification) { cancel() }
}
