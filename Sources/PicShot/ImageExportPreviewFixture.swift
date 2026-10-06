import AppKit
import CryptoKit
import ImageIO

/// Installed-app synthetic evidence through the production controls, worker,
/// decoder and publication path. Never captures the user's desktop or opens a
/// user file. Owner wires verify into the existing installed UI smoke launcher.
@MainActor
enum ImageExportPreviewFixture {
    static func verify(evidenceDirectory: URL, includeResourceCycles: Bool = true) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let before = NSApp.appearance; NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = before }
        var report: [String: Any] = ["status": "running", "syntheticSource": true,
            "networkAttempted": false, "screenCaptureAttempted": false, "preferencesWritten": false,
            "snapshotBackground": "Effective native NSWindow background composited behind cached content; evidence only",
            "snapshotPixelsPerPoint": 1,
            "maximumConcurrentEncoders": ImageExportService.queue.maxConcurrentOperationCount,
            "maximumSourcePixels": ImageExportLimits.standard.maximumSourcePixels,
            "maximumEncodedBytes": ImageExportLimits.standard.maximumEncodedBytes,
            "maximumCachedPreviewPages": 2,
            "maximumDecodedPreviewBytesPerPage": ImageExportLimits.standard.maximumPreviewBytes,
            "limitations": ["Synthetic native controls, not physical user input or live-screen capture", "Byte/pixel/job caps are not a process RSS or leak measurement", "Save-new-copy only; replacing existing files is not implemented"]]
        var completed: [String] = []
        do {
            report["nativeCodecCapabilities"] = ImageExportCapabilityProbe.report()
            let visual = try await visualChecks(evidenceDirectory: evidenceDirectory)
            report.merge(visual.report) { _, new in new }; completed = visual.completed
            // The helper returned only small metadata and weak references; its
            // source raster, encoded artifacts and PDF decoder have left scope.
            let drainDeadline = Date().addingTimeInterval(10)
            while ImageExportService.queue.operationCount > 0 && Date() < drainDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try await Task.sleep(nanoseconds: 80_000_000)
            guard visual.controllers.allSatisfy({ $0.value == nil }), ImageExportService.queue.operationCount == 0 else {
                throw failure("Visual fixture retained a controller or worker before resource sampling")
            }
            report["visualControllersReleasedBeforeResource"] = true
            report["queuedJobsBeforeResource"] = ImageExportService.queue.operationCount
            if includeResourceCycles {
                report["resourceObservation"] = try await ImageExportResourceFixture.verify(evidenceDirectory: evidenceDirectory)
                completed.append("warmup-and-four-measured-native-memory-cycles")
            } else {
                report["resourceObservation"] = ["status": "skipped", "reason": "early-ui-only profile; full installed smoke must run repeated memory sampling"]
            }
            report["status"] = "passed"; report["completedChecks"] = completed
            report["files"] = ["ui-export-owned-edge-light.png", "ui-export-owned-edge-dark.png", "ui-export-jpeg-preview.png", "ui-export-pdf-page-2.png", "ui-export-small-desktop.png", "export-preview-result.jpg",
                               "export-paginated-result.pdf", "export-result.bmp", "image-export-preview.json"] + (includeResourceCycles ? ["image-export-resource.json"] : [])
            try write(report, directory: evidenceDirectory)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription; report["completedChecks"] = completed
            try? write(report, directory: evidenceDirectory); throw error
        }
    }
    private static func visualChecks(evidenceDirectory: URL) async throws
        -> (report: [String: Any], completed: [String], controllers: [ImageExportFixtureWeakController]) {
        var report: [String: Any] = [:], completed: [String] = []
        // Production saves remain create-only. Repeated fixture runs publish
        // into a new private directory, then atomically refresh known evidence
        // copies only after output verification and the collision check.
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Export-Preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try makeSource(width: 612, height: 1711)
        let owned = try await ownedParentChecks(source: source, evidenceDirectory: evidenceDirectory)
        report["ownedParentEdgeLayout"] = owned.layouts
        completed.append("owned-export-edge-parent-movement-and-close")
        let raster = try ImageExportController(image: source)
        let weakRaster = ImageExportFixtureWeakController(raster)
        defer { raster.cancelExport() }
        raster.showWindow(nil); raster.window?.center(); raster.window?.makeKeyAndOrderFront(nil)
        // Exercise format and rapid quality controls before awaiting the
        // actual encoded result. Intermediate results must never win.
        raster.accessory.picker.selectItem(at: ImageExportFormat.jpeg.rawValue); try send(raster.accessory.picker)
        for value in [15.0, 88, 31] { raster.accessory.quality.doubleValue = value; try send(raster.accessory.quality) }
        let jpeg = try await ready(raster)
        guard jpeg.options.format == .jpeg, jpeg.options.quality == 0.31 else { throw failure("Stale JPEG preview replaced latest request") }
        report["jpegWindowLayout"] = try verifyLayout(raster)
        try snapshot(raster, to: evidenceDirectory.appendingPathComponent("ui-export-jpeg-preview.png"))
        if let screen = raster.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let compact = CGRect(x: screen.minX + 12, y: screen.minY + 12,
                                 width: min(580, screen.width - 24), height: min(480, screen.height - 24))
            raster.fitWindow(to: compact)
            report["compactWindowLayout"] = try verifyLayout(raster, visibleFrame: compact)
            report["compactViewportScope"] = "Synthetic 580×480-or-smaller usable desktop rectangle inside the actual screen"
            try snapshot(raster, to: evidenceDirectory.appendingPathComponent("ui-export-small-desktop.png"))
            raster.fitWindow()
        }
        let jpegURL = workspace.appendingPathComponent("export-preview-result.jpg")
        try await raster.savePrepared(to: jpegURL)
        guard try Data(contentsOf: jpegURL) == jpeg.data else { throw failure("Saved JPEG differs from preview bytes") }
        report["jpeg"] = ["quality": jpeg.options.quality, "actualBytes": jpeg.byteCount,
                          "sha256": digest(jpeg.data), "savedMatchesPreview": true]
        completed.append("native-quality-and-exact-byte-preview")

        let pdf = try ImageExportController(image: source)
        let weakPDF = ImageExportFixtureWeakController(pdf)
        defer { pdf.cancelExport() }
        pdf.showWindow(nil); pdf.window?.center(); pdf.window?.makeKeyAndOrderFront(nil)
        pdf.accessory.picker.selectItem(at: ImageExportFormat.pdf.rawValue); try send(pdf.accessory.picker)
        pdf.accessory.paper.selectItem(at: ImageExportPaper.letter.rawValue); try send(pdf.accessory.paper)
        pdf.accessory.margin.selectItem(withTag: 36); try send(pdf.accessory.margin)
        let document = try await ready(pdf)
        guard document.pageCount > 1 else { throw failure("Long PDF was not paginated") }
        pdf.showPage(1); try await awaitPreview(pdf)
        report["pdfWindowLayout"] = try verifyLayout(pdf)
        try snapshot(pdf, to: evidenceDirectory.appendingPathComponent("ui-export-pdf-page-2.png"))
        let pdfURL = workspace.appendingPathComponent("export-paginated-result.pdf")
        try await pdf.savePrepared(to: pdfURL)
        let reopened = try unwrap(CGPDFDocument(pdfURL as CFURL), "Saved PDF cannot reopen")
        let layout = try ImageExportPDFLayout.make(width: source.width, height: source.height, options: document.options)
        guard reopened.numberOfPages == layout.pages.count, try Data(contentsOf: pdfURL) == document.data else { throw failure("PDF pages/bytes mismatch") }
        report["pdf"] = ["pageCount": reopened.numberOfPages, "actualBytes": document.byteCount,
            "mediaBoxWidth": layout.mediaBox.width, "mediaBoxHeight": layout.mediaBox.height, "marginPoints": 36,
            "sourceRowRanges": layout.pages.map { [Int($0.source.minY), Int($0.source.maxY)] },
            "sha256": digest(document.data), "savedMatchesPreview": true]
        completed.append("native-pdf-controls-page-navigation-and-publication")

        let bmp = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: source), options: ImageExportOptions(format: .bmp))
        try ImageExportService.publish(bmp, to: workspace.appendingPathComponent("export-result.bmp"))
        report["bmp"] = ["actualBytes": bmp.byteCount, "magicBM": bmp.data.prefix(2) == Data("BM".utf8)]
        let cancelled = try ImageExportController(image: source)
        let weakCancelled = ImageExportFixtureWeakController(cancelled)
        cancelled.requestPreview(); cancelled.cancelExport()
        try await Task.sleep(nanoseconds: 220_000_000)
        guard cancelled.isClosed, cancelled.latestArtifact == nil else { throw failure("Closed export accepted stale preview") }
        completed.append("cancel-rejects-stale-preview")
        let prior = try Data(contentsOf: jpegURL)
        do { try ImageExportService.publish(jpeg, to: jpegURL); throw failure("Existing destination unexpectedly replaced") }
        catch ImageExportError.destinationExists { }
        guard try Data(contentsOf: jpegURL) == prior else { throw failure("Collision changed original bytes") }
        completed.append("existing-destination-preserved")
        raster.cancelExport(); pdf.cancelExport(); cancelled.cancelExport()
        guard raster.isClosed, pdf.isClosed, cancelled.isClosed else { throw failure("Visual fixture did not close all controllers") }
        for name in ["export-preview-result.jpg", "export-paginated-result.pdf", "export-result.bmp"] {
            let data = try Data(contentsOf: workspace.appendingPathComponent(name))
            guard data.count <= ImageExportLimits.standard.maximumEncodedBytes else { throw failure("Evidence copy exceeded output bound") }
            try data.write(to: evidenceDirectory.appendingPathComponent(name), options: .atomic)
        }
        try FileManager.default.removeItem(at: workspace)
        report["visualTemporaryWorkspaceRemoved"] = true
        report["visualControllersClosed"] = true
        report["evidencePublication"] = "Verified private create-only outputs copied atomically to exact fixture evidence filenames; safe to rerun"
        return (report, completed, [weakRaster, weakPDF, weakCancelled] + owned.controllers)
    }

    /// Early installed evidence of the actual production relationship and
    /// screen geometry; no test call repairs the export frame after presentation.
    private static func ownedParentChecks(source: CGImage, evidenceDirectory: URL) async throws
        -> (layouts: [[String: Any]], controllers: [ImageExportFixtureWeakController]) {
        guard let screen = NSScreen.main, screen.visibleFrame.width >= 720, screen.visibleFrame.height >= 650 else {
            throw failure("Owned export evidence needs a 720×650 usable display")
        }
        var layouts: [[String: Any]] = [], controllers: [ImageExportFixtureWeakController] = []
        for borderless in [false, true] {
            let mode = borderless ? "dark" : "light"
            let style: NSWindow.StyleMask = borderless ? [.borderless] : [.titled, .closable]
            let parent = NSWindow(contentRect: CGRect(x: screen.visibleFrame.maxX - 370,
                y: screen.visibleFrame.minY + 10, width: 360, height: 200), styleMask: style, backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false; parent.title = "Synthetic export parent"
            parent.appearance = NSAppearance(named: borderless ? .darkAqua : .aqua)
            if borderless { parent.level = .floating }
            parent.orderFront(nil); defer { parent.close() }
            let originalFrame = parent.frame
            let controller = try unwrap(ImageExportController.present(image: source, from: parent), "Owned export did not open")
            controllers.append(ImageExportFixtureWeakController(controller)); defer { controller.cancelExport() }
            controller.window?.appearance = parent.appearance
            let artifact = try await ready(controller)
            try await Task.sleep(nanoseconds: 450_000_000)
            // Save the actual owned-view pixels even if the strict geometry
            // check below fails, so a native failure remains visually actionable.
            try snapshot(controller, to: evidenceDirectory.appendingPathComponent("ui-export-owned-edge-" + mode + ".png"))
            let initial = try verifyLayout(controller)
            guard parent.frame == originalFrame, controller.window?.parent === parent,
                  controller.window?.sheetParent == nil, controller.window!.level.rawValue > parent.level.rawValue else {
                throw failure("Export changed its parent or lost above-parent ownership")
            }
            parent.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 10, y: screen.visibleFrame.maxY - 240))
            try await Task.sleep(nanoseconds: 450_000_000)
            let moved = try verifyLayout(controller)
            guard controller.window?.parent === parent, controller.latestArtifact?.data == artifact.data else {
                throw failure("Parent movement detached export or changed its frozen bytes")
            }
            if borderless { parent.close() }
            else {
                let root = try unwrap(controller.window?.contentView, "Owned export content missing")
                let cancel = try unwrap(descendants(root).first { $0.identifier?.rawValue == "export.cancel" } as? NSControl,
                                        "Owned export cancel control missing")
                try send(cancel)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            guard controller.isClosed, controller.window?.parent == nil, controller.window?.contentView == nil,
                  controller.window?.isVisible == false, parent.childWindows?.isEmpty ?? true,
                  borderless || parent.isVisible else { throw failure("Owned export cancel/parent-close left an orphan or closed its parent") }
            layouts.append(["appearance": mode, "borderlessFloatingParent": borderless,
                "sourceWidth": source.width, "sourceHeight": source.height, "initial": initial, "afterParentMove": moved,
                "frozenBytesPreserved": true, "parentUnmovedByPresentation": true,
                "closeRoute": borderless ? "parent close" : "native Cancel control", "detachedAndClosed": true])
        }
        return (layouts, controllers)
    }

    /// Real screen-space bounds, not merely a content-cache screenshot. Every
    /// visible export control and both bottom actions must fit before evidence
    /// is accepted; image dimensions must never increase the window dimensions.
    static func verifyLayout(_ controller: ImageExportController, visibleFrame: CGRect? = nil) throws -> [String: Any] {
        guard let window = controller.window, let root = window.contentView,
              let usable = visibleFrame ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { throw failure("No display is available for export layout verification") }
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let tolerance = usable.insetBy(dx: -1, dy: -1)
        guard tolerance.contains(window.frame), root.bounds.width <= 620.5, root.bounds.height <= 550.5 else {
            throw failure("Export window exceeds the compact screen bounds: \(window.frame), content \(root.bounds.size), visible \(usable)")
        }
        let controls = descendants(root).compactMap { $0 as? NSControl }.filter {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && ($0.identifier?.rawValue.hasPrefix("export.") ?? false)
        }
        let required: Set<String> = ["export.format", "export.save", "export.cancel"]
        guard required.isSubset(of: Set(controls.compactMap { $0.identifier?.rawValue })) else { throw failure("Export actions are missing from the native window") }
        var frames: [[String: Any]] = []
        for control in controls {
            let rect = control.convert(control.bounds, to: root)
            let screen = window.convertToScreen(control.convert(control.bounds, to: nil))
            guard rect.width > 0, rect.height > 0, root.bounds.insetBy(dx: -1, dy: -1).contains(rect), tolerance.contains(screen) else {
                throw failure("Export control is clipped or off screen: \(control.identifier?.rawValue ?? "unknown") \(screen)")
            }
            frames.append(["id": control.identifier?.rawValue ?? "unknown", "screenFrame": rectangle(screen)])
        }
        guard let image = controller.previewView.image else { throw failure("Export preview is missing during layout verification") }
        let displayed = controller.previewView.displayedImageRect
        guard displayed.width > 0, displayed.height > 0,
              controller.previewView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(displayed),
              abs(displayed.width / displayed.height - image.size.width / image.size.height) < 0.0001 else {
            throw failure("Export preview aspect-fit geometry is invalid")
        }
        return ["windowFrame": rectangle(window.frame), "visibleFrame": rectangle(usable),
            "contentSize": [root.bounds.width, root.bounds.height], "allControlsWithinVisibleFrame": true,
            "visibleControls": frames, "previewBounds": rectangle(controller.previewView.bounds),
            "displayedImageRect": rectangle(displayed), "decodedImageSize": [image.size.width, image.size.height],
            "previewAspectRatioPreserved": true, "imageIntrinsicSizeIgnored": controller.previewView.intrinsicContentSize.width == NSView.noIntrinsicMetric]
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private static func rectangle(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }

    private static func ready(_ controller: ImageExportController) async throws -> ImageExportArtifact {
        let deadline = Date().addingTimeInterval(30)
        while controller.latestArtifact == nil && !controller.isClosed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        return try unwrap(controller.latestArtifact, "Preview unavailable: \(controller.statusLabel.stringValue)")
    }
    private static func awaitPreview(_ controller: ImageExportController) async throws {
        let deadline = Date().addingTimeInterval(15)
        while controller.previewView.image == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard controller.previewView.image != nil else { throw failure("PDF page preview timed out") }
    }
    private static func send(_ control: NSControl) throws {
        guard control.sendAction(control.action, to: control.target) else { throw failure("Native export control did not dispatch") }
    }
    private static func snapshot(_ controller: ImageExportController, to url: URL) throws {
        guard let window = controller.window, let view = window.contentView else { throw failure("Export view closed") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        guard width > 0, height > 0, width <= 4_000_000 / height,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                  bytesPerRow: width * 4, bitsPerPixel: 32) else { throw failure("Export screenshot allocation failed") }
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let cached = bitmap.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Export screenshot composite failed") }
        // AppKit's titled-window background may not be included in cacheDisplay.
        // Composite only the evidence screenshot, never the user's image bytes.
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(window.backgroundColor.cgColor); context.fill(bounds)
            context.draw(cached, in: bounds)
        }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw failure("Export screenshot encoding failed") }
        try data.write(to: url, options: .atomic)
    }
    private static func makeSource(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw failure("Fixture source allocation failed") }
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8((x / 4 * 17 + y / 8 * 13) % 256)
            bytes[offset + 1] = UInt8((x / 4 * 7 + y / 8 * 31) % 256)
            bytes[offset + 2] = UInt8((x / 4 * 23 + y / 8 * 3) % 256); bytes[offset + 3] = 255
        } }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 140, y: 200, width: 330, height: 95))
        return try unwrap(context.makeImage(), "Fixture image unavailable")
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("image-export-preview.json"), options: .atomic)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Native export preview: \(message)") }
}

@MainActor private final class ImageExportFixtureWeakController {
    weak var value: ImageExportController?
    init(_ value: ImageExportController) { self.value = value }
}
