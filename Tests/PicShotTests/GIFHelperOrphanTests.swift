import XCTest
import Darwin
import Foundation
@testable import PicShot

final class GIFHelperOrphanTests: XCTestCase {
    func testRealHelperControlEOFExitsWithoutOrdinaryAppActivationAndCleansOwnedJob() async throws {
        let app = try GIFProcessTestApplication.make()
        defer { app.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GIF-Orphan-Test-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await GIFResourceSmokeFixture.makeMovie(in: root, profile: .quickTest)
        let originalBytes = try Data(contentsOf: original)
        let job = root.appendingPathComponent(".picshot-gif-job-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = job.appendingPathComponent("source.mp4")
        try FileManager.default.copyItem(at: original, to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let process = Process()
        process.executableURL = try GIFHelperExecutable.verified(bundleURL: app.bundleURL)
        process.arguments = ["--picshot-gif-helper"]
        process.currentDirectoryURL = job
        process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": job.path, "LANG": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let request = GIFHelperRequest(options: .init(frameRate: 30, maximumDimension: 128,
            maximumDuration: 2, maximumFrames: 60), frameExtraction: .asynchronous)
        try input.fileHandleForWriting.write(contentsOf: GIFHelperProtocol.encodeRequestLine(request))
        try input.fileHandleForWriting.close() // Complete request followed by loss of parent control.
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let exitedWithoutTestKill = !process.isRunning
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        let killDeadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(process.isRunning, "Owned helper exit must be confirmed even when the regression fails")
        guard !process.isRunning else { return }
        process.waitUntilExit()
        XCTAssertTrue(exitedWithoutTestKill, "EOF must trigger bounded helper-only shutdown, not launch the ordinary app")
        XCTAssertNotEqual(process.terminationStatus, 0)
        let bytes = try boundedRead(output.fileHandleForReading, maximum: GIFHelperLimits.stdoutBytes)
        let lines = bytes.split(separator: 10)
        XCTAssertFalse(lines.isEmpty, "Helper-only startup should emit the bounded protocol, not an ordinary GUI launch")
        let events = try lines.map { try GIFHelperProtocol.decodeEventLine(Data($0)) }
        XCTAssertEqual(events.last?.kind, .error)
        XCTAssertEqual(events.last?.errorCode, "cancelled")
        XCTAssertFalse(events.contains { $0.kind == .result })
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.path), "Orphan cleanup must remove only its validated private job")
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    private func boundedRead(_ handle: FileHandle, maximum: Int) throws -> Data {
        var result = Data()
        while true {
            let next = try handle.read(upToCount: min(4_096, maximum + 1 - result.count)) ?? Data()
            if next.isEmpty { return result }
            result.append(next)
            guard result.count <= maximum else { throw GIFExportProcessError.invalidProtocol }
        }
    }
}
