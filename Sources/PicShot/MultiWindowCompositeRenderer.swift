import Accelerate
import CoreGraphics
import Foundation
import Darwin
import PicShotCore

/// Production stays on the existing implementation until native differential
/// and fresh-process resource evidence pass. Only diagnostics select the candidate.
enum MultiWindowCompositionMode: String, CaseIterable, Sendable {
    case coreGraphicsBaseline
    /// Normalize once, then preserve Quartz's sampling and blending behavior.
    /// Replaces the rejected CPU prototype preserved at commit 83406c0d.
    case normalizedCandidate
    static let production: Self = .coreGraphicsBaseline
}

/// Counts only explicit allocations and the admitted source's row-stride bytes.
/// kvImageNoAllocate controls its destination, not private vImage/ColorSync or
/// decoder scratch. Never interpret this counter as a process-memory cap.
final class MultiWindowCompositionResourceProbe: @unchecked Sendable {
    enum Kind { case canvas, normalization, admittedSource }
    private let lock = NSLock()
    private var canvas = 0, normalization = 0, source = 0, peak = 0, conversions = 0
    private var canonicalImagesCreated = 0
    private weak var canonicalImage: CGImage?
    var snapshot: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["canvasBytes": canvas, "normalizationBytes": normalization, "admittedSourceBytes": source,
            "currentRasterBytes": canvas + normalization + source, "peakRasterBytes": peak, "normalizationCount": conversions,
            "canonicalImagesCreated": canonicalImagesCreated, "liveCanonicalImages": canonicalImage == nil ? 0 : 1]
    }
    fileprivate func recordCanonicalImage(_ image: CGImage) throws {
        lock.lock(); defer { lock.unlock() }
        guard canonicalImage == nil else { throw MultiWindowCaptureError.incomplete }
        canonicalImage = image; canonicalImagesCreated += 1
    }
    fileprivate func change(_ kind: Kind, by bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .canvas: canvas += bytes
        case .normalization: normalization += bytes; if bytes > 0 { conversions += 1 }
        case .admittedSource: source += bytes
        }
        peak = max(peak, canvas + normalization + source)
    }
}

/// Serialized actor owns one RGBA canvas and one source raster at a time. Capture
/// never stores a screenshot array or a full-desktop background. Transparent gaps
/// and source alpha survive source-over drawing in the selected desktop z-order.
private final class MultiWindowCanvasStorage: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let byteCount: Int
    private let probe: MultiWindowCompositionResourceProbe?
    private let kind: MultiWindowCompositionResourceProbe.Kind
    init(byteCount: Int, probe: MultiWindowCompositionResourceProbe? = nil,
         kind: MultiWindowCompositionResourceProbe.Kind = .canvas) throws {
        guard let pointer = calloc(1, byteCount) else { throw MultiWindowCaptureError.pixelLimit }
        self.pointer = pointer; self.byteCount = byteCount; self.probe = probe; self.kind = kind
        probe?.change(kind, by: byteCount)
    }
    deinit { free(pointer); probe?.change(kind, by: -byteCount) }
}

