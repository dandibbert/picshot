import XCTest
import AppKit
@testable import PicShot

@MainActor
final class ImageOutputDecorationPaletteTests: XCTestCase {
    func testApplyIsOneMetadataCommitAndCancelKeepsOriginal() async throws {
        _ = NSApplication.shared
        let image = try fixture(), originalProvider = image.dataProvider
        var commits: [ImageOutputDecoration] = [], dismissals = 0
        let palette = ImageOutputDecorationPalette(flattened: image, decoration: .none,
            onApply: { commits.append($0) }, onDismiss: { dismissals += 1 })
        defer { palette.cancel() }
        try await until { !palette.hasPendingPreview }
        let enable: NSButton = try control("decoration.enabled", in: palette)
        let radius: NSTextField = try control("decoration.radius", in: palette)
        enable.state = .on; send(enable); radius.stringValue = "18"; send(radius)
        try await until { !palette.hasPendingPreview }
        let apply: NSButton = try control("decoration.apply", in: palette)
        XCTAssertTrue(apply.isEnabled); XCTAssertNotNil(palette.displayedPreview)
        XCTAssertTrue(commits.isEmpty, "Preview must never write source/model history")
        send(apply); send(apply)
        XCTAssertEqual(commits.count, 1); XCTAssertEqual(commits.first?.cornerRadius, 18)
        XCTAssertEqual(dismissals, 1); XCTAssertNil(palette.displayedPreview)
        XCTAssertEqual(palette.estimatedAdditionalRasterBytes, 0)
        XCTAssertTrue(image.dataProvider === originalProvider)

        let next = ImageOutputDecorationPalette(flattened: image, decoration: commits[0], onApply: { commits.append($0) })
        let nextRadius: NSTextField = try control("decoration.radius", in: next)
        nextRadius.stringValue = "3"; send(nextRadius); next.cancel()
        try await until { ImageOutputDecorationPalette.previewQueue.operationCount == 0 }
        XCTAssertEqual(commits.count, 1); XCTAssertNil(next.displayedPreview)
    }

    func testInvalidTypingBeforeThumbnailCompletesCanRecoverAndReset() async throws {
        _ = NSApplication.shared
        ImageOutputDecorationPalette.previewQueue.isSuspended = true
        let palette = ImageOutputDecorationPalette(flattened: try fixture(), decoration: .init(enabled: true), onApply: { _ in })
        defer { ImageOutputDecorationPalette.previewQueue.isSuspended = false; palette.cancel() }
        let radius: NSTextField = try control("decoration.radius", in: palette)
        radius.stringValue = "-"; send(radius)
        XCTAssertTrue(palette.hasPendingPreview, "Incomplete typing must not discard initial thumbnail ownership")
        ImageOutputDecorationPalette.previewQueue.isSuspended = false
        try await until { !palette.hasPendingPreview }
        let apply: NSButton = try control("decoration.apply", in: palette)
        XCTAssertFalse(apply.isEnabled)
        radius.stringValue = "9"; send(radius)
        try await until { !palette.hasPendingPreview }
        XCTAssertTrue(apply.isEnabled)
        let reset: NSButton = try control("decoration.reset", in: palette)
        send(reset); try await until { !palette.hasPendingPreview }
        let enable: NSButton = try control("decoration.enabled", in: palette)
        XCTAssertEqual(enable.state, .off)
    }

    func testCancelledPendingAndAlreadyQueuedCompletionsCannotRepopulatePreview() async throws {
        _ = NSApplication.shared
        for _ in 0..<8 {
            var commits = 0, dismissals = 0
            let palette = ImageOutputDecorationPalette(flattened: try fixture(), decoration: .init(enabled: true, cornerRadius: 12),
                onApply: { _ in commits += 1 }, onDismiss: { dismissals += 1 })
            // The bounded worker finishes while this actor still owns execution,
            // so its main-queue callback is necessarily waiting behind cancel().
            ImageOutputDecorationPalette.previewQueue.waitUntilAllOperationsAreFinished()
            palette.cancel(); palette.cancel()
            await Task.yield()
            XCTAssertNil(palette.displayedPreview); XCTAssertFalse(palette.hasPendingPreview)
            XCTAssertEqual(commits, 0); XCTAssertEqual(dismissals, 1)
        }
    }

    func testPopoverStaysCompactAndContainsSignedOffsetsAndExplicitOutputDimensions() async throws {
        _ = NSApplication.shared
        let palette = ImageOutputDecorationPalette(flattened: try fixture(),
            decoration: .init(enabled: true, shadowEnabled: true, shadowOffsetX: -9, shadowOffsetY: -4), onApply: { _ in })
        defer { palette.cancel() }
        try await until { !palette.hasPendingPreview }
        let view = try XCTUnwrap(palette.contentView)
        XCTAssertLessThanOrEqual(view.frame.width, 360); XCTAssertLessThanOrEqual(view.frame.height, 380)
        let x: NSTextField = try control("decoration.offsetX", in: palette)
        let y: NSTextField = try control("decoration.offsetY", in: palette)
        XCTAssertEqual(Double(x.stringValue), -9); XCTAssertEqual(Double(y.stringValue), -4)
        let dimensions: NSTextField = try control("decoration.dimensions", in: palette)
        XCTAssertTrue(dimensions.stringValue.contains("原图")); XCTAssertTrue(dimensions.stringValue.contains("输出"))
        XCTAssertTrue(dimensions.stringValue.contains("96 × 64"))
    }

    private func send(_ control: NSControl) {
        guard let action = control.action else { XCTFail("Missing control action"); return }
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control))
    }
    private func control<T: NSView>(_ id: String, in palette: ImageOutputDecorationPalette) throws -> T {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            for child in view.subviews { if let result = find(child) { return result } }
            return nil
        }
        return try XCTUnwrap(find(try XCTUnwrap(palette.contentView)) as? T)
    }
    private func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Bounded native preview did not settle")
    }
    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 96 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        return try XCTUnwrap(context.makeImage())
    }
}
