import XCTest
import Foundation
import CoreMedia
@testable import PicShot

@MainActor
final class RecordingInputExportTests: XCTestCase {
    private typealias Oracle = RecordingInputExportOracle

    func testInteriorSelectionAndSamplingIncludeExpiryResumeAndFrozenStop() throws {
        let range = try VideoTrimRange(start: Oracle.start, end: Oracle.end, sourceDuration: 2.2)
        XCTAssertGreaterThan(range.start, 0)
        XCTAssertLessThan(range.end, 2.2)
        XCTAssertEqual(range.duration, 2.05, accuracy: 0.000001)
        XCTAssertEqual(Oracle.sampleTime(0).value, 0)
        XCTAssertEqual(Oracle.sampleTime(40).seconds + range.start, 2.1, accuracy: 0.000001)
        let plan = try GIFFramePlan(duration: range.duration, options: RecordingInputExportSmokeFixture.gifOptions)
        XCTAssertEqual(plan.frameCount, 41)
        for index in 0..<41 {
            XCTAssertEqual(plan.samplingTime(for: index), Oracle.sampleTime(index))
            XCTAssertEqual(plan.delay(for: index) * 1_000, Double(Oracle.delayMS(index, format: .gif)), accuracy: 0.0001)
            XCTAssertEqual(Oracle.delayMS(index, format: .webpLossless), 50)
            XCTAssertEqual(Oracle.delayMS(index, format: .webpLossy), 50)
        }
        XCTAssertEqual((0..<41).reduce(0) { $0 + Oracle.delayMS($1, format: .gif) }, 2_050)
        for lossless in [true, false] {
            let options = RecordingInputExportSmokeFixture.options(lossless: lossless)
            try options.validate()
            XCTAssertEqual(options.animation?.maximumFrames, 41)
            XCTAssertEqual(options.animation?.maximumDimension, 320)
            XCTAssertEqual(options.animation?.maximumDuration, 3)
            XCTAssertEqual(options.lossless, lossless)
        }
    }

    func testPixelOracleUsesTopDownRGBAAndDetectsEffectRelocationAndExpiry() throws {
        var pixels = raster()
        paint(&pixels, x: 70, y: 95, width: 10, height: 10, color: [230, 170, 40])
        let reference = try observe(pixels)
        XCTAssertEqual(reference.regions["click"]?.yellow.count, 100)
        XCTAssertEqual(reference.regions["click"]?.yellow.x, 74.5)
        XCTAssertEqual(reference.regions["click"]?.yellow.y, 99.5)
        XCTAssertNoThrow(try Oracle.compare(reference, to: reference))
        XCTAssertThrowsError(try Oracle.compare(observe(raster()), to: reference), "Absent click must not pass lossy tolerance")
        var shifted = raster()
        paint(&shifted, x: 85, y: 95, width: 10, height: 10, color: [230, 170, 40])
        XCTAssertThrowsError(try Oracle.compare(observe(shifted), to: reference), "Same color count at wrong location must fail")
        XCTAssertThrowsError(try Oracle.compare(reference, to: observe(raster())), "Expired frame must reject a stale click")
        var reflected = raster()
        paint(&reflected, x: 70, y: 180 - 95 - 10, width: 10, height: 10, color: [230, 170, 40])
        XCTAssertThrowsError(try Oracle.compare(observe(reflected), to: reference), "Vertical reflection must fail")
    }

