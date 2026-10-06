import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Read and write support are separate facts. This self-contained synthetic
/// probe performs no network access, codec install, file read or file write.
/// A successful result establishes only this runtime/configuration's encoder.
enum ImageExportCapabilityProbe {
    static func report() -> [String: Any] {
        let readers = CGImageSourceCopyTypeIdentifiers() as! [String]
        let writers = CGImageDestinationCopyTypeIdentifiers() as! [String]
        var result: [String: Any] = [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture, "probeVersion": 1,
            "scope": "Native ImageIO synthetic 8x8 encode, independent decode and pixel/alpha validation; not browser display support",
            "networkAttempted": false, "dependenciesInstalled": false,
            "destinationIdentifiers": writers.sorted()
        ]
        for (name, ext, fallback) in [("webp", "webp", "org.webmproject.webp"), ("avif", "avif", "public.avif")] {
            let identifier = UTType(filenameExtension: ext)?.identifier ?? fallback
            result[name] = probe(identifier: identifier, name: name, readers: readers, writers: writers)
        }
        return result
    }

    private static func probe(identifier: String, name: String, readers: [String], writers: [String]) -> [String: Any] {
        var report: [String: Any] = ["identifier": identifier, "readerListed": readers.contains(identifier),
                                   "writerListed": writers.contains(identifier), "canEncode": false, "alphaVerified": false]
        guard writers.contains(identifier) else { report["reason"] = "not-in-native-destination-list"; return report }
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            report["reason"] = "fixture-allocation-failed"; return report
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        guard let image = context.makeImage(), let originalStorage = context.data else { report["reason"] = "fixture-image-failed"; return report }
        // Compare reference and decoded pixels through the same bitmap layout,
        // avoiding assumptions about Quartz vs. raw-provider row origins.
        let reference = Data(bytes: originalStorage, count: 8 * 32)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, identifier as CFString, 1, nil) else {
            report["reason"] = "destination-creation-failed"; return report
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length < 1_048_576 else {
            report["reason"] = "finalize-or-byte-bound-failed"; return report
        }
        let bytes = data as Data
        let validMagic: Bool
        if name == "webp" {
            validMagic = bytes.count >= 12 && bytes.prefix(4) == Data("RIFF".utf8) && bytes[8..<12] == Data("WEBP".utf8)
        } else {
            validMagic = bytes.count >= 16 && bytes[4..<8] == Data("ftyp".utf8) &&
                (bytes.prefix(64).range(of: Data("avif".utf8)) != nil || bytes.prefix(64).range(of: Data("avis".utf8)) != nil)
        }
        guard validMagic, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetType(source) as String? == identifier, CGImageSourceGetCount(source) == 1,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              decoded.width == 8, decoded.height == 8 else { report["reason"] = "independent-decode-failed"; return report }
        context.clear(CGRect(x: 0, y: 0, width: 8, height: 8)); context.draw(decoded, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let storage = context.data?.assumingMemoryBound(to: UInt8.self) else { report["reason"] = "pixel-read-failed"; return report }
        var pixelsValid = true, alphaValid = true
        for offset in stride(from: 0, to: reference.count, by: 4) {
            if reference[offset + 3] == 255 {
                // Permit lossy chroma noise; opaque red must remain red.
                pixelsValid = pixelsValid && storage[offset] >= 180 && storage[offset + 1] <= 75 && storage[offset + 2] <= 75 && storage[offset + 3] >= 245
            } else { alphaValid = alphaValid && storage[offset + 3] <= 8 }
        }
        report["canEncode"] = pixelsValid; report["alphaVerified"] = pixelsValid && alphaValid
        report["encodedBytes"] = bytes.count; report["decodedWidth"] = decoded.width; report["decodedHeight"] = decoded.height
        report["reason"] = pixelsValid ? "real-native-encode-and-decode-passed" : "decoded-pixels-did-not-match"
        return report
    }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "other"
        #endif
    }
}
