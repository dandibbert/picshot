import XCTest
import Foundation
import Darwin
@testable import PicShot

@MainActor
final class CodecExportAttributionTests: XCTestCase {
    func testProfilesAndWorkloadsAreBoundedAndExplicit() {
        XCTAssertEqual(CodecExportAttributionFixture.Mode.allCases.map(\.rawValue), ["export-only", "decode-only", "combined"])
        XCTAssertEqual(CodecExportAttributionFixture.Profile.installed.width, 768)
        XCTAssertEqual(CodecExportAttributionFixture.Profile.installed.height, 576)
        XCTAssertEqual(CodecExportAttributionFixture.Profile.installed.warmupCycles, 2)
        XCTAssertEqual(CodecExportAttributionFixture.Profile.installed.measuredCycles, 12)
        XCTAssertEqual(CodecExportAttributionFixture.Profile.quickTest.width, 160)
        XCTAssertEqual(CodecExportAttributionFixture.Profile.quickTest.height, 120)
        XCTAssertEqual(CodecExportAttributionFixture.Profile.quickTest.warmupCycles, 2)
        XCTAssertEqual(CodecExportAttributionFixture.Profile.quickTest.measuredCycles, 3)
        XCTAssertLessThanOrEqual(CodecExportAttributionFixture.Profile.installed.deadlineSeconds, 480)
        XCTAssertLessThanOrEqual(CodecExportAttributionFixture.Profile.quickTest.deadlineSeconds, 90)
    }

