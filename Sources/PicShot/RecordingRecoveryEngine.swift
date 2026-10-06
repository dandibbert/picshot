import Darwin
import AVFoundation
import AppKit
import PicShotCore

struct RecordingRecoveryResult: Sendable {
    let url: URL
    let recoveredDuration: Double
    let completeFragments: Int
    let ignoredTailBytes: Int64
    /// A successful export remains usable if the optional journal update fails.
    let journalWarning: String?
}

/// Recovery never opens a capture device or resumes an interrupted encoder.
/// It works on a private prefix copy, then remuxes to a NEW movie. Sources are
/// retained on success, cancellation, export/validation failure, and low disk.
enum RecordingRecoveryEngine {
    static let exportTimeoutNanoseconds: UInt64 = 120_000_000_000

    static func recover(_ candidate: RecordingRecoveryCandidate, store: RecordingRecoveryStore,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> RecordingRecoveryResult {
        try Task.checkCancellation()
        let deadline = RecordingRecoveryDeadline()
        defer { deadline.finish() }
        let lease = try store.open(candidate)
        defer { lease.closeLease() }
        let source = try lease.validatedSourceURL()
        guard candidate.byteCount > 0, candidate.byteCount <= candidate.journal.byteLimit,
              candidate.byteCount <= RecordingRecoveryJournal.maximumBytes else { throw RecordingRecoveryError.limitExceeded }
        let capacity = try store.root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        guard let capacity, Int64(capacity) >= candidate.byteCount * 2 + 67_108_864 else {
            throw RecordingRecoveryError.io("磁盘空间不足，无法安全创建副本及恢复的录屏。")
        }
        let work = try store.makeWorkspace()
        let copy = work.sourceCopyURL
        let output = work.outputURL
        defer { withExtendedLifetime(work) {} }
        try work.validatePaths()
        progress?(0)
        let prefix = try lease.copyCompletePrefix(in: work)
        try deadline.check()
        try work.validatePaths()
        let asset = AVURLAsset(url: copy, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)])
        let before = try await inspect(asset, maximumDuration: candidate.journal.durationLimit, deadline: deadline)
        progress?(0.1)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mp4) else { throw RecordingRecoveryError.noRecoverableMedia }
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.fileLengthLimit = candidate.journal.byteLimit
        let operation = RecordingRecoveryExportOperation(exporter)
        let polling = Task {
            while !Task.isCancelled {
                progress?(0.1 + Double(operation.progress) * 0.8)
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
            }
        }
        deadline.register { [weak deadline] in operation.cancel(timedOut: deadline?.hasTimedOut ?? false) }
        defer { polling.cancel() }
        try work.validatePaths()
        try deadline.check()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in operation.start(continuation) }
            try Task.checkCancellation()
        } onCancel: { operation.cancel() }
        polling.cancel(); try deadline.check()
        try work.validatePaths()
        let recovered = AVURLAsset(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)])
        let after = try await inspect(recovered, maximumDuration: candidate.journal.durationLimit, deadline: deadline)
        guard before.audioTracks == after.audioTracks, abs(before.duration - after.duration) <= 0.25,
              let outputSize = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              outputSize > 0, Int64(outputSize) <= candidate.journal.byteLimit else {
            throw RecordingRecoveryError.noRecoverableMedia
        }
        try await decodeEndpoints(recovered, duration: after.duration, deadline: deadline)
        // Recheck the live source identity immediately before publishing a copy.
        guard try lease.validatedSourceURL() == source else { throw RecordingRecoveryError.sourceChanged }
        try deadline.check()
        let name = "PicShot-Recovered-" + UUID().uuidString + ".mp4"
        let destination = try work.publish(filename: name)
        var warning: String?
        do { try lease.markRecovered(filename: name) }
        catch { warning = "恢复的录屏已保存，但未能更新恢复提示：" + error.localizedDescription }
        progress?(1)
        return RecordingRecoveryResult(url: destination, recoveredDuration: after.duration,
            completeFragments: prefix.completeFragments, ignoredTailBytes: prefix.ignoredTailBytes, journalWarning: warning)
    }

    private static func inspect(_ asset: AVAsset, maximumDuration: Double, deadline: RecordingRecoveryDeadline) async throws -> (duration: Double, audioTracks: Int) {
        deadline.register { asset.cancelLoading() }
        try deadline.check()
        return try await withTaskCancellationHandler {
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0, duration <= maximumDuration + 1,
              videos.count == 1, audios.count <= 2, let video = videos.first else {
            throw RecordingRecoveryError.noRecoverableMedia
        }
        let size = try await video.load(.naturalSize)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 3_840, size.height <= 3_840, size.width * size.height <= 8_294_400 else {
            throw RecordingRecoveryError.limitExceeded
        }
        try Task.checkCancellation()
        try deadline.check()
        return (duration, audios.count)
        } onCancel: { asset.cancelLoading() }
    }

    /// Actual native decode, not merely an isPlayable or metadata check. This
    /// checks both ends in constant space; it is not a full-frame integrity scan.
    private static func decodeEndpoints(_ asset: AVAsset, duration: Double, deadline: RecordingRecoveryDeadline) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        deadline.register { generator.cancelAllCGImageGeneration() }
        try deadline.check()
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        try await withTaskCancellationHandler {
            _ = try await generator.image(at: .zero)
            try Task.checkCancellation()
            _ = try await generator.image(at: CMTime(seconds: max(0, duration - 0.15), preferredTimescale: 600))
            try Task.checkCancellation()
        } onCancel: { generator.cancelAllCGImageGeneration() }
        try deadline.check()
    }
}

