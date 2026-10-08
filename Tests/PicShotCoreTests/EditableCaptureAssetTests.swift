import XCTest
@testable import PicShotCore

final class EditableCaptureAssetTests: XCTestCase {
    func testSharedSourceCountsOnceAndLegacyHistoryRemainsDecodable() throws {
        let source = raster()
        let editable = descriptor(source, source)
        let record = CaptureRecord(title: "A", filename: source.filename, width: source.width, height: source.height,
                                   byteCount: source.byteCount, editableCapture: editable)
        XCTAssertTrue(record.hasSafeStorageMetadata)
        XCTAssertEqual(record.storedByteCount, source.byteCount + editable.documentByteCount)
        XCTAssertEqual(record.assetFilenames.count, 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "editableCapture")
        let legacy = try JSONDecoder().decode(CaptureRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.editableCapture)
        XCTAssertEqual(legacy.storedByteCount, source.byteCount)
    }
    func testHistoryQuotaIncludesBaseOriginalAndDocumentAndProtectsStars() {
        let source = raster(), base = raster(), current = raster()
        let editable = descriptor(source, base, current: current)
        let entry = CaptureRecord(title: "A", filename: current.filename, width: current.width, height: current.height,
                                  byteCount: current.byteCount, editableCapture: editable)
        XCTAssertEqual(entry.storedByteCount, 400)
        XCTAssertTrue(RetentionPolicy(maxBytes: 399).retained([entry]).isEmpty)
        var star = entry; star.starred = true
        XCTAssertEqual(RetentionPolicy(maxBytes: 399).retained([star, entry]).map(\.id), [star.id])
    }
    func testPinSchemaThreeRejectsDowngradeAndCountsAllAssets() throws {
        let source = raster(), base = raster(), current = raster()
        let entry = PinSessionEntry(original: source.pinAsset, current: current.pinAsset, editableCapture: descriptor(source, base, current: current))
        var index = PinSessionIndex(entries: [entry])
        XCTAssertEqual(index.version, 3)
        XCTAssertNoThrow(try index.validated())
        XCTAssertEqual(entry.assets.count, 3); XCTAssertEqual(entry.assetFilenames.count, 4)
        XCTAssertEqual(entry.storedByteCount, 400)
        XCTAssertFalse(PinSessionPolicy(maxDiskBytes: 399).fits([entry]))
        XCTAssertFalse(PinSessionPolicy(maxPixelCount: 299).fits([entry]))
        XCTAssertTrue(PinSessionPolicy(maxPixelCount: 300, maxDiskBytes: 400).fits([entry]))
        index.version = 2
        XCTAssertThrowsError(try index.validated())
    }
    func testProtectedGroupStillRejectsOversizeEditableReplacement() throws {
        let source = raster(), base = raster(), current = raster()
        let entry = PinSessionEntry(original: source.pinAsset, current: current.pinAsset, editableCapture: descriptor(source, base, current: current))
        var index = PinSessionIndex(entries: [entry]); index.groups[0].isProtected = true
        XCTAssertThrowsError(try PinSessionPolicy(maxDiskBytes: 399).retaining(index)) { XCTAssertEqual($0 as? PinSessionError, .capacityExceeded) }
    }
    func testDescriptorsRejectUnsafePathsAliasedIdentityAndOversizeJSON() {
        let source = raster(), base = raster()
        XCTAssertFalse(EditableCaptureAsset(documentFilename: "../outside.annotations", documentByteCount: 1, original: source, base: base, documentSHA256: String(repeating: "b", count: 64), current: source).isValid)
        XCTAssertFalse(EditableCaptureAsset(documentFilename: UUID().uuidString + ".annotations", documentByteCount: 8_388_609, original: source, base: base, documentSHA256: String(repeating: "b", count: 64), current: source).isValid)
        let identityAlias = EditableRasterAsset(assetID: source.assetID, filename: base.filename, width: 10, height: 10, byteCount: 100, sha256: String(repeating: "a", count: 64))
        XCTAssertFalse(descriptor(source, identityAlias).isValid)
        let fileAlias = EditableRasterAsset(assetID: UUID(), filename: source.filename, width: 10, height: 10, byteCount: 100, sha256: String(repeating: "a", count: 64))
        XCTAssertFalse(descriptor(source, fileAlias).isValid)
    }
    func testPinRejectsEditableOriginalThatDoesNotMatchItsImmutableOriginal() throws {
        let source = raster(), base = raster()
        let entry = PinSessionEntry(original: source.pinAsset, editableCapture: descriptor(base, base))
        XCTAssertThrowsError(try PinSessionIndex(entries: [entry]).validated())
    }
    func testEditableDescriptorsRequireChecksumsButLegacyRasterReferencesDoNot() {
        let source = raster()
        let legacy = EditableRasterAsset(assetID: UUID(), filename: UUID().uuidString + ".png", width: 10, height: 10, byteCount: 100)
        XCTAssertTrue(legacy.isValid); XCTAssertNil(legacy.sha256)
        XCTAssertFalse(EditableCaptureAsset(documentFilename: UUID().uuidString + ".annotations", documentByteCount: 100,
            original: legacy, base: legacy, documentSHA256: String(repeating: "b", count: 64), current: legacy).isValid)
        XCTAssertFalse(EditableCaptureAsset(documentFilename: UUID().uuidString + ".annotations", documentByteCount: 100,
            original: source, base: source, documentSHA256: String(repeating: "z", count: 64), current: source).isValid)
    }
    private func raster() -> EditableRasterAsset {
        EditableRasterAsset(assetID: UUID(), filename: UUID().uuidString + ".png", width: 10, height: 10, byteCount: 100, sha256: String(repeating: "a", count: 64))
    }
    private func descriptor(_ original: EditableRasterAsset, _ base: EditableRasterAsset, current: EditableRasterAsset? = nil) -> EditableCaptureAsset {
        EditableCaptureAsset(documentFilename: UUID().uuidString + ".annotations", documentByteCount: 100, original: original, base: base,
            documentSHA256: String(repeating: "b", count: 64), current: current ?? original)
    }
}
