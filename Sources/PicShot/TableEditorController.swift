import AppKit
import UniformTypeIdentifiers
import PicShotCore

/// Editable structured cells. This editor does not infer table structure from plain OCR.
@MainActor final class TableEditorController: NSWindowController {
    private(set) var table: StructuredTable
    private let grid: StructuredTableGrid
    private let valueField = NSTextField(string: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let typePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let alignmentPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fillPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let boldButton = NSButton(checkboxWithTitle: "粗体", target: nil, action: nil)
    private let italicButton = NSButton(checkboxWithTitle: "斜体", target: nil, action: nil)
    private let comparison = NSStackView()
    private var undoTables: [StructuredTable] = []
    private var redoTables: [StructuredTable] = []
    private var isExporting = false

    init(table: StructuredTable, sourceImage: CGImage? = nil) {
        self.table = table
        grid = StructuredTableGrid(table: table)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "表格编辑器 · \(table.title)"
        window.minSize = NSSize(width: 1000, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        buildInterface(sourceImage: sourceImage)
        grid.onSelection = { [weak self] in self?.refreshInspector() }
        grid.onEdit = { [weak self] address, text in
            guard let self else { return false }
            return self.edit(text: text, at: address)
        }
        grid.onCopy = { [weak self] in self?.copyTSV() }
        grid.onClear = { [weak self] in self?.clearSelection() }
        grid.onUndo = { [weak self] in self?.undoEdit() }
        grid.onRedo = { [weak self] in self?.redoEdit() }
        refreshInspector()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildInterface(sourceImage: CGImage?) {
        guard let content = window?.contentView else { return }
        func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
        let actions = NSStackView(views: [button("合并", #selector(mergeCells)), button("拆分", #selector(splitCells)),
            button("插入行", #selector(insertRow)), button("插入列", #selector(insertColumn)),
            button("删除行", #selector(deleteRow)), button("删除列", #selector(deleteColumn)),
            button("撤销", #selector(undoEdit)), button("重做", #selector(redoEdit)),
            button("复制 TSV", #selector(copyTSV)), button("导出 XLSX…", #selector(exportXLSX))])
        actions.spacing = 6
        actions.alignment = .centerY
        locationLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        locationLabel.widthAnchor.constraint(equalToConstant: 105).isActive = true
        typePicker.addItems(withTitles: ["文本", "数字", "布尔值"])
        typePicker.toolTip = "选择类型后点击应用。文本不会自动变成公式或数字。"
        valueField.placeholderString = "单元格内容"
        valueField.target = self; valueField.action = #selector(applyValue)
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let valueRow = NSStackView(views: [locationLabel, typePicker, valueField, button("应用", #selector(applyValue))])
        valueRow.alignment = .centerY
        valueRow.distribution = .fill
        for control in [boldButton, italicButton] { control.target = self; control.action = #selector(applyStyle) }
        alignmentPicker.addItems(withTitles: ["左对齐", "居中", "右对齐"])
        fillPicker.addItems(withTitles: ["无填充", "浅黄", "浅蓝", "浅绿", "浅灰"])
        alignmentPicker.target = self; alignmentPicker.action = #selector(applyStyle)
        fillPicker.target = self; fillPicker.action = #selector(applyStyle)
        let styleRow = NSStackView(views: [boldButton, italicButton, alignmentPicker, fillPicker])
        styleRow.alignment = .centerY
        styleRow.spacing = 12
        let compareButton = NSButton(checkboxWithTitle: "对照原图", target: self, action: #selector(toggleComparison(_:)))
        compareButton.state = sourceImage == nil ? .off : .on
        compareButton.isEnabled = sourceImage != nil
        styleRow.addArrangedSubview(compareButton)
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = grid
        scroll.drawsBackground = true
        comparison.orientation = .vertical; comparison.alignment = .centerX
        comparison.addArrangedSubview(NSTextField(labelWithString: "原图（仅供对照，不写入 XLSX）"))
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if let sourceImage { imageView.image = NSImage(cgImage: sourceImage, size: NSSize(width: CGFloat(sourceImage.width), height: CGFloat(sourceImage.height))) }
        comparison.addArrangedSubview(imageView)
        comparison.widthAnchor.constraint(equalToConstant: 290).isActive = true
        imageView.widthAnchor.constraint(equalTo: comparison.widthAnchor).isActive = true
        comparison.isHidden = sourceImage == nil
        let body = NSStackView(views: [scroll, comparison])
        body.orientation = .horizontal; body.alignment = .top; body.distribution = .fill
        scroll.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        comparison.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        let help = NSTextField(labelWithString: "双击编辑 · 拖动或 Shift 扩选 · 回车编辑 · Tab 移动 · Delete 清空 · ⌘Z 撤销")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        let root = NSStackView(views: [actions, valueRow, styleRow, body, statusLabel, help])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            body.widthAnchor.constraint(equalTo: root.widthAnchor), valueRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }
    private func refreshInspector() {
        guard let cell = table.cell(at: grid.activeAddress) else { return }
        locationLabel.stringValue = grid.selection.spreadsheetReference
        valueField.stringValue = cell.value.displayText
        switch cell.value { case .text: typePicker.selectItem(at: 0); case .number: typePicker.selectItem(at: 1); case .boolean: typePicker.selectItem(at: 2) }
        boldButton.state = cell.style.bold ? .on : .off
        italicButton.state = cell.style.italic ? .on : .off
        alignmentPicker.selectItem(at: TableCellAlignment.allCases.firstIndex(of: cell.style.alignment) ?? 0)
        fillPicker.selectItem(at: TableCellFill.allCases.firstIndex(of: cell.style.fill) ?? 0)
        statusLabel.stringValue = "\(table.rowCount) 行 × \(table.columnCount) 列 · \(table.cells.filter(\.isMerged).count) 个合并单元格 · 文字以文本保存，不执行公式"
    }
    @discardableResult private func mutate(_ operation: (inout StructuredTable) throws -> Void) -> Bool {
        do {
            var changed = table
            try operation(&changed)
            guard changed != table else { return true }
            undoTables.append(table); redoTables.removeAll()
            let limit = max(1, min(20, 500_000 / (table.rowCount * table.columnCount)))
            if undoTables.count > limit { undoTables.removeFirst(undoTables.count - limit) }
            table = changed; grid.update(table); refreshInspector()
            return true
        } catch { showError(error); return false }
    }
    private func edit(text: String, at address: TableCoordinate, type: Int? = nil) -> Bool {
        let current = table.cell(at: address)?.value ?? .text("")
        let selectedType: Int
        if let type { selectedType = type } else {
            switch current { case .text: selectedType = 0; case .number: selectedType = 1; case .boolean: selectedType = 2 }
        }
        let value: TableCellValue
        switch selectedType {
        case 1:
            guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else {
                showError(StructuredTableError.invalidNumber); return false
            }
            value = .number(number)
        case 2:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "是": value = .boolean(true)
            case "false", "0", "否": value = .boolean(false)
            default: showError(PicShotError.message("布尔值请输入 TRUE / FALSE、1 / 0 或 是 / 否。")); return false
            }
        default: value = .text(text)
        }
        return mutate { try $0.setValue(value, at: address) }
    }
    @objc private func applyValue() { _ = edit(text: valueField.stringValue, at: grid.activeAddress, type: typePicker.indexOfSelectedItem) }
    @objc private func applyStyle() {
        guard grid.finishEditing() else { return }
        let style = TableCellStyle(bold: boldButton.state == .on, italic: italicButton.state == .on,
                                   alignment: TableCellAlignment.allCases[max(0, alignmentPicker.indexOfSelectedItem)],
                                   fill: TableCellFill.allCases[max(0, fillPicker.indexOfSelectedItem)])
        let range = grid.selection
        mutate { try $0.setStyle(style, in: range) }
    }
    @objc private func mergeCells() {
        guard grid.finishEditing() else { return }
        let range = grid.selection; mutate { _ = try $0.merge(range) }
    }
    @objc private func splitCells() {
        guard grid.finishEditing() else { return }
        let selected = table.cells.filter { grid.selection.intersects($0.range) && $0.isMerged }.map(\.coordinate)
        mutate { table in for address in selected { try table.split(at: address) } }
    }
    @objc private func insertRow() {
        guard grid.finishEditing() else { return }; let index = grid.selection.firstRow
        if mutate({ try $0.insertRow(at: index) }) { grid.select(TableCoordinate(row: index, column: grid.activeAddress.column)) }
    }
    @objc private func insertColumn() {
        guard grid.finishEditing() else { return }; let index = grid.selection.firstColumn
        if mutate({ try $0.insertColumn(at: index) }) { grid.select(TableCoordinate(row: grid.activeAddress.row, column: index)) }
    }
    @objc private func deleteRow() {
        guard grid.finishEditing() else { return }; let index = grid.activeAddress.row
        mutate { try $0.deleteRow(at: index) }
    }
    @objc private func deleteColumn() {
        guard grid.finishEditing() else { return }; let index = grid.activeAddress.column
        mutate { try $0.deleteColumn(at: index) }
    }
    private func clearSelection() {
        let addresses = table.cells.filter { grid.selection.intersects($0.range) }.map(\.coordinate)
        mutate { table in for address in addresses { try table.setValue(.text(""), at: address) } }
    }
    @objc private func undoEdit() {
        guard grid.finishEditing(), let previous = undoTables.popLast() else { return }
        redoTables.append(table); table = previous; grid.update(table); refreshInspector()
    }
    @objc private func redoEdit() {
        guard grid.finishEditing(), let next = redoTables.popLast() else { return }
        undoTables.append(table); table = next; grid.update(table); refreshInspector()
    }
    @objc private func copyTSV() {
        guard grid.finishEditing() else { return }
        do {
            let text = try table.tsv(in: grid.selection)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            statusLabel.stringValue = "已复制 \(grid.selection.spreadsheetReference)（TSV，文本公式前缀已保护）"
        } catch { showError(error) }
    }
    @objc private func toggleComparison(_ sender: NSButton) { comparison.isHidden = sender.state != .on }
    @objc private func exportXLSX() {
        guard !isExporting, grid.finishEditing(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.nameFieldStringValue = "PicShot-Table.xlsx"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.isExporting = true
            let snapshot = self.table
            self.statusLabel.stringValue = "正在导出 XLSX…"
            Task { @MainActor [weak self] in
                do {
                    try await Task.detached(priority: .userInitiated) { try XLSXExporter.write(snapshot, to: url) }.value
                    self?.statusLabel.stringValue = "已导出：\(url.lastPathComponent)"
                } catch { showError(error); self?.refreshInspector() }
                self?.isExporting = false
            }
        }
    }
}

/// Draws only visible cells; one native text field is installed while editing.
@MainActor private final class StructuredTableGrid: NSView, NSTextFieldDelegate {
    private var table: StructuredTable
    private(set) var selection: TableRange
    private var anchor = TableCoordinate(row: 0, column: 0)
    private(set) var activeAddress = TableCoordinate(row: 0, column: 0)
    private let cellWidth: CGFloat = 132, cellHeight: CGFloat = 36, rowHeader: CGFloat = 44, columnHeader: CGFloat = 28
    private var editor: NSTextField?
    private var editingAddress: TableCoordinate?
    var onSelection: (() -> Void)?
    var onEdit: ((TableCoordinate, String) -> Bool)?
    var onCopy: (() -> Void)?
    var onClear: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(table: StructuredTable) {
        self.table = table
        selection = table.cell(at: TableCoordinate(row: 0, column: 0))!.range
        super.init(frame: .zero)
        update(table)
        setAccessibilityRole(.table)
        setAccessibilityLabel("可编辑表格。双击或按回车编辑所选单元格。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ table: StructuredTable) {
        self.table = table
        frame.size = NSSize(width: rowHeader + CGFloat(table.columnCount) * cellWidth, height: columnHeader + CGFloat(table.rowCount) * cellHeight)
        activeAddress = bounded(activeAddress); anchor = bounded(anchor)
        let clamped = TableRange(firstRow: min(selection.firstRow, table.rowCount - 1), firstColumn: min(selection.firstColumn, table.columnCount - 1),
                                 lastRow: min(selection.lastRow, table.rowCount - 1), lastColumn: min(selection.lastColumn, table.columnCount - 1))
        selection = (try? table.expandedRange(clamped)) ?? table.cell(at: activeAddress)!.range
        needsDisplay = true
    }
    private func bounded(_ value: TableCoordinate) -> TableCoordinate {
        TableCoordinate(row: max(0, min(table.rowCount - 1, value.row)), column: max(0, min(table.columnCount - 1, value.column)))
    }
    func select(_ address: TableCoordinate, extend: Bool = false) {
        activeAddress = bounded(address)
        if !extend { anchor = activeAddress }
        selection = (try? table.expandedRange(TableRange(anchor, activeAddress))) ?? table.cell(at: activeAddress)!.range
        needsDisplay = true; onSelection?()
        setAccessibilityValue("选择 \(selection.spreadsheetReference)，\(table.cell(at: activeAddress)?.value.displayText ?? "")")
    }
    private func rect(_ range: TableRange) -> NSRect {
        NSRect(x: rowHeader + CGFloat(range.firstColumn) * cellWidth, y: columnHeader + CGFloat(range.firstRow) * cellHeight,
               width: CGFloat(range.lastColumn - range.firstColumn + 1) * cellWidth, height: CGFloat(range.lastRow - range.firstRow + 1) * cellHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        let visible = dirtyRect.intersection(bounds)
        let firstRow = max(0, Int(floor((visible.minY - columnHeader) / cellHeight)))
        let lastRow = min(table.rowCount - 1, Int(floor((visible.maxY - columnHeader) / cellHeight)))
        let firstColumn = max(0, Int(floor((visible.minX - rowHeader) / cellWidth)))
        let lastColumn = min(table.columnCount - 1, Int(floor((visible.maxX - rowHeader) / cellWidth)))
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return }
        var drawn = Set<UUID>()
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                guard let cell = table.cell(at: TableCoordinate(row: row, column: column)), drawn.insert(cell.id).inserted else { continue }
                let bounds = rect(cell.range)
                if let rgb = cell.style.fill.rgbHex, let color = UInt32(rgb, radix: 16) {
                    NSColor(srgbRed: CGFloat((color >> 16) & 255) / 255, green: CGFloat((color >> 8) & 255) / 255,
                            blue: CGFloat(color & 255) / 255, alpha: 1).setFill(); bounds.fill()
                }
                if selection.intersects(cell.range) { NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); bounds.fill() }
                NSColor.separatorColor.setStroke(); let border = NSBezierPath(rect: bounds); border.lineWidth = 0.5; border.stroke()
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = cell.style.alignment == .left ? .left : cell.style.alignment == .right ? .right : .center
                paragraph.lineBreakMode = .byTruncatingTail
                var font = NSFont.systemFont(ofSize: 13, weight: cell.style.bold ? .bold : .regular)
                if cell.style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                let textColor: NSColor = cell.style.fill == .none ? .textColor : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
                (cell.value.displayText as NSString).draw(in: bounds.insetBy(dx: 7, dy: 7), withAttributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph])
            }
        }
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: frame.width, height: columnHeader).fill()
        NSRect(x: 0, y: 0, width: rowHeader, height: frame.height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        for column in firstColumn...lastColumn {
            (TableCoordinate.columnName(column) as NSString).draw(at: NSPoint(x: rowHeader + CGFloat(column) * cellWidth + 8, y: 7), withAttributes: attributes)
        }
        for row in firstRow...lastRow {
            (String(row + 1) as NSString).draw(at: NSPoint(x: 6, y: columnHeader + CGFloat(row) * cellHeight + 10), withAttributes: attributes)
        }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: rect(selection).insetBy(dx: 1, dy: 1)); outline.lineWidth = 2; outline.stroke()
    }
    private func address(at event: NSEvent) -> TableCoordinate {
        let point = convert(event.locationInWindow, from: nil)
        return bounded(TableCoordinate(row: Int(floor((point.y - columnHeader) / cellHeight)), column: Int(floor((point.x - rowHeader) / cellWidth))))
    }
    override func mouseDown(with event: NSEvent) {
        guard finishEditing() else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let address = address(at: event)
        if point.y < columnHeader, point.x < rowHeader { selection = table.fullRange; onSelection?(); needsDisplay = true; return }
        if point.y < columnHeader {
            select(TableCoordinate(row: 0, column: address.column)); select(TableCoordinate(row: table.rowCount - 1, column: address.column), extend: true)
        } else if point.x < rowHeader {
            select(TableCoordinate(row: address.row, column: 0)); select(TableCoordinate(row: address.row, column: table.columnCount - 1), extend: true)
        } else {
            select(address, extend: event.modifierFlags.contains(.shift))
            if event.clickCount == 2 { beginEditing() }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard editor == nil else { return }
        select(address(at: event), extend: true); autoscroll(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": onCopy?(); return
            case "a": selection = table.fullRange; needsDisplay = true; onSelection?(); return
            case "z": event.modifierFlags.contains(.shift) ? onRedo?() : onUndo?(); return
            default: super.keyDown(with: event); return
            }
        }
        let extend = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: move(row: 0, column: -1, extend: extend)
        case 124: move(row: 0, column: 1, extend: extend)
        case 125: move(row: 1, column: 0, extend: extend)
        case 126: move(row: -1, column: 0, extend: extend)
        case 48: move(row: 0, column: extend ? -1 : 1)
        case 36, 76: beginEditing()
        case 51, 117: onClear?()
        default:
            if let text = event.characters, !text.isEmpty, !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option),
               text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { beginEditing(replacement: text) }
            else { super.keyDown(with: event) }
        }
    }
    private func move(row: Int, column: Int, extend: Bool = false) {
        guard let cell = table.cell(at: activeAddress) else { return }
        let destination = TableCoordinate(row: row > 0 ? cell.row + cell.rowSpan : row < 0 ? cell.row - 1 : activeAddress.row,
                                          column: column > 0 ? cell.column + cell.columnSpan : column < 0 ? cell.column - 1 : activeAddress.column)
        select(destination, extend: extend)
        if let cell = table.cell(at: activeAddress) { scrollToVisible(rect(cell.range)) }
    }
    private func beginEditing(replacement: String? = nil) {
        guard let cell = table.cell(at: activeAddress), editor == nil else { return }
        let field = NSTextField(frame: rect(cell.range).insetBy(dx: 2, dy: 2))
        field.stringValue = replacement ?? cell.value.displayText
        field.font = .systemFont(ofSize: 13); field.delegate = self
        field.isBordered = true; field.bezelStyle = .squareBezel
        field.cell?.wraps = true; field.cell?.isScrollable = false
        editingAddress = cell.coordinate; editor = field
        addSubview(field); window?.makeFirstResponder(field)
        if replacement == nil { field.selectText(nil) }
        else if let text = field.currentEditor() { text.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0) }
    }
    @discardableResult func finishEditing() -> Bool {
        guard let field = editor, let address = editingAddress else { return true }
        // Detach first so model refresh/focus changes cannot recursively commit this field.
        editor = nil; editingAddress = nil
        guard onEdit?(address, field.stringValue) ?? true else {
            editor = field; editingAddress = address; window?.makeFirstResponder(field); return false
        }
        field.delegate = nil; field.removeFromSuperview(); needsDisplay = true
        return true
    }
    func controlTextDidEndEditing(_ obj: Notification) { _ = finishEditing() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editor?.delegate = nil; editor?.removeFromSuperview(); editor = nil; editingAddress = nil
            window?.makeFirstResponder(self); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Option-Return is the native multiline insertion shortcut.
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            if finishEditing() { window?.makeFirstResponder(self) }; return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            let backwards = commandSelector == #selector(NSResponder.insertBacktab(_:))
            if finishEditing() { window?.makeFirstResponder(self); move(row: 0, column: backwards ? -1 : 1) }; return true
        }
        return false
    }
}
