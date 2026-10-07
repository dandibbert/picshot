import XCTest
import Foundation
@testable import PicShotCodecCore

final class ImageDecodeTimingTraceTests: XCTestCase {
    func testOptInArgumentAndIndependentBoundedFrameRoundTrip() throws {
        XCTAssertEqual(ImageDecodeDiagnosticLimits.largeTimingArgument, "--image-draw-decode-diagnostic-v3")
        XCTAssertEqual(ImageDecodeDiagnosticLimits.largeArgument, "--image-draw-decode-diagnostic-v2")
        XCTAssertEqual(ImageDecodeDiagnosticLimits.largeSchema, "image-decode-helper-v2")
        let trace = value(), frame = try trace.encodeFrame()
        XCTAssertEqual(trace.schema, "image-decode-tail-v3")
        XCTAssertLessThanOrEqual(frame.count, 1_024)
        XCTAssertEqual(frame.filter { $0 == 10 }.count, 1)
        XCTAssertEqual(frame.last, 10)
        XCTAssertEqual(try ImageDecodeTimingTrace.decodeFrame(frame), trace)
        var decoder = ImageDecodeTimingTraceDecoder(), decoded: [ImageDecodeTimingTrace] = []
        for byte in frame { decoded += try decoder.consume(Data([byte])) }
        try decoder.finish(); XCTAssertEqual(decoded, [trace])
        XCTAssertTrue(try decoder.consume(Data()).isEmpty)
        XCTAssertThrowsError(try decoder.consume(Data([32])))
        XCTAssertThrowsError(try ImageDecodeDiagnosticRequest.decode(Data(frame.dropLast())))
        var stdout = ImageDecodeDiagnosticEventDecoder()
        XCTAssertThrowsError(try stdout.consume(frame))
    }

    func testAbsentFailedAndFallbackTerminalWriteStatesAreExplicit() throws {
        let states = [value(start: nil, complete: nil, attempts: 0, succeeded: false),
                      value(complete: nil, succeeded: false),
                      value(complete: nil, attempts: 2, succeeded: false), value(attempts: 2)]
        for trace in states { XCTAssertEqual(try ImageDecodeTimingTrace.decodeFrame(trace.encodeFrame()), trace) }
        let absent = try object(states[0])
        XCTAssertNil(absent["terminalWriteStartedUptimeSeconds"])
        XCTAssertNil(absent["terminalWriteCompletedUptimeSeconds"])
        XCTAssertEqual(absent["terminalWriteAttemptCount"] as? Int, 0)
        XCTAssertEqual(absent["terminalWriteSucceeded"] as? Bool, false)
        for bad in [value(start: nil), value(start: nil, complete: nil, attempts: 1, succeeded: false),
                    value(attempts: 0), value(attempts: -1), value(attempts: 3),
                    value(complete: nil), value(succeeded: false),
                    value(start: nil, complete: nil, attempts: 0, succeeded: true)] {
            XCTAssertThrowsError(try bad.validate())
            XCTAssertThrowsError(try bad.encodeFrame())
        }
    }

    func testAllTimesMustBeFiniteNonnegativeAndMonotone() throws {
        for bad in [-1.0, -.infinity, .infinity, .nan] {
            for trace in [value(start: bad), value(complete: bad), value(returned: bad), value(prepared: bad)] {
                XCTAssertThrowsError(try trace.validate())
                XCTAssertThrowsError(try trace.encodeFrame())
            }
        }
        for bad in [value(start: 2.1), value(complete: 3.1), value(returned: 4.1), value(prepared: 2.9),
                    value(start: 3.1, complete: nil, succeeded: false)] {
            XCTAssertThrowsError(try bad.validate())
        }
        try value(start: 0, complete: 0, returned: 0, prepared: 0).validate()
        try value(start: 4, complete: 4, returned: 4, prepared: 4).validate()
    }

    func testStrictKeysTypesNullDepthAndPID() throws {
        let good = try object(value())
        let replacements: [(String, Any)] = [
            ("schema", "image-decode-helper-v2"), ("schema", true),
            ("childPID", 1), ("childPID", -1), ("childPID", Int64(Int32.max) + 1),
            ("childPID", true), ("childPID", 12.5),
            ("terminalWriteAttemptCount", true), ("terminalWriteAttemptCount", 1.5),
            ("terminalWriteAttemptCount", 3), ("terminalWriteSucceeded", 1),
            ("terminalWriteSucceeded", "true"), ("runReturnedUptimeSeconds", "3"),
            ("runReturnedUptimeSeconds", true), ("framePreparedUptimeSeconds", NSNull()),
            ("terminalWriteStartedUptimeSeconds", NSNull()), ("terminalWriteCompletedUptimeSeconds", NSNull()),
            ("terminalWriteStartedUptimeSeconds", [1]), ("runReturnedUptimeSeconds", ["nested": 3]),
            ("unexpected", "extra")
        ]
        for (key, replacement) in replacements {
            var object = good; object[key] = replacement
            XCTAssertThrowsError(try ImageDecodeTimingTrace.decodeFrame(line(object)), key)
        }
        for key in ["schema", "childPID", "terminalWriteAttemptCount", "terminalWriteSucceeded", "runReturnedUptimeSeconds", "framePreparedUptimeSeconds"] {
            var object = good; object.removeValue(forKey: key)
            XCTAssertThrowsError(try ImageDecodeTimingTrace.decodeFrame(line(object)), key)
        }
    }

