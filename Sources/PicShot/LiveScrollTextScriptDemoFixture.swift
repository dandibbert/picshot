import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore
import PicShotTextScriptCore
import PicShotTextScriptProcess

/// One installed witness over owned native pixels. Acquisition alone is supplied;
/// assembly, saved choice, Vision, signed helper, checked Copy and Retry are real.
@MainActor enum LiveScrollTextScriptDemoFixture {
    static let expected = "ABC-123\nXYZ-987"
    static let savedName = "提取长图工单编号"
    static let savedSource = "const ids = text.match(/\\b[A-Z]{2,8}-\\d+\\b/g) || []; return [...new Set(ids)].join(\"\\n\");"
    static let scope = "Installed current-long-image/saved-script/Apple-Vision/signed-helper/checked-private-Copy witness over generated acquisition"
    static let limitations = [
        "Owned acquisition does not prove desktop selection, ScreenCaptureKit, TCC or third-party scrolling",
        "First checked private clipboard write is deliberately rejected",
        "Native images cache owned content only; no desktop screenshot",
        "256 MiB child RSS is sampled, not a hard allocation cap; bounded weak-owner drainage is not a leak or original227 memory pass"]
    private static let width = 720, height = 1056, viewportHeight = 480
    private static let offsets = [0, 144, 288, 432, 528, 576]
    private static let rawFilename = "live-scroll-text-script.json"

