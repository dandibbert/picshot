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
        // Clamp the whole two-row group, never each row separately. For a truly
        // tiny viewport there is no second row until room becomes available.
        let room = max(0, available.height - margin * 2)
        let paletteHeight = toolbarHeight + gap + paletteSize.height <= room ? paletteSize.height : 0
        let groupHeight = toolbarHeight + (paletteHeight > 0 ? gap + paletteHeight : 0)
        let above = selection.minY - gap - groupHeight < available.minY + margin
        let proposedBottom = above ? selection.maxY + gap : selection.minY - gap - groupHeight
        let bottom = max(available.minY + margin, min(proposedBottom, available.maxY - margin - groupHeight))
        let toolbarY = above ? bottom : bottom + (paletteHeight > 0 ? paletteHeight + gap : 0)
        let toolbar = CGRect(x: x, y: toolbarY, width: width, height: toolbarHeight)
        let paletteX = max(available.minX + margin, min(x + activeToolOffset - 22, available.maxX - margin - paletteWidth))
        let paletteY = above ? toolbar.maxY + gap : bottom
        return Frames(toolbar: toolbar,
                      palette: CGRect(x: paletteX, y: paletteY, width: paletteWidth, height: paletteHeight),
                      isAbove: above)
    }

    static func dimensionLabelFrame(selection: CGRect, available: CGRect, size: CGSize, avoiding controls: [CGRect]) -> CGRect {
        let maximumControlY = controls.map(\.maxY).max() ?? selection.maxY
        let candidates = [
            CGRect(x: selection.minX + 4, y: selection.maxY + 7, width: size.width, height: size.height),
            CGRect(x: selection.minX - size.width - 8, y: selection.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: selection.maxX + 8, y: selection.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: selection.minX + 4, y: maximumControlY + 7, width: size.width, height: size.height),
            CGRect(x: selection.minX + 4, y: selection.minY - size.height - 7, width: size.width, height: size.height),
            CGRect(x: selection.minX + 8, y: selection.maxY - size.height - 8, width: size.width, height: size.height),
            CGRect(x: available.minX + 8, y: available.minY + 8, width: size.width, height: size.height),
            CGRect(x: available.maxX - size.width - 8, y: available.maxY - size.height - 8, width: size.width, height: size.height),
            CGRect(x: available.maxX - size.width - 8, y: available.minY + 8, width: size.width, height: size.height)
        ]
        let inset = available.insetBy(dx: 4, dy: 4)
        for frame in candidates where inset.contains(frame) && !controls.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(frame) }) { return frame }
        // A full-screen capture has no outside label band. The label is a real
        // top-level overlay, so placing it inside the selected pixels stays legible.
        let y = max(inset.minY, min(selection.maxY - size.height - 8, inset.maxY - size.height))
        let x = max(inset.minX, min(selection.minX + 8, inset.maxX - size.width))
        return CGRect(x: x, y: y, width: min(size.width, inset.width), height: size.height)

    }
}

@MainActor
class EditorFloatingSurface: NSStackView {
    static let symbolPointSize: CGFloat = 18
    static let ink = NSColor(name: NSColor.Name("PicShotEditorInk")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 0.96, alpha: 1) : NSColor(calibratedWhite: 0.10, alpha: 1)
    }
    var isDarkSurface: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.cornerRadius = 7; layer?.borderWidth = 0.7
        shadow = NSShadow(); shadow?.shadowBlurRadius = 9; shadow?.shadowOffset = NSSize(width: 0, height: -2)
        refreshSurface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshSurface() }
    func refreshSurface() {
        let dark = isDarkSurface
        layer?.backgroundColor = NSColor(calibratedWhite: dark ? 0.17 : 0.99, alpha: 1).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.16)).cgColor
        shadow?.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.44 : 0.24)
        needsDisplay = true
    }
}

struct PinEditorPresentation {
    let viewportFrame: CGRect
    let imageFrame: CGRect
    let opacity: CGFloat
    let level: NSWindow.Level
}

