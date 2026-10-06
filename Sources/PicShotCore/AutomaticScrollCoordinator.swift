import Foundation

/// The driver owns capture/storage and must check cancellation before committing a frame.
/// All input is synchronous on the main actor: Stop/Pause cannot race a later event post.
@MainActor
public protocol AutomaticScrollDriver: AnyObject {
    func checkPermission() throws
    func validateTarget() throws
    func scroll(axis: ScrollAxis, points: Int) throws
    func capture() async throws -> AutomaticScrollSample
}

public enum AutomaticScrollSample: Sendable, Equatable {
    case accepted(totalFrames: Int)
    case duplicate
}

public enum AutomaticScrollEnd: Sendable, Equatable {
    case stopped, noMovement, frameLimit, eventLimit, timeLimit
}

public enum AutomaticScrollState: Sendable, Equatable {
    case ready, countdown(Int), capturing, scrolling, settling, retrying(Int), paused
    case finished(AutomaticScrollEnd)
    case failed(String)
}

public struct AutomaticScrollConfiguration: Sendable {
    public var countdownSeconds = 3
    public var stepPoints = 120
    public var settleSeconds: TimeInterval = 0.55
    public var duplicateRetrySeconds: TimeInterval = 0.8
    public var duplicateReadRetries = 2
    public var noMovementScrollAttempts = 2
    public var maximumFrames = 100
    public var maximumScrollEvents = 220
    public var maximumDuration: TimeInterval = 180
    public var captureTimeout: TimeInterval = 12
    public init() {}

    var isValid: Bool {
        (1...10).contains(countdownSeconds) && (1...240).contains(stepPoints)
            && settleSeconds.isFinite && (0.01...5).contains(settleSeconds)
            && duplicateRetrySeconds.isFinite && (0.01...5).contains(duplicateRetrySeconds)
            && (0...5).contains(duplicateReadRetries) && (1...3).contains(noMovementScrollAttempts)
            && (1...100).contains(maximumFrames) && (1...300).contains(maximumScrollEvents)
            && maximumDuration.isFinite && (0.01...600).contains(maximumDuration)
            && captureTimeout.isFinite && (0.01...30).contains(captureTimeout)
    }
}

/// No images are retained here. A fake driver can exercise every control/race/error path
/// without posting system input, reading the screen, or changing macOS TCC permissions.
@MainActor
public final class AutomaticScrollCoordinator {
    public private(set) var state: AutomaticScrollState = .ready
    public private(set) var postedEvents = 0
    public private(set) var acceptedFrames = 0
    public private(set) var hasPendingOperation = false
    public var onChange: ((AutomaticScrollState) -> Void)?
    public let configuration: AutomaticScrollConfiguration
    public let axis: ScrollAxis
    private let driver: any AutomaticScrollDriver
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> TimeInterval
    private var startedAt: TimeInterval?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var epoch = UUID()

    public init(axis: ScrollAxis, configuration: AutomaticScrollConfiguration = .init(),
                driver: any AutomaticScrollDriver, initialFrameCount: Int = 0,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                }) {
        self.axis = axis
        self.configuration = configuration
        self.driver = driver
        acceptedFrames = max(0, initialFrameCount)
        self.now = now
        self.sleep = sleep
    }

    /// This is the sole entry point that authorizes a run. Construction does no I/O.
    public func start() {
        guard state == .ready, !hasPendingOperation else { return }
        guard configuration.isValid else { change(.failed("Invalid automatic-scroll safety limits.")); return }
        do { try driver.checkPermission() }
        catch { change(.failed(error.localizedDescription)); return }
        startedAt = now()
        launch()
    }

    public func pause() {
        guard isRunning else { return }
        invalidate()
        change(.paused)
    }

    /// A suspended capture must drain before resuming, avoiding unbounded in-flight images.
    /// Resume always counts down and validates/captures the current position before input.
    public func resume() {
        guard state == .paused, !hasPendingOperation else { return }
        launch()
    }

    public func stop() {
        guard isRunning || state == .paused else { return }
        invalidate()
        change(.finished(.stopped))
    }

    public func cancel() {
        invalidate()
        change(.finished(.stopped))
    }

    public var isRunning: Bool {
        switch state {
        case .countdown, .capturing, .scrolling, .settling, .retrying: return true
        default: return false
        }
    }

    private func launch() {
        let token = UUID()
        epoch = token
        hasPendingOperation = true
        change(.countdown(configuration.countdownSeconds))
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run(token: token) }
            catch is CancellationError { }
            catch {
                if self.epoch == token { self.change(.failed(error.localizedDescription)) }
            }
            // A new run cannot start while this task is pending. Invalidation never clears
            // the task early; a noncooperative late capture is drained, never adopted.
            self.watchdog?.cancel()
            self.watchdog = nil
            self.task = nil
            self.hasPendingOperation = false
            self.onChange?(self.state)
        }
    }

    private func run(token: UUID) async throws {
        try check(token)
        if acceptedFrames >= configuration.maximumFrames { change(.finished(.frameLimit)); return }
        try driver.checkPermission()
        for remaining in stride(from: configuration.countdownSeconds, through: 1, by: -1) {
            change(.countdown(remaining))
            try await sleep(1)
            try check(token)
        }
        // Pin the target only after the countdown, allowing the user to return to the app.
        try driver.validateTarget()
        let baseline = try await sample(token)
        if case .accepted(let count) = baseline { acceptedFrames = count }
        var attemptsWithoutMovement = 0
        while true {
            try check(token)
            if acceptedFrames >= configuration.maximumFrames { change(.finished(.frameLimit)); return }
            if postedEvents >= configuration.maximumScrollEvents { change(.finished(.eventLimit)); return }
            try driver.checkPermission()
            try driver.validateTarget()
            change(.scrolling)
            // onChange may synchronously call Pause/Stop. Re-check before sending input.
            try check(token)
            try driver.scroll(axis: axis, points: configuration.stepPoints)
            postedEvents += 1
            attemptsWithoutMovement += 1
            try check(token)
            change(.settling)
            try await sleep(configuration.settleSeconds)
            try check(token)
            var result = try await sample(token)
            var retries = 0
            while result == .duplicate && retries < configuration.duplicateReadRetries {
                retries += 1
                change(.retrying(retries))
                try await sleep(configuration.duplicateRetrySeconds)
                try check(token)
                result = try await sample(token)
            }
            switch result {
            case .accepted(let count):
                acceptedFrames = count
                attemptsWithoutMovement = 0
            case .duplicate:
                if attemptsWithoutMovement >= configuration.noMovementScrollAttempts {
                    change(.finished(.noMovement))
                    return
                }
            }
        }
    }

    private func sample(_ token: UUID) async throws -> AutomaticScrollSample {
        try check(token)
        try driver.validateTarget()
        change(.capturing)
        try check(token)
        let remaining = max(0.001, configuration.maximumDuration - (now() - (startedAt ?? now())))
        let timeout = min(configuration.captureTimeout, remaining)
        watchdog = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(timeout) } catch { return }
            guard self.epoch == token, !Task.isCancelled else { return }
            self.invalidate()
            self.change(timeout < self.configuration.captureTimeout
                        ? .finished(.timeLimit)
                        : .failed("A screen capture timed out. Accepted frames have been kept."))
        }
        do {
            let result = try await driver.capture()
            watchdog?.cancel()
            watchdog = nil
            try check(token)
            return result
        } catch {
            watchdog?.cancel()
            watchdog = nil
            throw error
        }
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
    }

    private func change(_ next: AutomaticScrollState) {
        state = next
        onChange?(state)
    }
}
