import Foundation
import Combine
import PicShotCore

/// A bounded metadata-only local catalog. A failed read never overwrites the
/// existing file; a failed write never changes the published in-memory catalog.
@MainActor final class CapturePresetStore: ObservableObject {
    @Published private(set) var presets: [CapturePreset] = []
    let directory: URL
    static let manifestFilename = "presets.json"
    private let fileManager = FileManager.default

    init(directory: URL? = nil) throws {
        do {
            guard let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PicShot/CapturePresets", isDirectory: true), support.isFileURL,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: support.path)) == nil else {
                throw CapturePresetError.unsafePath
            }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let values = try support.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CapturePresetError.unsafePath }
            self.directory = URL(fileURLWithPath: support.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
            try reload()
        } catch let error as CapturePresetError { throw error }
        catch { throw CapturePresetError.loadFailed }
    }

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestFilename) }

    /// Explicit reload is useful if access was temporarily unavailable. On failure,
    /// the prior in-memory catalog and the existing file both remain untouched.
    func reload() throws {
        do {
            try checkDirectory()
            guard try checkedManifestExists() else { presets = []; return }
            let handle = try FileHandle(forReadingFrom: manifestURL)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: CapturePresetIndex.maximumBytes + 1) ?? Data()
            guard bytes.count <= CapturePresetIndex.maximumBytes else { throw CapturePresetError.invalidManifest }
            do { presets = try JSONDecoder().decode(CapturePresetIndex.self, from: bytes).presets }
            catch let error as CapturePresetError where error == .unsupportedVersion { throw error }
            catch { throw CapturePresetError.invalidManifest }
        } catch let error as CapturePresetError { throw error }
        catch { throw CapturePresetError.loadFailed }
    }

    func preset(id: UUID) -> CapturePreset? { presets.first { $0.id == id } }

    func add(_ preset: CapturePreset) throws {
        guard !presets.contains(where: { $0.id == preset.id }) else { throw CapturePresetError.duplicateIdentifier }
        try commit(presets + [preset])
    }

    func rename(id: UUID, name: String) throws { try update(id: id, name: name) }
    func updateDelay(id: UUID, delay: ScreenshotDelay) throws { try update(id: id, delay: delay) }

    func update(id: UUID, name: String? = nil, delay: ScreenshotDelay? = nil) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw CapturePresetError.missingPreset }
        var next = presets; next[index] = try next[index].replacing(name: name, delay: delay)
        try commit(next)
    }

    func remove(id: UUID) throws {
        guard presets.contains(where: { $0.id == id }) else { throw CapturePresetError.missingPreset }
        try commit(presets.filter { $0.id != id })
    }

    private func commit(_ presets: [CapturePreset]) throws {
        let index = try CapturePresetIndex(presets: presets)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(index)
            guard bytes.count <= CapturePresetIndex.maximumBytes else { throw CapturePresetError.invalidManifest }
            try checkDirectory(); _ = try checkedManifestExists()
            try bytes.write(to: manifestURL, options: .atomic)
            self.presets = presets
        } catch let error as CapturePresetError { throw error }
        catch { throw CapturePresetError.saveFailed }
    }

    private func checkDirectory() throws {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil else { throw CapturePresetError.unsafePath }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CapturePresetError.unsafePath }
    }

    /// Reject symbolic links, directories and oversized files before any read.
    private func checkedManifestExists() throws -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: manifestURL.path)) == nil else { throw CapturePresetError.unsafePath }
        guard fileManager.fileExists(atPath: manifestURL.path) else { return false }
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CapturePresetError.unsafePath }
        guard let size = values.fileSize, size >= 0, size <= CapturePresetIndex.maximumBytes else {
            throw CapturePresetError.invalidManifest
        }
        return true
    }
}
