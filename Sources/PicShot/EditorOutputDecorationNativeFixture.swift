import AppKit
import CryptoKit
import ImageIO

/// Explicit native acceptance entry point. Authored synthetic pixels only;
/// never screen capture, personal files, clipboard, user defaults or networking.
/// Screenshots rasterize this fixture's own editor and actual NSPopover views.
@MainActor
enum EditorOutputDecorationNativeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        guard evidenceDirectory.isFileURL else { throw failure("Evidence directory must be local") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let service = EditorOutputProjection.shared
        guard !service.isBusy, !service.queue.isSuspended else { throw failure("A prior output projection is still active or suspended") }
        try await waitFor { service.queue.operationCount == 0 }
        let started = service.startedCount, completed = service.completedCount
        let sampler = GIFResourceMemorySampler(); defer { sampler.stop() }
        let baseline = GIFResourceMemoryReading.current()
        guard baseline.residentBytes != nil, baseline.physicalFootprintBytes != nil else {
            throw failure("Native process memory observation is unavailable")
        }
        var report: [String: Any] = ["status": "running", "captureStarted": false, "networkAttempted": false,
            "clipboardTouched": false, "userFilesRead": false, "syntheticSource": true,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "scope": "Native editor/palette actions, metadata undo/redo, real PNG bytes and serial output ownership",
            "memoryScope": "Bounded 640x400 repeated UI/output workload; process RSS/footprint observations only; no plateau/no-leak or 60MP runtime claim",
            "baseline": try object(baseline), "cases": [[String: Any]]()]
        do {
            var cases: [[String: Any]] = [], settled: [[String: Any]] = []
            for (name, dark, edge) in [("light", false, false), ("dark", true, false), ("edge-light", false, true), ("edge-dark", true, true)] {
                cases.append(try await runCase(name: name, dark: dark, edge: edge, directory: evidenceDirectory))
                sampler.sample()
                let reading = GIFResourceMemoryReading.current()
                guard reading.residentBytes != nil, reading.physicalFootprintBytes != nil else { throw failure("Missing repeated native memory observation") }
                settled.append(try object(reading))
                report["cases"] = cases; try write(report, to: evidenceDirectory)
            }
            report["cancellation"] = try await cancellationCase()
            try await waitFor { !service.isBusy && service.queue.operationCount == 0 }
            sampler.stop()
            guard service.reservedBytes == 0, service.activeTicket == nil,
                  service.startedCount - started == service.completedCount - completed else {
                throw failure("Projection ownership did not drain")
            }
            report["status"] = "passed"
            report["projectionJobsStarted"] = service.startedCount - started
            report["projectionJobsCompleted"] = service.completedCount - completed
            report["activeProjectionJobsAfter"] = service.isBusy ? 1 : 0
            report["projectionReservedBytesAfter"] = service.reservedBytes
            report["queuedOperationsAfter"] = service.queue.operationCount
            report["settledProcessSamples"] = settled
            report["sampledProcessMemory"] = try object(sampler.snapshot())
            report["finalProcessMemory"] = try object(GIFResourceMemoryReading.current())
            try write(report, to: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["projectionReservedBytesAfterFailure"] = service.reservedBytes
            try? write(report, to: evidenceDirectory); throw error
        }
    }

