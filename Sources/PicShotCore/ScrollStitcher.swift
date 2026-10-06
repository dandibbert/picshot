import Foundation

/// Screen coordinates: positive vertical motion reveals content below; horizontal reveals right.
public enum ScrollAxis: String, CaseIterable, Sendable {
    case vertical, horizontal
}

public enum ScrollStitchError: Error, LocalizedError, Equatable {
    case invalidPixels, differentDimensions, duplicate, insufficientTexture, ambiguousOverlap, noOverlap, pixelLimit

    public var errorDescription: String? {
        switch self {
        case .invalidPixels: return "The image pixels are invalid or the frame is too large."
        case .differentDimensions: return "Every frame must have the same pixel dimensions."
        case .duplicate: return "This frame is unchanged. Scroll a little farther and capture again."
        case .insufficientTexture: return "There is too little detail to match this area safely. Include more text or image detail."
        case .ambiguousOverlap: return "The overlap repeats or has more than one possible match. Scroll a smaller distance or choose a more distinctive area."
        case .noOverlap: return "No reliable overlap was found. Return toward the previous position and leave at least 25% of the last frame visible."
        case .pixelLimit: return "This capture reached its pixel limit. Finish this image and start another."
        }
    }
}

/// A platform-independent, tightly packed luminance image. The stitcher never retains RGBA frames.
public struct ScrollFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public static let maximumPixels = 24_000_000
    public static let maximumDimension = 32_768

    public init(width: Int, height: Int, grayscale: [UInt8]) throws {
        guard width > 0, height > 0, width <= Self.maximumDimension, height <= Self.maximumDimension,
              width <= Self.maximumPixels / height,
              grayscale.count == width * height else { throw ScrollStitchError.invalidPixels }
        self.width = width
        self.height = height
        pixels = grayscale
    }

    /// RGBA byte order, with optional row padding; alpha is composited on white.
    public init(width: Int, height: Int, rgba: [UInt8], bytesPerRow: Int? = nil) throws {
        guard width > 0, height > 0, width <= Self.maximumDimension, height <= Self.maximumDimension,
              width <= Self.maximumPixels / height,
              width <= Int.max / 4 else { throw ScrollStitchError.invalidPixels }
        let stride = bytesPerRow ?? width * 4
        guard stride >= width * 4, stride <= Int.max / height,
              rgba.count >= stride * height else { throw ScrollStitchError.invalidPixels }
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * stride + x * 4
                let luminance = (77 * Int(rgba[p]) + 150 * Int(rgba[p + 1]) + 29 * Int(rgba[p + 2])) >> 8
                let alpha = Int(rgba[p + 3])
                gray[y * width + x] = UInt8((luminance * alpha + 255 * (255 - alpha) + 127) / 255)
            }
        }
        try self.init(width: width, height: height, grayscale: gray)
    }
}

/// Measured luminance agreement for a verified overlap. Error values are in 0...255.
/// `uniquenessMargin` is the mean-error gap to the next viable signed translation,
/// capped at 255 when there is no competitor. It is nil for a supplied alignment.
/// `worstBandError` includes both axes and local tiles, not just whole-image error.
public struct ScrollMatchEvidence: Sendable, Equatable {
    public let meanError: Double
    public let badFraction: Double
    public let worstBandError: Double
    public let texture: Double
    public let uniquenessMargin: Double?
}

