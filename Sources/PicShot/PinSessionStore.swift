import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// A disk-backed pin catalog. It never owns full-resolution images or pin controllers.
/// All changes commit metadata atomically before removing old assets. Failed writes leave
/// the previous session intact, and unfinished writes are cleaned on the next healthy load.
@MainActor final class PinSessionStore: ObservableObject {
    static let restorePreferenceKey = "restorePinSessionOnLaunch"
    @Published private(set) var index: PinSessionIndex
    let directory: URL
    let policy: PinSessionPolicy
    private var thumbnails: [UUID: (image: NSImage, cost: Int)] = [:]
    private var thumbnailRecency: [UUID] = []
    private(set) var thumbnailCacheCost = 0
    var cachedThumbnailCount: Int { thumbnails.count }
    private static let thumbnailByteLimit = 12 * 1_024 * 1_024
    private static let thumbnailCountLimit = 24
    private let fileManager = FileManager.default
    private static let maximumManifestBytes = 2 * 1_024 * 1_024

    /// Launch restoration is opt-in. Saving the bounded session itself requests no capture permission.
    static var restoreOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: restorePreferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: restorePreferenceKey) }
    }
    var groups: [PinGroup] { index.groups }
    var entries: [PinSessionEntry] { index.entries }
    var visibleEntries: [PinSessionEntry] { index.visibleEntries }

    init(directory: URL? = nil, policy: PinSessionPolicy = PinSessionPolicy()) throws {
        let requested = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicShot/PinSession", isDirectory: true)
        guard requested.isFileURL, (try? FileManager.default.destinationOfSymbolicLink(atPath: requested.path)) == nil else { throw PinSessionError.unsafePath }
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let directoryInfo = try requested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryInfo.isDirectory == true, directoryInfo.isSymbolicLink != true else { throw PinSessionError.unsafePath }
        self.directory = URL(fileURLWithPath: requested.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
        self.policy = policy; index = PinSessionIndex()

        let manifest = self.directory.appendingPathComponent("index.json")
        guard (try? fileManager.destinationOfSymbolicLink(atPath: manifest.path)) == nil else { throw PinSessionError.unsafePath }
        if fileManager.fileExists(atPath: manifest.path) {
            let info = try checkedRegularFile(manifest)
            guard (info.fileSize ?? Int.max) <= Self.maximumManifestBytes else { throw PinSessionError.invalidManifest }
            do { index = try JSONDecoder().decode(PinSessionIndex.self, from: Data(contentsOf: manifest)).validated() }
            catch let error as PinSessionError { throw error }
            catch { throw PinSessionError.invalidManifest }
        }
        // Header checks do not decode image pixels. Missing/corrupted assets are omitted,
        // while unsafe paths and symlinks reject the session without overwriting anything.
        var loaded = index
        var usable: [PinSessionEntry] = []
        for entry in loaded.entries {
            var assets: [String: PinRasterAsset] = [:]
            var complete = true
            for asset in entry.assets {
                guard let verified = try inspectedAsset(asset) else { complete = false; break }
                assets[asset.filename] = verified
            }
            if complete, let rich = entry.richContent { complete = try inspectedRichAsset(rich) }
            if complete, let original = assets[entry.original.filename], let current = assets[entry.current.filename] {
                var verified = entry; verified.original = original; verified.current = current
                usable.append(verified)
            }
        }
        loaded.entries = usable
        loaded.entries = try policy.retaining(loaded)
        try commit(loaded)
        cleanupStaleFiles()
    }

    @discardableResult func add(rich prepared: PreparedRichPin, presentation: PinPresentation = PinPresentation(),
                                protecting protectedIDs: Set<UUID> = [], revealingGroup: Bool = false) throws -> PinSessionEntry {
        guard PinSessionIndex.validName(prepared.title, limit: 120) else { throw PinSessionError.invalidName }
        let rich = prepared.asset
        guard rich.isValid else { throw RichPinError.invalidContent }
        let poster = try writeAsset(prepared.poster)
        var committed = false
        defer { if !committed { removeAssetIfSafe(poster.filename); removeAssetIfSafe(rich.filename) } }
        let temporary = directory.appendingPathComponent(".pin-write-" + rich.filename)
        defer { try? fileManager.removeItem(at: temporary) }
        try prepared.data.write(to: temporary, options: .atomic)
        _ = try checkedRegularFile(temporary)
        try fileManager.moveItem(at: temporary, to: assetURL(rich.filename))
        guard try inspectedRichAsset(rich) else { throw RichPinError.invalidContent }
        let entry = PinSessionEntry(groupID: index.activeGroupID, title: prepared.title, original: poster,
                                    presentation: presentation.normalized(), richContent: rich)
        var next = index; next.version = PinSessionIndex.schemaVersion; next.entries.insert(entry, at: 0)
        if revealingGroup {
            next.allHidden = false
            if let position = next.groups.firstIndex(where: { $0.id == next.activeGroupID }) { next.groups[position].isHidden = false }
        }
        next.entries = try policy.retaining(next, requiring: [entry.id], protecting: protectedIDs)
        try commit(next); committed = true
        return entry
    }

    /// A formula edit atomically replaces the source/options and its corresponding raster.
    /// The old pair survives render, quota, validation and manifest-write failures.
    func replaceRich(_ prepared: PreparedRichPin, id: UUID, protecting protectedIDs: Set<UUID> = []) throws {
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
        guard prepared.kind == .latex, index.entries[position].richContent?.kind == .latex else { throw RichPinError.invalidContent }
        let rich = prepared.asset
        guard rich.isValid else { throw RichPinError.invalidContent }
        let raster = try writeAsset(prepared.poster)
        var committed = false
        defer { if !committed { removeAssetIfSafe(raster.filename); removeAssetIfSafe(rich.filename) } }
        let temporary = directory.appendingPathComponent(".pin-write-" + rich.filename)
        defer { try? fileManager.removeItem(at: temporary) }
        try prepared.data.write(to: temporary, options: .atomic)
        _ = try checkedRegularFile(temporary)
        try fileManager.moveItem(at: temporary, to: assetURL(rich.filename))
        guard try inspectedRichAsset(rich) else { throw RichPinError.invalidContent }
        var next = index
        next.entries[position].richContent = rich
        next.entries[position].original = raster; next.entries[position].current = raster
        next.entries[position].updatedAt = Date()
        next.entries = try policy.retaining(next, requiring: [id], protecting: protectedIDs)
        try commit(next); committed = true; removeThumbnail(id: id)
    }

    /// A bounded payload read never follows the referenced file paths inside a document.
    func richData(id: UUID) throws -> Data {
        guard let rich = entry(id: id)?.richContent else { throw PinSessionError.missingPin }
        let data = try readRichAsset(rich)
        guard try validRichData(data, asset: rich) else { throw RichPinError.invalidContent }
        return data
    }
    private func readRichAsset(_ asset: PinRichAsset) throws -> Data {
        guard asset.isValid else { throw PinSessionError.invalidManifest }
        let url = try assetURL(asset.filename)
        let values = try checkedRegularFile(url)
        guard values.fileSize == Int(asset.byteCount) else { throw RichPinError.invalidContent }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(asset.byteCount) + 1) ?? Data()
        guard data.count == Int(asset.byteCount) else { throw RichPinError.invalidContent }
        return data
    }
    private func validRichData(_ data: Data, asset: PinRichAsset) throws -> Bool {
        if asset.kind == .animation {
            let info = try RichPinAnimationInfo.inspect(data)
            return info.width == asset.width && info.height == asset.height && info.frameCount == asset.frameCount && asset.filename.hasSuffix("." + info.fileExtension)
        }
        let document = try JSONDecoder().decode(PinRichDocument.self, from: data)
        return document.kind == asset.kind && document.isValid
    }
    private func inspectedRichAsset(_ asset: PinRichAsset) throws -> Bool {
        do { return try validRichData(readRichAsset(asset), asset: asset) }
        catch let error as PinSessionError where error == .unsafePath { throw error }
        catch { return false }
    }

    func entry(id: UUID) -> PinSessionEntry? { index.entry(id: id) }

    @discardableResult func add(image: CGImage, title: String = "贴图", groupID: UUID? = nil,
                               presentation: PinPresentation = PinPresentation(),
                               protecting protectedIDs: Set<UUID> = [],
                               revealingGroup: Bool = false) throws -> PinSessionEntry {
        try add(originalImage: image, currentImage: image, title: title, groupID: groupID,
                presentation: presentation, protecting: protectedIDs, revealingGroup: revealingGroup)
    }

    /// Stage source and decorated pixels before publishing one complete entry. The original
    /// is never rendered from the current image. Reusing the same image object stores one PNG.
    @discardableResult func add(originalImage: CGImage, currentImage: CGImage,
                               title: String = "贴图", groupID: UUID? = nil,
                               presentation: PinPresentation = PinPresentation(),
                               protecting protectedIDs: Set<UUID> = [],
                               revealingGroup: Bool = false) throws -> PinSessionEntry {
        let groupID = groupID ?? index.activeGroupID
        guard index.groups.contains(where: { $0.id == groupID }) else { throw PinSessionError.missingGroup }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PinSessionIndex.validName(title, limit: 120) else { throw PinSessionError.invalidName }
        var staged: [String] = []
        var committed = false
        defer { if !committed { staged.forEach { removeAssetIfSafe($0) } } }
        let original = try writeAsset(originalImage)
        staged.append(original.filename)
        let current: PinRasterAsset
        if originalImage === currentImage { current = original }
        else {
            current = try writeAsset(currentImage)
            staged.append(current.filename)
        }
        let entry = PinSessionEntry(groupID: groupID, title: title, original: original, current: current,
                                    presentation: presentation.normalized())
        var next = index; next.entries.insert(entry, at: 0)
        // A user-created pin can reveal its group in the same atomic transaction.
        // A failed manifest write must not save/evict a pin or change visibility alone.
        if revealingGroup {
            next.activeGroupID = groupID; next.allHidden = false
            if let position = next.groups.firstIndex(where: { $0.id == groupID }) { next.groups[position].isHidden = false }
        }
        next.entries = try policy.retaining(next, requiring: [entry.id], protecting: protectedIDs)
        try commit(next); committed = true
        return entry
    }

    /// Save only after a pixel edit, not on move/resize/opacity events. Preserves the original PNG.
    func replaceImage(_ image: CGImage, id: UUID, protecting protectedIDs: Set<UUID> = []) throws {
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
        guard index.entries[position].richContent == nil else { throw RichPinError.invalidContent }
        let asset = try writeAsset(image)
        var committed = false
        defer { if !committed { removeAssetIfSafe(asset.filename) } }
        var next = index; next.entries[position].current = asset; next.entries[position].updatedAt = Date()
        next.entries = try policy.retaining(next, requiring: [id], protecting: protectedIDs)
        try commit(next); committed = true
        removeThumbnail(id: id)
    }

    func resetImage(id: UUID) throws {
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
        guard index.entries[position].richContent == nil else { throw RichPinError.invalidContent }
        var next = index; next.entries[position].current = next.entries[position].original
        next.entries[position].updatedAt = Date(); try commit(next)
        removeThumbnail(id: id)
    }

    func updatePresentation(_ presentation: PinPresentation, id: UUID) throws {
        try updatePresentations([id: presentation])
    }

    /// A debounce flush is a single metadata write, not a partially committed loop.
    func updatePresentations(_ presentations: [UUID: PinPresentation]) throws {
        guard presentations.count <= PinGroupTransformPlan.maximumSelection else { throw PinSessionError.capacityExceeded }
        var next = index
        for (id, presentation) in presentations {
            guard let position = index.entries.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
            next.entries[position].presentation = presentation.normalized()
        }
        guard next != index else { return }
        try commit(next)
    }

    /// Validates every stable ID and expected presentation before the one atomic manifest
    /// replacement. No raster IO, cache insertion, quota eviction, or asset deletion.
    func applyGroupPresentations(_ plan: PinGroupTransformPlan, forward: Bool = true) throws {
        let next = try plan.applying(to: index, forward: forward)
        guard next != index else { return }
        try commit(next)
    }

    func renamePin(id: UUID, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PinSessionIndex.validName(title, limit: 120) else { throw PinSessionError.invalidName }
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
        var next = index; next.entries[position].title = title; try commit(next)
    }

    /// Ordinary window close archives a pin and its final presentation atomically.
    /// Original/current PNGs remain available in pin history and still count toward quota.
    func archive(id: UUID, presentation: PinPresentation? = nil) throws {
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
        var next = index; next.entries[position].isVisible = false
        if index.entries[position].isVisible { next.entries[position].archiveSequence = index.nextArchiveSequence }
        if let presentation { next.entries[position].presentation = presentation.normalized() }
        guard next != index else { return }
        next.entries[position].updatedAt = Date()
        try commit(next)
    }

    /// Reopens history and reveals/activates its group in one metadata transaction.
    /// No pixels are loaded here; the coordinator creates at most one live controller.
    func reopen(id: UUID) throws {
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingPin }
        var next = index
        let groupID = next.entries[position].groupID
        guard let groupPosition = next.groups.firstIndex(where: { $0.id == groupID }) else { throw PinSessionError.missingGroup }
        next.entries[position].isVisible = true; next.entries[position].archiveSequence = nil
        next.activeGroupID = groupID; next.allHidden = false; next.groups[groupPosition].isHidden = false
        guard next != index else { return }
        next.entries[position].updatedAt = Date()
        try commit(next)
    }

    /// Explicit manager removal only. Close archives; hide, switch and termination keep
    /// the pin's prior visibility. Only this operation intentionally deletes its assets.
    func remove(id: UUID) throws {
        guard index.entries.contains(where: { $0.id == id }) else { return }
        var next = index; next.entries.removeAll { $0.id == id }; try commit(next)
        removeThumbnail(id: id)
    }

    @discardableResult func createGroup(name: String, color: PinGroupColor = .blue) throws -> PinGroup {
        var next = index; let group = try next.createGroup(name: name, color: color); try commit(next); return group
    }
    func renameGroup(id: UUID, name: String, color: PinGroupColor? = nil) throws {
        var next = index; try next.renameGroup(id: id, name: name, color: color); try commit(next)
    }
    func deleteGroup(id: UUID) throws {
        var next = index; try next.deleteGroup(id: id); try commit(next)
    }
    func movePin(id: UUID, to groupID: UUID) throws {
        var next = index; try next.movePin(id: id, to: groupID); try commit(next)
    }
    func setActiveGroup(id: UUID) throws {
        guard index.groups.contains(where: { $0.id == id }) else { throw PinSessionError.missingGroup }
        var next = index; next.activeGroupID = id; next.allHidden = false; try commit(next)
    }
    func setGroupHidden(id: UUID, hidden: Bool) throws {
        guard let position = index.groups.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingGroup }
        var next = index; next.groups[position].isHidden = hidden; try commit(next)
    }
    func setGroupProtected(id: UUID, protected: Bool) throws {
        guard let position = index.groups.firstIndex(where: { $0.id == id }) else { throw PinSessionError.missingGroup }
        var next = index; next.groups[position].isProtected = protected; try commit(next)
    }
    func setAllHidden(_ hidden: Bool) throws {
        var next = index; next.allHidden = hidden; try commit(next)
    }
    func showActiveGroup() throws {
        var next = index; next.allHidden = false
        if let position = next.groups.firstIndex(where: { $0.id == next.activeGroupID }) { next.groups[position].isHidden = false }
        try commit(next)
    }

    /// No full-resolution cache: the caller owns the returned image's lifetime.
    func image(id: UUID, original: Bool = false) -> CGImage? {
        guard let entry = entry(id: id) else { return nil }
        let asset = original ? entry.original : entry.current
        guard let inspected = try? inspectedAsset(asset), inspected == asset,
              let url = try? assetURL(asset.filename),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A 512-pixel preview is also used by the group manager; no hidden full-resolution preview.
    func thumbnail(id: UUID) -> NSImage? {
        if let cached = thumbnails[id] {
            thumbnailRecency.removeAll { $0 == id }; thumbnailRecency.append(id)
            return cached.image
        }
        guard let entry = entry(id: id), let inspected = try? inspectedAsset(entry.current), inspected == entry.current,
              let url = try? assetURL(entry.current.filename),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cacheThumbnail(result, id: id, cost: image.bytesPerRow * image.height)
        return result
    }
    func clearThumbnailCache() {
        thumbnails.removeAll(); thumbnailRecency.removeAll(); thumbnailCacheCost = 0
    }
    private func removeThumbnail(id: UUID) {
        if let old = thumbnails.removeValue(forKey: id) { thumbnailCacheCost -= old.cost }
        thumbnailRecency.removeAll { $0 == id }
    }
    private func cacheThumbnail(_ image: NSImage, id: UUID, cost: Int) {
        removeThumbnail(id: id)
        guard cost > 0, cost <= Self.thumbnailByteLimit else { return }
        while thumbnails.count >= Self.thumbnailCountLimit || thumbnailCacheCost > Self.thumbnailByteLimit - cost {
            guard let oldest = thumbnailRecency.first else { break }
            removeThumbnail(id: oldest)
        }
        thumbnails[id] = (image, cost); thumbnailRecency.append(id); thumbnailCacheCost += cost
    }

    func recoveredPresentation(id: UUID, screens: [CGRect]) -> PinPresentation? {
        entry(id: id)?.presentation.normalized(screens: screens.map { PinWindowFrame($0) })
    }

    private func writeAsset(_ image: CGImage) throws -> PinRasterAsset {
        guard image.width > 0, image.height > 0, image.height <= 32_000_000,
              image.width <= 32_000_000 / image.height else { throw PinSessionError.invalidImage }
        guard Int64(image.width) * Int64(image.height) <= policy.maxPixelCount else { throw PinSessionError.capacityExceeded }
        let identifier = UUID().uuidString
        let temporary = directory.appendingPathComponent(".pin-write-\(identifier).png")
        let filename = identifier + ".png"
        let target = try assetURL(filename)
        defer { try? fileManager.removeItem(at: temporary) }
        try image.writePNG(to: temporary)
        let size = Int64(try checkedRegularFile(temporary).fileSize ?? 0)
        guard size > 0, size <= policy.maxDiskBytes else { throw PinSessionError.capacityExceeded }
        try fileManager.moveItem(at: temporary, to: target)
        return PinRasterAsset(filename: filename, width: image.width, height: image.height, byteCount: size)
    }

    private func assetURL(_ filename: String) throws -> URL {
        guard PinRasterAsset.isSafeFilename(filename) || PinRichAsset.isSafeFilename(filename) else { throw PinSessionError.unsafePath }
        let url = directory.appendingPathComponent(filename)
        guard url.standardizedFileURL.deletingLastPathComponent().path == directory.path else { throw PinSessionError.unsafePath }
        return url
    }
    private func checkedRegularFile(_ url: URL) throws -> URLResourceValues {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw PinSessionError.unsafePath }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PinSessionError.unsafePath }
        return values
    }
    private func inspectedAsset(_ asset: PinRasterAsset) throws -> PinRasterAsset? {
        let url = try assetURL(asset.filename)
        // resourceValues also catches dangling links, unlike fileExists alone.
        let values: URLResourceValues
        do { values = try checkedRegularFile(url) }
        catch let error as PinSessionError { throw error }
        catch { return nil }
        guard let byteCount = values.fileSize, byteCount > 0, byteCount <= 536_870_912,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == asset.width, height == asset.height else { return nil }
        let verified = PinRasterAsset(filename: asset.filename, width: width, height: height, byteCount: Int64(byteCount))
        return verified.isValid ? verified : nil
    }

    private func commit(_ proposed: PinSessionIndex) throws {
        let next = try proposed.validated()
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.maximumManifestBytes else { throw PinSessionError.invalidManifest }
        let manifest = directory.appendingPathComponent("index.json")
        guard (try? fileManager.destinationOfSymbolicLink(atPath: manifest.path)) == nil else { throw PinSessionError.unsafePath }
        if fileManager.fileExists(atPath: manifest.path) { _ = try checkedRegularFile(manifest) }
        try data.write(to: manifest, options: .atomic)
        let previous = index
        index = next
        let keep = Set(next.entries.flatMap(\.assetFilenames))
        for filename in previous.entries.flatMap(\.assetFilenames) where !keep.contains(filename) { removeAssetIfSafe(filename) }
        let keptIDs = Set(next.entries.map(\.id))
        for entry in previous.entries where !keptIDs.contains(entry.id) { removeThumbnail(id: entry.id) }
    }
    private func removeAssetIfSafe(_ filename: String) {
        guard let url = try? assetURL(filename), (try? checkedRegularFile(url)) != nil else { return }
        try? fileManager.removeItem(at: url)
    }
    private func cleanupStaleFiles() {
        let referenced = Set(index.entries.flatMap(\.assetFilenames))
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for file in files {
            let name = file.lastPathComponent
            let suffix = String(name.dropFirst(".pin-write-".count))
            let temporary = name.hasPrefix(".pin-write-") && (PinRasterAsset.isSafeFilename(suffix) || PinRichAsset.isSafeFilename(suffix))
            let orphan = (PinRasterAsset.isSafeFilename(name) || PinRichAsset.isSafeFilename(name)) && !referenced.contains(name)
            guard temporary || orphan, (try? checkedRegularFile(file)) != nil else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
