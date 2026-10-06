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

