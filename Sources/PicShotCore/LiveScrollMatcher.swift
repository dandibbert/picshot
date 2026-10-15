import Foundation

/// Integer, half-open bounds in a captured frame; no platform image types are retained.
public struct LiveScrollPixelRect: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct LiveScrollInsets: Sendable, Equatable {
    public let top: Int
    public let left: Int
    public let bottom: Int
    public let right: Int
}

public struct LiveScrollContentBounds: Sendable, Equatable {
    /// The same viewport rectangle in BOTH inputs. Only this rectangle may be stitched.
    public let rect: LiveScrollPixelRect
    public let insets: LiveScrollInsets
    /// Confidence in observed stationary edges, not a probability or a lifetime guarantee.
    public let confidence: Double
}

public struct LiveScrollMismatchRegion: Sendable, Equatable {
    /// Encloses changed overlap pixels in the NEXT capture's coordinates.
    public let rect: LiveScrollPixelRect
    public let mismatchedPixels: Int
}

public struct LiveScrollQuality: Sendable, Equatable {
    /// Mean error of pixels within pixelDifferenceTolerance, in luminance units 0...255.
    public let inlierMeanError: Double
    public let texturedTiles: Int
    public let supportingTiles: Int
    public let supportingAlongBands: Int
    public let supportingAcrossBands: Int
    /// Gap between contrast-bearing sampled, clipped-error scores for viable signed offsets.
    public let uniquenessMargin: Double
    /// Every overlap pixel is inspected during verification, including outlier pixels.
    public let verifiedPixels: Int
    public let mismatchedPixels: Int
    public let mismatchFraction: Double
    public let mismatchBoundingAreaFraction: Double
    public let confidence: Double
}

public struct LiveScrollMatch: Sendable, Equatable {
    /// Positive reveals below/right; negative reveals above/left; zero is stationary.
    public let displacement: Int
    public var isStationary: Bool { displacement == 0 }
    public let axis: ScrollAxis
    public let contentBounds: LiveScrollContentBounds
    public let previousOverlap: LiveScrollPixelRect
    public let nextOverlap: LiveScrollPixelRect
    public let quality: LiveScrollQuality
    public let mismatchRegions: [LiveScrollMismatchRegion]
}

public enum LiveScrollMatchError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration, unsupportedFixedContent, uncertainContentBounds

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "连续滚动匹配参数无效。"
        case .unsupportedFixedContent: return "固定区域过大或位于侧边，请缩小到滚动内容后重试；已接受的片段保持不变。"
        case .uncertainContentBounds: return "无法可靠区分固定边栏与滚动内容，请调整捕获区域；已接受的片段保持不变。"
        }
    }
}

/// Stateless, bounded matching of genuinely changing consecutive captures. This does not
/// wait for duplicate frames, create a composite, own an accepted anchor, or write files.
/// A caller must commit its frame/strips only after this method AND its disk transaction
/// succeed. On failure keep the old anchor, bounds, strips, and preview unchanged.
///
/// Small, textured stationary leading/trailing bands are inferred from zero-motion
/// evidence and checked against recovered motion. Broad sidebars, blank/repeated-only
/// content, large replacements and poorly separated offsets are intentionally rejected.
/// Bounds are pairwise evidence: the caller must reject later incompatible bounds rather
/// than silently changing previously committed strip geometry.
public enum LiveScrollMatcher {
    /// Pixel geometry only; supported dimensions do not establish overlap or texture.
    public static func supportsCapture(width: Int, height: Int, axis: ScrollAxis) -> Bool {
        let length = axis == .vertical ? height : width
        let cross = axis == .vertical ? width : height
        return length >= 48 && cross >= 24
    }

