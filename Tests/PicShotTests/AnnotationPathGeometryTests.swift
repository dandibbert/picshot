import XCTest
import AppKit
@testable import PicShot

final class AnnotationPathGeometryTests: XCTestCase {
    func testArcAndSectorShareEllipseAndOnlySectorHasInterior() {
        let arc = mark(.arc, start: 0, sweep: .pi / 2)
        let sector = mark(.sector, start: 0, sweep: .pi / 2)
        XCTAssertEqual(arc.arcStartPoint, CGPoint(x: 160, y: 90))
        XCTAssertEqual(arc.arcEndPoint.x, 100, accuracy: 0.0001)
        XCTAssertEqual(arc.arcEndPoint.y, 140, accuracy: 0.0001)
        XCTAssertTrue(arc.hitTest(CGPoint(x: 160, y: 90), tolerance: 1))
        XCTAssertFalse(arc.hitTest(CGPoint(x: 125, y: 110), tolerance: 1))
        XCTAssertFalse(arc.hitTest(CGPoint(x: 40, y: 90), tolerance: 1))
        XCTAssertTrue(sector.hitTest(CGPoint(x: 125, y: 110), tolerance: 1))
        XCTAssertFalse(sector.hitTest(CGPoint(x: 75, y: 110), tolerance: 1))
        XCTAssertFalse(arc.hasShapeFill); XCTAssertTrue(sector.hasShapeFill)
    }

    func testFullAndClockwiseSweepsAreFiniteAndBounded() {
        for sweep in [CGFloat.pi * 2, -.pi * 2] {
            let arc = mark(.arc, start: -.pi / 2, sweep: sweep)
            for point in [CGPoint(x: 160, y: 90), CGPoint(x: 100, y: 140), CGPoint(x: 40, y: 90), CGPoint(x: 100, y: 40)] {
                XCTAssertTrue(arc.hitTest(point, tolerance: 1), "Full turns include all cardinal points")
            }
        }
        let fullSector = mark(.sector, start: 0, sweep: .pi * 2)
        XCTAssertFalse(fullSector.outline.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(CGPoint(x: 125, y: 90)),
                       "A 360-degree sector has no radial seam through its filled interior")
        let clockwise = mark(.sector, start: 0, sweep: -.pi / 2)
        XCTAssertTrue(clockwise.hitTest(CGPoint(x: 125, y: 70), tolerance: 1))
        XCTAssertFalse(clockwise.hitTest(CGPoint(x: 125, y: 110), tolerance: 1))
        XCTAssertEqual(AnnotationArcGeometry.boundedSweep(0), .pi / 180, accuracy: 0.0001)
        XCTAssertEqual(AnnotationArcGeometry.boundedSweep(-100), -.pi * 2, accuracy: 0.0001)
        XCTAssertEqual(AnnotationArcGeometry.normalizedAngle(.infinity), 0)
        XCTAssertTrue(AnnotationArcGeometry.boundedSweep(.nan).isFinite)
        XCTAssertTrue(AnnotationArcGeometry.path(in: .zero, start: 0, sweep: .pi, sector: false).isEmpty)
    }

