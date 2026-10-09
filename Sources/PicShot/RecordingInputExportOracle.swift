import AVFoundation
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

/// Shared only by explicit synthetic acceptance and its separate native reader.
/// Keeps scalar observations, never an array of decoded frames. Coordinates in
/// observations are lower-left canvas coordinates, matching the input witness.
enum RecordingInputExportOracle {
    static let width = 320, height = 180, sourceFrames = 22, selectedFrames = 21
    static let start = 0.1, end = 2.15, duration = 2.05
    static let animationFrames = 41, animationFPS = 20
    static let maximumFileBytes = 4 * 1_024 * 1_024
    static let maximumReportBytes = 128 * 1_024
    static let reportName = "recording-input-export.json"
    static let independentReportName = "recording-input-export-independent.json"
    static let mediaNames = ["recording-input-selected.mp4", "recording-input-selected.gif",
                             "recording-input-lossless.webp", "recording-input-lossy.webp"]

    struct Region: Sendable {
        let name: String, x: Int, y: Int, width: Int, height: Int
    }
    static let regions: [Region] = [
        .init(name: "click", x: 54, y: 80, width: 52, height: 54),
        .init(name: "scroll", x: 194, y: 100, width: 44, height: 42),
        .init(name: "shortcut", x: 118, y: 12, width: 84, height: 32),
        .init(name: "camera", x: 30, y: 151, width: 10, height: 10),
        .init(name: "annotation", x: 273, y: 153, width: 10, height: 10),
        .init(name: "clear", x: 153, y: 158, width: 14, height: 14),
        .init(name: "horizontalScroll", x: 219, y: 107, width: 1, height: 1),
        .init(name: "verticalScroll", x: 229, y: 119, width: 1, height: 1),
        .init(name: "oppositeScroll", x: 240, y: 107, width: 1, height: 1),
        .init(name: "postStop", x: 157, y: 132, width: 6, height: 6)
    ]
    struct Feature: Codable {
        let count: Int
        let x: Double, y: Double
    }
    struct RegionObservation: Codable {
        let rgb: [Double]
        let yellow: Feature, pink: Feature, mint: Feature, white: Feature
    }
    struct Observation: Codable {
        let index: Int, pts: Double
        let regions: [String: RegionObservation]
    }
    struct Movie: Codable {
        let url: URL
        let frameCount: Int, duration: Double, packetEnd: Double
        let observations: [Observation]
    }
    struct Comparison: Codable {
        let index: Int, requestedSeconds: Double, actualSeconds: Double
        let sourceIndex: Int, delayMS: Int
        let regionMeanAbsoluteError: [String: Double]
    }
    enum Format: String { case gif, webpLossless, webpLossy }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "PicShot.RecordingInputExport", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    /// CoreMedia may deliver a zero-sample control marker in addition to media
    /// samples. Never turn it into a frame or infer/fix a media sample duration.
    /// A real empty playback interval, payload, or unrecognized empty buffer is
    /// not a harmless marker. Callers separately cap all returned buffers.
    static func isControlMarker(_ sample: CMSampleBuffer, context: String) throws -> Bool {
        guard CMSampleBufferGetNumSamples(sample) == 0 else { return false }
        var known = false
        for key in [kCMSampleBufferAttachmentKey_EmptyMedia,
                    kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
                    kCMSampleBufferAttachmentKey_PermanentEmptyMedia] {
            guard let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil) else { continue }
            try require(CFGetTypeID(value) == CFBooleanGetTypeID(), "Malformed control-marker flag: \(context)")
            known = known || (value as? NSNumber)?.boolValue == true
        }
        let dataBytes = CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) } ?? 0
        let entry = sampleTimingEntry(sample)
        let boundedTiming = (entry.status == noErr && (0...1).contains(entry.count))
            || (entry.status == kCMSampleBufferError_BufferHasNoSampleTimingInfo && entry.count == 0)
        let durations = [CMSampleBufferGetDuration(sample), CMSampleBufferGetOutputDuration(sample), entry.timing.duration]
        try require(CMSampleBufferIsValid(sample) && CMSampleBufferDataIsReady(sample) && known
            && CMSampleBufferGetTotalSampleSize(sample) == 0 && dataBytes == 0
            && CMSampleBufferGetImageBuffer(sample) == nil
            && boundedTiming
            && durations.allSatisfy { !$0.isValid || ($0.isNumeric && $0.seconds == 0) },
                    "Malformed/nonempty control marker: \(context)")
        return true
    }

    /// A marker's timing entry can describe an empty interval even when the
    /// aggregate duration sums zero media samples. Read at most one raw entry.
    private static func sampleTimingEntry(_ sample: CMSampleBuffer) -> (status: OSStatus, count: CMItemCount, timing: CMSampleTimingInfo) {
        var count: CMItemCount = 0
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        let status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 1,
            arrayToFill: &timing, entriesNeededOut: &count)
        return (status, count, timing)
    }

    /// Fixed-size scalar diagnostics only: no payloads, images, URLs, or arbitrary
    /// attachment descriptions. Invalid CMTime flags remain visible as-is.
    static func sampleTimingDescription(_ sample: CMSampleBuffer, route: String, phase: String,
                                        buffer: Int, media: Int, expected: Int) -> String {
        func time(_ value: CMTime) -> String {
            "\(value.value)/\(value.timescale):flags=\(value.flags.rawValue):epoch=\(value.epoch):seconds=\(value.seconds)"
        }
        func flag(_ key: CFString) -> String {
            guard let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil) else { return "absent" }
            guard CFGetTypeID(value) == CFBooleanGetTypeID(), let number = value as? NSNumber else { return "invalid-type" }
            return number.boolValue ? "true" : "false"
        }
        func trim(_ key: CFString) -> String {
            guard let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil) else { return "absent" }
            guard let dictionary = value as? NSDictionary else { return "invalid-type" }
            return [kCMTimeValueKey, kCMTimeScaleKey, kCMTimeFlagsKey, kCMTimeEpochKey].map {
                (dictionary[$0] as? NSNumber)?.stringValue ?? "missing"
            }.joined(separator: "/")
        }
        let bytes = CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) } ?? 0
        let entry = sampleTimingEntry(sample)
        return "route=\(route) phase=\(phase) buffer=\(buffer) media=\(media)/\(expected)"
            + " valid=\(CMSampleBufferIsValid(sample)) ready=\(CMSampleBufferDataIsReady(sample))"
            + " samples=\(CMSampleBufferGetNumSamples(sample)) sampleBytes=\(CMSampleBufferGetTotalSampleSize(sample)) dataBytes=\(bytes)"
            + " pts=\(time(CMSampleBufferGetPresentationTimeStamp(sample)))"
            + " dts=\(time(CMSampleBufferGetDecodeTimeStamp(sample))) duration=\(time(CMSampleBufferGetDuration(sample)))"
            + " outputPTS=\(time(CMSampleBufferGetOutputPresentationTimeStamp(sample)))"
            + " outputDuration=\(time(CMSampleBufferGetOutputDuration(sample)))"
            + " timingEntries=\(entry.count) timingStatus=\(entry.status) sampleDuration=\(time(entry.timing.duration))"
            + " samplePTS=\(time(entry.timing.presentationTimeStamp)) sampleDTS=\(time(entry.timing.decodeTimeStamp))"
            + " empty=\(flag(kCMSampleBufferAttachmentKey_EmptyMedia))"
            + " endsPrevious=\(flag(kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration))"
            + " permanentEmpty=\(flag(kCMSampleBufferAttachmentKey_PermanentEmptyMedia))"
            + " trimStart=\(trim(kCMSampleBufferAttachmentKey_TrimDurationAtStart))"
            + " trimEnd=\(trim(kCMSampleBufferAttachmentKey_TrimDurationAtEnd))"
    }
    static func check(_ deadline: Double) throws {
        try Task.checkCancellation()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Derived input verification deadline exceeded")
    }
    static func boundedData(_ url: URL, maximum: Int = maximumFileBytes) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(url.isFileURL && values.isRegularFile == true && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0 && (values.fileSize ?? Int.max) <= maximum,
                    "Not a bounded regular evidence file: \(url.lastPathComponent)")
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var data = Data()
        while true {
            let chunk = try input.read(upToCount: min(65_536, maximum + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            try require(data.count <= maximum, "Evidence grew beyond its byte cap")
        }
        try require(data.count > 0 && data.count <= maximum, "Evidence changed beyond its byte cap")
        return data
    }
    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try boundedData(url)).map { String(format: "%02x", $0) }.joined()
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func write(_ report: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try require(data.count <= maximumReportBytes, "Derived evidence JSON exceeded its cap")
        try data.write(to: url, options: [.atomic])
    }

    /// No color truth is taken from pristine authoring RGB for codec comparison.
    /// This is the helper's opaque sRGB raster convention. C animation output is
    /// already top-to-bottom straight RGBA8, so it needs no ImageIO conversion.
    static func raster(_ image: CGImage) throws -> [UInt8] {
        try require(image.width == width && image.height == height, "Derived canvas dimensions differ")
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try require(rendered, "Derived raster allocation failed")
        try require(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 },
                    "Authored opaque recording acquired transparency")
        return bytes
    }
    static func observation(_ pixels: UnsafeBufferPointer<UInt8>, index: Int, pts: Double) throws -> Observation {
        try require(pixels.count == width * height * 4, "Incorrect RGBA byte count")
        var result: [String: RegionObservation] = [:]
        for region in regions {
            var sum = [Double](repeating: 0, count: 3)
            var counts = [Int](repeating: 0, count: 4), xs = [Double](repeating: 0, count: 4), ys = xs
            for y in region.y..<(region.y + region.height) {
                for x in region.x..<(region.x + region.width) {
                    let offset = ((height - 1 - y) * width + x) * 4
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    for channel in 0..<3 { sum[channel] += Double(pixels[offset + channel]) }
                    let masks = [r > 120 && g > 90 && r > g + 15 && b < g - 30,
                                 r > 140 && b > 90 && r > g + 40,
                                 g > 120 && g > r + 30 && b > r + 20, min(r, g, b) > 140]
                    for feature in 0..<4 where masks[feature] {
                        counts[feature] += 1; xs[feature] += Double(x); ys[feature] += Double(y)
                    }
                }
            }
            func feature(_ index: Int) -> Feature {
                .init(count: counts[index], x: counts[index] == 0 ? 0 : xs[index] / Double(counts[index]),
                      y: counts[index] == 0 ? 0 : ys[index] / Double(counts[index]))
            }
            result[region.name] = .init(rgb: sum.map { $0 / Double(region.width * region.height) },
                yellow: feature(0), pink: feature(1), mint: feature(2), white: feature(3))
        }
        return Observation(index: index, pts: pts, regions: result)
    }
    static func semantics(_ frame: Observation) throws {
        guard let camera = frame.regions["camera"], let annotation = frame.regions["annotation"],
              let clear = frame.regions["clear"], let click = frame.regions["click"],
              let scroll = frame.regions["scroll"], let shortcut = frame.regions["shortcut"]
        else { throw NSError(domain: "PicShot.RecordingInputExport", code: 2) }
        func color(_ actual: [Double], _ expected: [Double], tolerance: Double) throws {
            try require(zip(actual, expected).allSatisfy { abs($0.0 - $0.1) <= tolerance },
                        "Source orientation/anchor differs at frame \(frame.index): \(actual)")
        }
        try color(camera.rgb, [0, 255, 255], tolerance: 45)
        try color(annotation.rgb, [255, 0, 255], tolerance: 45)
        try color(clear.rgb, [40, 40, 40], tolerance: 18)
        if frame.index == 2 { try require(click.yellow.count > 70, "Source click witness absent") }
        if frame.index == 4 {
            try require(scroll.mint.count > 50, "Source scroll witness absent")
            for name in ["horizontalScroll", "verticalScroll"] {
                guard let direction = frame.regions[name] else { throw NSError(domain: "Missing scroll direction", code: 1) }
                try color(direction.rgb, [77, 245, 189], tolerance: 65)
            }
            if let opposite = frame.regions["oppositeScroll"] { try color(opposite.rgb, [40, 40, 40], tolerance: 25) }
        }
        if frame.index == 6 { try require(shortcut.white.count > 140, "Source shortcut witness absent") }
        if frame.index == 9 { try require(click.yellow.count == 0, "Source click did not expire") }
        if frame.index == 13 { try require(scroll.mint.count == 0, "Source scroll did not expire") }
        if [0, 1, 18, 20].contains(frame.index) {
            for region in [click, scroll, shortcut] {
                try color(region.rgb, clear.rgb, tolerance: 4)
                try require(region.yellow.count + region.pink.count + region.mint.count + region.white.count == 0,
                            "Source initial/expired/resumed frame contains stale input")
            }
        }
        if frame.index == 21 {
            try require(click.pink.count > 45 && scroll.mint.count > 35 && shortcut.white.count > 100,
                        "Source Stop-frozen input witness absent")
        }
    }
    static func compare(_ actual: Observation, to expected: Observation) throws {
        for region in regions {
            guard let a = actual.regions[region.name], let e = expected.regions[region.name] else {
                throw NSError(domain: "PicShot.RecordingInputExport", code: 3)
            }
            let tolerance = region.width == 1 ? 65.0 : ["camera", "annotation"].contains(region.name) ? 25.0 : 12.0
            try require(zip(a.rgb, e.rgb).allSatisfy { abs($0.0 - $0.1) <= tolerance },
                        "Decoded \(region.name) color/location differs at source frame \(expected.index)")
            for (observed, reference) in zip([a.yellow, a.pink, a.mint, a.white], [e.yellow, e.pink, e.mint, e.white]) {
                try require(abs(observed.count - reference.count) <= max(20, Int(Double(reference.count) * 0.55)),
                            "Decoded \(region.name) feature presence/expiry differs at source frame \(expected.index)")
                if reference.count >= 30 {
                    try require(observed.count >= max(10, reference.count / 3)
                        && abs(observed.x - reference.x) <= 4 && abs(observed.y - reference.y) <= 4,
                                "Decoded \(region.name) feature moved at source frame \(expected.index)")
                }
            }
        }
    }

    static func movie(_ url: URL, selected: Bool, source: Movie? = nil, deadline: Double) async throws -> Movie {
        let route = selected ? "selected" : "source"
        _ = try boundedData(url)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(tracks.count == 1 && audio.isEmpty, "Unexpected derived media tracks")
        let transform = try await tracks[0].load(.preferredTransform)
        try require(transform == .identity, "Authored movie orientation changed")
        let formats = try await tracks[0].load(.formatDescriptions)
        try require(!formats.isEmpty && formats.allSatisfy {
            let dimensions = CMVideoFormatDescriptionGetDimensions($0)
            return CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
                && dimensions.width == width && dimensions.height == height
        }, "Derived movie is not bounded 320x180 H.264")
        let measuredDuration = try await asset.load(.duration).seconds
        let count = selected ? selectedFrames : sourceFrames, expectedDuration = selected ? duration : 2.2
        try require(abs(measuredDuration - expectedDuration) <= 1.0 / 600,
                    "Selected interval duration differs: route=\(route) actual=\(measuredDuration) expected=\(expectedDuration)")
        let packetEnd = try packets(asset, track: tracks[0], route: route, count: count, duration: expectedDuration, deadline: deadline)
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        try require(reader.canAdd(output), "Derived movie reader unavailable")
        reader.add(output); try require(reader.startReading(), "Derived movie decoder did not start")
        let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
        let sourceGenerator = selected ? source.map { generator($0.url) } : nil
        defer { sourceGenerator?.cancelAllCGImageGeneration() }
        var frames: [Observation] = []
        var buffers = 0
        while let sample = output.copyNextSampleBuffer() {
            try check(deadline)
            let detail = sampleTimingDescription(sample, route: route, phase: "decoded", buffer: buffers, media: frames.count, expected: count)
            try require(buffers < count * 2, "Decoded buffer cap exceeded: \(detail)")
            buffers += 1
            if try isControlMarker(sample, context: detail) {
                print("[recording-input-timing] control-marker \(detail)")
                continue
            }
            try autoreleasepool {
                try require(frames.count < count, "Derived decoder exceeded frame cap: \(detail)")
                try require(CMSampleBufferIsValid(sample) && CMSampleBufferDataIsReady(sample)
                    && CMSampleBufferGetNumSamples(sample) == 1, "Invalid decoded MP4 sample: \(detail)")
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                try require(pts.isFinite && abs(pts - Double(frames.count) / 10) <= 1.0 / 600,
                            "Decoded MP4 PTS/start selection differs: \(detail)")
                guard let pixels = CMSampleBufferGetImageBuffer(sample),
                      let image = context.createCGImage(CIImage(cvPixelBuffer: pixels), from: CGRect(x: 0, y: 0, width: width, height: height))
                else { throw NSError(domain: "PicShot.RecordingInputExport", code: 4,
                                     userInfo: [NSLocalizedDescriptionKey: "Decoded MP4 has no raster: \(detail)"]) }
                try require(CVPixelBufferGetWidth(pixels) == width && CVPixelBufferGetHeight(pixels) == height,
                            "Decoded MP4 canvas differs")
                let rgba = try raster(image)
                let frame = try rgba.withUnsafeBufferPointer { try observation($0, index: frames.count + (selected ? 1 : 0), pts: pts) }
                if selected {
                    guard let source, source.observations.count == sourceFrames else {
                        throw NSError(domain: "PicShot.RecordingInputExport", code: 5)
                    }
                    try compare(frame, to: source.observations[frame.index])
                    guard let sourceGenerator else { throw NSError(domain: "Missing source pixel reference", code: 1) }
                    var sourceActualTime = CMTime.invalid
                    let referenceImage = try sourceGenerator.copyCGImage(
                        at: CMTime(value: Int64(frame.index), timescale: 10), actualTime: &sourceActualTime)
                    try require(sourceActualTime.isNumeric && abs(sourceActualTime.seconds - Double(frame.index) / 10) <= 1.0 / 600,
                                "Selected MP4 did not map to the intended decoded source frame")
                    let referencePixels = try raster(referenceImage)
                    _ = try rgba.withUnsafeBufferPointer { try pixelErrors($0, reference: referencePixels, limit: 9, canvasLimit: 3) }
                } else { try semantics(frame) }
                frames.append(frame)
            }
        }
        try require(reader.status == .completed && frames.count == count,
                    "Derived movie decode did not finish: route=\(route) status=\(reader.status.rawValue) buffers=\(buffers) media=\(frames.count)/\(count)")
        print("[recording-input-timing] route=\(route) phase=decoded buffers=\(buffers) media=\(frames.count) duration=\(measuredDuration) packetEnd=\(packetEnd)")
        return Movie(url: url, frameCount: count, duration: measuredDuration, packetEnd: packetEnd, observations: frames)
    }
    private static func packets(_ asset: AVAsset, track: AVAssetTrack, route: String, count: Int, duration: Double, deadline: Double) throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        try require(reader.canAdd(output), "Derived packet reader unavailable")
        reader.add(output); try require(reader.startReading(), "Derived packet reader did not start")
        // Compressed packets may arrive in decode order after HighestQuality
        // reencoding. Retain only <=22 scalar intervals, then check PTS order.
        var intervals: [(Double, Double)] = []
        var buffers = 0
        while let sample = output.copyNextSampleBuffer() {
            try check(deadline)
            let detail = sampleTimingDescription(sample, route: route, phase: "compressed", buffer: buffers, media: intervals.count, expected: count)
            // Extra control markers are bounded in total by the media count.
            // The <=22/21 stored and decoded media-frame caps remain unchanged.
            try require(buffers < count * 2, "Compressed buffer cap exceeded: \(detail)")
            buffers += 1
            if try isControlMarker(sample, context: detail) {
                print("[recording-input-timing] control-marker \(detail)")
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let length = CMSampleBufferGetDuration(sample).seconds
            try require(intervals.count < count && CMSampleBufferGetNumSamples(sample) == 1
                && CMSampleBufferIsValid(sample) && CMSampleBufferDataIsReady(sample)
                && pts.isFinite && length.isFinite && length > 0, "Invalid/beyond-cap stored MP4 packets: \(detail)")
            intervals.append((pts, length))
        }
        intervals.sort { $0.0 < $1.0 }
        var end = 0.0
        for (index, interval) in intervals.enumerated() {
            try require(abs(interval.0 - Double(index) / 10) <= 1.0 / 600 && abs(interval.0 - end) <= 1.0 / 600,
                        "Stored MP4 packets are not adjacent in presentation order: route=\(route) index=\(index) pts=\(interval.0) duration=\(interval.1) previousEnd=\(end)")
            end = interval.0 + interval.1
        }
        // A track edit may clip playback halfway through its last nominal
        // packet. Check playback duration separately, and allow only that last
        // packet's bounded tail; no extra presented frame may start after end.
        try require(reader.status == .completed && intervals.count == count
            && end >= duration - 1.0 / 600 && end <= duration + 0.1 + 1.0 / 600
            && (intervals.last?.0 ?? duration) < duration,
                    "Stored MP4 endpoint exceeds its final presented packet: route=\(route) status=\(reader.status.rawValue) buffers=\(buffers) media=\(intervals.count)/\(count) packetEnd=\(end) playbackEnd=\(duration) lastPTS=\(intervals.last?.0 ?? .nan)")
        print("[recording-input-timing] route=\(route) phase=compressed buffers=\(buffers) media=\(intervals.count) playbackEnd=\(duration) intervals=\(intervals)")
        return end
    }

    static func sampleTime(_ index: Int) -> CMTime {
        // Both current encoders use nearest 600-Hz request ticks. Frame count
        // is 41 here, not the 21 MP4 frames; no index-to-index claim is made.
        CMTime(value: Int64((Double(index) * duration * 600 / Double(animationFrames)).rounded()), timescale: 600)
    }
    static func delayMS(_ index: Int, format: Format) -> Int {
        if format == .gif { return ((index + 1) * 205 / animationFrames - index * 205 / animationFrames) * 10 }
        return ((index + 1) * 2_050 + animationFrames / 2) / animationFrames
            - (index * 2_050 + animationFrames / 2) / animationFrames
    }
    static func generator(_ selected: URL) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: selected, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return generator
    }
    static func compareAnimation(_ pixels: UnsafeBufferPointer<UInt8>, index: Int, actualDelayMS: Int,
                                 format: Format, generator: AVAssetImageGenerator, selected: Movie,
                                 deadline: Double) throws -> Comparison {
        try check(deadline)
        try require((0..<animationFrames).contains(index) && actualDelayMS == delayMS(index, format: format)
            && actualDelayMS > 0, "Animation delay/sample count differs")
        var actualTime = CMTime.invalid
        let requested = sampleTime(index)
        let image = try generator.copyCGImage(at: requested, actualTime: &actualTime)
        let reference = try raster(image)
        try require(actualTime.isNumeric && actualTime.seconds >= 0 && actualTime.seconds < duration,
                    "Animation reference returned an out-of-selection frame")
        try require(actualTime.seconds <= requested.seconds + 1.0 / 600
            && requested.seconds < actualTime.seconds + 0.1 + 1.0 / 600,
                    "Animation actual source frame does not contain its requested time")
        // Resolve to an actually decoded selected MP4 PTS; never infer source
        // index from the animation index or silently tolerate boundary shifts.
        guard let sourceFrame = selected.observations.first(where: { abs($0.pts - actualTime.seconds) <= 1.0 / 600 }) else {
            throw NSError(domain: "PicShot.RecordingInputExport", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Animation actual time is not a decoded selected frame"])
        }
        let observed = try observation(pixels, index: sourceFrame.index, pts: actualTime.seconds)
        try compare(observed, to: sourceFrame)
        let referenceObservation = try reference.withUnsafeBufferPointer { try observation($0, index: sourceFrame.index, pts: actualTime.seconds) }
        try compare(referenceObservation, to: sourceFrame)
        let errors = try pixelErrors(pixels, reference: reference,
                                     limit: format == .webpLossless ? 9 : 18,
                                     canvasLimit: format == .webpLossless ? 3 : 6)
        return Comparison(index: index, requestedSeconds: requested.seconds, actualSeconds: actualTime.seconds,
                          sourceIndex: sourceFrame.index, delayMS: actualDelayMS, regionMeanAbsoluteError: errors)
    }
    static func pixelErrors(_ pixels: UnsafeBufferPointer<UInt8>, reference: [UInt8],
                            limit: Double, canvasLimit: Double) throws -> [String: Double] {
        try require(pixels.count == width * height * 4 && reference.count == pixels.count, "Pixel comparison byte cap differs")
        var errors: [String: Double] = [:]
        for region in regions {
            var error = 0.0
            for y in region.y..<(region.y + region.height) {
                for x in region.x..<(region.x + region.width) {
                    let offset = ((height - 1 - y) * width + x) * 4
                    for c in 0..<3 { error += Double(abs(Int(pixels[offset + c]) - Int(reference[offset + c]))) }
                }
            }
            let mean = error / Double(region.width * region.height * 3)
            // Repeated selected-clip H.264 preparation, native color conversion,
            // GIF palettes and lossy chroma are measured against decoded MP4.
            // Lossless WebP is not asserted lossless against desktop RGB.
            // Single anti-aliased direction-shaft pixels keep the accepted
            // source fixture's 65-level color allowance. Whole scroll masks,
            // centroids and the surrounding ROI still use the tighter gate.
            let regionLimit = region.width == 1 ? 65.0 : limit
            try require(mean <= regionLimit, "\(region.name) pixel error \(mean) exceeds \(regionLimit)")
            errors[region.name] = mean
        }
        var canvasError = 0.0
        for offset in stride(from: 0, to: reference.count, by: 4) {
            for channel in 0..<3 { canvasError += Double(abs(Int(pixels[offset + channel]) - Int(reference[offset + channel]))) }
        }
        let canvasMean = canvasError / Double(width * height * 3)
        try require(canvasMean <= canvasLimit, "Unexpected pixels outside effect/anchor regions")
        errors["wholeCanvas"] = canvasMean
        return errors
    }
    static func verifyTimeline(_ frames: [Comparison]) throws {
        try require(frames.count == animationFrames && frames.reduce(0) { $0 + $1.delayMS } == 2_050,
                    "Animation frame count/total duration differs")
        try require(zip(frames, frames.dropFirst()).allSatisfy { $0.0.actualSeconds <= $0.1.actualSeconds },
                    "Animation actual sampling times went backwards")
        let indices = Set(frames.map(\.sourceIndex))
        try require([1, 2, 4, 6, 9, 13, 18, 19, 20, 21].allSatisfy { indices.contains($0) }
            && frames.first?.sourceIndex == 1 && frames.last?.sourceIndex == 21,
                    "Sampling missed a required effect/expiry/resume/Stop/boundary witness")
    }
    static func gif(_ url: URL, selectedURL: URL, selected: Movie, deadline: Double) throws -> [Comparison] {
        let data = try boundedData(url)
        guard let decoder = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(decoder) as String? == "com.compuserve.gif",
              let properties = CGImageSourceCopyProperties(decoder, nil) as? [CFString: Any],
              let metadata = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { throw NSError(domain: "PicShot.RecordingInputExport", code: 7) }
        try require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width
            && (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height
            && CGImageSourceGetCount(decoder) == animationFrames
            && (metadata[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue == 0,
                    "GIF frame count or infinite looping differs")
        let generator = Self.generator(selectedURL)
        defer { generator.cancelAllCGImageGeneration() }
        var frames: [Comparison] = []
        for index in 0..<animationFrames {
            try autoreleasepool {
                try check(deadline)
                guard let image = CGImageSourceCreateImageAtIndex(decoder, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(decoder, index, nil) as? [CFString: Any],
                      let metadata = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                      let delay = (metadata[kCGImagePropertyGIFUnclampedDelayTime] ?? metadata[kCGImagePropertyGIFDelayTime]) as? NSNumber
                else { throw NSError(domain: "PicShot.RecordingInputExport", code: 8) }
                let pixels = try raster(image)
                try require(delay.doubleValue.isFinite && abs(delay.doubleValue * 1_000 - Double(delayMS(index, format: .gif))) < 0.01,
                            "GIF stored delay is not the planned centisecond duration")
                frames.append(try pixels.withUnsafeBufferPointer {
                    try compareAnimation($0, index: index, actualDelayMS: Int((delay.doubleValue * 1_000).rounded()),
                                         format: .gif, generator: generator, selected: selected, deadline: deadline)
                })
            }
        }
        try verifyTimeline(frames)
        return frames
    }
}
