import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Explicit synthetic acceptance only. No event monitor, capture stream, device,
/// window, posted OS event or permission API is used by this fixture.
@MainActor
enum RecordingInputSmokeFixture {
    static let width = 320
    static let height = 180
    static let frameRate = 10
    static let encodedFrames = 22
    static let duration = 2.2
    static let maximumEvidenceBytes = 4 * 1_024 * 1_024
    static let cooperativeDeadlineSeconds = 60.0
    private static let size = CGSize(width: width, height: height)
    private static let enabled = RecordingInputEffectsOptions(clicks: true, scrolls: true, shortcuts: true)
    private static let clickPoint = CGPoint(x: 0.25, y: 0.6)
    private static let scrollPoint = CGPoint(x: 0.72, y: 0.6)
    private static let witnessNames = ["recording-input.mp4", "recording-input.png", "recording-input.json"]

    /// Retains one short H.264 movie, one independently decoded PNG and JSON.
    /// The caller owns the evidence directory and an outer hard process timeout.
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        try require(evidenceDirectory.isFileURL, "Evidence must be a local file directory")
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        for name in witnessNames {
            try require(!files.fileExists(atPath: evidenceDirectory.appendingPathComponent(name).path),
                        "Refusing to replace existing input witness: \(name)")
        }
        let reportURL = evidenceDirectory.appendingPathComponent("recording-input.json")
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-Recording-Input-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + cooperativeDeadlineSeconds
        var report: [String: Any] = [
            "status": "running", "profile": "synthetic-recording-input",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "width": width, "height": height, "frameRate": frameRate,
            "expectedEncodedFrames": encodedFrames, "expectedDurationSeconds": duration,
            "captureStarted": false, "screenCaptureStarted": false, "cameraCaptureStarted": false, "microphoneStarted": false,
            "permissionRequested": false, "windowsCreated": 0, "inputEventsPosted": 0, "globalInputPosted": false,
            "sourceProvenance": "original solid desktop, camera and vector annotation pixels; injected normalized input values",
            "eventDeliveryScope": "synthetic model injection only; no foreign-app delivery, Accessibility, Input Monitoring or Secure Input acceptance",
            "stopScope": "writer stop barrier freezes input values and sampled time for pending output; service Stop removes monitors and clears effects immediately, and cannot remove already encoded pixels",
            "overlayRefreshScope": "production timer handler manually invoked on encoder queue against injected monotonic clock; actual timer scheduling not tested",
            "resourceScope": "one 320x180 export and one cancellation pipeline; bounded event values and weak object ownership; no RSS, GPU, codec-service or long-recording leak claim",
            "maximumEvidenceBytesPerMediaFile": maximumEvidenceBytes,
            "maximumReportBytes": 128 * 1_024, "cooperativeDeadlineSeconds": cooperativeDeadlineSeconds,
            "temporaryDirectoryRemoved": false
        ]
        do {
            try checkDeadline(deadline)
            report["phase"] = "bounded-event-and-disabled-path"
            report["stateChecks"] = try checkBoundedStateAndDisabledPath()
            let probe = InputSmokeReleaseProbe()
            report["phase"] = "export-and-independent-decode"
            var exported = try await export(root: root, evidence: evidenceDirectory, probe: probe, deadline: deadline)
            try await requireReleased(probe, deadline: deadline)
            exported["directoryCleanupDisposition"] = try RecordingCompositionSmokeFixture.removeOwnedFixtureDirectory(root.appendingPathComponent("export", isDirectory: true))
            report["export"] = exported
            report["decodedFrames"] = exported["decodedFrames"]
            report["decodedPixelChecks"] = exported["decodedPixelChecks"]
            report["storedPacketTiming"] = exported["storedPacketTiming"]
            report["releasedExportObjects"] = probe.liveObjects
            report["phase"] = "cancel-and-cleanup"
            let cancelled = InputSmokeReleaseProbe()
            var cancellation = try await cancel(root: root, probe: cancelled, deadline: deadline)
            try await requireReleased(cancelled, deadline: deadline)
            cancellation["directoryCleanupDisposition"] = try RecordingCompositionSmokeFixture.removeOwnedFixtureDirectory(root.appendingPathComponent("cancel", isDirectory: true))
            report["cancellation"] = cancellation
            report["releasedCancellationObjects"] = cancelled.liveObjects
            report["rootCleanupDisposition"] = try RecordingCompositionSmokeFixture.removeOwnedEmptyRoot(root)
            report["temporaryDirectoryRemoved"] = true
            report["witnessMovie"] = "recording-input.mp4"
            report["witnessPNG"] = "recording-input.png"
            report["witnessMoviePath"] = evidenceDirectory.appendingPathComponent("recording-input.mp4").path
            report["witnessPNGPath"] = evidenceDirectory.appendingPathComponent("recording-input.png").path
            report["functionalAssertions"] = ["decodedClickPixels": true, "decodedScrollDirection": true,
                "decodedShortcutGlyphs": true, "decodedExpiryClear": true, "decodedResumeClear": true,
                "decodedStopFrozenTimeAndValues": true, "cameraAndAnnotationsPreserved": true,
                "disabledSourceIdentity": true, "boundedEventRetention": true, "staleSessionRejected": true,
                "cancelledWriterReleased": true, "exportWriterReleased": true, "storedTimingAndPauseRemoval": true]
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            report["phase"] = "complete"; report["status"] = "passed"
            try write(report, to: reportURL)
            return report
        } catch {
            // This is a unique fixture-owned root, never a user's recording path.
            do {
                report["rootCleanupDisposition"] = try RecordingCompositionSmokeFixture.removeOwnedFixtureDirectory(root)
                report["temporaryDirectoryRemoved"] = true
            } catch { report["cleanupError"] = error.localizedDescription }
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try? write(report, to: reportURL)
            throw error
        }
    }

    private static func export(root: URL, evidence: URL, probe: InputSmokeReleaseProbe,
                               deadline: Double) async throws -> [String: Any] {
        let directory = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let state = RecordingCompositionState(), clock = InputSmokeClock(100), stops = InputSmokeStops()
        state.setCanvasSize(size)
        let inputToken = state.inputEffects.beginSession(options: enabled, at: 100)
        let cameraToken = UUID()
        state.setCameraSession(cameraToken)
        state.setLayout(RecordingCameraLayout(frame: CGRect(x: 0.04, y: 0.8, width: 0.16, height: 0.15), mirrored: false))
        let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
        let desktop = try makePixels(width: width, height: height, color: NSColor(srgbRed: 40.0 / 255, green: 40.0 / 255, blue: 40.0 / 255, alpha: 1), context: context)
        state.receiveCamera(try makePixels(width: 64, height: 48, color: .cyan, context: context), token: cameraToken)
        var mark = ImageAnnotation(tool: .rectangle,
            points: [CGPoint(x: 256, y: 150), CGPoint(x: 302, y: 169)], color: NSColor.magenta.cgColor, lineWidth: 2)
        mark.fillEnabled = true; mark.fillColor = NSColor.magenta.cgColor
        try require(state.setAnnotations([mark]), "Synthetic annotation was rejected")
        let compositor = try RecordingFrameCompositor(size: size, state: state, clock: { clock.seconds })
        let writer = try RecordingWriter(size: size,
            options: RecordingOptions(frameRate: frameRate, maximumDuration: 10, maximumFileSize: 16 * 1_024 * 1_024),
            outputDirectory: directory, compositor: compositor, automaticallyRefreshOverlays: false,
            clock: { clock.mediaTime }, requestStop: { stops.record($0) })
        probe.writer = writer; probe.compositor = compositor; probe.state = state; probe.inputEffects = state.inputEffects
        defer { state.inputEffects.endSession(); state.setCameraSession(nil); _ = state.setAnnotations([]) }
        do {
            for tick in 0...1 {
                clock.set(100 + Double(tick) / 10)
                try await append(makeSample(pixels: desktop, at: clock.seconds), writer: writer, stops: stops, deadline: deadline)
            }
            // No further real-screen callbacks: effects and their expiry must
            // make the production refresh handler encode the static desktop.
            for tick in 2...19 {
                clock.set(100 + Double(tick) / 10)
                if tick == 2 || tick == 19 {
                    try require(state.inputEffects.recordClick(button: .left, normalizedPoint: clickPoint, at: clock.seconds, token: inputToken), "Click injection failed")
                }
                if tick == 4 || tick == 19 {
                    try require(state.inputEffects.recordScroll(deltaX: -20, deltaY: 20, normalizedPoint: scrollPoint, at: clock.seconds, token: inputToken), "Scroll injection failed")
                }
                if tick == 6 || tick == 19 {
                    try require(state.inputEffects.recordShortcut(keyCode: 40, modifiers: [.command], at: clock.seconds, token: inputToken), "Shortcut injection failed")
                }
                try await refresh(writer, expectedPTS: Double(tick) / 10, stops: stops, deadline: deadline)
            }
            clock.set(102); state.inputEffects.setPaused(true, at: clock.seconds)
            _ = try await writer.setPaused(true)
            clock.set(102.5)
            try require(!state.inputEffects.recordClick(button: .right, normalizedPoint: clickPoint, at: clock.seconds, token: inputToken), "Paused input was accepted")
            try require(!state.inputEffects.snapshot(at: clock.seconds).hasVisibleEffects, "Pause retained input effects")
            writer.queue.sync { writer.refreshOverlay() }
            try require(abs(lastVideoTime(writer) - 1.9) < 0.0001, "A paused overlay refresh encoded a frame")
            clock.set(103); state.inputEffects.setPaused(false, at: clock.seconds)
            _ = try await writer.setPaused(false)
            try require(!state.inputEffects.recordShortcut(keyCode: 40, modifiers: [.command], at: 102.5, token: inputToken), "Queued paused shortcut appeared after resume")
            try await refresh(writer, expectedPTS: 2, stops: stops, deadline: deadline)

            // Leave a pending resume frame for finish(). Stop must preserve
            // both the event values and their sampled time before later teardown.
            clock.set(103.1); state.inputEffects.setPaused(true, at: clock.seconds)
            _ = try await writer.setPaused(true)
            clock.set(104.1); state.inputEffects.setPaused(false, at: clock.seconds)
            _ = try await writer.setPaused(false)
            try require(state.inputEffects.recordClick(button: .right, normalizedPoint: clickPoint, at: clock.seconds, token: inputToken), "Stop click injection failed")
            try require(state.inputEffects.recordScroll(deltaX: -20, deltaY: 20, normalizedPoint: scrollPoint, at: clock.seconds, token: inputToken), "Stop scroll injection failed")
            try require(state.inputEffects.recordShortcut(keyCode: 40, modifiers: [.command], at: clock.seconds, token: inputToken), "Stop shortcut injection failed")
            clock.set(104.2); _ = await writer.stopAccepting()
            state.inputEffects.endSession()
            clock.set(154.2)
            let replacementToken = state.inputEffects.beginSession(options: enabled, at: clock.seconds)
            try require(state.inputEffects.recordClick(button: .left, normalizedPoint: CGPoint(x: 0.5, y: 0.75), at: clock.seconds, token: replacementToken), "Replacement session injection failed")
            state.receiveCamera(try makePixels(width: 64, height: 48, color: .red, context: context), token: cameraToken)
            state.setCameraSession(nil); _ = state.setAnnotations([])
            let lateScreen = try makeSample(pixels: desktop, at: clock.seconds)
            try require(!writer.queue.sync { writer.consume(lateScreen, of: .screen) }, "Post-Stop source callback was accepted")
            let movie = try await writer.finish()
            try require(stops.message == nil, "Writer requested unexpected stop: \(stops.message ?? "")")
            let final = await writer.snapshot()
            try require(final.retainedVideoFrames == 0, "Finished writer retained a video surface")
            state.inputEffects.endSession()
            try require(state.inputEffects.snapshot(at: clock.seconds).events.isEmpty, "Input cleanup retained events")
            var result = try await validate(movie: movie, evidence: evidence, context: context, deadline: deadline)
            let bytes = try fileBytes(movie)
            try require(bytes > 0 && bytes <= maximumEvidenceBytes, "Input MP4 exceeded its evidence budget")
            try FileManager.default.copyItem(at: movie, to: evidence.appendingPathComponent("recording-input.mp4"))
            result["movieBytes"] = bytes; result["screenSamplesSubmitted"] = 2
            result["staticScreenRefreshFrames"] = 19; result["removedPauseSeconds"] = 2.0
            result["writerRetainedFramesAtFinish"] = final.retainedVideoFrames
            result["postStopMutationExcluded"] = true; result["inputEventsAtCleanup"] = 0
            return result
        } catch {
            try? await writer.discard()
            throw error
        }
    }

    private static func checkBoundedStateAndDisabledPath() throws -> [String: Any] {
        let state = RecordingCompositionState()
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let pixels = try makePixels(width: width, height: height, color: .gray, context: context)
        let source = try makeSample(pixels: pixels, at: 100)
        let compositor = try RecordingFrameCompositor(size: size, state: state, clock: { 100 })
        let disabledToken = state.inputEffects.beginSession(options: RecordingInputEffectsOptions(), at: 100)
        try require(!state.inputEffects.recordClick(button: .left, normalizedPoint: clickPoint, at: 100, token: disabledToken), "Default-off click was accepted")
        try require(!state.inputEffects.recordScroll(deltaX: 0, deltaY: 1, normalizedPoint: scrollPoint, at: 100, token: disabledToken), "Default-off scroll was accepted")
        try require(!state.inputEffects.recordShortcut(keyCode: 40, modifiers: [.command], at: 100, token: disabledToken), "Default-off shortcut was accepted")
        guard let unchanged = try compositor.composite(source) else { throw failure("Disabled compositor produced no frame") }
        try require(unchanged === source, "Disabled input changed the zero-overlay source identity")
        try require(!compositor.needsRefresh, "Disabled input scheduled an unnecessary refresh")
        var accepted = 0
        for session in 0..<4 {
            let token = state.inputEffects.beginSession(options: enabled, at: 100 + Double(session))
            try require(!state.inputEffects.recordClick(button: .left, normalizedPoint: clickPoint, at: 100 + Double(session), token: disabledToken), "Stale input session token was accepted")
            for index in 0..<1_024 {
                let now = 100 + Double(session) + Double(index) / 100_000
                let didAccept: Bool
                switch index % 3 {
                case 0: didAccept = state.inputEffects.recordClick(button: .left, normalizedPoint: clickPoint, at: now, token: token)
                case 1: didAccept = state.inputEffects.recordScroll(deltaX: -20, deltaY: 20, normalizedPoint: scrollPoint, at: now, token: token)
                default: didAccept = state.inputEffects.recordShortcut(keyCode: 40, modifiers: [.command], at: now, token: token)
                }
                try require(didAccept, "Bounded synthetic input was unexpectedly rejected"); accepted += 1
                try require(state.inputEffects.snapshot(at: now).events.count <= 48, "Input event storage exceeded 48 values")
            }
            try require(state.inputEffects.snapshot(at: 100 + Double(session) + 0.02).events.count == 48, "Repeated input did not exercise the capacity boundary")
            state.inputEffects.endSession()
            try require(state.inputEffects.snapshot(at: 100 + Double(session) + 0.02).events.isEmpty, "Session cleanup retained input values")
        }
        return ["disabledSourceIdentityPreserved": true, "disabledRefreshSuppressed": true,
            "sessions": 4, "injectedEvents": accepted, "maximumRetainedEvents": 48,
            "eventsAfterEachEnd": 0, "staleTokenRejected": true]
    }

    private static func cancel(root: URL, probe: InputSmokeReleaseProbe, deadline: Double) async throws -> [String: Any] {
        let directory = root.appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let state = RecordingCompositionState(), clock = InputSmokeClock(200), stops = InputSmokeStops()
        let token = state.inputEffects.beginSession(options: enabled, at: 200)
        state.inputEffects.recordClick(button: .left, normalizedPoint: clickPoint, at: 200, token: token)
        let compositor = try RecordingFrameCompositor(size: size, state: state, clock: { clock.seconds })
        let writer = try RecordingWriter(size: size,
            options: RecordingOptions(frameRate: frameRate, maximumDuration: 10, maximumFileSize: 16 * 1_024 * 1_024), outputDirectory: directory,
            compositor: compositor, automaticallyRefreshOverlays: false, clock: { clock.mediaTime }, requestStop: { stops.record($0) })
        probe.writer = writer; probe.compositor = compositor; probe.state = state; probe.inputEffects = state.inputEffects
        do {
            let context = CIContext(options: [.useSoftwareRenderer: true])
            let pixels = try makePixels(width: width, height: height, color: .black, context: context)
            try await append(makeSample(pixels: pixels, at: 200), writer: writer, stops: stops, deadline: deadline)
            clock.set(200.1); state.inputEffects.setPaused(true, at: clock.seconds)
            _ = try await writer.setPaused(true)
            try await writer.discard()
            try await writer.discard() // Repeated explicit cancellation must be harmless.
            state.inputEffects.endSession()
            let snapshot = await writer.snapshot()
            try require(snapshot.retainedVideoFrames == 0, "Cancelled writer retained a video frame")
            try require(state.inputEffects.snapshot(at: clock.seconds).events.isEmpty, "Cancelled input session retained events")
            let late = try makeSample(pixels: pixels, at: 201)
            try require(!writer.queue.sync { writer.consume(late, of: .screen) }, "Cancelled writer accepted a later frame")
            return ["cancelledWhilePaused": true, "repeatDiscardSucceeded": true,
                "writerRetainedFrames": snapshot.retainedVideoFrames, "inputEvents": 0]
        } catch { state.inputEffects.endSession(); try? await writer.discard(); throw error }
    }

    private static func validate(movie: URL, evidence: URL, context: CIContext, deadline: Double) async throws -> [String: Any] {
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(tracks.count == 1 && audio.isEmpty, "Unexpected input movie tracks")
        let formats = try await tracks[0].load(.formatDescriptions)
        try require(!formats.isEmpty && formats.allSatisfy { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }, "Input export is not H.264")
        let measuredDuration = try await asset.load(.duration).seconds
        try require(abs(measuredDuration - duration) < 0.02, "Input export pause removal or duration differs")
        let timing = try storedTiming(asset: asset, track: tracks[0])
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        try require(reader.canAdd(output), "Independent input decoder unavailable")
        reader.add(output); try require(reader.startReading(), "Independent input decoder failed to start")
        var frames = 0, checks = 0, observations: [[String: Any]] = []
        while let sample = output.copyNextSampleBuffer() {
            try checkDeadline(deadline)
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            try require(frames < encodedFrames, "Input decode exceeded its frame bound")
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw failure("Input decode has no pixels") }
            try require(CVPixelBufferGetWidth(pixels) == width && CVPixelBufferGetHeight(pixels) == height, "Decoded input dimensions differ")
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try require(abs(pts - Double(frames) / 10) < 0.001, "Input frame \(frames) PTS differs: \(pts)")
            let image = CIImage(cvPixelBuffer: pixels)
            try checkColor(image, point: CGPoint(x: 35, y: 156), expected: [0, 255, 255], tolerance: 40, context: context, label: "camera at frame \(frames)")
            try checkColor(image, point: CGPoint(x: 278, y: 158), expected: [255, 0, 255], tolerance: 40, context: context, label: "annotation at frame \(frames)")
            try checkColor(image, point: CGPoint(x: 160, y: 165), expected: [40, 40, 40], tolerance: 14, context: context, label: "untouched desktop at frame \(frames)")
            checks += 3
            if [0, 2, 4, 6, 9, 13, 18, 19, 20, 21].contains(frames) {
                let left = stats(image, rect: CGRect(x: 54, y: 80, width: 52, height: 54), context: context)
                let scroll = stats(image, rect: CGRect(x: 194, y: 100, width: 44, height: 42), context: context)
                let keys = stats(image, rect: CGRect(x: 118, y: 12, width: 84, height: 32), context: context)
                observations.append(["frame": frames, "pts": pts, "left": left, "scroll": scroll, "keys": keys])
                if frames == 2 { try require(left["yellow"]! > 70, "Encoded click ring is absent or has the wrong color"); checks += 1 }
                if frames == 4 {
                    try require(scroll["mint"]! > 50, "Encoded scroll cue is absent")
                    try checkColor(image, point: CGPoint(x: 219, y: 107), expected: [77, 245, 189], tolerance: 65, context: context, label: "negative horizontal scroll shaft")
                    try checkColor(image, point: CGPoint(x: 229, y: 119), expected: [77, 245, 189], tolerance: 65, context: context, label: "positive lower-left vertical scroll shaft")
                    try checkColor(image, point: CGPoint(x: 240, y: 107), expected: [40, 40, 40], tolerance: 25, context: context, label: "opposite scroll direction remains clear")
                    checks += 4
                }
                if frames == 6 { try require(keys["white"]! > 140, "Encoded shortcut glyphs are absent"); checks += 1 }
                if frames == 9 { try require(left["yellow"]! == 0, "Expired click remains in encoded output"); checks += 1 }
                if frames == 13 { try require(scroll["mint"]! == 0, "Expired scroll remains in encoded output"); checks += 1 }
                if [0, 18, 20].contains(frames) {
                    try require(left["nonBackground"]! == 0 && scroll["nonBackground"]! == 0 && keys["nonBackground"]! == 0,
                                "Initial/expired/resumed frame \(frames) contains stale input pixels")
                    checks += 3
                }
                if frames == 21 {
                    try require(left["pink"]! > 45 && scroll["mint"]! > 35 && keys["white"]! > 100,
                                "Pending resume lost Stop-frozen input values or sampled time")
                    try checkColor(image, point: CGPoint(x: 160, y: 134), expected: [40, 40, 40], tolerance: 14, context: context, label: "post-Stop replacement click excluded")
                    checks += 4
                    try savePNG(image, to: evidence.appendingPathComponent("recording-input.png"), context: context)
                }
            }
            frames += 1
        }
        try require(reader.status == .completed && frames == encodedFrames, "Input decoder did not complete with 22 frames: \(reader.error?.localizedDescription ?? "")")
        return ["decodedFrames": frames, "decodedPixelChecks": checks, "durationSeconds": measuredDuration,
            "videoCodec": "H.264", "storedPacketTiming": timing, "observations": observations,
            "verifiedPhases": ["click", "scroll-direction", "shortcut-glyphs", "expiry-on-static-desktop", "pause-clearing", "frozen-stop-sampled-time", "camera-and-annotation-combination"]]
    }

    private static func storedTiming(asset: AVAsset, track: AVAssetTrack) throws -> [String: Any] {
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        try require(reader.canAdd(output), "Input packet reader unavailable")
        reader.add(output); try require(reader.startReading(), "Input packet reader failed to start")
        var count = 0, end = CMTime.zero
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample), length = CMSampleBufferGetDuration(sample)
            try require(pts.isNumeric && length.isNumeric && length.seconds > 0 && CMTimeCompare(pts, end) == 0,
                        "Stored input packets are not adjacent with positive durations")
            try require(abs(pts.seconds - Double(count) / 10) < 0.001, "Stored input packet PTS differs")
            count += CMSampleBufferGetNumSamples(sample); end = CMTimeAdd(pts, length)
            try require(count <= encodedFrames, "Input packet count exceeded the fixed bound")
        }
        try require(reader.status == .completed && count == encodedFrames && abs(end.seconds - duration) < 0.02, "Input packet count or endpoint differs")
        return ["packets": count, "adjacent": true, "positiveDurations": true, "endSeconds": end.seconds]
    }

    private static func append(_ sample: CMSampleBuffer, writer: RecordingWriter, stops: InputSmokeStops, deadline: Double) async throws {
        let boundary = min(deadline, ProcessInfo.processInfo.systemUptime + 10)
        while !writer.queue.sync(execute: { writer.consume(sample, of: .screen) }) {
            try require(stops.message == nil, "Input writer stopped: \(stops.message ?? "")")
            try checkDeadline(boundary); try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func refresh(_ writer: RecordingWriter, expectedPTS: Double, stops: InputSmokeStops, deadline: Double) async throws {
        let boundary = min(deadline, ProcessInfo.processInfo.systemUptime + 10)
        // Visible effects intentionally keep needsOverlayRefresh true. Observe
        // actual encoder acceptance instead of waiting for that flag to clear.
        while abs(lastVideoTime(writer) - expectedPTS) >= 0.0001 {
            writer.queue.sync { writer.refreshOverlay() }
            try require(stops.message == nil, "Static input refresh stopped: \(stops.message ?? "")")
            try checkDeadline(boundary); try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func lastVideoTime(_ writer: RecordingWriter) -> Double {
        writer.queue.sync {
            let value = writer.smokeDiagnosticSnapshot()["lastVideoTime"] as? [String: Int64]
            guard let value, let ticks = value["value"], let scale = value["timescale"], scale > 0 else { return -1 }
            return Double(ticks) / Double(scale)
        }
    }

    private static func makePixels(width: Int, height: Int, color: NSColor, context: CIContext) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &result) == kCVReturnSuccess,
              let result else { throw failure("Synthetic input pixels unavailable") }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(CIImage(color: CIColor(cgColor: color.cgColor)), to: result,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: srgb)
        CVBufferSetAttachment(result, kCVImageBufferCGColorSpaceKey, srgb, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return result
    }

    private static func makeSample(pixels: CVPixelBuffer, at seconds: Double) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescriptionOut: &format) == noErr, let format else { throw failure("Input sample format unavailable") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr,
              let result, let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true)
        else { throw failure("Input sample unavailable") }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        return result
    }

    private static func stats(_ image: CIImage, rect: CGRect, context: CIContext) -> [String: Int] {
        let width = Int(rect.width), height = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 4, bounds: rect,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        var result = ["yellow": 0, "pink": 0, "mint": 0, "white": 0, "nonBackground": 0]
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
            if r > 120 && g > 90 && r > g + 15 && b < g - 30 { result["yellow"]! += 1 }
            if r > 140 && b > 90 && r > g + 40 { result["pink"]! += 1 }
            if g > 120 && g > r + 30 && b > r + 20 { result["mint"]! += 1 }
            if min(r, g, b) > 140 { result["white"]! += 1 }
            if max(abs(r - 40), abs(g - 40), abs(b - 40)) > 18 { result["nonBackground"]! += 1 }
        }
        return result
    }

    private static func checkColor(_ image: CIImage, point: CGPoint, expected: [Int], tolerance: Int,
                                   context: CIContext, label: String) throws {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let rgb = bytes.prefix(3).map(Int.init)
        try require(zip(rgb, expected).allSatisfy { abs($0.0 - $0.1) <= tolerance }, "Decoded \(label): \(rgb), expected \(expected)")
    }

    private static func savePNG(_ image: CIImage, to url: URL, context: CIContext) throws {
        guard let cg = context.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw failure("Decoded input witness unavailable") }
        CGImageDestinationAddImage(destination, cg, nil)
        try require(CGImageDestinationFinalize(destination), "Decoded input PNG failed to finalize")
        let bytes = try fileBytes(url)
        try require(bytes > 0 && bytes <= maximumEvidenceBytes, "Input PNG exceeded its evidence budget")
    }

    private static func requireReleased(_ probe: InputSmokeReleaseProbe, deadline: Double) async throws {
        let boundary = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        while probe.liveObjects.values.contains(true) {
            try checkDeadline(boundary); try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private static func fileBytes(_ url: URL) throws -> Int {
        guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw failure("Input witness byte count unavailable") }
        return bytes
    }
    private static func checkDeadline(_ deadline: Double) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Input smoke exceeded its cooperative deadline")
    }
    private static func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try require(data.count <= 128 * 1_024, "Input report exceeded its fixed evidence budget")
        try data.write(to: url, options: .atomic)
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PicShot.RecordingInputSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
private final class InputSmokeReleaseProbe {
    weak var writer: RecordingWriter?
    weak var compositor: RecordingFrameCompositor?
    weak var state: RecordingCompositionState?
    weak var inputEffects: RecordingInputEffectsState?
    var liveObjects: [String: Bool] {
        ["writer": writer != nil, "compositor": compositor != nil, "state": state != nil, "inputEffects": inputEffects != nil]
    }
}

private final class InputSmokeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    var seconds: Double { lock.lock(); defer { lock.unlock() }; return value }
    var mediaTime: CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
    func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private final class InputSmokeStops: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var message: String? { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ value: String?) { lock.lock(); defer { lock.unlock() }; if stored == nil { stored = value ?? "automatic limit" } }
}
