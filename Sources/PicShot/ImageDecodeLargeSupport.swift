import AppKit
import Foundation
import PicShotCodecCore

struct ImageDecodeLargeInput: Sendable {
    let profile: ImageDecodeDiagnosticProfile
    let png: Data, reference: Data
    let pngSHA: String, referenceSHA: String
    let producerPID: Int
}
@MainActor
enum ImageDecodeLargeSupport {
    static let inputProtocol = "image-decode-large-input-v2"
    static let parentProtocol = "image-decode-large-parent-v2"
    static let reportBytes = 2_097_152
    static let parentMemoryBytes: UInt64 = 536_870_912
    static var sourceCommit: String { Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown" }
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func prepare(profile: ImageDecodeDiagnosticProfile, directory: URL) throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 60
        let sampler = ImageDecodeMemorySampler(); defer { sampler.stop() }
        let payload: [String: Any] = try autoreleasepool {
            try check(deadline, sampler: sampler)
            let source = try CodecExportResourceFixture.fixture(width: profile.sourceWidth, height: profile.sourceHeight)
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: source), options: .init(format: .png))
            try check(deadline, sampler: sampler)
            guard artifact.data.count <= ImageDecodeDiagnosticLimits.pngBytes, artifact.firstPreview.width == profile.previewWidth,
                  artifact.firstPreview.height == profile.previewHeight else { throw ImageDecodeDiagnosticError.invalidInput }
            let reference = try CodecExportResourceFixture.raster(artifact.firstPreview)
            guard reference.count == profile.rasterBytes else { throw ImageDecodeDiagnosticError.invalidInput }
            try ImageExportService.publish(artifact, to: directory.appendingPathComponent("input.png"))
            try reference.write(to: directory.appendingPathComponent("reference.rgba"), options: .withoutOverwriting)
            return ["protocol": inputProtocol, "status": "prepared", "profile": profile.rawValue, "sourceCommit": sourceCommit,
                "architecture": architecture, "processIdentifier": Int(getpid()), "sourceWidth": profile.sourceWidth, "sourceHeight": profile.sourceHeight,
                "previewWidth": profile.previewWidth, "previewHeight": profile.previewHeight, "rawBytes": reference.count,
                "pngBytes": artifact.byteCount, "pngSHA256": ImageDecodeDiagnosticLimits.digest(artifact.data), "rawSHA256": ImageDecodeDiagnosticLimits.digest(reference),
                "syntheticSource": true, "pattern": "Deterministic structured alpha/color tiles; not a photo or incompressible-screen benchmark",
                "rawLayout": "premultipliedLast RGBA8 byteOrder32Big sRGB", "screenCaptureAttempted": false]
        }
        sampler.stop(); try check(deadline, sampler: sampler)
        var report = payload; report["preparationSeconds"] = ProcessInfo.processInfo.systemUptime - started
        report["preparationSampledMemory"] = try object(sampler.snapshot()); report["fullSourcePreparationExcludedFromRepeatedDecode"] = true
        try write(report, to: directory.appendingPathComponent("image-decode-large-inputs.json")); return report
    }
    static func input(profile: ImageDecodeDiagnosticProfile, directory: URL) throws -> ImageDecodeLargeInput {
        let data = try read(directory.appendingPathComponent("image-decode-large-inputs.json"), maximum: 32_768)
        guard let m = try JSONSerialization.jsonObject(with: data) as? [String: Any], m["protocol"] as? String == inputProtocol,
              m["status"] as? String == "prepared", m["profile"] as? String == profile.rawValue, m["sourceCommit"] as? String == sourceCommit,
              m["architecture"] as? String == architecture, m["syntheticSource"] as? Bool == true,
              m["sourceWidth"] as? Int == profile.sourceWidth, m["sourceHeight"] as? Int == profile.sourceHeight,
              m["previewWidth"] as? Int == profile.previewWidth, m["previewHeight"] as? Int == profile.previewHeight,
              m["rawBytes"] as? Int == profile.rasterBytes, let pngCount = m["pngBytes"] as? Int,
              let pngSHA = m["pngSHA256"] as? String, let rawSHA = m["rawSHA256"] as? String,
              let producer = m["processIdentifier"] as? Int, producer != Int(getpid()) else { throw ImageDecodeDiagnosticError.invalidInput }
        let png = try read(directory.appendingPathComponent("input.png"), maximum: ImageDecodeDiagnosticLimits.pngBytes)
        let raw = try read(directory.appendingPathComponent("reference.rgba"), maximum: profile.rasterBytes)
        guard png.count == pngCount, raw.count == profile.rasterBytes, ImageDecodeDiagnosticLimits.digest(png) == pngSHA,
              ImageDecodeDiagnosticLimits.digest(raw) == rawSHA else { throw ImageDecodeDiagnosticError.invalidInput }
        return .init(profile: profile, png: png, reference: raw, pngSHA: pngSHA, referenceSHA: rawSHA, producerPID: producer)
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, properties.isRegularFile == true, properties.isSymbolicLink != true, let size = properties.fileSize,
              size > 0, size <= maximum else { throw ImageDecodeDiagnosticError.invalidInput }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: size + 1) ?? Data()
        guard data.count == size else { throw ImageDecodeDiagnosticError.invalidInput }; return data
    }
    static func check(_ deadline: Double, sampler: ImageDecodeMemorySampler? = nil) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ImageDecodeDiagnosticError.deadline }
        let memory = try observe()
        guard (memory.residentBytes ?? UInt64.max) <= parentMemoryBytes, (memory.footprintBytes ?? UInt64.max) <= parentMemoryBytes else { throw ImageDecodeDiagnosticError.memoryLimit }
        if let peaks = sampler?.snapshot(), peaks.residentBytes > parentMemoryBytes || peaks.footprintBytes > parentMemoryBytes { throw ImageDecodeDiagnosticError.memoryLimit }
    }
    static func observe() throws -> ImageDecodeMemoryReading { let value = ImageDecodeMemoryReading.current(); guard value.usable else { throw ImageDecodeDiagnosticError.failed }; return value }
    static func settle(_ seconds: Double, deadline: Double) async throws {
        try check(deadline); guard ProcessInfo.processInfo.systemUptime + seconds < deadline else { throw ImageDecodeDiagnosticError.deadline }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); await Task.yield(); try check(deadline)
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw ImageDecodeDiagnosticError.invalidProtocol }; return object
    }
    static func write(_ report: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        guard data.count <= reportBytes else { throw ImageDecodeDiagnosticError.invalidProtocol }; try data.write(to: url, options: .atomic)
    }
    static func base(mode: String, input: ImageDecodeLargeInput) -> [String: Any] {
        ["protocol": parentProtocol, "status": "running", "mode": mode, "profile": input.profile.rawValue, "sourceCommit": sourceCommit,
         "architecture": architecture, "processIdentifier": Int(getpid()), "inputPreparationProcessIdentifier": input.producerPID,
         "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
         "sourceWidth": input.profile.sourceWidth, "sourceHeight": input.profile.sourceHeight,
         "previewWidth": input.profile.previewWidth, "previewHeight": input.profile.previewHeight, "rasterBytes": input.profile.rasterBytes,
         "maximumPreviewDimension": 1024, "maximumPreviewBytes": 4_194_304, "maximumEncodedBytes": ImageDecodeDiagnosticLimits.pngBytes,
         "pngSHA256": input.pngSHA, "rawSHA256": input.referenceSHA, "pixelTolerance": 0,
         "parentMemoryWatchdogBytes": parentMemoryBytes, "childMemoryWatchdogBytes": ImageDecodeDiagnosticLimits.residentWatchdogBytes,
         "parentLossVerified": false, "parentLossScope": "Early parent death or hard child exit can strand jobs; no orphan reaper has been proven",
         "screenCaptureAttempted": false, "networkAttempted": false, "preferencesWritten": false, "allocatorReliefCalls": 0,
         "validationScope": "Same bundle/helper signature and path checks on every child launch; no cache, fast path or helper reuse",
         "memoryScope": "Separate self Mach calls, sampled process peaks and receipt pairs; not atomic, not hard quotas, not unique system RAM. File cache/GPU/WindowServer excluded",
         "interpretation": "Bounded diagnostic observation only; no production-memory remedy or whole-export performance claim"]
    }
}