    func testRotatedArcHitTestAndAngleDragKeepOtherEndpointFixed() {
        var arc = mark(.arc, start: 0, sweep: .pi)
        arc.rotation = .pi / 3
        let oldStart = arc.arcStartPoint.applying(arc.transform)
        let oldEnd = arc.arcEndPoint.applying(arc.transform)
        XCTAssertTrue(arc.hitTest(oldStart, tolerance: 1))
        XCTAssertTrue(arc.bounds.contains(oldStart))
        XCTAssertFalse(arc.hitTest(CGPoint(x: 100, y: 90), tolerance: 1))
        let endTarget = AnnotationArcGeometry.point(in: arc.localBounds, angle: .pi / 2).applying(arc.transform)
        let movedEnd = arc.edited(handle: .arcEnd, from: oldEnd, to: endTarget, shift: false)
        assertPoint(movedEnd.arcStartPoint.applying(movedEnd.transform), oldStart)
        assertPoint(movedEnd.arcEndPoint.applying(movedEnd.transform), endTarget)
        XCTAssertEqual(movedEnd.effectiveArcSweep, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(movedEnd.rotation, arc.rotation)
        let startTarget = AnnotationArcGeometry.point(in: arc.localBounds, angle: .pi / 4).applying(arc.transform)
        let movedStart = arc.edited(handle: .arcStart, from: oldStart, to: startTarget, shift: true)
        assertPoint(movedStart.arcEndPoint.applying(movedStart.transform), oldEnd)
        assertPoint(movedStart.arcStartPoint.applying(movedStart.transform), startTarget)
        XCTAssertEqual(movedStart.effectiveArcSweep, .pi * 0.75, accuracy: 0.0001)
        XCTAssertEqual(arc.handle(at: oldStart, zoom: 1), .arcStart, "Angle handles precede coincident edge handles")
    }

    func testArcResizeKeepsRotatedAnchorAndAngles() {
        var arc = mark(.sector, start: .pi / 6, sweep: -.pi)
        arc.rotation = .pi / 5
        let anchor = arc.localBounds.origin.applying(arc.transform)
        let handle = CGPoint(x: arc.localBounds.maxX, y: arc.localBounds.maxY).applying(arc.transform)
        let resized = arc.edited(handle: .corner(2), from: handle,
            to: CGPoint(x: 210, y: 170).applying(arc.transform), shift: false)
        assertPoint(resized.localBounds.origin.applying(resized.transform), anchor)
        XCTAssertEqual(resized.effectiveArcStart, arc.effectiveArcStart)
        XCTAssertEqual(resized.effectiveArcSweep, arc.effectiveArcSweep)
        XCTAssertEqual(resized.localBounds.width, 170, accuracy: 0.001)
        XCTAssertEqual(resized.localBounds.height, 130, accuracy: 0.001)
    }

    func testPolylineHitsEachSegmentButNotItsBoundingBoxInterior() {
        var line = ImageAnnotation(tool: .polyline, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 140)], lineWidth: 2)
        XCTAssertTrue(line.hitTest(CGPoint(x: 65, y: 20), tolerance: 1))
        XCTAssertTrue(line.hitTest(CGPoint(x: 100, y: 90), tolerance: 1))
        XCTAssertFalse(line.hitTest(CGPoint(x: 40, y: 100), tolerance: 1))
        line.rotation = .pi / 4
        XCTAssertTrue(line.hitTest(CGPoint(x: 100, y: 90).applying(line.transform), tolerance: 1))
        XCTAssertFalse(line.hitTest(CGPoint(x: 40, y: 100).applying(line.transform), tolerance: 1))
        XCTAssertEqual(line.handle(at: line.points[1].applying(line.transform), zoom: 1), .vertex(1))
    }

    func testRotatedVertexMoveBakesTransformWithoutMovingOtherVertices() {
        var path = ImageAnnotation(tool: .polyline, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 40), CGPoint(x: 130, y: 110)])
        path.rotation = .pi / 3
        let oldPoints = path.points.map { $0.applying(path.transform) }
        let moved = path.edited(handle: .vertex(1), from: oldPoints[1], to: CGPoint(x: 150, y: 150), shift: false)
        XCTAssertEqual(moved.rotation, 0); XCTAssertEqual(moved.id, path.id)
        assertPoint(moved.points[0], oldPoints[0]); assertPoint(moved.points[2], oldPoints[2])
        XCTAssertEqual(moved.points[1], CGPoint(x: 150, y: 150))
        let snapped = path.edited(handle: .vertex(1), from: oldPoints[1], to: CGPoint(x: 150, y: 150), shift: true)
        let vector = CGPoint(x: snapped.points[1].x - oldPoints[0].x, y: snapped.points[1].y - oldPoints[0].y)
        let angleSteps = atan2(vector.y, vector.x) / (.pi / 4)
        XCTAssertEqual(angleSteps, angleSteps.rounded(), accuracy: 0.0001)
        XCTAssertEqual(path.edited(handle: .vertex(999), from: .zero, to: .zero, shift: false).points, path.points)
    }

    func testPolylineInputRenderingAndHandlesHaveBoundedFiniteGeometry() {
        var points = (0..<10_000).map { CGPoint(x: $0, y: $0 % 17) }
        points.insert(CGPoint(x: CGFloat.nan, y: 20), at: 0)
        let path = ImageAnnotation(tool: .polyline, points: points)
        XCTAssertEqual(path.boundedPathPoints.count, ImageAnnotation.maximumPolylinePoints)
        XCTAssertEqual(path.sanitizedPathGeometry.points.count, ImageAnnotation.maximumPolylinePoints)
        XCTAssertLessThanOrEqual(path.handles(zoom: 1).count, ImageAnnotation.maximumPolylinePoints + 9)
        XCTAssertEqual(path.localBounds.maxX, 255)
        XCTAssertEqual(path.strokePath.boundingBoxOfPath.maxX, 255)
        let flat = ImageAnnotation(tool: .polyline, points: [CGPoint(x: 10, y: 20), CGPoint(x: 60, y: 20)])
        XCTAssertEqual(flat.handles(zoom: 1).count, 3, "Collinear paths expose vertices and rotation, without singular box resizing")
    }

    func testArcSectorAndPolylineRasterPixelsAreDeterministicAndOpaqueRedactionSurvives() throws {
        let original = try whiteImage()
        var arc = mark(.arc, start: 0, sweep: .pi / 2)
        arc.fillEnabled = true; arc.fillColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let open = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [arc]))
        XCTAssertEqual(try pixel(open, x: 125, y: 110), [255, 255, 255, 255], "Arcs never acquire a radial fill")
        var sector = arc; sector.tool = .sector; sector.rotation = .pi / 2
        let filled = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [sector]))
        XCTAssertEqual(try pixel(filled, x: 80, y: 110), [0, 0, 255, 255])
        XCTAssertEqual(try pixel(filled, x: 125, y: 110), [255, 255, 255, 255])
        let path = ImageAnnotation(tool: .polyline, points: [CGPoint(x: 10, y: 15), CGPoint(x: 180, y: 15), CGPoint(x: 180, y: 160)], color: CGColor(gray: 0, alpha: 1), lineWidth: 6)
        var redaction = ImageAnnotation(tool: .redact, points: [CGPoint(x: 70, y: 100), CGPoint(x: 95, y: 125)], color: CGColor(gray: 0, alpha: 0.1))
        redaction.opacity = 0.1
        let marks = [sector, path, redaction]
        let result = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: marks))
        XCTAssertEqual(try pixel(result, x: 70, y: 15), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(result, x: 180, y: 100), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(result, x: 80, y: 110), [0, 0, 0, 255])
        let repeated = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: marks))
        XCTAssertEqual(try bytes(result), try bytes(repeated))
    }

    private func mark(_ tool: ImageEditorTool, start: CGFloat, sweep: CGFloat) -> ImageAnnotation {
        var result = ImageAnnotation(tool: tool, points: [CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 140)], color: CGColor(gray: 0, alpha: 1), lineWidth: 4)
        result.arcStartAngle = start; result.arcSweepAngle = sweep; return result
    }
    private func assertPoint(_ value: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value.x, expected.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(value.y, expected.y, accuracy: 0.0001, file: file, line: line)
    }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func whiteImage() throws -> CGImage {
        let context = try bitmap(width: 200, height: 180)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 180))
        return try XCTUnwrap(context.makeImage())
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try bitmap(width: 1, height: 1); context.translateBy(x: CGFloat(-x), y: CGFloat(-y))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }
    private func bytes(_ image: CGImage) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
}
