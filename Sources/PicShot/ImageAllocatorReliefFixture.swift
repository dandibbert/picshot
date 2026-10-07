import AppKit
import CryptoKit
import Darwin

/// Opt-in, self-process allocator experiment. Never called by normal image
/// export or by the ordinary backing matrix. No global pressure or VM purge.
@MainActor
enum ImageAllocatorReliefFixture {
    static let reportProtocol = "image-allocator-relief-v1"
    static let width = 768, height = 576, warmupCycles = 2, measuredCycles = 12
    static let goalBytes = 32 * 1_024 * 1_024
    static let cooperativeDeadlineSeconds: TimeInterval = 45
    static let requiredOuterDeadlineSeconds: TimeInterval = 60
    static let postObservationSeconds: [TimeInterval] = [0.5, 2]
    static let maximumInputBytes = 8 * 1_024 * 1_024
    static let maximumReportBytes = 1_024 * 1_024
    static let manifestName = "image-relief-input.json"
    private static var invocationClaimed = false

    enum Mode: String, CaseIterable, Sendable {
        case prepareInputs = "prepare-inputs", waitControl = "wait-control", allocatorRelief = "allocator-relief"
        var expectedReliefCalls: Int { self == .allocatorRelief ? 1 : 0 }
    }
    struct Request: Equatable {
        let mode: Mode
        let inputDirectory: URL?
    }

