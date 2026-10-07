import AppKit
import Darwin
import PicShotCore

/// The picker/collision sheet offers Keep Both, Choose Another Name and Cancel.
/// Replace is intentionally absent: a check-then-rename cannot bind permission to
/// the same existing inode in the presence of an unrelated writer.
enum SaveWorkflowError: LocalizedError {
    case collision(URL), unsafeDirectory, changedDirectory, exhaustedNames, invalidArtifact, writeFailed
    var errorDescription: String? {
        switch self {
        case .collision(let url): return "已存在 \(url.lastPathComponent)。请选择保留两者、更改名称或取消。"
        case .unsafeDirectory: return "无法安全打开保存文件夹。请重新选择本地真实文件夹，不能使用符号链接。"
        case .changedDirectory: return "保存过程中目录发生变化；没有覆盖已有文件。请重新选择文件夹。"
        case .exhaustedNames: return "可用文件名已用尽，请更改命名模板。"
        case .invalidArtifact: return "待保存内容或尺寸无效，请重新导出。"
        case .writeFailed: return "无法保存，请检查文件夹权限和剩余空间。"
        }
    }
}

enum SaveWorkflowClipboardOutcome: Equatable {
    case notRequested, copied, failed, cancelledAfterSave
}

/// Publication and copying are separate outcomes. A clipboard failure/cancellation
/// can never roll back the saved file. Copy uses the same immutable encoded bytes.
struct SaveWorkflowResult {
    let savedURL: URL
    let byteCount: Int
    var clipboardOutcome: SaveWorkflowClipboardOutcome = .notRequested
    fileprivate let copyData: Data
    fileprivate let copyType: String
}

/// Deterministic native test checkpoints; production never supplies these closures.
struct SaveWorkflowTestHooks {
    var beforeReadbackChunk: ((Int) -> Void)? = nil
    var beforeCollisionAttempt: ((Int) -> Void)? = nil
    var directoryFailure: ((SaveWorkflowDirectoryDiagnostic) -> Void)? = nil
}

/// Opt-in fixture diagnostics. Never logs user paths or changes directory-open policy.
struct SaveWorkflowDirectoryDiagnostic: Equatable {
    let operation: String
    let componentIndex: Int
    let component: String
    let errorNumber: Int32
    let observedMode: UInt32?
    var summary: String {
        "\(operation) component[\(componentIndex)]=\(component) errno=\(errorNumber) mode=\(observedMode.map { String($0, radix: 8) } ?? "unavailable")"
    }
}

enum SaveWorkflowService {
    static let maximumKeepBothAttempts = 10_000

    /// Call on ImageExportService.queue. The artifact must already be flattened,
    /// redacted and encoded; there is deliberately no history/capture-store access.
    /// A nil override uses the saved .ask/.keepBoth preference. No option replaces.
    static func publish(_ artifact: ImageExportArtifact, settings: SaveWorkflowSettings,
                        context: SaveWorkflowContext, collisionBehavior: SaveWorkflowCollisionBehavior? = nil,
                        cancellation: ImageExportCancellation = ImageExportCancellation(),
                        beforeCommit: (() throws -> Void)? = nil,
                        testHooks: SaveWorkflowTestHooks? = nil) throws -> SaveWorkflowResult {
        try cancellation.check(); try settings.validate(); try artifact.options.validate()
        guard artifact.width == context.width, artifact.height == context.height,
              artifact.width > 0, artifact.height > 0,
              artifact.width <= ImageExportLimits.standard.maximumSourcePixels / artifact.height,
              artifact.pageCount > 0, artifact.pageCount <= ImageExportLimits.standard.maximumPages,
              !artifact.data.isEmpty, artifact.data.count <= ImageExportLimits.standard.maximumEncodedBytes else {
            throw SaveWorkflowError.invalidArtifact
        }
        let destination = try settings.preview(context: context, filenameExtension: artifact.options.format.filenameExtension)
        return try publish(artifact, destination: destination, collisionBehavior: collisionBehavior ?? settings.collisionBehavior,
                           cancellation: cancellation, beforeCommit: beforeCommit, testHooks: testHooks)
    }

    /// Validate the explicitly chosen folder before storing it. Never creates a folder.
    static func validateBaseDirectory(_ url: URL,
                                      diagnostic: ((SaveWorkflowDirectoryDiagnostic) -> Void)? = nil) throws {
        let directories = try SaveWorkflowDirectoryChain(base: url, children: [], cancellation: ImageExportCancellation(), diagnostic: diagnostic)
        directories.close()
    }

