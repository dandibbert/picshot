import XCTest
import AppKit
import CoreGraphics
import PicShotCore
@testable import PicShot

final class FrozenCaptureTests: XCTestCase {
    func testRetinaCropAndPlacementShareTheSameAlignedPixels() throws {
        let original = try coordinateImage(width: 20, height: 16)
        let display = CGRect(x: -100, y: 200, width: 10, height: 8)
        let capture = try CapturedImage.frozenRegion(image: original, displayID: 77, displayFrame: display,
                                                    selection: CGRect(x: 1.25, y: 2.75, width: 3.5, height: 2.25))
        let presentation = try XCTUnwrap(capture.presentation)
        XCTAssertTrue(presentation.frozenImage === original)
        XCTAssertEqual(presentation.displayID, 77)
        XCTAssertEqual(presentation.displayFrame, display)
        XCTAssertEqual(presentation.selectionFrame, CGRect(x: 1, y: 3, width: 4, height: 2.5))
        XCTAssertEqual(capture.image.width, 8)
        XCTAssertEqual(capture.image.height, 5)
        XCTAssertEqual(capture.image.bytesPerRow, 8 * 4)
        let outputData = try XCTUnwrap(capture.image.dataProvider?.data)
        XCTAssertEqual(CFDataGetLength(outputData), 8 * 5 * 4)
        let raster = try materialize(capture.image)
        for y in 0..<5 { for x in 0..<8 {
            XCTAssertEqual(try pixel(raster, x: x, y: y), coordinatePixel(x: x + 2, y: y + 5))
        } }
        XCTAssertEqual(presentation.selectionFrame.offsetBy(dx: display.minX, dy: display.minY),
                       CGRect(x: -99, y: 203, width: 4, height: 2.5))
    }

    func testTopAndBottomSelectionsKeepImageOrientation() throws {
        let original = try coordinateImage(width: 8, height: 12)
        let display = CGRect(x: 350, y: -600, width: 4, height: 6)
        for top in [CGFloat(0), 4] {
            let capture = try CapturedImage.frozenRegion(image: original, displayID: 9, displayFrame: display,
                                                        selection: CGRect(x: 0, y: top, width: 4, height: 2))
            XCTAssertEqual(capture.presentation?.selectionFrame, CGRect(x: 0, y: 4 - top, width: 4, height: 2))
            let raster = try materialize(capture.image)
            XCTAssertEqual(try pixel(raster, x: 0, y: 0), coordinatePixel(x: 0, y: Int(top * 2)))
            XCTAssertEqual(try pixel(raster, x: 7, y: 3), coordinatePixel(x: 7, y: Int(top * 2) + 3))
        }
    }

