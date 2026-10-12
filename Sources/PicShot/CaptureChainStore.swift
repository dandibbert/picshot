import Foundation
import Combine
import PicShotCore

/// A bounded metadata-only catalog. Drafts and runtime sessions never write here.
/// Every deliberate change commits the whole catalog before publishing memory.
@MainActor final class CaptureChainStore: ObservableObject {
    @Published private(set) var index: CaptureChainIndex
    let directory: URL
    static let manifestFilename = "chains.json"
    private let fileManager = FileManager.default
    /// A narrow failure seam for verifying a failed commit preserves disk and memory.
    var beforeManifestCommit: (() throws -> Void)?

    var definitions: [CaptureChainDefinition] { index.definitions }
    var selectedID: UUID? { index.selectedID }

    init(directory: URL? = nil) throws {
        index = try CaptureChainIndex()
        do {
            guard let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PicShot/CaptureChains", isDirectory: true), support.isFileURL,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: support.path)) == nil else {
                throw CaptureChainError.unsafePath
            }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let values = try support.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CaptureChainError.unsafePath }
            self.directory = URL(fileURLWithPath: support.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
            try reload()
        } catch let error as CaptureChainError { throw error }
        catch { throw CaptureChainError.loadFailed }
    }

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestFilename) }

    func definition(id: UUID) -> CaptureChainDefinition? { definitions.first { $0.id == id } }

    /// Failed reloads leave both the prior published index and the file untouched.
    func reload() throws {
        do { index = try readIndex() }
        catch let error as CaptureChainError { throw error }
        catch { throw CaptureChainError.loadFailed }
    }

    func add(_ definition: CaptureChainDefinition) throws {
        guard self.definition(id: definition.id) == nil else { throw CaptureChainError.duplicateIdentifier }
        try commit(CaptureChainIndex(definitions: definitions + [definition], selectedID: selectedID))
    }

    func update(_ definition: CaptureChainDefinition) throws {
        guard let position = definitions.firstIndex(where: { $0.id == definition.id }) else {
            throw CaptureChainError.missingDefinition
        }
        var next = definitions; next[position] = definition
        try commit(CaptureChainIndex(definitions: next, selectedID: selectedID))
    }

    func update(id: UUID, name: String? = nil, source: CaptureChainSource? = nil,
                outputs: [CaptureChainOutput]? = nil) throws {
        guard let definition = definition(id: id) else { throw CaptureChainError.missingDefinition }
        try update(definition.replacing(name: name, source: source, outputs: outputs))
    }

    func remove(id: UUID) throws {
        guard definition(id: id) != nil else { throw CaptureChainError.missingDefinition }
        try commit(CaptureChainIndex(definitions: definitions.filter { $0.id != id },
                                     selectedID: selectedID == id ? nil : selectedID))
    }

    func select(id: UUID?) throws {
        try commit(CaptureChainIndex(definitions: definitions, selectedID: id))
    }

    private func commit(_ next: CaptureChainIndex) throws {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(next)
            guard bytes.count <= CaptureChainIndex.maximumBytes else { throw CaptureChainError.invalidManifest }
            // Do not overwrite externally corrupted, unsupported or unsafe files,
            // including after a failed explicit reload.
            _ = try readIndex()
            try beforeManifestCommit?()
            try bytes.write(to: manifestURL, options: .atomic)
            index = next
        } catch let error as CaptureChainError { throw error }
        catch { throw CaptureChainError.saveFailed }
    }

    private func readIndex() throws -> CaptureChainIndex {
        try checkDirectory()
        guard try checkedManifestExists() else { return try CaptureChainIndex() }
        let handle = try FileHandle(forReadingFrom: manifestURL)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: CaptureChainIndex.maximumBytes + 1) ?? Data()
        guard bytes.count <= CaptureChainIndex.maximumBytes else { throw CaptureChainError.invalidManifest }
        do { return try JSONDecoder().decode(CaptureChainIndex.self, from: bytes) }
        catch let error as CaptureChainError where error == .unsupportedVersion { throw error }
        catch { throw CaptureChainError.invalidManifest }
    }

    private func checkDirectory() throws {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil,
              directory.standardizedFileURL.resolvingSymlinksInPath().path == directory.path else {
            throw CaptureChainError.unsafePath
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CaptureChainError.unsafePath }
    }

    private func checkedManifestExists() throws -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: manifestURL.path)) == nil else { throw CaptureChainError.unsafePath }
        guard fileManager.fileExists(atPath: manifestURL.path) else { return false }
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CaptureChainError.unsafePath }
        guard let size = values.fileSize, size >= 0, size <= CaptureChainIndex.maximumBytes else {
            throw CaptureChainError.invalidManifest
        }
        return true
    }
}
