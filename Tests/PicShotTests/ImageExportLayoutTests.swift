import XCTest
@testable import PicShot

final class ImageExportLayoutTests: XCTestCase {
    func testLegacyFormatIndexesRemainStable() {
        XCTAssertEqual(ImageExportFormat(rawValue: 0), .png)
        XCTAssertEqual(ImageExportFormat(rawValue: 1), .jpeg)
        XCTAssertEqual(ImageExportFormat(rawValue: 2), .tiff)
        XCTAssertEqual(ImageExportFormat(rawValue: 3), .pdf)
        XCTAssertEqual(ImageExportFormat(rawValue: 4), .bmp)
    }
    func testImageSizedPDFRemainsOneUnscaledPage() throws {
        let layout = try ImageExportPDFLayout.make(width: 79, height: 901, options: ImageExportOptions(format: .pdf))
        XCTAssertEqual(layout.mediaBox, CGRect(x: 0, y: 0, width: 79, height: 901))
        XCTAssertEqual(layout.pages, [ImageExportPDFPage(source: layout.mediaBox, destination: layout.mediaBox)])
        XCTAssertEqual(layout.scale, 1)
    }
    func testVerticalPagesCoverEveryRowExactlyOnce() throws {
        for paper in [ImageExportPaper.a4, .letter] {
            for orientation in ImageExportOrientation.allCases {
                for margin in [0.0, 24, 72, 144] {
                    let options = ImageExportOptions(format: .pdf, paper: paper, orientation: orientation, margin: margin)
                    let layout = try ImageExportPDFLayout.make(width: 733, height: 18_789, options: options)
                    try assertCoverage(layout, width: 733, height: 18_789, vertical: true, margin: margin)
                }
            }
        }
    }
    func testHorizontalPagesCoverEveryColumnExactlyOnce() throws {
        for orientation in ImageExportOrientation.allCases {
            let options = ImageExportOptions(format: .pdf, paper: .letter, orientation: orientation, margin: 36, pagination: .horizontal)
            let layout = try ImageExportPDFLayout.make(width: 9_113, height: 777, options: options)
            try assertCoverage(layout, width: 9_113, height: 777, vertical: false, margin: 36)
        }
    }
    func testExactPageBoundaryDoesNotAddBlankPage() throws {
        let options = ImageExportOptions(format: .pdf, paper: .letter, margin: 0)
        let layout = try ImageExportPDFLayout.make(width: 612, height: 1_584, options: options)
        XCTAssertEqual(layout.pages.count, 2)
        XCTAssertEqual(layout.pages.map(\.source.height), [792, 792])
    }
    func testLastPartialPageStaysTopAlignedAndUnstretched() throws {
        let layout = try ImageExportPDFLayout.make(width: 612, height: 793,
            options: ImageExportOptions(format: .pdf, paper: .letter, margin: 0))
        XCTAssertEqual(layout.pages.count, 2)
        XCTAssertEqual(layout.pages[1].source, CGRect(x: 0, y: 792, width: 612, height: 1))
        XCTAssertEqual(layout.pages[1].destination, CGRect(x: 0, y: 791, width: 612, height: 1))
    }
    func testOrientationSwapsMediaBoxOnly() throws {
        let layout = try ImageExportPDFLayout.make(width: 42, height: 50,
            options: ImageExportOptions(format: .pdf, paper: .letter, orientation: .landscape, margin: 12))
        XCTAssertEqual(layout.mediaBox.size, CGSize(width: 792, height: 612))
    }
    func testInvalidDimensionsQualityMarginAndLimitsRejectBeforeAllocation() {
        for pair in [(0, 1), (1, 0), (-1, 8), (Int.max, 2), (1, Int.max)] {
            XCTAssertThrowsError(try ImageExportPDFLayout.make(width: pair.0, height: pair.1, options: ImageExportOptions()))
        }
        for value in [Double.nan, .infinity, -1, 1.1] {
            XCTAssertThrowsError(try ImageExportOptions(quality: value).validate())
        }
        for value in [Double.nan, .infinity, -1, 145] {
            XCTAssertThrowsError(try ImageExportOptions(margin: value).validate())
        }
        var limits = ImageExportLimits.standard; limits.maximumPages = 0
        XCTAssertThrowsError(try limits.validate())
        limits = .standard; limits.previewDimension = Int.max
        XCTAssertThrowsError(try limits.validate())
    }
    func testExcessivePageCountFailsWithoutBuildingArray() {
        XCTAssertThrowsError(try ImageExportPDFLayout.make(width: 1, height: 100_000,
            options: ImageExportOptions(format: .pdf, paper: .letter)))
    }
    private func assertCoverage(_ layout: ImageExportPDFLayout, width: Int, height: Int, vertical: Bool, margin: Double) throws {
        XCTAssertGreaterThan(layout.pages.count, 1)
        var end: CGFloat = 0
        for page in layout.pages {
            XCTAssertEqual(vertical ? page.source.minY : page.source.minX, end)
            XCTAssertEqual(page.source.origin.x.rounded(), page.source.origin.x)
            XCTAssertEqual(page.source.origin.y.rounded(), page.source.origin.y)
            XCTAssertEqual(vertical ? page.source.width : page.source.height, CGFloat(vertical ? width : height))
            XCTAssertEqual(page.destination.minX, CGFloat(margin), accuracy: 0.001)
            XCTAssertEqual(page.destination.maxY, layout.mediaBox.height - CGFloat(margin), accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(page.destination.minY, CGFloat(margin) - 0.001)
            XCTAssertLessThanOrEqual(page.destination.maxX, layout.mediaBox.width - CGFloat(margin) + 0.001)
            end = vertical ? page.source.maxY : page.source.maxX
        }
        XCTAssertEqual(end, CGFloat(vertical ? height : width))
    }
}
