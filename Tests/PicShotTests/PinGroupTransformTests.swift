import XCTest
import AppKit
import Combine
import PicShotCore
@testable import PicShot

final class PinGroupNativeTransformTests: XCTestCase {
    @MainActor func testMixedThreePinTransformUndoRedoPreservesSentinelAndRasterIdentity() throws {
        let f = try fixture(); defer { f.close() }
        let before = f.store.index, assets = try fileBytes(f.directory)
        let raster = try XCTUnwrap(f.session.liveControllers[f.ids[0]]?.currentImage)
        let rotated = try XCTUnwrap(f.session.liveControllers[f.ids[1]]?.currentImage)
        let text = f.session.richControllers[f.ids[2]]?.richDocument
        var commits = 0
        let subscription = f.store.$index.dropFirst().sink { _ in commits += 1 }; defer { subscription.cancel() }
        try f.session.groupTransforms.setSelection(Set(f.ids.prefix(3)))
        try f.session.groupTransforms.transform(.moveAndScale(dx: -40, dy: 35, scale: 1.25))
        let changed = f.store.index
        XCTAssertEqual(commits, 1, "One group operation must publish one atomic manifest")
        XCTAssertEqual(changed.entries.first { $0.id == f.ids[3] }, before.entries.first { $0.id == f.ids[3] })
        XCTAssertTrue(f.session.liveControllers[f.ids[0]]?.currentImage === raster)
        XCTAssertTrue(f.session.liveControllers[f.ids[1]]?.currentImage === rotated)
        XCTAssertEqual(f.session.richControllers[f.ids[2]]?.richDocument, text)
        XCTAssertEqual(try fileBytes(f.directory), assets, "Presentation does not rewrite pixels or rich payloads")
        XCTAssertEqual(f.session.groupTransforms.history.undoPlans.count, 1)
        try f.session.groupTransforms.undo(); XCTAssertEqual(f.store.index, before)
        for id in f.ids { XCTAssertEqual(presentation(f.session, id), before.entry(id: id)?.presentation) }
        try f.session.groupTransforms.redo(); XCTAssertEqual(f.store.index, changed)
        XCTAssertEqual(commits, 3)
    }
    @MainActor func testDiskFailureRollsBackEveryLiveFrameAndKeepsHistoryAndMemoryIndex() throws {
        let f = try fixture(); defer { f.close() }
        try f.session.groupTransforms.setSelection(Set(f.ids.prefix(3)))
        let before = f.store.index, assets = try fileBytes(f.directory)
        let manifest = f.directory.appendingPathComponent("index.json"), bytes = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.session.groupTransforms.transform(.align(.top)))
        XCTAssertEqual(f.store.index, before); XCTAssertFalse(f.session.groupTransforms.canUndo)
        XCTAssertEqual(f.session.groupTransforms.lastFailure?.stage, "commit-store")
        for id in f.ids { XCTAssertEqual(presentation(f.session, id), before.entry(id: id)?.presentation) }
        XCTAssertEqual(try fileBytes(f.directory), assets)
        try FileManager.default.removeItem(at: manifest); try bytes.write(to: manifest, options: .atomic)
        try f.session.groupTransforms.transform(.align(.top))
        let changed = f.store.index
        try FileManager.default.removeItem(at: manifest); try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.session.groupTransforms.undo())
        XCTAssertEqual(f.store.index, changed); XCTAssertTrue(f.session.groupTransforms.canUndo); XCTAssertFalse(f.session.groupTransforms.canRedo)
        for id in f.ids { XCTAssertEqual(presentation(f.session, id), changed.entry(id: id)?.presentation) }
        try FileManager.default.removeItem(at: manifest)
        try JSONEncoder().encode(changed).write(to: manifest, options: .atomic)
    }
    @MainActor func testInspectorCancelInvalidInputAndStaleSnapshotLeaveAllOriginalFrames() throws {
        let f = try fixture(); defer { f.close() }
        let group = f.session.groupTransforms
        try group.setSelection(Set(f.ids.prefix(3)))
        let before = f.store.index
        group.showEditor()
        let cancelled = try XCTUnwrap(group.editor)
        try field("pin-group-dx", in: cancelled).stringValue = "200"
        try button("pin-group-cancel", in: cancelled).performClick(nil)
        XCTAssertNil(group.editor); XCTAssertEqual(f.store.index, before)
        group.showEditor(); let invalid = try XCTUnwrap(group.editor)
        try field("pin-group-scale", in: invalid).stringValue = "nan"
        try button("pin-group-apply", in: invalid).performClick(nil)
        XCTAssertTrue(group.editor === invalid); XCTAssertEqual(f.store.index, before)
        XCTAssertEqual(invalid.applyOutcome, "failed"); XCTAssertEqual(invalid.lastApplyFailure?.code, "invalidGeometry")
        try field("pin-group-scale", in: invalid).stringValue = "125"
        // A different live window move while the inspector was open invalidates its snapshot.
        let image = try XCTUnwrap(f.session.liveControllers[f.ids[0]])
        var moved = image.presentation; moved.frame.x += 10; image.applyPresentation(moved); image.onPresentationChange?(moved)
        try f.session.flushPresentationChanges(); let intervening = f.store.index
        try button("pin-group-apply", in: invalid).performClick(nil)
        XCTAssertEqual(f.store.index, intervening); XCTAssertFalse(group.canUndo)
        XCTAssertEqual(invalid.applyOutcome, "failed"); XCTAssertEqual(invalid.lastApplyFailure?.code, "stalePresentation")
        XCTAssertEqual(group.lastFailure?.stage, "validate-store")
        XCTAssertEqual(group.lastFailure?.expected, before.entry(id: f.ids[0])?.presentation)
        XCTAssertEqual(group.lastFailure?.actual, intervening.entry(id: f.ids[0])?.presentation)
        try field("pin-group-dx", in: invalid).stringValue = "not-a-number"
        try button("pin-group-apply", in: invalid).performClick(nil)
        XCTAssertEqual(invalid.lastApplyFailure?.code, "invalidGeometry")
        XCTAssertNil(group.lastFailure, "A parsing failure must not reuse an earlier transaction's geometry")
        for id in f.ids { XCTAssertEqual(presentation(f.session, id), intervening.entry(id: id)?.presentation) }
        invalid.close()
    }
    @MainActor func testLockedClickThroughArchivedAndStaleIDsCannotBeSilentlySkipped() throws {
        let f = try fixture(); defer { f.close() }
        let group = f.session.groupTransforms, ids = Set(f.ids.prefix(3))
        XCTAssertThrowsError(try group.setSelection(ids.union([UUID()])))
        let controller = try XCTUnwrap(f.session.liveControllers[f.ids[1]])
        for flag in ["locked", "clickThrough"] {
            var value = controller.presentation
            if flag == "locked" { value.locked = true } else { value.clickThrough = true }
            controller.applyPresentation(value); controller.onPresentationChange?(value)
            XCTAssertThrowsError(try group.setSelection(ids))
            value.locked = false; value.clickThrough = false; controller.applyPresentation(value); controller.onPresentationChange?(value)
        }
        try group.setSelection(ids); try group.transform(.align(.left))
        controller.close()
        XCTAssertFalse(group.selectedIDs.contains(f.ids[1])); XCTAssertFalse(group.canUndo)
        XCTAssertThrowsError(try group.setSelection(ids))
        let count = f.session.livePinCount
        XCTAssertEqual(f.session.livePinCount, count, "Rejecting archives must not reopen them")
        try f.store.remove(id: f.ids[0]); try f.session.reconcileVisiblePins()
        XCTAssertFalse(group.selectedIDs.contains(f.ids[0]))
    }
    @MainActor func testGroupSwitchHideRestartClearSelectionAndUndoButPersistFrames() throws {
        let f = try fixture(); defer { f.close() }
        try f.session.groupTransforms.setSelection(Set(f.ids.prefix(3)))
        try f.session.groupTransforms.transform(.align(.bottom))
        let changed = f.store.index
        let other = try f.store.createGroup(name: "Other")
        try f.session.switchGroup(id: other.id)
        XCTAssertTrue(f.session.groupTransforms.selectedIDs.isEmpty); XCTAssertFalse(f.session.groupTransforms.canUndo)
        XCTAssertEqual(f.session.livePinCount, 0)
        try f.session.switchGroup(id: PinGroup.defaultID)
        for id in f.ids { XCTAssertEqual(f.store.entry(id: id)?.presentation, changed.entry(id: id)?.presentation) }
        try f.session.groupTransforms.setSelection(Set(f.ids.prefix(3)))
        try f.session.hideAll()
        XCTAssertEqual(f.session.livePinCount, 0); XCTAssertTrue(f.session.groupTransforms.selectedIDs.isEmpty)
        try f.session.showCurrentGroup(); try f.session.prepareForTermination()
        let restoredStore = try PinSessionStore(directory: f.directory)
        let restored = PinSessionCoordinator(store: restoredStore, presentWindows: false, screens: { [CGRect(x: -2000, y: -1000, width: 6000, height: 4000)] })
        defer { try? restored.prepareForTermination() }
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        XCTAssertEqual(restored.livePinCount, 4); XCTAssertTrue(restored.groupTransforms.selectedIDs.isEmpty); XCTAssertFalse(restored.groupTransforms.canUndo)
        for id in f.ids { XCTAssertEqual(presentation(restored, id), changed.entry(id: id)?.presentation) }
    }
    @MainActor func testNativeMinimumSizeRejectsWholeGroupBeforeWriting() throws {
        let f = try fixture(); defer { f.close() }
        let before = f.store.index
        try f.session.groupTransforms.setSelection(Set(f.ids.prefix(3)))
        // Text width 320 × .25 is smaller than its native 180pt content minimum.
        XCTAssertThrowsError(try f.session.groupTransforms.transform(.moveAndScale(dx: 0, dy: 0, scale: 0.25)))
        XCTAssertEqual(f.store.index, before)
        for id in f.ids { XCTAssertEqual(presentation(f.session, id), before.entry(id: id)?.presentation) }
    }
    @MainActor func testGroupManagerMultiselectAndContextActionUseSameStableIDs() throws {
        let f = try fixture(); defer { f.close() }
        let manager = PinGroupsController(store: f.store, transforms: f.session.groupTransforms)
        defer { manager.close() }
        let table = try XCTUnwrap(find(NSTableView.self, in: manager.window?.contentView))
        XCTAssertTrue(table.allowsMultipleSelection)
        let entries = f.store.entries.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        let ids = Set(f.ids.prefix(3))
        table.selectRowIndexes(IndexSet(entries.indices.filter { ids.contains(entries[$0].id) }), byExtendingSelection: false)
        XCTAssertEqual(f.session.groupTransforms.selectedIDs, ids)
        let image = try XCTUnwrap(f.session.liveControllers[f.ids[0]])
        let item = try XCTUnwrap(image.actionMenu?.items.first { $0.identifier?.rawValue == "pin-group-select" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(f.session.groupTransforms.selectedIDs, ids.subtracting([f.ids[0]]))
    }
    @MainActor private func fixture() throws -> GroupFixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GroupTests-" + UUID().uuidString)
        let store = try PinSessionStore(directory: directory)
        let session = PinSessionCoordinator(store: store, presentWindows: false, screens: { [CGRect(x: -2000, y: -1000, width: 6000, height: 4000)] })
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let first = try session.add(image: bitmap), second = try session.add(image: bitmap)
        try session.liveControllers[second]?.applyTransform(.rotateClockwise)
        let third = try session.add(rich: PreparedRichPin(document: PinRichDocument(text: PinTextContent(runs: [PinTextRun(text: "Mixed pin")])), title: "Text"))
        let sentinel = try session.add(image: bitmap)
        let ids = [first, second, third, sentinel]
        let frames = [PinWindowFrame(x: -300, y: -200, width: 300, height: 180), PinWindowFrame(x: 40, y: 60, width: 240, height: 360), PinWindowFrame(x: 360, y: -60, width: 320, height: 160), PinWindowFrame(x: 800, y: 200, width: 160, height: 100)]
        for (i, id) in ids.enumerated() {
            let value = PinPresentation(frame: frames[i], opacity: 0.8, zoom: i == 1 ? 2 : i == 2 ? 1 : nil)
            if let pin = session.liveControllers[id] { pin.applyPresentation(value); pin.onPresentationChange?(pin.presentation) }
            if let pin = session.richControllers[id] { pin.applyPresentation(value); pin.onPresentationChange?(pin.presentation) }
        }
        try session.flushPresentationChanges()
        return GroupFixture(directory: directory, store: store, session: session, ids: ids)
    }
    @MainActor private func presentation(_ session: PinSessionCoordinator, _ id: UUID) -> PinPresentation? { session.liveControllers[id]?.presentation ?? session.richControllers[id]?.presentation }
    private func fileBytes(_ directory: URL) throws -> [String: Data] {
        var bytes: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent != "index.json" { bytes[url.lastPathComponent] = try Data(contentsOf: url) }
        return bytes
    }
    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }; if let match = view as? T { return match }
        return view.subviews.compactMap { find(type, in: $0) }.first
    }
    @MainActor private func control<T: NSView>(_ type: T.Type, id: String, in view: NSView?) -> T? {
        guard let view else { return nil }; if let match = view as? T, view.identifier?.rawValue == id { return match }
        return view.subviews.compactMap { control(type, id: id, in: $0) }.first
    }
    @MainActor private func field(_ id: String, in editor: PinGroupTransformEditor) throws -> NSTextField { try XCTUnwrap(control(NSTextField.self, id: id, in: editor.window?.contentView)) }
    @MainActor private func button(_ id: String, in editor: PinGroupTransformEditor) throws -> NSButton { try XCTUnwrap(control(NSButton.self, id: id, in: editor.window?.contentView)) }
}
@MainActor private struct GroupFixture {
    let directory: URL
    let store: PinSessionStore
    let session: PinSessionCoordinator
    let ids: [UUID]
    func close() { try? session.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
}
