import AppKit
import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit

struct RecordingOptions: Equatable, Sendable {
    var frameRate: Int = 30
    var capturesSystemAudio = false
    var capturesMicrophone = false
    var maximumDuration: TimeInterval = 600
    /// Includes every pause; a forgotten paused session cannot run indefinitely.
    var maximumWallDuration: TimeInterval = 7_200
    var maximumFileSize: Int64 = 1_073_741_824

    func validate() throws {
        guard (1...60).contains(frameRate), maximumDuration.isFinite,
              (1...3_600).contains(maximumDuration), maximumWallDuration.isFinite,
              (maximumDuration...7_200).contains(maximumWallDuration),
              (16_777_216...4_294_967_296).contains(maximumFileSize) else {
            throw RecordingError.invalidOptions
        }
    }
}

enum RecordingError: LocalizedError {
    case busy, notRecording, noFrames, invalidOptions, microphoneUnavailable, microphonePermission
    case invalidRegion, failed(String), sizeLimit, invalidDelay

    var errorDescription: String? {
        switch self {
        case .busy: return "A recording is already starting, running, or being saved."
        case .notRecording: return "There is no recording to save."
        case .noFrames: return "No video frames were received. Check screen recording permission and try again."
        case .invalidOptions: return "Use 1–60 FPS, an active duration of 1 second to 1 hour, a total time limit between the active limit and 2 hours, and a file limit of 16 MB to 4 GB."
        case .microphoneUnavailable: return "Microphone recording requires macOS 15 or later and a PicShot build made with Xcode 16 or later. System audio is available on macOS 14."
        case .microphonePermission: return "Allow PicShot to use the microphone in System Settings → Privacy & Security → Microphone."
        case .invalidDelay: return "Choose a recording delay between 0 and 30 seconds."
        case .invalidRegion: return "The recording region must be at least 2 × 2 points and entirely inside the selected display."
        case .failed(let message): return "Couldn’t record the screen: \(message)"
        case .sizeLimit: return "The recording exceeded its file-size limit. Try a shorter recording or a smaller region."
        }
    }
}

