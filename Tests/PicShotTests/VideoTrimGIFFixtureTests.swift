import XCTest
import Foundation
import Darwin
@testable import PicShot

final class VideoTrimGIFFixtureTests: XCTestCase {
    func testReadinessRequiresCompleteRequestAndClosedMarkerBeforeReleaseReadback() throws {
        let child = try Child(); defer { child.cleanup() }
        let request = try VideoTrimGIFFixture.requestLine()
        _ = try GIFHelperProtocol.decodeRequestLine(request)
        try child.input.fileHandleForWriting.write(contentsOf: request.dropLast())
        XCTAssertTrue(try child.readOutput(seconds: 0.05).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.marker.path))
        try child.input.fileHandleForWriting.write(contentsOf: Data("\n{\"cancel\":true}\n".utf8))
        XCTAssertEqual(try child.readOutput(seconds: 3, stopAfterBytes: VideoTrimGIFFixture.progressBytes.count),
                       VideoTrimGIFFixture.progressBytes)
        let marker = try VideoTrimGIFFixture.ChildMarker(data: Data(contentsOf: child.marker))
        XCTAssertEqual(marker.pid, child.process.processIdentifier)
        // /var and /private/var may name the same directory on macOS even
        // after Foundation URL resolution. Compare the actual filesystem
        // objects, with both endpoints required to be directories.
        var markerDirectory = stat(), expectedDirectory = stat()
        guard lstat(marker.directory, &markerDirectory) == 0,
              lstat(child.root.path, &expectedDirectory) == 0 else {
            throw GIFProcessTestSupportError.failed("Cannot inspect trim GIF child directory identity")
        }
        XCTAssertEqual(markerDirectory.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(expectedDirectory.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(markerDirectory.st_dev, expectedDirectory.st_dev)
        XCTAssertEqual(markerDirectory.st_ino, expectedDirectory.st_ino)
        XCTAssertTrue(child.process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.readback.path))
        // Control cancellation is intentionally ignored by this stranded-child
        // fixture. It must not emit a second readiness event or read input yet.
        XCTAssertTrue(try child.readOutput(seconds: 0.05).isEmpty)
        XCTAssertGreaterThan(VideoTrimGIFFixture.trimReadyFraction, 0.4)
        XCTAssertLessThan(VideoTrimGIFFixture.trimReadyFraction, 1)
        try Data().write(to: child.release)
        XCTAssertEqual(try child.exitStatus(seconds: 3), 0)
        XCTAssertEqual(try Data(contentsOf: child.readback), child.sourceBytes)
    }

