import XCTest
import AppKit
@testable import PicShot

final class NumberedCalloutAcceptanceTests: XCTestCase {
    @MainActor
    func testNativeCalloutFixtureWritesCodableEvidenceAndReleasesOwnedWindows() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.frame.width >= 760, screen.frame.height >= 600 else {
            throw XCTSkip("Owned-window callout fixture needs a 760 × 600 WindowServer display")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-callout-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let evidence = try await NumberedCalloutAcceptanceFixture.verify(evidenceDirectory: directory)
        XCTAssertEqual(evidence.status, "passed"); XCTAssertEqual(evidence.checks.count, 12)
        XCTAssertTrue(evidence.checks.values.allSatisfy { $0 })
        XCTAssertEqual(evidence.closedControllerCount, 12); XCTAssertEqual(evidence.releasedControllerCount, 12)
        XCTAssertEqual(evidence.files.count, 9); XCTAssertEqual(evidence.exportedSHA256.count, 64)
        XCTAssertFalse(evidence.globalInputAttempted); XCTAssertFalse(evidence.screenCaptureAttempted)
        XCTAssertFalse(evidence.networkAttempted); XCTAssertFalse(evidence.generalPasteboardTouched); XCTAssertFalse(evidence.standardDefaultsWritten)
        for file in evidence.files { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)) }
        let saved = try JSONDecoder().decode(NumberedCalloutAcceptanceEvidence.self, from: Data(contentsOf: directory.appendingPathComponent("annotation-callouts.json")))
        XCTAssertEqual(saved.checks, evidence.checks); XCTAssertEqual(saved.files, evidence.files)
        XCTAssertTrue(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)).subtracting(original).isEmpty)
    }
}
