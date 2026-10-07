import XCTest
import AppKit
import ImageIO
@testable import PicShot

final class AnnotationFreehandPreviewTests: XCTestCase {
    @MainActor
    func testNativeFixtureRepeatsWithExactExportsAndReleasesOwnedUI() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.frame.width >= 760, screen.frame.height >= 600 else {
            throw XCTSkip("Native freehand fixture needs a 760 by 600 point WindowServer display")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-freehand-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appearance = NSApp.appearance, windows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        var hashes: [String: String] = [:]
        for iteration in 0..<2 {
            let directory = root.appendingPathComponent("run-\(iteration)", isDirectory: true)
            let report = try await AnnotationFreehandPreviewFixture.verify(evidenceDirectory: directory)
            XCTAssertEqual(report["status"] as? String, "passed")
            for key in ["syntheticDesktop", "originalRasterPreserved", "allOwnedEditorsClosed"] { XCTAssertEqual(report[key] as? Bool, true, key) }
            for key in ["screenCaptureAttempted", "networkAttempted", "preferencesWritten", "pasteboardAccessed"] { XCTAssertEqual(report[key] as? Bool, false, key) }
            XCTAssertEqual(report["completedChecks"] as? [String], ["pencil", "highlighter", "pointLimit", "edgePlacement"])
            XCTAssertEqual(report["maximumGesturePoints"] as? Int, 2_048)
            XCTAssertEqual(report["maximumConcurrentOwnedEditors"] as? Int, 1)
            XCTAssertEqual(report["maximumFixtureRasterPixels"] as? Int, 4_000_000)
            let pencil = try XCTUnwrap(report["pencil"] as? [String: Any])
            for key in ["nativeControlsReachable", "previewMatchesCommittedPixels", "draftExcludedFromExport", "repeatReleaseNoDuplicate",
                        "twoUndoRedoCyclesPixelIdentical", "escapePreservesRedo", "toolSwitchDiscardsDraft", "midStrokeShiftStraight",
                        "mouseUpEndpointPreserved", "singlePointAndTinyMarksVisible", "selectedSmoothingUndoRedoExact"] { XCTAssertEqual(pencil[key] as? Bool, true, key) }
            let highlighter = try XCTUnwrap(report["highlighter"] as? [String: Any])
            for key in ["nativeControlsReachable", "freehandAndRectangleReachable", "blendChangesDarkPixels", "selectedBlendUndoRedoExact", "rectangleHidesStrokeOnlyControls"] {
                XCTAssertEqual(highlighter[key] as? Bool, true, key)
            }
            let limit = try XCTUnwrap(report["pointLimit"] as? [String: Any])
            XCTAssertLessThanOrEqual(try XCTUnwrap(limit["retainedPointCount"] as? Int), 2_048)
            let edges = try XCTUnwrap(report["edges"] as? [[String: Any]])
            XCTAssertEqual(edges.compactMap { $0["edge"] as? String }, ["top-left", "top-right", "bottom-left", "bottom-right"])
            for result in [pencil, highlighter, limit] + edges {
                for key in ["pngRoundTripExact", "nativeCancelPreservedInput", "ownedWindowDetachedOnClose", "pendingStrokeReleasedOnClose", "presentationCacheReleasedOnClose"] {
                    XCTAssertEqual(result[key] as? Bool, true, key)
                }
                XCTAssertEqual(result["nativeSaveCallbackCount"] as? Int, 1)
                let name = try XCTUnwrap(result["resultFile"] as? String), hash = try XCTUnwrap(result["flattenedSHA256"] as? String)
                if iteration == 0 { hashes[name] = hash } else { XCTAssertEqual(hash, hashes[name], name) }
            }
            let files = try XCTUnwrap(report["files"] as? [String]); XCTAssertEqual(files.count, 14); XCTAssertEqual(Set(files).count, 14)
            for name in files where name.hasSuffix(".png") {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil), name)
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), name)
                XCTAssertLessThanOrEqual(image.width * image.height, 4_000_000)
            }
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("annotation-freehand-preview.json"))) as? [String: Any])
            XCTAssertEqual(saved["status"] as? String, "passed")
            XCTAssertTrue(NSApp.appearance === appearance)
            XCTAssertTrue(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)).subtracting(windows).isEmpty)
        }
    }

    @MainActor
    func testInvalidEvidenceDirectoryDoesNotOpenWindows() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-freehand-invalid-\(UUID().uuidString)")
        let original = Data("preserve".utf8); try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let windows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        do { _ = try await AnnotationFreehandPreviewFixture.verify(evidenceDirectory: file); XCTFail("Regular file is not an evidence directory") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)), windows)
    }
}
