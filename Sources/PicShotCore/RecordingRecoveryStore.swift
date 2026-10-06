import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct RecordingRecoveryFileVersion: Equatable, Sendable {
    public let size: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64
}

public struct RecordingRecoveryCandidate: Identifiable, Sendable {
    public var id: UUID { journal.id }
    public let journal: RecordingRecoveryJournal
    public let sourceURL: URL
    public let byteCount: Int64
    public let sourceVersion: RecordingRecoveryFileVersion
    public var isPreview: Bool { journal.phase == .published || journal.phase == .publishing }
}

public struct RecordingRecoveryScan: Sendable {
    public let candidates: [RecordingRecoveryCandidate]
    public let warnings: [String]
    public let reachedLimit: Bool
}

/// All media reads/moves are anchored to open directory descriptors. Paths from
/// disk are never accepted as absolute paths, and symlinks/hardlinked media are
/// refused. A nonblocking flock prevents a second process recovering a live take.
public enum RecordingRecoveryCheckpoint: Equatable, Sendable {
    case journalRenamed, journalWillSynchronize, protectedLinkCreated, publicationRenamed, rootWillSynchronize
}

public final class RecordingRecoveryStore: @unchecked Sendable {
    public static let maximumCandidates = 128
    public static let maximumDirectoryEntries = 4_096
    public let root: URL
    fileprivate let rootFD: Int32
    fileprivate let checkpoint: (@Sendable (RecordingRecoveryCheckpoint) throws -> Void)?

    public init(root: URL, checkpoint: (@Sendable (RecordingRecoveryCheckpoint) throws -> Void)? = nil) throws {
        self.checkpoint = checkpoint
        guard root.isFileURL else { throw RecordingRecoveryError.unsafePath }
        // Resolve system ancestors (macOS /var -> /private/var) only after
        // rejecting a user-supplied symlink at the root itself.
        let fd = recoveryOpen(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RecordingRecoveryError.unsafePath }
        rootFD = fd
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }
    deinit { close(rootFD) }

    public func begin(stagingDirectory: URL, mediaFilename: String = "recording.mp4",
                      byteLimit: Int64 = RecordingRecoveryJournal.maximumBytes,
                      durationLimit: Double = 3_600) throws -> RecordingRecoveryLease {
        guard stagingDirectory.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath() == root,
              let id = RecordingRecoveryJournal.id(directoryName: stagingDirectory.lastPathComponent),
              ["recording.mp4", "recording-mixed.mp4"].contains(mediaFilename) else { throw RecordingRecoveryError.unsafePath }
        let lease = try RecordingRecoveryLease(store: self, id: id, creatingLock: true)
        let media = try lease.openMedia(filename: mediaFilename, published: false)
        defer { close(media.fd) }
        let journal = RecordingRecoveryJournal(id: id, sourceIdentity: media.identity,
            mediaFilename: mediaFilename, byteLimit: byteLimit, durationLimit: durationLimit)
        _ = try journal.validated()
        try lease.writeInitial(journal)
        return lease
    }

