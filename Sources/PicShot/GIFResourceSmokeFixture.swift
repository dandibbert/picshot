import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Explicit installed-smoke entry point only. No capture APIs, audio devices,
/// user media, network, defaults, or TCC grants are used. Results describe this
/// bounded synthetic workload; they are not evidence of zero leaks.
enum GIFResourceSmokeFixture {
    struct Profile: Equatable, Sendable {
        let name: String
        let width: Int
        let height: Int
        let frameCount: Int
        let outputDimension: Int
        let warmupCount: Int
        let measuredCount: Int
        let cancelAfterFrames: Int
        let frameRate = 12

        static let installedSmoke = Profile(name: "installed-30-second", width: 640, height: 360,
            frameCount: 360, outputDimension: 480, warmupCount: 1, measuredCount: 4, cancelAfterFrames: 36)
        /// Small integration test, deliberately identified separately in evidence.
        static let quickTest = Profile(name: "unit-test-short", width: 128, height: 72,
            frameCount: 24, outputDimension: 96, warmupCount: 1, measuredCount: 2, cancelAfterFrames: 4)

        var duration: Double { Double(frameCount) / Double(frameRate) }
        var options: GIFExportOptions {
            GIFExportOptions(frameRate: Double(frameRate), maximumDimension: outputDimension,
                             maximumDuration: duration, maximumFrames: frameCount)
        }
    }

