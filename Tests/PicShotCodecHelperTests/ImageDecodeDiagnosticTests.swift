import XCTest
import Foundation
import Darwin
import PicShotCodecCore
@testable import PicShotCodecHelper

/// Pure seams plus bounded launches of the real separate helper executable.
/// Never call run() in-process: its _exit watchdog belongs only in the child.
final class ImageDecodeDiagnosticTests: XCTestCase {
    func testExplicitDiagnosticSelectorIsRejectedByNormalExportEntryValidation() throws {
        XCTAssertEqual(ImageDecodeDiagnosticLimits.argument, "--image-draw-decode-diagnostic-v1")
        try PicShotCodecHelper.validateArguments([])
        for arguments in [[ImageDecodeDiagnosticLimits.argument],
                          [ImageDecodeDiagnosticLimits.argument, "extra"],
                          ["--image-draw-decode-diagnostic-v2"], ["--input", "/tmp/input.png"]] {
            XCTAssertThrowsError(try PicShotCodecHelper.validateArguments(arguments))
        }
    }

    func testActualPNGDecodeDrawProducesEveryExpectedPremultipliedSRGBByte() throws {
        let png = try fixturePNG()
        XCTAssertEqual(png.count, 8046)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.digest(png), "7c8fe103d727c71bbd4edd0c0543bd8484c1e382b69ffcecc19a1749c509f1e8")
        let expected = expectedPixels()
        XCTAssertEqual(expected.count, ImageDecodeDiagnosticLimits.rasterBytes)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.digest(expected), "7e35d154b86ff50944c588bb08726c2f48b3659a4304c83cfd04f06e7176a1d7")
        let job = try ImageDecodeDiagnosticJob.create(png: png, mode: .decode, check: {})
        defer { _ = job.removeAfterExit() }
        var phases: [String] = [], checks = 0
        let result = try autoreleasepool {
            try ImageDecodeDiagnostic.decodePixels(job.readPNG(check: {}), check: { checks += 1 }, phase: { phases.append($0) })
        }
        XCTAssertEqual(phases, ["imageCreated", "rasterDrawn", "afterContextRelease"])
        XCTAssertGreaterThanOrEqual(checks, 3)
        XCTAssertEqual(result.0.count, 1_769_472)
        XCTAssertTrue(result.0.elementsEqual(expected), "Every byte must equal premultiplied-last, big-endian RGBA in sRGB")
        XCTAssertEqual(ImageDecodeDiagnosticLimits.digest(result.0), "7e35d154b86ff50944c588bb08726c2f48b3659a4304c83cfd04f06e7176a1d7")
        XCTAssertEqual(Array(result.0.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual(Array(result.0[(72 * 768 + 96) * 4 ..< (72 * 768 + 96) * 4 + 4]), [0, 0, 0, 0])
        for seconds in [result.1, result.2] { XCTAssertTrue(seconds.isFinite); XCTAssertGreaterThanOrEqual(seconds, 0) }
        XCTAssertFalse(job.outputExists())
        try job.writeRaw(result.0, check: {})
        let reloaded = try job.readRaw(sha256: ImageDecodeDiagnosticLimits.digest(expected), check: {})
        XCTAssertTrue(reloaded.elementsEqual(expected))
        XCTAssertTrue(job.removeAfterExit())
    }

    func testRejectsTruncatedPNGAndNonPNGInputsWithoutPublishingPixels() throws {
        let png = try fixturePNG()
        let invalid = [Data(), Data(png.prefix(32)), Data(png.prefix(33)),
                       Data(png.prefix(png.count / 2)), Data(png.dropLast(12)),
                       Data("GIF89a".utf8), Data([0xff, 0xd8, 0xff, 0xe0]), Data(repeating: 0, count: 64)]
        for bytes in invalid {
            XCTAssertThrowsError(try ImageDecodeDiagnostic.decodePixels(bytes, check: {}, phase: { _ in }), "Accepted \(bytes.count) invalid PNG bytes") {
                XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .invalidInput)
            }
        }
        var badSignature = png; badSignature[0] = 0
        var badIHDRLength = png; badIHDRLength[11] = 12
        var wrongFirstChunk = png; wrongFirstChunk[12] = 74
        for bytes in [badSignature, badIHDRLength, wrongFirstChunk] {
            XCTAssertThrowsError(try ImageDecodeDiagnostic.decodePixels(bytes, check: {}, phase: { _ in }))
        }
    }

    func testRejectsWrongDimensionsBeforeNativeImageCreation() throws {
        let png = try fixturePNG()
        for (width, height) in [(UInt32(0), UInt32(576)), (768, 0), (767, 576), (768, 575),
                                (769, 576), (768, 577), (UInt32.max, UInt32.max)] {
            var bytes = png
            put(width, in: &bytes, at: 16); put(height, in: &bytes, at: 20); repairIHDRCRC(&bytes)
            var phases: [String] = []
            XCTAssertThrowsError(try ImageDecodeDiagnostic.decodePixels(bytes, check: {}, phase: { phases.append($0) })) {
                XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .invalidInput)
            }
            XCTAssertTrue(phases.isEmpty)
        }
    }

    func testRejectsUnsupportedDepthAndMalformedIHDRTypes() throws {
        let png = try fixturePNG()
        // Keep CRC correct so ImageIO has to inspect the unsupported header.
        for (offset, value) in [(24, UInt8(16)), (24, 0), (24, 3), (25, 1), (25, 5), (25, 7),
                                (26, 1), (27, 1), (28, 2)] {
            var bytes = png; bytes[offset] = value; repairIHDRCRC(&bytes)
            XCTAssertThrowsError(try ImageDecodeDiagnostic.decodePixels(bytes, check: {}, phase: { _ in })) {
                XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .invalidInput)
            }
        }
    }

    func testCancellationBeforeDecodeDoesNotReachImageCreation() throws {
        var phases: [String] = [], checks = 0
        XCTAssertThrowsError(try ImageDecodeDiagnostic.decodePixels(fixturePNG(), check: {
            checks += 1; throw ImageDecodeDiagnosticError.cancelled
        }, phase: { phases.append($0) })) { XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled) }
        XCTAssertEqual(checks, 1); XCTAssertTrue(phases.isEmpty)
    }

    func testCancellationAfterActualCreationAndRasterDrawPreventsRawPublication() throws {
        let png = try fixturePNG()
        for stopPhase in ["imageCreated", "rasterDrawn", "afterContextRelease"] {
            let job = try ImageDecodeDiagnosticJob.create(png: png, mode: .holdAfterDecode, check: {})
            defer { _ = job.removeAfterExit() }
            var cancelled = false, phases: [String] = [], checkedAfterCancellation = false
            XCTAssertThrowsError(try autoreleasepool {
                let result = try ImageDecodeDiagnostic.decodePixels(job.readPNG(check: {}), check: {
                    if cancelled { checkedAfterCancellation = true; throw ImageDecodeDiagnosticError.cancelled }
                }, phase: { phase in
                    phases.append(phase)
                    if phase == stopPhase { cancelled = true }
                })
                try job.writeRaw(result.0, check: {})
            }) { XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled) }
            XCTAssertTrue(checkedAfterCancellation, stopPhase)
            XCTAssertTrue(phases.contains(stopPhase))
            if stopPhase == "imageCreated" { XCTAssertEqual(phases, ["imageCreated"]) }
            else { XCTAssertEqual(phases, ["imageCreated", "rasterDrawn", "afterContextRelease"]) }
            XCTAssertFalse(job.outputExists(), "Cancelled real decode must never publish decoded.rgba")
        }
    }

    func testRealHelperLaunchAcceptsStagedAndPhysicalCWDWithJobTMPDIR() throws {
        for physicalSpelling in [false, true] {
            let job = try ImageDecodeDiagnosticJob.create(png: fixturePNG(), mode: .decode, check: {})
            let process = Process()
            defer { if !process.isRunning { XCTAssertTrue(job.removeAfterExit()) } }
            let pointer = try XCTUnwrap(job.directory.path.withCString { realpath($0, nil) })
            let physical = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
            free(pointer)
            let normalized = physical.standardizedFileURL
            var stagedInfo = stat(), physicalInfo = stat()
            XCTAssertEqual(stat(job.directory.path, &stagedInfo), 0)
            XCTAssertEqual(stat(physical.path, &physicalInfo), 0)
            XCTAssertEqual(stagedInfo.st_dev, physicalInfo.st_dev); XCTAssertEqual(stagedInfo.st_ino, physicalInfo.st_ino)
            // Reproduce the old guard when the native temp directory has the
            // /private/var spelling; keep caller-supplied path checks strict.
            if physical.path != normalized.resolvingSymlinksInPath().path {
                XCTAssertThrowsError(try ImageDecodeDiagnosticJob.validate(directory: physical, expectedParent: getpid()))
            }
            let launchDirectory = physicalSpelling ? physical : job.directory
            print("Image decode cwd regression: staged=\(job.directory.path), physical=\(physical.path), normalized=\(normalized.path), launch=\(launchDirectory.path)")
            let result = try runRealDiagnostic(process, job: job, directory: launchDirectory)
            XCTAssertEqual(process.terminationReason, .exit); XCTAssertEqual(process.terminationStatus, 0)
            let terminal = try XCTUnwrap(result.last)
            XCTAssertEqual(terminal.kind, .result, terminal.error?.rawValue ?? "missing result")
            XCTAssertEqual(result.filter { $0.phase == "beforePNGRead" }.count, 1)
            XCTAssertEqual(result.filter { $0.phase == "rasterDrawn" }.count, 1)
            let expected = expectedPixels()
            let digest = try XCTUnwrap(terminal.rawSHA256)
            XCTAssertEqual(digest, ImageDecodeDiagnosticLimits.digest(expected))
            XCTAssertEqual(try job.readRaw(sha256: digest, check: {}), expected)
        }
    }

    func testRealHelperCWDAdmissionStillRejectsParentAndTokenMismatch() throws {
        for field in ["parentPID", "token"] {
            let job = try ImageDecodeDiagnosticJob.create(png: fixturePNG(), mode: .decode, check: {})
            let process = Process()
            defer { if !process.isRunning { XCTAssertTrue(job.removeAfterExit()) } }
            let requestURL = job.directory.appendingPathComponent("request.json")
            var request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as? [String: Any])
            if field == "parentPID" { request[field] = Int(getpid()) + 1 }
            else { request[field] = UUID().uuidString }
            try JSONSerialization.data(withJSONObject: request).write(to: requestURL)
            let result = try runRealDiagnostic(process, job: job, directory: job.directory)
            XCTAssertEqual(process.terminationReason, .exit); XCTAssertEqual(process.terminationStatus, 1)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.last?.kind, .error); XCTAssertEqual(result.last?.error, .invalidJob)
            XCTAssertFalse(job.outputExists())
        }
    }

    private func realHelperExecutable() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["PICSHOT_CODEC_HELPER_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let bundle = Bundle(for: ImageDecodeDiagnosticTests.self).bundleURL
        let candidates = [bundle.deletingLastPathComponent().appendingPathComponent("PicShotCodecHelper"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("PicShotCodecHelper")]
        return try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }, "Build the real PicShotCodecHelper for the cwd regression gate")
    }

    private func runRealDiagnostic(_ process: Process, job: ImageDecodeDiagnosticJob, directory: URL) throws -> [ImageDecodeDiagnosticEvent] {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = try realHelperExecutable(); process.arguments = [ImageDecodeDiagnosticLimits.argument]
        process.currentDirectoryURL = directory
        // Match the packaged parent supervisor, including its per-job TMPDIR.
        process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": job.directory.path, "LANG": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        for fd in [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
        }
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                let confirm = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < confirm { Thread.sleep(forTimeInterval: 0.005) }
                if !process.isRunning { process.waitUntilExit() }
                else { XCTFail("Owned diagnostic child exit unconfirmed; preserve its job directory") }
            }
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close(); try? errors.fileHandleForWriting.close()
        }
        try process.run()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + ImageDecodeDiagnosticLimits.exitSeconds
        var decoder = ImageDecodeDiagnosticEventDecoder(), events: [ImageDecodeDiagnosticEvent] = []
        var buffer = [UInt8](repeating: 0, count: 4_096), stdoutClosed = false, stderrClosed = false, stderrBytes = 0
        func drain(_ fd: Int32, isError: Bool) throws {
            for _ in 0..<40 {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n == 0 { if isError { stderrClosed = true } else { stdoutClosed = true }; return }
                if n < 0 {
                    guard errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK else { throw ImageDecodeDiagnosticError.invalidProtocol }
                    return
                }
                if isError {
                    stderrBytes += n
                    guard stderrBytes <= ImageDecodeDiagnosticLimits.stderrBytes else { throw ImageDecodeDiagnosticError.invalidProtocol }
                } else {
                    let batch = try decoder.consume(Data(buffer.prefix(n)))
                    guard batch.allSatisfy({ $0.childPID == process.processIdentifier }) else { throw ImageDecodeDiagnosticError.invalidProtocol }
                    events += batch
                }
            }
        }
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            if !stdoutClosed { try drain(output.fileHandleForReading.fileDescriptor, isError: false) }
            if !stderrClosed { try drain(errors.fileHandleForReading.fileDescriptor, isError: true) }
            if process.isRunning { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard !process.isRunning else { throw ImageDecodeDiagnosticError.exitUnconfirmed }
        process.waitUntilExit()
        let drainDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while (!stdoutClosed || !stderrClosed) && ProcessInfo.processInfo.systemUptime < drainDeadline {
            if !stdoutClosed { try drain(output.fileHandleForReading.fileDescriptor, isError: false) }
            if !stderrClosed { try drain(errors.fileHandleForReading.fileDescriptor, isError: true) }
            if !stdoutClosed || !stderrClosed { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard stdoutClosed, stderrClosed else { throw ImageDecodeDiagnosticError.invalidProtocol }
        try decoder.finish(); return events
    }

    private func expectedPixels() -> Data {
        let palette: [[UInt8]] = [[255, 0, 0, 255], [0, 128, 0, 128], [0, 0, 64, 64], [192, 192, 0, 192],
                                 [0, 0, 0, 0], [0, 255, 255, 255], [1, 1, 1, 1], [0, 0, 0, 255]]
        var bytes = Data(count: 768 * 576 * 4)
        bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for y in 0..<576 { for x in 0..<768 {
                let pixel = palette[(x / 96 + 3 * (y / 72)) % palette.count], offset = (y * 768 + x) * 4
                for channel in 0..<4 { raw[offset + channel] = pixel[channel] }
            } }
        }
        return bytes
    }
    private func put(_ value: UInt32, in data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
    }
    private func repairIHDRCRC(_ data: inout Data) {
        var crc = UInt32.max
        for byte in data[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        put(crc ^ UInt32.max, in: &data, at: 29)
    }
    private func fixturePNG() throws -> Data {
        // Deterministic 768x576 RGBA8 PNG with explicit sRGB, one IDAT, no
        // metadata, and asymmetric 96x72 tiles. Channels are 0 or 255 and
        // alpha is 0, 1, 64, 128, 192 or 255, making premultiplication exact.
        try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64, options: .ignoreUnknownCharacters))
    }
    private static let fixtureBase64 = """
    iVBORw0KGgoAAAANSUhEUgAAAwAAAAJACAYAAAA6rgFWAAAAAXNSR0IArs4c6QAAHyhJREFUeNrt2IENAjEMBEHTGaVRGp2F0MSvLA2nLQHF83NmjrruPgqb
    81bX/RN8FTZW7r4CR13391LX/G8gdTnCAQAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEAAAgAAEAAAAACAAAwAAAAAQAACAAAQAAAAAYAACAA
    AAABAAAIAAAAABzhAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAA5wgEA
    AAwAAEAAAAACAAAQAACAAQAACAAAQAAAAAIAADAAAAABAAAIAABAAAAABgAAIAAAAAEAAAgAAMAAAAAEAAAgAAAAAQAAGAAAAAA4wgEAAAQAACAAAAABAAAI
    AABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAGAAAAACAAAQAACAAAAADAAAQAAAAAIAABAAAIAB
    AAAIAABAAAAAAgAAMAAAAAEAAAgAAEAAAAAGAAAgAAAAAQAACAAAwAAAAAQAAAAAjnAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAA
    AgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAAAA4xAEAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEA
    AAgAAEAAAAACAAAwAAAAAQAACAAAAAAc4QAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAA
    AAAEAAAgAAAAAHCIAwAACAAAwAAAAAQAACAAAAABAAAYAACAAAAABAAAIAAAAAMAABAAAIAAAAAEAABgAAAAAgAAEAAAgAAAAAwAAEAAAAACAAAQAAAAAAgA
    AEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAAAACAAAwAAAAAQAACAAAQAAA
    AAYAACAAAAABAAAIAADAAAAABAAAIAAAAAEAABgAAIAAAAAEAAAgAAAAAwAAEAAAgAAAAAQAAGAAAAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAA
    AAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAAAAABgAAIAAAAAEAAAgAAAAAwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAADAAA
    QACwCwAeQQ+wB1geYA+wHs9HMB/gfIBTliMcAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAA
    EAAAgAAAAAQAAAAAAgAAEAAAgAEAAAgAAEAAAAACAAAwAAAAAQAACAAAQAAAAAYAACAAAAABAAAIAADAAAAABAAAIAAAAAEAABgAAIAAAAAEAAAgAAAAAHCE
    AwAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAAwBEOAABgAAAAAgAAEAAA
    gAAAAAwAAEAAAAACAAAQAACAAQAACAAAQAAAAAIAADAAAAABAAAIAABAAAAABgAAIAAAAAEAAAgAAMAAAAAAwBEOAAAgAAAAAQAACAAAQAAAAAIAABAAAIAA
    AAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAAAAAAwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAADAAAQAAAAAIAABAA
    AIABAAAIAABAAAAAAgAAMAAAAAEAAAgAAEAAAAAGAAAgAAAAAHCEAwAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAg
    AAAAAQAACAAAQAAAAAIAABAAAIAAAAAAwCEOAAAgAAAAAQAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAA
    gAEAAAgAAEAAAAAA4AgHAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAACA
    AAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEAAAgAAEAAAAACAAAwAAAAAQAACAAAQAAAAAYAACAAAAABAAAIAAAAAAQAACAAAAABAAAIAABA
    AAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAcoQDAAAIAADAAAAABAAAIAAAAAEAABgAAIAAAAAEAAAg
    AAAAAwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAADAAAQAAAAAIAABAAAIABAAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAI
    AABAALAMAB5BD7AHWB5gD7CezkcwH+B8gFOZQxwAAEAAAAACAAAwAAAAAQAACAAAQAAAAAYAACAAAAABAAAIAADAAAAABAAAIAAAAAEAABgAAIAAAAAEAAAg
    AAAAAwAAEAAAgAAAAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAAA
    EAAAgAAAAAwAAEAAAAACAAAQAACAAQAACAAAQAAAAAIAADAAAAABAAAIAABAAAAABgAAIAAAAAEAAAgAAMAAAAAEAAAgAAAAAQAAAIAAAAAEAAAgAAAAAQAA
    CAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQI5wAAAAAQAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAA
    BAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEAAAgAAEAAAAACAAAwBzgAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAA
    CAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQI5wAAAAAwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAADAAAQAAAAAIAABAAAIABAAAIAABAAAAAAgAA
    MAAAAAEAAAgAAEAAAAAGAAAgRzgAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAA
    CAAAQI5wAAAAAQAACAAAQAAAAAYAACAAAAABAAAIAADAAAAABAAAIAAAAAEAABgAAIAAAAAEAAAgAAAAAwAAEAAAgAAAAAQAAGAAAAACAAAAAEc4AACAAAAA
    BAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAECOcAAAAAEAAAgAAMAAAAAEAAAgAAAA
    AQAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAAABHOAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAA
    AAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAA
    gAHAnjyCHmAPsDzAHmA9n49gPsD5AKfsA5wjHAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIA
    ABAAAIAAAAAEAAAAAI5wAAAAAQAACAAAwAAAAAQAACAAAAABAAAYAACAAAAABAAAIAAAAAMAABAAAIAAAAAEAABgAAAAAgAAEAAAgAAAAAwAAEAAAAACAAAA
    AEc4AACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAAAABAAAIAAAAAMAABAA
    AIAAAAAEAABgAAAAAgAAEAAAgAAAAAwAAEAAAAACAAAQAACAAQAACAAAQAAAAAIAADAAAAABAAAIAABAAAAAAOAIBwAAEAAAgAAAAAQAACAAAAABAAAIAABA
    AAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAA5wAEAABzhAAAABgAAIAAAAAEAAAgAAMAAAAAEAAAgAAAAAQAAGAAAgAAA
    AAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAAAAABziAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAAB
    AAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAAAMAAAAAEAAAgAAEAAAAAGAAAgAAAAAQAACAAAwAAAAAQAACAAAAABAAAYAACAAAAABAAAIAAAAAMAABAAAIAA
    AAAEAABgAAAAAgAAAABHOAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAAAA
    AAQAACAAAAABAAAYAACAAAAABAAAIAAAAAMAABAAAIAAAAAEAABgAAAAAgAAEAAAgAAAAAwAAEAAAAACAAAQAACAAQAACAAAQAAAAAAgAAAAAQAACAAAQAAA
    AAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAAAACAAAQAAAAAYAACAAAAABAAAIAADAAAAABAAA
    IAAAAAEAABgAAIAAAAAEAAAgAAAAAwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAA
    BAAAIABYBQDzAHuA5QH2ACt5gH0E8wHOBzglOcEBAAAEAAAgAAAAAQAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAA
    AgAAEAAAgAEAAAgAAECOcAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACA
    HOEAAAACAAAQAACAAQAACAAAQAAAAAIAADAAAAABAAAIAABAAAAABgAAIAAAAAEAAAgAAMAAAAAEAAAgAAAAAQAAGAAAgAAAAAQAAAAAjnAAAAABAAAIAABA
    AAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAAAAIAABAAAAABgAAIAAAAAEAAAgAAMAAAAAE
    AAAgAAAAAQAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAAwBEOAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAA
    CAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAAAAARzgAAIABAAAIAABAAAAAAgAAMAAAAAEAAAgAAEAAAAAGAAAgAAAAAQAACAAAwAAAAAQA
    ACAAAAABAAAYAACAAAAABAAAIAAAAAMAAAAARzgAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAE
    AAAgAAAAAQAACAAAAAAMAABAAAAAAgAAEAAAgAEAAAgAAEAAAAACAAAwAAAAAQAACAAAQAAAAAYAACAAAAABAAAIAADAAAAABAAAIAAAAAEAABgAAIAAAAAA
    wBEOAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAAAAAhzgAAIAAAAAEAABg
    AAAAAgAAEAAAgAAAAAwAAEAAAAACAAAQAACAAQAACAAAQAAAAAIAADAAAAABAAAIAABAAAAABgAAIAAAAAEAAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQ
    AACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAAAIAAAAAEAABgAAIAAAAAEAAAgAAAAAwAAEAAAgAAAAAQAAGAAAAAC
    AAAQAACAAGAXADyCHmAPsDzAHmAF+QjmA5wPcOo+wDnCAQAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAA
    BAAAIAAAAAEAAAgAAEAAAAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEAAAgAAEAAAAACAAAwAAAAAQAACAAAQAAAAAYAACAAAAABAAAIAADAAAAA
    BAAAAACOcAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAAAAAAgAAEAAAAAC
    AAAwAAAAAQAACAAAQAAAAAYAACAAAAABAAAIAADAAAAABAAAIAAAAAEAABgAAIAAAAAEAAAgAAAAAwAAEAAAgAAAAABAAAAAAgAAEAAAgAAAAAQAACAAAAAB
    AAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAAAEAAAgAAAAAwAAEAAAAACAAAQAACAAQAACAAAQAAAAAIAADAA
    AAABAAAIAABAAAAABgAAIAAAAAEAAAgAAMAAAAAEAAAgAAAAAQAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIA
    ABAAAIAAAAAEAAAgAAAAAQAACAAAQI5wAAAAAQAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEAAAgA
    AEAAAAACAAAwRzgAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQI5wAAAA
    AwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAADAAAQAAAAAIAABAAAIABAAAIAABAAAAAAgAAMAAAAAEAAAgAAEAAAAAGAAAAAI5wAAAAAQAACAAAQAAAAAIA
    ABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAc4QAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEA
    AAgAAEAAAAACAAAwAAAAAQAACAAAQAAAAAYAACAAAAABAAAIAADAAAAABAAAAACOcAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAAC
    AAAQAACAAGAVADyCHmAPsHmAPcAqHmD5AOcDnJoPcI5wAAAAAwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAADAAAQAAAAAIAABAAAIABAAAIAABAAAAAAgAA
    MAAAAAEAAAgAAEAAAAAGAAAAAI5wAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIA
    ABAAAAAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEAAAgAAEAAAAACAAAwAAAAAQAAAIAjHAAAQAAA
    AAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAAAA5xAAAAAQAACAAAwAAAAAQAACAA
    AAABAAAYAACAAAAABAAAIAAAAAMAABAAAIAAAAAEAABgAAAAAgAAEAAAgAAAAAwAAEAAAAACAAAAAEc4AACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACA
    AAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAAAABAAAIAAAAAMAABAAAIAAAAAEAABgAAAAAgAAEAAAgAAAAAwAAEAAAAACAAAQ
    AACAAQAACAAAQAAAAAIAADAAAAABAAAIAABAAAAAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAAB
    AAAIAABAAAAAAgAAkCMcAABAAAAABgAAIAAAAAEAAAgAAMAAAAAEAAAgAAAAAQAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAM
    AAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAAAADAAAQAACAAAAA
    BAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEAAAgAAEAAAAACAAAwAAAAAQAACAAAQAAAAAYAACBHOAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAA
    EAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABATnAAAAABAAAIAABAAAAABgAAIAAAAAEAAAgAAMAAAAAEAAAgAAAAAQAA
    GAAAgAAAAAQAqwDgEfQAe4DlAfYAq3iAfQjzAc4HOGs+wDnCAQAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACA
    AAAABAAAIAAAAAEAAAgAAEAAAAByhAMAABgAAIAAAAAEAAAgAAAAAwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAADAAAQAAAAAIAABAAAIABAAAIAABAAAAA
    AgAAMAAAAABwhAMAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAAAMAAAAAE
    AAAgAAAAAQAAGAAAgAAAAAQAACAAAAADAAAQAACAAAAABAAAYAAAAAIAABAAAIAAAAAMAABAAAAAAgAAEAAAgAEAAAgAAAAAHOEAAAACAAAQAACAAAAABAAA
    IAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAABwhAMAAAgAAEAAAAAGAAAgAAAAAQAACAAAwAAAAAQA
    ACAAAAABAAAYAACAAAAABAAAIAAAAAMAABAAAIAAAAAEAABgAAAAAgAAEAAAAAA4wgEAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAI
    AABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAACAAAAABAAAYAACAAAAABAAAIAAAAAMAABAAAIAAAAAEAABgAAAAAgAAEAAAgAAAAAwAAEAAAAAC
    AAAQAACAAQAACAAAQAAAAAIAAAAAhzgAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAA
    AQAAyAEOAAAgAAAAAwAAEAAAgAAAAAQAAGAAAAACAAAQAACAAAAADAAAQAAAAAIAABAAAIABAAAIAABAAAAAAgAAMAAAAAEAAAgAAEAAAAAGAAAAAAIAABAA
    AIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAAAIABAAAIAABAAAAAAgAAMAAAAAEA
    AAgAAEAAAAAGAAAgAAAAAQAACAAAwAAAAAQAACAAAAABAAAYAACAAAAABAAAIAAAAAMAABAAAAAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAA
    AAIAABAAAIAAAAAEAJv2A0w/ADAdyCmfAAAAAElFTkSuQmCC
    """
}
