import AppKit
import CryptoKit
import Darwin
import Foundation
import PicShotCore

/// Diagnostic overlay: identical common code can run against pinned old/current
/// production implementations. No production lifetime or decoding policy changes.
@MainActor
enum ScrollMemoryAttributionFixture {
    enum Mode: String, CaseIterable, Sendable {
        case sourceCreate = "source-create", captureHash = "capture-hash", pngSpool = "png-spool"
        case stitchOverlap = "stitch-overlap", overview, detail, sharedAccept = "shared-accept"
        var needsInput: Bool { self == .stitchOverlap || self == .overview || self == .detail }
    }
    struct Profile: Sendable {
        let name: String, width: Int, height: Int, axis: ScrollAxis
        var step: Int { (axis == .vertical ? height : width) / 4 }
    }
    typealias DetailRenderer = @Sendable ([StoredScrollSource], ScrollSequenceLayout, ScrollAxis) throws -> [String: Int]
    nonisolated static let profiles: [Profile] = [
        Profile(name: "4k-vertical", width: 3840, height: 2160, axis: .vertical),
        Profile(name: "4k-horizontal", width: 3840, height: 2160, axis: .horizontal),
        Profile(name: "5k-vertical", width: 5120, height: 2880, axis: .vertical),
        Profile(name: "5k-horizontal", width: 5120, height: 2880, axis: .horizontal)
    ]
    nonisolated static let deadlineSeconds = 240.0
    nonisolated static let residentCeiling: UInt64 = 3 * 1024 * 1024 * 1024
    nonisolated static let footprintCeiling: UInt64 = 512 * 1024 * 1024
    nonisolated static let sourcesPerCycle = 4
    nonisolated static let manifestName = "scroll-memory-inputs.json"
    private static var claimed = false

    static func runIfRequested(evidenceDirectory: URL, detailRenderer: DetailRenderer? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [String: Any]? {
        guard let raw = environment["PICSHOT_SCROLL_ATTRIBUTION_MODE"] else { return nil }
        try require(!claimed, "Only one attribution invocation is permitted per fresh process")
        claimed = true
        let production = environment["PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT"] ?? ""
        let overlay = environment["PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT"] ?? ""
        try require(isCommit(production) && isCommit(overlay), "Exact production and overlay commit identities are required")
        let input = environment["PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        if raw == "prepare-inputs" {
            try require(input == nil, "Preparation does not accept an input directory")
            return try await prepare(evidenceDirectory, production: production, overlay: overlay)
        }
        guard let mode = Mode(rawValue: raw) else { throw failure("Unknown attribution mode") }
        try validate(mode: mode, input: input, detailAvailable: detailRenderer != nil)
        return try await verify(evidenceDirectory, mode: mode, input: input, detailRenderer: detailRenderer,
                                production: production, overlay: overlay)
    }

    nonisolated static func validate(mode: Mode, input: URL?, detailAvailable: Bool) throws {
        try require(mode.needsInput == (input != nil), "Only stitch/overview/detail require prepared input")
        try require(input?.isFileURL != false, "Inputs must be local files")
        try require(mode != .detail || detailAvailable, "This pinned production baseline has no detail renderer")
    }

    private static func identity(production: String, overlay: String) throws -> [String: Any] {
        guard let executable = Bundle.main.executableURL else { throw failure("Executable unavailable") }
        return ["schemaVersion": 1, "productionSourceCommit": production, "diagnosticOverlayCommit": overlay,
                "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
                "executableSHA256": try fileIdentity(executable)["sha256"]!, "bundlePath": Bundle.main.bundlePath,
                "processIdentifier": Int(getpid()), "architecture": architecture,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "buildMode": buildMode, "diagnosticOnly": true, "deliveredBinary": false]
    }

    private static func prepare(_ directory: URL, production: String, overlay: String) async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + deadlineSeconds
        var entries: [[String: Any]] = []
        for profile in profiles {
            for index in 0..<sourcesPerCycle {
                try checkDeadline(deadline)
                let url = directory.appendingPathComponent("\(profile.name)-\(index).png")
                try require(!FileManager.default.fileExists(atPath: url.path), "Preparation never overwrites inputs")
                let item = try await Task.detached(priority: .userInitiated) { () throws -> ScalarWork in
                    try autoreleasepool {
                        let image = try makeImage(width: profile.width, height: profile.height,
                                                  offset: 100 + index * profile.step, axis: profile.axis)
                        try ScrollImageIO.writeBoundedPNG(image, to: url, maximumBytes: 512 * 1024 * 1024)
                        var entry = try fileIdentity(url)
                        entry["profile"] = profile.name; entry["index"] = index
                        entry["width"] = profile.width; entry["height"] = profile.height
                        entry["sourceID"] = UUID().uuidString
                        return ScalarWork(value: entry)
                    }
                }.value
                entries.append(item.value)
            }
        }
        try checkDeadline(deadline)
        var report = try identity(production: production, overlay: overlay)
        report["status"] = "prepared"; report["mode"] = "prepare-inputs"; report["inputs"] = entries
        report["generator"] = "manual-procedural-v1-offset100-quarter-step-four-sources"
        report["cooperativeDeadlineSeconds"] = deadlineSeconds
        try write(report, directory.appendingPathComponent(manifestName))
        return report
    }

