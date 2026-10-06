import AppKit
import XCTest
@testable import PicShot

final class HistoryCaptureTimestampTests: XCTestCase {
    @MainActor func testHistoryReloadPreservesKnownCaptureTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capturedAt = Date(timeIntervalSince1970: 123_456)
        let store = HistoryStore(directory: directory)
        let saved = try store.add(image(), title: "Synthetic timestamp", capturedAt: capturedAt)
        XCTAssertEqual(saved.capturedAt, capturedAt)
        XCTAssertNotEqual(saved.createdAt, capturedAt)
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.records.first?.capturedAt, capturedAt)
        XCTAssertEqual(reloaded.records.first?.id, saved.id)
        XCTAssertNotNil(reloaded.image(for: saved))
    }
    @MainActor func testUnknownImportTimeStaysUnknownAndInvalidTimeWritesNoImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        XCTAssertThrowsError(try store.add(image(), capturedAt: Date(timeIntervalSinceReferenceDate: .nan)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".png") })
        let saved = try store.add(image(), title: "Imported fixture")
        XCTAssertNil(saved.capturedAt)
        XCTAssertNil(HistoryStore(directory: directory).records.first?.capturedAt)
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        return try XCTUnwrap(context.makeImage())
    }
}
