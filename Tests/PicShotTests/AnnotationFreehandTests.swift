import XCTest
import AppKit
import ImageIO
@testable import PicShot

final class AnnotationFreehandTests: XCTestCase {
    private let yellow = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
    private let extent = CGRect(x: 0, y: 0, width: 320, height: 240)

    func testLegacyDefaultsRetainPolylinePencilAndTranslucentRectangle() throws {
        let pencil = ImageAnnotation(tool: .freehand, points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30), CGPoint(x: 70, y: 10)])
        XCTAssertFalse(pencil.freehandSmoothing)
        var types: [CGPathElementType] = []; pencil.strokePath.applyWithBlock { types.append($0.pointee.type) }
        XCTAssertEqual(types, [.moveToPoint, .addLineToPoint, .addLineToPoint])
        let marker = ImageAnnotation(tool: .highlighter, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 90)], color: yellow)
        XCTAssertEqual(marker.highlighterMode, .rectangle); XCTAssertEqual(marker.highlighterBlend, .translucent)
        let result = try render(try base(), [marker])
        assertPixel(try pixel(result, x: 50, y: 50), near: [255, 255, 173, 255])
    }

    func testSmoothingOffAndRectangularHighlightMatchLegacyRendererExactly() throws {
        let image = try base(color: CGColor(srgbRed: 0.23, green: 0.44, blue: 0.72, alpha: 1))
        for dash in AnnotationStrokeStyle.allCases {
            var pencil = ImageAnnotation(tool: .freehand, points: [CGPoint(x: 20, y: 30), CGPoint(x: 45, y: 80), CGPoint(x: 80, y: 20), CGPoint(x: 130, y: 70)], lineWidth: 6)
            pencil.strokeStyle = dash; pencil.opacity = 0.67; pencil.rotation = 0.13
            let marker = ImageAnnotation(tool: .highlighter, points: [CGPoint(x: 60, y: 25), CGPoint(x: 110, y: 100)], color: yellow)
            let marks = [pencil, marker]
            XCTAssertEqual(try bytes(render(image, marks)), try bytes(XCTUnwrap(AutomaticMosaicLegacyRenderer.render(image: image, annotations: marks))))
        }
    }

    func testSmoothingIsReversibleBoundedAndHasExactEndpoints() throws {
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 45, y: 80), CGPoint(x: 80, y: 20), CGPoint(x: 130, y: 70)]
        var mark = ImageAnnotation(tool: .freehand, points: points, color: CGColor(gray: 0, alpha: 1), lineWidth: 8)
        mark.freehandSmoothing = true
        XCTAssertEqual(mark.strokePath.currentPoint, points.last)
        XCTAssertTrue(mark.localBounds.contains(mark.strokePath.boundingBoxOfPath))
        var types: [CGPathElementType] = []; mark.strokePath.applyWithBlock { types.append($0.pointee.type) }
        XCTAssertEqual(types.filter { $0 == .addQuadCurveToPoint }.count, 2)
        var reversed = mark; reversed.points.reverse()
        let original = try base()
        // Rasterizers may round equivalent reversed Beziers one coverage level apart.
        let a = try bytes(render(original, [mark])), b = try bytes(render(original, [reversed]))
        XCTAssertEqual(a.count, b.count)
        XCTAssertLessThanOrEqual(zip(a, b).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0, 2)
        var raw = mark; raw.freehandSmoothing = false
        XCTAssertNotEqual(a, try bytes(render(original, [raw])))
    }

    func testEveryConstraintClipsAlongTheSnappedRay() {
        let anchor = CGPoint(x: 290, y: 210)
        for mode in AnnotationPencilConstraint.allCases {
            let requested = CGPoint(x: 350, y: 260)
            let result = AnnotationFreehandGeometry.constrained(requested, from: anchor, mode: mode, extent: extent)
            XCTAssertGreaterThanOrEqual(result.x, extent.minX); XCTAssertLessThanOrEqual(result.x, extent.maxX + 0.0001)
            XCTAssertGreaterThanOrEqual(result.y, extent.minY); XCTAssertLessThanOrEqual(result.y, extent.maxY + 0.0001)
            if mode != .free {
                let angle = atan2(result.y - anchor.y, result.x - anchor.x) * 180 / .pi
                XCTAssertEqual(angle / CGFloat(mode.rawValue), (angle / CGFloat(mode.rawValue)).rounded(), accuracy: 0.0001)
            }
        }
        XCTAssertEqual(AnnotationFreehandGeometry.constrained(anchor, from: anchor, mode: .degrees5, extent: extent), anchor)
    }

    func testShiftHasOneLiveEndpointAndSmoothingKeepsConstrainedSectionStraight() {
        var gesture = AnnotationFreehandGesture(point: CGPoint(x: 10, y: 20), shift: false)
        gesture.sample(CGPoint(x: 40, y: 50), shift: false, constraint: .degrees45, extent: extent, minimumDistance: 0.1)
        gesture.setShift(true)
        for x in 50...100 {
            gesture.sample(CGPoint(x: x, y: 57), shift: true, constraint: .degrees45, extent: extent, minimumDistance: 0.1)
        }
        XCTAssertEqual(gesture.points.count, 3)
        XCTAssertEqual(gesture.points[2].y, 50, accuracy: 0.0001)
        let endpoint = gesture.points[2]
        gesture.setShift(false)
        gesture.sample(CGPoint(x: 130, y: 90), shift: false, constraint: .degrees45, extent: extent, minimumDistance: 0.1)
        XCTAssertEqual(gesture.points[2], endpoint)
        let path = AnnotationFreehandGeometry.path(points: gesture.points, smoothing: true, corners: gesture.corners)
        var types: [CGPathElementType] = []; path.applyWithBlock { types.append($0.pointee.type) }
        XCTAssertFalse(types.contains(.addQuadCurveToPoint), "Straight boundaries must not be smoothed into curves")
    }

    func testGestureAndMalformedInputHaveFinitePointCornerAndWidthBudgets() {
        let start = CGPoint(x: 10, y: 10), end = CGPoint(x: 280, y: 200)
        var gesture = AnnotationFreehandGesture(point: start, shift: false)
        for index in 0..<(ImageAnnotation.maximumGesturePoints * 5) {
            let point = CGPoint(x: index.isMultiple(of: 2) ? 30 : 90, y: index.isMultiple(of: 3) ? 20 : 100)
            gesture.sample(point, shift: index.isMultiple(of: 4), constraint: .degrees15, extent: extent, minimumDistance: 0.1)
            XCTAssertLessThanOrEqual(gesture.points.count, ImageAnnotation.maximumGesturePoints)
            XCTAssertLessThanOrEqual(gesture.corners.count, ImageAnnotation.maximumGesturePoints)
        }
        gesture.sample(end, shift: false, constraint: .free, extent: extent, minimumDistance: 0.1, final: true)
        XCTAssertTrue(gesture.wasSimplified); XCTAssertEqual(gesture.points.first, start); XCTAssertEqual(gesture.points.last, end)
        var mark = ImageAnnotation(tool: .freehand, points: [CGPoint(x: CGFloat.nan, y: 0)] + Array(repeating: start, count: 5_000), lineWidth: .infinity)
        mark.freehandCorners = Array(0..<5_000)
        mark = mark.sanitizedPathGeometry
        XCTAssertLessThanOrEqual(mark.points.count, ImageAnnotation.maximumGesturePoints)
        XCTAssertTrue(mark.points.allSatisfy(AnnotationFreehandGeometry.bounded))
        XCTAssertLessThanOrEqual(mark.freehandCorners.count, mark.points.count)
        XCTAssertTrue(mark.freehandWasSimplified); XCTAssertEqual(mark.lineWidth, 4)
    }

    func testHighlighterBlendsRespectTextAndSingleStrokeCrossings() throws {
        let white = try base(), black = try base(color: CGColor(gray: 0, alpha: 1))
        var mark = ImageAnnotation(tool: .highlighter, points: [CGPoint(x: 20, y: 60), CGPoint(x: 120, y: 60), CGPoint(x: 20, y: 60)], color: yellow, lineWidth: 20)
        mark.highlighterMode = .freehand; mark.highlighterBlend = .multiply
        assertPixel(try pixel(render(white, [mark]), x: 70, y: 60), near: [255, 255, 173, 255])
        XCTAssertEqual(try pixel(render(black, [mark]), x: 70, y: 60), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(render(white, [mark]), x: 70, y: 90), [255, 255, 255, 255])
        mark.highlighterBlend = .translucent
        assertPixel(try pixel(render(black, [mark]), x: 70, y: 60), near: [82, 82, 0, 255])
        mark.opacity = 0.5
        assertPixel(try pixel(render(black, [mark]), x: 70, y: 60), near: [41, 41, 0, 255])
    }

    func testSmoothedReversalRetainsAnalyticTurnAcrossAxesAndDirections() throws {
        let vectors = [CGPoint(x: 160, y: 0), CGPoint(x: 0, y: 160), CGPoint(x: 120, y: 120), CGPoint(x: -120, y: 0)]
        for vector in vectors {
            let start = CGPoint(x: 140, y: 40)
            let end = CGPoint(x: start.x + vector.x, y: start.y + vector.y)
            var mark = ImageAnnotation(tool: .highlighter, points: [start, end, start], color: yellow, lineWidth: 12)
            mark.highlighterMode = .freehand; mark.freehandSmoothing = true
            let turn = CGPoint(x: start.x + vector.x * 0.75, y: start.y + vector.y * 0.75)
            let beyondMidpoint = CGPoint(x: start.x + vector.x * 0.625, y: start.y + vector.y * 0.625)
            XCTAssertEqual(mark.freehandPath.currentPoint, start)
            XCTAssertTrue(mark.freehandInkPath().contains(turn), "The returning smoothed segment must retain its analytic extremum")
            XCTAssertTrue(mark.hitTest(beyondMidpoint, tolerance: 0), "Visible returning ink must remain selectable")
            let rendered = try render(base(), [mark])
            XCTAssertNotEqual(try pixel(rendered, x: Int(beyondMidpoint.x), y: Int(beyondMidpoint.y)), [255, 255, 255, 255])
            var reverse = mark; reverse.points.reverse()
            XCTAssertEqual(try bytes(rendered), try bytes(render(base(), [reverse])))
        }
    }

    func testSmoothedReversalDarkPixelsBlendOnceAndPreserveOutside() throws {
        let black = try base(color: CGColor(gray: 0, alpha: 1))
        var mark = ImageAnnotation(tool: .highlighter,
            points: [CGPoint(x: 20, y: 60), CGPoint(x: 120, y: 60), CGPoint(x: 20, y: 60)], color: yellow, lineWidth: 20)
        mark.highlighterMode = .freehand; mark.freehandSmoothing = true
        mark.highlighterBlend = .multiply
        let multiply = try render(black, [mark])
        mark.highlighterBlend = .translucent
        let normal = try render(black, [mark])
        // x=85 lies beyond the curve's coincident endpoints (x=70), before its
        // analytic turn at x=95. Formerly the stroked outline omitted this ink.
        XCTAssertEqual(try pixel(multiply, x: 85, y: 60), [0, 0, 0, 255])
        assertPixel(try pixel(normal, x: 85, y: 60), near: [82, 82, 0, 255])
        assertPixel(try pixel(normal, x: 50, y: 60), near: [82, 82, 0, 255])
        XCTAssertEqual(try pixel(normal, x: 85, y: 90), [0, 0, 0, 255])
        XCTAssertNotEqual(try bytes(multiply), try bytes(normal))
        mark.opacity = 0.5
        assertPixel(try pixel(render(black, [mark]), x: 85, y: 60), near: [41, 41, 0, 255])
    }

    func testUnequalCollinearReturnUsesQuadraticExtremumAndNotControlPoint() throws {
        var mark = ImageAnnotation(tool: .freehand,
            points: [CGPoint(x: 20, y: 60), CGPoint(x: 120, y: 60), CGPoint(x: 40, y: 60)], lineWidth: 4)
        mark.freehandSmoothing = true
        // Quadratic from 70 via 120 to 80 has derivative zero at t=5/9.
        XCTAssertEqual(mark.freehandPath.boundingBoxOfPath.maxX, 880.0 / 9.0, accuracy: 0.000001)
        XCTAssertEqual(mark.freehandPath.currentPoint, CGPoint(x: 40, y: 60))
        XCTAssertTrue(mark.hitTest(CGPoint(x: 95, y: 60), tolerance: 0))
        XCTAssertFalse(mark.hitTest(CGPoint(x: 120, y: 60), tolerance: 0))
        let image = try render(base(), [mark])
        var reversed = mark; reversed.points.reverse()
        let a = try bytes(image), b = try bytes(render(base(), [reversed]))
        XCTAssertLessThanOrEqual(zip(a, b).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0, 2)
    }

    func testSinglePointTinyMarksAndFreehandHitTestingUseVisibleInk() throws {
        for tool in [ImageEditorTool.freehand, .highlighter] {
            var dot = ImageAnnotation(tool: tool, points: [CGPoint(x: 50, y: 50)], color: yellow, lineWidth: 12)
            dot.highlighterMode = .freehand; dot.freehandSmoothing = true
            let white = try base()
            XCTAssertNotEqual(try pixel(render(white, [dot]), x: 50, y: 50), try pixel(white, x: 50, y: 50))
            XCTAssertTrue(dot.hitTest(CGPoint(x: 54, y: 50), tolerance: 0))
            XCTAssertFalse(dot.hitTest(CGPoint(x: 65, y: 50), tolerance: 0))
            dot.points.append(CGPoint(x: 50.2, y: 50.1))
            XCTAssertNotEqual(try bytes(render(white, [dot])), try bytes(white))
            dot.points = [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100), CGPoint(x: 180, y: 20)]
            XCTAssertFalse(dot.hitTest(CGPoint(x: 100, y: 25), tolerance: 0), "A stroke's bounding rectangle must not be selectable as ink")
        }
    }

    func testRedactionOrderNeverRevealsCoveredSourceAndEraserRemainsSequential() throws {
        let white = try base(), red = try base(color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        var cover = ImageAnnotation(tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 160, y: 100)], color: CGColor(gray: 0, alpha: 0.1))
        cover.opacity = 0.01
        var highlight = ImageAnnotation(tool: .highlighter, points: [CGPoint(x: 20, y: 60), CGPoint(x: 160, y: 60)], color: yellow, lineWidth: 20)
        highlight.highlighterMode = .freehand
        for blend in AnnotationHighlighterBlend.allCases {
            highlight.highlighterBlend = blend
            XCTAssertEqual(try pixel(render(white, [cover, highlight]), x: 80, y: 60), try pixel(render(red, [cover, highlight]), x: 80, y: 60))
            XCTAssertEqual(try pixel(render(red, [highlight, cover]), x: 80, y: 60), [0, 0, 0, 255])
        }
        let erase = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 80, y: 30), CGPoint(x: 80, y: 90)], lineWidth: 20)
        XCTAssertEqual(try pixel(render(white, [highlight, erase]), x: 80, y: 60), [255, 255, 255, 255])
        XCTAssertNotEqual(try pixel(render(white, [erase, highlight]), x: 80, y: 60), [255, 255, 255, 255])
    }

    func testExportPNGExactlyMatchesSharedRendererAndDirectComposition() throws {
        let original = try base()
        var pencil = ImageAnnotation(tool: .freehand, points: [CGPoint(x: 20, y: 40), CGPoint(x: 90, y: 150), CGPoint(x: 170, y: 80)], lineWidth: 8)
        pencil.freehandSmoothing = true
        var marker = pencil; marker.tool = .highlighter; marker.color = yellow; marker.lineWidth = 24
        marker.highlighterMode = .freehand; marker.highlighterBlend = .multiply; marker.rotation = 0.2
        let marks = [pencil, marker], rendered = try render(original, [pencil, marker])
        let direct = try context(width: 320, height: 240); direct.draw(original, in: extent)
        XCTAssertTrue(ImageEditorRenderer.drawAnnotations(marks, in: direct, extent: extent, baseImage: original))
        XCTAssertEqual(try bytes(rendered), try bytes(XCTUnwrap(direct.makeImage())))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-freehand-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try rendered.writePNG(to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(try bytes(decoded), try bytes(rendered))
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func base(color: CGColor = CGColor(gray: 1, alpha: 1)) throws -> CGImage {
        let result = try context(width: 320, height: 240); result.setFillColor(color); result.fill(extent)
        return try XCTUnwrap(result.makeImage())
    }
    private func render(_ image: CGImage, _ marks: [ImageAnnotation]) throws -> CGImage { try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: marks)) }
    private func bytes(_ image: CGImage) throws -> Data {
        let result = try context(width: image.width, height: image.height)
        result.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(result.data), count: result.bytesPerRow * result.height)
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let result = try context(width: 1, height: 1); result.translateBy(x: CGFloat(-x), y: CGFloat(-y))
        result.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(result.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }
    private func assertPixel(_ actual: [UInt8], near expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) { XCTAssertLessThanOrEqual(abs(Int(a) - b), 2, file: file, line: line) }
    }
}
