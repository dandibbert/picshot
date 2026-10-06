import AppKit

/// A transparent, explicitly enabled hit surface over the *same* image rect drawn by PinCanvas.
/// Only actual OCR polygons intercept clicks. Outside them the pin still moves normally.
@MainActor class PinTextSelectionOverlay: NSView, NSDraggingSource {
    var document: RecognizedTextDocument? {
        didSet {
            clearSelection(); needsDisplay = true; window?.invalidateCursorRects(for: self)
            setAccessibilityValue(document?.text ?? "")
            setAccessibilityNumberOfCharacters(document?.text.utf16.count ?? 0)
        }
    }
    var imageRect: CGRect = .zero { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onExit: (() -> Void)?
    var onAnnotate: (() -> Void)?
    private(set) var selectedRange: NSRange?
    private(set) var isDraggingText = false
    private var anchorUnit: Int?
    private var keyboardAnchor: Int?
    private var keyboardFocus: Int?
    private var mouseDownLocation: CGPoint?
    private var pendingExistingSelectionDrag = false
    private var selectionMenu: NSMenu?
    var selectedText: String { document.flatMap { document in selectedRange.map { document.substring($0) } } ?? "" }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("图片中的可选文字")
        toolTip = "拖动选择词句；⌘C 复制，拖动已选文字到其他应用；Shift + 方向键微调；Esc 退出"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let document else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), let normalized = normalized(local), document.unit(at: normalized) != nil else { return nil }
        return self
    }
    private func normalized(_ point: CGPoint) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        return CGPoint(x: (point.x - imageRect.minX) / imageRect.width, y: (point.y - imageRect.minY) / imageRect.height)
    }
    private func normalized(_ event: NSEvent) -> CGPoint? { normalized(convert(event.locationInWindow, from: nil)) }
    private func path(_ quad: RecognizedTextQuad) -> NSBezierPath {
        let path = NSBezierPath(), points = quad.points(in: imageRect)
        if let first = points.first { path.move(to: first); points.dropFirst().forEach { path.line(to: $0) }; path.close() }
        return path
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        for unit in document.units where unit.quad.bounds.intersects(normalizedRect(dirtyRect)) {
            let outline = path(unit.quad)
            let selected = selectedRange.map { NSIntersectionRange($0, unit.range).length > 0 } ?? false
            if selected { NSColor.selectedTextBackgroundColor.withAlphaComponent(0.36).setFill(); outline.fill() }
            NSColor.controlAccentColor.withAlphaComponent(selected ? 0.85 : 0.28).setStroke()
            outline.lineWidth = selected ? 1 : 0.65; outline.stroke()
        }
    }
    private func normalizedRect(_ rect: CGRect) -> CGRect {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - imageRect.minX) / imageRect.width, y: (rect.minY - imageRect.minY) / imageRect.height,
                      width: rect.width / imageRect.width, height: rect.height / imageRect.height)
    }
    override func resetCursorRects() {
        guard !isHidden, let document else { return }
        for unit in document.units {
            let box = unit.quad.bounds
            let rect = CGRect(x: imageRect.minX + box.minX * imageRect.width, y: imageRect.minY + box.minY * imageRect.height,
                              width: box.width * imageRect.width, height: box.height * imageRect.height).intersection(visibleRect)
            if !rect.isEmpty { addCursorRect(rect, cursor: .iBeam) }
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let document, let point = normalized(event), let index = document.unit(at: point) else { return menu }
        if selectedRange.map({ NSIntersectionRange($0, document.units[index].range).length > 0 }) != true {
            select(document.units[index].range)
        }
        let result = NSMenu()
        let copy = result.addItem(withTitle: "复制所选文字", action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self; copy.keyEquivalentModifierMask = [.command]
        let all = result.addItem(withTitle: "选择全部文字", action: #selector(selectAll(_:)), keyEquivalent: "a")
        all.target = self; all.keyEquivalentModifierMask = [.command]
        result.addItem(.separator())
        if let menu { for item in menu.items { if let item = item.copy() as? NSMenuItem { result.addItem(item) } } }
        selectionMenu = result
        return result
    }
    override func mouseDown(with event: NSEvent) {
        guard let document, let point = normalized(event), let index = document.unit(at: point) else { return }
        window?.makeKey(); window?.makeFirstResponder(self)
        mouseDownLocation = convert(event.locationInWindow, from: nil); anchorUnit = index
        pendingExistingSelectionDrag = false
        let unit = document.units[index]
        if event.clickCount >= 3, document.lines.indices.contains(unit.lineIndex) {
            select(document.lines[unit.lineIndex].range); return
        }
        if event.modifierFlags.contains(.shift), let old = selectedRange {
            let start = min(old.location, unit.range.location), end = max(NSMaxRange(old), NSMaxRange(unit.range))
            select(NSRange(location: start, length: end - start)); return
        }
        if event.clickCount == 1, let selectedRange, NSIntersectionRange(selectedRange, unit.range).length > 0 {
            pendingExistingSelectionDrag = true; return
        }
        select(unit.range)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let document, !isDraggingText, let anchorUnit, let point = normalized(event) else { return }
        if pendingExistingSelectionDrag, let down = mouseDownLocation {
            let now = convert(event.locationInWindow, from: nil)
            guard hypot(now.x - down.x, now.y - down.y) >= 4 else { return }
            pendingExistingSelectionDrag = false
            guard let item = draggingItem(at: down) else { return }
            isDraggingText = true; startTextDrag(item, event: event)
            return
        }
        guard let index = document.nearestUnit(to: point, imageSize: imageRect.size),
              let range = document.selection(from: anchorUnit, through: index) else { return }
        select(range); autoscroll(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        // A click on a selection keeps it available for a subsequent native drag.
        anchorUnit = nil; mouseDownLocation = nil; pendingExistingSelectionDrag = false
    }
    /// Kept as one narrow override point for event fixtures. Production always uses AppKit DnD.
    func startTextDrag(_ item: NSDraggingItem, event: NSEvent) {
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }
    func draggingItem(at point: CGPoint) -> NSDraggingItem? {
        let text = selectedText
        guard !text.isEmpty else { return nil }
        let item = NSDraggingItem(pasteboardWriter: text as NSString)
        // A bounded preview; the pasteboard always contains the full exact selected substring.
        let preview = String(text.prefix(100)).replacingOccurrences(of: "\n", with: " ↵ ")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let measured = (preview as NSString).size(withAttributes: attributes)
        let size = NSSize(width: min(420, max(36, measured.width + 16)), height: 28)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 5, yRadius: 5).fill()
        (preview as NSString).draw(in: NSRect(x: 8, y: 5, width: size.width - 16, height: 18), withAttributes: attributes)
        image.unlockFocus()
        item.setDraggingFrame(NSRect(x: point.x, y: point.y - size.height / 2, width: size.width, height: size.height), contents: image)
        return item
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { finishDragging() }
    func finishDragging() {
        isDraggingText = false; pendingExistingSelectionDrag = false; anchorUnit = nil; mouseDownLocation = nil
    }
    func clearSelection() {
        selectedRange = nil; keyboardAnchor = nil; keyboardFocus = nil; finishDragging(); needsDisplay = true
        setAccessibilitySelectedText(nil)
    }
    func select(_ range: NSRange) {
        guard let document, range.location >= 0, range.length >= 0, range.location <= document.text.utf16.count,
              range.length <= document.text.utf16.count - range.location,
              document.boundaries.contains(range.location), document.boundaries.contains(NSMaxRange(range)) else { return }
        selectedRange = range; keyboardAnchor = range.location; keyboardFocus = NSMaxRange(range); needsDisplay = true
        setAccessibilitySelectedText(document.substring(range))
        setAccessibilitySelectedTextRange(range)
    }
    @objc func copy(_ sender: Any?) { copySelection(to: .general) }
    @discardableResult func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard !selectedText.isEmpty else { return false }
        pasteboard.clearContents(); return pasteboard.setString(selectedText, forType: .string)
    }
    override func selectAll(_ sender: Any?) {
        guard let document else { return }; select(NSRange(location: 0, length: document.text.utf16.count))
    }
    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }
    @discardableResult func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 53 { onExit?(); return true }
        if flags.intersection([.command, .control, .option]).isEmpty, event.keyCode == 49 { onAnnotate?(); return true }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "t" { onExit?(); return true }
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "c" { copy(nil); return true }
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(nil); return true }
        guard let document, [123, 124].contains(event.keyCode), !flags.contains(.control), !flags.contains(.option) else { return false }
        let isLeft = event.keyCode == 123, extending = flags.contains(.shift)
        let old = selectedRange ?? NSRange(location: isLeft ? document.text.utf16.count : 0, length: 0)
        let focus = keyboardFocus ?? (isLeft ? old.location : NSMaxRange(old))
        let target: Int
        if flags.contains(.command) { target = isLeft ? 0 : document.text.utf16.count }
        else if !extending, old.length > 0 { target = isLeft ? old.location : NSMaxRange(old) }
        else { target = isLeft ? document.boundary(before: focus) : document.boundary(after: focus) }
        let anchor = extending ? (keyboardAnchor ?? old.location) : target
        selectedRange = NSRange(location: min(anchor, target), length: abs(target - anchor))
        keyboardAnchor = anchor; keyboardFocus = target; needsDisplay = true
        setAccessibilitySelectedText(selectedText)
        if let selectedRange { setAccessibilitySelectedTextRange(selectedRange) }
        return true
    }
    func releaseResources() {
        document = nil; selectionMenu = nil; menu = nil; onExit = nil; onAnnotate = nil
        window?.invalidateCursorRects(for: self)
    }
}
