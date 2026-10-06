import XCTest
import AppKit
import ImageIO
@testable import PicShot

final class AnnotationPathsPreviewTests: XCTestCase {
    @MainActor
    func testNativeFixtureRepeatsDeterministicallyAndReleasesOwnedUI() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.frame.width >= 760, screen.frame.height >= 600 else {
            throw XCTSkip("Native annotation paths fixture needs a 760 by 600 point WindowServer display")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-paths-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appearance = NSApp.appearance, windows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        var hashes: [String: String] = [:]
        for iteration in 0..<2 {
            let directory = root.appendingPathComponent("run-\(iteration)", isDirectory: true)
            let report = try await AnnotationPathsPreviewFixture.verify(evidenceDirectory: directory)
            XCTAssertEqual(report["status"] as? String, "passed")
            for key in ["syntheticDesktop", "originalRasterPreserved", "allOwnedEditorsClosed"] { XCTAssertEqual(report[key] as? Bool, true, key) }
            for key in ["screenCaptureAttempted", "audioCaptureAttempted", "cameraCaptureAttempted", "ocrInferenceAttempted", "networkAttempted", "preferencesWritten"] {
                XCTAssertEqual(report[key] as? Bool, false, key)
            }
            XCTAssertEqual(report["maximumConcurrentOwnedEditors"] as? Int, 1)
            XCTAssertEqual(report["maximumFixtureRasterPixels"] as? Int, 4_000_000)
            XCTAssertEqual(report["maximumPolylinePoints"] as? Int, 256)
            XCTAssertEqual(report["completedChecks"] as? [String], ["arcs", "polyline", "pointLimit", "edgePlacement"])
            let arcs = try XCTUnwrap(report["arcs"] as? [String: Any])
            for key in ["nativeSubtoolsReachable", "openArcHasNoRadialFill", "sectorFillMatchesAnglePixels", "twoUndoRedoCyclesPixelIdentical",
                        "rotatedEndpointKeepsOppositeFixed", "cancelledAngleDragPreservesRedo", "negativeSweepEditable"] {
                XCTAssertEqual(arcs[key] as? Bool, true, key)
            }
            let polyline = try XCTUnwrap(report["polyline"] as? [String: Any])
            for key in ["nativeSubtoolsReachable", "draftExcludedFromExport", "backspaceAndCommandZRemoveOneVertex", "doubleClickNoDuplicateVertex",
                        "returnAndFinishButtonCommit", "cancelAndToolSwitchDiscardDraft", "twoUndoRedoCyclesPixelIdentical", "escapePreservesRedo",
                        "rotatedVertexKeepsOthersFixed", "cancelledVertexDragPreservesRedo", "dashStyleUndoRedoPixelIdentical"] {
                XCTAssertEqual(polyline[key] as? Bool, true, key)
            }
            XCTAssertEqual(polyline["committedPointCount"] as? Int, 4)
            let bound = try XCTUnwrap(report["pointLimit"] as? [String: Any])
            XCTAssertEqual(bound["nativePointLimitAutoFinish"] as? Bool, true)
            XCTAssertEqual(bound["singleUndoState"] as? Bool, true); XCTAssertEqual(bound["committedPointCount"] as? Int, 256)
            let edges = try XCTUnwrap(report["edges"] as? [[String: Any]])
            XCTAssertEqual(edges.compactMap { $0["edge"] as? String }, ["top-left", "top-right", "bottom-left", "bottom-right"])
            for edge in edges {
                for key in ["frozenImageAnchored", "paletteInsideWorkspace", "toolbarPaletteDoNotOverlap"] { XCTAssertEqual(edge[key] as? Bool, true, key) }
            }
            for section in [arcs, polyline, bound] + edges {
                for key in ["nativeCancelPreservedInput", "ownedWindowDetachedOnClose", "pendingPathReleasedOnClose", "presentationCacheReleasedOnClose"] {
                    XCTAssertEqual(section[key] as? Bool, true, key)
                }
                XCTAssertEqual(section["nativeSaveCallbackCount"] as? Int, 1)
                let file = try XCTUnwrap(section["resultFile"] as? String), hash = try XCTUnwrap(section["flattenedSHA256"] as? String)
                XCTAssertEqual(hash.count, 64)
                if iteration == 0 { hashes[file] = hash } else { XCTAssertEqual(hash, hashes[file], file) }
            }
            let files = try XCTUnwrap(report["files"] as? [String]); XCTAssertEqual(files.count, 15); XCTAssertEqual(Set(files).count, 15)
            for filename in files where filename.hasSuffix(".png") {
                let url = directory.appendingPathComponent(filename)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), filename)
                XCTAssertEqual(CGImageSourceGetCount(source), 1)
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), filename)
                let width = filename.hasPrefix("ui-") ? report["desktopPixelWidth"] as? Int :
                    (filename.contains("path-edge-") ? 180 : report["resultPixelWidth"] as? Int)
                let height = filename.hasPrefix("ui-") ? report["desktopPixelHeight"] as? Int :
                    (filename.contains("path-edge-") ? 120 : report["resultPixelHeight"] as? Int)
                XCTAssertEqual(image.width, width, filename); XCTAssertEqual(image.height, height, filename)
                XCTAssertLessThanOrEqual(image.width * image.height, 4_000_000)
            }
            let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("annotation-paths-preview.json"))) as? [String: Any])
            XCTAssertEqual(persisted["status"] as? String, "passed"); XCTAssertEqual(persisted["files"] as? [String], files)
            XCTAssertTrue(NSApp.appearance === appearance)
            XCTAssertTrue(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)).subtracting(windows).isEmpty)
        }
    }

    @MainActor
    func testInvalidEvidenceDestinationDoesNotOpenWindows() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-paths-not-directory-\(UUID().uuidString)")
        let original = Data("leave this file intact".utf8); try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let windows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        do { _ = try await AnnotationPathsPreviewFixture.verify(evidenceDirectory: file); XCTFail("A regular file is not an evidence directory") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)), windows)
    }
}
