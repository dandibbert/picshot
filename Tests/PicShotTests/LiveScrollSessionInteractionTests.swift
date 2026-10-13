import XCTest
import AppKit
import PicShotCore
@testable import PicShot

/// Owned native controls and synthetic acquisition only: no capture permissions,
/// global input, clipboard writes, or real-time waits for the capture budget.
@MainActor
final class LiveScrollSessionInteractionTests: XCTestCase {
    func testLongPauseExcludesDrainAndIdleTimeAndExactActiveLimitKeepsCopyAndFinish() async throws {
        try await withSession { session, source, seed, output, clock in
            let toolbar = try Self.toolbar(session)
            clock.now += 179
            source.holdDrain = true
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { source.hasPendingDrain }
            clock.now += 4_000
            XCTAssertEqual(session.activeCaptureDurationForVerification, 179)
            source.releaseDrain()
            try await Self.waitUntil { !session.snapshotForVerification.busy }
            clock.now += 8_000
            XCTAssertEqual(session.activeCaptureDurationForVerification, 179)

            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { !session.snapshotForVerification.paused && !session.snapshotForVerification.busy }
            XCTAssertEqual(source.resumeCalls, 1)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 179)
            XCTAssertFalse(session.captureLimitReachedForVerification)
            try await Self.waitUntil { source.mailbox.counters.waitingReaders == 1 }
            clock.now += 1
            source.offer(seed) // Wake the normal sampling loop, without waiting 180 seconds.
            try await Self.waitUntil { session.captureLimitReachedForVerification && source.pauseCalls == 2 }
            try await Self.waitUntil { session.snapshotForVerification.statusKind == .paused }
            try Self.assertTerminalControls(session)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 180)
            clock.now += 9_000
            XCTAssertEqual(session.activeCaptureDurationForVerification, 180)
            toolbar.pauseButton.performClick(nil)
            XCTAssertEqual(source.resumeCalls, 1)

