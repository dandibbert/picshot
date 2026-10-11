import AppKit
import Combine
import XCTest
import PicShotCore
@testable import PicShot

/// Actual managed windows, persistent store bytes, and retained lifecycle callbacks.
/// These tests require a native display; headless membership is covered separately.
@MainActor final class PinVisibilityIsolationCoordinatorTests: XCTestCase {
    func testRepeatedMixedIsolationPreservesOwnersContentPresentationAndEveryDiskFile() throws {
        let f = try fixture(); defer { f.close() }
        let ids = try addMixedPins(to: f)
        let owners = try snapshots(f)
        let index = f.store.index, files = try diskSnapshot(f.directory)
        var publications = 0
        let subscription = f.store.$index.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<25 {
            try f.session.isolatePins([ids[0], ids[1]])
            assertVisible([ids[0], ids[1]], in: f)
            XCTAssertEqual(f.session.visibilityIsolation.restoreIDs, Set(ids))
            // A new subset may include a member hidden by this same baseline.
            try f.session.isolatePins([ids[2]])
            assertVisible([ids[2]], in: f)
            XCTAssertEqual(f.session.visibilityIsolation.restoreIDs, Set(ids))
            try f.session.restoreVisibilityIsolation()
            assertVisible(Set(ids), in: f)
            XCTAssertFalse(f.session.hasVisibilityIsolation)
            try assertUnchanged(owners, in: f)
        }
        try f.session.restoreVisibilityIsolation() // Repeated restore is a strict no-op.
        try f.session.flushPresentationChanges()
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(f.store.index, index)
        XCTAssertEqual(try diskSnapshot(f.directory), files)
        XCTAssertEqual(f.constructions.count, 1, "Isolation never reconstructs the image owner")
        XCTAssertTrue(f.errors.messages.isEmpty)
    }

    func testRestoreNeverRevealsOriginallyHiddenUnloadedArchivedOrOtherGroupPins() throws {
        let f = try fixture(); defer { f.close() }
        let first = try f.session.add(image: raster())
        let second = try addText(to: f, text: "visible sibling")
        let hidden = try addText(to: f, text: "already ordered out")
        try XCTUnwrap(f.session.richControllers[hidden]?.window).orderOut(nil)
        let unloaded = try f.store.add(image: raster(), title: "saved but never loaded")
        let archived = try f.store.add(image: raster(), title: "archived")
        try f.store.archive(id: archived.id)
        let other = try f.store.createGroup(name: "Hidden other group")
        let inactive = try f.store.add(image: raster(), title: "inactive")
        try f.store.movePin(id: inactive.id, to: other.id)
        try f.store.setGroupHidden(id: other.id, hidden: true)
        let expectedLive: Set<UUID> = [first, second, hidden]
        let files = try diskSnapshot(f.directory), index = f.store.index
        try f.session.isolatePins([first])
        XCTAssertEqual(f.session.visibilityIsolation.restoreIDs, [first, second])
        try f.session.reconcileVisiblePins()
        XCTAssertEqual(f.session.livePinIDs, expectedLive)
        try f.session.restoreVisibilityIsolation()
        assertVisible([first, second], in: f)
        XCTAssertEqual(f.session.livePinIDs, expectedLive)
        XCTAssertFalse(try XCTUnwrap(f.session.richControllers[hidden]?.window).isVisible)
        for id in [unloaded.id, archived.id, inactive.id] { XCTAssertFalse(f.session.livePinIDs.contains(id)) }
        XCTAssertEqual(f.store.index, index)
        XCTAssertEqual(try diskSnapshot(f.directory), files)
    }

    func testNewImageAndRichPinsJoinExistingBaselineWithoutLoadingSavedPins() throws {
        let f = try fixture(); defer { f.close() }
        let first = try f.session.add(image: raster()), sibling = try addText(to: f)
        let unloaded = try f.store.add(image: raster(), title: "unloaded")
        try f.session.isolatePins([first])
        let newImage = try f.session.add(image: raster()), newText = try addText(to: f, text: "new")
        assertVisible([first, newImage, newText], in: f)
        let expected: Set<UUID> = [first, sibling, newImage, newText]
        XCTAssertEqual(f.session.visibilityIsolation.restoreIDs, expected)
        XCTAssertEqual(f.session.visibilityIsolation.hiddenIDs, [sibling])
        XCTAssertFalse(f.session.livePinIDs.contains(unloaded.id))
        let index = f.store.index, files = try diskSnapshot(f.directory)
        try f.session.isolatePins([newText])
        assertVisible([newText], in: f)
        try f.session.restoreVisibilityIsolation()
        assertVisible(expected, in: f)
        XCTAssertEqual(f.store.index, index)
        XCTAssertEqual(try diskSnapshot(f.directory), files)
        XCTAssertFalse(f.session.livePinIDs.contains(unloaded.id))
    }

