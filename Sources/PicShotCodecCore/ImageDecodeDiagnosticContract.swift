import Foundation
import CryptoKit

/// Separate opt-in diagnostic protocol; never accepted by the codec export decoder.
public enum ImageDecodeDiagnosticLimits {
    public static let schema = "image-decode-helper-v1"
    public static let argument = "--image-draw-decode-diagnostic-v1"
    public static let largeSchema = "image-decode-helper-v2"
    public static let largeArgument = "--image-draw-decode-diagnostic-v2"
    public static let largeTimingArgument = "--image-draw-decode-diagnostic-v3"
    public static let width = 768, height = 576, rasterBytes = 1_769_472
    public static let pngBytes = 8 * 1_024 * 1_024
    public static let requestBytes = 4_096, eventBytes = 16_384, stdoutBytes = 131_072, stderrBytes = 8_192
    public static let reportBytes = 2 * 1_024 * 1_024, maximumEvents = 12
    public static let childWorkSeconds = 5.0, childHardSeconds = 6.0, exitSeconds = 9.0
    public static let armSeconds = 180.0, outerSeconds = 200.0
    public static let residentWatchdogBytes: UInt64 = 268_435_456
    public static let cancelLine = Data("cancel\n".utf8)
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func validDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}
public enum ImageDecodeDiagnosticError: String, Error, LocalizedError, Codable, Sendable {
    case invalidInput, invalidJob, invalidProtocol, cancelled, deadline, memoryLimit, failed, outputMismatch, exitUnconfirmed
    public var errorDescription: String? { "Image decode diagnostic: " + rawValue }
}
public struct ImageDecodeDiagnosticRequest: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case decode, holdAfterDecode }
    public let schema: String, token: String, pngSHA256: String
    public let parentPID: Int32, pngBytes: Int
    public let mode: Mode
    public let profile: ImageDecodeDiagnosticProfile?
    public var sourceWidth: Int { profile?.sourceWidth ?? ImageDecodeDiagnosticLimits.width }
    public var sourceHeight: Int { profile?.sourceHeight ?? ImageDecodeDiagnosticLimits.height }
    public var previewWidth: Int { profile?.previewWidth ?? ImageDecodeDiagnosticLimits.width }
    public var previewHeight: Int { profile?.previewHeight ?? ImageDecodeDiagnosticLimits.height }
    public var rasterBytes: Int { profile?.rasterBytes ?? ImageDecodeDiagnosticLimits.rasterBytes }
    public init(token: String, parentPID: Int32, pngBytes: Int, pngSHA256: String, mode: Mode,
                profile: ImageDecodeDiagnosticProfile? = nil) {
        schema = profile == nil ? ImageDecodeDiagnosticLimits.schema : ImageDecodeDiagnosticLimits.largeSchema
        self.token = token; self.parentPID = parentPID
        self.pngBytes = pngBytes; self.pngSHA256 = pngSHA256; self.mode = mode; self.profile = profile
    }
    public func validate() throws {
        guard schema == (profile == nil ? ImageDecodeDiagnosticLimits.schema : ImageDecodeDiagnosticLimits.largeSchema),
              UUID(uuidString: token) != nil, parentPID > 1,
              (1...ImageDecodeDiagnosticLimits.pngBytes).contains(pngBytes), ImageDecodeDiagnosticLimits.validDigest(pngSHA256) else { throw ImageDecodeDiagnosticError.invalidProtocol }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= ImageDecodeDiagnosticLimits.requestBytes,
              let object = try imageDecodeDiagnosticObject(data, maximumDepth: 1),
              let schema = object["schema"] as? String else { throw ImageDecodeDiagnosticError.invalidProtocol }
        var keys: Set<String> = ["schema", "token", "pngSHA256", "parentPID", "pngBytes", "mode"]
        if schema == ImageDecodeDiagnosticLimits.largeSchema { keys.insert("profile") }
        guard Set(object.keys) == keys else { throw ImageDecodeDiagnosticError.invalidProtocol }
        let result = try JSONDecoder().decode(Self.self, from: data); try result.validate(); return result
    }
}
public struct ImageDecodeDiagnosticEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case phase, ready, result, error }
    public let schema: String
    public let profile: ImageDecodeDiagnosticProfile?
    public var kind: Kind, phase: String
    public var childPID: Int32
    public var uptimeSeconds: Double
    public var memory: ImageDecodeMemoryReading?
    public var peaks: ImageDecodeMemoryPeaks?
    public var error: ImageDecodeDiagnosticError?
    public var rawSHA256: String?
    public var rawBytes: Int?
    public var imageCreationSeconds: Double?
    public var drawSeconds: Double?
    public var writeSeconds: Double?
    public var childWorkSeconds: Double?
    /// Monotonic helper entry/response timestamps, not OS process-start times.
    public var helperEntryUptimeSeconds: Double?
    public var responsePreparedUptimeSeconds: Double?
    public var pngReadAndHashSeconds: Double?
    public init(kind: Kind, phase: String, childPID: Int32, memory: ImageDecodeMemoryReading? = nil,
                profile: ImageDecodeDiagnosticProfile? = nil) {
        schema = profile == nil ? ImageDecodeDiagnosticLimits.schema : ImageDecodeDiagnosticLimits.largeSchema
        self.profile = profile; self.kind = kind; self.phase = phase; self.childPID = childPID
        uptimeSeconds = ProcessInfo.processInfo.systemUptime; self.memory = memory
    }
    public func validate() throws {
        let phases: Set<String> = ["beforePNGRead", "imageCreated", "rasterDrawn", "afterContextRelease", "heldAfterDecode", "outputClosed", "afterDecodePool", "complete", "failed"]
        guard schema == (profile == nil ? ImageDecodeDiagnosticLimits.schema : ImageDecodeDiagnosticLimits.largeSchema),
              childPID > 1, phases.contains(phase), uptimeSeconds.isFinite, uptimeSeconds >= 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
        for value in [imageCreationSeconds, drawSeconds, writeSeconds, childWorkSeconds].compactMap({ $0 }) {
            guard value.isFinite, value >= 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
        }
        for value in [helperEntryUptimeSeconds, responsePreparedUptimeSeconds].compactMap({ $0 }) {
            guard value.isFinite, value >= 0, value <= uptimeSeconds else { throw ImageDecodeDiagnosticError.invalidProtocol }
        }
        if let entry = helperEntryUptimeSeconds, let response = responsePreparedUptimeSeconds, response < entry { throw ImageDecodeDiagnosticError.invalidProtocol }
        if let pngReadAndHashSeconds {
            guard pngReadAndHashSeconds.isFinite, (0...ImageDecodeDiagnosticLimits.childHardSeconds).contains(pngReadAndHashSeconds) else { throw ImageDecodeDiagnosticError.invalidProtocol }
        }
        if let rawBytes, rawBytes != (profile?.rasterBytes ?? ImageDecodeDiagnosticLimits.rasterBytes) { throw ImageDecodeDiagnosticError.invalidProtocol }
        if let rawSHA256, !ImageDecodeDiagnosticLimits.validDigest(rawSHA256) { throw ImageDecodeDiagnosticError.invalidProtocol }
        if kind == .result {
            guard phase == "complete", rawBytes == (profile?.rasterBytes ?? ImageDecodeDiagnosticLimits.rasterBytes), rawSHA256 != nil,
                  imageCreationSeconds != nil, drawSeconds != nil, writeSeconds != nil, childWorkSeconds != nil,
                  error == nil, let peaks, peaks.residentSamples > 0, peaks.footprintSamples > 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
        }
        if kind == .error, error == nil { throw ImageDecodeDiagnosticError.invalidProtocol }
        if kind == .ready, phase != "heldAfterDecode" { throw ImageDecodeDiagnosticError.invalidProtocol }
        if let memory, !memory.usable { throw ImageDecodeDiagnosticError.invalidProtocol }
    }
}
public struct ImageDecodeDiagnosticEventDecoder {
    private var pending = Data(), total = 0, count = 0, terminal = false
    public init() { }
    public mutating func consume(_ data: Data) throws -> [ImageDecodeDiagnosticEvent] {
        guard total <= ImageDecodeDiagnosticLimits.stdoutBytes - data.count else { throw ImageDecodeDiagnosticError.invalidProtocol }
        total += data.count
        var result: [ImageDecodeDiagnosticEvent] = []
        for byte in data {
            guard !terminal else { throw ImageDecodeDiagnosticError.invalidProtocol }
            if byte == 10 {
                guard !pending.isEmpty, pending.count + 1 <= ImageDecodeDiagnosticLimits.eventBytes, count < ImageDecodeDiagnosticLimits.maximumEvents else { throw ImageDecodeDiagnosticError.invalidProtocol }
                let keys: Set<String> = ["schema", "profile", "kind", "phase", "childPID", "uptimeSeconds", "memory", "peaks", "error", "rawSHA256", "rawBytes", "imageCreationSeconds", "drawSeconds", "writeSeconds", "childWorkSeconds", "helperEntryUptimeSeconds", "responsePreparedUptimeSeconds", "pngReadAndHashSeconds"]
                guard let object = try imageDecodeDiagnosticObject(pending, maximumDepth: 4), Set(object.keys).isSubset(of: keys) else { throw ImageDecodeDiagnosticError.invalidProtocol }
                let event = try JSONDecoder().decode(ImageDecodeDiagnosticEvent.self, from: pending); try event.validate()
                pending.removeAll(keepingCapacity: true); count += 1; result.append(event)
                terminal = event.kind == .result || event.kind == .error
            } else {
                guard pending.count < ImageDecodeDiagnosticLimits.eventBytes else { throw ImageDecodeDiagnosticError.invalidProtocol }; pending.append(byte)
            }
        }
        return result
    }
    public func finish() throws { guard pending.isEmpty, terminal else { throw ImageDecodeDiagnosticError.invalidProtocol } }
}

