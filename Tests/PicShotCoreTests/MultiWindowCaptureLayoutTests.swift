import XCTest
@testable import PicShotCore

final class MultiWindowCaptureLayoutTests: XCTestCase {
    func testNegativeOriginsMixedDensityAndZOrderAreIndependentOfIDs() throws {
        let front = try window(90, CGRect(x: -20, y: -10, width: 20, height: 30), scale: 1)
        let back = try window(2, CGRect(x: 10, y: 20, width: 20, height: 10), scale: 2)
        let layout = try MultiWindowCaptureLayout(frontToBack: [front, back])
        XCTAssertEqual(layout.desktopBounds, CGRect(x: -20, y: -10, width: 50, height: 40))
        XCTAssertEqual(layout.width, 100); XCTAssertEqual(layout.height, 80)
        XCTAssertEqual(layout.placements.map(\.window.id), [2, 90])
        XCTAssertEqual(layout.placements[0].pixelBounds, CGRect(x: 60, y: 60, width: 40, height: 20))
        XCTAssertEqual(layout.placements[1].pixelBounds, CGRect(x: 0, y: 0, width: 40, height: 60))
    }
    func testSelectionToggleCycleAndKeyboardFocusPreserveDesktopOrder() throws {
        let windows = try [window(3), window(1), window(7)]
        var selection = MultiWindowSelection(windows: windows)
        try selection.toggle(7); try selection.toggle(3)
        XCTAssertEqual(selection.selected.map(\.id), [3, 7])
        XCTAssertEqual(selection.focus(at: CGPoint(x: 2, y: 2), cycle: false), 3)
        XCTAssertEqual(selection.focus(at: CGPoint(x: 2, y: 2), cycle: true), 1)
        try selection.toggle(1); try selection.toggle(7)
        XCTAssertEqual(selection.selected.map(\.id), [3, 1])
        selection.focusNext(); XCTAssertEqual(selection.focusedID, 3)
        selection.focusNext(backwards: true); XCTAssertEqual(selection.focusedID, 7)
        XCTAssertNil(selection.focus(at: CGPoint(x: -1, y: -1), cycle: false))
    }
    func testChangedIdentityClosureGeometryScaleAndRelativeOrderReject() throws {
        let first = try window(1), second = try window(2)
        let layout = try MultiWindowCaptureLayout(frontToBack: [first, second])
        XCTAssertNoThrow(try layout.validate(frontToBack: [window(99), first, second]))
        let renamed = try MultiWindowDescriptor(id: first.id, ownerPID: first.ownerPID, ownerStartedAt: first.ownerStartedAt,
            label: "Updated title", bounds: first.bounds, maximumScale: first.maximumScale)
        XCTAssertNoThrow(try layout.validate(frontToBack: [renamed, second]))
        for changed in [[first], [second, first], [try window(1, scale: 2), second],
                        [try window(1, CGRect(x: 1, y: 0, width: 10, height: 10)), second],
                        [try window(1, pid: 77), second], [try window(1, started: 99), second]] {
            XCTAssertThrowsError(try layout.validate(frontToBack: changed)) { XCTAssertEqual($0 as? MultiWindowCaptureError, .changed) }
        }
    }
    func testWindowCountInputAndOutputBudgetsBeforeCapture() throws {
        XCTAssertThrowsError(try MultiWindowCaptureLayout(frontToBack: []))
        XCTAssertThrowsError(try MultiWindowCaptureLayout(frontToBack: (1...9).map { try window(UInt32($0)) }))
        XCTAssertThrowsError(try MultiWindowCaptureLayout(frontToBack: [window(1), window(1)]))
        XCTAssertThrowsError(try window(1, CGRect(x: 0, y: 0, width: 5_000, height: 5_000)))
        let large = try (1...5).map { try window(UInt32($0), CGRect(x: 0, y: 0, width: 4_000, height: 4_000)) }
        XCTAssertThrowsError(try MultiWindowCaptureLayout(frontToBack: large))
        let left = try window(1, CGRect(x: -10_000, y: 0, width: 10, height: 10))
        let right = try window(2, CGRect(x: 10_000, y: 0, width: 10, height: 10))
        XCTAssertThrowsError(try MultiWindowCaptureLayout(frontToBack: [left, right]))
        var selection = MultiWindowSelection(windows: try (1...9).map { try window(UInt32($0)) })
        for id in UInt32(1)...8 { try selection.toggle(id) }
        XCTAssertThrowsError(try selection.toggle(9)); XCTAssertEqual(selection.selectedIDs.count, 8)
        try selection.toggle(1); try selection.toggle(9); XCTAssertEqual(selection.selectedIDs.count, 8)
    }
    func testActualRasterMustRespectAspectScaleAndFrameBudget() throws {
        let source = try window(1, CGRect(x: 0, y: 0, width: 100, height: 80), scale: 2)
        for (w, h) in [(100,80), (200,160), (150,120)] { XCTAssertNoThrow(try source.validateRaster(width: w, height: h)) }
        for (w, h) in [(0,0), (90,80), (200,180), (201,160), (Int.max,2)] { XCTAssertThrowsError(try source.validateRaster(width: w, height: h)) }
        for value in [CGFloat.nan, CGFloat.infinity, -1, 0] { XCTAssertThrowsError(try window(1, scale: value)) }
    }
    func testNormalizedRasterBudgetIncludesSourcePaddingAndScratch() throws {
        let layout = try MultiWindowCaptureLayout(frontToBack: [window(1, CGRect(x: 0, y: 0, width: 4_000, height: 4_000))])
        // The exact 192 MB boundary is canvas + admitted input + normalized input.
        XCTAssertEqual(try layout.normalizedRasterBytes(width: 4_000, height: 4_000, bytesPerRow: 16_000), 192_000_000)
        XCTAssertNoThrow(try layout.validateNormalizedRasterBudget())
        let padded = try MultiWindowCaptureLayout(frontToBack: [window(1, CGRect(x: 0, y: 0, width: 100, height: 100))])
        XCTAssertEqual(try padded.normalizedRasterBytes(width: 100, height: 100, bytesPerRow: 448), 124_800)
        for invalid in [(0,100,400), (100,0,400), (100,100,0), (100,100,Int.max), (Int.max,2,4)] {
            XCTAssertThrowsError(try padded.normalizedRasterBytes(width: invalid.0, height: invalid.1, bytesPerRow: invalid.2))
        }
        let large = try MultiWindowCaptureLayout(frontToBack: [
            window(1, CGRect(x: 0, y: 0, width: 4_000, height: 4_000)),
            window(2, CGRect(x: 4_000, y: 0, width: 4_000, height: 4_000))])
        XCTAssertEqual(large.width * large.height, MultiWindowCaptureLimits.outputPixels)
        XCTAssertThrowsError(try large.validateNormalizedRasterBudget()) { XCTAssertEqual($0 as? MultiWindowCaptureError, .pixelLimit) }
        // Padding alone can push an otherwise valid tight-input layout over budget.
        let near = try MultiWindowCaptureLayout(frontToBack: [
            window(1, CGRect(x: 0, y: 0, width: 3_000, height: 4_000)),
            window(2, CGRect(x: 3_000, y: 0, width: 3_000, height: 4_000))])
        XCTAssertNoThrow(try near.validateNormalizedRasterBudget())
        XCTAssertEqual(try near.normalizedRasterBytes(width: 3_000, height: 4_000, bytesPerRow: 12_000), 192_000_000)
        XCTAssertThrowsError(try near.normalizedRasterBytes(width: 3_000, height: 4_000, bytesPerRow: 12_004))
    }
    private func window(_ id: UInt32, _ bounds: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10),
                        scale: CGFloat = 1, pid: Int32 = 10, started: TimeInterval = 1) throws -> MultiWindowDescriptor {
        try MultiWindowDescriptor(id: id, ownerPID: pid, ownerStartedAt: started, label: "Window \(id)", bounds: bounds, maximumScale: scale)
    }
}
