import AppKit
import Foundation

// Launch the real installed app without command-line operands. Cocoa can turn
// unknown arguments (especially an absolute report path) into an open-file
// request, suppressing the application's normal initial window.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: launch-smoke-app.swift APP REPORT\n", stderr)
    exit(64)
}
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
for key in ["PICSHOT_SMOKE_FORMULA_MODEL_DIR", "PICSHOT_SMOKE_FORMULA_INPUT", "PICSHOT_SMOKE_TABLE_MODEL_DIR", "PICSHOT_SMOKE_TABLE_INPUT"] {
    if let value = ProcessInfo.processInfo.environment[key] { configuration.environment?[key] = value }
}
var launched: NSRunningApplication?
var launchError: Error?
var callbackReceived = false
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
    DispatchQueue.main.async {
        launched = app
        launchError = error
        callbackReceived = true
    }
}
let deadline = Date().addingTimeInterval(90)
while Date() < deadline {
    if callbackReceived {
        if let launchError {
            fputs("LaunchServices failed: \(launchError)\n", stderr)
            exit(1)
        }
        guard let launched else {
            fputs("LaunchServices returned no application\n", stderr)
            exit(1)
        }
        if launched.isTerminated { exit(0) }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
fputs("LaunchServices smoke app did not terminate within 90 seconds\n", stderr)
launched?.terminate()
exit(1)
