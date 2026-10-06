import XCTest
import AppKit
import Vision
@testable import PicShot

final class RecognizedBarcodeTests: XCTestCase {
    func testNativeSymbologyAndUPCAAliasNeverRewritePayload() {
        XCTAssertEqual(BarcodeSymbology(.qr), .qr); XCTAssertEqual(BarcodeSymbology(.dataMatrix), .dataMatrix)
        XCTAssertEqual(BarcodeSymbology(.pdf417), .pdf417); XCTAssertEqual(BarcodeSymbology(.code128), .code128)
        let upca = code("0012345678905", symbology: .ean13)
        XCTAssertEqual(upca.upcaEquivalent, "012345678905"); XCTAssertEqual(upca.payload, "0012345678905")
        XCTAssertEqual(upca.title, "EAN-13（兼容 UPC-A）")
        XCTAssertNil(code("5901234123457", symbology: .ean13).upcaEquivalent)
        XCTAssertNil(code("0012345678904", symbology: .ean13).upcaEquivalent, "Bad check digit cannot be called UPC-A")
        XCTAssertNil(code("0012345678905", symbology: .qr).upcaEquivalent)
        XCTAssertNil(code("012345678905", symbology: .ean13).upcaEquivalent, "Preserve the format Vision actually returned")
    }
    func testDocumentBoundsResultsWithoutTruncationOrDeduplication() {
        let exact = " leading\n中文 e\u{301} 👩🏽‍💻 trailing "
        let valid = (0..<140).map { _ in code(exact) }
        let document = RecognizedBarcodeDocument(candidates: valid, supportedSymbologies: [.qr], missingTextCount: 2)
        XCTAssertEqual(document.results.count, 128); XCTAssertEqual(document.omissions.resultLimit, 12)
        XCTAssertEqual(document.omissions.missingText, 2); XCTAssertEqual(document.omittedCount, 14)
        XCTAssertEqual(Set(document.results.map(\.id)).count, 128)
        XCTAssertTrue(document.results.allSatisfy { $0.payload == exact })
        XCTAssertTrue(document.statusText.contains("未截短")); XCTAssertTrue(document.statusText.contains("当前 macOS 不支持"))
        XCTAssertEqual(document.unsupportedAcceptanceSymbologies, [.code128, .ean13, .code39, .dataMatrix, .pdf417])
    }
    func testOversizedBinaryAndTotalBudgetHaveDifferentExplicitOmissions() {
        let maxPayload = String(repeating: "a", count: RecognizedBarcodeDocument.maximumPayloadUTF16)
        let candidates = [code(""), code(maxPayload + "x")] + (0..<17).map { _ in code(maxPayload) } + [code("tiny")]
        let document = RecognizedBarcodeDocument(candidates: candidates, supportedSymbologies: RecognizedBarcodeDocument.acceptanceSymbologies)
        XCTAssertEqual(document.results.count, 16); XCTAssertEqual(document.omissions.missingText, 1)
        XCTAssertEqual(document.omissions.oversizedPayload, 1); XCTAssertEqual(document.omissions.payloadBudget, 2)
        XCTAssertEqual(document.omissions.resultLimit, 0)
        XCTAssertEqual(document.results.reduce(0) { $0 + $1.payload.utf16.count }, 65_536)
        XCTAssertTrue(document.results.allSatisfy { $0.payload == maxPayload })
        XCTAssertTrue(document.unsupportedAcceptanceSymbologies.isEmpty)
    }
    func testInvalidGeometryKeepsExactPayloadAndOverlapsPreferSmallestTruePolygon() {
        let a = code("outer", quad: RecognizedTextQuad(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
        let b = code("inner", quad: RecognizedTextQuad(rect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)))
        let c = code("unlocalized", quad: nil)
        let document = RecognizedBarcodeDocument(candidates: [a, b, c], supportedSymbologies: [.qr])
        XCTAssertEqual(document.result(at: CGPoint(x: 0.3, y: 0.3)), 1)
        XCTAssertEqual(document.result(at: CGPoint(x: 0.7, y: 0.7)), 0)
        XCTAssertNil(document.result(at: CGPoint(x: 0.01, y: 0.5)))
        XCTAssertEqual(document.unlocalizedCount, 1); XCTAssertEqual(document.results[2].payload, "unlocalized")
    }
    func testURLPolicyOnlyAllowsExplicitAbsoluteUncredentialedWebURLs() {
        for valid in ["https://example.invalid/a?x=1#part", "http://example.invalid", "HTTPS://example.invalid/%E4%B8%AD"] {
            XCTAssertNotNil(BarcodeURLPolicy.url(for: valid), valid)
        }
        for invalid in ["javascript:alert(1)", "file:///tmp/capture.png", "data:text/html,<script>", "mailto:a@example.invalid", "tel:123", "ftp://example.invalid", "picshot://capture", "//example.invalid", "https:", "https:///path", "https://user:secret@example.invalid", "https://user@example.invalid", " https://example.invalid", "https://example.invalid\n", "https://exam\u{0}ple.invalid", "not a URL"] {
            XCTAssertNil(BarcodeURLPolicy.url(for: invalid), invalid)
        }
    }
    private func code(_ payload: String, symbology: BarcodeSymbology = .qr, quad: RecognizedTextQuad? = nil) -> RecognizedBarcode {
        RecognizedBarcode(symbology: symbology, payload: payload, quad: quad)
    }
}
