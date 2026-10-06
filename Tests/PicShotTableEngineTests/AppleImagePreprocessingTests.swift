#if canImport(CoreGraphics)
import XCTest
import CoreGraphics
import Foundation
@testable import PicShotTableEngine

final class AppleImagePreprocessingTests: XCTestCase {
    func testRasterizationPreservesOrientationAndBGRChannels() throws {
        // Top row red/green; bottom row blue/white. Non-symmetric pixels detect vertical flips.
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                          space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let actual = try SLANetPlus.preprocess(image: image)
        let expected = try SLANetPlus.preprocess(width: 2, height: 2, bgrBytes: [0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255])
        XCTAssertEqual(actual.values, expected.values)
    }
}
#endif