    /// Call only for an explicit folder-picker approval. This resolves the folder
    /// the user selected once, then validates and returns its physical spelling.
    /// Never call this while loading preferences or starting a later saved-path job:
    /// subsequent saves must reject symlink substitution rather than silently follow it.
    static func resolveApprovedDirectory(_ selected: URL,
                                         diagnostic: ((SaveWorkflowDirectoryDiagnostic) -> Void)? = nil) throws -> URL {
        try SaveWorkflowSettings.validateBaseURL(selected)
        let pointer = selected.withUnsafeFileSystemRepresentation { path in
            path.flatMap { Darwin.realpath($0, nil) }
        }
        guard let pointer else {
            let failure = errno
            diagnostic?(SaveWorkflowDirectoryDiagnostic(operation: "realpath", componentIndex: 0,
                component: String(selected.lastPathComponent.prefix(80)), errorNumber: failure, observedMode: nil))
            throw SaveWorkflowError.unsafeDirectory
        }
        defer { Darwin.free(pointer) }
        let physical = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        try validateBaseDirectory(physical, diagnostic: diagnostic)
        return physical
    }

    /// Exact picker-selected name. NSSavePanel's own Replace response never authorizes
    /// replacement here: publication is still exclusive and collisions return to the UI.
    static func publish(_ artifact: ImageExportArtifact, to url: URL,
                        collisionBehavior: SaveWorkflowCollisionBehavior = .ask,
                        cancellation: ImageExportCancellation = ImageExportCancellation(),
                        beforeCommit: (() throws -> Void)? = nil,
                        testHooks: SaveWorkflowTestHooks? = nil) throws -> SaveWorkflowResult {
        guard url.isFileURL, url.query == nil, url.fragment == nil else { throw ImageExportError.invalidDestination }
        let extensionValue = url.pathExtension.lowercased()
        let validExtension = extensionValue == artifact.options.format.filenameExtension
            || (artifact.options.format == .jpeg && extensionValue == "jpeg")
            || (artifact.options.format == .tiff && extensionValue == "tif")
        guard validExtension else { throw ImageExportError.invalidDestination }
        let destination = SaveWorkflowDestination(baseURL: url.deletingLastPathComponent(), relativeDirectories: [], filename: url.lastPathComponent)
        return try publish(artifact, destination: destination, collisionBehavior: collisionBehavior,
                           cancellation: cancellation, beforeCommit: beforeCommit, testHooks: testHooks)
    }

    private static func publish(_ artifact: ImageExportArtifact, destination: SaveWorkflowDestination,
                                collisionBehavior behavior: SaveWorkflowCollisionBehavior,
                                cancellation: ImageExportCancellation,
                                beforeCommit: (() throws -> Void)?,
                                testHooks: SaveWorkflowTestHooks?) throws -> SaveWorkflowResult {
        try cancellation.check(); try artifact.options.validate()
        guard artifact.width > 0, artifact.height > 0,
              artifact.width <= ImageExportLimits.standard.maximumSourcePixels / artifact.height,
              artifact.pageCount > 0, artifact.pageCount <= ImageExportLimits.standard.maximumPages,
              !artifact.data.isEmpty, artifact.data.count <= ImageExportLimits.standard.maximumEncodedBytes else {
            throw SaveWorkflowError.invalidArtifact
        }
        guard !destination.filename.isEmpty, destination.filename != ".", destination.filename != "..",
              !destination.filename.contains("/"), !destination.filename.contains("\u{0}"),
              destination.filename.utf8.count <= 255 else { throw ImageExportError.invalidDestination }
        let directories = try SaveWorkflowDirectoryChain(base: destination.baseURL, children: destination.relativeDirectories,
                                                         cancellation: cancellation, diagnostic: testHooks?.directoryFailure)
        defer { directories.close() }
        try cancellation.check()
        // A private sibling directory protects the staging namespace from accidental
        // cleanup/collision by another save. Only inode-matching owned entries are removed.
        let stage = try SaveWorkflowStage(parent: directories.lastDescriptor)
        defer { stage.cleanup() }
        try stage.write(artifact.data, cancellation: cancellation)
        try beforeCommit?()
        let rawStem = (destination.filename as NSString).deletingPathExtension
        var original = ""
        for character in rawStem {
            guard original.utf8.count + String(character).utf8.count <= 225 else { break }; original.append(character)
        }
        let ext = (destination.filename as NSString).pathExtension
        // The potentially large read stays outside the cancellation fence. Close/Cancel
        // can win while verification runs instead of blocking the main thread on disk I/O.
        try stage.validate(expectedData: artifact.data, cancellation: cancellation, beforeChunk: testHooks?.beforeReadbackChunk)
        var savedURL: URL?
        for attempt in 0..<maximumKeepBothAttempts {
            testHooks?.beforeCollisionAttempt?(attempt)
            try cancellation.check()
            let name = attempt == 0 ? destination.filename : "\(original) (\(attempt)).\(ext)"
            let candidate = destination.url.deletingLastPathComponent().appendingPathComponent(name)
            // Preserve the original source path even when it was removed after
            // snapshotting. Existing hard links are inherently protected by linkat.
            if candidate.standardizedFileURL.path == artifact.sourceURL?.standardizedFileURL.path {
                if behavior == .keepBoth { continue }; throw SaveWorkflowError.collision(candidate)
            }
            var occupied = false
            // Each attempt has its own metadata-only fence: at most 72 ancestor
            // checks, 2 stage identity checks and one exclusive link. No bulk
            // reads, keep-both search or fsync holds the UI cancellation lock.
            try cancellation.commit {
                try directories.validate(); try stage.validateIdentity()
                if Darwin.linkat(stage.directoryDescriptor, "payload", directories.lastDescriptor, name, 0) == 0 {
                    savedURL = candidate; return
                }
                if errno == EEXIST { occupied = true; return }
                throw SaveWorkflowError.writeFailed
            }
            if savedURL != nil { break }
            if occupied && behavior == .ask { throw SaveWorkflowError.collision(candidate) }
        }
        guard let savedURL else { throw SaveWorkflowError.exhaustedNames }
        // Publication won the fence. Cancellation/fsync failure cannot undo it.
        _ = Darwin.fsync(directories.lastDescriptor)
        return SaveWorkflowResult(savedURL: savedURL, byteCount: artifact.byteCount,
                                  copyData: artifact.data, copyType: artifact.options.format.contentType.identifier)
    }

