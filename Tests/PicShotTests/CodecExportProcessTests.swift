import XCTest
import Foundation
import Darwin
import PicShotCodecCore
@testable import PicShot

final class CodecExportProcessTests: XCTestCase {
    func testActualSignedNativeHelperRepeatedDecodeAlphaSaveCancelAndCleanup() async throws {
        let app = try CodecProcessTestApplication.make(); defer { app.cleanup() }
        let evidence = app.root.appendingPathComponent("evidence", isDirectory: true)
        let report = try await CodecExportResourceFixture.verify(evidenceDirectory: evidence, service: app.service(), dimension: 128)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual((report["runs"] as? [[String: Any]])?.count, 6)
        XCTAssertEqual((report["cancellation"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
    }
    func testMissingHelperNeverUsesNativeWriterFallback() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.png"); try Data([1]).write(to: source)
        let service = CodecExportProcessService(configuration: .init(executable: { throw CodecExportProcessError.helperUnavailable }))
        do { _ = try await service.export(sourceURL: source, destinationURL: root.appendingPathComponent("absent.webp"), options: .init(format: .webp)); XCTFail("Must fail closed") }
        catch CodecExportProcessError.helperUnavailable { }
        let state = await service.snapshot()
        XCTAssertFalse(state.active); XCTAssertEqual(state.lastJob?.childLaunched, false)
        XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["input.png"])
    }
    func testSignedPathRejectsSymlinkAndTampering() throws {
        let app = try CodecProcessTestApplication.make(); defer { app.cleanup() }
        let helper = try CodecHelperExecutable.verified(bundleURL: app.bundleURL)
        XCTAssertEqual(helper.lastPathComponent, "PicShotCodecHelper")
        let alias = app.root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app.bundleURL)
        XCTAssertThrowsError(try CodecHelperExecutable.verified(bundleURL: alias))
        let file = try FileHandle(forWritingTo: helper); try file.seekToEnd(); try file.write(contentsOf: Data([0])); try file.close()
        XCTAssertThrowsError(try CodecHelperExecutable.verified(bundleURL: app.bundleURL))
    }
    func testWatchdogTimeoutRSSAndOversizedStdoutConfirmExitBeforeReleasingLease() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png"); try Data([1]).write(to: source)
        for mode in ["timeout", "memory", "stdout"] {
            let script = """
            import sys,time,signal
            sys.stdin.buffer.readline()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            if '\(mode)' == 'stdout':
                sys.stdout.write('x' * 300000); sys.stdout.flush()
            else:
                print('{"version":1,"kind":"progress","fraction":0}',flush=True)
            time.sleep(20)
            """
            let service = try python(script, wall: mode == "timeout" ? 0.3 : 5, rss: mode == "memory" ? 1 : CodecExportLimits.residentBytes)
            do { _ = try await service.export(sourceURL: source, destinationURL: root.appendingPathComponent(mode + ".webp"), options: .init(format: .webp)); XCTFail("Watchdog must stop child") }
            catch { }
            let state = await service.snapshot()
            let metrics = try XCTUnwrap(state.lastJob)
            XCTAssertFalse(state.active); XCTAssertTrue(metrics.childLaunched); XCTAssertTrue(metrics.childExitConfirmed)
            XCTAssertTrue(metrics.temporaryDirectoryRemoved)
            XCTAssertEqual(metrics.outcome, mode == "timeout" ? "timedOut" : mode == "memory" ? "memoryLimit" : "failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(mode + ".webp").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(CodecTemporaryJob.prefix) })
        }
    }
    func testSharedLeaseRejectsCodecWhileGIFChildRunsAndReleasesAfterConfirmedCancel() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"); try Data([1]).write(to: source)
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else { throw CodecProcessTestSupportError.failed("System python3 required for explicitly synthetic protocol test") }
        let gif = GIFExportProcessService(configuration: .init(executable: { pythonURL }, arguments: ["-u", "-c", "import sys,time;sys.stdin.buffer.readline();print('{\"version\":1,\"kind\":\"progress\",\"fraction\":0}',flush=True);time.sleep(20)"], wallSeconds: 5))
        let progress = GIFProcessTestProgress()
        let task = Task { try await gif.export(sourceURL: source, destinationURL: root.appendingPathComponent("not-published.gif")) { progress.record($0) } }
        let deadline = Date().addingTimeInterval(3)
        while progress.values.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(progress.values.isEmpty, "GIF helper never produced its start event")
        let codec = try python("import sys;sys.exit(1)")
        do { _ = try await codec.export(sourceURL: source, destinationURL: root.appendingPathComponent("blocked.webp"), options: .init(format: .webp)); XCTFail("Shared native lease admitted a second child") }
        catch CodecExportProcessError.busy { }
        task.cancel(); _ = try? await task.value
        let state = await gif.snapshot()
        XCTAssertFalse(state.active); XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, true)
        XCTAssertEqual(state.lastJob?.childExitConfirmed, true)
        let token = try XCTUnwrap(NativeExportAdmission.shared.acquire()); NativeExportAdmission.shared.release(token)
    }
    func testStillInputByteAndPixelLimitsRejectBeforeNativeAllocation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let file = try FileHandle(forWritingTo: source); try file.truncate(atOffset: UInt64(CodecExportLimits.stillInputBytes + 1)); try file.close()
        let service = try python("import sys;sys.exit(1)")
        do { _ = try await service.export(sourceURL: source, destinationURL: root.appendingPathComponent("large.avif"), options: .init(format: .avif)); XCTFail("Oversized sparse input was admitted") }
        catch CodecExportProcessError.invalidSource { }
        let state = await service.snapshot(); XCTAssertFalse(state.active); XCTAssertEqual(state.lastJob?.childLaunched, false)
        XCTAssertThrowsError(try CodecExportLimits.validateStillDimensions(width: 4001, height: 4000))
        XCTAssertNoThrow(try CodecExportLimits.validateStillDimensions(width: 4000, height: 4000))
    }
    func testContainerMagicAndPreviewBoundsFailClosed() throws {
        XCTAssertThrowsError(try CodecExportProcessService.validateMagic(Data("RIFF0000WEBP".utf8), format: .webp))
        XCTAssertThrowsError(try CodecExportProcessService.validateMagic(Data("0000ftypavif000000000000".utf8), format: .avif))
        let image = try CodecExportResourceFixture.fixture(width: 128, height: 64)
        let png = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: ImageExportOptions())
        XCTAssertNoThrow(try CodecExportProcessService.validatePreview(png.data, width: 128, height: 64))
        XCTAssertThrowsError(try CodecExportProcessService.validatePreview(png.data, width: 128, height: 128))
        XCTAssertThrowsError(try CodecExportProcessService.validatePreview(png.data, width: 64, height: 32))
        XCTAssertThrowsError(try CodecExportProcessService.validatePreview(Data(repeating: 0, count: CodecExportLimits.previewBytes + 1), width: 128, height: 64))
    }

    private func python(_ script: String, wall: Double = 5, rss: UInt64 = CodecExportLimits.residentBytes) throws -> CodecExportProcessService {
        let url = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CodecProcessTestSupportError.failed("System python3 required for explicitly synthetic protocol test") }
        return CodecExportProcessService(configuration: .init(executable: { url }, arguments: ["-u", "-c", script], wallSeconds: wall, residentLimitBytes: rss))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-Codec-Parent-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return url
    }
}