// Inspect bounded wire bytes before Foundation materializes a nested object.
func imageDecodeDiagnosticObject(_ data: Data, maximumDepth: Int) throws -> [String: Any]? {
    let bytes = [UInt8](data)
    var objects: [Set<String>] = [], index = 0
    while index < bytes.count {
        switch bytes[index] {
        case 123: objects.append([]); guard objects.count <= maximumDepth else { throw ImageDecodeDiagnosticError.invalidProtocol }
        case 125: guard !objects.isEmpty else { throw ImageDecodeDiagnosticError.invalidProtocol }; objects.removeLast()
        case 91, 93, 10, 13: throw ImageDecodeDiagnosticError.invalidProtocol
        case 34:
            let start = index; index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { break }; index += 1
            }
            guard index < bytes.count else { throw ImageDecodeDiagnosticError.invalidProtocol }
            var next = index + 1
            while next < bytes.count, bytes[next] == 32 || bytes[next] == 9 { next += 1 }
            if next < bytes.count, bytes[next] == 58 {
                guard !objects.isEmpty else { throw ImageDecodeDiagnosticError.invalidProtocol }
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                guard objects[objects.count - 1].insert(key).inserted else { throw ImageDecodeDiagnosticError.invalidProtocol }
            }
        default: break
        }
        index += 1
    }
    guard objects.isEmpty, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImageDecodeDiagnosticError.invalidProtocol }
    func containsNull(_ object: [String: Any]) -> Bool { object.values.contains { $0 is NSNull || ($0 as? [String: Any]).map(containsNull) == true } }
    guard !containsNull(object) else { throw ImageDecodeDiagnosticError.invalidProtocol }; return object
}
