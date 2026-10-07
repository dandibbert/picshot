import XCTest
@testable import PicShotCore

final class PinLaTeXContentTests: XCTestCase {
    func testSourceOptionsRoundTripAndStrictUnion() throws {
        let source = PinLaTeXContent(source: #"\frac{x^2}{1+y}"#, fontSize: 48, scale: 3, transparent: true)
        let document = PinRichDocument(latex: source)
        XCTAssertTrue(document.isValid)
        XCTAssertEqual(try JSONDecoder().decode(PinRichDocument.self, from: JSONEncoder().encode(document)), document)
        var mixed = document; mixed.text = PinTextContent(text: "wrong union")
        XCTAssertFalse(mixed.isValid)
        var wrong = PinRichDocument(text: PinTextContent(text: "text")); wrong.latex = source
        XCTAssertFalse(wrong.isValid)
    }
    func testBoundsAreUTF8AndOptionsAreFinite() {
        XCTAssertTrue(PinLaTeXContent(source: String(repeating: "x", count: 8_192)).isValid)
        XCTAssertFalse(PinLaTeXContent(source: String(repeating: "x", count: 8_193)).isValid)
        XCTAssertFalse(PinLaTeXContent(source: String(repeating: "界", count: 2_731)).isValid)
        XCTAssertFalse(PinLaTeXContent(source: " \n ").isValid)
        XCTAssertFalse(PinLaTeXContent(source: "x\0").isValid)
        for size in [Double.nan, .infinity, 11, 97] { XCTAssertFalse(PinLaTeXContent(source: "x", fontSize: size).isValid) }
        for scale in [0, 4, Int.max] { XCTAssertFalse(PinLaTeXContent(source: "x", scale: scale).isValid) }
    }
    func testFormulaRasterCountsAgainstSharedQuotaAndManifestBounds() throws {
        let rich = PinRichAsset(kind: .latex, filename: UUID().uuidString + ".pinjson", byteCount: 500)
        let raster = PinRasterAsset(filename: UUID().uuidString + ".png", width: 100, height: 80, byteCount: 1_000)
        let entry = PinSessionEntry(original: raster, richContent: rich)
        XCTAssertTrue(rich.isValid)
        XCTAssertEqual(entry.storedByteCount, 1_500)
        XCTAssertFalse(PinSessionPolicy(maxPixelCount: 7_999).fits([entry]))
        XCTAssertFalse(PinSessionPolicy(maxDiskBytes: 1_499).fits([entry]))
        XCTAssertTrue(PinSessionPolicy(maxPixelCount: 8_000, maxDiskBytes: 1_500).fits([entry]))
        var index = PinSessionIndex(entries: [entry]); XCTAssertNoThrow(try index.validated())
        let excessive = PinRasterAsset(filename: raster.filename, width: 4_097, height: 1, byteCount: 1_000)
        index.entries[0].original = excessive; index.entries[0].current = excessive
        XCTAssertThrowsError(try index.validated())
    }
    func testLegacyDocumentsDecodeWithoutFormulaField() throws {
        let bytes = Data(#"{"kind":"text","text":{"runs":[{"text":"hello","bold":false,"italic":false,"code":false}],"importedHTML":false}}"#.utf8)
        let doc = try JSONDecoder().decode(PinRichDocument.self, from: bytes)
        XCTAssertTrue(doc.isValid); XCTAssertNil(doc.latex)
        XCTAssertThrowsError(try JSONDecoder().decode(PinRichDocument.self, from: Data(#"{"kind":"futureFormula"}"#.utf8)))
    }
}
