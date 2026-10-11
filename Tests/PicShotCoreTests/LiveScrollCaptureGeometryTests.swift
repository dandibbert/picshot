import XCTest
@testable import PicShotCore

final class LiveScrollCaptureGeometryTests: XCTestCase {
    func testPrefersBelowAndRightSideWhenBottomSpaceIsUnavailable() throws {
        let screen = CGRect(x: -1_400, y: -200, width: 1_400, height: 900)
        let target = CGRect(x: -1_000, y: 100, width: 500, height: 400)
        let below = try XCTUnwrap(LiveScrollCaptureGeometry.placement(target: target, visibleFrame: screen))
        XCTAssertEqual(below.toolbar.maxY, target.minY - 8)
        XCTAssertEqual(below.toolbar.maxX, target.maxX)
        XCTAssertFalse(below.overlapsTarget)
        XCTAssertGreaterThanOrEqual(below.preview.minX, target.maxX + 8)
        let bottomTarget = CGRect(x: -1_200, y: -200, width: 900, height: 800)
        let beside = try XCTUnwrap(LiveScrollCaptureGeometry.placement(target: bottomTarget, visibleFrame: screen))
        XCTAssertEqual(beside.toolbar.size, LiveScrollCaptureGeometry.compactToolbarSize)
        XCTAssertEqual(beside.toolbar.minX, bottomTarget.maxX + 8)
        XCTAssertFalse(beside.overlapsTarget)
        XCTAssertFalse(beside.toolbar.intersects(beside.preview))
    }

    func testFourEdgesAndNegativeDisplayOriginsStayReachable() throws {
        for screen in [CGRect(x: 0, y: 24, width: 1_280, height: 776),
                       CGRect(x: -1_920, y: -480, width: 1_920, height: 1_056),
                       CGRect(x: 200, y: 1_080, width: 1_024, height: 744)] {
            for x in [screen.minX, screen.maxX - 600] {
                for y in [screen.minY, screen.maxY - 500] {
                    let target = CGRect(x: x, y: y, width: 600, height: 500)
                    let result = try XCTUnwrap(LiveScrollCaptureGeometry.placement(target: target, visibleFrame: screen))
                    XCTAssertTrue(screen.contains(result.toolbar))
                    XCTAssertFalse(result.toolbar.intersects(target))
                    XCTAssertFalse(result.preview.isEmpty)
                    XCTAssertTrue(screen.contains(result.preview))
                    XCTAssertFalse(result.preview.intersects(result.toolbar))
                    XCTAssertFalse(result.preview.intersects(target))
                }
            }
        }
    }

    func testFullScreenFallbackReportsOverlapWithoutCoveringControls() throws {
        for width in [CGFloat(160), 180, 309, 310, 800] {
            let screen = CGRect(x: -600, y: -240, width: width, height: 600)
            let result = try XCTUnwrap(LiveScrollCaptureGeometry.placement(target: screen, visibleFrame: screen))
            XCTAssertTrue(result.overlapsTarget)
            XCTAssertTrue(screen.contains(result.toolbar))
            XCTAssertTrue(screen.contains(result.preview))
            XCTAssertFalse(result.preview.intersects(result.toolbar))
        }
        let minimal = CGRect(x: -160, y: 900, width: 160, height: 122)
        let result = try XCTUnwrap(LiveScrollCaptureGeometry.placement(target: minimal, visibleFrame: minimal))
        XCTAssertEqual(result.toolbar, minimal)
        XCTAssertTrue(result.preview.isEmpty)
        XCTAssertNil(LiveScrollCaptureGeometry.placement(target: .null, visibleFrame: minimal))
        XCTAssertNil(LiveScrollCaptureGeometry.placement(target: minimal, visibleFrame: CGRect(x: 0, y: 0, width: 159, height: 122)))
    }

    func testViewportMarkerUsesTopLeftCoordinatesAndRejectsInvalidValues() throws {
        let image = CGRect(x: 8, y: 7, width: 96, height: 300)
        let marker = try XCTUnwrap(LiveScrollCaptureGeometry.viewportMarker(
            fraction: CGRect(x: 0, y: 0.75, width: 1, height: 0.25), imageRect: image))
        XCTAssertEqual(marker, CGRect(x: 8, y: 232, width: 96, height: 75))
        let clipped = try XCTUnwrap(LiveScrollCaptureGeometry.normalizedViewport(CGRect(x: -0.1, y: 0.9, width: 1.2, height: 0.5)))
        XCTAssertEqual(clipped.minX, 0); XCTAssertEqual(clipped.width, 1)
        XCTAssertEqual(clipped.minY, 0.9); XCTAssertEqual(clipped.height, 0.1, accuracy: 0.000_001)
        for invalid in [CGRect.null, .zero, CGRect(x: .nan, y: 0, width: 1, height: 1),
                        CGRect(x: 2, y: 0, width: 1, height: 1)] {
            XCTAssertNil(LiveScrollCaptureGeometry.normalizedViewport(invalid))
        }
    }
}
