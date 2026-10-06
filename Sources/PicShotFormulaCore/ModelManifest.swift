import Foundation
import CryptoKit

public struct ModelAsset: Sendable, Equatable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
    public let url: URL
    public let allowedDownloadHosts: [String]
    public init(name: String, bytes: Int64, sha256: String, url: URL, allowedDownloadHosts: [String]? = nil) {
        self.name = name; self.bytes = bytes; self.sha256 = sha256; self.url = url
        self.allowedDownloadHosts = allowedDownloadHosts ?? [url.host ?? ""]
    }
    public func permitsDownloadURL(_ candidate: URL?) -> Bool {
        guard let candidate, candidate.scheme == "https", candidate.user == nil, candidate.password == nil,
              candidate.port == nil || candidate.port == 443, let host = candidate.host?.lowercased() else { return false }
        return allowedDownloadHosts.contains(host)
    }
}

public struct ModelPackManifest: Sendable {
    public let id: String
    public let title: String
    public let license: String
    public let source: URL
    public let assets: [ModelAsset]
    public var totalBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }
    public init(id: String, title: String, license: String, source: URL, assets: [ModelAsset]) {
        self.id = id; self.title = title; self.license = license; self.source = source; self.assets = assets
    }

    public func validateLayout() throws {
        let validCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        func safeName(_ name: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && name.unicodeScalars.allSatisfy { validCharacters.contains($0) }
        }
        guard safeName(id), !assets.isEmpty, assets.count <= 100,
              Set(assets.map(\.name)).count == assets.count,
              assets.allSatisfy({ safeName($0.name) && $0.bytes > 0 && $0.bytes <= 1_073_741_824 && $0.sha256.count == 64 && $0.permitsDownloadURL($0.url) }) else {
            throw ModelValidationError.invalid(id)
        }
    }

    public static let table = ModelPackManifest(
        id: "slanet-plus-v2.0.0-d57a942", title: "SLANet-plus", license: "Apache-2.0",
        source: URL(string: "https://www.modelscope.cn/models/RapidAI/RapidTable/files?Revision=v2.0.0")!,
        assets: [ModelAsset(name: "slanet-plus.onnx", bytes: 7_758_305,
            sha256: "d57a942af6a2f57d6a4a0372573c696a2379bf5857c45e2ac69993f3b334514b",
            url: URL(string: "https://www.modelscope.cn/models/RapidAI/RapidTable/resolve/v2.0.0/slanet-plus.onnx")!)])

    public static let formulaRevision = "1cef9f0bdcd6a4c63df7de1311fb0894593340cc"
    public static let formula: ModelPackManifest = {
        let root = "https://huggingface.co/breezedeus/pix2text-mfr-1.5/resolve/\(formulaRevision)/"
        func asset(_ name: String, _ bytes: Int64, _ sha: String) -> ModelAsset {
            ModelAsset(name: name, bytes: bytes, sha256: sha, url: URL(string: root + name)!,
                allowedDownloadHosts: ["huggingface.co", "cdn-lfs.huggingface.co", "cdn-lfs-us-1.huggingface.co", "cdn-lfs-eu-1.huggingface.co", "cas-bridge.xethub.hf.co", "us.aws.cdn.hf.co"])
        }
        return ModelPackManifest(id: "pix2text-mfr-1.5-1cef9f0", title: "Pix2Text-MFR-1.5", license: "MIT (author-published model card)",
            source: URL(string: "https://huggingface.co/breezedeus/pix2text-mfr-1.5/tree/\(formulaRevision)")!, assets: [
                asset("encoder_model.onnx", 87_510_770, "080a3f660f08bc9ebcacdd96e34be6b6400f8c7e62d7cd0dd8251badc37f610b"),
                asset("decoder_model.onnx", 32_026_253, "917deb98e91a0453c5f234f58a0f32f9fb037de8527c7eb4ed394daf9e692f2a"),
                asset("tokenizer.json", 113_168, "4ffbeb2143e6a38324bb6111b7a8109530d38a076a8439aa5777535f0a32758a"),
                asset("config.json", 1_573, "fe4076f08f6ca75940f6af9268d51928b834979a69bc2145dacee62633a5d53d"),
                asset("preprocessor_config.json", 450, "36a945a7cc645688b9ef64dabae16979cf5f7c1c448569cc306694edc0598b9b"),
                asset("generation_config.json", 211, "7363c031c6142d35a276815b0e285cc289dfb9f51d0b7c63de8f3ed65cc8d8ad"),
                asset("README.md", 9_441, "7ae7136c49c64378ff09a86b750ef9c2007ad8e91e148be391e3480bfd9dce97")
            ])
    }()
}

public enum ModelValidationError: LocalizedError {
    case missing(String), invalid(String)
    public var errorDescription: String? {
        switch self {
        case .missing(let file): return "模型文件缺失：\(file)。请下载模型包。"
        case .invalid(let file): return "模型校验失败：\(file)。请重新下载官方模型包。"
        }
    }
}

public enum ModelAssetVerifier {
    // Every inference verifies its fixed manifest again. Never trust a mutable
    // downloaded manifest, a marker file, filename, mtime or just Content-Length.
    public static func verify(_ asset: ModelAsset, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == asset.bytes else { throw ModelValidationError.invalid(asset.name) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            read += Int64(chunk.count)
            guard read <= asset.bytes else { throw ModelValidationError.invalid(asset.name) }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard read == asset.bytes, digest == asset.sha256 else { throw ModelValidationError.invalid(asset.name) }
    }
    public static func verify(_ manifest: ModelPackManifest, in directory: URL) throws {
        try manifest.validateLayout()
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ModelValidationError.invalid(manifest.id) }
        for asset in manifest.assets { try verify(asset, at: directory.appendingPathComponent(asset.name)) }
    }
}
