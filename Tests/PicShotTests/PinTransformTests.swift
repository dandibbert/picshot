import XCTest
import AppKit
import ImageIO
@testable import PicShot

final class PinTransformTests: XCTestCase {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let green: [UInt8] = [0, 255, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]
    private let yellow: [UInt8] = [255, 255, 0, 255]
    private let cyan: [UInt8] = [0, 255, 255, 255]
    private let magenta: [UInt8] = [255, 0, 255, 255]

    func testClockwiseRotationSwapsExtentAndMovesExactPixels() throws {
        let original = try fixture()
        let rotated = try XCTUnwrap(PinImageRenderer.render(image: original, transform: .rotateClockwise))
        XCTAssertEqual(rotated.width, 3); XCTAssertEqual(rotated.height, 2)
        XCTAssertEqual(try pixels(rotated), [cyan, blue, red, magenta, yellow, green])
        XCTAssertEqual(try pixels(original), [red, green, blue, yellow, cyan, magenta])
    }

    func testHorizontalAndVerticalFlipsAreDistinct() throws {
        let original = try fixture()
        let horizontal = try XCTUnwrap(PinImageRenderer.render(image: original, transform: .flipHorizontal))
        let vertical = try XCTUnwrap(PinImageRenderer.render(image: original, transform: .flipVertical))
        XCTAssertEqual(try pixels(horizontal), [green, red, yellow, blue, magenta, cyan])
        XCTAssertEqual(try pixels(vertical), [cyan, magenta, blue, yellow, red, green])
    }

    func testFourRotationsAndTwoFlipsRestorePixels() throws {
        let original = try fixture()
        var state = PinImageState(image: original)
        for _ in 0..<4 { XCTAssertTrue(state.apply(.rotateClockwise)) }
        XCTAssertEqual(try pixels(state.current), try pixels(original))
        for transform in [PinTransform.flipHorizontal, .flipVertical] {
            XCTAssertTrue(state.apply(transform)); XCTAssertTrue(state.apply(transform))
            XCTAssertEqual(try pixels(state.current), try pixels(original))
        }
    }

    func testGrayscaleChangesColorAndPreservesAlpha() throws {
        let original = try makeImage(width: 2, height: 1, pixels: [red, [0, 128, 0, 128]])
        let result = try XCTUnwrap(PinImageRenderer.render(image: original, transform: .grayscale))
        let resultPixels = try pixels(result)
        XCTAssertEqual(result.width, 2); XCTAssertEqual(result.height, 1)
        for pixel in resultPixels {
            XCTAssertEqual(Double(pixel[0]), Double(pixel[1]), accuracy: 1)
            XCTAssertEqual(Double(pixel[1]), Double(pixel[2]), accuracy: 1)
        }
        XCTAssertGreaterThan(resultPixels[0][0], 0); XCTAssertLessThan(resultPixels[0][0], 255)
        XCTAssertEqual(resultPixels[0][3], 255); XCTAssertEqual(resultPixels[1][3], 128)
    }

    func testInversionPreservesTransparencyAndIsReversible() throws {
        let original = try makeImage(width: 3, height: 1, pixels: [red, [128, 0, 0, 128], [0, 0, 0, 0]])
        let result = try XCTUnwrap(PinImageRenderer.render(image: original, transform: .invert))
        let resultPixels = try pixels(result)
        XCTAssertEqual(resultPixels[0], cyan)
        XCTAssertEqual(resultPixels[1][3], 128); XCTAssertEqual(resultPixels[2][3], 0)
        let twice = try XCTUnwrap(PinImageRenderer.render(image: result, transform: .invert))
        let originalPixels = try pixels(original), roundtripPixels = try pixels(twice)
        for index in 0..<2 {
            for component in 0..<4 {
                XCTAssertEqual(Double(roundtripPixels[index][component]), Double(originalPixels[index][component]), accuracy: 2)
            }
        }
    }

    func testCropUsesBottomLeftPixelsAndClipsToImage() throws {
        let original = try fixture()
        let bottom = try XCTUnwrap(PinImageRenderer.crop(image: original, to: CGRect(x: 0, y: 0, width: 2, height: 1)))
        XCTAssertEqual(bottom.width, 2); XCTAssertEqual(bottom.height, 1)
        XCTAssertEqual(try pixels(bottom), [cyan, magenta])
        let topLeft = try XCTUnwrap(PinImageRenderer.crop(image: original, to: CGRect(x: -1, y: 2, width: 2, height: 3)))
        XCTAssertEqual(topLeft.width, 1); XCTAssertEqual(topLeft.height, 1)
        XCTAssertEqual(try pixels(topLeft), [red])
    }

