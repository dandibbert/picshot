import Darwin
import Foundation
import XCTest
@testable import PicShot

final class GIFHelperProtocolTests: XCTestCase {
    func testDefaultRequestRoundTripsAsOneBoundedLine() throws {
        let request = GIFHelperRequest()
        let line = try GIFHelperProtocol.encodeRequestLine(request)
        XCTAssertEqual(line.last, 10)
        XCTAssertEqual(line.filter { $0 == 10 }.count, 1)
        XCTAssertLessThanOrEqual(line.count, GIFHelperLimits.requestBytes)
        let decoded = try GIFHelperProtocol.decodeRequestLine(line)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.options, request.options)
        XCTAssertEqual(decoded.frameExtraction, .asynchronous)
    }

    func testBothExtractionModesRoundTrip() throws {
        for mode in GIFFrameExtraction.allCases {
            let request = GIFHelperRequest(options: .init(frameRate: 30, maximumDimension: 1_920, maximumDuration: 60, maximumFrames: 600), frameExtraction: mode)
            let result = try GIFHelperProtocol.decodeRequestLine(GIFHelperProtocol.encodeRequestLine(request))
            XCTAssertEqual(result.frameExtraction, mode)
            XCTAssertEqual(result.options, request.options)
        }
    }

    func testRequestRejectsUnsupportedVersionAndUnsafeOptions() {
        XCTAssertThrowsError(try GIFHelperRequest(version: 2).validate())
        let options: [GIFExportOptions] = [
            .init(frameRate: 0), .init(frameRate: 31), .init(frameRate: .nan), .init(frameRate: .infinity),
            .init(maximumDimension: 15), .init(maximumDimension: 1_921),
            .init(maximumDuration: 0), .init(maximumDuration: 60.1), .init(maximumDuration: .infinity),
            .init(maximumFrames: 0), .init(maximumFrames: 601)
        ]
        for option in options { XCTAssertThrowsError(try GIFHelperRequest(options: option).validate()) }
    }

    func testRequestRejectsMissingUnknownAndWronglyTypedFields() throws {
        let valid = try requestObject()
        for key in ["version", "options", "frameExtraction"] {
            var object = valid
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(json(object)))
        }
        var extra = valid
        extra["sourceURL"] = "/tmp/other.mp4"
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(json(extra)))
        var wrongVersion = valid
        wrongVersion["version"] = true
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(json(wrongVersion)))
        var wrongMode = valid
        wrongMode["frameExtraction"] = "unknown"
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(json(wrongMode)))
        var extraOption = valid
        var options = try XCTUnwrap(valid["options"] as? [String: Any])
        options["outputPath"] = "/tmp/other.gif"
        extraOption["options"] = options
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(json(extraOption)))
        options.removeValue(forKey: "outputPath")
        options["maximumFrames"] = "600"
        extraOption["options"] = options
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(json(extraOption)))
    }

    func testDuplicateAndEscapedDuplicateKeysAreRejected() throws {
        let request = try String(decoding: GIFHelperProtocol.encodeRequestLine(.init()), as: UTF8.self)
        for duplicate in ["\"version\":1,", "\"\\u0076ersion\":1,"] {
            let source = "{" + duplicate + request.dropFirst()
            XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(Data(source.utf8)))
        }
        XCTAssertThrowsError(try GIFHelperProtocol.decodeCancelLine(Data("{\"cancel\":false,\"cancel\":true}\n".utf8)))
    }

    func testFramingRejectsEmbeddedLinesTrailingDocumentsAndArrays() throws {
        let valid = try GIFHelperProtocol.encodeRequestLine(.init())
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(valid + valid))
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(Data("{\n\"version\":1}\n".utf8)))
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(Data("[]\n".utf8)))
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(Data("null\n".utf8)))
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(Data()))
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(Data([0xFF, 10])))
        var crlf = valid
        crlf.insert(13, at: crlf.count - 1)
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(crlf))
    }

    func testRequestByteLimitIncludesNewline() throws {
        let original = try GIFHelperProtocol.encodeRequestLine(.init())
        var atLimit = Data(original.dropLast())
        atLimit.append(Data(repeating: 32, count: GIFHelperLimits.requestBytes - 1 - atLimit.count))
        atLimit.append(10)
        XCTAssertEqual(atLimit.count, GIFHelperLimits.requestBytes)
        XCTAssertNoThrow(try GIFHelperProtocol.decodeRequestLine(atLimit))
        atLimit.insert(32, at: atLimit.count - 1)
        XCTAssertThrowsError(try GIFHelperProtocol.decodeRequestLine(atLimit))
    }

    func testIncrementalDecoderAcceptsSplitRequestAndCancel() throws {
        var decoder = GIFHelperInputDecoder()
        var requests = 0
        var cancellations = 0
        let bytes = try GIFHelperProtocol.encodeRequestLine(.init()) + Data("{\"cancel\":true}\n".utf8)
        for byte in bytes {
            for message in try decoder.consume(Data([byte])) {
                switch message {
                case .request: requests += 1
                case .cancel: cancellations += 1
                }
            }
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(decoder.receivedRequest)
        XCTAssertNoThrow(try decoder.finish())
    }

    func testIncrementalDecoderRejectsSecondRequestAndExtraControl() throws {
        let request = try GIFHelperProtocol.encodeRequestLine(.init())
        var decoder = GIFHelperInputDecoder()
        _ = try decoder.consume(request)
        XCTAssertThrowsError(try decoder.consume(request))
        var second = GIFHelperInputDecoder()
        _ = try second.consume(request + Data("{\"cancel\":true}\n".utf8))
        XCTAssertThrowsError(try second.consume(Data("{\"cancel\":true}\n".utf8)))
    }

    func testIncompleteAndOversizedInputNeverFinishesSuccessfully() throws {
        var empty = GIFHelperInputDecoder()
        XCTAssertThrowsError(try empty.finish())
        var partial = GIFHelperInputDecoder()
        _ = try partial.consume(Data("{\"version\":".utf8))
        XCTAssertThrowsError(try partial.finish())
        var oversized = GIFHelperInputDecoder()
        XCTAssertThrowsError(try oversized.consume(Data(repeating: 32, count: GIFHelperLimits.requestBytes + 1)))
        var partialCancel = GIFHelperInputDecoder()
        _ = try partialCancel.consume(GIFHelperProtocol.encodeRequestLine(.init()))
        _ = try partialCancel.consume(Data("{".utf8))
        XCTAssertThrowsError(try partialCancel.finish())
    }

    func testCompleteRequestEOFHasValidFramingButRuntimeTreatsItAsParentLoss() throws {
        var decoder = GIFHelperInputDecoder()
        _ = try decoder.consume(GIFHelperProtocol.encodeRequestLine(.init()))
        XCTAssertNoThrow(try decoder.finish())
        // The framing parser reports truncation only. GIFHelperMain separately
        // cancels every stdin EOF because the supervising parent keeps it open.
    }

    func testCancelMustBeOneTrueBooleanAndNothingElse() {
        XCTAssertNoThrow(try GIFHelperProtocol.decodeCancelLine(Data("{\"cancel\":true}\n".utf8)))
        for source in ["{\"cancel\":false}", "{\"cancel\":1}", "{\"cancel\":\"true\"}", "{\"cancel\":null}",
                       "{\"cancel\":true,\"other\":1}", "{}"] {
            XCTAssertThrowsError(try GIFHelperProtocol.decodeCancelLine(Data(source.utf8)))
        }
        XCTAssertThrowsError(try GIFHelperProtocol.decodeCancelLine(Data(repeating: 32, count: GIFHelperLimits.cancelBytes + 1)))
    }

    func testUnterminatedControlCannotGrowBeyondItsOwnBudget() throws {
        var decoder = GIFHelperInputDecoder()
        _ = try decoder.consume(GIFHelperProtocol.encodeRequestLine(.init()))
        _ = try decoder.consume(Data(repeating: 32, count: GIFHelperLimits.cancelBytes))
        XCTAssertThrowsError(try decoder.consume(Data([32])))
    }

    func testAllEventKindsRoundTrip() throws {
        let events = [
            GIFHelperEvent(kind: .progress, fraction: 0.5),
            GIFHelperEvent(kind: .memory, residentBytes: 100, physicalFootprintBytes: 90),
            GIFHelperEvent(kind: .memory), // Both memory APIs can be unavailable.
            GIFHelperEvent(kind: .result, outputBytes: 1_024, frameCount: 12, duration: 1,
                residentBytes: 100, physicalFootprintBytes: 90, sampledPeakResidentBytes: 110,
                sampledPeakPhysicalFootprintBytes: 105, residentSampleCount: 3, physicalFootprintSampleCount: 3),
            GIFHelperEvent(kind: .error, errorCode: "cancelled", errorMessage: "GIF export was cancelled.")
        ]
        for event in events {
            let encoded = try GIFHelperProtocol.encodeEventLine(event)
            XCTAssertEqual(encoded.last, 10)
            XCTAssertLessThanOrEqual(encoded.count, GIFHelperLimits.eventBytes)
            let decoded = try GIFHelperProtocol.decodeEventLine(encoded)
            XCTAssertEqual(decoded.kind, event.kind)
            XCTAssertEqual(decoded.fraction, event.fraction)
            XCTAssertEqual(decoded.outputBytes, event.outputBytes)
            XCTAssertEqual(decoded.sampledPeakResidentBytes, event.sampledPeakResidentBytes)
        }
    }

    func testInvalidAndCrossKindEventPayloadsAreRejected() {
        let bad = [
            GIFHelperEvent(version: 2, kind: .memory),
            GIFHelperEvent(kind: .progress), GIFHelperEvent(kind: .progress, fraction: -0.1),
            GIFHelperEvent(kind: .progress, fraction: 1.1), GIFHelperEvent(kind: .progress, fraction: .nan),
            GIFHelperEvent(kind: .progress, fraction: 0, outputBytes: 10),
            GIFHelperEvent(kind: .memory, errorCode: "failed"),
            GIFHelperEvent(kind: .result, outputBytes: 0, frameCount: 1, duration: 1),
            GIFHelperEvent(kind: .result, outputBytes: GIFHelperLimits.outputBytes + 1, frameCount: 1, duration: 1),
            GIFHelperEvent(kind: .result, outputBytes: 1, frameCount: 601, duration: 1),
            GIFHelperEvent(kind: .result, outputBytes: 1, frameCount: 1, duration: .infinity),
            GIFHelperEvent(kind: .error), GIFHelperEvent(kind: .error, errorCode: "bad code"),
            GIFHelperEvent(kind: .error, errorCode: "failed", errorMessage: "two\nlines"),
            GIFHelperEvent(kind: .error, errorCode: "failed", errorMessage: String(repeating: "é", count: 385)),
            GIFHelperEvent(kind: .error, errorCode: "failed", residentSampleCount: -1)
        ]
        for event in bad { XCTAssertThrowsError(try GIFHelperProtocol.encodeEventLine(event)) }
        for json in ["{\"version\":1,\"kind\":\"other\"}", "{\"version\":1,\"kind\":\"memory\",\"path\":\"/tmp/x\"}",
                     "{\"version\":1,\"kind\":\"memory\",\"residentBytes\":null}", "{\"version\":1,\"kind\":\"memory\",\"residentBytes\":-1}"] {
            XCTAssertThrowsError(try GIFHelperProtocol.decodeEventLine(Data(json.utf8)))
        }
    }

    func testEventByteCapIsCheckedBeforeParsing() {
        XCTAssertThrowsError(try GIFHelperProtocol.decodeEventLine(Data(repeating: 32, count: GIFHelperLimits.eventBytes + 1)))
    }

    func testTerminalErrorSupportsBoundedUnicodeAndMissingMemoryReadings() throws {
        let message = String(repeating: "é", count: 384)
        let event = GIFHelperEvent(kind: .error, errorCode: "failed", errorMessage: message,
            residentSampleCount: 0, physicalFootprintSampleCount: 0)
        let decoded = try GIFHelperProtocol.decodeEventLine(GIFHelperProtocol.encodeEventLine(event))
        XCTAssertEqual(decoded.errorMessage, message)
        XCTAssertEqual(decoded.residentSampleCount, 0)
        XCTAssertNil(decoded.sampledPeakResidentBytes)
    }

    func testPrivateOwnedJobAcceptsOnlyFixedPaths() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try GIFHelperJobFiles.validate(directory: directory)
        XCTAssertEqual(files.sourceURL.lastPathComponent, "source.mp4")
        XCTAssertEqual(files.outputURL.lastPathComponent, "result.gif")
        XCTAssertThrowsError(try files.validateOutput())
        try Data("GIF output".utf8).write(to: files.outputURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.outputURL.path)
        XCTAssertEqual(try files.validateOutput(), 10)
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
    }

    func testJobRejectsLooseDirectoryPermissionsAndUnexpectedName() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let renamed = directory.deletingLastPathComponent().appendingPathComponent("picshot-unowned-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: directory, to: renamed)
        defer { try? FileManager.default.removeItem(at: renamed) }
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: renamed))
    }

    func testJobRejectsSymbolicDirectoryAndSymbolicSource() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alias = directory.deletingLastPathComponent().appendingPathComponent(".picshot-gif-job-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: alias))
        let source = directory.appendingPathComponent("source.mp4")
        let actual = directory.appendingPathComponent("actual.mp4")
        try FileManager.default.moveItem(at: source, to: actual)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: actual)
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
    }

    func testJobRejectsEmptyOversizedNonprivateAndHardLinkedSource() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
        try handle.truncate(atOffset: UInt64(GIFHelperLimits.sourceBytes) + 1)
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
        try handle.truncate(atOffset: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        try FileManager.default.linkItem(at: source, to: directory.appendingPathComponent("linked.mp4"))
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
    }

    func testJobRejectsDirectoryInPlaceOfSource() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
    }

    func testJobRejectsDanglingOutputSymlinkAndOversizedOutput() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try GIFHelperJobFiles.validate(directory: directory)
        try FileManager.default.createSymbolicLink(at: files.outputURL, withDestinationURL: directory.appendingPathComponent("missing"))
        XCTAssertThrowsError(try GIFHelperJobFiles.validate(directory: directory))
        XCTAssertThrowsError(try files.validateOutput())
        try FileManager.default.removeItem(at: files.outputURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: files.outputURL.path, contents: Data([1]), attributes: [.posixPermissions: 0o600]))
        let handle = try FileHandle(forWritingTo: files.outputURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(GIFHelperLimits.outputBytes) + 1)
        XCTAssertThrowsError(try files.validateOutput())
    }

    func testMP4GateAcceptsSelfContainedH264AndOptionalAAC() throws {
        let video = try validateMP4(mp4())
        XCTAssertEqual(video.trackCount, 1)
        XCTAssertEqual(video.mediaDataBytesSkipped, 4)
        XCTAssertLessThan(video.metadataBytesRead, 1_024)
        let audioVideo = try validateMP4(mp4(tracks: mp4Track() + mp4Track(handler: "soun", codec: "mp4a")))
        XCTAssertEqual(audioVideo.trackCount, 2)
    }

    func testMP4GatePreservesLocalFragmentedMovieLayout() throws {
        let movie = mp4(extraMovie: atom("mvex")) + atom("moof") + atom("mdat", Data([5, 6])) + atom("mfra")
        let result = try validateMP4(movie)
        XCTAssertEqual(result.mediaDataBytesSkipped, 6)
        XCTAssertEqual(result.trackCount, 1)
    }

    func testMP4GateRejectsPlaylistAndMissingRequiredBoxes() throws {
        for data in [Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://example.invalid/video.m3u8\n".utf8),
                     atom("moov", mp4Track()) + atom("mdat", Data([1])),
                     atom("ftyp", Data("mp42".utf8) + Data(repeating: 0, count: 4)) + atom("mdat", Data([1])),
                     atom("ftyp", Data("mp42".utf8) + Data(repeating: 0, count: 4)) + atom("moov", mp4Track()),
                     mp4(majorBrand: "qt  ")] {
            XCTAssertThrowsError(try validateMP4(data))
        }
    }

    func testMP4GateRejectsEveryExternalDataReference() throws {
        let external = [
            atom("url ", Data([0, 0, 0, 0]) + Data("https://example.invalid/media\0".utf8)),
            atom("url ", Data([0, 0, 0, 0]) + Data("file:///private/other.mp4\0".utf8)),
            atom("url ", Data([0, 0, 0, 1]) + Data("unexpected\0".utf8)),
            atom("urn ", Data([0, 0, 0, 1])), atom("alis", Data([0, 0, 0, 1])),
            atom("url ", Data([1, 0, 0, 1])), atom("url ", Data([0, 0, 0, 3]))
        ]
        for entry in external {
            XCTAssertThrowsError(try validateMP4(mp4(tracks: mp4Track(references: [entry]))))
            // An unselected external entry is still forbidden.
            XCTAssertThrowsError(try validateMP4(mp4(tracks: mp4Track(references: [atom("url ", Data([0, 0, 0, 1])), entry]))))
        }
    }

    func testMP4GateRejectsReferenceCompressedAndEncryptedMovies() throws {
        for type in ["rmra", "rmda", "rdrf", "cmov"] {
            XCTAssertThrowsError(try validateMP4(mp4(extraMovie: atom(type))))
        }
        for handler in ["moov", "text", "hint"] {
            XCTAssertThrowsError(try validateMP4(mp4(tracks: mp4Track(handler: handler))))
        }
        for codec in ["encv", "mp4s", "jpeg", "hvc1"] {
            XCTAssertThrowsError(try validateMP4(mp4(tracks: mp4Track(codec: codec))))
        }
    }

    func testMP4GateRejectsOutOfRangeSampleReferencesAndMissingReferences() throws {
        XCTAssertThrowsError(try validateMP4(mp4(tracks: mp4Track(sampleReference: 0))))
        XCTAssertThrowsError(try validateMP4(mp4(tracks: mp4Track(sampleReference: 2))))
        XCTAssertThrowsError(try validateMP4(mp4(tracks: mp4Track(references: []))))
        XCTAssertThrowsError(try validateMP4(mp4(tracks: mp4Track(omitReferences: true))))
    }

    func testMP4GateRejectsAACDescriptorURLFlags() throws {
        let tracks = mp4Track() + mp4Track(handler: "soun", codec: "mp4a", audioURLFlag: true)
        XCTAssertThrowsError(try validateMP4(mp4(tracks: tracks)))
    }

    func testMP4GateSkipsLargeExtendedSizeMediaPayloadWithoutReadingIt() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let mediaBytes: UInt64 = 128 * 1_024 * 1_024
        let prefix = mp4(includeMedia: false) + word32(1) + Data("mdat".utf8) + word64(mediaBytes + 16)
        try prefix.write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(prefix.count) + mediaBytes)
        let report = try GIFHelperMP4Validation.validate(sourceURL: source)
        XCTAssertEqual(report.mediaDataBytesSkipped, mediaBytes)
        XCTAssertLessThan(report.metadataBytesRead, 1_024)
        XCTAssertLessThan(report.atomCount, 32)
    }

    func testMP4GateRejectsMalformedSizesAndAtomCountBombs() throws {
        let malformed = [
            Data([0, 0, 0, 4]) + Data("ftyp".utf8),
            word32(100) + Data("ftyp".utf8),
            word32(1) + Data("mdat".utf8) + word64(UInt64.max),
            word32(0) + Data("moov".utf8),
            mp4() + Data([0, 0, 0])
        ]
        for data in malformed { XCTAssertThrowsError(try validateMP4(data)) }
        var bomb = mp4()
        for _ in 0..<GIFHelperMP4Validation.maximumAtoms { bomb.append(atom("free")) }
        XCTAssertThrowsError(try validateMP4(bomb))
    }

    func testMP4GateRejectsOversizedMetadataWithoutReadingIt() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let metadataBytes = GIFHelperMP4Validation.maximumMetadataBytesSpanned + 1
        let prefix = mp4() + word32(1) + Data("moof".utf8) + word64(metadataBytes + 16)
        try prefix.write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(prefix.count) + metadataBytes)
        XCTAssertThrowsError(try GIFHelperMP4Validation.validate(sourceURL: source))
    }

    func testMP4GateRejectsFIFOWithoutWaitingForAWriter() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(mkfifo(source.path, 0o600), 0)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try GIFHelperMP4Validation.validate(sourceURL: source))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testOrphanCleanupRemovesOnlyOwnedFixedAndRecognizedPartialArtifacts() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try GIFHelperJobFiles.validate(directory: directory)
        for name in ["result.gif", ".picshot-\(UUID().uuidString).gif"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path,
                contents: Data([1]), attributes: [.posixPermissions: 0o600]))
        }
        XCTAssertTrue(files.cleanupAfterParentLoss())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOrphanCleanupPreservesUnknownFilesAndDoesNotRecurse() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try GIFHelperJobFiles.validate(directory: directory)
        let nested = directory.appendingPathComponent("unknown", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let keep = nested.appendingPathComponent("source.mp4")
        try Data("keep".utf8).write(to: keep)
        let invalidPartial = directory.appendingPathComponent(".picshot-not-a-uuid.gif")
        try Data("keep too".utf8).write(to: invalidPartial)
        XCTAssertFalse(files.cleanupAfterParentLoss())
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: keep), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: invalidPartial), Data("keep too".utf8))
    }

    func testOrphanCleanupRefusesSubstitutedSourceIdentity() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try GIFHelperJobFiles.validate(directory: directory)
        let original = directory.appendingPathComponent("keep-original.mp4")
        try FileManager.default.moveItem(at: files.sourceURL, to: original)
        XCTAssertTrue(FileManager.default.createFile(atPath: files.sourceURL.path,
            contents: Data("replacement".utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertFalse(files.cleanupAfterParentLoss())
        XCTAssertEqual(try Data(contentsOf: files.sourceURL), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testOrphanCleanupRefusesSubstitutedDirectoryIdentity() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try GIFHelperJobFiles.validate(directory: directory)
        let original = directory.deletingLastPathComponent().appendingPathComponent(".picshot-gif-job-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: directory, to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(FileManager.default.createFile(atPath: files.sourceURL.path, contents: Data("keep".utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertFalse(files.cleanupAfterParentLoss())
        XCTAssertEqual(try Data(contentsOf: files.sourceURL), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("source.mp4").path))
    }

    func testOrphanCleanupDoesNotFollowSymlinkOrRemoveHardLinkedOutput() throws {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try GIFHelperJobFiles.validate(directory: directory)
        let keep = directory.appendingPathComponent("keep.gif")
        XCTAssertTrue(FileManager.default.createFile(atPath: keep.path, contents: Data("keep".utf8), attributes: [.posixPermissions: 0o600]))
        try FileManager.default.createSymbolicLink(at: files.outputURL, withDestinationURL: keep)
        let partial = directory.appendingPathComponent(".picshot-\(UUID().uuidString).gif")
        try FileManager.default.linkItem(at: keep, to: partial)
        XCTAssertFalse(files.cleanupAfterParentLoss())
        XCTAssertEqual(try Data(contentsOf: keep), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: files.outputURL.path), keep.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    private func validateMP4(_ data: Data) throws -> GIFHelperMP4Validation.Report {
        let directory = try makeJob()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try data.write(to: source)
        return try GIFHelperMP4Validation.validate(sourceURL: source)
    }

    /// Structural fixtures exercise the admission gate, not native decoding.
    /// The native process suite supplies actual AVAssetWriter H.264/AAC media.
    private func mp4(tracks: Data? = nil, extraMovie: Data = Data(), majorBrand: String = "mp42", includeMedia: Bool = true) -> Data {
        let type = atom("ftyp", Data(majorBrand.utf8) + word32(0) + Data("mp42isom".utf8))
        return type + atom("moov", (tracks ?? mp4Track()) + extraMovie) + (includeMedia ? atom("mdat", Data([1, 2, 3, 4])) : Data())
    }

    private func mp4Track(handler: String = "vide", codec: String = "avc1", references: [Data]? = nil,
                          sampleReference: Int = 1, omitReferences: Bool = false, audioURLFlag: Bool = false) -> Data {
        let references = references ?? [atom("url ", Data([0, 0, 0, 1]))]
        let referenceTable = atom("dinf", atom("dref", word32(0) + word32(UInt32(references.count)) + references.reduce(Data(), +)))
        var sample = Data(repeating: 0, count: codec == "mp4a" ? 28 : 78)
        sample[6] = UInt8((sampleReference >> 8) & 0xFF)
        sample[7] = UInt8(sampleReference & 0xFF)
        if codec == "mp4a" { sample += atom("esds", Data([0, 0, 0, 0, 3, 3, 0, 1, audioURLFlag ? 0x40 : 0])) }
        else { sample += atom("avcC", Data([1])) }
        let sampleTable = atom("stbl", atom("stsd", word32(0) + word32(1) + atom(codec, sample)))
        let information = atom("minf", (omitReferences ? Data() : referenceTable) + sampleTable)
        let handlerAtom = atom("hdlr", word32(0) + word32(0) + Data(handler.utf8))
        return atom("trak", atom("mdia", handlerAtom + information))
    }

    private func atom(_ type: String, _ payload: Data = Data()) -> Data {
        precondition(type.utf8.count == 4)
        return word32(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }
    private func word32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    private func word64(_ value: UInt64) -> Data {
        word32(UInt32(value >> 32)) + word32(UInt32(value & 0xFFFF_FFFF))
    }

    private func requestObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: GIFHelperProtocol.encodeRequestLine(.init())) as? [String: Any])
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
    }

    private func makeJob() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(".picshot-gif-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = directory.appendingPathComponent("source.mp4")
        guard FileManager.default.createFile(atPath: source.path, contents: Data([1]), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return directory
    }
}
