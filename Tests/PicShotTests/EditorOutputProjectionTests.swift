import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor
final class EditorOutputProjectionTests: XCTestCase {
    private let decoration = ImageOutputDecoration(enabled: true, cornerRadius: 18, borderEnabled: true,
        borderWidth: 2, shadowEnabled: true, shadowBlur: 3, shadowOffsetX: 4, shadowOffsetY: 6)

    func testMetadataApplyUndoRedoCancelAndCropPreserveInitialSourceAndAnnotationCoordinates() throws {
        let editor = try makeEditor(); defer { editor.close() }
        let source = editor.annotationCanvas.image
        let mark = ImageAnnotation(tool: .redact, points: [CGPoint(x: 60, y: 100), CGPoint(x: 150, y: 180)])
        editor.annotationCanvas.add(mark)
        XCTAssertTrue(try editor.applyOutputDecoration(decoration))
        XCTAssertFalse(try editor.applyOutputDecoration(decoration), "Unchanged metadata must not add undo entries")
        XCTAssertTrue(editor.annotationCanvas.image === source); XCTAssertTrue(editor.initialOriginalImage === source)
        XCTAssertEqual(editor.annotationCanvas.annotations[0].points, mark.points)
        send("undoEdit", to: editor); XCTAssertEqual(editor.outputDecoration, .none)
        XCTAssertEqual(editor.annotationCanvas.annotations.count, 1)
        send("redoEdit", to: editor); XCTAssertEqual(editor.outputDecoration, decoration)
        editor.cancelDecorationWork(); XCTAssertEqual(editor.outputDecoration, decoration)
        editor.annotationCanvas.cropRect = CGRect(x: 20, y: 20, width: 200, height: 180)
        send("applyCrop", to: editor)
        XCTAssertEqual(editor.annotationCanvas.image.width, 200); XCTAssertEqual(editor.annotationCanvas.image.height, 180)
        XCTAssertEqual(editor.outputDecoration, decoration, "Crop must not bake decoration or its padding into the source")
        XCTAssertTrue(editor.initialOriginalImage === source)
        send("undoEdit", to: editor)
        XCTAssertTrue(editor.annotationCanvas.image === source); XCTAssertEqual(editor.outputDecoration, decoration)
        XCTAssertEqual(editor.annotationCanvas.annotations[0].points, mark.points)
    }

    func testEveryFinalRouteUsesTheSameProjectionAndIdentityRoutesRemainSynchronous() async throws {
        let editor = try makeEditor(); defer { editor.close() }
        for route in ImageEditorOutputRoute.allCases {
            var synchronous = false
            editor.requestOutput(for: route) { _ in synchronous = true }
            XCTAssertTrue(synchronous); XCTAssertFalse(editor.outputProjectionIsPending)
            XCTAssertEqual(editor.lastOutputRoute, route)
        }
        _ = try editor.applyOutputDecoration(decoration)
        let expected = try ImageOutputDecorationRenderer.project(flattened: XCTUnwrap(editor.annotationCanvas.flattened()), decoration: decoration)
        let pixels = try EditorOutputDecorationNativeFixture.raster(expected)
        let prior = editor.outputDeliveryCount
        for route in ImageEditorOutputRoute.allCases {
            var delivered: CGImage?
            editor.requestOutput(for: route) { delivered = $0 }
            XCTAssertNil(delivered, "Active decoration must not run its raster loop on MainActor")
            XCTAssertTrue(editor.outputProjectionIsPending)
            try await until { !editor.outputProjectionIsPending }
            XCTAssertEqual(try EditorOutputDecorationNativeFixture.raster(XCTUnwrap(delivered)), pixels)
            XCTAssertEqual(editor.lastOutputRoute, route)
        }
        XCTAssertEqual(editor.outputDeliveryCount - prior, ImageEditorOutputRoute.allCases.count)
        XCTAssertFalse(EditorOutputProjection.shared.isBusy)
    }

