import XCTest
import CoreGraphics
import ImageIO
import PicShotCore
@testable import PicShot

/// Exact native promotion gates. A failure is evidence of changed pixels, not a
/// reason to loosen tolerance. This file does not change the production default.
final class MultiWindowNormalizedCompositionTests: XCTestCase {
    func testProductionDefaultAndDiagnosticParsing() throws {
        XCTAssertEqual(MultiWindowCompositionMode.production, .coreGraphicsBaseline)
        XCTAssertEqual(try MultiWindowCaptureResourceFixture.compositionMode(environment: [:]), .coreGraphicsBaseline)
        XCTAssertEqual(try MultiWindowCaptureResourceFixture.compositionMode(environment: ["PICSHOT_MULTIWINDOW_COMPOSITION": "normalizedCandidate"]), .normalizedCandidate)
        XCTAssertThrowsError(try MultiWindowCaptureResourceFixture.compositionMode(environment: ["PICSHOT_MULTIWINDOW_COMPOSITION": "typo"]))
    }

    func testEverySourceAndDestinationAlphaMatchesBaselineExactly() async throws {
        let front = try window(1, width: 256, height: 256), back = try window(2, width: 256, height: 256)
        var frontBytes = [UInt8](), backBytes = [UInt8](), expected = [UInt8]()
        for destinationAlpha in 0...255 { for sourceAlpha in 0...255 {
            let foreground = [sourceAlpha, sourceAlpha / 2, sourceAlpha / 3, sourceAlpha]
            let background = [destinationAlpha / 3, destinationAlpha / 2, destinationAlpha, destinationAlpha]
            frontBytes += foreground.map(UInt8.init); backBytes += background.map(UInt8.init)
            expected += zip(foreground, background).map { pair in UInt8(pair.0 + (pair.1 * (255 - sourceAlpha) + 127) / 255) }
        } }
        let frames = [try image(width: 256, height: 256, bytes: frontBytes), try image(width: 256, height: 256, bytes: backBytes)]
        let outputs = try await compare(frontToBack: [front, back], images: frames, label: "65,536 alpha pairs")
        XCTAssertEqual(outputs.candidate, expected, "Independent premultiplied source-over oracle")
    }

    func testFractionalBoundsMixedDensityOrientationZOrderAndGapsMatchExactly() async throws {
        let front = try window(90, x: -1, y: 0, width: 4.25, height: 4.25, scale: 2)
        let back = try window(2, x: -2.25, y: -1.25, width: 4.25, height: 4.25, scale: 2)
        let high = try window(1, x: 5, y: 5, width: 2, height: 2, scale: 3)
        let sources = [try pattern(width: 5, height: 5, seed: 7), try pattern(width: 8, height: 8, seed: 29),
                       try pattern(width: 6, height: 6, seed: 91)]
        let outputs = try await compare(frontToBack: [front, back, high], images: sources, label: "Fractional placement and 5/8-pixel sources at density 3")
        // Pixel zero is the back window's original top-left; a vertical flip,
        // channel permutation or z-order inversion cannot pass this explicit check.
        XCTAssertEqual(Array(outputs.candidate[0..<4]), [29,58,87,255])
        XCTAssertTrue(stride(from: 3, to: outputs.candidate.count, by: 4).contains { outputs.candidate[$0] == 0 })
    }

    func testProfilesAlphaConventionsByteOrdersAndPaddingMatchExactly() async throws {
        let width = 7, height = 5, descriptor = try window(1, width: CGFloat(width), height: CGFloat(height))
        let profiles: [(String, CFString)] = [("sRGB", CGColorSpace.sRGB), ("Display P3", CGColorSpace.displayP3), ("linear sRGB", CGColorSpace.linearSRGB)]
        for (name, profile) in profiles {
            for straight in [false, true] {
                for bgra in [false, true] {
                    let stride = width * 4 + 12
                    var bytes = [UInt8](repeating: 0xEE, count: stride * height)
                    for y in 0..<height { for x in 0..<width {
                        let alpha = [0,1,63,127,128,254,255][x], factor = straight ? 255 : alpha
                        let rgba = [(17 + x * 23) * factor / 255, (31 + y * 37) * factor / 255,
                                    (13 + x * 7 + y * 11) * factor / 255, alpha].map(UInt8.init)
                        let value = bgra ? [rgba[2],rgba[1],rgba[0],rgba[3]] : rgba
                        bytes.replaceSubrange((y * stride + x * 4)..<(y * stride + x * 4 + 4), with: value)
                    } }
                    let alpha: CGImageAlphaInfo = bgra ? (straight ? .first : .premultipliedFirst) : (straight ? .last : .premultipliedLast)
                    let bitmap = alpha.rawValue | (bgra ? CGBitmapInfo.byteOrder32Little.rawValue : CGBitmapInfo.byteOrder32Big.rawValue)
                    let source = try image(width: width, height: height, bytes: bytes, rowBytes: stride,
                                           space: XCTUnwrap(CGColorSpace(name: profile)), bitmap: bitmap)
                    _ = try await compare(frontToBack: [descriptor], images: [source], label: "\(name), straight=\(straight), BGRA=\(bgra), padded rows")
                }
            }
        }
    }

