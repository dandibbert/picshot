import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor
final class EditorOutputPinRecoveryTests: XCTestCase {
    private let decoration = ImageOutputDecoration(enabled: true, cornerRadius: 18, borderEnabled: true,
        borderWidth: 2, shadowEnabled: true, shadowBlur: 3, shadowOffsetX: 4, shadowOffsetY: 6)

    func testDecoratedFrozenPinCountFailureKeepsEditsUntilDurableRetry() async throws {
        try await checkPinCountFailure(decorated: true)
    }

    func testUndecoratedFrozenPinCountFailureKeepsEditsUntilDurableRetry() async throws {
        try await checkPinCountFailure(decorated: false)
    }

    private func checkPinCountFailure(decorated: Bool) async throws {
        let f = try fixture(policy: PinSessionPolicy(maxPins: 1), decorated: decorated)
        defer { f.close() }
        let previous = try f.session.add(image: f.source)
        let before = f.store.index, filesBefore = try fileBytes(f.directory)
        try await pin(f.editor)
        XCTAssertEqual(f.log.errors.first as? PinSessionError, .capacityExceeded)
        XCTAssertEqual(f.store.index, before)
        XCTAssertEqual(try fileBytes(f.directory), filesBefore)
        XCTAssertEqual(f.session.livePinIDs, [previous])
        try assertRecoverable(f)

        // Free the actual live-pin quota, then retry the unchanged editable capture.
        f.session.liveControllers[previous]?.close()
        try f.store.remove(id: previous)
        try await assertSuccessfulRetry(f)
    }

    func testDecoratedFrozenPixelQuotaFailureKeepsEditsUntilDurableRetry() async throws {
        let layout = try ImageOutputDecorationLayout.make(width: 320, height: 240, decoration: decoration)
        let pairPixels = Int64(320 * 240 + layout.width * layout.height)
        // Two pins fit the count limit. The source/current pair fits by itself,
        // while one existing protected live raster puts the aggregate over budget.
        let f = try fixture(policy: PinSessionPolicy(maxPins: 2, maxPixelCount: pairPixels))
        defer { f.close() }
        let previous = try f.session.add(image: f.source)
        let before = f.store.index, filesBefore = try fileBytes(f.directory)
        try await pin(f.editor)
        XCTAssertEqual(f.log.errors.first as? PinSessionError, .capacityExceeded)
        XCTAssertEqual(f.store.index, before)
        XCTAssertEqual(try fileBytes(f.directory), filesBefore)
        XCTAssertEqual(f.session.livePinIDs, [previous])
        try assertRecoverable(f)

        f.session.liveControllers[previous]?.close()
        try f.store.remove(id: previous)
        try await assertSuccessfulRetry(f)
        XCTAssertEqual(f.store.entries.flatMap(\.assets).reduce(Int64(0)) { $0 + $1.pixelCount }, pairPixels)
    }

    func testManifestCommitFailureRetainsFrozenEditorAndRollsBackBothStagedPNGs() async throws {
        let f = try fixture(); defer { f.close() }
        let before = f.store.index, filesBefore = try fileBytes(f.directory)
        let manifest = f.directory.appendingPathComponent("index.json")
        let manifestBytes = try Data(contentsOf: manifest)
        // A real filesystem failure occurs after both source/current PNG writes.
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        try await pin(f.editor)
        XCTAssertEqual(f.log.errors.count, 1)
        XCTAssertEqual(f.store.index, before)
        XCTAssertTrue(f.session.livePinIDs.isEmpty)
        XCTAssertEqual(try names(f.directory), Set(filesBefore.keys), "No staged or temporary raster may survive a failed commit")
        try assertRecoverable(f)

        try FileManager.default.removeItem(at: manifest)
        try manifestBytes.write(to: manifest)
        XCTAssertEqual(try fileBytes(f.directory), filesBefore)
        try await assertSuccessfulRetry(f)
    }

