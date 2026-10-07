#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import PicShotCore

final class CaptureAspectRatioTests: XCTestCase {
    func testRatiosReduceSwapAndLabelWithoutChangingTheirValue() throws {
        let reduced = try CaptureAspectRatio(numerator: 1920, denominator: 1080)
        XCTAssertEqual(reduced.numerator, 16)
        XCTAssertEqual(reduced.denominator, 9)
        XCTAssertEqual(reduced.label, "16:9")
        XCTAssertEqual(reduced, try ratio(16, 9))
        XCTAssertEqual(reduced.swapped, try ratio(9, 16))
        XCTAssertEqual(reduced.swapped.swapped, reduced)
        XCTAssertEqual(try ratio(10_000, 10_000), try ratio(1, 1))
        XCTAssertEqual(try ratio(10_000, 1).numerator, 10_000)
        XCTAssertEqual(CaptureAspectRatio.presets.map(\.label), ["1:1", "4:3", "3:2", "16:9", "9:16"])
    }

    func testInvalidRatiosAreRejectedBeforeReductionOrArithmetic() {
        for value in [Int.min, -1, 0, 10_001, Int.max] {
            XCTAssertThrowsError(try ratio(value, 1)) {
                XCTAssertEqual($0 as? CaptureAspectRatioError, .invalidRatio)
            }
            XCTAssertThrowsError(try ratio(1, value))
            XCTAssertThrowsError(try ratio(value, value), "Invalid equal values must not reduce to 1:1")
        }
    }

    func testCanvasValidationMatchesSelectionLimits() throws {
        let invalid: [(CGSize, Int, Int)] = [
            (CGSize(width: CGFloat.nan, height: 100), 100, 100),
            (CGSize(width: 100, height: CGFloat.infinity), 100, 100),
            (CGSize(width: 0, height: 100), 100, 100),
            (CGSize(width: 32_769, height: 100), 100, 100),
            (CGSize(width: 100, height: 100), 0, 100),
            (CGSize(width: 100, height: 100), 100, Int.max),
            (CGSize(width: 100, height: 100), 32_769, 100),
            (CGSize(width: 100, height: 100), 8_001, 8_000)
        ]
        for (size, width, height) in invalid {
            XCTAssertThrowsError(try CaptureRatioGeometry(pointSize: size, pixelWidth: width, pixelHeight: height)) {
                XCTAssertEqual($0 as? CaptureSelectionError, .invalidCanvas)
            }
        }
        _ = try CaptureRatioGeometry(pointSize: CGSize(width: 8_000, height: 8_000), pixelWidth: 8_000, pixelHeight: 8_000)
    }

    func testEveryDragQuadrantHasExactSourceRatioAtEveryDensity() throws {
        let aspect = try ratio(16, 9)
        for geometry in try densities() {
            for directionX in [-1, 1] {
                for directionY in [-1, 1] {
                    let anchor = CGPoint(x: 200, y: 150)
                    let pointer = CGPoint(x: 200 + directionX * 64, y: 150 + directionY * 36)
                    let result = try geometry.drag(from: point(anchor, in: geometry),
                                                   to: point(pointer, in: geometry), ratio: aspect)
                    let pixels = try assertInvariant(result, in: geometry, ratio: aspect)
                    XCTAssertEqual(pixels, CGRect(x: directionX < 0 ? 136 : 200,
                                                  y: directionY < 0 ? 114 : 150, width: 64, height: 36))
                }
            }
        }
    }

