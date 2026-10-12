import Foundation
import Combine
import PicShotCore

/// A bounded catalog of deliberately saved script bodies. Drafts and runtime sessions never write here.
/// Every deliberate change commits the whole catalog before publishing memory.
@MainActor final class TextScriptStore: ObservableObject {
    @Published private(set) var index: TextScriptIndex
    let directory: URL
    static let manifestFilename = "text-scripts.json"
    private let fileManager = FileManager.default
    /// A narrow failure seam for verifying a failed commit preserves disk and memory.
    var beforeManifestCommit: (() throws -> Void)?

    var definitions: [TextScriptDefinition] { index.definitions }
    var selectedID: UUID? { index.selectedID }

    init(directory: URL? = nil) throws {
        index = try TextScriptIndex()
        do {
            guard let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PicShot/TextScripts", isDirectory: true), support.isFileURL,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: support.path)) == nil else {
                throw TextScriptCatalogError.unsafePath
            }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let values = try support.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw TextScriptCatalogError.unsafePath }
            self.directory = URL(fileURLWithPath: support.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
            try reload()
        } catch let error as TextScriptCatalogError { throw error }
        catch { throw TextScriptCatalogError.loadFailed }
    }

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestFilename) }

    func definition(id: UUID) -> TextScriptDefinition? { definitions.first { $0.id == id } }

    /// Failed reloads leave both the prior published index and the file untouched.
    func reload() throws {
        do { index = try readIndex() }
        catch let error as TextScriptCatalogError { throw error }
        catch { throw TextScriptCatalogError.loadFailed }
    }

    func add(_ definition: TextScriptDefinition, select: Bool = false) throws {
        guard self.definition(id: definition.id) == nil else { throw TextScriptCatalogError.duplicateIdentifier }
        try commit(TextScriptIndex(definitions: definitions + [definition], selectedID: select ? definition.id : selectedID))
    }

    func update(_ definition: TextScriptDefinition, select: Bool = false) throws {
        guard let position = definitions.firstIndex(where: { $0.id == definition.id }) else {
            throw TextScriptCatalogError.missingDefinition
        }
        var next = definitions; next[position] = definition
        try commit(TextScriptIndex(definitions: next, selectedID: select ? definition.id : selectedID))
    }

    func update(id: UUID, name: String? = nil, source: String? = nil) throws {
        guard let definition = definition(id: id) else { throw TextScriptCatalogError.missingDefinition }
        try update(definition.replacing(name: name, source: source))
    }

    func remove(id: UUID) throws {
        guard definition(id: id) != nil else { throw TextScriptCatalogError.missingDefinition }
        try commit(TextScriptIndex(definitions: definitions.filter { $0.id != id },
                                     selectedID: selectedID == id ? nil : selectedID))
    }

    func select(id: UUID?) throws {
        try commit(TextScriptIndex(definitions: definitions, selectedID: id))
    }

    private func commit(_ next: TextScriptIndex) throws {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(next)
            guard bytes.count <= TextScriptIndex.maximumBytes else { throw TextScriptCatalogError.catalogTooLarge }
            // Do not overwrite externally corrupted, unsupported or unsafe files,
            // including after a failed explicit reload.
            _ = try readIndex()
            try beforeManifestCommit?()
            try bytes.write(to: manifestURL, options: .atomic)
            index = next
        } catch let error as TextScriptCatalogError { throw error }
        catch { throw TextScriptCatalogError.saveFailed }
    }

    private func readIndex() throws -> TextScriptIndex {
        try checkDirectory()
        guard try checkedManifestExists() else { return try TextScriptIndex() }
        let handle = try FileHandle(forReadingFrom: manifestURL)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: TextScriptIndex.maximumBytes + 1) ?? Data()
        guard bytes.count <= TextScriptIndex.maximumBytes else { throw TextScriptCatalogError.invalidManifest }
        do {
            // Codable rejects unknown/missing schema fields. This preflight also
            // rejects duplicate keys (including escaped equivalents), which
            // JSONDecoder would otherwise silently collapse.
            var syntax = TextScriptCatalogJSON(bytes: Array(bytes))
            try syntax.validate()
            return try JSONDecoder().decode(TextScriptIndex.self, from: bytes)
        }
        catch let error as TextScriptCatalogError where error == .unsupportedVersion { throw error }
        catch { throw TextScriptCatalogError.invalidManifest }
    }

    private func checkDirectory() throws {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) == nil,
              directory.standardizedFileURL.resolvingSymlinksInPath().path == directory.path else {
            throw TextScriptCatalogError.unsafePath
        }
        // A retained URL may cache resource values after the directory moves.
        // Query the current filesystem before treating a missing manifest as an
        // intentionally empty catalog; a missing directory must preserve index.
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw TextScriptCatalogError.unsafePath }
    }

    private func checkedManifestExists() throws -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: manifestURL.path)) == nil else { throw TextScriptCatalogError.unsafePath }
        guard fileManager.fileExists(atPath: manifestURL.path) else { return false }
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TextScriptCatalogError.unsafePath }
        guard let size = values.fileSize, size >= 0, size <= TextScriptIndex.maximumBytes else {
            throw TextScriptCatalogError.invalidManifest
        }
        return true
    }
}

/// Bounded structural preflight only; JSONDecoder remains the schema/value
/// validator. No decoded source or runtime payload is retained by this scanner.
private struct TextScriptCatalogJSON {
    let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func validate() throws {
        try value(depth: 0); whitespace()
        guard offset == bytes.count else { throw TextScriptCatalogError.invalidManifest }
    }

    private mutating func value(depth: Int) throws {
        guard depth <= 8 else { throw TextScriptCatalogError.invalidManifest }
        whitespace()
        guard offset < bytes.count else { throw TextScriptCatalogError.invalidManifest }
        switch bytes[offset] {
        case 123: // {
            offset += 1; whitespace()
            if consume(125) { return }
            var keys = Set<String>()
            while true {
                whitespace()
                let start = offset
                try string()
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
                guard keys.insert(key).inserted else { throw TextScriptCatalogError.invalidManifest }
                whitespace()
                guard consume(58) else { throw TextScriptCatalogError.invalidManifest }
                try value(depth: depth + 1); whitespace()
                if consume(125) { return }
                guard consume(44) else { throw TextScriptCatalogError.invalidManifest }
            }
        case 91: // [
            offset += 1; whitespace()
            if consume(93) { return }
            while true {
                try value(depth: depth + 1); whitespace()
                if consume(93) { return }
                guard consume(44) else { throw TextScriptCatalogError.invalidManifest }
            }
        case 34: try string()
        default:
            let start = offset
            while offset < bytes.count, ![UInt8(9), 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            guard offset > start else { throw TextScriptCatalogError.invalidManifest }
        }
    }

    private mutating func string() throws {
        guard consume(34) else { throw TextScriptCatalogError.invalidManifest }
        while offset < bytes.count {
            let next = bytes[offset]; offset += 1
            if next == 34 { return }
            if next == 92 { offset += 1 }
        }
        throw TextScriptCatalogError.invalidManifest
    }

    private mutating func whitespace() {
        while offset < bytes.count, [UInt8(9), 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1; return true
    }
}