actor MultiWindowCompositeRenderer {
    let layout: MultiWindowCaptureLayout
    let mode: MultiWindowCompositionMode
    private let resourceProbe: MultiWindowCompositionResourceProbe?
    private var context: CGContext?
    private var storage: MultiWindowCanvasStorage?
    private var next = 0
    private var inputPixels = 0
    private var isAppending = false
    private let diagnosticTailStripFirst: Bool
    private let diagnosticObserve: MultiWindowDiagnosticObserver?
    init(layout: MultiWindowCaptureLayout, mode: MultiWindowCompositionMode = .production,
         resourceProbe: MultiWindowCompositionResourceProbe? = nil,
         diagnosticTailStripFirst: Bool = false, diagnosticObserve: MultiWindowDiagnosticObserver? = nil) throws {
        try Task.checkCancellation()
        guard MultiWindowCaptureLimits.allows(width: layout.width, height: layout.height, pixels: MultiWindowCaptureLimits.outputPixels) else {
            throw MultiWindowCaptureError.pixelLimit
        }
        if mode != .coreGraphicsBaseline { try layout.validateNormalizedRasterBudget() }
        self.layout = layout; self.mode = mode; self.resourceProbe = resourceProbe
        self.diagnosticTailStripFirst = diagnosticTailStripFirst; self.diagnosticObserve = diagnosticObserve
        diagnosticObserve?(.canvasBeforeAllocation, 0, -1)
        let storage = try MultiWindowCanvasStorage(byteCount: layout.width * layout.height * 4, probe: resourceProbe)
        self.storage = storage
        // Both modes use the same Quartz context, transform, clips and blend mode.
        // Only the candidate's source is normalized into an explicit owned buffer.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw MultiWindowCaptureError.pixelLimit }
        let contextOwnership = Unmanaged.passRetained(storage)
        guard let canvas = CGContext(data: storage.pointer, width: layout.width, height: layout.height, bitsPerComponent: 8,
                  bytesPerRow: layout.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue,
                  releaseCallback: { info, _ in
                      if let info { Unmanaged<MultiWindowCanvasStorage>.fromOpaque(info).release() }
                  }, releaseInfo: contextOwnership.toOpaque()) else {
            contextOwnership.release(); throw MultiWindowCaptureError.pixelLimit
        }
        context = canvas
        canvas.clear(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        canvas.interpolationQuality = .none; canvas.setShouldAntialias(false); canvas.setBlendMode(.normal)
        diagnosticObserve?(.canvasAfterAllocation, 0, -1)
    }
    func append(_ image: CGImage, windowID: UInt32, deadline: TimeInterval) async throws {
        try check(deadline)
        guard let storage else { throw MultiWindowCaptureError.finished }
        defer { withExtendedLifetime(storage) {} }
        guard !isAppending, next < layout.placements.count else { throw MultiWindowCaptureError.incomplete }
        isAppending = true
        defer { isAppending = false }
        let placement = layout.placements[next]
        guard placement.window.id == windowID else { throw MultiWindowCaptureError.changed }
        try placement.window.validateRaster(width: image.width, height: image.height)
        guard image.bitsPerComponent == 8, image.bitsPerPixel <= 32,
              image.bytesPerRow <= MultiWindowCaptureLimits.framePixels * 4 / image.height else {
            throw MultiWindowCaptureError.pixelLimit
        }
        let cost = image.width * image.height
        guard cost <= MultiWindowCaptureLimits.totalInputPixels - inputPixels else { throw MultiWindowCaptureError.pixelLimit }
        let sourceBytes = image.bytesPerRow * image.height
        resourceProbe?.change(.admittedSource, by: sourceBytes)
        defer { resourceProbe?.change(.admittedSource, by: -sourceBytes) }
        switch mode {
        case .coreGraphicsBaseline:
            try await appendBaseline(image, placement: placement, deadline: deadline)
        case .normalizedCandidate:
            // Admission includes all three live rasters, including source padding,
            // and occurs before allocating the normalization workspace.
            _ = try layout.normalizedRasterBytes(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow)
            diagnosticObserve?(.normalizationBefore, windowID, -1)
            let normalized = try normalize(image, deadline: deadline)
            defer { withExtendedLifetime(normalized) {} }
            diagnosticObserve?(.normalizationAfter, windowID, -1)
            diagnosticObserve?(.candidateBlendBefore, windowID, -1)
            // The provider borrows the one normalized allocation. Quartz now
            // receives canonical sRGB RGBA without an ImageIO-backed source.
            // Its private drawing cache remains a measured native cost.
            let canonical = try canonicalImage(normalized, width: image.width, height: image.height)
            try resourceProbe?.recordCanonicalImage(canonical)
            try await appendBaseline(canonical, placement: placement, deadline: deadline)
            if let diagnosticObserve {
                withExtendedLifetime((image, canonical)) { diagnosticObserve(.candidateBlendAfter, windowID, -1) }
            }
        }
        guard self.storage != nil else { throw MultiWindowCaptureError.finished }
        try check(deadline)
        inputPixels += cost; next += 1
    }
    private func appendBaseline(_ image: CGImage, placement: MultiWindowPlacement, deadline: TimeInterval) async throws {
        guard let canvas = context else { throw MultiWindowCaptureError.finished }
        let windowID = placement.window.id
        let rect = placement.pixelBounds
        let destination = CGRect(x: rect.minX, y: CGFloat(layout.height) - rect.maxY, width: rect.width, height: rect.height)
        // Strips bound cancellation latency without creating crop-backed rasters.
        // The opt-in diagnostic only reorders the same disjoint clips; the
        // source, draw count, touched pixels and maximum strip size are unchanged.
        let stripCount = (Int(destination.height) + 127) / 128
        let lastStripTop = (stripCount - 1) * 128
        diagnosticObserve?(.appendBeforeDraws, windowID, -1)
        for ordinal in 0..<stripCount {
            let top = diagnosticTailStripFirst ? (ordinal == 0 ? lastStripTop : (ordinal - 1) * 128) : ordinal * 128
            try check(deadline)
            guard context != nil else { throw MultiWindowCaptureError.finished }
            canvas.saveGState()
            canvas.clip(to: CGRect(x: destination.minX, y: destination.minY + CGFloat(top),
                width: destination.width, height: min(128, destination.height - CGFloat(top))))
            diagnosticObserve?(.drawBefore, windowID, top)
            canvas.draw(image, in: destination)
            diagnosticObserve?(.drawAfter, windowID, top)
            canvas.restoreGState()
            await Task.yield()
        }
        guard context != nil else { throw MultiWindowCaptureError.finished }
        canvas.flush()
        if let diagnosticObserve {
            withExtendedLifetime(image) { diagnosticObserve(.appendAfterFlush, windowID, -1) }
        }
    }

    private func normalize(_ image: CGImage, deadline: TimeInterval) throws -> MultiWindowCanvasStorage {
        try check(deadline)
        return try autoreleasepool {
            let buffer = try MultiWindowCanvasStorage(byteCount: image.width * image.height * 4,
                probe: resourceProbe, kind: .normalization)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                    renderingIntent: .defaultIntent) else { throw MultiWindowCaptureError.incomplete }
            var destination = vImage_Buffer(data: buffer.pointer, height: vImagePixelCount(image.height),
                width: vImagePixelCount(image.width), rowBytes: image.width * 4)
            // One color-managed conversion into caller-owned storage per frame.
            // This native call is not interruptible; late/cancelled work is rejected.
            let result = withExtendedLifetime(space) {
                vImageBuffer_InitWithCGImage(&destination, &format, nil, image, vImage_Flags(kvImageNoAllocate))
            }
            try check(deadline)
            guard result == kvImageNoError, destination.data == buffer.pointer,
                  destination.width == vImagePixelCount(image.width), destination.height == vImagePixelCount(image.height),
                  destination.rowBytes == image.width * 4 else { throw MultiWindowCaptureError.incomplete }
            return buffer
        }
    }

    private func canonicalImage(_ buffer: MultiWindowCanvasStorage, width: Int, height: Int) throws -> CGImage {
        let retained = Unmanaged.passRetained(buffer)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: buffer.pointer, size: buffer.byteCount,
            releaseData: { info, _, _ in
                if let info { Unmanaged<MultiWindowCanvasStorage>.fromOpaque(info).release() }
            }) else { retained.release(); throw MultiWindowCaptureError.incomplete }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw MultiWindowCaptureError.incomplete
        }
        return image
    }

    func finish(deadline: TimeInterval) throws -> CGImage {
        try check(deadline)
        guard let storage else { throw MultiWindowCaptureError.finished }
        guard !isAppending, next == layout.placements.count else { throw MultiWindowCaptureError.incomplete }
        diagnosticObserve?(.finishBefore, 0, -1)
        let diagnosticCanvas = diagnosticObserve == nil ? nil : context
        context?.flush()
        // Transfer the same allocation into the final image; makeImage() could
        // otherwise copy the complete canvas at finish. No drawing occurs again.
        let retained = Unmanaged.passRetained(storage)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: storage.pointer, size: storage.byteCount, releaseData: { info, _, _ in
            if let info { Unmanaged<MultiWindowCanvasStorage>.fromOpaque(info).release() }
        }) else { retained.release(); throw MultiWindowCaptureError.incomplete }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: layout.width, height: layout.height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: layout.width * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw MultiWindowCaptureError.incomplete }
        context = nil; self.storage = nil
        if let diagnosticObserve {
            withExtendedLifetime(diagnosticCanvas) { diagnosticObserve(.finishAfterOwnershipTransfer, 0, -1) }
        }
        return image
    }
    func discard() { context = nil; storage = nil }
    private func check(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
    }
}

