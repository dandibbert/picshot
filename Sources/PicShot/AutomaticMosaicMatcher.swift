import Foundation
import CoreGraphics
import PicShotCore

/// Each editor owns an instance; cancelling one editor never cancels another.
/// Admission is process-wide, and remains held until the worker actually exits.
actor AutomaticMosaicMatcher {
    private static let admission = AutomaticMosaicAdmission()
    private var active: Task<RepeatedRegionMatchResult, Error>?
    private let limits: RepeatedRegionMatchLimits

    init(limits: RepeatedRegionMatchLimits = .init()) { self.limits = limits }

    func findMatches(in image: CGImage, seed: RepeatedRegionPixelRect) async throws -> RepeatedRegionMatchResult {
        guard !Task.isCancelled else { throw RepeatedRegionMatchError.cancelled }
        try limits.validate(width: image.width, height: image.height, seed: seed)
        guard active == nil, Self.admission.acquire() else { throw RepeatedRegionMatchError.busy }
        // CGImage is immutable; its original backing stays alive only for this job.
        let source = AutomaticMosaicSource(image: image), limits = self.limits
        let started = ProcessInfo.processInfo.systemUptime
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard !Task.isCancelled else { throw RepeatedRegionMatchError.cancelled }
                guard ProcessInfo.processInfo.systemUptime - started < limits.timeLimit else {
                    throw RepeatedRegionMatchError.budgetExceeded(.time)
                }
                let raster = try Self.rasterize(source.image, seed: seed, limits: limits)
                let remaining = limits.timeLimit - (ProcessInfo.processInfo.systemUptime - started)
                guard !Task.isCancelled else { throw RepeatedRegionMatchError.cancelled }
                guard remaining > 0 else { throw RepeatedRegionMatchError.budgetExceeded(.time) }
                let searchLimits = RepeatedRegionMatchLimits(maxImagePixels: limits.maxImagePixels,
                    maxTemplatePixels: limits.maxTemplatePixels, maxScratchBytes: limits.maxScratchBytes,
                    maxPixelComparisons: limits.maxPixelComparisons, maxRawCandidates: limits.maxRawCandidates,
                    maxResults: limits.maxResults, timeLimit: remaining)
                return try RepeatedRegionMatcher.findMatches(in: raster, seed: seed, limits: searchLimits)
            }
        }
        active = worker
        defer { active = nil; Self.admission.release() }
        let result = try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else { throw RepeatedRegionMatchError.cancelled }
        guard ProcessInfo.processInfo.systemUptime - started < limits.timeLimit else {
            throw RepeatedRegionMatchError.budgetExceeded(.time)
        }
        return result
    }

    func cancel() { active?.cancel() }

    /// CGContext's image row storage and CGImage cropping use top-left rows;
    /// editor annotations use y-up coordinates and must convert at their boundary.
    /// No CTM flip is applied here. Tests use asymmetric top/bottom markers.
    nonisolated static func rasterize(_ image: CGImage, seed: RepeatedRegionPixelRect,
                                      limits: RepeatedRegionMatchLimits = .init()) throws -> RepeatedRegionRaster {
        try limits.validate(width: image.width, height: image.height, seed: seed)
        guard !Task.isCancelled else { throw RepeatedRegionMatchError.cancelled }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw RepeatedRegionMatchError.invalidRaster
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            // This bounded native draw is synchronous; cancellation is cooperative
            // immediately before and after it, then every ~1024 search comparisons.
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        guard !Task.isCancelled else { throw RepeatedRegionMatchError.cancelled }
        return try RepeatedRegionRaster(width: image.width, height: image.height, rgba: bytes)
    }
}

private struct AutomaticMosaicSource: @unchecked Sendable { let image: CGImage }

/// Only the service's worker exit releases admission. A cancel request alone
/// cannot start a second allocation while the old raster is still alive.
final class AutomaticMosaicAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = false
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !admitted else { return false }
        admitted = true; return true
    }
    func release() {
        lock.lock(); defer { lock.unlock() }
        admitted = false
    }
}
