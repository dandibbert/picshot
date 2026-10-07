import Foundation

/// Integer, half-open source-image coordinates, with the origin at the top left.
public struct RepeatedRegionPixelRect: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum RepeatedRegionBudget: String, Equatable, Sendable {
    case time, comparisons, candidates, scratchMemory
}

public enum RepeatedRegionMatchError: Error, Equatable, LocalizedError, Sendable {
    case invalidRaster, invalidSelection, imageTooLarge, templateTooLarge, lowInformation
    case budgetExceeded(RepeatedRegionBudget)
    case cancelled, busy

    public var errorDescription: String? {
        switch self {
        case .invalidRaster: return "无法读取这张图片的像素。"
        case .invalidSelection: return "请在原图内框选至少 3 × 3 像素的区域。"
        case .imageTooLarge: return "自动马赛克支持最多 2000 万像素、单边不超过 8192 像素的图片。请先裁剪。"
        case .templateTooLarge: return "请框选更小的内容：区域单边不能超过 512 像素。"
        case .lowInformation: return "选区内容太少或过于单一，请包含完整的文字或图案。"
        case .budgetExceeded(.time): return "查找已达到时间上限，请裁剪图片或选择更有辨识度的内容。"
        case .budgetExceeded(.comparisons), .budgetExceeded(.candidates):
            return "相似位置太多，已停止查找。请选择更有辨识度的内容。"
        case .budgetExceeded(.scratchMemory): return "图片超出自动马赛克的工作内存上限，请先裁剪。"
        case .cancelled: return "已取消查找。"
        case .busy: return "另一个自动马赛克查找仍在运行，请稍后重试。"
        }
    }
}

/// All knobs may lower, but never raise, the production caps.
public struct RepeatedRegionMatchLimits: Sendable {
    public static let maximumDimension = 8_192
    public static let maximumImagePixels = 20_000_000
    public static let maximumTemplateDimension = 512
    public static let maximumTemplatePixels = 262_144
    public static let maximumScratchBytes = 96 * 1_024 * 1_024
    public let maxImagePixels: Int
    public let maxTemplatePixels: Int
    public let maxScratchBytes: Int
    public let maxPixelComparisons: Int
    public let maxRawCandidates: Int
    public let maxResults: Int
    public let timeLimit: TimeInterval

    public init(maxImagePixels: Int = 20_000_000, maxTemplatePixels: Int = 262_144,
                maxScratchBytes: Int = 96 * 1_024 * 1_024, maxPixelComparisons: Int = 384_000_000,
                maxRawCandidates: Int = 512, maxResults: Int = 24, timeLimit: TimeInterval = 8) {
        self.maxImagePixels = min(Self.maximumImagePixels, max(0, maxImagePixels))
        self.maxTemplatePixels = min(Self.maximumTemplatePixels, max(0, maxTemplatePixels))
        self.maxScratchBytes = min(Self.maximumScratchBytes, max(0, maxScratchBytes))
        self.maxPixelComparisons = min(384_000_000, max(0, maxPixelComparisons))
        self.maxRawCandidates = min(512, max(0, maxRawCandidates))
        self.maxResults = min(24, max(1, maxResults))
        self.timeLimit = timeLimit.isFinite ? min(8, max(0, timeLimit)) : 8
    }

    /// Check before allocating or drawing a canonical full-resolution raster.
    public func validate(width: Int, height: Int, seed: RepeatedRegionPixelRect) throws {
        guard width > 0, height > 0 else { throw RepeatedRegionMatchError.invalidRaster }
        guard width <= Self.maximumDimension, height <= Self.maximumDimension,
              width * height <= maxImagePixels else { throw RepeatedRegionMatchError.imageTooLarge }
        // Subtraction avoids overflow from attacker-controlled x + width values.
        guard seed.x >= 0, seed.y >= 0, seed.width >= 3, seed.height >= 3,
              seed.width <= width, seed.height <= height,
              seed.x <= width - seed.width, seed.y <= height - seed.height else {
            throw RepeatedRegionMatchError.invalidSelection
        }
        guard seed.width <= Self.maximumTemplateDimension, seed.height <= Self.maximumTemplateDimension,
              seed.width * seed.height <= maxTemplatePixels else { throw RepeatedRegionMatchError.templateTooLarge }
        // One RGBA image, one RGBA template, one byte/pixel edge mask, a 65,536-bin
        // UInt32 histogram, plus <=1 MiB for tiles, candidates and bounded metadata.
        let scratch = width * height * 4 + seed.width * seed.height * 5 + 65_536 * 4 + 1_048_576
        guard scratch <= maxScratchBytes else { throw RepeatedRegionMatchError.budgetExceeded(.scratchMemory) }
    }
}

