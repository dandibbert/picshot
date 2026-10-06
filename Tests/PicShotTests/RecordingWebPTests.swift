import XCTest
import Foundation
import PicShotCodecCore
@testable import PicShot

final class RecordingWebPTests: XCTestCase {
    func testOptionalImageIOProbeReportsUnavailableReaderWithoutClaimingAnimationSuccess() {
        let report = RecordingWebPSmokeFixture.imageIOReadProbe(Data("not an image".utf8), expectedFrames: 12, expectedDurationMS: 1_200)
        XCTAssertEqual(report["requiredForExportSuccess"] as? Bool, false)
        XCTAssertEqual(report["animationReadableWithTiming"] as? Bool, false)
        XCTAssertEqual(report["allExpectedFramesDecoded"] as? Bool, false)
        XCTAssertEqual(report["reportedFrameCount"] as? Int, 0)
        XCTAssertTrue(["reader-unavailable", "no-readable-frames"].contains(report["status"] as? String ?? ""))
    }

    func testTrimDecimalBoundariesUseNearestTicksBeforeWebPSourcePreparation() throws {
        for index in 1..<10 {
            let start = Double(index) / 10
            let end = Double(index + 1) / 10
            let range = try VideoTrimRange(start: start, end: end, sourceDuration: 2)
            XCTAssertEqual(range.timeRange.start.value, Int64(index * 60_000))
            XCTAssertEqual(range.timeRange.end.value, Int64((index + 1) * 60_000))
        }
    }

    @MainActor
    func testPreviewWebPOptionsHaveFixedChoicesAndKeepGIFDefaults() throws {
        let model = RecordingPreviewModel(url: URL(fileURLWithPath: "/unused/recording.mp4"))
        defer { model.close() }
        XCTAssertEqual(model.webpOptions.kind, .animation)
        XCTAssertEqual(model.webpOptions.format, .webp)
        XCTAssertEqual(model.webpOptions.quality, 80)
        XCTAssertFalse(model.webpOptions.lossless)
        XCTAssertTrue(model.webpOptions.preserveAlpha)
        XCTAssertEqual(model.webpOptions.animation?.frameRate, 15)
        XCTAssertEqual(model.webpOptions.animation?.maximumDimension, 1_280)
        XCTAssertEqual(model.webpOptions.animation?.maximumFrames, 600)
        XCTAssertEqual(model.webpOptions.animation?.maximumDuration, 60)
        model.webpFrameRate = 24; model.webpMaximumDimension = 640; model.webpLossless = true; model.webpQuality = 95
        try model.webpOptions.validate()
        XCTAssertEqual(model.webpOptions.animation?.frameRate, 24)
        XCTAssertTrue(model.webpOptions.lossless)
        XCTAssertEqual(RecordingPreviewModel.gifOptions.frameRate, 12)
        XCTAssertEqual(RecordingPreviewModel.gifOptions.maximumDuration, 30)
        XCTAssertEqual(RecordingPreviewModel.gifOptions.maximumFrames, 360)
    }

    func testTrimStagingIsPrivateRegardlessOfDestinationDirectory() throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try Data("source".utf8).write(to: source)
        let destination = try VideoExportDestination(url: directory.appendingPathComponent("export.webp"), preserving: source)
        let staging = try destination.makeStagingDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testWebPRejectsOversizedSelectionBeforeCreatingStageOrTouchingOriginal() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let original = Data("original preserved".utf8)
        try original.write(to: source)
        let destination = try VideoExportDestination(url: directory.appendingPathComponent("too-long.webp"), preserving: source)
        let range = try VideoTrimRange(start: 0, end: 61, sourceDuration: 61)
        do {
            _ = try await VideoTrimExporter.exportWebP(sourceURL: source, destination: destination, range: range,
                options: CodecExportRequest(kind: .animation, format: .webp, animation: .init()))
            XCTFail("An oversized selection must not be silently shortened")
        } catch VideoTrimError.webpDurationLimit(let duration) { XCTAssertEqual(duration, 60) }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.mp4"])
    }

    func testWebPRejectsStillOrAVIFRequestsAndPreCancelledTasks() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let original = Data("original preserved".utf8)
        try original.write(to: source)
        let destination = try VideoExportDestination(url: directory.appendingPathComponent("export.webp"), preserving: source)
        let range = try VideoTrimRange(start: 0, end: 1, sourceDuration: 1)
        for options in [CodecExportRequest(format: .webp), .init(kind: .animation, format: .avif, animation: .init())] {
            do {
                _ = try await VideoTrimExporter.exportWebP(sourceURL: source, destination: destination, range: range, options: options)
                XCTFail("Incorrect codec kind must be rejected")
            } catch let failure as CodecExportFailure { XCTAssertEqual(failure.code, .invalidOptions) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VideoTrimExporter.exportWebP(sourceURL: source, destination: destination, range: range,
                options: .init(kind: .animation, format: .webp, animation: .init()))
        }
        do { _ = try await task.value; XCTFail("Pre-cancelled WebP export cannot start") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.mp4"])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Recording-WebP-Tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
