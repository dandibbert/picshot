import AppKit
import CryptoKit
import ImageIO
import PicShotCore

/// Original synthetic images, real native controls and real exclusive files.
/// All preferences and pasteboard contents are isolated from the user's data.
@MainActor
enum SaveWorkflowUIPreviewFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-Save-UI-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let suite = "PicShot-Save-UI-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw failure("Isolated defaults unavailable") }
        let originalAppearance = NSApp.appearance
        let board = NSPasteboard.withUniqueName()
        defer { defaults.removePersistentDomain(forName: suite); NSApp.appearance = originalAppearance; board.releaseGlobally(); try? files.removeItem(at: root) }
        var report: [String: Any] = ["status": "running", "source": "original synthetic rasters", "userPreferencesRead": false,
            "generalPasteboardReadOrWritten": false, "liveScreenCaptured": false, "networkAttempted": false,
            "maximumSaveJobs": SaveWorkflowPresenter.maximumJobs,
            "estimatedRetainedInputBudgetBytes": SaveWorkflowPresenter.maximumRetainedInputBytes,
            "budgetScope": "estimated retained inputs/artifacts; encoded output is additionally bounded per job; not a total RSS quota",
            "clipboardScope": "exact saved PNG bytes in a private native pasteboard; no broad external-app paste compatibility claim",
            "snapshotScope": "cached owned native window content, composited using actual window geometry for the capture/child view; not a live desktop capture"]
        let presenter = SaveWorkflowPresenter(defaults: defaults)
        presenter.clipboardCopier = { data, type in board.clearContents(); return board.setData(data, forType: .init(type)) }
        defer { for controller in presenter.controllers { controller.cancel() } }
        do {
            guard let screen = NSScreen.main, let displayID = screen.displayID,
                  screen.visibleFrame.width >= 800, screen.visibleFrame.height >= 640 else { throw failure("Native save UI needs an 800×640 usable display") }
            var settings = SaveWorkflowSettings(baseURL: root, filenameTemplate: "final-{counter}")
            try settings.save(to: defaults)
            let source = try sourceImage(width: 160, height: 112)
            let original = try pixels(source)
            var visuals: [[String: Any]] = []
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                let controller = SettingsController(onChange: {}, defaults: defaults, isSmoke: false)
                defer { controller.close() }
                controller.selectCategory(.save); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                controller.window?.appearance = NSAppearance(named: appearance)
                let view = controller.saveWorkflowView
                try require(view.automatic.state == .off && view.previewLabel.stringValue.contains("1920"), "Real settings defaults/preview mismatch")
                let prior = defaults.data(forKey: SaveWorkflowSettings.preferenceKey)
                view.filenameTemplate.stringValue = "{unknown}"; try send(view.filenameTemplate)
                try require(!view.errorLabel.stringValue.isEmpty, "Invalid template did not surface an error")
                do { _ = try controller.validateSaveWorkflowDraft(); throw failure("Invalid template was accepted") } catch is SaveWorkflowValidationError { }
                view.filenameTemplate.stringValue = "final-{counter}"; try send(view.filenameTemplate)
                view.onFolderPanelShown = { $0.cancel(nil) }
                try send(view.chooseFolderButton)
                try await until({ view.folderPanel == nil }, "Folder cancellation did not complete")
                try require(view.baseURL == root && defaults.data(forKey: SaveWorkflowSettings.preferenceKey) == prior, "Folder/settings draft cancellation changed preferences")
                try snapshot(controller.window!, to: evidenceDirectory.appendingPathComponent("ui-save-settings-" + mode + ".png"))
                visuals.append(["appearance": mode, "windowWidth": controller.window!.contentView!.bounds.width,
                                "windowHeight": controller.window!.contentView!.bounds.height, "realTemplatePreview": true, "invalidTemplateRejected": true, "folderCancelPreserved": true])
                controller.close()
            }
            report["settings"] = visuals
            NSApp.appearance = NSAppearance(named: .aqua)
            let desktop = try sourceImage(width: 960, height: 640)
            let displayFrame = CGRect(origin: screen.frame.origin, size: CGSize(width: 960, height: 640))
            let capture = try CapturedImage.frozenRegion(image: desktop, displayID: displayID, displayFrame: displayFrame,
                selection: CGRect(x: 760, y: 20, width: 180, height: 120))
            let editor = ImageEditorController(image: capture.image, presentation: capture.presentation,
                onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, saveWorkflow: presenter)
            defer { editor.close() }
            editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            editor.setVerificationAnnotations([ImageAnnotation(tool: .redact,
                points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60)], color: CGColor(gray: 0, alpha: 1))])
            let flattened = try unwrap(editor.annotationCanvas.flattened(), "Flattened editor result unavailable")
            let expected = try pixels(flattened)
            try require(editor.floatingToolbarFrame.minX >= 0 && editor.floatingToolbarFrame.maxX <= editor.captureBoundaryWorkspace.bounds.width + 1,
                        "Save chevron pushes edge toolbar outside owned desktop")
            var edgeSnapshotError: Error?
            var wasAboveCapture = false
            presenter.onPresent = { controller in
                wasAboveCapture = controller.window?.parent === editor.window && controller.window!.level.rawValue > editor.window!.level.rawValue
                do { try ownedComposite(parent: editor.window!, child: controller.window!, to: evidenceDirectory.appendingPathComponent("ui-save-edge-child.png")) }
                catch { edgeSnapshotError = error }
                controller.closeButton.performClick(nil)
            }
            try menu("快速保存 PNG", editor)
            try await drained(presenter)
            if let edgeSnapshotError { throw edgeSnapshotError }
            try require(wasAboveCapture && !editor.isClosed, "Quick-save panel cancel did not preserve frozen editor")
            try require(try pixels(unwrap(editor.annotationCanvas.flattened(), "Canceled image missing")) == expected,
                        "Cancel changed finalized editor pixels")
            presenter.onPresent = nil
            try menu("快速保存 PNG", editor)
            let quick = try unwrap(presenter.controllers.last, "Quick save did not create a job")
            try await until({ quick.state == .completed || quick.state == .failed }, "Quick save did not finish")
            let quickResult = try unwrap(quick.result, quick.statusLabel.stringValue)
            try require(try pixels(decode(quickResult.savedURL)) == expected, "Quick save serialized intermediate/unredacted pixels")
            try require(editor.isClosed && quick.window?.parent == nil && quick.window?.level == .normal,
                        "Completed capture did not detach/reset transient save window")
            quick.cancel(); try await drained(presenter)
            settings.filenameTemplate = "collision"; try settings.save(to: defaults)
            let existing = root.appendingPathComponent("collision.png"); let sentinel = Data("keep-original".utf8); try sentinel.write(to: existing)
            presenter.onPresent = { controller in
                controller.onCollisionShown = { alert in
                    guard alert.buttons.map(\.title) == ["保留两者", "选择其他名称…", "取消"] else { alert.buttons.last?.performClick(nil); return }
                    alert.buttons.last?.performClick(nil)
                }
            }
            let cancelled = try unwrap(presenter.save(image: source), "Collision cancel not started")
            try await until({ cancelled.state == .closed }, "Collision cancellation did not close")
            try await drained(presenter)
            try require(try Data(contentsOf: existing) == sentinel && pixels(source) == original, "Collision cancel changed existing file/source")
            presenter.onPresent = { controller in controller.onCollisionShown = { $0.buttons.first?.performClick(nil) } }
            let both = try unwrap(presenter.save(image: source, copy: true), "Save-copy not started")
            try await until({ both.state == .completed || both.state == .failed }, "Save-copy did not finish")
            let bothResult = try unwrap(both.result, both.statusLabel.stringValue)
            try require(bothResult.savedURL.lastPathComponent == "collision (1).png", "Keep Both did not create a distinct name")
            let savedBytes = try Data(contentsOf: bothResult.savedURL)
            try require(board.data(forType: .png) == savedBytes && bothResult.clipboardOutcome == .copied, "Saved/copied bytes differ")
            try require(try Data(contentsOf: existing) == sentinel, "Keep Both changed old file")
            both.cancel(); try await drained(presenter); presenter.onPresent = nil
            settings.filenameTemplate = "copy-failure-{counter}"; try settings.save(to: defaults)
            presenter.clipboardCopier = { _, _ in false } // Explicit failure injection; real file publication still runs.
            let copyFailure = try unwrap(presenter.save(image: source, copy: true), "Copy-failure run not started")
            try await until({ copyFailure.state == .completed || copyFailure.state == .failed }, "Copy-failure result unavailable")
            let failedCopy = try unwrap(copyFailure.result, copyFailure.statusLabel.stringValue)
            try require(failedCopy.clipboardOutcome == .failed && files.fileExists(atPath: failedCopy.savedURL.path) && !copyFailure.retryCopyButton.isHidden,
                        "Clipboard failure did not preserve file/offer retry")
            try snapshot(copyFailure.window!, to: evidenceDirectory.appendingPathComponent("ui-save-copy-failure.png"))
            copyFailure.cancel(); try await drained(presenter)
            presenter.clipboardCopier = { data, type in board.clearContents(); return board.setData(data, forType: .init(type)) }
            report["actions"] = ["quickSaveActualFlattenedPixels": true, "privateClipboardSameSavedBytes": true,
                "collisionKeepBoth": true, "collisionCancelPreservesFileAndSource": true,
                "copyFailureInjected": true, "copyFailurePreservesSavedFile": true, "captureChildAboveParent": true]
            // Quiet auto save is triggered by a real finalized history-save action.
            // No raw capture, preview, OCR or canceled editor invokes this path.
            settings.autoOnFinalizedAction = true; settings.filenameTemplate = "automatic-{counter}"; try settings.save(to: defaults)
            let automaticEditor = ImageEditorController(image: source, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, saveWorkflow: presenter)
            automaticEditor.showWindow(nil)
            try menu("保存到历史", automaticEditor, identifier: "editor.more")
            let automatic = try unwrap(presenter.controllers.last, "Finalized action did not queue automatic copy")
            try require(automatic.quietAutomatic && automatic.window?.isVisible != true, "Automatic success stole focus with a progress window")
            automaticEditor.close()
            try await drained(presenter)
            try require(automatic.result != nil && automatic.window?.isVisible != true, "Quiet job did not survive capture close")
            report["quietAutomaticFinalizedAction"] = true
            // Two warm-up jobs plus eight measured real PNG publications. These
            // report parent samples/owned references, not a leak or RSS guarantee.
            var cycles: [[String: Any]] = []
            for cycle in 0..<10 {
                let before = GIFResourceMemoryReading.current()
                var job: SaveWorkflowController? = try unwrap(presenter.save(image: source, automatic: cycle % 2 == 0), "Repeated save admission failed")
                weak var weakJob = job
                try await until({ job?.jobDrained == true }, "Repeated job did not drain")
                let saved = try unwrap(job?.result, job?.statusLabel.stringValue ?? "Missing repeated result")
                try require(files.fileExists(atPath: saved.savedURL.path), "Repeated output missing")
                job?.cancel(); job = nil
                try await until({ weakJob == nil && presenter.controllers.isEmpty }, "Completed save window/controller retained")
                try require(presenter.activeJobCount == 0 && presenter.retainedInputBytes == 0, "Save input reservations were not released")
                try files.removeItem(at: saved.savedURL)
                cycles.append(["cycle": cycle, "warmup": cycle < 2, "automatic": cycle % 2 == 0,
                    "before": try object(before), "after": try object(GIFResourceMemoryReading.current()),
                    "activeJobs": presenter.activeJobCount, "retainedInputBytes": presenter.retainedInputBytes,
                    "controllerReleased": true, "temporaryJobRemoved": true])
            }
            report["resourceCycles"] = cycles; report["resourceInterpretation"] = "Two warmups and eight measured small real jobs; sampled parent values, no zero-leak assertion"
            try require(!presenter.canAdmit(inputBytes: SaveWorkflowPresenter.maximumRetainedInputBytes + 1), "Input byte admission is not enforced")
            report["status"] = "passed"
            report["files"] = ["ui-save-settings-light.png", "ui-save-settings-dark.png", "ui-save-edge-child.png", "ui-save-copy-failure.png", "save-workflow-ui.json"]
            try write(report, directory: evidenceDirectory); return report
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription; try? write(report, directory: evidenceDirectory); throw error }
    }
    static func sourceImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw failure("Synthetic allocation failed") }
        context.setFillColor(CGColor(srgbRed: 0.14, green: 0.44, blue: 0.72, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.96, green: 0.64, blue: 0.24, alpha: 1)); context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return try unwrap(context.makeImage(), "Synthetic image failed")
    }
    static func pixels(_ image: CGImage) throws -> Data { try CodecExportResourceFixture.raster(image) }
    static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw failure("Saved PNG did not decode") }; return image
    }
    static func menu(_ title: String, _ editor: ImageEditorController, identifier: String = "editor.saveActions") throws {
        guard let root = editor.window?.contentView,
              let popup = descendants(root).first(where: { $0.identifier?.rawValue == identifier }) as? NSPopUpButton,
              let item = popup.menu?.items.first(where: { $0.title == title }), let action = item.action,
              NSApp.sendAction(action, to: item.target, from: item) else { throw failure("Native menu action unavailable: " + title) }
    }
    private static func send(_ control: NSControl) throws { if !control.sendAction(control.action, to: control.target) { throw failure("Native control did not dispatch") } }
    static func until(_ condition: () -> Bool, _ text: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), text)
    }
    static func drained(_ presenter: SaveWorkflowPresenter) async throws { try await until({ presenter.activeJobCount == 0 && presenter.controllers.isEmpty }, "Save jobs/reservations did not drain") }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private static func nativeImage(_ window: NSWindow) throws -> CGImage {
        guard let view = window.contentView else { throw failure("Owned content missing") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let w = Int(view.bounds.width.rounded(.up)), h = Int(view.bounds.height.rounded(.up))
        guard w > 0, h > 0, w <= 4_000_000 / h,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Native snapshot exceeds bound") }
        bitmap.size = view.bounds.size
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            context.setFillColor(window.backgroundColor.cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if let image = bitmap.cgImage { context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        }
        return try unwrap(context.makeImage(), "Native snapshot failed")
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        let image = try nativeImage(window)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw failure("Snapshot PNG failed") }
        try data.write(to: url, options: .atomic)
    }
    private static func ownedComposite(parent: NSWindow, child: NSWindow, to url: URL) throws {
        let base = try nativeImage(parent), overlay = try nativeImage(child)
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: base.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Owned composite failed") }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let rectangle = parent.convertFromScreen(child.convertToScreen(child.contentView!.bounds))
        context.draw(overlay, in: rectangle)
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw failure("Owned composite PNG failed") }
        try data.write(to: url, options: .atomic)
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:] }
    private static func write(_ report: [String: Any], directory: URL) throws { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("save-workflow-ui.json"), options: .atomic) }
    private static func unwrap<T>(_ value: T?, _ text: String) throws -> T { guard let value else { throw failure(text) }; return value }
    private static func require(_ value: Bool, _ text: String) throws { if !value { throw failure(text) } }
    private static func failure(_ text: String) -> Error { PicShotError.message("Save workflow UI: " + text) }
}