    public struct Configuration: Sendable {
        public var minimumOverlapFraction: Double = 0.30
        /// Bounds work independently of potentially very tall/high-DPI captures.
        public var maximumDisplacement: Int = 2_048
        public var maximumFixedEdgeFraction: Double = 0.18
        public var maximumCombinedFixedFraction: Double = 0.25
        public var pixelDifferenceTolerance: Int = 18
        public var maximumInlierMeanError: Double = 5
        public var maximumMismatchFraction: Double = 0.06
        public var maximumMismatchBoundingAreaFraction: Double = 0.18
        public var maximumMismatchRegions: Int = 4
        public var minimumTextureDeviation: Double = 9
        public var minimumUniquenessMargin: Double = 1.25
        /// Geometry locked by the caller after its first accepted motion. This must be
        /// an entire cross-axis strip. Every later pair rechecks stationary-edge evidence.
        public var lockedContentBounds: LiveScrollPixelRect?
        public init() {}

        fileprivate var isValid: Bool {
            minimumOverlapFraction.isFinite && (0.25...0.80).contains(minimumOverlapFraction)
                && (1...4_096).contains(maximumDisplacement)
                && maximumFixedEdgeFraction.isFinite && (0...0.20).contains(maximumFixedEdgeFraction)
                && maximumCombinedFixedFraction.isFinite && (0...0.30).contains(maximumCombinedFixedFraction)
                && (4...24).contains(pixelDifferenceTolerance)
                && maximumInlierMeanError.isFinite && (0.1...7).contains(maximumInlierMeanError)
                && maximumMismatchFraction.isFinite && (0...0.08).contains(maximumMismatchFraction)
                && maximumMismatchBoundingAreaFraction.isFinite && (0...0.20).contains(maximumMismatchBoundingAreaFraction)
                && (0...4).contains(maximumMismatchRegions)
                && minimumTextureDeviation.isFinite && (6...32).contains(minimumTextureDeviation)
                && minimumUniquenessMargin.isFinite && (0.5...8).contains(minimumUniquenessMargin)
        }
    }

