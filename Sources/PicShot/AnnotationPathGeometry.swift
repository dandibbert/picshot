import AppKit

/// A single analytic ellipse arc is shared by selection and every raster output.
/// Angles use image-space radians (counterclockwise in y-up coordinates).
enum AnnotationArcGeometry {
    static let minimumSweep: CGFloat = .pi / 180
    static let fullTurn: CGFloat = .pi * 2

    static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 0 }
        let value = angle.truncatingRemainder(dividingBy: fullTurn)
        return value < 0 ? value + fullTurn : value
    }

    static func boundedSweep(_ sweep: CGFloat) -> CGFloat {
        guard sweep.isFinite else { return .pi * 1.5 }
        return (sweep < 0 ? -1 : 1) * min(fullTurn, max(minimumSweep, abs(sweep)))
    }

    static func point(in box: CGRect, angle: CGFloat) -> CGPoint {
        CGPoint(x: box.midX + box.width / 2 * cos(angle), y: box.midY + box.height / 2 * sin(angle))
    }

    static func angle(at point: CGPoint, in box: CGRect) -> CGFloat {
        normalizedAngle(atan2((point.y - box.midY) / max(0.001, box.height / 2),
                              (point.x - box.midX) / max(0.001, box.width / 2)))
    }

    static func sweep(from start: CGFloat, to end: CGFloat, direction: CGFloat) -> CGFloat {
        let distance = normalizedAngle(direction < 0 ? start - end : end - start)
        // Coincident handles represent a complete circle, never a disappearing mark.
        return (direction < 0 ? -1 : 1) * (distance < 0.000_001 ? fullTurn : max(minimumSweep, distance))
    }

    static func path(in box: CGRect, start: CGFloat, sweep: CGFloat, sector: Bool) -> CGPath {
        let path = CGMutablePath()
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0 else { return path }
        let start = normalizedAngle(start), sweep = boundedSweep(sweep)
        if sector && abs(sweep) >= fullTurn - 0.000_001 { return CGPath(ellipseIn: box, transform: nil) }
        let unit = CGMutablePath()
        if sector { unit.move(to: .zero); unit.addLine(to: CGPoint(x: cos(start), y: sin(start))) }
        // Splitting a full turn avoids Core Graphics' coincident-endpoint ambiguity.
        let pieces = max(1, Int(ceil(abs(sweep) / (.pi / 2))))
        for index in 0..<pieces {
            unit.addArc(center: .zero, radius: 1, startAngle: start + sweep * CGFloat(index) / CGFloat(pieces),
                        endAngle: start + sweep * CGFloat(index + 1) / CGFloat(pieces), clockwise: sweep < 0)
        }
        if sector || abs(sweep) >= fullTurn - 0.000_001 { unit.closeSubpath() }
        var transform = CGAffineTransform(translationX: box.midX, y: box.midY).scaledBy(x: box.width / 2, y: box.height / 2)
        return unit.copy(using: &transform) ?? path
    }
}

extension ImageEditorTool {
    var isArcTool: Bool { self == .arc || self == .sector }
}

extension ImageAnnotation {
    /// A bounded click-built path needs no raster backing and has at most 256 handles.
    static let maximumPolylinePoints = 256
    var isArc: Bool { tool == .arc || tool == .sector }
    var effectiveArcStart: CGFloat { AnnotationArcGeometry.normalizedAngle(arcStartAngle) }
    var effectiveArcSweep: CGFloat { AnnotationArcGeometry.boundedSweep(arcSweepAngle) }
    var arcStartPoint: CGPoint { AnnotationArcGeometry.point(in: localBounds, angle: effectiveArcStart) }
    var arcEndPoint: CGPoint { AnnotationArcGeometry.point(in: localBounds, angle: effectiveArcStart + effectiveArcSweep) }
    var boundedPathPoints: [CGPoint] {
        if isFreehandStroke {
            return points.prefix(Self.maximumGesturePoints).filter { AnnotationFreehandGeometry.bounded($0) }
        }
        guard tool == .polyline else { return points }
        return Array(points.lazy.filter { $0.x.isFinite && $0.y.isFinite }.prefix(Self.maximumPolylinePoints))
    }
    var sanitizedPathGeometry: ImageAnnotation {
        var result = self
        if tool == .polyline { result.points = boundedPathPoints }
        if isFreehandStroke {
            let valid = points.prefix(Self.maximumGesturePoints).enumerated().filter { AnnotationFreehandGeometry.bounded($0.element) }
            let corners = Set(freehandCorners.prefix(Self.maximumGesturePoints))
            result.points = valid.map(\.element)
            result.freehandCorners = valid.enumerated().compactMap { corners.contains($0.element.offset) ? $0.offset : nil }
            result.lineWidth = effectiveFreehandWidth
            result.freehandWasSimplified = freehandWasSimplified || points.count > Self.maximumGesturePoints
        }
        if isArc { result.arcStartAngle = effectiveArcStart; result.arcSweepAngle = effectiveArcSweep }
        return result.sanitizedNumberCallout
    }
}

/// Original template artwork for the three tools, keeping toolbar geometry compact.
@MainActor
enum AnnotationPathIcons {
    static func image(for tool: ImageEditorTool) -> NSImage? {
        guard [.arc, .sector, .polyline].contains(tool) else { return nil }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let path = NSBezierPath(); path.lineWidth = 1.7; path.lineCapStyle = .round; path.lineJoinStyle = .round
            if tool == .polyline {
                path.move(to: CGPoint(x: 2, y: 4)); path.line(to: CGPoint(x: 7, y: 15))
                path.line(to: CGPoint(x: 13, y: 7)); path.line(to: CGPoint(x: 18, y: 16))
            } else {
                if tool == .sector { path.move(to: CGPoint(x: 10, y: 10)); path.line(to: CGPoint(x: 18, y: 10)) }
                path.appendArc(withCenter: CGPoint(x: 10, y: 10), radius: 8, startAngle: 0, endAngle: 245)
                if tool == .sector { path.close() }
            }
            path.stroke(); return true
        }
        image.isTemplate = true
        return image
    }
}
