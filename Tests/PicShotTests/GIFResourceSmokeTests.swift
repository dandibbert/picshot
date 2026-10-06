import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PicShot

final class GIFResourceSmokeTests: XCTestCase {
    func testInstalledProfileExercisesFullDefaultFrameCountWithBoundedSizes() throws {
        let profile = GIFResourceSmokeFixture.Profile.installedSmoke
        XCTAssertEqual(profile.frameCount, 360)
        XCTAssertEqual(profile.duration, 30)
        XCTAssertEqual(profile.width, 640)
        XCTAssertEqual(profile.height, 360)
        XCTAssertEqual(profile.outputDimension, 480)
        XCTAssertEqual(profile.warmupCount, 1)
        XCTAssertEqual(profile.measuredCount, 4)
        XCTAssertEqual(profile.cancelAfterFrames, 36)
        XCTAssertNoThrow(try profile.options.validate())
        XCTAssertEqual(try GIFFramePlan(duration: profile.duration, options: profile.options).frameCount, profile.frameCount)
    }

    func testHighResolutionCaseKeepsMaximumDimensionAndExistingEnvelopes() throws {
        let profile = GIFResourceSmokeFixture.Profile.highResolution
        XCTAssertEqual(profile.width, 1_920)
        XCTAssertEqual(profile.height, 1_080)
        XCTAssertEqual(profile.frameCount, 12)
        XCTAssertEqual(profile.outputDimension, 1_920)
        XCTAssertEqual(profile.duration, 1)
        XCTAssertNoThrow(try profile.options.validate())
        let reading = GIFResourceSingleExportAssessment(baseline: 1_000, peak: 1_500, settled: 900)
        XCTAssertEqual(reading.withinEnvelope, true)
        XCTAssertEqual(reading.finalSettledGrowthBytes, -100)
        XCTAssertEqual(reading.configuredPeakGrowthLimitBytes, 384 * 1_024 * 1_024)
        XCTAssertEqual(reading.configuredFinalGrowthLimitBytes, 96 * 1_024 * 1_024)
        XCTAssertNil(GIFResourceSingleExportAssessment(baseline: nil, peak: 1, settled: 1).withinEnvelope)
        XCTAssertEqual(GIFResourceSingleExportAssessment(baseline: 0, peak: 500 * 1_024 * 1_024, settled: 0).withinEnvelope, false)
    }

    func testMissingMemoryReadingsAreNotFabricatedAsZeroOrPassingEvidence() throws {
        var statistics = GIFResourceMemoryStatistics()
        statistics.record(.init(residentBytes: nil, physicalFootprintBytes: nil))
        XCTAssertEqual(statistics.residentSampleCount, 0)
        XCTAssertEqual(statistics.physicalFootprintSampleCount, 0)
        XCTAssertEqual(statistics.failedResidentSampleCount, 1)
        XCTAssertEqual(statistics.failedPhysicalFootprintSampleCount, 1)
        XCTAssertNil(statistics.peakResidentBytes)
        XCTAssertNil(statistics.peakPhysicalFootprintBytes)
        let assessment = GIFResourceSmokeFixture.assessment(baseline: nil, settled: [nil, nil], peaks: [nil, nil])
        XCTAssertFalse(assessment.observationsComplete)
        XCTAssertNil(assessment.withinEnvelope)
        XCTAssertNil(assessment.finalSettledGrowthBytes)
        XCTAssertNoThrow(try JSONEncoder().encode(assessment))
    }

    func testMemoryAggregationKeepsActualPeaksAndIndependentAvailability() {
        var statistics = GIFResourceMemoryStatistics()
        statistics.record(.init(residentBytes: 1_000, physicalFootprintBytes: 900))
        statistics.record(.init(residentBytes: nil, physicalFootprintBytes: 1_500), isTimer: true)
        statistics.record(.init(residentBytes: 2_000, physicalFootprintBytes: nil))
        statistics.record(.init(residentBytes: 500, physicalFootprintBytes: 800))
        XCTAssertEqual(statistics.residentSampleCount, 3)
        XCTAssertEqual(statistics.physicalFootprintSampleCount, 3)
        XCTAssertEqual(statistics.timerTickCount, 1)
        XCTAssertEqual(statistics.boundarySampleCount, 3)
        XCTAssertEqual(statistics.peakResidentBytes, 2_000)
        XCTAssertEqual(statistics.peakPhysicalFootprintBytes, 1_500)
        XCTAssertEqual(statistics.failedResidentSampleCount, 1)
        XCTAssertEqual(statistics.failedPhysicalFootprintSampleCount, 1)
    }

    func testPlateauAssessmentPreservesNegativeGrowthAndRejectsLargeGrowth() {
        let plateau = GIFResourceSmokeFixture.assessment(baseline: 1_000, settled: [950, 925, 900, 910],
                                                       peaks: [1_600, 1_700, 1_500, 1_650])
        XCTAssertTrue(plateau.observationsComplete)
        XCTAssertEqual(plateau.withinEnvelope, true)
        XCTAssertEqual(plateau.sampledPeakGrowthBytes, 700)
        XCTAssertEqual(plateau.finalSettledGrowthBytes, -90)
        XCTAssertEqual(plateau.lastIntervalSettledGrowthBytes, 10)
        XCTAssertEqual(plateau.settledRangeBytes, 50)
        let mib: UInt64 = 1_024 * 1_024
        let growth = GIFResourceSmokeFixture.assessment(baseline: mib, settled: [mib, 120 * mib],
                                                      peaks: [30 * mib, 500 * mib])
        XCTAssertEqual(growth.withinEnvelope, false)
        XCTAssertEqual(growth.finalSettledGrowthBytes, Int64(119 * mib))
        let lateGrowth = GIFResourceSmokeFixture.assessment(baseline: mib, settled: [mib, 35 * mib],
                                                          peaks: [mib, 35 * mib])
        XCTAssertEqual(lateGrowth.withinEnvelope, false)
        XCTAssertEqual(lateGrowth.lastIntervalSettledGrowthBytes, Int64(34 * mib))
    }

