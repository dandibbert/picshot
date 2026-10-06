import Foundation
import Darwin
import PicShotCodecCore

/// Original narrow animation muxer. Only one bounded native still is borrowed
/// during append; previous bitstreams live only in the output file. Full-canvas
/// no-blend frames replace every pixel, including transparent pixels. No libwebp
/// animation encoder or retained-frame assembly API is used.
final class WebPContainerWriter {
    private var handle: FileHandle?
    private let width: Int, height: Int, maximumBytes: Int, frameByteLimit: Int
    private let cancelled: () -> Bool
    private(set) var bytesWritten = 0
    private(set) var framesWritten = 0
    private(set) var durationMS = 0
    private(set) var hasAlpha = false
    private var finished = false

    /// Takes ownership of an exclusively created, private output descriptor.
    init(fileDescriptor: Int32, width: Int, height: Int,
         maximumBytes: Int = CodecExportLimits.animationOutputBytes,
         frameByteLimit: Int = CodecExportLimits.animationFrameBytes,
         cancelled: @escaping () -> Bool = { false }) throws {
        self.width = width; self.height = height
        self.maximumBytes = maximumBytes; self.frameByteLimit = frameByteLimit; self.cancelled = cancelled
        handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        do {
            guard (1...CodecExportLimits.animationDimension).contains(width),
                  (1...CodecExportLimits.animationDimension).contains(height),
                  maximumBytes > 0, maximumBytes <= CodecExportLimits.animationOutputBytes,
                  frameByteLimit > 0, frameByteLimit <= CodecExportLimits.animationFrameBytes
            else { throw CodecExportFailure(.invalidOptions) }
            // Zero RIFF size intentionally makes an interrupted stream invalid.
            try write(Data("RIFF".utf8) + le(0, bytes: 4) + Data("WEBP".utf8))
            try write(Data("VP8X".utf8) + le(10, bytes: 4) + Data([0x02, 0, 0, 0])
                + le(width - 1, bytes: 3) + le(height - 1, bytes: 3))
            // Transparent black background; loop count zero means forever.
            try write(Data("ANIM".utf8) + le(6, bytes: 4) + Data(repeating: 0, count: 6))
        } catch { close(); throw error }
    }

    func append(stillWebP data: Data, durationMS: Int) throws {
        do {
            try checkCancellation()
            guard !finished, handle != nil else { throw CodecExportFailure(.invalidOutput) }
            guard data.count <= frameByteLimit else { throw CodecExportFailure(.tooLarge) }
            guard framesWritten < CodecExportLimits.animationFrames,
                  (1...60_000).contains(durationMS), durationMS <= 60_000 - self.durationMS
            else { throw CodecExportFailure(.tooLarge) }
            let frame = try WebPStillFrame.parse(data)
            guard frame.width == width, frame.height == height else { throw CodecExportFailure(.invalidOutput) }
            let payloadCount = frame.subchunks.reduce(16) { $0 + $1.count }
            guard payloadCount <= maximumBytes - bytesWritten - 8 else { throw CodecExportFailure(.tooLarge) }
            // ANMF x/y are stored divided by two; both are always zero here.
            // Bit 1 = do not blend, bit 0 = do not dispose. The full canvas is
            // replaced on every frame, so opaque→transparent transitions work.
            try write(Data("ANMF".utf8) + le(payloadCount, bytes: 4)
                + Data(repeating: 0, count: 6) + le(width - 1, bytes: 3)
                + le(height - 1, bytes: 3) + le(durationMS, bytes: 3) + Data([0x02]))
            for range in frame.subchunks { try write(data, range: range) }
            // Every subchunk already includes its own even-byte RIFF padding,
            // therefore the ANMF payload length is necessarily even as well.
            framesWritten += 1
            self.durationMS += durationMS
            hasAlpha = hasAlpha || frame.hasAlpha
        } catch { close(); throw error }
    }

