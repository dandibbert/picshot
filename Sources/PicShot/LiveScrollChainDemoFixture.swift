import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// One bounded installed-app witness. Only acquisition is substituted; the live
/// owner, choice/Run/Cancel/Continue controls and durable output recipients are real.
@MainActor
enum LiveScrollChainDemoFixture {
    private static let width = 480
    private static let viewportHeight = 320
    private static let offsets = [0, 96, 192, 288, 384]

    static func verify(evidenceDirectory directory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let files = FileManager.default, started = ProcessInfo.processInfo.systemUptime
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        var report: [String: Any] = [
            "schemaVersion": 1, "status": "running", "installerAcceptance": false,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "source": "Fixture-owned native numbered scrolling document; deterministic viewport crops",
            "acquisition": "LiveScrollVerificationFrameSource; actual AppDelegate, live session, assembler and prepared chain runner",
            "realScreenCaptureClaimed": false, "screenCaptureAPICalled": false,
            "permissionRequested": false, "globalInputPosted": false, "networkUsed": false,
            "userHistoryReadOrWritten": false, "standardDefaultsReadOrWritten": false,
            "generalPasteboardReadOrWritten": false, "productAppDelegateExercised": false,
            "productSessionControllerExercised": false, "productSaveWorkflowDeliveryExercised": false,
            "productPersistentPinExercised": false, "productSessionClosed": false,
            "limitations": ["Owned acquisition does not prove ScreenCaptureKit or third-party scrolling",
                "The first checked private-pasteboard write is deliberately rejected",
                "Images show cached owned native content, not a desktop screenshot",
                "Weak-owner and spool checks are bounded observations, not an RSS or zero-leak claim"]]
        try write(report, directory: directory)
        var root: URL?
        var safe = false
        let probes = LifetimeProbes(), trace = Trace()
        do {
            try require(ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] != nil,
                        "This isolated installed witness requires smoke launch")
            let screen = try unwrap(NSScreen.main, "An AppKit display is required")
            let owned = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-LiveChain-" + UUID().uuidString)
            root = owned; report["canonicalPrivateTemporaryRoot"] = true
            let document = NumberedDocument(frame: CGRect(x: 0, y: 0, width: width, height: 704))
            document.appearance = NSAppearance(named: .aqua)
            let sourceURL = directory.appendingPathComponent("scroll-chain-owned-numbered.png")
            try writePNG(nativeImage(view: document), to: sourceURL)
            let reference = try decode(sourceURL)
            report["sourceReference"] = try imageFacts(reference)
            let result = await runCase(reference: reference, screen: screen, root: owned,
                                       directory: directory, probes: probes, trace: trace)
            report["saveFailCancelContinue"] = result
            safe = result["cleanupSafe"] as? Bool == true
            report["productSessionClosed"] = result["productSessionClosed"] as? Bool == true
            try write(report, directory: directory)
            try await until("Existing-image chain owners did not release", seconds: 5) { probes.allReleased }
            report["ownership"] = probes.facts
            report["ownershipReleased"] = probes.allReleased
            report["status"] = result["status"] as? String == "passed" && safe ? "passed" : "failed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            safe = false
        }
        if let root, safe {
            do {
                try files.removeItem(at: root)
                report["privateTemporaryRootRemoved"] = !files.fileExists(atPath: root.path)
            } catch { report["status"] = "failed"; report["cleanupError"] = error.localizedDescription }
        } else if root != nil {
            report["privateTemporaryRootRemoved"] = false
            report["cleanupError"] = "Retained owned synthetic files because drainage was not confirmed"
        }
        report["productAppDelegateExercised"] = trace.appInitialized
        report["productSessionControllerExercised"] = trace.sessionStarted
        report["productSaveWorkflowDeliveryExercised"] = trace.saveCommitted
        report["productPersistentPinExercised"] = trace.pinCommitted
        report["cleanupSafe"] = safe && (report["privateTemporaryRootRemoved"] as? Bool == true)
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        if report["cleanupSafe"] as? Bool != true { report["status"] = "failed" }
        try write(report, directory: directory)
        try require(report["status"] as? String == "passed", "Existing-image chain witness failed; see live-scroll-chain.json")
        return report
    }

    private static func runCase(reference: CGImage, screen: NSScreen, root: URL, directory: URL,
                                probes: LifetimeProbes, trace: Trace) async -> [String: Any] {
        let suite = "PicShot-LiveChain-" + UUID().uuidString
        let board = NSPasteboard(name: .init("PicShot-LiveChain-" + UUID().uuidString))
        var report: [String: Any] = ["status": "running", "viewportOffsets": offsets,
            "definitionOutputs": ["quickSavePNG", "copy", "pin"]]
        var defaults: UserDefaults?, app: AppDelegate?, session: LiveScrollSessionController?
        var manager: CaptureChainController?, presenter: SaveWorkflowPresenter?, delivery: SaveWorkflowDelivery?
        var coordinator: PinSessionCoordinator?
        let spool = root.appendingPathComponent("spool", isDirectory: true)
        do {
            let savedRoot = root.appendingPathComponent("saved", isDirectory: true)
            try FileManager.default.createDirectory(at: savedRoot, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false)
            let approved = try SaveWorkflowUIPreviewFixture.canonicalExistingDirectory(savedRoot)
            let isolated = try unwrap(UserDefaults(suiteName: suite), "Isolated defaults unavailable")
            defaults = isolated
            try SaveWorkflowSettings(baseURL: approved, filenameTemplate: "owned-live-chain-{counter}").save(to: isolated)
            let output = SaveWorkflowPresenter(defaults: isolated)
            presenter = output; probes.presenter = output
            output.onPresent = { job in trace.saveAdmissions += 1; probes.saveJob = job }
            let save = SaveWorkflowDelivery(presenter: output)
            delivery = save; probes.delivery = save
            let pinStore = try PinSessionStore(directory: root.appendingPathComponent("pins", isDirectory: true))
            let pins = PinSessionCoordinator(store: pinStore, presentWindows: true,
                desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
                ocrPreferences: PinOCRPreferences(defaults: nil))
            coordinator = pins; probes.coordinator = pins
            let store = try CaptureChainStore(directory: root.appendingPathComponent("chains", isDirectory: true))
            let definition = try CaptureChainDefinition(name: "编号长图 · 保存、复制、贴图", source: .region,
                                                        outputs: [.quickSavePNG, .copy, .pin])
            try store.add(definition); try store.select(id: definition.id)
            let catalogURL = store.directory.appendingPathComponent(CaptureChainStore.manifestFilename)
            let before = try Data(contentsOf: catalogURL)
            report["catalogBeforeSHA256"] = hash(before)
            try before.write(to: directory.appendingPathComponent("scroll-chain-catalog.json"), options: .atomic)
            let history = HistoryStore(directory: root.appendingPathComponent("history", isDirectory: true),
                policy: RetentionPolicy(maxItems: 2, maxBytes: 8 * 1_024 * 1_024, maxDays: 1))
            let owner = AppDelegate(history: history, isolatedDefaults: isolated, chainStore: store,
                chainDependencies: { requested in
                    try require(requested == definition, "App did not freeze the saved definition")
                    return .init(capture: {
                        trace.captures += 1
                        throw failure("Existing-image route attempted fresh capture")
                    }, savePNG: { image in
                        trace.saves += 1
                        if probes.image == nil { probes.image = image }
                        trace.sameImage = trace.sameImage && probes.image === image
                        let result = await save.save(image: image, parent: probes.manager?.window)
                        if case .committed = result { trace.saveCommitted = true }
                        return result
                    }, copy: { image in
                        trace.copies += 1; trace.sameImage = trace.sameImage && probes.image === image
                        if trace.copies == 1 {
                            try LiveScrollClipboard.copy(image, pasteboard: board, writer: { _, _ in false })
                        } else {
                            probes.continuedRunner = probes.app?.activeCaptureChain
                            trace.continuedRunID = probes.app?.activeCaptureChain?.id
                            trace.continuedRevisionID = probes.session?.chainTransaction?.revisionID
                            trace.continuedTransactionID = probes.session?.chainTransaction?.transactionID
                            try LiveScrollClipboard.copy(image, pasteboard: board)
                        }
                    }, pin: { image in
                        trace.pins += 1; trace.sameImage = trace.sameImage && probes.image === image
                        let id = try pins.add(originalImage: image, currentImage: image, title: "编号长图链输出")
                        trace.pinCommitted = true; probes.pinController = pins.liveControllers[id]
                        return id
                    }, cancelSave: { save.cancel() })
                })
            app = owner; probes.app = owner; trace.appInitialized = true
            owner.setupWindow()
            NotificationCenter.default.addObserver(owner, selector: #selector(AppDelegate.windowClosed(_:)),
                name: NSWindow.willCloseNotification, object: nil)
            let input = try OwnedProvider(reference: reference)
            probes.provider = input
            let live = try owner.makeLiveScrollSessionForVerification(resourceStorageParent: spool)
            session = live; probes.session = live
            try await start(live, provider: input, screen: screen)
            trace.sessionStarted = true
            var viewportTrace: [[String: Any]] = []
            for offset in offsets {
                try input.select(offset: offset)
                try await until("Viewport did not reach offset \(offset)", seconds: 5) {
                    live.stateForVerification.matched && live.stateForVerification.acceptedObservations > 0
                        && live.stateForVerification.viewportOffset == offset
                }
                viewportTrace.append(["offset": offset, "height": live.stateForVerification.height,
                                      "acceptedObservations": live.stateForVerification.acceptedObservations])
            }
            report["viewportTrace"] = viewportTrace
            try require(live.stateForVerification.width == width && live.stateForVerification.height == 704,
                        "Owned viewports did not assemble the full numbered document")
            let controls = try unwrap(live.controlsForVerification, "Live native controls missing")
            try menuAction("scroll.live.imageChain", action: "more-open-choice", controls: controls, trace: trace)
            let choice = try await choiceAlert(live)
            let picker = try unwrap(choice.accessoryView as? NSPopUpButton, "Native saved-chain choice missing")
            picker.selectItem(at: 0)
            trace.record("select-saved-definition", identifier: picker.identifier?.rawValue ?? "",
                         route: "NSPopUpButton.selectItem; no output command")
            try require(trace.noOutputs && owner.activeCaptureChain == nil && live.chainTransaction == nil,
                        "Selecting a chain executed an output")
            report["choiceArtifacts"] = try evidence(choice.window, phase: "choice", directory: directory, report: report, trace: trace)
            try buttonAction(choice.buttons[1], action: "cancel-choice", trace: trace)
            try await until("Choice Cancel did not return to draft", seconds: 5) { live.chainChoiceAlertForVerification == nil }
            report["noOutputOnSelectionOrChoiceCancel"] = trace.noOutputs && live.chainTransaction == nil
            try require(report["noOutputOnSelectionOrChoiceCancel"] as? Bool == true, "Choice Cancel executed a chain")
            try menuAction("scroll.live.imageChain", action: "more-open-choice", controls: controls, trace: trace)
            let runChoice = try await choiceAlert(live)
            try buttonAction(runChoice.buttons[0], action: "run-current-image", trace: trace)
            try await until("Save then rejected Copy did not reach failure", seconds: 20) {
                owner.activeCaptureChain?.status.canRetry == true
            }
            let failedRunner = try unwrap(owner.activeCaptureChain, "Failed prepared runner missing")
            probes.firstRunner = failedRunner
            let controller = try unwrap(owner.captureChainManagerForVerification, "Result controller missing")
            manager = controller; probes.manager = controller
            let window = try unwrap(controller.window, "Result native window missing")
            let failed = failedRunner.snapshot
            let transaction = try unwrap(live.chainTransaction, "Frozen long-image transaction missing")
            report["firstRunID"] = failed.runID.uuidString
            report["revisionID"] = transaction.revisionID.uuidString
            report["transactionID"] = transaction.transactionID.uuidString
            report["failureReceipts"] = failed.receipts.map(receiptFacts)
            report["failureAttempts"] = trace.counts
            try require(failed.receipts.map(\.output) == [.quickSavePNG] && failed.isExistingScrollImage
                && failedRunner.capture?.image === transaction.capture.image && probes.image === transaction.capture.image,
                "Failure lost frozen image or saved prefix")
            let savedReceipt = try unwrap(failed.receipts.first, "Save receipt missing")
            guard case .saved(let savedURL, let byteCount) = savedReceipt.value else { throw failure("Invalid Save receipt") }
            let savedBytes = try Data(contentsOf: savedURL)
            try require(savedURL.deletingLastPathComponent() == approved && savedBytes.count == byteCount,
                        "Save escaped owned folder or receipt byte count differs")
            report["savedPath"] = savedURL.path; report["savedPNGByteCount"] = savedBytes.count
            report["savedPNGFileSHA256"] = hash(savedBytes)
            report["savedPNGComparison"] = try comparison(decode(savedURL), reference)
            try savedBytes.write(to: directory.appendingPathComponent("scroll-chain-saved.png"), options: .atomic)
            try require(output.activeJobCount == 0 && output.controllers.isEmpty && output.retainedInputBytes == 0,
                        "Saved job did not drain before Cancel")
            report["saveDrainedBeforeCancel"] = true
            report["failureArtifacts"] = try evidence(window, phase: "failure", directory: directory, report: report, trace: trace)
            let cancel: NSButton = try control("capture-chain-cancel", in: window)
            try buttonAction(cancel, action: "cancel-remaining", trace: trace)
            try await until("Cancel did not return the saved prefix to paused draft", seconds: 5) {
                owner.activeCaptureChain == nil && live.chainAttemptID == nil && !live.snapshotForVerification.busy
            }
            let checkpoint = try unwrap(live.chainTransaction, "Cancel discarded the frozen checkpoint")
            let paused = live.snapshotForVerification
            report["pausedReceipts"] = checkpoint.receipts.map(receiptFacts)
            report["pausedDraftRetained"] = !live.isClosedForVerification && paused.paused
                && checkpoint.receipts == failed.receipts && checkpoint.capture.image === transaction.capture.image
                && checkpoint.transactionID == transaction.transactionID && checkpoint.revisionID == transaction.revisionID
            report["pausedMutationControlsDisabled"] = !paused.canPause && !paused.canAutoScroll && !paused.canMoveRegion
                && !paused.canChangeAxis && !paused.canImport && !paused.canCopy && !paused.canQuickSave && !paused.canPin && !paused.canFinish
            try require(report["pausedDraftRetained"] as? Bool == true && report["pausedMutationControlsDisabled"] as? Bool == true,
                        "Paused receipt draft permits mutation or lost its prefix")
            let manage: NSButton = try control("capture-chain-manage", in: window)
            try buttonAction(manage, action: "manage-saved-chains", trace: trace)
            let resultButton: NSButton = try control("capture-chain-result", in: window)
            try buttonAction(resultButton, action: "show-prior-receipt", trace: trace)
            report["noOutputOnManage"] = owner.activeCaptureChain == nil && trace.saves == 1
                && trace.copies == 1 && trace.pins == 0 && live.chainTransaction?.receipts == failed.receipts
            try require(report["noOutputOnManage"] as? Bool == true, "Management navigation silently restarted outputs")
            report["pausedStatus"] = paused.status
            report["pausedArtifacts"] = try evidence(unwrap(controls.toolbarWindow, "Paused toolbar missing"),
                phase: "paused", directory: directory, report: report, trace: trace)
            try menuAction("scroll.live.imageChain.replace", action: "more-open-replacement", controls: controls, trace: trace)
            let replacement = try await choiceAlert(live)
            report["replacementWarning"] = replacement.informativeText
            try require(replacement.informativeText.contains(savedURL.path) && replacement.informativeText.contains("再次"),
                        "Replacement omitted committed receipt or repeat-output warning")
            report["replacementArtifacts"] = try evidence(replacement.window, phase: "replacement", directory: directory, report: report, trace: trace)
            try buttonAction(replacement.buttons[1], action: "cancel-replacement", trace: trace)
            try await until("Replacement Cancel did not settle", seconds: 5) { live.chainChoiceAlertForVerification == nil }
            try menuAction("scroll.live.imageChain.abandon", action: "more-open-abandon", controls: controls, trace: trace)
            let abandon = try await choiceAlert(live)
            report["abandonWarning"] = abandon.informativeText
            try require(abandon.informativeText.contains(savedURL.path) && abandon.informativeText.contains("仍保留"),
                        "Abandon omitted committed-output preservation warning")
            report["abandonArtifacts"] = try evidence(abandon.window, phase: "abandon", directory: directory, report: report, trace: trace)
            try buttonAction(abandon.buttons[1], action: "cancel-abandon", trace: trace)
            try await until("Abandon Cancel did not settle", seconds: 5) { live.chainChoiceAlertForVerification == nil }
            report["noOutputOnReplacementOrAbandonCancel"] = trace.saves == 1 && trace.copies == 1 && trace.pins == 0
                && live.chainTransaction?.receipts == failed.receipts && live.chainTransaction?.transactionID == transaction.transactionID
                && live.chainTransaction?.capture.image === transaction.capture.image
            try require(report["noOutputOnReplacementOrAbandonCancel"] as? Bool == true, "Warning Cancel changed prior output transaction")
            try menuAction("scroll.live.imageChain.continue", action: "more-continue", controls: controls, trace: trace)
            try await until("More Continue did not finish the original saved chain", seconds: 15) {
                controller.displayedSnapshot?.status == .completed && owner.activeCaptureChain == nil && live.isClosedForVerification
            }
            let completed = try unwrap(controller.displayedSnapshot, "Final receipt summary missing")
            try require(completed.receipts.map(\.output) == definition.outputs && completed.receipts.first == savedReceipt
                && completed.runID != failed.runID && trace.continuedRunID == completed.runID,
                "Continue reused run identity or repeated the saved prefix")
            report["continuedRunID"] = completed.runID.uuidString
            report["continuedRevisionID"] = trace.continuedRevisionID?.uuidString ?? ""
            report["continuedTransactionID"] = trace.continuedTransactionID?.uuidString ?? ""
            report["renderCount"] = live.chainRenderCountForVerification
            report["oneFrozenImageAcrossAttempts"] = trace.sameImage && trace.continuedRevisionID == transaction.revisionID
                && trace.continuedTransactionID == transaction.transactionID && live.chainRenderCountForVerification == 1
            report["receipts"] = completed.receipts.map(receiptFacts)
            let copied = try unwrap(board.data(forType: .png), "Checked private Copy missing")
            let copiedURL = directory.appendingPathComponent("scroll-chain-copied.png")
            try copied.write(to: copiedURL, options: .atomic)
            report["copiedPNGFileSHA256"] = hash(copied)
            report["copiedPNGComparison"] = try comparison(decode(copiedURL), reference)
            guard let receipt = completed.receipts.last, case .pinned(let pinID) = receipt.value else { throw failure("Durable Pin receipt missing") }
            let entry = try unwrap(pinStore.entry(id: pinID), "Persistent Pin missing")
            let asset = pinStore.directory.appendingPathComponent(entry.current.filename)
            let pinBytes = try Data(contentsOf: asset)
            try pinBytes.write(to: directory.appendingPathComponent("scroll-chain-pin.png"), options: .atomic)
            report["pinPNGFileSHA256"] = hash(pinBytes)
            report["publishedPinComparison"] = try comparison(decode(asset), reference)
            let reloaded = try PinSessionStore(directory: pinStore.directory)
            let reloadedImage = try unwrap(reloaded.image(id: pinID), "Reloaded Pin unavailable")
            report["reloadedPinComparison"] = try comparison(reloadedImage, reference)
            let reloadedURL = directory.appendingPathComponent("scroll-chain-pin-reloaded.png")
            try writePNG(reloadedImage, to: reloadedURL)
            report["reloadedPinPNGFileSHA256"] = hash(try Data(contentsOf: reloadedURL))
            report["pinID"] = pinID.uuidString; report["pinEntryCount"] = pinStore.entries.count
            report["reloadedPinEntryCount"] = reloaded.entries.count
            report["visibleNativePinCount"] = pins.livePinCount
            report["pinOriginalAndCurrentShareOneAsset"] = entry.original.filename == entry.current.filename
            report["savedFileCount"] = try FileManager.default.contentsOfDirectory(atPath: approved.path).count
            report["savedPNGUnchanged"] = try Data(contentsOf: savedURL) == savedBytes
            report["finalRetainedBytes"] = completed.retainedBytes; report["terminalStatus"] = "completed"
            let after = try Data(contentsOf: catalogURL)
            report["catalogAfterSHA256"] = hash(after)
            let decoded = try JSONDecoder().decode(CaptureChainIndex.self, from: after)
            let catalogFiles = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
            report["catalogDefinitionsOnly"] = before == after && decoded.definitions == [definition]
                && decoded.selectedID == definition.id
                && catalogFiles == [CaptureChainStore.manifestFilename]
            report["noEditorHistoryOrTransientPinOutput"] = history.records.isEmpty
                && !owner.controllers.contains(where: { $0 is ImageEditorController }) && owner.pins.isEmpty && owner.pinSession == nil
            try require(trace.captures == 0 && trace.saves == 1 && trace.saveAdmissions == 1 && trace.copies == 2 && trace.pins == 1,
                        "Continuation repeated an output or performed fresh capture")
            for key in ["savedPNGComparison", "copiedPNGComparison", "publishedPinComparison", "reloadedPinComparison"] {
                try require((report[key] as? [String: Any])?["passed"] as? Bool == true, "Output pixels differ: " + key)
            }
            for key in ["oneFrozenImageAcrossAttempts", "savedPNGUnchanged", "catalogDefinitionsOnly", "noEditorHistoryOrTransientPinOutput",
                        "pinOriginalAndCurrentShareOneAsset"] {
                try require(report[key] as? Bool == true, "Existing-image output invariant failed: " + key)
            }
            try require(pinStore.entries.count == 1 && reloaded.entries.count == 1 && pins.livePinCount == 1
                && pins.liveControllers[pinID]?.window?.isVisible == true && (report["savedFileCount"] as? Int == 1),
                "Continue duplicated Save or failed one visible durable Pin")
            report["resultArtifacts"] = try evidence(window, phase: "result", directory: directory, report: report, trace: trace)
            report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        app?.activeCaptureChain?.cancel(); delivery?.cancel(); presenter?.cancelAll()
        await session?.closeForVerification()
        do {
            try await until("Live chain cleanup did not drain", seconds: 5) {
                app?.activeCaptureChain == nil && session?.isClosedForVerification != false
                    && (presenter?.activeJobCount ?? 0) == 0 && presenter?.controllers.isEmpty != false
                    && (presenter?.retainedInputBytes ?? 0) == 0
            }
            try coordinator?.prepareForTermination()
        } catch { report["status"] = "failed"; report["cleanupError"] = error.localizedDescription }
        let closed = session?.isClosedForVerification ?? true
        let spoolEmpty = (try? FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty) == true
        let drained = app?.activeCaptureChain == nil && closed && spoolEmpty && (presenter?.activeJobCount ?? 0) == 0
            && presenter?.controllers.isEmpty != false && (presenter?.retainedInputBytes ?? 0) == 0
            && (coordinator?.livePinCount ?? 0) == 0
        presenter?.onPresent = nil; manager?.close()
        if let app {
            NotificationCenter.default.removeObserver(app, name: NSWindow.willCloseNotification, object: nil)
            app.mainWindow?.contentView = nil; app.mainWindow?.close(); app.controllers.removeAll()
        }
        session = nil; manager = nil; app = nil; delivery = nil; presenter = nil; coordinator = nil
        board.releaseGlobally()
        if drained { defaults?.removePersistentDomain(forName: suite) }
        report["actionTrace"] = trace.actions; report["attempts"] = trace.counts
        report["productSessionClosed"] = closed; report["spoolDirectoryEmpty"] = spoolEmpty
        report["saveJobsDrained"] = drained; report["privatePasteboardReleased"] = true
        report["isolatedDefaultsRemoved"] = drained; report["cleanupSafe"] = drained
        try? persistTrace(report, trace: trace, directory: directory)
        if !drained { report["status"] = "failed" }
        return report
    }

    private static func choiceAlert(_ session: LiveScrollSessionController) async throws -> NSAlert {
        try await until("Native saved-chain choice did not open", seconds: 5) {
            session.chainChoiceAlertForVerification?.window.isVisible == true
        }
        return try unwrap(session.chainChoiceAlertForVerification, "Choice alert missing")
    }
    private static func menuAction(_ identifier: String, action: String,
                                   controls: LiveScrollCaptureController, trace: Trace) throws {
        let item = try unwrap(controls.makeMoreMenu().items.first { $0.identifier?.rawValue == identifier }, "More item missing")
        try require(item.isEnabled && !item.isHidden, "More command unavailable: " + identifier)
        let selector = try unwrap(item.action, "More selector missing")
        try require(NSApp.sendAction(selector, to: item.target, from: item), "Native More dispatch refused")
        trace.record(action, identifier: identifier, route: "NSApp.sendAction on production More menu item")
    }
    private static func buttonAction(_ button: NSButton, action: String, trace: Trace) throws {
        try PortableSettingsUIPreviewFixture.click(button)
        trace.record(action, identifier: button.identifier?.rawValue ?? "",
                     route: "PortableSettingsUIPreviewFixture.click: owned NSButton.mouseDown with queued mouseUp")
    }
    private static func evidence(_ window: NSWindow, phase: String, directory: URL,
                                 report: [String: Any], trace: Trace) throws -> [[String: Any]] {
        // Preserve action/receipt facts before native pixels or geometry can fail.
        try persistTrace(report, trace: trace, directory: directory)
        return try CaptureChainUIPreviewFixture.captureOwnedEvidence(window: window,
            phase: "scroll-chain-" + phase, evidenceDirectory: directory)
    }
    private static func persistTrace(_ report: [String: Any], trace: Trace, directory: URL) throws {
        let value: [String: Any] = ["actionTrace": trace.actions,
            "failureReceipts": report["failureReceipts"] ?? [], "pausedReceipts": report["pausedReceipts"] ?? [],
            "receipts": report["receipts"] ?? []]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("scroll-chain-actions.json"), options: .atomic)
    }
    private final class Trace {
        var captures = 0, saves = 0, saveAdmissions = 0, copies = 0, pins = 0
        var sameImage = true, appInitialized = false, sessionStarted = false, saveCommitted = false, pinCommitted = false
        var continuedRunID: UUID?, continuedRevisionID: UUID?, continuedTransactionID: UUID?
        var actions: [[String: Any]] = []
        var counts: [String: Int] { ["capture": captures, "save": saves, "saveAdmissions": saveAdmissions, "copy": copies, "pin": pins] }
        var noOutputs: Bool { captures == 0 && saves == 0 && copies == 0 && pins == 0 }
        func record(_ action: String, identifier: String, route: String) {
            actions.append(["index": actions.count, "action": action, "identifier": identifier, "route": route])
        }
    }
    private final class LifetimeProbes {
        weak var app: AppDelegate?
        weak var session: LiveScrollSessionController?
        weak var manager: CaptureChainController?
        weak var firstRunner: CaptureChainRunner?
        weak var continuedRunner: CaptureChainRunner?
        weak var image: CGImage?
        weak var provider: OwnedProvider?
        weak var saveJob: SaveWorkflowController?
        weak var pinController: PinController?
        weak var presenter: SaveWorkflowPresenter?
        weak var delivery: SaveWorkflowDelivery?
        weak var coordinator: PinSessionCoordinator?
        var facts: [String: Bool] { ["app": app == nil, "session": session == nil, "manager": manager == nil,
            "firstRunner": firstRunner == nil, "continuedRunner": continuedRunner == nil, "frozenImage": image == nil,
            "provider": provider == nil, "saveJob": saveJob == nil, "pinController": pinController == nil,
            "presenter": presenter == nil, "delivery": delivery == nil, "pinCoordinator": coordinator == nil] }
        var allReleased: Bool { facts.values.allSatisfy { $0 } }
    }

    private static func start(_ owner: LiveScrollSessionController, provider: OwnedProvider, screen: NSScreen) async throws {
        let frame = CGRect(x: screen.visibleFrame.midX - CGFloat(width) / 2,
            y: screen.visibleFrame.midY - CGFloat(viewportHeight) / 2,
            width: CGFloat(width), height: CGFloat(viewportHeight))
        try await owner.startForVerification(targetFrame: frame, screen: screen, nextImage: {
            try await Task.sleep(nanoseconds: 30_000_000)
            try Task.checkCancellation()
            provider.calls += 1
            return provider.current
        })
    }

    @MainActor private final class OwnedProvider {
        let reference: CGImage
        var current: CGImage
        var calls = 0
        init(reference: CGImage) throws {
            self.reference = reference
            current = try LiveScrollChainDemoFixture.unwrap(reference.cropping(to: CGRect(x: 0, y: 0,
                width: LiveScrollChainDemoFixture.width, height: LiveScrollChainDemoFixture.viewportHeight)), "Initial owned viewport missing")
        }
        func select(offset: Int) throws {
            current = try LiveScrollChainDemoFixture.unwrap(reference.cropping(to: CGRect(x: 0, y: offset,
                width: LiveScrollChainDemoFixture.width, height: LiveScrollChainDemoFixture.viewportHeight)), "Owned viewport crop missing")
        }
    }

    private final class NumberedDocument: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); bounds.fill()
            let titles = ["Keep the complete source", "Review the final image", "Copy can be retried", "Save the original pixels",
                          "One owner for every output", "Pin a recoverable image", "A small native control", "Finish with a clear result"]
            for row in 0..<22 {
                let y = row * 32
                NSColor(calibratedWhite: row % 2 == 0 ? 0.98 : 0.94, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: LiveScrollChainDemoFixture.width, height: 32).fill()
                (String(format: "%02d", row + 1) as NSString).draw(at: CGPoint(x: 14, y: y + 8), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.darkGray])
                (titles[row % titles.count] as NSString).draw(at: CGPoint(x: 48, y: y + 3), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black])
                ("Owned entry \(row + 1) · PicShot output demonstration" as NSString).draw(at: CGPoint(x: 48, y: y + 19),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray])
                // A fixed numbered illustration varies over the entire row. It
                // keeps this small output fixture deterministic between baselines.
                for line in 0..<32 {
                    let shade = 0.35 + 0.22 * sin(Double(y + line) * 0.71 + Double(row) * 0.13)
                    NSColor(srgbRed: 0.18 + shade * 0.5, green: 0.35 + shade * 0.5, blue: 0.46 + shade * 0.4, alpha: 1).setFill()
                    NSRect(x: 368, y: y + line, width: 112, height: 1).fill()
                    NSColor(srgbRed: 0.12, green: 0.32, blue: 0.28, alpha: 1).setFill()
                    NSRect(x: 368, y: y + line, width: 22 + Int(17 * sin(Double(line) * 0.25 + Double(row))), height: 1).fill()
                }
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
            .write(to: directory.appendingPathComponent("live-scroll-chain.json"), options: .atomic)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw failure(message) }; return value
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Live chain demo: " + message) }
}
