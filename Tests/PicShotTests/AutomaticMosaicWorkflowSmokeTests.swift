import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor final class AutomaticMosaicWorkflowSmokeTests: XCTestCase {
    func testAuthoredNamesIconsColorAlphaUseActualMatcherAndKeepSourceBytes() async throws {
        let image = try AutomaticMosaicWorkflowSmokeFixture.authoredRaster()
        let before = try XCTUnwrap(image.dataProvider?.data) as Data
        let region = AutomaticMosaicWorkflowSmokeFixture.authoredRegions[0]
        let matcher = AutomaticMosaicMatcher()
        let result = try await matcher.findMatches(in: image, seed: RepeatedRegionPixelRect(
            x: Int(region.minX), y: Int(region.minY), width: Int(region.width), height: Int(region.height)))
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertFalse(result.truncated)
        for expected in AutomaticMosaicWorkflowSmokeFixture.authoredRegions.dropFirst() {
            XCTAssertEqual(result.candidates.filter {
                $0.rect.x == Int(expected.minX) && $0.rect.y == Int(expected.minY) &&
                    $0.rect.width == Int(expected.width) && $0.rect.height == Int(expected.height)
            }.count, 1)
        }
        let nonmatch = AutomaticMosaicWorkflowSmokeFixture.nearNonmatch
        XCTAssertFalse(result.candidates.contains { $0.rect.x == Int(nonmatch.minX) && $0.rect.y == Int(nonmatch.minY) })
        XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, before)
        XCTAssertTrue(stride(from: 3, to: before.count, by: 4).contains { before[$0] < 255 }, "Alpha case disappeared")
    }

    func testNativeWorkflowUsesReviewControlsExportsAndStaleActualCallbacks() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Requires native WindowServer; no capture or Accessibility permissions requested") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Mosaic-Workflow-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await AutomaticMosaicWorkflowSmokeFixture.verify(evidenceDirectory: directory, includeResourceCycles: false)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["sourceByteIdentityVerified"] as? Bool, true)
        XCTAssertEqual(report["generalPasteboardReadOrWritten"] as? Bool, false)
        let controls = try XCTUnwrap(report["controls"] as? [String: Any])
        XCTAssertEqual(controls["staleCallbacksRejected"] as? Int, 4)
        XCTAssertEqual(controls["edgePlacements"] as? [String], ["top-left", "top-right", "bottom-left", "bottom-right"])
        let resources = try XCTUnwrap(report["resourceEvidence"] as? [String: Any])
        XCTAssertEqual(resources["status"] as? String, "not-run")
        let exports = try XCTUnwrap(report["exports"] as? [[String: Any]])
        XCTAssertEqual(exports.count, 4)
        XCTAssertTrue(exports.allSatisfy { ($0["exteriorMismatches"] as? Int) == 0 })
    }
}
