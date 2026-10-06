import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO receives ONE still image at a time, never the animation. Its native
/// palette and LZW bytes are copied into a file-backed GIF89a stream and released
/// before the next frame. Memory depends on one frame, not animation duration.
final class GIFStreamingWriter {
    static let maximumEncodedFrameBytes = 8 * 1_024 * 1_024
    private var handle: FileHandle?
    private let maximumBytes: Int
    private let encodedFrameLimit: Int
    private let cancelled: @Sendable () -> Bool
    private(set) var bytesWritten = 0
    private(set) var framesWritten = 0
    private var dimensions: (width: Int, height: Int)?
    private var finished = false

    init(url: URL, maximumBytes: Int = GIFExporter.maximumOutputBytes,
         encodedFrameLimit: Int = maximumEncodedFrameBytes,
         cancelled: @escaping @Sendable () -> Bool = { false }) throws {
        guard maximumBytes > 0, encodedFrameLimit > 0, encodedFrameLimit <= Self.maximumEncodedFrameBytes else {
            throw GIFExportError.invalidOptions
        }
        self.maximumBytes = maximumBytes; self.encodedFrameLimit = encodedFrameLimit; self.cancelled = cancelled
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw GIFExportError.failed("The private GIF staging file could not be created.") }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(image: CGImage, delay: TimeInterval) throws {
        do { try autoreleasepool {
            try checkCancellation()
            guard image.width > 0, image.height > 0, image.width <= 1_920, image.height <= 1_920 else {
                throw GIFExportError.failed("The GIF frame dimensions exceed the supported bound.")
            }
            try GIFSingleFrame.requireOpaque(image)
            let data = try GIFSingleFrame.encode(image: image, maximumBytes: encodedFrameLimit, cancelled: cancelled)
            try append(singleFrameGIF: data, delay: delay)
        } } catch { close(); throw error }
    }

    /// Internal seam for container and native-pixel fidelity regression tests.
    /// Caller must already have verified the source raster is opaque. This
    /// accepts one bounded, complete native still GIF, not arbitrary GIF import.
    /// No animation or encoded-frame array is accumulated here.
    func append(singleFrameGIF data: Data, delay: TimeInterval) throws {
        do { try appendPacket(data, delay: delay) }
        catch { close(); throw error } // A partial/failed frame can never be finalized later.
    }

    private func appendPacket(_ data: Data, delay: TimeInterval) throws {
        try checkCancellation()
        guard !finished, handle != nil else { throw GIFExportError.failed("The GIF stream is already closed.") }
        guard data.count <= encodedFrameLimit else { throw GIFExportError.tooLarge }
        guard delay.isFinite, delay >= 0.02, delay <= 655.35 else { throw GIFExportError.invalidOptions }
        let centiseconds = Int((delay * 100).rounded())
        guard (2...65_535).contains(centiseconds) else { throw GIFExportError.invalidOptions }
        let frame = try GIFSingleFrame.parse(data)
        if let dimensions {
            guard dimensions.width == frame.width, dimensions.height == frame.height else {
                throw GIFExportError.failed("GIF frame dimensions changed during export.")
            }
        } else {
            dimensions = (frame.width, frame.height)
            // No global table: every frame carries its own native palette.
            try write(Data("GIF89a".utf8))
            try write(Data(word(frame.width) + word(frame.height) + [0x70, 0, 0]))
            try write(Data([0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]))
        }
        // Every image covers the full canvas and its source was verified opaque.
        // A native still may name an unused transparent palette index. Preserve
        // that index, but do not claim arbitrary-alpha animation composition.
        let flags: UInt8 = 0x08 | (frame.transparentIndex == nil ? 0 : 1)
        try write(Data([0x21, 0xF9, 4, flags] + word(centiseconds) + [frame.transparentIndex ?? 0, 0]))
        try write(Data([0x2C, 0, 0, 0, 0] + word(frame.width) + word(frame.height) + [frame.imagePacked]))
        try write(data, range: frame.paletteRange)
        try write(data, range: frame.imageDataRange)
        framesWritten += 1
    }

    func finish() throws {
        do { try finalize() } catch { close(); throw error }
    }

    private func finalize() throws {
        try checkCancellation()
        guard !finished, framesWritten > 0, let handle else { throw GIFExportError.noVideo }
        try write(Data([0x3B]))
        try handle.synchronize()
        try checkCancellation()
        finished = true
        close()
    }

