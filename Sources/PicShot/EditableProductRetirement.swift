import Foundation

/// Fixture-only completion evidence. No image/provider is retained by these
/// scalar observations, and no product cache, redraw or purge is requested.
@MainActor enum EditableProductRetirement {
    static let maximumWaitSeconds = 2.0
    static let pollIntervalSeconds = 0.01
    private static let pollNanoseconds: UInt64 = 10_000_000

    enum Failure: Error, Equatable, LocalizedError {
        case invalidObservation, deadlineExceeded, retirementTimedOut, workChangedDuringRetirement
        var errorDescription: String? {
            switch self {
            case .invalidObservation: return "Product retirement observation was invalid"
            case .deadlineExceeded: return "Product retirement reached the unchanged overall deadline"
            case .retirementTimedOut: return "Drawing providers did not retire inside the two-second cap"
            case .workChangedDuringRetirement: return "Product work or ownership changed during provider retirement"
            }
        }
    }
    struct Ownership: Codable, Equatable {
        var created: Int
        var aliveNonWindowObjects: Int
        var liveEditors: Int
        var livePins: Int
        var attachedWindowGraphs: Int
        var retainedWindowShells: Int
        var drained: Bool {
            aliveNonWindowObjects == 0 && liveEditors == 0 && livePins == 0 && attachedWindowGraphs == 0
        }
    }
    struct Work: Codable, Equatable {
        var appEditorCount: Int
        var pinCount: Int
        var pinEditorCount: Int
        var projectionBusy: Bool
        var projectionReservedBytes: Int
        var projectionQueueOperations: Int
        var projectionStarted: Int
        var projectionCompleted: Int
        var exportSessions: Int
        var exportQueueOperations: Int
        var drained: Bool {
            appEditorCount == 0 && pinCount == 0 && pinEditorCount == 0 && !projectionBusy
                && projectionReservedBytes == 0 && projectionQueueOperations == 0
                && projectionStarted == projectionCompleted && exportSessions == 0 && exportQueueOperations == 0
        }
    }
    struct State: Equatable {
        var ownership: Ownership
        var work: Work
        var drawing: DrawingRasterSnapshot
    }
    struct Observation: Codable, Equatable {
        var uptimeSeconds: Double
        var ownership: Ownership
        var work: Work
        var drawing: DrawingRasterSnapshot
    }
    struct Evidence: Codable, Equatable {
        var cycle: Int
        var phase: String
        var maximumWaitSeconds: Double
        var pollIntervalSeconds: Double
        var status = "waiting"
        var pollCount = 0
        var elapsedSeconds = 0.0
        var weakJobDrained: Observation
        var providerRetired: Observation?
    }

    static func balanced(_ value: DrawingRasterSnapshot) -> Bool {
        value.activeBytes == 0 && value.allocations == value.deallocations
            && value.allocations == value.releaseCallbacks && value.allocations == value.ownedCount
            && value.allocatedBytes == value.deallocatedBytes && value.allocatedBytes == value.callbackBytes
            && value.eligibleCount >= value.ownedCount
            && value.eligibleCount - value.ownedCount == value.seededContextCount
    }

    /// Wait first for the unchanged weak-owner/job condition. Then record it
    /// before awaiting providers, with a separate 2s cap inside the full deadline.
    /// Injectable time/suspension makes failure cases deterministic in tests.
    static func wait(cycle: Int, phase: String, deadline: Double,
        clock: () -> Double = { ProcessInfo.processInfo.systemUptime },
        cancellation: () throws -> Void = { try Task.checkCancellation() },
        pause: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        observe: () throws -> State,
        record: (Evidence) throws -> Void) async throws -> Evidence {
        var lastTime: Double?
        func checkedTime() throws -> Double {
            try cancellation()
            let time = clock()
            guard time.isFinite, time >= 0, deadline.isFinite,
                  lastTime.map({ time >= $0 }) ?? true else { throw Failure.invalidObservation }
            guard time < deadline else { throw Failure.deadlineExceeded }
            lastTime = time
            return time
        }
        func sample() throws -> Observation {
            _ = try checkedTime()
            let state = try observe()
            try validate(state)
            return Observation(uptimeSeconds: try checkedTime(), ownership: state.ownership,
                work: state.work, drawing: state.drawing)
        }
        var current = try sample()
        while !(current.ownership.drained && current.work.drained) {
            _ = try checkedTime()
            try await pause(pollNanoseconds)
            current = try sample()
        }
        let first = current
        var evidence = Evidence(cycle: cycle, phase: phase,
            maximumWaitSeconds: maximumWaitSeconds, pollIntervalSeconds: pollIntervalSeconds,
            weakJobDrained: first)
        try record(evidence)
        do {
            guard first.drawing.allocations == first.drawing.ownedCount,
                  first.drawing.eligibleCount >= first.drawing.ownedCount,
                  first.drawing.eligibleCount - first.drawing.ownedCount == first.drawing.seededContextCount else {
                throw Failure.invalidObservation
            }
            while true {
                let time = try checkedTime()
                guard time - first.uptimeSeconds < maximumWaitSeconds else { throw Failure.retirementTimedOut }
                if balanced(current.drawing) {
                    evidence.status = "retired"
                    evidence.providerRetired = current
                    evidence.elapsedSeconds = current.uptimeSeconds - first.uptimeSeconds
                    try record(evidence)
                    return evidence
                }
                try await pause(pollNanoseconds)
                evidence.pollCount += 1
                let previous = current
                current = try sample()
                guard current.uptimeSeconds - first.uptimeSeconds < maximumWaitSeconds else {
                    throw Failure.retirementTimedOut
                }
                try unchangedWork(previous, current)
                evidence.elapsedSeconds = current.uptimeSeconds - first.uptimeSeconds
                try record(evidence)
            }
        } catch {
            evidence.status = "failed"
            evidence.providerRetired = nil
            let time = clock()
            if time.isFinite && time >= first.uptimeSeconds { evidence.elapsedSeconds = time - first.uptimeSeconds }
            try record(evidence)
            throw error
        }
    }

