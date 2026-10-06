import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Stable raw values keep the original PNG/JPEG/TIFF/PDF export API compatible.
enum ImageExportFormat: Int, CaseIterable, Hashable {
    case png, jpeg, tiff, pdf, bmp, webp, avif
    var title: String { ["PNG", "JPEG", "TIFF", "PDF", "BMP", "WebP", "AVIF"][rawValue] }
    var contentType: UTType {
        if self == .webp { return UTType(filenameExtension: "webp") ?? UTType(exportedAs: "org.webmproject.webp", conformingTo: .image) }
        if self == .avif { return UTType(filenameExtension: "avif") ?? UTType(exportedAs: "public.avif", conformingTo: .image) }
        return [.png, .jpeg, .tiff, .pdf, .bmp][rawValue]
    }
    var filenameExtension: String { ["png", "jpg", "tiff", "pdf", "bmp", "webp", "avif"][rawValue] }
    var usesBundledCodec: Bool { self == .webp || self == .avif }
    static var nativeFormats: [Self] { allCases.filter { !$0.usesBundledCodec } }
    var preservesAlpha: Bool { self == .png || self == .tiff || usesBundledCodec }
}

enum ImageExportPaper: Int, CaseIterable, Hashable {
    case image, a4, letter
    var title: String { ["原图单页", "A4", "Letter"][rawValue] }
    var size: CGSize? {
        switch self {
        case .image: return nil
        case .a4: return CGSize(width: 595.2755905512, height: 841.8897637795)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }
}
enum ImageExportOrientation: Int, CaseIterable, Hashable { case portrait, landscape }
enum ImageExportPagination: Int, CaseIterable, Hashable { case vertical, horizontal }

struct ImageExportOptions: Hashable {
    var format: ImageExportFormat = .png
    var quality: Double = 0.94
    var lossless: Bool = false
    var preserveAlpha: Bool = true
    var alphaQuality: Double = 1
    var retainsAlpha: Bool { format.preservesAlpha && (!format.usesBundledCodec || preserveAlpha) }
    var paper: ImageExportPaper = .image
    var orientation: ImageExportOrientation = .portrait
    /// Equal margins in PDF points (72 points/inch), never source pixels.
    var margin: Double = 24
    var pagination: ImageExportPagination = .vertical

    func validate() throws {
        guard quality.isFinite, (0...1).contains(quality), alphaQuality.isFinite, (0...1).contains(alphaQuality), margin.isFinite, (0...144).contains(margin) else {
            throw ImageExportError.invalidOptions
        }
    }
}

struct ImageExportLimits {
    var maximumSourcePixels = 100_000_000
    var maximumEncodedBytes = 128 * 1_024 * 1_024
    var maximumPages = 200
    var previewDimension = 1_024
    var maximumPreviewBytes = 4 * 1_024 * 1_024
    static let standard = ImageExportLimits()
    func validate() throws {
        guard maximumSourcePixels > 0, maximumSourcePixels <= Self.standard.maximumSourcePixels,
              maximumEncodedBytes > 0, maximumEncodedBytes <= Self.standard.maximumEncodedBytes,
              maximumPages > 0, maximumPages <= Self.standard.maximumPages,
              previewDimension > 0, previewDimension <= Self.standard.previewDimension,
              maximumPreviewBytes >= 4, maximumPreviewBytes <= Self.standard.maximumPreviewBytes else {
            throw ImageExportError.invalidOptions
        }
    }
}

enum ImageExportError: LocalizedError {
    case invalidOptions, sourceTooLarge, outputTooLarge, tooManyPages, unavailable(String), encodeFailed
    case invalidOutput, destinationExists, invalidDestination, writeFailed
    var errorDescription: String? {
        switch self {
        case .invalidOptions: return "导出参数无效，请检查质量、纸张和页边距。"
        case .sourceTooLarge: return "图片超过导出上限（1 亿像素），请先裁剪。"
        case .outputTooLarge: return "导出文件超过 128 MiB 上限，请降低质量或裁剪图片。"
        case .tooManyPages: return "PDF 超过 200 页上限，请调整纸张、分页方向或裁剪图片。"
        case .unavailable(let name): return "当前系统没有可用的 \(name) 编码器。"
        case .encodeFailed: return "图片编码失败，尚未保存文件。"
        case .invalidOutput: return "导出文件校验失败，尚未保存文件。"
        case .destinationExists: return "该位置已有文件。为保护原图，请选择新文件名。"
        case .invalidDestination: return "导出路径或扩展名无效，请重新选择。"
        case .writeFailed: return "无法保存文件，请检查磁盘空间和文件夹权限。"
        }
    }
}

struct ImageExportPDFPage: Equatable {
    /// Integral source coordinates, top-left origin, matching CGImage.cropping.
    let source: CGRect
    /// PDF destination coordinates use a bottom-left origin.
    let destination: CGRect
}
struct ImageExportPDFLayout {
    let mediaBox: CGRect
    let pages: [ImageExportPDFPage]
    let scale: CGFloat

    static func make(width: Int, height: Int, options: ImageExportOptions,
                     limits: ImageExportLimits = .standard) throws -> Self {
        try options.validate(); try limits.validate()
        guard width > 0, height > 0, width <= limits.maximumSourcePixels / height else {
            throw ImageExportError.sourceTooLarge
        }
        guard var size = options.paper.size else {
            let box = CGRect(x: 0, y: 0, width: width, height: height)
            return Self(mediaBox: box, pages: [ImageExportPDFPage(source: box, destination: box)], scale: 1)
        }
        if options.orientation == .landscape { size = CGSize(width: size.height, height: size.width) }
        let margin = CGFloat(options.margin)
        let content = CGRect(x: margin, y: margin, width: size.width - 2 * margin, height: size.height - 2 * margin)
        guard content.width >= 1, content.height >= 1 else { throw ImageExportError.invalidOptions }
        let vertical = options.pagination == .vertical
        let scale = vertical ? content.width / CGFloat(width) : content.height / CGFloat(height)
        let capacity = Int(floor((vertical ? content.height : content.width) / scale))
        guard capacity >= 1 else { throw ImageExportError.invalidOptions }
        let total = vertical ? height : width
        let count = 1 + (total - 1) / capacity
        guard count <= limits.maximumPages else { throw ImageExportError.tooManyPages }
        var pages: [ImageExportPDFPage] = []
        // Advance in integer rows/columns. No floating-point rounding is ever
        // reused as a source boundary, including the last partial page.
        for start in stride(from: 0, to: total, by: capacity) {
            let length = min(capacity, total - start)
            let source = vertical ? CGRect(x: 0, y: start, width: width, height: length)
                                  : CGRect(x: start, y: 0, width: length, height: height)
            let destination = CGRect(x: margin, y: size.height - margin - source.height * scale,
                                     width: source.width * scale, height: source.height * scale)
            pages.append(ImageExportPDFPage(source: source, destination: destination))
        }
        return Self(mediaBox: CGRect(origin: .zero, size: size), pages: pages, scale: scale)
    }
}