    public static func match(previous: ScrollFrame, next: ScrollFrame, axis: ScrollAxis,
                             configuration: Configuration = .init()) throws -> LiveScrollMatch {
        guard configuration.isValid else { throw LiveScrollMatchError.invalidConfiguration }
        guard previous.width == next.width, previous.height == next.height else {
            throw ScrollStitchError.differentDimensions
        }
        try Task.checkCancellation()
        let length = axis == .vertical ? previous.height : previous.width
        let cross = axis == .vertical ? previous.width : previous.height
        guard supportsCapture(width: previous.width, height: previous.height, axis: axis) else {
            throw ScrollStitchError.insufficientTexture
        }
        let lockedEdges = try configuration.lockedContentBounds.map {
            try validateLockedBounds($0, frame: previous, axis: axis, configuration: configuration)
        }
        if previous.pixels == next.pixels {
            return stationary(previous, axis: axis, edges: lockedEdges ?? Edges(leading: 0, trailing: 0, oversized: false))
        }

        let edges = try lockedEdges ?? inferEdges(previous, next, axis: axis, configuration: configuration)
        let contentLength = length - edges.leading - edges.trailing
        let minimumOverlap = max(24, Int(ceil(Double(contentLength) * configuration.minimumOverlapFraction)))
        let maximumAdvance = min(configuration.maximumDisplacement, contentLength - minimumOverlap)
        guard maximumAdvance > 0 else { throw ScrollStitchError.insufficientTexture }

        // Search EVERY integer offset, including zero and the reverse direction. Spatial
        // sampling never subsamples candidate offsets; one-pixel alignment is explicit.
        // At most nine finalists are retained; too many plausible offsets fail closed.
        var finalists: [Candidate] = []
        var sawTexture = false
        var closestRejectedScore = Double.infinity
        for displacement in -maximumAdvance...maximumAdvance {
            if displacement % 16 == 0 { try Task.checkCancellation() }
            let score = screen(previous, next, axis: axis, start: edges.leading,
                               length: contentLength, cross: cross, displacement: displacement,
                               configuration: configuration)
            sawTexture = sawTexture || score.texturedTiles >= 12
            if score.hasDistributedSupport && score.error <= screenErrorLimit(configuration)
                && score.badFraction <= configuration.maximumMismatchFraction + 0.02 {
                finalists.append(Candidate(displacement: displacement, score: score))
                if finalists.count > 8 { throw ScrollStitchError.ambiguousOverlap }
            } else if score.hasDistributedTexture {
                closestRejectedScore = min(closestRejectedScore, score.error)
            }
        }
        guard sawTexture else { throw ScrollStitchError.insufficientTexture }
        finalists.sort { $0.score.error == $1.score.error
            ? $0.displacement < $1.displacement : $0.score.error < $1.score.error }
        guard !finalists.isEmpty else { throw ScrollStitchError.noOverlap }

        var verified: [(Candidate, Verification)] = []
        for candidate in finalists {
            try Task.checkCancellation()
            if let evidence = try verify(previous, next, axis: axis, start: edges.leading,
                                         length: contentLength, cross: cross,
                                         displacement: candidate.displacement, configuration: configuration) {
                verified.append((candidate, evidence))
            }
        }
        guard let (best, verification) = verified.first else { throw ScrollStitchError.noOverlap }
        // Even a near competitor that failed the strict verification must not turn an
        // imprecise subpixel/blurry translation into a confident integer alignment.
        let alternate = finalists.filter { $0.displacement != best.displacement }.map { $0.score.error }.min()
        let competitor = min(alternate ?? .infinity, closestRejectedScore)
        let margin = min(255, competitor.isFinite ? competitor - best.score.error : 255)
        guard margin >= configuration.minimumUniquenessMargin else { throw ScrollStitchError.ambiguousOverlap }
        if best.displacement == 0 {
            return stationary(previous, axis: axis, edges: edges, score: best.score, verification: verification,
                              uniquenessMargin: margin)
        }
        guard !edges.oversized else { throw LiveScrollMatchError.unsupportedFixedContent }
        let edgeConfidence = try validateEdges(previous, next, axis: axis, edges: edges,
                                               displacement: best.displacement, configuration: configuration)
        let bounds = boundsFor(previous, axis: axis, leading: edges.leading, trailing: edges.trailing,
                               confidence: edgeConfidence)
        let overlapLength = contentLength - abs(best.displacement)
        let oldStart = edges.leading + max(0, best.displacement)
        let newStart = edges.leading + max(0, -best.displacement)
        let confidence = min(edgeConfidence, min(1, margin / 4)
            * max(0, 1 - verification.inlierMeanError / (configuration.maximumInlierMeanError * 2))
            * (1 - verification.badFraction))
        let quality = LiveScrollQuality(inlierMeanError: verification.inlierMeanError,
            texturedTiles: best.score.texturedTiles, supportingTiles: best.score.supportingTiles,
            supportingAlongBands: best.score.alongBands, supportingAcrossBands: best.score.acrossBands,
            uniquenessMargin: margin, verifiedPixels: overlapLength * cross,
            mismatchedPixels: verification.badPixels, mismatchFraction: verification.badFraction,
            mismatchBoundingAreaFraction: verification.boundingAreaFraction, confidence: confidence)
        try Task.checkCancellation()
        return LiveScrollMatch(displacement: best.displacement, axis: axis, contentBounds: bounds,
            previousOverlap: rect(axis: axis, along: oldStart, across: 0, length: overlapLength, cross: cross),
            nextOverlap: rect(axis: axis, along: newStart, across: 0, length: overlapLength, cross: cross),
            quality: quality, mismatchRegions: verification.regions)
    }

    private struct Edges { let leading: Int; let trailing: Int; let oversized: Bool }
    private struct Candidate { let displacement: Int; let score: Screening }
    private struct Screening {
        let error: Double
        let badFraction: Double
        let texturedTiles: Int
        let supportingTiles: Int
        let alongBands: Int
        let acrossBands: Int
        let textureAlongBands: Int
        let textureAcrossBands: Int
        let quadrants: Int
        var hasDistributedTexture: Bool { texturedTiles >= 12 && textureAlongBands >= 5 && textureAcrossBands >= 3 }
        var hasDistributedSupport: Bool { supportingTiles >= 12 && alongBands >= 5 && acrossBands >= 3 && quadrants == 4 }
    }
    private struct Verification {
        let inlierMeanError: Double
        let badPixels: Int
        let badFraction: Double
        let boundingAreaFraction: Double
        let regions: [LiveScrollMismatchRegion]
    }

