import AppKit
import CoreText

/// Erasers remain vector operations in the document. They affect preceding marks only,
/// and never punch holes in the captured raster or retain raster history per gesture.
enum AnnotationEraserMode: String, CaseIterable {
    case brush, rectangle
    var title: String { self == .brush ? "画笔" : "框选" }
}
enum AnnotationRegionShape: String, CaseIterable {
    case rectangle, ellipse
    var title: String { self == .rectangle ? "矩形" : "椭圆" }
    func path(in rect: CGRect) -> CGPath {
        self == .ellipse ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
    }
}
enum AnnotationWatermarkPlacement: String, CaseIterable {
    case tiled, bottomRight, bottomLeft, topRight, topLeft, topCenter, bottomCenter, center
    var title: String {
        switch self {
        case .tiled: return "平铺"
        case .bottomRight: return "右下"
        case .bottomLeft: return "左下"
        case .topRight: return "右上"
        case .topLeft: return "左上"
        case .topCenter: return "上中"
        case .bottomCenter: return "下中"
        case .center: return "居中"
        }
    }
}
enum AnnotationMagnifierConnector: String, CaseIterable {
    case line, dotted, edges, none
    var title: String {
        switch self { case .line: return "线段"; case .dotted: return "点线"; case .edges: return "边框连线"; case .none: return "无连线" }
    }
}

extension ImageAnnotation {
    static let maximumGesturePoints = 2_048
    var magnifierSourceRect: CGRect { magnifierSource ?? localBounds }
    var effectiveMagnifierScale: CGFloat { magnifierScale.isFinite ? min(8, max(1, magnifierScale)) : 2 }

    /// Each capsule is clipped separately, so brush crossings and repeated visits form
    /// a union rather than the accidental holes produced by one even-odd compound path.
    func forEachEraserPath(_ body: (CGPath) -> Void) {
        guard tool == .eraser else { return }
        var transform = self.transform
        if eraserMode == .rectangle {
            if let path = CGPath(rect: localBounds, transform: nil).copy(using: &transform) { body(path) }
            return
        }
        let radius = max(1, lineWidth) / 2
        guard let first = points.first else { return }
        func emit(_ a: CGPoint, _ b: CGPoint) {
            let path: CGPath
            if hypot(b.x - a.x, b.y - a.y) < 0.001 {
                path = CGPath(ellipseIn: CGRect(x: a.x - radius, y: a.y - radius, width: radius * 2, height: radius * 2), transform: nil)
            } else {
                let center = CGMutablePath(); center.move(to: a); center.addLine(to: b)
                path = center.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            }
            if let transformed = path.copy(using: &transform) { body(transformed) }
        }
        if points.count < 2 { emit(first, first) }
        else { for index in 1..<points.count { emit(points[index - 1], points[index]) } }
    }

    /// Normalization uses the stroke's nonzero fill rule to merge self-crossings.
    /// One merged vector clip per eraser avoids points × underlying-marks clips.
    /// CGPath.normalized is available on the app's macOS 14 deployment target.
    var mergedEraserPath: CGPath {
        guard tool == .eraser else { return CGMutablePath() }
        var transform = self.transform
        let path: CGPath
        if eraserMode == .rectangle { path = CGPath(rect: localBounds, transform: nil) }
        else if let first = points.first {
            if points.allSatisfy({ hypot($0.x - first.x, $0.y - first.y) < 0.001 }) {
                let radius = max(1, lineWidth) / 2
                path = CGPath(ellipseIn: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2), transform: nil)
            } else {
                path = strokePath.copy(strokingWithWidth: max(1, lineWidth), lineCap: .round, lineJoin: .round, miterLimit: 10).normalized(using: .winding)
            }
        } else { return CGMutablePath() }
        return path.copy(using: &transform) ?? path
    }

    func erases(_ point: CGPoint) -> Bool { mergedEraserPath.contains(point) }

}

enum AnnotationWatermarkLayout {
    static let maximumTiles = 4_096
    static let maximumTemplateCharacters = 512

