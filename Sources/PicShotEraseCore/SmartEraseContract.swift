import Foundation

public enum SmartEraseLimits {
    public static let dimension = 8_192
    public static let pixels = 16_000_000
    public static let imageBytes = 80_000_000
    #if arch(x86_64)
    public static let seconds: TimeInterval = 300
    public static let runtimeNotice = "Intel CPU 修复可能需要几分钟，可随时取消；本次任务最长 300 秒。"
    #else
    public static let seconds: TimeInterval = 150
    public static let runtimeNotice = "可随时取消；本次任务最长 150 秒。"
    #endif
    public static let residentBytes: UInt64 = 2_147_483_648
    public static let modelSide = 800
    public static let strokes = 512
    public static let points = 32_768
    public static let rasterVisits = 128_000_000
}

public enum SmartEraseError: LocalizedError {
    case invalidInput, emptyMask, tooMuchMask, invalidModel, invalidOutput, busy, unavailable, signature, timeout, memory, failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "图片或笔刷数据无效；最多 1600 万像素，单边最多 8192 像素。"
        case .emptyMask: return "请先涂抹要移除的物体。"
        case .tooMuchMask: return "涂抹范围太大；请保留至少 10% 的画面作为修复参考。"
        case .invalidModel: return "消除模型的校验或输入格式不符，请重新下载模型。"
        case .invalidOutput: return "模型未返回有效修复图像，原图没有改变。"
        case .busy: return "另一个智能消除任务尚未结束，请稍后再试。"
        case .unavailable: return "安装包缺少原生消除辅助程序，请安装完整应用。"
        case .signature: return "消除辅助程序签名或路径不符，已阻止启动。"
        case .timeout: return "本次消除超过 \(Int(SmartEraseLimits.seconds)) 秒限制，已停止。请缩小图片后再试。"
        case .memory: return "消除进程超过 2 GiB 内存限制，已停止。"
        case .failed(let message): return "智能消除失败：\(message)"
        }
    }
}

public struct SmartErasePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Image-pixel coordinates, origin at the top left. Width is a diameter.
public struct SmartEraseStroke: Equatable, Sendable {
    public var points: [SmartErasePoint]
    public let width: Double
    public init(points: [SmartErasePoint], width: Double) { self.points = points; self.width = width }
}

public struct SmartEraseCrop: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let side: Int
    public init(x: Int, y: Int, side: Int) { self.x = x; self.y = y; self.side = side }
}

