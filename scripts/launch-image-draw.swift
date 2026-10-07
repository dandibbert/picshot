import Foundation
import Darwin

// Standalone opt-in launcher: no default smoke/CI hook. Work is killed at the
// 60-second deadline; up to three further seconds only confirm that owned PID's exit.
guard CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5 else {
    fputs("Usage: launch-image-draw.swift APP MODE NEW_EVIDENCE_DIRECTORY [PREPARED_DIRECTORY]\n", stderr)
    exit(64)
}
let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let mode = CommandLine.arguments[2]
let evidence = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
let hasInput = CommandLine.arguments.count == 5
let allowedModes = ["prepare-inputs", "production-draw", "imageio-no-cache-draw", "owned-rgba-draw"]
guard allowedModes.contains(mode), hasInput == (mode != "prepare-inputs") else {
    fputs("Explicit diagnostic mode and matching input-directory selection required\n", stderr); exit(64)
}
let files = FileManager.default
let binary = app.appendingPathComponent("Contents/MacOS/PicShot")
guard app.pathExtension == "app", files.isExecutableFile(atPath: binary.path), !files.fileExists(atPath: evidence.path) else {
    fputs("Expected executable PicShot.app and a new evidence directory\n", stderr); exit(64)
}
try files.createDirectory(at: evidence, withIntermediateDirectories: true)
let log = evidence.appendingPathComponent("process.log")
guard files.createFile(atPath: log.path, contents: nil) else { fputs("Cannot create diagnostic log\n", stderr); exit(1) }
let stream = try FileHandle(forWritingTo: log)
defer { try? stream.close() }
let report = evidence.appendingPathComponent("launch.json")
let process = Process()
process.executableURL = binary
process.arguments = []
process.standardInput = FileHandle.nullDevice
process.standardOutput = stream; process.standardError = stream
var environment = ["HOME": NSHomeDirectory(), "TMPDIR": files.temporaryDirectory.path, "LANG": "en_US.UTF-8",
    "PICSHOT_SMOKE_TEST": "1", "PICSHOT_SMOKE_REPORT": report.path, "PICSHOT_IMAGE_DRAW_MODE": mode]
if hasInput { environment["PICSHOT_IMAGE_DRAW_INPUT_DIRECTORY"] = CommandLine.arguments[4] }
process.environment = environment
let start = ProcessInfo.processInfo.systemUptime
try process.run()
while process.isRunning && ProcessInfo.processInfo.systemUptime - start < 60 { Thread.sleep(forTimeInterval: 0.01) }
if process.isRunning {
    let killResult = kill(process.processIdentifier, SIGKILL)
    let killError = errno
    let confirmDeadline = ProcessInfo.processInfo.systemUptime + 3
    while process.isRunning && ProcessInfo.processInfo.systemUptime < confirmDeadline { Thread.sleep(forTimeInterval: 0.01) }
    if !process.isRunning { process.waitUntilExit() }
    let evidence: [String: Any] = ["status": "timed-out", "mode": mode, "outerDeadlineSeconds": 60,
        "exitConfirmationGraceSeconds": 3, "ownedProcessIdentifier": Int(process.processIdentifier),
        "killReturn": Int(killResult), "killErrno": killResult == 0 ? 0 : Int(killError), "ownedProcessExitConfirmed": !process.isRunning]
    try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        .write(to: report.deletingLastPathComponent().appendingPathComponent("launcher-timeout.json"), options: .atomic)
    fputs("Draw diagnostic exceeded 60 seconds; owned process exit confirmed: \(!process.isRunning)\n", stderr)
    exit(1)
}
process.waitUntilExit()
guard process.terminationReason == .exit && process.terminationStatus == 0 else {
    fputs("Draw diagnostic app failed with status \(process.terminationStatus); see \(log.path)\n", stderr); exit(1)
}
let namedReport = evidence.appendingPathComponent(mode == "prepare-inputs" ? "image-draw-inputs.json" : "image-draw-\(mode).json")
let reportData = try Data(contentsOf: namedReport)
guard reportData.count <= 1_024 * 1_024,
      let payload = try JSONSerialization.jsonObject(with: reportData) as? [String: Any],
      payload["protocol"] as? String == "image-raster-materialization-v1", payload["mode"] as? String == mode,
      payload["processIdentifier"] as? Int == Int(process.processIdentifier),
      payload["status"] as? String == (mode == "prepare-inputs" ? "prepared" : "observed") else {
    fputs("Missing/mismatched diagnostic protocol or report\n", stderr); exit(1)
}
print(namedReport.path)
