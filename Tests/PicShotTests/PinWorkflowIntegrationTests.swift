import XCTest
import AppKit
import PicShotCore
import PicShotFormulaRenderCore
@testable import PicShot

/// Cross-module contracts exercise real coordinator/store/controllers with tiny synthetic
/// PNGs. The synthetic formula payload is a storage fixture, not renderer or Spaces proof.
final class PinWorkflowIntegrationTests: XCTestCase {
    @MainActor func testSameDesktopModePreservesFormulaDraftAndActualChangeDiscardsIt() async throws {
        let f = try fixture(); defer { f.close() }
        let pin = try XCTUnwrap(f.session.richControllers[f.formulaID])
        let model = try XCTUnwrap(pin.latexModel)
        let before = f.store.index
        pin.showWindow(nil); pin.editLaTeX()
        try await Task.sleep(nanoseconds: 80_000_000)
        let editor = try XCTUnwrap(pin.latexEditorContentView)
        model.source = "unsaved draft"
        f.session.setDesktopVisibility(.allDesktops)
        f.session.reloadDesktopVisibility()
        XCTAssertEqual(model.source, "unsaved draft")
        XCTAssertTrue(pin.latexEditorContentView === editor)
        XCTAssertTrue(pin.hasActiveLaTeXEditorOrRender)
        f.session.setDesktopVisibility(.currentDesktop)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.source, "x")
        XCTAssertNil(pin.latexEditorContentView)
        XCTAssertFalse(model.working)
        XCTAssertTrue(f.session.richControllers[f.formulaID] === pin)
        XCTAssertEqual(f.store.index, before)
        XCTAssertFalse(pin.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        XCTAssertFalse(pin.window?.collectionBehavior.contains(.moveToActiveSpace) == true)
    }

    @MainActor func testPreparedFormulaCommitAndPendingMetadataFlushPreserveEachOther() throws {
        let f = try fixture(); defer { f.close() }
        let pin = try XCTUnwrap(f.session.richControllers[f.formulaID])
        let old = try XCTUnwrap(f.store.entry(id: f.formulaID))
        var moved = pin.presentation; moved.frame.x += 17; moved.opacity = 0.6
        pin.applyPresentation(moved); pin.onPresentationChange?(pin.presentation)
        let commit = try XCTUnwrap(pin.latexModel?.onCommit)
        // Actual prepared-result callback: exercises controller + coordinator + atomic store
        // without invoking the external renderer. Source-model undo has its own tests.
        try commit(prepared("y", width: 24))
        let saved = try XCTUnwrap(f.store.entry(id: f.formulaID))
        XCTAssertNotEqual(saved.assetFilenames, old.assetFilenames)
        XCTAssertEqual(saved.groupID, old.groupID)
        XCTAssertEqual(pin.richDocument?.latex?.source, "y")
        try f.session.flushPresentationChanges()
        XCTAssertEqual(f.store.entry(id: f.formulaID)?.presentation, moved)
        XCTAssertEqual(f.store.entry(id: f.formulaID)?.assetFilenames, saved.assetFilenames)
        XCTAssertEqual(try source(f.store, f.formulaID), "y")
        XCTAssertEqual(pin.displayedLaTeXRaster?.width, 24)
        XCTAssertEqual(try PinSessionStore(directory: f.directory).entry(id: f.formulaID), f.store.entry(id: f.formulaID))
    }

    @MainActor func testGroupUndoRedoDoesNotRevertNewerFormulaAssetsOrDraft() throws {
        let f = try fixture(); defer { f.close() }
        let pin = try XCTUnwrap(f.session.richControllers[f.formulaID])
        let before = pin.presentation
        try f.session.groupTransforms.setSelection(f.selection)
        try f.session.groupTransforms.transform(.moveAndScale(dx: 15, dy: -10, scale: 1.25))
        let transformed = pin.presentation
        let commit = try XCTUnwrap(pin.latexModel?.onCommit)
        try commit(prepared("new source", width: 26))
        let assets = try XCTUnwrap(f.store.entry(id: f.formulaID)?.assetFilenames)
        let bytes = try assetsIn(f.directory)
        pin.latexModel?.source = "pending source draft"
        try f.session.groupTransforms.undo()
        XCTAssertEqual(pin.presentation, before)
        XCTAssertEqual(pin.latexModel?.source, "pending source draft")
        XCTAssertEqual(try source(f.store, f.formulaID), "new source")
        XCTAssertEqual(f.store.entry(id: f.formulaID)?.assetFilenames, assets)
        XCTAssertEqual(try assetsIn(f.directory), bytes)
        try f.session.groupTransforms.redo()
        XCTAssertEqual(pin.presentation, transformed)
        XCTAssertEqual(try source(f.store, f.formulaID), "new source")
        XCTAssertEqual(try assetsIn(f.directory), bytes)
    }