/// No frame arrays: ScreenCaptureKit has a three-frame queue and the encoder drops
/// frames under backpressure. The writer retains at most two video surfaces.
@MainActor
final class RecordingService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStopping = false
    @Published private(set) var isPaused = false
    @Published private(set) var isStarting = false
    @Published private(set) var isRestarting = false
    @Published private(set) var countdown: Int?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var error: String?
    /// Durable file in Movies/PicShot; also set after an automatic duration/size stop.
    /// Once finalized, a recording belongs to the user and cancel() never removes it.
    @Published private(set) var outputURL: URL?

    private var startingTask: Task<Void, Error>?
    private var startingID: UUID?
    private var restartingTask: Task<URL?, Error>?
    private var restartID: UUID?
    private var controlRevision = 0
    private var lastRequest: RecordingRequest?
    private var stoppingTask: Task<URL, Error>?
    private var timerTask: Task<Void, Never>?
    private var stream: SCStream?
    private var sink: RecordingWriter?
    private var sessionID: UUID?
    private var options = RecordingOptions()
    private var wallStartedAt: ContinuousClock.Instant?
    private var cancelRequested = false
    private let screenPermissionCheck: @MainActor () throws -> Void

    init(screenPermissionCheck: (@MainActor () throws -> Void)? = nil) {
        self.screenPermissionCheck = screenPermissionCheck ?? { try CaptureService.requireScreenPermission() }
    }

    static var supportsMicrophone: Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    func availableDisplays() async throws -> [SCDisplay] {
        try screenPermissionCheck()
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    private struct RecordingRequest {
        let displayID: CGDirectDisplayID
        let region: CGRect?
        let options: RecordingOptions
    }

    /// `region` is display-local logical points, with a top-left origin. A delay
    /// allocates no capture stream or recording file until its countdown ends.
    func start(displayID: CGDirectDisplayID, region: CGRect? = nil, options: RecordingOptions = .init(),
               delay: TimeInterval = 0) async throws {
        guard restartingTask == nil else { throw RecordingError.busy }
        try await startSession(displayID: displayID, region: region, options: options, delay: delay)
    }

    private func startSession(displayID: CGDirectDisplayID, region: CGRect?, options: RecordingOptions,
                              delay: TimeInterval) async throws {
        guard sessionID == nil, startingTask == nil, stoppingTask == nil else { throw RecordingError.busy }
        try options.validate()
        try Self.validateDelay(delay)
        if options.capturesMicrophone, !Self.supportsMicrophone { throw RecordingError.microphoneUnavailable }
        try Task.checkCancellation()
        let id = UUID()
        sessionID = id
        startingID = id
        cancelRequested = false
        error = nil
        outputURL = nil
        elapsed = 0
        isPaused = false
        isStarting = true
        countdown = delay > 0 ? Int(ceil(delay)) : nil
        self.options = options
        lastRequest = RecordingRequest(displayID: displayID, region: region, options: options)
        let task = Task {
            do {
                let deadline = ProcessInfo.processInfo.systemUptime + delay
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    self.countdown = max(1, Int(ceil(remaining)))
                    try await Task.sleep(nanoseconds: UInt64(min(0.1, max(0, remaining)) * 1_000_000_000))
                }
                self.countdown = nil
                try await self.begin(id: id, displayID: displayID, region: region, options: options)
            } catch {
                if self.sessionID == id, self.stream == nil { self.sessionID = nil }
                throw error
            }
        }
        startingTask = task
        defer {
            if startingID == id {
                startingTask = nil
                startingID = nil
                isStarting = false
                countdown = nil
            }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if !(error is CancellationError), startingID == id { self.error = error.localizedDescription }
            throw error
        }
    }

    static func validateDelay(_ delay: TimeInterval) throws {
        guard delay.isFinite, (0...30).contains(delay) else { throw RecordingError.invalidDelay }
    }

    /// Paused recordings remain `isRecording == true`: Stop still saves them.
    /// Commands are serialized by the encoder, including rapid repeated clicks.
    func pause() async throws { try await changePauseState(true) }
    func resume() async throws { try await changePauseState(false) }

    private func changePauseState(_ paused: Bool) async throws {
        guard isRecording, !isStopping, let sink, let id = sessionID else { throw RecordingError.notRecording }
        controlRevision += 1
        let revision = controlRevision
        let snapshot = try await sink.setPaused(paused)
        guard sessionID == id, isRecording, !isStopping else { throw RecordingError.notRecording }
        elapsed = max(elapsed, snapshot.elapsed)
        if revision == controlRevision { isPaused = snapshot.isPaused }
    }

    /// Save the unfinished take by default. Explicit `discardUnfinished: true`
    /// discards only that take. Previously published movies are never deleted.
    /// The returned URL is the previous saved take, if one was saved.
    func restart(discardUnfinished: Bool = false, delay: TimeInterval = 0) async throws -> URL? {
        try Self.validateDelay(delay)
        guard restartingTask == nil, !isStopping else { throw RecordingError.busy }
        guard sessionID != nil, let request = lastRequest else { throw RecordingError.notRecording }
        let token = UUID()
        restartID = token
        isRestarting = true
        let task = Task<URL?, Error> {
            let previous: URL?
            if discardUnfinished || (self.isStarting && self.countdown != nil) {
                await self.cancelSession()
                previous = nil
            } else {
                previous = try await self.stopSession()
            }
            try Task.checkCancellation()
            try await self.startSession(displayID: request.displayID, region: request.region,
                                        options: request.options, delay: delay)
            return previous
        }
        restartingTask = task
        defer {
            if restartID == token { restartingTask = nil; restartID = nil; isRestarting = false }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func stop() async throws -> URL {
        // A later Stop wins over an in-flight restart; it must not unexpectedly
        // create a new take after the old one has been saved.
        restartingTask?.cancel()
        return try await stopSession()
    }

    private func stopSession() async throws -> URL {
        if countdown != nil, let startingTask {
            startingTask.cancel()
            _ = await startingTask.result
            throw CancellationError()
        }
        if let startingTask {
            let id = startingID
            try await startingTask.value
            if startingID == id { self.startingTask = nil; startingID = nil; isStarting = false; countdown = nil }
        }
        if let stoppingTask { return try await stoppingTask.value }
        guard let stream, let sink, let id = sessionID else {
            if let outputURL { return outputURL }
            throw RecordingError.notRecording
        }
        isRecording = false
        isStopping = true
        isPaused = false
        controlRevision += 1
        timerTask?.cancel()
        timerTask = nil
        let task = Task { try await self.finish(stream: stream, sink: sink, id: id) }
        stoppingTask = task
        // Caller cancellation does not interrupt durable-save finalization.
        return try await task.value
    }

    func cancel() async {
        let restart = restartingTask
        restart?.cancel()
        await cancelSession()
        _ = await restart?.result
    }

    private func cancelSession() async {
        let targetID = sessionID
        cancelRequested = true
        if let startingTask {
            startingTask.cancel()
            _ = await startingTask.result
            // The start() caller's defer may resume later than this cancellation.
            // Clear only the same generation before a restart can begin.
            if sessionID == nil, startingID == targetID { self.startingTask = nil; startingID = nil; isStarting = false; countdown = nil }
        }
        guard sessionID == targetID else { return }
        if let stoppingTask {
            stoppingTask.cancel()
            _ = await stoppingTask.result
        } else if let stream, let sink, let id = sessionID {
            isRecording = false
            isPaused = false
            isStopping = true
            timerTask?.cancel()
            timerTask = nil
            let task = Task { try await self.finish(stream: stream, sink: sink, id: id) }
            stoppingTask = task
            _ = await task.result
        }
        // A published output belongs to the user. Never remove saved movies.
    }

    private func begin(id: UUID, displayID: CGDirectDisplayID, region: CGRect?, options: RecordingOptions) async throws {
        var createdSink: RecordingWriter?
        var createdStream: SCStream?
        do {
            try Task.checkCancellation()
            try screenPermissionCheck()
            if options.capturesMicrophone {
                let permitted: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: permitted = true
                case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for: .audio)
                default: permitted = false
                }
                guard permitted else { throw RecordingError.microphonePermission }
            }
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let bounds = CGRect(origin: .zero, size: filter.contentRect.size)
            let source = try Self.validatedRegion(region, bounds: bounds)
            let size = Self.encodedSize(for: source.size, scale: CGFloat(filter.pointPixelScale))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
            configuration.sourceRect = source
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = true
            configuration.capturesAudio = options.capturesSystemAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) { configuration.captureMicrophone = options.capturesMicrophone }
            #endif
            try Task.checkCancellation()
            let writer = try RecordingWriter(size: size, options: options) { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    if let message { self.error = message }
                    _ = try? await self.stop()
                }
            }
            createdSink = writer
            let capture = SCStream(filter: filter, configuration: configuration, delegate: writer)
            createdStream = capture
            try capture.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.capturesSystemAudio { try capture.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
            #if compiler(>=6.0)
            if #available(macOS 15.0, *), options.capturesMicrophone {
                try capture.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            }
            #endif
            self.stream = capture
            self.sink = writer
            try await capture.startCapture()
            try Task.checkCancellation()
            guard !cancelRequested else { throw CancellationError() }
            isRecording = true
            wallStartedAt = ContinuousClock.now
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                    guard let self, self.sessionID == id, self.isRecording else { break }
                    let snapshot = await writer.snapshot()
                    guard self.sessionID == id, self.isRecording else { break }
                    self.elapsed = max(self.elapsed, snapshot.elapsed)
                    let wall = self.wallStartedAt?.duration(to: ContinuousClock.now).components
                    let wallElapsed = Double(wall?.seconds ?? 0) + Double(wall?.attoseconds ?? 0) / 1e18
                    if self.elapsed >= options.maximumDuration || wallElapsed >= options.maximumWallDuration {
                        if wallElapsed >= options.maximumWallDuration {
                            self.error = "Recording stopped at its total time limit, including pauses."
                        }
                        _ = try? await self.stop()
                        break
                    }
                }
            }
        } catch {
            // startCapture can fail after allocating outputs; tear down every path.
            if let createdStream { try? await createdStream.stopCapture(); Self.detach(createdStream, sink: createdSink) }
            if let createdSink { await createdSink.discard() }
            if sessionID == id {
                stream = nil
                sink = nil
                sessionID = nil
                isRecording = false
                isStopping = false
                isPaused = false
            }
            throw error
        }
    }

    private func finish(stream: SCStream, sink: RecordingWriter, id: UUID) async throws -> URL {
        defer {
            if sessionID == id {
                self.stream = nil
                self.sink = nil
                self.sessionID = nil
                self.stoppingTask = nil
                self.isRecording = false
                self.isStopping = false
                self.isPaused = false
                self.wallStartedAt = nil
            }
        }
        do {
            let snapshot = await sink.stopAccepting()
            if sessionID == id { elapsed = max(elapsed, snapshot.elapsed) }
            // A stream may already be stopped by macOS (display disconnect, TCC,
            // sleep). Still finalize any frames already received instead of losing them.
            do { try await stream.stopCapture() }
            catch { if !cancelRequested { self.error = error.localizedDescription } }
            Self.detach(stream, sink: sink)
            if cancelRequested || Task.isCancelled {
                await sink.discard()
                throw CancellationError()
            }
            var url = try await sink.finish()
            if options.capturesSystemAudio && options.capturesMicrophone {
                do { url = try await Self.mixAudio(in: url, maximumFileSize: options.maximumFileSize) }
                catch {
                    if Task.isCancelled || cancelRequested { throw CancellationError() }
                    // Preserve the successful recording even if post-processing
                    // fails. The original MP4 retains both separate audio tracks.
                    self.error = "Recording saved with separate audio tracks; audio mixing failed: \(error.localizedDescription)"
                    let partialMix = url.deletingLastPathComponent().appendingPathComponent("recording-mixed.mp4")
                    try? FileManager.default.removeItem(at: partialMix)
                }
            }
            if cancelRequested || Task.isCancelled {
                await sink.discard()
                throw CancellationError()
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= options.maximumFileSize else { throw RecordingError.sizeLimit }
            do {
                let savedURL = try RecordingFileStorage.publish(from: url)
                outputURL = savedURL
                return savedURL
            } catch {
                // Staging also lives in Movies/PicShot, so a rename failure must
                // never delete the completed recording. Keep a recoverable file.
                self.error = "Recording finished but could not be renamed. Your recording is safe at \(url.path). \(error.localizedDescription)"
                outputURL = url
                return url
            }
        } catch {
            await sink.discard()
            if !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }

    private static func detach(_ stream: SCStream, sink: RecordingWriter?) {
        guard let sink else { return }
        try? stream.removeStreamOutput(sink, type: .screen)
        try? stream.removeStreamOutput(sink, type: .audio)
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { try? stream.removeStreamOutput(sink, type: .microphone) }
        #endif
    }

    static func validatedRegion(_ region: CGRect?, bounds: CGRect) throws -> CGRect {
        let result = region ?? bounds
        guard [result.origin.x, result.origin.y, result.width, result.height].allSatisfy({ $0.isFinite }),
              result.width >= 2, result.height >= 2, bounds.contains(result) else { throw RecordingError.invalidRegion }
        return result
    }

    static func encodedSize(for pointSize: CGSize, scale: CGFloat) -> CGSize {
        // H.264 dimensions are even. Downsample 5K/6K monitors instead of creating
        // enormous surfaces or relying on unsupported hardware encoder dimensions.
        let width = max(2, pointSize.width * max(1, scale))
        let height = max(2, pointSize.height * max(1, scale))
        let ratio = min(1, 3_840 / max(width, height), sqrt(8_294_400 / (width * height)))
        return CGSize(width: max(2, Int(width * ratio) / 2 * 2), height: max(2, Int(height * ratio) / 2 * 2))
    }

    private static func mixAudio(in source: URL, maximumFileSize: Int64) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return source }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(0.8, at: .zero)
            return parameters
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.failed("The audio mixer could not be created.")
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent("recording-mixed.mp4")
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.audioMix = mix
        exporter.fileLengthLimit = maximumFileSize
        try await withTaskCancellationHandler {
            await exporter.export()
            try Task.checkCancellation()
            guard exporter.status == .completed else {
                throw RecordingError.failed(exporter.error?.localizedDescription ?? "Audio mixing failed.")
            }
        } onCancel: { exporter.cancelExport() }
        try FileManager.default.removeItem(at: source)
        return destination
    }
}


