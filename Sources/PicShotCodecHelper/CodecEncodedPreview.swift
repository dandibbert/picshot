import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import CPicShotCodecs
import PicShotCodecCore

/// Always decodes actual final bytes. WebP animation verification traverses all
/// composited frames through the independent upstream demux/decoder, retaining
/// only its current frame and a bounded first-frame PNG.
enum CodecEncodedPreview {
    static func verifyAndWrite(files: CodecJobFiles, request: CodecExportRequest, width: Int, height: Int,
                               frames: Int, duration: Double, isCancelled: () -> Bool) throws -> (sha256: String, previewBytes: Int) {
        let fd = try files.openOutput()
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        let encoded = try CodecFileIO.read(file, maximum: request.outputByteLimit, isCancelled: isCancelled)
        try CodecOutputMagic.validate(encoded, format: request.format)
        let preview: Data
        if request.kind == .still {
            preview = try verifyStill(encoded, format: request.format, width: width, height: height, isCancelled: isCancelled)
        } else {
            preview = try verifyAnimation(encoded, width: width, height: height, frames: frames, duration: duration, isCancelled: isCancelled)
        }
        guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
        let outputFD = try files.createPreview(); defer { Darwin.close(outputFD) }
        try CodecFileIO.write(preview, to: outputFD, isCancelled: isCancelled)
        guard fsync(outputFD) == 0 else { throw CodecExportFailure(.invalidOutput) }
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return (digest, try files.validatePreview())
    }
    static func verifyStill(_ encoded: Data, format: CodecExportFormat, width: Int, height: Int,
                            isCancelled: () -> Bool) throws -> Data {
        guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
        var error = PSCodecError()
        let decoded = encoded.withUnsafeBytes { raw in
            PSCodecDecodeRGBA(format.nativeValue, raw.bindMemory(to: UInt8.self).baseAddress, UInt64(encoded.count),
                UInt64(CodecExportLimits.stillPixels), UInt64(CodecExportLimits.stillPixels * 4), &error)
        }
        guard let decoded else { throw CodecExportFailure.native(error.code) }
        defer { PSCodecDecodedFree(decoded) }
        guard Int(PSCodecDecodedWidth(decoded)) == width, Int(PSCodecDecodedHeight(decoded)) == height,
              PSCodecDecodedStride(decoded) == UInt64(width * 4), PSCodecDecodedByteCount(decoded) == UInt64(width * height * 4),
              let pixels = PSCodecDecodedPixels(decoded) else { throw CodecExportFailure(.invalidOutput) }
        return try previewPNG(pixels: pixels, width: width, height: height, isCancelled: isCancelled)
    }
    static func verifyAnimation(_ encoded: Data, width: Int, height: Int, frames: Int, duration: Double,
                                isCancelled: () -> Bool) throws -> Data {
        guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
        var error = PSCodecError()
        let decoded = encoded.withUnsafeBytes { raw in
            PSCodecWebPAnimationOpen(raw.bindMemory(to: UInt8.self).baseAddress, UInt64(encoded.count),
                UInt64(CodecExportLimits.animationDimension * CodecExportLimits.animationDimension),
                UInt32(CodecExportLimits.animationFrames), UInt64(CodecExportLimits.animationDimension * CodecExportLimits.animationDimension * 4), &error)
        }
        guard let decoded else { throw CodecExportFailure.native(error.code) }
        defer { PSCodecAnimationFree(decoded) }
        let expectedMS = UInt64((duration * 1_000).rounded())
        guard Int(PSCodecAnimationWidth(decoded)) == width, Int(PSCodecAnimationHeight(decoded)) == height,
              Int(PSCodecAnimationFrameCount(decoded)) == frames, PSCodecAnimationLoopCount(decoded) == 0,
              PSCodecAnimationDurationMS(decoded) == expectedMS else { throw CodecExportFailure(.invalidOutput) }
        var preview: Data?, totalMS: UInt64 = 0
        for index in 0..<frames {
            guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
            var pixels: UnsafePointer<UInt8>?, count: UInt64 = 0, frameMS: UInt32 = 0
            let code = PSCodecAnimationNext(decoded, &pixels, &count, &frameMS, &error)
            guard code == PS_CODEC_OK, let pixels, count == UInt64(width * height * 4), frameMS > 0
            else { throw CodecExportFailure(.invalidOutput) }
            totalMS += UInt64(frameMS)
            guard totalMS <= 60_000 else { throw CodecExportFailure(.invalidOutput) }
            if index == 0 { preview = try previewPNG(pixels: pixels, width: width, height: height, isCancelled: isCancelled) }
        }
        var extra: UnsafePointer<UInt8>?, extraBytes: UInt64 = 0, extraMS: UInt32 = 0
        guard PSCodecAnimationNext(decoded, &extra, &extraBytes, &extraMS, &error) == PS_CODEC_END,
              totalMS == expectedMS, let preview else { throw CodecExportFailure(.invalidOutput) }
        return preview
    }
    static func previewPNG(pixels: UnsafePointer<UInt8>, width: Int, height: Int,
                           isCancelled: () -> Bool) throws -> Data {
        try CodecExportLimits.validateStillDimensions(width: width, height: height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(dataInfo: nil, data: pixels, size: width * height * 4, releaseData: { _, _, _ in }),
              let source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CodecExportFailure(.invalidOutput) }
        // The native owner keeps the borrowed pixels alive for this whole call.
        // A 1000px fallback leaves room for PNG framing with incompressible data.
        for dimension in [CodecExportLimits.previewDimension, 1_000] {
            guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
            let scale = min(1, Double(dimension) / Double(max(width, height)))
            let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
            guard w * h * 4 <= CodecExportLimits.previewBytes,
                  let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw CodecExportFailure(.invalidOutput) }
            context.interpolationQuality = .high; context.setBlendMode(.copy)
            context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let image = context.makeImage() else { throw CodecExportFailure(.invalidOutput) }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            else { throw CodecExportFailure(.invalidOutput) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CodecExportFailure(.invalidOutput) }
            if data.length <= CodecExportLimits.previewBytes { return data as Data }
        }
        throw CodecExportFailure(.tooLarge)
    }
}
