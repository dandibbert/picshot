import XCTest
import AppKit
@testable import PicShot

final class AutomaticMosaicRendererTests: XCTestCase {
    func testOrdinaryFiltersRemainByteIdenticalToRetainedLegacyRenderer() throws {
        let image = try pattern(alpha: true)
        let edge = CGRect(x: 0, y: 0, width: 47, height: 39)
        let overlap = CGRect(x: 17, y: 21, width: 51, height: 43)
        for tool in [ImageEditorTool.pixelate, .blur] {
            var first = annotation(tool, edge); first.lineWidth = 3; first.opacity = 0.65
            var second = annotation(tool, overlap); second.rotation = .pi / 7; second.lineWidth = 4
            var earlier = annotation(.rectangle, CGRect(x: 9, y: 13, width: 72, height: 55))
            earlier.fillEnabled = true; earlier.fillColor = CGColor(srgbRed: 0.2, green: 0.8, blue: 0.1, alpha: 0.65)
            var eraser = annotation(.eraser, CGRect(x: 31, y: 29, width: 15, height: 81)); eraser.eraserMode = .rectangle
            let marks = [earlier, first, second, eraser]
            let old = try XCTUnwrap(AutomaticMosaicLegacyRenderer.render(image: image, annotations: marks))
            let new = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: marks))
            XCTAssertEqual(try bytes(new), try bytes(old), "Ordinary \(tool) grid phase, alpha, edge clamp, order, rotation and eraser clipping must not change")
        }
    }

    func testDisjointGroupedFiltersMatchLegacySequentialPixelsAtOddOrigins() throws {
        let image = try pattern(alpha: true)
        for tool in [ImageEditorTool.pixelate, .blur] {
            var marks = [annotation(tool, CGRect(x: 1, y: 3, width: 25, height: 19)),
                         annotation(tool, CGRect(x: 151, y: 109, width: 31, height: 23))]
            for index in marks.indices { marks[index].lineWidth = 1 }
            let ordinary = try XCTUnwrap(AutomaticMosaicLegacyRenderer.render(image: image, annotations: marks))
            let linked = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: group(marks)))
            XCTAssertEqual(try bytes(linked), try bytes(ordinary), "Distant peers must retain global pixel grid and edge blur semantics")
        }
    }

    func testOverlappingGroupUsesOnePreGroupImageAndOrdinaryFollowingFilterRemainsSequential() throws {
        let image = try pattern(alpha: false)
        for tool in [ImageEditorTool.pixelate, .blur] {
            let first = annotation(tool, CGRect(x: 13, y: 17, width: 69, height: 43))
            let second = annotation(tool, CGRect(x: 51, y: 31, width: 63, height: 41))
            let linked = group([first, second])
            // Independent reference: each fully opaque rectangular patch comes
            // from a separate old-renderer invocation on the same pre-group image.
            let context = try bitmap(width: image.width, height: image.height)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            for mark in [first, second] {
                let independentlyFiltered = try XCTUnwrap(AutomaticMosaicLegacyRenderer.render(image: image, annotations: [mark]))
                context.saveGState(); context.clip(to: mark.localBounds); context.setBlendMode(.copy)
                context.draw(independentlyFiltered, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.restoreGState()
            }
            let expectedGroup = try XCTUnwrap(context.makeImage())
            let actualGroup = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: linked))
            XCTAssertEqual(try bytes(actualGroup), try bytes(expectedGroup))
            var following = annotation(.pixelate, CGRect(x: 27, y: 24, width: 88, height: 57)); following.lineWidth = 7
            let expected = try XCTUnwrap(AutomaticMosaicLegacyRenderer.render(image: expectedGroup, annotations: [following]))
            let actual = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: linked + [following]))
            XCTAssertEqual(try bytes(actual), try bytes(expected), "Group source must be released at the next ordinary annotation")
        }
    }

    func testGroupedSolidRedactionAlwaysExportsOpaquePixelsForEveryIncludedRegion() throws {
        let image = try pattern(alpha: true)
        let rects = [CGRect(x: 11, y: 17, width: 33, height: 19), CGRect(x: 121, y: 97, width: 33, height: 19)]
        let marks = rects.map { rect -> ImageAnnotation in
            var mark = annotation(.redact, rect); mark.opacity = 0.01; mark.color = CGColor(srgbRed: 0.8, green: 0.1, blue: 0.2, alpha: 0.01); return mark
        }
        let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: group(marks)))
        let normalized = try bitmap(width: image.width, height: image.height)
        normalized.draw(result, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(normalized.data?.assumingMemoryBound(to: UInt8.self))
        for rect in rects {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = ((image.height - 1 - y) * image.width + x) * 4
                    XCTAssertEqual(data[offset + 3], 255)
                    XCTAssertGreaterThan(data[offset], 190)
                    XCTAssertLessThan(data[offset + 1], 35)
                }
            }
        }
    }

    func testExcludedRegionHasExactlyUnchangedExportPixels() throws {
        let image = try pattern(alpha: false)
        let selected = CGRect(x: 11, y: 17, width: 33, height: 19)
        let excluded = CGRect(x: 121, y: 97, width: 33, height: 19)
        var marks = group([annotation(.redact, selected)])
        marks[0].mosaicLink?.excludedTargets = [excluded]
        let result = try XCTUnwrap(ImageEditorRenderer.render(image: image, annotations: marks))
        let sourceBytes = try bytes(image), resultBytes = try bytes(result)
        for y in Int(excluded.minY)..<Int(excluded.maxY) {
            for x in Int(excluded.minX)..<Int(excluded.maxX) {
                let offset = ((image.height - 1 - y) * image.width + x) * 4
                XCTAssertEqual(Array(resultBytes[offset..<(offset + 4)]), Array(sourceBytes[offset..<(offset + 4)]))
            }
        }
    }

    private func group(_ annotations: [ImageAnnotation]) -> [ImageAnnotation] {
        let id = UUID(), addition = UUID(), targets = annotations.map(\.localBounds)
        return annotations.map { value in
            var mark = value
            mark.mosaicLink = AutomaticMosaicLink(groupID: id, additionID: addition, rootAdditionID: addition, target: mark.localBounds,
                includedTargets: targets, excludedTargets: [], synchronizes: true)
            return mark
        }
    }
    private func annotation(_ tool: ImageEditorTool, _ rect: CGRect) -> ImageAnnotation {
        ImageAnnotation(tool: tool, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], lineWidth: 3)
    }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func pattern(alpha: Bool) throws -> CGImage {
        let width = 193, height = 145, context = try bitmap(width: width, height: height)
        let data = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4, a = alpha ? (64 + (x * 7 + y * 13) % 192) : 255
                data[offset] = UInt8(((x * 19 + y * 3) % 256) * a / 255)
                data[offset + 1] = UInt8(((x * 5 + y * 23) % 256) * a / 255)
                data[offset + 2] = UInt8(((x * 31 + y * 11) % 256) * a / 255)
                data[offset + 3] = UInt8(a)
            }
        }
        return try XCTUnwrap(context.makeImage())
    }
    private func bytes(_ image: CGImage) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
}
