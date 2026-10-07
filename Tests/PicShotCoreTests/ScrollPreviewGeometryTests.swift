import XCTest
@testable import PicShotCore

final class ScrollPreviewGeometryTests: XCTestCase {
    private func sequence(_ axis: ScrollAxis) throws -> ScrollCaptureSequence {
        var sequence = try ScrollCaptureSequence(axis: axis, width: axis == .vertical ? 96 : 400,
                                                 height: axis == .vertical ? 400 : 96, sourceID: UUID())
        for _ in 0..<5 { try sequence.accept(advance: 300, sourceID: UUID()) }
        return sequence
    }

    func testLatestViewportProjectionSkipsDeletedBandsAndBlocksOnBothAxes() throws {
        for axis in ScrollAxis.allCases {
            let sequence = try sequence(axis)
            let cuts = [150..<230, 650..<790, 1_210..<1_265]
            let removed = Set([sequence.blocks[3].id])
            let layout = try sequence.layout(removing: removed, excluding: cuts)
            let documentViewport = 120..<1_650
            let actual = Set(ScrollPreviewGeometry.project(documentViewport, into: layout).flatMap { Array($0) })
            // Independent coordinate reference enumerates retained document pixels.
            let documents = (sequence.lowerBound..<sequence.upperBound).filter { pixel in
                !cuts.contains { $0.contains(pixel) } && !sequence.blocks.contains {
                    removed.contains($0.id) && ($0.documentStart..<($0.documentStart + $0.length)).contains(pixel)
                }
            }
            let expected = Set(documents.enumerated().compactMap { documentViewport.contains($0.element) ? $0.offset : nil })
            XCTAssertEqual(actual, expected, axis.rawValue)
            XCTAssertGreaterThan(axis == .vertical ? layout.height : layout.width, 800)
            XCTAssertEqual(ScrollPreviewGeometry.project(-100..<0, into: layout), [])
        }
    }

    func testFractionalTransformsHitExactOutputPixelAndBandOnBothAxes() throws {
        for axis in ScrollAxis.allCases {
            let layout = try sequence(axis).layout(excluding: [150..<230, 650..<790])
            let output = CGSize(width: layout.width, height: layout.height)
            let viewport = CGRect(x: 11.25, y: 30.75, width: 233.5, height: 159.25)
            let center = CGPoint(x: output.width * 0.43, y: output.height * 0.61)
            for scale in [CGFloat(0.137), 0.625, 1.333] {
                let rect = ScrollPreviewGeometry.imageRect(output: output, viewport: viewport, scale: scale, center: center)
                let length = axis == .vertical ? layout.height : layout.width
                for pixel in [0, 151, 801, length - 1] {
                    let point = axis == .vertical
                        ? CGPoint(x: rect.midX, y: rect.minY + (CGFloat(pixel) + 0.5) * scale)
                        : CGPoint(x: rect.minX + (CGFloat(pixel) + 0.5) * scale, y: rect.midY)
                    XCTAssertEqual(ScrollPreviewGeometry.pixel(at: point, imageRect: rect, length: length, axis: axis), pixel)
                }
                let band = ScrollPreviewGeometry.bandRect(333..<888, imageRect: rect, length: length, axis: axis)
                XCTAssertEqual(axis == .vertical ? band.height : band.width, 555 * scale, accuracy: 0.000001)
                let visible = ScrollPreviewGeometry.visibleOutput(imageRect: rect, viewport: viewport, output: output)
                XCTAssertGreaterThan(visible.width, 0); XCTAssertGreaterThan(visible.height, 0)
                XCTAssertGreaterThanOrEqual(visible.minX, -0.000001); XCTAssertGreaterThanOrEqual(visible.minY, -0.000001)
                XCTAssertLessThanOrEqual(visible.maxX, output.width + 0.000001)
                XCTAssertLessThanOrEqual(visible.maxY, output.height + 0.000001)
            }
        }
    }

    func testFractionalAndLargeTileRequestsStayBounded() throws {
        for output in [CGSize(width: 1_800, height: 32_768), CGSize(width: 32_768, height: 1_800)] {
            for scale in [CGFloat(0.125), 0.625, 2] {
                let tile = try ScrollPreviewTileRequest(outputSize: output,
                    visibleRect: CGRect(x: 13.25, y: 22.75, width: output.width - 20.5, height: output.height - 40.25), displayScale: scale)
                XCTAssertEqual(tile.outputRect.minX, 13); XCTAssertEqual(tile.outputRect.minY, 22)
                XCTAssertLessThanOrEqual(tile.pixelWidth, 1_024); XCTAssertLessThanOrEqual(tile.pixelHeight, 1_024)
                XCTAssertLessThanOrEqual(tile.pixelWidth * tile.pixelHeight, 1_048_576)
            }
        }
        for scale in [CGFloat.infinity, .nan, 0, -1] {
            XCTAssertThrowsError(try ScrollPreviewTileRequest(outputSize: CGSize(width: 100, height: 1_600),
                visibleRect: CGRect(x: 0, y: 0, width: 50, height: 300), displayScale: scale))
        }
        XCTAssertThrowsError(try ScrollPreviewTileRequest(outputSize: CGSize(width: 10_000, height: 10_000),
            visibleRect: CGRect(x: 0, y: 0, width: 50, height: 300), displayScale: 1))
    }

    func testCenterClampsAtBothEdgesAndFitCentersCrossAxis() {
        let output = CGSize(width: 100, height: 2_000), viewport = CGRect(x: 5, y: 29, width: 250, height: 150)
        XCTAssertEqual(ScrollPreviewGeometry.clampedCenter(CGPoint(x: -900, y: -900), output: output, viewport: viewport, scale: 0.5), CGPoint(x: 50, y: 150))
        XCTAssertEqual(ScrollPreviewGeometry.clampedCenter(CGPoint(x: 9_000, y: 9_000), output: output, viewport: viewport, scale: 0.5), CGPoint(x: 50, y: 1_850))
    }
}
