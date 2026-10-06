import AppKit
import ImageIO
import UniformTypeIdentifiers

extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
    func writePNG(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw PicShotError.message("无法创建图片文件") }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { throw PicShotError.message("图片写入失败，请检查磁盘空间") }
    }
    static func read(url: URL, maxDimension: Int? = nil) -> CGImage? {
        // Own compressed bytes: callers may delete temporary source files or
        // history retention may remove a file while its image is still displayed.
        guard let values=try? url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]),
              values.isRegularFile == true,let size=values.fileSize,size>0,size<=134_217_728,
              let data=try? Data(contentsOf:url),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: true] as CFDictionary) else { return nil }
        if let dimension = maxDimension {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: dimension, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        if let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int {
            guard width>0,height>0,width<=100_000_000/height else{return nil}
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

enum PicShotError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

@MainActor func showError(_ error: Error) {
    let alert = NSAlert(); alert.messageText = "PicShot"; alert.informativeText = error.localizedDescription; alert.alertStyle = .warning; alert.addButton(withTitle: "好"); alert.runModal()
}

@MainActor func copyImage(_ image: CGImage) {
    NSPasteboard.general.clearContents()
    let rep = NSBitmapImageRep(cgImage: image)
    if let data = rep.representation(using: .png, properties: [:]) { NSPasteboard.general.setData(data, forType: .png) }
}
