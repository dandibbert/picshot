import Foundation
import Darwin

/// Fixed-name private files for this diagnostic only. No recursive removal or
/// production codec allowlist changes. Cleanup requires the captured identity.
public struct ImageDecodeDiagnosticJob: @unchecked Sendable {
    public static let prefix = "picshot-image-decode-diagnostic-"
    private static let names: Set<String> = ["request.json", "input.png", "decoded.rgba"]
    public let directory: URL, request: ImageDecodeDiagnosticRequest
    private let identity: ImageDecodeFileIdentity, sourceIdentity: ImageDecodeFileIdentity

    public static func create(png: Data, mode: ImageDecodeDiagnosticRequest.Mode, check: () throws -> Void) throws -> Self {
        guard !png.isEmpty, png.count <= ImageDecodeDiagnosticLimits.pngBytes else { throw ImageDecodeDiagnosticError.invalidInput }
        try check()
        let token = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(prefix + token, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let identity = try directoryIdentity(directory)
        do {
            let request = ImageDecodeDiagnosticRequest(token: token, parentPID: getpid(), pngBytes: png.count,
                pngSHA256: ImageDecodeDiagnosticLimits.digest(png), mode: mode)
            let descriptor = try openDirectory(directory, identity: identity); defer { Darwin.close(descriptor) }
            try createFile("request.json", in: descriptor, data: JSONEncoder().encode(request), check: check)
            try createFile("input.png", in: descriptor, data: png, check: check)
            return try validate(directory: directory, expectedParent: getpid())
        } catch {
            guard remove(directory, identity: identity) else { throw ImageDecodeDiagnosticCreationFailure(directory: directory, identity: identity) }
            throw error
        }
    }
    /// Admit the OS-provided cwd through Foundation's normalized spelling, then
    /// bind it to an independently opened current-directory descriptor. Darwin
    /// getcwd may expose /private/var while Foundation standardization uses /var.
    /// Normalizing caller-supplied paths is deliberately not part of validate().
    public static func validateCurrentWorkingDirectory(expectedParent: Int32) throws -> Self {
        let fd = Darwin.open(".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ImageDecodeDiagnosticError.invalidJob }; defer { Darwin.close(fd) }
        var current = stat()
        guard fstat(fd, &current) == 0, ImageDecodeFileIdentity.privateDirectory(current) else { throw ImageDecodeDiagnosticError.invalidJob }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
        let job = try validate(directory: cwd, expectedParent: expectedParent)
        guard job.identity.sameObject(current) else { throw ImageDecodeDiagnosticError.invalidJob }
        return job
    }
    public static func validate(directory: URL, expectedParent: Int32) throws -> Self {
        let identity = try directoryIdentity(directory)
        let fd = try openDirectory(directory, identity: identity); defer { Darwin.close(fd) }
        let (data, _) = try readFile("request.json", in: fd, maximum: ImageDecodeDiagnosticLimits.requestBytes, check: {})
        let request = try ImageDecodeDiagnosticRequest.decode(data)
        guard request.parentPID == expectedParent, directory.lastPathComponent == prefix + request.token else { throw ImageDecodeDiagnosticError.invalidJob }
        var source = stat(), output = stat()
        guard fstatat(fd, "input.png", &source, AT_SYMLINK_NOFOLLOW) == 0, ImageDecodeFileIdentity.privateRegular(source), source.st_size == request.pngBytes,
              fstatat(fd, "decoded.rgba", &output, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ImageDecodeDiagnosticError.invalidJob }
        return Self(directory: directory, request: request, identity: identity, sourceIdentity: ImageDecodeFileIdentity(source))
    }
    public func readPNG(check: () throws -> Void) throws -> Data {
        let fd = try Self.openDirectory(directory, identity: identity); defer { Darwin.close(fd) }
        let (data, source) = try Self.readFile("input.png", in: fd, maximum: ImageDecodeDiagnosticLimits.pngBytes, check: check)
        guard source == sourceIdentity, data.count == request.pngBytes, ImageDecodeDiagnosticLimits.digest(data) == request.pngSHA256 else { throw ImageDecodeDiagnosticError.invalidInput }
        return data
    }
    public func writeRaw(_ data: Data, check: () throws -> Void) throws {
        guard data.count == ImageDecodeDiagnosticLimits.rasterBytes else { throw ImageDecodeDiagnosticError.invalidInput }
        let fd = try Self.openDirectory(directory, identity: identity); defer { Darwin.close(fd) }
        try Self.createFile("decoded.rgba", in: fd, data: data, check: check)
    }
    public func readRaw(sha256: String, check: () throws -> Void) throws -> Data {
        guard ImageDecodeDiagnosticLimits.validDigest(sha256) else { throw ImageDecodeDiagnosticError.invalidProtocol }
        let fd = try Self.openDirectory(directory, identity: identity); defer { Darwin.close(fd) }
        let (data, _) = try Self.readFile("decoded.rgba", in: fd, maximum: ImageDecodeDiagnosticLimits.rasterBytes, check: check)
        guard data.count == ImageDecodeDiagnosticLimits.rasterBytes, ImageDecodeDiagnosticLimits.digest(data) == sha256 else { throw ImageDecodeDiagnosticError.outputMismatch }
        return data
    }
    /// Caller must first confirm that no child can still access this job.
    public func removeAfterExit() -> Bool { Self.remove(directory, identity: identity) }
    public func outputExists() -> Bool {
        var info = stat(); return lstat(directory.appendingPathComponent("decoded.rgba").path, &info) == 0
    }
    private static func directoryIdentity(_ directory: URL) throws -> ImageDecodeFileIdentity {
        guard directory.isFileURL, directory.path == directory.standardizedFileURL.resolvingSymlinksInPath().path,
              directory.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil else { throw ImageDecodeDiagnosticError.invalidJob }
        var info = stat()
        guard lstat(directory.path, &info) == 0, ImageDecodeFileIdentity.privateDirectory(info) else { throw ImageDecodeDiagnosticError.invalidJob }
        return ImageDecodeFileIdentity(info)
    }
    private static func openDirectory(_ directory: URL, identity: ImageDecodeFileIdentity) throws -> Int32 {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ImageDecodeDiagnosticError.invalidJob }
        var info = stat()
        guard fstat(fd, &info) == 0, identity.sameObject(info), ImageDecodeFileIdentity.privateDirectory(info) else { Darwin.close(fd); throw ImageDecodeDiagnosticError.invalidJob }
        return fd
    }
    private static func createFile(_ name: String, in directory: Int32, data: Data, check: () throws -> Void) throws {
        guard names.contains(name) else { throw ImageDecodeDiagnosticError.invalidJob }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ImageDecodeDiagnosticError.invalidJob }; defer { Darwin.close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                try check()
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), min(65_536, data.count - offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ImageDecodeDiagnosticError.invalidJob }; offset += n
            }
        }
        try check(); guard fsync(fd) == 0 else { throw ImageDecodeDiagnosticError.invalidJob }; try check()
    }
    private static func readFile(_ name: String, in directory: Int32, maximum: Int, check: () throws -> Void) throws -> (Data, ImageDecodeFileIdentity) {
        guard names.contains(name) else { throw ImageDecodeDiagnosticError.invalidJob }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ImageDecodeDiagnosticError.invalidJob }; defer { Darwin.close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, ImageDecodeFileIdentity.privateRegular(initial), initial.st_size > 0, initial.st_size <= maximum else { throw ImageDecodeDiagnosticError.invalidJob }
        let identity = ImageDecodeFileIdentity(initial)
        var data = Data(); data.reserveCapacity(Int(initial.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < initial.st_size {
            try check()
            let n = Darwin.read(fd, &buffer, min(buffer.count, Int(initial.st_size) - data.count))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ImageDecodeDiagnosticError.invalidJob }; data.append(contentsOf: buffer.prefix(n))
        }
        var final = stat(), path = stat()
        guard fstat(fd, &final) == 0, fstatat(directory, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              identity == ImageDecodeFileIdentity(final), identity == ImageDecodeFileIdentity(path), ImageDecodeFileIdentity.privateRegular(final) else { throw ImageDecodeDiagnosticError.invalidJob }
        try check(); return (data, identity)
    }
    fileprivate static func remove(_ directory: URL, identity: ImageDecodeFileIdentity) -> Bool {
        guard let fd = try? openDirectory(directory, identity: identity) else { return false }; defer { Darwin.close(fd) }
        let copy = dup(fd); guard copy >= 0 else { return false }
        guard let listing = fdopendir(copy) else { Darwin.close(copy); return false }; defer { closedir(listing) }
        var found: [String] = [], info = stat()
        errno = 0
        while let entry = readdir(listing) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { p in p.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard names.contains(name), found.count < names.count else { return false }; found.append(name); errno = 0
        }
        guard errno == 0 else { return false }
        for name in found { guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, ImageDecodeFileIdentity.privateRegular(info) else { return false } }
        for name in found { guard unlinkat(fd, name, 0) == 0 else { return false } }
        guard lstat(directory.path, &info) == 0, identity.sameObject(info), ImageDecodeFileIdentity.privateDirectory(info), rmdir(directory.path) == 0 else { return false }
        return lstat(directory.path, &info) != 0 && errno == ENOENT
    }
}
public struct ImageDecodeDiagnosticCreationFailure: Error, LocalizedError, Sendable {
    public let directory: URL
    fileprivate let identity: ImageDecodeFileIdentity
    public var errorDescription: String? { "Image decode diagnostic staging cleanup was not confirmed" }
    public func retryOwnedCleanup() -> Bool { ImageDecodeDiagnosticJob.remove(directory, identity: identity) }
}
fileprivate struct ImageDecodeFileIdentity: Equatable, Sendable {
    let device: dev_t, inode: ino_t, size: off_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
    func sameObject(_ value: stat) -> Bool { device == value.st_dev && inode == value.st_ino }
    static func privateDirectory(_ v: stat) -> Bool { v.st_mode & S_IFMT == S_IFDIR && v.st_uid == geteuid() && v.st_mode & 0o7777 == 0o700 }
    static func privateRegular(_ v: stat) -> Bool { v.st_mode & S_IFMT == S_IFREG && v.st_uid == geteuid() && v.st_mode & 0o7777 == 0o600 && v.st_nlink == 1 }
}
