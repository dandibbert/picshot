import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A narrow optional phase of the native demo. Acquisition is the unchanged
/// production LiveScrollScreenSource, never a screenshot call or injected image.
/// The separately launched target owns every pixel in the locked capture region.
@MainActor
enum LiveScrollRealStreamFixture {
    static func run(outputDirectory directory: URL, helperExecutable: URL? = nil) async -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let permission = CGPreflightScreenCaptureAccess()
        var report: [String: Any] = [
            "schemaVersion": 1, "status": "running", "captureMode": "real-screen-capture-kit-stream",
            "permissionAlreadyGranted": permission, "permissionRequested": false,
            "globalInputPosted": false, "privateUserContent": false, "ownedPixelInjectionUsed": false,
            "realScreenCaptureClaimed": false, "screenCaptureStarted": false,
            "productSessionControllerExercised": false, "helperLaunched": false, "acquisitionAttempted": false,
            "startedStreams": 0, "confirmedStops": 0, "shareableContentRequests": 0,
            "source": "LiveScrollScreenSource", "session": "LiveScrollSessionController",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "counterMeaning": "receivedFrames counts complete correctly sized buffers accepted by the mailbox; consumedFrames counts buffers taken by its serial reader. These are not a total callback census.",
            "scope": "Separate original AppKit plain-text target, normal cropped source, real product sampling/assembler and native mouse Finish action"
        ]
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { report["status"] = "failed"; report["error"] = error.localizedDescription; return report }
        guard permission else {
            report["status"] = "blocked"
            report["blocker"] = "CGPreflightScreenCaptureAccess returned false; no stream, target helper or OS permission request was started. Owned-pixel demo evidence is separate."
            report["sourceCounters"] = counters(LiveScrollFrameCounters())
            report["sessionSampledFrames"] = 0
            save(report, directory); return report
        }
        let configured = helperExecutable ?? ProcessInfo.processInfo.environment["PICSHOT_LIVE_SCROLL_TARGET"].map { URL(fileURLWithPath: $0) }
        guard let executable = configured, FileManager.default.isExecutableFile(atPath: executable.path) else {
            report["status"] = "blocked"
            report["blocker"] = "The separate owned target executable is missing. Build scripts/build-live-scroll-target.sh and pass its resulting executable via PICSHOT_LIVE_SCROLL_TARGET."
            save(report, directory); return report
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-owned-scroll-" + UUID().uuidString, isDirectory: true)
        let process = Process()
        var session: LiveScrollSessionController?
        var source: LiveScrollScreenSource?
        var completedImage: CGImage?
        var finishCallbacks = 0
        var latestTarget: [String: Any] = [:]
        var trace: [[String: Any]] = []
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            process.executableURL = executable; process.arguments = [temporary.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            report["helperLaunched"] = true; report["helperPID"] = process.processIdentifier
            try await wait(seconds: 3, message: "Owned target did not publish its ready window") {
                latestTarget = (try? target(temporary)) ?? [:]
                return latestTarget["status"] as? String == "ready" && latestTarget["referenceReady"] as? Bool == true
            }
            let pid = try integer(latestTarget, "pid"), windowID = try integer(latestTarget, "windowID")
            let displayID = CGDirectDisplayID(try integer(latestTarget, "displayID"))
            try require(pid == Int(process.processIdentifier) && pid != Int(ProcessInfo.processInfo.processIdentifier),
                        "Target metadata does not identify the launched separate process")
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                throw failure("Owned target display disappeared")
            }
            let region = try rectangle(latestTarget, "viewportDisplayPoints")
            let bounds = try rectangle(latestTarget, "windowGlobalCGPoints")
            let input = try LiveScrollScreenSource(displayID: displayID, region: region, screenSize: screen.frame.size,
                lockedTarget: .init(pid: pid_t(pid), windowID: CGWindowID(windowID), bounds: bounds))
            source = input
            let controller = LiveScrollSessionController(onComplete: { image in
                finishCallbacks += 1; completedImage = image
                try writePNG(image, directory.appendingPathComponent("live-scroll-real-stream-output.png"))
            }, onImport: {})
            session = controller
            report["acquisitionAttempted"] = true
            try await controller.startForVerification(source: input, screen: screen)
            report["screenCaptureStarted"] = input.startedStreams > 0
            report["productSessionControllerExercised"] = true
            try await wait(seconds: 2, message: "Real source produced no initial product sample") {
                controller.sampledFramesForVerification > 0 && controller.stateForVerification.acceptedObservations > 0
            }
            report["firstProductSampleMilliseconds"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            try Data().write(to: temporary.appendingPathComponent("start"), options: .atomic)
            let movementStarted = ProcessInfo.processInfo.systemUptime
            var previous = controller.stateForVerification
            var growths = 0, reverseMatches = 0, extendedAfterReverse = false
            var firstGrowth: TimeInterval?
            repeat {
                try Task.checkCancellation()
                try require(process.isRunning, "Owned target exited before the stream phase completed")
                latestTarget = try target(temporary)
                let state = controller.stateForVerification
                if state.height > previous.height {
                    growths += 1
                    if firstGrowth == nil { firstGrowth = ProcessInfo.processInfo.systemUptime - movementStarted }
                    if reverseMatches > 0 { extendedAfterReverse = true }
                }
                if state.acceptedObservations > previous.acceptedObservations && state.viewportOffset < previous.viewportOffset { reverseMatches += 1 }
                trace.append(["seconds": ProcessInfo.processInfo.systemUptime - movementStarted,
                    "targetOffsetPoints": latestTarget["offset"] ?? -1,
                    "targetStatus": latestTarget["status"] ?? "unknown",
                    "acceptedOffsetPixels": state.viewportOffset, "outputHeight": state.height,
                    "acceptedObservations": state.acceptedObservations, "matched": state.matched,
                    "sessionSamples": controller.sampledFramesForVerification,
                    "receivedFrames": input.counters.receivedFrames, "consumedFrames": input.counters.consumedFrames])
                previous = state
                try require(controller.snapshotForVerification.statusKind != .error,
                            "Product session reported: " + controller.snapshotForVerification.status)
                try require(ProcessInfo.processInfo.systemUptime - movementStarted < 18 && trace.count <= 200,
                            "Owned continuous movement exceeded its bounded phase")
                if latestTarget["status"] as? String == "finished" { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while true
            let scale = Double(input.counters.pixelWidth) / Double(region.width)
            let expectedOffset = Int(((latestTarget["expectedFinalOffset"] as? NSNumber)?.doubleValue ?? 1320) * scale)
            try await wait(seconds: 1.5, message: "The final owned viewport was not accepted by the product session") {
                abs(controller.stateForVerification.viewportOffset - expectedOffset) <= 1
            }
            let finalState = controller.stateForVerification
            report["trace"] = trace; report["target"] = latestTarget
            report["firstGrowingPreviewMilliseconds"] = (firstGrowth ?? -1) * 1000
            report["growingPreviewObservations"] = growths
            report["acceptedReverseObservations"] = reverseMatches
            report["extendedAfterReversal"] = extendedAfterReverse
            report["fixedHeaderDetectedPixels"] = finalState.fixedLeading
            report["finalAcceptedOffsetPixels"] = finalState.viewportOffset
            report["sessionSampledFrames"] = controller.sampledFramesForVerification
            guard let button = findButton("scroll.live.finish", in: controller.controlsForVerification?.toolbarWindow?.contentView) else {
                throw failure("Actual product Finish button was not found")
            }
            try PortableSettingsUIPreviewFixture.click(button)
            report["finishRoute"] = "PortableSettingsUIPreviewFixture.click; native hit-test and owned mouse down/up"
            try await wait(seconds: 5, message: "Product Finish did not deliver its output and retire the session") {
                completedImage != nil && controller.isClosedForVerification
            }
            guard let image = completedImage else { throw failure("Product Finish returned no image") }
            let referenceURL = directory.appendingPathComponent("live-scroll-real-stream-reference.png")
            if FileManager.default.fileExists(atPath: referenceURL.path) { try FileManager.default.removeItem(at: referenceURL) }
            try FileManager.default.copyItem(at: temporary.appendingPathComponent("reference.png"), to: referenceURL)
            guard let reader = CGImageSourceCreateWithURL(referenceURL as CFURL, nil),
                  let reference = CGImageSourceCreateImageAtIndex(reader, 0, nil) else { throw failure("Owned independent reference is unreadable") }
            let comparison = try compare(image, reference, scale: scale)
            report["referenceComparison"] = comparison
            report["output"] = ["width": image.width, "height": image.height, "file": "live-scroll-real-stream-output.png"]
            report["finishCallbacks"] = finishCallbacks
            report["sourceCounters"] = counters(input.counters)
            report["shareableContentRequests"] = input.shareableContentRequests
            report["startedStreams"] = input.startedStreams
            report["confirmedStops"] = input.confirmedStops
            report["realScreenCaptureClaimed"] = input.startedStreams > 0 && input.counters.receivedFrames > 0 && input.counters.consumedFrames > 0
            try require(input.counters.receivedFrames > 0 && input.counters.consumedFrames > 0 && controller.sampledFramesForVerification > 0,
                        "No positive production stream/consumer evidence")
            try require(growths >= 6 && reverseMatches >= 2 && extendedAfterReverse, "Continuous growth, reverse and further extension were not all observed")
            try require(finishCallbacks == 1 && comparison["passed"] as? Bool == true,
                        "Real product output failed independent plain-text reference/seam checks")
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["trace"] = trace; report["target"] = latestTarget
        }
        await session?.closeForVerification()
        if let source {
            report["sourceCounters"] = counters(source.counters)
            report["startedStreams"] = source.startedStreams; report["confirmedStops"] = source.confirmedStops
            report["shareableContentRequests"] = source.shareableContentRequests
            report["screenCaptureStarted"] = source.startedStreams > 0
            report["realScreenCaptureClaimed"] = source.startedStreams > 0 && source.counters.receivedFrames > 0 && source.counters.consumedFrames > 0
        }
        report["finishCallbacks"] = finishCallbacks
        report["sessionSampledFrames"] = session?.sampledFramesForVerification ?? 0
        try? Data().write(to: temporary.appendingPathComponent("stop"), options: .atomic)
        if process.isRunning { try? await wait(seconds: 0.8, message: "Cooperative helper exit") { !process.isRunning } }
        if process.isRunning {
            process.terminate()
            try? await wait(seconds: 1.5, message: "Owned helper termination") { !process.isRunning }
        }
        let helperExited = !process.isRunning
        if helperExited { try? FileManager.default.removeItem(at: temporary) }
        let cleaned = helperExited && !FileManager.default.fileExists(atPath: temporary.path)
        let closed = session?.isClosedForVerification ?? true
        let drained = source.map { $0.state == .stopped && $0.counters.pendingFrames == 0 && $0.counters.waitingReaders == 0 } ?? true
        report["cleanup"] = ["helperExited": helperExited, "temporaryDirectoryRemoved": cleaned,
                             "sessionClosed": closed, "sourceStoppedAndDrained": drained]
        if !(cleaned && closed && drained) { report["status"] = "failed"; report["cleanupFailure"] = true }
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        save(report, directory)
        return report
    }

    private static func counters(_ c: LiveScrollFrameCounters) -> [String: Any] {
        ["receivedFrames": c.receivedFrames, "consumedFrames": c.consumedFrames,
         "replacedFrames": c.replacedFrames, "rejectedFrames": c.rejectedFrames,
         "incompleteFrames": c.incompleteFrames, "idleTimeouts": c.idleTimeouts,
         "pendingFrames": c.pendingFrames, "peakPendingFrames": c.peakPendingFrames,
         "waitingReaders": c.waitingReaders, "pixelWidth": c.pixelWidth, "pixelHeight": c.pixelHeight,
         "streamQueueDepth": c.streamQueueDepth]
    }
    private static func target(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("target.json"))
        try require(data.count <= 160_000, "Owned target metadata exceeded its bound")
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("Invalid owned target metadata") }
        return result
    }
    private static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = object[key] as? NSNumber else { throw failure("Missing owned target field: " + key) }
        return value.intValue
    }
    private static func rectangle(_ object: [String: Any], _ key: String) throws -> CGRect {
        guard let value = object[key] as? [String: NSNumber], let x = value["x"], let y = value["y"],
              let width = value["width"], let height = value["height"] else { throw failure("Missing target rectangle: " + key) }
        return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
    }
    private static func wait(seconds: Double, message: String, until predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            try Task.checkCancellation()
            try require(ProcessInfo.processInfo.systemUptime < deadline, message)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    private static func findButton(_ identifier: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
        for child in view.subviews { if let found = findButton(identifier, in: child) { return found } }
        return nil
    }
    /// Full-document reference comparison, plus every 8-point horizontal band.
    /// Ink-only mismatch prevents a mostly white image from passing accidentally;
    /// tight per-band checks expose missing/repeated text or an incorrect join.
    /// Tolerance is for SCK/AppKit font antialiasing and color conversion only.
    private static func compare(_ image: CGImage, _ reference: CGImage, scale: Double) throws -> [String: Any] {
        guard image.width == reference.width && image.height == reference.height else {
            return ["passed": false, "dimensionsMatch": false, "actualWidth": image.width, "actualHeight": image.height,
                    "expectedWidth": reference.width, "expectedHeight": reference.height]
        }
        let actual = try pixels(image), expected = try pixels(reference)
        let width = image.width, height = image.height, bandHeight = max(1, Int(8 * scale))
        var totalDifference: UInt64 = 0, mismatches = 0, ink = 0, mismatchedInk = 0
        var bands: [[String: Any]] = [], failedBands = 0
        for start in stride(from: 0, to: height, by: bandHeight) {
            let end = min(height, start + bandHeight)
            var bandInk = 0, bandMismatch = 0
            for y in start..<end {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let red = abs(Int(actual[i]) - Int(expected[i]))
                    let green = abs(Int(actual[i + 1]) - Int(expected[i + 1]))
                    let blue = abs(Int(actual[i + 2]) - Int(expected[i + 2]))
                    totalDifference += UInt64(red + green + blue)
                    let dark = min(actual[i], expected[i]) < 200
                    if dark { ink += 1; bandInk += 1 }
                    if max(red, max(green, blue)) > 40 {
                        mismatches += 1
                        if dark { mismatchedInk += 1; bandMismatch += 1 }
                    }
                }
            }
            let fraction = Double(bandMismatch) / Double(max(1, bandInk))
            let passed = bandInk < Int(20 * scale * scale) || fraction <= 0.35
            if !passed { failedBands += 1 }
            bands.append(["startRow": start, "endRowExclusive": end, "inkPixels": bandInk,
                          "mismatchedInkFraction": fraction, "passed": passed])
        }
        let mean = Double(totalDifference) / Double(width * height * 3)
        let mismatchFraction = Double(mismatches) / Double(width * height)
        let inkFraction = Double(mismatchedInk) / Double(max(1, ink))
        return ["passed": mean <= 4 && mismatchFraction <= 0.025 && inkFraction <= 0.22 && failedBands == 0 && ink > width,
            "dimensionsMatch": true, "meanAbsoluteRGBError": mean, "mismatchedPixelFraction": mismatchFraction,
            "mismatchedInkFraction": inkFraction, "inkPixels": ink, "failedHorizontalBands": failedBands,
            "horizontalBands": bands, "bandHeightPixels": bandHeight,
            "limits": ["meanAbsoluteRGBError": 4.0, "mismatchedPixelFraction": 0.025,
                       "mismatchedInkFraction": 0.22, "perBandMismatchedInkFraction": 0.35],
            "referenceSource": "Independent native rendering of the helper's complete numbered article and single fixed header; no output pixels reused"]
    }
    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Cannot allocate comparison pixels") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private static func writePNG(_ image: CGImage, _ url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw failure("Cannot create stream output PNG") }
        CGImageDestinationAddImage(writer, image, nil)
        try require(CGImageDestinationFinalize(writer), "Cannot finish stream output PNG")
    }
    private static func save(_ report: [String: Any], _ directory: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("live-scroll-real-stream.json"), options: .atomic)
        }
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw failure(message) }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PicShot.LiveScrollRealStream", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
