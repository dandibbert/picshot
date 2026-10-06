import AppKit
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// All annotation coordinates are image pixels, with the origin at the bottom left.
enum ImageEditorTool: String, CaseIterable {
    case select, rectangle, ellipse, arrow, line, freehand, text, number, highlighter, redact, blur, pixelate, crop

    var title: String {
        switch self {
        case .select: return "选择"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .freehand: return "画笔"
        case .text: return "文字"
        case .number: return "序号"
        case .highlighter: return "高亮"
        case .redact: return "遮盖"
        case .blur: return "模糊"
        case .pixelate: return "马赛克"
        case .crop: return "裁剪"
        }
    }
}

struct ImageAnnotation {
    var id = UUID()
    var tool: ImageEditorTool
    var points: [CGPoint]
    var color: CGColor = CGColor(srgbRed: 1, green: 0.23, blue: 0.24, alpha: 1)
    var lineWidth: CGFloat = 4
    var text = ""
    var number = 1
    /// Radians counterclockwise around localBounds' center. Image coordinates are y-up.
    var rotation: CGFloat = 0
    var opacity: CGFloat = 1
    var strokeStyle: AnnotationStrokeStyle = .solid
    var fillEnabled = false
    var fillColor: CGColor = CGColor(srgbRed: 1, green: 0.91, blue: 0.52, alpha: 1)
    var cornerRadius: CGFloat = 0
    var fontName = "Helvetica"
    var fontSize: CGFloat? = nil
    var bold = false
    var italic = false
    var underline = false
    /// Optional explicit box; text wraps to its width and remains clipped to its height.
    var textBoxSize: CGSize? = nil

    var localBounds: CGRect {
        guard let first = points.first else { return .zero }
        if tool == .text {
            return CGRect(origin: first, size: AnnotationTextLayout.size(for: self))
        }
        if tool == .number {
            let radius = max(14, lineWidth * 4)
            return CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let x = xs.min() ?? first.x, y = ys.min() ?? first.y
        return CGRect(x: x, y: y, width: (xs.max() ?? x) - x, height: (ys.max() ?? y) - y)
    }

    var bounds: CGRect { localBounds.applying(transform) }

    var transform: CGAffineTransform {
        let box = localBounds
        return CGAffineTransform(translationX: box.midX, y: box.midY)
            .rotated(by: rotation).translatedBy(x: -box.midX, y: -box.midY)
    }

    func translated(by delta: CGSize) -> ImageAnnotation {
        var result = self
        result.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return result
    }
}

/// Produces only raster pixels. Exports never contain editable annotations or source-image layers.
enum ImageEditorRenderer {
    static let maximumRasterPixels = 100_000_000
    private static let filterContext = CIContext(options: [.cacheIntermediates: false])

    static func allowsRasterSize(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= Int.max / 4 else { return false }
        let product = width.multipliedReportingOverflow(by: height)
        return !product.overflow && product.partialValue <= maximumRasterPixels
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard allowsRasterSize(width: width, height: height) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    static func render(image: CGImage, annotations: [ImageAnnotation]) -> CGImage? {
        guard let context = makeContext(width: image.width, height: image.height) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        context.draw(image, in: extent)
        for annotation in annotations {
            context.saveGState()
            // Obscuring pixels is a security boundary: redaction ignores both color alpha
            // and global opacity. Blur and pixelation remain cosmetic effects only.
            context.setAlpha(annotation.tool == .redact ? 1 : min(1, max(0, annotation.opacity)))
            context.setStrokeColor(annotation.color)
            context.setFillColor(annotation.color)
            context.setLineWidth(max(1, annotation.lineWidth))
            context.setLineCap(.round); context.setLineJoin(.round)
            context.setLineDash(phase: 0, lengths: annotation.strokeStyle.pattern(width: annotation.lineWidth))
            if annotation.tool == .blur || annotation.tool == .pixelate {
                let region = annotation.bounds.integral.intersection(extent)
                if !region.isEmpty, let snapshot = context.makeImage() {
                    let input = CIImage(cgImage: snapshot)
                    let filtered: CIImage
                    if annotation.tool == .blur {
                        filtered = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(8, annotation.lineWidth * 3)])
                    } else {
                        filtered = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, annotation.lineWidth * 4), kCIInputCenterKey: CIVector(x: 0, y: 0)])
                    }
                    if let patch = filterContext.createCGImage(filtered.cropped(to: region), from: region) {
                        var transform = annotation.transform
                        if let clip = annotation.outline.copy(using: &transform) { context.addPath(clip); context.clip() }
                        context.interpolationQuality = .none; context.draw(patch, in: region)
                    }
                }
                context.restoreGState(); continue
            }
            context.concatenate(annotation.transform)
            let rect = annotation.localBounds.standardized
            switch annotation.tool {
            case .select, .crop, .blur, .pixelate: break
            case .rectangle, .ellipse:
                if annotation.fillEnabled {
                    context.setFillColor(annotation.fillColor); context.addPath(annotation.outline); context.fillPath()
                }
                context.addPath(annotation.outline); context.strokePath()
            case .redact:
                context.setFillColor(annotation.color.copy(alpha: 1) ?? CGColor(gray: 0, alpha: 1))
                context.setShouldAntialias(false); context.fill(rect.integral)
            case .highlighter:
                context.setFillColor(annotation.color.copy(alpha: 0.32) ?? annotation.color); context.fill(rect)
            case .line, .arrow, .freehand:
                context.addPath(annotation.strokePath); context.strokePath()
            case .text:
                if annotation.fillEnabled {
                    context.setFillColor(annotation.fillColor); context.addPath(annotation.outline); context.fillPath()
                }
                AnnotationTextLayout.draw(annotation, context: context)
            case .number:
                context.fillEllipse(in: rect)
                let value = String(annotation.number)
                let fontSize = rect.height * 0.58
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                drawText(value, point: CGPoint(x: rect.midX - width / 2, y: rect.midY - fontSize * 0.37), size: fontSize, color: CGColor(gray: 1, alpha: 1), context: context, bold: true)
            }
            context.restoreGState()
        }
        return context.makeImage()
    }

    private static func drawText(_ text: String, point: CGPoint, size: CGFloat, color: CGColor, context: CGContext, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }

    static func crop(image: CGImage, to requested: CGRect) -> CGImage? {
        let rect = requested.standardized.integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard rect.width >= 1, rect.height >= 1,
              let context = makeContext(width: Int(rect.width), height: Int(rect.height)) else { return nil }
        // A CGImage subimage may retain the entire original backing store. Materialize
        // the crop so history accounting reflects the bytes actually kept alive.
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    static func makeSampleImage() -> CGImage {
        let context = makeContext(width: 960, height: 600)!
        context.setFillColor(CGColor(srgbRed: 0.09, green: 0.12, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 600))
        context.setFillColor(CGColor(srgbRed: 0.20, green: 0.72, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 64, y: 92, width: 360, height: 300))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.67, blue: 0.25, alpha: 1))
        context.fillEllipse(in: CGRect(x: 550, y: 180, width: 250, height: 250))
        drawText("PicShot", point: CGPoint(x: 64, y: 478), size: 54, color: CGColor(gray: 1, alpha: 1), context: context, bold: true)
        drawText("Capture. Annotate. Share.", point: CGPoint(x: 64, y: 432), size: 24, color: CGColor(gray: 0.85, alpha: 1), context: context)
        return context.makeImage()!
    }
}

