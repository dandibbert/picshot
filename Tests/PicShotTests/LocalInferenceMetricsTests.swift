import XCTest
import Foundation
@testable import PicShot

final class LocalInferenceMetricsTests: XCTestCase {
    func testMeasuredPeakDurationAndExitAreAggregatedWithoutInventingSamples() throws {
        let clock = InferenceMetricsClock(10)
        let recorder = LocalInferenceJobRecorder(kind: .formula, clock: { clock.value })
        recorder.recordResidentBytes(9_999) // Not a child sample before launch.
        clock.set(12); recorder.recordLaunch()
        recorder.recordResidentBytes(nil)
        recorder.recordResidentBytes(128)
        recorder.recordResidentBytes(64)
        clock.set(13); recorder.recordLaunch() // Duplicate must not reset start.
        clock.set(15); recorder.recordExit(status: 9, reason: .uncaughtSignal)
        recorder.recordResidentBytes(9_999) // Ignore samples after confirmed exit.
        recorder.recordExit(status: 0, reason: .exit) // Duplicate cannot change evidence.
        recorder.willCreateTemporaryDirectory()
        recorder.recordCleanup(confirmed: true)
        recorder.recordOutcome(.cancelled)
        clock.set(18)
        let metrics = recorder.snapshot()
        XCTAssertEqual(metrics.elapsedSeconds, 8)
        XCTAssertEqual(metrics.childElapsedSeconds, 3)
        XCTAssertEqual(metrics.sampledPeakResidentBytes, 128)
        XCTAssertEqual(metrics.residentSampleCount, 2)
        XCTAssertEqual(metrics.residentSampleIntervalSeconds, 0.1)
        XCTAssertEqual(metrics.configuredResidentLimitBytes, 1_073_741_824)
        XCTAssertEqual(metrics.configuredWallLimitSeconds, 120)
        XCTAssertTrue(metrics.childLaunched)
        XCTAssertTrue(metrics.childExitConfirmed)
        XCTAssertEqual(metrics.childTerminationStatus, 9)
        XCTAssertEqual(metrics.childTerminationReason, .uncaughtSignal)
        XCTAssertEqual(metrics.temporaryDirectoryCleanup, .confirmed)
        XCTAssertEqual(metrics.outcome, .cancelled)
    }

    func testMissingObservationNeverBecomesZeroPeakOrConfirmedCleanup() {
        let recorder = LocalInferenceJobRecorder(kind: .smartErase)
        recorder.recordResidentBytes(nil)
        recorder.recordExit(status: 0, reason: .exit) // No launched child to confirm.
        var metrics = recorder.snapshot()
        XCTAssertNil(metrics.sampledPeakResidentBytes)
        XCTAssertEqual(metrics.residentSampleCount, 0)
        XCTAssertNil(metrics.childElapsedSeconds)
        XCTAssertFalse(metrics.childLaunched)
        XCTAssertFalse(metrics.childExitConfirmed)
        XCTAssertNil(metrics.childTerminationStatus)
        XCTAssertNil(metrics.childTerminationReason)
        XCTAssertEqual(metrics.temporaryDirectoryCleanup, .notNeeded)
        recorder.willCreateTemporaryDirectory()
        XCTAssertEqual(recorder.snapshot().temporaryDirectoryCleanup, .unconfirmed)
        recorder.recordCleanup(confirmed: false)
        metrics = recorder.snapshot()
        XCTAssertEqual(metrics.temporaryDirectoryCleanup, .failed)
        XCTAssertEqual(metrics.configuredResidentLimitBytes, 2_147_483_648)
    }

    func testZeroIsARealSampleAndClockAnomaliesRemainJSONEncodable() throws {
        let clock = InferenceMetricsClock(10)
        let recorder = LocalInferenceJobRecorder(kind: .table, clock: { clock.value })
        recorder.recordLaunch(); recorder.recordResidentBytes(0)
        clock.set(5)
        XCTAssertEqual(recorder.snapshot().elapsedSeconds, 0)
        clock.set(.infinity)
        recorder.recordExit(status: 0, reason: .exit)
        let metrics = recorder.snapshot()
        XCTAssertEqual(metrics.sampledPeakResidentBytes, 0)
        XCTAssertEqual(metrics.residentSampleCount, 1)
        XCTAssertEqual(metrics.elapsedSeconds, 0)
        XCTAssertEqual(metrics.childElapsedSeconds, 0)
        XCTAssertNoThrow(try JSONEncoder().encode(metrics))
    }

