import CoreGraphics
import Foundation
import PicShotCore

/// One RGBA canvas plus at most one incoming frame. No full-size frame array or
/// crop-backed image collection survives a draw. Gaps remain transparent black.
final class DisplayCompositeRenderer {
    let layout: DisplayCompositeLayout
    private var context: CGContext?
    private var nextIndex = 0

    init(layout: DisplayCompositeLayout) throws {
        try Task.checkCancellation()
        guard DisplayCompositeLayout.allowsSize(width: layout.width, height: layout.height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: layout.width, height: layout.height,
                                      bitsPerComponent: 8, bytesPerRow: layout.width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw DisplayCompositeError.pixelLimit
        }
        self.layout = layout
        self.context = context
        context.clear(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        // Uniform maximum density preserves desktop proportions. Lower-density
        // displays are explicitly upscaled with nearest-neighbor sampling; no
        // claim is made that this produces extra native detail.
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setBlendMode(.copy)
    }

    func append(_ image: CGImage, for displayID: UInt32) throws {
        try Task.checkCancellation()
        guard let context else { throw DisplayCompositeError.finished }
        guard nextIndex < layout.placements.count else { throw DisplayCompositeError.incomplete }
        let placement = layout.placements[nextIndex]
        guard placement.display.id == displayID,
              image.width == placement.display.pixelWidth, image.height == placement.display.pixelHeight else {
            throw DisplayCompositeError.layoutChanged
        }
        let rect = placement.pixelBounds
        // Global layout is top-left based; CGContext drawing is bottom-left based.
        // The source CGImage already has the display's rotation applied by SCK.
        let destination = CGRect(x: rect.minX, y: CGFloat(layout.height) - rect.maxY, width: rect.width, height: rect.height)
        context.draw(image, in: destination)
        context.flush()
        try Task.checkCancellation()
        nextIndex += 1
    }

    func finish() throws -> CGImage {
        try Task.checkCancellation()
        guard let context else { throw DisplayCompositeError.finished }
        guard nextIndex == layout.placements.count else { throw DisplayCompositeError.incomplete }
        guard let image = context.makeImage() else { throw DisplayCompositeError.incomplete }
        self.context = nil
        return image
    }

    func discard() { context = nil }
}

/// Injected frame/layout providers make sequential capture, cancellation, and
/// changed-layout behavior testable without screen access or privacy permissions.
@MainActor
enum SequentialDisplayCapture {
    static func capture(layout: DisplayCompositeLayout,
                        validate: () throws -> Void,
                        frame: (DisplayCaptureDescriptor) async throws -> CGImage) async throws -> CGImage {
        try Task.checkCancellation()
        try validate()
        let renderer = try DisplayCompositeRenderer(layout: layout)
        defer { renderer.discard() }
        for placement in layout.placements {
            try Task.checkCancellation()
            try validate()
            // Helper scope releases this frame before the next capture starts.
            try await captureNext(placement.display, renderer: renderer, validate: validate, frame: frame)
        }
        try Task.checkCancellation()
        try validate()
        return try renderer.finish()
    }

    private static func captureNext(_ display: DisplayCaptureDescriptor, renderer: DisplayCompositeRenderer,
                                    validate: () throws -> Void,
                                    frame: (DisplayCaptureDescriptor) async throws -> CGImage) async throws {
        let image = try await frame(display)
        try Task.checkCancellation()
        try validate()
        try autoreleasepool { try renderer.append(image, for: display.id) }
    }
}
