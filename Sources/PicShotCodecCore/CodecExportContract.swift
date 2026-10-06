import Foundation

/// Admission/output budgets. The RSS limit is a sampled watchdog threshold,
/// not a kernel-enforced instantaneous ceiling on native codec allocations.
public enum CodecExportLimits {
    public static let version = 1
    public static let requestBytes = 4_096
    public static let responseBytes = 4_096
    public static let eventBytes = responseBytes
    public static let cancelBytes = 64
    public static let stdoutBytes = 262_144
    public static let stderrBytes = 8_192
    public static let progressEvents = 602
    public static let stillDimension = 8_192
    public static let stillPixels = 16_000_000
    public static let stillInputBytes = 80_000_000
    public static let stillOutputBytes = 134_217_728
    public static let animationInputBytes: Int64 = 1_073_741_824
    public static let animationDimension = 1_920
    public static let animationFrames = 600
    public static let animationDuration = 60.0
    public static let animationFrameBytes = 8_388_608
    public static let animationOutputBytes = 67_108_864
    public static let previewDimension = 1_024
    public static let previewBytes = 4_194_304
    public static let wallSeconds = 300.0
    public static let residentBytes: UInt64 = 1_073_741_824
    public static let sampleIntervalSeconds = 0.1
    public static let cancellationGraceSeconds = 2.0

    public static func validateStillDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= stillDimension, height <= stillDimension,
              width <= stillPixels / height else { throw CodecExportFailure(.tooLarge) }
    }
}

public enum CodecExportKind: String, Codable, Sendable { case still, animation }
public enum CodecExportFormat: String, Codable, Sendable { case webp, avif }
public enum CodecExportErrorCode: String, Codable, Sendable {
    case protocolViolation, unsupportedVersion, invalidOptions, invalidJobDirectory, invalidSource
    case invalidOutput, tooLarge, cancelled, deadline, memoryLimit, unavailable, failed
}

public struct CodecExportFailure: LocalizedError, Equatable, Sendable {
    public let code: CodecExportErrorCode
    public init(_ code: CodecExportErrorCode) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case .protocolViolation: return "The codec helper protocol is invalid."
        case .unsupportedVersion: return "The codec helper protocol version is unsupported."
        case .invalidOptions: return "The codec export options are invalid."
        case .invalidJobDirectory: return "The private codec export job could not be verified."
        case .invalidSource: return "The frozen image or local recording is invalid."
        case .invalidOutput: return "The encoded result could not be verified."
        case .tooLarge: return "The codec export exceeds its input, output, or frame budget."
        case .cancelled: return "Codec export was cancelled."
        case .deadline: return "Codec export exceeded its 300-second time limit."
        case .memoryLimit: return "The sampled codec process memory exceeded its 1 GiB abort threshold."
        case .unavailable: return "This codec export mode is unavailable in this build."
        case .failed: return "The native codec export failed."
        }
    }
}

public struct CodecAnimationOptions: Codable, Equatable, Sendable {
    public var frameRate: Int
    public var maximumDimension: Int
    public var maximumFrames: Int
    public var maximumDuration: Double
    public init(frameRate: Int = 15, maximumDimension: Int = 1_920, maximumFrames: Int = 600, maximumDuration: Double = 60) {
        self.frameRate = frameRate; self.maximumDimension = maximumDimension
        self.maximumFrames = maximumFrames; self.maximumDuration = maximumDuration
    }
    public func validate() throws {
        guard (1...30).contains(frameRate), (1...CodecExportLimits.animationDimension).contains(maximumDimension),
              (1...CodecExportLimits.animationFrames).contains(maximumFrames), maximumDuration.isFinite,
              maximumDuration > 0, maximumDuration <= CodecExportLimits.animationDuration
        else { throw CodecExportFailure(.invalidOptions) }
    }
}

/// There are no paths, URLs, command strings, or user-selected decoder names in
/// the wire format. The job contains a frozen PNG or a self-contained H.264 MP4.
public struct CodecExportRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: CodecExportKind
    public var format: CodecExportFormat
    public var quality: Int
    public var lossless: Bool
    public var preserveAlpha: Bool
    public var alphaQuality: Int
    public var animation: CodecAnimationOptions?
    public init(version: Int = 1, kind: CodecExportKind = .still, format: CodecExportFormat,
                quality: Int = 80, lossless: Bool = false, preserveAlpha: Bool = true, alphaQuality: Int = 100, animation: CodecAnimationOptions? = nil) {
        self.version = version; self.kind = kind; self.format = format; self.quality = quality
        self.lossless = lossless; self.preserveAlpha = preserveAlpha; self.alphaQuality = alphaQuality; self.animation = animation
    }
    public var inputName: String { kind == .still ? "input.png" : "input.mp4" }
    public var outputName: String { "output.\(format.rawValue)" }
    public var inputByteLimit: Int64 { kind == .still ? Int64(CodecExportLimits.stillInputBytes) : CodecExportLimits.animationInputBytes }
    public var outputByteLimit: Int { kind == .still ? CodecExportLimits.stillOutputBytes : CodecExportLimits.animationOutputBytes }
    public func validate() throws {
        guard version == CodecExportLimits.version else { throw CodecExportFailure(.unsupportedVersion) }
        guard (0...100).contains(quality), (0...100).contains(alphaQuality) else { throw CodecExportFailure(.invalidOptions) }
        switch kind {
        case .still: guard animation == nil else { throw CodecExportFailure(.invalidOptions) }
        case .animation:
            guard format == .webp, let animation else { throw CodecExportFailure(.invalidOptions) }
            try animation.validate()
        }
    }
}

