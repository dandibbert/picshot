import XCTest
@testable import PicShotCore

final class RecordingRecoveryJournalTests: XCTestCase {
    func testJournalRoundTripAndExactOwnedNames() throws {
        let value = journal()
        XCTAssertEqual(try JSONDecoder().decode(RecordingRecoveryJournal.self, from: JSONEncoder().encode(value)).validated(), value)
        XCTAssertEqual(RecordingRecoveryJournal.id(directoryName: value.directoryName), value.id)
        XCTAssertNil(RecordingRecoveryJournal.id(directoryName: value.directoryName.lowercased()))
        XCTAssertNil(RecordingRecoveryJournal.id(directoryName: value.directoryName + "/../"))
        XCTAssertFalse(RecordingRecoveryJournal.isPublishedFilename("PicShot-../secret.mp4"))
        XCTAssertFalse(RecordingRecoveryJournal.isRecoveredFilename("PicShot-Recovered-bogus.mp4"))
        XCTAssertTrue(RecordingRecoveryJournal.isRecoveredFilename("PicShot-Recovered-" + UUID().uuidString + ".mp4"))
    }
    func testMalformedVersionIdentityDurationNamesAndPublicationRejected() throws {
        var value = journal(); value.schemaVersion += 1; XCTAssertThrowsError(try value.validated())
        value = journal(); value.mediaFilename = "../recording.mp4"; XCTAssertThrowsError(try value.validated())
        value = journal(); value.phase = .published; XCTAssertThrowsError(try value.validated())
        value = journal(); value.publishedFilename = "/tmp/movie.mp4"; XCTAssertThrowsError(try value.validated())
        value = journal(); value.phase = .recovered; XCTAssertThrowsError(try value.validated())
        XCTAssertThrowsError(try journal(limit: 0).validated())
        XCTAssertThrowsError(try journal(duration: .infinity).validated())
        XCTAssertThrowsError(try journal(duration: 3_601).validated())
    }
    func testFragmentedPrefixDropsPartialAtomAndPreservesOffsets() throws {
        let complete = atom("ftyp", [0, 0, 0, 0]) + atom("moov", [1]) + atom("moof", [2]) + atom("mdat", [3, 4])
        let tail = atom("moof", [5]) + Data([0, 0, 1, 0, 109, 100, 97, 116, 6])
        let result = try parse(complete + tail)
        XCTAssertEqual(result.byteCount, Int64(complete.count))
        XCTAssertEqual(result.completeFragments, 1)
        XCTAssertEqual(result.ignoredTailBytes, Int64(tail.count))
    }
    func testInitialMovieAfterMediaIsRecoverableAndLaterFragmentsAreCounted() throws {
        let first = atom("ftyp") + atom("wide") + atom("mdat", [1]) + atom("moov", [2])
        let later = atom("moof", [3]) + atom("mdat", [4])
        XCTAssertEqual(try parse(first).completeFragments, 1)
        XCTAssertEqual(try parse(first + later).completeFragments, 2)
    }
    func testIncompleteFirstMovieOpenEndedMediaAndMalformedSizesDoNotClaimRecovery() {
        XCTAssertThrowsError(try parse(atom("ftyp") + atom("mdat", [1])))
        XCTAssertThrowsError(try parse(atom("ftyp") + atom("moov") + Data([0, 0, 0, 0, 109, 100, 97, 116, 1])))
        XCTAssertThrowsError(try parse(atom("ftyp") + Data([0, 0, 0, 4, 109, 111, 111, 118])))
        XCTAssertThrowsError(try parse(atom("ftyp") + atom("evil")))
        XCTAssertThrowsError(try parse(atom("ftyp") + atom("moov") + atom("moof") + atom("moof")))
    }
    func testExtendedSizeAndZeroSizedFinalizedAtom() throws {
        let header = Data([0, 0, 0, 1, 109, 100, 97, 116, 0, 0, 0, 0, 0, 0, 0, 17, 42])
        let data = atom("ftyp") + atom("moov") + header
        XCTAssertEqual(try parse(data).byteCount, Int64(data.count))
        let open = atom("ftyp") + atom("moov") + Data([0, 0, 0, 0, 109, 100, 97, 116, 1])
        XCTAssertEqual(try parse(open, finalized: true).byteCount, Int64(open.count))
    }
    func testParserWorkAndFileSizeAreBounded() throws {
        let base = atom("ftyp") + atom("moov") + atom("mdat", [1])
        let hugeAtomCount = base + Data(repeating: 0, count: 0) + (0..<RecordingRecoveryMP4.maximumAtoms).reduce(into: Data()) { result, _ in result += atom("free") }
        XCTAssertThrowsError(try parse(hugeAtomCount))
        XCTAssertThrowsError(try RecordingRecoveryMP4.completePrefix(fileSize: 4_294_967_297) { _, _ in XCTFail("Must reject before reading"); return Data() })
    }
    private func journal(limit: Int64 = 16_777_216, duration: Double = 600) -> RecordingRecoveryJournal {
        .init(id: UUID(), sourceIdentity: .init(device: 1, inode: 2), byteLimit: limit, durationLimit: duration)
    }
    private func atom(_ type: String, _ body: [UInt8] = []) -> Data {
        let size = UInt32(body.count + 8)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + Data(type.utf8) + Data(body)
    }
    private func parse(_ data: Data, finalized: Bool = false) throws -> RecordingRecoveryPrefix {
        try RecordingRecoveryMP4.completePrefix(fileSize: Int64(data.count), finalized: finalized) { offset, size in
            data.subdata(in: Int(offset)..<min(data.count, Int(offset) + size))
        }
    }
}
