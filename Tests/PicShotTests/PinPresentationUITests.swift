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

    @MainActor func testSpaceUsesSingleSharedEditorAndClosingPinReleasesIt() async throws {
        _ = NSApplication.shared
        // NSWindowController creation, responder events, and close all participate in
        // AppKit's event-scoped autorelease lifetime. Keep every borrow in this pool.
        let probes = try autoreleasepool { () throws -> [ClosedAuxiliaryWindowProbe] in
            let controller = PinController(image: try raster())
            let pinProbe = try ClosedAuxiliaryWindowProbe(controller)
            let content = try XCTUnwrap(controller.window?.contentView)
            let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }.first)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            scroll.documentView?.keyDown(with: event)
            let editor = try XCTUnwrap(controller.annotationEditor)
            let editorProbe = try ClosedAuxiliaryWindowProbe(editor)
            controller.showAnnotations(); XCTAssertTrue(controller.annotationEditor === editor)
            editor.close(); XCTAssertNil(controller.annotationEditor)
            editorProbe.assertDetached()
            controller.showAnnotations()
            let replacement = try XCTUnwrap(controller.annotationEditor)
            XCTAssertFalse(replacement === editor)
            let replacementProbe = try ClosedAuxiliaryWindowProbe(replacement)
            controller.close()
            XCTAssertNil(controller.annotationEditor)
            for probe in [pinProbe, replacementProbe] { probe.assertDetached() }
            controller.close() // Repeated dismissal must not reinstall any callbacks.
            return [pinProbe, editorProbe, replacementProbe]
        }
        for probe in probes { try await probe.assertReleased() }
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

/// Shared by the pin/OCR UI tests. Keeping a closed window strongly alive models
/// AppKit's window cache; it must not retain its controller or former content graph.
@MainActor final class ClosedAuxiliaryWindowProbe {
    weak var controller: NSWindowController?
    weak var content: NSView?
    let window: NSWindow

    init(_ controller: NSWindowController) throws {
        self.controller = controller
        window = try XCTUnwrap(controller.window)
        content = window.contentView
    }

    func assertDetached(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(window.contentView, "Close must detach the content synchronously", file: file, line: line)
        XCTAssertNil(window.delegate, "Close must detach its delegate synchronously", file: file, line: line)
        XCTAssertFalse(window.isVisible, file: file, line: line)
    }

    func assertReleased(file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !autoreleasepool(invoking: { controller == nil && content == nil }),
              ProcessInfo.processInfo.systemUptime < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(controller, "Closed controller retained after scoped pools and bounded main-run-loop drain", file: file, line: line)
        XCTAssertNil(content, "Closed window retained its former content/view graph", file: file, line: line)
        assertDetached(file: file, line: line)
    }
}
