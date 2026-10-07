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

    /// Executes the installed macOS shell with the production prelude. A hard
    /// filesize cap of two POSIX blocks must stop dd at exactly 1,024 bytes.
    func testNativePOSIXShellFileLimitIsBytesNotAddressSpace() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("limit.bin"), process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", MultiWindowScreenshotCommand.fileLimitPrelude(blocks: 2) +
            "exec /bin/dd if=/dev/zero of=\"$1\" bs=4096 count=1", "PicShot-file-limit-fixture", output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, 1_024, "Do not claim an 80MiB hard bound unless the native shell uses 512-byte blocks")
        XCTAssertEqual(MultiWindowCaptureLimits.temporaryBytes / 512, 163_840)
    }
    func testOwnedPNGDecodeCleansTemporaryDirectoryWithoutSystemCapture() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("owned source $(ignored) ' quote.png")
        try writeImage(to: png)
        let configuration = MultiWindowCommandConfiguration(temporaryRoot: root, arguments: { _, output in
            ["-c", MultiWindowScreenshotCommand.fileLimitPrelude(blocks: 163_840) + "exec /bin/cp \"$1\" \"$2\"", "PicShot-owned-PNG-fixture", png.path, output.path]
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
