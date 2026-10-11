import Foundation

/// Metadata only. These counters never contain screenshot bytes, hashes or window titles.
struct LiveScrollFrameCounters: Equatable, Sendable {
    var receivedFrames: UInt64 = 0
    var replacedFrames: UInt64 = 0
    var consumedFrames: UInt64 = 0
    var rejectedFrames: UInt64 = 0
    var incompleteFrames: UInt64 = 0
    var idleTimeouts: UInt64 = 0
    var pendingFrames = 0
    var peakPendingFrames = 0
    var waitingReaders = 0
    var pixelWidth = 0
    var pixelHeight = 0
    let streamQueueDepth = 3
}

/// One latest value and one waiter, never an AsyncStream/unbounded callback queue.
/// The callback only replaces this slot; conversion happens in the serial consumer.
/// A waiter is signalled without transferring a frame, so it takes the newest value
/// even when several producer callbacks run before its executor resumes.
final class LiveScrollFrameMailbox<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var accepting = false
    private var pending: Element?
    private var failure: Error = CancellationError()
    private var waiter: (id: UUID, continuation: CheckedContinuation<Bool, Error>)?
    private var timer: DispatchSourceTimer?
    private var statistics = LiveScrollFrameCounters()

    var counters: LiveScrollFrameCounters {
        locked { var result = statistics; result.waitingReaders = waiter == nil ? 0 : 1; return result }
    }

    func activate(generation: UInt64, width: Int, height: Int) {
        let previous = locked { () -> CheckedContinuation<Bool, Error>? in
            let previous = waiter?.continuation
            waiter = nil; timer?.cancel(); timer = nil
            self.generation = generation; accepting = true; pending = nil
            statistics.pendingFrames = 0
            statistics.pixelWidth = width; statistics.pixelHeight = height
            return previous
        }
        previous?.resume(throwing: CancellationError())
    }

    func isAccepting(generation: UInt64) -> Bool {
        locked { accepting && self.generation == generation }
    }

    func offer(_ value: Element, generation: UInt64) {
        let ready = locked { () -> CheckedContinuation<Bool, Error>? in
            guard accepting, self.generation == generation else {
                statistics.rejectedFrames &+= 1; return nil
            }
            statistics.receivedFrames &+= 1
            if pending != nil { statistics.replacedFrames &+= 1 }
            pending = value
            statistics.pendingFrames = 1; statistics.peakPendingFrames = 1
            let ready = waiter?.continuation
            waiter = nil; timer?.cancel(); timer = nil
            return ready
        }
        ready?.resume(returning: true)
    }

    func recordIncomplete(generation: UInt64) {
        locked {
            if accepting && self.generation == generation { statistics.incompleteFrames &+= 1 }
            else { statistics.rejectedFrames &+= 1 }
        }
    }

    /// Closing releases the retained element synchronously and wakes the reader.
    /// A delayed callback or cancellation from a previous generation cannot close a new one.
    func close(generation: UInt64, error: Error = CancellationError()) {
        let abandoned = locked { () -> CheckedContinuation<Bool, Error>? in
            guard self.generation == generation else { return nil }
            accepting = false; failure = error; pending = nil; statistics.pendingFrames = 0
            let abandoned = waiter?.continuation
            waiter = nil; timer?.cancel(); timer = nil
            return abandoned
        }
        abandoned?.resume(throwing: error)
    }

    /// Nil means unchanged content reached the bounded wait deadline.
    func next(generation: UInt64, timeout: TimeInterval) async throws -> Element? {
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw LiveScrollSourceError.invalidTimeout }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let ready = try await withCheckedThrowingContinuation { continuation in
                register(continuation, generation: generation, timeout: timeout)
            }
            try Task.checkCancellation()
            return try locked {
                guard accepting, self.generation == generation else { throw failure }
                guard ready else { return nil }
                let value = pending
                pending = nil; statistics.pendingFrames = 0
                if value != nil { statistics.consumedFrames &+= 1 }
                return value
            }
        } onCancel: {
            self.close(generation: generation)
        }
    }

    private func register(_ continuation: CheckedContinuation<Bool, Error>, generation: UInt64,
                          timeout: TimeInterval) {
        let immediate: Result<Bool, Error>? = locked {
            guard accepting, self.generation == generation else { return .failure(failure) }
            guard waiter == nil else { return .failure(LiveScrollSourceError.concurrentRead) }
            if pending != nil { return .success(true) }
            let id = UUID()
            waiter = (id, continuation)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.expire(id: id, generation: generation) }
            self.timer = timer; timer.resume()
            return nil
        }
        if let immediate { continuation.resume(with: immediate) }
    }

    private func expire(id: UUID, generation: UInt64) {
        let expired = locked { () -> CheckedContinuation<Bool, Error>? in
            guard self.generation == generation, waiter?.id == id else { return nil }
            let expired = waiter?.continuation
            waiter = nil; timer?.cancel(); timer = nil
            statistics.idleTimeouts &+= 1
            return expired
        }
        expired?.resume(returning: false)
    }

    private func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

enum LiveScrollSourceError: LocalizedError {
    case invalidTimeout, concurrentRead, paused, stopped, transitionInProgress
    case operationTimedOut(String), unconfirmedTeardown

    var errorDescription: String? {
        switch self {
        case .invalidTimeout: return "屏幕帧等待时限无效。"
        case .concurrentRead: return "屏幕帧必须依次处理。"
        case .paused: return "连续捕获已暂停。"
        case .stopped: return "连续捕获已结束。"
        case .transitionInProgress: return "正在准备或结束屏幕捕获。"
        case .operationTimedOut(let operation): return "屏幕捕获\(operation)超时，已停止接收画面。"
        case .unconfirmedTeardown: return "尚未确认屏幕捕获已结束，请停止当前截图后重试。"
        }
    }
}
