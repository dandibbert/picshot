import XCTest
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import PicShotCore
@testable import PicShot

final class RecordingPauseTests: XCTestCase {
    func testTimelineUsesOneOffsetForEveryTrackAndRejectsDelayedPausedSamples() throws {
        var timeline = RecordingTimeline()
        timeline.start(at: time(100))
        timeline.committed(through: time(101))
        timeline.pause(at: time(101))
        timeline.pause(at: time(102)) // Idempotent, preserves the original boundary.
        XCTAssertFalse(timeline.accepts(time(102)))
        timeline.resume(at: time(106))
        timeline.resume(at: time(107))
        XCTAssertEqual(timeline.removedDuration.seconds, 5)
        XCTAssertFalse(timeline.accepts(time(105.9)))
        XCTAssertEqual(try XCTUnwrap(timeline.presentationTime(for: time(106))).seconds, 1)
        timeline.committed(through: time(107))
        timeline.pause(at: time(107))
        timeline.resume(at: time(109))
        XCTAssertEqual(try XCTUnwrap(timeline.presentationTime(for: time(109))).seconds, 2)
        timeline.stop(at: time(110))
        XCTAssertEqual(timeline.activeDuration(at: time(900)).seconds, 3)
        XCTAssertFalse(timeline.accepts(time(111)))
    }

    func testQuickPauseCutsAfterAlreadyEncodedAudioAndNeverOverlaps() throws {
        var timeline = RecordingTimeline()
        timeline.start(at: time(100))
        timeline.committed(through: time(100.1))
        timeline.pause(at: time(100.05))
        timeline.resume(at: time(100.08))
        XCTAssertFalse(timeline.accepts(time(100.09)))
        XCTAssertEqual(timeline.removedDuration.seconds, 0)
        XCTAssertEqual(try XCTUnwrap(timeline.presentationTime(for: time(100.1))).seconds, 0.1, accuracy: 0.00001)
    }

    func testPauseBeforeFirstFrameDoesNotCreateLeadingGap() throws {
        var timeline = RecordingTimeline()
        timeline.pause(at: time(10))
        timeline.resume(at: time(15))
        XCTAssertFalse(timeline.accepts(time(14.9)))
        timeline.start(at: time(15.1))
        XCTAssertEqual(try XCTUnwrap(timeline.presentationTime(for: time(15.1))).seconds, 0)
        XCTAssertEqual(timeline.activeDuration(at: time(15.6)).seconds, 0.5, accuracy: 0.00001)
    }