    /// The date/timezone are frozen with the capture, not read while drawing or exporting.
    static func resolvedText(_ annotation: ImageAnnotation) -> String {
        let template = String(annotation.watermarkTemplate.prefix(maximumTemplateCharacters))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: annotation.frozenTimeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)
        return resolveTokens(template, formatter: formatter, date: annotation.frozenTimestamp)
    }

    private static func resolveTokens(_ template: String, formatter: DateFormatter, date: Date) -> String {
        var output = "", remaining = template[...]
        let allowed = CharacterSet(charactersIn: "yMdHhmsSaEzZX/:.,_- ")
        while let open = remaining.firstIndex(of: "$") {
            output += remaining[..<open]
            let tail = remaining.index(after: open)
            guard let close = remaining[tail...].firstIndex(of: "$") else { output += remaining[open...]; return output }
            let token = String(remaining[tail..<close])
            if !token.isEmpty && token.count <= 64 && token.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                formatter.dateFormat = token; output += formatter.string(from: date)
            } else { output += remaining[open...close] }
            remaining = remaining[remaining.index(after: close)...]
        }
        output += remaining
        return output
    }

    static func textAnnotation(_ annotation: ImageAnnotation) -> ImageAnnotation {
        var text = annotation; text.tool = .text; text.text = resolvedText(annotation)
        text.points = [.zero]; text.textBoxSize = nil; text.rotation = 0; text.fillEnabled = false
        return text
    }

    static func tileRects(for annotation: ImageAnnotation) -> [CGRect] {
        let area = annotation.localBounds.standardized
        guard area.width.isFinite, area.height.isFinite, area.width > 0, area.height > 0 else { return [] }
        let size = AnnotationTextLayout.size(for: textAnnotation(annotation))
        let margin = min(12, min(area.width, area.height) / 4)
        if annotation.watermarkPlacement != .tiled {
            let x: CGFloat, y: CGFloat
            switch annotation.watermarkPlacement {
            case .topLeft, .bottomLeft: x = area.minX + margin
            case .topRight, .bottomRight: x = area.maxX - margin - size.width
            default: x = area.midX - size.width / 2
            }
            switch annotation.watermarkPlacement {
            case .topLeft, .topRight, .topCenter: y = area.maxY - margin - size.height
            case .bottomLeft, .bottomRight, .bottomCenter: y = area.minY + margin
            default: y = area.midY - size.height / 2
            }
            return [CGRect(x: x, y: y, width: size.width, height: size.height)]
        }
        let spacing = annotation.watermarkSpacing.isFinite ? min(1_000, max(0, annotation.watermarkSpacing)) : 48
        var stepX = max(8, size.width + spacing), stepY = max(8, size.height + spacing)
        // Cap work on giant captures without truncating watermark coverage to one corner.
        var count = ceil(area.width / stepX) * ceil(area.height / stepY)
        while count > CGFloat(maximumTiles) {
            let columns = ceil(area.width / stepX), rows = ceil(area.height / stepY)
            // A single row/column needs a linear adjustment; a square-root-only
            // adjustment would truncate coverage on very tall scrolling captures.
            let ratio = count / CGFloat(maximumTiles)
            let factor = (columns <= 1 || rows <= 1 ? ratio : sqrt(ratio)) * 1.02
            stepX *= factor; stepY *= factor
            count = ceil(area.width / stepX) * ceil(area.height / stepY)
        }
        var result: [CGRect] = []
        var y = area.minY
        while y < area.maxY && result.count < maximumTiles {
            var x = area.minX
            while x < area.maxX && result.count < maximumTiles {
                result.append(CGRect(origin: CGPoint(x: x, y: y), size: size)); x += stepX
            }
            y += stepY
        }
        return result
    }

    static func draw(_ annotation: ImageAnnotation, in context: CGContext) {
        context.saveGState(); context.clip(to: annotation.localBounds)
        var text = textAnnotation(annotation)
        for rect in tileRects(for: annotation) {
            text.points = [rect.origin]; text.textBoxSize = rect.size
            AnnotationTextLayout.draw(text, context: context)
        }
        context.restoreGState()
    }
}

