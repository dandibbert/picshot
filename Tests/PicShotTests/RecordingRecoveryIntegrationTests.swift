import XCTest
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import PicShotCore
@testable import PicShot

/// Native encoders with injected disk-protection faults, never capture streams,
/// camera devices, microphone access, or Screen Recording permission requests.
final class RecordingRecoveryIntegrationTests: XCTestCase {
    func testFailedDiscardDoesNotCancelDeleteArchiveOrCacheAnIrrecoverableFailure() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ProtectionGate()
        let writer = try makeWriter(in: root, gate: gate)
        let stage = try stagingDirectory(in: root)
        let source = stage.appendingPathComponent("recording.mp4")
        try await appendScreen(to: writer)
        do { try await writer.discard(); XCTFail("Injected protection failure must propagate") }
        catch RecordingError.preservationFailed { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Cancellation would delete this name")
        XCTAssertEqual(try journal(in: stage).phase, .capturing)
        XCTAssertEqual(try journal(in: stage).mediaFilename, "recording.mp4")
        let frozen = await writer.snapshot()
        XCTAssertEqual(frozen.retainedVideoFrames, 0)
        do { _ = try await writer.setPaused(false); XCTFail("Capture must stay frozen while recovery is blocked") }
        catch RecordingError.notRecording { }
        XCTAssertTrue(try RecordingRecoveryStore(root: root).discover().candidates.isEmpty,
                      "The retained encoder still owns its recovery lease")

        gate.allow()
        try await writer.discard()
        try await writer.discard()
        XCTAssertEqual(gate.attempts, 2, "Repeated successful discard must be idempotent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let archived = try journal(in: stage)
        XCTAssertEqual(archived.phase, .discarded)
        XCTAssertEqual(archived.mediaFilename, "recording-preserved.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent(archived.mediaFilename).path))
        XCTAssertTrue(try RecordingRecoveryStore(root: root).discover().candidates.isEmpty)
        do { _ = try await writer.publishFinished(); XCTFail("Late publication cannot resurrect a discarded take") }
        catch RecordingError.notRecording { }
    }

    func testNoFrameProtectionFailureCanBeRetriedInsteadOfReplayingCachedFailure() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ProtectionGate()
        let writer = try makeWriter(in: root, gate: gate)
        let stage = try stagingDirectory(in: root)
        do { _ = try await writer.finish(); XCTFail("Unprotected empty take must stay owned") }
        catch RecordingError.preservationFailed { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("recording.mp4").path))
        gate.allow()
        do { _ = try await writer.finish(); XCTFail("No frames is still not a successful recording") }
        catch RecordingError.noFrames { }
        XCTAssertEqual(gate.attempts, 2)
        try await writer.discard()
        XCTAssertEqual(try journal(in: stage).phase, .discarded)
        XCTAssertTrue(try RecordingRecoveryStore(root: root).discover().candidates.isEmpty)
    }