enum ImageDecodeLargeRaster {
    static func ownedImage(_ raw: Data, profile: ImageDecodeDiagnosticProfile, tracker: ImageDrawAllocationTracker) throws -> CGImage {
        guard raw.count == profile.rasterBytes, profile.rasterBytes <= 4_194_304 else { throw ImageDecodeDiagnosticError.invalidInput }
        let lease = try ImageDecodeLargeBytes(raw, tracker: tracker)
        return try makeImage(lease, profile: profile)
    }
    private static func makeImage(_ bytes: ImageDecodeLargeBytes, profile: ImageDecodeDiagnosticProfile) throws -> CGImage {
        let retained = Unmanaged.passRetained(bytes)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: UnsafeRawPointer(bytes.pointer), size: profile.rasterBytes,
            releaseData: { info, _, count in
                guard let info else { return }
                let lease = Unmanaged<ImageDecodeLargeBytes>.fromOpaque(info).takeRetainedValue(); lease.callback(count)
            }) else { retained.release(); throw ImageDecodeDiagnosticError.failed }
        guard let image = CGImage(width: profile.previewWidth, height: profile.previewHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: profile.previewWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: ImageDrawDestination.bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ImageDecodeDiagnosticError.failed }
        return image
    }
}
private final class ImageDecodeLargeBytes {
    let pointer: UnsafeMutableRawPointer, count: Int
    private let tracker: ImageDrawAllocationTracker
    init(_ raw: Data, tracker: ImageDrawAllocationTracker) throws {
        try tracker.reserve(raw.count); self.tracker = tracker; count = raw.count
        pointer = .allocate(byteCount: raw.count, alignment: 64)
        raw.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: raw.count) }
    }
    func callback(_ count: Int) { tracker.callback(size: count) }
    deinit { pointer.deallocate(); tracker.freed(count) }
}
