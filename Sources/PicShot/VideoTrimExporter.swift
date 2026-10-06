import AVFoundation
import Foundation
import PicShotCodecCore
import Darwin

/// A half-open interval in the source movie's timeline. Fractional frame times
/// are retained; the UI never rounds an in/out point to the displayed text.
struct VideoTrimRange: Equatable, Sendable {
    static let timescale: CMTimeScale = 600_000
    let start: TimeInterval
    let end: TimeInterval
    var duration: TimeInterval { end - start }
    var timeRange: CMTimeRange {
        // Explicit nearest ticks keep decimal in/out boundaries from falling
        // one tick before the intended source frame through Double truncation.
        CMTimeRange(start: CMTime(value: Int64((start * Double(Self.timescale)).rounded()), timescale: Self.timescale),
                    end: CMTime(value: Int64((end * Double(Self.timescale)).rounded()), timescale: Self.timescale))
    }

    init(start: TimeInterval, end: TimeInterval, sourceDuration: TimeInterval) throws {
        let maximumRepresentableSeconds = Double(Int64.max / Int64(Self.timescale) - 1)
        guard sourceDuration.isFinite, sourceDuration > 0, sourceDuration < maximumRepresentableSeconds,
              start.isFinite, end.isFinite, start >= 0, end > start, end <= sourceDuration else {
            throw VideoTrimError.invalidRange
        }
        self.start = start
        self.end = end
        guard timeRange.duration.isNumeric, CMTimeCompare(timeRange.duration, .zero) > 0 else {
            throw VideoTrimError.invalidRange
        }
    }
}

enum VideoTrimError: LocalizedError {
    case invalidRange, noVideo, unsupportedExport, destinationExists, destinationChanged, originalDestination
    case gifDurationLimit(TimeInterval), webpDurationLimit(TimeInterval), recoveredDestination(URL), failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRange: return "Choose an end time after the start time, within the recording."
        case .noVideo: return "This recording has no playable video."
        case .unsupportedExport: return "This recording cannot be exported as MP4."
        case .destinationExists: return "A file already exists at that destination. Choose another name or confirm replacement in the save panel."
        case .destinationChanged: return "The destination changed while exporting. Save again to confirm the current file."
        case .originalDestination: return "Choose a different filename to keep the original recording intact."
        case .gifDurationLimit(let seconds): return "GIF export supports at most \(Int(seconds)) seconds. Shorten the selected range first."
        case .webpDurationLimit(let seconds): return "WebP export supports at most \(Int(seconds)) seconds. Shorten the selected range first."
        case .recoveredDestination(let url): return "The destination changed during saving. Its previous file was preserved at \(url.path). Keep that recovered file and choose a new export name."
        case .failed(let message): return "Couldn’t export the clip: \(message)"
        }
    }
}

/// Captured immediately after NSSavePanel returns OK. A new destination never
/// acquires overwrite permission just because a file appears during export.
struct VideoExportDestination: Sendable {
    let url: URL
    private let sourceURL: URL
    private let confirmedFile: FileSnapshot?

    init(url: URL, preserving sourceURL: URL, overwriteConfirmed: Bool = false) throws {
        guard url.isFileURL, sourceURL.isFileURL else { throw VideoTrimError.originalDestination }
        self.url = url
        self.sourceURL = sourceURL
        try Self.checkOriginal(sourceURL, destination: url)
        confirmedFile = try Self.snapshot(url)
        if confirmedFile != nil, !overwriteConfirmed { throw VideoTrimError.destinationExists }
    }

    enum PublicationCheckpoint: Equatable { case confirmedDestinationChecked, destinationDisplaced }

