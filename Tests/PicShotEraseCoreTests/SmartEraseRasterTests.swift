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
    func testPNGReadOwnsPixelsAfterSourceAndDirectoryAreDeleted() throws {
        let width = 800, height = 600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            pixels[offset] = UInt8((x * 13 + y * 7) % 256)
            pixels[offset + 1] = UInt8((x * 3 + y * 17) % 256)
            pixels[offset + 2] = UInt8((x * 19 + y * 5) % 256)
        } }
        let original = try SmartEraseRaster(width: width, height: height, rgba: pixels)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smart-erase-png-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("output.png")
        try SmartEraseRaster.png(original.image()).write(to: file)
        let loaded = try autoreleasepool { try SmartEraseRaster.readImage(file) }
        try FileManager.default.removeItem(at: root)
        // Both the ImageIO source/autorelease pool and the entire on-disk job
        // have gone away before any consumer draws the returned CGImage.
        for _ in 0..<3 {
            let actual = try autoreleasepool { try SmartEraseRaster(image: loaded) }
            XCTAssertEqual(actual.width, width); XCTAssertEqual(actual.height, height)
            let mismatches = zip(actual.rgba, pixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            XCTAssertEqual(mismatches, 0, "Deleted backing files must not turn decoded pixels transparent/black")
        }
    }

    func testParentRestoresExactOutsidePixelsAndAllAlphaAfterPNGInterchange() throws {
        let width = 32, height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var mask = Data(repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let alpha = index % 256
            pixels[index * 4] = UInt8((index * 17) % (alpha + 1))
            pixels[index * 4 + 1] = UInt8((index * 31) % (alpha + 1))
            pixels[index * 4 + 2] = UInt8((index * 7) % (alpha + 1))
            pixels[index * 4 + 3] = UInt8(alpha)
            if index % 4 == 0 { mask[index] = 255 }
        }
        let original = try SmartEraseRaster(width: width, height: height, rgba: pixels)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smart-erase-alpha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("result.png")
        try SmartEraseRaster.png(original.image()).write(to: file)
        var incoming = try SmartEraseRaster(image: SmartEraseRaster.readImage(file))
        // Simulate roundtrip error even if this ImageIO version happens to
        // preserve a particular sample exactly, including altered alpha.
        for index in 0..<(width * height) {
            incoming.rgba[index * 4] = 0
            incoming.rgba[index * 4 + 1] = 0
            incoming.rgba[index * 4 + 2] = 0
            incoming.rgba[index * 4 + 3] = 0
        }
        let restored = try original.applyingMaskedResult(incoming, mask: mask)
        for index in 0..<(width * height) {
            XCTAssertEqual(restored.rgba[index * 4 + 3], pixels[index * 4 + 3])
            if mask[index] == 0 {
                for channel in 0..<4 { XCTAssertEqual(restored.rgba[index * 4 + channel], pixels[index * 4 + channel]) }
            } else {
                XCTAssertEqual(restored.rgba[index * 4], 0)
                XCTAssertEqual(restored.rgba[index * 4 + 1], 0)
                XCTAssertEqual(restored.rgba[index * 4 + 2], 0)
            }
        }
    }

}
