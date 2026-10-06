import XCTest
import CoreGraphics
@testable import PicShotFormulaRenderCore

final class FormulaRenderContractTests: XCTestCase {
    func testRequestLimitsCountUTF8NotCharacters() throws {
        XCTAssertNoThrow(try FormulaRenderRequest(latex: "x^2").validate())
        for latex in ["", "   ", String(repeating: "x", count: 8193), String(repeating: "中", count: 3000), "x\0y"] {
            XCTAssertThrowsError(try FormulaRenderRequest(latex: latex).validate())
        }
        for size in [Double.nan, .infinity, 11, 97] { XCTAssertThrowsError(try FormulaRenderRequest(latex: "x", fontSize: size).validate()) }
        for scale in [0, 4] { XCTAssertThrowsError(try FormulaRenderRequest(latex: "x", scale: scale).validate()) }
    }
    func testUnsupportedConvertersAreExplicit() {
        XCTAssertEqual(FormulaRenderCapabilities.available.map(\.rawValue), ["latex", "mathML", "svg", "png", "pdf"])
        XCTAssertTrue(FormulaRenderCapabilities.unavailable.contains("Office OMML"))
        XCTAssertTrue(FormulaRenderCapabilities.unavailable.contains("Typst"))
        XCTAssertTrue(FormulaRenderCapabilities.unavailable.contains("AsciiMath"))
    }
    func testPathCommandsIncludingReflectedQuadraticAndCubic() throws {
        var budget = 100
        let path = try FormulaRenderSVGPath.parse("M0 0L10 0H20V10Q20 20 10 20T0 10C0 5 2 3 5 2S8 0 10 0Z", segmentBudget: &budget)
        XCTAssertFalse(path.isEmpty); XCTAssertEqual(budget, 91)
        XCTAssertEqual(path.boundingBoxOfPath.minX, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 20, accuracy: 0.001)
        XCTAssertEqual(path.boundingBoxOfPath.maxY, 20, accuracy: 0.001)
    }
    func testImplicitLineRelativeAndExponentCoordinates() throws {
        var budget = 20
        let path = try FormulaRenderSVGPath.parse("m1e1,10 20,0v20h-20z", segmentBudget: &budget)
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 20, height: 20))
    }
    func testMalformedPathsAndExhaustionFailClosed() {
        for source in ["MNaN 0", "M1e999 0", "M0 0A1 1 0 0 0 1 1", "M0 0L", "M0 0<script>", "M0 0Z42", "M0 0L1000001 1"] {
            var budget = 100
            XCTAssertThrowsError(try FormulaRenderSVGPath.parse(source, segmentBudget: &budget), source)
        }
        var budget = 2
        XCTAssertThrowsError(try FormulaRenderSVGPath.parse("M0 0L1 1L2 2", segmentBudget: &budget))
    }
}
