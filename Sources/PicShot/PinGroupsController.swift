import AppKit
import Combine
import PicShotCore

/// Compact native catalog for saved pins. The owner reconciles live windows through
/// onSessionChange and opens/focuses a particular pin through onOpenPin.
/// No screen-capture permission is needed to manage or restore saved images.
@MainActor final class PinGroupsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenPin: ((UUID) -> Void)?
    var onSessionChange: (() -> Void)?
    private let store: PinSessionStore
    private let transforms: PinGroupTransformController?
    private var transformSubscription: AnyCancellable?
    private let transformButton = NSButton(title: "移动 / 缩放…", target: nil, action: nil)
    private let alignPicker = NSPopUpButton()
    private let undoGroupButton = NSButton(title: "撤销组合", target: nil, action: nil)
    private let redoGroupButton = NSButton(title: "重做", target: nil, action: nil)
    private let selectionStatus = NSTextField(labelWithString: "⌘ / ⇧ 多选正在显示的贴图")
    private var selectedPinIDs: Set<UUID> = []
    private var restoringSelection = false
    private var tableTracksTransformSelection = false
    private var selectionGroupID: UUID?
    private var selectionVisibility: Bool?
    private var subscription: AnyCancellable?
    private let groupPicker = NSPopUpButton()
    private let hiddenToggle = NSButton(checkboxWithTitle: "隐藏此组", target: nil, action: nil)
    private let protectedToggle = NSButton(checkboxWithTitle: "保护此组", target: nil, action: nil)
    private let restoreToggle = NSButton(checkboxWithTitle: "启动时恢复上次显示的贴图组", target: nil, action: nil)
    private let renameGroupButton = NSButton(title: "改名 / 颜色…", target: nil, action: nil)
    private let deleteGroupButton = NSButton(title: "删除组…", target: nil, action: nil)
    private let openButton = NSButton(title: "显示贴图", target: nil, action: nil)
    private let renamePinButton = NSButton(title: "重命名…", target: nil, action: nil)
    private let removePinButton = NSButton(title: "移除保存项…", target: nil, action: nil)
    private let movePicker = NSPopUpButton()
    private let table = NSTableView()
    private let preview = NSImageView()
    private let details = NSTextField(wrappingLabelWithString: "选择贴图以预览")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var displayedEntries: [PinSessionEntry] = []
    private var selectedPinID: UUID?

    init(store: PinSessionStore, transforms: PinGroupTransformController? = nil) {
        self.store = store; self.transforms = transforms
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "贴图组与历史"; panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 680, height: 600); panel.center()
        buildInterface(in: panel)
        reload()
        // Scheduled delivery observes the committed value, not @Published's willSet value.
        subscription = store.$index.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
        transformSubscription = transforms?.$revision.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.synchronizeTransformSelection() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        if let transforms, !transforms.selectedIDs.isEmpty { selectedPinIDs = transforms.selectedIDs }
        reload(); super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
    }

    private func buildInterface(in window: NSWindow) {
        groupPicker.target = self; groupPicker.action = #selector(changeGroup)
        groupPicker.setAccessibilityLabel("当前贴图组")
        let addGroupButton = NSButton(title: "新建组…", target: self, action: #selector(addGroup))
        renameGroupButton.target = self; renameGroupButton.action = #selector(renameGroup)
        deleteGroupButton.target = self; deleteGroupButton.action = #selector(deleteGroup)
        hiddenToggle.target = self; hiddenToggle.action = #selector(toggleHidden)
        protectedToggle.target = self; protectedToggle.action = #selector(toggleProtected)
        protectedToggle.toolTip = "保护组内保存项不被空间上限自动淘汰；受保护内容仍计入总限额"
        restoreToggle.target = self; restoreToggle.action = #selector(toggleRestore)
        let showGroupButton = NSButton(title: "显示此组", target: self, action: #selector(showGroup))
        let hideAllButton = NSButton(title: "隐藏全部", target: self, action: #selector(hideAll))

        let heading = NSStackView(views: [NSTextField(labelWithString: "贴图组"), groupPicker, addGroupButton, renameGroupButton, deleteGroupButton])
        heading.orientation = .horizontal; heading.spacing = 8
        let visibility = NSStackView(views: [hiddenToggle, protectedToggle, NSView(), showGroupButton, hideAllButton])
        visibility.orientation = .horizontal; visibility.spacing = 12
        groupPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        groupPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pin"))
        column.title = "贴图"; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 62
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("此组保存的贴图")
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder

        preview.imageScaling = .scaleProportionallyUpOrDown; preview.imageAlignment = .alignCenter
        preview.setAccessibilityLabel("所选贴图预览")
        details.textColor = .secondaryLabelColor; details.font = .systemFont(ofSize: 11)
        details.maximumNumberOfLines = 5
        let previewStack = NSStackView(views: [preview, details])
        previewStack.orientation = .vertical; previewStack.spacing = 8; previewStack.alignment = .leading
        preview.widthAnchor.constraint(equalTo: previewStack.widthAnchor).isActive = true
        details.widthAnchor.constraint(equalTo: previewStack.widthAnchor).isActive = true
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        previewStack.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let content = NSStackView(views: [scroll, previewStack])
        content.orientation = .horizontal; content.spacing = 14; content.alignment = .top
        scroll.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        previewStack.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 310).isActive = true
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        openButton.target = self; openButton.action = #selector(openSelected)
        renamePinButton.target = self; renamePinButton.action = #selector(renameSelected)
        removePinButton.target = self; removePinButton.action = #selector(removeSelected)
        movePicker.target = self; movePicker.action = #selector(moveSelected)
        movePicker.setAccessibilityLabel("将所选贴图移动到组")
        let actions = NSStackView(views: [openButton, renamePinButton, removePinButton, NSView(), NSTextField(labelWithString: "移动到"), movePicker])
        actions.orientation = .horizontal; actions.spacing = 8
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        transformButton.target = self; transformButton.action = #selector(transformSelected)
        transformButton.identifier = NSUserInterfaceItemIdentifier("pin-group-transform")
        alignPicker.addItem(withTitle: "对齐…")
        for alignment in PinGroupAlignment.allCases { alignPicker.addItem(withTitle: alignment.title) }
        alignPicker.target = self; alignPicker.action = #selector(alignSelected)
        alignPicker.identifier = NSUserInterfaceItemIdentifier("pin-group-align"); alignPicker.setAccessibilityLabel("组合对齐")
        alignPicker.toolTip = "居中对齐遵循屏幕像素网格；窗口大小与图片像素不变。"
        undoGroupButton.target = self; undoGroupButton.action = #selector(undoGroup)
        undoGroupButton.identifier = NSUserInterfaceItemIdentifier("pin-group-undo")
        redoGroupButton.target = self; redoGroupButton.action = #selector(redoGroup)
        redoGroupButton.identifier = NSUserInterfaceItemIdentifier("pin-group-redo")
        selectionStatus.font = .systemFont(ofSize: 11); selectionStatus.textColor = .secondaryLabelColor
        let groupActions = NSStackView(views: [transformButton, alignPicker, undoGroupButton, redoGroupButton, selectionStatus])
        groupActions.orientation = .horizontal; groupActions.spacing = 8
        groupActions.isHidden = transforms == nil
        let root = NSStackView(views: [heading, visibility, content, actions, groupActions, restoreToggle, status])
        root.orientation = .vertical; root.spacing = 12; root.alignment = .leading
        let container = NSView(); container.addSubview(root); window.contentView = container
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        for row in [heading, visibility, content, actions] { row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    func reload() {
        let visible = !store.index.allHidden && store.groups.first(where: { $0.id == store.index.activeGroupID })?.isHidden == false
        if let selectionGroupID, selectionGroupID != store.index.activeGroupID || selectionVisibility != visible { selectedPinIDs.removeAll() }
        selectionGroupID = store.index.activeGroupID; selectionVisibility = visible
        if let transforms, tableTracksTransformSelection || !transforms.selectedIDs.isEmpty {
            selectedPinIDs = transforms.selectedIDs; tableTracksTransformSelection = true
        }
        let selection = selectedPinIDs
        restoringSelection = true
        groupPicker.removeAllItems(); movePicker.removeAllItems()
        for group in store.groups {
            let count = store.entries.filter { $0.groupID == group.id }.count
            let title = "\(group.name) (\(count))" + (group.isProtected ? " · 保护" : "")
            groupPicker.addItem(withTitle: title)
            groupPicker.lastItem?.image = colorDot(group.color)
            movePicker.addItem(withTitle: group.name)
            movePicker.lastItem?.image = colorDot(group.color)
        }
        if let groupIndex = store.groups.firstIndex(where: { $0.id == store.index.activeGroupID }) {
            groupPicker.selectItem(at: groupIndex); movePicker.selectItem(at: groupIndex)
            hiddenToggle.state = store.groups[groupIndex].isHidden ? .on : .off
            protectedToggle.state = store.groups[groupIndex].isProtected ? .on : .off
        }
        deleteGroupButton.isEnabled = store.index.activeGroupID != PinGroup.defaultID
        restoreToggle.state = PinSessionStore.restoreOnLaunch ? .on : .off
        displayedEntries = store.entries.filter { $0.groupID == store.index.activeGroupID }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        table.reloadData()
        let rows = IndexSet(displayedEntries.indices.filter { selection.contains(displayedEntries[$0].id) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        restoringSelection = false
        updateSelection(updateTransforms: false)
        let bytes = store.entries.reduce(Int64(0)) { $0 + $1.storedByteCount }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let visibility = store.index.allHidden ? " · 全部已隐藏" : ""
        let archivedCount = store.entries.filter { !$0.isVisible }.count
        status.stringValue = "已保存 \(store.entries.count)/\(store.policy.maxPins) 项（含归档 \(archivedCount) 项）· \(size)\(visibility)\n关闭贴图会归档；选择归档项可重新打开。最多同时显示 20 项（动画最多 4 个），总计最多 1 亿工作像素 / 512 MiB。\n受保护组与正在显示的贴图不会被自动淘汰；其他保存项在超限时按最近使用时间保留。"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedEntries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedEntries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("pin-row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PinSessionRowView ?? PinSessionRowView(frame: .zero)
        cell.identifier = identifier
        let entry = displayedEntries[row]
        cell.thumbnail.image = store.thumbnail(id: entry.id)
        cell.heading.stringValue = entry.title
        let visibility = entry.isVisible ? "会话中" : "已归档"
        cell.subtitle.stringValue = "\(visibility) · \(entry.contentLabel) · \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !restoringSelection { updateSelection() } }
    private func updateSelection(updateTransforms: Bool = true) {
        selectedPinIDs = Set(table.selectedRowIndexes.compactMap { displayedEntries.indices.contains($0) ? displayedEntries[$0].id : nil })
        let row = table.selectedRow
        let entry = displayedEntries.indices.contains(row) ? displayedEntries[row] : nil
        selectedPinID = selectedPinIDs.count == 1 ? entry?.id : nil
        if updateTransforms, let transforms {
            do { try transforms.setSelection(selectedPinIDs); tableTracksTransformSelection = true }
            catch {
                // Archive/hidden-row preview remains a table-only selection.
                tableTracksTransformSelection = false
                if !transforms.selectedIDs.isEmpty { transforms.clearSelection() }
            }
        }
        preview.image = entry.flatMap { store.thumbnail(id: $0.id) }
        if let entry {
            let modified = entry.original.filename == entry.current.filename ? "原始图片" : "已编辑；原图仍可恢复"
            if let rich = entry.richContent {
                let extra = rich.kind == .animation ? "\(rich.width) × \(rich.height) · \(rich.frameCount) 帧" : rich.kind == .files ? "仅保存引用，不读取文件内容" : "本机保存的内容"
                details.stringValue = "\(entry.title)\n\(entry.contentLabel) · \(extra)" + (entry.isVisible ? "" : "\n已归档：选择重新打开可恢复")
            } else {
                details.stringValue = "\(entry.title)\n\(entry.current.width) × \(entry.current.height) 像素 · \(modified)" + (entry.isVisible ? "" : "\n已归档：重新打开后恢复原图与编辑结果")
            }
            if let groupIndex = store.groups.firstIndex(where: { $0.id == entry.groupID }) { movePicker.selectItem(at: groupIndex) }
        } else { details.stringValue = displayedEntries.isEmpty ? "此组还没有贴图\n新贴图将保存到当前组" : "选择贴图以预览" }
        openButton.title = entry?.isVisible == false ? "重新打开" : "显示贴图"
        openButton.isEnabled = selectedPinID != nil; renamePinButton.isEnabled = selectedPinID != nil
        removePinButton.isEnabled = selectedPinID != nil; movePicker.isEnabled = selectedPinID != nil
        if selectedPinIDs.count > 1 { details.stringValue = "已选 \(selectedPinIDs.count) 项\n组合操作仅适用于正在显示、未锁定且未穿透的贴图。归档与隐藏项不会自动打开。直接拖动 / 拉伸仍只改变单个贴图；组合操作请用下方按钮。" }
        updateTransformControls()
    }
    /// Context menus and reset/hide own the live transform selection. A catalog
    /// reload must never replay old rows into it, including coalesced hide/show events.
    private func synchronizeTransformSelection() {
        guard let transforms else { return }
        if tableTracksTransformSelection || !transforms.selectedIDs.isEmpty {
            tableTracksTransformSelection = true
            restoringSelection = true
            let rows = IndexSet(displayedEntries.indices.filter { transforms.selectedIDs.contains(displayedEntries[$0].id) })
            table.selectRowIndexes(rows, byExtendingSelection: false)
            restoringSelection = false
            updateSelection(updateTransforms: false)
        } else { updateTransformControls() }
    }
    private func updateTransformControls() {
        let valid = transforms?.canTransform == true && transforms?.selectedIDs == selectedPinIDs
        transformButton.isEnabled = valid; alignPicker.isEnabled = valid
        undoGroupButton.isEnabled = transforms?.canUndo == true; redoGroupButton.isEnabled = transforms?.canRedo == true
        selectionStatus.stringValue = valid ? "已选 \(selectedPinIDs.count) 项 · 按钮操作" : selectedPinIDs.count > 1 ? "请仅选择可操作的显示项" : "⌘ / ⇧ 多选显示项"
    }
    @objc private func transformSelected() { transforms?.showEditor() }
    @objc private func alignSelected() {
        let index = alignPicker.indexOfSelectedItem - 1
        defer { alignPicker.selectItem(at: 0) }
        guard PinGroupAlignment.allCases.indices.contains(index) else { return }
        do { try transforms?.transform(.align(PinGroupAlignment.allCases[index])) }
        catch { showError(error) }
        updateTransformControls()
    }
    @objc private func undoGroup() { do { try transforms?.undo() } catch { showError(error) }; updateTransformControls() }
    @objc private func redoGroup() { do { try transforms?.redo() } catch { showError(error) }; updateTransformControls() }

    @discardableResult private func change(_ operation: () throws -> Void) -> Bool {
        do { try operation(); reload(); onSessionChange?(); return true }
        catch { showError(error); return false }
    }

    @objc private func changeGroup() {
        guard store.groups.indices.contains(groupPicker.indexOfSelectedItem) else { return }
        let id = store.groups[groupPicker.indexOfSelectedItem].id
        change { try store.setActiveGroup(id: id) }
    }
    @objc private func toggleHidden() {
        change { try store.setGroupHidden(id: store.index.activeGroupID, hidden: hiddenToggle.state == .on) }
    }
    @objc private func toggleProtected() {
        change { try store.setGroupProtected(id: store.index.activeGroupID, protected: protectedToggle.state == .on) }
    }
    @objc private func toggleRestore() { PinSessionStore.restoreOnLaunch = restoreToggle.state == .on }
    @objc private func showGroup() { change { try store.showActiveGroup() } }
    @objc private func hideAll() { change { try store.setAllHidden(true) } }
    @objc private func addGroup() {
        guard let result = askGroup(title: "新建贴图组", name: "", color: .blue) else { return }
        change {
            let group = try store.createGroup(name: result.0, color: result.1)
            try store.setActiveGroup(id: group.id)
        }
    }
    @objc private func renameGroup() {
        guard let group = store.groups.first(where: { $0.id == store.index.activeGroupID }),
              let result = askGroup(title: "编辑贴图组", name: group.name, color: group.color) else { return }
        change { try store.renameGroup(id: group.id, name: result.0, color: result.1) }
    }
    @objc private func deleteGroup() {
        guard let group = store.groups.first(where: { $0.id == store.index.activeGroupID }), group.id != PinGroup.defaultID else { return }
        let alert = NSAlert(); alert.messageText = "删除“\(group.name)”组？"
        alert.informativeText = "组内所有贴图将移到默认组，图片不会删除。"
        alert.addButton(withTitle: "移到默认组并删除组"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        change { try store.deleteGroup(id: group.id) }
    }
    @objc private func openSelected() {
        guard let id = selectedPinID else { return }
        // The coordinator atomically reopens the item and reveals its group before loading.
        onOpenPin?(id)
    }
    @objc private func moveSelected() {
        guard let id = selectedPinID, store.groups.indices.contains(movePicker.indexOfSelectedItem) else { return }
        let destination = store.groups[movePicker.indexOfSelectedItem].id
        change { try store.movePin(id: id, to: destination) }
    }
    @objc private func renameSelected() {
        guard let id = selectedPinID, let entry = store.entry(id: id) else { return }
        let alert = NSAlert(); alert.messageText = "重命名贴图"
        let field = NSTextField(string: entry.title); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        change { try store.renamePin(id: id, title: field.stringValue) }
    }
    @objc private func removeSelected() {
        guard let id = selectedPinID, let entry = store.entry(id: id) else { return }
        let alert = NSAlert(); alert.messageText = "移除“\(entry.title)”贴图？"
        alert.informativeText = "这会删除保存的贴图内容与预览；关闭贴图只会归档。被引用的文件、截图历史和已导出的文件不受影响。"
        alert.addButton(withTitle: "移除贴图"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        change { try store.remove(id: id) }
    }
    private func askGroup(title: String, name: String, color: PinGroupColor) -> (String, PinGroupColor)? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: name); field.placeholderString = "组名（最多 48 字）"
        let colors = NSPopUpButton()
        for value in PinGroupColor.allCases {
            colors.addItem(withTitle: colorName(value)); colors.lastItem?.image = colorDot(value)
        }
        colors.selectItem(at: PinGroupColor.allCases.firstIndex(of: color) ?? 0)
        let accessory = NSStackView(views: [field, colors])
        accessory.orientation = .horizontal; accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = accessory; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              PinGroupColor.allCases.indices.contains(colors.indexOfSelectedItem) else { return nil }
        return (field.stringValue, PinGroupColor.allCases[colors.indexOfSelectedItem])
    }
    private func colorName(_ color: PinGroupColor) -> String {
        switch color { case .gray: return "灰色"; case .blue: return "蓝色"; case .green: return "绿色"
        case .orange: return "橙色"; case .purple: return "紫色"; case .red: return "红色" }
    }
    private func colorDot(_ color: PinGroupColor) -> NSImage {
        let tint: NSColor
        switch color { case .gray: tint = .systemGray; case .blue: tint = .systemBlue; case .green: tint = .systemGreen
        case .orange: tint = .systemOrange; case .purple: tint = .systemPurple; case .red: tint = .systemRed }
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            tint.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
    }
}

@MainActor private final class PinSessionRowView: NSTableCellView {
    let thumbnail = NSImageView()
    let heading = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        heading.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 10); subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [heading, subtitle]); text.orientation = .vertical; text.spacing = 4; text.alignment = .leading
        let stack = NSStackView(views: [thumbnail, text]); stack.spacing = 10; stack.alignment = .centerY
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), thumbnail.widthAnchor.constraint(equalToConstant: 50),
            thumbnail.heightAnchor.constraint(equalToConstant: 48), heading.widthAnchor.constraint(equalTo: text.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
