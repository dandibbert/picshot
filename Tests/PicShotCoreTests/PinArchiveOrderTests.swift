import XCTest
@testable import PicShotCore

final class PinArchiveOrderTests: XCTestCase {
    func testActualCloseSequenceWinsOverCreationAndUpdateDates() throws {
        var newestCreated = entry(created: 500, sequence: 1)
        let oldestCreated = entry(created: 1, sequence: 2)
        newestCreated.updatedAt = Date(timeIntervalSince1970: 9000)
        let index = try PinSessionIndex(entries: [oldestCreated, newestCreated]).validated()
        XCTAssertEqual(index.lastArchivedEntry?.id, oldestCreated.id)
        XCTAssertEqual(index.nextArchiveSequence, 3)
        let decoded = try JSONDecoder().decode(PinSessionIndex.self, from: JSONEncoder().encode(index)).validated()
        XCTAssertEqual(decoded.lastArchivedEntry?.id, oldestCreated.id)
    }
    func testLegacyArchivedEntriesDoNotInventCloseOrder() throws {
        let old = entry(created: 9999, sequence: nil)
        let raw = try JSONEncoder().encode(PinSessionIndex(entries: [old]))
        let decoded = try JSONDecoder().decode(PinSessionIndex.self, from: raw).validated()
        XCTAssertEqual(decoded.entries.count, 1); XCTAssertNil(decoded.lastArchivedEntry)
        XCTAssertNil(decoded.entries[0].archiveSequence)
    }
    func testReopenedAndRemovedEntriesAreExcluded() {
        let first = entry(created: 1, sequence: 1)
        var second = entry(created: 2, sequence: 2); second.isVisible = true
        var index = PinSessionIndex(entries: [first, second])
        XCTAssertEqual(index.lastArchivedEntry?.id, first.id)
        index.entries.removeAll { $0.id == first.id }
        XCTAssertNil(index.lastArchivedEntry)
    }
    func testDuplicateZeroAndOverflowSequencesAreRejected() {
        for sequence in [UInt64(0), UInt64.max] {
            XCTAssertThrowsError(try PinSessionIndex(entries: [entry(created: 1, sequence: sequence)]).validated())
        }
        XCTAssertThrowsError(try PinSessionIndex(entries: [entry(created: 1, sequence: 2), entry(created: 2, sequence: 2)]).validated())
    }
    private func entry(created: TimeInterval, sequence: UInt64?) -> PinSessionEntry {
        PinSessionEntry(createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: created),
                        original: PinRasterAsset(filename: UUID().uuidString + ".png", width: 4, height: 4, byteCount: 30), isVisible: false, archiveSequence: sequence)
    }
}
