import AppKit
import ImageIO
import XCTest
import PicShotCore
@testable import PicShot

@MainActor final class PinEditableAdmissionTests: XCTestCase {
    func testFullBaseRedrawClosesSixteenBitAdmissionGapWithoutLargeAllocations() throws {
        let retained = 79_000_000 * 8 + 12
        let baseDecode = 20_000_000 * 8
        let limit = EditorAdmissionPolicy().maximumRasterBytes
        XCTAssertLessThan(baseDecode, limit - retained, "The former decoder-only check admitted this case")
        let remaining = try PinEditableAdmission.remaining(limit: limit, retained: retained,
            reportedProjection: 0, globalProjection: 0,
            work: PinEditableAdmission.redraw(width: 4_000, height: 5_000))
        XCTAssertGreaterThan(baseDecode, remaining, "Full-base redraw must be reserved before base decoding")
    }

    func testProjectionLeaseAndDrainingReservationAreCountedOnce() throws {
        let lease = EditorOutputProjection.combinedWorkingByteLimit
        let limit = EditorAdmissionPolicy().maximumRasterBytes
        XCTAssertThrowsError(try PinEditableAdmission.remaining(limit: limit, retained: 288_052_000,
            reportedProjection: 0, globalProjection: 0, work: lease))
        let active = try PinEditableAdmission.remaining(limit: limit, retained: lease + 1_024,
            reportedProjection: lease, globalProjection: lease, work: 512)
        let draining = try PinEditableAdmission.remaining(limit: limit, retained: 1_024,
            reportedProjection: 0, globalProjection: lease, work: 512)
        XCTAssertEqual(active, draining)
        XCTAssertEqual(draining, limit - lease - 1_536)
        XCTAssertThrowsError(try PinEditableAdmission.remaining(limit: 1_535, retained: 1_024,
            reportedProjection: 0, globalProjection: 0, work: 512))
        XCTAssertEqual(try PinEditableAdmission.remaining(limit: 1_536, retained: 1_024,
            reportedProjection: 0, globalProjection: 0, work: 512), 0)
    }

    func testSharedOriginalIsCreditedAndCropNeverShrinksEditorRedraw() throws {
        let source = try image(), other = try image()
        XCTAssertEqual(PinEditableAdmission.additionalImages([source, source], alreadyOwned: [source]), 0)
        XCTAssertEqual(PinEditableAdmission.additionalImages([source, other, other], alreadyOwned: [source]),
            other.bytesPerRow * other.height)
        var payload = makePayload(source: source, crop: CGRect(x: 1, y: 1, width: 4, height: 4))
        XCTAssertEqual(try PinEditableAdmission.workBytes(.editor, document: payload.document,
            baseWidth: 16, baseHeight: 16), 1_024)
        XCTAssertEqual(try PinEditableAdmission.workBytes(.hiddenPreview, document: payload.document,
            baseWidth: 16, baseHeight: 16), 64)
        payload.document.outputDecoration = .init(enabled: true, cornerRadius: 1)
        XCTAssertEqual(try PinEditableAdmission.workBytes(.hiddenPreview, document: payload.document,
            baseWidth: 16, baseHeight: 16), 64 + EditorOutputProjection.combinedWorkingByteLimit)
    }

    func testTwoPinEditorsRespectAggregateBoundaryAndReuseOriginal() throws {
        let fixture = try Fixture(limit: 3_072); defer { fixture.close() }
        let first = try fixture.add(), second = try fixture.add()
        first.showWindow(nil); second.showWindow(nil)
        var errors: [Error] = []; second.onAnnotationError = { errors.append($0) }
        first.showAnnotations()
        let editor = try XCTUnwrap(first.annotationEditor)
        XCTAssertEqual(first.estimatedRetainedRasterBytes, 2_048,
            "Opening must add one redraw, without charging the same original twice")
        second.showAnnotations()
        XCTAssertNil(second.annotationEditor)
        XCTAssertEqual(errors.last as? PinSessionError, .capacityExceeded)
        XCTAssertEqual(fixture.session.liveControllers.values.reduce(0) { $0 + $1.estimatedRetainedRasterBytes }, 3_072)
        editor.close()
        second.showAnnotations()
        XCTAssertNotNil(second.annotationEditor)
    }

