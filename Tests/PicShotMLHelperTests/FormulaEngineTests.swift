import XCTest
import ImageIO
import CoreGraphics
import PicShotFormulaCore
@testable import PicShotMLHelper

final class FormulaEngineTests: XCTestCase {
    func testStrictArgumentsRejectExtrasDuplicatesAndRelativePaths() throws {
        let valid = ["--mode", "formula", "--model-dir", "/models", "--input", "/input.png", "--output", "/output.json"]
        XCTAssertEqual(try PicShotMLHelper.arguments(valid)["--mode"], "formula")
        XCTAssertThrowsError(try PicShotMLHelper.arguments(valid + ["--remote-code", "yes"]))
        XCTAssertThrowsError(try PicShotMLHelper.arguments(["--mode", "formula", "--mode", "table", "--input", "/i", "--output", "/o"]))
        XCTAssertThrowsError(try PicShotMLHelper.arguments(["--mode", "formula", "--model-dir", "relative", "--input", "/i", "--output", "/o"]))
    }

    func testRGBNormalizationAndNCHWOrder() {
        let tensor = FormulaImagePreprocessor.resizeRGB(rgba: [255, 0, 128, 255], width: 1, height: 1)
        XCTAssertEqual(tensor.count, 3 * 384 * 384)
        XCTAssertEqual(tensor[0], 1)
        XCTAssertEqual(tensor[384 * 384], -1)
        XCTAssertEqual(tensor[2 * 384 * 384], Float(128) / 127.5 - 1, accuracy: 0.000001)
    }

    func testBicubicPreservesWhite() {
        let tensor = FormulaImagePreprocessor.resizeRGB(rgba: Array(repeating: 255, count: 17 * 13 * 4), width: 17, height: 13)
        XCTAssertTrue(tensor.allSatisfy { $0 == 1 })
    }

    /// Explicit opt-in integration test. Unit tests never fetch weights or accept
    /// a hard-coded/fake result. CI must provision the SHA-verified pinned pack.
    func testActualWeightsRecognizeFormulaFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["PICSHOT_FORMULA_MODEL_DIR"] else {
            throw XCTSkip("Set PICSHOT_FORMULA_MODEL_DIR to the verified optional pack to run actual native inference")
        }
        let directory = URL(fileURLWithPath: path)
        try ModelAssetVerifier.verify(.formula, in: directory)
        let cases = [("pythagorean", "x^{2}+y^{2}=z^{2}"), ("energy", "E=mc^{2}"), ("fraction", #"\frac{a+b}{c}"#)]
        for (name, expected) in cases {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let result = try FormulaEngine.recognize(image: image, modelDirectory: directory)
            XCTAssertEqual(result.latex.replacingOccurrences(of: " ", with: ""), expected, result.latex)
            XCTAssertGreaterThan(result.tokenCount, 0)
            XCTAssertLessThan(result.tokenCount, 100)
        }
    }
}
