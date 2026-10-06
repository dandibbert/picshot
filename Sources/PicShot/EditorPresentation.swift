import AppKit

/// Original AppKit layout, inspired by familiar floating capture tools. All values
/// are logical points; screenshot pixels are never reused as UI assets.
enum EditorFloatingLayout {
    static let toolbarHeight: CGFloat = 40
    static let gap: CGFloat = 8
    static let margin: CGFloat = 10

    struct Frames {
        let toolbar: CGRect
        let palette: CGRect
        let isAbove: Bool
    }

    static func frames(selection: CGRect, available: CGRect, toolbarSize: CGSize,
                       paletteSize: CGSize, activeToolOffset: CGFloat) -> Frames {
        let width = min(toolbarSize.width, max(1, available.width - margin * 2))
        let paletteWidth = min(paletteSize.width, max(1, available.width - margin * 2))
        let x = min(max(available.minX + margin, selection.maxX - width), available.maxX - margin - width)
        let requiredBelow = toolbarHeight + gap + (paletteSize.height > 0 ? paletteSize.height + gap : 0)
        let above = selection.minY - requiredBelow < available.minY + margin
        var y = above ? selection.maxY + gap : selection.minY - gap - toolbarHeight
        y = max(available.minY + margin, min(y, available.maxY - margin - toolbarHeight))
        let toolbar = CGRect(x: x, y: y, width: width, height: toolbarHeight)
        let paletteX = max(available.minX + margin, min(x + activeToolOffset - 22, available.maxX - margin - paletteWidth))
        var paletteY = above ? toolbar.maxY + gap : toolbar.minY - gap - paletteSize.height
        // Near a screen edge, keep every control reachable even when it must sit
        // over a small part of the capture. Never move the capture to make room.
        paletteY = max(available.minY + margin, min(paletteY, available.maxY - margin - paletteSize.height))
        return Frames(toolbar: toolbar,
                      palette: CGRect(x: paletteX, y: paletteY, width: paletteWidth, height: paletteSize.height),
                      isAbove: above)
    }
}

@MainActor
final class EditorWorkspaceView: NSView {
    var frozenImage: CGImage?
    var selectionFrame: CGRect = .zero { didSet { needsDisplay = true } }
    var pixelSize: CGSize = .zero
    var onLayout: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOutsideClick: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func mouseDown(with event: NSEvent) { onOutsideClick?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let frozenImage {
            context.draw(frozenImage, in: bounds)
            NSColor.black.withAlphaComponent(0.46).setFill(); bounds.fill()
        } else {
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill(); bounds.fill()
        }
        guard !selectionFrame.isEmpty else { return }
        // The canvas supplies the undimmed pixels. The outline is drawn just
        // outside it so the exact source rectangle does not lose a pixel.
        let border = selectionFrame.insetBy(dx: -1, dy: -1)
        NSColor(calibratedRed: 0.20, green: 0.53, blue: 1, alpha: 1).setStroke()
        let path = NSBezierPath(rect: border); path.lineWidth = 1.5; path.stroke()
        if frozenImage != nil {
            for x in [border.minX, border.midX, border.maxX] {
                for y in [border.minY, border.midY, border.maxY] where x != border.midX || y != border.midY {
                    let handle = NSRect(x: x - 2, y: y - 2, width: 4, height: 4)
                    NSColor.white.setFill(); handle.fill(); path.lineWidth = 1
                    NSBezierPath(rect: handle).stroke()
                }
            }
        }
        let value = "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px"
        let textY = min(bounds.maxY - 23, selectionFrame.maxY + 8)
        (value as NSString).draw(at: CGPoint(x: selectionFrame.minX + 4, y: textY),
                                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                 .foregroundColor: NSColor.white])
    }
}

