import XCTest
import AppKit
import CoreText
import PicShotCore
@testable import PicShot

final class NumberedCalloutTests: XCTestCase {
    func testCommentAndLeaderHitRegionsExcludeEmptyBoundingBox() {
        var mark = ImageAnnotation(tool: .number, points: [CGPoint(x: 100, y: 100), CGPoint(x: 50, y: 220)], number: 7)
        mark.numberComment = "步骤七 · مرحبا · 👩🏽‍💻"; mark.numberCommentSize = CGSize(width: 200, height: 70)
        XCTAssertTrue(mark.hitTest(CGPoint(x: 100, y: 100), tolerance: 0))
        XCTAssertTrue(mark.hitTest(CGPoint(x: 200, y: 100), tolerance: 0))
        XCTAssertTrue(mark.hitTest(CGPoint(x: 75, y: 160), tolerance: 2))
        XCTAssertFalse(mark.hitTest(CGPoint(x: 300, y: 210), tolerance: 0))
        XCTAssertTrue(mark.localBounds.contains(mark.numberCommentRect))
        mark.rotation = .pi / 2
        XCTAssertTrue(mark.hitTest(CGPoint(x: 200, y: 100).applying(mark.transform), tolerance: 0))
        XCTAssertFalse(mark.hitTest(CGPoint(x: 300, y: 210).applying(mark.transform), tolerance: 0))
    }

    func testRotatedTipEditKeepsBadgeAndCommentFixedAndTranslationMovesEverything() {
        var mark = ImageAnnotation(tool: .number, points: [CGPoint(x: 100, y: 100), CGPoint(x: 40, y: 200)], number: 7)
        mark.numberComment = "Attached"; mark.rotation = .pi / 3
        let transform = mark.transform, comment = mark.numberCommentRect.applying(transform)
        let target = CGPoint(x: 75, y: 280)
        let edited = mark.edited(handle: .end, from: mark.points[1].applying(transform), to: target, shift: false)
        XCTAssertEqual(edited.points[0], mark.points[0]); XCTAssertEqual(edited.rotation, mark.rotation, accuracy: 0.0001)
        XCTAssertEqual(edited.numberCommentRect.applying(edited.transform), comment)
        XCTAssertEqual(edited.points[1].applying(edited.transform).x, target.x, accuracy: 0.0001)
        XCTAssertEqual(edited.points[1].applying(edited.transform).y, target.y, accuracy: 0.0001)
        let translated = edited.translated(by: CGSize(width: 13, height: -9))
        XCTAssertEqual(translated.bounds.minX, edited.bounds.minX + 13, accuracy: 0.0001)
        XCTAssertEqual(translated.bounds.minY, edited.bounds.minY - 9, accuracy: 0.0001)
    }

    func testSeparateBadgeAndCommentResizeAndMalformedLimits() {
        var mark = ImageAnnotation(tool: .number, points: [CGPoint(x: 100, y: 100)], number: Int.max)
        mark.numberComment = String(repeating: "界", count: 10_000)
        mark.lineWidth = .infinity; mark.rotation = .nan
        mark.numberCommentSize = CGSize(width: CGFloat.nan, height: CGFloat.infinity)
        mark = mark.sanitizedNumberCallout
        XCTAssertEqual(mark.number, 3999); XCTAssertEqual(mark.numberComment.utf16.count, 2048)
        XCTAssertEqual(mark.rotation, 0); XCTAssertEqual(mark.numberRadius, 16)
        XCTAssertEqual(mark.numberCommentSize, CGSize(width: 240, height: 80))
        let larger = mark.edited(handle: .numberSize, from: .zero, to: CGPoint(x: 1_000, y: 1_000), shift: false)
        XCTAssertEqual(larger.numberRadius, 80); XCTAssertEqual(larger.points.first, mark.points.first)
        let comment = larger.edited(handle: .numberCommentSize, from: .zero, to: CGPoint(x: 2_000, y: -2_000), shift: false)
        XCTAssertEqual(comment.numberCommentSize, CGSize(width: 600, height: 400))
        XCTAssertEqual(comment.numberRadius, 80)
    }

    func testLegacySingleDigitPixelsAndCommentClippingUseSameFlattenedRenderer() throws {
        let base = ImageEditorRenderer.makeSampleImage()
        let mark = ImageAnnotation(tool: .number, points: [CGPoint(x: 100, y: 100)], number: 7)
        let reference = try context(width: base.width, height: base.height)
        reference.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        reference.setFillColor(mark.color); reference.fillEllipse(in: mark.numberBadgeRect)
        let size = mark.numberBadgeRect.height * 0.58
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "7", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
        reference.textMatrix = .identity
        reference.textPosition = CGPoint(x: 100 - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: 100 - size * 0.37)
        CTLineDraw(line, reference)
        XCTAssertEqual(try bytes(XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: [mark]))), try bytes(XCTUnwrap(reference.makeImage())))
        var callout = mark; callout.numberStyle = .roman; callout.number = 3888
        callout.numberComment = String(repeating: "很长的说明 Long comment مرحبا 👩🏽‍💻\n", count: 300)
        callout.numberCommentSize = CGSize(width: 120, height: 60)
        let output = try XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: [callout]))
        let bounded = callout.sanitizedNumberCallout
        XCTAssertEqual(try bytes(output), try bytes(XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: [bounded]))))
        // The bounded label cannot paint outside its badge; long comment text stays in its box.
        let before = try bytes(base), after = try bytes(output)
        for y in 0..<base.height {
            let start = (y * base.width + 256) * 4, end = (y + 1) * base.width * 4
            XCTAssertEqual(before[start..<end], after[start..<end], "Comment escaped its horizontal clipping bound")
        }
    }

    func testOpaqueRedactionStillCoversNumberCommentAndLeader() throws {
        let base = ImageEditorRenderer.makeSampleImage()
        var mark = ImageAnnotation(tool: .number, points: [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 300)], number: 7)
        mark.numberComment = "private"; mark.opacity = 0.2
        var cover = ImageAnnotation(tool: .redact, points: [.zero, CGPoint(x: base.width, y: base.height)])
        cover.color = CGColor(gray: 0, alpha: 0.001); cover.opacity = 0.001
        let output = try bytes(XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: [mark, cover])))
        XCTAssertTrue(stride(from: 0, to: output.count, by: 4).allSatisfy {
            output[$0] == 0 && output[$0 + 1] == 0 && output[$0 + 2] == 0 && output[$0 + 3] == 255
        }, "Redaction leaked an underlying callout pixel")
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
    }
}
