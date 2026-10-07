import XCTest
import Foundation
@testable import PicShot

/// The class name deliberately belongs to the existing CodecExportProcess
/// diagnostic CI filter. No Python, model, or signed native helper is needed.
final class CodecExportProcessLaunchDiagnosticsTests: XCTestCase {
    func testProductionAndOrdinaryInjectedConfigurationsDoNotCollectLaunchEvents() {
        XCTAssertNil(GIFProcessConfiguration.production.launchDiagnosticsForTesting)
        XCTAssertNil(GIFProcessConfiguration(executable: { URL(fileURLWithPath: "/bin/cat") })
            .launchDiagnosticsForTesting)
    }

    func testReadinessSnapshotCannotAcquireLaterLaunchOrRequestSuccess() throws {
        let recorder = GIFProcessLaunchDiagnostics()
        recorder.record(.processRunStarted)
        let frozen = recorder.snapshot()
        recorder.record(.processRunSucceeded)
        recorder.record(.requestPipeConfigurationStarted)
        recorder.record(.requestPipeReady)
        recorder.record(.requestWriteStarted)
        let writing = recorder.snapshot()
        recorder.record(.requestWriteFailed)
        recorder.record(.helperRunning)
        let final = recorder.snapshot()

        XCTAssertEqual(frozen.stage, .processRun)
        XCTAssertFalse(frozen.childLaunched)
        XCTAssertEqual(frozen.requestState, .notAttempted)
        XCTAssertEqual(frozen.events.map(\.phase), [.processRunStarted])
        XCTAssertEqual(writing.requestState, .writing)
        XCTAssertTrue(final.childLaunched)
        XCTAssertEqual(final.requestState, .writeFailed)
        XCTAssertFalse(final.events.contains { $0.phase == .requestWriteSucceeded })
        XCTAssertLessThanOrEqual(frozen.capturedElapsedSeconds, writing.capturedElapsedSeconds)
        XCTAssertLessThanOrEqual(writing.capturedElapsedSeconds, final.capturedElapsedSeconds)
        XCTAssertNotNil(frozen.boundedJSON())
    }

