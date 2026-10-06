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

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        let xs = points.map(\.x), ys = points.map(\.y)
        let minimumX = xs.min() ?? first.x, minimumY = ys.min() ?? first.y
        let box = CGRect(x: minimumX, y: minimumY, width: (xs.max() ?? first.x) - minimumX, height: (ys.max() ?? first.y) - minimumY)
        if tool == .text {
            let size = max(16, lineWidth * 5)
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            return CGRect(x: first.x, y: first.y, width: max(16, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))), height: size * 1.3)
        }
        if tool == .number {
            let radius = max(14, lineWidth * 4)
            return CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
        }
        return box
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
            context.setStrokeColor(annotation.color)
            context.setFillColor(annotation.color)
            context.setLineWidth(max(1, annotation.lineWidth))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let rect = annotation.bounds.standardized
            switch annotation.tool {
            case .select, .crop: break
            case .rectangle: context.stroke(rect)
            case .ellipse: context.strokeEllipse(in: rect)
            case .redact:
                // Always opaque: even a translucent chosen color cannot reveal the original pixels.
                context.setFillColor(annotation.color.copy(alpha: 1) ?? CGColor(gray: 0, alpha: 1))
                context.setShouldAntialias(false)
                context.fill(rect.integral)
            case .highlighter:
                context.setFillColor(annotation.color.copy(alpha: 0.32) ?? annotation.color)
                context.fill(rect)
            case .line, .arrow, .freehand:
                if let first = annotation.points.first, let last = annotation.points.last {
                    context.beginPath(); context.move(to: first)
                    for point in annotation.points.dropFirst() { context.addLine(to: point) }
                    context.strokePath()
                    if annotation.tool == .arrow {
                        let angle = atan2(last.y - first.y, last.x - first.x)
                        let length = max(12, annotation.lineWidth * 4)
                        context.beginPath(); context.move(to: last)
                        context.addLine(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                        context.move(to: last)
                        context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                        context.strokePath()
                    }
                }
            case .text:
                if let point = annotation.points.first {
                    drawText(annotation.text, point: point, size: max(16, annotation.lineWidth * 5), color: annotation.color, context: context)
                }
            case .number:
                context.fillEllipse(in: rect)
                let value = String(annotation.number)
                let fontSize = rect.height * 0.58
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                drawText(value, point: CGPoint(x: rect.midX - width / 2, y: rect.midY - fontSize * 0.37), size: fontSize, color: CGColor(gray: 1, alpha: 1), context: context, bold: true)
            case .blur, .pixelate:
                let region = rect.integral.intersection(extent)
                if !region.isEmpty, let snapshot = context.makeImage() {
                    let input = CIImage(cgImage: snapshot)
                    let filtered: CIImage
                    if annotation.tool == .blur {
                        filtered = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(8, annotation.lineWidth * 3)])
                    } else {
                        filtered = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, annotation.lineWidth * 4), kCIInputCenterKey: CIVector(x: 0, y: 0)])
                    }
                    if let patch = filterContext.createCGImage(filtered.cropped(to: region), from: region) {
                        context.interpolationQuality = .none
                        context.draw(patch, in: region)
                    }
                }
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
    var tool: ImageEditorTool = .arrow { didSet { draft = nil; cropRect = nil; needsDisplay = true } }
    var color = NSColor.systemRed.cgColor
    var strokeWidth: CGFloat = 4
    var zoom: CGFloat = 1 { didSet { resizeCanvas() } }
    var cropRect: CGRect?
    var onWillChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onRequestText: ((CGPoint, UUID?) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?
    private var selection: UUID?
    private var draft: ImageAnnotation?
    private var dragOrigin: CGPoint?
    private var movingOriginal: ImageAnnotation?
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
        setFrameSize(NSSize(width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom))
        needsDisplay = true
    }

    func setContent(image: CGImage, annotations: [ImageAnnotation]) {
        self.image = image; self.annotations = annotations
        selection = nil; draft = nil; cropRect = nil; cachedImage = nil
        resizeCanvas(); onChange?()
    }

    func flattened() -> CGImage? { ImageEditorRenderer.render(image: image, annotations: annotations) }

    func add(_ annotation: ImageAnnotation) {
        onWillChange?()
        annotations.append(annotation); selection = annotation.id
        changed()
    }

    private func changed() {
        cachedImage = nil; needsDisplay = true; onChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.scaleBy(x: zoom, y: zoom)
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        if cachedImage == nil { cachedImage = flattened() }
        let displayed = draft.flatMap { ImageEditorRenderer.render(image: cachedImage ?? image, annotations: [$0]) } ?? cachedImage ?? image
        context.draw(displayed, in: imageBounds)
        if let selected = annotations.first(where: { $0.id == selection }), tool == .select {
            drawSelection(selected.bounds.insetBy(dx: -4 / zoom, dy: -4 / zoom), context: context)
        }
        if let cropRect { drawSelection(cropRect, context: context) }
        context.restoreGState()
    }

    private func drawSelection(_ rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(3 / zoom); context.stroke(rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1.5 / zoom)
        context.setLineDash(phase: 0, lengths: [5 / zoom, 3 / zoom]); context.stroke(rect)
        context.restoreGState()
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, point.x / zoom), CGFloat(image.width)), y: min(max(0, point.y / zoom), CGFloat(image.height)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        dragOrigin = point; didBeginMoving = false; movingOriginal = nil
        if tool == .select {
            selection = annotations.reversed().first { $0.bounds.insetBy(dx: -8 / zoom, dy: -8 / zoom).contains(point) }?.id
            movingOriginal = annotations.first { $0.id == selection }
            if let selected = selectedAnnotation {
                color = selected.color; strokeWidth = selected.lineWidth
                if event.clickCount == 2, selected.tool == .text {
                    onRequestText?(selected.points.first ?? point, selected.id)
                }
            }
            needsDisplay = true; onChange?()
        } else if tool == .text {
            onRequestText?(point, nil)
        } else if tool == .number {
            let next = (annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
            add(ImageAnnotation(tool: .number, points: [point], color: color, lineWidth: strokeWidth, number: next))
        } else {
            draft = ImageAnnotation(tool: tool, points: [point, point], color: color, lineWidth: strokeWidth)
            if tool == .redact { draft?.color = CGColor(gray: 0, alpha: 1) }
            cropRect = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event)
        guard let origin = dragOrigin else { return }
        if tool == .select, let original = movingOriginal, let index = annotations.firstIndex(where: { $0.id == original.id }) {
            if !didBeginMoving {
                guard hypot(point.x - origin.x, point.y - origin.y) > 1 / zoom else { return }
                onWillChange?(); didBeginMoving = true
            }
            annotations[index] = original.translated(by: CGSize(width: point.x - origin.x, height: point.y - origin.y))
            changed()
        } else if tool == .freehand {
            draft?.points.append(point); needsDisplay = true
        } else if draft != nil {
            var end = point
            if event.modifierFlags.contains(.shift), [.rectangle, .ellipse, .crop].contains(tool) {
                let length = min(abs(point.x - origin.x), abs(point.y - origin.y))
                end = CGPoint(x: origin.x + (point.x >= origin.x ? length : -length), y: origin.y + (point.y >= origin.y ? length : -length))
            }
            draft?.points = [origin, end]
            if tool == .crop { cropRect = draft?.bounds; onChange?() }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { draft = nil; dragOrigin = nil; movingOriginal = nil; needsDisplay = true }
        guard let draft else { return }
        if tool == .crop { cropRect = draft.bounds; onChange?(); return }
        guard draft.bounds.width > 1 || draft.bounds.height > 1 else { return }
        add(draft)
    }

    func updateSelectedStyle(color newColor: CGColor? = nil, width: CGFloat? = nil) {
        guard let selection, let index = annotations.firstIndex(where: { $0.id == selection }) else { return }
        onWillChange?()
        if let newColor { annotations[index].color = newColor }
        if let width { annotations[index].lineWidth = max(1, width) }
        changed()
    }

    func updateText(id: UUID, text: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id && $0.tool == .text }) else { return }
        onWillChange?(); annotations[index].text = text; changed()
    }

    func deleteSelection() {
        guard let selection, annotations.contains(where: { $0.id == selection }) else { return }
        onWillChange?(); annotations.removeAll { $0.id == selection }; self.selection = nil; changed()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "z":
            if event.modifierFlags.contains(.shift) { onRedo?() } else { onUndo?() }
            return true
        case "c": onCopy?(); return true
        case "s": onExport?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: deleteSelection()
        case 36, 76: if cropRect != nil { onApplyCrop?() } else { super.keyDown(with: event) }
        case 53: selection = nil; draft = nil; cropRect = nil; needsDisplay = true; onChange?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class ImageEditorController: NSWindowController {
    private struct Snapshot { var image: CGImage; var annotations: [ImageAnnotation] }
    private let canvas: ImageEditorCanvas
    private let scrollView = NSScrollView()
    private let onSave: (CGImage) -> Void
    private let onPin: (CGImage) -> Void
    private let onOCR: (CGImage) -> Void
    private var undoStates: [Snapshot] = []
    private var redoStates: [Snapshot] = []
    private let status = NSTextField(labelWithString: "")
    private let toolPicker = NSPopUpButton()
    private let commonTools: [ImageEditorTool] = [.select, .arrow, .rectangle, .text, .redact, .crop]
    private let moreTools: [ImageEditorTool] = [.ellipse, .line, .freehand, .number, .highlighter, .blur, .pixelate]
    private var toolButtons: [ImageEditorTool: NSButton] = [:]
    var annotationCanvas: ImageEditorCanvas { canvas }
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 20, target: nil, action: nil)
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var cropButton: NSButton!
    private var zoomPicker = NSPopUpButton()
    private let zoomValues: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3]

    init(image: CGImage, onSave: @escaping (CGImage) -> Void, onPin: @escaping (CGImage) -> Void, onOCR: @escaping (CGImage) -> Void) {
        canvas = ImageEditorCanvas(image: image)
        self.onSave = onSave; self.onPin = onPin; self.onOCR = onOCR
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PicShot · 图片编辑"
        window.minSize = NSSize(width: 790, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        canvas.onWillChange = { [weak self] in self?.recordChange() }
        canvas.onChange = { [weak self] in self?.updateStatus() }
        canvas.onRequestText = { [weak self] point, id in self?.requestText(at: point, editing: id) }
        canvas.onUndo = { [weak self] in self?.undoEdit() }
        canvas.onRedo = { [weak self] in self?.redoEdit() }
        canvas.onApplyCrop = { [weak self] in self?.applyCrop() }
        canvas.onCopy = { [weak self] in self?.copyResult() }
        canvas.onExport = { [weak self] in self?.exportResult() }
        updateStatus(); window.center()
        DispatchQueue.main.async { [weak self] in self?.fitImage() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ title: String, action: Selector, tooltip: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; button.controlSize = .small; button.toolTip = tooltip
        return button
    }

    private func iconButton(_ symbol: String, title: String, action: Selector) -> NSButton {
        let control = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        control.bezelStyle = .texturedRounded; control.controlSize = .small
        control.imagePosition = .imageOnly; control.toolTip = title; control.setAccessibilityLabel(title)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return control
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 5
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let symbols = ["cursorarrow", "arrow.up.right", "rectangle", "textformat", "square.fill", "crop"]
        for (tool, symbol) in zip(commonTools, symbols) {
            let control = iconButton(symbol, title: tool.title, action: #selector(selectCommonTool(_:)))
            control.setButtonType(.toggle)
            control.tag = ImageEditorTool.allCases.firstIndex(of: tool) ?? 0
            control.state = tool == canvas.tool ? .on : .off
            toolButtons[tool] = control; toolbar.addArrangedSubview(control)
        }
        toolPicker.addItems(withTitles: ["更多"] + moreTools.map(\.title))
        toolPicker.controlSize = .small
        toolPicker.target = self; toolPicker.action = #selector(changeTool)
        toolPicker.toolTip = "选择工具可移动标注，Delete 删除；敏感信息请用不透明遮盖，模糊与马赛克仅为视觉效果"
        toolPicker.setAccessibilityLabel("标注工具")
        colorWell.color = .systemRed; colorWell.target = self; colorWell.action = #selector(changeColor)
        colorWell.translatesAutoresizingMaskIntoConstraints = false; colorWell.widthAnchor.constraint(equalToConstant: 32).isActive = true
        colorWell.setAccessibilityLabel("标注颜色")
        widthSlider.target = self; widthSlider.action = #selector(changeWidth); widthSlider.isContinuous = false
        widthSlider.translatesAutoresizingMaskIntoConstraints = false; widthSlider.widthAnchor.constraint(equalToConstant: 56).isActive = true
        widthSlider.toolTip = "线宽 / 字号 / 模糊强度"; widthSlider.setAccessibilityLabel("线宽")
        undoButton = iconButton("arrow.uturn.backward", title: "撤销 · ⌘Z", action: #selector(undoEdit))
        redoButton = iconButton("arrow.uturn.forward", title: "重做 · ⇧⌘Z", action: #selector(redoEdit))
        cropButton = button("应用裁剪", action: #selector(applyCrop), tooltip: "先用裁剪工具拖动选区，再按 Return")
        for view in [toolPicker, colorWell, widthSlider, undoButton!, redoButton!, iconButton("trash", title: "删除标注 · Delete", action: #selector(deleteAnnotation)), cropButton!] as [NSView] { toolbar.addArrangedSubview(view) }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(button("复制", action: #selector(copyResult), tooltip: "⌘C · 复制合成图片"))
        toolbar.addArrangedSubview(button("导出…", action: #selector(exportResult), tooltip: "⌘S · PNG / JPEG / TIFF / PDF"))
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(status)
        zoomPicker.addItems(withTitles: ["适合窗口"] + zoomValues.map { "\(Int($0 * 100))%" })
        zoomPicker.target = self; zoomPicker.action = #selector(changeZoom); zoomPicker.setAccessibilityLabel("缩放")
        footer.addArrangedSubview(zoomPicker)
        footer.addArrangedSubview(button("识别文字", action: #selector(recognizeResult)))
        footer.addArrangedSubview(button("贴图", action: #selector(pinResult)))
        footer.addArrangedSubview(button("保存到历史", action: #selector(saveResult)))
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.backgroundColor = .underPageBackgroundColor; scrollView.drawsBackground = true
        scrollView.documentView = canvas
        for view in [toolbar, scrollView, footer] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor), toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor), scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor), footer.leadingAnchor.constraint(equalTo: content.leadingAnchor), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window?.makeFirstResponder(canvas)
    }

    /// Seeds real annotations for a reproducible native-window verification capture.
    /// This uses the same model, redraw, history, and export path as interactive edits.
    func setVerificationAnnotations(_ annotations: [ImageAnnotation]) {
        recordChange()
        canvas.setContent(image: canvas.image, annotations: annotations)
        canvas.displayIfNeeded()
    }

    private var snapshot: Snapshot { Snapshot(image: canvas.image, annotations: canvas.annotations) }
    private func recordChange() {
        undoStates.append(snapshot)
        redoStates.removeAll()
        trimHistory(preferUndo: true); updateStatus()
    }
    private func trimHistory(preferUndo: Bool) {
        // Oldest entries are first in each stack. Protect the nearest state in
        // the direction the user just created, preserving immediate undo/redo.
        let first = preferUndo ? redoStates : undoStates
        let second = preferUndo ? undoStates : redoStates
        let count = ImageEditorHistoryBudget.retainedSuffixStart(images: (first + second).map(\.image))
        let firstCount = min(count, first.count)
        let secondCount = count - firstCount
        if preferUndo {
            redoStates.removeFirst(firstCount); undoStates.removeFirst(secondCount)
        } else {
            undoStates.removeFirst(firstCount); redoStates.removeFirst(secondCount)
        }
    }
    private func restore(_ state: Snapshot) { canvas.setContent(image: state.image, annotations: state.annotations); updateStatus() }
    private func updateStatus() {
        status.stringValue = "\(canvas.image.width) × \(canvas.image.height) px · \(Int(canvas.zoom * 100))% · \(canvas.annotations.count) 个标注"
        undoButton?.isEnabled = !undoStates.isEmpty; redoButton?.isEnabled = !redoStates.isEmpty
        cropButton?.isEnabled = (canvas.cropRect?.width ?? 0) >= 1 && (canvas.cropRect?.height ?? 0) >= 1
        for (tool, button) in toolButtons { button.state = canvas.tool == tool ? .on : .off }
        if canvas.tool == .select, let selected = canvas.selectedAnnotation {
            colorWell.color = NSColor(cgColor: selected.color) ?? colorWell.color
            widthSlider.doubleValue = Double(selected.lineWidth)
        }
    }

    private func chooseTool(_ tool: ImageEditorTool) {
        canvas.tool = tool
        toolPicker.selectItem(at: moreTools.firstIndex(of: tool).map { $0 + 1 } ?? 0)
        updateStatus(); window?.makeFirstResponder(canvas)
    }
    @objc private func selectCommonTool(_ sender: NSButton) {
        guard ImageEditorTool.allCases.indices.contains(sender.tag) else { return }
        chooseTool(ImageEditorTool.allCases[sender.tag])
    }
    @objc private func changeTool() {
        let index = toolPicker.indexOfSelectedItem - 1
        guard moreTools.indices.contains(index) else { return }
        chooseTool(moreTools[index])
    }
    @objc private func changeColor() {
        canvas.color = colorWell.color.cgColor
        if canvas.tool == .select { canvas.updateSelectedStyle(color: canvas.color) }
    }
    @objc private func changeWidth() {
        canvas.strokeWidth = CGFloat(widthSlider.doubleValue)
        if canvas.tool == .select { canvas.updateSelectedStyle(width: canvas.strokeWidth) }
    }
    @objc private func deleteAnnotation() { canvas.deleteSelection() }
    @objc private func undoEdit() {
        guard let state = undoStates.popLast() else { return }
        redoStates.append(snapshot); trimHistory(preferUndo: false); restore(state)
    }
    @objc private func redoEdit() {
        guard let state = redoStates.popLast() else { return }
        undoStates.append(snapshot); trimHistory(preferUndo: true); restore(state)
    }
    @objc private func applyCrop() {
        guard let rect = canvas.cropRect, let flattened = canvas.flattened(), let cropped = ImageEditorRenderer.crop(image: flattened, to: rect) else { return }
        recordChange(); canvas.setContent(image: cropped, annotations: []); fitImage()
    }
    @objc private func changeZoom() {
        let index = zoomPicker.indexOfSelectedItem
        if index == 0 { fitImage() }
        else if zoomValues.indices.contains(index - 1) { canvas.zoom = zoomValues[index - 1]; updateStatus() }
    }
    private func fitImage() {
        let available = scrollView.contentSize
        guard available.width > 0, available.height > 0 else { return }
        canvas.zoom = min(1, max(0.05, min(available.width / CGFloat(canvas.image.width), available.height / CGFloat(canvas.image.height))))
        zoomPicker.selectItem(at: 0); updateStatus()
    }
    private func result(_ action: (CGImage) -> Void) {
        guard let image = canvas.flattened() else { showError(PicShotError.message("无法合成图片，可能内存不足")); return }
        action(image)
    }
    @objc private func copyResult() { result { copyImage($0) } }
    @objc private func saveResult() { result(onSave) }
    @objc private func pinResult() { result(onPin) }
    @objc private func recognizeResult() { result(onOCR) }

    private func requestText(at point: CGPoint, editing id: UUID?) {
        guard let window else { return }
        let existing = id.flatMap { identifier in canvas.annotations.first { $0.id == identifier } }
        let alert = NSAlert(); alert.messageText = existing == nil ? "添加文字" : "编辑文字"; alert.informativeText = "文字大小由工具栏的粗细控制；选择工具下双击文字可再次编辑"
        alert.addButton(withTitle: existing == nil ? "添加" : "保存"); alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26)); input.placeholderString = "输入标注文字"
        input.stringValue = existing?.text ?? ""
        alert.accessoryView = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let id { self.canvas.updateText(id: id, text: input.stringValue) }
            else { self.canvas.add(ImageAnnotation(tool: .text, points: [point], color: self.canvas.color, lineWidth: self.canvas.strokeWidth, text: input.stringValue)) }
            window.makeFirstResponder(self.canvas)
        }
        alert.window.initialFirstResponder = input
    }

    @objc private func exportResult() {
        guard let window, let image = canvas.flattened() else { return }
        let panel = NSSavePanel(); panel.title = "导出图片"; panel.nameFieldStringValue = "PicShot.png"
        panel.allowedContentTypes = [.png]; panel.canCreateDirectories = true
        let formats = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        formats.addItems(withTitles: ["PNG", "JPEG", "TIFF", "PDF"])
        let accessory = ExportFormatAccessory(picker: formats, panel: panel)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [weak self, accessory] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Self.writeFlattened(image, to: url, format: accessory.picker.indexOfSelectedItem)
                self?.status.stringValue = "已导出 \(url.lastPathComponent)"
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
