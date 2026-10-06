import XCTest
import AppKit
import CoreGraphics
import PicShotCore
@testable import PicShot

final class AdvancedCaptureTests: XCTestCase {
    func testAsymmetricTopLeftCropPreservesSourcePixelsAtUnequalScales() throws {
        let image = try coordinateImage(width: 80, height: 60)
        var selection = try CaptureSelectionGeometry(pointSize: CGSize(width: 40, height: 20), pixelWidth: 80, pixelHeight: 60)
        try selection.append(.rectangle(CGRect(x: 5, y: 3, width: 9, height: 7)))
        let result = try AdvancedSelectionRenderer.render(image: image, selection: selection)
        XCTAssertEqual(result.width, 18)
        XCTAssertEqual(result.height, 21)
        XCTAssertEqual(try pixel(result, x: 0, y: 0), coordinatePixel(x: 10, y: 9))
        XCTAssertEqual(try pixel(result, x: 17, y: 20), coordinatePixel(x: 27, y: 29))
        XCTAssertEqual(try pixel(result, x: 3, y: 16), coordinatePixel(x: 13, y: 25))
    }

    func testSeparatedRectanglesMaterializeTransparentGapsWithoutHiddenRGB() throws {
        let image = try coordinateImage(width: 80, height: 60)
        var selection = try CaptureSelectionGeometry(pointSize: CGSize(width: 80, height: 60), pixelWidth: 80, pixelHeight: 60)
        try selection.append(.rectangle(CGRect(x: 3, y: 7, width: 5, height: 4)))
        try selection.append(.rectangle(CGRect(x: 20, y: 18, width: 4, height: 6)))
        let result = try AdvancedSelectionRenderer.render(image: image, selection: selection)
        XCTAssertEqual(result.width, 21)
        XCTAssertEqual(result.height, 17)
        XCTAssertEqual(try pixel(result, x: 0, y: 0), coordinatePixel(x: 3, y: 7))
        XCTAssertEqual(try pixel(result, x: 19, y: 13), coordinatePixel(x: 22, y: 20))
        XCTAssertEqual(try pixel(result, x: 10, y: 8), [0, 0, 0, 0])
        XCTAssertEqual(try pixel(result, x: 1, y: 14), [0, 0, 0, 0])
        XCTAssertEqual(result.bytesPerRow, result.width * 4)
        let data = try XCTUnwrap(result.dataProvider?.data)
        XCTAssertEqual(CFDataGetLength(data), result.width * result.height * 4)
    }

