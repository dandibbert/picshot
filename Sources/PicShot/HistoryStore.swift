import AppKit
import Combine
import PicShotCore

@MainActor final class HistoryStore: ObservableObject {
    @Published private(set) var records: [CaptureRecord] = []
    @Published var query = ""
    let directory: URL
    /// A damaged/unsafe catalog is read-only until recovered; a new save cannot overwrite it.
    private(set) var loadError: Error?
    var failureInjector: ((CaptureAssetWritePoint) throws -> Void)?
    static let maximumCurrentImageBytes: Int64 = 134_217_728
    private let currentImageByteLimit: Int64
    private let policyOverride: RetentionPolicy?
    var policy: RetentionPolicy {
        policyOverride ?? RetentionPolicy(maxItems: UserDefaults.standard.integer(forKey: "historyCount").nonzero ?? 200,
            maxBytes: Int64(UserDefaults.standard.integer(forKey: "historyMB").nonzero ?? 1024) * 1_048_576,
            maxDays: UserDefaults.standard.integer(forKey: "historyDays").nonzero ?? 30)
    }
    private let thumbnails = NSCache<NSUUID, NSImage>()
    private var assets: EditableCaptureAssetStore { EditableCaptureAssetStore(directory: directory) }
    private static let maximumIndexBytes = 16_777_216
    var filtered: [CaptureRecord] { records.filter { $0.matches(query) } }
    init(directory: URL? = nil, policy: RetentionPolicy? = nil, currentImageByteLimit: Int64 = 134_217_728) {
        let requested = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicShot/History", isDirectory: true)
        self.directory = URL(fileURLWithPath: requested.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
        self.policyOverride = policy
        self.currentImageByteLimit = max(1, min(Self.maximumCurrentImageBytes, currentImageByteLimit))
        thumbnails.totalCostLimit = 24 * 1024 * 1024; thumbnails.countLimit = 80
        do {
            guard requested.isFileURL, (try? FileManager.default.destinationOfSymbolicLink(atPath: requested.path)) == nil else { throw PinSessionError.unsafePath }
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let values = try self.directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw PinSessionError.unsafePath }
            let indexURL = self.directory.appendingPathComponent("index.json")
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: indexURL.path)) == nil else { throw PinSessionError.unsafePath }
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let size = try assets.checkedFile(indexURL).fileSize ?? Int.max
                guard size <= Self.maximumIndexBytes else { throw PinSessionError.invalidManifest }
                let handle = try FileHandle(forReadingFrom: indexURL)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.maximumIndexBytes + 1) ?? Data()
                guard data.count <= Self.maximumIndexBytes else { throw PinSessionError.invalidManifest }
                let loaded = try JSONDecoder().decode([CaptureRecord].self, from: data)
                try validate(loaded)
                // Validate boundaries only. Editable metadata and raster pixels load on demand.
                for record in loaded {
                    if let editable = record.editableCapture { try assets.validateFileBoundaries(editable) }
                    let target = url(for: record)
                    if FileManager.default.fileExists(atPath: target.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
                        _ = try assets.inspect(currentAsset(record), verifyContent: false)
                    }
                }
                records = loaded.filter { $0.editableCapture != nil || FileManager.default.fileExists(atPath: url(for: $0).path) }
            }
            try assets.recoverTransactions(referenced: Set(records.flatMap(\.assetFilenames)))
            try prune()
            assets.cleanupTemporaryFiles()
        } catch { loadError = error; NSLog("History: %@", error.localizedDescription) }
    }
    func url(for record: CaptureRecord) -> URL { directory.appendingPathComponent(record.filename) }
    func image(for record: CaptureRecord) -> CGImage? {
        guard record.hasSafeStorageMetadata, (try? assets.inspect(currentAsset(record))) != nil else { return nil }
        return CGImage.read(url: url(for: record))
    }
    func thumbnail(for record: CaptureRecord) -> NSImage? {
        if let value = thumbnails.object(forKey: record.id as NSUUID) { return value }
        guard record.hasSafeStorageMetadata, (try? assets.inspect(currentAsset(record))) != nil,
              let image = CGImage.read(url: url(for: record), maxDimension: 160) else { return nil }
        let value = image.nsImage; thumbnails.setObject(value, forKey: record.id as NSUUID, cost: image.bytesPerRow * image.height); return value
    }
    /// nil is reserved for legacy flattened captures. Corrupt/missing editable assets throw.
    func editablePayload(for record: CaptureRecord, reusingOriginal: CGImage? = nil,
                         maximumRasterBytes: Int = EditorAdmissionPolicy().maximumRasterBytes) throws -> EditableCapturePayload? {
        guard let stored = records.first(where: { $0.id == record.id }) else { throw PinSessionError.missingPin }
        guard let editable = stored.editableCapture else { return nil }
        let payload = try assets.read(editable, reusingOriginal: reusingOriginal, maximumRasterBytes: maximumRasterBytes)
        let size = try payload.document.expectedOutputPixelSize()
        guard size.width == CGFloat(stored.width), size.height == CGFloat(stored.height) else { throw PinSessionError.invalidManifest }
        _ = try assets.inspect(currentAsset(stored), verifyContent: false)
        return payload
    }
    @discardableResult func add(_ image: CGImage, title: String = "截图", capturedAt: Date? = nil,
                                editable: EditableCapturePayload? = nil) throws -> CaptureRecord {
        try requireWritable()
        guard capturedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { throw PicShotError.message("截图时间无效") }
        try editable?.validate(currentImage: image)
        var staged: [String] = [], committed = false
        defer { if !committed { staged.forEach { assets.remove($0) } }; assets.finish(staged, committed: committed) }
        let current = try assets.raster(image, maximumBytes: currentImageByteLimit, staged: &staged, failure: failureInjector)
        let document = try editable.map { payload in
            let reusable = image === payload.originalImage ? EditableRasterAsset(assetID: payload.document.originalAssetID,
                filename: current.filename, width: current.width, height: current.height, byteCount: current.byteCount, sha256: current.sha256) : nil
            return try assets.stage(payload, current: current, reusingOriginal: reusable, staged: &staged, failure: failureInjector)
        }
        let now = Date()
        let record = CaptureRecord(createdAt: now, title: "\(title) · \(now.formatted(date: .omitted, time: .shortened))",
            filename: current.filename, width: image.width, height: image.height, byteCount: current.byteCount,
            capturedAt: capturedAt, editableCapture: document)
        let kept = policy.retained([record] + records)
        guard kept.contains(where: { $0.id == record.id }) else { throw capacityError }
        try commit(kept); committed = true
        return record
    }
    /// Retains the capture identity, original, capture time, text and star. No mutation is
    /// observable until all source/base/document/current files and the index are committed.
    func replaceImage(_ image: CGImage, id: UUID, editable: EditableCapturePayload) throws {
        try requireWritable()
        guard let position = records.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
        var staged: [String] = [], committed = false
        defer { if !committed { staged.forEach { assets.remove($0) } }; assets.finish(staged, committed: committed) }
        try editable.validate(currentImage: image)
        let previous = records[position]
        let original = previous.editableCapture?.original ?? EditableRasterAsset(assetID: editable.document.originalAssetID,
            filename: previous.filename, width: previous.width, height: previous.height, byteCount: previous.byteCount)
        let current = try assets.raster(image, maximumBytes: currentImageByteLimit, staged: &staged, failure: failureInjector)
        let document = try assets.stage(editable, current: current, reusingOriginal: original, staged: &staged, failure: failureInjector)
        var next = records
        next[position].filename = current.filename; next[position].width = current.width; next[position].height = current.height
        next[position].byteCount = current.byteCount; next[position].editableCapture = document
        let kept = policy.retained(next)
        guard kept.contains(where: { $0.id == id }), protectedAndRequiredFit(kept, requiring: id) else { throw capacityError }
        try commit(kept); committed = true
        thumbnails.removeObject(forKey: id as NSUUID)
    }
    func updateText(_ text: String, id: UUID) throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        var next = records; next[i].text = text; try commit(next)
    }
    func toggleStar(_ record: CaptureRecord) throws {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        var next = records; next[i].starred.toggle(); try commit(next)
    }
    func remove(_ record: CaptureRecord) throws {
        guard records.contains(where: { $0.id == record.id }) else { return }
        try commit(records.filter { $0.id != record.id }, trashRemoved: true)
    }
    func prune() throws { try commit(policy.retained(records)) }
    private var capacityError: Error { PicShotError.message("历史空间不足。请调整保留上限或取消一些收藏，然后重试") }
    private func protectedAndRequiredFit(_ proposed: [CaptureRecord], requiring id: UUID) -> Bool {
        let required = proposed.filter { $0.starred || $0.id == id }
        guard required.count <= policy.maxItems else { return false }
        var remaining = policy.maxBytes
        for record in required { guard record.storedByteCount <= remaining else { return false }; remaining -= record.storedByteCount }
        return true
    }
    private func requireWritable() throws { if let loadError { throw loadError } }
    private func currentAsset(_ record: CaptureRecord) -> EditableRasterAsset {
        record.editableCapture?.current ?? EditableRasterAsset(assetID: record.id, filename: record.filename,
            width: record.width, height: record.height, byteCount: record.byteCount)
    }
    private func validate(_ records: [CaptureRecord]) throws {
        guard records.count <= 10_000, Set(records.map(\.id)).count == records.count,
              records.allSatisfy(\.hasSafeStorageMetadata) else { throw PinSessionError.invalidManifest }
        var filenames = Set<String>()
        for record in records {
            for filename in record.assetFilenames {
                guard filenames.insert(filename.lowercased()).inserted else { throw PinSessionError.invalidManifest }
            }
        }
    }
    private func commit(_ proposed: [CaptureRecord], trashRemoved: Bool = false) throws {
        try requireWritable(); try assets.requireDirectory(); try validate(proposed)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(proposed)
        guard data.count <= Self.maximumIndexBytes else { throw PinSessionError.invalidManifest }
        let target = directory.appendingPathComponent("index.json")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else { throw PinSessionError.unsafePath }
        if FileManager.default.fileExists(atPath: target.path) { _ = try assets.checkedFile(target) }
        let keep = Set(proposed.flatMap(\.assetFilenames))
        let retired = records.flatMap(\.assetFilenames).filter { !keep.contains($0) }
        let retirement = try (trashRemoved ? nil : assets.beginRetirement(retired))
        var committed = false
        defer { assets.finishRetirement(retirement, committed: committed) }
        try failureInjector?(.beforeIndexCommit)
        try data.write(to: target, options: .atomic)
        let previous = records; records = proposed; committed = true
        for filename in previous.flatMap(\.assetFilenames) where !keep.contains(filename) {
            if trashRemoved, let assetURL = try? assets.url(filename), (try? assets.checkedFile(assetURL)) != nil {
                var result: NSURL?
                try? FileManager.default.trashItem(at: assetURL, resultingItemURL: &result)
            } else { assets.remove(filename) }
        }
        let keptIDs = Set(proposed.map(\.id))
        for record in previous where !keptIDs.contains(record.id) { thumbnails.removeObject(forKey: record.id as NSUUID) }
    }
}
private extension Int { var nonzero: Int? { self > 0 ? self : nil } }
