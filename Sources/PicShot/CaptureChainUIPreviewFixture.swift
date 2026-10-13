import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// A bounded installed-app witness for one deliberately saved native chain.
/// Acquisition alone is synthetic. Save publication, checked private-pasteboard
/// delivery, durable Pin, the app admission owner and manager actions are real.
@MainActor
enum CaptureChainUIPreviewFixture {
    static func verify(evidenceDirectory directory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let files = FileManager.default, started = ProcessInfo.processInfo.systemUptime
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let execution = ExecutionEvidence()
        var report: [String: Any] = [
            "schemaVersion": 1, "status": "running", "installerAcceptance": false,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "source": "Fixture-owned native numbered image; one independent decoded selection per run",
            "acquisition": "Injected CaptureChainRunner.Dependencies.capture; no ScreenCaptureKit acquisition",
            "realScreenCaptureClaimed": false, "screenCaptureAPICalled": false,
            "permissionRequested": false, "globalInputPosted": false, "networkUsed": false,
            "userHistoryReadOrWritten": false, "standardDefaultsReadOrWritten": false,
            "generalPasteboardReadOrWritten": false, "productAppDelegateExercised": false,
            "productSaveWorkflowDeliveryExercised": false, "productPersistentPinExercised": false,
            "limitations": ["Synthetic acquisition does not prove desktop selection or ScreenCaptureKit",
                "The first checked clipboard recipient write is deliberately rejected",
                "Images show cached owned native content, not a desktop screenshot",
                "Weak-owner checks and bounded reservations are not an RSS or zero-leak claim"]
        ]
        var root: URL?
        var safeToRemove = true
        try write(report, directory: directory)
        do {
            try require(ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] != nil,
                        "This isolated installed witness requires smoke launch")
            _ = try unwrap(NSScreen.main, "An AppKit display is required")
            let owned = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-CaptureChain-" + UUID().uuidString)
            root = owned
            report["canonicalPrivateTemporaryRoot"] = true
            NSApp.appearance = NSAppearance(named: .aqua)
            let document = NumberedDocument(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
            document.appearance = NSAppearance(named: .aqua)
            let reference = try nativeImage(view: document)
            let sourceURL = directory.appendingPathComponent("chain-source-numbered.png")
            try writePNG(reference, to: sourceURL)
            // Decode the evidence source too, so each recipient is compared with
            // independently decoded published source pixels, not a retained view.
            let expected = try decode(sourceURL)
            report["sourceReference"] = try imageFacts(expected)
            let successProbes = LifetimeProbes()
            let success = await runCase(retry: true, sourceURL: sourceURL, expected: expected,
                                        root: owned, directory: directory, probes: successProbes, execution: execution)
            report["saveCopyRetryPin"] = success
            execution.apply(to: &report)
            safeToRemove = success["cleanupSafe"] as? Bool == true
            try await until("Successful chain owners did not release", seconds: 5) { successProbes.allReleased }
            report["successOwnershipReleased"] = successProbes.facts
            try write(report, directory: directory)
            if safeToRemove {
                let closeProbes = LifetimeProbes()
                let cancelled = await runCase(retry: false, sourceURL: sourceURL, expected: expected,
                                              root: owned, directory: directory, probes: closeProbes, execution: execution)
                report["closeAfterFailure"] = cancelled
                safeToRemove = cancelled["cleanupSafe"] as? Bool == true
                try await until("Closed failed-chain owners did not release", seconds: 5) { closeProbes.allReleased }
                report["closeOwnershipReleased"] = closeProbes.facts
                report["ownershipReleased"] = successProbes.allReleased && closeProbes.allReleased
                report["status"] = success["status"] as? String == "passed"
                    && cancelled["status"] as? String == "passed" && safeToRemove ? "passed" : "failed"
            } else { report["status"] = "failed" }
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            // Never remove files while an unconfirmed owned worker may use them.
            safeToRemove = false
        }
        if let root, safeToRemove {
            do {
                try files.removeItem(at: root)
                report["privateTemporaryRootRemoved"] = !files.fileExists(atPath: root.path)
            } catch { report["status"] = "failed"; report["cleanupError"] = error.localizedDescription }
        } else if root != nil {
            report["privateTemporaryRootRemoved"] = false
            report["cleanupError"] = "Retained synthetic files because bounded owner drainage was not confirmed"
        }
        report["cleanupSafe"] = safeToRemove && (report["privateTemporaryRootRemoved"] as? Bool == true)
        execution.apply(to: &report)
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        if report["cleanupSafe"] as? Bool != true { report["status"] = "failed" }
        try write(report, directory: directory)
        try require(report["status"] as? String == "passed", "Native chain witness failed; see capture-chain-demo.json")
        return report
    }

