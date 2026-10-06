import AppKit
import CryptoKit
import Darwin
import ImageIO

/// One deliberately narrow workload per fresh process. No production encoder,
/// decoder, controller, or resource-admission behavior is changed by this fixture.
@MainActor
enum ImageBackingAttributionFixture {
    typealias Profile = CodecExportAttributionFixture.Profile
    enum Mode: String, CaseIterable, Sendable {
        case sourceCreate = "source-create"
        case snapshotOnly = "snapshot-only"
        case rasterDigestOnly = "raster-digest-only"
        case nativeExport = "native-export"
        case previewOnly = "preview-only"
        case independentDecodeOnly = "independent-decode-only"
        var isReader: Bool { self == .previewOnly || self == .independentDecodeOnly }
        var requiresFormat: Bool { self == .nativeExport || isReader }
    }
    struct Cell: Equatable {
        let mode: Mode
        let format: ImageExportFormat?
    }
    static let supportedFormats: [ImageExportFormat] = [.png, .jpeg, .bmp, .pdf, .webp, .avif]
    /// Launchers can run this small attribution pass before expanding formats.
    static let focusedMatrix: [Cell] = [
        Cell(mode: .sourceCreate, format: nil), Cell(mode: .snapshotOnly, format: nil),
        Cell(mode: .rasterDigestOnly, format: nil), Cell(mode: .previewOnly, format: .webp),
        Cell(mode: .independentDecodeOnly, format: .webp), Cell(mode: .nativeExport, format: .png),
        Cell(mode: .previewOnly, format: .png)
    ]
    static let inputManifestName = "image-backing-inputs.json"
    private static var invocationClaimed = false