enum EditorBoundaryHandle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    func point(in frame: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .top: return CGPoint(x: frame.midX, y: frame.maxY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.minY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        }
    }
    static func hit(at point: CGPoint, frame: CGRect, tolerance: CGFloat = 7) -> EditorBoundaryHandle? {
        allCases.min { hypot($0.point(in: frame).x - point.x, $0.point(in: frame).y - point.y) < hypot($1.point(in: frame).x - point.x, $1.point(in: frame).y - point.y) }
            .flatMap { hypot($0.point(in: frame).x - point.x, $0.point(in: frame).y - point.y) <= tolerance ? $0 : nil }
    }
    func resized(_ original: CGRect, to point: CGPoint, in bounds: CGRect) -> CGRect {
        var left = original.minX, right = original.maxX, bottom = original.minY, top = original.maxY
        if [.topLeft, .bottomLeft, .left].contains(self) { left = max(bounds.minX, min(point.x, right - 2)) }
        if [.topRight, .bottomRight, .right].contains(self) { right = min(bounds.maxX, max(point.x, left + 2)) }
        if [.bottomLeft, .bottom, .bottomRight].contains(self) { bottom = max(bounds.minY, min(point.y, top - 2)) }
        if [.topLeft, .top, .topRight].contains(self) { top = min(bounds.maxY, max(point.y, bottom + 2)) }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

/// One crop-sized allocation at commit; dragging only reuses immutable images.
/// The old base patch preserves any edits already rasterized by the crop tool.
enum EditorBoundaryRenderer {
    static func alignedFrame(_ requested: CGRect, presentation: FrozenCapturePresentation) throws -> CGRect {
        let geometry = try FrozenCaptureGeometry(pointSize: presentation.displayFrame.size,
            pixelWidth: presentation.frozenImage.width, pixelHeight: presentation.frozenImage.height)
        let topLeft = CGRect(x: requested.minX, y: presentation.displayFrame.height - requested.maxY,
                             width: requested.width, height: requested.height)
        return try geometry.alignedSelection(topLeft).selectionFrame
    }
    static func recrop(_ requested: CGRect, presentation: FrozenCapturePresentation, previousImage: CGImage) throws -> CapturedImage {
        let source = presentation.frozenImage
        let geometry = try FrozenCaptureGeometry(pointSize: presentation.displayFrame.size, pixelWidth: source.width, pixelHeight: source.height)
        let topLeft = CGRect(x: requested.minX, y: presentation.displayFrame.height - requested.maxY, width: requested.width, height: requested.height)
        let aligned = try geometry.alignedSelection(topLeft)
        let width = Int(aligned.pixelFrame.width), height = Int(aligned.pixelFrame.height)
        guard let crop = source.cropping(to: aligned.pixelFrame),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PicShotError.message("无法调整截图区域，可能内存不足")
        }
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = annotationOffset(from: presentation.selectionFrame, to: aligned.selectionFrame, presentation: presentation)
        context.setBlendMode(.copy)
        context.draw(previousImage, in: CGRect(x: offset.width, y: offset.height, width: CGFloat(previousImage.width), height: CGFloat(previousImage.height)))
        guard let image = context.makeImage() else { throw PicShotError.message("无法完成截图区域调整") }
        return CapturedImage(image: image, presentation: FrozenCapturePresentation(frozenImage: source,
            displayID: presentation.displayID, displayFrame: presentation.displayFrame, selectionFrame: aligned.selectionFrame, capturedAt: presentation.capturedAt))
    }
    static func annotationOffset(from previous: CGRect, to next: CGRect, presentation: FrozenCapturePresentation) -> CGSize {
        CGSize(width: ((previous.minX - next.minX) * CGFloat(presentation.frozenImage.width) / presentation.displayFrame.width).rounded(),
               height: ((previous.minY - next.minY) * CGFloat(presentation.frozenImage.height) / presentation.displayFrame.height).rounded())
    }
}

