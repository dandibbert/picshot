import Darwin
import Foundation

/// Explicit diagnostic-only runs. Each mode should be launched in a fresh app
/// process. This reports attribution observations, not replacement acceptance
/// gates, a leak diagnosis, or a claim that memory reaches a steady state.
enum GIFResourceAttributionFixture {
    enum Mode: String, CaseIterable, Sendable { case exportOnly = "export-only", decodeOnly = "decode-only" }
    enum Execution: String, CaseIterable, Sendable {
        case inProcessBaseline = "in-process-baseline"
        case isolatedHelper = "isolated-helper"
    }
    static let measuredCycles = 8

    /// Intended caller: the installed app's explicit diagnostic smoke branch.
    /// The returned JSON object can be written directly as its launch report.
    /// A mode-specific JSON file is also written, including partial failure data.
    static func verify(evidenceDirectory: URL, mode: Mode,
                       profile: GIFResourceSmokeFixture.Profile = .installedSmoke,
                       frameExtraction: GIFFrameExtraction = .asynchronous,
                       execution: Execution = .inProcessBaseline) async throws -> [String: Any] {
        guard evidenceDirectory.isFileURL, profile == .installedSmoke || profile == .quickTest else {
            throw failure("Unsupported diagnostic directory/profile")
        }
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let reportURL = evidenceDirectory.appendingPathComponent("gif-attribution-" + mode.rawValue + ".json")
        let directory = files.temporaryDirectory.appendingPathComponent("PicShot-GIF-Attribution-" + UUID().uuidString,
                                                                         isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var mayRemoveFixture = true
        defer { if mayRemoveFixture { try? files.removeItem(at: directory) } }
        let started = ProcessInfo.processInfo.systemUptime
        let invocations = GIFAttributionInvocations()
        var report: [String: Any] = [
            "status": "running", "diagnosticOnly": true, "mode": mode.rawValue, "profile": profile.name,
            "frameExtraction": frameExtraction.rawValue, "execution": execution.rawValue,
            "frameExtractionScope": "explicit diagnostic strategy; app default remains async-baseline; codec, timing, size limits and resource envelopes unchanged",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundlePath, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "captureStarted": false, "audioStarted": false, "externalDownloads": false,
            "measuredCycles": measuredCycles, "warmupCycles": 1,
            "sourceWidth": profile.width, "sourceHeight": profile.height, "sourceFrames": profile.frameCount,
            "sourceDurationSeconds": profile.duration, "outputMaximumDimension": profile.outputDimension,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval,
            "invocationScope": "counts track full GIF validations and explicitly selected direct-engine or process exports; AVFoundation video-frame decoding remains part of export",
            "memoryScope": "main-process RSS/footprint; isolated-helper mode additionally records child RSS/footprint and confirmed exit for every export; framework services/GPU/other helpers excluded; sampled maxima are not kernel peaks",
            "interpretation": "raw growth/interval observations only; no automatic leak or no-leak conclusion; normal GIF acceptance workload and limits are unchanged",
            "diskScope": "one authored MP4 plus at most one GIF; isolated-helper mode additionally uses one bounded private source copy and child staging until confirmed exit/cleanup; only JSON retained after confirmed fixture cleanup; abrupt termination or unconfirmed child exit can leave temporary media",
            "runtimeScope": "fixed operation counts and 90-second cooperative source-writer deadline; the diagnostic launcher must enforce its outer deadline and confirm process exit for synchronous framework stalls",
            "bookkeepingScope": "whole-process observations include eight small scalar report dictionaries and incremental JSON writes; no frame or encoded-GIF arrays are stored in reports",
            "temporaryDirectoryRemoved": false
        ]
        do {
            let source = try await GIFResourceSmokeFixture.makeMovie(in: directory, profile: profile)
            let sourceBytes = try byteCount(source)
            try require(sourceBytes > 0 && sourceBytes <= 16 * 1_024 * 1_024, "Synthetic source exceeded its disk budget")
            report["sourceBytes"] = sourceBytes
            let output = directory.appendingPathComponent("diagnostic.gif")
            let plan = try GIFFramePlan(duration: profile.duration, options: profile.options)

            // Export-only warm-up intentionally does NOT call ImageIO's decoder.
            // Decode-only also needs one preparatory strategy-selected export to obtain
            // an original input; it is excluded from decoder-cycle measurements.
            let preparation = try await export(source: source, output: output, profile: profile, frameExtraction: frameExtraction, execution: execution, invocations: invocations)
            report[mode == .exportOnly ? "exportWarmup" : "inputPreparationExport"] = preparation
            try require(try byteCount(output) <= GIFExporter.maximumOutputBytes, "GIF exceeded output budget")
            if mode == .exportOnly {
                try files.removeItem(at: output)
                try require(try names(directory) == [source.lastPathComponent], "Warm-up left staging/output files")
                try await settle()
                let baseline = try observedMemory()
                report["baselineAfterWarmup"] = try object(baseline)
                let decoderCallsBeforeCycles = invocations.snapshot().decodes
                report["decoderInvocationsBeforeMeasuredExports"] = decoderCallsBeforeCycles
                try require(decoderCallsBeforeCycles == 0, "GIF decoding contaminated export-only warm-up")
                var cycles: [[String: Any]] = []
                var settled: [GIFResourceMemoryReading] = []
                var peaks: [GIFResourceMemoryReading] = []
                for index in 0..<measuredCycles {
                    var run = try await export(source: source, output: output, profile: profile, frameExtraction: frameExtraction, execution: execution, invocations: invocations)
                    run["cycle"] = index + 1
                    let outputBytes = try byteCount(output)
                    try require(outputBytes > 0 && outputBytes <= GIFExporter.maximumOutputBytes, "Invalid output byte count")
                    run["outputBytes"] = outputBytes
                    // No opening, hashing, mapping or decoding the output here.
                    // File-size metadata and unlinking do not read its pixels.
                    let retained = index == measuredCycles - 1
                    if !retained { try files.removeItem(at: output) }
                    let expected: Set<String> = retained ? [source.lastPathComponent, output.lastPathComponent] : [source.lastPathComponent]
                    try require(try names(directory) == expected, "Export-only cycle left unexpected files")
                    run["outputRetainedForFinalValidation"] = retained
                    run["partialFilesRemaining"] = 0
                    try await settle()
                    let end = try observedMemory()
                    run["settledAfterOutputCleanup"] = try object(end)
                    settled.append(end); peaks.append(try peakReading(run))
                    cycles.append(run); report["cycles"] = cycles
                    try write(report, to: reportURL)
                }
                report["residentTrend"] = try object(GIFResourceObservationTrend(baseline: baseline.residentBytes,
                    settled: settled.map(\.residentBytes), peaks: peaks.map(\.residentBytes)))
                report["physicalFootprintTrend"] = try object(GIFResourceObservationTrend(baseline: baseline.physicalFootprintBytes,
                    settled: settled.map(\.physicalFootprintBytes), peaks: peaks.map(\.physicalFootprintBytes)))
                let decoderCallsDuringCycles = invocations.snapshot().decodes - decoderCallsBeforeCycles
                report["decoderInvocationsDuringMeasuredExports"] = decoderCallsDuringCycles
                try require(decoderCallsDuringCycles == 0, "GIF decoding contaminated export-only measurements")
                // Give delayed releases an additional, explicitly reported chance
                // to occur BEFORE the one and only GIF validation in this mode.
                try await Task.sleep(nanoseconds: 2_000_000_000)
                report["twoSecondsAfterExportSequenceBeforeValidation"] = try object(try observedMemory())
                report["finalValidation"] = try decode(output: output, profile: profile, plan: plan, invocations: invocations)
                report["decoderInvocationsAfterMeasuredExports"] = invocations.snapshot().decodes - decoderCallsBeforeCycles
                try files.removeItem(at: output)
                try await settle()
                report["afterFinalValidationAndRemoval"] = try object(try observedMemory())
                report["scope"] = "one export warm-up plus eight serial exports using the explicitly selected frameExtraction strategy; zero GIF decoder calls before/during those cycles, then one complete validation of the final file"
            } else {
                // The immutable file is opened afresh by each validation call.
                // No export, rewrite, rename, duplicate or unlink occurs between
                // decoder warm-up and the final decoder-cycle observation.
                let originalSize = try byteCount(output)
                report["immutableInputBytes"] = originalSize
                report["decoderWarmup"] = try decode(output: output, profile: profile, plan: plan, invocations: invocations)
                try await settle()
                let baseline = try observedMemory()
                report["baselineAfterWarmup"] = try object(baseline)
                let exportCallsBeforeCycles = invocations.snapshot().exports
                var cycles: [[String: Any]] = []
                var settled: [GIFResourceMemoryReading] = []
                var peaks: [GIFResourceMemoryReading] = []
                for index in 0..<measuredCycles {
                    var run = try decode(output: output, profile: profile, plan: plan, invocations: invocations)
                    run["cycle"] = index + 1
                    try require(try byteCount(output) == originalSize, "Read-only diagnostic input size changed")
                    try await settle()
                    let end = try observedMemory()
                    run["settledAfterDecode"] = try object(end)
                    settled.append(end); peaks.append(try peakReading(run))
                    cycles.append(run); report["cycles"] = cycles
                    try write(report, to: reportURL)
                }
                report["residentTrend"] = try object(GIFResourceObservationTrend(baseline: baseline.residentBytes,
                    settled: settled.map(\.residentBytes), peaks: peaks.map(\.residentBytes)))
                report["physicalFootprintTrend"] = try object(GIFResourceObservationTrend(baseline: baseline.physicalFootprintBytes,
                    settled: settled.map(\.physicalFootprintBytes), peaks: peaks.map(\.physicalFootprintBytes)))
                let exportsDuringDecodeCycles = invocations.snapshot().exports - exportCallsBeforeCycles
                report["exportsDuringMeasuredDecodeCycles"] = exportsDuringDecodeCycles
                try require(exportsDuringDecodeCycles == 0, "Exports contaminated decoder-only measurements")
                report["scope"] = "one preparatory export using the explicitly selected frameExtraction strategy, then decoder warm-up plus eight full sequential cache-disabled validations of the same immutable GIF; zero exports between decoder observations"
                report["sameFileCachingLimit"] = "same pathname/inode and bytes can reuse OS/framework caches; a flat result does not rule out per-new-file provider retention, changed-file caching, or cross-export decoder interaction"
                try files.removeItem(at: output)
                try await settle()
                report["afterInputRemoval"] = try object(try observedMemory())
            }
            try require(try names(directory) == [source.lastPathComponent], "Diagnostic left staging/output files")
            try files.removeItem(at: directory)
            try require(removalConfirmed(directory), "Diagnostic temporary directory cleanup not confirmed")
            report["temporaryDirectoryRemoved"] = true
            let calls = invocations.snapshot()
            report["totalExportInvocations"] = calls.exports
            report["totalGIFValidationInvocations"] = calls.decodes
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            report["status"] = "completed"
            try write(report, to: reportURL)
            return report
        } catch {
            if execution == .isolatedHelper {
                let snapshot = await GIFExporter.processResourceSnapshot()
                mayRemoveFixture = !snapshot.active
                report["latestGIFProcess"] = try? object(snapshot)
            }
            if mayRemoveFixture { try? files.removeItem(at: directory) }
            report["temporaryDirectoryRemoved"] = removalConfirmed(directory)
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try? write(report, to: reportURL)
            throw error
        }
    }

    /// The child task and exporter locals are out of scope before the caller's
    /// post-cleanup samples. Returned diagnostics contain only numbers/strings.
    private static func export(source: URL, output: URL,
                               profile: GIFResourceSmokeFixture.Profile, frameExtraction: GIFFrameExtraction,
                               execution: Execution, invocations: GIFAttributionInvocations) async throws -> [String: Any] {
        invocations.recordExport()
        let before = try observedMemory()
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        let progress = GIFAttributionProgress()
        let callback: @Sendable (Double) -> Void = { value in progress.record(value); sampler.sample() }
        let worker = Task {
            switch execution {
            case .inProcessBaseline:
                return try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: output,
                    options: profile.options, frameExtraction: frameExtraction, progress: callback)
            case .isolatedHelper:
                return try await GIFExporter.export(sourceURL: source, destinationURL: output,
                    options: profile.options, frameExtraction: frameExtraction, progress: callback)
            }
        }
        let exportedURL = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try require(exportedURL == output && progress.completed, "Selected export strategy/progress did not complete")
        sampler.stop()
        let statistics = sampler.snapshot()
        try require(statistics.residentSampleCount > 0, "No valid export RSS samples")
        var result: [String: Any] = ["before": try object(before), "immediatelyAfter": try object(try observedMemory()),
            "memory": try object(statistics), "progressCallbacks": progress.callbackCount,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started]
        if execution == .isolatedHelper {
            let snapshot = await GIFExporter.processResourceSnapshot()
            guard let job = snapshot.lastJob else { throw failure("Missing isolated GIF helper metrics") }
            try require(!snapshot.active && job.childLaunched && job.childExitConfirmed && job.temporaryDirectoryRemoved,
                        "Isolated GIF helper exit/admission/cleanup not confirmed")
            try require(job.childResidentSampleCount > 0 && job.childSampledPeakResidentBytes != nil,
                        "Isolated GIF helper RSS was not sampled")
            result["helperProcess"] = try object(job)
        }
        return result
    }

