import XCTest
import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import ScreenCaptureKit
import PicShotCore
@testable import PicShot

/// Genuine recording/trim producers, synthetic pixels and PCM only. These
/// tests never create SCStream, touch a device, or request capture permission.
final class GIFRecordedInputCompatibilityTests: XCTestCase {
    func testSignedHelperAcceptsRecoveryPublishedFinalizedH264AndAACRecording() async throws {
        let app = try GIFProcessTestApplication.make()
        defer { app.cleanup() }
        let source = try await makePublishedRecording(in: app.root)
        let original = try Data(contentsOf: source)
        XCTAssertLessThan(original.count, 16 * 1_024 * 1_024)
        let atoms = try topLevelAtoms(original)
        XCTAssertTrue(atoms.contains("moov"), "Recording lacks its movie metadata: \(atoms)")
        // AVAssetWriter defragments movieFragmentInterval output when finish
        // succeeds. Native evidence here is [ftyp, mdat, moov]; the interrupted
        // RecordingWriter test below separately requires real moof atoms.
        XCTAssertTrue(atoms.contains("mdat"), "Recording lacks encoded media: \(atoms)")
        try await assertH264AndAAC(source, duration: 2.4)
        let service = app.service()
        let destination = app.root.appendingPathComponent("recorded.gif")
        let options = GIFExportOptions(frameRate: 10, maximumDimension: 40, maximumDuration: 2.4, maximumFrames: 24)
        let operation = InferenceTestOperation {
            try await service.export(sourceURL: source, destinationURL: destination, options: options)
        }
        defer { operation.cancel() }
        let result = try await GIFProcessTestDiagnostics.run(service: service, phase: "finalized H.264/AAC recording") {
            try await operation.value(timeout: 35, phase: "H.264/AAC recording through signed GIF helper")
        }
        XCTAssertEqual(result, destination)
        try validateGIF(result, frameCount: 24, duration: 2.4,
                        expectedColors: Array(repeating: RecordedColor.red, count: 8) + Array(repeating: .blue, count: 8) + Array(repeating: .green, count: 8))
        XCTAssertEqual(try Data(contentsOf: source), original, "GIF conversion must preserve the published recording byte-for-byte")
        try await assertExitedAndCleaned(service, root: app.root)
        try assertPublishedJournal(source: source, root: app.root)
    }

    func testSignedHelperAcceptsCompleteFragmentPrefixFromInterruptedRecordingWriter() async throws {
        let app = try GIFProcessTestApplication.make()
        defer { app.cleanup() }
        let fragment = try await makeInterruptedRecordingPrefix(in: app.root)
        let original = try Data(contentsOf: fragment.original)
        let prefixBefore = try Data(contentsOf: fragment.prefix)
        let atoms = try topLevelAtoms(prefixBefore)
        XCTAssertTrue(atoms.contains("moof"), "This separate input must contain actual movie fragments: \(atoms)")
        XCTAssertGreaterThanOrEqual(fragment.completeFragments, 2)
        let duration = try await AVURLAsset(url: fragment.prefix).load(.duration).seconds
        XCTAssertGreaterThanOrEqual(duration, 2.4, "The closed fragments must cover the requested GIF interval")
        try await assertH264AndAAC(fragment.prefix, duration: duration)
        let service = app.service()
        let destination = app.root.appendingPathComponent("fragment-prefix.gif")
        let options = GIFExportOptions(frameRate: 10, maximumDimension: 40, maximumDuration: 2.4, maximumFrames: 24)
        let operation = InferenceTestOperation {
            try await service.export(sourceURL: fragment.prefix, destinationURL: destination, options: options)
        }
        defer { operation.cancel() }
        let result = try await GIFProcessTestDiagnostics.run(service: service, phase: "interrupted RecordingWriter fragment prefix") {
            try await operation.value(timeout: 35, phase: "actual recording fragments through signed GIF helper")
        }
        // The production writer uses a two-second H.264 keyframe interval.
        // Crossing the color boundary exercises later fragment media too.
        try validateGIF(result, frameCount: 24, duration: 2.4,
            expectedColors: Array(repeating: RecordedColor.red, count: 20) + Array(repeating: .blue, count: 4))
        XCTAssertEqual(try Data(contentsOf: fragment.original), original)
        XCTAssertEqual(try Data(contentsOf: fragment.prefix), prefixBefore)
        try await assertExitedAndCleaned(service, root: app.root)
    }

