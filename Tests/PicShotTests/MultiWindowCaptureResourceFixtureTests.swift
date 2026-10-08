import XCTest
import CoreGraphics
import ImageIO
@testable import PicShot

/// The 16-cycle 4K acceptance workload belongs in the installed-app invocation,
/// not every unit-test run. This small test validates its weak ownership probe
/// assumptions with the same ImageIO source/cache settings and a real owned PNG.
final class MultiWindowCaptureResourceFixtureTests: XCTestCase {
    func testFreshImageIODecodeObjectsSupportReleaseObservation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Owned-Resource-Probe-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try autoreleasepool {
            let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let image = try XCTUnwrap(context.makeImage())
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let probe = ResourceFixtureWeakProbe()
        for _ in 0..<4 {
            try autoreleasepool {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
                probe.image = image; probe.source = source
                XCTAssertEqual(image.width, 16); XCTAssertNotNil(probe.image); XCTAssertNotNil(probe.source)
            }
            XCTAssertNil(probe.image, "An ImageIO CGImage remained retained after its owner scope")
            XCTAssertNil(probe.source, "An ImageIO source remained retained after its owner scope")
        }
    }
}
private final class ResourceFixtureWeakProbe {
    weak var image: CGImage?
    weak var source: CGImageSource?
}
