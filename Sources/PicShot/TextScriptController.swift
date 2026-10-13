import AppKit
import Combine
import PicShotCore

/// Twelve source snapshots together retain at most 192 KiB. AppKit typing
/// groups can contain unlimited registrations, so use the same bounded-value
/// history approach as the existing text-pin editor instead.
struct TextScriptDraftHistory {
    struct Snapshot {
        let text: String
        var selection: NSRange
    }
    static let maximumLevels = 12
    static let maximumHistoryBytes = 12 * TextScriptDefinition.maximumSourceBytes
    private(set) var current = Snapshot(text: "", selection: NSRange(location: 0, length: 0))
    private(set) var undoStates: [Snapshot] = []
    private(set) var redoStates: [Snapshot] = []
    var retainedBytes: Int { (undoStates + redoStates).reduce(0) { $0 + $1.text.utf8.count } }
    mutating func reset(_ text: String) {
        current = Snapshot(text: text, selection: NSRange(location: 0, length: 0))
        undoStates.removeAll(); redoStates.removeAll()
    }
    mutating func select(_ range: NSRange) { current.selection = range }
    mutating func record(_ text: String, selection: NSRange) {
        guard text.utf8.count <= TextScriptDefinition.maximumSourceBytes else { return }
        guard text != current.text else { current.selection = selection; return }
        undoStates.append(current); redoStates.removeAll()
        current = Snapshot(text: text, selection: selection); trim()
    }
    @discardableResult mutating func undo() -> Bool {
        guard let previous = undoStates.popLast() else { return false }
        redoStates.append(current); current = previous; trim(); return true
    }
    @discardableResult mutating func redo() -> Bool {
        guard let next = redoStates.popLast() else { return false }
        undoStates.append(current); current = next; trim(); return true
    }
    private mutating func trim() {
        while undoStates.count + redoStates.count > Self.maximumLevels || retainedBytes > Self.maximumHistoryBytes {
            if !undoStates.isEmpty { undoStates.removeFirst() } else if !redoStates.isEmpty { redoStates.removeFirst() }
        }
    }
}

/// An explicit-save editor only. Capture, OCR, evaluation and Copy belong to
/// the existing run owner. No runtime content is passed to this controller.
@MainActor final class TextScriptController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate, NSMenuItemValidation {
    var onRun: ((UUID, UInt64) -> Void)?
    var onClose: ((UInt64) -> Void)?
    private(set) var commandGeneration: UInt64 = 0