    func close() { try? handle?.close(); handle = nil }
    deinit { close() }

    private func checkCancellation() throws {
        if cancelled() || Task.isCancelled { throw CancellationError() }
    }
    private func word(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8((value >> 8) & 255)] }
    private func write(_ data: Data, range: Range<Int>? = nil) throws {
        try checkCancellation()
        guard let handle else { throw GIFExportError.failed("The GIF stream is closed.") }
        let selected = range ?? 0..<data.count
        guard selected.lowerBound >= 0, selected.upperBound <= data.count,
              selected.count <= maximumBytes - bytesWritten else { throw GIFExportError.tooLarge }
        // The parser's ranges are offsets into withUnsafeBytes, not Data.Index;
        // even a non-zero-based Data slice is safe. FileHandle consumes them
        // synchronously and never outlives the borrowed pointer.
        try data.withUnsafeBytes { storage in
            guard selected.count > 0, let base = storage.baseAddress else { return }
            let borrowed = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base.advanced(by: selected.lowerBound)),
                                count: selected.count, deallocator: .none)
            try handle.write(contentsOf: borrowed)
        }
        bytesWritten += selected.count
    }
}

struct GIFSingleFrame {
    let width: Int
    let height: Int
    let paletteRange: Range<Int>
    let imageDataRange: Range<Int>
    /// Local table present, same interlace bit, selected table's size exponent.
    let imagePacked: UInt8
    let transparentIndex: UInt8?