    func testRetimingPreservesPCMFrameDurationsAndEveryPTSAndDTS() throws {
        let input = try audioSample(at: time(10), channels: 2, frames: 4, distinctTiming: true)
        let result = try RecordingSampleTiming.copy(input, subtracting: time(9.5))
        var count: CMItemCount = 0
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(result, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count), noErr)
        XCTAssertEqual(count, 4)
        for index in 0..<count {
            var entry = CMSampleTimingInfo()
            XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(result, at: index, timingInfoOut: &entry), noErr)
            XCTAssertEqual(entry.presentationTimeStamp.seconds, 0.5 + Double(index) / 48_000, accuracy: 0.000001)
            XCTAssertEqual(entry.decodeTimeStamp.seconds, 0.4 + Double(index) / 48_000, accuracy: 0.000001)
            XCTAssertEqual(entry.duration, CMTime(value: 1, timescale: 48_000))
        }
        XCTAssertEqual(CMSampleBufferGetNumSamples(result), 4)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(result), CMSampleBufferGetTotalSampleSize(input))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(input), time(10), "Retiming must not mutate the input")
    }

    func testH264AndAACRemoveMultiplePausesAndKeepDecodedTracksSynchronized() async throws {
        try await verifyEncodedPauseRecording(includeMicrophone: false)
    }

    func testBothSystemAndMicrophoneAACTracksUseTheSamePauseOffset() async throws {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { try await verifyEncodedPauseRecording(includeMicrophone: true) }
        else { throw XCTSkip("ScreenCaptureKit microphone output requires macOS 15; no permission is requested") }
        #else
        throw XCTSkip("ScreenCaptureKit microphone output requires Xcode 16; no permission is requested")
        #endif
    }

    func testStillScreenStoppedWhilePausedHasOnlyActiveDuration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(100)
        let writer = try makeWriter(in: directory, clock: clock)
        try await append(try screenSample(at: time(100), color: .red), to: writer, type: .screen)
        clock.set(101)
        let paused = try await writer.setPaused(true)
        XCTAssertTrue(paused.isPaused)
        clock.set(112)
        let snapshot = await writer.stopAccepting()
        XCTAssertEqual(snapshot.elapsed, 1, accuracy: 0.00001)
        clock.set(200) // A slow SCStream teardown must not lengthen the file.
        let url = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.015)
        let again = try await writer.finish()
        XCTAssertEqual(again, url)
        let saved = try await writer.publishFinished(mediaURL: url)
        try await writer.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testStillScreenResumedWithoutNewVideoFramesHasCorrectDuration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(100)
        let writer = try makeWriter(in: directory, clock: clock)
        try await append(try screenSample(at: time(100), color: .red), to: writer, type: .screen)
        clock.set(101)
        _ = try await writer.setPaused(true)
        clock.set(110)
        _ = try await writer.setPaused(false)
        clock.set(110.5)
        let url = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.015)
    }

    func testFirstFrameArrivingDuringPauseCanStartAtResumeWithoutAnotherFrame() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(100)
        let writer = try makeWriter(in: directory, clock: clock)
        _ = try await writer.setPaused(true)
        let frame = try screenSample(at: time(101), color: .blue)
        writer.queue.sync { XCTAssertFalse(writer.consume(frame, of: .screen)) }
        clock.set(110)
        _ = try await writer.setPaused(false)
        clock.set(111)
        let url = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.015)
        let image = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
        let color = try centerColor(image)
        XCTAssertGreaterThan(color.2, color.0 + 100)
    }

    func testDesktopChangedDuringPauseIsCurrentAfterResumeWithoutNewFrames() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(100)
        let writer = try makeWriter(in: directory, clock: clock)
        try await append(try screenSample(at: time(100), color: .red), to: writer, type: .screen)
        clock.set(101)
        _ = try await writer.setPaused(true)
        let changed = try screenSample(at: time(105), color: .blue)
        writer.queue.sync { XCTAssertFalse(writer.consume(changed, of: .screen)) }
        clock.set(110)
        _ = try await writer.setPaused(false)
        clock.set(111)
        let url = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.015)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .zero
        let oldImage = try await generator.image(at: time(0.5)).image
        let newImage = try await generator.image(at: time(1.5)).image
        let before = try centerColor(oldImage)
        let after = try centerColor(newImage)
        XCTAssertGreaterThan(before.0, before.2 + 100)
        XCTAssertGreaterThan(after.2, after.0 + 100)
    }

    func testPausedInputsKeepAtMostTwoFramesAndWallLimitStillStops() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(100)
        let stops = StopRecorder()
        let options = RecordingOptions(frameRate: 10, capturesSystemAudio: true, maximumDuration: 2, maximumWallDuration: 3)
        let writer = try RecordingWriter(size: CGSize(width: 40, height: 24), options: options,
            outputDirectory: directory, clock: { clock.now }) { stops.record($0) }
        try await append(try screenSample(at: time(100), color: .red), to: writer, type: .screen)
        try await append(try audioSample(at: time(100), channels: 2), to: writer, type: .audio)
        clock.set(100.5)
        _ = try await writer.setPaused(true)
        let frame = try screenSample(at: time(101), color: .green)
        let audio = try audioSample(at: time(101), channels: 2)
        writer.queue.sync {
            for _ in 0..<20_000 {
                XCTAssertFalse(writer.consume(frame, of: .screen))
                XCTAssertFalse(writer.consume(audio, of: .audio))
            }
        }
        let paused = await writer.snapshot()
        XCTAssertEqual(paused.retainedVideoFrames, 2)
        XCTAssertEqual(paused.elapsed, 0.5, accuracy: 0.00001)
        clock.set(104)
        writer.queue.sync { XCTAssertFalse(writer.consume(frame, of: .screen)) }
        XCTAssertEqual(stops.messages.count, 1)
        XCTAssertTrue(stops.messages.compactMap { $0 }.first?.contains("total time limit") == true)
        let url = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.015)
        let finished = await writer.snapshot()
        XCTAssertEqual(finished.retainedVideoFrames, 0)
    }

    func testDiscardRacingFinishCannotPublishOrResumeAndCompletesBothCalls() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(100)
        let writer = try makeWriter(in: directory, clock: clock)
        try await append(try screenSample(at: time(100), color: .red), to: writer, type: .screen)
        clock.set(100.5)
        let finishing = Task { try await writer.finish() }
        try await writer.discard()
        _ = await finishing.result // Either ordering is valid; nothing is promoted.
        try await writer.discard()
        try assertArchivedRecordings(in: directory, count: 1)
        do { _ = try await writer.setPaused(false); XCTFail("A discarded writer cannot resume") }
        catch RecordingError.notRecording { }
        do { _ = try await writer.finish(); XCTFail("A discarded writer cannot finish") }
        catch is CancellationError { }
    }

    func testDurationAndWallBoundsRejectNonfiniteAndUnsafeOptions() {
        XCTAssertNoThrow(try RecordingOptions(maximumDuration: 1, maximumWallDuration: 1).validate())
        for wall in [Double.nan, .infinity, 0, 599, 7_201] {
            XCTAssertThrowsError(try RecordingOptions(maximumWallDuration: wall).validate())
        }
    }

    @MainActor
    func testDelayCancellationAndIdlePauseNeverAskForScreenPermission() async throws {
        for delay in [Double.nan, .infinity, -1, 30.01] { XCTAssertThrowsError(try RecordingService.validateDelay(delay)) }
        let service = serviceWithoutScreenAccess()
        do { try await service.pause(); XCTFail("Idle pause should fail") } catch RecordingError.notRecording { }
        do { try await service.resume(); XCTFail("Idle resume should fail") } catch RecordingError.notRecording { }
        let starting = Task { try await service.start(displayID: 0, delay: 30) }
        try await waitUntil { service.isStarting && service.countdown != nil }
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.elapsed, 0)
        do { try await service.start(displayID: 0, delay: 30); XCTFail("Countdown reserves the service") }
        catch RecordingError.busy { }
        await service.cancel()
        do { try await starting.value; XCTFail("Cancelled countdown cannot capture") } catch is CancellationError { }
        XCTAssertFalse(service.isStarting)
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isPaused)
        XCTAssertNil(service.countdown)
        XCTAssertNil(service.outputURL)
        XCTAssertNil(service.error)
    }

    @MainActor
    func testStopDuringDelayCancelsRatherThanStartingAStream() async throws {
        let service = serviceWithoutScreenAccess()
        let starting = Task { try await service.start(displayID: 0, delay: 30) }
        try await waitUntil { service.countdown != nil }
        do { _ = try await service.stop(); XCTFail("A countdown has no movie to save") } catch is CancellationError { }
        _ = await starting.result
        XCTAssertFalse(service.isStarting)
        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.outputURL)
        XCTAssertNil(service.error)
    }

    @MainActor
    func testRestartAndCancelDuringCountdownCannotLeakAnOlderStartGeneration() async throws {
        let service = serviceWithoutScreenAccess()
        let starting = Task { try await service.start(displayID: 0, delay: 30) }
        try await waitUntil { service.countdown != nil }
        let restarting = Task { try await service.restart(discardUnfinished: true, delay: 29) }
        try await waitUntil { service.isRestarting && service.countdown == 29 }
        do { try await starting.value; XCTFail("Original countdown must be cancelled") } catch is CancellationError { }
        XCTAssertTrue(service.isStarting)
        await service.cancel()
        do { _ = try await restarting.value; XCTFail("Restart countdown must be cancellable") } catch is CancellationError { }
        XCTAssertFalse(service.isRestarting)
        XCTAssertFalse(service.isStarting)
        XCTAssertNil(service.countdown)
        XCTAssertNil(service.error)
        // A later start uses a fresh generation; cancelling it requires no TCC.
        let next = Task { try await service.start(displayID: 0, delay: 30) }
        try await waitUntil { service.countdown == 30 }
        await service.cancel()
        _ = await next.result
        XCTAssertFalse(service.isStarting)
    }

    @MainActor
    func testLaterStopWinsOverRestartCountdown() async throws {
        let service = serviceWithoutScreenAccess()
        let starting = Task { try await service.start(displayID: 0, delay: 30) }
        try await waitUntil { service.countdown != nil }
        // Saving an unstarted countdown restarts it without manufacturing a clip.
        let restarting = Task { try await service.restart(delay: 29) }
        try await waitUntil { service.isRestarting && service.countdown == 29 }
        do { _ = try await service.stop(); XCTFail("Stop cancels the restart countdown") } catch is CancellationError { }
        _ = await starting.result
        do { _ = try await restarting.value; XCTFail("A later Stop must prevent the new take") } catch is CancellationError { }
        XCTAssertFalse(service.isStarting)
        XCTAssertFalse(service.isRestarting)
        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.countdown)
        XCTAssertNil(service.outputURL)
        XCTAssertNil(service.error)
    }

    // MARK: Actual media, independent of displays, microphones, TCC and sleep timing

    private func verifyEncodedPauseRecording(includeMicrophone: Bool) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(10)
        let stops = StopRecorder()
        let writer = try RecordingWriter(size: CGSize(width: 40, height: 24),
            options: RecordingOptions(frameRate: 10, capturesSystemAudio: true, capturesMicrophone: includeMicrophone),
            outputDirectory: directory, clock: { clock.now }) { stops.record($0) }
        // PCM packet boundaries must be integer ticks. Going through Double
        // seconds (for example 10.2 * 48_000) can put a timestamp one tick before
        // the previous packet's exact end, which is correctly rejected forever.
        let frameTicks: Int64 = 4_800
        let frameDuration = CMTime(value: frameTicks, timescale: 48_000)
        let segments: [(startTick: Int64, count: Int, color: Color)] = [
            (480_000, 5, .red), (600_000, 5, .blue), (768_000, 3, .green)
        ]
        let url: URL
        do {
            let preroll = try audioSample(at: CMTime(value: 475_200, timescale: 48_000), channels: 2)
            writer.queue.sync { XCTAssertFalse(writer.consume(preroll, of: .audio)) }
            for (segmentIndex, segment) in segments.enumerated() {
                let base = CMTime(value: segment.startTick, timescale: 48_000)
                if segmentIndex > 0 {
                    clock.set(base)
                    _ = try await writer.setPaused(false)
                    // Late callbacks from a removed interval remain rejected.
                    let stale = try audioSample(at: CMTimeSubtract(base, frameDuration), channels: 2)
                    writer.queue.sync { XCTAssertFalse(writer.consume(stale, of: .audio)) }
                }
                var previousPacketEnd: CMTime?
                for index in 0..<segment.count {
                    let timestamp = CMTime(value: segment.startTick + Int64(index) * frameTicks, timescale: 48_000)
                    clock.set(timestamp)
                    let screen = try screenSample(at: timestamp, color: segment.color)
                    let audio = try audioSample(at: timestamp, channels: 2)
                    let packetStart = CMSampleBufferGetPresentationTimeStamp(audio)
                    let packetDuration = CMSampleBufferGetDuration(audio)
                    XCTAssertEqual(CMTimeCompare(packetStart, timestamp), 0)
                    XCTAssertEqual(CMTimeCompare(packetDuration, frameDuration), 0)
                    if let previousPacketEnd {
                        XCTAssertEqual(CMTimeCompare(packetStart, previousPacketEnd), 0,
                            "PCM packets must be exactly adjacent, not one tick overlapping or gapped")
                    }
                    previousPacketEnd = CMTimeAdd(packetStart, packetDuration)
                    var inputs: [(sample: CMSampleBuffer, type: SCStreamOutputType)] = [(screen, .screen), (audio, .audio)]
                    if includeMicrophone {
                        #if compiler(>=6.0)
                        if #available(macOS 15.0, *) {
                            let microphone = try audioSample(at: timestamp, channels: 1)
                            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(microphone), packetStart), 0)
                            XCTAssertEqual(CMTimeCompare(CMSampleBufferGetDuration(microphone), packetDuration), 0)
                            inputs.append((microphone, .microphone))
                        }
                        #endif
                    }
                    // Do not block all producers while one input is backpressured:
                    // the muxer can need another track to maintain interleaving.
                    try await appendInterleaved(inputs, to: writer, stops: stops)
                    writer.queue.sync {
                        XCTAssertFalse(writer.consume(screen, of: .screen), "Duplicate video PTS must not be appended")
                        XCTAssertFalse(writer.consume(audio, of: .audio), "Overlapping audio packets must not be appended")
                    }
                }
                clock.set(CMTime(value: segment.startTick + Int64(segment.count) * frameTicks, timescale: 48_000))
                if segmentIndex < segments.count - 1 {
                    _ = try await writer.setPaused(true)
                    let excluded = try screenSample(at: CMTime(value: segment.startTick + 38_400, timescale: 48_000), color: .white)
                    writer.queue.sync { XCTAssertFalse(writer.consume(excluded, of: .screen)) }
                }
            }
            url = try await writer.finish()
        } catch {
            // A failed fixture must not leave an encoder open while its staging
            // directory is removed, obscuring later media tests with side effects.
            try await writer.discard()
            throw error
        }
        XCTAssertTrue(stops.messages.isEmpty, "Unexpected writer failure: \(stops.messages)")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.3, accuracy: 0.025, "The 5 paused seconds must be removed")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, includeMicrophone ? 2 : 1)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let videoFormats = try await videoTrack.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(videoFormats.first)), kCMVideoCodecType_H264)
        let videoRange = try await videoTrack.load(.timeRange)
        XCTAssertEqual(videoRange.start.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(videoRange.duration.seconds, 1.3, accuracy: 0.025,
            "The video track itself must retain its final frame, independently of longer audio tracks")
        XCTAssertEqual(videoRange.end.seconds, 1.3, accuracy: 0.025)
        try checkStoredVideoTimeline(asset: asset, track: videoTrack, expectedDuration: 1.3)
        try decodeAndCheck(asset: asset, track: videoTrack, audio: false, expectedDuration: 1.3)
        var audioChannelCounts = Set<UInt32>()
        for track in audioTracks {
            let formats = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(formats.first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kAudioFormatMPEG4AAC)
            let encodedAudio = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
            audioChannelCounts.insert(encodedAudio.mChannelsPerFrame)
            try decodeAndCheck(asset: asset, track: track, audio: true, expectedDuration: 1.3,
                               expectedAudioChannels: encodedAudio.mChannelsPerFrame)
            let range = try await track.load(.timeRange)
            XCTAssertEqual(range.duration.seconds, 1.3, accuracy: 0.06, "AAC must not keep pause-sized gaps")
        }
        XCTAssertEqual(audioChannelCounts, includeMicrophone ? Set<UInt32>([1, 2]) : Set<UInt32>([2]))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (timestamp, expected) in [(0.1, Color.red), (0.6, Color.blue), (1.1, Color.green), (1.2, Color.green)] {
            let image = try await generator.image(at: time(timestamp)).image
            let color = try centerColor(image)
            switch expected {
            case .red: XCTAssertGreaterThan(color.0, max(color.1, color.2) + 100)
            case .blue: XCTAssertGreaterThan(color.2, max(color.0, color.1) + 100)
            case .green: XCTAssertGreaterThan(color.1, max(color.0, color.2) + 100)
            case .white: XCTFail("Paused white pixels must never be encoded")
            }
        }
    }

    /// Read the H.264 packet timing exactly as stored in MP4. Decoded pixel
    /// buffers may have no duration, so they cannot establish the encoded end.
    /// Never synthesize a last-frame duration from the expected frame rate here.
    private func checkStoredVideoTimeline(asset: AVAsset, track: AVAssetTrack, expectedDuration: Double) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var previousEnd = CMTime.zero
        var samples = 0
        while let sample = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { assertEmptyMarker(sample); continue }
            XCTAssertGreaterThan(sampleCount, 0)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            XCTAssertTrue(timestamp.isNumeric)
            XCTAssertTrue(duration.isNumeric, "Stored H.264 duration is unavailable at PTS \(timestamp.seconds)")
            XCTAssertGreaterThan(duration.seconds, 0, "Stored final-frame duration must not be zero")
            XCTAssertEqual(CMTimeCompare(timestamp, previousEnd), 0,
                "Stored video packets must be adjacent; frame \(samples), PTS \(timestamp.seconds), prior end \(previousEnd.seconds)")
            previousEnd = CMTimeAdd(timestamp, duration)
            let payload = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            XCTAssertGreaterThan(CMBlockBufferGetDataLength(payload), 0)
            XCTAssertGreaterThan(CMSampleBufferGetTotalSampleSize(sample), 0)
            samples += sampleCount
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "Stored packet read did not complete")
        XCTAssertEqual(samples, 13)
        XCTAssertEqual(previousEnd.seconds, expectedDuration, accuracy: 0.025,
            "Stored H.264 sample timing must reach the full active duration")
    }

    /// Core Media permits attachment-only buffers for stream events such as
    /// discontinuity/drain markers. They contain zero media samples and must not
    /// replace a real packet's endpoint, even when their PTS is invalid.
    /// https://developer.apple.com/documentation/coremedia/cmsamplebuffer-api
    private func assertEmptyMarker(_ sample: CMSampleBuffer) {
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 0)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 0)
        XCTAssertNil(CMSampleBufferGetImageBuffer(sample))
        if let data = CMSampleBufferGetDataBuffer(sample) { XCTAssertEqual(CMBlockBufferGetDataLength(data), 0) }
    }

    private func decodeAndCheck(asset: AVAsset, track: AVAssetTrack, audio: Bool, expectedDuration: Double,
                                expectedAudioChannels: UInt32? = nil) throws {
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let settings: [String: Any] = audio ? [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ] : [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var previous = CMTime.invalid
        var previousPCMEnd = CMTime.invalid
        var end = 0.0
        var samples = 0
        var pcmSquaredSum = 0.0
        var pcmValueCount = 0
        while let sample = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { assertEmptyMarker(sample); continue }
            XCTAssertGreaterThan(sampleCount, 0)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            XCTAssertTrue(timestamp.isNumeric)
            if previous.isValid { XCTAssertGreaterThan(CMTimeCompare(timestamp, previous), 0) }
            XCTAssertGreaterThanOrEqual(timestamp.seconds, -0.03) // AAC encoder priming may precede zero.
            XCTAssertLessThan(timestamp.seconds, expectedDuration + 0.03)
            if audio {
                let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
                let pcm = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
                let channels = try XCTUnwrap(expectedAudioChannels)
                XCTAssertEqual(pcm.mFormatID, kAudioFormatLinearPCM)
                XCTAssertEqual(pcm.mSampleRate, 48_000)
                XCTAssertEqual(pcm.mChannelsPerFrame, channels)
                XCTAssertEqual(pcm.mBitsPerChannel, 32)
                XCTAssertNotEqual(pcm.mFormatFlags & kAudioFormatFlagIsFloat, 0)
                XCTAssertEqual(pcm.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
                let duration = CMSampleBufferGetDuration(sample)
                XCTAssertTrue(duration.isNumeric)
                XCTAssertGreaterThan(duration.seconds, 0)
                XCTAssertEqual(duration.seconds, Double(sampleCount) / 48_000, accuracy: 1.0 / 48_000,
                    "Decoded PCM duration must match the actual audio-frame count")
                if previousPCMEnd.isNumeric {
                    XCTAssertEqual(timestamp.seconds, previousPCMEnd.seconds, accuracy: 1.0 / 48_000,
                        "Decoded PCM packets must be continuous across the removed pauses")
                }
                previousPCMEnd = CMTimeAdd(timestamp, duration)
                end = max(end, previousPCMEnd.seconds)
                let data = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
                let valueCount = sampleCount * Int(channels)
                let byteCount = valueCount * MemoryLayout<Float>.size
                XCTAssertEqual(CMBlockBufferGetDataLength(data), byteCount)
                guard byteCount > 0, byteCount <= 1_048_576, CMBlockBufferGetDataLength(data) == byteCount else {
                    throw RecordingError.failed("The decoded PCM fixture has invalid payload size.")
                }
                var values = [Float](repeating: 0, count: valueCount)
                let copied = values.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: byteCount, destination: bytes.baseAddress!)
                }
                XCTAssertEqual(copied, noErr)
                XCTAssertTrue(values.allSatisfy { $0.isFinite }, "Decoded PCM must contain finite samples")
                for value in values where value.isFinite { pcmSquaredSum += Double(value) * Double(value) }
                pcmValueCount += valueCount
            } else { XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample)) }
            previous = timestamp
            samples += sampleCount
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "Decode did not complete")
        if audio {
            // Decoder chunking is implementation-dependent (one run emitted only
            // eight buffers). Validate real PCM frames and bytes instead. Retain
            // the existing 60ms AAC priming/padding allowance in both checks.
            XCTAssertEqual(Double(samples), expectedDuration * 48_000, accuracy: 0.06 * 48_000)
            XCTAssertEqual(end, expectedDuration, accuracy: 0.06)
            XCTAssertGreaterThan(pcmValueCount, 0)
            XCTAssertGreaterThan(pcmSquaredSum / Double(max(1, pcmValueCount)), 0.00001,
                "The fixture's tone must survive AAC encoding as non-silent PCM")
        } else {
            // All 13 source frames must decode, including the final green frame
            // whose presentation starts at 1.2s. Its real 0.1s extent is checked
            // above through the stored packets and the video track's timeRange.
            XCTAssertEqual(samples, 13)
            XCTAssertEqual(CMTimeCompare(previous, CMTime(value: 12, timescale: 10)), 0)
        }
    }

    private func append(_ sample: CMSampleBuffer, to writer: RecordingWriter, type: SCStreamOutputType) async throws {
        try await appendInterleaved([(sample, type)], to: writer)
    }

    private func appendInterleaved(_ inputs: [(sample: CMSampleBuffer, type: SCStreamOutputType)],
                                   to writer: RecordingWriter, stops: StopRecorder? = nil) async throws {
        // Fixed, tiny fixture batch: one sample per track, not a production queue.
        precondition((1...3).contains(inputs.count))
        let deadline = Date().addingTimeInterval(10)
        var accepted = [Bool](repeating: false, count: inputs.count)
        while accepted.contains(false) {
            writer.queue.sync {
                for index in inputs.indices where !accepted[index] {
                    accepted[index] = writer.consume(inputs[index].sample, of: inputs[index].type)
                }
            }
            if !accepted.contains(false) { return }
            let stopMessages = stops?.messages ?? []
            if !stopMessages.isEmpty || Date() >= deadline {
                let snapshot = await writer.snapshot()
                let pending = inputs.indices.filter { !accepted[$0] }.map { index in
                    let input = inputs[index]
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(input.sample)
                    let duration = CMSampleBufferGetDuration(input.sample)
                    return "track=\(input.type.rawValue), pts=\(timestamp.value)/\(timestamp.timescale), duration=\(duration.value)/\(duration.timescale), samples=\(CMSampleBufferGetNumSamples(input.sample))"
                }.joined(separator: "; ")
                let reasons = stopMessages.map { $0 ?? "automatic stop" }.joined(separator: "; ")
                throw RecordingError.failed("Synthetic append stalled: \(pending); elapsed=\(snapshot.elapsed), paused=\(snapshot.isPaused), writer stop=\(reasons.isEmpty ? "none" : reasons)")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func makeWriter(in directory: URL, clock: TestClock) throws -> RecordingWriter {
        try RecordingWriter(size: CGSize(width: 40, height: 24), options: RecordingOptions(frameRate: 10),
            outputDirectory: directory, clock: { clock.now }) { _ in }
    }

    @MainActor
    private func serviceWithoutScreenAccess() -> RecordingService {
        // Even if a countdown regresses or a CI process is suspended for 30s,
        // these service tests can never ask for real screen/TCC access.
        RecordingService(screenPermissionCheck: { throw RecordingError.failed("A countdown test attempted live capture.") })
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw RecordingError.failed("Recording state did not settle.") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
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
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
    private enum Color: Equatable { case red, blue, green, white }

    private func screenSample(at timestamp: CMTime, color: Color) throws -> CMSampleBuffer {
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 40, 24, kCVPixelFormatType_32BGRA, attributes, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 40, height: 24,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let red: CGFloat = color == .red || color == .white ? 1 : 0
        let green: CGFloat = color == .green || color == .white ? 1 : 0
        let blue: CGFloat = color == .blue || color == .white ? 1 : 0
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 24))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &result), noErr)
        let sample = try XCTUnwrap(result)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return sample
    }

    private func audioSample(at timestamp: CMTime, channels: Int, frames: Int = 4_800,
                             distinctTiming: Bool = false) throws -> CMSampleBuffer {
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
        let sampleCount = frames * channels
        let angularStep: Double = 2.0 * Double.pi * 440.0 / 48_000.0
        let values: [Float] = (0..<sampleCount).map { index in
            let phase = Double(index / channels) * angularStep
            return Float(sin(phase) * 0.25)
        }
        values.withUnsafeBytes { bytes in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: data,
                offsetIntoDestination: 0, dataLength: bytes.count), noErr)
        }
        let entryCount = distinctTiming ? frames : 1
        var timings = (0..<entryCount).map { index in
            CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTimeAdd(timestamp, CMTime(value: Int64(index), timescale: 48_000)),
                decodeTimeStamp: distinctTiming ? CMTimeAdd(CMTimeSubtract(timestamp, time(0.1)), CMTime(value: Int64(index), timescale: 48_000)) : .invalid)
        }
        var sampleSize = bytesPerFrame
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: try XCTUnwrap(description), sampleCount: frames, sampleTimingEntryCount: entryCount,
            sampleTimingArray: &timings, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    private func centerColor(_ image: CGImage) throws -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CMTime
    init(_ seconds: Double) { value = CMTime(seconds: seconds, preferredTimescale: 48_000) }
    var now: CMTime { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ seconds: Double) { set(CMTime(seconds: seconds, preferredTimescale: 48_000)) }
    func set(_ timestamp: CMTime) { lock.lock(); defer { lock.unlock() }; value = timestamp }
}

private final class StopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []
    func record(_ message: String?) { lock.lock(); defer { lock.unlock() }; storage.append(message) }
    var messages: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}
