import Foundation

/// The subprocess boundary is deliberately smaller than the general app API.
/// All byte limits include the newline framing byte when it is present.
enum GIFHelperLimits {
    static let requestBytes = 8_192
    static let eventBytes = 4_096
    static let stdoutBytes = 1_048_576
    static let stderrBytes = 8_192
    static let sourceBytes: Int64 = 1_073_741_824
    static let outputBytes = 67_108_864
    static let wallSeconds: TimeInterval = 300
    static let residentBytes: UInt64 = 1_073_741_824
    static let sampleIntervalSeconds: TimeInterval = 0.1
    static let progressEvents = 602
    static let cancelBytes = 64
}

struct GIFHelperRequest: Codable, Sendable {
    var version: Int = 1
    var options: GIFExportOptions
    var frameExtraction: GIFFrameExtraction

    init(version: Int = 1, options: GIFExportOptions = .init(), frameExtraction: GIFFrameExtraction = .asynchronous) {
        self.version = version
        self.options = options
        self.frameExtraction = frameExtraction
    }

    func validate() throws {
        guard version == 1 else { throw GIFHelperProtocolError.unsupportedVersion }
        try options.validate()
    }
}

struct GIFHelperEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case progress, memory, result, error }
    var version: Int = 1
    var kind: Kind
    var fraction: Double? = nil
    var outputBytes: Int? = nil
    var frameCount: Int? = nil
    var duration: Double? = nil
    var errorCode: String? = nil
    var errorMessage: String? = nil
    var residentBytes: UInt64? = nil
    var physicalFootprintBytes: UInt64? = nil
    var sampledPeakResidentBytes: UInt64? = nil
    var sampledPeakPhysicalFootprintBytes: UInt64? = nil
    var residentSampleCount: Int? = nil
    var physicalFootprintSampleCount: Int? = nil

    func validate() throws {
        guard version == 1 else { throw GIFHelperProtocolError.unsupportedVersion }
        if let fraction, !fraction.isFinite || !(0...1).contains(fraction) { throw GIFHelperProtocolError.invalidMessage }
        if let outputBytes, !(1...GIFHelperLimits.outputBytes).contains(outputBytes) { throw GIFHelperProtocolError.invalidMessage }
        if let frameCount, !(1...600).contains(frameCount) { throw GIFHelperProtocolError.invalidMessage }
        if let duration, !duration.isFinite || duration <= 0 || duration > 60.01 { throw GIFHelperProtocolError.invalidMessage }
        if let errorCode, errorCode.isEmpty || errorCode.utf8.count > 64 || !errorCode.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) {
            throw GIFHelperProtocolError.invalidMessage
        }
        if let errorMessage, errorMessage.utf8.count > 768 || errorMessage.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw GIFHelperProtocolError.invalidMessage
        }
        for count in [residentSampleCount, physicalFootprintSampleCount].compactMap({ $0 }) {
            guard (0...10_000).contains(count) else { throw GIFHelperProtocolError.invalidMessage }
        }
        switch kind {
        case .progress:
            guard fraction != nil, outputBytes == nil, frameCount == nil, duration == nil, errorCode == nil, errorMessage == nil,
                  residentBytes == nil, physicalFootprintBytes == nil, sampledPeakResidentBytes == nil,
                  sampledPeakPhysicalFootprintBytes == nil, residentSampleCount == nil, physicalFootprintSampleCount == nil
            else { throw GIFHelperProtocolError.invalidMessage }
        case .memory:
            guard fraction == nil, outputBytes == nil, frameCount == nil, duration == nil, errorCode == nil, errorMessage == nil,
                  sampledPeakResidentBytes == nil, sampledPeakPhysicalFootprintBytes == nil,
                  residentSampleCount == nil, physicalFootprintSampleCount == nil else { throw GIFHelperProtocolError.invalidMessage }
        case .result:
            guard outputBytes != nil, frameCount != nil, duration != nil, fraction == nil,
                  errorCode == nil, errorMessage == nil else { throw GIFHelperProtocolError.invalidMessage }
        case .error:
            guard errorCode != nil, outputBytes == nil, frameCount == nil, duration == nil, fraction == nil
            else { throw GIFHelperProtocolError.invalidMessage }
        }
    }
}

enum GIFHelperProtocolError: Error, Equatable {
    case invalidMessage, unsupportedVersion, messageTooLarge, incompleteMessage
    case invalidJobDirectory, invalidSource, unexpectedOutput
}

enum GIFHelperProtocol {
    private static let requestKeys: Set<String> = ["version", "options", "frameExtraction"]
    private static let optionKeys: Set<String> = ["frameRate", "maximumDimension", "maximumDuration", "maximumFrames"]
    private static let eventKeys: Set<String> = ["version", "kind", "fraction", "outputBytes", "frameCount", "duration", "errorCode", "errorMessage",
        "residentBytes", "physicalFootprintBytes", "sampledPeakResidentBytes", "sampledPeakPhysicalFootprintBytes", "residentSampleCount", "physicalFootprintSampleCount"]

