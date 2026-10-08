import AppKit
import CryptoKit
import Darwin
import ImageIO
import PicShotCore

/// Bounded diagnostic workload in the current app process. It exercises actual
/// production composition with fresh ImageIO decodes, not a synthetic allocator
/// substitute. Only two procedurally generated PNGs are read; no capture or TCC.
/// Observed memory growth is retained for review, never labeled a leak verdict.
enum MultiWindowCaptureResourceFixture {
    static let width = 3840, height = 2160
    static let warmupCount = 4, measuredCount = 12
    static let deadlineSeconds: TimeInterval = 180
    static let reportName = "multi-window-resource.json"
    private static let maximumDiskBytes = 2 * MultiWindowCaptureLimits.temporaryBytes

    /// This environment key affects this diagnostic fixture only. Normal capture
    /// always uses MultiWindowCompositionMode.production.
    static func compositionMode(environment: [String: String]) throws -> MultiWindowCompositionMode {
        guard let value = environment["PICSHOT_MULTIWINDOW_COMPOSITION"] else { return .production }
        guard let mode = MultiWindowCompositionMode(rawValue: value) else { throw MultiWindowCaptureError.incomplete }
        return mode
    }

    @MainActor static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        let mode = try compositionMode(environment: ProcessInfo.processInfo.environment)
        let normalizationBytes = mode == .coreGraphicsBaseline ? 0 : width * height * 4
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + deadlineSeconds
        let manager = FileManager.default
        try manager.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let root = manager.temporaryDirectory.appendingPathComponent("PicShot-MultiWindow-Resource-" + UUID().uuidString, isDirectory: true)
        let reportURL = evidenceDirectory.appendingPathComponent(reportName)
        let environment = ProcessInfo.processInfo.environment
        let diagnosticTailStripFirst = environment["PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST"] == "1"
        try require(!diagnosticTailStripFirst || mode == .coreGraphicsBaseline, "Tail-first diagnostic requires CoreGraphics baseline mode")
        let diagnosticTrace = environment["PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES"] == "1" ? MultiWindowDiagnosticTrace() : nil
        let diagnosticObserve: MultiWindowDiagnosticObserver?
        if let trace = diagnosticTrace {
            diagnosticObserve = { event, window, top in trace.record(event, window: window, stripTop: top) }
        } else { diagnosticObserve = nil }
        var report: [String: Any] = [
            "status": "running", "observationsComplete": false, "activePhase": "inputPreparation", "activeCycleIndex": 0,
            "remainingWarmupCycles": warmupCount, "remainingMeasuredCycles": measuredCount, "fixture": "multi-window-imageio-composition-comparison-v2",
            "compositionMode": mode.rawValue, "productionCompositionMode": MultiWindowCompositionMode.production.rawValue,
            "candidateImplementation": "vimage-canonical-cgimage-quartz-strips-v1",
            "pid": getpid(), "processName": ProcessInfo.processInfo.processName,
            "executablePath": Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "unknown",
            "bundlePath": Bundle.main.bundlePath, "bundleIdentifier": Bundle.main.bundleIdentifier ?? "none",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString, "compiledArchitecture": architecture,
            "executableScope": "Actual current process path above; ZIP/DMG/CLI provenance must be recorded by caller",
            "warmupCycles": warmupCount, "measuredCycles": measuredCount, "windowsPerCycle": 2,
            "sourceWidth": width, "sourceHeight": height, "logicalSourceWidth": 1920, "logicalSourceHeight": 1080,
            "pixelsPerPoint": 2, "outputWidth": 4480, "outputHeight": 2520,
            "diagnosticTailStripFirst": diagnosticTailStripFirst,
            "diagnosticBoundariesEnabled": diagnosticTrace != nil,
            "diagnosticTraceAllocatedBytesBeforeEntry": diagnosticTrace?.allocatedBytes ?? 0,
            "diagnosticStripScope": "Default order remains 0,128,...,2048. Tail-first visits 2048,0,128,...,1920; same 17 clips per input and 128-row maximum. No change to z-order, source identities, decode settings or digest.",
            "maximumSimultaneousProductionRasterBytes": (4480 * 2520 + width * height) * 4 + normalizationBytes,
            "normalizationRasterBytes": normalizationBytes, "ownedRasterLimitBytes": MultiWindowCaptureLimits.ownedRasterBytes,
            "normalizationScope": "Caller-owned extra RGBA raster only; private vImage/ColorSync/decoder scratch remains separate process accounting",
            "maximumTemporaryPNGBytes": maximumDiskBytes, "maximumConcurrentCycleTasks": 1,
            "cooperativeDeadlineSeconds": deadlineSeconds, "perCompositionDeadlineSeconds": 20,
            "outerDeadlineRequiredForNoncooperativeNativeCalls": true,
            "inputImageIOSettings": ["CGImageSourceShouldCache": false, "CGImageSourceShouldCacheImmediately": true],
            "inputReuse": "Same two PNG paths and pixels each cycle; fresh CGImageSource and CGImage for every frame; no decoded image array",
            "digestScope": "SHA-256 over actual owned RGBA output provider bytes; no normalization CGContext. CGDataProviderCopyData can allocate readback bytes; digest phase is separately labeled",
            "ownershipScope": "Weak probes enforce release of input CGImages, CGImageSources and output CGImages; this does not prove release of decoder/kernel backing",
            "backingAccountingScope": ImageBackingTaskVMReading.scope,
            "sampleIntervalSeconds": MultiWindowResourceSampler.interval,
            "zeroLeakClaim": false, "plateauAssessed": false, "memoryStabilityAssessed": false,
            "screenCaptureStarted": false, "permissionRequested": false, "systemScreenshotCommandInvoked": false,
            "userAssetsRead": false, "globalInputPosted": false, "memoryPressureOrPurgeRequested": false
        ]
        let sampler = MultiWindowResourceSampler()
        defer { sampler.stop() }
        var warmups: [[String: Any]] = [], cycles: [[String: Any]] = []
        var phase = "inputPreparation", cycleIndex = 0
        var rootCreated = false
        var activeCycle: [String: Any] = [:]
        var activeOwnership: MultiWindowResourceOwnership?
        var ownedIdentities: Set<OwnedFileIdentity> = []
        do {
            sampler.setPhase("setup.beforeInputPreparation")
            report["fixtureEntryBeforeInputPreparation"] = try memory()
            try write(report, to: reportURL)
            try check(deadline)
            let free = (try manager.attributesOfFileSystem(forPath: manager.temporaryDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard free >= Int64(maximumDiskBytes + 32 * 1024 * 1024) else { throw MultiWindowCaptureError.diskLimit }
            try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); rootCreated = true
            ownedIdentities = try ownedFileIdentities(root)
            let inputs = [root.appendingPathComponent("front.png"), root.appendingPathComponent("back.png")]
            sampler.setPhase("setup.inputGenerationAndPNGEncoding")
            let preparation = Task.detached(priority: .userInitiated) { try prepare(inputs, deadline: deadline) }
            let prepared = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            ownedIdentities = try ownedFileIdentities(root)
            report["fileDescriptorEvidence"] = "Own-process fstat device+inode matching against the owned directory and PNGs, including after unlink; linked path-prefix checks additionally reject unexpected owned paths"
            report["ownedFileIdentityCount"] = ownedIdentities.count
            report["preparedInputs"] = prepared.inputs; report["expectedOutputSHA256"] = prepared.expectedOutputSHA256
            sampler.setPhase("setup.afterInputPreparation")
            report["afterInputPreparationPreWarmup"] = try memory()
            report["inputPreparationScope"] = "Generator RGBA seed buffers, PNG destinations and row-sized oracle buffers have left lexical/autorelease scopes before this boundary"
            try require(try ownedFileDescriptors(root, identities: ownedIdentities).isEmpty, "Input preparation left an owned file descriptor open")
            try write(report, to: reportURL)
            let layout = try makeLayout()
            for index in 0..<(warmupCount + measuredCount) {
                try check(deadline)
                phase = index < warmupCount ? "warmup" : "measured"
                cycleIndex = index < warmupCount ? index + 1 : index - warmupCount + 1
                let label = "\(phase).\(cycleIndex)", ownership = MultiWindowResourceOwnership()
                diagnosticTrace?.begin(phase: phase == "warmup" ? 1 : 2, cycle: cycleIndex)
                let rasterProbe = MultiWindowCompositionResourceProbe()
                sampler.setPhase(label + ".before")
                activeCycle = ["phase": phase, "index": cycleIndex, "before": try memory()]
                activeOwnership = ownership
                report["activePhase"] = phase; report["activeCycleIndex"] = cycleIndex
                report["remainingWarmupCycles"] = warmupCount - warmups.count; report["remainingMeasuredCycles"] = measuredCount - cycles.count
                try write(report, to: reportURL)
                let cycleStarted = ProcessInfo.processInfo.systemUptime
                try await runCycle(layout: layout, inputs: inputs, expectedDigest: prepared.expectedOutputSHA256,
                    ownership: ownership, root: root, deadline: deadline, label: label, sampler: sampler,
                    mode: mode, rasterProbe: rasterProbe,
                    diagnosticTailStripFirst: diagnosticTailStripFirst, diagnosticObserve: diagnosticObserve, cycle: &activeCycle)
                activeCycle["ownedRasterProbe"] = rasterProbe.snapshot
                try require(rasterProbe.snapshot["currentRasterBytes"] == 0, "Completed cycle retained an explicit raster")
                try require(rasterProbe.snapshot["liveCanonicalImages"] == 0, "Completed cycle retained a normalized CGImage wrapper")
                try require(rasterProbe.snapshot["canonicalImagesCreated"] == (mode == .normalizedCandidate ? 2 : 0), "Unexpected canonical image count")
                try require(rasterProbe.snapshot["normalizationCount"] == (mode == .coreGraphicsBaseline ? 0 : 2), "Unexpected normalization count")
                try require(ownership.allReleased, "A completed cycle retained an input, decoder or output object")
                let handles = try ownedFileDescriptors(root, identities: ownedIdentities)
                try require(handles.isEmpty, "A completed cycle left an owned PNG descriptor open")
                sampler.setPhase(label + ".released")
                try await settle(deadline)
                diagnosticObserve?(.cycleAfterRelease, 0, -1)
                activeCycle["afterRelease"] = try memory(); activeCycle["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - cycleStarted
                activeCycle["ownership"] = ownership.report; activeCycle["ownedOpenFileDescriptorsAfter"] = handles.count
                activeCycle["transientSampledPeaksByPhase"] = sampler.phases(prefix: label + ".")
                if phase == "warmup" { warmups.append(activeCycle) } else { cycles.append(activeCycle) }
                activeCycle = [:]; activeOwnership = nil
                if index == warmupCount - 1 { report["afterWarmupBaseline"] = try memory() }
                report["warmups"] = warmups; report["cycles"] = cycles
                report["completedWarmupCycles"] = warmups.count; report["completedMeasuredCycles"] = cycles.count
                try write(report, to: reportURL)
            }
            phase = "cancellation"; report["activePhase"] = phase; try write(report, to: reportURL)
            sampler.setPhase("cancellation.before")
            diagnosticTrace?.begin(phase: 3, cycle: 0)
            let cancelledOwnership = MultiWindowResourceOwnership()
            let cancelled = Task { @MainActor in
                try await SequentialMultiWindowCapture.capture(layout: layout, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 20), mode: mode,
                    diagnosticTailStripFirst: diagnosticTailStripFirst, diagnosticObserve: diagnosticObserve,
                    validate: { try check(deadline) }, frame: { window, _ in
                        try require(cancelledOwnership.liveInputs == 0, "Cancellation acquired overlapping source frames")
                        let image = try await decode(inputs[window.id == 101 ? 0 : 1], expected: window, ownership: cancelledOwnership,
                            deadline: deadline, diagnosticObserve: diagnosticObserve)
                        withUnsafeCurrentTask { $0?.cancel() }
                        return image
                    })
            }
            do {
                _ = try await withTaskCancellationHandler { try await cancelled.value } onCancel: { cancelled.cancel() }
                throw failure("Cancelled composition produced an output")
            }
            catch is CancellationError {}
            try check(deadline)
            try require(cancelledOwnership.inputCount == 1 && cancelledOwnership.allReleased, "Cancellation did not release its sole decoded input")
            diagnosticObserve?(.cancellationAfterRelease, 0, -1)
            report["cancellation"] = ["status": "passed", "ownership": cancelledOwnership.report,
                                      "after": try memory(), "ownedOpenFileDescriptors": try ownedFileDescriptors(root, identities: ownedIdentities).count]
            try require(try ownedFileDescriptors(root, identities: ownedIdentities).isEmpty, "Cancellation left an owned file descriptor open")
            phase = "cleanup"; report["activePhase"] = phase; try write(report, to: reportURL)
            sampler.setPhase("cleanup")
            try manager.removeItem(at: root); rootCreated = false
            try require(!manager.fileExists(atPath: root.path), "Temporary PNG directory survived cleanup")
            try require(try ownedFileDescriptors(root, identities: ownedIdentities).isEmpty, "Unlinked temporary PNG still has an open descriptor")
            try await settle(deadline)
            report["finalAfterCleanup"] = try memory()
            report["temporaryDirectoryRemoved"] = true; report["ownedOpenFileDescriptorsAfterCleanup"] = 0
            report["lateMeasuredIncrements"] = lateIncrements(cycles)
            report["measuredBoundaryIncrements"] = increments(cycles)
            report["setupTransientSampledPeaks"] = sampler.phases(prefix: "setup.")
            sampler.stop(); report["transientSampler"] = sampler.report
            if let diagnosticTrace { report["diagnosticBoundaryTrace"] = diagnosticTrace.report }
            report["warmups"] = warmups; report["cycles"] = cycles
            report["completedWarmupCycles"] = warmups.count; report["completedMeasuredCycles"] = cycles.count
            report["status"] = "observed"; report["observationsComplete"] = true; report["activePhase"] = "completed"
            report["remainingWarmupCycles"] = 0; report["remainingMeasuredCycles"] = 0
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try check(deadline); try write(report, to: reportURL)
            return report
        } catch {
            let original = error
            if rootCreated {
                do { ownedIdentities.formUnion(try ownedFileIdentities(root)); try manager.removeItem(at: root); rootCreated = false }
                catch { report["cleanupError"] = error.localizedDescription }
            }
            sampler.stop()
            report["status"] = ((original as? MultiWindowCaptureError) == .deadline || original is CancellationError) ? "incomplete" : "failed"
            report["incompleteCycle"] = activeCycle; report["incompleteCycleOwnership"] = activeOwnership?.report
            report["error"] = original.localizedDescription; report["incompletePhase"] = phase; report["phaseCycleIndex"] = cycleIndex
            report["observationsComplete"] = false; report["warmups"] = warmups; report["cycles"] = cycles
            report["completedWarmupCycles"] = warmups.count; report["completedMeasuredCycles"] = cycles.count
            report["remainingWarmupCycles"] = warmupCount - warmups.count; report["remainingMeasuredCycles"] = measuredCount - cycles.count
            report["temporaryDirectoryRemoved"] = !manager.fileExists(atPath: root.path)
            report["ownedOpenFileDescriptorsAfterFailure"] = try? ownedFileDescriptors(root, identities: ownedIdentities).count
            report["transientSampler"] = sampler.report; report["finalAfterFailure"] = try? memory()
            if let diagnosticTrace { report["diagnosticBoundaryTrace"] = diagnosticTrace.report }
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try write(report, to: reportURL)
            throw original
        }
    }