    func testNativeSelectorsRouteCurrentPixelsThroughSharedSeam() async throws {
        _ = NSApplication.shared
        var calls: [String] = []
        let editor = ImageEditorController(image: try EditorOutputDecorationNativeFixture.makeSource(),
            onSave: { _ in calls.append("history") }, onPin: { _ in calls.append("pin") }, onOCR: { _ in calls.append("ocr") },
            onTranslate: { _ in calls.append("translate") }, onApply: { _ in calls.append("apply"); return false },
            saveWorkflow: SaveWorkflowPresenter(isSmoke: true), copyAction: { _ in calls.append("copy") })
        defer { editor.close() }
        _ = try editor.applyOutputDecoration(decoration)
        for (selector, route) in [("copyResult", ImageEditorOutputRoute.copy), ("saveResult", .history), ("pinResult", .pin),
                                   ("quickSaveResult", .quickSave), ("saveCopyResult", .saveCopy), ("recognizeResult", .recognition),
                                   ("translateResult", .translation), ("applyResult", .applyToPin)] {
            send(selector, to: editor); try await until { !editor.outputProjectionIsPending }
            XCTAssertEqual(editor.lastOutputRoute, route)
        }
        XCTAssertEqual(calls, ["copy", "history", "pin", "ocr", "translate", "apply"])
    }

    func testGlobalBusyRefusalQueuedCancellationAndDrainKeepAdmissionOwned() async throws {
        let service = EditorOutputProjection.shared
        XCTAssertTrue(service.queue === ImageOutputDecorationPalette.previewQueue)
        let first = try makeEditor(), second = try makeEditor()
        defer { service.queue.isSuspended = false; first.close(); second.close() }
        _ = try first.applyOutputDecoration(decoration); _ = try second.applyOutputDecoration(decoration)
        var callbacks = 0, errors = 0
        first.onOutputError = { _ in errors += 1 }; second.onOutputError = { _ in errors += 1 }
        service.queue.isSuspended = true
        first.requestOutput(for: .copy) { _ in callbacks += 1 }
        let ticket = try XCTUnwrap(service.activeTicket)
        XCTAssertEqual(first.estimatedOutputProjectionReservationBytes, service.reservedBytes)
        first.requestOutput(for: .pin) { _ in callbacks += 1 }
        second.requestOutput(for: .copy) { _ in callbacks += 1 }
        XCTAssertEqual(errors, 2); XCTAssertTrue(service.activeTicket === ticket)
        first.cancelDecorationWork()
        XCTAssertTrue(first.outputProjectionIsPending); XCTAssertGreaterThan(service.reservedBytes, 0)
        XCTAssertTrue(service.activeTicket === ticket)
        service.queue.isSuspended = false
        try await until { !service.isBusy && !first.outputProjectionIsPending }
        XCTAssertEqual(callbacks, 0); XCTAssertEqual(service.reservedBytes, 0)
        XCTAssertEqual(first.estimatedOutputProjectionReservationBytes, 0)
        second.requestOutput(for: .copy) { _ in callbacks += 1 }
        try await until { !second.outputProjectionIsPending }; XCTAssertEqual(callbacks, 1)
    }

    func testEditsUndoToolChangeAndDirectSourceInvalidationRejectPendingPixels() async throws {
        let service = EditorOutputProjection.shared
        defer { service.queue.isSuspended = false }
        for action in 0..<4 {
            let editor = try makeEditor(); _ = try editor.applyOutputDecoration(decoration)
            var calls = 0
            service.queue.isSuspended = true
            editor.requestOutput(for: .copy) { _ in calls += 1 }
            switch action {
            case 0: editor.annotationCanvas.add(.init(tool: .redact, points: [CGPoint(x: 2, y: 2), CGPoint(x: 20, y: 20)]))
            case 1: send("undoEdit", to: editor)
            case 2: editor.chooseTool(.rectangle)
            default: editor.annotationCanvas.setContent(image: editor.annotationCanvas.image, annotations: [])
            }
            XCTAssertTrue(service.isBusy, "Cancellation may not drop an undrained global reservation")
            service.queue.isSuspended = false
            try await until { !service.isBusy && !editor.outputProjectionIsPending }
            XCTAssertEqual(calls, 0); editor.close()
        }
    }

