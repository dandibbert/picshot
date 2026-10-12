import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// One bounded output demonstration. Acquisition alone is injected: the real
/// session owns sampling, stitching, output actions, delivery and retirement.
/// Source pixels, preferences, pin assets and output files are fixture-owned.
@MainActor
enum LiveScrollOutputDemoFixture {
    private static let width = 480
    private static let viewportHeight = 320
    private static let offsets = [0, 96, 192, 288, 384]

    static func verify(evidenceDirectory directory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = ProcessInfo.processInfo.systemUptime
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        var report: [String: Any] = [
            "schemaVersion": 1, "status": "running", "productSessionControllerExercised": true,
            "productSessionClosed": false,
            "source": "Fixture-owned native numbered document; deterministic viewport crops",
            "acquisition": "LiveScrollVerificationFrameSource; actual product sampling and assembler",
            "realScreenCaptureClaimed": false, "screenCaptureAPICalled": false,
            "permissionRequested": false, "globalInputPosted": false, "networkUsed": false,
            "userHistoryReadOrWritten": false, "standardDefaultsReadOrWritten": false,
            "generalPasteboardReadOrWritten": false,
            "limitations": ["Owned acquisition proves output routing, not ScreenCaptureKit or third-party scrolling",
                "Copy rejection is injected at the recipient boundary; no clipboard compatibility claim",
                "Native control pixels are cached and composited over resolved native window backgrounds; no desktop screenshot"],
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown"
        ]
        try write(report, directory: directory)
        var root: URL?
        var safeToRemove = true
        do {
            let screen = try unwrap(NSScreen.main, "An AppKit display is required")
            let owned = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-LiveOutput-" + UUID().uuidString)
            root = owned
            report["canonicalPrivateTemporaryRoot"] = true
            let document = NumberedDocument(frame: CGRect(x: 0, y: 0, width: width,
                height: viewportHeight + (offsets.last ?? 0)))
            document.appearance = NSAppearance(named: .aqua)
            let reference = try nativeImage(view: document)
            try writePNG(reference, directory.appendingPathComponent("output-owned-numbered-reference.png"))
            report["sourceReference"] = try imageFacts(reference)
            let save = await saveCase(reference: reference, screen: screen, root: owned, directory: directory)
            report["stitchedCopyFailureThenSave"] = save
            safeToRemove = save["cleanupSafe"] as? Bool == true
            try write(report, directory: directory)
            let pin: [String: Any]
            if safeToRemove {
                pin = await pinCase(reference: reference, screen: screen, root: owned, directory: directory)
                safeToRemove = pin["cleanupSafe"] as? Bool == true
            } else {
                pin = ["status": "blocked", "reason": "Previous session or save worker did not retire"]
            }
            report["singleViewportPin"] = pin
            let sessionsClosed = save["productSessionClosed"] as? Bool == true && pin["productSessionClosed"] as? Bool == true
            report["productSessionClosed"] = sessionsClosed
            report["status"] = save["status"] as? String == "passed" && pin["status"] as? String == "passed"
                && sessionsClosed && safeToRemove ? "passed" : "failed"
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
        }
        if let root, safeToRemove {
            do { try files.removeItem(at: root); report["privateTemporaryRootRemoved"] = !files.fileExists(atPath: root.path) }
            catch { report["status"] = "failed"; report["cleanupError"] = error.localizedDescription }
        } else if root != nil {
            report["privateTemporaryRootRemoved"] = false
            report["cleanupError"] = "Retained synthetic temporary files because retirement was not confirmed"
        }
        report["cleanupSafe"] = safeToRemove && (report["privateTemporaryRootRemoved"] as? Bool == true)
        if report["cleanupSafe"] as? Bool != true { report["status"] = "failed" }
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        try write(report, directory: directory)
        try require(report["status"] as? String == "passed", "Output demonstration failed; see live-scroll-output.json")
        return report
    }