    func testScalarTimelineRejectsFirstFrameOnlyWrongBoundaryAndMissingResume() throws {
        // Marker-only CMSampleBuffers are control messages, not media frames.
        // Exercise actual CoreMedia buffers without changing this test's ID.
        func marker(duration: CMTime = .invalid, withTiming: Bool = true,
                    pts: CMTime = CMTime(value: 22, timescale: 10)) throws -> CMSampleBuffer {
            var result: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: duration,
                presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            let status = withUnsafePointer(to: &timing) { pointer in
                CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
                    dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
                    sampleCount: 0, sampleTimingEntryCount: withTiming ? 1 : 0,
                    sampleTimingArray: withTiming ? pointer : nil,
                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result)
            }
            XCTAssertEqual(status, noErr)
            return try XCTUnwrap(result)
        }
        // ARM162's source reader emits this unmarked empty buffer before frame 0.
        let initial = try marker(duration: .zero, pts: CMTime(value: 0, timescale: 600))
        XCTAssertTrue(try Oracle.isControlMarker(initial, context: "unmarked-initial-control"))
        let initialDiagnostic = Oracle.sampleTimingDescription(initial, route: "source", phase: "compressed",
            buffer: 0, media: 0, expected: 22)
        XCTAssertTrue(initialDiagnostic.contains("samples=0 sampleBytes=0 dataBytes=0 imagePresent=false"))
        XCTAssertTrue(initialDiagnostic.contains("sampleDuration=0/1:flags=1"))
        XCTAssertTrue(initialDiagnostic.contains("empty=absent endsPrevious=absent permanentEmpty=absent"))
        let empty = try marker()
        XCTAssertTrue(try Oracle.isControlMarker(empty, context: "unmarked"))
        CMSetAttachment(empty, key: kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertTrue(try Oracle.isControlMarker(empty, context: "end-duration-marker"))
        let diagnostic = Oracle.sampleTimingDescription(empty, route: "source", phase: "compressed",
            buffer: 22, media: 22, expected: 22)
        XCTAssertTrue(diagnostic.contains("route=source phase=compressed buffer=22 media=22/22"))
        XCTAssertTrue(diagnostic.contains("samples=0 sampleBytes=0 dataBytes=0"))
        XCTAssertTrue(diagnostic.contains("endsPrevious=true"))
        XCTAssertTrue(diagnostic.contains("timingEntries=1 timingStatus=0"))
        XCTAssertTrue(diagnostic.contains("sampleDuration=0/0:flags=0"), "The raw invalid timing entry must remain visible")
        CMSetAttachment(empty, key: kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
                        value: NSNumber(value: 2), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.isControlMarker(empty, context: "non-Boolean-marker"))
        CMSetAttachment(empty, key: kCMSampleBufferAttachmentKey_EmptyMedia,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.isControlMarker(empty, context: "mixed-malformed-marker"))
        let gap = try marker(duration: CMTime(value: 1, timescale: 10))
        XCTAssertThrowsError(try Oracle.isControlMarker(gap, context: "unmarked-playback-gap"))
        CMSetAttachment(gap, key: kCMSampleBufferAttachmentKey_EmptyMedia,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try Oracle.isControlMarker(gap, context: "actual-playback-gap"),
                             "A positive empty-media interval must never be hidden")
        let timingFree = try marker(withTiming: false)
        CMSetAttachment(timingFree, key: kCMSampleBufferAttachmentKey_PermanentEmptyMedia,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertTrue(try Oracle.isControlMarker(timingFree, context: "timing-free-end-marker"))
        XCTAssertEqual(CMSampleBufferInvalidate(timingFree), noErr)
        XCTAssertThrowsError(try Oracle.isControlMarker(timingFree, context: "invalidated-marker"))

        var frames = (0..<41).map { index in
            Oracle.Comparison(index: index, requestedSeconds: Double(index) / 20,
                actualSeconds: Double(index / 2) / 10, sourceIndex: index / 2 + 1,
                delayMS: 50, regionMeanAbsoluteError: [:])
        }
        XCTAssertNoThrow(try Oracle.verifyTimeline(frames))
        XCTAssertThrowsError(try Oracle.verifyTimeline(Array(frames.prefix(1))))
        frames[40] = .init(index: 40, requestedSeconds: 2, actualSeconds: 1.9, sourceIndex: 20, delayMS: 50, regionMeanAbsoluteError: [:])
        XCTAssertThrowsError(try Oracle.verifyTimeline(frames), "Missing frozen Stop endpoint must fail")
        frames[40] = .init(index: 40, requestedSeconds: 2, actualSeconds: 2, sourceIndex: 21, delayMS: 50, regionMeanAbsoluteError: [:])
        for index in [38, 39] {
            frames[index] = .init(index: index, requestedSeconds: Double(index) / 20, actualSeconds: 1.8, sourceIndex: 19, delayMS: 50, regionMeanAbsoluteError: [:])
        }
        XCTAssertThrowsError(try Oracle.verifyTimeline(frames), "Missing post-pause clear frame must fail")
    }

    func testPixelComparisonRejectsChangedGlyphShapeAndOutOfRegionArtifacts() throws {
        let reference = raster()
        XCTAssertNoThrow(try reference.withUnsafeBufferPointer {
            try Oracle.pixelErrors($0, reference: reference, limit: 9, canvasLimit: 3)
        })
        var changed = reference
        paint(&changed, x: 118, y: 12, width: 84, height: 32, color: [240, 240, 240])
        XCTAssertThrowsError(try changed.withUnsafeBufferPointer {
            try Oracle.pixelErrors($0, reference: reference, limit: 18, canvasLimit: 6)
        })
        changed = reference
        // A large unexpected block outside all effect and anchor ROIs must be
        // caught by the whole-canvas comparison, not feature-count agreement.
        paint(&changed, x: 5, y: 5, width: 100, height: 60, color: [240, 0, 0])
        XCTAssertThrowsError(try changed.withUnsafeBufferPointer {
            try Oracle.pixelErrors($0, reference: reference, limit: 18, canvasLimit: 6)
        })
    }

    func testFixtureRefusesExistingDerivedWitnessBeforeReadingOrExportingSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in Oracle.mediaNames + [Oracle.reportName, Oracle.independentReportName] {
            let destination = directory.appendingPathComponent(name), sentinel = Data("owned elsewhere".utf8)
            try sentinel.write(to: destination)
            do { _ = try await RecordingInputExportSmokeFixture.verify(evidenceDirectory: directory); XCTFail("Existing derived witness accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Refusing to replace")) }
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [name])
            try FileManager.default.removeItem(at: destination)
        }
    }

    func testFixtureRequiresAcceptedOriginalReportBeforeLaunchingHelpers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prior = directory.appendingPathComponent("recording-input.json")
        try JSONSerialization.data(withJSONObject: ["status": "failed", "decodedFrames": 22]).write(to: prior)
        do { _ = try await RecordingInputExportSmokeFixture.verify(evidenceDirectory: directory); XCTFail("Failed original evidence accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("original input fixture must pass")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording-input.json"])
    }

    func testBoundedEvidenceRejectsSymlinksAndOversizedFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source"), alias = directory.appendingPathComponent("alias")
        try Data(repeating: 1, count: 33).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try Oracle.boundedData(alias))
        XCTAssertThrowsError(try Oracle.boundedData(source, maximum: 32))
        XCTAssertEqual(try Oracle.boundedData(source, maximum: 33).count, 33)
    }

    /// Native write/trim/decode test uses actual RecordingWriter + compositor
    /// and AVAssetExportSession. Signed animation helpers are installed-only.
    func testAuthoredInputTrimPreservesAllSelectedPixelsAndPacketBoundaries() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await RecordingInputSmokeFixture.verify(evidenceDirectory: directory)
        let sourceURL = directory.appendingPathComponent("recording-input.mp4")
        let originalHash = try Oracle.hash(sourceURL)
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        let original = try await Oracle.movie(sourceURL, selected: false, deadline: deadline)
        let output = directory.appendingPathComponent(Oracle.mediaNames[0])
        let range = try VideoTrimRange(start: Oracle.start, end: Oracle.end, sourceDuration: 2.2)
        _ = try await VideoTrimExporter.export(sourceURL: sourceURL, destinationURL: output, range: range)
        let selected = try await Oracle.movie(output, selected: true, source: original, deadline: deadline)
        XCTAssertEqual(selected.frameCount, 21)
        XCTAssertEqual(selected.observations.map(\.index), Array(1...21))
        XCTAssertEqual(selected.duration, 2.05, accuracy: 1.0 / 600)
        XCTAssertEqual(try Oracle.hash(sourceURL), originalHash)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".picshot-") })
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Input-Derived-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private func raster() -> [UInt8] {
        var pixels = [UInt8](repeating: 40, count: Oracle.width * Oracle.height * 4)
        for offset in stride(from: 3, to: pixels.count, by: 4) { pixels[offset] = 255 }
        return pixels
    }
    private func observe(_ pixels: [UInt8]) throws -> Oracle.Observation {
        try pixels.withUnsafeBufferPointer { try Oracle.observation($0, index: 2, pts: 0.2) }
    }
    private func paint(_ pixels: inout [UInt8], x: Int, y: Int, width: Int, height: Int, color: [UInt8]) {
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                let offset = ((Oracle.height - 1 - row) * Oracle.width + column) * 4
                for channel in 0..<3 { pixels[offset + channel] = color[channel] }
            }
        }
    }
}