            try PortableSettingsUIPreviewFixture.click(toolbar.copyButton)
            try await Self.waitUntil { session.isClosedForVerification }
            XCTAssertEqual(output.copies, 1); XCTAssertEqual(output.finishes, 0)
            XCTAssertEqual(try Self.pixels(XCTUnwrap(output.image)), try Self.pixels(seed))
        }
    }

    func testContinueAtExactly180ActiveSecondsCannotResumeSource() async throws {
        try await withSession { session, source, _, _, clock in
            let toolbar = try Self.toolbar(session)
            clock.now += 180
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { session.snapshotForVerification.paused && !session.snapshotForVerification.busy }
            clock.now += 6_000
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            XCTAssertTrue(session.captureLimitReachedForVerification)
            XCTAssertEqual(source.resumeCalls, 0)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 180)
            try Self.assertTerminalControls(session)
        }
    }

    func testEarlyHandleReleaseAppliesOnceAfterDrainAndExcludesMovementTime() async throws {
        try await withSession { session, source, _, output, clock in
            let handle = try Self.handle(session)
            let original = source.region
            let preview = try XCTUnwrap(Self.thumbnail(session).image)
            let start = try Self.handleCenter(handle)
            clock.now += 17
            source.holdDrain = true
            try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
            try await Self.waitUntil { source.hasPendingDrain }
            try Self.pointer(.leftMouseDragged, handle: handle, screenPoint: start.offsetBy(dx: 20, dy: -35))
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start)
            clock.now += 10_000
            XCTAssertFalse(handle.isDragging)
            XCTAssertTrue(session.snapshotForVerification.busy)
            XCTAssertFalse(session.snapshotForVerification.previewPositionVerified)
            XCTAssertEqual(session.activeCaptureDurationForVerification, 17)
            XCTAssertEqual(source.region, original)
            XCTAssertEqual(source.moveCalls, 0); XCTAssertEqual(source.resumeCalls, 0)
            XCTAssertTrue(try Self.thumbnail(session).image === preview)

            source.releaseDrain(); source.releaseDrain()
            try await Self.waitUntil { !session.snapshotForVerification.busy && !session.snapshotForVerification.paused }
            XCTAssertEqual(source.region, original.offsetBy(dx: 0, dy: 60))
            XCTAssertEqual(source.operations, ["pause", "move", "resume"])
            XCTAssertEqual(session.activeCaptureDurationForVerification, 17)
            XCTAssertFalse(session.snapshotForVerification.previewPositionVerified)
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 80, dy: -90))
            handle.cancelOperation(nil)
            XCTAssertEqual(source.moveCalls, 1); XCTAssertEqual(source.resumeCalls, 1)
            XCTAssertEqual(output.finishes + output.copies, 0)
        }
    }

    func testCancelledHandleRollsBackAndRepeatedCompletionCannotApplyOrResumeTwice() async throws {
        try await withSession { session, source, _, _, _ in
            let controls = try XCTUnwrap(session.controlsForVerification)
            let handle = try Self.handle(session)
            let original = source.region
            let outline = controls.outlineWindow?.frame
            let start = try Self.handleCenter(handle)
            let staleEnd = handle.end
            source.holdDrain = true
            try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
            try await Self.waitUntil { source.hasPendingDrain }
            try Self.pointer(.leftMouseDragged, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
            XCTAssertNotEqual(controls.outlineWindow?.frame, outline)
            handle.cancelOperation(nil)
            XCTAssertEqual(controls.outlineWindow?.frame, outline)
            handle.cancelOperation(nil); staleEnd?(start)
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
            XCTAssertEqual(source.region, original)
            XCTAssertEqual(source.moveCalls, 0); XCTAssertEqual(source.resumeCalls, 0)

            source.releaseDrain()
            try await Self.waitUntil { !session.snapshotForVerification.busy && !session.snapshotForVerification.paused }
            staleEnd?(start); staleEnd?(nil); source.releaseDrain()
            XCTAssertEqual(source.operations, ["pause", "resume"])
            XCTAssertEqual(source.region, original)
            XCTAssertEqual(controls.outlineWindow?.frame, outline)
            XCTAssertTrue(session.snapshotForVerification.canFinish)
            XCTAssertFalse(session.snapshotForVerification.previewPositionVerified)
        }
    }

    func testCloseDuringHeldDragDrainMakesLateCompletionInert() async throws {
        try await withSession { session, source, _, output, _ in
            var closes = 0
            session.onClose = { closes += 1 }
            let controls = try XCTUnwrap(session.controlsForVerification)
            let handle = try Self.handle(session)
            let start = try Self.handleCenter(handle)
            let original = source.region
            let staleEnd = handle.end
            source.holdDrain = true
            try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
            try await Self.waitUntil { source.hasPendingDrain }
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
            let beforeClose = session.snapshotForVerification
            session.cancel()
            XCTAssertTrue(controls.isRetired)
            XCTAssertNil(session.controlsForVerification)
            XCTAssertFalse(session.isClosedForVerification)
            XCTAssertEqual(closes, 0)
            XCTAssertEqual(output.finishes + output.copies, 0)
            source.releaseDrain(); source.releaseDrain()
            try await Self.waitUntil { source.completedDrains == 1 && session.isClosedForVerification }
            XCTAssertEqual(closes, 1)
            staleEnd?(start); handle.cancelOperation(nil)
            XCTAssertEqual(source.region, original)
            XCTAssertEqual(source.moveCalls, 0); XCTAssertEqual(source.resumeCalls, 0)
            XCTAssertEqual(source.stopCalls, 1)
            XCTAssertEqual(output.finishes + output.copies, 0)
            XCTAssertEqual(session.snapshotForVerification, beforeClose)
            XCTAssertNil(session.controlsForVerification)
            XCTAssertNil(handle.begin); XCTAssertNil(handle.move); XCTAssertNil(handle.end)
            XCTAssertEqual(closes, 1)
        }
    }

    func testCloseDuringHeldResumeCannotPublishAfterMoveOrRejectedMoveRecovery() async throws {
        for rejectMove in [false, true] {
            try await withSession { session, source, _, output, clock in
                var closes = 0
                session.onClose = { closes += 1 }
                let handle = try Self.handle(session)
                let start = try Self.handleCenter(handle)
                let original = source.region
                clock.now += 33
                source.holdResume = true
                source.failure = rejectMove ? .move : nil
                try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
                try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
                try await Self.waitUntil { source.hasPendingResume }
                clock.now += 9_000
                XCTAssertEqual(session.activeCaptureDurationForVerification, 33)
                let beforeClose = session.snapshotForVerification
                session.cancel()
                XCTAssertNil(session.controlsForVerification)
                XCTAssertFalse(session.isClosedForVerification)
                XCTAssertEqual(closes, 0)
                XCTAssertEqual(output.finishes + output.copies, 0)
                source.releaseResume(); source.releaseResume()
                try await Self.waitUntil { source.completedResumes == 1 && session.isClosedForVerification }
                XCTAssertEqual(closes, 1)
                XCTAssertEqual(source.moveCalls, 1); XCTAssertEqual(source.resumeCalls, 1)
                XCTAssertEqual(source.region, rejectMove ? original : original.offsetBy(dx: 0, dy: 60))
                XCTAssertEqual(source.stopCalls, 1)
                XCTAssertEqual(session.activeCaptureDurationForVerification, 33)
                XCTAssertEqual(session.snapshotForVerification, beforeClose)
                XCTAssertEqual(output.finishes + output.copies, 0)
                XCTAssertNil(session.controlsForVerification)
                XCTAssertEqual(closes, 1)
            }
        }
    }

    func testDragPauseMoveAndResumeFailuresRetainLastPreviewAndFinishPixels() async throws {
        for failure in [Failure.pause, .move, .resume] {
            try await withSession { session, source, seed, output, _ in
                let before = session.snapshotForVerification
                let preview = try XCTUnwrap(Self.thumbnail(session).image)
                let original = source.region
                source.failure = failure
                let handle = try Self.handle(session)
                let start = try Self.handleCenter(handle)
                try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
                try Self.pointer(.leftMouseUp, handle: handle, screenPoint: start.offsetBy(dx: 40, dy: -60))
                try await Self.waitUntil {
                    session.snapshotForVerification.statusKind == .error && !session.snapshotForVerification.busy
                }
                let failed = session.snapshotForVerification
                XCTAssertEqual(failed.acceptedFrames, before.acceptedFrames)
                XCTAssertEqual(failed.pixelWidth, before.pixelWidth); XCTAssertEqual(failed.pixelHeight, before.pixelHeight)
                XCTAssertTrue(failed.canFinish); XCTAssertTrue(failed.canCopy)
                XCTAssertFalse(failed.previewPositionVerified)
                XCTAssertTrue(try Self.thumbnail(session).image === preview)
                XCTAssertEqual(source.region, failure == .resume ? original.offsetBy(dx: 0, dy: 60) : original)
                XCTAssertEqual(source.resumeCalls, failure == .pause ? 0 : 1)
                XCTAssertEqual(failed.paused, failure != .move)
                XCTAssertEqual(output.finishes + output.copies, 0)

                source.failure = nil
                let toolbar = try Self.toolbar(session)
                if failure == .move {
                    // The move failed but restoring the old source succeeded.
                    // A real click must do the Pause action advertised by the UI.
                    XCTAssertEqual(toolbar.pauseButton.accessibilityLabel(), "暂停捕获")
                    XCTAssertEqual(toolbar.pauseButton.toolTip, "暂停捕获")
                    XCTAssertEqual(toolbar.statusLabel.stringValue, failed.status)
                    let pauses = source.pauseCalls
                    try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
                    try await Self.waitUntil {
                        session.snapshotForVerification.paused && !session.snapshotForVerification.busy
                    }
                    XCTAssertEqual(source.pauseCalls, pauses + 1)
                    XCTAssertEqual(source.resumeCalls, 1)
                    XCTAssertEqual(toolbar.pauseButton.accessibilityLabel(), "继续捕获")
                    XCTAssertFalse(session.snapshotForVerification.autoScrolling)
                    XCTAssertEqual(session.snapshotForVerification.pixelWidth, before.pixelWidth)
                    XCTAssertEqual(session.snapshotForVerification.pixelHeight, before.pixelHeight)
                    XCTAssertTrue(try Self.thumbnail(session).image === preview)
                } else {
                    XCTAssertEqual(toolbar.pauseButton.accessibilityLabel(), "重试捕获")
                }
                try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
                try await Self.waitUntil { session.isClosedForVerification }
                XCTAssertEqual(output.finishes, 1); XCTAssertEqual(output.copies, 0)
                XCTAssertEqual(try Self.pixels(XCTUnwrap(output.image)), try Self.pixels(seed))
            }
        }
    }

    private func withSession(_ body: (LiveScrollSessionController, Source, CGImage, Output, Clock) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for session controls") }
        let source = Source(displayBounds: screen.frame), output = Output(), clock = Clock()
        let seed = try Self.image()
        let session = LiveScrollSessionController(onComplete: { output.image = $0; output.finishes += 1 },
            onImport: { XCTFail("This regression must not open an importer") },
            onCopy: { output.image = $0; output.copies += 1 }, monotonicNow: { clock.now })
        do {
            try await session.startForVerification(source: source, screen: screen)
            source.offer(seed)
            try await Self.waitUntil { session.snapshotForVerification.acceptedFrames == 1 }
            try await body(session, source, seed, output, clock)
        } catch {
            source.releaseDrain(); source.releaseResume()
            await session.closeForVerification()
            throw error
        }
        source.releaseDrain(); source.releaseResume()
        await session.closeForVerification()
        XCTAssertTrue(session.isClosedForVerification)
    }

    private static func assertTerminalControls(_ session: LiveScrollSessionController) throws {
        let state = session.snapshotForVerification, toolbar = try Self.toolbar(session)
        XCTAssertTrue(state.paused); XCTAssertFalse(state.busy)
        XCTAssertFalse(state.canPause); XCTAssertFalse(state.canMoveRegion); XCTAssertFalse(state.canAutoScroll)
        XCTAssertFalse(state.canChangeAxis)
        XCTAssertTrue(state.canFinish); XCTAssertTrue(state.canCopy)
        XCTAssertFalse(toolbar.pauseButton.isEnabled); XCTAssertFalse(try handle(session).isEnabled)
        XCTAssertTrue(toolbar.finishButton.isEnabled); XCTAssertTrue(toolbar.copyButton.isEnabled)
        XCTAssertFalse(try XCTUnwrap(toolbar.moreButton.menu?.items.first {
            $0.identifier?.rawValue == "scroll.live.moveRegion"
        }).isEnabled)
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for the synthetic session transition")
                throw Failure.timedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private static func toolbar(_ session: LiveScrollSessionController) throws -> LiveScrollToolbarView {
        try XCTUnwrap(session.controlsForVerification?.toolbarWindow?.contentView as? LiveScrollToolbarView)
    }
    private static func thumbnail(_ session: LiveScrollSessionController) throws -> LiveScrollThumbnailView {
        try XCTUnwrap(session.controlsForVerification?.previewWindow?.contentView as? LiveScrollThumbnailView)
    }
    private static func handle(_ session: LiveScrollSessionController) throws -> LiveScrollRegionDragHandle {
        try XCTUnwrap(session.controlsForVerification?.handleWindow?.contentView as? LiveScrollRegionDragHandle)
    }
    private static func handleCenter(_ view: NSView) throws -> CGPoint {
        let frame = try XCTUnwrap(view.window).frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    private static func pointer(_ type: NSEvent.EventType, handle: LiveScrollRegionDragHandle, screenPoint: CGPoint) throws {
        let window = try XCTUnwrap(handle.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: handle.mouseDown(with: event)
        case .leftMouseDragged: handle.mouseDragged(with: event)
        case .leftMouseUp: handle.mouseUp(with: event)
        default: XCTFail("Unsupported owned pointer event")
        }
    }
    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 200, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 200))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1)); context.fill(CGRect(x: 7, y: 13, width: 29, height: 83))
        return try XCTUnwrap(context.makeImage())
    }
    private static func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private enum Failure: Error, Equatable { case pause, move, resume, timedOut }
    @MainActor private final class Clock { var now: TimeInterval = 1_000 }
    @MainActor private final class Output { var image: CGImage?; var finishes = 0; var copies = 0 }

    @MainActor private final class Source: LiveScrollFrameSource {
        var region = CGRect(x: 20, y: 30, width: 64, height: 200)
        let displayBounds: CGRect
        var target: LiveScrollScreenSource.Target? { nil }
        let mailbox = LiveScrollFrameMailbox<LiveScrollScreenSource.Frame>()
        var failure: Failure?
        var holdDrain = false
        var holdResume = false
        var hasPendingDrain: Bool { drain != nil }
        var hasPendingResume: Bool { resumption != nil }
        private(set) var pauseCalls = 0, resumeCalls = 0, moveCalls = 0, stopCalls = 0, completedDrains = 0
        private(set) var completedResumes = 0
        private(set) var operations: [String] = []
        private var generation: UInt64 = 0, sequence: UInt64 = 0
        private var running = false, stopped = false
        private var drain: CheckedContinuation<Void, Never>?
        private var resumption: CheckedContinuation<Void, Never>?

        init(displayBounds: CGRect) { self.displayBounds = displayBounds }
        func start() async throws {
            guard !stopped else { throw LiveScrollSourceError.stopped }
            generation &+= 1; running = true
            mailbox.activate(generation: generation, width: 64, height: 200)
        }
        func resume() async throws {
            resumeCalls += 1; operations.append("resume")
            if failure == .resume { throw Failure.resume }
            try await start()
            if holdResume {
                holdResume = false
                await withCheckedContinuation { resumption = $0 }
            }
            completedResumes += 1
        }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            let token = generation
            let frame = try await mailbox.next(generation: token, timeout: timeout)
            try Task.checkCancellation()
            guard running, generation == token else { throw CancellationError() }
            return frame
        }
        func offer(_ image: CGImage) {
            sequence &+= 1
            mailbox.offer(.init(image: image, sequence: sequence, generation: generation,
                timestamp: TimeInterval(sequence), region: region), generation: generation)
        }
        func pauseAndDrain() async throws {
            pauseCalls += 1; operations.append("pause"); halt()
            if holdDrain {
                holdDrain = false
                await withCheckedContinuation { drain = $0 }
            }
            completedDrains += 1
            if failure == .pause { throw Failure.pause }
        }
        func releaseDrain() {
            let pending = drain; drain = nil; pending?.resume()
        }
        func releaseResume() {
            let pending = resumption; resumption = nil; pending?.resume()
        }
        func stop() async throws {
            stopCalls += 1; stopped = true; halt()
            // Deliberately leave an already-held drain outstanding so the test
            // can complete it after retirement and exercise stale-task guards.
        }
        func moveRegion(to proposed: CGRect) throws {
            moveCalls += 1; operations.append("move")
            if failure == .move { throw Failure.move }
            guard !running, !stopped, drain == nil else { throw CaptureError.busy }
            region = proposed
        }
        func validateTarget() throws { }
        private func halt() {
            let token = generation
            running = false; generation &+= 1; mailbox.close(generation: token)
        }
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
