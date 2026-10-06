import Foundation
import Darwin
import PicShotFormulaCore
import PicShotEraseCore

/// Only model-backed jobs use this gate. The small, separately capped formula
/// renderer stays independent. Limits are polling watchdogs, not kernel quotas:
/// one helper can briefly overshoot its cap between samples or while stopping.
enum LocalInferenceJobKind: String, Codable, CaseIterable, Sendable {
    case formula, table, smartErase

    var residentLimitBytes: UInt64 {
        self == .smartErase ? SmartEraseLimits.residentBytes : 1_073_741_824
    }
    var wallLimitSeconds: TimeInterval {
        self == .smartErase ? SmartEraseLimits.seconds : MLJobLimits.seconds
    }
}

enum LocalInferenceResourceError: LocalizedError, Equatable {
    case busy
    var errorDescription: String? {
        "已有公式识别、表格识别或智能消除任务正在运行或清理，请等待完成或取消后再试。"
    }
}

enum LocalInferenceJobOutcome: String, Codable, Sendable {
    case succeeded, failed, cancelled, launchFailed, timedOut, memoryLimit
}

enum LocalInferenceTerminationReason: String, Codable, Sendable {
    case exit, uncaughtSignal
}

enum LocalInferenceCleanupStatus: String, Codable, Sendable {
    /// No directory creation was attempted (for example, signature validation failed).
    case notNeeded
    /// Creation was attempted, but absence has not been confirmed.
    case unconfirmed
    case confirmed, failed
}

/// Content-free, in-memory diagnostics. No images, text, model paths, temporary
/// paths, error messages, PIDs, timestamps or per-sample arrays are retained.
struct LocalInferenceJobMetrics: Codable, Equatable, Sendable {
    let kind: LocalInferenceJobKind
    let outcome: LocalInferenceJobOutcome
    /// Includes input preparation, child execution, output loading and cleanup.
    let elapsedSeconds: TimeInterval
    let childElapsedSeconds: TimeInterval?
    /// Highest successful proc_pidinfo RSS sample, NOT a kernel lifetime peak.
    /// nil means no successful measurement; zero is never a missing-data sentinel.
    let sampledPeakResidentBytes: UInt64?
    let residentSampleCount: UInt64
    let residentSampleIntervalSeconds: TimeInterval
    let configuredResidentLimitBytes: UInt64
    let configuredWallLimitSeconds: TimeInterval
    let childLaunched: Bool
    let childExitConfirmed: Bool
    let childTerminationStatus: Int32?
    let childTerminationReason: LocalInferenceTerminationReason?
    let temporaryDirectoryCleanup: LocalInferenceCleanupStatus
}

struct LocalInferenceResourceSnapshot: Codable, Equatable, Sendable {
    let activeJob: LocalInferenceJobKind?
    /// At most three entries, in CaseIterable order: one latest result per kind.
    let lastJobs: [LocalInferenceJobMetrics]
}

/// A fail-fast, process-wide lease. There are no continuations, waiting tasks,
/// input buffers or job queues here. A cancelled caller keeps its lease until
/// its operation has actually unwound, including child exit and disk cleanup.
final class LocalInferenceResources: @unchecked Sendable {
    static let shared = LocalInferenceResources()
    private let lock = NSLock()
    private var active: (id: UUID, kind: LocalInferenceJobKind)?
    private var lastJobs: [LocalInferenceJobKind: LocalInferenceJobMetrics] = [:]

    struct Lease: Sendable {
        fileprivate let id: UUID
        let recorder: LocalInferenceJobRecorder
    }

    func withJob<Result>(_ kind: LocalInferenceJobKind,
                         operation: @Sendable (LocalInferenceJobRecorder) async throws -> Result) async throws -> Result {
        let lease = try acquire(kind)
        defer { complete(lease) }
        do {
            // Handles cancellation in the small interval following acquisition.
            try Task.checkCancellation()
            let result = try await operation(lease.recorder)
            try Task.checkCancellation()
            lease.recorder.recordOutcome(.succeeded)
            return result
        } catch {
            if error is CancellationError || Task.isCancelled {
                lease.recorder.recordOutcome(.cancelled)
            }
            // Specific launch/watchdog outcomes are set by the worker. The
            // recorder's default is failed; never retain the error itself.
            throw error
        }
    }

