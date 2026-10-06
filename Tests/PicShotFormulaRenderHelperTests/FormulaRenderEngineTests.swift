import XCTest
import Foundation
import CoreGraphics
import ImageIO
import JavaScriptCore
@testable import PicShotFormulaRenderHelper
import PicShotFormulaRenderCore

final class FormulaRenderEngineTests: XCTestCase {
    func testFractionsSuperscriptsAndMatricesAreRealRenderedMath() throws {
        for (latex, element) in [(#"\frac{1}{x^2-1}"#, "mfrac"), (#"x^{2}+y_{1}"#, "msup"),
                                 (#"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#, "mtable"), (#"\sqrt{x+1}"#, "msqrt"),
                                 (#"\boxed{x}"#, "menclose"), (#"\overline{xy}"#, "mover")] {
            let request = FormulaRenderRequest(latex: latex)
            let result = try FormulaRenderEngine.render(request)
            try result.validate(for: request)
            XCTAssertTrue(result.mathML.contains("<\(element)")); XCTAssertTrue(result.svg.contains("<path "))
            XCTAssertFalse(result.svg.contains("<text")); XCTAssertFalse(result.svg.contains("href="))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(result.png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, result.width); XCTAssertEqual(image.height, result.height)
            XCTAssertGreaterThan(try darkPixelCount(image), 50, "The preview must contain real glyph outlines")
            let provider = try XCTUnwrap(CGDataProvider(data: result.pdf as CFData))
            let pdf = try XCTUnwrap(CGPDFDocument(provider)); XCTAssertEqual(pdf.numberOfPages, 1)
            let box = try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox)
            XCTAssertEqual(box.width, result.pointWidth, accuracy: 0.02)
            XCTAssertEqual(box.height, result.pointHeight, accuracy: 0.02)
        }
    }
    func testInvalidSyntaxAndResourceInjectionCannotRender() {
        for latex in [#"\frac{"#, #"\href{https://example.com}{x}"#, #"\require{html}"#,
                      #"\includegraphics{https://example.com/a.png}"#, #"\def\a{\a}\a"#,
                      #"\text{中文}"#] {
            XCTAssertThrowsError(try FormulaRenderEngine.render(FormulaRenderRequest(latex: latex)), latex)
        }
    }
    func testContextHasNoIOBridgeAndInputIsDataNotEvaluatedCode() throws {
        let context = try XCTUnwrap(JSContext())
        for name in ["fetch", "XMLHttpRequest", "WebSocket", "document", "window", "require", "process", "setTimeout"] {
            XCTAssertEqual(context.evaluateScript("typeof \(name)")?.toString(), "undefined")
        }
        let result = try FormulaRenderEngine.render(FormulaRenderRequest(latex: "'); globalThis.compromised = true; //"))
        XCTAssertFalse(result.svg.contains("<script")); XCTAssertTrue(result.svg.contains("<path "))
    }
    func testLargeGeometryAndInvalidRasterScaleAreRejectedBeforeAllocation() {
        XCTAssertThrowsError(try FormulaRenderEngine.render(FormulaRenderRequest(latex: String(repeating: "x", count: 400), fontSize: 96, scale: 3)))
        XCTAssertThrowsError(try FormulaRenderEngine.render(FormulaRenderRequest(latex: "x", scale: 4)))
    }
    func testCorruptResourceFailsDigestValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("globalThis.bad=true".utf8).write(to: directory.appendingPathComponent("FormulaRenderRuntime.js"))
        try Data(String(repeating: "0", count: 64).utf8).write(to: directory.appendingPathComponent("FormulaRenderRuntime.sha256"))
        XCTAssertThrowsError(try FormulaRenderEngine.render(FormulaRenderRequest(latex: "x"), runtimeDirectory: directory))
    }
    func testTransparentPNGPixelsAndScale() throws {
        let one = try FormulaRenderEngine.render(FormulaRenderRequest(latex: "x^2", scale: 1, transparent: true))
        let two = try FormulaRenderEngine.render(FormulaRenderRequest(latex: "x^2", scale: 2, transparent: true))
        XCTAssertEqual(one.pointWidth, two.pointWidth); XCTAssertEqual(two.width, Int(ceil(two.pointWidth * 2)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(one.png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rgba = try pixels(image)
        XCTAssertEqual(rgba[3], 0, "Padded corner should remain transparent")
        XCTAssertGreaterThan(stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count, 10)
    }
    private func darkPixelCount(_ image: CGImage) throws -> Int {
        let data = try pixels(image)
        return stride(from: 0, to: data.count, by: 4).filter { data[$0] < 128 && data[$0 + 3] > 128 }.count
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }
}
