import AppKit
import XCTest
import PicShotCore
@testable import PicShot

/// Uses AppMain's actual scroll factory, runner coordinator, manager callbacks
/// and admission. Acquisition and external output recipients remain isolated.
@MainActor
final class LiveScrollChainAppIntegrationTests: XCTestCase {
    func testAppCountsSharedRasterOnceAcrossCancelAndBlocksUnrelatedCaptureUntilAbandoned() async throws {
        try await withFixture(outputs: [.copy]) { f in
            f.outputs.failCopy = true
            let session = try await f.startSession()
            XCTAssertTrue(session.startImageChain(definition: f.definition))
            try await self.until { f.app.activeCaptureChain?.status.canRetry == true }
            let runner = try XCTUnwrap(f.app.activeCaptureChain), bytes = try XCTUnwrap(session.retainedChainCapture?.retainedBytes)
            XCTAssertGreaterThan(bytes, 0)
            XCTAssertEqual(f.app.retainedChainBytes, bytes)
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, bytes)
            XCTAssertTrue(runner.capture?.image === session.retainedChainCapture?.image)
            XCTAssertEqual(f.outputs.acquisitions, 0)
            XCTAssertFalse(f.app.runCaptureChain(id: f.definition.id))
            XCTAssertFalse(f.app.runTextScript(id: UUID()))
            f.app.runCaptureForEditing { f.outputs.acquisitions += 1; throw CaptureError.cancelled }
            XCTAssertEqual(f.outputs.acquisitions, 0); XCTAssertEqual(f.outputs.dependencyRequests, 1)
            XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateCancel)
            let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
            let sourceStatus: NSTextField = try self.view("run-status", in: manager)
            XCTAssertTrue(sourceStatus.stringValue.contains("来源：本次长截图"))
            XCTAssertFalse(sourceStatus.stringValue.contains("正在截图"))
            try self.press("cancel", in: manager)
            try await self.until { session.snapshotForVerification.canContinueImageChain }
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertEqual(f.app.retainedChainBytes, 0)
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, bytes)
            XCTAssertTrue(f.app.liveScrollSessionForVerification === session)
            XCTAssertFalse(f.app.runCaptureChain(id: f.definition.id))
            XCTAssertFalse(f.app.runTextScript(id: UUID()))
            f.app.runCaptureForEditing { f.outputs.acquisitions += 1; throw CaptureError.cancelled }
            XCTAssertEqual(f.outputs.dependencyRequests, 1); XCTAssertEqual(f.outputs.acquisitions, 0)
            XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateCancel)
            let transaction = try XCTUnwrap(session.chainTransaction)
            f.source?.onResume = {
                XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
                XCTAssertNil(session.retainedChainCapture)
            }
            XCTAssertTrue(session.abandonImageChain(transactionID: transaction.transactionID))
            try await self.until { f.source?.resumeCalls == 1 && !session.snapshotForVerification.busy }
            f.source?.onResume = nil
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
            XCTAssertFalse(f.app.runCaptureChain(id: f.definition.id), "The still-open scroll owner keeps acquisition reserved")
            await session.closeForVerification()
            XCTAssertNil(f.app.liveScrollSessionForVerification)
            XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateNow)
            XCTAssertTrue(f.app.history.records.isEmpty)
        }
    }

    func testDirectEditorAdmissionIncludesCancelledCheckpointAtExactByteBoundary() async throws {
        let incoming = try SaveWorkflowUIPreviewFixture.sourceImage(width: 24, height: 48)
        let opening = EditorRasterEstimate.openingBytes(image: incoming, presentation: nil)
        let checkpointBytes = incoming.bytesPerRow * incoming.height
        for shortByOne in [true, false] {
            try await withFixture(outputs: [.copy], admission: .init(maximumRasterBytes: opening + checkpointBytes - (shortByOne ? 1 : 0))) { f in
                f.outputs.failCopy = true
                let session = try await f.startSession()
                XCTAssertTrue(session.startImageChain(definition: f.definition))
                try await self.until { f.app.activeCaptureChain?.status.canRetry == true }
                let runner = try XCTUnwrap(f.app.activeCaptureChain)
                XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, checkpointBytes)
                if shortByOne {
                    XCTAssertFalse(f.app.openEditor(incoming, showAdmissionNotice: false))
                }
                XCTAssertTrue(runner.cancel())
                try await self.until { session.snapshotForVerification.canContinueImageChain }
                XCTAssertNil(f.app.activeCaptureChain)
                XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, checkpointBytes)
                XCTAssertEqual(f.app.openEditor(incoming, showAdmissionNotice: false), !shortByOne,
                    "A terminal attempt must not hide the still-resumable scroll raster from direct editor admission")
                let editors = f.app.controllers.compactMap { $0 as? ImageEditorController }
                XCTAssertEqual(editors.count, shortByOne ? 0 : 1)
                await session.closeForVerification()
                XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
                if shortByOne { XCTAssertTrue(f.app.openEditor(incoming, showAdmissionNotice: false)) }
                XCTAssertTrue(f.app.history.records.isEmpty)
            }
        }
    }

    func testStaleRunnerManagerAndOldSessionCloseCannotCancelContinuationOrSuccessorSession() async throws {
        try await withFixture(outputs: [.copy, .quickSavePNG]) { f in
            f.outputs.failCopy = true
            let session = try await f.startSession()
            let staleSessionClose = try XCTUnwrap(session.onClose)
            XCTAssertTrue(session.startImageChain(definition: f.definition))
            try await self.until { f.app.activeCaptureChain?.status.canRetry == true }
            let old = try XCTUnwrap(f.app.activeCaptureChain), manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
            let oldChange = try XCTUnwrap(old.onChange), oldTerminal = try XCTUnwrap(old.onTerminal)
            let staleRetry = try XCTUnwrap(manager.onRetry), staleCancel = try XCTUnwrap(manager.onCancel)
            let staleClose = try XCTUnwrap(manager.onClose), staleRun = try XCTUnwrap(manager.onRun)
            let oldGeneration = manager.commandGeneration, oldFailure = old.snapshot
            try self.press("cancel", in: manager)
            try await self.until { session.snapshotForVerification.canContinueImageChain }
            let checkpoint = try XCTUnwrap(session.chainTransaction)
            f.outputs.failCopy = false; f.outputs.holdSave = true
            XCTAssertTrue(session.continueImageChain(transactionID: checkpoint.transactionID))
            try await self.until { f.outputs.savePending }
            let fresh = try XCTUnwrap(f.app.activeCaptureChain), freshSnapshot = fresh.snapshot
            XCTAssertNotEqual(fresh.id, old.id)
            oldChange(oldFailure); oldTerminal(old.snapshot)
            staleClose(old.id, manager.commandGeneration)
            staleCancel(old.id, manager.commandGeneration); staleRetry(old.id, manager.commandGeneration)
            staleCancel(fresh.id, oldGeneration); staleRetry(fresh.id, oldGeneration)
            staleRun(f.definition.id, oldGeneration)
            XCTAssertTrue(f.app.activeCaptureChain === fresh)
            XCTAssertEqual(fresh.snapshot, freshSnapshot)
            XCTAssertEqual(manager.displayedSnapshot, freshSnapshot)
            XCTAssertEqual(f.outputs.dependencyRequests, 2); XCTAssertEqual(f.outputs.saveCancels, 0)
            XCTAssertEqual(session.chainTransaction?.transactionID, checkpoint.transactionID)
            f.outputs.completeSave(.cancelled)
            try await self.until { session.snapshotForVerification.canContinueImageChain }
            XCTAssertEqual(session.chainTransaction?.receipts.map(\.output), [.copy])
            await session.closeForVerification()
            XCTAssertNil(f.app.liveScrollSessionForVerification)
            let nextSession = try await f.startSession()
            XCTAssertNotEqual(session.sessionID, nextSession.sessionID)
            staleSessionClose(); oldTerminal(old.snapshot)
            XCTAssertTrue(f.app.liveScrollSessionForVerification === nextSession)
            XCTAssertFalse(nextSession.isClosedForVerification)
            XCTAssertNil(nextSession.chainTransaction)
            XCTAssertFalse(session.startImageChain(definition: f.definition))
            XCTAssertFalse(session.continueImageChain(transactionID: checkpoint.transactionID))
            XCTAssertTrue(nextSession.snapshotForVerification.canApplyImageChain)
        }
    }

    func testFullCloseDuringSaveKeepsAppReservationUntilDrainAndNeverMutatesCatalogOrDefaults() async throws {
        let counter = CaptureTestProviderCounter()
        try await withFixture(outputs: [.quickSavePNG, .copy]) { f in
            f.outputs.holdSave = true
            let manifest = f.store.directory.appendingPathComponent(CaptureChainStore.manifestFilename)
            let original = try Data(contentsOf: manifest)
            let defaults = f.defaults.persistentDomain(forName: f.suite) as NSDictionary?
            let session = try await f.startSession(counter: counter)
            XCTAssertTrue(session.startImageChain(definition: f.definition))
            try await self.until { f.outputs.savePending }
            let bytes = f.app.retainedCaptureDraftBytesForVerification
            XCTAssertEqual(bytes, 24 * 48 * 4)
            let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
            session.cancel()
            try self.press("close", in: manager)
            XCTAssertFalse(session.isClosedForVerification)
            XCTAssertTrue(f.app.liveScrollSessionForVerification === session)
            XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, bytes)
            XCTAssertFalse(f.app.runCaptureChain(id: f.definition.id))
            XCTAssertFalse(f.app.runTextScript(id: UUID()))
            XCTAssertThrowsError(try f.app.makeLiveScrollSessionForVerification(resourceStorageParent: f.spool))
            XCTAssertEqual(f.outputs.dependencyRequests, 1); XCTAssertEqual(f.outputs.saveCancels, 1)
            XCTAssertEqual(counter.deallocations, 0)
            f.outputs.completeSave(.cancelled)
            try await self.until { session.isClosedForVerification && f.app.liveScrollSessionForVerification == nil && counter.liveBytes == 0 }
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertEqual(f.app.retainedCaptureDraftBytesForVerification, 0)
            XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1)
            XCTAssertEqual(try Data(contentsOf: manifest), original)
            XCTAssertEqual(f.defaults.persistentDomain(forName: f.suite) as NSDictionary?, defaults)
            XCTAssertTrue(f.app.history.records.isEmpty)
            XCTAssertEqual(f.outputs.acquisitions, 0); XCTAssertEqual(f.outputs.copies, 0)
        }
    }

    private func withFixture(outputs: [CaptureChainOutput], admission: EditorAdmissionPolicy = .init(),
                             _ body: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for scroll controls") }
        let fixture = try Fixture(outputs: outputs, admission: admission, screen: screen)
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "App scroll chain did not reach its explicit ownership barrier")
    }
    private func view<T: NSView>(_ suffix: String, in controller: CaptureChainController) throws -> T {
        func find(_ root: NSView) -> T? {
            if root.identifier?.rawValue == "capture-chain-" + suffix { return root as? T }
            return root.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(try XCTUnwrap(controller.window?.contentView)))
    }
    private func press(_ suffix: String, in manager: CaptureChainController) throws {
        let button: NSButton = try view(suffix, in: manager)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
    }
    private enum Failure: Error { case output }

    @MainActor private final class Fixture {
        let root: URL, spool: URL, suite: String, defaults: UserDefaults, screen: NSScreen
        let definition: CaptureChainDefinition, store: CaptureChainStore, app: AppDelegate, outputs: Outputs
        var source: Source?
        init(outputs: [CaptureChainOutput], admission: EditorAdmissionPolicy, screen: NSScreen) throws {
            self.screen = screen
            root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-ScrollChainApp-" + UUID().uuidString)
            spool = root.appendingPathComponent("spool")
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false)
            suite = "PicShot.ScrollChainAppTests." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            definition = try CaptureChainDefinition(name: "Missing preset existing image", source: .preset(UUID()), outputs: outputs)
            store = try CaptureChainStore(directory: root.appendingPathComponent("chains"))
            try store.add(definition)
            let recipients = Outputs(); self.outputs = recipients
            app = AppDelegate(history: HistoryStore(directory: root.appendingPathComponent("history")),
                isolatedDefaults: defaults, editorAdmission: admission,
                admissionNotice: { XCTFail("Unexpected admission notice") }, chainStore: store,
                chainDependencies: { _ in recipients.dependencies() })
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
            try await SaveWorkflowUIPreviewFixture.until({ session.snapshotForVerification.canApplyImageChain && source.waiting },
                "Owned scroll image did not become ready")
            return session
        }
        func close() async {
            source?.onResume = nil
            outputs.completeSave(.cancelled)
            if let session = app.liveScrollSessionForVerification { await session.closeForVerification() }
            _ = app.activeCaptureChain?.cancel()
            if let manager = app.captureChainManagerForVerification {
                manager.onRun = nil; manager.onRetry = nil; manager.onCancel = nil; manager.onClose = nil
                manager.invalidateCommands()
            }
            Array(app.controllers).forEach { $0.close() }
            app.controllers.removeAll(); app.mainWindow.close()
            _ = app.pendingCaptureRecovery.discard()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    @MainActor private final class Outputs {
        var dependencyRequests = 0, acquisitions = 0, copies = 0, saveCancels = 0
        var failCopy = false, holdSave = false
        var savePending: Bool { saveContinuation != nil }
        private var saveContinuation: CheckedContinuation<SaveWorkflowTerminalOutcome, Never>?
        func dependencies() -> CaptureChainRunner.Dependencies {
            dependencyRequests += 1
            return .init(capture: { self.acquisitions += 1; throw CaptureError.cancelled }, savePNG: { _ in
                if self.holdSave { return await withCheckedContinuation { self.saveContinuation = $0 } }
                return .cancelled
            }, copy: { _ in self.copies += 1; if self.failCopy { throw Failure.output } },
            pin: { _ in XCTFail("Unexpected Pin"); return UUID() }, cancelSave: { self.saveCancels += 1 })
        }
        func completeSave(_ outcome: SaveWorkflowTerminalOutcome) {
            let pending = saveContinuation; saveContinuation = nil; pending?.resume(returning: outcome)
        }
    }
    @MainActor private final class Source: LiveScrollFrameSource {
        let region = CGRect(x: 80, y: 80, width: 320, height: 240)
        let displayBounds: CGRect
        var target: LiveScrollScreenSource.Target? { nil }
        var waiting: Bool { reader != nil }
        var resumeCalls = 0, onResume: (() -> Void)?
        private var running = false, sequence: UInt64 = 0
        private var reader: CheckedContinuation<LiveScrollScreenSource.Frame?, Error>?
        init(screen: NSScreen) { displayBounds = CGDisplayBounds(screen.displayID ?? 0) }
        func start() async throws { running = true }
        func resume() async throws { onResume?(); resumeCalls += 1; try await start() }
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
        func pauseAndDrain() async throws { drain() }
        func stop() async throws { drain() }
        func validateTarget() throws { }
        func moveRegion(to proposed: CGRect) throws { }
        private func drain() {
            running = false; let pending = reader; reader = nil; pending?.resume(throwing: CancellationError())
        }
    }
}
