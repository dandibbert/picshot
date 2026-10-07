import AppKit

/// Value-only styles travel with annotations through copy, transform and undo.
enum AnnotationLineCap: String, CaseIterable {
    case round, butt, square
    var title: String {
        switch self { case .round: return "圆端"; case .butt: return "平端"; case .square: return "方端" }
    }
    var cgValue: CGLineCap {
        switch self { case .round: return .round; case .butt: return .butt; case .square: return .square }
    }
}

enum AnnotationLineJoin: String, CaseIterable {
    case round, miter, bevel
    var title: String {
        switch self { case .round: return "圆角"; case .miter: return "尖角"; case .bevel: return "斜角" }
    }
    var cgValue: CGLineJoin {
        switch self { case .round: return .round; case .miter: return .miter; case .bevel: return .bevel }
    }
}

enum AnnotationArrowhead: String, CaseIterable {
    case open, filledTriangle, outlineTriangle, diamond, circle
    var title: String {
        switch self {
        case .open: return "开放"
        case .filledTriangle: return "实心"
        case .outlineTriangle: return "空心"
        case .diamond: return "菱形"
        case .circle: return "圆点"
        }
    }
}

extension ImageAnnotation {
    var supportsLineEndings: Bool { [.line, .arrow, .polyline].contains(tool) }
    var effectiveEndArrowEnabled: Bool { endArrowEnabled ?? (tool == .arrow) }
    var lineEndingFillPath: CGPath { AnnotationLineGeometry.paths(for: self).fill }
    var linePaintedBounds: CGRect {
        let paths = AnnotationLineGeometry.paths(for: self)
        let stroke = paths.stroke.copy(strokingWithWidth: max(1, lineWidth), lineCap: lineCap.cgValue,
                                       lineJoin: lineJoin.cgValue, miterLimit: 10)
        return stroke.boundingBoxOfPath.union(paths.fill.boundingBoxOfPath).applying(transform)
    }
    var effectiveTextOutlineWidth: CGFloat {
        guard textOutlineEnabled else { return 0 }
        return min(8, max(0.5, textOutlineWidth.isFinite ? textOutlineWidth : 2))
    }
    /// Stroke width is a percentage of font size, including in the zoomed NSTextView.
    var textOutlinePercentage: CGFloat { -100 * effectiveTextOutlineWidth / effectiveFontSize }
}

/// Shared analytic geometry for selection, live preview and flattened output.
/// Default arrows deliberately retain the original path commands and dash phase.
enum AnnotationLineGeometry {
    struct Paths {
        let stroke: CGPath
        let fill: CGPath
    }

    static func draw(_ annotation: ImageAnnotation, in context: CGContext) {
        let geometry = paths(for: annotation)
        guard !geometry.fill.isEmpty else {
            // Keep the legacy CoreGraphics stroke operation and its exact dash pixels.
            context.addPath(geometry.stroke); context.strokePath(); return
        }
        let dash = annotation.strokeStyle.pattern(width: annotation.lineWidth)
        let centerline = dash.isEmpty ? geometry.stroke : geometry.stroke.copy(dashingWithPhase: 0, lengths: dash)
        let shaft = centerline.copy(strokingWithWidth: max(1, annotation.lineWidth),
            lineCap: annotation.lineCap.cgValue, lineJoin: annotation.lineJoin.cgValue, miterLimit: 10)
        // Paint one vector union. Drawing caps and solid heads separately applies
        // color/global alpha twice at their overlap and leaves a dark seam.
        context.addPath(shaft.union(geometry.fill, using: .winding)); context.fillPath()
    }

