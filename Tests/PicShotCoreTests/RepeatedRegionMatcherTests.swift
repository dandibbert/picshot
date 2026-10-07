import XCTest
@testable import PicShotCore

final class RepeatedRegionMatcherTests: XCTestCase {
    func testFindsOddCoordinateGlyphsAndNearCopyButRejectsChangedCharacter() throws {
        var image = Pixels(width: 171, height: 95)
        let seed = rect(5, 7)
        image.glyph(at: seed)
        let exact = rect(73, 9), near = rect(101, 65), different = rect(39, 45)
        image.copy(seed, to: exact); image.copy(seed, to: near, delta: 2)
        image.copy(seed, to: different)
        // Change the bottom-left stroke of the final 8-like glyph to background.
        image.set(x: different.x + 17, y: different.y + 11, color: [244, 244, 244, 255])
        let original = image.bytes
        let result = try match(image, seed)
        XCTAssertEqual(result.seed, seed)
        XCTAssertEqual(result.candidates.map(\.rect), [exact, near])
        XCTAssertEqual(result.candidates[0].confidence, 1)
        XCTAssertGreaterThan(result.candidates[1].confidence, 0.9)
        XCTAssertLessThan(result.candidates[1].confidence, 1)
        XCTAssertEqual(result.examinedOrigins, (171 - seed.width + 1) * (95 - seed.height + 1))
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(image.bytes, original, "Matching must never edit the source raster")
    }

    func testSparseGlyphChangeCannotHideInLargeBlankMargins() throws {
        var image = Pixels(width: 217, height: 85)
        let seed = RepeatedRegionPixelRect(x: 3, y: 5, width: 96, height: 64)
        image.glyph(at: rect(seed.x + 29, seed.y + 21))
        let candidate = RepeatedRegionPixelRect(x: 115, y: 9, width: 96, height: 64)
        image.copy(seed, to: candidate)
        image.set(x: candidate.x + 29 + 17, y: candidate.y + 21 + 11, color: [244, 244, 244, 255])
        XCTAssertTrue(try match(image, seed).candidates.isEmpty)
    }

    func testColorChangeAtEqualApproximateLuminanceIsNotARepeat() throws {
        var image = Pixels(width: 101, height: 47)
        let seed = rect(3, 5), candidate = rect(61, 21)
        image.glyph(at: seed, ink: [180, 40, 50, 255])
        image.copy(seed, to: candidate)
        for y in candidate.y..<(candidate.y + candidate.height) {
            for x in candidate.x..<(candidate.x + candidate.width) {
                if image.bytes[(y * image.width + x) * 4] == 180 {
                    image.set(x: x, y: y, color: [30, 85, 50, 255])
                }
            }
        }
        XCTAssertTrue(try match(image, seed).candidates.isEmpty)
    }

    func testVisibleAlphaDifferenceIsRejectedButHiddenRGBIsIgnored() throws {
        var image = Pixels(width: 123, height: 71, background: [0, 0, 0, 0])
        let seed = rect(3, 5), exact = rect(47, 31), different = rect(89, 9)
        image.glyph(at: seed, ink: [60, 20, 30, 128])
        image.copy(seed, to: exact); image.copy(seed, to: different)
        for y in 0..<seed.height {
            for x in 0..<seed.width {
                let i = ((exact.y + y) * image.width + exact.x + x) * 4
                if image.bytes[i + 3] == 0 { image.set(x: exact.x + x, y: exact.y + y, color: [255, 99, 37, 0]) }
            }
        }
        image.set(x: different.x + 17, y: different.y + 11, color: [30, 10, 15, 64])
        let result = try match(image, seed)
        XCTAssertEqual(result.candidates.map(\.rect), [exact])
        XCTAssertEqual(result.candidates.first?.confidence, 1)
    }