    func testIncompleteOrUnrepresentableAssessmentsCannotPass() {
        let cases: [(UInt64?, [UInt64?], [UInt64?])] = [
            (100, [100], [100]), (100, [100, nil], [100, 100]),
            (100, [100, 100], [100, nil]), (100, [100, 100], []),
            (UInt64.max, [100, 100], [100, 100]), (100, [100, UInt64.max], [100, 100])
        ]
        for inputs in cases {
            let value = GIFResourceSmokeFixture.assessment(baseline: inputs.0, settled: inputs.1, peaks: inputs.2)
            XCTAssertFalse(value.observationsComplete)
            XCTAssertNil(value.withinEnvelope)
        }
    }

    func testValidatorRejectsWrongFrameCountDimensionsAndUnchangingFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GIF-Invalid-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = GIFResourceSmokeFixture.Profile.quickTest
        let plan = try GIFFramePlan(duration: profile.duration, options: profile.options)
        let cases = [("count", 96, 54, 1), ("dimensions", 64, 64, 24), ("unchanging", 96, 54, 24)]
        for (name, width, height, count) in cases {
            let url = root.appendingPathComponent(name + ".gif")
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try XCTUnwrap(context.makeImage())
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil))
            for index in 0..<count {
                let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: plan.delay(for: index),
                    kCGImagePropertyGIFUnclampedDelayTime: plan.delay(for: index)]] as CFDictionary
                CGImageDestinationAddImage(destination, image, properties)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            XCTAssertThrowsError(try GIFResourceSmokeFixture.validate(output: url, profile: profile, plan: plan), name)
        }
    }

    func testCurrentProcessRSSIsReadableAndPhysicalFootprintIsOptional() throws {
        let reading = GIFResourceMemoryReading.current()
        XCTAssertGreaterThan(try XCTUnwrap(reading.residentBytes), 0)
        if let footprint = reading.physicalFootprintBytes { XCTAssertGreaterThan(footprint, 0) }
        XCTAssertNoThrow(try JSONEncoder().encode(reading))
    }

    /// Real AVFoundation + ImageIO, but a separate short profile. This checks the
    /// harness/cancellation/cleanup without multiplying the installed 360-frame
    /// workload into every XCTest run. Only installed smoke establishes its
    /// full profile's measured resource evidence on the tested architecture.
    func testShortFixtureExportsChangingFramesCancelsInFlightAndWritesEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GIF-Resource-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await GIFResourceSmokeFixture.verify(evidenceDirectory: root, profile: .quickTest)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["profile"] as? String, "unit-test-short")
        XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
        XCTAssertEqual(report["captureStarted"] as? Bool, false)
        XCTAssertEqual(report["audioStarted"] as? Bool, false)
        XCTAssertFalse(Task.isCancelled, "Deliberate child export cancellation must not cancel the test/smoke caller")
        let exports = try XCTUnwrap(report["exports"] as? [[String: Any]])
        XCTAssertEqual(exports.count, 2)
        for run in exports {
            let output = try XCTUnwrap(run["output"] as? [String: Any])
            XCTAssertEqual(output["framesDecoded"] as? Int, 24)
            XCTAssertEqual(output["dimensions"] as? [String], ["96x54"])
            XCTAssertEqual(output["distinctDecodedThumbnailFingerprints"] as? Int, 24)
            XCTAssertEqual(run["partialFilesRemaining"] as? Int, 0)
            XCTAssertNotNil(run["immediatelyAfterExport"] as? [String: Any])
            XCTAssertNotNil(run["settledBeforeValidation"] as? [String: Any])
            XCTAssertNotNil(run["immediatelyAfterValidation"] as? [String: Any])
            XCTAssertNotNil(run["validationMemory"] as? [String: Any])
            let memory = try XCTUnwrap(run["memory"] as? [String: Any])
            XCTAssertGreaterThan(try XCTUnwrap(memory["residentSampleCount"] as? Int), 0)
            XCTAssertGreaterThan(try XCTUnwrap(memory["peakResidentBytes"] as? NSNumber).uint64Value, 0)
        }
        let cancellation = try XCTUnwrap(report["cancellation"] as? [String: Any])
        XCTAssertEqual(cancellation["cancellationRequested"] as? Bool, true)
        XCTAssertEqual(cancellation["cancellationObserved"] as? Bool, true)
        XCTAssertEqual(cancellation["parentObservedFrameProgressCount"] as? Int, 4)
        XCTAssertEqual(cancellation["destinationAbsent"] as? Bool, true)
        XCTAssertEqual(cancellation["partialFilesRemaining"] as? Int, 0)
        let data = try Data(contentsOf: root.appendingPathComponent("gif-resource.json"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(saved["status"] as? String, "passed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["gif-resource.json"])
        XCTAssertLessThan(data.count, 64 * 1_024)
    }
}
