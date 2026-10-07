import CoreGraphics
import CryptoKit
import Foundation
import PicShotCore

/// Manual capture uses the native conversion workspace. Explicit alternatives
/// preserve the independent CGContext reference and diagnostic controls.
enum ManualScrollObservationStrategy: String, CaseIterable, Sendable {
    case fullFrame = "full-frame"
    case pooledFullFrame = "pooled-full-frame"
    case reusableFullFrame = "reusable-full-frame"
    case vImageFullFrame = "vimage-full-frame"

    static let productionDefault: Self = .vImageFullFrame

    static func diagnosticSelection(environment: [String: String]) throws -> Self {
        guard let raw = environment["PICSHOT_MANUAL_HASH_STRATEGY"] else { return productionDefault }
        guard let selection = Self(rawValue: raw) else { throw ScrollStitchError.invalidPixels }
        return selection
    }
}

/// A driver may own one normalization bitmap, with the existing 24 MP admission
/// limit (at most 96,000,000 bytes). The lock serializes detached-worker access;
/// ownership may be dropped by the main actor while an in-flight worker drains.
/// This bounds owned scratch memory, not CoreGraphics' retained backing or RSS.
final class ManualScrollReusableObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let metadataLock = NSLock()
    private var context: CGContext?
    private var byteCount = 0

    var allocatedByteCount: Int {
        // Diagnostics never wait for a long native draw/hash while on MainActor.
        metadataLock.lock(); defer { metadataLock.unlock() }
        return byteCount
    }

    func observation(_ image: CGImage) throws -> ManualScrollObservation {
        try withNormalizedPixels(image) { pixels in
            let rowBytes = image.width * 4
            var hash = SHA256()
            for start in stride(from: 0, to: image.height, by: 64) {
                try Task.checkCancellation()
                let offset = start * rowBytes, count = min(64, image.height - start) * rowBytes
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: pixels[offset..<offset + count]))
            }
            try Task.checkCancellation()
            return try ManualScrollObservation(width: image.width, height: image.height,
                                               rgbaSHA256: Array(hash.finalize()))
        }
    }

    /// The borrowed bytes cannot escape this synchronous closure. This also lets
    /// native tests compare every normalized byte with the independent reference.
    func withNormalizedPixels<Result>(_ image: CGImage,
                                      _ consume: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        try Task.checkCancellation()
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        return try autoreleasepool {
            let width = image.width, height = image.height
            guard width > 0, height > 0, width <= ScrollFrame.maximumDimension,
                  height <= ScrollFrame.maximumDimension, width <= ScrollFrame.maximumPixels / height else {
                throw ScrollStitchError.invalidPixels
            }
            // Fixed extent is part of a manual session. A mismatch must not
            // silently grow/replace the workspace or change normalization policy.
            if let context {
                guard context.width == width, context.height == height else {
                    throw ScrollStitchError.differentDimensions
                }
            } else {
                context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            }
            guard let context, let data = context.data else { throw ScrollStitchError.invalidPixels }
            metadataLock.lock()
            byteCount = context.bytesPerRow * context.height
            metadataLock.unlock()
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            // The reference draws into newly zeroed memory with source-over.
            // Clearing restores that state even for transparent or masked input.
            context.clear(rect)
            context.interpolationQuality = .none
            context.draw(image, in: rect)
            try Task.checkCancellation()
            let result = try consume(UnsafeRawBufferPointer(start: data, count: width * height * 4))
            try Task.checkCancellation()
            return result
        }
    }
}
