import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import PicShotCodecCore
@testable import PicShot

final class ImageExportPNGStagingTests: XCTestCase {
    func testStagingHasExactOrdinaryAndReferencePNGBytesAndSourcePixels() throws {
        for (width, height) in [(73, 61), (1031, 19), (17, 1033)] {
            let snapshot = try ImageExportSnapshot(image: fixture(width: width, height: height))
            let originalPixels = try pixels(snapshot.image)
            let staged = try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot)
            let ordinary = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions())
            XCTAssertEqual(staged, ordinary.data)
            XCTAssertEqual(staged, try referencePNG(snapshot.image), "Keep the original PNG writer options")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(staged as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, width)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, height)
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(try pixels(decoded), originalPixels, "Preserve orientation, partial alpha and opaque detail")
            XCTAssertEqual(try pixels(snapshot.image), originalPixels)
            // Ordinary callers retain the real byte-derived bounded preview.
            let preview = try ImageExportService.preview(data: staged, format: .png)
            XCTAssertEqual(ordinary.firstPreview.width, preview.width)
            XCTAssertEqual(ordinary.firstPreview.height, preview.height)
            XCTAssertEqual(try pixels(ordinary.firstPreview), try pixels(preview))
            XCTAssertLessThanOrEqual(max(preview.width, preview.height), ImageExportLimits.standard.previewDimension)
        }
    }

    func testStagingKeepsInclusiveSourceAndEncodedByteCaps() throws {
        let snapshot = try ImageExportSnapshot(image: fixture(width: 73, height: 61))
        let expected = try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot)
        var limits = ImageExportLimits.standard
        limits.maximumSourcePixels = 73 * 61
        limits.maximumEncodedBytes = expected.count
        XCTAssertEqual(try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot, limits: limits), expected)
        limits.maximumSourcePixels -= 1
        XCTAssertThrowsError(try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot, limits: limits)) {
            guard case ImageExportError.sourceTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        limits.maximumSourcePixels += 1; limits.maximumEncodedBytes -= 1
        XCTAssertThrowsError(try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot, limits: limits)) {
            guard case ImageExportError.outputTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testStagingKeepsLimitValidationAndPreCancelledFailure() throws {
        let snapshot = try ImageExportSnapshot(image: fixture())
        for invalidField in 0..<5 {
            var limits = ImageExportLimits.standard
            switch invalidField {
            case 0: limits.maximumSourcePixels = 0
            case 1: limits.maximumEncodedBytes = 0
            case 2: limits.maximumPages = 0
            case 3: limits.previewDimension = 0
            default: limits.maximumPreviewBytes = 3
            }
            XCTAssertThrowsError(try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot, limits: limits)) {
                guard case ImageExportError.invalidOptions = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        let cancellation = ImageExportCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testStagedBytesPassTheSharedVerifierWhichRejectsWrongMetadata() throws {
        let snapshot = try ImageExportSnapshot(image: fixture(width: 73, height: 61))
        let staged = try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot)
        XCTAssertNoThrow(try ImageExportService.verify(data: staged, options: ImageExportOptions(), width: 73, height: 61, expectedPages: 1))
        for (options, width, height) in [(ImageExportOptions(format: .jpeg), 73, 61),
                                       (ImageExportOptions(), 61, 73), (ImageExportOptions(), 74, 61)] {
            XCTAssertThrowsError(try ImageExportService.verify(data: staged, options: options, width: width, height: height, expectedPages: 1)) {
                guard case ImageExportError.invalidOutput = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        XCTAssertThrowsError(try ImageExportService.verify(data: Data("not PNG".utf8), options: ImageExportOptions(), width: 73, height: 61, expectedPages: 1)) {
            guard case ImageExportError.invalidOutput = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testBothStillFormatsAndModesKeepPrivateExactStageAndCancelBeforeLaunch() async throws {
        let snapshot = try ImageExportSnapshot(image: fixture())
        let expected = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions()).data
        let expectedHash = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        for mode in [CodecPNGStagingMode.verifiedBytesOnly, .legacyPreview] {
            for format in [CodecExportFormat.webp, .avif] {
                let capture = StagedPNGObservation()
                let service = CodecExportProcessService(configuration: .init(
                    executable: { URL(fileURLWithPath: "/usr/bin/false") },
                    pngStagingMode: mode, collectStagedPNGIdentityForDiagnostics: true,
                    stagedPNGForDiagnostics: { url in
                        try capture.record(url)
                        // Cancel the actual detached staging task, without a
                        // timer race or launching a synthetic helper process.
                        let cancelled = withUnsafeCurrentTask { task -> Bool in
                            guard let task else { return false }; task.cancel(); return true
                        }
                        XCTAssertTrue(cancelled)
                    }))
                do { _ = try await service.prepare(snapshot: snapshot, options: .init(format: format)); XCTFail("Cancelled stage must not launch") }
                catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
                let observed = try XCTUnwrap(capture.snapshot())
                XCTAssertEqual(observed.data, expected)
                XCTAssertEqual(observed.fileMode & 0o777, 0o600)
                XCTAssertEqual(observed.directoryMode & 0o777, 0o700)
                XCTAssertFalse(FileManager.default.fileExists(atPath: observed.url.deletingLastPathComponent().path))
                let state = await service.snapshot(), metrics = try XCTUnwrap(state.lastJob)
                XCTAssertFalse(state.active); XCTAssertFalse(metrics.childLaunched)
                XCTAssertNil(metrics.childProcessIdentifier)
                XCTAssertEqual(metrics.outcome, "cancelled")
                XCTAssertTrue(metrics.temporaryDirectoryRemoved)
                XCTAssertEqual(metrics.pngStagingMode, mode.rawValue)
                XCTAssertEqual(metrics.sourceBytes, Int64(expected.count))
                XCTAssertEqual(metrics.sourceSHA256, expectedHash)
                // A cancelled stage must release the shared native lease.
                let lease = try XCTUnwrap(NativeExportAdmission.shared.acquire())
                NativeExportAdmission.shared.release(lease)
            }
        }
    }

    func testProductionDefaultsToBytesOnlyWithoutDiagnosticWork() {
        let configuration = CodecProcessConfiguration.production
        XCTAssertEqual(configuration.pngStagingMode, .verifiedBytesOnly)
        XCTAssertFalse(configuration.collectStagedPNGIdentityForDiagnostics)
        XCTAssertNil(configuration.stagedPNGForDiagnostics)
    }

    private func referencePNG(_ image: CGImage) throws -> Data {
        // Recreate the accepted consumer-backed PNG writer independently of the
        // shared encoding method, with its exact one-image type and properties.
        let cancellation = ImageExportCancellation()
        let buffer = ImageExportBuffer(maximumBytes: ImageExportLimits.standard.maximumEncodedBytes, cancellation: cancellation)
        let consumer = try buffer.consumer()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        try cancellation.check()
        guard CGImageDestinationFinalize(destination) else { throw buffer.failure ?? ImageExportError.encodeFailed }
        if let failure = buffer.failure { throw failure }
        try cancellation.check()
        return buffer.data
    }

    private func fixture(width: Int = 73, height: Int = 61) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            if x < width / 3 {
                bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0
                bytes[offset + 3] = x == 0 ? 0 : 128
            } else {
                bytes[offset] = UInt8((x * 17 + y * 31) % 256)
                bytes[offset + 1] = UInt8((x * 53 + y * 7) % 256)
                bytes[offset + 2] = UInt8((x * 11 + y * 73) % 256); bytes[offset + 3] = 255
            }
        } }
        return try XCTUnwrap(context.makeImage())
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
    }
}

private final class StagedPNGObservation: @unchecked Sendable {
    struct Value { let url: URL; let data: Data; let fileMode: Int; let directoryMode: Int }
    private let lock = NSLock()
    private var value: Value?
    func record(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let result = Value(url: url, data: data,
            fileMode: try XCTUnwrap(file[.posixPermissions] as? NSNumber).intValue,
            directoryMode: try XCTUnwrap(directory[.posixPermissions] as? NSNumber).intValue)
        lock.lock(); defer { lock.unlock() }; value = result
    }
    func snapshot() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}
