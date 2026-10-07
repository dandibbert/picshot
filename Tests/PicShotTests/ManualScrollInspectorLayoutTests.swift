import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class ManualScrollInspectorLayoutTests: XCTestCase {
    func testInspectorGivesFreeSpaceToPreviewAndFitsExpandedTrimControls() async throws {
        let controller = ScrollCaptureController { _ in }
        defer { controller.close() }
        controller.showWindow(nil)
        _ = try await controller.acceptForVerification(ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100), axis: .vertical)
        _ = try await controller.acceptForVerification(ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 147), axis: .vertical)
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let frame = window.frame
        let preview = controller.previewForVerification
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(preview.frame.height, 350, "Stopped inspector should spend free space on its preview")
        try assertVisibleControlsFit(content)
        let trimmed = try control("scroll.trim", in: content)
        trimmed.performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(preview.frame.height, 230)
        XCTAssertEqual(window.frame, frame, "Showing trim controls should not move/resize the inspector")
        for identifier in ["scroll.bandStart", "scroll.bandLength", "scroll.selectBand", "scroll.apply", "scroll.cancel"] {
            let view = try XCTUnwrap(allViews(content).first { $0.identifier?.rawValue == identifier })
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(content.bounds.insetBy(dx: 10, dy: 10).contains(view.convert(view.bounds, to: content)), identifier)
        }
        try assertVisibleControlsFit(content)
        try control("scroll.cancel", in: content).performClick(nil)
        await controller.waitForOperationForVerification()
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(preview.frame.height, 350)
        XCTAssertEqual(window.frame, frame)
    }

    private func assertVisibleControlsFit(_ content: NSView) throws {
        for view in allViews(content) where !view.isHiddenOrHasHiddenAncestor {
            guard view is NSControl, view.identifier?.rawValue.hasPrefix("scroll.") == true else { continue }
            XCTAssertTrue(content.bounds.contains(view.convert(view.bounds, to: content)), view.identifier?.rawValue ?? "")
        }
    }
    private func control(_ identifier: String, in content: NSView) throws -> NSButton {
        try XCTUnwrap(allViews(content).first { $0.identifier?.rawValue == identifier } as? NSButton)
    }
    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { allViews($0) } }
}
