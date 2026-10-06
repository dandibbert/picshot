import XCTest
import CoreGraphics
@testable import PicShotEraseCore

final class SmartEraseRasterTests: XCTestCase {
    func testRasterOrientationAndAlphaRoundTrip() throws {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 64, 0, 64, 128, 4, 5, 6, 255, 7, 8, 9, 255]
        let original = try SmartEraseRaster(width: 2, height: 3, rgba: pixels)
        XCTAssertEqual(try SmartEraseRaster(image: original.image()).rgba, pixels)
    }
    func testCompositingPreservesEveryOutsideByteAndAlpha() throws {
        var pixels = [UInt8](repeating: 0, count: 10 * 8 * 4)
        for index in 0..<(10 * 8) {
            pixels[index * 4] = UInt8(index); pixels[index * 4 + 1] = 64
            pixels[index * 4 + 2] = 22; pixels[index * 4 + 3] = 128
        }
        let original = try SmartEraseRaster(width: 10, height: 8, rgba: pixels)
        var mask = Data(repeating: 0, count: 80); mask[25] = 255; mask[37] = 255
        let prediction = try SmartEraseRaster(width: 800, height: 800, rgba: [UInt8](repeating: 255, count: 800 * 800 * 4))
        let output = try original.compositing(prediction: prediction, mask: mask, crop: .init(x: 0, y: 0, side: 10))
        for index in 0..<80 {
            XCTAssertEqual(output.rgba[index * 4 + 3], original.rgba[index * 4 + 3])
            if mask[index] == 0 {
                XCTAssertEqual(Array(output.rgba[(index * 4)..<(index * 4 + 4)]), Array(original.rgba[(index * 4)..<(index * 4 + 4)]))
            }
        }
        XCTAssertEqual(output.rgba[25 * 4], 128)
    }
    func testPrematureModelEnablingIsForbidden() {
        // User-facing enablement must agree with the recorded native gate,
        // and every enabled download remains an exact immutable byte manifest.
        XCTAssertEqual(SmartEraseModelPack.manifest != nil, SmartEraseModelPack.nativeValidationComplete)
        XCTAssertEqual(SmartEraseModelPack.candidateManifest.totalBytes, 216_647_386)
        if let manifest = SmartEraseModelPack.manifest {
            XCTAssertEqual(Set(manifest.assets.map(\.name)), Set(["Manifest.json", "model.mlmodel", "weight.bin"]))
            for asset in manifest.assets { XCTAssertEqual(asset.sha256.count, 64); XCTAssertGreaterThan(asset.bytes, 0) }
        }
    }
}
