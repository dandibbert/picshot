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
for key in ["PICSHOT_MANUAL_SCROLL_ONLY", "PICSHOT_MANUAL_SCROLL_RESOURCES", "PICSHOT_ANNOTATION_DETAILS_ONLY", "PICSHOT_AUTOMATIC_MOSAIC_ONLY", "PICSHOT_PIN_GROUP_TRANSFORMS_ONLY", "PICSHOT_LATEX_PIN_VERIFY", "PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY", "PICSHOT_SMOKE_FORMULA_MODEL_DIR", "PICSHOT_SMOKE_FORMULA_INPUT", "PICSHOT_SMOKE_TABLE_MODEL_DIR", "PICSHOT_SMOKE_TABLE_INPUT", "PICSHOT_SMOKE_ERASE_MODEL_DIR", "PICSHOT_UI_PREVIEW_ONLY", "PICSHOT_SMOKE_GIF_RESOURCES", "PICSHOT_GIF_DIAGNOSTIC_MODE", "PICSHOT_GIF_EXTRACTION", "PICSHOT_GIF_EXECUTION", "PICSHOT_CODEC_ATTRIBUTION_MODE", "PICSHOT_CODEC_ATTRIBUTION_FORMAT", "PICSHOT_CODEC_ATTRIBUTION_PROFILE", "PICSHOT_CODEC_ATTRIBUTION_INPUT_DIRECTORY", "PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_IMAGE_BACKING_FORMAT", "PICSHOT_IMAGE_BACKING_PROFILE", "PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY"] {
    if let value = ProcessInfo.processInfo.environment[key] { configuration.environment[key] = value }
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
let diagnosticMode = ProcessInfo.processInfo.environment["PICSHOT_GIF_DIAGNOSTIC_MODE"] ?? ""
let timeout: TimeInterval = ["export-only", "decode-only"].contains(diagnosticMode) ? 900 : 600
let deadline = Date().addingTimeInterval(timeout)
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
exit(1)
