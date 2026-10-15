import AppKit
import PicShotCore
import PicShotTextScriptCore
import XCTest
@testable import PicShot

/// Real session, accepted-frame assembler and prepared text runner. Owned
/// continuations expose lifecycle boundaries without capturing the desktop,
/// launching a helper, mutating a saved catalog or touching the public clipboard.
@MainActor
final class LiveScrollTextScriptSessionTests: XCTestCase {
    func testPickerRequiresExplicitRunAndRevalidatesChangedOrDeletedSavedDefinition() async throws {
        try await withSession { f in
            let original = f.bridge.definitions[0]
            f.bridge.definitions.append(try TextScriptDefinition(name: "Second script", source: "return text.trim();"))
            try f.dispatch("textScript")
            let choice = try XCTUnwrap(f.session.textChoiceAlertForVerification)
            let picker = try XCTUnwrap(choice.accessoryView as? NSPopUpButton)
            XCTAssertEqual(picker.indexOfSelectedItem, 0)
            picker.selectItem(at: 1)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertEqual(f.source.pauseCalls, 0)
            XCTAssertFalse(f.session.startTextScript(definition: original))
            XCTAssertFalse(f.session.startImageChain(definition: f.imageDefinition))
            choice.cancel()
            try await self.until { f.session.textChoiceAlertForVerification == nil }
            XCTAssertTrue(f.bridge.attempts.isEmpty)

            try f.dispatch("textScript")
            f.bridge.definitions[0] = try original.replacing(source: "return 'changed';")
            try f.confirmTextChoice()
            try await self.until { f.session.textChoiceAlertForVerification == nil }
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertEqual(f.source.pauseCalls, 0)
            XCTAssertFalse(f.session.startTextScript(definition: original))
            f.bridge.definitions = []
            XCTAssertFalse(f.session.startTextScript(definition: original))
            try f.dispatch("textScript")
            XCTAssertNil(f.session.textChoiceAlertForVerification)
            XCTAssertTrue(f.session.snapshotForVerification.status.contains("尚未保存文字脚本"))
            XCTAssertEqual(f.session.textRenderCountForVerification, 0)
        }
    }

