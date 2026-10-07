import Foundation
@testable import PicShot

/// Evidence for one explicitly synthetic shared-lease test, never a production
/// helper or timing override. It adds no child, prewarming, retries, or waits.
final class CodecGIFReadinessEvidence: @unchecked Sendable {
    let launchDiagnostics = GIFProcessLaunchDiagnostics()
    private let lock = NSLock()
    private let start = ProcessInfo.processInfo.systemUptime
    private var events: [[String: Any]] = []
    private var eventsDropped = 0
    private var childCaptures: [[String: Any]] = []
    private var wait: [String: Any] = [:]
    private var launchAtReadiness: GIFProcessLaunchDiagnostics.Snapshot?
    private var previousWake: TimeInterval?
    private var maximumWakeGap: TimeInterval = 0
    private var wakeCount = 0

    init() { record("evidenceCreated") }

    func record(_ phase: String, fraction: Double? = nil, errorType: String? = nil,
                callbackEnteredUptime: TimeInterval? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        var event: [String: Any] = ["phase": phase, "elapsedSeconds": now - start,
                                    "unixSeconds": Date().timeIntervalSince1970,
                                    "isMainThread": Thread.isMainThread]
        if let fraction { event["fraction"] = fraction }
        if let errorType { event["errorType"] = String(errorType.prefix(128)) }
        if let callbackEnteredUptime { event["callbackEnteredElapsedSeconds"] = callbackEnteredUptime - start }
        lock.lock(); defer { lock.unlock() }
        if events.count < 32 { events.append(event) } else { eventsDropped += 1 }
    }

    func beginWait(deadline: Date) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        previousWake = now
        wait = ["startedElapsedSeconds": now - start, "deadlineUnixSeconds": deadline.timeIntervalSince1970,
                "configuredReadinessSeconds": 3, "configuredPollSeconds": 0.01]
    }

    func recordWaitWake() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if let previousWake { maximumWakeGap = max(maximumWakeGap, now - previousWake) }
        previousWake = now; wakeCount += 1
    }

    func endWait(progressCount: Int) {
        // Synchronous, bounded memory snapshot: no actor hop, JSON encoding or
        // file I/O can let a late service event replace this frozen observation.
        let launchSnapshot = launchDiagnostics.snapshot()
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        wait["endedElapsedSeconds"] = now - start
        wait["endedUnixSeconds"] = Date().timeIntervalSince1970
        wait["progressCountAtAssertion"] = progressCount
        launchAtReadiness = launchSnapshot
    }

    func captureChildTrace(phase: String) {
        // v1/v2 logs retain their historical Python sidecars unchanged. This
        // fixture has no child-side timing probe: absence is explicit, never a
        // fabricated interpreter milestone or a claim that the child was silent.
        let capture: [String: Any] = [
            "phase": phase, "readElapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "status": "notCollectedForShellFixture", "records": [[String: Any]]()
        ]
        lock.lock(); defer { lock.unlock() }
        if childCaptures.count < 2 { childCaptures.append(capture) }
    }

    func emit(finalSnapshot: GIFExportProcessSnapshot?) {
        guard let data = encodedPayload(finalSnapshot: finalSnapshot) else {
            print("GIF readiness evidence: {\"schema\":\"picshot-codec-gif-readiness-v3\",\"encodingFailedOrOversized\":true}")
            return
        }
        print("GIF readiness evidence: " + String(decoding: data, as: UTF8.self))
    }

    // Shared with negative/ordering tests so they verify the actual emitted
    // payload, including its whole-record byte bound and frozen readiness state.
    func encodedPayload(finalSnapshot: GIFExportProcessSnapshot?) -> Data? {
        let finalLaunch = launchDiagnostics.snapshot()
        #if arch(x86_64)
        let architecture = "x86_64"
        #elseif arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "other"
        #endif
        lock.lock()
        var payload: [String: Any] = [
            "schema": "picshot-codec-gif-readiness-v3",
            "scope": "test-only synthetic /bin/sh builtins then exec /bin/sleep; not the signed native GIF helper",
            "syntheticFixture": "systemShellReadPrintfExecSleep",
            "childTraceStatus": "notCollectedForShellFixture",
            "expectedProgressBytes": CodecGIFLeaseFixture.progressBytes.count,
            "test": "CodecExportProcessTests.testSharedLeaseRejectsCodecWhileGIFChildRunsAndReleasesAfterConfirmedCancel",
            "probeSource": #fileID, "architecture": architecture,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "logicalProcessorCount": ProcessInfo.processInfo.processorCount,
            "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
            "sourceFixture": ["bytes": 1, "kind": "synthetic, not valid media"],
            "configuredGIFWallSeconds": 5, "parentEvents": events, "parentEventsDropped": eventsDropped,
            "parentStartedUptimeSeconds": start,
            "readinessWait": wait, "waitWakeCount": wakeCount, "maximumWaitWakeGapSeconds": maximumWakeGap,
            "childTraceCaptures": childCaptures,
            "clockScope": "unixSeconds permits wall-clock correlation; use monotonic deltas only within each process"
        ]
        let readinessLaunch = launchAtReadiness
        lock.unlock()
        for (key, snapshot) in [("launchAtReadiness", readinessLaunch), ("launchAfterTaskJoin", Optional(finalLaunch))] {
            if let snapshot, let data = snapshot.boundedJSON(),
               let object = try? JSONSerialization.jsonObject(with: data) {
                payload[key] = object
            } else { payload[key + "MissingOrOversized"] = true }
        }
        if let finalSnapshot, let data = try? JSONEncoder().encode(finalSnapshot),
           let object = try? JSONSerialization.jsonObject(with: data) {
            payload["finalGIFSnapshot"] = object
        } else { payload["finalGIFSnapshotMissing"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              data.count <= 16_384 else { return nil }
        return data
    }
}
