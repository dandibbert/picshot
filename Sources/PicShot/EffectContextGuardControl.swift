import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

struct EffectContextGuardControlMetadata: Codable, Equatable {
    let width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int
    let bitmapInfo: UInt32, alphaInfo: UInt32, renderingIntent: UInt32
    let colorSpaceName: String?, colorSpaceModel: Int?, colorSpaceICCSHA256: String?
    let shouldInterpolate: Bool, hasDecodeArray: Bool, isMask: Bool
}

struct EffectContextGuardControlRecord: Codable, Equatable {
    let effect: String
    let inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int
    let inputRGBASHA256: String, referenceRGBASHA256: String, candidateRGBASHA256: String
    let referenceStoredPixelsSHA256: String, candidateStoredPixelsSHA256: String
    let referenceMetadata: EffectContextGuardControlMetadata, candidateMetadata: EffectContextGuardControlMetadata
    let pixelsEqual: Bool, rgbaEqual: Bool, metadataEqual: Bool, outputDiffersFromInput: Bool
}

/// Scalar-only evidence for a separate positive control after the output guard.
/// It reports neither injected refusal coverage nor any memory observation.
struct EffectContextGuardControlReport: Codable, Equatable {
    let schemaVersion: Int
    let status: String, stage: String, comparisonKind: String, selectedPolicy: String
    let processBefore: EffectContextSnapshot, processAfter: EffectContextSnapshot
    let processControlCallCount: Int, independentReferenceContextCount: Int, independentReferenceCallCount: Int
    let rasterObservationCount: Int, memoryObservationCount: Int
    let records: [EffectContextGuardControlRecord]
}

@MainActor enum EffectContextGuardControl {
    enum Failure: Error, Equatable {
        case sourceCreation, referenceRender, unsupportedPixelLayout, missingProviderBytes
        case outputMismatch, ineffectiveFilter, unexpectedCounters
    }

    /// Call exactly once after the original output guard has returned, from its
    /// separate evidence stage. Never call from the measured paired workflow.
    static func verify() throws -> EffectContextGuardControlReport {
        try verify(configuration: .process)
    }

