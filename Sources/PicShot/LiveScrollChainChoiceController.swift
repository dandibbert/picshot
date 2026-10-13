import AppKit
import PicShotCore

/// A route-local native sheet with owned control frames. AppKit alert padding
/// does not define this layout, and selecting a definition never applies it.
@MainActor
final class LiveScrollChainChoiceController: NSObject, NSWindowDelegate {
    let window: NSPanel
    let buttons: [NSButton]
    let accessoryView: NSView?
    /// Complete informational summary retained for callers and accessibility
    /// verification; the consequence and receipt details have separate views.
    let informativeText: String
    let detailText: String
    let consequenceWarning: String?
    let warningLabel: NSTextField?
    let selectedNameLabel: NSTextField?
    let outputOrderLabel: NSTextField?

    /// Presentation values only: this sheet owns neither output definitions nor
    /// executable script source, and selection never starts either route.
    private struct Row {
        let name: String
        let stepSummary: String
    }
    private let rows: [Row]
    private let picker: NSPopUpButton?
    private var completion: ((NSApplication.ModalResponse) -> Void)?
    private var presented = false
    private var ending = false
    private var settled = false

    convenience init(title: String, informativeText: String, definitions: [CaptureChainDefinition] = [],
         confirmTitle: String, confirmIdentifier: String, cancelIdentifier: String,
         consequenceWarning: String? = nil) {
        self.init(title: title, informativeText: informativeText,
            rows: definitions.map { Row(name: $0.name, stepSummary: $0.outputs.map(\.title).joined(separator: " → ")) },
            identifierPrefix: "scroll.live.imageChain", selectionLabel: "选择已保存的截图链",
            confirmTitle: confirmTitle, confirmIdentifier: confirmIdentifier, cancelIdentifier: cancelIdentifier,
            consequenceWarning: consequenceWarning)
    }

    convenience init(title: String = "使用文字脚本处理当前长图",
         informativeText: String = "来源：本次长截图。识别后执行所选文字脚本，并复制处理后的文字。",
         textScripts: [TextScriptDefinition], confirmTitle: String = "处理当前长图",
         confirmIdentifier: String = "scroll.live.textScript.run",
         cancelIdentifier: String = "scroll.live.textScript.choice.cancel", consequenceWarning: String? = nil) {
        self.init(title: title, informativeText: informativeText,
            rows: textScripts.map { Row(name: $0.name, stepSummary: "本机文字识别 → 文字脚本 → 复制文字") },
            identifierPrefix: "scroll.live.textScript", selectionLabel: "选择已保存的文字脚本",
            confirmTitle: confirmTitle, confirmIdentifier: confirmIdentifier, cancelIdentifier: cancelIdentifier,
            consequenceWarning: consequenceWarning)
    }

