import Foundation
import PicShotCore

/// Pixel coordinates in the original, upright table crop; origin is top left.
public struct TableOCRBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0 &&
        (x + width).isFinite && (y + height).isFinite && (width * height).isFinite
    }
    var area: Double { width * height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    func intersectionArea(_ other: Self) -> Double {
        max(0, min(x + width, other.x + other.width) - max(x, other.x)) *
        max(0, min(y + height, other.y + other.height) - max(y, other.y))
    }
    func iou(_ other: Self) -> Double {
        let intersection = intersectionArea(other)
        return intersection / max(Double.leastNormalMagnitude, area + other.area - intersection)
    }
    func distance(_ other: Self) -> Double {
        let topLeft = abs(x - other.x) + abs(y - other.y)
        let bottomRight = abs(x + width - other.x - other.width) + abs(y + height - other.y - other.height)
        return topLeft + bottomRight + min(topLeft, bottomRight)
    }
}

public struct TableOCRObservation: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var box: TableOCRBox
    public init(text: String, confidence: Double, box: TableOCRBox) {
        self.text = text; self.confidence = confidence; self.box = box
    }
}

public struct RecognizedTableCell: Codable, Equatable, Sendable {
    public var coordinate: TableCoordinate
    public var box: TableOCRBox
    public var structureConfidence: Double
    public var ocrConfidence: Double?
}

public struct TableRecognitionResult: Codable, Equatable, Sendable {
    public var table: StructuredTable
    public var structureConfidence: Double
    public var cells: [RecognizedTableCell]
    /// OCR with uncertain geometry, confidence, or cell assignment is retained, never dropped silently.
    public var unmatchedOCR: [TableOCRObservation]
    public var warnings: [String]
}

public enum TableRecognitionError: Error, LocalizedError, Equatable {
    case invalidImage
    case invalidTensor(String)
    case incompleteSequence
    case unsupportedStructure(String)
    case lowConfidence(Double)
    case invalidCellGeometry
    case noRecognizedText
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "表格图像无效或尺寸过大。"
        case .invalidTensor(let reason): return "表格模型输出不兼容：\(reason)"
        case .incompleteSequence: return "表格结构超出模型长度限制或未完整识别，请缩小截图范围。"
        case .unsupportedStructure(let reason): return "无法可靠还原表格结构：\(reason)"
        case .lowConfidence: return "表格结构识别置信度过低，请使用更清晰、完整的表格截图。"
        case .invalidCellGeometry: return "表格模型没有返回有效单元格位置，请重试或手动编辑。"
        case .noRecognizedText: return "未能识别表格中的文字，请使用更清晰的截图。"
        }
    }
}

public struct SLANetInput: Sendable {
    public let values: [Float]
    public let shape: [Int64]
    public let originalWidth: Int
    public let originalHeight: Int
    public let resizedWidth: Int
    public let resizedHeight: Int
}