    /// Called only after publish succeeded. The injected copier is for native tests.
    /// Closing a save UI after commit preserves the completed file and skips copying.
    @MainActor static func copySaved(_ saved: SaveWorkflowResult,
                                    cancellation: ImageExportCancellation = ImageExportCancellation(),
                                    copier: ((Data, String) -> Bool)? = nil) -> SaveWorkflowResult {
        var result = saved
        guard !cancellation.isCancelled else { result.clipboardOutcome = .cancelledAfterSave; return result }
        let success: Bool
        if let copier { success = copier(saved.copyData, saved.copyType) }
        else {
            NSPasteboard.general.clearContents()
            success = NSPasteboard.general.setData(saved.copyData, forType: NSPasteboard.PasteboardType(saved.copyType))
        }
        result.clipboardOutcome = success ? .copied : .failed
        return result
    }
}

private struct SaveWorkflowFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
}

/// Every path component is opened with no-follow, and all later file operations
/// are relative to retained descriptors. A replaced ancestor is detected before
/// publication instead of resolving a new URL into an unapproved directory.
private final class SaveWorkflowDirectoryChain {
    private struct Entry {
        let descriptor: Int32
        let parent: Int32
        let name: String
        let identity: SaveWorkflowFileIdentity
    }
    private var entries: [Entry] = []
    private let diagnostic: ((SaveWorkflowDirectoryDiagnostic) -> Void)?
    var lastDescriptor: Int32 { entries.last!.descriptor }
    init(base: URL, children: [String], cancellation: ImageExportCancellation,
         diagnostic: ((SaveWorkflowDirectoryDiagnostic) -> Void)? = nil) throws {
        self.diagnostic = diagnostic
        try SaveWorkflowSettings.validateBaseURL(base)
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            let failure = errno; report("open", parent: -1, name: "/", error: failure)
            throw SaveWorkflowError.unsafeDirectory
        }
        var rootStat = stat()
        guard Darwin.fstat(root, &rootStat) == 0 else {
            let failure = errno; report("fstat", parent: -1, name: "/", error: failure)
            Darwin.close(root); throw SaveWorkflowError.unsafeDirectory
        }
        entries.append(Entry(descriptor: root, parent: -1, name: "/", identity: SaveWorkflowFileIdentity(rootStat)))
        do {
            for component in base.pathComponents where component != "/" {
                try cancellation.check(); try append(component, create: false)
            }
            for component in children {
                try cancellation.check(); try validate(); try append(component, create: true)
            }
            try validate()
        } catch { close(); throw error }
    }
    private func append(_ name: String, create: Bool) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\u{0}") else {
            report("validate-component", parent: -1, name: name, error: EINVAL)
            throw SaveWorkflowError.unsafeDirectory
        }
        let parent = lastDescriptor
        if create && Darwin.mkdirat(parent, name, mode_t(0o700)) != 0 && errno != EEXIST {
            let failure = errno; report("mkdirat", parent: parent, name: name, error: failure)
            throw SaveWorkflowError.writeFailed
        }
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let failure = errno; report("openat", parent: parent, name: name, error: failure)
            throw SaveWorkflowError.unsafeDirectory
        }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            let failure = errno; report("fstat", parent: parent, name: name, error: failure)
            Darwin.close(descriptor); throw SaveWorkflowError.unsafeDirectory
        }
        guard (value.st_mode & S_IFMT) == S_IFDIR else {
            report("validate-directory", parent: parent, name: name, error: ENOTDIR)
            Darwin.close(descriptor); throw SaveWorkflowError.unsafeDirectory
        }
        entries.append(Entry(descriptor: descriptor, parent: parent, name: name, identity: SaveWorkflowFileIdentity(value)))
    }
    private func report(_ operation: String, parent: Int32, name: String, error: Int32) {
        guard let diagnostic else { return }
        var observed = stat()
        let mode = parent >= 0 && Darwin.fstatat(parent, name, &observed, AT_SYMLINK_NOFOLLOW) == 0
            ? UInt32(observed.st_mode) : nil
        // Component-only, bounded context is sufficient to distinguish a system
        // alias from permission failure. No full selected-directory path is emitted.
        diagnostic(SaveWorkflowDirectoryDiagnostic(operation: operation, componentIndex: entries.count,
            component: String(name.prefix(80)), errorNumber: error, observedMode: mode))
    }
    func validate() throws {
        for entry in entries where entry.parent >= 0 {
            var value = stat()
            guard Darwin.fstatat(entry.parent, entry.name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  (value.st_mode & S_IFMT) == S_IFDIR, SaveWorkflowFileIdentity(value) == entry.identity else {
                throw SaveWorkflowError.changedDirectory
            }
        }
    }
    func close() { for entry in entries.reversed() { Darwin.close(entry.descriptor) }; entries.removeAll() }
    deinit { close() }
}