    private init(title: String, informativeText: String, rows: [Row], identifierPrefix: String,
         selectionLabel: String, confirmTitle: String, confirmIdentifier: String, cancelIdentifier: String,
         consequenceWarning: String?) {
        self.rows = rows; self.detailText = informativeText
        self.consequenceWarning = consequenceWarning
        self.informativeText = consequenceWarning.map { $0 + "\n\n" + informativeText } ?? informativeText
        let sheetWidth: CGFloat = 460, inset: CGFloat = 24, gap: CGFloat = 12
        let contentWidth = sheetWidth - 2 * inset
        let titleField = Self.label(title, id: identifierPrefix + ".sheet.title", font: .systemFont(ofSize: 16, weight: .semibold))
        // Consequences are always visible above the bounded receipt details.
        // This label never truncates, even when a receipt contains a long path.
        let warning = consequenceWarning.map {
            Self.label($0, id: identifierPrefix + ".sheet.warning", font: .systemFont(ofSize: 13, weight: .medium))
        }
        warningLabel = warning
        let warningHeight = warning.map { field in
            max(Self.textHeight(field.stringValue, font: field.font!, width: contentWidth),
                ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: 10_000)).height ?? 0) + 4)
        } ?? 0
        let warningSectionHeight = warning == nil ? 0 : warningHeight + gap
        let description = Self.label(informativeText, id: identifierPrefix + ".sheet.description")
        // Receipt details remain selectable and available in full via tooltip
        // and accessibility if an unusually long path exceeds this bounded view.
        let descriptionHeight = min(160, max(34, Self.textHeight(informativeText, font: description.font!, width: contentWidth)))
        description.maximumNumberOfLines = 9
        description.lineBreakMode = .byTruncatingTail

        let popup: NSPopUpButton?
        let nameLabel: NSTextField?
        let orderLabel: NSTextField?
        let nameHeight: CGFloat
        if rows.isEmpty {
            popup = nil; nameLabel = nil; orderLabel = nil; nameHeight = 0
        } else {
            let choice = NSPopUpButton(frame: .zero, pullsDown: false)
            choice.identifier = .init(identifierPrefix + ".choice")
            choice.font = .systemFont(ofSize: 13)
            choice.setAccessibilityLabel(selectionLabel)
            for (index, row) in rows.enumerated() {
                choice.addItem(withTitle: "\(index + 1). " + row.name)
                choice.lastItem?.toolTip = row.name + " · " + row.stepSummary
            }
            choice.selectItem(at: 0)
            popup = choice
            nameLabel = Self.label(rows[0].name, id: identifierPrefix + ".choice.name", font: .systemFont(ofSize: 13, weight: .medium))
            orderLabel = Self.label(rows[0].stepSummary, id: identifierPrefix + ".choice.outputs")
            nameHeight = max(20, rows.map { Self.textHeight($0.name, font: nameLabel!.font!, width: contentWidth) }.max() ?? 20)
        }
        picker = popup; accessoryView = popup
        selectedNameLabel = nameLabel; outputOrderLabel = orderLabel

        let confirm = NSButton(title: confirmTitle, target: nil, action: nil)
        confirm.identifier = .init(confirmIdentifier); confirm.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: nil, action: nil)
        cancel.identifier = .init(cancelIdentifier); cancel.keyEquivalent = "\u{1b}"
        for button in [confirm, cancel] {
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13)
            button.keyEquivalentModifierMask = []
            button.setAccessibilityLabel(button.title)
        }
        buttons = [confirm, cancel]
        let choicesHeight: CGFloat = popup == nil ? 0 : (gap + 28 + gap + nameHeight + 8 + 22)
        let height = inset + 24 + gap + warningSectionHeight + descriptionHeight + choicesHeight + 20 + 32 + inset
        let panel = LiveScrollChainChoicePanel(contentRect: NSRect(x: 0, y: 0, width: sheetWidth, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "PicShot"
        panel.identifier = .init(identifierPrefix + ".sheet")
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.contentMinSize = NSSize(width: sheetWidth, height: height)
        panel.contentMaxSize = panel.contentMinSize
        let content = NSView(frame: NSRect(x: 0, y: 0, width: sheetWidth, height: height))
        panel.contentView = content
        var top = height - inset
        func place(_ view: NSView, height: CGFloat, spacing: CGFloat) {
            top -= height
            view.frame = NSRect(x: inset, y: top, width: contentWidth, height: height)
            content.addSubview(view); top -= spacing
        }
        place(titleField, height: 24, spacing: gap)
        if let warning { place(warning, height: warningHeight, spacing: gap) }
        place(description, height: descriptionHeight, spacing: popup == nil ? 0 : gap)
        if let popup, let nameLabel, let orderLabel {
            place(popup, height: 28, spacing: gap)
            place(nameLabel, height: nameHeight, spacing: 8)
            place(orderLabel, height: 22, spacing: 0)
        }
        // These are complete native frames, with a 24-point gap between them.
        confirm.frame = NSRect(x: sheetWidth - inset - 140, y: inset, width: 140, height: 32)
        cancel.frame = NSRect(x: confirm.frame.minX - 24 - 88, y: inset, width: 88, height: 32)
        content.addSubview(confirm); content.addSubview(cancel)
        window = panel
        super.init()
        panel.delegate = self
        confirm.target = self; confirm.action = #selector(confirmPressed)
        cancel.target = self; cancel.action = #selector(cancelPressed)
        popup?.target = self; popup?.action = #selector(selectionChanged)
        panel.defaultButtonCell = confirm.cell as? NSButtonCell
        panel.confirm = { [weak self] in self?.requestFinish(.alertFirstButtonReturn) }
        panel.cancel = { [weak self] in self?.requestFinish(.alertSecondButtonReturn) }
        popup?.nextKeyView = confirm; confirm.nextKeyView = cancel; cancel.nextKeyView = (popup as NSView?) ?? confirm
        if let popup { Self.fitPopupTitles(popup, rows: rows) }
        updateSelectedRow()
    }

    func beginSheetModal(for parent: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !presented, !settled else { return }
        presented = true; completion = completionHandler
        guard parent.attachedSheet == nil else { complete(.cancel); return }
        // AppKit retains this one owner until the sheet has actually ended.
        parent.beginSheet(window) { [self] response in complete(response) }
        if !ending, !settled { window.makeFirstResponder((picker as NSResponder?) ?? buttons[0]) }
    }

    func cancel() {
        if !presented { settled = true; disableCommands(); return }
        requestFinish(.cancel)
    }

    @objc private func confirmPressed() { requestFinish(.alertFirstButtonReturn) }
    @objc private func cancelPressed() { requestFinish(.alertSecondButtonReturn) }
    @objc private func selectionChanged() {
        guard !ending, !settled else { return }
        updateSelectedRow()
    }

    private func updateSelectedRow() {
        guard let picker, rows.indices.contains(picker.indexOfSelectedItem) else { return }
        let selected = rows[picker.indexOfSelectedItem]
        Self.update(selectedNameLabel, text: selected.name)
        Self.update(outputOrderLabel, text: selected.stepSummary)
        picker.toolTip = selected.name + " · " + selected.stepSummary
        picker.setAccessibilityValue(selected.name + " · " + selected.stepSummary)
    }

    private func requestFinish(_ response: NSApplication.ModalResponse) {
        guard presented, !ending, !settled else { return }
        ending = true; disableCommands()
        let parent = window.sheetParent
        window.orderOut(nil)
        if let parent { parent.endSheet(window, returnCode: response) }
        else { complete(response) }
    }

    private func complete(_ response: NSApplication.ModalResponse) {
        guard !settled else { return }
        settled = true; ending = true; disableCommands()
        window.orderOut(nil)
        let callback = completion; completion = nil
        // Callback identity is retired before a new choice can be presented.
        callback?(response)
    }

    private func disableCommands() {
        for button in buttons { button.isEnabled = false; button.target = nil; button.action = nil }
        picker?.isEnabled = false; picker?.target = nil; picker?.action = nil
        (window as? LiveScrollChainChoicePanel)?.confirm = nil
        (window as? LiveScrollChainChoicePanel)?.cancel = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }

    private static func label(_ text: String, id: String, font: NSFont = .systemFont(ofSize: 13)) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.identifier = .init(id); field.font = font
        field.isSelectable = true; field.isEditable = false
        field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true; field.cell?.isScrollable = false
        update(field, text: text)
        return field
    }

    private static func update(_ field: NSTextField?, text: String) {
        field?.stringValue = text; field?.toolTip = text
        field?.setAccessibilityLabel(text); field?.setAccessibilityValue(text)
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let size = (text as NSString).boundingRect(with: NSSize(width: width - 4, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).size
        return ceil(size.height) + 4
    }

    private static func fitPopupTitles(_ popup: NSPopUpButton, rows: [Row]) {
        // Measure the real menu-wide native cell after installing its frame.
        // Padding differs across AppKit cells; no fixed overhead is assumed.
        guard let font = popup.font else { return }
        let selectedIndex = popup.indexOfSelectedItem
        var prefixes = rows.map(\.name)
        let maximumReductions = prefixes.reduce(0) { $0 + $1.count }
        func titleWidth(at index: Int) -> CGFloat {
            let title = popup.item(at: index)?.title ?? ""
            return (title as NSString).size(withAttributes: [.font: font]).width
        }
        // At most 32 × 64 character removals for a validated catalog. Shorter
        // names stay intact unless their own displayed title needs shortening.
        for _ in 0..<maximumReductions {
            guard let required = popup.cell?.cellSize,
                  required.width > popup.bounds.width else { break }
            guard let index = prefixes.indices.filter({ !prefixes[$0].isEmpty }).max(by: {
                titleWidth(at: $0) < titleWidth(at: $1)
            }) else { break }
            prefixes[index].removeLast()
            popup.item(at: index)?.title = "\(index + 1). " + prefixes[index] + "…"
            // Programmatic reselection refreshes the public popup cell title
            // without sending its action or altering the explicit selection.
            popup.selectItem(at: -1); popup.selectItem(at: selectedIndex)
        }
    }
}

@MainActor
private final class LiveScrollChainChoicePanel: NSPanel {
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty {
            if event.keyCode == 36 || event.keyCode == 76, let confirm { confirm(); return true }
            if event.keyCode == 53, let cancel { cancel(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { cancel?() }
}
