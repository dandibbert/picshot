import AppKit
import PicShotCore

/// One separately allocated thumbnail. Even a CGImage made by cropping a huge
/// image is copied into bounded storage, so it cannot retain the original provider.
@MainActor
final class LiveScrollThumbnailView: NSView {
    static let maximumDimension = 1_024
    static let maximumPixels = 262_144
    private(set) var image: CGImage?
    private(set) var viewportFraction: CGRect = .zero
    private var positionVerified = false
    private var hasCurrentPreview = false
    private var dimensions = ""
    var isPositionVerified: Bool { positionVerified && hasCurrentPreview && image != nil }
    var viewportMarkerColor: NSColor { isPositionVerified ? .systemGreen : .systemOrange }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = .init("scroll.live.thumbnail")
        setAccessibilityElement(true); setAccessibilityRole(.image)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    var imageRect: CGRect {
        guard let image else { return .zero }
        let area = bounds.insetBy(dx: 7, dy: 7)
        guard area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.minY, width: size.width, height: size.height)
    }

    var viewportMarker: CGRect? {
        LiveScrollCaptureGeometry.viewportMarker(fraction: viewportFraction, imageRect: imageRect)
    }

    func display(positionVerified: Bool, dimensions: String) {
        self.positionVerified = positionVerified; self.dimensions = dimensions
        updateAccessibility(); needsDisplay = true
    }

    private func updateAccessibility() {
        let prefix = dimensions.isEmpty ? "滚动拼接预览" : "滚动拼接预览，\(dimensions)"
        setAccessibilityLabel(prefix + (isPositionVerified ? "，绿色框表示已验证的当前页面位置" :
            "，当前位置尚未验证，橙色框仅表示上次位置"))
    }

    func update(image source: CGImage?, viewportFraction: CGRect) {
        guard let source else {
            image = nil; self.viewportFraction = .zero; hasCurrentPreview = false
            updateAccessibility(); needsDisplay = true; return
        }
        let next = boundedImage(size: CGSize(width: source.width, height: source.height)) { context, rect in
            context.interpolationQuality = .medium
            context.draw(source, in: rect)
        }
        acceptPreview(next, viewportFraction: viewportFraction)
    }

    func update(image source: NSImage, viewportFraction: CGRect) {
        let next = boundedImage(size: source.size) { context, rect in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            source.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }
        acceptPreview(next, viewportFraction: viewportFraction)
    }

    private func acceptPreview(_ next: CGImage?, viewportFraction: CGRect) {
        // Failed preview generation keeps the last good bounded image and its
        // last position, while making its uncertainty visible and accessible.
        hasCurrentPreview = next != nil
        if let next {
            image = next
            self.viewportFraction = LiveScrollCaptureGeometry.normalizedViewport(viewportFraction) ?? .zero
            if self.viewportFraction.isEmpty { hasCurrentPreview = false }
        }
        updateAccessibility(); needsDisplay = true
    }

    private func boundedImage(size: CGSize, draw: (CGContext, CGRect) -> Void) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        var scale = min(1, CGFloat(Self.maximumDimension) / longest)
        let scaledPixels = (size.width * scale) * (size.height * scale)
        if scaledPixels > CGFloat(Self.maximumPixels) { scale *= sqrt(CGFloat(Self.maximumPixels) / scaledPixels) }
        let width = max(1, Int(floor(size.width * scale)))
        let height = max(1, Int(floor(size.height * scale)))
        guard width <= Self.maximumDimension, height <= Self.maximumDimension,
              width * height <= Self.maximumPixels,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context, CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLiveScrollSurface(bounds, appearance: effectiveAppearance)
        guard let image else {
            let text = "实时预览" as NSString
            text.draw(in: CGRect(x: 10, y: 14, width: max(0, bounds.width - 20), height: 34), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let rect = imageRect
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let marker = viewportMarker {
            viewportMarkerColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: marker).fill()
            // A very long document can map the viewport to less than a point.
            // Keep a visible outline, clipped to the actual thumbnail bounds.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let visible = CGRect(x: marker.minX, y: marker.minY, width: max(2, marker.width), height: max(2, marker.height))
            let path = NSBezierPath(rect: visible.insetBy(dx: 0.75, dy: 0.75))
            viewportMarkerColor.setStroke(); path.lineWidth = 1.5
            if !isPositionVerified { path.setLineDash([3, 2], count: 2, phase: 0) }
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
