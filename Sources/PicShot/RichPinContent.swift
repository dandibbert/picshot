import AppKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

struct PreparedRichPin {
    let kind: PinContentKind
    let data: Data
    let fileExtension: String
    let poster: CGImage
    let width: Int
    let height: Int
    let frameCount: Int
    let title: String

    @MainActor init(document: PinRichDocument, title: String) throws {
        guard document.isValid else { throw RichPinError.invalidContent }
        let bytes = try JSONEncoder().encode(document)
        guard bytes.count <= PinRichAsset.maximumDocumentBytes else { throw RichPinError.tooLarge }
        kind = document.kind; data = bytes; fileExtension = "pinjson"
        width = 0; height = 0; frameCount = 0; self.title = title
        poster = try RichPinPoster.make(document)
    }
    init(animation data: Data, title: String) throws {
        let info = try RichPinAnimationInfo.inspect(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw RichPinError.invalidAnimation }
        kind = .animation; self.data = data; fileExtension = info.fileExtension; poster = image
        width = info.width; height = info.height; frameCount = info.frameCount; self.title = title
    }
    var asset: PinRichAsset {
        PinRichAsset(kind: kind, filename: UUID().uuidString + "." + fileExtension, byteCount: Int64(data.count), width: width, height: height, frameCount: frameCount)
    }
}

enum RichPinError: LocalizedError {
    case invalidContent, tooLarge, invalidAnimation, unavailableFile, unavailableSession
    var errorDescription: String? {
        switch self {
        case .invalidContent: return "无法读取此贴图内容。文字最多 256 KiB；文件贴图最多 64 个本机文件或文件夹引用。"
        case .tooLarge: return "内容超出保护上限。GIF/WebP 输入最多 16 MiB；静态图片最多 3200 万像素。动画最多 300 帧、单帧 400 万像素，全部帧合计最多 1.2 亿像素。"
        case .invalidAnimation: return "系统无法顺序解码此 GIF/WebP 动画，或动画帧尺寸不受支持。可导入静态图片；不会把首帧假装成动画。"
        case .unavailableFile: return "此文件引用已失效或无权访问。请重新选择文件；PicShot 不保存被引用文件的内容。"
        case .unavailableSession: return "多类型贴图需要可用的本机会话存储。请先解决贴图会话读取错误。"
        }
    }
}

struct RichPinAnimationInfo: Equatable {
    let width: Int
    let height: Int
    let frameCount: Int
    let fileExtension: String
    static func inspect(_ data: Data) throws -> RichPinAnimationInfo {
        guard !data.isEmpty, data.count <= PinRichAsset.maximumAnimationBytes else { throw RichPinError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, [UTType.gif.identifier, "org.webmproject.webp"].contains(type) else { throw RichPinError.invalidAnimation }
        let count = CGImageSourceGetCount(source)
        guard count >= 2 else { throw RichPinError.invalidAnimation }
        guard count <= PinRichAsset.maximumFrames else { throw RichPinError.tooLarge }
        guard let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = first[kCGImagePropertyPixelWidth] as? Int, let height = first[kCGImagePropertyPixelHeight] as? Int else { throw RichPinError.invalidAnimation }
        let ext = type == UTType.gif.identifier ? "gif" : "webp"
        let descriptor = PinRichAsset(kind: .animation, filename: UUID().uuidString + "." + ext,
                                      byteCount: Int64(data.count), width: width, height: height, frameCount: count)
        guard descriptor.isValid else { throw RichPinError.tooLarge }
        // Header-only pass; decoding happens sequentially in the player, never into an array.
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= width, h <= height else { throw RichPinError.invalidAnimation }
        }
        return RichPinAnimationInfo(width: width, height: height, frameCount: count, fileExtension: ext)
    }
    static func delay(source: CGImageSource, index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        let value = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ??
            (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double) ??
            (webp?[kCGImagePropertyWebPDelayTime] as? Double) ?? 0.1
        return value.isFinite && value > 0 ? min(10, max(0.04, value)) : 0.1
    }
}

@MainActor enum RichPinPoster {
    static func make(_ document: PinRichDocument) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 480, height: 280, bitsPerComponent: 8, bytesPerRow: 480 * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RichPinError.invalidContent }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 480, height: 280)).fill()
        let heading: String
        if let color = document.color {
            NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha) / 255).setFill()
            NSBezierPath(rect: NSRect(x: 24, y: 100, width: 432, height: 156)).fill()
            heading = color.hex + "\n" + color.rgb
        } else if let files = document.files {
            heading = "文件引用 · \(files.count) 项\n" + files.prefix(6).map { ($0.isDirectory ? "▸ " : "• ") + $0.name }.joined(separator: "\n")
        } else { heading = String((document.text?.plainText ?? "").prefix(600)) }
        (heading as NSString).draw(in: NSRect(x: 24, y: 24, width: 432, height: document.color == nil ? 232 : 66),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
        guard let result = context.makeImage() else { throw RichPinError.invalidContent }
        return result
    }
}

/// No file contents or custom icons are read when creating or restoring file-reference pins.
@MainActor enum RichPinImport {
    private static func title(_ value: String) -> String {
        let safe = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "文件贴图" : String(safe.prefix(120))
    }
    static func files(_ urls: [URL]) throws -> PreparedRichPin {
        guard !urls.isEmpty, urls.count <= 64, urls.allSatisfy(\.isFileURL) else { throw RichPinError.invalidContent }
        var references: [PinFileReference] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            references.append(PinFileReference(path: url.standardizedFileURL.path, name: url.lastPathComponent, isDirectory: values?.isDirectory == true))
        }
        return try PreparedRichPin(document: PinRichDocument(files: references), title: urls.count == 1 ? title(urls[0].lastPathComponent) : "\(urls.count) 个文件")
    }
    static func boundedAnimationData(at url: URL) throws -> Data {
        guard url.isFileURL else { throw RichPinError.invalidContent }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= PinRichAsset.maximumAnimationBytes else { throw RichPinError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: PinRichAsset.maximumAnimationBytes + 1) ?? Data()
        guard data.count <= PinRichAsset.maximumAnimationBytes else { throw RichPinError.tooLarge }
        return data
    }
    static func animationFile(_ url: URL) throws -> PreparedRichPin {
        try PreparedRichPin(animation: boundedAnimationData(at: url), title: title(url.deletingPathExtension().lastPathComponent))
    }
}
