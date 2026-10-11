import XCTest
@testable import PicShotCore

final class LiveScrollMatcherTests: XCTestCase {
    private func pixel(along: Int, across: Int, seed: UInt64 = 7) -> UInt8 {
        var value = UInt64(along) &* 0x9e3779b185ebca87
        value ^= UInt64(across) &* 0xc2b2ae3d27d4eb4f
        value ^= seed
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        value ^= value >> 31
        return UInt8(value % 216 + 20)
    }

    private func frame(_ axis: ScrollAxis = .vertical, origin: Int = 80, length: Int = 200,
                       cross: Int = 120, header: Int = 0, footer: Int = 0,
                       seed: UInt64 = 7, noise: Int = 0) throws -> ScrollFrame {
        let width = axis == .vertical ? cross : length
        let height = axis == .vertical ? length : cross
        var pixels = [UInt8](repeating: 0, count: width * height)
        for along in 0..<length {
            for across in 0..<cross {
                let fixed = along < header || along >= length - footer
                let value = pixel(along: fixed ? along : along + origin, across: across, seed: fixed ? 99 : seed)
                let jitter = noise == 0 || fixed ? 0 : (along * 13 + across * 17) % (noise * 2 + 1) - noise
                let index = axis == .vertical ? along * width + across : across * width + along
                pixels[index] = UInt8(clamping: Int(value) + jitter)
            }
        }
        return try ScrollFrame(width: width, height: height, grayscale: pixels)
    }

    private func change(_ source: ScrollFrame, axis: ScrollAxis = .vertical,
                        along: Range<Int>, across: Range<Int>, phase: Int = 0) throws -> ScrollFrame {
        var pixels = source.pixels
        for row in along {
            for column in across {
                let index = axis == .vertical ? row * source.width + column : column * source.width + row
                pixels[index] = UInt8((row * 19 + column * 23 + phase * 61) % 256)
            }
        }
        return try ScrollFrame(width: source.width, height: source.height, grayscale: pixels)
    }

    func testSignedMotionAndSinglePixelPrecisionOnBothAxes() throws {
        for axis in ScrollAxis.allCases {
            for displacement in [-49, -1, 1, 49] {
                let result = try LiveScrollMatcher.match(previous: frame(axis),
                    next: frame(axis, origin: 80 + displacement), axis: axis)
                XCTAssertEqual(result.displacement, displacement)
                XCTAssertFalse(result.isStationary)
                XCTAssertEqual(result.contentBounds.rect, LiveScrollPixelRect(x: 0, y: 0,
                    width: axis == .vertical ? 120 : 200, height: axis == .vertical ? 200 : 120))
                XCTAssertEqual(result.quality.verifiedPixels, (200 - abs(displacement)) * 120)
                XCTAssertEqual(result.quality.mismatchedPixels, 0)
                XCTAssertEqual(result.mismatchRegions, [])
                XCTAssertGreaterThanOrEqual(result.quality.supportingAlongBands, 5)
                XCTAssertGreaterThanOrEqual(result.quality.supportingAcrossBands, 3)
                XCTAssertGreaterThanOrEqual(result.quality.uniquenessMargin, 1.25)
                let oldStart = axis == .vertical ? result.previousOverlap.y : result.previousOverlap.x
                let newStart = axis == .vertical ? result.nextOverlap.y : result.nextOverlap.x
                XCTAssertEqual(oldStart - newStart, displacement)
            }
        }
    }

