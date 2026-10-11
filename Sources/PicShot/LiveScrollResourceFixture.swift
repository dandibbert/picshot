import AppKit
import CryptoKit
import Darwin
import ImageIO
import PicShotCore

/// Opt-in narrow resource cell. This is injected acquisition, never SCK proof.
/// Final PNG verification runs in another process; the measured app never decodes it.
@MainActor
enum LiveScrollResourceFixture {
    static let width = 1280, height = 960, header = 72, finalHeight = 7136
    static let viewportBytes = width * height * 4
    static let outputBytes = width * finalHeight * 4
    static let offsets = [0] + Array(stride(from: 32, through: 3072, by: 32))
        + Array(stride(from: 3040, through: 2688, by: -32))
        + Array(stride(from: 2720, through: 6144, by: 32)) + [6176]
    private static let workload = "live-scroll-owned-1280-v1"
    private static let warmups = 2, measured = 8

    @MainActor private final class Owners {
        weak var session: LiveScrollSessionController?
        weak var source: LiveScrollResourceFrameSource?
        weak var controls: LiveScrollCaptureController?
        weak var thumbnail: LiveScrollThumbnailView?
        var windows: [WeakWindow] = []
        var released: Bool {
            session == nil && source == nil && controls == nil && thumbnail == nil
                && windows.allSatisfy { $0.value?.contentView == nil && $0.value?.delegate == nil }
        }
        var report: [String: Any] {
            ["sessionReleased": session == nil, "sourceReleased": source == nil,
             "controlsReleased": controls == nil, "thumbnailReleased": thumbnail == nil,
             "attachedWindowGraphs": windows.filter { $0.value?.contentView != nil || $0.value?.delegate != nil }.count,
             "retainedWindowShells": windows.filter { $0.value != nil }.count]
        }
    }
    @MainActor private final class WeakWindow { weak var value: NSWindow?; init(_ value: NSWindow) { self.value = value } }
    @MainActor private final class Cycle {
        let owners = Owners(), ledger = LiveScrollResourceAllocationLedger()
        var image: CGImage?
        var completions = 0
        var report: [String: Any] = [:]
        var boundaries: [[String: Any]] = []
        func boundary(_ phase: String) throws { boundaries.append(try LiveScrollResourceFixture.memory(phase)) }
    }