    private static func runCase(retry: Bool, sourceURL: URL, expected: CGImage, root: URL,
                                directory: URL, probes: LifetimeProbes, execution: ExecutionEvidence) async -> [String: Any] {
        let name = retry ? "retry" : "close", suite = "PicShot-CaptureChain-" + UUID().uuidString
        let board = NSPasteboard(name: .init("PicShot-CaptureChain-" + UUID().uuidString))
        let trace = Trace()
        var report: [String: Any] = ["status": "running", "case": name,
            "definitionOutputs": ["quickSavePNG", "copy", "pin"],
            "actionRoute": "PortableSettingsUIPreviewFixture.click: owned NSButton.mouseDown with queued mouseUp; NSTableView: owned-nextEvent-sendEvent",
            "copyRejectionInjectedAtCheckedWriter": true]
        var defaults: UserDefaults?
        var app: AppDelegate?
        var manager: CaptureChainController?
        var presenter: SaveWorkflowPresenter?
        var delivery: SaveWorkflowDelivery?
        var coordinator: PinSessionCoordinator?
        var runner: CaptureChainRunner?
        do {
            let caseRoot = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: false)
            let savedRoot = caseRoot.appendingPathComponent("saved", isDirectory: true)
            try FileManager.default.createDirectory(at: savedRoot, withIntermediateDirectories: false)
            let approved = try SaveWorkflowUIPreviewFixture.canonicalExistingDirectory(savedRoot)
            let isolated = try unwrap(UserDefaults(suiteName: suite), "Isolated defaults unavailable")
            defaults = isolated
            let longFilename = "owned-chain-" + String(repeating: "numbered-output-", count: 5) + "截图链-{counter}"
            try SaveWorkflowSettings(baseURL: approved, filenameTemplate: longFilename).save(to: isolated)
            let output = SaveWorkflowPresenter(defaults: isolated)
            presenter = output; probes.presenter = output
            output.onPresent = { job in trace.saveAdmissions += 1; probes.saveJob = job }
            let save = SaveWorkflowDelivery(presenter: output)
            delivery = save; probes.delivery = save
            let pinStore = try PinSessionStore(directory: caseRoot.appendingPathComponent("pins", isDirectory: true))
            let pins = PinSessionCoordinator(store: pinStore, presentWindows: true,
                desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
                ocrPreferences: PinOCRPreferences(defaults: nil))
            coordinator = pins; probes.coordinator = pins
            let store = try CaptureChainStore(directory: caseRoot.appendingPathComponent("chains", isDirectory: true))
            let definition = try CaptureChainDefinition(name: "编号截图 · 保存、复制、贴图", source: .region,
                                                        outputs: [.quickSavePNG, .copy, .pin])
            try store.add(definition); try store.select(id: definition.id)
            let catalogURL = store.directory.appendingPathComponent(CaptureChainStore.manifestFilename)
            let before = try Data(contentsOf: catalogURL)
            report["catalogBeforeSHA256"] = hash(before)
            try before.write(to: directory.appendingPathComponent(retry ? "chain-catalog.json" : "chain-close-catalog.json"), options: .atomic)
            let history = HistoryStore(directory: caseRoot.appendingPathComponent("history", isDirectory: true),
                policy: RetentionPolicy(maxItems: 2, maxBytes: 8 * 1_024 * 1_024, maxDays: 1))
            let owner = AppDelegate(history: history, isolatedDefaults: isolated, chainStore: store,
                chainDependencies: { requested in
                    try require(requested == definition, "App did not resolve the saved definition")
                    return .init(capture: {
                        trace.captures += 1
                        trace.managerHiddenDuringCapture = probes.manager?.window?.isVisible == false
                        trace.historyHiddenDuringCapture = probes.app?.mainWindow?.isVisible == false
                        let image = try decode(sourceURL)
                        probes.image = image
                        return try ChainCapture(image: image, capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
                    }, savePNG: { image in
                        trace.saves += 1; trace.sameImageAtEveryOutput = trace.sameImageAtEveryOutput && probes.image === image
                        let outcome = await save.save(image: image, parent: probes.manager?.window)
                        if case .committed = outcome { execution.saveCommitted = true }
                        return outcome
                    }, copy: { image in
                        trace.copies += 1; trace.sameImageAtEveryOutput = trace.sameImageAtEveryOutput && probes.image === image
                        if trace.copies == 1 {
                            try LiveScrollClipboard.copy(image, pasteboard: board, writer: { _, _ in false })
                        } else { try LiveScrollClipboard.copy(image, pasteboard: board) }
                    }, pin: { image in
                        trace.pins += 1; trace.sameImageAtEveryOutput = trace.sameImageAtEveryOutput && probes.image === image
                        let id = try pins.add(originalImage: image, currentImage: image, title: "编号截图链输出")
                        execution.pinCommitted = true
                        probes.pinController = pins.liveControllers[id]
                        return id
                    }, cancelSave: { save.cancel() })
                })
            app = owner; probes.app = owner
            execution.appInitialized = true
            owner.setupWindow()
            // Install only the existing owned-window retirement callback. Never
            // call applicationDidFinishLaunching or read launch preferences.
            NotificationCenter.default.addObserver(owner, selector: #selector(AppDelegate.windowClosed(_:)),
                name: NSWindow.willCloseNotification, object: nil)
            owner.manageCaptureChains()
            let controller = try unwrap(owner.captureChainManagerForVerification, "Production chain manager missing")
            manager = controller; probes.manager = controller
            let window = try unwrap(controller.window, "Manager window missing")
            window.makeKeyAndOrderFront(nil)
            let table: NSTableView = try control("capture-chain-list", in: window)
            report["rowSelection"] = try PortableSettingsUIPreviewFixture.clickRow(0, in: table,
                                                                                  failureEvidenceDirectory: directory)
            if retry { report["managerArtifacts"] = try captureOwnedEvidence(window: window, phase: "chain-manager", evidenceDirectory: directory) }
            let run: NSButton = try control("capture-chain-run", in: window)
            report["runControlIdentifier"] = run.identifier?.rawValue ?? ""
            try PortableSettingsUIPreviewFixture.click(run)
            try await until("Save then rejected Copy did not reach a retryable failure", seconds: 20) {
                owner.activeCaptureChain?.status.canRetry == true
            }
            runner = try unwrap(owner.activeCaptureChain, "Failed run owner missing")
            probes.runner = runner
            let failed = try unwrap(runner?.snapshot, "Failed snapshot missing")
            report["failureReceiptOutputs"] = failed.receipts.map { $0.output.rawValue }
            report["failedRetainedBytes"] = failed.retainedBytes
            report["failureAttempts"] = ["capture": trace.captures, "save": trace.saves,
                "saveAdmissions": trace.saveAdmissions, "copy": trace.copies, "pin": trace.pins]
            try require(failed.status.canRetry && failed.receipts.map(\.output) == [.quickSavePNG]
                && failed.retainedBytes > 0 && runner?.capture?.image === probes.image,
                "Copy rejection did not retain the same image and committed Save receipt")
            try require(trace.captures == 1 && trace.saves == 1 && trace.saveAdmissions == 1
                && trace.copies == 1 && trace.pins == 0, "Output order or first failure counts are wrong")
            let savedReceipt = try unwrap(failed.receipts.first, "Saved receipt missing")
            guard case .saved(let savedURL, let savedByteCount) = savedReceipt.value else {
                throw failure("First receipt is not a saved PNG")
            }
            let savedBytes = try Data(contentsOf: savedURL)
            report["savedPNGComparison"] = try comparison(decode(savedURL), expected)
            report["savedPNGFileSHA256"] = hash(savedBytes)
            report["savedPNGByteCount"] = savedBytes.count
            report["savedPath"] = savedURL.path
            report["saveReceiptByteCountMatchesFile"] = savedByteCount == savedBytes.count
            try savedBytes.write(to: directory.appendingPathComponent(retry ? "chain-saved.png" : "chain-close-saved.png"), options: .atomic)
            try require(savedURL.deletingLastPathComponent() == approved && savedBytes.count == savedByteCount,
                        "Save receipt escaped the owned folder or has the wrong size")
            try require((report["savedPNGComparison"] as? [String: Any])?["passed"] as? Bool == true,
                        "Published Save pixels differ from source")
            try require(presenter?.activeJobCount == 0 && presenter?.controllers.isEmpty == true
                && presenter?.retainedInputBytes == 0, "Committed Save did not release its owned job")
            report["saveDrainedBeforeRetryOrClose"] = true
            // Preserve the actual published output before a later native layout
            // assertion can reject the status surface and enter cleanup.
            report["failureArtifacts"] = try captureOwnedEvidence(window: window,
                phase: retry ? "chain-copy-failure" : "chain-close-failure", evidenceDirectory: directory)
            if retry {
                let retryButton: NSButton = try control("capture-chain-retry", in: window)
                report["retryControlIdentifier"] = retryButton.identifier?.rawValue ?? ""
                try PortableSettingsUIPreviewFixture.click(retryButton)
                try await until("Native Retry did not finish the saved chain", seconds: 15) {
                    controller.displayedSnapshot?.status == .completed && owner.activeCaptureChain == nil
                }
                let completed = try unwrap(controller.displayedSnapshot, "Completed receipt summary missing")
                try require(completed.receipts.map(\.output) == definition.outputs
                    && completed.receipts.first == savedReceipt && completed.retainedBytes == 0,
                    "Retry lost or repeated the committed receipt")
                let copied = try unwrap(board.data(forType: .png), "Private pasteboard has no checked PNG")
                let copiedURL = directory.appendingPathComponent("chain-copied.png")
                try copied.write(to: copiedURL, options: .atomic)
                report["copiedPNGComparison"] = try comparison(decode(copiedURL), expected)
                report["copiedPNGFileSHA256"] = hash(copied)
                guard let last = completed.receipts.last, case .pinned(let pinID) = last.value else {
                    throw failure("Completed persistent Pin receipt missing")
                }
                let entry = try unwrap(pinStore.entry(id: pinID), "Persistent Pin entry missing")
                let pinURL = pinStore.directory.appendingPathComponent(entry.current.filename)
                let pinBytes = try Data(contentsOf: pinURL)
                try pinBytes.write(to: directory.appendingPathComponent("chain-pin.png"), options: .atomic)
                report["publishedPinComparison"] = try comparison(decode(pinURL), expected)
                let reloaded = try PinSessionStore(directory: pinStore.directory)
                let reloadedImage = try unwrap(reloaded.image(id: pinID), "Reloaded Pin missing")
                report["reloadedPinComparison"] = try comparison(reloadedImage, expected)
                let reloadedURL = directory.appendingPathComponent("chain-pin-reloaded.png")
                try writePNG(reloadedImage, to: reloadedURL)
                report["reloadedPinPNGFileSHA256"] = hash(try Data(contentsOf: reloadedURL))
                report["pinID"] = pinID.uuidString
                report["pinPNGFileSHA256"] = hash(pinBytes)
                report["pinOriginalAndCurrentShareOneAsset"] = entry.original.filename == entry.current.filename
                report["visibleNativePinCount"] = pins.livePinCount
                report["receipts"] = completed.receipts.map(receiptFacts)
                report["resultArtifacts"] = try captureOwnedEvidence(window: window, phase: "chain-result", evidenceDirectory: directory)
                try require(["copiedPNGComparison", "publishedPinComparison", "reloadedPinComparison"].allSatisfy {
                    (report[$0] as? [String: Any])?["passed"] as? Bool == true
                }, "One output differs from independently decoded source pixels")
                try require(trace.captures == 1 && trace.saves == 1 && trace.saveAdmissions == 1
                    && trace.copies == 2 && trace.pins == 1 && pinStore.entries.count == 1
                    && reloaded.entries.count == 1 && pins.livePinCount == 1
                    && pins.liveControllers[pinID]?.window?.isVisible == true,
                    "Retry repeated a successful output or failed persistent visible Pin delivery")
                try require(entry.original.filename == entry.current.filename, "Unmodified Pin duplicated its raster asset")
            }
            let close: NSButton = try control("capture-chain-close", in: window)
            report["closeControlIdentifier"] = close.identifier?.rawValue ?? ""
            window.makeKeyAndOrderFront(nil)
            try PortableSettingsUIPreviewFixture.click(close)
            try await until("Native Close did not retire its owned chain", seconds: 5) {
                owner.activeCaptureChain == nil && window.isVisible == false
            }
            if !retry {
                try require(runner?.status == .cancelled && runner?.retainedBytes == 0
                    && runner?.capture == nil && trace.pins == 0 && trace.copies == 1,
                    "Close did not cancel the retained failed image before later outputs")
                report["receipts"] = runner?.receipts.map(receiptFacts) ?? []
                report["committedFilePreservedAfterClose"] = try Data(contentsOf: savedURL) == savedBytes
                try require(report["committedFilePreservedAfterClose"] as? Bool == true, "Close changed the completed saved file")
            }
            let savedFiles = try FileManager.default.contentsOfDirectory(atPath: approved.path)
            report["savedFileCount"] = savedFiles.count
            report["savedPNGUnchangedAfterRetryOrClose"] = try Data(contentsOf: savedURL) == savedBytes
            try require(savedFiles == [savedURL.lastPathComponent]
                && (report["savedPNGUnchangedAfterRetryOrClose"] as? Bool == true),
                "Retry or Close duplicated or changed the completed Save")
            report["finalRetainedBytes"] = runner?.retainedBytes ?? -1
            report["terminalStatus"] = retry ? "completed" : "cancelled"
            let after = try Data(contentsOf: catalogURL)
            report["catalogAfterSHA256"] = hash(after)
            let decoded = try JSONDecoder().decode(CaptureChainIndex.self, from: after)
            let catalogFiles = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
            report["catalogDefinitionsOnly"] = before == after && decoded.definitions == [definition]
                && decoded.selectedID == definition.id && catalogFiles == [CaptureChainStore.manifestFilename]
            try after.write(to: directory.appendingPathComponent(retry ? "chain-catalog.json" : "chain-close-catalog.json"), options: .atomic)
            try require(report["catalogDefinitionsOnly"] as? Bool == true, "Runtime data entered or mutated the saved definition catalog")
            try require(history.records.isEmpty && !owner.controllers.contains(where: { $0 is ImageEditorController })
                && owner.pins.isEmpty && owner.pinSession == nil, "Chain opened unrelated editor/history/transient pin output")
            try require(trace.managerHiddenDuringCapture && trace.historyHiddenDuringCapture && trace.sameImageAtEveryOutput,
                        "Capture visibility or one-image output identity changed")
            report["managerHiddenDuringCapture"] = trace.managerHiddenDuringCapture
            report["historyHiddenDuringCapture"] = trace.historyHiddenDuringCapture
            report["sameOwnedImageAtEveryOutput"] = trace.sameImageAtEveryOutput
            report["noEditorHistoryOrTransientPinOutput"] = true
            report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        app?.activeCaptureChain?.cancel(); delivery?.cancel(); presenter?.cancelAll()
        do {
            try await until("Chain cleanup did not drain", seconds: 5) {
                app?.activeCaptureChain == nil && (presenter?.activeJobCount ?? 0) == 0
                    && presenter?.controllers.isEmpty != false && (presenter?.retainedInputBytes ?? 0) == 0
            }
            try coordinator?.prepareForTermination()
        } catch { report["status"] = "failed"; report["cleanupError"] = error.localizedDescription }
        let drained = app?.activeCaptureChain == nil && (presenter?.activeJobCount ?? 0) == 0
            && presenter?.controllers.isEmpty != false && (presenter?.retainedInputBytes ?? 0) == 0
            && (coordinator?.livePinCount ?? 0) == 0
        presenter?.onPresent = nil
        manager?.close()
        if let app {
            NotificationCenter.default.removeObserver(app, name: NSWindow.willCloseNotification, object: nil)
            app.mainWindow?.contentView = nil; app.mainWindow?.close(); app.controllers.removeAll()
        }
        runner = nil; manager = nil; app = nil; delivery = nil; presenter = nil; coordinator = nil
        board.releaseGlobally()
        if drained { defaults?.removePersistentDomain(forName: suite) }
        report["attempts"] = ["capture": trace.captures, "save": trace.saves,
                              "saveAdmissions": trace.saveAdmissions, "copy": trace.copies, "pin": trace.pins]
        report["cleanupSafe"] = drained
        report["saveJobsDrained"] = drained
        report["privatePasteboardReleased"] = true
        report["isolatedDefaultsRemoved"] = drained
        if !drained { report["status"] = "failed" }
        return report
    }

    /// Shared by native UI tests. Both appearances, complete raw control frames,
    /// text metrics and image hashes are persisted before any layout rejection.
    static func captureOwnedEvidence(window: NSWindow, phase: String,
                                     evidenceDirectory directory: URL) throws -> [[String: Any]] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = window.appearance
        defer { window.appearance = previous }
        var artifacts: [[String: Any]] = []
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let root = try unwrap(window.contentView, "Owned window has no content")
            descendants(root).forEach { $0.needsDisplay = true }
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let image = try nativeImage(view: root, window: window)
            let filename = phase + "-" + mode + ".png"
            try writePNG(image, to: directory.appendingPathComponent(filename))
            let layout = layoutObservation(window: window, phase: phase)
            var facts = try imageFacts(image)
            facts["filename"] = filename; facts["appearance"] = mode; facts["layout"] = layout
            facts["rendering"] = "Actual native owned content over resolved effective-appearance window background"
            try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(phase + "-" + mode + "-layout.json"), options: .atomic)
            artifacts.append(facts)
        }
        try require(artifacts.allSatisfy { ($0["layout"] as? [String: Any])?["passed"] as? Bool == true },
                    "Native layout failed for " + phase + "; preserved light/dark PNG and raw layout evidence")
        try require(artifacts.first?["canonicalRGBAPixelSHA256"] as? String != artifacts.last?["canonicalRGBAPixelSHA256"] as? String,
                    "Light and dark native images are identical for " + phase)
        return artifacts
    }

    @discardableResult static func assertLayout(window: NSWindow, phase: String) throws -> [String: Any] {
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let value = layoutObservation(window: window, phase: phase)
        try require(value["passed"] as? Bool == true,
                    "Native layout " + phase + ": " + ((value["violations"] as? [String]) ?? []).joined(separator: "; "))
        return value
    }

    private static func layoutObservation(window: NSWindow, phase: String) -> [String: Any] {
        guard let root = window.contentView else { return ["passed": false, "violations": ["Missing root"]] }
        var rows: [[String: Any]] = [], violations: [String] = []
        let visibleScreen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if visibleScreen?.insetBy(dx: -0.5, dy: -0.5).contains(window.frame) != true {
            violations.append("Full owned window outside usable display")
        }
        let views = descendants(root)
        let controlIDs = Dictionary(uniqueKeysWithValues: views.enumerated().compactMap { entry -> (ObjectIdentifier, String)? in
            let (index, view) = entry
            guard let control = view as? NSControl else { return nil }
            return (ObjectIdentifier(control), control.identifier?.rawValue ?? "native-control-\(index)")
        })
        var viewPaths: [ObjectIdentifier: [Int]] = [:]
        func recordViewPaths(_ view: NSView, path: [Int]) {
            viewPaths[ObjectIdentifier(view)] = path
            for (index, child) in view.subviews.enumerated() { recordViewPaths(child, path: path + [index]) }
        }
        recordViewPaths(root, path: [])
        var leaves: [(NSView, String, CGRect)] = []
        for (index, view) in views.enumerated() where view is NSControl {
            guard let control = view as? NSControl else { continue }
            let id = control.identifier?.rawValue ?? "native-control-\(index)"
            let frame = control.convert(control.bounds, to: root)
            let alignment = control.convert(control.alignmentRect(forFrame: control.bounds), to: root)
            var row: [String: Any] = ["id": id, "class": String(describing: type(of: control)),
                "fullFrame": rect(frame), "fullScreenFrame": rect(window.convertToScreen(control.convert(control.bounds, to: nil))),
                "hidden": control.isHiddenOrHasHiddenAncestor, "enabled": control.isEnabled,
                "visibleRect": rect(control.visibleRect), "toolTip": control.toolTip ?? "",
                "accessibilityLabel": control.accessibilityLabel() ?? "",
                "accessibilityValue": control.accessibilityValue() as? String ?? ""]
            let button = control as? NSButton, field = control as? NSTextField
            row["controlKind"] = button != nil ? "button" : field != nil ? "textField"
                : control is NSTableView ? "tableView" : control is NSScroller ? "scroller" : "other"
            row["identifierIsExplicit"] = control.identifier != nil
            row["viewPath"] = viewPaths[ObjectIdentifier(control)] ?? []
            row["ownerWindowNumber"] = control.window?.windowNumber ?? -1
            row["descendantOfOwnedContent"] = control.isDescendant(of: root) && control.window === window
            if id == "capture-chain-name" || id == "capture-chain-source" { row["alignmentFrame"] = rect(alignment) }
            let text = button?.title ?? field?.stringValue ?? ""
            row["text"] = text
            if let field {
                row["textWraps"] = field.cell?.wraps ?? false
                row["textEditable"] = field.isEditable
                row["textSelectable"] = field.isSelectable
                row["textScrollable"] = field.cell?.isScrollable ?? false
                row["lineBreakMode"] = field.lineBreakMode.rawValue
                row["maximumNumberOfLines"] = field.maximumNumberOfLines
            }
            let required = control.cell?.cellSize ?? .zero
            let wrapped = control.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: control.bounds.width, height: 10_000)) ?? .zero
            row["untruncatedCellSize"] = [required.width, required.height]
            row["requiredTextSizeAtActualWidth"] = [wrapped.width, wrapped.height]
            var inViewport = true
            var controlAncestors: [String] = []
            var nearestControl: NSControl?
            var ancestor = control.superview
            while let value = ancestor {
                if let parent = value as? NSControl {
                    if nearestControl == nil { nearestControl = parent }
                    controlAncestors.append(controlIDs[ObjectIdentifier(parent)] ?? "unreported-control")
                }
                if let clip = value as? NSClipView,
                   !clip.bounds.insetBy(dx: -0.5, dy: -0.5).contains(control.convert(control.bounds, to: clip)) { inViewport = false }
                ancestor = value.superview
            }
            row["parentControlID"] = controlAncestors.first.map { $0 as Any } ?? NSNull()
            row["controlAncestorIDs"] = controlAncestors
            row["insideScrollableViewport"] = inViewport
            if !control.isHiddenOrHasHiddenAncestor && inViewport && (button != nil || field != nil) {
                let contained = frame.width > 0 && frame.height > 0 && root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
                row["fullFrameContained"] = contained
                if !contained { violations.append(id + " full frame clipped") }
                if let button {
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    let hit = root.hitTest(root.convert(center, to: root.superview))
                    let hitMatches = hit === button || hit?.isDescendant(of: button) == true
                    row["hitTest"] = hitMatches
                    let fits = frame.width + 0.5 >= required.width && frame.height + 0.5 >= required.height
                    row["titleFits"] = fits
                    var moreIconAlternative = false
                    if id == "scroll.live.more", let popup = button as? LiveScrollMoreButton,
                       let cell = popup.cell as? NSPopUpButtonCell {
                        // AppKit documents that a pull-down displays its FIRST menu
                        // item's image; selectedItem is the last user selection.
                        // Keep that selection and the button image getter diagnostic,
                        // and validate the first item's image against the public rect.
                        // https://developer.apple.com/documentation/appkit/nspopupbutton
                        let anchor = popup.menu?.items.first
                        let imageSize = popup.image?.size ?? .zero
                        let anchorImageSize = anchor?.image?.size ?? .zero
                        let imageRect = cell.imageRect(forBounds: popup.bounds)
                        let finite = [anchorImageSize.width, anchorImageSize.height, imageRect.minX, imageRect.minY,
                                      imageRect.width, imageRect.height].allSatisfy { $0.isFinite }
                        row["moreIconPullsDown"] = popup.pullsDown
                        row["moreIconUsesItemFromMenu"] = cell.usesItemFromMenu
                        row["moreIconImagePosition"] = popup.imagePosition == .imageOnly ? "imageOnly" : "other"
                        row["moreIconArrowPosition"] = cell.arrowPosition == .noArrow ? "noArrow" : "other"
                        row["moreIconImageScaling"] = popup.imageScaling == .scaleNone ? "scaleNone" : "other"
                        row["moreIconAnchorPresent"] = anchor != nil
                        row["moreIconAnchorTitle"] = anchor?.title ?? ""
                        row["moreIconSelectedItemIsFirstItem"] = anchor != nil && popup.selectedItem === anchor
                        row["moreIconAnchorImagePresent"] = anchor?.image != nil
                        row["moreIconAnchorImageSize"] = [anchorImageSize.width, anchorImageSize.height]
                        row["moreIconImagePresent"] = popup.image != nil
                        row["moreIconNativeBounds"] = rect(popup.bounds)
                        row["moreIconImageSize"] = [imageSize.width, imageSize.height]
                        row["moreIconImageRect"] = rect(imageRect)
                        moreIconAlternative = nearestControl == nil && popup.isEnabled && popup.pullsDown && cell.usesItemFromMenu
                            && popup.imagePosition == .imageOnly && cell.arrowPosition == .noArrow
                            && popup.imageScaling == .scaleNone && popup.title.isEmpty
                            && anchor != nil && anchor?.title == ""
                            && anchor?.image != nil && finite && anchorImageSize.width > 0 && anchorImageSize.height > 0
                            && imageRect.width > 0 && imageRect.height > 0
                            && popup.bounds.width > 0 && popup.bounds.height > 0
                            && popup.bounds.insetBy(dx: -0.5, dy: -0.5).contains(imageRect)
                            && imageRect.width + 0.5 >= anchorImageSize.width && imageRect.height + 0.5 >= anchorImageSize.height
                            && popup.accessibilityLabel() == "更多滚动截图选项"
                            && popup.toolTip == "移动选区 · 方向 · 导入 · 帮助"
                        row["moreIconFits"] = moreIconAlternative
                    }
                    var longSourceAlternative = false
                    if id == "capture-chain-source", let popup = button as? NSPopUpButton {
                        let mode = popup.cell?.lineBreakMode ?? .byClipping
                        let truncates = mode == .byTruncatingHead || mode == .byTruncatingTail || mode == .byTruncatingMiddle
                        row["selectedItemTitle"] = popup.selectedItem?.title ?? ""
                        row["titleLineBreakMode"] = mode.rawValue
                        longSourceAlternative = alignment.width >= 320 && frame.height + 0.5 >= required.height
                            && truncates && popup.selectedItem?.title == text && popup.toolTip == text
                            && popup.accessibilityValue() as? String == text
                        row["sourcePopupLongTitleAlternative"] = longSourceAlternative
                        if alignment.width < 320 { violations.append(id + " usable alignment width is below 320") }
                    }
                    if (!fits && !longSourceAlternative && !moreIconAlternative) || !hitMatches {
                        violations.append(id + " title or native hit target does not fit")
                    }
                }
                if let field, !text.isEmpty {
                    let isTruncating = field.lineBreakMode == .byTruncatingTail || field.lineBreakMode == .byTruncatingMiddle
                        || field.lineBreakMode == .byTruncatingHead
                    let fullAlternative = field.toolTip == text
                        && (field.accessibilityLabel() == text || field.accessibilityValue() as? String == text)
                    let horizontalFit = field.cell?.wraps == true || required.width <= frame.width + 0.5
                    let verticalFit = wrapped.height <= frame.height + 0.5
                    let fits = verticalFit && horizontalFit
                    row["textFits"] = fits; row["intentionalTruncation"] = isTruncating && !fits
                    row["fullTextTooltipAndAccessibility"] = fullAlternative
                    row["fontPointSize"] = field.font?.pointSize ?? 0
                    var longNameAlternative = false
                    if id == "capture-chain-name" {
                        longNameAlternative = alignment.width >= 320 && field.isEditable && field.isSelectable
                            && field.cell?.isScrollable == true && verticalFit && field.toolTip == text
                            && field.accessibilityValue() as? String == text
                        row["editableNameLongTextAlternative"] = longNameAlternative
                        if alignment.width < 320 || !field.isEditable || !field.isSelectable || field.cell?.isScrollable != true {
                            violations.append(id + " usable editable/scrollable name input missing")
                        }
                    }
                    var inheritedSourceAlternative = false
                    if let popup = nearestControl as? NSPopUpButton,
                       popup.identifier?.rawValue == "capture-chain-source" {
                        let ownerFrame = popup.convert(popup.bounds, to: root)
                        let ownerAlignment = popup.convert(popup.alignmentRect(forFrame: popup.bounds), to: root)
                        let ownerRequired = popup.cell?.cellSize ?? .zero
                        let mode = popup.cell?.lineBreakMode ?? .byClipping
                        let truncates = mode == .byTruncatingHead || mode == .byTruncatingTail || mode == .byTruncatingMiddle
                        inheritedSourceAlternative = verticalFit && ownerAlignment.width >= 320
                            && ownerFrame.height + 0.5 >= ownerRequired.height && truncates
                            && popup.title == text && popup.selectedItem?.title == text && popup.toolTip == text
                            && popup.accessibilityValue() as? String == text
                    }
                    row["inheritedSourceTitleAlternative"] = inheritedSourceAlternative
                    if nearestControl is NSButton && !fits && !inheritedSourceAlternative {
                        violations.append(id + " native button title descendant is clipped")
                    }
                    if (field.font?.pointSize ?? 0) < 11 || (!fits && !longNameAlternative && !inheritedSourceAlternative
                        && !(id != "capture-chain-name" && isTruncating && fullAlternative)) {
                        violations.append(id + " visible text does not fit or lacks full accessible alternative")
                    }
                }
                leaves.append((control, id, frame))
            }
            rows.append(row)
        }
        for index in leaves.indices {
            for previous in 0..<index {
                let lhs = leaves[index], rhs = leaves[previous]
                if lhs.0.isDescendant(of: rhs.0) || rhs.0.isDescendant(of: lhs.0) { continue }
                let overlap = lhs.2.intersection(rhs.2)
                if !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5 {
                    violations.append(lhs.1 + " overlaps " + rhs.1)
                }
            }
        }
        return ["passed": violations.isEmpty && !rows.isEmpty, "phase": phase,
            "windowTitle": window.title, "windowFrame": rect(window.frame), "contentBounds": rect(root.bounds),
            "visibleScreenFrame": visibleScreen.map(rect) ?? [:],
            "windowVisible": window.isVisible, "windowNumber": window.windowNumber,
            "nativeControlCount": rows.count, "controls": rows, "violations": violations,
            "fullNativeFramesMeasured": true, "alignmentRectanglesSubstituted": false,
            "fullVisibleFramesChecked": violations.isEmpty,
            "controlsDoNotOverlap": !violations.contains(where: { $0.contains(" overlaps ") })]
    }

    /// Claims are published only after the actual owner or durable output exists.
    /// An interrupted early fixture keeps the initial report's three flags false.
    private final class ExecutionEvidence {
        var appInitialized = false, saveCommitted = false, pinCommitted = false
        func apply(to report: inout [String: Any]) {
            report["productAppDelegateExercised"] = appInitialized
            report["productSaveWorkflowDeliveryExercised"] = saveCommitted
            report["productPersistentPinExercised"] = pinCommitted
        }
    }
    private final class Trace {
        var captures = 0, saves = 0, saveAdmissions = 0, copies = 0, pins = 0
        var managerHiddenDuringCapture = false, historyHiddenDuringCapture = false
        var sameImageAtEveryOutput = true
    }
    private final class LifetimeProbes {
        weak var app: AppDelegate?
        weak var manager: CaptureChainController?
        weak var runner: CaptureChainRunner?
        weak var image: CGImage?
        weak var saveJob: SaveWorkflowController?
        weak var pinController: PinController?
        weak var presenter: SaveWorkflowPresenter?
        weak var delivery: SaveWorkflowDelivery?
        weak var coordinator: PinSessionCoordinator?
        var facts: [String: Bool] { ["app": app == nil, "manager": manager == nil, "runner": runner == nil,
            "selectedImage": image == nil, "saveJob": saveJob == nil, "pinController": pinController == nil,
            "presenter": presenter == nil, "delivery": delivery == nil, "pinCoordinator": coordinator == nil] }
        var allReleased: Bool { facts.values.allSatisfy { $0 } }
    }

    private final class NumberedDocument: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); bounds.fill()
            let titles = ["One selected image", "Save once", "Reject the first Copy", "Retry only unfinished actions",
                          "Copy the same pixels", "Pin a durable image", "Keep the saved definition", "Release the run owner"]
            for (index, title) in titles.enumerated() {
                let y = index * 40
                NSColor(calibratedWhite: index % 2 == 0 ? 0.97 : 0.91, alpha: 1).setFill()
                CGRect(x: 0, y: y, width: 480, height: 40).fill()
                NSColor(calibratedHue: CGFloat(index) / 8, saturation: 0.7, brightness: 0.85, alpha: 1).setFill()
                CGRect(x: 456, y: y + 5, width: 16, height: 30).fill()
                (String(format: "%02d", index + 1) as NSString).draw(at: CGPoint(x: 12, y: y + 10),
                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold), .foregroundColor: NSColor.black])
                (title as NSString).draw(at: CGPoint(x: 51, y: y + 11),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
            }
        }
    }

    private static func control<T: NSView>(_ id: String, in window: NSWindow) throws -> T {
        let root = try unwrap(window.contentView, "Control root missing")
        let matching = descendants(root).filter { $0.identifier?.rawValue == id }
        try require(matching.count == 1, "Expected exactly one native control: " + id)
        return try unwrap(matching.first as? T, "Wrong native control class: " + id)
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func rect(_ frame: CGRect) -> [String: CGFloat] {
        ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    private static func receiptFacts(_ receipt: CaptureChainReceipt) -> [String: Any] {
        var result: [String: Any] = ["output": receipt.output.rawValue]
        switch receipt.value {
        case .saved(let url, let count): result["savedURL"] = url.path; result["byteCount"] = count
        case .copied: result["checkedPrivatePasteboard"] = true
        case .pinned(let id): result["pinID"] = id.uuidString
        }
        return result
    }
    private static func nativeImage(view: NSView, window: NSWindow? = nil) throws -> CGImage {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try require(width > 0 && height > 0 && width <= 4_000_000 / height, "Owned native snapshot exceeds bound")
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), "Native bitmap unavailable")
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        bitmap.size = view.bounds.size
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Native composition unavailable")
        (window?.effectiveAppearance ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
            context.setFillColor((window?.backgroundColor ?? NSColor.windowBackgroundColor).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let cached = bitmap.cgImage { context.draw(cached, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        return try unwrap(context.makeImage(), "Native image unavailable")
    }
    private static func imageFacts(_ image: CGImage) throws -> [String: Any] {
        ["width": image.width, "height": image.height,
         "canonicalRGBAPixelSHA256": hash(try SaveWorkflowUIPreviewFixture.pixels(image))]
    }
    private static func comparison(_ image: CGImage, _ reference: CGImage) throws -> [String: Any] {
        let actual = try SaveWorkflowUIPreviewFixture.pixels(image), expected = try SaveWorkflowUIPreviewFixture.pixels(reference)
        let dimensions = image.width == reference.width && image.height == reference.height
        return ["passed": dimensions && actual == expected, "dimensionsMatch": dimensions,
            "exactCanonicalRGBAEquality": dimensions && actual == expected,
            "width": image.width, "height": image.height, "expectedWidth": reference.width, "expectedHeight": reference.height,
            "outputPixelSHA256": hash(actual), "sourcePixelSHA256": hash(expected),
            "method": "Independent ImageIO PNG decode followed by full canonical sRGB RGBA equality"]
    }
    private static func decode(_ url: URL) throws -> CGImage {
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "PNG source unavailable")
        return try unwrap(CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), "PNG decode failed")
    }
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let writer = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil), "PNG destination unavailable")
        CGImageDestinationAddImage(writer, image, nil)
        try require(CGImageDestinationFinalize(writer), "PNG finalization failed")
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func until(_ message: String, seconds: TimeInterval, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try Task.checkCancellation()
            try require(ProcessInfo.processInfo.systemUptime < deadline, message)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("capture-chain-demo.json"), options: .atomic)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw failure(message) }; return value
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Capture chain demo: " + message) }
}