    private static func saveCase(reference: CGImage, screen: NSScreen, root: URL,
                                 directory: URL) async -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        var report: [String: Any] = ["status": "running", "case": "stitched-copy-rejection-then-save",
            "sessionOwner": "LiveScrollSessionController", "outputOwner": "LiveScrollSaveDelivery → SaveWorkflowPresenter → SaveWorkflowService",
            "saveMenuIdentifier": "scroll.live.quickSave", "copyButtonIdentifier": "scroll.live.copy",
            "menuDispatch": "NSApp.sendAction on the production More menu item", "viewportOffsets": offsets]
        let suite = "PicShot-LiveOutput-Save-" + UUID().uuidString
        var defaults: UserDefaults?
        var presenter: SaveWorkflowPresenter?
        var session: LiveScrollSessionController?
        var copyAttempts = 0, editorCallbacks = 0, importCallbacks = 0, saveAdmissions = 0
        var rejectedCopyImage: CGImage?
        var saveJob: SaveWorkflowController?
        var provider: OwnedProvider?
        do {
            let settingsDefaults = try unwrap(UserDefaults(suiteName: suite), "Isolated save defaults unavailable")
            defaults = settingsDefaults
            let savedDirectory = root.appendingPathComponent("saved", isDirectory: true)
            let spool = root.appendingPathComponent("save-spool", isDirectory: true)
            try FileManager.default.createDirectory(at: savedDirectory, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false)
            let approved = try SaveWorkflowUIPreviewFixture.canonicalExistingDirectory(savedDirectory)
            try SaveWorkflowSettings(baseURL: approved, filenameTemplate: "owned-long-output-{counter}").save(to: settingsDefaults)
            let output = SaveWorkflowPresenter(defaults: settingsDefaults)
            presenter = output
            output.onPresent = { saveAdmissions += 1; saveJob = $0 }
            let input = try OwnedProvider(reference: reference)
            provider = input
            let owner = LiveScrollSessionController(onComplete: { _ in editorCallbacks += 1 },
                onImport: { importCallbacks += 1 }, onCopy: { image in
                    copyAttempts += 1; rejectedCopyImage = image
                    throw failure("Injected clipboard rejection")
                }, saveDestination: LiveScrollSaveDelivery(presenter: output), resourceStorageParent: spool,
                automaticScrollPermission: { false })
            session = owner
            try await start(owner, provider: input, screen: screen)
            var trace: [[String: Any]] = []
            for offset in offsets {
                try input.select(offset: offset)
                try await until("Viewport did not reach offset \(offset)", seconds: 5) {
                    owner.stateForVerification.matched && owner.stateForVerification.acceptedObservations > 0
                        && owner.stateForVerification.viewportOffset == offset
                }
                let state = owner.stateForVerification
                trace.append(["offset": offset, "width": state.width, "height": state.height,
                    "acceptedObservations": state.acceptedObservations, "committedSources": state.committedSources])
            }
            report["trace"] = trace
            let before = owner.stateForVerification
            try require(before.width == width && before.height == reference.height && before.height > viewportHeight * 2,
                        "Owned sequence did not assemble more than two viewport heights")
            let controls = try unwrap(owner.controlsForVerification, "Live controls missing")
            let toolbar = try unwrap(controls.toolbarWindow?.contentView as? LiveScrollToolbarView, "Native toolbar missing")
            try PortableSettingsUIPreviewFixture.click(toolbar.copyButton)
            try await until("Copy rejection did not restore the paused draft", seconds: 5) {
                copyAttempts == 1 && !owner.snapshotForVerification.busy
                    && owner.snapshotForVerification.statusKind == .error
            }
            let failed = owner.snapshotForVerification
            let after = owner.stateForVerification
            let retained = failed.paused && failed.canCopy && failed.canFinish && failed.canQuickSave
                && !owner.isClosedForVerification && before.width == after.width && before.height == after.height
                && before.acceptedObservations == after.acceptedObservations
            report["copyFailurePausedDraftAndAlternativePreserved"] = retained
            report["copyFailureStatus"] = failed.status
            let rejectedComparison = try compare(unwrap(rejectedCopyImage, "Copy recipient saw no output"), reference)
            report["rejectedCopyComparison"] = rejectedComparison
            try require(rejectedComparison["passed"] as? Bool == true, "Copy recipient did not receive the full owned source union")
            try require(retained, "Rejected Copy lost the paused draft or output alternatives")
            report["controlArtifacts"] = try appearanceSnapshots(window: unwrap(controls.toolbarWindow, "Toolbar window missing"),
                stem: "output-copy-failure-controls", directory: directory)
            let item = try menuItem("scroll.live.quickSave", controls: controls)
            report["saveSelector"] = NSStringFromSelector(try unwrap(item.action, "Quick Save selector missing"))
            try dispatch(item)
            try await until("Save did not publish or report failure", seconds: 12) {
                saveJob?.state == .completed || saveJob?.state == .failed
            }
            let job = try unwrap(saveJob, "More → Quick Save did not create a real job")
            let result = try unwrap(job.result, "Save failed: " + job.statusLabel.stringValue)
            let bytes = try Data(contentsOf: result.savedURL)
            let decoded = try decode(result.savedURL)
            let savedComparison = try compare(decoded, reference)
            report["savedPNGComparison"] = savedComparison
            report["independentPublishedPNGDecode"] = true
            report["savedPNGFileSHA256"] = hash(bytes)
            report["savedPNGByteCount"] = bytes.count
            report["savedFilename"] = result.savedURL.lastPathComponent
            report["saveFeedback"] = job.statusLabel.stringValue
            report["saveFeedbackArtifacts"] = try appearanceSnapshots(window: unwrap(job.window, "Save window missing"),
                stem: "output-save-feedback", directory: directory)
            try bytes.write(to: directory.appendingPathComponent("output-published-long.png"), options: .atomic)
            try require(savedComparison["passed"] as? Bool == true, "Published PNG differs from the owned source union")
            try await until("Successful Save did not retire the session", seconds: 5) { owner.isClosedForVerification }
            report["savePublicationRetiredSession"] = true
            report["savedInsideApprovedPrivateDirectory"] = result.savedURL.deletingLastPathComponent() == approved
            try require(result.savedURL.deletingLastPathComponent() == approved, "Save escaped the approved private directory")
            try require(copyAttempts == 1 && saveAdmissions == 1 && editorCallbacks == 0 && importCallbacks == 0,
                        "An unrelated or repeated output callback ran")
            report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        await session?.closeForVerification()
        presenter?.onPresent = nil
        presenter?.cancelAll()
        do {
            try await until("Save cleanup did not drain", seconds: 5) {
                (presenter?.activeJobCount ?? 0) == 0 && presenter?.controllers.isEmpty != false
            }
        } catch { report["status"] = "failed"; report["cleanupError"] = error.localizedDescription }
        let closed = session?.isClosedForVerification ?? true
        let drained = (presenter?.activeJobCount ?? 0) == 0 && presenter?.controllers.isEmpty != false
            && (presenter?.retainedInputBytes ?? 0) == 0
        if drained { defaults?.removePersistentDomain(forName: suite) }
        report["productSessionClosed"] = closed
        report["saveJobsDrained"] = drained
        report["cleanupSafe"] = closed && drained
        report["copyRecipientAttempts"] = copyAttempts
        report["saveJobAdmissions"] = saveAdmissions
        report["editorCallbacks"] = editorCallbacks; report["importCallbacks"] = importCallbacks
        report["frameProviderCalls"] = provider?.calls ?? 0
        report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        if !closed || !drained { report["status"] = "failed" }
        return report
    }

