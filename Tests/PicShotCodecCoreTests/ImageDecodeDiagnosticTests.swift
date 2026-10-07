import XCTest
import Foundation
import Darwin
@testable import PicShotCodecCore

final class ImageDecodeDiagnosticTests: XCTestCase {
    func testFixedLimitsAndDiagnosticRequestRemainSeparateFromExportProtocol() throws {
        XCTAssertEqual(ImageDecodeDiagnosticLimits.width, 768)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.height, 576)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.rasterBytes, 768 * 576 * 4)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.cancelLine, Data("cancel\n".utf8))
        XCTAssertNotEqual(ImageDecodeDiagnosticLimits.cancelLine, CodecExportProtocol.cancelLine)
        for mode in [ImageDecodeDiagnosticRequest.Mode.decode, .holdAfterDecode] {
            let request = request(mode: mode)
            let bytes = try JSONEncoder().encode(request)
            XCTAssertEqual(try ImageDecodeDiagnosticRequest.decode(bytes), request)
            XCTAssertThrowsError(try CodecExportProtocol.decodeRequestLine(bytes))
        }
        XCTAssertThrowsError(try ImageDecodeDiagnosticRequest.decode(CodecExportProtocol.encodeRequestLine(.init(format: .webp))))
    }

    func testRequestBoundsAndMalformedFieldsFailClosed() throws {
        for count in [1, ImageDecodeDiagnosticLimits.pngBytes] { try request(pngBytes: count).validate() }
        for count in [0, -1, ImageDecodeDiagnosticLimits.pngBytes + 1, Int.max] {
            XCTAssertThrowsError(try request(pngBytes: count).validate())
        }
        let good = try JSONEncoder().encode(request())
        for (key, value) in [("schema", "other" as Any), ("token", "../outside"), ("parentPID", 1),
                             ("parentPID", true), ("pngBytes", 1.5), ("pngBytes", NSNull()),
                             ("pngBytes", [1, 2]), ("pngBytes", ["nested": ["value": 1]]),
                             ("pngSHA256", String(repeating: "A", count: 64)), ("mode", "export"),
                             ("path", "/tmp/anything")] {
            XCTAssertThrowsError(try ImageDecodeDiagnosticRequest.decode(replacing(good, key: key, value: value)), key)
        }
        var missing = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        missing.removeValue(forKey: "mode")
        XCTAssertThrowsError(try ImageDecodeDiagnosticRequest.decode(JSONSerialization.data(withJSONObject: missing)))
        for bytes in [Data(), Data("[]".utf8), Data("null".utf8), good + good,
                      Data(repeating: 32, count: ImageDecodeDiagnosticLimits.requestBytes + 1)] {
            XCTAssertThrowsError(try ImageDecodeDiagnosticRequest.decode(bytes))
        }
        for digest in ["", String(repeating: "0", count: 63), String(repeating: "0", count: 65),
                       String(repeating: "g", count: 64), String(repeating: "é", count: 64)] {
            XCTAssertFalse(ImageDecodeDiagnosticLimits.validDigest(digest))
        }
        XCTAssertTrue(ImageDecodeDiagnosticLimits.validDigest(String(repeating: "0123456789abcdef", count: 4)))
    }

    func testRequestRejectsDuplicateAndEscapedDuplicateKeys() throws {
        let good = try JSONEncoder().encode(request())
        for key in ["schema", "sch\\u0065ma"] {
            var bytes = Data("{\"\(key)\":\"\(ImageDecodeDiagnosticLimits.schema)\",".utf8)
            bytes.append(good.dropFirst())
            XCTAssertThrowsError(try ImageDecodeDiagnosticRequest.decode(bytes), key)
        }
    }

    func testIncrementalEventFramingAndTerminalExactlyOnce() throws {
        let phase = ImageDecodeDiagnosticEvent(kind: .phase, phase: "beforePNGRead", childPID: 123)
        let bytes = try line(phase) + line(result())
        var decoder = ImageDecodeDiagnosticEventDecoder(), events: [ImageDecodeDiagnosticEvent] = []
        for byte in bytes { events += try decoder.consume(Data([byte])) }
        try decoder.finish()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.phase, "beforePNGRead")
        XCTAssertEqual(events.last?.kind, .result)
        XCTAssertEqual(events.last?.rawBytes, ImageDecodeDiagnosticLimits.rasterBytes)
        XCTAssertTrue(try decoder.consume(Data()).isEmpty)
        XCTAssertThrowsError(try decoder.consume(Data([10])))

        var empty = ImageDecodeDiagnosticEventDecoder()
        XCTAssertThrowsError(try empty.finish())
        XCTAssertThrowsError(try empty.consume(Data([10])))
        var partial = ImageDecodeDiagnosticEventDecoder()
        _ = try partial.consume(Data(try line(result()).dropLast()))
        XCTAssertThrowsError(try partial.finish())
        var noTerminal = ImageDecodeDiagnosticEventDecoder()
        _ = try noTerminal.consume(line(phase))
        XCTAssertThrowsError(try noTerminal.finish())
        var doubled = ImageDecodeDiagnosticEventDecoder()
        XCTAssertThrowsError(try doubled.consume(line(result()) + line(result())))
        let encoded = try JSONEncoder().encode(result())
        for bytes in [encoded + Data("\r\n".utf8), Data("{\n".utf8) + Data(encoded.dropFirst()) + Data([10])] {
            var invalid = ImageDecodeDiagnosticEventDecoder()
            XCTAssertThrowsError(try invalid.consume(bytes))
        }
    }

    func testEventCountLineAndCumulativeByteCaps() throws {
        let phase = ImageDecodeDiagnosticEvent(kind: .phase, phase: "imageCreated", childPID: 123)
        var allowed = ImageDecodeDiagnosticEventDecoder()
        for _ in 0..<(ImageDecodeDiagnosticLimits.maximumEvents - 1) { _ = try allowed.consume(line(phase)) }
        _ = try allowed.consume(line(result())); try allowed.finish()
        var tooMany = ImageDecodeDiagnosticEventDecoder()
        for _ in 0..<ImageDecodeDiagnosticLimits.maximumEvents { _ = try tooMany.consume(line(phase)) }
        XCTAssertThrowsError(try tooMany.consume(line(result())))
        var longLine = ImageDecodeDiagnosticEventDecoder()
        XCTAssertThrowsError(try longLine.consume(Data(repeating: 32, count: ImageDecodeDiagnosticLimits.eventBytes + 1)))

        let encoded = try JSONEncoder().encode(phase)
        var padded = encoded
        padded.append(Data(repeating: 32, count: ImageDecodeDiagnosticLimits.eventBytes - encoded.count - 1)); padded.append(10)
        XCTAssertEqual(padded.count, ImageDecodeDiagnosticLimits.eventBytes)
        var oversized = Data(padded.dropLast()); oversized.append(32); oversized.append(10)
        var includesNewline = ImageDecodeDiagnosticEventDecoder()
        XCTAssertThrowsError(try includesNewline.consume(oversized), "The LF must fit inside the event byte ceiling")
        var aggregate = ImageDecodeDiagnosticEventDecoder()
        for _ in 0..<(ImageDecodeDiagnosticLimits.stdoutBytes / padded.count) { _ = try aggregate.consume(padded) }
        XCTAssertThrowsError(try aggregate.consume(line(result())))
    }

    func testResultAndReadyEventValidation() throws {
        try result().validate()
        var event = result(); event.rawBytes = ImageDecodeDiagnosticLimits.rasterBytes - 1
        XCTAssertThrowsError(try event.validate())
        event = result(); event.rawSHA256 = nil; XCTAssertThrowsError(try event.validate())
        event = result(); event.imageCreationSeconds = nil; XCTAssertThrowsError(try event.validate())
        event = result(); event.peaks = nil; XCTAssertThrowsError(try event.validate())
        event = result(); event.error = .cancelled; XCTAssertThrowsError(try event.validate())
        for seconds in [-1.0, .infinity, .nan] {
            event = result(); event.drawSeconds = seconds; XCTAssertThrowsError(try event.validate())
            event = result(); event.uptimeSeconds = seconds; XCTAssertThrowsError(try event.validate())
        }
        event = result(); event.childPID = 1; XCTAssertThrowsError(try event.validate())
        event = result(); event.phase = "unknown"; XCTAssertThrowsError(try event.validate())
        event = .init(kind: .ready, phase: "heldAfterDecode", childPID: 123); try event.validate()
        event.phase = "rasterDrawn"; XCTAssertThrowsError(try event.validate())
        event = .init(kind: .error, phase: "failed", childPID: 123)
        XCTAssertThrowsError(try event.validate()); event.error = .cancelled
        var errors = ImageDecodeDiagnosticEventDecoder()
        XCTAssertEqual(try errors.consume(line(event)).first?.error, .cancelled); try errors.finish()
    }

    func testEventRejectsUnknownAndDuplicateKeys() throws {
        let bytes = try JSONEncoder().encode(result())
        var unknown = try replacing(bytes, key: "path", value: "/tmp/other.rgba"); unknown.append(10)
        var decoder = ImageDecodeDiagnosticEventDecoder()
        XCTAssertThrowsError(try decoder.consume(unknown))
        for key in ["kind", "k\\u0069nd"] {
            var duplicate = Data("{\"\(key)\":\"result\",".utf8)
            duplicate.append(bytes.dropFirst()); duplicate.append(10)
            var decoder = ImageDecodeDiagnosticEventDecoder()
            XCTAssertThrowsError(try decoder.consume(duplicate), key)
        }
    }

    func testFixedPrivateJobRoundTripExclusiveOutputAndCleanup() throws {
        let png = Data([137, 80, 78, 71, 1, 2, 3]) // Staging tests do not invoke ImageIO.
        let job = try ImageDecodeDiagnosticJob.create(png: png, mode: .decode, check: {})
        defer { _ = job.removeAfterExit() }
        XCTAssertEqual(job.directory.lastPathComponent, ImageDecodeDiagnosticJob.prefix + job.request.token)
        XCTAssertEqual(job.request.parentPID, getpid())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: job.directory.path).sorted(), ["input.png", "request.json"])
        try assertPrivate(job.directory, mode: 0o700, type: S_IFDIR)
        for name in ["request.json", "input.png"] { try assertPrivate(job.directory.appendingPathComponent(name), mode: 0o600, type: S_IFREG) }
        XCTAssertEqual(try job.readPNG(check: {}), png)
        XCTAssertFalse(job.outputExists())
        XCTAssertThrowsError(try ImageDecodeDiagnosticJob.validate(directory: job.directory, expectedParent: getpid() + 1))
        XCTAssertThrowsError(try job.writeRaw(Data([0]), check: {}))
        XCTAssertFalse(job.outputExists())
        let raw = Data(repeating: 37, count: ImageDecodeDiagnosticLimits.rasterBytes)
        try job.writeRaw(raw, check: {})
        try assertPrivate(job.directory.appendingPathComponent("decoded.rgba"), mode: 0o600, type: S_IFREG)
        XCTAssertEqual(try job.readRaw(sha256: ImageDecodeDiagnosticLimits.digest(raw), check: {}), raw)
        XCTAssertThrowsError(try job.readRaw(sha256: String(repeating: "0", count: 64), check: {}))
        XCTAssertThrowsError(try job.readRaw(sha256: "invalid", check: {}))
        XCTAssertThrowsError(try job.writeRaw(raw, check: {}))
        XCTAssertThrowsError(try ImageDecodeDiagnosticJob.validate(directory: job.directory, expectedParent: getpid()))
        XCTAssertTrue(job.removeAfterExit())
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.directory.path))
        XCTAssertFalse(job.removeAfterExit())
    }

    func testJobRejectsSourceMutationAndReplacement() throws {
        for replace in [false, true] {
            let job = try makeJob(); defer { _ = job.removeAfterExit() }
            let source = job.directory.appendingPathComponent("input.png")
            if replace {
                let previous = job.directory.appendingPathComponent("previous-input.png")
                try FileManager.default.moveItem(at: source, to: previous)
                defer { _ = unlink(previous.path) }
                // Keep the old inode alive while creating its replacement.
                try privateFile(source, data: Data([1, 2, 3]))
            }
            else { try Data([3, 2, 1]).write(to: source) }
            XCTAssertThrowsError(try job.readPNG(check: {}))
        }
    }

    func testJobRejectsUnsafeSourceKindsAndModesWithoutFollowingThem() throws {
        for kind in ["symlink", "hardlink", "fifo", "mode"] {
            let job = try makeJob()
            let outside = job.directory.deletingLastPathComponent().appendingPathComponent("decode-test-outside-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: job.directory); try? FileManager.default.removeItem(at: outside) }
            try privateFile(outside, data: Data([1, 2, 3]))
            let source = job.directory.appendingPathComponent("input.png")
            if kind == "mode" { XCTAssertEqual(chmod(source.path, 0o644), 0) }
            else {
                XCTAssertEqual(unlink(source.path), 0)
                if kind == "symlink" { XCTAssertEqual(symlink(outside.path, source.path), 0) }
                if kind == "hardlink" { XCTAssertEqual(link(outside.path, source.path), 0) }
                if kind == "fifo" { XCTAssertEqual(mkfifo(source.path, 0o600), 0) }
            }
            XCTAssertThrowsError(try ImageDecodeDiagnosticJob.validate(directory: job.directory, expectedParent: getpid()), kind)
            XCTAssertThrowsError(try job.readPNG(check: {}), kind)
            XCTAssertFalse(job.removeAfterExit(), kind)
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.directory.appendingPathComponent("request.json").path), kind)
            XCTAssertEqual(try Data(contentsOf: outside), Data([1, 2, 3]), kind)
        }
    }

    func testCleanupRefusesUnknownEntryBeforeRemovingOwnedFiles() throws {
        let job = try makeJob(); defer { _ = job.removeAfterExit() }
        let extra = job.directory.appendingPathComponent("do-not-delete.txt")
        try privateFile(extra, data: Data([9]))
        XCTAssertFalse(job.removeAfterExit())
        XCTAssertEqual(try Data(contentsOf: extra), Data([9]))
        XCTAssertEqual(try job.readPNG(check: {}), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.directory.appendingPathComponent("request.json").path))
        XCTAssertEqual(unlink(extra.path), 0)
        XCTAssertTrue(job.removeAfterExit())
    }

    func testRawOutputSymlinkCannotOverwriteOrDeleteItsTarget() throws {
        let job = try makeJob()
        let outside = job.directory.deletingLastPathComponent().appendingPathComponent("decode-test-output-\(UUID().uuidString)")
        let output = job.directory.appendingPathComponent("decoded.rgba")
        defer {
            _ = unlink(output.path); _ = job.removeAfterExit()
            try? FileManager.default.removeItem(at: outside)
        }
        try privateFile(outside, data: Data([99]))
        XCTAssertEqual(symlink(outside.path, output.path), 0)
        XCTAssertTrue(job.outputExists())
        XCTAssertThrowsError(try job.writeRaw(Data(count: ImageDecodeDiagnosticLimits.rasterBytes), check: {}))
        XCTAssertThrowsError(try job.readRaw(sha256: String(repeating: "0", count: 64), check: {}))
        XCTAssertFalse(job.removeAfterExit())
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.directory.appendingPathComponent("request.json").path))
        XCTAssertEqual(try job.readPNG(check: {}), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: outside), Data([99]))
    }

    func testDirectorySymlinkAndReplacementCannotBeReadOrCleanedByCapturedJob() throws {
        let job = try makeJob()
        let alias = job.directory.deletingLastPathComponent().appendingPathComponent(ImageDecodeDiagnosticJob.prefix + UUID().uuidString)
        let moved = job.directory.deletingLastPathComponent().appendingPathComponent("decode-test-moved-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: job.directory)
            try? FileManager.default.removeItem(at: moved)
        }
        XCTAssertEqual(symlink(job.directory.path, alias.path), 0)
        XCTAssertThrowsError(try ImageDecodeDiagnosticJob.validate(directory: alias, expectedParent: getpid()))
        try FileManager.default.moveItem(at: job.directory, to: moved)
        try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sentinel = job.directory.appendingPathComponent("input.png")
        try privateFile(sentinel, data: Data([99]))
        XCTAssertThrowsError(try job.readPNG(check: {}))
        XCTAssertFalse(job.removeAfterExit())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([99]))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("input.png")), Data([1, 2, 3]))
    }

    func testJobChecksCancellationDuringReadAndWriteAndCleansPartialOutput() throws {
        XCTAssertThrowsError(try ImageDecodeDiagnosticJob.create(png: Data([1]), mode: .decode, check: { throw ImageDecodeDiagnosticError.cancelled })) {
            XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled)
        }
        let job = try makeJob(); defer { _ = job.removeAfterExit() }
        XCTAssertThrowsError(try job.readPNG(check: { throw ImageDecodeDiagnosticError.cancelled })) {
            XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled)
        }
        var checks = 0
        XCTAssertThrowsError(try job.writeRaw(Data(count: ImageDecodeDiagnosticLimits.rasterBytes), check: {
            checks += 1; if checks == 2 { throw ImageDecodeDiagnosticError.cancelled }
        })) { XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled) }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(try Data(contentsOf: job.directory.appendingPathComponent("decoded.rgba")).count, 65_536)
        XCTAssertTrue(job.removeAfterExit())
    }

    func testSelfMemoryReadingsAndPeakSamplesKeepResidentAndFootprintSeparate() throws {
        let reading = ImageDecodeMemoryReading.current()
        XCTAssertTrue(reading.usable)
        XCTAssertEqual(reading.standard.flavor, "TASK_VM_INFO")
        XCTAssertEqual(reading.purgeable.flavor, "TASK_VM_INFO_PURGEABLE")
        for value in [reading.standard, reading.purgeable] {
            XCTAssertEqual(value.kernelReturn, KERN_SUCCESS)
            XCTAssertGreaterThan(value.returnedNaturalCount, 0)
            XCTAssertLessThanOrEqual(value.returnedNaturalCount, value.requestedNaturalCount)
            XCTAssertTrue(value.uptimeSeconds.isFinite)
        }
        XCTAssertGreaterThan(try XCTUnwrap(reading.residentBytes), 0)
        XCTAssertGreaterThan(try XCTUnwrap(reading.footprintBytes), 0)
        for field in ["purgeable_volatile_resident", "purgeable_volatile_virtual", "purgeable_volatile_pmap"] {
            XCTAssertNotNil(reading.purgeable.bytes[field])
        }
        var peaks = ImageDecodeMemoryPeaks()
        peaks.record(reading); peaks.record(reading)
        XCTAssertEqual(peaks.residentSamples, 2); XCTAssertEqual(peaks.footprintSamples, 2)
        XCTAssertEqual(peaks.residentBytes, reading.residentBytes)
        XCTAssertEqual(peaks.footprintBytes, reading.footprintBytes)
        var event = result(); event.memory = reading; event.peaks = peaks
        try event.validate()
    }

    private func request(pngBytes: Int = 3, mode: ImageDecodeDiagnosticRequest.Mode = .decode) -> ImageDecodeDiagnosticRequest {
        .init(token: "3C6B0788-E795-4B71-9D75-0DFD7D74DC88", parentPID: 123, pngBytes: pngBytes,
              pngSHA256: String(repeating: "a", count: 64), mode: mode)
    }
    private func result() -> ImageDecodeDiagnosticEvent {
        var event = ImageDecodeDiagnosticEvent(kind: .result, phase: "complete", childPID: 123)
        event.rawBytes = ImageDecodeDiagnosticLimits.rasterBytes; event.rawSHA256 = String(repeating: "a", count: 64)
        event.imageCreationSeconds = 0; event.drawSeconds = 0; event.writeSeconds = 0; event.childWorkSeconds = 0
        var peaks = ImageDecodeMemoryPeaks(); peaks.residentBytes = 1; peaks.footprintBytes = 1
        peaks.residentSamples = 1; peaks.footprintSamples = 1; event.peaks = peaks
        return event
    }
    private func line(_ event: ImageDecodeDiagnosticEvent) throws -> Data {
        var bytes = try JSONEncoder().encode(event); bytes.append(10); return bytes
    }
    private func replacing(_ data: Data, key: String, value: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object[key] = value; return try JSONSerialization.data(withJSONObject: object)
    }
    private func makeJob() throws -> ImageDecodeDiagnosticJob {
        try ImageDecodeDiagnosticJob.create(png: Data([1, 2, 3]), mode: .decode, check: {})
    }
    private func privateFile(_ url: URL, data: Data) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]))
    }
    private func assertPrivate(_ url: URL, mode: mode_t, type: mode_t, file: StaticString = #filePath, line: UInt = #line) throws {
        var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0, file: file, line: line)
        XCTAssertEqual(info.st_uid, geteuid(), file: file, line: line)
        XCTAssertEqual(info.st_mode & 0o7777, mode, file: file, line: line)
        XCTAssertEqual(info.st_mode & S_IFMT, type, file: file, line: line)
        if type == S_IFREG { XCTAssertEqual(info.st_nlink, 1, file: file, line: line) }
    }
}
