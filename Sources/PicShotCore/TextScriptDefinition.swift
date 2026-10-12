import Foundation

public enum TextScriptCatalogError: Error, LocalizedError, Equatable {
    case invalidName, invalidSource, invalidManifest, unsupportedVersion, limitReached, catalogTooLarge
    case duplicateIdentifier, missingDefinition, invalidSelection, unsafePath, loadFailed, saveFailed

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "请输入 1–64 个字符的脚本名称（最多 256 字节，不能包含换行或控制字符）。"
        case .invalidSource: return "请输入脚本函数体，最多 16,384 个 UTF-8 字节。"
        case .invalidManifest: return "文字脚本文件已损坏或内容无效，原文件未被覆盖。"
        case .unsupportedVersion: return "文字脚本文件来自不支持的版本，原文件未被覆盖。"
        case .limitReached: return "最多保存 32 个文字脚本，请先删除不需要的脚本。"
        case .catalogTooLarge: return "文字脚本文件不能超过 1 MiB；请缩短脚本后重试，原文件未改变。"
        case .duplicateIdentifier: return "脚本标识重复，无法保存。"
        case .missingDefinition: return "此脚本已不存在，请重新选择。"
        case .invalidSelection: return "所选脚本已不存在，请重新选择已保存的脚本。"
        case .unsafePath: return "文字脚本保存位置不安全，无法读取或修改。"
        case .loadFailed: return "无法读取文字脚本，请检查本地文件权限后重试。"
        case .saveFailed: return "无法保存文字脚本，请检查本地文件权限和可用空间后重试；原脚本未改变。"
        }
    }
}

/// A deliberately saved JavaScript function body. The only route is supplied
/// by the app: region → local OCR → transform(text) → checked text Copy.
/// Runtime input, output, images, paths and receipts have no fields here.
public struct TextScriptDefinition: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameCharacters = 64
    public static let maximumNameBytes = 256
    public static let maximumSourceBytes = 16_384
    public let id: UUID
    public let name: String
    public let source: String

    public init(id: UUID = UUID(), name: String, source: String) throws {
        guard !Self.forbiddenNameCharacters(name) else { throw TextScriptCatalogError.invalidName }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(normalized) else { throw TextScriptCatalogError.invalidName }
        guard Self.validSource(source) else { throw TextScriptCatalogError.invalidSource }
        self.id = id; self.name = normalized; self.source = source
    }

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maximumNameBytes && name.count <= maximumNameCharacters &&
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) && !forbiddenNameCharacters(name)
    }

    public static func validSource(_ source: String) -> Bool {
        source.utf8.count <= maximumSourceBytes && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func forbiddenNameCharacters(_ name: String) -> Bool {
        name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    public func replacing(name: String? = nil, source: String? = nil) throws -> TextScriptDefinition {
        try TextScriptDefinition(id: id, name: name ?? self.name, source: source ?? self.source)
    }

    private enum CodingKeys: String, CodingKey { case id, name, source }
    public init(from decoder: Decoder) throws {
        try rejectUnknownTextScriptKeys(decoder, allowed: ["id", "name", "source"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .name)
        guard Self.validName(name) else { throw TextScriptCatalogError.invalidManifest }
        try self.init(id: values.decode(UUID.self, forKey: .id), name: name,
                      source: values.decode(String.self, forKey: .source))
    }
}

/// Selection is persisted only after an explicit user selection. Opening an
/// empty catalog neither creates an example nor chooses the first script.
public struct TextScriptIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumDefinitions = 32
    public static let maximumBytes = 1_024 * 1_024
    public let version: Int
    public let definitions: [TextScriptDefinition]
    public let selectedID: UUID?

    public init(definitions: [TextScriptDefinition] = [], selectedID: UUID? = nil) throws {
        guard definitions.count <= Self.maximumDefinitions else { throw TextScriptCatalogError.limitReached }
        let ids = Set(definitions.map(\.id))
        guard ids.count == definitions.count else { throw TextScriptCatalogError.duplicateIdentifier }
        if let selectedID, !ids.contains(selectedID) { throw TextScriptCatalogError.invalidSelection }
        version = Self.schemaVersion; self.definitions = definitions; self.selectedID = selectedID
    }

    private enum CodingKeys: String, CodingKey { case version, definitions, selectedID }
    public init(from decoder: Decoder) throws {
        try rejectUnknownTextScriptKeys(decoder, allowed: ["version", "definitions", "selectedID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.schemaVersion else {
            throw TextScriptCatalogError.unsupportedVersion
        }
        var records = try values.nestedUnkeyedContainer(forKey: .definitions)
        if let count = records.count, count > Self.maximumDefinitions { throw TextScriptCatalogError.limitReached }
        var definitions: [TextScriptDefinition] = []
        while !records.isAtEnd {
            guard definitions.count < Self.maximumDefinitions else { throw TextScriptCatalogError.limitReached }
            definitions.append(try records.decode(TextScriptDefinition.self))
        }
        try self.init(definitions: definitions, selectedID: values.decodeIfPresent(UUID.self, forKey: .selectedID))
    }
}

private struct TextScriptCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownTextScriptKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: TextScriptCodingKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw TextScriptCatalogError.invalidManifest
    }
}
