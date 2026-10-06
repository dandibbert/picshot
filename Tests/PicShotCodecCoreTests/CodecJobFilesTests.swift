import XCTest
import Foundation
import Darwin
@testable import PicShotCodecCore

final class CodecJobFilesTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("codec-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func stage(_ directory: URL, contents: Data = Data([1, 2, 3])) throws {
        let path = directory.appendingPathComponent("input.png").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: contents, attributes: [.posixPermissions: 0o600]))
    }
    func testExclusiveDeterministicOutputsAndCleanup() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try CodecTemporaryJob.create(in: root); try stage(directory)
        let files = try CodecJobFiles.validate(directory: directory, request: .init(format: .webp))
        XCTAssertEqual(files.sourceURL.lastPathComponent, "input.png")
        let source = try files.openSource(); Darwin.close(source)
        let output = try files.createOutput()
        XCTAssertEqual(Darwin.write(output, [UInt8](repeating: 8, count: 12), 12), 12); Darwin.close(output)
        XCTAssertEqual(try files.validateOutput(), 12)
        XCTAssertThrowsError(try files.createOutput())
        XCTAssertThrowsError(try CodecJobFiles.validate(directory: directory, request: .init(format: .webp)))
        CodecTemporaryJob.removeOwned(directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testSourceSymlinkHardlinkPermissionAndIdentitySubstitutionRejected() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try CodecTemporaryJob.create(in: root)
        let outside = root.appendingPathComponent("outside")
        XCTAssertTrue(FileManager.default.createFile(atPath: outside.path, contents: Data([1]), attributes: [.posixPermissions: 0o600]))
        let source = directory.appendingPathComponent("input.png")
        XCTAssertEqual(symlink(outside.path, source.path), 0)
        XCTAssertThrowsError(try CodecJobFiles.validate(directory: directory, request: .init(format: .webp)))
        XCTAssertEqual(unlink(source.path), 0)
        XCTAssertEqual(link(outside.path, source.path), 0)
        XCTAssertThrowsError(try CodecJobFiles.validate(directory: directory, request: .init(format: .webp)))
        XCTAssertEqual(unlink(source.path), 0)
        try stage(directory)
        XCTAssertEqual(chmod(source.path, 0o644), 0)
        XCTAssertThrowsError(try CodecJobFiles.validate(directory: directory, request: .init(format: .webp)))
        XCTAssertEqual(chmod(source.path, 0o600), 0)
        let files = try CodecJobFiles.validate(directory: directory, request: .init(format: .webp))
        try Data([9, 9, 9, 9]).write(to: source)
        XCTAssertThrowsError(try files.openSource())
        try FileManager.default.removeItem(at: source); try stage(directory)
        XCTAssertThrowsError(try files.validateSourceIdentity())
    }
    func testUnknownFilesAndLinksPreventCleanup() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try CodecTemporaryJob.create(in: root); try stage(directory)
        let unknown = directory.appendingPathComponent("do-not-delete.txt")
        try Data([7]).write(to: unknown)
        CodecTemporaryJob.removeOwned(directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.png").path))
        try FileManager.default.removeItem(at: unknown)
        let outside = root.appendingPathComponent("outside"); try Data([7]).write(to: outside)
        XCTAssertEqual(symlink(outside.path, directory.appendingPathComponent("output.webp").path), 0)
        CodecTemporaryJob.removeOwned(directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
    func testDirectorySymlinkAndReplacedDirectoryRejected() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try CodecTemporaryJob.create(in: root); try stage(directory)
        let files = try CodecJobFiles.validate(directory: directory, request: .init(format: .avif))
        let alias = root.appendingPathComponent("picshot-codec-\(UUID().uuidString)")
        XCTAssertEqual(symlink(directory.path, alias.path), 0)
        XCTAssertThrowsError(try CodecJobFiles.validate(directory: alias, request: .init(format: .webp)))
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try stage(directory)
        XCTAssertThrowsError(try files.openSource())
        XCTAssertThrowsError(try files.createOutput())
    }
}