/// Stage on the output volume so promotion is a rename, never a partially visible
/// cross-volume copy. Each session owns only its unique hidden staging directory.
enum RecordingFileStorage {
    static func outputDirectory() throws -> URL {
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw RecordingError.failed("The Movies folder could not be found.")
        }
        let directory = movies.appendingPathComponent("PicShot", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makeStagingDirectory(in outputDirectory: URL? = nil) throws -> URL {
        let root = try outputDirectory ?? Self.outputDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    static func publish(from source: URL, in outputDirectory: URL? = nil) throws -> URL {
        let root = try outputDirectory ?? Self.outputDirectory()
        let staging = source.deletingLastPathComponent()
        guard staging.lastPathComponent.hasPrefix(".recording-"),
              staging.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
            throw RecordingError.failed("The recording is outside its owned staging directory.")
        }
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "PicShot-\(date)-\(UUID().uuidString.prefix(8)).mp4"
        let destination = root.appendingPathComponent(name)
        // The destination is a fresh name on the same volume. Existing user files
        // are never overwritten; failed moves preserve the original for recovery.
        try FileManager.default.moveItem(at: source, to: destination)
        try? FileManager.default.removeItem(at: staging)
        return destination
    }
}

struct RecordingWriterSnapshot: Sendable {
    let elapsed: TimeInterval
    let wallElapsed: TimeInterval
    let isPaused: Bool
    let retainedVideoFrames: Int
}

/// All writer, input, sample, and limit state is confined to `queue` after init.
/// ScreenCaptureKit invokes sample callbacks on that same serial queue. Pausing
/// drops audio immediately, retaining the last encoded frame and at most one
/// current screen snapshot so Resume also works when the desktop becomes static.
final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "PicShot.Recording.Encoder", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let directory: URL
    private let url: URL
    private let options: RecordingOptions
    private let requestStop: @Sendable (String?) -> Void
    private let clock: @Sendable () -> CMTime
    private let wallStart: CMTime
    private var sourceClock: CMClock?
    private var fallbackSourceOffset: CMTime?
    private var accepting = true
    private var finishing = false
    private var discarded = false
    private var finishedResult: Result<URL, Error>?
    private var finishContinuation: CheckedContinuation<URL, Error>?
    private var finishTimeout: DispatchWorkItem?
    private var stopRequested = false
    private var timeline = RecordingTimeline()
    private var lastVideo: CMSampleBuffer?
    private var pausedVideo: CMSampleBuffer?
    private var pendingResumeVideo: CMSampleBuffer?
    private var pendingResumeSourceTime: CMTime?
    private var lastVideoTime = CMTime.invalid
    private var lastSystemAudioEnd = CMTime.invalid
    private var lastMicrophoneEnd = CMTime.invalid
    private var lastDiskCheck = CMTime.invalid

