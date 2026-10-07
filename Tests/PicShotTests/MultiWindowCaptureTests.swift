import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class MultiWindowCaptureTests: XCTestCase {
    func testAlphaZOrderOriginalPixelsAndTransparentGaps() async throws {
        let front = try descriptor(80, CGRect(x: -2, y: -2, width: 2, height: 2))
        let back = try descriptor(2, CGRect(x: -3, y: -3, width: 2, height: 2))
        let gap = try descriptor(1, CGRect(x: 2, y: 2, width: 2, height: 2))
        let renderer = try MultiWindowCompositeRenderer(layout: MultiWindowCaptureLayout(frontToBack: [front, back, gap]))
        try await renderer.append(image(width: 2, height: 2, rgba: [0,255,0,255]), windowID: 1, deadline: deadline)
        try await renderer.append(image(width: 2, height: 2, rgba: [0,0,255,255]), windowID: 2, deadline: deadline)
        try await renderer.append(image(width: 2, height: 2, rgba: [128,0,0,128]), windowID: 80, deadline: deadline)
        let output = try await renderer.finish(deadline: deadline)
        XCTAssertEqual(output.width, 7); XCTAssertEqual(output.height, 7)
        XCTAssertEqual(try pixel(output, x: 0, y: 0), [0,0,255,255])
        let overlap = try pixel(output, x: 1, y: 1)
        XCTAssertEqual(overlap[0], 128); XCTAssertEqual(overlap[1], 0); XCTAssertEqual(overlap[3], 255)
        XCTAssertLessThanOrEqual(abs(Int(overlap[2]) - 127), 1)
        XCTAssertEqual(try pixel(output, x: 2, y: 2), [128,0,0,128])
        XCTAssertEqual(try pixel(output, x: 3, y: 3), [0,0,0,0])
        XCTAssertEqual(try pixel(output, x: 6, y: 6), [0,255,0,255])
    }
    func testMixedDensityUsesNearestSamplingWithoutRotatingSource() async throws {
        let low = try descriptor(1, CGRect(x: -2, y: 0, width: 2, height: 2))
        let high = try descriptor(2, CGRect(x: 0, y: 0, width: 2, height: 2), scale: 2)
        let renderer = try MultiWindowCompositeRenderer(layout: MultiWindowCaptureLayout(frontToBack: [high, low]))
        let bytes: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255]
        try await renderer.append(rawImage(width: 2, height: 2, bytes: bytes), windowID: 1, deadline: deadline)
        try await renderer.append(image(width: 4, height: 4, rgba: [90,80,70,255]), windowID: 2, deadline: deadline)
        let output = try await renderer.finish(deadline: deadline)
        for y in 0..<4 { for x in 0..<4 {
            let offset = ((y / 2) * 2 + x / 2) * 4
            XCTAssertEqual(try pixel(output, x: x, y: y), Array(bytes[offset..<offset+4]))
        } }
        XCTAssertEqual(try pixel(output, x: 7, y: 3), [90,80,70,255])
    }
    @MainActor func testChangedWindowAndFailureDiscardBeforeNextFrame() async throws {
        let sources = try [descriptor(2), descriptor(1)]
        let layout = try MultiWindowCaptureLayout(frontToBack: sources)
        var current = sources, calls = 0
        do {
            _ = try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline, validate: { try layout.validate(frontToBack: current) }, frame: { source, _ in
                calls += 1; current = []
                return try self.image(width: 2, height: 2, rgba: [1,2,3,255])
            })
            XCTFail("Changed inventory produced output")
        } catch { XCTAssertEqual(error as? MultiWindowCaptureError, .changed) }
        XCTAssertEqual(calls, 1)
        calls = 0
        do {
            _ = try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline, validate: {}, frame: { _, _ in
                calls += 1; throw MultiWindowCaptureError.incomplete
            }); XCTFail("Failed frame produced partial output")
        } catch { XCTAssertEqual(error as? MultiWindowCaptureError, .incomplete) }
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testPreAndMidCaptureCancellationReleaseAdmissionAndAllowRetry() async throws {
        let layout = try MultiWindowCaptureLayout(frontToBack: [descriptor(2), descriptor(1)])
        for before in [true, false] {
            var calls = 0
            let task = Task { @MainActor in
                if before { withUnsafeCurrentTask { $0?.cancel() } }
                return try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline, validate: {}, frame: { _, _ in
                    calls += 1; withUnsafeCurrentTask { $0?.cancel() }
                    return try self.image(width: 2, height: 2, rgba: [1,2,3,255])
                })
            }
            do { _ = try await task.value; XCTFail("Cancelled capture produced output") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(calls, before ? 0 : 1)
        }
        let output = try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline, validate: {}, frame: { _, _ in
            try self.image(width: 2, height: 2, rgba: [1,2,3,255])
        })
        XCTAssertEqual(output.width, 2)
    }
    @MainActor func testSequentialFramesReleaseBeforeNextRequest() async throws {
        let windows = try (1...8).map { try descriptor(UInt32($0)) }
        let layout = try MultiWindowCaptureLayout(frontToBack: windows)
        let lifetime = WindowFrameLifetime()
        for _ in 0..<3 {
            _ = try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline, validate: {}, frame: { _, _ in
                XCTAssertEqual(lifetime.live, 0, "Previous frame remained alive at the next acquisition")
                return try self.countedImage(lifetime)
            })
            XCTAssertEqual(lifetime.live, 0)
        }
        XCTAssertEqual(lifetime.peak, 1); XCTAssertEqual(lifetime.created, 24)
    }
    private func countedImage(_ counter: WindowFrameLifetime) throws -> CGImage {
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 4)
        pixels.initializeMemory(as: UInt8.self, repeating: 255, count: 16)
        let retained = Unmanaged.passRetained(counter); counter.acquire()
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pixels, size: 16, releaseData: { info, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
            if let info { Unmanaged<WindowFrameLifetime>.fromOpaque(info).takeRetainedValue().release() }
        }) else { pixels.deallocate(); counter.release(); retained.release(); throw MultiWindowCaptureError.incomplete }
        return try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    func testDeadlineWrongOrderDimensionsAndIncompleteFinishReject() async throws {
        let layout = try MultiWindowCaptureLayout(frontToBack: [descriptor(1)])
        let renderer = try MultiWindowCompositeRenderer(layout: layout)
        do { _ = try await renderer.finish(deadline: deadline); XCTFail() } catch { XCTAssertEqual(error as? MultiWindowCaptureError, .incomplete) }
        do { try await renderer.append(image(width: 2, height: 2, rgba: [1,2,3,255]), windowID: 9, deadline: deadline); XCTFail() } catch { XCTAssertEqual(error as? MultiWindowCaptureError, .changed) }
        do { try await renderer.append(image(width: 3, height: 2, rgba: [1,2,3,255]), windowID: 1, deadline: deadline); XCTFail() } catch { XCTAssertEqual(error as? MultiWindowCaptureError, .changed) }
        do { try await renderer.append(image(width: 2, height: 2, rgba: [1,2,3,255]), windowID: 1, deadline: 0); XCTFail() } catch { XCTAssertEqual(error as? MultiWindowCaptureError, .deadline) }
        await renderer.discard()
        do { _ = try await renderer.finish(deadline: deadline); XCTFail() } catch { XCTAssertEqual(error as? MultiWindowCaptureError, .finished) }
    }
    @MainActor func testNativeInjectedSelectionCaptureCancelAndRepeatedSessions() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Requires native WindowServer; never requests screen or AX permission") }
        let report = try await MultiWindowCaptureNativeFixture.verify()
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["permissionRequested"] as? Bool, false)
        XCTAssertEqual(report["realDesktopCaptured"] as? Bool, false)
    }
    private var deadline: TimeInterval { ProcessInfo.processInfo.systemUptime + 10 }
    private func descriptor(_ id: UInt32, _ bounds: CGRect = CGRect(x: 0, y: 0, width: 2, height: 2), scale: CGFloat = 1) throws -> MultiWindowDescriptor {
        try MultiWindowDescriptor(id: id, ownerPID: 10, ownerStartedAt: 1, label: "Synthetic \(id)", bounds: bounds, maximumScale: scale)
    }
    private func image(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        try rawImage(width: width, height: height, bytes: Array(repeating: rgba, count: width * height).flatMap { $0 })
    }
    private func rawImage(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data), bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        return Array(UnsafeBufferPointer(start: bytes.advanced(by: y * image.bytesPerRow + x * 4), count: 4))
    }
}

private final class WindowFrameLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0, maximum = 0, allocations = 0
    var live: Int { lock.lock(); defer { lock.unlock() }; return active }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var created: Int { lock.lock(); defer { lock.unlock() }; return allocations }
    func acquire() { lock.lock(); active += 1; maximum = max(maximum, active); allocations += 1; lock.unlock() }
    func release() { lock.lock(); active -= 1; lock.unlock() }
}
