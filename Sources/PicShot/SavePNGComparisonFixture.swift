import AppKit
import CryptoKit
import Darwin
import ImageIO
import PicShotCore
import UniformTypeIdentifiers

/// One matched Save-only comparison cell per fresh process. Source creation,
/// ordinary snapshotting, visible controller, writer, publication and drainage
/// are identical; only the init-only PNG preparation choice differs.
@MainActor
enum SavePNGComparisonFixture {
    static let protocolName = "save-png-comparison-v1"
    static let reportName = "save-png-comparison.json"
    static let validationName = "save-png-validation.json"
    private static let width = 3_840, height = 2_160, warmups = 2, measured = 8
    private static let seconds: Double = 300, validationSeconds: Double = 180, drainSeconds: Double = 4
    private static var claimed = false
    private enum Arm: String {
        case control, candidate
        var preparation: SavePNGPreparationMode { self == .control ? .legacyPreview : .encodedPayload }
    }

    static func runIfRequested(evidenceDirectory: URL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [String: Any]? {
        let prefix = "PICSHOT_SAVE_PNG_COMPARISON_"
        guard environment.keys.contains(where: { $0.hasPrefix(prefix) }) else { return nil }
        let mode = environment[prefix + "MODE"]
        let common: Set<String> = ["PICSHOT_SMOKE_TEST", "PICSHOT_SMOKE_REPORT", prefix + "MODE"]
        let expected = common.union(mode == "measure" ? [prefix + "ARM"] : [prefix + "INPUT_DIRECTORY"])
        guard !claimed, Set(environment.keys.filter { $0.hasPrefix("PICSHOT_") }) == expected,
              environment["PICSHOT_SMOKE_TEST"] == "1", environment["PICSHOT_SMOKE_REPORT"]?.isEmpty == false,
              mode == "measure" || mode == "validate", evidenceDirectory.isFileURL else {
            throw failure("An exclusive measure/control-or-candidate or separate validate request is required")
        }
        // V1 records the historical legacy default as a source invariant. Reject
        // both modes before claiming the fixture or emitting identity or outputs.
        guard SavePNGPreparationMode.productionDefault == .legacyPreview else {
            throw failure("Historical save-png-comparison-v1 requires the legacyPreview production default")
        }
        claimed = true
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        if mode == "validate" {
            guard let path = environment[prefix + "INPUT_DIRECTORY"], path.hasPrefix("/") else {
                throw failure("Validation needs an absolute matched-pair directory")
            }
            return try validate(input: URL(fileURLWithPath: path, isDirectory: true), evidence: evidenceDirectory)
        }
        guard let arm = environment[prefix + "ARM"].flatMap(Arm.init(rawValue:)) else { throw failure("Unknown arm") }
        return try await measure(arm: arm, directory: evidenceDirectory)
    }

    private static var options: [String: Any] {
        let value = ImageExportOptions()
        return ["format": value.format.filenameExtension, "quality": value.quality, "lossless": value.lossless,
                "preserveAlpha": value.preserveAlpha, "alphaQuality": value.alphaQuality,
                "paper": value.paper.rawValue, "orientation": value.orientation.rawValue,
                "margin": value.margin, "pagination": value.pagination.rawValue]
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
    private static func identity() -> [String: Any] {
        let limits = ImageExportLimits.standard
        return ["schemaVersion": 1, "protocol": protocolName,
         "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
         "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
         "executablePath": Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "",
         "processIdentifier": Int(getpid()), "architecture": architecture, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
         "sourceWidth": width, "sourceHeight": height, "options": options,
         "productionDefaultPNGPreparationMode": "legacyPreview", "productDefaultsChanged": false,
         "defaultsEvidenceScope": "source-review-invariant-not-runtime-default-observation",
         "productConfigurationScope": "Default mode is a reviewed source invariant, not a runtime workload result; limit values are read from ImageExportLimits.standard",
         "exportLimits": ["maximumSourcePixels": limits.maximumSourcePixels,
                          "maximumEncodedBytes": limits.maximumEncodedBytes, "maximumPages": limits.maximumPages,
                          "previewDimension": limits.previewDimension, "maximumPreviewBytes": limits.maximumPreviewBytes]]
    }

    private static func measure(arm: Arm, directory: URL) async throws -> [String: Any] {
        try require(architecture == "arm64", "This comparison authorizes only an ARM64 process pair")
        let began = uptime(), deadline = began + seconds
        let whole = GIFResourceMemorySampler(includeBacking: true)
        defer { whole.stop() }
        var report = identity()
        report.merge(["status": "running", "mode": "measure", "arm": arm.rawValue,
            "pngPreparationMode": arm == .control ? "legacyPreview" : "encodedPayload",
            "warmupCycles": warmups, "measuredCycles": measured, "maximumOutputs": warmups + measured,
            "beganUptimeSeconds": began,
            "entryScope": "Absolute entry VM and cumulative kernel peaks include earlier app startup; sampler begins before fixture setup/source creation, after selector parsing and evidence-directory creation. Launcher owns whole-process wall time",
            "cooperativeDeadlineSeconds": seconds, "nativeDrainDeadlineSeconds": drainSeconds,
            "outerDeadlineRequiredSeconds": 420, "productSaveTimeoutSeconds": 300,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval,
            "scope": "Actual visible SaveWorkflowPresenter/Controller fresh-image PNG jobs; same generated source per cycle, ordinary immutable snapshot, shared queue, verified exclusive writer, publication, native completion and close",
            "sourceScope": "One fresh generated 3840x2160 CGImage per cycle; provider bytes hashed through CodecStagingComparisonFixture.sourceIdentity without another raster draw. Source creation and hash costs are included in every sampled cycle, including cold warmups",
            "memoryScope": ImageBackingTaskVMReading.scope,
            "peakScope": "50ms sampled parent RSS/footprint/volatile peaks plus cumulative process kernel RSS/footprint peaks at every boundary; kernel peaks are not reset per cycle. No GPU or WindowServer attribution",
            "ownershipScope": "Weak source CGImage/controller/window/content observations after ordinary close and bounded native drain. No forced lifetime extension; weak release does not prove backing release",
            "bookkeepingScope": "Only scalar receipts retained. Receipt writes follow each cycle's final observation and sampler stop; whole-run sampling includes setup and receipt I/O",
            "afterPreparationScope": "Synchronous init-only diagnostic callback after the ordinary preparation await and snapshot release, before publication; captures scalars only and never suspends the queue",
            "interpretation": "Matched observations from a single process pair, not a pass/stability/leak/causality claim. Independent byte and full source-pixel validation runs only after both measured processes exit",
            "independentDecodes": 0, "extraReferenceRasterDraws": 0, "captureStarted": false,
            "networkAttempted": false, "userPreferencesRead": false, "generalPasteboardReadOrWritten": false,
            "warmups": [[String: Any]](), "cycles": [[String: Any]](), "observationFailures": [String]()
        ]) { _, new in new }
        let entry = ImageBackingMemoryReading.current()
        report["diagnosticEntryBacking"] = try object(entry)
        let reportURL = directory.appendingPathComponent(reportName)
        try write(report, to: reportURL)
        var failures = missing(entry).map { "entry: " + $0 }
        let files = FileManager.default, suite = "PicShot-Save-PNG-Comparison-" + UUID().uuidString
        var defaults: UserDefaults?, presenter: SaveWorkflowPresenter?
        let active = ActiveTrace()
        do {
            _ = NSApplication.shared
            try require(NSScreen.main != nil, "A native display is required for the actual visible Save controller")
            try require(ImageExportService.queue.operationCount == 0 && ImageExportController.activeSessionCount == 0,
                        "Other export work contaminated the fresh process")
            let output = directory.appendingPathComponent("outputs", isDirectory: true)
            // Exclusive creation prevents using a previous cell or unrelated files.
            try files.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let root = try SaveWorkflowUIPreviewFixture.canonicalExistingDirectory(output)
            guard let isolated = UserDefaults(suiteName: suite) else { throw failure("Isolated defaults unavailable") }
            defaults = isolated
            presenter = SaveWorkflowPresenter(defaults: isolated, pngPreparationMode: arm.preparation,
                afterPNGPreparationForDiagnostics: { active.value?.recordPreparation() })
            let setup = ImageBackingMemoryReading.current()
            report["afterSetupBacking"] = try object(setup)
            report["setupSeconds"] = uptime() - began
            report["outputsDirectory"] = "outputs"
            failures += missing(setup).map { "setup: " + $0 }
            let before = ImageBackingMemoryReading.current()
            report["backingBeforeWarmup"] = try object(before)
            failures += missing(before).map { "before-warmup: " + $0 }
            for ordinal in 0..<(warmups + measured) {
                try check(deadline)
                if ordinal == warmups {
                    let baseline = ImageBackingMemoryReading.current()
                    report["backingBaselineAfterWarmup"] = try object(baseline)
                    failures += missing(baseline).map { "warm-baseline: " + $0 }
                }
                let row = try await cycle(ordinal: ordinal, arm: arm, root: root, directory: directory,
                    defaults: isolated, presenter: presenter!, active: active, deadline: deadline)
                let key = ordinal < warmups ? "warmups" : "cycles"
                var rows = report[key] as? [[String: Any]] ?? []
                rows.append(row); report[key] = rows
                failures += (row["observationFailures"] as? [String] ?? ["missing per-cycle failure field"])
                    .map { "cycle \(ordinal + 1): " + $0 }
                report["completedCycles"] = ordinal + 1
                report["observationFailures"] = failures
                try write(report, to: reportURL)
                // The receipt and durable output precede any diagnostic assertion.
                // Missing memory fields still permit later cycles when ownership is safe.
                try require(row["workloadCompleted"] as? Bool == true, "Save workload failed; see preserved cycle receipt")
                try require(row["ownershipDrained"] as? Bool == true, "Save ownership did not drain; preserved outputs are retained")
            }
            let final = ImageBackingMemoryReading.current()
            report["backingFinal"] = try object(final)
            failures += missing(final).map { "final: " + $0 }
            try check(deadline); try await Task.sleep(nanoseconds: 500_000_000)
            await nativeYield()
            let late = ImageBackingMemoryReading.current()
            report["backingLate"] = try object(late); report["lateDelaySeconds"] = 0.5
            failures += missing(late).map { "late: " + $0 }
            whole.stop()
            report["wholeRunSampledMemory"] = try object(whole.snapshot())
            failures += missing(whole.snapshot()).map { "whole-run: " + $0 }
            report["activeJobsAfterAllCycles"] = presenter!.activeJobCount
            report["activeControllersAfterAllCycles"] = presenter!.controllers.count
            report["queuedOrRunningJobsAfterAllCycles"] = ImageExportService.queue.operationCount
            report["retainedInputBytesAfterAllCycles"] = presenter!.retainedInputBytes
            report["outputsPreserved"] = try files.contentsOfDirectory(atPath: root.path).sorted()
            report["observationFailures"] = failures
            report["status"] = failures.isEmpty ? "observed" : "failed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            // Cancel only fixture-owned jobs. Never remove the durable PNGs.
            presenter?.cancelAll()
            let until = min(deadline, uptime() + drainSeconds)
            while let owner = presenter, (owner.activeJobCount != 0 || !owner.controllers.isEmpty), uptime() < until {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            whole.stop(); report["wholeRunSampledMemory"] = try object(whole.snapshot())
        }
        active.value = nil
        let drained = (presenter?.activeJobCount ?? 0) == 0 && presenter?.controllers.isEmpty != false && ImageExportService.queue.operationCount == 0
        report["fixtureJobsDrained"] = drained
        if drained { defaults?.removePersistentDomain(forName: suite) }
        report["isolatedDefaultsRemoved"] = drained
        report["finishedUptimeSeconds"] = uptime()
        report["elapsedSeconds"] = uptime() - began
        if !drained { report["status"] = "failed"; report["cleanupError"] = "Owned jobs did not drain; defaults and outputs preserved" }
        try write(report, to: reportURL)
        return report
    }

    private static func cycle(ordinal: Int, arm: Arm, root: URL, directory: URL, defaults: UserDefaults,
                              presenter: SaveWorkflowPresenter, active: ActiveTrace, deadline: Double) async throws -> [String: Any] {
        let trace = CycleTrace(), probe = WeakOwners(), start = uptime()
        active.value = trace
        let sampler = GIFResourceMemorySampler(includeBacking: true)
        defer { sampler.stop(); active.value = nil }
        let stem = String(format: "cycle-%02d", ordinal + 1)
        var row: [String: Any] = ["schemaVersion": 1, "protocol": protocolName, "arm": arm.rawValue,
            "ordinal": ordinal + 1, "index": ordinal < warmups ? ordinal + 1 : ordinal - warmups + 1,
            "isWarmup": ordinal < warmups, "status": "running", "options": options,
            "outputFilename": "outputs/" + stem + ".png", "workloadCompleted": false,
            "independentDecodes": 0, "extraReferenceRasterDraws": 0]
        var errors: [String] = [], controller: SaveWorkflowController?
        func boundary(_ name: String) throws {
            let value = ImageBackingMemoryReading.current()
            row[name] = try object(value)
            errors += missing(value).map { name + ": " + $0 }
            var counts = row["queueCounts"] as? [String: Int] ?? [:]
            counts[name] = ImageExportService.queue.operationCount; row["queueCounts"] = counts
        }
        do {
            try boundary("entryBacking")
            try SaveWorkflowSettings(baseURL: root, filenameTemplate: stem).save(to: defaults)
            controller = try autoreleasepool {
                let sourceStarted = uptime()
                let image = try autoreleasepool { try CodecExportResourceFixture.fixture(width: width, height: height) }
                probe.source = image
                row["sourceCreateSeconds"] = uptime() - sourceStarted
                try boundary("afterSourceCreationBacking")
                let hashStarted = uptime()
                row["sourceSHA256"] = try autoreleasepool { try CodecStagingComparisonFixture.sourceIdentity(image) }
                row["sourceHashSeconds"] = uptime() - hashStarted
                try boundary("afterSourceHashBacking")
                let admitted = uptime(); trace.requested = admitted
                guard let job = presenter.save(image: image, copy: false, automatic: false, onSaved: { trace.recordSaved($0) }) else {
                    throw failure("Real Save presenter did not admit the generated image")
                }
                probe.controller = job; probe.window = job.window; probe.content = job.window?.contentView
                row["controllerCreationSeconds"] = uptime() - admitted
                row["nativeWindowVisibleAtAdmission"] = job.window?.isVisible == true
                row["reservedInputBytes"] = job.reservedInputBytes
                row["activeJobsAtAdmission"] = presenter.activeJobCount
                row["retainedInputBytesAtAdmission"] = presenter.retainedInputBytes
                return job
            }
            try boundary("afterControllerCreationBacking")
            while controller!.state != .completed && controller!.state != .failed && controller!.state != .closed {
                try check(deadline)
                controller!.window?.displayIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            controller!.window?.displayIfNeeded()
            row["terminalState"] = String(describing: controller!.state)
            row["nativeWindowVisibleAtCompletion"] = controller!.window?.isVisible == true
            row["jobDrainedAtCompletion"] = controller!.jobDrained
            row["activeJobsAtCompletion"] = presenter.activeJobCount
            try boundary("afterSaveBacking")
            if let saved = controller!.result {
                row["encodedBytes"] = saved.byteCount
                row["publishedFilenameMatches"] = saved.savedURL == root.appendingPathComponent(stem + ".png")
                row["clipboardNotRequested"] = saved.clipboardOutcome == .notRequested
            }
            row["workloadCompleted"] = controller!.state == .completed && trace.savedCount == 1 && controller!.result != nil
            if row["workloadCompleted"] as? Bool != true { errors.append("Save did not complete: " + controller!.detailLabel.stringValue) }
            // Exercise the ordinary native completion button, then discard the
            // fixture's final strong controller reference before native drainage.
            controller!.closeButton.performClick(nil)
            row["closedThroughNativeButton"] = controller!.state == .closed
            controller = nil
        } catch {
            errors.append(error.localizedDescription)
            controller?.cancel(); controller = nil
        }
        row["saveCallbackCount"] = trace.savedCount
        row["preparationCallbackCount"] = trace.preparedCount
        if let requested = trace.requested, let saved = trace.savedAt { row["saveLatencySeconds"] = saved - requested }
        else { row["saveLatencySeconds"] = NSNull(); errors.append("Save latency was not observed") }
        if let prepared = trace.prepared {
            row["afterPNGPreparationBacking"] = try object(prepared)
            errors += missing(prepared).map { "afterPNGPreparationBacking: " + $0 }
            row["requestToPreparedSeconds"] = trace.preparedAt.flatMap { at in trace.requested.map { (at - $0) as Any } } ?? NSNull()
            var counts = row["queueCounts"] as? [String: Int] ?? [:]
            counts["afterPNGPreparationBacking"] = trace.preparedQueueCount
            row["queueCounts"] = counts
        } else { row["afterPNGPreparationBacking"] = NSNull(); errors.append("Preparation boundary was not observed") }
        if trace.preparedCount != 1 { errors.append("Expected exactly one real preparation callback") }
        if trace.preparedQueueCount == nil { errors.append("Preparation queue count was not observed") }
        try boundary("afterCloseBacking")
        let drainStarted = uptime(), drainDeadline = min(deadline, drainStarted + drainSeconds)
        let initial = probe.facts
        // Yield through the existing main queue and autorelease-pool pattern;
        // no pressure, purge, queue suspension, or withExtendedLifetime is used.
        await nativeYield()
        while !(probe.released && presenter.activeJobCount == 0 && presenter.controllers.isEmpty && ImageExportService.queue.operationCount == 0), uptime() < drainDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await nativeYield()
        }
        let drained = probe.released && presenter.activeJobCount == 0 && presenter.controllers.isEmpty && ImageExportService.queue.operationCount == 0
        row["drain"] = ["initial": initial, "final": probe.facts, "elapsedSeconds": uptime() - drainStarted,
                         "maximumSeconds": drainSeconds, "activeJobs": presenter.activeJobCount,
                         "activeControllers": presenter.controllers.count, "retainedInputBytes": presenter.retainedInputBytes,
                         "queueCount": ImageExportService.queue.operationCount] as [String: Any]
        row["ownershipDrained"] = drained
        try boundary("settledBacking")
        sampler.stop(); row["sampledMemory"] = try object(sampler.snapshot())
        errors += missing(sampler.snapshot())
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            let expected = Set((1...(ordinal + 1)).map { String(format: "cycle-%02d.png", $0) })
            row["stagingEntries"] = names.filter { !expected.contains($0) }
            row["stagingCleanupConfirmed"] = Set(names) == expected
            if Set(names) != expected { errors.append("Output directory contains missing files or unremoved staging") }
        } catch { row["stagingEntries"] = NSNull(); row["stagingCleanupConfirmed"] = false; errors.append("Staging observation failed: " + error.localizedDescription) }
        if !drained { errors.append("Weak owners/jobs/queue retained after bounded native drain") }
        for key in ["nativeWindowVisibleAtAdmission", "nativeWindowVisibleAtCompletion", "closedThroughNativeButton", "publishedFilenameMatches", "clipboardNotRequested"] {
            if row[key] as? Bool != true { errors.append("Required native Save receipt missing/false: " + key) }
        }
        row["elapsedSeconds"] = uptime() - start; row["observationFailures"] = errors
        row["status"] = errors.isEmpty ? "observed" : "failed"
        try write(row, to: directory.appendingPathComponent("save-png-" + stem + ".json"))
        return row
    }

    /// Invoked only by a third fresh process after both measured producers exit.
    /// Decode/raster/hash work here is deliberately excluded from measurements.
    private static func validate(input: URL, evidence: URL) throws -> [String: Any] {
        let start = uptime(), deadline = start + validationSeconds
        var report = identity()
        report.merge(["mode": "validate", "status": "running", "measurementProcess": false,
                      "independentValidationProcess": true, "beganUptimeSeconds": start, "cooperativeDeadlineSeconds": validationSeconds,
                      "entries": [[String: Any]](),
                      "scope": "All twenty durable PNGs, independently decoded by ImageIO to full premultiplied RGBA8 sRGB and compared exactly to a separately regenerated canonical source; exact encoded bytes compared across arms"] ) { _, new in new }
        let destination = evidence.appendingPathComponent(validationName)
        try write(report, to: destination)
        do {
            let control = try readObject(input.appendingPathComponent("control/" + reportName))
            let candidate = try readObject(input.appendingPathComponent("candidate/" + reportName))
            var producerIDs: [Int32] = []
            for (name, manifest) in [("control", control), ("candidate", candidate)] {
                guard manifest["protocol"] as? String == protocolName, manifest["arm"] as? String == name,
                      manifest["sourceWidth"] as? Int == width, manifest["sourceHeight"] as? Int == height,
                      manifest["architecture"] as? String == "arm64", architecture == "arm64",
                      manifest["completedCycles"] as? Int == warmups + measured,
                      let rawPID = manifest["processIdentifier"] as? Int, let pid = Int32(exactly: rawPID), pid > 0, pid != getpid(),
                      let recordedOptions = manifest["options"] as? [String: Any], NSDictionary(dictionary: recordedOptions).isEqual(to: options) else {
                    throw failure("Invalid/incomplete matched producer manifest")
                }
                errno = 0
                try require(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "Measured producer has not exited")
                producerIDs.append(pid)
            }
            try require(producerIDs[0] != producerIDs[1], "Arms did not use distinct producer processes")
            guard let commit = control["sourceCommit"] as? String, !commit.isEmpty, commit != "unknown",
                  candidate["sourceCommit"] as? String == commit, report["sourceCommit"] as? String == commit else {
                throw failure("Producer/validator source identities differ")
            }
            guard let bundlePath = report["bundlePath"] as? String, let executablePath = report["executablePath"] as? String,
                  !bundlePath.isEmpty, !executablePath.isEmpty,
                  control["bundlePath"] as? String == bundlePath, candidate["bundlePath"] as? String == bundlePath,
                  control["executablePath"] as? String == executablePath, candidate["executablePath"] as? String == executablePath else {
                throw failure("Producer/validator canonical bundle or executable paths differ")
            }
            report["producerPIDs"] = producerIDs
            report["producerStatuses"] = [control["status"] as? String ?? "missing", candidate["status"] as? String ?? "missing"]
            let reference = try autoreleasepool { () throws -> (String, Data) in
                let image = try CodecExportResourceFixture.fixture(width: width, height: height)
                return (try CodecStagingComparisonFixture.sourceIdentity(image), try CodecExportResourceFixture.raster(image))
            }
            report["sourceSHA256"] = reference.0; report["canonicalSourceSHA256"] = digest(reference.1)
            var entries: [[String: Any]] = []
            for ordinal in 1...(warmups + measured) {
                try check(deadline)
                let stem = String(format: "cycle-%02d", ordinal)
                let paired = try autoreleasepool { () throws -> [[String: Any]] in
                    var results: [[String: Any]] = [], controlData: Data?
                    for arm in ["control", "candidate"] {
                        let cell = input.appendingPathComponent(arm, isDirectory: true)
                        let receipt = try readObject(cell.appendingPathComponent("save-png-" + stem + ".json"))
                        guard receipt["protocol"] as? String == protocolName, receipt["arm"] as? String == arm,
                              receipt["ordinal"] as? Int == ordinal,
                              receipt["sourceSHA256"] as? String == reference.0, receipt["workloadCompleted"] as? Bool == true,
                              let recordedOptions = receipt["options"] as? [String: Any], NSDictionary(dictionary: recordedOptions).isEqual(to: options) else {
                            throw failure("Cycle source/options/publication evidence missing")
                        }
                        let filename = "outputs/" + stem + ".png"
                        try require(receipt["outputFilename"] as? String == filename, "Cycle output name differs")
                        let data = try read(cell.appendingPathComponent(filename), maximum: ImageExportLimits.standard.maximumEncodedBytes)
                        try require(receipt["encodedBytes"] as? Int == data.count, "Published byte count differs from receipt")
                        if let controlData { try require(data == controlData, "Matched arms produced different exact PNG bytes") }
                        else { controlData = data }
                        try ImageExportService.verify(data: data, options: .init(), width: width, height: height, expectedPages: 1)
                        let image = try decodedPNG(data)
                        let actual = try CodecExportResourceFixture.raster(image)
                        try require(actual == reference.1, "Full canonical PNG pixels/alpha differ from generated source")
                        results.append(["arm": arm, "ordinal": ordinal, "filename": filename,
                                        "encodedBytes": data.count, "encodedSHA256": digest(data),
                                        "width": image.width, "height": image.height,
                                        "canonicalRGBABytes": actual.count, "canonicalRGBASHA256": digest(actual),
                                        "allSourcePixelsAndAlphaExactlyEqual": true, "exactPNGBytesEqualAcrossArms": true,
                                        "optionsVerified": true, "pngMetadataVerified": true])
                    }
                    return results
                }
                entries += paired; report["entries"] = entries
                try write(report, to: destination)
            }
            report["validatedOutputs"] = entries.count
            report["status"] = "validated"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        report["finishedUptimeSeconds"] = uptime()
        report["elapsedSeconds"] = uptime() - start
        try write(report, to: destination); return report
    }

    private static func decodedPNG(_ data: Data) throws -> CGImage {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height else { throw failure("Independent complete PNG decode/dimensions unavailable") }
        return image
    }
    private static func missing(_ value: ImageBackingMemoryReading) -> [String] {
        var absent: [String] = []
        if value.standard.kernelReturn != KERN_SUCCESS { absent.append("TASK_VM_INFO failed") }
        if value.purgeable.kernelReturn != KERN_SUCCESS { absent.append("TASK_VM_INFO_PURGEABLE failed") }
        for key in ["resident_size", "phys_footprint", "resident_size_peak"] where value.standard.bytes[key] == nil { absent.append("Missing " + key) }
        for key in ["purgeable_volatile_resident", "purgeable_volatile_virtual", "purgeable_volatile_pmap"] where value.purgeable.bytes[key] == nil { absent.append("Missing " + key) }
        if value.standard.ledgerBytes["ledger_phys_footprint_peak"] == nil { absent.append("Missing kernel footprint peak") }
        if value.purgeable.ledgerBytes["ledger_purgeable_volatile"] == nil { absent.append("Missing volatile ledger") }
        return absent
    }
    private static func missing(_ value: GIFResourceMemoryStatistics) -> [String] {
        var absent: [String] = []
        if value.timerTickCount == 0 { absent.append("No timer memory sample observed") }
        if value.residentSampleCount == 0 || value.peakResidentBytes == nil || value.failedResidentSampleCount != 0 { absent.append("Incomplete sampled RSS") }
        if value.physicalFootprintSampleCount == 0 || value.peakPhysicalFootprintBytes == nil || value.failedPhysicalFootprintSampleCount != 0 { absent.append("Incomplete sampled footprint") }
        if value.backingSampleCount == 0 || value.backingSampleCount != value.residentSampleCount || value.peakVolatileResidentBytes == nil || value.peakVolatileLedgerBytes == nil { absent.append("Incomplete sampled volatile backing") }
        return absent
    }
    private static func readObject(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: read(url, maximum: 4 * 1_024 * 1_024)) as? [String: Any] else { throw failure("Invalid JSON receipt") }
        return object
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= maximum else { throw failure("Evidence exceeds regular-file size bound") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: size + 1) ?? Data()
        try require(data.count == size, "Evidence changed while reading"); return data
    }
    private static func nativeYield() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { autoreleasepool { continuation.resume() } }
        }
        await Task.yield()
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw failure("Scalar receipt encoding failed") }; return object
    }
    private static func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try require(data.count <= 4 * 1_024 * 1_024, "Scalar report exceeded byte bound")
        try data.write(to: url, options: .atomic)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    private static func check(_ deadline: Double) throws { try Task.checkCancellation(); try require(uptime() < deadline, "Cooperative deadline exceeded") }
    private static func require(_ condition: Bool, _ text: String) throws { if !condition { throw failure(text) } }
    private static func failure(_ text: String) -> Error { PicShotError.message("Save PNG comparison: " + text) }

    @MainActor private final class ActiveTrace { var value: CycleTrace? }
    @MainActor private final class CycleTrace {
        var requested: Double?, preparedAt: Double?, savedAt: Double?
        var prepared: ImageBackingMemoryReading?, preparedQueueCount: Int?
        var preparedCount = 0, savedCount = 0
        func recordPreparation() {
            preparedCount += 1
            if prepared == nil { prepared = .current(); preparedAt = uptime(); preparedQueueCount = ImageExportService.queue.operationCount }
        }
        func recordSaved(_ saved: SaveWorkflowResult) { savedCount += 1; if savedAt == nil { savedAt = uptime() } }
    }
    @MainActor private final class WeakOwners {
        weak var source: CGImage?
        weak var controller: SaveWorkflowController?
        weak var window: NSWindow?
        weak var content: NSView?
        var facts: [String: Bool] { ["sourceReleased": source == nil, "controllerReleased": controller == nil,
                                   "windowReleased": window == nil, "contentReleased": content == nil] }
        var released: Bool { facts.values.allSatisfy { $0 } }
    }
}
