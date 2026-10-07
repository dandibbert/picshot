import XCTest
import AppKit
import CoreText
@testable import PicShot

final class AnnotationTextLineStyleTests: XCTestCase {
    func testLegacyDefaultLineAndArrowPixelsRemainExactIncludingShortReversedAndZeroLength() throws {
        for tool in [ImageEditorTool.line, .arrow, .polyline] {
            for points in [[CGPoint(x: 20, y: 60), CGPoint(x: 180, y: 80)],
                           [CGPoint(x: 180, y: 80), CGPoint(x: 20, y: 60)],
                           [CGPoint(x: 100, y: 60), CGPoint(x: 101, y: 60)],
                           [CGPoint(x: 100, y: 60), CGPoint(x: 100, y: 60)]] {
                for style in AnnotationStrokeStyle.allCases {
                    var mark = ImageAnnotation(tool: tool, points: points, color: CGColor(gray: 0, alpha: 1), lineWidth: 6)
                    mark.strokeStyle = style; mark.opacity = 0.65; mark.rotation = 0.23
                    let actual = try XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))
                    XCTAssertEqual(try bytes(actual), try bytes(legacyLine(mark)), "\(tool) \(style) \(points)")
                }
            }
        }
    }

    func testEndpointDefaultsBelongToToolAndExplicitEndToggleOverridesThem() {
        for tool in [ImageEditorTool.line, .arrow, .polyline] {
            var mark = ImageAnnotation(tool: tool, points: [])
            XCTAssertFalse(mark.startArrowEnabled)
            XCTAssertEqual(mark.effectiveEndArrowEnabled, tool == .arrow)
            mark.endArrowEnabled = true; XCTAssertTrue(mark.effectiveEndArrowEnabled)
            mark.endArrowEnabled = false; XCTAssertFalse(mark.effectiveEndArrowEnabled)
        }
    }

    func testClosedHeadFollowsLastDistinctSegmentAndInteriorIsSelectable() {
        var mark = ImageAnnotation(tool: .polyline, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 100)])
        mark.endArrowEnabled = true; mark.endArrowhead = .filledTriangle
        XCTAssertTrue(mark.lineEndingFillPath.contains(CGPoint(x: 100, y: 95)))
        XCTAssertTrue(mark.hitTest(CGPoint(x: 104, y: 89), tolerance: 0))
        XCTAssertFalse(mark.lineEndingFillPath.contains(CGPoint(x: 95, y: 100)))
        mark.startArrowEnabled = true; mark.startArrowhead = .diamond
        XCTAssertTrue(mark.lineEndingFillPath.contains(CGPoint(x: 25, y: 20)))
        mark.rotation = .pi / 3
        XCTAssertTrue(mark.hitTest(CGPoint(x: 25, y: 20).applying(mark.transform), tolerance: 0))
    }

    func testClosedHeadsNeverCrossOnTinyReversedOrRepeatedSegmentsAndZeroIsFinite() {
        for form in AnnotationArrowhead.allCases {
            for points in [[CGPoint(x: 51, y: 50), CGPoint(x: 50, y: 50)],
                           [CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50)],
                           [CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), CGPoint(x: 51, y: 50)]] {
                var mark = ImageAnnotation(tool: .polyline, points: points, lineWidth: 24)
                mark.startArrowEnabled = true; mark.endArrowEnabled = true
                mark.startArrowhead = form; mark.endArrowhead = form
                let paths = AnnotationLineGeometry.paths(for: mark)
                for path in [paths.stroke, paths.fill] where !path.isEmpty {
                    let rect = path.boundingBoxOfPath
                    XCTAssertTrue([rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite))
                }
                if form != .open && points.first != points.last {
                    if !paths.fill.isEmpty { XCTAssertLessThanOrEqual(paths.fill.boundingBoxOfPath.width, 1.001) }
                    XCTAssertGreaterThanOrEqual(paths.stroke.boundingBoxOfPath.minX, 50)
                    XCTAssertLessThanOrEqual(paths.stroke.boundingBoxOfPath.maxX, 51)
                }
            }
        }
    }

    func testCapsChangeActualPixelsAndHitTestingAtEndpoint() throws {
        var mark = ImageAnnotation(tool: .line, points: [CGPoint(x: 50, y: 60), CGPoint(x: 150, y: 60)], color: CGColor(gray: 0, alpha: 1), lineWidth: 12)
        for cap in AnnotationLineCap.allCases {
            mark.lineCap = cap
            let image = try XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))
            XCTAssertEqual(try pixel(image, x: 45, y: 60)[0] < 100, cap != .butt)
            XCTAssertEqual(mark.hitTest(CGPoint(x: 45, y: 60), tolerance: 0), cap != .butt)
            if cap == .square { XCTAssertLessThan(try pixel(image, x: 45, y: 65)[0], 100) }
            if cap == .round { XCTAssertGreaterThan(try pixel(image, x: 45, y: 65)[0], 240) }
        }
    }

    func testMiterBevelAndRoundJoinsProduceDistinctFiniteRasters() throws {
        var mark = ImageAnnotation(tool: .polyline, points: [CGPoint(x: 40, y: 30), CGPoint(x: 100, y: 125), CGPoint(x: 110, y: 30)], color: CGColor(gray: 0, alpha: 1), lineWidth: 16)
        var images = Set<Data>()
        for join in AnnotationLineJoin.allCases {
            mark.lineJoin = join
            images.insert(try bytes(XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))))
            XCTAssertTrue(mark.hitTest(CGPoint(x: 100, y: 125), tolerance: 1))
        }
        XCTAssertEqual(images.count, 3)
    }

    func testEveryHeadFormChangesPixelsAndCanBeTurnedOffIndependently() throws {
        var mark = ImageAnnotation(tool: .line, points: [CGPoint(x: 30, y: 80), CGPoint(x: 180, y: 80)], color: CGColor(gray: 0, alpha: 1), lineWidth: 5)
        let noHeads = try bytes(XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark])))
        var images = Set<Data>()
        for form in AnnotationArrowhead.allCases {
            mark.endArrowEnabled = true; mark.endArrowhead = form
            let image = try bytes(XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark])))
            XCTAssertNotEqual(image, noHeads); images.insert(image)
        }
        XCTAssertEqual(images.count, AnnotationArrowhead.allCases.count)
        mark.endArrowEnabled = false
        XCTAssertEqual(try bytes(XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))), noHeads)
        mark.startArrowEnabled = true
        XCTAssertNotEqual(try bytes(XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))), noHeads)
    }

    func testTranslucentClosedHeadsAndShaftCapsCompositeOnlyOnce() throws {
        for form in [AnnotationArrowhead.filledTriangle, .diamond, .circle] {
            for cap in [AnnotationLineCap.round, .square] {
                for colorAlpha in [CGFloat(1), 0.5] {
                    var mark = ImageAnnotation(tool: .line, points: [CGPoint(x: 20, y: 80), CGPoint(x: 180, y: 80)],
                        color: CGColor(gray: 0, alpha: colorAlpha), lineWidth: 12)
                    mark.opacity = 0.5; mark.lineCap = cap; mark.endArrowEnabled = true; mark.endArrowhead = form
                    let image = try XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))
                    let shaft = try pixel(image, x: 100, y: 80)[0]
                    // The head base is x=138.43, inside a round/square shaft cap.
                    let joint = try pixel(image, x: 141, y: 80)[0]
                    XCTAssertLessThanOrEqual(abs(Int(shaft) - Int((255 * (1 - colorAlpha * 0.5)).rounded())), 1)
                    XCTAssertLessThanOrEqual(abs(Int(joint) - Int(shaft)), 1, "\(form)/\(cap) must not double-compose opacity at the junction")
                }
            }
        }
    }

    func testMultilingualRotatedWrappedOutlineAddsIndependentColorWithoutChangingBox() throws {
        var mark = ImageAnnotation(tool: .text, points: [CGPoint(x: 20, y: 15)], color: CGColor(gray: 0, alpha: 1), text: "Hello 世界 العربية\n日本語 한글")
        mark.fontSize = 24; mark.textBoxSize = CGSize(width: 180, height: 130)
        mark.bold = true; mark.italic = true; mark.underline = true; mark.rotation = 0.17
        mark.fillEnabled = true; mark.fillColor = CGColor(srgbRed: 1, green: 1, blue: 0.8, alpha: 1)
        let bounds = mark.localBounds, size = AnnotationTextLayout.size(for: mark)
        let plain = try bytes(XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark])))
        mark.textOutlineEnabled = true; mark.textOutlineWidth = 2
        mark.textOutlineColor = CGColor(srgbRed: 0, green: 0.3, blue: 1, alpha: 1)
        let outlined = try XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))
        XCTAssertEqual(mark.localBounds, bounds); XCTAssertEqual(AnnotationTextLayout.size(for: mark), size)
        let data = [UInt8](try bytes(outlined))
        XCTAssertGreaterThan(stride(from: 0, to: data.count, by: 4).filter { data[$0 + 2] > 150 && data[$0] < 80 }.count, 60)
        XCTAssertNotEqual(try bytes(outlined), plain)
        mark.textOutlineEnabled = false
        XCTAssertEqual(try bytes(XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))), plain)
    }

    func testOutlineKeepsMultilingualWrappingAndFontFallbackLineRanges() throws {
        var mark = ImageAnnotation(tool: .text, points: [CGPoint(x: 20, y: 10)], text: "Hello 世界 العربية 日本語 한글 ✨ more words wrap across narrow lines")
        mark.fontSize = 22; mark.textBoxSize = CGSize(width: 135, height: 145)
        func ranges(_ value: ImageAnnotation) -> [NSRange] {
            let setter = CTFramesetterCreateWithAttributedString(AnnotationTextLayout.attributedString(for: value))
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                CGPath(rect: value.localBounds.insetBy(dx: 4, dy: 4), transform: nil), nil)
            return (CTFrameGetLines(frame) as! [CTLine]).map {
                let range = CTLineGetStringRange($0)
                return NSRange(location: range.location, length: range.length)
            }
        }
        let plain = ranges(mark); XCTAssertGreaterThanOrEqual(plain.count, 3)
        mark.textOutlineEnabled = true; mark.textOutlineWidth = 3
        XCTAssertEqual(ranges(mark), plain, "Glyph outline must not alter wrapping or fallback shaping")
        let image = try XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))
        XCTAssertEqual(try pixel(image, x: 157, y: 85), [255, 255, 255, 255], "Text stays clipped to its explicit box")
    }

    func testOutlineIsBoundedAndDoesNotChangeLegacyTextAttributesWhileOff() {
        var text = ImageAnnotation(tool: .text, points: [.zero], text: "text")
        XCTAssertNil(AnnotationTextLayout.attributedString(for: text).attribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), at: 0, effectiveRange: nil))
        text.textOutlineEnabled = true; text.textOutlineWidth = .nan
        XCTAssertEqual(text.effectiveTextOutlineWidth, 2)
        text.textOutlineWidth = 1000; XCTAssertEqual(text.effectiveTextOutlineWidth, 8)
        text.textOutlineWidth = -20; XCTAssertEqual(text.effectiveTextOutlineWidth, 0.5)
    }

    func testNewStylesCannotReduceOpaqueRedaction() throws {
        var mark = ImageAnnotation(tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 180, y: 130)], color: CGColor(gray: 0, alpha: 0), lineWidth: 24)
        mark.opacity = 0; mark.textOutlineEnabled = true; mark.fillEnabled = true
        mark.startArrowEnabled = true; mark.endArrowEnabled = true; mark.endArrowhead = .outlineTriangle
        mark.lineCap = .butt; mark.lineJoin = .bevel
        let image = try XCTUnwrap(ImageEditorRenderer.render(image: blank(), annotations: [mark]))
        XCTAssertEqual(try pixel(image, x: 100, y: 80), [0, 0, 0, 255])
    }

    private func bitmap(width: Int = 220, height: Int = 160) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func blank() throws -> CGImage {
        let c = try bitmap(); c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 220, height: 160))
        return try XCTUnwrap(c.makeImage())
    }
    private func bytes(_ image: CGImage) throws -> Data {
        let c = try bitmap(width: image.width, height: image.height); c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(c.data), count: c.bytesPerRow * c.height)
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let c = try bitmap(width: 1, height: 1); c.translateBy(x: CGFloat(-x), y: CGFloat(-y))
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }
    /// Frozen pre-style line renderer: intentionally independent from the new geometry helpers.
    private func legacyLine(_ mark: ImageAnnotation) throws -> CGImage {
        let c = try bitmap(); c.draw(try blank(), in: CGRect(x: 0, y: 0, width: 220, height: 160))
        c.setAlpha(mark.opacity); c.setStrokeColor(mark.color); c.setFillColor(mark.color)
        c.setLineWidth(max(1, mark.lineWidth)); c.setLineCap(.round); c.setLineJoin(.round)
        c.setLineDash(phase: 0, lengths: mark.strokeStyle.pattern(width: mark.lineWidth)); c.concatenate(mark.transform)
        let p = CGMutablePath(), first = try XCTUnwrap(mark.points.first)
        p.move(to: first); for point in mark.points.dropFirst() { p.addLine(to: point) }
        if mark.tool == .arrow, let last = mark.points.last {
            let a = atan2(last.y - first.y, last.x - first.x), l = max(12, mark.lineWidth * 4)
            p.move(to: last); p.addLine(to: CGPoint(x: last.x - l * cos(a - .pi / 6), y: last.y - l * sin(a - .pi / 6)))
            p.move(to: last); p.addLine(to: CGPoint(x: last.x - l * cos(a + .pi / 6), y: last.y - l * sin(a + .pi / 6)))
        }
        c.addPath(p); c.strokePath(); return try XCTUnwrap(c.makeImage())
    }
}