    func testGrayRGBAndDecodeArrayMatchExactly() async throws {
        let descriptor = try window(1, width: 4, height: 4)
        let gray = try image(width: 4, height: 4, bytes: (0..<16).map { UInt8($0 * 17) }, rowBytes: 4,
            space: CGColorSpaceCreateDeviceGray(), bitmap: CGImageAlphaInfo.none.rawValue, bitsPerPixel: 8)
        _ = try await compare(frontToBack: [descriptor], images: [gray], label: "8-bit grayscale")
        let rgb = try image(width: 4, height: 4, bytes: (0..<48).map { UInt8($0 * 5) }, rowBytes: 12,
            bitmap: CGImageAlphaInfo.none.rawValue, bitsPerPixel: 24)
        _ = try await compare(frontToBack: [descriptor], images: [rgb], label: "24-bit RGB")
        let decoded = try image(width: 4, height: 4, bytes: Array(repeating: [UInt8(19),53,127,255], count: 16).flatMap { $0 },
            decode: [1,0, 0,1, 1,0])
        _ = try await compare(frontToBack: [descriptor], images: [decoded], label: "CGImage color decode array")
    }

    func testFreshImageIOPNGDecodeMatchesExactly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Normalization-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try autoreleasepool {
            let source = try pattern(width: 17, height: 19, seed: 13)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, source, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let decoder = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        let source = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        _ = try await compare(frontToBack: [window(1, width: 17, height: 19)], images: [source], label: "Fresh ImageIO PNG")
    }

    @MainActor func testOneSourceAndOneNormalizationReleasedBeforeNextFrameAndFinalOutputRelease() async throws {
        let probe = MultiWindowCompositionResourceProbe(), sourceProbe = NormalizedSourceProbe()
        let windows = try (1...8).map { try window(UInt32($0), width: 128, height: 256) }
        let layout = try MultiWindowCaptureLayout(frontToBack: windows)
        for _ in 0..<3 {
            try await captureAndRelease(layout, probe: probe, sourceProbe: sourceProbe)
            XCTAssertEqual(sourceProbe.live, 0)
            XCTAssertEqual(probe.snapshot["currentRasterBytes"], 0)
        }
        XCTAssertEqual(probe.snapshot["normalizationCount"], 24)
        XCTAssertEqual(probe.snapshot["peakRasterBytes"], 128 * 256 * 4 * 3)
    }

