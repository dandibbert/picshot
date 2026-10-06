import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import PicShotCore
@testable import PicShot

final class RecordingAndGIFTests: XCTestCase {
    func testRecordingOptionsRejectUnboundedInputs() throws {
        XCTAssertNoThrow(try RecordingOptions().validate())
        XCTAssertThrowsError(try RecordingOptions(frameRate: 0).validate())
        XCTAssertThrowsError(try RecordingOptions(frameRate: 61).validate())
        XCTAssertThrowsError(try RecordingOptions(maximumDuration: .infinity).validate())
        XCTAssertThrowsError(try RecordingOptions(maximumDuration: 3_601).validate())
        XCTAssertThrowsError(try RecordingOptions(maximumFileSize: Int64.max).validate())
        XCTAssertThrowsError(try RecordingOptions(maximumFileSize: 0).validate())
    }

    @MainActor
    func testRegionUsesLocalPointsAndRejectsOutOfBounds() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        XCTAssertEqual(try RecordingService.validatedRegion(nil, bounds: bounds), bounds)
        let selected = CGRect(x: 40, y: 80, width: 200, height: 100)
        XCTAssertEqual(try RecordingService.validatedRegion(selected, bounds: bounds), selected)
        for invalid in [CGRect(x: -1, y: 0, width: 100, height: 100),
                        CGRect(x: 1_900, y: 0, width: 100, height: 100),
                        CGRect(x: 0, y: 0, width: 1, height: 100),
                        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)] {
            XCTAssertThrowsError(try RecordingService.validatedRegion(invalid, bounds: bounds))
        }
    }

    @MainActor
    func testEncodingDimensionsAreEvenRetinaAwareAndBounded() {
        XCTAssertEqual(RecordingService.encodedSize(for: CGSize(width: 200, height: 100), scale: 2), CGSize(width: 400, height: 200))
        XCTAssertEqual(RecordingService.encodedSize(for: CGSize(width: 201, height: 101), scale: 1), CGSize(width: 200, height: 100))
        for input in [CGSize(width: 6_016, height: 3_384), CGSize(width: 8_000, height: 8_000), CGSize(width: 1_800, height: 6_000)] {
            let output = RecordingService.encodedSize(for: input, scale: 2)
            XCTAssertLessThanOrEqual(max(output.width, output.height), 3_840)
            XCTAssertLessThanOrEqual(output.width * output.height, 8_294_400)
            XCTAssertEqual(Int(output.width) % 2, 0)
            XCTAssertEqual(Int(output.height) % 2, 0)
        }
    }

    @MainActor
    func testIdleStopAndRepeatedCancellationLeaveCleanState() async {
        let recorder = RecordingService()
        await recorder.cancel()
        await recorder.cancel()
        do { _ = try await recorder.stop(); XCTFail("Stopping an idle recorder must fail") }
        catch { XCTAssertTrue(error is RecordingError) }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isStopping)
        XCTAssertEqual(recorder.elapsed, 0)
        XCTAssertNil(recorder.outputURL)
    }

    func testActualRecordingWriterExtendsStaticScreenAndFinalizesMP4() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try RecordingWriter(size: CGSize(width: 40, height: 24), options: .init(), outputDirectory: root) { _ in }
        let frame = try makeScreenSample()
        writer.queue.sync { writer.consume(frame, of: .screen) }
        // A static desktop sends no subsequent complete frames. The writer must
        // nevertheless preserve wall-clock video duration at stop.
        try await Task.sleep(nanoseconds: 220_000_000)
        let url = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThanOrEqual(duration, 0.18)
        XCTAssertLessThan(duration, 5)
        let image = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 24)
        let saved = try await writer.publishFinished(mediaURL: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        // Discarding a now-finished writer must never delete the promoted movie.
        try await writer.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testActualRecordingWriterNoFramesAndCancellationArchiveOriginals() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try RecordingWriter(size: CGSize(width: 40, height: 24), options: .init(), outputDirectory: root) { _ in }
        do { _ = try await writer.finish(); XCTFail("Empty recording must fail") }
        catch RecordingError.noFrames { } catch { XCTFail("Unexpected error: \(error)") }
        try await writer.discard()
        try await writer.discard()
        try assertArchivedRecordings(in: root, count: 1)
        let cancelled = try RecordingWriter(size: CGSize(width: 40, height: 24), options: .init(), outputDirectory: root) { _ in }
        let frame = try makeScreenSample()
        cancelled.queue.sync { cancelled.consume(frame, of: .screen) }
        try await cancelled.discard()
        try assertArchivedRecordings(in: root, count: 2)
    }

    func testRecordingPublicationOwnsOnlyItsStagingDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.mp4")
        let existingData = Data("existing user recording".utf8)
        try existingData.write(to: existing)
        let staging = try RecordingFileStorage.makeStagingDirectory(in: root)
        let source = staging.appendingPathComponent("recording.mp4")
        let data = Data("new finalized recording".utf8)
        try data.write(to: source)
        let saved = try RecordingFileStorage.publish(from: source, in: root)
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(saved.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertEqual(try Data(contentsOf: existing), existingData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testRecordingPublicationRejectsUnownedParentWithoutDeletingAnything() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("keep.mp4")
        let data = Data("user movie".utf8)
        try data.write(to: source)
        XCTAssertThrowsError(try RecordingFileStorage.publish(from: source, in: root))
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRecordingPublicationFailurePreservesStagingForRecovery() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try RecordingFileStorage.makeStagingDirectory(in: root)
        let existing = staging.appendingPathComponent("recording.mp4")
        try Data("recoverable recording".utf8).write(to: existing)
        XCTAssertThrowsError(try RecordingFileStorage.publish(from: staging.appendingPathComponent("missing.mp4"), in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }

    func testGIFFrameLimitPreservesDuration() throws {
        let plan = try GIFFramePlan(duration: 5.23, options: GIFExportOptions(frameRate: 30, maximumFrames: 7))
        XCTAssertEqual(plan.frameCount, 7)
        XCTAssertEqual(plan.duration, 5.23, accuracy: 0.0001)
        XCTAssertEqual((0..<plan.frameCount).map { plan.delay(for: $0) }.reduce(0, +), 5.23, accuracy: 0.0001)
        XCTAssertEqual(plan.time(for: 0), 0)
        XCTAssertLessThan(plan.time(for: plan.frameCount - 1), plan.duration)
        XCTAssertTrue((0..<plan.frameCount).allSatisfy { plan.delay(for: $0) >= 0.02 })
    }

    func testGIFPlanTrimsDurationAndHandlesVeryShortClip() throws {
        let plan = try GIFFramePlan(duration: 120, options: .init())
        XCTAssertEqual(plan.duration, 30)
        XCTAssertEqual(plan.frameCount, 360)
        let tiny = try GIFFramePlan(duration: 0.001, options: .init())
        XCTAssertEqual(tiny.frameCount, 1)
        XCTAssertEqual(tiny.delay(for: 0), 0.02)
        XCTAssertThrowsError(try GIFFramePlan(duration: .infinity, options: .init()))
        XCTAssertThrowsError(try GIFFramePlan(duration: 0, options: .init()))
    }

    func testGIFOptionsRejectUnsafeBounds() {
        XCTAssertThrowsError(try GIFExportOptions(frameRate: .nan).validate())
        XCTAssertThrowsError(try GIFExportOptions(maximumDimension: Int.max).validate())
        XCTAssertThrowsError(try GIFExportOptions(maximumDuration: 61).validate())
        XCTAssertThrowsError(try GIFExportOptions(maximumFrames: 601).validate())
        XCTAssertThrowsError(try GIFExportOptions(maximumFrames: 0).validate())
    }

    func testGIFExportProducesReadableFramesAndPreservesPlaybackTime() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let destination = directory.appendingPathComponent("result.gif")
        let result = try await GIFExporter.export(sourceURL: source, destinationURL: destination,
            options: GIFExportOptions(frameRate: 12, maximumDimension: 24, maximumFrames: 3))
        XCTAssertEqual(result, destination)
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 3)
        var duration: Double = 0
        for index in 0..<CGImageSourceGetCount(gif) {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, index, nil))
            XCTAssertLessThanOrEqual(frame.width, 24)
            XCTAssertLessThanOrEqual(frame.height, 24)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [CFString: Any])
            let gifProperties = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            duration += try XCTUnwrap(gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        }
        XCTAssertEqual(duration, 1, accuracy: 0.02)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".picshot-") })
        XCTAssertLessThan(try Data(contentsOf: result).count, GIFExporter.maximumOutputBytes)
    }

    func testGIFExportNeverOverwritesAnExistingFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let destination = directory.appendingPathComponent("existing.gif")
        let original = Data("original file".utf8)
        try original.write(to: destination)
        do {
            _ = try await GIFExporter.export(sourceURL: source, destinationURL: destination)
            XCTFail("Existing destination must not be overwritten")
        } catch GIFExportError.destinationExists { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testCancelledGIFDoesNotPublishPartialOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let destination = directory.appendingPathComponent("cancelled.gif")
        let task = Task {
            try await GIFExporter.export(sourceURL: source, destinationURL: destination)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled export should fail") }
        catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".picshot-") })
    }

    private func assertArchivedRecordings(in root: URL, count: Int) throws {
        let stages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".recording-") }
        XCTAssertEqual(stages.count, count)
        for stage in stages {
            let journal = try JSONDecoder().decode(RecordingRecoveryJournal.self,
                from: Data(contentsOf: stage.appendingPathComponent(RecordingRecoveryJournal.filename)))
            XCTAssertEqual(journal.phase, .discarded)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent(journal.mediaFilename).path))
        }
        let scan = try RecordingRecoveryStore(root: root).discover()
        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertTrue(scan.warnings.isEmpty)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeScreenSample() throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 40, 24, kCVPixelFormatType_32BGRA, attributes, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)), 0x7F, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &result), noErr)
        let sample = try XCTUnwrap(result)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return sample
    }

    /// A tiny real H.264 fixture makes GIF verification independent of screen/TCC.
    private func makeMovie(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 40, AVVideoHeightKey: 24
        ])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 40, kCVPixelBufferHeightKey as String: 24,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingError.noFrames }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? RecordingError.noFrames }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 40, 24, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
            XCTAssertEqual(status, kCVReturnSuccess)
            let pixel = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 40, height: 24,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(red: Double(index) / 12, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 24))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 12)) else {
                throw writer.error ?? RecordingError.noFrames
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? RecordingError.noFrames }
        return url
    }
}
