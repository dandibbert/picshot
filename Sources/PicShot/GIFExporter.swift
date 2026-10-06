import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GIFExportOptions: Equatable, Sendable {
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
    case invalidOptions, noVideo, destinationExists, tooLarge, failed(String)
    var errorDescription: String? {
        switch self {
        case .invalidOptions: return "Use 1–30 GIF FPS, a maximum dimension of 16–1920 pixels, up to 60 seconds, and up to 600 frames."
        case .noVideo: return "This file has no playable video frames."
        case .destinationExists: return "A file already exists at that destination. Choose a new filename."
        case .tooLarge: return "The GIF exceeds 64 MB. Try fewer frames, a shorter clip, or smaller dimensions."
        case .failed(let message): return "Couldn’t export the GIF: \(message)"
        }
    }
}

/// Sequential, cancellable extraction; no video or frame array is loaded into RAM.
/// The output consumer enforces a hard 64 MiB byte limit while ImageIO writes.
/// Long sources are trimmed to `maximumDuration`; a frame cap reduces sampling
/// frequency while preserving the selected clip's playback duration.
enum GIFExporter {
    static let maximumOutputBytes = 64 * 1_024 * 1_024

    static func export(
        sourceURL: URL,
        destinationURL: URL? = nil,
        options: GIFExportOptions = .init(),
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
        let sink = try GIFByteSink(url: partial, maximumBytes: maximumOutputBytes, cancellation: cancellation)
        defer { sink.close() }
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
            guard let info else { return 0 }
            return Unmanaged<GIFByteSink>.fromOpaque(info).takeUnretainedValue().write(buffer, count: count)
        }, releaseConsumer: { info in
            if let info { Unmanaged<GIFByteSink>.fromOpaque(info).release() }
        })
        let retainedSink = Unmanaged.passRetained(sink)
        guard let consumer = CGDataConsumer(info: retainedSink.toOpaque(), cbks: &callbacks) else {
            retainedSink.release()
            throw GIFExportError.failed("The output file could not be opened.")
        }
        guard let imageDestination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.gif.identifier as CFString, plan.frameCount, nil) else {
            throw GIFExportError.failed("The GIF encoder is unavailable.")
        }
        CGImageDestinationSetProperties(imageDestination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maximumDimension, height: options.maximumDimension)
        let tolerance = CMTime(seconds: min(0.05, plan.duration / Double(plan.frameCount) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        progress?(0)
        try await withTaskCancellationHandler {
            for index in 0..<plan.frameCount {
                try Task.checkCancellation()
                let time = CMTime(seconds: plan.time(for: index), preferredTimescale: 600)
                let frame = try await generator.image(at: time)
                try Task.checkCancellation()
                autoreleasepool {
                    let properties = [kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: plan.delay(for: index),
                        kCGImagePropertyGIFUnclampedDelayTime: plan.delay(for: index)
                    ]] as CFDictionary
                    CGImageDestinationAddImage(imageDestination, frame.image, properties)
                }
                if let error = sink.failure { throw error }
                progress?(Double(index + 1) / Double(plan.frameCount + 1))
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(imageDestination) else {
                if cancellation.isCancelled { throw CancellationError() }
                throw sink.failure ?? GIFExportError.failed("The GIF could not be finalized.")
            }
            if let error = sink.failure { throw error }
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            generator.cancelAllCGImageGeneration()
        }
        try sink.flush()
        sink.close()
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

private final class GIFByteSink {
    private var handle: FileHandle?
    private let maximumBytes: Int
    private let cancellation: GIFCancellation
    private var bytes = 0
    private(set) var failure: Error?

    init(url: URL, maximumBytes: Int, cancellation: GIFCancellation) throws {
        self.maximumBytes = maximumBytes
        self.cancellation = cancellation
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw GIFExportError.failed("The output file could not be created.")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        guard failure == nil, let handle else { return 0 }
        if cancellation.isCancelled { failure = CancellationError(); return 0 }
        guard count <= maximumBytes - bytes else { failure = GIFExportError.tooLarge; return 0 }
        do {
            // FileHandle consumes these bytes synchronously; ImageIO owns the buffer.
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer), count: count, deallocator: .none)
            try handle.write(contentsOf: data)
            bytes += count
            return count
        } catch { failure = error; return 0 }
    }

    func flush() throws { try handle?.synchronize() }
    func close() { try? handle?.close(); handle = nil }
    deinit { close() }
}
