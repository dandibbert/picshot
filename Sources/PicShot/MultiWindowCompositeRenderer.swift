import CoreGraphics
import Foundation
import Darwin
import PicShotCore

/// Serialized actor owns one RGBA canvas and one source raster at a time. Capture
/// never stores a screenshot array or a full-desktop background. Transparent gaps
/// and source alpha survive source-over drawing in the selected desktop z-order.
private final class MultiWindowCanvasStorage: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let byteCount: Int
    init(byteCount: Int) throws {
        guard let pointer = calloc(1, byteCount) else { throw MultiWindowCaptureError.pixelLimit }
        self.pointer = pointer; self.byteCount = byteCount
    }
    deinit { free(pointer) }
}

actor MultiWindowCompositeRenderer {
    let layout: MultiWindowCaptureLayout
    private var context: CGContext?
    private var storage: MultiWindowCanvasStorage?
    private var next = 0
    private var inputPixels = 0
    private var isAppending = false
    init(layout: MultiWindowCaptureLayout) throws {
        try Task.checkCancellation()
        guard MultiWindowCaptureLimits.allows(width: layout.width, height: layout.height, pixels: MultiWindowCaptureLimits.outputPixels) else {
            throw MultiWindowCaptureError.pixelLimit
        }
        let storage = try MultiWindowCanvasStorage(byteCount: layout.width * layout.height * 4)
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
        self.layout = layout; context = canvas; self.storage = storage
        canvas.clear(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        canvas.interpolationQuality = .none; canvas.setShouldAntialias(false); canvas.setBlendMode(.normal)
    }
    func append(_ image: CGImage, windowID: UInt32, deadline: TimeInterval) async throws {
        try check(deadline)
        guard let canvas = context, let storage else { throw MultiWindowCaptureError.finished }
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
        let rect = placement.pixelBounds
        let destination = CGRect(x: rect.minX, y: CGFloat(layout.height) - rect.maxY, width: rect.width, height: rect.height)
        // Strips bound cancellation latency without creating crop-backed rasters.
        for top in stride(from: 0, to: Int(destination.height), by: 128) {
            try check(deadline)
            guard context != nil else { throw MultiWindowCaptureError.finished }
            canvas.saveGState()
            canvas.clip(to: CGRect(x: destination.minX, y: destination.minY + CGFloat(top),
                width: destination.width, height: min(128, destination.height - CGFloat(top))))
            canvas.draw(image, in: destination)
            canvas.restoreGState()
            await Task.yield()
        }
        guard context != nil else { throw MultiWindowCaptureError.finished }
        canvas.flush()
        try check(deadline)
        inputPixels += cost; next += 1
    }
    func finish(deadline: TimeInterval) throws -> CGImage {
        try check(deadline)
        guard let canvas = context else { throw MultiWindowCaptureError.finished }
        guard !isAppending, next == layout.placements.count, let storage else { throw MultiWindowCaptureError.incomplete }
        canvas.flush()
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
                        validate: () throws -> Void,
                        frame: (MultiWindowDescriptor, TimeInterval) async throws -> CGImage) async throws -> CGImage {
        try Task.checkCancellation(); try validate()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
        let renderer = try await Task.detached(priority: .userInitiated) { try MultiWindowCompositeRenderer(layout: layout) }.value
        do {
            for placement in layout.placements {
                try Task.checkCancellation(); try validate()
                try await append(placement.window, renderer: renderer, deadline: deadline, validate: validate, frame: frame)
            }
            try Task.checkCancellation(); try validate()
            let output = try await renderer.finish(deadline: deadline)
            try Task.checkCancellation(); try validate()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
            return output
        } catch {
            await renderer.discard()
            throw error
        }
    }
    private static func append(_ window: MultiWindowDescriptor, renderer: MultiWindowCompositeRenderer, deadline: TimeInterval,
                               validate: () throws -> Void,
                               frame: (MultiWindowDescriptor, TimeInterval) async throws -> CGImage) async throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
        let image = try await frame(window, deadline)
        try Task.checkCancellation(); try validate()
        try await renderer.append(image, windowID: window.id, deadline: deadline)
    }
}