    init(size: CGSize, options: RecordingOptions, outputDirectory: URL? = nil,
         clock: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
         requestStop: @escaping @Sendable (String?) -> Void) throws {
        try options.validate()
        self.options = options
        self.requestStop = requestStop
        self.clock = clock
        wallStart = clock()
        let recordingDirectory = try RecordingFileStorage.makeStagingDirectory(in: outputDirectory)
        directory = recordingDirectory
        url = recordingDirectory.appendingPathComponent("recording.mp4")
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let bitRate = min(16_000_000, max(1_000_000, Int(size.width * size.height * CGFloat(options.frameRate) * 0.08)))
            video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoExpectedSourceFrameRateKey: options.frameRate,
                    AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ])
            video.expectsMediaDataInRealTime = true
            systemAudio = options.capturesSystemAudio ? Self.audioInput(channels: 2) : nil
            // ScreenCaptureKit supplies native microphone samples. AVAssetWriter
            // converts their input sample rate/channel layout to this AAC mono track.
            microphone = options.capturesMicrophone ? Self.audioInput(channels: 1) : nil
            super.init()
            for input in [video, systemAudio, microphone].compactMap({ $0 }) {
                guard writer.canAdd(input) else { throw RecordingError.failed("The H.264/AAC encoder is unavailable.") }
                writer.add(input)
            }
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            guard writer.startWriting() else { throw RecordingError.failed(writer.error?.localizedDescription ?? "The MP4 could not be opened.") }
        } catch {
            try? FileManager.default.removeItem(at: recordingDirectory)
            throw error
        }
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    private var sourceNow: CMTime {
        if let sourceClock { return CMClockGetTime(sourceClock) }
        // Synthetic consumers need not use host-epoch PTS. Live capture always
        // uses the SCStream clock, never callback arrival time as a media clock.
        return CMTimeAdd(clock(), fallbackSourceOffset ?? .zero)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if sourceClock == nil { sourceClock = stream.synchronizationClock }
        consume(sampleBuffer, of: type)
    }

    /// Queue-confined entry shared by live capture and synthetic media tests.
    /// The return value reports encoder acceptance, not merely a valid input.
    @discardableResult
    func consume(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard accepting, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return false }
        if writer.status == .failed {
            notifyStop(writer.error?.localizedDescription ?? "The video encoder stopped.")
            return false
        }
        checkLimits()
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard !stopRequested, sourceTime.isNumeric else { return false }
        if timeline.isPaused {
            if type == .screen, Self.isCompleteScreenFrame(sampleBuffer),
               pausedVideo.map({ CMTimeCompare(sourceTime, CMSampleBufferGetPresentationTimeStamp($0)) >= 0 }) ?? true {
                pausedVideo = sampleBuffer
            }
            return false
        }
        guard timeline.accepts(sourceTime) else { return false }
        let input: AVAssetWriterInput
        if type == .screen {
            guard Self.isCompleteScreenFrame(sampleBuffer) else { return false }
            // A complete frame at the exact resume boundary supersedes the cached
            // snapshot. Otherwise insert the current paused-screen image at the cut.
            guard appendResumeFrame(before: sourceTime), video.isReadyForMoreMediaData else { return false }
            input = video
            if timeline.sourceStart == nil {
                if sourceClock == nil { fallbackSourceOffset = CMTimeSubtract(sourceTime, clock()) }
                timeline.start(at: sourceTime)
                writer.startSession(atSourceTime: .zero)
            }
        } else if type == .audio, let systemAudio {
            input = systemAudio
        } else {
            #if compiler(>=6.0)
            if #available(macOS 15.0, *), type == .microphone, let microphone { input = microphone }
            else { return false }
            #else
            return false
            #endif
        }
        guard input.isReadyForMoreMediaData,
              let timestamp = timeline.presentationTime(for: sourceTime) else { return false }
        guard timestamp.seconds < options.maximumDuration else { notifyStop(nil); return false }
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if type == .screen {
            guard !lastVideoTime.isValid || CMTimeCompare(timestamp, lastVideoTime) > 0 else { return false }
            if !duration.isNumeric || CMTimeCompare(duration, .zero) <= 0 {
                duration = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
            }
        } else {
            let previousEnd = type == .audio ? lastSystemAudioEnd : lastMicrophoneEnd
            guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0,
                  !previousEnd.isValid || CMTimeCompare(timestamp, previousEnd) >= 0 else { return false }
        }
        do {
            let offset = CMTimeSubtract(sourceTime, timestamp)
            let sample = try RecordingSampleTiming.copy(sampleBuffer, subtracting: offset)
            guard input.append(sample) else {
                notifyStop(writer.error?.localizedDescription ?? "A recording sample could not be encoded.")
                return false
            }
            timeline.committed(through: CMTimeAdd(sourceTime, duration))
            if type == .screen {
                lastVideo = sample
                lastVideoTime = timestamp
            } else if type == .audio { lastSystemAudioEnd = CMTimeAdd(timestamp, duration) }
            else { lastMicrophoneEnd = CMTimeAdd(timestamp, duration) }
            return true
        } catch { notifyStop(error.localizedDescription); return false }
    }

    private static func isCompleteScreenFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: rawStatus) == .complete && CMSampleBufferGetImageBuffer(sample) != nil
    }

    /// A constant-space snapshot, never an accumulated queue of paused frames.
    /// Returns false only for encoder backpressure or failure.
    private func appendResumeFrame(before nextSourceTime: CMTime? = nil) -> Bool {
        guard let sample = pendingResumeVideo, let sourceTime = pendingResumeSourceTime,
              let start = timeline.sourceStart else { return true }
        if let nextSourceTime, CMTimeCompare(nextSourceTime, sourceTime) <= 0 {
            pendingResumeVideo = nil
            pendingResumeSourceTime = nil
            return true
        }
        let timestamp = CMTimeSubtract(CMTimeSubtract(sourceTime, start), timeline.removedDuration)
        guard !lastVideoTime.isValid || CMTimeCompare(timestamp, lastVideoTime) > 0 else {
            pendingResumeVideo = nil
            pendingResumeSourceTime = nil
            return true
        }
        guard video.isReadyForMoreMediaData else { return false }
        let duration = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
              let copy, video.append(copy) else {
            notifyStop(writer.error?.localizedDescription ?? "The resumed screen frame could not be encoded.")
            return false
        }
        lastVideo = copy
        lastVideoTime = timestamp
        timeline.committed(through: CMTimeAdd(sourceTime, duration))
        pendingResumeVideo = nil
        pendingResumeSourceTime = nil
        return true
    }

    func setPaused(_ paused: Bool) async throws -> RecordingWriterSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.accepting, !self.stopRequested else {
                    continuation.resume(throwing: RecordingError.notRecording)
                    return
                }
                if paused, !self.timeline.isPaused {
                    // Normal real-time backpressure may drop this one cached
                    // resume image, just as it may drop any live video frame.
                    _ = self.appendResumeFrame()
                    self.pendingResumeVideo = nil
                    self.pendingResumeSourceTime = nil
                    self.timeline.pause(at: self.sourceNow)
                } else if !paused, self.timeline.isPaused {
                    self.timeline.resume(at: self.sourceNow)
                    self.pendingResumeVideo = self.pausedVideo
                    self.pendingResumeSourceTime = self.pendingResumeVideo == nil ? nil : self.timeline.minimumSourceTime
                    self.pausedVideo = nil
                    if self.timeline.sourceStart == nil, let sourceTime = self.pendingResumeSourceTime {
                        self.timeline.start(at: sourceTime)
                        self.writer.startSession(atSourceTime: .zero)
                    }
                }
                continuation.resume(returning: self.currentSnapshot())
            }
        }
    }

    func snapshot() async -> RecordingWriterSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.currentSnapshot()) }
        }
    }

    private func currentSnapshot() -> RecordingWriterSnapshot {
        RecordingWriterSnapshot(elapsed: min(options.maximumDuration, timeline.activeDuration(at: sourceNow).seconds),
            wallElapsed: max(0, CMTimeSubtract(clock(), wallStart).seconds), isPaused: timeline.isPaused,
            retainedVideoFrames: (lastVideo == nil ? 0 : 1) + (pausedVideo == nil ? 0 : 1) + (pendingResumeVideo == nil ? 0 : 1))
    }

    /// Freeze before awaiting SCStream.stopCapture, whose teardown latency must
    /// not lengthen a clip. Pending callbacks after this barrier are ignored.
    func stopAccepting() async -> RecordingWriterSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.freeze()
                continuation.resume(returning: self.currentSnapshot())
            }
        }
    }

    private func freeze() {
        accepting = false
        pausedVideo = nil
        timeline.stop(at: sourceNow)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.notifyStop(error.localizedDescription) }
    }

    private func notifyStop(_ message: String?) {
        guard !stopRequested, accepting else { return }
        stopRequested = true
        requestStop(message)
    }

    private func checkLimits() {
        let now = clock()
        if timeline.activeDuration(at: sourceNow).seconds >= options.maximumDuration { notifyStop(nil) }
        if CMTimeSubtract(now, wallStart).seconds >= options.maximumWallDuration {
            notifyStop("Recording stopped at its total time limit, including pauses.")
        }
        guard !lastDiskCheck.isValid || CMTimeSubtract(now, lastDiskCheck).seconds >= 0.5 else { return }
        lastDiskCheck = now
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .volumeAvailableCapacityKey])
            let stopSize = max(1, options.maximumFileSize - 8_388_608)
            if Int64(values.fileSize ?? 0) >= stopSize { notifyStop("Recording stopped at its file-size limit.") }
            if let available = values.volumeAvailableCapacity, available < 67_108_864 {
                notifyStop("Recording stopped because the disk is nearly full.")
            }
        } catch { notifyStop("The recording file could not be checked: \(error.localizedDescription)") }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.discarded { continuation.resume(throwing: CancellationError()); return }
                if let result = self.finishedResult { continuation.resume(with: result); return }
                guard !self.finishing else { continuation.resume(throwing: RecordingError.busy); return }
                self.finishing = true
                self.finishContinuation = continuation
                self.freeze()
                guard self.writer.status == .writing, self.timeline.sourceStart != nil, self.lastVideo != nil || self.pendingResumeVideo != nil else {
                    let error = self.writer.error.map { RecordingError.failed($0.localizedDescription) } ?? .noFrames
                    if self.writer.status == .writing || self.writer.status == .unknown { self.writer.cancelWriting() }
                    self.complete(.failure(error))
                    return
                }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.finishContinuation != nil else { return }
                    if self.writer.status == .writing { self.writer.cancelWriting() }
                    self.complete(.failure(RecordingError.failed("The encoder did not finish within 30 seconds.")))
                }
                self.finishTimeout = timeout
                self.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(self.options.frameRate))
                let maximumEnd = CMTime(seconds: self.options.maximumDuration, preferredTimescale: 48_000)
                let activeEnd = self.timeline.activeDuration(at: self.sourceNow)
                let lastEnd = self.lastVideoTime.isNumeric ? CMTimeAdd(self.lastVideoTime, frameDuration) : frameDuration
                let end = CMTimeMinimum(maximumEnd, CMTimeMaximum(activeEnd, lastEnd))
                self.finalizeVideo(endingAt: end, frameDuration: frameDuration)
            }
        }
    }

    private func finalizeVideo(endingAt end: CMTime, frameDuration: CMTime) {
        guard finishContinuation != nil, !discarded else { return }
        guard writer.status == .writing else {
            complete(.failure(RecordingError.failed(writer.error?.localizedDescription ?? "The final frame could not be encoded.")))
            return
        }
        // If the desktop changed during Pause and then stayed still, there may
        // be no complete video callback after Resume. Preserve its current image.
        if let sourceTime = pendingResumeSourceTime, let start = timeline.sourceStart {
            let timestamp = CMTimeSubtract(CMTimeSubtract(sourceTime, start), timeline.removedDuration)
            if CMTimeCompare(timestamp, end) >= 0 {
                pendingResumeVideo = nil
                pendingResumeSourceTime = nil
            } else if !appendResumeFrame() {
                queue.asyncAfter(deadline: .now() + 0.01) { self.finalizeVideo(endingAt: end, frameDuration: frameDuration) }
                return
            }
        }
        let finalTime = CMTimeSubtract(end, frameDuration)
        if CMTimeCompare(finalTime, lastVideoTime) > 0, let lastFrame = lastVideo {
            // Encoder backpressure at Stop must not silently shorten a static
            // recording. Poll one retained frame; the overall watchdog is bounded.
            guard video.isReadyForMoreMediaData else {
                queue.asyncAfter(deadline: .now() + 0.01) { self.finalizeVideo(endingAt: end, frameDuration: frameDuration) }
                return
            }
            var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: finalTime, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastFrame,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                  let copy, video.append(copy) else {
                complete(.failure(RecordingError.failed(writer.error?.localizedDescription ?? "The final frame could not be encoded.")))
                return
            }
        }
        lastVideo = nil
        writer.endSession(atSourceTime: end)
        video.markAsFinished()
        systemAudio?.markAsFinished()
        microphone?.markAsFinished()
        writer.finishWriting {
            self.queue.async {
                guard self.finishContinuation != nil else { return }
                if self.discarded { self.complete(.failure(CancellationError())) }
                else if self.writer.status == .completed { self.complete(.success(self.url)) }
                else { self.complete(.failure(RecordingError.failed(self.writer.error?.localizedDescription ?? "The MP4 could not be finalized."))) }
            }
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        finishTimeout?.cancel()
        finishTimeout = nil
        lastVideo = nil
        pausedVideo = nil
        pendingResumeVideo = nil
        pendingResumeSourceTime = nil
        finishedResult = result
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(with: result)
    }

    func discard() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.freeze()
                self.discarded = true
                self.lastVideo = nil
                if self.writer.status == .writing || self.writer.status == .unknown { self.writer.cancelWriting() }
                self.complete(.failure(CancellationError()))
                try? FileManager.default.removeItem(at: self.directory)
                continuation.resume()
            }
        }
    }
}