/// No retained raster cache: lenses sample one temporary composite snapshot at a time.
enum AnnotationMagnifierRenderer {
    static func draw(_ annotation: ImageAnnotation, snapshot: CGImage, extent: CGRect, privacyMarks: [ImageAnnotation] = [],
                     in context: CGContext,
                     effectPatchRenderer: ImageEditorRenderer.EffectPatchRenderer = ImageEditorRenderer.renderEffectPatch) -> Bool {
        let lens = annotation.localBounds.standardized, source = annotation.magnifierSourceRect.standardized
        guard source.width > 0, source.height > 0, lens.width > 0, lens.height > 0 else { return true }
        let sourcePath = annotation.magnifierShape.path(in: source)
        let lensPath = annotation.magnifierShape.path(in: lens)
        let sourceCenter = CGPoint(x: source.midX, y: source.midY), lensCenter = CGPoint(x: lens.midX, y: lens.midY)
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(annotation.magnifierSmooth)
        context.setLineDash(phase: 0, lengths: [])
        if annotation.magnifierConnector != .none && !lens.intersects(source) {
            let dx = lensCenter.x - sourceCenter.x, dy = lensCenter.y - sourceCenter.y
            func edge(_ rect: CGRect, from center: CGPoint, dx: CGFloat, dy: CGFloat) -> CGPoint {
                let scale: CGFloat
                if annotation.magnifierShape == .ellipse {
                    let norm = sqrt(pow(dx / max(1, rect.width / 2), 2) + pow(dy / max(1, rect.height / 2), 2))
                    scale = norm > 0.001 ? 1 / norm : 0
                } else {
                    scale = min(abs(dx) < 0.001 ? CGFloat.greatestFiniteMagnitude : rect.width / 2 / abs(dx),
                                abs(dy) < 0.001 ? CGFloat.greatestFiniteMagnitude : rect.height / 2 / abs(dy))
                }
                return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
            }
            let start = annotation.magnifierConnector == .edges ? edge(source, from: sourceCenter, dx: dx, dy: dy) : sourceCenter
            let end = edge(lens, from: lensCenter, dx: -dx, dy: -dy)
            if annotation.magnifierConnector == .dotted { context.setLineDash(phase: 0, lengths: [1, max(3, annotation.lineWidth * 2)]) }
            context.move(to: start); context.addLine(to: end); context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        if annotation.magnifierShadow {
            context.saveGState(); context.setShadow(offset: CGSize(width: 3, height: -3), blur: 8, color: CGColor(gray: 0, alpha: 0.45))
            context.setFillColor(CGColor(gray: 0, alpha: 0.25)); context.addPath(lensPath); context.fillPath(); context.restoreGState()
        }
        context.saveGState(); context.addPath(lensPath); context.clip()
        context.setShouldAntialias(annotation.magnifierSmooth)
        context.interpolationQuality = annotation.magnifierSmooth ? .high : .none
        // Mapping the entire snapshot avoids materializing and retaining a source-sized crop.
        let sx = lens.width / source.width, sy = lens.height / source.height
        context.translateBy(x: lens.minX - source.minX * sx, y: lens.minY - source.minY * sy)
        context.scaleBy(x: sx, y: sy); context.draw(snapshot, in: extent)
        if privacyMarks.contains(where: { $0.tool == .redact }) {
            guard ImageEditorRenderer.drawAnnotations(privacyMarks, in: context, extent: extent,
                effectPatchRenderer: effectPatchRenderer) else {
                context.restoreGState()
                return false
            }
        }
        context.restoreGState()
        context.addPath(lensPath); context.strokePath()
        context.setLineDash(phase: 0, lengths: [4, 3]); context.addPath(sourcePath); context.strokePath()
        return true
    }
}
