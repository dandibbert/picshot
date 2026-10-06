import Foundation

public enum CodecExportProtocol {
    public static let cancelLine = Data("{\"cancel\":true}\n".utf8)
    private static let requestKeys: Set<String> = ["version", "kind", "format", "quality", "lossless", "preserveAlpha", "alphaQuality"]
    private static let animationKeys: Set<String> = ["frameRate", "maximumDimension", "maximumFrames", "maximumDuration"]
    private static let responseKeys: Set<String> = ["version", "kind", "fraction", "format", "outputBytes", "width", "height", "frameCount", "duration", "previewBytes", "sha256", "errorCode", "sampledPeakResidentBytes", "sampledPeakPhysicalFootprintBytes", "residentSampleCount", "physicalFootprintSampleCount"]

    public static func decodeRequestLine(_ data: Data) throws -> CodecExportRequest {
        let (json, object) = try objectLine(data, limit: CodecExportLimits.requestBytes)
        guard Set(object.keys) == requestKeys || Set(object.keys) == requestKeys.union(["animation"])
        else { throw CodecExportFailure(.protocolViolation) }
        if let animation = object["animation"] {
            guard let fields = animation as? [String: Any], Set(fields.keys) == animationKeys
            else { throw CodecExportFailure(.protocolViolation) }
        }
        let request: CodecExportRequest = try decode(json)
        try request.validate()
        return request
    }
    public static func decodeResponseLine(_ data: Data) throws -> CodecExportResponse {
        let (json, object) = try objectLine(data, limit: CodecExportLimits.responseBytes)
        guard Set(object.keys).isSubset(of: responseKeys), object["version"] != nil, object["kind"] != nil
        else { throw CodecExportFailure(.protocolViolation) }
        let response: CodecExportResponse = try decode(json)
        try response.validate()
        return response
    }
    public static func decodeCancelLine(_ data: Data) throws {
        let (json, object) = try objectLine(data, limit: CodecExportLimits.cancelBytes)
        guard Set(object.keys) == ["cancel"] else { throw CodecExportFailure(.protocolViolation) }
        struct Command: Decodable { let cancel: Bool }
        let command: Command = try decode(json)
        guard command.cancel else { throw CodecExportFailure(.protocolViolation) }
    }
    public static func encodeRequestLine(_ request: CodecExportRequest) throws -> Data {
        try request.validate(); return try encodeLine(request, limit: CodecExportLimits.requestBytes)
    }
    public static func encodeResponseLine(_ response: CodecExportResponse) throws -> Data {
        try response.validate(); return try encodeLine(response, limit: CodecExportLimits.responseBytes)
    }
    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CodecExportFailure(.protocolViolation) }
    }
    private static func encodeLine<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        guard data.count < limit else { throw CodecExportFailure(.tooLarge) }
        data.append(10); return data
    }
    private static func objectLine(_ data: Data, limit: Int) throws -> (Data, [String: Any]) {
        guard !data.isEmpty, data.count <= limit else { throw CodecExportFailure(.protocolViolation) }
        let json = data.last == 10 ? Data(data.dropLast()) : data
        guard !json.isEmpty, !json.contains(10), !json.contains(13),
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        else { throw CodecExportFailure(.protocolViolation) }
        try rejectDuplicateKeysAndDeepObjects(json)
        guard !object.values.contains(where: { $0 is NSNull }) else { throw CodecExportFailure(.protocolViolation) }
        return (json, object)
    }
    /// JSONSerialization accepts duplicate keys. Detect escaped duplicates too,
    /// reject arrays and cap depth before any typed object is trusted.
    private static func rejectDuplicateKeysAndDeepObjects(_ data: Data) throws {
        let bytes = [UInt8](data)
        var objects: [Set<String>] = [], index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123:
                objects.append([])
                guard objects.count <= 2 else { throw CodecExportFailure(.protocolViolation) }
            case 125:
                guard !objects.isEmpty else { throw CodecExportFailure(.protocolViolation) }
                objects.removeLast()
            case 91, 93: throw CodecExportFailure(.protocolViolation)
            case 34:
                let start = index; index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }; index += 1
                }
                guard index < bytes.count else { throw CodecExportFailure(.protocolViolation) }
                var next = index + 1
                while next < bytes.count, bytes[next] == 32 || bytes[next] == 9 { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard !objects.isEmpty else { throw CodecExportFailure(.protocolViolation) }
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard objects[objects.count - 1].insert(key).inserted else { throw CodecExportFailure(.protocolViolation) }
                }
            default: break
            }
            index += 1
        }
    }
}

/// One request and at most one cancellation per process. Never accumulates an
/// unbounded pipe buffer, including when a malicious writer omits newlines.
public struct CodecExportInputDecoder {
    public enum Message { case request(CodecExportRequest), cancel }
    private var line = Data(), phase = 0, total = 0
    public init() {}
    public var receivedRequest: Bool { phase > 0 }
    public mutating func consume(_ data: Data) throws -> [Message] {
        guard data.count <= CodecExportLimits.requestBytes + CodecExportLimits.cancelBytes - total
        else { throw CodecExportFailure(.tooLarge) }
        total += data.count
        var messages: [Message] = []
        for byte in data {
            guard phase < 2 else { throw CodecExportFailure(.protocolViolation) }
            let limit = phase == 0 ? CodecExportLimits.requestBytes : CodecExportLimits.cancelBytes
            guard line.count < limit else { throw CodecExportFailure(.tooLarge) }
            line.append(byte)
            if byte == 10 {
                if phase == 0 { messages.append(.request(try CodecExportProtocol.decodeRequestLine(line))) }
                else { try CodecExportProtocol.decodeCancelLine(line); messages.append(.cancel) }
                line.removeAll(keepingCapacity: false); phase += 1
            }
        }
        return messages
    }
    public mutating func finish() throws {
        guard phase > 0, line.isEmpty else { throw CodecExportFailure(.protocolViolation) }
    }
}
