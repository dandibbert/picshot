import AppKit
import PicShotCodecCore

@MainActor
enum ImageDecodeLargeUIFixture {
    static func run(input: ImageDecodeLargeInput, isolated: Bool, directory: URL) async throws -> [String: Any] {
        guard input.profile == .fiveK else { throw ImageDecodeDiagnosticError.invalidInput }
        _ = NSApplication.shared
        let mode = isolated ? "native-ui-isolated" : "native-ui-control"
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 120
        let state = ImageDecodeUIState(), pulse = ImageDecodeMainQueueProbe(), sampler = ImageDecodeMemorySampler()
        defer { pulse.stop(); sampler.stop() }
        let adapter = try ImageDecodeLargeUIAdapter(input: input, isolated: isolated, deadline: deadline, state: state)
        defer { adapter.verifier.close() }
        var report = ImageDecodeLargeSupport.base(mode: mode, input: input)
        report["warmupCycles"] = 2; report["measuredCycles"] = 4; report["maximumRequestGenerations"] = 16
        report["armDeadlineSeconds"] = 120; report["requiredOuterDeadlineSeconds"] = 140
        report["scope"] = "Real ImageExportController controls/scheduling and ImageExportPreviewView native drawing over prepared PNG via encoder injection; excludes full export encoding and saving"
        report["inputLatencyScope"] = "Programmatic native control actions and one-outstanding main-queue acknowledgements; not physical input latency or monitor scanout"
        report["responsivenessFlagSeconds"] = 0.1
        report["parentPeakScope"] = "Whole UI run includes source/snapshot construction, fault scenarios and final evidence capture; successful-series settled samples are separate"
        report["retinaScope"] = "Actual AppKit backing factor and backing conversions only; no OS mode changes or assumed Retina hardware"
        var weakControllers: [ImageDecodeWeakUIController] = [], successful: [[String: Any]] = [], faults: [[String: Any]] = []
        let output = directory.appendingPathComponent("image-decode-large-\(mode).json")
        do {
            try ImageDecodeLargeSupport.check(deadline, sampler: sampler)
            report["beforeSourceConstruction"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            let sourceStarted = ProcessInfo.processInfo.systemUptime
            let source = try autoreleasepool { try CodecExportResourceFixture.fixture(width: input.profile.sourceWidth, height: input.profile.sourceHeight) }
            report["sourceConstructionSeconds"] = ProcessInfo.processInfo.systemUptime - sourceStarted
            report["afterSourceConstruction"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            var controller: ImageExportController? = try Self.makeController(source: source, adapter: adapter, state: state)
            weakControllers.append(.init(controller!))
            defer { controller?.cancelExport() }
            for ordinal in 0..<6 {
                let before = try ImageDecodeLargeSupport.observe()
                let oldDrawCount = state.snapshot().drawCount
                let action = try await perform(controller!, action: .preview, scenario: .normal, state: state)
                let ready = try await ready(controller!, state: state, newerThanDrawCount: oldDrawCount, deadline: deadline)
                guard ready.worker.pixelsSHA256 == input.referenceSHA else { throw ImageDecodeDiagnosticError.outputMismatch }
                try await ImageDecodeLargeSupport.settle(0.18, deadline: deadline)
                var row: [String: Any] = ["index": ordinal < 2 ? ordinal + 1 : ordinal - 1, "isWarmup": ordinal < 2,
                    "action": action, "workerIndex": ready.worker.index, "nativeDraw": try ImageDecodeLargeSupport.object(ready.draw),
                    "requestToNativeDrawSeconds": ready.draw.uptimeSeconds - ready.worker.requestUptimeSeconds,
                    "workerLifecycleSeconds": ready.worker.finishedUptimeSeconds! - ready.worker.startedUptimeSeconds,
                    "exactPreviewPixels": true, "rawSHA256": ready.worker.pixelsSHA256!,
                    "before": try ImageDecodeLargeSupport.object(before), "settled": try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())]
                row["sourcePreparationExcluded"] = true; successful.append(row)
                if ordinal == 1 { report["baselineAfterWarmup"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe()) }
                try ImageDecodeLargeSupport.check(deadline, sampler: sampler)
            }
            report["afterMeasuredSeries"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            // Three real native control actions inside the unchanged 160 ms debounce.
            let countBeforeBurst = state.snapshot().records.count, drawBeforeBurst = state.snapshot().drawCount
            let burstActions = try await performBurst(controller!, state: state)
            let burst = try await ready(controller!, state: state, newerThanDrawCount: drawBeforeBurst, deadline: deadline)
            let afterBurst = state.snapshot()
            guard afterBurst.records.count == countBeforeBurst + 1, burst.worker.scenario == "burst" else { throw ImageDecodeDiagnosticError.invalidProtocol }
            report["debounceBurst"] = ["actions": burstActions, "startedWorkers": 1, "latestResultDrawn": true,
                "finalNativeDraw": try ImageDecodeLargeSupport.object(burst.draw)]
            // Capture only after the repeated memory interval, using actual view backing.
            report["evidenceCapture"] = try capture(controller!, to: directory.appendingPathComponent("native-preview-ready.png"))
            controller?.cancelExport(); controller = nil
            try await quiescent(deadline: deadline)
            for scenario in [ImageDecodeUIState.Scenario.cancelActive, .closeDecoded, .lateResult] {
                let count = state.snapshot().records.count
                var faultController: ImageExportController? = try Self.makeController(source: source, adapter: adapter, state: state)
                weakControllers.append(.init(faultController!))
                defer { faultController?.cancelExport() }
                let previewAction = try await perform(faultController!, action: .preview, scenario: scenario, state: state)
                let desired = scenario == .cancelActive && isolated ? "signatureStarted" : scenario == .closeDecoded && isolated ? "heldAfterDecode" : "resultHeld"
                let worker = try await stage(desired, afterRecordCount: count, state: state, deadline: deadline)
                let action = try await perform(faultController!, action: scenario == .closeDecoded ? .close : .cancel, scenario: scenario, state: state, startsRequest: false)
                state.releaseLateResult()
                try await quiescent(deadline: deadline)
                let finished = try requireValue(state.snapshot().records.last)
                // Reading the cancellation token and recording completion are
                // distinct operations. A completed result supplies no evidence
                // that cancellation raced it, even when timestamps overlap.
                let completedWithoutObservedCancellation = isolated && scenario == .cancelActive && finished.outcome == "completed"
                guard finished.index == worker.index, finished.finishedUptimeSeconds != nil,
                      finished.outcome == "cancelled" || finished.outcome == "completed-after-cancel" || completedWithoutObservedCancellation,
                      faultController!.isClosed, faultController!.latestArtifact == nil, faultController!.previewView.image == nil,
                      !faultController!.saveButton.isEnabled, faultController!.previewView.diagnosticDrawObserver == nil else { throw ImageDecodeDiagnosticError.invalidProtocol }
                if let process = finished.process {
                    guard process.cleanupConfirmed, process.admissionReleased, !process.childLaunched || process.exitConfirmed else { throw ImageDecodeDiagnosticError.exitUnconfirmed }
                    if scenario == .closeDecoded { guard process.sawPostDecodeReady, process.terminal?.error == .cancelled else { throw ImageDecodeDiagnosticError.invalidProtocol } }
                    if scenario == .lateResult { guard process.exitConfirmed, process.outcome == "decoded" else { throw ImageDecodeDiagnosticError.invalidProtocol } }
                }
                var fault: [String: Any] = ["scenario": scenario.rawValue, "previewAction": previewAction, "cancelOrCloseAction": action,
                    "workerIndex": finished.index, "observedStage": desired, "staleResultSuppressed": true, "windowClosed": true,
                    "cancellationHandledToWorkerFinishedSeconds": max(0, finished.finishedUptimeSeconds! - action["handledUptimeSeconds"]!),
                    "cancellationRaceExercised": !completedWithoutObservedCancellation]
                if isolated && scenario == .cancelActive {
                    guard let start = finished.stages["signatureStarted"], let end = finished.stages["signatureFinished"] else { throw ImageDecodeDiagnosticError.invalidProtocol }
                    let handled = action["handledUptimeSeconds"]!
                    fault["cancelOverlappedSignatureValidation"] = handled >= start && handled <= end
                    fault["signatureCallInterruptible"] = false
                    // A fast verifier may finish before the UI action; record it
                    // honestly rather than fabricating a held signature call.
                }
                faults.append(fault); faultController = nil
                try await ImageDecodeLargeSupport.settle(0.2, deadline: deadline)
            }
            try await quiescent(deadline: deadline)
            adapter.verifier.close()
            try await ImageDecodeLargeSupport.settle(0.5, deadline: deadline)
            guard weakControllers.allSatisfy({ $0.value == nil }) else { throw ImageDecodeDiagnosticError.failed }
            withExtendedLifetime(source) { }; withExtendedLifetime(input) { }
            pulse.stop()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
            sampler.stop()
            let observed = state.snapshot(), mainQueue = pulse.snapshot()
            guard observed.records.count <= 16, mainQueue.samples > 0,
                  observed.records.allSatisfy({ $0.finishedUptimeSeconds != nil }), ImageExportService.queue.operationCount == 0 else { throw ImageDecodeDiagnosticError.failed }
            report["warmups"] = Array(successful.prefix(2)); report["cycles"] = Array(successful.dropFirst(2)); report["faultScenarios"] = faults
            report["workers"] = try observed.records.map { try ImageDecodeLargeSupport.object($0) }
            report["controllerConstruction"] = try observed.constructions.map { try ImageDecodeLargeSupport.object($0) }
            report["mainQueue"] = try ImageDecodeLargeSupport.object(mainQueue)
            report["responsivenessFlagTriggered"] = mainQueue.maximumDelaySeconds > 0.1
            report["allRequestedCancellationRacesObserved"] = faults.allSatisfy { $0["cancellationRaceExercised"] as? Bool == true &&
                ($0["cancelOverlappedSignatureValidation"] as? Bool ?? true) }
            report["actualNativeDrawCount"] = observed.drawCount
            report["completedSuccessfulNativeDraws"] = 6; report["exactSuccessfulPreviewValidations"] = 6
            report["measuredNativeDraws"] = 4
            report["backingScaleFactor"] = observed.lastDraw?.backingScale ?? 0
            report["highDPIBackingObserved"] = (observed.lastDraw?.backingScale ?? 0) >= 2
            report["controllersReleased"] = true; report["activeExportControllers"] = ImageExportController.activeSessionCount
            report["ownedJobsRemaining"] = 0; report["maximumObservedChildConcurrency"] = isolated ? 1 : 0
            report["helperInvocations"] = observed.records.filter { $0.process?.childLaunched == true }.count
            report["providerLifetime"] = try ImageDecodeLargeSupport.object(adapter.providers.snapshot())
            report["destinationLifetime"] = try ImageDecodeLargeSupport.object(adapter.verifier.tracker.snapshot())
            report["parentPeaks"] = try ImageDecodeLargeSupport.object(sampler.snapshot())
            try ImageDecodeLargeSupport.check(deadline, sampler: sampler)
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started; report["status"] = "observed"
            try ImageDecodeLargeSupport.write(report, to: output); return report
        } catch {
            state.releaseLateResult()
            let cleanupDeadline = min(started + 138, ProcessInfo.processInfo.systemUptime + 10)
            while ImageExportService.queue.operationCount > 0 && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { c.resume() } }
            }
            report["failureWorkerQueueDrained"] = ImageExportService.queue.operationCount == 0
            pulse.stop(); sampler.stop()
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedPreviews"] = successful; report["completedFaultScenarios"] = faults
            report["workers"] = try? state.snapshot().records.map { try ImageDecodeLargeSupport.object($0) }
            try? ImageDecodeLargeSupport.write(report, to: output); throw error
        }
    }
    private static func makeController(source: CGImage, adapter: ImageDecodeLargeUIAdapter, state: ImageDecodeUIState) throws -> ImageExportController {
        let started = ProcessInfo.processInfo.systemUptime, before = try ImageDecodeLargeSupport.observe()
        let controller = try ImageExportController(image: source, encoder: { snapshot, options, token in try adapter.encode(snapshot, options: options, token: token) })
        do { try state.recordConstruction(.init(elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                                                before: before, after: ImageDecodeLargeSupport.observe())) }
        catch { controller.cancelExport(); throw error }
        controller.window?.title = "PNG decode diagnostic"
        controller.previewView.diagnosticDrawObserver = { [state] observation in state.recordDraw(.init(observation)) }
        controller.showWindow(nil); controller.window?.center(); controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }
    private enum Action { case preview, cancel, close }
    private static func perform(_ controller: ImageExportController, action: Action, scenario: ImageDecodeUIState.Scenario,
                                state: ImageDecodeUIState, startsRequest: Bool = true) async throws -> [String: Double] {
        let queued = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let handled = ProcessInfo.processInfo.systemUptime
                        if startsRequest { state.plan(scenario, requestedAt: handled) }
                        do {
                            switch action {
                            case .preview:
                                controller.accessory.picker.selectItem(at: ImageExportFormat.png.rawValue)
                                guard controller.accessory.picker.sendAction(controller.accessory.picker.action, to: controller.accessory.picker.target) else { throw ImageDecodeDiagnosticError.failed }
                            case .cancel:
                                guard let root = controller.window?.contentView, let button = cancelButton(root), button.sendAction(button.action, to: button.target) else { throw ImageDecodeDiagnosticError.failed }
                            case .close: controller.window?.performClose(nil)
                            }
                            continuation.resume(returning: ["queuedUptimeSeconds": queued, "handledUptimeSeconds": handled,
                                "returnedUptimeSeconds": ProcessInfo.processInfo.systemUptime, "queueDelaySeconds": handled - queued])
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }
    private static func performBurst(_ controller: ImageExportController, state: ImageDecodeUIState) async throws -> [[String: Double]] {
        let queued = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        do {
                            var actions: [[String: Double]] = []
                            // All three real control callbacks run before the
                            // main actor can start any of their debounce Tasks.
                            for _ in 0..<3 {
                                let handled = ProcessInfo.processInfo.systemUptime
                                state.plan(.burst, requestedAt: handled)
                                controller.accessory.picker.selectItem(at: ImageExportFormat.png.rawValue)
                                guard controller.accessory.picker.sendAction(controller.accessory.picker.action, to: controller.accessory.picker.target) else { throw ImageDecodeDiagnosticError.failed }
                                actions.append(["queuedUptimeSeconds": queued, "handledUptimeSeconds": handled,
                                    "returnedUptimeSeconds": ProcessInfo.processInfo.systemUptime, "queueDelaySeconds": handled - queued])
                            }
                            continuation.resume(returning: actions)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }
    private static func cancelButton(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == "export.cancel" { return button }
        for child in view.subviews { if let result = cancelButton(child) { return result } }; return nil
    }
    private static func ready(_ controller: ImageExportController, state: ImageDecodeUIState, newerThanDrawCount: Int, deadline: Double) async throws -> (worker: ImageDecodeUIWorkerRecord, draw: ImageDecodeUIDrawRecord) {
        while ProcessInfo.processInfo.systemUptime < deadline {
            let value = state.snapshot()
            if let worker = value.records.last, worker.outcome == "failed" { throw ImageDecodeDiagnosticError.failed }
            if let artifact = controller.latestArtifact, let image = controller.previewView.image,
               let worker = value.records.last, worker.outcome == "completed", worker.imageIdentity == String(describing: ObjectIdentifier(artifact.firstPreview)),
               let draw = value.lastDraw, draw.imageIdentity == String(describing: ObjectIdentifier(image)), draw.windowVisible,
               draw.uptimeSeconds >= (worker.finishedUptimeSeconds ?? Double.infinity), value.drawCount > newerThanDrawCount,
               draw.displayedRect[2] > 0, draw.displayedRect[3] > 0, controller.saveButton.isEnabled {
                return (worker, draw)
            }
            try await ImageDecodeLargeSupport.settle(0.01, deadline: deadline)
        }
        throw ImageDecodeDiagnosticError.deadline
    }
    private static func stage(_ name: String, afterRecordCount: Int, state: ImageDecodeUIState, deadline: Double) async throws -> ImageDecodeUIWorkerRecord {
        while ProcessInfo.processInfo.systemUptime < deadline {
            let records = state.snapshot().records
            if records.count > afterRecordCount, let record = records.last {
                if record.stages[name] != nil { return record }
                if record.finishedUptimeSeconds != nil { throw ImageDecodeDiagnosticError.failed }
            }
            try await ImageDecodeLargeSupport.settle(0.005, deadline: deadline)
        }
        throw ImageDecodeDiagnosticError.deadline
    }
    private static func quiescent(deadline: Double) async throws {
        while ImageExportService.queue.operationCount > 0 { try await ImageDecodeLargeSupport.settle(0.01, deadline: deadline) }
        try await ImageDecodeLargeSupport.settle(0.1, deadline: deadline)
    }
    private static func capture(_ controller: ImageExportController, to url: URL) throws -> [String: Any] {
        guard let view = controller.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ImageDecodeDiagnosticError.failed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 4_194_304 else { throw ImageDecodeDiagnosticError.failed }
        try data.write(to: url, options: .atomic)
        return ["filename": url.lastPathComponent, "bytes": data.count, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
            "outsideRepeatedMemoryInterval": true, "screenCaptureAttempted": false]
    }
    private static func requireValue<T>(_ value: T?) throws -> T { guard let value else { throw ImageDecodeDiagnosticError.failed }; return value }
}
@MainActor private final class ImageDecodeWeakUIController {
    weak var value: ImageExportController?
    init(_ value: ImageExportController) { self.value = value }
}
