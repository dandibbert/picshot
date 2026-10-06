import Foundation
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// Distinguishes a genuine still GIF/WebP from a multi-frame source before any
/// static decode. Container structure and ImageIO's frame count must agree.
enum RichPinClipboardImage {
    case still(CGImage)
    case animated(PreparedRichPin)

    static func prepare(_ data: Data) throws -> RichPinClipboardImage {
        guard !data.isEmpty, data.count <= PinRichAsset.maximumAnimationBytes else { throw RichPinError.tooLarge }
        let envelope = try RichPinContainerInfo.inspect(data)
        if let width = envelope.width, let height = envelope.height {
            guard PinImageRenderer.allowsRasterSize(width: width, height: height) else { throw RichPinError.tooLarge }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == envelope.typeIdentifier,
              CGImageSourceGetStatus(source) == .statusComplete else { throw RichPinError.invalidAnimation }
        let count = CGImageSourceGetCount(source)
        try envelope.validateDecodedFrameCount(count)
        if envelope.requiresAnimation {
            return .animated(try PreparedRichPin(animation: data, title: "动态贴图"))
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw RichPinError.invalidAnimation }
        guard PinImageRenderer.allowsRasterSize(width: width, height: height) else { throw RichPinError.tooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height else { throw RichPinError.invalidAnimation }
        return .still(image)
    }
}

struct RichPinContainerInfo {
    let typeIdentifier: String
    let frameCount: Int
    let requiresAnimation: Bool
    let width: Int?
    let height: Int?

    func validateDecodedFrameCount(_ count: Int) throws {
        // A decoder exposing only frame zero of a RIFF ANIM/ANMF file must never
        // turn an unsupported animation into an apparently supported still pin.
        guard count == frameCount, count > 0, !requiresAnimation || count >= 2 else { throw RichPinError.invalidAnimation }
        guard count <= PinRichAsset.maximumFrames else { throw RichPinError.tooLarge }
    }
    static func inspect(_ data: Data) throws -> RichPinContainerInfo {
        guard !data.isEmpty, data.count <= PinRichAsset.maximumAnimationBytes else { throw RichPinError.tooLarge }
        let bytes = [UInt8](data)
        if bytes.count >= 6, String(bytes: bytes[0..<6], encoding: .ascii).map({ ["GIF87a", "GIF89a"].contains($0) }) == true {
            return try gif(bytes)
        }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return try webp(bytes)
        }
        throw RichPinError.invalidAnimation
    }
    private static func gif(_ bytes: [UInt8]) throws -> RichPinContainerInfo {
        guard bytes.count >= 14 else { throw RichPinError.invalidAnimation }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        let width = u16(6), height = u16(8)
        guard width > 0, height > 0 else { throw RichPinError.invalidAnimation }
        var offset = 13, frames = 0
        func advance(_ count: Int) throws {
            guard count >= 0, count <= bytes.count - offset else { throw RichPinError.invalidAnimation }
            offset += count
        }
        func subblocks() throws {
            while true {
                guard offset < bytes.count else { throw RichPinError.invalidAnimation }
                let size = Int(bytes[offset]); offset += 1
                if size == 0 { return }
                try advance(size)
            }
        }
        if bytes[10] & 0x80 != 0 { try advance(3 * (1 << (Int(bytes[10] & 7) + 1))) }
        while offset < bytes.count {
            let marker = bytes[offset]; offset += 1
            switch marker {
            case 0x21:
                try advance(1) // Extension label, followed by bounded data subblocks.
                try subblocks()
            case 0x2C:
                guard bytes.count - offset >= 9 else { throw RichPinError.invalidAnimation }
                let x = u16(offset), y = u16(offset + 2), w = u16(offset + 4), h = u16(offset + 6), packed = bytes[offset + 8]
                guard w > 0, h > 0, x <= width - w, y <= height - h else { throw RichPinError.invalidAnimation }
                try advance(9)
                if packed & 0x80 != 0 { try advance(3 * (1 << (Int(packed & 7) + 1))) }
                guard offset < bytes.count, (2...8).contains(Int(bytes[offset])) else { throw RichPinError.invalidAnimation }
                offset += 1; try subblocks(); frames += 1
                guard frames <= PinRichAsset.maximumFrames else { throw RichPinError.tooLarge }
            case 0x3B:
                guard frames > 0, offset == bytes.count else { throw RichPinError.invalidAnimation }
                return RichPinContainerInfo(typeIdentifier: UTType.gif.identifier, frameCount: frames, requiresAnimation: frames > 1, width: width, height: height)
            default: throw RichPinError.invalidAnimation
            }
        }
        throw RichPinError.invalidAnimation // Missing trailer or truncated frame.
    }
    private static func webp(_ bytes: [UInt8]) throws -> RichPinContainerInfo {
        func u32(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24 }
        func u24(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 }
        guard u32(4) == bytes.count - 8 else { throw RichPinError.invalidAnimation }
        var offset = 12, frames = 0, stillImages = 0
        var width: Int?, height: Int?
        var extended = false, flag = false, animationHeader = false
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw RichPinError.invalidAnimation }
            let tag = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let length = u32(offset + 4); offset += 8
            guard length <= bytes.count - offset else { throw RichPinError.invalidAnimation }
            switch tag {
            case "VP8X":
                guard length == 10, !extended else { throw RichPinError.invalidAnimation }
                extended = true; flag = bytes[offset] & 2 != 0
                width = u24(offset + 4) + 1; height = u24(offset + 7) + 1
            case "ANIM":
                guard length == 6, !animationHeader else { throw RichPinError.invalidAnimation }
                animationHeader = true
            case "ANMF":
                guard length >= 16 else { throw RichPinError.invalidAnimation }
                frames += 1; guard frames <= PinRichAsset.maximumFrames else { throw RichPinError.tooLarge }
            case "VP8 ", "VP8L":
                guard length > 0 else { throw RichPinError.invalidAnimation }; stillImages += 1
            default: break // Bounded metadata chunks are ignored, never interpreted as URLs.
            }
            let padded = length + (length & 1)
            guard padded <= bytes.count - offset else { throw RichPinError.invalidAnimation }
            offset += padded
        }
        let animated = flag || animationHeader || frames > 0
        if animated {
            guard extended, flag, animationHeader, frames > 0, stillImages == 0 else { throw RichPinError.invalidAnimation }
        } else { guard stillImages == 1 else { throw RichPinError.invalidAnimation } }
        return RichPinContainerInfo(typeIdentifier: "org.webmproject.webp", frameCount: animated ? frames : 1,
                                    requiresAnimation: animated, width: width, height: height)
    }
}

/// Rich HTML is only a preferred representation when the offline subset contains
/// meaningful text. Image-only/unsupported HTML does not suppress other clipboard
/// representations; it is never handed to AppKit's network-capable HTML importer.
enum RichPinClipboardRouting {
    static func preferredHTMLText(_ html: String) -> PinTextContent? {
        guard let content = PinOfflineHTML.parse(html),
              !content.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return content
    }
}