    func testClosedDeletedAndMovedMembersArePrunedAndNeverResurrected() throws {
        let f = try fixture(); defer { f.close() }
        let keep = try addText(to: f, text: "keep")
        let closedImage = try f.session.add(image: raster()), closedText = try addText(to: f, text: "close")
        let deleted = try f.session.add(image: raster()), moved = try addText(to: f, text: "move")
        let retained = try f.session.add(image: raster())
        let destination = try f.store.createGroup(name: "Destination")
        try f.session.isolatePins([keep])
        let imageOwner = try XCTUnwrap(f.session.liveControllers[closedImage])
        let textOwner = try XCTUnwrap(f.session.richControllers[closedText])
        imageOwner.close(); textOwner.close()
        try f.store.remove(id: deleted)
        try f.store.movePin(id: moved, to: destination.id)
        try f.session.reconcileVisiblePins()
        XCTAssertEqual(f.session.visibilityIsolation.restoreIDs, [keep, retained])
        XCTAssertEqual(f.session.visibilityIsolation.hiddenIDs, [retained])
        XCTAssertEqual(f.session.livePinIDs, [keep, retained])
        let index = f.store.index, files = try diskSnapshot(f.directory)
        try f.session.restoreVisibilityIsolation()
        assertVisible([keep, retained], in: f)
        XCTAssertEqual(f.store.index, index)
        XCTAssertEqual(try diskSnapshot(f.directory), files)
        XCTAssertEqual(f.store.entry(id: closedImage)?.isVisible, false)
        XCTAssertEqual(f.store.entry(id: closedText)?.isVisible, false)
        XCTAssertNil(f.store.entry(id: deleted))
        XCTAssertEqual(f.store.entry(id: moved)?.groupID, destination.id)
        XCTAssertNil(imageOwner.window?.contentView); XCTAssertNil(textOwner.window?.contentView)
    }

    func testRemovingEntireBaselineDoesNotLoadPreviouslyUnloadedPins() throws {
        for action in 0..<3 {
            let f = try fixture(); defer { f.close() }
            let first = try f.session.add(image: raster()), second = try addText(to: f)
            let unloaded = try f.store.add(image: raster(), title: "Do not reopen implicitly")
            let destination = try f.store.createGroup(name: "Destination")
            try f.session.isolatePins([first])
            for id in [first, second] {
                switch action {
                case 0: try f.store.movePin(id: id, to: destination.id)
                case 1: try f.store.remove(id: id)
                default:
                    f.session.liveControllers[id]?.close()
                    f.session.richControllers[id]?.close()
                }
            }
            try f.session.reconcileVisiblePins()
            XCTAssertEqual(f.session.livePinCount, 0,
                "Exhausting the original baseline must not turn reconciliation into Show Group")
            XCTAssertFalse(f.session.livePinIDs.contains(unloaded.id))
            try f.session.reconcileVisiblePins()
            XCTAssertEqual(f.session.livePinCount, 0,
                "A later generic reconcile must keep the original unloaded member excluded too")
            XCTAssertTrue(f.session.hasVisibilityIsolation)
            XCTAssertTrue(f.session.visibilityIsolation.restoreIDs.isEmpty)
            try f.session.restoreVisibilityIsolation()
            XCTAssertEqual(f.session.livePinCount, 0)
            try f.session.showCurrentGroup()
            assertVisible([unloaded.id], in: f)
        }
    }

