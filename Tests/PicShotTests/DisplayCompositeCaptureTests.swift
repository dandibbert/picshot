import XCTest
import AppKit
import CoreGraphics
import PicShotCore
@testable import PicShot

final class DisplayCompositeCaptureTests: XCTestCase {
    func testAsymmetricTopLeftFramesAndTransparentDesktopGaps() throws {
        let first = try display(1, x: -4, y: -3, width: 4, height: 3)
        let second = try display(2, x: 2, y: 1, width: 3, height: 5, rotation: 90)
        let layout = try DisplayCompositeLayout(displays: [first, second])
        let renderer = try DisplayCompositeRenderer(layout: layout)
        try renderer.append(coordinateImage(width: 4, height: 3), for: 1)
        try renderer.append(coordinateImage(width: 3, height: 5, seed: 80), for: 2)
        let output = try renderer.finish()
        XCTAssertEqual(output.width, 9)
        XCTAssertEqual(output.height, 9)
        XCTAssertEqual(try pixel(output, x: 0, y: 0), coordinatePixel(x: 0, y: 0))
        XCTAssertEqual(try pixel(output, x: 3, y: 2), coordinatePixel(x: 3, y: 2))
        XCTAssertEqual(try pixel(output, x: 6, y: 4), coordinatePixel(x: 0, y: 0, seed: 80))
        XCTAssertEqual(try pixel(output, x: 8, y: 8), coordinatePixel(x: 2, y: 4, seed: 80))
        for (x, y) in [(4, 0), (8, 0), (3, 3), (0, 8), (5, 6)] {
            XCTAssertEqual(try pixel(output, x: x, y: y), [0, 0, 0, 0])
        }
    }

    func testMixedRetinaNearestNeighborUpscalePreservesLogicalProportions() throws {
        let layout = try DisplayCompositeLayout(displays: [
            display(1, x: 0, y: 0, width: 3, height: 2),
            display(2, x: 3, y: 0, width: 2, height: 3, scale: 2)
        ])
        let renderer = try DisplayCompositeRenderer(layout: layout)
        try renderer.append(coordinateImage(width: 3, height: 2), for: 1)
        try renderer.append(coordinateImage(width: 4, height: 6, seed: 80), for: 2)
        let output = try renderer.finish()
        XCTAssertEqual(output.width, 10)
        XCTAssertEqual(output.height, 6)
        for y in 0..<4 { for x in 0..<6 {
            XCTAssertEqual(try pixel(output, x: x, y: y), coordinatePixel(x: x / 2, y: y / 2))
        } }
        for y in 0..<6 { for x in 6..<10 {
            XCTAssertEqual(try pixel(output, x: x, y: y), coordinatePixel(x: x - 6, y: y, seed: 80))
        } }
        XCTAssertEqual(try pixel(output, x: 0, y: 5), [0, 0, 0, 0])
    }

    func testRotationMetadataDoesNotRotateAlreadyOrientedPixelsAgain() throws {
        for rotation in [90.0, 180.0, 270.0] {
            let descriptor = try display(1, x: -2, y: -9, width: 3, height: 7, rotation: rotation)
            let renderer = try DisplayCompositeRenderer(layout: DisplayCompositeLayout(displays: [descriptor]))
            try renderer.append(coordinateImage(width: 3, height: 7), for: 1)
            let output = try renderer.finish()
            for y in 0..<7 { for x in 0..<3 {
                XCTAssertEqual(try pixel(output, x: x, y: y), coordinatePixel(x: x, y: y))
            } }
        }
    }