    /// Internal for isolated race tests. Production owners use withJob so every
    /// throwing/cancellation path has a single, unconditional deferred release.
    func acquire(_ kind: LocalInferenceJobKind) throws -> Lease {
        try Task.checkCancellation()
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw LocalInferenceResourceError.busy }
        let lease = Lease(id: UUID(), recorder: LocalInferenceJobRecorder(kind: kind))
        active = (lease.id, kind)
        return lease
    }

    /// Duplicate/stale completion cannot release or replace a newer owner's job.
    @discardableResult
    func complete(_ lease: Lease) -> Bool {
        let metrics = lease.recorder.snapshot()
        lock.lock(); defer { lock.unlock() }
        guard active?.id == lease.id else { return false }
        lastJobs[metrics.kind] = metrics
        active = nil
        return true
    }

    /// Safe to call synchronously from installed smoke after awaiting a service
    /// call, including its catch path. JSONEncoder can encode the returned value.
    func snapshot() -> LocalInferenceResourceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return LocalInferenceResourceSnapshot(activeJob: active?.kind,
            lastJobs: LocalInferenceJobKind.allCases.compactMap { lastJobs[$0] })
    }

    /// A failed lookup/permission error is not evidence of cleanup. lstat also
    /// detects a leftover symlink. The path is used transiently, never retained.
    static func removalIsConfirmed(at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var info = stat()
            return lstat(path, &info) != 0 && errno == ENOENT
        }
    }
}

/// Constant-space aggregation. Synchronization permits a snapshot after a
/// detached worker finishes without exposing its mutable state or retaining it.
final class LocalInferenceJobRecorder: @unchecked Sendable {
    static let sampleIntervalSeconds: TimeInterval = 0.1
    private let lock = NSLock()
    private let kind: LocalInferenceJobKind
    private let clock: @Sendable () -> TimeInterval
    private let started: TimeInterval
    private var childStarted: TimeInterval?
    private var childElapsed: TimeInterval?
    private var outcome: LocalInferenceJobOutcome = .failed
    private var peakRSS: UInt64?
    private var samples: UInt64 = 0
    private var exitConfirmed = false
    private var terminationStatus: Int32?
    private var terminationReason: LocalInferenceTerminationReason?
    private var cleanup: LocalInferenceCleanupStatus = .notNeeded

    init(kind: LocalInferenceJobKind,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.kind = kind; self.clock = clock; self.started = clock()
    }

    func recordOutcome(_ value: LocalInferenceJobOutcome) {
        lock.lock(); defer { lock.unlock() }; outcome = value
    }
    func recordLaunch() {
        lock.lock(); defer { lock.unlock() }
        if childStarted == nil { childStarted = clock() }
    }
    func recordResidentBytes(_ bytes: UInt64?) {
        guard let bytes else { return }
        lock.lock(); defer { lock.unlock() }
        // Only a live child can contribute a sample.
        guard childStarted != nil, !exitConfirmed else { return }
        peakRSS = max(peakRSS ?? bytes, bytes)
        if samples < UInt64.max { samples += 1 }
    }
    func recordExit(status: Int32, reason: LocalInferenceTerminationReason) {
        lock.lock(); defer { lock.unlock() }
        guard let childStarted, !exitConfirmed else { return }
        childElapsed = Self.elapsed(from: childStarted, to: clock())
        exitConfirmed = true; terminationStatus = status; terminationReason = reason
    }
    func willCreateTemporaryDirectory() {
        lock.lock(); defer { lock.unlock() }; cleanup = .unconfirmed
    }
    func recordCleanup(confirmed: Bool) {
        lock.lock(); defer { lock.unlock() }; cleanup = confirmed ? .confirmed : .failed
    }
    func snapshot() -> LocalInferenceJobMetrics {
        lock.lock(); defer { lock.unlock() }
        return LocalInferenceJobMetrics(kind: kind, outcome: outcome,
            elapsedSeconds: Self.elapsed(from: started, to: clock()), childElapsedSeconds: childElapsed,
            sampledPeakResidentBytes: peakRSS, residentSampleCount: samples,
            residentSampleIntervalSeconds: Self.sampleIntervalSeconds,
            configuredResidentLimitBytes: kind.residentLimitBytes, configuredWallLimitSeconds: kind.wallLimitSeconds,
            childLaunched: childStarted != nil, childExitConfirmed: exitConfirmed,
            childTerminationStatus: terminationStatus, childTerminationReason: terminationReason,
            temporaryDirectoryCleanup: cleanup)
    }
    private static func elapsed(from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        let elapsed = end - start
        return elapsed.isFinite ? max(0, elapsed) : 0
    }
}
