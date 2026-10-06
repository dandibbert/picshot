import AppKit

/// One reusable browser for screenshot, history and pin routes. The caller owns the
/// controller until onClose. No recognition, clipboard changes or URL opening in init.
@MainActor final class BarcodeResultController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onClose: (() -> Void)?
    var onSelect: ((Int) -> Void)?
    private(set) var document: RecognizedBarcodeDocument?
    private(set) var selectedIndex: Int?
    let showsSourceImage: Bool
    let preview = BarcodeSourcePreview()
    private let table = NSTableView()
    private let payloadView = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let selectionLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "复制完整值", target: nil, action: nil)
    private let openButton = NSButton(title: "打开网页", target: nil, action: nil)
    private var openURL: ((URL) -> Void)?
    private let copyPasteboard: NSPasteboard
    private var closed = false
    var selectedResult: RecognizedBarcode? {
        guard let document, let selectedIndex, document.results.indices.contains(selectedIndex) else { return nil }
        return document.results[selectedIndex]
    }
    var resultText: String { payloadView.string }
    var offersOpen: Bool { openButton.isEnabled }

    init(image: CGImage, document: RecognizedBarcodeDocument, showsSourceImage: Bool = true, pasteboard: NSPasteboard = .general,
         openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
        self.document = document; self.openURL = openURL; self.showsSourceImage = showsSourceImage; copyPasteboard = pasteboard
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: showsSourceImage ? 700 : 480, height: showsSourceImage ? 490 : 430),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "识别二维码 / 条码"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentMinSize = NSSize(width: showsSourceImage ? 540 : 390, height: 400); window.center()
        let root = NSView(); window.contentView = root
        let list = NSScrollView(); list.hasVerticalScroller = true; list.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("code")); column.width = showsSourceImage ? 200 : 450
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 46; table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = false; table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("识别码列表")
        list.documentView = table
        preview.isHidden = !showsSourceImage
        preview.image = showsSourceImage ? image : nil; preview.overlay.document = showsSourceImage ? document : nil
        preview.overlay.onSelect = { [weak self] in self?.selectResult(at: $0) }
        preview.overlay.onCopy = { [weak self] in self?.copy(nil) }
        preview.overlay.onExit = { [weak self] in self?.close() }
        let payloadScroll = NSScrollView(); payloadScroll.hasVerticalScroller = true; payloadScroll.hasHorizontalScroller = false
        payloadScroll.borderType = .bezelBorder; payloadScroll.documentView = payloadView
        payloadView.isEditable = false; payloadView.isSelectable = true; payloadView.isRichText = false
        payloadView.isAutomaticLinkDetectionEnabled = false; payloadView.isAutomaticDataDetectionEnabled = false
        payloadView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        payloadView.textContainerInset = NSSize(width: 6, height: 6)
        payloadView.autoresizingMask = [.width]; payloadView.isVerticallyResizable = true
        payloadView.textContainer?.widthTracksTextView = true
        payloadView.setAccessibilityLabel("完整识别值")
        status.stringValue = document.statusText; status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3; status.toolTip = document.statusText
        selectionLabel.font = .systemFont(ofSize: 12, weight: .medium); selectionLabel.lineBreakMode = .byTruncatingTail
        copyButton.target = self; copyButton.action = #selector(copy(_:))
        openButton.target = self; openButton.action = #selector(openSelected(_:))
        let help = NSTextField(labelWithString: "仅在本机识别 · 不自动访问码中的内容")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor; help.lineBreakMode = .byTruncatingTail
        for view in [list, preview, payloadScroll, status, selectionLabel, copyButton, openButton, help] as [NSView] {
            root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        }
        let rightEdge = showsSourceImage ? preview.trailingAnchor : list.trailingAnchor
        if showsSourceImage {
            NSLayoutConstraint.activate([
                list.widthAnchor.constraint(equalToConstant: 205), list.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
                preview.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 10), preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                preview.topAnchor.constraint(equalTo: list.topAnchor), preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 145)
            ])
        } else {
            NSLayoutConstraint.activate([list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                                         list.heightAnchor.constraint(greaterThanOrEqualToConstant: 125)])
        }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), list.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            selectionLabel.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 10), selectionLabel.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            selectionLabel.trailingAnchor.constraint(equalTo: rightEdge),
            payloadScroll.topAnchor.constraint(equalTo: selectionLabel.bottomAnchor, constant: 6), payloadScroll.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            payloadScroll.trailingAnchor.constraint(equalTo: rightEdge), payloadScroll.heightAnchor.constraint(equalToConstant: 100),
            status.topAnchor.constraint(equalTo: payloadScroll.bottomAnchor, constant: 6), status.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: rightEdge), status.heightAnchor.constraint(equalToConstant: 44),
            copyButton.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6), copyButton.trailingAnchor.constraint(equalTo: rightEdge),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            openButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8), openButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            help.leadingAnchor.constraint(equalTo: list.leadingAnchor), help.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            help.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -8)
        ])
        table.reloadData(); selectResult(at: document.results.isEmpty ? nil : 0, notify: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func numberOfRows(in tableView: NSTableView) -> Int { document?.results.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let document, document.results.indices.contains(row) else { return nil }
        let result = document.results[row]
        let summary = String(result.payload.prefix(80)).replacingOccurrences(of: "\n", with: " ↵ ") + (result.payload.count > 80 ? "…" : "")
        let label = NSTextField(wrappingLabelWithString: "\(row + 1) · \(result.title)\n" + summary)
        label.font = .systemFont(ofSize: 11); label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        label.toolTip = "列表为预览；下方显示并复制完整内容"
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { selectResult(at: table.selectedRow) }
    }
    func selectResult(at index: Int?, notify: Bool = true) {
        guard !closed, let document else { return }
        if let index, !document.results.indices.contains(index) { return }
        let changed = selectedIndex != index
        selectedIndex = index
        if let index, table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index) }
        preview.overlay.selectResult(at: index, notify: false)
        payloadView.string = selectedResult?.payload ?? ""
        var label = selectedResult.map { "\((index ?? 0) + 1) / \(document.results.count) · \($0.title) · \($0.payload.utf16.count) 字符（UTF-16）" } ?? "没有可用结果"
        if let equivalent = selectedResult?.upcaEquivalent { label += " · UPC-A：\(equivalent)（复制保留原始 13 位）" }
        selectionLabel.stringValue = label; selectionLabel.toolTip = label
        copyButton.isEnabled = selectedResult != nil
        openButton.isEnabled = selectedResult?.safeURL != nil
        openButton.toolTip = selectedResult?.safeURL.map { "在默认浏览器访问：" + $0.absoluteString } ?? "仅允许无账号密码的 http / https 网页地址"
        if notify, changed, let index { onSelect?(index) }
    }
    @objc func copy(_ sender: Any?) { copySelected(to: copyPasteboard) }
    @discardableResult func copySelected(to pasteboard: NSPasteboard) -> Bool {
        guard !closed, let result = selectedResult else { return false }
        pasteboard.clearContents(); return pasteboard.setString(result.payload, forType: .string)
    }
    /// This is connected only to the explicit Open button, never selection or double-click.
    @objc func openSelected(_ sender: Any?) {
        guard !closed, let url = selectedResult?.safeURL else { return }
        openURL?(url)
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true
        document = nil; selectedIndex = nil; preview.releaseResources(); payloadView.string = ""
        status.stringValue = ""; status.toolTip = nil; selectionLabel.stringValue = ""; selectionLabel.toolTip = nil
        openButton.toolTip = nil; openButton.isEnabled = false; copyButton.isEnabled = false
        table.dataSource = nil; table.delegate = nil; table.reloadData(); onSelect = nil; openURL = nil
        let completion = onClose; onClose = nil; completion?()
        window?.makeFirstResponder(nil); window?.contentView = nil; window?.delegate = nil
    }
}

@MainActor final class BarcodeSourcePreview: NSView {
    var image: CGImage? { didSet { needsDisplay = true; needsLayout = true } }
    let overlay = BarcodeSelectionOverlay()
    override init(frame: NSRect) { super.init(frame: frame); addSubview(overlay) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    var imageRect: CGRect {
        guard let image, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func layout() { super.layout(); overlay.frame = bounds; overlay.imageRect = imageRect }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        if let image, let context = NSGraphicsContext.current?.cgContext { context.interpolationQuality = .none; context.draw(image, in: imageRect) }
    }
    func releaseResources() { image = nil; overlay.releaseResources(); overlay.removeFromSuperview() }
}
