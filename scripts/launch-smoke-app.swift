import AppKit
import Foundation
import Darwin

// BEGIN opt-in pin UI owned-process diagnostics
// This observer owns at most two sample children. No process-name lookup, shell,
// privilege escalation, application operands, or application input is involved.
final class PinUIOwnedDiagnostic {
    private let directoryFD: Int32
    private let receipts: FileHandle
    private var receiptBytes = 0
    private let receiptLimit = 256 * 1024
    private let outputLimit = 2 * 1024 * 1024
    private let schedule: [TimeInterval] = [90, 360]
    private var nextSample = 0
    private(set) var failed = false
    private var receiptFailed = false
    private var cleanupUnconfirmed = false
    private var child: Process?
    private var pipe: Pipe?
    private var output: FileHandle?
    private var outputBytes = 0
    private var sampleStart: TimeInterval = 0
    private var scheduledSeconds: TimeInterval = 0
    private var sampleFailure: String?

    init(directory: String) throws {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw NSError(domain: "PinUIOwnedDiagnostic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Diagnostic directory must be an absolute existing directory"])
        }
        directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let fd = openat(directoryFD, "launcher-events.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(directoryFD)
            throw error
        }
        receipts = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    deinit { close(directoryFD) }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["schema"] = "pin-ui-owned-diagnostic-v1"
        row["event"] = event
        row["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0a)
            guard receiptBytes + data.count <= receiptLimit else {
                throw NSError(domain: "PinUIOwnedDiagnostic", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Lifecycle receipt byte limit reached"])
            }
            try receipts.write(contentsOf: data)
            receiptBytes += data.count
            try receipts.synchronize()
        } catch {
            failed = true; receiptFailed = true
            fputs("Unable to preserve pin UI diagnostic receipt: \(error)\n", stderr)
            fflush(stderr)
        }
    }

    // The main run loop drains a nonblocking pipe into a strictly capped file.
    // -file /dev/stdout prevents sample's default, otherwise unbounded /tmp file.
    private func drain() {
        guard let pipe, let output else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var wrote = false
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(pipe.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno != EAGAIN && errno != EINTR { sampleFailure = "pipe-read-error-\(errno)" }
                break
            }
            if count == 0 { break }
            let allowed = min(count, outputLimit - outputBytes)
            do {
                if allowed > 0 {
                    try output.write(contentsOf: Data(buffer.prefix(allowed)))
                    outputBytes += allowed
                    wrote = true
                }
            } catch { sampleFailure = "output-write-failed: \(error)"; break }
            if allowed < count || outputBytes == outputLimit {
                sampleFailure = "sample-output-byte-limit"
                break
            }
        }
        if wrote {
            do { try output.synchronize() }
            catch { sampleFailure = "output-flush-failed: \(error)" }
        }
    }

    private func complete(_ identity: [String: Any]) {
        guard let child else { return }
        drain()
        if identity["samplingFingerprintMatches"] as? Bool != true {
            sampleFailure = sampleFailure ?? "owned-sampling-identity-changed-or-not-live-after-sample"
        }
        let exited = !child.isRunning
        if !exited {
            failed = true; cleanupUnconfirmed = true
            record("sample-cleanup-unconfirmed", ["samplePID": Int(child.processIdentifier),
                "childExitConfirmed": false, "failure": sampleFailure ?? "sample-child-exit-unconfirmed",
                "identityAfter": identity])
            // Retain ownership and keep draining; never start a second child after this.
            return
        }
        if exited && (child.terminationReason != .exit || child.terminationStatus != 0) {
            sampleFailure = sampleFailure ?? "sample-command-failed"
        }
        if outputBytes == 0 { sampleFailure = sampleFailure ?? "sample-output-empty" }
        do { try output?.synchronize(); try output?.close(); try pipe?.fileHandleForReading.close() }
        catch { sampleFailure = sampleFailure ?? "sample-close-failed: \(error)" }
        var row: [String: Any] = ["scheduledSeconds": scheduledSeconds,
            "samplePID": Int(child.processIdentifier), "childExitConfirmed": exited,
            "outputBytes": outputBytes, "outputByteLimit": outputLimit,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - sampleStart,
            "identityAfter": identity, "stackCaptureValidated": false,
            "outcome": sampleFailure == nil ? "sample-command-completed" : "sample-failed"]
        if exited {
            row["terminationStatus"] = Int(child.terminationStatus)
            row["terminationReason"] = child.terminationReason == .exit ? "exit" : "signal"
        }
        if let sampleFailure { failed = true; row["failure"] = sampleFailure }
        record("sample-finished", row)
        self.child = nil; pipe = nil; output = nil
    }

    func stopSample(_ reason: String, identity: () -> [String: Any]) {
        guard let child else { return }
        if child.isRunning {
            sampleFailure = sampleFailure ?? reason
            record("sample-cleanup-started", ["reason": reason, "samplePID": Int(child.processIdentifier),
                                               "identityBeforeCleanup": identity()])
            child.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 1
            while child.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                drain()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if child.isRunning {
                let result = kill(child.processIdentifier, SIGKILL)
                let signalError = result == 0 ? 0 : errno
                record("sample-force-termination", ["samplePID": Int(child.processIdentifier),
                    "signalResult": Int(result), "signalErrno": Int(signalError)])
            }
            let forced = ProcessInfo.processInfo.systemUptime + 1
            while child.isRunning && ProcessInfo.processInfo.systemUptime < forced {
                drain()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        complete(identity())
    }

    func poll(elapsed: TimeInterval, identity: () -> [String: Any]) {
        if let child {
            drain()
            if !child.isRunning { complete(identity()) }
            else if cleanupUnconfirmed { return }
            else if sampleFailure != nil || receiptFailed { stopSample(sampleFailure ?? "receipt-failed", identity: identity) }
            else if identity()["samplingFingerprintMatches"] as? Bool != true { stopSample("owned-app-no-longer-live-or-matching", identity: identity) }
            else if ProcessInfo.processInfo.systemUptime - sampleStart >= 10 { stopSample("sample-10-second-timeout", identity: identity) }
        }
        guard child == nil, !receiptFailed, !cleanupUnconfirmed, nextSample < schedule.count, elapsed >= schedule[nextSample] else { return }
        scheduledSeconds = schedule[nextSample]
        nextSample += 1
        let before = identity()
        guard before["samplingFingerprintMatches"] as? Bool == true,
              let ownedPID = before["ownedProcessIdentifier"] as? Int else {
            failed = true
            let reason = before["launchDateAvailable"] as? Bool == true ? "owned-sampling-fingerprint-not-live-or-matching" : "owned-launch-date-unavailable"
            record("sample-skipped", ["scheduledSeconds": scheduledSeconds, "reason": reason, "identityBefore": before])
            return
        }
        let filename = "sample-\(Int(scheduledSeconds))s.txt"
        let fd = openat(directoryFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let creationError = errno
            failed = true
            record("sample-failed", ["scheduledSeconds": scheduledSeconds, "failure": "sample-output-create-failed", "errno": Int(creationError), "identityBefore": before])
            return
        }
        output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        outputBytes = 0; sampleFailure = nil
        let capture = Pipe()
        let readFD = capture.fileHandleForReading.fileDescriptor
        guard fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK) != -1 else {
            let pipeError = errno
            failed = true
            record("sample-failed", ["failure": "sample-pipe-nonblocking-failed", "errno": Int(pipeError), "identityBefore": before])
            try? output?.close(); output = nil
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ownedPID), "1", "10", "-file", "/dev/stdout"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = capture; process.standardError = capture
        record("sample-starting", ["scheduledSeconds": scheduledSeconds, "observedLaunchElapsedSeconds": elapsed, "outputFile": filename,
            "arguments": process.arguments!, "durationSeconds": 1, "intervalMilliseconds": 10,
            "childTimeoutSeconds": 10, "childCleanupSeconds": [1, 1], "outputByteLimit": outputLimit,
            "identityBefore": before])
        // Recheck after durable receipt I/O, immediately before the PID operand is used.
        guard !receiptFailed, identity()["samplingFingerprintMatches"] as? Bool == true else {
            failed = true
            record("sample-skipped", ["scheduledSeconds": scheduledSeconds, "reason": "identity-changed-or-receipt-failed-before-spawn", "identityBefore": identity()])
            try? output?.close(); output = nil
            return
        }
        do {
            sampleStart = ProcessInfo.processInfo.systemUptime
            try process.run()
            child = process; pipe = capture
            try capture.fileHandleForWriting.close()
            record("sample-started", ["scheduledSeconds": scheduledSeconds, "samplePID": Int(process.processIdentifier), "identityAfterSpawn": identity()])
        } catch {
            failed = true
            sampleFailure = "sample-launch-or-pipe-close-failed: \(error)"
            record("sample-failed", ["scheduledSeconds": scheduledSeconds, "failure": sampleFailure!, "identityBefore": before])
            if child != nil { stopSample(sampleFailure!, identity: identity) }
            else { try? output?.close(); output = nil }
        }
    }

    func finish(status: String, code: Int32, identity: () -> [String: Any]) {
        stopSample("launcher-finishing", identity: identity)
        record("launcher-finished", ["launcherStatus": status, "requestedLauncherExitCode": Int(code),
            "launcherExitCode": code == 0 && failed ? 1 : Int(code),
            "diagnosticFailed": failed, "sampleAttempts": nextSample, "sampleChildExitConfirmed": child == nil,
            "unreachedSampleSeconds": Array(schedule.dropFirst(nextSample)), "identityAfter": identity()])
    }
}
// END opt-in pin UI owned-process diagnostics

