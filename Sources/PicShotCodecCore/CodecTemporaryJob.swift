import Foundation
import Darwin

public enum CodecTemporaryJob {
    public static let prefix = "picshot-codec-"
    private static let markerName = ".picshot-codec-job.json"
    private struct Marker: Codable { let format: String; let parent: Int32 }
    private static let format = "PicShotCodecJob-v1"
    private static let names: Set<String> = [markerName, "input.png", "input.mp4", "output.webp", "output.avif", "preview.png"]

    public static func create(in root: URL) throws -> URL {
        guard root.isFileURL else { throw CodecExportFailure(.invalidJobDirectory) }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        sweep(in: root)
        let directory = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let marker = try JSONEncoder().encode(Marker(format: format, parent: getpid()))
            let fd = Darwin.open(directory.appendingPathComponent(markerName).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CodecExportFailure(.invalidJobDirectory) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.write(contentsOf: marker); try file.close()
            return directory
        } catch { removeKnown(directory); throw error }
    }
    public static func removeOwned(_ directory: URL) { removeKnown(directory) }
    public static func sweep(in root: URL, now: Date = Date()) {
        guard root.isFileURL else { return }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        guard let listing = fdopendir(fd) else { Darwin.close(fd); return }
        defer { closedir(listing) }
        // Bound enumeration itself, rather than materializing an arbitrarily
        // large temp-directory array before taking its prefix.
        var visited = 0
        while visited < 4_096, let entry = readdir(listing) {
            visited += 1
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            guard name.hasPrefix(prefix) else { continue }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard let identity = try? validateDirectory(directory), let marker = try? readMarker(directory),
                  !isAlive(marker.parent), now.timeIntervalSince1970 - Double(identity.modifiedSeconds) > 3_600
            else { continue }
            removeKnown(directory, expected: identity)
        }
    }
    static func validateDirectory(_ directory: URL) throws -> CodecFileIdentity {
        guard directory.isFileURL, directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil
        else { throw CodecExportFailure(.invalidJobDirectory) }
        var information = stat()
        guard lstat(directory.path, &information) == 0, CodecFileIdentity.isPrivateDirectory(information)
        else { throw CodecExportFailure(.invalidJobDirectory) }
        return CodecFileIdentity(information)
    }
    private static func readMarker(_ directory: URL) throws -> Marker {
        let fd = Darwin.open(directory.appendingPathComponent(markerName).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodecExportFailure(.invalidJobDirectory) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, CodecFileIdentity.isPrivateRegular(info), (1...256).contains(info.st_size),
              let data = try file.read(upToCount: 257), data.count == info.st_size,
              let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.format == format, marker.parent > 1
        else { throw CodecExportFailure(.invalidJobDirectory) }
        return marker
    }
    private static func isAlive(_ pid: Int32) -> Bool { pid > 1 && (kill(pid, 0) == 0 || errno == EPERM) }
    static func removeKnown(_ directory: URL, expected: CodecFileIdentity? = nil) {
        guard let identity = try? validateDirectory(directory) else { return }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, identity.matches(info), expected?.matches(info) != false else { return }
        let listingFD = dup(fd)
        guard listingFD >= 0 else { return }
        guard let listing = fdopendir(listingFD) else { Darwin.close(listingFD); return }
        defer { closedir(listing) }
        var candidates: [String] = []
        errno = 0
        while let entry = readdir(listing) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.contains(name), candidates.count < names.count else { return }
            candidates.append(name); errno = 0
        }
        guard errno == 0 else { return }
        // Check the whole set before deleting anything; links, unknown files,
        // substituted directories and hard links deliberately leave residue.
        for name in candidates {
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, CodecFileIdentity.isPrivateRegular(info) else { return }
        }
        for name in candidates { guard unlinkat(fd, name, 0) == 0 else { return } }
        guard lstat(directory.path, &info) == 0, identity.matches(info), CodecFileIdentity.isPrivateDirectory(info) else { return }
        _ = rmdir(directory.path)
    }
}
