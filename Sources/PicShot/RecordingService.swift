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
    var maximumFileSize: Int64 = 1_073_741_824

    func validate() throws {
        guard (1...60).contains(frameRate), maximumDuration.isFinite,
              (1...3_600).contains(maximumDuration),
              (16_777_216...4_294_967_296).contains(maximumFileSize) else {
            throw RecordingError.invalidOptions
        }
    }
}

enum RecordingError: LocalizedError {
    case busy, notRecording, noFrames, invalidOptions, microphoneUnavailable, microphonePermission
    case invalidRegion, failed(String), sizeLimit

    var errorDescription: String? {
        switch self {
        case .busy: return "A recording is already starting, running, or being saved."
        case .notRecording: return "There is no recording to save."
        case .noFrames: return "No video frames were received. Check screen recording permission and try again."
        case .invalidOptions: return "Use 1–60 FPS, a duration of 1 second to 1 hour, and a file limit of 16 MB to 4 GB."
        case .microphoneUnavailable: return "Microphone recording requires macOS 15 or later and a PicShot build made with Xcode 16 or later. System audio is available on macOS 14."
        case .microphonePermission: return "Allow PicShot to use the microphone in System Settings → Privacy & Security → Microphone."
        case .invalidRegion: return "The recording region must be at least 2 × 2 points and entirely inside the selected display."
        case .failed(let message): return "Couldn’t record the screen: \(message)"
        case .sizeLimit: return "The recording exceeded its file-size limit. Try a shorter recording or a smaller region."
        }
    }
}

