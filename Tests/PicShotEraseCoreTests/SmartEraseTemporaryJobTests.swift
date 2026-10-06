import XCTest
import Darwin
@testable import PicShotEraseCore

final class SmartEraseTemporaryJobTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("smart-erase-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    func testPrivateJobOwnershipAndCleanup() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try SmartEraseTemporaryJob.create(in: root)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: job.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try SmartEraseTemporaryJob.claim(job, parent: Int32.max))
        SmartEraseTemporaryJob.remove(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.path))
    }
    func testStaleSweepKeepsLiveJobsAndUnmarkedDirectories() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let live = try SmartEraseTemporaryJob.create(in: root)
        let unmarked = root.appendingPathComponent("picshot-erase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        SmartEraseTemporaryJob.sweep(in: root, now: Date().addingTimeInterval(7_200))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarked.path))
        SmartEraseTemporaryJob.remove(unmarked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarked.path))
    }
    func testStaleDeadJobIsRemovedAndSymlinkNeverFollowed() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dead = try SmartEraseTemporaryJob.create(in: root)
        let marker = Data(#"{"format":"PicShotEraseJob-v1","parent":2147483647,"helper":0}"#.utf8)
        try marker.write(to: dead.appendingPathComponent(".picshot-erase-job.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: dead.path)
        SmartEraseTemporaryJob.sweep(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        let protected = try SmartEraseTemporaryJob.create(in: root)
        let link = root.appendingPathComponent("picshot-erase-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protected)
        SmartEraseTemporaryJob.remove(link)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }
    func testParentOwnedCleanupSurvivesMissingMarker() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let job = try SmartEraseTemporaryJob.create(in: root)
        try Data([1, 2, 3]).write(to: job.appendingPathComponent("input.png"))
        try FileManager.default.removeItem(at: job.appendingPathComponent(".picshot-erase-job.json"))
        SmartEraseTemporaryJob.removeOwned(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.path))
    }

}