    func testChangingConsecutiveCapturesDoNotRequireIdenticalPairs() throws {
        for axis in ScrollAxis.allCases {
            let positions = [80, 107, 136, 120]
            var accepted = try change(frame(axis, origin: positions[0]), axis: axis,
                                      along: 66..<72, across: 43..<49)
            for index in 1..<positions.count {
                let candidate = try change(frame(axis, origin: positions[index], noise: 2), axis: axis,
                                           along: 65 + index..<71 + index, across: 45..<51, phase: index)
                XCTAssertNotEqual(accepted.pixels, candidate.pixels)
                let result = try LiveScrollMatcher.match(previous: accepted, next: candidate, axis: axis)
                XCTAssertEqual(result.displacement, positions[index] - positions[index - 1])
                XCTAssertGreaterThan(result.quality.mismatchedPixels, 0)
                XCTAssertLessThanOrEqual(result.quality.mismatchFraction, 0.06)
                XCTAssertLessThanOrEqual(result.mismatchRegions.count, 4)
                accepted = candidate
            }
        }
    }

    func testFixedHeaderFooterBoundsForForwardReverseAndOnePixelMotion() throws {
        for axis in ScrollAxis.allCases {
            for displacement in [-29, -1, 1, 29] {
                let result = try LiveScrollMatcher.match(previous: frame(axis, header: 18, footer: 12),
                    next: frame(axis, origin: 80 + displacement, header: 18, footer: 12), axis: axis)
                XCTAssertEqual(result.displacement, displacement)
                let insets = result.contentBounds.insets
                XCTAssertEqual(axis == .vertical ? insets.top : insets.left, 18)
                XCTAssertEqual(axis == .vertical ? insets.bottom : insets.right, 12)
                XCTAssertEqual(axis == .vertical ? result.contentBounds.rect.height : result.contentBounds.rect.width, 170)
                XCTAssertGreaterThanOrEqual(result.contentBounds.confidence, 0.96)
                XCTAssertEqual(result.quality.verifiedPixels, (170 - abs(displacement)) * 120)
            }
        }
    }

    func testLockedBoundsRemainValidAcrossChangingCapturePairs() throws {
        let initial = try frame(header: 18, footer: 12)
        let second = try frame(origin: 111, header: 18, footer: 12)
        let firstMatch = try LiveScrollMatcher.match(previous: initial, next: second, axis: .vertical)
        var config = LiveScrollMatcher.Configuration()
        config.lockedContentBounds = firstMatch.contentBounds.rect
        let third = try frame(origin: 95, header: 18, footer: 12)
        let reverse = try LiveScrollMatcher.match(previous: second, next: third, axis: .vertical, configuration: config)
        XCTAssertEqual(reverse.displacement, -16)
        XCTAssertEqual(reverse.contentBounds, firstMatch.contentBounds)
    }