private final class RecordingRecoveryExportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let exporter: AVAssetExportSession
    private var cancelled = false
    private var timedOut = false
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    var progress: Float { lock.lock(); defer { lock.unlock() }; return exporter.progress }
    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        exporter.exportAsynchronously { [self] in
            lock.lock(); let cancelled = self.cancelled; let timedOut = self.timedOut; lock.unlock()
            if timedOut { continuation.resume(throwing: RecordingRecoveryError.io("导出超出了两分钟时限，原始录屏已保留。")) }
            else if cancelled || exporter.status == .cancelled { continuation.resume(throwing: CancellationError()) }
            else if exporter.status == .completed { continuation.resume() }
            else { continuation.resume(throwing: exporter.error ?? RecordingRecoveryError.noRecoverableMedia) }
        }
    }
    func cancel(timedOut: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; self.timedOut = self.timedOut || timedOut; exporter.cancelExport()
    }
}

/// Bounds the whole native inspection/export/decode phase, not only export.
/// AVFoundation cancellation is requested on timeout; framework completion is
/// still required before deleting its scratch files. No unsafe force-close.
private final class RecordingRecoveryDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [() -> Void] = []
    private var cancelled = false
    private var timedOut = false
    private var timer: DispatchWorkItem?
    init() {
        let timer = DispatchWorkItem { [weak self] in self?.cancel(timedOut: true) }
        self.timer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timer)
    }
    var hasTimedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func register(_ callback: @escaping () -> Void) {
        lock.lock(); let cancelNow = cancelled
        if !cancelNow { callbacks.append(callback) }
        lock.unlock()
        if cancelNow { callback() }
    }
    func check() throws {
        try Task.checkCancellation()
        lock.lock(); let cancelled = self.cancelled; let timedOut = self.timedOut; lock.unlock()
        if timedOut { throw RecordingRecoveryError.io("恢复超出了两分钟时限，原始录屏已保留。") }
        if cancelled { throw CancellationError() }
    }
    func cancel(timedOut: Bool = false) {
        lock.lock(); cancelled = true; self.timedOut = self.timedOut || timedOut
        let pending = callbacks; callbacks.removeAll(); lock.unlock()
        for callback in pending { callback() }
    }
    func finish() { lock.lock(); timer?.cancel(); timer = nil; callbacks.removeAll(); lock.unlock() }
}
