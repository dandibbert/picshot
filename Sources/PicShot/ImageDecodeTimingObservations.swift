import Foundation

/// Fixed-size diagnostic timing values. Overlap is not causal attribution.
enum ImageDecodeUIPhase: String, Codable, CaseIterable, Sendable {
    case setup, sourceConstruction, controllerSnapshotConstruction, warmupPreview, steadyPreview
    case debounceBurst, cancelActive, closeDecoded, lateResult, evidenceCapture, settle, cleanup
}
struct ImageDecodeUIPhaseTransition: Encodable, Sendable {
    let phase: ImageDecodeUIPhase, uptimeSeconds: Double
}
struct ImageDecodeQueueAcknowledgement: Encodable, Sendable {
    let queuedUptimeSeconds: Double, acknowledgedUptimeSeconds: Double, delaySeconds: Double
    let queuedPhase: ImageDecodeUIPhase, acknowledgedPhase: ImageDecodeUIPhase
}
struct ImageDecodeQueueTiming: Encodable, Sendable {
    let version = 3, maximumWorstAcknowledgements = 8, maximumPhaseTransitions = 64
    var phaseTransitions: [ImageDecodeUIPhaseTransition] = []
    var worstAcknowledgements: [ImageDecodeQueueAcknowledgement] = []
    var overflowed = false, invalidTimestampObserved = false
    var currentPhase: ImageDecodeUIPhase { phaseTransitions.last?.phase ?? .setup }
    mutating func transition(_ phase: ImageDecodeUIPhase, at time: Double) {
        guard time.isFinite, time >= 0, time >= (phaseTransitions.last?.uptimeSeconds ?? 0) else { invalidTimestampObserved = true; return }
        guard phaseTransitions.count < maximumPhaseTransitions else { overflowed = true; return }
        phaseTransitions.append(.init(phase: phase, uptimeSeconds: time))
    }
    mutating func acknowledge(queued: Double, acknowledged: Double, phase: ImageDecodeUIPhase) {
        guard queued.isFinite, acknowledged.isFinite, queued >= 0, acknowledged >= queued else { invalidTimestampObserved = true; return }
        let record = ImageDecodeQueueAcknowledgement(queuedUptimeSeconds: queued, acknowledgedUptimeSeconds: acknowledged,
            delaySeconds: acknowledged - queued, queuedPhase: phase, acknowledgedPhase: currentPhase)
        // At most nine scalar candidates temporarily, then retain the worst eight.
        worstAcknowledgements.append(record)
        worstAcknowledgements.sort { $0.delaySeconds == $1.delaySeconds ? $0.queuedUptimeSeconds < $1.queuedUptimeSeconds : $0.delaySeconds > $1.delaySeconds }
        if worstAcknowledgements.count > maximumWorstAcknowledgements { worstAcknowledgements.removeLast() }
    }
}
