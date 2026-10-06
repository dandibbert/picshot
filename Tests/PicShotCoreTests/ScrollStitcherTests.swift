import XCTest
@testable import PicShotCore

final class ScrollStitcherTests: XCTestCase {
    /// Coordinate-hashed texture makes wrong displacements observably different, without
    /// tying the fixtures to any platform image framework or random-number generator.
    private func frame(width: Int = 96, height: Int = 140, x: Int = 0, y: Int = 0,
                       seed: UInt64 = 7, noise: Int = 0) throws -> ScrollFrame {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                var v = UInt64(column + x) &* 0x9e3779b185ebca87
                v ^= UInt64(row + y) &* 0xc2b2ae3d27d4eb4f
                v ^= seed
                v = (v ^ (v >> 30)) &* 0xbf58476d1ce4e5b9
                v = (v ^ (v >> 27)) &* 0x94d049bb133111eb
                v ^= v >> 31
                let jitter = noise == 0 ? 0 : ((row * 13 + column * 17) % (noise * 2 + 1)) - noise
                pixels.append(UInt8(clamping: Int(v % 216) + 20 + jitter))
            }
        }
        return try ScrollFrame(width: width, height: height, grayscale: pixels)
    }

    func testVerticalOverlapAndCumulativePlacement() throws {
        var stitcher = ScrollStitcher()
        let first = try stitcher.append(frame())
        XCTAssertEqual(first.advance, 0)
        let second = try stitcher.append(frame(y: 47))
        XCTAssertEqual(second.y, 47)
        XCTAssertEqual(second.advance, 47)
        XCTAssertEqual(second.overlap, 93)
        let third = try stitcher.append(frame(y: 104))
        XCTAssertEqual(third.y, 104)
        XCTAssertEqual(stitcher.outputWidth, 96)
        XCTAssertEqual(stitcher.outputHeight, 244)
        XCTAssertEqual(stitcher.frameCount, 3)
    }

    func testHorizontalOverlap() throws {
        var stitcher = ScrollStitcher(axis: .horizontal)
        try stitcher.append(frame(width: 160, height: 90))
        let result = try stitcher.append(frame(width: 160, height: 90, x: 61))
        XCTAssertEqual(result.x, 61)
        XCTAssertEqual(result.y, 0)
        XCTAssertEqual(result.overlap, 99)
        XCTAssertEqual(stitcher.outputWidth, 221)
        XCTAssertEqual(stitcher.outputHeight, 90)
    }

    func testNoiseStillFindsExactPixelOffset() throws {
        let result = try ScrollStitcher.match(previous: frame(), next: frame(y: 39, noise: 3), axis: .vertical)
        XCTAssertEqual(result.advance, 39)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testSinglePixelAdvance() throws {
        let result = try ScrollStitcher.match(previous: frame(), next: frame(y: 1), axis: .vertical)
        XCTAssertEqual(result.advance, 1)
    }

    func testDuplicateDoesNotChangeSessionAndCanRetry() throws {
        var stitcher = ScrollStitcher()
        let first = try frame()
        try stitcher.append(first)
        XCTAssertThrowsError(try stitcher.append(first)) { XCTAssertEqual($0 as? ScrollStitchError, .duplicate) }
        XCTAssertEqual(stitcher.frameCount, 1)
        XCTAssertEqual(stitcher.outputHeight, 140)
        XCTAssertEqual(try stitcher.append(frame(y: 31)).y, 31)
    }

    func testNonoverlappingImagesAreRejected() throws {
        XCTAssertThrowsError(try ScrollStitcher.match(previous: frame(), next: frame(y: 500), axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
        }
    }

    func testIndependentImagesAreRejected() throws {
        XCTAssertThrowsError(try ScrollStitcher.match(previous: frame(), next: frame(seed: 125), axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
        }
    }

    func testReverseScrollingIsRejected() throws {
        XCTAssertThrowsError(try ScrollStitcher.match(previous: frame(y: 75), next: frame(y: 20), axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
        }
    }

    func testTooLittleOverlapIsRejected() throws {
        XCTAssertThrowsError(try ScrollStitcher.match(previous: frame(), next: frame(y: 120), axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
        }
    }

    func testNonfiniteConfigurationIsRejectedSafely() throws {
        var config = ScrollStitcher.Configuration()
        config.minimumOverlapFraction = .nan
        XCTAssertThrowsError(try ScrollStitcher.match(previous: frame(), next: frame(y: 20), axis: .vertical, configuration: config)) {
            XCTAssertEqual($0 as? ScrollStitchError, .invalidPixels)
        }
    }

    func testRepeatedPatternIsAmbiguous() throws {
        func patterned(offset: Int) throws -> ScrollFrame {
            let width = 80, height = 160
            var values = [UInt8]()
            for y in 0..<height {
                for x in 0..<width { values.append(UInt8((((y + offset) % 16) * 17 + x * 29) % 256)) }
            }
            return try ScrollFrame(width: width, height: height, grayscale: values)
        }
        XCTAssertThrowsError(try ScrollStitcher.match(previous: patterned(offset: 0), next: patterned(offset: 5), axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .ambiguousOverlap)
        }
    }

    func testFlatFramesAreRejected() throws {
        let first = try ScrollFrame(width: 80, height: 120, grayscale: .init(repeating: 100, count: 9_600))
        let second = try ScrollFrame(width: 80, height: 120, grayscale: .init(repeating: 103, count: 9_600))
        XCTAssertThrowsError(try ScrollStitcher.match(previous: first, next: second, axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .insufficientTexture)
        }
    }

    func testChangedDimensionsAreRejectedWithoutMutation() throws {
        var stitcher = ScrollStitcher()
        try stitcher.append(frame())
        XCTAssertThrowsError(try stitcher.append(frame(width: 95))) {
            XCTAssertEqual($0 as? ScrollStitchError, .differentDimensions)
        }
        XCTAssertEqual(stitcher.frameCount, 1)
    }

    func testPixelLimitRejectsBeforeMutatingSession() throws {
        var configuration = ScrollStitcher.Configuration()
        configuration.maximumOutputPixels = 96 * 150
        var stitcher = ScrollStitcher(configuration: configuration)
        try stitcher.append(frame())
        XCTAssertThrowsError(try stitcher.append(frame(y: 40))) {
            XCTAssertEqual($0 as? ScrollStitchError, .pixelLimit)
        }
        XCTAssertEqual(stitcher.frameCount, 1)
        XCTAssertEqual(stitcher.outputHeight, 140)
        XCTAssertEqual(try stitcher.append(frame(y: 7)).y, 7)
    }

    func testFirstFrameAlsoObeysPixelLimit() throws {
        var config = ScrollStitcher.Configuration()
        config.maximumOutputPixels = 100
        var stitcher = ScrollStitcher(configuration: config)
        XCTAssertThrowsError(try stitcher.append(frame())) { XCTAssertEqual($0 as? ScrollStitchError, .pixelLimit) }
        XCTAssertEqual(stitcher.frameCount, 0)
    }

    func testRGBAConversionAndRowPadding() throws {
        let frame = try ScrollFrame(width: 2, height: 2, rgba: [
            255, 0, 0, 255, 0, 255, 0, 255, 99, 99, 99, 99,
            0, 0, 255, 255, 0, 0, 0, 0, 99, 99, 99, 99
        ], bytesPerRow: 12)
        XCTAssertEqual(frame.pixels, [76, 149, 28, 255])
    }

    func testInvalidPixelBuffersAndOverflowAreRejected() {
        XCTAssertThrowsError(try ScrollFrame(width: 2, height: 2, grayscale: [1]))
        XCTAssertThrowsError(try ScrollFrame(width: -1, height: 2, grayscale: []))
        XCTAssertThrowsError(try ScrollFrame(width: Int.max, height: 2, rgba: []))
        XCTAssertThrowsError(try ScrollFrame(width: 1, height: 2, rgba: [1, 2, 3, 4], bytesPerRow: Int.max))
    }

    func testFixedHeaderDoesNotCreateFalseMatch() throws {
        let original = try frame()
        let scrolled = try frame(y: 45)
        var pixels = scrolled.pixels
        // A large sticky header changes the overlap and should produce a safe rejection.
        pixels.replaceSubrange(0..<(96 * 65), with: original.pixels[0..<(96 * 65)])
        let next = try ScrollFrame(width: 96, height: 140, grayscale: pixels)
        XCTAssertThrowsError(try ScrollStitcher.match(previous: original, next: next, axis: .vertical))
    }
    private func axisFrame(_ axis: ScrollAxis, origin: Int = 0, seed: UInt64 = 7,
                           noise: Int = 0) throws -> ScrollFrame {
        try frame(width: axis == .vertical ? 96 : 140, height: axis == .vertical ? 140 : 96,
                  x: axis == .horizontal ? origin : 0, y: axis == .vertical ? origin : 0,
                  seed: seed, noise: noise)
    }

    private func replacing(_ source: ScrollFrame, axis: ScrollAxis,
                           along: Range<Int>, across: Range<Int>,
                           value: (Int, Int, UInt8) -> UInt8) throws -> ScrollFrame {
        var pixels = source.pixels
        for row in along {
            for column in across {
                let index = axis == .vertical ? row * source.width + column : column * source.width + row
                pixels[index] = value(row, column, pixels[index])
            }
        }
        return try ScrollFrame(width: source.width, height: source.height, grayscale: pixels)
    }

    func testBidirectionalSignedPlacementAndEvidenceOnBothAxes() throws {
        for axis in ScrollAxis.allCases {
            for advance in [-55, -1, 1, 55] {
                let result = try ScrollStitcher.matchBidirectional(previous: axisFrame(axis, origin: 80),
                                                                 next: axisFrame(axis, origin: 80 + advance), axis: axis)
                XCTAssertEqual(result.advance, advance)
                XCTAssertEqual(result.x, axis == .horizontal ? advance : 0)
                XCTAssertEqual(result.y, axis == .vertical ? advance : 0)
                XCTAssertEqual(result.overlap, 140 - abs(advance))
                XCTAssertEqual(result.confidence, 1)
                let evidence = try XCTUnwrap(result.evidence)
                XCTAssertEqual(evidence.meanError, 0)
                XCTAssertEqual(evidence.badFraction, 0)
                XCTAssertEqual(evidence.worstBandError, 0)
                XCTAssertGreaterThan(evidence.texture, 9)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(evidence.uniquenessMargin), 3)
            }
        }
    }

    func testBidirectionalSmallBoundedNoiseKeepsExactSignedOffset() throws {
        for axis in ScrollAxis.allCases {
            for advance in [-39, 39] {
                let result = try ScrollStitcher.matchBidirectional(previous: axisFrame(axis, origin: 70),
                                                                 next: axisFrame(axis, origin: 70 + advance, noise: 3), axis: axis)
                XCTAssertEqual(result.advance, advance)
                XCTAssertGreaterThan(result.confidence, 0.5)
                let evidence = try XCTUnwrap(result.evidence)
                XCTAssertGreaterThan(evidence.meanError, 0)
                XCTAssertLessThanOrEqual(evidence.meanError, 3)
                XCTAssertEqual(evidence.badFraction, 0)
                XCTAssertLessThanOrEqual(evidence.worstBandError, 3)
                XCTAssertGreaterThan(evidence.texture, 9)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(evidence.uniquenessMargin), 3)
            }
        }
    }

    func testBidirectionalOppositeDirectionsCompeteForPeriodicPattern() throws {
        for axis in ScrollAxis.allCases {
            let tile = try axisFrame(axis)
            func periodic(origin: Int) throws -> ScrollFrame {
                try replacing(tile, axis: axis, along: 0..<140, across: 0..<96) { along, across, _ in
                    let periodicAlong = (along + origin) % 101
                    let index = axis == .vertical ? periodicAlong * tile.width + across
                                                  : across * tile.width + periodicAlong
                    return tile.pixels[index]
                }
            }
            // Within the permitted +/-105 search range, both +40 and -61 match exactly.
            // Each single-direction search could choose a plausible but different answer.
            let previous = try periodic(origin: 0), next = try periodic(origin: 40)
            XCTAssertEqual(try ScrollStitcher.match(previous: previous, next: next, axis: axis).advance, 40)
            XCTAssertEqual(try ScrollStitcher.match(previous: next, next: previous, axis: axis).advance, 61)
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: previous, next: next, axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .ambiguousOverlap)
            }
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: next, next: previous, axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .ambiguousOverlap)
            }
        }
    }

    func testBidirectionalRepeatedPatternCandidateBudgetRejectsSafely() throws {
        for axis in ScrollAxis.allCases {
            let base = try axisFrame(axis)
            func repeated(_ offset: Int) throws -> ScrollFrame {
                try replacing(base, axis: axis, along: 0..<140, across: 0..<96) { along, across, _ in
                    UInt8((((along + offset) % 4) * 53 + across * 29) % 256)
                }
            }
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: repeated(0), next: repeated(1), axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .ambiguousOverlap)
            }
        }
    }

    func testBidirectionalRejectsLargeFixedHeadersAndSidebarsInBothDirections() throws {
        for axis in ScrollAxis.allCases {
            for advance in [-45, 45] {
                let previous = try axisFrame(axis, origin: 70)
                let scrolled = try axisFrame(axis, origin: 70 + advance)
                let fixedHeader = try replacing(scrolled, axis: axis, along: 0..<65, across: 0..<96) { along, across, _ in
                    let index = axis == .vertical ? along * previous.width + across : across * previous.width + along
                    return previous.pixels[index]
                }
                let fixedSidebar = try replacing(scrolled, axis: axis, along: 0..<140, across: 0..<70) { along, across, _ in
                    let index = axis == .vertical ? along * previous.width + across : across * previous.width + along
                    return previous.pixels[index]
                }
                for next in [fixedHeader, fixedSidebar] {
                    XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: previous, next: next, axis: axis)) {
                        XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
                    }
                }
            }
        }
    }

    func testBidirectionalRejectsSmallDynamicRegionOutsideSearchSamples() throws {
        for axis in ScrollAxis.allCases {
            for advance in [-55, 55] {
                let previous = try axisFrame(axis, origin: 75)
                let scrolled = try axisFrame(axis, origin: 75 + advance)
                // The sample grid includes overlap row zero, then row three; this pixel
                // at row/column one is only visited by the independent full verification.
                let changedAlong = max(0, -advance) + 1
                let changed = try replacing(scrolled, axis: axis, along: changedAlong..<(changedAlong + 1),
                                            across: 1..<2) { _, _, value in value < 128 ? 255 : 0 }
                XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: previous, next: changed, axis: axis)) {
                    XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
                }
            }
        }
    }

    func testBidirectionalTinyStationaryChangeIsNotMisclassifiedAsDuplicate() throws {
        for axis in ScrollAxis.allCases {
            let previous = try axisFrame(axis)
            let changed = try replacing(previous, axis: axis, along: 1..<2, across: 1..<2) { _, _, value in
                value < 128 ? 255 : 0
            }
            // Global mean is below the duplicate threshold, but a material changed pixel
            // disqualifies zero alignment and must not let retained source be discarded.
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: previous, next: changed, axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
            }
        }
    }

    func testBidirectionalRejectsUnrelatedAndTooDistantFramesInBothDirections() throws {
        for axis in ScrollAxis.allCases {
            let previous = try axisFrame(axis, origin: 250)
            for next in [try axisFrame(axis, origin: 250, seed: 91),
                         try axisFrame(axis, origin: 0), try axisFrame(axis, origin: 500),
                         try axisFrame(axis, origin: 130), try axisFrame(axis, origin: 370)] {
                XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: previous, next: next, axis: axis)) {
                    XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
                }
            }
        }
    }

    func testBidirectionalRejectsFlatAndDuplicateFramesOnBothAxes() throws {
        let flat = try ScrollFrame(width: 96, height: 140, grayscale: .init(repeating: 100, count: 96 * 140))
        let changedFlat = try ScrollFrame(width: 96, height: 140, grayscale: .init(repeating: 103, count: 96 * 140))
        for axis in ScrollAxis.allCases {
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: flat, next: changedFlat, axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .insufficientTexture)
            }
            let textured = try axisFrame(axis)
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: textured, next: textured, axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .duplicate)
            }
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: textured, next: axisFrame(axis, noise: 3), axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .duplicate)
            }
        }
    }

    func testBidirectionalAndAlignedComparisonRejectDimensionAndConfigurationErrors() throws {
        let previous = try frame(), wrongSize = try frame(width: 95)
        for axis in ScrollAxis.allCases {
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: previous, next: wrongSize, axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .differentDimensions)
            }
            XCTAssertThrowsError(try ScrollStitcher.validateAlignedOverlap(previous: previous, previousStart: 0,
                                                                         next: wrongSize, nextStart: 0, length: 1, axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .differentDimensions)
            }
            var config = ScrollStitcher.Configuration()
            config.minimumUniquenessMargin = .infinity
            XCTAssertThrowsError(try ScrollStitcher.matchBidirectional(previous: previous, next: previous, axis: axis, configuration: config)) {
                XCTAssertEqual($0 as? ScrollStitchError, .invalidPixels)
            }
            XCTAssertThrowsError(try ScrollStitcher.validateAlignedOverlap(previous: previous, previousStart: 0,
                                                                         next: previous, nextStart: 0, length: 1, axis: axis,
                                                                         configuration: config)) {
                XCTAssertEqual($0 as? ScrollStitchError, .invalidPixels)
            }
        }
    }

    func testAlignedIntervalsVerifyBothDirectionsWithoutCopyingOrUniqueness() throws {
        for axis in ScrollAxis.allCases {
            for advance in [-55, 55] {
                let previous = try axisFrame(axis, origin: 75)
                let next = try axisFrame(axis, origin: 75 + advance, noise: 3)
                let evidence = try ScrollStitcher.validateAlignedOverlap(previous: previous, previousStart: max(0, advance),
                                                                         next: next, nextStart: max(0, -advance),
                                                                         length: 140 - abs(advance), axis: axis)
                XCTAssertGreaterThan(evidence.meanError, 0)
                XCTAssertLessThanOrEqual(evidence.meanError, 3)
                XCTAssertEqual(evidence.badFraction, 0)
                XCTAssertLessThanOrEqual(evidence.worstBandError, 3)
                XCTAssertNil(evidence.uniquenessMargin)
            }
        }
    }

    func testAlignedOnePixelStripsInspectEveryCrossAxisPixel() throws {
        for axis in ScrollAxis.allCases {
            let previous = try axisFrame(axis, origin: 50), next = try axisFrame(axis, origin: 20)
            let evidence = try ScrollStitcher.validateAlignedOverlap(previous: previous, previousStart: 7,
                                                                     next: next, nextStart: 37, length: 1, axis: axis)
            XCTAssertEqual(evidence.meanError, 0)
            XCTAssertEqual(evidence.worstBandError, 0)
            XCTAssertNil(evidence.uniquenessMargin)
            for cross in [0, 1, 47, 95] {
                let changed = try replacing(next, axis: axis, along: 37..<38, across: cross..<(cross + 1)) { _, _, value in
                    value < 128 ? 255 : 0
                }
                XCTAssertThrowsError(try ScrollStitcher.validateAlignedOverlap(previous: previous, previousStart: 7,
                                                                             next: changed, nextStart: 37, length: 1, axis: axis)) {
                    XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
                }
            }
        }
    }

    func testAlignedFlatOnePixelIntervalNeedsNoTexture() throws {
        let flat = try ScrollFrame(width: 1, height: 1, grayscale: [100])
        let noisy = try ScrollFrame(width: 1, height: 1, grayscale: [103])
        for axis in ScrollAxis.allCases {
            let evidence = try ScrollStitcher.validateAlignedOverlap(previous: flat, previousStart: 0,
                                                                     next: noisy, nextStart: 0, length: 1, axis: axis)
            XCTAssertEqual(evidence.meanError, 3)
            XCTAssertEqual(evidence.worstBandError, 3)
            XCTAssertEqual(evidence.texture, 0)
            XCTAssertNil(evidence.uniquenessMargin)
        }
    }

    func testAlignedComparisonRejectsLocalizedChangesHiddenByMean() throws {
        for axis in ScrollAxis.allCases {
            let original = try axisFrame(axis)
            // Every difference is below the outlier threshold and global mean is under
            // one, but one complete local tile changed too much to discard its source.
            let changed = try replacing(original, axis: axis, along: 0..<18, across: 0..<12) { _, _, value in value + 16 }
            XCTAssertThrowsError(try ScrollStitcher.validateAlignedOverlap(previous: original, previousStart: 0,
                                                                         next: changed, nextStart: 0, length: 140, axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .noOverlap)
            }
        }
    }

    func testAlignedSliceBoundsRejectOverflowAndEmptyIntervals() throws {
        let image = try frame()
        for axis in ScrollAxis.allCases {
            let extent = axis == .vertical ? image.height : image.width
            let invalid = [(Int.min, 0, 1), (0, Int.min, 1), (Int.max, 0, 1), (0, Int.max, 1),
                           (0, 0, Int.max), (0, 0, 0), (0, 0, -1), (extent, 0, 1),
                           (0, extent, 1), (extent - 1, 0, 2), (0, extent - 1, 2)]
            for (previousStart, nextStart, length) in invalid {
                XCTAssertThrowsError(try ScrollStitcher.validateAlignedOverlap(previous: image, previousStart: previousStart,
                                                                             next: image, nextStart: nextStart, length: length, axis: axis)) {
                    XCTAssertEqual($0 as? ScrollStitchError, .invalidPixels)
                }
            }
        }
    }


    func testBidirectionalAndAlignedVerificationPropagateCancellation() async throws {
        let previous = try frame(), next = try frame(y: 40)
        let matching = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScrollStitcher.matchBidirectional(previous: previous, next: next, axis: .vertical)
        }
        do {
            _ = try await matching.value
            XCTFail("Canceled matching must not finish or become a noOverlap error")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let aligned = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScrollStitcher.validateAlignedOverlap(previous: previous, previousStart: 40,
                                                             next: next, nextStart: 0, length: 100, axis: .vertical)
        }
        do {
            _ = try await aligned.value
            XCTFail("Canceled retained-source verification must propagate cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

}
