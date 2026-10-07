import Foundation

/// Constructor-only observations for one synthetic test job. No paths, request
/// bytes, environment, error descriptions, callbacks, or I/O enter this recorder.
/// Production configurations do not create or retain one. Use a fresh instance
/// per observed job; a reused instance stays bounded and reports dropped events.
final class GIFProcessLaunchDiagnostics: @unchecked Sendable {
    static let maximumEvents = 16
    static let maximumEncodedBytes = 4_096

    enum Phase: String, Codable, Sendable {
        case executableValidationStarted, destinationPreparationStarted, sourceSnapshotStarted
        case processConfigurationStarted, processRunStarted, processRunSucceeded, processRunFailed
        case requestPipeConfigurationStarted, requestPipeReady, requestPipeFailed
        case requestWriteStarted, requestWriteSucceeded, requestWriteFailed
        case helperRunning, helperResponse
    }
    enum Stage: String, Codable, Sendable {
        case idle, executableValidation, destinationPreparation, sourceSnapshot, processConfiguration
        case processRun, requestPipeConfiguration, requestWrite, helperRunning, helperResponse
    }
    enum RequestState: String, Codable, Sendable {
        case notAttempted, configuringPipe, pipeReady, pipeFailed, writing, written, writeFailed
    }
    struct Event: Codable, Equatable, Sendable {
        let sequence: Int
        let phase: Phase
        let elapsedSeconds: TimeInterval
        let unixSeconds: TimeInterval
    }
    struct Snapshot: Codable, Equatable, Sendable {
        let startedUptimeSeconds: TimeInterval
        let capturedElapsedSeconds: TimeInterval
        let stage: Stage
        let childLaunched: Bool
        let requestState: RequestState
        let events: [Event]
        let eventsDropped: Int

        /// Called only by test evidence emission, after freezing the observation.
        /// Refuse oversized output rather than silently emitting an unbounded log.
        func boundedJSON() -> Data? {
            guard events.count <= GIFProcessLaunchDiagnostics.maximumEvents,
                  let data = try? JSONEncoder().encode(self),
                  data.count <= GIFProcessLaunchDiagnostics.maximumEncodedBytes else { return nil }
            return data
        }
    }

    private let lock = NSLock()
    private let start = ProcessInfo.processInfo.systemUptime
    private var stage = Stage.idle
    private var childLaunched = false
    private var requestState = RequestState.notAttempted
    private var events: [Event] = []
    private var eventsDropped = 0

    func record(_ phase: Phase) {
        lock.lock(); defer { lock.unlock() }
        // Stamp while locked so sequence and monotonic times share one order,
        // including a readiness snapshot racing the service thread.
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        switch phase {
        case .executableValidationStarted: stage = .executableValidation
        case .destinationPreparationStarted: stage = .destinationPreparation
        case .sourceSnapshotStarted: stage = .sourceSnapshot
        case .processConfigurationStarted: stage = .processConfiguration
        case .processRunStarted, .processRunFailed: stage = .processRun
        case .processRunSucceeded: stage = .processRun; childLaunched = true
        case .requestPipeConfigurationStarted: stage = .requestPipeConfiguration; requestState = .configuringPipe
        case .requestPipeReady: stage = .requestPipeConfiguration; requestState = .pipeReady
        case .requestPipeFailed: stage = .requestPipeConfiguration; requestState = .pipeFailed
        case .requestWriteStarted: stage = .requestWrite; requestState = .writing
        case .requestWriteSucceeded: stage = .requestWrite; requestState = .written
        case .requestWriteFailed: stage = .requestWrite; requestState = .writeFailed
        case .helperRunning: stage = .helperRunning
        case .helperResponse: stage = .helperResponse
        }
        guard events.count < Self.maximumEvents else {
            if eventsDropped < Int.max { eventsDropped += 1 }
            return
        }
        events.append(Event(sequence: events.count, phase: phase, elapsedSeconds: elapsed,
                            unixSeconds: Date().timeIntervalSince1970))
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(startedUptimeSeconds: start,
                        capturedElapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                        stage: stage, childLaunched: childLaunched, requestState: requestState,
                        events: events, eventsDropped: eventsDropped)
    }
}