    private static func decode(output: URL, profile: GIFResourceSmokeFixture.Profile,
                               plan: GIFFramePlan, invocations: GIFAttributionInvocations) throws -> [String: Any] {
        invocations.recordDecode()
        let before = try observedMemory()
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        let validation = try GIFResourceSmokeFixture.validate(output: output, profile: profile, plan: plan)
        sampler.stop()
        let statistics = sampler.snapshot()
        try require(statistics.residentSampleCount > 0, "No valid decoder RSS samples")
        return ["before": try object(before), "immediatelyAfter": try object(try observedMemory()),
            "memory": try object(statistics), "output": validation,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started]
    }

    private static func settle() async throws { try await Task.sleep(nanoseconds: 600_000_000) }
    private static func observedMemory() throws -> GIFResourceMemoryReading {
        let value = GIFResourceMemoryReading.current()
        try require(value.residentBytes != nil, "Main-process RSS measurement unavailable")
        return value
    }
    private static func peakReading(_ run: [String: Any]) throws -> GIFResourceMemoryReading {
        guard let memory = run["memory"] as? [String: Any], let rss = memory["peakResidentBytes"] as? NSNumber else {
            throw failure("Missing sampled export/decoder RSS peak")
        }
        return GIFResourceMemoryReading(residentBytes: rss.uint64Value,
            physicalFootprintBytes: (memory["peakPhysicalFootprintBytes"] as? NSNumber)?.uint64Value)
    }
    private static func byteCount(_ url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw failure("File size unavailable") }
        return size
    }
    private static func names(_ url: URL) throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) }
    private static func removalConfirmed(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var information = stat()
            return lstat(path, &information) != 0 && errno == ENOENT
        }
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw failure("Invalid diagnostic object")
        }
        return result
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try autoreleasepool {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PicShot.GIFResourceAttribution", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// No threshold or leak verdict: preserve all intervals, including negative
/// growth, so a reviewer can distinguish rising, falling and flat observations.
struct GIFResourceObservationTrend: Encodable, Equatable, Sendable {
    let observationsComplete: Bool
    let settledBytes: [UInt64]?
    let intervalGrowthBytes: [Int64]?
    let finalGrowthBytes: Int64?
    let sampledPeakGrowthBytes: Int64?
    let lastFourObservationGrowthBytes: Int64?
    let settledRangeBytes: UInt64?

    init(baseline: UInt64?, settled: [UInt64?], peaks: [UInt64?]) {
        let ends = settled.compactMap { $0 }, maxima = peaks.compactMap { $0 }
        guard let baseline, baseline <= UInt64(Int64.max), !ends.isEmpty,
              ends.count == settled.count, maxima.count == peaks.count, peaks.count == settled.count,
              ends.allSatisfy({ $0 <= UInt64(Int64.max) }), maxima.allSatisfy({ $0 <= UInt64(Int64.max) }) else {
            observationsComplete = false; settledBytes = nil; intervalGrowthBytes = nil; finalGrowthBytes = nil
            sampledPeakGrowthBytes = nil; lastFourObservationGrowthBytes = nil; settledRangeBytes = nil; return
        }
        var previous = baseline
        var differences: [Int64] = []
        for value in ends { differences.append(Int64(value) - Int64(previous)); previous = value }
        observationsComplete = true; settledBytes = ends; intervalGrowthBytes = differences
        finalGrowthBytes = Int64(ends.last!) - Int64(baseline)
        sampledPeakGrowthBytes = Int64(maxima.max()!) - Int64(baseline)
        lastFourObservationGrowthBytes = ends.count >= 4 ? Int64(ends.last!) - Int64(ends[ends.count - 4]) : nil
        settledRangeBytes = ends.max()! - ends.min()!
    }
}

private final class GIFAttributionProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var last = 0.0
    private var valid = true
    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        if !value.isFinite || !(0...1).contains(value) || value < last || (callbacks == 0 && value != 0) { valid = false }
        last = value; callbacks += 1
    }
    var completed: Bool { lock.lock(); defer { lock.unlock() }; return valid && callbacks > 1 && last == 1 }
    var callbackCount: Int { lock.lock(); defer { lock.unlock() }; return callbacks }
}

private final class GIFAttributionInvocations: @unchecked Sendable {
    private let lock = NSLock()
    private var exports = 0
    private var decodes = 0
    func recordExport() { lock.lock(); defer { lock.unlock() }; exports += 1 }
    func recordDecode() { lock.lock(); defer { lock.unlock() }; decodes += 1 }
    func snapshot() -> (exports: Int, decodes: Int) { lock.lock(); defer { lock.unlock() }; return (exports, decodes) }
}