    static func runIfRequested(evidenceDirectory: URL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [String: Any]? {
        guard let rawMode = environment["PICSHOT_IMAGE_BACKING_MODE"] else { return nil }
        guard let profile = Profile(rawValue: environment["PICSHOT_IMAGE_BACKING_PROFILE"] ?? Profile.installed.rawValue) else {
            throw failure("Unknown profile")
        }
        if rawMode == "prepare-inputs" {
            guard environment["PICSHOT_IMAGE_BACKING_FORMAT"] == nil,
                  environment["PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY"] == nil else { throw failure("Preparation cannot select a workload input") }
            return try await prepareInputs(evidenceDirectory: evidenceDirectory, profile: profile)
        }
        guard let mode = Mode(rawValue: rawMode) else { throw failure("Unknown workload") }
        let rawFormat = environment["PICSHOT_IMAGE_BACKING_FORMAT"]
        let format = rawFormat.flatMap { value in supportedFormats.first { $0.filenameExtension == value } }
        if rawFormat != nil && format == nil { throw failure("Unknown format; use png, jpg, bmp, pdf, webp, or avif") }
        let input = environment["PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return try await verify(evidenceDirectory: evidenceDirectory, mode: mode, format: format,
                                profile: profile, inputDirectory: input)
    }

    static func validateConfiguration(mode: Mode, format: ImageExportFormat?, inputDirectory: URL?) throws {
        try require(mode.requiresFormat == (format != nil), "Only export/reader workloads take a format")
        if let format { try require(supportedFormats.contains(format), "Unsupported comparison format") }
        try require(mode.isReader == (inputDirectory != nil), "Only reader workloads require separately prepared inputs")
        if mode == .nativeExport { try require(format?.usesBundledCodec == false, "Native export control accepts PNG/JPEG/BMP/PDF only") }
        if let inputDirectory { try require(inputDirectory.isFileURL, "Input directory must be local") }
    }

    /// Inputs are intentionally authored in another process. Readers never create
    /// a synthetic source, snapshot, encoder, or helper in their measured process.
    static func prepareInputs(evidenceDirectory: URL, profile: Profile = .installed) async throws -> [String: Any] {
        try claimInvocation()
        try require(evidenceDirectory.isFileURL, "Evidence directory must be local")
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for format in supportedFormats {
            let source = try autoreleasepool { try CodecExportResourceFixture.fixture(width: profile.width, height: profile.height) }
            let snapshot = try autoreleasepool { try ImageExportSnapshot(image: source) }
            let options = ImageExportOptions(format: format, quality: 0.81, lossless: true, preserveAlpha: true)
            let artifact: ImageExportArtifact
            if format.usesBundledCodec {
                artifact = try await ImageExportService.encodeBundled(snapshot: snapshot, options: options)
                let state = await CodecExportProcessService.shared.snapshot()
                try require(!state.active && state.lastJob?.outcome == "succeeded" &&
                            state.lastJob?.childExitConfirmed == true && state.lastJob?.temporaryDirectoryRemoved == true,
                            "Preparation helper exit/cleanup missing")
            } else {
                artifact = try autoreleasepool { try ImageExportService.encode(snapshot: snapshot, options: options) }
            }
            let destination = evidenceDirectory.appendingPathComponent(inputName(format))
            try autoreleasepool { try ImageExportService.publish(artifact, to: destination) }
            entries.append(["format": format.filenameExtension, "filename": destination.lastPathComponent,
                            "bytes": artifact.byteCount, "sha256": digest(artifact.data)])
        }
        let report: [String: Any] = ["status": "prepared", "mode": "prepare-inputs", "profile": profile.rawValue,
            "matrixTier": "input-preparation",
            "sourceCommit": sourceCommit, "processIdentifier": Int(getpid()), "sourceWidth": profile.width,
            "sourceHeight": profile.height, "syntheticSource": true, "captureStarted": false, "networkAttempted": false,
            "inputs": entries, "scope": "One separately prepared immutable input per format from unchanged production encode paths"]
        try write(report, to: evidenceDirectory.appendingPathComponent(inputManifestName))
        return report
    }

    static func verify(evidenceDirectory: URL, mode: Mode, format: ImageExportFormat? = nil,
                       profile: Profile = .installed, inputDirectory: URL? = nil) async throws -> [String: Any] {
        try validateConfiguration(mode: mode, format: format, inputDirectory: inputDirectory)
        try require(evidenceDirectory.isFileURL, "Evidence directory must be local")
        try claimInvocation()
        _ = NSApplication.shared
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let reportURL = evidenceDirectory.appendingPathComponent("image-backing-\(format?.filenameExtension ?? "common")-\(mode.rawValue).json")
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + profile.deadlineSeconds
        var report: [String: Any] = [
            "status": "running", "diagnosticOnly": true, "mode": mode.rawValue,
            "matrixTier": focusedMatrix.contains(Cell(mode: mode, format: format)) ? "focused-control" : "expanded-format-comparison",
            "format": format?.filenameExtension ?? "common", "profile": profile.rawValue,
            "sourceCommit": sourceCommit, "processIdentifier": Int(getpid()), "bundlePath": Bundle.main.bundlePath,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceWidth": profile.width, "sourceHeight": profile.height,
            "oneRGBAStorageBytes": profile.width * profile.height * 4,
            "oneRGBAStorageScope": "Reference sourceWidth * sourceHeight * 4 only, not an allocation-size claim; workload width/height/imageBytesPerRow/imageStrideStorageBytes describe the actual returned image",
            "pdfPagePolicy": "Prepared PDF uses image-sized single-page paper; independent reader rejects any other media-box size. Custom paper/margins require a separate profile, never silent source-size substitution",
            "warmupCycles": profile.warmupCycles, "measuredCycles": profile.measuredCycles,
            "cooperativeDeadlineSeconds": profile.deadlineSeconds, "outerDeadlineRequired": true,
            "captureStarted": false, "networkAttempted": false, "dependenciesInstalled": false,
            "controllerCreationCount": 0, "separateProcessRequired": true,
            "workloadScope": scope(mode), "backingMemoryScope": ImageBackingTaskVMReading.scope,
            "memoryScope": "Parent RSS/footprint continuously sampled; self Mach backing fields at boundaries only. No other process, GPU, or WindowServer attribution. Sampled peaks are not instantaneous kernel peaks",
            "ownershipScope": "Synchronous workload and explicit autorelease pool return scalars only. This does not establish release of CoreGraphics backing or diagnose a leak",
            "bookkeepingScope": "Bounded scalar readings only; no image/raster/result-byte arrays retained in cycle reports. JSON writes occur after memory observations",
            "interpretation": "Raw growth and accounting observations only; no automatic purgeability, leak, plateau, or no-leak conclusion"
        ]
        var cycles: [ImageBackingCycle] = []
        cycles.reserveCapacity(profile.warmupCycles + profile.measuredCycles)
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        do {
            let initialState = await CodecExportProcessService.shared.snapshot()
            try require(!initialState.active && initialState.lastJob == nil, "A codec helper already ran in this process")
            try await settle(deadline: deadline)
            report["beforePersistentInputPreparation"] = try object(try observed())
            let input = try inputDirectory.map { try validatedInput(directory: $0, format: format!, profile: profile) }
            // These long-lived control inputs are prepared before warmup and are
            // explicitly retained through the final observation. Source-create
            // and reader modes have neither a persistent source nor a snapshot.
            let source: CGImage?
            if mode == .snapshotOnly || mode == .rasterDigestOnly || mode == .nativeExport {
                source = try autoreleasepool { try CodecExportResourceFixture.fixture(width: profile.width, height: profile.height) }
            } else { source = nil }
            let snapshot: ImageExportSnapshot?
            if mode == .nativeExport, let source {
                snapshot = try autoreleasepool { try ImageExportSnapshot(image: source) }
            } else { snapshot = nil }
            report["persistentSyntheticSourceCount"] = source == nil ? 0 : 1
            report["persistentSnapshotCount"] = snapshot == nil ? 0 : 1
            report["persistentEncodedInputCount"] = input == nil ? 0 : 1
            if let input {
                report["inputPreparationProcessIdentifier"] = input.producerPID
                report["immutableInputBytes"] = input.data.count; report["immutableInputSHA256"] = input.sha256
                report["sameInputCachingLimit"] = "Same immutable Data retained; fresh ImageIO/PDF object per call. This isolates readers but does not test changing-file or changing-byte caches"
            }
            report["beforeWarmup"] = try object(try observed())
            for index in 1...profile.warmupCycles {
                cycles.append(try await cycle(index: index, warmup: true, mode: mode, format: format, profile: profile,
                    source: source, snapshot: snapshot, input: input, deadline: deadline))
            }
            let baseline = try observed()
            report["baselineAfterWarmup"] = try object(baseline)
            for index in 1...profile.measuredCycles {
                cycles.append(try await cycle(index: index, warmup: false, mode: mode, format: format, profile: profile,
                    source: source, snapshot: snapshot, input: input, deadline: deadline))
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            try await settle(deadline: deadline)
            report["halfSecondAfterFinalCycle"] = try object(try observed())
            withExtendedLifetime((source, snapshot, input)) { }
            sampler.stop()
            let measured = cycles.filter { !$0.isWarmup }
            report["residentTrend"] = try object(CodecAttributionTrend(baseline: baseline.residentBytes,
                settled: measured.map { $0.settled.residentBytes }, peaks: measured.map { $0.memory.peakResidentBytes }))
            report["physicalFootprintTrend"] = try object(CodecAttributionTrend(baseline: baseline.physicalFootprintBytes,
                settled: measured.map { $0.settled.physicalFootprintBytes }, peaks: measured.map { $0.memory.peakPhysicalFootprintBytes }))
            report["wholeRunSampledMemory"] = try object(sampler.snapshot())
            report["warmups"] = try cycles.filter(\.isWarmup).map { try object($0) }
            report["cycles"] = try measured.map { try object($0) }
            report["completedWorkloadInvocations"] = cycles.count
            report["expectedPerCycleOperations"] = try object(ImageBackingOperationCounts(mode: mode))
            if let input {
                try autoreleasepool {
                    let data = try boundedRead(input.url)
                    try require(data.count == input.data.count && digest(data) == input.sha256, "Prepared input changed")
                }
                report["immutableInputUnchanged"] = true
            }
            let finalState = await CodecExportProcessService.shared.snapshot()
            try require(!finalState.active && finalState.lastJob == nil, "Helper work contaminated control process")
            report["helperInvocations"] = 0
            report["activeControllersAfterAllCycles"] = ImageExportController.activeSessionCount
            report["queuedOrRunningJobsAfterAllCycles"] = ImageExportService.queue.operationCount
            report["ownedTemporaryMediaFiles"] = 0
            report["status"] = "observed"; report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try write(report, to: reportURL)
            return report
        } catch {
            sampler.stop()
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["completedCycles"] = try? cycles.map { try object($0) }
            try? write(report, to: reportURL)
            throw error
        }
    }

    private static func cycle(index: Int, warmup: Bool, mode: Mode, format: ImageExportFormat?, profile: Profile,
                              source: CGImage?, snapshot: ImageExportSnapshot?, input: ImageBackingInput?,
                              deadline: TimeInterval) async throws -> ImageBackingCycle {
        try check(deadline)
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let before = try observed()
        let workload = try autoreleasepool { try perform(mode: mode, format: format, profile: profile,
                                                         source: source, snapshot: snapshot, input: input) }
        let afterPool = try observed()
        try await settle(deadline: deadline)
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 60_000_000)
            try await settle(deadline: deadline)
        }
        let settled = try observed()
        sampler.stop()
        return ImageBackingCycle(index: index, isWarmup: warmup, before: before, workload: workload,
            afterAutoreleasePool: afterPool, settled: settled, memory: sampler.snapshot(), fixtureScopeExited: true)
    }