public struct ScrollPlacement: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let advance: Int
    public let overlap: Int
    public let confidence: Double
    /// Present for the conservative bidirectional matcher; legacy forward placements
    /// and the initial frame have no independently verified bidirectional evidence.
    public let evidence: ScrollMatchEvidence?

    public init(x: Int, y: Int, advance: Int, overlap: Int, confidence: Double,
                evidence: ScrollMatchEvidence? = nil) {
        self.x = x
        self.y = y
        self.advance = advance
        self.overlap = overlap
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// Conservative translation matching. Frames with uncertain alignment are rejected; they
/// are never blindly concatenated. Only the last luminance frame stays in memory.
public struct ScrollStitcher: Sendable {
    public struct Configuration: Sendable {
        public var minimumOverlapFraction: Double = 0.25
        public var maximumMeanError: Double = 7.0
        public var minimumTextureDeviation: Double = 9.0
        public var minimumUniquenessMargin: Double = 3.0
        public var maximumOutputPixels: Int = 60_000_000
        public init() {}
    }

    public let axis: ScrollAxis
    public let configuration: Configuration
    public private(set) var outputWidth = 0
    public private(set) var outputHeight = 0
    public private(set) var frameCount = 0
    private var previous: ScrollFrame?
    private var offset = 0

    public init(axis: ScrollAxis = .vertical, configuration: Configuration = Configuration()) {
        self.axis = axis
        self.configuration = configuration
    }

    /// On error the session is unchanged, so the user can retry from the last accepted frame.
    @discardableResult
    public mutating func append(_ frame: ScrollFrame) throws -> ScrollPlacement {
        guard let old = previous else {
            try checkPixelLimit(width: frame.width, height: frame.height)
            outputWidth = frame.width
            outputHeight = frame.height
            previous = frame
            frameCount = 1
            return ScrollPlacement(x: 0, y: 0, advance: 0,
                                   overlap: axis == .vertical ? frame.height : frame.width, confidence: 1)
        }
        guard old.width == frame.width, old.height == frame.height else {
            throw ScrollStitchError.differentDimensions
        }
        let match = try Self.match(previous: old, next: frame, axis: axis, configuration: configuration)
        let addition = offset.addingReportingOverflow(match.advance)
        guard !addition.overflow else { throw ScrollStitchError.pixelLimit }
        let length = axis == .vertical ? frame.height : frame.width
        let total = addition.partialValue.addingReportingOverflow(length)
        guard !total.overflow else { throw ScrollStitchError.pixelLimit }
        let width = axis == .vertical ? frame.width : total.partialValue
        let height = axis == .vertical ? total.partialValue : frame.height
        try checkPixelLimit(width: width, height: height)
        offset = addition.partialValue
        outputWidth = width
        outputHeight = height
        previous = frame
        frameCount += 1
        return ScrollPlacement(x: axis == .horizontal ? offset : 0,
                               y: axis == .vertical ? offset : 0,
                               advance: match.advance, overlap: match.overlap, confidence: match.confidence)
    }

    public static func match(previous: ScrollFrame, next: ScrollFrame, axis: ScrollAxis,
                             configuration: Configuration = Configuration()) throws -> ScrollPlacement {
        guard previous.width == next.width, previous.height == next.height else {
            throw ScrollStitchError.differentDimensions
        }
        guard configuration.minimumOverlapFraction.isFinite, configuration.maximumMeanError.isFinite,
              configuration.minimumTextureDeviation.isFinite, configuration.minimumUniquenessMargin.isFinite,
              configuration.maximumMeanError > 0, configuration.minimumTextureDeviation > 0,
              configuration.minimumUniquenessMargin > 0 else { throw ScrollStitchError.invalidPixels }
        let length = axis == .vertical ? previous.height : previous.width
        let cross = axis == .vertical ? previous.width : previous.height
        guard length >= 16, cross >= 8 else { throw ScrollStitchError.insufficientTexture }
        let overlapFraction = min(0.8, max(0.2, configuration.minimumOverlapFraction))
        let minimumOverlap = max(12, Int(Double(length) * overlapFraction))
        let maximumAdvance = length - minimumOverlap
        guard maximumAdvance >= 1 else { throw ScrollStitchError.insufficientTexture }
        let zero = measure(previous, next, axis: axis, advance: 0, dense: true)
        if zero.error <= 0.8 { throw ScrollStitchError.duplicate }
        if zero.texture < configuration.minimumTextureDeviation { throw ScrollStitchError.insufficientTexture }

        // Search every integer displacement. Subsampling only pixels (not displacements)
        // preserves one-pixel accuracy, including fine/high-frequency text and screenshots.
        var candidates: [(advance: Int, error: Double)] = []
        candidates.reserveCapacity(maximumAdvance)
        for advance in 1...maximumAdvance {
            let score = measure(previous, next, axis: axis, advance: advance, dense: false)
            candidates.append((advance, score.error))
        }
        candidates.sort { $0.error < $1.error }
        guard let first = candidates.first, first.error <= configuration.maximumMeanError + 3 else {
            throw ScrollStitchError.noOverlap
        }
        // Independently verify the finalists at more pixels. Screening and verification use
        // different sample grids, reducing false matches from repeated lines or sparse detail.
        let finalists = candidates.prefix(12).map { candidate in
            (advance: candidate.advance,
             score: measure(previous, next, axis: axis, advance: candidate.advance, dense: true))
        }.sorted { $0.score.error < $1.score.error }
        guard let best = finalists.first, best.score.error <= configuration.maximumMeanError,
              best.score.badFraction <= 0.15 else { throw ScrollStitchError.noOverlap }
        guard best.score.texture >= configuration.minimumTextureDeviation else {
            throw ScrollStitchError.insufficientTexture
        }
        // Nearby displacements also count as competing matches. Blurry/featureless content
        // whose precise offset is uncertain must not produce an apparently valid long image.
        if let runnerUp = finalists.dropFirst().first,
           runnerUp.score.error - best.score.error < configuration.minimumUniquenessMargin {
            throw ScrollStitchError.ambiguousOverlap
        }
        // A substantial strip of the overlap must agree too, preventing a static sidebar
        // or fixed header from dominating a mostly incorrect match.
        guard best.score.worstBandError <= max(14, configuration.maximumMeanError * 2) else {
            throw ScrollStitchError.noOverlap
        }
        let errorConfidence = max(0, 1 - best.score.error / max(1, configuration.maximumMeanError))
        return ScrollPlacement(x: axis == .horizontal ? best.advance : 0,
                               y: axis == .vertical ? best.advance : 0,
                               advance: best.advance, overlap: length - best.advance,
                               confidence: errorConfidence)
    }

    /// Finds a relative translation in either direction. Positive advances reveal below/right;
    /// negative advances reveal above/left. All signed offsets (including zero) compete in
    /// one search, so a periodic pattern cannot become valid merely by reversing direction.
    /// This intentionally has stricter local-change checks than the legacy forward matcher.
    public static func matchBidirectional(previous: ScrollFrame, next: ScrollFrame, axis: ScrollAxis,
                                          configuration: Configuration = Configuration()) throws -> ScrollPlacement {
        try validateComparison(previous, next, configuration: configuration)
        try Task.checkCancellation()
        let length = axis == .vertical ? previous.height : previous.width
        let cross = axis == .vertical ? previous.width : previous.height
        guard length >= 16, cross >= 8 else { throw ScrollStitchError.insufficientTexture }
        let overlapFraction = min(0.8, max(0.2, configuration.minimumOverlapFraction))
        let minimumOverlap = max(12, Int(Double(length) * overlapFraction))
        let maximumAdvance = length - minimumOverlap
        guard maximumAdvance >= 1 else { throw ScrollStitchError.insufficientTexture }

        // Full-pixel zero-offset verification prevents sparse sampling from declaring a
        // small changing region duplicate, and supplies texture from BOTH input frames.
        guard let zero = try regionScore(previous, next, previousStart: 0, nextStart: 0,
                                     length: length, axis: axis, sampled: false, rejectOutliers: false) else {
            throw ScrollStitchError.noOverlap
        }
        if zero.error <= 0.8, zero.badFraction == 0,
           zero.worstBandError <= maximumBandError(configuration) { throw ScrollStitchError.duplicate }
        guard zero.texture >= configuration.minimumTextureDeviation else {
            throw ScrollStitchError.insufficientTexture
        }

        var screened: [(advance: Int, error: Double)] = []
        // A sample can rule out an offset only by observing an actual >24 outlier.
        // A sampled mean is never used as a rejection threshold: a sparse local detail
        // must not eliminate an otherwise viable competitor and invent uniqueness.
        for advance in (-maximumAdvance)...maximumAdvance where advance != 0 {
            try Task.checkCancellation()
            if let score = try regionScore(previous, next,
                                       previousStart: max(0, advance), nextStart: max(0, -advance),
                                       length: length - abs(advance), axis: axis,
                                       sampled: true, rejectOutliers: true) {
                screened.append((advance, score.error))
            }
        }
        // Bound worst-case verification work for highly repetitive/low-information frames.
        // Too many unexcluded offsets are uncertainty, never permission to pick the first.
        guard screened.count <= 32 else { throw ScrollStitchError.ambiguousOverlap }
        screened.sort { $0.error == $1.error ? $0.advance < $1.advance : $0.error < $1.error }
        var verified: [(advance: Int, score: Score)] = []
        if zero.badFraction == 0 { verified.append((0, zero)) }
        for candidate in screened {
            try Task.checkCancellation()
            let advance = candidate.advance
            if let score = try regionScore(previous, next,
                                       previousStart: max(0, advance), nextStart: max(0, -advance),
                                       length: length - abs(advance), axis: axis,
                                       sampled: false, rejectOutliers: true) {
                verified.append((advance, score))
            }
        }
        verified.sort {
            $0.score.error == $1.score.error ? $0.advance < $1.advance : $0.score.error < $1.score.error
        }
        guard let best = verified.first else { throw ScrollStitchError.noOverlap }
        try requireAgreement(best.score, configuration: configuration)
        guard best.score.texture >= configuration.minimumTextureDeviation else {
            throw ScrollStitchError.insufficientTexture
        }
        let margin = verified.dropFirst().first.map { $0.score.error - best.score.error } ?? 255
        guard margin >= configuration.minimumUniquenessMargin else { throw ScrollStitchError.ambiguousOverlap }
        guard best.advance != 0 else { throw ScrollStitchError.duplicate }
        let evidence = evidence(for: best.score, uniquenessMargin: min(255, margin))
        return ScrollPlacement(x: axis == .horizontal ? best.advance : 0,
                               y: axis == .vertical ? best.advance : 0,
                               advance: best.advance, overlap: length - abs(best.advance),
                               confidence: max(0, 1 - best.score.error / max(1, configuration.maximumMeanError)),
                               evidence: evidence)
    }

    /// Verifies a known world-coordinate alignment without allocating cropped buffers.
    /// Starts/count are along `axis`; the complete cross-axis dimension is compared.
    /// Every pixel is inspected, including one-pixel strips. Texture and uniqueness are
    /// deliberately not prerequisites: the caller must already have established motion.
    /// Use this to verify retained source intervals before deduplicating a revisit.
    public static func validateAlignedOverlap(previous: ScrollFrame, previousStart: Int,
                                              next: ScrollFrame, nextStart: Int, length: Int,
                                              axis: ScrollAxis,
                                              configuration: Configuration = Configuration()) throws -> ScrollMatchEvidence {
        try validateComparison(previous, next, configuration: configuration)
        try Task.checkCancellation()
        let extent = axis == .vertical ? previous.height : previous.width
        // Subtraction after checking bounds avoids overflowing start + length.
        guard length > 0, previousStart >= 0, nextStart >= 0,
              previousStart < extent, nextStart < extent,
              length <= extent - previousStart, length <= extent - nextStart else {
            throw ScrollStitchError.invalidPixels
        }
        guard let score = try regionScore(previous, next, previousStart: previousStart, nextStart: nextStart,
                                      length: length, axis: axis, sampled: false, rejectOutliers: true) else {
            throw ScrollStitchError.noOverlap
        }
        try requireAgreement(score, configuration: configuration)
        return evidence(for: score, uniquenessMargin: nil)
    }

    private static func validateComparison(_ a: ScrollFrame, _ b: ScrollFrame,
                                           configuration: Configuration) throws {
        guard a.width == b.width, a.height == b.height else { throw ScrollStitchError.differentDimensions }
        guard configuration.minimumOverlapFraction.isFinite, configuration.maximumMeanError.isFinite,
              configuration.minimumTextureDeviation.isFinite, configuration.minimumUniquenessMargin.isFinite,
              configuration.maximumMeanError > 0, configuration.minimumTextureDeviation > 0,
              configuration.minimumUniquenessMargin > 0 else { throw ScrollStitchError.invalidPixels }
    }

    private static func maximumBandError(_ configuration: Configuration) -> Double {
        max(14, configuration.maximumMeanError * 2)
    }

    private static func requireAgreement(_ score: Score, configuration: Configuration) throws {
        // Deliberately require NO >24 outliers in the new path. A small changing word,
        // cursor or fixed region must not vanish inside a low average error when source
        // pixels would otherwise be discarded. Bounded antialiasing/noise still passes.
        guard score.error <= configuration.maximumMeanError, score.badFraction == 0,
              score.worstBandError <= maximumBandError(configuration) else { throw ScrollStitchError.noOverlap }
    }

    private static func evidence(for score: Score, uniquenessMargin: Double?) -> ScrollMatchEvidence {
        ScrollMatchEvidence(meanError: score.error, badFraction: score.badFraction,
                            worstBandError: score.worstBandError, texture: score.texture,
                            uniquenessMargin: uniquenessMargin)
    }

    /// With rejection enabled, observing even one outlier is proof this candidate cannot
    /// pass requireAgreement. The full verification uses every pixel, not the search grid.
    private static func regionScore(_ a: ScrollFrame, _ b: ScrollFrame,
                                    previousStart: Int, nextStart: Int, length: Int, axis: ScrollAxis,
                                    sampled: Bool, rejectOutliers: Bool) throws -> Score? {
        let cross = axis == .vertical ? a.width : a.height
        let rows = sampled ? min(length, 29) : length
        let columns = sampled ? min(cross, 23) : cross
        var sumA = 0.0, squaredA = 0.0, sumB = 0.0, squaredB = 0.0, error = 0.0
        var bad = 0
        // Eight strips in EACH direction and their 64 intersections catch stationary
        // headers/sidebars and localized changes, in either scrolling orientation.
        var tiles = [Double](repeating: 0, count: 64)
        var tileCounts = [Int](repeating: 0, count: 64)
        for row in 0..<rows {
            try Task.checkCancellation()
            let along = sampled && rows > 1 ? row * (length - 1) / (rows - 1) : row
            for column in 0..<columns {
                if (column & 1023) == 0 { try Task.checkCancellation() }
                let across = sampled && columns > 1 ? column * (cross - 1) / (columns - 1) : column
                let ai = axis == .vertical ? (previousStart + along) * a.width + across
                                          : across * a.width + previousStart + along
                let bi = axis == .vertical ? (nextStart + along) * b.width + across
                                          : across * b.width + nextStart + along
                let av = Double(a.pixels[ai]), bv = Double(b.pixels[bi])
                let delta = abs(av - bv)
                if delta > 24 {
                    if rejectOutliers { return nil }
                    bad += 1
                }
                sumA += av
                squaredA += av * av
                sumB += bv
                squaredB += bv * bv
                error += delta
                let tile = min(7, along * 8 / length) * 8 + min(7, across * 8 / cross)
                tiles[tile] += delta
                tileCounts[tile] += 1
            }
        }
        let count = Double(rows * columns)
        let meanA = sumA / count, meanB = sumB / count
        let textureA = sqrt(max(0, squaredA / count - meanA * meanA))
        let textureB = sqrt(max(0, squaredB / count - meanB * meanB))
        let worst = zip(tiles, tileCounts).map { $0 / Double(max(1, $1)) }.max() ?? 255
        return Score(error: error / count, texture: min(textureA, textureB),
                     badFraction: Double(bad) / count, worstBandError: worst)
    }

    private func checkPixelLimit(width: Int, height: Int) throws {
        guard width > 0, height > 0, configuration.maximumOutputPixels > 0,
              width <= configuration.maximumOutputPixels / height else { throw ScrollStitchError.pixelLimit }
    }

    private struct Score {
        let error: Double
        let texture: Double
        let badFraction: Double
        let worstBandError: Double
    }

    private static func measure(_ a: ScrollFrame, _ b: ScrollFrame, axis: ScrollAxis,
                                advance: Int, dense: Bool) -> Score {
        let length = (axis == .vertical ? a.height : a.width) - advance
        let cross = axis == .vertical ? a.width : a.height
        let rows = min(length, dense ? 67 : 29)
        let columns = min(cross, dense ? 61 : 23)
        var sum = 0.0, sumSquared = 0.0, error = 0.0
        var bad = 0
        var bands = [Double](repeating: 0, count: 4)
        var bandCounts = [Int](repeating: 0, count: 4)
        for row in 0..<rows {
            let along = min(length - 1, (row * length + length / 2) / rows)
            for column in 0..<columns {
                // The changing phase avoids a single grid landing only in line spacing.
                let phase = (row * 7 + (dense ? 11 : 3)) % max(1, cross / columns)
                let across = min(cross - 1, column * cross / columns + phase)
                let ai = axis == .vertical ? (along + advance) * a.width + across : across * a.width + along + advance
                let bi = axis == .vertical ? along * b.width + across : across * b.width + along
                let value = Double(a.pixels[ai])
                let delta = abs(value - Double(b.pixels[bi]))
                sum += value
                sumSquared += value * value
                error += delta
                if delta > 24 { bad += 1 }
                let band = min(3, row * 4 / rows)
                bands[band] += delta
                bandCounts[band] += 1
            }
        }
        let count = Double(rows * columns)
        let mean = sum / count
        return Score(error: error / count, texture: sqrt(max(0, sumSquared / count - mean * mean)),
                     badFraction: Double(bad) / count,
                     worstBandError: zip(bands, bandCounts).map { $0 / Double(max(1, $1)) }.max() ?? 255)
    }
}
