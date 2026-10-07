import Foundation

/// One opt-in stderr observation, emitted only after the diagnostic run returns.
/// Its timestamps observe helper boundaries, not process exit or teardown internals.
public struct ImageDecodeTimingTrace: Codable, Equatable, Sendable {
    public static let schemaIdentifier = "image-decode-tail-v3"
    /// Includes the mandatory final LF; the entire stderr timing stream has this cap.
    public static let frameBytes = 1_024
    public let schema: String
    public let childPID: Int32
    public let terminalWriteStartedUptimeSeconds: Double?
    public let terminalWriteCompletedUptimeSeconds: Double?
    /// The timestamps describe the last attempt; the existing error fallback may be attempt 2.
    public let terminalWriteAttemptCount: Int
    public let runReturnedUptimeSeconds: Double
    public let framePreparedUptimeSeconds: Double
    public let terminalWriteSucceeded: Bool

    public init(childPID: Int32, terminalWriteStartedUptimeSeconds: Double?,
                terminalWriteCompletedUptimeSeconds: Double?, terminalWriteAttemptCount: Int, runReturnedUptimeSeconds: Double,
                framePreparedUptimeSeconds: Double, terminalWriteSucceeded: Bool) {
        schema = Self.schemaIdentifier; self.childPID = childPID
        self.terminalWriteStartedUptimeSeconds = terminalWriteStartedUptimeSeconds
        self.terminalWriteCompletedUptimeSeconds = terminalWriteCompletedUptimeSeconds
        self.terminalWriteAttemptCount = terminalWriteAttemptCount
        self.runReturnedUptimeSeconds = runReturnedUptimeSeconds
        self.framePreparedUptimeSeconds = framePreparedUptimeSeconds
        self.terminalWriteSucceeded = terminalWriteSucceeded
    }

    public func validate() throws {
        guard schema == Self.schemaIdentifier, childPID > 1,
              (0...2).contains(terminalWriteAttemptCount),
              (terminalWriteAttemptCount == 0) == (terminalWriteStartedUptimeSeconds == nil),
              terminalWriteSucceeded == (terminalWriteCompletedUptimeSeconds != nil),
              terminalWriteCompletedUptimeSeconds == nil || terminalWriteStartedUptimeSeconds != nil else {
            throw ImageDecodeDiagnosticError.invalidProtocol
        }
        let observations: [Double?] = [terminalWriteStartedUptimeSeconds, terminalWriteCompletedUptimeSeconds,
                                       runReturnedUptimeSeconds, framePreparedUptimeSeconds]
        var previous = 0.0
        for observation in observations.compactMap({ $0 }) {
            guard observation.isFinite, observation >= previous else { throw ImageDecodeDiagnosticError.invalidProtocol }
            previous = observation
        }
    }

    public func encodeFrame() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= Self.frameBytes else { throw ImageDecodeDiagnosticError.invalidProtocol }
        return bytes
    }

    public static func decodeFrame(_ bytes: Data) throws -> Self {
        var decoder = ImageDecodeTimingTraceDecoder()
        let frames = try decoder.consume(bytes); try decoder.finish()
        guard let frame = frames.first else { throw ImageDecodeDiagnosticError.invalidProtocol }
        return frame
    }

    fileprivate static func decodePayload(_ bytes: Data) throws -> Self {
        let required: Set<String> = ["schema", "childPID", "terminalWriteAttemptCount", "runReturnedUptimeSeconds", "framePreparedUptimeSeconds", "terminalWriteSucceeded"]
        let optional: Set<String> = ["terminalWriteStartedUptimeSeconds", "terminalWriteCompletedUptimeSeconds"]
        guard let object = try imageDecodeDiagnosticObject(bytes, maximumDepth: 1),
              required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else {
            throw ImageDecodeDiagnosticError.invalidProtocol
        }
        let trace = try JSONDecoder().decode(Self.self, from: bytes)
        try trace.validate(); return trace
    }
}

/// Rejects absent, partial, oversized, duplicate, or trailing stderr frames.
/// Call finish only after stderr EOF; a trace alone does not establish child exit.
public struct ImageDecodeTimingTraceDecoder {
    private var pending = Data(), total = 0, complete = false
    public init() { }

    public mutating func consume(_ data: Data) throws -> [ImageDecodeTimingTrace] {
        guard data.count <= ImageDecodeTimingTrace.frameBytes - total else { throw ImageDecodeDiagnosticError.invalidProtocol }
        total += data.count
        var frames: [ImageDecodeTimingTrace] = []
        for byte in data {
            guard !complete else { throw ImageDecodeDiagnosticError.invalidProtocol }
            if byte == 10 {
                guard !pending.isEmpty else { throw ImageDecodeDiagnosticError.invalidProtocol }
                frames.append(try ImageDecodeTimingTrace.decodePayload(pending))
                pending.removeAll(keepingCapacity: false); complete = true
            } else {
                // Reserve one byte for the required newline.
                guard pending.count < ImageDecodeTimingTrace.frameBytes - 1 else { throw ImageDecodeDiagnosticError.invalidProtocol }
                pending.append(byte)
            }
        }
        return frames
    }

    public func finish() throws {
        guard complete, pending.isEmpty else { throw ImageDecodeDiagnosticError.invalidProtocol }
    }
}