private struct SaveWorkflowContentIdentity: Equatable {
    let size: off_t
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    init(_ value: stat) {
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

private final class SaveWorkflowStage {
    let directoryDescriptor: Int32
    private let parent: Int32
    private let name: String
    private let directoryIdentity: SaveWorkflowFileIdentity
    private let descriptor: Int32
    private let identity: SaveWorkflowFileIdentity
    private var cleaned = false
    private var verifiedContents: SaveWorkflowContentIdentity?
    init(parent: Int32) throws {
        self.parent = parent; name = ".picshot-save-\(UUID().uuidString)"
        guard Darwin.mkdirat(parent, name, mode_t(0o700)) == 0 else { throw SaveWorkflowError.writeFailed }
        let directory = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SaveWorkflowError.writeFailed }
        var directoryStat = stat()
        guard Darwin.fstat(directory, &directoryStat) == 0 else { Darwin.close(directory); throw SaveWorkflowError.writeFailed }
        directoryDescriptor = directory; directoryIdentity = SaveWorkflowFileIdentity(directoryStat)
        let file = Darwin.openat(directory, "payload", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else {
            Darwin.close(directory); throw SaveWorkflowError.writeFailed
        }
        var value = stat()
        guard Darwin.fstat(file, &value) == 0 else {
            Darwin.close(file); Darwin.close(directory); throw SaveWorkflowError.writeFailed
        }
        descriptor = file; identity = SaveWorkflowFileIdentity(value)
    }
    func write(_ data: Data, cancellation: ImageExportCancellation) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw SaveWorkflowError.invalidArtifact }
            var offset = 0
            while offset < bytes.count {
                try cancellation.check()
                let count = Darwin.write(descriptor, base.advanced(by: offset), min(1_048_576, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SaveWorkflowError.writeFailed }; offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw SaveWorkflowError.writeFailed }
    }
    func validateIdentity() throws {
        var value = stat()
        guard Darwin.fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
              (value.st_mode & S_IFMT) == S_IFDIR, SaveWorkflowFileIdentity(value) == directoryIdentity,
              Darwin.fstatat(directoryDescriptor, "payload", &value, AT_SYMLINK_NOFOLLOW) == 0,
              (value.st_mode & S_IFMT) == S_IFREG, SaveWorkflowFileIdentity(value) == identity else {
            throw SaveWorkflowError.changedDirectory
        }
        if let verifiedContents, SaveWorkflowContentIdentity(value) != verifiedContents {
            throw SaveWorkflowError.changedDirectory
        }
    }
    func validate(expectedData: Data, cancellation: ImageExportCancellation, beforeChunk: ((Int) -> Void)?) throws {
        try cancellation.check(); try validateIdentity()
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0, value.st_size == expectedData.count else {
            throw SaveWorkflowError.changedDirectory
        }
        let beforeRead = SaveWorkflowContentIdentity(value)
        // Re-read our actual staged bytes, bounded to a 1 MiB scratch buffer.
        // This also catches an interrupted/truncated write or same-inode tampering.
        var buffer = [UInt8](repeating: 0, count: min(expectedData.count, 1_048_576))
        try expectedData.withUnsafeBytes { expected in
            var offset = 0
            while offset < expected.count {
                beforeChunk?(offset)
                try cancellation.check()
                let requested = min(buffer.count, expected.count - offset)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.pread(descriptor, bytes.baseAddress!, requested, off_t(offset))
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SaveWorkflowError.writeFailed }
                let equal = buffer.withUnsafeBytes { bytes in
                    memcmp(bytes.baseAddress!, expected.baseAddress!.advanced(by: offset), count) == 0
                }
                guard equal else { throw SaveWorkflowError.changedDirectory }; offset += count
            }
        }
        guard Darwin.fstat(descriptor, &value) == 0, SaveWorkflowContentIdentity(value) == beforeRead else {
            throw SaveWorkflowError.changedDirectory
        }
        verifiedContents = beforeRead
        try cancellation.check(); try validateIdentity()
    }
    func cleanup() {
        guard !cleaned else { return }; cleaned = true
        var value = stat()
        if Darwin.fstatat(directoryDescriptor, "payload", &value, AT_SYMLINK_NOFOLLOW) == 0,
           SaveWorkflowFileIdentity(value) == identity { _ = Darwin.unlinkat(directoryDescriptor, "payload", 0) }
        Darwin.close(descriptor); Darwin.close(directoryDescriptor)
        if Darwin.fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
           (value.st_mode & S_IFMT) == S_IFDIR, SaveWorkflowFileIdentity(value) == directoryIdentity {
            _ = Darwin.unlinkat(parent, name, AT_REMOVEDIR)
        }
    }
    deinit { cleanup() }
}