    private static func pinCase(reference: CGImage, screen: NSScreen, root: URL,
                                directory: URL) async -> [String: Any] {
        var report: [String: Any] = ["status": "running", "case": "single-viewport-pin",
            "sessionOwner": "LiveScrollSessionController", "outputOwner": "PinSessionCoordinator → PinSessionStore",
            "menuIdentifier": "scroll.live.pin", "menuDispatch": "NSApp.sendAction on the production More menu item",
            "pinPreferences": "nil defaults; OCR disabled", "userHistoryReadOrWritten": false]
        var session: LiveScrollSessionController?
        var coordinator: PinSessionCoordinator?
        var pinCallbacks = 0, unexpectedCallbacks = 0
        var pinID: UUID?
        do {
            let spool = root.appendingPathComponent("pin-spool", isDirectory: true)
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false)
            let store = try PinSessionStore(directory: root.appendingPathComponent("pins", isDirectory: true))
            let pins = PinSessionCoordinator(store: store, presentWindows: true,
                desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
                ocrPreferences: PinOCRPreferences(defaults: nil), screens: { [screen.visibleFrame] })
            coordinator = pins
            let input = try OwnedProvider(reference: reference)
            let expected = input.current
            let owner = LiveScrollSessionController(onComplete: { _ in unexpectedCallbacks += 1 },
                onImport: { unexpectedCallbacks += 1 }, onCopy: { _ in unexpectedCallbacks += 1 },
                onPin: { image in
                    pinCallbacks += 1
                    pinID = try pins.add(image: image, title: "Owned live-scroll output demonstration")
                }, resourceStorageParent: spool, automaticScrollPermission: { false })
            session = owner
            try await start(owner, provider: input, screen: screen)
            try await until("Single viewport did not become available", seconds: 5) { owner.snapshotForVerification.canPin }
            let controls = try unwrap(owner.controlsForVerification, "Single viewport controls missing")
            report["controlArtifacts"] = try appearanceSnapshots(window: unwrap(controls.toolbarWindow, "Pin toolbar missing"),
                stem: "output-pin-controls", directory: directory)
            let item = try menuItem("scroll.live.pin", controls: controls)
            report["selector"] = NSStringFromSelector(try unwrap(item.action, "Pin selector missing"))
            try dispatch(item)
            try await until("Pin delivery did not retire the session", seconds: 5) { owner.isClosedForVerification }
            let id = try unwrap(pinID, "Pin callback did not publish an entry")
            let entry = try unwrap(store.entry(id: id), "Pin store entry missing")
            let asset = store.directory.appendingPathComponent(entry.current.filename)
            // Decode the published PNG independently of the pin's retained CGImage.
            let pinComparison = try compare(decode(asset), expected)
            report["publishedPinComparison"] = pinComparison
            report["independentPublishedPNGDecode"] = true
            let bytes = try Data(contentsOf: asset)
            report["pinPNGFileSHA256"] = hash(bytes); report["pinPNGByteCount"] = bytes.count
            try bytes.write(to: directory.appendingPathComponent("output-published-single-pin.png"), options: .atomic)
            try require(pinComparison["passed"] as? Bool == true, "Published pin differs from the owned single viewport")
            let reopened = try PinSessionStore(directory: store.directory)
            let reopenedComparison = try compare(unwrap(reopened.image(id: id), "Reopened pin missing"), expected)
            report["reopenedPinComparison"] = reopenedComparison
            try require(reopenedComparison["passed"] as? Bool == true, "Reopened pin differs from the owned single viewport")
            let pinWindow = try unwrap(pins.liveControllers[id]?.window, "Actual live pin window missing")
            try require(pinWindow.isVisible && pins.livePinCount == 1 && store.entries.count == 1,
                        "Pin delivery did not create exactly one visible isolated pin")
            report["nativePinArtifacts"] = try appearanceSnapshots(window: pinWindow, stem: "output-native-pin", directory: directory)
            report["singleViewportUnchanged"] = true; report["persistedAndReopened"] = true
            report["visibleNativePinCount"] = pins.livePinCount
            try require(pinCallbacks == 1 && unexpectedCallbacks == 0, "Pin action delivered more than once or to another recipient")
            report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        await session?.closeForVerification()
        do { try coordinator?.prepareForTermination() }
        catch { report["status"] = "failed"; report["cleanupError"] = error.localizedDescription }
        let closed = session?.isClosedForVerification ?? true
        let pinsClosed = (coordinator?.livePinCount ?? 0) == 0
        report["productSessionClosed"] = closed; report["pinControllersClosed"] = pinsClosed
        report["cleanupSafe"] = closed && pinsClosed; report["pinCallbacks"] = pinCallbacks
        report["unexpectedCallbacks"] = unexpectedCallbacks
        if !closed || !pinsClosed { report["status"] = "failed" }
        return report
    }

