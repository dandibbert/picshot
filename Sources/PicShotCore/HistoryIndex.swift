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
    public init(id: UUID = UUID(), createdAt: Date = Date(), title: String, filename: String, width: Int, height: Int, byteCount: Int64, text: String = "", starred: Bool = false) {
        self.id=id; self.createdAt=createdAt; self.title=title; self.filename=filename; self.width=width; self.height=height; self.byteCount=byteCount; self.text=text; self.starred=starred
    }
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
        var bytes = kept.reduce(Int64(0)) { $0 + $1.byteCount }
        for r in records.filter({ !$0.starred && $0.createdAt >= cutoff }).sorted(by: { $0.createdAt > $1.createdAt }) {
            guard kept.count < maxItems, bytes + r.byteCount <= maxBytes else { continue }
            kept.append(r); bytes += r.byteCount
        }
        return kept.sorted { $0.createdAt > $1.createdAt }
    }
}
