import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PicShot

/// Raw provider samples, including hidden RGB and 16-bit low bits, are the
/// oracle. A premultiplied CGContext draw would erase evidence of those bugs.
final class SourceFormatOwnedCopyTests: XCTestCase {
    private let limits = SourceFormatOwnedCopy.Limits(maximumDimension: 128,
        maximumOwnedBytes: 65_536, maximumCopyWorkBytes: 131_072)

    func testStraightRGBA8KeepsHiddenRGBPartialAlphaAndPaddedRows() throws {
        for alpha in [CGImageAlphaInfo.first, .last] {
            for order in [CGBitmapInfo.byteOrderDefault, .byteOrder32Big, .byteOrder32Little] {
                try assertCopy(depth: 8, alpha: alpha, order: order, color: sRGB())
            }
        }
    }
    func testPremultipliedRGBA8RetainsExactLowAlphaComponents() throws {
        for alpha in [CGImageAlphaInfo.premultipliedFirst, .premultipliedLast] {
            for order in [CGBitmapInfo.byteOrderDefault, .byteOrder32Big, .byteOrder32Little] {
                try assertCopy(depth: 8, alpha: alpha, order: order, color: sRGB())
            }
        }
    }
    func testRGBAndSkippedAlphaKeepOpaqueInterpretationAndMeaningfulSamples() throws {
        try assertCopy(depth: 8, alpha: .none, order: .byteOrderDefault, color: sRGB())
        for alpha in [CGImageAlphaInfo.noneSkipFirst, .noneSkipLast] {
            for order in [CGBitmapInfo.byteOrderDefault, .byteOrder32Big, .byteOrder32Little] {
                try assertCopy(depth: 8, alpha: alpha, order: order, color: sRGB())
            }
        }
    }
    func testExact16BitLowSamplesBothByteOrdersAndAllIntegerAlphaLayouts() throws {
        for alpha in [CGImageAlphaInfo.none, .first, .last, .premultipliedFirst,
                      .premultipliedLast, .noneSkipFirst, .noneSkipLast] {
            for order in [CGBitmapInfo.byteOrder16Big, .byteOrder16Little, .byteOrderDefault] {
                try assertCopy(depth: 16, alpha: alpha, order: order, color: sRGB())
            }
        }
    }
    func testExactColorSpaceObjectIntentAndInterpolationArePreserved() throws {
        let custom = try XCTUnwrap(CGColorSpace(iccData: XCTUnwrap(sRGB().copyICCData())))
        let colors = [try sRGB(), try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)),
                      try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB)),
                      CGColorSpaceCreateDeviceRGB(), custom]
        for color in colors {
            for depth in [8, 16] {
                try assertCopy(depth: depth, alpha: .last,
                    order: depth == 8 ? .byteOrder32Big : .byteOrder16Big, color: color)
            }
        }
    }
    func testEveryRenderingIntentAndInterpolationChoiceIsRetained() throws {
        for intent in [CGColorRenderingIntent.defaultIntent, .absoluteColorimetric, .relativeColorimetric, .perceptual, .saturation] {
            for interpolate in [false, true] {
                let source = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big,
                    color: sRGB(), intent: intent, interpolate: interpolate).image
                let image = try SourceFormatOwnedCopy.copy(source, limits: limits).image
                XCTAssertTrue(SourceFormatOwnedCopy.metadataMatches(source, image))
                XCTAssertEqual(image.renderingIntent, intent)
                XCTAssertEqual(image.shouldInterpolate, interpolate)
                XCTAssertEqual(try meaningfulSamples(source), try meaningfulSamples(image))
            }
        }
    }
    func testCustomDecodeGrayMaskAndFloatingPointReturnSameImageWithReason() throws {
        let rgb = Data(repeating: 127, count: 16)
        let provider = try XCTUnwrap(CGDataProvider(data: rgb as CFData))
        var decode: [CGFloat] = [1, 0, 0.2, 0.8, 0, 1]
        let remapped = try decode.withUnsafeMutableBufferPointer { values in
            try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 8, space: sRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: values.baseAddress, shouldInterpolate: false, intent: .saturation))
        }
        try assertUnchanged(remapped, reason: .decodeArray)
        let gray = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        try assertUnchanged(gray, reason: .colorSpace)
        let mask = try XCTUnwrap(CGImage(maskWidth: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, provider: provider, decode: nil, shouldInterpolate: false))
        try assertUnchanged(mask, reason: .imageMask)
        let floats: [Float] = [0.1, 0.2, 0.3, 0.5]
        let floatingData = floats.withUnsafeBytes { Data($0) }
        let floating = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: 16, space: sRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: XCTUnwrap(CGDataProvider(data: floatingData as CFData)), decode: nil,
            shouldInterpolate: true, intent: .perceptual))
        try assertUnchanged(floating, reason: .floatingPoint)
    }
    func testDimensionsRowSizeOverflowAndBothByteBudgetsFailClosed() throws {
        func storage(_ width: Int, _ height: Int, _ bits: Int, _ row: Int,
            _ limits: SourceFormatOwnedCopy.Limits? = nil) throws -> Int {
            try SourceFormatOwnedCopy.checkedStorage(width: width, height: height, bitsPerPixel: bits,
                bytesPerRow: row, limits: limits ?? self.limits)
        }
        XCTAssertEqual(try storage(2, 2, 32, 16), 32)
        for values in [(0, 2, 32, 8), (2, -1, 32, 8), (2, 2, 0, 8), (2, 2, 32, 7),
                       (129, 1, 32, 516), (Int.max, 1, 32, Int.max), (1, Int.max, 8, 8)] {
            XCTAssertThrowsError(try storage(values.0, values.1, values.2, values.3))
        }
        XCTAssertThrowsError(try storage(2, 2, 32, 16, .init(maximumDimension: 128, maximumOwnedBytes: 31, maximumCopyWorkBytes: 64)))
        XCTAssertThrowsError(try storage(2, 2, 32, 16, .init(maximumDimension: 128, maximumOwnedBytes: 32, maximumCopyWorkBytes: 63)))
        let source = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        let tracker = ImageDrawAllocationTracker(maximumAllocations: 0, allocationBytes: source.bytesPerRow * source.height)
        // An eligible copy failure must throw, never return unchanged success.
        XCTAssertThrowsError(try SourceFormatOwnedCopy.copy(source, limits: limits, tracker: tracker))
        XCTAssertEqual(tracker.snapshot().allocations, 0)
    }
    func testCancellationAtEveryFenceFreesDestinationWithoutPublishing() throws {
        let source = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        let count = source.bytesPerRow * source.height
        for fence in 1...3 {
            let tracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: count)
            var calls = 0
            try autoreleasepool {
                XCTAssertThrowsError(try SourceFormatOwnedCopy.copy(source, limits: limits, tracker: tracker,
                    isCancelled: { calls += 1; return calls == fence })) { error in
                    XCTAssertEqual(error as? SourceFormatOwnedCopy.Failure, .cancelled)
                }
            }
            let actual = tracker.snapshot()
            XCTAssertEqual(calls, fence)
            XCTAssertEqual(actual.allocations, fence == 1 ? 0 : 1)
            XCTAssertEqual(actual.deallocations, actual.allocations)
            XCTAssertEqual(actual.releaseCallbacks, fence == 3 ? 1 : 0)
            XCTAssertEqual(actual.activeBytes, 0)
            XCTAssertTrue(actual.callbackSizesMatch)
        }
    }
    func testImageIODataAndURLRoutesDetachAndSurviveSourceFileDeletion() throws {
        // Same full PNG bytes take both source routes. Compare actual decoded
        // sample representation, not bytes ImageIO may already have transformed.
        let known = try fixture(depth: 16, alpha: .last, order: .byteOrder16Big,
            color: XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)))
        let encoded = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, known.image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let data = encoded as Data
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var images: [CGImage] = [], expected: [Data] = [], trackers: [ImageDrawAllocationTracker] = []
        for isURL in [false, true] {
            let result: (CGImage, Data, ImageDrawAllocationTracker) = try autoreleasepool {
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                let source = try XCTUnwrap(isURL ? CGImageSourceCreateWithURL(url as CFURL, options)
                    : CGImageSourceCreateWithData(data as CFData, options))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
                XCTAssertEqual(decoded.bitsPerComponent, 16)
                let tracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: decoded.bytesPerRow * decoded.height)
                guard case .owned(let owned, _) = try SourceFormatOwnedCopy.copy(decoded, limits: limits, tracker: tracker) else {
                    throw TestFailure.unexpectedFallback
                }
                XCTAssertTrue(SourceFormatOwnedCopy.metadataMatches(decoded, owned))
                return (owned, try meaningfulSamples(decoded), tracker)
            }
            images.append(result.0); expected.append(result.1); trackers.append(result.2)
        }
        try FileManager.default.removeItem(at: url)
        try autoreleasepool {
            for (image, bytes) in zip(images, expected) { XCTAssertEqual(try meaningfulSamples(image), bytes) }
        }
        images.removeAll()
        for tracker in trackers { assertReleased(tracker) }
    }
    func testFailedSecondRoleReleasesFirstOwnedImageWithoutPartialPayload() throws {
        let source = try fixture(depth: 8, alpha: .last, order: .byteOrder32Big, color: sRGB()).image
        let tracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: source.bytesPerRow * source.height)
        func attempt() throws -> [CGImage] {
            let first = try SourceFormatOwnedCopy.copy(source, limits: limits, tracker: tracker).image
            let second = try SourceFormatOwnedCopy.copy(source, limits: limits, tracker: tracker).image
            return [first, second]
        }
        try autoreleasepool { XCTAssertThrowsError(try attempt()) }
        assertReleased(tracker)
    }

    private enum TestFailure: Error { case unexpectedFallback, incompleteProvider }
    private func sRGB() throws -> CGColorSpace { try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)) }
    private func assertUnchanged(_ image: CGImage, reason: SourceFormatOwnedCopy.UnsupportedReason) throws {
        let tracker = ImageDrawAllocationTracker(maximumAllocations: 0, allocationBytes: image.bytesPerRow * image.height)
        guard case .unchanged(let unchanged, let actual) = try SourceFormatOwnedCopy.copy(image, limits: limits, tracker: tracker) else {
            return XCTFail("Unsupported representation was copied")
        }
        XCTAssertTrue(unchanged === image); XCTAssertEqual(actual, reason)
        XCTAssertEqual(tracker.snapshot().allocations, 0)
        // Valid fallback does not consume destination admission, including the
        // copy's dimension bound, because no owned storage is allocated.
        let tiny = SourceFormatOwnedCopy.Limits(maximumDimension: 1, maximumOwnedBytes: 1, maximumCopyWorkBytes: 1)
        guard case .unchanged(let overBudget, let sameReason) = try SourceFormatOwnedCopy.copy(image, limits: tiny, tracker: tracker) else {
            return XCTFail("Copy budget changed compatibility fallback")
        }
        XCTAssertTrue(overBudget === image); XCTAssertEqual(sameReason, reason)
        XCTAssertEqual(tracker.snapshot().allocations, 0)
    }
    private func assertReleased(_ tracker: ImageDrawAllocationTracker, file: StaticString = #filePath, line: UInt = #line) {
        let state = tracker.snapshot()
        XCTAssertEqual(state.allocations, 1, file: file, line: line)
        XCTAssertEqual(state.releaseCallbacks, 1, file: file, line: line)
        XCTAssertEqual(state.deallocations, 1, file: file, line: line)
        XCTAssertEqual(state.activeBytes, 0, file: file, line: line)
        XCTAssertTrue(state.callbackSizesMatch, file: file, line: line)
    }
    private func assertCopy(depth: Int, alpha: CGImageAlphaInfo, order: CGBitmapInfo, color: CGColorSpace) throws {
        let known = try fixture(depth: depth, alpha: alpha, order: order, color: color)
        let tracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: known.bytes.count)
        try autoreleasepool {
            XCTAssertEqual(try providerBytes(known.image), known.bytes)
            guard case .owned(let image, let bytes) = try SourceFormatOwnedCopy.copy(known.image, limits: limits, tracker: tracker) else {
                throw TestFailure.unexpectedFallback
            }
            XCTAssertFalse(image === known.image)
            XCTAssertEqual(bytes, known.bytes.count)
            XCTAssertTrue(SourceFormatOwnedCopy.metadataMatches(known.image, image))
            XCTAssertTrue(image.colorSpace === known.image.colorSpace)
            XCTAssertEqual(image.bytesPerRow, known.image.bytesPerRow)
            XCTAssertEqual(try meaningfulSamples(image), try meaningfulSamples(known.image))
            XCTAssertEqual(try providerBytes(known.image), known.bytes)
            if let sourceProfile = known.image.colorSpace?.copyICCData(), let copiedProfile = image.colorSpace?.copyICCData() {
                XCTAssertEqual(sourceProfile as Data, copiedProfile as Data)
            }
            withExtendedLifetime(image) { }
        }
        assertReleased(tracker)
    }
    private func fixture(depth: Int, alpha: CGImageAlphaInfo, order: CGBitmapInfo,
        color: CGColorSpace, intent: CGColorRenderingIntent = .absoluteColorimetric,
        interpolate: Bool = false) throws -> (image: CGImage, bytes: Data) {
        let width = 6, height = 2, channels = alpha == .none ? 3 : 4, sampleBytes = depth / 8
        let rowBytes = width * channels * sampleBytes + 16
        var bytes = Data(repeating: 0xB7, count: rowBytes * height)
        let alphaValues = depth == 8 ? [0, 1, 2, 127, 254, 255] : [0, 1, 257, 32769, 65534, 65535]
        let first = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        let premultiplied = [.premultipliedFirst, .premultipliedLast].contains(alpha)
        for y in 0..<height { for x in 0..<width {
            let a = alphaValues[x], maximum = depth == 8 ? 255 : 65535
            var colors = depth == 8 ? [173 - x * 9, 37 + x * 17, 241 - y * 11] : [0xAB31 - x * 263, 0x1257 + x * 257, 0xF139 - y * 521]
            if premultiplied { colors = colors.map { $0 * a / maximum } }
            var values = channels == 3 ? colors : (first ? [a] + colors : colors + [a])
            if depth == 8 && order == .byteOrder32Little { values.reverse() }
            for (component, value) in values.enumerated() {
                let offset = y * rowBytes + (x * channels + component) * sampleBytes
                if depth == 8 { bytes[offset] = UInt8(value) }
                else if order == .byteOrder16Little {
                    bytes[offset] = UInt8(value & 255); bytes[offset + 1] = UInt8(value >> 8)
                } else {
                    bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 255)
                }
            }
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: depth,
            bitsPerPixel: channels * depth, bytesPerRow: rowBytes, space: color,
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | order.rawValue), provider: provider,
            decode: nil, shouldInterpolate: interpolate, intent: intent))
        return (image, bytes)
    }
    private func providerBytes(_ image: CGImage) throws -> Data {
        try XCTUnwrap(XCTUnwrap(image.dataProvider).data) as Data
    }
    private func meaningfulSamples(_ image: CGImage) throws -> Data {
        let bytes = try providerBytes(image), pixelBytes = image.bitsPerPixel / 8, componentBytes = image.bitsPerComponent / 8
        guard bytes.count >= image.bytesPerRow * image.height else { throw TestFailure.incompleteProvider }
        var skip: Int?
        if image.alphaInfo == .noneSkipFirst { skip = 0 }
        if image.alphaInfo == .noneSkipLast { skip = 3 }
        if image.bitsPerComponent == 8 && image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little,
           let index = skip { skip = 3 - index }
        var result = Data()
        for y in 0..<image.height { for x in 0..<image.width {
            let pixel = y * image.bytesPerRow + x * pixelBytes
            for component in 0..<(pixelBytes / componentBytes) where component != skip {
                result.append(contentsOf: bytes[(pixel + component * componentBytes)..<(pixel + (component + 1) * componentBytes)])
            }
        } }
        return result
    }
}
