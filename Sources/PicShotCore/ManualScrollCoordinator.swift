import Foundation

/// A full-color, full-frame signature, never an alignment claim. The screen driver hashes
/// normalized RGBA pixels (not sparse samples, compressed bytes, or luminance alone).
/// Keeping two signatures costs 64 digest bytes; the coordinator retains no image buffers.
public struct ManualScrollObservation: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgbaSHA256: [UInt8]

    public init(width: Int, height: Int, rgbaSHA256: [UInt8]) throws {
        guard width > 0, height > 0, width <= ScrollFrame.maximumDimension,
              height <= ScrollFrame.maximumDimension, width <= ScrollFrame.maximumPixels / height,
              rgbaSHA256.count == 32 else { throw ScrollStitchError.invalidPixels }
        self.width = width
        self.height = height
        self.rgbaSHA256 = rgbaSHA256
    }
}

/// Observation only: this protocol has no input-emission or Accessibility operation.
/// The driver may retain ONE pending image, replacing it on capture. Native drivers must
/// enforce the existing 24 MP frame, 60 MP/32768 output, 100 source and 512 MiB disk caps.
/// Capture and acceptance must check cancellation immediately before their commits.
/// Acceptance owns conservative matching and transactional source-file installation; a
/// thrown error must preserve the last accepted frame, sequence, edits, and stored sources.
@MainActor
public protocol ManualScrollDriver: AnyObject {
    func checkPermission() throws
    func validateTarget() throws
    func capture() async throws -> ManualScrollObservation
    func acceptStableCapture() async throws -> ManualScrollSample
    /// Releases only uncommitted capture data. Never clears the accepted matching anchor.
    func discardPendingCapture()
}

public enum ManualScrollSample: Sendable, Equatable {
    /// Includes verified revisits: their total source count stays unchanged.
    case accepted(totalFrames: Int)
    case duplicate
}

/// Explicitly recoverable native conditions, such as occlusion or a moved target window.
public struct ManualScrollRecoveryError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ManualScrollEnd: Sendable, Equatable {
    case stopped, frameLimit, sampleLimit, timeLimit
}

public enum ManualScrollState: Sendable, Equatable {
    case ready, countdown(Int), sampling, settling, matching, waiting, paused
    case recoverable(String)
    case finished(ManualScrollEnd)
    case failed(String)
}

public struct ManualScrollConfiguration: Sendable {
    public var countdownSeconds = 3
    public var sampleInterval: TimeInterval = 0.25
    public var stableSamples = 2
    /// Exact-color stability deliberately rejects animation. A changing screen pauses
    /// with guidance rather than spinning until the session deadline or inventing a seam.
    public var maximumUnstableSamples = 20
    public var maximumFrames = 100
    public var maximumSamples = 1_200
    /// Wall time includes the initial countdown and user pauses; resume never resets it.
    public var maximumDuration: TimeInterval = 180
    public var operationTimeout: TimeInterval = 12
    public init() {}

    var isValid: Bool {
        (0...10).contains(countdownSeconds)
            && sampleInterval.isFinite && (0.05...5).contains(sampleInterval)
            && (2...5).contains(stableSamples) && (2...240).contains(maximumUnstableSamples)
            && maximumUnstableSamples >= stableSamples
            && (1...ScrollCaptureSequence.maximumBlocks).contains(maximumFrames)
            && (2...2_400).contains(maximumSamples)
            && maximumDuration.isFinite && (0.01...600).contains(maximumDuration)
            && operationTimeout.isFinite && (0.01...30).contains(operationTimeout)
    }
}

/// Serial passive sampling with no queued captures. At most one capture OR acceptance
/// is active. Even an SDK operation ignoring cancellation must drain before resume; its
/// late result cannot restart sampling or advance coordinator state. The driver is also
/// required to reject cancellation at its own source commit boundary.
///
/// Stability is exact RGBA digest equality, not the lossy matcher's duplicate tolerance.
/// Only a new, stable viewport reaches the existing full overlap/sequence verification.
/// Pause, recoverable failure, and moved-region resume never reset accepted source data.
@MainActor
public final class ManualScrollCoordinator {
    public private(set) var state: ManualScrollState = .ready
    public private(set) var acceptedFrames: Int
    public private(set) var sampledFrames = 0
    public private(set) var hasPendingOperation = false
    public var onChange: ((ManualScrollState) -> Void)?
    public let configuration: ManualScrollConfiguration

