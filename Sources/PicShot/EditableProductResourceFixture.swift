import AppKit
import CryptoKit
import Darwin
import PicShotCore

/// Complementary product-lifecycle observation. The full fidelity/failure fixture
/// stays separate. Only `certify` draws reference pixels; measured modes never do.
@MainActor enum EditableProductResourceFixture {
    typealias O = EditableAnnotationFixtureObservation
    static let protocolID = "editable-product-resource-v2"
    static let installedDefaultProtocolID = "editable-product-installed-default-v1"
    static let warmups = 2, measured = 8, width = 3840, height = 2160
    static let deadlineSeconds = 300.0, copyBufferBytes = 65_536
    static let maximumPNGBytes = 40 * 1_024 * 1_024
    static let maximumMetadataBytes = 131_072
    static let maximumReportBytes = 8 * 1_024 * 1_024
    static let maximumEvidenceFiles = 256, maximumEvidenceBytes = 640 * 1_024 * 1_024
    static let maximumStages = 40, maximumCheckpoints = 160
    static let crop = CGRect(x: 480, y: 240, width: 2400, height: 1560)
    static let expectedHashes = [
        "original": "c7819513b71c4ad1675665feece59747ff9a518db5766c5a8de973f65fdf19c6",
        "base": "b41f79800dd04476e3381aa6fa9da0a2e4f61034729dce3551909a383be83fc9",
        "seven": "b8362e485bb0bfc04471d4a9de1eaf01be470fb66f419193fa41966cdcaaaff5",
        "eight": "901d625dd2b57188f0d6228ab9ecfbdc1ceee7d2e297d85d42a03bcdf751f621"]
    enum Mode: String { case certify, measure, installedDefault = "installed-default" }
    struct Request { let mode: Mode; let input: URL; let certificate: URL }
    private static var claimed = false

    static func request(_ environment: [String: String]) throws -> Request? {
        let prefix = "PICSHOT_EDITABLE_PRODUCT_"
        let keys = Set(environment.keys.filter { $0.hasPrefix(prefix) })
        guard !keys.isEmpty else { return nil }
        try O.require(environment["PICSHOT_SMOKE_TEST"] == "1", "Product resources require smoke mode")
        try O.require(keys == Set([prefix + "MODE", prefix + "INPUT", prefix + "CERTIFICATE"]), "Missing/unknown product resource override")
        let mode = try O.required(environment[prefix + "MODE"].flatMap(Mode.init(rawValue:)), "Unknown product resource mode")
        let conflicts = environment.keys.filter {
            !$0.hasPrefix(prefix) && $0 != "PICSHOT_DRAWING_RASTER_STRATEGY" && (($0.hasSuffix("_ONLY") && environment[$0] != "0")
                || $0.contains("_DIAGNOSTIC") || $0.contains("_ATTRIBUTION_")
                || $0.hasPrefix("PICSHOT_SUBSTAGE_")
                || $0.hasPrefix("PICSHOT_EDITABLE_COMPONENT_") || $0.hasPrefix("PICSHOT_IMAGE_")
                || $0.hasPrefix("PICSHOT_DRAWING_") || $0.hasPrefix("PICSHOT_RENDERER_")
                || $0.hasPrefix("PICSHOT_EFFECT_"))
        }
        try O.require(conflicts.isEmpty, "Product resources require an otherwise unselected default-strategy process")
        let drawing = try DrawingRasterConfiguration.selection(environment: environment)
        if mode == .installedDefault {
            try O.require(environment["PICSHOT_DRAWING_RASTER_STRATEGY"] == nil
                && DrawingRasterStrategy.productionDefault == .ownedSRGB8 && drawing == .ownedSRGB8,
                "Installed-default measurement requires the compiled owned-srgb8 default without a drawing override")
        } else {
            try O.require(environment["PICSHOT_DRAWING_RASTER_STRATEGY"] != nil,
                "Certification and paired measurement require explicit drawing selection")
            try O.require(mode != .certify || drawing == .reference, "Golden certification must use explicit reference drawing")
        }
        func path(_ name: String) throws -> URL {
            let value = try O.required(environment[prefix + name], "Missing product resource path")
            try O.require(value.hasPrefix("/") && !value.contains("\0"), "Product resource paths must be absolute")
            return URL(fileURLWithPath: value)
        }
        return try Request(mode: mode, input: path("INPUT"), certificate: path("CERTIFICATE"))
    }

    // This object contains only paths, scalar metadata and a seven-layer value
    // document. CGImage.read's compressed provider ownership is product cost.
    private struct Input {
        let directory: URL, document: EditableAnnotationDocument
        let manifestSHA256: String, certificateSHA256: String
        let producerPID: Int, certificatePID: Int
        let originalBytes: Int, baseBytes: Int
        var encodedBytes: Int { originalBytes + baseBytes }
    }

