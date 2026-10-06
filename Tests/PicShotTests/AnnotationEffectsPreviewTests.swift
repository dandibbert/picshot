import XCTest
import AppKit
import ImageIO
@testable import PicShot

final class AnnotationEffectsPreviewTests: XCTestCase {
    @MainActor
    func testNativePreviewProducesBoundedEvidenceAndCanRunAgainWithoutOwnedWindows() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.frame.width >= 760, screen.frame.height >= 600 else {
            throw XCTSkip("The native AppKit preview needs a WindowServer display of at least 760 by 600 points")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-effects-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalAppearance = NSApp.appearance
        let originalVisibleWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        var firstHashes: [String: String] = [:]
        for iteration in 0..<2 {
            let directory = root.appendingPathComponent("run-\(iteration)", isDirectory: true)
            let result = try await AnnotationEffectsPreviewFixture.verify(evidenceDirectory: directory)
            XCTAssertEqual(result["status"] as? String, "passed")
            XCTAssertEqual(result["syntheticDesktop"] as? Bool, true)
            XCTAssertEqual(result["sourcePixelsPerPoint"] as? Int, 1)
            XCTAssertEqual(result["snapshotPixelsPerPoint"] as? Int, 1)
            XCTAssertEqual(result["maximumConcurrentOwnedEditors"] as? Int, 1)
            XCTAssertEqual(result["maximumFixtureRasterPixels"] as? Int, 4_000_000)
            XCTAssertEqual(result["originalRasterPreserved"] as? Bool, true)
            XCTAssertEqual(result["allOwnedEditorsClosed"] as? Bool, true)
            XCTAssertEqual(result["completedChecks"] as? [String], ["eraser", "spotlight", "watermark", "magnifier"])
            for key in ["screenCaptureAttempted", "audioCaptureAttempted", "cameraCaptureAttempted", "ocrInferenceAttempted", "networkAttempted", "preferencesWritten"] {
                XCTAssertEqual(result[key] as? Bool, false, key)
            }
            for name in ["eraser", "spotlight", "watermark", "magnifier"] {
                let section = try XCTUnwrap(result[name] as? [String: Any], name)
                XCTAssertEqual(section["nativeSaveCallbackCount"] as? Int, 1, name)
                XCTAssertEqual(section["nativeCancelPreservedInput"] as? Bool, true, name)
                XCTAssertEqual(section["ownedWindowDetachedOnClose"] as? Bool, true, name)
                let hash = try XCTUnwrap(section["flattenedSHA256"] as? String, name)
                XCTAssertEqual(hash.count, 64)
                if iteration == 0 { firstHashes[name] = hash }
                else { XCTAssertEqual(hash, firstHashes[name], "Repeated original fixture produced different \(name) pixels") }
            }
            let eraser = try XCTUnwrap(result["eraser"] as? [String: Any])
            XCTAssertEqual(eraser["committedAnnotationCount"] as? Int, 4)
            for key in ["brushAndRectangleNativeGestures", "escapePreservesRedo", "twoUndoRedoCyclesPixelIdentical", "oneUndoStatePerGesture", "clearUndoRedoPreservesBase", "laterInkSurvives"] {
                XCTAssertEqual(eraser[key] as? Bool, true, key)
            }
            let magnifier = try XCTUnwrap(result["magnifier"] as? [String: Any])
            for key in ["independentSourceAndLensDrag", "escapePreservesRedo", "cancelledLensDragPreservesPixels", "redactionAddedAfterLensStaysOpaque", "hidingOrdinaryMarksKeepsRedactionOpaque", "ordinaryInkToggleChangesLens", "privacyToggleUndoRedoPixelIdentical"] {
                XCTAssertEqual(magnifier[key] as? Bool, true, key)
            }
            let files = try XCTUnwrap(result["files"] as? [String])
            XCTAssertEqual(files.count, 13)
            XCTAssertEqual(Set(files).count, files.count)
            let desktopWidth = try XCTUnwrap(result["desktopPixelWidth"] as? Int)
            let desktopHeight = try XCTUnwrap(result["desktopPixelHeight"] as? Int)
            let cropWidth = try XCTUnwrap(result["resultPixelWidth"] as? Int)
            let cropHeight = try XCTUnwrap(result["resultPixelHeight"] as? Int)
            for name in files where name.hasSuffix(".png") {
                let url = directory.appendingPathComponent(name)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), name)
                XCTAssertEqual(CGImageSourceGetCount(source), 1, "Flattened evidence must be a single raster")
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), name)
                XCTAssertEqual(image.width, name.hasPrefix("ui-") ? desktopWidth : cropWidth, name)
                XCTAssertEqual(image.height, name.hasPrefix("ui-") ? desktopHeight : cropHeight, name)
                XCTAssertLessThanOrEqual(image.width * image.height, 4_000_000)
                XCTAssertGreaterThan(try Data(contentsOf: url).count, 1_024, "Expected meaningful native UI/result pixels for \(name)")
            }
            let reportURL = directory.appendingPathComponent("annotation-effects-preview.json")
            let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
            XCTAssertEqual(persisted["status"] as? String, "passed")
            XCTAssertEqual(persisted["files"] as? [String], files)
            XCTAssertTrue(NSApp.appearance === originalAppearance, "Native fixture must restore the caller's app appearance")
            let remaining = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            XCTAssertTrue(remaining.subtracting(originalVisibleWindows).isEmpty, "Fixture left an owned editor visible")
        }
    }

    @MainActor
    func testUnwritableEvidenceDestinationFailsBeforeOpeningNativeUI() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-effects-not-directory-\(UUID().uuidString)")
        let original = Data("existing file must remain untouched".utf8)
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let appearance = NSApp.appearance
        let windows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        var rejected = false
        do { _ = try await AnnotationEffectsPreviewFixture.verify(evidenceDirectory: file) }
        catch { rejected = true }
        XCTAssertTrue(rejected, "A regular file cannot be used as the evidence directory")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(NSApp.appearance === appearance)
        XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)), windows)
    }
}
