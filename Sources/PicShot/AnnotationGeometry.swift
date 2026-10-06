import AppKit
import CoreText

/// Shared by canvas hit testing, edit handles and the flattened renderer.
enum AnnotationStrokeStyle: String, CaseIterable {
    case solid, dashed, dotted
    var title: String {
        switch self { case .solid: return "实线"; case .dashed: return "虚线"; case .dotted: return "点线" }
    }
    func pattern(width: CGFloat) -> [CGFloat] {
        switch self {
        case .solid: return []
        case .dashed: return [max(2, width * 3), max(2, width * 2)]
        case .dotted: return [max(0.1, width * 0.1), max(2, width * 2)]
        }
    }
}

enum AnnotationHandle: Equatable {
    case corner(Int), edge(Int), rotation, start, end, source, sourceCorner(Int)
}

extension ImageAnnotation {
    var effectiveFontSize: CGFloat { min(300, max(8, fontSize ?? max(16, lineWidth * 5))) }
    var isLinear: Bool { tool == .line || tool == .arrow }
    var hasShapeFill: Bool { tool == .rectangle || tool == .ellipse || tool == .text }
    var supportsRotation: Bool { tool != .select && tool != .crop && tool != .magnifier }

    var outline: CGPath {
        let rect = localBounds.standardized
        if tool == .spotlight { return spotlightShape.path(in: rect) }
        if tool == .magnifier { return magnifierShape.path(in: rect) }
        if tool == .ellipse || tool == .number { return CGPath(ellipseIn: rect, transform: nil) }
        if tool == .rectangle || tool == .text {
            let radius = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        return CGPath(rect: rect, transform: nil)
    }

    var strokePath: CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if tool == .arrow, let last = points.last {
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(12, lineWidth * 4)
            path.move(to: last)
            path.addLine(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
            path.move(to: last)
            path.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
        }
        return path
    }

    func hitTest(_ imagePoint: CGPoint, tolerance: CGFloat) -> Bool {
        if tool == .eraser { return erases(imagePoint) }
        if tool == .magnifier && magnifierShape.path(in: magnifierSourceRect).contains(imagePoint) { return true }
        let point = imagePoint.applying(transform.inverted())
        if tool == .watermark {
            guard localBounds.contains(point) else { return false }
            return AnnotationWatermarkLayout.tileRects(for: self).contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        }
        if isLinear || tool == .freehand {
            return strokePath.copy(strokingWithWidth: max(1, lineWidth) + tolerance * 2,
                                   lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        }
        // Interior selection is intentional for hollow shapes, matching familiar drawing editors.
        if outline.contains(point) { return true }
        return outline.copy(strokingWithWidth: max(1, lineWidth) + tolerance * 2,
                            lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }

    func handles(zoom: CGFloat) -> [(AnnotationHandle, CGPoint)] {
        let box = localBounds, scale = max(0.05, zoom)
        if isLinear, let start = points.first, let end = points.last {
            return [(.start, start.applying(transform)), (.end, end.applying(transform))]
        }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let edges = [CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.midY),
                     CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.minX, y: box.midY)]
        var result: [(AnnotationHandle, CGPoint)] = corners.enumerated().map { (.corner($0.offset), $0.element.applying(transform)) }
        result += edges.enumerated().map { (.edge($0.offset), $0.element.applying(transform)) }
        if tool == .magnifier {
            let source = magnifierSourceRect
            result += [(.source, CGPoint(x: source.midX, y: source.midY)),
                (.sourceCorner(0), CGPoint(x: source.minX, y: source.minY)),
                (.sourceCorner(1), CGPoint(x: source.maxX, y: source.minY)),
                (.sourceCorner(2), CGPoint(x: source.maxX, y: source.maxY)),
                (.sourceCorner(3), CGPoint(x: source.minX, y: source.maxY))]
        }
        if supportsRotation {
            result.append((.rotation, CGPoint(x: box.midX, y: box.maxY + 24 / scale).applying(transform)))
        }
        return result
    }

    func handle(at point: CGPoint, zoom: CGFloat) -> AnnotationHandle? {
        let radius = 6 / max(0.05, zoom)
        return handles(zoom: zoom).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= radius }?.0
    }

