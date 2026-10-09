import XCTest
import CoreGraphics
@testable import PicShot

final class RecordingInputEffectsTests: XCTestCase {
    private let all = RecordingInputEffectsOptions(clicks: true, scrolls: true, shortcuts: true)
    private let point = CGPoint(x: 0.5, y: 0.5)

    func testEveryCategoryIsOffByDefaultAndRequiresAnActiveSession() {
        let state = RecordingInputEffectsState()
        XCTAssertFalse(RecordingInputEffectsOptions().isEnabled)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 0, token: UUID()))
        let token = state.beginSession(options: RecordingInputEffectsOptions(), at: 0)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 0, token: token))
        XCTAssertFalse(state.recordScroll(deltaX: 1, deltaY: 1, normalizedPoint: point, at: 0, token: token))
        XCTAssertFalse(state.recordShortcut(keyCode: 8, modifiers: .command, at: 0, token: token))
        XCTAssertFalse(state.snapshot(at: 0).hasVisibleEffects)
    }

    func testIndependentOptInAndDisablingClearsOnlyDisabledCategories() {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        XCTAssertTrue(state.recordClick(button: .right, normalizedPoint: point, at: 0, token: token))
        XCTAssertTrue(state.recordScroll(deltaX: 1, deltaY: 0, normalizedPoint: point, at: 0, token: token))
        XCTAssertTrue(state.recordShortcut(keyCode: 8, modifiers: .command, at: 0, token: token))
        state.setOptions(RecordingInputEffectsOptions(scrolls: true))
        let snapshot = state.snapshot(at: 0)
        XCTAssertEqual(snapshot.events.count, 1)
        guard let event = snapshot.events.first, case .scroll = event.kind else {
            return XCTFail("Scroll opt-in must remain active")
        }
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 0, token: token))
        XCTAssertFalse(state.recordShortcut(keyCode: 8, modifiers: .command, at: 0, token: token))
        state.setOptions(RecordingInputEffectsOptions())
        XCTAssertTrue(state.snapshot(at: 0).events.isEmpty)
    }

    func testBurstHasFixedCountAndRetainsNewestValues() {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        for index in 0..<10_000 {
            XCTAssertTrue(state.recordClick(button: .left,
                normalizedPoint: CGPoint(x: CGFloat(index) / 10_000, y: 0.5), at: 0, token: token))
        }
        let events = state.snapshot(at: 0).events
        XCTAssertEqual(events.count, RecordingInputEffectsState.maximumEvents)
        guard case let .click(_, first)? = events.first?.kind,
              case let .click(_, last)? = events.last?.kind else { return XCTFail("Expected bounded click values") }
        XCTAssertEqual(first.x, CGFloat(10_000 - RecordingInputEffectsState.maximumEvents) / 10_000)
        XCTAssertEqual(last.x, 0.9999, accuracy: 0.000001)
    }

    func testExpiryIsPerCategoryAndAdvancesRevisionForFinalRepaint() {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        state.recordClick(button: .left, normalizedPoint: point, at: 0, token: token)
        state.recordScroll(deltaX: 1, deltaY: 1, normalizedPoint: point, at: 0, token: token)
        state.recordShortcut(keyCode: 8, modifiers: .command, at: 0, token: token)
        let initial = state.snapshot(at: 0)
        XCTAssertEqual(initial.events.count, 3)
        let clicksExpired = state.snapshot(at: 0.7)
        XCTAssertEqual(clicksExpired.events.count, 2)
        XCTAssertGreaterThan(clicksExpired.revision, initial.revision)
        let scrollExpired = state.snapshot(at: 0.85)
        XCTAssertEqual(scrollExpired.events.count, 1)
        XCTAssertGreaterThan(scrollExpired.revision, clicksExpired.revision)
        let allExpired = state.snapshot(at: RecordingInputEffectsState.maximumLifetime)
        XCTAssertFalse(allExpired.hasVisibleEffects)
        XCTAssertTrue(allExpired.events.isEmpty)
        XCTAssertGreaterThan(allExpired.revision, scrollExpired.revision)
        XCTAssertEqual(state.snapshot(at: 100).revision, allExpired.revision)
    }

    func testPauseResumeEndAndReplacementRejectQueuedEvents() {
        let state = RecordingInputEffectsState(), first = state.beginSession(options: all, at: 10)
        XCTAssertTrue(state.recordClick(button: .left, normalizedPoint: point, at: 10, token: first))
        state.setPaused(true, at: 10.1)
        XCTAssertTrue(state.snapshot(at: 10.1).events.isEmpty)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 10.2, token: first))
        state.setPaused(false, at: 20)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 19, token: first))
        XCTAssertTrue(state.recordClick(button: .left, normalizedPoint: point, at: 20, token: first))
        state.endSession()
        XCTAssertTrue(state.snapshot(at: 20).events.isEmpty)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 20.1, token: first))
        let second = state.beginSession(options: all, at: 30)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 30, token: first))
        XCTAssertTrue(state.recordClick(button: .left, normalizedPoint: point, at: 30, token: second))
    }

    func testPrivacyClearRejectsOlderCallbacksWithoutEndingSession() {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 10)
        state.recordShortcut(keyCode: 8, modifiers: .command, at: 10, token: token)
        state.clearEvents(at: 10.2)
        XCTAssertFalse(state.snapshot(at: 10.2).hasVisibleEffects)
        XCTAssertFalse(state.recordShortcut(keyCode: 8, modifiers: .command, at: 10.1, token: token))
        XCTAssertTrue(state.recordShortcut(keyCode: 8, modifiers: .command, at: 10.2, token: token))
        state.setPaused(true, at: 10.3)
        state.clearEvents(at: 10.4)
        XCTAssertFalse(state.recordShortcut(keyCode: 8, modifiers: .command, at: 10.5, token: token))
    }

    func testFiniteUnitSquarePointsAndFiniteNonnegativeOrderedTimesOnly() {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 10)
        let invalidPoints = [CGPoint(x: -CGFloat.infinity, y: 0), CGPoint(x: CGFloat.nan, y: 0),
                             CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: -0.01, y: 0.5), CGPoint(x: 0.5, y: 1.01)]
        for invalid in invalidPoints {
            XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: invalid, at: 10, token: token))
        }
        for time in [Double.nan, .infinity, -.infinity, -1, 9.9] {
            XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: time, token: token))
        }
        XCTAssertTrue(state.recordClick(button: .left, normalizedPoint: .zero, at: 10, token: token))
        XCTAssertTrue(state.recordClick(button: .left, normalizedPoint: CGPoint(x: 1, y: 1), at: 10.2, token: token))
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 10.1, token: token))
        for time in [Double.nan, .infinity, -1] { XCTAssertTrue(state.snapshot(at: time).events.isEmpty) }
    }

    func testInvalidLifecycleClockFailsClosed() {
        let state = RecordingInputEffectsState()
        let invalid = state.beginSession(options: all, at: .nan)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 0, token: invalid))
        let valid = state.beginSession(options: all, at: 0)
        state.setPaused(false, at: .infinity)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 1, token: valid))
        state.setPaused(false, at: 1)
        state.clearEvents(at: .nan)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 1, token: valid))
    }

    func testScrollPreservesBothDirectionsAndBoundsExtremeMagnitude() {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        XCTAssertFalse(state.recordScroll(deltaX: 0, deltaY: 0, normalizedPoint: point, at: 0, token: token))
        XCTAssertFalse(state.recordScroll(deltaX: .nan, deltaY: 1, normalizedPoint: point, at: 0, token: token))
        XCTAssertFalse(state.recordScroll(deltaX: 1, deltaY: .infinity, normalizedPoint: point, at: 0, token: token))
        XCTAssertTrue(state.recordScroll(deltaX: .greatestFiniteMagnitude, deltaY: -.greatestFiniteMagnitude,
                                        normalizedPoint: point, at: 0, token: token))
        guard case let .scroll(dx, dy, location)? = state.snapshot(at: 0).events.first?.kind else {
            return XCTFail("Expected a scroll event")
        }
        XCTAssertEqual(dx, RecordingInputEffectsState.maximumScrollDelta)
        XCTAssertEqual(dy, -RecordingInputEffectsState.maximumScrollDelta)
        XCTAssertEqual(location, point)
    }

    func testShortcutWhitelistRejectsOrdinaryTypingAndHasOnlyFixedASCII() {
        XCTAssertNil(RecordingInputShortcut(keyCode: 0, modifiers: []))
        XCTAssertNil(RecordingInputShortcut(keyCode: 0, modifiers: .shift))
        XCTAssertNil(RecordingInputShortcut(keyCode: 0, modifiers: .option), "Option can enter text and dead keys")
        XCTAssertNil(RecordingInputShortcut(keyCode: 0, modifiers: [.option, .shift]))
        XCTAssertNil(RecordingInputShortcut(keyCode: UInt16.max, modifiers: .command))
        XCTAssertNil(RecordingInputShortcut(keyCode: 55, modifiers: .command), "Modifier-only events are not shortcuts")
        XCTAssertNil(RecordingInputShortcut(keyCode: 0, modifiers: RecordingShortcutModifiers(rawValue: 255)))
        XCTAssertEqual(RecordingInputShortcut(keyCode: 8, modifiers: .command)?.label, "CMD+C")
        XCTAssertEqual(RecordingInputShortcut(keyCode: 126, modifiers: [.control, .option, .shift, .command])?.label,
                       "CTRL+OPT+SHIFT+CMD+UP")
        for code in UInt16(0)...UInt16(255) {
            if let shortcut = RecordingInputShortcut(keyCode: code, modifiers: [.control, .option, .shift, .command]) {
                XCTAssertTrue(shortcut.label.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 43 })
                XCTAssertLessThanOrEqual(shortcut.label.utf8.count, 32)
            }
        }
    }

    func testFutureEventsDoNotDrawAndSnapshotCannotResurrectExpiredCallbacks() {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        XCTAssertTrue(state.recordClick(button: .left, normalizedPoint: point, at: 2, token: token))
        XCTAssertFalse(state.snapshot(at: 1).hasVisibleEffects)
        XCTAssertTrue(state.snapshot(at: 2).hasVisibleEffects)
        XCTAssertFalse(state.snapshot(at: 10).hasVisibleEffects)
        XCTAssertFalse(state.recordClick(button: .left, normalizedPoint: point, at: 2.1, token: token))
    }

    func testConcurrentInputBurstRemainsBoundedAndPauseClearsAtomically() {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            state.recordClick(button: index.isMultiple(of: 2) ? .left : .right,
                normalizedPoint: CGPoint(x: 0.5, y: 0.5), at: 0, token: token)
            _ = state.snapshot(at: 0)
        }
        XCTAssertEqual(state.snapshot(at: 0).events.count, RecordingInputEffectsState.maximumEvents)
        state.setPaused(true, at: 0)
        XCTAssertFalse(state.snapshot(at: 0).hasVisibleEffects)
    }

    func testRenderingIsByteDeterministicAndExpiredEffectsRestoreExactBackground() throws {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        state.recordClick(button: .left, normalizedPoint: CGPoint(x: 0.2, y: 0.65), at: 0, token: token)
        state.recordScroll(deltaX: -10, deltaY: 20, normalizedPoint: CGPoint(x: 0.8, y: 0.65), at: 0, token: token)
        state.recordShortcut(keyCode: 8, modifiers: [.command, .shift], at: 0, token: token)
        let frozen = state.snapshot(at: 0.2)
        let first = try raster(frozen), identical = try raster(frozen)
        XCTAssertEqual(first.bytes, identical.bytes)
        XCTAssertNotEqual(first.bytes, try raster(frozen, at: 0.4).bytes)
        let empty = RecordingInputEffectsSnapshot(revision: 0, sampledAt: 0, events: [])
        XCTAssertEqual(try raster(frozen, at: 1.2).bytes, try raster(empty).bytes)
        state.endSession()
        XCTAssertEqual(first.bytes, try raster(frozen).bytes, "A frozen Stop snapshot retains its exact sampling time")
        XCTAssertEqual(frozen.sampledAt, 0.2)
    }

    func testLeftRightOtherClicksHaveDistinctColorsAtLowerLeftNormalizedPoints() throws {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        for (button, x) in [(RecordingInputClickButton.left, 0.2), (.right, 0.5), (.other, 0.8)] {
            state.recordClick(button: button, normalizedPoint: CGPoint(x: x, y: 0.7), at: 0, token: token)
        }
        let image = try raster(state.snapshot(at: 0), transparent: true)
        let left = image.colors(in: CGRect(x: 49, y: 125, width: 28, height: 28))
        let right = image.colors(in: CGRect(x: 145, y: 125, width: 28, height: 28))
        let other = image.colors(in: CGRect(x: 241, y: 125, width: 28, height: 28))
        XCTAssertTrue(left.contains { $0[0] > 245 && $0[1] > 180 && $0[2] < 45 && $0[3] > 245 })
        XCTAssertTrue(right.contains { $0[0] > 245 && $0[1] < 90 && $0[2] > 160 && $0[3] > 245 })
        XCTAssertTrue(other.contains { $0[0] < 65 && $0[1] > 205 && $0[2] > 245 && $0[3] > 245 })
        XCTAssertTrue(image.colors(in: CGRect(x: 0, y: 0, width: 320, height: 100)).allSatisfy { $0[3] == 0 },
                      "Lower-left input coordinates must not be vertically inverted")
    }

    func testScrollDrawsBothAxesWithCorrectSigns() throws {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        state.recordScroll(deltaX: 40, deltaY: -40, normalizedPoint: point, at: 0, token: token)
        let image = try raster(state.snapshot(at: 0), transparent: true)
        XCTAssertGreaterThan(image.alphaCount(in: CGRect(x: 170, y: 94, width: 23, height: 11)), 0)
        XCTAssertGreaterThan(image.alphaCount(in: CGRect(x: 154, y: 65, width: 11, height: 24)), 0)
        XCTAssertEqual(image.alphaCount(in: CGRect(x: 125, y: 94, width: 20, height: 11)), 0)
        XCTAssertEqual(image.alphaCount(in: CGRect(x: 154, y: 110, width: 11, height: 25)), 0)
    }

    func testShortcutBadgeUsesNewestChordAndPreservesPixelsOutsideItsBounds() throws {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        state.recordShortcut(keyCode: 8, modifiers: .command, at: 0, token: token)
        state.recordShortcut(keyCode: 9, modifiers: .command, at: 0.1, token: token)
        let snapshot = state.snapshot(at: 0.1)
        let onlyNewest = RecordingInputEffectsSnapshot(revision: snapshot.revision, sampledAt: snapshot.sampledAt,
            events: Array(snapshot.events.suffix(1)))
        let rendered = try raster(snapshot, transparent: true)
        XCTAssertEqual(rendered.bytes, try raster(onlyNewest, transparent: true).bytes)
        XCTAssertGreaterThan(rendered.alphaCount(in: CGRect(x: 100, y: 12, width: 120, height: 30)), 0)
        XCTAssertEqual(rendered.alphaCount(in: CGRect(x: 0, y: 43, width: 320, height: 157)), 0)
    }

    func testRendererPreservesSourceAlphaAndColorOutsideEffectsAndRejectsInvalidSizes() throws {
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        state.recordClick(button: .left, normalizedPoint: point, at: 0, token: token)
        let snapshot = state.snapshot(at: 0)
        let empty = RecordingInputEffectsSnapshot(revision: 0, sampledAt: 0, events: [])
        let baseline = try raster(empty)
        let changed = try raster(snapshot)
        XCTAssertEqual(changed.pixel(x: 2, y: 2), baseline.pixel(x: 2, y: 2))
        XCTAssertTrue(stride(from: 3, to: changed.bytes.count, by: 4).allSatisfy { changed.bytes[$0] == 255 })
        for size in [CGSize(width: CGFloat.nan, height: 200), CGSize(width: 320, height: CGFloat.infinity),
                     CGSize(width: 0, height: 200), CGSize(width: 100_000, height: 200),
                     CGSize(width: 3_840, height: 3_840)] {
            XCTAssertEqual(try raster(snapshot, drawingSize: size).bytes, baseline.bytes)
        }
        let translucentBaseline = try raster(empty, backgroundAlpha: 0.4)
        let translucent = try raster(snapshot, backgroundAlpha: 0.4)
        XCTAssertEqual(translucent.pixel(x: 2, y: 2), translucentBaseline.pixel(x: 2, y: 2))
        XCTAssertGreaterThan(translucent.pixel(x: 159, y: 99)[3], translucentBaseline.pixel(x: 159, y: 99)[3])
    }

    func testRendererRestoresCallerGraphicsState() throws {
        let context = try makeContext()
        context.setAlpha(0.3); context.setLineWidth(7)
        context.translateBy(x: 2, y: 3)
        let transform = context.ctm
        let state = RecordingInputEffectsState(), token = state.beginSession(options: all, at: 0)
        state.recordClick(button: .left, normalizedPoint: point, at: 0, token: token)
        RecordingInputEffectsRenderer.draw(state.snapshot(at: 0), in: context, size: CGSize(width: 320, height: 200))
        XCTAssertEqual(context.ctm, transform)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        let output = try bytes(context)
        XCTAssertEqual(Double(output.pixel(x: 3, y: 4)[3]), 77, accuracy: 1,
                       "Caller alpha must be restored after painting effects")
    }

    private func makeContext() throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 320 * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func raster(_ snapshot: RecordingInputEffectsSnapshot, at time: TimeInterval? = nil,
                        transparent: Bool = false, drawingSize: CGSize = CGSize(width: 320, height: 200),
                        backgroundAlpha: CGFloat = 1) throws -> InputEffectPixels {
        let context = try makeContext()
        context.clear(CGRect(x: 0, y: 0, width: 320, height: 200))
        if !transparent {
            context.setFillColor(CGColor(srgbRed: 0.24, green: 0.4, blue: 0.6, alpha: backgroundAlpha))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        }
        if let time {
            RecordingInputEffectsRenderer.draw(snapshot, in: context, size: drawingSize, at: time)
        } else {
            RecordingInputEffectsRenderer.draw(snapshot, in: context, size: drawingSize)
        }
        return try bytes(context)
    }

    private func bytes(_ context: CGContext) throws -> InputEffectPixels {
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return InputEffectPixels(bytes: Array(UnsafeBufferPointer(start: pointer, count: 320 * 200 * 4)))
    }
}

private struct InputEffectPixels {
    let bytes: [UInt8]

    func pixel(x: Int, y: Int) -> [UInt8] {
        // Bitmap memory rows run from top to bottom; all assertions use the
        // same lower-left canvas contract as the production compositor.
        let offset = ((200 - 1 - y) * 320 + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    func colors(in rect: CGRect) -> [[UInt8]] {
        (Int(rect.minY)..<Int(rect.maxY)).flatMap { y in
            (Int(rect.minX)..<Int(rect.maxX)).map { x in pixel(x: x, y: y) }
        }
    }

    func alphaCount(in rect: CGRect) -> Int { colors(in: rect).filter { $0[3] > 0 }.count }
}