    private static func validate(_ state: State) throws {
        let owner = state.ownership, work = state.work, drawing = state.drawing
        let owners = [owner.aliveNonWindowObjects, owner.liveEditors, owner.livePins,
            owner.attachedWindowGraphs, owner.retainedWindowShells]
        let workCounts = [work.appEditorCount, work.pinCount, work.pinEditorCount, work.projectionReservedBytes,
            work.projectionQueueOperations, work.projectionStarted, work.projectionCompleted,
            work.exportSessions, work.exportQueueOperations]
        let drawingCounts = [drawing.referenceCount, drawing.eligibleCount, drawing.ownedCount,
            drawing.seededContextCount, drawing.presentationReuseCount, drawing.presentationFallbackCount,
            drawing.failureCount, drawing.allocations, drawing.deallocations, drawing.releaseCallbacks,
            drawing.allocatedBytes, drawing.deallocatedBytes, drawing.callbackBytes, drawing.activeBytes,
            drawing.peakActiveBytes, drawing.seededContextBytes]
        guard (1...64).contains(owner.created), owners.allSatisfy({ (0...owner.created).contains($0) }),
              workCounts.allSatisfy({ $0 >= 0 }), work.projectionCompleted <= work.projectionStarted,
              drawingCounts.allSatisfy({ $0 >= 0 }), drawing.callbackSizesMatch,
              drawing.failureCount == 0, drawing.presentationFallbackCount == 0,
              drawing.unsupportedCounts.values.allSatisfy({ $0 > 0 }),
              drawing.unsupportedCounts.keys.allSatisfy({ DrawingRaster.UnsupportedReason(rawValue: $0) != nil }),
              drawing.deallocations <= drawing.allocations, drawing.releaseCallbacks <= drawing.allocations,
              drawing.ownedCount <= drawing.allocations, drawing.ownedCount <= drawing.eligibleCount,
              drawing.seededContextCount <= drawing.eligibleCount - drawing.ownedCount,
              drawing.deallocatedBytes <= drawing.allocatedBytes, drawing.callbackBytes <= drawing.allocatedBytes,
              drawing.activeBytes == drawing.allocatedBytes - drawing.deallocatedBytes,
              drawing.activeBytes <= drawing.peakActiveBytes, drawing.peakActiveBytes <= 800_000_000,
              (drawing.allocations == 0) == (drawing.allocatedBytes == 0),
              (drawing.seededContextCount == 0) == (drawing.seededContextBytes == 0) else {
            throw Failure.invalidObservation
        }
    }

    private static func unchangedWork(_ first: Observation, _ current: Observation) throws {
        var expectedOwner = first.ownership
        expectedOwner.retainedWindowShells = current.ownership.retainedWindowShells
        var expectedDrawing = first.drawing
        expectedDrawing.deallocations = current.drawing.deallocations
        expectedDrawing.deallocatedBytes = current.drawing.deallocatedBytes
        expectedDrawing.releaseCallbacks = current.drawing.releaseCallbacks
        expectedDrawing.callbackBytes = current.drawing.callbackBytes
        expectedDrawing.activeBytes = current.drawing.activeBytes
        guard current.ownership == expectedOwner,
              current.ownership.retainedWindowShells <= first.ownership.retainedWindowShells,
              current.work == first.work, current.drawing == expectedDrawing,
              current.drawing.deallocations >= first.drawing.deallocations,
              current.drawing.deallocatedBytes >= first.drawing.deallocatedBytes,
              current.drawing.releaseCallbacks >= first.drawing.releaseCallbacks,
              current.drawing.callbackBytes >= first.drawing.callbackBytes,
              current.drawing.activeBytes <= first.drawing.activeBytes else {
            throw Failure.workChangedDuringRetirement
        }
    }
}