/// Immutable, tightly packed, top-left row-major, premultiplied sRGB RGBA8.
/// Hidden RGB in a fully transparent pixel is ignored. The matcher does not
/// resample, mutate, upload, or retain the screenshot after returning.
public struct RepeatedRegionRaster: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard width > 0, height > 0,
              width <= RepeatedRegionMatchLimits.maximumDimension,
              height <= RepeatedRegionMatchLimits.maximumDimension,
              width * height <= RepeatedRegionMatchLimits.maximumImagePixels else {
            throw RepeatedRegionMatchError.imageTooLarge
        }
        guard rgba.count == width * height * 4 else { throw RepeatedRegionMatchError.invalidRaster }
        self.width = width; self.height = height; self.rgba = rgba
    }
}

public struct RepeatedRegionCandidate: Equatable, Sendable {
    public let rect: RepeatedRegionPixelRect
    /// A deterministic pixel-similarity score, not a calibrated probability.
    public let confidence: Double
    public init(rect: RepeatedRegionPixelRect, confidence: Double) {
        self.rect = rect; self.confidence = confidence
    }
}

public struct RepeatedRegionMatchResult: Equatable, Sendable {
    public let seed: RepeatedRegionPixelRect
    public let candidates: [RepeatedRegionCandidate]
    public let examinedOrigins: Int
    /// Search completed, but more non-overlapping matches exist than the UI cap.
    public let truncated: Bool

    public init(seed: RepeatedRegionPixelRect, candidates: [RepeatedRegionCandidate], examinedOrigins: Int, truncated: Bool) {
        self.seed = seed; self.candidates = candidates; self.examinedOrigins = examinedOrigins; self.truncated = truncated
    }
}

