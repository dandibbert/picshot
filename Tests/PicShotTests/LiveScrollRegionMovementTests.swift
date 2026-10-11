import XCTest
import AppKit
import PicShotCore
@testable import PicShot

/// Owned native events only. These exercise the production mover view's flipped
/// coordinates and commit/cancel callback; no global event or screen capture occurs.
@MainActor
final class LiveScrollRegionMovementTests: XCTestCase {
    private let original = CGRect(x: 100, y: 80, width: 200, height: 140)

    func testVerticalActiveMovementLocksXAndReturnCommitsFinalMouseUpPosition() throws {
        try verifyCommit(axis: .vertical, expected: CGRect(x: 100, y: 135, width: 200, height: 140))
    }

    func testHorizontalActiveMovementLocksYAndReturnCommitsFinalMouseUpPosition() throws {
        try verifyCommit(axis: .horizontal, expected: CGRect(x: 165, y: 80, width: 200, height: 140))
    }

    func testPausedMovementAllowsBothAxesAndReturnKeepsTheFixedSize() throws {
        try verifyCommit(axis: nil, expected: CGRect(x: 165, y: 135, width: 200, height: 140))
    }

    func testEscapeAfterNativeDragReturnsCancellationWithoutApplyingTheProposedRegion() throws {
        let axes: [ScrollAxis?] = [.vertical, .horizontal, nil]
        for axis in axes {
            let (window, view) = makeView(axis: axis)
            defer { view.finished = nil; window.contentView = nil; window.close() }
            var appliedRegion = original
            var commits = 0
            var failures: [Error] = []
            view.finished = { result in
                switch result {
                case .success(let region): appliedRegion = region; commits += 1
                case .failure(let error): failures.append(error)
                }
            }
            try drag(view)
            XCTAssertNotEqual(view.region, original, "The gesture must propose a real move before cancellation")
            XCTAssertEqual(appliedRegion, original, "Preview movement must not apply before Return")
            view.keyDown(with: try key(view, code: 53, characters: "\u{1b}"))
            XCTAssertEqual(commits, 0)
            XCTAssertEqual(appliedRegion, original)
            XCTAssertEqual(failures.count, 1)
            let error = try XCTUnwrap(failures.first)
            guard case CaptureError.cancelled = error else {
                XCTFail("Escape should return CaptureError.cancelled, got \(error)")
                continue
            }
        }
    }

    private func verifyCommit(axis: ScrollAxis?, expected: CGRect) throws {
        let (window, view) = makeView(axis: axis)
        defer { view.finished = nil; window.contentView = nil; window.close() }
        var appliedRegion = original
        var commits = 0
        var failures = 0
        view.finished = { result in
            switch result {
            case .success(let region): appliedRegion = region; commits += 1
            case .failure: failures += 1
            }
        }
        XCTAssertTrue(view.isFlipped)
        try drag(view)
        XCTAssertEqual(view.region, expected)
        XCTAssertEqual(view.region.size, original.size)
        XCTAssertTrue(view.bounds.contains(view.region))
        XCTAssertEqual(appliedRegion, original)
        XCTAssertEqual(commits, 0)
        // mouseUp finishes the gesture; a subsequent stray drag cannot mutate it.
        view.mouseDragged(with: try mouse(.leftMouseDragged, view: view, point: CGPoint(x: 400, y: 350)))
        XCTAssertEqual(view.region, expected)
        view.keyDown(with: try key(view, code: 36, characters: "\r"))
        XCTAssertEqual(appliedRegion, expected)
        XCTAssertEqual(commits, 1); XCTAssertEqual(failures, 0)
    }

    private func makeView(axis: ScrollAxis?) -> (NSWindow, ManualScrollRegionMoveView) {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ManualScrollRegionMoveView(frame: frame, region: original, movementAxis: axis)
        window.contentView = view
        return (window, view)
    }

    private func drag(_ view: ManualScrollRegionMoveView) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, view: view, point: CGPoint(x: 140, y: 120)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, view: view, point: CGPoint(x: 180, y: 150)))
        // The final event advances beyond mouseDragged to verify the production
        // mouseUp path, rather than only testing its intermediate preview.
        view.mouseUp(with: try mouse(.leftMouseUp, view: view, point: CGPoint(x: 205, y: 175)))
    }

    private func mouse(_ type: NSEvent.EventType, view: NSView, point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func key(_ view: NSView, code: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
