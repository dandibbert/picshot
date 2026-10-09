import XCTest
import AppKit
import ImageIO
@testable import PicShot

@MainActor
final class RecordingTransportTests: XCTestCase {
    private var bounds: CGRect { CGRect(x: -1_280, y: -100, width: 1_280, height: 800) }
    private var anchor: CGRect { CGRect(x: -960, y: 240, width: 320, height: 240) }
    private var active: RecordingTransportSnapshot { RecordingTransportSnapshot(canPause: true, canStop: true, elapsed: 83) }
    private var noActions: RecordingTransportActions { RecordingTransportActions(pauseResume: {}, stopSave: {}, expand: {}) }

    func testElapsedFormattingUsesAcceptedElapsedAndHandlesInvalidInput() {
        var state = active
        XCTAssertEqual(state.elapsedLabel, "01:23")
        state.elapsed = 3_661.9; XCTAssertEqual(state.elapsedLabel, "01:01:01")
        state.elapsed = -2; XCTAssertEqual(state.elapsedLabel, "00:00")
        state.elapsed = .nan; XCTAssertEqual(state.elapsedLabel, "00:00")
        state.elapsed = .infinity; XCTAssertEqual(state.elapsedLabel, "00:00")
        state.elapsed = 1_000_000; XCTAssertEqual(state.elapsedLabel, "99:59:59")
    }

    func testPlacementPrefersOutsideRegionAndClampsNegativeOriginEdges() {
        let below = RecordingTransportPlacement.initial(anchor: anchor, visibleFrame: bounds)
        XCTAssertEqual(below.maxY, anchor.minY - 8)
        XCTAssertEqual(below.midX, anchor.midX)
        XCTAssertTrue(bounds.contains(below))
        let bottom = CGRect(x: -1_260, y: bounds.minY, width: 100, height: 100)
        let above = RecordingTransportPlacement.initial(anchor: bottom, visibleFrame: bounds)
        XCTAssertEqual(above.minY, bottom.maxY + 8)
        XCTAssertEqual(above.minX, bounds.minX)
        for dx in [-10_000.0, 10_000.0] {
            for dy in [-10_000.0, 10_000.0] {
                let clamped = RecordingTransportPlacement.clamp(below.offsetBy(dx: dx, dy: dy), to: bounds)
                XCTAssertTrue(bounds.contains(clamped))
                XCTAssertEqual(clamped.size, CGSize(width: 300, height: 40))
            }
        }
        let full = RecordingTransportPlacement.initial(anchor: bounds, visibleFrame: bounds)
        XCTAssertTrue(bounds.contains(full))
        XCTAssertFalse(RecordingTransportPlacement.isUsable(.null))
        XCTAssertFalse(RecordingTransportPlacement.isUsable(CGRect(x: 0, y: 0, width: 80, height: 20)))
    }

    func testLiveNativeButtonsReflectOwnerStateAndReplacementActions() throws {
        _ = NSApplication.shared
        var firstPause = 0, firstStop = 0, secondPause = 0, secondStop = 0
        let controller = RecordingTransportController(actions: .init(pauseResume: { firstPause += 1 },
                                                                     stopSave: { firstStop += 1 }, expand: {}))
        defer { controller.teardown() }
        controller.show(snapshot: active, anchor: anchor, visibleFrame: bounds)
        let view = try XCTUnwrap(controller.window?.contentView as? RecordingTransportView)
        view.pauseButton.performClick(nil)
        XCTAssertEqual(firstPause, 1)
        var state = active
        state.paused = true; state.statusKind = .paused; state.status = "已暂停"
        state.pauseShortcut = "⌥⌘P"; state.stopShortcut = "⌥⌘S"
        controller.update(snapshot: state, actions: .init(pauseResume: { secondPause += 1 },
                                                         stopSave: { secondStop += 1 }, expand: {}))
        XCTAssertEqual(view.pauseButton.accessibilityLabel(), "继续录屏")
        XCTAssertEqual(view.statusLabel.stringValue, "已暂停")
        XCTAssertEqual(view.elapsedLabel.stringValue, "01:23")
        XCTAssertTrue(try XCTUnwrap(view.pauseButton.toolTip).contains("⌥⌘P"))
        view.pauseButton.performClick(nil)
        state.busy = true; controller.update(snapshot: state)
        XCTAssertFalse(view.pauseButton.isEnabled)
        XCTAssertTrue(view.stopButton.isEnabled)
        view.pauseButton.performClick(nil); view.stopButton.performClick(nil)
        XCTAssertEqual(firstPause, 1); XCTAssertEqual(firstStop, 0)
        XCTAssertEqual(secondPause, 1); XCTAssertEqual(secondStop, 1)
        state.canStop = false; state.pauseShortcut = nil; state.stopShortcut = nil
        controller.update(snapshot: state)
        view.stopButton.performClick(nil)
        XCTAssertEqual(secondStop, 1)
        XCTAssertTrue(try XCTUnwrap(view.pauseButton.toolTip).contains("未设置快捷键"))
        XCTAssertTrue(try XCTUnwrap(view.stopButton.toolTip).contains("未设置快捷键"))
    }

