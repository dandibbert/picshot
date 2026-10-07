import AppKit
import PicShotCore

/// Opt-in installed-app acceptance. All pixels are locally authored; no screen capture,
/// global input, permission requests, network, or writes to the general pasteboard.
/// The race phase is deliberately gated and is never counted as Apple Vision work.
@MainActor enum PinOCRWorkflowSmokeFixture {
    static let overallDeadlineSeconds: Double = 240
    static let warmupCycles = 2
    static let measuredCycles = 12

    static func verify(evidenceDirectory: URL, includeResourceCycles: Bool = true) async throws -> [String: Any] {
        _ = NSApplication.shared
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + overallDeadlineSeconds
        let files = FileManager.default
        try require(evidenceDirectory.isFileURL, "Evidence directory must be local")
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let directory = files.temporaryDirectory.appendingPathComponent("PicShot-OCRWorkflow-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let suite = "PicShot-OCRWorkflow-" + UUID().uuidString
        let defaults = try required(UserDefaults(suiteName: suite), "Private defaults unavailable")
        defer { defaults.removePersistentDomain(forName: suite); try? files.removeItem(at: directory) }
        defaults.set(true, forKey: TextResultController.directCopyPreferenceKey)
        defaults.set(true, forKey: PinOCRPreferences.automaticPreferenceKey)
        let generalCount = NSPasteboard.general.changeCount
        let clipboard = NSPasteboard.withUniqueName()
        clipboard.setString("OCR acceptance private clipboard sentinel", forType: .string)
        defer { clipboard.releaseGlobally() }
        let idle = await RecognitionService.resourceSnapshot()
        try require(idle.activeJobs == 0 && idle.waitingJobs == 0, "Fixture requires an idle Vision boundary")
        let raster = try PinTextSelectionSmokeFixture.visionRaster()
        try raster.writePNG(to: evidenceDirectory.appendingPathComponent("pin-ocr-workflow-input.png"))
        let focus = try PinOCRFocusSentinel()
        defer { focus.close() }
        let functional = try await verifyControls(raster: raster, defaults: defaults, clipboard: clipboard,
            focus: focus, evidenceDirectory: evidenceDirectory, deadline: deadline)
        // Source-link/edit/layout/code-exclusion checks receive the exact actual Vision result.
        let sourceLinks = try OCRSourceLinkAcceptanceFixture.verify(result: functional.result, sourceImage: raster,
            evidenceDirectory: evidenceDirectory)
        focus.activate()
        let restoration = try await verifyRestoration(raster: raster, result: functional.result, defaults: defaults,
            clipboard: clipboard, focus: focus, directory: directory.appendingPathComponent("session"), deadline: deadline)
        let resources: [String: Any]
        if includeResourceCycles {
            resources = try await verifyResources(raster: raster, defaults: defaults, deadline: deadline)
        } else {
            resources = ["status": "not-run", "reason": "includeResourceCycles=false; early native pixels only",
                         "warmupCycles": 0, "completedMeasuredCycles": 0, "actualVisionCalls": 0]
        }
        let finalJobs = await RecognitionService.resourceSnapshot()
        try require(finalJobs.activeJobs == 0 && finalJobs.waitingJobs == 0, "Vision jobs remain at final boundary")
        try require(NSPasteboard.general.changeCount == generalCount, "General clipboard changed")
        try files.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        let cleaned = !files.fileExists(atPath: directory.path)
        try require(cleaned && (defaults.persistentDomain(forName: suite)?.isEmpty ?? true), "Private fixture state remains")
        try checkDeadline(deadline)
        let report: [String: Any] = [
            "status": "passed", "schemaVersion": 1,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundlePath,
            "includeResourceCycles": includeResourceCycles, "overallDeadlineSeconds": overallDeadlineSeconds,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "realAppleVisionRan": true, "actualFunctionalVisionCalls": functional.actualCalls,
            "actualResourceVisionCalls": includeResourceCycles ? warmupCycles + measuredCycles : 0,
            "visionSource": "PinTextSelectionSmokeFixture.visionRaster(): authored CoreText raster, 1000x320",
            "visionRecognizedText": functional.result.text, "controls": functional.report,
            "sourceLinkAcceptance": sourceLinks, "coordinatorRestoration": restoration, "resourceEvidence": resources,
            "limits": limits, "finalVisionActiveJobs": finalJobs.activeJobs, "finalVisionWaitingJobs": finalJobs.waitingJobs,
            "temporaryDirectoryRemoved": cleaned, "privateDefaultsRemoved": true,
            "standardUserDefaultsChanged": false, "generalPasteboardChanged": false, "privatePasteboardCopyVerified": true,
            "screenCaptureStarted": false, "permissionRequests": false, "networkUsed": false, "globalInputPosted": false,
            "physicalRetinaVerified": false, "externalApplicationVerified": false, "tccAcceptanceVerified": false,
            "evidenceFiles": ["pin-ocr-workflow-input.png", "pin-ocr-automatic-light.png", "pin-ocr-automatic-dark.png",
                              "pin-ocr-compact-light.png", "pin-ocr-compact-dark.png", "ocr-source-linked-result.png"],
            "snapshotBackground": PinWorkflowSnapshot.backgroundDescription,
            "scope": "Actual local Apple Vision plus native controls over authored pixels; gated races are separately labeled. No physical Retina, external-app interaction, TCC, OCR accuracy across arbitrary inputs, plateau, or zero-leak claim."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("pin-ocr-workflow.json"), options: .atomic)
        return report
    }

    private static var limits: [String: Any] {
        ["frontActiveJobs": PinOCRScheduler.maximumActiveJobs, "frontAutomaticJobs": PinOCRScheduler.maximumAutomaticJobs,
         "frontWaitingSessions": PinOCRScheduler.maximumWaitingSessions, "visionActiveJobs": 2, "visionWaitingJobs": 4,
         "livePins": PinSessionCoordinator.maximumLivePins, "resourceWarmupCycles": warmupCycles,
         "resourceMeasuredCycles": measuredCycles, "overallDeadlineSeconds": overallDeadlineSeconds]
    }

    private static func verifyControls(raster: CGImage, defaults: UserDefaults, clipboard: NSPasteboard,
        focus: PinOCRFocusSentinel, evidenceDirectory: URL, deadline: Double) async throws
        -> (result: RecognitionResult, actualCalls: Int, report: [String: Any]) {
        let scheduler = PinOCRScheduler(), calls = PinOCRVisionCallCounter()
        var provider: PinOCRActualVisionProvider? = PinOCRActualVisionProvider(calls: calls)
        var pin: PinController? = makePin(raster: raster, provider: provider!, scheduler: scheduler, defaults: defaults)
        let probe = PinOCRWorkflowReleaseProbe(pin!, provider: provider!)
        defer { pin?.close() }
        let privateCount = clipboard.changeCount, generalCount = NSPasteboard.general.changeCount
        try perform("自动识别贴图文字", in: try recognitionMenu(pin!))
        try require(pin!.automaticOCREnabled && defaults.bool(forKey: TextResultController.directCopyPreferenceKey),
                    "Automatic/direct-copy fixture setup failed")
        focus.activate()
        pin!.showWindow(nil)
        weak var initialPinResponder = pin!.window?.firstResponder
        try await waitUntil(deadline: deadline, detail: "Actual automatic Vision completion", scheduler: scheduler,
            invariant: { try focus.verify(); try require(pin?.recognitionWindow == nil, "Automatic OCR opened a result") }) {
                pin?.ocrSession.state == .ready && pin?.textSelectionOverlay.document != nil
            }
        let result = try required(pin!.ocrSession.cachedResult, "Automatic result missing")
        let document = try required(result.document, "Actual Vision geometry missing")
        try require(document.units.count >= 3 && result.text.lowercased().contains("capture"), "Vision did not read authored text")
        try require(pin!.window?.firstResponder === initialPinResponder, "Automatic completion changed pin first responder")
        try require(NSPasteboard.general.changeCount == generalCount && clipboard.changeCount == privateCount,
                    "Automatic completion copied despite being background work")
        try require(calls.snapshot.started == 1 && calls.snapshot.completed == 1 && pin!.ocrSourceReadCount == 1,
                    "Automatic completion used more than one real recognition/source read")
        try renderAutomaticPreviews(pin!, evidenceDirectory: evidenceDirectory)
        try focus.verify()
        // Explicit private copy uses the production copy-all path; never send this action to .general.
        pin!.copyAllRecognizedText(to: clipboard)
        try await waitUntil(deadline: deadline, detail: "Private copy-all", scheduler: scheduler) {
            clipboard.string(forType: .string) == result.displayText
        }
        try perform("下次直接复制文本", in: try recognitionMenu(pin!))
        try require(!defaults.bool(forKey: TextResultController.directCopyPreferenceKey), "Private direct-copy menu did not toggle")
        pin!.setTextSelectionEnabled(false)
        try perform("选择图片文字", in: try recognitionMenu(pin!))
        try require(pin!.textSelectionOverlay.document == document, "Explicit selection did not reuse automatic cache")
        try perform("识别文字…", in: try recognitionMenu(pin!))
        try await waitUntil(deadline: deadline, detail: "Cached compact result", scheduler: scheduler) { pin?.recognitionWindow != nil }
        probe.observeResult(pin!.recognitionWindow)
        try verifyPinLinks(pin!, document: document)
        try require(calls.snapshot.started == 1 && scheduler.resourceSnapshot.admittedJobs == 1 && pin!.ocrSourceReadCount == 1,
                    "Selection/copy/result reuse performed extra recognition")
        try renderResultPreviews(pin!, evidenceDirectory: evidenceDirectory)
        var languageReport: [String: Any] = ["status": "unavailable", "actualVisionRan": false]
        let supportsEnglish = try RecognitionService.supportedLanguages().contains("en-US")
        if supportsEnglish {
            let panel = try required(pin!.recognitionWindow, "Language result window missing")
            try require(panel.offersLanguageSelection, "Supported language picker was hidden")
            let root = try required(panel.window?.contentView, "Language result content missing")
            let picker = try required(descendants(root).compactMap({ $0 as? NSPopUpButton })
                .first(where: { $0.toolTip?.contains("语言") == true }), "Native language picker missing")
            let nativeText = try required(descendants(root).compactMap({ $0 as? NSTextView }).first, "Native result editor missing")
            let english = try required(picker.itemArray.first(where: { ($0.representedObject as? String) == "en-US" }),
                "Supported English language missing from native picker")
            picker.select(english)
            let action = try required(picker.action, "Language action missing")
            try require(NSApp.sendAction(action, to: picker.target, from: picker), "Language control did not dispatch")
            try await waitUntil(deadline: deadline, detail: "Actual English language rerun", scheduler: scheduler) {
                pin?.ocrSession.key.options.language == "en-US" && pin?.ocrSession.state == .ready &&
                    pin?.recognitionWindow?.resultDocument == pin?.ocrSession.cachedResult?.document &&
                    calls.snapshot.completed == 2 && nativeText.isEditable
            }
            try require(calls.snapshot.started == 2 && calls.snapshot.languages == [nil, "en-US"], "Language control bypassed shared session")
            try verifyPinLinks(pin!, document: try required(pin!.ocrSession.cachedResult?.document, "Rerun geometry missing"))
            let beforeRerunCopy = clipboard.changeCount
            pin!.copyAllRecognizedText(to: clipboard)
            try await waitUntil(deadline: deadline, detail: "Rerun cached copy", scheduler: scheduler) {
                clipboard.changeCount > beforeRerunCopy && clipboard.string(forType: .string) == pin?.ocrSession.cachedResult?.displayText
            }
            try require(calls.snapshot.started == 2 && pin!.ocrSourceReadCount == 2, "Rerun copy did extra recognition")
            languageReport = ["status": "passed", "language": "en-US", "actualVisionRan": true, "nativePopupAction": true]
        } else {
            languageReport["reason"] = "RecognitionService.supportedLanguages() did not contain en-US on this macOS"
        }
        languageReport["supportedEnglish"] = supportsEnglish
        pin!.close(); pin = nil; provider = nil
        try await released([probe], scheduler: scheduler, deadline: deadline)
        try require(NSPasteboard.general.changeCount == generalCount, "Functional controls changed general clipboard")
        return (result, calls.snapshot.started,
            ["status": "passed", "automaticWithDirectCopyEnabled": true, "sentinelKeyAndFirstResponderPreserved": true,
             "automaticResultOpened": false, "automaticPasteboardChanged": false, "cachedConsumers": ["selection", "copy-all", "result"],
             "bidirectionalPinResultLinks": true, "languageRerun": languageReport, "actualVisionCalls": calls.snapshot.started,
             "sourceReadCount": calls.snapshot.started, "releaseProbeCount": 1, "retainedObjects": probe.retainedCount,
             "releaseEvidence": releaseObject([probe])])
    }

    private static func verifyPinLinks(_ pin: PinController, document: RecognizedTextDocument) throws {
        let panel = try required(pin.recognitionWindow, "Linked result missing")
        let first = try required(document.units.first, "First OCR source unit missing")
        let last = try required(document.units.last, "Last OCR source unit missing")
        let root = try required(panel.window?.contentView, "Result content missing")
        let text = try required(descendants(root).compactMap { $0 as? NSTextView }.first, "Editable result missing")
        try require(panel.resultDocument == document && !panel.isSourcePreviewVisible, "Result is not the compact exact document")
        text.setSelectedRange(first.range)
        panel.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: text))
        try require(pin.textSelectionOverlay.linkedSelectionRanges == [first.range], "Result selection did not link to pin")
        pin.textSelectionOverlay.select(last.range)
        try require(text.selectedRange() == last.range && panel.selectedSourceRanges == [last.range], "Pin selection did not link to result")
    }

    private static func renderAutomaticPreviews(_ pin: PinController, evidenceDirectory: URL) throws {
        let originalAppearance = pin.window?.appearance
        defer { pin.window?.appearance = originalAppearance }
        for (label, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            pin.window?.appearance = try required(NSAppearance(named: name), "Native appearance unavailable")
            let source = try required(pin.window?.contentView, "Pin preview missing")
            try PinWorkflowSnapshot.write(source, to: evidenceDirectory.appendingPathComponent("pin-ocr-automatic-\(label).png"))
        }
    }
    private static func renderResultPreviews(_ pin: PinController, evidenceDirectory: URL) throws {
        let panel = try required(pin.recognitionWindow, "Preview result missing")
        let originalResultAppearance = panel.window?.appearance
        defer { panel.window?.appearance = originalResultAppearance }
        for (label, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = try required(NSAppearance(named: name), "Native appearance unavailable")
            panel.window?.appearance = appearance
            let result = try required(panel.window?.contentView, "Result preview missing")
            try PinWorkflowSnapshot.write(result, to: evidenceDirectory.appendingPathComponent("pin-ocr-compact-\(label).png"))
        }
    }

    private static func verifyRestoration(raster: CGImage, result: RecognitionResult, defaults: UserDefaults,
        clipboard: NSPasteboard, focus: PinOCRFocusSentinel, directory: URL, deadline: Double) async throws -> [String: Any] {
        let store = try PinSessionStore(directory: directory)
        for index in 0..<20 {
            try checkDeadline(deadline)
            _ = try store.add(image: raster, title: "OCR restore \(index + 1)",
                presentation: PinPresentation(frame: PinWindowFrame(x: 50 + Double(index % 5) * 12,
                    y: 50 + Double(index / 5) * 12, width: 500, height: 160)), revealingGroup: true)
        }
        let originalGroup = store.index.activeGroupID
        let otherGroup = try store.createGroup(name: "OCR empty cancellation group", color: .purple)
        let scheduler = PinOCRScheduler(), gate = PinOCRDeterministicRaceGate(result: result)
        var probes: [PinOCRWorkflowReleaseProbe] = []
        var callbackErrors: [String] = []
        let coordinator = PinSessionCoordinator(store: store, desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
            ocrPreferences: PinOCRPreferences(defaults: defaults), makeImageController: { original, current, modified in
                let provider = PinOCRGatedProvider(gate: gate)
                let pin = PinController(originalImage: original, currentImage: current, isModified: modified,
                    recognizeWithOptions: { [provider] _, _ in try await provider.recognize() }, defaults: defaults, ocrScheduler: scheduler)
                probes.append(PinOCRWorkflowReleaseProbe(pin, provider: provider))
                return pin
            })
        coordinator.onError = { callbackErrors.append($0.localizedDescription) }
        defer { try? coordinator.prepareForTermination(); gate.releaseAll() }
        var observations: [[String: Any]] = []
        focus.activate()
        try coordinator.restoreOnLaunch(enabled: true, isSmoke: false)
        try await verifyTwenty(coordinator, scheduler: scheduler, gate: gate, focus: focus, deadline: deadline)
        observations.append(frontObject(scheduler.resourceSnapshot, label: "twenty-pin-launch-restore"))
        let clipboardCount = clipboard.changeCount
        try promoteWaitingCopy(coordinator, clipboard: clipboard)
        try await waitUntil(deadline: deadline, detail: "Two admitted front jobs", scheduler: scheduler,
            invariant: { try focus.verify() }) { gate.pendingCount == 2 }
        try require(scheduler.resourceSnapshot.activeJobs == 2 && scheduler.resourceSnapshot.automaticJobs == 1 &&
                    scheduler.resourceSnapshot.waitingSessions == 18 && sourceReads(coordinator) == 2,
                    "Explicit promotion exceeded admission/source-read bounds")
        observations.append(frontObject(scheduler.resourceSnapshot, label: "explicit-private-copy-promotion"))
        try coordinator.hideCurrentGroup()
        try require(coordinator.livePinCount == 0 && scheduler.resourceSnapshot.waitingSessions == 0, "Hide retained queued pins")
        gate.releaseAll()
        try await released(probes, scheduler: scheduler, deadline: deadline)
        try require(clipboard.changeCount == clipboardCount, "Cancelled copy wrote its private pasteboard")

        gate.hold()
        try coordinator.showCurrentGroup()
        try await verifyTwenty(coordinator, scheduler: scheduler, gate: gate, focus: focus, deadline: deadline)
        try coordinator.switchGroup(id: otherGroup.id)
        try require(coordinator.livePinCount == 0 && scheduler.resourceSnapshot.waitingSessions == 0, "Group switch retained queued pins")
        gate.releaseAll()
        try await released(probes, scheduler: scheduler, deadline: deadline)

        gate.hold()
        try coordinator.switchGroup(id: originalGroup)
        try await verifyTwenty(coordinator, scheduler: scheduler, gate: gate, focus: focus, deadline: deadline)
        try clickThroughAll(coordinator)
        try require(coordinator.livePinCount == 20 && coordinator.liveControllers.values.allSatisfy {
            $0.window?.ignoresMouseEvents == true && $0.ocrSession.state == .suspended && $0.ocrSession.cachedResult == nil
        }, "Click-through did not suspend every live pin")
        try require(scheduler.resourceSnapshot.waitingSessions == 0, "Click-through left waiting jobs")
        gate.releaseAll()
        try await waitUntil(deadline: deadline, detail: "Click-through running-job release", scheduler: scheduler,
            invariant: { try focus.verify() }) { scheduler.resourceSnapshot.activeJobs == 0 }
        try require(coordinator.liveControllers.values.allSatisfy { $0.ocrSession.cachedResult == nil && $0.recognitionWindow == nil },
                    "Late gated completion changed click-through pins")
        gate.hold()
        try coordinator.recoverCurrentGroup()
        try await verifyTwenty(coordinator, scheduler: scheduler, gate: gate, focus: focus, deadline: deadline, expectedReads: 2)
        closeAll(coordinator)
        try require(coordinator.livePinCount == 0 && scheduler.resourceSnapshot.waitingSessions == 0, "Close retained queued pins")
        gate.releaseAll()
        try await released(probes, scheduler: scheduler, deadline: deadline)
        try coordinator.prepareForTermination(); store.clearThumbnailCache()
        try focus.verify()
        try require(callbackErrors.isEmpty, "Coordinator callbacks failed: " + callbackErrors.joined(separator: "; "))
        let final = scheduler.resourceSnapshot
        try require(final.activeJobs == 0 && final.waitingSessions == 0 && final.admittedJobs == final.releasedJobs,
                    "Coordinator jobs did not return all admissions")
        return ["status": "passed", "restoredPinCount": 20, "controllerFactoryUsed": true,
                "deterministicRaceGate": true, "realAppleVisionRanInRacePhase": false,
                "raceResultProvenance": "Replayed caller's actual Vision document; gate itself does no recognition",
                "initialSourceReads": 1, "sourceReadsAfterExplicitPromotion": 2, "queuedMetadataContainsRasters": false,
                "sourceReadEvidence": "Each production provider increments ocrSourceReadCount only when its source is requested; 19 waiting pins remain unread",
                "focusPreserved": true, "cancelledPendingCopyPreservedClipboard": true,
                "cancellationChecks": ["hide-current-group", "switch-group", "native-click-through", "recover-current-group", "close"],
                "observedFrontBoundaries": observations, "finalFront": frontObject(final, label: "settled"),
                "releaseProbeCount": probes.count, "retainedObjects": probes.reduce(0) { $0 + $1.retainedCount },
                "releaseEvidence": releaseObject(probes),
                "liveControllersAfter": coordinator.livePinCount, "gatePendingAfter": gate.pendingCount]
    }

    private static func verifyTwenty(_ coordinator: PinSessionCoordinator, scheduler: PinOCRScheduler,
        gate: PinOCRDeterministicRaceGate, focus: PinOCRFocusSentinel, deadline: Double, expectedReads: Int = 1) async throws {
        try await waitUntil(deadline: deadline, detail: "Twenty-pin coordinator restoration", scheduler: scheduler,
            invariant: { try focus.verify() }) { gate.pendingCount == 1 }
        let front = scheduler.resourceSnapshot
        try require(coordinator.livePinCount == 20 && front.activeJobs == 1 && front.automaticJobs == 1 && front.waitingSessions == 19,
                    "Full restoration did not retain 19 metadata-only waiters behind one automatic job")
        try require(sourceReads(coordinator) == expectedReads, "Queued sources were read before admission")
        try require(coordinator.liveControllers.values.allSatisfy { $0.recognitionWindow == nil && $0.window?.isVisible == true },
                    "Restoration opened a result or failed to show pins")
    }
    private static func sourceReads(_ coordinator: PinSessionCoordinator) -> Int {
        coordinator.liveControllers.values.reduce(0) { $0 + $1.ocrSourceReadCount }
    }
    private static func promoteWaitingCopy(_ coordinator: PinSessionCoordinator, clipboard: NSPasteboard) throws {
        let pin = try required(coordinator.liveControllers.values.first { $0.ocrSession.state == .queued }, "Queued copy target missing")
        pin.copyAllRecognizedText(to: clipboard)
    }
    private static func clickThroughAll(_ coordinator: PinSessionCoordinator) throws {
        for pin in coordinator.liveControllers.values {
            try perform("鼠标穿透（菜单栏恢复当前组）", in: try required(pin.actionMenu, "Pin menu missing"))
        }
    }
    private static func closeAll(_ coordinator: PinSessionCoordinator) {
        for id in Array(coordinator.liveControllers.keys) { coordinator.liveControllers[id]?.close() }
    }

    private static func verifyResources(raster: CGImage, defaults: UserDefaults, deadline: Double) async throws -> [String: Any] {
        let scheduler = PinOCRScheduler(), calls = PinOCRVisionCallCounter()
        let beforeWarmup = try observedMemory(), warmupSampler = GIFResourceMemorySampler()
        defer { warmupSampler.stop() }
        var warmupProbes: [PinOCRWorkflowReleaseProbe] = []
        for _ in 0..<warmupCycles {
            warmupProbes.append(try await actualCycle(raster: raster, defaults: defaults, scheduler: scheduler, calls: calls, deadline: deadline))
            try await released(warmupProbes, scheduler: scheduler, deadline: deadline)
            try await settle(deadline: deadline)
        }
        let warmupStatistics = try stoppedStatistics(warmupSampler)
        let baseline = try observedMemory(), started = ProcessInfo.processInfo.systemUptime, sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        var measuredProbes: [PinOCRWorkflowReleaseProbe] = [], settled: [GIFResourceMemoryReading] = []
        for _ in 0..<measuredCycles {
            measuredProbes.append(try await actualCycle(raster: raster, defaults: defaults, scheduler: scheduler, calls: calls, deadline: deadline))
            try await released(measuredProbes, scheduler: scheduler, deadline: deadline)
            try await settle(deadline: deadline)
            sampler.sample(); settled.append(try observedMemory())
        }
        let measuredEnd = try required(settled.last, "Resource boundaries missing")
        let probes = warmupProbes + measuredProbes
        try await released(probes, scheduler: scheduler, deadline: deadline)
        try await settle(deadline: deadline)
        sampler.sample()
        let final = try observedMemory(), statistics = try stoppedStatistics(sampler), front = scheduler.resourceSnapshot
        let actual = calls.snapshot
        try require(actual.started == warmupCycles + measuredCycles && actual.completed == actual.started && actual.failed == 0,
                    "Resource cycles did not each finish one actual Vision recognition")
        try require(front.admittedJobs == actual.started && front.releasedJobs == actual.started,
                    "Result reuse added jobs or did not release admissions")
        let rss = settled.map { $0.residentBytes! }, footprint = settled.map { $0.physicalFootprintBytes! }
        return ["status": "passed", "observationsComplete": true, "warmupCycles": warmupCycles,
                "measuredCycles": measuredCycles, "completedMeasuredCycles": settled.count, "actualVisionCalls": actual.started,
                "cachedResultReuseCount": actual.started, "sameAuthoredRasterEachCycle": true,
                "sampleIntervalSeconds": GIFResourceMemorySampler.interval, "measuredElapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier), "limits": limits,
                "beforeWarmup": try object(beforeWarmup), "baselineAfterWarmup": try object(baseline),
                "warmupSampledMemory": try object(warmupStatistics), "sampledMemory": try object(statistics),
                "settledAfterCycles": try settled.map { try object($0) }, "afterMeasuredCycles": try object(measuredEnd),
                "finalAfterCleanup": try object(final), "settlingDelaySeconds": 0.15,
                "livePinsAndResultsAtBaselineAndEveryCycleEnd": 0, "activeJobsAtBaselineAndEveryCycleEnd": 0,
                "fixedInputRasterCountAtBaselineAndEveryCycleEnd": 1,
                "residentGrowthFromWarmupBytes": try delta(measuredEnd.residentBytes, baseline.residentBytes),
                "physicalFootprintGrowthFromWarmupBytes": try delta(measuredEnd.physicalFootprintBytes, baseline.physicalFootprintBytes),
                "residentLastIntervalGrowthBytes": Int64(rss[11]) - Int64(rss[10]),
                "physicalFootprintLastIntervalGrowthBytes": Int64(footprint[11]) - Int64(footprint[10]),
                "residentCleanupDeltaBytes": try delta(final.residentBytes, measuredEnd.residentBytes),
                "physicalFootprintCleanupDeltaBytes": try delta(final.physicalFootprintBytes, measuredEnd.physicalFootprintBytes),
                "residentLateThreeIntervalGrowthBytes": (9...11).map { Int64(rss[$0]) - Int64(rss[$0 - 1]) },
                "physicalFootprintLateThreeIntervalGrowthBytes": (9...11).map { Int64(footprint[$0]) - Int64(footprint[$0 - 1]) },
                "lateIntervalCycles": 1, "warmupReleaseProbes": warmupProbes.count, "measuredReleaseProbes": measuredProbes.count,
                "retainedObjects": probes.reduce(0) { $0 + $1.retainedCount }, "peakActualVisionCalls": actual.peakActive,
                "releaseEvidence": releaseObject(probes),
                "finalFront": frontObject(front, label: "settled"), "snapshotsInsideMeasuredLoop": 0,
                "memoryPressureOrSystemSettingsChanged": false, "memoryIsObservational": true, "stabilityAssessed": false,
                "scope": "2 warmups + 12 measured actual Vision show/result/close cycles. Identical zero-live-object endpoints retain one fixed authored input. Existing self-process RSS/footprint sampler; sampled peaks can miss transients. Not WindowServer/GPU totals, a plateau test, or proof of zero leaks."]
    }

    private static func actualCycle(raster: CGImage, defaults: UserDefaults, scheduler: PinOCRScheduler,
        calls: PinOCRVisionCallCounter, deadline: Double) async throws -> PinOCRWorkflowReleaseProbe {
        try checkDeadline(deadline)
        let prior = calls.snapshot.started, admitted = scheduler.resourceSnapshot.admittedJobs
        var provider: PinOCRActualVisionProvider? = PinOCRActualVisionProvider(calls: calls)
        var pin: PinController? = autoreleasepool { makePin(raster: raster, provider: provider!, scheduler: scheduler, defaults: defaults) }
        let probe = PinOCRWorkflowReleaseProbe(pin!, provider: provider!)
        defer { pin?.close() }
        pin!.applyAutomaticOCR(true); pin!.showWindow(nil)
        try await waitUntil(deadline: deadline, detail: "Resource actual Vision", scheduler: scheduler) { pin?.ocrSession.state == .ready }
        try require(pin!.ocrSession.cachedResult?.text.lowercased().contains("capture") == true && pin!.ocrSourceReadCount == 1,
                    "Resource cycle did not recognize fixed input exactly once")
        pin!.showRecognizedText()
        try await waitUntil(deadline: deadline, detail: "Resource cached result", scheduler: scheduler) { pin?.recognitionWindow != nil }
        probe.observeResult(pin!.recognitionWindow)
        try require(pin!.recognitionWindow?.resultDocument == pin!.ocrSession.cachedResult?.document,
                    "Resource result lost its actual source document")
        try require(calls.snapshot.started == prior + 1 && scheduler.resourceSnapshot.admittedJobs == admitted + 1,
                    "Resource result window repeated OCR")
        pin!.recognitionWindow?.close(); pin!.close(); pin = nil; provider = nil
        return probe
    }

    private static func makePin(raster: CGImage, provider: PinOCRActualVisionProvider, scheduler: PinOCRScheduler,
                                defaults: UserDefaults) -> PinController {
        PinController(originalImage: raster, currentImage: raster, isModified: false,
            recognizeWithOptions: { [provider] image, options in try await provider.recognize(image, options: options) },
            defaults: defaults, ocrScheduler: scheduler)
    }
    private static func waitUntil(deadline: Double, detail: String, scheduler: PinOCRScheduler,
                                  invariant: () throws -> Void = {}, condition: () -> Bool) async throws {
        let localDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 30)
        while true {
            try invariant(); try checkDeadline(localDeadline)
            let front = scheduler.resourceSnapshot, vision = await RecognitionService.resourceSnapshot()
            try require(front.activeJobs <= 2 && front.automaticJobs <= 1 && front.waitingSessions <= 32 &&
                        vision.activeJobs <= 2 && vision.waitingJobs <= 4, "Admission limits exceeded during " + detail)
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func released(_ probes: [PinOCRWorkflowReleaseProbe], scheduler: PinOCRScheduler, deadline: Double) async throws {
        try await waitUntil(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 10),
            detail: "Controller/provider/job release", scheduler: scheduler) {
                probes.allSatisfy { $0.retainedCount == 0 } && scheduler.resourceSnapshot.activeJobs == 0 &&
                    scheduler.resourceSnapshot.waitingSessions == 0
            }
        let vision = await RecognitionService.resourceSnapshot()
        try require(vision.activeJobs == 0 && vision.waitingJobs == 0, "Release boundary retained global Vision jobs")
    }
    private static func settle(deadline: Double) async throws {
        try checkDeadline(deadline)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { continuation.resume() } }
        try await Task.sleep(nanoseconds: 150_000_000)
        try checkDeadline(deadline)
    }
    private static func checkDeadline(_ deadline: Double) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Bounded fixture deadline exceeded")
    }
    private static func recognitionMenu(_ pin: PinController) throws -> NSMenu {
        try required(pin.actionMenu?.item(withTitle: "识别")?.submenu, "Recognition menu missing")
    }
    private static func perform(_ title: String, in menu: NSMenu) throws {
        let item = try required(menu.item(withTitle: title), "Menu item missing: " + title)
        try require(NSApp.sendAction(try required(item.action, "Menu action missing"), to: item.target, from: item), "Native menu action failed: " + title)
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func frontObject(_ value: PinOCRResourceSnapshot, label: String) -> [String: Any] {
        ["label": label, "activeJobs": value.activeJobs, "automaticJobs": value.automaticJobs,
         "waitingSessions": value.waitingSessions, "admittedJobs": value.admittedJobs, "releasedJobs": value.releasedJobs,
         "cancelledJobs": value.cancelledJobs, "rejectedJobs": value.rejectedJobs]
    }
    private static func releaseObject(_ probes: [PinOCRWorkflowReleaseProbe]) -> [String: Int] {
        ["probeCount": probes.count, "retainedControllers": probes.filter { $0.controller != nil }.count,
         "retainedSessions": probes.filter { $0.session != nil }.count, "retainedProviders": probes.filter { $0.provider != nil }.count,
         "retainedOverlays": probes.filter { $0.overlay != nil }.count, "retainedPinContentViews": probes.filter { $0.content != nil }.count,
         "retainedResultControllers": probes.filter { $0.result != nil }.count, "retainedResultContentViews": probes.filter { $0.resultContent != nil }.count]
    }
    private static func observedMemory() throws -> GIFResourceMemoryReading {
        let value = GIFResourceMemoryReading.current()
        guard let rss = value.residentBytes, let footprint = value.physicalFootprintBytes,
              rss > 0, footprint > 0, rss <= UInt64(Int64.max), footprint <= UInt64(Int64.max) else {
            throw failure("Required settled RSS/physical-footprint sample unavailable")
        }
        return value
    }
    private static func stoppedStatistics(_ sampler: GIFResourceMemorySampler) throws -> GIFResourceMemoryStatistics {
        sampler.stop(); let value = sampler.snapshot(), total = value.timerTickCount + value.boundarySampleCount
        try require(value.timerTickCount > 0 && value.residentSampleCount == total && value.physicalFootprintSampleCount == total &&
                    value.failedResidentSampleCount == 0 && value.failedPhysicalFootprintSampleCount == 0 &&
                    (value.peakResidentBytes ?? 0) > 0 && (value.peakPhysicalFootprintBytes ?? 0) > 0,
                    "Continuous RSS/footprint samples are incomplete")
        return value
    }
    private static func delta(_ current: UInt64?, _ previous: UInt64?) throws -> Int64 {
        guard let current, let previous, current <= UInt64(Int64.max), previous <= UInt64(Int64.max) else {
            throw failure("Comparable memory boundaries unavailable")
        }
        return Int64(current) - Int64(previous)
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try required(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any], "Evidence encoding failed")
    }
    private static func required<T>(_ value: T?, _ detail: String) throws -> T { guard let value else { throw failure(detail) }; return value }
    private static func require(_ condition: Bool, _ detail: String) throws { if !condition { throw failure(detail) } }
    private static func failure(_ detail: String) -> Error { PicShotError.message("Pin OCR workflow acceptance: " + detail) }
}

