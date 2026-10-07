import AVFoundation
import CoreGraphics
import Foundation

struct GIFExportOptions: Codable, Equatable, Sendable {
    var frameRate: Double = 12
    var maximumDimension: Int = 1_280
    var maximumDuration: TimeInterval = 30
    var maximumFrames: Int = 360

    func validate() throws {
        guard frameRate.isFinite, (1...30).contains(frameRate),
              (16...1_920).contains(maximumDimension), maximumDuration.isFinite,
              (0.1...60).contains(maximumDuration), (1...600).contains(maximumFrames) else {
            throw GIFExportError.invalidOptions
        }
    }
}

enum GIFExportError: LocalizedError {
    case invalidOptions, noVideo, destinationExists, tooLarge, unsupportedTransparency, failed(String)
    var errorDescription: String? {
        switch self {
        case .invalidOptions: return "Use 1–30 GIF FPS, a maximum dimension of 16–1920 pixels, up to 60 seconds, and up to 600 frames."
        case .noVideo: return "This file has no playable video frames."
        case .destinationExists: return "A file already exists at that destination. Choose a new filename."
        case .tooLarge: return "The GIF exceeds its output or single-frame size limit. Try fewer frames, a shorter clip, or smaller dimensions."
        case .unsupportedTransparency: return "GIF export currently supports opaque video frames, such as screen recordings. Videos with transparent frames are not supported."
        case .failed(let message): return "Couldn’t export the GIF: \(message)"
        }
    }
}

/// Internal diagnostic strategy. Keep the shipped async baseline as the
/// default until native comparison establishes the scoped candidate's behavior.
/// The streaming encoder, requested times, dimensions and tolerances are shared.
enum GIFFrameExtraction: String, Codable, CaseIterable, Sendable {
    case asynchronous = "async-baseline"
    case scopedSynchronous = "scoped-sync-candidate"
}

/// Production entry point: an on-demand signed child owns all native video/GIF
/// framework work. The app owns admission, source snapshot, publication and
/// confirmed child-exit/staging-cleanup accounting.
enum GIFExporter {
    static let maximumOutputBytes = 64 * 1_024 * 1_024
    @TaskLocal private static var processServiceForTests: GIFExportProcessService?

    static func export(sourceURL: URL, destinationURL: URL? = nil, options: GIFExportOptions = .init(),
                       frameExtraction: GIFFrameExtraction = .asynchronous,
                       trimStage: OwnedVideoExportStage? = nil,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let service = processServiceForTests ?? .shared
        return try await service.export(sourceURL: sourceURL, destinationURL: destinationURL, options: options,
                                        frameExtraction: frameExtraction, trimStage: trimStage, progress: progress)
    }
    static func processResourceSnapshot() async -> GIFExportProcessSnapshot {
        await (processServiceForTests ?? .shared).snapshot()
    }
    /// Explicit test injection still uses a real process service; this never
    /// substitutes an in-process engine when production helper validation fails.
    static func withProcessServiceForTesting<Result>(_ service: GIFExportProcessService,
        operation: () async throws -> Result) async rethrows -> Result {
        try await $processServiceForTests.withValue(service, operation: operation)
    }
}

