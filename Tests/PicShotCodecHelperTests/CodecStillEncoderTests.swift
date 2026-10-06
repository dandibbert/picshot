import XCTest
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CPicShotCodecs
import PicShotCodecCore
@testable import PicShotCodecHelper

/// These tests always link and execute the real pinned native codecs. There is
/// no canImport fallback, placeholder image, missing-library pass, or download.
final class CodecStillEncoderTests: XCTestCase {
    func testNativeLibrariesAreActuallyLinked() throws {
        XCTAssertEqual(String(cString: PSCodecVersion(UInt32(PS_CODEC_WEBP))), "1.6.0")
        XCTAssertEqual(String(cString: PSCodecVersion(UInt32(PS_CODEC_AVIF))), "1.4.2")
        XCTAssertTrue(String(cString: PSCodecAOMVersion()).contains("3.15.0"))
    }
    func testPremultipliedNormalizationAndWhiteBackground() throws {
        let source: [UInt8] = [99, 2, 3, 0, 64, 32, 16, 128, 1, 0, 0, 1, 10, 20, 30, 255]
        var alpha = source
        try CodecRaster.normalizePremultiplied(&alpha, width: 4, height: 1, preserveAlpha: true)
        XCTAssertEqual(alpha, [0, 0, 0, 0, 128, 64, 32, 128, 255, 0, 0, 1, 10, 20, 30, 255])
        var white = source
        try CodecRaster.normalizePremultiplied(&white, width: 4, height: 1, preserveAlpha: false)
        XCTAssertEqual(white, [255, 255, 255, 255, 191, 159, 143, 255, 255, 254, 254, 255, 10, 20, 30, 255])
        XCTAssertThrowsError(try CodecRaster.normalizePremultiplied(&white, width: 4, height: 1, preserveAlpha: true, isCancelled: { true }))
    }
    func testRealLosslessStillCodecsPreserveOddDimensionsOrientationAndAlpha() throws {
        let raster = try fixture()
        for format in [CodecExportFormat.webp, .avif] {
            let encoded = try encode(raster, format: format, lossless: true)
            try CodecOutputMagic.validate(encoded, format: format)
            let decoded = try decode(encoded, format: format)
            XCTAssertEqual(decoded.width, raster.width, "\(format)")
            XCTAssertEqual(decoded.height, raster.height, "\(format)")
            XCTAssertEqual(decoded.rgba, raster.rgba, "\(format) lossless compares defined normalized straight pixels")
            let preview = try CodecEncodedPreview.verifyStill(encoded, format: format, width: raster.width, height: raster.height, isCancelled: { false })
            XCTAssertLessThanOrEqual(preview.count, CodecExportLimits.previewBytes)
            try CodecRaster.validatePNGHeader(preview)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(preview as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, raster.width); XCTAssertEqual(image.height, raster.height)
        }
    }
    func testLossyAlphaRemainsExactAtFullAlphaQuality() throws {
        let raster = try fixture()
        for format in [CodecExportFormat.webp, .avif] {
            let decoded = try decode(encode(raster, format: format, lossless: false), format: format)
            for index in stride(from: 3, to: raster.rgba.count, by: 4) {
                XCTAssertEqual(decoded.rgba[index], raster.rgba[index], "\(format) alpha at \(index)")
            }
        }
    }
    func testNativeEncodeCancellationAndTinyOutputCapDoNotSucceed() throws {
        let raster = try fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codec-cancel-\(UUID().uuidString)")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CodecStillEncoder.encode(raster: raster, request: .init(format: .webp), descriptor: fd,
            isCancelled: { true }, progress: { _ in })) { XCTAssertEqual(($0 as? CodecExportFailure)?.code, .cancelled) }
        for format in [CodecExportFormat.webp, .avif] {
            var options = PSCodecDefaultOptions(format.nativeValue), error = PSCodecError()
            options.maxOutputBytes = 1
            let result = raster.rgba.withUnsafeBufferPointer { rgba in
                PSCodecEncodeRGBA(rgba.baseAddress, UInt64(rgba.count), UInt32(raster.width), UInt32(raster.height),
                    UInt64(raster.width * 4), &options, { _, _, _, _ in 1 }, { _, _, _ in 1 }, nil, &error)
            }
            XCTAssertEqual(result, PS_CODEC_LIMIT, "\(format)")
        }
    }
    func testRealDecodersRejectTruncationCounterfeitsAndPixelCaps() throws {
        let raster = try fixture()
        for format in [CodecExportFormat.webp, .avif] {
            let encoded = try encode(raster, format: format, lossless: true)
            for broken in [Data(encoded.prefix(encoded.count / 2)), Data([137, 80, 78, 71, 13, 10, 26, 10])] {
                var error = PSCodecError()
                let result = broken.withUnsafeBytes { bytes in
                    PSCodecDecodeRGBA(format.nativeValue, bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(broken.count), 1_000, 4_000, &error)
                }
                if let result { PSCodecDecodedFree(result); XCTFail("\(format) accepted corrupt bytes") }
            }
            var error = PSCodecError()
            let limited = encoded.withUnsafeBytes { bytes in
                PSCodecDecodeRGBA(format.nativeValue, bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(encoded.count), 1, 4, &error)
            }
            if let limited { PSCodecDecodedFree(limited); XCTFail("\(format) ignored pixel budget") }
        }
    }
    func testFrozenPNGAdmissionNormalizesWithoutRotating() throws {
        let directory = try CodecTemporaryJob.create(in: FileManager.default.temporaryDirectory)
        defer { CodecTemporaryJob.removeOwned(directory) }
        let image = try fixture().image(), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent("input.png").path,
            contents: data as Data, attributes: [.posixPermissions: 0o600]))
        let files = try CodecJobFiles.validate(directory: directory, request: .init(format: .webp))
        let raster = try CodecRaster.readFrozenPNG(files: files, preserveAlpha: true, isCancelled: { false })
        XCTAssertEqual(raster.width, image.width); XCTAssertEqual(raster.height, image.height)
        XCTAssertEqual(Array(raster.rgba.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual(Array(raster.rgba.suffix(4)), [0, 0, 255, 255])
        XCTAssertThrowsError(try CodecRaster.validatePNGHeader(Data(repeating: 0, count: 100)))
    }
    func testPreviewDimensionAndByteBudgetOnLargerActualOutput() throws {
        let width = 1_100, height = 3
        let raster = try CodecRaster(width: width, height: height, rgba: [UInt8](repeating: 255, count: width * height * 4))
        let encoded = try encode(raster, format: .webp, lossless: true)
        let preview = try CodecEncodedPreview.verifyStill(encoded, format: .webp, width: width, height: height, isCancelled: { false })
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(image.width, 1_024); XCTAssertLessThanOrEqual(image.height, 1_024)
        XCTAssertLessThanOrEqual(preview.count, CodecExportLimits.previewBytes)
        XCTAssertThrowsError(try CodecEncodedPreview.verifyStill(encoded, format: .webp, width: width, height: height, isCancelled: { true }))
    }
    private func fixture() throws -> CodecRaster {
        let width = 13, height = 9
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            let alpha: UInt8 = (x + y) % 4 == 0 ? 0 : ((x + y) % 4 == 1 ? 128 : 255)
            rgba[offset] = alpha == 0 ? 0 : UInt8(x * 17)
            rgba[offset + 1] = alpha == 0 ? 0 : UInt8(y * 23)
            rgba[offset + 2] = alpha == 0 ? 0 : UInt8((x + y) * 11)
            rgba[offset + 3] = alpha
        } }
        rgba.replaceSubrange(0..<4, with: [255, 0, 0, 255])
        rgba.replaceSubrange((rgba.count - 4)..<rgba.count, with: [0, 0, 255, 255])
        return try .init(width: width, height: height, rgba: rgba)
    }
    private func encode(_ raster: CodecRaster, format: CodecExportFormat, lossless: Bool) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codec-native-\(UUID().uuidString)")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: url) }
        try CodecStillEncoder.encode(raster: raster, request: .init(format: format, quality: 80, lossless: lossless),
            descriptor: fd, isCancelled: { false }, progress: { _ in })
        return try Data(contentsOf: url)
    }
    private func decode(_ data: Data, format: CodecExportFormat) throws -> CodecRaster {
        var error = PSCodecError()
        let decoded = data.withUnsafeBytes { bytes in
            PSCodecDecodeRGBA(format.nativeValue, bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(data.count),
                UInt64(CodecExportLimits.stillPixels), UInt64(CodecExportLimits.stillPixels * 4), &error)
        }
        let value = try XCTUnwrap(decoded, "\(format) native decode code \(error.code)")
        defer { PSCodecDecodedFree(value) }
        let pixels = try XCTUnwrap(PSCodecDecodedPixels(value))
        return try CodecRaster(width: Int(PSCodecDecodedWidth(value)), height: Int(PSCodecDecodedHeight(value)),
            rgba: Array(UnsafeBufferPointer(start: pixels, count: Int(PSCodecDecodedByteCount(value)))))
    }
}
