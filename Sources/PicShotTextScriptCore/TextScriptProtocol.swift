import Foundation

public enum TextScriptProtocol {
    /// One EOF-delimited JSON request. Closing stdin is required; a second object is invalid.
    public static func encodeRequest(_ request: TextScriptRequest) throws -> Data {
        try request.validate()
        let data = try encoder().encode(request)
        guard data.count <= TextScriptLimits.requestBytes else { throw TextScriptDiagnostic.invalidRequest }
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> TextScriptRequest {
        let object = try envelope(data, maximumBytes: TextScriptLimits.requestBytes)
        let request: TextScriptRequest
        do { request = try JSONDecoder().decode(TextScriptRequest.self, from: data) }
        catch { throw TextScriptDiagnostic.invalidRequest }
        switch request.operation {
        case .transform:
            try keys(object, exactly: ["schemaVersion", "requestID", "operation", "source", "text"])
        case .capabilityProbe:
            try keys(object, exactly: ["schemaVersion", "requestID", "operation", "probe"])
            guard let probe = object["probe"] as? [String: Any] else { throw TextScriptDiagnostic.invalidRequest }
            try keys(probe, exactly: ["loopbackPort"])
        }
        try request.validate()
        return request
    }

    /// Exactly one JSON response with a final newline; no progress or script-derived logging.
    public static func encodeResponse(_ response: TextScriptResponse) throws -> Data {
        var data = try encoder().encode(response)
        data.append(0x0a)
        guard data.count <= TextScriptLimits.responseBytes else { throw TextScriptDiagnostic.outputTooLarge }
        return data
    }

    public static func decodeResponse(_ data: Data, for request: TextScriptRequest) throws -> TextScriptResponse {
        do {
            guard data.last == 0x0a,
                  !data.dropLast().contains(0x0a), !data.dropLast().contains(0x0d) else {
                throw TextScriptDiagnostic.protocolViolation
            }
            let object = try envelope(data, maximumBytes: TextScriptLimits.responseBytes)
            let response = try JSONDecoder().decode(TextScriptResponse.self, from: data)
            var expected: Set<String> = ["schemaVersion", "requestID", "status"]
            if response.status == .failure { expected.insert("diagnostic") }
            else if request.operation == .transform { expected.insert("output") }
            else {
                expected.insert("probe")
                guard let probe = object["probe"] as? [String: Any] else { throw TextScriptDiagnostic.protocolViolation }
                try keys(probe, exactly: ["readDenied", "writeDenied", "networkDenied", "readErrno", "writeErrno", "networkErrno"])
            }
            try keys(object, exactly: expected)
            try response.validate(for: request)
            return response
        } catch { throw TextScriptDiagnostic.protocolViolation }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func keys(_ object: [String: Any], exactly expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw TextScriptDiagnostic.invalidRequest }
    }

    private static func envelope(_ data: Data, maximumBytes: Int) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBytes,
              String(data: data, encoding: .utf8) != nil else { throw TextScriptDiagnostic.invalidRequest }
        // Check Unicode escapes and duplicate keys before Foundation can normalize either.
        try validateStringTokens(data)
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TextScriptDiagnostic.invalidRequest
            }
            return object
        } catch { throw TextScriptDiagnostic.invalidRequest }
    }

    private static func validateStringTokens(_ data: Data) throws {
        let bytes = [UInt8](data)
        var index = 0
        var objectKeys: [Set<String>] = []
        func fail() -> TextScriptDiagnostic { .invalidRequest }
        func hex(_ start: Int) throws -> UInt16 {
            guard start + 4 <= bytes.count else { throw fail() }
            var value: UInt16 = 0
            for i in start..<(start + 4) {
                let digit: UInt16
                switch bytes[i] {
                case 48...57: digit = UInt16(bytes[i] - 48)
                case 65...70: digit = UInt16(bytes[i] - 55)
                case 97...102: digit = UInt16(bytes[i] - 87)
                default: throw fail()
                }
                value = value * 16 + digit
            }
            return value
        }
        while index < bytes.count {
            if bytes[index] == 0x7b {
                guard objectKeys.count < 4 else { throw fail() }
                objectKeys.append([]); index += 1; continue
            }
            if bytes[index] == 0x7d {
                guard !objectKeys.isEmpty else { throw fail() }
                objectKeys.removeLast(); index += 1; continue
            }
            guard bytes[index] == 0x22 else { index += 1; continue }
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != 0x22 {
                if bytes[index] == 0x5c {
                    index += 1
                    guard index < bytes.count else { throw fail() }
                    if bytes[index] == 0x75 {
                        let unit = try hex(index + 1)
                        index += 5
                        if (0xd800...0xdbff).contains(unit) {
                            guard index + 6 <= bytes.count, bytes[index] == 0x5c,
                                  bytes[index + 1] == 0x75,
                                  (0xdc00...0xdfff).contains(try hex(index + 2)) else { throw fail() }
                            index += 6
                        } else if (0xdc00...0xdfff).contains(unit) { throw fail() }
                        continue
                    }
                }
                index += 1
            }
            guard index < bytes.count else { throw fail() }
            index += 1
            var next = index
            while next < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[next]) { next += 1 }
            if next < bytes.count, bytes[next] == 0x3a {
                guard !objectKeys.isEmpty, index - start <= 128 else { throw fail() }
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                guard objectKeys[objectKeys.count - 1].insert(key).inserted else { throw fail() }
            }
        }
        guard objectKeys.isEmpty else { throw fail() }
    }
}
