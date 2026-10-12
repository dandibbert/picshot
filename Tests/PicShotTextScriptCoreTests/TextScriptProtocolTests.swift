import Foundation
import XCTest
@testable import PicShotTextScriptCore

final class TextScriptProtocolTests: XCTestCase {
    private let identifier = UUID(uuidString: "A74A3442-1FB4-4C42-B638-E7A87AB8C50B")!

    func testRoundTripKeepsSourceAndOCRSeparateIncludingUnicodeAndNUL() throws {
        let request = TextScriptRequest.transform(requestID: identifier,
            source: "return text.replace(/PIC-([0-9]+)/g, 'issue:$1');",
            text: "中文🙂 PIC-12 \u{0000} ");
        let encoded = try TextScriptProtocol.encodeRequest(request)
        XCTAssertEqual(try TextScriptProtocol.decodeRequest(encoded), request)
        let response = TextScriptResponse.success(requestID: identifier, output: " \u{0000}中文🙂\n")
        let output = try TextScriptProtocol.encodeResponse(response)
        XCTAssertEqual(output.last, 0x0a)
        XCTAssertEqual(try TextScriptProtocol.decodeResponse(output, for: request), response)
    }

    func testExactSourceAndInputLimits() throws {
        let request = TextScriptRequest.transform(requestID: identifier,
            source: String(repeating: " ", count: TextScriptLimits.sourceBytes),
            text: String(repeating: "🙂", count: TextScriptLimits.inputUTF16Units / 2))
        XCTAssertNoThrow(try TextScriptProtocol.encodeRequest(request))
        XCTAssertThrowsError(try TextScriptRequest.transform(source: request.source! + " ", text: "x").validate()) {
            XCTAssertEqual($0 as? TextScriptDiagnostic, .sourceTooLarge)
        }
        XCTAssertThrowsError(try TextScriptRequest.transform(source: "return text;", text: request.text! + "x").validate()) {
            XCTAssertEqual($0 as? TextScriptDiagnostic, .inputTooLarge)
        }
        XCTAssertThrowsError(try TextScriptRequest.transform(source: "return text;", text: "").validate())
        XCTAssertNoThrow(try TextScriptRequest.transform(source: "return text;", text: " ").validate())
    }