/// Same-size, integer-translation matching only. Every possible origin is
/// visited; discriminative anchors filter cheaply, without downsample-grid gaps.
/// Every accepted candidate is verified at every source pixel and in local tiles.
public enum RepeatedRegionMatcher {
    public static func findMatches(in raster: RepeatedRegionRaster, seed: RepeatedRegionPixelRect,
                                   limits: RepeatedRegionMatchLimits = .init(),
                                   isCancelled: @escaping () -> Bool = { Task.isCancelled },
                                   now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> RepeatedRegionMatchResult {
        try findMatches(in: raster, seed: seed, limits: limits, isCancelled: isCancelled, now: now, phaseChanged: { _ in })
    }

    // Internal deterministic cancellation seam. No timing sleeps are needed to
    // cover cancellation during preparation, origin scanning or full verification.
    enum Phase: Equatable { case preparing, scanning, verifying }
    static func findMatches(in raster: RepeatedRegionRaster, seed: RepeatedRegionPixelRect,
                            limits: RepeatedRegionMatchLimits = .init(),
                            isCancelled: @escaping () -> Bool = { Task.isCancelled },
                            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            phaseChanged: (Phase) -> Void) throws -> RepeatedRegionMatchResult {
        try limits.validate(width: raster.width, height: raster.height, seed: seed)
        var budget = Budget(limits: limits, started: now(), isCancelled: isCancelled, now: now)
        phaseChanged(.preparing)
        try budget.checkpoint()
        let template = try Template(raster: raster, rect: seed, budget: &budget)
        var raw: [RepeatedRegionCandidate] = []
        raw.reserveCapacity(min(64, limits.maxRawCandidates))
        var examined = 0
        phaseChanged(.scanning)
        try budget.checkpoint()
        for y in 0...(raster.height - seed.height) {
            for x in 0...(raster.width - seed.width) {
                examined += 1
                try budget.consume(template.anchors.count)
                if x == seed.x && y == seed.y { continue }
                let offset = (y * raster.width + x) * 4
                var passes = true
                for anchor in template.anchors {
                    let source = offset + (anchor.y * raster.width + anchor.x) * 4
                    if difference(raster.rgba, source, template.pixels, anchor.pixel).maximum > 48 {
                        passes = false; break
                    }
                }
                guard passes else { continue }
                phaseChanged(.verifying)
                try budget.checkpoint()
                if let confidence = try verify(raster, x: x, y: y, template: template, budget: &budget) {
                    guard raw.count < limits.maxRawCandidates else {
                        throw RepeatedRegionMatchError.budgetExceeded(.candidates)
                    }
                    raw.append(.init(rect: .init(x: x, y: y, width: seed.width, height: seed.height), confidence: confidence))
                }
                phaseChanged(.scanning)
            }
        }
        try budget.checkpoint()
        // Favor the most accurate location before suppressing nearby translations.
        // Coordinates break exact ties, so repeated runs never shuffle the review.
        raw.sort { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : precedes($0.rect, $1.rect) }
        var kept: [RepeatedRegionCandidate] = []
        for candidate in raw {
            try budget.consume(kept.count + 1)
            guard !overlapsDuplicate(candidate.rect, seed),
                  !kept.contains(where: { overlapsDuplicate(candidate.rect, $0.rect) }) else { continue }
            kept.append(candidate)
        }
        kept.sort { precedes($0.rect, $1.rect) }
        try budget.checkpoint()
        return .init(seed: seed, candidates: Array(kept.prefix(limits.maxResults)), examinedOrigins: examined,
                     truncated: kept.count > limits.maxResults)
    }

    private static func precedes(_ a: RepeatedRegionPixelRect, _ b: RepeatedRegionPixelRect) -> Bool {
        a.y != b.y ? a.y < b.y : a.x < b.x
    }

    private static func overlapsDuplicate(_ a: RepeatedRegionPixelRect, _ b: RepeatedRegionPixelRect) -> Bool {
        let w = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let h = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let intersection = w * h
        // IoU > 0.30; integer arithmetic makes ties deterministic.
        return intersection * 10 > (a.width * a.height + b.width * b.height - intersection) * 3
    }

    @inline(__always)
    private static func difference(_ a: [UInt8], _ i: Int, _ b: [UInt8], _ j: Int) -> (maximum: Int, alpha: Int) {
        let aa = Int(a[i + 3]), ba = Int(b[j + 3])
        let alpha = abs(aa - ba)
        var maximum = alpha
        for channel in 0..<3 {
            let av = aa == 0 ? 0 : Int(a[i + channel])
            let bv = ba == 0 ? 0 : Int(b[j + channel])
            maximum = max(maximum, abs(av - bv))
        }
        return (maximum, alpha)
    }

    private struct Anchor {
        let x: Int; let y: Int; let pixel: Int; let rarity: UInt32; let strength: Int
    }

    private struct Template {
        let width: Int; let height: Int
        var pixels: [UInt8]
        var edges: [UInt8]
        var anchors: [Anchor]
        var edgeCount: Int

        init(raster: RepeatedRegionRaster, rect: RepeatedRegionPixelRect, budget: inout Budget) throws {
            width = rect.width; height = rect.height
            pixels = [UInt8](repeating: 0, count: width * height * 4)
            edges = [UInt8](repeating: 0, count: width * height)
            anchors = []; edgeCount = 0
            var histogram = [UInt32](repeating: 0, count: 65_536)
            var minimum = [Int](repeating: 255, count: 4), maximum = [Int](repeating: 0, count: 4)
            for y in 0..<height {
                try budget.consume(width)
                for x in 0..<width {
                    let source = ((rect.y + y) * raster.width + rect.x + x) * 4, target = (y * width + x) * 4
                    for c in 0..<4 {
                        let value = c < 3 && raster.rgba[source + 3] == 0 ? 0 : Int(raster.rgba[source + c])
                        pixels[target + c] = UInt8(value)
                        minimum[c] = min(minimum[c], value); maximum[c] = max(maximum[c], value)
                    }
                    histogram[Self.bin(pixels, target)] += 1
                }
            }
            // Analyze every template pixel, including odd-coordinate single-pixel
            // strokes. Keep one informative pixel per 4x4 spatial cell.
            var cells = [Anchor?](repeating: nil, count: 16)
            for y in 0..<height {
                try budget.consume(width * 4)
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    var strength = 0
                    if x > 0 { strength = max(strength, RepeatedRegionMatcher.difference(pixels, i, pixels, i - 4).maximum) }
                    if x + 1 < width { strength = max(strength, RepeatedRegionMatcher.difference(pixels, i, pixels, i + 4).maximum) }
                    if y > 0 { strength = max(strength, RepeatedRegionMatcher.difference(pixels, i, pixels, i - width * 4).maximum) }
                    if y + 1 < height { strength = max(strength, RepeatedRegionMatcher.difference(pixels, i, pixels, i + width * 4).maximum) }
                    guard strength >= 16 else { continue }
                    edges[y * width + x] = 1; edgeCount += 1
                    let anchor = Anchor(x: x, y: y, pixel: i, rarity: histogram[Self.bin(pixels, i)], strength: strength)
                    let cell = min(3, y * 4 / height) * 4 + min(3, x * 4 / width)
                    if let old = cells[cell] {
                        if anchor.rarity < old.rarity || (anchor.rarity == old.rarity && anchor.strength > old.strength) { cells[cell] = anchor }
                    } else { cells[cell] = anchor }
                }
            }
            guard edgeCount >= 8, zip(maximum, minimum).contains(where: { $0.0 - $0.1 >= 24 }) else {
                throw RepeatedRegionMatchError.lowInformation
            }
            anchors = cells.compactMap { $0 }.sorted {
                if $0.rarity != $1.rarity { return $0.rarity < $1.rarity }
                if $0.strength != $1.strength { return $0.strength > $1.strength }
                return $0.pixel < $1.pixel
            }
        }

        private static func bin(_ pixels: [UInt8], _ i: Int) -> Int {
            (Int(pixels[i] >> 4) << 12) | (Int(pixels[i + 1] >> 4) << 8) |
                (Int(pixels[i + 2] >> 4) << 4) | Int(pixels[i + 3] >> 4)
        }
    }

