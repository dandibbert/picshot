import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import PicShot

final class VideoTrimTests: XCTestCase {
    func testRangeRetainsFractionalFrameBoundaries() throws {
        let range = try VideoTrimRange(start: 1.0 / 24, end: 17.0 / 24, sourceDuration: 2)
        XCTAssertEqual(range.start, 1.0 / 24)
        XCTAssertEqual(range.end, 17.0 / 24)
        XCTAssertEqual(range.timeRange.start.seconds, range.start, accuracy: 0.000002)
        XCTAssertEqual(range.timeRange.end.seconds, range.end, accuracy: 0.000002)
        XCTAssertEqual(range.duration, 16.0 / 24, accuracy: 0.000002)
        XCTAssertNoThrow(try VideoTrimRange(start: 0, end: 2, sourceDuration: 2))
    }

    func testRangeRejectsInvalidAndUnrepresentableTimes() {
        for (start, end, duration) in [
            (-1.0, 1.0, 2.0), (1, 1, 2), (2, 1, 2), (0, 3, 2),
            (0, 1, 0), (0, 1, -1), (Double.nan, 1, 2), (0, Double.nan, 2),
            (0, 1, Double.nan), (0, Double.infinity, 2), (0, 1, Double.infinity),
            (0, 1e-12, 2), (0, 1, Double.greatestFiniteMagnitude)
        ] {
            XCTAssertThrowsError(try VideoTrimRange(start: start, end: end, sourceDuration: duration), "\(start), \(end), \(duration)")
        }
    }

