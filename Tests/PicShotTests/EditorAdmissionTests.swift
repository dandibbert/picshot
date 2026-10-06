import AppKit
import XCTest
@testable import PicShot

final class EditorAdmissionTests: XCTestCase {
    func testRasterIdentityIsCountedOnceAndFreshCacheIsReserved() throws {
        let image = try raster(8, 8)
        let bytes = image.bytesPerRow * image.height
        XCTAssertEqual(EditorRasterEstimate.retainedBytes([image, image, image]), bytes)
        XCTAssertEqual(EditorRasterEstimate.openingBytes(image: image, presentation: nil), bytes + 8 * 8 * 4)
    }

    @MainActor
    func testCurrentHistoryCacheAndFrozenRasterAccounting() throws {
        _ = NSApplication.shared
        let image = try raster(8, 8), frozen = try raster(16, 16)
        let presentation = FrozenCapturePresentation(frozenImage: frozen, displayID: 0,
            displayFrame: CGRect(x: 0, y: 0, width: 16, height: 16),
            selectionFrame: CGRect(x: 0, y: 0, width: 8, height: 8))
        let editor = ImageEditorController(image: image, presentation: presentation, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        defer { editor.close() }
        let base = EditorRasterEstimate.openingBytes(image: image, presentation: presentation)
        XCTAssertEqual(editor.estimatedAdmissionRasterBytes, base)
        // Repeated annotation snapshots share the original raster.
        for _ in 0..<4 { editor.setVerificationAnnotations([]) }
        XCTAssertEqual(editor.estimatedAdmissionRasterBytes, base)
        let replacement = try raster(4, 4)
        editor.annotationCanvas.setContent(image: replacement, annotations: [])
        let expected = EditorRasterEstimate.retainedBytes([image, replacement, frozen]) + 4 * 4 * 4
        XCTAssertEqual(editor.estimatedAdmissionRasterBytes, expected)
        let preview = try XCTUnwrap(editor.annotationCanvas.rasterForBoundaryPreview())
        editor.captureBoundaryWorkspace.boundaryPreviewImage = preview
        XCTAssertEqual(editor.estimatedAdmissionRasterBytes,
            EditorRasterEstimate.retainedBytes([image, replacement, frozen, preview]))
    }

    @MainActor
    func testCloseStateChangesOnlyOnActualClose() throws {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: try raster(8, 8), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil)
        XCTAssertFalse(editor.isClosed)
        editor.window?.orderOut(nil)
        XCTAssertFalse(editor.isClosed, "Hiding a window must not discard unfinished edits or admission")
        var closes = 0; editor.onClose = { closes += 1 }
        editor.close()
        XCTAssertTrue(editor.isClosed); XCTAssertEqual(closes, 1)
    }

    private func raster(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}
