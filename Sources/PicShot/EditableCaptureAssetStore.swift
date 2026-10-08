import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// Test seam at the durable transaction boundaries, never used to alter production IO.
enum CaptureAssetWritePoint: Equatable { case rasterWritten, documentWritten, beforeIndexCommit }

/// An index is the commit marker: immutable files are staged first, and old assets are
/// removed only after its atomic replacement succeeds. This helper owns no raster cache.
@MainActor final class EditableCaptureAssetStore {
    let directory: URL
    private let manager = FileManager.default
    init(directory: URL) { self.directory = directory }

    func requireDirectory() throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path
        else { throw PinSessionError.unsafePath }
    }
    func checkedFile(_ url: URL) throws -> URLResourceValues {
        try requireDirectory()
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path,
              url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw PinSessionError.unsafePath }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PinSessionError.unsafePath }
        return values
    }
    func url(_ filename: String) throws -> URL {
        guard PinRasterAsset.isSafeFilename(filename) || EditableCaptureAsset.isSafeDocumentFilename(filename) else { throw PinSessionError.unsafePath }
        return directory.appendingPathComponent(filename)
    }
    func remove(_ filename: String) {
        guard let target = try? url(filename), (try? checkedFile(target)) != nil else { return }
        try? manager.removeItem(at: target)
    }
    func raster(_ image: CGImage, assetID: UUID = UUID(), maximumPixels: Int = 100_000_000,
                maximumBytes: Int64 = 1_073_741_824, staged: inout [String],
                failure: ((CaptureAssetWritePoint) throws -> Void)? = nil) throws -> EditableRasterAsset {
        guard image.width > 0, image.height > 0, image.height <= maximumPixels,
              image.width <= maximumPixels / image.height else { throw PinSessionError.invalidImage }
        let filename = UUID().uuidString + ".png"
        try register(filename, staged: &staged)
        let temporary = directory.appendingPathComponent(".editable-write-" + filename)
        defer { try? manager.removeItem(at: temporary) }
        try image.writePNG(to: temporary)
        let size = Int64(try checkedFile(temporary).fileSize ?? 0)
        guard size > 0, size <= maximumBytes else { throw PinSessionError.capacityExceeded }
        try manager.moveItem(at: temporary, to: url(filename))
        try failure?(.rasterWritten)
        return EditableRasterAsset(assetID: assetID, filename: filename, width: image.width, height: image.height, byteCount: size,
                                   sha256: try digest(try url(filename), expectedBytes: size))
    }
    func stage(_ payload: EditableCapturePayload, current: EditableRasterAsset, reusingOriginal: EditableRasterAsset? = nil,
               maximumPixels: Int = 100_000_000, maximumBytes: Int64 = 1_073_741_824,
               staged: inout [String], failure: ((CaptureAssetWritePoint) throws -> Void)? = nil) throws -> EditableCaptureAsset {
        try payload.validate()
        let document = payload.document
        let data = try EditableAnnotationDocumentCodec.encode(document)
        guard data.count > 0, Int64(data.count) <= EditableCaptureAsset.maximumDocumentBytes else { throw PinSessionError.invalidManifest }
        let original: EditableRasterAsset
        if let reusable = reusingOriginal {
            guard reusable.assetID == document.originalAssetID, reusable.width == payload.originalImage.width,
                  reusable.height == payload.originalImage.height else { throw PinSessionError.invalidManifest }
            // A missing or replaced original must fail the save, not publish metadata that
            // merely claims an original still exists.
            let path = try inspect(reusable)
            original = EditableRasterAsset(assetID: reusable.assetID, filename: reusable.filename, width: reusable.width,
                height: reusable.height, byteCount: reusable.byteCount,
                sha256: try (reusable.sha256 ?? digest(path, expectedBytes: reusable.byteCount)))
        } else {
            original = try raster(payload.originalImage, assetID: document.originalAssetID, maximumPixels: maximumPixels,
                                  maximumBytes: maximumBytes, staged: &staged, failure: failure)
        }
        let base: EditableRasterAsset
        if document.baseAssetID == document.originalAssetID { base = original }
        else {
            base = try raster(payload.baseImage, assetID: document.baseAssetID, maximumPixels: maximumPixels,
                              maximumBytes: maximumBytes, staged: &staged, failure: failure)
        }
        try document.validateAssetReferences(originalID: original.assetID, baseID: base.assetID,
            originalWidth: original.width, originalHeight: original.height, baseWidth: base.width, baseHeight: base.height)
        let filename = UUID().uuidString + ".annotations"
        try register(filename, staged: &staged)
        let temporary = directory.appendingPathComponent(".editable-write-" + filename)
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        guard try checkedFile(temporary).fileSize == data.count else { throw PinSessionError.invalidManifest }
        try manager.moveItem(at: temporary, to: url(filename))
        try failure?(.documentWritten)
        let storedCurrent = current.filename == original.filename ? original : (current.filename == base.filename ? base : current)
        _ = try inspect(storedCurrent)
        return EditableCaptureAsset(documentFilename: filename, documentByteCount: Int64(data.count), original: original, base: base,
            documentSHA256: Self.digest(data), current: storedCurrent)
    }
    /// Header inspection bounds dimensions and disk bytes, without decoding full pixels.
    @discardableResult func inspect(_ asset: EditableRasterAsset, verifyContent: Bool = true) throws -> URL {
        guard asset.isValid else { throw PinSessionError.invalidManifest }
        let target = try url(asset.filename)
        guard try checkedFile(target).fileSize == Int(asset.byteCount),
              let source = CGImageSourceCreateWithURL(target as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == asset.width,
              properties[kCGImagePropertyPixelHeight] as? Int == asset.height else { throw PinSessionError.invalidImage }
        if verifyContent, let expected = asset.sha256 {
            guard try digest(target, expectedBytes: asset.byteCount) == expected else { throw PinSessionError.invalidImage }
        }
        return target
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// A bounded encoded-content checksum, not authentication or concurrent-writer isolation.
    private func digest(_ target: URL, expectedBytes: Int64) throws -> String {
        guard expectedBytes > 0, expectedBytes <= 1_073_741_824,
              try checkedFile(target).fileSize == Int(expectedBytes) else { throw PinSessionError.invalidImage }
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        var hash = SHA256(), count: Int64 = 0
        while count <= expectedBytes {
            guard let data = try handle.read(upToCount: Int(min(65_536, expectedBytes + 1 - count))), !data.isEmpty else { break }
            count += Int64(data.count)
            guard count <= expectedBytes else { throw PinSessionError.invalidImage }
            hash.update(data: data)
        }
        guard count == expectedBytes else { throw PinSessionError.invalidImage }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func read(_ asset: EditableCaptureAsset, reusingOriginal: CGImage? = nil,
              maximumRasterBytes: Int = EditorAdmissionPolicy().maximumRasterBytes) throws -> EditableCapturePayload {
        guard maximumRasterBytes >= 0, asset.decodedRasterByteEstimate <= maximumRasterBytes else { throw PinSessionError.capacityExceeded }
        guard asset.isValid else { throw PinSessionError.invalidManifest }
        let documentURL = try url(asset.documentFilename)
        guard try checkedFile(documentURL).fileSize == Int(asset.documentByteCount) else { throw PinSessionError.invalidManifest }
        let handle = try FileHandle(forReadingFrom: documentURL)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Int(asset.documentByteCount) + 1) ?? Data()
        guard bytes.count == Int(asset.documentByteCount), Self.digest(bytes) == asset.documentSHA256 else { throw PinSessionError.invalidManifest }
        let document = try EditableAnnotationDocumentCodec.decode(bytes)
        if let current = asset.current { _ = try inspect(current) }
        try document.validateAssetReferences(originalID: asset.original.assetID, baseID: asset.base.assetID,
            originalWidth: asset.original.width, originalHeight: asset.original.height,
            baseWidth: asset.base.width, baseHeight: asset.base.height)
        func image(_ raster: EditableRasterAsset) throws -> CGImage {
            let path = try inspect(raster)
            guard let source = CGImageSourceCreateWithURL(path as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw PinSessionError.invalidImage }
            return image
        }
        let original: CGImage
        if let reused = reusingOriginal {
            guard reused.width == asset.original.width, reused.height == asset.original.height else { throw PinSessionError.invalidImage }
            _ = try inspect(asset.original)
            original = reused
        } else { original = try image(asset.original) }
        let originalBytes = EditorAdmissionPolicy.rasterBytes(bytesPerRow: original.bytesPerRow, height: original.height)
        let distinctBase = asset.base.filename != asset.original.filename
        guard EditorAdmissionPolicy.sum([originalBytes, distinctBase ? asset.base.decodedRasterByteEstimate : 0]) <= maximumRasterBytes
        else { throw PinSessionError.capacityExceeded }
        let base = try (distinctBase ? image(asset.base) : original)
        let baseBytes = distinctBase ? EditorAdmissionPolicy.rasterBytes(bytesPerRow: base.bytesPerRow, height: base.height) : 0
        guard EditorAdmissionPolicy.sum([originalBytes, baseBytes]) <= maximumRasterBytes else { throw PinSessionError.capacityExceeded }
        let payload = EditableCapturePayload(document: document, originalImage: original, baseImage: base)
        try payload.validate()
        return payload
    }
    func validateFileBoundaries(_ asset: EditableCaptureAsset) throws {
        guard asset.isValid else { throw PinSessionError.invalidManifest }
        // A broken editable document is not a reason to delete otherwise valid images.
        // Missing files are reported on open; size mismatches block catalog rewrites.
        for name in asset.assetFilenames {
            let target = try url(name)
            if manager.fileExists(atPath: target.path) || (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                let size = try checkedFile(target).fileSize ?? Int.max
                let expected = name == asset.documentFilename ? asset.documentByteCount : (asset.rasters + (asset.current.map { [$0] } ?? [])).first(where: { $0.filename == name })!.byteCount
                guard Int64(size) == expected else { throw PinSessionError.invalidManifest }
            }
        }
    }
    private func journalURL(_ staged: [String]) -> URL? {
        guard let first = staged.first, first.count >= 36 else { return nil }
        return directory.appendingPathComponent(".capture-transaction-" + String(first.prefix(36)) + ".json")
    }
    private func register(_ filename: String, staged: inout [String]) throws {
        try requireDirectory()
        var next = staged; next.append(filename)
        guard let journal = journalURL(next) else { throw PinSessionError.invalidManifest }
        guard (try? manager.destinationOfSymbolicLink(atPath: journal.path)) == nil else { throw PinSessionError.unsafePath }
        if manager.fileExists(atPath: journal.path) { _ = try checkedFile(journal) }
        // Register ownership before even beginning the write, so a crash at any later
        // boundary can remove this transaction's uncommitted assets and nothing else.
        try JSONEncoder().encode(next).write(to: journal, options: .atomic)
        staged = next
    }
    func finish(_ staged: [String], committed: Bool) {
        if !committed, staged.contains(where: { name in
            guard let target = try? url(name) else { return true }
            return manager.fileExists(atPath: target.path) || (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil
        }) { return }
        guard let journal = journalURL(staged), (try? checkedFile(journal)) != nil else { return }
        try? manager.removeItem(at: journal)
    }
    struct Retirement {
        let url: URL
        let filenames: [String]
    }
    func beginRetirement(_ filenames: [String]) throws -> Retirement? {
        guard !filenames.isEmpty else { return nil }
        try requireDirectory()
        let names = Array(Set(filenames)).sorted()
        guard names.count <= 40_000, names.allSatisfy({ PinRasterAsset.isSafeFilename($0) || EditableCaptureAsset.isSafeDocumentFilename($0) }) else { throw PinSessionError.invalidManifest }
        let journal = directory.appendingPathComponent(".capture-retire-" + UUID().uuidString + ".json")
        let data = try JSONEncoder().encode(names)
        guard data.count <= 2_097_152 else { throw PinSessionError.invalidManifest }
        try data.write(to: journal, options: .atomic)
        return Retirement(url: journal, filenames: names)
    }
    func finishRetirement(_ retirement: Retirement?, committed: Bool) {
        guard let retirement else { return }
        if committed, retirement.filenames.contains(where: { name in
            guard let target = try? url(name) else { return true }
            return manager.fileExists(atPath: target.path) || (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil
        }) { return }
        guard (try? checkedFile(retirement.url)) != nil else { return }
        try? manager.removeItem(at: retirement.url)
    }
    func recoverTransactions(referenced: Set<String>) throws {
        let prefix = ".capture-transaction-"
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for journal in files where (journal.lastPathComponent.hasPrefix(prefix) || journal.lastPathComponent.hasPrefix(".capture-retire-")) && journal.pathExtension == "json" {
            let retiring = journal.lastPathComponent.hasPrefix(".capture-retire-")
            let journalPrefix = retiring ? ".capture-retire-" : prefix
            let maximumBytes = retiring ? 2_097_152 : 16_384
            let stem = String(journal.deletingPathExtension().lastPathComponent.dropFirst(journalPrefix.count))
            guard UUID(uuidString: stem) != nil else { continue }
            let size = try checkedFile(journal).fileSize ?? Int.max
            guard size > 0, size <= maximumBytes else { continue }
            let handle = try FileHandle(forReadingFrom: journal)
            let bytes: Data
            do { bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard bytes.count <= maximumBytes, let staged = try? JSONDecoder().decode([String].self, from: bytes),
                  !staged.isEmpty, staged.count <= (retiring ? 40_000 : 8), Set(staged).count == staged.count,
                  staged.allSatisfy({ PinRasterAsset.isSafeFilename($0) || EditableCaptureAsset.isSafeDocumentFilename($0) }),
                  (retiring || journalURL(staged)?.lastPathComponent == journal.lastPathComponent) else { continue }
            // Validate all boundaries before cleanup. An unsafe link never redirects a
            // read or deletion to external data, or causes the journal to be discarded.
            for name in staged {
                let file = try url(name)
                if manager.fileExists(atPath: file.path) || (try? manager.destinationOfSymbolicLink(atPath: file.path)) != nil { _ = try checkedFile(file) }
            }
            for name in staged where !referenced.contains(name) { remove(name) }
            let remaining = staged.filter { !referenced.contains($0) }.contains { name in
                guard let target = try? url(name) else { return true }
                return manager.fileExists(atPath: target.path)
            }
            if !remaining { try manager.removeItem(at: journal) }
        }
    }
    func cleanupTemporaryFiles() {
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let prefix = ".editable-write-"
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            let name = String(file.lastPathComponent.dropFirst(prefix.count))
            guard PinRasterAsset.isSafeFilename(name) || EditableCaptureAsset.isSafeDocumentFilename(name),
                  (try? checkedFile(file)) != nil else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