    func testGroupSwitchGroupHideAndHideAllInvalidateWithoutRevealingOldWindows() throws {
        for action in 0..<3 {
            let f = try fixture(); defer { f.close() }
            let ids = try addMixedPins(to: f)
            let originalGroup = f.store.index.activeGroupID
            let other = try f.store.createGroup(name: "Other")
            let probes = try f.session.liveControllers.values.map { try ClosedAuxiliaryWindowProbe($0) }
                + f.session.richControllers.values.map { try ClosedAuxiliaryWindowProbe($0) }
            try f.session.isolatePins([ids[0]])
            switch action {
            case 0: try f.session.switchGroup(id: other.id)
            case 1: try f.session.hideCurrentGroup()
            default: try f.session.hideAll()
            }
            XCTAssertFalse(f.session.hasVisibilityIsolation)
            XCTAssertTrue(f.session.visibilityIsolation.restoreIDs.isEmpty)
            XCTAssertEqual(f.session.livePinCount, 0)
            for probe in probes { probe.assertDetached() }
            let index = f.store.index, files = try diskSnapshot(f.directory)
            try f.session.restoreVisibilityIsolation()
            XCTAssertEqual(f.session.livePinCount, 0)
            XCTAssertEqual(f.store.index, index)
            XCTAssertEqual(try diskSnapshot(f.directory), files)
            if action == 0 { try f.session.switchGroup(id: originalGroup) }
            else { try f.session.showCurrentGroup() }
            assertVisible(Set(ids), in: f)
            XCTAssertFalse(f.session.hasVisibilityIsolation)
            for id in ids { XCTAssertEqual(f.store.entry(id: id)?.isVisible, true) }
            for probe in probes { probe.assertDetached() }
        }
    }

    func testExplicitShowAndReopenEndIsolationThenLoadNormally() throws {
        for reopen in [false, true] {
            let f = try fixture(); defer { f.close() }
            let imageID = try f.session.add(image: raster()), textID = try addText(to: f)
            let unloaded = try f.store.add(image: raster(), title: "unloaded")
            let archived = try f.store.add(image: raster(), title: "archived")
            try f.store.archive(id: archived.id)
            let imageOwner = try XCTUnwrap(f.session.liveControllers[imageID])
            let textOwner = try XCTUnwrap(f.session.richControllers[textID])
            try f.session.isolatePins([imageID])
            if reopen { try f.session.openPin(id: archived.id) }
            else { try f.session.showCurrentGroup() }
            XCTAssertFalse(f.session.hasVisibilityIsolation)
            var expected: Set<UUID> = [imageID, textID, unloaded.id]
            if reopen { expected.insert(archived.id) }
            assertVisible(expected, in: f)
            XCTAssertTrue(f.session.liveControllers[imageID] === imageOwner)
            XCTAssertTrue(f.session.richControllers[textID] === textOwner)
            XCTAssertEqual(f.store.entry(id: archived.id)?.isVisible, reopen)
            try f.session.restoreVisibilityIsolation()
            assertVisible(expected, in: f)
        }
    }

    func testInvalidSelectionAndHeadlessEligibilityDoNotChangeBaselineOrPersistence() throws {
        for presentWindows in [true, false] {
            let f = try fixture(presentWindows: presentWindows); defer { f.close() }
            let imageID = try f.session.add(image: raster()), textID = try addText(to: f)
            try f.session.groupTransforms.setSelection([imageID, textID])
            try f.session.isolatePins([imageID])
            XCTAssertEqual(f.session.groupTransforms.selectedIDs, [imageID])
            XCTAssertEqual(f.session.groupTransformEligibleIDs, [imageID])
            let state = f.session.visibilityIsolation, files = try diskSnapshot(f.directory)
            let invalidSelections: [Set<UUID>] = [[], [UUID()], [imageID, UUID()]]
            for ids in invalidSelections {
                XCTAssertThrowsError(try f.session.isolatePins(ids))
                XCTAssertEqual(f.session.visibilityIsolation, state)
                XCTAssertEqual(f.session.visiblePinIDsForIsolation, [imageID])
            }
            XCTAssertThrowsError(try f.session.groupTransforms.setSelection([textID]))
            XCTAssertEqual(try diskSnapshot(f.directory), files)
        }
    }

