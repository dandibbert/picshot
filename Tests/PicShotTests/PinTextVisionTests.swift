import XCTest
import AppKit
@testable import PicShot

final class PinTextVisionTests: XCTestCase {
    @MainActor func testActualAppleVisionReturnsBoundedWordAndLineGeometry() async throws {
        let image = try PinTextSelectionSmokeFixture.visionRaster()
        let result = try await RecognitionService.recognize(image)
        let document = try XCTUnwrap(result.document)
        XCTAssertTrue(result.text.lowercased().contains("capture"), result.text)
        XCTAssertGreaterThanOrEqual(document.lines.count, 2)
        XCTAssertGreaterThanOrEqual(document.units.count, 3)
        XCTAssertEqual(document.text, result.text); XCTAssertFalse(document.isTruncated)
        for unit in document.units {
            XCTAssertFalse(document.substring(unit.range).isEmpty)
            XCTAssertTrue(document.boundaries.contains(unit.range.location))
            XCTAssertTrue(document.boundaries.contains(NSMaxRange(unit.range)))
            XCTAssertTrue(document.lines.indices.contains(unit.lineIndex))
            for point in unit.quad.points {
                XCTAssertTrue((0...1).contains(point.x)); XCTAssertTrue((0...1).contains(point.y))
            }
        }
        // This fixture establishes the local Vision integration, not real-world multilingual accuracy.
    }
    @MainActor func testImageOrientationReturnsGeometryInOrientedRasterCoordinates() async throws {
        let image = try PinTextSelectionSmokeFixture.visionRaster()
        let rotated = try XCTUnwrap(PinImageRenderer.render(image: image, transform: .rotateCounterclockwise))
        let upright = try await RecognitionService.recognize(image)
        let corrected = try await RecognitionService.recognize(rotated, options: RecognitionOptions(orientation: .right))
        XCTAssertTrue(corrected.text.lowercased().contains("capture"), corrected.text)
        let a = try XCTUnwrap(upright.document?.lines.first?.quad.bounds)
        let b = try XCTUnwrap(corrected.document?.lines.first?.quad.bounds)
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.025); XCTAssertEqual(a.minY, b.minY, accuracy: 0.025)
        XCTAssertEqual(a.width, b.width, accuracy: 0.025); XCTAssertEqual(a.height, b.height, accuracy: 0.025)
    }
    @MainActor func testCancellationReleasesVisionAdmissionAndReportsCancellation() async throws {
        let image = try PinTextSelectionSmokeFixture.visionRaster()
        let baseline = await RecognitionService.resourceSnapshot()
        let task = Task { try await RecognitionService.recognize(image) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        let after = await RecognitionService.resourceSnapshot()
        XCTAssertEqual(after.activeJobs, baseline.activeJobs)
        XCTAssertEqual(after.waitingJobs, baseline.waitingJobs)
    }
}
