import Foundation
import Darwin
@testable import PicShot

/// Evidence for one explicitly synthetic shared-lease test, never a production
/// helper or timing override. It adds no child, prewarming, retries, or waits.
final class CodecGIFReadinessEvidence: @unchecked Sendable {
    private static let traceLimit = 4_096
    private let lock = NSLock()
    private let trace: FileHandle
    private let traceURL: URL
    private let traceDevice: UInt64
    private let traceInode: UInt64
    private let start = ProcessInfo.processInfo.systemUptime
    private var events: [[String: Any]] = []
    private var eventsDropped = 0
    private var childCaptures: [[String: Any]] = []
    private var wait: [String: Any] = [:]
    private var previousWake: TimeInterval?
    private var maximumWakeGap: TimeInterval = 0
    private var wakeCount = 0

    init(root: URL) throws {
        let url = root.appendingPathComponent("synthetic-python-readiness.jsonl")
        traceURL = url
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw CodecProcessTestSupportError.failed("Cannot create owned readiness trace") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size == 0 else {
            try? handle.close()
            throw CodecProcessTestSupportError.failed("Readiness trace ownership check failed")
        }
        trace = handle
        traceDevice = UInt64(info.st_dev)
        traceInode = UInt64(info.st_ino)
        record("evidenceCreated")
    }

    var pythonArguments: [String] {
        ["-u", "-c", Self.pythonScript, traceURL.path, String(traceDevice), String(traceInode)]
    }

