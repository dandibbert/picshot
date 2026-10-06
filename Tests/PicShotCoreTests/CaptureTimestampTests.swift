import Foundation
import XCTest
@testable import PicShotCore

final class CaptureTimestampTests: XCTestCase {
    func testKnownCaptureTimeRoundTripsSeparatelyFromInsertionTime() throws {
        let value = record(capturedAt: Date(timeIntervalSince1970: 100))
        let restored = try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        XCTAssertNotEqual(restored.createdAt, restored.capturedAt)
        XCTAssertTrue(restored.hasSafeStorageMetadata)
    }
    func testOldHistoryDoesNotInventCaptureTimeFromInsertionTime() throws {
        let value = record(capturedAt: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json.removeValue(forKey: "capturedAt")
        let restored = try JSONDecoder().decode(CaptureRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.capturedAt)
        XCTAssertEqual(restored.createdAt, value.createdAt)
        XCTAssertTrue(restored.hasSafeStorageMetadata)
    }
    func testRetentionUsesInsertionTimeNotSourceCaptureTime() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var value = record(capturedAt: Date(timeIntervalSince1970: 1))
        value.createdAt = now
        XCTAssertEqual(RetentionPolicy(maxDays: 1).retained([value], now: now), [value])
    }
    func testNonfiniteCaptureTimeIsUnsafeMetadata() {
        XCTAssertFalse(record(capturedAt: Date(timeIntervalSinceReferenceDate: .nan)).hasSafeStorageMetadata)
        XCTAssertFalse(record(capturedAt: Date(timeIntervalSinceReferenceDate: .infinity)).hasSafeStorageMetadata)
    }
    private func record(capturedAt: Date?) -> CaptureRecord {
        CaptureRecord(createdAt: Date(timeIntervalSince1970: 1_000), title: "Fixture", filename: UUID().uuidString + ".png",
                      width: 16, height: 12, byteCount: 100, capturedAt: capturedAt)
    }
}
