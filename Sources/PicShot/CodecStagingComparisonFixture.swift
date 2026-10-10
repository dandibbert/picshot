import AppKit
import CryptoKit
import Darwin
import ImageIO
import PicShotCodecCore

/// One explicit diagnostic cell per fresh process. The application never reads
/// this selector outside its smoke fixture and its service default is unchanged.
@MainActor
enum CodecStagingComparisonFixture {
    static let protocolName = "codec-staging-comparison-v1"
    enum Mode: String { case exportOnly = "export-only", combined, controller, evidence, validate, interruptions }
    enum Arm: String { case control, candidate
        var staging: CodecPNGStagingMode { self == .control ? .legacyPreview : .verifiedBytesOnly }
    }
    private static var claimed = false
    static func runIfRequested(evidenceDirectory: URL, environment: [String: String]) async throws -> [String: Any]? {
        let prefix = "PICSHOT_CODEC_STAGING_", keys = Set(environment.keys.filter { $0.hasPrefix(prefix) })
        if keys.isEmpty { return nil }
        guard keys.isSubset(of: [prefix + "MODE", prefix + "ARM", prefix + "PROFILE", prefix + "INPUT_DIRECTORY", prefix + "FORMAT"]),
              let mode = environment[prefix + "MODE"].flatMap(Mode.init(rawValue:)),
              let arm = environment[prefix + "ARM"].flatMap(Arm.init(rawValue:)),
              let profile = environment[prefix + "PROFILE"].flatMap(CodecExportAttributionFixture.Profile.init(rawValue:)),
              profile == .installed || profile == .stagingLarge || profile == .stagingCheck,
              ["webp", "avif"].contains(environment[prefix + "FORMAT"] ?? "webp"),
              (mode == .validate) == (environment[prefix + "INPUT_DIRECTORY"] != nil),
              !environment.keys.contains(where: { $0.hasPrefix("PICSHOT_CODEC_ATTRIBUTION_") || $0.hasPrefix("PICSHOT_IMAGE_DECODE_") || $0.hasPrefix("PICSHOT_IMAGE_DRAW_") }),
              !claimed else { throw failure("Invalid or mixed comparison cell") }
        claimed = true
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        // Signature, path and binary digest are checked before any measured cell.
        let entryMemory = try observe(), preparationStarted = ProcessInfo.processInfo.systemUptime
        let helper = try CodecHelperExecutable.verified()
        let helperHash = try autoreleasepool { digest(try Data(contentsOf: helper)) }
        let preparationSeconds = ProcessInfo.processInfo.systemUptime - preparationStarted
        let afterPreparation = try observe()
        let format: ImageExportFormat = environment[prefix + "FORMAT"] == "avif" ? .avif : .webp
        let service = makeService(arm)
        var report: [String: Any]
        switch mode {
        case .exportOnly, .combined:
            report = try await CodecExportAttributionFixture.verify(evidenceDirectory: evidenceDirectory,
                mode: mode == .exportOnly ? .exportOnly : .combined, format: format, profile: profile,
                service: service, sampleBacking: true)
        case .controller: report = try await controller(profile, service: service, directory: evidenceDirectory)
        case .evidence: report = try await evidence(profile, arm: arm, directory: evidenceDirectory)
        case .validate:
            guard let path = environment[prefix + "INPUT_DIRECTORY"], path.hasPrefix("/") else { throw failure("Absolute evidence input required") }
            report = try validate(profile, input: URL(fileURLWithPath: path, isDirectory: true))
        case .interruptions:
            report = try await CodecExportUIPreviewFixture.verify(evidenceDirectory: evidenceDirectory, service: service)
            report["closeDuringHelper"] = try await closeDuringHelper(service)
        }
        report["protocol"] = protocolName; report["comparisonMode"] = mode.rawValue; report["arm"] = arm.rawValue
        report["profile"] = profile.rawValue; report["format"] = format.filenameExtension; report["processIdentifier"] = Int(getpid())
        report["sourceCommit"] = Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown"
        report["bundlePath"] = Bundle.main.bundlePath; report["helperVerifiedPath"] = helper.path
        report["helperVerifiedSHA256"] = helperHash; report["helperIdentityCheckedBeforeMeasurement"] = true
        report["diagnosticEntryBacking"] = try object(entryMemory); report["afterIdentityPreparationBacking"] = try object(afterPreparation)
        report["identityPreparationSeconds"] = preparationSeconds
        report["sourceIdentityScope"] = "Canonical synthetic provider bytes hashed without a per-cycle raster draw; preparation costs and entry VM boundaries are reported separately"
        report["sourceWidth"] = profile.width; report["sourceHeight"] = profile.height
        report["pngStagingMode"] = arm.staging.rawValue
        report["interpretation"] = "Matched diagnostic observations, not proof of causality or a leak/no-leak verdict. Staged PNG digest overhead is enabled identically in both arms; independent output pixel validation is in a separate process."
        try write(report, evidenceDirectory.appendingPathComponent("codec-staging.json")); return report
    }
    private static func makeService(_ arm: Arm, staged: (@Sendable (URL) throws -> Void)? = nil) -> CodecExportProcessService {
        CodecExportProcessService(configuration: CodecProcessConfiguration(executable: { try CodecHelperExecutable.verified() },
            pngStagingMode: arm.staging, collectStagedPNGIdentityForDiagnostics: true, stagedPNGForDiagnostics: staged))
    }
    private static func controller(_ profile: CodecExportAttributionFixture.Profile, service: CodecExportProcessService,
                                   directory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let deadline = ProcessInfo.processInfo.systemUptime + profile.deadlineSeconds
        let sampler = GIFResourceMemorySampler(includeBacking: true); defer { sampler.stop() }
        var report: [String: Any] = ["status": "running", "warmupCycles": profile.warmupCycles,
            "measuredCycles": profile.measuredCycles, "independentDecodes": 0,
            "scope": "Real ImageExportController, native control actions, actual visible preview draw observer, alternating Save/Close; no screenshots or independent raster decode in measured parent",
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval, "captureStarted": false, "networkAttempted": false]
        report["backingBeforeWarmup"] = try object(observe())
        var cycles: [[String: Any]] = []
        for ordinal in 0..<(profile.warmupCycles + profile.measuredCycles) {
            if ordinal == profile.warmupCycles { report["backingBaselineAfterWarmup"] = try object(observe()) }
            let perCycle = GIFResourceMemorySampler(includeBacking: true)
            var cycle = try await controllerCycle(profile, service: service, ordinal: ordinal, directory: directory, deadline: deadline)
            try await settle(deadline)
            cycle["backingSettled"] = try object(observe()); perCycle.stop()
            cycle["memory"] = try object(perCycle.snapshot()); cycle["isWarmup"] = ordinal < profile.warmupCycles
            cycle["index"] = ordinal < profile.warmupCycles ? ordinal + 1 : ordinal - profile.warmupCycles + 1
            cycles.append(cycle)
        }
        try await Task.sleep(nanoseconds: 500_000_000); try await settle(deadline)
        report["backingHalfSecondAfterFinalCycle"] = try object(observe()); sampler.stop()
        report["wholeRunSampledMemory"] = try object(sampler.snapshot())
        report["warmups"] = Array(cycles.prefix(profile.warmupCycles)); report["cycles"] = Array(cycles.dropFirst(profile.warmupCycles))
        report["activeControllersAfterAllCycles"] = ImageExportController.activeSessionCount
        report["queuedOrRunningJobsAfterAllCycles"] = ImageExportService.queue.operationCount
        report["status"] = "observed"; return report
    }
    private static func controllerCycle(_ profile: CodecExportAttributionFixture.Profile, service: CodecExportProcessService,
                                        ordinal: Int, directory: URL, deadline: Double) async throws -> [String: Any] {
        let source = try autoreleasepool { try CodecExportResourceFixture.fixture(width: profile.width, height: profile.height) }
        let sourceHash = try autoreleasepool { try sourceIdentity(source) }
        var controller: ImageExportController? = try ImageExportController(image: source,
            bundledEncoder: { try await ImageExportService.encodeBundled(snapshot: $0, options: $1, service: service) })
        weak var witness = controller
        defer { controller?.cancelExport() }
        let draw = CodecStagingDrawWitness()
        controller!.previewView.diagnosticDrawObserver = { draw.record($0) }
        controller!.showWindow(nil); controller!.window?.makeKeyAndOrderFront(nil)
        let controls = controller!.accessory
        controls.picker.selectItem(at: ImageExportFormat.webp.rawValue); try send(controls.picker)
        // Native changes share the ordinary debounce/cancellation path. The final
        // accepted options remain identical to the export-only cell.
        for quality in [17.0, 89.0, 81.0] { controls.quality.doubleValue = quality; try send(controls.quality) }
        controls.preserveAlpha.state = .on; try send(controls.preserveAlpha)
        controls.lossless.state = .on
        let requested = ProcessInfo.processInfo.systemUptime
        try send(controls.lossless)
        while controller!.latestArtifact == nil || draw.value == nil {
            try check(deadline)
            controller!.window?.displayIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let observation = draw.value, let displayed = controller!.previewView.image,
              observation.imageIdentity == String(describing: ObjectIdentifier(displayed)), observation.windowVisible,
              observation.uptimeSeconds >= requested else { throw failure("Draw does not match final visible preview") }
        var report: [String: Any] = ["requestUptimeSeconds": requested,
            "firstNativeDrawUptimeSeconds": observation.uptimeSeconds,
            "requestToNativeDrawSeconds": observation.uptimeSeconds - requested,
            "draw": try object(ImageDecodeUIDrawRecord(observation)), "currentImageIdentity": String(describing: ObjectIdentifier(displayed)), "sourceSHA256": sourceHash,
            "nativeControlChanges": 6]
        // Scalar-only evidence crosses the close/release boundary.
        do {
            guard let artifact = controller!.latestArtifact, artifact.options.format == .webp,
                  artifact.options.lossless, artifact.options.preserveAlpha, artifact.options.quality == 0.81 else { throw failure("Stale options reached preview") }
            report["encodedSHA256"] = digest(artifact.data); report["encodedBytes"] = artifact.byteCount
            report["helper"] = try object(try completed(await service.snapshot()))
            if ordinal % 2 == 0 {
                let output = directory.appendingPathComponent("reviewed.webp")
                try await controller!.savePrepared(to: output)
                try require(try Data(contentsOf: output) == artifact.data, "Save changed reviewed bytes")
                try FileManager.default.removeItem(at: output); report["action"] = "save"; report["sameByteSave"] = true
            } else { controller!.window?.performClose(nil); report["action"] = "close" }
        }
        try require(controller!.isClosed && controller!.latestArtifact == nil && controller!.previewView.image == nil, "Closed UI retained preview")
        controller = nil
        try await settle(deadline)
        let releasedState = await service.snapshot()
        try require(witness == nil && !releasedState.active, "Controller/helper still retained")
        report["controllerReleased"] = true; report["helperInactive"] = true; return report
    }
    private static func evidence(_ profile: CodecExportAttributionFixture.Profile, arm: Arm, directory: URL) async throws -> [String: Any] {
        let source = try CodecExportResourceFixture.fixture(width: profile.width, height: profile.height)
        let snapshot = try ImageExportSnapshot(image: source)
        let sourcePixels = try sourceProviderBytes(source)
        try sourcePixels.write(to: directory.appendingPathComponent("source.rgba"), options: .withoutOverwriting)
        var entries: [[String: Any]] = []
        for format in [ImageExportFormat.webp, .avif] {
            let stage = directory.appendingPathComponent("actual-staged-\(format.filenameExtension).png")
            let service = makeService(arm, staged: { try FileManager.default.copyItem(at: $0, to: stage) })
            let artifact = try await ImageExportService.encodeBundled(snapshot: snapshot,
                options: ImageExportOptions(format: format, quality: 0.81, lossless: true, preserveAlpha: true), service: service)
            let output = directory.appendingPathComponent("actual-final." + format.filenameExtension)
            try ImageExportService.publish(artifact, to: output)
            let preview = try CodecExportResourceFixture.raster(artifact.firstPreview)
            let previewName = "actual-preview-\(format.filenameExtension).rgba"
            try preview.write(to: directory.appendingPathComponent(previewName), options: .withoutOverwriting)
            let metrics = try completed(await service.snapshot())
            let stagedBytes = try Data(contentsOf: stage)
            try require(metrics.sourceSHA256 == digest(stagedBytes), "Actual staged file identity differs")
            entries.append(["format": format.filenameExtension, "stagedFile": stage.lastPathComponent,
                "stagedSHA256": digest(stagedBytes), "stagedBytes": stagedBytes.count,
                "finalFile": output.lastPathComponent, "finalSHA256": digest(artifact.data), "finalBytes": artifact.byteCount,
                "previewFile": previewName, "previewSHA256": digest(preview), "previewBytes": preview.count,
                "previewWidth": artifact.firstPreview.width, "previewHeight": artifact.firstPreview.height,
                "helper": try object(metrics)])
        }
        return ["status": "preserved", "sourceSHA256": digest(sourcePixels), "sourceFile": "source.rgba", "entries": entries,
            "scope": "Separate nonmeasured export process preserves actual staged PNG via explicit callback, final published encoded bytes and actual helper-derived preview pixels; no re-encoded stand-in"]
    }
    private static func validate(_ profile: CodecExportAttributionFixture.Profile, input: URL) throws -> [String: Any] {
        guard let manifest = try JSONSerialization.jsonObject(with: read(input.appendingPathComponent("codec-staging.json"), maximum: 4 * 1_024 * 1_024)) as? [String: Any],
              manifest["status"] as? String == "preserved", manifest["profile"] as? String == profile.rawValue,
              let producer = manifest["processIdentifier"] as? Int, producer != Int(getpid()),
              let entries = manifest["entries"] as? [[String: Any]], entries.count == 2 else { throw failure("Separate preserved evidence required") }
        let source = try read(input.appendingPathComponent("source.rgba"), maximum: profile.width * profile.height * 4)
        try require(source.count == profile.width * profile.height * 4 && digest(source) == manifest["sourceSHA256"] as? String, "Source pixels changed")
        var records: [[String: Any]] = []
        for entry in entries {
            guard let name = entry["format"] as? String, ["webp", "avif"].contains(name) else { throw failure("Invalid format") }
            let format: ImageExportFormat = name == "webp" ? .webp : .avif
            let stage = try read(input.appendingPathComponent("actual-staged-\(name).png"), maximum: CodecExportLimits.stillInputBytes)
            let final = try read(input.appendingPathComponent("actual-final.\(name)"), maximum: CodecExportLimits.stillOutputBytes)
            let preview = try read(input.appendingPathComponent("actual-preview-\(name).rgba"), maximum: CodecExportLimits.previewBytes)
            try require(digest(stage) == entry["stagedSHA256"] as? String && digest(final) == entry["finalSHA256"] as? String &&
                        digest(preview) == entry["previewSHA256"] as? String, "Preserved bytes changed")
            let decoded = try checkedDecode(final, format: format, width: profile.width, height: profile.height)
            let actual = try CodecExportResourceFixture.raster(decoded)
            let staged = try CodecExportResourceFixture.raster(checkedDecode(stage, format: .png, width: profile.width, height: profile.height))
            for expected in [source, staged] {
                try require(expected.count == actual.count && zip(expected, actual).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 }, "Actual decoded pixels/alpha differ")
            }
            guard let previewWidth = entry["previewWidth"] as? Int, let previewHeight = entry["previewHeight"] as? Int,
                  [CodecExportLimits.previewDimension, 1_000].contains(where: { dimension in
                      let scale = min(1, Double(dimension) / Double(max(profile.width, profile.height)))
                      return previewWidth == max(1, Int((Double(profile.width) * scale).rounded())) &&
                          previewHeight == max(1, Int((Double(profile.height) * scale).rounded()))
                  }) else { throw failure("Helper preview geometry is outside its declared plans") }
            let scaled = try scaledPreviewPixels(decoded, width: previewWidth, height: previewHeight)
            try require(preview.count == scaled.count && zip(preview, scaled).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 },
                        "Actual capped helper preview differs from independently scaled final decode")
            records.append(["format": name, "allPixelsAndAlphaCompared": true, "previewCompared": true,
                "previewWidth": previewWidth, "previewHeight": previewHeight, "previewValidatedBytes": scaled.count,
                "previewGeometry": "Actual helper plan, high interpolation, copy blend, premultiplied RGBA8 sRGB",
                "stagedCompared": true, "decodedBytes": actual.count, "finalSHA256": digest(final), "stagedSHA256": digest(stage)])
        }
        return ["status": "validated", "producerPID": producer, "entries": records,
            "independentValidationProcess": true, "helperLaunches": 0]
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let count = attributes.fileSize, count > 0, count <= maximum else { throw failure("Evidence file exceeds its regular-file byte bound") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: count + 1) ?? Data()
        try require(data.count == count, "Evidence file changed during bounded read"); return data
    }
    private static func checkedDecode(_ data: Data, format: ImageExportFormat, width: Int, height: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == format.contentType.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width, properties[kCGImagePropertyPixelHeight] as? Int == height else { throw failure("Evidence dimensions/type differ before decode") }
        return try CodecExportResourceFixture.independentDecode(data, format: format, width: width, height: height)
    }
    private static func scaledPreviewPixels(_ image: CGImage, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= CodecExportLimits.previewDimension, height <= CodecExportLimits.previewDimension,
              width * height * 4 <= CodecExportLimits.previewBytes,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Preview reference allocation exceeds bound") }
        context.interpolationQuality = .high; context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { throw failure("Preview reference pixels missing") }
        return Data(bytes: pixels, count: width * height * 4)
    }
    private static func closeDuringHelper(_ service: CodecExportProcessService) async throws -> [String: Any] {
        let source = try CodecExportResourceFixture.fixture(width: 768, height: 576)
        let target = CodecStagingWeakController(), completion = CodecStagingCompletion()
        var controller: ImageExportController? = try ImageExportController(image: source, bundledEncoder: { snapshot, options in
            defer { completion.finish() }
            return try await ImageExportService.encodeBundled(snapshot: snapshot, options: options, prepare: { frozen, request in
                try await service.prepare(snapshot: frozen, options: request) { fraction in
                    if fraction < 1 { Task { @MainActor in target.value?.window?.performClose(nil) } }
                }
            })
        })
        target.value = controller; weak var witness = controller
        defer { controller?.cancelExport() }
        controller!.showWindow(nil); controller!.accessory.picker.selectItem(at: ImageExportFormat.avif.rawValue)
        try send(controller!.accessory.picker)
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while !completion.done || !controller!.isClosed { try check(deadline); try await Task.sleep(nanoseconds: 10_000_000) }
        try require(controller!.latestArtifact == nil && controller!.previewView.image == nil && !controller!.saveButton.isEnabled,
                    "Late completion repainted a closed controller")
        let state = await service.snapshot()
        guard !state.active, let helper = state.lastJob, helper.childLaunched, helper.childExitConfirmed, helper.temporaryDirectoryRemoved else { throw failure("Close left helper/temporary staging") }
        controller = nil; try await settle(deadline); try require(witness == nil, "Close retained controller")
        return ["progressTriggeredClose": true, "lateResultSuppressed": true, "controllerReleased": true, "helper": try object(helper)]
    }
    private static func completed(_ state: CodecExportProcessSnapshot) throws -> CodecExportProcessMetrics {
        guard !state.active, let m = state.lastJob, m.outcome == "succeeded", m.childLaunched, m.childExitConfirmed,
              m.terminationStatus == 0, m.temporaryDirectoryRemoved, (m.childProcessIdentifier ?? 0) > 0,
              m.helperExecutablePath != nil, m.sourceSHA256 != nil else { throw failure("Incomplete helper evidence") }; return m
    }
    private static func observe() throws -> ImageBackingMemoryReading {
        let r = ImageBackingMemoryReading.current()
        try require(r.standard.kernelReturn == 0 && r.purgeable.kernelReturn == 0 && r.residentBytes != nil && r.physicalFootprintBytes != nil &&
                    r.purgeable.bytes["purgeable_volatile_resident"] != nil, "Required VM observation missing"); return r
    }
    private static func settle(_ deadline: Double) async throws {
        for _ in 0..<3 {
            try check(deadline); try await Task.sleep(nanoseconds: 60_000_000)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { autoreleasepool { c.resume() } } }
        }
        try require(ImageExportService.queue.operationCount == 0 && ImageExportController.activeSessionCount == 0, "Pending controller/queue work")
    }
    private static func send(_ control: NSControl) throws { try require(control.sendAction(control.action, to: control.target), "Native action not dispatched") }
    private static func check(_ deadline: Double) throws { try Task.checkCancellation(); try require(ProcessInfo.processInfo.systemUptime < deadline, "Cooperative deadline exceeded") }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Codec staging comparison: " + message) }
    private static func sourceProviderBytes(_ image: CGImage) throws -> Data {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.bytesPerRow == image.width * 4,
              let bytes = image.dataProvider?.data, CFDataGetLength(bytes) == image.width * image.height * 4 else { throw failure("Unexpected source provider layout") }
        return bytes as Data
    }
    static func sourceIdentity(_ image: CGImage) throws -> String { try digest(sourceProviderBytes(image)) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any] }
    private static func write(_ value: [String: Any], _ url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
}
@MainActor private final class CodecStagingDrawWitness {
    var value: ImageExportPreviewDrawObservation?
    func record(_ observation: ImageExportPreviewDrawObservation) { if value == nil { value = observation } }
}
@MainActor private final class CodecStagingWeakController { weak var value: ImageExportController? }
private final class CodecStagingCompletion: @unchecked Sendable {
    private let lock = NSLock(); private var finished = false
    func finish() { lock.lock(); finished = true; lock.unlock() }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}
