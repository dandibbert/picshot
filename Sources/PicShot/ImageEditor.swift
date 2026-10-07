import AppKit
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// All annotation coordinates are image pixels, with the origin at the bottom left.
enum ImageEditorTool: String, CaseIterable {
    case select, rectangle, ellipse, arrow, line, freehand, text, number, highlighter, redact, blur, pixelate, crop, eraser, spotlight, watermark, magnifier, arc, sector, polyline

    var title: String {
        switch self {
        case .select: return "选择"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .arc: return "圆弧"
        case .sector: return "扇形"
        case .polyline: return "折线"
        case .freehand: return "画笔"
        case .text: return "文字"
        case .number: return "序号"
        case .highlighter: return "高亮"
        case .redact: return "遮盖"
        case .blur: return "模糊"
        case .pixelate: return "马赛克"
        case .crop: return "裁剪"
        case .eraser: return "橡皮擦"
        case .spotlight: return "聚光灯"
        case .watermark: return "水印"
        case .magnifier: return "放大镜"
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
    var numberStyle: NumberedCalloutStyle = .decimal
    var numberComment = ""
    var numberCommentSize = CGSize(width: 240, height: 80)
    /// Radians counterclockwise around localBounds' center. Image coordinates are y-up.
    var rotation: CGFloat = 0
    var opacity: CGFloat = 1
    var strokeStyle: AnnotationStrokeStyle = .solid
    var lineCap: AnnotationLineCap = .round
    var lineJoin: AnnotationLineJoin = .round
    var startArrowEnabled = false
    /// nil keeps each tool's original default: one end arrow only for the arrow tool.
    var endArrowEnabled: Bool? = nil
    var startArrowhead: AnnotationArrowhead = .open
    var endArrowhead: AnnotationArrowhead = .open
    var fillEnabled = false
    var fillColor: CGColor = CGColor(srgbRed: 1, green: 0.91, blue: 0.52, alpha: 1)
    var cornerRadius: CGFloat = 0
    var fontName = "Helvetica"
    var fontSize: CGFloat? = nil
    var bold = false
    var italic = false
    var underline = false
    var textOutlineEnabled = false
    var textOutlineColor: CGColor = CGColor(gray: 1, alpha: 1)
    var textOutlineWidth: CGFloat = 2
    /// Optional explicit box; text wraps to its width and remains clipped to its height.
    var textBoxSize: CGSize? = nil
    var eraserMode: AnnotationEraserMode = .brush
    var spotlightShape: AnnotationRegionShape = .ellipse
    var spotlightDim: CGFloat = 0.55
    var spotlightBorder = true
    var watermarkPlacement: AnnotationWatermarkPlacement = .tiled
    var watermarkSpacing: CGFloat = 48
    var watermarkTemplate = "PicShot · $yyyy-MM-dd HH:mm:ss$"
    var frozenTimestamp = Date(timeIntervalSince1970: 0)
    var frozenTimeZoneIdentifier = "UTC"
    var timestampIsCaptureDate = false
    var magnifierSource: CGRect? = nil
    var magnifierScale: CGFloat = 2
    var magnifierShape: AnnotationRegionShape = .ellipse
    var magnifierConnector: AnnotationMagnifierConnector = .line
    var magnifierSmooth = false
    var magnifierShowsAnnotations = true
    var magnifierShadow = true
    var arcStartAngle: CGFloat = 0
    var arcSweepAngle: CGFloat = .pi * 1.5
    // Defaults preserve existing unsmoothed pencil and rectangular translucent marks.
    var freehandSmoothing = false
    var freehandConstraint: AnnotationPencilConstraint = .free
    var freehandCorners: [Int] = []
    var freehandWasSimplified = false
    var highlighterMode: AnnotationHighlighterMode = .rectangle
    var highlighterBlend: AnnotationHighlighterBlend = .translucent
    /// Value metadata lives in the annotation snapshot, so linking and exclusions undo together.
    var mosaicLink: AutomaticMosaicLink? = nil

    var localBounds: CGRect {
        let geometryPoints = boundedPathPoints
        guard let first = geometryPoints.first else { return .zero }
        if tool == .text {
            return CGRect(origin: first, size: AnnotationTextLayout.size(for: self))
        }
        if tool == .number {
            return numberLocalBounds
        }
        let xs = geometryPoints.map(\.x), ys = geometryPoints.map(\.y)
        let x = xs.min() ?? first.x, y = ys.min() ?? first.y
        return CGRect(x: x, y: y, width: (xs.max() ?? x) - x, height: (ys.max() ?? y) - y)
    }

    var bounds: CGRect { localBounds.applying(transform) }

    var transform: CGAffineTransform {
        let box = tool == .number ? numberBadgeRect : localBounds
        return CGAffineTransform(translationX: box.midX, y: box.midY)
            .rotated(by: rotation).translatedBy(x: -box.midX, y: -box.midY)
    }

    func translated(by delta: CGSize) -> ImageAnnotation {
        var result = self
        result.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        if let source = magnifierSource { result.magnifierSource = source.offsetBy(dx: delta.width, dy: delta.height) }
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
        drawAnnotations(annotations, in: context, extent: extent, baseImage: image)
        return context.makeImage()
    }

    /// Draw into an existing bottom-left, image-pixel context. Ordinary vector tools
    /// (including erasure) allocate no additional full-frame bitmap, including in video.
    static func drawAnnotations(_ annotations: [ImageAnnotation], in context: CGContext,
                                extent: CGRect, baseImage: CGImage? = nil) {
        // Build each eraser geometry once per frame, not once per underlying mark.
        let erasers: [(index: Int, path: CGPath)] = annotations.enumerated().compactMap { index, mark in
            guard mark.tool == .eraser else { return nil }
            return (index, mark.mergedEraserPath)
        }
        // A linked automatic result is a single composite operation. Contiguous members
        // sample one pre-group raster, rather than copying the full image per match.
        // Ordinary annotations retain their original sequential filtering semantics.
        var mosaicSnapshot: CGImage?
        var mosaicSnapshotGroup: UUID?
        for (index, annotation) in annotations.enumerated() where annotation.tool != .eraser {
            let group = annotation.mosaicLink?.additionID
            if group != mosaicSnapshotGroup { mosaicSnapshot = nil; mosaicSnapshotGroup = group }
            context.saveGState()
            // Clip each later eraser separately: operation order is stable, and marks
            // added after an eraser are not removed by an earlier operation.
            let affectedBounds = annotation.tool == .spotlight ? extent :
                (annotation.tool == .magnifier ? annotation.bounds.union(annotation.magnifierSourceRect) :
                    (annotation.supportsLineEndings ? annotation.linePaintedBounds : annotation.bounds))
                    .insetBy(dx: -max(annotation.tool == .magnifier ? 32 : 10, annotation.lineWidth * 4),
                             dy: -max(annotation.tool == .magnifier ? 32 : 10, annotation.lineWidth * 4))
            for eraser in erasers where eraser.index > index && eraser.path.boundingBoxOfPath.intersects(affectedBounds) {
                context.addRect(extent); context.addPath(eraser.path); context.clip(using: .evenOdd)
            }
            // Obscuring pixels is a security boundary: redaction ignores both color alpha
            // and global opacity. Blur and pixelation remain cosmetic effects only.
            context.setAlpha([ImageEditorTool.redact, .spotlight, .magnifier].contains(annotation.tool) ? 1 : min(1, max(0, annotation.opacity)))
            context.setStrokeColor(annotation.color)
            context.setFillColor(annotation.color)
            context.setLineWidth(max(1, annotation.lineWidth))
            context.setLineCap(annotation.supportsLineEndings ? annotation.lineCap.cgValue : .round)
            context.setLineJoin(annotation.supportsLineEndings ? annotation.lineJoin.cgValue : .round)
            context.setMiterLimit(10)
            context.setLineDash(phase: 0, lengths: annotation.strokeStyle.pattern(width: annotation.lineWidth))
            if annotation.tool == .blur || annotation.tool == .pixelate {
                let region = annotation.bounds.integral.intersection(extent)
                if group != nil && mosaicSnapshot == nil { mosaicSnapshot = context.makeImage() }
                if !region.isEmpty, let snapshot = mosaicSnapshot ?? context.makeImage() {
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
            if annotation.tool == .magnifier {
                // A snapshot is scoped to this one draw, never stored in the model/history.
                // Keep redaction visible even when other lower marks are hidden in the lens.
                autoreleasepool {
                    var snapshot: CGImage?
                    if !annotation.magnifierShowsAnnotations, let baseImage { snapshot = baseImage }
                    else if let baseImage, !annotations.prefix(index).contains(where: { $0.tool != .eraser }) { snapshot = baseImage }
                    else { snapshot = context.makeImage() }
                    // A redaction added after a lens must also hide its magnified copy.
                    // Apply these as vectors in source coordinates, avoiding another raster.
                    let privacyMarks = annotations.filter { $0.tool == .redact || $0.tool == .eraser }
                    if let snapshot {
                        AnnotationMagnifierRenderer.draw(annotation, snapshot: snapshot, extent: extent,
                                                         privacyMarks: privacyMarks, in: context)
                    }
                }
                context.restoreGState(); continue
            }
            if annotation.tool == .spotlight {
                var transform = annotation.transform
                if let hole = annotation.spotlightShape.path(in: annotation.localBounds).copy(using: &transform) {
                    context.saveGState(); context.addRect(extent); context.addPath(hole); context.clip(using: .evenOdd)
                    context.setBlendMode(.sourceAtop) // Dim existing pixels without filling transparent capture gaps.
                    context.setFillColor(CGColor(gray: 0, alpha: min(1, max(0, annotation.spotlightDim))))
                    context.fill(extent); context.restoreGState()
                    if annotation.spotlightBorder { context.addPath(hole); context.strokePath() }
                }
                context.restoreGState(); continue
            }
            context.concatenate(annotation.transform)
            let rect = annotation.localBounds.standardized
            switch annotation.tool {
            case .select, .crop, .blur, .pixelate, .eraser, .spotlight, .magnifier: break
            case .watermark: AnnotationWatermarkLayout.draw(annotation, in: context)
            case .rectangle, .ellipse, .arc, .sector:
                if annotation.hasShapeFill && annotation.fillEnabled {
                    context.setFillColor(annotation.fillColor); context.addPath(annotation.outline); context.fillPath()
                }
                context.addPath(annotation.outline); context.strokePath()
            case .redact:
                context.setFillColor(annotation.color.copy(alpha: 1) ?? CGColor(gray: 0, alpha: 1))
                context.setShouldAntialias(false); context.fill(rect.integral)
            case .freehand, .highlighter:
                AnnotationFreehandRenderer.draw(annotation, in: context)
            case .line, .arrow, .polyline:
                AnnotationLineGeometry.draw(annotation, in: context)
            case .text:
                if annotation.fillEnabled {
                    context.setFillColor(annotation.fillColor); context.addPath(annotation.outline); context.fillPath()
                }
                AnnotationTextLayout.draw(annotation, context: context)
            case .number:
                NumberedCalloutRenderer.draw(annotation, in: context)
            }
            context.restoreGState()
        }
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
    let captureDate: Date
    let captureTimeZoneIdentifier: String
    let captureTimestampKnown: Bool
    var annotations: [ImageAnnotation] = []
    var tool: ImageEditorTool = .arrow { didSet { finishNumberComment(commit: true); cancelInteraction(); cropRect = nil; needsDisplay = true } }
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
    var onContentInvalidated: (() -> Void)?
    private(set) var contentRevision: UInt64 = 0
    var automaticMosaicReview: AutomaticMosaicReviewState? { didSet { needsDisplay = true } }
    var automaticMosaicDrawHandler: ((CGRect) -> Void)?
    var onAutomaticMosaicToggle: ((Int) -> Void)?
    var onAutomaticMosaicCancel: (() -> Void)?
    var onAutomaticMosaicApply: (() -> Void)?
    var onAutomaticMosaicLimit: ((String) -> Void)?
    var editingAnnotationID: UUID? { didSet { cachedImage = nil; needsDisplay = true } }
    private var selection: UUID?
    private var draft: ImageAnnotation?
    private var freehandGesture: AnnotationFreehandGesture?
    var pendingFreehand: ImageAnnotation? { draft?.isFreehandStroke == true ? draft : nil }
    private var polylinePreviewPoint: CGPoint?
    private var pointerTrackingArea: NSTrackingArea?
    var pendingPolylinePointCount: Int { draft?.tool == .polyline ? draft!.points.count : 0 }
    var pendingPolyline: ImageAnnotation? { draft?.tool == .polyline ? draft : nil }
    private var dragOrigin: CGPoint?
    private var movingOriginal: ImageAnnotation?
    private var activeHandle: AnnotationHandle?
    private var didBeginMoving = false
    private var cachedImage: CGImage?
    var retainedPresentationRaster: CGImage? { cachedImage }
    var selectedAnnotation: ImageAnnotation? { annotations.first { $0.id == selection } }
    private(set) var numberSequence = NumberedCalloutSequence()
    private var numberCommentSession: NumberedCalloutCommentSession?
    var activeNumberCommentInput: InlineAnnotationTextView? { numberCommentSession?.box.input }
    var canCreateNumber: Bool { !numberSequence.isExhausted && annotations.lazy.filter { $0.tool == .number }.count < NumberedCalloutSequence.maximumMarks }

    init(image: CGImage, captureDate: Date? = nil, timeZone: TimeZone = .current) {
        self.image = image; self.captureDate = captureDate ?? Date(); self.captureTimeZoneIdentifier = timeZone.identifier
        self.captureTimestampKnown = captureDate != nil
        super.init(frame: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        wantsLayer = true
        style.freehandSmoothing = true
        style.highlighterMode = .freehand; style.highlighterBlend = .multiply
        if captureDate == nil { style.watermarkTemplate = "PicShot · 编辑于 $yyyy-MM-dd HH:mm:ss$" }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private func resizeCanvas() {
        setFrameSize(NSSize(width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * displayScaleY))
        needsDisplay = true
    }

    func setContent(image: CGImage, annotations: [ImageAnnotation], numberSequence: NumberedCalloutSequence? = nil) {
        finishNumberComment(commit: false)
        contentRevision &+= 1; onContentInvalidated?()
        self.image = image; self.annotations = annotations
        if let numberSequence { self.numberSequence = numberSequence }
        selection = nil; draft = nil; freehandGesture = nil; polylinePreviewPoint = nil; cropRect = nil; cachedImage = nil
        movingOriginal = nil; dragOrigin = nil; activeHandle = nil; didBeginMoving = false
        resizeCanvas(); onChange?()
    }

    func flattened() -> CGImage? { ImageEditorRenderer.render(image: image, annotations: annotations) }
    func rasterForBoundaryPreview() -> CGImage? {
        if cachedImage == nil { cachedImage = flattened() }
        return cachedImage
    }
    func releasePresentationCache() { cachedImage = nil }

    func makeAnnotation(tool: ImageEditorTool, points: [CGPoint], text: String = "") -> ImageAnnotation {
        var result = style
        result.id = UUID(); result.tool = tool; result.points = points; result.text = text
        result.rotation = 0; result.textBoxSize = nil
        result.freehandCorners = []; result.freehandWasSimplified = false
        result.frozenTimestamp = captureDate; result.frozenTimeZoneIdentifier = captureTimeZoneIdentifier
        result.timestampIsCaptureDate = captureTimestampKnown
        result.magnifierSource = nil; result.mosaicLink = nil
        result.numberComment = ""; result.numberCommentSize = CGSize(width: 240, height: 80)
        if tool == .number { result.number = numberSequence.nextValue }
        if tool == .eraser { result.lineWidth = max(4, result.lineWidth) }
        if tool == .spotlight || tool == .magnifier { result.opacity = 1 }
        if tool == .redact { result.color = CGColor(gray: 0, alpha: 1); result.opacity = 1 }
        return result.sanitizedPathGeometry
    }

    func add(_ annotation: ImageAnnotation) {
        if annotation.tool == .number && annotations.lazy.filter({ $0.tool == .number }).count >= NumberedCalloutSequence.maximumMarks { return }
        onWillChange?()
        annotations.append(annotation.sanitizedPathGeometry); selection = annotation.id
        if annotation.tool == .number { numberSequence.didInsert(annotation.number) }
        changed()
    }

    func setNextNumber(_ value: Int) {
        var sequence = numberSequence; sequence.setNext(value)
        guard sequence != numberSequence else { return }
        onWillChange?(); numberSequence = sequence; onChange?()
    }

    func setNumberClosesGaps(_ enabled: Bool) {
        guard enabled != numberSequence.closesGapsOnDelete else { return }
        onWillChange?(); numberSequence.closesGapsOnDelete = enabled; onChange?()
    }

    func renumberAnnotations(startingAt start: Int) {
        finishNumberComment(commit: true); cancelInteraction()
        let count = annotations.filter { $0.tool == .number }.count
        let start = min(NumberedCalloutSequence.clamp(start), max(1, NumberedCalloutSequence.maximumValue - count + 1))
        guard count > 0 else { setNextNumber(start); return }
        onWillChange?()
        var value = start
        for index in annotations.indices where annotations[index].tool == .number {
            annotations[index].number = value; value += 1
        }
        numberSequence.didInsert(value - 1); changed()
    }

    func beginNumberComment() {
        finishNumberComment(commit: true)
        guard let selected = selectedAnnotation, selected.tool == .number else { return }
        let rect = selected.numberCommentRect.applying(selected.transform)
        let width = min(max(100, selected.numberCommentRect.width * zoom), max(80, bounds.width))
        let height = min(max(64, selected.numberCommentRect.height * displayScaleY), max(40, bounds.height))
        let frame = CGRect(x: min(max(0, rect.minX * zoom), max(0, bounds.width - width)),
                           y: min(max(0, rect.minY * displayScaleY), max(0, bounds.height - height)), width: width, height: height)
        let session = NumberedCalloutCommentSession(annotation: selected, frame: frame, zoom: zoom, verticalZoom: displayScaleY)
        session.box.onAccept = { [weak self] in self?.finishNumberComment(commit: true) }
        session.box.onCancel = { [weak self] in self?.finishNumberComment(commit: false) }
        numberCommentSession = session
        addSubview(session.box); session.box.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(session.box.input)
    }

    func finishNumberComment(commit: Bool) {
        guard let session = numberCommentSession else { return }
        numberCommentSession = nil
        var mark = session.annotation
        mark.numberComment = NumberedCalloutSequence.boundedComment(session.box.input.string)
        if session.box.wasResized {
            mark.numberCommentSize = session.resizedCommentSize
        }
        session.close()
        if commit && (mark.numberComment != session.annotation.numberComment || mark.numberCommentSize != session.annotation.numberCommentSize) {
            replaceAnnotation(id: mark.id, with: mark)
        }
        window?.makeFirstResponder(self)
    }

    private func changed() {
        contentRevision &+= 1; onContentInvalidated?()
        cachedImage = nil; needsDisplay = true; onChange?()
    }

    func canApplyAutomaticMosaic(count: Int, replacing id: UUID?) -> Bool {
        let retained = annotations.filter { $0.mosaicLink != nil && $0.id != id }.count
        return count > 0 && count <= AutomaticMosaicModelLimits.maximumLinkedAnnotations - retained
    }

    @discardableResult
    func applyAutomaticMosaic(_ replacements: [ImageAnnotation], replacing id: UUID?) -> Bool {
        guard !replacements.isEmpty else { return false }
        guard canApplyAutomaticMosaic(count: replacements.count, replacing: id) else {
            onAutomaticMosaicLimit?("最多保留 200 个关联区域，请先删除部分区域"); return false
        }
        onWillChange?()
        if let id { annotations.removeAll { $0.id == id } }
        annotations.append(contentsOf: replacements)
        selection = replacements.first?.id; changed(); return true
    }

    func setMosaicSync(_ enabled: Bool) {
        guard let group = selectedAnnotation?.mosaicLink?.groupID else { return }
        onWillChange?()
        for index in annotations.indices where annotations[index].mosaicLink?.groupID == group {
            annotations[index].mosaicLink?.synchronizes = enabled
        }
        changed()
    }

    @discardableResult
    func addMosaicCorrection(_ rect: CGRect, relativeTo selected: ImageAnnotation) -> Bool {
        guard let link = selected.mosaicLink, rect.width >= 2, rect.height >= 2 else { return false }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let targets = link.synchronizes ? link.includedTargets : [link.target]
        let addition = UUID()
        let marks = targets.compactMap { target -> ImageAnnotation? in
            let box = rect.offsetBy(dx: target.minX - link.target.minX, dy: target.minY - link.target.minY)
            guard extent.contains(box) else { return nil }
            var mark = selected; mark.id = UUID(); mark.rotation = 0
            mark.points = [box.origin, CGPoint(x: box.maxX, y: box.maxY)]
            mark.mosaicLink = link.forTarget(target, additionID: addition)
            return mark
        }
        // Never partially synchronize a correction that leaves the image bounds.
        guard marks.count == targets.count else {
            onAutomaticMosaicLimit?("补充区域超出图片边缘；请在所有匹配内选择区域"); return false
        }
        return applyAutomaticMosaic(marks, replacing: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.scaleBy(x: zoom, y: displayScaleY)
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        if cachedImage == nil { cachedImage = ImageEditorRenderer.render(image: image, annotations: annotations.filter { $0.id != editingAnnotationID }) }
        let displayed: CGImage
        if var draft, automaticMosaicDrawHandler == nil {
            if draft.tool == .polyline, let preview = polylinePreviewPoint, draft.points.last != preview,
               draft.points.count < ImageAnnotation.maximumPolylinePoints { draft.points.append(preview) }
            // An eraser needs the original vector stack; a flattened preview would erase
            // the captured pixels. No draft is retained in undo until mouse-up.
            if draft.tool == .eraser || draft.tool == .magnifier {
                displayed = ImageEditorRenderer.render(image: image, annotations: annotations + [draft]) ?? cachedImage ?? image
            } else { displayed = ImageEditorRenderer.render(image: cachedImage ?? image, annotations: [draft]) ?? cachedImage ?? image }
        } else { displayed = cachedImage ?? image }
        context.draw(displayed, in: imageBounds)
        if let selected = selectedAnnotation, tool == .select { drawSelection(selected, context: context) }
        if let draft, draft.tool == .eraser {
            context.saveGState(); context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / zoom)
            context.addPath(draft.mergedEraserPath); context.strokePath(); context.restoreGState()
        }
        if let draft, draft.tool == .polyline {
            for point in draft.points {
                let rect = CGRect(x: point.x - 3 / zoom, y: point.y - 3 / zoom, width: 6 / zoom, height: 6 / zoom)
                context.setFillColor(NSColor.white.cgColor); context.fill(rect)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / zoom); context.stroke(rect)
            }
        }
        if let review = automaticMosaicReview { review.draw(in: context, zoom: zoom) }
        if automaticMosaicDrawHandler != nil, let draft { drawSelectionBox(CGPath(rect: draft.localBounds, transform: nil), context: context) }
        if let cropRect { drawSelectionBox(CGPath(rect: cropRect, transform: nil), context: context) }
        context.restoreGState()
    }

    private func drawSelection(_ annotation: ImageAnnotation, context: CGContext) {
        var transform = annotation.transform
        let box = CGPath(rect: annotation.localBounds, transform: &transform)
        if !annotation.isLinear { drawSelectionBox(box, context: context) }
        if annotation.tool == .magnifier {
            drawSelectionBox(annotation.magnifierShape.path(in: annotation.magnifierSourceRect), context: context)
        }
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
        finishNumberComment(commit: true)
        onBeforeInteraction?()
        window?.makeFirstResponder(self)
        if let review = automaticMosaicReview, automaticMosaicDrawHandler == nil {
            if let index = review.candidates.lastIndex(where: { $0.rect.insetBy(dx: -3 / zoom, dy: -3 / zoom).contains(imagePoint(event)) }) {
                onAutomaticMosaicToggle?(index)
            }
            return
        }
        if tool == .polyline {
            // The first click of a double-click already fixed the final vertex.
            // Finish before using the second location, which may contain hand jitter.
            if event.clickCount >= 2, pendingPolylinePointCount > 0 { finishPolyline(); return }
            let point = imagePoint(event)
            appendPolylinePoint(point, shift: event.modifierFlags.contains(.shift))
            dragOrigin = point
            if event.clickCount >= 2 { finishPolyline() }
            return
        }
        cancelInteraction()
        let point = imagePoint(event, clamped: tool != .select)
        dragOrigin = point
        if tool == .select {
            if event.clickCount != 2, !event.modifierFlags.contains(.option), let selected = selectedAnnotation, let handle = selected.handle(at: point, zoom: zoom) {
                activeHandle = handle; movingOriginal = selected
            } else {
                let hits = annotations.reversed().filter { $0.hitTest(point, tolerance: 6 / zoom) }
                if event.modifierFlags.contains(.option), let current = hits.firstIndex(where: { $0.id == selection }), !hits.isEmpty {
                    selection = hits[(current + 1) % hits.count].id
                } else { selection = hits.first?.id }
                movingOriginal = selectedAnnotation
                if let selected = selectedAnnotation, selected.tool == .magnifier,
                   selected.magnifierSourceRect.contains(point), !selected.localBounds.contains(point) { activeHandle = .source }
            }
            if let selected = selectedAnnotation {
                style = selected
                if event.clickCount == 2, selected.tool == .text {
                    movingOriginal = nil; onRequestText?(selected.points.first ?? point, selected.id)
                }
                if event.clickCount == 2, selected.tool == .number {
                    movingOriginal = nil; beginNumberComment()
                }
            }
            needsDisplay = true; onChange?()
        } else if tool == .text {
            onRequestText?(point, nil)
        } else if tool == .watermark {
            var annotation = makeAnnotation(tool: .watermark,
                points: [.zero, CGPoint(x: image.width, y: image.height)])
            annotation.watermarkTemplate = style.watermarkTemplate
            add(annotation)
        } else if tool == .number {
            if let mark = annotations.reversed().first(where: { $0.tool == .number && $0.hitTest(point, tolerance: 3 / zoom) }) {
                selection = mark.id; style = mark; dragOrigin = nil; needsDisplay = true; onChange?()
                if event.clickCount == 2 { beginNumberComment() }
                return
            }
            guard canCreateNumber else { onChange?(); return }
            draft = makeAnnotation(tool: .number, points: [point]); needsDisplay = true
        } else {
            draft = makeAnnotation(tool: tool, points: [point, point]); cropRect = nil
            if draft?.isFreehandStroke == true {
                draft?.points = [point]
                freehandGesture = AnnotationFreehandGesture(point: point, shift: event.modifierFlags.contains(.shift))
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event, clamped: tool != .select)
        if tool == .polyline { updatePolylinePreview(point, shift: event.modifierFlags.contains(.shift)); return }
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
                annotations[index] = original.tool == .magnifier ? original.translatedLens(by: delta) : original.translated(by: delta)
            }
            changed()
        } else if draft?.isFreehandStroke == true {
            updateFreehand(point, shift: event.modifierFlags.contains(.shift))
        } else if tool == .eraser && draft?.eraserMode == .brush {
            if let last = draft?.points.last, hypot(point.x - last.x, point.y - last.y) >= 0.75 / zoom {
                if (draft?.points.count ?? 0) >= ImageAnnotation.maximumGesturePoints {
                    // Progressive decimation bounds vector history even during very long gestures.
                    let reduced = draft!.points.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                    draft?.points = reduced
                }
                draft?.points.append(point)
            }
            needsDisplay = true
        } else if draft != nil {
            var end = point
            if event.modifierFlags.contains(.shift), [.rectangle, .ellipse, .arc, .sector, .crop, .spotlight, .magnifier].contains(tool) {
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
        if tool == .polyline {
            if pendingPolylinePointCount > 0, let origin = dragOrigin {
                let point = imagePoint(event)
                if hypot(point.x - origin.x, point.y - origin.y) > 2 / zoom {
                    appendPolylinePoint(point, shift: event.modifierFlags.contains(.shift))
                }
            }
            dragOrigin = nil; return
        }
        defer { draft = nil; freehandGesture = nil; dragOrigin = nil; movingOriginal = nil; activeHandle = nil; didBeginMoving = false; needsDisplay = true }
        if draft?.isFreehandStroke == true {
            updateFreehand(imagePoint(event), shift: event.modifierFlags.contains(.shift), final: true)
        }
        if didBeginMoving, let original = movingOriginal, let index = annotations.firstIndex(where: { $0.id == original.id }) {
            let edited = annotations[index]
            annotations[index] = original
            onWillChange?() // Exactly one original snapshot for an entire gesture, none for Escape.
            annotations[index] = edited
            propagateMosaicEdit(from: original, to: edited)
            style = edited; changed()
        }
        guard var draft else { return }
        if tool == .number {
            if let center = draft.points.first, draft.points.count > 1,
               hypot(draft.points[1].x - center.x, draft.points[1].y - center.y) <= draft.numberRadius + 2 {
                draft.points = [center]
            }
            add(draft); return
        }
        if let handler = automaticMosaicDrawHandler {
            let rect = draft.localBounds.standardized.integral
            if rect.width >= 2 && rect.height >= 2 { handler(rect) }
            return
        }
        if draft.isFreehandStroke {
            if !draft.points.isEmpty { add(draft) }; return
        }
        if tool == .eraser && draft.eraserMode == .brush {
            let last = imagePoint(event)
            if let previous = draft.points.last, previous != last {
                if draft.points.count >= ImageAnnotation.maximumGesturePoints { draft.points[draft.points.count - 1] = last }
                else { draft.points.append(last) }
            }
            if !annotations.isEmpty { add(draft) }; return
        }
        if tool == .magnifier {
            let source = draft.localBounds.standardized
            guard source.width > 1, source.height > 1 else { return }
            draft.magnifierSource = source
            draft = draft.resizedMagnifierLens(scale: draft.effectiveMagnifierScale)
            let size = draft.localBounds.size
            let x = min(max(0, source.maxX + 20), max(0, CGFloat(image.width) - size.width))
            let y = min(max(0, source.midY - size.height / 2), max(0, CGFloat(image.height) - size.height))
            draft.points = [CGPoint(x: x, y: y), CGPoint(x: x + size.width, y: y + size.height)]
        }
        if tool == .crop { cropRect = draft.localBounds; onChange?(); return }
        if draft.isArc && (draft.localBounds.width <= 1 || draft.localBounds.height <= 1) { return }
        guard draft.bounds.width > 1 || draft.bounds.height > 1 else { return }
        add(draft)
    }

    func cancelAutomaticMosaicGesture() { cancelInteraction() }

    private func cancelInteraction() {
        if didBeginMoving, let original = movingOriginal, let index = annotations.firstIndex(where: { $0.id == original.id }) {
            annotations[index] = original; changed()
        }
        draft = nil; freehandGesture = nil; polylinePreviewPoint = nil; dragOrigin = nil; movingOriginal = nil; activeHandle = nil; didBeginMoving = false
        needsDisplay = true
    }

    func cancelPendingFreehand() {
        guard pendingFreehand != nil else { return }
        cancelInteraction(); onChange?()
    }

    private func updateFreehand(_ point: CGPoint, shift: Bool, final: Bool = false) {
        guard draft?.isFreehandStroke == true, freehandGesture != nil else { return }
        let previouslySimplified = freehandGesture!.wasSimplified
        freehandGesture!.sample(point, shift: shift, constraint: draft!.freehandConstraint,
            extent: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            minimumDistance: 0.75 / max(0.05, zoom), final: final)
        draft?.points = freehandGesture!.points; draft?.freehandCorners = freehandGesture!.corners
        draft?.freehandWasSimplified = freehandGesture!.wasSimplified
        needsDisplay = true
        if previouslySimplified != freehandGesture!.wasSimplified { onChange?() }
    }

    override func flagsChanged(with event: NSEvent) {
        if draft?.isFreehandStroke == true { freehandGesture?.setShift(event.modifierFlags.contains(.shift)) }
        else { super.flagsChanged(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); pointerTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        if tool == .polyline { updatePolylinePreview(imagePoint(event), shift: event.modifierFlags.contains(.shift)) }
        else { super.mouseMoved(with: event) }
    }

    private func constrainedPolylinePoint(_ point: CGPoint, shift: Bool) -> CGPoint {
        guard shift, let anchor = draft?.points.last else { return point }
        let distance = hypot(point.x - anchor.x, point.y - anchor.y)
        let angle = (atan2(point.y - anchor.y, point.x - anchor.x) / (.pi / 4)).rounded() * (.pi / 4)
        // Shorten at the image boundary instead of clipping x/y independently and losing the angle.
        let vector = CGPoint(x: distance * cos(angle), y: distance * sin(angle))
        var fraction: CGFloat = 1
        if vector.x > 0 { fraction = min(fraction, (CGFloat(image.width) - anchor.x) / vector.x) }
        if vector.x < 0 { fraction = min(fraction, -anchor.x / vector.x) }
        if vector.y > 0 { fraction = min(fraction, (CGFloat(image.height) - anchor.y) / vector.y) }
        if vector.y < 0 { fraction = min(fraction, -anchor.y / vector.y) }
        return CGPoint(x: anchor.x + vector.x * max(0, fraction), y: anchor.y + vector.y * max(0, fraction))
    }

    private func updatePolylinePreview(_ point: CGPoint, shift: Bool) {
        guard pendingPolylinePointCount > 0 else { return }
        polylinePreviewPoint = constrainedPolylinePoint(point, shift: shift); needsDisplay = true
    }

    private func appendPolylinePoint(_ point: CGPoint, shift: Bool) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if draft?.tool != .polyline {
            cancelInteraction(); selection = nil
            draft = makeAnnotation(tool: .polyline, points: [point])
        } else {
            let next = constrainedPolylinePoint(point, shift: shift)
            guard let last = draft?.points.last, hypot(next.x - last.x, next.y - last.y) > 0.5 / zoom else { return }
            guard pendingPolylinePointCount < ImageAnnotation.maximumPolylinePoints else { finishPolyline(); return }
            draft?.points.append(next)
        }
        polylinePreviewPoint = nil; needsDisplay = true; onChange?()
        if pendingPolylinePointCount == ImageAnnotation.maximumPolylinePoints { finishPolyline() }
    }

    func removeLastPolylineVertex() {
        guard pendingPolylinePointCount > 0 else { return }
        draft?.points.removeLast(); polylinePreviewPoint = nil
        if draft?.points.isEmpty == true { cancelInteraction() }
        needsDisplay = true; onChange?()
    }

    func finishPolyline() {
        guard let path = pendingPolyline else { return }
        cancelInteraction()
        if path.points.count >= 2 { add(path) }
        else { onChange?() }
    }

    func cancelPolyline() {
        guard pendingPolylinePointCount > 0 else { return }
        cancelInteraction(); onChange?()
    }

    func updatePendingPolyline(_ edit: (inout ImageAnnotation) -> Void) {
        guard var path = pendingPolyline else { return }
        edit(&path); draft = path.sanitizedPathGeometry; needsDisplay = true
    }

    func updateSelected(_ edit: (inout ImageAnnotation) -> Void) {
        guard let selection, let index = annotations.firstIndex(where: { $0.id == selection }) else { return }
        onWillChange?()
        let original = annotations[index]
        let previousScale = annotations[index].magnifierScale
        edit(&annotations[index])
        annotations[index] = annotations[index].sanitizedPathGeometry
        if annotations[index].tool == .magnifier, annotations[index].magnifierScale != previousScale {
            annotations[index] = annotations[index].resizedMagnifierLens(scale: annotations[index].effectiveMagnifierScale)
        }
        let edited = annotations[index]
        propagateMosaicEdit(from: original, to: edited)
        style = annotations[index]; changed()
    }

    private func propagateMosaicEdit(from original: ImageAnnotation, to edited: ImageAnnotation) {
        guard let link = original.mosaicLink else { return }
        if !link.synchronizes {
            // A geometrically changed single result no longer represents the same
            // source location. Detach it rather than reuse stale offsets later.
            if original.points != edited.points || original.rotation != edited.rotation,
               let index = annotations.firstIndex(where: { $0.id == edited.id }) {
                annotations[index].mosaicLink = nil
                excludeMosaicRootTarget(link)
            }
            return
        }
        for peer in annotations.indices where annotations[peer].id != original.id && annotations[peer].mosaicLink?.groupID == link.groupID
            && annotations[peer].mosaicLink?.additionID == link.additionID {
            let target = annotations[peer].mosaicLink!.target
            var updated = edited.translated(by: CGSize(width: target.minX - link.target.minX, height: target.minY - link.target.minY))
            updated.id = annotations[peer].id; updated.mosaicLink = annotations[peer].mosaicLink
            annotations[peer] = updated
        }
    }

    private func excludeMosaicRootTarget(_ link: AutomaticMosaicLink) {
        // Deleting a correction only removes that addition's member. Deleting or
        // detaching an original result excludes its target from future additions.
        guard link.additionID == link.rootAdditionID else { return }
        for index in annotations.indices where annotations[index].mosaicLink?.groupID == link.groupID {
            annotations[index].mosaicLink?.includedTargets.removeAll { $0 == link.target }
            if annotations[index].mosaicLink?.excludedTargets.contains(link.target) == false {
                annotations[index].mosaicLink?.excludedTargets.append(link.target)
            }
        }
    }

    func updateSelectedStyle(color newColor: CGColor? = nil, width: CGFloat? = nil) {
        updateSelected {
            if let newColor { $0.color = newColor }
            if let width { $0.lineWidth = max(1, width) }
        }
    }

    func replaceAnnotation(id: UUID, with annotation: ImageAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        onWillChange?(); annotations[index] = annotation.sanitizedPathGeometry; selection = id; changed()
    }

    func updateText(id: UUID, text: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id && $0.tool == .text }) else { return }
        onWillChange?(); annotations[index].text = text; changed()
    }

    func duplicateSelection() {
        finishNumberComment(commit: true)
        cancelInteraction()
        guard let selected = selectedAnnotation else { return }
        if selected.mosaicLink != nil {
            addMosaicCorrection(selected.localBounds.offsetBy(dx: 20, dy: -20), relativeTo: selected)
        } else {
            var copy = selected.translated(by: CGSize(width: 20, height: -20)); copy.id = UUID()
            if copy.tool == .number {
                guard canCreateNumber else { return }
                copy.number = numberSequence.nextValue
            }
            add(copy)
        }
    }

    func clearAnnotations() {
        finishNumberComment(commit: false)
        cancelInteraction()
        guard !annotations.isEmpty else { return }
        onWillChange?(); annotations.removeAll(); selection = nil; changed()
    }

    func deleteSelection() {
        finishNumberComment(commit: false)
        cancelInteraction()
        guard let selection, annotations.contains(where: { $0.id == selection }) else { return }
        let link = selectedAnnotation?.mosaicLink
        let deletedNumber = selectedAnnotation.flatMap { $0.tool == .number ? $0.number : nil }
        onWillChange?()
        annotations.removeAll { mark in
            mark.id == selection || (link?.synchronizes == true && mark.mosaicLink?.groupID == link?.groupID
                && mark.mosaicLink?.additionID == link?.additionID)
        }
        if let link, !link.synchronizes { excludeMosaicRootTarget(link) }
        if let deletedNumber, numberSequence.closesGapsOnDelete {
            for index in annotations.indices where annotations[index].tool == .number && annotations[index].number > deletedNumber {
                annotations[index].number -= 1
            }
            numberSequence.didDelete(deletedNumber)
        }
        self.selection = nil; changed()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta.isFinite, abs(delta) > 0.001 else { super.scrollWheel(with: event); return }
        let active = tool == .select ? selectedAnnotation?.tool : tool
        let step: CGFloat = delta > 0 ? 1 : -1
        if active == .number {
            finishNumberComment(commit: true)
            if selectedAnnotation?.tool == .number { updateSelected { $0.lineWidth = min(20, max(3.5, $0.lineWidth + step * 0.5)) } }
            else { style.lineWidth = min(20, max(3.5, style.lineWidth + step * 0.5)); onChange?() }
            return
        }
        if active == .eraser {
            if tool == .select {
                updateSelected { $0.lineWidth = min(256, max(2, $0.lineWidth + step * 2)) }
            } else {
                style.lineWidth = min(256, max(2, style.lineWidth + step * 2)); onChange?()
            }
            return
        }
        if active == .spotlight {
            let edit: (inout ImageAnnotation) -> Void = { annotation in
                if event.modifierFlags.contains(.control) {
                    annotation.lineWidth = min(64, max(1, annotation.lineWidth + step))
                } else if event.modifierFlags.contains(.shift), annotation.points.count > 1 {
                    let box = annotation.localBounds, factor = step > 0 ? CGFloat(1.05) : CGFloat(1 / 1.05)
                    annotation.points = annotation.points.map { CGPoint(x: box.midX + ($0.x - box.midX) * factor,
                                                                        y: box.midY + ($0.y - box.midY) * factor) }
                } else { annotation.spotlightDim = min(1, max(0, annotation.spotlightDim + step * 0.05)) }
            }
            if selectedAnnotation?.tool == .spotlight { updateSelected(edit) }
            else { edit(&style); onChange?() }
            return
        }
        if active == .magnifier {
            let point = imagePoint(event, clamped: false)
            if let selected = selectedAnnotation, selected.tool == .magnifier {
                updateSelected {
                    if selected.hitTest(point, tolerance: 0) { $0.magnifierScale = min(8, max(1, $0.magnifierScale + step * 0.1)) }
                    else { $0.lineWidth = min(64, max(1, $0.lineWidth + step)) }
                }
            } else { style.magnifierScale = min(8, max(1, style.magnifierScale + step * 0.1)); onChange?() }
            return
        }
        super.scrollWheel(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        // NSWindow visits descendants for key equivalents even when the canvas is
        // not first responder. Let AppKit's Edit menu/text responder own text undo,
        // redo, copy and other editing keys, including inspector field editors.
        // Save remains an explicit document action and commits pending input.
        if key != "s", window?.firstResponder is NSTextView { return false }
        switch key {
        case "z":
            if pendingPolylinePointCount > 0 {
                if !event.modifierFlags.contains(.shift) { removeLastPolylineVertex() }; return true
            }
            cancelInteraction()
            if event.modifierFlags.contains(.shift) { onRedo?() } else { onUndo?() }
            return true
        case "d":
            if pendingPolylinePointCount == 0 { duplicateSelection() }; return true
        case "c": onCopy?(); return true
        case "s": onExport?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if automaticMosaicReview != nil || automaticMosaicDrawHandler != nil {
            if event.keyCode == 53 { onAutomaticMosaicCancel?(); return }
            if event.keyCode == 36 || event.keyCode == 76 { onAutomaticMosaicApply?(); return }
            if automaticMosaicReview != nil { return }
        }
        switch event.keyCode {
        case 51, 117:
            if pendingPolylinePointCount > 0 { removeLastPolylineVertex() } else { deleteSelection() }
        case 36, 76:
            if pendingPolylinePointCount > 0 { finishPolyline() }
            else if cropRect != nil { onApplyCrop?() }
            else if let selected = selectedAnnotation, selected.tool == .text {
                onRequestText?(selected.points.first ?? .zero, selected.id)
            } else if selectedAnnotation?.tool == .number { beginNumberComment()
            } else { super.keyDown(with: event) }
        case 53:
            let wasEditing = draft != nil || didBeginMoving || cropRect != nil || (tool == .select && selection != nil)
            cancelInteraction(); selection = nil; cropRect = nil; needsDisplay = true; onChange?()
            if !wasEditing { onCancel?() }
        case 123, 124, 125, 126:
            guard pendingPolylinePointCount == 0 else { return }
            cancelInteraction()
            guard tool == .select, selectedAnnotation != nil else { super.keyDown(with: event); return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta = CGSize(width: event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0),
                               height: event.keyCode == 125 ? -step : (event.keyCode == 126 ? step : 0))
            updateSelected {
                if $0.tool == .magnifier {
                    if event.modifierFlags.contains(.option) { $0.magnifierSource = $0.magnifierSourceRect.offsetBy(dx: delta.width, dy: delta.height) }
                    else { $0 = $0.translatedLens(by: delta) }
                } else { $0 = $0.translated(by: delta) }
            }
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "a", !event.modifierFlags.contains(.command), selectedAnnotation?.tool == .number { beginNumberComment() }
            else { super.keyDown(with: event) }
        }
    }
}

/// The save chevron has an explicit hit frame. A stock popup's ornament
/// alignment insets otherwise make its frame wider than its width constraint.
@MainActor
final class EditorSaveActionsButton: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }
    override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }
}

@MainActor
final class ImageEditorController: NSWindowController, NSWindowDelegate {
    private struct Snapshot { var image: CGImage; var annotations: [ImageAnnotation]; var selectionFrame: CGRect?; var pinPresentation: PinEditorPresentation?; var numberSequence: NumberedCalloutSequence }
    private let canvas: ImageEditorCanvas
    private let scrollView = NSScrollView()
    private let workspace = EditorWorkspaceView(frame: .zero)
    private let toolbar = EditorFloatingSurface(frame: .zero)
    private let inspector = AnnotationInspector(frame: .zero)
    private let onSave: (CGImage) -> Void
    private let onPin: (CGImage) -> Void
    private let onOCR: (CGImage) -> Void
    private let onTranslate: ((CGImage) -> Void)?
    private let onApply: ((CGImage) -> Bool)?
    private let saveWorkflow: SaveWorkflowPresenter?
    private let copyAction: (CGImage) -> Void
    let saveActions = EditorSaveActionsButton()
    private var presentation: FrozenCapturePresentation?
    private var pinPresentation: PinEditorPresentation?
    private let pinClipView = NSView()
    private var screenObserver: NSObjectProtocol?
    private var undoStates: [Snapshot] = []
    private var redoStates: [Snapshot] = []
    private var toolButtons: [ImageEditorTool: NSButton] = [:]
    private var subtoolMenus: [ImageEditorTool: NSPopUpButton] = [:]
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
    private var boundaryPreviewFrame: CGRect?
    let automaticMosaicReviewSurface = AutomaticMosaicReviewSurface(frame: .zero)
    let automaticMosaicMatcher = AutomaticMosaicMatcher()
    var automaticMosaicTask: Task<Void, Never>?
    var automaticMosaicGeneration = UUID()
    private(set) var automaticMosaicReviewState: AutomaticMosaicReviewState?
    var automaticMosaicIsComputing: Bool { automaticMosaicTask != nil }
    var automaticMosaicBlocksOutput: Bool { automaticMosaicReviewState != nil || canvas.automaticMosaicDrawHandler != nil }
    var automaticMosaicWorkspace: NSView { workspace }
    // A test may delay a real matcher result; production always uses the actor above.
    var automaticMosaicFind: ((CGImage, RepeatedRegionPixelRect) async throws -> RepeatedRegionMatchResult)?
    func setAutomaticMosaicReviewState(_ state: AutomaticMosaicReviewState?) { automaticMosaicReviewState = state }
    func refreshAutomaticMosaicInterface() { updateStatus() }
    func automaticMosaicOutputAction(_ action: Selector?) -> Bool {
        [#selector(copyResult), #selector(exportResult), #selector(pinResult), #selector(applyResult),
         #selector(saveResult), #selector(recognizeResult), #selector(translateResult),
         #selector(quickSaveResult), #selector(saveCopyResult)].contains { $0 == action }
    }
    func installAutomaticMosaicInspector() {
        inspector.onAutomaticMosaic = { [weak self] in self?.startAutomaticMosaic() }
        inspector.onMosaicSync = { [weak self] enabled in self?.canvas.setMosaicSync(enabled) }
        inspector.onMosaicAdd = { [weak self] in self?.beginLinkedMosaicCorrection() }
    }
    var onClose: (() -> Void)?
    private(set) var isClosed = false
    /// Current/history/cache/frozen rasters once per identity, with a reserved
    /// redraw raster when the cache is empty. This is not total process memory.
    var estimatedAdmissionRasterBytes: Int {
        var images = [canvas.image] + undoStates.map(\.image) + redoStates.map(\.image)
        images += [canvas.retainedPresentationRaster, presentation?.frozenImage,
                   workspace.frozenImage, workspace.boundaryPreviewImage].compactMap { $0 }
        return EditorAdmissionPolicy.sum([EditorRasterEstimate.retainedBytes(images),
            canvas.retainedPresentationRaster == nil ? EditorRasterEstimate.redrawBytes(canvas.image) : 0])
    }
    var annotationCanvas: ImageEditorCanvas { canvas }
    var activeInlineTextView: InlineAnnotationTextView? { inlineBox?.input }
    var floatingToolbarFrame: CGRect { toolbar.frame }
    var dimensionLabelFrame: CGRect { status.frame }
    var floatingSurfaceIsDark: Bool { toolbar.isDarkSurface }
    var toolbarSymbolPointSize: CGFloat { EditorFloatingSurface.symbolPointSize }
    /// Bounded, identifier/geometry-only diagnostics for native regression
    /// fixtures. No screenshot pixels, annotation text or personal paths.
    func nativeToolbarDiagnostics() -> [String: Any] {
        func item(_ view: NSView) -> [String: Any] {
            ["id": view.identifier?.rawValue ?? "", "class": String(describing: type(of: view)),
             "hidden": view.isHidden, "hiddenAncestor": view.isHiddenOrHasHiddenAncestor,
             "hasSuperview": view.superview != nil, "windowMatches": view.window === window,
             "frame": NSStringFromRect(view.frame)]
        }
        return ["editorClosed": isClosed, "hasContentView": window?.contentView != nil,
                "windowVisible": window?.isVisible ?? false, "windowFrame": window.map { NSStringFromRect($0.frame) } ?? "missing",
                "frozenPresentationActive": presentation != nil, "toolbarFrame": NSStringFromRect(toolbar.frame),
                "toolbarHasSuperview": toolbar.superview != nil,
                "rootChildren": Array((window?.contentView?.subviews ?? []).prefix(12)).map(item),
                "toolbarSubviews": Array(toolbar.subviews.prefix(48)).map(item),
                "toolbarOwnedViews": Array(toolbar.views.prefix(48)).map(item),
                "detachedViews": Array(toolbar.detachedViews.prefix(48)).map(item),
                "rectangle": toolButtons[.rectangle].map(item) ?? ["missing": true]]
    }
    var contextualPaletteFrame: CGRect { inspector.frame }
    var contextualPaletteVisible: Bool { !inspector.isHidden }
    var editorSelectionFrame: CGRect { workspace.selectionFrame }
    var captureBoundaryWorkspace: EditorWorkspaceView { workspace }
    var editorImageScreenFrame: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
    }
    var pinnedViewportScreenFrame: CGRect? { pinPresentation?.viewportFrame }

    init(image: CGImage, presentation: FrozenCapturePresentation? = nil,
         onSave: @escaping (CGImage) -> Void, onPin: @escaping (CGImage) -> Void,
         onOCR: @escaping (CGImage) -> Void, onTranslate: ((CGImage) -> Void)? = nil,
         onApply: ((CGImage) -> Bool)? = nil, captureDate: Date? = nil, saveWorkflow: SaveWorkflowPresenter? = nil, copyAction: ((CGImage) -> Void)? = nil) {
        canvas = ImageEditorCanvas(image: image, captureDate: presentation?.capturedAt ?? captureDate)
        self.presentation = presentation
        self.onSave = onSave; self.onPin = onPin; self.onOCR = onOCR
        self.onTranslate = onTranslate; self.onApply = onApply; self.saveWorkflow = saveWorkflow ?? SaveWorkflowPresenter.application
        self.copyAction = copyAction ?? { copyImage($0) }
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
        installAutomaticMosaic()
        inspector.onClearAnnotations = { [weak self] in self?.canvas.clearAnnotations() }
        inspector.onFinishPolyline = { [weak self] in
            self?.canvas.finishPolyline(); self?.window?.makeFirstResponder(self?.canvas)
        }
        inspector.onCancelPolyline = { [weak self] in
            self?.canvas.cancelPolyline(); self?.window?.makeFirstResponder(self?.canvas)
        }
        inspector.numberControls.onNext = { [weak self] value in self?.canvas.setNextNumber(value) }
        inspector.numberControls.onRenumber = { [weak self] value in self?.canvas.renumberAnnotations(startingAt: value) }
        inspector.numberControls.onCloseGaps = { [weak self] enabled in self?.canvas.setNumberClosesGaps(enabled) }
        inspector.numberControls.onComment = { [weak self] in self?.canvas.beginNumberComment() }
        inspector.onEdit = { [weak self] edit in
            guard let self else { return }
            self.canvas.finishNumberComment(commit: true)
            self.canvas.cancelPendingFreehand()
            edit(&self.canvas.style)
            if var annotation = self.inlineAnnotation, let box = self.inlineBox {
                edit(&annotation); self.inlineAnnotation = annotation
                box.applyStyle(annotation, zoom: self.canvas.zoom)
                self.updateStatus(); return
            }
            if self.canvas.pendingPolylinePointCount > 0 {
                self.canvas.updatePendingPolyline(edit); self.updateStatus(); return
            }
            if self.canvas.tool == .select || ([ImageEditorTool.watermark, .magnifier, .spotlight, .arc, .sector, .polyline, .arrow, .line, .text, .number].contains(self.canvas.tool)
                && self.canvas.selectedAnnotation?.tool == self.canvas.tool) { self.canvas.updateSelected(edit) }
            self.updateStatus()
        }
        workspace.onLayout = { [weak self] in self?.layoutInterface() }
        workspace.onDismiss = { [weak self] in self?.cancelEditor() }
        workspace.onOutsideClick = { [weak self] in self?.finishInlineText(commit: true) }
        if presentation != nil {
            workspace.selectionContent = canvas
            workspace.onBoundaryBegin = { [weak self] in self?.beginBoundaryResize() }
            workspace.onBoundaryChange = { [weak self] frame in self?.previewBoundaryResize(frame) }
            workspace.onBoundaryEnd = { [weak self] commit in self?.finishBoundaryResize(commit: commit) }
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

    /// Exact pin viewport/image geometry, including an existing zoom/pan offset.
    /// The new borderless window contains only the viewport and adjacent controls;
    /// its unused area is transparent and no desktop pixels are acquired.
    @discardableResult
    func showPinned(_ placement: PinEditorPresentation, desktopVisibility: PinDesktopVisibility = .defaultMode) -> Bool {
        guard presentation == nil, onApply != nil,
              [placement.viewportFrame.minX, placement.viewportFrame.minY, placement.viewportFrame.width, placement.viewportFrame.height,
               placement.imageFrame.minX, placement.imageFrame.minY, placement.imageFrame.width, placement.imageFrame.height].allSatisfy({ $0.isFinite }),
              placement.viewportFrame.width > 0, placement.viewportFrame.height > 0,
              placement.imageFrame.width > 0, placement.imageFrame.height > 0 else { return false }
        finishInlineText(commit: true)
        pinPresentation = placement
        let oldWindow = window
        let panel = EditorOverlayWindow(contentRect: placement.viewportFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = placement.level; panel.collectionBehavior = PinDesktopVisibilityPolicy.behavior(desktopVisibility, preserving: [.fullScreenAuxiliary])
        oldWindow?.delegate = nil; oldWindow?.contentView = nil
        window = panel; panel.delegate = self; panel.contentView = workspace
        oldWindow?.orderOut(nil); oldWindow?.close()
        workspace.transparentBackground = true; workspace.frozenImage = nil
        scrollView.documentView = nil; scrollView.removeFromSuperview(); canvas.removeFromSuperview()
        pinClipView.wantsLayer = true; pinClipView.layer?.masksToBounds = true
        pinClipView.addSubview(canvas); workspace.addSubview(pinClipView, positioned: .below, relativeTo: toolbar)
        canvas.alphaValue = min(1, max(0.05, placement.opacity))
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancelEditor() }
            }
        }
        layoutInterface(); panel.makeFirstResponder(canvas); showWindow(nil); panel.makeKeyAndOrderFront(nil)
        return true
    }

    private func iconButton(_ symbol: String, title: String, id: String, action: Selector) -> NSButton {
        let control = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: EditorFloatingSurface.symbolPointSize, weight: .medium)) ?? NSImage(), target: self, action: action)
        control.isBordered = false; control.bezelStyle = .regularSquare; control.imagePosition = .imageOnly
        control.contentTintColor = EditorFloatingSurface.ink; control.imageScaling = .scaleProportionallyDown; control.toolTip = title; control.setAccessibilityLabel(title)
        control.identifier = NSUserInterfaceItemIdentifier(id)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([control.widthAnchor.constraint(equalToConstant: 32), control.heightAnchor.constraint(equalToConstant: 32)])
        control.wantsLayer = true; control.layer?.cornerRadius = 4
        return control
    }
    private func addSubtoolMenu(for family: ImageEditorTool, tools: [ImageEditorTool], identifier: String) {
        let menu = NSPopUpButton(); menu.pullsDown = true; menu.isBordered = false
        menu.addItem(withTitle: "")
        menu.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "选择\(family.title)子工具")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        (menu.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        menu.imagePosition = .imageOnly; menu.contentTintColor = EditorFloatingSurface.ink
        menu.identifier = NSUserInterfaceItemIdentifier(identifier)
        menu.setAccessibilityLabel("选择\(family.title)子工具"); menu.toolTip = tools.map(\.title).joined(separator: " / ")
        for tool in tools {
            let item = NSMenuItem(title: tool.title, action: #selector(selectMenuTool(_:)), keyEquivalent: "")
            item.target = self; item.tag = ImageEditorTool.allCases.firstIndex(of: tool) ?? 0
            item.identifier = NSUserInterfaceItemIdentifier("editor.subtool.\(tool.rawValue)")
            item.image = AnnotationPathIcons.image(for: tool)
            menu.menu?.addItem(item)
        }
        menu.translatesAutoresizingMaskIntoConstraints = false
        menu.widthAnchor.constraint(equalToConstant: 14).isActive = true
        menu.heightAnchor.constraint(equalToConstant: 32).isActive = true
        subtoolMenus[family] = menu; toolbar.addArrangedSubview(menu)
    }

    private func refreshSubtoolButton(for tool: ImageEditorTool) {
        let family: ImageEditorTool
        let symbol: String
        if [.ellipse, .arc, .sector].contains(tool) { family = .ellipse; symbol = "circle" }
        else if [.line, .polyline].contains(tool) { family = .line; symbol = "line.diagonal" }
        else { return }
        guard let button = toolButtons[family] else { return }
        button.tag = ImageEditorTool.allCases.firstIndex(of: tool) ?? 0
        let fallback = NSImage(systemSymbolName: symbol, accessibilityDescription: tool.title)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: EditorFloatingSurface.symbolPointSize, weight: .medium))
        button.image = AnnotationPathIcons.image(for: tool) ?? fallback
        button.toolTip = tool.title; button.setAccessibilityLabel(tool.title)
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
        toolbar.orientation = .horizontal; toolbar.detachesHiddenViews = true; toolbar.spacing = 2; toolbar.alignment = .centerY
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7)
        toolbar.identifier = NSUserInterfaceItemIdentifier("editor.floatingToolbar")
        styleFloatingSurface(toolbar)
        let tools: [(ImageEditorTool, String)] = [(.rectangle, "rectangle"), (.ellipse, "circle"), (.freehand, "pencil"),
            (.arrow, "arrow.up.right"), (.text, "textformat"), (.number, "1.circle"), (.pixelate, "square.grid.2x2.fill"),
            (.redact, "rectangle.fill"), (.eraser, "eraser"), (.spotlight, "light.beacon.max"), (.line, "line.diagonal"), (.highlighter, "highlighter"), (.select, "cursorarrow"), (.crop, "crop")]
        for (tool, symbol) in tools {
            let control = iconButton(symbol, title: tool.title, id: "editor.tool.\(tool.rawValue)", action: #selector(selectTool(_:)))
            control.tag = ImageEditorTool.allCases.firstIndex(of: tool) ?? 0
            control.setButtonType(.toggle)
            toolButtons[tool] = control; toolbar.addArrangedSubview(control)
            if tool == .ellipse { addSubtoolMenu(for: tool, tools: [.ellipse, .arc, .sector], identifier: "editor.shapeSubtools") }
            if tool == .line { addSubtoolMenu(for: tool, tools: [.line, .polyline], identifier: "editor.lineSubtools") }
            if tool == .pixelate {
                addSubtoolMenu(for: tool, tools: [.pixelate, .blur, .redact], identifier: "editor.mosaicSubtools")
                let item = NSMenuItem(title: "自动马赛克…", action: #selector(chooseAutomaticMosaicTool), keyEquivalent: "")
                item.target = self; item.identifier = .init("editor.automaticMosaic")
                subtoolMenus[tool]?.menu?.addItem(item)
            }
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
        saveActions.pullsDown = true; saveActions.isBordered = false; saveActions.addItem(withTitle: "")
        saveActions.item(at: 0)?.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "保存选项")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        (saveActions.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        saveActions.imagePosition = .imageOnly; saveActions.contentTintColor = EditorFloatingSurface.ink
        saveActions.identifier = .init("editor.saveActions"); saveActions.setAccessibilityLabel("保存选项")
        for (title, action) in [("快速保存 PNG", #selector(quickSaveResult)), ("保存 PNG 并复制", #selector(saveCopyResult)), ("保存与命名设置…", #selector(openSaveSettings))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            item.isEnabled = saveWorkflow != nil; saveActions.menu?.addItem(item)
        }
        saveActions.menu?.autoenablesItems = false; saveActions.translatesAutoresizingMaskIntoConstraints = false
        // Width is the actual clickable frame, not an ornament alignment rect.
        saveActions.widthAnchor.constraint(equalToConstant: 19).isActive = true
        saveActions.heightAnchor.constraint(equalToConstant: 32).isActive = true; toolbar.addArrangedSubview(saveActions)
        canvas.menu = saveWorkflow != nil ? saveActions.menu?.copy() as? NSMenu : NSMenu()
        let autoMosaic = NSMenuItem(title: "查找相同内容…", action: #selector(startAutomaticMosaic), keyEquivalent: "")
        autoMosaic.target = self; autoMosaic.identifier = .init("editor.context.automaticMosaic")
        canvas.menu?.addItem(autoMosaic)

        toolbar.addArrangedSubview(iconButton("xmark", title: "取消 · Escape", id: "editor.cancel", action: #selector(cancelEditor)))
        toolbar.addArrangedSubview(iconButton("square.on.square", title: "复制图片 · ⌘C", id: "editor.copy", action: #selector(copyResult)))
        overflow.pullsDown = true; overflow.isBordered = false; overflow.addItem(withTitle: "")
        overflow.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作")
        overflow.imagePosition = .imageOnly; overflow.setAccessibilityLabel("更多操作")
        overflow.identifier = NSUserInterfaceItemIdentifier("editor.more")
        for tool in [ImageEditorTool.select, .ellipse, .arc, .sector, .line, .polyline, .highlighter, .crop, .eraser, .spotlight, .watermark, .magnifier] {
            let item = NSMenuItem(title: tool.title, action: #selector(selectMenuTool(_:)), keyEquivalent: "")
            item.target = self; item.tag = ImageEditorTool.allCases.firstIndex(of: tool) ?? 0; overflow.menu?.addItem(item)
        }
        overflow.menu?.addItem(.separator())
        addMenu("自动马赛克…", action: #selector(chooseAutomaticMosaicTool))
        addMenu("查找所选区域的相同内容…", action: #selector(startAutomaticMosaic))
        addMenu("模糊", action: #selector(selectBlur)); addMenu("创建标注副本 · ⌘D", action: #selector(duplicateAnnotation))
        addMenu("删除标注 · Delete", action: #selector(deleteAnnotation)); overflow.menu?.addItem(.separator())
        addMenu(onApply == nil ? "保存到历史" : "保存编辑", action: #selector(saveResult))
        if saveWorkflow != nil {
            addMenu("快速保存 PNG", action: #selector(quickSaveResult)); addMenu("保存 PNG 并复制", action: #selector(saveCopyResult))
            addMenu("保存与命名设置…", action: #selector(openSaveSettings))
        }
        addMenu("适合窗口", action: #selector(fitImage)); addMenu("100% 像素", action: #selector(actualSize))
        overflow.translatesAutoresizingMaskIntoConstraints = false; overflow.widthAnchor.constraint(equalToConstant: 32).isActive = true
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
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = .white; status.alignment = .center; status.wantsLayer = true
        status.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        status.layer?.cornerRadius = 4; status.identifier = NSUserInterfaceItemIdentifier("editor.dimensions")
        workspace.addSubview(status)
        window.makeFirstResponder(canvas)
    }
    private func addMenu(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; overflow.menu?.addItem(item)
    }
    private func styleFloatingSurface(_ view: NSView) {
        view.appearance = nil
        (view as? EditorFloatingSurface)?.refreshSurface()
    }
    private func layoutInterface() {
        guard !layingOut, workspace.bounds.width > 0 else { return }
        layingOut = true; defer { layingOut = false }
        let selection: CGRect
        if let pin = pinPresentation {
            selection = pin.viewportFrame
        } else if let presentation {
            selection = boundaryPreviewFrame ?? presentation.selectionFrame
            if boundaryPreviewFrame == nil {
                canvas.verticalZoom = selection.height / CGFloat(canvas.image.height)
                canvas.zoom = selection.width / CGFloat(canvas.image.width)
                canvas.frame = selection
            }
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
        if pinPresentation == nil { workspace.selectionFrame = selection }
        if let presentation, boundaryPreviewFrame != nil {
            workspace.pixelSize = CGSize(width: (selection.width * CGFloat(presentation.frozenImage.width) / presentation.displayFrame.width).rounded(),
                                         height: (selection.height * CGFloat(presentation.frozenImage.height) / presentation.displayFrame.height).rounded())
        } else { workspace.pixelSize = CGSize(width: canvas.image.width, height: canvas.image.height) }
        inspector.isHidden = automaticMosaicReviewState != nil || canvas.automaticMosaicDrawHandler != nil
            || canvas.tool == .crop || (canvas.tool == .select && canvas.selectedAnnotation == nil)
        let availableBounds = pinPresentation.flatMap { pin in NSScreen.screens.first { $0.frame.intersects(pin.viewportFrame) }?.frame } ?? workspace.bounds
        for button in toolButtons.values { button.isHidden = false }
        for menu in subtoolMenus.values { menu.isHidden = false }
        var preferredWidth = max(40, toolbar.fittingSize.width)
        for tool in [ImageEditorTool.ellipse, .line, .highlighter, .select, .crop, .spotlight, .eraser] where preferredWidth > availableBounds.width - 20 {
            if let button = toolButtons[tool] {
                button.isHidden = true; preferredWidth -= 34
                if let menu = subtoolMenus[tool] { menu.isHidden = true; preferredWidth -= 16 }
            }
        }
        toolbar.setFrameSize(CGSize(width: preferredWidth, height: 40))
        toolbar.layoutSubtreeIfNeeded(); inspector.layoutSubtreeIfNeeded()
        let activeFamily: ImageEditorTool = canvas.tool.isArcTool ? .ellipse : (canvas.tool == .polyline ? .line : canvas.tool)
        let active = toolButtons[activeFamily].map { toolbar.convert($0.bounds, from: $0).midX } ?? 18
        let frames = EditorFloatingLayout.frames(selection: selection, available: availableBounds,
            toolbarSize: CGSize(width: preferredWidth, height: 40),
            paletteSize: inspector.isHidden ? .zero : CGSize(width: inspector.fittingSize.width, height: max(38, inspector.fittingSize.height)), activeToolOffset: active)
        if let pin = pinPresentation, let window {
            var union = selection.union(frames.toolbar)
            if !inspector.isHidden { union = union.union(frames.palette) }
            let showsMosaic = automaticMosaicReviewState != nil || canvas.automaticMosaicDrawHandler != nil
            let focusedMosaic = automaticMosaicReviewState.flatMap { state -> CGRect? in
                guard state.candidates.indices.contains(state.selectedIndex) else { return nil }
                let rect = state.candidates[state.selectedIndex].rect
                return CGRect(x: pin.imageFrame.minX + rect.minX * pin.imageFrame.width / CGFloat(canvas.image.width),
                    y: pin.imageFrame.minY + rect.minY * pin.imageFrame.height / CGFloat(canvas.image.height),
                    width: rect.width * pin.imageFrame.width / CGFloat(canvas.image.width), height: rect.height * pin.imageFrame.height / CGFloat(canvas.image.height))
            }
            let mosaicFrame = AutomaticMosaicReviewSurface.frame(image: selection, available: availableBounds,
                avoiding: [frames.toolbar] + (inspector.isHidden ? [] : [frames.palette]), focusedCandidate: focusedMosaic)
            if showsMosaic { union = union.union(mosaicFrame) }
            let windowFrame = CGRect(x: union.minX - 2, y: union.minY - 2, width: union.width + 4, height: union.height + 28)
            if window.frame != windowFrame { window.setFrame(windowFrame, display: false) }
            // AppKit may snap a window origin to backing pixels. Derive local
            // placement from the actual frame so the pin image itself never moves.
            let dx = -window.frame.minX, dy = -window.frame.minY
            workspace.selectionFrame = pin.viewportFrame.offsetBy(dx: dx, dy: dy)
            pinClipView.frame = workspace.selectionFrame
            canvas.verticalZoom = pin.imageFrame.height / CGFloat(canvas.image.height)
            canvas.zoom = pin.imageFrame.width / CGFloat(canvas.image.width)
            canvas.frame = CGRect(x: pin.imageFrame.minX - pin.viewportFrame.minX, y: pin.imageFrame.minY - pin.viewportFrame.minY,
                                  width: pin.imageFrame.width, height: pin.imageFrame.height)
            toolbar.frame = frames.toolbar.offsetBy(dx: dx, dy: dy); inspector.frame = frames.palette.offsetBy(dx: dx, dy: dy)
            if showsMosaic { automaticMosaicReviewSurface.frame = mosaicFrame.offsetBy(dx: dx, dy: dy); automaticMosaicReviewSurface.layoutSubtreeIfNeeded() }
        } else {
            toolbar.frame = frames.toolbar; inspector.frame = frames.palette
        }
        if frames.palette.height == 0 { inspector.isHidden = true }
        status.stringValue = "\(Int(workspace.pixelSize.width)) × \(Int(workspace.pixelSize.height)) px"
        if (canvas.pendingFreehand ?? canvas.selectedAnnotation)?.freehandWasSimplified == true {
            status.stringValue += " · 长笔迹已简化（最多 2048 点）"
        }
        let labelSize = CGSize(width: (status.stringValue as NSString).size(withAttributes: [.font: status.font!]).width + 14, height: 23)
        let occupied = inspector.isHidden ? [toolbar.frame] : [toolbar.frame, inspector.frame]
        status.frame = EditorFloatingLayout.dimensionLabelFrame(selection: workspace.selectionFrame, available: workspace.bounds, size: labelSize, avoiding: occupied)
        if pinPresentation == nil { layoutAutomaticMosaicReview() }
    }

    func setVerificationAnnotations(_ annotations: [ImageAnnotation]) {
        recordChange(); canvas.setContent(image: canvas.image, annotations: annotations); canvas.displayIfNeeded()
    }
    private var snapshot: Snapshot { Snapshot(image: canvas.image, annotations: canvas.annotations, selectionFrame: presentation?.selectionFrame, pinPresentation: pinPresentation, numberSequence: canvas.numberSequence) }
    private func recordChange() { undoStates.append(snapshot); redoStates.removeAll(); trimHistory(preferUndo: true); updateStatus() }
    private func trimHistory(preferUndo: Bool) {
        let first = preferUndo ? redoStates : undoStates, second = preferUndo ? undoStates : redoStates
        let count = ImageEditorHistoryBudget.retainedSuffixStart(images: (first + second).map(\.image))
        let firstCount = min(count, first.count), secondCount = count - firstCount
        if preferUndo { redoStates.removeFirst(firstCount); undoStates.removeFirst(secondCount) }
        else { undoStates.removeFirst(firstCount); redoStates.removeFirst(secondCount) }
    }
    private func restore(_ state: Snapshot) {
        if pinPresentation != nil { pinPresentation = state.pinPresentation }
        if let old = presentation, let frame = state.selectionFrame {
            presentation = FrozenCapturePresentation(frozenImage: old.frozenImage, displayID: old.displayID, displayFrame: old.displayFrame, selectionFrame: frame, capturedAt: old.capturedAt)
        }
        canvas.setContent(image: state.image, annotations: state.annotations, numberSequence: state.numberSequence); updateStatus(); layoutInterface()
    }
    private func updateStatus() {
        let outputIDs: Set<String> = ["editor.copy", "editor.save", "editor.pin", "editor.applyToPin", "editor.ocr", "editor.translate", "editor.saveActions"]
        for view in toolbar.views + toolbar.detachedViews where outputIDs.contains(view.identifier?.rawValue ?? "") {
            (view as? NSControl)?.isEnabled = !automaticMosaicBlocksOutput
        }
        for menu in [canvas.menu, overflow.menu].compactMap({ $0 }) {
            for item in menu.items {
                if item.action == #selector(startAutomaticMosaic) {
                    item.isEnabled = canvas.selectedAnnotation?.supportsAutomaticMosaic == true && !isClosed
                    item.toolTip = canvas.selectedAnnotation?.mosaicLink == nil ? "选择同尺寸、未旋转的马赛克、模糊或遮盖区域" : "已关联的结果可用同步/补充区域编辑；重新查找请新建选区"
                }
                if automaticMosaicOutputAction(item.action) { item.isEnabled = !automaticMosaicBlocksOutput && !isClosed }
            }
        }
        status.stringValue = "\(canvas.image.width) × \(canvas.image.height) px · \(canvas.annotations.count) 个标注"
        undoButton?.isEnabled = !undoStates.isEmpty || canvas.pendingPolylinePointCount > 0; redoButton?.isEnabled = !redoStates.isEmpty && canvas.pendingPolylinePointCount == 0
        cropButton?.isHidden = canvas.tool != .crop
        cropButton?.isEnabled = (canvas.cropRect?.width ?? 0) >= 1 && (canvas.cropRect?.height ?? 0) >= 1
        for (tool, button) in toolButtons {
            let active = canvas.tool == tool || (tool == .ellipse && canvas.tool.isArcTool) || (tool == .line && canvas.tool == .polyline)
            button.state = active ? .on : .off
            button.contentTintColor = active ? .systemBlue : EditorFloatingSurface.ink
            button.layer?.backgroundColor = active ? NSColor.systemBlue.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
        }
        let usesCurrentMark = canvas.tool == .select || ([ImageEditorTool.watermark, .magnifier, .spotlight, .arc, .sector, .polyline, .arrow, .line, .text, .number].contains(canvas.tool)
            && canvas.selectedAnnotation?.tool == canvas.tool)
        let selected = usesCurrentMark && canvas.pendingPolylinePointCount == 0 ? canvas.selectedAnnotation : nil
        var inspected = inlineAnnotation ?? canvas.pendingPolyline ?? selected ?? canvas.style
        if inlineAnnotation == nil { inspected.tool = selected?.tool ?? canvas.tool }
        let enabled = canvas.tool != .crop && (canvas.tool != .select || selected != nil)
        inspector.isHidden = !enabled
        inspector.polylinePointCount = canvas.pendingPolylinePointCount
        inspector.numberSequence = canvas.numberSequence
        inspector.numberCount = canvas.annotations.lazy.filter { $0.tool == .number }.count
        inspector.display(annotation: inspected, selected: selected != nil, enabled: enabled)
        layoutInterface()
    }
    func chooseTool(_ tool: ImageEditorTool) {
        cancelAutomaticMosaic()
        finishInlineText(commit: true); canvas.tool = tool; refreshSubtoolButton(for: tool); updateStatus(); window?.makeFirstResponder(canvas)
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
        cancelAutomaticMosaic()
        canvas.finishNumberComment(commit: true)
        if canvas.pendingPolylinePointCount > 0 { canvas.removeLastPolylineVertex(); return }
        finishInlineText(commit: true)
        guard let state = undoStates.popLast() else { return }
        redoStates.append(snapshot); trimHistory(preferUndo: false); restore(state)
    }
    @objc private func redoEdit() {
        cancelAutomaticMosaic()
        canvas.finishNumberComment(commit: false)
        guard canvas.pendingPolylinePointCount == 0 else { return }
        finishInlineText(commit: false)
        guard let state = redoStates.popLast() else { return }
        undoStates.append(snapshot); trimHistory(preferUndo: true); restore(state)
    }
    @objc private func applyCrop() {
        canvas.finishNumberComment(commit: true)
        finishInlineText(commit: true)
        guard let rect = canvas.cropRect, let flattened = canvas.flattened(), let cropped = ImageEditorRenderer.crop(image: flattened, to: rect) else { return }
        recordChange()
        if let old = presentation {
            let scaleX = old.selectionFrame.width / CGFloat(canvas.image.width), scaleY = old.selectionFrame.height / CGFloat(canvas.image.height)
            let clipped = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: canvas.image.width, height: canvas.image.height))
            presentation = FrozenCapturePresentation(frozenImage: old.frozenImage, displayID: old.displayID, displayFrame: old.displayFrame,
                selectionFrame: CGRect(x: old.selectionFrame.minX + clipped.minX * scaleX, y: old.selectionFrame.minY + clipped.minY * scaleY, width: clipped.width * scaleX, height: clipped.height * scaleY), capturedAt: old.capturedAt)
        }
        if let pin = pinPresentation {
            let clipped = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: canvas.image.width, height: canvas.image.height))
            let scaleX = pin.imageFrame.width / CGFloat(canvas.image.width), scaleY = pin.imageFrame.height / CGFloat(canvas.image.height)
            let frame = CGRect(x: pin.imageFrame.minX + clipped.minX * scaleX, y: pin.imageFrame.minY + clipped.minY * scaleY,
                               width: clipped.width * scaleX, height: clipped.height * scaleY)
            pinPresentation = PinEditorPresentation(viewportFrame: pin.viewportFrame, imageFrame: frame, opacity: pin.opacity, level: pin.level)
        }
        canvas.setContent(image: cropped, annotations: []); fitImage()
    }
    @objc private func fitImage() { canvas.finishNumberComment(commit: true); finishInlineText(commit: true); fitToWindow = true; needsFit = true; layoutInterface() }
    @objc private func actualSize() { guard presentation == nil else { return }; canvas.finishNumberComment(commit: true); finishInlineText(commit: true); fitToWindow = false; canvas.zoom = 1; layoutInterface() }
    private func result(close: Bool = false, _ action: (CGImage) -> Void) {
        guard !automaticMosaicBlocksOutput else { return }
        canvas.finishNumberComment(commit: true)
        finishInlineText(commit: true); canvas.finishPolyline()
        guard let image = canvas.flattened() else { showError(PicShotError.message("无法合成图片，可能内存不足")); return }
        if close { window?.close() }; action(image)
    }
    @objc private func copyResult() {
        let workflow = saveWorkflow, copy = copyAction
        result(close: presentation != nil) { image in
            copy(image) // Immediate copy never waits for automatic save admission.
            workflow?.save(image: image, automatic: true)
        }
    }
    @objc private func saveResult() {
        let workflow = saveWorkflow, action = onSave
        result { image in action(image); workflow?.save(image: image, automatic: true) }
    }
    @objc private func pinResult() {
        let workflow = saveWorkflow, action = onPin
        result(close: presentation != nil) { image in action(image); workflow?.save(image: image, automatic: true) }
    }
    @objc private func quickSaveResult() { saveUsingWorkflow(copy: false) }
    @objc private func saveCopyResult() { saveUsingWorkflow(copy: true) }
    @objc private func openSaveSettings() { saveWorkflow?.onSettings?(window) }
    private func saveUsingWorkflow(copy: Bool) {
        guard let saveWorkflow else { return }
        result { [weak self] image in
            saveWorkflow.save(image: image, copy: copy, from: self?.window) { [weak self] saved in
                guard saved.clipboardOutcome != .failed, saved.clipboardOutcome != .cancelledAfterSave else { return }
                if self?.presentation != nil { self?.window?.close() }
            }
        }
    }
    @objc private func recognizeResult() { result(close: presentation != nil, onOCR) }
    @objc private func translateResult() { if let onTranslate { result(close: presentation != nil, onTranslate) } }
    @objc private func applyResult() {
        guard let onApply else { return }
        result { image in if onApply(image) { window?.close() } }
    }
    @objc private func cancelEditor() { finishInlineText(commit: false); window?.close() }

    private func beginBoundaryResize() {
        cancelAutomaticMosaic()
        canvas.finishNumberComment(commit: true)
        finishInlineText(commit: true); canvas.finishPolyline()
        guard let presentation, let preview = canvas.rasterForBoundaryPreview() else {
            workspace.cancelBoundaryResize(); return
        }
        boundaryPreviewFrame = presentation.selectionFrame
        workspace.boundaryPreviewOriginalFrame = presentation.selectionFrame
        workspace.boundaryPreviewImage = preview
        canvas.isHidden = true; workspace.needsDisplay = true
    }
    private func previewBoundaryResize(_ requested: CGRect) {
        guard let presentation, boundaryPreviewFrame != nil,
              let aligned = try? EditorBoundaryRenderer.alignedFrame(requested, presentation: presentation) else { return }
        boundaryPreviewFrame = aligned; layoutInterface(); workspace.needsDisplay = true
    }
    private func finishBoundaryResize(commit: Bool) {
        let requested = boundaryPreviewFrame
        boundaryPreviewFrame = nil; workspace.boundaryPreviewImage = nil
        canvas.isHidden = false
        guard commit, let requested, let previous = presentation, requested != previous.selectionFrame else {
            layoutInterface(); window?.makeFirstResponder(canvas); return
        }
        // Drop the redraw cache before allocating the new selected raster. Drag
        // motion made no raster copies and did not touch the annotation/history model.
        canvas.releasePresentationCache()
        do {
            let next = try EditorBoundaryRenderer.recrop(requested, presentation: previous, previousImage: canvas.image)
            guard let nextPresentation = next.presentation else { return }
            let offset = EditorBoundaryRenderer.annotationOffset(from: previous.selectionFrame, to: nextPresentation.selectionFrame, presentation: previous)
            let translated = canvas.annotations.map { $0.translated(by: offset) }
            recordChange()
            presentation = nextPresentation
            canvas.setContent(image: next.image, annotations: translated)
        } catch { showError(error) }
        layoutInterface(); workspace.needsDisplay = true; window?.makeFirstResponder(canvas)
    }

    func beginInlineText(at point: CGPoint, editing id: UUID?) {
        canvas.finishNumberComment(commit: true)
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
        updateStatus()
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
        if !isClosed { updateStatus() }
    }
    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }; isClosed = true
        cancelAutomaticMosaic(); automaticMosaicFind = nil
        automaticMosaicReviewSurface.removeFromSuperview()
        canvas.onContentInvalidated = nil; canvas.onAutomaticMosaicToggle = nil
        canvas.onAutomaticMosaicCancel = nil; canvas.onAutomaticMosaicApply = nil; canvas.onAutomaticMosaicLimit = nil
        inspector.onAutomaticMosaic = nil; inspector.onMosaicSync = nil; inspector.onMosaicAdd = nil
        workspace.cancelBoundaryResize()
        canvas.finishNumberComment(commit: false)
        finishInlineText(commit: false)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        workspace.frozenImage = nil; presentation = nil; pinPresentation = nil
        undoStates.removeAll(); redoStates.removeAll()
        canvas.onWillChange = nil; canvas.onChange = nil; canvas.onRequestText = nil
        canvas.onUndo = nil; canvas.onRedo = nil; canvas.onApplyCrop = nil
        canvas.onCopy = nil; canvas.onExport = nil; canvas.onCancel = nil; canvas.onBeforeInteraction = nil
        inspector.onEdit = nil; inspector.onClearAnnotations = nil; inspector.onFinishPolyline = nil; inspector.onCancelPolyline = nil
        inspector.numberControls.clearCallbacks()
        canvas.cancelPolyline(); canvas.cancelPendingFreehand(); canvas.releasePresentationCache(); inspector.deactivateColorWells()
        workspace.onLayout = nil; workspace.onDismiss = nil; workspace.onOutsideClick = nil
        workspace.onBoundaryBegin = nil; workspace.onBoundaryChange = nil; workspace.onBoundaryEnd = nil
        workspace.boundaryPreviewImage = nil; workspace.selectionContent = nil
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        window?.contentView = nil; window?.delegate = nil
        let completion = onClose; onClose = nil; completion?()
    }
    func windowDidResize(_ notification: Notification) { guard !layingOut else { return }; canvas.finishNumberComment(commit: true); finishInlineText(commit: true); layoutInterface() }

    @objc private func exportResult() {
        guard !automaticMosaicBlocksOutput else { return }
        canvas.finishNumberComment(commit: true)
        finishInlineText(commit: true); canvas.finishPolyline()
        guard let window, let image = canvas.flattened() else { return }
        ImageExportController.present(image: image, from: window, saveWorkflow: saveWorkflow) { [weak self] _ in
            if self?.presentation != nil { self?.window?.close() }
        }
    }

    /// Compatibility API for existing callers/tests. The UI uses the bounded
    /// asynchronous controller; this synchronous seam still verifies every
    /// output and publishes exclusively without changing an existing file.
    static func writeFlattened(_ image: CGImage, to url: URL, format: Int) throws {
        guard let format = ImageExportFormat(rawValue: format) else { throw ImageExportError.invalidOptions }
        let snapshot = try ImageExportSnapshot(image: image)
        let artifact = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: format))
        try ImageExportService.publish(artifact, to: url)
    }
}
