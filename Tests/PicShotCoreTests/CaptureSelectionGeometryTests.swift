import XCTest
@testable import PicShotCore

final class CaptureSelectionGeometryTests: XCTestCase {
    func testRetinaUsesIndependentXYScalesAndTopLeftOrigin() throws {
        var geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 100, height: 80), pixelWidth: 300, pixelHeight: 160)
        try geometry.append(.rectangle(CGRect(x: 7, y: 11, width: 9, height: 5)))
        let mask = try geometry.rasterized()
        XCTAssertEqual(mask.pixelBounds, CGRect(x: 21, y: 22, width: 27, height: 10))
        XCTAssertEqual(mask.selectedPixelCount, 270)
        XCTAssertTrue(mask.alpha.allSatisfy { $0 == 255 })
    }

    func testFractionalBoundsAreTrimmedToPixelCenterCoverage() throws {
        var geometry = try makeGeometry(size: 10, scale: 2)
        try geometry.append(.rectangle(CGRect(x: 1.4, y: 2.4, width: 2.2, height: 2.2)))
        XCTAssertEqual(try geometry.enclosingPixelBounds(), CGRect(x: 2, y: 4, width: 6, height: 6))
        let mask = try geometry.rasterized()
        XCTAssertEqual(mask.pixelBounds, CGRect(x: 3, y: 5, width: 4, height: 4))
        XCTAssertEqual(mask.selectedPixelCount, 16)
    }

    func testNegativeOriginClipsToDisplayWithoutShiftingY() throws {
        var geometry = try makeGeometry(size: 30, scale: 2)
        try geometry.append(.rectangle(CGRect(x: -8, y: 12, width: 12, height: 9)))
        XCTAssertEqual(try geometry.rasterized().pixelBounds, CGRect(x: 0, y: 24, width: 8, height: 18))
    }

    func testSeparatedRegionsLeaveTransparentGap() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.rectangle(CGRect(x: 2, y: 3, width: 4, height: 5)))
        try geometry.append(.rectangle(CGRect(x: 12, y: 9, width: 3, height: 4)))
        let mask = try geometry.rasterized()
        XCTAssertEqual(mask.pixelBounds, CGRect(x: 2, y: 3, width: 13, height: 10))
        XCTAssertEqual(mask.selectedPixelCount, 32)
        XCTAssertEqual(alpha(mask, x: 3, y: 4), 255)
        XCTAssertEqual(alpha(mask, x: 13, y: 11), 255)
        XCTAssertEqual(alpha(mask, x: 9, y: 6), 0)
        XCTAssertEqual(alpha(mask, x: 3, y: 11), 0)
    }

    func testOverlappingRegionsUnionRatherThanEvenOddCancellation() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 6, height: 6)))
        try geometry.append(.rectangle(CGRect(x: 4, y: 4, width: 6, height: 6)))
        let mask = try geometry.rasterized()
        XCTAssertEqual(mask.selectedPixelCount, 68)
        XCTAssertEqual(alpha(mask, x: 5, y: 5), 255)
    }

    func testSubtractionLeavesTrueTransparentHoleAndCanBeAddedBack() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 12, height: 12)))
        try geometry.append(.rectangle(CGRect(x: 3, y: 4, width: 5, height: 3)), subtracts: true)
        let subtracted = try geometry.rasterized()
        XCTAssertEqual(subtracted.selectedPixelCount, 129)
        XCTAssertEqual(alpha(subtracted, x: 4, y: 5), 0)
        XCTAssertEqual(alpha(subtracted, x: 4, y: 8), 255)
        try geometry.append(.rectangle(CGRect(x: 3, y: 4, width: 5, height: 3)))
        XCTAssertEqual(try geometry.rasterized().selectedPixelCount, 144)
    }

    func testSubtractionTrimsOutputToActualSurvivingUnion() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 10, height: 8)))
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 4, height: 8)), subtracts: true)
        XCTAssertEqual(try geometry.rasterized().pixelBounds, CGRect(x: 4, y: 0, width: 6, height: 8))
    }

    func testSubtractBeforeAddingDoesNotRemoveLaterRegion() throws {
        var geometry = try makeGeometry(size: 20)
        let rectangle = CaptureSelectionShape.rectangle(CGRect(x: 2, y: 3, width: 8, height: 9))
        try geometry.append(rectangle, subtracts: true)
        XCTAssertThrowsError(try geometry.rasterized()) { XCTAssertEqual($0 as? CaptureSelectionError, .emptySelection) }
        try geometry.append(rectangle)
        XCTAssertEqual(try geometry.rasterized().selectedPixelCount, 72)
    }

    func testRepeatedSubtractionNeverTogglesARegionBackOn() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)))
        for _ in 0..<2 { try geometry.append(.rectangle(CGRect(x: 3, y: 4, width: 2, height: 3)), subtracts: true) }
        XCTAssertEqual(try geometry.rasterized().selectedPixelCount, 94)
    }

    func testPolygonRasterMatchesEquivalentRectangle() throws {
        var rectangle = try makeGeometry(size: 20, scale: 2)
        var polygon = rectangle
        try rectangle.append(.rectangle(CGRect(x: 2, y: 3, width: 9, height: 7)))
        try polygon.append(.polygon([CGPoint(x: 2, y: 3), CGPoint(x: 11, y: 3), CGPoint(x: 11, y: 10), CGPoint(x: 2, y: 10)]))
        XCTAssertEqual(try rectangle.rasterized().pixelBounds, try polygon.rasterized().pixelBounds)
        XCTAssertEqual(try rectangle.rasterized().alpha, try polygon.rasterized().alpha)
    }

    func testTriangleHasTransparentPixelsInsideItsBoundingBox() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.polygon([CGPoint(x: 2, y: 3), CGPoint(x: 14, y: 3), CGPoint(x: 2, y: 16)]))
        let mask = try geometry.rasterized()
        XCTAssertEqual(alpha(mask, x: 3, y: 4), 255)
        XCTAssertEqual(alpha(mask, x: 12, y: 14), 0)
        XCTAssertEqual(alpha(mask, x: 12, y: 4), 255)
        XCTAssertEqual(alpha(mask, x: 3, y: 14), 0)
    }

    func testConcavePolygonPreservesNotch() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.polygon([CGPoint(x: 1, y: 1), CGPoint(x: 13, y: 1), CGPoint(x: 13, y: 5),
                                      CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 13), CGPoint(x: 1, y: 13)]))
        let mask = try geometry.rasterized()
        XCTAssertEqual(mask.selectedPixelCount, 80)
        XCTAssertEqual(alpha(mask, x: 10, y: 10), 0)
        XCTAssertEqual(alpha(mask, x: 3, y: 10), 255)
    }

    func testSelfCrossingPolygonUsesEvenOddFill() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.polygon([CGPoint(x: 2, y: 2), CGPoint(x: 14, y: 14), CGPoint(x: 2, y: 14), CGPoint(x: 14, y: 2)]))
        let mask = try geometry.rasterized()
        XCTAssertEqual(alpha(mask, x: 8, y: 3), 255)
        XCTAssertEqual(alpha(mask, x: 8, y: 12), 255)
        XCTAssertEqual(alpha(mask, x: 2, y: 7), 0)
    }

    func testPolygonOutsideCanvasIsClippedRatherThanVertexClamped() throws {
        var geometry = try makeGeometry(size: 10)
        try geometry.append(.polygon([CGPoint(x: -10, y: -10), CGPoint(x: 8, y: -10), CGPoint(x: 8, y: 8), CGPoint(x: -10, y: 8)]))
        let mask = try geometry.rasterized()
        XCTAssertEqual(mask.pixelBounds, CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertEqual(mask.selectedPixelCount, 64)
    }

    func testEmptyTinyCollinearAndFullySubtractedSelectionsFail() throws {
        var geometry = try makeGeometry(size: 20)
        XCTAssertThrowsError(try geometry.rasterized())
        XCTAssertThrowsError(try geometry.append(.rectangle(CGRect(x: 2, y: 3, width: 1, height: 8))))
        XCTAssertThrowsError(try geometry.append(.polygon([.zero, CGPoint(x: 4, y: 4)])))
        try geometry.append(.polygon([.zero, CGPoint(x: 4, y: 4), CGPoint(x: 8, y: 8)]))
        XCTAssertThrowsError(try geometry.rasterized()) { XCTAssertEqual($0 as? CaptureSelectionError, .emptySelection) }
        geometry.clear()
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)))
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)), subtracts: true)
        XCTAssertThrowsError(try geometry.rasterized()) { XCTAssertEqual($0 as? CaptureSelectionError, .emptySelection) }
    }

    func testSubtractionCannotLeaveASubTwoPointStrip() throws {
        var geometry = try makeGeometry(size: 20, scale: 2)
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)))
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 9, height: 10)), subtracts: true)
        XCTAssertThrowsError(try geometry.rasterized()) { XCTAssertEqual($0 as? CaptureSelectionError, .emptySelection) }
    }

    func testCancellationClearsDraftAndCannotBeUndoneOrRevived() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.rectangle(CGRect(x: 1, y: 2, width: 4, height: 6)))
        geometry.cancel()
        geometry.cancel()
        geometry.undo()
        geometry.clear()
        XCTAssertTrue(geometry.isCancelled)
        XCTAssertTrue(geometry.operations.isEmpty)
        XCTAssertThrowsError(try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 4, height: 4)))) {
            XCTAssertEqual($0 as? CaptureSelectionError, .cancelled)
        }
        XCTAssertThrowsError(try geometry.rasterized()) { XCTAssertEqual($0 as? CaptureSelectionError, .cancelled) }
        XCTAssertFalse(try makeGeometry(size: 20).isCancelled)
    }

    func testUndoAndClearDoNotMutateEarlierValueSnapshot() throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 4, height: 4)))
        let snapshot = geometry
        try geometry.append(.rectangle(CGRect(x: 8, y: 8, width: 4, height: 4)))
        geometry.undo()
        XCTAssertEqual(try geometry.rasterized().alpha, try snapshot.rasterized().alpha)
        geometry.clear()
        XCTAssertTrue(geometry.operations.isEmpty)
        XCTAssertEqual(try snapshot.rasterized().selectedPixelCount, 16)
    }

    func testCancelledTaskStopsRasterization() async throws {
        var geometry = try makeGeometry(size: 20)
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 4, height: 4)))
        let snapshot = geometry
        let worker = Task {
            // Whether cancellation arrives before or during sleep, still enter the
            // rasterizer in a cancelled task and verify its own cancellation check.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return try snapshot.rasterized()
        }
        worker.cancel()
        do { _ = try await worker.value; XCTFail("A cancelled raster must not return pixels") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAllocationPreflightRejectsOverflowAndOversizedUnion() throws {
        XCTAssertTrue(CaptureSelectionGeometry.allowsOutputSize(width: 8_000, height: 4_000))
        XCTAssertFalse(CaptureSelectionGeometry.allowsOutputSize(width: 8_001, height: 4_000))
        XCTAssertFalse(CaptureSelectionGeometry.allowsOutputSize(width: Int.max, height: 2))
        XCTAssertFalse(CaptureSelectionGeometry.allowsSourceSize(width: 2, height: Int.max))
        XCTAssertFalse(CaptureSelectionGeometry.allowsOutputSize(width: 0, height: 10))
        XCTAssertFalse(CaptureSelectionGeometry.allowsSourceSize(width: 10, height: -1))
        var geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 10_000, height: 6_000), pixelWidth: 10_000, pixelHeight: 6_000)
        try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 10_000, height: 6_000)))
        XCTAssertThrowsError(try geometry.enclosingPixelBounds()) { XCTAssertEqual($0 as? CaptureSelectionError, .pixelLimit) }
    }

    func testNonFiniteInputAndComplexityAreRejectedWithoutMutatingDraft() throws {
        XCTAssertThrowsError(try CaptureSelectionGeometry(pointSize: CGSize(width: CGFloat.nan, height: 10), pixelWidth: 10, pixelHeight: 10))
        var geometry = try makeGeometry(size: 20)
        XCTAssertThrowsError(try geometry.append(.rectangle(CGRect(x: CGFloat.infinity, y: 0, width: 4, height: 4))))
        XCTAssertThrowsError(try geometry.append(.polygon([CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 4)])))
        XCTAssertThrowsError(try geometry.append(.polygon(Array(repeating: .zero, count: CaptureSelectionGeometry.maximumPoints + 1)))) {
            XCTAssertEqual($0 as? CaptureSelectionError, .complexityLimit)
        }
        XCTAssertTrue(geometry.operations.isEmpty)
        for _ in 0..<CaptureSelectionGeometry.maximumOperations {
            try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 4, height: 4)))
        }
        XCTAssertThrowsError(try geometry.append(.rectangle(CGRect(x: 0, y: 0, width: 4, height: 4)))) {
            XCTAssertEqual($0 as? CaptureSelectionError, .complexityLimit)
        }
        XCTAssertEqual(geometry.operations.count, CaptureSelectionGeometry.maximumOperations)
    }

    private func makeGeometry(size: Int, scale: Int = 1) throws -> CaptureSelectionGeometry {
        try CaptureSelectionGeometry(pointSize: CGSize(width: size, height: size), pixelWidth: size * scale, pixelHeight: size * scale)
    }

    private func alpha(_ mask: CaptureSelectionMask, x: Int, y: Int) -> UInt8 {
        let localX = x - Int(mask.pixelBounds.minX), localY = y - Int(mask.pixelBounds.minY)
        guard localX >= 0, localY >= 0, localX < mask.width, localY < mask.height else { return 0 }
        return mask.alpha[localY * mask.width + localX]
    }
}