public struct CodecExportResponse: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case progress, result, error }
    public var version: Int = 1
    public var kind: Kind
    public var fraction: Double?
    public var format: CodecExportFormat?
    public var outputBytes: Int?
    public var width: Int?
    public var height: Int?
    public var frameCount: Int?
    public var duration: Double?
    public var previewBytes: Int?
    public var sha256: String?
    public var errorCode: CodecExportErrorCode?
    public var sampledPeakResidentBytes: UInt64?
    public var sampledPeakPhysicalFootprintBytes: UInt64?
    public var residentSampleCount: Int?
    public var physicalFootprintSampleCount: Int?
    public init(kind: Kind, fraction: Double? = nil, format: CodecExportFormat? = nil, outputBytes: Int? = nil,
                width: Int? = nil, height: Int? = nil, frameCount: Int? = nil, duration: Double? = nil,
                previewBytes: Int? = nil, sha256: String? = nil, errorCode: CodecExportErrorCode? = nil) {
        self.kind = kind; self.fraction = fraction; self.format = format; self.outputBytes = outputBytes
        self.width = width; self.height = height; self.frameCount = frameCount; self.duration = duration
        self.previewBytes = previewBytes; self.sha256 = sha256; self.errorCode = errorCode
    }
    public func validate() throws {
        guard version == CodecExportLimits.version else { throw CodecExportFailure(.unsupportedVersion) }
        // A positive count is evidence only when its matching observed peak
        // is present. Unsupported measurements omit both fields together.
        for (peak, count) in [(sampledPeakResidentBytes, residentSampleCount),
                              (sampledPeakPhysicalFootprintBytes, physicalFootprintSampleCount)] {
            switch (peak, count) {
            case (nil, nil): break
            case let (peak?, count?) where peak > 0 && (1...10_000).contains(count): break
            default: throw CodecExportFailure(.protocolViolation)
            }
        }
        switch kind {
        case .progress:
            guard let fraction, fraction.isFinite, (0...1).contains(fraction), format == nil, outputBytes == nil,
                  width == nil, height == nil, frameCount == nil, duration == nil, previewBytes == nil, sha256 == nil, errorCode == nil,
                  sampledPeakResidentBytes == nil, sampledPeakPhysicalFootprintBytes == nil,
                  residentSampleCount == nil, physicalFootprintSampleCount == nil
            else { throw CodecExportFailure(.protocolViolation) }
        case .result:
            guard fraction == nil, format != nil, let outputBytes, (1...CodecExportLimits.stillOutputBytes).contains(outputBytes),
                  let width, let height, let frameCount, (1...CodecExportLimits.animationFrames).contains(frameCount),
                  let duration, duration.isFinite, (0...CodecExportLimits.animationDuration).contains(duration),
                  let previewBytes, (1...CodecExportLimits.previewBytes).contains(previewBytes),
                  let sha256, sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), errorCode == nil,
                  (duration == 0 && frameCount == 1) || (duration > 0 && format == .webp)
            else { throw CodecExportFailure(.protocolViolation) }
            try CodecExportLimits.validateStillDimensions(width: width, height: height)
            if duration > 0 {
                guard width <= CodecExportLimits.animationDimension, height <= CodecExportLimits.animationDimension,
                      outputBytes <= CodecExportLimits.animationOutputBytes else { throw CodecExportFailure(.protocolViolation) }
            }
        case .error:
            guard errorCode != nil, fraction == nil, format == nil, outputBytes == nil, width == nil,
                  height == nil, frameCount == nil, duration == nil, previewBytes == nil, sha256 == nil
            else { throw CodecExportFailure(.protocolViolation) }
        }
    }
    public func validate(for request: CodecExportRequest) throws {
        try validate()
        guard kind == .result else { return }
        guard format == request.format, let outputBytes, outputBytes <= request.outputByteLimit else { throw CodecExportFailure(.protocolViolation) }
        if request.kind == .still {
            guard frameCount == 1, duration == 0 else { throw CodecExportFailure(.protocolViolation) }
        } else {
            guard let options = request.animation, let width, let height, let frameCount, let duration,
                  width <= options.maximumDimension, height <= options.maximumDimension,
                  frameCount <= options.maximumFrames, duration > 0, duration <= options.maximumDuration + 0.001
            else { throw CodecExportFailure(.protocolViolation) }
        }
    }
}
