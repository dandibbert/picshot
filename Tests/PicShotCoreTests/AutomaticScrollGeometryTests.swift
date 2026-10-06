import XCTest
@testable import PicShotCore

final class AutomaticScrollGeometryTests: XCTestCase {
    func testTargetUsesDisplayLocalPointsWithNegativeOrigins() throws {
        let region = CGRect(x: 100, y: 50, width: 400, height: 300)
        XCTAssertEqual(try AutomaticScrollGeometry.targetPoint(region: region,
            displayBounds: CGRect(x: -1920, y: -200, width: 1920, height: 1080)), CGPoint(x: -1620, y: 0))
    }

    func testSameLogicalRegionOnOneAndTwoTimesDisplays() throws {
        let region = CGRect(x: 100, y: 50, width: 400, height: 300)
        let size = CGSize(width: 1440, height: 900)
        XCTAssertEqual(try AutomaticScrollGeometry.pixelRect(region: region, logicalSize: size,
            pixelWidth: 1440, pixelHeight: 900), region)
        XCTAssertEqual(try AutomaticScrollGeometry.pixelRect(region: region, logicalSize: size,
            pixelWidth: 2880, pixelHeight: 1800), CGRect(x: 200, y: 100, width: 800, height: 600))
    }

    func testIndependentScalesAndFractionalEdgesRoundWithinDisplay() throws {
        let result = try AutomaticScrollGeometry.pixelRect(region: CGRect(x: 9.5, y: 8.5, width: 0.5, height: 1.5),
            logicalSize: CGSize(width: 10, height: 10), pixelWidth: 15, pixelHeight: 20)
        XCTAssertEqual(result, CGRect(x: 14, y: 17, width: 1, height: 3))
    }

    func testInvalidOrOffDisplayRegionsAreRejected() throws {
        for region in [CGRect.zero, CGRect(x: -1, y: 0, width: 5, height: 5),
                       CGRect(x: 9, y: 9, width: 2, height: 2), CGRect(x: .infinity, y: 0, width: 2, height: 2)] {
            XCTAssertThrowsError(try AutomaticScrollGeometry.targetPoint(region: region,
                displayBounds: CGRect(x: 0, y: 0, width: 10, height: 10)))
        }
        XCTAssertThrowsError(try AutomaticScrollGeometry.pixelRect(region: CGRect(x: 0, y: 0, width: 5, height: 5),
            logicalSize: CGSize(width: 10, height: 10), pixelWidth: 0, pixelHeight: 20))
    }
}