    static func runIfRequested(evidenceDirectory: URL) async throws -> [String: Any]? {
        guard let request = try request(ProcessInfo.processInfo.environment) else { return nil }
        try O.require(!claimed && NSScreen.main != nil, "Fresh owned native display required")
        claimed = true
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + deadlineSeconds
        // Read before configuration reporting: accessing the effect singleton
        // constructs a CIContext and must not invisibly warm the cold cycle.
        let entry = try O.memory(), sampler = EditableAnnotationMemorySampler()
        defer { sampler.stop() }
        var report = try identity()
        report.merge(["schemaVersion": 1,
            "protocol": request.mode == .installedDefault ? installedDefaultProtocolID : protocolID, "mode": request.mode.rawValue,
            "runIdentifier": UUID().uuidString, "status": "running", "deadlineSeconds": deadlineSeconds,
            "requestedDrawingStrategy": ProcessInfo.processInfo.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] ?? DrawingRasterStrategy.productionDefault.rawValue,
            "drawingOverridePresent": ProcessInfo.processInfo.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] != nil,
            "entryMemory": entry, "memoryStabilityAssessed": false, "zeroRSSClaim": false,
            "privateBackingReleaseProved": false, "fullCorrectnessFixtureReplaced": false,
            "scope": "Owned actual product lifecycle, self task only. Eight counters overlap; task-info flavors are not atomic. 50ms samples can miss transients and exclude WindowServer/GPU. Weak AppKit retirement is not proof of private graphics backing release.",
            "latencyScope": "Action dispatch to semantic completion, not physical-input or first-painted-frame latency. Save/pin/apply await durable callback and projection drain; open/Space/group-show include a 150ms native settle; edit/undo/crop end after native event handlers and metadata assertions.",
            "deadlineScope": "300-second cooperative native deadline. AppDelegate.openRecord retains normal modal error presentation; a blocking native modal cannot be preempted by cooperative checks. The owned-process launcher must enforce the unchanged 600-second terminal cap.",
            "entryPoints": ["seedMetadata": "programmatic certified seven-layer payload, uncropped",
                "initialOpen": "AppDelegate.openEditor with production CGImage.read and encoded backing admission",
                "historyReopen": "programmatic AppDelegate.openRecord",
                "nativeControls": "owned NSButton.performClick / NSMenu.performActionForItem",
                "nativeGestures": "owned canvas mouseDown/mouseDragged/mouseUp and Command-Z / Space responder events",
                "groupVisibility": "programmatic PinSessionCoordinator.hideCurrentGroup/showCurrentGroup",
                "historyGridDoubleClick": false, "physicalInput": false],
            "flags": ["syntheticSource": true, "screenCaptureStarted": false, "permissionRequests": false,
                "globalInputPosted": false, "networkUsed": false, "generalPasteboardUsed": false,
                "standardDefaultsWritten": false, "memoryPressureOrPurgeRequested": false,
                "manualCachePurges": false, "weakCoreFoundationProbes": false,
                "measuredRasterReferenceWork": false, "measuredRawRGBARead": false],
            "limits": ["sourceWidth": width, "sourceHeight": height, "warmups": warmups, "measured": measured,
                "copyBufferBytes": copyBufferBytes, "maximumPNGBytes": maximumPNGBytes,
                "maximumMetadataBytes": maximumMetadataBytes, "maximumEvidenceFiles": maximumEvidenceFiles,
                "maximumReportBytes": maximumReportBytes,
                "maximumEvidenceBytes": maximumEvidenceBytes, "maximumStages": maximumStages,
                "maximumCheckpoints": maximumCheckpoints, "editorAdmissionBytes": EditorAdmissionPolicy().maximumRasterBytes,
                "projectionReservationBytes": EditorOutputProjection.combinedWorkingByteLimit]]) { _, new in new }
        do {
            try safeDirectory(evidenceDirectory, create: true)
            let input = try loadInput(request, identity: report)
            report["inputManifestSHA256"] = input.manifestSHA256
            report["inputCertificateSHA256"] = input.certificateSHA256
            report["inputPreparationProcessIdentifier"] = input.producerPID
            report["inputCertificateProcessIdentifier"] = input.certificatePID
            report["inputOriginalEncodedBytes"] = input.originalBytes
            report["inputBaseEncodedBytes"] = input.baseBytes
            report["fixtureRetainedInputRasterBytes"] = 0
            if request.mode == .certify {
                report = try certify(input, report: report, directory: evidenceDirectory, deadline: deadline)
            } else {
                try await measure(input, directory: evidenceDirectory, deadline: deadline,
                    sampler: sampler, report: &report)
                report["status"] = "observed-pending-output-validation"
            }
            try check(deadline)
            sampler.setPhase("final-cleanup"); sampler.stop()
            report["sampledMemory"] = sampler.report; report["finalMemory"] = try O.memory()
            report["configuration"] = try configuration()
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try write(report, evidenceDirectory.appendingPathComponent(request.mode == .certify ? "product-certificate.json" : "editable-product-resource.json"))
            return report
        } catch {
            sampler.stop(); report["status"] = "failed"; report["error"] = error.localizedDescription
            report["sampledMemory"] = sampler.report; report["finalMemory"] = try? O.memory()
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try? write(report, evidenceDirectory.appendingPathComponent(request.mode == .certify ? "product-certificate.json" : "editable-product-resource.json"))
            throw error
        }
    }

    /// Weak probes cover Swift/AppKit ownership only. Raster identities below
    /// are point-in-time scalar observations, never cross-phase CF weak probes.
    @MainActor private final class Ownership {
        private final class Probe {
            weak var value: AnyObject?
            let role: String
            init(_ value: AnyObject, role: String) { self.value = value; self.role = role }
        }
        private var probes: [Probe] = []
        func observe(_ object: AnyObject, _ role: String) {
            if probes.contains(where: { $0.value === object && $0.role == role }) { return }
            probes.append(Probe(object, role: role))
        }
        func editor(_ editor: ImageEditorController) {
            observe(editor, "editor"); observe(editor.annotationCanvas, "canvas")
            if let window = editor.window { observe(window, "window") }
            if let content = editor.window?.contentView { observe(content, "content") }
        }
        func pin(_ pin: PinController) {
            observe(pin, "pin")
            if let window = pin.window { observe(window, "window") }
            if let content = pin.window?.contentView { observe(content, "content") }
        }
        var editorCount: Int { probes.filter { $0.role == "editor" && $0.value != nil }.count }
        var pinCount: Int { probes.filter { $0.role == "pin" && $0.value != nil }.count }
        var alive: Int { probes.filter { $0.role != "window" && $0.value != nil }.count }
        var attachedWindowCount: Int {
            probes.compactMap { $0.role == "window" ? $0.value as? NSWindow : nil }
                .filter { $0.contentView != nil || $0.delegate != nil }.count
        }
        var report: [String: Any] {
            ["created": probes.count, "aliveNonWindowObjects": alive, "liveEditors": editorCount,
                "livePins": pinCount, "attachedWindowGraphs": attachedWindowCount,
                "retainedWindowShells": probes.filter { $0.role == "window" && $0.value != nil }.count]
        }
    }

    @MainActor private final class Run {
        let app: AppDelegate, history: HistoryStore, session: PinSessionCoordinator
        let root: URL, defaults: UserDefaults, defaultsName: String, artifacts: Artifacts
        var observation = Ownership()
        var identities: Set<O.OwnedFileIdentity> = []
        var checkpoints: [[String: Any]] = [], stages: [[String: Any]] = [], actions: [[String: Any]] = []
        var phaseTimings: [[String: Any]] = []
        var cycle = 0, errors: [String] = []
        init(directory: URL) throws {
            let ownedRoot = try systemTemporaryDirectory().appendingPathComponent("picshot-product-" + UUID().uuidString)
            let ownedDefaultsName = "PicShot.ProductFixture." + UUID().uuidString
            let ownedDefaults = try O.required(UserDefaults(suiteName: ownedDefaultsName), "Isolated defaults unavailable")
            var ready = false
            defer {
                if !ready { try? FileManager.default.removeItem(at: ownedRoot); ownedDefaults.removePersistentDomain(forName: ownedDefaultsName) }
            }
            root = ownedRoot; defaultsName = ownedDefaultsName; defaults = ownedDefaults
            try safeDirectory(root, create: true)
            history = HistoryStore(directory: root.appendingPathComponent("history"),
                policy: RetentionPolicy(maxItems: 1, maxBytes: 256 * 1_024 * 1_024, maxDays: 30))
            try O.require(history.loadError == nil, "Owned history unavailable")
            app = AppDelegate(history: history, isolatedDefaults: defaults)
            session = PinSessionCoordinator(store: try PinSessionStore(directory: root.appendingPathComponent("pins"),
                policy: PinSessionPolicy(maxPins: 1)), presentWindows: true,
                desktopVisibilityService: PinDesktopVisibilityService(defaults: defaults),
                ocrPreferences: PinOCRPreferences(defaults: defaults))
            app.pinSession = session
            artifacts = try Artifacts(directory: directory)
            session.onError = { [weak self] error in self?.errors.append(error.localizedDescription) }
            ready = true
        }
        func cleanup() throws {
            app.controllers.compactMap { $0 as? ImageEditorController }.forEach { $0.close() }
            try session.prepareForTermination()
            identities.formUnion(try O.ownedFileIdentities(root))
            try FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        func record(_ phase: String) throws {
            try O.require(checkpoints.count < maximumCheckpoints, "Product checkpoint bound exceeded")
            checkpoints.append(["cycle": cycle, "phase": phase, "memory": try O.memory(),
                "state": try state(), "ownership": observation.report])
        }
        func state() throws -> [String: Any] {
            var rasterRows: [[String: Any]] = [], seen = Set<ObjectIdentifier>()
            func raster(_ image: CGImage, _ role: String) {
                let id = ObjectIdentifier(image)
                rasterRows.append(["role": role, "identity": String(describing: id), "width": image.width,
                    "height": image.height, "bytesPerRow": image.bytesPerRow, "knownBytes": image.bytesPerRow * image.height,
                    "firstIdentityOccurrence": seen.insert(id).inserted])
            }
            var editorBytes = 0, pinBytes = 0, undoRasters = 0, hiddenPreviews = 0, retainedBases = 0
            let editors = app.controllers.compactMap { $0 as? ImageEditorController }
                + session.liveControllers.values.compactMap(\.annotationEditor)
            for editor in editors where !editor.isClosed {
                let payload = try editor.editablePayload()
                raster(payload.originalImage, "editor-original"); raster(payload.baseImage, "editor-base")
                if let presentation = editor.annotationCanvas.retainedPresentationRaster { raster(presentation, "editor-presentation") }
                editorBytes += editor.estimatedAdmissionRasterBytes; undoRasters += editor.retainedUndoRasterCount
            }
            for pin in session.liveControllers.values {
                raster(pin.image, "pin-original"); raster(pin.currentImage, "pin-current")
                if pin.annotationsHidden { raster(pin.displayedImage, "pin-hidden-preview") }
                pinBytes += pin.estimatedRetainedRasterBytes
                hiddenPreviews += pin.retainedAnnotationPreviewCount; retainedBases += pin.retainedEditableBaseCount
            }
            return ["appEditorCount": app.controllers.compactMap { $0 as? ImageEditorController }.count,
                "pinCount": session.livePinCount, "pinEditorCount": session.liveControllers.values.filter { $0.annotationEditor != nil }.count,
                "knownRasters": rasterRows, "knownUniqueRasterBytes": rasterRows.filter { $0["firstIdentityOccurrence"] as? Bool == true }
                    .reduce(0) { $0 + ($1["knownBytes"] as? Int ?? 0) },
                "rasterIdentityScope": "Point-in-time object identity; row-stride estimates may share backing or omit provider/private caches",
                "editorAdmissionEstimateBytes": editorBytes, "pinAdmissionEstimateBytes": pinBytes,
                "undoRasterIdentities": undoRasters, "hiddenPreviewCount": hiddenPreviews, "retainedEditableBaseCount": retainedBases,
                "projectionBusy": EditorOutputProjection.shared.isBusy, "projectionReservedBytes": EditorOutputProjection.shared.reservedBytes,
                "projectionQueueOperations": EditorOutputProjection.shared.queue.operationCount,
                "projectionStarted": EditorOutputProjection.shared.startedCount, "projectionCompleted": EditorOutputProjection.shared.completedCount,
                "drawing": try scalar(DrawingRasterConfiguration.process.tracker.snapshot()),
                "rendererStorage": try scalar(RendererStorageConfiguration.process.tracker.snapshot()),
                "exportSessions": ImageExportController.activeSessionCount, "exportQueueOperations": ImageExportService.queue.operationCount,
                "pinThumbnailCacheBytes": session.store.thumbnailCacheCost, "pinThumbnailCacheCount": session.store.cachedThumbnailCount,
                "historyThumbnailRequests": 0, "historyThumbnailCacheLimitBytes": 24 * 1_024 * 1_024,
                "historyThumbnailCacheObservedBytes": NSNull(), "ownedOpenDescriptors": try O.ownedFileDescriptors(root, identities: identities).count,
                "fixedRunOwners": ["appDelegate": 1, "historyStore": 1, "pinSessionCoordinator": 1, "pinSessionStore": 1]]
        }
        func action(_ name: String, deadline: Double, _ operation: () async throws -> Void) async throws {
            let began = ProcessInfo.processInfo.systemUptime
            try await operation(); try check(deadline)
            let ended = ProcessInfo.processInfo.systemUptime
            actions.append(["cycle": cycle, "name": name, "startUptimeSeconds": began, "endUptimeSeconds": ended,
                "elapsedSeconds": ended - began])
            try O.require(errors.isEmpty, "Product callback failed: " + errors.joined(separator: "; "))
        }
    }

    private static func measure(_ input: Input, directory: URL, deadline: Double,
        sampler: EditableAnnotationMemorySampler, report: inout [String: Any]) async throws {
        var run: Run? = try Run(directory: directory)
        let fixedOwnership = Ownership()
        fixedOwnership.observe(run!, "run")
        fixedOwnership.observe(run!.app, "appDelegate")
        fixedOwnership.observe(run!.history, "historyStore")
        fixedOwnership.observe(run!.session, "pinSessionCoordinator")
        fixedOwnership.observe(run!.session.store, "pinSessionStore")
        var cleanupDone = false
        defer { if !cleanupDone { try? run?.cleanup() } }
        do {
            report["sessionDateBounds"] = ["start": Date().timeIntervalSinceReferenceDate]
            report["resourcePolicy"] = ["historyMaxItems": 1, "historyMaxBytes": 256 * 1_024 * 1_024,
                "pinMaxItems": 1, "pinMaximumPixels": 100_000_000, "pinMaximumDiskBytes": 536_870_912,
                "retirement": "ordinary history/pin retention replacement, native close, group hide/show, final coordinator termination",
                "firstCycleCold": true, "preliminaryFunctionalWorkInProcess": false,
                "fixedRunOwnersPreservedAcrossCycles": true]
            try await cycles(run!, input: input, directory: directory, deadline: deadline,
                sampler: sampler, report: &report)
            sampler.setPhase("run-cleanup")
            try run!.cleanup(); cleanupDone = true
            try await settle(deadline)
            try O.require(try O.ownedFileDescriptors(run!.root, identities: run!.identities).isEmpty,
                "Unlinked owned descriptor survived run cleanup")
            report["ownedTemporaryDirectoryRemoved"] = !FileManager.default.fileExists(atPath: run!.root.path)
            report["ownedOpenDescriptorsAfterCleanup"] = 0
            report["stages"] = run!.stages; report["checkpoints"] = run!.checkpoints
            report["actions"] = run!.actions; report["evidenceCopies"] = run!.artifacts.report
            report["phaseTimings"] = run!.phaseTimings
            report["afterCloseOwnership"] = run!.observation.report
            report["sessionDateBounds"] = ["start": (report["sessionDateBounds"] as? [String: Double])?["start"] ?? 0,
                "end": Date().timeIntervalSinceReferenceDate]
            run = nil
            try await wait(deadline) { fixedOwnership.alive == 0 && drained() }
            try await settle(deadline)
            try O.require(drained(), "Global projection/export job survived run release")
            report["fixedRunOwnershipAfterRelease"] = fixedOwnership.report
            report["fixedRunOwnersReleased"] = true
        } catch {
            if let current = run {
                report["stages"] = current.stages; report["checkpoints"] = current.checkpoints
                report["actions"] = current.actions; report["evidenceCopies"] = current.artifacts.report
                report["phaseTimings"] = current.phaseTimings
            }
            throw error
        }
    }

    private static func cycles(_ run: Run, input: Input, directory: URL, deadline: Double,
        sampler: EditableAnnotationMemorySampler, report: inout [String: Any]) async throws {
        var results: [[String: Any]] = [], endpoints: [[String: Any]] = []
        let before = try O.memory()
        report["beforeWarmup"] = before
        for ordinal in 1...(warmups + measured) {
            try check(deadline)
            run.cycle = ordinal; run.observation = Ownership()
            let started = ProcessInfo.processInfo.systemUptime, memoryBefore = try O.memory()
            let actionStart = run.actions.count, stageStart = run.stages.count
            let prefix = "cycle-\(ordinal)-"
            var phase = "seed", phaseBegan = ProcessInfo.processInfo.systemUptime
            func finishPhase() throws {
                try O.require(run.phaseTimings.count < 7 * (warmups + measured), "Product phase timing bound exceeded")
                let ended = ProcessInfo.processInfo.systemUptime
                run.phaseTimings.append(["cycle": ordinal, "phase": phase, "startUptimeSeconds": phaseBegan,
                    "endUptimeSeconds": ended, "elapsedSeconds": ended - phaseBegan])
            }
            func nextPhase(_ name: String) throws {
                try finishPhase(); phase = name; phaseBegan = ProcessInfo.processInfo.systemUptime
                sampler.setPhase(prefix + name)
            }
            sampler.setPhase(prefix + "seed")
            let historyID = try await seedEditCropSaveClose(run, input: input, deadline: deadline)
            // The seed helper has returned. Neither its controller nor its
            // original/base/payload locals are retained across this boundary.
            try await wait(deadline) { run.observation.editorCount == 0 && run.observation.alive == 0 && run.observation.attachedWindowCount == 0 && drained() }
            try run.record("seed-closed")
            try nextPhase("reopen")
            let pinID = try await reopenEditUndoPinClose(run, historyID: historyID, input: input, deadline: deadline)
            try await wait(deadline) { run.observation.editorCount == 0 && run.session.livePinCount == 1 && drained() }
            try run.record("history-editor-closed")
            try nextPhase("annotations")
            try await annotationVisibility(run, pinID: pinID, deadline: deadline)
            try nextPhase("group-hide")
            try await run.action("group-hide", deadline: deadline) { try run.session.hideCurrentGroup() }
            try await wait(deadline) { run.observation.alive == 0 && run.observation.attachedWindowCount == 0 && run.session.livePinCount == 0 && drained() }
            try run.record("group-hidden-released")
            try nextPhase("group-show")
            try await showGroup(run, pinID: pinID, deadline: deadline)
            try nextPhase("space-apply")
            try await spaceApplyClose(run, pinID: pinID, input: input, deadline: deadline)
            try nextPhase("release")
            try await wait(deadline) { run.observation.alive == 0 && run.observation.attachedWindowCount == 0 && run.session.livePinCount == 0 && drained() }
            run.identities.formUnion(try O.ownedFileIdentities(run.root))
            let handles = try O.ownedFileDescriptors(run.root, identities: run.identities)
            try O.require(handles.isEmpty, "Cycle-owned descriptor remained open")
            try run.record("cycle-released")
            let after = try O.memory(); endpoints.append(after)
            try finishPhase()
            results.append(["ordinal": ordinal, "warmup": ordinal <= warmups, "cold": ordinal == 1,
                "beforeMemory": memoryBefore, "afterMemory": after, "deltaBytes": delta(memoryBefore, after),
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "historyID": historyID.uuidString, "pinID": pinID.uuidString,
                "actionRange": [actionStart, run.actions.count], "stageRange": [stageStart, run.stages.count],
                "afterReleaseState": try run.state(), "ownershipAfterRelease": run.observation.report,
                "assertions": ["nativeEditUndo": true, "cropApplied": true, "appDelegateHistorySave": true,
                    "appDelegateOpenRecord": true, "nativePinCallback": true, "hiddenGeometry": true,
                    "groupRetiredAndReloaded": true, "spaceSharedOriginal": true, "nativeEighthLayerApplied": true,
                    "committedVersionsPreserved": true, "controllerGraphsRetired": true, "jobsAndDescriptorsDrained": true]])
            report["cycles"] = results; report["completedWarmupCycles"] = min(ordinal, warmups)
            report["completedMeasuredCycles"] = max(0, ordinal - warmups)
            report["stages"] = run.stages; report["checkpoints"] = run.checkpoints
            report["actions"] = run.actions; report["evidenceCopies"] = run.artifacts.report
            report["phaseTimings"] = run.phaseTimings
            if ordinal == warmups { report["afterWarmupBaseline"] = after }
            try write(report, directory.appendingPathComponent("editable-product-resource.json"))
        }
        report["afterMeasuredCycles"] = endpoints.last!
        report["warmupDeltaBytes"] = delta(before, endpoints[warmups - 1])
        report["afterWarmupToMeasuredDeltaBytes"] = delta(endpoints[warmups - 1], endpoints.last!)
        report["lateMeasuredIncrements"] = Array(zip(endpoints.dropLast(), endpoints.dropFirst()).suffix(3)).map { delta($0.0, $0.1) }
    }

    private static func seedEditCropSaveClose(_ run: Run, input: Input, deadline: Double) async throws -> UUID {
        try await run.action("open-editor", deadline: deadline) {
            let original = try O.required(CGImage.read(url: input.directory.appendingPathComponent("original.png")), "Production original decode failed")
            let base = try O.required(CGImage.read(url: input.directory.appendingPathComponent("base.png")), "Production base decode failed")
            try O.require(original.width == width && original.height == height && base.width == width && base.height == height,
                "Decoded input dimensions changed")
            var document = input.document; document.cropViewportInBase = nil
            let payload = EditableCapturePayload(document: document, originalImage: original, baseImage: base)
            try O.require(run.app.openEditor(base, editable: payload, encodedBackingBytes: input.encodedBytes,
                showAdmissionNotice: false), "Product editor admission failed")
            try await settle(deadline)
        }
        let editor = try currentEditor(run)
        run.observation.editor(editor)
        editor.onOutputError = { [weak run] error in run?.errors.append(error.localizedDescription) }
        try run.record("editor-open")
        try await run.action("seed-edit-undo", deadline: deadline) {
            let before = try documentData(editor)
            try nativeMark(editor); try undo(editor)
            try O.require(try documentData(editor) == before, "Seed native undo changed document")
        }
        try await run.action("native-crop", deadline: deadline) {
            try selectTool(.crop, editor: editor)
            try drag(editor.annotationCanvas, CGPoint(x: crop.minX + 0.25, y: crop.minY + 0.25),
                CGPoint(x: crop.maxX - 0.25, y: crop.maxY - 0.25))
            try click("editor.applyCrop", editor: editor)
            try O.require(editor.annotationCanvas.cropViewportInBase == crop, "Native crop viewport changed")
            try O.require(try documentData(editor) == EditableAnnotationDocumentCodec.encode(input.document), "Native crop changed certified metadata")
        }
        let previous = Set(run.history.records.map(\.id))
        try await run.action("history-save", deadline: deadline) {
            try editorMenu("saveResult", editor)
            try await wait(deadline) { !editor.outputProjectionIsPending && drained() }
        }
        try O.require(run.errors.isEmpty, "History save callback failed")
        let saved = try O.required(run.history.records.first { !previous.contains($0.id) }, "Native save produced no history record")
        try snapshot(run, stage: "history-save", historyID: saved.id)
        try run.record("history-saved")
        try await run.action("seed-close", deadline: deadline) {
            try click("editor.cancel", editor: editor)
            try O.require(editor.isClosed && run.app.controllers.isEmpty, "Seed close did not release AppDelegate ownership")
        }
        return saved.id
    }

    private static func reopenEditUndoPinClose(_ run: Run, historyID: UUID, input: Input, deadline: Double) async throws -> UUID {
        try await run.action("history-reopen", deadline: deadline) {
            let record = try O.required(run.history.records.first { $0.id == historyID }, "Saved history record missing")
            // This is the actual product entry point, including its normal
            // admission and error presentation; the outer launcher bounds an
            // unexpected native modal error that cannot cooperate with await.
            run.app.openRecord(record); try await settle(deadline)
        }
        let editor = try currentEditor(run)
        run.observation.editor(editor)
        editor.onOutputError = { [weak run] error in run?.errors.append(error.localizedDescription) }
        try O.require(editor.annotationCanvas.tool == .select, "History restore did not select native select tool")
        try O.require(try documentData(editor) == EditableAnnotationDocumentCodec.encode(input.document), "History metadata continuity failed")
        try run.record("history-reopened")
        try await run.action("reopen-edit-undo", deadline: deadline) {
            let before = try documentData(editor)
            try nativeMark(editor); try undo(editor)
            try O.require(try documentData(editor) == before, "Reopened native undo changed document")
        }
        let previous = Set(run.session.store.entries.map(\.id))
        try await run.action("native-pin", deadline: deadline) {
            try editorMenu("pinResult", editor)
            try await wait(deadline) { !editor.outputProjectionIsPending && drained() }
        }
        let pinID = try O.required(run.session.store.entries.first { !previous.contains($0.id) }?.id, "Native pin did not commit")
        let pin = try livePin(run, pinID)
        run.observation.pin(pin)
        pin.onAnnotationError = { [weak run] error in run?.errors.append(error.localizedDescription) }
        try snapshot(run, stage: "pin-before-apply", pinID: pinID)
        try run.record("pin-created")
        try await run.action("history-editor-close", deadline: deadline) {
            try click("editor.cancel", editor: editor)
            try O.require(editor.isClosed && run.app.controllers.isEmpty, "History editor failed to close")
        }
        return pinID
    }

    private static func annotationVisibility(_ run: Run, pinID: UUID, deadline: Double) async throws {
        let pin = try livePin(run, pinID), before = try committedAssets(run, pinID)
        let currentIdentity = ObjectIdentifier(pin.currentImage)
        try await run.action("annotations-hide", deadline: deadline) {
            try pinMenu("toggleAnnotationsHidden", pin)
            try await wait(deadline) { !pin.annotationVisibilityIsPending && drained() }
        }
        try O.require(pin.annotationsHidden && pin.retainedAnnotationPreviewCount == 1
            && pin.displayedImage.width == pin.currentImage.width && pin.displayedImage.height == pin.currentImage.height,
            "Hidden annotation preview count/geometry changed")
        try run.record("annotations-hidden")
        try await run.action("annotations-show", deadline: deadline) {
            try pinMenu("toggleAnnotationsHidden", pin)
            try await wait(deadline) { !pin.annotationVisibilityIsPending && drained() }
        }
        try O.require(!pin.annotationsHidden && pin.retainedAnnotationPreviewCount == 0
            && ObjectIdentifier(pin.currentImage) == currentIdentity && (try committedAssets(run, pinID)) == before,
            "Annotation visibility changed committed content or retained preview")
        try run.record("annotations-shown")
    }

    private static func showGroup(_ run: Run, pinID: UUID, deadline: Double) async throws {
        try await run.action("group-show", deadline: deadline) {
            try run.session.showCurrentGroup(); try await settle(deadline)
        }
        let pin = try livePin(run, pinID)
        run.observation.pin(pin)
        pin.onAnnotationError = { [weak run] error in run?.errors.append(error.localizedDescription) }
        try O.require(run.session.livePinCount == 1 && pin.retainedEditableBaseCount == 0,
            "Group reload retained an editable base without editor")
        try run.record("group-shown")
    }

    private static func spaceApplyClose(_ run: Run, pinID: UUID, input: Input, deadline: Double) async throws {
        let pin = try livePin(run, pinID)
        try await run.action("space-open", deadline: deadline) {
            let canvas = try pinCanvas(pin)
            canvas.keyDown(with: try key(canvas, " ", 49))
            try await settle(deadline)
        }
        try await run.action("space-edit", deadline: deadline) { try spaceEditAndApply(run, pinID: pinID, input: input) }
        try run.record("space-edited")
        try await run.action("apply-to-pin", deadline: deadline) {
            try click("editor.applyToPin", editor: O.required(pin.annotationEditor, "Space editor missing"))
            try await wait(deadline) { pin.annotationEditor == nil && drained() }
        }
        try O.require(!pin.annotationsHidden && pin.retainedEditableBaseCount == 0 && run.errors.isEmpty,
            "Apply failed or retained editable base")
        try snapshot(run, stage: "pin-after-apply", pinID: pinID)
        try run.record("pin-applied")
        try await run.action("pin-close", deadline: deadline) {
            try pinMenu("closePin", pin)
            try O.require(run.session.livePinCount == 0, "Native pin close did not retire session controller")
        }
        try snapshot(run, stage: "pin-closed", pinID: pinID)
    }

    // Synchronous helper returns before Apply awaits, so the annotation editor
    // and shared payload inspected here are not retained after native close.
    private static func spaceEditAndApply(_ run: Run, pinID: UUID, input: Input) throws {
        let pin = try livePin(run, pinID)
        let editor = try O.required(pin.annotationEditor, "Space did not open annotation editor")
        run.observation.editor(editor)
        let payload = try editor.editablePayload()
        try O.require(payload.originalImage === pin.image && editor.annotationCanvas.tool == .select,
            "Space failed to share original or restore select tool")
        try O.require(try documentData(editor) == EditableAnnotationDocumentCodec.encode(input.document), "Space changed saved metadata")
        try nativeMark(editor)
        try O.require(editor.annotationCanvas.annotations.count == 8, "Apply draft lacks eighth layer")
    }

    /// Copies encoded committed files, never decodes or normalizes their pixels.
    /// Every source version is streamed and verified even when content deduplicates.
    @MainActor private final class Artifacts {
        let directory: URL
        private var sourceFiles = 0, streamedBytes = 0, uniqueFiles = 0, uniqueBytes = 0
        private var seconds = 0.0
        static let maximumStreamedBytes = 2_147_483_648
        init(directory: URL) throws {
            self.directory = directory
            try safeDirectory(directory.appendingPathComponent("artifacts"), create: true)
            try safeDirectory(directory.appendingPathComponent("artifacts/blobs"), create: true)
        }
        func copy(_ source: URL, extension suffix: String, declaredBytes: Int? = nil,
                  declaredSHA256: String? = nil) throws -> [String: Any] {
            try O.require(["png", "json", "annotations"].contains(suffix), "Unsafe evidence extension")
            let maximum = suffix == "png" ? maximumPNGBytes : maximumMetadataBytes
            let size = try safeSize(source, maximum: maximum)
            try O.require(declaredBytes == nil || declaredBytes == size, "Committed evidence length differs from index")
            try O.require(sourceFiles < maximumEvidenceFiles && size <= Self.maximumStreamedBytes - streamedBytes,
                "Encoded evidence streaming bound exceeded")
            let began = ProcessInfo.processInfo.systemUptime, before = try memoryCounters()
            let temporary = directory.appendingPathComponent("artifacts/blobs/.copy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let copied = try stream(source, to: temporary, maximum: maximum)
            try O.require(declaredSHA256 == nil || declaredSHA256 == copied.sha256, "Committed evidence digest differs from index")
            let relative = "artifacts/blobs/" + copied.sha256 + "." + suffix
            let destination = directory.appendingPathComponent(relative)
            let duplicate = FileManager.default.fileExists(atPath: destination.path)
            if duplicate {
                try O.require(try safeSize(destination, maximum: maximum) == copied.bytes, "Existing content-addressed evidence changed")
            } else {
                try O.require(uniqueFiles < maximumEvidenceFiles && copied.bytes <= maximumEvidenceBytes - uniqueBytes,
                    "Encoded evidence output bound exceeded")
                try FileManager.default.moveItem(at: temporary, to: destination)
                uniqueFiles += 1; uniqueBytes += copied.bytes
            }
            sourceFiles += 1; streamedBytes += copied.bytes
            let elapsed = ProcessInfo.processInfo.systemUptime - began; seconds += elapsed
            return ["sourceFilename": source.lastPathComponent, "evidenceFilename": relative,
                "byteCount": copied.bytes, "sha256": copied.sha256, "streamedBytes": copied.bytes,
                "copySeconds": elapsed, "memoryBefore": before, "memoryAfter": try memoryCounters(), "deduplicated": duplicate]
        }
        var report: [String: Any] {
            ["sourceFiles": sourceFiles, "streamedBytes": streamedBytes, "uniqueFiles": uniqueFiles,
                "uniqueBytes": uniqueBytes, "copySeconds": seconds, "bufferBytes": copyBufferBytes,
                "maximumSourceFiles": maximumEvidenceFiles, "maximumUniqueFiles": maximumEvidenceFiles,
                "maximumUniqueBytes": maximumEvidenceBytes, "maximumStreamedBytes": Self.maximumStreamedBytes,
                "excludedFromProcessMemory": false, "rasterDecodeCount": 0, "rasterNormalizationCount": 0]
        }
    }

    private static func snapshot(_ run: Run, stage: String, historyID: UUID? = nil, pinID: UUID? = nil) throws {
        try O.require(drained() && run.stages.count < maximumStages && (historyID != nil) != (pinID != nil), "Snapshot boundary invalid")
        let sourceDirectory: URL, descriptor: EditableCaptureAsset, recordID: UUID, store: String
        if let historyID {
            let record = try O.required(run.history.records.first { $0.id == historyID }, "Snapshot history missing")
            descriptor = try O.required(record.editableCapture, "History editable descriptor missing")
            sourceDirectory = run.history.directory; recordID = historyID; store = "history"
        } else {
            let entry = try O.required(run.session.store.entry(id: pinID!), "Snapshot pin missing")
            descriptor = try O.required(entry.editableCapture, "Pin editable descriptor missing")
            sourceDirectory = run.session.store.directory; recordID = entry.id; store = "pin"
        }
        try O.require(descriptor.isValid, "Snapshot descriptor invalid")
        let expected = stage == "pin-after-apply" || stage == "pin-closed" ? "eight" : "seven"
        let index = try run.artifacts.copy(sourceDirectory.appendingPathComponent("index.json"), extension: "json")
        let document = try run.artifacts.copy(sourceDirectory.appendingPathComponent(descriptor.documentFilename), extension: "annotations",
            declaredBytes: Int(descriptor.documentByteCount), declaredSHA256: descriptor.documentSHA256)
        var rasters: [[String: Any]] = []
        for (role, asset) in [("original", descriptor.original), ("base", descriptor.base),
                              ("current", try O.required(descriptor.current, "Snapshot current descriptor missing"))] {
            var copied = try run.artifacts.copy(sourceDirectory.appendingPathComponent(asset.filename), extension: "png",
                declaredBytes: Int(asset.byteCount), declaredSHA256: asset.sha256)
            copied["role"] = role; copied["expectedState"] = role == "current" ? expected : role
            copied["width"] = asset.width; copied["height"] = asset.height; copied["assetID"] = asset.assetID.uuidString
            rasters.append(copied)
        }
        run.stages.append(["cycle": run.cycle, "stage": stage, "id": "\(run.cycle)-" + stage,
            "store": store, "recordID": recordID.uuidString, "expectedState": expected,
            "index": index, "document": document, "rasters": rasters])
        run.identities.formUnion(try O.ownedFileIdentities(run.root))
        try O.require(try O.ownedFileDescriptors(run.artifacts.directory, identities: []).isEmpty, "Evidence-copy descriptor survived snapshot")
    }

    private static func loadInput(_ request: Request, identity: [String: Any]) throws -> Input {
        try safeDirectory(request.input, create: false)
        let manifestData = try read(request.input.appendingPathComponent("inputs.json"), maximum: 262_144)
        let manifest = try object(manifestData), manifestHash = hash(manifestData)
        try O.require(manifest["protocol"] as? String == "editable-components-v1" && manifest["status"] as? String == "prepared"
            && manifest["fixtureSourceCommit"] as? String == "c80e94de9cf712e118009700feacbd707356e0a3", "Product input preparation identity invalid")
        try sameIdentity(manifest, identity)
        let producer = try positive(manifest["processIdentifier"])
        let certificateData = try read(request.certificate, maximum: 2_097_152)
        let certificate = try object(certificateData)
        try sameIdentity(certificate, identity)
        let certificatePID = try positive(certificate["processIdentifier"])
        try O.require(producer != Int(getpid()) && certificatePID != Int(getpid()) && producer != certificatePID,
            "Product preparation/certification require separate processes")
        try O.require(certificate["inputManifestSHA256"] as? String == manifestHash, "Certificate is not bound to input")
        let entries = try O.required(manifest["assets"] as? [[String: Any]], "Input assets missing")
        try O.require(entries.count == 3 && entries.compactMap { $0["role"] as? String } == ["original", "base", "current"], "Input roles differ")
        var originalBytes = 0, baseBytes = 0
        for entry in entries {
            let role = entry["role"] as! String, expected = role == "current" ? "seven" : role
            let imageWidth = role == "current" ? 2414 : width, imageHeight = role == "current" ? 1574 : height
            try O.require(entry["width"] as? Int == imageWidth && entry["height"] as? Int == imageHeight
                && entry["rawSHA256"] as? String == expectedHashes[expected]
                && entry["rawBytes"] as? Int == imageWidth * imageHeight * 4
                && entry["pngFile"] as? String == role + ".png" && entry["rawFile"] as? String == role + ".rgba",
                "Input pixel recipe differs")
            // Only original/base PNGs are measured-process inputs. The unused
            // current and all raw files are bound by the independent certificate.
            if role != "current" {
                let file = try stream(request.input.appendingPathComponent(role + ".png"), maximum: maximumPNGBytes)
                try O.require(entry["pngSHA256"] as? String == file.sha256 && entry["pngBytes"] as? Int == file.bytes,
                    "Certified encoded input changed")
                if role == "original" { originalBytes = file.bytes } else { baseBytes = file.bytes }
            }
        }
        try O.require(manifest["originalAndBaseDistinct"] as? Bool == true && manifest["layerCount"] as? Int == 7
            && manifest["documentFile"] as? String == "document.annotations", "Input document recipe differs")
        let documentData = try read(request.input.appendingPathComponent("document.annotations"), maximum: maximumMetadataBytes)
        try O.require(manifest["documentSHA256"] as? String == hash(documentData) && manifest["documentBytes"] as? Int == documentData.count,
            "Certified document changed")
        let document = try EditableAnnotationDocumentCodec.decode(documentData)
        try O.require(document.originalPixelWidth == width && document.originalPixelHeight == height
            && document.basePixelWidth == width && document.basePixelHeight == height
            && document.originalAssetID != document.baseAssetID && document.baseProvenance == .derivedRaster
            && document.cropViewportInBase == crop && document.annotations.count == 7
            && document.capturedAt == Date(timeIntervalSince1970: 0) && document.captureTimeZoneIdentifier == "UTC"
            && !document.captureTimestampKnown, "Certified metadata dimensions/crop/timestamp changed")
        if request.mode == .certify {
            try O.require(certificate["protocol"] as? String == "editable-components-v1"
                && certificate["mode"] as? String == "certify" && certificate["status"] as? String == "certified",
                "Independent component certificate missing")
            let validations = try O.required(certificate["validations"] as? [[String: Any]], "Component validations missing")
            try O.require(validations.count == 4 && validations.compactMap { $0["label"] as? String } == ["original", "base", "current", "controller-replay"], "Incomplete independent component certificate")
            for validation in validations {
                let label = validation["label"] as? String ?? ""
                let role = ["current", "controller-replay"].contains(label) ? "seven" : label
                let bytes = role == "seven" ? 2414 * 1574 * 4 : width * height * 4
                try O.require(validation["sha256"] as? String == expectedHashes[role]
                    && validation["comparedBytes"] as? Int == bytes && validation["exact"] as? Bool == true, "Component pixel certificate mismatch")
            }
        } else {
            try O.require(certificate["protocol"] as? String == protocolID && certificate["schemaVersion"] as? Int == 1
                && certificate["mode"] as? String == "certify" && certificate["status"] as? String == "certified"
                && certificate["originalDocumentBase64"] as? String == documentData.base64EncodedString(), "Independent product certificate missing")
            let goldens = try O.required(certificate["goldens"] as? [[String: Any]], "Product goldens missing")
            try O.require(goldens.count == 4 && goldens.compactMap { $0["role"] as? String } == ["original", "base", "seven", "eight"], "Product goldens incomplete")
            for golden in goldens {
                let role = golden["role"] as! String, large = role == "original" || role == "base"
                try O.require(golden["rawSHA256"] as? String == expectedHashes[role]
                    && golden["width"] as? Int == (large ? width : 2414) && golden["height"] as? Int == (large ? height : 1574)
                    && golden["rawBytes"] as? Int == (large ? width * height * 4 : 2414 * 1574 * 4)
                    && golden["rawFile"] as? String == role + ".rgba", "Product golden identity changed")
            }
            let selected = try O.required(certificate["configuration"] as? [String: Any], "Certificate configuration absent")
            try O.require(selected["drawingStrategy"] as? String == "reference" && selected["rendererStorageStrategy"] as? String == "native"
                && selected["effectContextPolicy"] as? String == "reference"
                && selected["drawingProductionDefault"] as? String == DrawingRasterStrategy.productionDefault.rawValue
                && certificate["requestedDrawingStrategy"] as? String == "reference"
                && certificate["drawingOverridePresent"] as? Bool == true,
                "Golden certification must explicitly select reference drawing in the same compiled default")
        }
        try O.require(try O.ownedFileDescriptors(request.input, identities: []).isEmpty, "Certified input descriptor remained open")
        return Input(directory: request.input, document: document, manifestSHA256: manifestHash,
            certificateSHA256: hash(certificateData), producerPID: producer, certificatePID: certificatePID,
            originalBytes: originalBytes, baseBytes: baseBytes)
    }

    /// Independent, unmeasured reference process. Every golden is anchored to
    /// completed build113/source129 canonical hashes, including the eighth mark.
    /// Never accepts a measured output as an expected result.
    private static func certify(_ input: Input, report initial: [String: Any], directory: URL, deadline: Double) throws -> [String: Any] {
        var report = initial
        let start = Date().timeIntervalSinceReferenceDate
        let original = try O.required(CGImage.read(url: input.directory.appendingPathComponent("original.png")), "Certificate original decode failed")
        let base = try O.required(CGImage.read(url: input.directory.appendingPathComponent("base.png")), "Certificate base decode failed")
        var goldens: [[String: Any]] = []
        for (role, image) in [("original", original), ("base", base)] {
            goldens.append(try certifyPixels(image, role: role, directory: directory))
        }
        var applied = input.document
        let canvas = ImageEditorCanvas(image: base)
        canvas.restoreCaptureTimestamp(input.document.capturedAt, timeZoneIdentifier: input.document.captureTimeZoneIdentifier,
            known: input.document.captureTimestampKnown)
        applied.annotations.append(canvas.makeAnnotation(tool: .rectangle, points: markPoints(crop)))
        for (role, document) in [("seven", input.document), ("eight", applied)] {
            try check(deadline)
            let full = try O.required(ImageEditorRenderer.render(image: base, annotations: document.annotations), "Golden reference render failed")
            let cropped = try O.required(ImageEditorRenderer.crop(image: full, to: crop), "Golden reference crop failed")
            let decorated = try ImageOutputDecorationRenderer.project(flattened: cropped, decoration: document.outputDecoration)
            goldens.append(try certifyPixels(decorated, role: role, directory: directory))
        }
        report["goldens"] = goldens
        report["originalDocumentBase64"] = try EditableAnnotationDocumentCodec.encode(input.document).base64EncodedString()
        report["appliedDocumentBase64"] = try EditableAnnotationDocumentCodec.encode(applied).base64EncodedString()
        report["sessionDateBounds"] = ["start": start, "end": Date().timeIntervalSinceReferenceDate]
        report["goldenSource"] = "Independent build113 original/base/seven and source129 full native 4K eighth-layer certified canonical SHA256 constants"
        report["memoryComparisonExcluded"] = true; report["status"] = "certified"
        return report
    }

    private static func certifyPixels(_ image: CGImage, role: String, directory: URL) throws -> [String: Any] {
        let context = try O.required(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Golden canonical allocation failed")
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let count = image.width * image.height * 4
        let data = Data(bytesNoCopy: try O.required(context.data, "Golden canonical data missing"), count: count, deallocator: .none)
        let digest = withExtendedLifetime(context) { hash(data) }
        try O.require(digest == expectedHashes[role], "Independent audited golden mismatch for " + role)
        try withExtendedLifetime(context) { try data.write(to: directory.appendingPathComponent(role + ".rgba"), options: .withoutOverwriting) }
        return ["role": role, "rawFile": role + ".rgba", "rawBytes": count, "rawSHA256": digest,
            "width": image.width, "height": image.height, "canonical": EditableComponentFixture.canonical(image.width, image.height)]
    }

    private static func currentEditor(_ run: Run) throws -> ImageEditorController {
        let editors = run.app.controllers.compactMap { $0 as? ImageEditorController }.filter { !$0.isClosed }
        try O.require(editors.count == 1, "Expected exactly one AppDelegate-owned editor")
        return editors[0]
    }
    private static func livePin(_ run: Run, _ id: UUID) throws -> PinController {
        try O.required(run.session.liveControllers[id], "Product pin controller missing")
    }
    private static func documentData(_ editor: ImageEditorController) throws -> Data {
        try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document)
    }
    private static func committedAssets(_ run: Run, _ id: UUID) throws -> EditableCaptureAsset {
        // Presentation metadata may legitimately debounce during visibility.
        // Asset/document equality is the invariant relevant to pixel content.
        let entry = try O.required(run.session.store.entry(id: id), "Pin entry missing")
        return try O.required(entry.editableCapture, "Pin editable assets missing")
    }
    private static func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) }
    }
    private static func click(_ id: String, editor: ImageEditorController) throws {
        let root = try O.required(editor.window?.contentView, "Editor content missing")
        let button = try O.required(descendants(root).first { $0.identifier?.rawValue == id } as? NSButton, "Native button missing: " + id)
        try O.require(button.isEnabled && !button.isHiddenOrHasHiddenAncestor, "Native button unavailable: " + id)
        let point = root.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        let hit = try O.required(root.hitTest(point), "Native button hit missed: " + id)
        try O.require(hit === button || hit.isDescendant(of: button), "Native button obscured: " + id)
        button.performClick(nil)
    }
    private static func editorMenu(_ action: String, _ editor: ImageEditorController) throws {
        let selector = NSSelectorFromString(action), views = descendants(editor.window?.contentView)
        if let button = views.compactMap({ $0 as? NSButton }).first(where: { $0.action == selector && !$0.isHiddenOrHasHiddenAncestor }) {
            try O.require(button.isEnabled, "Native editor action disabled"); button.performClick(nil); return
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
           !button.isHiddenOrHasHiddenAncestor {
            try O.require(button.isEnabled, "Native tool disabled"); button.performClick(nil)
        } else {
            let popup = try O.required(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == "editor.more" } as? NSPopUpButton, "Native tool menu missing")
            let menu = try O.required(popup.menu, "Native tool menu absent")
            let index = try O.required(menu.items.firstIndex { $0.title == tool.title }, "Native tool action missing")
            menu.performActionForItem(at: index)
        }
        try O.require(editor.annotationCanvas.tool == tool, "Native tool selection failed")
    }
    private static func markPoints(_ rectangle: CGRect) -> [CGPoint] {
        [CGPoint(x: rectangle.minX + rectangle.width * 0.12, y: rectangle.minY + rectangle.height * 0.7),
         CGPoint(x: rectangle.minX + rectangle.width * 0.28, y: rectangle.minY + rectangle.height * 0.84)]
    }
    private static func nativeMark(_ editor: ImageEditorController) throws {
        let oldIDs = Set(editor.annotationCanvas.annotations.map(\.id)), before = try documentData(editor)
        let count = editor.annotationCanvas.annotations.count
        try selectTool(.rectangle, editor: editor)
        let points = markPoints(editor.annotationCanvas.visibleImageRect)
        try drag(editor.annotationCanvas, points[0], points[1])
        let added = editor.annotationCanvas.annotations.filter { !oldIDs.contains($0.id) }
        try O.require(editor.annotationCanvas.annotations.count == count + 1 && added.count == 1,
            "Native rectangle gesture did not create exactly one mark")
        try O.require(added[0].tool == .rectangle && added[0].points.count == 2
            && abs(added[0].points[0].x - points[0].x) < 0.01 && abs(added[0].points[0].y - points[0].y) < 0.01
            && abs(added[0].points[1].x - points[1].x) < 0.01 && abs(added[0].points[1].y - points[1].y) < 0.01
            && (try documentData(editor)) != before, "Native rectangle geometry/document changed unexpectedly")
    }
    private static func drag(_ canvas: ImageEditorCanvas, _ start: CGPoint, _ end: CGPoint) throws {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil)
            let event = try O.required(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Native mouse event unavailable")
            if type == .leftMouseDown {
                let root = try O.required(canvas.window?.contentView, "Canvas root missing")
                let hit = root.hitTest(root.convert(location, from: nil))
                try O.require(hit === canvas || hit?.isDescendant(of: canvas) == true, "Native canvas hit-test missed")
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
            .compactMap(\.documentView).first { $0.menu === menu && $0.acceptsFirstResponder }, "Native pin responder missing")
        try O.require(canvas.window === pin.window && pin.window?.makeFirstResponder(canvas) == true, "Pin canvas is not the native key responder")
        return canvas
    }
    private static func drained() -> Bool {
        !EditorOutputProjection.shared.isBusy && EditorOutputProjection.shared.reservedBytes == 0
            && EditorOutputProjection.shared.queue.operationCount == 0
            && ImageExportController.activeSessionCount == 0 && ImageExportService.queue.operationCount == 0
    }
    private static func wait(_ deadline: Double, _ predicate: () -> Bool) async throws {
        while !predicate() { try check(deadline); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    private static func settle(_ deadline: Double) async throws {
        try check(deadline); try await Task.sleep(nanoseconds: 150_000_000); try check(deadline)
    }
    private static func check(_ deadline: Double) throws {
        try Task.checkCancellation()
        try O.require(ProcessInfo.processInfo.systemUptime < deadline, "Product fixture cooperative deadline exceeded")
    }
    private static func configuration() throws -> [String: Any] {
        let drawing = try DrawingRasterConfiguration.process.selectedStrategy()
        let storage = try RendererStorageConfiguration.process.selectedStrategy()
        let effect = try EffectContextConfiguration.process.selectedPolicy()
        let requested = ProcessInfo.processInfo.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] ?? DrawingRasterStrategy.productionDefault.rawValue
        try O.require(drawing.rawValue == requested && storage == .native && effect == .reference, "Product fixture strategy changed")
        return ["drawingStrategy": drawing.rawValue, "rendererStorageStrategy": storage.rawValue,
            "effectContextPolicy": effect.rawValue, "fixtureMutatedProductionDefaults": false,
            "drawing": try scalar(DrawingRasterConfiguration.process.tracker.snapshot()),
            "rendererStorage": try scalar(RendererStorageConfiguration.process.tracker.snapshot()),
            "effects": try scalar(EffectContextConfiguration.process.tracker.snapshot()),
            "drawingOriginalFormatFallback": "Unsupported layouts and profiles retain the original native drawing path; no model/source normalization or fallback on conversion failure",
            "drawingProductionDefault": DrawingRasterStrategy.productionDefault.rawValue,
            "rendererStorageProductionDefault": RendererStorageStrategy.productionDefault.rawValue,
            "effectContextProductionDefault": EffectContextPolicy.productionDefault.rawValue]
    }
    private static func identity() throws -> [String: Any] {
        let executable = try O.required(Bundle.main.executableURL, "Installed executable missing")
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        let file = try stream(executable, maximum: 268_435_456)
        return ["sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "executableSHA256": file.sha256, "executableBytes": file.bytes,
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
            "architecture": architecture, "processIdentifier": Int(getpid()),
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString]
    }
    private static func sameIdentity(_ other: [String: Any], _ current: [String: Any]) throws {
        for field in ["sourceCommit", "executableSHA256", "executableBytes", "bundlePath", "architecture", "operatingSystem"] {
            try O.require(String(describing: other[field] ?? NSNull()) == String(describing: current[field] ?? NSNull()), "Cross-process identity differs: " + field)
        }
    }
    private static func memoryCounters() throws -> [String: Any] {
        let reading = try O.memory()
        return ["uptimeSeconds": reading["uptimeSeconds"]!, "counters": reading["counters"]!]
    }
    private static func scalar<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func delta(_ before: [String: Any], _ after: [String: Any]) -> [String: Int64] {
        guard let a = before["counters"] as? [String: Int64], let b = after["counters"] as? [String: Int64] else { return [:] }
        return Dictionary(uniqueKeysWithValues: EditableAnnotationMemorySampler.required.compactMap { field in
            guard let x = a[field], let y = b[field] else { return nil }; return (field, y - x)
        })
    }

    static func safeDirectory(_ directory: URL, create: Bool) throws {
        try O.require(directory.isFileURL && directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
            "Unsafe product directory")
        // Foundation can leave an unresolved URL unchanged when its final
        // component does not exist. Inspect every ancestor before any mkdir,
        // including symlinks above a missing leaf, instead of trusting equality.
        try checkedDirectoryAncestors(directory, includingLeaf: true, allowingMissing: create)
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var info = stat()
        try O.require(directory.path.withCString { lstat($0, &info) } == 0 && (info.st_mode & S_IFMT) == S_IFDIR,
            "Product directory missing or unsafe")
    }
    /// Canonicalize only the trusted OS temporary anchor. Foundation URL
    /// resolution can abbreviate /private/var to its /var symlink on macOS.
    /// Requested input/evidence paths never use this canonicalization escape.
    static func systemTemporaryDirectory() throws -> URL {
        let pointer = FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }
        guard let pointer else { throw O.failure("Cannot resolve the system temporary directory") }
        defer { free(pointer) }
        let directory = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        try checkedDirectoryAncestors(directory, includingLeaf: true, allowingMissing: false)
        return directory
    }
    private static func checkedDirectoryAncestors(_ url: URL, includingLeaf: Bool, allowingMissing: Bool) throws {
        // Walk the supplied filesystem spelling, not standardizedFileURL:
        // Foundation can abbreviate canonical /private/var back to /var, which
        // is itself a system symlink. Lexical parent removal introduces none.
        func parent(_ path: String) -> String {
            guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
            return String(path[..<slash])
        }
        var path = url.path
        try O.require(path.hasPrefix("/") && path.utf8.count <= 4096, "Product directory path must be absolute and bounded")
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if !includingLeaf { path = parent(path) }
        var count = 0
        while true {
            count += 1; try O.require(count <= 128, "Product path depth exceeds bound")
            var info = stat()
            let result = path.withCString { lstat($0, &info) }
            if result == 0 {
                try O.require((info.st_mode & S_IFMT) == S_IFDIR,
                    "Product directory ancestor rejected (mode \(info.st_mode & S_IFMT), depth \(count)): " + path)
            } else {
                let code = errno
                try O.require(allowingMissing && code == ENOENT,
                    "Product directory ancestor inspection failed (errno \(code), depth \(count)): " + path)
            }
            if path == "/" { break }
            path = parent(path)
        }
    }
    static func safeSize(_ url: URL, maximum: Int) throws -> Int {
        try O.require(url.isFileURL && url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
            "Unsafe product input path")
        var info = stat()
        try O.require(url.path.withCString { lstat($0, &info) } == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_size > 0 && info.st_size <= maximum, "Product file missing, unsafe or oversized")
        return Int(info.st_size)
    }
    static func stream(_ source: URL, to destination: URL? = nil, maximum: Int) throws -> (bytes: Int, sha256: String) {
        let size = try safeSize(source, maximum: maximum)
        let descriptor = source.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        try O.require(descriptor >= 0, "Cannot open bounded encoded source")
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        try O.require(fstat(descriptor, &before) == 0 && (before.st_mode & S_IFMT) == S_IFREG && before.st_size == size,
            "Encoded source changed at open")
        var output: FileHandle?
        if let destination {
            try O.require(destination.isFileURL && destination.standardizedFileURL.path == destination.resolvingSymlinksInPath().standardizedFileURL.path,
                "Unsafe encoded evidence destination")
            try checkedDirectoryAncestors(destination, includingLeaf: false, allowingMissing: false)
            let target = destination.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
            try O.require(target >= 0, "Cannot create bounded encoded evidence")
            output = FileHandle(fileDescriptor: target, closeOnDealloc: true)
        }
        defer { try? output?.close() }
        var count = 0, hasher = SHA256()
        while let data = try input.read(upToCount: copyBufferBytes), !data.isEmpty {
            try O.require(data.count <= size - count, "Encoded source grew during copy")
            count += data.count; hasher.update(data: data); try output?.write(contentsOf: data)
        }
        var after = stat(), path = stat()
        try O.require(count == size && fstat(descriptor, &after) == 0 && source.path.withCString({ lstat($0, &path) }) == 0
            && after.st_dev == before.st_dev && after.st_ino == before.st_ino && after.st_size == before.st_size
            && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
            && after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec && after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
            && path.st_dev == before.st_dev && path.st_ino == before.st_ino && (path.st_mode & S_IFMT) == S_IFREG,
            "Encoded source changed while streaming")
        try output?.close(); output = nil
        return (count, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let size = try safeSize(url, maximum: maximum)
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        try O.require(descriptor >= 0, "Cannot open bounded metadata")
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        try O.require(fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size == size, "Metadata changed at open")
        let data = try handle.read(upToCount: size + 1) ?? Data()
        try O.require(data.count == size, "Metadata length changed while reading"); return data
    }
    private static func positive(_ value: Any?) throws -> Int {
        guard let integer = value as? Int, integer > 0 else { throw O.failure("Positive input integer missing") }; return integer
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        try O.required(JSONSerialization.jsonObject(with: data) as? [String: Any], "Product JSON object invalid")
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func write(_ report: [String: Any], _ target: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try O.require(data.count <= maximumReportBytes, "Product report exceeds 8 MiB")
        try data.write(to: target, options: .atomic)
    }
}