    func testActiveTextDraftRefusesNewSubsetAtomicallyAndKeepsPreviousBaseline() throws {
        try PinGroupOrderNativeTests.withApplicationLoop { [self] in
            let f = try fixture(); defer { f.close() }
            let imageID = try f.session.add(image: raster()), textID = try addText(to: f)
            let third = try f.session.add(image: raster())
            try f.session.isolatePins([imageID, textID])
            let pin = try XCTUnwrap(f.session.richControllers[textID])
            pin.editPlainText()
            let editor = try XCTUnwrap(pin.textEditController)
            replace(editor.textView, with: "Unsaved draft\n草稿 🐱")
            let selection = NSRange(location: 2, length: 3)
            editor.textView.setSelectedRange(selection)
            let draft = editor.textView.string, history = editor.history.current
            let state = f.session.visibilityIsolation, files = try diskSnapshot(f.directory)
            XCTAssertThrowsError(try f.session.isolatePins([imageID]))
            XCTAssertEqual(f.session.visibilityIsolation, state)
            assertVisible([imageID, textID], in: f)
            XCTAssertTrue(pin.textEditController === editor)
            XCTAssertTrue(editor.window?.isVisible == true)
            XCTAssertTrue(editor.window?.sheetParent === pin.window)
            XCTAssertEqual(editor.textView.string, draft)
            XCTAssertEqual(editor.textView.selectedRange(), selection)
            XCTAssertEqual(editor.history.current, history)
            XCTAssertFalse(editor.completed)
            XCTAssertEqual(try diskSnapshot(f.directory), files)
            editor.close()
            try f.session.isolatePins([imageID])
            XCTAssertEqual(f.session.visibilityIsolation.hiddenIDs, [textID, third])
        }
    }