/// Estimates retained raster storage once per image identity, rather than once
/// per annotation snapshot. The newest state is retained even if it alone is large.
enum ImageEditorHistoryBudget {
    static let maximumBytes = 256 * 1024 * 1024
    static let maximumSnapshots = 100

    static func retainedSuffixStart(images: [CGImage], maximumBytes: Int = ImageEditorHistoryBudget.maximumBytes,
                                    maximumSnapshots: Int = ImageEditorHistoryBudget.maximumSnapshots) -> Int {
        let budget = max(0, maximumBytes)
        var identities = Set<ObjectIdentifier>()
        var retainedBytes = 0
        var start = images.count
        for index in images.indices.reversed() {
            let image = images[index]
            let identity = ObjectIdentifier(image)
            let product = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
            let bytes = identities.contains(identity) ? 0 : (product.overflow ? Int.max : product.partialValue)
            if start < images.count {
                if images.count - index > max(1, maximumSnapshots) { break }
                if bytes > max(0, budget - retainedBytes) { break }
            }
            identities.insert(identity)
            let sum = retainedBytes.addingReportingOverflow(bytes)
            retainedBytes = sum.overflow ? Int.max : sum.partialValue
            start = index
        }
        return start
    }
}

@MainActor
final class ImageEditorCanvas: NSView {
    var image: CGImage
    var annotations: [ImageAnnotation] = []
    var tool: ImageEditorTool = .arrow { didSet { cancelInteraction(); cropRect = nil; needsDisplay = true } }
    var style = ImageAnnotation(tool: .arrow, points: [], color: NSColor.systemRed.cgColor, fontSize: 20)
    var color: CGColor { get { style.color } set { style.color = newValue } }
    var strokeWidth: CGFloat { get { style.lineWidth } set { style.lineWidth = newValue } }
    var zoom: CGFloat = 1 { didSet { resizeCanvas() } }
    var verticalZoom: CGFloat?
    var displayScaleY: CGFloat { verticalZoom ?? zoom }
    var cropRect: CGRect?
    var onWillChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onRequestText: ((CGPoint, UUID?) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?
    var onCancel: (() -> Void)?
    var onBeforeInteraction: (() -> Void)?
    var editingAnnotationID: UUID? { didSet { cachedImage = nil; needsDisplay = true } }
    private var selection: UUID?
    private var draft: ImageAnnotation?
    private var dragOrigin: CGPoint?
    private var movingOriginal: ImageAnnotation?
    private var activeHandle: AnnotationHandle?
    private var didBeginMoving = false
    private var cachedImage: CGImage?
    var selectedAnnotation: ImageAnnotation? { annotations.first { $0.id == selection } }

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private func resizeCanvas() {
        setFrameSize(NSSize(width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * displayScaleY))
        needsDisplay = true
    }

    func setContent(image: CGImage, annotations: [ImageAnnotation]) {
        self.image = image; self.annotations = annotations
        selection = nil; draft = nil; cropRect = nil; cachedImage = nil
        movingOriginal = nil; dragOrigin = nil; activeHandle = nil; didBeginMoving = false
        resizeCanvas(); onChange?()
    }

    func flattened() -> CGImage? { ImageEditorRenderer.render(image: image, annotations: annotations) }

    func makeAnnotation(tool: ImageEditorTool, points: [CGPoint], text: String = "") -> ImageAnnotation {
        var result = style
        result.id = UUID(); result.tool = tool; result.points = points; result.text = text
        result.rotation = 0; result.textBoxSize = nil
        if tool == .redact { result.color = CGColor(gray: 0, alpha: 1); result.opacity = 1 }
        return result
    }

    func add(_ annotation: ImageAnnotation) {
        onWillChange?()
        annotations.append(annotation); selection = annotation.id
        changed()
    }

    private func changed() { cachedImage = nil; needsDisplay = true; onChange?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.scaleBy(x: zoom, y: displayScaleY)
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        if cachedImage == nil { cachedImage = ImageEditorRenderer.render(image: image, annotations: annotations.filter { $0.id != editingAnnotationID }) }
        let displayed = draft.flatMap { ImageEditorRenderer.render(image: cachedImage ?? image, annotations: [$0]) } ?? cachedImage ?? image
        context.draw(displayed, in: imageBounds)
        if let selected = selectedAnnotation, tool == .select { drawSelection(selected, context: context) }
        if let cropRect { drawSelectionBox(CGPath(rect: cropRect, transform: nil), context: context) }
        context.restoreGState()
    }

    private func drawSelection(_ annotation: ImageAnnotation, context: CGContext) {
        var transform = annotation.transform
        let box = CGPath(rect: annotation.localBounds, transform: &transform)
        if !annotation.isLinear { drawSelectionBox(box, context: context) }
        let handles = annotation.handles(zoom: zoom)
        if let rotate = handles.first(where: { $0.0 == .rotation })?.1 {
            let start = CGPoint(x: annotation.localBounds.midX, y: annotation.localBounds.maxY).applying(annotation.transform)
            context.saveGState(); context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / zoom)
            context.move(to: start); context.addLine(to: rotate); context.strokePath(); context.restoreGState()
        }
        for (handle, point) in handles {
            let size: CGFloat = handle == .rotation ? 9 : 7
            let rect = CGRect(x: point.x - size / (2 * zoom), y: point.y - size / (2 * zoom), width: size / zoom, height: size / zoom)
            context.saveGState(); context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1.5 / zoom)
            if handle == .rotation { context.fillEllipse(in: rect); context.strokeEllipse(in: rect) }
            else { context.fill(rect); context.stroke(rect) }
            context.restoreGState()
        }
    }

    private func drawSelectionBox(_ path: CGPath, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(3 / zoom); context.addPath(path); context.strokePath()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1.5 / zoom)
        context.setLineDash(phase: 0, lengths: [5 / zoom, 3 / zoom]); context.addPath(path); context.strokePath()
        context.restoreGState()
    }

    private func imagePoint(_ event: NSEvent, clamped: Bool = true) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / displayScaleY)
        guard clamped else { return point }
        return CGPoint(x: min(max(0, point.x), CGFloat(image.width)), y: min(max(0, point.y), CGFloat(image.height)))
    }

    override func mouseDown(with event: NSEvent) {
        onBeforeInteraction?()
        cancelInteraction()
        window?.makeFirstResponder(self)
        let point = imagePoint(event, clamped: tool != .select)
        dragOrigin = point
        if tool == .select {
            if event.clickCount != 2, let selected = selectedAnnotation, let handle = selected.handle(at: point, zoom: zoom) {
                activeHandle = handle; movingOriginal = selected
            } else {
                selection = annotations.reversed().first { $0.hitTest(point, tolerance: 6 / zoom) }?.id
                movingOriginal = selectedAnnotation
            }
            if let selected = selectedAnnotation {
                style = selected
                if event.clickCount == 2, selected.tool == .text {
                    movingOriginal = nil; onRequestText?(selected.points.first ?? point, selected.id)
                }
            }
            needsDisplay = true; onChange?()
        } else if tool == .text {
            onRequestText?(point, nil)
        } else if tool == .number {
            var annotation = makeAnnotation(tool: .number, points: [point])
            annotation.number = (annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
            add(annotation)
        } else {
            draft = makeAnnotation(tool: tool, points: [point, point]); cropRect = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event, clamped: tool != .select)
        guard let origin = dragOrigin else { return }
        if tool == .select, let original = movingOriginal, let index = annotations.firstIndex(where: { $0.id == original.id }) {
            guard didBeginMoving || hypot(point.x - origin.x, point.y - origin.y) > 1 / zoom else { return }
            didBeginMoving = true
            if let activeHandle {
                annotations[index] = original.edited(handle: activeHandle, from: origin, to: point, shift: event.modifierFlags.contains(.shift))
            } else {
                var delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
                if event.modifierFlags.contains(.shift) {
                    if abs(delta.width) > abs(delta.height) { delta.height = 0 } else { delta.width = 0 }
                }
                annotations[index] = original.translated(by: delta)
            }
            changed()
        } else if tool == .freehand {
            draft?.points.append(point); needsDisplay = true
        } else if draft != nil {
            var end = point
            if event.modifierFlags.contains(.shift), [.rectangle, .ellipse, .crop].contains(tool) {
                let length = min(abs(point.x - origin.x), abs(point.y - origin.y))
                end = CGPoint(x: origin.x + (point.x >= origin.x ? length : -length), y: origin.y + (point.y >= origin.y ? length : -length))
            } else if event.modifierFlags.contains(.shift), tool == .line || tool == .arrow {
                let length = hypot(point.x - origin.x, point.y - origin.y)
                let angle = (atan2(point.y - origin.y, point.x - origin.x) / (.pi / 4)).rounded() * (.pi / 4)
                end = CGPoint(x: origin.x + length * cos(angle), y: origin.y + length * sin(angle))
            }
            draft?.points = [origin, end]
            if tool == .crop { cropRect = draft?.localBounds; onChange?() }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { draft = nil; dragOrigin = nil; movingOriginal = nil; activeHandle = nil; didBeginMoving = false; needsDisplay = true }
        if didBeginMoving, let original = movingOriginal, let index = annotations.firstIndex(where: { $0.id == original.id }) {
            let edited = annotations[index]
            annotations[index] = original
            onWillChange?() // Exactly one original snapshot for an entire gesture, none for Escape.
            annotations[index] = edited; style = edited; changed()
        }
        guard let draft else { return }
        if tool == .crop { cropRect = draft.localBounds; onChange?(); return }
        guard draft.bounds.width > 1 || draft.bounds.height > 1 else { return }
        add(draft)
    }

    private func cancelInteraction() {
        if didBeginMoving, let original = movingOriginal, let index = annotations.firstIndex(where: { $0.id == original.id }) {
            annotations[index] = original; changed()
        }
        draft = nil; dragOrigin = nil; movingOriginal = nil; activeHandle = nil; didBeginMoving = false
    }

    func updateSelected(_ edit: (inout ImageAnnotation) -> Void) {
        guard let selection, let index = annotations.firstIndex(where: { $0.id == selection }) else { return }
        onWillChange?(); edit(&annotations[index]); style = annotations[index]; changed()
    }

    func updateSelectedStyle(color newColor: CGColor? = nil, width: CGFloat? = nil) {
        updateSelected {
            if let newColor { $0.color = newColor }
            if let width { $0.lineWidth = max(1, width) }
        }
    }

    func replaceAnnotation(id: UUID, with annotation: ImageAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        onWillChange?(); annotations[index] = annotation; selection = id; changed()
    }

    func updateText(id: UUID, text: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id && $0.tool == .text }) else { return }
        onWillChange?(); annotations[index].text = text; changed()
    }

    func duplicateSelection() {
        cancelInteraction()
        guard let selected = selectedAnnotation else { return }
        var copy = selected.translated(by: CGSize(width: 20, height: -20)); copy.id = UUID()
        add(copy)
    }

    func deleteSelection() {
        cancelInteraction()
        guard let selection, annotations.contains(where: { $0.id == selection }) else { return }
        onWillChange?(); annotations.removeAll { $0.id == selection }; self.selection = nil; changed()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "z":
            cancelInteraction()
            if event.modifierFlags.contains(.shift) { onRedo?() } else { onUndo?() }
            return true
        case "d": duplicateSelection(); return true
        case "c": onCopy?(); return true
        case "s": onExport?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: deleteSelection()
        case 36, 76:
            if cropRect != nil { onApplyCrop?() }
            else if let selected = selectedAnnotation, selected.tool == .text {
                onRequestText?(selected.points.first ?? .zero, selected.id)
            } else { super.keyDown(with: event) }
        case 53:
            let wasEditing = draft != nil || didBeginMoving || cropRect != nil || (tool == .select && selection != nil)
            cancelInteraction(); selection = nil; cropRect = nil; needsDisplay = true; onChange?()
            if !wasEditing { onCancel?() }
        case 123, 124, 125, 126:
            cancelInteraction()
            guard tool == .select, selectedAnnotation != nil else { super.keyDown(with: event); return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta = CGSize(width: event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0),
                               height: event.keyCode == 125 ? -step : (event.keyCode == 126 ? step : 0))
            updateSelected { $0 = $0.translated(by: delta) }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class ImageEditorController: NSWindowController, NSWindowDelegate {
    private struct Snapshot { var image: CGImage; var annotations: [ImageAnnotation]; var selectionFrame: CGRect? }
    private let canvas: ImageEditorCanvas
    private let scrollView = NSScrollView()
    private let workspace = EditorWorkspaceView(frame: .zero)
    private let toolbar = NSStackView()
    private let inspector = AnnotationInspector(frame: .zero)
    private let onSave: (CGImage) -> Void
    private let onPin: (CGImage) -> Void
    private let onOCR: (CGImage) -> Void
    private let onTranslate: ((CGImage) -> Void)?
    private let onApply: ((CGImage) -> Bool)?
    private var presentation: FrozenCapturePresentation?
    private var screenObserver: NSObjectProtocol?
    private var undoStates: [Snapshot] = []
    private var redoStates: [Snapshot] = []
    private var toolButtons: [ImageEditorTool: NSButton] = [:]
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var cropButton: NSButton!
    private let overflow = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private var fitToWindow = true
    private var layingOut = false
    private var lastLayoutSize: CGSize = .zero
    private var lastImageSize: CGSize = .zero
    private var needsFit = true
    private var inlineBox: InlineAnnotationTextBox?
    private var inlineAnnotation: ImageAnnotation?
    private var inlineExistingID: UUID?
    var onClose: (() -> Void)?
    var annotationCanvas: ImageEditorCanvas { canvas }
    var activeInlineTextView: InlineAnnotationTextView? { inlineBox?.input }
    var floatingToolbarFrame: CGRect { toolbar.frame }
    var contextualPaletteFrame: CGRect { inspector.frame }
    var contextualPaletteVisible: Bool { !inspector.isHidden }
    var editorSelectionFrame: CGRect { workspace.selectionFrame }

    init(image: CGImage, presentation: FrozenCapturePresentation? = nil,
         onSave: @escaping (CGImage) -> Void, onPin: @escaping (CGImage) -> Void,
         onOCR: @escaping (CGImage) -> Void, onTranslate: ((CGImage) -> Void)? = nil,
         onApply: ((CGImage) -> Bool)? = nil) {
        canvas = ImageEditorCanvas(image: image)
        self.presentation = presentation
        self.onSave = onSave; self.onPin = onPin; self.onOCR = onOCR
        self.onTranslate = onTranslate; self.onApply = onApply
        let window: NSWindow
        if let presentation {
            window = EditorOverlayWindow(contentRect: presentation.displayFrame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .floating; window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "PicShot · 图片编辑"; window.minSize = NSSize(width: 760, height: 380)
        }
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        canvas.onWillChange = { [weak self] in self?.recordChange() }
        canvas.onChange = { [weak self] in self?.updateStatus() }
        canvas.onRequestText = { [weak self] point, id in self?.beginInlineText(at: point, editing: id) }
        canvas.onUndo = { [weak self] in self?.undoEdit() }
        canvas.onRedo = { [weak self] in self?.redoEdit() }
        canvas.onApplyCrop = { [weak self] in self?.applyCrop() }
        canvas.onCopy = { [weak self] in self?.copyResult() }
        canvas.onExport = { [weak self] in self?.exportResult() }
        canvas.onCancel = { [weak self] in self?.cancelEditor() }
        canvas.onBeforeInteraction = { [weak self] in self?.finishInlineText(commit: true) }
        inspector.onEdit = { [weak self] edit in
            guard let self else { return }
            edit(&self.canvas.style)
            if var annotation = self.inlineAnnotation, let box = self.inlineBox {
                edit(&annotation); self.inlineAnnotation = annotation
                box.applyStyle(annotation, zoom: self.canvas.zoom)
                self.updateStatus(); return
            }
            if self.canvas.tool == .select { self.canvas.updateSelected(edit) }
            self.updateStatus()
        }
        workspace.onLayout = { [weak self] in self?.layoutInterface() }
        workspace.onDismiss = { [weak self] in self?.cancelEditor() }
        workspace.onOutsideClick = { [weak self] in self?.finishInlineText(commit: true) }
        if presentation != nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancelEditor() }
            }
        } else { window.center() }
        updateStatus(); layoutInterface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(near screenFrame: CGRect) {
        guard presentation == nil, let window else { showWindow(nil); return }
        let screen = NSScreen.screens.first { $0.frame.intersects(screenFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? screenFrame.insetBy(dx: -200, dy: -150)
        let size = CGSize(width: min(visible.width, max(760, screenFrame.width + 40)),
                          height: min(visible.height, max(380, screenFrame.height + 156)))
        let origin = CGPoint(x: max(visible.minX, min(screenFrame.minX - 20, visible.maxX - size.width)),
                             y: max(visible.minY, min(screenFrame.maxY - size.height + 20, visible.maxY - size.height)))
        window.setFrame(CGRect(origin: origin, size: size), display: true)
        showWindow(nil); window.makeKeyAndOrderFront(nil)
    }

    private func iconButton(_ symbol: String, title: String, id: String, action: Selector) -> NSButton {
        let control = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        control.isBordered = false; control.bezelStyle = .regularSquare; control.imagePosition = .imageOnly
        control.contentTintColor = .labelColor; control.toolTip = title; control.setAccessibilityLabel(title)
        control.identifier = NSUserInterfaceItemIdentifier(id)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([control.widthAnchor.constraint(equalToConstant: 29), control.heightAnchor.constraint(equalToConstant: 32)])
        control.wantsLayer = true; control.layer?.cornerRadius = 4
        return control
    }
    private func divider() {
        let view = NSBox(); view.boxType = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolbar.addArrangedSubview(view)
    }
    private func buildInterface() {
        guard let window else { return }
        workspace.frame = window.contentView?.bounds ?? .zero
        workspace.autoresizingMask = [.width, .height]; window.contentView = workspace
        workspace.frozenImage = presentation?.frozenImage
        toolbar.orientation = .horizontal; toolbar.detachesHiddenViews = true; toolbar.spacing = 3; toolbar.alignment = .centerY
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7)
        toolbar.identifier = NSUserInterfaceItemIdentifier("editor.floatingToolbar")
        styleFloatingSurface(toolbar)
        let tools: [(ImageEditorTool, String)] = [(.select, "cursorarrow"), (.rectangle, "rectangle"), (.ellipse, "circle"),
            (.freehand, "pencil.tip"), (.arrow, "arrow.up.right"), (.line, "line.diagonal"), (.text, "textformat"),
            (.number, "1.circle"), (.highlighter, "highlighter"), (.pixelate, "square.grid.2x2.fill"), (.redact, "eraser.fill"), (.crop, "crop")]
        for (tool, symbol) in tools {
            let control = iconButton(symbol, title: tool.title, id: "editor.tool.\(tool.rawValue)", action: #selector(selectTool(_:)))
            control.tag = ImageEditorTool.allCases.firstIndex(of: tool) ?? 0
            control.setButtonType(.toggle)
            toolButtons[tool] = control; toolbar.addArrangedSubview(control)
        }
        divider()
        undoButton = iconButton("arrow.uturn.backward", title: "撤销 · ⌘Z", id: "editor.undo", action: #selector(undoEdit))
        redoButton = iconButton("arrow.uturn.forward", title: "重做 · ⇧⌘Z", id: "editor.redo", action: #selector(redoEdit))
        toolbar.addArrangedSubview(undoButton); toolbar.addArrangedSubview(redoButton)
        cropButton = iconButton("checkmark", title: "应用裁剪 · Return", id: "editor.applyCrop", action: #selector(applyCrop))
        toolbar.addArrangedSubview(cropButton)
        divider()
        toolbar.addArrangedSubview(iconButton("text.viewfinder", title: "识别文字", id: "editor.ocr", action: #selector(recognizeResult)))
        if onTranslate != nil { toolbar.addArrangedSubview(iconButton("character.bubble", title: "翻译", id: "editor.translate", action: #selector(translateResult))) }
        if onApply != nil {
            toolbar.addArrangedSubview(iconButton("checkmark.circle", title: "应用到贴图", id: "editor.applyToPin", action: #selector(applyResult)))
        } else { toolbar.addArrangedSubview(iconButton("pin", title: "贴图", id: "editor.pin", action: #selector(pinResult))) }
        toolbar.addArrangedSubview(iconButton("arrow.down.to.line", title: "保存图片… · ⌘S", id: "editor.save", action: #selector(exportResult)))
        toolbar.addArrangedSubview(iconButton("xmark", title: "取消 · Escape", id: "editor.cancel", action: #selector(cancelEditor)))
        toolbar.addArrangedSubview(iconButton("square.on.square", title: "复制图片 · ⌘C", id: "editor.copy", action: #selector(copyResult)))
        overflow.pullsDown = true; overflow.isBordered = false; overflow.addItem(withTitle: "")
        overflow.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作")
        overflow.imagePosition = .imageOnly; overflow.setAccessibilityLabel("更多操作")
        overflow.identifier = NSUserInterfaceItemIdentifier("editor.more")
        for tool in [ImageEditorTool.select, .ellipse, .line, .highlighter, .crop] {
            let item = NSMenuItem(title: tool.title, action: #selector(selectMenuTool(_:)), keyEquivalent: "")
            item.target = self; item.tag = ImageEditorTool.allCases.firstIndex(of: tool) ?? 0; overflow.menu?.addItem(item)
        }
        overflow.menu?.addItem(.separator())
        addMenu("模糊", action: #selector(selectBlur)); addMenu("创建标注副本 · ⌘D", action: #selector(duplicateAnnotation))
        addMenu("删除标注 · Delete", action: #selector(deleteAnnotation)); overflow.menu?.addItem(.separator())
        addMenu(onApply == nil ? "保存到历史" : "保存编辑", action: #selector(saveResult))
        addMenu("适合窗口", action: #selector(fitImage)); addMenu("100% 像素", action: #selector(actualSize))
        overflow.translatesAutoresizingMaskIntoConstraints = false; overflow.widthAnchor.constraint(equalToConstant: 29).isActive = true
        overflow.heightAnchor.constraint(equalToConstant: 32).isActive = true; toolbar.addArrangedSubview(overflow)
        inspector.identifier = NSUserInterfaceItemIdentifier("editor.contextPalette"); styleFloatingSurface(inspector)
        if presentation != nil {
            workspace.addSubview(canvas)
        } else {
            scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true; scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false; scrollView.borderType = .noBorder; scrollView.documentView = canvas
            workspace.addSubview(scrollView)
        }
        workspace.addSubview(toolbar); workspace.addSubview(inspector)
        window.makeFirstResponder(canvas)
    }
    private func addMenu(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; overflow.menu?.addItem(item)
    }
    private func styleFloatingSurface(_ view: NSView) {
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1).cgColor
        view.layer?.cornerRadius = 7; view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        view.shadow = NSShadow(); view.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.24)
        view.shadow?.shadowBlurRadius = 9; view.shadow?.shadowOffset = NSSize(width: 0, height: -2)
    }
    private func layoutInterface() {
        guard !layingOut, workspace.bounds.width > 0 else { return }
        layingOut = true; defer { layingOut = false }
        let selection: CGRect
        if let presentation {
            selection = presentation.selectionFrame
            canvas.verticalZoom = selection.height / CGFloat(canvas.image.height)
            canvas.zoom = selection.width / CGFloat(canvas.image.width)
            canvas.frame = selection
        } else {
            let available = CGRect(x: 22, y: 126, width: max(1, workspace.bounds.width - 44), height: max(1, workspace.bounds.height - 164))
            let imageSize = CGSize(width: canvas.image.width, height: canvas.image.height)
            if fitToWindow && (needsFit || lastLayoutSize != workspace.bounds.size || lastImageSize != imageSize) {
                canvas.zoom = min(1, max(0.05, min(available.width / CGFloat(canvas.image.width), available.height / CGFloat(canvas.image.height))))
            }
            needsFit = false; lastLayoutSize = workspace.bounds.size; lastImageSize = imageSize
            let displayed = CGSize(width: min(available.width, canvas.frame.width), height: min(available.height, canvas.frame.height))
            scrollView.frame = CGRect(x: available.midX - displayed.width / 2, y: available.maxY - displayed.height, width: displayed.width, height: displayed.height)
            selection = scrollView.frame
        }
        workspace.selectionFrame = selection
        workspace.pixelSize = CGSize(width: canvas.image.width, height: canvas.image.height)
        for button in toolButtons.values { button.isHidden = false }
        var preferredWidth = max(40, toolbar.fittingSize.width)
        for tool in [ImageEditorTool.ellipse, .line, .highlighter, .select, .crop] where preferredWidth > workspace.bounds.width - 20 {
            if let button = toolButtons[tool] { button.isHidden = true; preferredWidth -= 32 }
        }
        toolbar.setFrameSize(CGSize(width: preferredWidth, height: 40))
        toolbar.layoutSubtreeIfNeeded(); inspector.layoutSubtreeIfNeeded()
        let active = toolButtons[canvas.tool].map { toolbar.convert($0.bounds, from: $0).midX } ?? 18
        let frames = EditorFloatingLayout.frames(selection: selection, available: workspace.bounds,
            toolbarSize: CGSize(width: preferredWidth, height: 40),
            paletteSize: inspector.isHidden ? .zero : CGSize(width: inspector.fittingSize.width, height: max(38, inspector.fittingSize.height)), activeToolOffset: active)
        toolbar.frame = frames.toolbar; inspector.frame = frames.palette
    }

    func setVerificationAnnotations(_ annotations: [ImageAnnotation]) {
        recordChange(); canvas.setContent(image: canvas.image, annotations: annotations); canvas.displayIfNeeded()
    }
    private var snapshot: Snapshot { Snapshot(image: canvas.image, annotations: canvas.annotations, selectionFrame: presentation?.selectionFrame) }
    private func recordChange() { undoStates.append(snapshot); redoStates.removeAll(); trimHistory(preferUndo: true); updateStatus() }
    private func trimHistory(preferUndo: Bool) {
        let first = preferUndo ? redoStates : undoStates, second = preferUndo ? undoStates : redoStates
        let count = ImageEditorHistoryBudget.retainedSuffixStart(images: (first + second).map(\.image))
        let firstCount = min(count, first.count), secondCount = count - firstCount
        if preferUndo { redoStates.removeFirst(firstCount); undoStates.removeFirst(secondCount) }
        else { undoStates.removeFirst(firstCount); redoStates.removeFirst(secondCount) }
    }
    private func restore(_ state: Snapshot) {
        if let old = presentation, let frame = state.selectionFrame {
            presentation = FrozenCapturePresentation(frozenImage: old.frozenImage, displayID: old.displayID, displayFrame: old.displayFrame, selectionFrame: frame)
        }
        canvas.setContent(image: state.image, annotations: state.annotations); updateStatus(); layoutInterface()
    }
    private func updateStatus() {
        status.stringValue = "\(canvas.image.width) × \(canvas.image.height) px · \(canvas.annotations.count) 个标注"
        undoButton?.isEnabled = !undoStates.isEmpty; redoButton?.isEnabled = !redoStates.isEmpty
        cropButton?.isHidden = canvas.tool != .crop
        cropButton?.isEnabled = (canvas.cropRect?.width ?? 0) >= 1 && (canvas.cropRect?.height ?? 0) >= 1
        for (tool, button) in toolButtons {
            button.state = canvas.tool == tool ? .on : .off
            button.contentTintColor = canvas.tool == tool ? .systemBlue : .labelColor
            button.layer?.backgroundColor = canvas.tool == tool ? NSColor.systemBlue.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
        }
        let selected = canvas.tool == .select ? canvas.selectedAnnotation : nil
        var inspected = selected ?? canvas.style; inspected.tool = selected?.tool ?? canvas.tool
        let enabled = canvas.tool != .crop && (canvas.tool != .select || selected != nil)
        inspector.isHidden = !enabled
        inspector.display(annotation: inspected, selected: selected != nil, enabled: enabled)
        layoutInterface()
    }
    func chooseTool(_ tool: ImageEditorTool) {
        finishInlineText(commit: true); canvas.tool = tool; updateStatus(); window?.makeFirstResponder(canvas)
    }
    @objc private func selectTool(_ sender: NSButton) {
        guard ImageEditorTool.allCases.indices.contains(sender.tag) else { return }; chooseTool(ImageEditorTool.allCases[sender.tag])
    }
    @objc private func selectMenuTool(_ sender: NSMenuItem) {
        guard ImageEditorTool.allCases.indices.contains(sender.tag) else { return }; chooseTool(ImageEditorTool.allCases[sender.tag])
    }
    @objc private func selectBlur() { chooseTool(.blur) }
    @objc private func duplicateAnnotation() { finishInlineText(commit: true); canvas.duplicateSelection() }
    @objc private func deleteAnnotation() { finishInlineText(commit: false); canvas.deleteSelection() }
    @objc private func undoEdit() {
        finishInlineText(commit: true)
        guard let state = undoStates.popLast() else { return }
        redoStates.append(snapshot); trimHistory(preferUndo: false); restore(state)
    }
    @objc private func redoEdit() {
        finishInlineText(commit: false)
        guard let state = redoStates.popLast() else { return }
        undoStates.append(snapshot); trimHistory(preferUndo: true); restore(state)
    }
    @objc private func applyCrop() {
        finishInlineText(commit: true)
        guard let rect = canvas.cropRect, let flattened = canvas.flattened(), let cropped = ImageEditorRenderer.crop(image: flattened, to: rect) else { return }
        recordChange()
        if let old = presentation {
            let scaleX = old.selectionFrame.width / CGFloat(canvas.image.width), scaleY = old.selectionFrame.height / CGFloat(canvas.image.height)
            let clipped = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: canvas.image.width, height: canvas.image.height))
            presentation = FrozenCapturePresentation(frozenImage: old.frozenImage, displayID: old.displayID, displayFrame: old.displayFrame,
                selectionFrame: CGRect(x: old.selectionFrame.minX + clipped.minX * scaleX, y: old.selectionFrame.minY + clipped.minY * scaleY, width: clipped.width * scaleX, height: clipped.height * scaleY))
        }
        canvas.setContent(image: cropped, annotations: []); fitImage()
    }
    @objc private func fitImage() { finishInlineText(commit: true); fitToWindow = true; needsFit = true; layoutInterface() }
    @objc private func actualSize() { guard presentation == nil else { return }; finishInlineText(commit: true); fitToWindow = false; canvas.zoom = 1; layoutInterface() }
    private func result(close: Bool = false, _ action: (CGImage) -> Void) {
        finishInlineText(commit: true)
        guard let image = canvas.flattened() else { showError(PicShotError.message("无法合成图片，可能内存不足")); return }
        if close { window?.close() }; action(image)
    }
    @objc private func copyResult() { result(close: presentation != nil) { copyImage($0) } }
    @objc private func saveResult() { result(onSave) }
    @objc private func pinResult() { result(close: presentation != nil, onPin) }
    @objc private func recognizeResult() { result(close: presentation != nil, onOCR) }
    @objc private func translateResult() { if let onTranslate { result(close: presentation != nil, onTranslate) } }
    @objc private func applyResult() {
        guard let onApply else { return }
        result { image in if onApply(image) { window?.close() } }
    }
    @objc private func cancelEditor() { finishInlineText(commit: false); window?.close() }

    func beginInlineText(at point: CGPoint, editing id: UUID?) {
        finishInlineText(commit: true)
        let existing = id.flatMap { identifier in canvas.annotations.first { $0.id == identifier && $0.tool == .text } }
        var annotation = existing ?? canvas.makeAnnotation(tool: .text, points: [point])
        let zoom = canvas.zoom, scaleY = canvas.displayScaleY
        let width = min(max(150, (existing?.localBounds.width ?? 260 / zoom) * zoom + 8), max(80, canvas.bounds.width))
        let height = min(max(58, (existing?.localBounds.height ?? 66 / scaleY) * scaleY + 8), max(40, canvas.bounds.height))
        let origin = CGPoint(x: min(max(0, point.x * zoom), max(0, canvas.bounds.width - width)),
                             y: min(max(0, point.y * scaleY - (existing == nil ? height : 0)), max(0, canvas.bounds.height - height)))
        if existing == nil { annotation.points = [CGPoint(x: origin.x / zoom, y: origin.y / scaleY)] }
        let box = InlineAnnotationTextBox(frame: CGRect(origin: origin, size: CGSize(width: width, height: height)), annotation: annotation, zoom: zoom)
        box.onAccept = { [weak self] in self?.finishInlineText(commit: true) }
        box.onCancel = { [weak self] in self?.finishInlineText(commit: false) }
        inlineBox = box; inlineAnnotation = annotation; inlineExistingID = existing?.id
        canvas.editingAnnotationID = existing?.id
        canvas.addSubview(box); box.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(box.input); box.input.setSelectedRange(NSRange(location: box.input.string.utf16.count, length: 0))
    }
    func finishInlineText(commit: Bool) {
        guard let box = inlineBox, var annotation = inlineAnnotation else { return }
        let text = box.input.string, existingID = inlineExistingID
        inlineBox = nil; inlineAnnotation = nil; inlineExistingID = nil
        box.removeFromSuperview(); canvas.editingAnnotationID = nil
        if commit && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotation.text = text
            if existingID == nil || box.wasResized {
                annotation.points = [CGPoint(x: (box.frame.minX + 6) / canvas.zoom, y: (box.frame.minY + 5) / canvas.displayScaleY)]
                annotation.textBoxSize = CGSize(width: max(2, (box.bounds.width - 12) / canvas.zoom), height: max(2, (box.bounds.height - 10) / canvas.displayScaleY))
            }
            if let existingID { canvas.replaceAnnotation(id: existingID, with: annotation) }
            else { canvas.add(annotation) }
        }
        window?.makeFirstResponder(canvas)
    }
    func windowWillClose(_ notification: Notification) {
        finishInlineText(commit: false)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        workspace.frozenImage = nil; presentation = nil
        undoStates.removeAll(); redoStates.removeAll()
        canvas.onWillChange = nil; canvas.onChange = nil; canvas.onRequestText = nil
        canvas.onUndo = nil; canvas.onRedo = nil; canvas.onApplyCrop = nil
        canvas.onCopy = nil; canvas.onExport = nil; canvas.onCancel = nil; canvas.onBeforeInteraction = nil
        inspector.onEdit = nil; inspector.deactivateColorWells()
        workspace.onLayout = nil; workspace.onDismiss = nil; workspace.onOutsideClick = nil
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        window?.contentView = nil; window?.delegate = nil
        let completion = onClose; onClose = nil; completion?()
    }
    func windowDidResize(_ notification: Notification) { finishInlineText(commit: true); layoutInterface() }

    @objc private func exportResult() {
        finishInlineText(commit: true)
        guard let window, let image = canvas.flattened() else { return }
        let panel = NSSavePanel(); panel.title = "保存图片"; panel.nameFieldStringValue = "PicShot.png"
        panel.allowedContentTypes = [.png]; panel.canCreateDirectories = true
        let formats = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28)); formats.addItems(withTitles: ["PNG", "JPEG", "TIFF", "PDF"])
        let accessory = ExportFormatAccessory(picker: formats, panel: panel); panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [weak self, accessory] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Self.writeFlattened(image, to: url, format: accessory.picker.indexOfSelectedItem)
                if self?.presentation != nil { self?.window?.close() }
            } catch { showError(error) }
        }
    }

    static func writeFlattened(_ image: CGImage, to url: URL, format: Int) throws {
        if format == 3 {
            var media = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
            guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
                throw PicShotError.message("无法创建 PDF")
            }
            context.beginPDFPage(nil); context.draw(image, in: media); context.endPDFPage(); context.closePDF()
            return
        }
        let type: UTType = format == 1 ? .jpeg : (format == 2 ? .tiff : .png)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw PicShotError.message("无法创建导出文件") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PicShotError.message("导出失败，请检查磁盘空间或文件权限") }
    }
}

@MainActor
private final class ExportFormatAccessory: NSView {
    let picker: NSPopUpButton
    private weak var panel: NSSavePanel?
    init(picker: NSPopUpButton, panel: NSSavePanel) {
        self.picker = picker; self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 34))
        let label = NSTextField(labelWithString: "格式："); label.frame = NSRect(x: 0, y: 5, width: 65, height: 22)
        picker.frame.origin = NSPoint(x: 65, y: 2)
        addSubview(label); addSubview(picker)
        picker.target = self; picker.action = #selector(changeFormat)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changeFormat() {
        let types: [UTType] = [.png, .jpeg, .tiff, .pdf]
        guard types.indices.contains(picker.indexOfSelectedItem), let panel else { return }
        let type = types[picker.indexOfSelectedItem]
        panel.allowedContentTypes = [type]
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = name + "." + (type.preferredFilenameExtension ?? "png")
    }
}
