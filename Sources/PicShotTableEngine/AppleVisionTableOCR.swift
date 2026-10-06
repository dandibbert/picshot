#if canImport(CoreGraphics) && canImport(Vision)
import Foundation
import CoreGraphics
import Vision

extension SLANetPlus {
    /// Rasterizes the upright crop in sRGB, composites transparency on white, and converts to BGR.
    public static func preprocess(image: CGImage) throws -> SLANetInput {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= maximumImagePixels / height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw TableRecognitionError.invalidImage }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw TableRecognitionError.invalidImage }
        var bgr = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            bgr[pixel * 3] = rgba[pixel * 4 + 2]
            bgr[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            bgr[pixel * 3 + 2] = rgba[pixel * 4]
        }
        return try preprocess(width: width, height: height, bgrBytes: bgr)
    }
}

public enum VisionTableOCR {
    /// Synchronous, on-device OCR, intended for the one-shot helper process rather than the UI thread.
    /// Word bounds avoid assigning an entire line spanning several model cells to one cell.
    public static func recognize(image: CGImage) throws -> [TableOCRObservation] {
        guard image.width > 0, image.height > 0,
              image.width <= SLANetPlus.maximumImagePixels / image.height else { throw TableRecognitionError.invalidImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = Double(image.width), height = Double(image.height)
        func convert(_ box: CGRect) -> TableOCRBox {
            TableOCRBox(x: Double(box.minX) * width, y: (1 - Double(box.maxY)) * height,
                        width: Double(box.width) * width, height: Double(box.height) * height)
        }
        var result: [TableOCRObservation] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
            let string = candidate.string
            let ranges = string.rangesOfNonWhitespace()
            var words: [TableOCRObservation] = []
            for range in ranges {
                if let rectangle = try? candidate.boundingBox(for: range) {
                    words.append(TableOCRObservation(text: String(string[range]), confidence: Double(candidate.confidence), box: convert(rectangle.boundingBox)))
                }
            }
            // Never drop pieces of a line if Vision cannot produce an individual word's geometry.
            if words.count == ranges.count, !words.isEmpty { result.append(contentsOf: words) }
            else { result.append(TableOCRObservation(text: string, confidence: Double(candidate.confidence), box: convert(observation.boundingBox))) }
        }
        return result
    }
}

private extension String {
    func rangesOfNonWhitespace() -> [Range<String.Index>] {
        var result: [Range<String.Index>] = [], start: String.Index?
        var cursor = startIndex
        while cursor < endIndex {
            if self[cursor].isWhitespace {
                if let first = start { result.append(first..<cursor); start = nil }
            } else if start == nil { start = cursor }
            cursor = index(after: cursor)
        }
        if let first = start { result.append(first..<endIndex) }
        return result
    }
}
#endif