    func testChangedLockedHeaderIsRejectedWithoutChangingAcceptedFrame() throws {
        let accepted = try frame(header: 18)
        let saved = accepted.pixels
        var config = LiveScrollMatcher.Configuration()
        config.lockedContentBounds = LiveScrollPixelRect(x: 0, y: 18, width: 120, height: 182)
        let bad = try frame(origin: 108, header: 7)
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: accepted, next: bad, axis: .vertical, configuration: config))
        XCTAssertEqual(accepted.pixels, saved)
        let good = try frame(origin: 104, header: 18)
        XCTAssertEqual(try LiveScrollMatcher.match(previous: accepted, next: good, axis: .vertical,
                                                   configuration: config).displacement, 24)
    }

    func testStationaryAndBoundedBlinkReturnZeroWithoutInferringBounds() throws {
        let accepted = try frame()
        for candidate in [accepted, try change(accepted, along: 72..<79, across: 50..<57)] {
            let result = try LiveScrollMatcher.match(previous: accepted, next: candidate, axis: .vertical)
            XCTAssertTrue(result.isStationary)
            XCTAssertEqual(result.displacement, 0)
            XCTAssertEqual(result.contentBounds.confidence, 0)
        }
    }

    func testEveryOverlapPixelIsVerifiedIncludingSingleChangedPixel() throws {
        let next = try change(frame(origin: 103), along: 91..<92, across: 92..<93)
        let result = try LiveScrollMatcher.match(previous: frame(), next: next, axis: .vertical)
        XCTAssertEqual(result.displacement, 23)
        XCTAssertEqual(result.quality.verifiedPixels, 177 * 120)
        XCTAssertEqual(result.quality.mismatchedPixels, 1)
        XCTAssertEqual(result.mismatchRegions.count, 1)
        XCTAssertEqual(result.mismatchRegions[0].rect, LiveScrollPixelRect(x: 92, y: 91, width: 1, height: 1))
        XCTAssertEqual(result.mismatchRegions[0].mismatchedPixels, 1)
    }

    func testMismatchBoxesEncloseOldAndNewCursorPixelsInNextCoordinates() throws {
        let previous = try change(frame(), along: 91..<98, across: 38..<44)
        let next = try change(frame(origin: 103), along: 95..<102, across: 67..<73, phase: 2)
        let result = try LiveScrollMatcher.match(previous: previous, next: next, axis: .vertical)
        XCTAssertEqual(result.displacement, 23)
        XCTAssertEqual(result.mismatchRegions.reduce(0) { $0 + $1.mismatchedPixels }, result.quality.mismatchedPixels)
        for region in result.mismatchRegions {
            XCTAssertGreaterThanOrEqual(region.rect.x, result.nextOverlap.x)
            XCTAssertGreaterThanOrEqual(region.rect.y, result.nextOverlap.y)
            XCTAssertLessThanOrEqual(region.rect.maxX, result.nextOverlap.maxX)
            XCTAssertLessThanOrEqual(region.rect.maxY, result.nextOverlap.maxY)
        }
        XCTAssertTrue(result.mismatchRegions.contains { $0.rect.x <= 38 && $0.rect.maxX >= 44 && $0.rect.y <= 68 && $0.rect.maxY >= 75 })
        XCTAssertTrue(result.mismatchRegions.contains { $0.rect.x <= 67 && $0.rect.maxX >= 73 && $0.rect.y <= 95 && $0.rect.maxY >= 102 })
    }

    func testLargeContentReplacementIsRejectedAndAnchorCanBeRetried() throws {
        let accepted = try frame()
        let saved = accepted.pixels
        let bad = try change(frame(origin: 110), along: 55..<115, across: 30..<90)
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: accepted, next: bad, axis: .vertical))
        XCTAssertEqual(accepted.pixels, saved)
        XCTAssertEqual(try LiveScrollMatcher.match(previous: accepted, next: frame(origin: 101), axis: .vertical).displacement, 21)
    }

    func testThinFullHeightStationarySidebarIsNotAcceptedAsAnimation() throws {
        for axis in ScrollAxis.allCases {
            let previous = try frame(axis)
            let moved = try frame(axis, origin: 107)
            var pixels = moved.pixels
            for along in 0..<200 {
                for across in 0..<3 {
                    let index = axis == .vertical ? along * moved.width + across : across * moved.width + along
                    pixels[index] = previous.pixels[index]
                }
            }
            let next = try ScrollFrame(width: moved.width, height: moved.height, grayscale: pixels)
            XCTAssertThrowsError(try LiveScrollMatcher.match(previous: previous, next: next, axis: axis))
        }
    }

    func testBroadFixedHeaderAndUnrelatedImagesAreRejected() throws {
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: frame(header: 65),
            next: frame(origin: 109, header: 65), axis: .vertical))
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: frame(), next: frame(seed: 888), axis: .vertical))
    }

    func testUniformFixedBarNeedsBroadContrastingBoundaryEvidence() throws {
        func uniformHeader(_ origin: Int) throws -> ScrollFrame {
            let image = try frame(origin: origin)
            var pixels = image.pixels
            pixels.replaceSubrange(0..<1_920, with: repeatElement(UInt8(245), count: 1_920))
            return try ScrollFrame(width: image.width, height: image.height, grayscale: pixels)
        }
        let result = try LiveScrollMatcher.match(previous: uniformHeader(80), next: uniformHeader(109), axis: .vertical)
        XCTAssertEqual(result.displacement, 29)
        XCTAssertEqual(result.contentBounds.insets.top, 16)
        XCTAssertGreaterThanOrEqual(result.contentBounds.confidence, 0.96)
    }

    func testRepeatedOnlyContentCannotChooseAnArbitrarySignedOffset() throws {
        for axis in ScrollAxis.allCases {
            func repeated(_ origin: Int) throws -> ScrollFrame {
                let width = axis == .vertical ? 120 : 200, height = axis == .vertical ? 200 : 120
                var pixels = [UInt8](repeating: 0, count: width * height)
                for along in 0..<200 {
                    for across in 0..<120 {
                        let index = axis == .vertical ? along * width + across : across * width + along
                        pixels[index] = pixel(along: (along + origin) % 12, across: across)
                    }
                }
                return try ScrollFrame(width: width, height: height, grayscale: pixels)
            }
            XCTAssertThrowsError(try LiveScrollMatcher.match(previous: repeated(0), next: repeated(5), axis: axis)) {
                XCTAssertEqual($0 as? ScrollStitchError, .ambiguousOverlap)
            }
        }
    }

    func testOneTexturedCornerCannotValidateMostlyBlankContent() throws {
        func sparse(_ origin: Int) throws -> ScrollFrame {
            var pixels = [UInt8](repeating: 245, count: 120 * 200)
            for y in 45..<65 {
                for x in 12..<25 { pixels[y * 120 + x] = pixel(along: y + origin, across: x) }
            }
            return try ScrollFrame(width: 120, height: 200, grayscale: pixels)
        }
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: sparse(0), next: sparse(1), axis: .vertical))
    }

    func testGlobalLowTextureChangeIsRejected() throws {
        let first = try ScrollFrame(width: 120, height: 200, grayscale: .init(repeating: 80, count: 24_000))
        let next = try ScrollFrame(width: 120, height: 200, grayscale: .init(repeating: 88, count: 24_000))
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: first, next: next, axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .insufficientTexture)
        }
    }

    func testDisplacementOverlapAndOutlierCapsAreEnforced() throws {
        var config = LiveScrollMatcher.Configuration()
        config.maximumDisplacement = 20
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: frame(), next: frame(origin: 111),
                                                         axis: .vertical, configuration: config))
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: frame(), next: frame(origin: 240), axis: .vertical))
        config = .init()
        config.maximumMismatchFraction = 0
        let next = try change(frame(origin: 103), along: 91..<92, across: 92..<93)
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: frame(), next: next, axis: .vertical, configuration: config))
    }

    func testInvalidConfigurationsAndLockedRectanglesFailBeforeWork() throws {
        let initial = try frame(), next = try frame(origin: 102)
        var config = LiveScrollMatcher.Configuration()
        config.minimumOverlapFraction = .nan
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: initial, next: next, axis: .vertical, configuration: config)) {
            XCTAssertEqual($0 as? LiveScrollMatchError, .invalidConfiguration)
        }
        for rect in [LiveScrollPixelRect(x: 1, y: 0, width: 119, height: 200),
                     LiveScrollPixelRect(x: 0, y: 0, width: Int.max, height: 200),
                     LiveScrollPixelRect(x: 0, y: 90, width: 120, height: 110)] {
            config = .init(); config.lockedContentBounds = rect
            XCTAssertThrowsError(try LiveScrollMatcher.match(previous: initial, next: next, axis: .vertical, configuration: config)) {
                XCTAssertEqual($0 as? LiveScrollMatchError, .invalidConfiguration)
            }
        }
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: initial, next: frame(cross: 119), axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .differentDimensions)
        }
    }

    func testCancellationCannotProduceAnAcceptedMatch() async throws {
        let previous = try frame(), next = try frame(origin: 103)
        let task = Task { () throws -> LiveScrollMatch in
            withUnsafeCurrentTask { $0?.cancel() }
            return try LiveScrollMatcher.match(previous: previous, next: next, axis: .vertical)
        }
        do { _ = try await task.value; XCTFail("Cancelled comparison returned an accepted match") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
