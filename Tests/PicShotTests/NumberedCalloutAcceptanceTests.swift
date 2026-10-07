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
        let lifecycle = try XCTUnwrap(evidence.commentLifecycle)
        XCTAssertEqual(lifecycle.contract, "owned-graph-prompt_native-input-deadline-v2")
        XCTAssertEqual(lifecycle.status, "passed"); XCTAssertEqual(lifecycle.cycles.count, 6)
        XCTAssertEqual(lifecycle.promptOwnershipCheckMilliseconds, 10)
        XCTAssertEqual(lifecycle.deferredInputDeadlineMilliseconds, 2000)
        XCTAssertEqual(lifecycle.finalDeferredInputs, 0); XCTAssertEqual(lifecycle.finalDeferredContexts, 0)
        XCTAssertTrue(lifecycle.cycles.allSatisfy { $0.requiredGraphTracked && $0.promptRetainedOwners == 0
            && $0.promptRetainedTextSystemObjects == 0 && ($0.releasedAfterMilliseconds ?? .infinity) <= 2000 })
        XCTAssertTrue(lifecycle.samples.allSatisfy { $0.retainedOwnedGraphObjects == 0 })
        XCTAssertEqual(evidence.files.count, 9); XCTAssertEqual(evidence.exportedSHA256.count, 64)
        XCTAssertFalse(evidence.globalInputAttempted); XCTAssertFalse(evidence.screenCaptureAttempted)
        XCTAssertFalse(evidence.networkAttempted); XCTAssertFalse(evidence.generalPasteboardTouched); XCTAssertFalse(evidence.standardDefaultsWritten)
        for file in evidence.files { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)) }
        let saved = try JSONDecoder().decode(NumberedCalloutAcceptanceEvidence.self, from: Data(contentsOf: directory.appendingPathComponent("annotation-callouts.json")))
        XCTAssertEqual(saved.checks, evidence.checks); XCTAssertEqual(saved.files, evidence.files)
        XCTAssertEqual(saved.commentLifecycle?.samples.count, lifecycle.samples.count)
        XCTAssertTrue(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)).subtracting(original).isEmpty)
    }
}