    private static func runCase(name: String, dark: Bool, edge: Bool, directory: URL) async throws -> [String: Any] {
        let screen = try unwrap(NSScreen.main, "Native display is unavailable"), visible = screen.visibleFrame
        let capture = edge ? try frozenCapture(on: screen, right: dark) : nil
        let source = try capture?.image ?? makeSource(), before = try digest(source)
        var unexpected = 0, pinOriginal: CGImage?, pinCurrent: CGImage?, outputError: Error?
        let presenter = SaveWorkflowPresenter(isSmoke: true)
        let editor = ImageEditorController(image: source, presentation: capture?.presentation,
            onSave: { _ in unexpected += 1 }, onPin: { _ in unexpected += 1 },
            onOCR: { _ in unexpected += 1 }, onTranslate: { _ in unexpected += 1 }, saveWorkflow: presenter,
            copyAction: { _ in unexpected += 1 }, onPinWithOriginal: { pinOriginal = $0; pinCurrent = $1; return true })
        defer { editor.cancelDecorationWork(); editor.close() }
        editor.onOutputError = { outputError = $0 }
        let mark = ImageAnnotation(tool: .redact, points: [CGPoint(x: 60, y: 170), CGPoint(x: 140, y: 230)], color: CGColor(gray: 0, alpha: 1))
        editor.setVerificationAnnotations([mark])
        let window = try unwrap(editor.window, "Missing editor window")
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = CGSize(width: min(880, visible.width - 24), height: min(640, visible.height - 24))
        guard size.width >= 760, size.height >= 380 else { throw failure("Native display is too small for editor acceptance") }
        let frame = CGRect(x: edge ? (dark ? visible.maxX - size.width - 4 : visible.minX + 4) : visible.midX - size.width / 2,
                           y: edge ? (dark ? visible.minY + 4 : visible.maxY - size.height - 4) : visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        if capture == nil { window.setFrame(frame, display: true) }
        editor.showWindow(nil); window.makeKeyAndOrderFront(nil)
        try await settle(window)
        let anchoredImage = editor.editorImageScreenFrame, anchoredSelection = editor.editorSelectionFrame
        let anchoredWindow = window.frame
        var paletteSwitchingVerified = false
        if capture != nil {
            try click("editor.captureRatio", root: window.contentView)
            let ratioSurface: NSView = try control("editor.captureRatioPalette", root: window.contentView)
            guard !ratioSurface.isHiddenOrHasHiddenAncestor else { throw failure("Ratio palette did not open") }
            try click("editor.outputDecoration", root: window.contentView)
            let draft = try unwrap(editor.outputDecorationPalette, "Decoration draft did not open")
            guard ratioSurface.isHidden, draft.isShown else { throw failure("Decoration did not replace the ratio palette") }
            try configure(draft)
            let draftWindow = draft.contentView?.window
            try click("editor.captureRatio", root: window.contentView)
            guard editor.outputDecorationPalette == nil, !draft.isShown,
                  draftWindow?.isVisible != true, !ratioSurface.isHiddenOrHasHiddenAncestor,
                  editor.outputDecoration == .none, draft.displayedPreview == nil else {
                throw failure("Canceled decoration remained visible or committed while switching to ratio")
            }
            try await settle(window)
            _ = try snapshot(window.contentView, to: directory.appendingPathComponent("ui-output-ratio-switch-\(name).png"))
            paletteSwitchingVerified = true
        }
        try click("editor.outputDecoration", root: window.contentView)
        let palette = try unwrap(editor.outputDecorationPalette, "Decoration palette did not open")
        palette.contentView?.appearance = window.appearance
        try configure(palette)
        try await waitFor { !palette.hasPendingPreview }
        if let outputError { throw outputError }
        guard palette.isShown, palette.displayedPreview != nil,
              let paletteView = palette.contentView, let paletteWindow = paletteView.window,
              paletteView.bounds.width <= 360, paletteView.bounds.height <= 380,
              screen.frame.insetBy(dx: -2, dy: -2).contains(paletteWindow.frame) else {
            throw failure("Native compact palette was hidden, clipped or outside the display")
        }
        try await settle(paletteWindow)
        guard editor.editorImageScreenFrame == anchoredImage, editor.editorSelectionFrame == anchoredSelection,
              window.frame == anchoredWindow else { throw failure("Opening the decoration palette moved the captured image") }
        if let capture {
            guard editor.captureBoundaryWorkspace.frozenImage === capture.presentation?.frozenImage,
                  window.frame == screen.frame else { throw failure("Frozen capture lost its original screen-anchored dimmed desktop") }
        }
        _ = try snapshot(window.contentView, to: directory.appendingPathComponent("ui-output-decoration-\(name).png"))
        let paletteEvidence = try snapshot(palette.contentView, to: directory.appendingPathComponent("ui-output-decoration-palette-\(name).png"), textID: "decoration.dimensions", dark: dark)
        try click("decoration.apply", root: palette.contentView)
        guard editor.outputDecoration.enabled, editor.outputDecoration.cornerRadius == 20,
              editor.outputDecorationPalette == nil, editor.annotationCanvas.image === source,
              editor.annotationCanvas.annotations.first?.points == mark.points else { throw failure("Apply replaced source pixels or annotation coordinates") }
        let applied = editor.outputDecoration
        try click("editor.undo", root: window.contentView)
        guard editor.outputDecoration == .none, editor.annotationCanvas.image === source else { throw failure("Undo failed to restore metadata only") }
        try click("editor.redo", root: window.contentView)
        guard editor.outputDecoration == applied, editor.annotationCanvas.image === source else { throw failure("Redo failed to restore metadata only") }
        // Reopen, reset the draft, and cancel: committed metadata/undo state survives.
        try click("editor.outputDecoration", root: window.contentView)
        let cancelledPalette = try unwrap(editor.outputDecorationPalette, "Reopen failed")
        try click("decoration.reset", root: cancelledPalette.contentView)
        try click("decoration.cancel", root: cancelledPalette.contentView)
        guard editor.outputDecoration == applied else { throw failure("Cancel applied an uncommitted reset") }

        var projected: CGImage?
        editor.requestOutput(for: .export) { projected = $0 }
        guard editor.outputProjectionIsPending else { throw failure("Decorated output bypassed the asynchronous ownership path") }
        try await waitFor { !editor.outputProjectionIsPending }
        if let outputError { throw outputError }
        let output = try unwrap(projected, "Final output callback did not arrive")
        // Independently computed from blur=4, offsets=(6,10), support=13.
        guard output.width == 666, output.height == 426 else { throw failure("Final decorated pixel dimensions differ") }
        let pixels = try raster(output)
        guard pixel(pixels, width: output.width, x: 0, y: 0)[3] == 0,
              pixel(pixels, width: output.width, x: 7 + 320, y: 3 + 200)[3] == 0,
              pixel(pixels, width: output.width, x: 7 + 100, y: 3 + 200) == [0, 0, 0, 255] else {
            throw failure("Projected transparency, disjoint gap or flattened redaction pixels differ")
        }
        let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: output), options: .init(format: .png))
        let url = directory.appendingPathComponent("output-decoration-\(name).png")
        try ImageExportService.publish(artifact, to: url)
        let encodedSource = try unwrap(CGImageSourceCreateWithData(artifact.data as CFData, nil), "PNG bytes did not reopen")
        let decoded = try unwrap(CGImageSourceCreateImageAtIndex(encodedSource, 0, nil), "PNG failed to decode")
        guard try raster(decoded) == pixels else { throw failure("Real PNG pixels differ from final projection") }
        // Exercise the real toolbar pin path and optional original/current callback.
        try click("editor.pin", root: window.contentView)
        try await waitFor { !editor.outputProjectionIsPending }
        guard pinOriginal === source, let pinCurrent, try raster(pinCurrent) == pixels,
              unexpected == 0, try digest(source) == before else { throw failure("Original/current pin callback changed original or final pixels") }
        editor.close()
        guard editor.isClosed, editor.initialOriginalImage == nil, editor.outputDecorationPalette == nil,
              editor.window?.contentView == nil else { throw failure("Editor close retained original/palette/window ownership") }
        return ["name": name, "sourceUnchanged": true, "annotationCoordinatesUnchanged": true,
                "frozenCaptureOverlay": capture != nil, "imageAnchorUnchanged": true,
                "ratioDecorationSwitchVerified": paletteSwitchingVerified,
                "metadataApplyUndoRedo": true, "cancelPreservedCommittedValue": true,
                "outputWidth": output.width, "outputHeight": output.height,
                "transparentCorner": true, "disjointTransparentGap": true, "redactionRemainsOpaque": true,
                "pngRoundTripExact": true, "originalAwarePinCallback": true,
                "sourceSHA256": before, "outputSHA256": try digest(output),
                "outputFile": url.lastPathComponent, "paletteFrame": NSStringFromRect(paletteWindow.frame),
                "paletteScreenshot": paletteEvidence,
                "ownedPaletteClosed": !palette.isShown, "projectionReservationsAfter": editor.estimatedOutputProjectionReservationBytes]
    }

    private static func cancellationCase() async throws -> [String: Any] {
        let service = EditorOutputProjection.shared
        guard !service.isBusy else { throw failure("Unexpected prior projection") }
        let editor = ImageEditorController(image: try makeSource(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in },
            saveWorkflow: SaveWorkflowPresenter(isSmoke: true), copyAction: { _ in })
        defer { service.queue.isSuspended = false; editor.close() }
        _ = try editor.applyOutputDecoration(.init(enabled: true, cornerRadius: 20, shadowEnabled: true))
        var callbacks = 0, errors = 0
        editor.onOutputError = { _ in errors += 1 }
        service.queue.isSuspended = true
        editor.requestOutput(for: .copy) { _ in callbacks += 1 }
        let reserved = service.reservedBytes
        guard reserved > 0, editor.outputProjectionIsPending else { throw failure("Queued job did not retain admission") }
        editor.requestOutput(for: .pin) { _ in callbacks += 1 }
        guard errors == 1 else { throw failure("Busy projection was not explicitly refused") }
        editor.close()
        guard service.isBusy, service.reservedBytes == reserved, editor.initialOriginalImage == nil else {
            throw failure("Cancel released admission before the operation drained")
        }
        service.queue.isSuspended = false
        try await waitFor { !service.isBusy && service.queue.operationCount == 0 }
        guard callbacks == 0, !editor.outputProjectionIsPending, service.reservedBytes == 0 else {
            throw failure("Canceled output published late or retained ownership")
        }
        return ["busyRefused": true, "queuedCancellation": true, "noLateCallback": true,
                "reservationRetainedUntilDrain": true, "reservedBytesWhileQueued": reserved,
                "reservedBytesAfterDrain": service.reservedBytes, "activeJobsAfterDrain": service.isBusy ? 1 : 0]
    }

    static func makeSource() throws -> CGImage {
        let context = try unwrap(CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 640 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Cannot create synthetic pixels")
        context.setFillColor(CGColor(srgbRed: 0.18, green: 0.64, blue: 0.82, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 400))
        context.setFillColor(CGColor(srgbRed: 0.96, green: 0.72, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 400, y: 0, width: 240, height: 400))
        for y in stride(from: 20, to: 380, by: 32) {
            context.setFillColor(CGColor(gray: 1, alpha: 0.35))
            context.fill(CGRect(x: 24, y: y, width: 150, height: 5))
            context.fill(CGRect(x: 424, y: y, width: 170, height: 5))
        }
        return try unwrap(context.makeImage(), "Cannot finish synthetic pixels")
    }
    private static func frozenCapture(on screen: NSScreen, right: Bool) throws -> CapturedImage {
        let width = Int(screen.frame.width.rounded(.down)), height = Int(screen.frame.height.rounded(.down))
        guard width >= 700, height >= 460, width <= 4_096, height <= 2_304 else { throw failure("Synthetic desktop exceeds bounded fixture dimensions") }
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Cannot create synthetic frozen desktop")
        context.setFillColor(CGColor(srgbRed: 0.19, green: 0.26, blue: 0.36, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); context.setLineWidth(1)
        for x in stride(from: 0, to: width, by: 64) {
            context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height)); context.strokePath()
        }
        let pixelFrame = CGRect(x: right ? width - 640 - 12 : 12, y: right ? height - 400 - 12 : 12, width: 640, height: 400)
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(try makeSource(), in: CGRect(x: pixelFrame.minX, y: CGFloat(height) - pixelFrame.maxY, width: 640, height: 400))
        return try CapturedImage.frozenPixelRegion(image: unwrap(context.makeImage(), "Missing synthetic desktop"), displayID: 7,
            displayFrame: screen.frame, pixelFrame: pixelFrame)
    }
    private static func configure(_ palette: ImageOutputDecorationPalette) throws {
        for id in ["decoration.enabled", "decoration.border", "decoration.shadow"] {
            let button: NSButton = try control(id, root: palette.contentView); button.state = .on; try send(button)
        }
        for (id, value) in [("radius", "20"), ("borderWidth", "2"), ("blur", "4"), ("opacity", "35"), ("offsetX", "6"), ("offsetY", "10")] {
            let field: NSTextField = try control("decoration." + id, root: palette.contentView)
            field.stringValue = value; try send(field)
        }
    }
    static func raster(_ image: CGImage) throws -> [UInt8] {
        let context = try unwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Cannot inspect pixels")
        context.interpolationQuality = .none; context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private static func digest(_ image: CGImage) throws -> String { SHA256.hash(data: Data(try raster(image))).map { String(format: "%02x", $0) }.joined() }
    private static func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] { Array(data[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
    private static func snapshot(_ optionalView: NSView?, to url: URL,
                                 textID: String? = nil, dark: Bool? = nil) throws -> [String: Any] {
        let view = try unwrap(optionalView, "Missing native view"); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let width = Int(ceil(view.bounds.width)), height = Int(ceil(view.bounds.height))
        guard width > 0, height > 0, width <= 4_096, height <= 2_304 else { throw failure("Native screenshot exceeded bounds") }
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), "Cannot allocate view screenshot")
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        // cacheDisplay can leave NSVisualEffectView/window material transparent.
        // Resolve the native window surface in the actual view appearance and
        // composite explicitly; an alpha-only cache is not a window screenshot.
        var surface = CGColor(gray: 1, alpha: 1)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            surface = NSColor.windowBackgroundColor.withAlphaComponent(1).cgColor
        }
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Cannot compose native surface")
        context.setFillColor(surface); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let background = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4))
        context.draw(try unwrap(bitmap.cgImage, "Missing screenshot pixels"), in: CGRect(x: 0, y: 0, width: width, height: height))
        let image = try unwrap(context.makeImage(), "Missing composed native pixels"), bytes = try raster(image)
        guard stride(from: 3, to: bytes.count, by: 4).allSatisfy({ bytes[$0] == 255 }) else { throw failure("Native surface screenshot retained transparent outer pixels") }
        func luminance(_ values: [UInt8]) -> Double {
            let channels = values.prefix(3).map { component -> Double in
                let s = Double(component) / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let backgroundLuminance = luminance(background)
        if let dark {
            guard dark ? backgroundLuminance < 0.2 : backgroundLuminance > 0.6 else { throw failure("Native surface did not resolve the requested light/dark appearance") }
        }
        var maximumTextContrast = 0.0
        if let textID {
            let label: NSTextField = try control(textID, root: view)
            let rect = view.convert(label.bounds, from: label).integral.intersection(view.bounds)
            let crop = CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            let labelImage = try unwrap(image.cropping(to: crop), "Cannot inspect native label contrast")
            let labelPixels = try raster(labelImage)
            for index in stride(from: 0, to: labelPixels.count, by: 4) {
                let ink = luminance(Array(labelPixels[index..<index + 4]))
                maximumTextContrast = max(maximumTextContrast, (max(ink, backgroundLuminance) + 0.05) / (min(ink, backgroundLuminance) + 0.05))
            }
            guard maximumTextContrast >= 4.5 else { throw failure("Rendered native dimension text lacks readable contrast") }
        }
        try image.writePNG(to: url)
        return ["file": url.lastPathComponent, "opaqueSurface": true, "backgroundRGBA": background,
                "maximumRenderedTextContrast": maximumTextContrast,
                "method": "Own native view cache composited over resolved NSColor.windowBackgroundColor; excludes WindowServer shadows and other windows"]
    }
    private static func control<T: NSView>(_ id: String, root: NSView?) throws -> T {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            for child in view.subviews { if let match = find(child) { return match } }
            return nil
        }
        return try unwrap(find(try unwrap(root, "Missing view tree")) as? T, "Missing native control \(id)")
    }
    private static func click(_ id: String, root: NSView?) throws {
        let button: NSButton = try control(id, root: root)
        guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { throw failure("Native control is unavailable: \(id)") }
        try send(button)
    }
    private static func send(_ control: NSControl) throws {
        guard let action = control.action, NSApp.sendAction(action, to: control.target, from: control) else { throw failure("Native action failed") }
    }
    private static func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard predicate() else { throw failure("Native output/palette did not drain before deadline") }
    }
    private static func settle(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(nanoseconds: 40_000_000)
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any], "Invalid observation")
    }
    private static func write(_ report: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("output-decoration-native.json"), options: .atomic)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Output decoration native fixture: " + message) }
}
