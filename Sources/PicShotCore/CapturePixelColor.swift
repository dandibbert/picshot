import Foundation

/// An sRGB pixel after conversion from the frozen display's color space. Hue is
/// measured in degrees; saturation, value and lightness are in the range 0...1.
public struct CapturePixelColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: Int, green: Int, blue: Int, alpha: Int = 255) {
        self.red = UInt8(clamping: red)
        self.green = UInt8(clamping: green)
        self.blue = UInt8(clamping: blue)
        self.alpha = UInt8(clamping: alpha)
    }

    public var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }

    public var hsv: (hue: Double, saturation: Double, value: Double) {
        let components = normalizedComponents
        return (components.hue, components.maximum == 0 ? 0 : components.delta / components.maximum,
                components.maximum)
    }

    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let components = normalizedComponents
        let lightness = (components.maximum + components.minimum) / 2
        let saturation = components.delta == 0 ? 0 : components.delta / (1 - abs(2 * lightness - 1))
        return (components.hue, saturation, lightness)
    }

    private var normalizedComponents: (maximum: Double, minimum: Double, delta: Double, hue: Double) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maximum = max(r, max(g, b)), minimum = min(r, min(g, b)), delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        return (maximum, minimum, delta, hue)
    }
}

public struct CapturePixelCoordinate: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}