// Launch the real installed app without command-line operands. Cocoa can turn
// unknown arguments (especially an absolute report path) into an open-file
// request, suppressing the application's normal initial window.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: launch-smoke-app.swift APP REPORT\n", stderr)
    exit(64)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let recordingInputExportOnly = ProcessInfo.processInfo.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] != nil
let liveScrollDiagnostic = ProcessInfo.processInfo.environment["PICSHOT_LIVE_SCROLL_RESOURCE_MODE"] != nil
    || ProcessInfo.processInfo.environment["PICSHOT_LIVE_SCROLL_DEMO_ONLY"] == "1"
let captureChainDiagnostic = ProcessInfo.processInfo.environment["PICSHOT_CAPTURE_CHAIN_DEMO_ONLY"] == "1"
let expectedExecutablePath = appURL.appendingPathComponent("Contents/MacOS/PicShot").resolvingSymlinksInPath().path
let pinUIDiagnosticDirectory = ProcessInfo.processInfo.environment["PICSHOT_PIN_UI_DIAGNOSTIC_DIRECTORY"]
var pinUIDiagnostic: PinUIOwnedDiagnostic?
if let directory = pinUIDiagnosticDirectory {
    do { pinUIDiagnostic = try PinUIOwnedDiagnostic(directory: directory) }
    catch { fputs("Unable to initialize pin UI diagnostic: \(error)\n", stderr); exit(1) }
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = true
configuration.addsToRecentItems = false
configuration.arguments = []
configuration.environment = [
    "PICSHOT_SMOKE_TEST": "1",
    "PICSHOT_SMOKE_REPORT": CommandLine.arguments[2],
]
if let directory = pinUIDiagnosticDirectory, pinUIDiagnostic != nil {
    configuration.environment["PICSHOT_PIN_UI_DIAGNOSTIC_DIRECTORY"] = directory
}
if let selector = ProcessInfo.processInfo.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] {
    configuration.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] = selector
}
for key in ["PICSHOT_CAPTURE_CHAIN_DEMO_ONLY", "PICSHOT_LIVE_SCROLL_RESOURCE_MODE", "PICSHOT_LIVE_SCROLL_RESOURCE_INPUT", "PICSHOT_LIVE_SCROLL_PNG_WRITER", "PICSHOT_LIVE_SCROLL_DEMO_ONLY", "PICSHOT_LIVE_SCROLL_TARGET", "PICSHOT_CODEC_STAGING_MODE", "PICSHOT_CODEC_STAGING_ARM", "PICSHOT_CODEC_STAGING_PROFILE", "PICSHOT_CODEC_STAGING_FORMAT", "PICSHOT_CODEC_STAGING_INPUT_DIRECTORY", "PICSHOT_EDITABLE_PRODUCT_MODE", "PICSHOT_EDITABLE_PRODUCT_INPUT", "PICSHOT_EDITABLE_PRODUCT_CERTIFICATE", "PICSHOT_RENDERER_STORAGE_STRATEGY", "PICSHOT_DRAWING_RASTER_STRATEGY", "PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY", "PICSHOT_EDITABLE_HASH_DIAGNOSTIC", "PICSHOT_EDITABLE_ANNOTATIONS_ONLY", "PICSHOT_EDITABLE_ANNOTATION_RESOURCES", "PICSHOT_MULTIWINDOW_COMPOSITION", "PICSHOT_MULTIWINDOW_RESOURCES_ONLY", "PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST", "PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES", "PICSHOT_RECORDING_COMPOSITION_ONLY", "PICSHOT_RECORDING_COMPOSITION_TRACE", "PICSHOT_MANUAL_HASH_STRATEGY", "PICSHOT_SCROLL_ATTRIBUTION_MODE", "PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY", "PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT", "PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT", "PICSHOT_MANUAL_SCROLL_ONLY", "PICSHOT_MANUAL_SCROLL_RESOURCES", "PICSHOT_ANNOTATION_DETAILS_ONLY", "PICSHOT_AUTOMATIC_MOSAIC_ONLY", "PICSHOT_PIN_GROUP_TRANSFORMS_ONLY", "PICSHOT_LATEX_PIN_VERIFY", "PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY", "PICSHOT_SMOKE_FORMULA_MODEL_DIR", "PICSHOT_SMOKE_FORMULA_INPUT", "PICSHOT_SMOKE_TABLE_MODEL_DIR", "PICSHOT_SMOKE_TABLE_INPUT", "PICSHOT_SMOKE_ERASE_MODEL_DIR", "PICSHOT_UI_PREVIEW_ONLY", "PICSHOT_SMOKE_GIF_RESOURCES", "PICSHOT_GIF_DIAGNOSTIC_MODE", "PICSHOT_GIF_EXTRACTION", "PICSHOT_GIF_EXECUTION", "PICSHOT_CODEC_ATTRIBUTION_MODE", "PICSHOT_CODEC_ATTRIBUTION_FORMAT", "PICSHOT_CODEC_ATTRIBUTION_PROFILE", "PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY", "PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_IMAGE_BACKING_FORMAT", "PICSHOT_IMAGE_BACKING_PROFILE", "PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY"] {
    if let value = ProcessInfo.processInfo.environment[key] { configuration.environment[key] = value }
}
#if PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS
if let path = ProcessInfo.processInfo.environment["PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH"] {
    configuration.environment["PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH"] = path
}
#endif
let launchBegan = Date()
let launchBeganUptime = ProcessInfo.processInfo.systemUptime
var launched: NSRunningApplication?
var launchError: Error?
var launchedProcessIdentifier: Int?
var launchedBundlePath: String?
var launchedExecutablePath: String?
var callbackReceived = false
var pinUILaunchedDate: Date?
var pinUILaunchedUptime: TimeInterval?
func pinUIOwnedIdentity() -> [String: Any] {
    let current = launched.flatMap { NSRunningApplication(processIdentifier: $0.processIdentifier) }
    let ownedLive = launched?.isTerminated == false
    let currentLive = current?.isTerminated == false
    let ownedBundle = launched?.bundleURL?.resolvingSymlinksInPath().path
    let ownedExecutable = launched?.executableURL?.resolvingSymlinksInPath().path
    let currentBundle = current?.bundleURL?.resolvingSymlinksInPath().path
    let currentExecutable = current?.executableURL?.resolvingSymlinksInPath().path
    let expectedBundle = appURL.resolvingSymlinksInPath().path
    let dateMatches = pinUILaunchedDate == nil || (launched?.launchDate == pinUILaunchedDate && current?.launchDate == pinUILaunchedDate)
    let matches = ownedLive && currentLive && launchedIdentityMatches() &&
        ownedBundle == expectedBundle && currentBundle == expectedBundle &&
        ownedExecutable == expectedExecutablePath && currentExecutable == expectedExecutablePath &&
        launched.map { Int($0.processIdentifier) } == launchedProcessIdentifier && dateMatches
    // Sampling requires an immutable launch fingerprint. Missing launchDate
    // disables sampling but does not prevent cleanup of the retained owned app.
    let samplingFingerprintMatches = matches && pinUILaunchedDate != nil && dateMatches
    var row: [String: Any] = ["ownedLiveIdentityMatches": matches,
        "samplingFingerprintMatches": samplingFingerprintMatches,
        "ownedApplicationStillLive": ownedLive, "currentPIDStillLive": currentLive,
        "expectedBundlePath": expectedBundle, "expectedExecutablePath": expectedExecutablePath,
        "launchDateAvailable": pinUILaunchedDate != nil, "launchDateMatches": dateMatches]
    if let launchedProcessIdentifier { row["ownedProcessIdentifier"] = launchedProcessIdentifier }
    if let ownedBundle { row["ownedBundlePath"] = ownedBundle }
    if let ownedExecutable { row["ownedExecutablePath"] = ownedExecutable }
    if let currentBundle { row["currentBundlePath"] = currentBundle }
    if let currentExecutable { row["currentExecutablePath"] = currentExecutable }
    if let pinUILaunchedDate { row["ownedLaunchDateEpochSeconds"] = pinUILaunchedDate.timeIntervalSince1970 }
    if let date = current?.launchDate { row["currentLaunchDateEpochSeconds"] = date.timeIntervalSince1970 }
    return row
}
// The early gate's outer bounded runner may cancel this launcher. LaunchServices
// owns a separate app process, so let this existing owner close its exact app.
var interruptedSignal: Int32?
var interruptionSources: [DispatchSourceSignal] = []
if liveScrollDiagnostic || captureChainDiagnostic || recordingInputExportOnly || pinUIDiagnostic != nil {
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { interruptedSignal = number }
        source.resume(); interruptionSources.append(source)
    }
}
func launchedIdentityMatches() -> Bool {
    launchedBundlePath == appURL.resolvingSymlinksInPath().path && launchedExecutablePath == expectedExecutablePath
}
pinUIDiagnostic?.record("launch-requested", ["identityBefore": pinUIOwnedIdentity(),
    "scheduledSampleSeconds": [90, 360], "samplingTimingOrigin": "owned-launch-callback", "appTimeoutSeconds": captureChainDiagnostic ? 240 : 600, "appCleanupSeconds": [3, 3],
    "directory": pinUIDiagnosticDirectory!, "applicationArguments": configuration.arguments])
