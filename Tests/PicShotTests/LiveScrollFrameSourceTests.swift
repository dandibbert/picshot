import XCTest
import AppKit
@testable import PicShot

/// Exercises the production session's source interface with owned synthetic frames.
/// These tests provide no evidence about real display capture or screen permission.
@MainActor
final class LiveScrollFrameSourceTests: XCTestCase {
    private let region = CGRect(x: 20, y: 30, width: 16, height: 32)
    private let display = CGRect(x: -800, y: -100, width: 800, height: 600)

    func testProtocolSourceProducesOwnedFrameAndSupportsPauseMoveResume() async throws {
        let fixture = try Self.image(width: 16, height: 32)
        let source: any LiveScrollFrameSource = try LiveScrollVerificationFrameSource(region: region, displayBounds: display) { fixture }
        XCTAssertNil(source.automaticScrollWatermark)
        try await source.start()
        XCTAssertNil(source.automaticScrollWatermark)
        let firstResult = try await source.nextFrame(timeout: 0.1)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.image.width, 16); XCTAssertEqual(first.image.height, 32)
        XCTAssertEqual(first.region, region)
        XCTAssertFalse(first.image === fixture)
        XCTAssertEqual(source.automaticScrollWatermark,
                       LiveScrollFrameWatermark(generation: first.generation, sequence: first.sequence))
        try await source.pauseAndDrain()
        XCTAssertNil(source.automaticScrollWatermark)
        let moved = region.offsetBy(dx: 40, dy: 60)
        try source.moveRegion(to: moved)
        try await source.resume()
        XCTAssertNil(source.automaticScrollWatermark)
        let secondResult = try await source.nextFrame(timeout: 0.1)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(second.region, moved)
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertGreaterThan(second.sequence, first.sequence)
        XCTAssertEqual(source.automaticScrollWatermark,
                       LiveScrollFrameWatermark(generation: second.generation, sequence: second.sequence))
        try await source.stop()
        XCTAssertNil(source.automaticScrollWatermark)
        do { try await source.resume(); XCTFail("Stopped source resumed") }
        catch LiveScrollSourceError.stopped { }
    }

    func testNilProviderReturnsIdleAndNextCallCanProduceFrame() async throws {
        let fixture = try Self.image(width: 16, height: 32)
        var produce = false
        let source = try LiveScrollVerificationFrameSource(region: region, displayBounds: display) { produce ? fixture : nil }
        try await source.start()
        let idle = try await source.nextFrame(timeout: 0.01)
        XCTAssertNil(idle)
        XCTAssertNil(source.automaticScrollWatermark)
        produce = true
        let frame = try await source.nextFrame(timeout: 0.1)
        XCTAssertNotNil(frame)
        try await source.stop()
    }

    func testRepeatedIdleDeadlinesDoNotDuplicateAnOutstandingProvider() async throws {
        let gate = ImageGate(image: try Self.image(width: 16, height: 32))
        let source = try LiveScrollVerificationFrameSource(region: region, displayBounds: display) { await gate.next() }
        try await source.start()
        let firstIdle = try await source.nextFrame(timeout: 0.01)
        let secondIdle = try await source.nextFrame(timeout: 0.01)
        XCTAssertNil(firstIdle); XCTAssertNil(secondIdle)
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        let frame = try await source.nextFrame(timeout: 0.1)
        XCTAssertNotNil(frame)
        XCTAssertEqual(gate.calls, 1)
        try await source.stop()
    }

    func testPauseDrainsLateProviderAndRejectsItsGenerationBeforeMove() async throws {
        let gate = ImageGate(image: try Self.image(width: 16, height: 32))
        let source = try LiveScrollVerificationFrameSource(region: region, displayBounds: display) { await gate.next() }
        try await source.start()
        let read = Task { try await source.nextFrame(timeout: 1) }
        for _ in 0..<1_000 where gate.calls == 0 { await Task.yield() }
        XCTAssertEqual(gate.calls, 1)
        let pause = Task { try await source.pauseAndDrain() }
        for _ in 0..<1_000 where !gate.cancelled { await Task.yield() }
        XCTAssertTrue(gate.cancelled)
        gate.release()
        try await pause.value
        do { _ = try await read.value; XCTFail("Paused generation returned its late frame") }
        catch is CancellationError { }
        try source.moveRegion(to: region.offsetBy(dx: 2, dy: 4))
        try await source.resume()
        let resumed = try await source.nextFrame(timeout: 0.1)
        XCTAssertEqual(resumed?.region, region.offsetBy(dx: 2, dy: 4))
        XCTAssertEqual(gate.calls, 2)
        try await source.stop()
    }

    func testCancellingReadDrainsProviderAndMakesSourceTerminal() async throws {
        var entered = false
        let source = try LiveScrollVerificationFrameSource(region: region, displayBounds: display) {
            entered = true
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }
        try await source.start()
        let read = Task { try await source.nextFrame(timeout: 1) }
        for _ in 0..<1_000 where !entered { await Task.yield() }
        XCTAssertTrue(entered)
        read.cancel()
        do { _ = try await read.value; XCTFail("Cancelled read succeeded") }
        catch is CancellationError { }
        do { try await source.resume(); XCTFail("Cancelled source resumed") }
        catch LiveScrollSourceError.stopped { }
        try await source.stop()
    }

    func testCompatibleSourceDefaultsToNoKnownTeardownFailure() {
        let source: any LiveScrollFrameSource = CompatibleFrameSource(region: region, displayBounds: display)
        XCTAssertFalse(source.hasUnconfirmedTeardown)
    }

    func testConfirmedTeardownAllowsRecoveryAfterPauseAndProviderFailure() async throws {
        let fixture = try Self.image(width: 16, height: 32)
        var failProvider = false
        let source: any LiveScrollFrameSource = try LiveScrollVerificationFrameSource(region: region, displayBounds: display) {
            if failProvider { throw CaptureError.failed("Provider failed") }
            return fixture
        }
        XCTAssertFalse(source.hasUnconfirmedTeardown)
        try await source.start()
        XCTAssertFalse(source.hasUnconfirmedTeardown)
        let initial = try await source.nextFrame(timeout: 0.1)
        XCTAssertNotNil(initial)
        try await source.pauseAndDrain()
        XCTAssertFalse(source.hasUnconfirmedTeardown)
        try source.moveRegion(to: region.offsetBy(dx: 2, dy: 4))
        try await source.resume()
        failProvider = true
        do { _ = try await source.nextFrame(timeout: 0.1); XCTFail("Provider failure returned a frame") }
        catch CaptureError.failed(let message) { XCTAssertEqual(message, "Provider failed") }
        XCTAssertFalse(source.hasUnconfirmedTeardown)
        XCTAssertNil(source.automaticScrollWatermark)
        try source.moveRegion(to: region)
        failProvider = false
        try await source.resume()
        let recovered = try await source.nextFrame(timeout: 0.1)
        XCTAssertEqual(recovered?.region, region)
        XCTAssertFalse(source.hasUnconfirmedTeardown)
        try await source.stop()
        XCTAssertFalse(source.hasUnconfirmedTeardown)
    }

    func testUncooperativeProviderTimeoutKeepsTeardownUnconfirmedAfterLateCompletion() async throws {
        weak var releasedSource: LiveScrollVerificationFrameSource?
        weak var releasedGate: ImageGate?
        do {
            let gate = ImageGate(image: try Self.image(width: 16, height: 32))
            defer { gate.release() }
            var providerReturned = false
            let verification = try LiveScrollVerificationFrameSource(region: region, displayBounds: display) {
                let image = await gate.next()
                providerReturned = true
                return image
            }
            let source: any LiveScrollFrameSource = verification
            releasedSource = verification; releasedGate = gate
            try await source.start()
            XCTAssertFalse(source.hasUnconfirmedTeardown)
            let read = Task { try await source.nextFrame(timeout: 1) }
            for _ in 0..<1_000 where gate.calls == 0 { await Task.yield() }
            XCTAssertEqual(gate.calls, 1)
            XCTAssertNotNil(gate.continuation)
            let began = ProcessInfo.processInfo.systemUptime
            do { try await source.pauseAndDrain(); XCTFail("Uncooperative provider teardown succeeded") }
            catch LiveScrollSourceError.operationTimedOut(let operation) { XCTAssertEqual(operation, "验证帧清理") }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            XCTAssertEqual(LiveScrollScreenSource.operationTimeout, 3)
            XCTAssertGreaterThanOrEqual(elapsed, 2.9)
            XCTAssertLessThan(elapsed, 5)
            XCTAssertTrue(gate.cancelled)
            XCTAssertFalse(providerReturned)
            XCTAssertTrue(source.hasUnconfirmedTeardown)
            XCTAssertNil(source.automaticScrollWatermark)
            do { _ = try await read.value; XCTFail("Failed teardown delivered a frame") }
            catch is CancellationError { }
            do { try await source.resume(); XCTFail("Unconfirmed source resumed") }
            catch LiveScrollSourceError.unconfirmedTeardown { }
            do { try source.moveRegion(to: region.offsetBy(dx: 2, dy: 4)); XCTFail("Unconfirmed source moved") }
            catch CaptureError.busy { }

            gate.release()
            for _ in 0..<1_000 where !providerReturned { await Task.yield() }
            XCTAssertTrue(providerReturned)
            XCTAssertNil(gate.continuation)
            XCTAssertEqual(gate.calls, 1)
            XCTAssertTrue(source.hasUnconfirmedTeardown)
            XCTAssertNil(source.automaticScrollWatermark)
            do { _ = try await source.nextFrame(timeout: 0.1); XCTFail("Late provider completion delivered a frame") }
            catch LiveScrollSourceError.paused { }
            do { try await source.resume(); XCTFail("Late provider completion reset failed state") }
            catch LiveScrollSourceError.unconfirmedTeardown { }
            do { try source.moveRegion(to: region.offsetBy(dx: 2, dy: 4)); XCTFail("Late provider completion allowed movement") }
            catch CaptureError.busy { }
            do { try await source.stop(); XCTFail("Failed teardown became confirmed after release") }
            catch LiveScrollSourceError.unconfirmedTeardown { }
            XCTAssertTrue(source.hasUnconfirmedTeardown)
        }
        for _ in 0..<1_000 where releasedSource != nil || releasedGate != nil { await Task.yield() }
        XCTAssertNil(releasedSource)
        XCTAssertNil(releasedGate)
    }

    @MainActor
    private final class CompatibleFrameSource: LiveScrollFrameSource {
        let region: CGRect
        let displayBounds: CGRect
        let target: LiveScrollScreenSource.Target? = nil
        init(region: CGRect, displayBounds: CGRect) { self.region = region; self.displayBounds = displayBounds }
        func start() async throws { }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? { nil }
        func pauseAndDrain() async throws { }
        func resume() async throws { }
        func stop() async throws { }
        func moveRegion(to proposed: CGRect) throws { }
        func validateTarget() throws { }
    }

    private static func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    private final class ImageGate {
        let image: CGImage
        var calls = 0
        var cancelled = false
        var continuation: CheckedContinuation<Void, Never>?
        init(image: CGImage) { self.image = image }
        func next() async -> CGImage? {
            calls += 1
            if calls == 1 {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation = $0 }
                } onCancel: {
                    Task { @MainActor in self.cancelled = true }
                }
            }
            return image
        }
        func release() { let held = continuation; continuation = nil; held?.resume() }
    }
}