    /// Returns a JSON-compatible object and also writes gif-resource.json, even
    /// on a verification failure when the evidence directory remains writable.
    /// Call serially, after other smoke work has finished its helper processes.
    static func verify(evidenceDirectory: URL, profile: Profile = .installedSmoke) async throws -> [String: Any] {
        guard evidenceDirectory.isFileURL else { throw failure("Evidence directory must be local") }
        try require(profile == .installedSmoke || profile == .quickTest, "Unknown bounded fixture profile")
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let reportURL = evidenceDirectory.appendingPathComponent("gif-resource.json")
        let directory = files.temporaryDirectory.appendingPathComponent("PicShot-GIF-Resource-" + UUID().uuidString,
                                                                         isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let started = ProcessInfo.processInfo.systemUptime
        var report: [String: Any] = [
            "status": "running", "profile": profile.name, "captureStarted": false, "audioStarted": false,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "externalDownloads": false, "warmupExportCount": profile.warmupCount,
            "measuredExportCount": profile.measuredCount, "sourceFrames": profile.frameCount,
            "sourceWidth": profile.width, "sourceHeight": profile.height, "sourceFrameRate": profile.frameRate,
            "sourceDurationSeconds": profile.duration, "exportMaximumDimension": profile.outputDimension,
            "sampleIntervalSeconds": GIFResourceMemorySampler.interval,
            "memoryScope": "main process only; AVFoundation service/GPU memory is not included",
            "peakScope": "export-only maximum successful RSS/physical-footprint samples, not kernel lifetime peaks; 50 ms timer plus frame-progress boundaries, including synchronous ImageIO finalization",
            "resourceScope": "authored changing video, warm-up then serial GIF exports; ImageIO can retain internal buffers; sampled peaks and post-export growth are observational regression evidence, not a zero-leak claim or a maximum-size/sustained-recording test",
            "sourceProvenance": "original deterministic tiled RGB animation generated in this fixture",
            "maximumSourceBytes": 16 * 1_024 * 1_024, "maximumOutputBytes": GIFExporter.maximumOutputBytes,
            "diskScope": "one source plus one output/partial at a time; source size is checked after synthesis, output has the production 64 MiB write limit; only JSON is retained",
            "runtimeScope": "fixed work count and 90-second cooperative source-writer deadline; installed smoke launcher owns the outer process timeout, including synchronous ImageIO stalls",
            "temporaryDirectoryRemoved": false
        ]
        do {
            let source = try await makeMovie(in: directory, profile: profile)
            let sourceBytes = try fileBytes(source)
            try require(sourceBytes > 0 && sourceBytes <= 16 * 1_024 * 1_024, "Synthetic input exceeded its disk budget")
            report["sourceBytes"] = sourceBytes
            let asset = AVURLAsset(url: source)
            let sourceDuration = try await asset.load(.duration).seconds
            try require(abs(sourceDuration - profile.duration) < 0.02, "Synthetic source duration differs")
            let plan = try GIFFramePlan(duration: sourceDuration, options: profile.options)
            try require(plan.frameCount == profile.frameCount, "Synthetic source did not produce the expected frame plan")
            report["expectedOutputFrames"] = plan.frameCount
            var warmups: [[String: Any]] = []
            for _ in 0..<profile.warmupCount {
                warmups.append(try await runExport(source: source, directory: directory, profile: profile, plan: plan))
            }
            report["warmupExports"] = warmups
            let baseline = GIFResourceMemoryReading.current()
            try require(baseline.residentBytes != nil, "Main-process RSS measurement unavailable")
            report["baselineAfterWarmup"] = try object(baseline)
            var measured: [[String: Any]] = []
            var settled: [GIFResourceMemoryReading] = []
            var peaks: [GIFResourceMemoryReading] = []
            for _ in 0..<profile.measuredCount {
                let run = try await runExport(source: source, directory: directory, profile: profile, plan: plan)
                measured.append(run)
                // Persist completed phases if a later export fails.
                report["exports"] = measured
                let end = GIFResourceMemoryReading.current()
                settled.append(end)
                let metrics = run["memory"] as? [String: Any] ?? [:]
                peaks.append(GIFResourceMemoryReading(residentBytes: (metrics["peakResidentBytes"] as? NSNumber)?.uint64Value,
                    physicalFootprintBytes: (metrics["peakPhysicalFootprintBytes"] as? NSNumber)?.uint64Value))
            }
            report["postExportSettledSamples"] = try settled.map { try object($0) }
            let rss = assessment(baseline: baseline.residentBytes, settled: settled.map(\.residentBytes),
                                 peaks: peaks.map(\.residentBytes))
            let footprint = assessment(baseline: baseline.physicalFootprintBytes, settled: settled.map(\.physicalFootprintBytes),
                                       peaks: peaks.map(\.physicalFootprintBytes))
            report["residentAssessment"] = try object(rss)
            report["physicalFootprintAssessment"] = try object(footprint)
            report["cancellation"] = try await runExport(source: source, directory: directory, profile: profile,
                                                          plan: plan, cancelAfterFrames: profile.cancelAfterFrames)
            report["finalAfterCancellation"] = try object(GIFResourceMemoryReading.current())
            try files.removeItem(at: directory)
            try require(removalConfirmed(directory), "Synthetic media directory cleanup not confirmed")
            report["temporaryDirectoryRemoved"] = true
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            // Deliberately generous fixed smoke envelopes, not measured results
            // or production memory guarantees. Missing footprint is disclosed;
            // missing RSS is a failure, never silently reported as zero bytes.
            let passed = rss.withinEnvelope == true && (footprint.withinEnvelope ?? true)
            report["status"] = passed ? "passed" : "failed"
            try write(report, to: reportURL)
            try require(passed, "GIF memory observations exceeded the bounded smoke envelope; see gif-resource.json")
            return report
        } catch {
            try? files.removeItem(at: directory)
            report["temporaryDirectoryRemoved"] = removalConfirmed(directory)
            report["status"] = "failed"
            report["error"] = error.localizedDescription
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try? write(report, to: reportURL)
            throw error
        }
    }

    private static func runExport(source: URL, directory: URL, profile: Profile, plan: GIFFramePlan,
                                  cancelAfterFrames: Int? = nil) async throws -> [String: Any] {
        let output = directory.appendingPathComponent("output.gif")
        let sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        let progress = GIFResourceProgress(frameCount: plan.frameCount, cancelAfterFrames: cancelAfterFrames)
        let started = ProcessInfo.processInfo.systemUptime
        var cancellationObserved = false
        // Isolate deliberate cancellation from the smoke caller's task. Canceling
        // the caller here would also cancel its settling delay and later phases.
        let worker = Task {
            try await GIFExporter.export(sourceURL: source, destinationURL: output, options: profile.options) { value in
                sampler.sample()
                if progress.record(value) {
                    // Cancel the actual exporting task after completed AddImage
                    // calls, rather than canceling before the first await.
                    withUnsafeCurrentTask { task in
                        if let task { progress.didRequestCancellation(); task.cancel() }
                    }
                }
            }
        }
        do {
            _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        } catch is CancellationError {
            guard !Task.isCancelled, cancelAfterFrames != nil, progress.cancellationRequested else { throw CancellationError() }
            cancellationObserved = true
        }
        sampler.stop()
        let metrics = sampler.snapshot()
        try require(metrics.residentSampleCount > 0, "No valid RSS samples during export")
        try require(progress.isValid, "Export progress was missing, non-monotonic, or outside 0...1")
        var result: [String: Any] = ["memory": try object(metrics),
            "exportElapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "progressCallbackCount": progress.callbackCount, "lastProgress": progress.lastValue,
            "framesSubmittedBeforeReturn": progress.framesSubmitted,
            "cancellationRequested": progress.cancellationRequested, "cancellationObserved": cancellationObserved]
        if let cancelAfterFrames {
            try require(cancellationObserved && progress.framesSubmitted >= cancelAfterFrames &&
                        progress.framesSubmitted < plan.frameCount, "Cancellation did not interrupt an active export")
            try require(removalConfirmed(output), "Cancelled export published a destination")
            result["cancelAfterFrames"] = cancelAfterFrames
            result["destinationAbsent"] = true
        } else {
            try require(progress.lastValue == 1, "Successful export did not finish progress")
            // Validation is deliberately outside the export sampler. Cache-off
            // sequential decoding cannot masquerade as encoder peak memory.
            result["output"] = try validate(output: output, profile: profile, plan: plan)
            try FileManager.default.removeItem(at: output)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try require(Set(remaining) == [source.lastPathComponent], "Export left a destination or hidden partial GIF")
        result["partialFilesRemaining"] = 0
        // Let completion/autorelease work settle, without forcing malloc trims or
        // hiding retained buffers. The fixed delay is included in runtime.
        try await Task.sleep(nanoseconds: 600_000_000)
        result["settledAfterValidationAndCleanup"] = try object(GIFResourceMemoryReading.current())
        return result
    }

    static func validate(output: URL, profile: Profile, plan: GIFFramePlan) throws -> [String: Any] {
        try autoreleasepool {
            let bytes = try fileBytes(output)
            try require(bytes > 0 && bytes <= GIFExporter.maximumOutputBytes, "GIF output exceeds byte bound")
            let noCache = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(output as CFURL, noCache),
                  CGImageSourceGetStatus(source) == .statusComplete else { throw failure("GIF is not complete/readable") }
            try require(CGImageSourceGetCount(source) == plan.frameCount, "GIF frame count differs from plan")
            var duration = 0.0
            var fingerprints = Set<UInt64>()
            var dimensions: Set<String> = []
            for index in 0..<plan.frameCount {
                try autoreleasepool {
                    guard let frame = CGImageSourceCreateImageAtIndex(source, index, noCache),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, index, noCache) as? [CFString: Any],
                          let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                          let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? NSNumber
                    else { throw failure("Unreadable GIF frame or delay at \(index)") }
                    let expectedHeight = Int((Double(profile.height) * Double(profile.outputDimension) / Double(profile.width)).rounded())
                    try require(frame.width == profile.outputDimension && abs(frame.height - expectedHeight) <= 1,
                                "GIF downscaled frame dimensions differ at \(index)")
                    try require(abs(delay.doubleValue - plan.delay(for: index)) <= 0.011, "GIF frame delay differs at \(index)")
                    duration += delay.doubleValue
                    dimensions.insert("\(frame.width)x\(frame.height)")
                    fingerprints.insert(try fingerprint(frame))
                }
            }
            try require(abs(duration - plan.duration) <= 0.02, "GIF playback duration differs")
            try require(fingerprints.count >= min(plan.frameCount, 32), "Synthetic GIF contains too few distinct decoded frames")
            return ["framesDecoded": plan.frameCount, "dimensions": dimensions.sorted(), "bytes": bytes,
                    "playbackDurationSeconds": duration, "distinctDecodedThumbnailFingerprints": fingerprints.count,
                    "validation": "all frames decoded serially with ImageIO cache disabled; 16x9 RGBA fingerprints are diversity checks, not fidelity hashes"]
        }
    }

    private static func fingerprint(_ image: CGImage) throws -> UInt64 {
        var rgba = [UInt8](repeating: 0, count: 16 * 9 * 4)
        try rgba.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: 16, height: 9, bitsPerComponent: 8,
                bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw failure("Could not fingerprint decoded GIF") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        return rgba.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private static func makeMovie(in directory: URL, profile: Profile) async throws -> URL {
        let url = directory.appendingPathComponent("authored-animation.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: profile.width, AVVideoHeightKey: profile.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000,
                AVVideoMaxKeyFrameIntervalKey: profile.frameRate, AVVideoAllowFrameReorderingKey: false]
        ])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: profile.width, kCVPixelBufferHeightKey as String: profile.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        try require(writer.canAdd(input), "H.264 synthetic writer input unavailable")
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? failure("Synthetic writer could not start") }
        writer.startSession(atSourceTime: .zero)
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        for index in 0..<profile.frameCount {
            try Task.checkCancellation()
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Synthetic video generation timed out")
            while !input.isReadyForMoreMediaData {
                try require(writer.status == .writing && ProcessInfo.processInfo.systemUptime < deadline,
                            "Synthetic video writer stalled")
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try autoreleasepool {
                var buffer: CVPixelBuffer?
                let status = CVPixelBufferCreate(kCFAllocatorDefault, profile.width, profile.height,
                    kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
                guard status == kCVReturnSuccess, let buffer else { throw failure("Synthetic pixel buffer unavailable") }
                try fill(buffer, frame: index, profile: profile)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: Int32(profile.frameRate)))
                else { throw writer.error ?? failure("Synthetic frame append failed") }
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(profile.frameCount), timescale: Int32(profile.frameRate)))
        input.markAsFinished()
        // Poll after requesting completion so a stuck fixture writer is bounded
        // and cancellation does not wait forever for a callback continuation.
        writer.finishWriting { }
        while writer.status == .writing {
            try Task.checkCancellation()
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Synthetic writer finalization timed out")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard writer.status == .completed else { throw writer.error ?? failure("Synthetic video not finalized") }
        return url
    }

