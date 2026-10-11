import Foundation
import XCTest
@testable import PicShotCore

/// Native AppKit article luminance from exact219's owned-window evidence. The fixture
/// preserves ordinary text/white margins; it contains no synthetic alignment texture.
final class LiveScrollPlainTextMatcherTests: XCTestCase {
    private let width = 640, height = 480, header = 36

    private func article() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LiveScrollPlainTextLuminance.rle.b64")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let payload = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let encoded = [UInt8](payload)
        guard encoded.count >= 12, Array(encoded[0..<4]) == Array("PSG1".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func uint32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(encoded[offset + $1]) << ($1 * 8)) }
        }
        guard uint32(4) == width, uint32(8) == 1200, (encoded.count - 12) % 3 == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * 1200)
        for index in stride(from: 12, to: encoded.count, by: 3) {
            let count = Int(encoded[index]) | (Int(encoded[index + 1]) << 8)
            guard count > 0, count <= width * 1200 - pixels.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            pixels.append(contentsOf: repeatElement(encoded[index + 2], count: count))
        }
        guard pixels.count == width * 1200 else { throw CocoaError(.fileReadCorruptFile) }
        return pixels
    }

    private func frame(_ article: [UInt8], origin: Int, axis: ScrollAxis = .vertical) throws -> ScrollFrame {
        let pixels = Array(article[0..<header * width])
            + Array(article[(header + origin) * width..<(height + origin) * width])
        if axis == .vertical { return try ScrollFrame(width: width, height: height, grayscale: pixels) }
        var transposed = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width { transposed[x * height + y] = pixels[y * width + x] }
        }
        return try ScrollFrame(width: height, height: width, grayscale: transposed)
    }

    func testNativeArticleForwardAndReversePairsHaveUniqueExactOverlap() throws {
        let pixels = try article()
        let origins = [0, 60, 116, 176, 236, 296, 356, 416, 472, 532, 592, 652, 708, 720]
        for axis in ScrollAxis.allCases {
            var config = LiveScrollMatcher.Configuration()
            let positions = origins + Array(origins.dropLast().reversed())
            for (previous, next) in zip(positions, positions.dropFirst()) {
                let result = try LiveScrollMatcher.match(previous: frame(pixels, origin: previous, axis: axis),
                    next: frame(pixels, origin: next, axis: axis), axis: axis, configuration: config)
                XCTAssertEqual(result.displacement, next - previous)
                XCTAssertEqual(axis == .vertical ? result.contentBounds.insets.top : result.contentBounds.insets.left, header)
                XCTAssertEqual(result.quality.verifiedPixels, (height - header - abs(next - previous)) * width)
                XCTAssertEqual(result.quality.mismatchedPixels, 0)
                XCTAssertGreaterThanOrEqual(result.quality.supportingTiles, 12)
                XCTAssertGreaterThanOrEqual(result.quality.supportingAlongBands, 5)
                XCTAssertGreaterThanOrEqual(result.quality.supportingAcrossBands, 3)
                XCTAssertGreaterThanOrEqual(result.quality.uniquenessMargin, 1.25)
                config.lockedContentBounds = result.contentBounds.rect
            }
        }
    }

    func testAmbiguousBlankExtensionDoesNotBecomePermanentHeader() throws {
        let pixels = try article()
        for axis in ScrollAxis.allCases {
            let initial = try frame(pixels, origin: 320, axis: axis)
            XCTAssertThrowsError(try LiveScrollMatcher.match(previous: initial,
                next: frame(pixels, origin: 328, axis: axis), axis: axis)) {
                XCTAssertEqual($0 as? LiveScrollMatchError, .uncertainContentBounds)
            }
            // A later changing frame exposes the actual boundary without guessed rows.
            let result = try LiveScrollMatcher.match(previous: initial,
                next: frame(pixels, origin: 336, axis: axis), axis: axis)
            XCTAssertEqual(result.displacement, 16)
            XCTAssertEqual(axis == .vertical ? result.contentBounds.insets.top : result.contentBounds.insets.left, header)
        }
    }

    func testStartingMidArticleCanExtendAboveAndBelowWithExactPixelUnion() throws {
        let pixels = try article()
        let initialOrigin = 320
        var previousOrigin = initialOrigin
        var lower = initialOrigin, upper = initialOrigin + height - header
        var body = Array(pixels[(header + lower) * width..<(header + upper) * width])
        var config = LiveScrollMatcher.Configuration()
        let positions = [336, 304, 248, 188, 128, 68, 8, 0, 60, 120, 180, 240, 300, 360, 420, 480, 540, 600, 660, 720]
        for origin in positions {
            let next = try frame(pixels, origin: origin)
            let result = try LiveScrollMatcher.match(previous: frame(pixels, origin: previousOrigin),
                next: next, axis: .vertical, configuration: config)
            XCTAssertEqual(result.displacement, origin - previousOrigin)
            XCTAssertEqual(result.contentBounds.insets.top, header)
            config.lockedContentBounds = result.contentBounds.rect
            if origin < lower {
                body = Array(next.pixels[header * width..<(header + lower - origin) * width]) + body
                lower = origin
            }
            if origin + height - header > upper {
                let added = origin + height - header - upper
                body += next.pixels[(height - added) * width..<height * width]
                upper = origin + height - header
            }
            XCTAssertEqual(body, Array(pixels[(header + lower) * width..<(header + upper) * width]))
            previousOrigin = origin
        }
        XCTAssertEqual(lower, 0)
        XCTAssertEqual(upper, 1164)
        XCTAssertEqual(Array(pixels[0..<header * width]) + body, pixels)
    }

    func testPlainTextGapRejectsAndRetainedAnchorReconnects() throws {
        let pixels = try article()
        let initial = try frame(pixels, origin: 0)
        var config = LiveScrollMatcher.Configuration()
        config.lockedContentBounds = LiveScrollPixelRect(x: 0, y: header, width: width, height: height - header)
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: initial, next: frame(pixels, origin: 720),
            axis: .vertical, configuration: config))
        let recovered = try LiveScrollMatcher.match(previous: initial, next: frame(pixels, origin: 60),
            axis: .vertical, configuration: config)
        XCTAssertEqual(recovered.displacement, 60)
        XCTAssertEqual(recovered.quality.mismatchedPixels, 0)
    }

    func testRepeatedNativeParagraphsRemainAmbiguousAndBlankPageCannotProveMotion() throws {
        let pixels = try article()
        let paragraph = Array(pixels[header * width..<(header + 320) * width])
        let repeated = Array(pixels[0..<header * width]) + Array(repeating: paragraph, count: 4).flatMap { $0 }
        var config = LiveScrollMatcher.Configuration()
        config.lockedContentBounds = LiveScrollPixelRect(x: 0, y: header, width: width, height: height - header)
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: frame(repeated, origin: 0),
            next: frame(repeated, origin: 60), axis: .vertical, configuration: config)) {
            XCTAssertEqual($0 as? ScrollStitchError, .ambiguousOverlap)
        }
        let blank = try ScrollFrame(width: width, height: height, grayscale: .init(repeating: 255, count: width * height))
        let changed = try ScrollFrame(width: width, height: height, grayscale: .init(repeating: 247, count: width * height))
        XCTAssertThrowsError(try LiveScrollMatcher.match(previous: blank, next: changed, axis: .vertical)) {
            XCTAssertEqual($0 as? ScrollStitchError, .insufficientTexture)
        }
    }
}
