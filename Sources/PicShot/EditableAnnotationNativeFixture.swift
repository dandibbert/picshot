import AppKit
import CryptoKit
import ImageIO
import PicShotCore

/// Installed-app entry point. Own synthetic files/windows only; no screen capture,
/// input posted to other applications, permission requests or clipboard writes.
@MainActor enum EditableAnnotationNativeFixture {
    private typealias O = EditableAnnotationFixtureObservation
    private static let warmups = 2, measured = 8, deadlineSeconds = 300.0
    private static let assertions = ["nativeHistorySave", "historyReopen", "restoredSelectTool", "nativeEditUndo",
        "cancelKeptSavedContent", "durableFailureKeptDraft", "durableRetry", "pinSpaceReopen", "pinApply",
        "cropFullStackPixels", "uncropUndo", "hiddenGeometry", "hiddenExportAnnotated", "originalExportSeparate", "legacyRaster"]

    static func verify(evidenceDirectory: URL, includeResources: Bool = false) async throws -> [String: Any] {
        _ = NSApplication.shared
        try O.require(evidenceDirectory.isFileURL && NSScreen.main != nil, "Owned native display/evidence directory unavailable")
        try O.beginDiagnostic(includeResources: includeResources)
        try EditableDrawingPairDiagnostic.begin(includeResources: includeResources)
        defer { O.diagnostic = nil; EditableDrawingPairDiagnostic.process = nil }
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + deadlineSeconds
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshot-editable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var identities = Set<O.OwnedFileIdentity>()
        let sampler = EditableAnnotationMemorySampler(); defer { sampler.stop() }
        let executable = try O.required(Bundle.main.executableURL, "Bundle executable missing")
        let source = Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var report: [String: Any] = ["schemaVersion": 2, "status": "running", "sourceCommit": source,
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path, "architecture": architecture,
            "executableSHA256": try O.fileDigest(executable),
            "executableBytes": try executable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            "deadlineSeconds": deadlineSeconds, "resourcesRequested": includeResources,
            "entryMemory": try O.memory(), "functionalCases": [[String: Any]](), "resources": NSNull(),
            "flags": ["syntheticSource": true, "nativeEditorPinControls": true, "realPNGAndMetadataReads": true,
                "screenCaptureStarted": false, "permissionRequests": false, "globalInputPosted": false,
                "networkUsed": false, "generalPasteboardUsed": false, "standardDefaultsWritten": false,
                "memoryPressureOrPurgeRequested": false, "physicalMultiDisplayVerified": false,
                "appMainHistoryGridDoubleClickExercised": false, "memoryStabilityAssessed": false, "zeroLeakClaim": false],
            "historyReopenEntryPoint": "HistoryStore.editablePayload + ImageEditorController.restoreEditablePayload",
            "memoryScope": "Owned 4K original/base costs and canonical normalization are tracked alongside self-task RSS, footprint and volatile ledgers. 50ms samples can miss transients and exclude WindowServer/GPU. Positive growth remains visible; completion is not a plateau or leak verdict."]
        do {
            var cases: [[String: Any]] = []
            for (profile, width, height) in [("small", 640, 360), ("4k", 3840, 2160)] {
                sampler.setPhase("functional-" + profile)
                try O.diagnostic?.beginWorkload("functional-" + profile)
                let directory = root.appendingPathComponent(profile)
                let lifetime = EditableAnnotationLifetime()
                var result = try await functional(directory: directory, width: width, height: height,
                    lifetime: lifetime, identities: &identities, deadline: deadline,
                    visualDirectory: profile == "small" ? evidenceDirectory : nil)
                try await release(lifetime, deadline: deadline)
                try O.diagnostic?.checkpoint("workload-released")
                result["ownershipAfterRelease"] = lifetime.report
                result["windowContentGraphsAfterRelease"] = lifetime.windowContentGraphs
                result["ownedOpenDescriptorsAfter"] = try O.ownedFileDescriptors(root, identities: identities).count
                try O.require((result["ownedOpenDescriptorsAfter"] as? Int) == 0, "Functional owned file descriptor remained open")
                result["afterReleaseMemory"] = try O.memory(); result["profile"] = profile
                cases.append(result); report["functionalCases"] = cases
                try write(report, directory: evidenceDirectory)
            }
            if includeResources {
                sampler.setPhase("resource-before-input")
                report["resources"] = try await resources(root: root, sampler: sampler, identities: &identities, deadline: deadline) { partial in
                    report["resources"] = partial
                    try write(report, directory: evidenceDirectory)
                }
            }
            identities.formUnion(try O.ownedFileIdentities(root))
            try FileManager.default.removeItem(at: root)
            try await settle(deadline)
            let handles = try O.ownedFileDescriptors(root, identities: identities)
            try O.require(handles.isEmpty && !FileManager.default.fileExists(atPath: root.path), "Temporary root or unlinked owned descriptor survived cleanup")
            try O.require(!EditorOutputProjection.shared.isBusy && ImageExportController.activeSessionCount == 0,
                          "Output job/window survived fixture cleanup")
            sampler.setPhase("final-cleanup"); sampler.stop()
            try O.diagnostic?.checkpoint("final-cleanup")
            report["sampledMemory"] = sampler.report
            report["finalMemory"] = try O.memory()
            report["ownedTemporaryDirectoryRemoved"] = true; report["ownedOpenDescriptorsAfterCleanup"] = handles.count
            report["status"] = "passed"; report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try write(report, directory: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? FileManager.default.removeItem(at: root)
            report["ownedTemporaryDirectoryRemoved"] = !FileManager.default.fileExists(atPath: root.path)
            report["ownedOpenDescriptorsAfterCleanup"] = try? O.ownedFileDescriptors(root, identities: identities).count
            sampler.stop(); report["sampledMemory"] = sampler.report
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try? write(report, directory: evidenceDirectory); throw error
        }
    }

    private static func functional(directory: URL, width: Int, height: Int, lifetime: EditableAnnotationLifetime,
        identities: inout Set<O.OwnedFileIdentity>, deadline: Double, visualDirectory: URL? = nil) async throws -> [String: Any] {
        try O.require(visualDirectory == nil || (width == 640 && height == 360), "Visual evidence is restricted to the small functional profile")
        var visualEvidence: [[String: Any]] = []
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = HistoryStore(directory: directory.appendingPathComponent("history"))
        lifetime.observe(history, role: "store")
        let pinStore = try PinSessionStore(directory: directory.appendingPathComponent("pins"))
        lifetime.observe(pinStore, role: "store")
        let session = PinSessionCoordinator(store: pinStore, presentWindows: false,
            ocrPreferences: PinOCRPreferences(defaults: nil),
            makeImageController: { PinController(originalImage: $0, currentImage: $1, isModified: $2, defaults: nil) })
        defer { try? session.prepareForTermination() }
        var savedID: UUID?, pinID: UUID?, errors = 0
        try O.diagnostic?.checkpoint("input-generation")
        let source = try makeSource(width: width, height: height), base = try derivedBase(source)
        lifetime.image(source, role: "original"); lifetime.image(base, role: "base")
        let sourceHash = try O.digest(source, lifetime: lifetime, label: "source"), baseHash = try O.digest(base, lifetime: lifetime, label: "base")
        try O.require(sourceHash != baseHash, "Original/base fixture must contain different pixels")
        try O.diagnostic?.checkpoint("seed-native-render-crop")
        let seed = ImageEditorController(image: base, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in },
            saveWorkflow: SaveWorkflowPresenter(isSmoke: true), copyAction: { _ in },
            onSaveEditable: { output, payload in savedID = try history.add(output, title: "Owned editable fixture", editable: payload).id },
            baseProvenance: .derivedRaster)
        defer { seed.close() }; lifetime.editor(seed); seed.useOriginalImage(source)
        seed.onOutputError = { _ in errors += 1 }
        seed.annotationCanvas.setContent(image: base, annotations: marks(width: width))
        seed.showWindow(nil); try await settle(deadline)
        let crop = viewport(width: width)
        try selectTool(.crop, editor: seed)
        try drag(seed.annotationCanvas, CGPoint(x: crop.minX + 0.25, y: crop.minY + 0.25),
            CGPoint(x: crop.maxX - 0.25, y: crop.maxY - 0.25))
        try click("editor.applyCrop", editor: seed)
        let full = try O.required(ImageEditorRenderer.render(image: base, annotations: seed.annotationCanvas.annotations), "Full effect render failed")
        lifetime.image(full, role: "current")
        let expectedCrop = try O.required(ImageEditorRenderer.crop(image: full, to: crop), "Reference crop failed")
        lifetime.image(expectedCrop, role: "current")
        try O.require(try O.digest(expectedCrop, lifetime: lifetime, label: "reference-crop") == O.digest(O.required(seed.annotationCanvas.flattened(), "Crop output failed"), lifetime: lifetime, label: "actual-crop"), "Crop changed off-viewport effect sampling")
        _ = try seed.applyOutputDecoration(decoration)
        let expected = try ImageOutputDecorationRenderer.project(flattened: expectedCrop, decoration: decoration)
        lifetime.image(expected, role: "current")
        let expectedHash = try O.digest(expected, lifetime: lifetime, label: "decorated-reference")
        try O.diagnostic?.checkpoint("history-save-reopen-decode")
        try editorMenu("saveResult", seed); try await outputDrained(seed, deadline)
        try O.require(errors == 0, "Seed save failed")
        let id = try O.required(savedID, "Native history save did not commit")
        try click("editor.cancel", editor: seed)
        try O.require(seed.isClosed, "Native seed cancel did not close")
        let record = try O.required(history.records.first { $0.id == id }, "Saved record missing")
        let savedAsset = try O.required(record.editableCapture, "Saved layers missing")
        identities.formUnion(try O.ownedFileIdentities(directory))
        let reloaded = HistoryStore(directory: history.directory); lifetime.observe(reloaded, role: "store")
        let loadedRecord = try O.required(reloaded.records.first { $0.id == id }, "Fresh history failed to reopen")
        let payload = try O.required(reloaded.editablePayload(for: loadedRecord), "Editable history fell back to raster")
        lifetime.image(payload.originalImage, role: "original"); lifetime.image(payload.baseImage, role: "base")
        let current = try O.required(reloaded.image(for: loadedRecord), "Persisted current PNG unreadable")
        lifetime.image(current, role: "current")
        let persistedHash = try O.digest(current, lifetime: lifetime, label: "history-persisted-current")
        var latestHistoryID = id
        try O.diagnostic?.checkpoint("history-restore-edit-failure-retry")
        let editor = ImageEditorController(image: payload.baseImage, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in },
            saveWorkflow: SaveWorkflowPresenter(isSmoke: true), copyAction: { _ in },
            onSaveEditable: { output, draft in latestHistoryID = try reloaded.add(output, title: "Owned saved revision", editable: draft).id },
            onPinEditable: { output, draft in pinID = try session.add(originalImage: draft.originalImage, currentImage: output, editable: draft) })
        defer { editor.close() }; try editor.restoreEditablePayload(payload); lifetime.editor(editor)
        editor.onOutputError = { _ in errors += 1 }
        editor.showWindow(nil); try await settle(deadline)
        try O.require(editor.annotationCanvas.tool == .select && editor.annotationCanvas.image.width == width,
                      "Restored editor lost full base or select default")
        let replay = try ImageOutputDecorationRenderer.project(flattened: O.required(editor.annotationCanvas.flattened(), "Reopened output missing"), decoration: editor.outputDecoration)
        lifetime.image(replay, role: "current")
        let replayHash = try O.digest(replay, lifetime: lifetime, label: "history-replayed")
        try O.require(expectedHash == persistedHash && persistedHash == replayHash, "Saved current differs from restored layers/crop/decoration")
        let originalDocument = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
        try editorMenu("restoreFullCrop", editor)
        try O.require(editor.annotationCanvas.cropViewportInBase == nil, "Uncrop did not restore full base")
        try undo(editor); try O.require(editor.annotationCanvas.cropViewportInBase == crop, "Uncrop undo lost viewport")
        try nativeMark(editor); try undo(editor)
        try O.require(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document) == originalDocument, "Native edit undo changed document")
        try nativeMark(editor)
        let draft = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
        let beforeFiles = try fileManifest(history.directory)
        var stagedIdentities = Set<O.OwnedFileIdentity>()
        reloaded.failureInjector = { point in
            if point == .beforeIndexCommit {
                stagedIdentities.formUnion(try O.ownedFileIdentities(directory))
                throw O.failure("Injected failure before durable index commit")
            }
        }
        try editorMenu("saveResult", editor); try await outputDrained(editor, deadline)
        identities.formUnion(stagedIdentities)
        try O.require(errors == 1 && !editor.isClosed && (try fileManifest(history.directory)) == beforeFiles,
                      "Failed save changed durable files or dismissed draft")
        try O.require(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document) == draft, "Failed save lost editable draft")
        reloaded.failureInjector = nil
        try undo(editor)
        try editorMenu("saveResult", editor); try await outputDrained(editor, deadline)
        try O.require(errors == 1 && editor.annotationCanvas.cropViewportInBase == crop && latestHistoryID != id, "Retry did not add a saved revision")
        let savedAgain = try O.required(reloaded.records.first { $0.id == latestHistoryID }, "Saved revision missing")
        let savedAgainPayload = try O.required(reloaded.editablePayload(for: savedAgain), "Saved revision did not reopen")
        lifetime.image(savedAgainPayload.originalImage, role: "original"); lifetime.image(savedAgainPayload.baseImage, role: "base")
        try O.require(reloaded.records.contains { $0.id == id }
            && (try EditableAnnotationDocumentCodec.encode(savedAgainPayload.document)) == originalDocument,
            "Saving a reopened item overwrote the old history or changed layers")
        try O.diagnostic?.checkpoint("pin-create-reopen-hidden-preview")
        try editorMenu("pinResult", editor); try await outputDrained(editor, deadline)
        let pinnedID = try O.required(pinID, "Native pin did not commit")
        try click("editor.cancel", editor: editor)
        let initialPin = try O.required(session.liveControllers[pinnedID], "Pinned controller missing")
        lifetime.observe(initialPin, role: "pin")
        lifetime.image(initialPin.image, role: "original"); lifetime.image(initialPin.currentImage, role: "current")
        if let window = initialPin.window { lifetime.observe(window, role: "window") }
        initialPin.close(); try session.openPin(id: pinnedID)
        let pin = try O.required(session.liveControllers[pinnedID], "Saved pin did not reopen")
        lifetime.observe(pin, role: "pin"); lifetime.image(pin.image, role: "original"); lifetime.image(pin.currentImage, role: "current")
        if let window = pin.window { lifetime.observe(window, role: "window") }
        pin.onAnnotationError = { _ in errors += 1 }; pin.showWindow(nil)
        try pinMenu("toggleAnnotationsHidden", pin); try await visibilityDrained(pin, deadline)
        try O.require(pin.annotationsHidden && pin.displayedImage.width == pin.currentImage.width && pin.displayedImage.height == pin.currentImage.height,
                      "Hidden preview changed geometry")
        lifetime.image(pin.displayedImage, role: "current")
        let hiddenHash = try O.digest(pin.displayedImage, lifetime: lifetime, label: "hidden-preview")
        if let visualDirectory {
            let window = try O.required(pin.window, "Pin window missing for evidence")
            let previousAppearance = window.appearance
            window.appearance = NSAppearance(named: .darkAqua)
            try await settle(deadline)
            visualEvidence.append(try snapshotPin(pin, name: "editable-hidden-pin.png", kind: "hiddenPin", directory: visualDirectory, crop: crop))
            try pinMenu("toggleAnnotationsHidden", pin)
            try O.require(!pin.annotationsHidden, "Visual restore action failed")
            try await settle(deadline)
            visualEvidence.append(try snapshotPin(pin, name: "editable-restored-pin.png", kind: "restoredPin", directory: visualDirectory, crop: crop))
            try pinMenu("toggleAnnotationsHidden", pin); try await visibilityDrained(pin, deadline)
            window.appearance = previousAppearance
            try O.require(pin.annotationsHidden && (try O.digest(pin.displayedImage, lifetime: lifetime, label: "hidden-after-snapshots")) == hiddenHash,
                          "Visual toggle changed the hidden preview or saved pixels")
        }
        try O.diagnostic?.checkpoint("native-export")
        let annotatedExportHash = try await exportHash(pin: pin, original: false, lifetime: lifetime, deadline: deadline)
        try O.require(annotatedExportHash == expectedHash && hiddenHash != annotatedExportHash, "Hidden preview escaped through ordinary export")
        let originalExportHash = try await exportHash(pin: pin, original: true, lifetime: lifetime, deadline: deadline)
        try O.require(originalExportHash == sourceHash, "Explicit original export changed source")
        try O.diagnostic?.checkpoint("pin-edit-apply")
        let canvas = try pinCanvas(pin)
        canvas.keyDown(with: try key(canvas, " ", 49))
        let pinEditor = try O.required(pin.annotationEditor, "Space failed to reopen saved layers")
        lifetime.editor(pinEditor)
        try O.require(pinEditor.annotationCanvas.annotations.count == payload.document.annotations.count
            && (try EditableAnnotationDocumentCodec.encode(pinEditor.editablePayload().document)) == originalDocument,
            "Space fabricated, dropped or changed saved layers")
        if let visualDirectory {
            let window = try O.required(pinEditor.window, "Reopened editor window missing for evidence")
            let previousAppearance = window.appearance
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearance)
                try await settle(deadline)
                visualEvidence.append(try snapshotEditor(pinEditor, appearance: name, directory: visualDirectory, crop: crop))
            }
            window.appearance = previousAppearance
        }
        try nativeMark(pinEditor); try click("editor.cancel", editor: pinEditor)
        try await visibilityDrained(pin, deadline)
        try O.require(pin.annotationsHidden && (try O.digest(pin.currentImage, lifetime: lifetime, label: "pin-current-after-cancel")) == expectedHash, "Cancel changed pin or lost hidden state")
        canvas.keyDown(with: try key(canvas, " ", 49))
        let applied = try O.required(pin.annotationEditor, "Second Space failed")
        lifetime.editor(applied); try nativeMark(applied); try undo(applied)
        try O.require(try EditableAnnotationDocumentCodec.encode(applied.editablePayload().document) == originalDocument,
            "Pin native undo did not restore the saved document")
        try nativeMark(applied)
        let appliedDocument = try EditableAnnotationDocumentCodec.encode(applied.editablePayload().document)
        let appliedReference = try ImageOutputDecorationRenderer.project(
            flattened: O.required(applied.annotationCanvas.flattened(), "Applied reference render missing"), decoration: applied.outputDecoration)
        lifetime.image(appliedReference, role: "current")
        let appliedHash = try O.digest(appliedReference, lifetime: lifetime, label: "applied-reference")
        try O.require(appliedDocument != originalDocument && appliedHash != expectedHash, "Apply workload must change both layers and visible pixels")
        try click("editor.applyToPin", editor: applied); try await wait(deadline) { pin.annotationEditor == nil }
        try O.require(!pin.annotationsHidden && errors == 1, "Apply failed or left annotation visibility hidden")
        try O.diagnostic?.checkpoint("fresh-pin-load-render")
        let freshPinStore = try PinSessionStore(directory: pinStore.directory)
        lifetime.observe(freshPinStore, role: "store")
        let finalPinPayload = try O.required(freshPinStore.editablePayload(id: pinnedID), "Applied pin document missing after fresh store load")
        lifetime.image(finalPinPayload.originalImage, role: "original"); lifetime.image(finalPinPayload.baseImage, role: "base")
        try O.require(try EditableAnnotationDocumentCodec.encode(finalPinPayload.document) == appliedDocument,
            "Apply did not durably commit the distinct layer document")
        let appliedCurrent = try O.required(freshPinStore.image(id: pinnedID), "Applied current PNG missing")
        lifetime.image(appliedCurrent, role: "current")
        let appliedPersistedHash = try O.digest(appliedCurrent, lifetime: lifetime, label: "applied-persisted")
        let appliedFull = try O.required(ImageEditorRenderer.render(image: finalPinPayload.baseImage,
            annotations: finalPinPayload.document.annotations), "Fresh applied full-stack render failed")
        lifetime.image(appliedFull, role: "current")
        let appliedCropped = try O.required(ImageEditorRenderer.crop(image: appliedFull, to: crop), "Fresh applied crop failed")
        let appliedReplayed = try ImageOutputDecorationRenderer.project(flattened: appliedCropped, decoration: finalPinPayload.document.outputDecoration)
        lifetime.image(appliedCropped, role: "current"); lifetime.image(appliedReplayed, role: "current")
        let appliedReopenedHash = try O.digest(appliedReplayed, lifetime: lifetime, label: "applied-replayed")
        try O.require(appliedPersistedHash == appliedHash && appliedReopenedHash == appliedHash
            && (try O.digest(pin.currentImage, lifetime: lifetime, label: "pin-current-after-apply")) == appliedHash,
            "Applied live/current/restored pixels differ")
        try O.require(try O.digest(finalPinPayload.originalImage, lifetime: lifetime, label: "immutable-original") == sourceHash
            && O.digest(finalPinPayload.baseImage, lifetime: lifetime, label: "immutable-base") == baseHash,
            "Apply changed immutable original or base pixels")
        try O.diagnostic?.checkpoint("legacy-and-cleanup")
        let legacy = try reloaded.add(source, title: "Owned legacy raster")
        try O.require(try reloaded.editablePayload(for: legacy) == nil, "Legacy entry fabricated layers")
        let legacyEditor = ImageEditorController(image: source, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, saveWorkflow: SaveWorkflowPresenter(isSmoke: true))
        lifetime.editor(legacyEditor); legacyEditor.close()
        try O.require(legacyEditor.annotationCanvas.annotations.isEmpty, "Legacy raster contains invented annotations")
        identities.formUnion(try O.ownedFileIdentities(directory))
        try session.prepareForTermination(); seed.close(); editor.close()
        let originalPNGHash = try O.fileDigest(history.directory.appendingPathComponent(savedAsset.original.filename))
        let basePNGHash = try O.fileDigest(history.directory.appendingPathComponent(savedAsset.base.filename))
        try O.require(originalPNGHash == beforeFiles[savedAsset.original.filename]
            && basePNGHash == beforeFiles[savedAsset.base.filename]
            && originalPNGHash == savedAsset.original.sha256 && basePNGHash == savedAsset.base.sha256,
            "An immutable original/base PNG changed during reopen/edit/export")
        try EditableDrawingPairDiagnostic.process?.documents(original: originalDocument, applied: appliedDocument)
        let result: [String: Any] = ["width": width, "height": height, "fullBasePixels": width * height,
            "viewportPixels": Int(crop.width * crop.height), "outputWidth": expected.width, "outputHeight": expected.height,
            "layerCount": payload.document.annotations.count, "originalAndBaseAreDistinct": true,
            "visualEvidence": visualEvidence,
            "sourcePixelsSHA256": sourceHash, "basePixelsSHA256": baseHash,
            "expectedOutputPixelsSHA256": expectedHash, "persistedOutputPixelsSHA256": persistedHash,
            "reopenedOutputPixelsSHA256": replayHash, "hiddenPixelsSHA256": hiddenHash,
            "ordinaryExportPixelsSHA256": annotatedExportHash, "originalExportPixelsSHA256": originalExportHash,
            "originalPNGSHA256": originalPNGHash, "basePNGSHA256": basePNGHash,
            "documentSHA256": digest(originalDocument), "appliedDocumentSHA256": digest(appliedDocument),
            "appliedLayerCount": finalPinPayload.document.annotations.count,
            "appliedExpectedOutputPixelsSHA256": appliedHash, "appliedPersistedOutputPixelsSHA256": appliedPersistedHash,
            "appliedReopenedOutputPixelsSHA256": appliedReopenedHash, "assertions": Dictionary(uniqueKeysWithValues: assertions.map { ($0, true) })]
        try FileManager.default.removeItem(at: directory)
        return result
    }

    private static func snapshotEditor(_ editor: ImageEditorController, appearance: String,
        directory: URL, crop: CGRect) throws -> [String: Any] {
        let window = try O.required(editor.window, "Reopened editor window missing")
        let root = try O.required(window.contentView, "Reopened editor content missing")
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let toolbar = editor.floatingToolbarFrame
        try O.require(toolbar.height >= 24 && toolbar.height <= 56 && root.bounds.insetBy(dx: -1, dy: -1).contains(toolbar),
                      "Compact toolbar is oversized or clipped")
        let ids = ["editor.tool.rectangle", "editor.cancel", "editor.copy", "editor.applyToPin", "editor.outputDecoration", "editor.more"]
        let targets: [[String: Any]] = try ids.map { id in
            let control = try O.required(descendants(root).first { $0.identifier?.rawValue == id } as? NSControl,
                                         "Visual native target missing: " + id)
            try O.require(control.isEnabled && !control.isHiddenOrHasHiddenAncestor, "Visual native target disabled/hidden: " + id)
            let frame = root.convert(control.bounds, from: control)
            let hit = try O.required(root.hitTest(CGPoint(x: frame.midX, y: frame.midY)), "Visual native hit target missed: " + id)
            try O.require((hit === control || hit.isDescendant(of: control)) && root.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                          "Visual native target obscured/clipped: " + id)
            return ["id": id, "frame": rectangle(frame), "nativeHitVerified": true]
        }
        return try snapshot(window: window, canvas: editor.annotationCanvas,
            imageFrame: O.required(editor.editorImageScreenFrame, "Editor image frame missing"),
            viewportFrame: O.required(editor.pinnedViewportScreenFrame, "Editor viewport missing"),
            crop: crop, name: "editable-reopened-" + appearance + ".png", kind: "reopenedEditor",
            appearance: appearance, controls: targets, toolbar: toolbar, directory: directory)
    }
    private static func snapshotPin(_ pin: PinController, name: String, kind: String,
        directory: URL, crop: CGRect) throws -> [String: Any] {
        let placement = try O.required(pin.annotationPresentation, "Visual pin placement missing")
        return try snapshot(window: O.required(pin.window, "Visual pin window missing"), canvas: pinCanvas(pin),
            imageFrame: placement.imageFrame, viewportFrame: placement.viewportFrame, crop: crop,
            name: name, kind: kind, appearance: "dark", controls: [], toolbar: nil, directory: directory)
    }
    /// AppKit cache of owned views at one pixel per point, composited over the
    /// resolved native window background. No desktop pixels or TCC are acquired.
    private static func snapshot(window: NSWindow, canvas: NSView, imageFrame: CGRect, viewportFrame: CGRect,
        crop: CGRect, name: String, kind: String, appearance: String, controls: [[String: Any]],
        toolbar: CGRect?, directory: URL) throws -> [String: Any] {
        try O.diagnostic?.checkpoint("snapshot-before-" + name)
        defer { try? O.diagnostic?.checkpoint("snapshot-after-" + name) }
        let root = try O.required(window.contentView, "Visual root missing")
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        let point = root.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), from: canvas)
        let hit = try O.required(root.hitTest(point), "Visual image hit target missed")
        try O.require(hit === canvas || hit.isDescendant(of: canvas), "Visual image is obscured")
        let width = Int(ceil(root.bounds.width)), height = Int(ceil(root.bounds.height))
        try O.require(width > 0 && height > 0 && width <= 1280 && height <= 900, "Visual snapshot exceeds bounded small-profile size")
        let bitmap = try O.required(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Visual bitmap allocation failed")
        bitmap.size = root.bounds.size; root.cacheDisplay(in: root.bounds, to: bitmap)
        let context = try context(width, height)
        var background = CGColor(gray: 1, alpha: 1)
        root.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        context.setFillColor(background); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(try O.required(bitmap.cgImage, "Native view snapshot missing pixels"), in: CGRect(x: 0, y: 0, width: width, height: height))
        let image = try O.required(context.makeImage(), "Visual composition failed")
        try O.require(context.bytesPerRow == width * 4, "Unexpected visual raster row stride")
        let pixels = Data(bytesNoCopy: try O.required(context.data, "Visual pixel data missing"),
            count: width * height * 4, deallocator: .none)
        let rgbaHash = withExtendedLifetime(context) { digest(pixels) }
        let url = directory.appendingPathComponent(name)
        try image.writePNG(to: url)
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try O.require(bytes > 0 && bytes <= 8 * 1_024 * 1_024, "Visual PNG exceeds evidence byte bound")
        let whileLive = try withExtendedLifetime((bitmap, context, image)) { try O.memory() }
        return ["filename": name, "sha256": try O.fileDigest(url), "rgbaSHA256": rgbaHash, "byteCount": bytes,
            "pixelWidth": width, "pixelHeight": height, "kind": kind, "appearance": appearance,
            "windowFrame": rectangle(window.frame), "contentBounds": rectangle(root.bounds),
            "imageScreenFrame": rectangle(imageFrame), "viewportScreenFrame": rectangle(viewportFrame),
            "cropViewportInBase": rectangle(crop), "toolbarFrame": toolbar.map(rectangle) ?? [],
            "controls": controls, "imageNativeHitVerified": true, "whileSnapshotLiveMemory": whileLive,
            "scope": "Owned AppKit view cache, one pixel per point, composited native window background; no desktop capture"]
    }
    private static func rectangle(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }

    private static func resources(root: URL, sampler: EditableAnnotationMemorySampler,
        identities: inout Set<O.OwnedFileIdentity>, deadline: Double,
        progress: ([String: Any]) throws -> Void) async throws -> [String: Any] {
        let before = try O.memory()
        var warmupRecords: [[String: Any]] = [], records: [[String: Any]] = []
        var baseline: [String: Any] = before
        for cycle in 0..<(warmups + measured) {
            let isWarmup = cycle < warmups, index = isWarmup ? cycle + 1 : cycle - warmups + 1
            let label = (isWarmup ? "warmup-" : "measured-") + String(index)
            sampler.setPhase(label)
            try O.diagnostic?.beginWorkload(label)
            let entry = try O.memory(), lifetime = EditableAnnotationLifetime()
            let directory = root.appendingPathComponent("resource-" + label)
            try progress(["status": "running", "completedWarmupCycles": warmupRecords.count,
                "completedMeasuredCycles": records.count, "beforeWarmup": before, "afterWarmupBaseline": baseline,
                "warmups": warmupRecords, "cycles": records,
                "activeCycle": ["index": index, "phase": isWarmup ? "warmup" : "measured", "beforeMemory": entry]])
            var value = try await functional(directory: directory, width: 3840, height: 2160,
                lifetime: lifetime, identities: &identities, deadline: deadline)
            try await release(lifetime, deadline: deadline); try await settle(deadline)
            try O.diagnostic?.checkpoint("workload-released")
            let handles = try O.ownedFileDescriptors(root, identities: identities)
            try O.require(handles.isEmpty && !FileManager.default.fileExists(atPath: directory.path), "Resource cycle retained a temporary path or owned file descriptor")
            try O.require(ImageExportController.activeSessionCount == 0 && !EditorOutputProjection.shared.isBusy,
                          "Resource cycle retained an export or projection")
            value["index"] = index; value["phase"] = isWarmup ? "warmup" : "measured"
            value["beforeMemory"] = entry; value["afterMemory"] = try O.memory()
            value["ownershipAfterRelease"] = lifetime.report
            value["windowContentGraphsAfterRelease"] = lifetime.windowContentGraphs
            value["ownedOpenDescriptorsAfter"] = handles.count
            value["temporaryDirectoryRemoved"] = true
            value["activeExportControllersAfter"] = ImageExportController.activeSessionCount
            value["projectionReservedBytesAfter"] = EditorOutputProjection.shared.reservedBytes
            value["canonicalNormalizationBytesPerFullBase"] = 3840 * 2160 * 4
            value["minimumOriginalPlusBaseBytesWhileLoaded"] = 3840 * 2160 * 8
            if isWarmup { warmupRecords.append(value) } else { records.append(value) }
            if cycle == warmups - 1 { baseline = try O.memory() }
            try progress(["status": "running", "completedWarmupCycles": warmupRecords.count,
                "completedMeasuredCycles": records.count, "beforeWarmup": before, "afterWarmupBaseline": baseline,
                "warmups": warmupRecords, "cycles": records, "activeCycle": NSNull()])
        }
        try O.require(Set((warmupRecords + records).compactMap { $0["expectedOutputPixelsSHA256"] as? String }).count == 1,
                      "Identical repeated workload changed exact output pixels")
        let after = try O.memory()
        let endpoints = records.compactMap { $0["afterMemory"] as? [String: Any] }
        return ["status": "observed", "warmupCycles": warmups, "measuredCycles": measured,
            "completedWarmupCycles": warmupRecords.count, "completedMeasuredCycles": records.count,
            "sourceWidth": 3840, "sourceHeight": 2160, "fixedInputRastersAtEndpoints": 0,
            "originalAndBaseDistinct": true, "fullBaseCostsIncluded": true,
            "realHistoryPNGMetadataRoundTripsPerCycle": true, "nativeActionsInEveryCycle": true,
            "beforeWarmup": before, "afterWarmupBaseline": baseline,
            "warmups": warmupRecords, "cycles": records, "afterMeasuredCycles": after,
            "afterWarmupToMeasuredDeltaBytes": delta(baseline, after),
            "lateMeasuredIncrements": Array(zip(endpoints.dropLast(), endpoints.dropFirst()).suffix(3)).map { delta($0.0, $0.1) },
            "memoryStabilityAssessed": false, "zeroLeakClaim": false,
            "workload": "Every cycle creates distinct owned 4K original/base rasters, commits real PNG/metadata assets, closes/reopens history and pin editors through native controls, exercises durable failure/retry and crop/uncrop/undo, compares hidden preview with native PNG export bytes, and releases all tracked objects/files before the endpoint. No source raster is held between cycles."]
    }

    private static func exportHash(pin: PinController, original: Bool, lifetime: EditableAnnotationLifetime, deadline: Double) async throws -> String {
        try pinMenu(original ? "saveOriginal" : "savePin", pin)
        let controller = try O.required(pin.imageExportController, "Native export window did not open")
        defer { controller.cancelExport() }
        try await wait(deadline) { controller.latestArtifact != nil }
        let artifact = try O.required(controller.latestArtifact, "PNG export artifact missing")
        try O.require(artifact.options.format == .png, "Fixture export did not use PNG")
        let input = try O.required(CGImageSourceCreateWithData(artifact.data as CFData, nil), "Export PNG cannot be read")
        let image = try O.required(CGImageSourceCreateImageAtIndex(input, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), "Export PNG pixels missing")
        lifetime.image(image, role: "current")
        let hash = try O.digest(image, lifetime: lifetime, label: original ? "export-original" : "export-annotated")
        controller.cancelExport()
        try await wait(deadline) { controller.isClosed && ImageExportController.activeSessionCount == 0 && ImageExportService.queue.operationCount == 0 }
        return hash
    }
    private static var decoration: ImageOutputDecoration {
        ImageOutputDecoration(enabled: true, cornerRadius: 8, borderEnabled: true, borderWidth: 2,
            shadowEnabled: true, shadowBlur: 2, shadowOffsetX: 3, shadowOffsetY: 4)
    }
    private static func viewport(width: Int) -> CGRect {
        let s = CGFloat(width) / 640
        return CGRect(x: 80 * s, y: 40 * s, width: 400 * s, height: 260 * s)
    }
    private static func marks(width: Int) -> [ImageAnnotation] {
        let s = CGFloat(width) / 640
        func points(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
            [CGPoint(x: x * s, y: y * s), CGPoint(x: (x + w) * s, y: (y + h) * s)]
        }
        var redaction = ImageAnnotation(tool: .redact, points: points(125, 75, 85, 40), color: CGColor(gray: 0, alpha: 1))
        redaction.rotation = 0.08
        var blur = ImageAnnotation(tool: .blur, points: points(58, 22, 70, 70), lineWidth: 4 * s)
        blur.rotation = 0.11
        var lens = ImageAnnotation(tool: .magnifier, points: points(355, 80, 100, 100), lineWidth: 3)
        lens.magnifierSource = CGRect(x: 555 * s, y: 280 * s, width: 45 * s, height: 40 * s)
        var spotlight = ImageAnnotation(tool: .spotlight, points: points(60, 28, 440, 290))
        spotlight.spotlightDim = 0.23
        let eraser = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 105 * s, y: 100 * s), CGPoint(x: 230 * s, y: 100 * s)], lineWidth: 5 * s)
        let targets = [CGRect(x: 190 * s, y: 195 * s, width: 35 * s, height: 25 * s), CGRect(x: 285 * s, y: 215 * s, width: 35 * s, height: 25 * s)]
        let group = UUID(), addition = UUID()
        let linked = targets.map { rect -> ImageAnnotation in
            var mark = ImageAnnotation(tool: .pixelate, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], lineWidth: 3 * s)
            mark.mosaicLink = AutomaticMosaicLink(groupID: group, additionID: addition, rootAdditionID: addition,
                target: rect, includedTargets: targets, excludedTargets: [], synchronizes: true)
            return mark
        }
        return [redaction, blur, lens, spotlight, eraser] + linked
    }
    private static func makeSource(width: Int, height: Int) throws -> CGImage {
        let context = try context(width, height)
        for y in stride(from: 0, to: height, by: 16) { for x in stride(from: 0, to: width, by: 16) {
            context.setFillColor(CGColor(srgbRed: Double((x / 16 * 31 + y / 16 * 17) % 251) / 255,
                green: Double((x / 16 * 7 + y / 16 * 23) % 251) / 255,
                blue: Double((x / 16 * 19 + y / 16 * 11) % 251) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 16, height: 16))
        } }
        return try O.required(context.makeImage(), "Source raster allocation failed")
    }
    private static func derivedBase(_ original: CGImage) throws -> CGImage {
        let context = try context(original.width, original.height)
        context.setBlendMode(.copy); context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: original.width, height: 3))
        return try O.required(context.makeImage(), "Distinct base allocation failed")
    }
    private static func context(_ width: Int, _ height: Int) throws -> CGContext {
        try O.required(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Fixture context allocation failed")
    }
    private static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    private static func click(_ id: String, editor: ImageEditorController) throws {
        let root = try O.required(editor.window?.contentView, "Editor content missing")
        let button = try O.required(descendants(root).first { $0.identifier?.rawValue == id } as? NSButton, "Missing native button: " + id)
        try O.require(button.isEnabled && !button.isHiddenOrHasHiddenAncestor, "Native control disabled/hidden: " + id)
        let point = root.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        let hit = try O.required(root.hitTest(point), "Native hit-test missed: " + id)
        try O.require(hit === button || hit.isDescendant(of: button), "Native button obscured: " + id)
        button.performClick(nil)
    }
    private static func editorMenu(_ action: String, _ editor: ImageEditorController) throws {
        let selector = NSSelectorFromString(action), views = descendants(editor.window?.contentView)
        if let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.action == selector && !$0.isHiddenOrHasHiddenAncestor }) {
            try O.require(button.isEnabled, "Native action disabled"); button.performClick(nil); return
        }
        for menu in views.compactMap({ ($0 as? NSPopUpButton)?.menu }) + [editor.annotationCanvas.menu].compactMap({ $0 }) {
            if let index = menu.items.firstIndex(where: { $0.action == selector }) { menu.performActionForItem(at: index); return }
        }
        throw O.failure("Native editor action missing: " + action)
    }
    private static func pinMenu(_ action: String, _ pin: PinController) throws {
        let selector = NSSelectorFromString(action)
        func visit(_ menu: NSMenu) -> Bool {
            pin.menuNeedsUpdate(menu)
            if let index = menu.items.firstIndex(where: { $0.action == selector }) { menu.performActionForItem(at: index); return true }
            return menu.items.compactMap(\.submenu).contains { visit($0) }
        }
        try O.require(try visit(O.required(pin.actionMenu, "Pin menu missing")), "Native pin action missing: " + action)
    }
    private static func selectTool(_ tool: ImageEditorTool, editor: ImageEditorController) throws {
        if let button = descendants(editor.window?.contentView).first(where: { $0.identifier?.rawValue == "editor.tool." + tool.rawValue }) as? NSButton,
           !button.isHiddenOrHasHiddenAncestor { button.performClick(nil) }
        else {
            let popup = try O.required(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "editor.more" } as? NSPopUpButton, "Tool menu missing")
            let menu = try O.required(popup.menu, "Tool menu absent")
            let index = try O.required(menu.items.firstIndex { $0.title == tool.title }, "Tool action missing")
            menu.performActionForItem(at: index)
        }
        try O.require(editor.annotationCanvas.tool == tool, "Native tool selection did not apply")
    }
    private static func nativeMark(_ editor: ImageEditorController) throws {
        let before = try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
        let oldIDs = Set(editor.annotationCanvas.annotations.map(\.id))
        let count = editor.annotationCanvas.annotations.count
        try selectTool(.rectangle, editor: editor)
        let rect = editor.annotationCanvas.visibleImageRect
        let start = CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.7)
        let end = CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.84)
        try drag(editor.annotationCanvas, start, end)
        let added = editor.annotationCanvas.annotations.filter { !oldIDs.contains($0.id) }
        try O.require(editor.annotationCanvas.annotations.count == count + 1 && added.count == 1,
            "Native rectangle gesture was a no-op or created duplicate marks")
        let mark = added[0]
        try O.require(mark.tool == .rectangle && mark.points.count == 2
            && abs(mark.points[0].x - start.x) < 0.01 && abs(mark.points[0].y - start.y) < 0.01
            && abs(mark.points[1].x - end.x) < 0.01 && abs(mark.points[1].y - end.y) < 0.01,
            "Native rectangle gesture created unexpected geometry")
        try O.require(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document) != before,
            "Native rectangle gesture did not change the editable document")
    }
    private static func drag(_ canvas: ImageEditorCanvas, _ start: CGPoint, _ end: CGPoint) throws {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil)
            let event = try O.required(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Native mouse event unavailable")
            if type == .leftMouseDown {
                let root = try O.required(canvas.window?.contentView, "Canvas root missing")
                let hit = root.hitTest(root.convert(location, from: nil))
                try O.require(hit === canvas || hit?.isDescendant(of: canvas) == true, "Canvas hit-test missed")
                canvas.mouseDown(with: event)
            } else if type == .leftMouseDragged { canvas.mouseDragged(with: event) } else { canvas.mouseUp(with: event) }
        }
    }
    private static func key(_ view: NSView, _ text: String, _ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try O.required(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code), "Native key event unavailable")
    }
    private static func undo(_ editor: ImageEditorController) throws {
        try O.require(editor.annotationCanvas.performKeyEquivalent(with: key(editor.annotationCanvas, "z", 6, modifiers: .command)), "Native undo shortcut failed")
    }
    private static func pinCanvas(_ pin: PinController) throws -> NSView {
        let menu = try O.required(pin.actionMenu, "Pin action menu missing")
        let canvas = try O.required(descendants(pin.window?.contentView).compactMap { $0 as? NSScrollView }
            .compactMap(\.documentView).first { $0.menu === menu && $0.acceptsFirstResponder }, "Native pin document view missing")
        try O.require(canvas.window === pin.window && pin.window?.makeFirstResponder(canvas) == true,
                      "Pin document view is not the native key responder")
        return canvas
    }
    private static func outputDrained(_ editor: ImageEditorController, _ deadline: Double) async throws {
        try await wait(deadline) { !editor.outputProjectionIsPending && !EditorOutputProjection.shared.isBusy }
    }
    private static func visibilityDrained(_ pin: PinController, _ deadline: Double) async throws {
        try await wait(deadline) { !pin.annotationVisibilityIsPending && !EditorOutputProjection.shared.isBusy }
    }
    private static func release(_ lifetime: EditableAnnotationLifetime, deadline: Double) async throws {
        try await wait(min(deadline, ProcessInfo.processInfo.systemUptime + 10)) { autoreleasepool { lifetime.alive == 0 && lifetime.windowContentGraphs == 0 } }
    }
    private static func wait(_ deadline: Double, _ predicate: () -> Bool) async throws {
        while !predicate() {
            try Task.checkCancellation()
            try O.require(ProcessInfo.processInfo.systemUptime < deadline, "Fixture cooperative deadline exceeded")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func settle(_ deadline: Double) async throws {
        try O.require(ProcessInfo.processInfo.systemUptime < deadline, "Fixture deadline exceeded")
        try await Task.sleep(nanoseconds: 150_000_000)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func fileManifest(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[url.lastPathComponent] = try O.fileDigest(url)
        }
        return result
    }
    private static func delta(_ before: [String: Any], _ after: [String: Any]) -> [String: Int64] {
        guard let a = before["counters"] as? [String: Int64], let b = after["counters"] as? [String: Int64] else { return [:] }
        return Dictionary(uniqueKeysWithValues: EditableAnnotationMemorySampler.required.compactMap { key in
            guard let x = a[key], let y = b[key] else { return nil }; return (key, y - x)
        })
    }
    private static func write(_ report: [String: Any], directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("editable-annotation-native.json"), options: .atomic)
        try O.diagnostic?.write(native: report, nativeData: data, directory: directory)
        try EditableDrawingPairDiagnostic.process?.write(native: report, nativeData: data, directory: directory)
    }
}
