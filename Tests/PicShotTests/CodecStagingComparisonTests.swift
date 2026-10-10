import XCTest
import AppKit
import CryptoKit
import PicShotCodecCore
@testable import PicShot

@MainActor
final class CodecStagingComparisonTests: XCTestCase {
    func testSelectorsRejectMixedOrUnboundedWorkBeforeClaimingProcess() async throws {
        let base = ["PICSHOT_CODEC_STAGING_MODE": "export-only", "PICSHOT_CODEC_STAGING_ARM": "candidate",
                    "PICSHOT_CODEC_STAGING_PROFILE": "installed-768x576"]
        let absent = try await CodecStagingComparisonFixture.runIfRequested(evidenceDirectory: FileManager.default.temporaryDirectory, environment: [:])
        XCTAssertNil(absent)
        for changes in [
            ["PICSHOT_CODEC_STAGING_MODE": "unknown"], ["PICSHOT_CODEC_STAGING_ARM": "default"],
            ["PICSHOT_CODEC_STAGING_PROFILE": "unbounded"], ["PICSHOT_CODEC_STAGING_CYCLES": "1"],
            ["PICSHOT_CODEC_STAGING_FORMAT": "png"], ["PICSHOT_CODEC_ATTRIBUTION_MODE": "combined"],
            ["PICSHOT_CODEC_STAGING_INPUT_DIRECTORY": "/tmp/not-a-validation"],
            ["PICSHOT_CODEC_STAGING_MODE": "validate"]
        ] {
            let environment = base.merging(changes) { _, new in new }
            do {
                _ = try await CodecStagingComparisonFixture.runIfRequested(evidenceDirectory: FileManager.default.temporaryDirectory, environment: environment)
                XCTFail("Invalid diagnostic selector accepted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Codec staging comparison")) }
        }
    }
    func testProviderIdentityBindsSourceWithoutAnExtraMeasuredRasterDraw() throws {
        for (width, height) in [(160, 120), (768, 576)] {
            let source = try CodecExportResourceFixture.fixture(width: width, height: height)
            let expected = SHA256.hash(data: try CodecExportResourceFixture.raster(source)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try CodecStagingComparisonFixture.sourceIdentity(source), expected)
        }
    }
    func testBoundedLargeProfileAndOptInVolatileSampler() async throws {
        let profile = CodecExportAttributionFixture.Profile.stagingLarge
        XCTAssertEqual(profile.width, 2048); XCTAssertEqual(profile.height, 1536)
        XCTAssertLessThanOrEqual(profile.width * profile.height, CodecExportLimits.stillPixels)
        XCTAssertEqual(profile.warmupCycles, 2); XCTAssertEqual(profile.measuredCycles, 3)
        let original = GIFResourceMemorySampler(), diagnostic = GIFResourceMemorySampler(includeBacking: true)
        try await Task.sleep(nanoseconds: 120_000_000)
        original.stop(); diagnostic.stop()
        XCTAssertNil(original.snapshot().peakVolatileResidentBytes)
        XCTAssertEqual(original.snapshot().backingSampleCount, 0)
        XCTAssertGreaterThan(diagnostic.snapshot().backingSampleCount, 0)
        XCTAssertGreaterThan(diagnostic.snapshot().timerTickCount, 0)
        XCTAssertNotNil(diagnostic.snapshot().peakVolatileResidentBytes)
        XCTAssertNotNil(diagnostic.snapshot().peakVolatileLedgerBytes)
    }
}
