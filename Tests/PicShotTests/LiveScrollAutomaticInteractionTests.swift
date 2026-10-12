import XCTest
import AppKit
import PicShotCore
@testable import PicShot

/// Production session, mailbox, assembler and owned AppKit controls. The input
/// sink records CGEvents without posting them; permission and elapsed policy
/// time are injected. No desktop capture, TCC request or clipboard write occurs.
@MainActor
final class LiveScrollAutomaticInteractionTests: XCTestCase {
    func testSlowFirstFrameCannotArmAutoBeforeVerifiedSeed() async throws {
        try await withSession(seed: false) { fixture in
            let toolbar = try fixture.toolbar()
            XCTAssertFalse(fixture.session.snapshotForVerification.previewPositionVerified)
            XCTAssertFalse(toolbar.autoButton.isEnabled)
            toolbar.autoButton.performClick(nil)
            fixture.clock.now += 12
            try await fixture.deliverIdle()
            XCTAssertEqual(fixture.input.events.count, 0)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertFalse(fixture.session.snapshotForVerification.canAutoScroll)

            try await fixture.deliver(Self.image(origin: 0))
            XCTAssertTrue(fixture.session.snapshotForVerification.previewPositionVerified)
            XCTAssertTrue(toolbar.autoButton.isEnabled)
            try fixture.startAuto()
            XCTAssertEqual(fixture.input.events.count, 1)
            XCTAssertTrue(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertFalse(fixture.session.snapshotForVerification.previewPositionVerified,
                           "Posting input invalidates the previously verified current position")
            try await fixture.finish(origin: 0, length: 200)
        }
    }

    func testNilFramesCannotRepeatOutstandingStepAndThreeSecondTimeoutKeepsManualCapture() async throws {
        try await withSession { fixture in
            try fixture.startAuto()
            let emittedAt = fixture.clock.now
            for elapsed in [0.75, 1.5, 2.999] {
                fixture.clock.now = emittedAt + elapsed
                try await fixture.deliverIdle()
                XCTAssertEqual(fixture.input.events.count, 1)
                XCTAssertTrue(fixture.session.snapshotForVerification.autoScrolling)
            }
            fixture.clock.now = emittedAt + 3
            try await fixture.deliverIdle()
            try fixture.assertStoppedWithManualCapture()
            XCTAssertEqual(fixture.input.events.count, 1)
            let warning = fixture.session.snapshotForVerification.status
            XCTAssertFalse(warning.contains("底"), "A missing frame does not prove the page reached its bottom")
            XCTAssertFalse(warning.contains("页面已无移动"))

            fixture.clock.now += 1
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.session.stateForVerification.viewportOffset, 24)
            XCTAssertEqual(fixture.input.events.count, 1, "Manual progress must not silently rearm Auto")
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            try await fixture.finish(origin: 0, length: 224)
        }
    }

    func testDuplicateEndpointFramesCannotAcknowledgeOrResetNoProgressDeadline() async throws {
        try await withSession { fixture in
            let seed = try Self.image(origin: 0)
            let preview = try XCTUnwrap(fixture.thumbnail().image)
            try fixture.startAuto()
            let emittedAt = fixture.clock.now
            for elapsed in [0.4, 1.2, 2.4, 2.999] {
                fixture.clock.now = emittedAt + elapsed
                try await fixture.deliver(seed)
                XCTAssertEqual(fixture.input.events.count, 1)
                XCTAssertTrue(fixture.session.snapshotForVerification.autoScrolling)
                XCTAssertEqual(fixture.session.snapshotForVerification.acceptedFrames, 1)
            }
            fixture.clock.now = emittedAt + 3
            try await fixture.deliver(seed)
            try fixture.assertStoppedWithManualCapture()
            XCTAssertEqual(fixture.input.events.count, 1)
            XCTAssertTrue(try fixture.thumbnail().image === preview)
            try await fixture.finish(origin: 0, length: 200)
        }
    }

