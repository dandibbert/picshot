import Foundation

/// Bounds are shared by the UI, isolated renderer and build-time fixture tests.
public enum FormulaRenderLimits {
    public static let latexBytes = 8_192
    public static let svgBytes = 2_097_152
    public static let mathMLBytes = 262_144
    public static let resultBytes = 24 * 1_024 * 1_024
    public static let drawingItems = 8_192
    public static let pathSegments = 200_000
    public static let dimension = 4_096
    public static let pixels = 4_194_304
    public static let seconds = 10.0
    public static let residentBytes: UInt64 = 268_435_456
}

public enum FormulaRenderError: Error, LocalizedError {
    case invalidInput, unsupported(String), invalidOutput, missingRuntime, syntax
    case busy, timeLimit, memoryLimit, helperUnavailable, signature
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "公式为空、过长或字号超出范围（12–96）。"
        case .unsupported(let detail): return "此公式暂不支持本机预览：\(detail)"
        case .invalidOutput: return "公式渲染结果无效或超过尺寸限制。请缩小公式或字号。"
        case .missingRuntime: return "安装包缺少已校验的公式渲染资源，请重新安装完整版本。"
        case .syntax: return "LaTeX 语法无效或包含未支持的命令。请核对括号、命令及环境。"
        case .busy: return "已有公式正在渲染，请稍后再试。"
        case .timeLimit: return "公式渲染超过 10 秒，已停止。请简化公式。"
        case .memoryLimit: return "公式渲染超过 256 MiB 内存限制，已停止。"
        case .helperUnavailable: return "安装包缺少公式渲染辅助程序，请重新安装完整版本。"
        case .signature: return "公式渲染辅助程序或资源签名无效，已阻止启动。"
        }
    }
}

public struct FormulaRenderRequest: Codable, Equatable, Sendable {
    public let latex: String
    public let fontSize: Double
    public let scale: Int
    public let transparent: Bool
    public init(latex: String, fontSize: Double = 24, scale: Int = 2, transparent: Bool = false) {
        self.latex = latex; self.fontSize = fontSize; self.scale = scale; self.transparent = transparent
    }
    public func validate() throws {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              latex.utf8.count <= FormulaRenderLimits.latexBytes,
              !latex.unicodeScalars.contains(where: { $0.value == 0 }),
              fontSize.isFinite, (12...96).contains(fontSize), (1...3).contains(scale) else {
            throw FormulaRenderError.invalidInput
        }
    }
}

/// All formats describe the same successful render. Editing invalidates the entire result.
public struct FormulaRenderResult: Codable, Sendable {
    public let latex: String
    public let svg: String
    public let mathML: String
    public let png: Data
    public let pdf: Data
    public let width: Int
    public let height: Int
    public let pointWidth: Double
    public let pointHeight: Double

    public init(latex: String, svg: String, mathML: String, png: Data, pdf: Data,
                width: Int, height: Int, pointWidth: Double, pointHeight: Double) {
        self.latex = latex; self.svg = svg; self.mathML = mathML; self.png = png; self.pdf = pdf
        self.width = width; self.height = height; self.pointWidth = pointWidth; self.pointHeight = pointHeight
    }

    public func validate(for request: FormulaRenderRequest) throws {
        try request.validate()
        guard latex == request.latex, !svg.isEmpty, svg.utf8.count <= FormulaRenderLimits.svgBytes,
              !mathML.isEmpty, mathML.utf8.count <= FormulaRenderLimits.mathMLBytes,
              svg.hasPrefix("<svg "), mathML.hasPrefix("<math "),
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), pdf.starts(with: Array("%PDF-".utf8)),
              png.count <= FormulaRenderLimits.resultBytes, pdf.count <= FormulaRenderLimits.resultBytes,
              png.count + pdf.count + svg.utf8.count + mathML.utf8.count + latex.utf8.count <= FormulaRenderLimits.resultBytes,
              width > 0, height > 0, width <= FormulaRenderLimits.dimension, height <= FormulaRenderLimits.dimension,
              width <= FormulaRenderLimits.pixels / height,
              pointWidth.isFinite, pointHeight.isFinite, pointWidth > 0, pointHeight > 0,
              pointWidth <= Double(FormulaRenderLimits.dimension), pointHeight <= Double(FormulaRenderLimits.dimension),
              width == Int(ceil(pointWidth * Double(request.scale))),
              height == Int(ceil(pointHeight * Double(request.scale))) else { throw FormulaRenderError.invalidOutput }
    }
}

public enum FormulaRenderFormat: String, CaseIterable, Identifiable, Sendable {
    case latex, mathML, svg, png, pdf
    public var id: String { rawValue }
    public var label: String {
        switch self { case .latex: return "LaTeX"; case .mathML: return "MathML"; case .svg: return "SVG"; case .png: return "PNG"; case .pdf: return "PDF" }
    }
    public var fileExtension: String { self == .latex ? "tex" : self == .mathML ? "mml" : rawValue }
    public func data(from result: FormulaRenderResult) -> Data {
        switch self {
        case .latex: return Data(result.latex.utf8)
        case .mathML: return Data(result.mathML.utf8)
        case .svg: return Data(result.svg.utf8)
        case .png: return result.png
        case .pdf: return result.pdf
        }
    }
}

/// Deliberately no Office OMML, Typst or AsciiMath conversion claims.
public enum FormulaRenderCapabilities {
    public static let available = FormulaRenderFormat.allCases
    public static let unavailable = ["Office OMML", "Typst", "AsciiMath"]
}