    private static func fill(_ buffer: CVPixelBuffer, frame index: Int, profile: Profile) throws {
        try require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess, "Synthetic buffer lock failed")
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw failure("Synthetic pixel storage unavailable") }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        // Every frame changes across the raster. Coarse tiles keep the encoded
        // source reasonable while exercising changing palettes. Unlock before
        // passing the buffer to AVAssetWriter's potentially asynchronous encoder.
        for y in 0..<profile.height { for x in 0..<profile.width {
            let offset = y * stride + x * 4
            let tile = ((x + index * 7) / 16 + (y + index * 3) / 12) % 8
            pixels[offset] = UInt8((tile * 29 + index * 11) % 256)
            pixels[offset + 1] = UInt8((y / 3 + index * 5 + tile * 19) % 256)
            pixels[offset + 2] = UInt8((x / 3 + index * 13 + tile * 17) % 256)
            pixels[offset + 3] = 255
        } }
    }

    static func assessment(baseline: UInt64?, settled: [UInt64?], peaks: [UInt64?]) -> GIFResourceAssessment {
        GIFResourceAssessment(baseline: baseline, settled: settled, peaks: peaks)
    }
    private static func fileBytes(_ url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw failure("File size unavailable") }
        return size
    }
    private static func removalConfirmed(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var value = stat()
            return lstat(path, &value) != 0 && errno == ENOENT
        }
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        else { throw failure("Invalid evidence object") }
        return object
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PicShot.GIFResourceSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct GIFResourceMemoryReading: Encodable, Equatable, Sendable {
    let residentBytes: UInt64?
    let physicalFootprintBytes: UInt64?

    static func current() -> Self {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        return Self(residentBytes: basicResult == KERN_SUCCESS ? basic.resident_size : nil,
                    physicalFootprintBytes: vmResult == KERN_SUCCESS ? vm.phys_footprint : nil)
    }
}

