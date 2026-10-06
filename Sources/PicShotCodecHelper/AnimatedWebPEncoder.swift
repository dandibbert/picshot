import AVFoundation
import CoreGraphics
import Foundation
import Darwin
import CPicShotCodecs
import PicShotCodecCore

struct AnimatedWebPResult {
    let width: Int, height: Int, frameCount: Int
    let duration: Double
    let outputBytes: Int
    let hasAlpha: Bool
}

/// Integer WebP millisecond boundaries preserve the selected playback length.
/// Sampling is quantized separately to the nearest 600 Hz source request tick;
/// CMTime(seconds:) truncation must not select the preceding boundary frame.
struct AnimatedWebPFramePlan {
    let duration: Double, frameCount: Int, durationMS: Int
    init(duration: Double, options: CodecAnimationOptions) throws {
        try options.validate()
        guard duration.isFinite, duration > 0, duration <= options.maximumDuration + 0.000_001,
              duration <= CodecExportLimits.animationDuration else { throw CodecExportFailure(.tooLarge) }
        self.duration = duration
        durationMS = Int((duration * 1_000).rounded())
        guard durationMS > 0 else { throw CodecExportFailure(.invalidSource) }
        frameCount = max(1, min(options.maximumFrames, Int(ceil(duration * Double(options.frameRate))), durationMS))
    }
    func samplingTime(for index: Int) -> CMTime {
        precondition((0..<frameCount).contains(index))
        let ticks = Int64((Double(index) * duration * 600 / Double(frameCount)).rounded())
        let lastSourceTick = max(Int64(0), Int64(ceil(duration * 600)) - 1)
        return CMTime(value: min(ticks, lastSourceTick), timescale: 600)
    }
    func delayMS(for index: Int) -> Int {
        precondition((0..<frameCount).contains(index))
        // Round cumulative boundaries, rather than rounding every delay. This
        // gives e.g. 33,34,33 milliseconds at 30 FPS instead of losing time.
        let lower = (index * durationMS + frameCount / 2) / frameCount
        let upper = ((index + 1) * durationMS + frameCount / 2) / frameCount
        return upper - lower
    }
}

