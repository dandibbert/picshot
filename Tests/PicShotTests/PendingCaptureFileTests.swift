import AppKit
import XCTest
import ImageIO
import PicShotCore
@testable import PicShot

final class PendingCaptureFileTests: XCTestCase {
    @MainActor func testCommittedPNGMatchesOriginalAndNoStageSurvives() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = try raster(), capture = try PendingCapture(CapturedImage(image: image, presentation: nil,
            capturedAt: Date(timeIntervalSince1970: 123456)), title: "fixture")
        let destination = root.appendingPathComponent("saved.png")
        XCTAssertEqual(try PendingCaptureFileWriter.write(capture, to: destination), destination.standardizedFileURL.resolvingSymlinksInPath())
        let decoded = try SystemCaptureDecoder.read(url: destination)
        XCTAssertEqual(try pixels(decoded.image), try pixels(image))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["saved.png"])
    }

    @MainActor func testSymlinkParentPublishesToCanonicalDirectoryWithoutChangingPixels() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("actual", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let image = try raster(), capture = try PendingCapture(CapturedImage(image: image, presentation: nil), title: "fixture")
        let selected = alias.appendingPathComponent("saved.png")
        let saved = try PendingCaptureFileWriter.write(capture, to: selected)
        XCTAssertEqual(saved, target.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("saved.png"))
        XCTAssertEqual(try pixels(SystemCaptureDecoder.read(url: selected).image), try pixels(image))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["saved.png"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), target.path)
    }

    @MainActor func testFailureCapCancellationAndCollisionNeverClaimSavedOrDropRecovery() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = try PendingCapture(CapturedImage(image: try raster(), presentation: nil), title: "fixture")
        let recovery = PendingCaptureRecovery(); try recovery.retain(capture, error: CaptureRecoveryError.writeFailed)
        for mode in ["cap", "cancel", "disk", "collision"] {
            let url = root.appendingPathComponent(mode + ".png"), cancellation = ImageExportCancellation()
            if mode == "collision" { try Data("existing".utf8).write(to: url) }
            let saving = try XCTUnwrap(recovery.beginSave())
            let outcome: Result<URL, Error> = Result {
                try PendingCaptureFileWriter.write(saving, to: url, cancellation: cancellation,
                    maximumEncodedBytes: mode == "cap" ? 1 : CaptureRecoveryPolicy.maximumPendingBytes,
                    beforeCommit: {
                        if mode == "cancel" { cancellation.cancel() }
                        if mode == "disk" { throw CaptureRecoveryError.writeFailed }
                    })
            }
            if case .success = outcome { XCTFail("Failure must not be reported as saved") }
            recovery.finishSave(id: capture.id, result: outcome)
            XCTAssertEqual(recovery.pending?.id, capture.id); XCTAssertTrue(recovery.pending?.image === capture.image)
            if mode == "collision" { XCTAssertEqual(try Data(contentsOf: url), Data("existing".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".picshot") })
        }
    }

    @MainActor func testSystemDecodedPixelsSurviveSourceDeletionAndDiscardClearsReservation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.png"), original = try raster()
        try original.writePNG(to: url)
        let bytes = try Data(contentsOf: url).count
        let recovery = PendingCaptureRecovery()
        try autoreleasepool {
            let result = try SystemCaptureDecoder.read(url: url, capturedAt: Date(timeIntervalSince1970: 99))
            XCTAssertEqual(result.encodedBackingBytes, bytes)
            try recovery.retain(PendingCapture(result, title: "system"), error: CaptureRecoveryError.writeFailed)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(try pixels(XCTUnwrap(recovery.pending?.image)), try pixels(original))
        XCTAssertEqual(recovery.retainedBytes, try XCTUnwrap(recovery.pending?.image).bytesPerRow * original.height + bytes)
        XCTAssertTrue(recovery.discard())
        XCTAssertNil(recovery.pending); XCTAssertEqual(recovery.retainedBytes, 0)
        XCTAssertFalse(recovery.blocksCapture)
        // ImageIO's private CGDataProvider is not weak-referenceable on every
        // runtime. This test proves pixel survival and release of our reservation,
        // not private provider reclamation or a process-memory plateau.
    }

    @MainActor func testDiscardReleasesExplicitlyOwnedProviderAndBackingReservation() throws {
        let recovery = PendingCaptureRecovery(), counter = CaptureTestProviderCounter()
        try autoreleasepool {
            let image = try CaptureTestProviderCounter.image(width: 16, height: 12, counter: counter)
            try recovery.retain(PendingCapture(CapturedImage(image: image, presentation: nil), title: "owned"),
                                error: CaptureRecoveryError.writeFailed)
        }
        XCTAssertEqual(counter.callbacks, 0); XCTAssertEqual(counter.deallocations, 0)
        XCTAssertEqual(counter.liveBytes, 16 * 12 * 4)
        XCTAssertEqual(recovery.retainedBytes, 16 * 12 * 4)
        let observed = try autoreleasepool { try pixels(XCTUnwrap(recovery.pending?.image)) }
        XCTAssertEqual(observed, Data(Array(repeating: [UInt8(64), 128, 192, 255], count: 16 * 12).flatMap { $0 }))
        autoreleasepool { XCTAssertTrue(recovery.discard()) }
        XCTAssertNil(recovery.pending); XCTAssertEqual(recovery.retainedBytes, 0)
        XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1)
        XCTAssertEqual(counter.liveBytes, 0)
        // A public supplied-provider callback proves this owned control's lifetime;
        // it does not substitute for observing an opaque ImageIO provider.
    }

    func testSystemDecoderRefusesMissingMalformedAndOversizedInputWithoutRasterCopy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bad.png")
        XCTAssertThrowsError(try SystemCaptureDecoder.read(url: url))
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try SystemCaptureDecoder.read(url: url))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CaptureRecoveryPolicy.maximumEncodedBytes + 1)); try handle.close()
        XCTAssertThrowsError(try SystemCaptureDecoder.read(url: url))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func raster() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        return try XCTUnwrap(context.makeImage())
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}
