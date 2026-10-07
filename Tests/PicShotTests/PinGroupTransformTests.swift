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
        let transform = PinGroupTransform.moveAndScale(dx: -40.375, dy: 35.625, scale: 1.25)
        let plan = try f.session.groupTransforms.plannedTransform(index: before, selectedIDs: Set(f.ids.prefix(3)), transform: transform)
        try f.session.groupTransforms.transform(transform)
        let changed = f.store.index
        XCTAssertEqual(changed, try plan.applying(to: before))
        XCTAssertEqual(f.session.groupTransforms.history.undoPlans, [plan])
        for change in plan.changes { XCTAssertEqual(presentation(f.session, change.id), change.after) }
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
    @MainActor func testPositiveSmokeLayoutFitsVisibleFrameBeforeAndAfterFractionalScale() throws {
        // Includes the 682pt visible height that previously constrained the text pin,
        // a smaller display, and a display with a negative global origin.
        let visibleFrames = [NSRect(x: 0, y: 61, width: 1024, height: 682),
                             NSRect(x: 0, y: 24, width: 640, height: 500),
                             NSRect(x: -1440, y: -876, width: 1440, height: 876)]
        for visible in visibleFrames {
            let frames = try PinGroupTransformSmokeFixture.initialFrames(in: visible)
            XCTAssertEqual(frames.count, 4)
            XCTAssertEqual(frames.map(\.size), [NSSize(width: 300, height: 180), NSSize(width: 240, height: 320),
                                               NSSize(width: 340, height: 160), NSSize(width: 180, height: 120)])
            XCTAssertTrue(frames.allSatisfy { visible.contains($0) })
            let entries = frames.map { frame -> PinSessionEntry in
                var entry = PinSessionEntry(original: PinRasterAsset(filename: UUID().uuidString + ".png", width: 32, height: 16, byteCount: 128))
                entry.presentation.frame = PinWindowFrame(frame); return entry
            }
            let original = PinSessionIndex(entries: entries), selected = Set(entries.prefix(3).map(\.id))
            let proposed = try PinGroupTransformPlan(index: original, selectedIDs: selected,
                                                     transform: .moveAndScale(dx: 25, dy: -15, scale: 1.25))
            XCTAssertTrue(proposed.changes.contains { change in
                let frame = change.after.frame
                return [frame.x, frame.y, frame.width, frame.height].contains { $0 != $0.rounded() }
            }, "The positive fixture must still exercise fractional proposals")
            for scale in [CGFloat(1), CGFloat(2)] {
                func aligned(_ frame: NSRect) -> NSRect {
                    PinGroupBackingGeometry.alignedFrame(frame, toBacking: {
                        NSRect(x: ($0.minX - visible.minX) * scale, y: ($0.minY - visible.minY) * scale,
                               width: $0.width * scale, height: $0.height * scale)
                    }, fromBacking: {
                        NSRect(x: $0.minX / scale + visible.minX, y: $0.minY / scale + visible.minY,
                               width: $0.width / scale, height: $0.height / scale)
                    })
                }
                let canonical = try proposed.canonicalizingTargetFrames { PinWindowFrame(aligned($0.rect)) }
                var index = try canonical.applying(to: original)
                XCTAssertTrue(canonical.changes.allSatisfy { visible.contains($0.after.frame.rect) })
                for alignment in PinGroupAlignment.allCases {
                    let proposal = try PinGroupTransformPlan(index: index, selectedIDs: selected, transform: .align(alignment))
                    let plan = try PinGroupBackingGeometry.alignmentPlan(proposal, alignment: alignment,
                                                                        screenFrames: [visible], align: { _, frame in aligned(frame) })
                    XCTAssertTrue(plan.changes.allSatisfy { visible.contains($0.after.frame.rect) })
                    for change in plan.changes { XCTAssertEqual(change.after.frame.rect.size, change.before.frame.rect.size) }
                    index = try plan.applying(to: index)
                    XCTAssertEqual(index.entry(id: entries[3].id), original.entry(id: entries[3].id))
                }
            }
        }
    }
    @MainActor func testBackingGridQuantizationAtOneAndTwoTimesWithNegativeOrigins() {
        let origin = NSPoint(x: -1440, y: -900)
        let proposed = NSRect(x: -1300.375, y: -740.625, width: 200.375, height: 100.25)
        let expected = [NSRect(x: -1300, y: -741, width: 200, height: 101),
                        NSRect(x: -1300.5, y: -740.5, width: 200.5, height: 100)]
        for (index, scale) in [CGFloat(1), CGFloat(2)].enumerated() {
            let toBacking: (NSRect) -> NSRect = {
                NSRect(x: ($0.minX - origin.x) * scale, y: ($0.minY - origin.y) * scale,
                       width: $0.width * scale, height: $0.height * scale)
            }
            let fromBacking: (NSRect) -> NSRect = {
                NSRect(x: $0.minX / scale + origin.x, y: $0.minY / scale + origin.y,
                       width: $0.width / scale, height: $0.height / scale)
            }
            let actual = PinGroupBackingGeometry.alignedFrame(proposed, toBacking: toBacking, fromBacking: fromBacking)
            XCTAssertEqual(actual, expected[index], "Exact expected geometry on the \(scale)× destination grid")
            XCTAssertEqual(PinGroupBackingGeometry.alignedFrame(actual, toBacking: toBacking, fromBacking: fromBacking), actual)
            let pixels = toBacking(actual)
            for edge in [pixels.minX, pixels.minY, pixels.maxX, pixels.maxY] { XCTAssertEqual(edge, edge.rounded()) }
        }
    }
    @MainActor func testDestinationScreenUsesProposedOverlapAndNearestOffscreenDisplay() throws {
        let screens = [NSRect(x: -1440, y: -300, width: 1440, height: 900), NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        let cases: [(NSRect, Int)] = [
            (NSRect(x: -1400, y: -250, width: 200, height: 100), 0),
            (NSRect(x: 1400, y: 100, width: 200, height: 100), 1),
            (NSRect(x: -60, y: 100, width: 200, height: 100), 1),
            (NSRect(x: -160, y: 100, width: 200, height: 100), 0),
            (NSRect(x: -1800, y: -1000, width: 200, height: 100), 0),
            (NSRect(x: 1400, y: 1400, width: 200, height: 100), 1)
        ]
        for (frame, expected) in cases {
            XCTAssertEqual(PinGroupBackingGeometry.destinationScreenIndex(for: frame, screenFrames: screens), expected)
        }
        // A proposal moving between adjacent 2× and 1× displays must use its
        // destination's grid, regardless of the source window's backing scale.
        let targets = [NSRect(x: -120.375, y: 100.625, width: 80.25, height: 80.375),
                       NSRect(x: 10.375, y: 100.625, width: 80.25, height: 80.375)]
        let expected = [NSRect(x: -120.5, y: 100.5, width: 80.5, height: 80.5),
                        NSRect(x: 10, y: 101, width: 81, height: 80)]
        let scales: [CGFloat] = [2, 1]
        for (index, target) in targets.enumerated() {
            let destination = try XCTUnwrap(PinGroupBackingGeometry.destinationScreenIndex(for: target, screenFrames: screens))
            XCTAssertEqual(destination, index)
            let screen = screens[destination], scale = scales[destination]
            let actual = PinGroupBackingGeometry.alignedFrame(target, toBacking: {
                NSRect(x: ($0.minX - screen.minX) * scale, y: ($0.minY - screen.minY) * scale,
                       width: $0.width * scale, height: $0.height * scale)
            }, fromBacking: {
                NSRect(x: $0.minX / scale + screen.minX, y: $0.minY / scale + screen.minY,
                       width: $0.width / scale, height: $0.height / scale)
            })
            XCTAssertEqual(actual, expected[index])
        }
        XCTAssertNil(PinGroupBackingGeometry.destinationScreenIndex(for: .zero, screenFrames: []))
        XCTAssertThrowsError(try PinGroupBackingGeometry.canonicalFrame(PinWindowFrame(), screens: [])) {
            XCTAssertEqual($0 as? PinGroupTransformError, .windowConstraint)
        }
    }
    @MainActor func testMixedScaleSeamRechecksDestinationWithoutAccumulatingRounding() throws {
        let screens = [NSRect(x: -1440, y: -300, width: 1440, height: 900), NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        let scales: [CGFloat] = [1, 2]
        let proposed = PinWindowFrame(x: -100.1, y: 100.375, width: 200.3, height: 100.25)
        var destinations: [Int] = []
        let result = try PinGroupBackingGeometry.canonicalFrame(proposed, screenFrames: screens) { index, frame in
            destinations.append(index)
            XCTAssertEqual(frame, proposed.rect, "Always align the original proposal")
            let screen = screens[index], scale = scales[index]
            return PinGroupBackingGeometry.alignedFrame(frame, toBacking: {
                NSRect(x: ($0.minX - screen.minX) * scale, y: ($0.minY - screen.minY) * scale,
                       width: $0.width * scale, height: $0.height * scale)
            }, fromBacking: {
                NSRect(x: $0.minX / scale + screen.minX, y: $0.minY / scale + screen.minY,
                       width: $0.width / scale, height: $0.height / scale)
            })
        }
        XCTAssertEqual(destinations, [1, 0], "2× rounding creates a tie that selects the first, 1× display")
        XCTAssertEqual(result, PinWindowFrame(x: -100, y: 100, width: 200, height: 101))
        var calls = 0
        XCTAssertThrowsError(try PinGroupBackingGeometry.canonicalFrame(proposed, screenFrames: screens) { index, _ in
            calls += 1
            return NSRect(x: index == 0 ? 100 : -200, y: 100, width: 100, height: 100)
        }) { XCTAssertEqual($0 as? PinGroupTransformError, .windowConstraint) }
        XCTAssertEqual(calls, 2, "An unstable destination is bounded and rejects before mutation")
    }
    @MainActor func testAlignmentPreservesDimensionsAndUsesOneExactMixedScaleAnchor() throws {
        let screens = [NSRect(x: -1440, y: -300, width: 1440, height: 900), NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        let scales: [CGFloat] = [2, 1]
        func align(_ index: Int, _ frame: NSRect) -> NSRect {
            let screen = screens[index], scale = scales[index]
            return PinGroupBackingGeometry.alignedFrame(frame, toBacking: {
                NSRect(x: ($0.minX - screen.minX) * scale, y: ($0.minY - screen.minY) * scale,
                       width: $0.width * scale, height: $0.height * scale)
            }, fromBacking: {
                NSRect(x: $0.minX / scale + screen.minX, y: $0.minY / scale + screen.minY,
                       width: $0.width / scale, height: $0.height / scale)
            })
        }
        func index(_ frames: [PinWindowFrame]) -> PinSessionIndex {
            PinSessionIndex(entries: frames.map { frame in
                var entry = PinSessionEntry(original: PinRasterAsset(filename: UUID().uuidString + ".png", width: 32, height: 16, byteCount: 128))
                entry.presentation.frame = frame; return entry
            })
        }
        let source = index([PinWindowFrame(x: -300.5, y: 100.5, width: 200, height: 100),
                            PinWindowFrame(x: 100, y: 102, width: 200, height: 101)])
        let ids = Set(source.entries.map(\.id))
        let proposed = try PinGroupTransformPlan(index: source, selectedIDs: ids, transform: .align(.bottom))
        let plan = try PinGroupBackingGeometry.alignmentPlan(proposed, alignment: .bottom, screenFrames: screens, align: align)
        for change in plan.changes {
            XCTAssertEqual(change.after.frame.y, 101, "Both destination grids share the quantized bottom edge")
            XCTAssertEqual(change.after.frame.width, change.before.frame.width)
            XCTAssertEqual(change.after.frame.height, change.before.frame.height)
            XCTAssertEqual(change.before, source.entry(id: change.id)?.presentation)
        }
        let crossing = index([PinWindowFrame(x: -300, y: 100.5, width: 200, height: 100),
                              PinWindowFrame(x: 200, y: 100, width: 200, height: 100)])
        let crossingPlan = try PinGroupTransformPlan(index: crossing, selectedIDs: Set(crossing.entries.map(\.id)), transform: .align(.right))
        let crossed = try PinGroupBackingGeometry.alignmentPlan(crossingPlan, alignment: .right, screenFrames: screens, align: align)
        for change in crossed.changes {
            XCTAssertEqual(change.after.frame.x + change.after.frame.width, 400)
            XCTAssertEqual(change.after.frame.width, change.before.frame.width)
            XCTAssertEqual(change.after.frame.height, change.before.frame.height)
        }
        XCTAssertEqual(crossed.changes.first { $0.id == crossing.entries[0].id }?.after.frame.y, 101,
                       "The perpendicular origin follows the actual 1× destination grid")
        let fractionalSize = index([PinWindowFrame(x: -300, y: 100, width: 200.5, height: 100),
                                    PinWindowFrame(x: 200, y: 100, width: 200, height: 100)])
        let fractionalPlan = try PinGroupTransformPlan(index: fractionalSize, selectedIDs: Set(fractionalSize.entries.map(\.id)), transform: .align(.right))
        XCTAssertThrowsError(try PinGroupBackingGeometry.alignmentPlan(fractionalPlan, alignment: .right, screenFrames: screens, align: align)) {
            XCTAssertEqual($0 as? PinGroupTransformError, .unrepresentableAlignment)
        }
        let incompatible = index([PinWindowFrame(x: 100, y: 100, width: 200, height: 100),
                                  PinWindowFrame(x: 400, y: 100, width: 201, height: 100)])
        let incompatiblePlan = try PinGroupTransformPlan(index: incompatible, selectedIDs: Set(incompatible.entries.map(\.id)), transform: .align(.horizontalCenter))
        let quantized = try PinGroupBackingGeometry.alignmentPlan(incompatiblePlan, alignment: .horizontalCenter, screenFrames: screens, align: align)
        let residuals = PinGroupBackingGeometry.centerAlignmentResiduals(quantized, alignment: .horizontalCenter)
        XCTAssertEqual(residuals.values.sorted(), [0, 0.5], "Odd/even widths keep their size and explicitly report the unavoidable half-pixel residual")
        for change in quantized.changes {
            XCTAssertEqual(change.after.frame.width, change.before.frame.width)
            XCTAssertEqual(change.after.frame.height, change.before.frame.height)
            XCTAssertEqual(try PinGroupBackingGeometry.canonicalFrame(change.after.frame, screenFrames: screens, align: align), change.after.frame)
        }
        XCTAssertEqual(try quantized.applying(to: quantized.applying(to: incompatible), forward: false), incompatible)
        XCTAssertEqual(incompatible.entries.map(\.presentation.frame.width), [200, 201])
        let compatible = index([PinWindowFrame(x: 100, y: 100, width: 200, height: 100),
                                PinWindowFrame(x: 400, y: 100, width: 202, height: 100)])
        let compatiblePlan = try PinGroupTransformPlan(index: compatible, selectedIDs: Set(compatible.entries.map(\.id)), transform: .align(.horizontalCenter))
        let centered = try PinGroupBackingGeometry.alignmentPlan(compatiblePlan, alignment: .horizontalCenter, screenFrames: screens, align: align)
        for change in centered.changes {
            XCTAssertEqual(change.after.frame.x + change.after.frame.width / 2, 351)
            XCTAssertEqual(change.after.frame.width, change.before.frame.width)
        }
    }
    @MainActor func testLiveScreenConversionMatchesAppKitBackingAlignment() throws {
        _ = NSApplication.shared
        XCTAssertFalse(NSScreen.screens.isEmpty, "Native frame tests require a connected display")
        for screen in NSScreen.screens {
            let frame = NSRect(x: screen.frame.minX + 50.375, y: screen.frame.minY + 60.625, width: 240.25, height: 120.375)
            let actual = try PinGroupBackingGeometry.canonicalFrame(PinWindowFrame(frame), screens: [screen])
            XCTAssertEqual(actual.rect, screen.backingAlignedRect(frame, options: .alignAllEdgesNearest))
        }
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