    func testWrongSizeWrongOrderAndPartialFinishAreRejected() throws {
        let layout = try DisplayCompositeLayout(displays: [display(1, x: 0, y: 0, width: 3, height: 7)])
        let renderer = try DisplayCompositeRenderer(layout: layout)
        XCTAssertThrowsError(try renderer.finish()) { XCTAssertEqual($0 as? DisplayCompositeError, .incomplete) }
        XCTAssertThrowsError(try renderer.append(coordinateImage(width: 3, height: 7), for: 2))
        XCTAssertThrowsError(try renderer.append(coordinateImage(width: 7, height: 3), for: 1))
        try renderer.append(coordinateImage(width: 3, height: 7), for: 1)
        XCTAssertNoThrow(try renderer.finish())
        XCTAssertThrowsError(try renderer.finish()) { XCTAssertEqual($0 as? DisplayCompositeError, .finished) }
        renderer.discard()
        renderer.discard()
        XCTAssertThrowsError(try renderer.append(coordinateImage(width: 3, height: 7), for: 1))
    }

    @MainActor
    func testSequentialCaptureReleasesEachFrameBeforeRequestingNextRepeatedly() async throws {
        let layout = try twoDisplays()
        let counter = FrameLifetimeCounter()
        for _ in 0..<25 {
            var order: [UInt32] = []
            let output = try await SequentialDisplayCapture.capture(layout: layout, validate: {}, frame: { display in
                XCTAssertEqual(counter.live, 0, "Previous frame survived into next capture")
                order.append(display.id)
                return try self.coordinateImage(width: display.pixelWidth, height: display.pixelHeight, lifetime: counter)
            })
            XCTAssertEqual(order, [1, 2])
            XCTAssertEqual(counter.live, 0)
            XCTAssertEqual(output.width, 8)
            XCTAssertEqual(try pixel(output, x: 0, y: 0), coordinatePixel(x: 0, y: 0))
        }
        XCTAssertEqual(counter.maximumLive, 1)
        XCTAssertEqual(counter.created, 50)
        XCTAssertEqual(counter.released, 50)
    }

    @MainActor
    func testLayoutChangeDiscardsPartialCanvasBeforeSecondFrame() async throws {
        let layout = try twoDisplays()
        let counter = FrameLifetimeCounter()
        var changed = false
        var captures = 0
        do {
            _ = try await SequentialDisplayCapture.capture(layout: layout, validate: {
                if changed { throw DisplayCompositeError.layoutChanged }
            }, frame: { display in
                captures += 1
                changed = true
                return try self.coordinateImage(width: display.pixelWidth, height: display.pixelHeight, lifetime: counter)
            })
            XCTFail("Layout change returned a partial screenshot")
        } catch { XCTAssertEqual(error as? DisplayCompositeError, .layoutChanged) }
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(counter.live, 0)
    }