struct GIFResourceMemoryStatistics: Encodable, Equatable, Sendable {
    private(set) var residentSampleCount = 0
    private(set) var physicalFootprintSampleCount = 0
    private(set) var failedResidentSampleCount = 0
    private(set) var failedPhysicalFootprintSampleCount = 0
    private(set) var timerTickCount = 0
    private(set) var boundarySampleCount = 0
    private(set) var peakResidentBytes: UInt64?
    private(set) var peakPhysicalFootprintBytes: UInt64?

    mutating func record(_ reading: GIFResourceMemoryReading, isTimer: Bool = false) {
        if isTimer { timerTickCount += 1 } else { boundarySampleCount += 1 }
        if let bytes = reading.residentBytes {
            residentSampleCount += 1; peakResidentBytes = max(peakResidentBytes ?? bytes, bytes)
        } else { failedResidentSampleCount += 1 }
        if let bytes = reading.physicalFootprintBytes {
            physicalFootprintSampleCount += 1; peakPhysicalFootprintBytes = max(peakPhysicalFootprintBytes ?? bytes, bytes)
        } else { failedPhysicalFootprintSampleCount += 1 }
    }
}

/// Generous deterministic regression gates, not a claim that ImageIO streams
/// all encoded data or that memory use is independent of frame count/resolution.
struct GIFResourceAssessment: Encodable, Equatable, Sendable {
    let sampledPeakGrowthBytes: Int64?
    let finalSettledGrowthBytes: Int64?
    let lastIntervalSettledGrowthBytes: Int64?
    let settledRangeBytes: UInt64?
    let observationsComplete: Bool
    let withinEnvelope: Bool?
    let configuredPeakGrowthLimitBytes: Int64 = 384 * 1_024 * 1_024
    let configuredFinalGrowthLimitBytes: Int64 = 96 * 1_024 * 1_024
    let configuredLastIntervalGrowthLimitBytes: Int64 = 32 * 1_024 * 1_024

