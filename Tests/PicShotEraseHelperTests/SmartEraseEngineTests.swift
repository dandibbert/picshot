import XCTest
import CoreVideo
import CoreGraphics
@testable import PicShotEraseHelper
import PicShotEraseCore

final class SmartEraseEngineTests: XCTestCase {
    func testStrictArgumentContractRejectsDuplicatesUnknownAndRelativePaths() throws {
        let args = ["--input", "/private/input.png", "--mask", "/private/mask.bin", "--output", "/private/output.png", "--model-dir", "/private/model"]
        XCTAssertEqual(try PicShotEraseHelper.arguments(args).count, 4)
        XCTAssertThrowsError(try PicShotEraseHelper.arguments(Array(args.dropLast())))
        var invalid = args; invalid[2] = "--input"
        XCTAssertThrowsError(try PicShotEraseHelper.arguments(invalid))
        invalid = args; invalid[1] = "input.png"
        XCTAssertThrowsError(try PicShotEraseHelper.arguments(invalid))
        invalid = args; invalid[6] = "--shell"
        XCTAssertThrowsError(try PicShotEraseHelper.arguments(invalid))
    }
    func testModelBuffersPreserveOrientationAndBinaryMask() throws {
        let raster = try SmartEraseRaster(width: 2, height: 2, rgba: [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 64, 0, 64, 128])
        var mask = [UInt8](repeating: 0, count: 800 * 800); mask[0] = 255
        let buffers = try SmartEraseEngine.buffers(original: raster, mask: mask, crop: .init(x: 0, y: 0, side: 2))
        CVPixelBufferLockBaseAddress(buffers.image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffers.image, .readOnly) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffers.image)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffers.image)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels, count: 4)), [0, 0, 255, 255])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels + 799 * stride, count: 4)), [255, 0, 0, 255])
        CVPixelBufferLockBaseAddress(buffers.mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffers.mask, .readOnly) }
        let m = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffers.mask)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(m[0], 255); XCTAssertEqual(m[1], 0)
    }

    func testBottomEdgeObjectIsMaskedInReplicatedInputPadding() throws {
        var pixels = [UInt8](repeating: 255, count: 1_200 * 200 * 4)
        var sourceMask = Data(repeating: 0, count: 1_200 * 200)
        for x in 8..<12 {
            let index = 199 * 1_200 + x
            pixels[index * 4 + 1] = 0; pixels[index * 4 + 2] = 0
            sourceMask[index] = 255
        }
        let original = try SmartEraseRaster(width: 1_200, height: 200, rgba: pixels)
        let crop = SmartEraseCrop(x: 0, y: 0, side: 512)
        let mask = try SmartEraseMask.modelMask(width: 1_200, height: 200, mask: sourceMask, crop: crop)
        let buffers = try SmartEraseEngine.buffers(original: original, mask: mask, crop: crop)
        CVPixelBufferLockBaseAddress(buffers.image, .readOnly)
        CVPixelBufferLockBaseAddress(buffers.mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffers.image, .readOnly); CVPixelBufferUnlockBaseAddress(buffers.mask, .readOnly) }
        let imageBase = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffers.image)).assumingMemoryBound(to: UInt8.self)
        let maskBase = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffers.mask)).assumingMemoryBound(to: UInt8.self)
        let imageOffset = 799 * CVPixelBufferGetBytesPerRow(buffers.image) + 15 * 4
        XCTAssertEqual(imageBase[imageOffset + 2], 255)
        XCTAssertEqual(imageBase[imageOffset + 1], 0)
        XCTAssertEqual(maskBase[799 * CVPixelBufferGetBytesPerRow(buffers.mask) + 15], 255)
    }

    /// Opt-in real model gate. A missing model is a SKIP, never a pass. CI must
    /// set this variable and inspect the test result before advertising erase.
    func testRealCoreMLRemovesMarkedObjectAndPreservesOutsidePixels() throws {
        guard let path = ProcessInfo.processInfo.environment["PICSHOT_ERASE_MODEL_DIR"] else {
            throw XCTSkip("Real-model validation needs PICSHOT_ERASE_MODEL_DIR; weights are never downloaded by tests.")
        }
        let size = 800
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        var clean = pixels
        var mask = Data(repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size {
            let index = y * size + x
            let texture = 5 * sin(Double(x) / 20) + 4 * sin(Double(y) / 13)
            clean[index * 4] = UInt8(max(0, min(255, 170 + x / 20 + Int(texture))))
            clean[index * 4 + 1] = UInt8(max(0, min(255, 180 + y / 30 + Int(texture))))
            clean[index * 4 + 2] = UInt8(max(0, min(255, 195 + x / 40 + Int(texture))))
            pixels[index * 4] = clean[index * 4]; pixels[index * 4 + 1] = clean[index * 4 + 1]; pixels[index * 4 + 2] = clean[index * 4 + 2]
            if (350..<450).contains(x), (350..<450).contains(y) {
                pixels[index * 4] = 240; pixels[index * 4 + 1] = 20; pixels[index * 4 + 2] = 30
            }
            if (342..<458).contains(x), (342..<458).contains(y) { mask[index] = 255 }
        } }
        let original = try SmartEraseRaster(width: size, height: size, rgba: pixels)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("smart-erase-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try SmartEraseEngine.erase(image: original.image(), mask: mask,
                                               modelDirectory: URL(fileURLWithPath: path), jobDirectory: root)
        let output = try SmartEraseRaster(image: result)
        var beforeError: Double = 0, afterError: Double = 0, changed = 0, samples = 0
        var outsideMismatches = 0, alphaMismatches = 0
        var insideValues = Set<UInt8>()
        for index in 0..<(size * size) {
            if output.rgba[index * 4 + 3] != pixels[index * 4 + 3] { alphaMismatches += 1 }
            if mask[index] == 0 {
                for channel in 0..<4 { if output.rgba[index * 4 + channel] != pixels[index * 4 + channel] { outsideMismatches += 1 } }
            } else {
                if output.rgba[index * 4] != pixels[index * 4] { changed += 1 }
                insideValues.insert(output.rgba[index * 4])
                for channel in 0..<3 {
                    beforeError += abs(Double(pixels[index * 4 + channel]) - Double(clean[index * 4 + channel]))
                    afterError += abs(Double(output.rgba[index * 4 + channel]) - Double(clean[index * 4 + channel]))
                    samples += 1
                }
            }
        }
        XCTAssertEqual(outsideMismatches, 0, "Unpainted bytes must be unchanged")
        XCTAssertEqual(alphaMismatches, 0, "Alpha must be unchanged everywhere")
        XCTAssertGreaterThanOrEqual(changed, 10_000, "Actual marked content must change")
        XCTAssertGreaterThan(insideValues.count, 5, "A flat fill is not an inpainting result")
        XCTAssertLessThan(afterError, beforeError * 0.5, "The red object should be substantially replaced with surrounding texture")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, SmartEraseLimits.seconds)
        print("SMART_ERASE_NATIVE_FIXTURE_METRICS masked MAE before=\(beforeError / Double(samples)) after=\(afterError / Double(samples)) changed=\(changed)")
    }
}