    func testSignedHelperAcceptsReencodedAACTrimAndProductionTrimToGIFPath() async throws {
        let app = try GIFProcessTestApplication.make()
        defer { app.cleanup() }
        let source = try await makePublishedRecording(in: app.root)
        let original = try Data(contentsOf: source)
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let range = try VideoTrimRange(start: 0.6, end: 1.8, sourceDuration: sourceDuration)
        let trimmed = app.root.appendingPathComponent("selected.mp4")
        let trimming = InferenceTestOperation {
            try await VideoTrimExporter.export(sourceURL: source, destinationURL: trimmed, range: range)
        }
        defer { trimming.cancel() }
        let trimmedResult = try await trimming.value(timeout: 35, phase: "re-encoded recording trim")
        XCTAssertEqual(trimmedResult, trimmed)
        try await assertH264AndAAC(trimmed, duration: 1.2)
        let trimmedBefore = try Data(contentsOf: trimmed)
        let service = app.service()
        let options = GIFExportOptions(frameRate: 10, maximumDimension: 40, maximumDuration: range.duration, maximumFrames: 12)
        let expected = Array(repeating: RecordedColor.red, count: 2) + Array(repeating: .blue, count: 8) + Array(repeating: .green, count: 2)
        let directDestination = app.root.appendingPathComponent("selected-direct.gif")
        let direct = InferenceTestOperation {
            try await service.export(sourceURL: trimmed, destinationURL: directDestination, options: options)
        }
        defer { direct.cancel() }
        let directResult = try await GIFProcessTestDiagnostics.run(service: service, phase: "re-encoded H.264/AAC trim") {
            try await direct.value(timeout: 35, phase: "re-encoded H.264/AAC trim through signed GIF helper")
        }
        try validateGIF(directResult, frameCount: 12, duration: 1.2, expectedColors: expected)
        XCTAssertEqual(try Data(contentsOf: trimmed), trimmedBefore)
        try await assertExitedAndCleaned(service, root: app.root)

        // Also cover the user-facing selection route, whose temporary MP4 is
        // authored and removed by VideoTrimExporter rather than by this test.
        let destination = try VideoExportDestination(url: app.root.appendingPathComponent("selected-pipeline.gif"), preserving: source)
        let pipeline = InferenceTestOperation {
            try await GIFExporter.withProcessServiceForTesting(service) {
                try await VideoTrimExporter.exportGIF(sourceURL: source, destination: destination, range: range, options: options)
            }
        }
        defer { pipeline.cancel() }
        let pipelineResult = try await GIFProcessTestDiagnostics.run(service: service, phase: "production recording trim-to-GIF pipeline") {
            try await pipeline.value(timeout: 65, phase: "production recording trim-to-GIF pipeline")
        }
        XCTAssertEqual(pipelineResult, destination.url)
        try validateGIF(pipelineResult, frameCount: 12, duration: 1.2, expectedColors: expected)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: trimmed), trimmedBefore)
        try await assertExitedAndCleaned(service, root: app.root)
        try assertPublishedJournal(source: source, root: app.root)
    }

    private struct InterruptedRecording {
        let original: URL
        let prefix: URL
        let completeFragments: Int
    }

    private func makeInterruptedRecordingPrefix(in root: URL) async throws -> InterruptedRecording {
        let clock = GIFRecordedInputClock(CMTime(value: 480_000, timescale: 48_000))
        let stops = GIFRecordedInputStops()
        let writer = try RecordingWriter(size: CGSize(width: 40, height: 24),
            options: RecordingOptions(frameRate: 10, capturesSystemAudio: true),
            outputDirectory: root, clock: { clock.now }) { stops.record($0) }
        do {
            let stages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".recording-") }
            let stage = try XCTUnwrap(stages.first)
            let liveSource = stage.appendingPathComponent("recording.mp4")
            let producerDeadline = ProcessInfo.processInfo.systemUptime + 20
            // Include the 6-second keyframe and following samples so the
            // encoder can close later two-second fragments before interruption.
            for index in 0..<80 {
                guard ProcessInfo.processInfo.systemUptime < producerDeadline else {
                    throw RecordingError.failed("Actual RecordingWriter fixture exceeded its 20-second producer deadline")
                }
                let timestamp = CMTime(value: 480_000 + Int64(index) * 4_800, timescale: 48_000)
                clock.set(timestamp)
                let color: RecordedColor = index < 20 ? .red : (index < 40 ? .blue : .green)
                try await appendInterleaved(screen: screenSample(at: timestamp, color: color),
                    audio: audioSample(at: timestamp), to: writer, stops: stops)
                // Give native encoders a bounded flush opportunity without
                // changing the controlled media PTS or invoking live capture.
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            clock.set(CMTime(value: 480_000 + 80 * 4_800, timescale: 48_000))
            _ = await writer.stopAccepting()
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var lastObservation = "no closed media yet"
            var ready = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                do {
                    // Reuse only the existing bounded descriptor-based reader;
                    // this test's producer is the real RecordingWriter above.
                    let prefix = try RecordingRecoverySyntheticMovie.prefix(at: liveSource)
                    lastObservation = "completeFragments=\(prefix.completeFragments), bytes=\(prefix.byteCount)"
                    if prefix.completeFragments >= 2 { ready = true; break }
                } catch { lastObservation = String(describing: error) }
                guard stops.messages.isEmpty else { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard ready else { throw RecordingError.failed("Actual RecordingWriter fragment readiness failed: \(lastObservation); \(stops.messages)") }
            // The production interruption path preserves an alias before
            // cancelling the writer, then releases the recovery lease.
            try await writer.abandonPreservingRecovery()
            let store = try RecordingRecoveryStore(root: root)
            let scan = try store.discover()
            XCTAssertEqual(scan.candidates.count, 1)
            let candidate = try XCTUnwrap(scan.candidates.first)
            XCTAssertEqual(candidate.journal.phase, .capturing)
            let originalBefore = try Data(contentsOf: candidate.sourceURL)
            let lease = try store.open(candidate)
            defer { lease.closeLease() }
            let destination = root.appendingPathComponent("complete-recording-fragments.mp4")
            let copied = try lease.copyCompletePrefix(to: destination)
            XCTAssertGreaterThanOrEqual(copied.completeFragments, 2)
            XCTAssertEqual(try Data(contentsOf: candidate.sourceURL), originalBefore)
            XCTAssertTrue(try topLevelAtoms(Data(contentsOf: destination)).contains("moof"))
            return InterruptedRecording(original: candidate.sourceURL, prefix: destination, completeFragments: copied.completeFragments)
        } catch {
            try? await writer.abandonPreservingRecovery()
            throw error
        }
    }

    private func makePublishedRecording(in root: URL) async throws -> URL {
        let clock = GIFRecordedInputClock(CMTime(value: 480_000, timescale: 48_000))
        let stops = GIFRecordedInputStops()
        let writer = try RecordingWriter(size: CGSize(width: 40, height: 24),
            options: RecordingOptions(frameRate: 10, capturesSystemAudio: true),
            outputDirectory: root, clock: { clock.now }) { stops.record($0) }
        do {
            for index in 0..<24 {
                try Task.checkCancellation()
                let timestamp = CMTime(value: 480_000 + Int64(index) * 4_800, timescale: 48_000)
                clock.set(timestamp)
                let color: RecordedColor = index < 8 ? .red : (index < 16 ? .blue : .green)
                let screen = try screenSample(at: timestamp, color: color)
                let audio = try audioSample(at: timestamp)
                try await appendInterleaved(screen: screen, audio: audio, to: writer, stops: stops)
            }
            clock.set(CMTime(value: 480_000 + 24 * 4_800, timescale: 48_000))
            let stopped = await writer.stopAccepting()
            XCTAssertEqual(stopped.elapsed, 2.4, accuracy: 0.00001)
            let finalized = try await writer.finish()
            let source = try await writer.publishFinished(mediaURL: finalized)
            XCTAssertTrue(stops.messages.isEmpty, "Synthetic recording unexpectedly stopped: \(stops.messages)")
            XCTAssertEqual(source.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
            try assertPublishedJournal(source: source, root: root)
            return source
        } catch {
            // Close/preserve the real encoder transaction before fixture teardown.
            try? await writer.discard()
            throw error
        }
    }

    private func appendInterleaved(screen: CMSampleBuffer, audio: CMSampleBuffer,
                                   to writer: RecordingWriter, stops: GIFRecordedInputStops) async throws {
        let inputs: [(CMSampleBuffer, SCStreamOutputType)] = [(screen, .screen), (audio, .audio)]
        var accepted = [false, false]
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while accepted.contains(false) {
            try Task.checkCancellation()
            // A backpressured video input must not prevent audio reaching the
            // muxer (and vice versa). Only two authored packets are retained.
            writer.queue.sync {
                for index in inputs.indices where !accepted[index] {
                    accepted[index] = writer.consume(inputs[index].0, of: inputs[index].1)
                }
            }
            if !accepted.contains(false) { return }
            guard stops.messages.isEmpty, ProcessInfo.processInfo.systemUptime < deadline else {
                throw RecordingError.failed("Synthetic recording append stalled: \(stops.messages)")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func assertH264AndAAC(_ url: URL, duration expectedDuration: Double) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, expectedDuration, accuracy: 0.03)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1, "The compatibility fixture must contain actual AAC, not a silent video-only MP4")
        let videoTrack = try XCTUnwrap(video.first)
        let audioTrack = try XCTUnwrap(audio.first)
        let videoFormats = try await videoTrack.load(.formatDescriptions)
        let audioFormats = try await audioTrack.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(videoFormats.first)), kCMVideoCodecType_H264)
        let audioFormat = try XCTUnwrap(audioFormats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioFormat), kAudioFormatMPEG4AAC)
        let description = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)).pointee
        XCTAssertEqual(description.mChannelsPerFrame, 2)
        XCTAssertGreaterThan(description.mSampleRate, 0)
        // Prove AAC packets were actually muxed, not merely an empty audio
        // track declaration. No audio device or PCM decoder is needed here.
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(audioOutput)
        XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "AAC reader did not start")
        var encodedPackets = 0
        while let sample = audioOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            XCTAssertGreaterThan(CMSampleBufferGetTotalSampleSize(sample), 0)
            encodedPackets += CMSampleBufferGetNumSamples(sample)
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "AAC packet read did not finish")
        XCTAssertGreaterThan(encodedPackets, 0)
    }

    private func validateGIF(_ url: URL, frameCount: Int, duration: Double, expectedColors: [RecordedColor]) throws {
        XCTAssertEqual(expectedColors.count, frameCount)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        XCTAssertEqual(CGImageSourceGetCount(source), frameCount)
        var totalDuration = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            try autoreleasepool {
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index,
                    [kCGImageSourceShouldCache: false] as CFDictionary))
                XCTAssertEqual(image.width, 40)
                XCTAssertEqual(image.height, 24)
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
                let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
                let delay = try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber).doubleValue
                XCTAssertEqual(delay, 0.1, accuracy: 0.00001)
                totalDuration += delay
                let rgb = try averageColor(image)
                guard index < expectedColors.count else { return XCTFail("Unexpected extra GIF frame") }
                switch expectedColors[index] {
                case .red: XCTAssertGreaterThan(rgb.0, max(rgb.1, rgb.2) + 100, "Wrong recorded frame at \(index)")
                case .blue: XCTAssertGreaterThan(rgb.2, max(rgb.0, rgb.1) + 100, "Wrong recorded frame at \(index)")
                case .green: XCTAssertGreaterThan(rgb.1, max(rgb.0, rgb.2) + 100, "Wrong recorded frame at \(index)")
                }
            }
        }
        XCTAssertEqual(totalDuration, duration, accuracy: 0.01)
    }

    private func assertExitedAndCleaned(_ service: GIFExportProcessService, root: URL) async throws {
        let state = await service.snapshot()
        let metrics = try XCTUnwrap(state.lastJob)
        XCTAssertFalse(state.active)
        XCTAssertEqual(metrics.outcome, "succeeded")
        XCTAssertTrue(metrics.childLaunched)
        XCTAssertTrue(metrics.childExitConfirmed)
        XCTAssertEqual(metrics.terminationStatus, 0)
        XCTAssertTrue(metrics.temporaryDirectoryRemoved)
        XCTAssertGreaterThan(metrics.childResidentSampleCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.childSampledPeakResidentBytes), 0)
        XCTAssertGreaterThan(metrics.childReportedResidentSampleCount, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".picshot-") }, "Export left GIF/trim staging: \(names)")
    }

    private func assertPublishedJournal(source: URL, root: URL) throws {
        let stages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".recording-") }
        XCTAssertEqual(stages.count, 1)
        let stage = try XCTUnwrap(stages.first)
        let journal = try JSONDecoder().decode(RecordingRecoveryJournal.self,
            from: Data(contentsOf: stage.appendingPathComponent(RecordingRecoveryJournal.filename)))
        XCTAssertEqual(journal.phase, .published, "Exercise production recovery-aware publication, not raw writer.finish() output")
        XCTAssertEqual(journal.publishedFilename, source.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// Independent bounded top-level framing check establishes that the actual
    /// RecordingWriter fixture contains fragments; it does not reuse the gate.
    private func topLevelAtoms(_ data: Data) throws -> [String] {
        guard !data.isEmpty, data.count < 16 * 1_024 * 1_024 else { throw RecordingError.failed("Recording fixture exceeds its byte budget") }
        var offset = 0
        var names: [String] = []
        while offset < data.count {
            guard data.count - offset >= 8, names.count < 128 else { throw RecordingError.failed("Malformed recording fixture atom") }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var size = data[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var header = 8
            if size == 1 {
                guard data.count - offset >= 16 else { throw RecordingError.failed("Truncated recording fixture atom") }
                size = data[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                header = 16
            } else if size == 0 { size = UInt64(data.count - offset) }
            guard size >= UInt64(header), size <= UInt64(data.count - offset) else { throw RecordingError.failed("Invalid recording fixture atom extent") }
            names.append(type)
            offset += Int(size)
        }
        return names
    }

    private enum RecordedColor: Equatable { case red, blue, green }

    private func screenSample(at timestamp: CMTime, color: RecordedColor) throws -> CMSampleBuffer {
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 40, 24, kCVPixelFormatType_32BGRA, attributes, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        do {
            defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 40, height: 24,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(red: color == .red ? 1 : 0, green: color == .green ? 1 : 0,
                                         blue: color == .blue ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 24))
        }
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &result), noErr)
        let sample = try XCTUnwrap(result)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return sample
    }

    private func audioSample(at timestamp: CMTime) throws -> CMSampleBuffer {
        let frames = 4_800, channels = 2
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * bytesPerFrame, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frames * bytesPerFrame, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        let step = 2 * Double.pi * 440 / 48_000
        let values = (0..<(frames * channels)).map { Float(sin(Double($0 / channels) * step) * 0.25) }
        values.withUnsafeBytes { bytes in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: data,
                offsetIntoDestination: 0, dataLength: bytes.count), noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                       presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: try XCTUnwrap(description), sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    private func averageColor(_ image: CGImage) throws -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}

private final class GIFRecordedInputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CMTime
    init(_ time: CMTime) { value = time }
    var now: CMTime { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ time: CMTime) { lock.lock(); value = time; lock.unlock() }
}

private final class GIFRecordedInputStops: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []
    func record(_ message: String?) { lock.lock(); storage.append(message); lock.unlock() }
    var messages: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}