    func testAsymmetricPolygonMaskAndImageUseTheSameTopRow() throws {
        let image = try coordinateImage(width: 80, height: 60)
        var selection = try CaptureSelectionGeometry(pointSize: CGSize(width: 40, height: 30), pixelWidth: 80, pixelHeight: 60)
        try selection.append(.polygon([CGPoint(x: 3, y: 4), CGPoint(x: 13, y: 4), CGPoint(x: 3, y: 17)]))
        let mask = try selection.rasterized()
        let result = try AdvancedSelectionRenderer.render(image: image, selection: selection)
        XCTAssertEqual(result.width, mask.width)
        XCTAssertEqual(result.height, mask.height)
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let expected = mask.alpha[y * mask.width + x] == 0 ? [UInt8](repeating: 0, count: 4) :
                    coordinatePixel(x: x + Int(mask.pixelBounds.minX), y: y + Int(mask.pixelBounds.minY))
                XCTAssertEqual(try pixel(result, x: x, y: y), expected, "Mask/image mismatch at \(x),\(y)")
            }
        }
    }

    func testSubtractionCutsTransparentHoleAndShrinksTheOutput() throws {
        let image = try coordinateImage(width: 80, height: 60)
        var selection = try CaptureSelectionGeometry(pointSize: CGSize(width: 80, height: 60), pixelWidth: 80, pixelHeight: 60)
        try selection.append(.rectangle(CGRect(x: 5, y: 9, width: 20, height: 16)))
        try selection.append(.rectangle(CGRect(x: 5, y: 9, width: 4, height: 16)), subtracts: true)
        try selection.append(.rectangle(CGRect(x: 13, y: 12, width: 5, height: 4)), subtracts: true)
        let result = try AdvancedSelectionRenderer.render(image: image, selection: selection)
        XCTAssertEqual(result.width, 16)
        XCTAssertEqual(result.height, 16)
        XCTAssertEqual(try pixel(result, x: 0, y: 0), coordinatePixel(x: 9, y: 9))
        XCTAssertEqual(try pixel(result, x: 5, y: 4), [0, 0, 0, 0])
        XCTAssertEqual(try pixel(result, x: 5, y: 12), coordinatePixel(x: 14, y: 21))
    }

    func testClosedFreehandOutlineUsesConcaveMaskInsteadOfBoundingBox() throws {
        let image = try coordinateImage(width: 80, height: 60)
        var selection = try CaptureSelectionGeometry(pointSize: CGSize(width: 80, height: 60), pixelWidth: 80, pixelHeight: 60)
        // A sampled freehand outline with an indentation and an explicit closing point.
        try selection.append(.polygon([CGPoint(x: 3, y: 6), CGPoint(x: 9, y: 6), CGPoint(x: 15, y: 6),
                                       CGPoint(x: 15, y: 10), CGPoint(x: 8, y: 10), CGPoint(x: 8, y: 18),
                                       CGPoint(x: 3, y: 18), CGPoint(x: 3, y: 6)]))
        let result = try AdvancedSelectionRenderer.render(image: image, selection: selection)
        XCTAssertEqual(try pixel(result, x: 8, y: 8), [0, 0, 0, 0])
        XCTAssertEqual(try pixel(result, x: 2, y: 8), coordinatePixel(x: 5, y: 14))
    }

    func testCancelledAndWrongSizedFramesCannotRender() throws {
        let image = try coordinateImage(width: 80, height: 60)
        var selection = try CaptureSelectionGeometry(pointSize: CGSize(width: 80, height: 60), pixelWidth: 80, pixelHeight: 60)
        try selection.append(.rectangle(CGRect(x: 0, y: 0, width: 4, height: 4)))
        let wrongImage = try coordinateImage(width: 60, height: 80)
        XCTAssertThrowsError(try AdvancedSelectionRenderer.render(image: wrongImage, selection: selection)) {
            XCTAssertEqual($0 as? CaptureSelectionError, .invalidCanvas)
        }
        selection.cancel()
        XCTAssertThrowsError(try AdvancedSelectionRenderer.render(image: image, selection: selection)) {
            XCTAssertEqual($0 as? CaptureSelectionError, .cancelled)
        }
    }

    @MainActor
    func testEscapeFinishesOnceAndDiscardLeavesNoReusableSelection() throws {
        _ = NSApplication.shared
        let image = try coordinateImage(width: 80, height: 60)
        var geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 80, height: 60), pixelWidth: 80, pixelHeight: 60)
        try geometry.append(.rectangle(CGRect(x: 3, y: 7, width: 4, height: 8)))
        let view = AdvancedSelectionView(frame: CGRect(x: 0, y: 0, width: 80, height: 60), image: image, style: .multiRegion, geometry: geometry)
        var finishes = 0
        view.finished = { result in
            finishes += 1
            if case .success = result { XCTFail("Escape must cancel") }
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        view.keyDown(with: escape)
        XCTAssertEqual(finishes, 1)
        XCTAssertTrue(view.selection.isCancelled)
        XCTAssertTrue(view.selection.operations.isEmpty)
        view.discard()
        view.discard()
        XCTAssertNil(view.finished)
        XCTAssertTrue(view.selection.isCancelled)
        XCTAssertThrowsError(try view.selection.rasterized())
    }

    /// A direct top-row-first RGBA fixture avoids relying on CGContext coordinate
    /// conventions while building the expected image. Both axes are asymmetric.
    private func coordinateImage(width: Int, height: Int) throws -> CGImage {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes.append(contentsOf: coordinatePixel(x: x, y: y)) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: colorSpace,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func coordinatePixel(x: Int, y: Int) -> [UInt8] {
        [UInt8((x * 3 + 17) % 256), UInt8((y * 4 + 31) % 256), UInt8((x + y * 2 + 43) % 256), 255]
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 4))
    }
}