    public func discover() throws -> RecordingRecoveryScan {
        // openat(".") gives an independent directory stream offset; dup would
        // share the existing offset and could skip entries on repeated scans.
        let scanFD = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scanFD >= 0, let directory = fdopendir(scanFD) else {
            if scanFD >= 0 { close(scanFD) }; throw failure()
        }
        defer { closedir(directory) }
        var candidates: [RecordingRecoveryCandidate] = [], warnings: [String] = []
        var entries = 0, reachedLimit = false
        while let entry = readdir(directory) {
            entries += 1
            if entries > Self.maximumDirectoryEntries || candidates.count >= Self.maximumCandidates { reachedLimit = true; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            guard let id = RecordingRecoveryJournal.id(directoryName: name) else { continue }
            do {
                let lease = try RecordingRecoveryLease(store: self, id: id)
                defer { lease.closeLease() }
                try lease.load()
                guard let journal = lease.journal, journal.phase.isPending else { continue }
                let source = try lease.checkedSource(enforceByteLimit: false)
                defer { close(source.fd) }
                candidates.append(RecordingRecoveryCandidate(journal: journal, sourceURL: source.url, byteCount: source.size, sourceVersion: source.version))
            } catch RecordingRecoveryError.activeSession { continue }
            catch {
                if warnings.count < Self.maximumCandidates { warnings.append("\(name): \(error.localizedDescription)") }
            }
        }
        return RecordingRecoveryScan(candidates: candidates.sorted { $0.journal.createdAt < $1.journal.createdAt },
                                     warnings: warnings, reachedLimit: reachedLimit)
    }

    public func open(_ candidate: RecordingRecoveryCandidate) throws -> RecordingRecoveryLease {
        let lease = try RecordingRecoveryLease(store: self, id: candidate.id)
        try lease.load()
        guard lease.journal == candidate.journal else { throw RecordingRecoveryError.sourceChanged }
        lease.expectedVersion = candidate.sourceVersion
        let source = try lease.checkedSource(enforceByteLimit: false); close(source.fd)
        return lease
    }

    /// Reject a root pathname replaced after this store anchored its descriptor.
    public func validateRootPath() throws {
        let current = recoveryOpen(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw RecordingRecoveryError.unsafePath }
        defer { close(current) }
        var expected = stat(), actual = stat()
        guard fstat(rootFD, &expected) == 0, fstat(current, &actual) == 0,
              expected.st_dev == actual.st_dev, expected.st_ino == actual.st_ino else { throw RecordingRecoveryError.sourceChanged }
    }
    public func makeWorkspace() throws -> RecordingRecoveryWorkspace {
        try validateRootPath()
        return try RecordingRecoveryWorkspace(store: self)
    }
    fileprivate func openDirectory(_ name: String) throws -> Int32 {
        let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RecordingRecoveryError.unsafePath }
        return fd
    }
    fileprivate func openPublished(_ name: String) throws -> RecordingRecoveryFile {
        guard RecordingRecoveryJournal.isPublishedFilename(name) else { throw RecordingRecoveryError.unsafePath }
        return try checkedFile(directory: rootFD, name: name, url: root.appendingPathComponent(name))
    }
    fileprivate func moveToRoot(directoryFD: Int32, filename: String, destination: String) throws {
        guard RecordingRecoveryJournal.isPublishedFilename(destination) else { throw RecordingRecoveryError.unsafePath }
        #if canImport(Darwin)
        guard renameatx_np(directoryFD, filename, rootFD, destination, UInt32(RENAME_EXCL)) == 0 else { throw failure() }
        #else
        guard linkat(directoryFD, filename, rootFD, destination, 0) == 0 else { throw failure() }
        guard unlinkat(directoryFD, filename, 0) == 0 else { throw failure() }
        #endif
        try checkpoint?(.publicationRenamed)
        try synchronizeRoot()
    }
    fileprivate func synchronizeRoot() throws {
        try checkpoint?(.rootWillSynchronize)
        guard fsync(rootFD) == 0 else { throw failure() }
    }
}

fileprivate struct RecordingRecoveryFile {
    let fd: Int32
    let identity: RecordingRecoveryIdentity
    let size: Int64
    let version: RecordingRecoveryFileVersion
    let linkCount: UInt64
    let url: URL
}

