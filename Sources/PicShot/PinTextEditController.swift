import AppKit
import PicShotCore

/// A draft owns a small snapshot history, never AppKit's unbounded typing undo.
/// Both directions together retain at most 12 entries / 512 KiB of UTF-8 payload.
struct PinTextDraftHistory {
    struct Snapshot: Equatable {
        var text: String
        var selection: NSRange
    }
    static let maximumLevels = 12
    static let maximumHistoryBytes = 524_288
    private(set) var current: Snapshot
    private(set) var undoStates: [Snapshot] = []
    private(set) var redoStates: [Snapshot] = []
    var retainedHistoryBytes: Int { (undoStates + redoStates).reduce(0) { $0 + $1.text.utf8.count } }
    init(_ text: String) { current = Snapshot(text: text, selection: NSRange(location: 0, length: 0)) }
    mutating func select(_ range: NSRange) { current.selection = range }
    mutating func record(_ text: String, selection: NSRange) {
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
        while undoStates.count + redoStates.count > Self.maximumLevels || retainedHistoryBytes > Self.maximumHistoryBytes {
            if !undoStates.isEmpty { undoStates.removeFirst() } else if !redoStates.isEmpty { redoStates.removeFirst() }
        }
    }
    mutating func clear() { current = Snapshot(text: "", selection: NSRange(location: 0, length: 0)); undoStates.removeAll(); redoStates.removeAll() }
}

private enum PinDraftError: LocalizedError {
    case empty, tooLarge, invalid, composition, unavailable
    var errorDescription: String? {
        switch self {
        case .empty: return "文字不能为空。请先输入文字。"
        case .tooLarge: return "文字不能超过 262,144 个 UTF-8 字节；此次输入未加入草稿。"
        case .invalid: return "文字包含无效的空字符；此次输入未加入草稿。"
        case .composition: return "请先完成输入法候选文字，再保存。"
        case .unavailable: return "此贴图已关闭，无法保存。"
        }
    }
}

/// Shared owned sheet lifecycle. No asynchronous save callback can outlive its
/// owner, and a retained button cannot re-enter or repeat a completed commit.
@MainActor class PinDraftSheetController: NSWindowController, NSWindowDelegate {
    let saveButton = NSButton(title: "保存", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    var onDismiss: (() -> Void)?
    private(set) var completed = false
    private(set) var isSaving = false
    var initialFirstResponder: NSView? { nil }

    init(title: String, size: NSSize, body: NSView, explanation: String, identifier: String) {
        let panel = PinDraftWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = title; panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.identifier = .init(identifier); panel.backgroundColor = .windowBackgroundColor
        super.init(window: panel); panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.onSave = { [weak self] in self?.saveDraft() }
        let root = NSView(); panel.contentView = root
        let hint = NSTextField(wrappingLabelWithString: explanation)
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        errorLabel.identifier = .init(identifier + ".error"); errorLabel.setAccessibilityLabel("保存错误")
        for button in [cancelButton, saveButton] { button.bezelStyle = .rounded }
        saveButton.target = self; saveButton.action = #selector(saveDraft); saveButton.identifier = .init(identifier + ".save")
        cancelButton.target = self; cancelButton.action = #selector(cancelDraft); cancelButton.identifier = .init(identifier + ".cancel")
        // Return remains a newline / IME commit in the multiline editor.
        // Cmd-S and Escape are routed only by this owned window.
        let buttons = NSStackView(views: [cancelButton, saveButton]); buttons.spacing = 8
        for view in [hint, body, errorLabel, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: hint.leadingAnchor), body.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            body.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            body.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -8),
            errorLabel.leadingAnchor.constraint(equalTo: hint.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            errorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            errorLabel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: hint.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @discardableResult func presentSheet(for parent: NSWindow) -> Bool {
        guard !completed, let window else { return false }
        if window.sheetParent === parent { window.makeKeyAndOrderFront(nil); return true }
        guard parent.attachedSheet == nil else { close(); return false }
        window.appearance = parent.appearance
        parent.beginSheet(window); window.contentView?.layoutSubtreeIfNeeded()
        if let initialFirstResponder { window.makeFirstResponder(initialFirstResponder) }
        return true
    }
    func commitDraft() throws { throw PinDraftError.unavailable }
    func discardPayload() {}
    @objc func saveDraft() {
        guard !completed, !isSaving else { return }
        isSaving = true; saveButton.isEnabled = false
        do {
            try commitDraft()
            // The synchronous persistence callback can close its owner on error
            // recovery. Never reopen, redraw or finish another owner's sheet.
            guard !completed else { return }
            close()
        } catch {
            guard !completed else { return }
            isSaving = false; saveButton.isEnabled = true
            showError(error.localizedDescription)
        }
    }
    func showError(_ message: String) { errorLabel.stringValue = message; window?.contentView?.layoutSubtreeIfNeeded() }
    @objc private func cancelDraft() { close() }
    override func close() {
        guard !completed else { return }; completed = true; isSaving = false
        let callback = onDismiss; onDismiss = nil
        saveButton.target = nil; saveButton.action = nil; cancelButton.target = nil; cancelButton.action = nil
        if let panel = window as? PinDraftWindow { panel.onSave = nil; panel.onCancel = nil }
        discardPayload()
        window?.delegate = nil
        if let window { window.sheetParent?.endSheet(window, returnCode: .cancel); window.orderOut(nil) }
        super.close(); window?.contentView = nil
        callback?()
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }; close()
    }
}

@MainActor private final class PinDraftWindow: NSWindow {
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
           let text = firstResponder as? PinDraftTextView { return text.performKeyEquivalent(with: event) }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if (firstResponder as? NSTextView)?.hasMarkedText() == true { return }
        onCancel?()
    }
}