    /// Both files are on the destination volume. Final publication is atomic;
    /// confirmed replacements have a brief coordinated filename gap while the
    /// previous file is safely retained. No partial output is ever published.
    /// The optional checkpoint permits deterministic concurrent-writer tests.
    func publish(stagedURL: URL, checkpoint: ((PublicationCheckpoint) throws -> Void)? = nil) throws {
        try Task.checkCancellation()
        try Self.checkOriginal(sourceURL, destination: url)
        if let confirmedFile {
            // Ordinary document writers are coordinated. Exclusive renames also
            // protect against an uncoordinated app replacing the path: retain the
            // displaced file until its actual identity has been checked.
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var writeError: Error?
            var published = false
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do {
                    try Task.checkCancellation()
                    guard coordinatedURL.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath(),
                          try Self.snapshot(coordinatedURL) == confirmedFile else { throw VideoTrimError.destinationChanged }
                    try Self.checkOriginal(sourceURL, destination: coordinatedURL)
                    try checkpoint?(.confirmedDestinationChecked)
                    let recovery = coordinatedURL.deletingLastPathComponent()
                        .appendingPathComponent("PicShot-Recovered-\(UUID().uuidString).\(url.pathExtension)")
                    try Self.renameExclusively(from: coordinatedURL, to: recovery)
                    do {
                        try checkpoint?(.destinationDisplaced)
                        guard try Self.snapshot(recovery) == confirmedFile else { throw VideoTrimError.destinationChanged }
                        try Task.checkCancellation()
                        try Self.renameExclusively(from: stagedURL, to: coordinatedURL, allowOwnedFileLinkFallback: true)
                        published = true
                        // Only a verified, explicitly replaced file may be removed.
                        try? FileManager.default.removeItem(at: recovery)
                    } catch {
                        let failure = error
                        do { try Self.renameExclusively(from: recovery, to: coordinatedURL) }
                        catch { throw VideoTrimError.recoveredDestination(recovery) }
                        throw failure
                    }
                } catch { writeError = error }
            }
            if let writeError { throw writeError }
            if let coordinationError { throw coordinationError }
            guard published else { throw VideoTrimError.destinationChanged }
        } else {
            try Self.renameExclusively(from: stagedURL, to: url, allowOwnedFileLinkFallback: true)
        }
    }

    private static func renameExclusively(from source: URL, to destination: URL, allowOwnedFileLinkFallback: Bool = false) throws {
        // Unlike rename(), RENAME_EXCL never overwrites a file which appeared
        // after the save panel. It also works on volumes without hard links.
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw VideoTrimError.destinationExists }
            // Link fallback is allowed only for our completed staging file,
            // which the owning defer removes. Never unlink an unowned path.
            if allowOwnedFileLinkFallback, code == ENOTSUP || code == EINVAL {
                do { try FileManager.default.linkItem(at: source, to: destination) }
                catch {
                    if FileManager.default.fileExists(atPath: destination.path) { throw VideoTrimError.destinationExists }
                    throw error
                }
                return
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    func makeStagingDirectory() throws -> URL {
        let directory = url.deletingLastPathComponent()
            .appendingPathComponent(".picshot-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private struct FileSnapshot: Equatable, Sendable {
        let inode: UInt64
        let device: UInt64
        let size: UInt64
        let modified: Date
    }

    private static func snapshot(_ url: URL) throws -> FileSnapshot? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw VideoTrimError.destinationChanged
        }
        return FileSnapshot(inode: inode.uint64Value, device: device.uint64Value, size: size.uint64Value, modified: modified)
    }

    private static func checkOriginal(_ source: URL, destination: URL) throws {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw VideoTrimError.originalDestination
        }
        if let sourceFile = try snapshot(source), let destinationFile = try snapshot(destination),
           sourceFile.inode == destinationFile.inode, sourceFile.device == destinationFile.device {
            throw VideoTrimError.originalDestination
        }
    }
}

