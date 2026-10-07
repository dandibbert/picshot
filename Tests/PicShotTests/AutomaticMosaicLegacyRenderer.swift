// Retained verbatim pre-automatic-mosaic rendering reference (base da8dde5661662a728770984deec1bc0ac0ed2ea3).
// Only the enum name changed; this deliberately does not call the new renderer.
import AppKit
import CoreImage
import CoreText
@testable import PicShot

enum AutomaticMosaicLegacyRenderer {
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
        for (index, annotation) in annotations.enumerated() where annotation.tool != .eraser {
            context.saveGState()
            // Clip each later eraser separately: operation order is stable, and marks
            // added after an eraser are not removed by an earlier operation.
            let affectedBounds = annotation.tool == .spotlight ? extent :
                (annotation.tool == .magnifier ? annotation.bounds.union(annotation.magnifierSourceRect) : annotation.bounds)
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
            case .highlighter:
                context.setFillColor(annotation.color.copy(alpha: 0.32) ?? annotation.color); context.fill(rect)
            case .line, .arrow, .freehand, .polyline:
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
    }

    private static func drawText(_ text: String, point: CGPoint, size: CGFloat, color: CGColor, context: CGContext, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }

}