public final class RecordingRecoveryLease: @unchecked Sendable {
    private let store: RecordingRecoveryStore
    public let directory: URL
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1
    public private(set) var journal: RecordingRecoveryJournal?
    fileprivate var expectedVersion: RecordingRecoveryFileVersion?
    // Call methods on one serial writer queue or one recovery task, never both.
    fileprivate init(store: RecordingRecoveryStore, id: UUID, creatingLock: Bool = false) throws {
        self.store = store
        let name = ".recording-" + id.uuidString
        directory = store.root.appendingPathComponent(name, isDirectory: true)
        directoryFD = try store.openDirectory(name)
        lockFD = openat(directoryFD, "recovery.lock", O_RDWR | (creatingLock ? O_CREAT : 0) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw RecordingRecoveryError.unsafePath }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw RecordingRecoveryError.unsafePath
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw RecordingRecoveryError.activeSession
        }
    }
    deinit { closeLease(); if directoryFD >= 0 { close(directoryFD) } }
    public func closeLease() { if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 } }
    private func requireLease() throws { guard lockFD >= 0 else { throw RecordingRecoveryError.activeSession } }

    fileprivate func load() throws {
        let value = try readJournal()
        guard value.directoryName == directory.lastPathComponent else { throw RecordingRecoveryError.invalidJournal }
        journal = value
    }
    fileprivate func writeInitial(_ value: RecordingRecoveryJournal) throws {
        // An existing journal is never replaced by a new recording.
        var info = stat()
        guard fstatat(directoryFD, RecordingRecoveryJournal.filename, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw RecordingRecoveryError.invalidJournal
        }
        try write(value); journal = value
    }
    private func readJournal() throws -> RecordingRecoveryJournal {
        try requireLease()
        let file = try checkedFile(directory: directoryFD, name: RecordingRecoveryJournal.filename,
                                   url: directory.appendingPathComponent(RecordingRecoveryJournal.filename))
        defer { close(file.fd) }
        guard file.size > 0, file.size <= RecordingRecoveryJournal.maximumJournalBytes else { throw RecordingRecoveryError.invalidJournal }
        let data = try readBytes(fd: file.fd, offset: 0, count: Int(file.size))
        do { return try JSONDecoder().decode(RecordingRecoveryJournal.self, from: data).validated() }
        catch { throw RecordingRecoveryError.invalidJournal }
    }
    private func write(_ value: RecordingRecoveryJournal) throws {
        try requireLease()
        let data = try JSONEncoder().encode(value.validated())
        guard data.count <= RecordingRecoveryJournal.maximumJournalBytes else { throw RecordingRecoveryError.invalidJournal }
        let temporary = ".journal-write-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd); _ = unlinkat(directoryFD, temporary, 0) }
        try writeBytes(fd: fd, data: data)
        guard fsync(fd) == 0 else { throw failure() }
        guard renameat(directoryFD, temporary, directoryFD, RecordingRecoveryJournal.filename) == 0 else { throw failure() }
        // Preserve the exact visible transaction state even when the following
        // durability barrier fails, so a retry retains its planned filename.
        journal = value
        try store.checkpoint?(.journalRenamed)
        try store.checkpoint?(.journalWillSynchronize)
        guard fsync(directoryFD) == 0 else { throw failure() }
    }
    private func commit(_ next: RecordingRecoveryJournal) throws {
        let stored = try readJournal()
        if stored == next {
            // A previous rename may have committed while directory fsync failed.
            // Retry only the exact intended record; never overwrite other state.
            try store.checkpoint?(.journalWillSynchronize)
            guard fsync(directoryFD) == 0 else { throw failure() }
            journal = next; return
        }
        guard stored == journal else { throw RecordingRecoveryError.sourceChanged }
        try write(next); journal = next
    }
    fileprivate func openMedia(filename: String, published: Bool) throws -> RecordingRecoveryFile {
        if published { return try store.openPublished(filename) }
        guard RecordingRecoveryJournal.mediaFilenames.contains(filename) else { throw RecordingRecoveryError.unsafePath }
        let file = try checkedFile(directory: directoryFD, name: filename, url: directory.appendingPathComponent(filename), maximumLinks: filename == "recording-mixed.mp4" ? 1 : 2)
        if file.linkCount == 2 {
            // Only the two exact writer-cancellation aliases may share an inode.
            // An additional external hardlink or a missing alias is rejected.
            let alias = filename == "recording.mp4" ? "recording-preserved.mp4" : "recording.mp4"
            do {
                let other = try checkedFile(directory: directoryFD, name: alias, url: directory.appendingPathComponent(alias), maximumLinks: 2)
                defer { close(other.fd) }
                guard other.identity == file.identity, other.linkCount == 2 else { throw RecordingRecoveryError.unsafePath }
            } catch { close(file.fd); throw error }
        }
        return file
    }
    fileprivate func checkedSource(enforceByteLimit: Bool = true) throws -> RecordingRecoveryFile {
        try requireLease()
        guard let journal else { throw RecordingRecoveryError.invalidJournal }
        let file: RecordingRecoveryFile
        if [.published, .publishing].contains(journal.phase), let name = journal.publishedFilename {
            do { file = try openMedia(filename: name, published: true) }
            catch {
                // A crash before the planned rename leaves the staged source.
                guard journal.phase == .publishing else { throw error }
                file = try openMedia(filename: journal.mediaFilename, published: false)
            }
        } else { file = try openMedia(filename: journal.mediaFilename, published: false) }
        guard file.identity == journal.sourceIdentity,
              expectedVersion.map({ $0 == file.version }) ?? true else {
            close(file.fd); throw RecordingRecoveryError.sourceChanged
        }
        if enforceByteLimit, file.size > journal.byteLimit { close(file.fd); throw RecordingRecoveryError.limitExceeded }
        return file
    }
    public func validatedSourceURL() throws -> URL {
        let source = try checkedSource(enforceByteLimit: false); defer { close(source.fd) }; return source.url
    }

    /// AVAssetWriter.cancelWriting can delete its output URL. Protect that
    /// inode with a second owned name and commit the journal BEFORE cancellation.
    /// If this fails the caller MUST NOT cancel/deallocate a writing encoder.
    /// No movie bytes are copied; even low disk needs only directory metadata.
    public func protectBeforeCancellingWriter() throws {
        guard var next = journal, [.capturing, .finalized].contains(next.phase),
              ["recording.mp4", "recording-preserved.mp4"].contains(next.mediaFilename) else {
            throw RecordingRecoveryError.invalidJournal
        }
        if next.mediaFilename == "recording-preserved.mp4" {
            let protected = try checkedSource(enforceByteLimit: false); defer { close(protected.fd) }
            guard fsync(protected.fd) == 0 else { throw failure() }
            try commit(next); return
        }
        let source = try checkedSource(enforceByteLimit: false); defer { close(source.fd) }
        if linkat(directoryFD, "recording.mp4", directoryFD, "recording-preserved.mp4", 0) != 0, errno != EEXIST { throw failure() }
        let protected = try openMedia(filename: "recording-preserved.mp4", published: false)
        defer { close(protected.fd) }
        guard protected.identity == source.identity else { throw RecordingRecoveryError.sourceChanged }
        try store.checkpoint?(.protectedLinkCreated)
        guard fsync(protected.fd) == 0, fsync(directoryFD) == 0 else { throw failure() }
        next.mediaFilename = "recording-preserved.mp4"
        try commit(next)
    }

    public func markFinalized(mediaURL: URL? = nil) throws {
        guard var next = journal else { throw RecordingRecoveryError.invalidJournal }
        guard [.capturing, .finalized].contains(next.phase) else { throw RecordingRecoveryError.invalidJournal }
        let url = mediaURL ?? directory.appendingPathComponent(next.mediaFilename)
        guard url.standardizedFileURL.deletingLastPathComponent() == directory else { throw RecordingRecoveryError.unsafePath }
        let file = try openMedia(filename: url.lastPathComponent, published: false)
        defer { close(file.fd) }
        guard file.size > 0, file.size <= next.byteLimit else { throw RecordingRecoveryError.limitExceeded }
        if url.lastPathComponent == next.mediaFilename, file.identity != next.sourceIdentity { throw RecordingRecoveryError.sourceChanged }
        guard fsync(file.fd) == 0 else { throw failure() }
        next.mediaFilename = url.lastPathComponent; next.sourceIdentity = file.identity; next.phase = .finalized
        try commit(next)
    }

    /// Normal-save transaction, including a durable planned name before rename.
    /// Callers must not recursively remove the staging directory afterward.
    @discardableResult public func publishFinalized(mediaURL: URL? = nil) throws -> URL {
        if journal?.phase == .capturing || (journal?.phase == .finalized && mediaURL != nil) {
            try markFinalized(mediaURL: mediaURL)
        }
        guard var next = journal, [.finalized, .publishing, .published].contains(next.phase) else { throw RecordingRecoveryError.invalidJournal }
        let source = try checkedSource(); defer { close(source.fd) }
        if next.phase == .published { try store.synchronizeRoot(); try commit(next); return source.url }
        let name: String
        if next.phase == .publishing, let planned = next.publishedFilename { name = planned }
        else {
            name = "PicShot-" + UUID().uuidString + ".mp4"
            next.publishedFilename = name; next.phase = .publishing; try commit(next)
        }
        // A failed fsync/commit after rename can retry without moving twice.
        if source.url.deletingLastPathComponent() != store.root {
            try store.moveToRoot(directoryFD: directoryFD, filename: next.mediaFilename, destination: name)
        }
        let moved = try store.openPublished(name); defer { close(moved.fd) }
        guard moved.identity == source.identity else { throw RecordingRecoveryError.sourceChanged }
        try store.synchronizeRoot()
        next.phase = .published; try commit(next)
        return store.root.appendingPathComponent(name)
    }

    /// Explicit discard is an archival state, never deletion or Trash emptying.
    public func discard() throws {
        guard var next = journal else { throw RecordingRecoveryError.invalidJournal }
        let source = try checkedSource(enforceByteLimit: false); close(source.fd)
        next.phase = .discarded; try commit(next)
    }
    /// Intentional preview close only dismisses its recovery prompt.
    public func dismissPreview() throws {
        guard var next = journal, [.published, .publishing].contains(next.phase) else { throw RecordingRecoveryError.invalidJournal }
        let source = try checkedSource(enforceByteLimit: false); close(source.fd)
        next.phase = .dismissed; try commit(next)
    }
    public func markRecovered(filename: String) throws {
        guard var next = journal, RecordingRecoveryJournal.isRecoveredFilename(filename) else { throw RecordingRecoveryError.invalidJournal }
        let output = try store.openPublished(filename); defer { close(output.fd) }
        guard output.size > 0, output.identity != next.sourceIdentity else { throw RecordingRecoveryError.sourceChanged }
        next.phase = .recovered; next.recoveredFilename = filename; try commit(next)
    }

    /// Copies through the original open descriptor, retaining inode and size
    /// checks across the copy. Destination must be a fresh file, never replaced.
    public func copyCompletePrefix(to destination: URL) throws -> RecordingRecoveryPrefix {
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        return try copyCompletePrefix(toFD: fd)
    }
    public func copyCompletePrefix(in workspace: RecordingRecoveryWorkspace) throws -> RecordingRecoveryPrefix {
        try workspace.validatePaths()
        let fd = try workspace.createSourceCopy()
        defer { close(fd) }
        return try copyCompletePrefix(toFD: fd)
    }
    private func copyCompletePrefix(toFD fd: Int32) throws -> RecordingRecoveryPrefix {
        let source = try checkedSource(); defer { close(source.fd) }
        guard let journal else { throw RecordingRecoveryError.invalidJournal }
        let prefix = try RecordingRecoveryMP4.completePrefix(fileSize: source.size, finalized: journal.phase != .capturing) {
            try readBytes(fd: source.fd, offset: $0, count: $1)
        }
        var offset: Int64 = 0
        while offset < prefix.byteCount {
            try Task.checkCancellation()
            let length = Int(min(1_048_576, prefix.byteCount - offset))
            let data = try readBytes(fd: source.fd, offset: offset, count: length)
            guard data.count == length else { throw RecordingRecoveryError.sourceChanged }
            try writeBytes(fd: fd, data: data); offset += Int64(length)
        }
        guard fsync(fd) == 0 else { throw failure() }
        let again = try checkedSource(); defer { close(again.fd) }
        guard again.identity == source.identity, again.version == source.version else { throw RecordingRecoveryError.sourceChanged }
        return prefix
    }
}

