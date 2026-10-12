import Foundation

/// The native decision gate uses these same immutable limits on both sides of the pipe.
public enum TextScriptLimits {
    public static let schemaVersion = 1
    public static let sourceBytes = 16 * 1_024
    public static let inputUTF16Units = 32_768
    public static let outputUTF16Units = 32_768
    public static let outputUTF8Bytes = 128 * 1_024
    public static let requestBytes = 512 * 1_024
    public static let responseBytes = 256 * 1_024
    public static let stderrBytes = 4 * 1_024
    public static let cpuSoftSeconds = 2
    public static let cpuHardSeconds = 3
    public static let helperAlarmSeconds: UInt32 = 5
    public static let acceptanceSeconds: TimeInterval = 3
    public static let terminationGraceSeconds: TimeInterval = 0.25
    public static let killedExitObservationSeconds: TimeInterval = 0.75
    public static let residentBytes: UInt64 = 256 * 1_024 * 1_024
    public static let signingIdentifier = "com.picshot.TextScriptHelper"
}

/// No case carries script text, exception descriptions, source excerpts, paths or OCR.
public enum TextScriptDiagnostic: String, Codable, Error, CaseIterable, Sendable {
    case invalidRequest
    case unsupportedSchema
    case sourceTooLarge
    case emptyInput
    case inputTooLarge
    case syntaxError
    case scriptException
    case outputNotString
    case emptyOutput
    case outputTooLarge
    case invalidUnicode
    case runtimeUnavailable
    case resourceLimitSetup
    case protocolViolation
    case transportFailure
}

public enum TextScriptOperation: String, Codable, Sendable {
    case transform
    case capabilityProbe
}

public enum TextScriptStatus: String, Codable, Sendable {
    case success
    case failure
}

public struct TextScriptProbeRequest: Codable, Equatable, Sendable {
    public let loopbackPort: UInt16
    public init(loopbackPort: UInt16) { self.loopbackPort = loopbackPort }

    /// The fixture creates only these project-owned sentinels. Arbitrary paths are not accepted.
    public static func sentinelDirectory(for requestID: UUID) -> String {
        "/private/tmp/picshot-text-script-gate-" + requestID.uuidString.lowercased()
    }
    public static let readSentinelName = "read-sentinel.txt"
    public static let writeSentinelName = "write-sentinel.txt"
}

public struct TextScriptProbeResult: Codable, Equatable, Sendable {
    public let readDenied: Bool
    public let writeDenied: Bool
    public let networkDenied: Bool
    public let readErrno: Int32
    public let writeErrno: Int32
    public let networkErrno: Int32

    public init(readDenied: Bool, writeDenied: Bool, networkDenied: Bool,
                readErrno: Int32, writeErrno: Int32, networkErrno: Int32) {
        self.readDenied = readDenied; self.writeDenied = writeDenied; self.networkDenied = networkDenied
        self.readErrno = readErrno; self.writeErrno = writeErrno; self.networkErrno = networkErrno
    }

    public var allDenied: Bool { readDenied && writeDenied && networkDenied }
}

public struct TextScriptRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let operation: TextScriptOperation
    public let source: String?
    public let text: String?
    public let probe: TextScriptProbeRequest?

    public init(schemaVersion: Int = TextScriptLimits.schemaVersion, requestID: UUID,
                operation: TextScriptOperation, source: String? = nil, text: String? = nil,
                probe: TextScriptProbeRequest? = nil) {
        self.schemaVersion = schemaVersion; self.requestID = requestID; self.operation = operation
        self.source = source; self.text = text; self.probe = probe
    }

    public static func transform(requestID: UUID = UUID(), source: String, text: String) -> Self {
        Self(requestID: requestID, operation: .transform, source: source, text: text)
    }

    public static func capabilityProbe(requestID: UUID = UUID(), loopbackPort: UInt16) -> Self {
        Self(requestID: requestID, operation: .capabilityProbe, probe: .init(loopbackPort: loopbackPort))
    }

    public func validate() throws {
        guard schemaVersion == TextScriptLimits.schemaVersion else { throw TextScriptDiagnostic.unsupportedSchema }
        switch operation {
        case .transform:
            guard let source, let text, probe == nil else { throw TextScriptDiagnostic.invalidRequest }
            guard source.utf8.count <= TextScriptLimits.sourceBytes else { throw TextScriptDiagnostic.sourceTooLarge }
            guard !text.isEmpty else { throw TextScriptDiagnostic.emptyInput }
            guard text.utf16.count <= TextScriptLimits.inputUTF16Units else { throw TextScriptDiagnostic.inputTooLarge }
        case .capabilityProbe:
            guard source == nil, text == nil, let probe, probe.loopbackPort > 0 else {
                throw TextScriptDiagnostic.invalidRequest
            }
        }
    }
}

public struct TextScriptResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let status: TextScriptStatus
    public let output: String?
    public let diagnostic: TextScriptDiagnostic?
    public let probe: TextScriptProbeResult?

    public init(schemaVersion: Int = TextScriptLimits.schemaVersion, requestID: UUID,
                status: TextScriptStatus, output: String? = nil, diagnostic: TextScriptDiagnostic? = nil,
                probe: TextScriptProbeResult? = nil) {
        self.schemaVersion = schemaVersion; self.requestID = requestID; self.status = status
        self.output = output; self.diagnostic = diagnostic; self.probe = probe
    }

    public static func success(requestID: UUID, output: String) -> Self {
        Self(requestID: requestID, status: .success, output: output)
    }

    public static func success(requestID: UUID, probe: TextScriptProbeResult) -> Self {
        Self(requestID: requestID, status: .success, probe: probe)
    }

    public static func failure(requestID: UUID, diagnostic: TextScriptDiagnostic) -> Self {
        Self(requestID: requestID, status: .failure, diagnostic: diagnostic)
    }

    public func validate(for request: TextScriptRequest) throws {
        guard schemaVersion == TextScriptLimits.schemaVersion, requestID == request.requestID else {
            throw TextScriptDiagnostic.protocolViolation
        }
        switch status {
        case .failure:
            guard output == nil, probe == nil, diagnostic != nil else { throw TextScriptDiagnostic.protocolViolation }
        case .success:
            guard diagnostic == nil else { throw TextScriptDiagnostic.protocolViolation }
            switch request.operation {
            case .transform:
                guard let output, probe == nil, !output.isEmpty,
                      output.utf16.count <= TextScriptLimits.outputUTF16Units,
                      output.utf8.count <= TextScriptLimits.outputUTF8Bytes else {
                    throw TextScriptDiagnostic.protocolViolation
                }
            case .capabilityProbe:
                guard output == nil, let probe else { throw TextScriptDiagnostic.protocolViolation }
                // Darwin EPERM=1 and EACCES=13. A closed port/missing file never proves denial.
                let denied: (Int32) -> Bool = { $0 == 1 || $0 == 13 }
                guard probe.readDenied == denied(probe.readErrno),
                      probe.writeDenied == denied(probe.writeErrno),
                      probe.networkDenied == denied(probe.networkErrno),
                      probe.readErrno >= 0, probe.writeErrno >= 0, probe.networkErrno >= 0 else {
                    throw TextScriptDiagnostic.protocolViolation
                }
            }
        }
    }
}