    func testRejectsExtraKeysDuplicateKeysMixedOperationsAndSecondDocument() throws {
        let request = TextScriptRequest.transform(requestID: identifier, source: "return text;", text: "x")
        let data = try TextScriptProtocol.encodeRequest(request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unrecognized"] = true
        XCTAssertThrowsError(try TextScriptProtocol.decodeRequest(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "unrecognized")
        object["probe"] = ["loopbackPort": 12345]
        XCTAssertThrowsError(try TextScriptProtocol.decodeRequest(JSONSerialization.data(withJSONObject: object)))
        let valid = String(decoding: data, as: UTF8.self)
        let duplicate = valid.replacingOccurrences(of: "{", with: "{\"text\":\"first\",", options: [], range: valid.startIndex..<valid.index(after: valid.startIndex))
        XCTAssertThrowsError(try TextScriptProtocol.decodeRequest(Data(duplicate.utf8)))
        let escapedDuplicate = valid.replacingOccurrences(of: "{", with: "{\"t\\u0065xt\":\"first\",", options: [], range: valid.startIndex..<valid.index(after: valid.startIndex))
        XCTAssertThrowsError(try TextScriptProtocol.decodeRequest(Data(escapedDuplicate.utf8)))
        XCTAssertThrowsError(try TextScriptProtocol.decodeRequest(Data((valid + "\n" + valid).utf8)))
        XCTAssertThrowsError(try TextScriptProtocol.decodeRequest(Data(repeating: 0x20, count: TextScriptLimits.requestBytes + 1)))
    }

    func testRejectsMalformedUnicodeInsteadOfReplacingIt() throws {
        let prefix = "{\"schemaVersion\":1,\"requestID\":\"\(identifier)\",\"operation\":\"transform\",\"source\":\"return text;\",\"text\":"
        for bad in ["\"\\ud800\"", "\"\\udc00\"", "\"\\ud800x\\udc00\"", "\"\\ud800\\u0041\""] {
            XCTAssertThrowsError(try TextScriptProtocol.decodeRequest(Data((prefix + bad + "}").utf8)))
        }
        let pair = Data((prefix + "\"\\ud83d\\ude42\"}").utf8)
        XCTAssertEqual(try TextScriptProtocol.decodeRequest(pair).text, "🙂")
        var invalidUTF8 = Data((prefix + "\"").utf8)
        invalidUTF8.append(contentsOf: [0xc0, 0xaf])
        invalidUTF8.append(contentsOf: [0x22, 0x7d])
        XCTAssertThrowsError(try TextScriptProtocol.decodeRequest(invalidUTF8))
    }

    func testWrongIdentityVersionAndContradictoryResponsesAreRejected() throws {
        let request = TextScriptRequest.transform(requestID: identifier, source: "return text;", text: "x")
        let responses = [
            TextScriptResponse.success(requestID: UUID(), output: "x"),
            TextScriptResponse(schemaVersion: 2, requestID: identifier, status: .success, output: "x"),
            TextScriptResponse(requestID: identifier, status: .success, output: "x", diagnostic: .syntaxError),
            TextScriptResponse(requestID: identifier, status: .failure, output: "x", diagnostic: .syntaxError),
            TextScriptResponse.success(requestID: identifier, output: ""),
            TextScriptResponse.success(requestID: identifier, output: String(repeating: "x", count: TextScriptLimits.outputUTF16Units + 1))
        ]
        for response in responses {
            XCTAssertThrowsError(try TextScriptProtocol.decodeResponse(TextScriptProtocol.encodeResponse(response), for: request))
        }
        XCTAssertThrowsError(try TextScriptProtocol.decodeResponse(Data(repeating: 0x20, count: TextScriptLimits.responseBytes + 1), for: request))
    }

    func testResponseRequiresExactlyOneNewlineTerminatedDocument() throws {
        let request = TextScriptRequest.transform(requestID: identifier, source: "return text;", text: "x")
        let valid = try TextScriptProtocol.encodeResponse(.success(requestID: identifier, output: "line1\nline2\rline3"))
        XCTAssertNoThrow(try TextScriptProtocol.decodeResponse(valid, for: request))
        XCTAssertThrowsError(try TextScriptProtocol.decodeResponse(Data(valid.dropLast()), for: request))
        XCTAssertThrowsError(try TextScriptProtocol.decodeResponse(valid + Data([0x0a]), for: request))
        XCTAssertThrowsError(try TextScriptProtocol.decodeResponse(Data([0x0a]) + valid, for: request))
        XCTAssertThrowsError(try TextScriptProtocol.decodeResponse(Data(valid.dropLast()) + Data([0x0d, 0x0a]), for: request))
        XCTAssertThrowsError(try TextScriptProtocol.decodeResponse(valid + valid, for: request))
    }

    func testPermissionErrnosAreRequiredForNativeProbeEvidence() throws {
        let request = TextScriptRequest.capabilityProbe(requestID: identifier, loopbackPort: 12345)
        XCTAssertEqual(try TextScriptProtocol.decodeRequest(TextScriptProtocol.encodeRequest(request)), request)
        XCTAssertEqual(TextScriptProbeRequest.sentinelDirectory(for: identifier),
                       "/private/tmp/picshot-text-script-gate-a74a3442-1fb4-4c42-b638-e7a87ab8c50b")
        let good = TextScriptProbeResult(readDenied: true, writeDenied: true, networkDenied: true,
                                        readErrno: 1, writeErrno: 13, networkErrno: 1)
        XCTAssertNoThrow(try TextScriptResponse.success(requestID: identifier, probe: good).validate(for: request))
        let missingAndRefused = TextScriptProbeResult(readDenied: true, writeDenied: true, networkDenied: true,
                                                    readErrno: 2, writeErrno: 2, networkErrno: 61)
        XCTAssertThrowsError(try TextScriptResponse.success(requestID: identifier, probe: missingAndRefused).validate(for: request))
    }

    func testFailureWireContainsOnlyFixedCodeAndIdentity() throws {
        let response = TextScriptResponse.failure(requestID: identifier, diagnostic: .scriptException)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: TextScriptProtocol.encodeResponse(response)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "requestID", "status", "diagnostic"])
        XCTAssertEqual(object["diagnostic"] as? String, "scriptException")
    }
}