    static func request(environment: [String: String]) throws -> Request? {
        let prefix = "PICSHOT_IMAGE_RELIEF_"
        let supplied = Set(environment.keys.filter { $0.hasPrefix(prefix) })
        if supplied.isEmpty { return nil }
        let allowed: Set<String> = [prefix + "MODE", prefix + "INPUT_DIRECTORY"]
        try require(supplied.isSubset(of: allowed), "Unknown relief selector; dimensions, counts, goal, and deadlines cannot be overridden")
        guard let raw = environment[prefix + "MODE"], let mode = Mode(rawValue: raw) else {
            throw failure("Explicit prepare-inputs, wait-control, or allocator-relief mode required")
        }
        try require(environment["PICSHOT_IMAGE_BACKING_MODE"] == nil && environment["PICSHOT_CODEC_ATTRIBUTION_MODE"] == nil &&
                    environment["PICSHOT_GIF_DIAGNOSTIC_MODE"] == nil && environment["PICSHOT_UI_PREVIEW_ONLY"] != "1" &&
                    environment["PICSHOT_SMOKE_GIF_RESOURCES"] != "1", "Relief comparison requires a separate diagnostic process")
        let path = environment[prefix + "INPUT_DIRECTORY"]
        try require((mode != .prepareInputs) == (path != nil), "Only comparison arms require a separately prepared input directory")
        if let path { try require(path.hasPrefix("/") && !path.isEmpty, "Input directory must be an absolute local path") }
        return Request(mode: mode, inputDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    static func runIfRequested(evidenceDirectory: URL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [String: Any]? {
        guard let request = try request(environment: environment) else { return nil }
        try require(!invocationClaimed && evidenceDirectory.isFileURL, "One relief diagnostic per fresh process is required")
        invocationClaimed = true
        if request.mode == .prepareInputs { return try prepare(evidenceDirectory: evidenceDirectory) }
        return try await compare(request: request, evidenceDirectory: evidenceDirectory)
    }

    private static func prepare(evidenceDirectory: URL) throws -> [String: Any] {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let result: [String: Any] = try autoreleasepool {
            let source = try CodecExportResourceFixture.fixture(width: width, height: height)
            let snapshot = try ImageExportSnapshot(image: source)
            let artifact = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: .png))
            let pixels = try CodecExportResourceFixture.raster(artifact.firstPreview)
            let destination = evidenceDirectory.appendingPathComponent("image-relief-input.png")
            try ImageExportService.publish(artifact, to: destination)
            return ["protocol": reportProtocol, "status": "prepared", "mode": Mode.prepareInputs.rawValue,
                "sourceCommit": sourceCommit, "architecture": architecture, "processIdentifier": Int(getpid()), "syntheticSource": true,
                "sourceWidth": width, "sourceHeight": height, "format": "png", "filename": destination.lastPathComponent,
                "bytes": artifact.byteCount, "sha256": digest(artifact.data), "expectedPixelsSHA256": digest(pixels),
                "expectedRasterBytes": pixels.count, "reliefInvocationCount": 0,
                "captureStarted": false, "networkAttempted": false]
        }
        try write(result, to: evidenceDirectory.appendingPathComponent(manifestName))
        return result
    }

    private static func compare(request: Request, evidenceDirectory: URL) async throws -> [String: Any] {
        try require(request.mode != .prepareInputs && request.inputDirectory != nil, "Invalid comparison request")
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let output = evidenceDirectory.appendingPathComponent("image-relief-\(request.mode.rawValue).json")
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + cooperativeDeadlineSeconds
        var calls = 0
        var cycles: [ImageReliefCycle] = []
        var interventionEvidence: ImageReliefIntervention?
        var observations: [ImageReliefDelayedObservation] = []
        cycles.reserveCapacity(warmupCycles + measuredCycles)
        var report: [String: Any] = [
            "protocol": reportProtocol, "status": "running", "diagnosticOnly": true, "mode": request.mode.rawValue,
            "sourceCommit": sourceCommit, "architecture": architecture, "processIdentifier": Int(getpid()), "bundlePath": Bundle.main.bundlePath,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceWidth": width, "sourceHeight": height, "format": "png", "warmupCycles": warmupCycles,
            "measuredCycles": measuredCycles, "configuredGoalBytes": goalBytes,
            "cooperativeDeadlineSeconds": cooperativeDeadlineSeconds, "requiredOuterDeadlineSeconds": requiredOuterDeadlineSeconds,
            "postObservationSeconds": postObservationSeconds, "captureStarted": false, "networkAttempted": false,
            "scope": "Same immutable separately prepared PNG Data; unchanged production preview; no rasterization during the 2+12 accumulation cycles. All cycle image scopes and pools exit before intervention",
            "interventionScope": "One best-effort call across this process's malloc zones only, or zero calls in a fresh wait-control process. The 32 MiB goal is not a hard cap. No global pressure, VM purge, giant allocation, permission change, or retry loop",
            "invocationScope": "Counts cover fixture-initiated calls only; framework/OS automatic reclamation is not intercepted",
            "memoryScope": ImageBackingTaskVMReading.scope,
            "bookkeepingScope": "Bounded scalar records retained. Successful-run JSON serialization/writes occur after intervention observations and post-check. Reports themselves can contribute small accounting increments",
            "interpretation": "Raw allocator return and accounting observations only; no automatic reclaimed-preview, no-leak, plateau, or zero-cost verdict"
        ]
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        do {
            try await inactive(deadline: deadline)
            let state = await CodecExportProcessService.shared.snapshot()
            try require(state.lastJob == nil, "Codec helper work already occurred in this process")
            let input = try validatedInput(directory: request.inputDirectory!)
            report["inputPreparationProcessIdentifier"] = input.producerPID
            report["immutableInputSHA256"] = input.sha256
            report["immutableInputBytes"] = input.data.count
            // Encoded Data remains deliberately alive across both comparison arms.
            let beforeWarmup = try observed()
            for i in 1...warmupCycles { cycles.append(try await cycle(index: i, isWarmup: true, data: input.data, deadline: deadline)) }
            let baseline = try observed()
            for i in 1...measuredCycles { cycles.append(try await cycle(index: i, isWarmup: false, data: input.data, deadline: deadline)) }
            try await sleep(until: ProcessInfo.processInfo.systemUptime + 0.5, deadline: deadline)
            try await inactive(deadline: deadline)
            try require(cycles.count == warmupCycles + measuredCycles && calls == 0, "Intervention workload/count fence failed")
            let beforeIntervention = try observed()
            let callStart = ProcessInfo.processInfo.systemUptime
            let returnedBytes: UInt64?
            if request.mode == .allocatorRelief {
                // Public malloc/malloc.h API, available since macOS 10.7.
                // Uses Darwin's direct C import, not dlsym, a private symbol,
                // manually declared ABI, global pressure event, or VM purge.
                calls += 1
                returnedBytes = UInt64(malloc_zone_pressure_relief(nil, goalBytes))
            } else { returnedBytes = nil }
            let interventionEnd = ProcessInfo.processInfo.systemUptime
            // Preserve the API return even if a later deadline or observation
            // check fails. Failed Mach fields stay missing in this raw sample.
            let immediatelyAfter = ImageBackingMemoryReading.current()
            let intervention = ImageReliefIntervention(mode: request.mode.rawValue, invocationCount: calls,
                requestedGoalBytes: calls == 1 ? goalBytes : nil, apiReportedReleasedBytes: returnedBytes,
                callElapsedSeconds: interventionEnd - callStart, before: beforeIntervention, immediatelyAfter: immediatelyAfter)
            interventionEvidence = intervention
            try check(deadline)
            try require(immediatelyAfter.residentBytes != nil && immediatelyAfter.physicalFootprintBytes != nil,
                        "Post-intervention self Mach RSS/footprint unavailable")
            // Deadlines are relative to API/no-op completion, not cumulative waits.
            for offset in postObservationSeconds {
                try await sleep(until: interventionEnd + offset, deadline: deadline)
                try await inactive(deadline: deadline)
                observations.append(ImageReliefDelayedObservation(requestedSecondsAfterIntervention: offset,
                    actualSecondsAfterIntervention: ProcessInfo.processInfo.systemUptime - interventionEnd, memory: try observed()))
            }
            let beforePostCheck = try observed()
            sampler.stop()
            // Pixel materialization occurs only after both post-intervention
            // observations. Its cost is reported separately, never mixed into them.
            let validation = try autoreleasepool { try postCheck(data: input.data, expectedPixelsSHA256: input.pixelSHA256) }
            try await inactive(deadline: deadline)
            let afterPostCheck = try observed()
            try require(calls == request.mode.expectedReliefCalls, "Unexpected relief invocation count")
            try require(try digest(boundedRead(input.url, maximumBytes: maximumInputBytes)) == input.sha256, "Immutable PNG input changed")
            withExtendedLifetime(input) { }
            let measured = cycles.filter { !$0.isWarmup }
            report["beforeWarmup"] = try object(beforeWarmup)
            report["baselineAfterWarmup"] = try object(baseline)
            report["warmups"] = try cycles.filter(\.isWarmup).map { try object($0) }
            report["cycles"] = try measured.map { try object($0) }
            report["residentTrend"] = try object(CodecAttributionTrend(baseline: baseline.residentBytes,
                settled: measured.map { $0.settled.residentBytes }, peaks: measured.map { $0.memory.peakResidentBytes }))
            report["physicalFootprintTrend"] = try object(CodecAttributionTrend(baseline: baseline.physicalFootprintBytes,
                settled: measured.map { $0.settled.physicalFootprintBytes }, peaks: measured.map { $0.memory.peakPhysicalFootprintBytes }))
            report["intervention"] = try object(intervention)
            report["postInterventionObservations"] = try observations.map { try object($0) }
            report["memoryBeforeSubsequentPixelCheck"] = try object(beforePostCheck)
            report["subsequentPreviewAndPixels"] = try object(validation)
            report["memoryAfterSubsequentPixelCheck"] = try object(afterPostCheck)
            report["wholeRunSampledMemoryBeforePostCheck"] = try object(sampler.snapshot())
            report["completedAccumulationPreviews"] = cycles.count
            report["subsequentVerificationPreviews"] = 1
            report["reliefInvocationCount"] = calls
            report["helperInvocations"] = 0; report["ownedTemporaryMediaFiles"] = 0
            report["immutableInputUnchanged"] = true
            report["status"] = "observed"
            try check(deadline)
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try write(report, to: output)
            return report
        } catch {
            sampler.stop()
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["reliefInvocationCount"] = calls
            report["completedAccumulationPreviews"] = cycles.count
            report["completedCycles"] = try? cycles.map { try object($0) }
            if let interventionEvidence { report["intervention"] = try? object(interventionEvidence) }
            report["postInterventionObservations"] = try? observations.map { try object($0) }
            try? write(report, to: output)
            throw error
        }
    }

    private static func cycle(index: Int, isWarmup: Bool, data: Data, deadline: TimeInterval) async throws -> ImageReliefCycle {
        try await inactive(deadline: deadline)
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let before = try observed()
        let preview = try autoreleasepool { try previewObservation(data: data) }
        let afterPool = try observed()
        for _ in 0..<3 {
            try await sleep(until: ProcessInfo.processInfo.systemUptime + 0.06, deadline: deadline)
            try await inactive(deadline: deadline)
        }
        let settled = try observed()
        sampler.stop()
        return ImageReliefCycle(index: index, isWarmup: isWarmup, before: before, preview: preview,
            afterAutoreleasePool: afterPool, settled: settled, memory: sampler.snapshot(), fixtureScopeExited: true)
    }
    private static func previewObservation(data: Data) throws -> ImageReliefPreviewObservation {
        let start = ProcessInfo.processInfo.systemUptime
        let image = try ImageExportService.preview(data: data, format: .png)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try imageBounds(image)
        let live = try observed()
        withExtendedLifetime(image) { }
        return ImageReliefPreviewObservation(width: image.width, height: image.height, strideBytes: image.bytesPerRow * image.height,
            previewElapsedSeconds: elapsed, whileImageLive: live)
    }
    private static func postCheck(data: Data, expectedPixelsSHA256: String) throws -> ImageReliefPixelCheck {
        let start = ProcessInfo.processInfo.systemUptime
        let image = try ImageExportService.preview(data: data, format: .png)
        let previewSeconds = ProcessInfo.processInfo.systemUptime - start
        try imageBounds(image)
        let rasterStart = ProcessInfo.processInfo.systemUptime
        let pixels = try CodecExportResourceFixture.raster(image)
        let sha = digest(pixels)
        let rasterSeconds = ProcessInfo.processInfo.systemUptime - rasterStart
        try require(pixels.count == width * height * 4 && sha == expectedPixelsSHA256, "Subsequent PNG preview pixels changed")
        withExtendedLifetime((image, pixels)) { }
        return ImageReliefPixelCheck(width: image.width, height: image.height, rasterBytes: pixels.count,
            pixelsSHA256: sha, exactPixelsMatch: true, previewElapsedSeconds: previewSeconds,
            rasterAndDigestElapsedSeconds: rasterSeconds)
    }
    private static func imageBounds(_ image: CGImage) throws {
        try require(image.width == width && image.height == height && image.bytesPerRow <= ImageExportLimits.standard.maximumPreviewBytes / image.height,
                    "PNG preview dimensions/4 MiB stride limit changed")
    }
    private static func validatedInput(directory: URL) throws -> ImageReliefInput {
        try autoreleasepool {
            guard let m = try JSONSerialization.jsonObject(with: boundedRead(directory.appendingPathComponent(manifestName), maximumBytes: 32 * 1_024)) as? [String: Any],
                  m["protocol"] as? String == reportProtocol, m["status"] as? String == "prepared",
                  m["syntheticSource"] as? Bool == true, m["format"] as? String == "png", m["sourceCommit"] as? String == sourceCommit,
                  m["architecture"] as? String == architecture,
                  m["sourceWidth"] as? Int == width, m["sourceHeight"] as? Int == height,
                  m["filename"] as? String == "image-relief-input.png", let count = m["bytes"] as? Int,
                  let sha = m["sha256"] as? String, sha.count == 64,
                  let pixelSHA = m["expectedPixelsSHA256"] as? String, pixelSHA.count == 64,
                  m["expectedRasterBytes"] as? Int == width * height * 4,
                  let pid = m["processIdentifier"] as? Int, pid != Int(getpid()) else { throw failure("Matching separate-process synthetic PNG input required") }
            let url = directory.appendingPathComponent("image-relief-input.png")
            let data = try boundedRead(url, maximumBytes: maximumInputBytes)
            try require(data.count == count && digest(data) == sha, "Prepared PNG input size/hash differs")
            return ImageReliefInput(url: url, data: data, sha256: sha, pixelSHA256: pixelSHA, producerPID: pid)
        }
    }
    private static func boundedRead(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count > 0, count <= maximumBytes else { throw failure("Invalid bounded local input") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: count + 1) ?? Data()
        try require(data.count == count, "Input changed during bounded read")
        return data
    }
    private static func inactive(deadline: TimeInterval) async throws {
        try check(deadline)
        try require(ImageExportController.activeSessionCount == 0 && ImageExportService.queue.operationCount == 0,
                    "Active export controller/queue contaminates comparison")
        let helper = await CodecExportProcessService.shared.snapshot()
        try require(!helper.active && helper.lastJob == nil, "Helper work contaminates self-only comparison")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { autoreleasepool { continuation.resume() } }
        }
        await Task.yield()
        try check(deadline)
    }
    private static func sleep(until target: TimeInterval, deadline: TimeInterval) async throws {
        try check(deadline)
        try require(target <= deadline, "Observation would exceed cooperative deadline")
        let remaining = max(0, target - ProcessInfo.processInfo.systemUptime)
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        try check(deadline)
    }
    private static func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "45-second cooperative deadline exceeded; outer launcher must bound native stalls")
    }
    private static func observed() throws -> ImageBackingMemoryReading {
        let value = ImageBackingMemoryReading.current()
        try require(value.residentBytes != nil && value.physicalFootprintBytes != nil, "Self Mach RSS/footprint unavailable")
        return value
    }
    private static var sourceCommit: String { Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown" }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw failure("Invalid evidence object") }
        return value
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try autoreleasepool {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try require(data.count <= maximumReportBytes, "Diagnostic metadata exceeded 1 MiB")
            try data.write(to: url, options: .atomic)
        }
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Image allocator relief: " + message) }
}

