import XCTest
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PicShotCodecCore
@testable import PicShotCodecHelper

final class CodecHelperLifecycleTests: XCTestCase {
    func testStrictArgumentsAndCancellationWinsTerminalRace() throws {
        try PicShotCodecHelper.validateArguments([])
        XCTAssertThrowsError(try PicShotCodecHelper.validateArguments(["--input", "/anywhere"]))
        let state = CodecHelperRunState()
        state.cancel(.cancelled); state.cancel(.memoryLimit)
        state.complete(.init(kind: .result, format: .webp, outputBytes: 42, width: 1, height: 1,
                             frameCount: 1, duration: 0, previewBytes: 64, sha256: String(repeating: "0", count: 64)))
        XCTAssertTrue(state.isComplete); XCTAssertTrue(state.isCancelled)
        XCTAssertEqual(state.response.kind, .error); XCTAssertEqual(state.response.errorCode, .cancelled)
        XCTAssertNotNil(state.cancelledAt)
    }
    func testHelperOneJobSuccessExitsAndProducesVerifiedBytes() throws {
        let directory = try stagePNG()
        defer { CodecTemporaryJob.removeOwned(directory) }
        let request = CodecExportRequest(format: .webp, lossless: true)
        let result = try run(directory: directory, input: CodecExportProtocol.encodeRequestLine(request), closeInput: false)
        XCTAssertEqual(result.status, 0)
        let terminal = try XCTUnwrap(result.responses.last)
        XCTAssertEqual(terminal.kind, .result); try terminal.validate(for: request)
        XCTAssertEqual(terminal.width, 13); XCTAssertEqual(terminal.height, 9)
        XCTAssertGreaterThan(terminal.residentSampleCount ?? 0, 0)
        let output = try Data(contentsOf: directory.appendingPathComponent("output.webp"))
        try CodecOutputMagic.validate(output, format: .webp)
        XCTAssertEqual(output.count, terminal.outputBytes)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("preview.png")).count, terminal.previewBytes)
        XCTAssertLessThanOrEqual(result.responses.count, CodecExportLimits.progressEvents + 1)
    }
    func testHelperRejectsMalformedRequestAndExits() throws {
        let directory = try stagePNG(); defer { CodecTemporaryJob.removeOwned(directory) }
        let result = try run(directory: directory, input: Data("{\"version\":1,\"command\":\"anything\"}\n".utf8), closeInput: false)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.responses.last?.kind, .error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("output.webp").path))
    }
    func testHelperCancellationAndControlEOFDoNotReportSuccess() throws {
        for close in [false, true] {
            let directory = try stagePNG(); defer { CodecTemporaryJob.removeOwned(directory) }
            var input = try CodecExportProtocol.encodeRequestLine(.init(format: .avif, lossless: true))
            if !close { input.append(CodecExportProtocol.cancelLine) }
            let result = try run(directory: directory, input: input, closeInput: close)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertNotEqual(result.responses.last?.kind, .result)
        }
    }
    private func helperExecutable() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["PICSHOT_CODEC_HELPER_PATH"] { return URL(fileURLWithPath: path) }
        let bundle = Bundle(for: CodecHelperLifecycleTests.self).bundleURL
        let candidates = [bundle.deletingLastPathComponent().appendingPathComponent("PicShotCodecHelper"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("PicShotCodecHelper")]
        // Missing the real executable is a failed native gate, never a skip.
        return try XCTUnwrap(candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
                             "Build PicShotCodecHelper or supply PICSHOT_CODEC_HELPER_PATH for the native lifecycle gate")
    }
    private func stagePNG() throws -> URL {
        let directory = try CodecTemporaryJob.create(in: FileManager.default.temporaryDirectory)
        do {
            let raster = try CodecRaster(width: 13, height: 9, rgba: [UInt8](repeating: 255, count: 13 * 9 * 4))
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try raster.image(), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent("input.png").path,
                contents: data as Data, attributes: [.posixPermissions: 0o600]))
            return directory
        } catch { CodecTemporaryJob.removeOwned(directory); throw error }
    }
    private func run(directory: URL, input: Data, closeInput: Bool) throws -> (status: Int32, responses: [CodecExportResponse]) {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = try helperExecutable(); process.currentDirectoryURL = directory
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            try? stdin.fileHandleForWriting.close()
        }
        try stdin.fileHandleForWriting.write(contentsOf: input)
        if closeInput { try stdin.fileHandleForWriting.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { XCTFail("Codec helper failed to exit within lifecycle test budget"); throw CodecExportFailure(.deadline) }
        process.waitUntilExit()
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let diagnostics = try stderr.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertLessThanOrEqual(output.count, CodecExportLimits.stdoutBytes)
        XCTAssertLessThanOrEqual(diagnostics.count, CodecExportLimits.stderrBytes)
        var responses: [CodecExportResponse] = []
        for line in output.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            responses.append(try CodecExportProtocol.decodeResponseLine(Data(line)))
        }
        XCTAssertEqual(output.last, 10)
        XCTAssertEqual(responses.filter { $0.kind != .progress }.count, 1)
        return (process.terminationStatus, responses)
    }
}