    func testRejectsFlatAndHiddenColorOnlyTemplates() throws {
        let flat = Pixels(width: 31, height: 29)
        assertError(.lowInformation) { _ = try self.match(flat, self.rect(3, 5)) }
        var hidden = Pixels(width: 31, height: 29, background: [0, 0, 0, 0])
        hidden.glyph(at: rect(3, 5), ink: [100, 25, 250, 0])
        assertError(.lowInformation) { _ = try self.match(hidden, self.rect(3, 5)) }
    }

    func testInputLimitsRejectBeforeAllocationAndDoNotOverflow() {
        let limits = RepeatedRegionMatchLimits()
        assertError(.imageTooLarge) { try limits.validate(width: Int.max, height: Int.max, seed: self.rect(0, 0)) }
        assertError(.invalidSelection) {
            try limits.validate(width: 100, height: 100, seed: .init(x: Int.max, y: 0, width: 24, height: 16))
        }
        assertError(.invalidSelection) {
            try limits.validate(width: 100, height: 100, seed: .init(x: 0, y: 0, width: 2, height: 4))
        }
        assertError(.templateTooLarge) {
            try limits.validate(width: 1024, height: 1024, seed: .init(x: 0, y: 0, width: 513, height: 20))
        }
        assertError(.budgetExceeded(.scratchMemory)) {
            try RepeatedRegionMatchLimits(maxScratchBytes: 1).validate(width: 31, height: 29, seed: self.rect(3, 5))
        }
        XCTAssertEqual(RepeatedRegionMatchLimits(maxImagePixels: Int.max, maxResults: Int.max, timeLimit: 100).maxImagePixels, 20_000_000)
        XCTAssertEqual(RepeatedRegionMatchLimits(maxResults: Int.max).maxResults, 24)
        XCTAssertEqual(RepeatedRegionMatchLimits(timeLimit: 100).timeLimit, 8)
    }

    func testMalformedRasterIsRejected() {
        assertError(.invalidRaster) { _ = try RepeatedRegionRaster(width: 11, height: 9, rgba: [1, 2, 3]) }
    }