    static func verify(evidenceDirectory directory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let files = FileManager.default, started = ProcessInfo.processInfo.systemUptime
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        var report: [String: Any] = ["schemaVersion": 1, "status": "running", "scope": scope,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "source": "Fixture-owned native numbered scrolling document; deterministic viewport crops",
            "acquisition": "LiveScrollVerificationFrameSource; actual AppDelegate, live session, assembler and prepared text runner",
            "installerAcceptance": false, "original227MemoryAcceptance": false, "hardMemoryCapClaimed": false,
            "realScreenCaptureClaimed": false, "screenCaptureAPICalled": false, "permissionRequested": false,
            "networkUsed": false, "globalInputPosted": false, "userHistoryReadOrWritten": false,
            "standardDefaultsReadOrWritten": false, "generalPasteboardReadOrWritten": false,
            "runtimeGateBuild": false, "transportFixtureUsed": false, "limitations": limitations,
            "generatedExpectedOutput": expected, "productAppDelegateExercised": false,
            "productSessionControllerExercised": false, "productSessionClosed": false,
            "realAppleVisionRan": false, "productionHelperRan": false,
            "limits": ["maximumRasterPixels": PinImageRenderer.maximumRasterPixels,
                "sourceBytes": TextScriptLimits.sourceBytes, "inputUTF16Units": TextScriptLimits.inputUTF16Units,
                "outputUTF16Units": TextScriptLimits.outputUTF16Units, "outputUTF8Bytes": TextScriptLimits.outputUTF8Bytes,
                "helperAcceptanceSeconds": TextScriptLimits.acceptanceSeconds,
                "sampledResidentLimitBytes": TextScriptLimits.residentBytes,
                "ownerDrainSeconds": 5, "ocrHelperWaitSeconds": 25, "maximumUIPhases": 3]]
        let trace = Trace(), probes = Probes()
        var root: URL?, safe = false
        try write(report, to: directory.appendingPathComponent(rawFilename))
        do {
            try require(ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] != nil, "smoke-required")
            let screen = try unwrap(NSScreen.main, "display-required")
            let vision = await RecognitionService.resourceSnapshot()
            try require(vision.activeJobs == 0 && vision.waitingJobs == 0 && !TextScriptProcessService.snapshot().occupied,
                        "initial-boundary-busy")
            let owned = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-LiveText-" + UUID().uuidString)
            root = owned; report["canonicalPrivateTemporaryRoot"] = true
            NSApp.appearance = NSAppearance(named: .aqua)
            let document = NumberedDocument(frame: CGRect(x: 0, y: 0, width: width, height: height))
            document.appearance = NSAppearance(named: .aqua)
            let sourceURL = directory.appendingPathComponent("scroll-text-script-owned-numbered.png")
            try writePNG(nativeImage(document), to: sourceURL)
            let reference = try decode(sourceURL)
            report["sourceReference"] = try imageFacts(reference)
            report["sourcePNGFileSHA256"] = hash(try Data(contentsOf: sourceURL))
            try Data(savedSource.utf8).write(to: directory.appendingPathComponent("scroll-text-script-source.js"), options: .atomic)
            let result = await runCase(reference: reference, screen: screen, root: owned,
                                       directory: directory, trace: trace, probes: probes)
            report["copyRetry"] = result
            safe = result["cleanupSafe"] as? Bool == true
            report["productSessionClosed"] = result["productSessionClosed"] as? Bool == true
            try write(report, to: directory.appendingPathComponent(rawFilename))
            try await until("owner-release-timeout", seconds: 5) { probes.allReleased }
            report["ownershipReleased"] = probes.allReleased
            report["status"] = result["status"] as? String == "passed" && safe ? "passed" : "failed"
        } catch { report["status"] = "failed"; report["failureCode"] = fixedCode(error); safe = false }
        report["ownership"] = probes.facts
        report["ownershipReleased"] = probes.allReleased
        if let root, safe {
            do { try files.removeItem(at: root); report["privateTemporaryRootRemoved"] = !files.fileExists(atPath: root.path) }
            catch { report["status"] = "failed"; report["cleanupFailureCode"] = "private-root-removal-failed" }
        } else if root != nil { report["privateTemporaryRootRemoved"] = false }
        let vision = await RecognitionService.resourceSnapshot()
        report["productAppDelegateExercised"] = trace.appInitialized
        report["productSessionControllerExercised"] = trace.sessionStarted
        report["realAppleVisionRan"] = trace.ocr == 1
        report["productionHelperRan"] = trace.metrics.count == 1 && trace.metrics.first?.outcome == .succeeded
        report["finalVisionActiveJobs"] = vision.activeJobs; report["finalVisionWaitingJobs"] = vision.waitingJobs
        report["finalHelperAdmissionOccupied"] = TextScriptProcessService.snapshot().occupied
        report["cleanupSafe"] = safe && probes.allReleased && report["privateTemporaryRootRemoved"] as? Bool == true
            && vision.activeJobs == 0 && vision.waitingJobs == 0 && !TextScriptProcessService.snapshot().occupied
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        if report["cleanupSafe"] as? Bool != true { report["status"] = "failed" }
        try write(report, to: directory.appendingPathComponent(rawFilename))
        try require(report["status"] as? String == "passed", "installed-witness-failed-see-preserved-report")
        return report
    }

    private static func runCase(reference: CGImage, screen: NSScreen, root: URL, directory: URL,
                                trace: Trace, probes: Probes) async -> [String: Any] {
        let suite = "PicShot-LiveText-" + UUID().uuidString
        let board = NSPasteboard(name: .init("PicShot-LiveText-" + UUID().uuidString))
        let spool = root.appendingPathComponent("spool", isDirectory: true)
        var report: [String: Any] = ["status": "running", "case": "copyRetry", "viewportOffsets": offsets,
            "actionRoute": "Production More NSApp.sendAction; owned native chooser Run/Retry/Close mouseDown with queued mouseUp",
            "copyRejectionInjectedAtCheckedWriter": true, "recognitionLanguage": "en-US"]
        var defaults: UserDefaults?, app: AppDelegate?, session: LiveScrollSessionController?
        var manager: CaptureChainController?, runtime: CaptureChainTextRuntime?
        do {
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false)
            let isolated = try unwrap(UserDefaults(suiteName: suite), "isolated-defaults-unavailable")
            defaults = isolated; isolated.set("owned-live-text-witness", forKey: "fixtureMarker")
            let defaultsBefore = try defaultsBytes(isolated, suite: suite)
            let scripts = try TextScriptStore(directory: root.appendingPathComponent("scripts", isDirectory: true))
            let definition = try TextScriptDefinition(name: savedName, source: savedSource)
            try scripts.add(definition, select: true)
            let catalog = scripts.directory.appendingPathComponent(TextScriptStore.manifestFilename)
            let before = try Data(contentsOf: catalog)
            try before.write(to: directory.appendingPathComponent("scroll-text-script-catalog.json"), options: .atomic)
            report["definitionID"] = definition.id.uuidString
            report["savedDefinitionReloaded"] = try TextScriptStore(directory: scripts.directory).definitions == [definition]
            report["catalogBeforeSHA256"] = hash(before)
            report["isolatedDefaultsBeforeSHA256"] = hash(defaultsBefore)
            let chains = try CaptureChainStore(directory: root.appendingPathComponent("chains", isDirectory: true))
            let history = HistoryStore(directory: root.appendingPathComponent("history", isDirectory: true),
                policy: RetentionPolicy(maxItems: 2, maxBytes: 8 * 1_024 * 1_024, maxDays: 1))
            let historyBefore = try directoryFacts(history.directory), chainsBefore = try directoryFacts(chains.directory)
            let process = CaptureChainTextRuntime(onMetrics: { trace.metrics.append($0) })
            runtime = process; probes.runtime = process
            let owner = AppDelegate(history: history, isolatedDefaults: isolated, chainStore: chains,
                textScriptStore: scripts, textScriptDependencies: { requested in
                    try require(requested == definition, "saved-definition-not-frozen")
                    trace.definitionFrozen = true
                    return .init(capture: {
                        trace.captures += 1
                        throw FixtureFailure(code: "unexpected-fresh-capture")
                    }, recognize: { image in
                        probes.image = image
                        trace.acceptedImageReference = try imageFacts(image)
                        let url = directory.appendingPathComponent("scroll-text-script-accepted.png")
                        try writePNG(image, to: url)
                        trace.acceptedPNGFileSHA256 = hash(try Data(contentsOf: url))
                        trace.sourceImageComparison = try comparison(decode(url), reference)
                        try require(trace.sourceImageComparison["passed"] as? Bool == true, "accepted-frontier-pixels-mismatch")
                        trace.comparedBeforeOCR = true
                        trace.ocr += 1
                        let value = try await RecognitionService.recognize(image, options: RecognitionOptions(language: "en-US"))
                        trace.ocrText = value.text; trace.truncated = value.document?.isTruncated == true
                        try Data(value.text.utf8).write(to: directory.appendingPathComponent("scroll-text-script-ocr.txt"), options: .atomic)
                        return ChainTextRecognition(text: value.text, truncated: trace.truncated)
                    }, transform: { source, text, id in
                        trace.transformSourceFrozen = source == savedSource
                        guard trace.transformSourceFrozen else { return .failed(.invalidResult, cleanupPending: false) }
                        trace.transforms += 1; trace.requestID = id
                        return await process.transform(source: source, text: text, requestID: id)
                    }, copy: { text in
                        trace.copies += 1
                        try require(text == expected, "generated-output-mismatch")
                        if trace.copies == 1 { try CheckedTextClipboard.copy(text, pasteboard: board, writer: { _, _ in false }) }
                        else { try CheckedTextClipboard.copy(text, pasteboard: board); trace.commits += 1 }
                    }, cleanupComplete: { process.cleanupComplete(requestID: $0) })
                })
            app = owner; probes.app = owner; trace.appInitialized = true
            owner.setupWindow()
            NotificationCenter.default.addObserver(owner, selector: #selector(AppDelegate.windowClosed(_:)),
                name: NSWindow.willCloseNotification, object: nil)
            let input = try OwnedProvider(reference: reference); probes.provider = input
            let live = try owner.makeLiveScrollSessionForVerification(resourceStorageParent: spool)
            session = live; probes.session = live
            let frame = CGRect(x: screen.visibleFrame.midX - CGFloat(width) / 2,
                y: screen.visibleFrame.midY - CGFloat(viewportHeight) / 2,
                width: CGFloat(width), height: CGFloat(viewportHeight))
            try await live.startForVerification(targetFrame: frame, screen: screen, nextImage: {
                try await Task.sleep(nanoseconds: 30_000_000); try Task.checkCancellation()
                input.calls += 1; return input.current
            })
            trace.sessionStarted = true
            var viewportTrace: [[String: Any]] = []
            for offset in offsets {
                try input.select(offset: offset)
                try await until("viewport-not-accepted", seconds: 5) {
                    live.stateForVerification.matched && live.stateForVerification.acceptedObservations > 0
                        && live.stateForVerification.viewportOffset == offset
                }
                viewportTrace.append(["offset": offset, "height": live.stateForVerification.height,
                                      "acceptedObservations": live.stateForVerification.acceptedObservations])
            }
            report["viewportTrace"] = viewportTrace
            report["finalAcceptedWidth"] = live.stateForVerification.width
            report["finalAcceptedHeight"] = live.stateForVerification.height
            try require(live.stateForVerification.width == width && live.stateForVerification.height == height,
                        "full-document-not-assembled")
            let committed = try unwrap(await live.documentSnapshotForResourceVerification(), "committed-document-missing")
            let frontier = live.stateForVerification
            report["preRunFrontier"] = ["width": frontier.width, "acceptedHeight": frontier.height,
                "committedHeight": committed.height, "committedLowerBound": committed.lowerBound,
                "committedUpperBound": committed.upperBound, "viewportOffset": frontier.viewportOffset,
                "viewportLength": committed.viewportLength, "pendingPixelRows": frontier.height - committed.height,
                "previewIsTransient": frontier.previewIsTransient, "committedSources": committed.sourceCount,
                "acceptedObservations": frontier.acceptedObservations]
            try require(frontier.previewIsTransient && frontier.height == height && committed.height == height - 48
                && committed.lowerBound == 0 && committed.upperBound == height - 48 && frontier.viewportOffset == 576
                && committed.viewportLength == viewportHeight && committed.sourceCount == 5
                && frontier.acceptedObservations == offsets.count, "pending-frontier-not-observed")
            let controls = try unwrap(live.controlsForVerification, "live-controls-missing")
            try menuAction(controls, trace: trace)
            try await until("choice-not-opened", seconds: 5) { live.textChoiceAlertForVerification?.window.isVisible == true }
            let choice = try unwrap(live.textChoiceAlertForVerification, "choice-missing")
            let picker = try unwrap(choice.accessoryView as? NSPopUpButton, "saved-script-picker-missing")
            picker.selectItem(at: 0)
            trace.record("select-saved-definition", identifier: picker.identifier?.rawValue ?? "",
                         route: "NSPopUpButton.selectItem; no output command")
            report["noOutputOnSelection"] = trace.noOutputs && owner.activeCaptureChain == nil && live.textAttemptID == nil
            try require(report["noOutputOnSelection"] as? Bool == true, "selection-ran-script")
            report["choiceArtifacts"] = try evidence(choice.window, phase: "choice", report: report, trace: trace, directory: directory)
            try buttonAction(choice.buttons[0], action: "run-current-long-image", trace: trace)
            try await until("copy-failure-not-reached", seconds: 25) { owner.activeCaptureChain?.status.canRetry == true }
            let active = try unwrap(owner.activeCaptureChain, "runner-missing"); probes.runner = active
            let controller = try unwrap(owner.captureChainManagerForVerification, "progress-missing")
            manager = controller; probes.manager = controller
            let window = try unwrap(controller.window, "progress-window-missing")
            report["runID"] = active.id.uuidString
            let rejectedCopy = active.status == .textFailed(.copy, .clipboardRejected)
            report["failurePhase"] = rejectedCopy ? "copy" : "unexpected-text-phase"
            report["failureCode"] = rejectedCopy ? "clipboardRejected" : "unexpected-text-failure"
            report["failureAttempts"] = trace.attempts
            report["failureReceiptCount"] = active.textReceipt == nil ? 0 : 1
            report["failureReceipts"] = [] as [String]
            report["failedRetainedTextBytes"] = active.retainedTextBytes
            report["failedImageReleased"] = active.capture == nil && probes.image == nil
            report["providerStagingReleased"] = live.stagedTextCapture == nil && probes.image == nil
            report["rejectedPasteboardEmpty"] = board.string(forType: .string) == nil
            report["paused"] = live.snapshotForVerification.paused
            report["nonAuto"] = !live.snapshotForVerification.autoScrolling
            report["textRenderCount"] = live.textRenderCountForVerification
            report["isExistingScrollImage"] = active.isExistingScrollImage
            report["isTextScript"] = active.isTextScript
            report["sourceProviderCallsAtFailure"] = input.calls
            try persist(report, trace: trace, directory: directory)
            try require(rejectedCopy && active.textReceipt == nil
                && active.receipts.isEmpty && active.capture == nil && probes.image == nil
                && active.retainedTextBytes == expected.utf8.count && !active.isAttemptRunning, "failed-state-mismatch")
            try require(trace.captures == 0 && trace.ocr == 1 && trace.transforms == 1 && trace.copies == 1
                && trace.commits == 0 && !trace.truncated && trace.comparedBeforeOCR, "failure-attempts-mismatch")
            try require(live.snapshotForVerification.paused && !live.snapshotForVerification.autoScrolling
                && live.textRenderCountForVerification == 1 && live.stagedTextCapture == nil
                && active.isExistingScrollImage && active.isTextScript, "live-text-owner-mismatch")
            try require(board.string(forType: .string) == nil, "rejected-copy-published-text")
            let metric = try unwrap(trace.metrics.first, "helper-metrics-missing")
            try require(trace.metrics.count == 1 && metric.outcome == .succeeded && metric.childLaunched
                && metric.childExitConfirmed && metric.pipesDrained && metric.admissionReleased
                && metric.signature?.appAndHelperStrictlyValidated == true, "production-helper-not-confirmed")
            report["failureArtifacts"] = try evidence(window, phase: "failure", report: report, trace: trace, directory: directory)
            let providerCalls = input.calls
            let retry: NSButton = try control("capture-chain-retry", in: window)
            try buttonAction(retry, action: "retry-copy", trace: trace)
            try await until("copy-retry-not-completed", seconds: 25) {
                owner.activeCaptureChain == nil && controller.displayedSnapshot?.status == .completed
                    && live.isClosedForVerification
            }
            let completed = try unwrap(controller.displayedSnapshot, "completed-snapshot-missing")
            let actual = try unwrap(board.string(forType: .string), "checked-copy-missing")
            try require(actual == expected && completed.textReceipt?.characterCount == expected.count
                && completed.receipts.isEmpty && completed.retainedBytes == 0 && completed.retainedTextBytes == 0,
                "completed-receipt-mismatch")
            report["generatedActualOutput"] = actual; report["receiptCharacterCount"] = completed.textReceipt?.characterCount
            report["committedReceiptCount"] = 1; report["receipts"] = [["kind": "textCopy", "characterCount": expected.count]]
            let copied = Data(actual.utf8)
            try copied.write(to: directory.appendingPathComponent("scroll-text-script-copied.txt"), options: .atomic)
            report["copiedTextSHA256"] = hash(copied); report["copiedTextBytes"] = copied.count
            report["cacheRetry"] = trace.captures == 0 && trace.ocr == 1 && trace.transforms == 1
                && trace.copies == 2 && trace.commits == 1 && live.textRenderCountForVerification == 1
            report["sourceProviderCallsAfterRetry"] = input.calls
            report["sourceProviderStayedPaused"] = providerCalls == input.calls
            report["finalRetainedBytes"] = active.retainedBytes; report["finalRetainedTextBytes"] = active.retainedTextBytes
            report["terminalStatus"] = "completed"
            let after = try Data(contentsOf: catalog), defaultsAfter = try defaultsBytes(isolated, suite: suite)
            report["catalogAfterSHA256"] = hash(after)
            let catalogFiles = try FileManager.default.contentsOfDirectory(atPath: scripts.directory.path)
            report["catalogDefinitionsOnly"] = before == after && catalogFiles == [TextScriptStore.manifestFilename]
            report["isolatedDefaultsAfterSHA256"] = hash(defaultsAfter)
            report["isolatedDefaultsUnchanged"] = defaultsBefore == defaultsAfter
            report["historyUnchanged"] = try directoryFacts(history.directory) == historyBefore && history.records.isEmpty
            report["chainCatalogUnchanged"] = try directoryFacts(chains.directory) == chainsBefore
            report["noEditorHistoryOrPinOutput"] = history.records.isEmpty && owner.pins.isEmpty && owner.pinSession == nil
                && !owner.controllers.contains(where: { $0 is ImageEditorController })
            for key in ["cacheRetry", "sourceProviderStayedPaused", "catalogDefinitionsOnly", "isolatedDefaultsUnchanged",
                        "historyUnchanged", "chainCatalogUnchanged", "noEditorHistoryOrPinOutput", "savedDefinitionReloaded"] {
                try require(report[key] as? Bool == true, "post-run-invariant-failed")
            }
            try require(trace.definitionFrozen && trace.transformSourceFrozen, "frozen-script-changed")
            report["resultArtifacts"] = try evidence(window, phase: "result", report: report, trace: trace, directory: directory)
            let close: NSButton = try control("capture-chain-close", in: window)
            try buttonAction(close, action: "close-result", trace: trace)
            try await until("result-close-not-retired", seconds: 5) { !window.isVisible && owner.activeCaptureChain == nil }
            report["status"] = "passed"
        } catch { report["status"] = "failed"; report["fixtureFailureCode"] = fixedCode(error) }
        app?.activeCaptureChain?.cancel()
        await session?.closeForVerification()
        do {
            try await until("owner-drain-timeout", seconds: 5) {
                app?.activeCaptureChain == nil && session?.isClosedForVerification != false
                    && !TextScriptProcessService.snapshot().occupied
            }
        } catch { report["status"] = "failed"; report["cleanupFailureCode"] = "owner-drain-timeout" }
        let vision = await RecognitionService.resourceSnapshot()
        let closed = session?.isClosedForVerification ?? true
        let spoolEmpty = (try? FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty) == true
        let drained = app?.activeCaptureChain == nil && closed && spoolEmpty && !TextScriptProcessService.snapshot().occupied
            && vision.activeJobs == 0 && vision.waitingJobs == 0
        manager?.close()
        if let app {
            NotificationCenter.default.removeObserver(app, name: NSWindow.willCloseNotification, object: nil)
            app.mainWindow?.contentView = nil; app.mainWindow?.close(); app.controllers.removeAll()
        }
        session = nil; manager = nil; app = nil; runtime = nil
        board.releaseGlobally()
        if drained { defaults?.removePersistentDomain(forName: suite) }
        report["productSessionClosed"] = closed; report["spoolDirectoryEmpty"] = spoolEmpty
        report["visionJobsDrained"] = vision.activeJobs == 0 && vision.waitingJobs == 0
        report["helperAdmissionDrained"] = !TextScriptProcessService.snapshot().occupied
        report["privatePasteboardReleased"] = true; report["isolatedDefaultsRemoved"] = drained
        report["cleanupSafe"] = drained
        enrich(&report, trace: trace)
        if !drained { report["status"] = "failed" }
        try? persist(report, trace: trace, directory: directory)
        return report
    }

    private final class Trace {
        var captures = 0, ocr = 0, transforms = 0, copies = 0, commits = 0
        var appInitialized = false, sessionStarted = false, truncated = false, comparedBeforeOCR = false
        var definitionFrozen = false, transformSourceFrozen = false
        var ocrText = "", acceptedPNGFileSHA256 = "", requestID: UUID?
        var metrics: [TextScriptProcessMetrics] = [], actions: [[String: Any]] = []
        var acceptedImageReference: [String: Any] = [:], sourceImageComparison: [String: Any] = [:]
        var attempts: [String: Int] { ["capture": captures, "ocr": ocr, "transform": transforms, "copy": copies, "committedCopy": commits] }
        var noOutputs: Bool { captures == 0 && ocr == 0 && transforms == 0 && copies == 0 && commits == 0 }
        func record(_ action: String, identifier: String, route: String) {
            actions.append(["index": actions.count, "action": action, "identifier": identifier, "route": route])
        }
    }
    private final class Probes {
        weak var app: AppDelegate?, session: LiveScrollSessionController?, manager: CaptureChainController?
        weak var runner: CaptureChainRunner?, image: CGImage?, runtime: CaptureChainTextRuntime?, provider: OwnedProvider?
        var facts: [String: Bool] { ["app": app == nil, "session": session == nil, "manager": manager == nil,
            "runner": runner == nil, "renderedImage": image == nil, "runtime": runtime == nil, "provider": provider == nil] }
        var allReleased: Bool { facts.values.allSatisfy { $0 } }
    }
    @MainActor private final class OwnedProvider {
        let reference: CGImage
        var current: CGImage
        var calls = 0
        init(reference: CGImage) throws {
            self.reference = reference
            current = try LiveScrollTextScriptDemoFixture.unwrap(reference.cropping(to: CGRect(x: 0, y: 0,
                width: LiveScrollTextScriptDemoFixture.width, height: LiveScrollTextScriptDemoFixture.viewportHeight)), "initial-crop-missing")
        }
        func select(offset: Int) throws {
            current = try LiveScrollTextScriptDemoFixture.unwrap(reference.cropping(to: CGRect(x: 0, y: offset,
                width: LiveScrollTextScriptDemoFixture.width, height: LiveScrollTextScriptDemoFixture.viewportHeight)), "viewport-crop-missing")
        }
    }
    private final class NumberedDocument: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); bounds.fill()
            for row in 0..<22 {
                let y = row * 48
                NSColor(calibratedWhite: row % 2 == 0 ? 0.98 : 0.94, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: LiveScrollTextScriptDemoFixture.width, height: 48).fill()
                (String(format: "%02d", row + 1) as NSString).draw(at: CGPoint(x: 18, y: y + 12), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.darkGray])
                let issue = row == 2 || row == 19 ? "ABC-123" : row == 12 ? "XYZ-987" : nil
                let line = issue ?? "Owned entry \(row + 1) · Read the current long image"
                (line as NSString).draw(at: CGPoint(x: 64, y: y + (issue == nil ? 15 : 6)), withAttributes: [
                    .font: issue == nil ? NSFont.systemFont(ofSize: 17, weight: .medium)
                        : NSFont.monospacedSystemFont(ofSize: 32, weight: .medium), .foregroundColor: NSColor.black])
                // Deterministic row texture preserves matching across repeated
                // text without adding anything that could be a script target.
                for line in 0..<48 {
                    let shade = 0.35 + 0.22 * sin(Double(y + line) * 0.71 + Double(row) * 0.13)
                    NSColor(srgbRed: 0.18 + shade * 0.5, green: 0.35 + shade * 0.5, blue: 0.46 + shade * 0.4, alpha: 1).setFill()
                    NSRect(x: 552, y: y + line, width: 168, height: 1).fill()
                    NSColor(srgbRed: 0.12, green: 0.32, blue: 0.28, alpha: 1).setFill()
                    NSRect(x: 552, y: y + line, width: 33 + Int(25 * sin(Double(line) * 0.25 + Double(row))), height: 1).fill()
                }
            }
        }
    }

    private static func menuAction(_ controls: LiveScrollCaptureController, trace: Trace) throws {
        let id = "scroll.live.textScript"
        let toolbar = try unwrap(controls.toolbarWindow?.contentView as? LiveScrollToolbarView, "more-toolbar-missing")
        let menu = try unwrap(toolbar.moreButton.menu, "installed-more-menu-missing")
        let item = try unwrap(menu.items.first { $0.identifier?.rawValue == id }, "more-item-missing")
        try require(item.isEnabled && !item.isHidden, "more-item-unavailable")
        let action = try unwrap(item.action, "more-selector-missing")
        try require(NSApp.sendAction(action, to: item.target, from: item), "more-dispatch-failed")
        trace.record("more-open-choice", identifier: id, route: "NSApp.sendAction on production More menu item")
    }
    private static func buttonAction(_ button: NSButton, action: String, trace: Trace) throws {
        try PortableSettingsUIPreviewFixture.click(button)
        trace.record(action, identifier: button.identifier?.rawValue ?? "",
                     route: "PortableSettingsUIPreviewFixture.click: owned NSButton.mouseDown with queued mouseUp")
    }
    private static func evidence(_ window: NSWindow, phase: String, report: [String: Any], trace: Trace,
                                 directory: URL) throws -> [[String: Any]] {
        try persist(report, trace: trace, directory: directory)
        return try TextScriptUIPreviewFixture.capture(window, phase: "scroll-text-script-" + phase, directory: directory)
    }
    private static func enrich(_ report: inout [String: Any], trace: Trace) {
        report["actionTrace"] = trace.actions; report["attempts"] = trace.attempts
        report["generatedActualOCR"] = trace.ocrText; report["recognitionTruncated"] = trace.truncated
        report["ocrTextSHA256"] = hash(Data(trace.ocrText.utf8)); report["ocrTextBytes"] = trace.ocrText.utf8.count
        report["helperMetrics"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(trace.metrics))) ?? []
        report["requestID"] = trace.requestID?.uuidString ?? ""
        report["acceptedImageReference"] = trace.acceptedImageReference
        report["acceptedPNGFileSHA256"] = trace.acceptedPNGFileSHA256
        report["sourceImageComparison"] = trace.sourceImageComparison
        report["comparedBeforeOCR"] = trace.comparedBeforeOCR
        report["savedDefinitionFrozen"] = trace.definitionFrozen && trace.transformSourceFrozen
    }
    private static func persist(_ report: [String: Any], trace: Trace, directory: URL) throws {
        var value = report; enrich(&value, trace: trace)
        try write(value, to: directory.appendingPathComponent("scroll-text-script-case.json"))
        try write(["actionTrace": trace.actions, "failureReceipts": report["failureReceipts"] ?? [],
                   "receipts": report["receipts"] ?? []], to: directory.appendingPathComponent("scroll-text-script-actions.json"))
    }
    private static func directoryFacts(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            result[name] = hash(try Data(contentsOf: directory.appendingPathComponent(name)))
        }
        return result
    }
    private static func defaultsBytes(_ defaults: UserDefaults, suite: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: defaults.persistentDomain(forName: suite) ?? [:], options: [.sortedKeys])
    }
    private static func nativeImage(_ view: NSView) throws -> CGImage {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        try require(w > 0 && h > 0 && w <= 4_000_000 / h, "native-image-bound")
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32), "native-bitmap-missing")
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * h)
        bitmap.size = view.bounds.size
        let context = try unwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "native-context-missing")
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.white.cgColor); context.fill(view.bounds)
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let cached = bitmap.cgImage { context.draw(cached, in: view.bounds) }
        }
        return try unwrap(context.makeImage(), "native-image-missing")
    }
    private static func imageFacts(_ image: CGImage) throws -> [String: Any] {
        ["width": image.width, "height": image.height, "canonicalRGBAPixelSHA256": hash(try SaveWorkflowUIPreviewFixture.pixels(image))]
    }
    private static func comparison(_ image: CGImage, _ reference: CGImage) throws -> [String: Any] {
        let actual = try SaveWorkflowUIPreviewFixture.pixels(image), expected = try SaveWorkflowUIPreviewFixture.pixels(reference)
        let dimensions = image.width == reference.width && image.height == reference.height
        return ["passed": dimensions && actual == expected, "dimensionsMatch": dimensions,
            "exactCanonicalRGBAEquality": dimensions && actual == expected, "width": image.width, "height": image.height,
            "expectedWidth": reference.width, "expectedHeight": reference.height,
            "outputPixelSHA256": hash(actual), "sourcePixelSHA256": hash(expected),
            "method": "Independent ImageIO PNG decode followed by full canonical sRGB RGBA equality"]
    }
    private static func decode(_ url: URL) throws -> CGImage {
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "png-source-missing")
        return try unwrap(CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), "png-decode-failed")
    }
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let writer = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil), "png-destination-missing")
        CGImageDestinationAddImage(writer, image, nil)
        try require(CGImageDestinationFinalize(writer), "png-write-failed")
    }
    private static func control<T: NSView>(_ id: String, in window: NSWindow) throws -> T {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let matches = descendants(try unwrap(window.contentView, "control-root-missing")).filter { $0.identifier?.rawValue == id }
        try require(matches.count == 1, "control-census-mismatch")
        return try unwrap(matches.first as? T, "control-type-mismatch")
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static func until(_ code: String, seconds: TimeInterval, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() { try Task.checkCancellation(); try require(ProcessInfo.processInfo.systemUptime < deadline, code); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    private struct FixtureFailure: Error { let code: String }
    private static func fixedCode(_ error: Error) -> String { (error as? FixtureFailure)?.code ?? "owned-operation-failed" }
    private static func require(_ condition: Bool, _ code: String) throws { if !condition { throw FixtureFailure(code: code) } }
    private static func unwrap<T>(_ value: T?, _ code: String) throws -> T { guard let value else { throw FixtureFailure(code: code) }; return value }
}
