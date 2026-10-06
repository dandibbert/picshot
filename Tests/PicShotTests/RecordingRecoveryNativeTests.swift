import XCTest
import AVFoundation
import PicShotCore
@testable import PicShot

final class RecordingRecoveryNativeTests: XCTestCase {
    func testActualWriterCancellationKeepsProtectedInodeAndRecoversDecodedAudioVideo() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await RecordingRecoverySyntheticMovie.make(in: root)
        try await waitForFragments(movie.url)
        try movie.lease.protectBeforeCancellingWriter()
        let protected = try movie.lease.validatedSourceURL()
        XCTAssertEqual(protected.lastPathComponent, "recording-preserved.mp4")
        movie.writer.cancelWriting() // Real API that deletes its original output URL.
        XCTAssertEqual(movie.writer.status, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        movie.lease.closeLease()
        let original = try Data(contentsOf: protected)
        let store = try RecordingRecoveryStore(root: root)
        let candidate = try XCTUnwrap(store.discover().candidates.first)
        let result = try await RecordingRecoveryEngine.recover(candidate, store: store)
        let decoded = try await RecordingRecoveryFixture.decodeAllSyntheticMedia(result.url)
        XCTAssertGreaterThanOrEqual(decoded.video, 20)
        XCTAssertGreaterThanOrEqual(decoded.audio, 48_000)
        XCTAssertGreaterThanOrEqual(result.recoveredDuration, 2)
        XCTAssertLessThanOrEqual(result.recoveredDuration, 6.2)
        XCTAssertEqual(try Data(contentsOf: protected), original)
        XCTAssertTrue(try store.discover().candidates.isEmpty)
        XCTAssertNotEqual(result.url, protected)
    }

    func testTornFinalFragmentExportsOnlyCompleteNativeMediaAndKeepsEveryOriginalByte() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await interruptedSource(in: root)
        // Append a complete moof header and a deliberately torn mdat. Recovery
        // must omit this tail rather than passing it into native remux/decode.
        let file = try FileHandle(forWritingTo: source)
        try file.seekToEnd()
        try file.write(contentsOf: Data([0,0,0,9,109,111,111,102,0, 0,1,0,0,109,100,97,116,1,2,3]))
        try file.synchronize(); try file.close()
        let original = try Data(contentsOf: source)
        let store = try RecordingRecoveryStore(root: root)
        let candidate = try XCTUnwrap(store.discover().candidates.first)
        let result = try await RecordingRecoveryEngine.recover(candidate, store: store)
        XCTAssertGreaterThan(result.ignoredTailBytes, 0)
        let decoded = try await RecordingRecoveryFixture.decodeAllSyntheticMedia(result.url)
        XCTAssertGreaterThan(decoded.video, 0); XCTAssertGreaterThan(decoded.audio, 0)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCancellationNeverRemovesTheSourceOrDismissesItsJournal() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await interruptedSource(in: root)
        let original = try Data(contentsOf: source)
        let store = try RecordingRecoveryStore(root: root)
        let candidate = try XCTUnwrap(store.discover().candidates.first)
        let task = Task { try await RecordingRecoveryEngine.recover(candidate, store: store) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled recovery must not publish") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try store.discover().candidates.count, 1)
    }

    func testInvalidMediaFailureKeepsJournalAndUnrelatedSavedFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = try RecordingFileStorage.makeStagingDirectory(in: root)
        let source = stage.appendingPathComponent("recording.mp4")
        let original = Data([1,2,3,4]); try original.write(to: source)
        let unrelated = root.appendingPathComponent("PicShot-existing.mp4"); try Data([9]).write(to: unrelated)
        let store = try RecordingRecoveryStore(root: root)
        let lease = try store.begin(stagingDirectory: stage); lease.closeLease()
        let candidate = try XCTUnwrap(store.discover().candidates.first)
        do { _ = try await RecordingRecoveryEngine.recover(candidate, store: store); XCTFail("Invalid media must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([9]))
        XCTAssertEqual(try store.discover().candidates.count, 1)
    }

    @MainActor func testRecoveryWindowCloseAndRepeatedDiscardRemainExplicitAndNonDestructive() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = try RecordingFileStorage.makeStagingDirectory(in: root)
        let source = stage.appendingPathComponent("recording.mp4"); try Data([1]).write(to: source)
        let store = try RecordingRecoveryStore(root: root)
        let lease = try store.begin(stagingDirectory: stage); lease.closeLease()
        let scan = try store.discover()
        let candidate = try XCTUnwrap(scan.candidates.first)
        let model = RecordingRecoveryModel(store: store, scan: scan)
        XCTAssertFalse(model.isBusy)
        model.close() // Keep for later: does not dismiss, recover, or start devices.
        model.recover(candidate)
        XCTAssertFalse(model.isBusy); XCTAssertEqual(try store.discover().candidates.count, 1)
        let later = RecordingRecoveryModel(store: store, scan: try store.discover())
        later.discardConfirmed(candidate); later.discardConfirmed(candidate)
        XCTAssertTrue(try store.discover().candidates.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
    }

    @MainActor func testExistingRecoveryModelRefreshesAfterAnotherTakeIsProtected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root)
        let model = RecordingRecoveryModel(store: store, scan: try store.discover())
        XCTAssertTrue(model.candidates.isEmpty)
        let stage = try RecordingFileStorage.makeStagingDirectory(in: root)
        try Data([1]).write(to: stage.appendingPathComponent("recording.mp4"))
        let lease = try store.begin(stagingDirectory: stage)
        try lease.protectBeforeCancellingWriter(); lease.closeLease()
        model.refresh()
        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertFalse(model.isBusy)
        model.close()
    }

    private func interruptedSource(in root: URL) async throws -> URL {
        let movie = try await RecordingRecoverySyntheticMovie.make(in: root)
        try await waitForFragments(movie.url)
        try movie.lease.protectBeforeCancellingWriter()
        movie.writer.cancelWriting()
        let url = try movie.lease.validatedSourceURL(); movie.lease.closeLease()
        return url
    }
    private func waitForFragments(_ url: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let prefix = try? RecordingRecoverySyntheticMovie.prefix(at: url), prefix.completeFragments >= 3 {
                try await Task.sleep(nanoseconds: 100_000_000); return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RecordingRecoveryError.noRecoverableMedia
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-RecoveryNative-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
