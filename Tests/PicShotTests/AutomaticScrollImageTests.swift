import XCTest
import AppKit
@testable import PicShot
@testable import PicShotCore

final class AutomaticScrollImageTests: XCTestCase {
    private func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testPreviewContainsEarlierFramesAndOnlyNewStripsOnBothAxes() throws {
        for axis in ScrollAxis.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let firstURL = directory.appendingPathComponent("first.png")
            let secondURL = directory.appendingPathComponent("second.png")
            try ScrollImageIO.writePNG(solidImage(width: 100, height: 100, red: 1, green: 0), to: firstURL)
            try ScrollImageIO.writePNG(solidImage(width: 100, height: 100, red: 0, green: 1), to: secondURL)
            let frames = [
                StoredScrollFrame(url: firstURL, placement: ScrollPlacement(x: 0, y: 0, advance: 0, overlap: 100, confidence: 1), width: 100, height: 100),
                StoredScrollFrame(url: secondURL, placement: ScrollPlacement(x: axis == .horizontal ? 40 : 0,
                    y: axis == .vertical ? 40 : 0, advance: 40, overlap: 60, confidence: 1), width: 100, height: 100)
            ]
            let width = axis == .vertical ? 100 : 140
            let height = axis == .vertical ? 140 : 100
            let preview = try ScrollImageIO.compositeThumbnail(frames, width: width, height: height, axis: axis)
            let full = try ScrollImageIO.render(frames, width: width, height: height, axis: axis)
            XCTAssertEqual(preview.width, width); XCTAssertEqual(preview.height, height)
            let pixels = try bytes(preview)
            XCTAssertEqual(pixels, try bytes(full), "At 1:1 the composite thumbnail and export must agree")
            var redPixels = 0, greenPixels = 0
            for p in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[p] > 250 && pixels[p + 1] < 5 { redPixels += 1 }
                if pixels[p] < 5 && pixels[p + 1] > 250 { greenPixels += 1 }
            }
            XCTAssertEqual(redPixels, 10_000)
            XCTAssertEqual(greenPixels, 4_000)
        }
    }

    func testLongCompositePreviewHasBoundedPixelMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("frame.png")
        try ScrollImageIO.writePNG(solidImage(width: 400, height: 600, red: 1, green: 0), to: url)
        let frames = (0..<100).map { index in
            StoredScrollFrame(url: url, placement: ScrollPlacement(x: 0, y: index * 300,
                advance: index == 0 ? 0 : 300, overlap: index == 0 ? 600 : 300, confidence: 1), width: 400, height: 600)
        }
        let preview = try ScrollImageIO.compositeThumbnail(frames, width: 400, height: 30_300, axis: .vertical)
        XCTAssertEqual(preview.height, 800)
        XCTAssertLessThanOrEqual(preview.width, 800)
        XCTAssertLessThanOrEqual(preview.width * preview.height, 640_000)
    }

    @MainActor
    func testScrollEventConstructionIsBoundedAndAxisSpecificWithoutPosting() throws {
        let point = CGPoint(x: -300, y: 241)
        let vertical = try AutomaticScrollScreenDriver.makeScrollEvent(axis: .vertical, points: 47, location: point)
        let horizontal = try AutomaticScrollScreenDriver.makeScrollEvent(axis: .horizontal, points: 53, location: point)
        XCTAssertEqual(vertical.type, .scrollWheel)
        XCTAssertEqual(vertical.location, point)
        XCTAssertEqual(vertical.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -47)
        XCTAssertEqual(vertical.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
        XCTAssertEqual(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertEqual(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -53)
        XCTAssertTrue(vertical.flags.isEmpty)
        for amount in [Int.min, -1, 0, 241, Int.max] {
            XCTAssertThrowsError(try AutomaticScrollScreenDriver.makeScrollEvent(axis: .vertical, points: amount, location: point))
        }
        XCTAssertThrowsError(try AutomaticScrollScreenDriver.makeScrollEvent(axis: .vertical, points: 1,
                                                                             location: CGPoint(x: CGFloat.nan, y: 0)))
        // Intentionally no event.post, app activation, screen read or permission request.
    }

    @MainActor
    func testTargetPolicyLocksForegroundPIDWindowBoundsAndPointWithoutPosting() throws {
        let point = CGPoint(x: -300, y: 241)
        let target = AutomaticScrollScreenDriver.Target(pid: 100, windowID: 4242,
                                                        bounds: CGRect(x: -500, y: 100, width: 400, height: 400))
        let first = try AutomaticScrollScreenDriver.checkedTarget(target, locked: nil, at: point,
                                                                  frontmostPID: 100, ownPID: 999)
        XCTAssertEqual(first, target)
        XCTAssertEqual(try AutomaticScrollScreenDriver.checkedTarget(target, locked: first, at: point,
                                                                     frontmostPID: 100, ownPID: 999), target)
        XCTAssertThrowsError(try AutomaticScrollScreenDriver.checkedTarget(nil, locked: target, at: point,
                                                                           frontmostPID: 100, ownPID: 999))
        XCTAssertThrowsError(try AutomaticScrollScreenDriver.checkedTarget(target, locked: target, at: point,
                                                                           frontmostPID: 200, ownPID: 999))
        XCTAssertThrowsError(try AutomaticScrollScreenDriver.checkedTarget(target, locked: target, at: point,
                                                                           frontmostPID: nil, ownPID: 999))
        XCTAssertThrowsError(try AutomaticScrollScreenDriver.checkedTarget(target, locked: target, at: point,
                                                                           frontmostPID: 100, ownPID: 100))
        XCTAssertThrowsError(try AutomaticScrollScreenDriver.checkedTarget(target, locked: target, at: .zero,
                                                                           frontmostPID: 100, ownPID: 999))
        let changedTargets = [
            AutomaticScrollScreenDriver.Target(pid: 200, windowID: 4242, bounds: target.bounds),
            AutomaticScrollScreenDriver.Target(pid: 100, windowID: 4243, bounds: target.bounds),
            AutomaticScrollScreenDriver.Target(pid: 100, windowID: 4242,
                                               bounds: target.bounds.offsetBy(dx: 1, dy: 0)),
            AutomaticScrollScreenDriver.Target(pid: 100, windowID: 0, bounds: target.bounds)
        ]
        for changed in changedTargets {
            XCTAssertThrowsError(try AutomaticScrollScreenDriver.checkedTarget(changed, locked: target, at: point,
                                                                               frontmostPID: changed.pid, ownPID: 999))
        }
        // Window identity is verified in the preflight policy. Do not infer a writable
        // scroll-window field or live application/view routing from CGEvent construction.
    }

}