    private static func verify(_ raster: RepeatedRegionRaster, x: Int, y: Int,
                               template: Template, budget: inout Budget) throws -> Double? {
        var sum = 0, edgeSum = 0, worst = 0
        var maximumTileMean = 0.0
        // Tile checks prevent a small changed glyph from disappearing into the
        // average error of a large, mostly blank selection.
        for ty in stride(from: 0, to: template.height, by: 8) {
            for tx in stride(from: 0, to: template.width, by: 8) {
                var tileSum = 0, tileCount = 0
                for sy in ty..<min(ty + 8, template.height) {
                    try budget.consume(min(8, template.width - tx))
                    for sx in tx..<min(tx + 8, template.width) {
                        let i = ((y + sy) * raster.width + x + sx) * 4
                        let index = sy * template.width + sx
                        let error = difference(raster.rgba, i, template.pixels, index * 4)
                        guard error.maximum <= 48, error.alpha <= 16 else { return nil }
                        sum += error.maximum; tileSum += error.maximum; tileCount += 1
                        worst = max(worst, error.maximum)
                        if template.edges[index] != 0 { edgeSum += error.maximum }
                    }
                }
                guard tileSum <= tileCount * 8 else { return nil }
                maximumTileMean = max(maximumTileMean, Double(tileSum) / Double(tileCount))
            }
        }
        let area = template.width * template.height
        guard sum <= area * 4, edgeSum <= template.edgeCount * 6 else { return nil }
        let mean = Double(sum) / Double(area), edgeMean = Double(edgeSum) / Double(template.edgeCount)
        return max(0, min(1, 1 - 0.08 * (mean / 4 + edgeMean / 6 + maximumTileMean / 8 + Double(worst) / 48)))
    }

    private struct Budget {
        let limits: RepeatedRegionMatchLimits
        let started: TimeInterval
        let isCancelled: () -> Bool
        let now: () -> TimeInterval
        var spent = 0
        var nextCheck = 0

        mutating func consume(_ amount: Int) throws {
            guard amount <= limits.maxPixelComparisons - spent else {
                throw RepeatedRegionMatchError.budgetExceeded(.comparisons)
            }
            spent += amount
            if spent >= nextCheck { try checkpoint(); nextCheck = spent + 1_024 }
        }
        func checkpoint() throws {
            if isCancelled() { throw RepeatedRegionMatchError.cancelled }
            if now() - started >= limits.timeLimit { throw RepeatedRegionMatchError.budgetExceeded(.time) }
        }
    }
}
