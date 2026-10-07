/// Closed source profiles for the opt-in production-thumbnail diagnostic.
/// Raster dimensions are derived here, never supplied by wire callers.
public enum ImageDecodeDiagnosticProfile: String, Codable, CaseIterable, Sendable {
    case fourK = "4k", fiveK = "5k"

    public var sourceWidth: Int { self == .fourK ? 3_840 : 5_120 }
    public var sourceHeight: Int { self == .fourK ? 2_160 : 2_880 }
    public var previewWidth: Int { 1_024 }
    public var previewHeight: Int { 576 }
    public var rasterBytes: Int { previewWidth * previewHeight * 4 }
}