struct ImageReliefIntervention: Encodable {
    let mode: String
    let invocationCount: Int
    let requestedGoalBytes: Int?
    let apiReportedReleasedBytes: UInt64?
    let callElapsedSeconds: TimeInterval
    let before: ImageBackingMemoryReading
    let immediatelyAfter: ImageBackingMemoryReading
}
private struct ImageReliefInput { let url: URL; let data: Data; let sha256: String; let pixelSHA256: String; let producerPID: Int }
private struct ImageReliefPreviewObservation: Encodable {
    let width: Int, height: Int, strideBytes: Int
    let previewElapsedSeconds: TimeInterval
    let whileImageLive: ImageBackingMemoryReading
}
private struct ImageReliefCycle: Encodable {
    let index: Int
    let isWarmup: Bool
    let before: ImageBackingMemoryReading
    let preview: ImageReliefPreviewObservation
    let afterAutoreleasePool: ImageBackingMemoryReading
    let settled: ImageBackingMemoryReading
    let memory: GIFResourceMemoryStatistics
    let fixtureScopeExited: Bool
}
private struct ImageReliefDelayedObservation: Encodable {
    let requestedSecondsAfterIntervention: TimeInterval
    let actualSecondsAfterIntervention: TimeInterval
    let memory: ImageBackingMemoryReading
}
private struct ImageReliefPixelCheck: Encodable {
    let width: Int, height: Int, rasterBytes: Int
    let pixelsSHA256: String
    let exactPixelsMatch: Bool
    let previewElapsedSeconds: TimeInterval
    let rasterAndDigestElapsedSeconds: TimeInterval
}
