import XCTest
@testable import PicShotEraseCore

final class SmartEraseMaskTests: XCTestCase {
    func testCapsuleHasNoFastDragGapsAndUndoIsStrokeBased() throws {
        let stroke = SmartEraseStroke(points: [.init(x: 2, y: 5), .init(x: 98, y: 5)], width: 4)
        let mask = try SmartEraseMask.rasterize(width: 100, height: 20, strokes: [stroke])
        for x in 2..<98 { XCTAssertEqual(mask[5 * 100 + x], 255) }
        XCTAssertEqual(mask[15 * 100 + 50], 0)
        XCTAssertTrue(try SmartEraseMask.rasterize(width: 100, height: 20, strokes: []).allSatisfy { $0 == 0 })
    }
    func testDimensionAndStrokeBounds() {
        XCTAssertThrowsError(try SmartEraseMask.validateDimensions(width: Int.max, height: 2))
        XCTAssertThrowsError(try SmartEraseMask.validateDimensions(width: 8_192, height: 8_192))
        XCTAssertThrowsError(try SmartEraseMask.rasterize(width: 20, height: 20, strokes: [.init(points: [.init(x: .nan, y: 1)], width: 20)]))
        XCTAssertThrowsError(try SmartEraseMask.rasterize(width: 20, height: 20, strokes: [.init(points: [.init(x: 1, y: 1)], width: .infinity)]))
    }
    func testMaskRejectsEmptyFullAndNonBinary() {
        XCTAssertThrowsError(try SmartEraseMask.crop(width: 10, height: 10, mask: Data(repeating: 0, count: 100)))
        XCTAssertThrowsError(try SmartEraseMask.crop(width: 10, height: 10, mask: Data(repeating: 255, count: 100)))
        var mask = Data(repeating: 0, count: 100); mask[0] = 1
        XCTAssertThrowsError(try SmartEraseMask.crop(width: 10, height: 10, mask: mask))
    }
    func testNonSquareImageAndEdgeMasksStayInsideCrop() throws {
        var mask = Data(repeating: 0, count: 1_200 * 200); mask[1_199] = 255; mask[199 * 1_200] = 255
        let crop = try SmartEraseMask.crop(width: 1_200, height: 200, mask: mask)
        XCTAssertEqual(crop, .init(x: 0, y: 0, side: 1_200))
        let model = try SmartEraseMask.modelMask(width: 1_200, height: 200, mask: mask, crop: crop)
        XCTAssertEqual(model[799], 255)
        XCTAssertGreaterThan(model.filter { $0 > 0 }.count, 1)
    }
    func testThinMaskSurvivesReduction() throws {
        var mask = Data(repeating: 0, count: 4_000 * 2_000); mask[1_001 * 4_000 + 2_003] = 255
        let model = try SmartEraseMask.modelMask(width: 4_000, height: 2_000, mask: mask, crop: .init(x: 0, y: 0, side: 4_000))
        XCTAssertEqual(model.filter { $0 > 0 }.count, 1)
    }
    func testMarkedEdgesExtendIntoReplicatedPadding() throws {
        var bottom = Data(repeating: 0, count: 1_200 * 200); bottom[199 * 1_200 + 10] = 255
        let bottomMask = try SmartEraseMask.modelMask(width: 1_200, height: 200, mask: bottom, crop: .init(x: 0, y: 0, side: 512))
        XCTAssertEqual(bottomMask[799 * 800 + 15], 255)
        XCTAssertEqual(bottomMask[799 * 800 + 30], 0)
        var right = Data(repeating: 0, count: 200 * 1_200); right[10 * 200 + 199] = 255
        let rightMask = try SmartEraseMask.modelMask(width: 200, height: 1_200, mask: right, crop: .init(x: 0, y: 0, side: 512))
        XCTAssertEqual(rightMask[15 * 800 + 799], 255)
        XCTAssertEqual(rightMask[30 * 800 + 799], 0)
    }

    func testUpsampledMaskIncludesBilinearSourceSupport() throws {
        var mask = Data(repeating: 0, count: 512 * 512); mask[100 * 512 + 100] = 255
        let result = try SmartEraseMask.modelMask(width: 512, height: 512, mask: mask, crop: .init(x: 0, y: 0, side: 512))
        for y in 155...158 { for x in 155...158 { XCTAssertEqual(result[y * 800 + x], 255) } }
        XCTAssertEqual(result[154 * 800 + 154], 0)
    }

}
