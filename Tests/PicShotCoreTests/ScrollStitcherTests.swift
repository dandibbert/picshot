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
}