if pinUIDiagnostic?.failed == true { exit(1) }
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
    DispatchQueue.main.async {
        launched = app
        launchError = error
        launchedProcessIdentifier = app.map { Int($0.processIdentifier) }
        launchedBundlePath = app?.bundleURL?.resolvingSymlinksInPath().path
        launchedExecutablePath = app?.executableURL?.resolvingSymlinksInPath().path
        callbackReceived = true
        if let diagnostic = pinUIDiagnostic {
            pinUILaunchedDate = app?.launchDate
            pinUILaunchedUptime = ProcessInfo.processInfo.systemUptime
            var receipt: [String: Any] = ["identityAfter": pinUIOwnedIdentity(), "applicationReturned": app != nil]
            if let error { receipt["launchError"] = error.localizedDescription }
            diagnostic.record("launch-callback", receipt)
        }
    }
}
let diagnosticMode = pinUIDiagnostic != nil ? "" : (ProcessInfo.processInfo.environment["PICSHOT_GIF_DIAGNOSTIC_MODE"] ?? "")
let timeout: TimeInterval = ["export-only", "decode-only"].contains(diagnosticMode) ? 900 : 600
// Keep chain observation and owned-app cleanup inside its existing 300-second outer step.
let effectiveTimeout: TimeInterval = captureChainDiagnostic ? 240 : timeout
let deadline = Date().addingTimeInterval(effectiveTimeout)
func finish(_ requestedCode: Int32, _ status: String) -> Never {
    pinUIDiagnostic?.finish(status: status, code: requestedCode, identity: pinUIOwnedIdentity)
    let code: Int32 = requestedCode == 0 && pinUIDiagnostic?.failed == true ? 1 : requestedCode
    if liveScrollDiagnostic || captureChainDiagnostic || recordingInputExportOnly || ProcessInfo.processInfo.environment["PICSHOT_CODEC_STAGING_MODE"] != nil || ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil ||
       ProcessInfo.processInfo.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] == "1" ||
       ProcessInfo.processInfo.environment["PICSHOT_UI_PREVIEW_ONLY"] == "1" ||
       ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1" ||
       ProcessInfo.processInfo.environment["PICSHOT_MULTIWINDOW_RESOURCES_ONLY"] == "1" ||
       ProcessInfo.processInfo.environment["PICSHOT_MANUAL_HASH_STRATEGY"] != nil ||
       ProcessInfo.processInfo.environment["PICSHOT_RECORDING_COMPOSITION_ONLY"] == "1" ||
       ProcessInfo.processInfo.environment["PICSHOT_RECORDING_COMPOSITION_TRACE"] == "1" {
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[2] + ".launcher.json")
        var report: [String: Any] = ["schemaVersion": 1, "status": status,
            "launcherExitCode": Int(code), "selectedAppPath": appURL.resolvingSymlinksInPath().path,
            "createsNewApplicationInstance": configuration.createsNewApplicationInstance,
            "timeoutSeconds": effectiveTimeout, "elapsedSeconds": Date().timeIntervalSince(launchBegan),
            "callbackReceived": callbackReceived, "ownedExitConfirmed": launched?.isTerminated == true,
            "processStartMemoryCaptured": false,
            "scope": "LaunchServices-owned application lifecycle only; no child memory read and no application exit-code inference"]
        if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil {
            report["launchBeganUptimeSeconds"] = launchBeganUptime
            report["finishUptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        }
        if ProcessInfo.processInfo.environment["PICSHOT_CODEC_STAGING_MODE"] != nil {
            report["launchedIdentityMatches"] = launchedIdentityMatches()
            report["expectedExecutablePath"] = expectedExecutablePath
        }
        if recordingInputExportOnly || liveScrollDiagnostic || captureChainDiagnostic {
            report["earlyWitnessOnly"] = recordingInputExportOnly
            report["liveScrollDiagnosticOnly"] = liveScrollDiagnostic
            report["captureChainDiagnosticOnly"] = captureChainDiagnostic
            report["expectedExecutablePath"] = expectedExecutablePath
            report["launchedIdentityMatches"] = launchedIdentityMatches()
            if let interruptedSignal { report["interruptedSignal"] = Int(interruptedSignal) }
        }
        if launched != nil {
            report["processIdentifier"] = launchedProcessIdentifier
            report["launchedAppPath"] = launchedBundlePath
            report["launchedExecutablePath"] = launchedExecutablePath
        }
        if let launchError { report["error"] = launchError.localizedDescription }
        if let diagnostic = pinUIDiagnostic {
            report["scope"] = "LaunchServices-owned lifecycle and opt-in owned-PID stack sampling; no application exit-code inference"
            report["pinUIDiagnosticFailed"] = diagnostic.failed
            report["pinUIOwnedIdentity"] = pinUIOwnedIdentity()
        }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        } catch {
            fputs("Unable to preserve owned launch lifecycle: \(error)\n", stderr)
            exit(1)
        }
    }
    exit(code)
}
while Date() < deadline && interruptedSignal == nil {
    if callbackReceived {
        if let launchError {
            fputs("LaunchServices failed: \(launchError)\n", stderr)
            finish(1, "launch-failed")
        }
        guard let launched else {
            fputs("LaunchServices returned no application\n", stderr)
            finish(1, "application-missing")
        }
        if (liveScrollDiagnostic || captureChainDiagnostic || recordingInputExportOnly || ProcessInfo.processInfo.environment["PICSHOT_CODEC_STAGING_MODE"] != nil) && !launchedIdentityMatches() {
            fputs("LaunchServices returned a different installed bundle or executable\n", stderr)
            finish(1, "identity-mismatch")
        }
        if launched.isTerminated { finish(0, "exited") }
        if let diagnostic = pinUIDiagnostic {
            guard pinUIOwnedIdentity()["ownedLiveIdentityMatches"] as? Bool == true else {
                diagnostic.record("owned-identity-mismatch", pinUIOwnedIdentity())
                finish(1, "identity-mismatch")
            }
            diagnostic.poll(elapsed: ProcessInfo.processInfo.systemUptime - (pinUILaunchedUptime ?? launchBeganUptime), identity: pinUIOwnedIdentity)
        }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
pinUIDiagnostic?.stopSample("launcher-timeout-or-interruption", identity: pinUIOwnedIdentity)
pinUIDiagnostic?.record("app-cleanup-started", ["identityBefore": pinUIOwnedIdentity(), "interruptedSignal": interruptedSignal.map(Int.init) ?? 0])
fputs(interruptedSignal == nil ? "LaunchServices smoke app did not terminate within \(Int(effectiveTimeout)) seconds\n" : "Owned smoke launch interrupted\n", stderr)
if let launched, !launched.isTerminated, !(recordingInputExportOnly || liveScrollDiagnostic || captureChainDiagnostic) || launchedIdentityMatches(),
   pinUIDiagnostic == nil || pinUIOwnedIdentity()["ownedLiveIdentityMatches"] as? Bool == true {
    _ = launched.terminate()
    let grace = Date().addingTimeInterval(3)
    while !launched.isTerminated && Date() < grace {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if !launched.isTerminated { _ = launched.forceTerminate() }
    let forced = Date().addingTimeInterval(3)
    while !launched.isTerminated && Date() < forced {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    fputs(launched.isTerminated ? "Timed-out owned app exit confirmed\n" : "Timed-out owned app exit could not be confirmed\n", stderr)
}
pinUIDiagnostic?.record("app-cleanup-finished", ["identityAfter": pinUIOwnedIdentity(), "ownedExitConfirmed": launched?.isTerminated == true])
finish(1, interruptedSignal == nil ? "timed-out" : "cancelled")
