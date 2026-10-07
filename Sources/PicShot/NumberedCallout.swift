import AppKit
import CoreText
import PicShotCore

extension ImageAnnotation {
    var numberRadius: CGFloat { min(80, max(14, (lineWidth.isFinite ? lineWidth : 4) * 4)) }
    var numberBadgeRect: CGRect {
        let center = points.first ?? .zero, radius = numberRadius
        return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
    var numberCommentRect: CGRect {
        let badge = numberBadgeRect
        let size = CGSize(width: min(600, max(60, numberCommentSize.width.isFinite ? numberCommentSize.width : 240)),
                          height: min(400, max(28, numberCommentSize.height.isFinite ? numberCommentSize.height : 80)))
        return CGRect(x: badge.maxX + 12, y: badge.midY - size.height / 2, width: size.width, height: size.height)
    }
    var hasNumberComment: Bool { !numberComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var numberLeaderPath: CGPath {
        let path = CGMutablePath()
        guard let center = points.first, points.count > 1 else { return path }
        let tip = points[1], distance = hypot(tip.x - center.x, tip.y - center.y)
        guard distance > numberRadius + 2 else { return path }
        let angle = atan2(tip.y - center.y, tip.x - center.x)
        let length = min(distance - numberRadius, max(8, min(24, lineWidth * 3)))
        path.move(to: CGPoint(x: center.x + numberRadius * cos(angle), y: center.y + numberRadius * sin(angle)))
        path.addLine(to: tip)
        path.move(to: CGPoint(x: tip.x - length * cos(angle - .pi / 6), y: tip.y - length * sin(angle - .pi / 6)))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + .pi / 6), y: tip.y - length * sin(angle + .pi / 6)))
        return path
    }
    var numberLocalBounds: CGRect {
        var rect = numberBadgeRect
        if hasNumberComment { rect = rect.union(numberCommentRect) }
        if !numberLeaderPath.isEmpty { rect = rect.union(numberLeaderPath.boundingBoxOfPath) }
        return rect
    }
    var sanitizedNumberCallout: ImageAnnotation {
        guard tool == .number else { return self }
        var result = self
        result.number = NumberedCalloutSequence.clamp(number)
        result.points = Array(points.lazy.filter { $0.x.isFinite && $0.y.isFinite }.prefix(2))
        result.lineWidth = numberRadius / 4
        result.numberComment = NumberedCalloutSequence.boundedComment(numberComment)
        result.numberCommentSize = numberCommentRect.size
        result.rotation = rotation.isFinite ? atan2(sin(rotation), cos(rotation)) : 0
        return result
    }
    func numberHitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        CGPath(ellipseIn: numberBadgeRect.insetBy(dx: -tolerance, dy: -tolerance), transform: nil).contains(point)
            || (hasNumberComment && numberCommentRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point))
            || numberLeaderPath.copy(strokingWithWidth: max(1, lineWidth) + tolerance * 2,
                lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }
    func numberHandles(zoom: CGFloat) -> [(AnnotationHandle, CGPoint)] {
        let badge = numberBadgeRect, box = numberLocalBounds
        var handles: [(AnnotationHandle, CGPoint)] = [(.numberSize, CGPoint(x: badge.maxX, y: badge.maxY))]
        if points.count > 1 { handles.append((.end, points[1])) }
        if hasNumberComment { handles.append((.numberCommentSize, CGPoint(x: numberCommentRect.maxX, y: numberCommentRect.minY))) }
        handles.append((.rotation, CGPoint(x: box.midX, y: box.maxY + 24 / max(0.05, zoom))))
        return handles.map { ($0.0, $0.1.applying(transform)) }
    }
    func editedNumber(handle: AnnotationHandle, from origin: CGPoint, to point: CGPoint, shift: Bool) -> ImageAnnotation {
        guard let center = points.first else { return self }
        var result = self
        if handle == .rotation {
            let angle = rotation + atan2(point.y - center.y, point.x - center.x) - atan2(origin.y - center.y, origin.x - center.x)
            result.rotation = shift ? (angle / (.pi / 12)).rounded() * (.pi / 12) : angle
        } else {
            let local = point.applying(transform.inverted())
            if handle == .numberSize {
                result.lineWidth = min(80, max(14, max(local.x - center.x, local.y - center.y))) / 4
            } else if handle == .numberCommentSize {
                result.numberCommentSize = CGSize(width: local.x - numberCommentRect.minX,
                                                  height: max(28, 2 * abs(local.y - center.y)))
            } else if handle == .end, points.count > 1 {
                var target = local
                if shift {
                    let angle = (atan2(local.y - center.y, local.x - center.x) / (.pi / 4)).rounded() * (.pi / 4)
                    let length = hypot(local.x - center.x, local.y - center.y)
                    target = CGPoint(x: center.x + length * cos(angle), y: center.y + length * sin(angle))
                }
                result.points[1] = target
            }
        }
        return result.sanitizedNumberCallout
    }
    mutating func setNumberLeader(_ enabled: Bool) {
        guard let center = points.first else { return }
        if enabled, points.count < 2 { points.append(CGPoint(x: center.x - numberRadius - 50, y: center.y - numberRadius - 50)) }
        if !enabled { points = [center] }
    }
}

