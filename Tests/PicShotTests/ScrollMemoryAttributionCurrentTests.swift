import XCTest
import PicShotCore
@testable import PicShot

/// Current checkout only. Baseline must not gain these production dependencies.
@MainActor
final class ScrollMemoryAttributionCurrentTests: XCTestCase {
    func testOverlayGeneratorAndHashMatchCurrentManualProductionAlgorithms() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            for offset in [100, 164] {
                let overlay = try ScrollMemoryAttributionFixture.makeImage(width: 384, height: 256, offset: offset, axis: axis)
                let endToEnd = try ScrollManualCaptureSmokeFixture.largeImage(width: 384, height: 256, offset: offset, axis: axis)
                let actual = try ManualScrollScreenDriver.observation(endToEnd)
                XCTAssertEqual(try ScrollMemoryAttributionFixture.rgbaHash(overlay), actual.rgbaSHA256.map { String(format: "%02x", $0) }.joined())
            }
        }
    }
}