    @MainActor
    func testServiceRetainsExactlyOnePendingTakeAndBlocksStartRestartAndQuitUntilRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ProtectionGate()
        let service = serviceWithoutCaptureAccess()
        var writer: RecordingWriter? = try makeWriter(in: root, gate: gate)
        weak var retained = writer
        try await appendScreen(to: XCTUnwrap(writer))
        do { try await service.preserveStoppedTake(XCTUnwrap(writer)); XCTFail("Protection is injected to fail") }
        catch RecordingError.preservationFailed { }
        writer = nil
        XCTAssertNotNil(retained, "The service must own the unresolved encoder, not a temporary stack frame")
        XCTAssertTrue(service.hasPendingTake)
        XCTAssertNotNil(service.error)
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isStopping)
        XCTAssertFalse(service.camera.requested)
        XCTAssertEqual(service.controlState.terminationAction, .preserve)
        XCTAssertTrue(service.controlState.blocksClosing)
        XCTAssertFalse(service.controlState.canStart)
        XCTAssertFalse(service.controlState.canPauseOrStop)
        do { try await service.start(displayID: 0); XCTFail("Pending preservation must block a new take") }
        catch RecordingError.pendingTake { }
        do { _ = try await service.restart(discardUnfinished: true); XCTFail("Restart may not bypass pending preservation") }
        catch RecordingError.pendingTake { }
        await service.cancel()
        XCTAssertTrue(service.hasPendingTake)
        XCTAssertNotNil(retained)
        XCTAssertTrue(try RecordingRecoveryStore(root: root).discover().candidates.isEmpty)
        do {
            try await RecordingTerminationCoordinator.finish(snapshot: { service.controlState },
                cancelCountdown: { XCTFail("An unresolved encoder is not a countdown") },
                save: { XCTFail("An unresolved encoder must use preservation") },
                preserve: { try await service.retryPendingTakePreservation(presentRecovery: false) })
            XCTFail("A failed protection must deny Quit")
        } catch RecordingError.preservationFailed { }
        XCTAssertTrue(service.hasPendingTake)
        XCTAssertNotNil(retained)

        var presentations = 0
        service.onPendingTakePreserved = { presentations += 1 }
        gate.allow()
        let first = Task { try await service.retryPendingTakePreservation() }
        let second = Task { try await service.retryPendingTakePreservation() }
        try await first.value
        try await second.value
        XCTAssertFalse(service.hasPendingTake)
        XCTAssertNil(service.error)
        XCTAssertNil(service.outputURL, "A recoverable fragment is not automatically a playable saved movie")
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(gate.attempts, 3, "Two retry clicks must share one preservation")
        let scan = try RecordingRecoveryStore(root: root).discover()
        XCTAssertEqual(scan.candidates.count, 1)
        XCTAssertEqual(scan.candidates.first?.sourceURL.lastPathComponent, "recording-preserved.mp4")
        XCTAssertEqual(scan.candidates.first?.journal.phase, .capturing, "Failure must not archive the reminder as user discard")
        XCTAssertTrue(scan.warnings.isEmpty)
        try await waitUntil { retained == nil }
        XCTAssertTrue(service.controlState.canStart)
        XCTAssertEqual(service.controlState.terminationAction, .none)
    }

    @MainActor
    func testTerminationCannotApproveQuitWhenCancelledPreservationStillOwnsTake() async {
        do {
            try await RecordingTerminationCoordinator.finish(
                snapshot: { RecordingControlState(hasPendingTake: true) },
                cancelCountdown: { XCTFail("Must not discard") },
                save: { XCTFail("Must not save an absent stream") },
                preserve: { throw CancellationError() })
            XCTFail("Cancellation does not authorize dropping the pending encoder")
        } catch RecordingError.pendingTake { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testTerminationRetriesProtectionAndWaitsForVisiblePendingStateToClear() async throws {
        var state = RecordingControlState(hasPendingTake: true)
        var attempts = 0
        try await RecordingTerminationCoordinator.finish(snapshot: { state },
            cancelCountdown: { XCTFail("Must not discard") },
            save: { XCTFail("Must preserve the stopped take") },
            preserve: { attempts += 1; state.hasPendingTake = false })
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(state.terminationAction, .none)
    }

    func testLegacyPublicationRefusesJournalOwnedMovieAndWriterPublicationPreservesIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ProtectionGate()
        gate.allow()
        let writer = try makeWriter(in: root, gate: gate)
        try await appendScreen(to: writer)
        let source = try await writer.finish()
        XCTAssertThrowsError(try RecordingFileStorage.publish(from: source, in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let saved = try await writer.publishFinished(mediaURL: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        try await writer.discard()
        try await writer.abandonPreservingRecovery()
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertEqual(gate.attempts, 0, "A completed and published encoder does not need cancellation")
        do { _ = try await writer.publishFinished(); XCTFail("A later save must not create or overwrite a second file") }
        catch RecordingError.notRecording { }
    }

    private func makeWriter(in root: URL, gate: ProtectionGate) throws -> RecordingWriter {
        try RecordingWriter(size: CGSize(width: 40, height: 24), options: .init(), outputDirectory: root,
            protectBeforeCancellation: { try gate.protect($0) }, requestStop: { _ in })
    }

    @MainActor
    private func serviceWithoutCaptureAccess() -> RecordingService {
        RecordingService(screenPermissionCheck: {
            XCTFail("Recovery integration tests must never request capture permissions")
            throw RecordingError.failed("Live capture is forbidden in recovery integration tests.")
        })
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicShot-RecoveryIntegration-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func stagingDirectory(in root: URL) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".recording-") })
    }

    private func journal(in stage: URL) throws -> RecordingRecoveryJournal {
        try JSONDecoder().decode(RecordingRecoveryJournal.self,
            from: Data(contentsOf: stage.appendingPathComponent(RecordingRecoveryJournal.filename)))
    }

    private func appendScreen(to writer: RecordingWriter) async throws {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 40, 24, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), 0x7F, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        let frame = try XCTUnwrap(sample)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: true))
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        attachment[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !writer.queue.sync(execute: { writer.consume(frame, of: .screen) }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RecordingError.noFrames }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RecordingError.failed("Pending writer was not released.") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class ProtectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = true
    private var count = 0
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
    func allow() { lock.lock(); blocked = false; lock.unlock() }
    func protect(_ lease: RecordingRecoveryLease) throws {
        lock.lock()
        count += 1
        let shouldFail = blocked
        lock.unlock()
        if shouldFail { throw RecordingRecoveryError.io("Injected full-disk preservation failure") }
        try lease.protectBeforeCancellingWriter()
    }
}
