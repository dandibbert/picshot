import XCTest
import CoreGraphics
import Foundation
import ImageIO
@testable import PicShot

final class GIFStreamingWriterTests: XCTestCase {
    func testNativePaletteAndLZWArePreservedAcrossDifferentOpaqueFrames() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stream.gif")
        let writer = try GIFStreamingWriter(url: url)
        var expected: [[UInt8]] = []
        var nativePayloads: [Data] = []
        for index in 0..<8 {
            try autoreleasepool {
                let image = try raster(width: 47, height: 29, seed: index)
                try GIFSingleFrame.requireOpaque(image)
                let native = try GIFSingleFrame.encode(image: image)
                let packet = try GIFSingleFrame.parse(native)
                nativePayloads.append(Data(native[packet.imageDataRange]))
                let decoder = try XCTUnwrap(CGImageSourceCreateWithData(native as CFData, nil))
                expected.append(try pixels(XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, nil))))
                try writer.append(singleFrameGIF: native, delay: index % 2 == 0 ? 0.08 : 0.09)
            }
        }
        XCTAssertEqual(writer.framesWritten, 8)
        try writer.finish()
        let encoded = try Data(contentsOf: url)
        XCTAssertEqual(encoded.last, 0x3B)
        let decoder = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(decoder), 8)
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(decoder, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual((gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 0)
        for index in 0..<8 {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, index, nil))
            XCTAssertEqual(try pixels(image), expected[index], "Palette/channel/orientation changed in frame \(index)")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoder, index, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double), index % 2 == 0 ? 0.08 : 0.09,
                           accuracy: 0.001)
        }
        // The native codec's payload is copied verbatim; this writer neither
        // re-quantizes palettes nor implements LZW code-width transitions.
        let payloads = try animationImagePayloads(encoded)
        XCTAssertEqual(payloads, nativePayloads)
        XCTAssertThrowsError(try writer.append(image: raster(width: 47, height: 29, seed: 9), delay: 0.1))
        XCTAssertThrowsError(try writer.finish())
    }

    func testOpaqueAlphaCapableAndNoneSkipLayoutsAreAccepted() throws {
        let alphaCapable = try raster(width: 19, height: 13, seed: 3)
        XCTAssertEqual(alphaCapable.alphaInfo, .premultipliedLast)
        XCTAssertNoThrow(try GIFSingleFrame.requireOpaque(alphaCapable))
        // Zero in noneSkipLast's unused byte is NOT transparency.
        let skipped = try raster(width: 19, height: 13, seed: 4, skipAlpha: true)
        XCTAssertEqual(skipped.alphaInfo, .noneSkipLast)
        XCTAssertNoThrow(try GIFSingleFrame.requireOpaque(skipped))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("opaque.gif")
        let writer = try GIFStreamingWriter(url: url)
        try writer.append(image: skipped, delay: 0.1)
        try writer.append(image: alphaCapable, delay: 0.1)
        try writer.finish()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        for index in 0..<2 {
            let rgba = try pixels(XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil)))
            XCTAssertTrue(stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 })
        }
    }

    func testActualTransparencyIsRejectedRatherThanFlattenedOrComposited() throws {
        for alpha in [UInt8(0), UInt8(128), UInt8(254)] {
            let image = try raster(width: 19, height: 13, seed: 3, onePixelAlpha: alpha)
            XCTAssertThrowsError(try GIFSingleFrame.requireOpaque(image)) { error in
                guard case GIFExportError.unsupportedTransparency = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try GIFStreamingWriter(url: directory.appendingPathComponent("rejected.gif"))
        try writer.append(image: raster(width: 19, height: 13, seed: 1), delay: 0.1)
        XCTAssertThrowsError(try writer.append(image: raster(width: 19, height: 13, seed: 2, onePixelAlpha: 0), delay: 0.1))
        XCTAssertThrowsError(try writer.finish(), "A rejected frame must poison the stream")
    }

    func testNearOpaqueFloatAlphaIsNotRoundedUpToOpaque() throws {
        for alpha in [Float(1), Float(1).nextDown] {
            let components: [Float] = [0, 0, 0, alpha]
            let bytes = components.withUnsafeBytes { Data($0) }
            let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
            let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 32, bitsPerPixel: 128,
                bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            if alpha == 1 { XCTAssertNoThrow(try GIFSingleFrame.requireOpaque(image)) }
            else { XCTAssertThrowsError(try GIFSingleFrame.requireOpaque(image)) }
        }
    }

    func testAnimationPayloadInspectionThrowsForTruncationInsteadOfCrashing() throws {
        let good = onePixelGIF()
        XCTAssertEqual(try animationImagePayloads(good).count, 1)
        for count in 0..<good.count {
            XCTAssertThrowsError(try animationImagePayloads(Data(good.prefix(count))), "prefix \(count)")
        }
        var bad = good; bad[30] = 255
        XCTAssertThrowsError(try animationImagePayloads(bad))
    }

    func testSingleFrameParserHandlesGlobalLocalAndInterlacedPalettes() throws {
        // An authored 1x1 GIF with one opaque pixel; fixture bytes are original.
        let global = onePixelGIF()
        let packet = try GIFSingleFrame.parse(global)
        XCTAssertEqual(packet.width, 1); XCTAssertEqual(packet.height, 1)
        XCTAssertEqual(Array(global[packet.paletteRange]), [255, 0, 0, 0, 255, 0])
        XCTAssertEqual(packet.imagePacked, 0x80)
        XCTAssertNil(packet.transparentIndex)
        let local = onePixelGIF(localPalette: true, interlaced: true)
        let localPacket = try GIFSingleFrame.parse(local)
        XCTAssertEqual(Array(local[localPacket.paletteRange]), [0, 0, 255, 255, 255, 0])
        XCTAssertEqual(localPacket.imagePacked, 0xC0)
        XCTAssertEqual(Data(local[localPacket.imageDataRange]), Data(global[packet.imageDataRange]))
        var prefixed = Data([9, 8, 7]); prefixed.append(local)
        let nonzeroBasedSlice = prefixed[3...]
        XCTAssertEqual(try GIFSingleFrame.parse(nonzeroBasedSlice).width, 1)
    }

    func testSingleFrameParserRejectsEveryTruncationAndUnsupportedStructure() throws {
        let good = onePixelGIF()
        for count in 0..<good.count { XCTAssertThrowsError(try GIFSingleFrame.parse(Data(good.prefix(count))), "prefix \(count)") }
        var bad = good; bad.append(0)
        XCTAssertThrowsError(try GIFSingleFrame.parse(bad))
        bad = good; bad[6] = 2 // Logical/image dimension mismatch.
        XCTAssertThrowsError(try GIFSingleFrame.parse(bad))
        bad = good; bad[20] = 1 // Nonzero image left offset.
        XCTAssertThrowsError(try GIFSingleFrame.parse(bad))
        bad = good; bad[29] = 1 // Invalid GIF LZW minimum code size.
        XCTAssertThrowsError(try GIFSingleFrame.parse(bad))
        bad = Data(good.dropLast()); bad.append(good[19..<good.count]) // Second image.
        XCTAssertThrowsError(try GIFSingleFrame.parse(bad))
        bad = Data(good.prefix(19)); bad.append(contentsOf: [0x21, 0x01, 0]); bad.append(good[19...])
        XCTAssertThrowsError(try GIFSingleFrame.parse(bad), "Plaintext rendering cannot be silently discarded")
        for control in [[UInt8](arrayLiteral: 0x21, 0xF9, 3, 1, 0, 0, 0, 0),
                        [0x21, 0xF9, 4, 1, 0, 0, 2, 0], // Transparent index beyond two-color palette.
                        [0x21, 0xF9, 4, 1, 0, 0, 0, 1]] { // Invalid terminator.
            bad = Data(good.prefix(19)); bad.append(contentsOf: control); bad.append(good[19...])
            XCTAssertThrowsError(try GIFSingleFrame.parse(bad))
        }
    }

    func testEncodedFrameAndOutputBudgetsFailWithoutPublishingOversizeBytes() throws {
        let image = try raster(width: 47, height: 29, seed: 4)
        XCTAssertThrowsError(try GIFSingleFrame.encode(image: image, maximumBytes: 10)) { error in
            guard case GIFExportError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("limited.gif")
        let writer = try GIFStreamingWriter(url: url, maximumBytes: 40)
        XCTAssertThrowsError(try writer.append(image: image, delay: 0.1))
        XCTAssertThrowsError(try writer.finish())
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 40)
        XCTAssertLessThanOrEqual(writer.bytesWritten, 40)
        XCTAssertThrowsError(try GIFStreamingWriter(url: url), "Staging creation must be exclusive")
    }

    func testCancellationDuringNativeSingleFrameEncodingIsObserved() throws {
        let image = try raster(width: 128, height: 96, seed: 9)
        let cancellation = GIFTestCancellation(afterChecks: 2)
        XCTAssertThrowsError(try GIFSingleFrame.encode(image: image, cancelled: { cancellation.check() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(cancellation.count, 3)
    }

    private func raster(width: Int, height: Int, seed: Int, skipAlpha: Bool = false,
                        onePixelAlpha: UInt8? = nil) throws -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            rgba[offset] = UInt8((x * 31 + y * 7 + seed * 53) % 256)
            rgba[offset + 1] = UInt8((y * 29 + x * 3 + seed * 89) % 256)
            rgba[offset + 2] = UInt8((x * 11 + y * 19 + seed * 47) % 256)
            rgba[offset + 3] = skipAlpha ? 0 : 255
        } }
        if let alpha = onePixelAlpha {
            let offset = (width + 1) * 4
            for channel in 0..<3 { rgba[offset + channel] = UInt8(Int(rgba[offset + channel]) * Int(alpha) / 255) }
            rgba[offset + 3] = alpha
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let info = (skipAlpha ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func onePixelGIF(localPalette: Bool = false, interlaced: Bool = false) -> Data {
        var bytes = Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0, 255, 0, 0, 0, 255, 0]
        bytes += [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, (localPalette ? 0x80 : 0) | (interlaced ? 0x40 : 0)]
        if localPalette { bytes += [0, 0, 255, 255, 255, 0] }
        // min code size=2, clear=4, pixel=0, end=5, little-endian packed 3-bit codes.
        bytes += [2, 2, 0x44, 0x01, 0, 0x3B]
        return Data(bytes)
    }
    private func animationImagePayloads(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var offset = 0
        func take(_ count: Int) throws -> Range<Int> {
            guard count >= 0, count <= bytes.count - offset else { throw GIFTestParseError.invalid }
            let range = offset..<(offset + count); offset += count; return range
        }
        func byte() throws -> UInt8 { bytes[try take(1).lowerBound] }
        func subblocks() throws {
            while true {
                let count = Int(try byte())
                if count == 0 { return }
                _ = try take(count)
            }
        }
        _ = try take(13)
        guard String(decoding: bytes[0..<6], as: UTF8.self).hasPrefix("GIF8") else { throw GIFTestParseError.invalid }
        let screenPacked = bytes[10]
        if screenPacked & 0x80 != 0 { _ = try take(3 * (2 << Int(screenPacked & 7))) }
        var payloads: [Data] = []
        while true {
            switch try byte() {
            case 0x3B:
                guard offset == bytes.count else { throw GIFTestParseError.invalid }
                return payloads
            case 0x21:
                _ = try byte(); try subblocks()
            case 0x2C:
                let descriptor = try take(9)
                let packed = bytes[descriptor.upperBound - 1]
                if packed & 0x80 != 0 { _ = try take(3 * (2 << Int(packed & 7))) }
                let start = offset
                guard (2...8).contains(Int(try byte())) else { throw GIFTestParseError.invalid }
                try subblocks()
                payloads.append(Data(bytes[start..<offset]))
            default: throw GIFTestParseError.invalid
            }
        }
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GIF-Stream-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private final class GIFTestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let afterChecks: Int
    private var checks = 0
    init(afterChecks: Int) { self.afterChecks = afterChecks }
    func check() -> Bool { lock.lock(); defer { lock.unlock() }; checks += 1; return checks > afterChecks }
    var count: Int { lock.lock(); defer { lock.unlock() }; return checks }
}

private enum GIFTestParseError: Error { case invalid }
