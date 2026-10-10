import AppKit

/// Owns only a value draft. The enclosing Settings Save writes it; Cancel,
/// window close and import cancellation never commit the draft or captured key.
@MainActor final class LocalAnnotationShortcutSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var draft: LocalAnnotationShortcutSettings
    let tableView = NSTableView()
    let captureButton = LocalAnnotationShortcutCaptureButton()
    let clearButton = SettingsActionButton(title: "清除此键", target: nil, action: nil)
    let restoreDefaultsButton = SettingsActionButton(title: "恢复默认", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    var onChange: (() -> Void)?
    var selectedTool: ImageEditorTool? {
        ImageEditorTool.allCases.indices.contains(tableView.selectedRow) ? ImageEditorTool.allCases[tableView.selectedRow] : nil
    }
    init(settings: LocalAnnotationShortcutSettings) {
        draft = settings; super.init(frame: .zero)
        identifier = .init("localShortcuts.settings")
        let tool = NSTableColumn(identifier: .init("tool")); tool.title = "标注工具"; tool.width = 200
        let key = NSTableColumn(identifier: .init("binding")); key.title = "本地快捷键"; key.width = 130
        tableView.addTableColumn(tool); tableView.addTableColumn(key)
        tableView.rowHeight = 24; tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true; tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false; tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self; tableView.delegate = self
        tableView.identifier = .init("localShortcuts.tools"); tableView.setAccessibilityLabel("标注工具本地快捷键")
        let scroll = NSScrollView(); scroll.documentView = tableView; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 182).isActive = true
        captureButton.identifier = .init("localShortcuts.capture")
        captureButton.widthAnchor.constraint(equalToConstant: 170).isActive = true
        captureButton.onCapture = { [weak self] binding in
            guard let self, let tool = self.selectedTool else { return }
            self.draft = try self.draft.replacing(tool, with: binding)
            self.reloadTools(preserving: tool)
            self.showStatus("已设置 \(tool.title)：\(binding.displayName)；保存设置后，下次打开编辑器生效。", error: false)
            self.onChange?()
        }
        captureButton.onStatus = { [weak self] text, error in self?.showStatus(text, error: error) }
        clearButton.target = self; clearButton.action = #selector(clearSelected)
        restoreDefaultsButton.target = self; restoreDefaultsButton.action = #selector(restoreDefaults)
        for (button, id) in [(clearButton, "clear"), (restoreDefaultsButton, "restoreDefaults")] {
            button.bezelStyle = .rounded; button.identifier = .init("localShortcuts." + id); button.setAccessibilityLabel(button.title)
        }
        let controls = NSStackView(views: [captureButton, clearButton, restoreDefaultsButton]); controls.spacing = 8
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.identifier = .init("localShortcuts.status")
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        let help = NSTextField(wrappingLabelWithString: "仅在编辑器画布获得焦点时生效，输入文字时不切换工具。使用字母或数字键，可加 Shift；按物理键位识别，标签采用美式键盘。A 与画布操作键保留；原有序号备注操作优先。默认均未设置，保存后下次打开编辑器生效。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [scroll, controls, statusLabel, help]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        reloadTools(preserving: .select)
        showStatus("选择工具后点击“设置快捷键”；Esc 取消录入，Delete 清除当前绑定。", error: false)
        captureButton.onClear = { [weak self] in self?.clearSelected() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(settings: LocalAnnotationShortcutSettings) {
        let tool = selectedTool ?? .select
        cancelRecording(); draft = settings; reloadTools(preserving: tool)
        showStatus("更改在保存设置后，下次打开编辑器生效。", error: false)
    }
    func cancelRecording() { captureButton.cancelRecording() }
    func selectTool(_ tool: ImageEditorTool) {
        guard let row = ImageEditorTool.allCases.firstIndex(of: tool) else { return }
        cancelRecording(); tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row); refreshControls()
    }
    /// With nonempty selection required, a native reload may select the first
    /// row. Restore semantic tool identity before refreshing controls/callbacks,
    /// so the next recorder or Clear action still addresses the chosen tool.
    private func reloadTools(preserving tool: ImageEditorTool) {
        tableView.reloadData(); selectTool(tool)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { ImageEditorTool.allCases.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard ImageEditorTool.allCases.indices.contains(row) else { return nil }
        let tool = ImageEditorTool.allCases[row]
        let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "binding" ? (draft[tool]?.displayName ?? "未设置") : tool.title)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        label.identifier = .init("localShortcuts.\(tool.rawValue).\(tableColumn?.identifier.rawValue ?? "tool")")
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { cancelRecording(); refreshControls() }
    private func refreshControls() {
        let binding = selectedTool.flatMap { draft[$0] }
        captureButton.isEnabled = selectedTool != nil
        captureButton.setBinding(binding)
        captureButton.setAccessibilityLabel((selectedTool?.title ?? "标注工具") + "本地快捷键")
        clearButton.isEnabled = binding != nil
        restoreDefaultsButton.isEnabled = draft != .defaults
    }
    private func showStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text; statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        statusLabel.setAccessibilityLabel(text)
    }
    @objc private func clearSelected() {
        cancelRecording()
        guard let tool = selectedTool, draft[tool] != nil, let next = try? draft.replacing(tool, with: nil) else { return }
        draft = next; reloadTools(preserving: tool)
        showStatus("已清除 \(tool.title) 的草稿绑定；点击保存设置后生效。", error: false); onChange?()
    }
    @objc private func restoreDefaults() {
        guard draft != .defaults else { return }
        apply(settings: .defaults); showStatus("草稿已恢复默认（均未设置）；取消设置可保留原配置。", error: false); onChange?()
    }
}

/// First-responder recording only. The Settings window gives this button first
/// refusal for Return/Escape and menu chords while recording, so they cannot
/// accidentally save/close the window. Rejected chords leave the prior draft intact.
@MainActor final class LocalAnnotationShortcutCaptureButton: NSButton {
    private(set) var binding: LocalAnnotationShortcutBinding?
    private(set) var isRecording = false
    var onCapture: ((LocalAnnotationShortcutBinding) throws -> Void)?
    var onClear: (() -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    init() {
        super.init(frame: .zero); bezelStyle = .rounded; target = self; action = #selector(beginRecording); refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self); cancelRecording()
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(recordingWindowUnavailable(_:)), name: name, object: window)
        }
    }
    @objc private func recordingWindowUnavailable(_ note: Notification) {
        guard isRecording else { return }
        cancelRecording(); onStatus?("录入已取消；原有绑定未更改。", false)
    }
    override var acceptsFirstResponder: Bool { true }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }
    override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }
    func setBinding(_ value: LocalAnnotationShortcutBinding?) { binding = value; cancelRecording() }
    func cancelRecording() { isRecording = false; refreshTitle() }
    @objc private func beginRecording() {
        guard window?.isKeyWindow == true, window?.attachedSheet == nil, window?.makeFirstResponder(self) == true else { return }
        isRecording = true; refreshTitle()
        onStatus?("请按字母或数字键，可加 Shift；Esc 取消，Delete 清除。", false)
    }
    override func resignFirstResponder() -> Bool { cancelRecording(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording, let window, window.isKeyWindow, window.attachedSheet == nil,
              window.firstResponder === self, event.windowNumber == window.windowNumber else { super.keyDown(with: event); return }
        guard event.type == .keyDown, !event.isARepeat else { return }
        if event.keyCode == 53 { cancelRecording(); onStatus?("已取消录入；原有绑定未更改。", false); return }
        if [UInt16(51), 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            cancelRecording(); onClear?(); return
        }
        do {
            let value = try LocalAnnotationShortcutBinding.capture(event)
            try onCapture?(value); binding = value; cancelRecording()
        } catch { onStatus?(error.localizedDescription, true) }
    }
    private func refreshTitle() { title = isRecording ? "按键…（Esc 取消）" : (binding.map { "更改 " + $0.displayName } ?? "设置快捷键") }
}