    @MainActor func testFailedGroupWriteCannotBeReappliedByDelayedNativeCallbacksOrDebounce() async throws {
        let f = try fixture(); defer { f.close() }
        let pin = try XCTUnwrap(f.session.richControllers[f.formulaID])
        let image = try XCTUnwrap(f.session.liveControllers[f.imageID])
        // A legitimate pre-existing move must flush before the transaction snapshot.
        var moved = pin.presentation; moved.frame.x += 9
        pin.applyPresentation(moved); pin.onPresentationChange?(pin.presentation)
        try f.session.flushPresentationChanges()
        try f.session.groupTransforms.setSelection(f.selection)
        let before = f.store.index, assets = try assetsIn(f.directory)
        let manifest = f.directory.appendingPathComponent("index.json")
        let bytes = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.session.groupTransforms.transform(.moveAndScale(dx: 30, dy: 25, scale: 1.25)))
        XCTAssertEqual(f.store.index, before)
        XCTAssertEqual(pin.presentation, before.entry(id: f.formulaID)?.presentation)
        XCTAssertEqual(image.presentation, before.entry(id: f.imageID)?.presentation)
        try FileManager.default.removeItem(at: manifest); try bytes.write(to: manifest, options: .atomic)
        // AppKit may deliver resize/move after setFrame returns. Exercise those delegates
        // after rollback, and allow any real scheduled metadata task to reach its deadline.
        pin.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: pin.window))
        pin.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: pin.window))
        image.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: image.window))
        image.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: image.window))
        try await Task.sleep(nanoseconds: 80_000_000)
        try f.session.flushPresentationChanges()
        XCTAssertEqual(f.store.index, before)
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
        XCTAssertEqual(try assetsIn(f.directory), assets)
        XCTAssertFalse(f.session.groupTransforms.canUndo)
        XCTAssertTrue(f.session.groupTransforms.history.redoPlans.isEmpty)
    }

    @MainActor func testActiveFormulaRenderRefusesWholeGroupAndModeChangeCancelsBeforeCommit() async throws {
        let f = try fixture(); defer { f.close() }
        let pin = try XCTUnwrap(f.session.richControllers[f.formulaID])
        let model = try XCTUnwrap(pin.latexModel)
        try f.session.groupTransforms.setSelection(f.selection)
        let before = f.store.index
        model.source = "y"; model.apply()
        // The task has not yielded to the renderer; admission is already synchronous.
        XCTAssertTrue(model.working); XCTAssertFalse(pin.canParticipateInGroupTransform)
        XCTAssertThrowsError(try f.session.groupTransforms.transform(.align(.left)))
        XCTAssertEqual(f.store.index, before)
        f.session.setDesktopVisibility(.currentDesktop)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.working); XCTAssertEqual(model.source, "x")
        XCTAssertEqual(f.store.index, before)
        XCTAssertTrue(pin.canParticipateInGroupTransform)
    }

    @MainActor func testFormulaCloseHideAndGroupSwitchInvalidateSelectionAndHistory() throws {
        let f = try fixture(); defer { f.close() }
        try f.session.groupTransforms.setSelection(f.selection)
        try f.session.groupTransforms.transform(.align(.top))
        f.session.richControllers[f.formulaID]?.close()
        XCTAssertFalse(f.session.groupTransforms.selectedIDs.contains(f.formulaID))
        XCTAssertFalse(f.session.groupTransforms.canUndo)
        try f.session.openPin(id: f.formulaID)
        try f.session.groupTransforms.setSelection(f.selection)
        try f.session.groupTransforms.transform(.moveAndScale(dx: 10, dy: 0, scale: 1))
        try f.session.hideAll()
        XCTAssertTrue(f.session.groupTransforms.selectedIDs.isEmpty)
        XCTAssertFalse(f.session.groupTransforms.canUndo)
        XCTAssertEqual(f.session.livePinCount, 0)
        try f.session.showCurrentGroup()
        try f.session.groupTransforms.setSelection(f.selection)
        try f.session.groupTransforms.transform(.moveAndScale(dx: 5, dy: 0, scale: 1))
        let other = try f.store.createGroup(name: "Other")
        try f.session.switchGroup(id: other.id)
        XCTAssertTrue(f.session.groupTransforms.selectedIDs.isEmpty)
        XCTAssertFalse(f.session.groupTransforms.canUndo)
        XCTAssertEqual(try source(f.store, f.formulaID), "x")
    }

    @MainActor func testOwnedFormulaSaveChooserBlocksTransformsAndCancelsOnModeChangeOrHide() async throws {
        let f = try fixture(); defer { f.close() }
        let pin = try XCTUnwrap(f.session.richControllers[f.formulaID])
        pin.showWindow(nil)
        try f.session.groupTransforms.setSelection(f.selection)
        let before = f.store.index
        pin.beginLaTeXSave(.latex)
        let chooser = try XCTUnwrap(pin.latexSavePanel)
        XCTAssertFalse(pin.canParticipateInGroupTransform)
        XCTAssertThrowsError(try f.session.groupTransforms.transform(.align(.left)))
        f.session.setDesktopVisibility(.allDesktops)
        XCTAssertTrue(pin.latexSavePanel === chooser)
        f.session.setDesktopVisibility(.currentDesktop)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(pin.latexSavePanel)
        XCTAssertFalse(chooser.isVisible)
        XCTAssertNil(pin.window?.attachedSheet)
        XCTAssertEqual(f.store.index, before)
        pin.beginLaTeXSave(.latex)
        let nextChooser = try XCTUnwrap(pin.latexSavePanel)
        try f.session.hideAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(pin.latexSavePanel)
        XCTAssertFalse(nextChooser.isVisible)
        XCTAssertNil(pin.window?.attachedSheet)
        XCTAssertNil(pin.latexModel)
        XCTAssertFalse(f.session.groupTransforms.canUndo)
    }

    @MainActor func testManagerReloadCannotReplayContextDeselectionOrCoalescedHideShowSelection() async throws {
        let f = try fixture(); defer { f.close() }
        let sourceImage = try XCTUnwrap(f.session.liveControllers[f.imageID]?.currentImage)
        let extra = try f.session.add(image: sourceImage), sentinel = try f.session.add(image: sourceImage)
        let selected: Set<UUID> = [f.imageID, f.formulaID, extra]
        let manager = PinGroupsController(store: f.store, transforms: f.session.groupTransforms)
        defer { manager.close() }
        let table = try XCTUnwrap(descendant(NSTableView.self, in: manager.window?.contentView))
        let ordered = f.store.entries.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        table.selectRowIndexes(IndexSet(ordered.indices.filter { selected.contains(ordered[$0].id) }), byExtendingSelection: false)
        XCTAssertEqual(f.session.groupTransforms.selectedIDs, selected)
        let pin = try XCTUnwrap(f.session.liveControllers[f.imageID])
        let item = try XCTUnwrap(pin.actionMenu?.items.first { $0.identifier?.rawValue == "pin-group-select" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let expected = selected.subtracting([f.imageID])
        let unrelated = try XCTUnwrap(f.session.liveControllers[sentinel])
        var moved = unrelated.presentation; moved.frame.x += 7
        unrelated.applyPresentation(moved); unrelated.onPresentationChange?(unrelated.presentation)
        try f.session.flushPresentationChanges()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(f.session.groupTransforms.selectedIDs, expected)
        let before = pin.presentation
        try f.session.groupTransforms.transform(.moveAndScale(dx: 5, dy: 3, scale: 1))
        XCTAssertEqual(pin.presentation, before)
        // Both store subscriptions will see the final visible state. The explicit
        // transform reset must still win over the manager's previously selected rows.
        try f.session.hideAll(); try f.session.showCurrentGroup()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(f.session.groupTransforms.selectedIDs.isEmpty)
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
        XCTAssertFalse(f.session.groupTransforms.canUndo)
    }

    @MainActor func testGroupInspectorSameModePreservesDraftButRealModeChangeDismissesIt() throws {
        let f = try fixture(); defer { f.close() }
        try f.session.groupTransforms.setSelection(f.selection)
        let before = f.store.index
        f.session.groupTransforms.showEditor()
        let inspector = try XCTUnwrap(f.session.groupTransforms.editor)
        XCTAssertTrue(inspector.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        f.session.setDesktopVisibility(.allDesktops); f.session.reloadDesktopVisibility()
        XCTAssertTrue(f.session.groupTransforms.editor === inspector)
        f.session.setDesktopVisibility(.currentDesktop)
        XCTAssertNil(f.session.groupTransforms.editor)
        XCTAssertFalse(inspector.window?.isVisible == true)
        XCTAssertEqual(f.store.index, before)
        f.session.groupTransforms.showEditor()
        XCTAssertFalse(f.session.groupTransforms.editor?.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        XCTAssertFalse(f.session.groupTransforms.editor?.window?.collectionBehavior.contains(.moveToActiveSpace) == true)
    }

    @MainActor func testInlineCancelClearsQueuedFormulaSaveBeforePublicationAndReleasesAdmissionAfterDrain() async throws {
        let f = try fixture(); defer { f.close() }
        let pin = try XCTUnwrap(f.session.richControllers[f.formulaID]), model = try XCTUnwrap(pin.latexModel)
        let target = f.directory.appendingPathComponent("chosen-new-copy.tex")
        ImageExportService.queue.isSuspended = true
        defer { ImageExportService.queue.isSuspended = false }
        pin.showWindow(nil)
        try pin.saveLaTeX(.latex, to: target)
        await Task.yield()
        XCTAssertTrue(model.saving); XCTAssertFalse(pin.canParticipateInGroupTransform)
        XCTAssertEqual(LaTeXPinSaveLease.activeJobs, 1)
        model.cancel() // Exact Stop action used by the inline editor.
        XCTAssertFalse(model.saving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(LaTeXPinSaveLease.activeJobs, 1, "The slot stays occupied until the queued operation drains")
        ImageExportService.queue.isSuspended = false
        for _ in 0..<100 {
            if LaTeXPinSaveLease.activeJobs == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(LaTeXPinSaveLease.activeJobs, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try source(f.store, f.formulaID), "x")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).contains { $0.hasPrefix(".picshot-save-") })
    }

    @MainActor func testNativeFractionalFrameScaleAndMoveRequiresExactAppKitResult() throws {
        let f = try fixture(); defer { f.close() }
        let formula = try XCTUnwrap(f.session.richControllers[f.formulaID])
        let image = try XCTUnwrap(f.session.liveControllers[f.imageID])
        let requestedFormula = PinPresentation(frame: PinWindowFrame(x: -180.25, y: 100.125, width: 200.5, height: 100.25))
        let requestedImage = PinPresentation(frame: PinWindowFrame(x: 350.625, y: -50.375, width: 240.25, height: 120.5))
        formula.applyPresentation(requestedFormula); formula.onPresentationChange?(formula.presentation)
        image.applyPresentation(requestedImage); image.onPresentationChange?(image.presentation)
        try f.session.flushPresentationChanges()
        let before = f.store.index, assets = try assetsIn(f.directory)
        let transform = PinGroupTransform.moveAndScale(dx: 0.375, dy: -0.625, scale: 1.25)
        let proposed = try PinGroupTransformPlan(index: before, selectedIDs: f.selection, transform: transform)
        let plan = try f.session.groupTransforms.plannedTransform(index: before, selectedIDs: f.selection, transform: transform)
        print("Fractional AppKit initial request/observed: formula=\(requestedFormula.frame)/\(formula.presentation.frame), image=\(requestedImage.frame)/\(image.presentation.frame)")
        print("Fractional group proposed/canonical targets (strict comparison): \(proposed.changes)/\(plan.changes)")
        try f.session.groupTransforms.setSelection(f.selection)
        do {
            try f.session.groupTransforms.transform(transform)
            let committed = try plan.applying(to: before)
            XCTAssertEqual(f.store.index, committed)
            XCTAssertEqual(f.session.groupTransforms.history.undoPlans, [plan])
            XCTAssertEqual(try assetsIn(f.directory), assets)
            for change in plan.changes {
                let actual = f.session.liveControllers[change.id]?.presentation ?? f.session.richControllers[change.id]?.presentation
                XCTAssertEqual(actual, change.after, "Canonical placement must be exact; no tolerance substitution")
            }
            try f.session.groupTransforms.undo()
            XCTAssertEqual(f.store.index, before)
            XCTAssertEqual(formula.presentation, before.entry(id: f.formulaID)?.presentation)
            XCTAssertEqual(image.presentation, before.entry(id: f.imageID)?.presentation)
            try f.session.groupTransforms.redo()
            XCTAssertEqual(f.store.index, committed)
            for change in plan.changes {
                let actual = f.session.liveControllers[change.id]?.presentation ?? f.session.richControllers[change.id]?.presentation
                XCTAssertEqual(actual, change.after, "Redo must replay the recorded canonical target")
            }
            XCTAssertEqual(try assetsIn(f.directory), assets)
        } catch {
            print("Fractional group operation rejected by native AppKit: \(error); post-rollback formula=\(formula.presentation.frame), image=\(image.presentation.frame)")
            XCTAssertEqual(f.store.index, before)
            XCTAssertEqual(formula.presentation, before.entry(id: f.formulaID)?.presentation)
            XCTAssertEqual(image.presentation, before.entry(id: f.imageID)?.presentation)
            XCTFail("Native fractional transform did not apply exactly: \(error). Inspect real window rounding; keep geometry/stale checks strict.")
        }
    }

    @MainActor private func descendant<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.compactMap { descendant(type, in: $0) }.first
    }

    @MainActor private func fixture() throws -> PinWorkflowFixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-PinWorkflow-" + UUID().uuidString)
        let store = try PinSessionStore(directory: directory)
        let session = PinSessionCoordinator(store: store, presentWindows: false,
            desktopVisibilityService: PinDesktopVisibilityService(defaults: nil), debounceNanoseconds: 10_000_000,
            screens: { [CGRect(x: -2000, y: -1000, width: 6000, height: 4000)] })
        let formulaID = try session.add(rich: prepared("x"))
        let image = try XCTUnwrap(CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let imageID = try session.add(image: image)
        let formulaPresentation = PinPresentation(frame: PinWindowFrame(x: 80, y: 100, width: 200, height: 100))
        let imagePresentation = PinPresentation(frame: PinWindowFrame(x: 350, y: 200, width: 240, height: 120))
        session.richControllers[formulaID]?.applyPresentation(formulaPresentation)
        session.richControllers[formulaID]?.onPresentationChange?(formulaPresentation)
        session.liveControllers[imageID]?.applyPresentation(imagePresentation)
        session.liveControllers[imageID]?.onPresentationChange?(imagePresentation)
        try session.flushPresentationChanges()
        return PinWorkflowFixture(directory: directory, store: store, session: session, formulaID: formulaID, imageID: imageID)
    }
    @MainActor private func source(_ store: PinSessionStore, _ id: UUID) throws -> String? {
        try JSONDecoder().decode(PinRichDocument.self, from: store.richData(id: id)).latex?.source
    }
    private func assetsIn(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent != "index.json" {
            result[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return result
    }
    private func prepared(_ source: String, width: Int = 20) throws -> PreparedRichPin {
        let request = FormulaRenderRequest(latex: source)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 12, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let result = FormulaRenderResult(latex: source, svg: "<svg />", mathML: "<math ><mi>x</mi></math>", png: png,
            pdf: Data("%PDF-storage-fixture".utf8), width: width, height: 12,
            pointWidth: Double(width) / Double(request.scale), pointHeight: 12 / Double(request.scale))
        return try PreparedRichPin(formula: request, result: result)
    }
}

@MainActor private struct PinWorkflowFixture {
    let directory: URL
    let store: PinSessionStore
    let session: PinSessionCoordinator
    let formulaID: UUID
    let imageID: UUID
    var selection: Set<UUID> { [formulaID, imageID] }
    func close() { try? session.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
}
