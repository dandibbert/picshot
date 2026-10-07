import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor
final class ScrollMemoryAttributionTests: XCTestCase {
    func testBaselineConfigurationRejectsUnavailableDetailAndMissingPreparedInputs() throws {
        let directory = FileManager.default.temporaryDirectory
        for mode in ScrollMemoryAttributionFixture.Mode.allCases {
            if mode == .detail {
                XCTAssertThrowsError(try ScrollMemoryAttributionFixture.validate(mode: mode, input: directory, detailAvailable: false))
            } else {
                XCTAssertNoThrow(try ScrollMemoryAttributionFixture.validate(mode: mode,
                    input: mode.needsInput ? directory : nil, detailAvailable: false))
            }
        }
        XCTAssertThrowsError(try ScrollMemoryAttributionFixture.validate(mode: .overview, input: nil, detailAvailable: true))
        XCTAssertThrowsError(try ScrollMemoryAttributionFixture.validate(mode: .sourceCreate, input: directory, detailAvailable: true))
    }

    func testProceduralSourcesMatchQuarterStepAndHashesDetectMovedViewports() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            let width = 384, height = 256, step = (axis == .vertical ? height : width) / 4
            let first = try ScrollMemoryAttributionFixture.makeImage(width: width, height: height, offset: 100, axis: axis)
            let second = try ScrollMemoryAttributionFixture.makeImage(width: width, height: height, offset: 100 + step, axis: axis)
            let same = try ScrollMemoryAttributionFixture.makeImage(width: width, height: height, offset: 100, axis: axis)
            XCTAssertEqual(try ScrollMemoryAttributionFixture.rgbaHash(first), try ScrollMemoryAttributionFixture.rgbaHash(same))
            XCTAssertNotEqual(try ScrollMemoryAttributionFixture.rgbaHash(first), try ScrollMemoryAttributionFixture.rgbaHash(second))
            let match = try ScrollStitcher.matchBidirectional(previous: ScrollImageIO.luminance(first), next: ScrollImageIO.luminance(second), axis: axis)
            XCTAssertEqual(match.advance, step)
        }
    }

    func testSampleWatchdogRejectsMissingFailedAndOverLimitObservations() throws {
        var statistics = GIFResourceMemoryStatistics()
        XCTAssertThrowsError(try ScrollMemoryAttributionFixture.checkSamples(statistics))
        statistics.record(GIFResourceMemoryReading(residentBytes: 4096, physicalFootprintBytes: 4096), isTimer: true)
        XCTAssertNoThrow(try ScrollMemoryAttributionFixture.checkSamples(statistics))
        statistics.record(GIFResourceMemoryReading(residentBytes: nil, physicalFootprintBytes: 4096))
        XCTAssertThrowsError(try ScrollMemoryAttributionFixture.checkSamples(statistics))
        var excessive = GIFResourceMemoryStatistics()
        excessive.record(GIFResourceMemoryReading(residentBytes: ScrollMemoryAttributionFixture.residentCeiling + 1, physicalFootprintBytes: 4096))
        XCTAssertThrowsError(try ScrollMemoryAttributionFixture.checkSamples(excessive))
        var footprint = GIFResourceMemoryStatistics()
        footprint.record(GIFResourceMemoryReading(residentBytes: 4096, physicalFootprintBytes: ScrollMemoryAttributionFixture.footprintCeiling + 1))
        XCTAssertThrowsError(try ScrollMemoryAttributionFixture.checkSamples(footprint))
    }
}
