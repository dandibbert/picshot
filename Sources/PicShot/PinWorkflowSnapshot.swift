import AppKit

/// Native-view evidence only. AppKit may paint a titled window's background outside
/// cacheDisplay; compose that effective native background under the captured pixels.
/// Transparent surfaces use the current system window background for opaque review.
/// This does not alter a production view, pin raster, or exported image's alpha.
@MainActor enum PinWorkflowSnapshot {
    static let backgroundDescription = "Effective native window background (system window fallback for transparent surfaces) composited beneath cached native pixels; evidence only"

    static func write(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PicShotError.message("Pin snapshot could not allocate native bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage, image.width > 0, image.height > 0,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PicShotError.message("Pin snapshot could not compose native pixels")
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let background = view.window?.backgroundColor ?? .windowBackgroundColor
            let resolved = background.usingColorSpace(.deviceRGB)
            let opaque = (resolved?.alphaComponent ?? 0) > 0 ? background.withAlphaComponent(1) : NSColor.windowBackgroundColor
            context.setFillColor(opaque.cgColor)
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.fill(bounds); context.draw(image, in: bounds)
        guard let output = context.makeImage() else { throw PicShotError.message("Pin snapshot has no composited pixels") }
        try output.writePNG(to: url)
    }
}
