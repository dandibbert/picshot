import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PicShot

final class ImageExportServiceTests: XCTestCase {
    func testEveryRasterReopensAsRequestedFormatAndExactDimensions() throws {
        let snapshot = try ImageExportSnapshot(image: fixture(width: 73, height: 61))
        for format in [ImageExportFormat.png, .jpeg, .tiff, .bmp] {
            let artifact = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: format))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(artifact.data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, format.contentType.identifier)
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 73); XCTAssertEqual(decoded.height, 61)
            XCTAssertEqual(artifact.byteCount, artifact.data.count)
            XCTAssertEqual(try pixels(artifact.firstPreview), try pixels(decoded), "Preview must be from the real encoded bytes: \(format)")
            let center = try pixel(decoded, x: 30, y: 25)
            XCTAssertLessThan(center[0], 8); XCTAssertLessThan(center[1], 8); XCTAssertLessThan(center[2], 8)
            let transparent = try pixel(decoded, x: 0, y: 0)
            if format.preservesAlpha { XCTAssertEqual(transparent[3], 0) }
            else { XCTAssertEqual(transparent[3], 255); XCTAssertGreaterThan(transparent[0], 245) }
            if format == .bmp { XCTAssertEqual(artifact.data.prefix(2), Data("BM".utf8)) }
        }
    }
    func testJPEGQualityChangesActualBytesAndDecodedPreview() throws {
        let image = try noise(width: 200, height: 140)
        let snapshot = try ImageExportSnapshot(image: image)
        let low = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: .jpeg, quality: 0.1))
        let high = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: .jpeg, quality: 0.95))
        XCTAssertLessThan(low.byteCount, high.byteCount)
        XCTAssertNotEqual(low.data, high.data)
        XCTAssertNotEqual(try pixels(low.firstPreview), try pixels(high.firstPreview))
    }
    func testSnapshotOwnsPixelsAndNoSourceLayersAreSerialized() throws {
        let image = try fixture(width: 50, height: 40)
        let snapshot = try ImageExportSnapshot(image: image)
        let bytes = try pixels(snapshot.image)
        let artifact = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions())
        XCTAssertEqual(try pixels(snapshot.image), bytes)
        XCTAssertNil(artifact.data.range(of: Data("ImageAnnotation".utf8)))
        XCTAssertEqual(try pixel(artifact.firstPreview, x: 25, y: 20), [0, 0, 0, 255])
    }
    func testSnapshotMaterializesMutableProviderPixels() throws {
        let width = 8, height = 8, count = width * height * 4
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        let bytes = storage.assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 0, to: count, by: 4) {
            bytes[offset] = 255; bytes[offset + 1] = 0; bytes[offset + 2] = 0; bytes[offset + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(dataInfo: nil, data: storage, size: count, releaseData: { _, pointer, _ in
            UnsafeMutableRawPointer(mutating: pointer).deallocate()
        }))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let snapshot = try ImageExportSnapshot(image: image)
        for offset in stride(from: 0, to: count, by: 4) { bytes[offset] = 0; bytes[offset + 2] = 255 }
        XCTAssertEqual(try pixel(snapshot.image, x: 3, y: 3), [255, 0, 0, 255])
        // The snapshot owns a different provider, regardless of whether native
        // drawing happens to cache the caller's subsequently mutated CGImage.
        XCTAssertFalse(snapshot.image.dataProvider === image.dataProvider)
    }

    func testPDFMediaBoxesMarginsAndRealPageCounts() throws {
        let snapshot = try ImageExportSnapshot(image: fixture(width: 570, height: 1901))
        for orientation in ImageExportOrientation.allCases {
            let options = ImageExportOptions(format: .pdf, paper: .letter, orientation: orientation, margin: 36)
            let artifact = try ImageExportService.encode(snapshot: snapshot, options: options)
            let provider = try XCTUnwrap(CGDataProvider(data: artifact.data as CFData))
            let document = try XCTUnwrap(CGPDFDocument(provider))
            let layout = try ImageExportPDFLayout.make(width: 570, height: 1901, options: options)
            XCTAssertEqual(document.numberOfPages, layout.pages.count)
            XCTAssertEqual(artifact.pageCount, layout.pages.count)
            for index in 1...document.numberOfPages {
                let page = try XCTUnwrap(document.page(at: index))
                XCTAssertEqual(page.getBoxRect(.mediaBox), layout.mediaBox)
                let raster = try render(page: page)
                XCTAssertEqual(try pixel(raster, x: 1, y: 1), [255, 255, 255, 255])
                let preview = try ImageExportService.preview(data: artifact.data, format: .pdf, page: index - 1)
                XCTAssertLessThanOrEqual(preview.width, 1024); XCTAssertLessThanOrEqual(preview.height, 1024)
            }
        }
    }
    func testPDFVerticalAndHorizontalSeamsMatchContiguousExactSourcePixels() throws {
        for vertical in [true, false] {
            let width = vertical ? 612 : 1301, height = vertical ? 1601 : 792
            let snapshot = try ImageExportSnapshot(image: noise(width: width, height: height))
            let options = ImageExportOptions(format: .pdf, paper: .letter, margin: 0,
                                             pagination: vertical ? .vertical : .horizontal)
            let artifact = try ImageExportService.encode(snapshot: snapshot, options: options)
            let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: artifact.data as CFData))))
            let layout = try ImageExportPDFLayout.make(width: width, height: height, options: options)
            XCTAssertEqual(layout.scale, 1)
            for (index, segment) in layout.pages.enumerated() {
                let page = try XCTUnwrap(document.page(at: index + 1)), raster = try render(page: page)
                let expected = try XCTUnwrap(snapshot.image.cropping(to: segment.source))
                // Convert PDF bottom-left bounds to CGImage top-left crop
                // coordinates before comparing *all* pixels on both seam sides.
                let topLeft = CGRect(x: segment.destination.minX,
                    y: CGFloat(raster.height) - segment.destination.maxY,
                    width: segment.destination.width, height: segment.destination.height)
                let actual = try XCTUnwrap(raster.cropping(to: topLeft))
                XCTAssertEqual(try pixels(actual), try pixels(expected), "Page \(index + 1), vertical \(vertical)")
            }
        }
    }
    func testSourceOutputPreviewAndPageResourceBounds() throws {
        let image = try fixture(width: 64, height: 64)
        var limits = ImageExportLimits.standard; limits.maximumSourcePixels = 4095
        XCTAssertThrowsError(try ImageExportSnapshot(image: image, limits: limits))
        let snapshot = try ImageExportSnapshot(image: image)
        limits = .standard; limits.maximumEncodedBytes = 12
        for format in ImageExportFormat.allCases {
            XCTAssertThrowsError(try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: format), limits: limits))
        }
        limits = .standard; limits.previewDimension = 16; limits.maximumPreviewBytes = 16 * 16 * 4
        let artifact = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(), limits: limits)
        XCTAssertLessThanOrEqual(artifact.firstPreview.width, 16)
        XCTAssertLessThanOrEqual(artifact.firstPreview.bytesPerRow * artifact.firstPreview.height, 1024)
        XCTAssertEqual(ImageExportService.queue.maxConcurrentOperationCount, 1)
    }
    func testCancelledPendingInputReleasesPayloadWithoutRunningQueuedBlock() {
        final class Payload {}
        var payload: Payload? = Payload()
        weak var weakPayload = payload
        let input = ImageExportJobInput(payload!)
        let suspended = OperationQueue(); suspended.isSuspended = true; suspended.maxConcurrentOperationCount = 1
        let operation = BlockOperation { _ = input.take() }
        suspended.addOperation(operation); payload = nil
        XCTAssertNotNil(weakPayload)
        operation.cancel(); input.clear()
        XCTAssertNil(weakPayload, "Cancelled queued blocks must not retain heavyweight snapshots/artifacts")
        XCTAssertNil(input.take())
        suspended.isSuspended = false
    }
    func testJobInputOwnershipTransfersOnlyOnce() {
        let input = ImageExportJobInput(42)
        XCTAssertEqual(input.take(), 42); XCTAssertNil(input.take())
        input.clear(); XCTAssertNil(input.take())
    }

    func testCancellationBeforeAndImmediatelyBeforeCommitPublishesNothing() throws {
        try withDirectory { directory in
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: fixture()), options: ImageExportOptions())
            let token = ImageExportCancellation(); token.cancel()
            XCTAssertThrowsError(try ImageExportService.encode(snapshot: ImageExportSnapshot(image: fixture()), options: ImageExportOptions(), cancellation: token))
            let destination = directory.appendingPathComponent("cancelled.png")
            XCTAssertThrowsError(try ImageExportService.publish(artifact, to: destination, cancellation: token))
            let late = ImageExportCancellation()
            XCTAssertThrowsError(try ImageExportService.publish(artifact, to: destination, cancellation: late, beforeCommit: { late.cancel() }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }
    func testExistingAndRacingDestinationNeverOverwritten() throws {
        try withDirectory { directory in
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: fixture()), options: ImageExportOptions())
            let destination = directory.appendingPathComponent("collision.png"), original = Data("keep-original".utf8)
            try original.write(to: destination)
            XCTAssertThrowsError(try ImageExportService.publish(artifact, to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), original)
            try FileManager.default.removeItem(at: destination)
            XCTAssertThrowsError(try ImageExportService.publish(artifact, to: destination, beforeCommit: { try original.write(to: destination) }))
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["collision.png"])
        }
    }
    func testSymlinkCollisionAndOriginalURLAreProtected() throws {
        try withDirectory { directory in
            let originalURL = directory.appendingPathComponent("original.png"), output = directory.appendingPathComponent("link.png")
            let original = Data("private original".utf8); try original.write(to: originalURL)
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: fixture(), sourceURL: originalURL), options: ImageExportOptions())
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: originalURL)
            XCTAssertThrowsError(try ImageExportService.publish(artifact, to: output))
            XCTAssertThrowsError(try ImageExportService.publish(artifact, to: originalURL))
            XCTAssertEqual(try Data(contentsOf: originalURL), original)
        }
    }
    func testSuccessfulAtomicPublicationHasExactPreviewedBytesNoStageFiles() throws {
        try withDirectory { directory in
            for format in ImageExportFormat.nativeFormats {
                let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: fixture()), options: ImageExportOptions(format: format))
                let destination = directory.appendingPathComponent("result.\(format.filenameExtension)")
                try ImageExportService.publish(artifact, to: destination)
                XCTAssertEqual(try Data(contentsOf: destination), artifact.data)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 5)
        }
    }
    func testWrongExtensionAndMalformedDecodedBytesFailClosed() throws {
        try withDirectory { directory in
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: fixture()), options: ImageExportOptions())
            XCTAssertThrowsError(try ImageExportService.publish(artifact, to: directory.appendingPathComponent("fake.jpg")))
            XCTAssertThrowsError(try ImageExportService.preview(data: Data("not an image".utf8), format: .png))
            XCTAssertThrowsError(try ImageExportService.verify(data: artifact.data, options: ImageExportOptions(format: .jpeg), width: artifact.width, height: artifact.height, expectedPages: 1))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    private func fixture(width: Int = 73, height: Int = 61) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 3, y: 3, width: width - 6, height: height - 6))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }
    private func noise(width: Int, height: Int) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            pointer[offset] = UInt8((x * 17 + y * 31) % 256)
            pointer[offset + 1] = UInt8((x * 53 + y * 7) % 256)
            pointer[offset + 2] = UInt8((x * 11 + y * 73) % 256); pointer[offset + 3] = 255
        } }
        return try XCTUnwrap(context.makeImage())
    }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        context.interpolationQuality = .none; context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        Array(try pixels(image)[((y * image.width + x) * 4)..<((y * image.width + x) * 4 + 4)])
    }
    private func render(page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.mediaBox), context = try bitmap(width: Int(box.width), height: Int(box.height))
        context.interpolationQuality = .none; context.drawPDFPage(page)
        return try XCTUnwrap(context.makeImage())
    }
    private func withDirectory(_ action: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }; try action(directory)
    }
}
