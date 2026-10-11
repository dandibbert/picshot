import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import PicShotCore

/// A product demo, not a replacement for the core acceptance fixtures. Every pixel
/// belongs to this app's numbered document or actual compact capture controls.
/// Screen capture is attempted only when permission was ALREADY granted. Otherwise
/// owned AppKit viewport pixels are injected, and that limitation is in every report.
@MainActor
enum LiveScrollUsabilityDemoFixture {
    private static let width = 640
    private static let height = 480
    private static let headerHeight = 36
    private static let duration = 15.0

    /// Main route: the actual product session owns frame acquisition, matching,
    /// presentation state, pause/resume, and Finish. The fixture supplies only an
    /// owned source window/frame provider, native wheel input and observations.
    static func verify(evidenceDirectory directory: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = ProcessInfo.processInfo.systemUptime
        let permitted = CGPreflightScreenCaptureAccess()
        let screen = try unwrap(NSScreen.main, "Native demo requires an available display")
        let visible = screen.visibleFrame
        let window = NSWindow(contentRect: CGRect(x: visible.midX - 390, y: visible.midY - 200,
            width: CGFloat(width), height: CGFloat(height)), styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "PicShot · Native continuous-scroll document"
        window.isReleasedWhenClosed = false; window.hasShadow = false
        window.backgroundColor = .white; window.appearance = NSAppearance(named: .aqua)
        let viewport = DemoViewport(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.contentView = viewport; window.orderFrontRegardless(); window.displayIfNeeded()
        defer { window.close() }
        try writePNG(try nativeImage(viewport), directory.appendingPathComponent("live-scroll-native-first-viewport.png"))
        let firstPixelsMS = milliseconds(since: start)
        let capture = try await CaptureSource.make(window: window, viewport: viewport, permitted: permitted)
        var report: [String: Any] = ["schemaVersion": 2, "status": "running",
            "productSessionControllerExercised": true, "permissionAlreadyGranted": permitted,
            "permissionRequested": false, "globalInputPosted": false, "privateUserContent": false,
            "networkUsed": false, "captureMode": "production-session-with-owned-frame-provider",
            "ownedFrameAcquisitionMode": capture.mode,
            "ownedWindowScreenshotAcquisitionStarted": capture.screenCaptureStarted,
            "realScreenCaptureClaimed": false, "realScreenCaptureValidated": false,
            "sourceBoundary": "Owned-window cases inject a frame provider into the production session; only the separately reported realStream phase can validate production SCStream delivery. No phase requests TCC permission.",
            "firstNativeWindowPixelsMilliseconds": firstPixelsMS,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown"]
        if !capture.screenCaptureStarted { report["limitation"] = capture.reason }
        try writeReport(report, directory)
        let illustrated = await productCycle(viewport: viewport, window: window, screen: screen,
            capture: capture, directory: directory, plain: false)
        report["illustratedCase"] = illustrated
        try writeReport(report, directory)
        guard illustrated["productSessionClosed"] as? Bool == true else {
            report["status"] = "failed"
            report["ordinaryTextCase"] = ["status": "blocked", "reason": "Prior owned product session did not close"]
            try writeReport(report, directory)
            throw DemoFailure(errorDescription: "Previous native demo session cleanup was not confirmed")
        }
        let plain = await productCycle(viewport: viewport, window: window, screen: screen,
            capture: capture, directory: directory, plain: true)
        report["ordinaryTextCase"] = plain
        let realStream: [String: Any]
        if plain["productSessionClosed"] as? Bool == true {
            realStream = await LiveScrollRealStreamFixture.run(outputDirectory: directory.appendingPathComponent("real-stream"))
        } else {
            realStream = ["status": "blocked", "permissionAlreadyGranted": permitted,
                          "blocker": "Previous owned product session cleanup was not confirmed",
                          "realScreenCaptureClaimed": false]
        }
        report["realStream"] = realStream
        report["realScreenCaptureClaimed"] = realStream["realScreenCaptureClaimed"] as? Bool ?? false
        report["realScreenCaptureValidated"] = realStream["status"] as? String == "passed"
        if realStream["status"] as? String == "blocked" {
            report["realScreenCaptureBlocker"] = realStream["blocker"] as? String ?? "Real stream phase blocked"
        }
        let realPermission = realStream["permissionAlreadyGranted"] as? Bool ?? permitted
        let realOutcomeAcceptable = realStream["status"] as? String == "passed"
            || (realStream["status"] as? String == "blocked" && !realPermission)
        let passed = illustrated["status"] as? String == "passed" && plain["status"] as? String == "passed"
            && realOutcomeAcceptable
        report["status"] = passed ? "passed" : "failed"
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
        try writeReport(report, directory)
        try require(passed, "Product-session demo failed; preserved per-case reports and native pixels identify the failure")
        return report
    }

    private static func productCycle(viewport: DemoViewport, window: NSWindow, screen: NSScreen,
                                     capture: CaptureSource, directory: URL, plain: Bool) async -> [String: Any] {
        let prefix = plain ? "live-scroll-plain-text" : "live-scroll"
        let start = ProcessInfo.processInfo.systemUptime
        var completedImage: CGImage?, completedCount = 0, frameRequests = 0
        let session = LiveScrollSessionController(onComplete: { image in
            completedImage = image; completedCount += 1
        }, onImport: {})
        var wheel: Task<Void, Error>?
        var report: [String: Any] = ["status": "running", "productSessionControllerExercised": true,
            "addedAlignmentMarkers": !plain, "captureMode": capture.mode,
            "scope": plain ? "ordinary numbered native text on white" : "numbered native rich document",
            "sessionSamplingLoopReimplementedByFixture": false,
            "buttonInputRoute": "accepted native hit-test/mouse helper PortableSettingsUIPreviewFixture.click"]
        do {
            try scroll(viewport.scrollView, pixels: -Int(viewport.offset.rounded()))
            viewport.document.illustrated = !plain
            let initial = try await capture.image()
            try await session.startForVerification(targetFrame: window.frame, screen: screen, nextImage: {
                try await Task.sleep(nanoseconds: 66_666_667)
                frameRequests += 1
                return try await capture.image()
            })
            try await waitFor("Product session did not produce its first preview", timeout: 6) {
                session.stateForVerification.acceptedObservations > 0
            }
            let controls = try unwrap(session.controlsForVerification, "Product session did not install capture controls")
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow] {
                panel?.appearance = NSAppearance(named: .aqua)
            }
            let thumbnail = try unwrap(controls.previewWindow?.contentView as? LiveScrollThumbnailView,
                                       "Product session thumbnail is missing")
            let firstMarker = thumbnail.viewportMarker
            report["firstPreviewMilliseconds"] = milliseconds(since: start)
            try writePNG(try scene(window: window, controls: controls,
                caption: plain ? "Ordinary text · actual PicShot session" : "PicShot · actual live-scroll session"),
                directory.appendingPathComponent(prefix + "-native-first-window.png"))
            var done = false, events = 0, direction = 1
            var maxOffset = 0.0, lastArtifact = -1.0
            var firstGrowth: Double?
            var growths = 0, reverseUpdates = 0, observedUpdates = 0
            var extendedAfterReverse = false
            var lastAccepted = session.stateForVerification.acceptedObservations
            var lastHeight = session.stateForVerification.height
            var story: [CGImage] = [], trace: [[String: Any]] = []
            let totalEvents = plain ? 180 : 450
            let inputStart = ProcessInfo.processInfo.systemUptime
            wheel = Task { @MainActor in
                for index in 0..<totalEvents {
                    try Task.checkCancellation()
                    direction = !plain && (180..<240).contains(index) ? -1 : 1
                    try scroll(viewport.scrollView, pixels: direction * 4)
                    events += 1; maxOffset = max(maxOffset, Double(viewport.offset))
                    try await Task.sleep(nanoseconds: 33_333_333)
                }
                done = true
            }
            while !done {
                let state = session.stateForVerification
                if state.acceptedObservations > lastAccepted {
                    observedUpdates += 1
                    if direction < 0 { reverseUpdates += 1 }
                    lastAccepted = state.acceptedObservations
                }
                if state.height > lastHeight {
                    growths += 1; lastHeight = state.height
                    if firstGrowth == nil { firstGrowth = milliseconds(since: inputStart) }
                    if !plain && events > 240 { extendedAfterReverse = true }
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - inputStart
                trace.append(["seconds": elapsed, "nativeOffset": viewport.offset,
                    "acceptedOffset": state.viewportOffset, "outputHeight": state.height,
                    "acceptedObservations": state.acceptedObservations, "matched": state.matched,
                    "nativeWheelEvents": events, "direction": direction,
                    "productStatus": session.snapshotForVerification.status])
                if elapsed - lastArtifact >= 0.5, story.count < 36 {
                    let image = try scene(window: window, controls: controls,
                        caption: String(format: "%.1f s · %@ · %d px · actual PicShot session", elapsed,
                                        direction < 0 ? "scrolling back" : "scrolling", state.height))
                    story.append(image); lastArtifact = elapsed
                    try writePNG(image, directory.appendingPathComponent(String(format: prefix + "-frame-%02d.png", story.count)))
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(elapsed < (plain ? 18 : 32), "Native product demo exceeded its input deadline")
            }
            try await wheel?.value; wheel = nil
            let continuousSeconds = ProcessInfo.processInfo.systemUptime - inputStart
            report["continuousSeconds"] = continuousSeconds
            report["nativeWheelEvents"] = events
            report["inputRoute"] = "Owned NSScrollView.scrollWheel(with:) with native pixel NSEvents; no global posting"
            report["settleDetectorUsed"] = false
            report["firstGrowthMilliseconds"] = firstGrowth ?? -1
            report["observedGrowingPreviewUpdates"] = growths
            report["observedPreviewUpdates"] = observedUpdates
            report["acceptedReverseObservations"] = reverseUpdates
            report["extendedAfterReversal"] = extendedAfterReverse
            report["trace"] = trace
            // Synchronize only the terminal assertions. Acquisition updated throughout
            // the continuous input above; no stop/settle gate feeds the product loop.
            try await waitFor("Final native viewport was not joined", timeout: 5) {
                session.stateForVerification.viewportOffset == Int(viewport.offset.rounded())
            }
            if !plain {
                let pause = try unwrap(findButton("scroll.live.pauseResume", in: controls.toolbarWindow?.contentView),
                                       "Actual Pause button missing")
                try require(pause.isEnabled, "Actual Pause button disabled during capture")
                try PortableSettingsUIPreviewFixture.click(pause)
                try await waitFor("Actual Pause did not drain", timeout: 5) {
                    session.snapshotForVerification.paused && !session.snapshotForVerification.busy
                }
                let pausedRequests = frameRequests
                let pausedState = session.stateForVerification
                try scroll(viewport.scrollView, pixels: 48)
                try await Task.sleep(nanoseconds: 220_000_000)
                let pausePreserved = frameRequests == pausedRequests
                    && session.stateForVerification.viewportOffset == pausedState.viewportOffset
                try PortableSettingsUIPreviewFixture.click(pause)
                try await waitFor("Actual Resume did not rejoin", timeout: 5) {
                    !session.snapshotForVerification.paused
                        && session.stateForVerification.viewportOffset == Int(viewport.offset.rounded())
                }
                report["pauseStoppedFrameRequestsAndPreservedOutput"] = pausePreserved
                report["resumeRejoinedNativeViewport"] = true
                let retainedState = session.stateForVerification
                let retainedImage = try unwrap(thumbnail.image, "No retained thumbnail before gap")
                let retainedPixels = try normalizedPixels(retainedImage)
                let retainedOffset = viewport.offset
                try scroll(viewport.scrollView, pixels: height * 2)
                try await waitFor("Product session did not warn about the non-overlapping gap", timeout: 5) {
                    !session.stateForVerification.matched
                }
                let afterGap = session.stateForVerification
                let afterGapPixels = try normalizedPixels(try unwrap(thumbnail.image, "Gap removed the retained thumbnail"))
                let preserved = afterGap.height == retainedState.height && afterGap.viewportOffset == retainedState.viewportOffset
                    && afterGapPixels == retainedPixels
                try writePNG(try scene(window: window, controls: controls,
                    caption: "Gap warning · actual session retains the last valid long image"),
                    directory.appendingPathComponent("live-scroll-gap-recovery.png"))
                try scroll(viewport.scrollView, pixels: Int((retainedOffset - viewport.offset).rounded()))
                try await waitFor("Product session did not recover retained overlap", timeout: 5) {
                    session.stateForVerification.matched
                }
                try scroll(viewport.scrollView, pixels: 48)
                try await waitFor("Product session did not extend after recovery", timeout: 5) {
                    session.stateForVerification.viewportOffset == Int(viewport.offset.rounded())
                }
                report["gapRejected"] = true; report["gapPreservedLastValidPreviewAndState"] = preserved
                report["gapRecoveryMatched"] = true
                try require(pausePreserved && preserved, "Pause or gap changed the retained output")
            }
            maxOffset = max(maxOffset, Double(viewport.offset))
            let finalState = session.stateForVerification
            let finalMarker = thumbnail.viewportMarker
            report["fixedHeaderDetectedPixels"] = finalState.fixedLeading
            report["actualPreviewUpdates"] = finalState.acceptedObservations
            report["viewportMarkerPresentAtStartAndEnd"] = firstMarker != nil && finalMarker != nil
            report["viewportMarkerShrankAsDocumentGrew"] = (finalMarker?.height ?? .infinity) < (firstMarker?.height ?? 0)
            let finalScene = try scene(window: window, controls: controls, caption: "Ready to finish · actual PicShot session")
            story.append(finalScene)
            try writePNG(finalScene, directory.appendingPathComponent(prefix + "-native-finished-window.png"))
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow] {
                panel?.appearance = NSAppearance(named: .darkAqua)
            }
            try writePNG(try scene(window: window, controls: controls, caption: "Dark appearance · actual PicShot session"),
                         directory.appendingPathComponent(prefix + "-native-dark-controls.png"))
            try writeGIF(story, directory.appendingPathComponent(prefix + "-interaction.gif"))
            try writePNG(try contactSheet(story), directory.appendingPathComponent(prefix + "-contact-sheet.png"))
            let finish = try unwrap(findButton("scroll.live.finish", in: controls.toolbarWindow?.contentView),
                                    "Actual Finish button missing")
            try require(finish.isEnabled, "Actual Finish button disabled with retained output")
            try PortableSettingsUIPreviewFixture.click(finish)
            try await waitFor("Actual Finish did not deliver its completion image", timeout: 8) { completedImage != nil }
            let output = try unwrap(completedImage, "Actual Finish returned no image")
            try writePNG(output, directory.appendingPathComponent(prefix + "-finished.png"))
            report["finishButtonCompletionCallbacks"] = completedCount
            report["outputWidth"] = output.width; report["outputHeight"] = output.height
            report["frameProviderCalls"] = frameRequests
            if plain {
                let reference = try plainTextReference(initial: initial, totalHeight: height + Int(maxOffset.rounded()))
                try writePNG(reference, directory.appendingPathComponent(prefix + "-reference.png"))
                let comparison = try nativeRasterComparison(output, reference)
                report["nativeReferenceComparison"] = comparison
                try require(comparison["passed"] as? Bool == true, "Ordinary text output differs from independent native document reference")
            } else {
                let coverage = try numberedCoverage(output: output, expectedOffset: Int(maxOffset.rounded()))
                report["numberedCoverage"] = coverage
                try require(coverage["passed"] as? Bool == true, "Product Finish has missing or duplicated numbered coverage")
                try require(reverseUpdates >= 2 && extendedAfterReverse, "Product session failed reversal then extension")
            }
            try require(events == totalEvents && continuousSeconds >= (plain ? 6 : 15), "Continuous native input was incomplete")
            try require(growths >= (plain ? 3 : 8) && (firstGrowth ?? .infinity) < 2000, "Actual growing preview was too slow or absent")
            try require(finalState.fixedLeading == headerHeight, "Actual session did not preserve the sticky header exactly once")
            try require(completedCount == 1 && firstMarker != nil && finalMarker != nil, "Actual Finish or viewport marker failed")
            report["status"] = "passed"
        } catch {
            wheel?.cancel(); try? await wheel?.value
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["productStatus"] = session.snapshotForVerification.status
            report["retainedOutputHeight"] = session.stateForVerification.height
            if let controls = session.controlsForVerification,
               let image = try? scene(window: window, controls: controls, caption: "Actual product-session failure; retained native UI") {
                try? writePNG(image, directory.appendingPathComponent(prefix + "-failure.png"))
            }
        }
        report["productSampledFrames"] = session.sampledFramesForVerification
        await session.closeForVerification()
        report["productSessionClosed"] = session.isClosedForVerification
        if !session.isClosedForVerification {
            report["status"] = "failed"
            report["cleanupError"] = "Product session did not report closed after bounded closeForVerification"
        }
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent(prefix + "-product-session.json"), options: .atomic)
        }
        return report
    }

    private static func nativeRasterComparison(_ output: CGImage, _ reference: CGImage) throws -> [String: Any] {
        let actual = try normalizedPixels(output), expected = try normalizedPixels(reference)
        let dimensions = output.width == reference.width && output.height == reference.height
        var total: UInt64 = 0, bad = 0
        if dimensions {
            actual.withUnsafeBytes { aa in expected.withUnsafeBytes { bb in
                let a = aa.bindMemory(to: UInt8.self), b = bb.bindMemory(to: UInt8.self)
                for index in 0..<a.count {
                    let delta = abs(Int(a[index]) - Int(b[index])); total += UInt64(delta)
                    if delta > 8 { bad += 1 }
                }
            } }
        }
        let mean = dimensions ? Double(total) / Double(max(1, actual.count)) : -1
        let fraction = dimensions ? Double(bad) / Double(max(1, actual.count)) : 1
        return ["passed": dimensions && mean <= 0.5 && fraction <= 0.001,
            "exactEquality": actual == expected, "dimensionsMatch": dimensions,
            "expectedHeight": reference.height, "actualHeight": output.height,
            "meanAbsoluteRGBAError": mean, "fractionOfChannelsDifferingByMoreThan8": fraction]
    }

    private static func waitFor(_ message: String, timeout: Double,
                                condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, message)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    static func verifyAssemblerDemo(evidenceDirectory directory: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = ProcessInfo.processInfo.systemUptime
        let permitted = CGPreflightScreenCaptureAccess()
        var report: [String: Any] = [
            "schemaVersion": 1, "status": "running", "permissionAlreadyGranted": permitted,
            "permissionRequested": false, "globalInputPosted": false, "networkUsed": false,
            "privateUserContent": false, "durationRequestedSeconds": duration,
            "scope": "Owned native NSScrollView with continuous wheel NSEvents, real compact PicShot HUD and growing thumbnail; reverse, gap recovery and final numbered-document coverage",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "captureMode": "undetermined",
            "productSessionControllerExercised": false,
            "sessionBoundary": "Real compact HUD and LiveScrollAssembler, with fixture-owned acquisition/input tasks; this pass does not validate LiveScrollSessionController acquisition, pause, auto-scroll or finish routing"
        ]
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = CGRect(x: visible.midX - 390, y: visible.midY - 200, width: CGFloat(width), height: CGFloat(height))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "PicShot · Continuous scroll demo"
        window.isReleasedWhenClosed = false; window.hasShadow = false
        window.backgroundColor = .white; window.appearance = NSAppearance(named: .aqua)
        let viewport = DemoViewport(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.contentView = viewport
        window.orderFrontRegardless(); window.displayIfNeeded()
        var finishClicks = 0
        var actions = LiveScrollCaptureActions()
        actions.finishEdit = { finishClicks += 1 }
        let controls = LiveScrollCaptureController(actions: actions)
        for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow] {
            panel?.appearance = NSAppearance(named: .aqua)
        }
        var snapshot = LiveScrollCaptureSnapshot()
        snapshot.status = "持续滚动 · 原生文档演示"
        snapshot.showsAutoScroll = false; snapshot.canMoveRegion = false; snapshot.canImport = false
        snapshot.canChangeAxis = false
        controls.show(snapshot: snapshot, targetFrame: window.frame, visibleFrame: visible)
        defer { controls.teardown(); window.close() }
        let assembler = LiveScrollAssembler(axis: .vertical, generation: 1)
        var wheel: Task<Void, Error>?
        do {
            // Save useful native pixels first, even if a later algorithm assertion fails.
            let firstView = try nativeImage(viewport)
            try writePNG(firstView, directory.appendingPathComponent("live-scroll-native-first-viewport.png"))
            try writePNG(try scene(window: window, controls: controls, caption: "PicShot · live scroll / native window"),
                         directory.appendingPathComponent("live-scroll-native-first-window.png"))
            report["firstNativeWindowPixelsMilliseconds"] = milliseconds(since: started)
            try writeReport(report, directory)
            let capture = try await CaptureSource.make(window: window, viewport: viewport, permitted: permitted)
            report["captureMode"] = capture.mode
            report["screenCaptureStarted"] = capture.screenCaptureStarted
            if !capture.screenCaptureStarted {
                report["limitation"] = capture.reason
                report["realScreenCaptureClaimed"] = false
            }
            let first = try await capture.image()
            var latest = try await assembler.observe(first)
            apply(latest, to: controls, snapshot: &snapshot)
            let firstPreviewMS = milliseconds(since: started)
            let initialMarker = (controls.previewWindow?.contentView as? LiveScrollThumbnailView)?.viewportMarker
            var firstGrowthMS: Double?
            var previewUpdates = latest.preview == nil ? 0 : 1
            var accepted = latest.state.acceptedObservations
            var growingUpdates = 0
            var movementDuringMatch = 0
            var reverseAccepted = 0
            var extensionAfterReverse = false
            var trace: [[String: Any]] = []
            var story: [CGImage] = []
            var lastStoryTime = -1.0
            var inputFinished = false
            var delivered = 0
            var largestY = 0.0
            var lastDirection = 1
            let scrollingStarted = ProcessInfo.processInfo.systemUptime
            wheel = Task { @MainActor in
                for index in 0..<450 {
                    try Task.checkCancellation()
                    // 0–6 s down; 6–8 s up over known content; 8–15 s down past the frontier.
                    let direction = (180..<240).contains(index) ? -1 : 1
                    lastDirection = direction
                    try scroll(viewport.scrollView, pixels: direction * 4)
                    delivered += 1
                    largestY = max(largestY, Double(viewport.offset))
                    try await Task.sleep(nanoseconds: 33_333_333)
                }
                inputFinished = true
            }
            while !inputFinished {
                let offset = viewport.offset
                let inputBefore = delivered
                let captured = try await capture.image()
                let previousHeight = latest.state.height
                let update = try await assembler.observe(captured)
                if delivered > inputBefore { movementDuringMatch += 1 }
                if update.state.acceptedObservations > accepted {
                    accepted = update.state.acceptedObservations
                    if lastDirection < 0 { reverseAccepted += 1 }
                }
                if update.preview != nil { previewUpdates += 1 }
                if update.state.height > previousHeight {
                    growingUpdates += 1
                    if firstGrowthMS == nil { firstGrowthMS = milliseconds(since: scrollingStarted) }
                    if delivered > 240 { extensionAfterReverse = true }
                }
                latest = update; apply(update, to: controls, snapshot: &snapshot)
                let elapsed = ProcessInfo.processInfo.systemUptime - scrollingStarted
                trace.append(["seconds": elapsed, "nativeViewportOffset": offset,
                              "acceptedOffset": update.state.viewportOffset, "outputHeight": update.state.height,
                              "acceptedObservations": update.state.acceptedObservations,
                              "previewUpdated": update.preview != nil, "matched": update.state.matched,
                              "wheelEvents": delivered, "direction": lastDirection])
                if elapsed - lastStoryTime >= 0.5, story.count < 36 {
                    let caption = String(format: "%.1f s · %@ · %d px · %d updates", elapsed,
                                         lastDirection < 0 ? "returning over captured rows" : "scrolling continuously",
                                         update.state.height, previewUpdates)
                    let image = try scene(window: window, controls: controls, caption: caption)
                    story.append(image); lastStoryTime = elapsed
                    try writePNG(image, directory.appendingPathComponent(String(format: "live-scroll-frame-%02d.png", story.count)))
                    if story.count == 3 {
                        report["earlyPreviewUpdates"] = previewUpdates
                        report["earlyOutputHeight"] = update.state.height
                        try writeReport(report, directory)
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(elapsed < 32, "Continuous input exceeded the bounded demo deadline")
            }
            try await wheel?.value
            wheel = nil
            // Capture the final event without waiting for a stop/settle detector.
            latest = try await assembler.observe(capture.image())
            apply(latest, to: controls, snapshot: &snapshot)
            let scrollingElapsed = ProcessInfo.processInfo.systemUptime - scrollingStarted
            let beforeGap = try await assembler.finish()
            try writePNG(beforeGap, directory.appendingPathComponent("live-scroll-last-good-before-gap.png"))
            let beforeGapBytes = try normalizedPixels(beforeGap)
            let oldOffset = viewport.offset
            let oldState = await assembler.currentState()
            try scroll(viewport.scrollView, pixels: height * 2)
            let rejected = try await assembler.observe(capture.image())
            apply(rejected, to: controls, snapshot: &snapshot)
            let afterGap = try await assembler.finish()
            let gapPreserved = try normalizedPixels(afterGap) == beforeGapBytes
            let rejectedGap = !rejected.state.matched
            try writePNG(try scene(window: window, controls: controls,
                                   caption: "Gap · last valid output is retained; scroll back to reconnect"),
                         directory.appendingPathComponent("live-scroll-gap-recovery.png"))
            // Send the reverse wheel event to the same native control; no scrollTo workaround.
            try scroll(viewport.scrollView, pixels: Int((oldOffset - viewport.offset).rounded()))
            let recovered = try await assembler.observe(capture.image())
            apply(recovered, to: controls, snapshot: &snapshot)
            try require(abs(viewport.offset - oldOffset) <= 1, "Native wheel return missed the retained overlap")
            try scroll(viewport.scrollView, pixels: 48)
            latest = try await assembler.observe(capture.image())
            apply(latest, to: controls, snapshot: &snapshot)
            largestY = max(largestY, Double(viewport.offset))
            let output = try await assembler.finish()
            try writePNG(output, directory.appendingPathComponent("live-scroll-finished.png"))
            let coverage = try numberedCoverage(output: output, expectedOffset: Int(largestY.rounded()))
            let finalMarker = (controls.previewWindow?.contentView as? LiveScrollThumbnailView)?.viewportMarker
            let finalScene = try scene(window: window, controls: controls,
                                       caption: "Finished · numbered rows preserved once, sticky header once")
            story.append(finalScene)
            try writePNG(finalScene, directory.appendingPathComponent("live-scroll-native-finished-window.png"))
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow] {
                panel?.appearance = NSAppearance(named: .darkAqua)
            }
            try writePNG(try scene(window: window, controls: controls, caption: "Dark controls · growing preview and viewport marker"),
                         directory.appendingPathComponent("live-scroll-native-dark-controls.png"))
            try writeGIF(story, directory.appendingPathComponent("live-scroll-interaction.gif"))
            try writePNG(try contactSheet(story), directory.appendingPathComponent("live-scroll-contact-sheet.png"))
            if let button = findButton("scroll.live.finish", in: controls.toolbarWindow?.contentView) {
                button.performClick(nil)
            }
            report["continuousSeconds"] = scrollingElapsed
            report["inputEventsDeliveredToNativeView"] = delivered + 3
            report["inputRoute"] = "CGEvent pixel scrollWheel converted to NSEvent; owned NSScrollView.scrollWheel(with:) invokes AppKit's native scrolling implementation; no global posting"
            report["settleDetectorUsed"] = false
            report["firstPreviewMilliseconds"] = firstPreviewMS
            report["firstGrowingPreviewMillisecondsFromInput"] = firstGrowthMS ?? -1
            report["previewUpdates"] = previewUpdates
            report["growingPreviewUpdates"] = growingUpdates
            report["samplesWhoseMatchingOverlappedInput"] = movementDuringMatch
            report["acceptedReverseObservations"] = reverseAccepted
            report["extendedAfterReversal"] = extensionAfterReverse
            report["fixedHeaderDetectedPixels"] = latest.state.fixedLeading
            report["gapRejected"] = rejectedGap
            report["gapPreservedLastValidOutput"] = gapPreserved
            report["gapRecoveryMatched"] = recovered.state.matched
            report["gapPreservedAcceptedOffset"] = rejected.state.viewportOffset == oldState.viewportOffset
            report["numberedCoverage"] = coverage
            report["finishButtonCallbacks"] = finishClicks
            report["nativeAppearancesRendered"] = ["aqua", "darkAqua"]
            report["viewportMarkerPresentAtStartAndEnd"] = initialMarker != nil && finalMarker != nil
            report["viewportMarkerShrankAsDocumentGrew"] = (finalMarker?.height ?? .infinity) < (initialMarker?.height ?? 0)
            report["trace"] = trace
            report["output"] = ["width": output.width, "height": output.height,
                                "file": "live-scroll-finished.png", "storyFrames": story.count]
            try writeReport(report, directory)
            let ordinaryText = try await ordinaryTextCycle(viewport: viewport, window: window, controls: controls,
                                                           capture: capture, directory: directory)
            report["ordinaryTextCase"] = ordinaryText
            try writeReport(report, directory)
            try require(delivered == 450 && scrollingElapsed >= 15, "Native continuous-input duration was incomplete")
            try require(previewUpdates >= 12 && growingUpdates >= 8, "Growing preview failed to update during input")
            try require((firstGrowthMS ?? .infinity) < 2000, "First growing preview was too slow")
            try require(reverseAccepted >= 2 && extensionAfterReverse, "Reverse then extend was not observed")
            try require(latest.state.fixedLeading == headerHeight, "Sticky header was not isolated exactly once")
            try require(rejectedGap && gapPreserved && recovered.state.matched,
                        "Gap recovery discarded the last valid output or failed to rejoin")
            try require(finishClicks == 1, "Actual compact HUD finish button did not invoke its action")
            try require(initialMarker != nil && finalMarker != nil, "Native viewport marker was absent")
            try require(coverage["passed"] as? Bool == true, "Finished numbered coverage has missing or repeated rows")
            report["status"] = ordinaryText["status"] as? String == "passed" ? "passed" : "partial: ordinary text failed"
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try writeReport(report, directory)
            await assembler.close()
            return report
        } catch {
            wheel?.cancel(); try? await wheel?.value
            await assembler.close()
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try? writeReport(report, directory)
            throw error
        }
    }

    /// The ordinary article case has no illustration, accent, colored row fill or
    /// added alignment marker. A genuine failure remains visible in its report.
    private static func ordinaryTextCycle(viewport: DemoViewport, window: NSWindow,
                                         controls: LiveScrollCaptureController, capture: CaptureSource,
                                         directory: URL) async throws -> [String: Any] {
        try scroll(viewport.scrollView, pixels: -Int(viewport.offset.rounded()))
        viewport.document.illustrated = false
        for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow] {
            panel?.appearance = NSAppearance(named: .aqua)
        }
        let assembler = LiveScrollAssembler(axis: .vertical, generation: 2)
        var task: Task<Void, Error>?
        var result: [String: Any] = ["status": "running", "captureMode": capture.mode,
            "addedAlignmentMarkers": false, "illustrations": false,
            "source": "ordinary numbered native article text on plain white, same fixed 36px heading"]
        do {
            var state = LiveScrollCaptureSnapshot()
            state.showsAutoScroll = false; state.canChangeAxis = false; state.canMoveRegion = false; state.canImport = false
            let initial = try await capture.image()
            var update = try await assembler.observe(initial)
            apply(update, to: controls, snapshot: &state)
            try writePNG(try scene(window: window, controls: controls, caption: "Ordinary text · no added alignment markers"),
                         directory.appendingPathComponent("live-scroll-plain-text-start.png"))
            var done = false, events = 0, previews = 0, growths = 0, refusals = 0
            var firstGrowth: Double?
            var trace: [[String: Any]] = []
            let start = ProcessInfo.processInfo.systemUptime
            task = Task { @MainActor in
                for _ in 0..<180 {
                    try Task.checkCancellation()
                    try scroll(viewport.scrollView, pixels: 4); events += 1
                    try await Task.sleep(nanoseconds: 33_333_333)
                }
                done = true
            }
            while !done {
                let priorHeight = update.state.height
                update = try await assembler.observe(capture.image())
                if update.preview != nil { previews += 1 }
                if update.state.height > priorHeight {
                    growths += 1
                    if firstGrowth == nil { firstGrowth = milliseconds(since: start) }
                }
                if !update.state.matched { refusals += 1 }
                apply(update, to: controls, snapshot: &state)
                trace.append(["seconds": ProcessInfo.processInfo.systemUptime - start,
                              "nativeOffset": viewport.offset, "acceptedOffset": update.state.viewportOffset,
                              "outputHeight": update.state.height, "matched": update.state.matched])
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(ProcessInfo.processInfo.systemUptime - start < 18, "Ordinary text pass exceeded its deadline")
            }
            try await task?.value; task = nil
            update = try await assembler.observe(capture.image())
            apply(update, to: controls, snapshot: &state)
            let final = try await assembler.finish()
            try writePNG(final, directory.appendingPathComponent("live-scroll-plain-text-finished.png"))
            try writePNG(try scene(window: window, controls: controls, caption: "Ordinary text · actual final preview and status"),
                         directory.appendingPathComponent("live-scroll-plain-text-end.png"))
            let expectedHeight = height + Int(viewport.offset.rounded())
            let reference = try plainTextReference(initial: initial, totalHeight: expectedHeight)
            try writePNG(reference, directory.appendingPathComponent("live-scroll-plain-text-reference.png"))
            let actualBytes = try normalizedPixels(final), expectedBytes = try normalizedPixels(reference)
            let exact = actualBytes == expectedBytes
            var differentChannels = 0, totalError: UInt64 = 0
            if actualBytes.count == expectedBytes.count {
                actualBytes.withUnsafeBytes { a in expectedBytes.withUnsafeBytes { b in
                    let aa = a.bindMemory(to: UInt8.self), bb = b.bindMemory(to: UInt8.self)
                    for index in 0..<aa.count {
                        let difference = abs(Int(aa[index]) - Int(bb[index]))
                        totalError += UInt64(difference)
                        if difference > 8 { differentChannels += 1 }
                    }
                } }
            }
            let dimensionsMatch = final.width == width && final.height == expectedHeight
            let mean = dimensionsMatch ? Double(totalError) / Double(max(1, actualBytes.count)) : -1
            let badFraction = dimensionsMatch ? Double(differentChannels) / Double(max(1, actualBytes.count)) : 1
            // Independent native rendering may differ by tiny text anti-aliasing values.
            // Record exact equality and strict whole-image error, never silently pass a gap.
            let reconstruction = dimensionsMatch && mean <= 0.5 && badFraction <= 0.001
            result["status"] = reconstruction && growths >= 3 && update.state.fixedLeading == headerHeight ? "passed" : "failed"
            result["continuousSeconds"] = ProcessInfo.processInfo.systemUptime - start
            result["nativeWheelEvents"] = events
            result["previewUpdates"] = previews; result["growingUpdates"] = growths
            result["firstGrowthMilliseconds"] = firstGrowth ?? -1
            result["refusedSamples"] = refusals; result["fixedHeaderPixels"] = update.state.fixedLeading
            result["expectedHeight"] = expectedHeight; result["actualHeight"] = final.height
            result["exactNativeRasterEquality"] = exact
            result["meanAbsoluteRGBAError"] = mean
            result["fractionOfChannelsDifferingByMoreThan8"] = badFraction
            result["referenceReconstructionPassed"] = reconstruction
            result["finalMessage"] = update.state.message
            result["lastValidOutputPreserved"] = final.height >= height
            result["trace"] = trace
            await assembler.close()
        } catch {
            task?.cancel(); try? await task?.value
            if let output = try? await assembler.finish() {
                try? writePNG(output, directory.appendingPathComponent("live-scroll-plain-text-last-valid.png"))
            }
            await assembler.close()
            result["status"] = "failed"; result["error"] = error.localizedDescription
        }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("live-scroll-plain-text.json"), options: .atomic)
        return result
    }

