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
        let handle = try XCTUnwrap(controller.handleWindow)
        for window in [toolbar, outline, preview, handle] {
            XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain)
            XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
            XCTAssertEqual(window.sharingType, .none)
            XCTAssertFalse(window.isMovableByWindowBackground)
        }
        XCTAssertFalse(toolbar.ignoresMouseEvents)
        XCTAssertFalse(handle.ignoresMouseEvents)
        XCTAssertTrue(screen.contains(handle.frame)); XCTAssertFalse(handle.frame.intersects(target))
        XCTAssertFalse(handle.frame.intersects(toolbar.frame)); XCTAssertFalse(handle.frame.intersects(preview.frame))
        XCTAssertTrue(outline.ignoresMouseEvents); XCTAssertTrue(preview.ignoresMouseEvents)
        XCTAssertEqual(outline.frame, target.insetBy(dx: -3, dy: -3))
        XCTAssertNil(outline.contentView?.hitTest(CGPoint(x: 20, y: 20)))
        XCTAssertNil(preview.contentView?.hitTest(CGPoint(x: 20, y: 20)))
        XCTAssertEqual(controller.captureExcludedWindowIDs.count, 4)

        let selections: [(String, CGRect, Bool)] = [
            ("lower-left corner", CGRect(x: screen.minX, y: screen.minY, width: target.width, height: target.height), true),
            ("lower-right corner", CGRect(x: screen.maxX - target.width, y: screen.minY, width: target.width, height: target.height), true),
            ("upper-left corner", CGRect(x: screen.minX, y: screen.maxY - target.height, width: target.width, height: target.height), true),
            ("upper-right corner", CGRect(x: screen.maxX - target.width, y: screen.maxY - target.height, width: target.width, height: target.height), true),
            ("wide with top edge free", CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - 80), true),
            ("wide with bottom edge free", CGRect(x: screen.minX, y: screen.minY + 80, width: screen.width, height: screen.height - 80), true),
            // The tall cases leave only a narrow outside lane. Its upper portion
            // holds the preview, so the old four-candidate search went inside.
            ("tall with right edge free", CGRect(x: screen.minX, y: screen.minY, width: screen.width - 80, height: screen.height), true),
            ("tall with left edge free", CGRect(x: screen.minX + 80, y: screen.minY, width: screen.width - 80, height: screen.height), true),
            ("full-screen fallback", screen, false)
        ]
        for (name, selection, hasOutsideSpace) in selections {
            controller.show(snapshot: active, targetFrame: selection, visibleFrame: screen)
            XCTAssertTrue(handle.isVisible, name)
            XCTAssertTrue(screen.contains(handle.frame), name)
            XCTAssertFalse(handle.frame.intersects(toolbar.frame), name)
            if preview.isVisible { XCTAssertFalse(handle.frame.intersects(preview.frame), name) }
            if hasOutsideSpace { XCTAssertFalse(handle.frame.intersects(selection), name) }
            else { XCTAssertTrue(handle.frame.intersects(selection), "Full-screen selection needs an honest inside fallback") }
            XCTAssertFalse(handle.canBecomeKey, name)
            XCTAssertTrue(NSApp.keyWindow === previousKey, name)
        }
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
        // Recovering a rejected move can leave an error explanation while the
        // source is running again. The actual button action is still Pause.
        state.paused = false; controller.update(snapshot: state)
        XCTAssertEqual(view.pauseButton.accessibilityLabel(), "暂停捕获")
        XCTAssertEqual(view.pauseButton.toolTip, "暂停捕获")
        XCTAssertEqual(view.statusLabel.textColor, .systemRed)
        XCTAssertEqual(view.statusLabel.stringValue, state.status)
        view.pauseButton.performClick(nil); XCTAssertEqual(pause, 3)
        state.paused = true; controller.update(snapshot: state)
        XCTAssertEqual(view.pauseButton.accessibilityLabel(), "重试捕获")
        XCTAssertEqual(view.pauseButton.toolTip, "重试捕获")
        XCTAssertEqual(controller.toolbarWindow?.frame, initialFrame)
        state.busy = true; controller.update(snapshot: state)
        XCTAssertFalse(view.pauseButton.isEnabled)
        XCTAssertFalse(view.copyButton.isEnabled); XCTAssertFalse(view.finishButton.isEnabled)
        XCTAssertTrue(view.cancelButton.isEnabled)
        view.copyButton.performClick(nil); view.finishButton.performClick(nil)
        XCTAssertEqual(copy, 2); XCTAssertEqual(finish, 2)
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
        XCTAssertNotNil(originalMenu.items.first?.image, "The actual More control must have its ellipsis image")
        XCTAssertTrue(originalMenu.items.contains { $0.identifier?.rawValue == "scroll.live.moveRegion" })
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

    func testDirectHandleNativeMouseEventsLockActiveAxisAndUseFinalReleasePosition() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            var ids: [UUID] = [], completions: [(UUID, CGRect?)] = []
            let controller = LiveScrollCaptureController(actions: .init(beginRegionDrag: { ids.append($0); return true },
                endRegionDrag: { completions.append(($0, $1)) }))
            defer { controller.teardown() }
            var state = active; state.axis = axis
            controller.show(snapshot: state, targetFrame: target, visibleFrame: screen)
            let handle = try XCTUnwrap(controller.handleWindow)
            let view = try XCTUnwrap(handle.contentView as? LiveScrollRegionDragHandle)
            let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
            let hit = view.convert(handle.convertPoint(fromScreen: start), from: nil)
            XCTAssertTrue(view.hitTest(view.convert(hit, to: view.superview)) === view)
            try pointer(.leftMouseDown, window: handle, global: start)
            XCTAssertEqual(ids.count, 1); XCTAssertTrue(view.isDragging)
            XCTAssertTrue(handle.canBecomeKey); XCTAssertTrue(handle.firstResponder === view)
            state.busy = true; state.canMoveRegion = false; controller.update(snapshot: state)
            XCTAssertTrue(view.isEnabled, "Busy capture preparation must not orphan an accepted drag")
            try pointer(.leftMouseDragged, window: handle, global: CGPoint(x: start.x + 20, y: start.y + 35))
            XCTAssertTrue(try XCTUnwrap(controller.toolbarWindow).isVisible)
            XCTAssertTrue(try XCTUnwrap(controller.previewWindow).isVisible)
            try pointer(.leftMouseUp, window: handle, global: CGPoint(x: start.x + 40, y: start.y + 60))
            let expected = target.offsetBy(dx: axis == .vertical ? 0 : 40, dy: axis == .horizontal ? 0 : 60)
            XCTAssertEqual(completions.count, 1); XCTAssertEqual(completions[0].0, ids[0])
            XCTAssertEqual(completions[0].1, expected)
            XCTAssertEqual(controller.outlineWindow?.frame, expected.insetBy(dx: -3, dy: -3))
            XCTAssertFalse(view.isDragging); XCTAssertFalse(handle.canBecomeKey)
            try pointer(.leftMouseUp, window: handle, global: start)
            try pointer(.leftMouseDragged, window: handle, global: start)
            controller.cancelRegionDrag()
            XCTAssertEqual(completions.count, 1, "Stray events cannot complete an accepted ID twice")
        }
    }

    func testDirectPausedDragClampsToCaptureBoundsWhileHUDStaysInVisibleWorkArea() throws {
        var completed: CGRect?
        let controller = LiveScrollCaptureController(actions: .init(beginRegionDrag: { _ in true },
            endRegionDrag: { _, frame in completed = frame }))
        defer { controller.teardown() }
        var state = active; state.paused = true
        let bounds = screen.insetBy(dx: 0, dy: -40)
        controller.show(snapshot: state, targetFrame: target, visibleFrame: screen, movementBounds: bounds)
        let handle = try XCTUnwrap(controller.handleWindow)
        let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
        try pointer(.leftMouseDown, window: handle, global: start)
        try pointer(.leftMouseDragged, window: handle, global: CGPoint(x: start.x + 9_000, y: start.y + 9_000))
        try pointer(.leftMouseUp, window: handle, global: CGPoint(x: start.x + 9_000, y: start.y + 9_000))
        XCTAssertEqual(completed, CGRect(x: bounds.maxX - target.width, y: bounds.maxY - target.height,
                                         width: target.width, height: target.height))
        XCTAssertTrue(screen.contains(try XCTUnwrap(controller.toolbarWindow).frame))
        XCTAssertTrue(screen.contains(handle.frame))
    }

    func testDirectDragEscapeAndFocusLossRestoreOriginalFrameAndCompleteOnce() throws {
        for escape in [true, false] {
            var ids: [UUID] = [], completions: [(UUID, CGRect?)] = []
            let controller = LiveScrollCaptureController(actions: .init(beginRegionDrag: { ids.append($0); return true },
                endRegionDrag: { completions.append(($0, $1)) }))
            defer { controller.teardown() }
            controller.show(snapshot: active, targetFrame: target, visibleFrame: screen)
            let handle = try XCTUnwrap(controller.handleWindow)
            let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
            try pointer(.leftMouseDown, window: handle, global: start)
            try pointer(.leftMouseDragged, window: handle, global: CGPoint(x: start.x, y: start.y + 60))
            XCTAssertNotEqual(controller.outlineWindow?.frame, target.insetBy(dx: -3, dy: -3))
            if escape {
                handle.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: handle.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
            } else {
                // Native focus transition invokes the actual NSWindowDelegate path.
                handle.resignKey()
            }
            XCTAssertEqual(completions.count, 1); XCTAssertEqual(completions.first?.0, ids.first)
            XCTAssertNil(completions.first?.1)
            XCTAssertEqual(controller.outlineWindow?.frame, target.insetBy(dx: -3, dy: -3))
            XCTAssertTrue(try XCTUnwrap(controller.toolbarWindow).isVisible)
            XCTAssertTrue(try XCTUnwrap(controller.previewWindow).isVisible)
            try pointer(.leftMouseUp, window: handle, global: start)
            controller.cancelRegionDrag(); controller.hide(); controller.teardown()
            XCTAssertEqual(completions.count, 1)
        }
    }

    func testDisabledOrRejectedHandleCannotStartDragAndRetiredHandleIsInert() throws {
        var begins = 0, ends = 0
        let controller = LiveScrollCaptureController(actions: .init(beginRegionDrag: { _ in begins += 1; return false },
            endRegionDrag: { _, _ in ends += 1 }))
        var state = active; state.busy = true
        controller.show(snapshot: state, targetFrame: target, visibleFrame: screen)
        let handle = try XCTUnwrap(controller.handleWindow)
        let view = try XCTUnwrap(handle.contentView as? LiveScrollRegionDragHandle)
        let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
        try pointer(.leftMouseDown, window: handle, global: start)
        XCTAssertEqual(begins, 0)
        state.busy = false; controller.update(snapshot: state)
        try pointer(.leftMouseDown, window: handle, global: start)
        try pointer(.leftMouseUp, window: handle, global: start)
        XCTAssertEqual(begins, 1); XCTAssertEqual(ends, 0); XCTAssertFalse(view.isDragging)
        controller.teardown()
        XCTAssertNil(view.begin); XCTAssertNil(view.move); XCTAssertNil(view.end)
        XCTAssertFalse(view.isEnabled); XCTAssertNil(controller.handleWindow)
    }

    func testStalePreviewRetainsLastGoodImageWithAmberAccessibleMarkerUntilVerified() throws {
        let controller = LiveScrollCaptureController(actions: .init(beginRegionDrag: { _ in true }))
        defer { controller.teardown() }
        var state = active; state.previewPositionVerified = true
        controller.show(snapshot: state, targetFrame: target, visibleFrame: screen)
        let preview = try XCTUnwrap(controller.previewWindow?.contentView as? LiveScrollThumbnailView)
        let fraction = CGRect(x: 0, y: 0.3, width: 1, height: 0.25)
        controller.updatePreview(image: try fixtureImage(width: 256, height: 1_024), viewportFraction: fraction)
        let original = try XCTUnwrap(preview.image)
        XCTAssertTrue(preview.isPositionVerified); XCTAssertEqual(preview.viewportMarkerColor, .systemGreen)
        state.previewPositionVerified = false; state.statusKind = .warning
        controller.update(snapshot: state)
        XCTAssertTrue(preview.image === original); assertViewport(preview.viewportFraction, equals: fraction)
        XCTAssertFalse(preview.isPositionVerified); XCTAssertEqual(preview.viewportMarkerColor, .systemOrange)
        XCTAssertTrue(try XCTUnwrap(preview.accessibilityLabel()).contains("尚未验证"))
        XCTAssertFalse(try XCTUnwrap(preview.accessibilityLabel()).contains("绿色"))
        // Failed allocation/invalid NSImage dimensions must not erase good pixels
        // or relabel them as verified even if a stale verified snapshot arrives.
        controller.updatePreview(image: NSImage(size: .zero), viewportFraction: .zero)
        state.previewPositionVerified = true; controller.update(snapshot: state)
        XCTAssertTrue(preview.image === original); XCTAssertFalse(preview.isPositionVerified)
        controller.updatePreview(image: try fixtureImage(width: 256, height: 1_024), viewportFraction: fraction)
        XCTAssertTrue(preview.isPositionVerified)
        let handle = try XCTUnwrap(controller.handleWindow)
        for cancel in [true, false] {
            let beforeDrag = try XCTUnwrap(preview.image)
            let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
            try pointer(.leftMouseDown, window: handle, global: start)
            let acceptedFraction = CGRect(x: 0, y: 0.5, width: 1, height: 0.3)
            controller.updatePreview(image: try fixtureImage(width: 512, height: 800), viewportFraction: acceptedFraction)
            controller.update(snapshot: state)
            let accepted = try XCTUnwrap(preview.image)
            XCTAssertFalse(accepted === beforeDrag, "An accepted pre-drain observation must keep its corresponding preview")
            assertViewport(preview.viewportFraction, equals: acceptedFraction)
            XCTAssertFalse(preview.isPositionVerified, "An in-flight drag cannot verify even the latest accepted position")
            XCTAssertEqual(preview.viewportMarkerColor, .systemOrange)

            let latestFraction = CGRect(x: 0, y: 0.6, width: 1, height: 0.25)
            let source = try fixtureImage(width: 256, height: 800)
            controller.updatePreview(image: NSImage(cgImage: source, size: CGSize(width: 256, height: 800)),
                                     viewportFraction: latestFraction)
            controller.update(snapshot: state)
            let latest = try XCTUnwrap(preview.image)
            XCTAssertFalse(latest === accepted)
            assertViewport(preview.viewportFraction, equals: latestFraction)
            XCTAssertFalse(preview.isPositionVerified)
            XCTAssertTrue(try XCTUnwrap(preview.accessibilityLabel()).contains("尚未验证"))

            if cancel { controller.cancelRegionDrag() }
            else { try pointer(.leftMouseUp, window: handle, global: start) }
            XCTAssertFalse(preview.isPositionVerified, "Release alone does not verify the viewport")
            // A duplicate verified match may carry no replacement preview. The
            // most recently accepted image/viewport must then be the green pair.
            controller.update(snapshot: state)
            XCTAssertTrue(preview.image === latest)
            assertViewport(preview.viewportFraction, equals: latestFraction)
            XCTAssertTrue(preview.isPositionVerified); XCTAssertEqual(preview.viewportMarkerColor, .systemGreen)
        }
    }

    private func assertViewport(_ actual: CGRect, equals expected: CGRect,
                                file: StaticString = #filePath, line: UInt = #line) {
        // CGRect intersection normalizes floating-point endpoints. Preserve all
        // four geometric checks while allowing only rounding-scale error.
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-12, file: file, line: line)
    }

    private func pointer(_ type: NSEvent.EventType, window: NSWindow, global: CGPoint) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: global),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
    }

    private func fixtureImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
