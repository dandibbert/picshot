import XCTest
@testable import PicShotCore

final class RecordingRecoveryStoreTests: XCTestCase {
    func testLiveLeaseIsNotDiscoveredAndRestartFindsTheSameIdentity() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root)
        let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage)
        XCTAssertTrue(try store.discover().candidates.isEmpty)
        lease.closeLease()
        let candidate = try XCTUnwrap(store.discover().candidates.first)
        XCTAssertEqual(candidate.journal.id, RecordingRecoveryJournal.id(directoryName: stage.lastPathComponent))
        let next = try store.open(candidate)
        XCTAssertEqual(try next.validatedSourceURL(), stage.appendingPathComponent("recording.mp4"))
        next.closeLease()
    }
    func testExplicitDiscardKeepsMediaAndJournalAndIsNotPromptedAgain() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage); let bytes = try Data(contentsOf: stage.appendingPathComponent("recording.mp4"))
        try lease.discard(); lease.closeLease()
        XCTAssertTrue(try store.discover().candidates.isEmpty)
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("recording.mp4")), bytes)
        let journal = try JSONDecoder().decode(RecordingRecoveryJournal.self, from: Data(contentsOf: stage.appendingPathComponent("recovery.json")))
        XCTAssertEqual(journal.phase, .discarded)
    }
    func testPublicationAndIntentionalPreviewDismissalRetainSavedMovie() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage)
        try lease.markFinalized()
        let output = try lease.publishFinalized(); lease.closeLease()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let candidate = try XCTUnwrap(store.discover().candidates.first)
        XCTAssertTrue(candidate.isPreview); XCTAssertEqual(candidate.sourceURL, output)
        let reopened = try store.open(candidate); try reopened.dismissPreview(); reopened.closeLease()
        XCTAssertTrue(try store.discover().candidates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
    func testChangedSourceInodeOrJournalCannotBeRecoveredOrDiscarded() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage); lease.closeLease()
        let candidate = try XCTUnwrap(store.discover().candidates.first)
        let media = stage.appendingPathComponent("recording.mp4")
        // Keep the old inode allocated so this test cannot pass via inode reuse.
        try FileManager.default.moveItem(at: media, to: stage.appendingPathComponent("original-kept.mp4"))
        try Data([9, 9]).write(to: media)
        XCTAssertThrowsError(try store.open(candidate))
        let scan = try store.discover(); XCTAssertTrue(scan.candidates.isEmpty); XCTAssertEqual(scan.warnings.count, 1)
        XCTAssertEqual(try Data(contentsOf: media), Data([9, 9]))
    }
    func testSymlinkDirectoryMediaJournalAndRootAreRejectedWithoutFollowing() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try directory(); defer { try? FileManager.default.removeItem(at: outside) }
        let outsideFile = outside.appendingPathComponent("sentinel"); try Data([7]).write(to: outsideFile)
        let linkRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: outside)
        XCTAssertThrowsError(try RecordingRecoveryStore(root: linkRoot))
        let store = try RecordingRecoveryStore(root: root)
        let linkedStage = root.appendingPathComponent(".recording-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linkedStage, withDestinationURL: outside)
        XCTAssertThrowsError(try store.begin(stagingDirectory: linkedStage))
        let stage = try staged(root); let media = stage.appendingPathComponent("recording.mp4")
        try FileManager.default.removeItem(at: media)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outsideFile)
        XCTAssertThrowsError(try store.begin(stagingDirectory: stage))
        try FileManager.default.removeItem(at: media); try Data([1]).write(to: media)
        let journal = stage.appendingPathComponent("recovery.json")
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outsideFile)
        XCTAssertThrowsError(try store.begin(stagingDirectory: stage))
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data([7]))
    }
    func testHardlinkedMediaAndOversizeMalformedJournalAreRejected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let media = stage.appendingPathComponent("recording.mp4")
        let link = root.appendingPathComponent("hardlink.mp4"); try FileManager.default.linkItem(at: media, to: link)
        XCTAssertThrowsError(try store.begin(stagingDirectory: stage))
        try FileManager.default.removeItem(at: link)
        let lease = try store.begin(stagingDirectory: stage); lease.closeLease()
        try Data(repeating: 32, count: RecordingRecoveryJournal.maximumJournalBytes + 1).write(to: stage.appendingPathComponent("recovery.json"))
        let scan = try store.discover(); XCTAssertTrue(scan.candidates.isEmpty); XCTAssertEqual(scan.warnings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
    }
    func testCopyFailureAndDestinationCollisionLeaveOriginalUntouched() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage)
        let source = stage.appendingPathComponent("recording.mp4"), before = try Data(contentsOf: source)
        let destination = root.appendingPathComponent("copy.mp4"); try Data([7]).write(to: destination)
        XCTAssertThrowsError(try lease.copyCompletePrefix(to: destination))
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try Data(contentsOf: destination), Data([7]))
    }
    func testExistingJournalCannotBeOverwrittenByBegin() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage); lease.closeLease()
        let url = stage.appendingPathComponent("recovery.json"), original = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.begin(stagingDirectory: stage))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testProtectionSurvivesEveryLinkJournalAndCancellationBoundary() throws {
        for boundary in 0...2 {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
            let source = stage.appendingPathComponent("recording.mp4")
            let protected = stage.appendingPathComponent("recording-preserved.mp4")
            let original = try Data(contentsOf: source)
            let lease = try store.begin(stagingDirectory: stage)
            if boundary == 0 {
                // Crash after link, before journal transition.
                try FileManager.default.linkItem(at: source, to: protected)
            } else { try lease.protectBeforeCancellingWriter() }
            if boundary == 2 {
                // Models the writer deleting only its own original pathname.
                try FileManager.default.removeItem(at: source)
            }
            lease.closeLease()
            let candidate = try XCTUnwrap(store.discover().candidates.first)
            let reopened = try store.open(candidate)
            XCTAssertEqual(try Data(contentsOf: reopened.validatedSourceURL()), original)
            reopened.closeLease()
        }
    }

    func testProtectionIsIdempotentAndUnrelatedExtraLinksAreRefused() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage)
        try lease.protectBeforeCancellingWriter(); try lease.protectBeforeCancellingWriter()
        let protected = try lease.validatedSourceURL()
        let unrelated = root.appendingPathComponent("not-owned.mp4")
        try FileManager.default.linkItem(at: protected, to: unrelated)
        XCTAssertThrowsError(try lease.validatedSourceURL())
        lease.closeLease()
        XCTAssertTrue(try store.discover().candidates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testProtectionFailureDoesNotOverwriteAnExistingProtectedFilename() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage)
        let protected = stage.appendingPathComponent("recording-preserved.mp4")
        try Data([9]).write(to: protected)
        XCTAssertThrowsError(try lease.protectBeforeCancellingWriter())
        XCTAssertEqual(lease.journal?.mediaFilename, "recording.mp4")
        XCTAssertEqual(try Data(contentsOf: protected), Data([9]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("recording.mp4").path))
    }

    func testInPlaceSameSizeEditAfterDiscoveryIsRejected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage); lease.closeLease()
        let candidate = try XCTUnwrap(store.discover().candidates.first)
        let file = try FileHandle(forWritingTo: candidate.sourceURL)
        try file.write(contentsOf: Data([9])); try file.synchronize(); try file.close()
        XCTAssertThrowsError(try store.open(candidate))
    }

    func testWorkspaceCleanupNeverRecursivelyDeletesUnexpectedDirectory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root)
        var work: RecordingRecoveryWorkspace? = try store.makeWorkspace()
        let output = try XCTUnwrap(work).outputURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sentinel = output.appendingPathComponent("unexpected-user-file")
        try Data([7]).write(to: sentinel)
        work = nil
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([7]))
    }

    func testRootPathReplacementCannotRedirectRecoveryWorkspaceOrPublication() throws {
        let root = try directory(); let moved = root.appendingPathExtension("kept")
        let outside = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try RecordingRecoveryStore(root: root)
        let work = try store.makeWorkspace()
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        XCTAssertThrowsError(try store.validateRootPath())
        XCTAssertThrowsError(try work.validatePaths())
        XCTAssertThrowsError(try store.makeWorkspace())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testProtectionRetriesJournalDurabilityAfterRenameAlreadySucceeded() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let faults = RecoveryFaults()
        let store = try RecordingRecoveryStore(root: root, checkpoint: { try faults.visit($0) })
        let stage = try staged(root); let lease = try store.begin(stagingDirectory: stage)
        faults.arm(.journalWillSynchronize)
        XCTAssertThrowsError(try lease.protectBeforeCancellingWriter())
        XCTAssertEqual(lease.journal?.mediaFilename, "recording-preserved.mp4")
        let barriers = faults.count(.journalWillSynchronize)
        try lease.protectBeforeCancellingWriter()
        XCTAssertEqual(faults.count(.journalWillSynchronize), barriers + 1, "Retry must re-establish the exact journal durability barrier")
        let preserved = try lease.validatedSourceURL(); let before = try Data(contentsOf: preserved)
        try FileManager.default.removeItem(at: stage.appendingPathComponent("recording.mp4"))
        lease.closeLease()
        let found = try XCTUnwrap(store.discover().candidates.first)
        XCTAssertEqual(try Data(contentsOf: found.sourceURL), before)
    }

    func testPublicationRetriesRootDurabilityWithoutInventingAnotherDestination() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let faults = RecoveryFaults()
        let store = try RecordingRecoveryStore(root: root, checkpoint: { try faults.visit($0) })
        let stage = try staged(root); let lease = try store.begin(stagingDirectory: stage)
        try lease.markFinalized()
        faults.arm(.rootWillSynchronize)
        XCTAssertThrowsError(try lease.publishFinalized())
        let planned = try XCTUnwrap(lease.journal?.publishedFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(planned).path))
        let barriers = faults.count(.rootWillSynchronize)
        let saved = try lease.publishFinalized()
        XCTAssertEqual(saved.lastPathComponent, planned)
        XCTAssertGreaterThan(faults.count(.rootWillSynchronize), barriers)
        XCTAssertEqual(lease.journal?.phase, .published)
    }

    func testProtectionAndArchiveStillWorkWhenSourceExceededItsExportLimit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingRecoveryStore(root: root); let stage = try staged(root)
        let lease = try store.begin(stagingDirectory: stage, byteLimit: 1)
        try lease.protectBeforeCancellingWriter()
        let protected = try lease.validatedSourceURL()
        XCTAssertThrowsError(try lease.copyCompletePrefix(to: root.appendingPathComponent("too-big.mp4")))
        try lease.discard(); lease.closeLease()
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(try store.discover().candidates.isEmpty)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-RecoveryTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.resolvingSymlinksInPath()
    }
    private func staged(_ root: URL) throws -> URL {
        let stage = root.appendingPathComponent(".recording-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        // Structurally framed, intentionally NOT claimed to be native media.
        let data = Data([0,0,0,8,102,116,121,112, 0,0,0,8,109,111,111,118, 0,0,0,9,109,100,97,116,1])
        try data.write(to: stage.appendingPathComponent("recording.mp4"))
        return stage
    }
}

private final class RecoveryFaults: @unchecked Sendable {
    private let lock = NSLock()
    private var target: RecordingRecoveryCheckpoint?
    private var visits: [RecordingRecoveryCheckpoint] = []
    func arm(_ value: RecordingRecoveryCheckpoint) { lock.lock(); target = value; lock.unlock() }
    func count(_ value: RecordingRecoveryCheckpoint) -> Int { lock.lock(); defer { lock.unlock() }; return visits.filter { $0 == value }.count }
    func visit(_ value: RecordingRecoveryCheckpoint) throws {
        lock.lock(); visits.append(value)
        let fail = target == value
        if fail { target = nil }
        lock.unlock()
        if fail { throw RecordingRecoveryError.io("Injected durability failure") }
    }
}
