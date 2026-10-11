import XCTest
import AppKit
import PicShotCore
@testable import PicShot

/// Synthetic acquisition with the production mailbox, session, controls and
/// assembler. No SCStream, screen capture, OS input or clipboard operation.
@MainActor
final class LiveScrollMailboxFailureSessionTests: XCTestCase {
    func testPostConsumeFailurePausesVisiblyAndFinishRetainsLastGoodImage() async throws {
        let failures: [Error] = [
            NSError(domain: "LiveScrollMailboxFailureSessionTests.Stream", code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "Synthetic stream stopped"]),
            ScrollStitchError.differentDimensions
        ]
        for failure in failures {
            try await withSession { session, source, seed, output in
                let toolbar = try Self.toolbar(session)
                let thumbnail = try Self.thumbnail(session)
                let lastPreview = try XCTUnwrap(thumbnail.image)
                let before = session.snapshotForVerification
                source.afterConsume = { token in source.mailbox.close(generation: token, error: failure) }
                source.offer(seed)
                try await Self.waitUntil { session.snapshotForVerification.statusKind == .error }

                let failed = session.snapshotForVerification
                XCTAssertTrue(failed.paused)
                XCTAssertTrue(failed.status.contains(failure.localizedDescription))
                XCTAssertEqual(failed.acceptedFrames, before.acceptedFrames)
                XCTAssertEqual(failed.pixelWidth, before.pixelWidth)
                XCTAssertEqual(failed.pixelHeight, before.pixelHeight)
                XCTAssertTrue(failed.canFinish); XCTAssertTrue(failed.canCopy); XCTAssertTrue(failed.canPause)
                XCTAssertEqual(source.mailbox.counters.consumedFrames, 2,
                               "The failure must be injected after the second frame was consumed")
                XCTAssertEqual(session.sampledFramesForVerification, 1,
                               "The rejected frame must never reach the assembler")
                XCTAssertTrue(thumbnail.image === lastPreview)
                XCTAssertEqual(session.controlsForVerification?.snapshot, failed)
                XCTAssertEqual(toolbar.pauseButton.accessibilityLabel(), "重试捕获")
                XCTAssertEqual(toolbar.statusLabel.textColor, .systemRed)

                // Finish to the test callback, never Copy to the user's clipboard.
                try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
                try await Self.waitUntil { session.isClosedForVerification }
                let finished = try XCTUnwrap(output.image)
                XCTAssertEqual(finished.width, seed.width); XCTAssertEqual(finished.height, seed.height)
                XCTAssertEqual(try Self.pixels(finished), try Self.pixels(seed))
            }
        }
    }

    func testIntentionalPauseStaysSilentAndStaleFailureCannotBreakResumedGeneration() async throws {
        try await withSession { session, source, seed, _ in
            let toolbar = try Self.toolbar(session)
            let lastPreview = try XCTUnwrap(Self.thumbnail(session).image)
            let oldGeneration = source.generation
            try await Self.waitUntil { source.mailbox.counters.waitingReaders == 1 }
            // Leave a source-capturing hook unconsumed to exercise pause cleanup.
            source.afterConsume = { token in source.mailbox.close(generation: token, error: ScrollStitchError.invalidPixels) }
            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil {
                let snapshot = session.snapshotForVerification
                return snapshot.paused && !snapshot.busy && snapshot.statusKind == .paused
            }
            XCTAssertNil(source.afterConsume)
            XCTAssertEqual(session.snapshotForVerification.status, "已暂停 · 内容保留")
            XCTAssertTrue(try Self.thumbnail(session).image === lastPreview)
            XCTAssertEqual(session.snapshotForVerification.acceptedFrames, 1)

            try PortableSettingsUIPreviewFixture.click(toolbar.pauseButton)
            try await Self.waitUntil {
                !session.snapshotForVerification.paused && !session.snapshotForVerification.busy
            }
            XCTAssertGreaterThan(source.generation, oldGeneration)
            source.mailbox.close(generation: oldGeneration, error: ScrollStitchError.differentDimensions)
            source.offer(seed)
            try await Self.waitUntil { session.sampledFramesForVerification == 2 }
            try await Self.waitUntil { source.mailbox.counters.waitingReaders == 1 }
            XCTAssertFalse(session.snapshotForVerification.paused)
            XCTAssertNotEqual(session.snapshotForVerification.statusKind, .error)
            XCTAssertTrue(session.snapshotForVerification.canFinish)
            XCTAssertNoThrow(try source.mailbox.checkAccepting(generation: source.generation))
        }
    }

    func testIntentionalSessionCancellationDoesNotPublishError() async throws {
        try await withSession { session, source, _, output in
            try await Self.waitUntil { source.mailbox.counters.waitingReaders == 1 }
            let before = session.snapshotForVerification
            session.cancel()
            try await Self.waitUntil { session.isClosedForVerification }
            XCTAssertEqual(session.snapshotForVerification, before)
            XCTAssertNotEqual(session.snapshotForVerification.statusKind, .error)
            XCTAssertNil(output.image)
        }
    }

    private func withSession(_ body: (LiveScrollSessionController, Source, CGImage, Output) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for session controls") }
        let seed = try Self.image()
        let source = Source(displayBounds: screen.frame)
        let output = Output()
        let session = LiveScrollSessionController(onComplete: { output.image = $0 }, onImport: {
            XCTFail("This regression must not open an importer")
        })
        do {
            try await session.startForVerification(source: source, screen: screen)
            source.offer(seed)
            try await Self.waitUntil { session.snapshotForVerification.acceptedFrames == 1 }
            try await body(session, source, seed, output)
            await session.closeForVerification()
        } catch {
            await session.closeForVerification()
            throw error
        }
        XCTAssertTrue(session.isClosedForVerification)
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for the synthetic session transition")
                throw WaitFailure.timedOut
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

    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 200, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 200))
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 7, y: 13, width: 29, height: 83))
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

    private enum WaitFailure: Error { case timedOut }
    @MainActor private final class Output { var image: CGImage? }

    /// The hook closes the real mailbox synchronously between next() returning
    /// a consumed frame and the same throwing check used by the screen source.
    @MainActor
    private final class Source: LiveScrollFrameSource {
        var region = CGRect(x: 20, y: 30, width: 64, height: 200)
        let displayBounds: CGRect
        var target: LiveScrollScreenSource.Target? { nil }
        let mailbox = LiveScrollFrameMailbox<LiveScrollScreenSource.Frame>()
        private(set) var generation: UInt64 = 0
        private var sequence: UInt64 = 0
        private var running = false
        var afterConsume: ((UInt64) -> Void)?

        init(displayBounds: CGRect) { self.displayBounds = displayBounds }
        func start() async throws {
            generation &+= 1; running = true
            mailbox.activate(generation: generation, width: 64, height: 200)
        }
        func resume() async throws { try await start() }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            let token = generation
            let frame = try await mailbox.next(generation: token, timeout: timeout)
            if frame != nil {
                let callback = afterConsume; afterConsume = nil
                callback?(token)
            }
            try Task.checkCancellation()
            guard running, generation == token else { throw CancellationError() }
            try mailbox.checkAccepting(generation: token)
            return frame
        }
        func offer(_ image: CGImage) {
            sequence &+= 1
            mailbox.offer(.init(image: image, sequence: sequence, generation: generation,
                                timestamp: TimeInterval(sequence), region: region), generation: generation)
        }
        func pauseAndDrain() async throws {
            let token = generation
            afterConsume = nil
            running = false; generation &+= 1
            mailbox.close(generation: token)
        }
        func stop() async throws { try await pauseAndDrain() }
        func moveRegion(to proposed: CGRect) throws { region = proposed }
        func validateTarget() throws { }
    }
}
