import AppKit
import CoreGraphics
import PicShotCore

struct FrozenCapturePixelSample {
    let coordinate: CapturePixelCoordinate
    let color: CapturePixelColor
    let pixelBounds: CGRect
    let image: CGImage
}

/// Retains the existing immutable capture, but never copies the entire display.
/// Each sample materializes at most 9 × 9 sRGB pixels (324 bytes). Returned loupe
/// images own only this tiny context, not the cropped full-display backing store.
final class FrozenCapturePixelSampler {
    static let radius = 4
    private let image: CGImage

    init(image: CGImage) { self.image = image }

    func sample(at coordinate: CapturePixelCoordinate) -> FrozenCapturePixelSample? {
        guard coordinate.x >= 0, coordinate.y >= 0, coordinate.x < image.width, coordinate.y < image.height else { return nil }
        let left = max(0, coordinate.x - Self.radius), top = max(0, coordinate.y - Self.radius)
        let right = min(image.width, coordinate.x + Self.radius + 1)
        let bottom = min(image.height, coordinate.y + Self.radius + 1)
        let width = right - left, height = bottom - top
        let pixelBounds = CGRect(x: left, y: top, width: width, height: height)
        guard let crop = image.cropping(to: pixelBounds), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self), let patch = context.makeImage() else { return nil }
        let offset = (coordinate.y - top) * width * 4 + (coordinate.x - left) * 4
        let alpha = Int(bytes[offset + 3])
        func straight(_ value: UInt8) -> Int {
            alpha == 0 ? 0 : min(255, (Int(value) * 255 + alpha / 2) / alpha)
        }
        let color = CapturePixelColor(red: straight(bytes[offset]), green: straight(bytes[offset + 1]),
                                      blue: straight(bytes[offset + 2]), alpha: alpha)
        return FrozenCapturePixelSample(coordinate: coordinate, color: color, pixelBounds: pixelBounds, image: patch)
    }
}

/// A small click-through HUD. The center square always identifies the sampled
/// source pixel; missing pixels beyond display edges stay blank rather than wrap.
@MainActor
final class CapturePrecisionHUD: NSView {
    var sample: FrozenCapturePixelSample? {
        didSet {
            needsDisplay = true
            if let sample {
                setAccessibilityLabel("Frozen screen pixel X \(sample.coordinate.x), Y \(sample.coordinate.y), sRGB \(sample.color.hex)")
            }
        }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let sample else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).stroke()
        let cell: CGFloat = 9, origin = CGPoint(x: 10, y: 10)
        let grid = CGRect(origin: origin, size: CGSize(width: 81, height: 81))
        NSColor.black.setFill()
        grid.fill()
        let offsetX = sample.pixelBounds.minX - CGFloat(sample.coordinate.x) + CGFloat(FrozenCapturePixelSampler.radius)
        let offsetY = sample.pixelBounds.minY - CGFloat(sample.coordinate.y) + CGFloat(FrozenCapturePixelSampler.radius)
        let patchRect = CGRect(x: origin.x + offsetX * cell, y: origin.y + offsetY * cell,
                               width: sample.pixelBounds.width * cell, height: sample.pixelBounds.height * cell)
        NSImage(cgImage: sample.image, size: sample.pixelBounds.size).draw(
            in: patchRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none.rawValue])
        let gridLines = NSBezierPath()
        for index in 0...9 {
            let offset = CGFloat(index) * cell
            gridLines.move(to: CGPoint(x: origin.x + offset, y: grid.minY))
            gridLines.line(to: CGPoint(x: origin.x + offset, y: grid.maxY))
            gridLines.move(to: CGPoint(x: grid.minX, y: origin.y + offset))
            gridLines.line(to: CGPoint(x: grid.maxX, y: origin.y + offset))
        }
        NSColor.black.withAlphaComponent(0.2).setStroke()
        gridLines.lineWidth = 0.5
        gridLines.stroke()
        let center = CGRect(x: origin.x + cell * 4, y: origin.y + cell * 4, width: cell, height: cell)
        NSColor.black.setStroke()
        let outer = NSBezierPath(rect: center.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 3
        outer.stroke()
        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: center.insetBy(dx: -1, dy: -1))
        inner.lineWidth = 1
        inner.stroke()
        let color = sample.color, hsv = color.hsv, hsl = color.hsl
        let lines = [
            "X \(sample.coordinate.x)  Y \(sample.coordinate.y) px",
            "HEX \(color.hex)",
            "RGB \(color.red), \(color.green), \(color.blue)",
            String(format: "HSV %.0f° %.0f%% %.0f%%", hsv.hue, hsv.saturation * 100, hsv.value * 100),
            String(format: "HSL %.0f° %.0f%% %.0f%%", hsl.hue, hsl.saturation * 100, hsl.lightness * 100)
        ]
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                                                       .foregroundColor: NSColor.labelColor]
        for (index, text) in lines.enumerated() {
            (text as NSString).draw(at: CGPoint(x: 101, y: 10 + CGFloat(index) * 17), withAttributes: attributes)
        }
        ("sRGB · C copies HEX · Tab hides HUD" as NSString).draw(at: CGPoint(x: 10, y: 100), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor
        ])
    }
}