    func edited(handle: AnnotationHandle, from origin: CGPoint, to point: CGPoint, shift: Bool) -> ImageAnnotation {
        var result = self
        if tool == .magnifier {
            if handle == .source {
                result.magnifierSource = magnifierSourceRect.offsetBy(dx: point.x - origin.x, dy: point.y - origin.y)
                return result
            }
            if case .sourceCorner(let index) = handle {
                var sourceShape = ImageAnnotation(tool: .rectangle,
                    points: [magnifierSourceRect.origin, CGPoint(x: magnifierSourceRect.maxX, y: magnifierSourceRect.maxY)])
                sourceShape = sourceShape.edited(handle: .corner(index), from: origin, to: point, shift: shift)
                result.magnifierSource = sourceShape.localBounds
                return result.resizedMagnifierLens(scale: effectiveMagnifierScale)
            }
        }
        let box = localBounds, center = CGPoint(x: box.midX, y: box.midY)
        if handle == .rotation {
            let start = atan2(origin.y - center.y, origin.x - center.x)
            let end = atan2(point.y - center.y, point.x - center.x)
            var angle = rotation + end - start
            if shift { angle = (angle / (.pi / 12)).rounded() * (.pi / 12) }
            result.rotation = atan2(sin(angle), cos(angle))
            return result
        }
        if handle == .start || handle == .end {
            guard points.count >= 2 else { return self }
            // Bake the old transform so dragging an endpoint keeps the opposite end fixed.
            result.points = points.map { $0.applying(transform) }; result.rotation = 0
            let index = handle == .start ? 0 : result.points.count - 1
            let anchor = handle == .start ? result.points.last! : result.points.first!
            var end = point
            if shift {
                let distance = hypot(point.x - anchor.x, point.y - anchor.y)
                let angle = (atan2(point.y - anchor.y, point.x - anchor.x) / (.pi / 4)).rounded() * (.pi / 4)
                end = CGPoint(x: anchor.x + distance * cos(angle), y: anchor.y + distance * sin(angle))
            }
            result.points[index] = end
            return result
        }
        let local = point.applying(transform.inverted())
        var minX = box.minX, maxX = box.maxX, minY = box.minY, maxY = box.maxY
        var changesLeft = false, changesRight = false, changesBottom = false, changesTop = false
        switch handle {
        case .corner(let index):
            changesLeft = index == 0 || index == 3; changesRight = !changesLeft
            changesBottom = index == 0 || index == 1; changesTop = !changesBottom
        case .edge(let index):
            changesBottom = index == 0; changesRight = index == 1; changesTop = index == 2; changesLeft = index == 3
        default: return self
        }
        // Do not reflect on crossing the anchor: retaining a minimum box avoids singular transforms.
        let minimum: CGFloat = tool == .text ? 16 : 2
        if changesLeft { minX = min(local.x, maxX - minimum) }
        if changesRight { maxX = max(local.x, minX + minimum) }
        if changesBottom { minY = min(local.y, maxY - minimum) }
        if changesTop { maxY = max(local.y, minY + minimum) }
        if (shift || tool == .number || tool == .magnifier), case .corner = handle, box.width > 0, box.height > 0 {
            let ratio = box.width / box.height
            let width = maxX - minX, height = maxY - minY
            if width / height > ratio {
                if changesBottom { minY = maxY - width / ratio } else { maxY = minY + width / ratio }
            } else {
                if changesLeft { minX = maxX - height * ratio } else { maxX = minX + height * ratio }
            }
        }
        var newBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if tool == .number {
            let diameter = max(28, max(newBox.width, newBox.height))
            if changesLeft { newBox.origin.x = box.maxX - diameter }
            else if !changesRight { newBox.origin.x = box.midX - diameter / 2 }
            if changesBottom { newBox.origin.y = box.maxY - diameter }
            else if !changesTop { newBox.origin.y = box.midY - diameter / 2 }
            newBox.size = CGSize(width: diameter, height: diameter)
        }
        // Recenter the unrotated geometry so the opposite handle stays fixed in image space.
        let transformedCenter = CGPoint(x: newBox.midX, y: newBox.midY).applying(transform)
        let delta = CGSize(width: transformedCenter.x - newBox.midX, height: transformedCenter.y - newBox.midY)
        if tool == .text {
            result.points = [CGPoint(x: newBox.minX + delta.width, y: newBox.minY + delta.height)]
            result.textBoxSize = newBox.size
        } else if tool == .number {
            result.points = [transformedCenter]; result.lineWidth = newBox.width / 8
        } else {
            result.points = points.map { value in
                let x = box.width > 0 ? (value.x - box.minX) / box.width : 0.5
                let y = box.height > 0 ? (value.y - box.minY) / box.height : 0.5
                return CGPoint(x: newBox.minX + x * newBox.width + delta.width, y: newBox.minY + y * newBox.height + delta.height)
            }
        }
        if tool == .magnifier {
            let source = magnifierSourceRect
            let proposedScale = changesTop || changesBottom ? newBox.height / max(1, source.height) : newBox.width / max(1, source.width)
            result = result.resizedMagnifierLens(scale: proposedScale)
        }
        return result
    }

