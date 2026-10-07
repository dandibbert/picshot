import AppKit
import CryptoKit
import Foundation
import PicShotCore

/// Opt-in repeated resource observations. Native button/drag and exact-output proof lives
/// in ScrollManualCaptureSmokeFixture. This loop uses direct setup and real production
/// RGBA hashing, stability, matching, transactional PNG spooling and sampled preview.
@MainActor
enum ScrollManualResourceFixture {
    static let reportName = "scroll-manual-resource.json"
    private static let warmupRepetitions = 2
    private static let measuredRepetitions = 4
    private static let deadlineSeconds = 240.0
    private static let settleSeconds = 0.15
    private static let acceptedPerCycle = 4
    private static let profiles: [(String, Int, Int, ScrollAxis)] = [
        ("4k-vertical", 3840, 2160, .vertical), ("4k-horizontal", 3840, 2160, .horizontal),
        ("5k-vertical", 5120, 2880, .vertical), ("5k-horizontal", 5120, 2880, .horizontal)
    ]

    static func verify(evidenceDirectory: URL, functionalReportURL: URL,
                       observationStrategy: ManualScrollObservationStrategy = .fullFrame,
                       diagnosticContext: [String: Any]? = nil) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let start = ProcessInfo.processInfo.systemUptime, deadline = start + deadlineSeconds
        let reportURL = evidenceDirectory.appendingPathComponent(reportName)
        var report: [String: Any] = [
            "schemaVersion": 2, "status": "running",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
            "architecture": architecture, "buildMode": buildMode,
            "warmupCycles": profiles.count * warmupRepetitions, "measuredCycles": profiles.count * measuredRepetitions,
            "acceptedFramesPerCycle": acceptedPerCycle, "overallDeadlineSeconds": deadlineSeconds,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval, "settlingDelaySeconds": settleSeconds,
            "workload": "direct setup; procedural viewports; production passive driver, RGBA hash, matcher, PNG spool and preview",
            "nativeControlEventsInResourceLoop": false, "fullOutputRastersInResourceLoop": 0,
            "giantMasterPageRasters": 0, "memoryIsObservational": true, "stabilityAssessed": false, "zeroLeakClaim": false,
            "screenCaptureStarted": false, "permissionRequests": false, "globalInputPosted": false,
            "networkUsed": false, "generalPasteboardUsed": false, "standardDefaultsWritten": false,
            "memoryPressureOrSystemSettingsChanged": false, "allocatorPurgeAttempted": false,
            "physicalDisplayOrExternalApplicationVerified": false,
            "backingAccountingScope": ImageBackingTaskVMReading.scope,
            "backingAccountingSampling": "Boundary-only TASK_VM_INFO and TASK_VM_INFO_PURGEABLE at every existing before/settled/baseline/final point; separate non-atomic calls from the unchanged 50 ms RSS/footprint sampler. These observations do not identify image ownership or prove reclaimability.",
            "purgeabilityInferredFromRSSFootprintGap": false,
            "memoryScope": "Main-process sampled Mach RSS and physical footprint; excludes WindowServer, GPU and other processes. Timer maxima can miss native transients and are not kernel lifetime peaks.",
            "backingCaveat": "ImageIO may retain volatile decoded backing beyond lexical release. RSS and footprint differ; owned-state release is not overall memory stability. Production screen crops may retain full-display backing; injected viewports do not measure that path.",
            "ownershipScope": "The fixture retains at most one procedural viewport, reused across stable captures; driver references may alias it. Sampled ownership counters cover the pending driver raster, accepted grayscale, overview, preview tile/jobs and provider call; they do not count transient normalization buffers, ImageIO decoder backing or framework caches.",
            "limits": ["framePixels": ScrollFrame.maximumPixels, "outputPixels": ScrollCaptureSequence.maximumOutputPixels,
                       "outputDimension": ScrollCaptureSequence.maximumOutputDimension, "acceptedSources": ScrollCaptureSequence.maximumBlocks,
                       "temporaryDiskBytes": 512 * 1024 * 1024, "fixtureViewportRasters": 1, "pendingCaptureRasters": 1, "captureRunners": 1,
                       "queuedCaptureRequests": 0, "overviewPixels": 800 * 800,
                       "previewTilePixels": ScrollPreviewTileRequest.maximumTilePixels,
                       "previewSourceSamplePixels": ScrollPreviewTileRequest.maximumSourceSamplePixels,
                       "previewCachedTiles": ScrollPreviewTileRequest.maximumCachedTiles,
                       "previewActiveJobs": ScrollPreviewTileRequest.maximumConcurrentJobs, "previewPendingJobs": 1]
        ]
        // The optional extension is consumed only by the dedicated candidate
        // checker. Ordinary resource reports retain their existing strict schema.
        try require(observationStrategy == .fullFrame || diagnosticContext != nil,
                    "Experimental hashing requires an explicit diagnostic context")
        var hashDiagnosticCycles: [[String: Any]] = []
        let diagnosticSink: (([String: Any]) -> Void)? = diagnosticContext == nil ? nil : { hashDiagnosticCycles.append($0) }
        func refreshHashDiagnostics() {
            guard var context = diagnosticContext else { return }
            context["strategy"] = observationStrategy.rawValue
            context["cycles"] = hashDiagnosticCycles
            report["diagnosticHashComparison"] = context
        }
        refreshHashDiagnostics()
        var warmups: [[String: Any]] = [], cycles: [[String: Any]] = []
        let warmupSampler = GIFResourceMemorySampler()
        defer { warmupSampler.stop() }
        do {
            guard NSScreen.main != nil else { throw failure("A WindowServer display is required") }
            guard let executable = Bundle.main.executableURL else { throw failure("Installed executable unavailable") }
            report["executableSHA256"] = try fileIdentity(executable).sha256
            let functionalSHA = try functionalDigest(functionalReportURL, sourceCommit: report["sourceCommit"] as? String ?? "unknown")
            report["functionalReportSHA256"] = functionalSHA
            report["beforeWarmup"] = try memory()
            for repetition in 0..<warmupRepetitions {
                for (index, profile) in profiles.enumerated() {
                    warmups.append(try await cycle(profile, index: repetition * profiles.count + index + 1, phase: "warmup", deadline: deadline,
                                                  observationStrategy: observationStrategy, diagnosticSink: diagnosticSink))
                    warmupSampler.sample(); report["warmups"] = warmups; refreshHashDiagnostics()
                }
            }
            warmupSampler.stop(); report["warmupSampledMemory"] = try statistics(warmupSampler)
            report["baselineAfterWarmup"] = try memory()
            let measuredSampler = GIFResourceMemorySampler()
            defer { measuredSampler.stop() }
            for repetition in 0..<measuredRepetitions {
                for (index, profile) in profiles.enumerated() {
                    cycles.append(try await cycle(profile, index: repetition * profiles.count + index + 1,
                                                   phase: "measured", deadline: deadline,
                                                   observationStrategy: observationStrategy, diagnosticSink: diagnosticSink))
                    measuredSampler.sample(); report["cycles"] = cycles; refreshHashDiagnostics()
                }
            }
            try await settle(deadline)
            let final = try memory()
            measuredSampler.stop(); report["sampledMemory"] = try statistics(measuredSampler)
            report["finalAfterCleanup"] = final
            guard let baseline = report["baselineAfterWarmup"] as? [String: Any] else { throw failure("Baseline absent") }
            for (field, prefix) in [("residentBytes", "resident"), ("physicalFootprintBytes", "physicalFootprint")] {
                let values = try cycles.map { try signedMemory($0["settledAfterClose"], field) }
                report[prefix + "GrowthFromWarmupBytes"] = values.last! - (try signedMemory(baseline, field))
                report[prefix + "EveryIntervalGrowthBytes"] = zip(values.dropFirst(), values).map { $0.0 - $0.1 }
                report[prefix + "LateThreeIntervalGrowthBytes"] = (values.count - 3..<values.count).map { values[$0] - values[$0 - 1] }
                report[prefix + "CleanupDeltaBytes"] = (try signedMemory(final, field)) - values.last!
            }
            var perProfile: [[String: Any]] = []
            for profile in profiles {
                let selected = cycles.filter { ($0["profile"] as? String) == profile.0 }
                var result: [String: Any] = ["profile": profile.0, "cycleIndices": selected.map { $0["index"]! },
                                                 "settledAfterCycles": selected.map { $0["settledAfterClose"]! }]
                for (field, prefix) in [("residentBytes", "resident"), ("physicalFootprintBytes", "physicalFootprint")] {
                    let values = try selected.map { try signedMemory($0["settledAfterClose"], field) }
                    result[prefix + "LateThreeIntervalGrowthBytes"] = zip(values.dropFirst(), values).map { $0.0 - $0.1 }
                }
                perProfile.append(result)
            }
            report["profileMemory"] = perProfile
            try checkDeadline(deadline)
            try require(try functionalDigest(functionalReportURL, sourceCommit: report["sourceCommit"] as? String ?? "unknown") == functionalSHA,
                        "Functional report changed during resource workload")
            report["completedWarmupCycles"] = warmups.count; report["completedMeasuredCycles"] = cycles.count
            report["observationsComplete"] = true
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start; report["status"] = "passed"
            try write(report, to: reportURL)
            return report
        } catch {
            refreshHashDiagnostics()
            report["status"] = "failed"; report["observationsComplete"] = false
            report["error"] = error.localizedDescription; report["warmups"] = warmups; report["cycles"] = cycles
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
            try? write(report, to: reportURL)
            throw error
        }
    }

    private static func cycle(_ profile: (String, Int, Int, ScrollAxis), index: Int,
                              phase: String, deadline: Double, observationStrategy: ManualScrollObservationStrategy,
                              diagnosticSink: (([String: Any]) -> Void)?) async throws -> [String: Any] {
        let (name, width, height, axis) = profile
        let began = ProcessInfo.processInfo.systemUptime
        let source = Source(width: width, height: height, axis: axis)
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let before = try memory()
        var controller: ScrollCaptureController? = ScrollCaptureController { _ in }
        weak var weakController = controller
        weak var weakPreview = controller?.previewForVerification
        weak var weakDriver: ManualScrollScreenDriver?
        weak var weakControls: NSWindowController?
        var coordinator: ManualScrollCoordinator?
        weak var weakCoordinator: ManualScrollCoordinator?
        var directory: URL?
        let observations = Observations(collectNormalization: diagnosticSink != nil)
        var normalizationReleases: [[String: Any]] = []
        var accepted: [SourceIdentity] = [], after: [SourceIdentity] = []
        var previewProof: [String: Any] = [:], resetProof: [String: Any] = [:]
        var sampledFrames = 0, capturesAtCancel = 0, verifiedDiskBytes: Int64 = 0
        defer { source.release(); coordinator?.cancel(); controller?.close() }
        do {
            guard let live = controller else { throw failure("Missing resource controller") }
            live.window?.setContentSize(NSSize(width: 760, height: 740))
            live.window?.contentView?.layoutSubtreeIfNeeded()
            try await live.setAutoCropForVerification(false)
            var config = ManualScrollConfiguration()
            config.countdownSeconds = 0; config.sampleInterval = 0.05; config.operationTimeout = 30
            config.maximumDuration = 120; config.maximumSamples = 80
            coordinator = try live.startManualForVerification(axis: axis,
                region: CGRect(x: 10, y: 10, width: width, height: height),
                screenSize: CGSize(width: width + 100, height: height + 100), configuration: config,
                observationStrategy: observationStrategy,
                provider: { try await source.next() })
            weakCoordinator = coordinator; weakDriver = live.manualDriverForVerification
            weakControls = live.manualControlsForVerification
            guard let run = coordinator else { throw failure("Missing resource coordinator") }
            func observe() throws { try observations.sample(live, run: run, source: source) }
            func releasedNormalization(_ label: String) throws {
                guard diagnosticSink != nil else { return }
                let bytes = weakDriver?.normalizationBufferBytesForVerification ?? 0
                try require(bytes == 0, "Normalization workspace survived drained " + label)
                normalizationReleases.append(["stage": label, "normalizationBufferBytes": bytes])
            }
            func wait(_ label: String, _ condition: () -> Bool) async throws {
                try await until(label, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 40)) {
                    try observe(); return condition()
                }
            }
            try await wait("First source not accepted") { live.sourceURLsForVerification.count == 1 && run.acceptedFrames == 1 && run.state == .waiting }
            directory = live.temporaryDirectoryForVerification
            accepted.append(try fileIdentity(live.sourceURLsForVerification[0]))
            let duplicateSamples = source.captures + 2
            try await wait("Stationary duplicate samples missing") { source.captures >= duplicateSamples }
            run.pause()
            try await wait("Pause did not drain") { run.canResume }
            try releasedNormalization("first-pause")
            try require(live.sourceURLsForVerification.count == 1 && weakDriver?.pendingImage == nil,
                        "Stationary viewport duplicated or pause retained a candidate")
            let pauseCaptures = source.captures
            try await settle(deadline)
            try require(source.captures == pauseCaptures, "Paused coordinator sampled")
            let original = live.manualRegionForVerification!
            try live.moveManualRegionForVerification(to: original.offsetBy(dx: 12, dy: 8))
            try require(live.manualRegionForVerification?.size == original.size, "Move resized region")
            try require(try fileIdentities(live.sourceURLsForVerification) == accepted, "Move changed accepted bytes")
            source.offset += source.step
            run.resume()
            try await wait("Moved source not accepted") { live.sourceURLsForVerification.count == 2 && run.acceptedFrames == 2 && run.state == .waiting }
            run.pause(); try await wait("Second source pause did not drain") { run.canResume }
            try releasedNormalization("second-pause")
            accepted.append(try fileIdentity(live.sourceURLsForVerification[1]))
            source.offset = source.length * 8 + 17
            run.resume()
            try await wait("Uncertain seam did not pause recoverably") {
                if case .recoverable = run.state { return run.canResume }; return false
            }
            try releasedNormalization("recoverable-seam")
            try require(try fileIdentities(live.sourceURLsForVerification) == accepted, "Rejected seam changed accepted bytes")
            for frame in 3...acceptedPerCycle {
                source.offset = 100 + (frame - 1) * source.step
                run.resume()
                try await wait("Stable source \(frame) not accepted") { live.sourceURLsForVerification.count == frame && run.acceptedFrames == frame && run.state == .waiting }
                run.pause(); try await wait("Stable source pause did not drain") { run.canResume }
                try releasedNormalization("accepted-\(frame)-pause")
                accepted.append(try fileIdentity(live.sourceURLsForVerification[frame - 1]))
            }
            try require(run.acceptedFrames == acceptedPerCycle, "Coordinator accepted count differs")
            try require(live.retainedGrayPixelsForVerification == width * height, "Accepted grayscale extent differs")
            let preview = live.previewForVerification
            // Direct setup intentionally avoids claiming native mouse/control semantics.
            preview.zoomPreview(by: 8)
            preview.navigate(to: .beginning); preview.zoomPreview(by: 2)
            try await wait("Beginning detail tile did not settle") {
                let s = preview.snapshotForVerification
                return int(s, "activeJobs") == 0 && int(s, "pendingJobs") == 0 && int(s, "cachedTiles") == 1
            }
            let beginning = preview.snapshotForVerification
            preview.navigate(to: .end); preview.zoomPreview(by: 2)
            try await wait("End detail tile did not settle") {
                let s = preview.snapshotForVerification
                return int(s, "activeJobs") == 0 && int(s, "pendingJobs") == 0 && int(s, "cachedTiles") == 1
            }
            let end = preview.snapshotForVerification
            try require((beginning["visibleRect"] as? [Double]) != (end["visibleRect"] as? [Double]), "Preview did not navigate")
            previewProof = ["beginning": beginning, "end": end]
            after = try fileIdentities(live.sourceURLsForVerification)
            try require(after == accepted, "Preview changed accepted source bytes")
            let actualDisk = try diskSize(directory)
            verifiedDiskBytes = actualDisk
            try require(actualDisk == live.diskBytesForVerification, "Spool accounting differs from files")
            try observe()
            // Hold the next injected provider call so cancellation definitely overlaps
            // one pending capture, with no second provider call or queued capture.
            source.holdNext = true; run.resume()
            try await wait("Cancellation provider gate not reached") { source.waiting }
            capturesAtCancel = source.captures; sampledFrames = run.sampledFrames
            run.cancel(); source.release()
            try await wait("Canceled capture did not drain") { !run.hasPendingOperation && source.activeProviders == 0 }
            try releasedNormalization("cancel")
            try require(source.captures == capturesAtCancel && run.sampledFrames == sampledFrames,
                        "Cancellation scheduled late sampling")
            try require(live.manualDriverForVerification?.pendingImage == nil, "Canceled provider retained pending raster")
            try require(try fileIdentities(live.sourceURLsForVerification) == accepted, "Cancellation changed accepted sources")
            source.clearRaster()
            live.resetForVerification()
            try await wait("Reset preview worker did not drain") { int(preview.snapshotForVerification, "activeJobs") == 0 }
            try releasedNormalization("reset")
            resetProof = endpoint(live, run: run, source: source)
            try require(resetProof.values.allSatisfy { ($0 as? Int) == 0 }, "Reset retained owned state")
            try require(directory.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "Reset left spool directory")
            live.close()
        }
        controller = nil; coordinator = nil
        try await until("Closed resource objects remain retained", deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 10)) {
            weakController == nil && weakPreview == nil && weakDriver == nil && weakControls == nil && weakCoordinator == nil
        }
        try await settle(deadline)
        try require(source.captures == capturesAtCancel && source.activeProviders == 0, "Late provider ran after close")
        let settled = try memory(); sampler.stop()
        if let diagnosticSink {
            let ownsWorkspace = observationStrategy == .reusableFullFrame || observationStrategy == .vImageFullFrame
            let expectedPeak = ownsWorkspace ? width * height * 4 : 0
            try require(observations.normalizationPeakBytes == expectedPeak && observations.normalizationSamples > 0,
                        "Diagnostic normalization workspace was not observed at its expected bound")
            diagnosticSink(["index": index, "phase": phase, "profile": name,
                "strategy": observationStrategy.rawValue,
                "peakNormalizationBufferBytes": observations.normalizationPeakBytes,
                "normalizationSamples": observations.normalizationSamples,
                "normalizationReleases": normalizationReleases,
                "normalizationBufferBytesAfterClose": weakDriver?.normalizationBufferBytesForVerification ?? 0])
        }
        return [
            "index": index, "phase": phase, "profile": name, "axis": axis.rawValue,
            "width": width, "height": height, "framePixels": width * height, "rgbaBytesPerViewport": width * height * 4,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
            "captures": source.captures, "sampledFrames": sampledFrames, "acceptedFrames": acceptedPerCycle,
            "verifiedSpoolBytes": verifiedDiskBytes, "providerPeakActiveCalls": source.peakActiveProviders, "lateCaptureIncrements": source.captures - capturesAtCancel,
            "sourceBytesBefore": try accepted.map(object), "sourceBytesAfter": try after.map(object),
            "acceptedSourcesImmutable": true, "stationarySuppressed": true, "uncertainSeamRejected": true,
            "pauseDrained": true, "pauseStoppedSampling": true, "sameSizeMovePreservedSources": true,
            "retryKeptAnchor": true, "cancelOverlappedProvider": true, "cancelDrained": true,
            "resetRemovedSpool": true, "closedObjectsReleased": true,
            "preview": previewProof, "observedPeaks": observations.peaks, "ownershipSamples": observations.count,
            "resetState": resetProof,
            "closedState": ["controllers": weakController == nil ? 0 : 1, "previews": weakPreview == nil ? 0 : 1,
                            "drivers": weakDriver == nil ? 0 : 1, "controls": weakControls == nil ? 0 : 1,
                            "coordinators": weakCoordinator == nil ? 0 : 1, "providerCalls": source.activeProviders,
                            "spoolDirectories": directory.map { FileManager.default.fileExists(atPath: $0.path) ? 1 : 0 } ?? 0],
            "before": before, "settledAfterClose": settled, "sampledMemory": try statistics(sampler)
        ]
    }

    @MainActor private final class Source {
        let width: Int, height: Int, axis: ScrollAxis
        var offset = 100 { didSet { if offset != oldValue { cached = nil } } }
        var captures = 0, activeProviders = 0, peakActiveProviders = 0
        private(set) var cached: CGImage?
        var holdNext = false, waiting = false
        private var gate: CheckedContinuation<Void, Never>?
        var length: Int { axis == .vertical ? height : width }
        var step: Int { length / 4 }
        init(width: Int, height: Int, axis: ScrollAxis) { self.width = width; self.height = height; self.axis = axis }
        func next() async throws -> CGImage {
            captures += 1; activeProviders += 1; peakActiveProviders = max(peakActiveProviders, activeProviders)
            defer { activeProviders -= 1 }
            if holdNext {
                holdNext = false; waiting = true
                await withCheckedContinuation { gate = $0 }
                waiting = false
            }
            try Task.checkCancellation()
            if let cached { return cached }
            let w = width, h = height, o = offset, a = axis
            let worker = Task.detached(priority: .userInitiated) {
                try autoreleasepool { try ScrollManualCaptureSmokeFixture.largeImage(width: w, height: h, offset: o, axis: a) }
            }
            let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            cached = image
            return image
        }
        func release() { gate?.resume(); gate = nil }
        func clearRaster() { cached = nil }
    }

    @MainActor private final class Observations {
        let collectNormalization: Bool
        private(set) var normalizationPeakBytes = 0, normalizationSamples = 0
        init(collectNormalization: Bool) { self.collectNormalization = collectNormalization }
        var count = 0
        var peaks: [String: Int] = [:]
        func sample(_ live: ScrollCaptureController, run: ManualScrollCoordinator, source: Source) throws {
            let p = live.previewForVerification.snapshotForVerification
            let pending = live.manualDriverForVerification?.pendingImage
            let state: [String: Int] = [
                "fixtureViewportRasters": source.cached == nil ? 0 : 1,
                "fixtureViewportPixels": source.cached.map { $0.width * $0.height } ?? 0,
                "pendingCaptureRasters": pending == nil ? 0 : 1,
                "pendingCapturePixels": pending.map { $0.width * $0.height } ?? 0,
                "captureRunners": run.hasPendingOperation ? 1 : 0, "providerCalls": source.activeProviders,
                "acceptedSources": live.sourceURLsForVerification.count,
                "acceptedGrayPixels": live.retainedGrayPixelsForVerification,
                "overviewPixels": live.previewPixelsForVerification,
                "previewTilePixels": ScrollManualResourceFixture.int(p, "tileWidth") * ScrollManualResourceFixture.int(p, "tileHeight"),
                "previewCachedTiles": ScrollManualResourceFixture.int(p, "cachedTiles"), "previewActiveJobs": ScrollManualResourceFixture.int(p, "activeJobs"),
                "previewPendingJobs": ScrollManualResourceFixture.int(p, "pendingJobs"), "previewSourceReferences": ScrollManualResourceFixture.int(p, "sourceReferences"),
                "temporaryDiskBytes": Int(live.diskBytesForVerification)
            ]
            let caps: [String: Int] = [
                "fixtureViewportRasters": 1, "fixtureViewportPixels": source.width * source.height,
                "pendingCaptureRasters": 1, "pendingCapturePixels": source.width * source.height,
                "captureRunners": 1, "providerCalls": 1, "acceptedSources": ScrollManualResourceFixture.acceptedPerCycle,
                "acceptedGrayPixels": source.width * source.height, "overviewPixels": 800 * 800,
                "previewTilePixels": ScrollPreviewTileRequest.maximumTilePixels, "previewCachedTiles": 1,
                "previewActiveJobs": 1, "previewPendingJobs": 1, "previewSourceReferences": ScrollManualResourceFixture.acceptedPerCycle,
                "temporaryDiskBytes": 512 * 1024 * 1024
            ]
            for (key, value) in state {
                try ScrollManualResourceFixture.require(value >= 0 && value <= caps[key]!, "Observed owned bound exceeded: \(key)")
                peaks[key] = max(peaks[key] ?? 0, value)
            }
            if collectNormalization {
                let bytes = live.manualDriverForVerification?.normalizationBufferBytesForVerification ?? 0
                try ScrollManualResourceFixture.require(bytes >= 0 && bytes <= source.width * source.height * 4,
                                                        "Owned normalization workspace exceeded viewport bound")
                normalizationPeakBytes = max(normalizationPeakBytes, bytes); normalizationSamples += 1
            }
            count += 1
        }
    }

    private static func endpoint(_ live: ScrollCaptureController, run: ManualScrollCoordinator, source: Source) -> [String: Any] {
        let p = live.previewForVerification.snapshotForVerification
        return ["fixtureViewportRasters": source.cached == nil ? 0 : 1,
                "pendingCaptureRasters": live.manualDriverForVerification?.pendingImage == nil ? 0 : 1,
                "captureRunners": run.hasPendingOperation ? 1 : 0, "providerCalls": source.activeProviders,
                "acceptedSources": live.sourceURLsForVerification.count, "acceptedGrayPixels": live.retainedGrayPixelsForVerification,
                "overviewPixels": live.previewPixelsForVerification, "temporaryDiskBytes": Int(live.diskBytesForVerification),
                "previewActiveJobs": int(p, "activeJobs"), "previewPendingJobs": int(p, "pendingJobs"),
                "previewCachedTiles": int(p, "cachedTiles"), "previewSourceReferences": int(p, "sourceReferences")]
    }
    private static func int(_ dictionary: [String: Any], _ key: String) -> Int { dictionary[key] as? Int ?? -1 }
    private struct SourceIdentity: Encodable, Equatable { let name: String; let bytes: Int64; let sha256: String }
    private static func fileIdentities(_ urls: [URL]) throws -> [SourceIdentity] { try urls.map(fileIdentity) }
    private static func fileIdentity(_ url: URL) throws -> SourceIdentity {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), count: Int64 = 0
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty { hash.update(data: bytes); count += Int64(bytes.count) }
        return SourceIdentity(name: url.lastPathComponent, bytes: count, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func diskSize(_ directory: URL?) throws -> Int64 {
        guard let directory else { throw failure("Missing source spool") }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { sum, url in sum + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }
    /// Earliest caller-visible boundary is smoke entry after AppDelegate startup.
    /// This cannot reconstruct counters at process birth.
    static func hashComparisonMemoryBoundary() throws -> [String: Any] { try memory() }

    private static func memory() throws -> [String: Any] {
        let reading = GIFResourceMemoryReading.current()
        try require((reading.residentBytes ?? 0) > 0 && (reading.physicalFootprintBytes ?? 0) > 0
                    && reading.residentBytes! <= UInt64(Int64.max) && reading.physicalFootprintBytes! <= UInt64(Int64.max),
                    "RSS/physical-footprint sample unavailable")
        // Read the kernel's purgeable accounting directly. The RSS/footprint gap
        // is never substituted for any of these values. Existing timer sampling
        // remains unchanged; these two additional calls occur only at boundaries.
        let backing = ImageBackingMemoryReading.current()
        try require(backing.standard.kernelReturn == 0 && backing.purgeable.kernelReturn == 0
                    && (backing.residentBytes ?? 0) > 0 && (backing.physicalFootprintBytes ?? 0) > 0
                    && backing.purgeable.bytes["purgeable_volatile_resident"] != nil
                    && backing.purgeable.bytes["purgeable_volatile_virtual"] != nil
                    && backing.purgeable.bytes["purgeable_volatile_pmap"] != nil,
                    "TASK_VM_INFO/PURGEABLE boundary accounting unavailable or short; fields were not replaced with zero")
        var result = try object(reading)
        result["backingAccounting"] = try object(backing)
        return result
    }
    private static func statistics(_ sampler: GIFResourceMemorySampler) throws -> [String: Any] {
        let s = sampler.snapshot(), total = s.timerTickCount + s.boundarySampleCount
        try require(s.timerTickCount > 0 && s.boundarySampleCount > 0 && s.failedResidentSampleCount == 0
                    && s.failedPhysicalFootprintSampleCount == 0 && s.residentSampleCount == total
                    && s.physicalFootprintSampleCount == total, "Resource sampling incomplete")
        return try object(s)
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw failure("Invalid report object") }
        return result
    }
    private static func signedMemory(_ object: Any?, _ field: String) throws -> Int64 {
        guard let object = object as? [String: Any], let value = object[field] as? NSNumber, value.int64Value > 0 else { throw failure("Missing memory field") }
        return value.int64Value
    }
    private static func until(_ label: String, deadline: Double, condition: () throws -> Bool) async throws {
        while true {
            try checkDeadline(deadline)
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
            if ProcessInfo.processInfo.systemUptime >= deadline { throw failure(label) }
        }
    }
    private static func settle(_ deadline: Double) async throws {
        try checkDeadline(deadline); try await Task.sleep(nanoseconds: 150_000_000); try checkDeadline(deadline)
    }
    private static func checkDeadline(_ deadline: Double) throws {
        try Task.checkCancellation(); try require(ProcessInfo.processInfo.systemUptime < deadline, "Resource fixture deadline exceeded")
    }
    private static func functionalDigest(_ url: URL, sourceCommit: String) throws -> String {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(properties.isRegularFile == true && properties.isSymbolicLink != true
                    && (properties.fileSize ?? 0) > 0 && (properties.fileSize ?? Int.max) <= 2 * 1024 * 1024,
                    "Functional report must be a bounded regular file")
        let bytes = try Data(contentsOf: url)
        guard let report = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw failure("Invalid functional report") }
        try require(report["status"] as? String == "passed" && report["sourceCommit"] as? String == sourceCommit,
                    "Functional report did not pass for the installed source")
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
    private static var buildMode: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }
    private struct FixtureFailure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func failure(_ message: String) -> FixtureFailure { FixtureFailure(message: message) }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw failure(message) }
    }
}
