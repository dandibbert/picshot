import XCTest
import AppKit
import CoreGraphics
@testable import PicShot

final class AnnotationEffectsTests: XCTestCase {
    private let frozenDate = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02 03:04:05 UTC
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    private let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

    func testBrushEraserRemovesEarlierInkButNeverTheBaseOrLaterInk() throws {
        let base = try solidImage(width: 120, height: 100, color: blue)
        let mark = filledRect(CGRect(x: 10, y: 10, width: 100, height: 80), color: red)
        let eraser = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 20, y: 50), CGPoint(x: 100, y: 50)], lineWidth: 20)
        let later = filledRect(CGRect(x: 55, y: 40, width: 10, height: 20), color: green)
        let baseBytes = try imageBytes(base)
        let result = try render(base, [mark, eraser, later])
        XCTAssertEqual(try pixel(result, x: 30, y: 50), [0, 0, 255, 255])
        XCTAssertEqual(try pixel(result, x: 30, y: 25), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(result, x: 60, y: 50), [0, 255, 0, 255])
        XCTAssertEqual(try imageBytes(base), baseBytes)
        XCTAssertEqual(try imageBytes(render(base, [eraser])), baseBytes, "An eraser alone must not modify capture pixels")
    }

    func testBrushSelfCrossingRepeatedSegmentsAndMultipleErasersFormAUnion() throws {
        let base = try solidImage(width: 120, height: 120)
        let mark = filledRect(CGRect(x: 10, y: 10, width: 100, height: 100), color: red)
        let crossing = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100),
            CGPoint(x: 20, y: 100), CGPoint(x: 100, y: 20), CGPoint(x: 20, y: 100)], lineWidth: 14)
        let repeated = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 20, y: 60), CGPoint(x: 100, y: 60),
            CGPoint(x: 20, y: 60), CGPoint(x: 100, y: 60)], lineWidth: 12)
        let result = try render(base, [mark, crossing, repeated])
        for point in [CGPoint(x: 60, y: 60), CGPoint(x: 30, y: 30), CGPoint(x: 30, y: 90), CGPoint(x: 90, y: 30), CGPoint(x: 30, y: 60)] {
            XCTAssertEqual(try pixel(result, x: Int(point.x), y: Int(point.y)), [255, 255, 255, 255], "Overlapping eraser capsules must not restore old ink at \(point)")
            XCTAssertTrue(crossing.erases(point) || repeated.erases(point))
        }
        XCTAssertEqual(try pixel(result, x: 15, y: 50), [255, 0, 0, 255])
    }

    func testMergedEraserPathMatchesIndependentCapsuleUnionAtSelfCrossingsAndRetraces() {
        let fixtures: [[CGPoint]] = [
            [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100), CGPoint(x: 20, y: 100), CGPoint(x: 100, y: 20), CGPoint(x: 20, y: 100)],
            [CGPoint(x: 20, y: 60), CGPoint(x: 100, y: 60), CGPoint(x: 20, y: 60), CGPoint(x: 100, y: 60)],
            [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 100), CGPoint(x: 20, y: 100), CGPoint(x: 20, y: 20)],
            [CGPoint(x: 60, y: 60), CGPoint(x: 60, y: 60), CGPoint(x: 60, y: 60)]
        ]
        for (index, points) in fixtures.enumerated() {
            var eraser = ImageAnnotation(tool: .eraser, points: points, lineWidth: 14)
            if index == 2 { eraser.rotation = .pi / 6 }
            var capsules: [CGPath] = []
            eraser.forEachEraserPath { capsules.append($0) }
            let merged = eraser.mergedEraserPath
            for y in stride(from: 0, through: 140, by: 4) {
                for x in stride(from: 0, through: 140, by: 4) {
                    // Fractional offsets avoid asserting unstable boundary membership.
                    let point = CGPoint(x: CGFloat(x) + 0.375, y: CGFloat(y) + 0.125)
                    let expected = capsules.contains { $0.contains(point) }
                    XCTAssertEqual(merged.contains(point), expected, "Fixture \(index), point \(point)")
                }
            }
        }
    }

    func testBrushWidthAndSinglePointEraseHaveRealPixelCoverage() throws {
        let base = try solidImage(width: 100, height: 100)
        let mark = filledRect(CGRect(x: 5, y: 5, width: 90, height: 90), color: red)
        var eraser = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 50, y: 50)], lineWidth: 8)
        let narrow = try render(base, [mark, eraser])
        XCTAssertEqual(try pixel(narrow, x: 50, y: 50), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(narrow, x: 60, y: 50), [255, 0, 0, 255])
        eraser.lineWidth = 32
        let wide = try render(base, [mark, eraser])
        XCTAssertEqual(try pixel(wide, x: 60, y: 50), [255, 255, 255, 255])
        XCTAssertFalse(eraser.erases(CGPoint(x: 80, y: 80)))
    }

    func testRectangleEraserCanBeResizedAndIgnoresPaintOpacity() throws {
        let base = try solidImage(width: 100, height: 100)
        let mark = filledRect(CGRect(x: 5, y: 5, width: 90, height: 90), color: red)
        var eraser = region(.eraser, CGRect(x: 20, y: 20, width: 20, height: 20))
        eraser.eraserMode = .rectangle; eraser.opacity = 0; eraser.color = CGColor(gray: 0, alpha: 0)
        let first = try render(base, [mark, eraser])
        XCTAssertEqual(try pixel(first, x: 30, y: 30), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(first, x: 60, y: 60), [255, 0, 0, 255])
        let resized = eraser.edited(handle: .corner(2), from: CGPoint(x: 40, y: 40), to: CGPoint(x: 75, y: 75), shift: false)
        XCTAssertEqual(resized.id, eraser.id)
        XCTAssertEqual(resized.localBounds, CGRect(x: 20, y: 20, width: 55, height: 55))
        XCTAssertEqual(try pixel(render(base, [mark, resized]), x: 60, y: 60), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(render(base, [resized, mark]), x: 60, y: 60), [255, 0, 0, 255])
    }

    func testEraserRestoresTheExactTransparentBaseAlpha() throws {
        let base = try solidImage(width: 100, height: 100, color: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.35))
        let mark = filledRect(CGRect(x: 10, y: 10, width: 80, height: 80), color: red)
        var eraser = region(.eraser, CGRect(x: 25, y: 25, width: 50, height: 50)); eraser.eraserMode = .rectangle
        let result = try render(base, [mark, eraser])
        let expected = try pixel(base, x: 50, y: 50)
        XCTAssertGreaterThan(expected[3], 0); XCTAssertLessThan(expected[3], 255)
        XCTAssertEqual(try pixel(result, x: 50, y: 50), expected)
        XCTAssertEqual(try pixel(result, x: 5, y: 5), try pixel(base, x: 5, y: 5))
        XCTAssertEqual(try pixel(result, x: 15, y: 15), [255, 0, 0, 255])
        let transparent = try solidImage(width: 100, height: 100, color: CGColor(gray: 0, alpha: 0))
        XCTAssertEqual(try pixel(render(transparent, [mark, eraser]), x: 50, y: 50), [0, 0, 0, 0])
    }

    func testSpotlightLeavesInsideUnchangedAndDimsOnlyOutside() throws {
        let base = try solidImage(width: 160, height: 120)
        var spotlight = region(.spotlight, CGRect(x: 40, y: 30, width: 80, height: 60))
        spotlight.spotlightShape = .rectangle; spotlight.spotlightBorder = false; spotlight.spotlightDim = 0.5
        let result = try render(base, [spotlight])
        XCTAssertEqual(try pixel(result, x: 80, y: 60), [255, 255, 255, 255])
        assertGray(try pixel(result, x: 10, y: 10), near: 127)
        spotlight.spotlightDim = 0
        XCTAssertEqual(try imageBytes(render(base, [spotlight])), try imageBytes(base))
        spotlight.spotlightDim = 1
        XCTAssertEqual(try pixel(render(base, [spotlight]), x: 10, y: 10), [0, 0, 0, 255])
    }

    func testSpotlightEllipseClipsCornerAndOptionalBorderProducesInk() throws {
        let base = try solidImage(width: 160, height: 120)
        var spotlight = region(.spotlight, CGRect(x: 40, y: 20, width: 80, height: 80))
        spotlight.spotlightShape = .ellipse; spotlight.spotlightBorder = false; spotlight.spotlightDim = 0.5
        spotlight.color = red; spotlight.lineWidth = 6
        let noBorder = try render(base, [spotlight])
        assertGray(try pixel(noBorder, x: 44, y: 24), near: 127)
        XCTAssertEqual(try pixel(noBorder, x: 80, y: 60), [255, 255, 255, 255])
        spotlight.spotlightBorder = true
        let bordered = try render(base, [spotlight])
        XCTAssertEqual(try pixel(bordered, x: 41, y: 60), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(bordered, x: 80, y: 60), try pixel(noBorder, x: 80, y: 60))
    }

    func testSpotlightsStackInOrderAndLaterMarksRemainUndimmed() throws {
        let base = try solidImage(width: 180, height: 120)
        var first = region(.spotlight, CGRect(x: 20, y: 20, width: 70, height: 80))
        first.spotlightShape = .rectangle; first.spotlightDim = 0.5; first.spotlightBorder = false
        var second = first; second.id = UUID(); second.points = [CGPoint(x: 60, y: 20), CGPoint(x: 140, y: 100)]
        let result = try render(base, [first, second])
        XCTAssertEqual(try pixel(result, x: 75, y: 60), [255, 255, 255, 255])
        assertGray(try pixel(result, x: 35, y: 60), near: 127)
        assertGray(try pixel(result, x: 160, y: 60), near: 64)
        let later = filledRect(CGRect(x: 150, y: 40, width: 20, height: 40), color: green)
        XCTAssertEqual(try pixel(render(base, [first, second, later]), x: 160, y: 60), [0, 255, 0, 255])
    }

    func testWatermarkResolvesFrozenDateAndTimezoneWithoutChangingTheTemplate() {
        var watermark = watermarkAnnotation()
        watermark.watermarkTemplate = "Captured $yyyy-MM-dd HH:mm:ss$ · $yyyy/MM/dd$"
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(watermark), "Captured 2024-01-02 03:04:05 · 2024/01/02")
        watermark.frozenTimeZoneIdentifier = "Asia/Shanghai"
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(watermark), "Captured 2024-01-02 11:04:05 · 2024/01/02")
        XCTAssertEqual(watermark.watermarkTemplate, "Captured $yyyy-MM-dd HH:mm:ss$ · $yyyy/MM/dd$")
        watermark.frozenTimeZoneIdentifier = "Invalid/Zone"
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(watermark), "Captured 2024-01-02 03:04:05 · 2024/01/02")
    }

    func testWatermarkInvalidAndUnclosedTokensStayLiteralAndTemplatesAreBounded() {
        var watermark = watermarkAnnotation()
        watermark.watermarkTemplate = "literal $unknown$ $$ $yyyy-QQ$ $yyyy-MM-dd"
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(watermark), watermark.watermarkTemplate)
        watermark.watermarkTemplate = "$" + String(repeating: "y", count: 65) + "$"
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(watermark), watermark.watermarkTemplate)
        watermark.watermarkTemplate = String(repeating: "A", count: 1_024)
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(watermark).count, AnnotationWatermarkLayout.maximumTemplateCharacters)
        XCTAssertEqual(AnnotationWatermarkLayout.maximumTemplateCharacters, 512)
    }

    func testAllEightWatermarkPlacementsRespectAreaAnchors() throws {
        var watermark = watermarkAnnotation(area: CGRect(x: 30, y: 40, width: 400, height: 260))
        let area = watermark.localBounds
        let base = try solidImage(width: 500, height: 350)
        XCTAssertEqual(AnnotationWatermarkPlacement.allCases.count, 8)
        for placement in AnnotationWatermarkPlacement.allCases {
            watermark.watermarkPlacement = placement
            let tiles = AnnotationWatermarkLayout.tileRects(for: watermark)
            let tile = try XCTUnwrap(tiles.first, "\(placement)")
            let rendered = try render(base, [watermark])
            XCTAssertGreaterThan(try channelValues(rendered, in: tile).filter { $0 < 100 }.count, 20, "\(placement) must draw visible text at its resolved anchor")
            if placement == .tiled {
                XCTAssertGreaterThan(tiles.count, 1); XCTAssertEqual(tile.origin, area.origin)
                continue
            }
            XCTAssertEqual(tiles.count, 1, "\(placement)")
            switch placement {
            case .topLeft, .bottomLeft: XCTAssertEqual(tile.minX, area.minX + 12, accuracy: 0.001)
            case .topRight, .bottomRight: XCTAssertEqual(tile.maxX, area.maxX - 12, accuracy: 0.001)
            default: XCTAssertEqual(tile.midX, area.midX, accuracy: 0.001)
            }
            switch placement {
            case .topLeft, .topRight, .topCenter: XCTAssertEqual(tile.maxY, area.maxY - 12, accuracy: 0.001)
            case .bottomLeft, .bottomRight, .bottomCenter: XCTAssertEqual(tile.minY, area.minY + 12, accuracy: 0.001)
            default: XCTAssertEqual(tile.midY, area.midY, accuracy: 0.001)
            }
            XCTAssertTrue(area.contains(tile), "\(placement)")
        }
    }

    func testWatermarkSpacingChangesDensityAndGiantAreasStayBoundedAndCovered() throws {
        var watermark = watermarkAnnotation(area: CGRect(x: 0, y: 0, width: 600, height: 400))
        watermark.watermarkSpacing = 10
        let tight = AnnotationWatermarkLayout.tileRects(for: watermark)
        XCTAssertGreaterThan(tight.count, 2)
        XCTAssertEqual(tight[1].minX - tight[0].maxX, 10, accuracy: 0.001)
        watermark.watermarkSpacing = 100
        let sparse = AnnotationWatermarkLayout.tileRects(for: watermark)
        XCTAssertLessThan(sparse.count, tight.count)
        XCTAssertEqual(sparse[1].minX - sparse[0].maxX, 100, accuracy: 0.001)
        watermark.points = [.zero, CGPoint(x: 1_000_000, y: 1_000_000)]
        watermark.watermarkTemplate = "x"; watermark.fontSize = 8; watermark.watermarkSpacing = 0
        let bounded = AnnotationWatermarkLayout.tileRects(for: watermark)
        XCTAssertEqual(AnnotationWatermarkLayout.maximumTiles, 4_096)
        XCTAssertLessThanOrEqual(bounded.count, 4_096)
        XCTAssertGreaterThan(bounded.count, 1_000)
        XCTAssertGreaterThan(try XCTUnwrap(bounded.map(\.minX).max()), 900_000)
        XCTAssertGreaterThan(try XCTUnwrap(bounded.map(\.minY).max()), 900_000, "The cap must distribute coverage across the whole capture")
    }

    func testWatermarkTileCapStillCoversVeryTallAndVeryWideCaptures() throws {
        for area in [CGRect(x: 0, y: 0, width: 16, height: 1_000_000),
                     CGRect(x: 0, y: 0, width: 1_000_000, height: 16)] {
            var watermark = watermarkAnnotation(area: area)
            watermark.watermarkTemplate = "x"; watermark.fontSize = 8; watermark.watermarkSpacing = 0
            let tiles = AnnotationWatermarkLayout.tileRects(for: watermark)
            XCTAssertFalse(tiles.isEmpty)
            XCTAssertLessThanOrEqual(tiles.count, AnnotationWatermarkLayout.maximumTiles)
            XCTAssertEqual(tiles.first?.origin, area.origin)
            if area.height > area.width {
                XCTAssertGreaterThan(try XCTUnwrap(tiles.map(\.minY).max()), area.maxY * 0.95,
                    "The density cap must reach the end of a one-column scrolling capture")
            } else {
                XCTAssertGreaterThan(try XCTUnwrap(tiles.map(\.minX).max()), area.maxX * 0.95,
                    "The density cap must reach the end of a one-row panoramic capture")
            }
        }
    }

    func testWatermarkActuallyRendersTextAndAppliesOpacityWithinItsArea() throws {
        let base = try solidImage(width: 320, height: 200)
        var watermark = watermarkAnnotation(area: CGRect(x: 40, y: 30, width: 240, height: 140))
        watermark.watermarkTemplate = "TEST"; watermark.fontSize = 42; watermark.watermarkPlacement = .center
        watermark.opacity = 1
        let opaque = try render(base, [watermark])
        let dark = try channelValues(opaque, in: watermark.localBounds)
        XCTAssertGreaterThan(dark.filter { $0 < 40 }.count, 100, "A watermark must rasterize glyph ink, not only produce layout rectangles")
        watermark.opacity = 0.25
        let translucent = try render(base, [watermark])
        let faded = try channelValues(translucent, in: watermark.localBounds)
        XCTAssertGreaterThan(faded.filter { $0 < 230 }.count, 100)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(faded.min()), 190)
        XCTAssertLessThanOrEqual(try XCTUnwrap(faded.min()), 193)
        XCTAssertEqual(try channelValues(translucent, in: CGRect(x: 0, y: 0, width: 320, height: 20)).filter { $0 != 255 }.count, 0)
        XCTAssertEqual(try pixel(translucent, x: 10, y: 100), [255, 255, 255, 255])
    }

    func testMagnifierLensTranslationAndScaleLeaveSourceIndependent() {
        let annotation = magnifierAnnotation()
        let moved = annotation.translatedLens(by: CGSize(width: 15, height: -25))
        XCTAssertEqual(moved.id, annotation.id)
        XCTAssertEqual(moved.magnifierSourceRect, annotation.magnifierSourceRect)
        XCTAssertEqual(moved.localBounds, annotation.localBounds.offsetBy(dx: 15, dy: -25))
        let resized = annotation.resizedMagnifierLens(scale: 3)
        XCTAssertEqual(resized.magnifierSourceRect, annotation.magnifierSourceRect)
        XCTAssertEqual(resized.magnifierScale, 3)
        XCTAssertEqual(resized.localBounds.size, CGSize(width: 90, height: 60))
        XCTAssertEqual(center(resized.localBounds), center(annotation.localBounds))
        XCTAssertEqual(annotation.resizedMagnifierLens(scale: 100).magnifierScale, 8)
        XCTAssertEqual(annotation.resizedMagnifierLens(scale: -1).magnifierScale, 1)
        XCTAssertEqual(annotation.resizedMagnifierLens(scale: .nan).magnifierScale, 2)
        let whole = annotation.translated(by: CGSize(width: 7, height: 9))
        XCTAssertEqual(whole.magnifierSourceRect, annotation.magnifierSourceRect.offsetBy(dx: 7, dy: 9))
        XCTAssertEqual(whole.localBounds, annotation.localBounds.offsetBy(dx: 7, dy: 9))
    }

    func testMagnifierSourceMoveAndResizePreserveLensCenterAndScale() {
        let annotation = magnifierAnnotation()
        let source = annotation.magnifierSourceRect
        let moved = annotation.edited(handle: .source, from: center(source), to: CGPoint(x: source.midX + 20, y: source.midY - 10), shift: false)
        XCTAssertEqual(moved.localBounds, annotation.localBounds)
        XCTAssertEqual(moved.magnifierScale, annotation.magnifierScale)
        XCTAssertEqual(moved.magnifierSourceRect, source.offsetBy(dx: 20, dy: -10))
        let resized = annotation.edited(handle: .sourceCorner(2), from: CGPoint(x: source.maxX, y: source.maxY),
                                        to: CGPoint(x: source.maxX + 10, y: source.maxY + 10), shift: false)
        XCTAssertEqual(resized.magnifierSourceRect, CGRect(x: 20, y: 30, width: 40, height: 30))
        XCTAssertEqual(resized.localBounds.size, CGSize(width: 80, height: 60))
        XCTAssertEqual(center(resized.localBounds), center(annotation.localBounds))
        XCTAssertEqual(resized.magnifierScale, 2)
        let handles = annotation.handles(zoom: 2)
        XCTAssertTrue(handles.contains { $0.0 == .source && $0.1 == center(source) })
        for index in 0..<4 { XCTAssertTrue(handles.contains { $0.0 == .sourceCorner(index) }) }
        XCTAssertFalse(handles.contains { $0.0 == .rotation })
        XCTAssertTrue(annotation.hitTest(center(source), tolerance: 0))
        XCTAssertTrue(annotation.hitTest(center(annotation.localBounds), tolerance: 0))
        XCTAssertFalse(annotation.hitTest(CGPoint(x: 5, y: 5), tolerance: 0))
    }

    func testMagnifierSamplesSourceAndClipsRectangleOrEllipseLens() throws {
        let context = try bitmap(width: 180, height: 120)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 180, height: 120))
        for (rect, color) in [(CGRect(x: 10, y: 10, width: 10, height: 10), red),
                              (CGRect(x: 20, y: 10, width: 10, height: 10), blue),
                              (CGRect(x: 10, y: 20, width: 10, height: 10), green),
                              (CGRect(x: 20, y: 20, width: 10, height: 10), CGColor(gray: 0, alpha: 1))] {
            context.setFillColor(color); context.fill(rect)
        }
        let base = try XCTUnwrap(context.makeImage())
        var magnifier = region(.magnifier, CGRect(x: 80, y: 20, width: 60, height: 60))
        magnifier.magnifierSource = CGRect(x: 10, y: 10, width: 20, height: 20)
        magnifier.magnifierScale = 3; magnifier.magnifierShape = .rectangle
        magnifier.magnifierConnector = .none; magnifier.magnifierShadow = false; magnifier.lineWidth = 1
        let rectangle = try render(base, [magnifier])
        XCTAssertEqual(try pixel(rectangle, x: 90, y: 30), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(rectangle, x: 130, y: 30), [0, 0, 255, 255])
        XCTAssertEqual(try pixel(rectangle, x: 90, y: 70), [0, 255, 0, 255])
        XCTAssertEqual(try pixel(rectangle, x: 130, y: 70), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(rectangle, x: 82, y: 22), [255, 0, 0, 255])
        magnifier.magnifierShape = .ellipse
        let ellipse = try render(base, [magnifier])
        XCTAssertEqual(try pixel(ellipse, x: 82, y: 22), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(ellipse, x: 100, y: 40), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(ellipse, x: 150, y: 60), [255, 255, 255, 255])
    }

    func testMagnifierIncludesLowerMarksAndHidingMarksKeepsRedactionOpaque() throws {
        let base = try solidImage(width: 180, height: 120)
        let mark = filledRect(CGRect(x: 10, y: 10, width: 30, height: 30), color: red)
        var redaction = region(.redact, CGRect(x: 10, y: 10, width: 15, height: 30))
        redaction.color = CGColor(gray: 0, alpha: 0.01); redaction.opacity = 0
        var magnifier = region(.magnifier, CGRect(x: 80, y: 20, width: 60, height: 60))
        magnifier.magnifierSource = CGRect(x: 10, y: 10, width: 30, height: 30)
        magnifier.magnifierShape = .rectangle; magnifier.magnifierConnector = .none; magnifier.magnifierShadow = false
        let included = try render(base, [mark, redaction, magnifier])
        XCTAssertEqual(try pixel(included, x: 95, y: 50), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(included, x: 125, y: 50), [255, 0, 0, 255])
        magnifier.magnifierShowsAnnotations = false
        let hidden = try render(base, [mark, redaction, magnifier])
        XCTAssertEqual(try pixel(hidden, x: 95, y: 50), [0, 0, 0, 255], "Hiding decorative marks must never reveal pixels under redaction")
        XCTAssertEqual(try pixel(hidden, x: 125, y: 50), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(hidden, x: 32, y: 25), [255, 0, 0, 255], "The source view keeps its lower annotations")
    }

    func testRedactionAddedAfterAMagnifierAlsoRedactsItsAlreadyCreatedLens() throws {
        let base = try solidImage(width: 180, height: 120, color: red)
        var magnifier = region(.magnifier, CGRect(x: 80, y: 20, width: 60, height: 60))
        magnifier.magnifierSource = CGRect(x: 10, y: 10, width: 30, height: 30)
        magnifier.magnifierShape = .rectangle; magnifier.magnifierConnector = .none; magnifier.magnifierShadow = false
        var laterRedaction = region(.redact, CGRect(x: 10, y: 10, width: 30, height: 30))
        laterRedaction.color = CGColor(gray: 0, alpha: 0.01); laterRedaction.opacity = 0
        XCTAssertEqual(try pixel(render(base, [magnifier]), x: 110, y: 50), [255, 0, 0, 255])
        for showsAnnotations in [true, false] {
            magnifier.magnifierShowsAnnotations = showsAnnotations
            let result = try render(base, [magnifier, laterRedaction])
            XCTAssertEqual(try pixel(result, x: 25, y: 25), [0, 0, 0, 255])
            XCTAssertEqual(try pixel(result, x: 110, y: 50), [0, 0, 0, 255],
                "A previously created lens must not retain pixels subsequently redacted in its source, including when decorative annotations are hidden")
            XCTAssertEqual(try pixel(result, x: 160, y: 100), [255, 0, 0, 255])
        }
    }

    func testMagnifierConnectorModesAndShadowChangeExportedPixels() throws {
        let base = try solidImage(width: 200, height: 140)
        var lens = region(.magnifier, CGRect(x: 110, y: 40, width: 60, height: 60))
        lens.magnifierSource = CGRect(x: 20, y: 40, width: 20, height: 20)
        lens.magnifierShape = .rectangle; lens.magnifierShadow = false
        lens.color = CGColor(gray: 0, alpha: 1); lens.lineWidth = 3
        let corridor = CGRect(x: 50, y: 40, width: 45, height: 40)
        var darkCounts: [AnnotationMagnifierConnector: Int] = [:]
        for connector in AnnotationMagnifierConnector.allCases {
            lens.magnifierConnector = connector
            let result = try render(base, [lens])
            darkCounts[connector] = try channelValues(result, in: corridor).filter { $0 < 100 }.count
            if connector == .line { XCTAssertLessThan(try pixel(result, x: 35, y: 51)[0], 50) }
            if connector == .edges { XCTAssertEqual(try pixel(result, x: 35, y: 51), [255, 255, 255, 255]) }
        }
        XCTAssertEqual(darkCounts[.none], 0)
        XCTAssertGreaterThan(try XCTUnwrap(darkCounts[.line]), 50)
        XCTAssertGreaterThan(try XCTUnwrap(darkCounts[.dotted]), 0)
        XCTAssertLessThan(try XCTUnwrap(darkCounts[.dotted]), try XCTUnwrap(darkCounts[.line]))
        lens.magnifierConnector = .none
        let noShadow = try render(base, [lens])
        lens.magnifierShadow = true
        let shadow = try render(base, [lens])
        let exterior = CGRect(x: 172, y: 30, width: 12, height: 70)
        XCTAssertEqual(try channelValues(noShadow, in: exterior).filter { $0 < 250 }.count, 0)
        XCTAssertGreaterThan(try channelValues(shadow, in: exterior).filter { $0 < 250 }.count, 0)
    }

    func testMagnifierSmoothSamplingChangesCheckerboardInterpolation() throws {
        let context = try bitmap(width: 100, height: 80)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        for y in 10..<14 { for x in 10..<14 {
            context.setFillColor(CGColor(gray: (x + y).isMultiple(of: 2) ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let base = try XCTUnwrap(context.makeImage())
        var lens = region(.magnifier, CGRect(x: 50, y: 20, width: 32, height: 32))
        lens.magnifierSource = CGRect(x: 10, y: 10, width: 4, height: 4)
        lens.magnifierScale = 8; lens.magnifierShape = .rectangle; lens.magnifierShadow = false
        lens.magnifierConnector = .none; lens.magnifierSmooth = false
        let interior = CGRect(x: 54, y: 24, width: 24, height: 24)
        let crisp = try channelValues(render(base, [lens]), in: interior)
        XCTAssertEqual(crisp.filter { $0 > 1 && $0 < 254 }.count, 0)
        lens.magnifierSmooth = true
        let smooth = try channelValues(render(base, [lens]), in: interior)
        XCTAssertGreaterThan(smooth.filter { $0 > 1 && $0 < 254 }.count, 30)
    }

    @MainActor
    func testNativeEraserEscapeRepeatedStrokesUndoRedoAndClearKeepTheBase() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            try selectTool(.rectangle, editor)
            let fill: NSButton = try control("annotation.fill", editor); fill.performClick(nil)
            try drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 260, y: 180))
            let painted = try imageBytes(XCTUnwrap(canvas.flattened()))
            let originalImage = canvas.image
            try selectTool(.eraser, editor)
            try selectPicker("annotation.lineWidth", title: "24", editor)
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 40, y: 30)))
            canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: 40, y: 160)))
            canvas.keyDown(with: try key(canvas, "\u{1b}", code: 53))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 40, y: 160)))
            XCTAssertFalse(editor.isClosed)
            XCTAssertEqual(canvas.annotations.count, 1)
            XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), painted)
            for x in [60, 120, 180] {
                try drag(canvas, from: CGPoint(x: CGFloat(x), y: 30), to: CGPoint(x: CGFloat(x), y: 160))
            }
            XCTAssertEqual(canvas.annotations.count, 4)
            XCTAssertTrue(canvas.annotations.dropFirst().allSatisfy { $0.tool == .eraser && $0.eraserMode == .brush && $0.lineWidth == 24 })
            let erased = try imageBytes(XCTUnwrap(canvas.flattened()))
            for _ in 0..<3 {
                for _ in 0..<3 { try command(canvas, "z", code: 6) }
                XCTAssertEqual(canvas.annotations.count, 1)
                XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), painted)
                for _ in 0..<3 { try command(canvas, "z", code: 6, shift: true) }
                XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), erased)
            }
            let clear: NSButton = try control("annotation.clearAnnotations", editor)
            XCTAssertFalse(clear.isHiddenOrHasHiddenAncestor); clear.performClick(nil)
            XCTAssertTrue(canvas.annotations.isEmpty)
            XCTAssertTrue(canvas.image === originalImage)
            XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), try imageBytes(originalImage))
            try command(canvas, "z", code: 6)
            XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), erased)
            try command(canvas, "z", code: 6, shift: true)
            XCTAssertTrue(canvas.annotations.isEmpty)
        }
    }

    @MainActor
    func testNativeRectangleEraserPaletteResizeAndUndo() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.add(filledRect(CGRect(x: 10, y: 10, width: 280, height: 200), color: red))
            try selectTool(.eraser, editor)
            try selectPicker("annotation.eraserMode", index: 1, editor)
            try drag(canvas, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 90, y: 90))
            XCTAssertEqual(canvas.annotations.last?.eraserMode, .rectangle)
            XCTAssertEqual(try pixel(XCTUnwrap(canvas.flattened()), x: 60, y: 60), [255, 255, 255, 255])
            try selectMenuTool(.select, editor)
            try drag(canvas, from: CGPoint(x: 90, y: 90), to: CGPoint(x: 150, y: 130))
            XCTAssertEqual(canvas.annotations.last?.localBounds, CGRect(x: 30, y: 30, width: 120, height: 100))
            XCTAssertEqual(try pixel(XCTUnwrap(canvas.flattened()), x: 120, y: 110), [255, 255, 255, 255])
            try command(canvas, "z", code: 6)
            XCTAssertEqual(canvas.annotations.last?.localBounds, CGRect(x: 30, y: 30, width: 60, height: 60))
            XCTAssertEqual(try pixel(XCTUnwrap(canvas.flattened()), x: 120, y: 110), [255, 0, 0, 255])
        }
    }

    @MainActor
    func testNativeSpotlightPaletteEditsAreRenderedAndUndoable() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            try selectTool(.spotlight, editor)
            try selectPicker("annotation.spotlightShape", index: 0, editor)
            let dim: NSSlider = try control("annotation.spotlightDim", editor); dim.doubleValue = 0.5
            XCTAssertTrue(dim.sendAction(dim.action, to: dim.target))
            let border: NSButton = try control("annotation.spotlightBorder", editor); border.performClick(nil)
            try drag(canvas, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 160))
            XCTAssertEqual(canvas.annotations[0].spotlightShape, .rectangle)
            XCTAssertFalse(canvas.annotations[0].spotlightBorder)
            assertGray(try pixel(XCTUnwrap(canvas.flattened()), x: 10, y: 10), near: 127)
            try selectMenuTool(.select, editor)
            dim.doubleValue = 0.75; XCTAssertTrue(dim.sendAction(dim.action, to: dim.target))
            border.performClick(nil)
            XCTAssertEqual(canvas.annotations[0].spotlightDim, 0.75, accuracy: 0.001)
            XCTAssertTrue(canvas.annotations[0].spotlightBorder)
            assertGray(try pixel(XCTUnwrap(canvas.flattened()), x: 10, y: 10), near: 64)
            try command(canvas, "z", code: 6); try command(canvas, "z", code: 6)
            XCTAssertEqual(canvas.annotations[0].spotlightDim, 0.5)
            XCTAssertFalse(canvas.annotations[0].spotlightBorder)
        }
    }

    @MainActor
    func testNativeWatermarkMoreMenuTimestampPaletteAndUndoRedoFreezeTime() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            try selectMenuTool(.watermark, editor)
            let template: NSTextField = try control("annotation.watermarkTemplate", editor)
            template.stringValue = "Capture"; XCTAssertTrue(template.sendAction(template.action, to: template.target))
            let timestamp: NSButton = try control("annotation.watermarkTimestamp", editor)
            XCTAssertFalse(timestamp.isHiddenOrHasHiddenAncestor); timestamp.performClick(nil)
            XCTAssertEqual(canvas.style.watermarkTemplate, "Capture $yyyy-MM-dd HH:mm:ss$")
            try selectPicker("annotation.watermarkPlacement", index: 7, editor)
            try setField("annotation.fontSize", value: 24, editor)
            try click(canvas, CGPoint(x: 80, y: 80))
            let initial = try XCTUnwrap(canvas.annotations.first)
            XCTAssertEqual(initial.tool, .watermark); XCTAssertEqual(initial.watermarkPlacement, .center)
            XCTAssertEqual(initial.frozenTimestamp, frozenDate)
            XCTAssertEqual(initial.frozenTimeZoneIdentifier, canvas.captureTimeZoneIdentifier)
            let resolved = AnnotationWatermarkLayout.resolvedText(initial)
            let originalBytes = try imageBytes(XCTUnwrap(canvas.flattened()))
            for _ in 0..<3 {
                try command(canvas, "z", code: 6); XCTAssertTrue(canvas.annotations.isEmpty)
                try command(canvas, "z", code: 6, shift: true)
                XCTAssertEqual(canvas.annotations[0].frozenTimestamp, frozenDate)
                XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(canvas.annotations[0]), resolved)
                XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), originalBytes)
            }
            try selectMenuTool(.select, editor); try click(canvas, CGPoint(x: 160, y: 120))
            try selectPicker("annotation.watermarkPlacement", index: 0, editor)
            try setField("annotation.watermarkSpacing", value: 72, editor)
            let opacity: NSSlider = try control("annotation.opacity", editor); opacity.doubleValue = 0.45
            XCTAssertTrue(opacity.sendAction(opacity.action, to: opacity.target))
            timestamp.performClick(nil)
            XCTAssertEqual(canvas.annotations[0].watermarkTemplate, "Capture $yyyy-MM-dd HH:mm:ss$ $yyyy-MM-dd HH:mm:ss$")
            XCTAssertEqual(canvas.annotations[0].watermarkSpacing, 72)
            XCTAssertEqual(canvas.annotations[0].opacity, 0.45, accuracy: 0.001)
            XCTAssertEqual(canvas.annotations[0].frozenTimestamp, initial.frozenTimestamp)
            XCTAssertEqual(canvas.annotations[0].frozenTimeZoneIdentifier, initial.frozenTimeZoneIdentifier)
            let editedText = AnnotationWatermarkLayout.resolvedText(canvas.annotations[0])
            let editedBytes = try imageBytes(XCTUnwrap(canvas.flattened()))
            for _ in 0..<4 { try command(canvas, "z", code: 6) }
            XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(canvas.annotations[0]), resolved)
            XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), originalBytes)
            for _ in 0..<4 { try command(canvas, "z", code: 6, shift: true) }
            XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(canvas.annotations[0]), editedText)
            XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), editedBytes)
        }
    }

    @MainActor
    func testNativeMagnifierPaletteConfiguresAllOptionsAndScaleResizesTheLens() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            try selectMenuTool(.magnifier, editor)
            try selectPicker("annotation.magnifierShape", index: 0, editor)
            try selectPicker("annotation.magnifierConnector", index: 3, editor)
            try setField("annotation.magnifierScale", value: 3, editor)
            for identifier in ["annotation.magnifierSmooth", "annotation.magnifierShadow", "annotation.magnifierShowsAnnotations"] {
                let toggle: NSButton = try control(identifier, editor)
                XCTAssertFalse(toggle.isHiddenOrHasHiddenAncestor); toggle.performClick(nil)
            }
            try drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 40))
            let initial = try XCTUnwrap(canvas.annotations.first)
            XCTAssertEqual(initial.magnifierShape, .rectangle); XCTAssertEqual(initial.magnifierConnector, .none)
            XCTAssertTrue(initial.magnifierSmooth); XCTAssertFalse(initial.magnifierShadow); XCTAssertFalse(initial.magnifierShowsAnnotations)
            XCTAssertEqual(initial.magnifierScale, 3); XCTAssertEqual(initial.localBounds.size, CGSize(width: 60, height: 60))
            try selectMenuTool(.select, editor)
            try setField("annotation.magnifierScale", value: 4, editor)
            XCTAssertEqual(canvas.annotations[0].localBounds.size, CGSize(width: 80, height: 80))
            XCTAssertEqual(center(canvas.annotations[0].localBounds), center(initial.localBounds))
            XCTAssertEqual(canvas.annotations[0].magnifierSourceRect, initial.magnifierSourceRect)
            try command(canvas, "z", code: 6)
            XCTAssertEqual(canvas.annotations[0].localBounds, initial.localBounds)
            try command(canvas, "z", code: 6, shift: true)
            XCTAssertEqual(canvas.annotations[0].magnifierScale, 4)
        }
    }

    @MainActor
    func testNativeMagnifierSourceAndLensDragIndependentlyAndEscapePreservesRedo() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.zoom = 2
            try selectMenuTool(.magnifier, editor)
            try drag(canvas, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60))
            let initial = try XCTUnwrap(canvas.annotations.first)
            try selectMenuTool(.select, editor)
            let movedLensCenter = CGPoint(x: 180, y: 120)
            try drag(canvas, from: center(initial.localBounds), to: movedLensCenter)
            let lensMoved = canvas.annotations[0]
            XCTAssertEqual(center(lensMoved.localBounds), movedLensCenter)
            XCTAssertEqual(lensMoved.magnifierSourceRect, initial.magnifierSourceRect)
            try drag(canvas, from: center(initial.magnifierSourceRect), to: CGPoint(x: 55, y: 65))
            let sourceMoved = canvas.annotations[0]
            XCTAssertEqual(sourceMoved.localBounds, lensMoved.localBounds)
            XCTAssertEqual(sourceMoved.magnifierSourceRect, initial.magnifierSourceRect.offsetBy(dx: 10, dy: 20))
            let finalBytes = try imageBytes(XCTUnwrap(canvas.flattened()))
            try command(canvas, "z", code: 6)
            try click(canvas, center(initial.magnifierSourceRect))
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, center(initial.magnifierSourceRect)))
            canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: 90, y: 100)))
            XCTAssertNotEqual(canvas.annotations[0].magnifierSourceRect, initial.magnifierSourceRect)
            canvas.keyDown(with: try key(canvas, "\u{1b}", code: 53))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 90, y: 100)))
            XCTAssertEqual(canvas.annotations[0].magnifierSourceRect, initial.magnifierSourceRect)
            XCTAssertEqual(canvas.annotations[0].localBounds, lensMoved.localBounds)
            try command(canvas, "z", code: 6, shift: true)
            XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), finalBytes)
            try click(canvas, movedLensCenter)
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, movedLensCenter))
            canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: 200, y: 160)))
            XCTAssertNotEqual(canvas.annotations[0].localBounds, sourceMoved.localBounds)
            canvas.keyDown(with: try key(canvas, "\u{1b}", code: 53))
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 200, y: 160)))
            XCTAssertEqual(canvas.annotations[0].localBounds, sourceMoved.localBounds)
            XCTAssertEqual(canvas.annotations[0].magnifierSourceRect, sourceMoved.magnifierSourceRect)
            XCTAssertFalse(editor.isClosed)
            for _ in 0..<3 { try command(canvas, "z", code: 6) }
            XCTAssertTrue(canvas.annotations.isEmpty, "Canceled source and lens drags must not add history entries")
            for _ in 0..<3 { try command(canvas, "z", code: 6, shift: true) }
            XCTAssertEqual(try imageBytes(XCTUnwrap(canvas.flattened())), finalBytes)
        }
    }

    @MainActor
    func testNativeMagnifierSourceCornerAndKeyboardNudgesKeepTheOtherPartFixed() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            try selectMenuTool(.magnifier, editor)
            try drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 50, y: 40))
            try selectMenuTool(.select, editor)
            let initial = canvas.annotations[0]
            try drag(canvas, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 60, y: 50))
            let resized = canvas.annotations[0]
            XCTAssertEqual(resized.magnifierSourceRect, CGRect(x: 20, y: 20, width: 40, height: 30))
            XCTAssertEqual(resized.localBounds.size, CGSize(width: 80, height: 60))
            XCTAssertEqual(center(resized.localBounds), center(initial.localBounds))
            XCTAssertEqual(resized.magnifierScale, 2)
            canvas.keyDown(with: try key(canvas, "", code: 124))
            XCTAssertEqual(canvas.annotations[0].localBounds, resized.localBounds.offsetBy(dx: 1, dy: 0))
            XCTAssertEqual(canvas.annotations[0].magnifierSourceRect, resized.magnifierSourceRect)
            canvas.keyDown(with: try key(canvas, "", code: 126, modifiers: [.option, .shift]))
            XCTAssertEqual(canvas.annotations[0].localBounds, resized.localBounds.offsetBy(dx: 1, dy: 0))
            XCTAssertEqual(canvas.annotations[0].magnifierSourceRect, resized.magnifierSourceRect.offsetBy(dx: 0, dy: 10))
            for _ in 0..<3 { try command(canvas, "z", code: 6) }
            XCTAssertEqual(canvas.annotations[0].magnifierSourceRect, initial.magnifierSourceRect)
            XCTAssertEqual(canvas.annotations[0].localBounds, initial.localBounds)
        }
    }

    func testSpotlightPreservesTransparentCaptureAlphaOutsideTheHole() throws {
        let base = try solidImage(width: 100, height: 100, color: CGColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: 0.4))
        var spotlight = region(.spotlight, CGRect(x: 30, y: 30, width: 40, height: 40))
        spotlight.spotlightShape = .rectangle; spotlight.spotlightBorder = false; spotlight.spotlightDim = 0.5
        let result = try render(base, [spotlight])
        let outside = try pixel(result, x: 10, y: 10), original = try pixel(base, x: 10, y: 10)
        XCTAssertEqual(outside[3], original[3], "Dimming must not fill transparent display gaps")
        for index in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(outside[index]) * 2 - Int(original[index])), 2) }
        XCTAssertEqual(try pixel(result, x: 50, y: 50), try pixel(base, x: 50, y: 50))
        let transparent = try solidImage(width: 100, height: 100, color: CGColor(gray: 0, alpha: 0))
        XCTAssertEqual(try pixel(render(transparent, [spotlight]), x: 10, y: 10), [0, 0, 0, 0])
    }

    func testWatermarkHitTestingUsesVisibleTileBoxesRatherThanItsWholeCanvas() throws {
        var watermark = watermarkAnnotation()
        watermark.watermarkPlacement = .bottomRight
        let tile = try XCTUnwrap(AnnotationWatermarkLayout.tileRects(for: watermark).first)
        XCTAssertTrue(watermark.hitTest(center(tile), tolerance: 0))
        XCTAssertFalse(watermark.hitTest(CGPoint(x: 20, y: 150), tolerance: 0))
        watermark.watermarkPlacement = .tiled; watermark.watermarkSpacing = 100
        let tiles = AnnotationWatermarkLayout.tileRects(for: watermark)
        XCTAssertGreaterThan(tiles.count, 1)
        XCTAssertTrue(watermark.hitTest(center(tiles[0]), tolerance: 0))
        XCTAssertFalse(watermark.hitTest(CGPoint(x: tiles[0].maxX + 40, y: tiles[0].midY), tolerance: 0))
    }

    func testFrozenCaptureRecropRetainsOriginalCaptureTimestamp() throws {
        let image = try solidImage(width: 640, height: 480)
        let presentation = FrozenCapturePresentation(frozenImage: image, displayID: 7,
            displayFrame: CGRect(x: 0, y: 0, width: 640, height: 480),
            selectionFrame: CGRect(x: 100, y: 80, width: 320, height: 240), capturedAt: frozenDate)
        let selected = try XCTUnwrap(ImageEditorRenderer.crop(image: image, to: presentation.selectionFrame))
        let expanded = try EditorBoundaryRenderer.recrop(CGRect(x: 80, y: 60, width: 360, height: 280),
            presentation: presentation, previousImage: selected)
        let next = try XCTUnwrap(expanded.presentation)
        XCTAssertEqual(next.capturedAt, frozenDate)
        let contracted = try EditorBoundaryRenderer.recrop(CGRect(x: 120, y: 100, width: 240, height: 180),
            presentation: next, previousImage: expanded.image)
        XCTAssertEqual(contracted.presentation?.capturedAt, frozenDate)
    }

    @MainActor
    func testNativeCropUndoRedoAndNewWatermarkKeepTheOriginalCaptureTime() throws {
        _ = NSApplication.shared
        let image = try solidImage(width: 640, height: 480)
        let presentation = FrozenCapturePresentation(frozenImage: image, displayID: 7,
            displayFrame: CGRect(x: 0, y: 0, width: 640, height: 480),
            selectionFrame: CGRect(x: 100, y: 80, width: 320, height: 240), capturedAt: frozenDate)
        let selected = try XCTUnwrap(ImageEditorRenderer.crop(image: image, to: presentation.selectionFrame))
        let editor = ImageEditorController(image: selected, presentation: presentation,
            onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded()
        defer { editor.close() }
        let canvas = editor.annotationCanvas
        try selectMenuTool(.watermark, editor); try click(canvas, CGPoint(x: 80, y: 80))
        let original = try XCTUnwrap(canvas.annotations.first)
        XCTAssertTrue(original.timestampIsCaptureDate)
        XCTAssertEqual(original.frozenTimestamp, frozenDate)
        let originalText = AnnotationWatermarkLayout.resolvedText(original)
        try selectMenuTool(.crop, editor)
        try drag(canvas, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 250, y: 180))
        canvas.keyDown(with: try key(canvas, "\r", code: 36))
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertEqual(canvas.image.width, 220); XCTAssertEqual(canvas.image.height, 150)
        try selectMenuTool(.watermark, editor); try click(canvas, CGPoint(x: 50, y: 50))
        XCTAssertEqual(canvas.annotations[0].frozenTimestamp, frozenDate)
        XCTAssertTrue(canvas.annotations[0].timestampIsCaptureDate)
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(canvas.annotations[0]), originalText)
        try command(canvas, "z", code: 6); try command(canvas, "z", code: 6)
        XCTAssertEqual(canvas.image.width, 320); XCTAssertEqual(canvas.image.height, 240)
        XCTAssertEqual(canvas.annotations[0].id, original.id)
        XCTAssertEqual(canvas.annotations[0].frozenTimestamp, frozenDate)
        for _ in 0..<2 { try command(canvas, "z", code: 6, shift: true) }
        XCTAssertEqual(canvas.image.width, 220); XCTAssertEqual(canvas.image.height, 150)
        XCTAssertEqual(canvas.annotations[0].frozenTimestamp, frozenDate)
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(canvas.annotations[0]), originalText)
    }

    @MainActor
    func testImportedImageWatermarkLabelsFrozenTimeAsEditingStart() throws {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: try solidImage(width: 320, height: 240),
            onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded()
        defer { editor.close() }
        let canvas = editor.annotationCanvas
        XCTAssertFalse(canvas.captureTimestampKnown)
        try selectMenuTool(.watermark, editor)
        let template: NSTextField = try control("annotation.watermarkTemplate", editor)
        XCTAssertTrue(template.stringValue.contains("编辑于"))
        XCTAssertTrue(try XCTUnwrap(template.toolTip).contains("编辑开始时间"))
        try click(canvas, CGPoint(x: 50, y: 50))
        let annotation = try XCTUnwrap(canvas.annotations.first)
        XCTAssertFalse(annotation.timestampIsCaptureDate)
        XCTAssertEqual(annotation.frozenTimestamp, canvas.captureDate)
        let resolved = AnnotationWatermarkLayout.resolvedText(annotation)
        try command(canvas, "z", code: 6); try command(canvas, "z", code: 6, shift: true)
        XCTAssertEqual(canvas.annotations[0].frozenTimestamp, annotation.frozenTimestamp)
        XCTAssertFalse(canvas.annotations[0].timestampIsCaptureDate)
        XCTAssertEqual(AnnotationWatermarkLayout.resolvedText(canvas.annotations[0]), resolved)
    }

    @MainActor
    func testNativeEffectsDoNotInheritUnrelatedTextOpacityAndWatermarkHonorsChosenOpacity() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.style.opacity = 0.15
            try selectTool(.spotlight, editor)
            try drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
            XCTAssertEqual(canvas.annotations.last?.opacity, 1)
            canvas.style.opacity = 0.15
            try selectMenuTool(.magnifier, editor)
            try drag(canvas, from: CGPoint(x: 100, y: 20), to: CGPoint(x: 130, y: 50))
            XCTAssertEqual(canvas.annotations.last?.opacity, 1)
            try selectMenuTool(.watermark, editor)
            let opacity: NSSlider = try control("annotation.opacity", editor); opacity.doubleValue = 0.8
            XCTAssertTrue(opacity.sendAction(opacity.action, to: opacity.target))
            try click(canvas, CGPoint(x: 40, y: 40))
            XCTAssertEqual(try XCTUnwrap(canvas.annotations.last).opacity, 0.8, accuracy: 0.001)
        }
    }

    @MainActor
    func testNativeLongBrushGestureRetainsBoundedPointsIncludingMouseUpEndpoint() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            canvas.add(filledRect(CGRect(x: 10, y: 10, width: 280, height: 200), color: red))
            try selectTool(.eraser, editor)
            let start = CGPoint(x: 20, y: 20), end = CGPoint(x: 200, y: 180)
            canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start))
            for index in 0..<(ImageAnnotation.maximumGesturePoints - 2) {
                let point = index.isMultiple(of: 2) ? CGPoint(x: 40, y: 40) : CGPoint(x: 80, y: 80)
                canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, point))
            }
            canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
            let eraser = try XCTUnwrap(canvas.annotations.last)
            XCTAssertEqual(eraser.tool, .eraser)
            XCTAssertLessThanOrEqual(eraser.points.count, ImageAnnotation.maximumGesturePoints)
            XCTAssertEqual(eraser.points.first, start); XCTAssertEqual(eraser.points.last, end)
            try command(canvas, "z", code: 6); XCTAssertEqual(canvas.annotations.count, 1)
            try command(canvas, "z", code: 6, shift: true)
            XCTAssertEqual(canvas.annotations.last?.points, eraser.points)
        }
    }

    @MainActor
    func testNativeOptionClickCyclesOverlappingAnnotationsWithoutEditingHistory() throws {
        try withEditor { editor in
            let canvas = editor.annotationCanvas
            let lower = filledRect(CGRect(x: 20, y: 20, width: 180, height: 180), color: red)
            let upper = filledRect(CGRect(x: 40, y: 40, width: 140, height: 140), color: blue)
            canvas.add(lower); canvas.add(upper)
            try selectMenuTool(.select, editor)
            let point = CGPoint(x: 100, y: 100)
            try click(canvas, point); XCTAssertEqual(canvas.selectedAnnotation?.id, upper.id)
            for expected in [lower.id, upper.id, lower.id] {
                canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point, modifiers: .option))
                canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point, modifiers: .option))
                XCTAssertEqual(canvas.selectedAnnotation?.id, expected)
            }
            try command(canvas, "z", code: 6)
            XCTAssertEqual(canvas.annotations.count, 1)
            XCTAssertEqual(canvas.annotations[0].id, lower.id)
        }
    }

    private func region(_ tool: ImageEditorTool, _ rect: CGRect) -> ImageAnnotation {
        ImageAnnotation(tool: tool, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], lineWidth: 2)
    }
    private func filledRect(_ rect: CGRect, color: CGColor) -> ImageAnnotation {
        var annotation = region(.rectangle, rect)
        annotation.color = color; annotation.fillColor = color; annotation.fillEnabled = true
        return annotation
    }
    private func watermarkAnnotation(area: CGRect = CGRect(x: 0, y: 0, width: 320, height: 200)) -> ImageAnnotation {
        var annotation = region(.watermark, area)
        annotation.color = CGColor(gray: 0, alpha: 1); annotation.fontSize = 20
        annotation.watermarkTemplate = "TEST"; annotation.frozenTimestamp = frozenDate; annotation.frozenTimeZoneIdentifier = "UTC"
        return annotation
    }
    private func magnifierAnnotation() -> ImageAnnotation {
        var annotation = region(.magnifier, CGRect(x: 120, y: 100, width: 60, height: 40))
        annotation.magnifierSource = CGRect(x: 20, y: 30, width: 30, height: 20)
        annotation.magnifierScale = 2; annotation.magnifierShadow = false; annotation.magnifierConnector = .none
        return annotation
    }
    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func solidImage(width: Int, height: Int, color: CGColor = CGColor(gray: 1, alpha: 1)) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func render(_ base: CGImage, _ annotations: [ImageAnnotation]) throws -> CGImage {
        try XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: annotations))
    }
    /// Sample image-space y-up coordinates, independent of the provider's scanline order.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try bitmap(width: 1, height: 1)
        context.translateBy(x: CGFloat(-x), y: CGFloat(-y)); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }
    private func channelValues(_ image: CGImage, in rect: CGRect) throws -> [UInt8] {
        let context = try bitmap(width: Int(rect.width), height: Int(rect.height))
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(context.width * context.height)).map { bytes[$0 * 4] }
    }
    private func imageBytes(_ image: CGImage) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
    private func assertGray(_ rgba: [UInt8], near expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rgba.count, 4, file: file, line: line)
        for channel in rgba.prefix(3) { XCTAssertLessThanOrEqual(abs(Int(channel) - expected), 1, file: file, line: line) }
        XCTAssertEqual(rgba.last, 255, file: file, line: line)
    }

    @MainActor
    private func withEditor(_ body: (ImageEditorController) throws -> Void) throws {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: try solidImage(width: 320, height: 240),
            onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, captureDate: frozenDate)
        editor.showWindow(nil); editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.annotationCanvas.zoom = 1
        defer {
            if let sheet = editor.window?.attachedSheet { editor.window?.endSheet(sheet, returnCode: .cancel) }
            editor.close()
        }
        try body(editor)
    }
    @MainActor
    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor
    private func control<T: NSView>(_ identifier: String, _ editor: ImageEditorController) throws -> T {
        try XCTUnwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == identifier } as? T, identifier)
    }
    @MainActor
    private func selectTool(_ tool: ImageEditorTool, _ editor: ImageEditorController) throws {
        let button: NSButton = try control("editor.tool.\(tool.rawValue)", editor)
        button.performClick(nil); XCTAssertEqual(editor.annotationCanvas.tool, tool)
    }
    @MainActor
    private func selectMenuTool(_ tool: ImageEditorTool, _ editor: ImageEditorController) throws {
        let more: NSPopUpButton = try control("editor.more", editor)
        XCTAssertFalse(more.isHiddenOrHasHiddenAncestor)
        let menu = try XCTUnwrap(more.menu)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == tool.title })
        XCTAssertNotNil(menu.items[index].target); XCTAssertNotNil(menu.items[index].action)
        menu.performActionForItem(at: index); XCTAssertEqual(editor.annotationCanvas.tool, tool)
    }
    @MainActor
    private func selectPicker(_ identifier: String, index: Int, _ editor: ImageEditorController) throws {
        let picker: NSPopUpButton = try control(identifier, editor)
        picker.selectItem(at: index); XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
    }
    @MainActor
    private func selectPicker(_ identifier: String, title: String, _ editor: ImageEditorController) throws {
        let picker: NSPopUpButton = try control(identifier, editor)
        picker.selectItem(withTitle: title); XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
    }
    @MainActor
    private func setField(_ identifier: String, value: Double, _ editor: ImageEditorController) throws {
        let field: NSTextField = try control(identifier, editor)
        field.doubleValue = value; XCTAssertTrue(field.sendAction(field.action, to: field.target))
    }
    @MainActor
    private func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let location = canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @MainActor
    private func key(_ canvas: ImageEditorCanvas, _ value: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: value,
            charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
    @MainActor
    private func command(_ canvas: ImageEditorCanvas, _ value: String, code: UInt16, shift: Bool = false) throws {
        XCTAssertTrue(canvas.performKeyEquivalent(with: try key(canvas, value, code: code, modifiers: shift ? [.command, .shift] : .command)))
    }
    @MainActor
    private func click(_ canvas: ImageEditorCanvas, _ point: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point))
    }
    @MainActor
    private func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }
}
