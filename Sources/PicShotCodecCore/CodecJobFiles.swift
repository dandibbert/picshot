import Foundation
import Darwin

/// File capabilities are restricted to deterministic names under one private,
/// owned directory. Reopened descriptors must retain the admitted identities.
public struct CodecJobFiles: Sendable {
    public let directoryURL: URL
    public let sourceURL: URL
    public let outputURL: URL
    public let previewURL: URL
    public let request: CodecExportRequest
    private let directoryIdentity: CodecFileIdentity
    private let sourceIdentity: CodecFileIdentity

    public static func validate(directory: URL, request: CodecExportRequest) throws -> Self {
        try request.validate()
        let identity = try CodecTemporaryJob.validateDirectory(directory)
        let source = directory.appendingPathComponent(request.inputName)
        var information = stat()
        guard lstat(source.path, &information) == 0, CodecFileIdentity.isPrivateRegular(information),
              information.st_size > 0, information.st_size <= request.inputByteLimit
        else { throw CodecExportFailure(.invalidSource) }
        for name in [request.outputName, "preview.png"] {
            guard lstat(directory.appendingPathComponent(name).path, &information) != 0, errno == ENOENT
            else { throw CodecExportFailure(.invalidOutput) }
        }
        guard lstat(source.path, &information) == 0, CodecFileIdentity.isPrivateRegular(information),
              information.st_size > 0, information.st_size <= request.inputByteLimit
        else { throw CodecExportFailure(.invalidSource) }
        return Self(directoryURL: directory, sourceURL: source,
                    outputURL: directory.appendingPathComponent(request.outputName),
                    previewURL: directory.appendingPathComponent("preview.png"), request: request,
                    directoryIdentity: identity, sourceIdentity: CodecFileIdentity(information))
    }

    public func validateSourceIdentity() throws {
        let fd = try openSource(); Darwin.close(fd)
    }
    /// The caller owns this descriptor. Use it rather than reopening a user URL.
    public func openSource() throws -> Int32 {
        let directory = try openDirectory(); defer { Darwin.close(directory) }
        let fd = openat(directory, request.inputName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodecExportFailure(.invalidSource) }
        var information = stat()
        guard fstat(fd, &information) == 0, sourceIdentity.matches(information, includeContents: true),
              CodecFileIdentity.isPrivateRegular(information) else {
            Darwin.close(fd); throw CodecExportFailure(.invalidSource)
        }
        return fd
    }
    public func createOutput() throws -> Int32 { try create(name: request.outputName) }
    public func createPreview() throws -> Int32 { try create(name: "preview.png") }
    public func validateOutput() throws -> Int { try validateFile(name: request.outputName, limit: request.outputByteLimit) }
    public func validatePreview() throws -> Int { try validateFile(name: "preview.png", limit: CodecExportLimits.previewBytes) }
    public func openOutput() throws -> Int32 { try openResult(name: request.outputName, limit: request.outputByteLimit) }
    public func openPreview() throws -> Int32 { try openResult(name: "preview.png", limit: CodecExportLimits.previewBytes) }

    private func openDirectory() throws -> Int32 {
        let fd = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodecExportFailure(.invalidJobDirectory) }
        var information = stat()
        guard fstat(fd, &information) == 0, directoryIdentity.matches(information),
              CodecFileIdentity.isPrivateDirectory(information),
              directoryURL.standardizedFileURL.path == directoryURL.resolvingSymlinksInPath().path else {
            Darwin.close(fd); throw CodecExportFailure(.invalidJobDirectory)
        }
        return fd
    }
    private func create(name: String) throws -> Int32 {
        let directory = try openDirectory(); defer { Darwin.close(directory) }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodecExportFailure(.invalidOutput) }
        return fd
    }
    private func openResult(name: String, limit: Int) throws -> Int32 {
        let directory = try openDirectory(); defer { Darwin.close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodecExportFailure(.invalidOutput) }
        var information = stat()
        guard fstat(fd, &information) == 0, CodecFileIdentity.isPrivateRegular(information),
              information.st_size > 0, information.st_size <= Int64(limit) else {
            Darwin.close(fd); throw CodecExportFailure(.invalidOutput)
        }
        return fd
    }
    private func validateFile(name: String, limit: Int) throws -> Int {
        let fd = try openResult(name: name, limit: limit); defer { Darwin.close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0 else { throw CodecExportFailure(.invalidOutput) }
        return Int(information.st_size)
    }
    /// Only known regular, single-link files are unlinked, never recursively.
    /// Called after the worker has stopped writing, or immediately before exit.
    public func cleanupAfterParentLoss() {
        CodecTemporaryJob.removeKnown(directoryURL, expected: directoryIdentity)
    }
}

struct CodecFileIdentity: Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
    }
    func matches(_ info: stat, includeContents: Bool = false) -> Bool {
        device == info.st_dev && inode == info.st_ino && (!includeContents ||
            (size == info.st_size && modifiedSeconds == info.st_mtimespec.tv_sec && modifiedNanoseconds == info.st_mtimespec.tv_nsec &&
             changedSeconds == info.st_ctimespec.tv_sec && changedNanoseconds == info.st_ctimespec.tv_nsec))
    }
    static func isPrivateDirectory(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && info.st_uid == getuid() && info.st_mode & 0o7777 == 0o700
    }
    static func isPrivateRegular(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_uid == getuid() && info.st_nlink == 1 &&
            info.st_mode & 0o7177 == 0 && info.st_mode & 0o400 != 0
    }
}