    // Exactly three bounded sidecar records; stdout remains the original single
    // progress event. Keep tracing failures from changing fixture protocol behavior.
    // Capture interpreter-ready before opening the trace, after imports only.
    private static let pythonScript = #"""
    import sys,time,os
    ready = (time.time(), time.monotonic())
    trace_fd = None
    try:
        trace_fd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(trace_fd)
        if (info.st_dev, info.st_ino, info.st_uid, info.st_size) != (int(sys.argv[2]), int(sys.argv[3]), os.geteuid(), 0):
            os.close(trace_fd)
            trace_fd = None
    except OSError:
        if trace_fd is not None:
            os.close(trace_fd)
        trace_fd = None
    def mark(phase, stamp=None):
        if trace_fd is None:
            return
        wall, monotonic = stamp if stamp is not None else (time.time(), time.monotonic())
        line = ('{"phase":"%s","unixSeconds":%.9f,"monotonicSeconds":%.9f,"pid":%d,"pythonVersion":"%d.%d.%d"}\n' % (phase, wall, monotonic, os.getpid(), *sys.version_info[:3])).encode('ascii')
        try:
            if len(line) <= 256 and os.fstat(trace_fd).st_size + len(line) <= 4096:
                os.write(trace_fd, line)
        except OSError:
            pass
    mark('interpreterReady', ready)
    sys.stdin.buffer.readline()
    request_read = (time.time(), time.monotonic())
    print('{"version":1,"kind":"progress","fraction":0}',flush=True)
    progress_written = (time.time(), time.monotonic())
    mark('requestRead', request_read)
    mark('progressWritten', progress_written)
    if trace_fd is not None:
        os.close(trace_fd)
    time.sleep(20)
    """#

    func record(_ phase: String, fraction: Double? = nil, errorType: String? = nil,
                callbackEnteredUptime: TimeInterval? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        var event: [String: Any] = ["phase": phase, "elapsedSeconds": now - start,
                                    "unixSeconds": Date().timeIntervalSince1970,
                                    "isMainThread": Thread.isMainThread]
        if let fraction { event["fraction"] = fraction }
        if let errorType { event["errorType"] = String(errorType.prefix(128)) }
        if let callbackEnteredUptime { event["callbackEnteredElapsedSeconds"] = callbackEnteredUptime - start }
        lock.lock(); defer { lock.unlock() }
        if events.count < 32 { events.append(event) } else { eventsDropped += 1 }
    }

    func beginWait(deadline: Date) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        previousWake = now
        wait = ["startedElapsedSeconds": now - start, "deadlineUnixSeconds": deadline.timeIntervalSince1970,
                "configuredReadinessSeconds": 3, "configuredPollSeconds": 0.01]
    }

    func recordWaitWake() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if let previousWake { maximumWakeGap = max(maximumWakeGap, now - previousWake) }
        previousWake = now; wakeCount += 1
    }

    func endWait(progressCount: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        wait["endedElapsedSeconds"] = now - start
        wait["endedUnixSeconds"] = Date().timeIntervalSince1970
        wait["progressCountAtAssertion"] = progressCount
    }

    func captureChildTrace(phase: String) {
        // Read the retained descriptor, not a reopenable pathname. A snapshot
        // racing one small append may have an incomplete tail; never parse it.
        var buffer = [UInt8](repeating: 0, count: Self.traceLimit + 1)
        let count = Darwin.pread(trace.fileDescriptor, &buffer, buffer.count, 0)
        var capture: [String: Any] = ["phase": phase, "readElapsedSeconds": ProcessInfo.processInfo.systemUptime - start]
        if count < 0 {
            capture["readErrno"] = errno
        } else {
            let bytes = Array(buffer.prefix(min(count, Self.traceLimit)))
            let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
            let completeLines = lines.dropLast()
            let allowed = Set(["interpreterReady", "requestRead", "progressWritten"])
            var records: [[String: Any]] = []
            var rejected = 0
            for line in completeLines.prefix(3) {
                guard line.count <= 256,
                      let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let name = item["phase"] as? String, allowed.contains(name),
                      let wall = item["unixSeconds"] as? Double, wall.isFinite,
                      let monotonic = item["monotonicSeconds"] as? Double, monotonic.isFinite,
                      let pid = item["pid"] as? Int, pid > 0,
                      let version = item["pythonVersion"] as? String, version.utf8.count <= 32,
                      version.allSatisfy({ $0.isNumber || $0 == "." }) else { rejected += 1; continue }
                records.append(["phase": name, "unixSeconds": wall, "monotonicSeconds": monotonic,
                                "pid": pid, "pythonVersion": version])
            }
            capture["records"] = records
            capture["bytesRead"] = count
            capture["oversized"] = count > Self.traceLimit
            capture["incompleteTrailingRecord"] = !bytes.isEmpty && bytes.last != 10
            capture["rejectedRecords"] = rejected
            capture["extraRecords"] = max(0, completeLines.count - 3)
        }
        lock.lock(); defer { lock.unlock() }
        if childCaptures.count < 2 { childCaptures.append(capture) }
    }

    func emit(finalSnapshot: GIFExportProcessSnapshot?) {
        #if arch(x86_64)
        let architecture = "x86_64"
        #elseif arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "other"
        #endif
        lock.lock()
        var payload: [String: Any] = [
            "schema": "picshot-codec-gif-readiness-v1",
            "scope": "test-only synthetic /usr/bin/python3; not the signed native GIF helper",
            "test": "CodecExportProcessTests.testSharedLeaseRejectsCodecWhileGIFChildRunsAndReleasesAfterConfirmedCancel",
            "probeSource": #fileID, "architecture": architecture,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "logicalProcessorCount": ProcessInfo.processInfo.processorCount,
            "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
            "sourceFixture": ["bytes": 1, "kind": "synthetic, not valid media"],
            "configuredGIFWallSeconds": 5, "parentEvents": events, "parentEventsDropped": eventsDropped,
            "readinessWait": wait, "waitWakeCount": wakeCount, "maximumWaitWakeGapSeconds": maximumWakeGap,
            "childTraceCaptures": childCaptures,
            "clockScope": "unixSeconds permits wall-clock correlation; use monotonic deltas only within each process"
        ]
        lock.unlock()
        if let finalSnapshot, let data = try? JSONEncoder().encode(finalSnapshot),
           let object = try? JSONSerialization.jsonObject(with: data) {
            payload["finalGIFSnapshot"] = object
        } else { payload["finalGIFSnapshotMissing"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), data.count <= 16_384 else {
            print("GIF readiness evidence: {\"schema\":\"picshot-codec-gif-readiness-v1\",\"encodingFailedOrOversized\":true}")
            return
        }
        print("GIF readiness evidence: " + String(decoding: data, as: UTF8.self))
    }
}
