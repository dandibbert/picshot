import Darwin
import Foundation

/// A capability for one caller-owned GIF trim stage. The helper job is a
/// sibling on the same volume, never a descendant of this directory.
final class OwnedVideoExportStage: @unchecked Sendable {
    private let directory: OwnedExportDirectory
    var directoryURL: URL { directory.url }
    var clipURL: URL { directoryURL.appendingPathComponent("selected.mp4") }
    var gifURL: URL { directoryURL.appendingPathComponent("selected.gif") }

    private init(directory: OwnedExportDirectory) { self.directory = directory }

    static func create(beside destination: URL) throws -> OwnedVideoExportStage {
        guard destination.isFileURL else { throw VideoTrimError.destinationChanged }
        return try Self(directory: OwnedExportDirectory.create(in: destination.deletingLastPathComponent(),
            prefix: ".picshot-trim-", recognizes: { $0 == "selected.mp4" || $0 == "selected.gif" }))
    }

    func recordClip() throws { try directory.record("selected.mp4") }
    func recordGIF() throws { try directory.record("selected.gif") }
    func finishGIFPublication(at destination: URL) throws {
        try directory.removePublishedLink("selected.gif", destination: destination)
    }

    func validateGIFPaths(sourceURL: URL, destinationURL: URL) throws {
        guard sourceURL.standardizedFileURL == clipURL, destinationURL.standardizedFileURL == gifURL,
              directory.validate(), directory.matchesRecorded("selected.mp4") else {
            throw VideoTrimError.destinationChanged
        }
    }

    func makeSiblingGIFJob(sourceURL: URL, destinationURL: URL) throws -> OwnedGIFJobDirectory {
        try validateGIFPaths(sourceURL: sourceURL, destinationURL: destinationURL)
        let job = try OwnedGIFJobDirectory.create(in: directory.parentURL)
        guard job.device == directory.device, directory.validate() else {
            _ = job.cleanup()
            throw VideoTrimError.destinationChanged
        }
        return job
    }

    /// A failed check deliberately leaves residue. Never recursively delete a
    /// replaced directory, an unknown file, a link, or an unrecorded artifact.
    @discardableResult func cleanupIfOwned() -> Bool { directory.cleanup(adoptRecognizedFiles: false) }
}

/// Parent-side job cleanup is independently identity-bound. Call cleanup only
/// before launch or after confirmed exit; a stranded job retains this owner.
final class OwnedGIFJobDirectory: @unchecked Sendable {
    private let directory: OwnedExportDirectory
    var url: URL { directory.url }
    var device: dev_t { directory.device }
    private init(directory: OwnedExportDirectory) { self.directory = directory }

    static func create(in parent: URL) throws -> OwnedGIFJobDirectory {
        try Self(directory: OwnedExportDirectory.create(in: parent, prefix: ".picshot-gif-job-", recognizes: { name in
            if name == "source.mp4" || name == "result.gif" { return true }
            let prefix = ".picshot-", suffix = ".gif"
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
            return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
        }))
    }

    func recordSource() throws { try directory.record("source.mp4") }
    @discardableResult func cleanup() -> Bool { directory.cleanup(adoptRecognizedFiles: true) }
}

/// An automatically generated GIF destination is also an owned directory.
/// On failure remove only its verified empty root, after its child job has
/// been cleaned. Never recurse around a child job's failed ownership check.
final class OwnedGIFOutputDirectory: @unchecked Sendable {
    private let directory: OwnedExportDirectory
    var url: URL { directory.url }
    private init(directory: OwnedExportDirectory) { self.directory = directory }
    static func create(in parent: URL) throws -> OwnedGIFOutputDirectory {
        try Self(directory: OwnedExportDirectory.create(in: parent, prefix: "PicShot-GIF-", recognizes: { _ in false }))
    }
    @discardableResult func cleanupEmpty() -> Bool { directory.cleanup(adoptRecognizedFiles: false) }
}

/// All traversal/deletion below an admitted parent is descriptor-relative.
/// The complete bounded entry set is checked before the first unlink; each
/// identity is checked again immediately before unlink. Private directories
/// and exclusive UUID creation prevent another ordinary export sharing them.
private final class OwnedExportDirectory: @unchecked Sendable {
    private struct Identity {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
        func matches(_ value: stat) -> Bool { device == value.st_dev && inode == value.st_ino }
    }
    private struct FileIdentity {
        let identity: Identity
        let size: off_t
        let modified: timespec
        let changed: timespec
        init(_ value: stat) {
            identity = Identity(value); size = value.st_size
            modified = value.st_mtimespec; changed = value.st_ctimespec
        }
        func matches(_ value: stat) -> Bool {
            matchesContents(value) &&
                changed.tv_sec == value.st_ctimespec.tv_sec && changed.tv_nsec == value.st_ctimespec.tv_nsec
        }
        func matchesContents(_ value: stat) -> Bool {
            identity.matches(value) && size == value.st_size &&
                modified.tv_sec == value.st_mtimespec.tv_sec && modified.tv_nsec == value.st_mtimespec.tv_nsec
        }
    }

    let url: URL
    let parentURL: URL
    var device: dev_t { identity.device }
    private let parentFD: Int32
    private let descriptor: Int32
    private let parentIdentity: Identity
    private let identity: Identity
    private let recognizes: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var recorded: [String: FileIdentity] = [:]
    private var removed = false

    private init(url: URL, parentURL: URL, parentFD: Int32, descriptor: Int32,
                 parentIdentity: Identity, identity: Identity, recognizes: @escaping @Sendable (String) -> Bool) {
        self.url = url; self.parentURL = parentURL; self.parentFD = parentFD; self.descriptor = descriptor
        self.parentIdentity = parentIdentity; self.identity = identity; self.recognizes = recognizes
    }
    deinit { Darwin.close(descriptor); Darwin.close(parentFD) }