    private static func plainTextReference(initial: CGImage, totalHeight: Int) throws -> CGImage {
        let page = NumberedDocument(frame: CGRect(x: 0, y: 0, width: width, height: totalHeight - headerHeight))
        page.illustrated = false; page.appearance = NSAppearance(named: .aqua)
        let body = try nativeImage(page)
        let heading = try unwrap(initial.cropping(to: CGRect(x: 0, y: 0, width: width, height: headerHeight)),
                                 "Cannot retain the original native heading")
        let context = try unwrap(CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            "Cannot allocate independent native text reference")
        context.draw(body, in: CGRect(x: 0, y: 0, width: width, height: totalHeight - headerHeight))
        context.draw(heading, in: CGRect(x: 0, y: totalHeight - headerHeight, width: width, height: headerHeight))
        return try unwrap(context.makeImage(), "Native text reference is empty")
    }

    private static func apply(_ update: LiveScrollAssembler.Update, to controls: LiveScrollCaptureController,
                              snapshot: inout LiveScrollCaptureSnapshot) {
        snapshot.pixelWidth = update.state.width; snapshot.pixelHeight = update.state.height
        snapshot.acceptedFrames = update.state.acceptedObservations
        snapshot.status = update.state.message
        snapshot.statusKind = update.state.matched ? .capturing : .warning
        snapshot.canFinish = update.state.acceptedObservations > 0; snapshot.canCopy = snapshot.canFinish
        controls.update(snapshot: snapshot)
        if let image = update.preview { controls.updatePreview(image: image, viewportFraction: update.viewport) }
    }

