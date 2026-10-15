import XCTest
import AppKit
import CoreVideo
import ScreenCaptureKit
import PicShotCore
@testable import PicShot

/// Synthetic ownership/concurrency tests only. These never create an SCStream,
/// discover shareable content, inspect the desktop, prompt for TCC or send input.
@MainActor
final class LiveScrollScreenSourceTests: XCTestCase {
    private final class Marker {
        let value: Int
        init(_ value: Int) { self.value = value }
    }

    func testProducerWatermarkIncludesQueuedReplacementAndSurvivesConsumption() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        XCTAssertNil(mailbox.frameWatermark)
        mailbox.activate(generation: 21, width: 80, height: 60)
        XCTAssertNil(mailbox.frameWatermark)
        mailbox.offer(Marker(1), generation: 21, sequence: 1)
        let first = try await mailbox.next(generation: 21, timeout: 0.1)
        XCTAssertEqual(first?.value, 1)
        XCTAssertEqual(mailbox.frameWatermark, LiveScrollFrameWatermark(generation: 21, sequence: 1))
        mailbox.offer(Marker(2), generation: 21, sequence: 2)
        mailbox.offer(Marker(3), generation: 21, sequence: 3)
        // The input fence must include pixels already queued while frame 1 is processed.
        XCTAssertEqual(mailbox.counters.pendingFrames, 1)
        XCTAssertEqual(mailbox.frameWatermark, LiveScrollFrameWatermark(generation: 21, sequence: 3))
        let latest = try await mailbox.next(generation: 21, timeout: 0.1)
        XCTAssertEqual(latest?.value, 3)
        XCTAssertEqual(mailbox.counters.pendingFrames, 0)
        XCTAssertEqual(mailbox.frameWatermark, LiveScrollFrameWatermark(generation: 21, sequence: 3))
        mailbox.close(generation: 21)
        XCTAssertNil(mailbox.frameWatermark)
    }

    func testProducerWatermarkResetsOnActivationAndRejectsOldGenerationChanges() {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 22, width: 80, height: 60)
        mailbox.offer(Marker(8), generation: 22, sequence: 8)
        XCTAssertEqual(mailbox.frameWatermark, LiveScrollFrameWatermark(generation: 22, sequence: 8))
        mailbox.activate(generation: 23, width: 80, height: 60)
        XCTAssertNil(mailbox.frameWatermark)
        mailbox.offer(Marker(9), generation: 22, sequence: 9)
        XCTAssertNil(mailbox.frameWatermark)
        mailbox.offer(Marker(1), generation: 23, sequence: 1)
        mailbox.offer(Marker(10), generation: 22, sequence: 10)
        mailbox.close(generation: 22)
        XCTAssertEqual(mailbox.frameWatermark, LiveScrollFrameWatermark(generation: 23, sequence: 1))
        XCTAssertEqual(mailbox.counters.rejectedFrames, 2)
        mailbox.close(generation: 23)
        XCTAssertNil(mailbox.frameWatermark)
        mailbox.offer(Marker(2), generation: 23, sequence: 2)
        XCTAssertNil(mailbox.frameWatermark)
        XCTAssertEqual(mailbox.counters.rejectedFrames, 3)
    }

    func testUnsequencedProducerCannotExposeAnEarlierWatermark() {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 24, width: 80, height: 60)
        mailbox.offer(Marker(1), generation: 24)
        XCTAssertNil(mailbox.frameWatermark)
        mailbox.offer(Marker(2), generation: 24, sequence: 2)
        XCTAssertNotNil(mailbox.frameWatermark)
        mailbox.offer(Marker(3), generation: 24)
        XCTAssertNil(mailbox.frameWatermark)
        mailbox.close(generation: 24)
    }

    func testSlowConsumerRetainsOnlyNewestFrameAndReleasesReplacedObject() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 1, width: 800, height: 600)
        weak var replaced: Marker?
        do {
            let first = Marker(0); replaced = first
            mailbox.offer(first, generation: 1)
        }
        XCTAssertNotNil(replaced)
        for value in 1...10_000 { mailbox.offer(Marker(value), generation: 1) }
        XCTAssertNil(replaced)
        XCTAssertEqual(mailbox.counters.pendingFrames, 1)
        XCTAssertEqual(mailbox.counters.peakPendingFrames, 1)
        XCTAssertEqual(mailbox.counters.replacedFrames, 10_000)
        let newest = try await mailbox.next(generation: 1, timeout: 0.1)
        XCTAssertEqual(newest?.value, 10_000)
        XCTAssertEqual(mailbox.counters.consumedFrames, 1)
        XCTAssertEqual(mailbox.counters.pendingFrames, 0)
        mailbox.close(generation: 1)
    }

    func testCloseDrainsOwnershipAndRejectsLateFrames() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 10, width: 100, height: 200)
        weak var pending: Marker?
        do {
            let value = Marker(1); pending = value
            mailbox.offer(value, generation: 10)
        }
        mailbox.close(generation: 10)
        XCTAssertNil(pending)
        mailbox.offer(Marker(2), generation: 10)
        XCTAssertEqual(mailbox.counters.pendingFrames, 0)
        XCTAssertEqual(mailbox.counters.rejectedFrames, 1)
        do { _ = try await mailbox.next(generation: 10, timeout: 0.1); XCTFail("Closed read succeeded") }
        catch is CancellationError { }
    }

    func testPostConsumeStreamFailureKeepsItsOriginalError() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 11, width: 80, height: 60)
        mailbox.offer(Marker(1), generation: 11)
        let consumed = try await mailbox.next(generation: 11, timeout: 0.1)
        XCTAssertEqual(consumed?.value, 1)
        XCTAssertEqual(mailbox.counters.consumedFrames, 1)
        XCTAssertEqual(mailbox.counters.pendingFrames, 0)
        let failure = NSError(domain: "LiveScrollScreenSourceTests.Stream", code: 42)
        // Deterministically place the callback after consumption and before the
        // same mailbox check called by LiveScrollScreenSource.checkActiveRead.
        mailbox.close(generation: 11, error: failure)
        XCTAssertThrowsError(try mailbox.checkAccepting(generation: 11)) { error in
            XCTAssertFalse(error is CancellationError)
            XCTAssertTrue((error as NSError) === failure)
        }
    }

    func testPostConsumeInvalidBufferFailureIsNotCancellation() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 12, width: 80, height: 60)
        mailbox.offer(Marker(1), generation: 12)
        let consumed = try await mailbox.next(generation: 12, timeout: 0.1)
        XCTAssertNotNil(consumed)
        mailbox.close(generation: 12, error: ScrollStitchError.differentDimensions)
        XCTAssertThrowsError(try mailbox.checkAccepting(generation: 12)) { error in
            XCTAssertEqual(error as? ScrollStitchError, .differentDimensions)
        }
    }

    func testPostConsumeIntentionalClosureRemainsCancellation() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 13, width: 80, height: 60)
        mailbox.offer(Marker(1), generation: 13)
        let consumed = try await mailbox.next(generation: 13, timeout: 0.1)
        XCTAssertNotNil(consumed)
        mailbox.close(generation: 13)
        XCTAssertThrowsError(try mailbox.checkAccepting(generation: 13)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPostConsumeFailureCannotCrossGenerationBoundary() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 14, width: 80, height: 60)
        mailbox.offer(Marker(1), generation: 14)
        _ = try await mailbox.next(generation: 14, timeout: 0.1)
        mailbox.close(generation: 14, error: ScrollStitchError.differentDimensions)
        mailbox.activate(generation: 15, width: 80, height: 60)
        mailbox.close(generation: 14, error: ScrollStitchError.invalidPixels)
        XCTAssertNoThrow(try mailbox.checkAccepting(generation: 15))
        mailbox.offer(Marker(2), generation: 15)
        let current = try await mailbox.next(generation: 15, timeout: 0.1)
        XCTAssertEqual(current?.value, 2)
        XCTAssertThrowsError(try mailbox.checkAccepting(generation: 14)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        mailbox.close(generation: 15, error: ScrollStitchError.invalidPixels)
        XCTAssertThrowsError(try mailbox.checkAccepting(generation: 14)) { error in
            XCTAssertTrue(error is CancellationError, "A stale reader must not inherit the new generation's error")
        }
    }

    func testPausedReadAndOldGenerationCannotAffectMovedRegionGeneration() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 1, width: 160, height: 240)
        let previous = Task { try await mailbox.next(generation: 1, timeout: 5) }
        for _ in 0..<1_000 where mailbox.counters.waitingReaders == 0 { await Task.yield() }
        XCTAssertEqual(mailbox.counters.waitingReaders, 1)
        mailbox.close(generation: 1)
        mailbox.activate(generation: 2, width: 160, height: 240)
        mailbox.offer(Marker(2), generation: 2)
        mailbox.offer(Marker(1), generation: 1)
        mailbox.close(generation: 1)
        do { _ = try await previous.value; XCTFail("Old generation returned a frame") }
        catch is CancellationError { }
        let next = try await mailbox.next(generation: 2, timeout: 0.1)
        XCTAssertEqual(next?.value, 2)
        XCTAssertEqual(mailbox.counters.pixelWidth, 160)
        XCTAssertEqual(mailbox.counters.pixelHeight, 240)
        XCTAssertEqual(mailbox.counters.rejectedFrames, 1)
        mailbox.close(generation: 2)
    }

    func testCancelledWaitDrainsAndDoesNotRemainSuspended() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 3, width: 80, height: 60)
        let read = Task { try await mailbox.next(generation: 3, timeout: 5) }
        for _ in 0..<1_000 where mailbox.counters.waitingReaders == 0 { await Task.yield() }
        XCTAssertEqual(mailbox.counters.waitingReaders, 1)
        read.cancel()
        do { _ = try await read.value; XCTFail("Cancelled read returned") }
        catch is CancellationError { }
        XCTAssertEqual(mailbox.counters.waitingReaders, 0)
        XCTAssertEqual(mailbox.counters.pendingFrames, 0)
        XCTAssertFalse(mailbox.isAccepting(generation: 3))
    }

    func testUnchangedContentHasBoundedIdleResultAndCanLaterDeliver() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 4, width: 80, height: 60)
        let idle = try await mailbox.next(generation: 4, timeout: 0.01)
        XCTAssertNil(idle)
        XCTAssertEqual(mailbox.counters.idleTimeouts, 1)
        XCTAssertEqual(mailbox.counters.waitingReaders, 0)
        mailbox.offer(Marker(7), generation: 4)
        let active = try await mailbox.next(generation: 4, timeout: 0.1)
        XCTAssertEqual(active?.value, 7)
        mailbox.close(generation: 4)
    }

    func testConcurrentWaitDoesNotReplaceTheOriginalWaiter() async throws {
        let mailbox = LiveScrollFrameMailbox<Marker>()
        mailbox.activate(generation: 5, width: 80, height: 60)
        let first = Task { try await mailbox.next(generation: 5, timeout: 5) }
        for _ in 0..<1_000 where mailbox.counters.waitingReaders == 0 { await Task.yield() }
        do { _ = try await mailbox.next(generation: 5, timeout: 0.1); XCTFail("Concurrent read was accepted") }
        catch LiveScrollSourceError.concurrentRead { }
        mailbox.offer(Marker(8), generation: 5)
        let result = try await first.value
        XCTAssertEqual(result?.value, 8)
        mailbox.close(generation: 5)
    }

    func testCroppedConfigurationUsesNativePixelsAndBoundedQueue() throws {
        let geometry = try LiveScrollScreenSource.captureGeometry(
            region: CGRect(x: 20.25, y: 35.25, width: 100, height: 140),
            screenSize: CGSize(width: 800, height: 600),
            contentRect: CGRect(x: -800, y: -100, width: 800, height: 600),
            pointPixelScale: 2, expectedPixelSize: nil)
        XCTAssertEqual(geometry.region, CGRect(x: 20, y: 35, width: 100.5, height: 140.5))
        XCTAssertEqual(geometry.pixelSize, CGSize(width: 201, height: 281))
        let config = LiveScrollScreenSource.configuration(region: geometry.region, pixelSize: geometry.pixelSize)
        XCTAssertEqual(config.sourceRect, geometry.region)
        XCTAssertEqual(config.width, 201); XCTAssertEqual(config.height, 281)
        XCTAssertEqual(config.queueDepth, 3)
        XCTAssertEqual(config.minimumFrameInterval.seconds, 1.0 / 15.0, accuracy: 0.000001)
        XCTAssertFalse(config.showsCursor); XCTAssertFalse(config.capturesAudio)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertThrowsError(try LiveScrollScreenSource.captureGeometry(region: geometry.region,
            screenSize: CGSize(width: 800, height: 600), contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            pointPixelScale: 1, expectedPixelSize: geometry.pixelSize))
    }

    func testMatcherMinimumUsesActualCaptureGeometryAtOneAndTwoPixelScales() throws {
        // The same logical selection can be unsupported at 1x and supported at
        // 2x. Neither the selector's points nor the machine's Retina scale is
        // evidence that the returned capture is large enough for matching.
        for scale: CGFloat in [1, 2, 1.5] {
            let geometry = try LiveScrollScreenSource.captureGeometry(
                region: CGRect(x: 20, y: 30, width: 24, height: 24),
                screenSize: CGSize(width: 800, height: 600),
                contentRect: CGRect(x: -800, y: -100, width: 800, height: 600),
                pointPixelScale: scale, expectedPixelSize: nil)
            let side = Int(24 * scale)
            XCTAssertEqual(geometry.pixelSize, CGSize(width: side, height: side))
            let configuration = LiveScrollScreenSource.configuration(region: geometry.region, pixelSize: geometry.pixelSize)
            XCTAssertEqual(configuration.width, side); XCTAssertEqual(configuration.height, side)
            for axis in [ScrollAxis.vertical, .horizontal] {
                XCTAssertEqual(LiveScrollMatcher.supportsCapture(width: configuration.width,
                    height: configuration.height, axis: axis), scale == 2, "\(scale)x \(axis)")
            }
        }
    }

    func testMatcherExactAndOnePixelShortBoundariesUseRoundedCapturePixelsAtEveryScale() throws {
        let dimensions: [(width: Int, height: Int, axis: ScrollAxis, supported: Bool)] = [
            (24, 48, .vertical, true), (23, 48, .vertical, false), (24, 47, .vertical, false),
            (48, 24, .horizontal, true), (47, 24, .horizontal, false), (48, 23, .horizontal, false)
        ]
        for scale: CGFloat in [1, 2, 1.5] {
            for item in dimensions {
                // At 1.5x a 15-point edge rounds outward to 23 actual pixels;
                // use that real geometry result, without rounding up to a
                // matching minimum or expanding the user's selection.
                let logicalWidth = scale == 1.5 && item.width == 23 ? 15 : CGFloat(item.width) / scale
                let logicalHeight = scale == 1.5 && item.height == 23 ? 15 : CGFloat(item.height) / scale
                let geometry = try LiveScrollScreenSource.captureGeometry(
                    region: CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight),
                    screenSize: CGSize(width: 800, height: 600),
                    contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                    pointPixelScale: scale, expectedPixelSize: nil)
                XCTAssertEqual(geometry.pixelSize, CGSize(width: item.width, height: item.height), "\(scale)x \(item)")
                let configuration = LiveScrollScreenSource.configuration(region: geometry.region, pixelSize: geometry.pixelSize)
                XCTAssertEqual(configuration.width, item.width); XCTAssertEqual(configuration.height, item.height)
                XCTAssertEqual(LiveScrollMatcher.supportsCapture(width: configuration.width,
                    height: configuration.height, axis: item.axis), item.supported, "\(scale)x \(item)")
            }
        }
    }

    func testOwnedImageSurvivesPixelBufferReuseAndReleaseWithoutColorOrRowFlip() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer), kCVReturnSuccess)
        var image: CGImage!
        do {
            let source = try XCTUnwrap(buffer)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(source)
            for y in 0..<16 {
                for x in 0..<16 {
                    let index = y * stride + x * 4
                    bytes[index] = UInt8(x); bytes[index + 1] = UInt8(y)
                    bytes[index + 2] = 200; bytes[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(source, [])
            image = try LiveScrollScreenSource.ownedImage(source)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
            memset(bytes, 0, stride * 16)
            CVPixelBufferUnlockBaseAddress(source, [])
        }
        buffer = nil
        let owned = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(owned))
        XCTAssertEqual(image.width, 16); XCTAssertEqual(image.height, 16)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [0, 0, 200, 255])
        let last = bytes.advanced(by: 15 * image.bytesPerRow + 15 * 4)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: last, count: 4)), [15, 15, 200, 255])
    }
}
