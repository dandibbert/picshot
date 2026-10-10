import AppKit
import Foundation
import Darwin

// Launch the real installed app without command-line operands. Cocoa can turn
// unknown arguments (especially an absolute report path) into an open-file
// request, suppressing the application's normal initial window.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: launch-smoke-app.swift APP REPORT\n", stderr)
    exit(64)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let recordingInputExportOnly = ProcessInfo.processInfo.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] != nil
let expectedExecutablePath = appURL.appendingPathComponent("Contents/MacOS/PicShot").resolvingSymlinksInPath().path
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = true
configuration.addsToRecentItems = false
configuration.arguments = []
configuration.environment = [
    "PICSHOT_SMOKE_TEST": "1",
    "PICSHOT_SMOKE_REPORT": CommandLine.arguments[2],
]
if let selector = ProcessInfo.processInfo.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] {
    configuration.environment["PICSHOT_RECORDING_INPUT_EXPORT_ONLY"] = selector
}
for key in ["PICSHOT_EDITABLE_PRODUCT_MODE", "PICSHOT_EDITABLE_PRODUCT_INPUT", "PICSHOT_EDITABLE_PRODUCT_CERTIFICATE", "PICSHOT_RENDERER_STORAGE_STRATEGY", "PICSHOT_DRAWING_RASTER_STRATEGY", "PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY", "PICSHOT_EDITABLE_HASH_DIAGNOSTIC", "PICSHOT_EDITABLE_ANNOTATIONS_ONLY", "PICSHOT_EDITABLE_ANNOTATION_RESOURCES", "PICSHOT_MULTIWINDOW_COMPOSITION", "PICSHOT_MULTIWINDOW_RESOURCES_ONLY", "PICSHOT_MULTIWINDOW_DIAGNOSTIC_TAIL_FIRST", "PICSHOT_MULTIWINDOW_DIAGNOSTIC_BOUNDARIES", "PICSHOT_RECORDING_COMPOSITION_ONLY", "PICSHOT_RECORDING_COMPOSITION_TRACE", "PICSHOT_MANUAL_HASH_STRATEGY", "PICSHOT_SCROLL_ATTRIBUTION_MODE", "PICSHOT_SCROLL_ATTRIBUTION_INPUT_DIRECTORY", "PICSHOT_SCROLL_ATTRIBUTION_PRODUCTION_COMMIT", "PICSHOT_SCROLL_ATTRIBUTION_OVERLAY_COMMIT", "PICSHOT_MANUAL_SCROLL_ONLY", "PICSHOT_MANUAL_SCROLL_RESOURCES", "PICSHOT_ANNOTATION_DETAILS_ONLY", "PICSHOT_AUTOMATIC_MOSAIC_ONLY", "PICSHOT_PIN_GROUP_TRANSFORMS_ONLY", "PICSHOT_LATEX_PIN_VERIFY", "PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY", "PICSHOT_SMOKE_FORMULA_MODEL_DIR", "PICSHOT_SMOKE_FORMULA_INPUT", "PICSHOT_SMOKE_TABLE_MODEL_DIR", "PICSHOT_SMOKE_TABLE_INPUT", "PICSHOT_SMOKE_ERASE_MODEL_DIR", "PICSHOT_UI_PREVIEW_ONLY", "PICSHOT_SMOKE_GIF_RESOURCES", "PICSHOT_GIF_DIAGNOSTIC_MODE", "PICSHOT_GIF_EXTRACTION", "PICSHOT_GIF_EXECUTION", "PICSHOT_CODEC_ATTRIBUTION_MODE", "PICSHOT_CODEC_ATTRIBUTION_FORMAT", "PICSHOT_CODEC_ATTRIBUTION_PROFILE", "PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY", "PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_IMAGE_BACKING_FORMAT", "PICSHOT_IMAGE_BACKING_PROFILE", "PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY"] {
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
// The early gate's outer bounded runner may cancel this launcher. LaunchServices
// owns a separate app process, so let this existing owner close its exact app.
var interruptedSignal: Int32?
var interruptionSources: [DispatchSourceSignal] = []
if recordingInputExportOnly {
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
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
    DispatchQueue.main.async {
        launched = app
        launchError = error
        launchedProcessIdentifier = app.map { Int($0.processIdentifier) }
        launchedBundlePath = app?.bundleURL?.resolvingSymlinksInPath().path
        launchedExecutablePath = app?.executableURL?.resolvingSymlinksInPath().path
        callbackReceived = true
    }
}
let diagnosticMode = ProcessInfo.processInfo.environment["PICSHOT_GIF_DIAGNOSTIC_MODE"] ?? ""
let timeout: TimeInterval = ["export-only", "decode-only"].contains(diagnosticMode) ? 900 : 600
let deadline = Date().addingTimeInterval(timeout)
func finish(_ code: Int32, _ status: String) -> Never {
    if recordingInputExportOnly || ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil ||
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
            "timeoutSeconds": timeout, "elapsedSeconds": Date().timeIntervalSince(launchBegan),
            "callbackReceived": callbackReceived, "ownedExitConfirmed": launched?.isTerminated == true,
            "processStartMemoryCaptured": false,
            "scope": "LaunchServices-owned application lifecycle only; no child memory read and no application exit-code inference"]
        if ProcessInfo.processInfo.environment["PICSHOT_EDITABLE_PRODUCT_MODE"] != nil {
            report["launchBeganUptimeSeconds"] = launchBeganUptime
            report["finishUptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        }
        if recordingInputExportOnly {
            report["earlyWitnessOnly"] = true
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
        if recordingInputExportOnly && !launchedIdentityMatches() {
            fputs("LaunchServices returned a different installed bundle or executable\n", stderr)
            finish(1, "identity-mismatch")
        }
        if launched.isTerminated { finish(0, "exited") }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
fputs(interruptedSignal == nil ? "LaunchServices smoke app did not terminate within \(Int(timeout)) seconds\n" : "Early recording witness launch interrupted\n", stderr)
if let launched, !launched.isTerminated, !recordingInputExportOnly || launchedIdentityMatches() {
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
finish(1, interruptedSignal == nil ? "timed-out" : "cancelled")
