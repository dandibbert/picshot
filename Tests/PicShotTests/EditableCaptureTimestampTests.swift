import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor final class EditableCaptureTimestampTests: XCTestCase {
    func testUnknownEpochZeroCaptureMetadataRoundTripsByteForByte() throws {
        try assertCaptureRoundTrip(date: Date(timeIntervalSince1970: 0), zone: "UTC", known: false)
    }

    func testUnknownNonzeroCaptureMetadataRoundTripsByteForByte() throws {
        try assertCaptureRoundTrip(date: Date(timeIntervalSince1970: 1_700_000_000.123456),
                                  zone: "Asia/Shanghai", known: false)
    }

    func testKnownCaptureDatesRoundTripAndNewWatermarksKeepCaptureTime() throws {
        let source = try EditableUIFixtures.source()
        for date in [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_700_000_000.123456)] {
            let zone = "America/Los_Angeles"
            try assertCaptureRoundTrip(date: date, zone: zone, known: true)
            let canvas = ImageEditorCanvas(image: source)
            canvas.restoreCaptureTimestamp(date, timeZoneIdentifier: zone, known: true)
            let mark = canvas.makeAnnotation(tool: .watermark, points: [.zero, CGPoint(x: 200, y: 100)])
            XCTAssertEqual(mark.frozenTimestamp, date)
            XCTAssertEqual(mark.frozenTimeZoneIdentifier, zone)
            XCTAssertTrue(mark.timestampIsCaptureDate)
            XCTAssertEqual(mark.watermarkTemplate, "PicShot · $yyyy-MM-dd HH:mm:ss$")
            XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(mark), "PicShot · " + formatted(date, zone: zone))
        }
    }

    func testNewWatermarksForUnknownCaptureUseFrozenSessionEditTime() throws {
        let source = try EditableUIFixtures.source()
        for storedDate in [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_700_000_000.123456)] {
            let zone = "Asia/Shanghai"
            var payload = makePayload(source, date: storedDate, zone: zone, known: false)
            payload.document = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(payload.document))
            let beforeOpening = Date()
            let editor = EditableUIFixtures.editor(source); defer { editor.close() }
            let afterOpening = Date()
            try editor.restoreEditablePayload(payload)
            let canvas = editor.annotationCanvas
            let mark = canvas.makeAnnotation(tool: .watermark, points: [.zero, CGPoint(x: 200, y: 100)])
            XCTAssertGreaterThanOrEqual(mark.frozenTimestamp, beforeOpening)
            XCTAssertLessThanOrEqual(mark.frozenTimestamp, afterOpening)
            XCTAssertNotEqual(mark.frozenTimestamp, storedDate)
            XCTAssertEqual(mark.frozenTimeZoneIdentifier, zone)
            XCTAssertFalse(mark.timestampIsCaptureDate)
            XCTAssertEqual(mark.watermarkTemplate, "PicShot · 编辑于 $yyyy-MM-dd HH:mm:ss$")
            XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(mark),
                           "PicShot · 编辑于 " + formatted(mark.frozenTimestamp, zone: zone))
            let another = canvas.makeAnnotation(tool: .watermark, points: [.zero, CGPoint(x: 100, y: 80)])
            XCTAssertEqual(another.frozenTimestamp, mark.frozenTimestamp, "New marks freeze this session's editing start")

            canvas.add(mark)
            var expected = payload.document
            expected.annotations.append(mark)
            let expectedBytes = try EditableAnnotationDocumentCodec.encode(expected)
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document), expectedBytes,
                           "Adding a watermark must not rewrite capture metadata or existing marks")
            EditableUIFixtures.action("undoEdit", editor)
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document),
                           try EditableAnnotationDocumentCodec.encode(payload.document))
            EditableUIFixtures.action("redoEdit", editor)
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document), expectedBytes)

            var saved = try editor.editablePayload()
            saved.document = try EditableAnnotationDocumentCodec.decode(expectedBytes)
            let reopened = EditableUIFixtures.editor(source); defer { reopened.close() }
            try reopened.restoreEditablePayload(saved)
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(reopened.editablePayload().document), expectedBytes,
                           "A saved editing timestamp must remain frozen when a later session opens")
        }
    }

    private func assertCaptureRoundTrip(date: Date, zone: String, known: Bool,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try EditableUIFixtures.source()
        var payload = makePayload(source, date: date, zone: zone, known: known)
        let originalBytes = try EditableAnnotationDocumentCodec.encode(payload.document)
        payload.document = try EditableAnnotationDocumentCodec.decode(originalBytes)
        let originalTexts = payload.document.annotations.map { AnnotationWatermarkLayout.resolvedText($0) }
        let editor = EditableUIFixtures.editor(source); defer { editor.close() }
        try editor.restoreEditablePayload(payload)
        let restored = try editor.editablePayload()
        XCTAssertEqual(editor.annotationCanvas.captureDate, date, file: file, line: line)
        XCTAssertEqual(editor.annotationCanvas.captureTimeZoneIdentifier, zone, file: file, line: line)
        XCTAssertEqual(editor.annotationCanvas.captureTimestampKnown, known, file: file, line: line)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(restored.document), originalBytes,
                       "An unmodified editor must preserve every encoded field", file: file, line: line)
        XCTAssertEqual(restored.document.annotations.map { AnnotationWatermarkLayout.resolvedText($0) }, originalTexts,
                       "Previously authored watermarks keep their own date, timezone and label", file: file, line: line)
        XCTAssertTrue(restored.originalImage === source, file: file, line: line)
        XCTAssertTrue(restored.baseImage === source, file: file, line: line)
    }

    private func makePayload(_ source: CGImage, date: Date, zone: String, known: Bool) -> EditableCapturePayload {
        var edited = ImageAnnotation(tool: .watermark, points: [CGPoint(x: 30, y: 30), CGPoint(x: 240, y: 170)])
        edited.watermarkTemplate = "备份 · 编辑于 $yyyy-MM-dd HH:mm:ss$"
        edited.frozenTimestamp = Date(timeIntervalSince1970: 1_600_000_000.654321)
        edited.frozenTimeZoneIdentifier = "Europe/Paris"; edited.timestampIsCaptureDate = false
        var captured = edited; captured.id = UUID()
        captured.watermarkTemplate = "Captured $yyyy-MM-dd HH:mm:ss$"
        captured.frozenTimestamp = Date(timeIntervalSince1970: 1_500_000_000.123456)
        captured.frozenTimeZoneIdentifier = "America/New_York"; captured.timestampIsCaptureDate = true
        let assetID = UUID()
        var document = EditableAnnotationDocument(originalAssetID: assetID,
            originalPixelWidth: source.width, originalPixelHeight: source.height,
            baseAssetID: assetID, basePixelWidth: source.width, basePixelHeight: source.height,
            annotations: [edited, captured])
        document.capturedAt = date; document.captureTimeZoneIdentifier = zone; document.captureTimestampKnown = known
        document.baseProvenance = .originalCapture
        document.cropViewportInBase = CGRect(x: 16, y: 8, width: 288, height: 216)
        document.numberSequence.setNext(27); document.numberSequence.closesGapsOnDelete = true
        document.outputDecoration = ImageOutputDecoration(enabled: true, cornerRadius: 5.5,
            borderEnabled: true, borderWidth: 1.5)
        return EditableCapturePayload(document: document, originalImage: source, baseImage: source)
    }

    private func formatted(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
