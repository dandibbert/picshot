import XCTest
@testable import PicShotCore

final class DisplayCompositeLayoutTests: XCTestCase {
    func testNegativeOriginsAboveAndLeftPreserveDesktopPlacement() throws {
        let left = try display(1, x: -100, y: -40, width: 100, height: 80)
        let main = try display(2, x: 0, y: 0, width: 120, height: 90)
        let layout = try DisplayCompositeLayout(displays: [main, left])
        XCTAssertEqual(layout.desktopBounds, CGRect(x: -100, y: -40, width: 220, height: 130))
        XCTAssertEqual(layout.width, 220)
        XCTAssertEqual(layout.height, 130)
        XCTAssertEqual(layout.placements.map(\.display.id), [1, 2])
        XCTAssertEqual(layout.placements[0].pixelBounds, CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(layout.placements[1].pixelBounds, CGRect(x: 100, y: 40, width: 120, height: 90))
    }

    func testMixedRetinaUsesOneMaximumDensityWithGapsIncludedInBudget() throws {
        let layout = try DisplayCompositeLayout(displays: [
            display(1, x: 0, y: 0, width: 100, height: 80, scale: 1),
            display(2, x: 120, y: 30, width: 90, height: 70, scale: 2)
        ])
        XCTAssertEqual(layout.pixelsPerPoint, 2)
        XCTAssertEqual(layout.width, 420)
        XCTAssertEqual(layout.height, 200)
        XCTAssertEqual(layout.placements[0].display.pixelWidth, 100)
        XCTAssertEqual(layout.placements[0].pixelBounds, CGRect(x: 0, y: 0, width: 200, height: 160))
        XCTAssertEqual(layout.placements[1].pixelBounds, CGRect(x: 240, y: 60, width: 180, height: 140))
    }

    func testPortraitRotationsUseAlreadyOrientedBoundsWithoutSecondSwap() throws {
        for rotation in [0.0, 90.0, 180.0, 270.0] {
            let portrait = try DisplayCaptureDescriptor(id: 7, bounds: CGRect(x: -60, y: -80, width: 60, height: 100),
                                                       pixelsPerPoint: 2, rotationDegrees: rotation)
            let layout = try DisplayCompositeLayout(displays: [portrait])
            XCTAssertEqual(layout.width, 120)
            XCTAssertEqual(layout.height, 200)
            XCTAssertEqual(layout.placements[0].display.rotationDegrees, rotation)
        }
    }

    func testFractionalCommonEdgesDoNotCreateSeamsOrOverlaps() throws {
        let layout = try DisplayCompositeLayout(displays: [
            display(1, x: -10.3, y: 0, width: 20.3, height: 30, scale: 1.25),
            display(2, x: 10, y: 0, width: 20.7, height: 30, scale: 1.5)
        ])
        XCTAssertEqual(layout.placements[0].pixelBounds.maxX, layout.placements[1].pixelBounds.minX)
        XCTAssertEqual(layout.placements.last?.pixelBounds.maxX, CGFloat(layout.width))
    }

    func testMirroredOverlappingScreensHaveStableIDOrder() throws {
        let one = try display(1, x: 0, y: 0, width: 100, height: 80)
        let two = try display(2, x: 0, y: 0, width: 100, height: 80)
        XCTAssertEqual(try DisplayCompositeLayout(displays: [one, two]), try DisplayCompositeLayout(displays: [two, one]))
        XCTAssertEqual(try DisplayCompositeLayout(displays: [one, two]).width, 100)
    }

    func testExactly64MillionPixelsAllowedAndOneMoreRejectedBeforeAllocation() throws {
        XCTAssertTrue(DisplayCompositeLayout.allowsSize(width: 8_000, height: 8_000))
        XCTAssertFalse(DisplayCompositeLayout.allowsSize(width: 8_001, height: 8_000))
        let valid = try display(1, x: 0, y: 0, width: 8_000, height: 8_000)
        XCTAssertEqual(try DisplayCompositeLayout(displays: [valid]).width, 8_000)
        XCTAssertThrowsError(try display(1, x: 0, y: 0, width: 8_001, height: 8_000))
        let tinyFarAway = try display(2, x: 8_000, y: 0, width: 1, height: 1)
        XCTAssertThrowsError(try DisplayCompositeLayout(displays: [valid, tinyFarAway])) {
            XCTAssertEqual($0 as? DisplayCompositeError, .pixelLimit)
        }
    }

    func testLargeEmptyGapCannotBypassCompositeLimit() throws {
        let a = try display(1, x: -20_000, y: 0, width: 10, height: 10)
        let b = try display(2, x: 20_000, y: 0, width: 10, height: 10)
        XCTAssertThrowsError(try DisplayCompositeLayout(displays: [a, b]))
        XCTAssertFalse(DisplayCompositeLayout.allowsSize(width: Int.max, height: 2))
        XCTAssertFalse(DisplayCompositeLayout.allowsSize(width: 2, height: Int.max))
        XCTAssertFalse(DisplayCompositeLayout.allowsSize(width: 0, height: 1))
        XCTAssertFalse(DisplayCompositeLayout.allowsSize(width: 1, height: -1))
    }

    func testNonFiniteAndOverflowGeometryIsRejectedWithoutIntegerTrap() throws {
        for invalid in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try display(1, x: invalid, y: 0, width: 10, height: 10))
            XCTAssertThrowsError(try display(1, x: 0, y: invalid, width: 10, height: 10))
            XCTAssertThrowsError(try display(1, x: 0, y: 0, width: invalid, height: 10))
            XCTAssertThrowsError(try display(1, x: 0, y: 0, width: 10, height: 10, scale: invalid))
        }
        XCTAssertThrowsError(try display(1, x: 0, y: 0, width: 10, height: 10, scale: 0))
        XCTAssertThrowsError(try display(1, x: 0, y: 0, width: 1e300, height: 1e300))
    }

    func testEmptyDuplicateAndTooManyDisplaysAreRejected() throws {
        XCTAssertThrowsError(try DisplayCompositeLayout(displays: []))
        let one = try display(1, x: 0, y: 0, width: 10, height: 10)
        XCTAssertThrowsError(try DisplayCompositeLayout(displays: [one, one])) {
            XCTAssertEqual($0 as? DisplayCompositeError, .duplicateDisplay)
        }
        let many = try (0...64).map { try display(UInt32($0), x: 0, y: 0, width: 1, height: 1) }
        XCTAssertThrowsError(try DisplayCompositeLayout(displays: many))
    }

    func testReorderedSnapshotAcceptedButConnectionOriginDensityAndRotationChangesRejected() throws {
        let one = try display(1, x: 0, y: 0, width: 100, height: 80)
        let two = try display(2, x: 100, y: 0, width: 100, height: 80)
        let layout = try DisplayCompositeLayout(displays: [one, two])
        XCTAssertNoThrow(try layout.validate(displays: [two, one]))
        let changes = try [
            [one],
            [one, display(3, x: 100, y: 0, width: 100, height: 80)],
            [one, display(2, x: 101, y: 0, width: 100, height: 80)],
            [one, display(2, x: 100, y: 0, width: 100, height: 80, scale: 2)],
            [one, DisplayCaptureDescriptor(id: 2, bounds: two.bounds, pixelsPerPoint: 1, rotationDegrees: 180)]
        ]
        for changed in changes {
            XCTAssertThrowsError(try layout.validate(displays: changed)) {
                XCTAssertEqual($0 as? DisplayCompositeError, .layoutChanged)
            }
        }
    }

    private func display(_ id: UInt32, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, scale: CGFloat = 1) throws -> DisplayCaptureDescriptor {
        try DisplayCaptureDescriptor(id: id, bounds: CGRect(x: x, y: y, width: width, height: height), pixelsPerPoint: scale)
    }
}