    private static func start(_ owner: LiveScrollSessionController, provider: OwnedProvider, screen: NSScreen) async throws {
        let frame = CGRect(x: screen.visibleFrame.midX - CGFloat(width) / 2,
            y: screen.visibleFrame.midY - CGFloat(viewportHeight) / 2,
            width: CGFloat(width), height: CGFloat(viewportHeight))
        try await owner.startForVerification(targetFrame: frame, screen: screen, nextImage: {
            try await Task.sleep(nanoseconds: 30_000_000)
            try Task.checkCancellation()
            provider.calls += 1
            return provider.current
        })
    }

    @MainActor private final class OwnedProvider {
        let reference: CGImage
        var current: CGImage
        var calls = 0
        init(reference: CGImage) throws {
            self.reference = reference
            current = try LiveScrollOutputDemoFixture.unwrap(reference.cropping(to: CGRect(x: 0, y: 0,
                width: LiveScrollOutputDemoFixture.width, height: LiveScrollOutputDemoFixture.viewportHeight)), "Initial owned viewport missing")
        }
        func select(offset: Int) throws {
            current = try LiveScrollOutputDemoFixture.unwrap(reference.cropping(to: CGRect(x: 0, y: offset,
                width: LiveScrollOutputDemoFixture.width, height: LiveScrollOutputDemoFixture.viewportHeight)), "Owned viewport crop missing")
        }
    }