/// Sequential, cancellable extraction and file-backed animation assembly.
/// ImageIO receives one still frame at a time; no animated destination retains
/// earlier rasters. The file sink enforces a hard 64 MiB output byte limit.
/// Actual transparency is rejected explicitly; recorded screen MP4s are opaque.
/// Long sources are trimmed to `maximumDuration`; a frame cap reduces sampling
/// frequency while preserving the selected clip's playback duration.
enum GIFInProcessEngine {
    /// Only the signed helper and explicitly named semantic/diagnostic callers
    /// may use this engine. There is no automatic production fallback to it.
    static func exportDirect(
        sourceURL: URL,
        destinationURL: URL? = nil,
        options: GIFExportOptions = .init(),
        frameExtraction: GIFFrameExtraction = .asynchronous,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try options.validate()
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw GIFExportError.noVideo }
        let sourceDuration = try await asset.load(.duration).seconds
        let plan = try GIFFramePlan(duration: sourceDuration, options: options)
        let destination: URL
        let ownsDirectory: Bool
        if let destinationURL {
            destination = destinationURL
            ownsDirectory = false
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw GIFExportError.destinationExists }
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GIF-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            destination = directory.appendingPathComponent("recording.gif")
            ownsDirectory = true
        }
        // Write alongside the destination, then publish with a move. A failed or
        // cancelled conversion never leaves a partial GIF at the requested name.
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".picshot-\(UUID().uuidString).gif")
        var completed = false
        defer {
            try? FileManager.default.removeItem(at: partial)
            if !completed, ownsDirectory { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        }
        let cancellation = GIFCancellation()
        let stream = try GIFStreamingWriter(url: partial, cancelled: { cancellation.isCancelled })
        defer { stream.close() }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maximumDimension, height: options.maximumDimension)
        let tolerance = CMTime(seconds: min(0.05, plan.duration / Double(plan.frameCount) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        progress?(0)
        // A progress observer may cancel before any frame request exists. Honor
        // that here, without entering native image-generation cancellation.
        try Task.checkCancellation()
        do {
            try await withTaskCancellationHandler {
                for index in 0..<plan.frameCount {
                    try Task.checkCancellation()
                    let time = plan.samplingTime(for: index)
                    switch frameExtraction {
                    case .asynchronous:
                        // Unchanged production baseline for controlled comparison.
                        let frame = try await generator.image(at: time)
                        try Task.checkCancellation()
                        try stream.append(image: frame.image, delay: plan.delay(for: index))
                    case .scopedSynchronous:
                        // Intentional use of the still-available deprecated API:
                        // extraction AND encoding now share one drained pool.
                        // This nonisolated async function runs on Swift 5.9's
                        // generic executor, never the caller's MainActor.
                        try autoreleasepool {
                            try Task.checkCancellation()
                            let image = try generator.copyCGImage(at: time, actualTime: nil)
                            try Task.checkCancellation()
                            try stream.append(image: image, delay: plan.delay(for: index))
                        }
                    }
                    progress?(Double(index + 1) / Double(plan.frameCount + 1))
                    if frameExtraction == .scopedSynchronous {
                        // A synchronous framework call cannot be promised to
                        // interrupt mid-call. Honor cancellation immediately on
                        // return, and don't monopolize the executor across frames.
                        await Task.yield()
                        try Task.checkCancellation()
                    }
                }
                try Task.checkCancellation()
                try stream.finish()
                try Task.checkCancellation()
            } onCancel: {
                cancellation.cancel()
                generator.cancelAllCGImageGeneration()
            }
        } catch {
            if Task.isCancelled || cancellation.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        // FileManager.moveItem fails rather than overwriting a destination created
        // by another process while export was in progress.
        try FileManager.default.moveItem(at: partial, to: destination)
        completed = true
        progress?(1)
        return destination
    }
}

/// Quantize delays to GIF's centiseconds, distributing the remainder across
/// frames so frame limiting never speeds up playback or produces zero delays.
struct GIFFramePlan: Equatable {
    let duration: TimeInterval
    let frameCount: Int
    private let centiseconds: Int

    init(duration: TimeInterval, options: GIFExportOptions) throws {
        try options.validate()
        guard duration.isFinite, duration > 0 else { throw GIFExportError.noVideo }
        self.duration = min(duration, options.maximumDuration)
        centiseconds = max(2, Int((self.duration * 100).rounded()))
        frameCount = max(1, min(options.maximumFrames, Int(ceil(self.duration * options.frameRate)), centiseconds / 2))
    }

    func time(for index: Int) -> TimeInterval { Double(index) * duration / Double(frameCount) }
    /// Select the nearest tick explicitly. CMTime's seconds initializer can
    /// truncate a Double just below an intended boundary (for example 0.8 to
    /// 479/600), selecting the preceding source frame. This changes neither
    /// the sampling grid nor GIF delays, only its conversion to rational time.
    func samplingTime(for index: Int) -> CMTime {
        precondition((0..<frameCount).contains(index))
        return CMTime(value: Int64((time(for: index) * 600).rounded()), timescale: 600)
    }
    func delay(for index: Int) -> TimeInterval {
        let lower = index * centiseconds / frameCount
        let upper = (index + 1) * centiseconds / frameCount
        return Double(upper - lower) / 100
    }
}

private final class GIFCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