    func testFinishedWorkerCannotPublishAfterNewerEditBeforeMainActorDelivery() async throws {
        let editor = try makeEditor(); defer { editor.close() }
        _ = try editor.applyOutputDecoration(decoration)
        var calls = 0
        editor.requestOutput(for: .history) { _ in calls += 1 }
        EditorOutputProjection.shared.queue.waitUntilAllOperationsAreFinished()
        editor.annotationCanvas.add(.init(tool: .redact, points: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20)]))
        try await until { !editor.outputProjectionIsPending }
        XCTAssertEqual(calls, 0); XCTAssertEqual(EditorOutputProjection.shared.reservedBytes, 0)
    }

    func testOriginalAwarePinCommitsBeforeFrozenEditorClose() async throws {
        _ = NSApplication.shared
        let source = try EditorOutputDecorationNativeFixture.makeSource()
        let capture = try CapturedImage.frozenPixelRegion(image: source, displayID: 7,
            displayFrame: CGRect(x: 0, y: 0, width: 640, height: 400), pixelFrame: CGRect(x: 0, y: 0, width: 640, height: 400))
        var original: CGImage?, current: CGImage?, fallback = 0, closedAtDelivery = false
        weak var weakEditor: ImageEditorController?
        let editor = ImageEditorController(image: capture.image, presentation: capture.presentation,
            onSave: { _ in }, onPin: { _ in fallback += 1 }, onOCR: { _ in }, saveWorkflow: SaveWorkflowPresenter(isSmoke: true),
            onPinWithOriginal: { original = $0; current = $1; closedAtDelivery = weakEditor?.isClosed == true; return true })
        weakEditor = editor; defer { editor.close() }
        _ = try editor.applyOutputDecoration(decoration)
        let expectedOriginal = try XCTUnwrap(editor.initialOriginalImage)
        send("pinResult", to: editor)
        try await until { !editor.outputProjectionIsPending }
        XCTAssertTrue(original === expectedOriginal); XCTAssertGreaterThan(try XCTUnwrap(current).width, expectedOriginal.width)
        XCTAssertFalse(closedAtDelivery); XCTAssertTrue(editor.isClosed); XCTAssertNil(editor.initialOriginalImage); XCTAssertEqual(fallback, 0)
    }

    func testCloseClearsOriginalAndDoesNotRetainControllerThroughPendingCallback() async throws {
        let service = EditorOutputProjection.shared
        service.queue.isSuspended = true; defer { service.queue.isSuspended = false }
        weak var weakEditor: ImageEditorController?
        var calls = 0
        try autoreleasepool {
            var editor: ImageEditorController? = try makeEditor()
            weakEditor = editor
            _ = try editor?.applyOutputDecoration(decoration)
            editor?.requestOutput(for: .copy) { _ in calls += 1 }
            editor?.close(); XCTAssertNil(editor?.initialOriginalImage); editor = nil
        }
        XCTAssertTrue(service.isBusy); XCTAssertGreaterThan(service.reservedBytes, 0)
        await Task.yield()
        XCTAssertNil(weakEditor, "Projection completion must hold the controller weakly")
        service.queue.isSuspended = false
        try await until { !service.isBusy }
        XCTAssertEqual(calls, 0); XCTAssertEqual(service.reservedBytes, 0)
    }

    func testQueuedPinCloseReleasesOriginalProviderBeforeProjectionDrains() async throws {
        _ = NSApplication.shared
        let service = EditorOutputProjection.shared, witness = ProjectionSourceWitness()
        var calls = 0
        let editor = try autoreleasepool {
            let original = try trackedOriginal(witness)
            let editor = ImageEditorController(image: original, onSave: { _ in }, onPin: { _ in calls += 1 },
                onOCR: { _ in }, saveWorkflow: SaveWorkflowPresenter(isSmoke: true),
                onPinWithOriginal: { _, _ in calls += 1; return true })
            // Independent current pixels model an edited/cropped document without
            // leaving a crop provider that could itself share the original bytes.
            editor.annotationCanvas.setContent(image: try EditorOutputDecorationNativeFixture.makeSource(), annotations: [])
            return editor
        }
        defer { service.queue.isSuspended = false; editor.close() }
        XCTAssertNotNil(witness.owner, "The editor must retain the initial original while open")
        _ = try editor.applyOutputDecoration(decoration)
        service.queue.isSuspended = true
        autoreleasepool { send("pinResult", to: editor); editor.close() }
        XCTAssertTrue(service.isBusy); XCTAssertGreaterThan(service.reservedBytes, 0)
        XCTAssertNil(editor.initialOriginalImage)
        XCTAssertNil(witness.owner, "A pending pin completion must not retain the original source after close")
        service.queue.isSuspended = false
        try await until { !service.isBusy }
        XCTAssertEqual(calls, 0); XCTAssertEqual(service.reservedBytes, 0)
    }

    func testCombinedInputAndWorkingLimitRefusesSixtyMegapixelShadowBeforeFlattening() throws {
        let service = EditorOutputProjection.shared
        XCTAssertThrowsError(try service.reserve(width: 2_000, height: 30_000, decoration: decoration)) {
            XCTAssertTrue($0.localizedDescription.contains("512 MiB"))
        }
        XCTAssertFalse(service.isBusy)
        let radius = ImageOutputDecoration(enabled: true, cornerRadius: 24)
        let ticket = try service.reserve(width: 2_000, height: 30_000, decoration: radius)
        XCTAssertEqual(ticket.rendererLimits.maximumWorkingBytes, 512 * 1_024 * 1_024 - 240_000_000)
        XCTAssertEqual(ticket.knownWorkingBytes, 480_000_000)
        service.abandon(ticket); XCTAssertEqual(service.reservedBytes, 0)
    }

    func testRatioAndDecorationPalettesAreMutuallyExclusiveAndRatioEditCancelsDraft() async throws {
        _ = NSApplication.shared
        let capture = try CapturedImage.frozenPixelRegion(image: EditorOutputDecorationNativeFixture.makeSource(), displayID: 7,
            displayFrame: CGRect(x: 100, y: 100, width: 640, height: 400), pixelFrame: CGRect(x: 100, y: 100, width: 320, height: 180),
            aspectRatio: CaptureAspectRatio(numerator: 16, denominator: 9))
        let editor = ImageEditorController(image: capture.image, presentation: capture.presentation,
            onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, saveWorkflow: SaveWorkflowPresenter(isSmoke: true))
        defer { editor.close() }
        editor.showWindow(nil)
        send("toggleCaptureRatio", to: editor)
        let root = try XCTUnwrap(editor.window?.contentView)
        let ratioView = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "editor.captureRatioPalette" })
        XCTAssertFalse(ratioView.isHiddenOrHasHiddenAncestor)
        send("editOutputDecoration", to: editor)
        XCTAssertNotNil(editor.outputDecorationPalette)
        XCTAssertTrue(ratioView.isHidden, "Opening decoration must hide the ratio palette")
        let palette = try XCTUnwrap(editor.outputDecorationPalette)
        send("toggleCaptureRatio", to: editor)
        XCTAssertNil(editor.outputDecorationPalette, "Switching to ratio must discard the draft owner")
        XCTAssertFalse(palette.isShown, "The old decoration popover must close before the ratio controls appear")
        XCTAssertFalse(ratioView.isHidden, "Switching from decoration must reveal the ratio controls")
        send("editOutputDecoration", to: editor)
        XCTAssertTrue(editor.setCaptureAspectRatio(try CaptureAspectRatio(numerator: 4, denominator: 3)))
        XCTAssertNil(editor.outputDecorationPalette); XCTAssertEqual(editor.outputDecoration, .none)
        try await until { ImageOutputDecorationPalette.previewQueue.operationCount == 0 }
    }

    func testProductionNativeFixtureWritesRealScreenshotsPixelsAndDrainedOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Decoration-Native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await EditorOutputDecorationNativeFixture.verify(evidenceDirectory: directory)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual((report["cases"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual(report["activeProjectionJobsAfter"] as? Int, 0)
        XCTAssertEqual(report["projectionReservedBytesAfter"] as? Int, 0)
        XCTAssertEqual(report["projectionJobsStarted"] as? Int, report["projectionJobsCompleted"] as? Int)
        XCTAssertEqual((report["settledProcessSamples"] as? [[String: Any]])?.count, 4)
        for name in ["light", "dark", "edge-light", "edge-dark"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ui-output-decoration-palette-\(name).png").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("output-decoration-\(name).png").path))
        }
    }

    private func makeEditor() throws -> ImageEditorController {
        _ = NSApplication.shared
        return ImageEditorController(image: try EditorOutputDecorationNativeFixture.makeSource(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in },
            saveWorkflow: SaveWorkflowPresenter(isSmoke: true), copyAction: { _ in })
    }
    private func trackedOriginal(_ witness: ProjectionSourceWitness) throws -> CGImage {
        let owner = ProjectionSourcePixels(count: 32 * 32 * 4); witness.owner = owner
        let retained = Unmanaged.passRetained(owner).toOpaque()
        guard let provider = CGDataProvider(dataInfo: retained, data: owner.pointer, size: 32 * 32 * 4,
            releaseData: { info, _, _ in if let info { Unmanaged<ProjectionSourcePixels>.fromOpaque(info).release() } }) else {
            Unmanaged<ProjectionSourcePixels>.fromOpaque(retained).release()
            throw ImageOutputDecorationError.allocationFailed
        }
        return try XCTUnwrap(CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func send(_ selector: String, to editor: ImageEditorController) {
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString(selector), to: editor, from: nil))
    }
    private func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Native projection did not drain")
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private final class ProjectionSourceWitness { weak var owner: ProjectionSourcePixels? }
private final class ProjectionSourcePixels {
    let pointer: UnsafeMutableRawPointer
    init(count: Int) {
        pointer = .allocate(byteCount: count, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 255, count: count)
    }
    deinit { pointer.deallocate() }
}