    /// Honor alpha semantics, never the unused bytes in noneSkip* layouts.
    /// Alpha-capable opaque rasters are accepted; actual fractional/zero alpha
    /// is rejected instead of flattening or corrupting animation composition.
    static func requireOpaque(_ image: CGImage) throws {
        guard !image.isMask, image.width > 0, image.height > 0,
              image.width <= 1_920, image.height <= 1_920 else { throw GIFExportError.unsupportedTransparency }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return
        case .alphaOnly: throw GIFExportError.unsupportedTransparency
        case .first, .last, .premultipliedFirst, .premultipliedLast: break
        @unknown default: throw GIFExportError.unsupportedTransparency
        }
        // A float context avoids rounding a 16/32-bit fractional alpha to 255
        // and mistaking it for opacity. This scratch is at most 1920²×16 bytes,
        // is released before native GIF encoding, and never spans frames.
        var components = [Float](repeating: 0, count: image.width * image.height * 4)
        try components.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 32, bytesPerRow: image.width * 16, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw GIFExportError.failed("The video frame's opacity could not be verified.")
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        for index in stride(from: 3, to: components.count, by: 4) {
            if components[index] != 1 { throw GIFExportError.unsupportedTransparency }
        }
    }

    static func encode(image: CGImage, maximumBytes: Int = GIFStreamingWriter.maximumEncodedFrameBytes,
                       cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Data {
        let buffer = GIFEncodedFrameBuffer(maximumBytes: maximumBytes, cancelled: cancelled)
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            return Unmanaged<GIFEncodedFrameBuffer>.fromOpaque(info).takeUnretainedValue().append(bytes, count: count)
        }, releaseConsumer: { info in
            if let info { Unmanaged<GIFEncodedFrameBuffer>.fromOpaque(info).release() }
        })
        let retained = Unmanaged.passRetained(buffer)
        guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else {
            retained.release(); throw GIFExportError.failed("The single-frame GIF encoder could not open.")
        }
        guard let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.gif.identifier as CFString, 1, nil) else {
            throw GIFExportError.failed("The single-frame GIF encoder is unavailable.")
        }
        if cancelled() || Task.isCancelled { throw CancellationError() }
        CGImageDestinationAddImage(destination, image, nil)
        if let failure = buffer.failure { throw failure }
        if cancelled() || Task.isCancelled { throw CancellationError() }
        guard CGImageDestinationFinalize(destination) else {
            throw buffer.failure ?? GIFExportError.failed("The single-frame GIF could not be finalized.")
        }
        if let failure = buffer.failure { throw failure }
        if cancelled() || Task.isCancelled { throw CancellationError() }
        return buffer.data
    }

    static func parse(_ data: Data) throws -> Self {
        try data.withUnsafeBytes { storage in
            var cursor = GIFFrameCursor(bytes: storage.bindMemory(to: UInt8.self))
            let header = try cursor.take(6)
            let signature = String(decoding: cursor.bytes[header], as: UTF8.self)
            guard signature == "GIF87a" || signature == "GIF89a" else { throw invalid() }
            let width = try cursor.word(), height = try cursor.word(), screenPacked = try cursor.byte()
            guard (1...1_920).contains(width), (1...1_920).contains(height) else { throw invalid() }
            _ = try cursor.take(2) // Background index/aspect, neither affects the full-frame image.
            let globalSize = screenPacked & 7
            let globalPalette: Range<Int>?
            if screenPacked & 0x80 != 0 { globalPalette = try cursor.take(3 * (2 << Int(globalSize))) }
            else { globalPalette = nil }
            var transparent: UInt8?
            var packet: Self?
            var pendingControl = false
            while true {
                switch try cursor.byte() {
                case 0x21:
                    let label = try cursor.byte()
                    if label == 0xF9 {
                        guard packet == nil, !pendingControl, try cursor.byte() == 4 else { throw invalid() }
                        let flags = try cursor.byte()
                        guard flags & 0xE0 == 0 else { throw invalid() }
                        _ = try cursor.take(2) // Caller replaces the still frame's delay.
                        let index = try cursor.byte()
                        guard try cursor.byte() == 0 else { throw invalid() }
                        transparent = flags & 1 != 0 ? index : nil
                        pendingControl = true
                    } else if label == 0xFE || label == 0xFF {
                        // Non-rendering comment/application metadata is not copied.
                        // A plaintext rendering extension would need compositing.
                        _ = try cursor.subblocks()
                    } else { throw invalid() }
                case 0x2C:
                    guard packet == nil else { throw invalid() }
                    let left = try cursor.word(), top = try cursor.word()
                    let imageWidth = try cursor.word(), imageHeight = try cursor.word(), packed = try cursor.byte()
                    guard left == 0, top == 0, imageWidth == width, imageHeight == height, packed & 0x18 == 0 else { throw invalid() }
                    let hasLocal = packed & 0x80 != 0
                    let size = hasLocal ? packed & 7 : globalSize
                    let local: Range<Int>?
                    if hasLocal { local = try cursor.take(3 * (2 << Int(size))) }
                    else { local = nil }
                    guard let palette = local ?? globalPalette else { throw invalid() }
                    if let transparent, Int(transparent) >= palette.count / 3 { throw invalid() }
                    let start = cursor.offset
                    guard (2...8).contains(Int(try cursor.byte())) else { throw invalid() }
                    guard try cursor.subblocks() > 0 else { throw invalid() }
                    packet = Self(width: width, height: height, paletteRange: palette,
                        imageDataRange: start..<cursor.offset, imagePacked: 0x80 | (packed & 0x40) | size,
                        transparentIndex: transparent)
                case 0x3B:
                    guard let packet, cursor.offset == cursor.bytes.count else { throw invalid() }
                    return packet
                default: throw invalid()
                }
            }
        }
    }

    fileprivate static func invalid() -> GIFExportError { .failed("The single-frame GIF has unsupported or invalid structure.") }
}

private struct GIFFrameCursor {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset = 0
    mutating func byte() throws -> UInt8 { let index = try take(1).lowerBound; return bytes[index] }
    mutating func word() throws -> Int { let low = Int(try byte()); return low | (Int(try byte()) << 8) }
    mutating func take(_ count: Int) throws -> Range<Int> {
        guard count >= 0, count <= bytes.count - offset else { throw GIFSingleFrame.invalid() }
        let range = offset..<(offset + count); offset += count; return range
    }
    mutating func subblocks() throws -> Int {
        var total = 0
        while true {
            let count = Int(try byte())
            if count == 0 { return total }
            _ = try take(count); total += count
        }
    }
}

private final class GIFEncodedFrameBuffer {
    private let maximumBytes: Int
    private let cancelled: @Sendable () -> Bool
    private(set) var data = Data()
    private(set) var failure: Error?
    init(maximumBytes: Int, cancelled: @escaping @Sendable () -> Bool) {
        self.maximumBytes = maximumBytes; self.cancelled = cancelled
    }
    func append(_ pointer: UnsafeRawPointer, count: Int) -> Int {
        guard failure == nil else { return 0 }
        if cancelled() { failure = CancellationError(); return 0 }
        guard count <= maximumBytes - data.count else { failure = GIFExportError.tooLarge; return 0 }
        data.append(pointer.assumingMemoryBound(to: UInt8.self), count: count)
        return count
    }
}