    func testProcessServiceAcceptsInitialProgressThenDistinctReadinessBeforeCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picshot-trim-gif-protocol-'quote space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let sourceBytes = Data([0, 255, 39, 34, 10, 92, 1, 2, 3])
        try sourceBytes.write(to: source)
        let destination = root.appendingPathComponent("must-not-publish.gif")
        let marker = root.appendingPathComponent("child.ready")
        let release = root.appendingPathComponent("release")
        let readback = root.appendingPathComponent("readback.mp4")
        let progress = GIFProcessTestProgress()
        let cancellation = GIFProcessTestCancellation()
        // This runs the actual private process-pipe parser, not a replica or
        // a line decoder. Keep the original readiness wall/observer bounds.
        let service = GIFExportProcessService(configuration: .init(
            executable: { VideoTrimGIFFixture.executableURL },
            arguments: try VideoTrimGIFFixture.arguments(marker: marker, release: release, readback: readback),
            wallSeconds: 0.5))
        let operation = InferenceTestOperation {
            try await service.export(sourceURL: source, destinationURL: destination) { value in
                progress.record(value)
                XCTAssertFalse(cancellation.wasRequested, "Every fixture event must precede cancellation")
                if value == VideoTrimGIFFixture.readyFraction {
                    do {
                        let child = try VideoTrimGIFFixture.ChildMarker(data: Data(contentsOf: marker))
                        XCTAssertEqual(Darwin.kill(child.pid, 0), 0, "Readiness must arrive while the actual child is alive")
                        XCTAssertFalse(FileManager.default.fileExists(atPath: readback.path))
                    } catch { XCTFail("Readiness preceded a complete closed marker: \(error)") }
                    cancellation.request()
                }
            }
        }
        cancellation.install { operation.cancel() }
        defer { cancellation.clear(); operation.cancel() }
        do {
            _ = try await operation.value(timeout: 15, phase: "trim GIF fixture actual protocol readiness")
            XCTFail("The readiness callback must cancel export before publication")
        } catch {
            if !(error is CancellationError) {
                await GIFProcessTestDiagnostics.record(service: service, phase: "trim GIF fixture actual protocol readiness",
                    detail: String(describing: error))
            }
            XCTAssertTrue(error is CancellationError, "Expected readiness cancellation, got \(error)")
        }
        XCTAssertEqual(progress.values, [0, VideoTrimGIFFixture.readyFraction])
        XCTAssertTrue(cancellation.wasRequested, "Initial zero alone must not cancel export")
        let state = await service.snapshot()
        XCTAssertFalse(state.active)
        let metrics = try XCTUnwrap(state.lastJob)
        XCTAssertEqual(metrics.outcome, "cancelled")
        XCTAssertEqual(metrics.configuredWallSeconds, 0.5)
        XCTAssertEqual(metrics.stdoutBytes, VideoTrimGIFFixture.progressBytes.count)
        XCTAssertTrue(metrics.childLaunched)
        XCTAssertTrue(metrics.childExitConfirmed)
        XCTAssertTrue(metrics.temporaryDirectoryRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: readback.path))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".picshot-") })
    }

    func testEOFTruncatedEmptyAndWrongRequestsNeverFabricateReadiness() throws {
        let request = try VideoTrimGIFFixture.requestLine()
        for bytes in [Data(), Data(request.dropLast()), Data("\n".utf8), Data("{}\n".utf8)] {
            let child = try Child(); defer { child.cleanup() }
            try child.input.fileHandleForWriting.write(contentsOf: bytes)
            try child.input.fileHandleForWriting.close()
            XCTAssertEqual(try child.exitStatus(seconds: 3), 2)
            XCTAssertTrue(try child.readOutput(seconds: 0.1).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: child.marker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: child.readback.path))
        }
    }

    func testMarkerPublicationFailureDoesNotEmitProgressOrReplaceExistingBytes() throws {
        let child = try Child(); defer { child.cleanup() }
        let previous = Data("previous marker is not owned".utf8)
        try previous.write(to: child.marker)
        try child.input.fileHandleForWriting.write(contentsOf: VideoTrimGIFFixture.requestLine())
        XCTAssertEqual(try child.exitStatus(seconds: 3), 3)
        XCTAssertTrue(try child.readOutput(seconds: 0.1).isEmpty)
        XCTAssertEqual(try Data(contentsOf: child.marker), previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.readback.path))
    }

    func testRequestMetacharactersRemainDataAndCannotCreateFiles() throws {
        let child = try Child(); defer { child.cleanup() }
        let injected = child.root.appendingPathComponent("must-not-exist")
        try child.input.fileHandleForWriting.write(contentsOf: Data("$(touch '\(injected.path)'); `false`\n".utf8))
        XCTAssertEqual(try child.exitStatus(seconds: 3), 2)
        XCTAssertTrue(try child.readOutput(seconds: 0.1).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: injected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.marker.path))
    }

    func testReadbackKeepsOwnedPIDAndRefusesExistingDestination() throws {
        let child = try Child(); defer { child.cleanup() }
        try FileManager.default.removeItem(at: child.source)
        XCTAssertEqual(mkfifo(child.source.path, 0o600), 0)
        try child.input.fileHandleForWriting.write(contentsOf: VideoTrimGIFFixture.requestLine())
        XCTAssertEqual(try child.readOutput(seconds: 3, stopAfterBytes: VideoTrimGIFFixture.progressBytes.count),
                       VideoTrimGIFFixture.progressBytes)
        let ownedPID = child.process.processIdentifier
        try Data().write(to: child.release)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while executablePath(ownedPID) != "/bin/cat", child.process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(executablePath(ownedPID), "/bin/cat", "exec must keep readback in the actual owned child")
        XCTAssertEqual(child.process.processIdentifier, ownedPID)
        // exec identity can become visible before cat opens the FIFO. Wait
        // for that real reader using the same deadline, never a blocking open.
        var descriptor: Int32 = -1
        while descriptor < 0, child.process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            descriptor = open(child.source.path, O_WRONLY | O_NONBLOCK)
            if descriptor < 0 {
                guard errno == ENXIO || errno == EINTR else { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        guard descriptor >= 0 else { return XCTFail("Owned cat did not open its independent source") }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try writer.write(contentsOf: child.sourceBytes)
        try writer.close()
        XCTAssertEqual(try child.exitStatus(seconds: 3), 0)
        XCTAssertEqual(try Data(contentsOf: child.readback), child.sourceBytes)

        let collision = try Child(); defer { collision.cleanup() }
        let previous = Data("unowned readback".utf8)
        try previous.write(to: collision.readback)
        try collision.input.fileHandleForWriting.write(contentsOf: VideoTrimGIFFixture.requestLine())
        XCTAssertEqual(try collision.readOutput(seconds: 3, stopAfterBytes: VideoTrimGIFFixture.progressBytes.count),
                       VideoTrimGIFFixture.progressBytes)
        try Data().write(to: collision.release)
        XCTAssertNotEqual(try collision.exitStatus(seconds: 3), 0)
        XCTAssertEqual(try Data(contentsOf: collision.readback), previous)
    }

    func testChildMarkerRejectsIncompleteInvalidPIDAndExtraFields() throws {
        for bytes in [Data(), Data("123\0/tmp".utf8), Data("0\0/tmp\0".utf8),
                      Data("-1\0/tmp\0".utf8), Data("2147483648\0/tmp\0".utf8),
                      Data("123\0relative\0".utf8), Data("123\0/tmp\0extra".utf8)] {
            XCTAssertThrowsError(try VideoTrimGIFFixture.ChildMarker(data: bytes))
        }
        let path = "/tmp/quote' double\" slash\\ newline\n directory"
        let marker = try VideoTrimGIFFixture.ChildMarker(data: Data("123\0\(path)\0".utf8))
        XCTAssertEqual(marker.pid, 123)
        XCTAssertEqual(marker.directory, path)
    }

    func testUnreleasedChildExitsWithinItsOriginalTwentySecondBoundWithoutReadback() throws {
        let child = try Child(); defer { child.cleanup() }
        try child.input.fileHandleForWriting.write(contentsOf: VideoTrimGIFFixture.requestLine())
        XCTAssertEqual(try child.readOutput(seconds: 3, stopAfterBytes: VideoTrimGIFFixture.progressBytes.count),
                       VideoTrimGIFFixture.progressBytes)
        let readyAt = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try child.exitStatus(seconds: 21), 4)
        // Bash's whole-second SECONDS counter can expire up to one second
        // earlier than the original Python monotonic 20-second upper bound.
        // Observe from readiness so slow fixture launch is not charged twice.
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - readyAt, 21)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.readback.path))
        XCTAssertTrue(try child.readOutput(seconds: 0.1).isEmpty)
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
        let root: URL
        let sourceBytes = Data([0, 255, 39, 34, 10, 92, 1, 2, 3])
        var marker: URL { root.appendingPathComponent("child.ready") }
        var release: URL { root.appendingPathComponent("release") }
        var readback: URL { root.appendingPathComponent("readback.mp4") }
        var source: URL { root.appendingPathComponent("source.mp4") }

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("picshot-trim-gif-'quote space-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            do {
                try sourceBytes.write(to: source)
                let descriptor = output.fileHandleForReading.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                      fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                    throw GIFProcessTestSupportError.failed("Cannot prepare bounded trim GIF fixture pipes")
                }
                process.executableURL = VideoTrimGIFFixture.executableURL
                process.arguments = try VideoTrimGIFFixture.arguments(marker: marker, release: release, readback: readback)
                process.currentDirectoryURL = root
                process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": root.path, "LANG": "C"]
                process.standardInput = input; process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                try? input.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
            } catch { try? FileManager.default.removeItem(at: root); throw error }
        }

        func readOutput(seconds: Double, stopAfterBytes: Int = Int.max) throws -> Data {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            var result = Data(), bytes = [UInt8](repeating: 0, count: 128)
            while ProcessInfo.processInfo.systemUptime < deadline {
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count == 0 { break }
                if count > 0 {
                    result.append(contentsOf: bytes.prefix(count))
                    guard result.count <= 256 else { throw GIFProcessTestSupportError.failed("Fixture emitted excess output") }
                    if result.count >= stopAfterBytes { break }
                } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    throw GIFProcessTestSupportError.failed("Fixture output read failed")
                } else { Thread.sleep(forTimeInterval: 0.005) }
            }
            return result
        }

        func exitStatus(seconds: Double) throws -> Int32 {
            guard waitForExit(seconds: seconds) else {
                throw GIFProcessTestSupportError.failed("Owned trim GIF fixture did not confirm exit within its test deadline")
            }
            return process.terminationStatus
        }

        private func waitForExit(seconds: Double) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
            guard !process.isRunning else { return false }
            process.waitUntilExit()
            return true
        }

        func cleanup() {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            XCTAssertTrue(waitForExit(seconds: 2), "Owned trim GIF fixture must confirm exit")
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
