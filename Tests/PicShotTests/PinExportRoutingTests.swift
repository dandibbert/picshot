import XCTest
import AppKit
@testable import PicShot

final class PinExportRoutingTests: XCTestCase {
    @MainActor func testCurrentAndOriginalPinExportUseSharedSnapshotAndCloseWithParent() async throws {
        _ = NSApplication.shared
        let original = try BarcodeAcceptanceFixture.nearMissRaster()
        let pin = PinController(image: original); defer { pin.close() }
        pin.bringForward(); try pin.cropImage(to: CGRect(x: 0, y: 0, width: 160, height: 100))
        let current = try XCTUnwrap(pin.actionMenu?.item(withTitle: "当前图像另存为…"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(current.action), to: current.target, from: current))
        let first = try XCTUnwrap(pin.imageExportController)
        XCTAssertTrue(first.window?.parent === pin.window)
        XCTAssertNil(first.window?.sheetParent)
        try await waitForPreview(first)
        XCTAssertEqual(first.latestArtifact?.width, 160); XCTAssertEqual(first.latestArtifact?.height, 100)
        try pin.applyTransform(.rotateClockwise)
        XCTAssertEqual(pin.currentImage.width, 160, "Pixel changes are blocked while an immutable export snapshot is open")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(current.action), to: current.target, from: current))
        XCTAssertTrue(pin.imageExportController === first, "Repeated save must not allocate another export session")
        first.cancelExport(); XCTAssertTrue(first.isClosed)
        let originalItem = try XCTUnwrap(pin.actionMenu?.item(withTitle: "原始图片")?.submenu?.item(withTitle: "原始图片另存为…"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(originalItem.action), to: originalItem.target, from: originalItem))
        let second = try XCTUnwrap(pin.imageExportController)
        XCTAssertFalse(second === first); try await waitForPreview(second)
        XCTAssertEqual(second.latestArtifact?.width, original.width); XCTAssertEqual(second.latestArtifact?.height, original.height)
        pin.close()
        XCTAssertTrue(second.isClosed); XCTAssertNil(pin.imageExportController); XCTAssertNil(pin.window?.contentView)
        XCTAssertNil(second.latestArtifact); XCTAssertNil(second.previewView.image)
    }
    @MainActor func testHidingPinCancelsPendingExportAndAllowsNextSave() throws {
        _ = NSApplication.shared
        let pin = PinController(image: try BarcodeAcceptanceFixture.nearMissRaster()); defer { pin.close() }
        pin.bringForward()
        let item = try XCTUnwrap(pin.actionMenu?.item(withTitle: "当前图像另存为…"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let exporting = try XCTUnwrap(pin.imageExportController)
        pin.hideTemporarily()
        XCTAssertTrue(exporting.isClosed); XCTAssertNil(pin.imageExportController)
        pin.bringForward()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertNotNil(pin.imageExportController); XCTAssertFalse(pin.imageExportController === exporting)
    }
    @MainActor private func waitForPreview(_ controller: ImageExportController) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while controller.latestArtifact == nil && !controller.isClosed && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(controller.latestArtifact, controller.statusLabel.stringValue)
    }
}
