import XCTest
import AppKit
import ImageIO
@testable import PicShot

final class AnnotationTextLinePreviewTests: XCTestCase {
    @MainActor
    func testNativeLightDarkEdgeFixtureExportsPixelsAndReleasesOwnedUI() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.frame.width >= 760, screen.frame.height >= 600 else {
            throw XCTSkip("Native text/line styles fixture requires a 760 by 600 point WindowServer")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-text-line-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appearance = NSApp.appearance, windows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let report = try await AnnotationTextLinePreviewFixture.verify(evidenceDirectory: root)
        XCTAssertEqual(report["status"] as? String, "passed")
        for key in ["syntheticDesktop", "originalRasterPreserved", "allOwnedEditorsClosed"] { XCTAssertEqual(report[key] as? Bool, true, key) }
        for key in ["screenCaptureAttempted", "networkAttempted", "preferencesWritten", "generalPasteboardUsed"] { XCTAssertEqual(report[key] as? Bool, false, key) }
        let themes = try XCTUnwrap(report["themes"] as? [[String: Any]])
        XCTAssertEqual(themes.compactMap { $0["appearance"] as? String }, ["light", "dark"])
        XCTAssertEqual(themes[0]["flattenedSHA256"] as? String, themes[1]["flattenedSHA256"] as? String, "Appearance must not recolor committed model pixels")
        for theme in themes {
            let line = try XCTUnwrap(theme["line"] as? [String: Any])
            for key in ["nativeEndpointAndStrokeControls", "draftExcludedFromExport", "translucentLineCompositedOnce", "twoUndoRedoCyclesPixelIdentical", "cancelledDraftPreservesCommittedPath", "selectedHeadEditChangesPixels", "cancelledVertexDragPreservesRedo"] { XCTAssertEqual(line[key] as? Bool, true, key) }
            XCTAssertEqual(line["committedPointCount"] as? Int, 4)
            let text = try XCTUnwrap(theme["text"] as? [String: Any])
            for key in ["nativeMultilingualInlineInput", "independentOutlineAndBackground", "inlineTypingAndExistingTextOutline", "inlineInspectorUsesCurrentStyle", "continuedEditPreservesIdentityAndRotation", "cancelledTextAndStylePreservesRedo", "twoUndoRedoCyclesPixelIdentical"] { XCTAssertEqual(text[key] as? Bool, true, key) }
        }
        let edges = try XCTUnwrap(report["edges"] as? [[String: Any]])
        XCTAssertEqual(edges.count, 4)
        for edge in edges {
            for key in ["frozenImageAnchored", "paletteInsideWorkspace", "requiredControlsInsidePalette", "toolbarPaletteDoNotOverlap"] { XCTAssertEqual(edge[key] as? Bool, true, key) }
        }
        for section in themes + edges {
            for key in ["pngRoundtripPixelIdentical", "nativeCancelPreservedInput", "ownedWindowDetachedOnClose", "pendingPathReleasedOnClose", "presentationCacheReleasedOnClose"] { XCTAssertEqual(section[key] as? Bool, true, key) }
            XCTAssertEqual(section["nativeSaveCallbackCount"] as? Int, 1)
            XCTAssertEqual((section["flattenedSHA256"] as? String)?.count, 64)
        }
        let files = try XCTUnwrap(report["files"] as? [String]); XCTAssertEqual(files.count, 17); XCTAssertEqual(Set(files).count, 17)
        for file in files where file.hasSuffix(".png") {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent(file) as CFURL, nil), file)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file)
            XCTAssertLessThanOrEqual(image.width * image.height, 4_000_000)
            if file.hasPrefix("ui-") { XCTAssertEqual(image.width, 760); XCTAssertEqual(image.height, 600) }
        }
        XCTAssertTrue(NSApp.appearance === appearance)
        XCTAssertTrue(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)).subtracting(windows).isEmpty)
    }

    @MainActor
    func testInvalidDestinationLeavesExistingFileAndWindowsUnchanged() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-text-line-invalid-\(UUID().uuidString)")
        let original = Data("do not replace".utf8); try original.write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let windows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        do { _ = try await AnnotationTextLinePreviewFixture.verify(evidenceDirectory: root); XCTFail("A regular file cannot receive fixture evidence") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: root), original)
        XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)), windows)
    }

    @MainActor
    func testInlineOutlineScalesWithFontAtZoomAndDisablesWithoutLosingInput() throws {
        _ = NSApplication.shared
        var mark = ImageAnnotation(tool: .text, points: [.zero], text: "世界 العربية\nWrap")
        mark.fontSize = 24; mark.textOutlineEnabled = true; mark.textOutlineWidth = 3
        for zoom in [CGFloat(0.5), 1, 2] {
            let box = InlineAnnotationTextBox(frame: CGRect(x: 0, y: 0, width: 220, height: 100), annotation: mark, zoom: zoom)
            XCTAssertEqual(box.input.font?.pointSize, 24 * zoom)
            XCTAssertEqual((box.input.typingAttributes[.strokeWidth] as? NSNumber)?.doubleValue ?? 0, -12.5, accuracy: 0.001)
            XCTAssertNotNil(box.input.textStorage?.attribute(.strokeColor, at: 0, effectiveRange: nil))
            var plain = mark; plain.textOutlineEnabled = false
            box.applyStyle(plain, zoom: zoom)
            XCTAssertEqual(box.input.string, mark.text)
            XCTAssertNil(box.input.typingAttributes[.strokeWidth])
            XCTAssertNil(box.input.textStorage?.attribute(.strokeColor, at: 0, effectiveRange: nil))
            XCTAssertFalse(box.input.drawsBackground)
        }
    }
}