    private static func scroll(_ view: NSScrollView, pixels: Int) throws {
        let event = try unwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                       wheel1: Int32(-pixels), wheel2: 0, wheel3: 0), "Cannot construct owned wheel event")
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let native = try unwrap(NSEvent(cgEvent: event), "Cannot convert wheel event")
        view.scrollWheel(with: native)
        view.reflectScrolledClipView(view.contentView)
        view.window?.displayIfNeeded()
    }

    @MainActor private final class CaptureSource {
        let viewport: NSView
        let filter: SCContentFilter?
        let mode: String
        let reason: String
        var screenCaptureStarted: Bool { filter != nil }
        init(viewport: NSView, filter: SCContentFilter?, reason: String) {
            self.viewport = viewport; self.filter = filter; self.reason = reason
            self.mode = filter == nil ? "injected-rendered-owned-window" : "ScreenCaptureKit-owned-window"
        }
        static func make(window: NSWindow, viewport: NSView, permitted: Bool) async throws -> CaptureSource {
            guard permitted else {
                return CaptureSource(viewport: viewport, filter: nil,
                    reason: "Existing Screen Recording permission unavailable; no permission was requested. Owned AppKit cacheDisplay pixels validate native scrolling and the assembler, not real screen capture or third-party apps.")
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let own = try LiveScrollUsabilityDemoFixture.unwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) },
                                     "Owned demo window missing from ScreenCaptureKit inventory")
                return CaptureSource(viewport: viewport, filter: SCContentFilter(desktopIndependentWindow: own), reason: "")
            } catch {
                return CaptureSource(viewport: viewport, filter: nil,
                    reason: "Existing permission preflight passed but ScreenCaptureKit setup failed: \(error.localizedDescription). Used explicitly injected owned native pixels.")
            }
        }
        func image() async throws -> CGImage {
            guard let filter else { return try LiveScrollUsabilityDemoFixture.nativeImage(viewport) }
            let configuration = SCStreamConfiguration()
            configuration.width = LiveScrollUsabilityDemoFixture.width; configuration.height = LiveScrollUsabilityDemoFixture.height
            configuration.showsCursor = false
            configuration.sourceRect = CGRect(x: 0, y: 0, width: LiveScrollUsabilityDemoFixture.width, height: LiveScrollUsabilityDemoFixture.height)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    private final class DemoViewport: NSView {
        let scrollView = NSScrollView()
        let document = NumberedDocument(frame: CGRect(x: 0, y: 0, width: LiveScrollUsabilityDemoFixture.width, height: 8000))
        override var isFlipped: Bool { true }
        var offset: CGFloat { scrollView.contentView.bounds.minY }
        override init(frame: CGRect) {
            super.init(frame: frame)
            scrollView.frame = CGRect(x: 0, y: LiveScrollUsabilityDemoFixture.headerHeight, width: LiveScrollUsabilityDemoFixture.width, height: LiveScrollUsabilityDemoFixture.height - LiveScrollUsabilityDemoFixture.headerHeight)
            scrollView.borderType = .noBorder; scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false; scrollView.drawsBackground = true
            scrollView.backgroundColor = .white; scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none; scrollView.documentView = document
            scrollView.automaticallyAdjustsContentInsets = false
            addSubview(scrollView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(calibratedRed: 0.075, green: 0.13, blue: 0.21, alpha: 1).setFill()
            bounds.fill()
            NSColor(calibratedRed: 0.16, green: 0.82, blue: 0.66, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: LiveScrollUsabilityDemoFixture.width, height: 3).fill()
            ("FIELD NOTES  /  A numbered native document" as NSString).draw(at: CGPoint(x: 20, y: 11),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        }
    }

    private final class NumberedDocument: NSView {
        static let rowHeight = 40
        var illustrated = true { didSet { needsDisplay = true } }
        static let titles = ["The coast before sunrise", "Finding the quiet path", "Light through the pine trees",
                             "A notebook full of small details", "The harbor opens for the day", "Following the river north",
                             "A place to stop and look", "Making room for the unexpected"]
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); dirtyRect.fill()
            let lower = max(0, Int(dirtyRect.minY) / Self.rowHeight)
            let upper = min(199, Int(dirtyRect.maxY) / Self.rowHeight)
            guard lower <= upper else { return }
            for row in lower...upper {
                let y = row * Self.rowHeight
                NSColor(calibratedWhite: illustrated ? (row % 2 == 0 ? 0.98 : 0.955) : 1, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: LiveScrollUsabilityDemoFixture.width, height: Self.rowHeight).fill()
                // A narrow unique accent is an independent machine-readable row ID;
                // the rest is a normal numbered, richly styled native text document.
                if illustrated { Self.accent(row).setFill(); NSRect(x: 0, y: y, width: 8, height: Self.rowHeight).fill() }
                (String(format: "%03d", row + 1) as NSString).draw(at: CGPoint(x: 24, y: y + 10),
                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
                                     .foregroundColor: NSColor(calibratedWhite: 0.27, alpha: 1)])
                (Self.titles[row % Self.titles.count] as NSString).draw(at: CGPoint(x: 82, y: y + 5),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                     .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1)])
                ("Entry \(row + 1) · observations, sketches and things worth keeping" as NSString)
                    .draw(at: CGPoint(x: 82, y: y + 23), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1)])
                // Small abstract travel illustration: textured across the full row height.
                // This also makes the true fixed-header boundary observable in a
                // live frame pair, including between text baselines.
                if illustrated { for scanline in 0..<Self.rowHeight {
                    let phase = Double(y + scanline) * 0.71 + Double(row) * 0.13
                    let shade = 0.32 + 0.23 * sin(phase)
                    NSColor(srgbRed: 0.28 + shade * 0.4, green: 0.47 + shade * 0.45,
                            blue: 0.54 + shade * 0.4, alpha: 1).setFill()
                    NSRect(x: 536, y: y + scanline, width: 104, height: 1).fill()
                    NSColor(srgbRed: 0.23, green: 0.43, blue: 0.38, alpha: 1).setFill()
                    let edge = Int(22 + 19 * sin(Double(scanline) * 0.25 + Double(row)))
                    NSRect(x: 536, y: y + scanline, width: edge, height: 1).fill()
                } }
            }
        }
        static func accent(_ row: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(35 + row * 47 % 190) / 255,
                    green: CGFloat(45 + row * 73 % 180) / 255,
                    blue: CGFloat(55 + row * 31 % 170) / 255, alpha: 1)
        }
    }

    private static func numberedCoverage(output: CGImage, expectedOffset: Int) throws -> [String: Any] {
        let expectedHeight = height + expectedOffset
        let bitmap = NSBitmapImageRep(cgImage: output)
        let expectedBody = expectedHeight - headerHeight
        var badScanlines = 0
        for line in 0..<min(expectedBody, max(0, output.height - headerHeight)) {
            let actual = bitmap.colorAt(x: 3, y: headerHeight + line)?.usingColorSpace(.sRGB)
            let wanted = NumberedDocument.accent(line / NumberedDocument.rowHeight).usingColorSpace(.sRGB)
            guard let actual, let wanted else { badScanlines += 1; continue }
            if max(abs(actual.redComponent - wanted.redComponent),
                   abs(actual.greenComponent - wanted.greenComponent),
                   abs(actual.blueComponent - wanted.blueComponent)) > 0.025 { badScanlines += 1 }
        }
        return ["passed": output.width == width && output.height == expectedHeight && badScanlines == 0,
                "expectedHeight": expectedHeight, "actualHeight": output.height,
                "firstNumberedRow": 1, "lastNumberedRow": (expectedBody - 1) / NumberedDocument.rowHeight + 1,
                "fullyCoveredRows": expectedBody / NumberedDocument.rowHeight,
                "verifiedBodyScanlines": min(expectedBody, output.height - headerHeight),
                "mismatchedRowIdentityScanlines": badScanlines,
                "method": "Every output scanline's native unique row accent is checked against independent row numbering; output dimensions require one fixed header and one contiguous document range"]
    }

    private static func nativeImage(_ view: NSView) throws -> CGImage {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        try require(w > 0 && h > 0 && w * h <= 2_000_000, "Unbounded native snapshot")
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32), "Native snapshot allocation failed")
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        return try unwrap(bitmap.cgImage, "Native snapshot was empty")
    }

    private static func scene(window: NSWindow, controls: LiveScrollCaptureController, caption: String) throws -> CGImage {
        let windows = [window, controls.previewWindow, controls.toolbarWindow].compactMap { $0 }
        var extent = window.frame
        for item in windows { extent = extent.union(item.frame) }
        extent = extent.insetBy(dx: -18, dy: -18)
        let w = Int(extent.width.rounded(.up)), h = Int(extent.height.rounded(.up)) + 40
        let context = try unwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            "Scene allocation failed")
        context.setFillColor(NSColor(calibratedWhite: 0.91, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for item in windows {
            guard let view = item.contentView else { continue }
            item.displayIfNeeded()
            let image = try nativeImage(view)
            context.draw(image, in: CGRect(x: item.frame.minX - extent.minX,
                y: item.frame.minY - extent.minY + 40, width: item.frame.width, height: item.frame.height))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (caption as NSString).draw(at: CGPoint(x: 18, y: 15), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1)])
        NSGraphicsContext.restoreGraphicsState()
        return try unwrap(context.makeImage(), "Scene was empty")
    }

    private static func normalizedPixels(_ image: CGImage) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try unwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Pixel comparison allocation failed")
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private static func writePNG(_ image: CGImage, _ url: URL) throws {
        let writer = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil),
                                "Cannot open PNG")
        CGImageDestinationAddImage(writer, image, nil)
        try require(CGImageDestinationFinalize(writer), "Cannot finish PNG")
    }
    private static func writeGIF(_ images: [CGImage], _ url: URL) throws {
        let writer = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil),
                                "Cannot open GIF")
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for image in images {
            CGImageDestinationAddImage(writer, image, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: 0.5, kCGImagePropertyGIFUnclampedDelayTime: 0.5]] as CFDictionary)
        }
        try require(CGImageDestinationFinalize(writer), "Cannot finish GIF")
    }
    private static func contactSheet(_ images: [CGImage]) throws -> CGImage {
        let indexes = [0, images.count / 5, images.count * 2 / 5, images.count * 3 / 5, images.count * 4 / 5, images.count - 1]
        let tileW = 600, tileH = 410
        let context = try unwrap(CGContext(data: nil, width: tileW * 2, height: tileH * 3, bitsPerComponent: 8,
            bytesPerRow: tileW * 2 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            "Cannot allocate contact sheet")
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: tileW * 2, height: tileH * 3))
        for (slot, index) in indexes.enumerated() {
            let image = images[index]
            let scale = min(CGFloat(tileW - 12) / CGFloat(image.width), CGFloat(tileH - 12) / CGFloat(image.height))
            let rect = CGRect(x: CGFloat(slot % 2 * tileW + 6), y: CGFloat((2 - slot / 2) * tileH + 6),
                              width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: rect)
        }
        return try unwrap(context.makeImage(), "Empty contact sheet")
    }
    private static func findButton(_ id: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if view.identifier?.rawValue == id { return view as? NSButton }
        for child in view.subviews { if let found = findButton(id, in: child) { return found } }
        return nil
    }
    private static func writeReport(_ report: [String: Any], _ directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("live-scroll-usability.json"), options: .atomic)
    }
    private static func milliseconds(since time: Double) -> Double {
        (ProcessInfo.processInfo.systemUptime - time) * 1000
    }
    private struct DemoFailure: LocalizedError { let errorDescription: String? }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw DemoFailure(errorDescription: message) }
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw DemoFailure(errorDescription: message) }; return value
    }
}
