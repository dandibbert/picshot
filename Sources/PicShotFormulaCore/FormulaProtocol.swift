import Foundation

public enum MLJobLimits {
    public static let inputBytes = 32 * 1_024 * 1_024
    public static let inputPixels = 16_000_000
    public static let inputDimension = 8_192
    public static let outputBytes = 1_024 * 1_024
    public static let formulaTokens = 1_024
    public static let formulaTextBytes = 65_536
    public static let seconds: TimeInterval = 120
}

public struct FormulaRecognitionResult: Codable, Sendable, Equatable {
    public let latex: String
    public let tokenCount: Int
    public let modelID: String
    public let warnings: [String]
    public init(latex: String, tokenCount: Int, modelID: String, warnings: [String] = []) {
        self.latex = latex; self.tokenCount = tokenCount; self.modelID = modelID; self.warnings = warnings
    }
}

public enum FormulaError: LocalizedError {
    case invalidInput, invalidTokenizer, invalidTensor, tokenLimit, timeLimit, emptyResult
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "图片无效或超出限制（最长边 8192 像素、1600 万像素、32 MiB）。"
        case .invalidTokenizer: return "公式词表格式不受支持。请重新下载模型包。"
        case .invalidTensor: return "公式模型的输入或输出格式与此版本不匹配。"
        case .tokenLimit: return "公式超过 1024 个标记，已停止。请缩小截图范围后重试。"
        case .timeLimit: return "识别超过两分钟，已停止。请缩小截图范围后重试。"
        case .emptyResult: return "未识别出公式。请截取单个清晰的公式后重试。"
        }
    }
}

// The pinned tokenizer uses Hugging Face ByteLevel BPE, NOT SentencePiece.
// Only decoding is required: the decoder network generates vocabulary IDs.
public struct FormulaTokenizer {
    private let vocabulary: [Int: String]
    private let specialIDs: Set<Int>
    private let byteForScalar: [Unicode.Scalar: UInt8]

    public init(data: Data) throws {
        guard data.count <= 1_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decoder = json["decoder"] as? [String: Any], decoder["type"] as? String == "ByteLevel",
              let model = json["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocab = model["vocab"] as? [String: Int], !vocab.isEmpty, vocab.count <= 10_000 else {
            throw FormulaError.invalidTokenizer
        }
        var inverse: [Int: String] = [:]
        for (token, id) in vocab {
            guard id >= 0, inverse[id] == nil else { throw FormulaError.invalidTokenizer }
            inverse[id] = token
        }
        vocabulary = inverse
        let added = json["added_tokens"] as? [[String: Any]] ?? []
        specialIDs = Set(added.filter { $0["special"] as? Bool == true }.compactMap { $0["id"] as? Int })
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte); scalars.append(256 + extra); extra += 1
        }
        byteForScalar = Dictionary(uniqueKeysWithValues: zip(scalars, bytes).map { (Unicode.Scalar($0.0)!, UInt8($0.1)) })
    }

    public func decode(_ ids: [Int64]) throws -> String {
        guard ids.count <= MLJobLimits.formulaTokens + 1 else { throw FormulaError.tokenLimit }
        var bytes: [UInt8] = []
        for id in ids {
            if id == 2 { break }
            if specialIDs.contains(Int(id)) { continue }
            guard let token = vocabulary[Int(id)] else { throw FormulaError.invalidTokenizer }
            for scalar in token.unicodeScalars {
                guard let byte = byteForScalar[scalar] else { throw FormulaError.invalidTokenizer }
                bytes.append(byte)
            }
            guard bytes.count <= MLJobLimits.formulaTextBytes else { throw FormulaError.tokenLimit }
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw FormulaError.invalidTokenizer }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
