import AppKit
import CoreImage
import XCTest
@testable import PicShot

/// Uses per-render/per-canvas failures. No global renderer override or GPU is needed
/// to prove that an incomplete effect stack cannot reach a final-output callback.
@MainActor final class EditorOutputProjectionEffectFailureTests: XCTestCase {
    func testNilPatchRejectsWholeRasterForBothToolsEveryPositionAndLinkedGroups() throws {
        let source = try raster(), before = try pixels(source)
        for tool in [ImageEditorTool.blur, .pixelate] {
            for linked in [false, true] {
                let marks = effects(tool, linked: linked)
                for failingCall in 1...marks.count {
                    var calls = 0
                    let result = ImageEditorRenderer.render(image: source, annotations: marks) { _, region in
                        calls += 1
                        return calls == failingCall ? nil : self.patch(region)
                    }
                    XCTAssertNil(result, "\(tool), linked=\(linked), patch=\(failingCall)")
                    XCTAssertEqual(calls, failingCall, "Stop before drawing more effects into a rejected image")
                    XCTAssertEqual(try pixels(source), before)
                }
            }
        }
    }

    func testSuccessfulPatchInjectionKeepsExactRegionsAndExteriorPixels() throws {
        let source = try raster(), before = try pixels(source)
        for tool in [ImageEditorTool.blur, .pixelate] {
            let marks = effects(tool, linked: true)
            var regions: [CGRect] = []
            let result = try XCTUnwrap(ImageEditorRenderer.render(image: source, annotations: marks) { input, region in
                XCTAssertEqual(input.extent, region)
                regions.append(region)
                return self.patch(region)
            })
            XCTAssertEqual(regions, marks.map { $0.bounds.integral })
            let after = try pixels(result)
            var changed = 0
            for y in 0..<source.height { for x in 0..<source.width {
                let offset = (y * source.width + x) * 4
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(source.height - 1 - y) + 0.5)
                if regions.contains(where: { $0.contains(point) }) {
                    if before[offset..<(offset + 4)] != after[offset..<(offset + 4)] { changed += 1 }
                } else {
                    XCTAssertEqual(before[offset..<(offset + 4)], after[offset..<(offset + 4)])
                }
            } }
            XCTAssertGreaterThan(changed, 0)
        }
    }

    func testFailedDirectDrawRestoresCallerGraphicsStateAndOutOfFrameEffectsNeedNoPatch() throws {
        let source = try raster(), context = try bitmap(width: 96, height: 72)
        context.translateBy(x: 3, y: 5)
        context.clip(to: CGRect(x: 0, y: 0, width: 90, height: 60))
        let transform = context.ctm, clip = context.boundingBoxOfClipPath
        let complete = ImageEditorRenderer.drawAnnotations(effects(.blur, linked: true), in: context,
            extent: CGRect(x: 0, y: 0, width: 96, height: 72), baseImage: source,
            effectPatchRenderer: { _, _ in nil })
        XCTAssertFalse(complete)
        XCTAssertEqual(context.ctm, transform)
        XCTAssertEqual(context.boundingBoxOfClipPath, clip)
        let outside = ImageAnnotation(tool: .pixelate, points: [CGPoint(x: 120, y: 100), CGPoint(x: 140, y: 120)])
        var calls = 0
        XCTAssertNotNil(ImageEditorRenderer.render(image: source, annotations: [outside]) { _, _ in
            calls += 1; return nil
        })
        XCTAssertEqual(calls, 0)
    }

    func testMagnifierCannotTurnFailedEarlierOrLaterEffectsIntoSuccessfulRaster() throws {
        let source = try raster(), lens = magnifier()
        for tool in [ImageEditorTool.blur, .pixelate] {
            let effect = effects(tool, linked: false)[0]
            for marks in [[effect, lens], [lens, effect]] {
                var calls = 0
                XCTAssertNil(ImageEditorRenderer.render(image: source, annotations: marks) { _, _ in
                    calls += 1; return nil
                })
                XCTAssertEqual(calls, 1)
            }
        }
    }

    func testNestedMagnifierDrawPropagatesFailureAndRestoresBothGraphicsStates() throws {
        let source = try raster(), context = try bitmap(width: 96, height: 72)
        context.translateBy(x: 2, y: 7)
        let transform = context.ctm, clip = context.boundingBoxOfClipPath
        let redaction = ImageAnnotation(tool: .redact, points: [CGPoint(x: 4, y: 5), CGPoint(x: 12, y: 15)])
        // Production passes only redaction/eraser privacy marks. Exercise the recursive
        // draw contract too, so a future additional effect cannot be silently ignored.
        for tool in [ImageEditorTool.blur, .pixelate] {
            var calls = 0
            XCTAssertFalse(AnnotationMagnifierRenderer.draw(magnifier(), snapshot: source,
                extent: CGRect(x: 0, y: 0, width: 96, height: 72),
                privacyMarks: [redaction, effects(tool, linked: false)[0]], in: context,
                effectPatchRenderer: { _, _ in calls += 1; return nil }))
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(context.ctm, transform)
            XCTAssertEqual(context.boundingBoxOfClipPath, clip)
        }
    }

    func testFailedCanvasRenderCannotCachePartialPixelsOrReusePriorRevision() throws {
        let source = try raster(), canvas = ImageEditorCanvas(image: source)
        let first = effects(.blur, linked: false)[0]
        canvas.effectPatchRenderer = { _, region in self.patch(region) }
        canvas.add(first)
        let safe = try XCTUnwrap(canvas.rasterForBoundaryPreview()), safeBytes = try pixels(safe)
        XCTAssertNotNil(canvas.retainedPresentationRaster)
        canvas.effectPatchRenderer = { _, _ in nil }
        XCTAssertNil(canvas.retainedPresentationRaster, "Changing the per-canvas renderer invalidates cached output")
        canvas.setContent(image: source, annotations: [first, effects(.pixelate, linked: false)[1]])
        let ids = canvas.annotations.map(\.id)
        for _ in 0..<2 {
            XCTAssertNil(canvas.rasterForBoundaryPreview())
            XCTAssertNil(canvas.flattened())
            XCTAssertNil(canvas.retainedPresentationRaster)
        }
        XCTAssertEqual(canvas.annotations.map(\.id), ids)
        XCTAssertTrue(canvas.image === source)
        XCTAssertEqual(try pixels(safe), safeBytes, "A rejected render cannot overwrite an earlier safe raster")
        canvas.effectPatchRenderer = { _, region in self.patch(region) }
        let retried = try XCTUnwrap(canvas.flattened())
        XCTAssertEqual(retried.width, source.width); XCTAssertEqual(retried.height, source.height)
        XCTAssertEqual(canvas.annotations.map(\.id), ids)
    }

    func testEveryOutputRouteRejectsNilPatchKeepsDraftAndPriorPublishedFile() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("effect-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("safe.png"), source = try raster()
        let safeRedaction = ImageAnnotation(tool: .redact,
            points: [CGPoint(x: 3, y: 4), CGPoint(x: 50, y: 40)])
        let safeImage = try XCTUnwrap(ImageEditorRenderer.render(image: source, annotations: [safeRedaction]))
        try safeImage.writePNG(to: output)
        let saved = try Data(contentsOf: output)
        for tool in [ImageEditorTool.blur, .pixelate] {
            for decorated in [false, true] {
                let editor = makeEditor(source); defer { editor.close() }
                let canvas = editor.annotationCanvas
                canvas.effectPatchRenderer = { _, _ in nil }
                canvas.add(effects(tool, linked: true)[0])
                if decorated { _ = try editor.applyOutputDecoration(decoration) }
                let draft = draftState(editor), frame = editor.window?.frame
                var errors = 0, callbacks = 0, closes = 0
                editor.onOutputError = { error in
                    XCTAssertTrue(error is ImageEditorRenderingError)
                    XCTAssertFalse(error.localizedDescription.isEmpty)
                    errors += 1
                }
                editor.onClose = { closes += 1 }
                for route in ImageEditorOutputRoute.allCases {
                    editor.requestOutput(for: route, close: true) { image in
                        callbacks += 1
                        try? image.writePNG(to: output)
                    }
                    XCTAssertEqual(callbacks, 0, "\(route) must not publish a partial or original-image fallback")
                    XCTAssertFalse(editor.isClosed); XCTAssertEqual(closes, 0)
                    XCTAssertEqual(editor.window?.frame, frame)
                    XCTAssertTrue(editor.initialOriginalImage === source)
                    XCTAssertEqual(draftState(editor), draft)
                    XCTAssertNil(canvas.retainedPresentationRaster)
                    XCTAssertFalse(editor.outputProjectionIsPending)
                    XCTAssertFalse(EditorOutputProjection.shared.isBusy)
                    XCTAssertEqual(EditorOutputProjection.shared.reservedBytes, 0)
                    XCTAssertEqual(try Data(contentsOf: output), saved)
                }
                XCTAssertEqual(errors, ImageEditorOutputRoute.allCases.count)
                XCTAssertEqual(editor.outputDeliveryCount, 0); XCTAssertNil(editor.lastOutputRoute)
                // Undo/redo stays usable after output failure and restores the exact saved draft.
                send("undoEdit", editor); send("redoEdit", editor)
                XCTAssertEqual(draftState(editor), draft)
                canvas.effectPatchRenderer = { _, region in self.patch(region) }
                var retry: CGImage?
                // Retry the undressed raster synchronously; no output destination is changed.
                if decorated { send("undoEdit", editor) }
                editor.requestOutput(for: .copy) { retry = $0 }
                XCTAssertNotNil(retry); XCTAssertEqual(editor.outputDeliveryCount, 1)
                XCTAssertEqual(try Data(contentsOf: output), saved)
            }
        }
    }

    func testNativeOutputSelectorsNeverCallLegacyOrOriginalAwareSinksOnRenderFailure() throws {
        _ = NSApplication.shared
        for originalAware in [false, true] {
            for decorated in [false, true] {
                var deliveries = 0, errors = 0
                let workflow = SaveWorkflowPresenter(isSmoke: true)
                let originalSink: ((CGImage, CGImage) -> Bool)? = originalAware ? { _, _ in deliveries += 1; return true } : nil
                let editor = ImageEditorController(image: try raster(),
                    onSave: { _ in deliveries += 1 }, onPin: { _ in deliveries += 1 }, onOCR: { _ in deliveries += 1 },
                    onTranslate: { _ in deliveries += 1 }, onApply: { _ in deliveries += 1; return true },
                    saveWorkflow: workflow, copyAction: { _ in deliveries += 1 }, onPinWithOriginal: originalSink)
                defer { editor.close() }
                editor.annotationCanvas.effectPatchRenderer = { _, _ in nil }
                editor.annotationCanvas.add(effects(.pixelate, linked: true)[0])
                if decorated { _ = try editor.applyOutputDecoration(decoration) }
                let draft = draftState(editor)
                editor.onOutputError = { error in XCTAssertTrue(error is ImageEditorRenderingError); errors += 1 }
                let selectors = ["copyResult", "saveResult", "pinResult", "quickSaveResult", "saveCopyResult",
                                 "recognizeResult", "translateResult", "applyResult", "exportResult"]
                for selector in selectors {
                    send(selector, editor)
                    XCTAssertEqual(deliveries, 0, selector)
                    XCTAssertEqual(editor.outputDeliveryCount, 0, selector)
                    XCTAssertFalse(editor.isClosed, selector)
                    XCTAssertFalse(editor.outputProjectionIsPending, selector)
                    XCTAssertTrue(workflow.controllers.isEmpty, selector)
                    XCTAssertEqual(draftState(editor), draft, selector)
                }
                XCTAssertEqual(errors, selectors.count)
            }
        }
    }

    func testFailedLegacyCropCannotBakePartialEffectsOrReplaceSource() throws {
        _ = NSApplication.shared
        let source = try raster(), editor = makeEditor(source)
        defer { editor.close() }
        for tool in [ImageEditorTool.blur, .pixelate] {
            editor.annotationCanvas.setContent(image: source, annotations: effects(tool, linked: true))
            editor.annotationCanvas.effectPatchRenderer = { _, _ in nil }
            let crop = CGRect(x: 2, y: 3, width: 80, height: 60)
            editor.annotationCanvas.cropRect = crop
            let draft = draftState(editor)
            send("applyCrop", editor)
            XCTAssertEqual(draftState(editor), draft)
            XCTAssertTrue(editor.annotationCanvas.image === source)
            XCTAssertEqual(editor.annotationCanvas.cropRect, crop)
            XCTAssertNil(editor.annotationCanvas.flattened())
            XCTAssertNil(editor.annotationCanvas.retainedPresentationRaster)
        }
    }

    private let decoration = ImageOutputDecoration(enabled: true, cornerRadius: 3, borderEnabled: true, borderWidth: 1)
    private func makeEditor(_ source: CGImage) -> ImageEditorController {
        ImageEditorController(image: source, onSave: { _ in XCTFail("Unexpected save") },
            onPin: { _ in XCTFail("Unexpected pin") }, onOCR: { _ in XCTFail("Unexpected recognition") },
            saveWorkflow: SaveWorkflowPresenter(isSmoke: true), copyAction: { _ in XCTFail("Unexpected copy") })
    }
    private struct DraftState: Equatable {
        let image: ObjectIdentifier
        let annotations: [AnnotationState]
        let decoration: ImageOutputDecoration
    }
    private struct AnnotationState: Equatable {
        let id: UUID
        let tool: String
        let points: [CGPoint]
        let color: [CGFloat]
        let lineWidth: CGFloat
        let opacity: CGFloat
        let rotation: CGFloat
        let group: UUID?
        let addition: UUID?
        let root: UUID?
        let target: CGRect?
        let included: [CGRect]
        let excluded: [CGRect]
        let synchronizes: Bool?
        init(_ mark: ImageAnnotation) {
            id = mark.id; tool = mark.tool.rawValue; points = mark.points
            color = mark.color.components ?? []; lineWidth = mark.lineWidth
            opacity = mark.opacity; rotation = mark.rotation
            group = mark.mosaicLink?.groupID; addition = mark.mosaicLink?.additionID
            root = mark.mosaicLink?.rootAdditionID; target = mark.mosaicLink?.target
            included = mark.mosaicLink?.includedTargets ?? []; excluded = mark.mosaicLink?.excludedTargets ?? []
            synchronizes = mark.mosaicLink?.synchronizes
        }
    }
    private func draftState(_ editor: ImageEditorController) -> DraftState {
        DraftState(image: ObjectIdentifier(editor.annotationCanvas.image),
            annotations: editor.annotationCanvas.annotations.map(AnnotationState.init), decoration: editor.outputDecoration)
    }
    private func send(_ name: String, _ editor: ImageEditorController) {
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString(name), to: editor, from: nil))
    }
    private func magnifier() -> ImageAnnotation {
        var mark = ImageAnnotation(tool: .magnifier, points: [CGPoint(x: 55, y: 35), CGPoint(x: 85, y: 60)])
        mark.magnifierSource = CGRect(x: 5, y: 6, width: 18, height: 14)
        mark.magnifierShowsAnnotations = true
        return mark
    }
    private func effects(_ tool: ImageEditorTool, linked: Bool) -> [ImageAnnotation] {
        let rects = [CGRect(x: 5, y: 7, width: 17, height: 13), CGRect(x: 33, y: 21, width: 19, height: 15),
                     CGRect(x: 61, y: 43, width: 21, height: 17)]
        let group = UUID(), addition = UUID()
        return rects.map { rect in
            var mark = ImageAnnotation(tool: tool, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)])
            if linked {
                mark.mosaicLink = AutomaticMosaicLink(groupID: group, additionID: addition, rootAdditionID: addition,
                    target: rect, includedTargets: rects, excludedTargets: [], synchronizes: true)
            }
            return mark
        }
    }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func raster() throws -> CGImage {
        let context = try bitmap(width: 96, height: 72)
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 72))
        return try XCTUnwrap(context.makeImage())
    }
    private func patch(_ region: CGRect) -> CGImage? {
        guard let context = try? bitmap(width: Int(region.width), height: Int(region.height)) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(origin: .zero, size: region.size))
        return context.makeImage()
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] { try EditorOutputDecorationNativeFixture.raster(image) }
}
