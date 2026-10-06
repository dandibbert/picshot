import XCTest
import AppKit
@testable import PicShot

@MainActor final class CapturePresetsElementsSmokeTests: XCTestCase {
    func testNativeElementsAndPresetManagerKeepFrozenPixelsAndNoPermissionPrompts() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Requires native WindowServer; never requests capture/AX permission") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Elements-Smoke-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await CapturePresetsElementsSmokeFixture.verify(evidenceDirectory: directory)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["screenCaptureStarted"] as? Bool, false)
        XCTAssertEqual(report["permissionRequested"] as? Bool, false)
        XCTAssertNotNil(report["realOwnApplicationAX"])
        let pixels = try XCTUnwrap(report["fakeProvider"] as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(pixels["frozenPixelsChecked"] as? Int), 10_000)
    }

    func testSavedIntegralPixelsDoNotGetAnExtraEdgeAtFractionalDensity() throws {
        let source = try CapturePresetsElementsSmokeFixture.coordinateImage(width: 300, height: 240)
        let pixels = CGRect(x: 7, y: 11, width: 65, height: 37)
        let capture = try CapturedImage.frozenPixelRegion(image: source, displayID: 99,
            displayFrame: CGRect(x: -400, y: 120, width: 200, height: 160), pixelFrame: pixels)
        XCTAssertEqual(capture.image.width, 65); XCTAssertEqual(capture.image.height, 37)
        XCTAssertEqual(capture.presentation?.selectionFrame.minX ?? 0, 7 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(capture.presentation?.selectionFrame.minY ?? 0, 128, accuracy: 1e-9)
        for invalid in [CGRect(x: 0.5, y: 0, width: 20, height: 20), CGRect(x: -1, y: 0, width: 20, height: 20),
                        CGRect(x: 290, y: 0, width: 20, height: 20)] {
            XCTAssertThrowsError(try CapturedImage.frozenPixelRegion(image: source, displayID: 99,
                displayFrame: CGRect(x: 0, y: 0, width: 200, height: 160), pixelFrame: invalid))
        }
    }

    func testEvidenceCompositesTitledManagerOverEffectiveNativeBackground() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor
        defer { window.close() }
        let source = try transparentEvidenceSource()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            let output = try CapturePresetsElementsSmokeFixture.evidenceImage(source, for: window)
            XCTAssertFalse(output === source)
            var expected: NSColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                expected = window.backgroundColor.usingColorSpace(.sRGB)
            }
            let color = try XCTUnwrap(expected), bytes = try rgbaBytes(output)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                XCTAssertLessThanOrEqual(abs(Int(bytes[offset]) - Int((color.redComponent * 255).rounded())), 1)
                XCTAssertLessThanOrEqual(abs(Int(bytes[offset + 1]) - Int((color.greenComponent * 255).rounded())), 1)
                XCTAssertLessThanOrEqual(abs(Int(bytes[offset + 2]) - Int((color.blueComponent * 255).rounded())), 1)
                XCTAssertEqual(bytes[offset + 3], 255)
            }
        }
    }

    func testEvidencePreservesIntentionalBorderlessOverlayTransparency() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        defer { window.close() }
        let source = try transparentEvidenceSource()
        let output = try CapturePresetsElementsSmokeFixture.evidenceImage(source, for: window)
        XCTAssertTrue(output === source)
        XCTAssertEqual(try rgbaBytes(output), [UInt8](repeating: 0, count: 16))
    }

    private func transparentEvidenceSource() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

}
