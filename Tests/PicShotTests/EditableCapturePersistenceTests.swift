import AppKit
import CryptoKit
import XCTest
import PicShotCore
@testable import PicShot

final class EditableCapturePersistenceTests: XCTestCase {
    enum Injected: Error { case write }

    @MainActor func testHistoryReopensLayersSourceBaseTimestampAndCurrentWithoutCachingRasters() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let store = HistoryStore(directory: directory)
        let record = try store.add(rendered(payload), capturedAt: payload.document.capturedAt, editable: payload)
        let descriptor = try XCTUnwrap(record.editableCapture)
        XCTAssertEqual(record.assetFilenames.count, 4)
        XCTAssertEqual(record.storedByteCount, try fileBytes(record.assetFilenames, in: directory))
        let reopened = HistoryStore(directory: directory)
        XCTAssertNil(reopened.loadError)
        let restored = try XCTUnwrap(reopened.editablePayload(for: record))
        XCTAssertEqual(try encoded(restored), try encoded(payload))
        XCTAssertEqual(restored.originalImage.width, 10); XCTAssertEqual(restored.baseImage.width, 8)
        let savedCurrent = try XCTUnwrap(reopened.image(for: record))
        XCTAssertEqual(savedCurrent.width, 8)
        XCTAssertEqual(try pixels(savedCurrent), try pixels(rendered(restored)))
        XCTAssertEqual(reopened.records.first?.capturedAt, payload.document.capturedAt)
        XCTAssertNotEqual(descriptor.original.filename, descriptor.base.filename)
    }

    @MainActor func testSharedOriginalBaseAndCurrentUseOnePNG() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(annotated: false)
        let history = HistoryStore(directory: directory)
        let record = try history.add(payload.originalImage, editable: payload)
        XCTAssertEqual(record.assetFilenames.count, 2)
        let restored = try XCTUnwrap(history.editablePayload(for: record))
        XCTAssertTrue(restored.originalImage === restored.baseImage)
        let pinDirectory = directory.appendingPathComponent("pins")
        let pins = try PinSessionStore(directory: pinDirectory)
        let pin = try pins.add(originalImage: payload.originalImage, currentImage: payload.originalImage, editable: payload)
        XCTAssertEqual(pin.assetFilenames.count, 2); XCTAssertEqual(pin.assets.count, 1)
        XCTAssertEqual(pin.storedByteCount, try fileBytes(pin.assetFilenames, in: pinDirectory))
    }

    @MainActor func testPinRoundTripPreservesGroupsPresentationArchiveAndEditableSource() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let store = try PinSessionStore(directory: directory)
        let group = try store.createGroup(name: "参考")
        let presentation = PinPresentation(opacity: 0.5, zoom: 2, clickThrough: true, locked: true)
        let entry = try store.add(originalImage: payload.originalImage, currentImage: rendered(payload),
                                  groupID: group.id, presentation: presentation, editable: payload)
        try store.setGroupProtected(id: group.id, protected: true)
        try store.archive(id: entry.id)
        let reopened = try PinSessionStore(directory: directory)
        let saved = try XCTUnwrap(reopened.entry(id: entry.id))
        XCTAssertEqual(reopened.index.version, 3); XCTAssertEqual(saved.presentation, presentation)
        XCTAssertEqual(saved.groupID, group.id); XCTAssertFalse(saved.isVisible); XCTAssertNotNil(saved.archiveSequence)
        XCTAssertEqual(saved.original.sha256, entry.original.sha256); XCTAssertNotNil(saved.original.sha256)
        XCTAssertEqual(saved.current.sha256, entry.current.sha256); XCTAssertNotNil(saved.current.sha256)
        let restored = try XCTUnwrap(reopened.editablePayload(id: entry.id))
        XCTAssertEqual(try encoded(restored), try encoded(payload))
        XCTAssertEqual(reopened.image(id: entry.id, original: true)?.width, 10)
        let savedCurrent = try XCTUnwrap(reopened.image(id: entry.id))
        XCTAssertEqual(savedCurrent.width, 8)
        XCTAssertEqual(try pixels(savedCurrent), try pixels(rendered(restored)))
    }

    @MainActor func testEveryHistoryWriteBoundaryRollsBackIndexSourceAndNewAssets() throws {
        for boundary in [CaptureAssetWritePoint.rasterWritten, .documentWritten, .beforeIndexCommit] {
            let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let payload = try fixture(distinctBase: true)
            let store = HistoryStore(directory: directory)
            let record = try store.add(rendered(payload), editable: payload)
            let before = try snapshot(directory)
            store.failureInjector = { if $0 == boundary { throw Injected.write } }
            XCTAssertThrowsError(try store.replaceImage(rendered(payload), id: record.id, editable: payload))
            XCTAssertEqual(store.records, [record]); XCTAssertEqual(try snapshot(directory), before)
            store.failureInjector = nil
            try store.replaceImage(rendered(payload), id: record.id, editable: payload)
            let updated = try XCTUnwrap(store.records.first)
            XCTAssertEqual(updated.id, record.id); XCTAssertEqual(updated.editableCapture?.original, record.editableCapture?.original)
        }
    }

    @MainActor func testEveryPinWriteBoundaryPreservesOriginalCurrentDocumentAndAllowsRetry() throws {
        for boundary in [CaptureAssetWritePoint.rasterWritten, .documentWritten, .beforeIndexCommit] {
            let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let payload = try fixture(distinctBase: true)
            let store = try PinSessionStore(directory: directory)
            let pin = try store.add(originalImage: payload.originalImage, currentImage: rendered(payload), editable: payload)
            let beforeIndex = store.index, beforeFiles = try snapshot(directory)
            store.failureInjector = { if $0 == boundary { throw Injected.write } }
            XCTAssertThrowsError(try store.replaceImage(rendered(payload), id: pin.id, editable: payload))
            XCTAssertEqual(store.index, beforeIndex); XCTAssertEqual(try snapshot(directory), beforeFiles)
            store.failureInjector = nil
            try store.replaceImage(rendered(payload), id: pin.id, editable: payload)
            XCTAssertEqual(store.entry(id: pin.id)?.original, pin.original)
        }
    }

    @MainActor func testPartialSourceWriteFailureRollsBackAllNewRasters() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let store = HistoryStore(directory: directory)
        let before = try snapshot(directory)
        var count = 0
        store.failureInjector = { if $0 == .rasterWritten { count += 1; if count == 2 { throw Injected.write } } }
        XCTAssertThrowsError(try store.add(rendered(payload), editable: payload))
        XCTAssertEqual(count, 2); XCTAssertTrue(store.records.isEmpty); XCTAssertEqual(try snapshot(directory), before)
    }

    @MainActor func testHistoryAndPinQuotasIncludeJSONAndPreserveProtectedRecords() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture()
        let history = HistoryStore(directory: directory, policy: RetentionPolicy(maxItems: 1))
        let first = try history.add(rendered(payload), editable: payload); try history.toggleStar(first)
        let before = try snapshot(directory)
        XCTAssertThrowsError(try history.add(rendered(payload), editable: payload))
        XCTAssertEqual(try snapshot(directory), before)
        let other = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: other) }
        let byteLimited = HistoryStore(directory: other, policy: RetentionPolicy(maxBytes: first.byteCount + 1))
        XCTAssertThrowsError(try byteLimited.add(rendered(payload), editable: payload))
        XCTAssertTrue(byteLimited.records.isEmpty)
        let pins = try PinSessionStore(directory: other.appendingPathComponent("pins"),
            policy: PinSessionPolicy(maxDiskBytes: first.byteCount + 1))
        XCTAssertThrowsError(try pins.add(originalImage: payload.originalImage, currentImage: rendered(payload), editable: payload))
        XCTAssertTrue(pins.entries.isEmpty)
    }

    @MainActor func testCorruptDocumentThrowsWithoutDroppingCurrentOrDeletingOriginal() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let pins = try PinSessionStore(directory: directory)
        let entry = try pins.add(originalImage: payload.originalImage, currentImage: rendered(payload), editable: payload)
        let editable = try XCTUnwrap(entry.editableCapture)
        try Data(repeating: 0x78, count: Int(editable.documentByteCount)).write(to: directory.appendingPathComponent(editable.documentFilename))
        let before = try snapshot(directory)
        let reopened = try PinSessionStore(directory: directory)
        XCTAssertEqual(reopened.entries.map(\.id), [entry.id])
        XCTAssertThrowsError(try reopened.editablePayload(id: entry.id))
        XCTAssertNotNil(reopened.image(id: entry.id)); XCTAssertNotNil(reopened.image(id: entry.id, original: true))
        XCTAssertEqual(try snapshot(directory), before)
    }

    @MainActor func testOversizedOrSymlinkedDocumentNeverChangesIndexOrExternalFile() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture()
        let history = HistoryStore(directory: directory)
        let record = try history.add(rendered(payload), editable: payload)
        let editable = try XCTUnwrap(record.editableCapture), target = directory.appendingPathComponent(editable.documentFilename)
        let indexBefore = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        try Data(repeating: 0x78, count: Int(EditableCaptureAsset.maximumDocumentBytes) + 1).write(to: target)
        let tooLarge = HistoryStore(directory: directory)
        XCTAssertNotNil(tooLarge.loadError)
        XCTAssertThrowsError(try tooLarge.add(rendered(payload)))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), indexBefore)
        let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("external data".utf8).write(to: outside)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        let linked = HistoryStore(directory: directory)
        XCTAssertNotNil(linked.loadError); XCTAssertThrowsError(try history.editablePayload(for: record))
        XCTAssertEqual(try String(contentsOf: outside), "external data")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), indexBefore)
    }

    @MainActor func testMissingBaseAndFailedSaveRetainReadablePinOriginalAndCurrent() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let pins = try PinSessionStore(directory: directory)
        let entry = try pins.add(originalImage: payload.originalImage, currentImage: rendered(payload), editable: payload)
        let editable = try XCTUnwrap(entry.editableCapture)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(editable.base.filename))
        let reopened = try PinSessionStore(directory: directory)
        XCTAssertNotNil(reopened.entry(id: entry.id)); XCTAssertThrowsError(try reopened.editablePayload(id: entry.id))
        XCTAssertNotNil(reopened.image(id: entry.id)); XCTAssertNotNil(reopened.image(id: entry.id, original: true))
        // Removing the source must fail a subsequent replacement before index commit.
        try FileManager.default.removeItem(at: directory.appendingPathComponent(editable.original.filename))
        let before = try snapshot(directory), beforeIndex = reopened.index
        XCTAssertThrowsError(try reopened.replaceImage(rendered(payload), id: entry.id, editable: payload))
        XCTAssertEqual(reopened.index, beforeIndex); XCTAssertEqual(try snapshot(directory), before)
    }

    @MainActor func testLegacyHistoryAndPinsStayExplicitlyFlattenedAndResetClearsDocument() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let history = HistoryStore(directory: directory)
        let legacy = try history.add(payload.originalImage)
        XCTAssertNil(try HistoryStore(directory: directory).editablePayload(for: legacy))
        let pins = try PinSessionStore(directory: directory.appendingPathComponent("pins"))
        let old = try pins.add(image: payload.originalImage)
        XCTAssertNil(try pins.editablePayload(id: old.id))
        let entry = try pins.add(originalImage: payload.originalImage, currentImage: rendered(payload), editable: payload)
        try pins.resetImage(id: entry.id)
        let reset = try XCTUnwrap(pins.entry(id: entry.id))
        XCTAssertNil(reset.editableCapture); XCTAssertEqual(reset.current, reset.original)
        XCTAssertEqual(reset.original.sha256, entry.original.sha256); XCTAssertNotNil(reset.original.sha256)
        for filename in entry.assetFilenames where filename != reset.original.filename {
            XCTAssertFalse(FileManager.default.fileExists(atPath: pins.directory.appendingPathComponent(filename).path))
        }
    }

    @MainActor func testCrashJournalCleansOnlyUncommittedOwnedFilesAndRetainsCommittedSource() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture()
        let history = HistoryStore(directory: directory)
        let record = try history.add(rendered(payload), editable: payload)
        let orphan = UUID().uuidString + ".png", unrelated = UUID().uuidString + ".png"
        try Data("partial".utf8).write(to: directory.appendingPathComponent(orphan))
        try Data("user-owned".utf8).write(to: directory.appendingPathComponent(unrelated))
        let journal = directory.appendingPathComponent(".capture-transaction-" + String(orphan.prefix(36)) + ".json")
        try JSONEncoder().encode([orphan, record.filename]).write(to: journal)
        let reopened = HistoryStore(directory: directory)
        XCTAssertNil(reopened.loadError); XCTAssertNotNil(reopened.image(for: record))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(orphan).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(unrelated)), "user-owned")
    }

    @MainActor func testMetadataAndOutputMismatchFailuresAreTransactional() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture()
        let history = HistoryStore(directory: directory)
        let record = try history.add(rendered(payload), editable: payload)
        let before = try snapshot(directory)
        history.failureInjector = { if $0 == .beforeIndexCommit { throw Injected.write } }
        XCTAssertThrowsError(try history.toggleStar(record))
        XCTAssertThrowsError(try history.updateText("new text", id: record.id))
        XCTAssertEqual(history.records, [record]); XCTAssertEqual(try snapshot(directory), before)
        history.failureInjector = nil
        XCTAssertThrowsError(try history.replaceImage(image(width: 2), id: record.id, editable: payload))
        XCTAssertEqual(try snapshot(directory), before)
    }

    @MainActor func testUnknownDocumentVersionAndChangedOriginalIdentityNeverBecomeLegacy() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var payload = try fixture()
        let pins = try PinSessionStore(directory: directory)
        let entry = try pins.add(originalImage: payload.originalImage, currentImage: rendered(payload), editable: payload)
        let before = try snapshot(directory)
        payload.document.originalAssetID = UUID(); payload.document.baseAssetID = payload.document.originalAssetID
        XCTAssertThrowsError(try pins.replaceImage(rendered(payload), id: entry.id, editable: payload))
        XCTAssertEqual(try snapshot(directory), before)
        let editable = try XCTUnwrap(entry.editableCapture)
        let url = directory.appendingPathComponent(editable.documentFilename)
        let beforeDocument = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: beforeDocument, encoding: .utf8))
        let changed = Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)
        XCTAssertNotEqual(changed, beforeDocument); XCTAssertEqual(changed.count, beforeDocument.count)
        try changed.write(to: url)
        // Altering bytes alone is an integrity failure, even when the length is unchanged.
        XCTAssertThrowsError(try pins.editablePayload(id: entry.id)) { XCTAssertEqual($0 as? PinSessionError, .invalidManifest) }
        // Deliberately update the fixture descriptor digest to reach codec version dispatch.
        let updated = EditableCaptureAsset(documentFilename: editable.documentFilename, documentByteCount: editable.documentByteCount,
            original: editable.original, base: editable.base, documentSHA256: sha256(changed), current: editable.current)
        var index = pins.index; index.entries[0].editableCapture = updated
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"))
        let reopened = try PinSessionStore(directory: directory)
        XCTAssertThrowsError(try reopened.editablePayload(id: entry.id)) {
            XCTAssertEqual($0 as? EditableAnnotationDocumentError, .unsupportedVersion)
        }
        XCTAssertNotNil(reopened.entry(id: entry.id)?.editableCapture)
        XCTAssertNotNil(reopened.image(id: entry.id, original: true))
    }

    @MainActor func testPostCommitRetirementRecoveryKeepsTheCommittedSource() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture()
        let history = HistoryStore(directory: directory)
        let entry = try history.add(rendered(payload), editable: payload)
        let old = UUID().uuidString + ".png"
        try Data("old revision".utf8).write(to: directory.appendingPathComponent(old))
        let journal = directory.appendingPathComponent(".capture-retire-" + UUID().uuidString + ".json")
        try JSONEncoder().encode([old, entry.filename]).write(to: journal)
        let reopened = HistoryStore(directory: directory)
        XCTAssertNil(reopened.loadError); XCTAssertNotNil(reopened.image(for: entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(old).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    @MainActor func testDecodedBudgetIsIndependentOfCompressedBytesAndCanReuseOwnedOriginal() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let pins = try PinSessionStore(directory: directory)
        let entry = try pins.add(originalImage: payload.originalImage, currentImage: rendered(payload), editable: payload)
        let descriptor = try XCTUnwrap(entry.editableCapture)
        XCTAssertThrowsError(try pins.editablePayload(id: entry.id, maximumRasterBytes: descriptor.decodedRasterByteEstimate - 1)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        let opened = try XCTUnwrap(pins.editablePayload(id: entry.id, reusingOriginal: payload.originalImage,
                                                      maximumRasterBytes: descriptor.decodedRasterByteEstimate))
        XCTAssertTrue(opened.originalImage === payload.originalImage)
        XCTAssertEqual(opened.baseImage.width, 8)
    }

    @MainActor func testSameSizeValidPNGSubstitutionRejectsLazyLoadsAndOriginalReuseWithoutEviction() throws {
        for sourceKind in ["original", "base", "current"] {
            let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let payload = try fixture(distinctBase: true)
            let output = try rendered(payload)
            let pins = try PinSessionStore(directory: directory)
            let entry = try pins.add(originalImage: payload.originalImage, currentImage: output, editable: payload)
            let descriptor = try XCTUnwrap(entry.editableCapture)
            let asset = try (sourceKind == "original" ? descriptor.original : (sourceKind == "base" ? descriptor.base : XCTUnwrap(descriptor.current)))
            let raster = sourceKind == "original" ? payload.originalImage : (sourceKind == "base" ? payload.baseImage : output)
            let replacement = try sameSizeDifferentPNG(raster, byteCount: Int(asset.byteCount), directory: directory)
            XCTAssertEqual(replacement.count, Int(asset.byteCount))
            XCTAssertNotEqual(sha256(replacement), asset.sha256)
            try replacement.write(to: directory.appendingPathComponent(asset.filename))
            let before = try snapshot(directory), beforeIndex = pins.index
            // A healthy catalog opens lazily; equal-size tampering is detected when used.
            let reopened = try PinSessionStore(directory: directory)
            XCTAssertEqual(reopened.entries.map(\.id), [entry.id])
            XCTAssertThrowsError(try reopened.editablePayload(id: entry.id)) { XCTAssertEqual($0 as? PinSessionError, .invalidImage) }
            if sourceKind == "original" {
                XCTAssertThrowsError(try pins.replaceImage(output, id: entry.id, editable: payload)) {
                    XCTAssertEqual($0 as? PinSessionError, .invalidImage)
                }
                XCTAssertThrowsError(try pins.resetImage(id: entry.id)) { XCTAssertEqual($0 as? PinSessionError, .invalidImage) }
                XCTAssertThrowsError(try pins.replaceImage(output, id: entry.id)) { XCTAssertEqual($0 as? PinSessionError, .invalidImage) }
                XCTAssertEqual(pins.index, beforeIndex)
            }
            if sourceKind == "current" { XCTAssertNil(reopened.image(id: entry.id)) }
            XCTAssertEqual(try snapshot(directory), before)
        }
    }

    @MainActor func testHistoryCurrentChecksumIsLazyAndCannotSilentlyServeDifferentPixels() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(), output = try rendered(payload)
        let history = HistoryStore(directory: directory)
        let record = try history.add(output, editable: payload)
        let replacement = try sameSizeDifferentPNG(output, byteCount: Int(record.byteCount), directory: directory)
        try replacement.write(to: history.url(for: record))
        let before = try snapshot(directory)
        let reopened = HistoryStore(directory: directory)
        XCTAssertNil(reopened.loadError); XCTAssertEqual(reopened.records.count, 1)
        XCTAssertNil(reopened.image(for: record))
        XCTAssertThrowsError(try reopened.editablePayload(for: record))
        XCTAssertEqual(try snapshot(directory), before)
    }

    @MainActor func testCroppedDecoratedCurrentExactlyMatchesReopenedLayers() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var payload = try fixture(distinctBase: true)
        payload.document.cropViewportInBase = CGRect(x: 1, y: 2, width: 6, height: 6)
        payload.document.outputDecoration = ImageOutputDecoration(enabled: true, cornerRadius: 1, borderEnabled: true,
            borderWidth: 1, shadowEnabled: true, shadowBlur: 1, shadowOffsetX: 1, shadowOffsetY: 2, shadowOpacity: 0.4)
        let output = try rendered(payload)
        let history = HistoryStore(directory: directory)
        let record = try history.add(output, editable: payload)
        let reopened = HistoryStore(directory: directory)
        let restored = try XCTUnwrap(reopened.editablePayload(for: record))
        let stored = try XCTUnwrap(reopened.image(for: record))
        XCTAssertEqual(try pixels(stored), try pixels(rendered(restored)))
        XCTAssertEqual(stored.width, output.width); XCTAssertEqual(stored.height, output.height)
        XCTAssertEqual(restored.baseImage.width, 8); XCTAssertEqual(restored.baseImage.height, 10)
    }

    @MainActor func testHistoryCurrentEncodedLimitIsInclusiveAndRejectedWritePreservesPriorRecord() throws {
        XCTAssertEqual(HistoryStore.maximumCurrentImageBytes, 134_217_728)
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(), output = try rendered(payload)
        let probe = directory.appendingPathComponent("probe.png")
        try output.writePNG(to: probe)
        let bytes = Int64(try Data(contentsOf: probe).count)
        try FileManager.default.removeItem(at: probe)
        let acceptedDirectory = directory.appendingPathComponent("accepted")
        let accepted = HistoryStore(directory: acceptedDirectory, currentImageByteLimit: bytes)
        let atBoundary = try accepted.add(output, editable: payload)
        XCTAssertEqual(atBoundary.byteCount, bytes); XCTAssertNotNil(accepted.image(for: atBoundary))
        let refusedDirectory = directory.appendingPathComponent("refused")
        let original = HistoryStore(directory: refusedDirectory)
        let previous = try original.add(image(width: 1))
        let restricted = HistoryStore(directory: refusedDirectory, policy: RetentionPolicy(maxItems: 1), currentImageByteLimit: bytes - 1)
        let before = try snapshot(refusedDirectory)
        XCTAssertThrowsError(try restricted.add(output, editable: payload)) { XCTAssertEqual($0 as? PinSessionError, .capacityExceeded) }
        XCTAssertEqual(restricted.records.map(\.id), [previous.id]); XCTAssertEqual(try snapshot(refusedDirectory), before)
        XCTAssertNotNil(restricted.image(for: previous))
    }

    @MainActor func testResetDigestSurvivesReloadAndSizeMismatchNeverBecomesRetentionEviction() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let pins = try PinSessionStore(directory: directory)
        let entry = try pins.add(originalImage: payload.originalImage, currentImage: rendered(payload), editable: payload)
        try pins.resetImage(id: entry.id)
        let reset = try XCTUnwrap(pins.entry(id: entry.id))
        let reloaded = try PinSessionStore(directory: directory)
        XCTAssertEqual(reloaded.entry(id: entry.id)?.original.sha256, reset.original.sha256)
        XCTAssertNotNil(reloaded.image(id: entry.id))
        let file = directory.appendingPathComponent(reset.original.filename)
        var altered = try Data(contentsOf: file); altered.append(0)
        try altered.write(to: file)
        let before = try snapshot(directory)
        XCTAssertThrowsError(try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxDiskBytes: 1))) {
            XCTAssertEqual($0 as? PinSessionError, .invalidManifest)
        }
        XCTAssertEqual(try snapshot(directory), before)
    }

    @MainActor func testFirstEditableSaveUpgradesLegacyPinHashWithoutReplacingSource() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = try fixture(distinctBase: true)
        let pins = try PinSessionStore(directory: directory)
        let legacy = try pins.add(image: payload.originalImage)
        XCTAssertNil(legacy.original.sha256); XCTAssertNil(legacy.editableCapture)
        let originalBytes = try Data(contentsOf: directory.appendingPathComponent(legacy.original.filename))
        try pins.replaceImage(rendered(payload), id: legacy.id, editable: payload)
        let upgraded = try XCTUnwrap(pins.entry(id: legacy.id))
        XCTAssertEqual(upgraded.original.filename, legacy.original.filename)
        XCTAssertEqual(upgraded.original.sha256, sha256(originalBytes))
        XCTAssertEqual(upgraded.editableCapture?.original.pinAsset, upgraded.original)
        let reopened = try PinSessionStore(directory: directory)
        let restored = try XCTUnwrap(reopened.editablePayload(id: legacy.id))
        XCTAssertEqual(try pixels(XCTUnwrap(reopened.image(id: legacy.id))), try pixels(rendered(restored)))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(legacy.original.filename)), originalBytes)
    }

    @MainActor private func fixture(distinctBase: Bool = false, annotated: Bool = true) throws -> EditableCapturePayload {
        let original = try image()
        let base = try (distinctBase ? image(width: 8) : original)
        let originalID = UUID(), baseID = distinctBase ? UUID() : originalID
        let document = EditableAnnotationDocument(originalAssetID: originalID, originalPixelWidth: original.width,
            originalPixelHeight: original.height, baseAssetID: baseID, basePixelWidth: base.width, basePixelHeight: base.height,
            baseProvenance: distinctBase ? .derivedRaster : .originalCapture, capturedAt: Date(timeIntervalSince1970: 1000),
            annotations: annotated ? [ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 1, y: 1), CGPoint(x: 6, y: 6)])] : [])
        return EditableCapturePayload(document: document, originalImage: original, baseImage: base)
    }
    private func rendered(_ payload: EditableCapturePayload) throws -> CGImage {
        let annotated = try XCTUnwrap(ImageEditorRenderer.render(image: payload.baseImage, annotations: payload.document.annotations))
        let cropped: CGImage
        if let crop = payload.document.cropViewportInBase {
            // CGImage crops are top-left based; document coordinates are bottom-left.
            cropped = try XCTUnwrap(annotated.cropping(to: CGRect(x: crop.minX,
                y: CGFloat(annotated.height) - crop.maxY, width: crop.width, height: crop.height)))
        } else { cropped = annotated }
        return try ImageOutputDecorationRenderer.project(flattened: cropped, decoration: payload.document.outputDecoration)
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
    private func sameSizeDifferentPNG(_ raster: CGImage, byteCount: Int, directory: URL) throws -> Data {
        let original = try pixels(raster)
        let temporary = directory.appendingPathComponent("candidate.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // XOR preserves the pixel pattern but changes its colors. Search only bounded,
        // real ImageIO-generated PNGs; do not substitute corrupt padding as test data.
        for mask in UInt8(1)...UInt8(255) {
            var changed = original
            changed.withUnsafeMutableBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                for index in stride(from: 0, to: bytes.count, by: 4) { bytes[index] ^= mask }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: changed as CFData))
            let image = try XCTUnwrap(CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: raster.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            try image.writePNG(to: temporary)
            let candidate = try Data(contentsOf: temporary)
            if candidate.count == byteCount {
                let decoded = try XCTUnwrap(CGImage.read(url: temporary))
                XCTAssertEqual(decoded.width, raster.width); XCTAssertEqual(decoded.height, raster.height)
                XCTAssertNotEqual(try pixels(decoded), original)
                return candidate
            }
        }
        XCTFail("Unable to create an equal-length valid PNG fixture")
        throw Injected.write
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func encoded(_ payload: EditableCapturePayload) throws -> Data { try EditableAnnotationDocumentCodec.encode(payload.document) }
    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("EditablePersistence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path.resolvingSymlinksInPath()
    }
    private func image(width: Int = 10, red: CGFloat = 1) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 10, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: 10))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 2, y: 3, width: 3, height: 4))
        return try XCTUnwrap(context.makeImage())
    }
    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    private func fileBytes(_ filenames: [String], in directory: URL) throws -> Int64 {
        try filenames.reduce(0) { $0 + Int64(try directory.appendingPathComponent($1).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }
}
