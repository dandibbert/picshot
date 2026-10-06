import XCTest
import CryptoKit
@testable import PicShotFormulaCore

final class FormulaCoreTests: XCTestCase {
    func testManifestHasImmutableURLsAndExactSizes() {
        let manifest = ModelPackManifest.formula
        XCTAssertEqual(manifest.assets.count, 7)
        XCTAssertEqual(manifest.totalBytes, 119_661_866)
        for asset in manifest.assets {
            XCTAssertEqual(asset.sha256.count, 64)
            XCTAssertTrue(asset.url.absoluteString.contains(ModelPackManifest.formulaRevision))
            XCTAssertEqual(asset.url.scheme, "https")
            XCTAssertFalse(asset.name.contains("/"))
        }
    }

    func testModelLayoutRejectsTraversalAndDuplicateNames() throws {
        let source = URL(string: "https://example.invalid/model")!
        let good = ModelAsset(name: "model.onnx", bytes: 1, sha256: String(repeating: "a", count: 64), url: source)
        let traversal = ModelAsset(name: "../model.onnx", bytes: 1, sha256: good.sha256, url: source)
        XCTAssertThrowsError(try ModelPackManifest(id: "../outside", title: "test", license: "test", source: source, assets: [good]).validateLayout())
        XCTAssertThrowsError(try ModelPackManifest(id: "test", title: "test", license: "test", source: source, assets: [traversal]).validateLayout())
        XCTAssertThrowsError(try ModelPackManifest(id: "test", title: "test", license: "test", source: source, assets: [good, good]).validateLayout())
        XCTAssertNoThrow(try ModelPackManifest.formula.validateLayout())
        XCTAssertNoThrow(try ModelPackManifest.table.validateLayout())
    }

    func testRedirectAllowlistIsScopedAndHTTPSOnly() {
        let formula = ModelPackManifest.formula.assets[0]
        XCTAssertTrue(formula.permitsDownloadURL(URL(string: "https://cas-bridge.xethub.hf.co/signed-model")))
        XCTAssertTrue(formula.permitsDownloadURL(URL(string: "https://us.aws.cdn.hf.co/signed-model")))
        XCTAssertFalse(formula.permitsDownloadURL(URL(string: "https://www.modelscope.cn/model")))
        XCTAssertFalse(formula.permitsDownloadURL(URL(string: "https://huggingface.co.attacker.invalid/model")))
        XCTAssertFalse(formula.permitsDownloadURL(URL(string: "http://huggingface.co/model")))
        XCTAssertFalse(formula.permitsDownloadURL(URL(string: "https://user:secret@huggingface.co/model")))
        let table = ModelPackManifest.table.assets[0]
        XCTAssertTrue(table.permitsDownloadURL(table.url))
        XCTAssertFalse(table.permitsDownloadURL(formula.url))
    }

    func testByteLevelBPEIsNotSentencePiece() throws {
        let json = #"{"decoder":{"type":"ByteLevel"},"model":{"type":"BPE","vocab":{"<pad>":0,"<s>":1,"</s>":2,"x":5,"Ġ=":6,"Ġé":7,"Ã":8,"©":9}},"added_tokens":[{"id":0,"special":true},{"id":1,"special":true},{"id":2,"special":true}]}"#
        let tokenizer = try FormulaTokenizer(data: Data(json.utf8))
        XCTAssertEqual(try tokenizer.decode([1, 5, 6, 5, 2, 5]), "x =x")
        XCTAssertEqual(try tokenizer.decode([8, 9]), "é")
        XCTAssertThrowsError(try tokenizer.decode([999]))
        XCTAssertThrowsError(try tokenizer.decode(Array(repeating: 5, count: 1026)))
    }

    func testRejectsUnsupportedTokenizer() {
        XCTAssertThrowsError(try FormulaTokenizer(data: Data(#"{"decoder":{"type":"Metaspace"},"model":{"type":"Unigram","vocab":{}}}"#.utf8)))
        XCTAssertThrowsError(try FormulaTokenizer(data: Data(repeating: 0, count: 1_000_001)))
    }

    func testVerifierRejectsSameLengthCorruptionAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("original".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let asset = ModelAsset(name: "test.onnx", bytes: Int64(data.count), sha256: hash, url: URL(string: "https://example.invalid/test")!)
        let file = root.appendingPathComponent(asset.name)
        try data.write(to: file)
        XCTAssertNoThrow(try ModelAssetVerifier.verify(asset, at: file))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ModelAssetVerifier.verify(asset, at: link))
        try Data("modified".utf8).write(to: file)
        XCTAssertThrowsError(try ModelAssetVerifier.verify(asset, at: file))
    }

    func testRecognitionResultRoundTrip() throws {
        let expected = FormulaRecognitionResult(latex: #"\frac{a+b}{c}"#, tokenCount: 10, modelID: ModelPackManifest.formula.id)
        XCTAssertEqual(try JSONDecoder().decode(FormulaRecognitionResult.self, from: JSONEncoder().encode(expected)), expected)
    }
}