@MainActor final class PinTextEditController: PinDraftSheetController, NSTextViewDelegate {
    let textView = PinDraftTextView(frame: NSRect(x: 0, y: 0, width: 428, height: 184))
    let undoButton = NSButton(title: "撤销", target: nil, action: nil)
    let redoButton = NSButton(title: "重做", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    private(set) var history: PinTextDraftHistory
    private var originalContent: PinTextContent?
    private var onSave: ((PinTextContent, PinTextContent) throws -> Void)?
    private var restoring = false
    override var initialFirstResponder: NSView? { textView }
    /// Extra capacity is provisional only; Save still enforces the core limit.
    static let provisionalAllowanceUTF8Bytes = 16_384
    static let maximumProvisionalUTF8Bytes = PinTextContent.maximumUTF8Bytes + provisionalAllowanceUTF8Bytes
    static func isEditable(_ content: PinTextContent) -> Bool {
        content.isValid && !content.importedHTML && !content.plainText.contains("\0") &&
            content.runs.allSatisfy { !$0.bold && !$0.italic && !$0.code }
    }

    init(content: PinTextContent, onSave: @escaping (PinTextContent, PinTextContent) throws -> Void) throws {
        guard Self.isEditable(content) else { throw RichPinError.invalidContent }
        originalContent = content; self.onSave = onSave; history = PinTextDraftHistory(content.plainText)
        textView.string = content.plainText; textView.isRichText = false; textView.importsGraphics = false
        textView.allowsUndo = false; textView.isEditable = true; textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14); textView.textColor = .textColor; textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticLinkDetectionEnabled = false; textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false; textView.isGrammarCheckingEnabled = false
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 7, height: 7)
        textView.identifier = .init("pin.textEdit.text"); textView.setAccessibilityLabel("贴图文字草稿")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder; scroll.documentView = textView
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); countLabel.textColor = .secondaryLabelColor
        let body = NSView(), buttons = NSStackView(views: [undoButton, redoButton]); buttons.spacing = 6
        for view in [scroll, buttons, countLabel] { view.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: body.topAnchor), scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            buttons.leadingAnchor.constraint(equalTo: body.leadingAnchor), buttons.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            countLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor), countLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.trailingAnchor, constant: 8)
        ])
        super.init(title: "编辑贴图文字", size: NSSize(width: 460, height: 352), body: body,
            explanation: "保存后更新贴图。取消或关闭会放弃草稿。⌘S 保存；回车换行。", identifier: "pin.textEdit")
        textView.delegate = self
        textView.maximumDraftUTF8Bytes = Self.maximumProvisionalUTF8Bytes
        textView.onInputRejected = { [weak self] in
            self?.showError("此次输入过大，未加入草稿；现有文字和输入法候选保持不变。")
        }
        textView.onCompositionFinished = { [weak self] in self?.acceptTextChange() }
        textView.onUndo = { [weak self] in self?.undoDraft() }
        textView.onRedo = { [weak self] in self?.redoDraft() }
        textView.onCancel = { [weak self] in self?.close() }
        for button in [undoButton, redoButton] { button.bezelStyle = .rounded; button.target = self }
        undoButton.action = #selector(undoDraft); undoButton.identifier = .init("pin.textEdit.undo")
        redoButton.action = #selector(redoDraft); redoButton.identifier = .init("pin.textEdit.redo")
        refreshState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !completed, !isSaving else { return false }
        guard let replacementString else { return true }
        // Marked text is provisional. Keep the last committed draft intact, then
        // validate the whole composition once the input method commits it.
        if self.textView.isUpdatingMarkedText || textView.hasMarkedText() {
            // NSTextView input overrides preflight marked replacements before
            // AppKit mutates composition. Keep this check for other edit paths.
            return self.textView.permitsReplacement(replacementString, range: range)
        }
        guard replacementString.utf8.count <= PinTextContent.maximumUTF8Bytes,
              let swiftRange = Range(range, in: textView.string) else { showError(PinDraftError.tooLarge.localizedDescription); return false }
        let next = textView.string.replacingCharacters(in: swiftRange, with: replacementString)
        if let error = validationError(next, allowEmpty: true) { showError(error.localizedDescription); return false }
        history.select(textView.selectedRange()); return true
    }
    func textDidChange(_ notification: Notification) { acceptTextChange() }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !completed, !restoring, !textView.hasMarkedText(), !textView.isHandlingTextInput,
              textView.string == history.current.text else { return }
        history.select(textView.selectedRange())
    }
    private func acceptTextChange() {
        guard !completed, !restoring, !textView.hasMarkedText(), !textView.isHandlingTextInput else { refreshState(); return }
        if let error = validationError(textView.string, allowEmpty: true) {
            restoreCurrent(); showError(error.localizedDescription); return
        }
        let changed = textView.string != history.current.text
        history.record(textView.string, selection: textView.selectedRange())
        if changed { errorLabel.stringValue = "" }; refreshState()
    }
    private func validationError(_ text: String, allowEmpty: Bool) -> PinDraftError? {
        if !allowEmpty && text.isEmpty { return .empty }
        if text.utf8.count > PinTextContent.maximumUTF8Bytes { return .tooLarge }
        if text.contains("\0") { return .invalid }
        return nil
    }
    override func commitDraft() throws {
        guard !textView.hasMarkedText(), !textView.isHandlingTextInput else { throw PinDraftError.composition }
        if let error = validationError(textView.string, allowEmpty: false) { throw error }
        guard let originalContent, let onSave else { throw PinDraftError.unavailable }
        let content = PinTextContent(text: textView.string)
        guard content.isValid else { throw RichPinError.invalidContent }
        try onSave(content, originalContent)
    }
    @objc func undoDraft() {
        guard !completed, !isSaving, !textView.hasMarkedText(), history.undo() else { return }; restoreCurrent()
    }
    @objc func redoDraft() {
        guard !completed, !isSaving, !textView.hasMarkedText(), history.redo() else { return }; restoreCurrent()
    }
    private func restoreCurrent() {
        restoring = true
        textView.string = history.current.text
        let count = (history.current.text as NSString).length, selection = history.current.selection
        let start = min(count, max(0, selection.location))
        textView.setSelectedRange(NSRange(location: start, length: min(selection.length, count - start)))
        restoring = false; refreshState()
    }
    private func refreshState() {
        let composing = textView.hasMarkedText() || textView.isUpdatingMarkedText
        undoButton.isEnabled = !completed && !composing && !history.undoStates.isEmpty
        redoButton.isEnabled = !completed && !composing && !history.redoStates.isEmpty
        countLabel.stringValue = "\(textView.string.utf8.count) / 262,144 字节"
    }
    override func discardPayload() {
        onSave = nil; originalContent = nil; history.clear()
        textView.delegate = nil; textView.onCompositionFinished = nil; textView.onUndo = nil; textView.onRedo = nil; textView.onCancel = nil; textView.onInputRejected = nil
        textView.string = ""; textView.menu = nil
        for button in [undoButton, redoButton] { button.target = nil; button.action = nil }
    }
}

