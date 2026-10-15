import AppKit
import PicShotCore
import XCTest
@testable import PicShot

/// Exercises AppMain's real scroll factory, saved-script picker, runner and
/// manager with owned frame/OCR/helper gates and isolated output recipients.
@MainActor
final class LiveScrollTextAppIntegrationTests: XCTestCase {
    func testAppFactoryRequiresExplicitSavedTextChoiceAndRunWithoutAcquisition() async throws {
        try await withFixture { f in
            f.outputs.failCopy = true
            let session = try await f.startSession()
            let menu = f.app.captureChainsMenu()
            let saved = try XCTUnwrap(menu.items.first {
                $0.action == #selector(AppDelegate.runTextScriptItem(_:))
                    && ($0.representedObject as? String) == f.script.id.uuidString
            })
            XCTAssertEqual(saved.keyEquivalent, "")
            XCTAssertEqual(f.outputs.dependencyRequests, 0)
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertNil(f.scripts.selectedID)
            let item = try f.textMenuItem(session)
            XCTAssertTrue(item.isEnabled); XCTAssertEqual(item.keyEquivalent, "")
            try f.dispatch(item)
            let choice = try XCTUnwrap(session.textChoiceAlertForVerification)
            let picker = try XCTUnwrap(choice.accessoryView as? NSPopUpButton)
            let selectedIndex = try XCTUnwrap(f.scripts.definitions.firstIndex { $0.id == f.otherScript.id })
            picker.selectItem(at: selectedIndex)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
            XCTAssertEqual(f.outputs.dependencyRequests, 0); XCTAssertEqual(f.source?.pauseCalls, 0)
            choice.cancel()
            try await self.until { session.textChoiceAlertForVerification == nil && session.snapshotForVerification.canApplyTextScript }
            XCTAssertEqual(f.outputs.dependencyRequests, 0); XCTAssertEqual(session.textRenderCountForVerification, 0)
            try f.dispatch(try f.textMenuItem(session))
            let confirmed = try XCTUnwrap(session.textChoiceAlertForVerification)
            let confirmedPicker = try XCTUnwrap(confirmed.accessoryView as? NSPopUpButton)
            confirmedPicker.selectItem(at: selectedIndex)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(confirmedPicker.action), to: confirmedPicker.target, from: confirmedPicker))
            try self.press(try XCTUnwrap(confirmed.buttons.first))
            try await self.until { f.app.activeCaptureChain?.status.canRetry == true }
            XCTAssertEqual(f.outputs.definitions, [f.otherScript])
            XCTAssertEqual(f.outputs.sources, [f.otherScript.source])
            XCTAssertEqual(f.outputs.acquisitions, 0); XCTAssertEqual(f.outputs.imageDependencyRequests, 0)
            XCTAssertEqual(session.textRenderCountForVerification, 1)
            XCTAssertTrue(f.app.activeCaptureChain?.snapshot.isExistingScrollImage == true)
            XCTAssertNil(session.chainTransaction); XCTAssertNil(f.scripts.selectedID)
        }
    }

    func testPreparedRasterIsCountedOnceAndReleasedBeforeCachedCopyRetryAcrossCatalogEdit() async throws {
        try await withFixture { f in
            f.outputs.holdRecognition = true; f.outputs.failCopy = true
            let session = try await f.startSession()
            var stagedIdentity: ObjectIdentifier?, stagedBytes = 0
            f.outputs.onDependencyRequest = {
                let staged = try XCTUnwrap(session.stagedTextCapture)
                stagedIdentity = ObjectIdentifier(staged.image); stagedBytes = staged.retainedBytes
                XCTAssertNil(f.app.activeCaptureChain)
                XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, staged.retainedBytes)
                XCTAssertTrue(session.acceptsTextRun(runID: try XCTUnwrap(session.textAttemptID)))
            }
            XCTAssertTrue(session.startTextScript(definition: f.script))
            try await self.until { f.outputs.recognitionWaiting }
            let runner = try XCTUnwrap(f.app.activeCaptureChain)
            XCTAssertEqual(runner.id, session.textAttemptID)
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(runner.capture?.image)), stagedIdentity)
            XCTAssertEqual(f.outputs.recognizedImageIDs, [try XCTUnwrap(stagedIdentity)])
            XCTAssertNil(session.stagedTextCapture)
            XCTAssertEqual(f.app.retainedChainBytes, stagedBytes + f.script.source.utf8.count)
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, f.app.retainedChainBytes)
            XCTAssertEqual(runner.status, .preparingText(.recognize))
            XCTAssertEqual(f.outputs.acquisitions, 0)
            let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
            let status: NSTextField = try self.view("run-status", in: manager)
            XCTAssertTrue(status.stringValue.contains("来源：本次长截图"))
            XCTAssertTrue(status.stringValue.contains("正在识别文字"))
            XCTAssertFalse(status.stringValue.contains("正在截图"))
            f.outputs.releaseRecognition()
            try await self.until { runner.status == .textFailed(.copy, .clipboardRejected) }
            XCTAssertNil(runner.capture); XCTAssertNil(session.stagedTextCapture)
            XCTAssertNil(session.retainedChainCapture)
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, f.outputs.transformedText.utf8.count)
            XCTAssertEqual(runner.snapshot.retainedTextBytes, f.outputs.transformedText.utf8.count)
            let labels = try self.labels(in: manager).joined(separator: "\n")
            XCTAssertTrue(labels.contains("不会重新识别当前长图或执行脚本"))
            XCTAssertFalse(labels.contains("区域截图"))
            try f.scripts.update(try TextScriptDefinition(id: f.script.id, name: "Edited after Copy failed", source: "return 'edited';"))
            try f.acceptExplicitCatalogEdit()
            f.outputs.failCopy = false
            try self.press("retry", in: manager)
            try await self.until { session.isClosedForVerification && f.app.liveScrollSessionForVerification == nil }
            XCTAssertEqual(runner.status, .completed)
            XCTAssertEqual([f.outputs.dependencyRequests, f.outputs.recognitions, f.outputs.transforms, f.outputs.copies], [1, 1, 1, 2])
            XCTAssertEqual(f.outputs.sources, [f.script.source])
            XCTAssertEqual(f.outputs.recognizedTexts, [f.outputs.recognition.text])
            XCTAssertEqual(f.outputs.copiedTexts, [f.outputs.transformedText, f.outputs.transformedText])
            XCTAssertEqual(runner.snapshot.textReceipt?.characterCount, f.outputs.transformedText.count)
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
            XCTAssertEqual(session.textRenderCountForVerification, 1)
        }
    }

    func testCancelReturnsSamePausedDraftWithoutAutomaticResumeOrNewCapture() async throws {
        try await withFixture { f in
            f.outputs.failCopy = true
            let session = try await f.startSession(), initial = session.snapshotForVerification
            let samples = session.sampledFramesForVerification
            XCTAssertTrue(session.startTextScript(definition: f.script))
            try await self.until { f.app.activeCaptureChain?.status.canRetry == true }
            let first = try XCTUnwrap(f.app.activeCaptureChain)
            try self.press("cancel", in: try XCTUnwrap(f.app.captureChainManagerForVerification))
            try await self.until { session.textAttemptID == nil && session.snapshotForVerification.canApplyTextScript }
            XCTAssertEqual(first.status, .cancelled); XCTAssertNil(first.snapshot.textReceipt)
            XCTAssertNil(f.app.activeCaptureChain)
            XCTAssertTrue(f.app.liveScrollSessionForVerification === session)
            XCTAssertTrue(session.snapshotForVerification.paused); XCTAssertFalse(session.snapshotForVerification.autoScrolling)
            XCTAssertFalse(session.snapshotForVerification.busy)
            XCTAssertEqual(session.snapshotForVerification.pixelWidth, initial.pixelWidth)
            XCTAssertEqual(session.snapshotForVerification.pixelHeight, initial.pixelHeight)
            XCTAssertEqual(session.snapshotForVerification.acceptedFrames, initial.acceptedFrames)
            XCTAssertEqual(session.sampledFramesForVerification, samples)
            XCTAssertEqual(f.source?.resumeCalls, 0)
            XCTAssertNil(session.chainTransaction); XCTAssertNil(session.stagedTextCapture)
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
            self.assertCaptureReservation(f)
            XCTAssertTrue(session.startTextScript(definition: f.script))
            try await self.until { f.app.activeCaptureChain?.status.canRetry == true }
            XCTAssertNotEqual(f.app.activeCaptureChain?.id, first.id)
            XCTAssertEqual(f.outputs.dependencyRequests, 2)
            XCTAssertEqual(f.outputs.acquisitions, 0); XCTAssertEqual(f.source?.resumeCalls, 0)
        }
    }

    func testCopyCommitWithSynchronousCancelClosesDraftExactlyOnce() async throws {
        try await withFixture { f in
            let session = try await f.startSession()
            let close = try XCTUnwrap(session.onClose)
            var closes = 0, committedRunner: CaptureChainRunner?
            session.onClose = { closes += 1; close() }
            f.outputs.onCopy = {
                let runner = try XCTUnwrap(f.app.activeCaptureChain)
                committedRunner = runner
                XCTAssertTrue(runner.cancel())
            }
            XCTAssertTrue(session.startTextScript(definition: f.script))
            try await self.until { session.isClosedForVerification && f.app.liveScrollSessionForVerification == nil }
            let runner = try XCTUnwrap(committedRunner)
            XCTAssertEqual(runner.status, .cancelled)
            XCTAssertEqual(runner.snapshot.textReceipt?.characterCount, f.outputs.transformedText.count)
            XCTAssertEqual(f.outputs.copies, 1); XCTAssertEqual(closes, 1)
            XCTAssertFalse(runner.retry()); XCTAssertFalse(runner.cancel())
            session.cancel(); await session.closeForVerification()
            XCTAssertEqual(closes, 1); XCTAssertEqual(f.outputs.copies, 1)
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
            XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateNow)
        }
    }

    func testStaleRunnerManagerAndSessionCallbacksCannotChangeSuccessorSession() async throws {
        try await withFixture { f in
            f.outputs.failCopy = true
            let firstSession = try await f.startSession()
            let staleSessionClose = try XCTUnwrap(firstSession.onClose)
            XCTAssertTrue(firstSession.startTextScript(definition: f.script))
            try await self.until { f.app.activeCaptureChain?.status.canRetry == true }
            let old = try XCTUnwrap(f.app.activeCaptureChain)
            let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
            let oldChange = try XCTUnwrap(old.onChange), oldTerminal = try XCTUnwrap(old.onTerminal)
            let oldRetry = try XCTUnwrap(manager.onRetry), oldCancel = try XCTUnwrap(manager.onCancel)
            let oldClose = try XCTUnwrap(manager.onClose), oldRun = try XCTUnwrap(manager.onRun)
            let oldGeneration = manager.commandGeneration, oldFailure = old.snapshot
            try self.press("cancel", in: manager)
            try await self.until { firstSession.textAttemptID == nil }
            await firstSession.closeForVerification()
            f.outputs.holdRecognition = true
            let next = try await f.startSession()
            XCTAssertTrue(next.startTextScript(definition: f.otherScript))
            try await self.until { f.outputs.recognitionWaiting }
            let fresh = try XCTUnwrap(f.app.activeCaptureChain), snapshot = fresh.snapshot
            XCTAssertNotEqual(next.sessionID, firstSession.sessionID); XCTAssertNotEqual(fresh.id, old.id)
            oldChange(oldFailure); oldTerminal(old.snapshot); staleSessionClose()
            oldRetry(old.id, manager.commandGeneration); oldCancel(old.id, manager.commandGeneration)
            oldClose(old.id, manager.commandGeneration)
            oldRetry(fresh.id, oldGeneration); oldCancel(fresh.id, oldGeneration)
            oldRun(f.image.id, oldGeneration)
            XCTAssertTrue(f.app.activeCaptureChain === fresh)
            XCTAssertTrue(f.app.liveScrollSessionForVerification === next)
            XCTAssertEqual(fresh.snapshot, snapshot); XCTAssertEqual(manager.displayedSnapshot, snapshot)
            XCTAssertEqual(next.textAttemptID, fresh.id)
            XCTAssertFalse(next.isClosedForVerification); XCTAssertNil(next.chainTransaction)
            XCTAssertFalse(firstSession.startTextScript(definition: f.script))
            XCTAssertEqual(f.outputs.dependencyRequests, 2)
            XCTAssertEqual(f.outputs.copies, 1); XCTAssertEqual(f.outputs.acquisitions, 0)
        }
    }

    func testCloseWaitsForWithheldOCRBeforeReleasingSharedCaptureOwner() async throws {
        let counter = CaptureTestProviderCounter()
        try await withFixture { f in
            f.outputs.holdRecognition = true
            let session = try await f.startSession(counter: counter)
            XCTAssertTrue(session.startTextScript(definition: f.script))
            try await self.until { f.outputs.recognitionWaiting }
            let runner = try XCTUnwrap(f.app.activeCaptureChain)
            session.cancel()
            try self.press("close", in: try XCTUnwrap(f.app.captureChainManagerForVerification))
            XCTAssertEqual(runner.status, .cancelling)
            XCTAssertFalse(session.isClosedForVerification)
            XCTAssertTrue(f.app.liveScrollSessionForVerification === session)
            XCTAssertTrue(f.app.activeCaptureChain === runner)
            XCTAssertEqual(counter.deallocations, 0)
            self.assertCaptureReservation(f)
            XCTAssertThrowsError(try f.app.makeLiveScrollSessionForVerification(resourceStorageParent: f.spool))
            XCTAssertEqual(f.outputs.cancelAcquisitions, 0)
            f.outputs.releaseRecognition()
            try await self.until { session.isClosedForVerification && f.app.liveScrollSessionForVerification == nil && counter.liveBytes == 0 }
            XCTAssertEqual(runner.status, .cancelled); XCTAssertNil(runner.snapshot.textReceipt)
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
            XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1)
            XCTAssertEqual(f.outputs.transforms, 0); XCTAssertEqual(f.outputs.copies, 0)
            XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateNow)
        }
    }

    func testCloseWaitsForOwnedHelperCleanupBeforeReleasingSharedCaptureOwner() async throws {
        try await withFixture { f in
            f.outputs.helperCleanupPending = true
            let session = try await f.startSession()
            XCTAssertTrue(session.startTextScript(definition: f.script))
            try await self.until { f.app.activeCaptureChain?.status == .waitingForTextCleanup(.invalidResult) }
            let runner = try XCTUnwrap(f.app.activeCaptureChain)
            XCTAssertFalse(runner.retry()); XCTAssertNil(runner.capture)
            session.cancel()
            try self.press("close", in: try XCTUnwrap(f.app.captureChainManagerForVerification))
            XCTAssertFalse(runner.checkTextCleanup())
            XCTAssertEqual(runner.status, .cancelling)
            XCTAssertFalse(session.isClosedForVerification)
            XCTAssertTrue(f.app.liveScrollSessionForVerification === session)
            self.assertCaptureReservation(f)
            XCTAssertThrowsError(try f.app.makeLiveScrollSessionForVerification(resourceStorageParent: f.spool))
            XCTAssertEqual(f.outputs.copies, 0)
            f.outputs.helperCleanupReleased = true
            XCTAssertTrue(runner.checkTextCleanup())
            try await self.until { session.isClosedForVerification && f.app.liveScrollSessionForVerification == nil }
            XCTAssertEqual(runner.status, .cancelled); XCTAssertFalse(runner.checkTextCleanup())
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertNil(runner.snapshot.textReceipt)
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
            XCTAssertEqual(f.outputs.cleanupRequestIDs, Array(repeating: try XCTUnwrap(f.outputs.transformRequestIDs.first), count: f.outputs.cleanupRequestIDs.count))
            XCTAssertEqual(f.outputs.transforms, 1); XCTAssertEqual(f.outputs.copies, 0)
        }
    }

    func testDependencyFactoryFailurePreservesPausedDraftWithoutFallbackAcquisition() async throws {
        try await withFixture { f in
            f.outputs.onDependencyRequest = { throw Failure.dependency }
            let session = try await f.startSession(), before = session.snapshotForVerification
            XCTAssertTrue(session.startTextScript(definition: f.script))
            try await self.until { session.textAttemptID == nil && session.snapshotForVerification.canApplyTextScript }
            XCTAssertEqual(session.snapshotForVerification.statusKind, .error)
            XCTAssertTrue(session.snapshotForVerification.paused)
            XCTAssertEqual(session.snapshotForVerification.pixelWidth, before.pixelWidth)
            XCTAssertEqual(session.snapshotForVerification.pixelHeight, before.pixelHeight)
            XCTAssertTrue(f.app.liveScrollSessionForVerification === session)
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertNil(session.stagedTextCapture)
            XCTAssertEqual(f.outputs.dependencyRequests, 1); XCTAssertEqual(f.outputs.recognitions, 0)
            XCTAssertEqual(f.outputs.acquisitions, 0); XCTAssertEqual(f.outputs.imageDependencyRequests, 0)
            XCTAssertEqual(f.source?.resumeCalls, 0)
            self.assertCaptureReservation(f)
        }
    }

    func testDependencyFactoryReentrantCancelCannotInstallOrStartPreparedRunner() async throws {
        try await withFixture { f in
            let session = try await f.startSession()
            f.outputs.onDependencyRequest = { session.cancel() }
            XCTAssertTrue(session.startTextScript(definition: f.script))
            try await self.until { session.isClosedForVerification && f.app.liveScrollSessionForVerification == nil }
            XCTAssertEqual(f.outputs.dependencyRequests, 1)
            XCTAssertEqual(f.outputs.acquisitions, 0); XCTAssertEqual(f.outputs.recognitions, 0)
            XCTAssertEqual(f.outputs.transforms, 0); XCTAssertEqual(f.outputs.copies, 0)
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertNil(session.textAttemptID)
            XCTAssertNil(session.stagedTextCapture); XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
            XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateNow)
        }
    }

    func testRecognitionFailureProgressNamesCurrentLongImageWithoutRegionRecapture() async throws {
        for recognition in [ChainTextRecognition(text: ""), ChainTextRecognition(text: "partial", truncated: true)] {
            try await withFixture { f in
                f.outputs.recognition = recognition
                let session = try await f.startSession()
                XCTAssertTrue(session.startTextScript(definition: f.script))
                try await self.until { f.app.activeCaptureChain?.status.canRetry == true }
                let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
                let status: NSTextField = try self.view("run-status", in: manager)
                XCTAssertTrue(status.stringValue.contains("当前长图"))
                XCTAssertTrue(status.stringValue.contains("来源：本次长截图"))
                let labels = try self.labels(in: manager).joined(separator: "\n")
                XCTAssertTrue(labels.contains("重试使用当前长图"))
                XCTAssertFalse(labels.contains("重新选择区域")); XCTAssertFalse(labels.contains("选择更小的区域"))
                XCTAssertFalse(labels.contains("区域截图")); XCTAssertFalse(labels.contains("正在截图"))
                XCTAssertEqual(f.outputs.acquisitions, 0); XCTAssertEqual(f.outputs.transforms, 0)
                XCTAssertEqual(f.outputs.copies, 0)
            }
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for scroll controls") }
        let fixture = try Fixture(screen: screen)
        do { try await body(fixture); try fixture.assertPersistentState() }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "App scroll text did not reach its owned phase barrier")
    }
    private func assertCaptureReservation(_ f: Fixture) {
        XCTAssertFalse(f.app.runTextScript(id: f.script.id))
        XCTAssertFalse(f.app.runCaptureChain(id: f.image.id))
        var acquisitions = 0
        f.app.runCaptureForEditing { acquisitions += 1; throw CaptureError.cancelled }
        XCTAssertEqual(acquisitions, 0)
        XCTAssertEqual(f.outputs.acquisitions, 0); XCTAssertEqual(f.outputs.imageDependencyRequests, 0)
        XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateCancel)
    }
    private func view<T: NSView>(_ suffix: String, in manager: CaptureChainController) throws -> T {
        func find(_ root: NSView) -> T? {
            if root.identifier?.rawValue == "capture-chain-" + suffix { return root as? T }
            return root.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(try XCTUnwrap(manager.window?.contentView)))
    }
    private func labels(in manager: CaptureChainController) throws -> [String] {
        func all(_ root: NSView) -> [String] {
            ((root as? NSTextField).map { [$0.stringValue] } ?? []) + root.subviews.flatMap(all)
        }
        return all(try XCTUnwrap(manager.window?.contentView))
    }
    private func press(_ button: NSButton) throws {
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
    }
    private func press(_ suffix: String, in manager: CaptureChainController) throws {
        let button: NSButton = try view(suffix, in: manager)
        try press(button)
    }
    private enum Failure: Error { case dependency, copy }

    @MainActor private final class Fixture {
        let root: URL, spool: URL, suite: String, defaults: UserDefaults, screen: NSScreen
        let images: CaptureChainStore, scripts: TextScriptStore
        let image: CaptureChainDefinition, script: TextScriptDefinition, otherScript: TextScriptDefinition
        let app: AppDelegate, outputs: Outputs
        private let imageCatalogData: Data
        private var scriptCatalogData: Data
        private let originalDefaults: NSDictionary?
        var source: Source?
        init(screen: NSScreen) throws {
            self.screen = screen
            root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-ScrollTextApp-" + UUID().uuidString)
            spool = root.appendingPathComponent("spool")
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false)
            suite = "PicShot.ScrollTextAppTests." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            images = try CaptureChainStore(directory: root.appendingPathComponent("image-chains"))
            scripts = try TextScriptStore(directory: root.appendingPathComponent("text-scripts"))
            image = try CaptureChainDefinition(name: "Unresolved saved preset", source: .preset(UUID()), outputs: [.copy])
            script = try TextScriptDefinition(name: "First saved text", source: "return text;")
            otherScript = try TextScriptDefinition(name: "Second saved text", source: "return text.trim();")
            try images.add(image); try scripts.add(script); try scripts.add(otherScript)
            imageCatalogData = try Data(contentsOf: images.directory.appendingPathComponent(CaptureChainStore.manifestFilename))
            scriptCatalogData = try Data(contentsOf: scripts.directory.appendingPathComponent(TextScriptStore.manifestFilename))
            originalDefaults = defaults.persistentDomain(forName: suite) as NSDictionary?
            let recipients = Outputs(); outputs = recipients
            app = AppDelegate(history: HistoryStore(directory: root.appendingPathComponent("history")),
                isolatedDefaults: defaults, admissionNotice: { XCTFail("Unexpected admission notice") },
                chainStore: images, chainDependencies: { _ in
                    recipients.imageDependencyRequests += 1
                    return .init(capture: { recipients.acquisitions += 1; throw CaptureError.cancelled },
                        savePNG: { _ in XCTFail("Unexpected image Save"); return .cancelled },
                        copy: { _ in XCTFail("Unexpected image Copy") },
                        pin: { _ in XCTFail("Unexpected image Pin"); return UUID() }, cancelSave: {})
                }, textScriptStore: scripts, textScriptDependencies: { definition in try recipients.dependencies(definition) })
            app.mainWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
                styleMask: [.titled], backing: .buffered, defer: false)
            app.mainWindow.isReleasedWhenClosed = false; app.mainWindow.animationBehavior = .none
        }
        func startSession(counter: CaptureTestProviderCounter? = nil) async throws -> LiveScrollSessionController {
            let source = Source(screen: screen); self.source = source
            let session = try app.makeLiveScrollSessionForVerification(resourceStorageParent: spool)
            try await session.startForVerification(source: source, screen: screen)
            try await SaveWorkflowUIPreviewFixture.until({ source.waiting }, "Owned source did not request its initial frame")
            try autoreleasepool {
                let image = try counter.map { try CaptureTestProviderCounter.image(width: 24, height: 48, counter: $0) }
                    ?? SaveWorkflowUIPreviewFixture.sourceImage(width: 24, height: 48)
                source.offer(image)
            }
            try await SaveWorkflowUIPreviewFixture.until({ session.snapshotForVerification.canApplyTextScript && source.waiting },
                "Owned scroll image did not become ready for explicit text processing")
            return session
        }
        func textMenuItem(_ session: LiveScrollSessionController) throws -> NSMenuItem {
            let toolbar = try XCTUnwrap(session.controlsForVerification?.toolbarWindow?.contentView as? LiveScrollToolbarView)
            return try XCTUnwrap(toolbar.moreButton.menu?.items.first { $0.identifier?.rawValue == "scroll.live.textScript" })
        }
        func dispatch(_ item: NSMenuItem) throws {
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        func acceptExplicitCatalogEdit() throws {
            scriptCatalogData = try Data(contentsOf: scripts.directory.appendingPathComponent(TextScriptStore.manifestFilename))
        }
        func assertPersistentState() throws {
            XCTAssertEqual(try Data(contentsOf: images.directory.appendingPathComponent(CaptureChainStore.manifestFilename)), imageCatalogData)
            XCTAssertEqual(try Data(contentsOf: scripts.directory.appendingPathComponent(TextScriptStore.manifestFilename)), scriptCatalogData)
            XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, originalDefaults)
            XCTAssertTrue(app.history.records.isEmpty)
        }
        func close() async {
            outputs.onDependencyRequest = nil; outputs.onCopy = nil
            outputs.releaseRecognition(); outputs.helperCleanupReleased = true
            _ = app.activeCaptureChain?.cancel(); _ = app.activeCaptureChain?.checkTextCleanup()
            if let session = app.liveScrollSessionForVerification { await session.closeForVerification() }
            if let manager = app.captureChainManagerForVerification {
                manager.onRun = nil; manager.onRetry = nil; manager.onCancel = nil; manager.onClose = nil
                manager.invalidateCommands()
            }
            Array(app.controllers).forEach { $0.close() }; app.controllers.removeAll()
            app.mainWindow.close(); _ = app.pendingCaptureRecovery.discard()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor private final class Outputs {
        var dependencyRequests = 0, imageDependencyRequests = 0, acquisitions = 0, cancelAcquisitions = 0
        var recognitions = 0, transforms = 0, copies = 0
        var definitions: [TextScriptDefinition] = [], sources: [String] = [], recognizedTexts: [String] = [], copiedTexts: [String] = []
        var recognizedImageIDs: [ObjectIdentifier] = [], transformRequestIDs: [UUID] = [], cleanupRequestIDs: [UUID] = []
        var holdRecognition = false, failCopy = false, helperCleanupPending = false, helperCleanupReleased = false
        var recognition = ChainTextRecognition(text: "PIC-17 PIC-17 PIC-28")
        let transformedText = "PIC-17\nPIC-28"
        var onDependencyRequest: (() throws -> Void)?, onCopy: (() throws -> Void)?
        private var recognitionContinuation: CheckedContinuation<Void, Never>?
        var recognitionWaiting: Bool { recognitionContinuation != nil }
        func dependencies(_ definition: TextScriptDefinition) throws -> CaptureChainRunner.TextDependencies {
            dependencyRequests += 1; definitions.append(definition)
            try onDependencyRequest?()
            return .init(capture: { self.acquisitions += 1; throw CaptureError.cancelled }, recognize: { image in
                self.recognitions += 1; self.recognizedImageIDs.append(ObjectIdentifier(image))
                if self.holdRecognition { await withCheckedContinuation { self.recognitionContinuation = $0 } }
                return self.recognition
            }, transform: { source, text, requestID in
                self.transforms += 1; self.sources.append(source); self.recognizedTexts.append(text)
                self.transformRequestIDs.append(requestID)
                if self.helperCleanupPending { return .failed(.invalidResult, cleanupPending: true) }
                return .succeeded(self.transformedText)
            }, copy: { text in
                self.copies += 1; self.copiedTexts.append(text)
                try self.onCopy?()
                if self.failCopy { throw Failure.copy }
            }, cleanupComplete: { requestID in
                self.cleanupRequestIDs.append(requestID)
                return self.helperCleanupReleased
            }, cancelCapture: { self.cancelAcquisitions += 1 })
        }
        func releaseRecognition() {
            let pending = recognitionContinuation; recognitionContinuation = nil; pending?.resume()
        }
    }

    @MainActor private final class Source: LiveScrollFrameSource {
        let region = CGRect(x: 80, y: 80, width: 320, height: 240)
        let displayBounds: CGRect
        var target: LiveScrollScreenSource.Target? { nil }
        var waiting: Bool { reader != nil }
        var pauseCalls = 0, resumeCalls = 0
        private var running = false, sequence: UInt64 = 0
        private var reader: CheckedContinuation<LiveScrollScreenSource.Frame?, Error>?
        init(screen: NSScreen) { displayBounds = CGDisplayBounds(screen.displayID ?? 0) }
        func start() async throws { running = true }
        func resume() async throws { resumeCalls += 1; try await start() }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            try Task.checkCancellation()
            guard running else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { reader = $0 }
        }
        func offer(_ image: CGImage) {
            sequence &+= 1; let pending = reader; reader = nil
            pending?.resume(returning: .init(image: image, sequence: sequence, generation: 1,
                timestamp: TimeInterval(sequence), region: region))
        }
        func pauseAndDrain() async throws { pauseCalls += 1; drain() }
        func stop() async throws { drain() }
        func validateTarget() throws { }
        func moveRegion(to proposed: CGRect) throws { }
        private func drain() {
            running = false; let pending = reader; reader = nil; pending?.resume(throwing: CancellationError())
        }
    }
}