    func testOnlyThreeLatestContentFreeRecordsSurviveRepeatedJobs() async throws {
        let resources = LocalInferenceResources()
        for index in 0..<300 {
            _ = try await resources.withJob(LocalInferenceJobKind.allCases[index % 3]) { recorder in
                recorder.recordLaunch()
                recorder.recordResidentBytes(UInt64(index))
                recorder.recordExit(status: 0, reason: .exit)
                recorder.willCreateTemporaryDirectory(); recorder.recordCleanup(confirmed: true)
                return index
            }
        }
        let snapshot = resources.snapshot()
        XCTAssertNil(snapshot.activeJob)
        XCTAssertEqual(snapshot.lastJobs.map(\.kind), [.formula, .table, .smartErase])
        XCTAssertEqual(snapshot.lastJobs.map(\.sampledPeakResidentBytes), [297, 298, 299])
        XCTAssertTrue(snapshot.lastJobs.allSatisfy { $0.residentSampleCount == 1 })
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertLessThan(encoded.count, 4_096)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["lastJobs"])
        let jobs = try XCTUnwrap(object["lastJobs"] as? [[String: Any]])
        let allowed: Set<String> = ["kind", "outcome", "elapsedSeconds", "childElapsedSeconds",
            "sampledPeakResidentBytes", "residentSampleCount", "residentSampleIntervalSeconds",
            "configuredResidentLimitBytes", "configuredWallLimitSeconds", "childLaunched",
            "childExitConfirmed", "childTerminationStatus", "childTerminationReason", "temporaryDirectoryCleanup"]
        for job in jobs { XCTAssertEqual(Set(job.keys), allowed) }
    }

    func testExitZeroWithInvalidPostprocessedOutputIsAFailedJob() async throws {
        let resources = LocalInferenceResources()
        do {
            _ = try await resources.withJob(.formula) { recorder in
                recorder.recordLaunch()
                recorder.recordExit(status: 0, reason: .exit)
                recorder.willCreateTemporaryDirectory(); recorder.recordCleanup(confirmed: true)
                // Matches the service contract: decode stays inside withJob,
                // after child exit/cleanup but before success is recorded.
                return try JSONDecoder().decode(InferenceDecodedFixture.self, from: Data("invalid-json".utf8))
            }
            XCTFail("Invalid output must fail even if the helper exited zero")
        } catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertNil(resources.snapshot().activeJob)
        let last = try XCTUnwrap(resources.snapshot().lastJobs.first)
        XCTAssertEqual(last.outcome, .failed)
        XCTAssertEqual(last.childTerminationStatus, 0)
        XCTAssertTrue(last.childExitConfirmed)
        XCTAssertEqual(last.temporaryDirectoryCleanup, .confirmed)
    }

    func testPrivateErrorMessageNeverEntersTelemetry() async throws {
        let resources = LocalInferenceResources()
        let secret = "private-image-text /Users/private/person/input.png secret model path"
        do {
            _ = try await resources.withJob(.formula) { _ -> Int in throw InferenceMetricsPrivateError(detail: secret) }
            XCTFail("Fixture should fail")
        } catch { /* The caller still receives the error; diagnostics don't retain it. */ }
        let data = try JSONEncoder().encode(resources.snapshot())
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains(secret))
        for fragment in ["private-image", "/Users/", "input.png", "model path", "detail"] {
            XCTAssertFalse(encoded.contains(fragment))
        }
        XCTAssertEqual(resources.snapshot().lastJobs.first?.outcome, .failed)
    }

    func testSnapshotsCannotBeMutatedByAStaleRecorder() throws {
        let resources = LocalInferenceResources()
        let lease = try resources.acquire(.formula)
        lease.recorder.recordLaunch(); lease.recorder.recordResidentBytes(10)
        lease.recorder.recordExit(status: 0, reason: .exit)
        XCTAssertTrue(resources.complete(lease))
        let before = resources.snapshot()
        lease.recorder.recordOutcome(.memoryLimit)
        lease.recorder.recordCleanup(confirmed: false)
        XCTAssertFalse(resources.complete(lease))
        XCTAssertEqual(resources.snapshot(), before)
    }

    func testCleanupVerificationRequiresActualAbsenceIncludingBrokenSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("picshot-resource-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        let link = root.appendingPathComponent("dangling")
        XCTAssertFalse(LocalInferenceResources.removalIsConfirmed(at: root))
        XCTAssertTrue(LocalInferenceResources.removalIsConfirmed(at: missing))
        try fm.createSymbolicLink(at: link, withDestinationURL: missing)
        XCTAssertFalse(LocalInferenceResources.removalIsConfirmed(at: link))
        try fm.removeItem(at: link)
        XCTAssertTrue(LocalInferenceResources.removalIsConfirmed(at: link))
    }
}

private struct InferenceMetricsPrivateError: Error { let detail: String }
private final class InferenceMetricsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ time: TimeInterval) { self.time = time }
    func set(_ value: TimeInterval) { lock.lock(); defer { lock.unlock() }; time = value }
    var value: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
}

private struct InferenceDecodedFixture: Decodable { let value: Int }