    func testActualSourceDimensionsControlFractionalAndIndependentDensities() throws {
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 100, height: 80), pixelWidth: 150, pixelHeight: 200)
        let selection = try geometry.alignedSelection(CGRect(x: 10.25, y: 20.25, width: 30.25, height: 25.25))
        XCTAssertEqual(selection.pixelFrame, CGRect(x: 15, y: 50, width: 46, height: 64))
        XCTAssertEqual(selection.topLeftFrame.minX, 10)
        XCTAssertEqual(selection.topLeftFrame.minY, 20)
        XCTAssertEqual(selection.selectionFrame.minY, 34.4, accuracy: 0.000_001)
        XCTAssertEqual(selection.selectionFrame.width, 46 / 1.5, accuracy: 0.000_001)
        XCTAssertEqual(selection.selectionFrame.height, 25.6, accuracy: 0.000_001)
    }

    func testSelectionClampsToOneDisplayWithoutMovingItsOrigin() throws {
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 100, height: 80), pixelWidth: 200, pixelHeight: 160)
        let selection = try geometry.alignedSelection(CGRect(x: -10, y: 75, width: 25, height: 30))
        XCTAssertEqual(selection.pixelFrame, CGRect(x: 0, y: 150, width: 30, height: 10))
        XCTAssertEqual(selection.selectionFrame, CGRect(x: 0, y: 0, width: 15, height: 5))
        let full = try geometry.alignedSelection(CGRect(x: -20, y: -30, width: 200, height: 200))
        XCTAssertEqual(full.pixelFrame, CGRect(x: 0, y: 0, width: 200, height: 160))
        XCTAssertEqual(full.selectionFrame, CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testTinyEmptyNonfiniteAndOutsideSelectionsAreRejected() throws {
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 100, height: 80), pixelWidth: 200, pixelHeight: 160)
        for rectangle in [CGRect.zero, CGRect(x: 10, y: 10, width: 1.99, height: 5),
                          CGRect(x: 200, y: 200, width: 20, height: 20),
                          CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20),
                          CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20)] {
            XCTAssertThrowsError(try geometry.alignedSelection(rectangle))
        }
    }

    func testSourceLimitsAreCheckedWithoutAllocatingPixels() throws {
        let points = CGSize(width: 100, height: 80)
        XCTAssertNoThrow(try FrozenCaptureGeometry(pointSize: points, pixelWidth: 10_000, pixelHeight: 6_400))
        for (width, height) in [(10_000, 6_401), (32_769, 1), (Int.max, 2), (0, 2)] {
            XCTAssertThrowsError(try FrozenCaptureGeometry(pointSize: points, pixelWidth: width, pixelHeight: height)) {
                XCTAssertEqual($0 as? DisplayCompositeError, .pixelLimit)
            }
        }
        XCTAssertThrowsError(try FrozenCaptureGeometry(pointSize: CGSize(width: CGFloat.nan, height: 80), pixelWidth: 20, pixelHeight: 16))
    }

    @MainActor
    func testSelectorPassesRawRetinaSelectionToTheSingleFinalAlignment() throws {
        _ = NSApplication.shared
        let image = try coordinateImage(width: 200, height: 160)
        let geometry = try FrozenCaptureGeometry(pointSize: CGSize(width: 100, height: 80), pixelWidth: 200, pixelHeight: 160)
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 100, height: 80), frozenImage: image, geometry: geometry)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.discard(); window.close() }
        var result: CGRect?
        view.finished = { result = try? $0.get() }
        let start = CGPoint(x: 10.25, y: 20.75), end = CGPoint(x: 24.75, y: 29.25)
        view.mouseDown(with: try mouse(.leftMouseDown, point: start, in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: end, in: view))
        XCTAssertEqual(result, CGRect(x: 10.25, y: 20.75, width: 14.5, height: 8.5))
        let capture = try CapturedImage.frozenRegion(image: image, displayID: 1, displayFrame: view.bounds,
                                                    selection: XCTUnwrap(result))
        XCTAssertEqual(capture.presentation?.selectionFrame, CGRect(x: 10, y: 50.5, width: 15, height: 9))
    }

    @MainActor
    func testRecordingSelectorStillReturnsTopLeftIntegralPoints() throws {
        _ = NSApplication.shared
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.discard(); window.close() }
        var result: CGRect?
        view.finished = { result = try? $0.get() }
        view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: 24.75, y: 29.25), in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 10.25, y: 20.75), in: view))
        XCTAssertEqual(result, CGRect(x: 10, y: 20, width: 15, height: 10))
    }

    @MainActor
    func testRepeatedEditingDelayCancellationNeverRequestsScreenAccess() async throws {
        let service = CaptureService()
        for mode in CaptureMode.allCases {
            for _ in 0..<3 {
                let task = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await service.captureForEditing(mode: mode, options: .init(delay: .tenSeconds))
                }
                do { _ = try await task.value; XCTFail("Cancelled request returned a capture") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
        }
    }

    @MainActor
    func testNativeSelectionRepeatedCancellationAndDisplayChangeReleaseContinuation() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("Requires a WindowServer display") }
        let controller = RegionSelectionController(screen: screen)
        for iteration in 0..<6 {
            let task = Task { @MainActor in try await controller.select() }
            guard await waitForSelection(controller) else {
                task.cancel(); _ = try? await task.value
                XCTFail("Selector did not present"); return
            }
            if iteration.isMultiple(of: 2) {
                task.cancel()
                controller.cancel()
                controller.cancel()
            } else {
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            }
            do { _ = try await task.value; XCTFail("Interrupted selection returned pixels") }
            catch let error as CaptureError {
                switch error {
                case .cancelled, .noDisplay: break
                default: XCTFail("Unexpected failure: \(error)")
                }
            } catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertFalse(controller.isSelecting)
        }
    }

    @MainActor
    private func waitForSelection(_ controller: RegionSelectionController) async -> Bool {
        for _ in 0..<100 {
            if controller.isSelecting { return true }
            await Task.yield()
        }
        return false
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, point: CGPoint, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func coordinateImage(width: Int, height: Int) throws -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<height { for x in 0..<width { bytes.append(contentsOf: coordinatePixel(x: x, y: y)) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func coordinatePixel(x: Int, y: Int) -> [UInt8] {
        [UInt8((x * 3 + 17) % 256), UInt8((y * 4 + 31) % 256), UInt8((x + y * 2 + 43) % 256), 255]
    }

    private func materialize(_ image: CGImage) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        return Array(UnsafeBufferPointer(start: bytes.advanced(by: y * image.bytesPerRow + x * 4), count: 4))
    }
}
