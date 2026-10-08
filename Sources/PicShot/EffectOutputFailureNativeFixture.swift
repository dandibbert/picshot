import AppKit
import CryptoKit
import PicShotCore

/// Installed-app proof over owned synthetic pixels and private output sinks.
/// The 0.16 document, crop, history and production renderer remain unchanged.
@MainActor enum EffectOutputFailureNativeFixture {
    static let filename = "effect-output-failure.json"
    static let selectors = ["copyResult", "saveResult", "pinResult", "quickSaveResult", "saveCopyResult",
                            "recognizeResult", "translateResult", "applyResult", "exportResult"]
    private enum SinkMode: String, CaseIterable { case legacy, originalAware, editable }

    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        let files = FileManager.default, service = EditorOutputProjection.shared
        guard evidenceDirectory.isFileURL else { throw failure("Evidence directory must be local") }
        try await drain(service)
        guard !service.queue.isSuspended, ImageExportController.activeSessionCount == 0,
              let executable = Bundle.main.executableURL else { throw failure("Output work was active or executable identity missing") }
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let temporary = files.temporaryDirectory.appendingPathComponent("PicShot-Editable-Effect-Guard-" + UUID().uuidString)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let started = service.startedCount, completed = service.completedCount
        var report: [String: Any] = ["status": "running", "schemaVersion": 2,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "executablePath": executable.resolvingSymlinksInPath().path,
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier), "syntheticSource": true,
            "perCanvasFailureInjection": true, "productionOutputActions": true,
            "generalPasteboardReadOrWritten": false, "screenCaptureStarted": false,
            "permissionRequests": false, "networkUsed": false, "userFilesReadOrWritten": false,
            "standardUserDefaultsChanged": false, "originalImageCopyTestedAsAnnotatedOutput": false,
            "nonNilGPUCorruptionCovered": false, "onscreenConcealmentCovered": false,
            "scope": "Injected nil second required linked blur/pixelation patch across current-output routes and native selectors. Exact editable document, original/base identities and pixels, nondestructive crop, full undo/redo, prior private output/document, cache clearing, unchanged-draft retry and bounded cleanup. Explicit original-image copy bypasses current marks and is outside this guard. No claim for nonnil GPU corruption or onscreen concealment."]
        do {
            var cases: [[String: Any]] = []
            for tool in [ImageEditorTool.blur, .pixelate] {
                for decorated in [false, true] {
                    for cropped in [false, true] {
                        for sink in SinkMode.allCases {
                            let (entry, probe) = try await runCase(tool: tool, decorated: decorated,
                                cropped: cropped, sink: sink, directory: temporary)
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
            }
            try await drain(service)
            guard cases.count == 24, service.startedCount - started == 12,
                  service.completedCount - completed == 12, ImageExportController.activeSessionCount == 0 else {
                throw failure("Unexpected output work or incomplete release")
            }
            try files.removeItem(at: temporary)
            guard !files.fileExists(atPath: temporary.path) else { throw failure("Private output directory remained") }
            report["status"] = "passed"; report["caseCount"] = cases.count
            report["controllerReleaseCount"] = cases.count; report["temporaryDirectoryRemoved"] = true
            report["activeProjectionJobsAfter"] = 0; report["projectionReservedBytesAfter"] = 0
            // The twelve decorated successful retries run real projection jobs.
            // Each rejected request separately proves no job was started.
            report["projectionJobsStarted"] = service.startedCount - started
            report["projectionJobsCompleted"] = service.completedCount - completed
            report["projectionJobsStartedDuringFailures"] = 0
            report["queuedOperationsAfter"] = service.queue.operationCount
            report["activeExportSessionsAfter"] = ImageExportController.activeSessionCount
            try write(report, to: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = String(error.localizedDescription.prefix(1024))
            try? write(report, to: evidenceDirectory); throw error
        }
    }

    private static func runCase(tool: ImageEditorTool, decorated: Bool, cropped: Bool, sink: SinkMode,
                                directory: URL) async throws -> ([String: Any], ReleaseProbe) {
        let original = try raster()
        let baseCrop = CGRect(x: 8, y: 8, width: 80, height: 56)
        guard let base = ImageEditorRenderer.crop(image: original, to: baseCrop) else { throw failure("Base crop allocation failed") }
        let originalBefore = try pixels(original), baseBefore = try pixels(base)
        let output = directory.appendingPathComponent(UUID().uuidString + ".png")
        let documentOutput = directory.appendingPathComponent(UUID().uuidString + ".annotations")
        let calls = Calls(), presenter = SaveWorkflowPresenter(isSmoke: true)
        let publish: (CGImage) -> Void = { image in calls.sinkDeliveries += 1; try? image.writePNG(to: output) }
        let originalSink: ((CGImage, CGImage) -> Bool)? = sink == .originalAware ? { _, image in publish(image); return true } : nil
        let editableSink: ((CGImage, EditableCapturePayload) throws -> Void)? = sink == .editable ? { image, payload in
            publish(image)
            try EditableAnnotationDocumentCodec.encode(payload.document).write(to: documentOutput, options: .atomic)
        } : nil
        let editor = ImageEditorController(image: base, onSave: publish, onPin: publish, onOCR: publish,
            onTranslate: publish, onApply: { image in publish(image); return true },
            saveWorkflow: presenter, copyAction: publish, onPinWithOriginal: originalSink,
            onSaveEditable: editableSink, onPinEditable: editableSink, onApplyEditable: editableSink)
        let probe = ReleaseProbe(editor, presenter)
        defer { editor.close(); presenter.cancelAll() }
        editor.onOutputError = { error in
            calls.errors += 1
            if !(error is ImageEditorRenderingError) || error.localizedDescription.isEmpty { calls.wrongErrors += 1 }
        }
        editor.onClose = { calls.closes += 1 }
        let canvas = editor.annotationCanvas
        let safeMark = ImageAnnotation(tool: .redact, points: [CGPoint(x: 3, y: 4), CGPoint(x: 24, y: 16)])
        var document = EditableAnnotationDocument(originalAssetID: UUID(), originalPixelWidth: original.width,
            originalPixelHeight: original.height, baseAssetID: UUID(), basePixelWidth: base.width,
            basePixelHeight: base.height, baseCropInOriginal: baseCrop, baseProvenance: .originalCapture,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), captureTimeZoneIdentifier: "UTC",
            captureTimestampKnown: true, annotations: [safeMark])
        document.numberSequence.setNext(7); document.numberSequence.closesGapsOnDelete = true
        try editor.restoreEditablePayload(EditableCapturePayload(document: document, originalImage: original, baseImage: base))
        let initial = try DraftState(editor)
        editor.requestOutput(for: .copy) { image in
            calls.safeDeliveries += 1; try? image.writePNG(to: output)
        }
        try initial.document.write(to: documentOutput, options: .atomic)
        let safeBytes = try Data(contentsOf: output), safeDocumentBytes = try Data(contentsOf: documentOutput)
        guard calls.safeDeliveries == 1, editor.outputDeliveryCount == 1, !safeBytes.isEmpty,
              safeDocumentBytes == initial.document else { throw failure("Private successful-output control failed") }
        var history = [initial]
        let regions = [CGRect(x: 0, y: 2, width: 17, height: 13), CGRect(x: 33, y: 21, width: 19, height: 15)]
        let group = UUID(), addition = UUID()
        for rect in regions {
            var mark = ImageAnnotation(tool: tool, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)])
            mark.mosaicLink = AutomaticMosaicLink(groupID: group, additionID: addition, rootAdditionID: addition,
                target: rect, includedTargets: regions, excludedTargets: [CGRect(x: 60, y: 40, width: 7, height: 7)], synchronizes: true)
            canvas.add(mark); history.append(try DraftState(editor))
        }
        if cropped {
            canvas.cropRect = CGRect(x: 4, y: 6, width: 64, height: 40)
            try send("applyCrop", to: editor); history.append(try DraftState(editor))
            guard canvas.cropViewportInBase == CGRect(x: 4, y: 6, width: 64, height: 40) else { throw failure("Native nondestructive crop failed") }
        }
        if decorated {
            guard try editor.applyOutputDecoration(ImageOutputDecoration(enabled: true, cornerRadius: 3, borderEnabled: true, borderWidth: 1)) else {
                throw failure("Decoration control did not change metadata")
            }
            history.append(try DraftState(editor))
        }
        let draft = try DraftState(editor), frame = editor.window?.frame
        guard draft.original != draft.base, draft.document != initial.document,
              editor.initialOriginalImage === original, canvas.image === base else { throw failure("Original/base separation or editable layers missing") }
        // Keep a real redo branch alive during every failure, so an output action
        // that silently clears redo cannot pass merely by preserving undo history.
        canvas.setNextNumber(11)
        let redoBranch = try DraftState(editor)
        try send("undoEdit", to: editor)
        guard redoBranch != draft, try DraftState(editor) == draft else { throw failure("Existing redo control failed") }
        func verifyRedoBranch() throws {
            try send("redoEdit", to: editor)
            guard try DraftState(editor) == redoBranch else { throw failure("Output action discarded the pre-existing redo branch") }
            try send("undoEdit", to: editor)
            guard try DraftState(editor) == draft else { throw failure("Redo branch could not return to the unchanged draft") }
        }
        // Prime an actual successful presentation cache, then prove injection invalidates it.
        canvas.effectPatchRenderer = { _, region in patch(region) }
        guard let safeCache = canvas.rasterForBoundaryPreview(), canvas.retainedPresentationRaster != nil else {
            throw failure("Successful presentation cache control failed")
        }
        let safeCacheBytes = try pixels(safeCache)
        canvas.effectPatchRenderer = { _, region in
            calls.patchCalls += 1
            return calls.patchCalls.isMultiple(of: 2) ? nil : patch(region)
        }
        guard canvas.retainedPresentationRaster == nil else { throw failure("Prior successful presentation cache survived failure injection") }
        for _ in 0..<2 {
            calls.patchCalls = 0
            guard canvas.rasterForBoundaryPreview() == nil, calls.patchCalls == 2,
                  canvas.retainedPresentationRaster == nil else { throw failure("Incomplete presentation raster was cached or returned") }
        }
        let service = EditorOutputProjection.shared, started = service.startedCount, completed = service.completedCount
        var routes: [String] = [], native: [String] = []
        func unchanged() throws -> Bool {
            try DraftState(editor) == draft && pixels(original) == originalBefore && pixels(base) == baseBefore &&
                Data(contentsOf: output) == safeBytes && Data(contentsOf: documentOutput) == safeDocumentBytes &&
                pixels(safeCache) == safeCacheBytes
        }
        func checkRejected(_ action: () throws -> Void) throws {
            calls.patchCalls = 0
            let before = calls.errors
            try action()
            guard calls.patchCalls == 2, calls.errors == before + 1, calls.wrongErrors == 0,
                  calls.sinkDeliveries == 0, calls.closes == 0, !editor.isClosed,
                  editor.outputDeliveryCount == 1, editor.lastOutputRoute == .copy,
                  editor.window?.frame == frame, try unchanged(), canvas.retainedPresentationRaster == nil,
                  !editor.outputProjectionIsPending, !service.isBusy, service.reservedBytes == 0,
                  service.queue.operationCount == 0, service.startedCount == started, service.completedCount == completed,
                  presenter.controllers.isEmpty, presenter.activeJobCount == 0, presenter.retainedInputBytes == 0,
                  ImageExportController.activeSessionCount == 0 else {
                throw failure("Failed effect reached output, changed editable draft/prior bytes, or retained work")
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
        try verifyRedoBranch()
        // Exercise every recorded layer/crop/decoration snapshot in both directions.
        // A single no-op undo/redo pair would not establish preserved history.
        for state in history.dropLast().reversed() {
            try send("undoEdit", to: editor)
            guard try DraftState(editor) == state else { throw failure("Failed output changed an undo snapshot") }
        }
        for state in history.dropFirst() {
            try send("redoEdit", to: editor)
            guard try DraftState(editor) == state else { throw failure("Failed output changed a redo snapshot") }
        }
        guard try unchanged(), canvas.retainedPresentationRaster == nil else { throw failure("Undo/redo did not preserve complete editable draft") }
        // Retry with the full crop and decoration still applied, through the real projection.
        calls.patchCalls = 0
        canvas.effectPatchRenderer = { _, region in calls.patchCalls += 1; return patch(region) }
        guard let referenceFull = ImageEditorRenderer.render(image: base, annotations: canvas.annotations,
            effectPatchRenderer: { _, region in patch(region) }) else { throw failure("Successful full-base reference failed") }
        let referenceVisible: CGImage
        if cropped {
            guard let image = ImageEditorRenderer.crop(image: referenceFull, to: CGRect(x: 4, y: 6, width: 64, height: 40)) else {
                throw failure("Successful reference crop failed")
            }
            referenceVisible = image
        } else { referenceVisible = referenceFull }
        let expected = try ImageOutputDecorationRenderer.project(flattened: referenceVisible, decoration: editor.outputDecoration)
        var retried: CGImage?
        editor.requestOutput(for: .copy) { retried = $0 }
        guard calls.patchCalls == 2 else { throw failure("Retry skipped required linked effect patches") }
        let retryDeadline = ProcessInfo.processInfo.systemUptime + 3
        while retried == nil && editor.outputProjectionIsPending && ProcessInfo.processInfo.systemUptime < retryDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await drain(service)
        guard let retried, retried.width == expected.width, retried.height == expected.height,
              try pixels(retried) == pixels(expected), try pixels(referenceFull) != baseBefore,
              try unchanged(), editor.outputDeliveryCount == 2, !editor.outputProjectionIsPending,
              calls.errors == routes.count + native.count, calls.sinkDeliveries == 0,
              calls.closes == 0, presenter.controllers.isEmpty, presenter.activeJobCount == 0,
              presenter.retainedInputBytes == 0, ImageExportController.activeSessionCount == 0,
              service.startedCount - started == (decorated ? 1 : 0),
              service.completedCount - completed == (decorated ? 1 : 0) else {
            throw failure("Unchanged-draft retry, expected projection, private prior output or cleanup failed")
        }
        try verifyRedoBranch()
        guard try unchanged() else { throw failure("Successful retry altered existing undo/redo state") }
        return (["tool": tool.rawValue, "decorated": decorated, "cropped": cropped, "sinkMode": sink.rawValue,
                 "rejectedRoutes": routes, "rejectedNativeSelectors": native,
                 "failedRenderRequests": routes.count + native.count, "errorCallbacks": calls.errors,
                 "sinkDeliveriesDuringFailures": calls.sinkDeliveries, "wrongErrorCallbacks": calls.wrongErrors,
                 "successControlDeliveries": calls.safeDeliveries, "retryDeliveries": 1,
                 "draftPreserved": true, "undoRedoPreserved": true, "undoRedoSteps": history.count - 1,
                 "existingRedoBranchPreserved": true, "existingRedoBranchRoundTrips": 2,
                 "sourcePixelsUnchanged": true, "originalIdentityPreserved": true, "baseIdentityPreserved": true,
                 "originalPixelsUnchanged": true, "basePixelsUnchanged": true, "editableDocumentPreserved": true,
                 "cropViewportPreserved": true, "baseCropPreserved": true, "numberSequencePreserved": true,
                 "decorationsPreserved": true, "priorEditableDocumentPreserved": true,
                 "presentationCacheCleared": true, "failureNeverCached": true, "cacheFailureAttempts": 2,
                 "retryMatchesExpectedProjection": true, "retryPreservesEditableDocument": true,
                 "projectionJobsStartedDuringFailures": 0,
                 "priorOutputPreserved": true, "priorOutputSHA256": digest(safeBytes), "priorOutputBytes": safeBytes.count,
                 "priorEditableDocumentSHA256": digest(safeDocumentBytes), "priorEditableDocumentBytes": safeDocumentBytes.count,
                 "editableDocumentSHA256": digest(draft.document), "editableDocumentBytes": draft.document.count,
                 "originalSHA256": digest(Data(originalBefore)), "baseSHA256": digest(Data(baseBefore)),
                 "failedPatchPosition": 2, "closeCallbacksDuringFailures": calls.closes, "status": "passed"], probe)
    }

    /// Canonical encoding covers every persisted field, including all annotation
    /// attributes, link metadata, identifiers, timestamps, number sequence and crop.
    private struct DraftState: Equatable {
        let original: ObjectIdentifier, base: ObjectIdentifier, document: Data
        @MainActor init(_ editor: ImageEditorController) throws {
            let payload = try editor.editablePayload()
            original = ObjectIdentifier(payload.originalImage); base = ObjectIdentifier(payload.baseImage)
            document = try EditableAnnotationDocumentCodec.encode(payload.document)
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
        @MainActor var released: Bool { editor == nil && window == nil && canvas == nil && presenter == nil }
    }
    private static func drain(_ service: EditorOutputProjection) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while (service.isBusy || service.queue.operationCount != 0) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !service.isBusy, service.reservedBytes == 0, service.queue.operationCount == 0 else { throw failure("Output ownership did not drain") }
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
    private static func failure(_ message: String) -> Error { PicShotError.message("Editable effect output guard: " + message) }
}
