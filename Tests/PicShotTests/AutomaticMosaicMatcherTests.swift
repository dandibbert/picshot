import XCTest
import CoreGraphics
import PicShotCore
@testable import PicShot

final class AutomaticMosaicMatcherTests: XCTestCase {
    func testCanonicalRowsPreserveAsymmetricCGImageProviderPixels() throws {
        let width = 13, height = 19
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        func put(_ x: Int, _ y: Int, _ color: [UInt8]) {
            for c in 0..<4 { bytes[(y * width + x) * 4 + c] = color[c] }
        }
        put(3, 1, [255, 0, 0, 255]); put(9, 15, [0, 255, 0, 255])
        put(5, 7, [0, 0, 128, 128])
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let raster = try AutomaticMosaicMatcher.rasterize(image, seed: .init(x: 1, y: 1, width: 5, height: 5))
        XCTAssertEqual(raster.rgba, bytes)
    }

    func testYUpDrawingConvertsToTopLeftOddSourceCoordinates() throws {
        let width = 47, height = 39
        let context = try makeContext(width: width, height: height)
        // These exact channel assertions require an explicit sRGB fixture.
        // Generic RGB colors are color-managed when drawn into the sRGB context.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        // A y-up editor rectangle (5, 27, 7, 9) has top-left source y = 3.
        context.fill(CGRect(x: 5, y: 27, width: 7, height: 9))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 33, y: 1, width: 3, height: 5))
        let image = try XCTUnwrap(context.makeImage())
        let raster = try AutomaticMosaicMatcher.rasterize(image, seed: .init(x: 5, y: 3, width: 7, height: 9))
        XCTAssertEqual(pixel(raster, x: 5, y: 3), [255, 0, 0, 255])
        XCTAssertEqual(pixel(raster, x: 11, y: 11), [255, 0, 0, 255])
        XCTAssertEqual(pixel(raster, x: 5, y: 2), [255, 255, 255, 255])
        XCTAssertEqual(pixel(raster, x: 33, y: 33), [0, 0, 255, 255])
        XCTAssertEqual(pixel(raster, x: 33, y: 38), [255, 255, 255, 255])
    }

    func testServiceFindsNativeDrawnGlyphAtAsymmetricTopLeftCoordinates() async throws {
        let width = 139, height = 97
        let context = try makeContext(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let seed = RepeatedRegionPixelRect(x: 5, y: 7, width: 27, height: 19)
        let candidate = RepeatedRegionPixelRect(x: 87, y: 65, width: 27, height: 19)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.1, blue: 0.6, alpha: 1))
        for region in [seed, candidate] {
            for part in [CGRect(x: 3, y: 2, width: 3, height: 12), CGRect(x: 3, y: 3, width: 16, height: 2),
                         CGRect(x: 15, y: 6, width: 3, height: 10), CGRect(x: 8, y: 11, width: 13, height: 2)] {
                context.fill(CGRect(x: CGFloat(region.x) + part.minX,
                    y: CGFloat(height - region.y) - part.maxY, width: part.width, height: part.height))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let service = AutomaticMosaicMatcher()
        let result = try await service.findMatches(in: image, seed: seed)
        XCTAssertEqual(result.candidates.map(\.rect), [candidate])
        XCTAssertEqual(result.candidates.first?.confidence, 1)
        // A completed job releases global admission for another editor.
        let again = try await AutomaticMosaicMatcher().findMatches(in: image, seed: seed)
        XCTAssertEqual(result, again)
    }

    func testFailedJobReleasesAdmissionAndExpiredJobCannotPublish() async throws {
        let context = try makeContext(width: 31, height: 29)
        let image = try XCTUnwrap(context.makeImage())
        let seed = RepeatedRegionPixelRect(x: 3, y: 5, width: 19, height: 17)
        do {
            _ = try await AutomaticMosaicMatcher(limits: .init(timeLimit: 0)).findMatches(in: image, seed: seed)
            XCTFail("An expired job must not publish a result")
        } catch { XCTAssertEqual(error as? RepeatedRegionMatchError, .budgetExceeded(.time)) }
        do {
            _ = try await AutomaticMosaicMatcher().findMatches(in: image, seed: seed)
            XCTFail("A transparent flat seed must be refused")
        } catch { XCTAssertEqual(error as? RepeatedRegionMatchError, .lowInformation) }
    }

    func testAdmissionRemainsExclusiveUntilRelease() {
        let admission = AutomaticMosaicAdmission()
        XCTAssertTrue(admission.acquire())
        XCTAssertFalse(admission.acquire())
        XCTAssertFalse(admission.acquire())
        admission.release()
        XCTAssertTrue(admission.acquire())
        admission.release()
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setShouldAntialias(false); context.interpolationQuality = .none
        return context
    }
    private func pixel(_ raster: RepeatedRegionRaster, x: Int, y: Int) -> [UInt8] {
        Array(raster.rgba[((y * raster.width + x) * 4)..<((y * raster.width + x) * 4 + 4)])
    }
}
