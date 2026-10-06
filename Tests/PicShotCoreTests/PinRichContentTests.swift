import XCTest
@testable import PicShotCore

final class PinRichContentTests: XCTestCase {
    func testLegacyImageSessionStaysVersionOneAndHasNoRichPayload() throws {
        let index = PinSessionIndex(entries: [PinSessionEntry(original: poster())])
        XCTAssertEqual(index.version, 1)
        let restored = try JSONDecoder().decode(PinSessionIndex.self, from: JSONEncoder().encode(index)).validated()
        XCTAssertEqual(restored, index); XCTAssertNil(restored.entries[0].richContent)
        XCTAssertEqual(restored.entries[0].assets.count, 1)
    }
    func testRichSessionRoundTripsAndRequiresVersionTwo() throws {
        let entry = PinSessionEntry(original: poster(), richContent: rich())
        let index = PinSessionIndex(entries: [entry])
        XCTAssertEqual(index.version, 2)
        XCTAssertEqual(try JSONDecoder().decode(PinSessionIndex.self, from: JSONEncoder().encode(index)).validated(), index)
        var invalid = index; invalid.version = 1
        XCTAssertThrowsError(try invalid.validated())
    }
    func testPayloadPathsTypesAndDuplicatesAreStrictlyValidated() throws {
        for name in ["../outside.pinjson", "index.json", "/tmp/a.gif", "reference.gif", UUID().uuidString + ".GIF", UUID().uuidString + ".png"] {
            XCTAssertFalse(PinRichAsset.isSafeFilename(name))
            let invalid = PinRichAsset(kind: .text, filename: name, byteCount: 30)
            XCTAssertThrowsError(try PinSessionIndex(entries: [PinSessionEntry(original: poster(), richContent: invalid)]).validated())
        }
        let shared = rich()
        XCTAssertThrowsError(try PinSessionIndex(entries: [PinSessionEntry(original: poster(), richContent: shared), PinSessionEntry(original: poster(), richContent: shared)]).validated())
        XCTAssertFalse(PinRichAsset(kind: .text, filename: UUID().uuidString + ".gif", byteCount: 30).isValid)
        XCTAssertFalse(PinRichAsset(kind: .files, filename: UUID().uuidString + ".pinjson", byteCount: Int64.max).isValid)
    }
    func testQuotaIncludesPosterPayloadAndAnimationWorkingFrames() {
        let entry = PinSessionEntry(original: poster(), richContent: rich(bytes: 30))
        XCTAssertEqual(entry.assetFilenames.count, 2); XCTAssertEqual(entry.storedByteCount, 40)
        XCTAssertFalse(PinSessionPolicy(maxDiskBytes: 39).fits([entry]))
        XCTAssertTrue(PinSessionPolicy(maxDiskBytes: 40).fits([entry]))
        let animation = PinRichAsset(kind: .animation, filename: UUID().uuidString + ".gif", byteCount: 30, width: 20, height: 10, frameCount: 2)
        let moving = PinSessionEntry(original: poster(), richContent: animation)
        XCTAssertEqual(animation.workingPixelCount, 400)
        XCTAssertFalse(PinSessionPolicy(maxPixelCount: 499).fits([moving]))
        XCTAssertTrue(PinSessionPolicy(maxPixelCount: 500).fits([moving]))
    }
    func testAnimationDimensionsAndOverflowHaveHardBounds() {
        for values in [(Int.max, Int.max, 2), (0, 1, 2), (4_000_001, 1, 2), (2000, 2000, 31), (1, 1, 301), (1, 1, 1)] {
            XCTAssertFalse(PinRichAsset(kind: .animation, filename: UUID().uuidString + ".gif", byteCount: 30,
                                       width: values.0, height: values.1, frameCount: values.2).isValid)
        }
        XCTAssertTrue(PinRichAsset(kind: .animation, filename: UUID().uuidString + ".webp", byteCount: 30, width: 2000, height: 2000, frameCount: 30).isValid)
    }
    func testHTMLPreservesSafeTextStylesAndNeverImportsResourcesOrScripts() throws {
        let value = try XCTUnwrap(PinOfflineHTML.parse("<html><head><style>SECRET</style></head><body><p>Hello <b>bold</b> <em>italic</em></p><script>BAD</script><iframe src='https://example.invalid'>HIDDEN</iframe><img src='file:///secret'><a href='javascript:bad'>visible &amp; safe</a><code>x&lt;y</code></body></html>"))
        XCTAssertTrue(value.importedHTML); XCTAssertTrue(value.plainText.contains("Hello bold italic"))
        XCTAssertTrue(value.plainText.contains("visible & safe")); XCTAssertTrue(value.plainText.contains("x<y"))
        XCTAssertFalse(value.plainText.contains("SECRET")); XCTAssertFalse(value.plainText.contains("BAD")); XCTAssertFalse(value.plainText.contains("HIDDEN"))
        XCTAssertTrue(value.runs.contains { $0.bold && $0.text == "bold" })
        XCTAssertTrue(value.runs.contains { $0.italic && $0.text == "italic" })
        XCTAssertTrue(value.runs.contains { $0.code && $0.text == "x<y" })
    }
    func testHTMLNumericEntitiesAndMalformedMarkupRemainPlainText() throws {
        let content = try XCTUnwrap(PinOfflineHTML.parse("&#65; &#x1F600; &unknown; <b>hi</b><unfinished"))
        XCTAssertEqual(content.plainText, "A 😀 &unknown; hi<unfinished")
        XCTAssertNil(PinOfflineHTML.parse("<script>only hidden</script>"))
        XCTAssertNil(PinOfflineHTML.parse(String(repeating: "x", count: PinTextContent.maximumUTF8Bytes + 1)))
        XCTAssertNil(PinOfflineHTML.parse(String(repeating: "<b>x</b>y", count: 5000)))
    }
    func testTextAndReferencePayloadsAreBoundedAndMutuallyExclusive() {
        XCTAssertFalse(PinTextContent(text: "").isValid)
        XCTAssertFalse(PinTextContent(text: String(repeating: "字", count: 100_000)).isValid)
        XCTAssertFalse(PinRichDocument(files: []).isValid)
        let file = PinFileReference(path: "/missing/private-file", name: "private-file", isDirectory: false)
        XCTAssertTrue(PinRichDocument(files: [file]).isValid, "Metadata validation must not require accessing referenced files")
        XCTAssertFalse(PinRichDocument(files: Array(repeating: file, count: 65)).isValid)
        XCTAssertFalse(PinFileReference(path: "https://example.com", name: "url", isDirectory: false).isValid)
        XCTAssertFalse(PinFileReference(path: "/tmp/x\0y", name: "x", isDirectory: false).isValid)
        var conflicting = PinRichDocument(text: PinTextContent(text: "hello")); conflicting.files = [file]
        XCTAssertFalse(conflicting.isValid)
    }
    func testHEXAndRGBConversionsIncludingAlpha() throws {
        XCTAssertEqual(try XCTUnwrap(PinRGBColor.parse("#abc")).hex, "#AABBCC")
        XCTAssertEqual(try XCTUnwrap(PinRGBColor.parse("#abcd")).hex, "#AABBCCDD")
        XCTAssertEqual(try XCTUnwrap(PinRGBColor.parse("rgb(1, 2, 255)")).hex, "#0102FF")
        XCTAssertEqual(try XCTUnwrap(PinRGBColor.parse("rgba(1, 2, 3, 0.5)")).hex, "#01020380")
        XCTAssertEqual(try XCTUnwrap(PinRGBColor.parse("#FF0000")).rgb, "rgb(255, 0, 0)")
        for text in ["#12", "#ggg", "red", "rgb(256,0,0)", "rgba(0,0,0,nan)", "rgba(0,0,0,2)", "rgb(-1,2,3)"] { XCTAssertNil(PinRGBColor.parse(text), text) }
    }
    private func poster() -> PinRasterAsset { PinRasterAsset(filename: UUID().uuidString + ".png", width: 10, height: 10, byteCount: 10) }
    private func rich(bytes: Int64 = 30) -> PinRichAsset { PinRichAsset(kind: .text, filename: UUID().uuidString + ".pinjson", byteCount: bytes) }
}