    func testFreshForwardProgressReleasesOneStepOnlyAfterMinimumCadence() async throws {
        try await withSession { fixture in
            try fixture.startAuto()
            let emittedAt = fixture.clock.now
            fixture.clock.now = emittedAt + 0.1
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.session.stateForVerification.viewportOffset, 24)
            XCTAssertEqual(fixture.input.events.count, 1, "A matched response must still respect the 0.35s cadence")
            fixture.clock.now = emittedAt + 0.349
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.input.events.count, 1)
            fixture.clock.now = emittedAt + 0.351
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.input.events.count, 2)
            let first = try XCTUnwrap(fixture.input.events.first)
            let second = try XCTUnwrap(fixture.input.events.dropFirst().first)
            XCTAssertGreaterThanOrEqual(second.time - first.time, 0.35)

            fixture.clock.now += 0.5
            try await fixture.deliver(Self.image(origin: 24))
            try await fixture.deliverIdle()
            XCTAssertEqual(fixture.input.events.count, 2, "The next outstanding step needs its own forward response")
            try await fixture.deliver(Self.image(origin: 48))
            XCTAssertEqual(fixture.input.events.count, 3)
            XCTAssertEqual(fixture.session.stateForVerification.viewportOffset, 48)
            XCTAssertTrue(fixture.input.events.allSatisfy { $0.type == .scrollWheel })
            XCTAssertTrue(fixture.input.events.allSatisfy {
                $0.location == CGPoint(x: fixture.source.displayBounds.minX + fixture.source.region.midX,
                                      y: fixture.source.displayBounds.minY + fixture.source.region.midY)
            })
            try await fixture.finish(origin: 0, length: 248)
        }
    }

    func testProducerQueuedForwardFrameCannotAcknowledgeStepUntilPostFenceObservation() async throws {
        try await withSession { fixture in
            let advanced = try Self.image(origin: 24)
            fixture.input.afterRecord = {
                fixture.input.afterRecord = nil
                // This frame exists before input delivery returns. The session
                // must fence the producer's latest sequence, not its last read.
                fixture.source.offer(advanced)
            }
            let reads = fixture.source.readCalls
            try fixture.startAuto()
            fixture.clock.now += 0.4
            try await Self.waitUntil { fixture.source.readCalls > reads && fixture.source.mailbox.counters.waitingReaders == 1 }
            XCTAssertEqual(fixture.session.stateForVerification.viewportOffset, 24)
            XCTAssertEqual(fixture.input.events.count, 1, "A queued pre-fence image cannot acknowledge the just-issued step")
            XCTAssertTrue(fixture.session.snapshotForVerification.autoScrolling)

            fixture.clock.now += 0.1
            try await fixture.deliver(advanced)
            XCTAssertEqual(fixture.input.events.count, 1,
                           "A fresh duplicate proves no movement beyond the already queued viewport")
            try await fixture.deliver(Self.image(origin: 48))
            XCTAssertEqual(fixture.input.events.count, 2,
                           "Fresh forward movement after the producer fence releases one next step")
            try await fixture.finish(origin: 0, length: 248)
        }
    }

    func testRapidAutoOffOnCannotBypassMinimumInputCadence() async throws {
        try await withSession { fixture in
            let toolbar = try fixture.toolbar()
            try fixture.startAuto()
            let emittedAt = fixture.clock.now
            try PortableSettingsUIPreviewFixture.click(toolbar.autoButton)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertFalse(fixture.session.snapshotForVerification.previewPositionVerified)
            XCTAssertFalse(toolbar.autoButton.isEnabled)
            toolbar.autoButton.performClick(nil)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertEqual(fixture.input.events.count, 1)
            fixture.clock.now = emittedAt + 0.1
            try await fixture.deliver(Self.image(origin: 0))
            XCTAssertTrue(fixture.session.snapshotForVerification.previewPositionVerified)
            XCTAssertTrue(toolbar.autoButton.isEnabled)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            try fixture.startAuto()
            XCTAssertTrue(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertEqual(fixture.input.events.count, 1, "Re-enabling Auto cannot bypass its minimum input interval")
            fixture.clock.now = emittedAt + 0.349
            try await fixture.deliverIdle()
            XCTAssertEqual(fixture.input.events.count, 1)
            fixture.clock.now = emittedAt + 0.351
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.input.events.count, 2)
            let first = try XCTUnwrap(fixture.input.events.first)
            let second = try XCTUnwrap(fixture.input.events.dropFirst().first)
            XCTAssertGreaterThanOrEqual(second.time - first.time, 0.35)
            try await fixture.finish(origin: 0, length: 224)
        }
    }

    func testStaleSequenceAndGenerationCannotReleaseOutstandingStepOrChangeAcceptedPixels() async throws {
        try await withSession { fixture in
            let sequence = fixture.source.sequence
            let generation = fixture.source.generation
            try fixture.startAuto()
            fixture.clock.now += 0.5
            for identity in [(generation, sequence), (generation, sequence - 1), (generation - 1, sequence + 1)] {
                try await fixture.deliver(Self.image(origin: 24), sequence: identity.1, generation: identity.0)
                XCTAssertEqual(fixture.input.events.count, 1)
                XCTAssertEqual(fixture.session.stateForVerification.viewportOffset, 0)
                XCTAssertEqual(fixture.session.snapshotForVerification.acceptedFrames, 1)
            }
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.session.stateForVerification.viewportOffset, 24)
            XCTAssertEqual(fixture.input.events.count, 2)
            try await fixture.finish(origin: 0, length: 224)
        }
    }

    func testReverseMovementStopsAutoAndMatchedRecoveryRequiresExplicitToggle() async throws {
        try await withSession { fixture in
            try await fixture.deliver(Self.image(origin: 48))
            try fixture.startAuto()
            fixture.clock.now += 0.5
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.session.stateForVerification.viewportOffset, 24)
            try fixture.assertStoppedWithManualCapture()
            XCTAssertEqual(fixture.input.events.count, 1)

            fixture.clock.now += 0.5
            try await fixture.deliver(Self.image(origin: 48))
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertEqual(fixture.input.events.count, 1)
            XCTAssertTrue(fixture.session.snapshotForVerification.canAutoScroll)
            try fixture.startAuto()
            XCTAssertEqual(fixture.input.events.count, 2)
            try await fixture.finish(origin: 0, length: 248)
        }
    }

    func testMismatchDisablesAutoUntilRecoveredAndDoesNotReplaceLastGoodPixels() async throws {
        try await withSession { fixture in
            let preview = try XCTUnwrap(fixture.thumbnail().image)
            try fixture.startAuto()
            fixture.clock.now += 0.5
            try await fixture.deliver(Self.image(origin: 0, salt: 101))
            try fixture.assertStoppedWithManualCapture()
            XCTAssertFalse(fixture.session.snapshotForVerification.previewPositionVerified)
            XCTAssertFalse(try fixture.toolbar().autoButton.isEnabled)
            XCTAssertTrue(try fixture.thumbnail().image === preview)
            XCTAssertEqual(fixture.session.snapshotForVerification.acceptedFrames, 1)
            try fixture.toolbar().autoButton.performClick(nil)
            XCTAssertEqual(fixture.input.events.count, 1)

            try await fixture.deliver(Self.image(origin: 0))
            XCTAssertTrue(fixture.session.snapshotForVerification.previewPositionVerified)
            XCTAssertTrue(try fixture.toolbar().autoButton.isEnabled)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertEqual(fixture.input.events.count, 1)
            try fixture.startAuto()
            XCTAssertEqual(fixture.input.events.count, 2)
            fixture.clock.now += 0.5
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.input.events.count, 3)
            try await fixture.finish(origin: 0, length: 224)
        }
    }

    func testPauseAndResumeDiscardOutstandingStepWithoutRearming() async throws {
        try await withSession { fixture in
            let toolbar = try fixture.toolbar()
            try fixture.startAuto()
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { fixture.session.snapshotForVerification.paused && !fixture.session.snapshotForVerification.busy }
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertFalse(toolbar.autoButton.isEnabled)
            XCTAssertEqual(fixture.source.pauseCalls, 1)
            fixture.clock.now += 30
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil { !fixture.session.snapshotForVerification.paused && !fixture.session.snapshotForVerification.busy }
            XCTAssertEqual(fixture.source.resumeCalls, 1)
            XCTAssertFalse(toolbar.autoButton.isEnabled, "Resuming requires a new verified current position")
            try await fixture.deliverIdle()
            XCTAssertEqual(fixture.input.events.count, 1)
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertTrue(toolbar.autoButton.isEnabled)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertEqual(fixture.input.events.count, 1)
            try fixture.startAuto()
            XCTAssertEqual(fixture.input.events.count, 2)
            try await fixture.finish(origin: 0, length: 224)
        }
    }

    func testOwnedRegionDragDiscardsOutstandingStepAndRequiresFreshPosition() async throws {
        try await withSession { fixture in
            let handle = try XCTUnwrap(fixture.session.controlsForVerification?.handleWindow?.contentView as? LiveScrollRegionDragHandle)
            let window = try XCTUnwrap(handle.window)
            let start = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let original = fixture.source.region
            try fixture.startAuto()
            try Self.pointer(.leftMouseDown, handle: handle, screenPoint: start)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            try Self.pointer(.leftMouseDragged, handle: handle, screenPoint: CGPoint(x: start.x + 20, y: start.y - 30))
            try Self.pointer(.leftMouseUp, handle: handle, screenPoint: CGPoint(x: start.x + 40, y: start.y - 60))
            try await Self.waitUntil { !fixture.session.snapshotForVerification.paused && !fixture.session.snapshotForVerification.busy }
            XCTAssertEqual(fixture.source.region, original.offsetBy(dx: 0, dy: 60))
            XCTAssertEqual(fixture.source.moveCalls, 1)
            XCTAssertEqual(fixture.source.resumeCalls, 1)
            XCTAssertFalse(fixture.session.snapshotForVerification.previewPositionVerified)
            XCTAssertFalse(try fixture.toolbar().autoButton.isEnabled)
            fixture.clock.now += 5
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.input.events.count, 1)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertTrue(fixture.session.snapshotForVerification.canAutoScroll)
            try fixture.startAuto()
            XCTAssertEqual(fixture.input.events.count, 2)
            try await fixture.finish(origin: 0, length: 224)
        }
    }

    func testRevokedPermissionTargetFailureAndInputFailureStopSafelyWithoutRearming() async throws {
        for failure in [Failure.permission, .target, .input] {
            try await withSession { fixture in
                try fixture.startAuto()
                fixture.clock.now += 0.5
                switch failure {
                case .permission: fixture.input.permitted = false
                case .target: fixture.source.targetFailure = true
                case .input: fixture.input.throwOnInput = true
                default: XCTFail("Unexpected failure fixture")
                }
                try await fixture.deliver(Self.image(origin: 24))
                try fixture.assertStoppedWithManualCapture()
                XCTAssertEqual(fixture.input.events.count, 1)
                XCTAssertEqual(fixture.input.attempts, failure == .input ? 2 : 1)
                if failure == .permission { XCTAssertFalse(try fixture.toolbar().autoButton.isEnabled) }

                fixture.input.permitted = true
                fixture.source.targetFailure = false
                fixture.input.throwOnInput = false
                fixture.clock.now += 0.5
                try await fixture.deliver(Self.image(origin: 48))
                XCTAssertEqual(fixture.input.events.count, 1)
                XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
                try await fixture.finish(origin: 0, length: 248)
            }
        }
    }

    func testMissingPermissionNeverEmitsEvenWithVerifiedSeed() async throws {
        try await withSession(permission: false) { fixture in
            XCTAssertTrue(fixture.session.snapshotForVerification.previewPositionVerified)
            XCTAssertFalse(try fixture.toolbar().autoButton.isEnabled)
            try fixture.toolbar().autoButton.performClick(nil)
            fixture.clock.now += 5
            try await fixture.deliver(Self.image(origin: 24))
            XCTAssertEqual(fixture.input.attempts, 0)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            try await fixture.finish(origin: 0, length: 224)
        }
    }

    func testFinishAndCloseRetireOutstandingInputAndStaleOwnedControls() async throws {
        for finish in [true, false] {
            try await withSession { fixture in
                let controls = try XCTUnwrap(fixture.session.controlsForVerification)
                let toolbar = try fixture.toolbar()
                try fixture.startAuto()
                if finish { try await fixture.finish(origin: 0, length: 200) }
                else {
                    try PortableSettingsUIPreviewFixture.click(toolbar.cancelButton)
                    try await Self.waitUntil { fixture.session.isClosedForVerification }
                }
                XCTAssertTrue(controls.isRetired)
                XCTAssertEqual(fixture.source.stopCalls, 1)
                fixture.clock.now += 10
                fixture.source.offer(try Self.image(origin: 24))
                toolbar.autoButton.performClick(nil)
                toolbar.pauseButton.performClick(nil)
                toolbar.finishButton.performClick(nil)
                toolbar.cancelButton.performClick(nil)
                XCTAssertEqual(fixture.input.events.count, 1)
                XCTAssertEqual(fixture.output.finishes, finish ? 1 : 0)
                XCTAssertEqual(fixture.output.copies, 0)
                XCTAssertNil(fixture.session.controlsForVerification)
                XCTAssertEqual(fixture.source.mailbox.counters.pendingFrames, 0)
                XCTAssertGreaterThan(fixture.source.mailbox.counters.rejectedFrames, 0)
            }
        }
    }

    func testExactActiveCaptureLimitPreventsInputFromAlreadyEnabledAutoControl() async throws {
        try await withSession { fixture in
            let toolbar = try fixture.toolbar()
            XCTAssertTrue(toolbar.autoButton.isEnabled)
            fixture.clock.now += 180
            try PortableSettingsUIPreviewFixture.click(toolbar.autoButton)
            XCTAssertEqual(fixture.input.attempts, 0, "Recheck the capture limit immediately before input delivery")
            fixture.source.offerIdle()
            try await Self.waitUntil {
                fixture.session.captureLimitReachedForVerification && fixture.source.pauseCalls == 1
                    && fixture.session.snapshotForVerification.statusKind == .paused
            }
            XCTAssertTrue(fixture.session.captureLimitReachedForVerification)
            XCTAssertFalse(fixture.session.snapshotForVerification.autoScrolling)
            XCTAssertFalse(toolbar.autoButton.isEnabled)
            XCTAssertTrue(toolbar.finishButton.isEnabled)
            try await fixture.finish(origin: 0, length: 200)
        }
    }

    private func withSession(seed: Bool = true, permission: Bool = true,
                             _ body: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for session controls") }
        let fixture = Fixture(screen: screen, permission: permission)
        do {
            try await fixture.session.startForVerification(source: fixture.source, screen: screen)
            try await Self.waitUntil { fixture.source.mailbox.counters.waitingReaders == 1 }
            if seed { try await fixture.deliver(Self.image(origin: 0)) }
            try await body(fixture)
        } catch {
            fixture.input.afterRecord = nil
            await fixture.session.closeForVerification()
            throw error
        }
        fixture.input.afterRecord = nil
        await fixture.session.closeForVerification()
        XCTAssertTrue(fixture.session.isClosedForVerification)
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for the owned automatic-scroll session transition")
                throw Failure.timedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
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

    /// Absolute document coordinates independently generate each viewport and
    /// the complete expected union. No assembler or strip-writing code is reused.
    private static func image(origin: Int, length: Int = 200, salt: UInt64 = 7) throws -> CGImage {
        let width = 64
        var data = [UInt8](repeating: 255, count: width * length * 4)
        for y in 0..<length { for x in 0..<width {
            var value = UInt64(y + origin + 10_000) &* 0x9e3779b185ebca87
            value ^= UInt64(x) &* 0xc2b2ae3d27d4eb4f
            value ^= salt
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            let pixel = UInt8(value % 216 + 20), index = (y * width + x) * 4
            data[index] = pixel; data[index + 1] = pixel; data[index + 2] = pixel
        } }
        return try XCTUnwrap(CGImage(width: width, height: length, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private enum Failure: Error, Equatable { case permission, target, input, timedOut }
    @MainActor private final class Clock { var now: TimeInterval = 1_000 }
    @MainActor private final class Output { var image: CGImage?; var finishes = 0; var copies = 0 }

    @MainActor private final class Input {
        struct Event { let time: TimeInterval; let type: CGEventType; let location: CGPoint }
        let clock: Clock
        var permitted: Bool
        var throwOnInput = false
        var afterRecord: (() -> Void)?
        private(set) var attempts = 0
        private(set) var events: [Event] = []
        init(clock: Clock, permitted: Bool) { self.clock = clock; self.permitted = permitted }
        func receive(_ event: CGEvent) throws {
            attempts += 1
            if throwOnInput { throw Failure.input }
            events.append(Event(time: clock.now, type: event.type, location: event.location))
            afterRecord?()
        }
    }

    @MainActor private final class Fixture {
        let source: Source
        let clock: Clock
        let output: Output
        let input: Input
        let session: LiveScrollSessionController

        init(screen: NSScreen, permission: Bool) {
            let source = Source(displayBounds: screen.frame), clock = Clock(), output = Output()
            let input = Input(clock: clock, permitted: permission)
            self.source = source; self.clock = clock; self.output = output; self.input = input
            session = LiveScrollSessionController(onComplete: { output.image = $0; output.finishes += 1 },
                onImport: { XCTFail("Automatic-scroll regression must not open an importer") },
                onCopy: { output.image = $0; output.copies += 1 }, monotonicNow: { clock.now },
                automaticScrollPermission: { input.permitted }, automaticScrollInput: { try input.receive($0) })
        }

        func toolbar() throws -> LiveScrollToolbarView {
            try XCTUnwrap(session.controlsForVerification?.toolbarWindow?.contentView as? LiveScrollToolbarView)
        }
        func thumbnail() throws -> LiveScrollThumbnailView {
            try XCTUnwrap(session.controlsForVerification?.previewWindow?.contentView as? LiveScrollThumbnailView)
        }
        func startAuto() throws {
            let button = try toolbar().autoButton
            XCTAssertTrue(button.isEnabled)
            try PortableSettingsUIPreviewFixture.click(button)
        }
        func deliver(_ image: CGImage, sequence: UInt64? = nil, generation: UInt64? = nil) async throws {
            let reads = source.readCalls
            source.offer(image, sequence: sequence, generation: generation)
            try await LiveScrollAutomaticInteractionTests.waitUntil {
                self.source.readCalls > reads && self.source.mailbox.counters.waitingReaders == 1
            }
        }
        func deliverIdle() async throws {
            let reads = source.readCalls
            source.offerIdle()
            try await LiveScrollAutomaticInteractionTests.waitUntil {
                self.source.readCalls > reads && self.source.mailbox.counters.waitingReaders == 1
            }
        }
        func assertStoppedWithManualCapture() throws {
            let state = session.snapshotForVerification, toolbar = try self.toolbar()
            XCTAssertFalse(state.autoScrolling)
            XCTAssertFalse(state.paused)
            XCTAssertFalse(state.busy)
            XCTAssertEqual(state.statusKind, .warning)
            XCTAssertTrue(state.canPause); XCTAssertTrue(state.canFinish); XCTAssertTrue(state.canCopy)
            XCTAssertTrue(toolbar.pauseButton.isEnabled)
            XCTAssertTrue(toolbar.finishButton.isEnabled); XCTAssertTrue(toolbar.copyButton.isEnabled)
            XCTAssertEqual(source.pauseCalls, 0)
            XCTAssertEqual(source.stopCalls, 0)
            XCTAssertEqual(source.mailbox.counters.waitingReaders, 1)
        }
        func finish(origin: Int, length: Int) async throws {
            let count = input.events.count
            try PortableSettingsUIPreviewFixture.click(toolbar().finishButton)
            try await LiveScrollAutomaticInteractionTests.waitUntil { self.session.isClosedForVerification }
            XCTAssertEqual(output.finishes, 1); XCTAssertEqual(output.copies, 0)
            XCTAssertEqual(input.events.count, count)
            let actual = try XCTUnwrap(output.image)
            let expected = try LiveScrollAutomaticInteractionTests.image(origin: origin, length: length)
            XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(try LiveScrollAutomaticInteractionTests.pixels(actual), try LiveScrollAutomaticInteractionTests.pixels(expected))
        }
    }

    /// .idle wakes the real mailbox but returns nil to production sampling. This
    /// avoids real-time waits without changing the product's capture deadlines.
    @MainActor private final class Source: LiveScrollFrameSource {
        enum Delivery { case frame(LiveScrollScreenSource.Frame), idle }
        var region = CGRect(x: 20, y: 30, width: 64, height: 200)
        let displayBounds: CGRect
        var target: LiveScrollScreenSource.Target? { nil }
        let mailbox = LiveScrollFrameMailbox<Delivery>()
        var automaticScrollWatermark: LiveScrollFrameWatermark? { mailbox.frameWatermark }
        private(set) var generation: UInt64 = 0, sequence: UInt64 = 0
        private(set) var readCalls = 0, pauseCalls = 0, resumeCalls = 0, moveCalls = 0, stopCalls = 0
        var targetFailure = false
        private var running = false, stopped = false

        init(displayBounds: CGRect) { self.displayBounds = displayBounds }
        func start() async throws {
            guard !stopped else { throw LiveScrollSourceError.stopped }
            generation &+= 1; running = true
            mailbox.activate(generation: generation, width: 64, height: 200)
        }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            readCalls += 1
            let token = generation
            let delivery = try await mailbox.next(generation: token, timeout: timeout)
            try Task.checkCancellation()
            guard running, generation == token else { throw CancellationError() }
            try mailbox.checkAccepting(generation: token)
            switch delivery {
            case .some(.frame(let frame)): return frame
            case .some(.idle), .none: return nil
            }
        }
        func offer(_ image: CGImage, sequence suppliedSequence: UInt64? = nil, generation suppliedGeneration: UInt64? = nil) {
            let frameGeneration = suppliedGeneration ?? generation
            let frameSequence = suppliedSequence ?? (sequence + 1)
            if running && frameGeneration == generation { sequence = max(sequence, frameSequence) }
            mailbox.offer(.frame(.init(image: image, sequence: frameSequence, generation: frameGeneration,
                timestamp: TimeInterval(frameSequence), region: region)), generation: generation, sequence: sequence)
        }
        func offerIdle() { mailbox.offer(.idle, generation: generation, sequence: sequence) }
        func pauseAndDrain() async throws { pauseCalls += 1; halt() }
        func resume() async throws { resumeCalls += 1; try await start() }
        func stop() async throws { stopCalls += 1; stopped = true; halt() }
        func moveRegion(to proposed: CGRect) throws {
            guard !running, !stopped else { throw CaptureError.busy }
            moveCalls += 1; region = proposed
        }
        func validateTarget() throws { if targetFailure { throw Failure.target } }
        private func halt() {
            let token = generation
            running = false; generation &+= 1
            mailbox.close(generation: token)
        }
    }
}
