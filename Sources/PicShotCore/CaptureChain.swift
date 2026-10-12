import Foundation

public enum CaptureChainError: Error, LocalizedError, Equatable {
    case invalidName, invalidOutputs, invalidManifest, unsupportedVersion, limitReached
    case duplicateIdentifier, missingDefinition, invalidSelection, unsafePath, loadFailed, saveFailed

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "请输入 1–64 个字符的截图链名称（最多 256 字节，不能包含换行或控制字符）。"
        case .invalidOutputs: return "请选择 1–3 个不同的输出操作，并按需要排列顺序。"
        case .invalidManifest: return "截图链文件已损坏或内容无效，原文件未被覆盖。"
        case .unsupportedVersion: return "截图链文件来自不支持的版本，原文件未被覆盖。"
        case .limitReached: return "最多保存 32 个截图链，请先删除不需要的截图链。"
        case .duplicateIdentifier: return "截图链标识重复，无法保存。"
        case .missingDefinition: return "此截图链已不存在，请重新选择。"
        case .invalidSelection: return "所选截图链已不存在，请重新选择已保存的截图链。"
        case .unsafePath: return "截图链保存位置不安全，无法读取或修改。"
        case .loadFailed: return "无法读取截图链，请检查本地文件权限后重试。"
        case .saveFailed: return "无法保存截图链，请检查本地文件权限和可用空间后重试；原截图链未改变。"
        }
    }
}

public enum CaptureChainOutput: String, Codable, CaseIterable, Hashable, Sendable {
    case quickSavePNG, copy, pin

    public var title: String {
        switch self {
        case .quickSavePNG: return "快速保存 PNG"
        case .copy: return "复制"
        case .pin: return "贴图"
        }
    }
}

/// A saved reference only. A missing preset remains unavailable; decoding never
/// substitutes an interactive capture or another preset.
public enum CaptureChainSource: Codable, Equatable, Sendable {
    case region
    case preset(UUID)

    private enum CodingKeys: String, CodingKey { case kind, presetID }
    private enum Kind: String, Codable { case region, preset }

    public init(from decoder: Decoder) throws {
        try rejectUnknownChainKeys(decoder, allowed: ["kind", "presetID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .region:
            guard !values.contains(.presetID) else { throw CaptureChainError.invalidManifest }
            self = .region
        case .preset:
            self = .preset(try values.decode(UUID.self, forKey: .presetID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .region:
            try values.encode(Kind.region, forKey: .kind)
        case .preset(let id):
            try values.encode(Kind.preset, forKey: .kind)
            try values.encode(id, forKey: .presetID)
        }
    }
}

/// Deliberately saved metadata. Images, file paths, runtime state and receipts
/// have no representation in this definition or its encoded form.
public struct CaptureChainDefinition: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameCharacters = 64
    public static let maximumNameBytes = 256
    public static let maximumOutputs = 3
    public let id: UUID
    public let name: String
    public let source: CaptureChainSource
    public let outputs: [CaptureChainOutput]

    public init(id: UUID = UUID(), name: String, source: CaptureChainSource,
                outputs: [CaptureChainOutput]) throws {
        // Trim ordinary surrounding whitespace, but never sanitize away a
        // control character or newline supplied by a caller.
        guard !Self.containsForbiddenNameCharacters(name) else { throw CaptureChainError.invalidName }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { throw CaptureChainError.invalidName }
        guard !outputs.isEmpty, outputs.count <= Self.maximumOutputs,
              Set(outputs).count == outputs.count else { throw CaptureChainError.invalidOutputs }
        self.id = id; self.name = name; self.source = source; self.outputs = outputs
    }

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maximumNameCharacters && name.utf8.count <= maximumNameBytes &&
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) && !containsForbiddenNameCharacters(name)
    }

    private static func containsForbiddenNameCharacters(_ name: String) -> Bool {
        name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    public func replacing(name: String? = nil, source: CaptureChainSource? = nil,
                          outputs: [CaptureChainOutput]? = nil) throws -> CaptureChainDefinition {
        try CaptureChainDefinition(id: id, name: name ?? self.name, source: source ?? self.source,
                                   outputs: outputs ?? self.outputs)
    }

    private enum CodingKeys: String, CodingKey { case id, name, source, outputs }
    public init(from decoder: Decoder) throws {
        try rejectUnknownChainKeys(decoder, allowed: ["id", "name", "source", "outputs"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .name)
        guard Self.validName(name) else { throw CaptureChainError.invalidManifest }
        var records = try values.nestedUnkeyedContainer(forKey: .outputs)
        if let count = records.count, count > Self.maximumOutputs { throw CaptureChainError.invalidOutputs }
        var outputs: [CaptureChainOutput] = []
        while !records.isAtEnd {
            guard outputs.count < Self.maximumOutputs else { throw CaptureChainError.invalidOutputs }
            outputs.append(try records.decode(CaptureChainOutput.self))
        }
        try self.init(id: values.decode(UUID.self, forKey: .id), name: name,
                      source: values.decode(CaptureChainSource.self, forKey: .source), outputs: outputs)
    }
}

/// A small, versioned catalog. Selection is saved only by an explicit selection
/// operation; an empty selection never defaults to the first definition.
public struct CaptureChainIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumDefinitions = 32
    public static let maximumBytes = 128 * 1_024
    public let version: Int
    public let definitions: [CaptureChainDefinition]
    public let selectedID: UUID?

    public init(definitions: [CaptureChainDefinition] = [], selectedID: UUID? = nil) throws {
        guard definitions.count <= Self.maximumDefinitions else { throw CaptureChainError.limitReached }
        let identifiers = Set(definitions.map(\.id))
        guard identifiers.count == definitions.count else { throw CaptureChainError.duplicateIdentifier }
        if let selectedID, !identifiers.contains(selectedID) { throw CaptureChainError.invalidSelection }
        version = Self.schemaVersion; self.definitions = definitions; self.selectedID = selectedID
    }

    private enum CodingKeys: String, CodingKey { case version, definitions, selectedID }
    public init(from decoder: Decoder) throws {
        try rejectUnknownChainKeys(decoder, allowed: ["version", "definitions", "selectedID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.schemaVersion else {
            throw CaptureChainError.unsupportedVersion
        }
        var records = try values.nestedUnkeyedContainer(forKey: .definitions)
        if let count = records.count, count > Self.maximumDefinitions { throw CaptureChainError.limitReached }
        var definitions: [CaptureChainDefinition] = []
        while !records.isAtEnd {
            guard definitions.count < Self.maximumDefinitions else { throw CaptureChainError.limitReached }
            definitions.append(try records.decode(CaptureChainDefinition.self))
        }
        try self.init(definitions: definitions, selectedID: values.decodeIfPresent(UUID.self, forKey: .selectedID))
    }
}

/// Codable normally ignores unknown fields. This catalog is deliberately strict:
/// runtime payloads and newer schemas must not be silently accepted and rewritten.
private struct CaptureChainCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownChainKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: CaptureChainCodingKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw CaptureChainError.invalidManifest
    }
}
