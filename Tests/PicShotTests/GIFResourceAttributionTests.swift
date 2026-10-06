import XCTest
import Foundation
@testable import PicShot

final class GIFResourceAttributionTests: XCTestCase {
    func testModesAndCycleCountAreExplicitAndBounded() {
        XCTAssertEqual(GIFResourceAttributionFixture.Mode.allCases.map(\.rawValue), ["export-only", "decode-only"])
        XCTAssertNil(GIFResourceAttributionFixture.Mode(rawValue: "combined"))
        XCTAssertEqual(GIFResourceAttributionFixture.measuredCycles, 8)
    }

    func testTrendPreservesEveryIntervalWithoutInventingAPassOrLeakVerdict() throws {
        let observation = GIFResourceObservationTrend(baseline: 100, settled: [110, 120, 115, 130, 130],
                                                    peaks: [120, 130, 125, 140, 140])
        XCTAssertTrue(observation.observationsComplete)
        XCTAssertEqual(observation.settledBytes, [110, 120, 115, 130, 130])
        XCTAssertEqual(observation.intervalGrowthBytes, [10, 10, -5, 15, 0])
        XCTAssertEqual(observation.finalGrowthBytes, 30)
        XCTAssertEqual(observation.sampledPeakGrowthBytes, 40)
        XCTAssertEqual(observation.lastFourObservationGrowthBytes, 10)
        XCTAssertEqual(observation.settledRangeBytes, 20)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as? [String: Any])
        XCTAssertNil(json["withinEnvelope"])
        XCTAssertNil(json["leakDetected"])
        let decrease = GIFResourceObservationTrend(baseline: 100, settled: [90, 80], peaks: [95, 85])
        XCTAssertEqual(decrease.intervalGrowthBytes, [-10, -10])
        XCTAssertEqual(decrease.finalGrowthBytes, -20)
        XCTAssertNil(decrease.lastFourObservationGrowthBytes)
    }

    func testMissingObservationsNeverBecomeZeroOrCompleteTrends() throws {
        let cases: [(UInt64?, [UInt64?], [UInt64?])] = [
            (nil, [1, 2], [1, 2]), (1, [1, nil], [1, 2]), (1, [1, 2], [nil, 2]),
            (1, [], []), (1, [1, 2], [1]), (UInt64.max, [1, 2], [1, 2])
        ]
        for values in cases {
            let observation = GIFResourceObservationTrend(baseline: values.0, settled: values.1, peaks: values.2)
            XCTAssertFalse(observation.observationsComplete)
            XCTAssertNil(observation.finalGrowthBytes)
            XCTAssertNil(observation.intervalGrowthBytes)
            XCTAssertNoThrow(try JSONEncoder().encode(observation))
        }
    }

    /// Actual native exporter/decoder, but the existing 24-frame/96-pixel quick
    /// profile keeps ordinary tests small. Full diagnostics use 360 frames and
    /// separate installed app processes; test success is not memory evidence.
    func testExportOnlyUsesNoGIFValidationUntilEightExportsHaveFinished() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await GIFResourceAttributionFixture.verify(evidenceDirectory: root, mode: .exportOnly, profile: .quickTest)
        XCTAssertEqual(report["status"] as? String, "completed")
        XCTAssertEqual(report["mode"] as? String, "export-only")
        XCTAssertEqual(report["profile"] as? String, "unit-test-short")
        XCTAssertEqual(report["frameExtraction"] as? String, "async-baseline")
        XCTAssertEqual(report["diagnosticOnly"] as? Bool, true)
        XCTAssertEqual(report["captureStarted"] as? Bool, false)
        XCTAssertEqual(report["decoderInvocationsBeforeMeasuredExports"] as? Int, 0)
        XCTAssertEqual(report["decoderInvocationsDuringMeasuredExports"] as? Int, 0)
        XCTAssertEqual(report["decoderInvocationsAfterMeasuredExports"] as? Int, 1)
        XCTAssertEqual(report["totalExportInvocations"] as? Int, 9)
        XCTAssertEqual(report["totalGIFValidationInvocations"] as? Int, 1)
        XCTAssertNotNil(report["exportWarmup"])
        XCTAssertNil(report["decoderWarmup"])
        let cycles = try XCTUnwrap(report["cycles"] as? [[String: Any]])
        XCTAssertEqual(cycles.count, 8)
        for (index, cycle) in cycles.enumerated() {
            XCTAssertEqual(cycle["cycle"] as? Int, index + 1)
            XCTAssertEqual(cycle["outputRetainedForFinalValidation"] as? Bool, index == 7)
            XCTAssertEqual(cycle["partialFilesRemaining"] as? Int, 0)
            XCTAssertGreaterThan(try XCTUnwrap(cycle["outputBytes"] as? Int), 0)
            XCTAssertNil(cycle["output"], "No decoded-image validation is allowed in export-only cycles")
            XCTAssertNotNil(cycle["settledAfterOutputCleanup"] as? [String: Any])
        }
        let final = try XCTUnwrap(report["finalValidation"] as? [String: Any])
        let output = try XCTUnwrap(final["output"] as? [String: Any])
        XCTAssertEqual(output["framesDecoded"] as? Int, 24)
        try assertSaved(report: report, root: root, mode: "export-only")
    }

    func testDecodeOnlyKeepsOnePreparedFileAndPerformsNoInterveningExports() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await GIFResourceAttributionFixture.verify(evidenceDirectory: root, mode: .decodeOnly, profile: .quickTest,
                                                                     frameExtraction: .scopedSynchronous)
        XCTAssertEqual(report["status"] as? String, "completed")
        XCTAssertEqual(report["mode"] as? String, "decode-only")
        XCTAssertEqual(report["frameExtraction"] as? String, "scoped-sync-candidate")
        XCTAssertEqual(report["exportsDuringMeasuredDecodeCycles"] as? Int, 0)
        XCTAssertEqual(report["totalExportInvocations"] as? Int, 1)
        XCTAssertEqual(report["totalGIFValidationInvocations"] as? Int, 9)
        XCTAssertNotNil(report["inputPreparationExport"])
        XCTAssertNotNil(report["decoderWarmup"])
        XCTAssertNil(report["exportWarmup"])
        XCTAssertNotNil(report["sameFileCachingLimit"] as? String)
        let cycles = try XCTUnwrap(report["cycles"] as? [[String: Any]])
        XCTAssertEqual(cycles.count, 8)
        for cycle in cycles {
            let output = try XCTUnwrap(cycle["output"] as? [String: Any])
            XCTAssertEqual(output["framesDecoded"] as? Int, 24)
            XCTAssertEqual(output["dimensions"] as? [String], ["96x54"])
            XCTAssertEqual(output["bytes"] as? Int, report["immutableInputBytes"] as? Int)
            XCTAssertNil(cycle["progressCallbacks"])
            XCTAssertNotNil(cycle["settledAfterDecode"] as? [String: Any])
        }
        try assertSaved(report: report, root: root, mode: "decode-only")
    }

    private func assertSaved(report: [String: Any], root: URL, mode: String) throws {
        XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
        let filename = "gif-attribution-" + mode + ".json"
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [filename])
        let data = try Data(contentsOf: root.appendingPathComponent(filename))
        XCTAssertLessThan(data.count, 64 * 1_024)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(saved["status"] as? String, "completed")
        let trend = try XCTUnwrap(saved["residentTrend"] as? [String: Any])
        XCTAssertEqual(trend["observationsComplete"] as? Bool, true)
        XCTAssertEqual((trend["settledBytes"] as? [NSNumber])?.count, 8)
        XCTAssertEqual((trend["intervalGrowthBytes"] as? [NSNumber])?.count, 8)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GIF-Attribution-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
