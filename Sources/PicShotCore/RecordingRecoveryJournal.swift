import Foundation

public enum RecordingRecoveryError: Error, LocalizedError, Equatable {
    case unsafePath, invalidJournal, sourceChanged, activeSession, limitExceeded, noRecoverableMedia
    case io(String)
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "录屏路径不安全，未修改任何文件。"
        case .invalidJournal: return "恢复记录已损坏或版本不受支持，原始文件已保留。"
        case .sourceChanged: return "录屏文件已发生变化，原始文件已保留。"
        case .activeSession: return "这段录屏仍由 PicShot 使用中。"
        case .limitExceeded: return "这段录屏超出了恢复资源上限，原始文件已保留。"
        case .noRecoverableMedia: return "尚无完整可恢复的录屏片段，原始录屏已保留。"
        case .io(let message): return "录屏恢复失败：\(message)"
        }
    }
}

public struct RecordingRecoveryIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

public enum RecordingRecoveryPhase: String, Codable, Sendable {
    case capturing, finalized, publishing, published, recovered, discarded, dismissed
    public var isPending: Bool { self == .capturing || self == .finalized || self == .publishing || self == .published }
}

/// A journal is a locator, never authority to read arbitrary paths or delete media.
public struct RecordingRecoveryJournal: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maximumBytes: Int64 = 4_294_967_296
    public static let maximumJournalBytes = 16_384
    public static let filename = "recovery.json"
    public static let mediaFilenames = ["recording.mp4", "recording-mixed.mp4", "recording-preserved.mp4"]
    public var schemaVersion = RecordingRecoveryJournal.version
    public let id: UUID
    public let createdAt: Date
    public var phase: RecordingRecoveryPhase
    public var mediaFilename: String
    public var sourceIdentity: RecordingRecoveryIdentity
    public var publishedFilename: String?
    public var recoveredFilename: String?
    public let byteLimit: Int64
    public let durationLimit: Double

    public init(id: UUID, sourceIdentity: RecordingRecoveryIdentity, mediaFilename: String = "recording.mp4",
                byteLimit: Int64 = Self.maximumBytes, durationLimit: Double = 3_600, createdAt: Date = Date()) {
        self.id = id; self.sourceIdentity = sourceIdentity; self.mediaFilename = mediaFilename
        self.byteLimit = byteLimit; self.durationLimit = durationLimit; self.createdAt = createdAt
        phase = .capturing
    }
    public var directoryName: String { ".recording-" + id.uuidString }
    public func validated() throws -> Self {
        guard schemaVersion == Self.version, createdAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970 >= 0, createdAt.timeIntervalSince1970 <= 32_503_680_000,
              sourceIdentity.inode > 0, (1...Self.maximumBytes).contains(byteLimit),
              durationLimit.isFinite, (0.01...3_600).contains(durationLimit),
              Self.mediaFilenames.contains(mediaFilename),
              publishedFilename.map(Self.isPublishedFilename) ?? true,
              recoveredFilename.map(Self.isRecoveredFilename) ?? true,
              ![.publishing, .published].contains(phase) || publishedFilename != nil,
              phase != .recovered || recoveredFilename != nil else { throw RecordingRecoveryError.invalidJournal }
        return self
    }
    public static func id(directoryName: String) -> UUID? {
        guard directoryName.hasPrefix(".recording-"), let id = UUID(uuidString: String(directoryName.dropFirst(11))),
              directoryName == ".recording-" + id.uuidString else { return nil }
        return id
    }
    public static func isPublishedFilename(_ name: String) -> Bool {
        guard name.hasPrefix("PicShot-"), name.hasSuffix(".mp4"), name.utf8.count <= 110 else { return false }
        return name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }
    }
    public static func isRecoveredFilename(_ name: String) -> Bool {
        guard name.hasPrefix("PicShot-Recovered-"), name.hasSuffix(".mp4") else { return false }
        let middle = String(name.dropFirst(18).dropLast(4))
        return UUID(uuidString: middle)?.uuidString == middle
    }
}

public struct RecordingRecoveryPrefix: Equatable, Sendable {
    public let byteCount: Int64
    public let completeFragments: Int
    public let ignoredTailBytes: Int64
}

/// Constant-memory top-level ISO-BMFF framing check. It does not claim that an
/// atom's samples decode; the native engine must decode-check and remux a COPY.
/// Offsets remain unchanged so absolute chunk/sample offsets stay valid.
public enum RecordingRecoveryMP4 {
    public static let maximumAtoms = 16_384
    public static func completePrefix(fileSize: Int64, finalized: Bool = false,
                                      read: (Int64, Int) throws -> Data) throws -> RecordingRecoveryPrefix {
        guard fileSize > 0, fileSize <= RecordingRecoveryJournal.maximumBytes else { throw RecordingRecoveryError.limitExceeded }
        var offset: Int64 = 0, safeEnd: Int64 = 0
        var hasFileType = false, hasMovie = false, hasMedia = false, pendingFragment = false
        var fragments = 0, atoms = 0
        while offset < fileSize {
            atoms += 1
            guard atoms <= maximumAtoms else { throw RecordingRecoveryError.limitExceeded }
            guard fileSize - offset >= 8 else { break }
            let header = try read(offset, 8)
            guard header.count == 8 else { break }
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            var size = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var headerSize: UInt64 = 8
            if size == 1 {
                guard fileSize - offset >= 16 else { break }
                let extended = try read(offset + 8, 8)
                guard extended.count == 8 else { break }
                size = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; headerSize = 16
            } else if size == 0 {
                // An open-ended mdat is not a committed fragment after a crash.
                guard finalized else { break }
                size = UInt64(fileSize - offset)
            }
            guard size >= headerSize else { throw RecordingRecoveryError.noRecoverableMedia }
            guard size <= UInt64(fileSize - offset) else { break }
            let end = offset + Int64(size)
            switch type {
            case "ftyp":
                guard !hasFileType, offset == 0, size <= 4_096 else { throw RecordingRecoveryError.noRecoverableMedia }
                hasFileType = true
            case "moov":
                guard hasFileType, !hasMovie, size <= 16_777_216 else { throw RecordingRecoveryError.noRecoverableMedia }
                hasMovie = true
                if hasMedia { safeEnd = end; fragments += 1 }
            case "moof":
                guard hasMovie, !pendingFragment, size <= 4_194_304 else { throw RecordingRecoveryError.noRecoverableMedia }
                pendingFragment = true
            case "mdat":
                guard hasFileType else { throw RecordingRecoveryError.noRecoverableMedia }
                hasMedia = true
                if hasMovie {
                    // The first initial mdat may follow a non-fragmented moov.
                    guard pendingFragment || fragments == 0 else { throw RecordingRecoveryError.noRecoverableMedia }
                    safeEnd = end; fragments += 1; pendingFragment = false
                }
            case "free", "skip", "wide", "uuid", "sidx", "mfra", "styp", "prft": break
            default: throw RecordingRecoveryError.noRecoverableMedia
            }
            offset = end
        }
        guard hasFileType, hasMovie, safeEnd > 0, fragments > 0 else { throw RecordingRecoveryError.noRecoverableMedia }
        if finalized, offset == fileSize, !pendingFragment { safeEnd = fileSize }
        return RecordingRecoveryPrefix(byteCount: safeEnd, completeFragments: fragments, ignoredTailBytes: fileSize - safeEnd)
    }
}
