import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import JavaScriptCore
import CryptoKit
import PicShotFormulaRenderCore

enum FormulaRenderEngine {
    /// The JavaScript context has no Objective-C bridge, filesystem, DOM, network or timers.
    /// Only immutable request JSON enters the renderer; LaTeX is never evaluated as script.
    static func render(_ request: FormulaRenderRequest, runtimeDirectory: URL? = nil) throws -> FormulaRenderResult {
        try request.validate()
        let directory = try runtimeDirectory ?? FormulaRenderResources.directory()
        let source = try runtime(in: directory)
        guard let context = JSContext() else { throw FormulaRenderError.missingRuntime }
        var exception = false
        context.exceptionHandler = { _, _ in exception = true }
        context.evaluateScript(source)
        guard !exception, let function = context.objectForKeyedSubscript("FormulaRenderRuntime")?.objectForKeyedSubscript("render"),
              !function.isUndefined else { throw FormulaRenderError.missingRuntime }
        let dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        guard let json = function.call(withArguments: [dictionary])?.toString(), !exception,
              json.utf8.count <= FormulaRenderLimits.resultBytes else { throw FormulaRenderError.invalidOutput }
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        guard response.ok else {
            switch response.error {
            case "unsafeInput": throw FormulaRenderError.unsupported("不能使用网页链接、外部资源或自定义宏")
            case "unsupportedGlyph": throw FormulaRenderError.unsupported("此字形不在内置数学字体中")
            case "limit", "empty", "unsafeOutput": throw FormulaRenderError.invalidOutput
            default: throw FormulaRenderError.syntax
            }
        }
        guard let svg = response.svg, let mathML = response.mathML, let items = response.items,
              let viewBox = response.viewBox, let fontSize = response.fontSize, let padding = response.padding,
              let width = response.width, let height = response.height,
              let pointWidth = response.pointWidth, let pointHeight = response.pointHeight,
              viewBox.count == 4, viewBox.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              viewBox[2] > 0, viewBox[3] > 0, fontSize == request.fontSize, padding == 8,
              items.count > 0, items.count <= FormulaRenderLimits.drawingItems,
              width > 0, height > 0, width <= FormulaRenderLimits.dimension, height <= FormulaRenderLimits.dimension,
              width <= FormulaRenderLimits.pixels / height,
              pointWidth.isFinite, pointHeight.isFinite, pointWidth > 0, pointHeight > 0,
              abs(pointWidth - (viewBox[2] * fontSize / 1000 + 16)) < 0.00001,
              abs(pointHeight - (viewBox[3] * fontSize / 1000 + 16)) < 0.00001,
              width == Int(ceil(pointWidth * Double(request.scale))), height == Int(ceil(pointHeight * Double(request.scale)))
        else { throw FormulaRenderError.invalidOutput }
        let drawing = try prepare(items)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FormulaRenderError.invalidOutput }
        bitmap.scaleBy(x: CGFloat(request.scale), y: CGFloat(request.scale))
        draw(drawing, context: bitmap, pointWidth: pointWidth, pointHeight: pointHeight,
             viewBox: viewBox, fontSize: fontSize, transparent: request.transparent)
        guard let image = bitmap.makeImage() else { throw FormulaRenderError.invalidOutput }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw FormulaRenderError.invalidOutput }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FormulaRenderError.invalidOutput }
        let pdf = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight)
        guard let consumer = CGDataConsumer(data: pdf), let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw FormulaRenderError.invalidOutput }
        pdfContext.beginPDFPage(nil)
        draw(drawing, context: pdfContext, pointWidth: pointWidth, pointHeight: pointHeight,
             viewBox: viewBox, fontSize: fontSize, transparent: request.transparent)
        pdfContext.endPDFPage(); pdfContext.closePDF()
        let result = FormulaRenderResult(latex: request.latex, svg: svg, mathML: mathML,
                                         png: png as Data, pdf: pdf as Data, width: width, height: height,
                                         pointWidth: pointWidth, pointHeight: pointHeight)
        try result.validate(for: request)
        return result
    }

    private static func runtime(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("FormulaRenderRuntime.js")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 2_097_152 else { throw FormulaRenderError.missingRuntime }
        let data = try Data(contentsOf: url)
        let digestURL = directory.appendingPathComponent("FormulaRenderRuntime.sha256")
        let digestValues = try digestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard digestValues.isRegularFile == true, digestValues.isSymbolicLink != true,
              let digestSize = digestValues.fileSize, (64...128).contains(digestSize) else { throw FormulaRenderError.missingRuntime }
        let expected = try String(contentsOf: digestURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard expected.count == 64, actual == expected, let source = String(data: data, encoding: .utf8) else { throw FormulaRenderError.missingRuntime }
        return source
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let svg: String?, mathML: String?
        let items: [Item]?, viewBox: [Double]?
        let fontSize: Double?, padding: Double?, pointWidth: Double?, pointHeight: Double?
        let width: Int?, height: Int?
    }
    private struct Item: Decodable {
        let kind: String, matrix: [Double]
        let path: String?
        let fill: Bool, strokeWidth: Double, clips: [Clip]
        let x: Double?, y: Double?, width: Double?, height: Double?
    }
    private struct Clip: Decodable {
        let matrix: [Double]
        let x: Double, y: Double, width: Double, height: Double
    }
    private struct Drawing {
        let path: CGPath, transform: CGAffineTransform, fill: Bool, strokeWidth: Double, clips: [CGPath]
    }
    private static func transform(_ m: [Double]) throws -> CGAffineTransform {
        guard m.count == 6, m.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw FormulaRenderError.invalidOutput }
        return CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
    }
    private static func prepare(_ items: [Item]) throws -> [Drawing] {
        var budget = FormulaRenderLimits.pathSegments
        return try items.map { item in
            let matrix = try transform(item.matrix)
            guard item.strokeWidth.isFinite, (0...10_000).contains(item.strokeWidth), item.clips.count <= 8 else { throw FormulaRenderError.invalidOutput }
            let clips: [CGPath] = try item.clips.map { clip in
                guard [clip.x, clip.y, clip.width, clip.height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                      clip.width > 0, clip.height > 0 else { throw FormulaRenderError.invalidOutput }
                var t = try transform(clip.matrix)
                return CGPath(rect: CGRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height), transform: &t)
            }
            if item.kind == "path", let source = item.path {
                return Drawing(path: try FormulaRenderSVGPath.parse(source, segmentBudget: &budget), transform: matrix,
                               fill: item.fill, strokeWidth: item.strokeWidth, clips: clips)
            }
            guard let x = item.x, let y = item.y, let width = item.width, let height = item.height,
                  [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw FormulaRenderError.invalidOutput }
            let path = CGMutablePath()
            if item.kind == "rect", width >= 0, height >= 0 {
                path.addRect(CGRect(x: x, y: y, width: width, height: height))
                return Drawing(path: path, transform: matrix, fill: item.fill, strokeWidth: item.strokeWidth, clips: clips)
            }
            if item.kind == "line" {
                path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: width, y: height))
                return Drawing(path: path, transform: matrix, fill: false, strokeWidth: item.strokeWidth, clips: clips)
            }
            throw FormulaRenderError.invalidOutput
        }
    }
    private static func draw(_ drawing: [Drawing], context: CGContext, pointWidth: Double, pointHeight: Double,
                             viewBox: [Double], fontSize: Double, transparent: Bool) {
        context.saveGState(); defer { context.restoreGState() }
        if !transparent {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight))
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.translateBy(x: 0, y: pointHeight); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 8, y: 8); context.scaleBy(x: fontSize / 1000, y: fontSize / 1000)
        context.translateBy(x: -viewBox[0], y: -viewBox[1])
        for item in drawing {
            context.saveGState()
            for clip in item.clips { context.addPath(clip); context.clip() }
            context.concatenate(item.transform); context.addPath(item.path)
            if item.strokeWidth > 0 {
                context.setLineWidth(item.strokeWidth); context.drawPath(using: item.fill ? .fillStroke : .stroke)
            } else if item.fill { context.fillPath() }
            else { context.beginPath() }
            context.restoreGState()
        }
    }
}