    func testTrendPreservesSignedGrowthAndExactlyThreeLateIntervals() throws {
        let trend = CodecAttributionTrend(baseline: 100, settled: [110, 120, 115, 130, 129], peaks: [121, 131, 126, 141, 140])
        XCTAssertTrue(trend.observationsComplete)
        XCTAssertEqual(trend.baselineBytes, 100)
        XCTAssertEqual(trend.endBytes, 129)
        XCTAssertEqual(trend.sampledPeakBytes, 141)
        XCTAssertEqual(trend.intervalGrowthBytes, [10, 10, -5, 15, -1])
        XCTAssertEqual(trend.finalGrowthBytes, 29)
        XCTAssertEqual(trend.sampledPeakGrowthBytes, 41)
        XCTAssertEqual(trend.lastThreeIntervalGrowthBytes, [-5, 15, -1])
        XCTAssertEqual(trend.lastThreeIntervalsTotalGrowthBytes, 9)
        let three = CodecAttributionTrend(baseline: 100, settled: [99, 97, 94], peaks: [100, 100, 98])
        XCTAssertEqual(three.lastThreeIntervalGrowthBytes, [-1, -2, -3])
        XCTAssertEqual(three.lastThreeIntervalsTotalGrowthBytes, -6)
        let short = CodecAttributionTrend(baseline: 100, settled: [90, 80], peaks: [100, 90])
        XCTAssertNil(short.lastThreeIntervalGrowthBytes)
        XCTAssertNil(short.lastThreeIntervalsTotalGrowthBytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trend)) as? [String: Any])
        XCTAssertNil(json["leakDetected"])
        XCTAssertNil(json["withinEnvelope"])
        XCTAssertNil(json["plateau"])
    }

    func testMissingOrUnrepresentableSamplesNeverBecomeZeroGrowth() {
        let cases: [(UInt64?, [UInt64?], [UInt64?])] = [
            (nil, [1], [1]), (1, [], []), (1, [nil], [1]), (1, [1], [nil]),
            (1, [1, 2], [2]), (UInt64.max, [1], [1]), (1, [UInt64.max], [1]), (1, [1], [UInt64.max])
        ]
        for (baseline, settled, peaks) in cases {
            let trend = CodecAttributionTrend(baseline: baseline, settled: settled, peaks: peaks)
            XCTAssertFalse(trend.observationsComplete)
            XCTAssertNil(trend.intervalGrowthBytes)
            XCTAssertNil(trend.lastThreeIntervalGrowthBytes)
            XCTAssertNil(trend.finalGrowthBytes)
        }
    }

    func testEnvironmentRoutingIsExplicitAndRejectsUnknownValuesWithoutClaimingProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
        let absent = try await CodecExportAttributionFixture.runIfRequested(evidenceDirectory: directory, environment: [:])
        XCTAssertNil(absent)
        for environment in [
            ["PICSHOT_CODEC_ATTRIBUTION_MODE": "unknown"],
            ["PICSHOT_CODEC_ATTRIBUTION_MODE": "combined", "PICSHOT_CODEC_ATTRIBUTION_FORMAT": "png"],
            ["PICSHOT_CODEC_ATTRIBUTION_MODE": "prepare-inputs", "PICSHOT_CODEC_ATTRIBUTION_PROFILE": "unbounded"]
        ] {
            do {
                _ = try await CodecExportAttributionFixture.runIfRequested(evidenceDirectory: directory, environment: environment)
                XCTFail("Invalid diagnostic selectors were accepted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Codec attribution")) }
        }
    }

    /// Structural integration only: actual signed helper, never a mock, seven
    /// separate native app processes, and the tiny profile. Its measurements
    /// are not installed 768x576 memory acceptance or a leak/no-leak verdict.
    func testFreshProcessMatrixUsesRealHelpersAndIndependentImageIODecodes() async throws {
        let app = try CodecProcessTestApplication.make()
        defer { app.cleanup() }
        let evidence = app.root.appendingPathComponent("attribution-evidence", isDirectory: true)
        let preparationDirectory = evidence.appendingPathComponent("prepared", isDirectory: true)
        let preparation = try await launch(app: app, directory: preparationDirectory, mode: "prepare-inputs")
        XCTAssertEqual(preparation["status"] as? String, "prepared")
        let inputs = try XCTUnwrap(preparation["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 2)
        var processIDs = Set<Int>()
        processIDs.insert(try XCTUnwrap(preparation["processIdentifier"] as? Int))
        for format in ["webp", "avif"] {
            let entry = try XCTUnwrap(inputs.first { $0["format"] as? String == format })
            let expectedSourceSHA = try XCTUnwrap(entry["sourceSHA256"] as? String)
            for mode in CodecExportAttributionFixture.Mode.allCases {
                let directory = evidence.appendingPathComponent("\(format)-\(mode.rawValue)", isDirectory: true)
                let report = try await launch(app: app, directory: directory, mode: mode.rawValue, format: format,
                    inputDirectory: mode == .decodeOnly ? preparationDirectory : nil)
                XCTAssertEqual(report["status"] as? String, "observed", "\(format) \(mode.rawValue)")
                XCTAssertTrue(processIDs.insert(try XCTUnwrap(report["processIdentifier"] as? Int)).inserted)
                XCTAssertEqual(report["mode"] as? String, mode.rawValue)
                XCTAssertEqual(report["format"] as? String, format)
                XCTAssertEqual(report["profile"] as? String, "unit-160x120")
                XCTAssertEqual(report["warmupCycles"] as? Int, 2)
                XCTAssertEqual(report["measuredCycles"] as? Int, 3)
                XCTAssertEqual(report["controllerCreationCount"] as? Int, 0)
                XCTAssertEqual(report["totalExports"] as? Int, mode == .decodeOnly ? 0 : 5)
                XCTAssertEqual(report["totalIndependentDecodes"] as? Int, mode == .exportOnly ? 0 : 5)
                XCTAssertEqual(report["fixtureEncodingTasksStarted"] as? Int, mode == .decodeOnly ? 0 : 5)
                XCTAssertEqual(report["fixtureEncodingTasksCompleted"] as? Int, mode == .decodeOnly ? 0 : 5)
                XCTAssertEqual(report["fixtureEncodingTasksActive"] as? Int, 0)
                XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
                XCTAssertEqual(report["activeControllersAfterAllCycles"] as? Int, 0)
                XCTAssertEqual(report["queuedOrRunningJobsAfterAllCycles"] as? Int, 0)
                XCTAssertEqual(report["captureStarted"] as? Bool, false)
                XCTAssertEqual(report["mockedCodec"] as? Bool, false)
                let warmups = try XCTUnwrap(report["warmups"] as? [[String: Any]])
                let cycles = try XCTUnwrap(report["cycles"] as? [[String: Any]])
                XCTAssertEqual(warmups.count, 2); XCTAssertEqual(cycles.count, 3)
                for cycle in warmups + cycles {
                    XCTAssertEqual(cycle["sourceSHA256"] as? String, expectedSourceSHA)
                    XCTAssertEqual((cycle["encodedSHA256"] as? String)?.count, 64)
                    XCTAssertEqual(cycle["payloadReleased"] as? Bool, true)
                    XCTAssertEqual(cycle["activeControllers"] as? Int, 0)
                    XCTAssertEqual(cycle["fixtureEncodingTasksActive"] as? Int, 0)
                    XCTAssertEqual(cycle["queuedOrRunningJobs"] as? Int, 0)
                    XCTAssertEqual(cycle["helperActive"] as? Bool, false)
                    XCTAssertEqual(cycle["ownedTemporaryFiles"] as? Int, 0)
                    XCTAssertEqual((cycle["settledSamples"] as? [[String: Any]])?.count, 3)
                    let memory = try XCTUnwrap(cycle["memory"] as? [String: Any])
                    XCTAssertGreaterThan(try XCTUnwrap(memory["residentSampleCount"] as? Int), 0)
                    XCTAssertGreaterThan(try XCTUnwrap(memory["physicalFootprintSampleCount"] as? Int), 0)
                    XCTAssertGreaterThan(try XCTUnwrap(memory["timerTickCount"] as? Int), 0)
                    let boundaries = try XCTUnwrap(cycle["boundaries"] as? [[String: Any]])
                    let names = boundaries.compactMap { $0["name"] as? String }
                    XCTAssertTrue(names.contains("afterWorkloadScope"))
                    XCTAssertEqual(names.last, "afterMainQueueDrainAndSettling")
                    if mode == .decodeOnly {
                        XCTAssertNil(cycle["helper"])
                        XCTAssertFalse(names.contains("afterProductionExportAndHelperExit"))
                        XCTAssertEqual(cycle["encodedSHA256"] as? String, entry["sha256"] as? String)
                    } else {
                        let helper = try XCTUnwrap(cycle["helper"] as? [String: Any])
                        XCTAssertEqual(helper["outcome"] as? String, "succeeded")
                        XCTAssertEqual(helper["childExitConfirmed"] as? Bool, true)
                        XCTAssertEqual(helper["temporaryDirectoryRemoved"] as? Bool, true)
                        XCTAssertEqual(helper["terminationStatus"] as? Int, 0)
                        XCTAssertEqual(cycle["sameByteSave"] as? Bool, true)
                    }
                    if mode == .exportOnly {
                        XCTAssertNil(cycle["independentDecode"])
                        XCTAssertFalse(names.contains("independentDecodedPixelsLive"))
                    } else {
                        let decode = try XCTUnwrap(cycle["independentDecode"] as? [String: Any])
                        XCTAssertEqual(decode["allPixelsAndAlphaCompared"] as? Bool, true)
                        XCTAssertEqual(decode["materializedBytes"] as? Int, 160 * 120 * 4)
                        XCTAssertTrue(names.contains("afterIndependentDecodeAutoreleasePool"))
                    }
                }
                for key in ["residentTrend", "physicalFootprintTrend"] {
                    let trend = try XCTUnwrap(report[key] as? [String: Any])
                    XCTAssertEqual(trend["observationsComplete"] as? Bool, true)
                    XCTAssertEqual((trend["lastThreeIntervalGrowthBytes"] as? [Int64])?.count, 3)
                    XCTAssertNil(trend["leakDetected"])
                    XCTAssertNil(trend["withinEnvelope"])
                }
                if mode == .decodeOnly {
                    XCTAssertEqual(report["immutableInputUnchanged"] as? Bool, true)
                    XCTAssertEqual(report["inputPreparationProcessIdentifier"] as? Int, preparation["processIdentifier"] as? Int)
                }
            }
        }
        XCTAssertEqual(processIDs.count, 7)
    }

    private func launch(app: CodecProcessTestApplication, directory: URL, mode: String,
                        format: String? = nil, inputDirectory: URL? = nil) async throws -> [String: Any] {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("launch.json")
        let log = directory.appendingPathComponent("process.log")
        XCTAssertTrue(files.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = app.bundleURL.appendingPathComponent("Contents/MacOS/PicShot")
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        var environment = ["HOME": NSHomeDirectory(), "TMPDIR": files.temporaryDirectory.path, "LANG": "en_US.UTF-8",
            "PICSHOT_SMOKE_TEST": "1", "PICSHOT_SMOKE_REPORT": reportURL.path,
            "PICSHOT_CODEC_ATTRIBUTION_MODE": mode, "PICSHOT_CODEC_ATTRIBUTION_PROFILE": "unit-160x120"]
        environment["PICSHOT_CODEC_ATTRIBUTION_FORMAT"] = format
        environment["PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY"] = inputDirectory?.path
        process.environment = environment
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 100
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if !process.isRunning { process.waitUntilExit() }
            throw CodecProcessTestSupportError.failed("Attribution subprocess exceeded its 100-second deadline; child exit confirmed: \(!process.isRunning)")
        }
        process.waitUntilExit()
        let reportData = try Data(contentsOf: reportURL)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        XCTAssertEqual(process.terminationStatus, 0, String(data: reportData, encoding: .utf8) ?? "Failed attribution process")
        // Full self-Mach backing observations expand the diagnostic metadata.
        // The scalar-width stress test covers 68 full readings plus 64 KiB of
        // other metadata. Check those structural limits on the actual report.
        try assertBoundedMetadata(report)
        XCTAssertLessThan(reportData.count, 512 * 1_024)
        return report
    }

    private func assertBoundedMetadata(_ report: [String: Any]) throws {
        var backingReadings = 0
        func replacingBacking(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                if object["standard"] is [String: Any], object["purgeable"] is [String: Any] {
                    backingReadings += 1
                    return "backing-reading"
                }
                return object.mapValues { replacingBacking($0) }
            }
            if let array = value as? [Any] { return array.map { replacingBacking($0) } }
            return value
        }
        let scalarMetadata = replacingBacking(report)
        XCTAssertLessThanOrEqual(backingReadings, 68)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: scalarMetadata, options: [.prettyPrinted, .sortedKeys]).count, 64 * 1_024)
    }
}