    func testFinalAcceptedFrontierRendersOnceAndRunnerAdoptsIdenticalRasterWithoutSessionRetention() async throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            try await withSession(initial: { try self.orientedTexture(origin: 0, axis: axis) }) { f in
                if axis == .horizontal {
                    try f.dispatch("axis.horizontal")
                    try await self.until { f.source.waiting && !f.session.snapshotForVerification.busy }
                }
                try await f.deliver(self.orientedTexture(origin: 70, axis: axis))
                f.source.finalImageDuringPause = try self.orientedTexture(origin: 130, axis: axis)
                f.bridge.expectedPixels = try SaveWorkflowUIPreviewFixture.pixels(self.orientedTexture(origin: 0, length: 330, axis: axis))
                f.bridge.holdTransform = true
                let frozen = f.bridge.definitions[0]
                XCTAssertTrue(f.session.startTextScript(definition: frozen))
                XCTAssertFalse(f.session.startTextScript(definition: frozen))
                try await self.until { f.bridge.transformPending }
                let expectedWidth = axis == .vertical ? 160 : 330
                let expectedHeight = axis == .vertical ? 330 : 160
                XCTAssertEqual(f.session.stateForVerification.width, expectedWidth)
                XCTAssertEqual(f.session.stateForVerification.height, expectedHeight)
                XCTAssertEqual(f.session.stateForVerification.acceptedObservations, 3)
                XCTAssertEqual(f.bridge.attempts.count, 1)
                XCTAssertEqual(f.bridge.attempts[0].width, expectedWidth)
                XCTAssertEqual(f.bridge.attempts[0].height, expectedHeight)
                XCTAssertEqual(f.bridge.pixelChecks, 1, "Independently generated full-frontier pixels must match the adopted raster")
                XCTAssertEqual(f.bridge.attempts[0].sessionID, f.session.sessionID)
                XCTAssertEqual(f.session.textRenderCountForVerification, 1)
                XCTAssertEqual(f.bridge.recognitions, 1); XCTAssertEqual(f.bridge.acquisitions, 0)
                XCTAssertNil(f.session.stagedTextCapture)
                XCTAssertNil(f.bridge.activeRunner?.capture)
                XCTAssertNil(f.bridge.renderedImage, "The rendered image must leave both session and runner after OCR")
                XCTAssertTrue(f.bridge.copies.isEmpty)
                f.bridge.definitions = [try frozen.replacing(name: "Changed after launch", source: "throw text;")]
                XCTAssertEqual(f.bridge.transformedSources, [frozen.source])
                f.bridge.completeTransform(.succeeded("prepared text"))
                try await self.until { f.session.isClosedForVerification }
                XCTAssertEqual(f.bridge.copies, ["prepared text"])
                XCTAssertEqual(f.bridge.terminals.count, 1); XCTAssertEqual(f.closes, 1)
                XCTAssertEqual(f.source.pauseCalls, axis == .vertical ? 1 : 2)
                XCTAssertEqual(f.source.resumeCalls, axis == .vertical ? 0 : 1)
                XCTAssertEqual(f.ordinaryOutputs, 0)
            }
        }
    }

    func testRetryStaysInOwnedRunnerAndUsesFrozenOCRAndCopyOutputWithoutRenderingAgain() async throws {
        for failedPhase in [ChainTextPhase.recognize, .transform, .copy] {
            try await withSession { f in
                f.bridge.failOnce = failedPhase
                let definition = f.bridge.definitions[0]
                XCTAssertTrue(f.session.startTextScript(definition: definition))
                try await self.until { f.bridge.activeRunner?.status.canRetry == true }
                let runner = try XCTUnwrap(f.bridge.activeRunner), id = runner.id
                XCTAssertEqual(f.session.textAttemptID, id)
                XCTAssertNil(f.session.stagedTextCapture)
                self.assertBlocked(f.session.snapshotForVerification)
                XCTAssertFalse(f.session.startTextScript(definition: definition))
                XCTAssertTrue(runner.retry())
                try await self.until { f.session.isClosedForVerification }
                XCTAssertEqual(f.bridge.attempts.count, 1); XCTAssertEqual(f.session.textRenderCountForVerification, 1)
                XCTAssertEqual(f.bridge.recognitions, failedPhase == .recognize ? 2 : 1)
                XCTAssertEqual(f.bridge.transforms, failedPhase == .transform ? 2 : 1)
                XCTAssertEqual(f.bridge.copies.count, failedPhase == .copy ? 2 : 1)
                XCTAssertEqual(f.bridge.terminals.last?.runID, id)
                XCTAssertEqual(f.source.resumeCalls, 0)
            }
        }
    }

    func testPendingScriptRejectsForcedCaptureOutputMoveAxisAndImageChainCommands() async throws {
        try await withSession { f in
            let stale = f.session.snapshotForVerification
            f.bridge.holdTransform = true
            XCTAssertTrue(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try await self.until { f.bridge.transformPending }
            let controls = try XCTUnwrap(f.session.controlsForVerification), toolbar = try f.toolbar()
            for button in [toolbar.finishButton, toolbar.copyButton, toolbar.pauseButton, toolbar.autoButton] {
                var before = stale; before.canAutoScroll = true
                controls.update(snapshot: before)
                try PortableSettingsUIPreviewFixture.click(button)
            }
            for suffix in ["quickSave", "pin", "moveRegion", "axis.horizontal", "imageChain", "textScript"] {
                var before = stale
                before.canQuickSave = true; before.canPin = true; before.canMoveRegion = true
                before.canChangeAxis = true; before.canApplyImageChain = true; before.canApplyTextScript = true
                controls.update(snapshot: before)
                try f.dispatch(suffix, requireEnabled: false)
            }
            f.session.show()
            XCTAssertEqual(f.ordinaryOutputs, 0); XCTAssertEqual(f.imageRuns, 0)
            XCTAssertEqual(f.source.resumeCalls, 0); XCTAssertEqual(f.source.moveCalls, 0)
            XCTAssertNil(f.session.chainTransaction); XCTAssertNil(f.session.chainChoiceAlertForVerification)
            XCTAssertNil(f.session.textChoiceAlertForVerification)
            XCTAssertEqual(f.session.snapshotForVerification.axis, .vertical)
            self.assertBlocked(f.session.snapshotForVerification)
            f.bridge.completeTransform(.cancelled(cleanupPending: false))
            try await self.until { f.session.snapshotForVerification.canApplyTextScript }
            XCTAssertTrue(f.session.snapshotForVerification.paused)
        }
    }

    func testImageChoiceAndPendingImageTransactionCannotCoexistWithTextScript() async throws {
        try await withSession { f in
            try f.dispatch("imageChain")
            XCTAssertFalse(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try XCTUnwrap(f.session.chainChoiceAlertForVerification).cancel()
            try await self.until { f.session.chainChoiceAlertForVerification == nil }
            XCTAssertTrue(f.session.startImageChain(definition: f.imageDefinition))
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            XCTAssertFalse(f.session.snapshotForVerification.canApplyTextScript)
            XCTAssertFalse(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try f.dispatch("textScript", requireEnabled: false)
            XCTAssertNil(f.session.textChoiceAlertForVerification)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertNotNil(f.session.chainTransaction)
        }
    }

    func testAlreadyOversizedActiveDraftRejectsWithoutPausingOrDraining() async throws {
        // Each observation stays below the 24 MP frame limit; accepted scrolling
        // grows the active composite beyond the separate 32 MP text limit.
        try await withSession(initial: { try self.largeTexture(origin: 0) }) { f in
            XCTAssertEqual(f.session.stateForVerification.width, 8_000)
            XCTAssertEqual(f.session.stateForVerification.height, 2_000)
            XCTAssertEqual(f.session.stateForVerification.acceptedObservations, 1)
            XCTAssertFalse(f.session.snapshotForVerification.paused)
            XCTAssertEqual(f.source.pauseCalls, 0)
            XCTAssertTrue(f.session.snapshotForVerification.canApplyTextScript)

            try await f.deliver(self.largeTexture(origin: 1_300))
            XCTAssertEqual(f.session.stateForVerification.width, 8_000)
            XCTAssertEqual(f.session.stateForVerification.height, 3_300)
            XCTAssertEqual(f.session.stateForVerification.acceptedObservations, 2)
            XCTAssertFalse(f.session.snapshotForVerification.paused)
            XCTAssertEqual(f.source.pauseCalls, 0)
            XCTAssertTrue(f.session.snapshotForVerification.canApplyTextScript)

            try await f.deliver(self.largeTexture(origin: 2_001))
            XCTAssertEqual(f.session.stateForVerification.width, 8_000)
            XCTAssertEqual(f.session.stateForVerification.height, 4_001)
            XCTAssertEqual(f.session.stateForVerification.acceptedObservations, 3)
            XCTAssertFalse(f.session.snapshotForVerification.paused)
            XCTAssertEqual(f.source.pauseCalls, 0)
            XCTAssertFalse(f.session.snapshotForVerification.canApplyTextScript)
            XCTAssertFalse(f.session.startTextScript(definition: f.bridge.definitions[0]))
            XCTAssertFalse(f.session.snapshotForVerification.paused)
            XCTAssertFalse(f.session.snapshotForVerification.busy)
            XCTAssertTrue(f.source.waiting)
            XCTAssertEqual(f.source.pauseCalls, 0)
            XCTAssertEqual(f.session.textRenderCountForVerification, 0)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertNil(f.session.textAttemptID)
            XCTAssertNil(f.session.stagedTextCapture); XCTAssertNil(f.session.chainTransaction)
            XCTAssertTrue(f.session.snapshotForVerification.status.contains("3200 万像素"))
            XCTAssertTrue(f.session.snapshotForVerification.status.contains("当前长图仍保留"))
        }
    }

    func testPostDrain32MillionPixelCrossingRejectsBeforeRenderAndKnownOversizeRejectsBeforeDrain() async throws {
        try await withSession(initial: { try self.largeTexture(origin: 0) }) { f in
            try await f.deliver(self.largeTexture(origin: 1_300))
            XCTAssertEqual(f.session.stateForVerification.height, 3_300)
            f.source.finalImageDuringPause = try self.largeTexture(origin: 2_001)
            XCTAssertTrue(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try await self.until { !f.session.snapshotForVerification.busy }
            XCTAssertEqual(f.session.stateForVerification.height, 4_001)
            XCTAssertEqual(f.source.pauseCalls, 1)
            XCTAssertEqual(f.session.textRenderCountForVerification, 0)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertNil(f.session.stagedTextCapture)
            XCTAssertTrue(f.session.snapshotForVerification.paused)
            XCTAssertFalse(f.session.snapshotForVerification.autoScrolling)
            XCTAssertFalse(f.session.snapshotForVerification.canApplyTextScript)
            XCTAssertTrue(f.session.snapshotForVerification.textScriptUnavailableReason.contains("3200 万像素"))
            XCTAssertFalse(f.session.startTextScript(definition: f.bridge.definitions[0]))
            XCTAssertEqual(f.source.pauseCalls, 1, "Known oversized input is rejected before another drain")
            XCTAssertTrue(f.session.snapshotForVerification.canFinish)
        }
    }

    func testExactly32MillionPixelsAtFinalFrontierPassesSameRecognitionPredicate() async throws {
        try await withSession(initial: { try self.largeTexture(origin: 0) }) { f in
            try await f.deliver(self.largeTexture(origin: 1_300))
            f.source.finalImageDuringPause = try self.largeTexture(origin: 2_000)
            XCTAssertTrue(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.bridge.attempts.first?.width, 8_000)
            XCTAssertEqual(f.bridge.attempts.first?.height, 4_000)
            XCTAssertEqual(f.session.textRenderCountForVerification, 1)
            XCTAssertEqual(f.bridge.recognitions, 1); XCTAssertEqual(f.bridge.copies.count, 1)
        }
    }

    func testUnconfirmedDrainNeverRendersOrStartsAndPreservesPausedDraft() async throws {
        try await withSession { f in
            f.source.refusePause = true
            XCTAssertTrue(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try await self.until { !f.session.snapshotForVerification.busy }
            XCTAssertEqual(f.source.pauseCalls, 1)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertEqual(f.session.textRenderCountForVerification, 0)
            XCTAssertTrue(f.session.snapshotForVerification.paused); XCTAssertFalse(f.session.snapshotForVerification.autoScrolling)
            XCTAssertTrue(f.session.snapshotForVerification.canFinish)
            XCTAssertTrue(f.session.snapshotForVerification.status.contains("当前长图保持暂停"))
            XCTAssertNil(f.session.textAttemptID); XCTAssertNil(f.session.stagedTextCapture)
            f.source.refusePause = false
            XCTAssertTrue(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.bridge.attempts.count, 1)
        }
    }

    func testCloseDuringBlockedDrainWaitsThenDiscardsLateFrontierWithoutRendering() async throws {
        try await withSession { f in
            f.source.holdPause = true
            XCTAssertTrue(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try await self.until { f.source.pausePending }
            let runID = try XCTUnwrap(f.session.textAttemptID)
            f.session.cancel(); f.session.cancel()
            XCTAssertFalse(f.session.acceptsTextRun(runID: runID))
            XCTAssertFalse(f.session.isClosedForVerification); XCTAssertEqual(f.closes, 0)
            XCTAssertNil(f.session.controlsForVerification)
            f.source.releasePause()
            try await self.until { f.session.isClosedForVerification }
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertEqual(f.session.textRenderCountForVerification, 0)
            XCTAssertEqual(f.closes, 1)
        }
    }

    func testCloseDuringRunnerDrainSettlesRetiredWaiterAndClosesExactlyOnce() async throws {
        try await withSession { f in
            f.bridge.holdTransform = true
            XCTAssertTrue(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try await self.until { f.bridge.transformPending }
            let id = try XCTUnwrap(f.session.textAttemptID)
            f.session.cancel(); f.session.cancel()
            XCTAssertFalse(f.session.isClosedForVerification); XCTAssertEqual(f.closes, 0)
            XCTAssertEqual(f.bridge.cancelledIDs, [id])
            f.bridge.completeTransform(.succeeded("must not copy"))
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.closes, 1); XCTAssertTrue(f.bridge.copies.isEmpty)
            XCTAssertEqual(f.bridge.terminals.last?.status, .cancelled)
            XCTAssertNil(f.session.stagedTextCapture); XCTAssertNil(f.session.textAttemptID)
            f.bridge.callbacks[0](try XCTUnwrap(f.bridge.terminals.last))
            XCTAssertEqual(f.closes, 1)
        }
    }

    func testSynchronousDuplicateAndWrongRunTerminalsSettleOnceAndCannotControlSuccessor() async throws {
        try await withSession { f in
            f.bridge.synchronousTerminal = .cancelled
            f.bridge.emitWrongRunFirst = true; f.bridge.emitWrongDefinitionFirst = true
            let saved = f.bridge.definitions[0]
            XCTAssertTrue(f.session.startTextScript(definition: saved))
            try await self.until { f.session.snapshotForVerification.canApplyTextScript }
            let oldCallback = f.bridge.callbacks[0], oldTerminal = try XCTUnwrap(f.bridge.terminals.last)
            XCTAssertEqual(f.closes, 0); XCTAssertTrue(f.session.snapshotForVerification.paused)
            XCTAssertEqual(f.session.textRenderCountForVerification, 1)
            XCTAssertNil(f.session.stagedTextCapture)
            f.bridge.synchronousTerminal = nil; f.bridge.holdTransform = true
            XCTAssertTrue(f.session.startTextScript(definition: saved))
            try await self.until { f.bridge.transformPending }
            let current = f.session.textAttemptID
            oldCallback(oldTerminal)
            oldCallback(f.bridge.snapshot(runID: oldTerminal.runID, definition: saved, committed: true))
            XCTAssertEqual(f.session.textAttemptID, current)
            XCTAssertFalse(f.session.isClosedForVerification); XCTAssertTrue(f.bridge.copies.isEmpty)
            f.bridge.completeTransform(.succeeded("new result"))
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.closes, 1); XCTAssertEqual(f.bridge.copies, ["new result"])
            XCTAssertEqual(f.session.textRenderCountForVerification, 2)
        }
    }

    func testSynchronousCommittedTerminalAndCancelledAfterCheckedCopyBothRetireWithoutReplay() async throws {
        for synchronous in [true, false] {
            try await withSession { f in
                if synchronous { f.bridge.synchronousTerminal = .completed }
                else { f.bridge.cancelAtCopy = true }
                let saved = f.bridge.definitions[0]
                XCTAssertTrue(f.session.startTextScript(definition: saved))
                try await self.until { f.session.isClosedForVerification }
                XCTAssertNotNil(f.bridge.terminals.last?.textReceipt)
                XCTAssertEqual(f.bridge.terminals.last?.status, synchronous ? .completed : .cancelled)
                XCTAssertEqual(f.closes, 1); XCTAssertEqual(f.session.textRenderCountForVerification, 1)
                XCTAssertFalse(f.session.startTextScript(definition: saved))
                let result = try XCTUnwrap(f.bridge.terminals.last)
                f.bridge.callbacks[0](result)
                XCTAssertEqual(f.closes, 1)
            }
        }
    }

    func testRunnerCancelPreservesDraftWithoutRestartingPreviouslyEnabledAuto() async throws {
        try await withSession { f in
            let toolbar = try f.toolbar()
            XCTAssertTrue(f.session.snapshotForVerification.canAutoScroll)
            try PortableSettingsUIPreviewFixture.click(toolbar.autoButton)
            XCTAssertTrue(f.session.snapshotForVerification.autoScrolling)
            XCTAssertEqual(f.automaticEvents, 1)
            f.bridge.holdTransform = true
            XCTAssertTrue(f.session.startTextScript(definition: f.bridge.definitions[0]))
            try await self.until { f.bridge.transformPending }
            XCTAssertFalse(f.session.snapshotForVerification.autoScrolling)
            XCTAssertTrue(f.bridge.activeRunner?.cancel() == true)
            f.bridge.completeTransform(.cancelled(cleanupPending: false))
            try await self.until { f.session.snapshotForVerification.canApplyTextScript }
            XCTAssertTrue(f.session.snapshotForVerification.paused)
            XCTAssertFalse(f.session.snapshotForVerification.autoScrolling)
            XCTAssertFalse(f.session.snapshotForVerification.canAutoScroll)
            XCTAssertEqual(f.source.resumeCalls, 0); XCTAssertEqual(f.automaticEvents, 1)
            XCTAssertTrue(f.bridge.copies.isEmpty)
            XCTAssertEqual(f.bridge.terminals.last?.retainedBytes, 0)
            XCTAssertEqual(f.bridge.terminals.last?.retainedTextBytes, 0)
            XCTAssertNil(f.bridge.activeRunner)
        }
    }

    func testClosedChoiceCannotStartOrDismissReopenedSessionsChoice() async throws {
        var oldChoice: LiveScrollChainChoiceController?
        try await withSession { f in
            try f.dispatch("textScript")
            oldChoice = try XCTUnwrap(f.session.textChoiceAlertForVerification)
            f.session.cancel()
            try await self.until { f.session.isClosedForVerification }
            XCTAssertNil(oldChoice?.window.sheetParent); XCTAssertFalse(oldChoice?.window.isVisible ?? true)
            XCTAssertTrue(f.bridge.attempts.isEmpty)
        }
        try await withSession { f in
            try f.dispatch("textScript")
            let current = try XCTUnwrap(f.session.textChoiceAlertForVerification)
            let old = try XCTUnwrap(oldChoice)
            if let button = old.buttons.first, let action = button.action {
                _ = NSApp.sendAction(action, to: button.target, from: button)
            }
            old.cancel()
            XCTAssertTrue(f.session.textChoiceAlertForVerification === current)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertEqual(f.source.pauseCalls, 0)
            current.cancel()
        }
    }

    private func withSession(initial: (() throws -> CGImage)? = nil,
                             _ body: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for scroll controls") }
        let root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-ScrollText-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try Fixture(root: root, screen: screen)
        do {
            try await f.session.startForVerification(source: f.source, screen: screen)
            try await until { f.source.waiting }
            try autoreleasepool { f.source.offer(try initial?() ?? SaveWorkflowUIPreviewFixture.sourceImage(width: 24, height: 48)) }
            try await until { f.source.waiting && f.session.stateForVerification.width > 0 }
            try await body(f)
        } catch {
            f.source.releasePause(); f.bridge.completeTransform(.cancelled(cleanupPending: false))
            await f.session.closeForVerification()
            throw error
        }
        f.source.releasePause(); f.bridge.completeTransform(.cancelled(cleanupPending: false))
        await f.session.closeForVerification()
        XCTAssertTrue(f.session.isClosedForVerification); XCTAssertEqual(f.closes, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "Scroll text did not reach its owned lifecycle barrier")
    }

    private func assertBlocked(_ s: LiveScrollCaptureSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(s.busy, file: file, line: line)
        for allowed in [s.canFinish, s.canCopy, s.canQuickSave, s.canPin, s.canPause, s.canMoveRegion,
                        s.canAutoScroll, s.canChangeAxis, s.canImport, s.canApplyImageChain,
                        s.canContinueImageChain, s.canReplaceImageChain, s.canAbandonImageChain, s.canApplyTextScript] {
            XCTAssertFalse(allowed, file: file, line: line)
        }
    }

    private func texture(origin: Int) throws -> CGImage {
        try makeTexture(width: 160, height: 200, origin: origin)
    }
    private func orientedTexture(origin: Int, length: Int = 200, axis: ScrollAxis) throws -> CGImage {
        let image = try makeTexture(width: 160, height: length, origin: origin)
        if axis == .vertical { return image }
        return try XCTUnwrap(PinImageRenderer.render(image: image, transform: .rotateClockwise))
    }
    private func largeTexture(origin: Int) throws -> CGImage {
        try makeTexture(width: 8_000, height: 2_000, origin: origin)
    }
    private func makeTexture(width: Int, height: Int, origin: Int) throws -> CGImage {
        let rowBytes = width / 8
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height { for column in 0..<rowBytes {
            var value = UInt64(y + origin + 10_000) &* 0x9e3779b185ebca87
            value ^= UInt64(column + 1) &* 0xc2b2ae3d27d4eb4f
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            bytes[y * rowBytes + column] = UInt8(truncatingIfNeeded: value)
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1,
            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private enum Failure: Error { case drain, output, unexpectedCapture }

    @MainActor private final class Fixture {
        let source: Source, bridge: Bridge, imageDefinition: CaptureChainDefinition
        var session: LiveScrollSessionController!
        var ordinaryOutputs = 0, imageRuns = 0, closes = 0, automaticEvents = 0
        init(root: URL, screen: NSScreen) throws {
            source = Source(screen: screen); bridge = try Bridge()
            imageDefinition = try CaptureChainDefinition(name: "Image-only route", source: .region, outputs: [.copy])
            session = LiveScrollSessionController(onComplete: { [weak self] _ in self?.ordinaryOutputs += 1 },
                onImport: { [weak self] in self?.ordinaryOutputs += 1 },
                onCopy: { [weak self] _ in self?.ordinaryOutputs += 1 },
                onPin: { [weak self] _ in self?.ordinaryOutputs += 1 }, resourceStorageParent: root,
                automaticScrollPermission: { true }, automaticScrollInput: { [weak self] _ in self?.automaticEvents += 1 },
                chainDependencies: .init(definitions: { [imageDefinition] in [imageDefinition] }, run: { [weak self] transaction, id in
                    self?.imageRuns += 1
                    return .init(runID: id, definition: transaction.definition, status: .cancelled, receipts: [],
                        capturedAt: transaction.capture.capturedAt, retainedBytes: 0, isExistingScrollImage: true)
                }, cancel: { _ in }),
                textDependencies: .init(definitions: { [bridge] in bridge.definitions },
                    start: { [bridge] sessionID, runID, definition, prepared, terminal in
                        try bridge.start(sessionID: sessionID, runID: runID, definition: definition, prepared: prepared, terminal: terminal)
                    }, cancel: { [bridge] in bridge.cancel($0) }))
            bridge.session = session
            session.onClose = { [weak self] in self?.closes += 1 }
        }
        func toolbar() throws -> LiveScrollToolbarView {
            try XCTUnwrap(session.controlsForVerification?.toolbarWindow?.contentView as? LiveScrollToolbarView)
        }
        func dispatch(_ suffix: String, requireEnabled: Bool = true) throws {
            let item = try XCTUnwrap(toolbar().moreButton.menu?.items.first { $0.identifier?.rawValue == "scroll.live." + suffix })
            if requireEnabled { XCTAssertTrue(item.isEnabled, suffix) }
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        func confirmTextChoice() throws {
            let choice = try XCTUnwrap(session.textChoiceAlertForVerification)
            let parent = try XCTUnwrap(choice.window.sheetParent)
            parent.endSheet(choice.window, returnCode: .alertFirstButtonReturn)
        }
        func deliver(_ image: CGImage) async throws {
            try await SaveWorkflowUIPreviewFixture.until({ self.source.waiting }, "Source did not wait for a frame")
            let previous = session.sampledFramesForVerification
            source.offer(image)
            try await SaveWorkflowUIPreviewFixture.until({ self.source.waiting && self.session.sampledFramesForVerification > previous }, "Frame was not accepted")
            XCTAssertTrue(session.stateForVerification.matched)
        }
    }

    @MainActor private final class Bridge {
        struct Attempt { let sessionID: UUID, runID: UUID; let definition: TextScriptDefinition; let width: Int, height: Int }
        weak var session: LiveScrollSessionController?
        weak var renderedImage: CGImage?
        var definitions: [TextScriptDefinition]
        var attempts: [Attempt] = [], callbacks: [(CaptureChainSnapshot) -> Void] = [], terminals: [CaptureChainSnapshot] = []
        var activeRunner: CaptureChainRunner?
        var acquisitions = 0, recognitions = 0, transforms = 0, pixelChecks = 0
        var expectedPixels: Data?
        var transformedSources: [String] = [], copies: [String] = [], cancelledIDs: [UUID] = []
        var failOnce: ChainTextPhase?, holdTransform = false, cancelAtCopy = false, emitWrongRunFirst = false
        var emitWrongDefinitionFirst = false
        var synchronousTerminal: CaptureChainStatus?
        private var transformContinuation: CheckedContinuation<ChainTextTransformResult, Never>?
        var transformPending: Bool { transformContinuation != nil }
        init() throws { definitions = [try TextScriptDefinition(name: "Explicit saved script", source: "return text;")] }
        func start(sessionID: UUID, runID: UUID, definition: TextScriptDefinition, prepared: ChainCapture,
                   terminal: @escaping (CaptureChainSnapshot) -> Void) throws {
            XCTAssertEqual(session?.textAttemptID, runID)
            XCTAssertTrue(session?.acceptsTextRun(runID: runID) == true)
            XCTAssertTrue(session?.stagedTextCapture?.image === prepared.image)
            XCTAssertNil(activeRunner)
            attempts.append(.init(sessionID: sessionID, runID: runID, definition: definition,
                width: prepared.image.width, height: prepared.image.height))
            callbacks.append(terminal); renderedImage = prepared.image
            if let expectedPixels {
                XCTAssertEqual(try SaveWorkflowUIPreviewFixture.pixels(prepared.image), expectedPixels)
                pixelChecks += 1
            }
            if emitWrongRunFirst { terminal(snapshot(runID: UUID(), definition: definition, committed: true)) }
            if emitWrongDefinitionFirst {
                terminal(snapshot(runID: runID, definition: try definition.replacing(name: "Wrong frozen name"), committed: true))
                terminal(snapshot(runID: runID, definition: try TextScriptDefinition(name: definition.name, source: definition.source), committed: true))
                for invalid in [
                    try CaptureChainDefinition(id: definition.id, name: definition.name, source: .preset(UUID()), outputs: [.copy]),
                    try CaptureChainDefinition(id: definition.id, name: definition.name, source: .region, outputs: [.pin])
                ] {
                    terminal(.init(runID: runID, definition: invalid, status: .completed, receipts: [],
                        capturedAt: nil, retainedBytes: 0, isTextScript: true,
                        textReceipt: .init(characterCount: 8), isExistingScrollImage: true))
                }
                terminal(.init(runID: runID,
                    definition: try CaptureChainDefinition(id: definition.id, name: definition.name, source: .region, outputs: [.copy]),
                    status: .completed, receipts: [.init(output: .copy, value: .copied)], capturedAt: nil, retainedBytes: 0,
                    isTextScript: true, textReceipt: .init(characterCount: 8), isExistingScrollImage: true))
            }
            if let status = synchronousTerminal {
                let result = snapshot(runID: runID, definition: definition, committed: status == .completed)
                terminals.append(result); terminal(result); terminal(result)
                return
            }
            let imageID = ObjectIdentifier(prepared.image)
            let runner = try CaptureChainRunner(textScript: definition, preparedCapture: prepared, dependencies: .init(
                capture: { self.acquisitions += 1; throw Failure.unexpectedCapture }, recognize: { image in
                    self.recognitions += 1
                    XCTAssertEqual(ObjectIdentifier(image), imageID)
                    XCTAssertNil(self.session?.stagedTextCapture)
                    if self.failOnce == .recognize && self.recognitions == 1 { throw Failure.output }
                    return .init(text: "recognized text")
                }, transform: { source, text, _ in
                    self.transforms += 1; self.transformedSources.append(source)
                    XCTAssertEqual(text, "recognized text"); XCTAssertNil(self.session?.stagedTextCapture)
                    if self.holdTransform { return await withCheckedContinuation { self.transformContinuation = $0 } }
                    if self.failOnce == .transform && self.transforms == 1 { return .failed(.script(.scriptException), cleanupPending: false) }
                    return .succeeded("prepared text")
                }, copy: { text in
                    self.copies.append(text)
                    if self.failOnce == .copy && self.copies.count == 1 { throw Failure.output }
                    if self.cancelAtCopy { _ = self.activeRunner?.cancel() }
                }, cleanupComplete: { _ in true }), id: runID)
            activeRunner = runner
            runner.onTerminal = { [weak self] snapshot in
                self?.terminals.append(snapshot)
                if self?.activeRunner?.id == runID { self?.activeRunner = nil }
                terminal(snapshot)
            }
            XCTAssertTrue(runner.start())
        }
        func snapshot(runID: UUID, definition: TextScriptDefinition, committed: Bool) -> CaptureChainSnapshot {
            .init(runID: runID, definition: try! CaptureChainDefinition(id: definition.id, name: definition.name, source: .region, outputs: [.copy]),
                status: committed ? .completed : .cancelled, receipts: [], capturedAt: nil, retainedBytes: 0,
                isTextScript: true, textReceipt: committed ? .init(characterCount: 8) : nil, isExistingScrollImage: true)
        }
        func cancel(_ id: UUID) {
            guard activeRunner?.id == id else { return }
            cancelledIDs.append(id); _ = activeRunner?.cancel()
        }
        func completeTransform(_ result: ChainTextTransformResult) {
            let pending = transformContinuation; transformContinuation = nil; pending?.resume(returning: result)
        }
    }

    @MainActor private final class Source: LiveScrollFrameSource {
        let region = CGRect(x: 80, y: 80, width: 320, height: 240)
        let displayBounds: CGRect
        var target: LiveScrollScreenSource.Target? { nil }
        var automaticScrollWatermark: LiveScrollFrameWatermark? { .init(generation: generation, sequence: sequence) }
        var waiting: Bool { reader != nil }
        var pausePending: Bool { pauseContinuation != nil }
        var pauseCalls = 0, resumeCalls = 0, moveCalls = 0, holdPause = false, refusePause = false
        var finalImageDuringPause: CGImage?
        private var generation: UInt64 = 0, sequence: UInt64 = 0, running = false
        private var reader: CheckedContinuation<LiveScrollScreenSource.Frame?, Error>?
        private var pauseContinuation: CheckedContinuation<Void, Never>?
        init(screen: NSScreen) { displayBounds = CGDisplayBounds(screen.displayID ?? 0) }
        func start() async throws { generation &+= 1; running = true }
        func resume() async throws { resumeCalls += 1; try await start() }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            try Task.checkCancellation()
            guard running else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { reader = $0 }
        }
        func offer(_ image: CGImage) {
            sequence &+= 1
            let pending = reader; reader = nil
            pending?.resume(returning: .init(image: image, sequence: sequence, generation: generation,
                timestamp: TimeInterval(sequence), region: region))
        }
        func pauseAndDrain() async throws {
            pauseCalls += 1
            if let image = finalImageDuringPause { finalImageDuringPause = nil; offer(image) }
            drain()
            if holdPause { await withCheckedContinuation { pauseContinuation = $0 } }
            if refusePause { throw Failure.drain }
        }
        func stop() async throws { drain() }
        func validateTarget() throws { }
        func moveRegion(to proposed: CGRect) throws { moveCalls += 1 }
        func releasePause() { let pending = pauseContinuation; pauseContinuation = nil; pending?.resume() }
        private func drain() {
            running = false
            let pending = reader; reader = nil; pending?.resume(throwing: CancellationError())
        }
    }
}