@MainActor
enum SequentialMultiWindowCapture {
    static func capture(layout: MultiWindowCaptureLayout, deadline: TimeInterval,
                        mode: MultiWindowCompositionMode = .production,
                        resourceProbe: MultiWindowCompositionResourceProbe? = nil,
                        diagnosticTailStripFirst: Bool = false, diagnosticObserve: MultiWindowDiagnosticObserver? = nil,
                        validate: () throws -> Void,
                        frame: (MultiWindowDescriptor, TimeInterval) async throws -> CGImage) async throws -> CGImage {
        try Task.checkCancellation(); try validate()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
        let renderer = try await Task.detached(priority: .userInitiated) {
            try MultiWindowCompositeRenderer(layout: layout, mode: mode, resourceProbe: resourceProbe,
                diagnosticTailStripFirst: diagnosticTailStripFirst, diagnosticObserve: diagnosticObserve)
        }.value
        do {
            for placement in layout.placements {
                try Task.checkCancellation(); try validate()
                try await append(placement.window, renderer: renderer, deadline: deadline,
                    diagnosticObserve: diagnosticObserve, validate: validate, frame: frame)
                diagnosticObserve?(.inputAfterAppendScope, placement.window.id, -1)
            }
            try Task.checkCancellation(); try validate()
            let output = try await renderer.finish(deadline: deadline)
            diagnosticObserve?(.outputAfterFinishScope, 0, -1)
            try Task.checkCancellation(); try validate()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
            return output
        } catch {
            await renderer.discard()
            throw error
        }
    }
    private static func append(_ window: MultiWindowDescriptor, renderer: MultiWindowCompositeRenderer, deadline: TimeInterval,
                               diagnosticObserve: MultiWindowDiagnosticObserver?,
                               validate: () throws -> Void,
                               frame: (MultiWindowDescriptor, TimeInterval) async throws -> CGImage) async throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
        let image = try await frame(window, deadline)
        try Task.checkCancellation(); try validate()
        diagnosticObserve?(.inputBeforeAppend, window.id, -1)
        try await renderer.append(image, windowID: window.id, deadline: deadline)
    }
}
