import Foundation
import CoreGraphics
import Vision

/// Keep the native symbology and exact decoder string. UPC-A shares its bars with a
/// zero-prefixed EAN-13: never silently remove that leading zero from copied content.
enum BarcodeSymbology: Sendable, Equatable, Hashable {
    case qr, code128, ean13, ean8, upce, code39, code39Checksum, code39FullASCII, code39FullASCIIChecksum
    case dataMatrix, pdf417, aztec, other(String)

    init(_ native: VNBarcodeSymbology) {
        switch native {
        case .qr: self = .qr
        case .code128: self = .code128
        case .ean13: self = .ean13
        case .ean8: self = .ean8
        case .upce: self = .upce
        case .code39: self = .code39
        case .code39Checksum: self = .code39Checksum
        case .code39FullASCII: self = .code39FullASCII
        case .code39FullASCIIChecksum: self = .code39FullASCIIChecksum
        case .dataMatrix: self = .dataMatrix
        case .pdf417: self = .pdf417
        case .aztec: self = .aztec
        default: self = .other(native.rawValue)
        }
    }
    var title: String {
        switch self {
        case .qr: return "QR"
        case .code128: return "Code 128"
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upce: return "UPC-E"
        case .code39: return "Code 39"
        case .code39Checksum: return "Code 39 校验"
        case .code39FullASCII: return "Code 39 ASCII"
        case .code39FullASCIIChecksum: return "Code 39 ASCII 校验"
        case .dataMatrix: return "Data Matrix"
        case .pdf417: return "PDF417"
        case .aztec: return "Aztec"
        case .other(let name): return name
        }
    }
}

struct RecognizedBarcode: Sendable, Equatable, Identifiable {
    let id: UUID
    let symbology: BarcodeSymbology
    let payload: String
    /// Vision normalized bottom-left coordinates, in the oriented current raster.
    /// Missing/invalid geometry does not prevent exact copy in the result browser.
    let quad: RecognizedTextQuad?
    init(id: UUID = UUID(), symbology: BarcodeSymbology, payload: String, quad: RecognizedTextQuad?) {
        self.id = id; self.symbology = symbology; self.payload = payload; self.quad = quad
    }
    var upcaEquivalent: String? {
        guard symbology == .ean13, payload.utf8.count == 13, payload.first == "0",
              payload.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let digits = payload.utf8.map { Int($0 - 48) }
        guard digits.enumerated().reduce(0, { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3) }).isMultiple(of: 10) else { return nil }
        return String(payload.dropFirst())
    }
    var title: String { upcaEquivalent == nil ? symbology.title : "EAN-13（兼容 UPC-A）" }
    var safeURL: URL? { BarcodeURLPolicy.url(for: payload) }
}

enum BarcodeURLPolicy {
    /// Only absolute web URLs without credentials, whitespace or control characters.
    /// Decoder content is never opened during recognition, selection, or copy.
    static func url(for payload: String) -> URL? {
        guard !payload.isEmpty, !payload.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let components = URLComponents(string: payload),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}

struct BarcodeOmissions: Sendable, Equatable {
    var missingText = 0
    var oversizedPayload = 0
    var resultLimit = 0
    var payloadBudget = 0
    var total: Int { missingText + oversizedPayload + resultLimit + payloadBudget }
}

struct RecognizedBarcodeDocument: Sendable, Equatable {
    static let maximumResults = 128
    static let maximumPayloadUTF16 = 4096
    static let maximumTotalUTF16 = 65_536
    static let acceptanceSymbologies: [BarcodeSymbology] = [.qr, .code128, .ean13, .code39, .dataMatrix, .pdf417]
    let results: [RecognizedBarcode]
    let supportedSymbologies: [BarcodeSymbology]
    let omissions: BarcodeOmissions
    var omittedCount: Int { omissions.total }
    var unlocalizedCount: Int { results.filter { $0.quad == nil }.count }
    var unsupportedAcceptanceSymbologies: [BarcodeSymbology] { Self.acceptanceSymbologies.filter { !supportedSymbologies.contains($0) } }

    /// Accept complete strings or omit them with an explicit reason. No deduplication:
    /// two identical values printed in distinct regions must remain independently selectable.
    init(candidates: [RecognizedBarcode], supportedSymbologies: [BarcodeSymbology], missingTextCount: Int = 0) {
        var accepted: [RecognizedBarcode] = [], counts = BarcodeOmissions(missingText: max(0, missingTextCount)), total = 0
        for result in candidates {
            let count = result.payload.utf16.count
            if result.payload.isEmpty { counts.missingText += 1 }
            else if count > Self.maximumPayloadUTF16 { counts.oversizedPayload += 1 }
            else if accepted.count >= Self.maximumResults { counts.resultLimit += 1 }
            else if count > Self.maximumTotalUTF16 - total { counts.payloadBudget += 1 }
            else { accepted.append(result); total += count }
        }
        self.results = accepted
        self.supportedSymbologies = supportedSymbologies
        omissions = counts
    }

    var statusText: String {
        var parts = [results.isEmpty ? "未识别到可复制的码" : "\(results.count) 个码 · 点选列表或图片区域"]
        if omissions.missingText > 0 { parts.append("\(omissions.missingText) 个码没有可用文本（可能是二进制内容），未提供复制") }
        if omissions.oversizedPayload > 0 { parts.append("\(omissions.oversizedPayload) 个码超过单码长度上限") }
        if omissions.resultLimit > 0 { parts.append("\(omissions.resultLimit) 个码超过数量上限") }
        if omissions.payloadBudget > 0 { parts.append("\(omissions.payloadBudget) 个码超过总文本上限") }
        if omittedCount > 0 { parts.append("以上内容已省略；已列出的值均完整，未截短") }
        if unlocalizedCount > 0 { parts.append("\(unlocalizedCount) 个码缺少可靠位置，可在列表中复制") }
        let unsupported = unsupportedAcceptanceSymbologies
        if !unsupported.isEmpty { parts.append("当前 macOS 不支持：" + unsupported.map(\.title).joined(separator: "、")) }
        parts.append("未检出不代表图片没有码；模糊、遮挡或其他格式可能无法识别")
        return parts.joined(separator: "；")
    }

    func result(at point: CGPoint) -> Int? {
        results.indices.filter { results[$0].quad?.contains(point) == true }.min {
            let a = results[$0].quad!.bounds, b = results[$1].quad!.bounds
            return a.width * a.height < b.width * b.height
        }
    }
}
