import AppKit
import CoreFoundation
import Darwin
import Foundation

/// Fixture-only observation. Never enabled by the installed application's normal path.
/// Every wait intentionally blocks the main actor; this perturbation is part of the evidence.
@MainActor
final class LiveScrollAllocationDiagnostic {
    static let protocolName = "picshot-live-scroll-allocation-diagnostic-v1"
    static let directoryEnvironment = "PICSHOT_LIVE_SCROLL_ALLOCATION_DIAGNOSTIC"
    static let tokenEnvironment = "PICSHOT_LIVE_SCROLL_ALLOCATION_DIAGNOSTIC_TOKEN"
    static let mallocEnvironmentKeys = ["MallocStackLogging", "MallocStackLoggingNoCompact", "MallocStackLoggingDirectory"]
    static let checkpoints: [(Int, String)] = [
        (4, "released-plus-1000ms"),
        (5, "pre-finish-pending-edge"),
        (5, "released-plus-1000ms"),
        (8, "released-plus-1000ms"),
        (9, "finish-image-alive-before-png"),
        (9, "png-finalized-image-alive"),
        (9, "released-plus-1000ms"),
        (10, "released-plus-1000ms"),
    ]
    static let perturbation = "diagnostic-only owned calibration malloc/free, scalar allocator queries, JSON/file I/O, full malloc stack logging, external process inspection, and bounded main-actor blocking; not an uninstrumented memory qualification"

    private let directory: URL
    private let directoryFD: Int32
    private let token: String
    private let identity: [String: Any]
    private let mallocEnvironment: [String: Any]
    private let fixtureDeadline: Double
    private var sequence = 0
    private var checkpointIndex = 0
    private var acknowledgedReplies = Set<String>()
    private var terminalFailure: NSError?
    private var events: [[String: Any]] = []
    private var calibrationComplete = false

    static func makeIfRequested(environment: [String: String], mode: String, pngWriter: String,
                                executable: URL, executableSHA256: String, deadline: Double) throws -> LiveScrollAllocationDiagnostic? {
        guard let path = environment[directoryEnvironment] else {
            guard environment[tokenEnvironment] == nil else { throw failure("diagnostic-token-without-directory") }
            return nil
        }
        guard mode == "measure", pngWriter == "foundation",
              let token = environment[tokenEnvironment], UUID(uuidString: token) != nil,
              environment["MallocStackLogging"] == "full",
              environment["MallocStackLoggingNoCompact"] == "1",
              let stackDirectory = environment["MallocStackLoggingDirectory"], stackDirectory.hasPrefix("/") else {
            throw failure("diagnostic-requires-measure-foundation-token-and-exact-full-malloc-settings")
        }
        return try LiveScrollAllocationDiagnostic(directory: path, token: token, environment: environment,
            executable: executable, executableSHA256: executableSHA256, deadline: deadline)
    }