    func testEditorRefusalPreservesPreviouslyHiddenPreviewAndSavedDocument() throws {
        let fixture = try Fixture(limit: 1_200); defer { fixture.close() }
        let source = try image(), payload = makePayload(source: source, crop: CGRect(x: 1, y: 1, width: 4, height: 4))
        let current = try render(payload)
        let pin = try fixture.add(payload: payload, current: current)
        pin.showWindow(nil)
        try pin.setAnnotationsHidden(true)
        let preview = pin.displayedImage, stored = fixture.store.index
        var errors: [Error] = []; pin.onAnnotationError = { errors.append($0) }
        pin.showAnnotations()
        XCTAssertEqual(errors.last as? PinSessionError, .capacityExceeded)
        XCTAssertNil(pin.annotationEditor); XCTAssertTrue(pin.annotationsHidden)
        XCTAssertTrue(pin.displayedImage === preview); XCTAssertTrue(pin.currentImage === current)
        XCTAssertEqual(fixture.store.index, stored)
    }

    func testDecoratedPreviewRefusesBeforeCropProjectionOrVisibilityMutation() throws {
        let source = try image()
        var payload = makePayload(source: source, crop: CGRect(x: 1, y: 1, width: 4, height: 4))
        payload.document.outputDecoration = .init(enabled: true, cornerRadius: 1)
        let current = try render(payload)
        let retained = EditorRasterEstimate.retainedBytes([source, current])
        let required = retained + 64 + EditorOutputProjection.combinedWorkingByteLimit
        let fixture = try Fixture(limit: required - 1); defer { fixture.close() }
        let pin = try fixture.add(payload: payload, current: current)
        let stored = fixture.store.index, starts = EditorOutputProjection.shared.startedCount
        XCTAssertThrowsError(try pin.setAnnotationsHidden(true)) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertFalse(pin.annotationsHidden); XCTAssertFalse(pin.annotationVisibilityIsPending)
        XCTAssertEqual(pin.retainedAnnotationPreviewCount, 0)
        XCTAssertTrue(pin.displayedImage === current); XCTAssertEqual(fixture.store.index, stored)
        XCTAssertEqual(EditorOutputProjection.shared.startedCount, starts)
        XCTAssertFalse(EditorOutputProjection.shared.isBusy)
    }

    func testCancelledClosedOwnerKeepsGlobalLeaseUntilDrain() async throws {
        let projection = EditorOutputProjection.shared
        XCTAssertFalse(projection.isBusy)
        let firstFixture = try Fixture(); defer { firstFixture.close() }
        let secondFixture = try Fixture(limit: 4_096); defer { secondFixture.close() }
        let source = try image()
        var payload = makePayload(source: source)
        payload.document.outputDecoration = .init(enabled: true, cornerRadius: 1)
        let first = try firstFixture.add(payload: payload, current: render(payload))
        let second = try secondFixture.add(); second.showWindow(nil)
        var errors: [Error] = []; second.onAnnotationError = { errors.append($0) }
        projection.queue.isSuspended = true
        defer { projection.queue.isSuspended = false }
        try first.setAnnotationsHidden(true)
        XCTAssertEqual(projection.reservedBytes, EditorOutputProjection.combinedWorkingByteLimit)
        try first.setAnnotationsHidden(false); first.close()
        XCTAssertTrue(firstFixture.session.liveControllers.isEmpty)
        second.showAnnotations()
        XCTAssertNil(second.annotationEditor)
        XCTAssertEqual(errors.last as? PinSessionError, .capacityExceeded)
        projection.queue.isSuspended = false
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while projection.isBusy && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(projection.isBusy)
        second.showAnnotations(); XCTAssertNotNil(second.annotationEditor)
    }

