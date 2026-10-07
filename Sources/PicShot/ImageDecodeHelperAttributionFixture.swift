import AppKit
import Foundation
import PicShotCodecCore

@MainActor
enum ImageDecodeHelperAttributionFixture {
    static let reportProtocol = "image-decode-helper-parent-v1"
    enum Mode: String, CaseIterable, Equatable { case productionControl = "production-control", isolatedDecode = "isolated-decode", cancelAfterDecode = "cancel-after-decode", timeoutAfterDecode = "timeout-after-decode" }
    struct Request: Equatable { let mode: Mode; let directory: URL }
    private static var claimed = false
    static func request(environment: [String: String]) throws -> Request? {
        let prefix = "PICSHOT_IMAGE_DRAW_HELPER_", keys = Set(environment.keys.filter { $0.hasPrefix(prefix) })
        if keys.isEmpty { return nil }
        guard keys == [prefix + "MODE", prefix + "INPUT_DIRECTORY"],
              let mode = environment[prefix + "MODE"].flatMap(Mode.init(rawValue:)),
              let path = environment[prefix + "INPUT_DIRECTORY"], path.hasPrefix("/"),
              !environment.keys.contains(where: { $0.hasPrefix("PICSHOT_IMAGE_DRAW_") && !$0.hasPrefix(prefix) }),
              environment["PICSHOT_IMAGE_RELIEF_MODE"] == nil, environment["PICSHOT_IMAGE_BACKING_MODE"] == nil,
              environment["PICSHOT_CODEC_ATTRIBUTION_MODE"] == nil, environment["PICSHOT_GIF_DIAGNOSTIC_MODE"] == nil,
              environment["PICSHOT_UI_PREVIEW_ONLY"] != "1", environment["PICSHOT_SMOKE_GIF_RESOURCES"] != "1"
        else { throw ImageDecodeDiagnosticError.invalidProtocol }
        return Request(mode: mode, directory: URL(fileURLWithPath: path, isDirectory: true))
    }
    static func runIfRequested(evidenceDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [String: Any]? {
        guard let request = try request(environment: environment) else { return nil }
        guard !claimed else { throw ImageDecodeDiagnosticError.invalidProtocol }; claimed = true
        return try await run(request, evidenceDirectory: evidenceDirectory)
    }
    private static func run(_ request: Request, evidenceDirectory: URL) async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + ImageDecodeDiagnosticLimits.armSeconds
        let measured = request.mode == .productionControl || request.mode == .isolatedDecode
        let destinationTracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: ImageDecodeDiagnosticLimits.rasterBytes)
        let providers = ImageDrawAllocationTracker(maximumAllocations: 14, allocationBytes: ImageDecodeDiagnosticLimits.rasterBytes)
        var destination: ImageDrawDestination?
        defer { destination?.close() }
        let sampler = ImageDecodeMemorySampler(); defer { sampler.stop() }
        var report: [String: Any] = ["protocol": reportProtocol, "status": "running", "mode": request.mode.rawValue,
            "sourceCommit": sourceCommit, "architecture": architecture, "processIdentifier": Int(getpid()),
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "diagnosticOnly": true,
            "sourceWidth": 768, "sourceHeight": 576, "rasterBytes": ImageDecodeDiagnosticLimits.rasterBytes,
            "warmupCycles": measured ? 2 : 0, "measuredCycles": measured ? 12 : 0, "oneShotProbe": !measured,
            "pixelTolerance": 0, "maximumChildConcurrency": 1, "maximumEncodedBytes": ImageDecodeDiagnosticLimits.pngBytes,
            "childWorkDeadlineSeconds": ImageDecodeDiagnosticLimits.childWorkSeconds, "childHardDeadlineSeconds": ImageDecodeDiagnosticLimits.childHardSeconds,
            "childExitDeadlineSeconds": ImageDecodeDiagnosticLimits.exitSeconds, "armDeadlineSeconds": ImageDecodeDiagnosticLimits.armSeconds,
            "requiredOuterDeadlineSeconds": ImageDecodeDiagnosticLimits.outerSeconds,
            "captureStarted": false, "networkAttempted": false, "allocatorReliefCalls": 0,
            "inputScope": "Separate preparation process supplies immutable PNG and premultiplied sRGB RGBA reference. Child job contains PNG and request only; no reference pixels. Parent retains PNG/reference once",
            "transportScope": "One sequential signed bundle child per decode. Child exits before parent reads fixed raw Data; parent makes one owned provider copy. Both transient parent buffers and file I/O costs are included",
            "memoryScope": "Parent and child self TASK_VM_INFO/TASK_VM_INFO_PURGEABLE calls are separate, non-atomic. Exact field statuses/counts retained; periodic 10 ms maxima are sampled, not hard lifetime peaks. Parent polling is only its owned child's RSS",
            "peakScope": "Separate process maxima and receipt-time pairs only. Independent maxima sums are sampled envelopes, not simultaneous, hard, or unique-physical-memory peaks. No zero child sample after exit. Kernel file cache, GPU, WindowServer and other processes excluded",
            "parentLossVerified": false,
            "parentLossCleanupScope": "Abrupt parent loss is not covered. Death before child startup or a hard-backstop exit without a live parent can strand a private job; no orphan reaper is installed",
            "transportPhaseMemoryScope": "Aggregate parent boundaries and child event receipt pairs; no separate immediate parent observations after staging, exit or raw read/cleanup",
            "timingScope": "Full lifecycle begins before signature/input staging and ends after confirmed child exit, pipe drainage, raw read/hash/copy, actual draw, complete pixel validation, pool exit and owned job cleanup. Settling is separate",
            "interpretation": "Process isolation observation only. Lower parent retention can coexist with greater concurrent memory, transport, CPU and launch costs; no production remedy or large-image inference"]
        let output = evidenceDirectory.appendingPathComponent("image-decode-helper-\(request.mode.rawValue).json")
        var cycles: [ImageDecodeParentCycle] = []
        do {
            try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            try await inactive(deadline)
            let input = try readInputs(request.directory)
            report["inputPreparationProcessIdentifier"] = input.producerPID
            report["immutablePNGSHA256"] = input.pngSHA; report["immutableRawSHA256"] = input.rawSHA
            report["beforeDestinationPreparation"] = try object(try observe())
            if measured { destination = try ImageDrawDestination(width: 768, height: 576, tracker: destinationTracker) }
            report["afterDestinationPreparation"] = try object(try observe())
            if measured {
                for i in 1...2 { cycles.append(try await cycle(i, warmup: true, mode: request.mode, input: input, destination: destination!, providers: providers, deadline: deadline, failedReport: &report)) }
                report["baselineAfterWarmup"] = try object(try observe())
                for i in 1...12 { cycles.append(try await cycle(i, warmup: false, mode: request.mode, input: input, destination: destination!, providers: providers, deadline: deadline, failedReport: &report)) }
            } else {
                let child = ImageDecodeDiagnosticProcess(mode: request.mode == .cancelAfterDecode ? .cancelAfterDecode : .timeoutAfterDecode)
                report["beforeProbe"] = try object(try observe())
                do {
                    let result = try await withTaskCancellationHandler { try await Task.detached { try autoreleasepool { try child.run(png: input.png, armDeadline: deadline) } }.value } onCancel: { child.cancel() }
                    guard result == nil else { throw ImageDecodeDiagnosticError.invalidProtocol }
                } catch { report["probe"] = try? object(child.snapshot()); throw error }
                let metrics = child.snapshot()
                guard metrics.exitConfirmed, metrics.cleanupConfirmed, metrics.admissionReleased, metrics.sawPostDecodeReady,
                      metrics.terminal?.kind == .error, !metrics.outputExistedBeforeCleanup,
                      metrics.phases.first(where: { $0.child.kind == .ready })?.child.rawSHA256 == input.rawSHA else { throw ImageDecodeDiagnosticError.invalidProtocol }
                report["probeDecodedRGBAMatchesReference"] = true
                report["probe"] = try object(metrics); report["afterProbe"] = try object(try observe())
            }
            try await settle(0.5, deadline: deadline)
            report["halfSecondAfterFinalCycleDestinationLive"] = try object(try observe())
            destination?.close(); destination = nil
            report["afterDestinationOwnerDropped"] = try object(try observe())
            try await settle(0.5, deadline: deadline)
            report["halfSecondAfterDestinationOwnerDropped"] = try object(try observe())
            sampler.stop()
            // Keep the immutable input allocations alive through every memory boundary.
            withExtendedLifetime(input) { }
            let reread = try readInputs(request.directory)
            guard reread.pngSHA == input.pngSHA, reread.rawSHA == input.rawSHA else { throw ImageDecodeDiagnosticError.invalidInput }
            report["warmups"] = try cycles.filter(\.isWarmup).map { try object($0) }
            report["cycles"] = try cycles.filter { !$0.isWarmup }.map { try object($0) }
            report["completedDraws"] = cycles.count; report["completedFullPixelValidations"] = cycles.count
            report["destinationLifetime"] = try object(destinationTracker.snapshot())
            if request.mode == .isolatedDecode { report["rawProviderLifetime"] = try object(providers.snapshot()) }
            report["parentSampledMemory"] = try object(sampler.snapshot())
            report["retainedCycleImages"] = 0; report["immutableInputsUnchanged"] = true
            report["maximumObservedChildConcurrency"] = request.mode == .productionControl ? 0 : 1
            report["helperInvocations"] = request.mode == .productionControl ? 0 : (measured ? 14 : 1)
            report["ownedJobDirectoriesRemaining"] = 0
            try check(deadline); report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started; report["status"] = "observed"
            try write(report, to: output); return report
        } catch {
            destination?.close(); destination = nil; sampler.stop()
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedCycles"] = try? cycles.map { try object($0) }
            report["destinationLifetime"] = try? object(destinationTracker.snapshot())
            report["rawProviderLifetime"] = try? object(providers.snapshot())
            try? write(report, to: output); throw error
        }
    }
    private static func cycle(_ index: Int, warmup: Bool, mode: Mode, input: ImageDecodePreparedInput,
                              destination: ImageDrawDestination, providers: ImageDrawAllocationTracker, deadline: Double,
                              failedReport: inout [String: Any]) async throws -> ImageDecodeParentCycle {
        try await inactive(deadline)
        let before = try observe(), sampler = ImageDecodeMemorySampler()
        defer { sampler.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        var raw: Data?, childMetrics: ImageDecodeProcessMetrics?
        if mode == .isolatedDecode {
            let child = ImageDecodeDiagnosticProcess(mode: .decode)
            do {
                raw = try await withTaskCancellationHandler { try await Task.detached { try autoreleasepool { try child.run(png: input.png, armDeadline: deadline) } }.value } onCancel: { child.cancel() }
                let m = child.snapshot(); childMetrics = m
                guard m.exitConfirmed, m.cleanupConfirmed, m.admissionReleased, m.outcome == "decoded", let value = raw,
                      value.count == input.reference.count else { throw ImageDecodeDiagnosticError.outputMismatch }
                if value != input.reference {
                    failedReport["receivedRawMaximumAbsoluteChannelDifference"] = zip(value, input.reference).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
                    failedReport["receivedRawSHA256"] = ImageDecodeDiagnosticLimits.digest(value)
                    throw ImageDecodeDiagnosticError.outputMismatch
                }
            } catch { failedReport["failedChild"] = try? object(child.snapshot()); throw error }
        }
        let beforeParentDraw = try observe()
        let draw = try autoreleasepool { try draw(mode: mode, png: input.png, raw: raw, reference: input.reference, destination: destination, providers: providers) }
        raw = nil
        let afterPool = try observe()
        let fullLifecycleSeconds = ProcessInfo.processInfo.systemUptime - started
        try check(deadline)
        try await settle(0.18, deadline: deadline)
        let settled = try observe(); sampler.stop()
        return ImageDecodeParentCycle(index: index, isWarmup: warmup, before: before, beforeParentDraw: beforeParentDraw,
            draw: draw, afterPool: afterPool, settled: settled, process: childMetrics,
            timeToValidatedPixelsSeconds: draw.pixelsValidatedUptimeSeconds - started,
            fullLifecycleSeconds: fullLifecycleSeconds, observedCycleSeconds: ProcessInfo.processInfo.systemUptime - started,
            parentPeaks: sampler.snapshot(), rawProviderLifetime: mode == .isolatedDecode ? providers.snapshot() : nil)
    }
    private static func draw(mode: Mode, png: Data, raw: Data?, reference: Data, destination: ImageDrawDestination,
                             providers: ImageDrawAllocationTracker) throws -> ImageDecodeParentDraw {
        let started = ProcessInfo.processInfo.systemUptime
        let image: CGImage
        if mode == .productionControl { image = try ImageExportService.preview(data: png, format: .png) }
        else { guard let raw else { throw ImageDecodeDiagnosticError.invalidInput }; image = try ImageRasterMaterializationFixture.ownedImage(raw, tracker: providers) }
        let creationSeconds = ProcessInfo.processInfo.systemUptime - started
        let before = try observe()
        let pixels = try destination.drawAndValidate(image, reference: reference, tolerance: 0)
        let pixelsValidated = ProcessInfo.processInfo.systemUptime
        let after = try observe()
        withExtendedLifetime(image) { }
        return ImageDecodeParentDraw(imageCreationSeconds: creationSeconds, drawAndFlushSeconds: pixels.drawSeconds,
            pixelValidationSeconds: pixels.validationSeconds, pixelsValidatedUptimeSeconds: pixelsValidated, pixelsSHA256: pixels.sha256, maximumAbsoluteChannelDifference: pixels.maximumDifference,
            beforeDrawImageLive: before, afterDrawAndReadbackImageLive: after)
    }
    private static func readInputs(_ directory: URL) throws -> ImageDecodePreparedInput {
        let manifest = try boundedRead(directory.appendingPathComponent("image-draw-inputs.json"), maximum: 32_768)
        guard let m = try JSONSerialization.jsonObject(with: manifest) as? [String: Any], m["protocol"] as? String == "image-raster-materialization-v1",
              m["status"] as? String == "prepared", m["sourceCommit"] as? String == sourceCommit, m["architecture"] as? String == architecture,
              m["sourceWidth"] as? Int == 768, m["sourceHeight"] as? Int == 576, m["rawBytes"] as? Int == ImageDecodeDiagnosticLimits.rasterBytes,
              m["syntheticSource"] as? Bool == true, let pngBytes = m["pngBytes"] as? Int,
              let pngSHA = m["pngSHA256"] as? String, let rawSHA = m["rawSHA256"] as? String,
              let pid = m["processIdentifier"] as? Int, pid != Int(getpid()) else { throw ImageDecodeDiagnosticError.invalidInput }
        let png = try boundedRead(directory.appendingPathComponent("image-draw-input.png"), maximum: ImageDecodeDiagnosticLimits.pngBytes)
        let raw = try boundedRead(directory.appendingPathComponent("image-draw-reference.rgba"), maximum: ImageDecodeDiagnosticLimits.rasterBytes)
        guard png.count == pngBytes, raw.count == ImageDecodeDiagnosticLimits.rasterBytes,
              ImageDecodeDiagnosticLimits.digest(png) == pngSHA, ImageDecodeDiagnosticLimits.digest(raw) == rawSHA else { throw ImageDecodeDiagnosticError.invalidInput }
        return ImageDecodePreparedInput(png: png, reference: raw, pngSHA: pngSHA, rawSHA: rawSHA, producerPID: pid)
    }
    private static func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, let count = v.fileSize, count > 0, count <= maximum else { throw ImageDecodeDiagnosticError.invalidInput }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: count + 1) ?? Data()
        guard data.count == count else { throw ImageDecodeDiagnosticError.invalidInput }; return data
    }
    private static func inactive(_ deadline: Double) async throws {
        try check(deadline)
        let snapshot = await CodecExportProcessService.shared.snapshot()
        guard !snapshot.active, snapshot.lastJob == nil, ImageExportController.activeSessionCount == 0, ImageExportService.queue.operationCount == 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { autoreleasepool { c.resume() } } }
        await Task.yield(); try check(deadline)
    }
    private static func settle(_ seconds: Double, deadline: Double) async throws {
        try check(deadline); guard ProcessInfo.processInfo.systemUptime + seconds < deadline else { throw ImageDecodeDiagnosticError.deadline }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); try await inactive(deadline)
    }
    private static func check(_ deadline: Double) throws { try Task.checkCancellation(); guard ProcessInfo.processInfo.systemUptime < deadline else { throw ImageDecodeDiagnosticError.deadline } }
    private static func observe() throws -> ImageDecodeMemoryReading { let r = ImageDecodeMemoryReading.current(); guard r.usable else { throw ImageDecodeDiagnosticError.failed }; return r }
    private static var sourceCommit: String { Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown" }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let r = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw ImageDecodeDiagnosticError.invalidProtocol }; return r
    }
    static func encodedReport(_ report: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= ImageDecodeDiagnosticLimits.reportBytes else { throw ImageDecodeDiagnosticError.invalidProtocol }; return data
    }
    private static func write(_ report: [String: Any], to url: URL) throws { try encodedReport(report).write(to: url, options: .atomic) }
}
private struct ImageDecodePreparedInput: Sendable { let png: Data, reference: Data; let pngSHA: String, rawSHA: String; let producerPID: Int }
private struct ImageDecodeParentDraw: Encodable {
    let imageCreationSeconds: Double, drawAndFlushSeconds: Double, pixelValidationSeconds: Double, pixelsValidatedUptimeSeconds: Double
    let pixelsSHA256: String; let maximumAbsoluteChannelDifference: Int
    let actualDrawCount = 1, validatedRGBABytes = ImageDecodeDiagnosticLimits.rasterBytes
    let beforeDrawImageLive: ImageDecodeMemoryReading, afterDrawAndReadbackImageLive: ImageDecodeMemoryReading
}
private struct ImageDecodeParentCycle: Encodable {
    let index: Int; let isWarmup: Bool
    let before: ImageDecodeMemoryReading, beforeParentDraw: ImageDecodeMemoryReading
    let draw: ImageDecodeParentDraw
    let afterPool: ImageDecodeMemoryReading, settled: ImageDecodeMemoryReading
    let process: ImageDecodeProcessMetrics?
    let timeToValidatedPixelsSeconds: Double, fullLifecycleSeconds: Double, observedCycleSeconds: Double
    let parentPeaks: ImageDecodeMemoryPeaks
    let rawProviderLifetime: ImageDrawAllocationSnapshot?
}
