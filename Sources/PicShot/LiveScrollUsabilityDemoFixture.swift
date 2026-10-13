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
            report["automaticCase"] = ["status": "blocked", "productSessionClosed": false,
                                       "reason": "Prior owned product session did not close"]
            try writeReport(report, directory)
            throw DemoFailure(errorDescription: "Previous native demo session cleanup was not confirmed")
        }
        let plain = await productCycle(viewport: viewport, window: window, screen: screen,
            capture: capture, directory: directory, plain: true)
        report["ordinaryTextCase"] = plain
        try writeReport(report, directory)
        let automatic: [String: Any]
        if plain["productSessionClosed"] as? Bool == true {
            automatic = await automaticCycle(screen: screen, directory: directory)
        } else {
            automatic = ["status": "blocked", "productSessionClosed": false,
                         "reason": "Previous owned product session cleanup was not confirmed"]
        }
        report["automaticCase"] = automatic
        try writeReport(report, directory)
        let movement: [String: Any]
        if automatic["productSessionClosed"] as? Bool == true {
            movement = await verifyMovement(evidenceDirectory: directory.appendingPathComponent("movement"))
        } else {
            movement = ["status": "blocked", "productSessionClosed": false,
                        "reason": "Previous owned product session cleanup was not confirmed"]
        }
        report["movementCase"] = movement
        try writeReport(report, directory)
        let output: [String: Any]
        if movement["productSessionClosed"] as? Bool == true {
            let outputDirectory = directory.appendingPathComponent("output-actions")
            do { output = try await LiveScrollOutputDemoFixture.verify(evidenceDirectory: outputDirectory) }
            catch {
                let data = try? Data(contentsOf: outputDirectory.appendingPathComponent("live-scroll-output.json"))
                if let data, let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    output = saved
                } else {
                    output = ["status": "failed", "productSessionClosed": false, "error": error.localizedDescription]
                }
            }
        } else {
            output = ["status": "blocked", "productSessionClosed": false,
                      "reason": "Previous owned product session cleanup was not confirmed"]
        }
        report["outputCase"] = output
        try writeReport(report, directory)
        let realStream: [String: Any]
        if output["productSessionClosed"] as? Bool == true {
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
            && automatic["status"] as? String == "passed"
            && movement["status"] as? String == "passed" && output["status"] as? String == "passed" && realOutcomeAcceptable
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
        var holdStationaryRecovery = false
        weak var observedSession: LiveScrollSessionController?
        let session = LiveScrollSessionController(onComplete: { image in
            completedImage = image; completedCount += 1
        }, onImport: {})
        observedSession = session
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
                // Pace only the next owned acquisition so both native appearances
                // can show the real failure before the product retries a duplicate.
                // Cancellation and the two-second cap keep normal drain bounded.
                if holdStationaryRecovery && observedSession?.stateForVerification.previewUnavailable == true {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while holdStationaryRecovery && ProcessInfo.processInfo.systemUptime < deadline {
                        try await Task.sleep(nanoseconds: 25_000_000)
                    }
                }
                frameRequests += 1
                return try await capture.image()
            })
            try await waitFor("Product session did not produce its first preview", timeout: 6) {
                session.stateForVerification.acceptedObservations > 0
            }
            let controls = try unwrap(session.controlsForVerification, "Product session did not install capture controls")
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
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
                let gapLabel = thumbnail.accessibilityLabel() ?? ""
                let gapMarkerUnverified = !thumbnail.isPositionVerified
                let gapMarkerAmber = thumbnail.viewportMarkerColor == .systemOrange
                let gapAccessibilityUnverified = gapLabel.contains("尚未验证") && !gapLabel.contains("绿色")
                report["gapRejected"] = true; report["gapPreservedLastValidPreviewAndState"] = preserved
                report["gapMarkerUnverified"] = gapMarkerUnverified
                report["gapMarkerAmber"] = gapMarkerAmber
                report["gapAccessibilityDescribesUnverifiedPosition"] = gapAccessibilityUnverified
                report["gapAccessibilityLabel"] = gapLabel
                report["gapRecoveryMatched"] = false; report["gapRecoveryMarkerVerified"] = false
                try writePNG(try scene(window: window, controls: controls,
                    caption: "Gap warning · actual session retains the last valid long image"),
                    directory.appendingPathComponent("live-scroll-gap-recovery.png"))
                try require(preserved && gapMarkerUnverified && gapMarkerAmber && gapAccessibilityUnverified,
                            "Rejected gap changed retained pixels or labeled an unverified page position as current")
                try scroll(viewport.scrollView, pixels: Int((retainedOffset - viewport.offset).rounded()))
                try await waitFor("Product session did not recover retained overlap", timeout: 5) {
                    session.stateForVerification.matched && thumbnail.isPositionVerified
                }
                let recoveredLabel = thumbnail.accessibilityLabel() ?? ""
                report["gapRecoveryMatched"] = session.stateForVerification.matched
                report["gapRecoveryMarkerVerified"] = thumbnail.isPositionVerified
                report["gapRecoveryMarkerGreen"] = thumbnail.viewportMarkerColor == .systemGreen
                report["gapRecoveryAccessibilityDescribesVerifiedPosition"] = recoveredLabel.contains("绿色")
                    && !recoveredLabel.contains("尚未验证")
                try require(thumbnail.viewportMarkerColor == .systemGreen && recoveredLabel.contains("绿色")
                    && !recoveredLabel.contains("尚未验证"), "Recovered overlap did not restore the verified marker and accessibility label")
                try scroll(viewport.scrollView, pixels: 48)
                try await waitFor("Product session did not extend after recovery", timeout: 5) {
                    session.stateForVerification.viewportOffset == Int(viewport.offset.rounded())
                }
                try require(pausePreserved && preserved, "Pause or gap changed the retained output")

                // Fail one actual accepted preview, then leave the owned document
                // completely stationary. The production sampler must recover it.
                let beforeFailure = session.stateForVerification
                let previewBeforeFailure = try normalizedPixels(try unwrap(thumbnail.image, "Preview missing before injected failure"))
                let auto = try unwrap(findButton("scroll.live.autoScroll", in: controls.toolbarWindow?.contentView),
                                      "Actual Auto control absent during recovery")
                holdStationaryRecovery = true
                await session.failNextPreviewForTesting()
                try scroll(viewport.scrollView, pixels: 48)
                try await waitFor("Accepted preview did not enter the induced failure", timeout: 5) {
                    session.stateForVerification.previewUnavailable
                        && session.stateForVerification.viewportOffset == beforeFailure.viewportOffset + 48
                }
                let failed = session.stateForVerification
                let failedNativeOffset = Int(viewport.offset.rounded())
                let failedDocument = try unwrap(await session.documentSnapshotForResourceVerification(),
                                               "Failed preview lost the accepted document")
                let failedFrameCount = session.sampledFramesForVerification
                let failedLabel = thumbnail.accessibilityLabel() ?? ""
                let retainedFailurePixels = try normalizedPixels(try unwrap(thumbnail.image, "Failure removed retained preview"))
                    == previewBeforeFailure
                var recovery: [String: Any] = ["status": "running", "injectedPreviewFailures": 1,
                    "nativeWheelEventsToFailure": 1, "nativeWheelEventsDuringRecovery": 0,
                    "beforeFailureAcceptedObservations": beforeFailure.acceptedObservations,
                    "beforeFailureOffset": beforeFailure.viewportOffset,
                    "failureAcceptedObservations": failed.acceptedObservations,
                    "failureOffset": failed.viewportOffset, "failureHeight": failed.height,
                    "failureNativeOffset": failedNativeOffset,
                    "failurePreviewUnavailable": failed.previewUnavailable, "failureMatched": failed.matched,
                    "failureRetainedPreviewPixels": retainedFailurePixels,
                    "failureMarkerUnverified": !thumbnail.isPositionVerified,
                    "failureMarkerAmber": thumbnail.viewportMarkerColor == .systemOrange,
                    "failureAccessibilityUnverified": failedLabel.contains("尚未验证") && !failedLabel.contains("绿色"),
                    "failureAutoOff": !session.snapshotForVerification.autoScrolling,
                    "failureAutoLabel": auto.accessibilityLabel() ?? "",
                    "failureAutoDisabled": !auto.isEnabled,
                    "recoveryRequiresFurtherInput": false,
                    "sourcePacingMaximumSeconds": 2,
                    "failureAppearanceEvidence": ["light": "live-scroll-preview-failed-light.png", "dark": "live-scroll-preview-failed-dark.png"],
                    "recoveryAppearanceEvidence": ["light": "live-scroll-preview-recovered-light.png", "dark": "live-scroll-preview-recovered-dark.png"]]
                report["stationaryPreviewRecovery"] = recovery
                try require(failed.matched && retainedFailurePixels && !thumbnail.isPositionVerified
                    && thumbnail.viewportMarkerColor == .systemOrange && !auto.isEnabled
                    && !session.snapshotForVerification.autoScrolling,
                    "Failed preview lost accepted pixels or advertised a verified position/active Auto")
                try recoveryAppearances(window: window, controls: controls, directory: directory,
                    stem: "live-scroll-preview-failed", caption: "Preview unavailable · retained pixels · Auto off")
                try require(session.stateForVerification.previewUnavailable,
                            "Stationary recovery happened before native failure evidence was captured")
                holdStationaryRecovery = false
                try await waitFor("Stationary owned frame did not recover the unavailable preview", timeout: 5) {
                    !session.stateForVerification.previewUnavailable && thumbnail.isPositionVerified
                        && session.sampledFramesForVerification > failedFrameCount
                }
                let recovered = session.stateForVerification
                let recoveredDocument = try unwrap(await session.documentSnapshotForResourceVerification(),
                                                  "Stationary retry lost the accepted document")
                let recoveredLabel = thumbnail.accessibilityLabel() ?? ""
                let expectedFraction = CGRect(x: 0,
                    y: Double(recovered.fixedLeading + failedNativeOffset) / Double(recovered.height),
                    width: 1,
                    height: Double(height - recovered.fixedLeading - recovered.fixedTrailing) / Double(recovered.height))
                let fraction = thumbnail.viewportFraction
                let fractionCorrect = abs(fraction.minY - expectedFraction.minY) < 0.000000000001
                    && abs(fraction.height - expectedFraction.height) < 0.000000000001
                    && fraction.minX == 0 && fraction.width == 1 && thumbnail.viewportMarker != nil
                recovery["recoveryAcceptedObservations"] = recovered.acceptedObservations
                recovery["recoveryOffset"] = recovered.viewportOffset; recovery["recoveryHeight"] = recovered.height
                recovery["recoveryNativeOffset"] = Int(viewport.offset.rounded())
                recovery["stationaryFramesObserved"] = session.sampledFramesForVerification - failedFrameCount
                recovery["recoveryPreviewAvailable"] = !recovered.previewUnavailable
                recovery["recoveryMarkerVerified"] = thumbnail.isPositionVerified
                recovery["recoveryMarkerGreen"] = thumbnail.viewportMarkerColor == .systemGreen
                recovery["recoveryMarkerAtAcceptedViewport"] = fractionCorrect
                recovery["recoveryAccessibilityVerified"] = recoveredLabel.contains("绿色") && !recoveredLabel.contains("尚未验证")
                recovery["recoveryAutoOff"] = !session.snapshotForVerification.autoScrolling
                recovery["recoveryAutoLabel"] = auto.accessibilityLabel() ?? ""
                recovery["durableSourceCountUnchanged"] = recoveredDocument.sourceCount == failedDocument.sourceCount
                recovery["durableStripCountUnchanged"] = recoveredDocument.stripCount == failedDocument.stripCount
                recovery["durableDiskBytesUnchanged"] = recoveredDocument.diskBytes == failedDocument.diskBytes
                recovery["status"] = "passed"
                report["stationaryPreviewRecovery"] = recovery
                try require(recovered.acceptedObservations == failed.acceptedObservations
                    && recovered.viewportOffset == failed.viewportOffset && recovered.height == failed.height
                    && Int(viewport.offset.rounded()) == failedNativeOffset
                    && recoveredDocument.sourceCount == failedDocument.sourceCount
                    && recoveredDocument.stripCount == failedDocument.stripCount
                    && recoveredDocument.diskBytes == failedDocument.diskBytes
                    && fractionCorrect && thumbnail.viewportMarkerColor == .systemGreen
                    && !session.snapshotForVerification.autoScrolling,
                    "Stationary retry changed accepted output/spool/position or restarted Auto")
                try recoveryAppearances(window: window, controls: controls, directory: directory,
                    stem: "live-scroll-preview-recovered", caption: "Stationary preview recovered · verified position · Auto off")
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
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
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
            let reference = try numberedReference(initial: initial,
                totalHeight: height + Int(maxOffset.rounded()), illustrated: !plain)
            try writePNG(reference, directory.appendingPathComponent(prefix + "-reference.png"))
            let referenceStart = try unwrap(reference.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)),
                                             "Independent reference has no initial viewport")
            let calibration = try nativeRasterComparison(referenceStart, initial)
            let comparison = try nativeRasterComparison(output, reference)
            report["referenceInitialViewportCalibration"] = calibration
            report["nativeReferenceComparison"] = comparison
            report["referenceMethod"] = "Fresh native numbered document from origin; only original 36px header reused; every RGBA pixel normalized identically and compared"
            try require(calibration["passed"] as? Bool == true,
                        "Independent document reference does not reproduce the initial native viewport")
            try require(comparison["passed"] as? Bool == true,
                        "Product Finish differs from the independent full native document reference")
            if !plain {
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

    /// One bounded native automatic-scroll scenario. Only the product session
    /// emits automatic input; the fixture observes and routes it to its own view.
    private static func automaticCycle(screen: NSScreen, directory: URL) async -> [String: Any] {
        let prefix = "live-scroll-automatic"
        let start = ProcessInfo.processInfo.systemUptime
        let boundedOffset = 640
        let visible = screen.visibleFrame
        let window = NSWindow(contentRect: CGRect(x: visible.midX - 390, y: visible.midY - 200,
            width: CGFloat(width), height: CGFloat(height)), styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "PicShot · Bounded native automatic scrolling"
        window.isReleasedWhenClosed = false; window.hasShadow = false
        window.backgroundColor = .white; window.appearance = NSAppearance(named: .aqua)
        let viewport = DemoViewport(frame: CGRect(x: 0, y: 0, width: width, height: height))
        // Preserve the numbered drawing exactly; shorten only its native extent.
        viewport.document.setFrameSize(CGSize(width: width, height: height - headerHeight + boundedOffset))
        window.contentView = viewport; window.orderFrontRegardless(); window.displayIfNeeded()
        defer { window.close() }
        let capture = CaptureSource(viewport: viewport, filter: nil,
            reason: "Automatic input is intercepted into this owned native view; acquisition uses owned AppKit pixels, not SCStream or third-party content.")
        var completedImage: CGImage?, completedCount = 0, frameRequests = 0
        var phase = "awaiting-seed"
        var inputTrace: [[String: Any]] = [], trace: [[String: Any]] = [], story: [CGImage] = []
        var inputTimes: [Double] = [], inputPhases: [String] = [], inputOffsets: [Int] = [], inputSamples: [Int] = []
        var growths = 0, lastHeight = 0, lastArtifact = -1.0
        var firstGrowth: Double?, firstInput: Double?
        var stopClicked = false, restartClicked = false
        weak var observedSession: LiveScrollSessionController?
        let session = LiveScrollSessionController(onComplete: { image in
            completedImage = image; completedCount += 1
        }, onImport: {}, automaticScrollPermission: { true }, automaticScrollInput: { event in
            let native = try unwrap(NSEvent(cgEvent: event), "Cannot convert product automatic wheel event")
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let before = viewport.offset
            let state = observedSession?.stateForVerification
            let samples = observedSession?.sampledFramesForVerification ?? 0
            viewport.scrollView.scrollWheel(with: native)
            viewport.scrollView.reflectScrolledClipView(viewport.scrollView.contentView)
            window.displayIfNeeded()
            inputTimes.append(elapsed); inputPhases.append(phase)
            inputOffsets.append(state?.viewportOffset ?? -1); inputSamples.append(samples)
            if firstInput == nil { firstInput = elapsed }
            inputTrace.append(["seconds": elapsed, "phase": phase,
                "nativeOffsetBefore": before, "nativeOffsetAfter": viewport.offset,
                "acceptedOffsetBeforeInput": state?.viewportOffset ?? -1,
                "acceptedObservationsBeforeInput": state?.acceptedObservations ?? 0,
                "previewPositionVerifiedBeforeInput": observedSession?.snapshotForVerification.previewPositionVerified ?? false,
                "sampledFramesBeforeInput": samples, "frameProviderCallsBeforeInput": frameRequests,
                "productStatusBeforeInput": observedSession?.snapshotForVerification.status ?? "",
                "pixelDeltaY": event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                "continuous": event.getIntegerValueField(.scrollWheelEventIsContinuous)])
        })
        observedSession = session
        var report: [String: Any] = ["status": "running", "productSessionControllerExercised": true,
            "captureMode": capture.mode, "scope": "owned bounded numbered native document",
            "realScreenCaptureClaimed": false, "globalInputPosted": false,
            "permissionRequested": false, "accessibilityPermissionInjectedForOwnedInputOnly": true,
            "sessionSamplingLoopReimplementedByFixture": false,
            "automaticInputLoopReimplementedByFixture": false,
            "inputRoute": "Unchanged product CGEvent converted to NSEvent and delivered to owned NSScrollView.scrollWheel(with:); no global posting",
            "buttonInputRoute": "accepted native hit-test/mouse helper PortableSettingsUIPreviewFixture.click",
            "seedDelaySeconds": 0.3, "freshFrameDelaySeconds": 0.1,
            "boundedDocumentHeight": height - headerHeight + boundedOffset,
            "expectedNativeEndOffset": boundedOffset, "expectedOutputWidth": width,
            "expectedOutputHeight": height + boundedOffset, "limitation": capture.reason]
        do {
            let initial = try await capture.image()
            try await session.startForVerification(targetFrame: window.frame, screen: screen, nextImage: {
                frameRequests += 1
                try await Task.sleep(nanoseconds: frameRequests == 1 ? 300_000_000 : 100_000_000)
                return try await capture.image()
            })
            let controls = try unwrap(session.controlsForVerification, "Automatic demo controls are missing")
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
                panel?.appearance = NSAppearance(named: .aqua)
            }
            let auto = try unwrap(findButton("scroll.live.autoScroll", in: controls.toolbarWindow?.contentView),
                                  "Actual Auto/Stop button missing")
            let thumbnail = try unwrap(controls.previewWindow?.contentView as? LiveScrollThumbnailView,
                                       "Automatic demo thumbnail is missing")
            report["autoDisabledBeforeVerifiedSeed"] = !auto.isEnabled && inputTimes.isEmpty
                && session.stateForVerification.acceptedObservations == 0
            try require(report["autoDisabledBeforeVerifiedSeed"] as? Bool == true,
                        "Automatic input became available before a verified seed")
            try writePNG(try scene(window: window, controls: controls, caption: "Auto waits for the delayed native seed"),
                         directory.appendingPathComponent(prefix + "-waiting-for-seed.png"))
            try await waitFor("Automatic demo did not verify its delayed native seed", timeout: 6) {
                session.snapshotForVerification.previewPositionVerified && auto.isEnabled
            }
            report["firstVerifiedPreviewMilliseconds"] = milliseconds(since: start)
            let firstMarker = thumbnail.viewportMarker
            lastHeight = session.stateForVerification.height
            let firstScene = try scene(window: window, controls: controls, caption: "Verified seed · actual Auto button ready")
            story.append(firstScene)
            try writePNG(firstScene, directory.appendingPathComponent(prefix + "-native-first-window.png"))
            phase = "initial-auto"
            try PortableSettingsUIPreviewFixture.click(auto)
            report["nativeAutoButtonStartedSession"] = session.snapshotForVerification.autoScrolling && inputTimes.count == 1
            try require(report["nativeAutoButtonStartedSession"] as? Bool == true,
                        "Actual Auto button did not start the session's automatic input")
            while true {
                let state = session.stateForVerification
                let snapshot = session.snapshotForVerification
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if state.height > lastHeight {
                    growths += 1; lastHeight = state.height
                    if firstGrowth == nil { firstGrowth = elapsed }
                }
                trace.append(["seconds": elapsed, "phase": phase, "nativeOffset": viewport.offset,
                    "acceptedOffset": state.viewportOffset, "outputHeight": state.height,
                    "acceptedObservations": state.acceptedObservations, "matched": state.matched,
                    "automaticInputs": inputTimes.count, "autoScrolling": snapshot.autoScrolling,
                    "paused": snapshot.paused, "productStatus": snapshot.status])
                if elapsed - lastArtifact >= 0.5, story.count < 35 {
                    let image = try scene(window: window, controls: controls,
                        caption: String(format: "%.1f s · automatic · %d px · actual PicShot session", elapsed, state.height))
                    story.append(image); lastArtifact = elapsed
                    try writePNG(image, directory.appendingPathComponent(String(format: prefix + "-frame-%02d.png", story.count)))
                }
                // Exercise the actual Stop affordance before resuming the same
                // session. There is no fixture task producing automatic wheels.
                if !stopClicked, state.viewportOffset >= 201, snapshot.autoScrolling {
                    try PortableSettingsUIPreviewFixture.click(auto)
                    stopClicked = true; phase = "stopped-by-button"
                    let stoppedCount = inputTimes.count
                    let stoppedSamples = session.sampledFramesForVerification
                    try writePNG(try scene(window: window, controls: controls, caption: "Actual Stop button · manual capture stays active"),
                                 directory.appendingPathComponent(prefix + "-native-stopped-window.png"))
                    try await Task.sleep(nanoseconds: 450_000_000)
                    try await waitFor("Stopped automatic session did not join its current viewport", timeout: 5) {
                        session.stateForVerification.viewportOffset == Int(viewport.offset.rounded())
                            && session.snapshotForVerification.previewPositionVerified && auto.isEnabled
                    }
                    report["nativeStopButtonStoppedInput"] = !session.snapshotForVerification.autoScrolling
                        && inputTimes.count == stoppedCount
                    report["manualCaptureActiveAfterStopButton"] = !session.snapshotForVerification.paused
                        && session.sampledFramesForVerification > stoppedSamples
                    try require(report["nativeStopButtonStoppedInput"] as? Bool == true
                        && report["manualCaptureActiveAfterStopButton"] as? Bool == true,
                        "Actual Stop button failed to stop input while retaining manual capture")
                    phase = "resumed-auto"
                    try PortableSettingsUIPreviewFixture.click(auto)
                    restartClicked = true
                    report["nativeAutoButtonRestartedSession"] = session.snapshotForVerification.autoScrolling
                    try require(session.snapshotForVerification.autoScrolling, "Actual Auto button did not restart")
                } else if !snapshot.autoScrolling {
                    break
                }
                try require(elapsed < 22, "Bounded automatic demo exceeded its deadline")
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let stoppedAt = ProcessInfo.processInfo.systemUptime - start
            let stoppedSnapshot = session.snapshotForVerification
            let endState = session.stateForVerification
            let timeoutSeconds = stoppedAt - (inputTimes.last ?? stoppedAt)
            report["noProgressStopStatus"] = stoppedSnapshot.status
            report["noProgressStopSecondsSinceLastInput"] = timeoutSeconds
            report["noProgressStoppedAtNativeEnd"] = !stoppedSnapshot.autoScrolling
                && stoppedSnapshot.status.contains("未确认页面移动")
                && Int(viewport.offset.rounded()) == boundedOffset && endState.viewportOffset == boundedOffset
            report["automaticEndOutputHeight"] = endState.height
            report["noProgressTerminalInputCount"] = inputTrace.filter {
                ($0["nativeOffsetBefore"] as? CGFloat) == CGFloat(boundedOffset)
                    && ($0["nativeOffsetAfter"] as? CGFloat) == CGFloat(boundedOffset)
            }.count
            try writePNG(try scene(window: window, controls: controls,
                caption: "Document end · automatic input stopped · manual capture available"),
                directory.appendingPathComponent(prefix + "-native-no-progress-window.png"))
            try require(report["noProgressStoppedAtNativeEnd"] as? Bool == true && timeoutSeconds >= 3,
                        "Automatic scrolling did not stop at the bounded end after its no-progress deadline")
            try require(report["noProgressTerminalInputCount"] as? Int == 1,
                        "More than one automatic input was pending without native forward progress")
            let stoppedInputCount = inputTimes.count
            let samplesAtEnd = session.sampledFramesForVerification
            try await Task.sleep(nanoseconds: 450_000_000)
            report["manualCaptureActiveAfterNoProgress"] = !session.snapshotForVerification.paused
                && session.sampledFramesForVerification > samplesAtEnd && inputTimes.count == stoppedInputCount
            try scroll(viewport.scrollView, pixels: -40)
            try await waitFor("Manual reverse after automatic stop did not rejoin", timeout: 5) {
                session.stateForVerification.viewportOffset == boundedOffset - 40
            }
            try scroll(viewport.scrollView, pixels: 40)
            try await waitFor("Manual return after automatic stop did not rejoin", timeout: 5) {
                session.stateForVerification.viewportOffset == boundedOffset
            }
            report["manualRecoveryWheelEvents"] = 2
            report["manualRecoveryAfterNoProgress"] = session.stateForVerification.matched
                && !session.snapshotForVerification.autoScrolling && inputTimes.count == stoppedInputCount
            let finalState = session.stateForVerification
            let finalMarker = thumbnail.viewportMarker
            report["fixedHeaderDetectedPixels"] = finalState.fixedLeading
            report["viewportMarkerPresentAtStartAndEnd"] = firstMarker != nil && finalMarker != nil
            report["viewportMarkerShrankAsDocumentGrew"] = (finalMarker?.height ?? .infinity) < (firstMarker?.height ?? 0)
            let finalScene = try scene(window: window, controls: controls, caption: "Ready to finish · bounded automatic output retained")
            story.append(finalScene)
            try writePNG(finalScene, directory.appendingPathComponent(prefix + "-native-finished-window.png"))
            let finish = try unwrap(findButton("scroll.live.finish", in: controls.toolbarWindow?.contentView),
                                    "Actual Finish button missing after automatic capture")
            report["completionCallbacksBeforeFinish"] = completedCount
            try require(finish.isEnabled && completedCount == 0, "Automatic stop finished output prematurely or disabled Finish")
            try PortableSettingsUIPreviewFixture.click(finish)
            try await waitFor("Automatic demo Finish did not deliver its image", timeout: 8) { completedImage != nil }
            let output = try unwrap(completedImage, "Automatic demo Finish returned no image")
            try writePNG(output, directory.appendingPathComponent(prefix + "-finished.png"))
            report["outputWidth"] = output.width; report["outputHeight"] = output.height
            let reference = try numberedReference(initial: initial, totalHeight: height + boundedOffset, illustrated: true)
            try writePNG(reference, directory.appendingPathComponent(prefix + "-reference.png"))
            let referenceStart = try unwrap(reference.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)),
                                             "Automatic reference has no initial viewport")
            let calibration = try nativeRasterComparison(referenceStart, initial)
            let comparison = try nativeRasterComparison(output, reference)
            report["referenceInitialViewportCalibration"] = calibration
            report["nativeReferenceComparison"] = comparison
            report["referenceMethod"] = "Fresh native numbered document from origin to bounded end; only original 36px header reused; every RGBA pixel normalized identically and compared"
            var intervals: [Double] = [], withinRunIntervals: [Double] = []
            var freshProgressBeforeEveryFollowingInput = true
            for index in 1..<inputTimes.count {
                intervals.append(inputTimes[index] - inputTimes[index - 1])
                guard inputPhases[index] == inputPhases[index - 1] else { continue }
                withinRunIntervals.append(inputTimes[index] - inputTimes[index - 1])
                freshProgressBeforeEveryFollowingInput = freshProgressBeforeEveryFollowingInput
                    && inputOffsets[index] > inputOffsets[index - 1] && inputSamples[index] > inputSamples[index - 1]
            }
            report["minimumAutomaticIntervalSeconds"] = intervals.min() ?? -1
            report["minimumAutomaticIntervalWithinRunSeconds"] = withinRunIntervals.min() ?? -1
            report["matchedForwardProgressBeforeEveryFollowingInput"] = freshProgressBeforeEveryFollowingInput
            try require(stopClicked && restartClicked && inputTimes.count >= 6 && growths >= 4,
                        "Automatic demo did not show progressive preview updates and actual Stop/restart controls")
            try require((intervals.min() ?? 0) >= 0.35 - 0.000001 && freshProgressBeforeEveryFollowingInput,
                        "Automatic input ignored its minimum interval or verified forward progress")
            try require(report["manualCaptureActiveAfterNoProgress"] as? Bool == true
                && report["manualRecoveryAfterNoProgress"] as? Bool == true,
                "No-progress stop disabled manual capture or emitted further automatic input")
            try require(finalState.fixedLeading == headerHeight && completedCount == 1
                && firstMarker != nil && finalMarker != nil,
                "Automatic output lost its sticky header, viewport marker, or unique Finish callback")
            try require(output.width == width && output.height == height + boundedOffset
                && calibration["passed"] as? Bool == true && comparison["passed"] as? Bool == true,
                "Automatic Finish differs from the full bounded native numbered document reference")
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            if let controls = session.controlsForVerification,
               let image = try? scene(window: window, controls: controls, caption: "Automatic demo failure · retained native UI") {
                try? writePNG(image, directory.appendingPathComponent(prefix + "-failure.png"))
            }
        }
        report["nativeAutomaticInputCount"] = inputTimes.count
        report["automaticInputTimesSeconds"] = inputTimes
        report["automaticInputTrace"] = inputTrace; report["trace"] = trace
        report["observedGrowingPreviewUpdates"] = growths
        report["firstAutomaticInputMilliseconds"] = firstInput.map { $0 * 1000 } ?? -1
        report["firstGrowthMillisecondsFromInput"] = firstGrowth.flatMap { growth in firstInput.map { (growth - $0) * 1000 } } ?? -1
        report["finishButtonCompletionCallbacks"] = completedCount
        report["frameProviderCalls"] = frameRequests
        report["productSampledFrames"] = session.sampledFramesForVerification
        report["productStatus"] = session.snapshotForVerification.status
        report["retainedOutputHeight"] = session.stateForVerification.height
        report["storyFrames"] = story.count
        if !story.isEmpty {
            try? writeGIF(story, directory.appendingPathComponent(prefix + "-interaction.gif"))
            try? writePNG(contactSheet(story), directory.appendingPathComponent(prefix + "-contact-sheet.png"))
        }
        await session.closeForVerification()
        report["productSessionClosed"] = session.isClosedForVerification
        if !session.isClosedForVerification {
            report["status"] = "failed"
            report["cleanupError"] = "Automatic product session did not report closed after bounded closeForVerification"
        }
        report["finishButtonCompletionCallbacks"] = completedCount
        if report["status"] as? String == "passed", completedCount != 1 {
            report["status"] = "failed"
            report["completionError"] = "Automatic capture did not retain exactly one completion through closure"
        }
        window.close()
        report["ownedWindowClosed"] = !window.isVisible
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

    /// Save actual native scene pixels for both appearances, restoring Aqua.
    private static func recoveryAppearances(window: NSWindow, controls: LiveScrollCaptureController,
                                            directory: URL, stem: String, caption: String) throws {
        let panels = [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow]
        defer { for panel in panels { panel?.appearance = NSAppearance(named: .aqua) } }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for panel in panels { panel?.appearance = NSAppearance(named: appearance) }
            try writePNG(try scene(window: window, controls: controls, caption: caption),
                         directory.appendingPathComponent(stem + "-" + name + ".png"))
        }
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
        for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
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
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
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
        for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
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
        try numberedReference(initial: initial, totalHeight: totalHeight, illustrated: false)
    }

    private static func numberedReference(initial: CGImage, totalHeight: Int, illustrated: Bool) throws -> CGImage {
        let page = NumberedDocument(frame: CGRect(x: 0, y: 0, width: width, height: totalHeight - headerHeight))
        page.illustrated = illustrated; page.appearance = NSAppearance(named: .aqua)
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
        snapshot.previewPositionVerified = update.state.matched && !update.state.previewUnavailable
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
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * h)
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        return try unwrap(bitmap.cgImage, "Native snapshot was empty")
    }

    private static func scene(window: NSWindow, controls: LiveScrollCaptureController, caption: String) throws -> CGImage {
        let windows = [window, controls.outlineWindow, controls.previewWindow, controls.toolbarWindow,
                       controls.handleWindow].compactMap { $0 }.filter(\.isVisible)
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
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                "Pixel comparison allocation failed")
            context.setBlendMode(.copy); context.interpolationQuality = .none
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