    private static func screenErrorLimit(_ configuration: Configuration) -> Double {
        configuration.maximumInlierMeanError + Double(configuration.pixelDifferenceTolerance) * configuration.maximumMismatchFraction
    }

    @inline(__always) private static func value(_ frame: ScrollFrame, axis: ScrollAxis, along: Int, across: Int) -> Int {
        Int(frame.pixels[axis == .vertical ? along * frame.width + across : across * frame.width + along])
    }

    /// Forty-eight spatial tiles, each sampled on a phase-varying 5x5 grid. Both images
    /// must carry texture; a matching blank background is never positive motion evidence.
    /// Uniqueness uses contrast-bearing samples, so empty margins cannot dilute the
    /// disagreement between similar text rows. Support and full-pixel checks stay separate.
    private static func screen(_ a: ScrollFrame, _ b: ScrollFrame, axis: ScrollAxis, start: Int,
                               length: Int, cross: Int, displacement: Int,
                               configuration: Configuration) -> Screening {
        let overlap = length - abs(displacement)
        let oldStart = start + max(0, displacement), newStart = start + max(0, -displacement)
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 25) { samples in
            var informativeError = 0.0, informativeCount = 0
            var total = 0, totalBad = 0, textured = 0, supported = 0
            var alongMask = 0, acrossMask = 0, textureAlongMask = 0, textureAcrossMask = 0, quadrantMask = 0
            for alongTile in 0..<8 {
                let low = alongTile * overlap / 8, high = (alongTile + 1) * overlap / 8
                for acrossTile in 0..<6 {
                    let left = acrossTile * cross / 6, right = (acrossTile + 1) * cross / 6
                    var sumA = 0.0, squareA = 0.0, sumB = 0.0, squareB = 0.0, error = 0.0
                    var bad = 0, count = 0
                    let rows = min(5, high - low), columns = min(5, right - left)
                    for row in 0..<rows {
                        let y0 = low + row * (high - low) / rows
                        let y1 = low + (row + 1) * (high - low) / rows
                        for column in 0..<columns {
                            let x0 = left + column * (right - left) / columns
                            let x1 = left + (column + 1) * (right - left) / columns
                            let along = y0 + (acrossTile * 3 + column * 5 + row) % max(1, y1 - y0)
                            let across = x0 + (alongTile * 7 + row * 3 + column) % max(1, x1 - x0)
                            let av = value(a, axis: axis, along: oldStart + along, across: across)
                            let bv = value(b, axis: axis, along: newStart + along, across: across)
                            let delta = abs(av - bv)
                            sumA += Double(av); squareA += Double(av * av)
                            sumB += Double(bv); squareB += Double(bv * bv)
                            error += Double(min(delta, configuration.pixelDifferenceTolerance))
                            if delta > configuration.pixelDifferenceTolerance { bad += 1 }
                            samples[count] = UInt16(av << 8 | bv)
                            count += 1
                        }
                    }
                    let n = Double(max(1, count))
                    let meanA = sumA / n, meanB = sumB / n
                    let deviationA = sqrt(max(0, squareA / n - meanA * meanA))
                    let deviationB = sqrt(max(0, squareB / n - meanB * meanB))
                    let deviation = min(deviationA, deviationB)
                    if max(deviationA, deviationB) >= configuration.minimumTextureDeviation {
                        let contrastA = max(configuration.minimumTextureDeviation, deviationA)
                        let contrastB = max(configuration.minimumTextureDeviation, deviationB)
                        for index in 0..<count {
                            let av = Int(samples[index] >> 8), bv = Int(samples[index] & 255)
                            // The union matters: disappearing/replaced text must contribute
                            // disagreement even when the other image is a flat background.
                            if abs(Double(av) - meanA) >= contrastA || abs(Double(bv) - meanB) >= contrastB {
                                informativeError += Double(min(abs(av - bv), configuration.pixelDifferenceTolerance))
                                informativeCount += 1
                            }
                        }
                    }
                    if deviation >= configuration.minimumTextureDeviation {
                        textured += 1; textureAlongMask |= 1 << alongTile; textureAcrossMask |= 1 << acrossTile
                        if error / n <= configuration.maximumInlierMeanError + 1 && Double(bad) / n <= 0.20 {
                            supported += 1; alongMask |= 1 << alongTile; acrossMask |= 1 << acrossTile
                            quadrantMask |= 1 << ((alongTile / 4) * 2 + acrossTile / 3)
                        }
                    }
                    total += count; totalBad += bad
                }
            }
            return Screening(error: informativeError / Double(max(1, informativeCount)), badFraction: Double(totalBad) / Double(max(1, total)), texturedTiles: textured,
                supportingTiles: supported, alongBands: alongMask.nonzeroBitCount,
                acrossBands: acrossMask.nonzeroBitCount, textureAlongBands: textureAlongMask.nonzeroBitCount,
                textureAcrossBands: textureAcrossMask.nonzeroBitCount, quadrants: quadrantMask.nonzeroBitCount)
        }
    }

    private static func inferEdges(_ a: ScrollFrame, _ b: ScrollFrame, axis: ScrollAxis,
                                   configuration: Configuration) throws -> Edges {
        let length = axis == .vertical ? a.height : a.width
        let cross = axis == .vertical ? a.width : a.height
        let samples = min(96, cross)
        func stationary(_ line: Int) -> Bool {
            var changed = 0
            for column in 0..<samples {
                let across = column * cross / samples + (line * 7 + column * 3) % max(1, cross / samples)
                if abs(value(a, axis: axis, along: line, across: across)
                    - value(b, axis: axis, along: line, across: across)) > 4 { changed += 1 }
            }
            return Double(changed) / Double(samples) <= 0.04
        }
        var leading = 0, trailing = 0
        while leading < length && stationary(leading) {
            if leading % 32 == 0 { try Task.checkCancellation() }
            leading += 1
        }
        while trailing < length - leading && stationary(length - 1 - trailing) {
            if trailing % 32 == 0 { try Task.checkCancellation() }
            trailing += 1
        }
        // A single accidental unchanged scanline is not enough evidence for a fixed bar.
        if leading < 2 { leading = 0 }
        if trailing < 2 { trailing = 0 }
        // A stationary run can cross the real bar boundary into coincident paragraph
        // whitespace. Do not lock that blank extension into the fixed band: its pixels
        // cannot distinguish fixed padding from scrolling content yet. Wait for another
        // changing frame to expose the boundary instead of guessing or dropping rows.
        func hasAmbiguousFlatExtension(_ band: Range<Int>, leadingEdge: Bool) throws -> Bool {
            guard !band.isEmpty else { return false }
            let end = leadingEdge ? band.upperBound - 1 : band.lowerBound
            let inward = leadingEdge ? -1 : 1
            let reference = value(a, axis: axis, along: end, across: 0)
            var line = end
            while band.contains(line) {
                if line % 32 == 0 { try Task.checkCancellation() }
                var flatA = true, flatB = true
                for column in 0..<samples {
                    let across = column * cross / samples
                    if abs(value(a, axis: axis, along: line, across: across) - reference) > 4 { flatA = false }
                    if abs(value(b, axis: axis, along: line, across: across) - reference) > 4 { flatB = false }
                    if !flatA && !flatB { break }
                }
                if !flatA && !flatB { break }
                line += inward
            }
            guard line != end, band.contains(line) else { return false }
            var broad = 0
            for column in 0..<samples {
                let across = column * cross / samples
                if abs(value(a, axis: axis, along: line, across: across) - reference)
                    > configuration.pixelDifferenceTolerance
                    && abs(value(b, axis: axis, along: line, across: across) - reference)
                    > configuration.pixelDifferenceTolerance { broad += 1 }
            }
            return Double(broad) / Double(samples) >= 0.50
        }
        if try hasAmbiguousFlatExtension(0..<leading, leadingEdge: true)
            || hasAmbiguousFlatExtension((length - trailing)..<length, leadingEdge: false) {
            throw LiveScrollMatchError.uncertainContentBounds
        }
        // Ordinary paragraph/row whitespace can coincide at a viewport edge. Such a
        // flat run alone is not a fixed bar. Require texture OR a broad visible boundary;
        // an uninformative run remains in the full-pixel verified scrolling rectangle.
        func hasEdgeEvidence(_ band: Range<Int>, adjacent: Int) -> Bool {
            guard !band.isEmpty, adjacent >= 0, adjacent < length else { return true }
            var sum = 0.0, squared = 0.0, count = 0
            for along in band {
                for column in 0..<samples {
                    let across = column * cross / samples
                    let v = value(a, axis: axis, along: along, across: across)
                    if abs(v - value(b, axis: axis, along: along, across: across)) <= 4 {
                        sum += Double(v); squared += Double(v * v); count += 1
                    }
                }
            }
            let n = Double(max(1, count))
            if sqrt(max(0, squared / n - pow(sum / n, 2))) >= configuration.minimumTextureDeviation { return true }
            let boundary = adjacent < band.lowerBound ? band.lowerBound : band.upperBound - 1
            var different = 0
            for column in 0..<samples {
                let across = column * cross / samples
                if abs(value(a, axis: axis, along: boundary, across: across)
                    - value(a, axis: axis, along: adjacent, across: across)) > configuration.pixelDifferenceTolerance {
                    different += 1
                }
            }
            return Double(different) / Double(samples) >= 0.50
        }
        if !hasEdgeEvidence(0..<leading, adjacent: leading) { leading = 0 }
        if !hasEdgeEvidence((length - trailing)..<length, adjacent: length - trailing - 1) { trailing = 0 }
        let tooLarge = Double(max(leading, trailing)) > Double(length) * configuration.maximumFixedEdgeFraction
            || Double(leading + trailing) > Double(length) * configuration.maximumCombinedFixedFraction
        // Retain zero as a candidate for idle frames with a blink/cursor. An oversized
        // edge may never justify cropping or accepting a nonzero motion.
        return Edges(leading: tooLarge ? 0 : leading, trailing: tooLarge ? 0 : trailing, oversized: tooLarge)
    }

    private static func validateEdges(_ a: ScrollFrame, _ b: ScrollFrame, axis: ScrollAxis,
                                      edges: Edges, displacement: Int,
                                      configuration: Configuration) throws -> Double {
        let length = axis == .vertical ? a.height : a.width
        let cross = axis == .vertical ? a.width : a.height
        var confidence = 1.0
        for band in [0..<edges.leading, (length - edges.trailing)..<length] where !band.isEmpty {
            var sum = 0.0, squared = 0.0, same = 0, count = 0, movingBad = 0, movingCount = 0
            for along in band {
                try Task.checkCancellation()
                for across in 0..<cross {
                    let av = value(a, axis: axis, along: along, across: across)
                    let bv = value(b, axis: axis, along: along, across: across)
                    count += 1
                    if abs(av - bv) <= 4 {
                        same += 1; sum += Double(av); squared += Double(av * av)
                    }
                    let shifted = along + displacement
                    if shifted >= 0 && shifted < length && !band.contains(shifted) {
                        movingCount += 1
                        if abs(value(a, axis: axis, along: shifted, across: across) - bv)
                            > configuration.pixelDifferenceTolerance { movingBad += 1 }
                    }
                    let reverseShifted = along - displacement
                    if reverseShifted >= 0 && reverseShifted < length && !band.contains(reverseShifted) {
                        movingCount += 1
                        if abs(av - value(b, axis: axis, along: reverseShifted, across: across))
                            > configuration.pixelDifferenceTolerance { movingBad += 1 }
                    }
                }
            }
            let n = Double(count), stationaryAgreement = Double(same) / n
            let stableCount = Double(max(1, same))
            let texture = sqrt(max(0, squared / stableCount - pow(sum / stableCount, 2)))
            // An untextured bar additionally needs a broad, contrasting moving boundary;
            // a coincidental patch of paragraph whitespace cannot certify fixed geometry.
            let requiredMovingDisagreement = texture >= configuration.minimumTextureDeviation ? 0.10 : 0.50
            guard stationaryAgreement >= 0.96, movingCount > 0,
                  Double(movingBad) / Double(movingCount) >= requiredMovingDisagreement else {
                throw LiveScrollMatchError.uncertainContentBounds
            }
            confidence = min(confidence, stationaryAgreement)
        }
        return confidence
    }

    private struct BadCell {
        var count = 0
        var minAlong = Int.max, maxAlong = -1, minAcross = Int.max, maxAcross = -1
        mutating func add(along: Int, across: Int) {
            count += 1
            minAlong = min(minAlong, along); maxAlong = max(maxAlong, along)
            minAcross = min(minAcross, across); maxAcross = max(maxAcross, across)
        }
    }

    /// Full-pixel verification uses constant-size spatial bookkeeping (384 cells). The
    /// mismatch count is exact; returned component boxes conservatively enclose pixels.
    private static func verify(_ a: ScrollFrame, _ b: ScrollFrame, axis: ScrollAxis, start: Int,
                               length: Int, cross: Int, displacement: Int,
                               configuration: Configuration) throws -> Verification? {
        let overlap = length - abs(displacement), total = overlap * cross
        let oldStart = start + max(0, displacement), newStart = start + max(0, -displacement)
        let badLimit = Int(Double(total) * configuration.maximumMismatchFraction)
        var badPixels = 0, inlierError = 0.0
        var cells = [BadCell](repeating: BadCell(), count: 24 * 16)
        for along in 0..<overlap {
            try Task.checkCancellation()
            for across in 0..<cross {
                let delta = abs(value(a, axis: axis, along: oldStart + along, across: across)
                    - value(b, axis: axis, along: newStart + along, across: across))
                if delta > configuration.pixelDifferenceTolerance {
                    badPixels += 1
                    if badPixels > badLimit { return nil }
                    let cell = min(23, along * 24 / overlap) * 16 + min(15, across * 16 / cross)
                    cells[cell].add(along: along, across: across)
                } else { inlierError += Double(delta) }
            }
        }
        let inlierMean = inlierError / Double(max(1, total - badPixels))
        guard inlierMean <= configuration.maximumInlierMeanError else { return nil }
        var seen = [Bool](repeating: false, count: cells.count)
        var regions: [LiveScrollMismatchRegion] = []
        var boundingArea = 0
        for index in cells.indices where cells[index].count > 0 && !seen[index] {
            var queue = [index], head = 0
            seen[index] = true
            var count = 0, low = Int.max, high = -1, left = Int.max, right = -1
            while head < queue.count {
                let current = queue[head]; head += 1
                let cell = cells[current]
                count += cell.count; low = min(low, cell.minAlong); high = max(high, cell.maxAlong)
                left = min(left, cell.minAcross); right = max(right, cell.maxAcross)
                let row = current / 16, column = current % 16
                for dy in -1...1 {
                    for dx in -1...1 {
                        let y = row + dy, x = column + dx
                        if y >= 0 && y < 24 && x >= 0 && x < 16 {
                            let neighbor = y * 16 + x
                            if !seen[neighbor] && cells[neighbor].count > 0 {
                                seen[neighbor] = true; queue.append(neighbor)
                            }
                        }
                    }
                }
            }
            let alongExtent = high - low + 1, crossExtent = right - left + 1
            let area = alongExtent * crossExtent
            // A full-height narrow sidebar is not a permissible cursor/animation region.
            guard Double(alongExtent) <= Double(overlap) * 0.55,
                  Double(crossExtent) <= Double(cross) * 0.60,
                  Double(area) <= Double(total) * 0.12 else { return nil }
            boundingArea += area
            guard Double(boundingArea) <= Double(total) * configuration.maximumMismatchBoundingAreaFraction,
                  regions.count < configuration.maximumMismatchRegions else { return nil }
            regions.append(LiveScrollMismatchRegion(
                rect: rect(axis: axis, along: newStart + low, across: left, length: alongExtent, cross: crossExtent),
                mismatchedPixels: count))
        }
        return Verification(inlierMeanError: inlierMean, badPixels: badPixels,
            badFraction: Double(badPixels) / Double(total),
            boundingAreaFraction: Double(boundingArea) / Double(total), regions: regions)
    }

    private static func rect(axis: ScrollAxis, along: Int, across: Int, length: Int, cross: Int) -> LiveScrollPixelRect {
        axis == .vertical ? .init(x: across, y: along, width: cross, height: length)
            : .init(x: along, y: across, width: length, height: cross)
    }

    private static func boundsFor(_ frame: ScrollFrame, axis: ScrollAxis, leading: Int,
                                  trailing: Int, confidence: Double) -> LiveScrollContentBounds {
        let length = axis == .vertical ? frame.height : frame.width
        let cross = axis == .vertical ? frame.width : frame.height
        return LiveScrollContentBounds(rect: rect(axis: axis, along: leading, across: 0,
            length: length - leading - trailing, cross: cross),
            insets: .init(top: axis == .vertical ? leading : 0, left: axis == .horizontal ? leading : 0,
                          bottom: axis == .vertical ? trailing : 0, right: axis == .horizontal ? trailing : 0),
            confidence: confidence)
    }

    private static func validateLockedBounds(_ bounds: LiveScrollPixelRect, frame: ScrollFrame,
                                              axis: ScrollAxis, configuration: Configuration) throws -> Edges {
        guard bounds.x >= 0, bounds.y >= 0, bounds.width > 0, bounds.height > 0,
              bounds.x < frame.width, bounds.y < frame.height,
              bounds.width <= frame.width - bounds.x, bounds.height <= frame.height - bounds.y else {
            throw LiveScrollMatchError.invalidConfiguration
        }
        let length = axis == .vertical ? frame.height : frame.width
        let leading = axis == .vertical ? bounds.y : bounds.x
        let trailing = length - (axis == .vertical ? bounds.maxY : bounds.maxX)
        guard (axis == .vertical ? bounds.x == 0 && bounds.width == frame.width
                : bounds.y == 0 && bounds.height == frame.height),
              Double(max(leading, trailing)) <= Double(length) * configuration.maximumFixedEdgeFraction,
              Double(leading + trailing) <= Double(length) * configuration.maximumCombinedFixedFraction else {
            throw LiveScrollMatchError.invalidConfiguration
        }
        return Edges(leading: leading, trailing: trailing, oversized: false)
    }

    private static func stationary(_ frame: ScrollFrame, axis: ScrollAxis, edges: Edges,
                                    score: Screening? = nil, verification: Verification? = nil,
                                    uniquenessMargin: Double = 255) -> LiveScrollMatch {
        // No motion supplies no NEW evidence for fixed-content geometry. The caller must
        // neither lock these bounds nor replace its accepted anchor/image on this result.
        let bounds = boundsFor(frame, axis: axis, leading: edges.leading, trailing: edges.trailing, confidence: 0)
        let quality = LiveScrollQuality(inlierMeanError: verification?.inlierMeanError ?? 0,
            texturedTiles: score?.texturedTiles ?? 0, supportingTiles: score?.supportingTiles ?? 0,
            supportingAlongBands: score?.alongBands ?? 0, supportingAcrossBands: score?.acrossBands ?? 0,
            uniquenessMargin: uniquenessMargin, verifiedPixels: bounds.rect.width * bounds.rect.height,
            mismatchedPixels: verification?.badPixels ?? 0, mismatchFraction: verification?.badFraction ?? 0,
            mismatchBoundingAreaFraction: verification?.boundingAreaFraction ?? 0, confidence: 1)
        return LiveScrollMatch(displacement: 0, axis: axis, contentBounds: bounds,
            previousOverlap: bounds.rect, nextOverlap: bounds.rect, quality: quality,
            mismatchRegions: verification?.regions ?? [])
    }
}
