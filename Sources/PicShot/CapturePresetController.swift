import AppKit
import Combine
import PicShotCore

/// Compact metadata manager. Capture permission and countdown belong to the
/// caller; this window is hidden before either capture callback is invoked.
@MainActor final class CapturePresetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onCreate: ((String, ScreenshotDelay) -> Void)?
    var onInvoke: ((CapturePreset) -> Void)?
    /// Also called for Escape and the window's close button. The owner cancels
    /// its pending selection/countdown task without creating a screenshot.
    var onCancel: (() -> Void)?

    private let store: CapturePresetStore
    private var subscription: AnyCancellable?
    private let table = NSTableView()
    private let nameField = NSTextField(string: "矩形预设")
    private let delayPicker = NSPopUpButton()
    private let createButton = NSButton(title: "框选并保存…", target: nil, action: nil)
    private let updateButton = NSButton(title: "保存名称与延时", target: nil, action: nil)
    private let invokeButton = NSButton(title: "按预设截图", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除预设", target: nil, action: nil)
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var selectedID: UUID?

    init(store: CapturePresetStore) {
        self.store = store
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "截图预设"; panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 400); panel.center(); panel.delegate = self
        buildInterface(in: panel); reload()
        subscription = store.$presets.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        reload(); super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
    }

    private func buildInterface(in panel: NSWindow) {
        let guidance = NSTextField(wrappingLabelWithString: "保存显示器上的矩形区域与延时，下次直接截图。显示器位置、缩放、分辨率或旋转改变后，需要重新保存。")
        guidance.textColor = .secondaryLabelColor; guidance.font = .systemFont(ofSize: 11)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("capture-presets"))
        column.title = "已保存预设"; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.target = self; table.doubleAction = #selector(invokeSelected)
        table.identifier = NSUserInterfaceItemIdentifier("capture-preset-list")
        table.setAccessibilityLabel("已保存的截图预设")
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder

        nameField.placeholderString = "预设名称，最多 64 个字符"
        nameField.identifier = NSUserInterfaceItemIdentifier("capture-preset-name")
        nameField.setAccessibilityLabel("截图预设名称")
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delayPicker.identifier = NSUserInterfaceItemIdentifier("capture-preset-delay")
        delayPicker.setAccessibilityLabel("截图预设延时")
        for delay in ScreenshotDelay.allCases {
            delayPicker.addItem(withTitle: Self.delayTitle(delay)); delayPicker.lastItem?.tag = delay.rawValue
        }
        let form = NSStackView(views: [NSTextField(labelWithString: "名称"), nameField,
                                      NSTextField(labelWithString: "延时"), delayPicker])
        form.orientation = .horizontal; form.spacing = 8
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        createButton.target = self; createButton.action = #selector(createPreset)
        updateButton.target = self; updateButton.action = #selector(updateSelected)
        invokeButton.target = self; invokeButton.action = #selector(invokeSelected)
        deleteButton.target = self; deleteButton.action = #selector(deleteSelected)
        createButton.identifier = NSUserInterfaceItemIdentifier("capture-preset-create")
        updateButton.identifier = NSUserInterfaceItemIdentifier("capture-preset-update")
        invokeButton.identifier = NSUserInterfaceItemIdentifier("capture-preset-invoke")
        deleteButton.identifier = NSUserInterfaceItemIdentifier("capture-preset-delete")
        let editing = NSStackView(views: [createButton, updateButton, NSView(), deleteButton])
        editing.orientation = .horizontal; editing.spacing = 8
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        cancel.identifier = NSUserInterfaceItemIdentifier("capture-preset-cancel")
        cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancel, invokeButton])
        actions.orientation = .horizontal; actions.spacing = 8
        details.textColor = .secondaryLabelColor; details.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        details.maximumNumberOfLines = 2
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); status.maximumNumberOfLines = 3
        status.identifier = NSUserInterfaceItemIdentifier("capture-preset-status")
        status.setAccessibilityLabel("截图预设状态")
        let root = NSStackView(views: [guidance, scroll, details, form, editing, status, actions])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        let container = NSView(); container.addSubview(root); panel.contentView = container
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130)
        ])
        for view in [guidance, scroll, details, form, editing, status, actions] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
    }

    func reload() {
        let previousID = selectedID
        table.reloadData()
        if let previousID, let row = store.presets.firstIndex(where: { $0.id == previousID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { table.deselectAll(nil); selectedID = nil }
        updateSelection()
        status.textColor = .secondaryLabelColor
        status.stringValue = "已保存 \(store.presets.count)/\(CapturePresetIndex.maximumPresets) 个预设 · 仅在本机保存区域和延时，不保存屏幕图像"
    }

    func showError(_ error: Error) {
        status.textColor = .systemRed
        // These app-defined errors carry actionable screen-permission and
        // display-change guidance. Never replace them with a disk-error guess,
        // or expose arbitrary NSError details (paths, payloads, service text).
        if let error = error as? CapturePresetError {
            status.stringValue = error.errorDescription ?? "操作未完成，请重试。"
        } else if let error = error as? CaptureError {
            status.stringValue = error.errorDescription ?? "操作未完成，请重试。"
        } else if let error = error as? DisplayCompositeError {
            status.stringValue = error.errorDescription ?? "操作未完成，请重试。"
        } else {
            status.stringValue = "操作未完成，请重试。"
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.presets.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.presets.indices.contains(row) else { return nil }
        let preset = store.presets[row]
        let label = NSTextField(labelWithString: "\(preset.name)\n\(Int(preset.pixelFrame.width)) × \(Int(preset.pixelFrame.height)) 像素 · \(Self.delayTitle(preset.delay))")
        label.maximumNumberOfLines = 2; label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail; label.toolTip = preset.name
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        let row = table.selectedRow
        let preset = store.presets.indices.contains(row) ? store.presets[row] : nil
        selectedID = preset?.id
        if let preset {
            nameField.stringValue = preset.name; delayPicker.selectItem(withTag: preset.delay.rawValue)
            details.stringValue = "源像素：X \(Int(preset.pixelFrame.minX))，Y \(Int(preset.pixelFrame.minY)) · \(Int(preset.pixelFrame.width)) × \(Int(preset.pixelFrame.height))\n显示器：\(preset.display.uuid.uuidString)"
        } else { details.stringValue = "输入名称与延时，然后选择“框选并保存…”" }
        updateButton.isEnabled = preset != nil; invokeButton.isEnabled = preset != nil; deleteButton.isEnabled = preset != nil
        createButton.isEnabled = store.presets.count < CapturePresetIndex.maximumPresets
    }

    private var selectedDelay: ScreenshotDelay { ScreenshotDelay(rawValue: delayPicker.selectedTag()) ?? .none }
    private static func delayTitle(_ delay: ScreenshotDelay) -> String { delay == .none ? "无延时" : "\(delay.rawValue) 秒" }

    @objc private func createPreset() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CapturePreset.validName(name) else { showError(CapturePresetError.invalidName); return }
        guard store.presets.count < CapturePresetIndex.maximumPresets else { showError(CapturePresetError.limitReached); return }
        guard let onCreate else { return }
        let delay = selectedDelay
        window?.orderOut(nil)
        onCreate(name, delay)
    }

    @objc private func updateSelected() {
        guard let id = selectedID else { return }
        do { try store.update(id: id, name: nameField.stringValue, delay: selectedDelay); reload() }
        catch { showError(error) }
    }

    @objc private func deleteSelected() {
        guard let id = selectedID else { return }
        do { try store.remove(id: id); selectedID = nil; reload() }
        catch { showError(error) }
    }

    @objc private func invokeSelected() {
        guard let id = selectedID, let preset = store.preset(id: id), let onInvoke else { return }
        window?.orderOut(nil)
        onInvoke(preset)
    }

    @objc private func cancelAction() { window?.orderOut(nil); onCancel?() }
    func windowWillClose(_ notification: Notification) { onCancel?() }
}