    func testNarrowWorkAreaPreservesNonoverlappingNativeActionHitTargets() throws {
        _ = NSApplication.shared
        let controller = RecordingTransportController(actions: noActions)
        defer { controller.teardown() }
        for width in [CGFloat(144), 180, 220, 300] {
            let screen = CGRect(x: -600, y: -240, width: width, height: 400)
            controller.show(snapshot: active, anchor: screen, visibleFrame: screen)
            let window = try XCTUnwrap(controller.window)
            let view = try XCTUnwrap(window.contentView as? RecordingTransportView)
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(screen.contains(window.frame))
            var frames: [CGRect] = []
            for control in [view.grip, view.pauseButton, view.stopButton, view.expandButton] as [NSView] {
                let frame = control.convert(control.bounds, to: view)
                XCTAssertTrue(view.bounds.contains(frame))
                XCTAssertFalse(frames.contains { $0.intersects(frame) })
                let hit = view.hitTest(view.convert(CGPoint(x: frame.midX, y: frame.midY), to: view.superview))
                XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true)
                frames.append(frame)
            }
            XCTAssertTrue(view.stopButton.isEnabled)
        }
    }

    func testStateUpdatesAndHidePreservePositionWhileBoundsChangesClamp() throws {
        _ = NSApplication.shared
        var pause = 0, stop = 0
        let controller = RecordingTransportController(actions: .init(pauseResume: { pause += 1 }, stopSave: { stop += 1 }, expand: {}))
        defer { controller.teardown() }
        controller.show(snapshot: active, anchor: anchor, visibleFrame: bounds)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(CGPoint(x: -310, y: -90))
        let position = window.frame.origin
        var state = active; state.elapsed = 120
        controller.update(snapshot: state)
        XCTAssertEqual(window.frame.origin, position)
        controller.hide()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(pause, 0); XCTAssertEqual(stop, 0)
        controller.show(snapshot: state, anchor: anchor.offsetBy(dx: 30, dy: 100), visibleFrame: bounds)
        XCTAssertEqual(window.frame.origin, position)
        let reduced = CGRect(x: -800, y: 0, width: 600, height: 500)
        controller.updatePlacement(anchor: anchor, visibleFrame: reduced)
        XCTAssertTrue(reduced.contains(window.frame))
        let clamped = window.frame
        controller.updatePlacement(anchor: .null, visibleFrame: .null)
        XCTAssertEqual(window.frame, clamped)
        controller.updatePlacement(anchor: anchor, visibleFrame: bounds, preservePosition: false)
        XCTAssertEqual(window.frame, RecordingTransportPlacement.initial(anchor: anchor, visibleFrame: bounds))
    }

    func testOnlyGripDragChangesWindowAndHideCancelsItsInFlightGesture() throws {
        _ = NSApplication.shared
        let controller = RecordingTransportController(actions: noActions)
        defer { controller.teardown() }
        controller.show(snapshot: active, anchor: anchor, visibleFrame: bounds)
        let window = try XCTUnwrap(controller.window)
        let view = try XCTUnwrap(window.contentView as? RecordingTransportView)
        view.layoutSubtreeIfNeeded()
        let original = window.frame
        let start = window.convertPoint(toScreen: view.grip.convert(CGPoint(x: 10, y: 16), to: nil))
        view.grip.mouseDown(with: try event(.leftMouseDown, point: start, window: window))
        let destination = CGPoint(x: start.x + 30, y: start.y + 20)
        view.grip.mouseDragged(with: try event(.leftMouseDragged, point: destination, window: window))
        view.grip.mouseUp(with: try event(.leftMouseUp, point: destination, window: window))
        XCTAssertEqual(window.frame.origin, original.offsetBy(dx: 30, dy: 20).origin)
        let moved = window.frame
        for button in [view.pauseButton, view.stopButton, view.expandButton] {
            XCTAssertFalse(button.mouseDownCanMoveWindow)
            button.mouseDragged(with: try event(.leftMouseDragged, point: destination, window: window))
            XCTAssertEqual(window.frame, moved)
        }
        view.grip.mouseDown(with: try event(.leftMouseDown, point: destination, window: window))
        controller.hide()
        view.grip.mouseDragged(with: try event(.leftMouseDragged, point: start, window: window))
        XCTAssertEqual(window.frame, moved)
        XCTAssertFalse(window.isMovableByWindowBackground)
    }

    func testTeardownIsIdempotentAndOldControlReferencesCannotDispatch() throws {
        _ = NSApplication.shared
        var calls = 0
        let action = { calls += 1 }
        let controller = RecordingTransportController(actions: .init(pauseResume: action, stopSave: action, expand: action))
        controller.show(snapshot: active, anchor: anchor, visibleFrame: bounds)
        let window = try XCTUnwrap(controller.window)
        let view = try XCTUnwrap(window.contentView as? RecordingTransportView)
        XCTAssertEqual(window.sharingType, .none)
        XCTAssertFalse(window.styleMask.contains(.closable))
        controller.teardown(); controller.teardown()
        for button in [view.pauseButton, view.stopButton, view.expandButton] {
            button.performClick(nil)
            XCTAssertNil(button.target); XCTAssertNil(button.action); XCTAssertFalse(button.isEnabled)
        }
        XCTAssertNil(window.contentView)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(controller.window)
        XCTAssertTrue(controller.isRetired)
        controller.show(snapshot: active, anchor: anchor, visibleFrame: bounds)
        XCTAssertNil(controller.window)
        XCTAssertEqual(calls, 0)
    }

    func testNativeFixturePersistsLightDarkPixelsRawGeometryAndOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let appearance = NSApp.appearance
        let report = try await RecordingTransportPreviewFixture.verify(evidenceDirectory: directory)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["nativeMonitorRegistrations"] as? Int, 0)
        XCTAssertEqual(report["productionTimers"] as? Int, 0)
        XCTAssertEqual(report["productionObservers"] as? Int, 0)
        let appearances = try XCTUnwrap(report["appearances"] as? [[String: Any]])
        XCTAssertEqual(appearances.count, 2)
        for theme in appearances {
            let ownership = try XCTUnwrap(theme["ownership"] as? [String: Any])
            XCTAssertEqual(ownership["retainedObjects"] as? Int, 0)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(ownership["weakProbeCount"] as? Int), 9)
            let states = try XCTUnwrap(theme["states"] as? [[String: Any]])
            XCTAssertEqual(states.count, 4)
            for state in states {
                let png = directory.appendingPathComponent(try XCTUnwrap(state["file"] as? String))
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, 300); XCTAssertEqual(image.height, 40)
                let rawURL = directory.appendingPathComponent(try XCTUnwrap(state["geometryFile"] as? String))
                let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: rawURL)) as? [String: Any])
                XCTAssertEqual(raw["status"] as? String, "measured-before-validation")
                XCTAssertEqual((raw["controls"] as? [Any])?.count, 6)
            }
        }
        let lightData = try Data(contentsOf: directory.appendingPathComponent("recording-transport-recording-light.png"))
        let darkData = try Data(contentsOf: directory.appendingPathComponent("recording-transport-recording-dark.png"))
        let light = try XCTUnwrap(NSBitmapImageRep(data: lightData)?.colorAt(x: 26, y: 20)?.usingColorSpace(.deviceRGB))
        let dark = try XCTUnwrap(NSBitmapImageRep(data: darkData)?.colorAt(x: 26, y: 20)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(light.redComponent - dark.redComponent, 0.5, "Light/dark PNGs must contain the native surface change")
        XCTAssertTrue(NSApp.appearance === appearance)
        XCTAssertTrue(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)).subtracting(visible).isEmpty)
        let retirement = try XCTUnwrap(report["repeatedRetirement"] as? [String: Any])
        XCTAssertEqual(retirement["retainedObjects"] as? Int, 0)
        XCTAssertEqual(retirement["weakProbeCount"] as? Int, 64)
    }

    func testFixtureRejectsUnwritableEvidenceBeforeCreatingWindows() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-transport-file-\(UUID().uuidString)")
        let sentinel = Data("existing file".utf8)
        try sentinel.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = NSApplication.shared
        let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        do {
            _ = try await RecordingTransportPreviewFixture.verify(evidenceDirectory: file)
            XCTFail("Fixture should reject a regular file as its evidence directory")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), sentinel)
        XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)), visible)
    }

    private func event(_ type: NSEvent.EventType, point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