    private static func perform(mode: Mode, format: ImageExportFormat?, profile: Profile,
                                source: CGImage?, snapshot: ImageExportSnapshot?, input: ImageBackingInput?) throws -> ImageBackingWorkload {
        func imageResult(_ image: CGImage, encodedBytes: Int? = nil) throws -> ImageBackingWorkload {
            try require(image.width == profile.width && image.height == profile.height, "Unexpected image dimensions")
            let reading = try observed()
            withExtendedLifetime(image) { }
            return ImageBackingWorkload(operations: ImageBackingOperationCounts(mode: mode), width: image.width,
                height: image.height, imageBytesPerRow: image.bytesPerRow, rasterBytes: nil, rasterSHA256: nil,
                encodedBytes: encodedBytes, imageStrideStorageBytes: image.bytesPerRow * image.height, whilePayloadLive: reading)
        }
        switch mode {
        case .sourceCreate:
            return try imageResult(CodecExportResourceFixture.fixture(width: profile.width, height: profile.height))
        case .snapshotOnly:
            guard let source else { throw failure("Missing persistent source") }
            let snapshot = try ImageExportSnapshot(image: source)
            return try imageResult(snapshot.image)
        case .rasterDigestOnly:
            guard let source else { throw failure("Missing persistent source") }
            let raster = try CodecExportResourceFixture.raster(source)
            let sha = digest(raster)
            let reading = try observed()
            withExtendedLifetime(raster) { }
            return ImageBackingWorkload(operations: ImageBackingOperationCounts(mode: mode), width: source.width,
                height: source.height, imageBytesPerRow: nil, rasterBytes: raster.count, rasterSHA256: sha,
                encodedBytes: nil, imageStrideStorageBytes: nil, whilePayloadLive: reading)
        case .nativeExport:
            guard let snapshot, let format else { throw failure("Missing native export inputs") }
            let artifact = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: format, quality: 0.81))
            let result = try imageResult(artifact.firstPreview, encodedBytes: artifact.byteCount)
            withExtendedLifetime(artifact) { }
            return result
        case .previewOnly:
            guard let input, let format else { throw failure("Missing immutable reader input") }
            return try imageResult(ImageExportService.preview(data: input.data, format: format))
        case .independentDecodeOnly:
            guard let input, let format else { throw failure("Missing immutable reader input") }
            return try imageResult(independentDecode(input.data, format: format, width: profile.width, height: profile.height))
        }
    }

    /// No raster hash/reference comparison here: those allocate another context
    /// and Data and have their own common control. Cache-immediately requests a
    /// full ImageIO decode; PDF independently rasterizes its single native page.
    static func independentDecode(_ data: Data, format: ImageExportFormat, width: Int, height: Int) throws -> CGImage {
        if format != .pdf {
            return try CodecExportResourceFixture.independentDecode(data, format: format, width: width, height: height)
        }
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              document.numberOfPages == 1, let page = document.page(at: 1),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw failure("Independent PDF decode unavailable")
        }
        let box = page.getBoxRect(.mediaBox)
        try require(abs(box.width - CGFloat(width)) < 0.02 && abs(box.height - CGFloat(height)) < 0.02, "PDF page dimensions differ")
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw failure("Independent PDF raster unavailable") }
        return image
    }

    private static func validatedInput(directory: URL, format: ImageExportFormat, profile: Profile) throws -> ImageBackingInput {
        try autoreleasepool {
            guard let manifest = try JSONSerialization.jsonObject(with: boundedRead(directory.appendingPathComponent(inputManifestName))) as? [String: Any],
                  manifest["status"] as? String == "prepared", manifest["syntheticSource"] as? Bool == true,
                  manifest["profile"] as? String == profile.rawValue, manifest["sourceCommit"] as? String == sourceCommit,
                  manifest["sourceWidth"] as? Int == profile.width, manifest["sourceHeight"] as? Int == profile.height,
                  let pid = manifest["processIdentifier"] as? Int, pid != Int(getpid()),
                  let entries = manifest["inputs"] as? [[String: Any]],
                  let entry = entries.first(where: { $0["format"] as? String == format.filenameExtension }),
                  entry["filename"] as? String == inputName(format), let count = entry["bytes"] as? Int,
                  let sha = entry["sha256"] as? String else { throw failure("Reader needs matching synthetic inputs from another process") }
            let url = directory.appendingPathComponent(inputName(format))
            let data = try boundedRead(url)
            try require(data.count == count && digest(data) == sha, "Prepared input size/hash differs")
            return ImageBackingInput(url: url, data: data, sha256: sha, producerPID: pid)
        }
    }
    private static func boundedRead(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count > 0, count <= 8 * 1_024 * 1_024 else { throw failure("Input exceeds 8 MiB regular-file limit") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: count + 1) ?? Data()
        try require(data.count == count, "Input changed during read")
        return data
    }
    private static func settle(deadline: TimeInterval) async throws {
        try check(deadline)
        try require(ImageExportController.activeSessionCount == 0 && ImageExportService.queue.operationCount == 0,
                    "Active controller/queue contaminates isolated control")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { autoreleasepool { continuation.resume() } }
        }
        await Task.yield()
    }
    private static func observed() throws -> ImageBackingMemoryReading {
        let reading = ImageBackingMemoryReading.current()
        try require(reading.residentBytes != nil && reading.physicalFootprintBytes != nil, "Self Mach RSS/footprint unavailable")
        return reading
    }
    private static func scope(_ mode: Mode) -> String {
        switch mode {
        case .sourceCreate: return "Synthetic CGContext drawing + makeImage only; no snapshot, raster digest, encoder, or decoder"
        case .snapshotOnly: return "Unchanged ImageExportSnapshot on one persistent pre-warmup synthetic source; no source recreation, raster digest, encoder, or decoder"
        case .rasterDigestOnly: return "Existing fixture raster(context draw + Data copy) and SHA256 on one persistent source; no source recreation, snapshot, encoder, or decoder"
        case .nativeExport: return "Unchanged native ImageExportService.encode on one persistent snapshot; production metadata verification and production preview are included; no publication or independent validation"
        case .previewOnly: return "Unchanged ImageExportService.preview on separately prepared immutable Data; fresh reader/thumbnail or PDF render per call; no synthetic source or extra raster digest"
        case .independentDecodeOnly: return "Independent cache-immediate ImageIO full decode or full-page PDF render on separately prepared immutable Data; no source creation, production preview, or extra raster digest/reference comparison"
        }
    }
    private static func claimInvocation() throws {
        try require(!invocationClaimed, "Each workload and preparation requires a fresh process")
        invocationClaimed = true
    }
    private static func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Cooperative deadline exceeded; launcher must bound native stalls")
    }
    private static func inputName(_ format: ImageExportFormat) -> String { "image-backing-input." + format.filenameExtension }
    private static var sourceCommit: String { Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown" }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw failure("Invalid report object") }
        return value
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try autoreleasepool { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Image backing attribution: " + message) }
}

struct ImageBackingOperationCounts: Encodable, Equatable {
    let syntheticSources: Int, snapshots: Int, rasterDigests: Int, nativeExports: Int, productionPreviews: Int, independentDecodes: Int
    init(mode: ImageBackingAttributionFixture.Mode) {
        syntheticSources = mode == .sourceCreate ? 1 : 0
        snapshots = mode == .snapshotOnly ? 1 : 0
        rasterDigests = mode == .rasterDigestOnly ? 1 : 0
        nativeExports = mode == .nativeExport ? 1 : 0
        productionPreviews = mode == .previewOnly || mode == .nativeExport ? 1 : 0
        independentDecodes = mode == .independentDecodeOnly ? 1 : 0
    }
}
private struct ImageBackingInput { let url: URL; let data: Data; let sha256: String; let producerPID: Int }
private struct ImageBackingWorkload: Encodable {
    let operations: ImageBackingOperationCounts
    let width: Int, height: Int
    let imageBytesPerRow: Int?, rasterBytes: Int?, rasterSHA256: String?, encodedBytes: Int?
    let imageStrideStorageBytes: Int?
    let whilePayloadLive: ImageBackingMemoryReading
}
private struct ImageBackingCycle: Encodable {
    let index: Int
    let isWarmup: Bool
    let before: ImageBackingMemoryReading
    let workload: ImageBackingWorkload
    let afterAutoreleasePool: ImageBackingMemoryReading
    let settled: ImageBackingMemoryReading
    let memory: GIFResourceMemoryStatistics
    let fixtureScopeExited: Bool
}