@MainActor private final class PinOCRFocusSentinel {
    let window: NSWindow
    let field = NSTextField(string: "Keep typing here while local OCR completes")
    private var expectedResponder: NSResponder?
    init() throws {
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 100),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OCR acceptance focus sentinel"; window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        field.frame = NSRect(x: 16, y: 36, width: 388, height: 24); content.addSubview(field); window.contentView = content
        activate(); try verify()
    }
    func activate() { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field); expectedResponder = window.firstResponder }
    func verify() throws {
        guard NSApp.keyWindow === window, let expectedResponder, window.firstResponder === expectedResponder,
              field.currentEditor() === expectedResponder else {
            throw PicShotError.message("OCR stole key-window/text-field first-responder focus, or sentinel could not acquire it")
        }
    }
    func close() { expectedResponder = nil; window.makeFirstResponder(nil); window.contentView = nil; window.close() }
}

@MainActor private final class PinOCRWorkflowReleaseProbe {
    weak var controller: PinController?
    weak var session: PinOCRSession?
    weak var overlay: PinTextSelectionOverlay?
    weak var content: NSView?
    weak var provider: AnyObject?
    weak var result: TextResultController?
    weak var resultContent: NSView?
    init(_ controller: PinController, provider: AnyObject) {
        self.controller = controller; session = controller.ocrSession; overlay = controller.textSelectionOverlay
        content = controller.window?.contentView; self.provider = provider
    }
    func observeResult(_ result: TextResultController?) { self.result = result; resultContent = result?.window?.contentView }
    var retainedCount: Int {
        autoreleasepool { [controller as AnyObject?, session, overlay, content, provider, result, resultContent].compactMap { $0 }.count }
    }
}