private func checkedFile(directory: Int32, name: String, url: URL, maximumLinks: UInt64 = 1) throws -> RecordingRecoveryFile {
    let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw RecordingRecoveryError.unsafePath }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink >= 1, UInt64(info.st_nlink) <= maximumLinks, info.st_size >= 0 else {
        close(fd); throw RecordingRecoveryError.unsafePath
    }
    #if canImport(Darwin)
    let modified = info.st_mtimespec, changed = info.st_ctimespec
    #else
    let modified = info.st_mtim, changed = info.st_ctim
    #endif
    let version = RecordingRecoveryFileVersion(size: Int64(info.st_size), modificationSeconds: Int64(modified.tv_sec),
        modificationNanoseconds: Int64(modified.tv_nsec), changeSeconds: Int64(changed.tv_sec), changeNanoseconds: Int64(changed.tv_nsec))
    return RecordingRecoveryFile(fd: fd, identity: .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)),
                                 size: Int64(info.st_size), version: version, linkCount: UInt64(info.st_nlink), url: url)
}
private func failure() -> RecordingRecoveryError { .io(String(cString: strerror(errno))) }
private func readBytes(fd: Int32, offset: Int64, count: Int) throws -> Data {
    var data = Data(count: count)
    let received = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
    guard received >= 0 else { throw failure() }
    if received < count { data.removeSubrange(received..<count) }
    return data
}
private func writeBytes(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { buffer in
        var done = 0
        while done < buffer.count {
            let count = write(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure() }; done += count
        }
    }
}

