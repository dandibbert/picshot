import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore
import PicShotTextScriptProcess

/// Installed production path over fixture-owned pixels. No live capture, user
/// preferences, general pasteboard, network, runtime gate or transport fixture.
@MainActor enum TextScriptUIPreviewFixture {
    static let expected = "ABC-123\nXYZ-987"
    static let savedName = "提取工单编号 · " + String(repeating: "本机文字脚本", count: 8)
    static let savedSource = "const ids = text.match(/\\b[A-Z]{2,8}-\\d+\\b/g) || [];\nreturn [...new Set(ids)].join(\"\\n\");\n"
        + (1...24).map { "// Owned editor line \($0): " + String(repeating: "readable wrapped source ", count: 8) }.joined(separator: "\n")
    static let scope = "Installed saved editor and region/OCR/script/Copy owner; generated acquisition, actual Apple Vision and signed production helper, checked private clipboard"
    static let limitations = ["Generated acquisition does not prove desktop selection, ScreenCaptureKit or TCC",
        "First checked private clipboard write is deliberately rejected",
        "Native images cache owned content only; no desktop screenshot",
        "256 MiB child RSS is sampled, not a hard allocation cap; bounded weak-owner drainage is not a leak or original227 memory pass"]

    static func verify(evidenceDirectory directory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let files = FileManager.default, started = ProcessInfo.processInfo.systemUptime
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        var report: [String: Any] = ["schemaVersion": 1, "status": "running", "scope": scope,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "installerAcceptance": false, "original227MemoryAcceptance": false, "hardMemoryCapClaimed": false,
            "realScreenCaptureClaimed": false, "screenCaptureAPICalled": false, "permissionRequested": false,
            "networkUsed": false, "globalInputPosted": false, "userHistoryReadOrWritten": false,
            "standardDefaultsReadOrWritten": false, "generalPasteboardReadOrWritten": false,
            "runtimeGateBuild": false, "transportFixtureUsed": false, "limitations": limitations,
            "generatedExpectedOutput": expected, "productAppDelegateExercised": false,
            "realAppleVisionRan": false, "productionHelperRan": false]
        var root: URL?, cleanupSafe = true
        try write(report, to: directory.appendingPathComponent("text-script-demo.json"))
        do {
            try require(ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] != nil, "smoke-required")
            _ = try unwrap(NSScreen.main, "display-required")
            let idle = await RecognitionService.resourceSnapshot()
            try require(idle.activeJobs == 0 && idle.waitingJobs == 0 && !TextScriptProcessService.snapshot().occupied, "initial-boundary-busy")
            let owned = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-TextScript-" + UUID().uuidString)
            root = owned; report["canonicalPrivateTemporaryRoot"] = true
            NSApp.appearance = NSAppearance(named: .aqua)
            let image = try generatedImage()
            let sourceURL = directory.appendingPathComponent("text-script-source.png")
            try writePNG(image, to: sourceURL)
            report["sourceReference"] = try imageFacts(decode(sourceURL))
            let first = Probes()
            let success = await runCase(retry: true, sourceURL: sourceURL, root: owned, directory: directory, probes: first)
            report["copyRetry"] = success
            cleanupSafe = success["cleanupSafe"] as? Bool == true
            try await until("retry-owner-retained", seconds: 5) { first.allReleased }
            report["successOwnershipReleased"] = first.facts
            try write(report, to: directory.appendingPathComponent("text-script-demo.json"))
            if cleanupSafe {
                let second = Probes()
                let closed = await runCase(retry: false, sourceURL: sourceURL, root: owned, directory: directory, probes: second)
                report["closeAfterFailure"] = closed
                cleanupSafe = closed["cleanupSafe"] as? Bool == true
                try await until("close-owner-retained", seconds: 5) { second.allReleased }
                report["closeOwnershipReleased"] = second.facts
                report["ownershipReleased"] = first.allReleased && second.allReleased
                report["status"] = success["status"] as? String == "passed" && closed["status"] as? String == "passed" ? "passed" : "failed"
            } else { report["status"] = "failed" }
        } catch {
            report["status"] = "failed"; report["failureCode"] = fixedCode(error)
            cleanupSafe = false
        }
        if let root, cleanupSafe {
            do { try files.removeItem(at: root); report["privateTemporaryRootRemoved"] = !files.fileExists(atPath: root.path) }
            catch { report["status"] = "failed"; report["cleanupFailureCode"] = "private-root-removal-failed" }
        } else if root != nil { report["privateTemporaryRootRemoved"] = false }
        let cases = [report["copyRetry"], report["closeAfterFailure"]].compactMap { $0 as? [String: Any] }
        report["productAppDelegateExercised"] = cases.contains { $0["appInitialized"] as? Bool == true }
        report["realAppleVisionRan"] = cases.contains { ($0["attempts"] as? [String: Int])?["ocr"] == 1 }
        report["productionHelperRan"] = cases.contains { ($0["helperMetrics"] as? [[String: Any]])?.first?["outcome"] as? String == "succeeded" }
        let vision = await RecognitionService.resourceSnapshot()
        report["finalVisionActiveJobs"] = vision.activeJobs; report["finalVisionWaitingJobs"] = vision.waitingJobs
        report["finalHelperAdmissionOccupied"] = TextScriptProcessService.snapshot().occupied
        report["cleanupSafe"] = cleanupSafe && report["privateTemporaryRootRemoved"] as? Bool == true
            && vision.activeJobs == 0 && vision.waitingJobs == 0 && !TextScriptProcessService.snapshot().occupied
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        if report["cleanupSafe"] as? Bool != true { report["status"] = "failed" }
        try write(report, to: directory.appendingPathComponent("text-script-demo.json"))
        try require(report["status"] as? String == "passed", "installed-witness-failed-see-preserved-report")
        return report
    }

    private static func runCase(retry: Bool, sourceURL: URL, root: URL, directory: URL, probes: Probes) async -> [String: Any] {
        let name = retry ? "retry" : "close", suite = "PicShot-TextScript-" + UUID().uuidString
        let board = NSPasteboard(name: .init("PicShot-TextScript-" + UUID().uuidString)), trace = Trace()
        var report: [String: Any] = ["status": "running", "case": name,
            "actionRoute": "Owned native Save/Run/Retry/Close mouseDown with queued mouseUp; owned table nextEvent/sendEvent; native text insertion",
            "copyRejectionInjectedAtCheckedWriter": true, "appInitialized": false]
        var defaults: UserDefaults?, app: AppDelegate?, editor: TextScriptController?
        var progress: CaptureChainController?, runner: CaptureChainRunner?, runtime: CaptureChainTextRuntime?
        do {
            let owned = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
            let isolated = try unwrap(UserDefaults(suiteName: suite), "isolated-defaults-unavailable")
            defaults = isolated
            let scripts = try TextScriptStore(directory: owned.appendingPathComponent("scripts", isDirectory: true))
            let chains = try CaptureChainStore(directory: owned.appendingPathComponent("chains", isDirectory: true))
            let history = HistoryStore(directory: owned.appendingPathComponent("history", isDirectory: true),
                policy: RetentionPolicy(maxItems: 2, maxBytes: 8 * 1_024 * 1_024, maxDays: 1))
            let process = CaptureChainTextRuntime(onMetrics: { trace.metrics.append($0) })
            runtime = process; probes.runtime = process
            let owner = AppDelegate(history: history, isolatedDefaults: isolated, chainStore: chains,
                textScriptStore: scripts, textScriptDependencies: { definition in
                    try require(definition.name == savedName && definition.source == savedSource, "saved-definition-mismatch")
                    return .init(capture: {
                        trace.captures += 1
                        trace.editorHidden = probes.editor?.window?.isVisible == false
                        trace.progressHidden = probes.app?.captureChainManagerForVerification?.window?.isVisible == false
                        trace.historyHidden = probes.app?.mainWindow?.isVisible == false
                        let selected = try decode(sourceURL); probes.image = selected
                        return try ChainCapture(image: selected, capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
                    }, recognize: { image in
                        trace.ocr += 1
                        let value = try await RecognitionService.recognize(image, options: RecognitionOptions(language: "en-US"))
                        // Only generated fixture pixels can enter this closure.
                        trace.ocrText = value.text; trace.truncated = value.document?.isTruncated == true
                        return ChainTextRecognition(text: value.text, truncated: trace.truncated)
                    }, transform: { source, text, id in
                        trace.transforms += 1; trace.requestID = id
                        return await process.transform(source: source, text: text, requestID: id)
                    }, copy: { text in
                        trace.copies += 1
                        try require(text == expected, "generated-output-mismatch")
                        if trace.copies == 1 { try CheckedTextClipboard.copy(text, pasteboard: board, writer: { _, _ in false }) }
                        else { try CheckedTextClipboard.copy(text, pasteboard: board); trace.commits += 1 }
                    }, cleanupComplete: { process.cleanupComplete(requestID: $0) })
                })
            app = owner; probes.app = owner; report["appInitialized"] = true
            owner.setupWindow()
            NotificationCenter.default.addObserver(owner, selector: #selector(AppDelegate.windowClosed(_:)),
                name: NSWindow.willCloseNotification, object: nil)
            owner.manageTextScripts()
            let manager = try unwrap(owner.textScriptManagerForVerification, "editor-missing")
            editor = manager; probes.editor = manager
            let window = try unwrap(manager.window, "editor-window-missing")
            window.makeKeyAndOrderFront(nil)
            let create: NSButton = try control("text-script-create", in: window)
            try PortableSettingsUIPreviewFixture.click(create)
            let field: NSTextField = try control("text-script-name", in: window)
            try require(window.makeFirstResponder(field), "name-focus-failed")
            let fieldEditor = try unwrap(window.fieldEditor(true, for: field) as? NSTextView, "name-field-editor-missing")
            fieldEditor.insertText(savedName, replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
            window.makeFirstResponder(nil)
            let source: NSTextView = try control("text-script-source", in: window)
            try require(window.makeFirstResponder(source), "source-focus-failed")
            source.insertText(savedSource, replacementRange: NSRange(location: 0, length: source.string.utf16.count))
            window.makeFirstResponder(nil)
            try require(field.stringValue == savedName && source.string == savedSource && scripts.definitions.isEmpty, "native-draft-mismatch")
            let save: NSButton = try control("text-script-save", in: window)
            try PortableSettingsUIPreviewFixture.click(save)
            try await until("save-not-persisted", seconds: 5) { scripts.definitions.count == 1 }
            let definition = try unwrap(scripts.definitions.first, "saved-definition-missing")
            let table: NSTableView = try control("text-script-list", in: window)
            report["rowSelection"] = try PortableSettingsUIPreviewFixture.clickRow(0, in: table, failureEvidenceDirectory: directory)
            let reload = try TextScriptStore(directory: scripts.directory)
            try require(reload.definitions == [definition] && reload.selectedID == definition.id
                && definition.name == savedName && definition.source == savedSource, "disk-roundtrip-mismatch")
            report["nativeSaveControlIdentifier"] = "text-script-save"
            report["nativeSourceInsertion"] = true; report["savedDefinitionReloaded"] = true
            report["definitionID"] = definition.id.uuidString
            let catalogURL = scripts.directory.appendingPathComponent(TextScriptStore.manifestFilename)
            let before = try Data(contentsOf: catalogURL)
            report["catalogBeforeSHA256"] = hash(before)
            try before.write(to: directory.appendingPathComponent("text-script-" + name + "-catalog.json"), options: .atomic)
            if retry { report["editorArtifacts"] = try capture(window, phase: "text-script-editor", directory: directory) }
            let run: NSButton = try control("text-script-run", in: window)
            try PortableSettingsUIPreviewFixture.click(run)
            report["runControlIdentifier"] = "text-script-run"
            try await until("copy-failure-not-reached", seconds: 25) { owner.activeCaptureChain?.status.canRetry == true }
            let active = try unwrap(owner.activeCaptureChain, "active-run-missing")
            runner = active; probes.runner = active
            let receiptWindow = try unwrap(owner.captureChainManagerForVerification, "progress-missing")
            progress = receiptWindow; probes.progress = receiptWindow
            let progressWindow = try unwrap(receiptWindow.window, "progress-window-missing")
            try require(active.status == .textFailed(.copy, .clipboardRejected), "failure-not-fixed-copy-rejection")
            try require(active.snapshot.textReceipt == nil && active.receipts.isEmpty
                && active.capture == nil && active.retainedTextBytes == expected.utf8.count,
                "failure-retained-wrong-payload")
            try require(trace.captures == 1 && trace.ocr == 1 && trace.transforms == 1 && trace.copies == 1
                && trace.commits == 0 && trace.metrics.count == 1 && !trace.truncated, "first-attempt-counts")
            try require(board.string(forType: .string) == nil, "rejected-copy-published-text")
            report["failureCode"] = "clipboardRejected"; report["failurePhase"] = "copy"
            report["failureAttempts"] = trace.attempts
            report["failedRetainedTextBytes"] = active.retainedTextBytes
            report["failedImageReleased"] = active.capture == nil && probes.image == nil
            report["failureReceiptCount"] = 0; report["rejectedPasteboardEmpty"] = true
            report["failureArtifacts"] = try capture(progressWindow, phase: "text-script-" + name + "-failure", directory: directory)
            try write(report, to: directory.appendingPathComponent("text-script-" + name + "-case.json"))
            if retry {
                let retryButton: NSButton = try control("capture-chain-retry", in: progressWindow)
                try PortableSettingsUIPreviewFixture.click(retryButton)
                report["retryControlIdentifier"] = "capture-chain-retry"
                try await until("copy-retry-not-completed", seconds: 10) {
                    owner.activeCaptureChain == nil && receiptWindow.displayedSnapshot?.status == .completed
                }
                let completed = try unwrap(receiptWindow.displayedSnapshot, "completed-snapshot-missing")
                let actual = try unwrap(board.string(forType: .string), "checked-copy-missing")
                try require(actual == expected && completed.textReceipt?.characterCount == expected.count
                    && completed.receipts.isEmpty && completed.retainedBytes == 0 && completed.retainedTextBytes == 0,
                    "completed-copy-receipt-mismatch")
                report["generatedActualOutput"] = actual; report["receiptCharacterCount"] = completed.textReceipt?.characterCount
                report["committedReceiptCount"] = 1
                let bytes = Data(actual.utf8)
                try bytes.write(to: directory.appendingPathComponent("text-script-copied.txt"), options: .atomic)
                report["copiedTextSHA256"] = hash(bytes); report["copiedTextBytes"] = bytes.count
                report["resultArtifacts"] = try capture(progressWindow, phase: "text-script-result", directory: directory)
            }
            let close: NSButton = try control("capture-chain-close", in: progressWindow)
            try PortableSettingsUIPreviewFixture.click(close)
            report["closeControlIdentifier"] = "capture-chain-close"
            try await until("close-not-retired", seconds: 5) { owner.activeCaptureChain == nil && !progressWindow.isVisible }
            if !retry {
                try require(active.status == .cancelled && active.textReceipt == nil && board.string(forType: .string) == nil,
                    "close-committed-unfinished-copy")
                report["committedReceiptCount"] = 0; report["privatePasteboardEmptyAfterClose"] = true
            }
            try require(active.retainedBytes == 0 && active.retainedTextBytes == 0 && active.capture == nil
                && !active.isAttemptRunning, "terminal-payload-retained")
            let after = try Data(contentsOf: catalogURL)
            report["catalogAfterSHA256"] = hash(after)
            let names = try FileManager.default.contentsOfDirectory(atPath: scripts.directory.path)
            report["catalogDefinitionsOnly"] = before == after && names == [TextScriptStore.manifestFilename]
            try require(report["catalogDefinitionsOnly"] as? Bool == true, "catalog-mutated-by-run")
            try require(trace.captures == 1 && trace.ocr == 1 && trace.transforms == 1 && trace.copies == (retry ? 2 : 1)
                && trace.commits == (retry ? 1 : 0), "retry-repeated-completed-phase")
            try require(trace.editorHidden && trace.progressHidden && trace.historyHidden, "capture-ui-visible")
            try require(history.records.isEmpty && owner.pins.isEmpty && owner.pinSession == nil
                && !owner.controllers.contains(where: { $0 is ImageEditorController }), "unrelated-output-created")
            report["editorHiddenDuringCapture"] = trace.editorHidden
            report["progressHiddenDuringCapture"] = trace.progressHidden
            report["historyHiddenDuringCapture"] = trace.historyHidden
            report["noEditorHistoryOrPinOutput"] = true
            report["finalRetainedBytes"] = active.retainedBytes; report["finalRetainedTextBytes"] = active.retainedTextBytes
            report["terminalStatus"] = retry ? "completed" : "cancelled"
            manager.present()
            let closeEditor: NSButton = try control("text-script-close", in: window)
            try PortableSettingsUIPreviewFixture.click(closeEditor)
            try require(!window.isVisible, "editor-close-failed")
            report["editorCloseControlIdentifier"] = "text-script-close"
            report["status"] = "passed"
        } catch { report["status"] = "failed"; report["fixtureFailureCode"] = fixedCode(error) }
        app?.activeCaptureChain?.cancel()
        do { try await until("owner-drain-timeout", seconds: 5) { app?.activeCaptureChain == nil && !TextScriptProcessService.snapshot().occupied } }
        catch { report["status"] = "failed"; report["cleanupFailureCode"] = "owner-drain-timeout" }
        let vision = await RecognitionService.resourceSnapshot()
        let drained = app?.activeCaptureChain == nil && !TextScriptProcessService.snapshot().occupied
            && vision.activeJobs == 0 && vision.waitingJobs == 0
        progress?.close(); editor?.close()
        if let app {
            NotificationCenter.default.removeObserver(app, name: NSWindow.willCloseNotification, object: nil)
            app.mainWindow?.contentView = nil; app.mainWindow?.close(); app.controllers.removeAll()
        }
        runner = nil; progress = nil; editor = nil; app = nil; runtime = nil
        board.releaseGlobally()
        if drained { defaults?.removePersistentDomain(forName: suite) }
        report["attempts"] = trace.attempts
        report["generatedActualOCR"] = String(trace.ocrText.prefix(4096))
        report["recognitionTruncated"] = trace.truncated
        report["helperMetrics"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(trace.metrics))) ?? []
        report["requestID"] = trace.requestID?.uuidString ?? ""
        report["cleanupSafe"] = drained; report["visionJobsDrained"] = vision.activeJobs == 0 && vision.waitingJobs == 0
        report["helperAdmissionDrained"] = !TextScriptProcessService.snapshot().occupied
        report["privatePasteboardReleased"] = true; report["isolatedDefaultsRemoved"] = drained
        if !drained { report["status"] = "failed" }
        try? write(report, to: directory.appendingPathComponent("text-script-" + name + "-case.json"))
        return report
    }

    private final class Trace {
        var captures = 0, ocr = 0, transforms = 0, copies = 0, commits = 0
        var editorHidden = false, progressHidden = false, historyHidden = false, truncated = false
        var ocrText = "", metrics: [TextScriptProcessMetrics] = [], requestID: UUID?
        var attempts: [String: Int] { ["capture": captures, "ocr": ocr, "transform": transforms, "copy": copies, "committedCopy": commits] }
    }
    private final class Probes {
        weak var app: AppDelegate?, editor: TextScriptController?, progress: CaptureChainController?
        weak var runner: CaptureChainRunner?, image: CGImage?, runtime: CaptureChainTextRuntime?
        var facts: [String: Bool] { ["app": app == nil, "editor": editor == nil, "progress": progress == nil,
            "runner": runner == nil, "selectedImage": image == nil, "runtime": runtime == nil] }
        var allReleased: Bool { facts.values.allSatisfy { $0 } }
    }

    private static func generatedImage() throws -> CGImage {
        let view = IssueDocument(frame: CGRect(x: 0, y: 0, width: 900, height: 300))
        view.appearance = NSAppearance(named: .aqua)
        return try nativeImage(view)
    }
    private final class IssueDocument: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); bounds.fill()
            for (index, line) in ["ABC-123", "XYZ-987", "ABC-123"].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 48, y: 24 + index * 88), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 48, weight: .medium), .foregroundColor: NSColor.black])
            }
        }
    }

    /// Every owned control is measured, including native descendants; source
    /// text retains its complete document with a bounded, wrapping viewport.
    static func capture(_ window: NSWindow, phase: String, directory: URL) throws -> [[String: Any]] {
        let previous = window.appearance
        defer { window.appearance = previous }
        var artifacts: [[String: Any]] = []
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let root = try unwrap(window.contentView, "snapshot-content-missing")
            descendants(root).forEach { $0.needsDisplay = true }
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let image = try nativeImage(root, window: window), filename = phase + "-" + mode + ".png"
            try writePNG(image, to: directory.appendingPathComponent(filename))
            var artifact = try imageFacts(image)
            artifact["filename"] = filename; artifact["appearance"] = mode
            artifact["layout"] = try layout(window, phase: phase)
            try write(artifact, to: directory.appendingPathComponent(phase + "-" + mode + "-layout.json"))
            artifacts.append(artifact)
        }
        try require(artifacts.allSatisfy { ($0["layout"] as? [String: Any])?["passed"] as? Bool == true }, "native-layout-failed")
        try require(artifacts.first?["canonicalRGBAPixelSHA256"] as? String != artifacts.last?["canonicalRGBAPixelSHA256"] as? String,
            "native-appearances-identical")
        return artifacts
    }

    private static func layout(_ window: NSWindow, phase: String) throws -> [String: Any] {
        let root = try unwrap(window.contentView, "layout-content-missing")
        var paths: [ObjectIdentifier: [Int]] = [:]
        func visit(_ view: NSView, _ path: [Int]) {
            paths[ObjectIdentifier(view)] = path
            for (i, child) in view.subviews.enumerated() { visit(child, path + [i]) }
        }
        visit(root, [])
        let views = descendants(root).filter { $0 is NSControl || $0.identifier?.rawValue == "text-script-source" }
        let ids = Dictionary(uniqueKeysWithValues: views.enumerated().map { (ObjectIdentifier($0.element), $0.element.identifier?.rawValue ?? "native-\($0.offset)") })
        var rows: [[String: Any]] = [], violations: [String] = [], leaves: [(NSView, CGRect)] = []
        let screen = window.screen?.visibleFrame ?? .zero
        if !screen.insetBy(dx: -0.5, dy: -0.5).contains(window.frame) { violations.append("window-offscreen") }
        for view in views {
            let id = ids[ObjectIdentifier(view)]!, frame = view.convert(view.bounds, to: root)
            let button = view as? NSButton, field = view as? NSTextField, textView = view as? NSTextView
            let control = view as? NSControl
            var ancestors: [String] = [], parent = view.superview, inViewport = true
            while let value = parent {
                if let ancestor = ids[ObjectIdentifier(value)] { ancestors.append(ancestor) }
                if let clip = value as? NSClipView,
                   !clip.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.convert(view.bounds, to: clip)) { inViewport = false }
                parent = value.superview
            }
            var row: [String: Any] = ["id": id, "class": String(describing: type(of: view)),
                "kind": button != nil ? "button" : field != nil ? "field" : textView != nil ? "source" : view is NSTableView ? "table" : "other",
                "viewPath": paths[ObjectIdentifier(view)] ?? [], "ancestorIDs": ancestors,
                "ownerWindowNumber": view.window?.windowNumber ?? -1,
                "owned": view.isDescendant(of: root) && view.window === window,
                "fullFrame": rect(frame), "screenFrame": rect(window.convertToScreen(view.convert(view.bounds, to: nil))),
                "hidden": view.isHiddenOrHasHiddenAncestor, "enabled": control?.isEnabled ?? textView?.isEditable ?? false,
                "insideViewport": inViewport]
            let text = button?.title ?? field?.stringValue ?? textView?.string ?? ""
            row["text"] = text; row["tooltip"] = view.toolTip ?? ""
            row["accessibilityValue"] = view.accessibilityValue() as? String ?? ""
            row["accessibilityLabel"] = view.accessibilityLabel() ?? ""
            if !view.isHiddenOrHasHiddenAncestor && inViewport && (button != nil || field != nil) {
                let contained = root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
                row["contained"] = contained
                if !contained { violations.append(id + ":clipped") }
                let size = control?.cell?.cellSize ?? .zero
                let wrapped = control?.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: view.bounds.width, height: 10_000)) ?? .zero
                row["cellSize"] = [size.width, size.height]; row["wrappedSize"] = [wrapped.width, wrapped.height]
                if let button {
                    let hit = root.hitTest(root.convert(CGPoint(x: frame.midX, y: frame.midY), to: root.superview))
                    let hitOK = hit === button || hit?.isDescendant(of: button) == true
                    let fits = frame.width + 0.5 >= size.width && frame.height + 0.5 >= size.height
                    row["hitTest"] = hitOK; row["textFits"] = fits
                    if !hitOK || !fits { violations.append(id + ":button-fit") }
                } else if let field {
                    let wraps = field.cell?.wraps == true
                    let fits = wrapped.height <= frame.height + 0.5 && (wraps || size.width <= frame.width + 0.5)
                    let editable = field.isEditable && field.isSelectable && field.cell?.isScrollable == true
                    let alignment = field.alignmentRect(forFrame: field.bounds)
                    let nameAlternative = id == "text-script-name" && editable && alignment.width >= 320
                        && wrapped.height <= frame.height + 0.5 && field.toolTip == text && field.accessibilityValue() as? String == text
                    let truncates = [NSLineBreakMode.byTruncatingHead, .byTruncatingTail, .byTruncatingMiddle].contains(field.lineBreakMode)
                    let accessible = field.toolTip == text && (field.accessibilityValue() as? String == text || field.accessibilityLabel() == text)
                    row["textFits"] = fits; row["wraps"] = wraps; row["editableScrollable"] = editable
                    row["alignmentWidth"] = alignment.width; row["nameAlternative"] = nameAlternative
                    row["truncates"] = truncates; row["accessibleAlternative"] = accessible
                    row["fontSize"] = field.font?.pointSize ?? 0
                    if (field.font?.pointSize ?? 0) < 11 || (!text.isEmpty && !fits && !nameAlternative && !(truncates && accessible)) {
                        violations.append(id + ":field-fit")
                    }
                }
                leaves.append((view, frame))
            }
            if let textView, !view.isHiddenOrHasHiddenAncestor {
                let scroll = try unwrap(textView.enclosingScrollView, "source-scroll-missing")
                let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: root)
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)
                let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
                row["viewport"] = rect(viewport); row["usedTextRect"] = rect(used)
                row["textContainerWidth"] = textView.textContainer?.containerSize.width ?? 0
                row["textInset"] = [textView.textContainerInset.width, textView.textContainerInset.height]
                row["wraps"] = textView.textContainer?.widthTracksTextView == true && !textView.isHorizontallyResizable
                row["verticalScroll"] = scroll.hasVerticalScroller
                row["editableSelectable"] = textView.isEditable && textView.isSelectable
                row["fontSize"] = textView.font?.pointSize ?? 0
                row["completeSourceAccessible"] = textView.accessibilityValue() as? String == text
                if viewport.width < 320 || viewport.height < 120 || !root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(viewport)
                    || row["wraps"] as? Bool != true || !scroll.hasVerticalScroller
                    || used.width > (textView.textContainer?.containerSize.width ?? 0) + 0.5
                    || row["completeSourceAccessible"] as? Bool != true { violations.append(id + ":source-viewport") }
                leaves.append((view, viewport))
            }
            rows.append(row)
        }
        for i in leaves.indices { for j in 0..<i {
            if leaves[i].0.isDescendant(of: leaves[j].0) || leaves[j].0.isDescendant(of: leaves[i].0) { continue }
            let overlap = leaves[i].1.intersection(leaves[j].1)
            if !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5 { violations.append("independent-control-overlap") }
        } }
        return ["phase": phase, "passed": violations.isEmpty, "windowVisible": window.isVisible,
            "windowNumber": window.windowNumber, "windowFrame": rect(window.frame), "screenFrame": rect(screen),
            "contentBounds": rect(root.bounds), "controls": rows, "violations": violations,
            "fullNativeFramesMeasured": true, "alignmentRectanglesSubstituted": false]
    }
    private static func nativeImage(_ view: NSView, window: NSWindow? = nil) throws -> CGImage {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        try require(width > 0 && height > 0 && width <= 4_000_000 / height, "raster-bound")
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "bitmap-unavailable")
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * height); bitmap.size = view.bounds.size
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "context-unavailable")
        (window?.effectiveAppearance ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
            context.setFillColor((window?.backgroundColor ?? NSColor.white).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let image = bitmap.cgImage { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        return try unwrap(context.makeImage(), "image-unavailable")
    }
    private static func imageFacts(_ image: CGImage) throws -> [String: Any] {
        ["width": image.width, "height": image.height, "canonicalRGBAPixelSHA256": hash(try SaveWorkflowUIPreviewFixture.pixels(image))]
    }
    private static func decode(_ url: URL) throws -> CGImage {
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "source-unavailable")
        return try unwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), "decode-failed")
    }
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let writer = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil), "png-unavailable")
        CGImageDestinationAddImage(writer, image, nil); try require(CGImageDestinationFinalize(writer), "png-failed")
    }
    private static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    private static func control<T: NSView>(_ id: String, in window: NSWindow) throws -> T {
        let values = descendants(try unwrap(window.contentView, "control-root-missing")).filter { $0.identifier?.rawValue == id }
        try require(values.count == 1, "control-census-mismatch")
        return try unwrap(values.first as? T, "control-type-mismatch")
    }
    private static func rect(_ r: CGRect) -> [String: CGFloat] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
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