@MainActor
final class EditorWorkspaceView: NSView {
    var frozenImage: CGImage?
    var transparentBackground = false { didSet { needsDisplay = true } }
    var selectionFrame: CGRect = .zero { didSet { needsDisplay = true } }
    var pixelSize: CGSize = .zero
    var onLayout: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOutsideClick: (() -> Void)?
    weak var selectionContent: NSView?
    var onBoundaryBegin: (() -> Void)?
    var onBoundaryChange: ((CGRect) -> Void)?
    var onBoundaryEnd: ((Bool) -> Void)?
    var boundaryPreviewImage: CGImage?
    var boundaryPreviewOriginalFrame: CGRect = .zero
    private var boundaryHandle: EditorBoundaryHandle?
    private var boundaryOriginalFrame: CGRect = .zero
    var isResizingBoundary: Bool { boundaryHandle != nil }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { !transparentBackground }
    override func layout() { super.layout(); onLayout?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard frozenImage != nil, onBoundaryBegin != nil else { return hit }
        // Controls above an edge keep priority over the resize handles.
        guard hit === self || (selectionContent.map { hit === $0 || hit?.isDescendant(of: $0) == true } ?? false) else { return hit }
        let local = convert(point, from: superview)
        return EditorBoundaryHandle.hit(at: local, frame: selectionFrame) == nil ? hit : self
    }
    override func resetCursorRects() {
        guard frozenImage != nil, onBoundaryBegin != nil else { return }
        for handle in EditorBoundaryHandle.allCases {
            let point = handle.point(in: selectionFrame)
            addCursorRect(CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10), cursor: .crosshair)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard frozenImage != nil, onBoundaryBegin != nil,
              let handle = EditorBoundaryHandle.hit(at: point, frame: selectionFrame) else { onOutsideClick?(); return }
        boundaryHandle = handle; boundaryOriginalFrame = selectionFrame
        window?.makeFirstResponder(self); onBoundaryBegin?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let handle = boundaryHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        onBoundaryChange?(handle.resized(boundaryOriginalFrame, to: point, in: bounds))
    }
    override func mouseUp(with event: NSEvent) {
        guard boundaryHandle != nil else { return }
        mouseDragged(with: event); boundaryHandle = nil; onBoundaryEnd?(true)
    }
    func cancelBoundaryResize() {
        guard boundaryHandle != nil else { return }
        boundaryHandle = nil; onBoundaryEnd?(false)
    }
    override func rightMouseDown(with event: NSEvent) {
        if isResizingBoundary { cancelBoundaryResize() } else { onDismiss?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if isResizingBoundary { cancelBoundaryResize() } else { onDismiss?() }
        } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let frozenImage {
            context.draw(frozenImage, in: bounds)
            NSColor.black.withAlphaComponent(0.46).setFill(); bounds.fill()
            if let preview = boundaryPreviewImage {
                context.saveGState(); context.clip(to: selectionFrame)
                context.draw(frozenImage, in: bounds)
                context.draw(preview, in: boundaryPreviewOriginalFrame)
                context.restoreGState()
            }
        } else if !transparentBackground {
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill(); bounds.fill()
        } else {
            context.clear(bounds)
        }
        guard !selectionFrame.isEmpty else { return }
        // The canvas supplies the undimmed pixels. The outline is drawn just
        // outside it so the exact source rectangle does not lose a pixel.
        let border = selectionFrame.insetBy(dx: -1, dy: -1)
        NSColor(calibratedRed: 0.20, green: 0.53, blue: 1, alpha: 1).setStroke()
        let path = NSBezierPath(rect: border); path.lineWidth = 1.5; path.stroke()
        if frozenImage != nil, onBoundaryBegin != nil {
            for x in [border.minX, border.midX, border.maxX] {
                for y in [border.minY, border.midY, border.maxY] where x != border.midX || y != border.midY {
                    let handle = NSRect(x: x - 2, y: y - 2, width: 4, height: 4)
                    let dot = NSBezierPath(ovalIn: handle)
                    NSColor.white.setFill(); dot.fill()
                    NSColor.systemBlue.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            }
        }

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
