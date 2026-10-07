import AppKit

/// Settings live with the mark, so editing and undo use exactly the export geometry.
enum AnnotationPencilConstraint: Int, CaseIterable {
    case free = 0, degrees45 = 45, degrees30 = 30, degrees15 = 15, degrees10 = 10, degrees5 = 5
    var title: String { self == .free ? "自由直线" : "\(rawValue)° 直线" }
}

enum AnnotationHighlighterMode: String, CaseIterable {
    case rectangle, freehand
    var title: String { self == .rectangle ? "框选" : "画笔" }
}

enum AnnotationHighlighterBlend: String, CaseIterable {
    case translucent, multiply
    var title: String { self == .multiply ? "正片叠底" : "半透明" }
}

/// Quadratic midpoint smoothing stays inside the sample hull, includes both ends,
/// and has identical geometry when a stroke is reversed. No raster cache is retained.
enum AnnotationFreehandGeometry {
    static let maximumWidth: CGFloat = 256

    static func bounded(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }

    static func constrained(_ point: CGPoint, from anchor: CGPoint,
                            mode: AnnotationPencilConstraint, extent: CGRect) -> CGPoint {
        guard bounded(point), bounded(anchor) else { return anchor }
        var vector = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        if mode != .free {
            let increment = CGFloat(mode.rawValue) * .pi / 180
            let angle = (atan2(vector.y, vector.x) / increment).rounded() * increment
            let length = hypot(vector.x, vector.y)
            vector = CGPoint(x: length * cos(angle), y: length * sin(angle))
        }
        // Shorten the vector as a whole; clamping axes independently changes its angle.
        var fraction: CGFloat = 1
        if vector.x > 0 { fraction = min(fraction, (extent.maxX - anchor.x) / vector.x) }
        if vector.x < 0 { fraction = min(fraction, (extent.minX - anchor.x) / vector.x) }
        if vector.y > 0 { fraction = min(fraction, (extent.maxY - anchor.y) / vector.y) }
        if vector.y < 0 { fraction = min(fraction, (extent.minY - anchor.y) / vector.y) }
        return CGPoint(x: anchor.x + vector.x * max(0, fraction), y: anchor.y + vector.y * max(0, fraction))
    }

    static func path(points: [CGPoint], smoothing: Bool, corners: [Int]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard smoothing, points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        let ends = Array(Set(corners.prefix(ImageAnnotation.maximumGesturePoints).filter { $0 > 0 && $0 < points.count - 1 } + [points.count - 1])).sorted()
        var start = 0
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x / 2 + b.x / 2, y: a.y / 2 + b.y / 2) }
        for end in ends {
            if end > start + 1 {
                path.addLine(to: midpoint(points[start], points[start + 1]))
                for index in (start + 1)..<end {
                    path.addQuadCurve(to: midpoint(points[index], points[index + 1]), control: points[index])
                }
            }
            path.addLine(to: points[end]); start = end
        }
        return path
    }
}

/// At most 2,048 samples and 2,048 corner indexes, even during an unbounded drag.
/// A Shift section is one live straight segment, not many snapped sawtooth edges.
struct AnnotationFreehandGesture {
    private(set) var points: [CGPoint]
    private(set) var corners: [Int] = []
    private(set) var wasSimplified = false
    private var straightAnchor: Int?

    init(point: CGPoint, shift: Bool) {
        points = AnnotationFreehandGeometry.bounded(point) ? [point] : []
        straightAnchor = shift && !points.isEmpty ? 0 : nil
    }

    mutating func setShift(_ shift: Bool) {
        guard !points.isEmpty else { return }
        if shift && straightAnchor == nil {
            straightAnchor = points.count - 1; markCorner(points.count - 1)
        } else if !shift && straightAnchor != nil {
            markCorner(points.count - 1); straightAnchor = nil
        }
    }

    mutating func sample(_ point: CGPoint, shift: Bool, constraint: AnnotationPencilConstraint,
                         extent: CGRect, minimumDistance: CGFloat, final: Bool = false) {
        guard AnnotationFreehandGeometry.bounded(point), let last = points.last else { return }
        setShift(shift)
        if let anchor = straightAnchor {
            let end = AnnotationFreehandGeometry.constrained(point, from: points[anchor], mode: constraint, extent: extent)
            if points.count == anchor + 1 {
                guard end != last else { return }
                makeRoom(); points.append(end)
            } else { points[points.count - 1] = end }
            // The last endpoint must remain sharp when smoothing is enabled.
            markCorner(points.count - 1)
        } else if point != last && (final || hypot(point.x - last.x, point.y - last.y) >= max(0.01, minimumDistance)) {
            makeRoom(); points.append(point)
        }
    }

    private mutating func markCorner(_ index: Int) {
        if corners.last != index { corners.append(index) }
    }

    private mutating func makeRoom() {
        guard points.count >= ImageAnnotation.maximumGesturePoints else { return }
        let kept = points.indices.filter { $0.isMultiple(of: 2) || $0 == points.count - 1 }
        let mapping = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })
        let oldCorners = Set(corners)
        corners = kept.enumerated().compactMap { index, old in
            // Preserve hard joins around a discarded constrained endpoint too.
            oldCorners.contains(old) || oldCorners.contains(max(0, old - 1)) ? index : nil
        }
        if let anchor = straightAnchor { straightAnchor = mapping[anchor] ?? kept.count - 1 }
        points = kept.map { points[$0] }; wasSimplified = true
    }
}

extension ImageAnnotation {
    var isFreehandStroke: Bool { tool == .freehand || (tool == .highlighter && highlighterMode == .freehand) }
    var effectiveFreehandWidth: CGFloat {
        lineWidth.isFinite ? min(AnnotationFreehandGeometry.maximumWidth, max(1, lineWidth)) : 4
    }
    var freehandPath: CGPath {
        AnnotationFreehandGeometry.path(points: boundedPathPoints, smoothing: freehandSmoothing, corners: freehandCorners)
    }
    var freehandIsDot: Bool {
        let values = boundedPathPoints
        guard let first = values.first else { return false }
        return values.allSatisfy { hypot($0.x - first.x, $0.y - first.y) < 0.001 }
    }
    func freehandInkPath(tolerance: CGFloat = 0) -> CGPath {
        let width = effectiveFreehandWidth + max(0, tolerance) * 2
        if freehandIsDot, let first = boundedPathPoints.first {
            return CGPath(ellipseIn: CGRect(x: first.x - width / 2, y: first.y - width / 2,
                                          width: width, height: width), transform: nil)
        }
        return freehandPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}

/// One fill/stroke per mark prevents self-crossings from repeatedly applying alpha.
/// The caller retains the existing ordering, eraser clips, opacity and redaction rules.
enum AnnotationFreehandRenderer {
    static func draw(_ annotation: ImageAnnotation, in context: CGContext) {
        if annotation.tool == .highlighter {
            context.setBlendMode(annotation.highlighterBlend == .multiply ? .multiply : .normal)
            context.setFillColor(annotation.color.copy(alpha: 0.32) ?? annotation.color)
            if annotation.highlighterMode == .rectangle { context.fill(annotation.localBounds.standardized) }
            else { context.addPath(annotation.freehandInkPath()); context.fillPath() }
        } else if annotation.freehandIsDot {
            context.addPath(annotation.freehandInkPath()); context.fillPath()
        } else {
            context.setLineWidth(annotation.effectiveFreehandWidth)
            context.addPath(annotation.freehandPath); context.strokePath()
        }
    }
}
