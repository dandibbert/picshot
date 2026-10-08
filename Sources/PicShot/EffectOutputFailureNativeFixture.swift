import AppKit
import CryptoKit

/// Installed-app proof of failure propagation. The injected patch failure uses
/// only owned synthetic pixels and private sinks; production render defaults stay intact.
@MainActor enum EffectOutputFailureNativeFixture {
    static let filename = "effect-output-failure.json"
    static let selectors = ["copyResult", "saveResult", "pinResult", "quickSaveResult", "saveCopyResult",
                            "recognizeResult", "translateResult", "applyResult", "exportResult"]

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        let files = FileManager.default, service = EditorOutputProjection.shared
        guard evidenceDirectory.isFileURL else { throw failure("Evidence directory must be local") }
        let drainDeadline = ProcessInfo.processInfo.systemUptime + 3
        while (service.isBusy || service.queue.operationCount != 0) && ProcessInfo.processInfo.systemUptime < drainDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !service.isBusy, service.reservedBytes == 0, service.queue.operationCount == 0,
              !service.queue.isSuspended, ImageExportController.activeSessionCount == 0,
              let executable = Bundle.main.executableURL else { throw failure("Output work was already active or executable identity missing") }
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let temporary = files.temporaryDirectory.appendingPathComponent("PicShot-Effect-Guard-" + UUID().uuidString)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let started = service.startedCount, completed = service.completedCount
        var report: [String: Any] = ["status": "running", "schemaVersion": 1,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "executablePath": executable.resolvingSymlinksInPath().path,
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier), "syntheticSource": true,
            "perCanvasFailureInjection": true, "productionOutputActions": true,
            "generalPasteboardReadOrWritten": false, "screenCaptureStarted": false,
            "permissionRequests": false, "networkUsed": false, "userFilesReadOrWritten": false,
            "standardUserDefaultsChanged": false,
            "scope": "Injected failure of the second linked blur/pixelation patch; all current output routes and native selectors, private prior-output bytes, annotation draft and release checks. No GPU failure reproduction claim."]
        do {
            var cases: [[String: Any]] = []
            for tool in [ImageEditorTool.blur, .pixelate] {
                for decorated in [false, true] {
                    for originalAware in [false, true] {
                        let (entry, probe) = try runCase(tool: tool, decorated: decorated,
                            originalAware: originalAware, directory: temporary)
                        let deadline = ProcessInfo.processInfo.systemUptime + 3
                        while !probe.released && ProcessInfo.processInfo.systemUptime < deadline {
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                        guard probe.released else { throw failure("Owned editor, canvas, window or presenter remained") }
                        cases.append(entry); report["cases"] = cases
                        try write(report, to: evidenceDirectory)
                    }
                }
            }
            guard cases.count == 8, !service.isBusy, service.reservedBytes == 0,
                  service.queue.operationCount == 0, service.startedCount == started,
                  service.completedCount == completed, ImageExportController.activeSessionCount == 0 else {
                throw failure("A rejected image started output work or ownership did not drain")
            }
            try files.removeItem(at: temporary)
            guard !files.fileExists(atPath: temporary.path) else { throw failure("Private output directory remained") }
            report["status"] = "passed"; report["caseCount"] = cases.count
            report["controllerReleaseCount"] = cases.count
            report["temporaryDirectoryRemoved"] = true
            report["activeProjectionJobsAfter"] = 0; report["projectionReservedBytesAfter"] = 0
            report["projectionJobsStarted"] = service.startedCount - started
            report["projectionJobsCompleted"] = service.completedCount - completed
            report["queuedOperationsAfter"] = service.queue.operationCount
            report["activeExportSessionsAfter"] = ImageExportController.activeSessionCount
            try write(report, to: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = String(error.localizedDescription.prefix(1024))
            try? write(report, to: evidenceDirectory); throw error
        }
    }

    private static func runCase(tool: ImageEditorTool, decorated: Bool, originalAware: Bool,
                                directory: URL) throws -> ([String: Any], ReleaseProbe) {
        let source = try raster(), sourceBefore = try pixels(source)
        let output = directory.appendingPathComponent(UUID().uuidString + ".png")
        let calls = Calls(), presenter = SaveWorkflowPresenter(isSmoke: true)
        let publish: (CGImage) -> Void = { image in calls.sinkDeliveries += 1; try? image.writePNG(to: output) }
        let originalSink: ((CGImage, CGImage) -> Bool)? = originalAware ? { _, image in publish(image); return true } : nil
        let editor = ImageEditorController(image: source, onSave: publish, onPin: publish, onOCR: publish,
            onTranslate: publish, onApply: { image in publish(image); return true },
            saveWorkflow: presenter, copyAction: publish, onPinWithOriginal: originalSink)
        let probe = ReleaseProbe(editor, presenter)
        defer { editor.close(); presenter.cancelAll() }
        editor.onOutputError = { error in
            calls.errors += 1
            if !(error is ImageEditorRenderingError) || error.localizedDescription.isEmpty { calls.wrongErrors += 1 }
        }
        editor.onClose = { calls.closes += 1 }
        let canvas = editor.annotationCanvas
        canvas.add(ImageAnnotation(tool: .redact, points: [CGPoint(x: 3, y: 4), CGPoint(x: 50, y: 40)]))
        editor.requestOutput(for: .copy) { image in
            calls.safeDeliveries += 1; try? image.writePNG(to: output)
        }
        let safeBytes = try Data(contentsOf: output)
        guard calls.safeDeliveries == 1, editor.outputDeliveryCount == 1, !safeBytes.isEmpty else {
            throw failure("Private successful-output control failed")
        }
        let regions = [CGRect(x: 5, y: 7, width: 17, height: 13), CGRect(x: 33, y: 21, width: 19, height: 15)]
        let group = UUID(), addition = UUID()
        let marks = regions.map { rect -> ImageAnnotation in
            var mark = ImageAnnotation(tool: tool, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)])
            mark.mosaicLink = AutomaticMosaicLink(groupID: group, additionID: addition, rootAdditionID: addition,
                target: rect, includedTargets: regions, excludedTargets: [], synchronizes: true)
            return mark
        }
        canvas.setContent(image: source, annotations: [])
        for mark in marks { canvas.add(mark) }
        if decorated { _ = try editor.applyOutputDecoration(ImageOutputDecoration(enabled: true, cornerRadius: 3, borderEnabled: true, borderWidth: 1)) }
        canvas.effectPatchRenderer = { _, region in
            calls.patchCalls += 1
            return calls.patchCalls == 2 ? nil : patch(region)
        }
        let draft = DraftState(editor), frame = editor.window?.frame
        var routes: [String] = [], native: [String] = []
        func checkRejected(_ action: () throws -> Void) throws {
            calls.patchCalls = 0
            let before = calls.errors
            try action()
            guard calls.patchCalls == 2, calls.errors == before + 1, calls.wrongErrors == 0,
                  calls.sinkDeliveries == 0, calls.closes == 0, !editor.isClosed,
                  editor.outputDeliveryCount == 1, editor.lastOutputRoute == .copy,
                  editor.window?.frame == frame, editor.initialOriginalImage === source,
                  DraftState(editor) == draft, try pixels(source) == sourceBefore,
                  try Data(contentsOf: output) == safeBytes, canvas.retainedPresentationRaster == nil,
                  !editor.outputProjectionIsPending, !EditorOutputProjection.shared.isBusy,
                  EditorOutputProjection.shared.reservedBytes == 0, presenter.controllers.isEmpty,
                  presenter.activeJobCount == 0, presenter.retainedInputBytes == 0,
                  ImageExportController.activeSessionCount == 0 else {
                throw failure("Failed effect reached output, changed draft/prior bytes, or retained work")
            }
        }
        for route in ImageEditorOutputRoute.allCases {
            try checkRejected { editor.requestOutput(for: route, close: true, completion: publish) }
            routes.append(route.rawValue)
        }
        for selector in selectors {
            try checkRejected { try send(selector, to: editor) }
            native.append(selector)
        }
        try send("undoEdit", to: editor); try send("redoEdit", to: editor)
        guard DraftState(editor) == draft else { throw failure("Draft undo/redo did not survive failed output") }
        // Restore only the synthetic patch provider and retry through the production
        // route. Undo decoration for a synchronous result; never touch a user sink.
        canvas.effectPatchRenderer = { _, region in patch(region) }
        if decorated { try send("undoEdit", to: editor) }
        var retried: CGImage?
        editor.requestOutput(for: .copy) { retried = $0 }
        guard let retried, retried.width == source.width, retried.height == source.height,
              try pixels(retried) != sourceBefore, editor.outputDeliveryCount == 2,
              try Data(contentsOf: output) == safeBytes, calls.errors == routes.count + native.count,
              calls.sinkDeliveries == 0, presenter.controllers.isEmpty else { throw failure("Safe retry or private output retention failed") }
        return (["tool": tool.rawValue, "decorated": decorated, "originalAwarePin": originalAware,
                 "rejectedRoutes": routes, "rejectedNativeSelectors": native,
                 "failedRenderRequests": routes.count + native.count, "errorCallbacks": calls.errors,
                 "sinkDeliveriesDuringFailures": calls.sinkDeliveries, "wrongErrorCallbacks": calls.wrongErrors,
                 "successControlDeliveries": calls.safeDeliveries, "retryDeliveries": 1,
                 "draftPreserved": true, "undoRedoPreserved": true, "sourcePixelsUnchanged": true,
                 "priorOutputPreserved": true, "priorOutputSHA256": digest(safeBytes),
                 "priorOutputBytes": safeBytes.count, "failedPatchPosition": 2,
                 "closeCallbacksDuringFailures": calls.closes, "status": "passed"], probe)
    }

    private struct DraftState: Equatable {
        let image: ObjectIdentifier, annotations: [MarkState], decoration: ImageOutputDecoration
        @MainActor init(_ editor: ImageEditorController) {
            image = ObjectIdentifier(editor.annotationCanvas.image)
            annotations = editor.annotationCanvas.annotations.map(MarkState.init)
            decoration = editor.outputDecoration
        }
    }
    private struct MarkState: Equatable {
        let id: UUID, tool: String, points: [CGPoint], color: [CGFloat]
        let width: CGFloat, opacity: CGFloat, rotation: CGFloat
        let group: UUID?, addition: UUID?, root: UUID?, target: CGRect?
        let included: [CGRect], excluded: [CGRect], synchronizes: Bool?
        init(_ mark: ImageAnnotation) {
            id = mark.id; tool = mark.tool.rawValue; points = mark.points; color = mark.color.components ?? []
            width = mark.lineWidth; opacity = mark.opacity; rotation = mark.rotation
            group = mark.mosaicLink?.groupID; addition = mark.mosaicLink?.additionID; root = mark.mosaicLink?.rootAdditionID
            target = mark.mosaicLink?.target; included = mark.mosaicLink?.includedTargets ?? []
            excluded = mark.mosaicLink?.excludedTargets ?? []; synchronizes = mark.mosaicLink?.synchronizes
        }
    }
    private final class Calls {
        var patchCalls = 0, errors = 0, wrongErrors = 0, sinkDeliveries = 0, closes = 0, safeDeliveries = 0
    }
    private final class ReleaseProbe {
        weak var editor: ImageEditorController?, window: NSWindow?, canvas: ImageEditorCanvas?, presenter: SaveWorkflowPresenter?
        @MainActor init(_ editor: ImageEditorController, _ presenter: SaveWorkflowPresenter) {
            self.editor = editor; window = editor.window; canvas = editor.annotationCanvas; self.presenter = presenter
        }
        var released: Bool { editor == nil && window == nil && canvas == nil && presenter == nil }
    }
    private static func send(_ selector: String, to editor: ImageEditorController) throws {
        guard NSApp.sendAction(NSSelectorFromString(selector), to: editor, from: nil) else { throw failure("Missing native selector " + selector) }
    }
    private static func raster() throws -> CGImage {
        guard let image = patch(CGRect(x: 0, y: 0, width: 96, height: 72), shade: 0.9) else { throw failure("Source allocation failed") }
        return image
    }
    private static func patch(_ region: CGRect, shade: CGFloat = 0.2) -> CGImage? {
        let width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0, width <= 96, height <= 72,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: shade, alpha: 1)); context.fill(CGRect(origin: .zero, size: region.size))
        return context.makeImage()
    }
    private static func pixels(_ image: CGImage) throws -> [UInt8] { try EditorOutputDecorationNativeFixture.raster(image) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func write(_ report: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
    private static func failure(_ message: String) -> Error { PicShotError.message("Effect output guard: " + message) }
}