    func testDuplicatesIncludingEscapedKeysAreRejected() throws {
        let payload = Data(try value().encodeFrame().dropLast())
        for key in ["schema", "sch\\u0065ma"] {
            let duplicate = Data("{\"\(key)\":\"image-decode-tail-v3\",".utf8) + payload.dropFirst() + Data([10])
            XCTAssertThrowsError(try ImageDecodeTimingTrace.decodeFrame(duplicate))
        }
    }

    func testNonfiniteWireNumbersAreRejected() throws {
        let frame = try XCTUnwrap(String(data: value().encodeFrame(), encoding: .utf8))
        for number in ["NaN", "Infinity", "-Infinity", "1e9999", "-1"] {
            let invalid = frame.replacingOccurrences(of: "\"runReturnedUptimeSeconds\":3", with: "\"runReturnedUptimeSeconds\":\(number)")
            XCTAssertNotEqual(invalid, frame)
            XCTAssertThrowsError(try ImageDecodeTimingTrace.decodeFrame(Data(invalid.utf8)))
        }
    }

    func testMissingPartialExtraAndTrailingFramesAreRejected() throws {
        let frame = try value().encodeFrame(), payload = Data(frame.dropLast())
        for invalid in [Data(), Data([10]), payload, Data("[]\n".utf8), Data("null\n".utf8),
                        frame + frame, frame + Data([10]), frame + Data([32]),
                        payload + payload + Data([10]), payload + Data("\r\n".utf8),
                        Data("{\n".utf8) + payload.dropFirst() + Data([10]),
                        Data("{\"schema\":\"unterminated}\n".utf8)] {
            XCTAssertThrowsError(try ImageDecodeTimingTrace.decodeFrame(invalid))
        }
        var absent = ImageDecodeTimingTraceDecoder()
        XCTAssertTrue(try absent.consume(Data()).isEmpty)
        XCTAssertThrowsError(try absent.finish())
        var partial = ImageDecodeTimingTraceDecoder()
        XCTAssertTrue(try partial.consume(payload).isEmpty)
        XCTAssertThrowsError(try partial.finish())
        var secondChunk = ImageDecodeTimingTraceDecoder()
        _ = try secondChunk.consume(frame)
        XCTAssertThrowsError(try secondChunk.consume(frame))
    }

    func testCapIncludesNewlineAndAppliesAcrossChunks() throws {
        let payload = Data(try value().encodeFrame().dropLast())
        let boundary = payload + Data(repeating: 32, count: ImageDecodeTimingTrace.frameBytes - payload.count - 1) + Data([10])
        XCTAssertEqual(boundary.count, 1_024)
        XCTAssertEqual(try ImageDecodeTimingTrace.decodeFrame(boundary), value())
        let oversized = Data(boundary.dropLast()) + Data([32, 10])
        XCTAssertThrowsError(try ImageDecodeTimingTrace.decodeFrame(oversized))
        var partial = ImageDecodeTimingTraceDecoder()
        _ = try partial.consume(Data(boundary.dropLast()))
        XCTAssertThrowsError(try partial.consume(Data([32])))
        var aggregate = ImageDecodeTimingTraceDecoder()
        _ = try aggregate.consume(boundary)
        XCTAssertThrowsError(try aggregate.consume(Data([32])))
        XCTAssertThrowsError(try ImageDecodeTimingTrace.decodeFrame(Data(repeating: 32, count: 1_025)))
    }

    private func value(start: Double? = 1, complete: Double? = 2, attempts: Int = 1,
                       returned: Double = 3, prepared: Double = 4, succeeded: Bool = true) -> ImageDecodeTimingTrace {
        .init(childPID: 123, terminalWriteStartedUptimeSeconds: start, terminalWriteCompletedUptimeSeconds: complete,
              terminalWriteAttemptCount: attempts, runReturnedUptimeSeconds: returned,
              framePreparedUptimeSeconds: prepared, terminalWriteSucceeded: succeeded)
    }
    private func object(_ trace: ImageDecodeTimingTrace) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trace)) as? [String: Any])
    }
    private func line(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) + Data([10]) }
}
