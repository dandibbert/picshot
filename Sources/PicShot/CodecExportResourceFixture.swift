import Foundation
import CoreGraphics
import ImageIO
import PicShotCodecCore

/// Installed-app synthetic acceptance through the production signed helper.
/// This never captures the screen, reads a personal image, or uploads evidence.
/// A missing native decoder/helper or an unobserved cancellation is a failure,
/// never a mock, skip, or claimed codec pass.
enum CodecExportResourceFixture {
    static let cyclesPerFormat = 3
    static func verify(evidenceDirectory: URL, service: CodecExportProcessService = .shared,
                       dimension: Int = 768) async throws -> [String: Any] {
        guard evidenceDirectory.isFileURL, (64...1024).contains(dimension) else { throw failure("Invalid fixture configuration") }
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let directory = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-Codec-Fixture-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var mayCleanup = true
        defer { if mayCleanup { try? files.removeItem(at: directory) } }
        let image = try fixture(width: dimension, height: dimension * 3 / 4)
        let snapshot = try ImageExportSnapshot(image: image)
        let baseline = GIFResourceMemoryReading.current()
        var report: [String: Any] = ["status": "running", "cyclesPerFormat": cyclesPerFormat,
            "sourceWidth": image.width, "sourceHeight": image.height,
            "captureStarted": false, "networkAttempted": false, "dependenciesInstalled": false,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "scope": "Signed bundled helper encodes, independently decodes its exact bytes for preview; ImageIO separately decodes every still result and verifies all premultiplied pixels and alpha",
            "memoryScope": "Parent RSS/footprint and child sampled RSS/footprint per cycle; sampled watchdog is not a hard quota, instantaneous peak, leak diagnosis or whole-system measurement",
            "maximumInputPixels": CodecExportLimits.stillPixels, "maximumOutputBytes": CodecExportLimits.stillOutputBytes,
            "wallSeconds": CodecExportLimits.wallSeconds, "childSampledRSSAbortBytes": CodecExportLimits.residentBytes,
            "baseline": try object(baseline), "runs": [[String: Any]](), "temporaryDirectoryRemoved": false]
        let reportURL = evidenceDirectory.appendingPathComponent("codec-export-resource.json")
        do {
            var runs: [[String: Any]] = []
            var qualityChecks: [[String: Any]] = []
            for format in [ImageExportFormat.webp, .avif] {
                for cycle in 1...cyclesPerFormat {
                    let options = ImageExportOptions(format: format, quality: 0.81, lossless: true, preserveAlpha: true)
                    let artifact = try await ImageExportService.encodeBundled(snapshot: snapshot, options: options, service: service)
                    try require(artifact.width == image.width && artifact.height == image.height && artifact.byteCount > 0,
                                "Wrong real encoded dimensions/bytes")
                    try CodecExportProcessService.validateMagic(artifact.data, format: format == .webp ? .webp : .avif)
                    // Independent platform decode. Do not fall back to the source
                    // raster or helper preview when the reader is absent.
                    let decoded = try independentDecode(artifact.data, format: format, width: image.width, height: image.height)
                    try compare(decoded, image, tolerance: 2)
                    try compare(artifact.firstPreview, decoded, tolerance: 2)
                    let output = directory.appendingPathComponent("cycle." + format.filenameExtension)
                    try ImageExportService.publish(artifact, to: output)
                    try require(try Data(contentsOf: output) == artifact.data, "Saved bytes differ from previewed bytes")
                    let beforeCollision = try Data(contentsOf: output)
                    do { try ImageExportService.publish(artifact, to: output); throw failure("Collision replaced an existing result") }
                    catch ImageExportError.destinationExists { }
                    try require(try Data(contentsOf: output) == beforeCollision, "Collision changed existing file")
                    try files.removeItem(at: output)
                    let state = await service.snapshot()
                    let metrics = try finished(state, expectSuccess: true)
                    try require(try files.contentsOfDirectory(atPath: directory.path).isEmpty, "Staging or result remained")
                    runs.append(["format": format.title, "cycle": cycle, "metrics": try object(metrics),
                                 "independentDecode": true, "allPixelsAndAlpha": true, "sameByteSave": true,
                                 "settledParent": try object(GIFResourceMemoryReading.current())])
                    report["runs"] = runs; try write(report, to: reportURL)
                }
                // An explicit alpha-off run verifies the documented white
                // composition rather than merely accepting an opaque header.
                let opaque = try await ImageExportService.encodeBundled(snapshot: snapshot,
                    options: ImageExportOptions(format: format, lossless: true, preserveAlpha: false), service: service)
                let decoded = try independentDecode(opaque.data, format: format, width: image.width, height: image.height)
                let pixels = try raster(decoded)
                let expected = try opaqueReference(image)
                try compare(decoded, expected, tolerance: 2)
                try require(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 }, "Alpha-off output is not fully opaque")
                _ = try finished(await service.snapshot(), expectSuccess: true)
                let low = try await ImageExportService.encodeBundled(snapshot: snapshot,
                    options: ImageExportOptions(format: format, quality: 0.12, alphaQuality: 1), service: service)
                _ = try finished(await service.snapshot(), expectSuccess: true)
                let high = try await ImageExportService.encodeBundled(snapshot: snapshot,
                    options: ImageExportOptions(format: format, quality: 0.94, alphaQuality: 1), service: service)
                _ = try finished(await service.snapshot(), expectSuccess: true)
                let lowPixels = try raster(independentDecode(low.data, format: format, width: image.width, height: image.height))
                let highPixels = try raster(independentDecode(high.data, format: format, width: image.width, height: image.height))
                try require(low.data != high.data && lowPixels != highPixels, "Quality controls did not change real encoded and decoded bytes")
                qualityChecks.append(["format": format.title, "lowBytes": low.byteCount, "highBytes": high.byteCount,
                                      "realBytesChanged": true, "decodedPixelsChanged": true])
            }
            report["qualityChecks"] = qualityChecks
            let input = directory.appendingPathComponent("source.png")
            let png = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions())
            try ImageExportService.publish(png, to: input)
            var cancelled: [[String: Any]] = []
            for format in [CodecExportFormat.webp, .avif] {
                let signal = CodecFixtureCancellation()
                let destination = directory.appendingPathComponent("cancelled." + format.rawValue)
                let task = Task {
                    try await service.export(sourceURL: input, destinationURL: destination,
                        options: CodecExportRequest(format: format, lossless: true)) { value in
                            if value < 1 { signal.request() }
                        }
                }
                signal.install { task.cancel() }
                do { _ = try await task.value; throw failure("Real codec cancellation unexpectedly succeeded") }
                catch is CancellationError { }
                signal.clear()
                try require(signal.wasRequested, "Cancellation did not observe real helper progress")
                let metrics = try finished(await service.snapshot(), expectSuccess: false)
                try require(metrics.outcome == "cancelled" && !files.fileExists(atPath: destination.path), "Cancelled output escaped publication fence")
                cancelled.append(["format": format.rawValue, "metrics": try object(metrics)])
            }
            report["cancellation"] = cancelled
            try files.removeItem(at: input)
            try require(try files.contentsOfDirectory(atPath: directory.path).isEmpty, "Cancellation left staging")
            try files.removeItem(at: directory)
            report["temporaryDirectoryRemoved"] = true; report["status"] = "passed"
            report["finalParent"] = try object(GIFResourceMemoryReading.current())
            try write(report, to: reportURL); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            let state = await service.snapshot(); mayCleanup = !state.active
            report["lastProcess"] = try? object(state)
            try? write(report, to: reportURL); throw error
        }
    }
    static func finished(_ state: CodecExportProcessSnapshot, expectSuccess: Bool) throws -> CodecExportProcessMetrics {
        guard !state.active, let metrics = state.lastJob, metrics.childLaunched, metrics.childExitConfirmed,
              metrics.temporaryDirectoryRemoved, metrics.childResidentSampleCount > 0,
              metrics.parentResidentSampleCount > 0, metrics.parentPhysicalFootprintSampleCount > 0,
              (metrics.childSampledPeakResidentBytes ?? UInt64.max) <= CodecExportLimits.residentBytes else {
            throw failure("Missing child exit/cleanup or real parent/child memory observations")
        }
        if expectSuccess {
            try require(metrics.outcome == "succeeded" && metrics.childReportedResidentSampleCount > 0 &&
                        metrics.childReportedPhysicalFootprintSampleCount > 0 &&
                        (metrics.childReportedPeakResidentBytes ?? UInt64.max) <= CodecExportLimits.residentBytes &&
                        (metrics.childReportedPeakPhysicalFootprintBytes ?? UInt64.max) <= CodecExportLimits.residentBytes,
                        "Successful child omitted or exceeded native memory evidence")
        }
        return metrics
    }
    static func independentDecode(_ data: Data, format: ImageExportFormat, width: Int, height: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let identifier = CGImageSourceGetType(source) as String?, identifier == format.contentType.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height else {
            throw failure("Independent ImageIO \(format.title) reader or real output validation failed")
        }; return image
    }
    static func fixture(width: Int, height: Int) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) where x >= width / 4 {
                let alpha: CGFloat = x < width / 2 ? 0.5 : 1
                context.setFillColor(CGColor(srgbRed: CGFloat((x * 13 + y * 7) % 251) / 250,
                    green: CGFloat((x * 3 + y * 17) % 251) / 250, blue: CGFloat((x * 23 + y * 11) % 251) / 250, alpha: alpha))
                context.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        guard let image = context.makeImage() else { throw failure("Fixture image allocation failed") }; return image
    }
    static func raster(_ image: CGImage) throws -> Data {
        let context = try makeContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data else { throw failure("Pixel read failed") }
        return Data(bytes: bytes, count: image.width * image.height * 4)
    }
    private static func compare(_ actual: CGImage, _ expected: CGImage, tolerance: Int) throws {
        try require(actual.width == expected.width && actual.height == expected.height, "Decoded preview dimensions differ")
        let a = try raster(actual), e = try raster(expected)
        try require(zip(a, e).allSatisfy { pair in abs(Int(pair.0) - Int(pair.1)) <= tolerance }, "Actual decoded pixels/alpha differ from lossless reference")
    }
    private static func opaqueReference(_ image: CGImage) throws -> CGImage {
        let context = try makeContext(width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let image = context.makeImage() else { throw failure("Opaque reference failed") }; return image
    }
    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw failure("Fixture allocation failed") }; return context
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw failure("Evidence encoding failed") }; return object
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Codec acceptance: " + message) }
}

private final class CodecFixtureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var action: (@Sendable () -> Void)?
    func install(_ value: @escaping @Sendable () -> Void) {
        lock.lock(); action = value; let ready = requested; lock.unlock(); if ready { value() }
    }
    func request() { lock.lock(); requested = true; let action = action; lock.unlock(); action?() }
    func clear() { lock.lock(); action = nil; lock.unlock() }
    var wasRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}
