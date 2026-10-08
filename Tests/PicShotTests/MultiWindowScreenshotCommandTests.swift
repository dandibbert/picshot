import XCTest
import AppKit
import Darwin
import ImageIO
import PicShotCore
@testable import PicShot

final class MultiWindowScreenshotCommandTests: XCTestCase {
    func testInstalledSystemCommandDocumentsWindowShadowAndPNGFlags() throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-h"] // Help only: no capture or permission request.
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let help = String(data: data, encoding: .utf8) ?? ""
        for flag in ["-l", "-o", "-t", "-x"] { XCTAssertTrue(help.contains(flag), "Installed system command does not document \(flag)") }
    }

    /// A finite 4 KiB write verifies the installed shell's actual byte boundary,
    /// even when POSIX mode was enabled before entering the production prelude.
    func testNativeShellFileLimitUses1024ByteBlocks() throws {
        try assertNativeFileLimit(prelude: "set -o posix || exit 71; " +
            MultiWindowScreenshotCommand.fileLimitPrelude(bytes: 2_048),
            expectedBytes: 2_048, blockBytes: 4_096, blockCount: 1)
    }
    /// Use the same default prelude as live capture, without the polling guard.
    /// The OS must stop an attempted 81 MiB write at exactly 80 MiB. The finite
    /// count also bounds disk use if the production limit regresses or is absent.
    func testNativeShellEnforcesProduction80MiBFileLimit() throws {
        XCTAssertEqual(MultiWindowCaptureLimits.temporaryBytes, 80 * 1_024 * 1_024)
        try assertNativeFileLimit(prelude: MultiWindowScreenshotCommand.fileLimitPrelude(),
            expectedBytes: 80 * 1_024 * 1_024, blockBytes: 1_024 * 1_024, blockCount: 81)
    }
    func testOwnedPNGDecodeCleansTemporaryDirectoryWithoutSystemCapture() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("owned source $(ignored) ' quote.png")
        try writeImage(to: png)
        let configuration = MultiWindowCommandConfiguration(temporaryRoot: root, arguments: { _, output in
            ["-c", MultiWindowScreenshotCommand.fileLimitPrelude() + "exec /bin/cp \"$1\" \"$2\"", "PicShot-owned-PNG-fixture", png.path, output.path]
        })
        let result = try await MultiWindowScreenshotCommand.capture(descriptor(), deadline: uptime + 5, configuration: configuration)
        XCTAssertEqual(result.width, 2); XCTAssertEqual(result.height, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [png.lastPathComponent])
    }
    func testCancellationAndDeadlineReapOwnedChildAndRemovePartialDirectory() async throws {
        for cancel in [false, true] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let state = LaunchedWindowChild()
            let configuration = MultiWindowCommandConfiguration(temporaryRoot: root,
                arguments: { _, _ in ["-c", "exec /bin/sleep 10", "PicShot-owned-sleep-fixture"] }, didLaunch: { state.set($0) })
            let source = try descriptor(), deadline = uptime + (cancel ? 5 : 0.2)
            let task = Task { try await MultiWindowScreenshotCommand.capture(source, deadline: deadline, configuration: configuration) }
            let until = uptime + 3
            while state.pid == nil && uptime < until { try await Task.sleep(nanoseconds: 5_000_000) }
            let pid = try XCTUnwrap(state.pid)
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("Stopped process produced an image") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } else { XCTAssertEqual(error as? MultiWindowCaptureError, .deadline) } }
            XCTAssertEqual(Darwin.kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    func testCommandFailureKeepsExitStatusAndRemovesFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MultiWindowCommandConfiguration(temporaryRoot: root, arguments: { _, output in
            ["-c", "printf partial > \"$1\"; exit 37", "PicShot-owned-failure-fixture", output.path]
        })
        do { _ = try await MultiWindowScreenshotCommand.capture(descriptor(), deadline: uptime + 5, configuration: configuration); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("37")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    private func assertNativeFileLimit(prelude: String, expectedBytes: Int, blockBytes: Int, blockCount: Int,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let manager = FileManager.default, root = try directory()
        defer { try? manager.removeItem(at: root) }
        let output = root.appendingPathComponent("limit $(ignored) ' quote.bin"), process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", prelude +
            // Raising only the soft limit must fail: the prelude also sets the hard limit.
            "if ulimit -S -f \(expectedBytes / 1_024 + 1) 2>/dev/null; then exit 73; fi; " +
            "exec /bin/dd if=/dev/zero of=\"$1\" bs=\(blockBytes) count=\(blockCount)",
            "PicShot-file-limit-fixture", output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = uptime + 10
        while process.isRunning && uptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            XCTFail("Owned file-limit fixture exceeded its deadline", file: file, line: line)
            return
        }
        process.waitUntilExit()
        guard process.terminationStatus != 73 else {
            XCTFail("The child raised its soft file limit above the required hard limit", file: file, line: line)
            return
        }
        XCTAssertNotEqual(process.terminationStatus, 0, file: file, line: line)
        let attributes = try manager.attributesOfItem(atPath: output.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular, file: file, line: line)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid(), file: file, line: line)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, expectedBytes,
                       "The installed shell must enforce the exact file-size bound in bytes", file: file, line: line)
        try manager.removeItem(at: root)
        XCTAssertFalse(manager.fileExists(atPath: root.path), file: file, line: line)
    }
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Owned-Window-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func descriptor() throws -> MultiWindowDescriptor {
        try MultiWindowDescriptor(id: 1, ownerPID: 10, ownerStartedAt: 1, label: "Owned fixture", bounds: CGRect(x: 0, y: 0, width: 2, height: 2), maximumScale: 1)
    }
    private func writeImage(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage()), destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class LaunchedWindowChild: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var pid: Int32? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ pid: Int32) { lock.lock(); value = pid; lock.unlock() }
}
