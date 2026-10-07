import Foundation
import Darwin

guard CommandLine.arguments.count == 5 else {
    fputs("Usage: launch-image-decode-helper.swift APP MODE NEW_EVIDENCE PREPARED_INPUTS\n", stderr); exit(64)
}
let args = CommandLine.arguments, app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mode = args[2], evidence = URL(fileURLWithPath: args[3], isDirectory: true)
let modes = ["production-control", "isolated-decode", "cancel-after-decode", "timeout-after-decode"]
let files = FileManager.default, binary = app.appendingPathComponent("Contents/MacOS/PicShot")
guard modes.contains(mode), args[1].hasPrefix("/"), args[3].hasPrefix("/"), args[4].hasPrefix("/"), app.pathExtension == "app",
      files.isExecutableFile(atPath: binary.path), !files.fileExists(atPath: evidence.path) else { exit(64) }
try files.createDirectory(at: evidence, withIntermediateDirectories: true)
let logURL = evidence.appendingPathComponent("process.log")
guard files.createFile(atPath: logURL.path, contents: nil) else { exit(1) }
let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
let launchReport = evidence.appendingPathComponent("launch.json")
let pipe = Pipe(), process = Process()
let readFD = pipe.fileHandleForReading.fileDescriptor, flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
guard flags >= 0, fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0 else { exit(1) }
process.executableURL = binary; process.arguments = []
process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": files.temporaryDirectory.path, "LANG": "en_US.UTF-8",
    "PICSHOT_SMOKE_TEST": "1", "PICSHOT_SMOKE_REPORT": launchReport.path,
    "PICSHOT_IMAGE_DRAW_HELPER_MODE": mode, "PICSHOT_IMAGE_DRAW_HELPER_INPUT_DIRECTORY": args[4]]
let start = ProcessInfo.processInfo.systemUptime
try process.run(); try? pipe.fileHandleForWriting.close()
var readBytes = 0, closed = false, failure: String?, buffer = [UInt8](repeating: 0, count: 4_096)
func drain() {
    for _ in 0..<40 {
        let n = Darwin.read(readFD, &buffer, buffer.count)
        if n == 0 { closed = true; return }
        if n < 0 { if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { failure = "log-read-failed" }; return }
        let allowed = min(n, max(0, 1_048_576 - readBytes))
        if allowed > 0 { try? log.write(contentsOf: Data(buffer.prefix(allowed))) }
        readBytes += n
        if readBytes > 1_048_576 { failure = "log-cap-exceeded"; return }
    }
}
while process.isRunning {
    drain()
    if ProcessInfo.processInfo.systemUptime - start >= 200 { failure = "outer-deadline" }
    if failure != nil { break }
    Thread.sleep(forTimeInterval: 0.01)
}
if process.isRunning {
    let result = kill(process.processIdentifier, SIGKILL), error = errno
    let end = ProcessInfo.processInfo.systemUptime + 3
    while process.isRunning && ProcessInfo.processInfo.systemUptime < end { drain(); Thread.sleep(forTimeInterval: 0.01) }
    if !process.isRunning { process.waitUntilExit() }
    let report: [String: Any] = ["status": "failed", "reason": failure ?? "unknown", "outerDeadlineSeconds": 200,
        "parentPID": Int(process.processIdentifier), "killReturn": result, "killErrno": result == 0 ? 0 : error,
        "parentExitConfirmed": !process.isRunning, "childCleanupConfirmed": false,
        "scope": "Only owned parent termination is confirmed here; each diagnostic child has an independent six-second backstop. No child memory or cleanup success is inferred"]
    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("launcher-failure.json"), options: .atomic)
    exit(1)
}
process.waitUntilExit()
let drainDeadline = ProcessInfo.processInfo.systemUptime + 0.5
while !closed && ProcessInfo.processInfo.systemUptime < drainDeadline { drain(); if !closed { Thread.sleep(forTimeInterval: 0.01) } }
try? pipe.fileHandleForReading.close()
guard failure == nil, closed, process.terminationReason == .exit, process.terminationStatus == 0 else { exit(1) }
let named = evidence.appendingPathComponent("image-decode-helper-\(mode).json")
let size = try named.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
guard size > 0, size <= 2_097_152 else { exit(1) }
let data = try Data(contentsOf: named)
guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      report["protocol"] as? String == "image-decode-helper-parent-v1", report["status"] as? String == "observed",
      report["mode"] as? String == mode, report["processIdentifier"] as? Int == Int(process.processIdentifier) else { exit(1) }
print(named.path)