    static func decodeRequestLine(_ data: Data) throws -> GIFHelperRequest {
        let (json, object) = try objectLine(data, limit: GIFHelperLimits.requestBytes)
        guard Set(object.keys) == requestKeys, let options = object["options"] as? [String: Any], Set(options.keys) == optionKeys
        else { throw GIFHelperProtocolError.invalidMessage }
        let request = try JSONDecoder().decode(GIFHelperRequest.self, from: json)
        try request.validate()
        return request
    }

    static func decodeEventLine(_ data: Data) throws -> GIFHelperEvent {
        let (json, object) = try objectLine(data, limit: GIFHelperLimits.eventBytes)
        guard Set(object.keys).isSubset(of: eventKeys), object["version"] != nil, object["kind"] != nil,
              !object.values.contains(where: { $0 is NSNull }) else { throw GIFHelperProtocolError.invalidMessage }
        let event = try JSONDecoder().decode(GIFHelperEvent.self, from: json)
        try event.validate()
        return event
    }

    static func decodeCancelLine(_ data: Data) throws {
        let (json, object) = try objectLine(data, limit: GIFHelperLimits.cancelBytes)
        guard Set(object.keys) == ["cancel"] else { throw GIFHelperProtocolError.invalidMessage }
        struct Command: Decodable { let cancel: Bool }
        guard try JSONDecoder().decode(Command.self, from: json).cancel else { throw GIFHelperProtocolError.invalidMessage }
    }

    static func encodeRequestLine(_ request: GIFHelperRequest) throws -> Data {
        try request.validate()
        return try encodeLine(request, limit: GIFHelperLimits.requestBytes)
    }

    static func encodeEventLine(_ event: GIFHelperEvent) throws -> Data {
        try event.validate()
        return try encodeLine(event, limit: GIFHelperLimits.eventBytes)
    }

    private static func encodeLine<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        guard data.count < limit else { throw GIFHelperProtocolError.messageTooLarge }
        data.append(10)
        return data
    }

    private static func objectLine(_ data: Data, limit: Int) throws -> (Data, [String: Any]) {
        guard !data.isEmpty else { throw GIFHelperProtocolError.invalidMessage }
        guard data.count <= limit else { throw GIFHelperProtocolError.messageTooLarge }
        let json = data.last == 10 ? Data(data.dropLast()) : data
        guard !json.isEmpty, !json.contains(10), !json.contains(13),
              let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { throw GIFHelperProtocolError.invalidMessage }
        try rejectDuplicateKeysAndDeepObjects(json)
        return (json, object)
    }

    /// Foundation accepts duplicate object keys. Reject them, including escaped
    /// spellings of the same key, before using Foundation's decoded values.
    /// JSON syntax has already been checked above; this only checks its shape.
    private static func rejectDuplicateKeysAndDeepObjects(_ data: Data) throws {
        let bytes = [UInt8](data)
        var objects: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123:
                objects.append([])
                guard objects.count <= 2 else { throw GIFHelperProtocolError.invalidMessage }
            case 125:
                guard !objects.isEmpty else { throw GIFHelperProtocolError.invalidMessage }
                objects.removeLast()
            case 91, 93:
                throw GIFHelperProtocolError.invalidMessage
            case 34:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }
                    index += 1
                }
                guard index < bytes.count else { throw GIFHelperProtocolError.invalidMessage }
                var next = index + 1
                while next < bytes.count, bytes[next] == 32 || bytes[next] == 9 { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard !objects.isEmpty else { throw GIFHelperProtocolError.invalidMessage }
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard objects[objects.count - 1].insert(key).inserted else { throw GIFHelperProtocolError.invalidMessage }
                }
            default: break
            }
            index += 1
        }
    }
}

/// Incremental framing never retains more than one bounded line. Only one
/// request followed by at most one cancel command is accepted per process.
struct GIFHelperInputDecoder {
    enum Message { case request(GIFHelperRequest), cancel }
    private var line = Data()
    private var phase = 0
    private var total = 0
    var receivedRequest: Bool { phase > 0 }

    mutating func consume(_ data: Data) throws -> [Message] {
        let totalLimit = GIFHelperLimits.requestBytes + GIFHelperLimits.cancelBytes
        guard data.count <= totalLimit - total else { throw GIFHelperProtocolError.messageTooLarge }
        total += data.count
        var messages: [Message] = []
        for byte in data {
            guard phase < 2 else { throw GIFHelperProtocolError.invalidMessage }
            let limit = phase == 0 ? GIFHelperLimits.requestBytes : GIFHelperLimits.cancelBytes
            guard line.count < limit else { throw GIFHelperProtocolError.messageTooLarge }
            line.append(byte)
            if byte == 10 {
                if phase == 0 { messages.append(.request(try GIFHelperProtocol.decodeRequestLine(line))) }
                else { try GIFHelperProtocol.decodeCancelLine(line); messages.append(.cancel) }
                line.removeAll(keepingCapacity: false)
                phase += 1
            }
        }
        return messages
    }

    mutating func finish() throws {
        guard phase > 0, line.isEmpty else { throw GIFHelperProtocolError.incompleteMessage }
    }
}
