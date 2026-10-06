import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class ScrollSequenceEditingTests: XCTestCase {
    func testInstalledFixtureExercisesBothAxesNativeCutsHandoffsAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Scroll-Tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await ScrollSequenceSmokeFixture.verify(evidenceDirectory: root)
        XCTAssertEqual(report["status"] as? String, "passed")
        let axes = try XCTUnwrap(report["axes"] as? [[String: Any]])
        XCTAssertEqual(axes.count, 2)
        XCTAssertTrue(axes.allSatisfy { ($0["temporaryDirectoryRemoved"] as? Bool) == true })
        for filename in ["scroll-sequence.json", "scroll-vertical-trim.png", "scroll-horizontal-trim.png",
                         "scroll-vertical-output.png", "scroll-horizontal-output.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(filename).path))
        }
    }

    func testLongPreviewStaysBoundedAndCloseReleasesSources() async throws {
        let controller = ScrollCaptureController { _ in }
        defer { controller.close() }
        try await controller.setAutoCropForVerification(false)
        for index in 0..<18 {
            _ = try await controller.acceptForVerification(ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100 + 80 * index), axis: .vertical)
        }
        let directory = try XCTUnwrap(controller.temporaryDirectoryForVerification)
        XCTAssertEqual(controller.sequenceForVerification?.blocks.count, 18)
        XCTAssertLessThanOrEqual(controller.previewPixelsForVerification, 640_000)
        XCTAssertEqual(controller.retainedGrayPixelsForVerification, 96 * 140)
        let before = controller.sourceURLsForVerification
        for offset in stride(from: 100 + 80 * 16, through: 100 + 80 * 8, by: -80) {
            let added = try await controller.acceptForVerification(ScrollSequenceSmokeFixture.image(axis: .vertical, offset: offset), axis: .vertical)
            XCTAssertFalse(added)
        }
        XCTAssertEqual(controller.sourceURLsForVerification, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 18)
        controller.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(controller.retainedGrayPixelsForVerification, 0)
        XCTAssertEqual(controller.previewPixelsForVerification, 0)
    }

    func testCanceledAcceptanceDoesNotCommitOrLeavePartialPNG() async throws {
        let controller = ScrollCaptureController { _ in }
        defer { controller.close() }
        _ = try await controller.acceptForVerification(ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100), axis: .vertical)
        let urls = controller.sourceURLsForVerification
        let image = try ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 140)
        let task = Task { @MainActor in try await controller.acceptForVerification(image, axis: .vertical) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled acceptance should throw") }
        catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error)") }
        XCTAssertEqual(controller.sourceURLsForVerification, urls)
        let directory = try XCTUnwrap(controller.temporaryDirectoryForVerification)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testOutputRasterBoundsRejectBeforeAllocation() {
        for (width, height) in [(Int.max, 1), (1, Int.max), (0, 10), (10_000, 6_001), (32_769, 10)] {
            XCTAssertThrowsError(try ScrollCaptureSequence.validateRaster(width: width, height: height))
        }
    }
}