    func testDragUsesSourcePixelRatioRatherThanPointRatio() throws {
        let geometry = try CaptureRatioGeometry(pointSize: CGSize(width: 100, height: 100), pixelWidth: 300, pixelHeight: 200)
        let aspect = try ratio(1, 1)
        let result = try geometry.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 20), ratio: aspect)
        XCTAssertEqual(try assertInvariant(result, in: geometry, ratio: aspect), CGRect(x: 30, y: 20, width: 30, height: 30))
        XCTAssertEqual(result.width, 10)
        XCTAssertEqual(result.height, 15)
    }

    func testDragSnapsAnchorAndRetainsSubpixelQuadrant() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(3, 2)
        let result = try geometry.drag(from: CGPoint(x: 20.2, y: 30.2), to: CGPoint(x: 20.1, y: 30.1), ratio: aspect)
        XCTAssertEqual(try assertInvariant(result, in: geometry, ratio: aspect), CGRect(x: 17, y: 28, width: 3, height: 2))
        let rounded = try geometry.drag(from: CGPoint(x: 20.7, y: 30.7), to: CGPoint(x: 30, y: 37), ratio: aspect)
        XCTAssertEqual(try geometry.sourcePixelRect(rounded).origin, CGPoint(x: 21, y: 31))
    }

    func testDragAtBoundsShrinksOnlyByWholeRatioMultiples() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(3, 2)
        let result = try geometry.drag(from: CGPoint(x: 93, y: 92), to: CGPoint(x: 200, y: 200), ratio: aspect)
        XCTAssertEqual(try assertInvariant(result, in: geometry, ratio: aspect), CGRect(x: 93, y: 92, width: 6, height: 4))
        XCTAssertThrowsError(try geometry.drag(from: CGPoint(x: 99, y: 99), to: CGPoint(x: 200, y: 200), ratio: aspect))
        let backwards = try geometry.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: -200, y: -200), ratio: aspect)
        XCTAssertEqual(try assertInvariant(backwards, in: geometry, ratio: aspect), CGRect(x: 1, y: 34, width: 99, height: 66))
    }

    func testAllEightResizeHandlesPreserveTheirAnchorsAtEveryDensity() throws {
        let aspect = try ratio(3, 2)
        let cases: [(CaptureRatioHandle, CGPoint, CGRect)] = [
            (.minXMinY, CGPoint(x: 50, y: 50), CGRect(x: 50, y: 50, width: 150, height: 100)),
            (.minY, CGPoint(x: 5, y: 50), CGRect(x: 65, y: 50, width: 150, height: 100)),
            (.maxXMinY, CGPoint(x: 230, y: 50), CGRect(x: 80, y: 50, width: 150, height: 100)),
            (.maxX, CGPoint(x: 230, y: 5), CGRect(x: 80, y: 60, width: 150, height: 100)),
            (.maxXMaxY, CGPoint(x: 230, y: 170), CGRect(x: 80, y: 70, width: 150, height: 100)),
            (.maxY, CGPoint(x: 5, y: 170), CGRect(x: 65, y: 70, width: 150, height: 100)),
            (.minXMaxY, CGPoint(x: 50, y: 170), CGRect(x: 50, y: 70, width: 150, height: 100)),
            (.minX, CGPoint(x: 50, y: 5), CGRect(x: 50, y: 60, width: 150, height: 100))
        ]
        XCTAssertEqual(cases.count, CaptureRatioHandle.allCases.count)
        for geometry in try densities() {
            let original = geometry.pointRect(CGRect(x: 80, y: 70, width: 120, height: 80))
            for (handle, pointer, expected) in cases {
                let result = try geometry.resize(original, handle: handle, to: point(pointer, in: geometry), ratio: aspect)
                XCTAssertEqual(try assertInvariant(result, in: geometry, ratio: aspect), expected, "Handle: \(handle)")
            }
        }
    }

    func testCrossingCornerAnchorKeepsOriginalQuadrantAndMinimum() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(3, 2)
        let original = CGRect(x: 20, y: 20, width: 30, height: 20)
        let result = try geometry.resize(original, handle: .minXMinY, to: CGPoint(x: 90, y: 90), ratio: aspect)
        XCTAssertEqual(try assertInvariant(result, in: geometry, ratio: aspect), CGRect(x: 47, y: 38, width: 3, height: 2))
        let side = try geometry.resize(original, handle: .minX, to: CGPoint(x: 90, y: 90), ratio: aspect)
        XCTAssertEqual(try assertInvariant(side, in: geometry, ratio: aspect), CGRect(x: 47, y: 29, width: 3, height: 2))
    }

    func testSideResizeRoundsPerpendicularCenterByAtMostHalfPixel() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(1, 1)
        let original = CGRect(x: 10, y: 10, width: 21, height: 21)
        for handle in [CaptureRatioHandle.maxX, .maxY] {
            let result = try geometry.resize(original, handle: handle, to: CGPoint(x: 20, y: 20), ratio: aspect)
            let pixels = try assertInvariant(result, in: geometry, ratio: aspect)
            if handle == .maxX {
                XCTAssertEqual(pixels.minX, original.minX)
                XCTAssertEqual(abs(pixels.midY - original.midY), 0.5)
            } else {
                XCTAssertEqual(pixels.minY, original.minY)
                XCTAssertEqual(abs(pixels.midX - original.midX), 0.5)
            }
        }
    }

    func testSideResizeShiftsPerpendicularCenterWhenBoundsRequireIt() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(1, 1)
        let horizontal = try geometry.resize(CGRect(x: 70, y: 80, width: 20, height: 20), handle: .maxX,
                                             to: CGPoint(x: 100, y: 0), ratio: aspect)
        XCTAssertEqual(try assertInvariant(horizontal, in: geometry, ratio: aspect), CGRect(x: 70, y: 70, width: 30, height: 30))
        let vertical = try geometry.resize(CGRect(x: 80, y: 70, width: 20, height: 20), handle: .minY,
                                           to: CGPoint(x: 0, y: 0), ratio: aspect)
        XCTAssertEqual(try assertInvariant(vertical, in: geometry, ratio: aspect), CGRect(x: 10, y: 0, width: 90, height: 90))
    }

    func testNumericEditsSnapNearestAndOnlyMoveOriginAtBounds() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(16, 9)
        let original = CGRect(x: 80, y: 80, width: 16, height: 9)
        for (pixels, axis) in [(31, CaptureRatioAxis.width), (24, .width), (17, .height)] {
            let result = try geometry.sized(original, pixels: pixels, axis: axis, ratio: aspect)
            XCTAssertEqual(try assertInvariant(result, in: geometry, ratio: aspect), CGRect(x: 68, y: 80, width: 32, height: 18))
        }
        let smaller = try geometry.sized(original, pixels: 23, axis: .width, ratio: aspect)
        XCTAssertEqual(smaller, original)
        let edge = try geometry.sized(original, pixels: 100, axis: .width, ratio: aspect)
        XCTAssertEqual(try assertInvariant(edge, in: geometry, ratio: aspect), CGRect(x: 4, y: 46, width: 96, height: 54))
    }

    func testNumericEditsRejectTinyImpossibleAndOverflowingRequests() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(16, 9)
        let original = CGRect(x: 10, y: 10, width: 16, height: 9)
        for pixels in [Int.min, -1, 0, 1, 7, 101, Int.max] {
            XCTAssertThrowsError(try geometry.sized(original, pixels: pixels, axis: .width, ratio: aspect))
        }
        XCTAssertThrowsError(try geometry.sized(original, pixels: 100, axis: .height, ratio: aspect),
                             "A fitting requested axis must not silently shrink an impossible derived axis")
        let retina = try CaptureRatioGeometry(pointSize: CGSize(width: 100, height: 100), pixelWidth: 200, pixelHeight: 200)
        XCTAssertThrowsError(try retina.sized(original, pixels: 3, axis: .width, ratio: ratio(1, 1)))
        let roundedTooLarge = try ratio(6, 5)
        XCTAssertThrowsError(try geometry.sized(original, pixels: 100, axis: .width, ratio: roundedTooLarge),
                             "The nearest multiple is 102 × 85 and cannot be clipped or silently rounded down")
    }

    func testNumericEditsAndFittingStayInSourcePixelsAtEveryDensity() throws {
        let aspect = try ratio(16, 9)
        for geometry in try densities() {
            let original = geometry.pointRect(CGRect(x: 200, y: 150, width: 64, height: 36))
            for (pixels, axis) in [(127, CaptureRatioAxis.width), (71, .height)] {
                let result = try geometry.sized(original, pixels: pixels, axis: axis, ratio: aspect)
                XCTAssertEqual(try assertInvariant(result, in: geometry, ratio: aspect),
                               CGRect(x: 200, y: 150, width: 128, height: 72))
            }
            XCTAssertEqual(try geometry.fitting(original, ratio: aspect), original)
        }
    }

    func testFittingUsesNearestWidthPreservesOriginAndShrinksToFit() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(16, 9)
        let fit = try geometry.fitting(CGRect(x: 10, y: 11, width: 33, height: 70), ratio: aspect)
        XCTAssertEqual(try assertInvariant(fit, in: geometry, ratio: aspect), CGRect(x: 10, y: 11, width: 32, height: 18))
        let portrait = try geometry.fitting(CGRect(x: 10, y: 11, width: 90, height: 70), ratio: aspect.swapped)
        XCTAssertEqual(try assertInvariant(portrait, in: geometry, ratio: aspect.swapped), CGRect(x: 10, y: 4, width: 54, height: 96))
        let original = CGRect(x: 10, y: 11, width: 32, height: 18)
        XCTAssertEqual(try geometry.fitting(original, ratio: aspect), original)
    }

    func testMinimumIsTwoPointsOnBothIndependentAxes() throws {
        let geometry = try CaptureRatioGeometry(pointSize: CGSize(width: 100, height: 100), pixelWidth: 300, pixelHeight: 125)
        let aspect = try ratio(3, 2)
        let result = try geometry.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.1, y: 10.1), ratio: aspect)
        XCTAssertEqual(try assertInvariant(result, in: geometry, ratio: aspect).size, CGSize(width: 6, height: 4))
        XCTAssertEqual(result.width, 2)
        XCTAssertGreaterThan(result.height, 2)
        let tinyCanvas = try CaptureRatioGeometry(pointSize: CGSize(width: 1, height: 100), pixelWidth: 100, pixelHeight: 100)
        XCTAssertThrowsError(try tinyCanvas.drag(from: .zero, to: CGPoint(x: 1, y: 100), ratio: aspect))
    }

    func testExtremeValidRatiosMustStillFitMinimumAndCanvas() throws {
        let geometry = try CaptureRatioGeometry(pointSize: CGSize(width: 32_000, height: 2_000), pixelWidth: 32_000, pixelHeight: 2_000)
        let aspect = try ratio(10_000, 1)
        let fit = try geometry.fitting(CGRect(x: 10, y: 10, width: 100, height: 100), ratio: aspect)
        XCTAssertEqual(try assertInvariant(fit, in: geometry, ratio: aspect), CGRect(x: 10, y: 10, width: 20_000, height: 2))
        XCTAssertThrowsError(try geometry.fitting(CGRect(x: 0, y: 0, width: 100, height: 100), ratio: ratio(10_000, 9_999)))
    }

    func testSourceLimitGeometryAndOutputPreflightNeedNoRaster() throws {
        let geometry = try CaptureRatioGeometry(pointSize: CGSize(width: 8_000, height: 8_000), pixelWidth: 8_000, pixelHeight: 8_000)
        let aspect = try ratio(1, 1)
        // A valid 64-million-pixel source is only scalar metadata in this type.
        let fit = try geometry.fitting(CGRect(x: 0, y: 0, width: 8_000, height: 8_000), ratio: aspect)
        let pixels = try assertInvariant(fit, in: geometry, ratio: aspect)
        XCTAssertEqual(pixels.size, CGSize(width: 5_656, height: 5_656))
        XCTAssertFalse(CaptureSelectionGeometry.allowsOutputSize(width: 5_657, height: 5_657))
        XCTAssertThrowsError(try geometry.sized(fit, pixels: 5_657, axis: .width, ratio: aspect)) {
            XCTAssertEqual($0 as? CaptureSelectionError, .pixelLimit)
        }
        for handle in CaptureRatioHandle.allCases {
            let resized = try geometry.resize(fit, handle: handle, to: CGPoint(x: 8_000, y: 8_000), ratio: aspect)
            _ = try assertInvariant(resized, in: geometry, ratio: aspect)
        }
        let drag = try geometry.drag(from: .zero, to: CGPoint(x: 8_000, y: 8_000), ratio: aspect)
        XCTAssertEqual(drag, fit)
    }

    func testPixelEdgeRoundTripIsStableAtFractionalIndependentDensities() throws {
        let geometry = try CaptureRatioGeometry(pointSize: CGSize(width: 1_000, height: 700), pixelWidth: 1_397, pixelHeight: 911)
        XCTAssertEqual(geometry.pixelsPerPointX, 1.397, accuracy: 1e-12)
        XCTAssertEqual(geometry.pixelsPerPointY, 911.0 / 700, accuracy: 1e-12)
        for x in [0, 1, 13, 317, 1_360] {
            for y in [0, 1, 17, 619, 886] {
                let pixels = CGRect(x: x, y: y, width: 37, height: 25)
                XCTAssertEqual(try geometry.sourcePixelRect(geometry.pointRect(pixels)), pixels)
            }
        }
        let outside = CGRect(x: -10, y: -10, width: 1_020, height: 720)
        XCTAssertEqual(try geometry.sourcePixelRect(outside), CGRect(x: 0, y: 0, width: 1_397, height: 911))
    }

    func testNonfiniteAndHugeCoordinatesFailBeforeConversion() throws {
        let geometry = try makeGeometry()
        let aspect = try ratio(4, 3)
        let original = CGRect(x: 10, y: 10, width: 40, height: 30)
        for value in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity, CGFloat.greatestFiniteMagnitude, -1e100, 1e10] {
            let invalidPoint = CGPoint(x: value, y: 5)
            XCTAssertThrowsError(try geometry.drag(from: invalidPoint, to: .zero, ratio: aspect))
            XCTAssertThrowsError(try geometry.drag(from: .zero, to: invalidPoint, ratio: aspect))
            XCTAssertThrowsError(try geometry.resize(original, handle: .maxX, to: invalidPoint, ratio: aspect))
            for invalidRect in [CGRect(x: value, y: 0, width: 40, height: 30),
                                CGRect(x: 0, y: 0, width: 40, height: value)] {
                XCTAssertThrowsError(try geometry.sourcePixelRect(invalidRect))
                XCTAssertThrowsError(try geometry.fitting(invalidRect, ratio: aspect))
                XCTAssertThrowsError(try geometry.sized(invalidRect, pixels: 40, axis: .width, ratio: aspect))
                XCTAssertTrue(geometry.pointRect(invalidRect).isNull)
            }
        }
    }

    func testRectanglePrecisionReplacementPreservesBooleanOrderAndRejectsMalformedBounds() throws {
        var selection = try CaptureSelectionGeometry(pointSize: CGSize(width: 100, height: 80), pixelWidth: 150, pixelHeight: 200)
        try selection.append(.rectangle(CGRect(x: 10, y: 10, width: 30, height: 30)))
        try selection.append(.rectangle(CGRect(x: 15, y: 15, width: 8, height: 8)), subtracts: true)
        let first = selection.operations[0]
        let exact = CGRect(x: 21, y: 37, width: 16, height: 9)
        try selection.setRectanglePixelBounds(at: 1, bounds: exact)
        XCTAssertEqual(selection.operations[0], first)
        XCTAssertTrue(selection.operations[1].subtracts)
        XCTAssertEqual(selection.rectanglePixelBounds(selection.operations[1].shape.bounds), exact)
        let operations = selection.operations
        for invalid in [CGRect(x: 0.1, y: 0, width: 16, height: 9), CGRect(x: -1, y: 0, width: 16, height: 9),
                        CGRect(x: 149, y: 0, width: 16, height: 9), CGRect(x: 0, y: 0, width: 2, height: 9),
                        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 9)] {
            XCTAssertThrowsError(try selection.setRectanglePixelBounds(at: 1, bounds: invalid))
            XCTAssertEqual(selection.operations, operations)
        }
        selection.cancel()
        XCTAssertThrowsError(try selection.setRectanglePixelBounds(at: 1, bounds: exact)) {
            XCTAssertEqual($0 as? CaptureSelectionError, .cancelled)
        }
    }

    func testExactMaximumOutputRectangleDoesNotGainAnEpsilonColumnDuringMultiRegionPreflight() throws {
        var selection = try CaptureSelectionGeometry(pointSize: CGSize(width: 7700, height: 6393), pixelWidth: 10010, pixelHeight: 6393)
        let ratioGeometry = try CaptureRatioGeometry(pointSize: selection.pointSize, pixelWidth: selection.pixelWidth, pixelHeight: selection.pixelHeight)
        let exact = CGRect(x: 51, y: 0, width: 8000, height: 4000)
        try selection.append(.rectangle(ratioGeometry.pointRect(exact)))
        // Metadata-only preflight. Do not allocate a 32M coverage mask in this test.
        XCTAssertEqual(try selection.enclosingPixelBounds(), exact)
        XCTAssertEqual(selection.rectanglePixelBounds(selection.operations[0].shape.bounds), exact)
    }

    @discardableResult
    private func assertInvariant(_ rectangle: CGRect, in geometry: CaptureRatioGeometry, ratio: CaptureAspectRatio,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let pixels = try geometry.sourcePixelRect(rectangle)
        for edge in [pixels.minX, pixels.minY, pixels.maxX, pixels.maxY] {
            XCTAssertEqual(edge, edge.rounded(), file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(rectangle.width, 2 - 1e-9, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rectangle.height, 2 - 1e-9, file: file, line: line)
        XCTAssertGreaterThanOrEqual(pixels.minX, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(pixels.minY, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(pixels.maxX, CGFloat(geometry.pixelWidth), file: file, line: line)
        XCTAssertLessThanOrEqual(pixels.maxY, CGFloat(geometry.pixelHeight), file: file, line: line)
        XCTAssertEqual(Int(pixels.width) % ratio.numerator, 0, file: file, line: line)
        XCTAssertEqual(Int(pixels.height) % ratio.denominator, 0, file: file, line: line)
        XCTAssertEqual(Int(pixels.width) / ratio.numerator, Int(pixels.height) / ratio.denominator, file: file, line: line)
        XCTAssertTrue(CaptureSelectionGeometry.allowsOutputSize(width: Int(pixels.width), height: Int(pixels.height)), file: file, line: line)
        var selection = try CaptureSelectionGeometry(pointSize: geometry.pointSize,
                                                      pixelWidth: geometry.pixelWidth, pixelHeight: geometry.pixelHeight)
        try selection.append(.rectangle(rectangle))
        XCTAssertEqual(selection.rectanglePixelBounds(rectangle), pixels, file: file, line: line)
        return pixels
    }

    private func point(_ pixels: CGPoint, in geometry: CaptureRatioGeometry) -> CGPoint {
        CGPoint(x: pixels.x / geometry.pixelsPerPointX, y: pixels.y / geometry.pixelsPerPointY)
    }

    private func makeGeometry() throws -> CaptureRatioGeometry {
        try CaptureRatioGeometry(pointSize: CGSize(width: 100, height: 100), pixelWidth: 100, pixelHeight: 100)
    }

    private func densities() throws -> [CaptureRatioGeometry] {
        try [(400, 300), (800, 600), (500, 375), (1_200, 600)].map {
            try CaptureRatioGeometry(pointSize: CGSize(width: 400, height: 300), pixelWidth: $0.0, pixelHeight: $0.1)
        }
    }

    private func ratio(_ numerator: Int, _ denominator: Int) throws -> CaptureAspectRatio {
        try CaptureAspectRatio(numerator: numerator, denominator: denominator)
    }
}