private func recoveryOpen(_ path: String, _ flags: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.open(path, flags)
    #else
    return Glibc.open(path, flags)
    #endif
}

/// The only two writable scratch names are fixed here. No recursive cleanup,
/// no untrusted destination names, and publication is relative to anchored FDs.
public final class RecordingRecoveryWorkspace: @unchecked Sendable {
    private let store: RecordingRecoveryStore
    private let name: String
    private let fd: Int32
    public let directory: URL
    public var sourceCopyURL: URL { directory.appendingPathComponent("complete-prefix.mp4") }
    public var outputURL: URL { directory.appendingPathComponent("recovered.mp4") }
    fileprivate init(store: RecordingRecoveryStore) throws {
        self.store = store; name = ".recovery-work-" + UUID().uuidString
        directory = store.root.appendingPathComponent(name, isDirectory: true)
        guard mkdirat(store.rootFD, name, 0o700) == 0 else { throw failure() }
        fd = try store.openDirectory(name)
    }
    deinit {
        _ = unlinkat(fd, "complete-prefix.mp4", 0)
        _ = unlinkat(fd, "recovered.mp4", 0)
        close(fd)
        _ = unlinkat(store.rootFD, name, AT_REMOVEDIR)
    }
    public func validatePaths() throws {
        try store.validateRootPath()
        let current = recoveryOpen(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw RecordingRecoveryError.unsafePath }
        defer { close(current) }
        var expected = stat(), actual = stat()
        guard fstat(fd, &expected) == 0, fstat(current, &actual) == 0,
              expected.st_dev == actual.st_dev, expected.st_ino == actual.st_ino else { throw RecordingRecoveryError.sourceChanged }
    }
    fileprivate func createSourceCopy() throws -> Int32 {
        let copy = openat(fd, "complete-prefix.mp4", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard copy >= 0 else { throw failure() }
        return copy
    }
    public func publish(filename: String) throws -> URL {
        guard RecordingRecoveryJournal.isRecoveredFilename(filename) else { throw RecordingRecoveryError.unsafePath }
        try validatePaths()
        let source = try checkedFile(directory: fd, name: "recovered.mp4", url: outputURL)
        defer { close(source.fd) }
        guard source.size > 0, fsync(source.fd) == 0 else { throw failure() }
        try store.moveToRoot(directoryFD: fd, filename: "recovered.mp4", destination: filename)
        let result = try store.openPublished(filename); defer { close(result.fd) }
        guard result.identity == source.identity else { throw RecordingRecoveryError.sourceChanged }
        return result.url
    }
}