    func finish() throws {
        do {
            try checkCancellation()
            guard !finished, framesWritten > 0, let handle else { throw CodecExportFailure(.invalidOutput) }
            // Only a complete successful stream gets its real RIFF length and
            // truthful aggregate alpha flag. A caller removes failed output.
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: le(bytesWritten - 8, bytes: 4))
            try handle.seek(toOffset: 20)
            try handle.write(contentsOf: Data([hasAlpha ? 0x12 : 0x02]))
            try handle.synchronize()
            try checkCancellation()
            finished = true
            close()
        } catch { close(); throw error }
    }

    func close() { try? handle?.close(); handle = nil }
    deinit { close() }

    private func checkCancellation() throws {
        if cancelled() || Task.isCancelled { throw CancellationError() }
    }
    private func le(_ value: Int, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func write(_ data: Data, range: Range<Int>? = nil) throws {
        try checkCancellation()
        guard let handle else { throw CodecExportFailure(.invalidOutput) }
        let selected = range ?? 0..<data.count
        guard selected.count <= maximumBytes - bytesWritten else { throw CodecExportFailure(.tooLarge) }
        // Foundation copies at most one still subchunk, never an animation.
        try handle.write(contentsOf: data.subdata(in: selected))
        bytesWritten += selected.count
    }
}

/// Validates the exact tiny subset emitted by the native still encoder before
/// copying its ALPH/VP8/VP8L subchunks into ANMF. It rejects metadata, animation,
/// duplicated/reordered chunks, truncated headers, bad dimensions and padding.
struct WebPStillFrame {
    let width: Int, height: Int, hasAlpha: Bool
    let subchunks: [Range<Int>]

    static func parse(_ data: Data) throws -> Self {
        func require(_ condition: Bool) throws {
            guard condition else { throw CodecExportFailure(.invalidOutput) }
        }
        func number(_ at: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(data[at + $1]) << ($1 * 8)) }
        }
        func fourCC(_ at: Int) -> String { String(decoding: data[at..<(at + 4)], as: UTF8.self) }
        try require(data.count >= 20 && data.count <= CodecExportLimits.animationFrameBytes)
        try require(fourCC(0) == "RIFF" && fourCC(8) == "WEBP" && number(4, 4) == data.count - 8)
        var offset = 12, chunks: [Range<Int>] = []
        var canvas: (Int, Int)?, extendedAlpha: Bool?
        var dimensions: (Int, Int)?, alpha = false, alphaChunk = false, imageSeen = false
        while offset < data.count {
            try require(data.count - offset >= 8 && !imageSeen)
            let kind = fourCC(offset), size = number(offset + 4, 4), payload = offset + 8
            try require(size <= data.count - payload)
            let end = payload + size, paddedEnd = end + (size & 1)
            try require(paddedEnd <= data.count)
            if size & 1 != 0 { try require(data[end] == 0) }
            switch kind {
            case "VP8X":
                try require(offset == 12 && canvas == nil && size == 10 && data[payload] & ~UInt8(0x10) == 0)
                try require(data[(payload + 1)..<(payload + 4)].allSatisfy { $0 == 0 })
                canvas = (number(payload + 4, 3) + 1, number(payload + 7, 3) + 1)
                extendedAlpha = data[payload] & 0x10 != 0
            case "ALPH":
                try require(canvas != nil && extendedAlpha == true && !alphaChunk && chunks.isEmpty && size >= 1)
                let header = data[payload]
                try require(header & 0xC0 == 0 && header & 0x03 <= 1 && ((header >> 4) & 0x03) <= 1)
                alphaChunk = true; alpha = true
                chunks.append(offset..<paddedEnd)
            case "VP8 ":
                try require(size >= 10 && data[payload] & 1 == 0
                    && ((data[payload] >> 1) & 7) <= 3 && data[payload] & 0x10 != 0)
                try require(data[(payload + 3)..<(payload + 6)].elementsEqual([0x9d, 0x01, 0x2a]))
                dimensions = (number(payload + 6, 2) & 0x3fff, number(payload + 8, 2) & 0x3fff)
                imageSeen = true; chunks.append(offset..<paddedEnd)
            case "VP8L":
                try require(!alphaChunk && size >= 5 && data[payload] == 0x2f)
                let bits = number(payload + 1, 4)
                try require(bits >> 29 == 0)
                dimensions = ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1)
                alpha = bits & (1 << 28) != 0
                imageSeen = true; chunks.append(offset..<paddedEnd)
            default: throw CodecExportFailure(.invalidOutput)
            }
            offset = paddedEnd
        }
        guard let dimensions, imageSeen else { throw CodecExportFailure(.invalidOutput) }
        try require((1...CodecExportLimits.animationDimension).contains(dimensions.0)
            && (1...CodecExportLimits.animationDimension).contains(dimensions.1))
        if let canvas { try require(canvas.0 == dimensions.0 && canvas.1 == dimensions.1) }
        if let extendedAlpha { try require(extendedAlpha == alpha) }
        return Self(width: dimensions.0, height: dimensions.1, hasAlpha: alpha, subchunks: chunks)
    }
}