    private let driver: any ManualScrollDriver
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> TimeInterval
    private let initialFrameCount: Int
    private var startedAt: TimeInterval?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var epoch = UUID()

    public init(configuration: ManualScrollConfiguration = .init(), driver: any ManualScrollDriver,
                initialFrameCount: Int = 0,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                }) {
        self.configuration = configuration
        self.driver = driver
        self.initialFrameCount = initialFrameCount
        acceptedFrames = initialFrameCount
        self.now = now
        self.sleep = sleep
    }

    public var isRunning: Bool {
        switch state {
        case .countdown, .sampling, .settling, .matching, .waiting: return true
        default: return false
        }
    }

    public var canResume: Bool {
        guard !hasPendingOperation else { return false }
        switch state {
        case .paused, .recoverable: return true
        default: return false
        }
    }

    /// Construction performs no permission check, capture, matching, or input operation.
    public func start() {
        guard state == .ready, !hasPendingOperation else { return }
        guard configuration.isValid,
              (0...ScrollCaptureSequence.maximumBlocks).contains(initialFrameCount) else {
            change(.failed("连续手动捕获安全限制无效。")); return
        }
        do { try driver.checkPermission() }
        catch { change(.failed(error.localizedDescription)); return }
        startedAt = now()
        launch(countdownSeconds: configuration.countdownSeconds)
    }

    public func pause() {
        guard isRunning else { return }
        invalidate()
        change(.paused)
    }

    /// Explicit resume re-samples the viewport; it never adopts a pre-pause candidate or
    /// resets the accepted anchor. The caller may move a same-size region only once drained.
    public func resume() {
        guard canResume else { return }
        launch(countdownSeconds: 0)
    }

    public func stop() {
        guard isRunning || canResume || isPausedOrRecoverable else { return }
        invalidate()
        change(.finished(.stopped))
    }

    public func cancel() {
        invalidate()
        change(.finished(.stopped))
    }

    private var isPausedOrRecoverable: Bool {
        switch state {
        case .paused, .recoverable: return true
        default: return false
        }
    }

    private func launch(countdownSeconds: Int) {
        let token = UUID()
        epoch = token
        hasPendingOperation = true
        change(countdownSeconds > 0 ? .countdown(countdownSeconds) : .settling)
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run(token: token, countdownSeconds: countdownSeconds) }
            catch is CancellationError {
                if self.epoch == token, self.isRunning {
                    self.change(.recoverable("本次采样已中断，请检查目标区域后继续；已接受的片段保持不变。"))
                }
            }
            catch {
                if self.epoch == token {
                    self.change(Self.recoveryMessage(for: error).map(ManualScrollState.recoverable)
                                ?? .failed(error.localizedDescription))
                }
            }
            // Invalidation never clears this task early: one noncooperative old image is
            // drained, not overlapped by another run. No reset touches accepted sources.
            self.watchdog?.cancel()
            self.watchdog = nil
            self.driver.discardPendingCapture()
            self.task = nil
            self.hasPendingOperation = false
            self.onChange?(self.state)
        }
    }

    private func run(token: UUID, countdownSeconds: Int) async throws {
        try check(token)
        if reachedResourceLimit() { return }
        try driver.checkPermission()
        if countdownSeconds > 0 {
            for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
                change(.countdown(remaining))
                try check(token)
                try await sleep(1)
                try check(token)
            }
        }
        // A run retains one previous 32-byte signature, plus the current result while
        // comparing. Native raster/gray/source ownership stays exclusively in the driver.
        var previous: ManualScrollObservation?
        var consecutiveStable = 0
        var consecutiveUnstable = 0
        var submittedCurrentViewport = false
        while true {
            try check(token)
            if reachedResourceLimit() { return }
            try driver.checkPermission()
            try driver.validateTarget()
            change(.sampling)
            try check(token) // onChange can synchronously Pause/Stop before I/O.
            sampledFrames += 1
            let observation = try await performWithTimeout(token) { try await self.driver.capture() }
            try check(token)
            if observation == previous {
                consecutiveStable = min(configuration.stableSamples, consecutiveStable + 1)
            } else {
                consecutiveStable = 1
                submittedCurrentViewport = false
            }
            consecutiveUnstable = consecutiveStable >= configuration.stableSamples ? 0 : consecutiveUnstable + 1
            previous = observation
            if consecutiveUnstable >= configuration.maximumUnstableSamples {
                throw ManualScrollRecoveryError(message: "画面持续变化，已暂停连续捕获。请停止滚动或避开动画区域，再继续；已接受的片段保持不变。")
            }
            if consecutiveStable >= configuration.stableSamples && !submittedCurrentViewport {
                change(.matching)
                try check(token)
                try driver.checkPermission()
                try driver.validateTarget()
                let result: ManualScrollSample
                do { result = try await performWithTimeout(token) { try await self.driver.acceptStableCapture() } }
                catch ScrollStitchError.duplicate { result = .duplicate }
                try check(token)
                if case .accepted(let count) = result {
                    guard count >= acceptedFrames, count <= configuration.maximumFrames,
                          count <= acceptedFrames + 1 else {
                        throw ManualScrollRecoveryError(message: "捕获片段计数发生变化，已暂停。请检查并完成当前截图。")
                    }
                    acceptedFrames = count
                }
                submittedCurrentViewport = true
            }
            driver.discardPendingCapture()
            if reachedResourceLimit() { return }
            change(submittedCurrentViewport ? .waiting : .settling)
            try check(token)
            try await sleep(configuration.sampleInterval)
            try check(token)
        }
    }

    private func performWithTimeout<T>(_ token: UUID, body: () async throws -> T) async throws -> T {
        try check(token)
        let remaining = max(0.001, configuration.maximumDuration - (now() - (startedAt ?? now())))
        let timeout = min(configuration.operationTimeout, remaining)
        watchdog = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(timeout) } catch { return }
            guard self.epoch == token, !Task.isCancelled else { return }
            self.invalidate()
            self.change(remaining <= self.configuration.operationTimeout
                        ? .finished(.timeLimit)
                        : .failed("屏幕捕获或匹配超时，已保留捕获内容。"))
        }
        defer { watchdog?.cancel(); watchdog = nil }
        let result = try await body()
        try check(token)
        return result
    }

    private func reachedResourceLimit() -> Bool {
        if acceptedFrames >= configuration.maximumFrames { change(.finished(.frameLimit)); return true }
        if sampledFrames >= configuration.maximumSamples { change(.finished(.sampleLimit)); return true }
        return false
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard epoch == token else { throw CancellationError() }
        if let startedAt, now() - startedAt >= configuration.maximumDuration {
            change(.finished(.timeLimit))
            throw CancellationError()
        }
    }

    private func invalidate() {
        epoch = UUID()
        task?.cancel()
        watchdog?.cancel()
        watchdog = nil
        // The driver may still be inside capture/accept. It owns that transient until the
        // operation drains; clearing it here could race with a pending native commit.
        if !hasPendingOperation { driver.discardPendingCapture() }
    }

    private func change(_ next: ManualScrollState) {
        state = next
        onChange?(state)
    }

    private static func recoveryMessage(for error: Error) -> String? {
        if let recoverable = error as? ManualScrollRecoveryError { return recoverable.message }
        guard let stitch = error as? ScrollStitchError else { return nil }
        switch stitch {
        case .noOverlap, .ambiguousOverlap, .insufficientTexture, .differentDimensions:
            return stitch.localizedDescription
        default: return nil
        }
    }
}
