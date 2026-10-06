import AppKit
import CoreGraphics
import CoreText
import CryptoKit

/// Installed-app UI evidence, built only from an original synthetic desktop.
/// All marks are created through native controls and canvas NSEvents. The 1×
/// evidence is deliberately not a Retina, screen-capture, or permission test.
@MainActor
enum AnnotationEffectsPreviewFixture {
    private static let maximumPixels = 4_000_000
    private static let frozenDate = Date(timeIntervalSince1970: 1_704_164_645)
    private static let reportName = "annotation-effects-preview.json"

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        var report: [String: Any] = [
            "status": "running", "syntheticDesktop": true,
            "scope": "Native AppKit controls, canvas NSEvents and flattened exports on an original 1x synthetic desktop; no live desktop pixels or capture permissions",
            "sourcePixelsPerPoint": 1, "snapshotPixelsPerPoint": 1,
            "screenCaptureAttempted": false, "audioCaptureAttempted": false,
            "cameraCaptureAttempted": false, "ocrInferenceAttempted": false,
            "networkAttempted": false, "preferencesWritten": false,
            "maximumFixtureRasterPixels": maximumPixels,
            "maximumConcurrentOwnedEditors": 1,
            "limitations": ["Synthetic 1x source and view-cache snapshots, not Retina acquisition", "No TCC, physical-input routing, OCR, or recording coverage", "Raster bounds are not a process-memory or leak measurement"]
        ]
        var completed: [String] = []
        do {
            guard let screen = NSScreen.main, let displayID = screen.displayID else {
                throw failure("No WindowServer display is available")
            }
            let size = CGSize(width: min(1_280, floor(screen.frame.width)), height: min(820, floor(screen.frame.height)))
            guard size.width >= 760, size.height >= 600 else {
                throw failure("A native display of at least 760 by 600 points is needed")
            }
            let frame = CGRect(origin: screen.frame.origin, size: size)
            let selection = CGRect(x: 64, y: 96, width: size.width - 128, height: size.height - 256)
            let desktop = try syntheticDesktop(size: size, selection: selection)
            let captured = try CapturedImage.frozenRegion(image: desktop, displayID: displayID,
                displayFrame: frame, selection: selection, capturedAt: frozenDate)
            report["nativeDisplayBackingScale"] = screen.backingScaleFactor
            report["desktopPixelWidth"] = desktop.width; report["desktopPixelHeight"] = desktop.height
            report["resultPixelWidth"] = captured.image.width; report["resultPixelHeight"] = captured.image.height
            report["frozenCaptureEpochSeconds"] = frozenDate.timeIntervalSince1970
            let originalDigest = try digest(captured.image)
            NSApp.appearance = NSAppearance(named: .aqua)
            report["eraser"] = try await withEditor(captured, name: "eraser", directory: evidenceDirectory) { editor in
                try await verifyEraser(editor, directory: evidenceDirectory)
            }
            completed.append("eraser")
            report["spotlight"] = try await withEditor(captured, name: "spotlight", directory: evidenceDirectory) { editor in
                try await verifySpotlight(editor, directory: evidenceDirectory)
            }
            completed.append("spotlight")
            report["watermark"] = try await withEditor(captured, name: "watermark", directory: evidenceDirectory) { editor in
                try await verifyWatermark(editor, directory: evidenceDirectory)
            }
            completed.append("watermark")
            report["magnifier"] = try await withEditor(captured, name: "magnifier", directory: evidenceDirectory) { editor in
                try await verifyMagnifier(editor, directory: evidenceDirectory)
            }
            completed.append("magnifier")
            guard try digest(captured.image) == originalDigest else { throw failure("Editing mutated the original capture pixels") }
            report["status"] = "passed"; report["originalRasterPreserved"] = true
            report["allOwnedEditorsClosed"] = true
            report["completedChecks"] = completed
            report["files"] = [
                "ui-annotation-eraser-brush.png", "ui-annotation-eraser-rectangle.png",
                "ui-annotation-spotlight-light.png", "ui-annotation-spotlight-dark.png",
                "ui-annotation-watermark-center.png", "ui-annotation-watermark-tiled.png",
                "ui-annotation-magnifier-source-lens.png", "ui-annotation-magnifier-redaction-safe.png",
                "annotation-eraser-result.png", "annotation-spotlight-result.png",
                "annotation-watermark-result.png", "annotation-magnifier-result.png", reportName
            ]
            try writeReport(report, directory: evidenceDirectory)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedChecks"] = completed
            // Every withEditor owns a defer that closes its controller on failure.
            report["ownedEditorCleanupAttempted"] = true
            try? writeReport(report, directory: evidenceDirectory)
            throw error
        }
    }

    private static func withEditor(_ captured: CapturedImage, name: String, directory: URL,
        body: (ImageEditorController) async throws -> [String: Any]) async throws -> [String: Any] {
        var saves = 0, forbiddenCallbacks = 0, closes = 0
        var savedDigest: String?, saveError: Error?
        let resultURL = directory.appendingPathComponent("annotation-\(name)-result.png")
        let editor = ImageEditorController(image: captured.image, presentation: captured.presentation,
            onSave: { image in
                saves += 1
                do { try image.writePNG(to: resultURL); savedDigest = try digest(image) }
                catch { saveError = error }
            }, onPin: { _ in forbiddenCallbacks += 1 }, onOCR: { _ in forbiddenCallbacks += 1 })
        editor.onClose = { closes += 1 }
        defer { editor.close() }
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        try await settle(editor)
        guard editor.annotationCanvas.annotations.isEmpty,
              editor.annotationCanvas.image === captured.image,
              editor.annotationCanvas.zoom == 1, editor.annotationCanvas.displayScaleY == 1 else {
            throw failure("\(name) did not start as an unannotated 1x synthetic capture")
        }
        var result = try await body(editor)
        let finalDigest = try digest(unwrap(editor.annotationCanvas.flattened(), "Cannot flatten \(name)"))
        try menuAction(title: "保存到历史", editor)
        if let saveError { throw saveError }
        guard saves == 1, savedDigest == finalDigest, forbiddenCallbacks == 0,
              FileManager.default.fileExists(atPath: resultURL.path) else {
            throw failure("\(name) native save callback did not receive the final flattened raster")
        }
        try click("editor.cancel", editor)
        guard editor.isClosed, editor.window?.isVisible != true, editor.window?.contentView == nil,
              editor.window?.delegate == nil, editor.captureBoundaryWorkspace.frozenImage == nil,
              closes == 1, saves == 1, forbiddenCallbacks == 0,
              editor.annotationCanvas.image === captured.image else {
            throw failure("\(name) cancel did not close owned UI and preserve its input")
        }
        result["nativeSaveCallbackCount"] = saves; result["nativeCancelPreservedInput"] = true
        result["ownedWindowDetachedOnClose"] = true; result["flattenedSHA256"] = finalDigest
        result["resultFile"] = resultURL.lastPathComponent
        return result
    }

    private static func verifyEraser(_ editor: ImageEditorController, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas, original = canvas.image
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(canvas, x, y) }
        try choose(.rectangle, editor); try click("annotation.fill", editor)
        try picker("annotation.lineWidth", title: "4", editor)
        try drag(canvas, from: p(0.08, 0.18), to: p(0.66, 0.78))
        guard canvas.annotations.count == 1, canvas.annotations[0].fillEnabled else { throw failure("Native filled rectangle was not created") }
        let painted = try digest(unwrap(canvas.flattened(), "Missing painted rectangle"))
        try choose(.eraser, editor); try picker("annotation.lineWidth", title: "48", editor)
        try cancelDrag(canvas, from: p(0.20, 0.26), to: p(0.20, 0.68))
        guard !editor.isClosed, canvas.annotations.count == 1,
              try digest(unwrap(canvas.flattened(), "Missing cancelled brush result")) == painted else {
            throw failure("Escape committed the draft eraser or closed the editor")
        }
        for x in [CGFloat(0.20), CGFloat(0.33)] { try drag(canvas, from: p(x, 0.26), to: p(x, 0.68)) }
        guard canvas.annotations.count == 3, canvas.annotations.dropFirst().allSatisfy({
            $0.tool == .eraser && $0.eraserMode == .brush && $0.lineWidth == 48 && $0.points.count <= ImageAnnotation.maximumGesturePoints
        }) else { throw failure("Repeated native brush gestures did not produce bounded eraser operations") }
        let brushDigest = try digest(unwrap(canvas.flattened(), "Missing brush result"))
        let erasedPoint = p(0.20, 0.46)
        guard try pixel(unwrap(canvas.flattened(), "Missing eraser raster"), erasedPoint) == pixel(original, erasedPoint) else {
            throw failure("Brush erasure did not reveal the exact original pixel")
        }
        try click("editor.undo", editor)
        try cancelDrag(canvas, from: p(0.50, 0.26), to: p(0.50, 0.68))
        try click("editor.redo", editor)
        guard try digest(unwrap(canvas.flattened(), "Missing eraser redo")) == brushDigest else {
            throw failure("Cancelled erasure consumed the redo branch")
        }
        try await evidence(editor, name: "ui-annotation-eraser-brush.png", controls: ["annotation.eraserMode", "annotation.lineWidth", "annotation.clearAnnotations"], directory: directory)
        try picker("annotation.eraserMode", index: 1, editor)
        try drag(canvas, from: p(0.45, 0.27), to: p(0.59, 0.68))
        guard canvas.annotations.count == 4, canvas.annotations.last?.eraserMode == .rectangle,
              try pixel(unwrap(canvas.flattened(), "Missing rectangle eraser result"), p(0.52, 0.46)) == pixel(original, p(0.52, 0.46)) else {
            throw failure("Rectangle eraser palette or rendered coverage is incorrect")
        }
        let erased = try digest(unwrap(canvas.flattened(), "Missing erased raster"))
        for _ in 0..<2 {
            for _ in 0..<3 { try commandUndo(canvas) }
            guard canvas.annotations.count == 1, try digest(unwrap(canvas.flattened(), "Missing eraser undo")) == painted else {
                throw failure("Eraser gestures created extra undo states")
            }
            for _ in 0..<3 { try commandUndo(canvas, redo: true) }
            guard try digest(unwrap(canvas.flattened(), "Missing eraser repeat redo")) == erased else { throw failure("Repeated eraser redo changed pixels") }
        }
        try click("annotation.clearAnnotations", editor)
        guard canvas.annotations.isEmpty, canvas.image === original,
              try digest(unwrap(canvas.flattened(), "Missing clear result")) == digest(original) else { throw failure("Clear annotations changed capture pixels") }
        try commandUndo(canvas)
        guard try digest(unwrap(canvas.flattened(), "Missing clear undo")) == erased else { throw failure("Clear annotations was not undoable") }
        try commandUndo(canvas, redo: true); try commandUndo(canvas)
        try choose(.rectangle, editor); try picker("annotation.lineWidth", title: "4", editor)
        try drag(canvas, from: p(0.48, 0.38), to: p(0.56, 0.54))
        guard try pixel(unwrap(canvas.flattened(), "Missing later ink"), p(0.52, 0.46)) != pixel(original, p(0.52, 0.46)) else {
            throw failure("Earlier eraser removed later ink")
        }
        try commandUndo(canvas); try choose(.eraser, editor)
        try await evidence(editor, name: "ui-annotation-eraser-rectangle.png", controls: ["annotation.eraserMode", "annotation.clearAnnotations"], directory: directory)
        return ["brushAndRectangleNativeGestures": true, "escapePreservesRedo": true,
                "twoUndoRedoCyclesPixelIdentical": true, "oneUndoStatePerGesture": true,
                "clearUndoRedoPreservesBase": true, "laterInkSurvives": true,
                "originalRasterIdentityPreserved": canvas.image === original, "committedAnnotationCount": canvas.annotations.count]
    }

    private static func verifySpotlight(_ editor: ImageEditorController, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas
        try choose(.spotlight, editor); try picker("annotation.spotlightShape", index: 0, editor)
        try slider("annotation.spotlightDim", value: 0.5, editor); try click("annotation.spotlightBorder", editor)
        let start = point(canvas, 0.16, 0.30), end = point(canvas, 0.80, 0.82)
        try drag(canvas, from: start, to: end)
        let originalMark = try unwrap(canvas.annotations.first, "Native spotlight was not created")
        let first = try unwrap(canvas.flattened(), "Missing spotlight raster")
        let inside = point(canvas, 0.48, 0.56), outside = point(canvas, 0.03, 0.03)
        let dimmed = try pixel(first, outside), base = try pixel(canvas.image, outside)
        guard originalMark.spotlightShape == .rectangle, !originalMark.spotlightBorder,
              try pixel(first, inside) == pixel(canvas.image, inside), dimmed[3] == base[3],
              zip(dimmed.prefix(3), base.prefix(3)).allSatisfy({ abs(Int($0.0) - Int($0.1) / 2) <= 2 }) else {
            throw failure("Spotlight changed its interior or failed to dim only the exterior")
        }
        let initialDigest = try digest(first)
        try slider("annotation.spotlightDim", value: 0.72, editor)
        try click("annotation.spotlightBorder", editor); try picker("annotation.spotlightShape", index: 1, editor)
        guard let updated = canvas.annotations.first, updated.spotlightShape == .ellipse,
              updated.spotlightBorder, abs(updated.spotlightDim - 0.72) < 0.001 else {
            throw failure("Native spotlight palette did not edit the selected mark")
        }
        let editedDigest = try digest(unwrap(canvas.flattened(), "Missing edited spotlight"))
        for _ in 0..<3 { try commandUndo(canvas) }
        guard try digest(unwrap(canvas.flattened(), "Missing spotlight undo")) == initialDigest else { throw failure("Spotlight palette undo changed original pixels") }
        for _ in 0..<3 { try commandUndo(canvas, redo: true) }
        guard try digest(unwrap(canvas.flattened(), "Missing spotlight redo")) == editedDigest else { throw failure("Spotlight palette redo changed final pixels") }
        let controls = ["annotation.spotlightShape", "annotation.spotlightDim", "annotation.spotlightBorder", "annotation.lineWidth"]
        try await evidence(editor, name: "ui-annotation-spotlight-light.png", controls: controls, directory: directory)
        let oldAppearance = editor.window?.appearance
        defer { editor.window?.appearance = oldAppearance }
        editor.window?.appearance = NSAppearance(named: .darkAqua)
        try await evidence(editor, name: "ui-annotation-spotlight-dark.png", controls: controls, directory: directory)
        guard editor.floatingSurfaceIsDark, try digest(unwrap(canvas.flattened(), "Missing dark spotlight")) == editedDigest else {
            throw failure("Dark native spotlight changed export pixels or missed the floating palette")
        }
        return ["nativeShapeDimAndBorderControls": true, "interiorUnchanged": true,
                "exteriorDimmed": true, "paletteUndoRedoPixelIdentical": true,
                "lightAndDarkPaletteSnapshots": true, "appearanceDoesNotChangeExport": true]
    }

    private static func verifyWatermark(_ editor: ImageEditorController, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas
        try choose(.watermark, editor)
        try field("annotation.watermarkTemplate", value: "REVIEW COPY", editor)
        try click("annotation.watermarkTimestamp", editor)
        try picker("annotation.watermarkPlacement", index: 7, editor)
        try field("annotation.fontSize", value: "24", editor)
        try slider("annotation.opacity", value: 0.65, editor); try click("annotation.swatch.6", editor)
        try canvasClick(canvas, point(canvas, 0.5, 0.5))
        let initial = try unwrap(canvas.annotations.first, "Native watermark click did not create a mark")
        guard initial.tool == .watermark, initial.watermarkPlacement == .center,
              initial.watermarkTemplate == "REVIEW COPY $yyyy-MM-dd HH:mm:ss$",
              initial.frozenTimestamp == frozenDate, initial.timestampIsCaptureDate,
              initial.frozenTimeZoneIdentifier == canvas.captureTimeZoneIdentifier else {
            throw failure("Watermark failed to freeze its capture timestamp or native template")
        }
        let text = AnnotationWatermarkLayout.resolvedText(initial)
        let initialDigest = try digest(unwrap(canvas.flattened(), "Missing watermark raster"))
        guard !text.contains("$"), text.hasPrefix("REVIEW COPY "),
              initialDigest != (try digest(canvas.image)) else { throw failure("Watermark did not resolve and render its time template") }
        try await evidence(editor, name: "ui-annotation-watermark-center.png", controls: ["annotation.watermarkTemplate", "annotation.watermarkPlacement", "annotation.watermarkTimestamp", "annotation.opacity"], directory: directory)
        try picker("annotation.watermarkPlacement", index: 0, editor)
        try field("annotation.watermarkSpacing", value: "72", editor)
        try slider("annotation.opacity", value: 0.35, editor)
        let tiled = try unwrap(canvas.annotations.first, "Lost tiled watermark")
        let tiles = AnnotationWatermarkLayout.tileRects(for: tiled)
        guard tiled.watermarkPlacement == .tiled, tiled.watermarkSpacing == 72,
              abs(tiled.opacity - 0.35) < 0.001, tiles.count > 1,
              tiles.count <= AnnotationWatermarkLayout.maximumTiles else { throw failure("Native watermark tiling controls were ignored") }
        let tiledDigest = try digest(unwrap(canvas.flattened(), "Missing tiled watermark"))
        for _ in 0..<2 {
            for _ in 0..<3 { try commandUndo(canvas) }
            guard try digest(unwrap(canvas.flattened(), "Missing watermark undo")) == initialDigest else { throw failure("Watermark undo did not restore the centered result") }
            for _ in 0..<3 { try commandUndo(canvas, redo: true) }
            guard let mark = canvas.annotations.first, mark.frozenTimestamp == frozenDate,
                  AnnotationWatermarkLayout.resolvedText(mark) == text,
                  try digest(unwrap(canvas.flattened(), "Missing watermark redo")) == tiledDigest else {
                throw failure("Watermark redraw or redo changed the frozen text or pixels")
            }
        }
        try await evidence(editor, name: "ui-annotation-watermark-tiled.png", controls: ["annotation.watermarkTemplate", "annotation.watermarkPlacement", "annotation.watermarkSpacing", "annotation.opacity"], directory: directory)
        return ["nativeOverflowMenuAndCanvasClick": true, "nativeTemplateAndTimestampInsertion": true,
                "captureTimestampFrozenAcrossUndoRedo": true, "twoUndoRedoCyclesPixelIdentical": true,
                "centerAndTiledPlacement": true, "tileCount": tiles.count,
                "resolvedText": text, "frozenTimeZoneIdentifier": initial.frozenTimeZoneIdentifier]
    }

    private static func verifyMagnifier(_ editor: ImageEditorController, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(canvas, x, y) }
        try choose(.rectangle, editor); try click("annotation.fill", editor)
        try drag(canvas, from: p(0.15, 0.43), to: p(0.29, 0.49))
        try choose(.magnifier, editor); try field("annotation.magnifierScale", value: "2", editor)
        try picker("annotation.magnifierShape", index: 0, editor)
        try picker("annotation.magnifierConnector", index: 2, editor)
        try click("annotation.magnifierSmooth", editor)
        try drag(canvas, from: p(0.12, 0.25), to: p(0.30, 0.55))
        let initial = try unwrap(canvas.annotations.last, "Native magnifier source drag did not create a lens")
        guard initial.tool == .magnifier, initial.magnifierShape == .rectangle,
              initial.magnifierConnector == .edges, initial.magnifierSmooth,
              initial.magnifierShowsAnnotations,
              abs(initial.localBounds.width - initial.magnifierSourceRect.width * 2) < 0.01 else {
            throw failure("Native magnifier controls did not reach the model")
        }
        try choose(.select, editor)
        let movedLensCenter = center(initial.localBounds).applying(CGAffineTransform(translationX: CGFloat(canvas.image.width) * 0.10, y: CGFloat(canvas.image.height) * 0.04))
        try drag(canvas, from: center(initial.localBounds), to: movedLensCenter)
        let lensMoved = try unwrap(canvas.annotations.last, "Lens drag lost its mark")
        guard close(center(lensMoved.localBounds), movedLensCenter),
              lensMoved.magnifierSourceRect == initial.magnifierSourceRect else { throw failure("Dragging the lens moved its source") }
        let sourceDelta = CGSize(width: CGFloat(canvas.image.width) * 0.02, height: -CGFloat(canvas.image.height) * 0.03)
        let sourceTarget = CGPoint(x: initial.magnifierSourceRect.midX + sourceDelta.width, y: initial.magnifierSourceRect.midY + sourceDelta.height)
        try drag(canvas, from: center(initial.magnifierSourceRect), to: sourceTarget)
        let sourceMoved = try unwrap(canvas.annotations.last, "Source drag lost its mark")
        guard same(sourceMoved.localBounds, lensMoved.localBounds),
              same(sourceMoved.magnifierSourceRect, initial.magnifierSourceRect.offsetBy(dx: sourceDelta.width, dy: sourceDelta.height)) else {
            throw failure("Dragging the source moved the lens")
        }
        let movedDigest = try digest(unwrap(canvas.flattened(), "Missing moved lens raster"))
        try commandUndo(canvas)
        try cancelDrag(canvas, from: center(initial.magnifierSourceRect), to: p(0.32, 0.35))
        guard !editor.isClosed, let cancelled = canvas.annotations.last,
              same(cancelled.magnifierSourceRect, initial.magnifierSourceRect), same(cancelled.localBounds, lensMoved.localBounds) else {
            throw failure("Escape did not restore the source drag")
        }
        try commandUndo(canvas, redo: true)
        guard try digest(unwrap(canvas.flattened(), "Missing lens redo")) == movedDigest else { throw failure("Cancelled magnifier source drag consumed redo") }
        try cancelDrag(canvas, from: movedLensCenter, to: p(0.86, 0.73))
        guard try digest(unwrap(canvas.flattened(), "Missing cancelled lens raster")) == movedDigest else { throw failure("Escape committed a lens drag") }
        try canvasClick(canvas, movedLensCenter)
        let controls = ["annotation.magnifierShape", "annotation.magnifierScale", "annotation.magnifierConnector", "annotation.magnifierSmooth", "annotation.magnifierShadow", "annotation.magnifierShowsAnnotations"]
        try await evidence(editor, name: "ui-annotation-magnifier-source-lens.png", controls: controls, directory: directory)

        // Deliberately add opaque redaction AFTER creating/moving the lens. The
        // existing lens must not expose those pixels when ordinary marks are hidden.
        let source = sourceMoved.magnifierSourceRect
        try choose(.redact, editor)
        try drag(canvas, from: CGPoint(x: source.midX - source.width * 0.18, y: source.midY - source.height * 0.15),
                 to: CGPoint(x: source.midX + source.width * 0.18, y: source.midY + source.height * 0.15))
        let shown = try unwrap(canvas.flattened(), "Missing redacted magnifier")
        guard try pixel(shown, center(source)) == [0, 0, 0, 255],
              try pixel(shown, movedLensCenter) == [0, 0, 0, 255] else { throw failure("Later redaction leaked through the existing lens") }
        try choose(.select, editor); try canvasClick(canvas, movedLensCenter)
        try click("annotation.magnifierShowsAnnotations", editor)
        let hidden = try unwrap(canvas.flattened(), "Missing hidden-annotation lens")
        guard canvas.selectedAnnotation?.tool == .magnifier,
              canvas.selectedAnnotation?.magnifierShowsAnnotations == false,
              try pixel(hidden, center(source)) == [0, 0, 0, 255],
              try pixel(hidden, movedLensCenter) == [0, 0, 0, 255] else {
            throw failure("Hiding ordinary annotations exposed redacted pixels")
        }
        let stripeInSource = p(0.23, 0.46)
        let stripeInLens = CGPoint(x: sourceMoved.localBounds.minX + (stripeInSource.x - source.minX) * 2,
                                   y: sourceMoved.localBounds.minY + (stripeInSource.y - source.minY) * 2)
        guard try pixel(shown, stripeInLens) != pixel(hidden, stripeInLens) else {
            throw failure("The includes-annotations toggle did not change ordinary ink inside the lens")
        }
        let safeDigest = try digest(hidden)
        try commandUndo(canvas); try commandUndo(canvas, redo: true)
        guard try digest(unwrap(canvas.flattened(), "Missing privacy redo")) == safeDigest else { throw failure("Magnifier privacy toggle redo changed export pixels") }
        // Reselect after undo/redo so the screenshot contains the actual lens palette.
        try canvasClick(canvas, movedLensCenter)
        try await evidence(editor, name: "ui-annotation-magnifier-redaction-safe.png", controls: controls, directory: directory)
        return ["nativeOverflowMenuAndSourceGesture": true, "nativePaletteOptions": true,
                "independentSourceAndLensDrag": true, "escapePreservesRedo": true,
                "cancelledLensDragPreservesPixels": true, "redactionAddedAfterLensStaysOpaque": true,
                "hidingOrdinaryMarksKeepsRedactionOpaque": true, "ordinaryInkToggleChangesLens": true,
                "privacyToggleUndoRedoPixelIdentical": true]
    }

    private static func evidence(_ editor: ImageEditorController, name: String, controls: [String], directory: URL) async throws {
        try await settle(editor)
        let view = try unwrap(editor.window?.contentView, "Missing content view for \(name)")
        guard editor.contextualPaletteVisible, view.bounds.contains(editor.contextualPaletteFrame),
              view.bounds.contains(editor.floatingToolbarFrame),
              !editor.contextualPaletteFrame.intersects(editor.floatingToolbarFrame) else {
            throw failure("Native palette is clipped or overlaps the toolbar for \(name)")
        }
        for id in controls {
            let widget: NSControl = try control(id, editor)
            guard widget.isEnabled, !widget.isHiddenOrHasHiddenAncestor, widget.target != nil, widget.action != nil else {
                throw failure("Native palette control \(id) is not reachable for \(name)")
            }
        }
        // An explicit 1× cache target bounds evidence allocations even on Retina
        // displays. cacheDisplay reads this owned view, never the WindowServer.
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try checkSize(width: width, height: height)
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), "Cannot allocate 1x view evidence")
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try unwrap(bitmap.cgImage, "Empty native view evidence")
        guard image.width == width, image.height == height else { throw failure("Native snapshot exceeded its 1x dimensions") }
        try image.writePNG(to: directory.appendingPathComponent(name))
    }

    private static func settle(_ editor: ImageEditorController) async throws {
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
    }
    private static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    private static func control<T: NSView>(_ id: String, _ editor: ImageEditorController) throws -> T {
        try unwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == id } as? T, "Missing native control \(id)")
    }
    private static func click(_ id: String, _ editor: ImageEditorController) throws {
        let button: NSButton = try control(id, editor)
        guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { throw failure("Native button \(id) is not available") }
        button.performClick(nil)
    }
    private static func choose(_ tool: ImageEditorTool, _ editor: ImageEditorController) throws {
        if let button = descendants(editor.window?.contentView).first(where: { $0.identifier?.rawValue == "editor.tool.\(tool.rawValue)" }) as? NSButton,
           !button.isHiddenOrHasHiddenAncestor { try click("editor.tool.\(tool.rawValue)", editor) }
        else { try menuAction(title: tool.title, editor) }
        guard editor.annotationCanvas.tool == tool else { throw failure("Native tool action failed for \(tool.rawValue)") }
    }
    private static func menuAction(title: String, _ editor: ImageEditorController) throws {
        let more: NSPopUpButton = try control("editor.more", editor)
        guard more.isEnabled, !more.isHiddenOrHasHiddenAncestor,
              let menu = more.menu, let index = menu.items.firstIndex(where: { $0.title == title }),
              menu.items[index].target != nil, menu.items[index].action != nil else { throw failure("Missing native overflow action \(title)") }
        menu.performActionForItem(at: index)
    }
    private static func send(_ control: NSControl) throws {
        guard control.isEnabled, !control.isHiddenOrHasHiddenAncestor,
              control.action != nil, control.target != nil,
              control.sendAction(control.action, to: control.target) else { throw failure("Native control action was not accepted") }
    }
    private static func picker(_ id: String, index: Int, _ editor: ImageEditorController) throws {
        let widget: NSPopUpButton = try control(id, editor)
        guard widget.itemArray.indices.contains(index) else { throw failure("Invalid native picker index for \(id)") }
        widget.selectItem(at: index); try send(widget)
    }
    private static func picker(_ id: String, title: String, _ editor: ImageEditorController) throws {
        let widget: NSPopUpButton = try control(id, editor)
        guard widget.itemArray.contains(where: { $0.title == title }) else { throw failure("Missing native picker value \(id): \(title)") }
        widget.selectItem(withTitle: title); try send(widget)
    }
    private static func field(_ id: String, value: String, _ editor: ImageEditorController) throws {
        let widget: NSTextField = try control(id, editor); widget.stringValue = value; try send(widget)
    }
    private static func slider(_ id: String, value: Double, _ editor: ImageEditorController) throws {
        let widget: NSSlider = try control(id, editor); widget.doubleValue = value; try send(widget)
    }
    private static func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type,
            location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Cannot create native canvas input")
    }
    private static func key(_ canvas: ImageEditorCanvas, code: UInt16, value: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: value,
            charactersIgnoringModifiers: value, isARepeat: false, keyCode: code), "Cannot create native keyboard input")
    }
    private static func canvasClick(_ canvas: ImageEditorCanvas, _ point: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point))
    }
    private static func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start))
        for step in 1...4 {
            let t = CGFloat(step) / 4
            canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged,
                CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
        }
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }
    private static func cancelDrag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end))
        canvas.keyDown(with: try key(canvas, code: 53, value: "\u{1b}"))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }
    private static func commandUndo(_ canvas: ImageEditorCanvas, redo: Bool = false) throws {
        guard canvas.performKeyEquivalent(with: try key(canvas, code: 6, value: "z", flags: redo ? [.command, .shift] : .command)) else {
            throw failure("Canvas did not handle native undo/redo keyboard input")
        }
    }
    private static func point(_ canvas: ImageEditorCanvas, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(canvas.image.width) * x, y: CGFloat(canvas.image.height) * y)
    }
    private static func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    private static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool { close(a.origin, b.origin) && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01 }
    private static func checkSize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumPixels, height <= maximumPixels,
              width <= maximumPixels / height else { throw failure("Fixture raster exceeded its bounded pixel budget") }
    }
    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        try checkSize(width: width, height: height)
        return try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Cannot allocate bounded fixture raster")
    }
    private static func pixel(_ image: CGImage, _ point: CGPoint) throws -> [UInt8] {
        let context = try bitmap(width: 1, height: 1)
        context.translateBy(x: -floor(point.x), y: -floor(point.y)); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try unwrap(context.data, "Missing pixel data").assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }
    private static func digest(_ image: CGImage) throws -> String {
        let context = try bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = Data(bytes: try unwrap(context.data, "Missing digest pixels"), count: context.bytesPerRow * context.height)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func syntheticDesktop(size: CGSize, selection: CGRect) throws -> CGImage {
        let context = try bitmap(width: Int(size.width), height: Int(size.height))
        fill(context, CGRect(origin: .zero, size: size), CGColor(srgbRed: 0.09, green: 0.16, blue: 0.24, alpha: 1))
        text("PicShot  /  Annotation Studio", at: CGPoint(x: 28, y: size.height - 36), size: 18, bold: true, context: context)
        text("ORIGINAL SYNTHETIC DESKTOP  •  1× EVIDENCE  •  NO SCREEN PIXELS CAPTURED", at: CGPoint(x: 28, y: 28), size: 11, context: context)
        let paper = CGRect(x: selection.minX, y: size.height - selection.maxY, width: selection.width, height: selection.height)
        fill(context, paper, CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1))
        context.saveGState(); context.translateBy(x: paper.minX, y: paper.minY)
        text("Make the detail unmistakable.", at: CGPoint(x: 30, y: paper.height - 53), size: min(30, paper.width / 25), bold: true,
             color: CGColor(srgbRed: 0.10, green: 0.17, blue: 0.26, alpha: 1), context: context)
        text("Erase ink. Focus attention. Mark ownership. Magnify safely.", at: CGPoint(x: 30, y: paper.height - 82), size: 13,
             color: CGColor(srgbRed: 0.33, green: 0.40, blue: 0.49, alpha: 1), context: context)
        let left = CGRect(x: paper.width * 0.08, y: paper.height * 0.14, width: paper.width * 0.32, height: paper.height * 0.49)
        fill(context, left, CGColor(srgbRed: 0.12, green: 0.58, blue: 0.66, alpha: 1))
        for row in 0..<6 {
            for column in 0..<8 where (row + column) % 2 == 0 {
                fill(context, CGRect(x: left.minX + CGFloat(column) * left.width / 8, y: left.minY + CGFloat(row) * left.height / 6,
                                     width: left.width / 8, height: left.height / 6), CGColor(srgbRed: 0.31, green: 0.77, blue: 0.78, alpha: 1))
            }
        }
        let right = CGRect(x: paper.width * 0.48, y: paper.height * 0.16, width: paper.width * 0.44, height: paper.height * 0.45)
        fill(context, right, CGColor(srgbRed: 0.90, green: 0.91, blue: 0.96, alpha: 1))
        text("Original sample", at: CGPoint(x: right.minX + 20, y: right.maxY - 35), size: 19, bold: true,
             color: CGColor(srgbRed: 0.24, green: 0.27, blue: 0.40, alpha: 1), context: context)
        for index in 0..<4 {
            fill(context, CGRect(x: right.minX + 20, y: right.minY + 22 + CGFloat(index) * 23, width: right.width * (0.40 + CGFloat(index) * 0.10), height: 7),
                 CGColor(srgbRed: 0.54, green: 0.58, blue: 0.72, alpha: 1))
        }
        context.restoreGState()
        return try unwrap(context.makeImage(), "Cannot materialize original synthetic desktop")
    }
    private static func fill(_ context: CGContext, _ rect: CGRect, _ color: CGColor) { context.setFillColor(color); context.fill(rect) }
    private static func text(_ value: String, at point: CGPoint, size: CGFloat, bold: Bool = false,
                             color: CGColor = CGColor(gray: 1, alpha: 1), context: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        context.textMatrix = .identity; context.textPosition = point; CTLineDraw(line, context)
    }
    private static func writeReport(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(reportName), options: .atomic)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Native annotation effects preview: \(message)") }
}