    private init(directory path: String, token: String, environment: [String: String],
                 executable: URL, executableSHA256: String, deadline: Double) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Self.failure("diagnostic-directory-not-absolute") }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.resolvingSymlinksInPath().path == url.path else { throw Self.failure("diagnostic-directory-not-canonical") }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("diagnostic-directory-open-failed") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
            close(fd); throw Self.failure("diagnostic-directory-must-be-private-and-owned")
        }
        guard let launchDate = NSRunningApplication.current.launchDate else {
            close(fd); throw Self.failure("diagnostic-process-start-unavailable")
        }
        let nowEpoch = Date().timeIntervalSince1970
        let nowUptime = ProcessInfo.processInfo.systemUptime
        self.directory = url; self.directoryFD = fd; self.token = token; self.fixtureDeadline = deadline
        self.identity = ["pid": Int(getpid()), "processStartEpochSeconds": launchDate.timeIntervalSince1970,
            "processStartUptimeSeconds": nowUptime - (nowEpoch - launchDate.timeIntervalSince1970),
            "executablePath": executable.resolvingSymlinksInPath().path, "executableSHA256": executableSHA256]
        self.mallocEnvironment = Dictionary(uniqueKeysWithValues: Self.mallocEnvironmentKeys.map { key in
            (key, environment[key].map { $0 as Any } ?? NSNull())
        })
        // A run owns a fresh directory. Never consume acknowledgements from another run.
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard !names.contains(where: { $0.hasPrefix("request-") || $0.hasPrefix("reply-") }) else {
            throw Self.failure("diagnostic-stale-protocol-files")
        }
    }

    deinit { close(directoryFD) }

    var report: [String: Any] {
        ["enabled": true, "protocol": Self.protocolName, "runToken": token, "identity": identity,
         "identityUptimeOrigin": "NSRunningApplication launchDate converted once using current epoch and system uptime; external observer must verify kernel process birth and launcher receipt",
         "receivedMallocEnvironment": mallocEnvironment,
         "requestedStackLoggingMode": "full", "compactStackLoggingAcceptedAsFull": false,
         "perturbationLabel": Self.perturbation, "mainActorBlockedDuringHandshake": true,
         "maximumCalibrationHoldSeconds": 30, "maximumCheckpointHoldSeconds": 10,
         "maximumCheckpointCount": 8, "maximumTotalRequestedHoldSeconds": 110,
         "calibrationComplete": calibrationComplete, "completedCheckpointCount": checkpointIndex,
         "requestCount": sequence, "events": events,
         "failed": terminalFailure != nil,
         "errorCode": terminalFailure?.localizedDescription ?? ""]
    }

    /// No image or product ownership is introduced. These are scalar allocator totals.
    static func allocatorScalarsIfEnabled() -> [String: Any]? {
        guard ProcessInfo.processInfo.environment[directoryEnvironment] != nil else { return nil }
        var value = malloc_statistics_t()
        malloc_zone_statistics(nil, &value)
        return ["scope": "malloc_zone_statistics(NULL): all malloc zones; allocator bookkeeping, not process VM or exact semantic live ownership",
            "blocksInUse": UInt64(value.blocks_in_use), "sizeInUseBytes": UInt64(value.size_in_use),
            "maxSizeInUseBytes": UInt64(value.max_size_in_use), "sizeAllocatedBytes": UInt64(value.size_allocated),
            "uptimeSeconds": ProcessInfo.processInfo.systemUptime]
    }

    func calibrateBeforeFirstCycle() throws {
        guard sequence == 0, !calibrationComplete else { throw Self.failure("diagnostic-calibration-repeated") }
        let byteCount = 65_537
        guard let block = malloc(byteCount) else { throw Self.failure("diagnostic-calibration-allocation-failed") }
        var ownsBlock = true
        defer { if ownsBlock { free(block) } }
        memset(block, 0xA5, byteCount)
        let calibration: [String: Any] = ["address": "0x" + String(UInt(bitPattern: block), radix: 16),
            "requestedBytes": byteCount, "usableBytes": malloc_size(block)]
        try exchange(kind: "calibration-live", ordinal: 0, phase: "calibration-owned-allocation-live",
                     holdSeconds: 15, calibration: calibration)
        free(block); ownsBlock = false
        try exchange(kind: "calibration-released", ordinal: 0, phase: "calibration-owned-allocation-released",
                     holdSeconds: 15, calibration: calibration)
        calibrationComplete = true
    }

    func observeCheckpoint(ordinal: Int, phase: String) throws {
        guard Self.checkpoints.contains(where: { $0.0 == ordinal && $0.1 == phase }) else { return }
        if let terminalFailure { throw terminalFailure }
        guard calibrationComplete, checkpointIndex < Self.checkpoints.count,
              Self.checkpoints[checkpointIndex].0 == ordinal, Self.checkpoints[checkpointIndex].1 == phase else {
            throw Self.failure("diagnostic-checkpoint-order-invalid")
        }
        try exchange(kind: "checkpoint", ordinal: ordinal, phase: phase, holdSeconds: 10, calibration: nil)
        checkpointIndex += 1
    }

    func requireComplete() throws {
        if let terminalFailure { throw terminalFailure }
        guard calibrationComplete, checkpointIndex == Self.checkpoints.count, sequence == 10 else {
            throw Self.failure("diagnostic-checkpoints-incomplete")
        }
        try rejectUnexpectedReplies(current: nil)
    }

    private func exchange(kind: String, ordinal: Int, phase: String, holdSeconds: Double,
                          calibration: [String: Any]?) throws {
        if let terminalFailure { throw terminalFailure }
        let began = ProcessInfo.processInfo.systemUptime
        // No new app/session deadline. All overhead consumes the unchanged fixture budget.
        guard began + holdSeconds < fixtureDeadline else { throw Self.failure("diagnostic-insufficient-existing-budget") }
        sequence += 1
        let requestID = UUID().uuidString.lowercased()
        let requestName = String(format: "request-%04d.json", sequence)
        let replyName = String(format: "reply-%04d.json", sequence)
        let replyDeadline = min(began + holdSeconds, fixtureDeadline)
        var event: [String: Any] = ["sequence": sequence, "kind": kind, "ordinal": ordinal, "phase": phase,
            "publishedUptimeSeconds": began, "replyDeadlineUptimeSeconds": replyDeadline,
            "maximumHoldSeconds": holdSeconds, "mainActorBlocked": true]
        do {
            try rejectUnexpectedReplies(current: nil)
            let request: [String: Any] = ["schemaVersion": 1, "protocol": Self.protocolName,
                "runToken": token, "sequence": sequence, "requestID": requestID, "kind": kind,
                "cycleOrdinal": ordinal, "phase": phase, "identity": identity,
                "publishedUptimeSeconds": began, "replyDeadlineUptimeSeconds": replyDeadline,
                "maximumHoldSeconds": holdSeconds, "fixtureDeadlineUptimeSeconds": fixtureDeadline,
                "mainActorBlocked": true, "perturbationLabel": Self.perturbation,
                "mallocEnvironment": mallocEnvironment, "calibration": calibration.map { $0 as Any } ?? NSNull()]
            try publish(request, name: requestName)
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                guard now < replyDeadline else { throw Self.failure("diagnostic-reply-timeout") }
                try rejectUnexpectedReplies(current: replyName)
                if let reply = try readReplyIfPresent(replyName) {
                    try validate(reply: reply, requestID: requestID, published: began, deadline: replyDeadline)
                    acknowledgedReplies.insert(replyName)
                    event["status"] = "ok"; event["completedUptimeSeconds"] = ProcessInfo.processInfo.systemUptime
                    event["holdElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
                    events.append(event)
                    return
                }
                // Deliberately no runloop pumping: observation cannot reenter the synchronous Finish recipient.
                Thread.sleep(forTimeInterval: min(0.025, max(0, replyDeadline - ProcessInfo.processInfo.systemUptime)))
            }
        } catch {
            let failure = error as NSError
            terminalFailure = failure
            event["status"] = "failed"; event["errorCode"] = failure.localizedDescription
            event["holdElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            events.append(event)
            throw failure
        }
    }

    private func rejectUnexpectedReplies(current: String?) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where name.hasPrefix("reply-") {
            guard acknowledgedReplies.contains(name) || name == current else { throw Self.failure("diagnostic-unknown-or-premature-reply") }
        }
    }

    private func readReplyIfPresent(_ name: String) throws -> [String: Any]? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Self.failure("diagnostic-reply-open-failed")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 16_384 else {
            throw Self.failure("diagnostic-reply-file-invalid")
        }
        guard let data = try file.read(upToCount: 16_385), data.count == Int(info.st_size), data.count <= 16_384,
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Self.failure("diagnostic-reply-json-invalid")
        }
        return reply
    }

    private func validate(reply: [String: Any], requestID: String, published: Double, deadline: Double) throws {
        let keys: Set<String> = ["schemaVersion", "protocol", "runToken", "sequence", "requestID", "identity", "status", "completedUptimeSeconds", "errorCode"]
        guard Set(reply.keys) == keys,
              number(reply["schemaVersion"]) == 1, number(reply["sequence"]) == Double(sequence),
              reply["protocol"] as? String == Self.protocolName, reply["runToken"] as? String == token,
              reply["requestID"] as? String == requestID,
              let echoed = reply["identity"] as? [String: Any], Set(echoed.keys) == Set(identity.keys),
              number(echoed["pid"]) == number(identity["pid"]),
              number(echoed["processStartEpochSeconds"]) == number(identity["processStartEpochSeconds"]),
              number(echoed["processStartUptimeSeconds"]) == number(identity["processStartUptimeSeconds"]),
              echoed["executablePath"] as? String == identity["executablePath"] as? String,
              echoed["executableSHA256"] as? String == identity["executableSHA256"] as? String,
              let completed = number(reply["completedUptimeSeconds"]), completed >= published, completed <= deadline,
              completed <= ProcessInfo.processInfo.systemUptime, ProcessInfo.processInfo.systemUptime < deadline,
              let status = reply["status"] as? String, ["ok", "failed"].contains(status),
              let errorCode = reply["errorCode"] as? String, errorCode.utf8.count <= 128,
              errorCode.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
              (status == "ok" ? errorCode.isEmpty : !errorCode.isEmpty) else {
            throw Self.failure("diagnostic-reply-schema-identity-or-time-invalid")
        }
        guard status == "ok" else { throw Self.failure("diagnostic-observer-failed-" + errorCode) }
    }

    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private func publish(_ object: [String: Any], name: String) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        guard data.count <= 16_384 else { throw Self.failure("diagnostic-request-too-large") }
        let temporary = "." + name + "." + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("diagnostic-request-create-failed") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(directoryFD, temporary, 0) }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard renameatx_np(directoryFD, temporary, directoryFD, name, UInt32(RENAME_EXCL)) == 0 else { throw Self.failure("diagnostic-request-publish-failed") }
        guard fsync(directoryFD) == 0 else { throw Self.failure("diagnostic-request-directory-sync-failed") }
    }

    private static func failure(_ code: String) -> NSError {
        NSError(domain: "PicShot.LiveScrollAllocationDiagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: code])
    }
}
