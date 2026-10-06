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

    func testFrozenPixelSamplerUsesTopLeftPixelsAndTinyIndependentPatches() throws {
        let image = try coordinateImage(width: 80, height: 60)
        let sampler = FrozenCapturePixelSampler(image: image)
        for coordinate in [CapturePixelCoordinate(x: 10, y: 9), CapturePixelCoordinate(x: 0, y: 0),
                           CapturePixelCoordinate(x: 79, y: 59), CapturePixelCoordinate(x: 0, y: 47)] {
            let sample = try XCTUnwrap(sampler.sample(at: coordinate))
            let expected = coordinatePixel(x: coordinate.x, y: coordinate.y)
            XCTAssertEqual(sample.color, CapturePixelColor(red: Int(expected[0]), green: Int(expected[1]), blue: Int(expected[2])))
            XCTAssertLessThanOrEqual(sample.image.width, 9)
            XCTAssertLessThanOrEqual(sample.image.height, 9)
            XCTAssertEqual(sample.image.bytesPerRow, sample.image.width * 4)
            let data = try XCTUnwrap(sample.image.dataProvider?.data)
            XCTAssertLessThanOrEqual(CFDataGetLength(data), 324)
            for y in 0..<sample.image.height {
                for x in 0..<sample.image.width {
                    XCTAssertEqual(try pixel(sample.image, x: x, y: y),
                                   coordinatePixel(x: x + Int(sample.pixelBounds.minX), y: y + Int(sample.pixelBounds.minY)))
                }
            }
        }
        XCTAssertNil(sampler.sample(at: CapturePixelCoordinate(x: -1, y: 0)))
        XCTAssertNil(sampler.sample(at: CapturePixelCoordinate(x: 80, y: 0)))
        XCTAssertNil(sampler.sample(at: CapturePixelCoordinate(x: 0, y: 60)))
        XCTAssertNil(sampler.sample(at: CapturePixelCoordinate(x: Int.max, y: Int.max)))
    }

    func testFrozenPixelSamplerConvertsGrayscaleAndHandlesTinyImages() throws {
        let data = Data([UInt8(255), 0, 64, 128])
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
                                         bytesPerRow: 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let sampler = FrozenCapturePixelSampler(image: image)
        XCTAssertEqual(try XCTUnwrap(sampler.sample(at: CapturePixelCoordinate(x: 0, y: 0))).color.hex, "#FFFFFF")
        XCTAssertEqual(try XCTUnwrap(sampler.sample(at: CapturePixelCoordinate(x: 1, y: 0))).color.hex, "#000000")
        let gray = try XCTUnwrap(sampler.sample(at: CapturePixelCoordinate(x: 0, y: 1)))
        XCTAssertEqual(gray.image.width, 2)
        XCTAssertEqual(gray.image.height, 2)
        XCTAssertEqual(gray.color.red, gray.color.green)
        XCTAssertEqual(gray.color.green, gray.color.blue)
        XCTAssertEqual(gray.color.hsv.saturation, 0)
        XCTAssertEqual(gray.color.hsl.saturation, 0)
    }

    @MainActor
    func testKeyboardPixelNudgeResizeDeleteAndUndoOperateOnRealSelection() throws {
        _ = NSApplication.shared
        var geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 400, height: 300), pixelWidth: 800, pixelHeight: 900)
        try geometry.append(.rectangle(CGRect(x: 20, y: 180, width: 40, height: 30)))
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize),
                                         image: try coordinateImage(width: 800, height: 900), style: .multiRegion, geometry: geometry)
        view.keyDown(with: try key(124))
        XCTAssertEqual(try view.selection.rasterized().pixelBounds, CGRect(x: 41, y: 540, width: 80, height: 90))
        view.keyDown(with: try key(125, flags: .option))
        XCTAssertEqual(try view.selection.rasterized().pixelBounds, CGRect(x: 41, y: 540, width: 80, height: 91))
        view.keyDown(with: try key(123, flags: .shift))
        XCTAssertEqual(try view.selection.rasterized().pixelBounds, CGRect(x: 31, y: 540, width: 80, height: 91))
        view.keyDown(with: try key(6, flags: .command))
        XCTAssertEqual(try view.selection.rasterized().pixelBounds, CGRect(x: 41, y: 540, width: 80, height: 91))
        let beforeRemoval = view.selection.operations
        view.keyDown(with: try key(51))
        XCTAssertTrue(view.selection.operations.isEmpty)
        view.keyDown(with: try key(6, flags: .command))
        XCTAssertEqual(view.selection.operations, beforeRemoval)
        view.discard()
        view.keyDown(with: try key(6, flags: .command))
        view.keyDown(with: try key(124))
        XCTAssertTrue(view.selection.isCancelled)
        XCTAssertTrue(view.selection.operations.isEmpty)
    }

    @MainActor
    func testClickSelectsAnEarlierRectangleWithoutAddingAShape() throws {
        _ = NSApplication.shared
        var geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 400, height: 300), pixelWidth: 800, pixelHeight: 600)
        try geometry.append(.rectangle(CGRect(x: 20, y: 180, width: 40, height: 40)))
        try geometry.append(.rectangle(CGRect(x: 100, y: 180, width: 40, height: 40)), subtracts: true)
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize),
                                         image: try coordinateImage(width: 800, height: 600), style: .multiRegion, geometry: geometry)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.discard(); window.close() }
        view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: 30, y: 200), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 30, y: 200), in: view))
        XCTAssertEqual(view.selectedOperationIndex, 0)
        XCTAssertEqual(view.selection.operations, geometry.operations)
        view.keyDown(with: try key(124))
        XCTAssertEqual(view.selection.operations[1], geometry.operations[1])
        XCTAssertEqual(view.selection.operations[0].shape.bounds.origin.x, 20.5)
        view.keyDown(with: try key(117))
        XCTAssertEqual(view.selection.operations, [geometry.operations[1]])
        view.keyDown(with: try key(6, flags: .command))
        XCTAssertEqual(view.selection.operations.count, 2)
    }

    @MainActor
    func testNumericDimensionsApplyAndClearCanBeUndone() throws {
        _ = NSApplication.shared
        var geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 400, height: 300), pixelWidth: 800, pixelHeight: 600)
        try geometry.append(.rectangle(CGRect(x: 20, y: 180, width: 40, height: 30)))
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize),
                                         image: try coordinateImage(width: 800, height: 600), style: .multiRegion, geometry: geometry)
        let controls = descendants(of: view)
        let width = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "capturePixelWidth" } as? NSTextField)
        let height = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "capturePixelHeight" } as? NSTextField)
        let apply = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Apply px" })
        let clear = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Clear" })
        var finishes = 0
        view.finished = { _ in finishes += 1 }
        width.stringValue = "101"; height.stringValue = "73"
        apply.performClick(nil)
        XCTAssertEqual(try view.selection.rasterized().pixelBounds, CGRect(x: 40, y: 360, width: 101, height: 73))
        XCTAssertEqual(finishes, 0)
        let applied = view.selection.operations
        width.stringValue = "1.5"
        apply.performClick(nil)
        XCTAssertEqual(view.selection.operations, applied)
        clear.performClick(nil)
        XCTAssertTrue(view.selection.operations.isEmpty)
        view.keyDown(with: try key(6, flags: .command))
        XCTAssertEqual(view.selection.operations, applied)
        view.keyDown(with: try key(6, flags: .command))
        XCTAssertEqual(view.selection.operations, geometry.operations)
        view.discard()
    }

    @MainActor
    func testRemovingPolygonVertexCanBeUndoneBeforeCapture() throws {
        _ = NSApplication.shared
        let geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 400, height: 300), pixelWidth: 800, pixelHeight: 600)
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize),
                                         image: try coordinateImage(width: 800, height: 600), style: .polygon, geometry: geometry)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.discard(); window.close() }
        let points = [CGPoint(x: 20, y: 180), CGPoint(x: 50, y: 180), CGPoint(x: 20, y: 230)]
        for point in points { view.mouseDown(with: try mouse(.leftMouseDown, point: point, in: view)) }
        view.keyDown(with: try key(51))
        view.keyDown(with: try key(6, flags: .command))
        var captured: CaptureSelectionGeometry?
        view.finished = { result in captured = try? result.get() }
        view.keyDown(with: try key(36))
        XCTAssertEqual(try XCTUnwrap(captured).operations, [CaptureSelectionOperation(shape: .polygon(points))])
    }

    @MainActor
    func testNumericFieldReturnAppliesWithoutCapturingAndEscapeCancels() throws {
        _ = NSApplication.shared
        var geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 400, height: 300), pixelWidth: 800, pixelHeight: 600)
        try geometry.append(.rectangle(CGRect(x: 20, y: 180, width: 40, height: 30)))
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize),
                                         image: try coordinateImage(width: 800, height: 600), style: .multiRegion, geometry: geometry)
        let controls = descendants(of: view)
        let width = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "capturePixelWidth" } as? NSTextField)
        let editor = NSTextView()
        editor.string = "101"
        var finishes = 0
        view.finished = { _ in finishes += 1 }
        XCTAssertTrue(view.control(width, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(try view.selection.rasterized().pixelBounds, CGRect(x: 40, y: 360, width: 101, height: 60))
        XCTAssertEqual(finishes, 0)
        XCTAssertTrue(view.control(width, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(view.selection.isCancelled)
        XCTAssertEqual(finishes, 1)
        view.discard()
    }

    @MainActor
    func testFreehandReplacementUndoRestoresPriorOutlineAndHUDDiscards() throws {
        _ = NSApplication.shared
        let geometry = try CaptureSelectionGeometry(pointSize: CGSize(width: 400, height: 300), pixelWidth: 800, pixelHeight: 600)
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: geometry.pointSize),
                                         image: try coordinateImage(width: 800, height: 600), style: .freehand, geometry: geometry)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.discard(); window.close() }
        func outline(x: CGFloat) throws {
            view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: x, y: 180), in: view))
            for point in [CGPoint(x: x + 30, y: 180), CGPoint(x: x + 30, y: 230), CGPoint(x: x, y: 230)] {
                view.mouseDragged(with: try mouse(.leftMouseDragged, point: point, in: view))
            }
            view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: x, y: 180), in: view))
        }
        try outline(x: 20)
        let firstOutline = view.selection.operations
        try outline(x: 90)
        XCTAssertNotEqual(view.selection.operations, firstOutline)
        view.keyDown(with: try key(6, flags: .command))
        XCTAssertEqual(view.selection.operations, firstOutline)
        let hud = try XCTUnwrap(view.subviews.compactMap { $0 as? CapturePrecisionHUD }.first)
        XCTAssertNotNil(hud.sample)
        XCTAssertNil(hud.hitTest(CGPoint(x: 1, y: 1)))
        view.keyDown(with: try key(48))
        XCTAssertTrue(hud.isHidden)
        view.keyDown(with: try key(48))
        XCTAssertFalse(hud.isHidden)
        view.discard()
        XCTAssertNil(hud.sample)
        XCTAssertTrue(hud.isHidden)
        view.keyDown(with: try key(6, flags: .command))
        XCTAssertTrue(view.selection.operations.isEmpty)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: code))
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, point: CGPoint, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
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