@MainActor
final class EditorOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Canvas-local text input. Escape cancels; Command-Return accepts; Return inserts
/// a newline. The text is committed once, producing one undo snapshot.
@MainActor
final class InlineAnnotationTextView: NSTextView {
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) { onAccept?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
final class InlineAnnotationTextBox: NSView {
    let input = InlineAnnotationTextView(frame: .zero)
    private let accept = NSButton()
    private let cancel = NSButton()
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    private var resizeOrigin: CGPoint?
    private var initialFrame: CGRect = .zero
    private(set) var wasResized = false
    init(frame: CGRect, annotation: ImageAnnotation, zoom: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true; layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 0.20, green: 0.53, blue: 1, alpha: 1).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        input.identifier = NSUserInterfaceItemIdentifier("annotation.textInput")
        input.isRichText = false; input.allowsUndo = true
        input.isHorizontallyResizable = false; input.isVerticallyResizable = false
        input.autoresizingMask = [.width, .height]
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.heightTracksTextView = true
        input.textContainer?.lineFragmentPadding = 0
        input.textContainerInset = NSSize(width: 3, height: 2)
        applyStyle(annotation, zoom: zoom); input.string = annotation.text
        input.setAccessibilityLabel("图上编辑文字；Command Return 完成，Escape 取消")
        input.onAccept = { [weak self] in self?.onAccept?() }
        input.onCancel = { [weak self] in self?.onCancel?() }
        addSubview(input)
        for (button, symbol, title, action) in [(accept, "checkmark", "完成文字 · ⌘Return", #selector(acceptText)), (cancel, "xmark", "取消文字 · Escape", #selector(cancelText))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageOnly; button.bezelStyle = .regularSquare; button.isBordered = false
            button.contentTintColor = .white; button.wantsLayer = true
            button.layer?.backgroundColor = (button === cancel ? NSColor.systemRed : NSColor.systemBlue).cgColor
            button.target = self; button.action = action; button.toolTip = title
            button.setAccessibilityLabel(title); addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyStyle(_ annotation: ImageAnnotation, zoom: CGFloat) {
        input.drawsBackground = annotation.fillEnabled
        input.backgroundColor = NSColor(cgColor: annotation.fillColor) ?? .white
        input.textColor = NSColor(cgColor: annotation.color) ?? .systemRed
        var font = NSFont(name: annotation.fontName, size: annotation.effectiveFontSize * zoom) ?? .systemFont(ofSize: annotation.effectiveFontSize * zoom)
        if annotation.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if annotation.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        input.font = font
        input.typingAttributes[.underlineStyle] = annotation.underline ? NSUnderlineStyle.single.rawValue : 0
        if input.string.utf16.count > 0 {
            input.textStorage?.addAttribute(.underlineStyle, value: annotation.underline ? NSUnderlineStyle.single.rawValue : 0, range: NSRange(location: 0, length: input.string.utf16.count))
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if CGRect(x: bounds.maxX - 10, y: 0, width: 10, height: 10).contains(local) { return self }
        return super.hitTest(point)
    }
    override func resetCursorRects() { addCursorRect(CGRect(x: bounds.maxX - 10, y: 0, width: 10, height: 10), cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        resizeOrigin = event.locationInWindow; initialFrame = frame
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = resizeOrigin, let parent = superview else { return }
        let dx = event.locationInWindow.x - origin.x, dy = event.locationInWindow.y - origin.y
        let width = min(max(80, initialFrame.width + dx), parent.bounds.maxX - initialFrame.minX)
        let bottom = min(initialFrame.maxY - 38, max(parent.bounds.minY, initialFrame.minY + dy))
        frame = CGRect(x: initialFrame.minX, y: bottom, width: width, height: initialFrame.maxY - bottom)
        wasResized = true; needsLayout = true
    }
    override func mouseUp(with event: NSEvent) { resizeOrigin = nil }
    override func layout() {
        super.layout()
        input.frame = bounds.insetBy(dx: 3, dy: 3)
        accept.frame = NSRect(x: 0, y: bounds.height - 16, width: 16, height: 16)
        cancel.frame = NSRect(x: bounds.width - 16, y: bounds.height - 16, width: 16, height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0)] {
            NSRect(x: point.x - 2, y: point.y - 2, width: 5, height: 5).fill()
        }
    }
    @objc private func acceptText() { onAccept?() }
    @objc private func cancelText() { onCancel?() }
}
