import XCTest
import Foundation
import Darwin
import CPicShotCodecs
import PicShotCodecCore
@testable import PicShotCodecHelper

final class WebPContainerWriterTests: XCTestCase {
    func testNativeIndependentDemuxDecodesEveryOddSizedFrameAndTransparencyTransition() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unequal.webp")
        let writer = try makeWriter(url, width: 3, height: 5)
        let delays = [17, 33, 51, 199]
        let colors: [[UInt8]] = [[210, 20, 30, 255], [0, 0, 0, 0], [30, 140, 220, 127], [15, 210, 45, 255]]
        let expected = colors.map { Data(Array(repeating: $0, count: 15).flatMap { $0 }) }
        for (index, pixels) in expected.enumerated() {
            let raster = try CodecRaster(width: 3, height: 5, rgba: [UInt8](pixels))
            let packet = try AnimatedWebPEncoder.encodeFrame(raster: raster, request: losslessRequest)
            try writer.append(stillWebP: packet, durationMS: delays[index])
            XCTAssertEqual(writer.framesWritten, index + 1)
            XCTAssertEqual(try Data(contentsOf: url)[4..<8], Data(repeating: 0, count: 4), "RIFF size must remain invalid until all frames complete")
        }
        try writer.finish()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(writer.bytesWritten, data.count)
        XCTAssertEqual(writer.durationMS, 300)
        XCTAssertTrue(writer.hasAlpha)
        XCTAssertEqual(data[20], 0x12)
        let decoded = try independentDecode(data)
        XCTAssertEqual(decoded.width, 3); XCTAssertEqual(decoded.height, 5)
        XCTAssertEqual(decoded.loopCount, 0)
        XCTAssertEqual(decoded.delays, delays)
        XCTAssertEqual(decoded.frames, expected, "Full-canvas no-blend must clear earlier pixels when a later frame is transparent")
    }

    func testOpaqueAnimationHasNoAlphaFlagAndSamePixelsInEveryDecodedFrame() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("opaque.webp")
        let writer = try makeWriter(url, width: 5, height: 3)
        let raster = try CodecRaster(width: 5, height: 3, rgba: Array(repeating: [UInt8(90), 180, 250, 255], count: 15).flatMap { $0 })
        let packet = try AnimatedWebPEncoder.encodeFrame(raster: raster, request: losslessRequest)
        for duration in [33, 34, 33] { try writer.append(stillWebP: packet, durationMS: duration) }
        try writer.finish()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data[20], 0x02)
        XCTAssertFalse(writer.hasAlpha)
        let decoded = try independentDecode(data)
        XCTAssertEqual(decoded.delays, [33, 34, 33])
        XCTAssertEqual(decoded.frames, Array(repeating: Data(raster.rgba), count: 3))
    }

    func testLossyALPHChunksCarryRealPartialAlpha() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lossy-alpha.webp")
        let writer = try makeWriter(url, width: 5, height: 3)
        let pixels = Array(repeating: [90, 180, 230, 127] as [UInt8], count: 15).flatMap { $0 }
        let raster = try CodecRaster(width: 5, height: 3, rgba: pixels)
        let request = CodecExportRequest(kind: .animation, format: .webp, quality: 95, lossless: false,
                                        preserveAlpha: true, animation: .init())
        let packet = try AnimatedWebPEncoder.encodeFrame(raster: raster, request: request)
        let parsed = try WebPStillFrame.parse(packet)
        XCTAssertTrue(parsed.hasAlpha)
        XCTAssertEqual(parsed.subchunks.count, 2, "Lossy transparency must be carried by ALPH followed by VP8")
        try writer.append(stillWebP: packet, durationMS: 41)
        try writer.append(stillWebP: packet, durationMS: 42)
        try writer.finish()
        let decoded = try independentDecode(Data(contentsOf: url))
        XCTAssertEqual(decoded.delays, [41, 42])
        for frame in decoded.frames {
            for offset in stride(from: 0, to: frame.count, by: 4) {
                XCTAssertEqual(frame[offset + 3], 127)
                for component in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(frame[offset + component]) - Int(pixels[offset + component])), 12) }
            }
        }
    }

    func testMalformedContainersAndUnexpectedSubchunksAreRejectedBeforeAppend() throws {
        let raster = try CodecRaster(width: 3, height: 5, rgba: Array(repeating: [1, 2, 3, 255] as [UInt8], count: 15).flatMap { $0 })
        let packet = try AnimatedWebPEncoder.encodeFrame(raster: raster, request: losslessRequest)
        var badMagic = packet; badMagic[0] = 0
        var badSize = packet; badSize[4] ^= 1
        var tooLargeChunk = packet; for offset in 16..<20 { tooLargeChunk[offset] = 0xff }
        let chunk = packet.subdata(in: 12..<packet.count)
        var duplicate = packet + chunk; patchRIFF(&duplicate)
        var unknown = packet; unknown.replaceSubrange(12..<16, with: Data("EXIF".utf8))
        var animation = packet; animation.replaceSubrange(12..<16, with: Data("ANMF".utf8))
        for invalid in [Data(), Data(packet.prefix(15)), Data(packet.dropLast()), badMagic, badSize, tooLargeChunk, duplicate, unknown, animation] {
            XCTAssertThrowsError(try WebPStillFrame.parse(invalid))
        }
        var oversized = Data(repeating: 0, count: CodecExportLimits.animationFrameBytes + 1)
        oversized.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        XCTAssertThrowsError(try WebPStillFrame.parse(oversized))
    }

    func testReservedLosslessVersionAndOddChunkPaddingAreRejected() throws {
        func packet(payload: [UInt8], pad: UInt8 = 0) -> Data {
            let length = payload.count
            let chunk = Data("VP8L".utf8) + Data((0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
                + Data(payload) + (length & 1 == 1 ? Data([pad]) : Data())
            let riffSize = chunk.count + 4
            return Data("RIFF".utf8) + Data((0..<4).map { UInt8(truncatingIfNeeded: riffSize >> ($0 * 8)) })
                + Data("WEBP".utf8) + chunk
        }
        // These deliberately tiny bitstream headers exercise admission only;
        // every successful file test above uses real native encoded payloads.
        XCTAssertThrowsError(try WebPStillFrame.parse(packet(payload: [0x2f, 2, 0, 1, 0], pad: 0xff)))
        XCTAssertThrowsError(try WebPStillFrame.parse(packet(payload: [0x2f, 2, 0, 1, 0x20])))
        XCTAssertThrowsError(try WebPStillFrame.parse(packet(payload: [0x2f, 0xff, 0x3f, 1, 0])))
    }

    func testDimensionMismatchAndFailedAppendCannotBeFinalized() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mismatch.webp")
        let writer = try makeWriter(url, width: 4, height: 5)
        let packet = try frame(width: 3, height: 5)
        XCTAssertThrowsError(try writer.append(stillWebP: packet, durationMS: 30))
        XCTAssertThrowsError(try writer.finish())
        XCTAssertEqual(try Data(contentsOf: url)[4..<8], Data(repeating: 0, count: 4))
    }

    func testExactOutputFrameDurationAndCountCaps() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let packet = try frame(width: 3, height: 5)
        let parsed = try WebPStillFrame.parse(packet)
        let oneFrameBytes = 44 + 24 + parsed.subchunks.reduce(0) { $0 + $1.count }
        let exact = try makeWriter(directory.appendingPathComponent("exact.webp"), width: 3, height: 5, maximumBytes: oneFrameBytes)
        try exact.append(stillWebP: packet, durationMS: 60_000); try exact.finish()
        XCTAssertEqual(exact.bytesWritten, oneFrameBytes)
        let capped = try makeWriter(directory.appendingPathComponent("bytes.webp"), width: 3, height: 5, maximumBytes: oneFrameBytes - 1)
        XCTAssertThrowsError(try capped.append(stillWebP: packet, durationMS: 1))
        XCTAssertThrowsError(try capped.finish())
        let frameCap = try makeWriter(directory.appendingPathComponent("frame.webp"), width: 3, height: 5, frameByteLimit: packet.count - 1)
        XCTAssertThrowsError(try frameCap.append(stillWebP: packet, durationMS: 1))
        let countCap = try makeWriter(directory.appendingPathComponent("count.webp"), width: 3, height: 5)
        for _ in 0..<600 { try countCap.append(stillWebP: packet, durationMS: 1) }
        XCTAssertThrowsError(try countCap.append(stillWebP: packet, durationMS: 1))
        let durationCap = try makeWriter(directory.appendingPathComponent("duration.webp"), width: 3, height: 5)
        try durationCap.append(stillWebP: packet, durationMS: 60_000)
        XCTAssertThrowsError(try durationCap.append(stillWebP: packet, durationMS: 1))
    }

    func testCancellationLeavesUnfinalizedHeaderAndRejectsFurtherWrites() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel.webp")
        var cancelled = false
        let writer = try makeWriter(url, width: 3, height: 5, cancelled: { cancelled })
        try writer.append(stillWebP: frame(width: 3, height: 5), durationMS: 33)
        cancelled = true
        XCTAssertThrowsError(try writer.finish()) { XCTAssertTrue($0 is CancellationError) }
        cancelled = false
        XCTAssertThrowsError(try writer.finish())
        XCTAssertEqual(try Data(contentsOf: url)[4..<8], Data(repeating: 0, count: 4))
        XCTAssertThrowsError(try AnimatedWebPEncoder.encodeFrame(raster: CodecRaster(width: 1, height: 1, rgba: [1, 2, 3, 255]),
                                                               request: losslessRequest, isCancelled: { true }))
    }

    private var losslessRequest: CodecExportRequest {
        CodecExportRequest(kind: .animation, format: .webp, lossless: true, animation: .init())
    }
    private func frame(width: Int, height: Int) throws -> Data {
        let raster = try CodecRaster(width: width, height: height, rgba: Array(repeating: [UInt8(100), 50, 200, 255], count: width * height).flatMap { $0 })
        return try AnimatedWebPEncoder.encodeFrame(raster: raster, request: losslessRequest)
    }
    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-WebP-Container-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func makeWriter(_ url: URL, width: Int, height: Int,
                            maximumBytes: Int = CodecExportLimits.animationOutputBytes,
                            frameByteLimit: Int = CodecExportLimits.animationFrameBytes,
                            cancelled: @escaping () -> Bool = { false }) throws -> WebPContainerWriter {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return try WebPContainerWriter(fileDescriptor: fd, width: width, height: height,
                                      maximumBytes: maximumBytes, frameByteLimit: frameByteLimit, cancelled: cancelled)
    }
    private func patchRIFF(_ data: inout Data) {
        let count = data.count - 8
        for offset in 0..<4 { data[4 + offset] = UInt8(truncatingIfNeeded: count >> (offset * 8)) }
    }
    private struct Decoded {
        let width: Int, height: Int, loopCount: Int
        var frames: [Data] = [], delays: [Int] = []
    }
    private func independentDecode(_ data: Data) throws -> Decoded {
        var error = PSCodecError()
        let animation = try XCTUnwrap(data.withUnsafeBytes { bytes in
            PSCodecWebPAnimationOpen(bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(data.count),
                                    1_920 * 1_920, 600, 1_920 * 1_920 * 4, &error)
        }, "The independent native WebPDemux/WebPAnimDecoder must accept the complete container")
        defer { PSCodecAnimationFree(animation) }
        var decoded = Decoded(width: Int(PSCodecAnimationWidth(animation)), height: Int(PSCodecAnimationHeight(animation)),
                              loopCount: Int(PSCodecAnimationLoopCount(animation)))
        let count = Int(PSCodecAnimationFrameCount(animation))
        for _ in 0..<count {
            var pixels: UnsafePointer<UInt8>?, bytes: UInt64 = 0, duration: UInt32 = 0
            XCTAssertEqual(PSCodecAnimationNext(animation, &pixels, &bytes, &duration, &error), Int32(PS_CODEC_OK))
            decoded.frames.append(Data(bytes: try XCTUnwrap(pixels), count: Int(bytes)))
            decoded.delays.append(Int(duration))
        }
        var pixels: UnsafePointer<UInt8>?, bytes: UInt64 = 0, duration: UInt32 = 0
        XCTAssertEqual(PSCodecAnimationNext(animation, &pixels, &bytes, &duration, &error), Int32(PS_CODEC_END))
        XCTAssertEqual(Int(PSCodecAnimationDurationMS(animation)), decoded.delays.reduce(0, +))
        return decoded
    }
}