    static let exampleSource = #"""
    const ids = text.match(/\b[A-Z][A-Z0-9]*-\d+\b/g) || [];
    return [...new Set(ids)].join("\n");
    """#

    private let store: TextScriptStore
    private var subscription: AnyCancellable?
    private var draftID: UUID?
    private var baseline: TextScriptDefinition?
    private var selectionUpdate = false
    private var restoring = false
    private var pendingCommand = false
    private var runActive = false
    private var closeRequested = false
    private var wantsVisible = false
    private var isSaving = false
    private var refreshingControls = false
    private var sourceHistory = TextScriptDraftHistory()
    var sourceUndoRetainedBytesForVerification: Int { sourceHistory.retainedBytes }

    private let table = NSTableView()
    private let nameField = NSTextField(string: "")
    private let nameEditor = TextScriptBoundedTextView(frame: .zero)
    private let sourceView = TextScriptBoundedTextView(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let byteCount = NSTextField(labelWithString: "")
    private let createButton = NSButton(title: "新建", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let discardButton = NSButton(title: "放弃更改", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let runButton = TextScriptRunButton(title: "运行", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    init(store: TextScriptStore) {
        self.store = store
        let panel = TextScriptEditorPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "文字脚本"; panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 600, height: 560); panel.delegate = self; panel.center()
        panel.onSave = { [weak self] in self?.saveDraft() }
        panel.onCancel = { [weak self] in self?.window?.performClose(nil) }
        buildInterface(in: panel)
        loadDraft(store.selectedID.flatMap { store.definition(id: $0) })
        reloadCatalog()
        subscription = store.$index.dropFirst().sink { [weak self] _ in
            // @Published sends before assignment. Invalidate now, reconcile
            // after assignment without ever replacing an unsaved draft.
            self?.invalidateCommands()
            DispatchQueue.main.async { [weak self] in self?.catalogDidChange() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() { showWindow(nil) }
    override func showWindow(_ sender: Any?) {
        wantsVisible = true; closeRequested = false
        catalogDidChange()
        super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
    }
    func hideForCapture() { window?.orderOut(nil) }
    /// App Quit must use the same explicit Save/Discard rule as window Close.
    /// A refused termination preserves both the draft and a live composition.
    func requestApplicationTermination() -> Bool {
        guard canClose() else {
            present()
            setStatus("更改尚未保存。请先点击“保存”或“放弃更改”，再退出 PicShot。")
            return false
        }
        return true
    }
    func isCurrentCommand(_ generation: UInt64) -> Bool { generation == commandGeneration && !closeRequested }
    func invalidateCommands() { commandGeneration &+= 1; pendingCommand = false; refreshControls() }
    func setRunActive(_ active: Bool) {
        if runActive != active { runActive = active; invalidateCommands() }
        else { pendingCommand = false; refreshControls() }
    }
    func showError(_ error: Error) {
        // Only our fixed catalog diagnostics are retained. Arbitrary NSError,
        // JavaScript exception strings and source contents are never displayed.
        let message = (error as? TextScriptCatalogError)?.errorDescription ?? "操作未完成，请重试。"
        invalidateCommands(); setStatus(message, error: true)
        if wantsVisible { window?.makeKeyAndOrderFront(nil) }
    }

    private var liveName: String { nameField.currentEditor()?.string ?? nameField.stringValue }
    private var hasDraft: Bool { draftID != nil }
    private var hasUnsavedDraft: Bool {
        guard hasDraft else { return false }
        guard let baseline else { return true }
        return liveName != baseline.name || sourceView.string != baseline.source
    }
    private var composing: Bool {
        sourceView.hasMarkedText() || sourceView.isHandlingTextInput || sourceView.isUpdatingMarkedText ||
            nameEditor.hasMarkedText() || nameEditor.isHandlingTextInput || nameEditor.isUpdatingMarkedText
    }
    private var editing: Bool { nameEditor.isTextEditing || sourceView.isTextEditing }
    private var canEdit: Bool { !runActive && !pendingCommand && !isSaving && !closeRequested }
    private var cleanSavedDraft: TextScriptDefinition? {
        guard !hasUnsavedDraft, !composing, let baseline,
              store.definition(id: baseline.id) == baseline else { return nil }
        return baseline
    }

    private func buildInterface(in panel: NSWindow) {
        let route = label("框选区域 → 本机文字识别 → transform(text) → 复制文字", id: "route")
        let guidance = label("只运行已保存的函数体。脚本只能处理文字，不能访问文件、网络或系统操作。", id: "guidance")
        let column = NSTableColumn(identifier: .init("text-scripts"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 26; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.dataSource = self; table.delegate = self
        table.identifier = .init("text-script-list"); table.setAccessibilityLabel("已保存的文字脚本")
        let list = NSScrollView(); list.documentView = table
        list.identifier = .init("text-script-list-scroll")
        list.hasVerticalScroller = true; list.autohidesScrollers = true; list.borderType = .bezelBorder

        nameField.identifier = .init("text-script-name"); nameField.placeholderString = "脚本名称，最多 64 个字符"
        nameField.delegate = self; nameField.cell?.isScrollable = true
        nameField.setAccessibilityLabel("脚本名称")
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameEditor.isFieldEditor = true; nameEditor.maximumUTF8Bytes = TextScriptDefinition.maximumNameBytes
        nameEditor.maximumCharacters = TextScriptDefinition.maximumNameCharacters; nameEditor.isSingleLine = true
        nameEditor.onInputRejected = { [weak self] in
            self?.setStatus("名称最多 64 个字符、256 字节，不能包含换行或控制字符；此次输入未加入。", error: true)
        }

        sourceView.identifier = .init("text-script-source"); sourceView.setAccessibilityLabel("transform(text) 的 JavaScript 函数体")
        sourceView.isRichText = false; sourceView.importsGraphics = false
        sourceView.isAutomaticQuoteSubstitutionEnabled = false; sourceView.isAutomaticDashSubstitutionEnabled = false
        sourceView.isAutomaticTextReplacementEnabled = false; sourceView.isAutomaticSpellingCorrectionEnabled = false
        sourceView.isContinuousSpellCheckingEnabled = false
        sourceView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sourceView.textColor = .textColor; sourceView.backgroundColor = .textBackgroundColor
        sourceView.textContainerInset = NSSize(width: 8, height: 8)
        sourceView.isVerticallyResizable = true; sourceView.isHorizontallyResizable = false
        sourceView.minSize = .zero; sourceView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sourceView.autoresizingMask = [.width]
        sourceView.textContainer?.widthTracksTextView = true
        sourceView.textContainer?.containerSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        sourceView.delegate = self
        sourceView.onUndo = { [weak self] in self?.undoSource() }
        sourceView.onRedo = { [weak self] in self?.redoSource() }
        sourceView.toolTip = "编辑函数体；⌘Z 撤销，⇧⌘Z 重做。保存或放弃更改后清空撤销记录。"
        let sourceMenu = NSMenu(title: "文字脚本")
        for (title, action) in [("撤销", #selector(undoSource)), ("重做", #selector(redoSource))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; sourceMenu.addItem(item)
        }
        sourceMenu.addItem(.separator())
        for (title, action) in [("剪切", #selector(NSText.cut(_:))), ("复制", #selector(NSText.copy(_:))),
                                ("粘贴", #selector(NSText.paste(_:))), ("全选", #selector(NSText.selectAll(_:)))] {
            sourceMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        sourceView.menu = sourceMenu
        sourceView.onInputRejected = { [weak self] in
            self?.setStatus("函数体最多 16,384 个 UTF-8 字节；此次输入未加入，现有文字和输入法候选保持不变。", error: true)
        }
        for editor in [sourceView, nameEditor] {
            editor.isRichText = false; editor.allowsUndo = false
            editor.onInputWillChange = { [weak self] in self?.invalidateCommands() }
            editor.onInputFinished = { [weak self] in self?.draftDidChange() }
            editor.onFocusChanged = { [weak self] in self?.invalidateCommands() }
            editor.onCancel = { [weak self] in self?.window?.performClose(nil) }
        }
        let sourceScroll = NSScrollView(); sourceScroll.documentView = sourceView
        sourceScroll.identifier = .init("text-script-source-scroll")
        sourceScroll.hasVerticalScroller = true; sourceScroll.autohidesScrollers = true; sourceScroll.borderType = .bezelBorder
        let signature = NSTextField(labelWithString: "function transform(text) {")
        signature.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        signature.identifier = .init("text-script-signature"); signature.setAccessibilityLabel("固定函数签名 function transform(text)")
        let closing = NSTextField(labelWithString: "}"); closing.font = signature.font
        closing.identifier = .init("text-script-closing-brace")
        byteCount.font = .systemFont(ofSize: 11); byteCount.textColor = .secondaryLabelColor
        byteCount.identifier = .init("text-script-byte-count")
        let signatureRow = row([signature, NSView(), byteCount])
        let nameRow = row([NSTextField(labelWithString: "名称"), nameField])

        configure(createButton, "create", #selector(createDraft))
        configure(saveButton, "save", #selector(saveDraft))
        configure(discardButton, "discard", #selector(discardDraft))
        configure(deleteButton, "delete", #selector(deleteDraft))
        configure(runButton, "run", #selector(requestRun))
        configure(closeButton, "close", #selector(closeAction))
        let actions = row([createButton, saveButton, discardButton, deleteButton, NSView(), closeButton, runButton])
        status.identifier = .init("text-script-status"); status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let root = NSStackView(views: [route, guidance, list, nameRow, signatureRow, sourceScroll, closing, status, actions])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        let content = NSView(); panel.contentView = content; content.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            list.heightAnchor.constraint(equalToConstant: 100),
            sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            status.heightAnchor.constraint(equalToConstant: 32)
        ])
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        panel.initialFirstResponder = table
        setStatus("选择已保存的脚本，或点“新建”编辑示例。只有点击“保存”才会保存函数体。")
    }
    private func label(_ text: String, id: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor; field.lineBreakMode = .byTruncatingTail
        field.identifier = .init("text-script-" + id); field.toolTip = text; field.setAccessibilityLabel(text)
        return field
    }
    private func row(_ views: [NSView]) -> NSStackView {
        // Stack spacing measures alignment rectangles, not rounded buttons'
        // full native frames. Leave enough room for their transparent padding.
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 20
        return stack
    }
    private func configure(_ button: NSButton, _ id: String, _ action: Selector) {
        button.target = self; button.action = action; button.bezelStyle = .rounded
        button.identifier = .init("text-script-" + id); button.setAccessibilityLabel(button.title)
    }
    private func setStatus(_ message: String, error: Bool = false) {
        status.stringValue = message; status.toolTip = message; status.setAccessibilityLabel(message)
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }
    private func refreshControls() {
        // Disabling a focused native field can synchronously resign its editor
        // and call back through invalidateCommands. Keep that invalidation, but
        // do not re-enter AppKit setters before the outer setter has returned.
        guard !refreshingControls else { return }
        refreshingControls = true
        defer { refreshingControls = false }
        let clean = cleanSavedDraft != nil
        nameField.isEnabled = canEdit && hasDraft; sourceView.isEditable = canEdit && hasDraft
        sourceView.isSelectable = hasDraft
        createButton.isEnabled = canEdit && !hasUnsavedDraft && !composing && store.definitions.count < TextScriptIndex.maximumDefinitions
        saveButton.isEnabled = canEdit && hasUnsavedDraft && !composing
        discardButton.isEnabled = canEdit && (hasUnsavedDraft || composing)
        deleteButton.isEnabled = canEdit && clean && !composing
        runButton.isEnabled = canEdit && clean && !editing
        byteCount.stringValue = "\(sourceView.string.utf8.count) / 16,384 字节"
        byteCount.setAccessibilityLabel(byteCount.stringValue)
    }
    private func catalogDidChange() {
        if !hasUnsavedDraft && !composing {
            let id = draftID ?? store.selectedID
            loadDraft(id.flatMap { store.definition(id: $0) })
        }
        reloadCatalog()
    }
    private func reloadCatalog() {
        selectionUpdate = true; table.reloadData()
        if let draftID, let row = store.definitions.firstIndex(where: { $0.id == draftID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        selectionUpdate = false; refreshControls()
    }
    private func loadDraft(_ definition: TextScriptDefinition?) {
        restoring = true
        // Explicit restoration discards composition without creating an undo
        // history that might later restore text from another script.
        nameEditor.unmarkText(); sourceView.unmarkText(); window?.makeFirstResponder(table)
        nameEditor.string = ""; nameField.stringValue = definition?.name ?? ""
        sourceView.string = definition?.source ?? ""; sourceView.setSelectedRange(NSRange(location: 0, length: 0))
        sourceHistory.reset(sourceView.string)
        baseline = definition; draftID = definition?.id
        nameField.toolTip = definition?.name; nameField.setAccessibilityValue(nameField.stringValue)
        restoring = false; refreshControls()
    }
    private func draftDidChange() {
        guard !restoring else { return }
        if !sourceView.hasMarkedText() && !sourceView.isHandlingTextInput && !sourceView.isUpdatingMarkedText {
            sourceHistory.record(sourceView.string, selection: sourceView.selectedRange())
        }
        invalidateCommands(); nameField.toolTip = liveName; nameField.setAccessibilityValue(liveName)
        refreshControls()
    }

    @objc private func undoSource() {
        guard canEdit && !composing, sourceHistory.undo() else { return }; restoreSourceHistory()
    }
    @objc private func redoSource() {
        guard canEdit && !composing, sourceHistory.redo() else { return }; restoreSourceHistory()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoSource) { return canEdit && !composing && !sourceHistory.undoStates.isEmpty }
        if menuItem.action == #selector(redoSource) { return canEdit && !composing && !sourceHistory.redoStates.isEmpty }
        return false
    }
    private func restoreSourceHistory() {
        restoring = true; sourceView.string = sourceHistory.current.text
        let length = (sourceView.string as NSString).length, selection = sourceHistory.current.selection
        let start = min(length, max(0, selection.location))
        sourceView.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        restoring = false; invalidateCommands()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.definitions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.definitions.indices.contains(row) else { return nil }
        let name = store.definitions[row].name
        let cell = NSTextField(labelWithString: name); cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail; cell.toolTip = name; cell.setAccessibilityLabel(name)
        return cell
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard canEdit else { return false }
        if hasUnsavedDraft || composing {
            setStatus("请先保存或放弃当前更改，再选择其他脚本。")
            return false
        }
        return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectionUpdate else { return }
        guard canEdit && !hasUnsavedDraft && !composing else { reloadCatalog(); return }
        let row = table.selectedRow
        let definition = store.definitions.indices.contains(row) ? store.definitions[row] : nil
        guard draftID != definition?.id else { window?.makeFirstResponder(table); refreshControls(); return }
        do {
            if store.selectedID != definition?.id { try store.select(id: definition?.id) }
            invalidateCommands(); loadDraft(definition); reloadCatalog()
            setStatus("编辑函数体后点击“保存”。“运行”将框选一次区域，并复制处理后的文字。")
        } catch { reloadCatalog(); showError(error) }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { invalidateCommands() }
    func controlTextDidChange(_ obj: Notification) { draftDidChange() }
    func controlTextDidEndEditing(_ obj: Notification) { draftDidChange() }
    func textDidBeginEditing(_ notification: Notification) { invalidateCommands() }
    func textDidChange(_ notification: Notification) { draftDidChange() }
    func textDidEndEditing(_ notification: Notification) { draftDidChange() }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !restoring, !composing, sourceView.string == sourceHistory.current.text else { return }
        sourceHistory.select(sourceView.selectedRange())
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        canEdit && hasDraft
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if let field = client as? NSTextField, field === nameField { return nameEditor }
        return nil
    }

    @objc private func createDraft() {
        guard canEdit && !hasUnsavedDraft && !composing,
              store.definitions.count < TextScriptIndex.maximumDefinitions else { return }
        invalidateCommands(); loadDraft(nil)
        draftID = UUID(); nameField.stringValue = "提取工单编号"; sourceView.string = Self.exampleSource
        sourceHistory.reset(sourceView.string)
        reloadCatalog(); window?.makeFirstResponder(nameField)
        setStatus("示例尚未保存。提取并去重 ABC-123 格式编号；按需编辑后点击“保存”。")
    }
    @objc private func saveDraft() {
        guard canEdit, hasUnsavedDraft, let id = draftID else { return }
        guard !composing else { setStatus("请先完成输入法候选文字，再保存。", error: true); return }
        do {
            let definition = try TextScriptDefinition(id: id, name: liveName, source: sourceView.string)
            isSaving = true; refreshControls()
            defer { isSaving = false; refreshControls() }
            if baseline == nil { try store.add(definition, select: true) }
            else { try store.update(definition, select: true) }
            invalidateCommands(); loadDraft(definition); reloadCatalog()
            setStatus("已保存。点击“运行”框选区域；识别和文字处理均在本机完成。")
        } catch { showError(error) }
    }
    @objc private func discardDraft() {
        guard canEdit && (hasUnsavedDraft || composing) else { return }
        let saved = draftID.flatMap { store.definition(id: $0) }
        invalidateCommands(); loadDraft(saved); reloadCatalog()
        setStatus("已放弃未保存的更改。")
    }
    @objc private func deleteDraft() {
        guard canEdit, !composing, let definition = cleanSavedDraft else { return }
        do {
            try store.remove(id: definition.id)
            invalidateCommands(); loadDraft(nil); reloadCatalog()
            setStatus("已删除脚本。")
        } catch { showError(error) }
    }
    @objc private func requestRun() {
        guard canEdit, !editing, let definition = cleanSavedDraft, onRun != nil else { return }
        let generation = commandGeneration; let id = definition.id
        pendingCommand = true; refreshControls()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentCommand(generation), self.pendingCommand else { return }
            guard !self.runActive, !self.editing, self.cleanSavedDraft?.id == id, let onRun = self.onRun else {
                self.invalidateCommands(); return
            }
            onRun(id, generation)
        }
    }
    @objc private func closeAction() { window?.performClose(nil) }
    override func close() {
        guard canClose() else { return }
        super.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }
    private func canClose() -> Bool {
        guard !hasUnsavedDraft && !composing else {
            setStatus("更改尚未保存。请先点击“保存”或“放弃更改”，再关闭。")
            return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        wantsVisible = false
        guard !closeRequested else { return }
        closeRequested = true; invalidateCommands(); onClose?(commandGeneration)
    }
}

@MainActor private final class TextScriptEditorPanel: NSPanel {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        if event.keyCode == 53, flags.isEmpty {
            if (firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            if !event.isARepeat { onCancel?() }; return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            if !event.isARepeat { onSave?() }; return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == .command || flags == [.command, .shift],
           let text = firstResponder as? TextScriptBoundedTextView { return text.performKeyEquivalent(with: event) }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if (firstResponder as? NSTextView)?.hasMarkedText() == true { return }
        onCancel?()
    }
}

/// Input is preflighted before AppKit updates composition or lays out a paste.
/// Rejection leaves the current selection, marked range and text untouched.
@MainActor final class TextScriptBoundedTextView: NSTextView {
    var maximumUTF8Bytes = TextScriptDefinition.maximumSourceBytes
    var maximumCharacters: Int?
    var isSingleLine = false
    var onInputRejected: (() -> Void)?
    var onInputWillChange: (() -> Void)?
    var onInputFinished: (() -> Void)?
    var onFocusChanged: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    private(set) var isUpdatingMarkedText = false
    private(set) var isTextEditing = false
    private var inputDepth = 0
    var isHandlingTextInput: Bool { inputDepth > 0 }

    override var allowsUndo: Bool {
        get { false }
        set { super.allowsUndo = false }
    }
    override var undoManager: UndoManager? { nil }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { isTextEditing = true; onFocusChanged?() }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { isTextEditing = false; onFocusChanged?() }
        return result
    }
    func permitsReplacement(_ replacement: String, range: NSRange) -> Bool {
        let incoming = replacement.utf8.count
        guard incoming <= maximumUTF8Bytes, let range = Range(range, in: string),
              string.utf8.count - string[range].utf8.count <= maximumUTF8Bytes - incoming else {
            onInputRejected?(); return false
        }
        if isSingleLine && replacement.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) { onInputRejected?(); return false }
        if let maximumCharacters,
           string.replacingCharacters(in: range, with: replacement).count > maximumCharacters {
            onInputRejected?(); return false
        }
        return true
    }
    private func permitsInput(_ value: Any, replacementRange: NSRange) -> Bool {
        guard let text = (value as? NSAttributedString)?.string ?? (value as? String) else {
            onInputRejected?(); return false
        }
        let range = replacementRange.location == NSNotFound
            ? (hasMarkedText() ? markedRange() : selectedRange()) : replacementRange
        return permitsReplacement(text, range: range)
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let replacementString, !permitsReplacement(replacementString, range: affectedCharRange) { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard permitsInput(string, replacementRange: replacementRange) else { return }
        let wasUpdating = isUpdatingMarkedText
        isUpdatingMarkedText = true; inputDepth += 1; onInputWillChange?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputDepth -= 1; isUpdatingMarkedText = wasUpdating
        if !isHandlingTextInput { onInputFinished?() }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard permitsInput(insertString, replacementRange: replacementRange) else { return }
        inputDepth += 1; onInputWillChange?()
        super.insertText(insertString, replacementRange: replacementRange)
        inputDepth -= 1
        if !isHandlingTextInput { onInputFinished?() }
    }
    override func unmarkText() {
        super.unmarkText()
        if !isHandlingTextInput { onInputFinished?() }
    }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) } else { onCancel?() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == .command || flags == [.command, .shift],
           onUndo != nil || onRedo != nil {
            if !hasMarkedText(), !event.isARepeat { if flags.contains(.shift) { onRedo?() } else { onUndo?() } }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor private final class TextScriptRunButton: NSButton {
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