enum AnimatedWebPEncoder {
    /// Only the signed, one-job helper calls this native path. The app freezes
    /// a self-contained selected H.264 clip, then enforces child deadline/RSS/
    /// cancellation/termination. No source metadata is copied into the WebP.
    static func encode(files: CodecJobFiles, request: CodecExportRequest,
                       isCancelled: @escaping () -> Bool,
                       progress: @escaping (Double) throws -> Void) async throws -> AnimatedWebPResult {
        try request.validate()
        guard request.kind == .animation, request.format == .webp, let options = request.animation
        else { throw CodecExportFailure(.invalidOptions) }
        let cancellation = WebPAnimationCancellation(external: isCancelled)
        try cancellation.check()
        try CodecAnimationMP4Admission.validate(files: files, isCancelled: { cancellation.isCancelled })
        try files.validateSourceIdentity()
        let asset = AVURLAsset(url: files.sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        else { throw CodecExportFailure(.invalidSource) }
        let duration = try await asset.load(.duration).seconds
        let plan = try AnimatedWebPFramePlan(duration: duration, options: options)
        try cancellation.check()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maximumDimension, height: options.maximumDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var stream: WebPContainerWriter?
        var canvas: (Int, Int)?
        var previousActualTime: CMTime?
        defer { stream?.close(); generator.cancelAllCGImageGeneration() }
        try progress(0)
        do {
            try await withTaskCancellationHandler {
                for index in 0..<plan.frameCount {
                    // Extraction, raster normalization, still compression and
                    // append share one drained pool. Only one decoded raster
                    // and one <=8 MiB compressed still survive inside this pool.
                    try autoreleasepool {
                        try cancellation.check()
                        var actualTime = CMTime.invalid
                        let image = try generator.copyCGImage(at: plan.samplingTime(for: index), actualTime: &actualTime)
                        try cancellation.check()
                        guard actualTime.isNumeric, actualTime.seconds.isFinite,
                              actualTime.seconds >= -1.0 / 600,
                              actualTime.seconds < duration + 1.0 / 600,
                              image.width <= options.maximumDimension, image.height <= options.maximumDimension
                        else { throw CodecExportFailure(.invalidSource) }
                        if let previousActualTime, CMTimeCompare(actualTime, previousActualTime) < 0 {
                            throw CodecExportFailure(.invalidSource)
                        }
                        previousActualTime = actualTime
                        let raster = try CodecRaster(image: image, preserveAlpha: request.preserveAlpha,
                                                     isCancelled: { cancellation.isCancelled })
                        if let canvas {
                            guard canvas.0 == raster.width, canvas.1 == raster.height else { throw CodecExportFailure(.invalidSource) }
                        } else {
                            canvas = (raster.width, raster.height)
                            stream = try WebPContainerWriter(fileDescriptor: files.createOutput(), width: raster.width, height: raster.height,
                                                             cancelled: { cancellation.isCancelled })
                        }
                        let encoded = try encodeFrame(raster: raster, request: request, isCancelled: { cancellation.isCancelled })
                        try stream?.append(stillWebP: encoded, durationMS: plan.delayMS(for: index))
                    }
                    try cancellation.check()
                    try progress(Double(index + 1) / Double(plan.frameCount + 1))
                    await Task.yield()
                }
                try cancellation.check()
                try files.validateSourceIdentity()
                try stream?.finish()
                try cancellation.check()
            } onCancel: {
                cancellation.cancel()
                generator.cancelAllCGImageGeneration()
            }
        } catch {
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard let stream, let canvas, stream.framesWritten == plan.frameCount else { throw CodecExportFailure(.invalidOutput) }
        let count = try files.validateOutput()
        guard count == stream.bytesWritten else { throw CodecExportFailure(.invalidOutput) }
        // The helper's finalization layer independently demuxes/decodes EVERY
        // frame, hashes the real output and produces its decoded preview. Only
        // that successful response is eligible for parent publication.
        return AnimatedWebPResult(width: canvas.0, height: canvas.1, frameCount: stream.framesWritten,
            duration: Double(stream.durationMS) / 1_000, outputBytes: count, hasAlpha: stream.hasAlpha)
    }

    /// Internal seam also used by real native encode→mux→demux regression tests.
    static func encodeFrame(raster: CodecRaster, request: CodecExportRequest,
                            isCancelled: @escaping () -> Bool = { false }) throws -> Data {
        try request.validate()
        guard raster.width <= CodecExportLimits.animationDimension, raster.height <= CodecExportLimits.animationDimension
        else { throw CodecExportFailure(.tooLarge) }
        let sink = WebPFrameSink(cancelled: isCancelled)
        var options = PSCodecDefaultOptions(UInt32(PS_CODEC_WEBP))
        options.quality = UInt32(request.quality); options.lossless = request.lossless ? 1 : 0
        // Normalization has already white-composited when alpha was disabled.
        options.preserveAlpha = request.preserveAlpha ? 1 : 0
        options.alphaQuality = UInt32(request.alphaQuality)
        options.maxOutputBytes = UInt64(CodecExportLimits.animationFrameBytes)
        options.maxThreads = 1; options.effort = 4
        var error = PSCodecError()
        let status = raster.rgba.withUnsafeBufferPointer { pixels in
            PSCodecEncodeRGBA(pixels.baseAddress, UInt64(pixels.count), UInt32(raster.width), UInt32(raster.height),
                UInt64(raster.width * 4), &options, { bytes, count, cumulative, context in
                    guard let context, let bytes else { return 0 }
                    let sink = Unmanaged<WebPFrameSink>.fromOpaque(context).takeUnretainedValue()
                    if sink.cancelled() || Task.isCancelled { sink.wasCancelled = true; return 0 }
                    guard count <= UInt64(CodecExportLimits.animationFrameBytes - sink.data.count),
                          cumulative == UInt64(sink.data.count) + count else { sink.exceededLimit = true; return 0 }
                    sink.data.append(bytes, count: Int(count))
                    return 1
                }, { _, _, context in
                    guard let context else { return 0 }
                    let sink = Unmanaged<WebPFrameSink>.fromOpaque(context).takeUnretainedValue()
                    if sink.cancelled() || Task.isCancelled { sink.wasCancelled = true; return 0 }
                    return 1
                }, Unmanaged.passUnretained(sink).toOpaque(), &error)
        }
        if sink.wasCancelled || isCancelled() || Task.isCancelled { throw CancellationError() }
        if sink.exceededLimit || status == PS_CODEC_LIMIT { throw CodecExportFailure(.tooLarge) }
        guard status == PS_CODEC_OK else { throw CodecExportFailure(.failed) }
        _ = try WebPStillFrame.parse(sink.data)
        return sink.data
    }
}

private final class WebPFrameSink {
    var data = Data(), wasCancelled = false, exceededLimit = false
    let cancelled: () -> Bool
    init(cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
}
private final class WebPAnimationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let external: () -> Bool
    init(external: @escaping () -> Bool) { self.external = external }
    var isCancelled: Bool {
        lock.lock(); let stopped = self.stopped; lock.unlock()
        return stopped || external()
    }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws { if isCancelled || Task.isCancelled { throw CancellationError() } }
}

/// Bounded, fail-closed ISO-BMFF gate before AVFoundation sees any media URL.
/// Adapted from PicShot's authored GIF admission policy: only local H.264/AAC
/// sample entries with self-contained data references; no alias, URL or playlist.
enum CodecAnimationMP4Admission {
    static let maximumAtoms = 16_384
    static let maximumDepth = 12
    static let maximumMetadataBytesRead = 1_048_576
    static let maximumMetadataBytesSpanned: UInt64 = 16_777_216
    struct Report {
        let atomCount: Int
        let metadataBytesRead: Int
        let mediaDataBytesSkipped: UInt64
        let trackCount: Int
    }

    @discardableResult
    static func validate(files: CodecJobFiles, isCancelled: @escaping () -> Bool = { false }) throws -> Report {
        let descriptor = try files.openSource()
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_size > 0,
              information.st_size <= CodecExportLimits.animationInputBytes else { throw CodecExportFailure(.invalidSource) }
        return try Reader(descriptor: descriptor, size: UInt64(information.st_size), isCancelled: isCancelled).validate()
    }

    private struct Atom {
        let type: String
        let offset: UInt64
        let payload: UInt64
        let end: UInt64
        var payloadBytes: UInt64 { end - payload }
    }
    private struct Sample {
        let codec: String
        let reference: Int
    }
    private final class Reader {
        let descriptor: Int32
        let size: UInt64
        var atomCount = 0
        var bytesRead = 0
        let isCancelled: () -> Bool
        init(descriptor: Int32, size: UInt64, isCancelled: @escaping () -> Bool) {
            self.descriptor = descriptor; self.size = size; self.isCancelled = isCancelled
        }

        func validate() throws -> Report {
            let roots = try atoms(from: 0, to: size, depth: 0)
            let topTypes: Set<String> = ["ftyp", "moov", "mdat", "moof", "mfra", "free", "skip", "wide"]
            try allowed(roots, topTypes)
            let fileType = try one("ftyp", in: roots)
            let movie = try one("moov", in: roots)
            try validateFileType(fileType)
            var mediaBytes: UInt64 = 0
            var metadataBytes: UInt64 = 0
            for atom in roots {
                if atom.type == "mdat" { mediaBytes += atom.payloadBytes }
                else if !["free", "skip", "wide"].contains(atom.type) {
                    try require(atom.payloadBytes <= maximumMetadataBytesSpanned - metadataBytes)
                    metadataBytes += atom.payloadBytes
                }
            }
            try require(mediaBytes > 0)
            let movieChildren = try atoms(in: movie, depth: 1)
            try allowed(movieChildren, ["mvhd", "trak", "mvex", "udta", "meta", "iods", "free", "skip"])
            let tracks = movieChildren.filter { $0.type == "trak" }
            try require(!tracks.isEmpty && tracks.count <= 32)
            var videoTracks = 0
            for track in tracks {
                let trackChildren = try atoms(in: track, depth: 2)
                try allowed(trackChildren, ["tkhd", "mdia", "edts", "udta", "meta", "tapt", "free", "skip"])
                let media = try one("mdia", in: trackChildren)
                let mediaChildren = try atoms(in: media, depth: 3)
                try allowed(mediaChildren, ["mdhd", "hdlr", "minf", "elng", "udta", "meta", "free", "skip"])
                let handler = try one("hdlr", in: mediaChildren)
                try require(handler.payloadBytes >= 12)
                let handlerPrefix = try read(at: handler.payload, count: 12)
                try require(number(handlerPrefix.prefix(4)) == 0)
                let kind = String(decoding: handlerPrefix[8..<12], as: UTF8.self)
                try require(kind == "vide" || kind == "soun")
                if kind == "vide" { videoTracks += 1 }
                let information = try one("minf", in: mediaChildren)
                let informationChildren = try atoms(in: information, depth: 4)
                try allowed(informationChildren, ["vmhd", "smhd", "hdlr", "dinf", "stbl", "free", "skip"])
                let references = try dataReferences(try one("dinf", in: informationChildren))
                let samples = try sampleDescriptions(try one("stbl", in: informationChildren))
                for sample in samples {
                    try require(sample.reference > 0 && sample.reference <= references)
                    try require(kind == "vide" ? ["avc1", "avc3"].contains(sample.codec) : sample.codec == "mp4a")
                }
            }
            try require(videoTracks > 0)
            return Report(atomCount: atomCount, metadataBytesRead: bytesRead, mediaDataBytesSkipped: mediaBytes, trackCount: tracks.count)
        }

        private func validateFileType(_ atom: Atom) throws {
            try require(atom.payloadBytes >= 8 && atom.payloadBytes <= 1_024 && atom.payloadBytes % 4 == 0)
            let data = try read(at: atom.payload, count: Int(atom.payloadBytes))
            let supported: Set<String> = ["isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1"]
            let major = String(decoding: data.prefix(4), as: UTF8.self)
            try require(supported.contains(major))
        }

        private func dataReferences(_ information: Atom) throws -> Int {
            let children = try atoms(in: information, depth: 5)
            try allowed(children, ["dref", "free", "skip"])
            let table = try one("dref", in: children)
            let count = try entryCount(table)
            let entries = try atoms(from: table.payload + 8, to: table.end, depth: 6, allowSelfContainedURL: true)
            try require(entries.count == count)
            for entry in entries {
                // Full-box version 0, flags exactly 1, and no location bytes.
                // Reject urn, alias, external url, and ambiguous trailing data.
                try require(entry.type == "url " && entry.payloadBytes == 4)
                try require(number(try read(at: entry.payload, count: 4)) == 1)
            }
            return count
        }

        private func sampleDescriptions(_ table: Atom) throws -> [Sample] {
            let children = try atoms(in: table, depth: 5)
            try allowed(children, ["stsd", "stts", "ctts", "stsc", "stsz", "stz2", "stco", "co64", "stss", "stps", "sdtp",
                                   "sgpd", "sbgp", "padb", "stsh", "subs", "free", "skip"])
            let descriptions = try one("stsd", in: children)
            let count = try entryCount(descriptions)
            let entries = try atoms(from: descriptions.payload + 8, to: descriptions.end, depth: 6)
            try require(entries.count == count)
            return try entries.map { entry in
                try require(["avc1", "avc3", "mp4a"].contains(entry.type))
                let headerBytes = entry.type == "mp4a" ? 28 : 78
                try require(entry.payloadBytes >= UInt64(headerBytes))
                let prefix = try read(at: entry.payload, count: 10)
                try require(prefix.prefix(6).allSatisfy { $0 == 0 })
                let reference = Int(number(prefix[6..<8]))
                if entry.type == "mp4a" { try require(number(prefix[8..<10]) == 0) } // Version-0 audio sample entry.
                let extensions = try atoms(from: entry.payload + UInt64(headerBytes), to: entry.end, depth: 7,
                    allowNativeChrmLeaf: entry.type == "avc1" || entry.type == "avc3")
                if entry.type == "mp4a" {
                    try allowed(extensions, ["esds", "btrt"])
                    try validateAudioDescriptor(try one("esds", in: extensions))
                } else {
                    try allowed(extensions, ["avcC", "pasp", "colr", "clap", "btrt", "fiel", "gama", "cspc", "mdcv", "clli", "chrm"])
                    // Native evidence contains one opaque 00 00 leaf. Admit
                    // only that representation without inferring its semantics.
                    try require(extensions.filter { $0.type == "chrm" }.count <= 1)
                    let configuration = try one("avcC", in: extensions)
                    try require(configuration.payloadBytes > 0 && configuration.payloadBytes <= 65_536)
                }
                return Sample(codec: entry.type, reference: reference)
            }
        }

        private func validateAudioDescriptor(_ atom: Atom) throws {
            try require(atom.payloadBytes >= 9 && atom.payloadBytes <= 65_536)
            let data = try read(at: atom.payload, count: min(Int(atom.payloadBytes), 16))
            try require(number(data.prefix(4)) == 0 && data[4] == 3) // ES_Descriptor.
            var position = 5
            var length = 0
            var ended = false
            for _ in 0..<4 {
                try require(position < data.count)
                let byte = data[position]; position += 1
                length = (length << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { ended = true; break }
            }
            try require(ended && length >= 3 && UInt64(position + length) == atom.payloadBytes && position + 2 < data.count)
            // ES_ID is followed by flags; URL_Flag would supply another source.
            try require(data[position + 2] & 0x40 == 0)
        }

        private func entryCount(_ atom: Atom) throws -> Int {
            try require(atom.payloadBytes >= 8)
            let prefix = try read(at: atom.payload, count: 8)
            let count = Int(number(prefix[4..<8]))
            try require(number(prefix.prefix(4)) == 0 && (1...16).contains(count))
            return count
        }
        private func allowed(_ atoms: [Atom], _ types: Set<String>) throws {
            try require(atoms.allSatisfy { types.contains($0.type) })
        }
        private func one(_ type: String, in atoms: [Atom]) throws -> Atom {
            let matches = atoms.filter { $0.type == type }
            try require(matches.count == 1)
            return matches[0]
        }
        private func atoms(in parent: Atom, depth: Int) throws -> [Atom] {
            try atoms(from: parent.payload, to: parent.end, depth: depth)
        }
        private func atoms(from start: UInt64, to end: UInt64, depth: Int, allowSelfContainedURL: Bool = false,
                           allowNativeChrmLeaf: Bool = false) throws -> [Atom] {
            try require(depth <= maximumDepth && start <= end && end <= size)
            var offset = start
            var result: [Atom] = []
            while offset < end {
                if isCancelled() || Task.isCancelled { throw CancellationError() }
                try require(atomCount < maximumAtoms && end - offset >= 8)
                atomCount += 1
                let header = try read(at: offset, count: 8)
                let type = String(decoding: header[4..<8], as: UTF8.self)
                // Compressed movies hide the reference tree from this gate.
                try require(!["rmra", "rmda", "rdrf", "cmov", "urn ", "alis"].contains(type))
                try require(type != "url " || allowSelfContainedURL)
                var length = number(header.prefix(4))
                var headerBytes: UInt64 = 8
                if length == 1 {
                    try require(end - offset >= 16)
                    length = number(try read(at: offset + 8, count: 8))
                    headerBytes = 16
                } else if length == 0 {
                    // ISO-BMFF permits the final media-data box to extend to EOF.
                    try require(depth == 0 && type == "mdat")
                    length = end - offset
                }
                try require(length >= headerBytes && length <= end - offset)
                if type == "chrm" {
                    // Compatibility is confined to one normal-header leaf in
                    // avc1/avc3. Every other traversed container rejects it.
                    try require(allowNativeChrmLeaf && headerBytes == 8 && length == 10)
                    try require(number(try read(at: offset + headerBytes, count: 2)) == 0)
                }
                result.append(Atom(type: type, offset: offset, payload: offset + headerBytes, end: offset + length))
                offset += length
            }
            return result
        }
        private func read(at offset: UInt64, count: Int) throws -> Data {
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            try require(count >= 0 && count <= maximumMetadataBytesRead - bytesRead && offset <= size && UInt64(count) <= size - offset)
            bytesRead += count
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                var obtained = 0
                while obtained < count {
                    if isCancelled() || Task.isCancelled { throw CancellationError() }
                    let result = pread(descriptor, base.advanced(by: obtained), count - obtained, off_t(offset + UInt64(obtained)))
                    if result < 0 && errno == EINTR { continue }
                    try require(result > 0)
                    obtained += result
                }
            }
            return data
        }
        private func number<T: Sequence>(_ bytes: T) -> UInt64 where T.Element == UInt8 {
            bytes.reduce(0) { ($0 << 8) | UInt64($1) }
        }
        private func require(_ condition: Bool) throws {
            guard condition else { throw CodecExportFailure(.invalidSource) }
        }
    }
}