    @MainActor
    func testCancellationDuringFrameStopsNextCaptureAndRepeatedNewSessionsWork() async throws {
        let layout = try twoDisplays()
        let counter = FrameLifetimeCounter()
        for _ in 0..<20 {
            var captures = 0
            let task = Task { @MainActor in
                try await SequentialDisplayCapture.capture(layout: layout, validate: {}, frame: { display in
                    captures += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try self.coordinateImage(width: display.pixelWidth, height: display.pixelHeight, lifetime: counter)
                })
            }
            do { _ = try await task.value; XCTFail("Cancelled session returned pixels") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(counter.live, 0)
        }
        let output = try await SequentialDisplayCapture.capture(layout: layout, validate: {}, frame: { display in
            try self.coordinateImage(width: display.pixelWidth, height: display.pixelHeight, lifetime: counter)
        })
        XCTAssertEqual(output.width, 8)
        XCTAssertEqual(counter.live, 0)
    }

    @MainActor
    func testCancellationBeforeCaptureDoesNotRequestAnyFrame() async throws {
        let layout = try twoDisplays()
        var captures = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SequentialDisplayCapture.capture(layout: layout, validate: {}, frame: { display in
                captures += 1
                return try self.coordinateImage(width: display.pixelWidth, height: display.pixelHeight)
            })
        }
        do { _ = try await task.value; XCTFail("Cancelled session began capture") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(captures, 0)
    }

    @MainActor
    func testFinalLayoutValidationRejectsChangeAfterLastFrame() async throws {
        let layout = try DisplayCompositeLayout(displays: [display(1, x: 0, y: 0, width: 3, height: 7)])
        var validations = 0
        do {
            _ = try await SequentialDisplayCapture.capture(layout: layout, validate: {
                validations += 1
                if validations == 4 { throw DisplayCompositeError.layoutChanged }
            }, frame: { display in
                try self.coordinateImage(width: display.pixelWidth, height: display.pixelHeight)
            })
            XCTFail("Final layout validation was skipped")
        } catch { XCTAssertEqual(error as? DisplayCompositeError, .layoutChanged) }
        XCTAssertEqual(validations, 4)
    }

    @MainActor
    func testCursorToggleAndNativeDimensionsReachSCKConfiguration() throws {
        let descriptor = try display(1, x: -3, y: -2, width: 4, height: 7, scale: 2, rotation: 270)
        for showsCursor in [true, false] {
            let configuration = CaptureService.displayConfiguration(for: descriptor, showsCursor: showsCursor)
            XCTAssertEqual(configuration.showsCursor, showsCursor)
            XCTAssertEqual(configuration.width, 8)
            XCTAssertEqual(configuration.height, 14)
        }
        XCTAssertTrue(CaptureMode.allCases.contains(.allScreens))
    }

    @MainActor
    func testRepeatedCancelledScreenshotDelayDoesNotAccessScreenAndReleasesBusyState() async throws {
        let service = CaptureService()
        for _ in 0..<10 {
            let task = Task { @MainActor in
                // Cancel within the task before calling the service. This fixture
                // cannot reach a permission API even under a stalled test runner.
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.capture(mode: .allScreens, options: .init(delay: .tenSeconds))
            }
            do { _ = try await task.value; XCTFail("Cancelled delay returned a screenshot") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    private func twoDisplays() throws -> DisplayCompositeLayout {
        try DisplayCompositeLayout(displays: [display(1, x: -4, y: -3, width: 4, height: 3),
                                               display(2, x: 0, y: -3, width: 4, height: 3)])
    }

    private func display(_ id: UInt32, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                         scale: CGFloat = 1, rotation: Double = 0) throws -> DisplayCaptureDescriptor {
        try DisplayCaptureDescriptor(id: id, bounds: CGRect(x: x, y: y, width: width, height: height),
                                     pixelsPerPoint: scale, rotationDegrees: rotation)
    }

    private func coordinateImage(width: Int, height: Int, seed: Int = 0, lifetime: FrameLifetimeCounter? = nil) throws -> CGImage {
        let counter = lifetime ?? FrameLifetimeCounter()
        let byteCount = width * height * 4
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        let pixels = bytes.bindMemory(to: UInt8.self, capacity: byteCount)
        for y in 0..<height { for x in 0..<width {
            let color = coordinatePixel(x: x, y: y, seed: seed)
            for channel in 0..<4 { pixels[(y * width + x) * 4 + channel] = color[channel] }
        } }
        counter.didCreate()
        let retained = Unmanaged.passRetained(counter)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: bytes, size: byteCount, releaseData: { info, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
            if let info { Unmanaged<FrameLifetimeCounter>.fromOpaque(info).takeRetainedValue().didRelease() }
        }) else {
            bytes.deallocate(); counter.didRelease(); retained.release()
            throw DisplayCompositeError.incomplete
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func coordinatePixel(x: Int, y: Int, seed: Int = 0) -> [UInt8] {
        [UInt8((x * 3 + 17 + seed) % 256), UInt8((y * 4 + 31 + seed) % 256), UInt8((x + y * 2 + 43) % 256), 255]
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        return Array(UnsafeBufferPointer(start: bytes.advanced(by: y * image.bytesPerRow + x * 4), count: 4))
    }
}

private final class FrameLifetimeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var allocations = 0
    private var releases = 0
    var live: Int { lock.lock(); defer { lock.unlock() }; return active }
    var maximumLive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var created: Int { lock.lock(); defer { lock.unlock() }; return allocations }
    var released: Int { lock.lock(); defer { lock.unlock() }; return releases }
    func didCreate() { lock.lock(); active += 1; allocations += 1; peak = max(peak, active); lock.unlock() }
    func didRelease() { lock.lock(); active -= 1; releases += 1; lock.unlock() }
}
