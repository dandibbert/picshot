import AppKit

/// Transparent except for actual barcode polygons. Outside them, pin dragging still works.
@MainActor final class BarcodeSelectionOverlay: NSView {
    var document: RecognizedBarcodeDocument? {
        didSet { selectedIndex = nil; setAccessibilityValue(""); needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }
    var imageRect: CGRect = .zero { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    private(set) var selectedIndex: Int?
    var onSelect: ((Int) -> Void)?
    var onExit: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onCopy: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("图片中的识别码")
        toolTip = "点击码的区域选择；方向键切换，⌘C 复制；Esc 退出，空格标注"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        return CGPoint(x: (point.x - imageRect.minX) / imageRect.width, y: (point.y - imageRect.minY) / imageRect.height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let document else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), let point = normalized(local), document.result(at: point) != nil else { return nil }
        return self
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        for (index, result) in document.results.enumerated() {
            guard let quad = result.quad else { continue }
            let points = quad.points(in: imageRect), path = NSBezierPath()
            if let first = points.first { path.move(to: first); points.dropFirst().forEach { path.line(to: $0) }; path.close() }
            let selected = index == selectedIndex
            NSColor.controlAccentColor.withAlphaComponent(selected ? 0.23 : 0.07).setFill(); path.fill()
            NSColor.controlAccentColor.withAlphaComponent(selected ? 1 : 0.6).setStroke()
            path.lineWidth = selected ? 2.5 : 1; path.stroke()
            let box = quad.bounds
            let label = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            let badge = CGRect(x: imageRect.minX + box.minX * imageRect.width, y: imageRect.minY + box.maxY * imageRect.height - 19,
                               width: max(20, size.width + 8), height: 19)
            NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            label.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.minY + 2), withAttributes: attributes)
        }
    }
    override func resetCursorRects() {
        guard !isHidden, let document else { return }
        for result in document.results {
            guard let box = result.quad?.bounds else { continue }
            let rect = CGRect(x: imageRect.minX + box.minX * imageRect.width, y: imageRect.minY + box.minY * imageRect.height,
                              width: box.width * imageRect.width, height: box.height * imageRect.height).intersection(visibleRect)
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
        }
    }
    func selectResult(at index: Int?, notify: Bool = true) {
        guard let document else { selectedIndex = nil; return }
        if let index, !document.results.indices.contains(index) { return }
        selectedIndex = index; needsDisplay = true
        setAccessibilityValue(index.map { "\($0 + 1)：" + document.results[$0].title + " " + document.results[$0].payload } ?? "")
        if notify, let index { onSelect?(index) }
    }
    override func mouseDown(with event: NSEvent) {
        guard let document, let point = normalized(convert(event.locationInWindow, from: nil)), let index = document.result(at: point) else { return }
        window?.makeKey(); window?.makeFirstResponder(self); selectResult(at: index)
    }
    @objc func copy(_ sender: Any?) { onCopy?() }
    @discardableResult func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, event.keyCode == 53 { onExit?(); return true }
        if flags.isEmpty, event.keyCode == 49 { onAnnotate?(); return true }
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "c" { onCopy?(); return true }
        guard flags.isEmpty, [123, 124, 125, 126].contains(event.keyCode), let document, !document.results.isEmpty else { return false }
        let forward = [124, 125].contains(event.keyCode)
        let next = selectedIndex.map { ($0 + (forward ? 1 : document.results.count - 1)) % document.results.count } ?? 0
        selectResult(at: next); return true
    }
    override func keyDown(with event: NSEvent) { if !handleKeyDown(event) { super.keyDown(with: event) } }
    func releaseResources() {
        document = nil; onSelect = nil; onExit = nil; onCopy = nil; onAnnotate = nil; menu = nil
    }
}
