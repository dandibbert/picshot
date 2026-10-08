import XCTest
import AppKit
import Darwin
import ImageIO
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
    @MainActor func testLargerRepeatedFramesKeepOneOwnedSourceAndReportRSSSeparately() async throws {
        let width = 1024, height = 768, frameBytes = width * height * 4
        let windows = try (0..<8).map { try descriptor(UInt32($0 + 1), CGRect(x: $0 * 16, y: $0 * 12, width: width, height: height)) }
        let layout = try MultiWindowCaptureLayout(frontToBack: windows), lifetime = WindowFrameLifetime()
        var samples = [WindowProcessMemory.current()]
        for _ in 0..<3 {
            let output = try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline, validate: {}, frame: { _, _ in
                XCTAssertEqual(lifetime.live, 0)
                let image = try self.countedImage(lifetime, width: width, height: height)
                samples.append(WindowProcessMemory.current())
                return image
            })
            XCTAssertEqual(output.width, layout.width); XCTAssertEqual(output.height, layout.height)
            XCTAssertEqual(try pixel(output, x: output.width - 1, y: output.height - 1), [255,255,255,255])
            XCTAssertEqual(lifetime.live, 0)
            samples.append(WindowProcessMemory.current())
        }
        XCTAssertEqual(lifetime.peak, 1); XCTAssertEqual(lifetime.peakBytes, frameBytes)
        XCTAssertEqual(lifetime.liveBytes, 0); XCTAssertEqual(lifetime.created, 24)
        let report: [String: Any] = ["iterations": 3, "windowsPerIteration": 8, "sourceWidth": width, "sourceHeight": height,
            "ownedSourcePeakBytes": lifetime.peakBytes, "ownedSourceBytesAfter": lifetime.liveBytes,
            "calculatedCanvasBytes": layout.width * layout.height * 4,
            "sampledProcessRSSBytes": samples.compactMap(\.residentBytes),
            "sampledProcessPhysicalFootprintBytes": samples.compactMap(\.physicalFootprintBytes),
            "measurementBoundary": "Whole XCTest process observations; not an owned-buffer counter, attributed peak, or RSS limit"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("MULTI_WINDOW_RESOURCE_OBSERVATION " + (String(data: data, encoding: .utf8) ?? ""))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Multi-window source ownership and process observations"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func countedImage(_ counter: WindowFrameLifetime, width: Int = 2, height: Int = 2) throws -> CGImage {
        let count = width * height * 4
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4)
        pixels.initializeMemory(as: UInt8.self, repeating: 255, count: count)
        let retained = Unmanaged.passRetained(counter); counter.acquire(bytes: count)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pixels, size: count, releaseData: { info, data, size in
            UnsafeMutableRawPointer(mutating: data).deallocate()
            if let info { Unmanaged<WindowFrameLifetime>.fromOpaque(info).takeRetainedValue().release(bytes: size) }
        }) else { pixels.deallocate(); counter.release(bytes: count); retained.release(); throw MultiWindowCaptureError.incomplete }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Owned-MultiWindow-Evidence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await MultiWindowCaptureNativeFixture.verify(evidenceDirectory: directory)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["permissionRequested"] as? Bool, false)
        XCTAssertEqual(report["realDesktopCaptured"] as? Bool, false)
        XCTAssertEqual(report["completedCapturesSameController"] as? Int, 2)
        XCTAssertEqual(report["cancelledSessionsSameController"] as? Int, 4)
        XCTAssertEqual(report["clearedObserverTimerContinuationChecks"] as? Int, 6)
        XCTAssertEqual(report["retainedSelectors"] as? Int, 0)
        XCTAssertEqual(report["visibleRetiredPanels"] as? Int, 0)
        XCTAssertEqual(report["ownedBackdropClosed"] as? Bool, true)
        XCTAssertEqual(report["latePermissionProviderCalls"] as? Int, 0)
        for key in ["exactRGBAPixelsChecked", "transparentPixelsChecked", "translucentPixelsChecked", "overlapPixelsChecked"] {
            XCTAssertGreaterThan(try XCTUnwrap(report[key] as? Int), 0)
        }
        let files = try XCTUnwrap(report["evidenceFiles"] as? [String]); XCTAssertEqual(files.count, 3)
        for file in files {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(file) as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertGreaterThan(image.width, 100); XCTAssertGreaterThan(image.height, 100)
        }
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
    private var active = 0, maximum = 0, allocations = 0, bytes = 0, maximumBytes = 0
    var live: Int { lock.lock(); defer { lock.unlock() }; return active }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var created: Int { lock.lock(); defer { lock.unlock() }; return allocations }
    var liveBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var peakBytes: Int { lock.lock(); defer { lock.unlock() }; return maximumBytes }
    func acquire(bytes count: Int) { lock.lock(); active += 1; maximum = max(maximum, active); allocations += 1; bytes += count; maximumBytes = max(maximumBytes, bytes); lock.unlock() }
    func release(bytes count: Int) { lock.lock(); active -= 1; bytes -= count; lock.unlock() }
}

private struct WindowProcessMemory {
    let residentBytes: UInt64?
    let physicalFootprintBytes: UInt64?
    static func current() -> Self {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        return Self(residentBytes: basicResult == KERN_SUCCESS ? basic.resident_size : nil,
                    physicalFootprintBytes: vmResult == KERN_SUCCESS ? vm.phys_footprint : nil)
    }
}