public enum SmartEraseMask {
    public static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= SmartEraseLimits.dimension, height <= SmartEraseLimits.dimension,
              width * height <= SmartEraseLimits.pixels else { throw SmartEraseError.invalidInput }
    }

    /// Rasterize capsules instead of only dab points, so quick mouse movements
    /// never leave gaps. No full-image undo snapshots are retained.
    public static func rasterize(width: Int, height: Int, strokes: [SmartEraseStroke]) throws -> Data {
        try validateDimensions(width: width, height: height)
        guard strokes.count <= SmartEraseLimits.strokes,
              strokes.reduce(0, { $0 + $1.points.count }) <= SmartEraseLimits.points else { throw SmartEraseError.invalidInput }
        var pixels = [UInt8](repeating: 0, count: width * height)
        var visits = 0
        for stroke in strokes {
            guard stroke.width.isFinite, stroke.width >= 1, stroke.width <= 512, !stroke.points.isEmpty,
                  stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 && $0.x <= Double(width) && $0.y <= Double(height) }) else { throw SmartEraseError.invalidInput }
            let radius = stroke.width / 2
            for index in stroke.points.indices {
                try Task.checkCancellation()
                let a = stroke.points[max(0, index - 1)], b = stroke.points[index]
                let left = max(0, Int(floor(min(a.x, b.x) - radius)))
                let right = min(width - 1, Int(ceil(max(a.x, b.x) + radius)))
                let top = max(0, Int(floor(min(a.y, b.y) - radius)))
                let bottom = min(height - 1, Int(ceil(max(a.y, b.y) + radius)))
                guard left <= right, top <= bottom else { continue }
                visits += (right - left + 1) * (bottom - top + 1)
                guard visits <= SmartEraseLimits.rasterVisits else { throw SmartEraseError.invalidInput }
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                for y in top...bottom {
                    for x in left...right {
                        let px = Double(x) + 0.5, py = Double(y) + 0.5
                        let t = length > 0 ? max(0, min(1, ((px - a.x) * dx + (py - a.y) * dy) / length)) : 0
                        let ex = px - a.x - t * dx, ey = py - a.y - t * dy
                        if ex * ex + ey * ey <= radius * radius { pixels[y * width + x] = 255 }
                    }
                }
            }
        }
        return Data(pixels)
    }

    public static func crop(width: Int, height: Int, mask: Data) throws -> SmartEraseCrop {
        try validateDimensions(width: width, height: height)
        guard mask.count == width * height else { throw SmartEraseError.invalidInput }
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        for (index, value) in mask.enumerated() where value > 0 {
            guard value == 255 else { throw SmartEraseError.invalidInput }
            let x = index % width, y = index / width
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y); count += 1
        }
        guard count > 0 else { throw SmartEraseError.emptyMask }
        guard count * 10 <= width * height * 9 else { throw SmartEraseError.tooMuchMask }
        let side = min(max(width, height), max(512, max(maxX - minX + 1, maxY - minY + 1) + 128))
        let x = max(0, min(width - side, (minX + maxX + 1 - side) / 2))
        let y = max(0, min(height - side, (minY + maxY + 1 - side) / 2))
        return SmartEraseCrop(x: x, y: y, side: side)
    }

    /// Max-pool into model cells. A thin source stroke survives downsampling.
    public static func modelMask(width: Int, height: Int, mask: Data, crop: SmartEraseCrop) throws -> [UInt8] {
        try validateDimensions(width: width, height: height)
        guard mask.count == width * height, crop.side > 0 else { throw SmartEraseError.invalidInput }
        let side = SmartEraseLimits.modelSide
        var result = [UInt8](repeating: 0, count: side * side)
        for (index, value) in mask.enumerated() where value > 0 {
            let x = index % width - crop.x, y = index / width - crop.y
            guard x >= 0, y >= 0, x < crop.side, y < crop.side else { throw SmartEraseError.invalidInput }
            let x0 = max(0, min(side - 1, x * side / crop.side))
            let x1 = max(x0, min(side - 1, ((x + 1) * side - 1) / crop.side))
            let y0 = max(0, min(side - 1, y * side / crop.side))
            let y1 = max(y0, min(side - 1, ((y + 1) * side - 1) / crop.side))
            for my in y0...y1 { for mx in x0...x1 { result[my * side + mx] = 255 } }
        }
        // Image resizing is bilinear: mask every source tap that can influence
        // a model pixel, including edge-replicated padding. Otherwise fragments
        // of the marked object leak back into the model's supposedly valid
        // context when scaling up or padding a non-square image.
        let scale = Double(crop.side) / Double(side)
        for y in 0..<side {
            let sy = max(0, min(Double(height - 1), Double(crop.y) + (Double(y) + 0.5) * scale - 0.5))
            let y0 = Int(sy), y1 = min(height - 1, Int(sy) + 1)
            for x in 0..<side {
                let sx = max(0, min(Double(width - 1), Double(crop.x) + (Double(x) + 0.5) * scale - 0.5))
                let x0 = Int(sx), x1 = min(width - 1, Int(sx) + 1)
                if mask[y0 * width + x0] > 0 || mask[y0 * width + x1] > 0 || mask[y1 * width + x0] > 0 || mask[y1 * width + x1] > 0 {
                    result[y * side + x] = 255
                }
            }
        }
        return result
    }
}
