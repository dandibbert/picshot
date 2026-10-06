import XCTest
import AppKit
import CoreGraphics
import ImageIO
@testable import PicShot

final class ImageEditorTests: XCTestCase {
    func testSampleFixtureHasExpectedDimensions() {
        let image = ImageEditorRenderer.makeSampleImage()
        XCTAssertEqual(image.width, 960)
        XCTAssertEqual(image.height, 600)
        XCTAssertNotNil(image.dataProvider?.data)
    }

    func testEmptyRenderPreservesDimensionsAndPixels() throws {
        let original = try makeImage(width: 40, height: 30, color: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: []))
        XCTAssertEqual(rendered.width, 40)
        XCTAssertEqual(rendered.height, 30)
        XCTAssertEqual(try rgba(rendered, x: 20, y: 15), try rgba(original, x: 20, y: 15))
    }

    func testRedactionIsOpaqueEvenWhenChosenColorIsTransparent() throws {
        let original = try makeImage(width: 40, height: 40, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let annotation = ImageAnnotation(tool: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: CGColor(gray: 0, alpha: 0.1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [annotation]))
        XCTAssertEqual(try rgba(rendered, x: 20, y: 20), [0, 0, 0, 255])
        XCTAssertEqual(try rgba(rendered, x: 2, y: 2), [255, 0, 0, 255])
        // Raster output must remain independent from subsequent model changes.
        var editedAnnotation = annotation
        editedAnnotation.points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertEqual(try rgba(rendered, x: 20, y: 20), [0, 0, 0, 255])
        XCTAssertNotEqual(editedAnnotation.bounds, annotation.bounds)
    }

    func testHighlighterKeepsUnderlyingPixelsVisible() throws {
        let original = try makeImage(width: 40, height: 40, color: CGColor(gray: 1, alpha: 1))
        let marker = ImageAnnotation(tool: .highlighter, points: [CGPoint(x: 8, y: 8), CGPoint(x: 32, y: 32)], color: CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [marker]))
        let pixel = try rgba(rendered, x: 20, y: 20)
        XCTAssertGreaterThan(pixel[2], 100)
        XCTAssertLessThan(pixel[2], 240)
        XCTAssertEqual(pixel[3], 255)
    }

    func testAnnotationOrderIsFlattenedInOrder() throws {
        let original = try makeImage(width: 40, height: 40, color: CGColor(gray: 1, alpha: 1))
        let points = [CGPoint(x: 5, y: 5), CGPoint(x: 35, y: 35)]
        let red = ImageAnnotation(tool: .redact, points: points, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let blue = ImageAnnotation(tool: .redact, points: points, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [red, blue]))
        XCTAssertEqual(try rgba(rendered, x: 20, y: 20), [0, 0, 255, 255])
    }

    func testEveryDrawingToolRendersWithoutChangingExtent() throws {
        let image = ImageEditorRenderer.makeSampleImage()
        for tool in ImageEditorTool.allCases {
            let annotation = ImageAnnotation(tool: tool, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250)], text: "Test 文字", number: 2)
            let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: [annotation]), "\(tool)")
            XCTAssertEqual(result.width, image.width, "\(tool)")
            XCTAssertEqual(result.height, image.height, "\(tool)")
        }
    }

    func testCropClipsToImageAndRejectsEmptyRegion() throws {
        let image = try makeImage(width: 100, height: 80, color: CGColor(gray: 1, alpha: 1))
        let cropped = try XCTUnwrap(ImageEditorRenderer.crop(image: image, to: CGRect(x: -10, y: 20, width: 50, height: 100)))
        XCTAssertEqual(cropped.width, 40)
        XCTAssertEqual(cropped.height, 60)
        XCTAssertNil(ImageEditorRenderer.crop(image: image, to: CGRect(x: 200, y: 200, width: 10, height: 10)))
        XCTAssertNil(ImageEditorRenderer.crop(image: image, to: .zero))
    }

    func testCropUsesBottomLeftAnnotationCoordinates() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 80, bitsPerComponent: 8, bytesPerRow: 60 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 40, width: 60, height: 40))
        let original = try XCTUnwrap(context.makeImage())
        let bottom = try XCTUnwrap(ImageEditorRenderer.crop(image: original, to: CGRect(x: 0, y: 0, width: 60, height: 40)))
        XCTAssertEqual(try rgba(bottom, x: 30, y: 20), [255, 0, 0, 255])
    }

    func testFiltersChangeOnlyTheSelectedRegion() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 80 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        for y in stride(from: 0, to: 80, by: 2) {
            for x in stride(from: 0, to: 80, by: 2) {
                context.setFillColor(CGColor(gray: ((x / 2 + y / 2) % 2 == 0) ? 0 : 1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        let original = try XCTUnwrap(context.makeImage())
        for tool in [ImageEditorTool.blur, .pixelate] {
            let annotation = ImageAnnotation(tool: tool, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)])
            let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [annotation]))
            XCTAssertEqual(try rgba(rendered, x: 5, y: 5), try rgba(original, x: 5, y: 5))
            var foundChangedPixel = false
            for x in 30..<50 {
                if try rgba(rendered, x: x, y: 40) != rgba(original, x: x, y: 40) { foundChangedPixel = true }
            }
            XCTAssertTrue(foundChangedPixel, "\(tool) must affect pixels inside the selected area")
        }
    }

    func testRasterAllocationLimitRejectsOversizedAndOverflowingDimensions() {
        XCTAssertTrue(ImageEditorRenderer.allowsRasterSize(width: 10_000, height: 10_000))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: 10_001, height: 10_000))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: Int.max, height: 2))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: Int.max / 4, height: 8))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: 0, height: 2))
        XCTAssertFalse(ImageEditorRenderer.allowsRasterSize(width: 1, height: -2))
    }

    func testHistoryBudgetCountsSharedImagesOnlyOnce() throws {
        let first = try makeImage(width: 4, height: 4, color: CGColor(gray: 0, alpha: 1))
        let second = try makeImage(width: 4, height: 4, color: CGColor(gray: 1, alpha: 1))
        let bytes = first.bytesPerRow * first.height + second.bytesPerRow * second.height
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: [first, first, second], maximumBytes: bytes), 0)
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: [first, first, second], maximumBytes: bytes, maximumSnapshots: 2), 1)
    }

    func testHistoryBudgetEvictsOldestDistinctImages() throws {
        let first = try makeImage(width: 4, height: 4, color: CGColor(gray: 0, alpha: 1))
        let second = try makeImage(width: 4, height: 4, color: CGColor(gray: 1, alpha: 1))
        let third = try makeImage(width: 4, height: 4, color: CGColor(gray: 0.5, alpha: 1))
        let bytes = second.bytesPerRow * second.height + third.bytesPerRow * third.height
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: [first, second, third], maximumBytes: bytes), 1)
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: [first, second, third], maximumBytes: 1), 2)
        XCTAssertEqual(ImageEditorHistoryBudget.retainedSuffixStart(images: []), 0)
    }

    func testCropMaterializesOnlyItsVisibleRaster() throws {
        let image = try makeImage(width: 200, height: 160, color: CGColor(gray: 1, alpha: 1))
        let crop = try XCTUnwrap(ImageEditorRenderer.crop(image: image, to: CGRect(x: 20, y: 20, width: 8, height: 10)))
        XCTAssertEqual(crop.bytesPerRow, crop.width * 4)
        let data = try XCTUnwrap(crop.dataProvider?.data)
        XCTAssertEqual(CFDataGetLength(data), 8 * 10 * 4)
    }

    func testTranslationPreservesIdentityAndText() {
        let original = ImageAnnotation(tool: .text, points: [CGPoint(x: 10, y: 20)], text: "Label")
        let moved = original.translated(by: CGSize(width: 14, height: -8))
        XCTAssertEqual(moved.id, original.id)
        XCTAssertEqual(moved.text, "Label")
        XCTAssertEqual(moved.points.first, CGPoint(x: 24, y: 12))
        XCTAssertEqual(original.points.first, CGPoint(x: 10, y: 20))
    }

    @MainActor
    func testRasterExportsCanBeReopenedWithoutSourceLayers() throws {
        let original = try makeImage(width: 40, height: 40, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let redaction = ImageAnnotation(tool: .redact, points: [CGPoint(x: 5, y: 5), CGPoint(x: 35, y: 35)], color: CGColor(gray: 0, alpha: 1))
        let rendered = try XCTUnwrap(ImageEditorRenderer.render(image: original, annotations: [redaction]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (format, ext) in ["png", "jpg", "tiff"].enumerated() {
            let url = directory.appendingPathComponent("redacted.\(ext)")
            try ImageEditorController.writeFlattened(rendered, to: url, format: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            let reopened = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(reopened.width, 40)
            let pixel = try rgba(reopened, x: 20, y: 20)
            XCTAssertLessThan(pixel[0], 8, "\(ext) redaction must remain black")
            XCTAssertLessThan(pixel[1], 8)
            XCTAssertLessThan(pixel[2], 8)
        }
        let pdfURL = directory.appendingPathComponent("redacted.pdf")
        try ImageEditorController.writeFlattened(rendered, to: pdfURL, format: 3)
        let pdf = try XCTUnwrap(CGPDFDocument(pdfURL as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 40, height: 40))
    }

    private func makeImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 4))
    }
}
