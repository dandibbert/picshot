import XCTest
import AppKit
@testable import PicShot

@MainActor
final class ImageExportResourceFixtureTests: XCTestCase {
    func testQuickProfileRecordsRepeatedRealMemorySamplesAndCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-resource-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await ImageExportResourceFixture.verify(evidenceDirectory: directory, profile: .quickTest)
        XCTAssertEqual(report["status"] as? String, "observed")
        XCTAssertEqual(report["profile"] as? String, "unit-160x100-two-cycles")
        XCTAssertEqual(report["completedMeasuredCycles"] as? Int, 2)
        XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
        XCTAssertEqual(report["activeSessionsAfterAllCycles"] as? Int, 0)
        XCTAssertEqual(report["queuedOrRunningJobsAfterAllCycles"] as? Int, 0)
        let cycles = try XCTUnwrap(report["cycles"] as? [[String: Any]])
        XCTAssertEqual(cycles.count, 2)
        for cycle in cycles {
            let metrics = try XCTUnwrap(cycle["sampledMemory"] as? [String: Any])
            XCTAssertGreaterThan((metrics["residentSampleCount"] as? NSNumber)?.intValue ?? 0, 1)
            XCTAssertGreaterThan((metrics["physicalFootprintSampleCount"] as? NSNumber)?.intValue ?? 0, 1)
            XCTAssertGreaterThan((metrics["timerTickCount"] as? NSNumber)?.intValue ?? 0, 0)
            XCTAssertEqual((cycle["settledSamples"] as? [[String: Any]])?.count, 3)
            XCTAssertEqual(cycle["observedControllerReleaseCount"] as? Int, 4)
            XCTAssertEqual(cycle["activeSessionsAfterCycle"] as? Int, 0)
            XCTAssertEqual(cycle["queuedOrRunningJobsAfterCycle"] as? Int, 0)
            XCTAssertEqual(cycle["ownedTemporaryFilesAfterCycle"] as? Int, 0)
            let exports = try XCTUnwrap(cycle["exports"] as? [[String: Any]])
            XCTAssertEqual(exports.compactMap { $0["format"] as? String }, ["PNG", "JPEG", "BMP", "PDF"])
            XCTAssertTrue(exports.allSatisfy { $0["controllerReleased"] as? Bool == true })
        }
        XCTAssertNotNil(report["residentGrowthFromWarmupBytes"])
        XCTAssertNotNil(report["physicalFootprintGrowthFromWarmupBytes"])
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("image-export-resource.json"))) as? [String: Any]
        XCTAssertEqual(saved?["status"] as? String, "observed")
    }
    func testInstalledProfileRemainsBoundedAndDistinctFromUnitProfile() {
        XCTAssertEqual(ImageExportResourceFixture.Profile.installed.width, 1440)
        XCTAssertEqual(ImageExportResourceFixture.Profile.installed.height, 900)
        XCTAssertEqual(ImageExportResourceFixture.Profile.installed.measuredCycles, 4)
        XCTAssertEqual(ImageExportResourceFixture.Profile.quickTest.width, 160)
        XCTAssertNotEqual(ImageExportResourceFixture.Profile.installed.rawValue, ImageExportResourceFixture.Profile.quickTest.rawValue)
    }
}
