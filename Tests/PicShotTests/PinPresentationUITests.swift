import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class PinPresentationUITests: XCTestCase {
    @MainActor func testIdlePinContainsOnlyImageAndUsesContextualActions() throws {
        _ = NSApplication.shared
        let controller = PinController(image: try raster()); defer { controller.close() }
        let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
        XCTAssertFalse(window.styleMask.contains(.titled)); XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.hasShadow); XCTAssertEqual(window.frame.size, NSSize(width: 320, height: 180))
        XCTAssertFalse(descendants(content).contains { $0 is NSButton || $0 is NSTextField || $0 is NSSlider })
        let menu = try XCTUnwrap(controller.actionMenu)
        for title in ["识别", "图像处理", "复制当前图像", "当前图像另存为…", "标注", "锁定", "关闭"] {
            XCTAssertNotNil(menu.item(withTitle: title), title)
        }
        XCTAssertNotNil(menu.item(withTitle: "图像处理")?.submenu?.item(withTitle: "不透明度")?.submenu)
        XCTAssertEqual(menu.item(withTitle: "标注")?.keyEquivalent, " ")
    }

    @MainActor func testContextualOpacityLockAndClickThroughStillRecover() throws {
        _ = NSApplication.shared
        let controller = PinController(image: try raster()); defer { controller.close() }
        let menu = try XCTUnwrap(controller.actionMenu)
        var writes = 0; controller.onPresentationChange = { _ in writes += 1 }
        try invoke(menu.item(withTitle: "图像处理")?.submenu?.item(withTitle: "不透明度")?.submenu?.item(withTitle: "40%"))
        try invoke(menu.item(withTitle: "锁定"))
        try invoke(menu.item(withTitle: "鼠标穿透（菜单栏恢复当前组）"))
        XCTAssertEqual(controller.presentation.opacity, 0.4, accuracy: 0.001)
        XCTAssertTrue(controller.presentation.locked); XCTAssertTrue(controller.presentation.clickThrough)
        XCTAssertFalse(controller.window?.styleMask.contains(.resizable) ?? true)
        controller.restore(screens: [CGRect(x: 0, y: 0, width: 1200, height: 900)])
        XCTAssertEqual(controller.presentation.opacity, 1); XCTAssertFalse(controller.presentation.clickThrough)
        XCTAssertTrue(controller.presentation.locked); XCTAssertGreaterThanOrEqual(writes, 4)
    }

    @MainActor func testSpaceUsesSingleSharedEditorAndClosingPinReleasesIt() throws {
        _ = NSApplication.shared
        var controller: PinController? = PinController(image: try raster())
        let content = try XCTUnwrap(controller?.window?.contentView)
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller?.window?.windowNumber ?? 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        scroll.documentView?.keyDown(with: event)
        weak var editor = controller?.annotationEditor
        XCTAssertNotNil(editor)
        controller?.showAnnotations(); XCTAssertTrue(controller?.annotationEditor === editor)
        editor?.close(); XCTAssertNil(controller?.annotationEditor)
        controller?.showAnnotations(); weak var replacement = controller?.annotationEditor
        XCTAssertNotNil(replacement)
        let window = controller?.window
        controller?.close(); controller = nil
        XCTAssertNil(replacement); XCTAssertNil(window?.contentView); XCTAssertNil(window?.delegate)
    }

    @MainActor func testFlattenedAnnotationPersistenceFailurePreservesOriginalAndCurrent() throws {
        _ = NSApplication.shared
        let original = try raster(), edited = try raster(width: 160, height: 90)
        let controller = PinController(image: original); defer { controller.close() }
        controller.onPixelChange = { _, _ in throw PicShotError.message("Disk full") }
        XCTAssertThrowsError(try controller.applyAnnotatedImage(edited))
        XCTAssertTrue(controller.currentImage === original); XCTAssertTrue(controller.image === original)
        var acceptedOriginal: Bool?
        controller.onPixelChange = { _, original in acceptedOriginal = original }
        try controller.applyAnnotatedImage(edited)
        XCTAssertEqual(acceptedOriginal, false); XCTAssertTrue(controller.currentImage === edited)
        try controller.restoreOriginalImage()
        XCTAssertEqual(acceptedOriginal, true); XCTAssertTrue(controller.currentImage === original)
    }

    @MainActor func testRichPinsKeepContentVisibleAndControlsContextual() throws {
        _ = NSApplication.shared
        let documents = [PinRichDocument(text: PinTextContent(text: "Compact text pin")),
                         PinRichDocument(files: [PinFileReference(path: "/tmp/example.txt", name: "example.txt", isDirectory: false)]),
                         PinRichDocument(color: try XCTUnwrap(PinRGBColor.parse("#006599")))]
        for document in documents {
            let prepared = try PreparedRichPin(document: document, title: "Pin")
            let controller = try RichPinController(asset: prepared.asset, data: prepared.data, title: "Pin")
            let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
            XCTAssertFalse(window.styleMask.contains(.titled))
            XCTAssertFalse(descendants(content).contains { $0 is NSButton || $0 is NSSlider })
            XCTAssertNotNil(content.menu?.item(withTitle: "不透明度")); XCTAssertNotNil(content.menu?.item(withTitle: "锁定"))
            XCTAssertLessThan(window.frame.height, 200)
            controller.close(); XCTAssertNil(window.contentView); XCTAssertNil(window.delegate)
        }
    }

    @MainActor private func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
    @MainActor private func invoke(_ optional: NSMenuItem?) throws {
        let item = try XCTUnwrap(optional), action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
    }
    private func raster(width: Int = 320, height: Int = 180) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height)); return try XCTUnwrap(context.makeImage())
    }
}
