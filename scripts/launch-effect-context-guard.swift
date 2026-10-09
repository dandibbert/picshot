import AppKit
import Foundation

// Launch the real installed app without command-line operands. Cocoa can turn
// unknown arguments (especially an absolute report path) into an open-file
// request, suppressing the application's normal initial window.
guard CommandLine.arguments.count == 4 else {
    fputs("Usage: launch-effect-context-guard.swift APP REPORT POLICY\n", stderr)
    exit(64)
}
let policy = CommandLine.arguments[3]
guard ["reference", "memory32"].contains(policy), CommandLine.arguments[1].hasPrefix("/"),
      CommandLine.arguments[2].hasPrefix("/") else { exit(64) }
let comparisonKind = "effect-context-memory-target"
let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = true
configuration.addsToRecentItems = false
configuration.arguments = []
configuration.environment = [
    "PICSHOT_SMOKE_TEST": "1",
    "PICSHOT_SMOKE_REPORT": CommandLine.arguments[2],
]
configuration.environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] = "1"
configuration.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] = "owned-srgb8"
configuration.environment["PICSHOT_EFFECT_CONTEXT_POLICY"] = policy
let launchBegan = Date()
let launchBeganUptime = ProcessInfo.processInfo.systemUptime
var launched: NSRunningApplication?
var launchError: Error?
var launchedProcessIdentifier: Int?
var launchedBundlePath: String?
var launchedExecutablePath: String?
var callbackReceived = false
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
let timeout: TimeInterval = 600
let deadline = Date().addingTimeInterval(timeout)
func finish(_ code: Int32, _ status: String) -> Never {
    do {
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[2] + ".launcher.json")
        var report: [String: Any] = ["schemaVersion": 1, "status": status,
            "launcherExitCode": Int(code), "drawingStrategy": "owned-srgb8",
            "rendererStorageStrategy": "native", "comparisonKind": comparisonKind,
            "rendererAutoreleaseScope": "caller", "effectContextPolicy": policy,
            "selectedAppPath": appURL.resolvingSymlinksInPath().path,
            "createsNewApplicationInstance": configuration.createsNewApplicationInstance,
            "timeoutSeconds": timeout, "elapsedSeconds": Date().timeIntervalSince(launchBegan),
            "launchBeganUptimeSeconds": launchBeganUptime, "finishUptimeSeconds": ProcessInfo.processInfo.systemUptime,
            "callbackReceived": callbackReceived, "ownedExitConfirmed": launched?.isTerminated == true,
            "processStartMemoryCaptured": false,
            "scope": "LaunchServices-owned application lifecycle only; no child memory read and no application exit-code inference"]
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
while Date() < deadline {
    if callbackReceived {
        if let launchError {
            fputs("LaunchServices failed: \(launchError)\n", stderr)
            finish(1, "launch-failed")
        }
        guard let launched else {
            fputs("LaunchServices returned no application\n", stderr)
            finish(1, "application-missing")
        }
        if launched.isTerminated { finish(0, "exited") }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
fputs("LaunchServices smoke app did not terminate within \(Int(timeout)) seconds\n", stderr)
if let launched, !launched.isTerminated {
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
finish(1, "timed-out")