    /// Explicit configuration is a native-test seam; normal evidence uses process.
    static func verify(configuration: EffectContextConfiguration) throws -> EffectContextGuardControlReport {
        let policy = try configuration.selectedPolicy()
        let before = configuration.tracker.snapshot()
        // Deliberately independent of policy.contextOptions and the process
        // helper, so a mistaken candidate/reference option cannot mask a change.
        let reference = CIContext(options: [.cacheIntermediates: false])
        let source = try sourceImage()
        let inputPixels = try observe(source)
        var rasterObservations = 1
        let region = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let input = CIImage(cgImage: source)
        var records: [EffectContextGuardControlRecord] = []
        var processCalls = 0, referenceCalls = 0
        for effect in ["blur", "pixelate"] {
            let filtered = (effect == "blur"
                ? input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
                : input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 12,
                                                                  kCIInputCenterKey: CIVector(x: 0, y: 0)]))
                .cropped(to: region)
            referenceCalls += 1
            guard let expected = reference.createCGImage(filtered, from: region) else { throw Failure.referenceRender }
            processCalls += 1
            let actual = try configuration.render(filtered, from: region)
            let expectedPixels = try observe(expected)
            rasterObservations += 1
            let actualPixels = try observe(actual)
            rasterObservations += 1
            let pixelsEqual = expectedPixels.stored == actualPixels.stored
            let rgbaEqual = expectedPixels.rgba == actualPixels.rgba
            let metadataEqual = expectedPixels.metadata == actualPixels.metadata
            guard pixelsEqual, rgbaEqual, metadataEqual else { throw Failure.outputMismatch }
            let differs = actualPixels.rgba != inputPixels.rgba
            guard differs else { throw Failure.ineffectiveFilter }
            records.append(EffectContextGuardControlRecord(effect: effect,
                inputWidth: source.width, inputHeight: source.height, outputWidth: actual.width, outputHeight: actual.height,
                inputRGBASHA256: digest(inputPixels.rgba), referenceRGBASHA256: digest(expectedPixels.rgba),
                candidateRGBASHA256: digest(actualPixels.rgba), referenceStoredPixelsSHA256: digest(expectedPixels.stored),
                candidateStoredPixelsSHA256: digest(actualPixels.stored), referenceMetadata: expectedPixels.metadata,
                candidateMetadata: actualPixels.metadata, pixelsEqual: pixelsEqual, rgbaEqual: rgbaEqual,
                metadataEqual: metadataEqual, outputDiffersFromInput: differs))
        }
        let after = configuration.tracker.snapshot()
        guard processCalls == 2, referenceCalls == 2, records.count == 2, rasterObservations == 5,
              after.contextCount == before.contextCount, after.contextCount == 1,
              after.contextOptionCount == before.contextOptionCount,
              after.configuredCacheIntermediates == before.configuredCacheIntermediates,
              after.configuredMemoryTargetMegabytes == before.configuredMemoryTargetMegabytes,
              after.attemptCount - before.attemptCount == processCalls,
              after.publishCount - before.publishCount == processCalls,
              after.failureCount == before.failureCount else { throw Failure.unexpectedCounters }
        return EffectContextGuardControlReport(schemaVersion: 1, status: "passed",
            stage: "separate-positive-effect-control-after-output-guard", comparisonKind: "effect-context-memory-target",
            selectedPolicy: policy.rawValue, processBefore: before, processAfter: after,
            processControlCallCount: processCalls, independentReferenceContextCount: 1,
            independentReferenceCallCount: referenceCalls, rasterObservationCount: rasterObservations,
            memoryObservationCount: 0, records: records)
    }

    /// Reads real output bytes without a CGContext redraw or color/alpha
    /// conversion. RGBA changes component order only; premultiplication remains
    /// as declared by metadata. Both native stored rows and RGBA must match.
    private static func observe(_ image: CGImage) throws ->
        (stored: Data, rgba: Data, metadata: EffectContextGuardControlMetadata) {
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let first = image.alphaInfo == .first || image.alphaInfo == .premultipliedFirst
        let last = image.alphaInfo == .last || image.alphaInfo == .premultipliedLast
        guard image.width > 0, image.height > 0, image.width <= 129, image.height <= 101,
              image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.colorSpace?.model == .rgb,
              !image.bitmapInfo.contains(.floatComponents), first || last,
              [CGBitmapInfo.byteOrderDefault, .byteOrder32Big, .byteOrder32Little].contains(order),
              image.bytesPerRow >= image.width * 4, image.bytesPerRow <= 4096 else { throw Failure.unsupportedPixelLayout }
        guard let provider = image.dataProvider, let raw = provider.data,
              CFDataGetLength(raw) >= image.bytesPerRow * image.height else { throw Failure.missingProviderBytes }
        let bytes = raw as Data
        var stored = Data(), rgba = Data()
        stored.reserveCapacity(image.width * image.height * 4)
        rgba.reserveCapacity(image.width * image.height * 4)
        for y in 0..<image.height {
            let row = y * image.bytesPerRow
            stored.append(bytes[row..<(row + image.width * 4)])
            for x in 0..<image.width {
                let offset = row + x * 4
                let components = order == .byteOrder32Little
                    ? [bytes[offset + 3], bytes[offset + 2], bytes[offset + 1], bytes[offset]]
                    : [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
                if first { rgba.append(contentsOf: [components[1], components[2], components[3], components[0]]) }
                else { rgba.append(contentsOf: components) }
            }
        }
        let profile = image.colorSpace?.copyICCData() as Data?
        let metadata = EffectContextGuardControlMetadata(width: image.width, height: image.height,
            bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow,
            bitmapInfo: image.bitmapInfo.rawValue, alphaInfo: image.alphaInfo.rawValue,
            renderingIntent: image.renderingIntent.rawValue, colorSpaceName: image.colorSpace?.name.map { $0 as String },
            colorSpaceModel: image.colorSpace.map { Int($0.model.rawValue) }, colorSpaceICCSHA256: profile.map(digest),
            shouldInterpolate: image.shouldInterpolate, hasDecodeArray: image.decode != nil, isMask: image.isMask)
        return (stored, rgba, metadata)
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceImage() throws -> CGImage {
        let width = 129, height = 101, row = width * 4
        var bytes = Data(repeating: 0, count: row * height)
        let alphas = [0, 1, 2, 63, 127, 254, 255]
        for y in 0..<height { for x in 0..<width {
            let offset = y * row + x * 4, alpha = alphas[(x + y) % alphas.count]
            bytes[offset] = UInt8(((x * 19 + y * 3) % 256) * alpha / 255)
            bytes[offset + 1] = UInt8(((x * 5 + y * 23) % 256) * alpha / 255)
            bytes[offset + 2] = UInt8(((x * 31 + y * 11) % 256) * alpha / 255)
            bytes[offset + 3] = UInt8(alpha)
        } }
        guard let color = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: row, space: color,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric) else {
            throw Failure.sourceCreation
        }
        return image
    }
}