/// No frame arrays: ScreenCaptureKit has a three-frame queue and the encoder drops
/// frames under backpressure. The writer retains only the most recent video frame.
@MainActor
final class RecordingService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStopping = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var error: String?
    /// Also set on an automatic duration/size stop. The caller owns the returned file.
    @Published private(set) var outputURL: URL?

    private var startingTask: Task<Void, Error>?
    private var stoppingTask: Task<URL, Error>?
    private var timerTask: Task<Void, Never>?
    private var stream: SCStream?
    private var sink: RecordingWriter?
    private var sessionID: UUID?
    private var options = RecordingOptions()
    private var beganAt: TimeInterval = 0
    private var cancelRequested = false

    static var supportsMicrophone: Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    func availableDisplays() async throws -> [SCDisplay] {
        try CaptureService.requireScreenPermission()
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    /// `region` is display-local logical points, with a top-left origin.
    func start(displayID: CGDirectDisplayID, region: CGRect? = nil, options: RecordingOptions = .init()) async throws {
        guard sessionID == nil, startingTask == nil, stoppingTask == nil else { throw RecordingError.busy }
        try options.validate()
        if options.capturesMicrophone, !Self.supportsMicrophone { throw RecordingError.microphoneUnavailable }
        let id = UUID()
        sessionID = id
        cancelRequested = false
        error = nil
        outputURL = nil
        elapsed = 0
        self.options = options
        let task = Task { try await self.begin(id: id, displayID: displayID, region: region, options: options) }
        startingTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            startingTask = nil
        } catch {
            startingTask = nil
            if !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }

    func stop() async throws -> URL {
        if let startingTask { try await startingTask.value }
        if let stoppingTask { return try await stoppingTask.value }
        guard let stream, let sink, let id = sessionID else {
            if let outputURL { return outputURL }
            throw RecordingError.notRecording
        }
        isRecording = false
        isStopping = true
        timerTask?.cancel()
        timerTask = nil
        let task = Task { try await self.finish(stream: stream, sink: sink, id: id) }
        stoppingTask = task
        // Cancellation of a caller does not interrupt file finalization. Use cancel()
        // when the user explicitly chooses to discard the recording.
        return try await task.value
    }

    func cancel() async {
        cancelRequested = true
        if let startingTask {
            startingTask.cancel()
            _ = await startingTask.result
        }
        if let stoppingTask {
            stoppingTask.cancel()
            _ = await stoppingTask.result
        } else if stream != nil {
            _ = try? await stop()
        }
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
            self.outputURL = nil
        }
    }

    private func begin(id: UUID, displayID: CGDirectDisplayID, region: CGRect?, options: RecordingOptions) async throws {
        var createdSink: RecordingWriter?
        var createdStream: SCStream?
        do {
            try Task.checkCancellation()
            try CaptureService.requireScreenPermission()
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
            beganAt = ProcessInfo.processInfo.systemUptime
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                    guard let self, self.sessionID == id, self.isRecording else { break }
                    self.elapsed = ProcessInfo.processInfo.systemUptime - self.beganAt
                    if self.elapsed >= options.maximumDuration {
                        _ = try? await self.stop()
                        break
                    }
                }
            }
        } catch {
            // startCapture can fail after allocating outputs; tear down every path.
            if let createdStream { try? await createdStream.stopCapture(); Self.detach(createdStream, sink: createdSink) }
            if let createdSink { await createdSink.discard() }
            stream = nil
            sink = nil
            sessionID = nil
            isRecording = false
            isStopping = false
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
            }
        }
        do {
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
                url = try await Self.mixAudio(in: url, maximumFileSize: options.maximumFileSize)
            }
            if cancelRequested || Task.isCancelled {
                await sink.discard()
                throw CancellationError()
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= options.maximumFileSize else { throw RecordingError.sizeLimit }
            outputURL = url
            return url
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

/// All writer, input, sample, and limit state is confined to `queue` after init.
/// ScreenCaptureKit invokes sample callbacks on that same serial queue.
private final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "PicShot.Recording.Encoder", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let directory: URL
    private let url: URL
    private let options: RecordingOptions
    private let requestStop: @Sendable (String?) -> Void
    private var accepting = true
    private var stopRequested = false
    private var sessionStart: CMTime?
    private var hostStart: TimeInterval = 0
    private var lastVideo: CMSampleBuffer?
    private var lastVideoTime = CMTime.invalid
    private var lastSystemAudioTime = CMTime.invalid
    private var lastMicrophoneTime = CMTime.invalid
    private var lastDiskCheck: TimeInterval = 0

    init(size: CGSize, options: RecordingOptions, requestStop: @escaping @Sendable (String?) -> Void) throws {
        self.options = options
        self.requestStop = requestStop
        let recordingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Recording-\(UUID().uuidString)", isDirectory: true)
        directory = recordingDirectory
        url = recordingDirectory.appendingPathComponent("recording.mp4")
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let bitRate = min(16_000_000, max(1_000_000, Int(size.width * size.height * Double(options.frameRate) * 0.08)))
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, timestamp.isNumeric else { return }
        if writer.status == .failed {
            notifyStop(writer.error?.localizedDescription ?? "The video encoder stopped.")
            return
        }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
                  video.isReadyForMoreMediaData else { return }
            if sessionStart == nil {
                writer.startSession(atSourceTime: timestamp)
                sessionStart = timestamp
                hostStart = ProcessInfo.processInfo.systemUptime
            }
            guard !lastVideoTime.isValid || CMTimeCompare(timestamp, lastVideoTime) > 0 else { return }
            if video.append(sampleBuffer) {
                lastVideo = sampleBuffer
                lastVideoTime = timestamp
            } else { notifyStop(writer.error?.localizedDescription ?? "A video frame could not be encoded.") }
        } else {
            // Do not buffer pre-roll audio or give the writer timestamps before its
            // first video frame. Backpressure is handled by dropping, never queuing.
            guard let sessionStart, CMTimeCompare(timestamp, sessionStart) >= 0 else { return }
            if type == .audio, let systemAudio {
                if !lastSystemAudioTime.isValid || CMTimeCompare(timestamp, lastSystemAudioTime) > 0,
                   systemAudio.isReadyForMoreMediaData {
                    if systemAudio.append(sampleBuffer) { lastSystemAudioTime = timestamp }
                    else { notifyStop(writer.error?.localizedDescription ?? "System audio could not be encoded.") }
                }
            } else {
                #if compiler(>=6.0)
                if #available(macOS 15.0, *), type == .microphone, let microphone,
                   !lastMicrophoneTime.isValid || CMTimeCompare(timestamp, lastMicrophoneTime) > 0,
                   microphone.isReadyForMoreMediaData {
                    if microphone.append(sampleBuffer) { lastMicrophoneTime = timestamp }
                    else { notifyStop(writer.error?.localizedDescription ?? "Microphone audio could not be encoded.") }
                }
                #endif
            }
        }
        checkLimits()
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
        let now = ProcessInfo.processInfo.systemUptime
        if sessionStart != nil, now - hostStart >= options.maximumDuration { notifyStop(nil) }
        guard now - lastDiskCheck >= 0.5 else { return }
        lastDiskCheck = now
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .volumeAvailableCapacityKey])
            // Reserve headroom for codec queues and MP4 finalization. The completed
            // result is checked against the exact user-facing limit before returning.
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
                self.accepting = false
                guard self.writer.status == .writing, let start = self.sessionStart, let lastFrame = self.lastVideo else {
                    let error = self.writer.error.map { RecordingError.failed($0.localizedDescription) } ?? .noFrames
                    self.writer.cancelWriting()
                    self.lastVideo = nil
                    continuation.resume(throwing: error)
                    return
                }
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(self.options.frameRate))
                let duration = min(self.options.maximumDuration, max(0, ProcessInfo.processInfo.systemUptime - self.hostStart))
                let wallEnd = CMTimeAdd(start, CMTime(seconds: duration, preferredTimescale: 600))
                let end = CMTimeMaximum(wallEnd, CMTimeAdd(self.lastVideoTime, frameDuration))
                // ScreenCaptureKit emits no new complete frames while a screen is
                // static. Extend its last frame so a 30-second still recording has
                // 30 seconds of video rather than ending at the last mouse movement.
                let finalTime = CMTimeSubtract(end, frameDuration)
                if CMTimeCompare(finalTime, self.lastVideoTime) > 0, self.video.isReadyForMoreMediaData {
                    var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: finalTime, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastFrame,
                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                       let copy { _ = self.video.append(copy) }
                }
                self.lastVideo = nil
                self.writer.endSession(atSourceTime: end)
                self.video.markAsFinished()
                self.systemAudio?.markAsFinished()
                self.microphone?.markAsFinished()
                self.writer.finishWriting {
                    self.queue.async {
                        if self.writer.status == .completed { continuation.resume(returning: self.url) }
                        else { continuation.resume(throwing: RecordingError.failed(self.writer.error?.localizedDescription ?? "The MP4 could not be finalized.")) }
                    }
                }
            }
        }
    }

    func discard() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                self.lastVideo = nil
                if self.writer.status == .writing || self.writer.status == .unknown { self.writer.cancelWriting() }
                try? FileManager.default.removeItem(at: self.directory)
                continuation.resume()
            }
        }
    }
}
