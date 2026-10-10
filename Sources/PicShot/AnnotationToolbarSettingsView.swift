import AppKit
import PicShotCore

extension AnnotationToolbarOrder.Family {
    var editorTool: ImageEditorTool {
        switch self {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .freehand: return .freehand
        case .arrow: return .arrow
        case .text: return .text
        case .number: return .number
        case .pixelate: return .pixelate
        case .redact: return .redact
        case .eraser: return .eraser
        case .spotlight: return .spotlight
        case .line: return .line
        case .highlighter: return .highlighter
        case .select: return .select
        case .crop: return .crop
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .freehand: return "pencil"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .number: return "1.circle"
        case .pixelate: return "square.grid.2x2.fill"
        case .redact: return "rectangle.fill"
        case .eraser: return "eraser"
        case .spotlight: return "light.beacon.max"
        case .line: return "line.diagonal"
        case .highlighter: return "highlighter"
        case .select: return "cursorarrow"
        case .crop: return "crop"
        }
    }
    var settingsTitle: String {
        switch self {
        case .ellipse: return "椭圆 / 圆弧 / 扇形"
        case .line: return "直线 / 折线"
        case .pixelate: return "马赛克 / 模糊 / 遮盖"
        default: return editorTool.title
        }
    }
}

/// This view owns a value-only draft and never reads or writes UserDefaults.
/// Closing/canceling Settings discards it; the outer Save Settings commits it.
@MainActor
final class AnnotationToolbarSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var draft: AnnotationToolbarOrder
    let tableView = NSTableView()
    let moveUpButton = SettingsActionButton(title: "上移", target: nil, action: nil)
    let moveDownButton = SettingsActionButton(title: "下移", target: nil, action: nil)
    let restoreDefaultsButton = SettingsActionButton(title: "恢复默认顺序", target: nil, action: nil)
    let selectionLabel = NSTextField(labelWithString: "")
    var onChange: (() -> Void)?

    var selectedFamily: AnnotationToolbarOrder.Family? {
        draft.families.indices.contains(tableView.selectedRow) ? draft.families[tableView.selectedRow] : nil
    }

    init(order: AnnotationToolbarOrder) {
        draft = order; super.init(frame: .zero)
        identifier = .init("annotationToolbar.settings")
        let column = NSTableColumn(identifier: .init("annotationToolbar.family"))
        column.resizingMask = .autoresizingMask; tableView.addTableColumn(column)
        tableView.headerView = nil; tableView.rowHeight = 24; tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true; tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false; tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self; tableView.delegate = self; tableView.identifier = .init("annotationToolbar.order")
        tableView.setAccessibilityLabel("标注工具顺序")
        let scroll = NSScrollView(); scroll.documentView = tableView; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 208).isActive = true
        let controls = NSStackView(views: [moveUpButton, moveDownButton, restoreDefaultsButton]); controls.spacing = 8
        for (button, id, action) in [(moveUpButton, "moveUp", #selector(moveToolbarFamilyUp)),
                                     (moveDownButton, "moveDown", #selector(moveToolbarFamilyDown)),
                                     (restoreDefaultsButton, "restoreDefaults", #selector(restoreDefaults))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
            button.identifier = .init("annotationToolbar." + id); button.setAccessibilityLabel(button.title)
        }
        selectionLabel.font = .systemFont(ofSize: 11); selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.identifier = .init("annotationToolbar.selection")
        let help = NSTextField(wrappingLabelWithString: "选择工具后上移或下移；子工具跟随主工具。屏幕较窄时，自定义顺序靠后的工具收进“更多操作”。所有工具始终可在其中找到。点击“保存设置”后，下次打开编辑器生效；取消会丢弃草稿。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [scroll, selectionLabel, controls, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor), selectionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        tableView.reloadData(); selectFamily(order.families[0])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Replaces the draft (for import/cancel/reset) without committing or firing
    /// a user-edit callback. A currently selected family keeps its identity.
    func apply(order: AnnotationToolbarOrder) {
        let selected = selectedFamily ?? order.families[0]
        draft = order; tableView.reloadData(); selectFamily(selected)
    }

    func selectFamily(_ family: AnnotationToolbarOrder.Family) {
        guard let row = draft.families.firstIndex(of: family) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row); refreshSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { draft.families.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard draft.families.indices.contains(row) else { return nil }
        let family = draft.families[row]
        let label = NSTextField(labelWithString: "\(row + 1).  \(family.settingsTitle)")
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        label.identifier = .init("annotationToolbar.family." + family.rawValue)
        label.setAccessibilityLabel("\(family.settingsTitle)，第 \(row + 1) 项，共 \(draft.families.count) 项")
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshSelection() }

    private func refreshSelection() {
        let row = tableView.selectedRow
        moveUpButton.isEnabled = row > 0
        moveDownButton.isEnabled = row >= 0 && row < draft.families.count - 1
        restoreDefaultsButton.isEnabled = draft != .defaults
        selectionLabel.stringValue = selectedFamily.map { "当前选择：\($0.settingsTitle)（\(row + 1) / \(draft.families.count)）" } ?? "请选择工具"
        moveUpButton.toolTip = selectedFamily.map { "上移\($0.editorTool.title)" }
        moveDownButton.toolTip = selectedFamily.map { "下移\($0.editorTool.title)" }
    }
    private func moveSelection(by offset: Int) {
        guard let family = selectedFamily, draft.move(family, by: offset) else { return }
        tableView.reloadData(); selectFamily(family); onChange?()
    }
    @objc private func moveToolbarFamilyUp() { moveSelection(by: -1) }
    @objc private func moveToolbarFamilyDown() { moveSelection(by: 1) }
    @objc private func restoreDefaults() {
        guard draft != .defaults else { return }
        apply(order: .defaults); onChange?()
    }
}