    @MainActor private static func runCycle(layout: MultiWindowCaptureLayout, inputs: [URL], expectedDigest: String,
        ownership: MultiWindowResourceOwnership, root: URL, deadline: TimeInterval, label: String,
        sampler: MultiWindowResourceSampler, mode: MultiWindowCompositionMode,
        rasterProbe: MultiWindowCompositionResourceProbe, diagnosticTailStripFirst: Bool,
        diagnosticObserve: MultiWindowDiagnosticObserver?, cycle: inout [String: Any]) async throws {
        sampler.setPhase(label + ".composition")
        let output = try await SequentialMultiWindowCapture.capture(layout: layout,
            deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 20), mode: mode, resourceProbe: rasterProbe,
            diagnosticTailStripFirst: diagnosticTailStripFirst, diagnosticObserve: diagnosticObserve,
            validate: { try check(deadline) }, frame: { window, _ in
                try require(ownership.liveInputs == 0 && ownership.liveDecoders == 0, "A prior source survived into the next acquisition")
                sampler.setPhase(label + ".decode." + String(window.id))
                let image = try await decode(inputs[window.id == 101 ? 0 : 1], expected: window, ownership: ownership,
                    deadline: deadline, diagnosticObserve: diagnosticObserve)
                sampler.setPhase(label + ".composition")
                return image
            })
        ownership.recordOutput(output)
        try require(output.width == layout.width && output.height == layout.height, "Output dimensions changed")
        try require(ownership.liveInputs == 0 && ownership.liveDecoders == 0, "Completed composition retained an input")
        cycle["afterCompositionBeforeDigest"] = try memory()
        sampler.setPhase(label + ".outputDigest")
        diagnosticObserve?(.digestBefore, 0, -1)
        let work = Task.detached(priority: .userInitiated) { try digestOutput(output, deadline: deadline) }
        let digest = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try require(digest == expectedDigest, "Real composed RGBA digest does not match the independent procedural oracle")
        cycle["rgbaSHA256"] = digest; cycle["exactOutputPixels"] = output.width * output.height
        try withExtendedLifetime(output) {
            cycle["afterDigestBeforeOutputRelease"] = try memory()
            diagnosticObserve?(.digestAfter, 0, -1)
        }
        // No image escapes: caller retains scalar report and weak probes only.
    }

    private static func decode(_ url: URL, expected: MultiWindowDescriptor, ownership: MultiWindowResourceOwnership,
                               deadline: TimeInterval, diagnosticObserve: MultiWindowDiagnosticObserver? = nil) async throws -> CGImage {
        diagnosticObserve?(.decodeBefore, expected.id, -1)
        let work = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try check(deadline)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == "public.png",
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
                      (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height,
                      (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8,
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw failure("Fresh ImageIO PNG decode failed")
                }
                try expected.validateRaster(width: image.width, height: image.height)
                guard image.bitsPerComponent == 8, image.bitsPerPixel <= 32,
                      image.bytesPerRow <= MultiWindowCaptureLimits.framePixels * 4 / image.height else { throw MultiWindowCaptureError.pixelLimit }
                ownership.recordInput(image, decoder: source)
                diagnosticObserve?(.decodeImageCreated, expected.id, -1)
                try check(deadline)
                return image
            }
        }
        let image = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        diagnosticObserve?(.decodeReturned, expected.id, -1)
        return image
    }

    private struct Prepared: @unchecked Sendable { let inputs: [[String: Any]]; let expectedOutputSHA256: String }
    private static func prepare(_ urls: [URL], deadline: TimeInterval) throws -> Prepared {
        var identities: [[String: Any]] = []
        for (index, url) in urls.enumerated() {
            let rawDigest = try autoreleasepool { () throws -> String in
                try check(deadline)
                var raw = Data(count: width * height * 4)
                try raw.withUnsafeMutableBytes { bytes in
                    let pixels = bytes.bindMemory(to: UInt8.self)
                    for y in 0..<height {
                        if y % 64 == 0 { try check(deadline) }
                        for x in 0..<width {
                            let value = pixel(x, y, seed: index == 0 ? 17 : 91), offset = (y * width + x) * 4
                            pixels[offset] = value.0; pixels[offset+1] = value.1; pixels[offset+2] = value.2; pixels[offset+3] = value.3
                        }
                    }
                }
                let rawHash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
                guard let provider = CGDataProvider(data: raw as CFData),
                      let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw failure("Could not prepare owned PNG") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw failure("Owned PNG encoding failed") }
                try check(deadline)
                return rawHash
            }
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            try require(size > 0 && size <= MultiWindowCaptureLimits.temporaryBytes, "Owned PNG exceeds disk bound")
            identities.append(["filename": url.lastPathComponent, "bytes": size, "pngSHA256": try fileDigest(url, deadline: deadline), "generatedRGBA_SHA256": rawDigest])
        }
        return Prepared(inputs: identities, expectedOutputSHA256: try oracleDigest(deadline: deadline))
    }
    private static func makeLayout() throws -> MultiWindowCaptureLayout {
        try MultiWindowCaptureLayout(frontToBack: [
            MultiWindowDescriptor(id: 101, ownerPID: 9001, ownerStartedAt: 1, label: "Resource fixture front", bounds: CGRect(x: -320, y: -180, width: 1920, height: 1080), maximumScale: 2),
            MultiWindowDescriptor(id: 202, ownerPID: 9002, ownerStartedAt: 1, label: "Resource fixture back", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), maximumScale: 2)
        ])
    }
    private static func pixel(_ x: Int, _ y: Int, seed: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard x >= 4, y >= 4, x < width - 4, y < height - 4 else { return (0,0,0,0) }
        if y < 8 { return (32,64,96,128) }
        return (UInt8((x / 16 + seed) & 255), UInt8((y / 16 + seed * 3) & 255), UInt8(((x / 64 ^ y / 64) + seed * 7) & 255), 255)
    }
    private static func oracleDigest(deadline: TimeInterval) throws -> String {
        var hash = SHA256(), row = [UInt8](repeating: 0, count: 4480 * 4)
        for y in 0..<2520 {
            if y % 32 == 0 { try check(deadline) }
            for x in 0..<4480 {
                var value: (UInt8, UInt8, UInt8, UInt8) = (0,0,0,0)
                if x >= 640 && y >= 360 && x < 4480 && y < 2520 { value = pixel(x - 640, y - 360, seed: 91) }
                if x < width && y < height {
                    let front = pixel(x, y, seed: 17)
                    if front.3 != 0 {
                        try require(front.3 == 255 || value.3 == 0, "Oracle unexpectedly needs fractional overlap blending")
                        value = front
                    }
                }
                let offset = x * 4
                row[offset] = value.0; row[offset+1] = value.1; row[offset+2] = value.2; row[offset+3] = value.3
            }
            row.withUnsafeBytes { hash.update(bufferPointer: $0) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func digestOutput(_ image: CGImage, deadline: TimeInterval) throws -> String {
        try autoreleasepool {
            try check(deadline)
            guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.bytesPerRow == image.width * 4,
                  let data = image.dataProvider?.data, CFDataGetLength(data) == image.bytesPerRow * image.height,
                  let bytes = CFDataGetBytePtr(data) else { throw failure("Output provider does not expose bounded RGBA bytes") }
            defer { withExtendedLifetime(data) {} }
            var hash = SHA256()
            for row in stride(from: 0, to: image.height, by: 64) {
                try check(deadline)
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.advanced(by: row * image.bytesPerRow),
                    count: min(64, image.height - row) * image.bytesPerRow))
            }
            try check(deadline)
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
    private static func fileDigest(_ url: URL, deadline: TimeInterval) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { try check(deadline); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func memory() throws -> [String: Any] {
        let reading = ImageBackingMemoryReading.current()
        let flat = MultiWindowResourceSampler.flatten(reading)
        try require(MultiWindowResourceSampler.required.allSatisfy { flat[$0] != nil }, "Required memory accounting field is unavailable")
        return ["uptimeSeconds": ProcessInfo.processInfo.systemUptime, "counters": flat,
                "backingAccounting": try JSONSerialization.jsonObject(with: JSONEncoder().encode(reading))]
    }
    private struct OwnedFileIdentity: Hashable { let device: Int64; let inode: UInt64 }
    private static func ownedFileIdentities(_ root: URL) throws -> Set<OwnedFileIdentity> {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        try require(children.count <= 8, "Temporary input directory contains unexpected files")
        var identities: Set<OwnedFileIdentity> = []
        for url in [root] + children {
            var status = stat()
            guard url.path.withCString({ lstat($0, &status) }) == 0 else { throw failure("Cannot record owned file identity") }
            identities.insert(OwnedFileIdentity(device: Int64(status.st_dev), inode: UInt64(status.st_ino)))
        }
        return identities
    }
    private static func ownedFileDescriptors(_ root: URL, identities: Set<OwnedFileIdentity>) throws -> [Int32] {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { throw failure("Cannot enumerate own file descriptors") }
        let capacity = max(32, Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32)
        guard capacity <= 16_384 else { throw failure("Own file descriptor inventory exceeds bound") }
        let buffer = UnsafeMutablePointer<proc_fdinfo>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let received = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
        guard received > 0, Int(received) < capacity * MemoryLayout<proc_fdinfo>.stride, Int(received) % MemoryLayout<proc_fdinfo>.stride == 0 else { throw failure("Own file descriptor inventory changed beyond bound") }
        var owned: [Int32] = []
        let prefixes = Set([root.path, root.resolvingSymlinksInPath().standardizedFileURL.path])
        for index in 0..<(Int(received) / MemoryLayout<proc_fdinfo>.stride) where buffer[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var status = stat()
            guard fstat(buffer[index].proc_fd, &status) == 0 else {
                if errno == EBADF { continue }; throw failure("Cannot inspect own descriptor identity")
            }
            if identities.contains(OwnedFileIdentity(device: Int64(status.st_dev), inode: UInt64(status.st_ino))) {
                owned.append(buffer[index].proc_fd); continue
            }
            var information = vnode_fdinfowithpath()
            let count = proc_pidfdinfo(getpid(), buffer[index].proc_fd, PROC_PIDFDVNODEPATHINFO, &information, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            // A descriptor can close while enumerating. Do not substitute another
            // process or print unrelated paths. Only this owned directory matters.
            guard count == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else {
                if errno == EBADF || errno == ENOENT { continue }
                throw failure("An own-process vnode descriptor could not be inspected")
            }
            let path = withUnsafePointer(to: &information.pvip.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { owned.append(buffer[index].proc_fd) }
        }
        return owned
    }
    private static func increments(_ cycles: [[String: Any]]) -> [[String: Any]] {
        guard cycles.count >= 2 else { return [] }
        return (1..<cycles.count).map { index in
            let before = (cycles[index-1]["afterRelease"] as? [String: Any])?["counters"] as? [String: Int64] ?? [:]
            let after = (cycles[index]["afterRelease"] as? [String: Any])?["counters"] as? [String: Int64] ?? [:]
            var delta: [String: Int64] = [:]
            for key in MultiWindowResourceSampler.required { if let old = before[key], let new = after[key] { delta[key] = new - old } }
            return ["fromMeasuredCycle": index, "toMeasuredCycle": index + 1, "counterDeltaBytes": delta]
        }
    }
    private static func lateIncrements(_ cycles: [[String: Any]]) -> [[String: Any]] { Array(increments(cycles).suffix(4)) }
    private static func settle(_ deadline: TimeInterval) async throws { try check(deadline); try await Task.sleep(nanoseconds: 100_000_000); try check(deadline) }
    private static func check(_ deadline: TimeInterval) throws { try Task.checkCancellation(); guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline } }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> NSError { NSError(domain: "PicShot.MultiWindowResource", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func write(_ report: [String: Any], to url: URL) throws { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "other"
        #endif
    }
}

private final class MultiWindowResourceOwnership: @unchecked Sendable {
    private final class ImageProbe { weak var value: CGImage?; init(_ value: CGImage) { self.value = value } }
    private final class DecoderProbe { weak var value: CGImageSource?; init(_ value: CGImageSource) { self.value = value } }
    private let lock = NSLock()
    private var inputs: [ImageProbe] = [], decoders: [DecoderProbe] = [], outputs: [ImageProbe] = []
    private var maximumInputs = 0
    func recordInput(_ image: CGImage, decoder: CGImageSource) {
        lock.lock(); defer { lock.unlock() }
        inputs.append(ImageProbe(image)); decoders.append(DecoderProbe(decoder))
        maximumInputs = max(maximumInputs, inputs.filter { $0.value != nil }.count)
    }
    func recordOutput(_ image: CGImage) { lock.lock(); outputs.append(ImageProbe(image)); lock.unlock() }
    var inputCount: Int { lock.lock(); defer { lock.unlock() }; return inputs.count }
    var liveInputs: Int { lock.lock(); defer { lock.unlock() }; return inputs.filter { $0.value != nil }.count }
    var liveDecoders: Int { lock.lock(); defer { lock.unlock() }; return decoders.filter { $0.value != nil }.count }
    var allReleased: Bool { lock.lock(); defer { lock.unlock() }; return (inputs + outputs).allSatisfy { $0.value == nil } && decoders.allSatisfy { $0.value == nil } }
    var report: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["inputObjectsCreated": inputs.count, "decoderObjectsCreated": decoders.count, "outputObjectsCreated": outputs.count,
                "maximumConcurrentInputObjects": maximumInputs, "liveInputObjects": inputs.filter { $0.value != nil }.count,
                "liveDecoderObjects": decoders.filter { $0.value != nil }.count, "liveOutputObjects": outputs.filter { $0.value != nil }.count]
    }
}

private final class MultiWindowResourceSampler: @unchecked Sendable {
    static let interval: TimeInterval = 0.05
    static let required = ["resident_size", "phys_footprint", "purgeable_volatile_resident", "purgeable_volatile_virtual", "ledger_purgeable_volatile_compressed", "compressed"]
    private let lock = NSLock(), queue = DispatchQueue(label: "PicShot.MultiWindowResource.Memory")
    private var timer: DispatchSourceTimer?
    private var phase = "entry"
    private var total = Stats(), byPhase: [String: Stats] = [:]
    private struct Stats {
        var samples = 0, timerSamples = 0
        var peak: [String: Int64] = [:], minimum: [String: Int64] = [:], last: [String: Int64] = [:], missing: [String: Int] = [:]
        mutating func record(_ values: [String: Int64], timer: Bool) {
            samples += 1; if timer { timerSamples += 1 }; last = values
            for key in MultiWindowResourceSampler.required {
                if let value = values[key] { peak[key] = max(peak[key] ?? value, value); minimum[key] = min(minimum[key] ?? value, value) }
                else { missing[key, default: 0] += 1 }
            }
        }
        var report: [String: Any] { ["sampleCount": samples, "timerSampleCount": timerSamples, "sampledPeakBytes": peak, "sampledMinimumBytes": minimum, "lastBytes": last, "missingFieldCounts": missing] }
    }
    init() {
        sample(timer: false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample(timer: true) }; self.timer = timer; timer.resume()
    }
    func setPhase(_ value: String) { lock.lock(); phase = value; lock.unlock(); sample(timer: false) }
    private func sample(timer: Bool) {
        lock.lock(); let label = phase; lock.unlock()
        let values = Self.flatten(ImageBackingMemoryReading.current())
        lock.lock(); defer { lock.unlock() }
        total.record(values, timer: timer)
        let boundedLabel = byPhase[label] != nil || byPhase.count < 127 ? label : "overflow"
        byPhase[boundedLabel, default: Stats()].record(values, timer: timer)
    }
    func stop() { guard let timer else { return }; timer.cancel(); self.timer = nil; queue.sync {}; sample(timer: false) }
    deinit { timer?.cancel() }
    func phases(prefix: String) -> [String: Any] { lock.lock(); defer { lock.unlock() }; return byPhase.filter { $0.key.hasPrefix(prefix) }.mapValues(\.report) }
    var report: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["scope": "50ms self-task samples, not kernel lifetime peaks; phases label observations without proving allocation ownership",
                "maximumPhaseAggregates": 128, "continuousSampleArraysRetained": false,
                "pairedTaskInfoCallsAreAtomic": false, "missingFieldsBecomeZero": false,
                "total": total.report, "phases": byPhase.mapValues(\.report)]
    }
    static func flatten(_ reading: ImageBackingMemoryReading) -> [String: Int64] {
        var values: [String: Int64] = [:]
        for key in ["resident_size", "phys_footprint", "compressed"] {
            if let value = reading.standard.bytes[key], value <= UInt64(Int64.max) { values[key] = Int64(value) }
        }
        for key in ["purgeable_volatile_resident", "purgeable_volatile_virtual"] {
            if let value = reading.purgeable.bytes[key], value <= UInt64(Int64.max) { values[key] = Int64(value) }
        }
        values["ledger_purgeable_volatile_compressed"] = reading.purgeable.ledgerBytes["ledger_purgeable_volatile_compressed"]
        return values
    }
}
