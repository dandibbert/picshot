import Foundation
import Darwin
import CPicShotCodecs
import PicShotCodecCore

enum CodecStillEncoder {
    static func encode(files: CodecJobFiles, request: CodecExportRequest,
                       isCancelled: @escaping () -> Bool, progress: @escaping (Double) throws -> Void) throws -> (width: Int, height: Int) {
        let raster = try CodecRaster.readFrozenPNG(files: files, preserveAlpha: request.preserveAlpha, isCancelled: isCancelled)
        try progress(0.05)
        let descriptor = try files.createOutput(); defer { Darwin.close(descriptor) }
        try encode(raster: raster, request: request, descriptor: descriptor, isCancelled: isCancelled) { try progress(0.05 + $0 * 0.8) }
        guard fsync(descriptor) == 0 else { throw CodecExportFailure(.invalidOutput) }
        try files.validateSourceIdentity()
        return (raster.width, raster.height)
    }
    static func encode(raster: CodecRaster, request: CodecExportRequest, descriptor: Int32,
                       isCancelled: @escaping () -> Bool, progress: @escaping (Double) throws -> Void) throws {
        try request.validate()
        guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
        let context = CodecEncodeContext(descriptor: descriptor, limit: request.outputByteLimit, isCancelled: isCancelled, progress: progress)
        var options = PSCodecDefaultOptions(request.format.nativeValue)
        options.quality = UInt32(request.quality); options.lossless = request.lossless ? 1 : 0
        options.preserveAlpha = request.preserveAlpha ? 1 : 0
        options.alphaQuality = UInt32(request.lossless ? 100 : request.alphaQuality)
        options.maxThreads = 2; options.effort = 4; options.maxOutputBytes = UInt64(request.outputByteLimit)
        var error = PSCodecError()
        let code = raster.rgba.withUnsafeBufferPointer { buffer in
            PSCodecEncodeRGBA(buffer.baseAddress, UInt64(buffer.count), UInt32(raster.width), UInt32(raster.height),
                UInt64(raster.width * 4), &options, codecWriter, codecProgress,
                Unmanaged.passUnretained(context).toOpaque(), &error)
        }
        if let failure = context.failure { throw failure }
        guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
        guard code == PS_CODEC_OK else { throw CodecExportFailure.native(code) }
        guard context.written > 0 else { throw CodecExportFailure(.invalidOutput) }
    }
}

extension CodecExportFormat {
    var nativeValue: UInt32 { self == .webp ? UInt32(PS_CODEC_WEBP) : UInt32(PS_CODEC_AVIF) }
}
extension CodecExportFailure {
    static func native(_ code: Int32) -> Self {
        switch code {
        case Int32(PS_CODEC_CANCELLED): return .init(.cancelled)
        case Int32(PS_CODEC_LIMIT): return .init(.tooLarge)
        case Int32(PS_CODEC_MEMORY): return .init(.memoryLimit)
        case Int32(PS_CODEC_INVALID): return .init(.invalidOptions)
        case Int32(PS_CODEC_DECODE): return .init(.invalidOutput)
        default: return .init(.failed)
        }
    }
}
private final class CodecEncodeContext {
    let descriptor: Int32
    let limit: Int
    let isCancelled: () -> Bool
    let progress: (Double) throws -> Void
    var written: UInt64 = 0
    var failure: Error?
    init(descriptor: Int32, limit: Int, isCancelled: @escaping () -> Bool, progress: @escaping (Double) throws -> Void) {
        self.descriptor = descriptor; self.limit = limit; self.isCancelled = isCancelled; self.progress = progress
    }
}
private let codecWriter: PSCodecWriter = { bytes, count, cumulative, opaque in
    guard let opaque, let bytes else { return 0 }
    let context = Unmanaged<CodecEncodeContext>.fromOpaque(opaque).takeUnretainedValue()
    do {
        guard count > 0, count <= UInt64(context.limit), context.written <= UInt64(context.limit) - count,
              cumulative == context.written + count else { throw CodecExportFailure(.tooLarge) }
        try CodecFileIO.write(bytes, count: Int(count), to: context.descriptor, isCancelled: context.isCancelled)
        context.written = cumulative
        return 1
    } catch { context.failure = error; return 0 }
}
private let codecProgress: PSCodecProgress = { percent, _, opaque in
    guard let opaque else { return 0 }
    let context = Unmanaged<CodecEncodeContext>.fromOpaque(opaque).takeUnretainedValue()
    do {
        guard !context.isCancelled() else { throw CodecExportFailure(.cancelled) }
        guard percent <= 100 else { throw CodecExportFailure(.protocolViolation) }
        try context.progress(Double(percent) / 100)
        return 1
    } catch { context.failure = error; return 0 }
}
