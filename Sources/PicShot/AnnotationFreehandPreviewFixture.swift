import AppKit
import CryptoKit
import ImageIO

/// Opt-in installed-app checks on original synthetic pixels and owned native views.
/// No screen capture, TCC, external app input, clipboard, network or defaults writes.
@MainActor
enum AnnotationFreehandPreviewFixture {
    private static let maximumPixels = 4_000_000
    private static let reportName = "annotation-freehand-preview.json"

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        var report: [String: Any] = [
            "status": "running", "syntheticDesktop": true,
            "scope": "Native palette controls, owned canvas NSEvents, shared preview/export raster and PNG round trip",
            "screenCaptureAttempted": false, "networkAttempted": false, "preferencesWritten": false,
            "pasteboardAccessed": false, "maximumConcurrentOwnedEditors": 1,
            "maximumFixtureRasterPixels": maximumPixels, "maximumGesturePoints": ImageAnnotation.maximumGesturePoints,
            "limitations": ["Synthetic 1x pixels; no live capture or physical input routing", "Owned references checked on close; no process-memory or leak claim"]
        ]
        var completed: [String] = [], files: [String] = []
        do {
            guard let screen = NSScreen.main, let displayID = screen.displayID else { throw failure("No WindowServer display") }
            let size = CGSize(width: min(1_180, floor(screen.frame.width)), height: min(760, floor(screen.frame.height)))
            guard size.width >= 760, size.height >= 600 else { throw failure("A 760 by 600 point display is needed") }
            let source = try syntheticSource(size), original = try digest(source)
            let frame = CGRect(origin: screen.frame.origin, size: size)
            let selection = CGRect(x: 40, y: 90, width: size.width - 80, height: size.height - 240)
            let captured = try CapturedImage.frozenRegion(image: source, displayID: displayID, displayFrame: frame,
                selection: selection, capturedAt: Date(timeIntervalSince1970: 1_704_164_645))
            report["desktopPixelWidth"] = source.width; report["desktopPixelHeight"] = source.height
            report["resultPixelWidth"] = captured.image.width; report["resultPixelHeight"] = captured.image.height
            NSApp.appearance = NSAppearance(named: .aqua)
            report["pencil"] = try await withEditor(captured, name: "pencil", directory: evidenceDirectory) { editor in
                try await verifyPencil(editor, directory: evidenceDirectory)
            }
            completed.append("pencil"); files += ["ui-annotation-pencil-light.png", "annotation-pencil-result.png"]
            NSApp.appearance = NSAppearance(named: .darkAqua)
            report["highlighter"] = try await withEditor(captured, name: "highlighter", directory: evidenceDirectory) { editor in
                try await verifyHighlighter(editor, directory: evidenceDirectory)
            }
            completed.append("highlighter"); files += ["ui-annotation-highlighter-dark.png", "annotation-highlighter-result.png"]
            report["pointLimit"] = try await withEditor(captured, name: "freehand-limit", directory: evidenceDirectory) { editor in
                try choose(.freehand, editor)
                let canvas = editor.annotationCanvas, start = CGPoint(x: 20, y: 20)
                canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start))
                for index in 0..<(ImageAnnotation.maximumGesturePoints * 2) {
                    let point = CGPoint(x: index.isMultiple(of: 2) ? 40 : 90, y: index.isMultiple(of: 3) ? 30 : 80)
                    canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, point))
                    guard let draft = canvas.pendingFreehand, draft.points.count <= ImageAnnotation.maximumGesturePoints,
                          draft.freehandCorners.count <= ImageAnnotation.maximumGesturePoints else { throw failure("Native gesture exceeded its vector budget") }
                }
                let end = CGPoint(x: 160, y: 100)
                canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
                guard let mark = canvas.annotations.first, mark.freehandWasSimplified, mark.points.first == start, mark.points.last == end else {
                    throw failure("Bounded stroke lost an endpoint or did not disclose simplification")
                }
                let status: NSTextField = try control("editor.dimensions", editor)
                guard !status.isHiddenOrHasHiddenAncestor, status.stringValue.contains("2048") else {
                    throw failure("Long-stroke simplification was not visible in the status strip")
                }
                try undo(canvas); guard canvas.annotations.isEmpty else { throw failure("Long stroke used multiple history states") }
                try undo(canvas, redo: true)
                return ["boundedDuringGesture": true, "endpointsPreserved": true, "simplificationDisclosed": true,
                        "singleUndoState": true, "retainedPointCount": mark.points.count]
            }
            completed.append("pointLimit"); files.append("annotation-freehand-limit-result.png")
            NSApp.appearance = NSAppearance(named: .aqua)
            var edges: [[String: Any]] = []
            for (name, x, y) in [("top-left", CGFloat(8), CGFloat(8)), ("top-right", size.width - 188, CGFloat(8)),
                                 ("bottom-left", CGFloat(8), size.height - 128), ("bottom-right", size.width - 188, size.height - 128)] {
                let edge = try CapturedImage.frozenRegion(image: source, displayID: displayID, displayFrame: frame,
                    selection: CGRect(x: x, y: y, width: 180, height: 120))
                let filename = "ui-annotation-freehand-edge-\(name).png"
                var result = try await withEditor(edge, name: "freehand-edge-\(name)", directory: evidenceDirectory) { editor in
                    let originalFrame = editor.annotationCanvas.frame, originalSelection = editor.editorSelectionFrame
                    try choose(.highlighter, editor)
                    try picker("annotation.highlighterMode", title: AnnotationHighlighterMode.freehand.title, editor)
                    try picker("annotation.lineWidth", title: "16", editor)
                    try stroke(editor.annotationCanvas, [CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 80), CGPoint(x: 140, y: 40)])
                    guard editor.annotationCanvas.frame == originalFrame, editor.editorSelectionFrame == originalSelection else { throw failure("Palette moved the frozen image") }
                    try await snapshot(editor, filename: filename, controls: ["annotation.highlighterMode", "annotation.highlighterBlend", "annotation.pencilSmoothing", "annotation.pencilConstraint"], directory: evidenceDirectory)
                    return ["frozenImageAnchored": true, "paletteInsideWorkspace": true, "toolbarPaletteDoNotOverlap": true]
                }
                result["edge"] = name; edges.append(result)
                files += [filename, "annotation-freehand-edge-\(name)-result.png"]
            }
            completed.append("edgePlacement"); report["edges"] = edges
            guard try digest(source) == original else { throw failure("Original pixels changed") }
            report["status"] = "passed"; report["originalRasterPreserved"] = true; report["allOwnedEditorsClosed"] = true
            report["completedChecks"] = completed; report["files"] = files + [reportName]
            try write(report, directory: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription; report["completedChecks"] = completed
            report["ownedEditorCleanupAttempted"] = true; try? write(report, directory: evidenceDirectory); throw error
        }
    }

    private static func verifyPencil(_ editor: ImageEditorController, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas, original = try digest(canvas.image)
        try choose(.freehand, editor); try picker("annotation.lineWidth", title: "6", editor)
        for mode in AnnotationPencilConstraint.allCases {
            try picker("annotation.pencilConstraint", title: mode.title, editor)
            guard canvas.style.freehandConstraint == mode else { throw failure("An angle option was unreachable") }
        }
        try picker("annotation.pencilConstraint", title: AnnotationPencilConstraint.degrees45.title, editor)
        let points = [CGPoint(x: 20, y: 40), CGPoint(x: 70, y: 100), CGPoint(x: 130, y: 50), CGPoint(x: 190, y: 110)]
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, points[0]))
        for point in points.dropFirst() { canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, point)) }
        guard let draft = canvas.pendingFreehand, draft.freehandSmoothing, canvas.annotations.isEmpty,
              try digest(raster(canvas)) == original else { throw failure("Pencil draft was not smoothed or leaked into history/export") }
        let draftDigest = try digest(unwrap(ImageEditorRenderer.render(image: canvas.image, annotations: [draft]), "Cannot render pencil draft"))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, points.last!))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, points.last!))
        guard canvas.annotations.count == 1, try digest(raster(canvas)) == draftDigest else { throw failure("Release duplicated or changed pencil preview pixels") }
        let committed = try digest(raster(canvas))
        for _ in 0..<2 {
            try undo(canvas); guard canvas.annotations.isEmpty else { throw failure("Pencil used multiple history entries") }
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, points[0]))
            canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, points[1]))
            canvas.keyDown(with: try key(canvas, "\u{1b}", code: 53))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, points[1]))
            guard canvas.pendingFreehand == nil, !editor.isClosed else { throw failure("Escape did not cancel only the stroke") }
            try undo(canvas, redo: true)
            guard try digest(raster(canvas)) == committed else { throw failure("Cancel destroyed redo pixels") }
        }
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, points[0]))
        try choose(.highlighter, editor); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, points[1]))
        guard canvas.annotations.count == 1, canvas.pendingFreehand == nil else { throw failure("Tool switch committed a stray stroke") }
        try choose(.freehand, editor)
        let start = CGPoint(x: 240, y: 40), corner = CGPoint(x: 270, y: 70), requested = CGPoint(x: 330, y: 79)
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, corner))
        canvas.flagsChanged(with: try flags(canvas, .shift))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, requested, flags: .shift))
        guard let straight = canvas.pendingFreehand, let end = straight.points.last, abs(end.y - corner.y) < 0.0001,
              straight.points.count == 3 else { throw failure("Mid-stroke Shift was not one snapped straight section") }
        canvas.flagsChanged(with: try flags(canvas, []))
        let released = CGPoint(x: 370, y: 100)
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, released))
        guard canvas.annotations.last?.points.last == released else { throw failure("Mouse-up endpoint was lost") }
        try stroke(canvas, [CGPoint(x: 220, y: 160)])
        try stroke(canvas, [CGPoint(x: 240, y: 160), CGPoint(x: 240.1, y: 160.1)])
        guard canvas.annotations.count == 4,
              try pixel(raster(canvas), CGPoint(x: 220, y: 160)) != pixel(canvas.image, CGPoint(x: 220, y: 160)),
              try pixel(raster(canvas), CGPoint(x: 240, y: 160)) != pixel(canvas.image, CGPoint(x: 240, y: 160)) else {
            throw failure("Click/tiny pencil marks disappeared")
        }
        try choose(.select, editor); try clickCanvas(canvas, points[0])
        let beforeStyle = try digest(raster(canvas)); try click("annotation.pencilSmoothing", editor)
        let afterStyle = try digest(raster(canvas))
        guard beforeStyle != afterStyle else { throw failure("Selected smoothing control did not edit pixels") }
        try undo(canvas); guard try digest(raster(canvas)) == beforeStyle else { throw failure("Smoothing undo changed pixels") }
        try undo(canvas, redo: true); guard try digest(raster(canvas)) == afterStyle else { throw failure("Smoothing redo changed pixels") }
        try choose(.freehand, editor)
        try await snapshot(editor, filename: "ui-annotation-pencil-light.png", controls: ["annotation.pencilSmoothing", "annotation.pencilConstraint", "annotation.lineWidth"], directory: directory)
        return ["nativeControlsReachable": true, "previewMatchesCommittedPixels": true, "draftExcludedFromExport": true,
                "repeatReleaseNoDuplicate": true, "twoUndoRedoCyclesPixelIdentical": true, "escapePreservesRedo": true,
                "toolSwitchDiscardsDraft": true, "midStrokeShiftStraight": true, "mouseUpEndpointPreserved": true,
                "singlePointAndTinyMarksVisible": true, "selectedSmoothingUndoRedoExact": true]
    }

    private static func verifyHighlighter(_ editor: ImageEditorController, directory: URL) async throws -> [String: Any] {
        let canvas = editor.annotationCanvas
        try choose(.highlighter, editor); try picker("annotation.highlighterMode", title: AnnotationHighlighterMode.freehand.title, editor)
        try picker("annotation.highlighterBlend", title: AnnotationHighlighterBlend.multiply.title, editor)
        try picker("annotation.lineWidth", title: "24", editor); try click("annotation.swatch.2", editor)
        let y: CGFloat = 130, end = CGFloat(canvas.image.width) - 40
        try stroke(canvas, [CGPoint(x: 40, y: y), CGPoint(x: end, y: y), CGPoint(x: 40, y: y)])
        guard let mark = canvas.annotations.first, mark.highlighterMode == .freehand, mark.highlighterBlend == .multiply else { throw failure("Highlighter modes were not applied") }
        let multiplyImage = try raster(canvas), multiply = try digest(multiplyImage)
        try choose(.select, editor); try clickCanvas(canvas, CGPoint(x: 70, y: y))
        let selectedBefore = canvas.selectedAnnotation
        let modelBefore = canvas.annotations.first { $0.id == mark.id }
        try picker("annotation.highlighterBlend", title: AnnotationHighlighterBlend.translucent.title, editor)
        let selectedAfter = canvas.selectedAnnotation
        let modelAfter = canvas.annotations.first { $0.id == mark.id }
        let translucentImage = try raster(canvas), translucent = try digest(translucentImage)
        let selectionMatches = selectedBefore?.id == mark.id && selectedAfter?.id == mark.id
        let modelModesMatch = modelBefore?.highlighterBlend == .multiply && modelAfter?.highlighterBlend == .translucent
            && modelBefore?.highlighterMode == .freehand && modelAfter?.highlighterMode == .freehand
        if multiply == translucent || !selectionMatches || !modelModesMatch {
            try writeHighlighterDiagnostic(canvas, expected: mark, before: modelBefore, after: modelAfter,
                selectedBefore: selectedBefore, selectedAfter: selectedAfter, multiply: multiplyImage,
                translucent: translucentImage, y: y, directory: directory)
        }
        // Keep the original acceptance condition and failure. Diagnostics do not turn
        // an unchanged raster into a successful blend check or alter production drawing.
        guard multiply != translucent else { throw failure("Blend control did not change dark background pixels") }
        guard selectionMatches, modelModesMatch else { throw failure("Blend control did not edit the expected selected highlighter model") }
        try undo(canvas); guard try digest(raster(canvas)) == multiply else { throw failure("Blend undo changed pixels") }
        try undo(canvas, redo: true); guard try digest(raster(canvas)) == translucent else { throw failure("Blend redo changed pixels") }
        try choose(.highlighter, editor)
        let width: NSPopUpButton = try control("annotation.lineWidth", editor)
        let smoothing: NSButton = try control("annotation.pencilSmoothing", editor)
        try picker("annotation.highlighterMode", title: AnnotationHighlighterMode.rectangle.title, editor)
        guard width.isHiddenOrHasHiddenAncestor, smoothing.isHiddenOrHasHiddenAncestor else { throw failure("Rectangle mode exposed irrelevant stroke controls") }
        try stroke(canvas, [CGPoint(x: 30, y: 190), CGPoint(x: 260, y: 230)])
        guard canvas.annotations.last?.highlighterMode == .rectangle else { throw failure("Rectangular highlighter was not preserved") }
        try picker("annotation.highlighterMode", title: AnnotationHighlighterMode.freehand.title, editor)
        try await snapshot(editor, filename: "ui-annotation-highlighter-dark.png", controls: ["annotation.highlighterMode", "annotation.highlighterBlend", "annotation.pencilSmoothing", "annotation.pencilConstraint"], directory: directory)
        return ["nativeControlsReachable": true, "freehandAndRectangleReachable": true, "blendChangesDarkPixels": true,
                "selectedBlendUndoRedoExact": true, "rectangleHidesStrokeOnlyControls": true]
    }

    /// Failure-only, bounded evidence: two existing <=4MP rasters, 8 pixel probes,
    /// <=16 model samples and <=32 path elements. This is fixture instrumentation.
    private static func writeHighlighterDiagnostic(_ canvas: ImageEditorCanvas, expected: ImageAnnotation,
        before: ImageAnnotation?, after: ImageAnnotation?, selectedBefore: ImageAnnotation?, selectedAfter: ImageAnnotation?,
        multiply: CGImage, translucent: CGImage, y: CGFloat, directory: URL) throws {
        func geometry(_ annotation: ImageAnnotation?) -> [String: Any] {
            guard let annotation else { return ["missing": true] }
            let path = annotation.freehandPath, ink = annotation.freehandInkPath()
            var elements: [[String: Any]] = [], elementCount = 0
            path.applyWithBlock { pointer in
                let element = pointer.pointee
                elementCount += 1
                guard elements.count < 32 else { return }
                let count: Int
                switch element.type {
                case .moveToPoint, .addLineToPoint: count = 1
                case .addQuadCurveToPoint: count = 2
                case .addCurveToPoint: count = 3
                case .closeSubpath: count = 0
                @unknown default: count = 0
                }
                elements.append(["type": Int(element.type.rawValue),
                                 "points": (0..<count).map { NSStringFromPoint(element.points[$0]) }])
            }
            return ["id": annotation.id.uuidString, "tool": annotation.tool.rawValue,
                    "highlighterMode": annotation.highlighterMode.rawValue, "blend": annotation.highlighterBlend.rawValue,
                    "smoothing": annotation.freehandSmoothing, "constraintDegrees": annotation.freehandConstraint.rawValue,
                    "pointCount": annotation.points.count, "points": Array(annotation.points.prefix(16)).map(NSStringFromPoint),
                    "cornerCount": annotation.freehandCorners.count, "corners": Array(annotation.freehandCorners.prefix(16)),
                    "lineWidth": Double(annotation.lineWidth), "effectiveWidth": Double(annotation.effectiveFreehandWidth),
                    "opacity": Double(annotation.opacity), "colorComponents": (annotation.color.components ?? []).map { Double($0) },
                    "rotation": Double(annotation.rotation), "localBounds": NSStringFromRect(annotation.localBounds),
                    "strokeBounds": NSStringFromRect(path.boundingBox), "strokeBoundsOfPath": NSStringFromRect(path.boundingBoxOfPath),
                    "inkBounds": NSStringFromRect(ink.boundingBoxOfPath), "inkIsEmpty": ink.isEmpty,
                    "pathElementCount": elementCount, "pathElements": elements]
        }
        let width = CGFloat(canvas.image.width)
        let locations: [(String, CGPoint)] = [
            ("selection-white", CGPoint(x: 70, y: y)),
            ("white-near-boundary", CGPoint(x: width / 2 - 16, y: y)),
            ("dark-near-boundary", CGPoint(x: width / 2 + 8, y: y)),
            ("dark-quarter-stroke", CGPoint(x: width * 0.625, y: y)),
            ("dark-smoothed-turn", CGPoint(x: width * 0.75 - 20, y: y)),
            ("dark-original-turn", CGPoint(x: width - 40, y: y)),
            ("white-off-stroke", CGPoint(x: 70, y: y + 20)),
            ("dark-off-stroke", CGPoint(x: width * 0.625, y: y + 20))
        ]
        let samples: [[String: Any]] = try locations.map { name, point in
            let beforePoint = before.map { point.applying($0.transform.inverted()) } ?? point
            let afterPoint = after.map { point.applying($0.transform.inverted()) } ?? point
            return ["name": name, "point": NSStringFromPoint(point),
                    "sourceRGBA": try pixel(canvas.image, point), "multiplyRGBA": try pixel(multiply, point),
                    "translucentRGBA": try pixel(translucent, point),
                    "beforeInkContains": before?.freehandInkPath().contains(beforePoint) ?? false,
                    "afterInkContains": after?.freehandInkPath().contains(afterPoint) ?? false]
        }
        let beforeName = "highlighter-blend-before.png", afterName = "highlighter-blend-after.png"
        try checkSize(multiply.width, multiply.height); try checkSize(translucent.width, translucent.height)
        try multiply.writePNG(to: directory.appendingPathComponent(beforeName))
        try translucent.writePNG(to: directory.appendingPathComponent(afterName))
        let report: [String: Any] = [
            "schemaVersion": 1, "status": "failed", "diagnosticOnly": true,
            "expectedID": expected.id.uuidString, "selectedBeforeID": selectedBefore?.id.uuidString ?? "none",
            "selectedAfterID": selectedAfter?.id.uuidString ?? "none", "activeTool": canvas.tool.rawValue,
            "annotationCount": canvas.annotations.count, "width": canvas.image.width, "height": canvas.image.height,
            "sourceSHA256": try digest(canvas.image), "multiplySHA256": try digest(multiply), "translucentSHA256": try digest(translucent),
            "before": geometry(before), "after": geometry(after), "selectedBefore": geometry(selectedBefore), "selectedAfter": geometry(selectedAfter),
            "samples": samples, "files": [beforeName, afterName], "maximumRasterPixels": maximumPixels,
            "scope": "Original synthetic highlighter fixture; diagnostic probes do not change model or rendering"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("highlighter-blend-diagnostic.json"), options: .atomic)
    }

    private static func withEditor(_ captured: CapturedImage, name: String, directory: URL,
        body: (ImageEditorController) async throws -> [String: Any]) async throws -> [String: Any] {
        var saves = 0, unexpected = 0, closes = 0
        var savedDigest: String?, saveError: Error?
        let url = directory.appendingPathComponent("annotation-\(name)-result.png")
        let editor = ImageEditorController(image: captured.image, presentation: captured.presentation,
            onSave: { image in
                saves += 1
                do { try image.writePNG(to: url); savedDigest = try digest(image) } catch { saveError = error }
            }, onPin: { _ in unexpected += 1 }, onOCR: { _ in unexpected += 1 }, copyAction: { _ in unexpected += 1 })
        editor.onClose = { closes += 1 }
        defer { editor.close() }
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil); try await settle(editor)
        let base = try digest(captured.image)
        guard editor.annotationCanvas.zoom == 1, editor.annotationCanvas.displayScaleY == 1 else { throw failure("Lost 1x native placement") }
        var result = try await body(editor)
        let finalDigest = try digest(raster(editor.annotationCanvas))
        try menuAction("保存到历史", editor)
        if let saveError { throw saveError }
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "Cannot reopen output PNG")
        let decoded = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "Cannot decode output PNG")
        guard saves == 1, savedDigest == finalDigest, try digest(decoded) == finalDigest, unexpected == 0 else { throw failure("Saved/exported appearance did not match the rendered document") }
        try choose(.freehand, editor)
        editor.annotationCanvas.mouseDown(with: try mouse(editor.annotationCanvas, .leftMouseDown, CGPoint(x: 10, y: 10)))
        try click("editor.cancel", editor)
        guard editor.isClosed, editor.window?.contentView == nil, editor.window?.delegate == nil, editor.window?.isVisible != true,
              editor.captureBoundaryWorkspace.frozenImage == nil, editor.annotationCanvas.pendingFreehand == nil,
              editor.annotationCanvas.retainedPresentationRaster == nil, closes == 1, saves == 1, unexpected == 0,
              try digest(captured.image) == base else { throw failure("Close retained a draft/window/cache or changed source pixels") }
        result["nativeSaveCallbackCount"] = saves; result["flattenedSHA256"] = finalDigest; result["resultFile"] = url.lastPathComponent
        result["pngRoundTripExact"] = true; result["nativeCancelPreservedInput"] = true
        result["ownedWindowDetachedOnClose"] = true; result["pendingStrokeReleasedOnClose"] = true; result["presentationCacheReleasedOnClose"] = true
        return result
    }

    private static func snapshot(_ editor: ImageEditorController, filename: String, controls: [String], directory: URL) async throws {
        try await settle(editor)
        let view = try unwrap(editor.window?.contentView, "Missing content view")
        guard editor.contextualPaletteVisible, view.bounds.contains(editor.contextualPaletteFrame), view.bounds.contains(editor.floatingToolbarFrame),
              !editor.contextualPaletteFrame.intersects(editor.floatingToolbarFrame) else { throw failure("Compact palette/toolbar is clipped or overlaps") }
        for id in controls {
            let widget: NSControl = try control(id, editor)
            guard widget.isEnabled, !widget.isHiddenOrHasHiddenAncestor, widget.target != nil, widget.action != nil else { throw failure("Unreachable native control \(id)") }
        }
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try checkSize(width, height)
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Cannot allocate native snapshot")
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        try unwrap(bitmap.cgImage, "Missing native pixels").writePNG(to: directory.appendingPathComponent(filename))
    }
    private static func settle(_ editor: ImageEditorController) async throws {
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 40_000_000)
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
    }
    private static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    private static func control<T: NSView>(_ id: String, _ editor: ImageEditorController) throws -> T {
        try unwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == id } as? T, "Missing control \(id)")
    }
    private static func click(_ id: String, _ editor: ImageEditorController) throws {
        let button: NSButton = try control(id, editor)
        guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { throw failure("Unavailable button \(id)") }
        button.performClick(nil)
    }
    private static func choose(_ tool: ImageEditorTool, _ editor: ImageEditorController) throws {
        if let button = descendants(editor.window?.contentView).first(where: { $0.identifier?.rawValue == "editor.tool.\(tool.rawValue)" }) as? NSButton,
           !button.isHiddenOrHasHiddenAncestor { button.performClick(nil) }
        else { try menuAction(tool.title, editor) }
        guard editor.annotationCanvas.tool == tool else { throw failure("Tool selection failed") }
    }
    private static func menuAction(_ title: String, _ editor: ImageEditorController) throws {
        let more: NSPopUpButton = try control("editor.more", editor)
        guard let menu = more.menu, let index = menu.items.firstIndex(where: { $0.title == title }) else { throw failure("Missing menu action \(title)") }
        menu.performActionForItem(at: index)
    }
    private static func picker(_ id: String, title: String, _ editor: ImageEditorController) throws {
        let widget: NSPopUpButton = try control(id, editor)
        guard widget.isEnabled, !widget.isHiddenOrHasHiddenAncestor, widget.item(withTitle: title) != nil else { throw failure("Unavailable picker \(id)") }
        widget.selectItem(withTitle: title)
        guard widget.sendAction(widget.action, to: widget.target) else { throw failure("Picker rejected action") }
    }
    private static func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Cannot create mouse event")
    }
    private static func key(_ canvas: ImageEditorCanvas, _ value: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: value, charactersIgnoringModifiers: value,
            isARepeat: false, keyCode: code), "Cannot create key event")
    }
    private static func flags(_ canvas: ImageEditorCanvas, _ value: NSEvent.ModifierFlags) throws -> NSEvent {
        try unwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: value, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56), "Cannot create modifier event")
    }
    private static func stroke(_ canvas: ImageEditorCanvas, _ points: [CGPoint]) throws {
        guard let first = points.first, let last = points.last else { throw failure("Empty fixture stroke") }
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, first))
        for point in points.dropFirst() { canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, point)) }
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, last))
    }
    private static func clickCanvas(_ canvas: ImageEditorCanvas, _ point: CGPoint) throws { try stroke(canvas, [point]) }
    private static func undo(_ canvas: ImageEditorCanvas, redo: Bool = false) throws {
        guard canvas.performKeyEquivalent(with: try key(canvas, "z", code: 6, modifiers: redo ? [.command, .shift] : .command)) else { throw failure("Undo/redo key was not handled") }
    }
    private static func raster(_ canvas: ImageEditorCanvas) throws -> CGImage { try unwrap(canvas.flattened(), "Cannot flatten canvas") }
    private static func checkSize(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, height <= maximumPixels, width <= maximumPixels / height else { throw failure("Raster budget exceeded") }
    }
    private static func bitmap(_ width: Int, _ height: Int) throws -> CGContext {
        try checkSize(width, height)
        return try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Cannot allocate bitmap")
    }
    private static func syntheticSource(_ size: CGSize) throws -> CGImage {
        let context = try bitmap(Int(size.width), Int(size.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(gray: 0.07, alpha: 1)); context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        // Original contrasting bars stand in for small text; no copyrighted screenshot.
        for index in 0..<12 {
            let x = 90 + CGFloat(index) * 18
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: x, y: 245, width: 10, height: 12))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: x + size.width / 2, y: 245, width: 10, height: 12))
        }
        return try unwrap(context.makeImage(), "Cannot create source")
    }
    private static func pixel(_ image: CGImage, _ point: CGPoint) throws -> [UInt8] {
        let context = try bitmap(1, 1); context.translateBy(x: -floor(point.x), y: -floor(point.y))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try unwrap(context.data, "Missing pixel bytes").assumingMemoryBound(to: UInt8.self), count: 4))
    }
    private static func digest(_ image: CGImage) throws -> String {
        let context = try bitmap(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = Data(bytes: try unwrap(context.data, "Missing image bytes"), count: context.bytesPerRow * context.height)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(reportName), options: .atomic)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Native freehand preview: \(message)") }
}
