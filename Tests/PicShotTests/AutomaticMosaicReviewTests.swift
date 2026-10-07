import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class AutomaticMosaicReviewTests: XCTestCase {
    private let boxes = [CGRect(x: 31, y: 37, width: 44, height: 23), CGRect(x: 137, y: 89, width: 44, height: 23), CGRect(x: 251, y: 173, width: 44, height: 23)]

    func testOddAsymmetricImageAndTopLeftCoordinatesRoundTrip() throws {
        for rect in boxes {
            let pixel = try XCTUnwrap(AutomaticMosaicCoordinates.pixelRect(rect, imageHeight: 241))
            XCTAssertEqual(pixel.x, Int(rect.minX)); XCTAssertEqual(pixel.y, 241 - Int(rect.maxY))
            XCTAssertEqual(AutomaticMosaicCoordinates.imageRect(pixel, imageHeight: 241), rect)
        }
        let rect = CGRect(x: 5, y: 27, width: 7, height: 9)
        XCTAssertEqual(AutomaticMosaicCoordinates.pixelRect(rect, imageHeight: 39), RepeatedRegionPixelRect(x: 5, y: 3, width: 7, height: 9))
    }

    func testInvalidAndNonFiniteCoordinatesNeverConvertToInt() {
        let invalid = [CGRect(x: CGFloat.infinity, y: 1, width: 5, height: 5), CGRect(x: CGFloat.nan, y: 1, width: 5, height: 5),
                       CGRect(x: -1, y: 1, width: 5, height: 5), CGRect(x: 1, y: 239, width: 5, height: 5),
                       CGRect(x: 1, y: 1, width: 2, height: 5), CGRect(x: 1e30, y: 1, width: 5, height: 5)]
        for rect in invalid { XCTAssertNil(AutomaticMosaicCoordinates.pixelRect(rect, imageHeight: 241)) }
        XCTAssertNil(AutomaticMosaicCoordinates.imageRect(.init(x: Int.max, y: 0, width: 9, height: 9), imageHeight: 241))
        XCTAssertNil(AutomaticMosaicCoordinates.imageRect(.init(x: 0, y: Int.max, width: 9, height: 9), imageHeight: 241))
    }

    func testEligibleSeedsRequireAxisAlignedObscuringRectangles() {
        for tool in [ImageEditorTool.pixelate, .blur, .redact] {
            var seed = annotation(tool: tool, rect: boxes[0]); XCTAssertTrue(seed.supportsAutomaticMosaic)
            seed.rotation = .pi / 2; XCTAssertFalse(seed.supportsAutomaticMosaic)
            seed.rotation = .nan; XCTAssertFalse(seed.supportsAutomaticMosaic)
        }
        XCTAssertFalse(annotation(tool: .rectangle, rect: boxes[0]).supportsAutomaticMosaic)
        XCTAssertFalse(annotation(tool: .pixelate, rect: CGRect(x: 1, y: 1, width: 2, height: 2)).supportsAutomaticMosaic)
    }

    @MainActor
    func testApplyIsOneUndoUnitAndExclusionsRemainValueMetadata() throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas
        var review = state(image: canvas.image, tool: .redact)
        review.candidates[2].included = false
        let result = review.committedAnnotations()
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertTrue(canvas.applyAutomaticMosaic(result, replacing: nil))
        XCTAssertEqual(canvas.annotations.count, 2)
        XCTAssertEqual(canvas.annotations[0].mosaicLink?.excludedTargets, [boxes[2]])
        try command(canvas, "z", code: 6)
        XCTAssertTrue(canvas.annotations.isEmpty)
        try command(canvas, "z", code: 6, shift: true)
        XCTAssertEqual(canvas.annotations.count, 2)
        XCTAssertEqual(canvas.annotations[1].mosaicLink?.excludedTargets, [boxes[2]])
    }

    @MainActor
    func testSyncAddsDeletesAndStyleUseOneUndoUnitEach() throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas
        canvas.applyAutomaticMosaic(state(image: canvas.image).committedAnnotations(), replacing: nil)
        let selected = try XCTUnwrap(canvas.selectedAnnotation)
        let correction = CGRect(x: boxes[0].minX + 4, y: boxes[0].minY + 3, width: 9, height: 7)
        XCTAssertTrue(canvas.addMosaicCorrection(correction, relativeTo: selected))
        XCTAssertEqual(canvas.annotations.count, 6)
        let addition = try XCTUnwrap(canvas.selectedAnnotation?.mosaicLink?.additionID)
        canvas.updateSelectedStyle(width: 16)
        XCTAssertEqual(canvas.annotations.filter { $0.mosaicLink?.additionID == addition }.map(\.lineWidth), [16, 16, 16])
        try command(canvas, "z", code: 6)
        XCTAssertEqual(canvas.annotations.filter { $0.mosaicLink?.additionID == addition }.map(\.lineWidth), [4, 4, 4])
        try click(canvas, CGPoint(x: correction.midX, y: correction.midY))
        canvas.deleteSelection(); XCTAssertEqual(canvas.annotations.count, 3)
        try command(canvas, "z", code: 6); XCTAssertEqual(canvas.annotations.count, 6)
        try command(canvas, "z", code: 6); XCTAssertEqual(canvas.annotations.count, 3)
    }

    @MainActor
    func testSyncOffCorrectionDeletionDoesNotExcludeOriginalTarget() throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas
        canvas.applyAutomaticMosaic(state(image: canvas.image).committedAnnotations(), replacing: nil)
        let root = try XCTUnwrap(canvas.selectedAnnotation)
        canvas.addMosaicCorrection(CGRect(x: boxes[0].minX + 4, y: boxes[0].minY + 3, width: 9, height: 7), relativeTo: root)
        canvas.setMosaicSync(false)
        canvas.deleteSelection()
        XCTAssertEqual(canvas.annotations.count, 5)
        XCTAssertTrue(canvas.annotations.allSatisfy { $0.mosaicLink?.includedTargets == boxes })
        try click(canvas, CGPoint(x: boxes[0].minX + 25, y: boxes[0].minY + 15))
        canvas.setMosaicSync(true)
        canvas.addMosaicCorrection(CGRect(x: boxes[0].minX + 20, y: boxes[0].minY + 12, width: 6, height: 6), relativeTo: try XCTUnwrap(canvas.selectedAnnotation))
        XCTAssertEqual(canvas.annotations.count, 8, "A later synced addition includes all three approved original targets")
    }

    @MainActor
    func testSyncOffOriginalDeletionPreservesExclusionWhenSyncReturns() throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas
        canvas.applyAutomaticMosaic(state(image: canvas.image).committedAnnotations(), replacing: nil)
        canvas.setMosaicSync(false); canvas.deleteSelection()
        XCTAssertEqual(canvas.annotations.count, 2)
        XCTAssertTrue(canvas.annotations.allSatisfy { $0.mosaicLink?.excludedTargets == [boxes[0]] })
        try click(canvas, CGPoint(x: boxes[1].midX, y: boxes[1].midY))
        canvas.setMosaicSync(true)
        canvas.addMosaicCorrection(boxes[1].insetBy(dx: 9, dy: 7), relativeTo: try XCTUnwrap(canvas.selectedAnnotation))
        XCTAssertEqual(canvas.annotations.count, 4)
        XCTAssertFalse(canvas.annotations.contains { $0.mosaicLink?.target == boxes[0] })
    }

    @MainActor
    func testSyncOffTransformDetachesOnlyTransformedMarkAndUndoRestoresLink() throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas
        canvas.applyAutomaticMosaic(state(image: canvas.image).committedAnnotations(), replacing: nil)
        canvas.setMosaicSync(false)
        let first = try XCTUnwrap(canvas.selectedAnnotation?.id)
        canvas.updateSelected { $0 = $0.translated(by: CGSize(width: 11, height: 5)) }
        XCTAssertNil(canvas.annotations.first { $0.id == first }?.mosaicLink)
        XCTAssertEqual(canvas.annotations.filter { $0.mosaicLink != nil }.count, 2)
        XCTAssertTrue(canvas.annotations.filter { $0.mosaicLink != nil }.allSatisfy { $0.mosaicLink?.excludedTargets == [boxes[0]] })
        try command(canvas, "z", code: 6)
        XCTAssertNotNil(canvas.annotations.first { $0.id == first }?.mosaicLink)
        XCTAssertTrue(canvas.annotations.allSatisfy { $0.mosaicLink?.includedTargets == boxes })
    }

    @MainActor
    func testLinkedAnnotationCapRejectsAtomicallyWithoutUndoSnapshot() throws {
        let image = try raster()
        let canvas = ImageEditorCanvas(image: image)
        var snapshots = 0, rejected = ""
        canvas.onWillChange = { snapshots += 1 }; canvas.onAutomaticMosaicLimit = { rejected = $0 }
        let base = state(image: image).committedAnnotations()[0]
        let marks = (0..<AutomaticMosaicModelLimits.maximumLinkedAnnotations).map { _ -> ImageAnnotation in var mark = base; mark.id = UUID(); return mark }
        XCTAssertTrue(canvas.applyAutomaticMosaic(marks, replacing: nil)); XCTAssertEqual(snapshots, 1)
        XCTAssertFalse(canvas.applyAutomaticMosaic([base], replacing: nil))
        XCTAssertEqual(snapshots, 1); XCTAssertEqual(canvas.annotations.count, AutomaticMosaicModelLimits.maximumLinkedAnnotations)
        XCTAssertFalse(rejected.isEmpty)
    }

    @MainActor
    func testDeleteDuringLinkedCorrectionCancelsCapturedGroupBeforeAnotherDrag() throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas
        XCTAssertTrue(canvas.applyAutomaticMosaic(state(image: canvas.image).committedAnnotations(), replacing: nil))
        XCTAssertEqual(canvas.annotations.count, 3)
        editor.beginLinkedMosaicCorrection()
        XCTAssertNotNil(canvas.automaticMosaicDrawHandler)
        XCTAssertNil(editor.automaticMosaicReviewState)
        canvas.keyDown(with: try key(canvas, "\u{7f}", code: 51))
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertNil(canvas.automaticMosaicDrawHandler)
        XCTAssertNil(editor.automaticMosaicReviewState)
        XCTAssertTrue(editor.automaticMosaicReviewSurface.isHidden)
        XCTAssertFalse(editor.automaticMosaicBlocksOutput)
        try drag(canvas, CGRect(x: 21, y: 29, width: 6, height: 6))
        XCTAssertLessThanOrEqual(canvas.annotations.count, 1)
        XCTAssertTrue(canvas.annotations.allSatisfy { $0.mosaicLink == nil })
    }

    @MainActor
    func testNativeReviewControlsAreTransactionalAndApplyUndoRestoresSelectedSeed() async throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas
        canvas.add(annotation(tool: .redact, rect: boxes[0])); editor.chooseTool(.select)
        let seedID = try XCTUnwrap(canvas.selectedAnnotation?.id)
        installMatches(editor)
        let find: NSButton = try control("annotation.automaticMosaic", editor)
        XCTAssertTrue(find.isEnabled); find.performClick(nil)
        try await waitUntil { editor.automaticMosaicReviewState?.phase == .ready }
        XCTAssertEqual(canvas.annotations.count, 1)
        editor.automaticMosaicReviewSurface.nextButton.performClick(nil)
        editor.automaticMosaicReviewSurface.nextButton.performClick(nil)
        editor.automaticMosaicReviewSurface.includeButton.performClick(nil)
        XCTAssertEqual(editor.automaticMosaicReviewState?.includedCount, 2)
        XCTAssertEqual(canvas.annotations.count, 1)
        editor.automaticMosaicReviewSurface.applyButton.performClick(nil)
        XCTAssertNil(editor.automaticMosaicReviewState)
        XCTAssertEqual(canvas.annotations.count, 2)
        XCTAssertEqual(canvas.annotations[0].mosaicLink?.excludedTargets, [boxes[2]])
        try command(canvas, "z", code: 6)
        XCTAssertEqual(canvas.annotations.map(\.id), [seedID])
    }

    @MainActor
    func testNativeManualReviewAdditionRetainsExclusionsAndCommitsOnlyOnApply() async throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas; installMatches(editor)
        editor.chooseAutomaticMosaicTool(); try drag(canvas, boxes[0])
        try await waitUntil { editor.automaticMosaicReviewState?.phase == .ready }
        editor.automaticMosaicReviewSurface.nextButton.performClick(nil)
        editor.automaticMosaicReviewSurface.nextButton.performClick(nil)
        editor.automaticMosaicReviewSurface.includeButton.performClick(nil)
        editor.automaticMosaicReviewSurface.addButton.performClick(nil)
        XCTAssertFalse(editor.automaticMosaicReviewSurface.applyButton.isEnabled)
        let manual = CGRect(x: 91, y: 177, width: 44, height: 23)
        try drag(canvas, manual)
        let review = try XCTUnwrap(editor.automaticMosaicReviewState)
        XCTAssertEqual(review.candidates.count, 4); XCTAssertEqual(review.includedCount, 3)
        XCTAssertTrue(review.candidates[3].isManual); XCTAssertEqual(review.candidates[3].rect, manual)
        XCTAssertTrue(canvas.annotations.isEmpty)
        editor.automaticMosaicReviewSurface.applyButton.performClick(nil)
        XCTAssertEqual(canvas.annotations.count, 3)
        XCTAssertTrue(canvas.annotations.allSatisfy { $0.mosaicLink?.excludedTargets == [boxes[2]] })
        XCTAssertTrue(canvas.annotations.contains { $0.localBounds == manual })
        try command(canvas, "z", code: 6); XCTAssertTrue(canvas.annotations.isEmpty)
    }

    @MainActor
    func testNativeCancelAndDirectSeedEscapeLeaveAnnotationsAndUndoUnchanged() async throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas; installMatches(editor)
        editor.chooseAutomaticMosaicTool()
        try drag(canvas, boxes[0])
        try await waitUntil { editor.automaticMosaicReviewState?.phase == .ready }
        editor.automaticMosaicReviewSurface.cancelButton.performClick(nil)
        XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertNil(editor.automaticMosaicReviewState)
        editor.chooseAutomaticMosaicTool()
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, boxes[0].origin))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: boxes[0].maxX, y: boxes[0].maxY)))
        canvas.keyDown(with: try key(canvas, "", code: 53))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: boxes[0].maxX, y: boxes[0].maxY)))
        XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertNil(canvas.automaticMosaicDrawHandler)
        let undo: NSButton = try control("editor.undo", editor); XCTAssertFalse(undo.isEnabled)
    }

    @MainActor
    func testLateCompletionAfterEditUndoCropAndCloseCannotPublishReview() async throws {
        for invalidation in 0..<4 {
            let editor = try editor(); let canvas = editor.annotationCanvas
            let gate = CompletionGate()
            editor.automaticMosaicFind = { _, _ in await gate.wait() }
            editor.chooseAutomaticMosaicTool(); try drag(canvas, boxes[0])
            try await waitUntil { gate.waiting }
            switch invalidation {
            case 0: canvas.add(annotation(tool: .rectangle, rect: boxes[2]))
            case 1: try command(canvas, "z", code: 6)
            case 2: canvas.setContent(image: try raster(width: 200, height: 150), annotations: [])
            default: editor.close()
            }
            gate.finish(matches())
            for _ in 0..<8 { await Task.yield() }
            XCTAssertNil(editor.automaticMosaicReviewState); XCTAssertFalse(editor.automaticMosaicIsComputing)
            XCTAssertFalse(canvas.annotations.contains { $0.mosaicLink != nil })
            editor.close()
        }
    }

    @MainActor
    func testContextFindEnablementRejectsEmptyOrdinaryAndRotatedSelections() throws {
        let editor = try editor(); defer { editor.close() }
        let canvas = editor.annotationCanvas
        let item = try XCTUnwrap(canvas.menu?.items.first { $0.identifier?.rawValue == "editor.context.automaticMosaic" })
        XCTAssertFalse(editor.validateMenuItem(item))
        canvas.add(annotation(tool: .rectangle, rect: boxes[0])); XCTAssertFalse(editor.validateMenuItem(item))
        canvas.add(annotation(tool: .pixelate, rect: boxes[1])); XCTAssertTrue(editor.validateMenuItem(item))
        canvas.updateSelected { $0.rotation = .pi / 4 }; XCTAssertFalse(editor.validateMenuItem(item))
        canvas.applyAutomaticMosaic(state(image: canvas.image).committedAnnotations(), replacing: nil)
        XCTAssertFalse(editor.validateMenuItem(item), "Already linked results use sync/correction editing, avoiding split groups")
        editor.chooseTool(.select)
        let find: NSButton = try control("annotation.automaticMosaic", editor)
        XCTAssertFalse(find.isEnabled); XCTAssertTrue(find.toolTip?.contains("重新查找请新建选区") == true)
    }

    @MainActor
    func testPendingReviewBlocksNativeOutputButtonsAndKeyboardUntilCancelOrApply() async throws {
        _ = NSApplication.shared
        var copies = 0, pins = 0, ocrs = 0
        let editor = ImageEditorController(image: try raster(), onSave: { _ in }, onPin: { _ in pins += 1 }, onOCR: { _ in ocrs += 1 }, copyAction: { _ in copies += 1 })
        defer { editor.close() }; editor.showWindow(nil); installMatches(editor)
        let canvas = editor.annotationCanvas
        for apply in [false, true] {
            editor.chooseAutomaticMosaicTool()
            let copy: NSButton = try control("editor.copy", editor)
            let save: NSButton = try control("editor.save", editor)
            let pin: NSButton = try control("editor.pin", editor)
            let ocr: NSButton = try control("editor.ocr", editor)
            XCTAssertFalse(copy.isEnabled); XCTAssertFalse(save.isEnabled)
            try command(canvas, "c", code: 8); try command(canvas, "s", code: 1)
            XCTAssertNil(editor.window?.attachedSheet)
            try drag(canvas, boxes[0]); try await waitUntil { editor.automaticMosaicReviewState?.phase == .ready }
            for button in [copy, save, pin, ocr] {
                XCTAssertFalse(button.isEnabled)
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
            }
            try command(canvas, "c", code: 8); try command(canvas, "s", code: 1)
            XCTAssertEqual(copies, apply ? 1 : 0); XCTAssertEqual(pins, 0); XCTAssertEqual(ocrs, 0)
            XCTAssertNil(editor.window?.attachedSheet); XCTAssertNotNil(editor.automaticMosaicReviewState)
            if apply { editor.automaticMosaicReviewSurface.applyButton.performClick(nil) }
            else { editor.automaticMosaicReviewSurface.cancelButton.performClick(nil) }
            XCTAssertTrue(copy.isEnabled); XCTAssertTrue(save.isEnabled); XCTAssertTrue(pin.isEnabled); XCTAssertTrue(ocr.isEnabled)
            copy.performClick(nil)
        }
        XCTAssertEqual(copies, 2); XCTAssertEqual(canvas.annotations.count, 3)
    }

    @MainActor
    func testCompactLayoutPrefersOutsideImageAndKeepsFocusedCandidateVisibleAtEdges() {
        let available = CGRect(x: 0, y: 0, width: 900, height: 700)
        let image = CGRect(x: 180, y: 230, width: 520, height: 320)
        let toolbar = CGRect(x: 180, y: 175, width: 520, height: 40)
        let outside = AutomaticMosaicReviewSurface.frame(image: image, available: available, avoiding: [toolbar], focusedCandidate: boxes[0])
        XCTAssertTrue(available.contains(outside)); XCTAssertFalse(outside.intersects(image)); XCTAssertFalse(outside.intersects(toolbar))
        let full = CGRect(x: 0, y: 0, width: 760, height: 380)
        for candidate in [CGRect(x: 0, y: 0, width: 180, height: 80), CGRect(x: 570, y: 0, width: 180, height: 80),
                          CGRect(x: 0, y: 290, width: 180, height: 80), CGRect(x: 570, y: 290, width: 180, height: 80)] {
            let frame = AutomaticMosaicReviewSurface.frame(image: full, available: full, focusedCandidate: candidate)
            XCTAssertTrue(full.contains(frame)); XCTAssertFalse(frame.intersects(candidate))
            XCTAssertLessThanOrEqual(frame.width, 326); XCTAssertLessThanOrEqual(frame.height, 110)
        }
    }

    private func annotation(tool: ImageEditorTool = .pixelate, rect: CGRect) -> ImageAnnotation {
        ImageAnnotation(tool: tool, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)])
    }
    private func state(image: CGImage, tool: ImageEditorTool = .pixelate) -> AutomaticMosaicReviewState {
        AutomaticMosaicReviewState(phase: .ready, generation: UUID(), sourceIdentity: ObjectIdentifier(image), sourceRevision: 0,
            sourceWidth: image.width, sourceHeight: image.height, seed: annotation(tool: tool, rect: boxes[0]), replacingID: nil,
            candidates: boxes.enumerated().map { AutomaticMosaicReviewCandidate(rect: $0.element, confidence: 1, included: true, isSeed: $0.offset == 0) })
    }
    private func raster(width: Int = 321, height: Int = 241) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func matches() -> RepeatedRegionMatchResult {
        RepeatedRegionMatchResult(seed: AutomaticMosaicCoordinates.pixelRect(boxes[0], imageHeight: 241)!,
            candidates: boxes.dropFirst().map { RepeatedRegionCandidate(rect: AutomaticMosaicCoordinates.pixelRect($0, imageHeight: 241)!, confidence: 1) },
            examinedOrigins: 100, truncated: false)
    }
    @MainActor private func installMatches(_ editor: ImageEditorController) {
        let result = matches(); editor.automaticMosaicFind = { _, _ in result }
    }
    @MainActor private func editor() throws -> ImageEditorController {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: try raster(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.annotationCanvas.zoom = 1
        editor.chooseTool(.select); return editor
    }
    @MainActor private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private func control<T: NSView>(_ id: String, _ editor: ImageEditorController) throws -> T {
        try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == id } as? T)
    }
    @MainActor private func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @MainActor private func key(_ canvas: ImageEditorCanvas, _ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    @MainActor private func command(_ canvas: ImageEditorCanvas, _ text: String, code: UInt16, shift: Bool = false) throws {
        XCTAssertTrue(canvas.performKeyEquivalent(with: try key(canvas, text, code: code, flags: shift ? [.command, .shift] : .command)))
    }
    @MainActor private func click(_ canvas: ImageEditorCanvas, _ point: CGPoint) throws {
        canvas.tool = .select
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point))
    }
    @MainActor private func drag(_ canvas: ImageEditorCanvas, _ rect: CGRect) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, rect.origin))
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class CompletionGate {
    var waiting: Bool { continuation != nil }
    private var continuation: CheckedContinuation<RepeatedRegionMatchResult, Never>?
    func wait() async -> RepeatedRegionMatchResult {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ result: RepeatedRegionMatchResult) { continuation?.resume(returning: result); continuation = nil }
}
