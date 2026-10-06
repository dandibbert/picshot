import Foundation
import CoreGraphics
import PicShotFormulaCore

/// RGB, a direct 384x384 bicubic resize (no center crop or aspect-ratio padding),
/// then (pixel / 255 - 0.5) / 0.5 in NCHW order. Transparent pixels become white.
enum FormulaImagePreprocessor {
    static func tensor(_ image: CGImage) throws -> [Float] {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= MLJobLimits.inputDimension,
              height <= MLJobLimits.inputDimension, width * height <= MLJobLimits.inputPixels,
              let color = CGColorSpace(name: CGColorSpace.sRGB) else { throw FormulaError.invalidInput }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw FormulaError.invalidInput }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return resizeRGB(rgba: rgba, width: width, height: height)
    }

    static func resizeRGB(rgba: [UInt8], width: Int, height: Int) -> [Float] {
        let size = 384
        let horizontal = coefficients(input: width, output: size)
        let vertical = coefficients(input: height, output: size)
        var temporary = [UInt8](repeating: 0, count: height * size * 3)
        for y in 0..<height {
            for x in 0..<size {
                for c in 0..<3 {
                    var sum = 0.0
                    for (source, weight) in horizontal[x] { sum += Double(rgba[(y * width + source) * 4 + c]) * weight }
                    temporary[(y * size + x) * 3 + c] = UInt8(max(0, min(255, Int(sum.rounded()))))
                }
            }
        }
        var output = [Float](repeating: 0, count: 3 * size * size)
        for y in 0..<size {
            for x in 0..<size {
                for c in 0..<3 {
                    var sum = 0.0
                    for (source, weight) in vertical[y] { sum += Double(temporary[(source * size + x) * 3 + c]) * weight }
                    let value = Float(max(0, min(255, Int(sum.rounded()))))
                    output[c * size * size + y * size + x] = (value / 255 - 0.5) / 0.5
                }
            }
        }
        return output
    }

    private static func coefficients(input: Int, output: Int) -> [[(Int, Double)]] {
        let scale = Double(input) / Double(output)
        let filterScale = max(1, scale)
        let support = 2 * filterScale
        return (0..<output).map { destination in
            let center = (Double(destination) + 0.5) * scale
            let first = max(0, Int(center - support + 0.5))
            let last = min(input, Int(center + support + 0.5))
            var weights: [(Int, Double)] = []
            var total = 0.0
            for source in first..<last {
                let x = abs((Double(source) - center + 0.5) / filterScale)
                let w: Double
                if x < 1 { w = ((1.5 * x - 2.5) * x) * x + 1 }
                else if x < 2 { w = ((-0.5 * x + 2.5) * x - 4) * x + 2 }
                else { w = 0 }
                weights.append((source, w)); total += w
            }
            return weights.map { ($0.0, $0.1 / total) }
        }
    }
}