    func testTrimPublishesDecodableMP4WithSelectedDurationAndFrames() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let original = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("trimmed.mp4")
        let range = try VideoTrimRange(start: 0.75, end: 1.5, sourceDuration: 2)
        let progress = ProgressRecorder()
        let result = try await VideoTrimExporter.export(sourceURL: source, destinationURL: destination, range: range,
                                                         progress: { progress.record($0) })
        XCTAssertEqual(result, destination)
        let asset = AVURLAsset(url: result)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.75, accuracy: 0.025)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: .zero).image
        let later = try await generator.image(at: CMTime(value: 6, timescale: 12)).image
        XCTAssertEqual(first.width, 64)
        XCTAssertEqual(first.height, 48)
        let firstColor = try pixelColor(first)
        let laterColor = try pixelColor(later)
        XCTAssertGreaterThan(firstColor.red, firstColor.blue + 100, "The selected start should be in the source's red segment")
        XCTAssertGreaterThan(laterColor.blue, laterColor.red + 100, "The later selected frame should be in the blue segment")
        // Decode every output sample without collecting frames in memory.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
            XCTAssertGreaterThanOrEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 0)
            frames += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThanOrEqual(frames, 8)
        XCTAssertLessThanOrEqual(frames, 10)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(progress.values.first, 0)
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertTrue(progress.values.allSatisfy { (0...1).contains($0) })
        try assertNoStaging(in: directory)
    }

    func testSelectedGIFStartsAtChosenRangeAndPreservesItsPlaybackTime() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let destination = try VideoExportDestination(url: directory.appendingPathComponent("selected.gif"), preserving: source)
        let range = try VideoTrimRange(start: 1, end: 1.75, sourceDuration: 2)
        let helper = try GIFProcessTestApplication.make()
        defer { helper.cleanup() }
        let result = try await GIFExporter.withProcessServiceForTesting(helper.service()) {
            try await VideoTrimExporter.exportGIF(sourceURL: source, destination: destination, range: range,
                                                  options: GIFExportOptions(maximumDimension: 64))
        }
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 9)
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(gif) {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, index, nil))
            let color = try pixelColor(frame)
            XCTAssertGreaterThan(color.blue, color.red + 100, "Every selected frame must be from the blue second")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [CFString: Any])
            let gifProperties = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            duration += try XCTUnwrap(gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        }
        XCTAssertEqual(duration, 0.75, accuracy: 0.01)
        try assertNoStaging(in: directory)
    }

    func testGIFFaultInjectedUnconfirmedExitPreservesOnlyItsOwnTrimStaging() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let original = try Data(contentsOf: source)
        let range = try VideoTrimRange(start: 0, end: 0.5, sourceDuration: 2)
        let target = directory.appendingPathComponent("unconfirmed.gif")
        let destination = try VideoExportDestination(url: target, preserving: source)
        // Test the caller's ownership decision; this injected error creates no
        // child and is not evidence of a genuinely unkillable macOS process.
        let service = GIFExportProcessService(configuration: .init(executable: { throw GIFExportProcessError.exitUnconfirmed }))
        do {
            _ = try await GIFExporter.withProcessServiceForTesting(service) {
                try await VideoTrimExporter.exportGIF(sourceURL: source, destination: destination, range: range)
            }
            XCTFail("Unconfirmed helper exit must preserve staged media")
        } catch GIFExportProcessError.exitUnconfirmed { }
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let stages = remaining.filter { $0.lastPathComponent.hasPrefix(".picshot-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(stages.first).appendingPathComponent("selected.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCancellationAfterHelperPublicationDoesNotPublishTrimDestination() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try GIFProcessTestApplication.make()
        defer { helper.cleanup() }
        let service = helper.service()
        let source = try await makeMovie(in: directory)
        let target = directory.appendingPathComponent("cancel-at-publication.gif")
        let destination = try VideoExportDestination(url: target, preserving: source)
        let range = try VideoTrimRange(start: 0, end: 0.5, sourceDuration: 2)
        let cancellation = GIFProcessTestCancellation()
        let operation = InferenceTestOperation {
            try await GIFExporter.withProcessServiceForTesting(service) {
                try await VideoTrimExporter.exportGIF(sourceURL: source, destination: destination, range: range) { value in
                    if value >= 0.99, value < 1 { cancellation.request() }
                }
            }
        }
        cancellation.install { operation.cancel() }
        defer { cancellation.clear(); operation.cancel() }
        do { _ = try await operation.value(timeout: 35, phase: "trim GIF cancellation after helper exit"); XCTFail("Must cancel before final destination publication") }
        catch is CancellationError { }
        XCTAssertTrue(cancellation.wasRequested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let snapshot = await service.snapshot()
        XCTAssertFalse(snapshot.active)
        XCTAssertEqual(snapshot.lastJob?.childExitConfirmed, true)
        try assertNoStaging(in: directory)
    }

    func testGIFRejectsSelectionsBeyondExplicitDurationCap() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.mp4")
        try Data("source remains untouched".utf8).write(to: source)
        let destination = try VideoExportDestination(url: directory.appendingPathComponent("oversized.gif"), preserving: source)
        let range = try VideoTrimRange(start: 0, end: 31, sourceDuration: 31)
        do {
            _ = try await VideoTrimExporter.exportGIF(sourceURL: source, destination: destination, range: range)
            XCTFail("The selection must not be silently truncated to the GIF limit")
        } catch VideoTrimError.gifDurationLimit(let maximum) { XCTAssertEqual(maximum, 30) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.url.path))
        try assertNoStaging(in: directory)
    }

    func testExistingDestinationRequiresExplicitConfirmation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let destination = directory.appendingPathComponent("existing.mp4")
        let oldContents = Data("keep this existing user file".utf8)
        try oldContents.write(to: destination)
        let range = try VideoTrimRange(start: 0.5, end: 1.5, sourceDuration: 2)
        do {
            _ = try await VideoTrimExporter.export(sourceURL: source, destinationURL: destination, range: range)
            XCTFail("Unconfirmed overwrite should fail")
        } catch VideoTrimError.destinationExists { }
        XCTAssertEqual(try Data(contentsOf: destination), oldContents)
        _ = try await VideoTrimExporter.export(sourceURL: source, destinationURL: destination, range: range, overwriteConfirmed: true)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.025)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try assertNoStaging(in: directory)
    }

    func testSourceCannotBeOverwrittenEvenWithConfirmationOrHardLinkAlias() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let original = try Data(contentsOf: source)
        let hardLink = directory.appendingPathComponent("alias.mp4")
        try FileManager.default.linkItem(at: source, to: hardLink)
        let symbolicLink = directory.appendingPathComponent("symlink.mp4")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
        let range = try VideoTrimRange(start: 0.5, end: 1.5, sourceDuration: 2)
        for destination in [source, hardLink, symbolicLink] {
            do {
                _ = try await VideoTrimExporter.export(sourceURL: source, destinationURL: destination, range: range, overwriteConfirmed: true)
                XCTFail("The source and its aliases must be protected")
            } catch VideoTrimError.originalDestination { }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        try assertNoStaging(in: directory)
    }

    func testDestinationAppearingAfterConfirmationCannotBeOverwritten() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try Data("source".utf8).write(to: source)
        let target = directory.appendingPathComponent("new.mp4")
        let destination = try VideoExportDestination(url: target, preserving: source, overwriteConfirmed: true)
        let staging = try destination.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let partial = staging.appendingPathComponent("partial.mp4")
        try Data("exported clip".utf8).write(to: partial)
        let appeared = Data("another app saved here".utf8)
        try appeared.write(to: target)
        XCTAssertThrowsError(try destination.publish(stagedURL: partial))
        XCTAssertEqual(try Data(contentsOf: target), appeared)
    }

    func testChangedConfirmedDestinationIsPreserved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let target = directory.appendingPathComponent("target.mp4")
        try Data("source".utf8).write(to: source)
        try Data("old destination".utf8).write(to: target)
        let destination = try VideoExportDestination(url: target, preserving: source, overwriteConfirmed: true)
        let staging = try destination.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let partial = staging.appendingPathComponent("partial.mp4")
        try Data("exported clip".utf8).write(to: partial)
        let replacement = Data("new unconfirmed destination contents".utf8)
        try replacement.write(to: target, options: .atomic)
        XCTAssertThrowsError(try destination.publish(stagedURL: partial))
        XCTAssertEqual(try Data(contentsOf: target), replacement)
    }

    func testCheckToReplaceRaceRestoresTheUnconfirmedFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let target = directory.appendingPathComponent("target.mp4")
        try Data("source".utf8).write(to: source)
        try Data("confirmed destination".utf8).write(to: target)
        let destination = try VideoExportDestination(url: target, preserving: source, overwriteConfirmed: true)
        let staging = try destination.makeStagingDirectory()
        let partial = staging.appendingPathComponent("partial.mp4")
        let exported = Data("exported clip".utf8)
        let concurrent = Data("unconfirmed concurrent writer".utf8)
        try exported.write(to: partial)
        XCTAssertThrowsError(try destination.publish(stagedURL: partial) { checkpoint in
            if checkpoint == .confirmedDestinationChecked { try concurrent.write(to: target, options: .atomic) }
        })
        XCTAssertEqual(try Data(contentsOf: target), concurrent)
        XCTAssertEqual(try Data(contentsOf: partial), exported)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("PicShot-Recovered-") })
    }

    func testNewWriterDuringReplacementKeepsItsFileAndPreservesRecoveryCopy() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let target = directory.appendingPathComponent("target.mp4")
        try Data("source".utf8).write(to: source)
        let confirmed = Data("confirmed destination".utf8)
        try confirmed.write(to: target)
        let destination = try VideoExportDestination(url: target, preserving: source, overwriteConfirmed: true)
        let staging = try destination.makeStagingDirectory()
        let partial = staging.appendingPathComponent("partial.mp4")
        try Data("exported clip".utf8).write(to: partial)
        let concurrent = Data("new concurrent destination".utf8)
        do {
            try destination.publish(stagedURL: partial) { checkpoint in
                if checkpoint == .destinationDisplaced { try concurrent.write(to: target, options: .atomic) }
            }
            XCTFail("The concurrent destination must not be overwritten")
        } catch VideoTrimError.recoveredDestination(let recovery) {
            XCTAssertEqual(try Data(contentsOf: recovery), confirmed)
            XCTAssertEqual(recovery.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath(),
                           directory.standardizedFileURL.resolvingSymlinksInPath())
        }
        XCTAssertEqual(try Data(contentsOf: target), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testCancellationBeforeEncoderStartsCleansOwnedStagingAndPreservesOriginal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let original = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("cancelled.mp4")
        let range = try VideoTrimRange(start: 0, end: 2, sourceDuration: 2)
        let task = Task {
            try await VideoTrimExporter.export(sourceURL: source, destinationURL: destination, range: range) { value in
                // The first zero is emitted after staging/session setup, before
                // the cancellation handler starts the encoder: exercise the race.
                if value == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled export must not publish") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        try assertNoStaging(in: directory)
    }

    func testRangeIsRevalidatedAgainstActualAssetDuration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let destination = directory.appendingPathComponent("outside.mp4")
        let range = try VideoTrimRange(start: 1, end: 3, sourceDuration: 4)
        do {
            _ = try await VideoTrimExporter.export(sourceURL: source, destinationURL: destination, range: range)
            XCTFail("A range from another asset must be rejected")
        } catch VideoTrimError.invalidRange { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStaging(in: directory)
    }

    @MainActor
    func testPreviewEditsRealRangeAndPauseCancelsSeekResume() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeMovie(in: directory)
        let model = RecordingPreviewModel(url: source)
        defer { model.close() }
        model.load()
        let deadline = Date().addingTimeInterval(10)
        while !model.ready, model.errorMessage == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.ready, model.errorMessage ?? "Player did not become ready")
        model.startText = "0.75"
        model.endText = "1.5"
        XCTAssertTrue(model.applyRangeFields())
        XCTAssertEqual(model.start, 0.75)
        XCTAssertEqual(model.end, 1.5)
        model.startText = "NaN"
        XCTAssertFalse(model.applyRangeFields())
        XCTAssertEqual(model.start, 0.75, "Invalid editing must not silently mutate the actual range")
        model.startText = "0.75"
        model.playSelection()
        model.pause()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(model.playing)
        XCTAssertEqual(model.player.rate, 0, "A stale seek completion must not resume playback after Pause")
        model.close()
        XCTAssertNil(model.player.currentItem)
    }

    @MainActor
    func testClosingPreviewCancelsLoadingAndReleasesPlayerIdempotently() {
        let model = RecordingPreviewModel(url: URL(fileURLWithPath: "/nonexistent/picshot-preview.mp4"))
        model.load()
        model.close()
        model.close()
        model.load()
        model.togglePlayback()
        XCTAssertTrue(model.closed)
        XCTAssertFalse(model.ready)
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.playing)
        XCTAssertNil(model.player.currentItem)
    }

    private func assertNoStaging(in directory: URL) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".picshot-trim-") })
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Trim-Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pixelColor(_ image: CGImage) throws -> (red: Int, blue: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(bytes[0]), Int(bytes[2]))
    }

    /// Authored here, not a downloaded fixture: one red second followed by one
    /// blue second at 12 FPS. No screen permission or recording service required.
    private func makeMovie(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("original.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 12]
        ])
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoTrimError.noVideo }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<24 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? VideoTrimError.noVideo }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 64, height: 48,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(red: index < 12 ? 1 : 0, green: 0.15, blue: index < 12 ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 12)) else {
                throw writer.error ?? VideoTrimError.noVideo
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? VideoTrimError.noVideo }
        return url
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ value: Double) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
}