    static func runIfRequested(evidenceDirectory: URL) async throws -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["PICSHOT_LIVE_SCROLL_RESOURCE_MODE"] else { return nil }
        let allowed: Set<String> = ["PICSHOT_SMOKE_TEST", "PICSHOT_SMOKE_REPORT", "PICSHOT_LIVE_SCROLL_RESOURCE_MODE", "PICSHOT_LIVE_SCROLL_RESOURCE_INPUT", "PICSHOT_LIVE_SCROLL_PNG_WRITER"]
        guard Set(env.keys.filter { $0.hasPrefix("PICSHOT_") }).isSubset(of: allowed),
              ["certify", "measure", "validate"].contains(mode),
              let path = env["PICSHOT_LIVE_SCROLL_RESOURCE_INPUT"], path.hasPrefix("/"),
              env["PICSHOT_SMOKE_TEST"] == "1", env["PICSHOT_LIVE_SCROLL_DEMO_ONLY"] == nil else {
            throw failure("Invalid/extraneous live-scroll resource request")
        }
        guard let pngWriter = ScrollPNGWriteBackend(rawValue: env["PICSHOT_LIVE_SCROLL_PNG_WRITER"] ?? "foundation") else {
            throw failure("Unknown live-scroll PNG writer; expected foundation or posix")
        }
        let prepared = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let input = prepared.appendingPathComponent("fixture.bgra")
        let certificateURL = prepared.appendingPathComponent("certificate.json")
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 590
        let entry = try memory("fresh-app-entry-before-input-validation")
        let commit = Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown"
        try require(commit.count == 40 && commit.allSatisfy { $0.isHexDigit }, "Missing exact production source stamp")
        guard let executable = Bundle.main.executableURL else { throw failure("Missing executable identity") }
        let executableSHA = try digest(executable)
        var report: [String: Any] = ["schemaVersion": 2, "status": "running", "mode": mode,
            "pngWriterBackend": pngWriter.rawValue, "pngWriterSelectionScope": "Final PNG recipient only; independent reference uses the unchanged default writer",
            "measurementComplete": false, "pixelValidationStatus": "not-run",
            "workload": workload, "sourceCommit": commit, "executableSHA256": executableSHA,
            "architecture": architecture, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundlePath": Bundle.main.bundlePath, "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "entry": entry, "warmupCycles": warmups, "measuredCycles": measured,
            "viewportWidth": width, "viewportHeight": height, "sourceFramesPerCycle": offsets.count,
            "outputWidth": width, "outputHeight": finalHeight, "preparedRawBytes": outputBytes,
            "acquisition": "direct owned-byte protocol source; no SCK or verification-adapter draw",
            "measurementScope": "Production live session, growing UI, Finish render and bounded PNG writer; excludes AppDelegate history/editor recipient, SCK/WindowServer/GPU/other processes",
            "backingAccountingScope": ImageBackingTaskVMReading.scope,
            "nativeAcquisitionValidated": false, "installerAcceptance": false,
            "memoryStabilityClaimed": false, "zeroLeakClaimed": false,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval,
            "cooperativeDeadlineSeconds": 590, "externalLauncherDeadlineSeconds": 600,
            "deadlineReason": "Existing600s launcher;590s app budget leaves nominal10s margin,startup consumes part;180s/session unchanged",
            "unobservedTransientFrameworkPeak": true,
            "predeclaredTargetsAndGatesBytes": ["coldSampledGrowth": 2 * outputBytes + 8 * viewportBytes + 16 * 1_024 * 1_024,
                "coldFinalGrowth": 2 * viewportBytes + 16 * 1_024 * 1_024,
                "measuredGrowth": 2 * viewportBytes, "lateIntervalAndSum": viewportBytes],
            "coldAndPeakTargetsAreDiagnosticOnly": true,
            "acceptanceGates": "Exact outputs/ownership/cleanup plus measured and late growth; estimated cold/peak targets are reported separately, never relabeled passed",
            "pixelVerificationInMeasuredProcess": false]
        let reportURL = evidenceDirectory.appendingPathComponent(mode == "certify" ? "live-scroll-resource-certificate-run.json" : "live-scroll-resource-measurement.json")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        do {
            if mode == "certify" {
                try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
                try prepareForVerification(input)
                let referenceURL = evidenceDirectory.appendingPathComponent("expected-reference.png")
                try writeReference(input, to: referenceURL)
                report["expectedReference"] = ["file": referenceURL.lastPathComponent, "sha256": try digest(referenceURL)]
                report["byteConversionFidelity"] = try await byteConversionFidelity(input)
            } else {
                let certificate = try readObject(certificateURL)
                try require(certificate["status"] as? String == "passed" && certificate["workload"] as? String == workload
                    && certificate["sourceCommit"] as? String == commit
                    && certificate["executableSHA256"] as? String == executableSHA
                    && certificate["pngWriterBackend"] as? String == pngWriter.rawValue,
                    "Native pixel certificate does not match this exact app/workload")
                let inputSHA = try digest(input)
                try require(certificate["inputSHA256"] as? String == inputSHA, "Prepared input identity changed")
                report["certificateSHA256"] = try digest(certificateURL)
            }
            report["inputSHA256"] = try digest(input)
            report["afterInputValidation"] = try memory("after-input-validation")
            if mode == "validate" {
                let measurement = try readObject(reportURL)
                guard let cycles = measurement["cycles"] as? [[String: Any]],
                      let assessment = measurement["budgetAssessment"] as? [String: Any],
                      let memoryPassed = assessment["warmAndLateGatesPassed"] as? Bool else {
                    throw failure("Complete measurement cycles/assessment unavailable")
                }
                try require(measurement["measurementComplete"] as? Bool == true
                    && measurement["measurementStatus"] as? String == "complete"
                    && measurement["workload"] as? String == workload
                    && measurement["warmupCycles"] as? Int == warmups
                    && measurement["measuredCycles"] as? Int == measured
                    && measurement["sourceFramesPerCycle"] as? Int == offsets.count
                    && measurement["sourceCommit"] as? String == commit
                    && measurement["executableSHA256"] as? String == executableSHA
                    && measurement["pngWriterBackend"] as? String == pngWriter.rawValue
                    && (measurement["inputSHA256"] as? String) == (report["inputSHA256"] as? String)
                    && (measurement["certificateSHA256"] as? String) == (report["certificateSHA256"] as? String)
                    && measurement["completedWarmupCycles"] as? Int == warmups
                    && measurement["completedMeasuredCycles"] as? Int == measured
                    && cycles.count == warmups + measured,
                    "Matching complete measurement identity/counts unavailable")
                let expectedMeasurementStatus = memoryPassed ? "measured-awaiting-pixel-validation" : "failed"
                try require(measurement["status"] as? String == expectedMeasurementStatus
                    && measurement["memoryGateStatus"] as? String == (memoryPassed ? "passed" : "failed"),
                    "Measurement status disagrees with unchanged memory gates")
                var proofs: [[String: Any]] = []
                for ordinal in 1...(warmups + measured) {
                    let cycle = cycles[ordinal - 1]
                    let name = String(format: "cycle-%02d.png", ordinal)
                    guard let output = cycle["output"] as? [String: Any],
                          let expectedBytes = output["encodedBytes"] as? Int,
                          let state = cycle["lastProductState"] as? [String: Any],
                          let source = cycle["sourceAfterStop"] as? [String: Any] else {
                        throw failure("Completed cycle output/work metadata missing")
                    }
                    try require(cycle["ordinal"] as? Int == ordinal && cycle["status"] as? String == "passed"
                        && cycle["warmup"] as? Bool == (ordinal <= warmups)
                        && cycle["pngWriterBackend"] as? String == pngWriter.rawValue
                        && cycle["finishCallbacks"] as? Int == 1
                        && state["acceptedObservations"] as? Int == offsets.count
                        && source["successfulFrames"] as? Int == offsets.count
                        && output["file"] as? String == name && expectedBytes > 0
                        && output["width"] as? Int == width && output["height"] as? Int == finalHeight,
                        "Incomplete or reordered cycle cannot receive a complete pixel certificate")
                    var proof: [String: Any]
                    do { proof = try verifyPNG(evidenceDirectory.appendingPathComponent(name), input: input) }
                    catch {
                        proof = ["passed": false, "file": name, "error": error.localizedDescription,
                            "hashAvailable": false, "pixelEquality": false]
                    }
                    proof["ordinal"] = ordinal; proof["expectedEncodedBytes"] = expectedBytes
                    if proof["encodedBytes"] as? Int != expectedBytes {
                        proof["passed"] = false; proof["error"] = "Encoded file byte count differs from completed recipient output"
                    }
                    proofs.append(proof)
                    report["outputCertificates"] = proofs
                    try write(report, evidenceDirectory.appendingPathComponent("live-scroll-resource-validation.json"))
                }
                let pixelsPassed = proofs.allSatisfy { $0["passed"] as? Bool == true }
                report["measurementComplete"] = true; report["measurementStatus"] = "complete"
                report["completedWarmupCycles"] = warmups; report["completedMeasuredCycles"] = measured
                report["memoryGateStatus"] = memoryPassed ? "passed" : "failed"
                report["measurementReportStatus"] = measurement["status"]
                report["pixelValidationStatus"] = pixelsPassed ? "passed" : "failed"
                report["validationCompleted"] = true
                report["status"] = memoryPassed && pixelsPassed ? "passed" : "failed"
                report["measurementReportSHA256"] = try digest(reportURL)
                try write(report, evidenceDirectory.appendingPathComponent("live-scroll-resource-validation.json"))
                return report
            }
            var cycles: [[String: Any]] = []
            let count = mode == "certify" ? 1 : warmups + measured
            for ordinal in 1...count {
                let cycle = await runCycle(input: input, directory: evidenceDirectory, ordinal: ordinal, deadline: deadline, pngWriter: pngWriter)
                cycles.append(cycle); report["cycles"] = cycles
                try write(report, reportURL)
                try require(cycle["status"] as? String == "passed", "Live-scroll resource cycle failed; inspect preserved scalar evidence")
                if mode == "measure", ordinal == 1, let elapsed = cycle["elapsedSeconds"] as? Double {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    let projectedRemaining = elapsed * Double(count - ordinal)
                    report["firstCycleTimingEligibility"] = ["cycleSeconds": elapsed,
                        "remainingSeconds": remaining, "projectedRemainingCycleSeconds": projectedRemaining,
                        "projectionIsGuarantee": false]
                    if projectedRemaining + 1 > remaining {
                        report["status"] = "incomplete"
                        report["reason"] = "First actual cycle projects beyond the existing outer bound; planned 2+8 workload was not reduced"
                        report["completedWarmupCycles"] = 1; report["completedMeasuredCycles"] = 0
                        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
                        try write(report, reportURL)
                        return report
                    }
                }
            }
            let final = try memory("after-all-cycle-150ms-and-1000ms-observations")
            report["final"] = final
            report["finalTimingScope"] = "Fresh reading after the last cycle's explicit 150ms and1000ms release observations; exact per-cycle timestamps retained"
            if mode == "certify" {
                let proof = try verifyPNG(evidenceDirectory.appendingPathComponent("cycle-01.png"), input: input)
                report["outputCertificate"] = proof
                try require(proof["passed"] as? Bool == true, "Native prequalification PNG pixels failed")
                report["pixelValidationStatus"] = "passed"
                report["status"] = "passed"
                try write(report, certificateURL)
            } else {
                let assessment = try assess(entry: entry, cycles: cycles, final: final)
                report["budgetAssessment"] = assessment
                let memoryPassed = assessment["warmAndLateGatesPassed"] as? Bool == true
                report["measurementComplete"] = true; report["measurementStatus"] = "complete"
                report["completedWarmupCycles"] = warmups; report["completedMeasuredCycles"] = measured
                report["memoryGateStatus"] = memoryPassed ? "passed" : "failed"
                report["pixelValidationStatus"] = "pending-independent-validation"
                report["independentValidationRequired"] = true
                report["status"] = memoryPassed ? "measured-awaiting-pixel-validation" : "failed"
                if !memoryPassed {
                    report["failureKind"] = "memory-gates"
                    report["error"] = "Predeclared measured/late growth gate exceeded; all complete outputs still require independent pixel validation"
                }
            }
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try write(report, reportURL)
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try? write(report, mode == "validate" ? evidenceDirectory.appendingPathComponent("live-scroll-resource-validation.json") : reportURL)
            throw error
        }
    }

    private static func runCycle(input: URL, directory: URL, ordinal: Int, deadline: Double, pngWriter: ScrollPNGWriteBackend) async -> [String: Any] {
        let context = Cycle(), sampler = GIFResourceMemorySampler(includeBacking: true)
        defer { sampler.stop() }
        let began = ProcessInfo.processInfo.systemUptime
        let spool = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-LiveResource-" + UUID().uuidString)
        context.report = ["ordinal": ordinal, "warmup": ordinal <= warmups, "cold": ordinal == 1, "pngWriterBackend": pngWriter.rawValue]
        var cycleError: Error?
        do {
            try context.boundary("before-session")
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try await runSession(context, input: input, spool: spool,
                output: directory.appendingPathComponent(String(format: "cycle-%02d.png", ordinal)), sampler: sampler, deadline: deadline, pngWriter: pngWriter)
            try context.boundary("session-closed-output-recipient-alive")
        } catch { cycleError = error }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        context.image = nil
        context.report["explicitOwnerReleaseUptime"] = releasedAt
        // runSession has returned: its source/session/controls/image locals no longer own anything.
        do {
            try context.boundary("recipient-and-helper-locals-released")
            try await sleepUntil(releasedAt + 0.15)
            try context.boundary("released-plus-150ms")
            context.report["observed150msElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - releasedAt
            context.report["ownership150ms"] = context.owners.report
            context.report["provider150ms"] = try object(context.ledger.snapshot())
            try await sleepUntil(releasedAt + 1.0)
            try context.boundary("released-plus-1000ms")
            context.report["observed1000msElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - releasedAt
            context.report["ownership1000ms"] = context.owners.report
            let allocations = context.ledger.snapshot()
            context.report["providerAfterClose"] = try object(allocations)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: spool.path)
            context.report["remainingSpoolEntries"] = remaining
            try require(remaining.isEmpty, "Owned live-scroll spool did not clean up")
            // rmdir only: never recursively hide a leaked session directory.
            var removed = false
            spool.withUnsafeFileSystemRepresentation { path -> Void in
                guard let path else { return }
                removed = Darwin.rmdir(path) == 0
            }
            context.report["ownedSpoolParentRemoved"] = removed
            try require(removed && context.owners.released && allocations.liveImages == 0 && allocations.liveBytes == 0
                && allocations.allocatedImages == allocations.releasedImages,
                "Source buffers or weak session/source/control graph survived cleanup")
            try require(allocations.peakLiveImages <= 2 && allocations.peakLiveBytes <= 2 * viewportBytes,
                "Direct source retained more than the active viewport and previous anchor")
            try check(deadline, sampler)
        } catch {
            context.report["cleanupError"] = error.localizedDescription
            if cycleError == nil { cycleError = error }
        }
        sampler.stop()
        let statistics = sampler.snapshot()
        do { try ScrollMemoryAttributionFixture.checkSamples(statistics) }
        catch { if cycleError == nil { cycleError = error } }
        if statistics.timerTickCount == 0 || statistics.backingSampleCount != statistics.timerTickCount + statistics.boundarySampleCount
            || statistics.peakVolatileResidentBytes == nil || statistics.peakVolatileLedgerBytes == nil {
            cycleError = cycleError ?? failure("Timer/backing sampler observations incomplete")
        }
        context.report["memory"] = try? object(sampler.snapshot())
        context.report["boundaries"] = context.boundaries
        context.report["finishCallbacks"] = context.completions
        context.report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
        context.report["status"] = cycleError == nil ? "passed" : "failed"
        if let cycleError { context.report["error"] = cycleError.localizedDescription }
        return context.report
    }

    private static func runSession(_ context: Cycle, input: URL, spool: URL, output: URL,
                                   sampler: GIFResourceMemorySampler, deadline: Double, pngWriter: ScrollPNGWriteBackend) async throws {
        guard let screen = NSScreen.main else { throw CaptureError.noDisplay }
        let sessionDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 180)
        let source = try LiveScrollResourceFrameSource(input: input, screen: screen, ledger: context.ledger)
        context.owners.source = source
        let session = LiveScrollSessionController(onComplete: { image in
            context.completions += 1
            try require(context.completions == 1, "Repeated Finish delivery")
            context.image = image
            try context.boundary("finish-image-alive-before-png")
            try require(image.width == width && image.height == finalHeight, "Finish output dimensions changed")
            try ScrollImageIO.writeBoundedPNG(image, to: output, maximumBytes: 512 * 1_024 * 1_024, backend: pngWriter)
            context.report["output"] = ["file": output.lastPathComponent, "width": image.width, "height": image.height,
                "layoutBytes": image.bytesPerRow * image.height,
                "encodedBytes": try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1]
            try context.boundary("png-finalized-image-alive")
        }, onImport: {}, resourceStorageParent: spool)
        context.owners.session = session
        var failure: Error?
        do {
            try context.boundary("source-ready")
            try await session.startForVerification(source: source, screen: screen)
            context.owners.controls = session.controlsForVerification
            if let controls = session.controlsForVerification {
                context.owners.thumbnail = controls.previewWindow?.contentView as? LiveScrollThumbnailView
                context.owners.windows = [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow].compactMap { $0 }.map(WeakWindow.init)
            }
            var previousHeight = 0, growths = 0, reverseSamples = 0, previousOffset = 0
            var firstPreview = false, firstMarker: CGRect?
            while session.stateForVerification.acceptedObservations < offsets.count {
                try check(sessionDeadline, sampler)
                let state = session.stateForVerification
                if source.snapshot.successfulFrames == offsets.count && source.snapshot.idleResponses > 0 {
                    throw self.failure("All218 source frames were consumed but the product did not accept the full fixed sequence")
                }
                try require(session.snapshotForVerification.statusKind != .error && !state.previewUnavailable,
                    "Product session failed or preview became unavailable")
                if state.height > previousHeight { if previousHeight > 0 { growths += 1 }; previousHeight = state.height }
                if state.viewportOffset < previousOffset { reverseSamples += 1 }; previousOffset = state.viewportOffset
                if !firstPreview, let view = context.owners.thumbnail, view.image != nil {
                    firstPreview = true; firstMarker = view.viewportMarker
                    try context.boundary("first-displayed-preview")
                }
                if let image = context.owners.thumbnail?.image {
                    try require(image.width <= 1024 && image.height <= 1024 && image.width * image.height <= 262_144,
                        "Displayed preview exceeded existing bounds")
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let state = session.stateForVerification
            let doc = await session.documentSnapshotForResourceVerification()
            try require(state.width == width && state.height == finalHeight && state.viewportOffset == 6176
                && state.acceptedObservations == offsets.count && !state.previewUnavailable
                && session.snapshotForVerification.statusKind != .error
                && state.fixedLeading == header && state.fixedTrailing == 0,
                "Final live state or pending 32-pixel edge changed")
            try require(doc != nil && doc!.height <= finalHeight && doc!.sourceReadCount == 0
                && doc!.cachedPreviewBytes <= LiveScrollDocument.maximumCachedPreviewBytes,
                "Incremental preview/cache/document metadata changed")
            let finalMarker = context.owners.thumbnail?.viewportMarker
            try require(context.owners.thumbnail?.image != nil, "Final thumbnail is absent")
            if let image = context.owners.thumbnail?.image {
                try require(image.width <= 1024 && image.height <= 1024 && image.width * image.height <= 262_144,
                    "Final thumbnail exceeded existing bounds")
            }
            try require(firstPreview && growths >= 8 && reverseSamples >= 2 && firstMarker != nil && finalMarker != nil
                && finalMarker!.height < firstMarker!.height, "Growing preview or accepted reverse movement missing")
            context.report["preFinish"] = ["acceptedObservations": state.acceptedObservations, "sourceCount": state.committedSources,
                "diskBytes": state.diskBytes, "height": state.height, "offset": state.viewportOffset,
                "cachedPreviewBytes": doc!.cachedPreviewBytes, "sourceReadCount": doc!.sourceReadCount,
                "durableHeight": doc!.height, "pendingPreview": state.previewIsTransient,
                "predictedSourceCountBeforeFinish": 66, "predictedSourceCountAfterFinish": 67,
                "predictedCountStatus": "Arithmetic diagnostic only; not acceptance thresholds",
                "observedGrowths": growths, "observedReverseSamples": reverseSamples,
                "growthObservationScope": "10ms UI polling; not exact per-frame update counts"]
            try context.boundary("pre-finish-pending-edge")
            guard let button = findButton("scroll.live.finish", in: session.controlsForVerification?.toolbarWindow?.contentView) else {
                throw self.failure("Native Finish button missing")
            }
            try PortableSettingsUIPreviewFixture.click(button)
            while context.completions != 1 || !session.isClosedForVerification {
                try check(sessionDeadline, sampler)
                try require(session.snapshotForVerification.statusKind != .error, "Finish or PNG recipient failed")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch { failure = error }
        let retained = session.stateForVerification
        context.report["lastProductState"] = ["width": retained.width, "height": retained.height,
            "acceptedObservations": retained.acceptedObservations, "sampledFrames": session.sampledFramesForVerification,
            "offset": retained.viewportOffset, "committedSources": retained.committedSources,
            "diskBytes": retained.diskBytes, "matched": retained.matched,
            "previewUnavailable": retained.previewUnavailable, "productStatus": session.snapshotForVerification.status]
        await session.closeForVerification()
        do { try await source.stop() } catch { if failure == nil { failure = error } }
        context.report["sourceAfterStop"] = try object(source.snapshot)
        context.report["sessionReportedClosed"] = session.isClosedForVerification
        if !session.isClosedForVerification || source.snapshot.state != "stopped" || source.snapshot.activeReads != 0
            || source.snapshot.descriptorOpen || !source.snapshot.descriptorCloseConfirmed || source.snapshot.confirmedStops != 1 {
            failure = failure ?? self.failure("Actual injected source stop/drain not confirmed")
        }
        if let failure { throw failure }
        try require(source.snapshot.successfulFrames == offsets.count, "Incorrect successful source work count")
    }

    private static func sleepUntil(_ deadline: Double) async throws {
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
    }
    private static func check(_ deadline: Double, _ sampler: GIFResourceMemorySampler) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Bounded live-scroll resource/session deadline exceeded")
        try ScrollMemoryAttributionFixture.checkSamples(sampler.snapshot())
    }
    private static func memory(_ phase: String) throws -> [String: Any] {
        let reading = GIFResourceMemoryReading.current(), backing = ImageBackingMemoryReading.current()
        try require(reading.residentBytes != nil && reading.physicalFootprintBytes != nil
            && backing.standard.kernelReturn == KERN_SUCCESS && backing.purgeable.kernelReturn == KERN_SUCCESS
            && backing.purgeable.bytes["purgeable_volatile_resident"] != nil
            && backing.purgeable.bytes["purgeable_volatile_virtual"] != nil
            && backing.purgeable.bytes["purgeable_volatile_pmap"] != nil
            && backing.purgeable.ledgerBytes["ledger_purgeable_volatile"] != nil
            && backing.purgeable.ledgerBytes["ledger_purgeable_volatile_compressed"] != nil,
            "Required self-task accounting unavailable; not a zero observation")
        try require(reading.residentBytes! <= ScrollMemoryAttributionFixture.residentCeiling
            && reading.physicalFootprintBytes! <= ScrollMemoryAttributionFixture.footprintCeiling,
            "Boundary memory watchdog ceiling exceeded")
        return ["phase": phase, "uptime": ProcessInfo.processInfo.systemUptime,
            "memory": try object(reading), "backing": try object(backing)]
    }
    private static func assess(entry: [String: Any], cycles: [[String: Any]], final: [String: Any]) throws -> [String: Any] {
        try require(cycles.count == 10, "Incomplete repeated workload")
        var result: [String: Any] = [:]
        var gatesPassed = true
        for key in ["residentBytes", "physicalFootprintBytes"] {
            let initial = try scalar(entry, key), end = try scalar(final, key)
            let endpoints = try cycles.map { cycle -> Int64 in
                guard let rows = cycle["boundaries"] as? [[String: Any]],
                      let endpoint = rows.first(where: { $0["phase"] as? String == "released-plus-150ms" }) else { throw failure("Missing 150ms boundary") }
                return try scalar(endpoint, key)
            }
            let peakKey = key == "residentBytes" ? "peakResidentBytes" : "peakPhysicalFootprintBytes"
            let peaks = try cycles.map { cycle -> Int64 in
                guard let memory = cycle["memory"] as? [String: Any], let value = memory[peakKey] as? NSNumber else { throw failure("Missing sampled peak") }
                let rows = cycle["boundaries"] as? [[String: Any]] ?? []
                let boundaryPeaks = try rows.map { try scalar($0, key) }
                return max(value.int64Value, boundaryPeaks.max() ?? value.int64Value)
            }
            let late = Array(zip(endpoints.dropLast(), endpoints.dropFirst()).suffix(3)).map { $0.1 - $0.0 }
            let coldPeak = peaks.max()! - initial, coldFinal = end - initial, measuredGrowth = endpoints.last! - endpoints[1]
            let coldTargetMet = coldFinal <= Int64(2 * viewportBytes + 16 * 1_024 * 1_024)
            let peakTargetMet = coldPeak <= Int64(2 * outputBytes + 8 * viewportBytes + 16 * 1_024 * 1_024)
            let passed = measuredGrowth <= Int64(2 * viewportBytes)
                && late.allSatisfy { $0 <= Int64(viewportBytes) } && late.reduce(0, +) <= Int64(viewportBytes)
            result[key] = ["entry": initial, "settledEndpoints": endpoints, "final": end,
                "coldPeakGrowth": coldPeak, "coldFinalGrowth": coldFinal,
                "estimatedColdTargetMet": coldTargetMet, "estimatedPeakTargetMet": peakTargetMet,
                "coldAndPeakTargetsAreDiagnosticOnly": true,
                "measuredGrowth": measuredGrowth, "lateThreeIncrements": late, "warmAndLateGatePassed": passed]
            gatesPassed = gatesPassed && passed
        }
        let ledgers = try cycles.map { cycle -> Int64 in
            guard let boundaries = cycle["boundaries"] as? [[String: Any]],
                  let point = boundaries.first(where: { $0["phase"] as? String == "released-plus-150ms" }),
                  let backing = point["backing"] as? [String: Any], let purgeable = backing["purgeable"] as? [String: Any],
                  let ledger = purgeable["ledgerBytes"] as? [String: Any],
                  let resident = ledger["ledger_purgeable_volatile"] as? NSNumber,
                  let compressed = ledger["ledger_purgeable_volatile_compressed"] as? NSNumber else {
                throw failure("Missing combined volatile ledger endpoint")
            }
            let sum = resident.int64Value.addingReportingOverflow(compressed.int64Value)
            try require(!sum.overflow, "Volatile ledger sum overflow")
            return sum.partialValue
        }
        let late = Array(zip(ledgers.dropLast(), ledgers.dropFirst()).suffix(3)).map { $0.1 - $0.0 }
        let growth = ledgers.last! - ledgers[1]
        let passed = growth <= Int64(2 * viewportBytes) && late.allSatisfy { $0 <= Int64(viewportBytes) }
            && late.reduce(0, +) <= Int64(viewportBytes)
        result["combinedVolatileLedger"] = ["settledEndpoints": ledgers, "measuredGrowth": growth,
            "lateThreeIncrements": late, "passed": passed]
        result["warmAndLateGatesPassed"] = gatesPassed && passed
        result["coldAndPeakTargetsAreDiagnosticOnly"] = true
        return result
    }
    private static func scalar(_ boundary: [String: Any], _ key: String) throws -> Int64 {
        guard let memory = boundary["memory"] as? [String: Any], let value = memory[key] as? NSNumber,
              value.uint64Value <= UInt64(Int64.max) else { throw failure("Missing/invalid memory value") }
        return value.int64Value
    }

    // Preparation and full-pixel checks run only in separate certify/validate processes.
    static func prepareForVerification(_ url: URL) throws {
        try require(!FileManager.default.fileExists(atPath: url.path), "Prepared input already exists; do not overwrite it")
        try require(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]), "Cannot create fixture")
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        for y in 0..<finalHeight {
            var row = [UInt8](repeating: 255, count: width * 4)
            for x in 0..<width {
                var value = UInt64(y < header ? y + 1_000_000 : y - header + 10_000) &* 0x9e3779b185ebca87
                value ^= UInt64(x) &* 0xc2b2ae3d27d4eb4f; value ^= 7
                value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
                value = (value ^ (value >> 27)) &* 0x94d049bb133111eb; value ^= value >> 31
                let v = Int(value % 216 + 20)
                row[x * 4] = UInt8((v * 7) % 216 + 20)
                row[x * 4 + 1] = UInt8((v * 3) % 216 + 20)
                row[x * 4 + 2] = UInt8(v)
            }
            try handle.write(contentsOf: Data(row))
        }
        try handle.synchronize()
    }
    static func byteConversionFidelity(_ input: URL) async throws -> [String: Any] {
        guard let screen = NSScreen.main else { throw CaptureError.noDisplay }
        let ledger = LiveScrollResourceAllocationLedger()
        let source = try LiveScrollResourceFrameSource(input: input, screen: screen, ledger: ledger)
        try await source.start()
        do {
            guard let frame = try await source.nextFrame(timeout: 0.75) else { throw failure("Fidelity source returned no image") }
            let reference = try ManualScrollReusableObservation().withNormalizedPixels(frame.image) { Data($0) }
            let actual = try ManualScrollVImageObservation().withNormalizedPixels(frame.image) { Data($0) }
            try require(reference == actual && actual.count == viewportBytes, "Existing CGContext/vImage full-byte fidelity failed")
            let raw = try Data(contentsOf: input)
            for i in stride(from: 0, to: actual.count, by: 4) {
                try require(actual[i] == raw[i + 2] && actual[i + 1] == raw[i + 1]
                    && actual[i + 2] == raw[i] && actual[i + 3] == 255, "Owned source BGRA channel/row fidelity failed")
            }
        } catch { try? await source.stop(); throw error }
        try await source.stop()
        return ["passed": true, "bytesCompared": viewportBytes,
            "method": "Existing ManualScrollReusableObservation and ManualScrollVImageObservation every RGBA byte, plus independent prepared BGRA channel/row oracle"]
    }
    private static func writeReference(_ input: URL, to output: URL) throws {
        let data = try Data(contentsOf: input)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: finalHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw failure("Independent reference image construction failed")
        }
        try ScrollImageIO.writeBoundedPNG(image, to: output, maximumBytes: 512 * 1_024 * 1_024)
    }
    private static func verifyPNG(_ url: URL, input: URL) throws -> [String: Any] {
        let encodedBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        let identity = try digest(url)
        var proof: [String: Any] = ["passed": false, "pixelEquality": false, "file": url.lastPathComponent,
            "sha256": identity, "encodedBytes": encodedBytes, "hashAvailable": true,
            "expectedWidth": width, "expectedHeight": finalHeight]
        do {
            guard let reader = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(reader, 0, nil),
                  image.width == width, image.height == finalHeight else { throw failure("Output PNG is missing or has wrong dimensions") }
            let raw = try Data(contentsOf: input)
            try require(raw.count == outputBytes, "Oracle length changed")
            try ManualScrollVImageObservation().withNormalizedPixels(image) { bytes in
                try require(bytes.count == outputBytes, "Decoded output byte count changed")
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    try require(bytes[i] == raw[i + 2] && bytes[i + 1] == raw[i + 1]
                        && bytes[i + 2] == raw[i] && bytes[i + 3] == raw[i + 3], "Final PNG pixel differs from independent coordinate oracle")
                }
            }
            proof["passed"] = true; proof["pixelEquality"] = true; proof["comparedBytes"] = outputBytes
        } catch { proof["error"] = error.localizedDescription }
        return proof
    }
    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func findButton(_ identifier: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
        for child in view.subviews { if let found = findButton(identifier, in: child) { return found } }
        return nil
    }
    private static func readObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        try require(data.count <= 4 * 1_024 * 1_024, "Scalar report exceeded bound")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("Invalid scalar report") }
        return object
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw failure("Invalid scalar encoding") }
        return object
    }
    private static func write(_ report: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw failure(message) } }
    private static func failure(_ message: String) -> NSError { NSError(domain: "PicShot.LiveScrollResource", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