    func testVisibleAnnotationEditorRefusesIsolationWithoutLosingDraftOrShowingOwner() throws {
        let f = try fixture(); defer { f.close() }
        let editedID = try f.session.add(image: raster()), keep = try addText(to: f)
        let spare = try f.session.add(image: raster())
        let pin = try XCTUnwrap(f.session.liveControllers[editedID])
        pin.showAnnotations()
        let editor = try XCTUnwrap(pin.annotationEditor)
        editor.annotationCanvas.add(ImageAnnotation(tool: .rectangle,
            points: [CGPoint(x: 5, y: 5), CGPoint(x: 25, y: 20)]))
        let draft = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
        let original = pin.image, current = pin.currentImage, files = try diskSnapshot(f.directory)
        XCTAssertFalse(try XCTUnwrap(pin.window).isVisible)
        XCTAssertTrue(editor.window?.isVisible == true)
        XCTAssertThrowsError(try f.session.isolatePins([keep]))
        XCTAssertFalse(f.session.hasVisibilityIsolation)
        XCTAssertEqual(f.session.visibilityIsolation, PinVisibilityIsolation())
        XCTAssertTrue(pin.annotationEditor === editor); XCTAssertFalse(editor.isClosed)
        XCTAssertFalse(try XCTUnwrap(pin.window).isVisible)
        XCTAssertTrue(editor.window?.isVisible == true)
        XCTAssertTrue(f.session.liveControllers[spare]?.window?.isVisible == true)
        XCTAssertTrue(f.session.richControllers[keep]?.window?.isVisible == true)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document), draft)
        XCTAssertTrue(pin.image === original); XCTAssertTrue(pin.currentImage === current)
        XCTAssertEqual(try diskSnapshot(f.directory), files)
    }

    func testActiveImageExportRefusesIsolationWithoutClosingExportOrChangingOtherPins() throws {
        let f = try fixture(); defer { f.close() }
        let exportedID = try f.session.add(image: raster()), keep = try addText(to: f)
        let spare = try f.session.add(image: raster())
        let pin = try XCTUnwrap(f.session.liveControllers[exportedID])
        let initialExports = ImageExportController.activeSessionCount
        let item = try XCTUnwrap(pin.actionMenu?.item(withTitle: "当前图像另存为…"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let export = try XCTUnwrap(pin.imageExportController)
        defer { export.cancelExport() }
        let files = try diskSnapshot(f.directory), index = f.store.index
        XCTAssertThrowsError(try f.session.isolatePins([keep]))
        XCTAssertFalse(f.session.hasVisibilityIsolation)
        assertVisible([exportedID, keep, spare], in: f)
        XCTAssertTrue(pin.imageExportController === export); XCTAssertFalse(export.isClosed)
        XCTAssertTrue(export.window?.parent === pin.window)
        XCTAssertEqual(ImageExportController.activeSessionCount, initialExports + 1)
        XCTAssertEqual(f.store.index, index)
        XCTAssertEqual(try diskSnapshot(f.directory), files)
        export.cancelExport()
        XCTAssertEqual(ImageExportController.activeSessionCount, initialExports)
        try f.session.isolatePins([keep])
        assertVisible([keep], in: f)
    }

    func testActiveRenameAndGroupEditorRefuseIsolationWithoutDiscardingFields() throws {
        try PinGroupOrderNativeTests.withApplicationLoop { [self] in
            let f = try fixture(); defer { f.close() }
            let imageID = try f.session.add(image: raster()), textID = try addText(to: f)
            let other = try f.session.add(image: raster())
            let imageOwner = try XCTUnwrap(f.session.liveControllers[imageID])
            imageOwner.renamePin()
            let rename = try XCTUnwrap(imageOwner.renameController)
            rename.nameField.stringValue = "Unsaved rename"
            let files = try diskSnapshot(f.directory)
            XCTAssertThrowsError(try f.session.isolatePins([textID]))
            XCTAssertTrue(imageOwner.renameController === rename)
            XCTAssertEqual(rename.nameField.stringValue, "Unsaved rename")
            XCTAssertFalse(rename.completed)
            assertVisible([imageID, textID, other], in: f)
            rename.close()
            try f.session.groupTransforms.setSelection([imageID, other])
            f.session.groupTransforms.showEditor()
            let editor = try XCTUnwrap(f.session.groupTransforms.editor)
            let field = try XCTUnwrap(find(NSTextField.self, id: "pin-group-dx", in: editor.window?.contentView))
            field.stringValue = "123"
            XCTAssertThrowsError(try f.session.isolatePins([textID]))
            XCTAssertTrue(f.session.groupTransforms.editor === editor)
            XCTAssertTrue(editor.window?.isVisible == true)
            XCTAssertEqual(field.stringValue, "123")
            XCTAssertFalse(f.session.hasVisibilityIsolation)
            assertVisible([imageID, textID, other], in: f)
            XCTAssertEqual(try diskSnapshot(f.directory), files)
        }
    }

    func testRestoreDoesNotDisturbKeptAnnotationAndTextEditors() throws {
        try PinGroupOrderNativeTests.withApplicationLoop { [self] in
            let f = try fixture(); defer { f.close() }
            let imageID = try f.session.add(image: raster()), textID = try addText(to: f)
            let hidden = try f.session.add(image: raster())
            try f.session.isolatePins([imageID, textID])
            let imageOwner = try XCTUnwrap(f.session.liveControllers[imageID])
            imageOwner.showAnnotations()
            let annotation = try XCTUnwrap(imageOwner.annotationEditor)
            annotation.annotationCanvas.add(ImageAnnotation(tool: .rectangle,
                points: [CGPoint(x: 5, y: 5), CGPoint(x: 25, y: 20)]))
            let annotationDraft = try EditableAnnotationDocumentCodec.encode(annotation.editablePayload().document)
            let textOwner = try XCTUnwrap(f.session.richControllers[textID])
            textOwner.editPlainText()
            let text = try XCTUnwrap(textOwner.textEditController)
            replace(text.textView, with: "Kept unsaved draft 👩🏽‍💻")
            let textDraft = text.textView.string, history = text.history.current
            let files = try diskSnapshot(f.directory), index = f.store.index
            try f.session.restoreVisibilityIsolation()
            XCTAssertFalse(f.session.hasVisibilityIsolation)
            XCTAssertTrue(f.session.liveControllers[hidden]?.window?.isVisible == true)
            XCTAssertTrue(imageOwner.annotationEditor === annotation)
            XCTAssertTrue(annotation.window?.isVisible == true)
            XCTAssertFalse(try XCTUnwrap(imageOwner.window).isVisible, "Restore must not reveal the editor's duplicate pin surface")
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(annotation.editablePayload().document), annotationDraft)
            XCTAssertFalse(annotation.isClosed)
            XCTAssertTrue(textOwner.textEditController === text)
            XCTAssertTrue(text.window?.sheetParent === textOwner.window)
            XCTAssertEqual(text.textView.string, textDraft); XCTAssertEqual(text.history.current, history)
            XCTAssertFalse(text.completed)
            XCTAssertEqual(f.store.index, index)
            XCTAssertEqual(try diskSnapshot(f.directory), files)
        }
    }

    func testRetainedOldOwnerCallbacksCannotAffectReplacementOrLaterIsolation() throws {
        let f = try fixture(); defer { f.close() }
        let imageID = try f.session.add(image: raster()), textID = try addText(to: f)
        let oldImage = try XCTUnwrap(f.session.liveControllers[imageID])
        let oldText = try XCTUnwrap(f.session.richControllers[textID])
        let callbacks = [try XCTUnwrap(oldImage.onIsolateThisPin), try XCTUnwrap(oldText.onIsolateThisPin),
                         try XCTUnwrap(oldImage.onIsolateSelectedPins), try XCTUnwrap(oldText.onIsolateSelectedPins),
                         try XCTUnwrap(oldImage.onRestoreVisibilityIsolation), try XCTUnwrap(oldText.onRestoreVisibilityIsolation)]
        let stateQueries = [try XCTUnwrap(oldImage.hasVisibilityIsolation), try XCTUnwrap(oldText.hasVisibilityIsolation),
                            try XCTUnwrap(oldImage.canIsolateSelectedPins), try XCTUnwrap(oldText.canIsolateSelectedPins)]
        oldImage.close(); oldText.close()
        try f.session.openPin(id: imageID); try f.session.openPin(id: textID)
        XCTAssertFalse(f.session.liveControllers[imageID] === oldImage)
        XCTAssertFalse(f.session.richControllers[textID] === oldText)
        try f.session.groupTransforms.setSelection([imageID])
        try f.session.isolatePins([imageID])
        let state = f.session.visibilityIsolation, files = try diskSnapshot(f.directory)
        for callback in callbacks { callback() }
        for query in stateQueries { XCTAssertFalse(query()) }
        XCTAssertEqual(f.session.visibilityIsolation, state)
        assertVisible([imageID], in: f)
        XCTAssertEqual(try diskSnapshot(f.directory), files)
        assertIsolationCallbacksDetached(oldImage)
        assertIsolationCallbacksDetached(oldText)
        XCTAssertTrue(f.errors.messages.isEmpty)
        try f.session.prepareForTermination()
        let terminatedIndex = f.store.index
        for callback in callbacks { callback() }
        XCTAssertEqual(f.store.index, terminatedIndex)
        XCTAssertEqual(f.session.livePinCount, 0)
    }

    func testTwentyRetainedMixedOwnersRemainBoundedThenReleaseWindowsImagesAndCallbacks() async throws {
        let f = try fixture(); defer { f.close() }
        let (ids, probes, rasters) = try autoreleasepool { () throws -> ([UUID], [ClosedAuxiliaryWindowProbe], [IsolationRasterProbe]) in
            var ids: [UUID] = [], probes: [ClosedAuxiliaryWindowProbe] = [], rasters: [IsolationRasterProbe] = []
            for index in 0..<PinSessionCoordinator.maximumLivePins {
                let id: UUID
                if index.isMultiple(of: 2) {
                    id = try f.session.add(image: raster())
                    let pin = try XCTUnwrap(f.session.liveControllers[id])
                    probes.append(try ClosedAuxiliaryWindowProbe(pin)); rasters.append(IsolationRasterProbe(pin.currentImage))
                } else {
                    id = try addText(to: f, text: "Bounded \(index)")
                    probes.append(try ClosedAuxiliaryWindowProbe(try XCTUnwrap(f.session.richControllers[id])))
                }
                ids.append(id)
            }
            return (ids, probes, rasters)
        }
        let files = try diskSnapshot(f.directory), index = f.store.index
        for iteration in 0..<30 {
            try f.session.isolatePins([ids[iteration % ids.count]])
            XCTAssertEqual(f.session.livePinCount, 20)
            XCTAssertEqual(f.session.visibilityIsolation.restoreIDs.count, 20)
            XCTAssertEqual(f.session.visibilityIsolation.hiddenIDs.count, 19)
            try f.session.restoreVisibilityIsolation()
            XCTAssertEqual(f.session.livePinCount, 20)
            XCTAssertTrue(rasters.allSatisfy { $0.image != nil })
        }
        XCTAssertThrowsError(try f.session.add(image: raster()))
        XCTAssertThrowsError(try addText(to: f, text: "over capacity"))
        XCTAssertEqual(f.constructions.count, 10)
        XCTAssertEqual(f.store.index, index)
        XCTAssertEqual(try diskSnapshot(f.directory), files)
        try autoreleasepool {
            try f.session.isolatePins([ids[0]])
            let imageOwners = Array(f.session.liveControllers.values), richOwners = Array(f.session.richControllers.values)
            try f.session.prepareForTermination()
            for pin in imageOwners { assertIsolationCallbacksDetached(pin) }
            for pin in richOwners { assertIsolationCallbacksDetached(pin) }
            XCTAssertFalse(f.session.hasVisibilityIsolation)
            XCTAssertTrue(f.session.visibilityIsolation.restoreIDs.isEmpty)
            XCTAssertTrue(f.session.visibilityIsolation.hiddenIDs.isEmpty)
            XCTAssertEqual(f.session.livePinCount, 0)
            for probe in probes { probe.assertDetached() }
        }
        for probe in probes { try await probe.assertReleased() }
        XCTAssertTrue(rasters.allSatisfy { $0.image == nil }, "Isolation must not own any raster after session cleanup")
        XCTAssertEqual(Set(f.store.entries.filter(\.isVisible).map(\.id)), Set(ids))
        XCTAssertTrue(f.errors.messages.isEmpty)
    }

    private func fixture(presentWindows: Bool = true) throws -> IsolationFixture {
        _ = NSApplication.shared
        _ = try XCTUnwrap(NSScreen.screens.first, "Native isolation tests require an attached display")
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-Isolation-" + UUID().uuidString)
        let store = try PinSessionStore(directory: directory)
        let constructions = IsolationConstructionCount(), errors = IsolationErrors()
        let session = PinSessionCoordinator(store: store, presentWindows: presentWindows,
            desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
            ocrPreferences: PinOCRPreferences(defaults: nil),
            makeImageController: { original, current, modified in
                constructions.count += 1
                return PinController(originalImage: original, currentImage: current, isModified: modified, defaults: nil)
            })
        session.onError = { errors.messages.append($0.localizedDescription) }
        return IsolationFixture(directory: directory, store: store, session: session, constructions: constructions, errors: errors)
    }

    private func addText(to f: IsolationFixture, text: String = "Saved text\n原文 🌱") throws -> UUID {
        try f.session.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: text)), title: "Text"))
    }

    private func addMixedPins(to f: IsolationFixture) throws -> [UUID] {
        let imageID = try f.session.add(image: raster())
        try f.session.liveControllers[imageID]?.applyTransform(.rotateClockwise)
        let textID = try addText(to: f)
        let color = try XCTUnwrap(PinRGBColor.parse("#3366AA80"))
        let colorID = try f.session.add(rich: PreparedRichPin(document: PinRichDocument(color: color), title: "Color"))
        let file = PinFileReference(path: f.directory.appendingPathComponent("missing-reference.txt").path,
                                    name: "Missing reference", isDirectory: false)
        let fileID = try f.session.add(rich: PreparedRichPin(document: PinRichDocument(files: [file]), title: "Files"))
        let ids = [imageID, textID, colorID, fileID]
        let screen = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        for (offset, id) in ids.enumerated() {
            var presentation = try XCTUnwrap(f.session.liveControllers[id]?.presentation ?? f.session.richControllers[id]?.presentation)
            presentation.frame.x = Double(screen.minX) + 30 + Double(offset * 24)
            presentation.frame.y = Double(screen.minY) + 40 + Double(offset * 24)
            presentation.opacity = 0.65 + Double(offset) * 0.1
            presentation.locked = offset == 2; presentation.clickThrough = offset == 3
            if let pin = f.session.liveControllers[id] { pin.applyPresentation(presentation); pin.onPresentationChange?(pin.presentation) }
            if let pin = f.session.richControllers[id] { pin.applyPresentation(presentation); pin.onPresentationChange?(pin.presentation) }
        }
        try f.session.flushPresentationChanges()
        assertVisible(Set(ids), in: f)
        return ids
    }

    private func raster() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 192,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        return try XCTUnwrap(context.makeImage())
    }

    private func snapshots(_ f: IsolationFixture) throws -> [UUID: IsolationOwnerSnapshot] {
        try Dictionary(uniqueKeysWithValues: f.session.livePinIDs.map { id in
            let controller = try XCTUnwrap((f.session.liveControllers[id] as NSWindowController?) ?? f.session.richControllers[id])
            let window = try XCTUnwrap(controller.window)
            return (id, IsolationOwnerSnapshot(controller: controller, window: window,
                content: try XCTUnwrap(window.contentView),
                presentation: try XCTUnwrap(f.session.liveControllers[id]?.presentation ?? f.session.richControllers[id]?.presentation),
                original: f.session.liveControllers[id]?.image, current: f.session.liveControllers[id]?.currentImage,
                document: f.session.richControllers[id]?.richDocument))
        })
    }

    private func assertUnchanged(_ snapshots: [UUID: IsolationOwnerSnapshot], in f: IsolationFixture,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(f.session.livePinIDs, Set(snapshots.keys), file: file, line: line)
        for (id, before) in snapshots {
            let image = f.session.liveControllers[id], rich = f.session.richControllers[id]
            let owner = try XCTUnwrap((image as NSWindowController?) ?? rich, file: file, line: line)
            XCTAssertTrue(owner === before.controller, file: file, line: line)
            XCTAssertTrue(owner.window === before.window, file: file, line: line)
            XCTAssertTrue(owner.window?.contentView === before.content, file: file, line: line)
            XCTAssertEqual(image?.presentation ?? rich?.presentation, before.presentation, file: file, line: line)
            if let image {
                XCTAssertTrue(image.image === before.original, file: file, line: line)
                XCTAssertTrue(image.currentImage === before.current, file: file, line: line)
            } else { XCTAssertEqual(rich?.richDocument, before.document, file: file, line: line) }
        }
    }

    private func assertVisible(_ expected: Set<UUID>, in f: IsolationFixture,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.session.visiblePinIDsForIsolation, expected, file: file, line: line)
        let actual = Set(f.session.liveControllers.filter { $0.value.window?.isVisible == true }.keys)
            .union(f.session.richControllers.filter { $0.value.window?.isVisible == true }.keys)
        XCTAssertEqual(actual, expected, "Actual native windows must match the visible model", file: file, line: line)
        for (id, pin) in f.session.liveControllers { XCTAssertEqual(pin.isVisibilityIsolated, f.session.visibilityIsolation.hiddenIDs.contains(id), file: file, line: line) }
        for (id, pin) in f.session.richControllers { XCTAssertEqual(pin.isVisibilityIsolated, f.session.visibilityIsolation.hiddenIDs.contains(id), file: file, line: line) }
    }

    private func diskSnapshot(_ directory: URL) throws -> [String: IsolationDiskFile] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (url.lastPathComponent, IsolationDiskFile(bytes: try Data(contentsOf: url),
                modified: try XCTUnwrap(attributes[.modificationDate] as? Date),
                inode: try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value))
        })
    }

    private func assertIsolationCallbacksDetached(_ pin: PinController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(pin.onIsolateThisPin, file: file, line: line)
        XCTAssertNil(pin.onIsolateSelectedPins, file: file, line: line)
        XCTAssertNil(pin.onRestoreVisibilityIsolation, file: file, line: line)
        XCTAssertNil(pin.canIsolateSelectedPins, file: file, line: line)
        XCTAssertNil(pin.hasVisibilityIsolation, file: file, line: line)
    }
    private func assertIsolationCallbacksDetached(_ pin: RichPinController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(pin.onIsolateThisPin, file: file, line: line)
        XCTAssertNil(pin.onIsolateSelectedPins, file: file, line: line)
        XCTAssertNil(pin.onRestoreVisibilityIsolation, file: file, line: line)
        XCTAssertNil(pin.canIsolateSelectedPins, file: file, line: line)
        XCTAssertNil(pin.hasVisibilityIsolation, file: file, line: line)
    }
    private func replace(_ view: NSTextView, with value: String) {
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.insertText(value, replacementRange: view.selectedRange())
    }
    private func find<T: NSView>(_ type: T.Type, id: String, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T, view.identifier?.rawValue == id { return match }
        return view.subviews.compactMap { find(type, id: id, in: $0) }.first
    }


}

@MainActor private struct IsolationFixture {
    let directory: URL
    let store: PinSessionStore
    let session: PinSessionCoordinator
    let constructions: IsolationConstructionCount
    let errors: IsolationErrors
    func close() { try? session.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
}
@MainActor private final class IsolationConstructionCount { var count = 0 }
@MainActor private final class IsolationErrors { var messages: [String] = [] }
@MainActor private struct IsolationOwnerSnapshot {
    let controller: NSWindowController
    let window: NSWindow
    let content: NSView
    let presentation: PinPresentation
    let original: CGImage?
    let current: CGImage?
    let document: PinRichDocument?
}
private struct IsolationDiskFile: Equatable {
    let bytes: Data
    let modified: Date
    let inode: UInt64
}
private final class IsolationRasterProbe {
    weak var image: CGImage?
    init(_ image: CGImage) { self.image = image }
}