    init(baseline: UInt64?, settled: [UInt64?], peaks: [UInt64?]) {
        let ends = settled.compactMap { $0 }, maxima = peaks.compactMap { $0 }
        guard let baseline, baseline <= UInt64(Int64.max), settled.count >= 2,
              ends.count == settled.count, maxima.count == peaks.count, peaks.count == settled.count,
              ends.allSatisfy({ $0 <= UInt64(Int64.max) }), maxima.allSatisfy({ $0 <= UInt64(Int64.max) }) else {
            sampledPeakGrowthBytes = nil; finalSettledGrowthBytes = nil; lastIntervalSettledGrowthBytes = nil
            settledRangeBytes = nil; observationsComplete = false; withinEnvelope = nil; return
        }
        let peak = Int64(maxima.max()!) - Int64(baseline)
        let final = Int64(ends.last!) - Int64(baseline)
        let last = Int64(ends[ends.count - 1]) - Int64(ends[ends.count - 2])
        sampledPeakGrowthBytes = peak; finalSettledGrowthBytes = final; lastIntervalSettledGrowthBytes = last
        settledRangeBytes = ends.max()! - ends.min()!; observationsComplete = true
        withinEnvelope = peak <= configuredPeakGrowthLimitBytes && final <= configuredFinalGrowthLimitBytes &&
            last <= configuredLastIntervalGrowthLimitBytes
    }
}

/// Timer queue is independent of the task executing ImageIO's synchronous
/// finalization. Constant-space counters only; no per-tick arrays or images.
private final class GIFResourceMemorySampler: @unchecked Sendable {
    static let interval = 0.05
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "PicShot.GIFResourceSmoke.Memory")
    private var timer: DispatchSourceTimer?
    private var statistics = GIFResourceMemoryStatistics()

    init() {
        sample()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample(isTimer: true) }
        self.timer = timer
        timer.resume()
    }
    func sample(isTimer: Bool = false) {
        let reading = GIFResourceMemoryReading.current()
        lock.lock(); defer { lock.unlock() }; statistics.record(reading, isTimer: isTimer)
    }
    func stop() {
        // Called only by the export owner, never the sampling queue.
        guard let timer else { return }
        timer.cancel(); self.timer = nil
        queue.sync { }
        sample()
    }
    func snapshot() -> GIFResourceMemoryStatistics { lock.lock(); defer { lock.unlock() }; return statistics }
    deinit { timer?.cancel() }
}

/// Callbacks are synchronous and sequential in GIFExporter. Locking also makes
/// the probe safe to inspect after an awaited task finishes on another executor.
private final class GIFResourceProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let frameCount: Int
    private let cancelAfterFrames: Int?
    private var valid = true
    private var callbacks = 0
    private var last = 0.0
    private var frames = 0
    private var requested = false
    init(frameCount: Int, cancelAfterFrames: Int?) { self.frameCount = frameCount; self.cancelAfterFrames = cancelAfterFrames }
    func record(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !value.isFinite || value < last || !(0...1).contains(value) || (callbacks == 0 && value != 0) { valid = false }
        callbacks += 1; last = value
        if value.isFinite, (0...1).contains(value) { frames = min(frameCount, Int((value * Double(frameCount + 1)).rounded())) }
        return cancelAfterFrames.map { frames >= $0 && !requested } ?? false
    }
    func didRequestCancellation() { lock.lock(); defer { lock.unlock() }; requested = true }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid && callbacks > 0 }
    var callbackCount: Int { lock.lock(); defer { lock.unlock() }; return callbacks }
    var lastValue: Double { lock.lock(); defer { lock.unlock() }; return last }
    var framesSubmitted: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var cancellationRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}