    /// Moving a lens keeps its sample source fixed. Whole-object translation (used by
    /// crop/boundary changes and duplication) deliberately moves both components.
    func translatedLens(by delta: CGSize) -> ImageAnnotation {
        var result = self
        result.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return result
    }

    func resizedMagnifierLens(scale: CGFloat) -> ImageAnnotation {
        var result = self
        result.magnifierScale = scale.isFinite ? min(8, max(1, scale)) : 2
        let source = magnifierSourceRect, lens = localBounds
        let size = CGSize(width: max(2, source.width) * result.magnifierScale,
                          height: max(2, source.height) * result.magnifierScale)
        result.points = [CGPoint(x: lens.midX - size.width / 2, y: lens.midY - size.height / 2),
                         CGPoint(x: lens.midX + size.width / 2, y: lens.midY + size.height / 2)]
        result.rotation = 0
        return result
    }
}

/// Core Text is used for both measuring and rasterizing. It keeps wrapping, font traits and
/// bottom-left coordinates identical in the on-screen preview and all export formats.
enum AnnotationTextLayout {
    static let padding: CGFloat = 4
    static func font(for annotation: ImageAnnotation) -> CTFont {
        let base = CTFontCreateWithName(annotation.fontName as CFString, annotation.effectiveFontSize, nil)
        var traits: CTFontSymbolicTraits = []
        if annotation.bold { traits.insert(.traitBold) }
        if annotation.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
    }

    static func attributedString(for annotation: ImageAnnotation) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(for: annotation),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color
        ]
        if annotation.underline { attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = 1 }
        return NSAttributedString(string: annotation.text, attributes: attributes)
    }

    static func size(for annotation: ImageAnnotation) -> CGSize {
        if let size = annotation.textBoxSize {
            return CGSize(width: max(16, size.width), height: max(16, size.height))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(for: annotation))
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                   CGSize(width: 312, height: 100_000), nil)
        return CGSize(width: max(16, ceil(measured.width) + padding * 2),
                      height: max(annotation.effectiveFontSize * 1.3, ceil(measured.height) + padding * 2))
    }

    static func draw(_ annotation: ImageAnnotation, context: CGContext) {
        let box = annotation.localBounds
        context.saveGState()
        context.addPath(annotation.outline); context.clip()
        context.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(for: annotation))
        let content = box.insetBy(dx: padding, dy: padding)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: content, transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
