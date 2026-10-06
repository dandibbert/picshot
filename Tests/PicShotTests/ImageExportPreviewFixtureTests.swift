import XCTest
import AppKit
import ImageIO
@testable import PicShot

@MainActor
final class ImageExportPreviewFixtureTests: XCTestCase {
    func testRepeatedEarlyFixtureHasOpaqueBackgroundAndReleasedVisualSessions() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.frame.width >= 620, screen.frame.height >= 600 else {
            throw XCTSkip("Native export screenshots require a WindowServer display of at least 620 by 600 points")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-preview-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<2 {
            let report = try await ImageExportPreviewFixture.verify(evidenceDirectory: directory, includeResourceCycles: false)
            XCTAssertEqual(report["status"] as? String, "passed")
            XCTAssertEqual(report["visualControllersClosed"] as? Bool, true)
            XCTAssertEqual(report["visualControllersReleasedBeforeResource"] as? Bool, true)
            XCTAssertEqual(report["visualTemporaryWorkspaceRemoved"] as? Bool, true)
            XCTAssertEqual(report["queuedJobsBeforeResource"] as? Int, 0)
            XCTAssertEqual(report["snapshotPixelsPerPoint"] as? Int, 1)
            for key in ["jpegWindowLayout", "pdfWindowLayout", "compactWindowLayout"] {
                let layout = try XCTUnwrap(report[key] as? [String: Any])
                XCTAssertEqual(layout["allControlsWithinVisibleFrame"] as? Bool, true)
                XCTAssertEqual(layout["previewAspectRatioPreserved"] as? Bool, true)
                XCTAssertEqual(layout["imageIntrinsicSizeIgnored"] as? Bool, true)
            }
            XCTAssertEqual((report["resourceObservation"] as? [String: Any])?["status"] as? String, "skipped")
        }
        for name in ["ui-export-jpeg-preview.png", "ui-export-pdf-page-2.png", "ui-export-small-desktop.png"] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertGreaterThan(image.width, 0); XCTAssertGreaterThan(image.height, 0)
            XCTAssertLessThanOrEqual(image.width, 620); XCTAssertLessThanOrEqual(image.height, 550)
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let corner = (2 * image.width + 2) * 4
            XCTAssertEqual(bytes[corner + 3], 255, "Titled-window background must not be transparent")
            XCTAssertGreaterThan(bytes[corner], 180, "Aqua window background must not become black")
        }
    }
}
