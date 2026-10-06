import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PicShotCodecCore

/// Installed-app-only authored recording fixture. Exercises the real selected
/// trim→signed one-job helper→identity-checked save route. Never captures a
/// screen, microphone, camera, user's media or remote content.
enum RecordingWebPSmokeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        let files = FileManager.default
        try files.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let directory = files.temporaryDirectory.appendingPathComponent("PicShot-Recording-WebP-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Helper inputs are separately copied into owned system-temp jobs;
        // the fixture directory is never a live child's working directory.
        defer { try? files.removeItem(at: directory) }
        var report: [String: Any] = [
            "status": "running", "captureStarted": false, "audioStarted": false, "externalDownloads": false,
            "sourceProvenance": "original deterministic 24-frame H.264 animation authored in this fixture",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "animationValidation": "signed helper independently WebPDemux/WebPAnimDecoder-decodes every frame before result; parent checks full-canvas ANMF rectangles, durations, counts, magic and byte caps",
            "pixelFidelityEvidence": "separate native AnimatedWebPEncoderTests and WebPContainerWriterTests compare every decoded frame against authored input, including odd dimensions and alpha transitions",
            "resourceScope": "sampled parent/child metrics for these short synthetic codec jobs only; optional main-process ImageIO compatibility probing is separate; no zero-leak or instantaneous hard RSS claim",
            "maximumOutputBytes": CodecExportLimits.animationOutputBytes,
            "maximumEncodedFrameBytes": CodecExportLimits.animationFrameBytes,
            "temporaryDirectoryRemoved": false
        ]
        let reportURL = evidenceDirectory.appendingPathComponent("recording-webp.json")
        do {
            let source = directory.appendingPathComponent("original.mp4")
            try await makeMovie(at: source)
            let original = try Data(contentsOf: source)
            try require(original.count < 8 * 1_024 * 1_024, "Synthetic source exceeded its fixture disk cap")
            let range = try VideoTrimRange(start: 0.4, end: 1.6, sourceDuration: 2.4)
            var exports: [[String: Any]] = []
            for lossless in [true, false] {
                let output = directory.appendingPathComponent(lossless ? "selected-lossless.webp" : "selected-lossy.webp")
                let destination = try VideoExportDestination(url: output, preserving: source)
                _ = try await VideoTrimExporter.exportWebP(sourceURL: source, destination: destination, range: range,
                                                           options: options(lossless: lossless))
                let encoded = try Data(contentsOf: output)
                let structure = try inspect(encoded)
                let imageIOProbe = imageIOReadProbe(encoded, expectedFrames: 12, expectedDurationMS: 1_200)
                try require(structure.frames == 12 && structure.durationMS == 1_200, "Selected animation range/timing differs")
                try require(structure.width == 160 && structure.height == 90, "Selected animation dimensions differ")
                let snapshot = await CodecExportProcessService.shared.snapshot()
                guard let job = snapshot.lastJob else { throw failure("Missing real helper process metrics") }
                try require(!snapshot.active && job.childLaunched && job.childExitConfirmed && job.temporaryDirectoryRemoved,
                            "Successful helper did not confirm exit and cleanup")
                try require(job.parentResidentSampleCount > 0 && job.childResidentSampleCount > 0
                    && job.childReportedResidentSampleCount > 0 && job.childReportedPhysicalFootprintSampleCount > 0,
                            "Successful helper omitted bounded parent/child memory observations")
                try require(job.verifiedFrameCount == structure.frames && job.verifiedWidth == structure.width
                    && job.verifiedHeight == structure.height && abs((job.verifiedDuration ?? -1) - 1.2) <= 0.001,
                            "Native independently decoded result differs from the selected container")
                try require(try Data(contentsOf: source) == original, "Original source changed")
                exports.append(["lossless": lossless, "frames": structure.frames, "durationMS": structure.durationMS,
                                "width": structure.width, "height": structure.height, "outputBytes": structure.bytes,
                                "process": try object(job), "imageIOReadProbe": imageIOProbe])
                try files.removeItem(at: output)
                try assertNoStages(directory)
                report["exports"] = exports
                try write(report, to: reportURL)
            }
            report["cancellation"] = try await verifyCancellation(source: source, original: original, directory: directory, range: range)
            // A destination created after panel confirmation must survive even
            // though the completed helper artifact is valid and ready to save.
            let raceURL = directory.appendingPathComponent("concurrent.webp")
            let raceDestination = try VideoExportDestination(url: raceURL, preserving: source)
            let concurrent = Data("another app owns this newly created destination".utf8)
            let racer = WebPFixtureDestinationRace(url: raceURL, data: concurrent)
            do {
                _ = try await VideoTrimExporter.exportWebP(sourceURL: source, destination: raceDestination, range: range,
                    options: options(lossless: true)) { value in
                    if value >= 0.99 { racer.writeOnce() }
                }
                throw failure("Concurrent destination was overwritten")
            } catch VideoTrimError.destinationExists { }
            catch { throw racer.failure ?? error }
            if let failure = racer.failure { throw failure }
            try require(try Data(contentsOf: raceURL) == concurrent, "Concurrent file was not preserved")
            try require(try Data(contentsOf: source) == original, "Original source changed after cancelled/racing jobs")
            report["destinationRacePreserved"] = true
            report["originalPreserved"] = true
            try assertNoStages(directory)
            try files.removeItem(at: directory)
            report["temporaryDirectoryRemoved"] = true
            report["status"] = "passed"
            try write(report, to: reportURL)
            return report
        } catch {
            let snapshot = await CodecExportProcessService.shared.snapshot()
            report["status"] = "failed"
            report["error"] = error.localizedDescription
            if let metrics = snapshot.lastJob { report["lastProcess"] = try? object(metrics) }
            report["independentHelperJobStillTracked"] = snapshot.active
            try? write(report, to: reportURL)
            throw error
        }
    }

    /// Informational reader compatibility only. Mandatory animation integrity
    /// remains the helper's independent all-frame libwebp decode. ImageIO may
    /// expose just the first frame or omit timing on an otherwise valid WebP.
    static func imageIOReadProbe(_ encoded: Data, expectedFrames: Int, expectedDurationMS: Int) -> [String: Any] {
        var report: [String: Any] = [
            "scope": "optional native ImageIO animation-reader compatibility for existing animated pins",
            "requiredForExportSuccess": false, "expectedFrames": expectedFrames,
            "expectedDurationMS": expectedDurationMS, "readerType": "unavailable",
            "reportedFrameCount": 0, "everyExposedFrameDecoded": false,
            "allExpectedFramesDecoded": false, "allFrameDelaysAvailable": false,
            "timingMatchesExpected": false, "animationReadableWithTiming": false
        ]
        guard encoded.count <= CodecExportLimits.animationOutputBytes else {
            report["status"] = "input-exceeds-probe-cap"; return report
        }
        guard let source = CGImageSourceCreateWithData(encoded as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else {
            report["status"] = "reader-unavailable"; return report
        }
        report["readerType"] = CGImageSourceGetType(source) as String? ?? "unknown"
        let count = CGImageSourceGetCount(source)
        report["reportedFrameCount"] = count
        guard count > 0, count <= CodecExportLimits.animationFrames else {
            report["status"] = count == 0 ? "no-readable-frames" : "reader-frame-count-exceeds-probe-cap"
            return report
        }
        var frames: [[String: Any]] = [], decodedCount = 0, delays: [Double] = []
        for index in 0..<count {
            // Release each CGImage before probing the next. No decoded-frame
            // collection or unbounded metadata is retained by this probe.
            autoreleasepool {
                var frame: [String: Any] = ["index": index, "decoded": false]
                if let image = CGImageSourceCreateImageAtIndex(source, index,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                    frame["decoded"] = true; frame["width"] = image.width; frame["height"] = image.height
                    decodedCount += 1
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
                let metadata = frameDelayMetadata(properties)
                frame["availableDelayMetadata"] = metadata
                // These ImageIO property names represent seconds. Unknown
                // delay-like metadata remains raw evidence, never guessed.
                let unclamped = metadata.keys.sorted().first { $0 == "UnclampedDelayTime" || $0.hasSuffix(".UnclampedDelayTime") }
                let clamped = metadata.keys.sorted().first { $0 == "DelayTime" || $0.hasSuffix(".DelayTime") }
                if let key = unclamped ?? clamped, let seconds = metadata[key], seconds >= 0 {
                    frame["selectedDelayProperty"] = key; frame["delaySeconds"] = seconds
                    delays.append(seconds)
                }
                frames.append(frame)
            }
        }
        let allFrames = count == expectedFrames && decodedCount == count
        let milliseconds = delays.reduce(0, +) * 1_000
        let allTiming = delays.count == count && milliseconds.isFinite
        let timingMatches = allFrames && allTiming && abs(milliseconds - Double(expectedDurationMS)) <= 1
        report["frames"] = frames
        report["everyExposedFrameDecoded"] = decodedCount == count
        report["allExpectedFramesDecoded"] = allFrames
        report["allFrameDelaysAvailable"] = allTiming
        report["timingMatchesExpected"] = timingMatches
        report["animationReadableWithTiming"] = timingMatches
        if allTiming { report["decodedDurationMS"] = milliseconds }
        if timingMatches { report["status"] = "full-animation-readable" }
        else if count == 1 && expectedFrames > 1 { report["status"] = "first-frame-only" }
        else if !allFrames { report["status"] = "incomplete-frame-decoding" }
        else if !allTiming { report["status"] = "frames-readable-timing-unavailable" }
        else { report["status"] = "frame-timing-differs" }
        return report
    }

    private static func frameDelayMetadata(_ properties: [String: Any]) -> [String: Double] {
        var result: [String: Double] = [:], remaining = 128
        func visit(_ dictionary: [String: Any], prefix: String, depth: Int) {
            guard depth <= 3, remaining > 0 else { return }
            for key in dictionary.keys.sorted().prefix(64) {
                guard remaining > 0 else { return }; remaining -= 1
                guard key.utf8.count <= 256 else { continue }
                let path = prefix.isEmpty ? key : prefix + "." + key
                if key.lowercased().contains("delay"), let number = dictionary[key] as? NSNumber, number.doubleValue.isFinite {
                    result[path] = number.doubleValue
                } else if let child = dictionary[key] as? [String: Any] {
                    visit(child, prefix: path, depth: depth + 1)
                }
            }
        }
        visit(properties, prefix: "", depth: 0)
        return result
    }

    private static func verifyCancellation(source: URL, original: Data, directory: URL,
                                           range: VideoTrimRange) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        for late in [false, true] {
            let output = directory.appendingPathComponent(late ? "cancel-publication.webp" : "cancel-frame.webp")
            let destination = try VideoExportDestination(url: output, preserving: source)
            let cancellation = WebPFixtureCancellation()
            let task = Task {
                try await VideoTrimExporter.exportWebP(sourceURL: source, destination: destination, range: range,
                    options: options(lossless: true)) { value in
                    if late ? value >= 0.99 : value > 0.30 { cancellation.request() }
                }
            }
            cancellation.install { task.cancel() }
            defer { cancellation.clear(); task.cancel() }
            do { _ = try await task.value; throw failure("Cancelled WebP export succeeded") }
            catch is CancellationError { }
            let snapshot = await CodecExportProcessService.shared.snapshot()
            guard let job = snapshot.lastJob else { throw failure("Missing cancellation metrics") }
            try require(cancellation.requested && !snapshot.active && job.childExitConfirmed && job.temporaryDirectoryRemoved,
                        "Cancelled child exit/cleanup is unconfirmed")
            try require(!FileManager.default.fileExists(atPath: output.path), "Cancelled destination was published")
            try require(try Data(contentsOf: source) == original, "Cancellation changed original")
            try assertNoStages(directory)
            results.append(["point": late ? "after-helper-publication" : "first-observed-encoded-frame-progress", "process": try object(job)])
        }
        return results
    }

    private static func options(lossless: Bool) -> CodecExportRequest {
        CodecExportRequest(kind: .animation, format: .webp, quality: 80, lossless: lossless,
                           animation: .init(frameRate: 10, maximumDimension: 160))
    }
    private struct Structure { let width: Int, height: Int, frames: Int, durationMS: Int, bytes: Int }
    private static func inspect(_ data: Data) throws -> Structure {
        func number(_ at: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(data[at + $1]) << (8 * $1) } }
        func name(_ at: Int) -> String { String(decoding: data[at..<(at + 4)], as: UTF8.self) }
        try require(data.count >= 44 && data.count <= CodecExportLimits.animationOutputBytes, "Invalid WebP size")
        try require(name(0) == "RIFF" && name(8) == "WEBP" && number(4, 4) == data.count - 8, "Incorrect WebP magic/RIFF size")
        try require(name(12) == "VP8X" && number(16, 4) == 10 && data[20] == 0x02, "Recording WebP must have opaque animation flags")
        let width = number(24, 3) + 1, height = number(27, 3) + 1
        try require(name(30) == "ANIM" && number(34, 4) == 6 && number(42, 2) == 0, "Invalid animation header")
        var offset = 44, frames = 0, duration = 0
        while offset < data.count {
            try require(data.count - offset >= 24 && name(offset) == "ANMF", "Missing animation frame")
            let size = number(offset + 4, 4)
            try require(size >= 16 && size <= data.count - offset - 8, "Truncated animation frame")
            try require(number(offset + 8, 3) == 0 && number(offset + 11, 3) == 0
                && number(offset + 14, 3) + 1 == width && number(offset + 17, 3) + 1 == height
                && data[offset + 23] == 0x02, "Frame rectangle/blending differs")
            let delay = number(offset + 20, 3)
            try require(delay > 0, "Zero animation frame duration")
            frames += 1; duration += delay; offset += 8 + size + (size & 1)
            try require(frames <= 600 && duration <= 60_000 && offset <= data.count, "Animation budget exceeded")
        }
        try require(offset == data.count && frames > 1, "Animation proof requires all frames")
        return Structure(width: width, height: height, frames: frames, durationMS: duration, bytes: data.count)
    }
    private static func assertNoStages(_ directory: URL) throws {
        try require(!FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".picshot-") },
                    "Owned trim staging remains after confirmed helper exit")
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PicShot.RecordingWebPFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1]])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? failure("Synthetic video writer failed") }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(30)
        for index in 0..<24 {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw failure("Synthetic writer exceeded its deadline") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try autoreleasepool {
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
                      let pixel = buffer else { throw failure("Synthetic pixel allocation failed") }
                CVPixelBufferLockBaseAddress(pixel, [])
                defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 320, height: 180,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { throw failure("Synthetic pixel context failed") }
                context.setFillColor(CGColor(red: CGFloat(index) / 24, green: 0.25, blue: 1 - CGFloat(index) / 24, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                context.setFillColor(CGColor(red: 0.8, green: CGFloat(index % 6) / 6, blue: 0.2, alpha: 1))
                context.fill(CGRect(x: CGFloat(index * 10), y: 40, width: 60, height: 80))
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
                    throw writer.error ?? failure("Synthetic frame append failed")
                }
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 24, timescale: 10))
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? failure("Synthetic video did not finalize") }
    }
}

private final class WebPFixtureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var pending = false
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return pending }
    func install(_ action: @escaping () -> Void) {
        lock.lock(); self.action = action; let invoke = pending; lock.unlock()
        if invoke { action() }
    }
    func request() {
        lock.lock(); pending = true; let action = self.action; lock.unlock()
        action?()
    }
    func clear() { lock.lock(); action = nil; lock.unlock() }
}

private final class WebPFixtureDestinationRace: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL, data: Data
    private var written = false
    private var error: Error?
    init(url: URL, data: Data) { self.url = url; self.data = data }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return error }
    func writeOnce() {
        lock.lock(); defer { lock.unlock() }
        guard !written else { return }; written = true
        do { try data.write(to: url, options: .withoutOverwriting) }
        catch { self.error = error }
    }
}
