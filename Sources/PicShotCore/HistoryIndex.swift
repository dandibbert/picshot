import Foundation

public struct CaptureRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var title: String
    public var filename: String
    public var width: Int
    public var height: Int
    public var byteCount: Int64
    public var text: String
    public var starred: Bool
    /// Present only when the source capture time is known. Imports and older
    /// history records must not mistake their library insertion time for it.
    public var capturedAt: Date?
    public var editableCapture: EditableCaptureAsset?
    public init(id: UUID = UUID(), createdAt: Date = Date(), title: String, filename: String, width: Int, height: Int, byteCount: Int64, text: String = "", starred: Bool = false, capturedAt: Date? = nil, editableCapture: EditableCaptureAsset? = nil) {
        self.id=id; self.createdAt=createdAt; self.title=title; self.filename=filename; self.width=width; self.height=height; self.byteCount=byteCount; self.text=text; self.starred=starred; self.capturedAt=capturedAt; self.editableCapture=editableCapture
    }
    public var hasSafeStorageMetadata: Bool {
        guard filename.hasSuffix(".png"), filename.count == 40, UUID(uuidString: String(filename.dropLast(4))) != nil,
              width > 0, height > 0, width <= 100_000_000 / height, byteCount >= 0, byteCount <= 1_073_741_824,
              text.utf8.count <= 1_048_576, title.utf8.count <= 4_096,
              capturedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { return false }
        if let editableCapture {
            guard editableCapture.isValid, let current = editableCapture.current,
                  current.filename == filename, current.width == width, current.height == height, current.byteCount == byteCount else { return false }
            for raster in editableCapture.rasters where raster.filename == filename {
                guard raster.width == width, raster.height == height, raster.byteCount == byteCount else { return false }
            }
        }
        return true
    }
    public var storedByteCount: Int64 { byteCount + (editableCapture?.additionalByteCount(excluding: [filename]) ?? 0) }
    public var assetFilenames: [String] { Array(Set([filename] + (editableCapture?.assetFilenames ?? []))) }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query) || text.localizedCaseInsensitiveContains(query)
    }
}

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var maxItems: Int
    public var maxBytes: Int64
    public var maxDays: Int
    public init(maxItems: Int = 200, maxBytes: Int64 = 1_073_741_824, maxDays: Int = 30) {
        self.maxItems = max(1, maxItems); self.maxBytes = max(1, maxBytes); self.maxDays = max(1, maxDays)
    }
    /// Starred captures count toward quota and are never silently deleted.
    /// If protected files exceed the limit, new captures must be rejected.
    public func retained(_ records: [CaptureRecord], now: Date = Date()) -> [CaptureRecord] {
        let cutoff = now.addingTimeInterval(-Double(maxDays) * 86400)
        var kept = records.filter(\.starred).sorted { $0.createdAt > $1.createdAt }
        var bytes = kept.reduce(Int64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.storedByteCount)
            return overflow ? Int64.max : sum
        }
        for r in records.filter({ !$0.starred && $0.createdAt >= cutoff }).sorted(by: { $0.createdAt > $1.createdAt }) {
            guard kept.count < maxItems, r.storedByteCount <= maxBytes - bytes else { continue }
            kept.append(r); bytes += r.storedByteCount
        }
        return kept.sorted { $0.createdAt > $1.createdAt }
    }
}
