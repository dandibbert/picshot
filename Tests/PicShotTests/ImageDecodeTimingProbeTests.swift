import XCTest
import PicShotCodecCore
@testable import PicShot

@MainActor
final class ImageDecodeTimingProbeTests: XCTestCase {
    func testExplicitTimingSelectorIsClosedAndDefaultOff() throws {
        let base = ["PICSHOT_IMAGE_DECODE_LARGE_MODE": "prepare", "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": "5k"]
        XCTAssertEqual(try ImageDecodeLargeAttributionFixture.request(base)?.timingEnabled, false)
        var enabled = base; enabled["PICSHOT_IMAGE_DECODE_LARGE_TIMING"] = "3"
        XCTAssertEqual(try ImageDecodeLargeAttributionFixture.request(enabled)?.timingEnabled, true)
        for bad in ["", "1", "2", "true", "03", "4"] {
            enabled["PICSHOT_IMAGE_DECODE_LARGE_TIMING"] = bad
            XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(enabled))
        }
    }
    func testWorstAcknowledgementsStayBoundedAndRetainPhaseOverlap() throws {
        var value = ImageDecodeQueueTiming()
        value.transition(.sourceConstruction, at: 1)
        value.transition(.controllerSnapshotConstruction, at: 2)
        for index in 0..<20 { value.acknowledge(queued: 1.5, acknowledged: 2 + Double(index), phase: .sourceConstruction) }
        XCTAssertEqual(value.worstAcknowledgements.count, 8)
        XCTAssertEqual(value.worstAcknowledgements.first?.delaySeconds, 19.5)
        XCTAssertEqual(value.worstAcknowledgements.last?.delaySeconds, 12.5)
        XCTAssertTrue(value.worstAcknowledgements.allSatisfy { $0.queuedPhase == .sourceConstruction && $0.acknowledgedPhase == .controllerSnapshotConstruction })
        XCTAssertFalse(value.overflowed)
    }
    func testTimelineOverflowAndInvalidTimeAreExplicit() throws {
        var value = ImageDecodeQueueTiming()
        for index in 0..<64 { value.transition(.steadyPreview, at: Double(index)) }
        value.transition(.cleanup, at: 64)
        XCTAssertEqual(value.phaseTransitions.count, 64); XCTAssertTrue(value.overflowed)
        value.acknowledge(queued: .infinity, acknowledged: 3, phase: .setup)
        XCTAssertTrue(value.invalidTimestampObserved); XCTAssertTrue(value.worstAcknowledgements.isEmpty)
        var reverse = ImageDecodeQueueTiming(); reverse.transition(.setup, at: 2); reverse.transition(.cleanup, at: 1)
        XCTAssertTrue(reverse.invalidTimestampObserved); XCTAssertEqual(reverse.phaseTransitions.count, 1)
    }
    func testEnabledProbeDrainsAndBaselineOmitsTiming() async throws {
        let baseline = ImageDecodeMainQueueProbe(), enabled = ImageDecodeMainQueueProbe(timingEnabled: true)
        enabled.phase(.steadyPreview)
        try await Task.sleep(nanoseconds: 70_000_000)
        baseline.stop(); enabled.stop()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
        XCTAssertNil(baseline.snapshot().timing)
        let result = enabled.snapshot(), timing = try XCTUnwrap(result.timing)
        XCTAssertEqual(result.outstandingCallbacks, 0); XCTAssertGreaterThan(result.samples, 0)
        XCTAssertFalse(timing.overflowed); XCTAssertFalse(timing.invalidTimestampObserved)
        XCTAssertEqual(timing.worstAcknowledgements.count, min(8, result.samples))
        XCTAssertEqual(timing.worstAcknowledgements.first?.delaySeconds, result.maximumDelaySeconds)
        let bytes = try JSONEncoder().encode(result)
        XCTAssertLessThan(bytes.count, 16_384)
    }
    func testTimingCannotActivateSmallV1Supervisor() throws {
        let process = ImageDecodeDiagnosticProcess(mode: .decode, timingEnabled: true)
        XCTAssertThrowsError(try process.run(png: Data([0]), armDeadline: ProcessInfo.processInfo.systemUptime + 1))
        XCTAssertFalse(process.snapshot().childLaunched)
    }
    func testMaximumScalarTimingPayloadFitsExistingReportHeadroom() throws {
        var timing = ImageDecodeQueueTiming()
        for index in 0..<64 { timing.transition(.controllerSnapshotConstruction, at: Double(index) * 1e200) }
        for index in 0..<8 { timing.acknowledge(queued: Double(index) * 1e200, acknowledged: 64e200, phase: .setup) }
        let trace = ImageDecodeTimingTrace(childPID: Int32.max, terminalWriteStartedUptimeSeconds: 1e200,
            terminalWriteCompletedUptimeSeconds: 2e200, terminalWriteAttemptCount: 1,
            runReturnedUptimeSeconds: 3e200, framePreparedUptimeSeconds: 4e200, terminalWriteSucceeded: true)
        let traceObject = try ImageDecodeLargeSupport.object(trace)
        let parentTimes = Dictionary(uniqueKeysWithValues: ["terminalFrameReadReturned", "terminalFrameDecodedAtReceipt", "terminationObserved", "waitUntilExitStarted", "waitUntilExitCompleted"].map { ($0, Double.greatestFiniteMagnitude) })
        let perWorker: [String: Any] = ["childTimingTrace": traceObject, "parentTimingUptimes": parentTimes,
            "childTimingTraceStatus": "complete", "timingInstrumentationVersion": 3]
        let payload: [String: Any] = ["timing": try ImageDecodeLargeSupport.object(timing), "workers": Array(repeating: perWorker, count: 16)]
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        // V2's scalar-width rehearsal is ~1.44 MiB; v3 adds <32 KiB to the
        // same unchanged 2 MiB report ceiling, with no media in the payload.
        XCTAssertLessThan(bytes.count, 32_768)
    }
}
