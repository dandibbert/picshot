import AppKit
import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit
import PicShotCore
import Darwin

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
    case pendingTake, preservationFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "A recording is already starting, running, or being saved."
        case .pendingTake: return "A stopped recording still needs to be protected. Retry protecting it before starting another recording or quitting."
        case .preservationFailed(let message): return "Capture has stopped, but the recording’s recovery copy could not be secured. Keep PicShot open and retry protecting the take. \(message)"
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
/// frames under backpressure. Overlay surfaces use a separate bounded pool.
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

    /// One stopped encoder may remain alive until its recovery copy is durable.
    /// New recording is blocked instead of accumulating quarantined writers.
    @Published private(set) var hasPendingTake = false
    var onPendingTakePreserved: (() -> Void)?

    let composition: RecordingCompositionState
    let camera: RecordingCameraController
    let overlay: RecordingOverlayController
    let inputMonitor: RecordingInputMonitor

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
    private var pendingTake: RecordingWriter?
    private var pendingPreservationTask: Task<Void, Error>?
    private var sessionID: UUID?
    private var options = RecordingOptions()
    private var wallStartedAt: ContinuousClock.Instant?
    private var cancelRequested = false
    private let screenPermissionCheck: @MainActor () throws -> Void

    init(screenPermissionCheck: (@MainActor () throws -> Void)? = nil,
         inputMonitorDependencies: RecordingInputMonitorDependencies? = nil) {
        self.screenPermissionCheck = screenPermissionCheck ?? { try CaptureService.requireScreenPermission() }
        let composition = RecordingCompositionState()
        self.composition = composition
        camera = RecordingCameraController(composition: composition)
        overlay = RecordingOverlayController(state: composition)
        inputMonitor = RecordingInputMonitor(state: composition.inputEffects, dependencies: inputMonitorDependencies)
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
        guard !hasPendingTake else { throw RecordingError.pendingTake }
        guard restartingTask == nil else { throw RecordingError.busy }
        try await startSession(displayID: displayID, region: region, options: options, delay: delay)
    }

    private func startSession(displayID: CGDirectDisplayID, region: CGRect?, options: RecordingOptions,
                              delay: TimeInterval) async throws {
        guard !hasPendingTake else { throw RecordingError.pendingTake }
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
            if sessionID == nil {
                inputMonitor.endSession()
                overlay.hide()
                if isRestarting { await camera.suspend() } else { await camera.disable() }
            }
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
        // Remove native input listeners immediately on Pause. A rejected writer
        // command cannot leave input monitoring active behind an error message.
        if paused { inputMonitor.setPaused(true, at: ProcessInfo.processInfo.systemUptime) }
        let snapshot: RecordingWriterSnapshot
        do { snapshot = try await sink.setPaused(paused) }
        catch {
            inputMonitor.endSession()
            throw error
        }
        guard sessionID == id, isRecording, !isStopping else { throw RecordingError.notRecording }
        elapsed = max(elapsed, snapshot.elapsed)
        if revision == controlRevision {
            isPaused = snapshot.isPaused
            inputMonitor.setPaused(snapshot.isPaused, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Save the unfinished take by default. Explicit `discardUnfinished: true`
    /// discards only that take. Previously published movies are never deleted.
    /// The returned URL is the previous saved take, if one was saved.
    func restart(discardUnfinished: Bool = false, delay: TimeInterval = 0) async throws -> URL? {
        try Self.validateDelay(delay)
        guard !hasPendingTake else { throw RecordingError.pendingTake }
        guard restartingTask == nil, !isStopping else { throw RecordingError.busy }
        guard sessionID != nil, let request = lastRequest else { throw RecordingError.notRecording }
        let token = UUID()
        restartID = token
        isRestarting = true
        let task = Task<URL?, Error> {
            let previous: URL?
            if discardUnfinished || (self.isStarting && self.countdown != nil) {
                try await self.cancelSession()
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
        // Effects disappear for future output at the user's stop request, and
        // no global monitor survives potentially slow encoder/disk finalization.
        inputMonitor.endSession()
        guard !hasPendingTake else { throw RecordingError.pendingTake }
        if countdown != nil, let startingTask {
            startingTask.cancel()
            _ = await startingTask.result
            overlay.hide()
            await camera.disable()
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
        do { try await cancelSession() }
        catch {
            // Keep the actionable disk error on an already blocked take.
            if !hasPendingTake || self.error == nil { self.error = error.localizedDescription }
        }
        _ = await restart?.result
    }

    private func cancelSession() async throws {
        inputMonitor.endSession()
        guard !hasPendingTake else { throw RecordingError.pendingTake }
        let targetID = sessionID
        cancelRequested = true
        if let startingTask {
            startingTask.cancel()
            let result = await startingTask.result
            if case .failure(let failure) = result, hasPendingTake { throw failure }
            // The start() caller's defer may resume later than this cancellation.
            // Clear only the same generation before a restart can begin.
            if sessionID == nil, startingID == targetID { self.startingTask = nil; startingID = nil; isStarting = false; countdown = nil }
        }
        if sessionID == nil {
            overlay.hide()
            if isRestarting { await camera.suspend() } else { await camera.disable() }
            return
        }
        guard sessionID == targetID else { return }
        if let stoppingTask {
            stoppingTask.cancel()
            let result = await stoppingTask.result
            if case .failure(let failure) = result, !(failure is CancellationError) { throw failure }
        } else if let stream, let sink, let id = sessionID {
            isRecording = false
            isPaused = false
            isStopping = true
            timerTask?.cancel()
            timerTask = nil
            let task = Task { try await self.finish(stream: stream, sink: sink, id: id) }
            stoppingTask = task
            let result = await task.result
            if case .failure(let failure) = result, !(failure is CancellationError) { throw failure }
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
            // Application exclusion also covers controls/overlays created after
            // this filter, unlike a one-time list of visible window IDs. Preview
            // pixels are composed exactly once by RecordingWriter, never captured.
            let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            guard !ownApplications.isEmpty else {
                throw RecordingError.failed("PicShot’s recording controls could not be excluded from screen capture.")
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
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
            composition.setCanvasSize(size)
            let compositor = try RecordingFrameCompositor(size: size, state: composition)
            let writer = try RecordingWriter(size: size, options: options, compositor: compositor) { [weak self] message in
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
            var inputFrame: CGRect?
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }) {
                let frame = CGRect(x: screen.frame.minX + source.minX, y: screen.frame.maxY - source.maxY,
                    width: source.width, height: source.height)
                inputFrame = frame
                overlay.show(frame: frame, canvasSize: size)
            }
            if camera.requested, camera.status == .off { await camera.enable() }
            try Task.checkCancellation()
            try await capture.startCapture()
            try Task.checkCancellation()
            guard !cancelRequested else { throw CancellationError() }
            isRecording = true
            if let inputFrame {
                inputMonitor.beginSession(frame: inputFrame, at: ProcessInfo.processInfo.systemUptime)
            }
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
            let originalError = error
            inputMonitor.endSession()
            // Freeze and detach capture before any fallible disk protection.
            if let createdSink { _ = await createdSink.stopAccepting() }
            overlay.hide()
            await camera.disable()
            if let createdStream { try? await createdStream.stopCapture(); Self.detach(createdStream, sink: createdSink) }
            defer {
                if sessionID == id {
                    stream = nil
                    sink = nil
                    sessionID = nil
                    isRecording = false
                    isStopping = false
                    isPaused = false
                    wallStartedAt = nil
                }
            }
            if let createdSink { try await preserveStoppedTake(createdSink) }
            throw originalError
        }
    }

    private func finish(stream: SCStream, sink: RecordingWriter, id: UUID) async throws -> URL {
        inputMonitor.endSession()
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
            overlay.hide()
            // The writer froze the final composition at its stop barrier. Release
            // camera hardware before potentially slow stream/encoder cleanup.
            if isRestarting { await camera.suspend() } else { await camera.disable() }
            if sessionID == id { elapsed = max(elapsed, snapshot.elapsed) }
            // A stream may already be stopped by macOS (display disconnect, TCC,
            // sleep). Still finalize any frames already received instead of losing them.
            do { try await stream.stopCapture() }
            catch { if !cancelRequested { self.error = error.localizedDescription } }
            Self.detach(stream, sink: sink)
            if cancelRequested || Task.isCancelled {
                try await sink.discard()
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
                try await sink.discard()
                throw CancellationError()
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= options.maximumFileSize else { throw RecordingError.sizeLimit }
            do {
                let savedURL = try await sink.publishFinished(mediaURL: url)
                outputURL = savedURL
                return savedURL
            } catch {
                // Staging also lives in Movies/PicShot, so a rename failure must
                // never delete the completed recording. Keep a recoverable file.
                guard let retainedURL = await sink.recoverableURLAndClose() else { throw error }
                self.error = "Recording finished but its save transaction needs recovery. Your recording is safe at \(retainedURL.path). \(error.localizedDescription)"
                outputURL = retainedURL
                return retainedURL
            }
        } catch {
            if isRestarting { await camera.suspend() } else { await camera.disable() }
            let originalError = error
            // A failed protection must remain visible and retryable; never
            // immediately retry and accidentally hide the failed save attempt.
            if let failure = originalError as? RecordingError, case .preservationFailed = failure {
                retainPendingTake(sink, error: originalError)
            } else {
                try await preserveStoppedTake(sink)
                if !(originalError is CancellationError) { self.error = originalError.localizedDescription }
            }
            throw originalError
        }
    }

    /// The caller has already stopped/detached capture hardware. This is also a
    /// hardware-free integration seam for exercising preservation failures.
    func preserveStoppedTake(_ take: RecordingWriter) async throws {
        guard pendingTake == nil || pendingTake === take else { throw RecordingError.pendingTake }
        do {
            try await take.abandonPreservingRecovery()
        } catch {
            retainPendingTake(take, error: error)
            throw error
        }
    }

    private func retainPendingTake(_ take: RecordingWriter, error: Error) {
        // start/restart cannot create another writer while this slot is occupied.
        precondition(pendingTake == nil || pendingTake === take)
        pendingTake = take
        hasPendingTake = true
        self.error = error.localizedDescription
    }

    /// Secure the stopped take, then release its encoder into explicit recovery.
    /// Multiple clicks share one bounded operation and never create a new take.
    func retryPendingTakePreservation(presentRecovery: Bool = true) async throws {
        if let pendingPreservationTask { return try await pendingPreservationTask.value }
        guard let take = pendingTake else { return }
        let task = Task {
            do {
                try await take.abandonPreservingRecovery()
                self.pendingTake = nil
                self.hasPendingTake = false
                self.error = nil
                if presentRecovery { self.onPendingTakePreserved?() }
            } catch {
                self.error = error.localizedDescription
                throw error
            }
        }
        pendingPreservationTask = task
        defer { pendingPreservationTask = nil }
        try await task.value
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
        // Keep the finalized original until the recovery journal has durably
        // transferred identity to the mixed copy. It remains available in staging.
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
        guard !FileManager.default.fileExists(atPath: staging.appendingPathComponent(RecordingRecoveryJournal.filename).path) else {
            throw RecordingError.failed("This recording has a recovery journal and must be published through its writer transaction.")
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
    let queue = DispatchQueue(label: "PicShot.Recording.Encoder", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let directory: URL
    private let url: URL
    private let options: RecordingOptions
    private var recoveryLease: RecordingRecoveryLease?
    private let protectBeforeCancellation: @Sendable (RecordingRecoveryLease) throws -> Void
    private let requestStop: @Sendable (String?) -> Void
    private let clock: @Sendable () -> CMTime
    private let wallStart: CMTime
    private let compositor: RecordingFrameCompositor?
    private var overlayTimer: DispatchSourceTimer?
    private var latestScreen: CMSampleBuffer?
    private var screenRevision: UInt64 = 0
    private var encodedScreenRevision: UInt64 = 0
    private var sourceClock: CMClock?
    private var fallbackSourceOffset: CMTime?
    private var accepting = true
    private var finishing = false
    private var discarded = false
    private var protectionNeedsRetry = false
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
         compositor: RecordingFrameCompositor? = nil, automaticallyRefreshOverlays: Bool = true,
         clock: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
         protectBeforeCancellation: @escaping @Sendable (RecordingRecoveryLease) throws -> Void = { try $0.protectBeforeCancellingWriter() },
         requestStop: @escaping @Sendable (String?) -> Void) throws {
        try options.validate()
        self.options = options
        self.compositor = compositor
        self.requestStop = requestStop
        self.protectBeforeCancellation = protectBeforeCancellation
        self.clock = clock
        wallStart = clock()
        let recordingDirectory = try RecordingFileStorage.makeStagingDirectory(in: outputDirectory)
        directory = recordingDirectory
        url = recordingDirectory.appendingPathComponent("recording.mp4")
        var initializedLease: RecordingRecoveryLease?
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let bitRate = min(16_000_000, max(1_000_000, Int(size.width * size.height * CGFloat(options.frameRate) * 0.08)))
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoExpectedSourceFrameRateKey: options.frameRate,
                    AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
            if compositor != nil { videoSettings[AVVideoColorPropertiesKey] = RecordingFrameCompositor.videoColorProperties }
            video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
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
            RecordingRecoveryWriterSupport.configure(writer)
            guard writer.startWriting() else { throw RecordingError.failed(writer.error?.localizedDescription ?? "The MP4 could not be opened.") }
            let store = try RecordingRecoveryStore(root: recordingDirectory.deletingLastPathComponent())
            initializedLease = try store.begin(stagingDirectory: recordingDirectory, byteLimit: options.maximumFileSize, durationLimit: options.maximumDuration)
            recoveryLease = initializedLease
            if compositor != nil, automaticallyRefreshOverlays {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 1 / Double(options.frameRate), leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.refreshOverlay() }
                overlayTimer = timer; timer.resume()
            }
        } catch {
            initializedLease?.closeLease()
            // Never recursively erase a journal or media after a failed start.
            // No frames are accepted before init returns; an empty folder is safe to remove.
            _ = rmdir(recordingDirectory.path)
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
    func consume(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType, updatingScreenSnapshot: Bool = true) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard accepting, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return false }
        if writer.status == .failed {
            notifyStop(writer.error?.localizedDescription ?? "The video encoder stopped.")
            return false
        }
        checkLimits()
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard !stopRequested, sourceTime.isNumeric else { return false }
        if updatingScreenSnapshot, compositor != nil, type == .screen, Self.isCompleteScreenFrame(sampleBuffer),
           latestScreen.map({ CMTimeCompare(sourceTime, CMSampleBufferGetPresentationTimeStamp($0)) >= 0 }) ?? true {
            latestScreen = sampleBuffer
            screenRevision &+= 1
        }
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
            if compositor != nil, lastVideoTime.isNumeric,
               CMTimeSubtract(timestamp, lastVideoTime).seconds + 0.000_001 < 1 / Double(options.frameRate) { return false }
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
            let sourceSample: CMSampleBuffer
            if type == .screen, let compositor {
                guard let composed = try compositor.composite(sampleBuffer) else { return false }
                sourceSample = composed
            } else { sourceSample = sampleBuffer }
            let sample = try RecordingSampleTiming.copy(sourceSample, subtracting: offset)
            guard input.append(sample) else {
                notifyStop(writer.error?.localizedDescription ?? "A recording sample could not be encoded.")
                return false
            }
            timeline.committed(through: CMTimeAdd(sourceTime, duration))
            if type == .screen {
                lastVideo = sample
                lastVideoTime = timestamp
                encodedScreenRevision = screenRevision
            } else if type == .audio { lastSystemAudioEnd = CMTimeAdd(timestamp, duration) }
            else { lastMicrophoneEnd = CMTimeAdd(timestamp, duration) }
            return true
        } catch { notifyStop(error.localizedDescription); return false }
    }

    /// ScreenCaptureKit may stop emitting complete frames on a static desktop.
    /// Sample only the newest camera/vector state at the shared screen clock;
    /// no camera callback queue is ever forwarded into the encoder.
    var needsOverlayRefresh: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let compositor else { return false }
        return compositor.needsRefresh || screenRevision != encodedScreenRevision
    }

    func refreshOverlay() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard accepting, !stopRequested, !timeline.isPaused,
              let source = latestScreen, needsOverlayRefresh else { return }
        let now = sourceNow
        if let previous = timeline.presentationTime(for: now), lastVideoTime.isNumeric,
           CMTimeSubtract(previous, lastVideoTime).seconds < 1 / Double(options.frameRate) { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(options.frameRate)),
            presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var refreshed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: source,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &refreshed) == noErr,
              let refreshed else { return }
        // A refreshed PTS is not a new ScreenCaptureKit frame. Keeping it out of
        // the raw cache prevents newer-clock heartbeats from rejecting slightly
        // delayed real screen callbacks and freezing the desktop under Camera.
        _ = consume(refreshed, of: .screen, updatingScreenSnapshot: false)
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
        let sourceSample: CMSampleBuffer
        do {
            if let compositor {
                guard let composed = try compositor.composite(sample) else { return false }
                sourceSample = composed
            } else { sourceSample = sample }
        } catch { notifyStop(error.localizedDescription); return false }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sourceSample,
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
                    self.pendingResumeVideo = self.pausedVideo ?? (self.compositor == nil ? nil : self.latestScreen)
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

    /// Scalar-only diagnostic observation; caller must use the encoder queue.
    /// Does not drive readiness, allocate a pixel buffer, or change writer state.
    func smokeDiagnosticSnapshot() -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(queue))
        func time(_ value: CMTime?) -> Any {
            guard let value, value.isNumeric else { return NSNull() }
            return ["value": value.value, "timescale": Int64(value.timescale)]
        }
        var result: [String: Any] = [
            "assetWriterStatus": writer.status.rawValue,
            "videoReady": video.isReadyForMoreMediaData,
            "accepting": accepting, "finishing": finishing, "discarded": discarded,
            "stopRequested": stopRequested, "paused": timeline.isPaused,
            "needsOverlayRefresh": needsOverlayRefresh,
            "screenRevision": screenRevision, "encodedScreenRevision": encodedScreenRevision,
            "sourceNow": time(sourceNow), "sourceStart": time(timeline.sourceStart),
            "lastVideoTime": time(lastVideoTime), "removedDuration": time(timeline.removedDuration),
            "pendingResumeSourceTime": time(pendingResumeSourceTime),
            "latestScreenPresent": latestScreen != nil, "lastVideoPresent": lastVideo != nil,
            "pendingResumePresent": pendingResumeVideo != nil, "pausedVideoPresent": pausedVideo != nil,
            "retainedVideoFrames": currentSnapshot().retainedVideoFrames,
            "finishContinuationPresent": finishContinuation != nil,
            "recoveryLeasePresent": recoveryLease != nil, "protectionNeedsRetry": protectionNeedsRetry
        ]
        if let error = writer.error as NSError? {
            result["assetWriterError"] = ["domain": error.domain, "code": error.code,
                "message": String(error.localizedDescription.prefix(512))]
        }
        if let compositor {
            result["compositorNeedsRefresh"] = compositor.needsRefresh
            result["compositorLastRevision"] = compositor.lastRevision.map { $0 as Any } ?? NSNull()
            result["compositionRevision"] = compositor.state.currentRevision
            result["lastPixelPoolAllocationStatus"] = compositor.smokeLastAllocationStatus.map { $0 as Any } ?? NSNull()
        }
        return result
    }

    func snapshot() async -> RecordingWriterSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.currentSnapshot()) }
        }
    }

    private func currentSnapshot() -> RecordingWriterSnapshot {
        RecordingWriterSnapshot(elapsed: min(options.maximumDuration, timeline.activeDuration(at: sourceNow).seconds),
            wallElapsed: max(0, CMTimeSubtract(clock(), wallStart).seconds), isPaused: timeline.isPaused,
            retainedVideoFrames: (lastVideo == nil ? 0 : 1) + (pausedVideo == nil ? 0 : 1) +
                (pendingResumeVideo == nil ? 0 : 1) + (latestScreen == nil ? 0 : 1))
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
        compositor?.freeze()
        overlayTimer?.cancel(); overlayTimer = nil
        latestScreen = nil
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
                    do {
                        try self.protectAndCancelWriter()
                        self.complete(.failure(error))
                    } catch { self.complete(.failure(error), cacheResult: false) }
                    return
                }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.finishContinuation != nil else { return }
                    do {
                        try self.protectAndCancelWriter()
                        self.complete(.failure(RecordingError.failed("The encoder did not finish within 30 seconds.")))
                    } catch { self.complete(.failure(error), cacheResult: false) }
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

    private func complete(_ result: Result<URL, Error>, cacheResult: Bool = true) {
        var finalResult = result
        if case .success = result {
            do { try recoveryLease?.markFinalized() }
            catch { finalResult = .failure(error) }
        }
        finishTimeout?.cancel()
        finishTimeout = nil
        lastVideo = nil
        pausedVideo = nil
        pendingResumeVideo = nil
        pendingResumeSourceTime = nil
        compositor?.releaseFrozenSnapshot()
        finishedResult = cacheResult ? finalResult : nil
        finishing = false
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(with: finalResult)
    }

    /// Publication is serialized with encoder completion and journal ownership.
    func publishFinished(mediaURL: URL? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.discarded, case .success? = self.finishedResult, let lease = self.recoveryLease else {
                    continuation.resume(throwing: RecordingError.notRecording); return
                }
                do {
                    let result = try lease.publishFinalized(mediaURL: mediaURL)
                    lease.closeLease(); self.recoveryLease = nil
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// A rename may succeed before the final journal fsync fails. Resolve the
    /// validated current path before releasing the lease, never return a stale path.
    func recoverableURLAndClose() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.writer.status != .writing, self.writer.status != .unknown,
                      !self.protectionNeedsRetry else { continuation.resume(returning: nil); return }
                let source = try? self.recoveryLease?.validatedSourceURL()
                self.recoveryLease?.closeLease(); self.recoveryLease = nil
                continuation.resume(returning: source)
            }
        }
    }

    /// The only cancellation site. AVAssetWriter deletes outputURL on cancel,
    /// so durable alias + journal protection must succeed first. This function
    /// does not cache failures: the same retained writer can retry disk errors.
    private func protectAndCancelWriter() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let needsCancellation = writer.status == .writing || writer.status == .unknown
        guard needsCancellation || protectionNeedsRetry else { return }
        guard let lease = recoveryLease else {
            protectionNeedsRetry = true
            throw RecordingError.preservationFailed("The recovery journal is unavailable.")
        }
        do { try protectBeforeCancellation(lease) }
        catch {
            protectionNeedsRetry = true
            throw RecordingError.preservationFailed(error.localizedDescription)
        }
        protectionNeedsRetry = false
        // finishWriting can complete while the user repairs a disk failure.
        // Retry the durability barrier even then, but never cancel a completed file.
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
    }

    /// Failure is not user discard. Preserve any fragments for explicit recovery.
    /// A thrown error means the caller MUST keep this writer alive and retry.
    func abandonPreservingRecovery() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.freeze()
                do {
                    try self.protectAndCancelWriter()
                    self.discarded = true
                    self.complete(.failure(CancellationError()))
                    self.recoveryLease?.closeLease(); self.recoveryLease = nil
                    continuation.resume()
                } catch {
                    // Frozen capture has no pending frames or camera surfaces;
                    // retaining one encoder + lease is bounded and visible.
                    self.complete(.failure(error), cacheResult: false)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func discard() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.freeze()
                do {
                    try self.protectAndCancelWriter()
                    // Archive only after cancellation is safe. If journal I/O
                    // fails, retain the lease and leave the reminder retryable.
                    try self.recoveryLease?.discard()
                    self.discarded = true
                    self.complete(.failure(CancellationError()))
                    self.recoveryLease?.closeLease(); self.recoveryLease = nil
                    continuation.resume()
                } catch {
                    let failure = (error as? RecordingError) ?? RecordingError.preservationFailed(error.localizedDescription)
                    self.complete(.failure(failure), cacheResult: false)
                    continuation.resume(throwing: failure)
                }
            }
        }
    }
}