// A separate owned-source case exercises the actual movement action and source crop.
extension LiveScrollUsabilityDemoFixture {
    static func verifyMovement(evidenceDirectory directory: URL) async -> [String: Any] {
        var report: [String: Any] = ["status": "running", "productSessionControllerExercised": true,
            "captureMode": "injected-rendered-owned-window-current-region",
            "realScreenCaptureClaimed": false, "permissionRequested": false,
            "globalInputPosted": false, "privateUserContent": false,
            "headerExcluded": true, "newMenuHarness": false,
            "scope": "Persistent direct handle, native axis-constrained drag/release and Escape rollback with visible HUD/preview; actual changed source crop, continued capture and product Finish"]
        let started = ProcessInfo.processInfo.systemUptime
        var session: LiveScrollSessionController?
        var ownedSource: MovementRejectingSource?
        var ownedWindow: NSWindow?
        var providerCalls = 0, providerRegions: [[CGFloat]] = []
        var trace: [[String: Any]] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let screen = try unwrap(NSScreen.main, "Movement demo requires a native display")
            let displayID = try unwrap(screen.displayID, "Movement display has no identity")
            let displayBounds = CGDisplayBounds(displayID), visible = screen.visibleFrame
            try require(visible.height >= 680, "Movement demo needs a 680-point usable native display")
            let nativeHeight = min(CGFloat(700), visible.height - 40)
            // The injected raster is 1 px per point; align its display-relative origin
            // before converting from top-left display coordinates to AppKit coordinates.
            let windowLeft = (visible.midX - screen.frame.minX - CGFloat(width) / 2).rounded()
            let windowTop = (screen.frame.maxY - visible.maxY + 18).rounded()
            let window = NSWindow(contentRect: CGRect(x: screen.frame.minX + windowLeft,
                y: screen.frame.maxY - windowTop - nativeHeight, width: CGFloat(width), height: nativeHeight),
                styleMask: .borderless, backing: .buffered, defer: false)
            ownedWindow = window
            window.title = "PicShot · Move capture region"
            window.isReleasedWhenClosed = false; window.hasShadow = false
            window.backgroundColor = .white; window.appearance = NSAppearance(named: .aqua)
            let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: CGFloat(width), height: nativeHeight))
            let document = NumberedDocument(frame: CGRect(x: 0, y: 0, width: width, height: 8000))
            document.illustrated = false
            scrollView.documentView = document; scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = false; scrollView.hasHorizontalScroller = false
            scrollView.verticalScrollElasticity = .none; scrollView.horizontalScrollElasticity = .none
            scrollView.backgroundColor = .white; scrollView.drawsBackground = true
            scrollView.automaticallyAdjustsContentInsets = false
            window.contentView = scrollView; window.orderFrontRegardless(); window.displayIfNeeded()
            let windowOnDisplay = CGRect(x: window.frame.minX - screen.frame.minX,
                y: screen.frame.maxY - window.frame.maxY, width: window.frame.width, height: window.frame.height)
            let originalRegion = CGRect(x: windowOnDisplay.minX, y: windowOnDisplay.minY + 80,
                                        width: CGFloat(width), height: CGFloat(height))
            let target = LiveScrollScreenSource.Target(pid: ProcessInfo.processInfo.processIdentifier,
                windowID: CGWindowID(window.windowNumber),
                bounds: windowOnDisplay.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY))
            let reference = MovementSourceReference()
            let baseSource = try LiveScrollVerificationFrameSource(region: originalRegion, displayBounds: displayBounds,
                target: target, image: { [reference, weak scrollView, weak window] in
                    try await Task.sleep(nanoseconds: 66_666_667)
                    guard let source = reference.source, let scrollView, let window,
                          window.windowNumber == Int(target.windowID) else {
                        throw DemoFailure(errorDescription: "Owned movement source identity disappeared")
                    }
                    // The base source owns/cancels this worker. Hold only its next
                    // post-rejection raster while native error controls are observed.
                    if source.holdRejectedFrame {
                        let deadline = ProcessInfo.processInfo.systemUptime + 2
                        while source.holdRejectedFrame && ProcessInfo.processInfo.systemUptime < deadline {
                            try await Task.sleep(nanoseconds: 25_000_000)
                        }
                    }
                    let region = source.region
                    let crop = region.offsetBy(dx: -windowOnDisplay.minX, dy: -windowOnDisplay.minY)
                    try require(CGRect(origin: .zero, size: scrollView.bounds.size).contains(crop),
                                "Moved capture escaped its original owned document window")
                    providerCalls += 1
                    if providerRegions.count < 120 { providerRegions.append([region.minX, region.minY, region.width, region.height]) }
                    let full = try nativeImage(scrollView)
                    return try unwrap(full.cropping(to: crop), "Cannot crop actual moved source region")
                })
            let source = MovementRejectingSource(base: baseSource)
            ownedSource = source; reference.source = source
            var output: CGImage?, completions = 0
            let controller = LiveScrollSessionController(onComplete: { image in output = image; completions += 1 }, onImport: {})
            session = controller
            try await controller.startForVerification(source: source, screen: screen)
            try await waitFor("Movement source produced no preview", timeout: 5) {
                controller.stateForVerification.acceptedObservations > 0
            }
            let controls = try unwrap(controller.controlsForVerification, "Movement controls absent")
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
                panel?.appearance = NSAppearance(named: .aqua)
            }
            var story = [try scene(window: window, controls: controls, caption: "Capture an inner band of the actual native document")]
            try writePNG(story[0], directory.appendingPathComponent("live-scroll-movement-native-first.png"))
            try await movementWheelRun(scrollView, session: controller, count: 90, phase: "before move", trace: &trace)
            try await waitFor("Initial movement capture did not join", timeout: 5) {
                controller.stateForVerification.viewportOffset == Int(scrollView.contentView.bounds.minY.rounded())
            }
            let before = controller.stateForVerification
            let cropBefore = source.region.offsetBy(dx: -windowOnDisplay.minX, dy: -windowOnDisplay.minY)
            let beforePixels = try normalizedPixels(try unwrap(nativeImage(scrollView).cropping(to: cropBefore), "Initial crop absent"))
            story.append(try scene(window: window, controls: controls, caption: "Before drag · live capture and persistent handle"))
            let handleWindow = try unwrap(controls.handleWindow, "Persistent region drag handle window absent")
            let handle = try unwrap(handleWindow.contentView as? LiveScrollRegionDragHandle,
                                    "Persistent region drag handle view absent")
            let thumbnail = try unwrap(controls.previewWindow?.contentView as? LiveScrollThumbnailView,
                                       "Movement thumbnail absent")
            let original = source.region
            let originalFrame = CGRect(x: screen.frame.minX + original.minX,
                y: screen.frame.maxY - original.maxY, width: original.width, height: original.height)
            try require(controls.outlineWindow?.frame == originalFrame.insetBy(dx: -3, dy: -3),
                        "Persistent outline started with a different source region")
            try require(handle.isEnabled && handleWindow.isVisible && !handleWindow.ignoresMouseEvents,
                        "Persistent drag handle is not an available mouse target")
            let retainedThumbnailPixels = try normalizedPixels(try unwrap(thumbnail.image, "No thumbnail before movement"))
            let downPoint = CGPoint(x: handleWindow.frame.midX, y: handleWindow.frame.midY)
            let localPoint = handle.convert(handleWindow.convertPoint(fromScreen: downPoint), from: nil)
            try require(handle.hitTest(handle.convert(localPoint, to: handle.superview)) === handle,
                        "Persistent move target was not hit-testable")
            try movementMouse(.leftMouseDown, screenPoint: downPoint, window: handleWindow)
            try require(handle.isDragging && handleWindow.isKeyWindow && handleWindow.firstResponder === handle,
                        "Persistent handle did not receive native drag and Escape focus")
            // AppKit screen Y increases upward. Moving down 32 points proposes a
            // +32 display-relative crop; release advances to +48 independently.
            let draggedPoint = CGPoint(x: downPoint.x + 24, y: downPoint.y - 32)
            let releasedPoint = CGPoint(x: downPoint.x + 24, y: downPoint.y - 48)
            try movementMouse(.leftMouseDragged, screenPoint: draggedPoint, window: handleWindow)
            let proposedFrame = try unwrap(controls.outlineWindow?.frame, "Dragged outline absent").insetBy(dx: 3, dy: 3)
            let hudVisible = controls.toolbarWindow?.isVisible == true
            let previewVisible = controls.previewWindow?.isVisible == true
            let retainedDuringDrag = try normalizedPixels(try unwrap(thumbnail.image, "Drag removed the accepted preview"))
                == retainedThumbnailPixels
            let dragLabel = thumbnail.accessibilityLabel() ?? ""
            let dragAccessibilityUnverified = dragLabel.contains("尚未验证") && !dragLabel.contains("绿色")
            report["duringDrag"] = ["toolbarVisible": hudVisible, "previewVisible": previewVisible,
                "handleVisible": handleWindow.isVisible, "lastGoodPreviewPixelsPreserved": retainedDuringDrag,
                "previewPositionUnverified": !thumbnail.isPositionVerified,
                "previewMarkerAmber": thumbnail.viewportMarkerColor == .systemOrange,
                "previewAccessibilityUnverified": dragAccessibilityUnverified,
                "sourceRegionUnchanged": source.region == original,
                "fullscreenMoveViewAbsent": controller.activeMoveViewForVerification == nil,
                "proposedAppKitFrame": movementRect(proposedFrame)]
            try require(hudVisible && previewVisible && handleWindow.isVisible && retainedDuringDrag,
                        "Direct dragging hid the HUD/preview or discarded accepted preview pixels")
            try require(!thumbnail.isPositionVerified && thumbnail.viewportMarkerColor == .systemOrange
                && dragAccessibilityUnverified && source.region == original
                && controller.activeMoveViewForVerification == nil,
                        "A direct drag applied its uncommitted source or claimed a verified preview position")
            try require(proposedFrame == originalFrame.offsetBy(dx: 0, dy: -32),
                        "Direct drag failed to move the visible frame along its active axis")
            let draggingScene = try scene(window: window, controls: controls,
                caption: "Dragging the handle · HUD and last-good preview stay visible")
            story.append(draggingScene)
            try writePNG(draggingScene, directory.appendingPathComponent("live-scroll-movement-native-drag.png"))
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
                panel?.appearance = NSAppearance(named: .darkAqua)
            }
            let darkDraggingScene = try scene(window: window, controls: controls,
                caption: "Dark appearance while dragging · persistent controls and retained preview")
            story.append(darkDraggingScene)
            try writePNG(darkDraggingScene, directory.appendingPathComponent("live-scroll-movement-native-dark-drag.png"))
            for panel in [controls.toolbarWindow, controls.previewWindow, controls.outlineWindow, controls.handleWindow] {
                panel?.appearance = NSAppearance(named: .aqua)
            }
            report["dragAppearanceEvidence"] = ["light": "live-scroll-movement-native-drag.png",
                "dark": "live-scroll-movement-native-dark-drag.png", "restoredAppearance": "aqua"]
            try movementMouse(.leftMouseUp, screenPoint: releasedPoint, window: handleWindow)
            let dragged = original.offsetBy(dx: 0, dy: 48)
            try await waitFor("Mouse release did not apply and resume the actual region", timeout: 5) {
                source.region == dragged && !controller.snapshotForVerification.busy
                    && !controller.snapshotForVerification.paused && !handle.isDragging
            }
            report["drag"] = ["requestedDelta": [24, 48], "requestedAppKitDelta": [24, -48],
                "lastDragAppKitDelta": [24, -32], "original": movementRect(original),
                "afterDrag": movementRect(source.region), "crossAxisUnchanged": source.region.minX == original.minX,
                "sizeUnchanged": source.region.size == original.size, "alongAxisDelta": source.region.minY - original.minY,
                "finalReleasePositionApplied": source.region == dragged,
                "route": "owned persistent handle NSWindow.sendEvent mouseDown/mouseDragged/mouseUp with hit-test; global screen points reconverted after every panel move"]
            try require(source.region.minX == original.minX && source.region.minY == original.minY + 48
                && source.region.size == original.size,
                "Active direct Move was not constrained to its scroll axis or ignored final mouse-up position")
            try await waitFor("Changed source crop did not match its real document displacement", timeout: 5) {
                controller.stateForVerification.viewportOffset == before.viewportOffset + 48
                    && thumbnail.isPositionVerified
            }
            let cropAfter = source.region.offsetBy(dx: -windowOnDisplay.minX, dy: -windowOnDisplay.minY)
            let afterPixels = try normalizedPixels(try unwrap(nativeImage(scrollView).cropping(to: cropAfter), "Moved crop absent"))
            report["moveAppliedThroughReturn"] = false
            report["moveAppliedThroughMouseRelease"] = true
            report["actualSourcePixelsChanged"] = beforePixels != afterPixels
            report["matchedMoveDisplacement"] = controller.stateForVerification.viewportOffset - before.viewportOffset
            report["ownedTargetIdentityUnchanged"] = source.target == target
            try require(beforePixels != afterPixels && source.target == target,
                        "Moved-region provider returned unchanged pixels or changed its owned target")
            story.append(try scene(window: window, controls: controls,
                caption: "Released · actual source moved 48 px and the seam is verified"))

            // Cancel a second real drag after successful capture has resumed.
            // The source and accepted output must roll back together, and the
            // pending native mouse-up must not apply the cancelled proposal.
            let rollbackState = controller.stateForVerification
            let rollbackThumbnail = try normalizedPixels(try unwrap(thumbnail.image, "No preview before rollback"))
            let rollbackDown = CGPoint(x: handleWindow.frame.midX, y: handleWindow.frame.midY)
            let rollbackPoint = CGPoint(x: rollbackDown.x + 18, y: rollbackDown.y - 24)
            try movementMouse(.leftMouseDown, screenPoint: rollbackDown, window: handleWindow)
            try movementMouse(.leftMouseDragged, screenPoint: rollbackPoint, window: handleWindow)
            try require(handle.isDragging && handleWindow.isKeyWindow && handleWindow.firstResponder === handle,
                        "Second direct drag did not retain native Escape focus")
            let rollbackProposed = try unwrap(controls.outlineWindow?.frame, "Rollback proposal outline absent").insetBy(dx: 3, dy: 3)
            try require(rollbackProposed == originalFrame.offsetBy(dx: 0, dy: -72) && source.region == dragged,
                        "Second drag failed to propose a visible move without applying its source")
            let escape = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: handleWindow.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
                "Escape event unavailable")
            handleWindow.sendEvent(escape)
            try movementMouse(.leftMouseUp, screenPoint: rollbackPoint, window: handleWindow)
            try await waitFor("Escape did not restore the accepted region and resume capture", timeout: 5) {
                !controller.snapshotForVerification.busy && !controller.snapshotForVerification.paused
                    && !handle.isDragging && thumbnail.isPositionVerified
            }
            let rollbackPixels = try normalizedPixels(try unwrap(thumbnail.image, "Escape removed the accepted preview"))
            let rollbackPreserved = source.region == dragged && rollbackPixels == rollbackThumbnail
                && controller.stateForVerification.height == rollbackState.height
                && controller.stateForVerification.viewportOffset == rollbackState.viewportOffset
                && controls.outlineWindow?.frame == originalFrame.offsetBy(dx: 0, dy: -48).insetBy(dx: -3, dy: -3)
            report["escapeRollback"] = ["passed": rollbackPreserved, "sourceRegionPreserved": source.region == dragged,
                "acceptedHeightPreserved": controller.stateForVerification.height == rollbackState.height,
                "acceptedOffsetPreserved": controller.stateForVerification.viewportOffset == rollbackState.viewportOffset,
                "lastGoodPreviewPixelsPreserved": rollbackPixels == rollbackThumbnail,
                "captureResumed": !controller.snapshotForVerification.paused,
                "trailingMouseUpIgnored": source.region == dragged,
                "route": "owned key handle window sendEvent Escape to actual first responder, followed by native mouse-up"]
            try require(rollbackPreserved, "Escape or trailing release changed accepted region, output or preview")
            let rollbackScene = try scene(window: window, controls: controls,
                caption: "Escape cancels another drag · accepted region and long image preserved")
            story.append(rollbackScene)
            try writePNG(rollbackScene, directory.appendingPathComponent("live-scroll-movement-native-rollback.png"))
            // Reject one proposal through the same native pointer path. All other
            // movement/source operations, identities and lifetime belong to base.
            let rejectedState = controller.stateForVerification
            let rejectedThumbnail = try normalizedPixels(try unwrap(thumbnail.image, "No preview before rejected move"))
            let rejectedRegion = source.region
            let resumesBeforeRejection = source.resumeCount
            let pausesBeforeRejection = source.pauseCount
            source.rejectNextMove = true
            let rejectDown = CGPoint(x: handleWindow.frame.midX, y: handleWindow.frame.midY)
            let rejectPoint = CGPoint(x: rejectDown.x + 12, y: rejectDown.y - 16)
            let rejectLocal = handle.convert(handleWindow.convertPoint(fromScreen: rejectDown), from: nil)
            try require(handle.hitTest(handle.convert(rejectLocal, to: handle.superview)) === handle,
                        "Rejected move handle is not hit-testable")
            try movementMouse(.leftMouseDown, screenPoint: rejectDown, window: handleWindow)
            try movementMouse(.leftMouseDragged, screenPoint: rejectPoint, window: handleWindow)
            try movementMouse(.leftMouseUp, screenPoint: rejectPoint, window: handleWindow)
            try await waitFor("Rejected move did not resume its original source with an active error", timeout: 5) {
                source.rejectedMoveCount == 1 && source.resumeCount == resumesBeforeRejection + 1
                    && source.captureRunning && !controller.snapshotForVerification.paused
                    && !controller.snapshotForVerification.busy && controller.snapshotForVerification.statusKind == .error
            }
            let pause = try unwrap(findButton("scroll.live.pauseResume", in: controls.toolbarWindow?.contentView),
                                   "Pause missing after rejected move resumed")
            var rejection: [String: Any] = ["status": "running", "injectedMoveFailures": source.rejectedMoveCount,
                "moveRoute": "owned handle NSWindow.sendEvent mouseDown/mouseDragged/mouseUp with hit-test",
                "pauseButtonRoute": "accepted native hit-test/mouse helper PortableSettingsUIPreviewFixture.click",
                "resumeCallsAfterRejection": source.resumeCount - resumesBeforeRejection,
                "pauseCallsForDrag": source.pauseCount - pausesBeforeRejection,
                "activeErrorStatus": controller.snapshotForVerification.statusKind == .error,
                "activeSourceResumed": source.captureRunning && !controller.snapshotForVerification.paused,
                "activePauseLabel": pause.accessibilityLabel() ?? "", "activePauseTooltip": pause.toolTip ?? "",
                "activePauseEnabled": pause.isEnabled,
                "sourceRegionPreserved": source.region == rejectedRegion,
                "ownedTargetIdentityUnchanged": source.target == target,
                "retainedHeight": rejectedState.height, "retainedOffset": rejectedState.viewportOffset,
                "retainedAcceptedObservations": rejectedState.acceptedObservations,
                "sourcePacingMaximumSeconds": 2,
                "activeAppearanceEvidence": ["light": "live-scroll-rejected-move-active-light.png", "dark": "live-scroll-rejected-move-active-dark.png"],
                "pausedAppearanceEvidence": ["light": "live-scroll-rejected-move-paused-light.png", "dark": "live-scroll-rejected-move-paused-dark.png"]]
            report["rejectedMovePause"] = rejection
            try require(pause.isEnabled && pause.accessibilityLabel() == "暂停捕获" && pause.toolTip == "暂停捕获"
                && source.region == rejectedRegion && source.target == target,
                "Resumed source error displayed Retry instead of the actual Pause action")
            try recoveryAppearances(window: window, controls: controls, directory: directory,
                stem: "live-scroll-rejected-move-active", caption: "Move rejected · original source resumed · Pause remains available")
            try require(controller.snapshotForVerification.statusKind == .error
                && !controller.snapshotForVerification.paused && pause.accessibilityLabel() == "暂停捕获",
                "Active-error state disappeared before native Pause input")
            let pausesBeforeClick = source.pauseCount
            try PortableSettingsUIPreviewFixture.click(pause)
            try await waitFor("Native Pause did not drain the resumed source after rejection", timeout: 5) {
                controller.snapshotForVerification.paused && !controller.snapshotForVerification.busy
                    && !source.captureRunning && source.pauseCount == pausesBeforeClick + 1
            }
            source.holdRejectedFrame = false
            let pausedProviderCalls = providerCalls
            let pausedSamples = controller.sampledFramesForVerification
            try await Task.sleep(nanoseconds: 220_000_000)
            let pausedState = controller.stateForVerification
            let pausedPixels = try normalizedPixels(try unwrap(thumbnail.image, "Pause lost rejected move preview"))
            rejection["pauseClickDrainedSource"] = source.pauseCount == pausesBeforeClick + 1 && !source.captureRunning
            rejection["pauseStoppedProviderCalls"] = providerCalls == pausedProviderCalls
            rejection["pauseStoppedSamples"] = controller.sampledFramesForVerification == pausedSamples
            rejection["pausedHeight"] = pausedState.height; rejection["pausedOffset"] = pausedState.viewportOffset
            rejection["pausedAcceptedObservations"] = pausedState.acceptedObservations
            rejection["pausedPreviewPixelsPreserved"] = pausedPixels == rejectedThumbnail
            rejection["pausedSourceRegionPreserved"] = source.region == rejectedRegion
            rejection["pausedLabel"] = pause.accessibilityLabel() ?? ""
            try require(pausedPixels == rejectedThumbnail && pausedState.height == rejectedState.height
                && pausedState.viewportOffset == rejectedState.viewportOffset
                && pausedState.acceptedObservations == rejectedState.acceptedObservations
                && source.region == rejectedRegion && providerCalls == pausedProviderCalls
                && controller.sampledFramesForVerification == pausedSamples && pause.accessibilityLabel() == "继续捕获",
                "Native Pause failed to stop acquisition or preserve the accepted moved output")
            try recoveryAppearances(window: window, controls: controls, directory: directory,
                stem: "live-scroll-rejected-move-paused", caption: "Native Pause drained capture · accepted long image preserved")
            try PortableSettingsUIPreviewFixture.click(pause)
            try await waitFor("Native Resume after rejected-move Pause did not reconnect", timeout: 5) {
                !controller.snapshotForVerification.paused && !controller.snapshotForVerification.busy
                    && source.captureRunning && thumbnail.isPositionVerified
            }
            rejection["nativeResumeRejoined"] = true; rejection["status"] = "passed"
            report["rejectedMovePause"] = rejection
            try await movementWheelRun(scrollView, session: controller, count: 60, phase: "after move", trace: &trace)
            let expectedOffset = Int(scrollView.contentView.bounds.minY.rounded()) + 48
            try await waitFor("Capture did not continue after moving its region", timeout: 5) {
                controller.stateForVerification.viewportOffset == expectedOffset
            }
            story.append(try scene(window: window, controls: controls, caption: "Continued scrolling after Move · ready to Finish"))
            let finish = try unwrap(findButton("scroll.live.finish", in: controls.toolbarWindow?.contentView), "Actual Finish absent")
            try PortableSettingsUIPreviewFixture.click(finish)
            try await waitFor("Actual Finish did not deliver moved-region output", timeout: 8) { output != nil }
            let image = try unwrap(output, "Moved-region Finish returned no output")
            let expectedHeight = height + expectedOffset
            let referencePage = NumberedDocument(frame: CGRect(x: 0, y: 0, width: width, height: 80 + expectedHeight))
            referencePage.illustrated = false; referencePage.appearance = NSAppearance(named: .aqua)
            let expectedImage = try unwrap(nativeImage(referencePage).cropping(to: CGRect(x: 0, y: 80, width: width, height: expectedHeight)),
                                           "Independent moved-range document reference absent")
            let comparison = try nativeRasterComparison(image, expectedImage)
            report["referenceComparison"] = comparison
            report["referenceDocumentRange"] = [80, 80 + expectedHeight]
            report["finishCallbacks"] = completions; report["providerCalls"] = providerCalls
            report["providerRegions"] = providerRegions; report["trace"] = trace
            report["nativeWheelEvents"] = 150
            report["escapeKeyRoute"] = "owned key handle window sendEvent to actual first responder"
            try writePNG(image, directory.appendingPathComponent("live-scroll-movement-finished.png"))
            try writePNG(expectedImage, directory.appendingPathComponent("live-scroll-movement-reference.png"))
            try writeGIF(try uniformMovementFrames(story), directory.appendingPathComponent("live-scroll-movement-interaction.gif"))
            try writePNG(try contactSheet(story), directory.appendingPathComponent("live-scroll-movement-contact-sheet.png"))
            try require(completions == 1 && comparison["passed"] as? Bool == true,
                        "Moved capture lost or duplicated independent document pixels")
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            if let session { report["productStatus"] = session.snapshotForVerification.status }
            if let window = ownedWindow, let controls = session?.controlsForVerification,
               let image = try? scene(window: window, controls: controls, caption: "Actual movement session failure") {
                try? writePNG(image, directory.appendingPathComponent("live-scroll-movement-failure.png"))
            }
        }
        report["providerCalls"] = providerCalls; report["providerRegions"] = providerRegions
        report["trace"] = trace
        await session?.closeForVerification()
        report["ownedSourceStopped"] = ownedSource.map { $0.stopCount > 0 && !$0.captureRunning } ?? (session == nil)
        if report["ownedSourceStopped"] as? Bool != true { report["status"] = "failed" }
        report["productSessionClosed"] = session?.isClosedForVerification ?? true
        if session?.isClosedForVerification == false { report["status"] = "failed"; report["cleanupError"] = "Session retirement unconfirmed" }
        ownedWindow?.close()
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("live-scroll-movement.json"), options: .atomic)
        }
        return report
    }

    @MainActor private final class MovementSourceReference { weak var source: MovementRejectingSource? }

    /// Verification-only owner of the existing source. One deliberate rejection
    /// precedes delegation; normal frame identity, crop, mailbox and teardown stay
    /// with the strongly owned base. Its image closure refers back only weakly.
    @MainActor private final class MovementRejectingSource: LiveScrollFrameSource {
        let base: LiveScrollVerificationFrameSource
        var rejectNextMove = false
        var holdRejectedFrame = false
        private(set) var rejectedMoveCount = 0
        private(set) var resumeCount = 0
        private(set) var pauseCount = 0
        private(set) var stopCount = 0
        private(set) var captureRunning = false
        init(base: LiveScrollVerificationFrameSource) { self.base = base }
        var region: CGRect { base.region }
        var displayBounds: CGRect { base.displayBounds }
        var target: LiveScrollScreenSource.Target? { base.target }
        var automaticScrollWatermark: LiveScrollFrameWatermark? { base.automaticScrollWatermark }
        func start() async throws { try await base.start(); captureRunning = true }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            try await base.nextFrame(timeout: timeout)
        }
        func pauseAndDrain() async throws {
            try await base.pauseAndDrain(); pauseCount += 1; captureRunning = false
        }
        func resume() async throws { try await base.resume(); resumeCount += 1; captureRunning = true }
        func stop() async throws { try await base.stop(); stopCount += 1; captureRunning = false }
        func validateTarget() throws { try base.validateTarget() }
        func moveRegion(to proposed: CGRect) throws {
            if rejectNextMove {
                rejectNextMove = false; rejectedMoveCount += 1; holdRejectedFrame = true
                throw DemoFailure(errorDescription: "Owned verification rejects exactly one proposed move")
            }
            try base.moveRegion(to: proposed)
        }
    }

    private static func movementWheelRun(_ view: NSScrollView, session: LiveScrollSessionController,
                                        count: Int, phase: String, trace: inout [[String: Any]]) async throws {
        for index in 0..<count {
            try Task.checkCancellation()
            try scroll(view, pixels: 4)
            if index % 10 == 0 {
                trace.append(["phase": phase, "event": index + 1, "nativeScrollOffset": view.contentView.bounds.minY,
                    "acceptedOffset": session.stateForVerification.viewportOffset,
                    "outputHeight": session.stateForVerification.height,
                    "status": session.snapshotForVerification.status])
            }
            try await Task.sleep(nanoseconds: 33_333_333)
        }
    }

    private static func movementMouse(_ type: NSEvent.EventType, screenPoint: CGPoint, window: NSWindow) throws {
        // The handle panel moves during a drag; convert the fixed global pointer
        // again for each event, rather than adding deltas to its new local origin.
        let event = try unwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1), "Move mouse event unavailable")
        window.sendEvent(event)
    }

    private static func uniformMovementFrames(_ images: [CGImage]) throws -> [CGImage] {
        let width = images.map(\.width).max() ?? 1, height = images.map(\.height).max() ?? 1
        return try images.map { image in
            let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                "Movement frame canvas allocation failed")
            context.setFillColor(NSColor(calibratedWhite: 0.91, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: (width - image.width) / 2, y: (height - image.height) / 2,
                                          width: image.width, height: image.height))
            return try unwrap(context.makeImage(), "Movement frame canvas absent")
        }
    }

    private static func movementRect(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
}