    private final class NumberedDocument: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); bounds.fill()
            let titles = ["Keep the complete source", "Review the final image", "Copy can be retried", "Save the original pixels",
                          "One owner for every output", "Pin a recoverable image", "A small native control", "Finish with a clear result"]
            for row in 0..<22 {
                let y = row * 32
                NSColor(calibratedWhite: row % 2 == 0 ? 0.98 : 0.94, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: LiveScrollOutputDemoFixture.width, height: 32).fill()
                (String(format: "%02d", row + 1) as NSString).draw(at: CGPoint(x: 14, y: y + 8), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.darkGray])
                (titles[row % titles.count] as NSString).draw(at: CGPoint(x: 48, y: y + 3), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black])
                ("Owned entry \(row + 1) · PicShot output demonstration" as NSString).draw(at: CGPoint(x: 48, y: y + 19),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray])
                // A fixed numbered illustration varies over the entire row. It
                // keeps this small output fixture deterministic between baselines.
                for line in 0..<32 {
                    let shade = 0.35 + 0.22 * sin(Double(y + line) * 0.71 + Double(row) * 0.13)
                    NSColor(srgbRed: 0.18 + shade * 0.5, green: 0.35 + shade * 0.5, blue: 0.46 + shade * 0.4, alpha: 1).setFill()
                    NSRect(x: 368, y: y + line, width: 112, height: 1).fill()
                    NSColor(srgbRed: 0.12, green: 0.32, blue: 0.28, alpha: 1).setFill()
                    NSRect(x: 368, y: y + line, width: 22 + Int(17 * sin(Double(line) * 0.25 + Double(row))), height: 1).fill()
                }
            }
        }
    }

    private static func menuItem(_ id: String, controls: LiveScrollCaptureController) throws -> NSMenuItem {
        let item = try unwrap(controls.makeMoreMenu().items.first { $0.identifier?.rawValue == id }, "Native More item missing: " + id)
        try require(item.isEnabled, "Native More item disabled: " + id)
        return item
    }
    private static func dispatch(_ item: NSMenuItem) throws {
        let action = try unwrap(item.action, "Native menu action missing")
        try require(NSApp.sendAction(action, to: item.target, from: item), "Native menu dispatch rejected")
    }

    private static func appearanceSnapshots(window: NSWindow, stem: String, directory: URL) throws -> [[String: Any]] {
        let previous = window.appearance
        defer { window.appearance = previous }
        var artifacts: [[String: Any]] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let view = try unwrap(window.contentView, "Native window has no content")
            view.needsDisplay = true
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let image = try nativeImage(view: view, window: window)
            let filename = stem + "-" + name + ".png"
            try writePNG(image, directory.appendingPathComponent(filename))
            var facts = try imageFacts(image)
            facts["filename"] = filename; facts["appearance"] = name
            facts["rendering"] = "Actual owned native content with effective-appearance window background composed"
            artifacts.append(facts)
        }
        return artifacts
    }

    private static func nativeImage(view: NSView, window: NSWindow? = nil) throws -> CGImage {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let w = Int(view.bounds.width.rounded(.up)), h = Int(view.bounds.height.rounded(.up))
        try require(w > 0 && h > 0 && w <= 4_000_000 / h, "Native snapshot exceeds the bounded canvas")
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32), "Native bitmap allocation failed")
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * h)
        bitmap.size = view.bounds.size
        let context = try unwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Native composition allocation failed")
        (window?.effectiveAppearance ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
            // Resolve dynamic colors while the requested native appearance is current.
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if let window { context.setFillColor(window.backgroundColor.cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let cached = bitmap.cgImage { context.draw(cached, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        }
        return try unwrap(context.makeImage(), "Native composition failed")
    }
    private static func imageFacts(_ image: CGImage) throws -> [String: Any] {
        ["width": image.width, "height": image.height, "canonicalRGBAPixelSHA256": hash(try pixels(image))]
    }
    private static func compare(_ actual: CGImage, _ expected: CGImage) throws -> [String: Any] {
        let actualPixels = try pixels(actual), expectedPixels = try pixels(expected)
        let dimensions = actual.width == expected.width && actual.height == expected.height
        let exact = dimensions && actualPixels == expectedPixels
        return ["passed": exact, "dimensionsMatch": dimensions, "exactCanonicalRGBAEquality": exact,
            "width": actual.width, "height": actual.height, "expectedWidth": expected.width, "expectedHeight": expected.height,
            "outputPixelSHA256": hash(actualPixels), "sourcePixelSHA256": hash(expectedPixels),
            "method": "Full canonical sRGB RGBA comparison against the owned reference; file recipients independently decoded with ImageIO"]
    }
    private static func pixels(_ image: CGImage) throws -> Data {
        try SaveWorkflowUIPreviewFixture.pixels(image)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func decode(_ url: URL) throws -> CGImage {
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "Published PNG cannot be opened")
        return try unwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), "Published PNG cannot be decoded")
    }
    private static func writePNG(_ image: CGImage, _ url: URL) throws {
        let writer = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil), "Cannot create evidence PNG")
        CGImageDestinationAddImage(writer, image, nil)
        try require(CGImageDestinationFinalize(writer), "Cannot finalize evidence PNG")
    }
    private static func until(_ message: String, seconds: TimeInterval, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try Task.checkCancellation()
            try require(ProcessInfo.processInfo.systemUptime < deadline, message)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    private static func write(_ report: [String: Any], directory: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("live-scroll-output.json"), options: .atomic)
    }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw failure(message) }; return value
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Live output demo: " + message) }
}