    private static func verify(_ directory: URL, mode: Mode, input: URL?, detailRenderer: DetailRenderer?,
                               production: String, overlay: String) async throws -> [String: Any] {
        _ = NSApplication.shared
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + deadlineSeconds
        let reportURL = directory.appendingPathComponent("scroll-memory-\(mode.rawValue).json")
        var report = try identity(production: production, overlay: overlay)
        report.merge([
            "mode": mode.rawValue, "status": "running", "separateProcessRequired": true,
            "warmupCycles": 8, "measuredCycles": 16, "sourcesPerCycle": sourcesPerCycle,
            "cooperativeDeadlineSeconds": deadlineSeconds, "outerDeadlineRequired": true,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval, "settlingDelaySeconds": 0.15,
            "sampledResidentCeilingBytes": residentCeiling, "sampledPhysicalFootprintCeilingBytes": footprintCeiling,
            "watchdogScope": "Parent polls the 50 ms sampler every 50 ms, cancels and drains one sequential cycle task on failure/ceiling/deadline; sampled observations are not allocation quotas or kernel lifetime peaks. Outer launcher must stop noncooperative native calls.",
            "backingAccountingScope": ImageBackingTaskVMReading.scope,
            "backingAccountingSampling": "Named boundaries only; separate from 50 ms RSS/footprint sampler",
            "purgeabilityInferredFromRSSFootprintGap": false, "zeroLeakClaim": false, "stabilityAssessed": false,
            "captureStarted": false, "permissionRequests": false, "globalInputPosted": false,
            "networkUsed": false, "memoryPressureOrSystemSettingsChanged": false, "allocatorPurgeAttempted": false,
            "scope": scope(mode), "maximumConcurrentWorkloadTasks": 1,
            "ownershipScope": "Scalar reports only. Lexical release and controller/spool cleanup do not identify framework backing ownership or prove reclaimability.",
            "endToEndFixtureUnchanged": true, "fullOutputRasters": 0,
            "operationCountsScope": "Explicit fixture operations; shared-accept counts its unchanged acceptance calls. Split cells use four accepted-equivalent viewports and omit the end-to-end loop rejection/pause/cancel and variable sampling."
        ]) { _, new in new }
        var warmups: [[String: Any]] = [], cycles: [[String: Any]] = []
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        do {
            let inputs = try input.map(validatedInputs) ?? [:]
            if let input {
                report["inputManifestSHA256"] = try fileIdentity(input.appendingPathComponent(manifestName))["sha256"]
                report["inputFileIdentities"] = try profiles.flatMap { profile in
                    try (inputs[profile.name] ?? []).map { try fileIdentity($0.url) }
                }
            }
            report["beforeWarmup"] = try memory()
            for repetition in 0..<6 {
                for (pindex, profile) in profiles.enumerated() {
                    try checkDeadline(deadline)
                    let phase = repetition < 2 ? "warmup" : "measured"
                    let index = (repetition < 2 ? repetition : repetition - 2) * profiles.count + pindex + 1
                    let before = try memory(), started = ProcessInfo.processInfo.systemUptime
                    let state = WorkState()
                    let worker = Task {
                        do {
                            if mode == .sharedAccept {
                                state.value = try await sharedAcceptance(profile, deadline: deadline)
                            } else {
                                let child = Task.detached(priority: .userInitiated) {
                                    try synchronousWork(mode, profile: profile, prepared: inputs[profile.name] ?? [],
                                                        detailRenderer: detailRenderer, deadline: deadline)
                                }
                                state.value = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
                            }
                        } catch { state.error = error }
                        state.completed = true
                    }
                    do {
                        while !state.completed {
                            try checkDeadline(deadline); try checkSamples(sampler.snapshot())
                            try await Task.sleep(nanoseconds: 50_000_000)
                        }
                        try checkSamples(sampler.snapshot())
                        if let error = state.error { throw error }
                    } catch {
                        worker.cancel(); await worker.value
                        throw error
                    }
                    guard var cycle = state.value?.value else { throw failure("Cycle returned no scalar report") }
                    state.value = nil
                    try await settle(deadline)
                    sampler.sample(); try checkSamples(sampler.snapshot())
                    cycle.merge(["profile": profile.name, "index": index, "phase": phase,
                        "width": profile.width, "height": profile.height, "axis": profile.axis.rawValue,
                        "rgbaReferenceBytes": profile.width * profile.height * 4, "before": before,
                        "settledAfterCleanup": try memory(), "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started]) { _, new in new }
                    if repetition < 2 { warmups.append(cycle) } else { cycles.append(cycle) }
                }
                if repetition == 1 { report["baselineAfterWarmup"] = try memory() }
            }
            report["afterCyclesBeforeInputRevalidation"] = try memory()
            if let input {
                _ = try validatedInputs(input)
                try require(try fileIdentity(input.appendingPathComponent(manifestName))["sha256"] as? String == report["inputManifestSHA256"] as? String,
                            "Prepared manifest changed")
            }
            try await settle(deadline)
            report["finalAfterCleanup"] = try memory(); sampler.stop()
            let stats = sampler.snapshot(); try checkSamples(stats)
            try require(stats.timerTickCount > 0 && stats.boundarySampleCount > 0, "Sampler did not observe both kinds of sample")
            report["sampledMemory"] = try object(stats)
            report["completedWarmupCycles"] = warmups.count; report["completedMeasuredCycles"] = cycles.count
            report["warmups"] = warmups; report["cycles"] = cycles
            report["observationsComplete"] = true; report["preparedInputsUnchanged"] = mode.needsInput
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try checkDeadline(deadline)
            report["status"] = "observed"
            try write(report, reportURL)
            return report
        } catch {
            report["status"] = "failed"; report["observationsComplete"] = false
            report["error"] = error.localizedDescription; report["warmups"] = warmups; report["cycles"] = cycles
            report["sampledMemory"] = try? object(sampler.snapshot())
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try? write(report, reportURL)
            throw error
        }
    }

    private final class WorkState { var completed = false; var value: ScalarWork?; var error: Error? }
    private struct ScalarWork: @unchecked Sendable { let value: [String: Any] }

    nonisolated private static func synchronousWork(_ mode: Mode, profile: Profile, prepared: [StoredScrollSource],
                                                    detailRenderer: DetailRenderer?, deadline: Double) throws -> ScalarWork {
        var phases: [[String: Any]] = []
        var sequence: ScrollCaptureSequence?, previous: ScrollFrame?
        var sourceCreates = 0, hashes = 0, writes = 0, matches = 0, overlaps = 0, overviews = 0, tiles = 0
        var spoolBytes: Int64 = 0
        let spool = mode == .pngSpool ? FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Scroll-Attribution-\(UUID().uuidString)") : nil
        if let spool { try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        defer { if let spool { try? FileManager.default.removeItem(at: spool) } }
        if mode.needsInput { try require(prepared.count == sourcesPerCycle, "Prepared source count differs") }
        for index in 0..<sourcesPerCycle {
            try checkDeadline(deadline); try Task.checkCancellation()
            var phase: [String: Any] = ["sourceIndex": index, "before": try memory()]
            try autoreleasepool {
                if mode == .overview || mode == .detail {
                    let stored = prepared[index]
                    if var current = sequence { _ = try current.accept(advance: profile.step, sourceID: stored.id); sequence = current }
                    else { sequence = try ScrollCaptureSequence(axis: profile.axis, width: profile.width, height: profile.height, sourceID: stored.id) }
                    if mode == .overview {
                        let image = try ScrollImageIO.sequenceThumbnail(Array(prepared.prefix(index + 1)), layout: sequence!.layout(), axis: profile.axis)
                        try require(image.width * image.height <= 800 * 800, "Overview bound exceeded")
                        phase["renderedPixels"] = image.width * image.height; overviews += 1
                    }
                } else {
                    let image = try makeImage(width: profile.width, height: profile.height, offset: 100 + index * profile.step, axis: profile.axis)
                    sourceCreates += 1; phase["afterSourceCreation"] = try withExtendedLifetime(image) { try memory() }
                    switch mode {
                    case .sourceCreate: break
                    case .captureHash:
                        let first = try rgbaHash(image), second = try rgbaHash(image)
                        try require(first == second, "Stable viewport hashes differ"); hashes += 2
                        phase["rgbaSHA256"] = first
                    case .pngSpool:
                        let url = spool!.appendingPathComponent("frame-\(index).png")
                        try ScrollImageIO.writeBoundedPNG(image, to: url, maximumBytes: 512 * 1024 * 1024 - spoolBytes)
                        let encoded = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                        try require(encoded > 0, "PNG spool is empty")
                        spoolBytes += encoded; phase["encodedBytes"] = encoded; writes += 1
                    case .stitchOverlap:
                        let gray = try ScrollImageIO.luminance(image)
                        if var current = sequence, let previous {
                            let match = try ScrollStitcher.matchBidirectional(previous: previous, next: gray, axis: profile.axis)
                            try require(match.advance == profile.step, "Matched advance differs from known fixture motion")
                            let old = current
                            _ = try current.accept(advance: match.advance, sourceID: prepared[index].id)
                            try ScrollImageIO.validateSequenceOverlap(gray, image: image, sequence: old,
                                viewportOffset: current.viewportOffset, sources: Array(prepared.prefix(index)))
                            sequence = current; matches += 1; overlaps += 1
                        } else { sequence = try ScrollCaptureSequence(axis: profile.axis, width: profile.width, height: profile.height, sourceID: prepared[index].id) }
                        previous = gray
                    default: throw failure("Unsupported synchronous mode")
                    }
                    phase["afterOperationWhileSourceAlive"] = try withExtendedLifetime(image) { try memory() }
                }
            }
            phase["afterPool"] = try memory(); phases.append(phase)
        }
        if mode == .detail {
            guard let sequence, let detailRenderer else { throw failure("Missing current detail adapter") }
            let before = try memory()
            let counts = try autoreleasepool { try detailRenderer(prepared, sequence.layout(), profile.axis) }
            tiles = counts["tiles"] ?? -1
            try require(tiles == 2, "Detail adapter did not render exactly two tiles")
            phases.append(["stage": "two-detail-tiles", "before": before, "afterPool": try memory(), "renderCounts": counts])
        }
        previous = nil; sequence = nil
        if let spool { try FileManager.default.removeItem(at: spool) }
        return ScalarWork(value: ["phases": phases, "sourceCreates": sourceCreates, "rgbaHashes": hashes,
            "pngWrites": writes, "matches": matches, "overlapValidations": overlaps, "overviewRenders": overviews,
            "detailRenders": tiles, "acceptedFrames": 0,
            "cleanup": ["fixtureSourceRasters": 0, "retainedGrayscaleFrames": 0, "spoolDirectories": spool.map { FileManager.default.fileExists(atPath: $0.path) ? 1 : 0 } ?? 0,
                        "controllers": 0, "activeWorkloadTasks": 0]])
    }

    private static func sharedAcceptance(_ profile: Profile, deadline: Double) async throws -> ScalarWork {
        var controller: ScrollCaptureController? = ScrollCaptureController { _ in }
        weak var weakController = controller
        var spool: URL?, phases: [[String: Any]] = []
        defer { controller?.close() }
        try await controller!.setAutoCropForVerification(false)
        for index in 0..<sourcesPerCycle {
            try checkDeadline(deadline); try Task.checkCancellation()
            let before = try memory()
            var image: CGImage? = try await createdSource(profile, index: index)
            let afterCreate = try memory()
            try require(try await controller!.acceptForVerification(image!, axis: profile.axis), "Shared accept rejected known source")
            image = nil
            spool = controller!.temporaryDirectoryForVerification
            try require(controller!.sourceURLsForVerification.count == index + 1, "Shared accepted source count differs")
            phases.append(["sourceIndex": index, "before": before, "afterSourceCreation": afterCreate,
                           "afterAcceptance": try memory(), "acceptedSources": index + 1])
        }
        controller?.close(); controller = nil
        while weakController != nil { try checkDeadline(deadline); try await Task.sleep(nanoseconds: 10_000_000) }
        try require(spool.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "Shared controller left source spool")
        return ScalarWork(value: ["phases": phases, "sourceCreates": 4, "rgbaHashes": 0, "pngWrites": 4,
            "matches": 3, "overlapValidations": 3, "overviewRenders": 4, "detailRenders": 0, "acceptedFrames": 4,
            "cleanup": ["fixtureSourceRasters": 0, "retainedGrayscaleFrames": 0, "spoolDirectories": 0,
                        "controllers": weakController == nil ? 0 : 1, "activeWorkloadTasks": 0],
            "sharedAcceptanceScope": "Real pinned controller accept and close; renderer operation counts describe accept's explicit calls, not asynchronous UI detail jobs"])
    }

    private static func createdSource(_ profile: Profile, index: Int) async throws -> CGImage {
        let child = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try makeImage(width: profile.width, height: profile.height, offset: 100 + index * profile.step, axis: profile.axis) }
        }
        return try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
    }

    nonisolated private static func validatedInputs(_ directory: URL) throws -> [String: [StoredScrollSource]] {
        let manifestURL = directory.appendingPathComponent(manifestName)
        let manifestBytes = (try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        try require(manifestBytes > 0 && manifestBytes <= 64 * 1024, "Input manifest too large or empty")
        let data = try Data(contentsOf: manifestURL)
        try require(data.count <= 64 * 1024, "Input manifest changed size")
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["status"] as? String == "prepared", let entries = manifest["inputs"] as? [[String: Any]], entries.count == 16 else { throw failure("Invalid prepared manifest") }
        var result: [String: [StoredScrollSource]] = [:], ids = Set<UUID>()
        for profile in profiles {
            var stored: [StoredScrollSource] = []
            for index in 0..<sourcesPerCycle {
                let expected = "\(profile.name)-\(index).png"
                let matches = entries.filter { $0["profile"] as? String == profile.name && $0["index"] as? Int == index }
                guard matches.count == 1, let entry = matches.first,
                      entry["name"] as? String == expected, entry["width"] as? Int == profile.width,
                      entry["height"] as? Int == profile.height, let uuid = entry["sourceID"] as? String,
                      let id = UUID(uuidString: uuid), ids.insert(id).inserted else { throw failure("Prepared profile metadata differs") }
                let url = directory.appendingPathComponent(expected), actual = try fileIdentity(url)
                try require(actual["sha256"] as? String == entry["sha256"] as? String && actual["bytes"] as? Int64 == (entry["bytes"] as? NSNumber)?.int64Value,
                            "Prepared image identity differs")
                let bytes = (actual["bytes"] as? Int64) ?? 0
                try require(bytes > 0 && bytes <= 512 * 1024 * 1024, "Prepared file limit exceeded")
                stored.append(StoredScrollSource(id: id, url: url, width: profile.width, height: profile.height, byteCount: bytes))
            }
            result[profile.name] = stored
        }
        return result
    }

    // Same original procedural pixels as the manual end-to-end fixture. This
    // overlay owns it so the old build does not gain a new production dependency.
    nonisolated static func makeImage(width: Int, height: Int, offset: Int, axis: ScrollAxis) throws -> CGImage {
        guard width > 0, height > 0, width <= ScrollFrame.maximumPixels / height else { throw ScrollStitchError.invalidPixels }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let cross = axis == .vertical ? x % 64 : 0
                let along = (axis == .vertical ? y : x) + offset
                var value = UInt64(cross) &* 0x9e3779b185ebca87 ^ UInt64(along) &* 0xc2b2ae3d27d4eb4f ^ 7
                value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
                value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
                value ^= value >> 31
                let sample = UInt8(value % 216 + 20), index = (y * width + x) * 4
                bytes[index] = sample; bytes[index + 1] = sample; bytes[index + 2] = sample
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScrollStitchError.invalidPixels }
        return image
    }

    // Same draw and SHA-256 row traversal as ManualScrollScreenDriver.observation.
    // This is an isolated diagnostic algorithm on baseline, not a shipped feature.
    nonisolated static func rgbaHash(_ image: CGImage) throws -> String {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= ScrollFrame.maximumDimension, height <= ScrollFrame.maximumDimension,
              width <= ScrollFrame.maximumPixels / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw ScrollStitchError.invalidPixels }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hash = SHA256()
        for start in stride(from: 0, to: height, by: 64) {
            try Task.checkCancellation()
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: data.advanced(by: start * width * 4), count: min(64, height - start) * width * 4))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func checkSamples(_ stats: GIFResourceMemoryStatistics) throws {
        let count = stats.timerTickCount + stats.boundarySampleCount
        try require(stats.failedResidentSampleCount == 0 && stats.failedPhysicalFootprintSampleCount == 0 &&
                    stats.residentSampleCount == count && stats.physicalFootprintSampleCount == count,
                    "Memory sampler has failed or missing observations")
        guard let rss = stats.peakResidentBytes, let footprint = stats.peakPhysicalFootprintBytes else { throw failure("Sampled peaks missing") }
        try require(rss <= residentCeiling && footprint <= footprintCeiling, "Sampled parent memory watchdog ceiling exceeded")
    }
    nonisolated private static func memory() throws -> [String: Any] {
        let sample = GIFResourceMemoryReading.current(), backing = ImageBackingMemoryReading.current()
        try require((sample.residentBytes ?? 0) > 0 && (sample.physicalFootprintBytes ?? 0) > 0 &&
                    backing.standard.kernelReturn == KERN_SUCCESS && backing.purgeable.kernelReturn == KERN_SUCCESS &&
                    backing.standard.bytes["resident_size"] != nil && backing.standard.bytes["phys_footprint"] != nil &&
                    backing.purgeable.ledgerBytes["ledger_purgeable_nonvolatile"] != nil &&
                    backing.purgeable.bytes["purgeable_volatile_resident"] != nil &&
                    backing.purgeable.bytes["purgeable_volatile_virtual"] != nil &&
                    backing.purgeable.bytes["purgeable_volatile_pmap"] != nil, "Memory/backing boundary unavailable")
        var result = try object(sample); result["backingAccounting"] = try object(backing)
        return result
    }
    nonisolated private static func fileIdentity(_ url: URL) throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data); bytes += Int64(data.count) }
        return ["name": url.lastPathComponent, "bytes": bytes, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()]
    }
    nonisolated private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw failure("Invalid scalar report object") }
        return result
    }
    nonisolated private static func write(_ report: [String: Any], _ url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try require(data.count <= 4 * 1024 * 1024, "Attribution scalar report exceeded 4 MiB")
        try data.write(to: url, options: .atomic)
    }
    nonisolated private static func isCommit(_ value: String) -> Bool { value.count == 40 && value.allSatisfy { $0.isHexDigit } }
    nonisolated private static func checkDeadline(_ deadline: Double) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Attribution 240-second cooperative deadline exceeded")
    }
    private static func settle(_ deadline: Double) async throws { try checkDeadline(deadline); try await Task.sleep(nanoseconds: 150_000_000); try checkDeadline(deadline) }
    nonisolated private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    nonisolated private static func failure(_ message: String) -> NSError { NSError(domain: "PicShot.ScrollMemoryAttribution", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    nonisolated private static func scope(_ mode: Mode) -> String {
        switch mode {
        case .sourceCreate: return "Four original procedural source viewports, sequentially released; no hash/encoder/decoder"
        case .captureHash: return "Same four source viewports, two identical full RGBA draw+hash observations each; no coordinator/spool/decoder"
        case .pngSpool: return "Same four source viewports plus production bounded PNG encoder; no image decoding or preview"
        case .stitchOverlap: return "Same four source viewports plus production luminance/match and stored-source full decode/color overlap validation; separately prepared immutable PNGs; no encoding/preview"
        case .overview: return "Four incremental production overview renders over 1/2/3/4 prepared sources (ten source decodes); no source generation/hash/encoding/overlap validation"
        case .detail: return "Current production renderer for two fixed beginning/end tile requests over four prepared sources; no source generation/hash/encoding/overlap/overview/UI job equivalence claim"
        case .sharedAccept: return "Each pinned production controller accepts four identical procedural viewports and closes; shared encode/overlap/overview path plus its own UI; no manual coordinator or hash"
        }
    }
    nonisolated private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    nonisolated private static var buildMode: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }
}
