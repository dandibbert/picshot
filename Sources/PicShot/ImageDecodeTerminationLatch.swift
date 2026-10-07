import Foundation

/// Fixed-size evidence from Foundation's termination callback, using the same
/// monotonic uptime clock as the diagnostic supervisor. This is not pipe EOF,
/// job cleanup, or permission to release the supervisor's ownership lease.
struct ImageDecodeTerminationObservation: Codable, Equatable, Sendable {
    var callbackCount = 0
    var childPID: Int32?
    var terminationStatus: Int32?
    var terminationReason: Int?
    var callbackObservedNotRunning: Bool?
    var callbackEnteredUptimeSeconds: Double?
    var callbackPublishedUptimeSeconds: Double?
}

enum ImageDecodeTerminationLatchError: Error, Equatable {
    case processAlreadyLaunched
    case terminationHandlerAlreadyInstalled
    case callbackMissing
    case multipleCallbacks(Int)
    case malformedObservation
    case callbackObservedRunning
    case processIdentifierMismatch(expected: Int32, observed: Int32)
    case processStillRunning
    case terminationStatusMismatch(expected: Int32, observed: Int32)
    case terminationReasonMismatch(expected: Int, observed: Int)
}

/// Diagnostic-only callback latch. The Process owns the handler, which owns
/// this latch; the latch never owns or stores a Process, handler, or provider.
/// Installing it does not launch, terminate, reap, or release anything.
final class ImageDecodeTerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var observation = ImageDecodeTerminationObservation()

    /// Must be installed by the Process owner before its one permitted run().
    /// Installation and launch are serialized by that owner, not this latch.
    static func install(on process: Process) throws -> ImageDecodeTerminationLatch {
        guard !process.isRunning, process.processIdentifier == 0 else {
            throw ImageDecodeTerminationLatchError.processAlreadyLaunched
        }
        guard process.terminationHandler == nil else {
            throw ImageDecodeTerminationLatchError.terminationHandlerAlreadyInstalled
        }
        let latch = ImageDecodeTerminationLatch()
        process.terminationHandler = { [latch] exitedProcess in
            let entered = ProcessInfo.processInfo.systemUptime
            let notRunning = !exitedProcess.isRunning
            // Foundation raises an exception for terminationStatus while running.
            // A malformed callback must remain rejectable without that access.
            let status = notRunning ? exitedProcess.terminationStatus : nil
            let reason = notRunning ? exitedProcess.terminationReason.rawValue : nil
            latch.recordCallback(childPID: exitedProcess.processIdentifier,
                terminationStatus: status, terminationReason: reason,
                observedNotRunning: notRunning, enteredUptimeSeconds: entered)
        }
        return latch
    }

    func snapshot() -> ImageDecodeTerminationObservation {
        lock.lock(); defer { lock.unlock() }
        return observation
    }

    /// Bounded wait for publication only. A true result still needs validation.
    /// First publication permanently opens the scalar latch for every observer.
    /// No pending semaphore/group retains resources when launch never succeeds.
    func wait(untilUptimeSeconds deadline: Double) -> Bool {
        while snapshot().callbackCount == 0 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard deadline.isFinite, remaining > 0 else { return false }
            Thread.sleep(forTimeInterval: min(0.005, remaining))
        }
        return true
    }

    /// The supplied Process must be the supervisor's still-owned instance.
    /// This checks matching scalar evidence, not ownership, pipe EOF, or cleanup.
    @discardableResult
    func validateCompletion(for process: Process) throws -> ImageDecodeTerminationObservation {
        // Do not hold our lock while entering Foundation's Process accessors.
        let value = snapshot()
        guard value.callbackCount > 0 else { throw ImageDecodeTerminationLatchError.callbackMissing }
        guard value.callbackCount == 1 else { throw ImageDecodeTerminationLatchError.multipleCallbacks(value.callbackCount) }
        guard let pid = value.childPID, pid > 0,
              let notRunning = value.callbackObservedNotRunning,
              let entered = value.callbackEnteredUptimeSeconds, entered.isFinite, entered >= 0,
              let published = value.callbackPublishedUptimeSeconds, published.isFinite, published >= entered,
              published <= ProcessInfo.processInfo.systemUptime else {
            throw ImageDecodeTerminationLatchError.malformedObservation
        }
        guard notRunning else { throw ImageDecodeTerminationLatchError.callbackObservedRunning }
        guard let status = value.terminationStatus,
              let reason = value.terminationReason,
              reason == Process.TerminationReason.exit.rawValue || reason == Process.TerminationReason.uncaughtSignal.rawValue else {
            throw ImageDecodeTerminationLatchError.malformedObservation
        }
        let ownedPID = process.processIdentifier
        guard ownedPID == pid else {
            throw ImageDecodeTerminationLatchError.processIdentifierMismatch(expected: ownedPID, observed: pid)
        }
        guard !process.isRunning else { throw ImageDecodeTerminationLatchError.processStillRunning }
        let currentStatus = process.terminationStatus
        guard currentStatus == status else {
            throw ImageDecodeTerminationLatchError.terminationStatusMismatch(expected: currentStatus, observed: status)
        }
        let currentReason = process.terminationReason.rawValue
        guard currentReason == reason else {
            throw ImageDecodeTerminationLatchError.terminationReasonMismatch(expected: currentReason, observed: reason)
        }
        // First-published fields never change. Reject any duplicate that arrived
        // while comparing them against Foundation's current process state.
        let confirmed = snapshot()
        guard confirmed.callbackCount == 1 else {
            throw ImageDecodeTerminationLatchError.multipleCallbacks(confirmed.callbackCount)
        }
        return confirmed
    }

    /// Scalar-only publication is separate to allow deterministic rejection and
    /// concurrency tests. Only install(on:)'s handler calls it in the supervisor.
    /// Preserve the first observation; count duplicate callbacks without growth.
    func recordCallback(childPID: Int32, terminationStatus: Int32?, terminationReason: Int?,
                        observedNotRunning: Bool, enteredUptimeSeconds: Double) {
        lock.lock()
        let first = observation.callbackCount == 0
        if observation.callbackCount < Int.max { observation.callbackCount += 1 }
        if first {
            observation.childPID = childPID
            observation.terminationStatus = terminationStatus
            observation.terminationReason = terminationReason
            observation.callbackObservedNotRunning = observedNotRunning
            observation.callbackEnteredUptimeSeconds = enteredUptimeSeconds
            observation.callbackPublishedUptimeSeconds = ProcessInfo.processInfo.systemUptime
        }
        lock.unlock()
    }
}
