import XCTest
import Foundation
import Darwin
@testable import PicShot

final class CodecExportProcessShellFixtureTests: XCTestCase {
    func testCompleteRequestEmitsExactProgressOnceAndExecKeepsTheOwnedPID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshot-shell-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("must-not-exist")
        let child = try Child(); defer { child.cleanup() }
        let ownedPID = child.process.processIdentifier
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        // Inert request data includes command substitution and metacharacters.
        // It is sent over stdin, never concatenated into the fixture program.
        try child.input.fileHandleForWriting.write(contentsOf: Data("$(touch '\(marker.path)'); `false` \\".utf8))
        XCTAssertTrue(try child.readOutput(until: ProcessInfo.processInfo.systemUptime + 0.05).isEmpty)
        guard child.process.isRunning else { return XCTFail("Fixture exited before receiving a complete request") }
        try child.input.fileHandleForWriting.write(contentsOf: Data("\nsecond request must not emit another event\n".utf8))
        let output = try child.readOutput(until: deadline, stopAfterBytes: CodecGIFLeaseFixture.progressBytes.count)
        XCTAssertEqual(output, CodecGIFLeaseFixture.progressBytes)
        XCTAssertEqual(output.count, 45)
        while executablePath(ownedPID) != "/bin/sleep", child.process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
        guard child.process.isRunning else { return XCTFail("Fixture must remain live after progress") }
        XCTAssertEqual(child.process.processIdentifier, ownedPID)
        XCTAssertEqual(executablePath(ownedPID), "/bin/sleep", "exec must replace the owned shell, not leave it waiting for another child")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        child.process.terminate()
        guard child.waitForExit(until: ProcessInfo.processInfo.systemUptime + 2) else {
            return XCTFail("Owned fixture must confirm termination")
        }
        XCTAssertEqual(child.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.process.terminationStatus, SIGTERM)
        XCTAssertTrue(try child.readOutput(until: ProcessInfo.processInfo.systemUptime + 0.1).isEmpty)
    }

    func testEOFAndIncompleteRequestExitWithoutFabricatingReadiness() throws {
        for request in [Data(), Data("unterminated request".utf8)] {
            let child = try Child(); defer { child.cleanup() }
            try child.input.fileHandleForWriting.write(contentsOf: request)
            try child.input.fileHandleForWriting.close()
            guard child.waitForExit(until: ProcessInfo.processInfo.systemUptime + 3) else {
                return XCTFail("Incomplete request must exit within its fixture budget")
            }
            XCTAssertEqual(child.process.terminationReason, .exit)
            XCTAssertEqual(child.process.terminationStatus, 2)
            XCTAssertTrue(try child.readOutput(until: ProcessInfo.processInfo.systemUptime + 0.1).isEmpty)
        }
    }

    func testShellEvidenceMarksChildTimingUnavailableWithoutPythonMilestones() throws {
        let evidence = CodecGIFReadinessEvidence()
        evidence.captureChildTrace(phase: "afterReadinessAssertion")
        evidence.captureChildTrace(phase: "afterTaskJoin")
        let data = try XCTUnwrap(evidence.encodedPayload(finalSnapshot: nil))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["schema"] as? String, "picshot-codec-gif-readiness-v3")
        XCTAssertEqual(payload["expectedProgressBytes"] as? Int, 45)
        XCTAssertEqual(payload["childTraceStatus"] as? String, "notCollectedForShellFixture")
        let captures = try XCTUnwrap(payload["childTraceCaptures"] as? [[String: Any]])
        XCTAssertEqual(captures.count, 2)
        for capture in captures {
            XCTAssertEqual(capture["status"] as? String, "notCollectedForShellFixture")
            XCTAssertEqual((capture["records"] as? [[String: Any]])?.count, 0)
            XCTAssertNil(capture["bytesRead"], "No sidecar was read; zero bytes would imply a different observation")
        }
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("interpreterReady"))
        XCTAssertFalse(json.contains("pythonVersion"))
        XCTAssertLessThanOrEqual(data.count, 16_384)
    }

    private func executablePath(_ pid: Int32) -> String? {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    private final class Child {
        let process = Process()
        let input = Pipe()
        private let output = Pipe()

        init() throws {
            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw CodecProcessTestSupportError.failed("Cannot prepare bounded fixture pipes")
            }
            process.executableURL = CodecGIFLeaseFixture.executableURL
            process.arguments = CodecGIFLeaseFixture.arguments
            process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "C"]
            process.standardInput = input; process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }

        func readOutput(until deadline: Double, stopAfterBytes: Int = Int.max) throws -> Data {
            var result = Data(), bytes = [UInt8](repeating: 0, count: 128)
            while ProcessInfo.processInfo.systemUptime < deadline {
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count == 0 { break }
                if count > 0 {
                    result.append(contentsOf: bytes.prefix(count))
                    guard result.count <= 256 else { throw CodecProcessTestSupportError.failed("Fixture emitted excess output") }
                    if result.count >= stopAfterBytes { break }
                } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    throw CodecProcessTestSupportError.failed("Fixture output read failed")
                } else { Thread.sleep(forTimeInterval: 0.005) }
            }
            return result
        }

        func waitForExit(until deadline: Double) -> Bool {
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
            guard !process.isRunning else { return false }
            process.waitUntilExit() // Exit already observed; do not wait on a live child.
            return true
        }

        func cleanup() {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            XCTAssertTrue(waitForExit(until: ProcessInfo.processInfo.systemUptime + 2), "Owned fixture child must exit")
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
    }
}
