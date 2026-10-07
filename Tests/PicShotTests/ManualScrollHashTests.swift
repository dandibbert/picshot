import XCTest
import AppKit
import CryptoKit
import ImageIO
import PicShotCore
@testable import PicShot

@MainActor
final class ManualScrollHashTests: XCTestCase {
    func testDiagnosticSelectionIsExplicitAndRejectsUnknownValues() throws {
        XCTAssertEqual(try ManualScrollObservationStrategy.diagnosticSelection(environment: [:]), .fullFrame)
        for strategy in ManualScrollObservationStrategy.allCases {
            XCTAssertEqual(try ManualScrollObservationStrategy.diagnosticSelection(environment:
                ["PICSHOT_MANUAL_HASH_STRATEGY": strategy.rawValue]), strategy)
        }
        XCTAssertThrowsError(try ManualScrollObservationStrategy.diagnosticSelection(environment:
            ["PICSHOT_MANUAL_HASH_STRATEGY": "raw-provider"]))
    }

    func testReusableContextMatchesEveryReferenceByteAcrossFormatsAndSourceColorSpaces() throws {
        let width = 37, height = 131
        let workspace = ManualScrollReusableObservation()
        let spaces = [try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), CGColorSpaceCreateDeviceRGB(),
                      try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))]
        var images: [(String, CGImage)] = []
        for (index, space) in spaces.enumerated() {
            for format in [Format.rgba, .bgra, .straightRGBA] {
                images.append(("space\(index)-\(format)", try image(width: width, height: height, space: space, format: format)))
            }
        }
        images.append(("gray-padded", try grayImage(width: width, height: height)))
        images.append(("indexed-padded", try indexedImage(width: width, height: height)))
        images.append(("rgba16-padded", try rgba16Image(width: width, height: height)))
        let parent = try image(width: width + 14, height: height + 18, space: spaces[2])
        let cropped = try XCTUnwrap(parent.cropping(to: CGRect(x: 5, y: 7, width: width, height: height)))
        images.append(("nonzero-origin-crop", cropped))
        let nestedParent = try XCTUnwrap(parent.cropping(to: CGRect(x: 2, y: 3, width: width + 8, height: height + 10)))
        images.append(("nested-crop", try XCTUnwrap(nestedParent.cropping(to: CGRect(x: 3, y: 4, width: width, height: height)))))
        for type in ["public.png", "public.jpeg"] {
            images.append((type, try encodedRoundTrip(try image(width: width, height: height, space: spaces[0], opaque: true), type: type)))
        }
        // Revisit all inputs in reverse order: stale pixels/color conversion state
        // from a preceding image must not affect the next observation.
        for (label, image) in images + Array(images.reversed()) {
            let expected = try referencePixels(image)
            let actual = try workspace.withNormalizedPixels(image) { Data($0) }
            XCTAssertEqual(actual, expected, label)
            XCTAssertEqual(try workspace.observation(image), try ManualScrollScreenDriver.observation(image), label)
            XCTAssertEqual(workspace.allocatedByteCount, width * height * 4)
        }
    }

    func testRepeatedTransparentFramesDoNotAccumulateOldPixels() throws {
        let workspace = ManualScrollReusableObservation(), space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let opaque = try image(width: 31, height: 97, space: space, opaque: true)
        let translucent = try image(width: 31, height: 97, space: space)
        let zero = try rgbaBytesImage(width: 31, height: 97, bytes: [UInt8](repeating: 0, count: 31 * 97 * 4), space: space)
        for source in [opaque, translucent, translucent, zero, translucent, zero, opaque] {
            XCTAssertEqual(try workspace.withNormalizedPixels(source) { Data($0) }, try referencePixels(source))
        }
    }

    func testEveryPixelAndEveryRGBAChannelAffectsObservation() throws {
        let width = 9, height = 11, space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let initialBytes = Array(repeating: [UInt8(47), 83, 129, 255], count: width * height).flatMap { $0 }
        let initial = try rgbaBytesImage(width: width, height: height, bytes: initialBytes, space: space)
        let workspace = ManualScrollReusableObservation(), original = try workspace.observation(initial)
        for pixel in 0..<width * height {
            for channel in 0..<4 {
                var changed = initialBytes
                changed[pixel * 4 + channel] = channel == 3 ? 254 : changed[pixel * 4 + channel] + 1
                let source = try rgbaBytesImage(width: width, height: height, bytes: changed, space: space)
                let result = try workspace.observation(source)
                XCTAssertNotEqual(result, original, "pixel \(pixel), channel \(channel)")
                XCTAssertEqual(result, try ManualScrollScreenDriver.observation(source))
            }
        }
    }

    func testWorkspaceRejectsChangedExtentWithoutReplacingItsAllocation() throws {
        let space = CGColorSpaceCreateDeviceRGB(), workspace = ManualScrollReusableObservation()
        let initial = try image(width: 17, height: 19, space: space)
        let expected = try workspace.observation(initial)
        XCTAssertThrowsError(try workspace.observation(image(width: 18, height: 19, space: space)))
        XCTAssertEqual(workspace.allocatedByteCount, 17 * 19 * 4)
        XCTAssertEqual(try workspace.observation(initial), expected)
    }

    func testDimensionAdmissionRunsBeforeWorkspaceAllocation() throws {
        for (width, height) in [(ScrollFrame.maximumDimension + 1, 1), (1, ScrollFrame.maximumDimension + 1)] {
            let workspace = ManualScrollReusableObservation()
            let source = try rgbaBytesImage(width: width, height: height,
                bytes: [UInt8](repeating: 0, count: width * height * 4), space: CGColorSpaceCreateDeviceRGB())
            XCTAssertThrowsError(try workspace.observation(source))
            XCTAssertEqual(workspace.allocatedByteCount, 0)
        }
    }

    func testWorkspaceUsesOneBackingAddressAndReleasesAfterOwnerDropsIt() throws {
        var workspace: ManualScrollReusableObservation? = ManualScrollReusableObservation()
        weak var weakWorkspace = workspace
        let source = try image(width: 37, height: 131, space: CGColorSpaceCreateDeviceRGB())
        let firstAddress = try workspace!.withNormalizedPixels(source) { UInt(bitPattern: $0.baseAddress!) }
        for _ in 0..<12 {
            XCTAssertEqual(try workspace!.withNormalizedPixels(source) { UInt(bitPattern: $0.baseAddress!) }, firstAddress)
        }
        workspace = nil
        XCTAssertNil(weakWorkspace)
    }

    func testCancellationBeforeAndAfterNormalizationRejectsTheResult() async throws {
        let source = try image(width: 37, height: 131, space: CGColorSpaceCreateDeviceRGB())
        let before = ManualScrollReusableObservation()
        let beforeTask = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try before.observation(source)
        }
        do { _ = try await beforeTask.value; XCTFail("Canceled observation succeeded") }
        catch is CancellationError { }
        XCTAssertEqual(before.allocatedByteCount, 0)
        let after = ManualScrollReusableObservation()
        let afterTask = Task.detached {
            try after.withNormalizedPixels(source) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return 1
            }
        }
        do { _ = try await afterTask.value; XCTFail("Canceled normalized result escaped") }
        catch is CancellationError { }
        XCTAssertEqual(try after.observation(source), try ManualScrollScreenDriver.observation(source))
    }

    func testDefaultDriverDoesNotAllocateExperimentalWorkspaceAndAllStrategiesAgree() async throws {
        let source = try image(width: 37, height: 131, space: CGColorSpaceCreateDeviceRGB())
        let expected = try ManualScrollScreenDriver.observation(source)
        let defaultDriver = ManualScrollScreenDriver(region: CGRect(x: 0, y: 0, width: 37, height: 131),
            screenSize: CGSize(width: 800, height: 600), provider: { source }, accept: { _ in .accepted(totalFrames: 1) })
        let defaultObservation = try await defaultDriver.capture()
        XCTAssertEqual(defaultObservation, expected)
        XCTAssertEqual(defaultDriver.normalizationBufferBytesForVerification, 0)
        defaultDriver.invalidate()
        for strategy in ManualScrollObservationStrategy.allCases {
            let driver = ManualScrollScreenDriver(region: CGRect(x: 0, y: 0, width: 37, height: 131),
                screenSize: CGSize(width: 800, height: 600), observationStrategy: strategy,
                provider: { source }, accept: { _ in .accepted(totalFrames: 1) })
            let first = try await driver.capture()
            XCTAssertEqual(first, expected)
            driver.discardPendingCapture()
            XCTAssertNil(driver.pendingImage)
            XCTAssertEqual(driver.normalizationBufferBytesForVerification, strategy == .reusableFullFrame ? 37 * 131 * 4 : 0)
            let second = try await driver.capture()
            XCTAssertEqual(second, expected)
            driver.invalidate()
            XCTAssertNil(driver.pendingImage)
            XCTAssertEqual(driver.normalizationBufferBytesForVerification, 0)
        }
    }

    func testLateCaptureAfterInvalidationCannotReinstallPendingImageOrWorkspace() async throws {
        let source = try image(width: 37, height: 131, space: CGColorSpaceCreateDeviceRGB())
        for strategy in ManualScrollObservationStrategy.allCases {
            let gate = Gate()
            var waitForGate = false
            let driver = ManualScrollScreenDriver(region: CGRect(x: 0, y: 0, width: 37, height: 131),
                screenSize: CGSize(width: 800, height: 600), observationStrategy: strategy,
                provider: { if waitForGate { await gate.hold() }; return source },
                accept: { _ in XCTFail("Canceled image was committed"); return .accepted(totalFrames: 1) })
            _ = try await driver.capture(); driver.discardPendingCapture()
            waitForGate = true
            let worker = Task { try await driver.capture() }
            try await until { gate.waiting }
            worker.cancel(); driver.invalidate()
            XCTAssertEqual(driver.normalizationBufferBytesForVerification, 0)
            gate.release()
            do { _ = try await worker.value; XCTFail("Late capture escaped cancellation") }
            catch is CancellationError { }
            XCTAssertNil(driver.pendingImage)
            XCTAssertEqual(driver.normalizationBufferBytesForVerification, 0)
        }
    }

    func testControllerReleasesWorkspaceAfterPauseThenRebuildsOnResumeAndCloses() async throws {
        let controller = ScrollCaptureController { _ in }
        defer { controller.close() }
        try await controller.setAutoCropForVerification(false)
        var configuration = ManualScrollConfiguration()
        configuration.countdownSeconds = 0; configuration.sampleInterval = 0.05
        let coordinator = try controller.startManualForVerification(axis: .vertical,
            region: CGRect(x: 0, y: 0, width: 96, height: 140), screenSize: CGSize(width: 800, height: 600),
            configuration: configuration, observationStrategy: .reusableFullFrame,
            provider: { try ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100) })
        let driver = try XCTUnwrap(controller.manualDriverForVerification)
        try await until { controller.sourceURLsForVerification.count == 1 && coordinator.state == .waiting }
        XCTAssertEqual(driver.normalizationBufferBytesForVerification, 96 * 140 * 4)
        coordinator.pause(); try await until { coordinator.canResume }
        XCTAssertNil(driver.pendingImage); XCTAssertEqual(driver.normalizationBufferBytesForVerification, 0)
        coordinator.resume()
        try await until { coordinator.state == .waiting && driver.normalizationBufferBytesForVerification > 0 }
        coordinator.stop(); try await until { !coordinator.hasPendingOperation }
        XCTAssertEqual(driver.normalizationBufferBytesForVerification, 0)
        controller.resetForVerification(); controller.close()
        XCTAssertNil(driver.pendingImage); XCTAssertEqual(driver.normalizationBufferBytesForVerification, 0)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ScrollStitchError.invalidPixels }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor private final class Gate {
        var waiting = false
        var continuation: CheckedContinuation<Void, Never>?
        func hold() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    private enum Format: Equatable { case rgba, bgra, straightRGBA }

    private func image(width: Int, height: Int, space: CGColorSpace, format: Format = .rgba,
                       opaque: Bool = false) throws -> CGImage {
        let rowBytes = width * 4 + 12
        var bytes = [UInt8](repeating: 211, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let a = opaque ? 255 : (x * 43 + y * 71) % 256
                let limit = format == .straightRGBA ? 256 : a + 1
                let r = (x * 97 + y * 23 + 11) % limit, g = (x * 17 + y * 109 + 31) % limit
                let b = (x * 67 + y * 13 + 71) % limit
                let values = format == .bgra ? [b, g, r, a] : [r, g, b, a]
                for c in 0..<4 { bytes[y * rowBytes + x * 4 + c] = UInt8(values[c]) }
            }
        }
        let alpha: CGImageAlphaInfo = format == .bgra ? .premultipliedFirst : (format == .straightRGBA ? .last : .premultipliedLast)
        let order: CGBitmapInfo = format == .bgra ? .byteOrder32Little : .byteOrder32Big
        return try makeImage(width: width, height: height, bits: 8, pixelBits: 32, rowBytes: rowBytes,
            space: space, bitmap: CGBitmapInfo(rawValue: order.rawValue | alpha.rawValue), bytes: bytes)
    }

    private func rgbaBytesImage(width: Int, height: Int, bytes: [UInt8], space: CGColorSpace) throws -> CGImage {
        try makeImage(width: width, height: height, bits: 8, pixelBits: 32, rowBytes: width * 4, space: space,
            bitmap: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue), bytes: bytes)
    }

    private func grayImage(width: Int, height: Int) throws -> CGImage {
        let stride = width + 7
        let bytes = (0..<stride * height).map { UInt8(($0 * 37 + $0 / stride * 19) % 256) }
        return try makeImage(width: width, height: height, bits: 8, pixelBits: 8, rowBytes: stride,
            space: CGColorSpaceCreateDeviceGray(), bitmap: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), bytes: bytes)
    }

    private func indexedImage(width: Int, height: Int) throws -> CGImage {
        let palette: [UInt8] = [11, 79, 223, 97, 241, 3, 211, 31, 173, 251, 181, 59]
        let space = try palette.withUnsafeBufferPointer {
            try XCTUnwrap(CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 3, colorTable: $0.baseAddress!))
        }
        let stride = width + 7
        let bytes = (0..<stride * height).map { UInt8(($0 + $0 / stride) % 4) }
        return try makeImage(width: width, height: height, bits: 8, pixelBits: 8, rowBytes: stride,
            space: space, bitmap: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), bytes: bytes)
    }

    private func rgba16Image(width: Int, height: Int) throws -> CGImage {
        let stride = width * 8 + 16
        var bytes = [UInt8](repeating: 193, count: stride * height)
        for y in 0..<height { for x in 0..<width {
            let values = [(x * 1733 + y * 307) % 65536, (x * 97 + y * 2011) % 65536,
                          (x * 911 + y * 37) % 65536, 65535]
            for c in 0..<4 {
                bytes[y * stride + x * 8 + c * 2] = UInt8(values[c] >> 8)
                bytes[y * stride + x * 8 + c * 2 + 1] = UInt8(values[c] & 255)
            }
        } }
        return try makeImage(width: width, height: height, bits: 16, pixelBits: 64, rowBytes: stride,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmap: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue), bytes: bytes)
    }

    private func makeImage(width: Int, height: Int, bits: Int, pixelBits: Int, rowBytes: Int,
                           space: CGColorSpace, bitmap: CGBitmapInfo, bytes: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: pixelBits,
            bytesPerRow: rowBytes, space: space, bitmapInfo: bitmap, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func encodedRoundTrip(_ image: CGImage, type: String) throws -> CGImage {
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes, [kCGImageSourceShouldCache: false] as CFDictionary))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    private func referencePixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}
