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
        let evidence = try CodecGIFReadinessEvidence(root: root)
        var finalSnapshot: GIFExportProcessSnapshot?
        defer { evidence.emit(finalSnapshot: finalSnapshot) }
        let gif = GIFExportProcessService(configuration: .init(executable: {
            evidence.record("executableClosureEntered")
            return pythonURL
        }, arguments: evidence.pythonArguments, wallSeconds: 5,
            launchDiagnosticsForTesting: evidence.launchDiagnostics))
        let progress = GIFProcessTestProgress()
        evidence.record("beforeTaskCreation")
        let task = Task {
            evidence.record("exportTaskEntered")
            defer { evidence.record("exportTaskFinished") }
            do {
                return try await gif.export(sourceURL: source, destinationURL: root.appendingPathComponent("not-published.gif")) {
                    let callbackEntered = ProcessInfo.processInfo.systemUptime
                    progress.record($0)
                    evidence.record("progressStored", fraction: $0, callbackEnteredUptime: callbackEntered)
                }
            } catch {
                evidence.record("exportTaskThrew", errorType: String(reflecting: type(of: error)))
                throw error
            }
        }
        var joined = false
        do {
            let deadline = Date().addingTimeInterval(3)
            evidence.beginWait(deadline: deadline)
            while progress.values.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
                evidence.recordWaitWake()
            }
            // Freeze the original assertion's observation before doing file I/O;
            // a late callback during diagnostics cannot turn a failure into a pass.
            let valuesAtReadinessCheck = progress.values
            evidence.endWait(progressCount: valuesAtReadinessCheck.count)
            XCTAssertFalse(valuesAtReadinessCheck.isEmpty, "GIF helper never produced its start event")
            evidence.captureChildTrace(phase: "afterReadinessAssertion")
            let codec = try python("import sys;sys.exit(1)")
            evidence.record("beforeCodecAdmissionAttempt")
            do { _ = try await codec.export(sourceURL: source, destinationURL: root.appendingPathComponent("blocked.webp"), options: .init(format: .webp)); XCTFail("Shared native lease admitted a second child") }
            catch CodecExportProcessError.busy { evidence.record("codecRejectedBusy") }
            evidence.record("beforeCancellation")
            task.cancel(); _ = try? await task.value
            joined = true
            evidence.record("afterTaskJoin")
            let state = await gif.snapshot()
            finalSnapshot = state
            evidence.captureChildTrace(phase: "afterTaskJoin")
            XCTAssertFalse(state.active); XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, true)
            XCTAssertEqual(state.lastJob?.childExitConfirmed, true)
            let token = try XCTUnwrap(NativeExportAdmission.shared.acquire()); NativeExportAdmission.shared.release(token)
            evidence.record("leaseReacquiredAndReleased")
        } catch {
            // Task.sleep, codec setup/export, or XCTUnwrap can throw. Always join
            // the owned GIF task before the root's existing cleanup removes files.
            evidence.record("testThrew", errorType: String(reflecting: type(of: error)))
            if !joined {
                evidence.record("earlyErrorCancellation")
                task.cancel(); _ = try? await task.value
                evidence.record("afterEarlyErrorTaskJoin")
                finalSnapshot = await gif.snapshot()
                evidence.captureChildTrace(phase: "afterEarlyErrorTaskJoin")
            }
            throw error
        }
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