    static func paths(for annotation: ImageAnnotation) -> Paths {
        let stroke = CGMutablePath(), fill = CGMutablePath()
        let raw = annotation.boundedPathPoints.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = raw.first else { return Paths(stroke: stroke, fill: fill) }
        if !annotation.startArrowEnabled && !annotation.effectiveEndArrowEnabled {
            stroke.move(to: first)
            for point in raw.dropFirst() { stroke.addLine(to: point) }
            return Paths(stroke: stroke, fill: fill)
        }
        if annotation.tool == .arrow && !annotation.startArrowEnabled && annotation.effectiveEndArrowEnabled && annotation.endArrowhead == .open {
            // Do not subtly change existing arrow pixels, even for very short arrows.
            stroke.move(to: first)
            for point in raw.dropFirst() { stroke.addLine(to: point) }
            if let last = raw.last {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(12, annotation.lineWidth * 4)
                stroke.move(to: last)
                stroke.addLine(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                stroke.move(to: last)
                stroke.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
            }
            return Paths(stroke: stroke, fill: fill)
        }
        // Direction comes from each endpoint's nearest distinct neighbour. Repeated
        // clicks cannot create NaNs or point a polyline head at the opposite endpoint.
        var points: [CGPoint] = []
        for point in raw where points.last != point { points.append(point) }
        guard points.count >= 2 else {
            stroke.move(to: first); stroke.addLine(to: first)
            return Paths(stroke: stroke, fill: fill)
        }
        var body = points
        let headStroke = CGMutablePath()
        let width = annotation.lineWidth.isFinite ? max(1, annotation.lineWidth) : 4
        let requestedLength = min(4096, max(12, width * 4))
        func appendHead(tip: CGPoint, neighbour: CGPoint, form: AnnotationArrowhead, sharedSegment: Bool) -> CGPoint {
            let distance = hypot(tip.x - neighbour.x, tip.y - neighbour.y)
            guard distance > 0.000_001 else { return tip }
            let angle = atan2(tip.y - neighbour.y, tip.x - neighbour.x)
            // A pair of closed heads on a short segment must never cross or reverse its shaft.
            let length = form == .open ? requestedLength : min(requestedLength, distance / (sharedSegment ? 2 : 1))
            let depth = length * cos(.pi / 6), halfWidth = length * sin(.pi / 6)
            func point(_ behind: CGFloat, _ across: CGFloat) -> CGPoint {
                CGPoint(x: tip.x - behind * cos(angle) - across * sin(angle),
                        y: tip.y - behind * sin(angle) + across * cos(angle))
            }
            let left = point(depth, halfWidth), right = point(depth, -halfWidth)
            switch form {
            case .open:
                headStroke.move(to: tip); headStroke.addLine(to: left)
                headStroke.move(to: tip); headStroke.addLine(to: right)
                return tip
            case .filledTriangle, .outlineTriangle:
                let path = form == .filledTriangle ? fill : headStroke
                path.move(to: tip); path.addLine(to: left); path.addLine(to: right); path.closeSubpath()
                return point(depth, 0)
            case .diamond:
                fill.move(to: tip); fill.addLine(to: point(depth / 2, halfWidth))
                fill.addLine(to: point(depth, 0)); fill.addLine(to: point(depth / 2, -halfWidth)); fill.closeSubpath()
                return point(depth, 0)
            case .circle:
                let center = point(depth / 2, 0)
                fill.addEllipse(in: CGRect(x: center.x - depth / 2, y: center.y - depth / 2, width: depth, height: depth))
                return point(depth, 0)
            }
        }
        let sharedSegment = points.count == 2 && annotation.startArrowEnabled && annotation.effectiveEndArrowEnabled
        if annotation.startArrowEnabled {
            body[0] = appendHead(tip: points[0], neighbour: points[1], form: annotation.startArrowhead, sharedSegment: sharedSegment)
        }
        if annotation.effectiveEndArrowEnabled {
            body[body.count - 1] = appendHead(tip: points[points.count - 1], neighbour: points[points.count - 2], form: annotation.endArrowhead, sharedSegment: sharedSegment)
        }
        stroke.move(to: body[0])
        for point in body.dropFirst() { stroke.addLine(to: point) }
        stroke.addPath(headStroke)
        return Paths(stroke: stroke, fill: fill)
    }
}
