import Foundation
import Darwin

/// Only uniquely named, owned, private directories with our tiny marker may be
/// eligible for the stale-job sweep. Ordinary user directories never qualify.
/// Live parent/helper PIDs prevent sweeping an active job. The live parent has
/// a separate cleanup path for its own just-created job after helper exit.
public enum SmartEraseTemporaryJob {
    private struct Marker: Codable {
        let format: String
        let parent: Int32
        var helper: Int32
    }
    private static let markerName = ".picshot-erase-job.json"
    private static let format = "PicShotEraseJob-v1"

    public static func create(in root: URL) throws -> URL {
        let root = root.resolvingSymlinksInPath()
        sweep(in: root)
        let directory = root.appendingPathComponent("picshot-erase-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let data = try JSONEncoder().encode(Marker(format: format, parent: getpid(), helper: 0))
            guard fm.createFile(atPath: directory.appendingPathComponent(markerName).path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw SmartEraseError.invalidInput }
            return directory
        } catch { try? fm.removeItem(at: directory); throw error }
    }

    public static func claim(_ directory: URL, parent: Int32) throws {
        var marker = try read(directory)
        guard parent > 1, marker.parent == parent, marker.helper == 0 else { throw SmartEraseError.invalidInput }
        marker.helper = getpid()
        try JSONEncoder().encode(marker).write(to: directory.appendingPathComponent(markerName), options: .atomic)
    }

    public static func remove(_ directory: URL) {
        guard (try? read(directory)) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Parent-only cleanup for a directory it just created, after the helper
    /// has exited (or before it was started). Does not depend on an intact
    /// child-written marker, so a partial marker write cannot strand inputs.
    public static func removeOwned(_ directory: URL) {
        guard (try? validateDirectory(directory)) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    public static func sweep(in root: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for directory in children where directory.lastPathComponent.hasPrefix("picshot-erase-") {
            guard let marker = try? read(directory),
                  let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate, now.timeIntervalSince(date) > 3_600,
                  !isAlive(marker.parent), !isAlive(marker.helper) else { continue }
            try? fm.removeItem(at: directory)
        }
    }

    public static func parentIsAlive(_ originalParent: Int32) -> Bool {
        originalParent > 1 && getppid() == originalParent && isAlive(originalParent)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private static func validateDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        let name = directory.lastPathComponent
        guard name.hasPrefix("picshot-erase-"), UUID(uuidString: String(name.dropFirst("picshot-erase-".count))) != nil,
              directory.standardizedFileURL == directory.resolvingSymlinksInPath() else { throw SmartEraseError.invalidInput }
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw SmartEraseError.invalidInput }
    }

    private static func read(_ directory: URL) throws -> Marker {
        try validateDirectory(directory)
        let markerURL = directory.appendingPathComponent(markerName)
        let values = try markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 256 else { throw SmartEraseError.invalidInput }
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        guard marker.format == format, marker.parent > 1, marker.helper >= 0 else { throw SmartEraseError.invalidInput }
        return marker
    }
}