    func testFractionalCropIncludesTouchedPixelsAndAcceptsReverseDrag() throws {
        let original = try fixture()
        let fractional = try XCTUnwrap(PinImageRenderer.crop(image: original, to: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
        XCTAssertEqual(fractional.width, 1); XCTAssertEqual(fractional.height, 1)
        XCTAssertEqual(try pixels(fractional), [cyan])
        let reverse = try XCTUnwrap(PinImageRenderer.crop(image: original, to: CGRect(x: 2, y: 1, width: -2, height: -1)))
        XCTAssertEqual(try pixels(reverse), [cyan, magenta])
    }

    func testInvalidCropDoesNotReplaceCurrentImage() throws {
        let original = try fixture()
        var state = PinImageState(image: original)
        for rect in [CGRect.zero, CGRect(x: 9, y: 9, width: 3, height: 3),
                     CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)] {
            XCTAssertFalse(state.crop(to: rect))
            XCTAssertTrue(state.current === original)
            XCTAssertFalse(state.isModified)
        }
    }

    func testResetRestoresOriginalAfterRepeatedDestructiveEdits() throws {
        let original = try fixture()
        var state = PinImageState(image: original)
        for _ in 0..<12 { XCTAssertTrue(state.apply(.rotateClockwise)) }
        XCTAssertTrue(state.apply(.invert)); XCTAssertTrue(state.apply(.grayscale))
        XCTAssertTrue(state.crop(to: CGRect(x: 0, y: 0, width: 1, height: 2)))
        XCTAssertTrue(state.isModified); XCTAssertTrue(state.original === original)
        XCTAssertEqual(state.current.width, 1); XCTAssertEqual(state.current.height, 2)
        state.reset()
        XCTAssertTrue(state.current === original); XCTAssertFalse(state.isModified)
        XCTAssertEqual(try pixels(state.current), [red, green, blue, yellow, cyan, magenta])
    }

    func testOriginalAndCurrentPNGExportsRemainIndependent() throws {
        let original = try fixture()
        var state = PinImageState(image: original)
        XCTAssertTrue(state.apply(.rotateClockwise))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("original.png")
        let currentURL = directory.appendingPathComponent("current.png")
        try state.original.writePNG(to: originalURL); try state.current.writePNG(to: currentURL)
        let reopenedOriginal = try XCTUnwrap(CGImage.read(url: originalURL))
        let reopenedCurrent = try XCTUnwrap(CGImage.read(url: currentURL))
        XCTAssertEqual(reopenedOriginal.width, 2); XCTAssertEqual(reopenedOriginal.height, 3)
        XCTAssertEqual(reopenedCurrent.width, 3); XCTAssertEqual(reopenedCurrent.height, 2)
        XCTAssertEqual(try pixels(reopenedOriginal), [red, green, blue, yellow, cyan, magenta])
        XCTAssertEqual(try pixels(reopenedCurrent), [cyan, blue, red, magenta, yellow, green])
        state.reset()
        XCTAssertEqual(try pixels(reopenedCurrent), [cyan, blue, red, magenta, yellow, green])
    }

    func testRasterAllocationLimitRejectsOverflowAndInvalidDimensions() {
        XCTAssertTrue(PinImageRenderer.allowsRasterSize(width: 8_000, height: 4_000))
        XCTAssertFalse(PinImageRenderer.allowsRasterSize(width: 8_001, height: 4_000))
        XCTAssertFalse(PinImageRenderer.allowsRasterSize(width: 0, height: 1))
        XCTAssertFalse(PinImageRenderer.allowsRasterSize(width: 1, height: 0))
        XCTAssertFalse(PinImageRenderer.allowsRasterSize(width: -1, height: 1))
        XCTAssertFalse(PinImageRenderer.allowsRasterSize(width: Int.max, height: Int.max))
        XCTAssertFalse(PinImageRenderer.allowsRasterSize(width: Int.max, height: 1))
    }

    private func fixture() throws -> CGImage {
        // Row order is top to bottom, intentionally asymmetric to catch wrong rotations.
        try makeImage(width: 2, height: 3, pixels: [red, green, blue, yellow, cyan, magenta])
    }

    private func makeImage(width: Int, height: Int, pixels: [[UInt8]]) throws -> CGImage {
        let data = Data(pixels.flatMap { $0 })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [[UInt8]] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var result: [[UInt8]] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                result.append([color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map {
                    UInt8(min(255, max(0, ($0 * 255).rounded())))
                })
            }
        }
        return result
    }
}
