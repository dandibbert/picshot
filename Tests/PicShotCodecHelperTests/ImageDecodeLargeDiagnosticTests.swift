import XCTest
import Foundation
import ImageIO
import PicShotCodecCore
@testable import PicShotCodecHelper

/// These tests exercise real ImageIO thumbnails and CGContext readback on macOS.
/// Fixtures are indexed PNG8 with explicit sRGB and one constant palette entry:
/// exact expected RGBA does not depend on ImageIO's resampling filter.
final class ImageDecodeLargeDiagnosticTests: XCTestCase {
    func testLargeSelectorRemainsOutsideNormalCodecArguments() throws {
        XCTAssertThrowsError(try PicShotCodecHelper.validateArguments([ImageDecodeDiagnosticLimits.largeArgument]))
        XCTAssertThrowsError(try PicShotCodecHelper.validateArguments([ImageDecodeDiagnosticLimits.largeArgument, "4k"]))
        try PicShotCodecHelper.validateArguments([])
    }

    func testRealFourKAndFiveKThumbnailsReadBackEveryCanonicalPremultipliedByte() throws {
        for profile in ImageDecodeDiagnosticProfile.allCases {
            // Opaque, fractional alpha, and fully transparent palette entries.
            let samples: [([UInt8], UInt8, [UInt8])] = [
                ([255, 0, 0], 255, [255, 0, 0, 255]),
                ([0, 255, 0], 128, [0, 128, 0, 128]),
                ([255, 255, 255], 0, [0, 0, 0, 0])
            ]
            for (rgb, alpha, expected) in samples {
                let png = try fixture(profile: profile, rgb: rgb, alpha: alpha)
                XCTAssertLessThan(png.count, ImageDecodeDiagnosticLimits.pngBytes)
                let job = try ImageDecodeDiagnosticJob.create(png: png, mode: .decode, profile: profile, check: {})
                defer { _ = job.removeAfterExit() }
                var phases: [String] = [], checks = 0
                let result = try autoreleasepool {
                    try ImageDecodeDiagnostic.decodeThumbnailPixels(job.readPNG(check: {}), profile: profile,
                        check: { checks += 1 }, phase: { phases.append($0) })
                }
                XCTAssertEqual(phases, ["imageCreated", "rasterDrawn", "afterContextRelease"])
                XCTAssertGreaterThanOrEqual(checks, 4)
                let oracle = canonicalPixels(expected, count: 1_024 * 576)
                XCTAssertEqual(result.0.count, 2_359_296)
                XCTAssertTrue(result.0.elementsEqual(oracle), "Every \(profile.rawValue) thumbnail byte must match canonical premultiplied RGBA/sRGB")
                XCTAssertEqual(ImageDecodeDiagnosticLimits.digest(result.0), ImageDecodeDiagnosticLimits.digest(oracle))
                for seconds in [result.1, result.2] { XCTAssertTrue(seconds.isFinite); XCTAssertGreaterThanOrEqual(seconds, 0) }
                try job.writeRaw(result.0, check: {})
                XCTAssertEqual(try job.readRaw(sha256: ImageDecodeDiagnosticLimits.digest(oracle), check: {}), oracle)
            }
        }
    }

    func testSmallDecoderStillUsesItsOriginalDimensionsAndBytes() throws {
        let png = try fixture(profile: nil, rgb: [0, 255, 0], alpha: 128)
        var phases: [String] = []
        let result = try ImageDecodeDiagnostic.decodePixels(png, check: {}, phase: { phases.append($0) })
        XCTAssertEqual(result.0.count, 1_769_472)
        XCTAssertEqual(result.0, canonicalPixels([0, 128, 0, 128], count: 768 * 576))
        XCTAssertEqual(phases, ["imageCreated", "rasterDrawn", "afterContextRelease"])
        for profile in ImageDecodeDiagnosticProfile.allCases {
            XCTAssertThrowsError(try ImageDecodeDiagnostic.decodeThumbnailPixels(png, profile: profile, check: {}, phase: { _ in }))
            XCTAssertThrowsError(try ImageDecodeDiagnostic.decodePixels(fixture(profile: profile), check: {}, phase: { _ in }))
        }
    }

