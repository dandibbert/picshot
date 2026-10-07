import AppKit
import CryptoKit
import Darwin
import ImageIO
import PicShotCodecCore

/// One format and one workload per fresh app process. This is an observation,
/// not a leak detector, UI-lifetime test, or replacement for codec acceptance.
@MainActor
enum CodecExportAttributionFixture {
    enum Mode: String, CaseIterable, Sendable {
        case exportOnly = "export-only", decodeOnly = "decode-only", combined
    }
    enum Profile: String, CaseIterable, Sendable {
        case installed = "installed-768x576", quickTest = "unit-160x120"
        var width: Int { self == .installed ? 768 : 160 }
        var height: Int { width * 3 / 4 }
        var warmupCycles: Int { 2 }
        var measuredCycles: Int { self == .installed ? 12 : 3 }
        var deadlineSeconds: TimeInterval { self == .installed ? 480 : 90 }
    }
    // Reject accidentally mixing modes, formats, or preparation in one process.
    private static var invocationClaimed = false
    static let inputManifestName = "codec-attribution-inputs.json"

    /// SmokeVerification calls this before running any other codec fixture.
    /// The launcher must use a new process for preparation and every matrix cell.
    static func runIfRequested(evidenceDirectory: URL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [String: Any]? {
        if let report = try await ImageAllocatorReliefFixture.runIfRequested(evidenceDirectory: evidenceDirectory, environment: environment) {
            return report
        }
        if environment["PICSHOT_IMAGE_BACKING_MODE"] != nil {
            guard environment["PICSHOT_CODEC_ATTRIBUTION_MODE"] == nil else {
                throw failure("Image backing and codec attribution require separate fresh processes")
            }
            return try await ImageBackingAttributionFixture.runIfRequested(evidenceDirectory: evidenceDirectory, environment: environment)
        }
        guard let rawMode = environment["PICSHOT_CODEC_ATTRIBUTION_MODE"] else { return nil }
        guard let profile = Profile(rawValue: environment["PICSHOT_CODEC_ATTRIBUTION_PROFILE"] ?? Profile.installed.rawValue) else {
            throw failure("Unknown attribution profile")
        }
        if rawMode == "prepare-inputs" { return try await prepareInputs(evidenceDirectory: evidenceDirectory, profile: profile) }
        guard let mode = Mode(rawValue: rawMode),
              let format = format(environment["PICSHOT_CODEC_ATTRIBUTION_FORMAT"] ?? "") else {
            throw failure("Specify export-only, decode-only, or combined and webp or avif")
        }
        let input = environment["PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return try await verify(evidenceDirectory: evidenceDirectory, mode: mode, format: format,
                                profile: profile, inputDirectory: input)
    }

    static func prepareInputs(evidenceDirectory: URL, profile: Profile = .installed) async throws -> [String: Any] {
        try claimInvocation()
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for format in [ImageExportFormat.webp, .avif] {
            let source = try autoreleasepool { try CodecExportResourceFixture.fixture(width: profile.width, height: profile.height) }
            let snapshot = try autoreleasepool { try ImageExportSnapshot(image: source) }
            let artifact = try await ImageExportService.encodeBundled(snapshot: snapshot, options: options(format))
            let state = await CodecExportProcessService.shared.snapshot()
            let metrics = try finished(state)
            let destination = evidenceDirectory.appendingPathComponent(inputName(format))
            try autoreleasepool { try ImageExportService.publish(artifact, to: destination) }
            entries.append(["format": format.filenameExtension, "filename": destination.lastPathComponent,
                            "bytes": artifact.byteCount, "sha256": digest(artifact.data),
                            "sourceSHA256": try autoreleasepool { digest(try CodecExportResourceFixture.raster(source)) },
                            "helper": try object(metrics)])
        }
        let report: [String: Any] = ["status": "prepared", "mode": "prepare-inputs", "profile": profile.rawValue,
            "processIdentifier": Int(getpid()), "sourceCommit": sourceCommit,
            "sourceWidth": profile.width, "sourceHeight": profile.height, "inputs": entries,
            "syntheticSource": true, "captureStarted": false, "networkAttempted": false,
            "scope": "Original synthetic inputs made with the production signed helper in this separate process; no independent WebP/AVIF ImageIO validation"]
        try write(report, to: evidenceDirectory.appendingPathComponent(inputManifestName))
        return report
    }

    static func verify(evidenceDirectory: URL, mode: Mode, format: ImageExportFormat,
                       profile: Profile = .installed, inputDirectory: URL? = nil) async throws -> [String: Any] {
        try claimInvocation()
        guard evidenceDirectory.isFileURL, format == .webp || format == .avif,
              (mode == .decodeOnly) == (inputDirectory != nil) else { throw failure("Invalid mode, format, or input directory") }
        _ = NSApplication.shared
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let directory = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-Codec-Attribution-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // The helper only reads its own private staging copy. This directory
        // never contains any live helper's source or working directory.
        defer { try? files.removeItem(at: directory) }
        let reportURL = evidenceDirectory.appendingPathComponent("codec-attribution-\(format.filenameExtension)-\(mode.rawValue).json")
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + profile.deadlineSeconds
        var report: [String: Any] = [
            "status": "running", "diagnosticOnly": true, "mode": mode.rawValue, "format": format.filenameExtension,
            "profile": profile.rawValue, "processIdentifier": Int(getpid()), "sourceCommit": sourceCommit,
            "bundlePath": Bundle.main.bundlePath, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceWidth": profile.width, "sourceHeight": profile.height,
            "controllerCreationCount": 0, "separateProcessRequired": true,
            "warmupCycles": profile.warmupCycles, "measuredCycles": profile.measuredCycles,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval, "cooperativeDeadlineSeconds": profile.deadlineSeconds,
            "captureStarted": false, "networkAttempted": false, "dependenciesInstalled": false, "mockedCodec": false,
            "scope": "Production encodeBundled, signed codec helper, helper-derived preview, and exclusive same-byte publication; decode-only uses independently materialized ImageIO pixels from a separately prepared immutable input",
            "exportOnlyScope": "No independent WebP/AVIF ImageIO validation; production PNG source staging, its PNG preview, and helper-preview PNG decoding remain part of export",
            "memoryScope": "Parent Mach RSS and physical footprint sampled continuously at 50 ms plus named boundaries; excludes other processes, GPU, and WindowServer; sampled peaks can miss instantaneous peaks",
            "backingMemoryScope": ImageBackingTaskVMReading.scope,
            "controllerScope": "Service-level attribution matching CodecExportResourceFixture; zero export controllers created. Active controller counts detect contamination, not UI lifetime or all native allocations",
            "taskScope": "Fixture-created encoding tasks are awaited and leave scope before settling; production helper inactivity and shared OperationQueue emptiness checked separately, not a count of all runtime tasks",
            "bookkeepingScope": "Bounded scalar cycle records retained; no encoded bytes, images, or raster arrays in reports. Baseline reading objects serialize before cycles; successful-run cycle serialization and disk writes occur after final memory observations",
            "autoreleaseScope": "Synchronous source/snapshot, decode/materialization, publication and readback calls have explicit pools; async encoding runs through its unchanged production path and is awaited before main-queue drains",
            "interpretation": "Raw signed increments and boundary observations only; no automatic leak, plateau, no-leak, or maximum-size verdict",
            "outerDeadlineRequired": true, "temporaryDirectoryRemoved": false
        ]
        var cycles: [CodecAttributionCycle] = []
        cycles.reserveCapacity(profile.warmupCycles + profile.measuredCycles)
        let counters = CodecAttributionCounters()
        let wholeSampler = GIFResourceMemorySampler()
        defer { wholeSampler.stop() }
        do {
            let initialState = await CodecExportProcessService.shared.snapshot()
            try require(!initialState.active && initialState.lastJob == nil, "Codec work already occurred in this process")
            try await drain(deadline: deadline)
            let input = try inputDirectory.map { try validatedInput(directory: $0, format: format, profile: profile) }
            if let input {
                report["inputPreparationProcessIdentifier"] = input.producerPID
                report["immutableInputBytes"] = input.bytes; report["immutableInputSHA256"] = input.sha256
                report["sameInputCachingLimit"] = "Each cycle opens the same immutable bytes in a fresh ImageIO source and materializes all pixels. File/framework caching can differ from new bytes on every export"
            }
            let beforeWarmup = try observedMemory()
            report["beforeWarmup"] = try object(beforeWarmup)
            report["backingBeforeWarmup"] = try object(ImageBackingMemoryReading.current())
            for index in 1...profile.warmupCycles {
                cycles.append(try await cycle(index: index, isWarmup: true, mode: mode, format: format,
                    profile: profile, input: input, directory: directory, deadline: deadline, counters: counters))
            }
            let baseline = try observedMemory()
            report["baselineAfterWarmup"] = try object(baseline)
            report["backingBaselineAfterWarmup"] = try object(ImageBackingMemoryReading.current())
            for index in 1...profile.measuredCycles {
                cycles.append(try await cycle(index: index, isWarmup: false, mode: mode, format: format,
                    profile: profile, input: input, directory: directory, deadline: deadline, counters: counters))
            }
            // Delayed releases remain inside continuous sampling, before JSON.
            try await Task.sleep(nanoseconds: 500_000_000)
            try await drain(deadline: deadline)
            let delayedEnd = try observedMemory()
            report["backingHalfSecondAfterFinalCycle"] = try object(ImageBackingMemoryReading.current())
            wholeSampler.stop()
            let measured = cycles.filter { !$0.isWarmup }
            let ends = measured.map(\.settled)
            report["residentTrend"] = try object(CodecAttributionTrend(baseline: baseline.residentBytes,
                settled: ends.map(\.residentBytes), peaks: measured.map { $0.memory.peakResidentBytes }))
            report["physicalFootprintTrend"] = try object(CodecAttributionTrend(baseline: baseline.physicalFootprintBytes,
                settled: ends.map(\.physicalFootprintBytes), peaks: measured.map { $0.memory.peakPhysicalFootprintBytes }))
            report["wholeRunSampledMemory"] = try object(wholeSampler.snapshot())
            report["halfSecondAfterFinalCycle"] = try object(delayedEnd)
            report["warmups"] = try cycles.filter(\.isWarmup).map { try object($0) }
            report["cycles"] = try measured.map { try object($0) }
            report["totalExports"] = counters.exports; report["totalIndependentDecodes"] = counters.decodes
            report["fixtureEncodingTasksStarted"] = counters.startedTasks
            report["fixtureEncodingTasksCompleted"] = counters.completedTasks
            report["fixtureEncodingTasksActive"] = counters.activeTasks
            let expected = profile.warmupCycles + profile.measuredCycles
            try require(counters.exports == (mode == .decodeOnly ? 0 : expected) &&
                        counters.decodes == (mode == .exportOnly ? 0 : expected), "Workload boundary counts differ")
            try require(counters.activeTasks == 0 && counters.startedTasks == counters.completedTasks, "Fixture encoding task remains")
            if let input {
                try autoreleasepool {
                    let data = try boundedRead(input.url)
                    try require(data.count == input.bytes && digest(data) == input.sha256, "Read-only decoder input changed")
                }
                report["immutableInputUnchanged"] = true
            }
            try require(try files.contentsOfDirectory(atPath: directory.path).isEmpty, "Owned staging/output remains")
            try files.removeItem(at: directory)
            report["temporaryDirectoryRemoved"] = !files.fileExists(atPath: directory.path)
            report["activeControllersAfterAllCycles"] = ImageExportController.activeSessionCount
            report["queuedOrRunningJobsAfterAllCycles"] = ImageExportService.queue.operationCount
            report["status"] = "observed"; report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try write(report, to: reportURL)
            return report
        } catch {
            wholeSampler.stop()
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedCycles"] = try? cycles.map { try object($0) }
            report["lastProcess"] = try? object(await CodecExportProcessService.shared.snapshot())
            report["fixtureEncodingTasksActive"] = counters.activeTasks
            try? files.removeItem(at: directory)
            report["temporaryDirectoryRemoved"] = !files.fileExists(atPath: directory.path)
            try? write(report, to: reportURL)
            throw error
        }
    }

    private static func cycle(index: Int, isWarmup: Bool, mode: Mode, format: ImageExportFormat,
                              profile: Profile, input: CodecAttributionInput?, directory: URL,
                              deadline: TimeInterval, counters: CodecAttributionCounters) async throws -> CodecAttributionCycle {
        try check(deadline)
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        // Only scalars and a weak ownership witness cross this async scope.
        // Source/snapshot/encoded bytes/preview/data providers are dropped there.
        let result = try await workload(mode: mode, format: format, profile: profile, input: input,
                                        directory: directory, deadline: deadline, counters: counters, sampler: sampler)
        var boundaries = result.boundaries
        boundaries.append(try boundary("afterWorkloadScope", sampler: sampler))
        try await drain(deadline: deadline)
        var settledSamples: [GIFResourceMemoryReading] = []
        settledSamples.reserveCapacity(3)
        for _ in 0..<3 {
            try check(deadline)
            try await Task.sleep(nanoseconds: 60_000_000)
            try await mainQueueDrain()
            sampler.sample(); settledSamples.append(try observedMemory())
        }
        let state = await CodecExportProcessService.shared.snapshot()
        let ownedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).count
        try require(result.payload.value == nil && !state.active && ownedFiles == 0 &&
                    ImageExportController.activeSessionCount == 0 && ImageExportService.queue.operationCount == 0 &&
                    counters.activeTasks == 0, "Retained fixture payload, active service/task/controller/queue, or leftover output")
        let end = try observedMemory()
        boundaries.append(CodecAttributionBoundary(name: "afterMainQueueDrainAndSettling", memory: end))
        sampler.stop()
        let memory = sampler.snapshot()
        try require(memory.residentSampleCount > 0 && memory.physicalFootprintSampleCount > 0 && memory.timerTickCount > 0,
                    "Continuous RSS/footprint sampling is missing")
        return CodecAttributionCycle(index: index, isWarmup: isWarmup, boundaries: boundaries,
            memory: memory, settledSamples: settledSamples, settled: end, helper: result.helper,
            encodedBytes: result.encodedBytes, encodedSHA256: result.encodedSHA256, sourceSHA256: result.sourceSHA256, independentDecode: result.decode,
            sameByteSave: mode != .decodeOnly, payloadReleased: true, activeControllers: ImageExportController.activeSessionCount,
            queuedOrRunningJobs: ImageExportService.queue.operationCount, fixtureEncodingTasksActive: counters.activeTasks,
            helperActive: state.active, ownedTemporaryFiles: ownedFiles, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
    }

    private static func workload(mode: Mode, format: ImageExportFormat, profile: Profile, input: CodecAttributionInput?,
                                 directory: URL, deadline: TimeInterval, counters: CodecAttributionCounters,
                                 sampler: GIFResourceMemorySampler) async throws -> CodecAttributionWorkload {
        var boundaries: [CodecAttributionBoundary] = []
        boundaries.reserveCapacity(8)
        boundaries.append(try boundary("beforeSource", sampler: sampler))
        let source = try autoreleasepool { try CodecExportResourceFixture.fixture(width: profile.width, height: profile.height) }
        boundaries.append(try boundary("afterSyntheticSourceCreation", sampler: sampler))
        let sourceSHA256 = try autoreleasepool { digest(try CodecExportResourceFixture.raster(source)) }
        boundaries.append(try boundary("afterSourceRasterDigest", sampler: sampler))
        let payload = CodecAttributionPayload(source: source)
        let weak = CodecAttributionWeakPayload(payload)
        if mode != .decodeOnly { payload.snapshot = try autoreleasepool { try ImageExportSnapshot(image: source) } }
        boundaries.append(try boundary("afterSourceAndOptionalSnapshot", sampler: sampler))
        var helper: CodecExportProcessMetrics?
        if mode != .decodeOnly {
            try check(deadline)
            counters.exports += 1
            try await encode(payload: payload, format: format, counters: counters)
            boundaries.append(try boundary("afterProductionExportAndHelperExit", sampler: sampler))
            helper = try finished(await CodecExportProcessService.shared.snapshot())
        }
        let bytes: Int
        let encodedSHA256: String
        var decode: CodecAttributionDecode?
        if mode == .decodeOnly {
            guard let input else { throw failure("Decoder input unavailable") }
            payload.inputBytes = try autoreleasepool { try boundedRead(input.url) }
            bytes = payload.inputBytes!.count
            encodedSHA256 = autoreleasepool { digest(payload.inputBytes!) }
            try require(encodedSHA256 == input.sha256 && sourceSHA256 == input.sourceSHA256, "Immutable input or synthetic reference differs")
            boundaries.append(try boundary("afterImmutableEncodedInputRead", sampler: sampler))
            counters.decodes += 1
            decode = try decodeAndMaterialize(payload.inputBytes!, format: format, reference: source, sampler: sampler)
        } else {
            guard let artifact = payload.artifact, artifact.width == profile.width, artifact.height == profile.height,
                  artifact.byteCount > 0 else { throw failure("Wrong production artifact dimensions or bytes") }
            try CodecExportProcessService.validateMagic(artifact.data, format: format == .webp ? .webp : .avif)
            bytes = artifact.byteCount
            encodedSHA256 = autoreleasepool { digest(artifact.data) }
            if mode == .combined {
                counters.decodes += 1
                decode = try decodeAndMaterialize(artifact.data, format: format, reference: source, sampler: sampler)
            }
        }
        if let decode {
            boundaries.append(CodecAttributionBoundary(name: "independentDecodedPixelsLive", memory: decode.whilePixelsLive,
                                                        backing: decode.backingWhilePixelsLive))
            boundaries.append(try boundary("afterIndependentDecodeAutoreleasePool", sampler: sampler))
        }
        if let artifact = payload.artifact {
            let output = directory.appendingPathComponent("cycle." + format.filenameExtension)
            try autoreleasepool {
                try ImageExportService.publish(artifact, to: output)
                try require(try boundedRead(output) == artifact.data, "Published bytes differ from helper-derived preview bytes")
            }
            boundaries.append(try boundary("afterPublicationAndReadbackPool", sampler: sampler))
            try FileManager.default.removeItem(at: output)
            boundaries.append(try boundary("afterOutputUnlink", sampler: sampler))
        }
        return CodecAttributionWorkload(boundaries: boundaries, payload: weak, helper: helper, encodedBytes: bytes,
                                        encodedSHA256: encodedSHA256, sourceSHA256: sourceSHA256, decode: decode)
    }

    private static func encode(payload: CodecAttributionPayload, format: ImageExportFormat,
                               counters: CodecAttributionCounters) async throws {
        guard let snapshot = payload.snapshot else { throw failure("Missing owned snapshot") }
        counters.startedTasks += 1; counters.activeTasks += 1
        defer { counters.completedTasks += 1; counters.activeTasks -= 1 }
        let task = Task { try await ImageExportService.encodeBundled(snapshot: snapshot, options: options(format)) }
        payload.artifact = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func decodeAndMaterialize(_ data: Data, format: ImageExportFormat, reference: CGImage,
                                             sampler: GIFResourceMemorySampler) throws -> CodecAttributionDecode {
        try autoreleasepool {
            // Same ImageIO options as the existing acceptance fixture. Opening a
            // fresh source and rasterizing all pixels prevents lazy-decode-only evidence.
            let image = try CodecExportResourceFixture.independentDecode(data, format: format, width: reference.width, height: reference.height)
            let pixels = try CodecExportResourceFixture.raster(image)
            let expected = try CodecExportResourceFixture.raster(reference)
            try require(pixels.count == expected.count && zip(pixels, expected).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 },
                        "Lossless independently decoded pixels/alpha differ from original synthetic reference")
            sampler.sample()
            let memory = try observedMemory()
            let backing = ImageBackingMemoryReading.current()
            withExtendedLifetime((image, pixels, expected)) { }
            return CodecAttributionDecode(width: image.width, height: image.height, materializedBytes: pixels.count,
                                          allPixelsAndAlphaCompared: true, whilePixelsLive: memory, backingWhilePixelsLive: backing)
        }
    }

    private static func validatedInput(directory: URL, format: ImageExportFormat, profile: Profile) throws -> CodecAttributionInput {
        let manifest = try autoreleasepool { try JSONSerialization.jsonObject(with: boundedRead(directory.appendingPathComponent(inputManifestName))) as? [String: Any] }
        guard let manifest, manifest["status"] as? String == "prepared", manifest["syntheticSource"] as? Bool == true,
              manifest["profile"] as? String == profile.rawValue, manifest["sourceCommit"] as? String == sourceCommit,
              manifest["sourceWidth"] as? Int == profile.width, manifest["sourceHeight"] as? Int == profile.height,
              let pid = manifest["processIdentifier"] as? Int, pid != Int(getpid()),
              let entries = manifest["inputs"] as? [[String: Any]],
              let entry = entries.first(where: { $0["format"] as? String == format.filenameExtension }),
              entry["filename"] as? String == inputName(format), let bytes = entry["bytes"] as? Int,
              let sha = entry["sha256"] as? String, let sourceSHA = entry["sourceSHA256"] as? String else { throw failure("Decoder requires matching synthetic inputs from a separate preparation process") }
        let url = directory.appendingPathComponent(inputName(format))
        try autoreleasepool {
            let data = try boundedRead(url)
            try require(data.count == bytes && digest(data) == sha, "Prepared input size/hash differs")
            try CodecExportProcessService.validateMagic(data, format: format == .webp ? .webp : .avif)
        }
        return CodecAttributionInput(url: url, bytes: bytes, sha256: sha, sourceSHA256: sourceSHA, producerPID: pid)
    }
    private static func boundedRead(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw failure("Input must be local") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= 8 * 1_024 * 1_024 else { throw failure("Attribution input exceeds its 8 MiB regular-file limit") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: size + 1) ?? Data()
        try require(data.count == size, "Attribution input changed or exceeded its byte limit")
        return data
    }
    private static func finished(_ state: CodecExportProcessSnapshot) throws -> CodecExportProcessMetrics {
        guard !state.active, let m = state.lastJob, m.outcome == "succeeded", m.childLaunched,
              m.childExitConfirmed, m.terminationStatus == 0, m.temporaryDirectoryRemoved,
              m.parentResidentSampleCount > 0, m.parentPhysicalFootprintSampleCount > 0,
              m.childReportedResidentSampleCount > 0, m.childReportedPhysicalFootprintSampleCount > 0 else {
            throw failure("Actual signed helper exit, cleanup, or memory evidence missing")
        }
        // Parent-polled child samples can legitimately miss a very short child;
        // their absence remains nil/zero, never fabricated or silently replaced.
        return m
    }
    private static func drain(deadline: TimeInterval) async throws {
        while ImageExportService.queue.operationCount > 0 {
            try check(deadline); try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(deadline)
        try await mainQueueDrain()
        try require(ImageExportController.activeSessionCount == 0, "An export controller would contaminate service attribution")
    }
    private static func mainQueueDrain() async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { autoreleasepool { continuation.resume() } }
        }
        await Task.yield()
    }
    private static func boundary(_ name: String, sampler: GIFResourceMemorySampler) throws -> CodecAttributionBoundary {
        sampler.sample(); return CodecAttributionBoundary(name: name, memory: try observedMemory())
    }
    private static func observedMemory() throws -> GIFResourceMemoryReading {
        let reading = GIFResourceMemoryReading.current()
        try require(reading.residentBytes != nil && reading.physicalFootprintBytes != nil, "Mach RSS/physical footprint unavailable")
        return reading
    }
    private static func claimInvocation() throws {
        try require(!invocationClaimed, "Attribution modes, formats, and preparation require separate fresh app processes")
        invocationClaimed = true
    }
    private static func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Attribution cooperative deadline exceeded; launcher must bound native stalls")
    }
    private static func options(_ format: ImageExportFormat) -> ImageExportOptions {
        ImageExportOptions(format: format, quality: 0.81, lossless: true, preserveAlpha: true)
    }
    private static func format(_ raw: String) -> ImageExportFormat? { raw == "webp" ? .webp : raw == "avif" ? .avif : nil }
    private static func inputName(_ format: ImageExportFormat) -> String { "codec-attribution-input." + format.filenameExtension }
    private static var sourceCommit: String { Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown" }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw failure("Invalid evidence object") }
        return object
    }
    private static func write(_ value: [String: Any], to url: URL) throws {
        try autoreleasepool { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Codec attribution: " + message) }
}

private struct CodecAttributionInput { let url: URL; let bytes: Int; let sha256: String; let sourceSHA256: String; let producerPID: Int }
private struct CodecAttributionBoundary: Encodable {
    let name: String
    let memory: GIFResourceMemoryReading
    let backing: ImageBackingMemoryReading
    init(name: String, memory: GIFResourceMemoryReading, backing: ImageBackingMemoryReading = .current()) {
        self.name = name; self.memory = memory; self.backing = backing
    }
}
private struct CodecAttributionDecode: Encodable {
    let width: Int; let height: Int; let materializedBytes: Int; let allPixelsAndAlphaCompared: Bool
    let whilePixelsLive: GIFResourceMemoryReading
    let backingWhilePixelsLive: ImageBackingMemoryReading
}
private struct CodecAttributionCycle: Encodable {
    let index: Int; let isWarmup: Bool; let boundaries: [CodecAttributionBoundary]
    let memory: GIFResourceMemoryStatistics; let settledSamples: [GIFResourceMemoryReading]; let settled: GIFResourceMemoryReading
    let helper: CodecExportProcessMetrics?; let encodedBytes: Int; let encodedSHA256: String; let sourceSHA256: String; let independentDecode: CodecAttributionDecode?
    let sameByteSave: Bool; let payloadReleased: Bool; let activeControllers: Int; let queuedOrRunningJobs: Int
    let fixtureEncodingTasksActive: Int; let helperActive: Bool; let ownedTemporaryFiles: Int; let elapsedSeconds: TimeInterval
}
private struct CodecAttributionWorkload {
    let boundaries: [CodecAttributionBoundary]; let payload: CodecAttributionWeakPayload
    let helper: CodecExportProcessMetrics?; let encodedBytes: Int; let encodedSHA256: String; let sourceSHA256: String; let decode: CodecAttributionDecode?
}
@MainActor private final class CodecAttributionCounters {
    var exports = 0, decodes = 0, startedTasks = 0, completedTasks = 0, activeTasks = 0
}
private final class CodecAttributionPayload {
    let source: CGImage
    var snapshot: ImageExportSnapshot?; var artifact: ImageExportArtifact?; var inputBytes: Data?
    init(source: CGImage) { self.source = source }
}
private final class CodecAttributionWeakPayload {
    weak var value: CodecAttributionPayload?
    init(_ value: CodecAttributionPayload) { self.value = value }
}

/// Missing observations stay missing; negative growth stays negative. No gates,
/// extrapolation, or invented leak verdict from a short diagnostic workload.
struct CodecAttributionTrend: Encodable, Equatable {
    let observationsComplete: Bool
    let baselineBytes: UInt64?
    let endBytes: UInt64?
    let sampledPeakBytes: UInt64?
    let settledBytes: [UInt64]?
    let intervalGrowthBytes: [Int64]?
    let finalGrowthBytes: Int64?
    let sampledPeakGrowthBytes: Int64?
    let lastThreeIntervalGrowthBytes: [Int64]?
    let lastThreeIntervalsTotalGrowthBytes: Int64?

    init(baseline: UInt64?, settled: [UInt64?], peaks: [UInt64?]) {
        let ends = settled.compactMap { $0 }, maxima = peaks.compactMap { $0 }
        guard let baseline, baseline <= UInt64(Int64.max), !ends.isEmpty, ends.count == settled.count,
              maxima.count == peaks.count, maxima.count == ends.count,
              ends.allSatisfy({ $0 <= UInt64(Int64.max) }), maxima.allSatisfy({ $0 <= UInt64(Int64.max) }) else {
            observationsComplete = false; baselineBytes = nil; endBytes = nil; sampledPeakBytes = nil
            settledBytes = nil; intervalGrowthBytes = nil; finalGrowthBytes = nil; sampledPeakGrowthBytes = nil
            lastThreeIntervalGrowthBytes = nil; lastThreeIntervalsTotalGrowthBytes = nil; return
        }
        var previous = baseline
        var increments: [Int64] = []
        for end in ends { increments.append(Int64(end) - Int64(previous)); previous = end }
        observationsComplete = true; baselineBytes = baseline; endBytes = ends.last; sampledPeakBytes = maxima.max()
        settledBytes = ends; intervalGrowthBytes = increments
        finalGrowthBytes = Int64(ends.last!) - Int64(baseline)
        sampledPeakGrowthBytes = Int64(maxima.max()!) - Int64(baseline)
        lastThreeIntervalGrowthBytes = increments.count >= 3 ? Array(increments.suffix(3)) : nil
        let lateBaseline = ends.count > 3 ? ends[ends.count - 4] : baseline
        lastThreeIntervalsTotalGrowthBytes = ends.count >= 3 ? Int64(ends.last!) - Int64(lateBaseline) : nil
    }
}