    func testPostDecodeActualOwnershipCheckPrecedesVisibilityAndEditorMutation() throws {
        let source = try image(), payload = makePayload(source: source)
        let pin = PinController(image: source, defaults: nil); defer { pin.close() }
        var allow = true, checked: [PinEditableWork] = []
        pin.configureEditableCapture(available: true, loadForWork: { _ in payload }, admission: { work, _ in
            checked.append(work)
            if !allow { throw PinSessionError.capacityExceeded }
        })
        pin.showWindow(nil); try pin.setAnnotationsHidden(true)
        let preview = pin.displayedImage
        allow = false
        var errors: [Error] = []; pin.onAnnotationError = { errors.append($0) }
        pin.showAnnotations()
        XCTAssertEqual(errors.last as? PinSessionError, .capacityExceeded)
        XCTAssertNil(pin.annotationEditor); XCTAssertTrue(pin.annotationsHidden)
        XCTAssertTrue(pin.displayedImage === preview); XCTAssertEqual(checked.count, 2)
    }

    func testTinySixteenBitPNGUsesActualDecodedRows() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let source = try image(width: 1, height: 1)
        let pixels = Data((0..<(8 * 8)).flatMap { _ in [UInt8(0x12), 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xff, 0xff] })
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let base = try XCTUnwrap(CGImage(width: 8, height: 8, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let document = EditableAnnotationDocument(originalAssetID: UUID(), originalPixelWidth: 1, originalPixelHeight: 1,
            baseAssetID: UUID(), basePixelWidth: 8, basePixelHeight: 8,
            cropViewportInBase: CGRect(x: 0, y: 0, width: 1, height: 1), baseProvenance: .derivedRaster, annotations: [])
        let payload = EditableCapturePayload(document: document, originalImage: source, baseImage: base)
        let entry = try fixture.store.add(originalImage: source, currentImage: render(payload), editable: payload)
        let restored = try XCTUnwrap(fixture.store.editablePayload(id: entry.id, reusingOriginal: source))
        XCTAssertEqual(restored.baseImage.bitsPerComponent, 16)
        XCTAssertGreaterThanOrEqual(restored.baseImage.bytesPerRow, 64)
        XCTAssertEqual(PinEditableAdmission.additionalImages([restored.originalImage, restored.baseImage], alreadyOwned: [source]),
            restored.baseImage.bytesPerRow * restored.baseImage.height)
    }

    private func image(width: Int = 16, height: Int = 16) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func makePayload(source: CGImage, crop: CGRect? = nil) -> EditableCapturePayload {
        let id = UUID()
        return EditableCapturePayload(document: EditableAnnotationDocument(originalAssetID: id,
            originalPixelWidth: source.width, originalPixelHeight: source.height, baseAssetID: id,
            basePixelWidth: source.width, basePixelHeight: source.height, cropViewportInBase: crop,
            baseProvenance: .originalCapture, annotations: []), originalImage: source, baseImage: source)
    }
    private func render(_ payload: EditableCapturePayload) throws -> CGImage {
        let base = try EditableCapturePresentation.visibleBase(payload)
        return try ImageOutputDecorationRenderer.project(flattened: base, decoration: payload.document.outputDecoration)
    }
    @MainActor private final class Fixture {
        let directory: URL
        let store: PinSessionStore
        let session: PinSessionCoordinator
        init(limit: Int = EditorAdmissionPolicy().maximumRasterBytes) throws {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PinEditableAdmission-" + UUID().uuidString)
            store = try PinSessionStore(directory: directory)
            session = PinSessionCoordinator(store: store, presentWindows: false,
                desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
                ocrPreferences: PinOCRPreferences(defaults: nil),
                makeImageController: { PinController(originalImage: $0, currentImage: $1, isModified: $2, defaults: nil) },
                editableRasterByteLimit: limit)
        }
        func add(payload: EditableCapturePayload? = nil, current: CGImage? = nil) throws -> PinController {
            let value: EditableCapturePayload
            if let payload { value = payload }
            else {
                let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                    bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
                let source = try XCTUnwrap(context.makeImage()), assetID = UUID()
                value = EditableCapturePayload(document: EditableAnnotationDocument(originalAssetID: assetID,
                    originalPixelWidth: 16, originalPixelHeight: 16, baseAssetID: assetID,
                    basePixelWidth: 16, basePixelHeight: 16, baseProvenance: .originalCapture, annotations: []),
                    originalImage: source, baseImage: source)
            }
            let id = try session.add(originalImage: value.originalImage, currentImage: current ?? value.baseImage, editable: value)
            return try XCTUnwrap(session.liveControllers[id])
        }
        func close() { try? session.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
    }
}
