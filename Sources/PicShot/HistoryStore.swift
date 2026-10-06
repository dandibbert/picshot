import AppKit
import Combine
import PicShotCore

@MainActor final class HistoryStore: ObservableObject {
    @Published private(set) var records: [CaptureRecord] = []
    @Published var query = ""
    let directory: URL
    var policy: RetentionPolicy {
        get { RetentionPolicy(maxItems: UserDefaults.standard.integer(forKey: "historyCount").nonzero ?? 200, maxBytes: Int64(UserDefaults.standard.integer(forKey: "historyMB").nonzero ?? 1024) * 1_048_576, maxDays: UserDefaults.standard.integer(forKey: "historyDays").nonzero ?? 30) }
    }
    private let thumbnails = NSCache<NSUUID, NSImage>()
    var filtered: [CaptureRecord] { records.filter { $0.matches(query) } }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PicShot/History", isDirectory: true)
        thumbnails.totalCostLimit = 24 * 1024 * 1024; thumbnails.countLimit = 80
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let indexURL=self.directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath:indexURL.path) {
                let bytes=try indexURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard bytes <= 16_777_216 else {throw PicShotError.message("历史索引超过安全大小，原文件已保留")}
                let loaded=try JSONDecoder().decode([CaptureRecord].self,from:Data(contentsOf:indexURL))
                // Never let an edited/corrupt index direct reads or retention cleanup outside this store.
                records=Array(loaded.filter(\.hasSafeStorageMetadata).prefix(10_000))
            }
            records.removeAll { !FileManager.default.fileExists(atPath: self.directory.appendingPathComponent($0.filename).path) }
            try prune()
        } catch { NSLog("History: %@", error.localizedDescription) }
    }
    func url(for record: CaptureRecord) -> URL { directory.appendingPathComponent(record.filename) }
    func image(for record: CaptureRecord) -> CGImage? { CGImage.read(url: url(for: record)) }
    func thumbnail(for record: CaptureRecord) -> NSImage? {
        if let value = thumbnails.object(forKey: record.id as NSUUID) { return value }
        guard let image = CGImage.read(url: url(for: record), maxDimension: 160) else { return nil }
        let value = image.nsImage; thumbnails.setObject(value, forKey: record.id as NSUUID, cost: image.bytesPerRow * image.height); return value
    }
    @discardableResult func add(_ image: CGImage, title: String = "截图") throws -> CaptureRecord {
        guard image.width * image.height <= 100_000_000 else { throw PicShotError.message("图片超过 1 亿像素，请先缩小或分段保存") }
        let id = UUID(), filename = UUID().uuidString + ".png", now = Date()
        let target = directory.appendingPathComponent(filename)
        try image.writePNG(to: target)
        let size = (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        let record = CaptureRecord(id: id, createdAt: now, title: "\(title) · \(now.formatted(date: .omitted, time: .shortened))", filename: filename, width: image.width, height: image.height, byteCount: Int64(size))
        let proposed = [record] + records
        let kept = policy.retained(proposed)
        guard kept.contains(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: target); throw PicShotError.message("历史空间不足。请调整保留上限或取消一些收藏，然后重试") }
        let previous = records; records = proposed
        do { try prune() } catch { records = previous; try? FileManager.default.removeItem(at: target); throw error }
        return record
    }
    func updateText(_ text: String, id: UUID) throws {
        guard let i = records.firstIndex(where: {$0.id == id}) else { return }; records[i].text = text; try persist()
    }
    func toggleStar(_ record: CaptureRecord) throws {
        guard let i = records.firstIndex(where: {$0.id == record.id}) else { return }; records[i].starred.toggle(); try persist()
    }
    func remove(_ record: CaptureRecord) throws {
        var result: NSURL?
        if FileManager.default.fileExists(atPath: url(for: record).path) { try FileManager.default.trashItem(at: url(for: record), resultingItemURL: &result) }
        records.removeAll {$0.id == record.id}; thumbnails.removeObject(forKey: record.id as NSUUID); try persist()
    }
    func prune() throws {
        let kept = policy.retained(records), ids = Set(kept.map(\.id))
        // Persist the surviving index first. Retention is explicit in Settings.
        let old = records; records = kept
        do { try persist() } catch { records = old; throw error }
        for r in old where !ids.contains(r.id) { try? FileManager.default.removeItem(at: url(for: r)); thumbnails.removeObject(forKey: r.id as NSUUID) }
    }
    private func persist() throws { try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
}
private extension Int { var nonzero: Int? { self > 0 ? self : nil } }