    func testOutputLimitReportsTruncationOnlyAfterCompleteScan() throws {
        var image = Pixels(width: 561, height: 27)
        let seed = rect(1, 5)
        image.glyph(at: seed)
        for x in stride(from: 36, through: 526, by: 35) { image.copy(seed, to: rect(x, 5)) }
        let result = try match(image, seed, limits: .init(maxResults: 3))
        XCTAssertEqual(result.candidates.map(\.rect), [rect(36, 5), rect(71, 5), rect(106, 5)])
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.examinedOrigins, (561 - seed.width + 1) * (27 - seed.height + 1))
    }

    func testRawCandidateAndComparisonBudgetsThrowWithoutPartialResult() throws {
        var image = Pixels(width: 141, height: 29)
        let seed = rect(3, 5)
        image.glyph(at: seed)
        image.copy(seed, to: rect(43, 5)); image.copy(seed, to: rect(83, 5))
        assertError(.budgetExceeded(.candidates)) { _ = try self.match(image, seed, limits: .init(maxRawCandidates: 1)) }
        assertError(.budgetExceeded(.comparisons)) { _ = try self.match(image, seed, limits: .init(maxPixelComparisons: 1)) }
    }

    func testCancellationAtPreparationScanningAndVerification() throws {
        var image = Pixels(width: 91, height: 39)
        let seed = rect(3, 5)
        image.glyph(at: seed); image.copy(seed, to: rect(53, 17))
        let raster = try image.raster()
        for phase in [RepeatedRegionMatcher.Phase.preparing, .scanning, .verifying] {
            var cancelled = false, reached = false
            assertError(.cancelled) {
                _ = try RepeatedRegionMatcher.findMatches(in: raster, seed: seed, isCancelled: { cancelled }, phaseChanged: {
                    if $0 == phase { reached = true; cancelled = true }
                })
            }
            XCTAssertTrue(reached)
        }
    }

    func testDeadlineRejectsExpiredScanWithoutWallClockSleeps() throws {
        var image = Pixels(width: 71, height: 39)
        let seed = rect(3, 5)
        image.glyph(at: seed)
        var now = 100.0
        assertError(.budgetExceeded(.time)) {
            _ = try RepeatedRegionMatcher.findMatches(in: image.raster(), seed: seed, now: { now }, phaseChanged: {
                if $0 == .scanning { now = 109 }
            })
        }
    }

    func testNonMaximumSuppressionAndOrderAreDeterministic() throws {
        var image = Pixels(width: 29, height: 19)
        for y in 0..<image.height {
            for x in 0..<image.width { image.set(x: x, y: y, color: (x + y) % 2 == 0 ? [40, 40, 40, 255] : [244, 244, 244, 255]) }
        }
        let seed = RepeatedRegionPixelRect(x: 9, y: 5, width: 8, height: 8)
        let first = try match(image, seed), second = try match(image, seed)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.candidates.isEmpty)
        let all = [seed] + first.candidates.map(\.rect)
        for a in 0..<all.count {
            for b in (a + 1)..<all.count {
                let overlap = max(0, min(all[a].x + 8, all[b].x + 8) - max(all[a].x, all[b].x)) *
                    max(0, min(all[a].y + 8, all[b].y + 8) - max(all[a].y, all[b].y))
                XCTAssertLessThanOrEqual(Double(overlap) / Double(128 - overlap), 0.3)
            }
        }
        XCTAssertEqual(first.candidates.map(\.rect), first.candidates.map(\.rect).sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y })
    }

    private func rect(_ x: Int, _ y: Int) -> RepeatedRegionPixelRect { .init(x: x, y: y, width: 24, height: 16) }
    private func match(_ pixels: Pixels, _ seed: RepeatedRegionPixelRect, limits: RepeatedRegionMatchLimits = .init()) throws -> RepeatedRegionMatchResult {
        try RepeatedRegionMatcher.findMatches(in: pixels.raster(), seed: seed, limits: limits)
    }
    private func assertError(_ expected: RepeatedRegionMatchError, file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { XCTAssertEqual($0 as? RepeatedRegionMatchError, expected, file: file, line: line) }
    }

    /// Actual RGBA bitmap strokes for a CJK-like character and an 8-like digit;
    /// this fixture exercises matching pixels, not OCR strings or mocked results.
    private struct Pixels {
        let width: Int; let height: Int
        var bytes: [UInt8]
        init(width: Int, height: Int, background: [UInt8] = [244, 244, 244, 255]) {
            self.width = width; self.height = height
            bytes = Array(repeating: background, count: width * height).flatMap { $0 }
        }
        mutating func set(x: Int, y: Int, color: [UInt8]) {
            let offset = (y * width + x) * 4
            for c in 0..<4 { bytes[offset + c] = color[c] }
        }
        mutating func glyph(at rect: RepeatedRegionPixelRect, ink: [UInt8] = [40, 40, 40, 255]) {
            for y in 2...13 {
                for x in 2...21 {
                    let cjk = x <= 11 && ((y == 3 || y == 8 || y == 12) || x == 6 || (y >= 5 && y <= 10 && (x == 2 || x == 11)))
                    let digit = x >= 16 && ((y == 3 || y == 8 || y == 12) || ((x == 17 || x == 21) && y >= 3 && y <= 12))
                    if cjk || digit { set(x: rect.x + x, y: rect.y + y, color: ink) }
                }
            }
        }
        mutating func copy(_ from: RepeatedRegionPixelRect, to: RepeatedRegionPixelRect, delta: Int = 0) {
            let original = bytes
            for y in 0..<from.height {
                for x in 0..<from.width {
                    let i = ((from.y + y) * width + from.x + x) * 4
                    set(x: to.x + x, y: to.y + y, color: (0..<4).map { c in c == 3 ? original[i + c] : UInt8(clamping: Int(original[i + c]) + delta) })
                }
            }
        }
        func raster() throws -> RepeatedRegionRaster { try .init(width: width, height: height, rgba: bytes) }
    }
}
