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
        let report: [String: Any]
        do { report = try await RecordingCompositionSmokeFixture.verify(evidenceDirectory: directory, profile: .quickTest) }
        catch {
            let url = directory.appendingPathComponent("recording-composition.json")
            if let data = try? String(contentsOf: url, encoding: .utf8) {
                print("Recording smoke failure evidence: \(data.prefix(32_768))")
            }
            throw error
        }
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["profile"] as? String, "unit-test-recording-composition")
        XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
        let finalCleanup = try XCTUnwrap(report["rootCleanupDisposition"] as? String)
        XCTAssertTrue(["empty-root-rmdir-and-lstat-confirmed", "empty-root-already-absent-lstat-confirmed"].contains(finalCleanup),
                      "verify() itself must exercise the checked final-root path")
        XCTAssertEqual(report["completedMeasuredCycles"] as? Int, 2)
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

    func testCleanupAcceptsMissingOwnedRootOnlyAfterExactAbsenceCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Recording-Composition-Cleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("synthetic.txt")
        try Data([1, 2, 3]).write(to: child)
        // An ENOENT for some descendant must never count as root cleanup.
        XCTAssertThrowsError(try RecordingCompositionSmokeFixture.removeOwnedFixtureDirectory(root, remover: { _ in
            throw CocoaError(.fileNoSuchFile)
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
        XCTAssertEqual(try RecordingCompositionSmokeFixture.removeOwnedFixtureDirectory(root),
                       "removed-and-absence-confirmed-by-lstat")
        XCTAssertEqual(try RecordingCompositionSmokeFixture.removeOwnedFixtureDirectory(root),
                       "already-absent-confirmed-by-lstat")
        // Even with an absent root, an unrelated permissions/I/O failure is not
        // silently reclassified as a successful FileManager removal.
        XCTAssertThrowsError(try RecordingCompositionSmokeFixture.removeOwnedFixtureDirectory(root, remover: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }))
    }

    func testFinalRootRemovalRequiresEmptyDirectoryAndConfirmsAbsence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Recording-Composition-EmptyRoot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("leftover.txt")
        try Data([1]).write(to: child)
        XCTAssertThrowsError(try RecordingCompositionSmokeFixture.removeOwnedEmptyRoot(root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
        try FileManager.default.removeItem(at: child)
        XCTAssertEqual(try RecordingCompositionSmokeFixture.removeOwnedEmptyRoot(root), "empty-root-rmdir-and-lstat-confirmed")
        XCTAssertEqual(try RecordingCompositionSmokeFixture.removeOwnedEmptyRoot(root), "empty-root-already-absent-lstat-confirmed")
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