    static func create(in parent: URL, prefix: String,
                       recognizes: @escaping @Sendable (String) -> Bool) throws -> OwnedExportDirectory {
        guard parent.isFileURL else { throw VideoTrimError.destinationChanged }
        let canonical = parent.standardizedFileURL.resolvingSymlinksInPath()
        let parentFD = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw VideoTrimError.destinationChanged }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(parentFD); throw VideoTrimError.destinationChanged
        }
        let name = prefix + UUID().uuidString
        guard mkdirat(parentFD, name, 0o700) == 0 else {
            let code = errno; Darwin.close(parentFD); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        let descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0, isPrivateDirectory(info) else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            Darwin.close(parentFD)
            // Do not remove an entry whose identity was never admitted.
            throw VideoTrimError.destinationChanged
        }
        let result = Self(url: canonical.appendingPathComponent(name, isDirectory: true), parentURL: canonical,
            parentFD: parentFD, descriptor: descriptor, parentIdentity: Identity(parentInfo), identity: Identity(info), recognizes: recognizes)
        guard result.validate() else { throw VideoTrimError.destinationChanged }
        return result
    }

    func validate() -> Bool { lock.lock(); defer { lock.unlock() }; return validateLocked() }
    private func validateLocked() -> Bool {
        var info = stat()
        return !removed && parentURL.resolvingSymlinksInPath() == parentURL &&
            fstat(parentFD, &info) == 0 && parentIdentity.matches(info) &&
            lstat(parentURL.path, &info) == 0 && parentIdentity.matches(info) && info.st_mode & S_IFMT == S_IFDIR &&
            fstat(descriptor, &info) == 0 && identity.matches(info) && Self.isPrivateDirectory(info) &&
            fstatat(parentFD, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
            identity.matches(info) && Self.isPrivateDirectory(info)
    }

    func record(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        var info = stat()
        guard validateLocked(), recognizes(name),
              fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, Self.isOwnedRegularFile(info) else {
            throw VideoTrimError.destinationChanged
        }
        if let previous = recorded[name], !previous.matches(info) { throw VideoTrimError.destinationChanged }
        recorded[name] = FileIdentity(info)
    }

    func matchesRecorded(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var info = stat()
        return validateLocked() && fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
            Self.isOwnedRegularFile(info) && recorded[name]?.matches(info) == true
    }

    /// VideoExportDestination's existing, successful link fallback deliberately
    /// leaves its owned source link for the caller. Admit only that exact pair,
    /// after publication, without allowing hard links in ordinary cleanup.
    func removePublishedLink(_ name: String, destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard validateLocked(), let expected = recorded[name], destination.isFileURL else {
            throw VideoTrimError.destinationChanged
        }
        var source = stat()
        if fstatat(descriptor, name, &source, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw VideoTrimError.destinationChanged }
            return // Exclusive rename consumed the source.
        }
        let targetFD = Darwin.open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard targetFD >= 0 else { throw VideoTrimError.destinationChanged }
        defer { Darwin.close(targetFD) }
        var target = stat()
        guard source.st_mode & S_IFMT == S_IFREG, source.st_uid == geteuid(), source.st_nlink == 2,
              expected.matchesContents(source), fstat(targetFD, &target) == 0, expected.matchesContents(target),
              target.st_nlink == 2, validateLocked(),
              fstatat(descriptor, name, &source, AT_SYMLINK_NOFOLLOW) == 0,
              source.st_mode & S_IFMT == S_IFREG, source.st_nlink == 2, expected.matchesContents(source),
              unlinkat(descriptor, name, 0) == 0 else { throw VideoTrimError.destinationChanged }
    }

    func cleanup(adoptRecognizedFiles: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if removed { return true }
        guard validateLocked() else {
            // The helper may have removed its own private job on control EOF.
            // An absent name is success only when our original open directory
            // has also been unlinked, not when it was renamed elsewhere.
            var info = stat(), entry = stat()
            if fstat(descriptor, &info) == 0, identity.matches(info), info.st_nlink == 0,
               fstatat(parentFD, url.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
                removed = true; return true
            }
            return false
        }
        let listingFD = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listingFD >= 0 else { return false }
        guard let listing = fdopendir(listingFD) else { Darwin.close(listingFD); return false }
        defer { closedir(listing) }
        var files: [(String, FileIdentity)] = []
        var visited = 0
        errno = 0
        while let entry = readdir(listing) {
            visited += 1
            guard visited <= 64 else { return false }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { errno = 0; continue }
            var info = stat()
            guard recognizes(name), (adoptRecognizedFiles || recorded[name] != nil),
                  fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, Self.isOwnedRegularFile(info),
                  recorded[name]?.matches(info) != false else { return false }
            files.append((name, FileIdentity(info))); errno = 0
        }
        guard errno == 0, validateLocked() else { return false }
        for (name, expected) in files {
            var info = stat()
            guard validateLocked(), fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isOwnedRegularFile(info), expected.matches(info), unlinkat(descriptor, name, 0) == 0 else { return false }
        }
        guard validateLocked(), unlinkat(parentFD, url.lastPathComponent, AT_REMOVEDIR) == 0 else { return false }
        removed = true
        return true
    }

    private static func isPrivateDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o7777 == 0o700
    }
    private static func isOwnedRegularFile(_ value: stat) -> Bool {
        // AVFoundation may create 0644 output; its enclosing 0700 directory is
        // the privacy boundary. Never adopt links or executable/special files.
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1 && value.st_mode & 0o7111 == 0
    }
}
