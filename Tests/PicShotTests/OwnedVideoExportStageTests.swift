import Darwin
import Foundation
import XCTest
@testable import PicShot

final class OwnedVideoExportStageTests: XCTestCase {
    func testRecordedClipAndGIFCleanupIsSuccessfulAndIdempotent() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        XCTAssertEqual(try info(stage.directoryURL).st_mode & 0o7777, 0o700)

        XCTAssertTrue(stage.cleanupIfOwned())
        XCTAssertFalse(exists(stage.directoryURL))
        XCTAssertFalse(exists(stage.clipURL))
        XCTAssertFalse(exists(stage.gifURL))
        XCTAssertTrue(stage.cleanupIfOwned())
        try assertProtectedFiles(fixture)
    }

    func testUnrecordedRecognizedFilesAreNeverAdoptedByCleanup() throws {
        let fixture = try makeFixture()
        for unrecordedName in ["selected.mp4", "selected.gif"] {
            let stage = try OwnedVideoExportStage.create(beside: fixture.destination)
            try write(clipBytes, to: stage.clipURL)
            try write(gifBytes, to: stage.gifURL)
            if unrecordedName == "selected.mp4" { try stage.recordGIF() }
            else { try stage.recordClip() }

            XCTAssertFalse(stage.cleanupIfOwned(), unrecordedName)
            try assertStageFiles(stage.directoryURL)
        }
        try assertProtectedFiles(fixture)
    }

    func testUnknownEntryRefusesCleanupBeforeDeletingAnyRecordedFile() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let unknown = stage.directoryURL.appendingPathComponent("unknown.txt")
        let unknownBytes = Data("unrecognized artifact".utf8)
        try write(unknownBytes, to: unknown)

        XCTAssertFalse(stage.cleanupIfOwned())
        try assertStageFiles(stage.directoryURL)
        XCTAssertEqual(try Data(contentsOf: unknown), unknownBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: stage.directoryURL.path)),
                       Set(["selected.mp4", "selected.gif", "unknown.txt"]))
        try assertProtectedFiles(fixture)
    }

    func testUnknownSubdirectoryIsNotRecursivelyDeleted() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let unknown = stage.directoryURL.appendingPathComponent("other-job", isDirectory: true)
        try makePrivateDirectory(unknown)
        let sentinel = unknown.appendingPathComponent("selected.gif")
        try write(gifBytes, to: sentinel)

        XCTAssertFalse(stage.cleanupIfOwned())
        try assertStageFiles(stage.directoryURL)
        XCTAssertEqual(try Data(contentsOf: sentinel), gifBytes)
        try assertProtectedFiles(fixture)
    }

    func testCleanupFailureCanBeRetriedAfterUnknownEntryIsRemoved() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let unknown = stage.directoryURL.appendingPathComponent("unknown.txt")
        try write(Data("temporary obstacle".utf8), to: unknown)

        XCTAssertFalse(stage.cleanupIfOwned())
        try assertStageFiles(stage.directoryURL)
        try FileManager.default.removeItem(at: unknown)
        XCTAssertTrue(stage.cleanupIfOwned())
        XCTAssertTrue(stage.cleanupIfOwned())
        XCTAssertFalse(exists(stage.directoryURL))
        try assertProtectedFiles(fixture)
    }

    func testSymlinkArtifactsRefuseRecordingAndCleanupAndPreserveOutsideFiles() throws {
        let fixture = try makeFixture()
        for linkedName in ["selected.mp4", "selected.gif"] {
            let stage = try OwnedVideoExportStage.create(beside: fixture.destination)
            let linkedURL = stage.directoryURL.appendingPathComponent(linkedName)
            let outside = linkedName == "selected.mp4" ? fixture.source : fixture.destination
            try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: outside)
            if linkedName == "selected.mp4" {
                try write(gifBytes, to: stage.gifURL)
                try stage.recordGIF()
                XCTAssertThrowsError(try stage.recordClip())
            } else {
                try write(clipBytes, to: stage.clipURL)
                try stage.recordClip()
                XCTAssertThrowsError(try stage.recordGIF())
            }

            XCTAssertFalse(stage.cleanupIfOwned())
            XCTAssertEqual(try info(linkedURL).st_mode & S_IFMT, S_IFLNK)
            let recordedURL = linkedName == "selected.mp4" ? stage.gifURL : stage.clipURL
            XCTAssertEqual(try Data(contentsOf: recordedURL), linkedName == "selected.mp4" ? gifBytes : clipBytes)
            try assertProtectedFiles(fixture)
        }
    }

    func testHardLinkedArtifactsRefuseRecordingAndCleanupAndPreserveOutsideFiles() throws {
        let fixture = try makeFixture()
        for linkedName in ["selected.mp4", "selected.gif"] {
            let stage = try OwnedVideoExportStage.create(beside: fixture.destination)
            let linkedURL = stage.directoryURL.appendingPathComponent(linkedName)
            let outside = linkedName == "selected.mp4" ? fixture.source : fixture.destination
            try FileManager.default.linkItem(at: outside, to: linkedURL)
            if linkedName == "selected.mp4" {
                try write(gifBytes, to: stage.gifURL)
                try stage.recordGIF()
                XCTAssertThrowsError(try stage.recordClip())
            } else {
                try write(clipBytes, to: stage.clipURL)
                try stage.recordClip()
                XCTAssertThrowsError(try stage.recordGIF())
            }

            XCTAssertEqual(try info(linkedURL).st_nlink, 2)
            XCTAssertEqual(try info(linkedURL).st_ino, try info(outside).st_ino)
            XCTAssertFalse(stage.cleanupIfOwned())
            XCTAssertTrue(exists(linkedURL))
            let recordedURL = linkedName == "selected.mp4" ? stage.gifURL : stage.clipURL
            XCTAssertEqual(try Data(contentsOf: recordedURL), linkedName == "selected.mp4" ? gifBytes : clipBytes)
            try assertProtectedFiles(fixture)
        }
    }

    func testReplacedRecordedFileIdentityRefusesCleanupEvenWithIdenticalBytes() throws {
        let fixture = try makeFixture()
        for replacedName in ["selected.mp4", "selected.gif"] {
            let stage = try makeRecordedStage(in: fixture)
            let replacement = stage.directoryURL.appendingPathComponent(replacedName)
            let original = fixture.root.appendingPathComponent("moved-" + replacedName)
            let bytes = replacedName == "selected.mp4" ? clipBytes : gifBytes
            // Keep the old inode alive so replacement cannot reuse its identity.
            try FileManager.default.moveItem(at: replacement, to: original)
            try write(bytes, to: replacement)
            XCTAssertNotEqual(try info(original).st_ino, try info(replacement).st_ino)

            if replacedName == "selected.mp4" {
                XCTAssertThrowsError(try stage.recordClip())
                XCTAssertThrowsError(try stage.validateGIFPaths(sourceURL: stage.clipURL, destinationURL: stage.gifURL))
            } else {
                XCTAssertThrowsError(try stage.recordGIF())
            }
            XCTAssertFalse(stage.cleanupIfOwned())
            try assertStageFiles(stage.directoryURL)
            XCTAssertEqual(try Data(contentsOf: original), bytes)
        }
        try assertProtectedFiles(fixture)
    }

    func testSubstitutedStageDirectoryIdentityRefusesCleanup() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let moved = fixture.root.appendingPathComponent("moved-stage", isDirectory: true)
        try FileManager.default.moveItem(at: stage.directoryURL, to: moved)
        try makePrivateDirectory(stage.directoryURL)
        try write(clipBytes, to: stage.clipURL)
        try write(gifBytes, to: stage.gifURL)
        XCTAssertNotEqual(try info(moved).st_ino, try info(stage.directoryURL).st_ino)

        XCTAssertThrowsError(try stage.validateGIFPaths(sourceURL: stage.clipURL, destinationURL: stage.gifURL))
        XCTAssertFalse(stage.cleanupIfOwned())
        try assertStageFiles(moved)
        try assertStageFiles(stage.directoryURL)
        try assertProtectedFiles(fixture)
    }

    func testSubstitutedParentDirectoryIdentityRefusesCleanup() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let movedParent = fixture.root.appendingPathComponent("moved-exports", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.parent, to: movedParent)
        try makePrivateDirectory(fixture.parent)
        try makePrivateDirectory(stage.directoryURL)
        try write(clipBytes, to: stage.clipURL)
        try write(gifBytes, to: stage.gifURL)
        let replacementDestination = Data("replacement destination stays intact".utf8)
        try write(replacementDestination, to: fixture.destination)
        XCTAssertNotEqual(try info(movedParent).st_ino, try info(fixture.parent).st_ino)

        XCTAssertThrowsError(try stage.validateGIFPaths(sourceURL: stage.clipURL, destinationURL: stage.gifURL))
        XCTAssertFalse(stage.cleanupIfOwned())
        try assertStageFiles(stage.directoryURL)
        try assertStageFiles(movedParent.appendingPathComponent(stage.directoryURL.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
        XCTAssertEqual(try Data(contentsOf: movedParent.appendingPathComponent(fixture.destination.lastPathComponent)),
                       fixture.destinationBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), replacementDestination)
    }

    func testGIFJobIsAnIndependentSiblingOnTheSameDevice() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let job = try stage.makeSiblingGIFJob(sourceURL: stage.clipURL, destinationURL: stage.gifURL)
        XCTAssertEqual(job.url.deletingLastPathComponent(), stage.directoryURL.deletingLastPathComponent())
        XCTAssertNotEqual(job.url, stage.directoryURL)
        XCTAssertEqual(job.device, try info(stage.directoryURL).st_dev)
        XCTAssertEqual(try info(job.url).st_dev, try info(stage.directoryURL).st_dev)
        XCTAssertEqual(try info(job.url).st_mode & 0o7777, 0o700)
        let jobSource = job.url.appendingPathComponent("source.mp4")
        let jobResult = job.url.appendingPathComponent("result.gif")
        try write(clipBytes, to: jobSource)
        try job.recordSource()
        try write(gifBytes, to: jobResult)

        XCTAssertTrue(stage.cleanupIfOwned())
        XCTAssertEqual(try Data(contentsOf: jobSource), clipBytes)
        XCTAssertEqual(try Data(contentsOf: jobResult), gifBytes)
        XCTAssertTrue(job.cleanup())
        XCTAssertTrue(job.cleanup())
        XCTAssertFalse(exists(job.url))
        try assertProtectedFiles(fixture)
    }

    func testGIFCapabilityRequiresItsOwnExactPathsAndRecordedClip() throws {
        let fixture = try makeFixture()
        let stage = try OwnedVideoExportStage.create(beside: fixture.destination)
        try write(clipBytes, to: stage.clipURL)
        XCTAssertThrowsError(try stage.validateGIFPaths(sourceURL: stage.clipURL, destinationURL: stage.gifURL))
        XCTAssertThrowsError(try stage.makeSiblingGIFJob(sourceURL: stage.clipURL, destinationURL: stage.gifURL))
        try stage.recordClip()
        XCTAssertNoThrow(try stage.validateGIFPaths(sourceURL: stage.clipURL, destinationURL: stage.gifURL))

        let other = try makeRecordedStage(in: fixture)
        let entriesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path))
        for (source, destination) in [
            (fixture.source, stage.gifURL), (stage.clipURL, fixture.destination),
            (other.clipURL, stage.gifURL), (stage.clipURL, other.gifURL),
            (stage.gifURL, stage.clipURL)
        ] {
            XCTAssertThrowsError(try stage.validateGIFPaths(sourceURL: source, destinationURL: destination))
            XCTAssertThrowsError(try stage.makeSiblingGIFJob(sourceURL: source, destinationURL: destination))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path)), entriesBefore)
        XCTAssertTrue(stage.cleanupIfOwned())
        XCTAssertTrue(other.cleanupIfOwned())
        try assertProtectedFiles(fixture)
    }

    func testJobCleanupRecognizesOriginalDirectoryAlreadyRemovedByHelper() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let job = try stage.makeSiblingGIFJob(sourceURL: stage.clipURL, destinationURL: stage.gifURL)
        try write(clipBytes, to: job.url.appendingPathComponent("source.mp4"))
        try job.recordSource()
        try FileManager.default.removeItem(at: job.url) // Simulate helper-owned EOF cleanup.

        XCTAssertTrue(job.cleanup())
        XCTAssertTrue(job.cleanup())
        XCTAssertTrue(stage.cleanupIfOwned())
        try assertProtectedFiles(fixture)
    }

    func testMissingJobPathDoesNotMeanRenamedOriginalDirectoryWasCleaned() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let job = try stage.makeSiblingGIFJob(sourceURL: stage.clipURL, destinationURL: stage.gifURL)
        try write(clipBytes, to: job.url.appendingPathComponent("source.mp4"))
        try job.recordSource()
        let moved = fixture.parent.appendingPathComponent("moved-job", isDirectory: true)
        try FileManager.default.moveItem(at: job.url, to: moved)

        XCTAssertFalse(job.cleanup())
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("source.mp4")), clipBytes)
        XCTAssertTrue(stage.cleanupIfOwned())
        try assertProtectedFiles(fixture)
    }

    func testSimulatedRelaunchCreatesDistinctStageAndCannotAdoptExistingStage() throws {
        let fixture = try makeFixture()
        // Release the old capability while its files remain, as after process loss.
        let abandonedURL: URL = try {
            let oldOwner = try makeRecordedStage(in: fixture)
            return oldOwner.directoryURL
        }()
        let fresh = try makeRecordedStage(in: fixture)
        XCTAssertNotEqual(fresh.directoryURL, abandonedURL)
        XCTAssertNotEqual(try info(fresh.directoryURL).st_ino, try info(abandonedURL).st_ino)
        let abandonedClip = abandonedURL.appendingPathComponent("selected.mp4")
        let abandonedGIF = abandonedURL.appendingPathComponent("selected.gif")

        XCTAssertThrowsError(try fresh.validateGIFPaths(sourceURL: abandonedClip, destinationURL: abandonedGIF))
        XCTAssertThrowsError(try fresh.makeSiblingGIFJob(sourceURL: abandonedClip, destinationURL: abandonedGIF))
        XCTAssertTrue(fresh.cleanupIfOwned())
        XCTAssertFalse(exists(fresh.directoryURL))
        try assertStageFiles(abandonedURL)
        try assertProtectedFiles(fixture)
    }

    func testPublishedHardLinkRequiresExplicitFinishBeforeOrdinaryCleanup() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let published = fixture.parent.appendingPathComponent("published.gif")
        try FileManager.default.linkItem(at: stage.gifURL, to: published)
        XCTAssertEqual(try info(stage.gifURL).st_nlink, 2)

        XCTAssertFalse(stage.cleanupIfOwned())
        try assertStageFiles(stage.directoryURL)
        XCTAssertNoThrow(try stage.finishGIFPublication(at: published))
        XCTAssertFalse(exists(stage.gifURL))
        XCTAssertEqual(try Data(contentsOf: stage.clipURL), clipBytes)
        XCTAssertEqual(try info(published).st_nlink, 1)
        XCTAssertEqual(try Data(contentsOf: published), gifBytes)
        XCTAssertTrue(stage.cleanupIfOwned())
        XCTAssertFalse(exists(stage.directoryURL))
        XCTAssertEqual(try Data(contentsOf: published), gifBytes)
        try assertProtectedFiles(fixture)
    }

    func testPublicationFinishRefusesDifferentDestinationIdentity() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let published = fixture.parent.appendingPathComponent("published.gif")
        let different = fixture.parent.appendingPathComponent("different.gif")
        try FileManager.default.linkItem(at: stage.gifURL, to: published)
        try write(gifBytes, to: different)
        XCTAssertNotEqual(try info(published).st_ino, try info(different).st_ino)

        XCTAssertThrowsError(try stage.finishGIFPublication(at: different))
        XCTAssertFalse(stage.cleanupIfOwned())
        try assertStageFiles(stage.directoryURL)
        XCTAssertEqual(try Data(contentsOf: published), gifBytes)
        XCTAssertEqual(try Data(contentsOf: different), gifBytes)
        try assertProtectedFiles(fixture)
    }

    func testPublicationFinishRefusesAnExtraThirdHardLink() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let published = fixture.parent.appendingPathComponent("published.gif")
        let thirdLink = fixture.root.appendingPathComponent("third-link.gif")
        try FileManager.default.linkItem(at: stage.gifURL, to: published)
        try FileManager.default.linkItem(at: stage.gifURL, to: thirdLink)
        XCTAssertEqual(try info(stage.gifURL).st_nlink, 3)

        XCTAssertThrowsError(try stage.finishGIFPublication(at: published))
        XCTAssertFalse(stage.cleanupIfOwned())
        try assertStageFiles(stage.directoryURL)
        XCTAssertEqual(try Data(contentsOf: published), gifBytes)
        XCTAssertEqual(try Data(contentsOf: thirdLink), gifBytes)
        try assertProtectedFiles(fixture)
    }

    func testPublicationFinishAcceptsRenameWithNoRemainingStageGIF() throws {
        let fixture = try makeFixture()
        let stage = try makeRecordedStage(in: fixture)
        let published = fixture.parent.appendingPathComponent("published.gif")
        try FileManager.default.moveItem(at: stage.gifURL, to: published)

        XCTAssertNoThrow(try stage.finishGIFPublication(at: published))
        XCTAssertFalse(exists(stage.gifURL))
        XCTAssertTrue(stage.cleanupIfOwned())
        XCTAssertFalse(exists(stage.directoryURL))
        XCTAssertEqual(try Data(contentsOf: published), gifBytes)
        try assertProtectedFiles(fixture)
    }

    // These are filesystem ownership fixtures; no media decoder runs in this suite.
    private let clipBytes = Data("selected MP4 fixture bytes".utf8)
    private let gifBytes = Data("GIF89a selected GIF fixture bytes".utf8)

    private struct Fixture {
        let root: URL
        let parent: URL
        let source: URL
        let destination: URL
        let sourceBytes = Data("external original recording".utf8)
        let destinationBytes = Data("external existing destination".utf8)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShotOwnedVideoExportStageTests-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("exports", isDirectory: true)
        try makePrivateDirectory(parent)
        let fixture = Fixture(root: root, parent: parent, source: root.appendingPathComponent("original.mp4"),
                              destination: parent.appendingPathComponent("destination.gif"))
        try write(fixture.sourceBytes, to: fixture.source)
        try write(fixture.destinationBytes, to: fixture.destination)
        return fixture
    }

    private func makeRecordedStage(in fixture: Fixture) throws -> OwnedVideoExportStage {
        let stage = try OwnedVideoExportStage.create(beside: fixture.destination)
        try write(clipBytes, to: stage.clipURL)
        try stage.recordClip()
        try write(gifBytes, to: stage.gifURL)
        try stage.recordGIF()
        return stage
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
    }

    private func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    private func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return value
    }

    private func exists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }

    private func assertStageFiles(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("selected.mp4")), clipBytes, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("selected.gif")), gifBytes, file: file, line: line)
    }

    private func assertProtectedFiles(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.destinationBytes, file: file, line: line)
    }
}