/// Native streaming export. HighestQuality re-encodes boundary frames rather
/// than silently extending the selected interval to passthrough keyframes.
/// Audio tracks and the movie's orientation are handled by AVFoundation.
enum VideoTrimExporter {
    /// Explicitly rejects oversized selections instead of silently exporting
    /// the first N seconds. The temporary MP4 isolates exactly the chosen clip.
    static func exportGIF(
        sourceURL: URL, destination: VideoExportDestination, range: VideoTrimRange,
        options: GIFExportOptions = .init(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try options.validate()
        guard range.duration <= options.maximumDuration else { throw VideoTrimError.gifDurationLimit(options.maximumDuration) }
        try Task.checkCancellation()
        let directory = try destination.makeStagingDirectory()
        var mayRemoveStaging = true
        defer { if mayRemoveStaging { try? FileManager.default.removeItem(at: directory) } }
        let clipURL = directory.appendingPathComponent("selected.mp4")
        _ = try await export(sourceURL: sourceURL, destinationURL: clipURL, range: range,
                             progress: { progress?($0 * 0.4) })
        try Task.checkCancellation()
        let gifURL = directory.appendingPathComponent("selected.gif")
        do {
            _ = try await GIFExporter.export(sourceURL: clipURL, destinationURL: gifURL, options: options,
                                             progress: { progress?(0.4 + $0 * 0.59) })
        } catch GIFExportProcessError.exitUnconfirmed {
            // This call's child job is nested in our trim staging directory.
            // Preserve it while a live child may still hold/use these files.
            // A .busy rejection belongs to another call and does not take this branch.
            mayRemoveStaging = false
            throw GIFExportProcessError.exitUnconfirmed
        }
        try Task.checkCancellation()
        try destination.publish(stagedURL: gifURL)
        progress?(1)
        return destination.url
    }

    /// Uses the same identity-checked publication as MP4/GIF. The helper sees
    /// a frozen, self-contained selected clip, never the user's original URL.
    /// WebP frame extraction/encoding stays in the child; preparing the selected
    /// MP4 uses the existing cancellable AVFoundation trim exporter.
    static func exportWebP(
        sourceURL: URL, destination: VideoExportDestination, range: VideoTrimRange,
        options: CodecExportRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try options.validate()
        guard options.kind == .animation, options.format == .webp, let animation = options.animation
        else { throw CodecExportFailure(.invalidOptions) }
        guard range.duration <= animation.maximumDuration else { throw VideoTrimError.webpDurationLimit(animation.maximumDuration) }
        guard destination.url.pathExtension.lowercased() == "webp" else { throw ImageExportError.invalidDestination }
        try Task.checkCancellation()
        let directory = try destination.makeStagingDirectory()
        // The codec service owns its copied input and helper job in a separate
        // private system-temp directory. No child ever reads this trim stage,
        // so it is safe to remove even if the child's exit is unconfirmed.
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipURL = directory.appendingPathComponent("selected.mp4")
        _ = try await export(sourceURL: sourceURL, destinationURL: clipURL, range: range,
                             progress: { progress?($0 * 0.25) })
        try Task.checkCancellation()
        let webpURL = directory.appendingPathComponent("selected.webp")
        _ = try await CodecExportProcessService.shared.export(sourceURL: clipURL, destinationURL: webpURL,
            options: options, progress: { progress?(0.25 + $0 * 0.74) })
        try Task.checkCancellation()
        try destination.publish(stagedURL: webpURL)
        progress?(1)
        return destination.url
    }

    static func export(
        sourceURL: URL, destinationURL: URL, range: VideoTrimRange,
        overwriteConfirmed: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        let destination = try VideoExportDestination(url: destinationURL, preserving: sourceURL,
                                                      overwriteConfirmed: overwriteConfirmed)
        return try await export(sourceURL: sourceURL, destination: destination, range: range, progress: progress)
    }

    static func export(
        sourceURL: URL, destination: VideoExportDestination, range: VideoTrimRange,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw VideoTrimError.noVideo }
        let duration = try await asset.load(.duration).seconds
        let checkedRange = try VideoTrimRange(start: range.start, end: range.end, sourceDuration: duration)
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else { throw VideoTrimError.unsupportedExport }
        let directory = try destination.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("clip.mp4")
        session.outputURL = partial
        session.outputFileType = .mp4
        session.timeRange = checkedRange.timeRange
        session.shouldOptimizeForNetworkUse = true
        let operation = VideoTrimExportOperation(session: session)
        progress?(0)
        let polling = Task {
            while !Task.isCancelled {
                progress?(min(0.99, Double(operation.progress)))
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
            }
        }
        defer { polling.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.start(continuation)
            }
            try Task.checkCancellation()
        } onCancel: {
            operation.cancel()
        }
        polling.cancel()
        await polling.value
        // Validate the finalized file before committing its user-visible name.
        let outputAsset = AVURLAsset(url: partial)
        let outputDuration = try await outputAsset.load(.duration).seconds
        guard outputDuration.isFinite, outputDuration > 0,
              !(try await outputAsset.loadTracks(withMediaType: .video)).isEmpty else {
            throw VideoTrimError.noVideo
        }
        try Task.checkCancellation()
        try destination.publish(stagedURL: partial)
        progress?(1)
        return destination.url
    }
}

/// Serializes start/cancel, including cancellation before AVFoundation starts.
/// The continuation is resumed only by the one export completion callback.
private final class VideoTrimExportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let session: AVAssetExportSession
    private var cancelled = false

    init(session: AVAssetExportSession) { self.session = session }
    var progress: Float { lock.lock(); defer { lock.unlock() }; return session.progress }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        session.exportAsynchronously { [self] in
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled || session.status == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else if session.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: session.error ?? VideoTrimError.failed("The encoder did not finish."))
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        session.cancelExport()
    }
}