/// One Core Text / vector path renderer serves preview, export and recording.
enum NumberedCalloutRenderer {
    static func draw(_ source: ImageAnnotation, in context: CGContext) {
        let annotation = source.sanitizedNumberCallout, badge = annotation.numberBadgeRect
        context.setLineDash(phase: 0, lengths: [])
        context.setStrokeColor(annotation.color); context.setFillColor(annotation.color)
        context.setLineWidth(max(1, annotation.lineWidth))
        context.addPath(annotation.numberLeaderPath); context.strokePath()
        if annotation.hasNumberComment {
            context.move(to: CGPoint(x: badge.maxX, y: badge.midY))
            context.addLine(to: CGPoint(x: annotation.numberCommentRect.minX, y: badge.midY)); context.strokePath()
        }
        context.fillEllipse(in: badge)
        let value = annotation.numberStyle.label(for: annotation.number)
        var size = badge.height * 0.58
        func line(_ size: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
        }
        var label = line(size)
        let width = CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil))
        if width > badge.width * 0.82 { size *= badge.width * 0.82 / width; label = line(size) }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: badge.midX - CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil)) / 2,
                                       y: badge.midY - size * 0.37)
        CTLineDraw(label, context)
        guard annotation.hasNumberComment else { return }
        let box = annotation.numberCommentRect
        context.saveGState()
        let path = CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.setFillColor(CGColor(gray: 1, alpha: 0.94)); context.addPath(path); context.fillPath()
        context.setLineWidth(1); context.addPath(path); context.strokePath()
        context.addPath(path); context.clip()
        var text = annotation
        text.tool = .text; text.text = annotation.numberComment; text.points = [box.origin]
        text.textBoxSize = box.size; text.rotation = 0
        let framesetter = CTFramesetterCreateWithAttributedString(AnnotationTextLayout.attributedString(for: text))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: box.insetBy(dx: 6, dy: 6), transform: nil), nil)
        CTFrameDraw(frame, context); context.restoreGState()
    }
}

/// Bounded, canvas-local comment editing. The original mark changes only on acceptance.
@MainActor
final class NumberedCalloutCommentSession: NSObject, NSTextViewDelegate {
    let annotation: ImageAnnotation
    let box: InlineAnnotationTextBox
    let imageScaleX: CGFloat
    let imageScaleY: CGFloat
    private let inputUndoManager = UndoManager()
    var resizedCommentSize: CGSize {
        CGSize(width: box.bounds.width / imageScaleX, height: box.bounds.height / imageScaleY)
    }
    init(annotation: ImageAnnotation, frame: CGRect, zoom: CGFloat, verticalZoom: CGFloat? = nil) {
        self.annotation = annotation
        let scaleX = zoom.isFinite ? max(0.05, zoom) : 1
        imageScaleX = scaleX
        let y = verticalZoom ?? zoom
        imageScaleY = y.isFinite ? max(0.05, y) : scaleX
        var text = annotation; text.tool = .text; text.text = annotation.numberComment
        text.fillEnabled = true; text.fillColor = CGColor(gray: 1, alpha: 1)
        box = InlineAnnotationTextBox(frame: frame, annotation: text, zoom: zoom)
        super.init()
        inputUndoManager.levelsOfUndo = 32
        box.input.identifier = .init("annotation.numberCommentInput")
        box.input.setAccessibilityLabel("序号注释，最多 2048 个 UTF-16 单位；Command Return 完成，Escape 取消")
        box.input.delegate = self
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let retained = textView.string.utf16.count - affectedCharRange.length
        return retained >= 0 && replacementString.utf16.prefix(NumberedCalloutSequence.maximumCommentUTF16 + 1).count <= NumberedCalloutSequence.maximumCommentUTF16 - retained
    }
    func undoManager(for view: NSTextView) -> UndoManager? { inputUndoManager }
    func textDidChange(_ notification: Notification) {
        guard !box.input.hasMarkedText() else { return }
        let bounded = NumberedCalloutSequence.boundedComment(box.input.string)
        if box.input.string != bounded { box.input.string = bounded }
    }
    func close() {
        box.input.delegate = nil; box.input.onAccept = nil; box.input.onCancel = nil
        box.onAccept = nil; box.onCancel = nil; inputUndoManager.removeAllActions()
        box.removeFromSuperview()
    }
}