/// The physical destination is bound when the user approves the chooser, before
/// renderer/queue delays. Descriptors survive those delays; publication refuses any
/// replaced physical ancestor rather than resolving a newer symlink target.
final class RawPinArtifactDestination: @unchecked Sendable {
    let url: URL
    private let directories: SaveWorkflowDirectoryChain
    init(_ selected: URL) throws {
        let name = selected.lastPathComponent
        guard selected.isFileURL, selected.query == nil, selected.fragment == nil,
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\u{0}"), name.utf8.count <= 255 else {
            throw ImageExportError.invalidDestination
        }
        let approved = try SaveWorkflowService.resolveApprovedDirectory(selected.deletingLastPathComponent())
        directories = try SaveWorkflowDirectoryChain(base: approved, children: [], cancellation: ImageExportCancellation())
        url = approved.appendingPathComponent(name)
    }
    fileprivate func publish(_ data: Data, cancellation: ImageExportCancellation,
                             beforeCommit: (() throws -> Void)?) throws {
        try cancellation.check()
        guard !data.isEmpty, data.count <= ImageExportLimits.standard.maximumEncodedBytes else {
            throw ImageExportError.invalidDestination
        }
        let name = url.lastPathComponent
        try directories.validate()
        let stage = try SaveWorkflowStage(parent: directories.lastDescriptor)
        defer { stage.cleanup() }
        try stage.write(data, cancellation: cancellation)
        try beforeCommit?()
        try stage.validate(expectedData: data, cancellation: cancellation, beforeChunk: nil)
        try cancellation.commit {
            try directories.validate(); try stage.validateIdentity()
            guard Darwin.linkat(stage.directoryDescriptor, "payload", directories.lastDescriptor, name, 0) == 0 else {
                if errno == EEXIST { throw ImageExportError.destinationExists }
                throw SaveWorkflowError.writeFailed
            }
        }
        _ = Darwin.fsync(directories.lastDescriptor)
    }
}

/// Scoped publisher for validated pin artifacts; no fabricated raster/PDF metadata.
enum RawPinArtifactPublication {
    static func publish(_ data: Data, to destination: RawPinArtifactDestination,
                        cancellation: ImageExportCancellation,
                        beforeCommit: (() throws -> Void)? = nil) throws {
        try destination.publish(data, cancellation: cancellation, beforeCommit: beforeCommit)
    }
}
