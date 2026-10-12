import AppKit
import Combine
import PicShotCore

/// A metadata draft and a value-only receipt surface. The application owns all
/// capture/output work; this controller never receives or retains a raster.
@MainActor final class CaptureChainController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    var onRun: ((UUID, UInt64) -> Void)?
    var onRetry: ((UUID, UInt64) -> Void)?
    var onCancel: ((UUID, UInt64) -> Void)?
    var onClose: ((UUID?, UInt64) -> Void)?

    private(set) var commandGeneration: UInt64 = 0
    private(set) var displayedSnapshot: CaptureChainSnapshot?
    private let store: CaptureChainStore
    private var subscription: AnyCancellable?
    private var presets: [CapturePreset]
    private var draftID: UUID?
    private var draftSource: CaptureChainSource = .region
    private var draftOutputs: [CaptureChainOutput] = [.quickSavePNG]
    private var selectionUpdate = false
    private var pendingCommand = false
    private var wantsVisible = false
    private var closeRequested = false
    private var cancellationRequestedFor: UUID?
    private var showingProgress = false
    private let managerContent = NSStackView()
    private let progressContent = NSStackView()

    private let table = NSTableView()
    private let nameField = NSTextField(string: "")
    private let sourcePicker = NSPopUpButton()
    private let outputs = NSStackView()
    private let currentLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let runStatus = NSTextField(wrappingLabelWithString: "尚未运行")
    private let receipts = NSStackView()
    private let createButton = NSButton(title: "新建", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存更改", target: nil, action: nil)
    private let discardButton = NSButton(title: "取消更改", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let selectButton = NSButton(title: "设为当前截图链", target: nil, action: nil)
    private let runButton = CaptureChainRunButton(title: "运行", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试未完成操作", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消运行", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let manageButton = NSButton(title: "返回管理", target: nil, action: nil)
    private let resultButton = NSButton(title: "查看结果", target: nil, action: nil)

    init(store: CaptureChainStore, presets: [CapturePreset] = []) {
        self.store = store; self.presets = presets
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "截图链"; panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 600, height: 600); panel.center(); panel.delegate = self
        buildInterface(in: panel)
        reloadCatalog()
        subscription = store.$index.dropFirst().sink { [weak self] _ in
            // Invalidate at publication, before a queued action could read a
            // changed selection. @Published sends before replacing the value.
            self?.invalidateCommands()
            DispatchQueue.main.async { [weak self] in self?.reloadCatalog() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() { showWindow(nil) }
    override func showWindow(_ sender: Any?) {
        wantsVisible = true; closeRequested = false
        reloadCatalog()
        if displayedSnapshot?.status == .capturing { return }
        super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
    }

    func setPresets(_ presets: [CapturePreset]) {
        self.presets = presets; rebuildSources(); refreshControls()
    }
    func hideForCapture() { window?.orderOut(nil) }
    func isCurrentCommand(_ generation: UInt64) -> Bool { generation == commandGeneration }
    func invalidateCommands() {
        commandGeneration &+= 1; pendingCommand = false; refreshControls()
    }

    func update(snapshot: CaptureChainSnapshot) {
        let old = displayedSnapshot
        displayedSnapshot = snapshot
        if old?.runID != snapshot.runID || snapshot.status.isTerminal { cancellationRequestedFor = nil }
        if old?.runID != snapshot.runID || !snapshot.status.isTerminal { setShowingProgress(true) }
        // An old queued Run/Retry/Close must not become a command for the next
        // run, or arrive after a terminal session has reopened admission.
        if old?.runID != snapshot.runID || old?.status.isTerminal != snapshot.status.isTerminal ||
            old?.status.canRetry != snapshot.status.canRetry {
            invalidateCommands()
        } else { pendingCommand = false }
        renderProgress(); refreshControls()
        if snapshot.status == .capturing { hideForCapture() }
        else if wantsVisible && window?.isVisible == false { window?.makeKeyAndOrderFront(nil) }
    }

    func showGuidance(_ message: String) {
        if !hasActiveRun { setShowingProgress(false) }
        invalidateCommands(); status.stringValue = message; status.toolTip = message
        status.textColor = .secondaryLabelColor
        present()
    }
    func showError(_ error: Error) {
        if !hasActiveRun { setShowingProgress(false) }
        let message: String
        if let error = error as? CaptureChainError { message = error.errorDescription ?? "操作未完成，请重试。" }
        else if let error = error as? CapturePresetError { message = error.errorDescription ?? "操作未完成，请重试。" }
        else if let error = error as? CaptureError { message = error.errorDescription ?? "操作未完成，请重试。" }
        else if let error = error as? DisplayCompositeError { message = error.errorDescription ?? "操作未完成，请重试。" }
        else { message = "操作未完成，请重试。" }
        invalidateCommands(); status.stringValue = message; status.toolTip = message; status.textColor = .systemRed
        if wantsVisible { window?.makeKeyAndOrderFront(nil) }
    }

    private var savedDraft: CaptureChainDefinition? { draftID.flatMap { store.definition(id: $0) } }
    private var hasDraft: Bool { draftID != nil }
    private var hasUnsavedDraft: Bool {
        guard hasDraft else { return false }
        guard let savedDraft else { return true }
        return nameField.stringValue != savedDraft.name || draftSource != savedDraft.source || draftOutputs != savedDraft.outputs
    }
    private var hasActiveRun: Bool { displayedSnapshot.map { !$0.status.isTerminal } ?? false }
    private var canEdit: Bool { !hasActiveRun && !pendingCommand }
    private var sourceAvailable: Bool {
        if case .preset(let id) = draftSource { return presets.contains { $0.id == id } }
        return true
    }

    private func buildInterface(in panel: NSWindow) {
        let guidance = label("一次截图，按顺序执行 1–3 个操作；仅在本机保存定义。", id: "guidance")
        guidance.maximumNumberOfLines = 1
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("capture-chains"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 36; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(runFromTable)
        table.identifier = NSUserInterfaceItemIdentifier("capture-chain-list")
        table.setAccessibilityLabel("已保存的截图链，双击运行已保存的定义")
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder

        nameField.identifier = NSUserInterfaceItemIdentifier("capture-chain-name")
        nameField.placeholderString = "截图链名称，最多 64 个字符"; nameField.delegate = self
        nameField.setAccessibilityLabel("截图链名称")
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourcePicker.identifier = NSUserInterfaceItemIdentifier("capture-chain-source")
        sourcePicker.setAccessibilityLabel("截图来源")
        sourcePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sourcePicker.target = self; sourcePicker.action = #selector(sourceChanged)
        sourcePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let nameRow = row([NSTextField(labelWithString: "名称"), nameField])
        let sourceRow = row([NSTextField(labelWithString: "来源"), sourcePicker])
        outputs.orientation = .vertical; outputs.alignment = .leading; outputs.spacing = 4
        outputs.identifier = NSUserInterfaceItemIdentifier("capture-chain-outputs")

        configure(createButton, "create", #selector(createDraft))
        configure(saveButton, "save", #selector(saveDraft))
        configure(discardButton, "discard", #selector(discardDraft))
        configure(deleteButton, "delete", #selector(deleteDraft))
        configure(selectButton, "select", #selector(selectCurrent))
        configure(runButton, "run", #selector(runFromButton))
        configure(retryButton, "retry", #selector(retryRun))
        configure(cancelButton, "cancel", #selector(cancelRun))
        configure(closeButton, "close", #selector(closeAction)); closeButton.keyEquivalent = "\u{1b}"
        configure(manageButton, "manage", #selector(showManager))
        configure(resultButton, "result", #selector(showResult))
        let editing = row([createButton, saveButton, discardButton, NSView(), deleteButton])
        currentLabel.font = .systemFont(ofSize: 11); currentLabel.textColor = .secondaryLabelColor
        currentLabel.lineBreakMode = .byTruncatingTail
        currentLabel.identifier = NSUserInterfaceItemIdentifier("capture-chain-current")
        currentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let current = row([currentLabel, selectButton])
        style(status, id: "status"); status.maximumNumberOfLines = 2
        style(runStatus, id: "run-status"); runStatus.maximumNumberOfLines = 2
        runStatus.font = .systemFont(ofSize: 12, weight: .medium)
        receipts.orientation = .vertical; receipts.alignment = .leading; receipts.spacing = 4
        receipts.identifier = NSUserInterfaceItemIdentifier("capture-chain-receipts")
        for view in [guidance, scroll, current, nameRow, sourceRow, outputs, editing, status] {
            managerContent.addArrangedSubview(view)
        }
        // Cross-row constraints require the controls to share an installed
        // ancestor. The same width relationship is valid once both rows belong
        // to managerContent; activating it earlier raises NSGenericException.
        nameField.widthAnchor.constraint(equalTo: sourcePicker.widthAnchor).isActive = true
        for view in [runStatus, receipts] { progressContent.addArrangedSubview(view) }
        for stack in [managerContent, progressContent] {
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
            for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        progressContent.isHidden = true
        let actions = row([closeButton, manageButton, resultButton, NSView(), retryButton, cancelButton, runButton])
        let root = NSStackView(views: [managerContent, progressContent, NSView(), actions])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        let container = NSView(); container.addSubview(root); panel.contentView = container
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        status.stringValue = "选择已有截图链，或点“新建”。当前截图链仅用于快捷键，不会自动运行。"
        rebuildSources(); rebuildOutputs(); renderProgress()
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 12; return row
    }
    private func configure(_ button: NSButton, _ id: String, _ action: Selector) {
        button.target = self; button.action = action; button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier("capture-chain-" + id)
    }
    private func style(_ field: NSTextField, id: String) {
        field.identifier = NSUserInterfaceItemIdentifier("capture-chain-" + id)
        field.textColor = .secondaryLabelColor; field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
    }
    private func label(_ text: String, id: String) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text); style(result, id: id); return result
    }

    private func reloadCatalog() {
        selectionUpdate = true; table.reloadData()
        if let draftID, let index = store.definitions.firstIndex(where: { $0.id == draftID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        selectionUpdate = false
        let name = store.selectedID.flatMap { store.definition(id: $0)?.name }
        currentLabel.stringValue = name.map { "当前：" + $0 } ?? "当前：未选择"
        currentLabel.toolTip = currentLabel.stringValue; currentLabel.setAccessibilityLabel(currentLabel.stringValue)
        rebuildSources(); refreshControls()
    }
    private func loadDraft(_ definition: CaptureChainDefinition?) {
        draftID = definition?.id; nameField.stringValue = definition?.name ?? ""
        draftSource = definition?.source ?? .region; draftOutputs = definition?.outputs ?? [.quickSavePNG]
        nameField.toolTip = definition?.name
        rebuildSources(); rebuildOutputs(); refreshControls()
    }
    private func rebuildSources() {
        sourcePicker.removeAllItems(); sourcePicker.addItem(withTitle: "框选区域")
        sourcePicker.lastItem?.representedObject = "region"
        for preset in presets {
            sourcePicker.addItem(withTitle: "预设：" + preset.name)
            sourcePicker.lastItem?.representedObject = preset.id; sourcePicker.lastItem?.toolTip = preset.name
        }
        if case .preset(let id) = draftSource {
            if let item = sourcePicker.itemArray.first(where: { ($0.representedObject as? UUID) == id }) {
                sourcePicker.select(item)
            } else {
                sourcePicker.addItem(withTitle: "预设已删除或不可用")
                sourcePicker.lastItem?.representedObject = id; sourcePicker.select(sourcePicker.lastItem)
            }
        } else { sourcePicker.selectItem(at: 0) }
        sourcePicker.toolTip = sourcePicker.titleOfSelectedItem
    }
    private func rebuildOutputs() {
        for view in outputs.arrangedSubviews { outputs.removeArrangedSubview(view); view.removeFromSuperview() }
        let order = draftOutputs + CaptureChainOutput.allCases.filter { !draftOutputs.contains($0) }
        for output in order {
            let index = draftOutputs.firstIndex(of: output)
            let title = index.map { "\($0 + 1). " + output.title } ?? output.title
            let check = NSButton(checkboxWithTitle: title, target: self, action: #selector(outputChanged(_:)))
            check.identifier = NSUserInterfaceItemIdentifier("capture-chain-output-" + output.rawValue)
            check.tag = CaptureChainOutput.allCases.firstIndex(of: output)!
            check.state = index == nil ? .off : .on; check.isEnabled = canEdit && hasDraft
            check.setAccessibilityLabel(output.title)
            let up = NSButton(title: "上移", target: self, action: #selector(moveOutputUp(_:)))
            let down = NSButton(title: "下移", target: self, action: #selector(moveOutputDown(_:)))
            for (button, suffix) in [(up, "up"), (down, "down")] {
                button.tag = check.tag; button.bezelStyle = .rounded
                button.controlSize = .small; button.font = .systemFont(ofSize: 11)
                button.identifier = NSUserInterfaceItemIdentifier("capture-chain-" + suffix + "-" + output.rawValue)
                button.setAccessibilityLabel(output.title + button.title)
            }
            up.isEnabled = canEdit && (index.map { $0 > 0 } ?? false)
            down.isEnabled = canEdit && (index.map { $0 + 1 < draftOutputs.count } ?? false)
            let line = row([check, NSView(), up, down]); outputs.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: outputs.widthAnchor).isActive = true
        }
    }
    private func refreshControls() {
        let clean = savedDraft != nil && !hasUnsavedDraft
        nameField.isEnabled = canEdit && hasDraft; sourcePicker.isEnabled = canEdit && hasDraft
        createButton.isEnabled = canEdit && !hasUnsavedDraft && store.definitions.count < CaptureChainIndex.maximumDefinitions
        saveButton.isEnabled = canEdit && hasUnsavedDraft
        discardButton.isEnabled = canEdit && hasUnsavedDraft
        deleteButton.isEnabled = canEdit && clean
        selectButton.isEnabled = canEdit && clean && store.selectedID != draftID
        runButton.isEnabled = canEdit && clean && sourceAvailable
        retryButton.isEnabled = displayedSnapshot?.status.canRetry == true && !pendingCommand
        cancelButton.isEnabled = hasActiveRun && displayedSnapshot?.status != .cancelling && !pendingCommand &&
            displayedSnapshot?.runID != cancellationRequestedFor
        retryButton.isHidden = displayedSnapshot?.status.canRetry != true
        cancelButton.isHidden = !hasActiveRun
        manageButton.isHidden = !showingProgress; manageButton.isEnabled = !hasActiveRun && !pendingCommand
        resultButton.isHidden = showingProgress || displayedSnapshot == nil
        rebuildOutputs()
    }
    private func setShowingProgress(_ value: Bool) {
        guard showingProgress != value else { return }
        showingProgress = value; managerContent.isHidden = value; progressContent.isHidden = !value
        let height: CGFloat = value ? 270 : 600
        window?.contentMinSize = NSSize(width: 600, height: height)
        window?.setContentSize(NSSize(width: max(600, window?.contentView?.bounds.width ?? 620), height: height))
        refreshControls()
    }
    @objc private func showManager() {
        guard !hasActiveRun && !pendingCommand else { return }
        invalidateCommands(); setShowingProgress(false)
    }
    @objc private func showResult() {
        guard displayedSnapshot != nil, !pendingCommand else { return }
        invalidateCommands(); setShowingProgress(true)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.definitions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.definitions.indices.contains(row) else { return nil }
        let definition = store.definitions[row]
        let text = definition.name + "\n" + definition.outputs.map(\.title).joined(separator: " → ")
        let result = NSTextField(labelWithString: text)
        result.maximumNumberOfLines = 2; result.lineBreakMode = .byTruncatingTail
        result.font = .systemFont(ofSize: 12); result.toolTip = text; result.setAccessibilityLabel(text)
        return result
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard canEdit else { return false }
        if hasUnsavedDraft {
            status.stringValue = "请先保存或取消当前更改，再选择其他截图链。"; return false
        }
        return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectionUpdate else { return }
        guard canEdit && !hasUnsavedDraft else { reloadCatalog(); return }
        let row = table.selectedRow
        invalidateCommands(); loadDraft(store.definitions.indices.contains(row) ? store.definitions[row] : nil)
        status.textColor = .secondaryLabelColor
        if !sourceAvailable { status.stringValue = "此截图链引用的预设已删除或不可用。请选择其他预设并保存。" }
        else { status.stringValue = "可编辑名称、来源和操作顺序。更改只在点击“保存更改”后保存。" }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard canEdit else { return }
        invalidateCommands(); nameField.toolTip = nameField.stringValue; refreshControls()
    }
    @objc private func sourceChanged() {
        guard canEdit && hasDraft else { return }
        draftSource = (sourcePicker.selectedItem?.representedObject as? UUID).map(CaptureChainSource.preset) ?? .region
        invalidateCommands(); sourcePicker.toolTip = sourcePicker.titleOfSelectedItem
    }
    @objc private func outputChanged(_ sender: NSButton) {
        guard canEdit && hasDraft, CaptureChainOutput.allCases.indices.contains(sender.tag) else { return }
        let output = CaptureChainOutput.allCases[sender.tag]
        if sender.state == .on { if !draftOutputs.contains(output) { draftOutputs.append(output) } }
        else { draftOutputs.removeAll { $0 == output } }
        invalidateCommands()
    }
    @objc private func moveOutputUp(_ sender: NSButton) { moveOutput(sender, by: -1) }
    @objc private func moveOutputDown(_ sender: NSButton) { moveOutput(sender, by: 1) }
    private func moveOutput(_ sender: NSButton, by offset: Int) {
        guard canEdit && hasDraft, CaptureChainOutput.allCases.indices.contains(sender.tag),
              let index = draftOutputs.firstIndex(of: CaptureChainOutput.allCases[sender.tag]),
              draftOutputs.indices.contains(index + offset) else { return }
        draftOutputs.swapAt(index, index + offset); invalidateCommands()
    }
    @objc private func createDraft() {
        guard canEdit && !hasUnsavedDraft, store.definitions.count < CaptureChainIndex.maximumDefinitions else { return }
        invalidateCommands(); loadDraft(nil); draftID = UUID(); nameField.stringValue = "新截图链"
        selectionUpdate = true; table.deselectAll(nil); selectionUpdate = false
        refreshControls(); window?.makeFirstResponder(nameField)
        status.stringValue = "新截图链尚未保存。选择来源和 1–3 个操作，然后点击“保存更改”。"
    }
    @objc private func saveDraft() {
        guard canEdit, let id = draftID, hasUnsavedDraft else { return }
        do {
            let definition = try CaptureChainDefinition(id: id, name: nameField.stringValue,
                source: draftSource, outputs: draftOutputs)
            if savedDraft == nil { try store.add(definition) } else { try store.update(definition) }
            invalidateCommands(); loadDraft(definition); reloadCatalog()
            status.textColor = .secondaryLabelColor; status.stringValue = "已保存截图链。点击“运行”，或将它设为当前截图链供快捷键使用。"
        } catch { showError(error) }
    }
    @objc private func discardDraft() {
        guard canEdit && hasUnsavedDraft else { return }
        let saved = savedDraft; invalidateCommands(); loadDraft(saved); reloadCatalog()
        status.textColor = .secondaryLabelColor; status.stringValue = "已取消未保存的更改。"
    }
    @objc private func deleteDraft() {
        guard canEdit && !hasUnsavedDraft, let id = savedDraft?.id else { return }
        do {
            try store.remove(id: id); invalidateCommands(); loadDraft(nil); reloadCatalog()
            status.textColor = .secondaryLabelColor; status.stringValue = "已删除截图链。已完成的文件、剪贴板和贴图不会被删除。"
        } catch { showError(error) }
    }
    @objc private func selectCurrent() {
        guard canEdit && !hasUnsavedDraft, let id = savedDraft?.id else { return }
        do { try store.select(id: id); invalidateCommands(); reloadCatalog() }
        catch { showError(error) }
    }

    @objc private func runFromButton() { requestRun() }
    @objc private func runFromTable() { requestRun() }
    private func requestRun() {
        guard canEdit && !hasUnsavedDraft && sourceAvailable, let id = savedDraft?.id, onRun != nil else { return }
        enqueue { [weak self] generation in self?.onRun?(id, generation) }
    }
    @objc private func retryRun() {
        guard let snapshot = displayedSnapshot, snapshot.status.canRetry, !pendingCommand, onRetry != nil else { return }
        enqueue { [weak self] generation in self?.onRetry?(snapshot.runID, generation) }
    }
    @objc private func cancelRun() {
        guard let snapshot = displayedSnapshot, !snapshot.status.isTerminal,
              snapshot.status != .cancelling, !pendingCommand, cancellationRequestedFor != snapshot.runID,
              let onCancel else { return }
        // Reserve and send cancellation synchronously. Ordinary output progress
        // cannot erase the request before the owner receives it.
        cancellationRequestedFor = snapshot.runID; pendingCommand = true; refreshControls()
        onCancel(snapshot.runID, commandGeneration)
    }
    private func enqueue(_ action: @escaping (UInt64) -> Void) {
        let generation = commandGeneration; pendingCommand = true; refreshControls()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentCommand(generation), self.pendingCommand else { return }
            action(generation)
        }
    }
    @objc private func closeAction() { window?.performClose(nil) }
    func windowWillClose(_ notification: Notification) {
        wantsVisible = false
        guard !closeRequested else { return }
        closeRequested = true
        invalidateCommands()
        let runID = displayedSnapshot?.runID
        // The application may release its last controller reference as soon as
        // this window closes. Deliver its identity-bearing cancellation while
        // the controller is still alive, never through a weak queued callback.
        onClose?(runID, commandGeneration)
    }

    private func renderProgress() {
        for view in receipts.arrangedSubviews { receipts.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let snapshot = displayedSnapshot else {
            runStatus.stringValue = "尚未运行"; addReceiptLabel("每次只截取一次；重试只继续尚未完成的操作。", index: 0); return
        }
        let heading: String
        switch snapshot.status {
        case .idle: heading = "准备运行"
        case .capturing: heading = "正在截图…"
        case .running(let index): heading = "正在执行第 \(index + 1) 个操作…"
        case .failed(_, let message): heading = "操作未完成：" + message
        case .captureFailed(let message): heading = "截图未完成：" + message + " 请重新运行。"
        case .cancelling: heading = "正在取消，等待当前操作结束…"
        case .completed: heading = "全部完成"
        case .cancelled: heading = snapshot.receipts.isEmpty ? "已取消" : "已取消后续操作；以下已完成结果仍然保留"
        }
        runStatus.stringValue = snapshot.definition.name + " · " + heading
        runStatus.toolTip = runStatus.stringValue; runStatus.setAccessibilityLabel(runStatus.stringValue)
        runStatus.textColor = snapshot.status.canRetry ? .systemRed : .labelColor
        for (index, output) in snapshot.definition.outputs.enumerated() {
            let detail: String
            if let receipt = snapshot.receipts.first(where: { $0.output == output }) {
                switch receipt.value {
                case .saved(let url, let count):
                    detail = "已保存：\(url.path)（\(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file))）"
                case .copied: detail = "已复制到剪贴板"
                case .pinned(let id): detail = "已持久保存贴图 · " + id.uuidString
                }
            } else {
                switch snapshot.status {
                case .running(let active) where active == index: detail = "正在执行…"
                case .failed(let failed, _) where failed == index: detail = "失败，可重试；前面已完成的操作不会重复"
                case .cancelled: detail = "未执行"
                case .captureFailed: detail = "未执行，截图未完成"
                default: detail = "等待执行"
                }
            }
            addReceiptLabel("\(index + 1). \(output.title) · \(detail)", index: index)
        }
    }
    private func addReceiptLabel(_ text: String, index: Int) {
        let field = label(text, id: "receipt-\(index)"); field.maximumNumberOfLines = 2
        field.toolTip = text; field.setAccessibilityLabel(text); receipts.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: receipts.widthAnchor).isActive = true
    }
}

/// Native duplicate events are rejected before NSButton's tracking/action path.
/// The table has a separate intentional double-action path.
@MainActor private final class CaptureChainRunButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount <= 1 else { return }; super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }; super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.isARepeat { return false }; return super.performKeyEquivalent(with: event)
    }
}
