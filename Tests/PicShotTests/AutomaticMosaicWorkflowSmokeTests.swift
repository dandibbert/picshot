import XCTest
import AppKit
import Darwin
import PicShotCore
@testable import PicShot

@MainActor final class AutomaticMosaicWorkflowSmokeTests: XCTestCase {
    func testAuthoredNamesIconsColorAlphaUseActualMatcherAndKeepSourceBytes() async throws {
        let image = try AutomaticMosaicWorkflowSmokeFixture.authoredRaster()
        let before = try XCTUnwrap(image.dataProvider?.data) as Data
        let region = AutomaticMosaicWorkflowSmokeFixture.authoredRegions[0]
        let matcher = AutomaticMosaicMatcher()
        let result = try await matcher.findMatches(in: image, seed: RepeatedRegionPixelRect(
            x: Int(region.minX), y: Int(region.minY), width: Int(region.width), height: Int(region.height)))
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertFalse(result.truncated)
        for expected in AutomaticMosaicWorkflowSmokeFixture.authoredRegions.dropFirst() {
            XCTAssertEqual(result.candidates.filter {
                $0.rect.x == Int(expected.minX) && $0.rect.y == Int(expected.minY) &&
                    $0.rect.width == Int(expected.width) && $0.rect.height == Int(expected.height)
            }.count, 1)
        }
        let nonmatch = AutomaticMosaicWorkflowSmokeFixture.nearNonmatch
        XCTAssertFalse(result.candidates.contains { $0.rect.x == Int(nonmatch.minX) && $0.rect.y == Int(nonmatch.minY) })
        XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, before)
        XCTAssertTrue(stride(from: 3, to: before.count, by: 4).contains { before[$0] < 255 }, "Alpha case disappeared")
    }

    func testNativeWorkflowUsesReviewControlsExportsAndStaleActualCallbacks() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Requires native WindowServer; no capture or Accessibility permissions requested") }
        let evidence = try makeEvidenceDirectory(test: "native-workflow")
        let directory = evidence.url
        var reachedEnd = false
        defer { finishEvidence(evidence, reachedEnd: reachedEnd) }
        let report = try await AutomaticMosaicWorkflowSmokeFixture.verify(evidenceDirectory: directory, includeResourceCycles: false)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["sourceByteIdentityVerified"] as? Bool, true)
        XCTAssertEqual(report["generalPasteboardReadOrWritten"] as? Bool, false)
        let controls = try XCTUnwrap(report["controls"] as? [String: Any])
        XCTAssertEqual(controls["staleCallbacksRejected"] as? Int, 4)
        XCTAssertEqual(controls["edgePlacements"] as? [String], ["top-left", "top-right", "bottom-left", "bottom-right"])
        let resources = try XCTUnwrap(report["resourceEvidence"] as? [String: Any])
        XCTAssertEqual(resources["status"] as? String, "not-run")
        let exports = try XCTUnwrap(report["exports"] as? [[String: Any]])
        XCTAssertEqual(exports.count, 4)
        XCTAssertTrue(exports.allSatisfy { ($0["exteriorMismatches"] as? Int) == 0 })
        reachedEnd = true
    }

    func testFailureDiagnosticsKeepCurrentModeCountersAndOnlyFirstExteriorMismatch() throws {
        let evidence = try makeEvidenceDirectory(test: "failure-diagnostics")
        let directory = evidence.url
        var reachedEnd = false
        defer { finishEvidence(evidence, reachedEnd: reachedEnd) }
        let diagnostics = AutomaticMosaicWorkflowDiagnostics(directory: directory)
        diagnostics.beginMode("blur")
        diagnostics.record("export-pixel-validation")
        let before = Data([11, 22, 33, 44, 55, 66, 77, 88]), after = Data([12, 23, 34, 45, 56, 67, 78, 89])
        diagnostics.observeExteriorMismatch(x: 7, y: 9, offset: 4, before: before, after: after)
        diagnostics.observeExteriorMismatch(x: 8, y: 9, offset: 0, before: before, after: after)
        diagnostics.recordExportCounters(matched: 10, exterior: 20, changed: 3, mismatches: 2, inspectedAllPixels: true)
        diagnostics.fail(NSError(domain: "MosaicDiagnosticTest", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Original pixel assertion failure"]))

        let report = try diagnosticReport(in: directory)
        XCTAssertEqual(report["status"] as? String, "failed")
        XCTAssertEqual(report["observationalOnly"] as? Bool, true)
        XCTAssertEqual(report["currentMode"] as? String, "blur")
        XCTAssertEqual(report["currentPhase"] as? String, "export-pixel-validation")
        XCTAssertEqual(report["failure"] as? String, "Original pixel assertion failure")
        let counters = try XCTUnwrap(report["exportCounters"] as? [String: Any])
        XCTAssertEqual(counters["matchedPixelsChecked"] as? Int, 10)
        XCTAssertEqual(counters["exteriorPixelsChecked"] as? Int, 20)
        XCTAssertEqual(counters["changedMatchedPixels"] as? Int, 3)
        XCTAssertEqual(counters["exteriorMismatches"] as? Int, 2)
        XCTAssertEqual(counters["inspectedAllPixels"] as? Bool, true)
        let mismatch = try XCTUnwrap(report["firstExteriorMismatch"] as? [String: Any])
        XCTAssertEqual(mismatch["x"] as? Int, 7)
        XCTAssertEqual(mismatch["y"] as? Int, 9)
        XCTAssertEqual(mismatch["beforeRGBA"] as? [Int], [55, 66, 77, 88])
        XCTAssertEqual(mismatch["afterRGBA"] as? [Int], [56, 67, 78, 89])

        diagnostics.beginMode("pixelate")
        let nextMode = try diagnosticReport(in: directory)
        XCTAssertEqual(nextMode["currentMode"] as? String, "pixelate")
        XCTAssertNil(nextMode["exportCounters"])
        XCTAssertNil(nextMode["firstExteriorMismatch"])
        reachedEnd = true
    }

    func testDiagnosticPhasesArePersistedBeforeFailureAndBounded() throws {
        let evidence = try makeEvidenceDirectory(test: "bounded-phases")
        let directory = evidence.url
        var reachedEnd = false
        defer { finishEvidence(evidence, reachedEnd: reachedEnd) }
        let diagnostics = AutomaticMosaicWorkflowDiagnostics(directory: directory)
        let count = AutomaticMosaicWorkflowDiagnostics.maximumPhases + 3
        for index in 0..<count { diagnostics.record("phase-\(index)") }
        let report = try diagnosticReport(in: directory)
        XCTAssertEqual(report["status"] as? String, "running")
        XCTAssertEqual(report["omittedEarlierPhases"] as? Int, 3)
        let phases = try XCTUnwrap(report["phases"] as? [[String: Any]])
        XCTAssertEqual(phases.count, AutomaticMosaicWorkflowDiagnostics.maximumPhases)
        XCTAssertEqual(phases.first?["phase"] as? String, "phase-3")
        XCTAssertEqual(phases.last?["phase"] as? String, "phase-\(count - 1)")
        for phase in phases {
            let timestamp = try XCTUnwrap(phase["timestampUTC"] as? String)
            XCTAssertNotNil(ISO8601DateFormatter().date(from: timestamp))
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(phase["elapsedSeconds"] as? Double), 0)
        }
        let data = try Data(contentsOf: directory.appendingPathComponent(AutomaticMosaicWorkflowDiagnostics.filename))
        XCTAssertLessThan(data.count, 32 * 1024)
        reachedEnd = true
    }

    private struct EvidenceDirectory {
        let url: URL
        let descriptor: Int32
    }

    private func makeEvidenceDirectory(test: String) throws -> EvidenceDirectory {
        let root: URL
        if let path = ProcessInfo.processInfo.environment["PICSHOT_TEST_EVIDENCE_ROOT"] {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else {
                throw NSError(domain: "AutomaticMosaicXCTestEvidence", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "PICSHOT_TEST_EVIDENCE_ROOT must be an absolute directory path"])
            }
            root = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else {
            root = FileManager.default.temporaryDirectory
        }
        // mkdtemp creates a new private child exclusively; never adopt a root or
        // another test's directory. Write there directly so crashes retain evidence.
        var template = Array(root.appendingPathComponent("PicShot-Mosaic-\(test)-XXXXXX").path.utf8CString)
        guard template.withUnsafeMutableBufferPointer({ Darwin.mkdtemp($0.baseAddress!) != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let url = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return EvidenceDirectory(url: url, descriptor: descriptor)
    }

    private func finishEvidence(_ evidence: EvidenceDirectory, reachedEnd: Bool) {
        defer { Darwin.close(evidence.descriptor) }
        guard reachedEnd && testRun?.failureCount == 0 else {
            print("Automatic mosaic XCTest evidence retained at: \(evidence.url.path)")
            return
        }
        var owned = stat(), current = stat()
        guard fstat(evidence.descriptor, &owned) == 0,
              lstat(evidence.url.path, &current) == 0,
              owned.st_dev == current.st_dev, owned.st_ino == current.st_ino else {
            print("Automatic mosaic XCTest cleanup refused a changed directory: \(evidence.url.path)")
            return
        }
        // Only these ten fixture outputs are owned. Never enumerate, recursively
        // delete, follow output symlinks, or remove the supplied evidence root.
        let files = ["automatic-mosaic-input.png", "automatic-mosaic-review-light.png",
                     "automatic-mosaic-review-dark.png", "automatic-mosaic-edge.png",
                     "automatic-mosaic-redact.png", "automatic-mosaic-redact-excluded.png",
                     "automatic-mosaic-blur.png", "automatic-mosaic-pixelate.png",
                     "automatic-mosaic-workflow.json", AutomaticMosaicWorkflowDiagnostics.filename]
        for name in files { _ = unlinkat(evidence.descriptor, name, 0) }
        if Darwin.rmdir(evidence.url.path) != 0 {
            print("Automatic mosaic XCTest cleanup left unremoved files at: \(evidence.url.path)")
        }
    }

    private func diagnosticReport(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(AutomaticMosaicWorkflowDiagnostics.filename))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
