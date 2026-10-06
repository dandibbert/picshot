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
    func testAppleMediaBeforeMetadataOrderingValidatesEachReferencedFragment() throws {
        var data = initial()
        for sequence in 1...4 {
            let offset = data.count + 8
            data += atom("mdat", Data([1,2,3,4]))
            data += fragment(sequence: UInt32(sequence), base: UInt64(offset), sizes: [2,2])
        }
        let committed = data.count
        data += atom("wide") + Data([0,0,0,0,109,100,97,116,1,2,3])
        let result = try parse(data)
        XCTAssertEqual(result.completeFragments, 5)
        XCTAssertEqual(result.byteCount, Int64(committed))
        XCTAssertEqual(result.ignoredTailBytes, Int64(data.count - committed))
    }
    func testMoofBeforeMdatAndSignedNegativeOffsetsBothRemainSupported() throws {
        var data = atom("ftyp") + movie()
        let provisional = fragment(sequence: 1, base: nil, dataOffset: 0, sizes: [2])
        data += fragment(sequence: 1, base: nil, dataOffset: Int32(provisional.count + 8), sizes: [2])
        data += atom("mdat", Data([7,8]))
        XCTAssertEqual(try parse(data).completeFragments, 1)
        var apple = initial()
        let start = apple.count + 8
        apple += atom("mdat", Data([7,8]))
        apple += fragment(sequence: 1, base: nil, dataOffset: Int32(start - apple.count), sizes: [2])
        XCTAssertEqual(try parse(apple).completeFragments, 2)
    }
    func testIncompleteMediaOrMetadataTailRetainsOnlyPreviouslyCheckedPrefix() throws {
        let first = initial()
        let future = fragment(sequence: 1, base: UInt64(first.count + 4_096), sizes: [2])
        XCTAssertEqual(try parse(first + future).byteCount, Int64(first.count))
        let truncated = atom("mdat", Data([1,2])) + Data([0,0,1,0,109,111,111,102,0])
        XCTAssertEqual(try parse(first + truncated).byteCount, Int64(first.count))
    }
    func testMetadataReferencesCannotPointIntoHeadersMovieOrOutsidePayload() throws {
        let first = initial()
        for badOffset: UInt64 in [0, 8, 17, UInt64(first.count - 1), 4_294_967_295] {
            let fragment = fragment(sequence: 1, base: badOffset, sizes: [2])
            if badOffset == 4_294_967_295 { XCTAssertThrowsError(try parse(first + fragment)) }
            else { XCTAssertEqual(try parse(first + fragment).byteCount, Int64(first.count)) }
        }
        let oversizedRun = fragment(sequence: 1, base: 16, sizes: [3]) // Initial payload has only 2 bytes.
        XCTAssertEqual(try parse(first + oversizedRun).completeFragments, 1)
        XCTAssertThrowsError(try parse(atom("ftyp") + atom("mdat", Data([1,2])) + movie(offsets: [0], sizes: [2])))
    }
    func testUnknownTrackDuplicateSequenceAndMalformedRunSizesAreRejected() throws {
        var first = initial()
        let offset = first.count + 8
        first += atom("mdat", Data([3,4]))
        XCTAssertThrowsError(try parse(first + fragment(sequence: 1, base: UInt64(offset), sizes: [2], track: 9)))
        let good = fragment(sequence: 1, base: UInt64(offset), sizes: [2])
        XCTAssertThrowsError(try parse(first + good + good))
        let badRun = full("trun", flags: 0x200, u32(100) + u32(2))
        let bad = atom("moof", full("mfhd", u32(1)) + atom("traf", tfhd(base: UInt64(offset)) + badRun))
        XCTAssertThrowsError(try parse(first + bad))
    }
    func testDefaultSampleSizeAndDurationAreResolvedFromTrexAndTfhd() throws {
        let initMovie = movie(defaultSize: 2)
        let base = atom("ftyp") + initMovie
        let dataOffset = base.count + 8
        let header = full("tfhd", flags: 1, u32(1) + u64(UInt64(dataOffset)))
        let run = full("trun", u32(2))
        let metadata = atom("moof", full("mfhd", u32(1)) + atom("traf", header + run))
        XCTAssertEqual(try parse(base + atom("mdat", Data([1,2,3,4])) + metadata).completeFragments, 1)
        let zeroDefault = atom("ftyp") + movie(defaultSize: 0)
        XCTAssertThrowsError(try parse(zeroDefault + atom("mdat", Data([1,2,3,4])) + metadata))
    }
    func testExplicitTfhdBaseTakesPrecedenceOverDefaultBaseIsMoof() throws {
        let first = initial()
        let header = full("tfhd", flags: 0x020009, u32(1) + u64(16) + u32(600))
        let run = full("trun", flags: 0x200, u32(1) + u32(2))
        let metadata = atom("moof", full("mfhd", u32(1)) + atom("traf", header + run))
        XCTAssertEqual(try parse(first + metadata).completeFragments, 2)
    }
    func testExternalMediaReferencesAreRefusedBeforeNativeAssetLoading() throws {
        XCTAssertThrowsError(try parse(atom("ftyp") + movie(externalReference: true)))
        let referenceMovie = atom("moov", Data(movie().dropFirst(8)) + atom("rmra", atom("rmda")))
        XCTAssertThrowsError(try parse(atom("ftyp") + referenceMovie))
    }
    func testExtendedMdatAndOpenEndedFinalizedMedia() throws {
        let ftyp = atom("ftyp")
        let extended = u32(1) + Data("mdat".utf8) + u64(18) + Data([1,2])
        let data = ftyp + extended + movie(offsets: [UInt64(ftyp.count + 16)], sizes: [2])
        XCTAssertEqual(try parse(data).byteCount, Int64(data.count))
        let metadata = movie(offsets: [0], sizes: [2])
        let offset = ftyp.count + metadata.count + 8
        let before = ftyp + movie(offsets: [UInt64(offset)], sizes: [2])
        let open = before + Data([0,0,0,0,109,100,97,116,1,2])
        XCTAssertThrowsError(try parse(open))
        XCTAssertEqual(try parse(open, finalized: true).byteCount, Int64(open.count))
    }
    func testParserWorkAndFileSizeAreBounded() throws {
        let data = initial() + (0..<RecordingRecoveryMP4.maximumAtoms).reduce(into: Data()) { result, _ in result += atom("free") }
        XCTAssertThrowsError(try parse(data))
        XCTAssertThrowsError(try RecordingRecoveryMP4.completePrefix(fileSize: 4_294_967_297) { _, _ in XCTFail("Must reject before reading"); return Data() })
        let excessive = full("trun", flags: 0x200, u32(UInt32(RecordingRecoveryMP4.maximumSamples + 1)))
        let fragment = atom("moof", full("mfhd", u32(1)) + atom("traf", tfhd(base: 16) + excessive))
        XCTAssertThrowsError(try parse(initial() + fragment))
    }
    private func journal(limit: Int64 = 16_777_216, duration: Double = 600) -> RecordingRecoveryJournal {
        .init(id: UUID(), sourceIdentity: .init(device: 1, inode: 2), byteLimit: limit, durationLimit: duration)
    }
    private func initial() -> Data { atom("ftyp") + atom("mdat", Data([1,2])) + movie(offsets: [16], sizes: [2]) }
    private func u32(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    private func u64(_ value: UInt64) -> Data { u32(UInt32(value >> 32)) + u32(UInt32(value & 0xffff_ffff)) }
    private func atom(_ type: String, _ body: Data = Data()) -> Data { u32(UInt32(body.count + 8)) + Data(type.utf8) + body }
    private func full(_ type: String, flags: UInt32 = 0, _ body: Data = Data()) -> Data { atom(type, u32(flags) + body) }
    /// Structurally faithful metadata only; actual decode stays in native tests.
    private func movie(offsets: [UInt64] = [], sizes: [UInt32] = [], defaultSize: UInt32 = 0, externalReference: Bool = false) -> Data {
        let header = full("tkhd", u32(0) + u32(0) + u32(1) + u32(0))
        let handler = full("hdlr", u32(0) + Data("vide".utf8))
        let reference = full("url ", flags: externalReference ? 0 : 1, externalReference ? Data("https://example.invalid/media\0".utf8) : Data())
        let dinf = atom("dinf", full("dref", u32(1) + reference))
        let format = atom("avc1", Data(repeating: 0, count: 6) + Data([0,1]))
        let descriptions = full("stsd", u32(1) + format)
        let stsz = full("stsz", u32(0) + u32(UInt32(sizes.count)) + sizes.reduce(into: Data()) { $0 += u32($1) })
        let stco = full("co64", u32(UInt32(offsets.count)) + offsets.reduce(into: Data()) { $0 += u64($1) })
        let stsc = full("stsc", offsets.isEmpty ? u32(0) : u32(1) + u32(1) + u32(1) + u32(1))
        let table = atom("stbl", descriptions + stsz + stco + stsc)
        let track = atom("trak", header + atom("mdia", handler + atom("minf", dinf + table)))
        let trex = full("trex", u32(1) + u32(1) + u32(600) + u32(defaultSize) + u32(0))
        return atom("moov", track + atom("mvex", trex))
    }
    private func tfhd(base: UInt64?, track: UInt32 = 1) -> Data {
        full("tfhd", flags: base == nil ? 0x020008 : 9, u32(track) + (base.map(u64) ?? Data()) + u32(600))
    }
    private func fragment(sequence: UInt32, base: UInt64?, dataOffset: Int32? = nil, sizes: [UInt32], track: UInt32 = 1) -> Data {
        let flags: UInt32 = 0x200 | (dataOffset == nil ? 0 : 1)
        let run = full("trun", flags: flags, u32(UInt32(sizes.count)) + (dataOffset.map { u32(UInt32(bitPattern: $0)) } ?? Data()) + sizes.reduce(into: Data()) { $0 += u32($1) })
        return atom("moof", full("mfhd", u32(sequence)) + atom("traf", tfhd(base: base, track: track) + run))
    }
    private func parse(_ data: Data, finalized: Bool = false) throws -> RecordingRecoveryPrefix {
        try RecordingRecoveryMP4.completePrefix(fileSize: Int64(data.count), finalized: finalized) { offset, size in
            data.subdata(in: Int(offset)..<min(data.count, Int(offset) + size))
        }
    }
}
