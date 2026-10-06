import XCTest
@testable import PicShotCore

final class CompactPinRecoveryTests: XCTestCase {
    func testSmallPinsStayCompactWhenRecovered() {
        let frame = PinWindowFrame(x: 50, y: 70, width: 120, height: 80)
        XCTAssertEqual(frame.recovered(in: [PinWindowFrame(x: 0, y: 0, width: 1440, height: 900)]), frame)
    }
    func testCompactMinimumAndRemovedDisplayAreStillClamped() {
        let screen = PinWindowFrame(x: -1280, y: 0, width: 1280, height: 800)
        let frame = PinWindowFrame(x: 5000, y: -400, width: 2, height: 3).recovered(in: [screen])
        XCTAssertEqual(frame.width, 32); XCTAssertEqual(frame.height, 24)
        XCTAssertGreaterThanOrEqual(frame.x, screen.x); XCTAssertLessThanOrEqual(frame.x + frame.width, screen.x + screen.width)
        XCTAssertGreaterThanOrEqual(frame.y, screen.y); XCTAssertLessThanOrEqual(frame.y + frame.height, screen.y + screen.height)
    }
}