    func testConcurrentDiagnosticOverflowIsBoundedAndChronological() throws {
        let recorder = GIFProcessLaunchDiagnostics()
        DispatchQueue.concurrentPerform(iterations: 128) { _ in recorder.record(.processRunStarted) }
        let frozen = recorder.snapshot()
        XCTAssertEqual(frozen.events.count, GIFProcessLaunchDiagnostics.maximumEvents)
        XCTAssertEqual(frozen.eventsDropped, 128 - GIFProcessLaunchDiagnostics.maximumEvents)
        XCTAssertEqual(frozen.events.map(\.sequence), Array(0..<GIFProcessLaunchDiagnostics.maximumEvents))
        for (earlier, later) in zip(frozen.events, frozen.events.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.elapsedSeconds, later.elapsedSeconds)
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(frozen.events.last).elapsedSeconds, frozen.capturedElapsedSeconds)
        let data = try XCTUnwrap(frozen.boundedJSON())
        XCTAssertLessThanOrEqual(data.count, GIFProcessLaunchDiagnostics.maximumEncodedBytes)
        let roundTrip = try JSONDecoder().decode(GIFProcessLaunchDiagnostics.Snapshot.self, from: data)
        XCTAssertEqual(roundTrip, frozen)
        // Overflow cannot hide the latest state or mutate an earlier snapshot.
        recorder.record(.processRunSucceeded)
        recorder.record(.requestPipeFailed)
        let latest = recorder.snapshot()
        XCTAssertTrue(latest.childLaunched)
        XCTAssertEqual(latest.requestState, .pipeFailed)
        XCTAssertFalse(frozen.childLaunched)
        XCTAssertEqual(latest.events, frozen.events)
        XCTAssertEqual(latest.eventsDropped, frozen.eventsDropped + 2)
    }

    func testEmittedReadinessPreservesFailureAfterLateLaunchAndWrite() throws {
        let evidence = CodecGIFReadinessEvidence()
        evidence.beginWait(deadline: Date().addingTimeInterval(3))
        evidence.launchDiagnostics.record(.processRunStarted)
        evidence.endWait(progressCount: 0)
        evidence.launchDiagnostics.record(.processRunSucceeded)
        evidence.launchDiagnostics.record(.requestWriteStarted)
        evidence.launchDiagnostics.record(.requestWriteSucceeded)
        let data = try XCTUnwrap(evidence.encodedPayload(finalSnapshot: nil))
        XCTAssertLessThanOrEqual(data.count, 16_384)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wait = try XCTUnwrap(payload["readinessWait"] as? [String: Any])
        let frozen = try XCTUnwrap(payload["launchAtReadiness"] as? [String: Any])
        let final = try XCTUnwrap(payload["launchAfterTaskJoin"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(payload["parentStartedUptimeSeconds"] as? Double).isFinite)
        XCTAssertEqual(payload["schema"] as? String, "picshot-codec-gif-readiness-v3")
        XCTAssertEqual(payload["childTraceStatus"] as? String, "notCollectedForShellFixture")
        XCTAssertEqual(payload["syntheticFixture"] as? String, "systemShellReadPrintfExecSleep")
        XCTAssertEqual(wait["progressCountAtAssertion"] as? Int, 0)
        XCTAssertEqual(frozen["childLaunched"] as? Bool, false)
        XCTAssertEqual(frozen["requestState"] as? String, "notAttempted")
        XCTAssertEqual(final["childLaunched"] as? Bool, true)
        XCTAssertEqual(final["requestState"] as? String, "written")
    }

    func testLaunchFailureIsRecordedWithoutRequestSuccessOrPrivateErrorText() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("private-source.mp4")
        try Data([1]).write(to: source)
        let recorder = GIFProcessLaunchDiagnostics()
        let missing = root.appendingPathComponent("private-missing-executable")
        let service = GIFExportProcessService(configuration: .init(executable: { missing }, arguments: [],
            wallSeconds: 5, launchDiagnosticsForTesting: recorder))
        do {
            _ = try await service.export(sourceURL: source, destinationURL: root.appendingPathComponent("never.gif"))
            XCTFail("Missing executable must fail")
        } catch { }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.events.map(\.phase), [
            .executableValidationStarted, .destinationPreparationStarted, .sourceSnapshotStarted,
            .processConfigurationStarted, .processRunStarted, .processRunFailed
        ])
        XCTAssertFalse(snapshot.childLaunched)
        XCTAssertEqual(snapshot.requestState, .notAttempted)
        let state = await service.snapshot()
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.lastJob?.childLaunched, false)
        XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, true)
        let json = String(decoding: try XCTUnwrap(snapshot.boundedJSON()), as: UTF8.self)
        XCTAssertFalse(json.contains(root.path))
        XCTAssertFalse(json.contains("private-source"))
        XCTAssertFalse(json.contains("private-missing"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testSourceRejectionReportsStagingWithoutInventingAChildLaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = GIFProcessLaunchDiagnostics()
        let service = GIFExportProcessService(configuration: .init(executable: { URL(fileURLWithPath: "/bin/cat") },
            arguments: [], wallSeconds: 5, launchDiagnosticsForTesting: recorder))
        do {
            _ = try await service.export(sourceURL: root, destinationURL: root.appendingPathComponent("never.gif"))
            XCTFail("A directory is not a valid source")
        } catch GIFExportProcessError.invalidSource { }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.stage, .sourceSnapshot)
        XCTAssertFalse(snapshot.childLaunched)
        XCTAssertEqual(snapshot.requestState, .notAttempted)
        XCTAssertFalse(snapshot.events.contains { $0.phase == .processRunStarted })
        let state = await service.snapshot()
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRealLaunchAndRequestWriteRemainOrderedWhenProtocolFails() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"); try Data([1]).write(to: source)
        let recorder = GIFProcessLaunchDiagnostics()
        // cat echoes the actual request. A request is not a valid response, so
        // the unchanged protocol gate must fail and confirm child cleanup.
        let service = GIFExportProcessService(configuration: .init(executable: { URL(fileURLWithPath: "/bin/cat") },
            arguments: [], wallSeconds: 5, launchDiagnosticsForTesting: recorder))
        do {
            _ = try await service.export(sourceURL: source, destinationURL: root.appendingPathComponent("never.gif"))
            XCTFail("Echoed request must fail the response protocol")
        } catch GIFExportProcessError.invalidProtocol { }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.events.map(\.phase), [
            .executableValidationStarted, .destinationPreparationStarted, .sourceSnapshotStarted,
            .processConfigurationStarted, .processRunStarted, .processRunSucceeded,
            .requestPipeConfigurationStarted, .requestPipeReady, .requestWriteStarted,
            .requestWriteSucceeded, .helperRunning, .helperResponse
        ])
        XCTAssertEqual(snapshot.eventsDropped, 0)
        XCTAssertTrue(snapshot.childLaunched)
        XCTAssertEqual(snapshot.requestState, .written)
        for (earlier, later) in zip(snapshot.events, snapshot.events.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.elapsedSeconds, later.elapsedSeconds)
        }
        let state = await service.snapshot()
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.lastJob?.outcome, "failed")
        XCTAssertEqual(state.lastJob?.childExitConfirmed, true)
        XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, true)
        let token = try XCTUnwrap(NativeExportAdmission.shared.acquire())
        NativeExportAdmission.shared.release(token)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshot-launch-diagnostic-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
