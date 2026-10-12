import AppKit

/// A small real mouse target attached to the capture frame. The surrounding
/// outline stays click-through, so scrolling the page is never intercepted.
@MainActor
final class LiveScrollRegionDragHandle: NSView {
    static let preferredSize = CGSize(width: 64, height: 26)
    var begin: ((CGPoint) -> Bool)?
    var move: ((CGPoint) -> Void)?
    var end: ((CGPoint?) -> Void)?
    var isEnabled = true {
        didSet { setAccessibilityEnabled(isEnabled); needsDisplay = true }
    }
    private(set) var isDragging = false
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = .init("scroll.live.moveHandle.surface")
        toolTip = "拖动以移动选区；按 Esc 取消。捕获中沿滚动方向移动，暂停后可自由移动"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("拖动移动截图选区")
        setAccessibilityHelp(toolTip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, alphaValue > 0,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isDragging, let point = screenPoint(event) else { return }
        isDragging = true
        guard begin?(point) == true else { stopTracking(); return }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let point = screenPoint(event) else { return }
        move?(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        let point = screenPoint(event)
        stopTracking()
        end?(point)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        guard isDragging else { return }
        stopTracking()
        end?(nil)
    }

    func stopTracking() {
        isDragging = false
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func retire() {
        stopTracking(); begin = nil; move = nil; end = nil; isEnabled = false
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint? {
        guard let window else { return nil }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLiveScrollSurface(bounds, appearance: effectiveAppearance)
        let color = isEnabled ? NSColor.labelColor : .disabledControlTextColor
        // Direct strokes resolve labelColor in this view's current appearance;
        // drawing an untinted template NSImage left a black glyph in dark mode.
        let glyph = CGRect(x: 7, y: 6, width: 14, height: 14)
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: glyph.minX + 1, y: glyph.midY))
        arrow.line(to: CGPoint(x: glyph.maxX - 1, y: glyph.midY))
        arrow.move(to: CGPoint(x: glyph.midX, y: glyph.minY + 1))
        arrow.line(to: CGPoint(x: glyph.midX, y: glyph.maxY - 1))
        for (tip, first, second) in [
            (CGPoint(x: glyph.minX + 1, y: glyph.midY), CGPoint(x: glyph.minX + 4, y: glyph.midY - 3), CGPoint(x: glyph.minX + 4, y: glyph.midY + 3)),
            (CGPoint(x: glyph.maxX - 1, y: glyph.midY), CGPoint(x: glyph.maxX - 4, y: glyph.midY - 3), CGPoint(x: glyph.maxX - 4, y: glyph.midY + 3)),
            (CGPoint(x: glyph.midX, y: glyph.minY + 1), CGPoint(x: glyph.midX - 3, y: glyph.minY + 4), CGPoint(x: glyph.midX + 3, y: glyph.minY + 4)),
            (CGPoint(x: glyph.midX, y: glyph.maxY - 1), CGPoint(x: glyph.midX - 3, y: glyph.maxY - 4), CGPoint(x: glyph.midX + 3, y: glyph.maxY - 4))
        ] {
            arrow.move(to: first); arrow.line(to: tip); arrow.line(to: second)
        }
        color.setStroke(); arrow.lineWidth = 1.2
        arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        ("移动" as NSString).draw(in: CGRect(x: 27, y: 5, width: 30, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}