    func testRasterWriteFailureRetainsFrozenEditorUntilStorageIsRepairedAndRetried() async throws {
        let f = try fixture(); defer { f.close() }
        let before = f.store.index, filesBefore = try fileBytes(f.directory)
        let backup = f.root.appendingPathComponent("session-backup", isDirectory: true)
        let obstructionURL = f.root.appendingPathComponent("session", isDirectory: false)
        let obstruction = Data("A fixture file blocks the session directory".utf8)
        try FileManager.default.moveItem(at: f.directory, to: backup)
        try obstruction.write(to: obstructionURL)
        try await pin(f.editor)
        XCTAssertEqual(f.log.errors.count, 1)
        XCTAssertEqual(f.store.index, before)
        XCTAssertTrue(f.session.livePinIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: obstructionURL), obstruction)
        XCTAssertEqual(try fileBytes(backup), filesBefore)
        try assertRecoverable(f)

        try FileManager.default.removeItem(at: obstructionURL)
        try FileManager.default.moveItem(at: backup, to: f.directory)
        try await assertSuccessfulRetry(f)
    }

    func testLegacySingleImageCallbackCompletesBeforeFrozenEditorClosesOnce() async throws {
        _ = NSApplication.shared
        let capture = try frozenCapture()
        var calls = 0, closes = 0, wasOpenAtDelivery = false
        weak var weakEditor: ImageEditorController?
        let editor = ImageEditorController(image: capture.image, presentation: capture.presentation,
            onSave: { _ in XCTFail("Pin must not add history") }, onPin: { _ in
                calls += 1
                wasOpenAtDelivery = weakEditor?.isClosed == false && weakEditor?.initialOriginalImage != nil
            }, onOCR: { _ in }, saveWorkflow: SaveWorkflowPresenter(isSmoke: true))
        weakEditor = editor; defer { editor.close() }
        editor.onClose = { closes += 1 }; editor.showWindow(nil)
        _ = try editor.applyOutputDecoration(decoration)
        try await pin(editor)
        XCTAssertTrue(wasOpenAtDelivery)
        XCTAssertTrue(editor.isClosed)
        XCTAssertEqual(calls, 1); XCTAssertEqual(closes, 1)
        try await pin(editor); editor.close()
        XCTAssertEqual(calls, 1); XCTAssertEqual(closes, 1)
    }

    private func assertRecoverable(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(f.editor.isClosed, file: file, line: line)
        XCTAssertEqual(f.log.closes, 0, file: file, line: line)
        XCTAssertTrue(f.log.durableIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(f.log.openAtDelivery, [true], file: file, line: line)
        XCTAssertTrue(f.editor.window?.isVisible == true, file: file, line: line)
        XCTAssertNotNil(f.editor.window?.contentView, file: file, line: line)
        XCTAssertEqual(f.editor.window?.frame, f.windowFrame, file: file, line: line)
        XCTAssertEqual(f.editor.editorSelectionFrame, f.selectionFrame, file: file, line: line)
        XCTAssertTrue(f.editor.initialOriginalImage === f.source, file: file, line: line)
        XCTAssertTrue(f.editor.annotationCanvas.image === f.source, file: file, line: line)
        XCTAssertTrue(f.editor.captureBoundaryWorkspace.frozenImage === f.frozen, file: file, line: line)
        XCTAssertEqual(f.editor.captureAspectRatio, try CaptureAspectRatio(numerator: 4, denominator: 3), file: file, line: line)
        XCTAssertEqual(f.editor.annotationCanvas.annotations.map(\.id), [f.mark.id], file: file, line: line)
        XCTAssertEqual(f.editor.annotationCanvas.annotations.first?.points, f.mark.points, file: file, line: line)
        XCTAssertEqual(try pixels(f.editor.annotationCanvas.image), f.sourcePixels, file: file, line: line)
        XCTAssertEqual(try pixels(XCTUnwrap(f.editor.annotationCanvas.flattened())), f.flattenedPixels, file: file, line: line)
        XCTAssertEqual(f.editor.outputDecoration, f.decoration, file: file, line: line)
        XCTAssertFalse(f.editor.outputProjectionIsPending, file: file, line: line)
        XCTAssertFalse(EditorOutputProjection.shared.isBusy, file: file, line: line)
        XCTAssertEqual(EditorOutputProjection.shared.reservedBytes, 0, file: file, line: line)

        // A failed pin leaves the user's editing history usable, not just visible pixels.
        send("undoEdit", to: f.editor)
        if f.decoration.enabled {
            XCTAssertEqual(f.editor.outputDecoration, .none, file: file, line: line)
            XCTAssertEqual(f.editor.annotationCanvas.annotations.map(\.id), [f.mark.id], file: file, line: line)
        } else {
            XCTAssertTrue(f.editor.annotationCanvas.annotations.isEmpty, file: file, line: line)
        }
        send("redoEdit", to: f.editor)
        XCTAssertEqual(f.editor.outputDecoration, f.decoration, file: file, line: line)
        XCTAssertEqual(f.editor.annotationCanvas.annotations.map(\.id), [f.mark.id], file: file, line: line)
    }

    private func assertSuccessfulRetry(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await pin(f.editor)
        XCTAssertEqual(f.log.attempts, 2, file: file, line: line)
        XCTAssertEqual(f.log.errors.count, 1, file: file, line: line)
        XCTAssertEqual(f.log.openAtDelivery, [true, true], file: file, line: line)
        XCTAssertEqual(f.log.durableIDs.count, 1, file: file, line: line)
        let id = try XCTUnwrap(f.log.durableIDs.first)
        XCTAssertEqual(f.log.idsOnClose, [id], "The pair must already be in the on-disk manifest when close fires", file: file, line: line)
        XCTAssertEqual(f.log.closes, 1, file: file, line: line)
        XCTAssertTrue(f.editor.isClosed, file: file, line: line)
        XCTAssertNil(f.editor.initialOriginalImage, file: file, line: line)
        XCTAssertNil(f.editor.captureBoundaryWorkspace.frozenImage, file: file, line: line)
        XCTAssertNil(f.editor.window?.contentView, file: file, line: line)
        XCTAssertFalse(f.editor.window?.isVisible == true, file: file, line: line)
        XCTAssertEqual(f.session.livePinIDs, [id], file: file, line: line)
        let saved = try XCTUnwrap(f.store.entry(id: id))
        XCTAssertNotEqual(saved.original.filename, saved.current.filename, file: file, line: line)
        XCTAssertEqual(saved.assets.count, 2, file: file, line: line)
        XCTAssertEqual(try names(f.directory), Set(["index.json"] + saved.assetFilenames), file: file, line: line)
        let restored = try PinSessionStore(directory: f.directory, policy: f.store.policy)
        XCTAssertEqual(restored.entries.map(\.id), [id], file: file, line: line)
        XCTAssertEqual(try pixels(XCTUnwrap(restored.image(id: id, original: true))), f.sourcePixels, file: file, line: line)
        XCTAssertEqual(try pixels(XCTUnwrap(restored.image(id: id))), f.outputPixels, file: file, line: line)
        try await pin(f.editor); f.editor.close()
        XCTAssertEqual(f.log.attempts, 2, file: file, line: line)
        XCTAssertEqual(f.log.closes, 1, file: file, line: line)
        XCTAssertEqual(f.store.entries.map(\.id), [id], file: file, line: line)
    }

    private func fixture(policy: PinSessionPolicy = PinSessionPolicy(), decorated: Bool = true) throws -> Fixture {
        _ = NSApplication.shared
        let capture = try frozenCapture(), source = capture.image
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotEditorPinRecovery-" + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("session", isDirectory: true)
        let store = try PinSessionStore(directory: directory, policy: policy)
        let session = PinSessionCoordinator(store: store, presentWindows: false,
            desktopVisibilityService: PinDesktopVisibilityService(defaults: nil), ocrPreferences: PinOCRPreferences(defaults: nil))
        let log = DeliveryLog()
        weak var weakEditor: ImageEditorController?
        let editor = ImageEditorController(image: source, presentation: capture.presentation,
            onSave: { _ in XCTFail("Pin must not add history") }, onPin: { _ in XCTFail("Original-aware failure must not fall back") },
            onOCR: { _ in }, saveWorkflow: SaveWorkflowPresenter(isSmoke: true), onPinWithOriginal: { original, current in
                log.attempts += 1
                log.openAtDelivery.append(weakEditor?.isClosed == false && weakEditor?.initialOriginalImage != nil)
                do {
                    log.durableIDs.append(try session.add(originalImage: original, currentImage: current))
                    return true
                } catch {
                    log.errors.append(error)
                    return false
                }
            })
        weakEditor = editor
        editor.onOutputError = { error in XCTFail("Unexpected projection failure: \(error)") }
        editor.onClose = {
            log.closes += 1
            let data = try? Data(contentsOf: directory.appendingPathComponent("index.json"))
            log.idsOnClose = data.flatMap { try? JSONDecoder().decode(PinSessionIndex.self, from: $0) }?.entries.map(\.id) ?? []
        }
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded()
        let mark = ImageAnnotation(tool: .redact, points: [CGPoint(x: 30, y: 80), CGPoint(x: 140, y: 160)])
        editor.annotationCanvas.add(mark)
        if decorated { _ = try editor.applyOutputDecoration(decoration) }
        let flattened = try XCTUnwrap(editor.annotationCanvas.flattened())
        let output = try ImageOutputDecorationRenderer.project(flattened: flattened, decoration: editor.outputDecoration)
        return Fixture(root: root, directory: directory, store: store, session: session, editor: editor, log: log,
            source: source, frozen: try XCTUnwrap(capture.presentation).frozenImage, mark: mark,
            decoration: editor.outputDecoration, windowFrame: try XCTUnwrap(editor.window).frame,
            selectionFrame: editor.editorSelectionFrame, sourcePixels: try pixels(source),
            flattenedPixels: try pixels(flattened), outputPixels: try pixels(output))
    }

    private func frozenCapture() throws -> CapturedImage {
        try CapturedImage.frozenPixelRegion(image: EditorOutputDecorationNativeFixture.makeSource(), displayID: 7,
            displayFrame: CGRect(x: 0, y: 0, width: 640, height: 400), pixelFrame: CGRect(x: 24, y: 24, width: 320, height: 240),
            aspectRatio: CaptureAspectRatio(numerator: 4, denominator: 3))
    }

    private func pin(_ editor: ImageEditorController) async throws {
        send("pinResult", to: editor)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while editor.outputProjectionIsPending, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(editor.outputProjectionIsPending, "Native projection did not drain")
    }

    private func send(_ selector: String, to editor: ImageEditorController) {
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString(selector), to: editor, from: nil))
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] { try EditorOutputDecorationNativeFixture.raster(image) }
    private func names(_ directory: URL) throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) }
    private func fileBytes(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: names(directory).map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) })
    }

    private final class DeliveryLog {
        var attempts = 0, closes = 0
        var errors: [Error] = []
        var durableIDs: [UUID] = [], idsOnClose: [UUID] = []
        var openAtDelivery: [Bool] = []
    }
    private struct Fixture {
        let root: URL, directory: URL
        let store: PinSessionStore, session: PinSessionCoordinator, editor: ImageEditorController
        let log: DeliveryLog
        let source: CGImage, frozen: CGImage
        let mark: ImageAnnotation, decoration: ImageOutputDecoration
        let windowFrame: CGRect, selectionFrame: CGRect
        let sourcePixels: [UInt8], flattenedPixels: [UInt8], outputPixels: [UInt8]
        @MainActor func close() {
            editor.close(); try? session.prepareForTermination()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