    @MainActor private func captureAndRelease(_ layout: MultiWindowCaptureLayout, probe: MultiWindowCompositionResourceProbe,
                                               sourceProbe: NormalizedSourceProbe) async throws {
        let output = try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline,
            mode: .normalizedCandidate, resourceProbe: probe, validate: {}, frame: { _, _ in
                XCTAssertEqual(sourceProbe.live, 0, "Previous source survived into next acquisition")
                XCTAssertEqual(probe.snapshot["normalizationBytes"], 0, "Previous normalization survived into next acquisition")
                return try self.ownedImage(width: 128, height: 256, probe: sourceProbe)
            })
        XCTAssertEqual(output.width, layout.width)
        XCTAssertEqual(probe.snapshot["currentRasterBytes"], layout.width * layout.height * 4)
        XCTAssertEqual(probe.snapshot["normalizationBytes"], 0)
        XCTAssertEqual(probe.snapshot["admittedSourceBytes"], 0)
        XCTAssertEqual(sourceProbe.live, 0)
        withExtendedLifetime(output) {}
    }

    @MainActor func testCandidateCancellationAndFailureReleaseEveryRaster() async throws {
        let layout = try MultiWindowCaptureLayout(frontToBack: [window(1, width: 128, height: 256), window(2, width: 128, height: 256)])
        for cancel in [false, true] {
            let probe = MultiWindowCompositionResourceProbe(), sourceProbe = NormalizedSourceProbe()
            var calls = 0
            let task = Task { @MainActor in
                try await SequentialMultiWindowCapture.capture(layout: layout, deadline: deadline,
                    mode: .normalizedCandidate, resourceProbe: probe, validate: {}, frame: { _, _ in
                        calls += 1
                        if calls == 2 {
                            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                            else { throw MultiWindowCaptureError.changed }
                        }
                        return try self.ownedImage(width: 128, height: 256, probe: sourceProbe)
                    })
            }
            do { _ = try await task.value; XCTFail("Interrupted capture produced output") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } else { XCTAssertEqual(error as? MultiWindowCaptureError, .changed) } }
            XCTAssertEqual(calls, 2); XCTAssertEqual(sourceProbe.live, 0)
            XCTAssertEqual(probe.snapshot["currentRasterBytes"], 0)
            XCTAssertEqual(probe.snapshot["normalizationCount"], 1)
        }
    }

    func testOverBudgetCandidateRejectsBeforeCanvasAllocation() throws {
        let layout = try MultiWindowCaptureLayout(frontToBack: [window(1, width: 4_000, height: 4_000), window(2, x: 4_000, width: 4_000, height: 4_000)])
        let probe = MultiWindowCompositionResourceProbe()
        XCTAssertThrowsError(try MultiWindowCompositeRenderer(layout: layout, mode: .normalizedCandidate, resourceProbe: probe)) {
            XCTAssertEqual($0 as? MultiWindowCaptureError, .pixelLimit)
        }
        XCTAssertEqual(probe.snapshot["peakRasterBytes"], 0)
    }

    private func compare(frontToBack windows: [MultiWindowDescriptor], images: [CGImage], label: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> (baseline: [UInt8], candidate: [UInt8]) {
        let layout = try MultiWindowCaptureLayout(frontToBack: windows)
        func render(_ mode: MultiWindowCompositionMode) async throws -> [UInt8] {
            let renderer = try MultiWindowCompositeRenderer(layout: layout, mode: mode)
            for index in windows.indices.reversed() {
                try await renderer.append(images[index], windowID: windows[index].id, deadline: deadline)
            }
            let output = try await renderer.finish(deadline: deadline)
            XCTAssertEqual(output.width, layout.width, file: file, line: line)
            XCTAssertEqual(output.height, layout.height, file: file, line: line)
            XCTAssertEqual(output.colorSpace?.name as String?, CGColorSpace.sRGB as String, file: file, line: line)
            XCTAssertEqual(output.alphaInfo, .premultipliedLast, file: file, line: line)
            let data = try XCTUnwrap(output.dataProvider?.data)
            return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        }
        let baseline = try await render(.coreGraphicsBaseline), candidate = try await render(.normalizedCandidate)
        if let index = zip(baseline, candidate).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            XCTFail("\(label): first differing RGBA byte \(index), baseline=\(baseline[index]), candidate=\(candidate[index]); native equivalence gate FAILED", file: file, line: line)
        }
        XCTAssertEqual(baseline.count, candidate.count, file: file, line: line)
        return (baseline, candidate)
    }

    private var deadline: TimeInterval { ProcessInfo.processInfo.systemUptime + 20 }
    private func window(_ id: UInt32, x: CGFloat = 0, y: CGFloat = 0, width: CGFloat, height: CGFloat, scale: CGFloat = 1) throws -> MultiWindowDescriptor {
        try MultiWindowDescriptor(id: id, ownerPID: 1, ownerStartedAt: 1, label: "Owned conversion fixture",
            bounds: CGRect(x: x, y: y, width: width, height: height), maximumScale: scale)
    }
    private func pattern(width: Int, height: Int, seed: Int) throws -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<height { for x in 0..<width {
            bytes += [UInt8((seed + x * 11) % 256), UInt8((seed * 2 + y * 17) % 256), UInt8((seed * 3 + x * 5 + y * 7) % 256), 255]
        } }
        return try image(width: width, height: height, bytes: bytes)
    }
    private func image(width: Int, height: Int, bytes: [UInt8], rowBytes: Int? = nil,
                       space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmap: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue,
                       bitsPerPixel: Int = 32, decode: [CGFloat]? = nil) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        func make(_ decodePointer: UnsafePointer<CGFloat>?) throws -> CGImage {
            try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: bitsPerPixel,
                bytesPerRow: rowBytes ?? width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                provider: provider, decode: decodePointer, shouldInterpolate: false, intent: .defaultIntent))
        }
        if let decode { return try decode.withUnsafeBufferPointer { try make($0.baseAddress) } }
        return try make(nil)
    }
    private func ownedImage(width: Int, height: Int, probe: NormalizedSourceProbe) throws -> CGImage {
        let count = width * height * 4
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4)
        pixels.initializeMemory(as: UInt8.self, repeating: 255, count: count)
        probe.change(1); let retained = Unmanaged.passRetained(probe)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pixels, size: count, releaseData: { info, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
            if let info { Unmanaged<NormalizedSourceProbe>.fromOpaque(info).takeRetainedValue().change(-1) }
        }) else { pixels.deallocate(); retained.release(); probe.change(-1); throw MultiWindowCaptureError.incomplete }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
private final class NormalizedSourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    var live: Int { lock.lock(); defer { lock.unlock() }; return current }
    func change(_ delta: Int) { lock.lock(); current += delta; lock.unlock() }
}