@MainActor final class PinDraftTextView: NSTextView {
    private(set) var isUpdatingMarkedText = false
    private var textInputDepth = 0
    var isHandlingTextInput: Bool { textInputDepth > 0 }
    var onCompositionFinished: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCancel: (() -> Void)?
    var maximumDraftUTF8Bytes = PinTextEditController.maximumProvisionalUTF8Bytes
    var onInputRejected: (() -> Void)?
    // Validate before super.setMarkedText / super.insertText: refusing in a
    // later delegate notification can already have destroyed a valid marked
    // range. NSNotFound means replace the current composition, or selection.
    private func permitsInput(_ value: Any, replacementRange: NSRange) -> Bool {
        guard let text = (value as? NSAttributedString)?.string ?? (value as? String) else {
            onInputRejected?(); return false
        }
        let range = replacementRange.location == NSNotFound
            ? (hasMarkedText() ? markedRange() : selectedRange()) : replacementRange
        return permitsReplacement(text, range: range)
    }
    func permitsReplacement(_ replacement: String, range: NSRange) -> Bool {
        let incoming = replacement.utf8.count
        guard incoming <= maximumDraftUTF8Bytes, let range = Range(range, in: string),
              string.utf8.count - string[range].utf8.count <= maximumDraftUTF8Bytes - incoming else {
            onInputRejected?(); return false
        }
        return true
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let replacementString, !permitsReplacement(replacementString, range: affectedCharRange) { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
    // No enclosing window / application undo manager can retain draft payloads.
    override var undoManager: UndoManager? { nil }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard permitsInput(string, replacementRange: replacementRange) else { return }
        let wasUpdating = isUpdatingMarkedText
        isUpdatingMarkedText = true; textInputDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        textInputDepth -= 1; isUpdatingMarkedText = wasUpdating
        if !isHandlingTextInput { onCompositionFinished?() }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard permitsInput(insertString, replacementRange: replacementRange) else { return }
        textInputDepth += 1
        super.insertText(insertString, replacementRange: replacementRange)
        textInputDepth -= 1
        if !isHandlingTextInput { onCompositionFinished?() }
    }
    override func unmarkText() {
        super.unmarkText()
        if !isHandlingTextInput { onCompositionFinished?() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == .command || flags == [.command, .shift] {
            if !hasMarkedText(), !event.isARepeat { if flags.contains(.shift) { onRedo?() } else { onUndo?() } }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) } else { onCancel?() }
    }
}

/// Reusable for image and text pins. The owner supplies the durable metadata
/// update and changes its own saved title only after that callback succeeds.
@MainActor final class PinRenameController: PinDraftSheetController {
    let nameField = NSTextField(string: "")
    private var onSave: ((String) throws -> Void)?
    static let maximumDraftUTF8Bytes = 16_384
    private let fieldEditor = PinDraftTextView(frame: .zero)
    override var initialFirstResponder: NSView? { nameField }
    init(title: String, onSave: @escaping (String) throws -> Void) {
        self.onSave = onSave; nameField.stringValue = title
        nameField.identifier = .init("pin.rename.name"); nameField.setAccessibilityLabel("贴图名称")
        nameField.font = .systemFont(ofSize: 13)
        fieldEditor.isFieldEditor = true; fieldEditor.isRichText = false; fieldEditor.allowsUndo = false
        fieldEditor.maximumDraftUTF8Bytes = Self.maximumDraftUTF8Bytes
        super.init(title: "重命名贴图", size: NSSize(width: 420, height: 176), body: nameField,
            explanation: "名称最多 120 个字符；保存后更新，不改变贴图内容。", identifier: "pin.rename")
        fieldEditor.onInputRejected = { [weak self] in
            self?.showError("名称草稿不能超过 16,384 个 UTF-8 字节；此次输入未加入。")
        }
        fieldEditor.onCancel = { [weak self] in self?.close() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if let field = client as? NSTextField, field === nameField { return fieldEditor }; return nil
    }
    override func commitDraft() throws {
        guard !fieldEditor.hasMarkedText() else { throw PinDraftError.composition }
        // Use the live field editor text without moving focus or selection.
        let raw = nameField.currentEditor()?.string ?? nameField.stringValue
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PinSessionIndex.validName(title, limit: 120) else { throw PinSessionError.invalidName }
        guard let onSave else { throw PinDraftError.unavailable }; try onSave(title)
    }
    override func discardPayload() {
        onSave = nil; fieldEditor.onInputRejected = nil; fieldEditor.onCancel = nil
        fieldEditor.string = ""; nameField.stringValue = ""
    }
}
