import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class LiveScrollCaptureControlsTests: XCTestCase {
    private let screen = CGRect(x: -1_280, y: -100, width: 1_280, height: 800)
    private let target = CGRect(x: -1_000, y: 140, width: 540, height: 400)
    private var active: LiveScrollCaptureSnapshot {
        LiveScrollCaptureSnapshot(pixelWidth: 1_080, pixelHeight: 2_740, acceptedFrames: 4,
                                  canFinish: true, canCopy: true, canAutoScroll: true)
    }

    func testPanelsStayNonactivatingAndOutlineAndThumbnailAreClickThrough() throws {
        _ = NSApplication.shared
        let previousKey = NSApp.keyWindow
        let controller = LiveScrollCaptureController(actions: .init())
        defer { controller.teardown() }
        controller.show(snapshot: active, targetFrame: target, visibleFrame: screen)
        XCTAssertTrue(NSApp.keyWindow === previousKey)
        let toolbar = try XCTUnwrap(controller.toolbarWindow)
        let outline = try XCTUnwrap(controller.outlineWindow)
        let preview = try XCTUnwrap(controller.previewWindow)
        for window in [toolbar, outline, preview] {
            XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain)
            XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
            XCTAssertEqual(window.sharingType, .none)
            XCTAssertFalse(window.isMovableByWindowBackground)
        }
        XCTAssertFalse(toolbar.ignoresMouseEvents)
        XCTAssertTrue(outline.ignoresMouseEvents); XCTAssertTrue(preview.ignoresMouseEvents)
        XCTAssertEqual(outline.frame, target.insetBy(dx: -3, dy: -3))
        XCTAssertNil(outline.contentView?.hitTest(CGPoint(x: 20, y: 20)))
        XCTAssertNil(preview.contentView?.hitTest(CGPoint(x: 20, y: 20)))
        XCTAssertEqual(controller.captureExcludedWindowIDs.count, 3)
    }

    func testPausedAndRecoverableFailureKeepFinishCopyCancelAndRetryUsable() throws {
        _ = NSApplication.shared
        var finish = 0, copy = 0, pause = 0, cancel = 0, close = 0
        let controller = LiveScrollCaptureController(actions: .init(finishEdit: { finish += 1 }, copy: { copy += 1 },
            pauseResume: { pause += 1 }, cancel: { cancel += 1 }, onClose: { close += 1 }))
        defer { controller.teardown() }
        controller.show(snapshot: active, targetFrame: target, visibleFrame: screen)
        let view = try XCTUnwrap(controller.toolbarWindow?.contentView as? LiveScrollToolbarView)
        let initialFrame = controller.toolbarWindow?.frame
        view.pauseButton.performClick(nil)
        XCTAssertEqual(pause, 1)
        var state = active; state.paused = true; state.statusKind = .paused; state.status = "已暂停 · 可移动选区"
        controller.update(snapshot: state)
        XCTAssertEqual(view.pauseButton.accessibilityLabel(), "继续捕获")
        XCTAssertEqual(view.statusLabel.textColor, .systemOrange)
        view.copyButton.performClick(nil); view.finishButton.performClick(nil)
        state.statusKind = .error; state.status = "未能匹配 · 回滚少许后重试"
        controller.update(snapshot: state)
        XCTAssertEqual(view.pauseButton.accessibilityLabel(), "重试捕获")
        XCTAssertEqual(view.statusLabel.textColor, .systemRed)
        view.pauseButton.performClick(nil); view.copyButton.performClick(nil); view.finishButton.performClick(nil)
        XCTAssertEqual(pause, 2); XCTAssertEqual(copy, 2); XCTAssertEqual(finish, 2)
        XCTAssertEqual(controller.toolbarWindow?.frame, initialFrame)
        state.busy = true; controller.update(snapshot: state)
        XCTAssertFalse(view.pauseButton.isEnabled)
        XCTAssertTrue(view.copyButton.isEnabled); XCTAssertTrue(view.finishButton.isEnabled); XCTAssertTrue(view.cancelButton.isEnabled)
        view.cancelButton.performClick(nil); view.cancelButton.performClick(nil); controller.close()
        XCTAssertEqual(cancel, 1); XCTAssertEqual(close, 0)
    }

    func testMoreMenuUsesOwnerStateAndMoveWorksDuringCaptureAndPause() throws {
        _ = NSApplication.shared
        var moves = 0, reverse: Bool?, axis: ScrollAxis?, imports = 0, help = 0
        let controller = LiveScrollCaptureController(actions: .init(changeAxis: { axis = $0 }, reverseCrop: { reverse = $0 },
            moveRegion: { moves += 1 }, importImages: { imports += 1 }, help: { help += 1 }))
        defer { controller.teardown() }
        controller.show(snapshot: active, targetFrame: target, visibleFrame: screen)
        let view = try XCTUnwrap(controller.toolbarWindow?.contentView as? LiveScrollToolbarView)
        func invoke(_ suffix: String) throws {
            let menu = try XCTUnwrap(view.moreButton.menu)
            let index = try XCTUnwrap(menu.items.firstIndex { $0.identifier?.rawValue == "scroll.live." + suffix })
            XCTAssertTrue(menu.items[index].isEnabled)
            menu.performActionForItem(at: index)
        }
        XCTAssertFalse(controller.snapshot.reverseCrop)
        let originalMenu = try XCTUnwrap(view.moreButton.menu)
        XCTAssertFalse(originalMenu.items.contains { $0.identifier?.rawValue == "scroll.live.reverseCrop" })
        var state = active; state.showsReverseCrop = true
        controller.update(snapshot: state)
        XCTAssertTrue(view.moreButton.menu === originalMenu)
        try invoke("moveRegion"); XCTAssertEqual(moves, 1)
        try invoke("reverseCrop"); XCTAssertEqual(reverse, true)
        try invoke("axis.horizontal"); XCTAssertEqual(axis, .horizontal)
        try invoke("import"); try invoke("help")
        XCTAssertEqual(imports, 1); XCTAssertEqual(help, 1)
        state.paused = true; controller.update(snapshot: state)
        try invoke("moveRegion"); XCTAssertEqual(moves, 2)
        state.busy = true; controller.update(snapshot: state)
        for id in ["moveRegion", "reverseCrop", "axis.horizontal", "import"] {
            XCTAssertFalse(try XCTUnwrap(view.moreButton.menu?.items.first { $0.identifier?.rawValue == "scroll.live." + id }).isEnabled)
        }
        try invoke("help"); XCTAssertEqual(help, 2)
        state.showsReverseCrop = false; controller.update(snapshot: state)
        XCTAssertTrue(view.moreButton.menu === originalMenu)
        XCTAssertFalse(originalMenu.items.contains { $0.identifier?.rawValue == "scroll.live.reverseCrop" })
    }

    func testBothToolbarLayoutsHaveFullNativeHitTargetsAndNoOverlaps() throws {
        _ = NSApplication.shared
        let controller = LiveScrollCaptureController(actions: .init())
        defer { controller.teardown() }
        for size in [LiveScrollCaptureGeometry.toolbarSize, LiveScrollCaptureGeometry.compactToolbarSize] {
            let workArea = CGRect(x: -600, y: -200, width: size.width, height: 600)
            controller.show(snapshot: active, targetFrame: workArea, visibleFrame: workArea)
            let view = try XCTUnwrap(controller.toolbarWindow?.contentView as? LiveScrollToolbarView)
            view.layoutSubtreeIfNeeded()
            var frames: [CGRect] = []
            for control in [view.finishButton, view.copyButton, view.pauseButton, view.autoButton,
                            view.moreButton, view.cancelButton] as [NSControl] {
                let frame = control.frame
                XCTAssertGreaterThanOrEqual(frame.width, 34); XCTAssertEqual(frame.height, 34)
                XCTAssertTrue(view.bounds.contains(frame)); XCTAssertFalse(frames.contains { $0.intersects(frame) })
                XCTAssertFalse(frame.intersects(view.dimensionLabel.frame)); XCTAssertFalse(frame.intersects(view.statusLabel.frame))
                let point = view.convert(CGPoint(x: frame.midX, y: frame.midY), to: view.superview)
                XCTAssertTrue(view.hitTest(point) === control)
                XCTAssertFalse(try XCTUnwrap(control.accessibilityLabel()).isEmpty)
                XCTAssertFalse(try XCTUnwrap(control.toolTip).isEmpty)
                frames.append(frame)
            }
        }
    }

    func testPreviewCopiesOnlyBoundedStorageAndUpdatesTheViewportAtBothEnds() throws {
        _ = NSApplication.shared
        let controller = LiveScrollCaptureController(actions: .init())
        defer { controller.teardown() }
        controller.show(snapshot: active, targetFrame: target, visibleFrame: screen)
        let preview = try XCTUnwrap(controller.previewWindow?.contentView as? LiveScrollThumbnailView)
        let source = try fixtureImage(width: 256, height: 4_096)
        controller.updatePreview(image: source, viewportFraction: CGRect(x: 0, y: 0, width: 1, height: 0.25))
        let first = try XCTUnwrap(preview.image)
        XCTAssertFalse(first === source)
        XCTAssertLessThanOrEqual(first.width * first.height, LiveScrollThumbnailView.maximumPixels)
        XCTAssertLessThanOrEqual(max(first.width, first.height), LiveScrollThumbnailView.maximumDimension)
        XCTAssertEqual(try XCTUnwrap(preview.viewportMarker).minY, preview.imageRect.minY)
        controller.updatePreview(image: source, viewportFraction: CGRect(x: 0, y: 0.75, width: 1, height: 0.25))
        XCTAssertEqual(try XCTUnwrap(preview.viewportMarker).maxY, preview.imageRect.maxY)
        controller.updatePreview(image: NSImage(cgImage: source, size: CGSize(width: 256, height: 4_096)),
                                 viewportFraction: CGRect(x: 0, y: 0.25, width: 1, height: 0.25))
        XCTAssertNotNil(preview.image)
        controller.updatePreview(image: nil as CGImage?, viewportFraction: .zero)
        XCTAssertNil(preview.image); XCTAssertNil(preview.viewportMarker)
    }

    func testHideAndTeardownNeverInvokeCloseOrDiscardAndOldControlsAreInert() throws {
        _ = NSApplication.shared
        var calls = 0
        let controller = LiveScrollCaptureController(actions: .init(finishEdit: { calls += 1 }, copy: { calls += 1 },
            pauseResume: { calls += 1 }, cancel: { calls += 1 }, onClose: { calls += 1 }))
        controller.show(snapshot: active, targetFrame: target, visibleFrame: screen)
        let view = try XCTUnwrap(controller.toolbarWindow?.contentView as? LiveScrollToolbarView)
        let preview = try XCTUnwrap(controller.previewWindow?.contentView as? LiveScrollThumbnailView)
        controller.updatePreview(image: try fixtureImage(width: 100, height: 200), viewportFraction: CGRect(x: 0, y: 0, width: 1, height: 1))
        controller.hide(); XCTAssertEqual(calls, 0)
        controller.teardown(); controller.teardown()
        view.finishButton.performClick(nil); view.copyButton.performClick(nil); view.cancelButton.performClick(nil)
        controller.close(); controller.cancel()
        XCTAssertEqual(calls, 0); XCTAssertNil(preview.image); XCTAssertNil(view.moreButton.menu)
        XCTAssertNil(controller.toolbarWindow); XCTAssertTrue(controller.captureExcludedWindowIDs.isEmpty)
        let closing = LiveScrollCaptureController(actions: .init(onClose: { calls += 1 }))
        closing.close(); closing.close(); closing.teardown()
        XCTAssertEqual(calls, 1)
    }

    private func fixtureImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