private final class PinOCRVisionCallCounter: @unchecked Sendable {
    struct Snapshot { let started: Int; let completed: Int; let failed: Int; let peakActive: Int; let languages: [String?] }
    private let lock = NSLock()
    private var started = 0, completed = 0, failed = 0, active = 0, peakActive = 0
    private var languages: [String?] = []
    func begin(_ options: RecognitionOptions) {
        lock.lock(); defer { lock.unlock() }; started += 1; active += 1; peakActive = max(peakActive, active); languages.append(options.language)
    }
    func finish(success: Bool) { lock.lock(); defer { lock.unlock() }; active -= 1; if success { completed += 1 } else { failed += 1 } }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(started: started, completed: completed, failed: failed, peakActive: peakActive, languages: languages)
    }
}

private final class PinOCRActualVisionProvider: @unchecked Sendable {
    let calls: PinOCRVisionCallCounter
    init(calls: PinOCRVisionCallCounter) { self.calls = calls }
    func recognize(_ image: CGImage, options: RecognitionOptions) async throws -> RecognitionResult {
        calls.begin(options)
        do { let result = try await RecognitionService.recognize(image, options: options); calls.finish(success: true); return result }
        catch { calls.finish(success: false); throw error }
    }
}

private final class PinOCRGatedProvider: @unchecked Sendable {
    let gate: PinOCRDeterministicRaceGate
    init(gate: PinOCRDeterministicRaceGate) { self.gate = gate }
    func recognize() async throws -> RecognitionResult { try await gate.wait() }
}

/// Deliberately ignores cancellation until explicitly released to exercise stale completions.
/// No raster is captured here; this is a deterministic race harness, never an OCR substitute.
private final class PinOCRDeterministicRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let result: RecognitionResult
    private var opened = false
    private var waiting: [CheckedContinuation<RecognitionResult, Error>] = []
    init(result: RecognitionResult) { self.result = result }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
    func hold() { lock.lock(); defer { lock.unlock() }; precondition(waiting.isEmpty); opened = false }
    func wait() async throws -> RecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume(returning: result) }
            else { waiting.append(continuation); lock.unlock() }
        }
    }
    func releaseAll() {
        lock.lock(); opened = true; let pending = waiting; waiting.removeAll(); lock.unlock()
        for continuation in pending { continuation.resume(returning: result) }
    }
}
