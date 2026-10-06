import XCTest
import Foundation
@testable import PicShot

@MainActor
final class RecordingCompositionSmokeTests: XCTestCase {
    func testInstalledProfileIsFixedShortAndSeparateFromQuickTest() {
        let installed = RecordingCompositionSmokeFixture.Profile.installedSmoke
        XCTAssertEqual(installed.width, 640); XCTAssertEqual(installed.height, 360)
        XCTAssertEqual(installed.cameraWidth, 160); XCTAssertEqual(installed.cameraHeight, 120)
        XCTAssertEqual(installed.frameRate, 10); XCTAssertEqual(installed.encodedFrames, 7)
        XCTAssertEqual(installed.duration, 0.7, accuracy: 0.0001)
        XCTAssertEqual(installed.warmupCycles, 1); XCTAssertEqual(installed.measuredCycles, 3)
        let quick = RecordingCompositionSmokeFixture.Profile.quickTest
        XCTAssertEqual(quick.width, 320); XCTAssertEqual(quick.height, 180)
        XCTAssertEqual(quick.measuredCycles, 2); XCTAssertNotEqual(quick.name, installed.name)
    }

    /// Real production H.264 compositor/writer and decoder, with a distinct small
    /// profile. No ScreenCaptureKit stream, capture device, window or event input.
    func testQuickFixtureVerifiesMediaCleanupAndWritesNativeEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Composition-Smoke-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await RecordingCompositionSmokeFixture.verify(evidenceDirectory: directory, profile: .quickTest)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["profile"] as? String, "unit-test-recording-composition")
        XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
        for key in ["screenCaptureStarted", "cameraCaptureStarted", "microphoneStarted", "permissionRequested"] {
            XCTAssertEqual(report[key] as? Bool, false, key)
        }
        XCTAssertEqual(report["windowsCreated"] as? Int, 0)
        XCTAssertEqual(report["inputEventsPosted"] as? Int, 0)
        XCTAssertEqual(report["controllerCreationCount"] as? Int, 3)
        XCTAssertEqual(report["controllerReleaseCount"] as? Int, 3)
        XCTAssertEqual(report["pipelineReleaseCount"] as? Int, 3)
        let runs = try XCTUnwrap(report["cycles"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 2)
        for run in runs {
            XCTAssertEqual(run["status"] as? String, "passed")
            XCTAssertEqual(run["decodedFrames"] as? Int, 7)
            XCTAssertGreaterThan(try XCTUnwrap(run["decodedPixelChecks"] as? Int), 30)
            XCTAssertEqual(run["writerRetainedFrameReferencesAtFinish"] as? Int, 0)
            XCTAssertEqual(run["cameraSlotsAtCleanup"] as? Int, 0)
            XCTAssertEqual(run["liveTrackedObjectsAfterRelease"] as? Int, 0)
            XCTAssertEqual(run["temporaryFilesRemaining"] as? Int, 0)
            XCTAssertEqual(run["postStopMutationExcluded"] as? Bool, true)
            let timing = try XCTUnwrap(run["storedPacketTiming"] as? [String: Any])
            XCTAssertEqual(timing["packets"] as? Int, 7)
            XCTAssertEqual(timing["adjacent"] as? Bool, true)
            let memory = try XCTUnwrap(run["sampledMemory"] as? [String: Any])
            XCTAssertGreaterThan(try XCTUnwrap(memory["residentSampleCount"] as? Int), 0)
        }
        let expected: Set<String> = ["recording-composition.json", "recording-composition.mp4", "recording-composition.png"]
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), expected)
        let json = try Data(contentsOf: directory.appendingPathComponent("recording-composition.json"))
        XCTAssertLessThan(json.count, 128 * 1_024)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(stored["status"] as? String, "passed")
        for file in ["recording-composition.mp4", "recording-composition.png"] {
            let bytes = try directory.appendingPathComponent(file).resourceValues(forKeys: [.fileSizeKey]).fileSize
            XCTAssertGreaterThan(try XCTUnwrap(bytes), 0)
            XCTAssertLessThanOrEqual(try XCTUnwrap(bytes), 4 * 1_024 * 1_024)
        }
    }

    func testRejectsUnrecognizedProfileBeforeWritingOrCapturing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Composition-Invalid-" + UUID().uuidString)
        let invalid = RecordingCompositionSmokeFixture.Profile(name: "unbounded", width: 10_000, height: 10_000, measuredCycles: 200)
        do {
            _ = try await RecordingCompositionSmokeFixture.verify(evidenceDirectory: directory, profile: invalid)
            XCTFail("Invalid smoke profile should be rejected")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