    func testMalformedTruncatedOversizedAndWrongProfilePNGsFailBeforeImageCreated() throws {
        for profile in ImageDecodeDiagnosticProfile.allCases {
            let png = try fixture(profile: profile)
            var badCRC = png; badCRC[29] ^= 1
            var badSignature = png; badSignature[0] = 0
            var badChunkLength = png; put(UInt32.max, in: &badChunkLength, at: 8)
            let invalid = [Data(), Data("GIF89a".utf8), Data(png.prefix(32)), Data(png.dropLast(12)),
                Data(png.prefix(png.count / 2)), png + Data([0]), badCRC, badSignature, badChunkLength,
                Data(repeating: 0, count: ImageDecodeDiagnosticLimits.pngBytes + 1),
                try fixture(profile: profile == .fourK ? .fiveK : .fourK)]
            for data in invalid {
                var phases: [String] = []
                XCTAssertThrowsError(try ImageDecodeDiagnostic.decodeThumbnailPixels(data, profile: profile, check: {}, phase: { phases.append($0) })) {
                    XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .invalidInput)
                }
                XCTAssertTrue(phases.isEmpty)
            }
            for (offset, value) in [(16, UInt32(0)), (16, UInt32(profile.sourceWidth + 1)),
                                    (20, UInt32(0)), (20, UInt32(profile.sourceHeight - 1)), (20, UInt32.max)] {
                var invalid = png; put(value, in: &invalid, at: offset); repairIHDRCRC(&invalid)
                XCTAssertThrowsError(try ImageDecodeDiagnostic.decodeThumbnailPixels(invalid, profile: profile, check: {}, phase: { _ in }))
            }
            for (offset, value) in [(24, UInt8(16)), (24, 1), (25, 1), (25, 5), (26, 1), (27, 1), (28, 2)] {
                var invalid = png; invalid[offset] = value; repairIHDRCRC(&invalid)
                XCTAssertThrowsError(try ImageDecodeDiagnostic.decodeThumbnailPixels(invalid, profile: profile, check: {}, phase: { _ in }))
            }
        }
    }

    func testOrientationMustBeOneBeforeThumbnailTransform() throws {
        for orientation in [UInt8(2), 8] {
            let png = try fixture(profile: .fourK, orientation: orientation)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, Int(orientation), "Verify the fixture's eXIf orientation is recognized")
            var phases: [String] = []
            XCTAssertThrowsError(try ImageDecodeDiagnostic.decodeThumbnailPixels(png, profile: .fourK, check: {}, phase: { phases.append($0) })) {
                XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .invalidInput)
            }
            XCTAssertTrue(phases.isEmpty)
        }
    }

    func testCancellationBeforeCreationAndAfterDrawNeverPublishesRaw() throws {
        let png = try fixture(profile: .fiveK)
        var beforePhases: [String] = []
        XCTAssertThrowsError(try ImageDecodeDiagnostic.decodeThumbnailPixels(png, profile: .fiveK,
            check: { throw ImageDecodeDiagnosticError.cancelled }, phase: { beforePhases.append($0) })) {
                XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled)
            }
        XCTAssertTrue(beforePhases.isEmpty)
        for stopPhase in ["imageCreated", "rasterDrawn", "afterContextRelease"] {
            let job = try ImageDecodeDiagnosticJob.create(png: png, mode: .decode, profile: .fiveK, check: {})
            defer { _ = job.removeAfterExit() }
            var cancelled = false, phases: [String] = []
            XCTAssertThrowsError(try autoreleasepool {
                let result = try ImageDecodeDiagnostic.decodeThumbnailPixels(png, profile: .fiveK,
                    check: { if cancelled { throw ImageDecodeDiagnosticError.cancelled } }, phase: {
                        phases.append($0); if $0 == stopPhase { cancelled = true }
                    })
                try job.writeRaw(result.0, check: {})
            }) { XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled) }
            XCTAssertTrue(phases.contains(stopPhase)); XCTAssertFalse(job.outputExists())
        }
    }

    private func canonicalPixels(_ pixel: [UInt8], count: Int) -> Data {
        var bytes = Data(count: count * 4)
        bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for offset in stride(from: 0, to: raw.count, by: 4) {
                for channel in 0..<4 { raw[offset + channel] = pixel[channel] }
            }
        }
        return bytes
    }
    private func fixture(profile: ImageDecodeDiagnosticProfile?, rgb: [UInt8] = [255, 0, 0],
                         alpha: UInt8 = 255, orientation: UInt8? = nil) throws -> Data {
        let width = profile?.sourceWidth ?? 768, height = profile?.sourceHeight ?? 576
        // Python zlib.compress(bytes((width + 1) * height), 9), including one
        // filter-zero byte per row. Long base64 runs are represented compactly.
        let compressed: String
        switch profile {
        case .some(.fourK):
            compressed = "eNrswQEBAAAAgJD+r+4ICg" + String(repeating: "A", count: 5_458)
                + "gNuDQwIAAAAAQf9f+8EM" + String(repeating: "A", count: 5_259) + "cAZ/SAAE="
        case .some(.fiveK):
            compressed = "eNrswQEBAAAAgJD+r+4ICg" + String(repeating: "A", count: 5_458)
                + "gNmDAwEAAAAAIP/XRlB" + String(repeating: "V", count: 5_460)
                + "hDw4EAAAAAID8XxtB" + String(repeating: "V", count: 5_460)
                + "pT04IAEAAAAQ9P91OwIV" + String(repeating: "A", count: 2_670) + "CAhwAYbwAB"
        case nil:
            compressed = "eNrtwQENAAAAwqD3T20PBxQ" + String(repeating: "A", count: 570) + "MCnAcKaAAE="
        }
        var ihdr = Data(count: 13); put(UInt32(width), in: &ihdr, at: 0); put(UInt32(height), in: &ihdr, at: 4)
        ihdr[8] = 8; ihdr[9] = 3 // Indexed color with 8-bit samples.
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        png.append(chunk("IHDR", ihdr)); png.append(chunk("sRGB", Data([0])))
        png.append(chunk("PLTE", Data(rgb))); png.append(chunk("tRNS", Data([alpha])))
        if let orientation {
            // Little-endian TIFF IFD containing one SHORT Orientation tag.
            let exif = Data([73, 73, 42, 0, 8, 0, 0, 0, 1, 0, 18, 1, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0, 0, 0, 0, 0])
            png.append(chunk("eXIf", exif))
        }
        png.append(chunk("IDAT", try XCTUnwrap(Data(base64Encoded: compressed))))
        png.append(chunk("IEND", Data()))
        return png
    }
    private func chunk(_ type: String, _ payload: Data) -> Data {
        var chunk = Data(count: 4); put(UInt32(payload.count), in: &chunk, at: 0)
        chunk.append(contentsOf: type.utf8); chunk.append(payload)
        let crc = checksum(Data(chunk.dropFirst(4))); let offset = chunk.count
        chunk.append(Data(count: 4)); put(crc, in: &chunk, at: offset)
        return chunk
    }
    private func put(_ value: UInt32, in data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
    }
    private func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        return crc ^ UInt32.max
    }
    private func repairIHDRCRC(_ png: inout Data) { put(checksum(Data(png[12..<29])), in: &png, at: 29) }
}
