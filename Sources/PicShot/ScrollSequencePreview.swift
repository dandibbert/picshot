import AppKit
import PicShotCore

/// A compact stitched preview: click a source block or drag any axis band while trimming.
/// The pop-up and exact start/length fields remain accessible alternatives for tiny strips.
@MainActor
final class ScrollSequencePreview: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var layout: ScrollSequenceLayout? { didSet { needsDisplay = true } }
    var axis: ScrollAxis = .vertical
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var selectedRange: Range<Int>? { didSet { needsDisplay = true } }
    private var dragAnchor: Int?
    var allowsSelection = false
    var onSelect: ((UUID) -> Void)?
    var onDelete: (() -> Void)?
    var onBandSelect: ((Range<Int>) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { allowsSelection }

    var imageRect: CGRect {
        guard let layout else { return .zero }
        let available = bounds.insetBy(dx: 5, dy: 5)
        guard available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / CGFloat(layout.width), available.height / CGFloat(layout.height))
        let size = CGSize(width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func block(at point: CGPoint) -> UUID? {
        guard allowsSelection, let layout, imageRect.contains(point) else { return nil }
        let rect = imageRect
        let fraction = axis == .vertical ? (point.y - rect.minY) / rect.height : (point.x - rect.minX) / rect.width
        let pixel = Int(fraction * CGFloat(axis == .vertical ? layout.height : layout.width))
        return layout.strips.first { pixel >= $0.outputStart && pixel < $0.outputStart + $0.block.length }?.block.id
    }

    override func mouseDown(with event: NSEvent) {
        guard let id = block(at: convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        selectedRange = nil
        dragAnchor = pixel(at: convert(event.locationInWindow, from: nil))
        selectedID = id; onSelect?(id)
    }
    override func mouseDragged(with event: NSEvent) {
        guard allowsSelection, let start = dragAnchor, let end = pixel(at: convert(event.locationInWindow, from: nil)),
              start != end else { return }
        let range = min(start, end)..<(max(start, end) + 1)
        selectedRange = range; selectedID = nil; onBandSelect?(range)
    }
    override func mouseUp(with event: NSEvent) { dragAnchor = nil }
    private func pixel(at point: CGPoint) -> Int? {
        guard let layout else { return nil }
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let length = axis == .vertical ? layout.height : layout.width
        let fraction = axis == .vertical ? (point.y - rect.minY) / rect.height : (point.x - rect.minX) / rect.width
        return min(length - 1, max(0, Int(fraction * CGFloat(length))))
    }
    override func keyDown(with event: NSEvent) {
        if allowsSelection && (event.keyCode == 51 || event.keyCode == 117) { onDelete?() }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard let image, let layout else { return }
        let rect = imageRect
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard allowsSelection else { return }
        let scale = axis == .vertical ? rect.height / CGFloat(layout.height) : rect.width / CGFloat(layout.width)
        for strip in layout.strips {
            let area = axis == .vertical
                ? CGRect(x: rect.minX, y: rect.minY + CGFloat(strip.outputStart) * scale,
                         width: rect.width, height: CGFloat(strip.block.length) * scale)
                : CGRect(x: rect.minX + CGFloat(strip.outputStart) * scale, y: rect.minY,
                         width: CGFloat(strip.block.length) * scale, height: rect.height)
            let selected = strip.block.id == selectedID
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            let path = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = selected ? 2 : 1; path.stroke()
            if selected { NSColor.controlAccentColor.withAlphaComponent(0.16).setFill(); NSBezierPath(rect: area).fill() }
        }
        if let selectedRange {
            let band = axis == .vertical
                ? CGRect(x: rect.minX, y: rect.minY + CGFloat(selectedRange.lowerBound) * scale,
                         width: rect.width, height: CGFloat(selectedRange.count) * scale)
                : CGRect(x: rect.minX + CGFloat(selectedRange.lowerBound) * scale, y: rect.minY,
                         width: CGFloat(selectedRange.count) * scale, height: rect.height)
            NSColor.systemRed.withAlphaComponent(0.26).setFill(); NSBezierPath(rect: band).fill()
            NSColor.systemRed.setStroke(); let outline = NSBezierPath(rect: band); outline.lineWidth = 2; outline.stroke()
        }
    }
}
