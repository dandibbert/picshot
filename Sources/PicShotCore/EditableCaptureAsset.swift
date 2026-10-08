import Foundation

/// Value-only references. Editable documents and pixels are never embedded in catalog indexes.
public struct EditableRasterAsset: Codable, Equatable, Sendable {
    public let assetID: UUID
    public let filename: String
    public let width: Int
    public let height: Int
    public let byteCount: Int64
    /// nil is reserved for legacy raster references; new editable bundles require a digest.
    public let sha256: String?
    public init(assetID: UUID, filename: String, width: Int, height: Int, byteCount: Int64, sha256: String? = nil) {
        self.assetID = assetID; self.filename = filename; self.width = width; self.height = height; self.byteCount = byteCount; self.sha256 = sha256
    }
    public var isValid: Bool {
        PinRasterAsset.isSafeFilename(filename) && width > 0 && height > 0 &&
            height <= 100_000_000 && width <= 100_000_000 / height && byteCount > 0 && byteCount <= 1_073_741_824 &&
            (sha256.map(EditableCaptureAsset.isValidDigest) ?? true)
    }
    /// Conservative 16-bit RGBA estimate, with row padding; independent of PNG size.
    public var decodedRasterByteEstimate: Int {
        guard isValid else { return Int.max }
        return ((width * 8 + 63) / 64 * 64) * height
    }
    public var pinAsset: PinRasterAsset { PinRasterAsset(filename: filename, width: width, height: height, byteCount: byteCount, sha256: sha256) }
}

public struct EditableCaptureAsset: Codable, Equatable, Sendable {
    public static let maximumDocumentBytes: Int64 = 8 * 1_024 * 1_024
    public let documentFilename: String
    public let documentByteCount: Int64
    public let documentSHA256: String?
    public let current: EditableRasterAsset?
    public let original: EditableRasterAsset
    public let base: EditableRasterAsset
    public init(documentFilename: String, documentByteCount: Int64, original: EditableRasterAsset, base: EditableRasterAsset,
                documentSHA256: String? = nil, current: EditableRasterAsset? = nil) {
        self.documentFilename = documentFilename; self.documentByteCount = documentByteCount
        self.original = original; self.base = base; self.documentSHA256 = documentSHA256; self.current = current
    }
    public static func isSafeDocumentFilename(_ filename: String) -> Bool {
        let suffix = ".annotations"
        guard filename.hasSuffix(suffix), filename.count == 36 + suffix.count else { return false }
        let stem = String(filename.dropLast(suffix.count))
        return UUID(uuidString: stem)?.uuidString.lowercased() == stem.lowercased()
    }
    public static func isValidDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public var isValid: Bool {
        guard let current, current.isValid, current.sha256 != nil,
              let documentSHA256, Self.isValidDigest(documentSHA256), original.sha256 != nil, base.sha256 != nil,
              Self.isSafeDocumentFilename(documentFilename), documentByteCount > 0,
              documentByteCount <= Self.maximumDocumentBytes, original.isValid, base.isValid else { return false }
        if original.assetID == base.assetID && original != base { return false }
        if original.assetID != base.assetID && original.filename == base.filename { return false }
        for raster in rasters where raster.filename == current.filename || raster.assetID == current.assetID {
            guard raster == current else { return false }
        }
        return true
    }
    public var rasters: [EditableRasterAsset] { original.filename == base.filename ? [original] : [original, base] }
    public var decodedRasterByteEstimate: Int {
        EditorAdmissionPolicy.sum(rasters.map(\.decodedRasterByteEstimate))
    }
    public var assetFilenames: [String] { Array(Set(rasters.map(\.filename) + (current.map { [$0.filename] } ?? []) + [documentFilename])) }
    public func additionalByteCount(excluding filenames: Set<String>) -> Int64 {
        rasters.filter { !filenames.contains($0.filename) }.reduce(documentByteCount) { $0 + $1.byteCount }
    }
}
