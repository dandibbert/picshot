import Foundation

/// Test-only one-shot phase signal. Check-and-register, open and timeout are
/// atomic with respect to each other; exactly one of them owns each resume.
/// Intentionally ignores task cancellation so a fixture can model a detached
/// helper still unwinding, but every wait has an independent Dispatch deadline.
final class InferenceTestLatch: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: DispatchWorkItem
    }
    private let lock = NSLock()
    private var opened = false
    private var waiters: [UUID: Waiter] = [:]

    func wait(timeout: TimeInterval = 3, phase: String) async throws {
        precondition(timeout.isFinite && timeout > 0)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let id = UUID()
            let timeoutWork = DispatchWorkItem { [weak self] in self?.expire(id, phase: phase) }
            // Do not check opened before entering the continuation closure:
            // registration and open must share one non-suspending critical section.
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[id] = Waiter(continuation: continuation, timeout: timeoutWork)
                lock.unlock()
                // If open raced this scheduling, the cancelled item is harmless.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        }
    }

    var waitingCount: Int {
        lock.lock(); defer { lock.unlock() }; return waiters.count
    }

    func open() {
        lock.lock()
        opened = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    private func expire(_ id: UUID, phase: String) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.continuation.resume(throwing: InferenceTestSynchronizationError.timedOut(phase))
    }
}

enum InferenceTestSynchronizationError: Error, CustomStringConvertible {
    case timedOut(String)
    case missingResult
    var description: String {
        switch self {
        case .timedOut(let phase): return "Timed out waiting for inference test phase: \(phase)"
        case .missingResult: return "Inference test signalled completion without a result"
        }
    }
}

/// A bounded observer for an unstructured test task. Avoids awaiting task.value
/// forever after a failed handshake, without pretending cancellation is cleanup.
/// Timeout is a test failure; it never marks a child exited or releases a lease.
final class InferenceTestOperation<Value: Sendable>: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        let finished = InferenceTestLatch()
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        func store(_ value: Result<Value, Error>) {
            lock.lock(); result = value; lock.unlock()
            finished.open()
        }
        func read() throws -> Value {
            lock.lock(); let value = result; lock.unlock()
            guard let value else { throw InferenceTestSynchronizationError.missingResult }
            return try value.get()
        }
    }
    private let completion: Completion
    private let task: Task<Void, Never>

    init(_ operation: @escaping @Sendable () async throws -> Value) {
        let completion = Completion()
        self.completion = completion
        task = Task.detached {
            do { completion.store(.success(try await operation())) }
            catch { completion.store(.failure(error)) }
        }
    }
    func cancel() { task.cancel() }
    func value(timeout: TimeInterval = 3, phase: String) async throws -> Value {
        try await completion.finished.wait(timeout: timeout, phase: phase)
        return try completion.read()
    }
    deinit { task.cancel() }
}
