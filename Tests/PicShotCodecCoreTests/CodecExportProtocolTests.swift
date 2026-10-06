import XCTest
import Foundation
@testable import PicShotCodecCore

final class CodecExportProtocolTests: XCTestCase {
    func testStillAndAnimationRoundTrips() throws {
        let requests = [CodecExportRequest(format: .avif, quality: 73, lossless: true),
            CodecExportRequest(kind: .animation, format: .webp, quality: 84, preserveAlpha: false,
                               alphaQuality: 91, animation: .init(frameRate: 24, maximumDimension: 1_280, maximumFrames: 300, maximumDuration: 12))]
        for request in requests {
            let data = try CodecExportProtocol.encodeRequestLine(request)
            XCTAssertEqual(data.last, 10)
            XCTAssertEqual(try CodecExportProtocol.decodeRequestLine(data), request)
        }
    }
    func testMalformedRequestsFailClosed() throws {
        let good = String(decoding: try CodecExportProtocol.encodeRequestLine(.init(format: .webp)), as: UTF8.self)
        let cases = [
            good.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
            good.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"vers\\u0069on\":1"),
            good.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
            good.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            good.replacingOccurrences(of: "\"lossless\":false", with: "\"lossless\":0"),
            good.replacingOccurrences(of: "\"quality\":80", with: "\"quality\":80.5"),
            good.replacingOccurrences(of: "\"quality\":80", with: "\"quality\":null"),
            good.replacingOccurrences(of: "\"quality\":80", with: "\"quality\":101"),
            good.replacingOccurrences(of: "\"quality\":80", with: "\"quality\":-1"),
            good.replacingOccurrences(of: "\"quality\":80", with: "\"quality\":[]"),
            good.replacingOccurrences(of: "\"quality\":80", with: "\"quality\":{\"nested\":{\"x\":1}}"),
            good.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"path\":\"/tmp/other.png\""),
            good.replacingOccurrences(of: "\"kind\":\"still\"", with: "\"kind\":\"animation\""),
            good + good, "[]\n", "null\n", "{}\r\n", "{\n}\n"
        ]
        for value in cases { XCTAssertThrowsError(try CodecExportProtocol.decodeRequestLine(Data(value.utf8)), value) }
        XCTAssertThrowsError(try CodecExportProtocol.decodeRequestLine(Data(repeating: 32, count: CodecExportLimits.requestBytes + 1)))
    }
    func testOptionsRejectInvalidAndOverflowingDimensions() throws {
        for pair in [(0, 1), (1, 0), (-1, 2), (Int.max, 1), (4_001, 4_000), (8_193, 1)] {
            XCTAssertThrowsError(try CodecExportLimits.validateStillDimensions(width: pair.0, height: pair.1))
        }
        try CodecExportLimits.validateStillDimensions(width: 4_000, height: 4_000)
        try CodecExportLimits.validateStillDimensions(width: 13, height: 9)
        for duration in [0.0, -1, 60.1, .infinity, .nan] { XCTAssertThrowsError(try CodecAnimationOptions(maximumDuration: duration).validate()) }
        XCTAssertThrowsError(try CodecAnimationOptions(maximumFrames: 601).validate())
        XCTAssertThrowsError(try CodecAnimationOptions(maximumDimension: 1_921).validate())
        XCTAssertThrowsError(try CodecAnimationOptions(frameRate: 31).validate())
        XCTAssertThrowsError(try CodecExportRequest(kind: .animation, format: .avif, animation: .init()).validate())
        XCTAssertThrowsError(try CodecExportRequest(format: .webp, alphaQuality: 101).validate())
    }
    func testStrictResponseShapeAndRequestBinding() throws {
        let result = CodecExportResponse(kind: .result, format: .webp, outputBytes: 120,
            width: 13, height: 9, frameCount: 1, duration: 0, previewBytes: 80, sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(try CodecExportProtocol.decodeResponseLine(CodecExportProtocol.encodeResponseLine(result)), result)
        try result.validate(for: .init(format: .webp))
        XCTAssertThrowsError(try result.validate(for: .init(format: .avif)))
        var invalid = result; invalid.sha256 = String(repeating: "G", count: 64)
        XCTAssertThrowsError(try invalid.validate())
        invalid = result; invalid.outputBytes = CodecExportLimits.stillOutputBytes + 1
        XCTAssertThrowsError(try invalid.validate())
        invalid = result; invalid.previewBytes = CodecExportLimits.previewBytes + 1
        XCTAssertThrowsError(try invalid.validate())
        invalid = result; invalid.errorCode = .cancelled
        XCTAssertThrowsError(try invalid.validate())
        invalid = result; invalid.duration = 0.3; invalid.width = 1_921
        XCTAssertThrowsError(try invalid.validate())
        invalid = .init(kind: .progress, fraction: .nan)
        XCTAssertThrowsError(try invalid.validate())
        invalid = .init(kind: .error, errorCode: .cancelled); invalid.residentSampleCount = -1
        XCTAssertThrowsError(try invalid.validate())
        let encoded = try CodecExportProtocol.encodeResponseLine(result)
        let text = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"other\":1")
        XCTAssertThrowsError(try CodecExportProtocol.decodeResponseLine(Data(text.utf8)))
        XCTAssertThrowsError(try CodecExportProtocol.decodeResponseLine(Data("{\"version\":1,\"kind\":\"error\",\"errorCode\":\"untrustedText\"}\n".utf8)))
    }
    func testTerminalMemoryEvidenceRequiresMatchingPositivePairs() throws {
        var response = CodecExportResponse(kind: .error, errorCode: .cancelled)
        try response.validate() // Missing observations are explicitly absent.
        let pairs: [(UInt64?, Int?)] = [(nil, 1), (128, nil), (nil, 0), (0, 1), (128, 0), (128, 10_001)]
        for (peak, count) in pairs {
            response.sampledPeakResidentBytes = peak; response.residentSampleCount = count
            XCTAssertThrowsError(try response.validate())
            response.sampledPeakResidentBytes = nil; response.residentSampleCount = nil
            response.sampledPeakPhysicalFootprintBytes = peak; response.physicalFootprintSampleCount = count
            XCTAssertThrowsError(try response.validate())
            response.sampledPeakPhysicalFootprintBytes = nil; response.physicalFootprintSampleCount = nil
        }
        response.sampledPeakResidentBytes = 128; response.residentSampleCount = 1
        response.sampledPeakPhysicalFootprintBytes = 256; response.physicalFootprintSampleCount = 2
        XCTAssertEqual(try CodecExportProtocol.decodeResponseLine(CodecExportProtocol.encodeResponseLine(response)), response)
    }
    func testIncrementalFramingCancellationAndEOF() throws {
        let line = try CodecExportProtocol.encodeRequestLine(.init(format: .webp))
        var decoder = CodecExportInputDecoder(), count = 0
        for byte in line { count += try decoder.consume(Data([byte])).count }
        XCTAssertEqual(count, 1); XCTAssertTrue(decoder.receivedRequest)
        XCTAssertEqual(try decoder.consume(CodecExportProtocol.cancelLine).count, 1)
        try decoder.finish()
        XCTAssertThrowsError(try decoder.consume(CodecExportProtocol.cancelLine))
        var incomplete = CodecExportInputDecoder()
        _ = try incomplete.consume(line.dropLast())
        XCTAssertThrowsError(try incomplete.finish())
        var extra = CodecExportInputDecoder()
        _ = try extra.consume(line)
        XCTAssertThrowsError(try extra.consume(line))
        var huge = CodecExportInputDecoder()
        XCTAssertThrowsError(try huge.consume(Data(repeating: 65, count: CodecExportLimits.requestBytes + 1)))
        for input in ["{\"cancel\":false}\n", "{\"cancel\":1}\n", "{\"cancel\":true,\"cancel\":true}\n", "{\"cancel\":true,\"other\":0}\n"] {
            XCTAssertThrowsError(try CodecExportProtocol.decodeCancelLine(Data(input.utf8)))
        }
    }
    func testContainerMagicRejectsRenamedTruncatedAndLengthMismatch() throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10] + [UInt8](repeating: 0, count: 32))
        XCTAssertThrowsError(try CodecOutputMagic.validate(png, format: .webp))
        XCTAssertThrowsError(try CodecOutputMagic.validate(png, format: .avif))
        var webp = Data("RIFF".utf8); webp.append(contentsOf: [12, 0, 0, 0]); webp.append(Data("WEBPVP8 ".utf8)); webp.append(contentsOf: [0, 0, 0, 0])
        try CodecOutputMagic.validate(webp, format: .webp)
        webp[4] = 13; XCTAssertThrowsError(try CodecOutputMagic.validate(webp, format: .webp))
        var avif = Data([0, 0, 0, 24]); avif.append(Data("ftypavif".utf8)); avif.append(contentsOf: [0, 0, 0, 0]); avif.append(Data("mif1avif".utf8))
        try CodecOutputMagic.validate(avif, format: .avif)
        avif[3] = 28; XCTAssertThrowsError(try CodecOutputMagic.validate(avif, format: .avif))
    }
}
