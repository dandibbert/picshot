import AppKit
import UniformTypeIdentifiers

/// Small non-modal recovery panel; no thumbnail/full desktop/image duplicate.
/// Close/Escape only hide it. The menu and any new capture bring it back.
@MainActor final class PendingCaptureController: NSWindowController {
    let recovery: PendingCaptureRecovery
    var onRetry: ((PendingCapture) -> Bool)?
    var onResolved: (() -> Void)?
    var chooseDestination: ((NSWindow, @escaping (URL?) -> Void) -> Void)?
    var confirmDiscard: (() -> Bool)?
    var write: @Sendable (PendingCapture, URL, ImageExportCancellation) async throws -> URL = { capture, url, cancellation in
        try await Task.detached(priority: .userInitiated) {
            try PendingCaptureFileWriter.write(capture, to: url, cancellation: cancellation)
        }.value
    }
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "重试编辑", target: nil, action: nil)
    private let save = NSButton(title: "保存 PNG…", target: nil, action: nil)
    private let discard = NSButton(title: "放弃截图…", target: nil, action: nil)
    private let cancel = NSButton(title: "稍后", target: nil, action: nil)
    private var saveTask: Task<Void, Never>?
    private var cancellation: ImageExportCancellation?
    private var savePanel: NSSavePanel?
    private var choosingDestination = false

    init(recovery: PendingCaptureRecovery) {
        self.recovery = recovery
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 510, height: 220),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "PicShot · 未保存的截图"; panel.isReleasedWhenClosed = false; panel.center()
        details.font = .systemFont(ofSize: 12); details.maximumNumberOfLines = 3
        details.identifier = NSUserInterfaceItemIdentifier("pending-capture-details")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 4; status.identifier = NSUserInterfaceItemIdentifier("pending-capture-status")
        for (button, action, name) in [(retry, #selector(retryAction), "retry"), (save, #selector(saveAction), "save"),
                                      (discard, #selector(discardAction), "discard"), (cancel, #selector(cancelAction), "cancel")] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier("pending-capture-" + name)
        }
        cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [discard, NSView(), cancel, save, retry]); actions.spacing = 8
        let stack = NSStackView(views: [details, status, NSView(), actions]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 12
        let container = NSView(); container.addSubview(stack); panel.contentView = container
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        recovery.didChange = { [weak self] in self?.refresh() }; refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        refresh(); super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
    }
    private func refresh() {
        if let capture = recovery.pending {
            let mib = String(format: "%.2f", Double(capture.retainedBytes) / 1_048_576)
            details.stringValue = "原始截图已保留：\(capture.image.width) × \(capture.image.height) · \(mib) MiB\n\(capture.capturedAt.formatted())\n单张待处理上限 640 MiB；编辑窗口另有 768 MiB 准入预算。"
        }
        status.stringValue = recovery.message
        let enabled = recovery.pending != nil && !recovery.isSaving && !choosingDestination
        retry.isEnabled = enabled; save.isEnabled = enabled; discard.isEnabled = enabled
        cancel.title = recovery.isSaving ? "取消保存" : "稍后"
    }
    @objc private func retryAction() {
        guard !choosingDestination else { return }
        if recovery.retryEditor({ self.onRetry?($0) ?? false }) { resolved() }
    }
    @objc private func saveAction() {
        guard !choosingDestination, !recovery.isSaving, recovery.pending != nil, let window else { return }
        choosingDestination = true; refresh()
        let picked: (URL?) -> Void = { [weak self] url in
            guard let self else { return }
            self.choosingDestination = false; self.savePanel = nil; self.refresh()
            guard let url else { self.recovery.savePickerCancelled(); return }
            self.save(to: url)
        }
        if let chooseDestination { chooseDestination(window, picked); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.canCreateDirectories = true
        panel.title = "保存未完成的截图"; panel.prompt = "保存新文件"; panel.nameFieldStringValue = "PicShot-recovered.png"
        savePanel = panel
        panel.beginSheetModal(for: window) { response in picked(response == .OK ? panel.url : nil) }
    }
    private func save(to url: URL) {
        guard let capture = recovery.beginSave() else { return }
        let cancellation = ImageExportCancellation(); self.cancellation = cancellation
        let write = self.write
        saveTask = Task { [self] in
            let result: Result<URL, Error>
            do { result = .success(try await write(capture, url, cancellation)) }
            catch { result = .failure(error) }
            self.cancellation = nil; self.saveTask = nil
            recovery.finishSave(id: capture.id, result: result)
            if recovery.pending == nil { resolved() }
        }
    }
    @objc private func discardAction() {
        guard !choosingDestination, !recovery.isSaving, recovery.pending != nil else { return }
        let confirmed: Bool
        if let confirmDiscard { confirmed = confirmDiscard() }
        else {
            let alert = NSAlert(); alert.messageText = "放弃这张未保存的截图？"
            alert.informativeText = "原始截图将从内存移除，无法恢复。"; alert.addButton(withTitle: "保留截图"); alert.addButton(withTitle: "放弃截图")
            confirmed = alert.runModal() == .alertSecondButtonReturn
        }
        if confirmed && recovery.discard() { resolved() }
    }
    @objc private func cancelAction() {
        if recovery.isSaving { cancellation?.cancel() }
        else if choosingDestination { savePanel?.cancel(nil) }
        else { window?.orderOut(nil) }
    }
    private func resolved() { close(); onResolved?() }
}
