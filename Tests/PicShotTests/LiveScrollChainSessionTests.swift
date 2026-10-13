import AppKit
import XCTest
import PicShotCore
@testable import PicShot

/// An owned frame source feeds the production scroll owner and assembler. The
/// injected recipient runs the real prepared runner; native More actions retain
/// their production command guards. No desktop input or public clipboard is used.
@MainActor
final class LiveScrollChainSessionTests: XCTestCase {
    func testAll15OrdersRenderOnceAcquireNothingAndDeliverIdenticalFrozenPixels() async throws {
        let choices: [CaptureChainOutput] = [.quickSavePNG, .copy, .pin]
        var orders = choices.map { [$0] }
        for first in choices { for second in choices where second != first {
            orders.append([first, second])
            for third in choices where third != first && third != second { orders.append([first, second, third]) }
        } }
        XCTAssertEqual(orders.count, 15)
        for order in orders {
            try await withSession(outputs: order) { f in
                let samples = f.session.sampledFramesForVerification
                XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
                XCTAssertFalse(f.session.startImageChain(definition: f.bridge.definitions[0]))
                try await self.until { f.session.isClosedForVerification }
                XCTAssertEqual(f.session.chainRenderCountForVerification, 1)
                XCTAssertEqual(f.bridge.acquisitions, 0); XCTAssertEqual(f.bridge.attempts.count, 1)
                XCTAssertEqual(f.bridge.outputs, order)
                XCTAssertEqual(f.bridge.terminalSnapshots.last?.receipts.map(\.output), order)
                XCTAssertEqual(Set(f.bridge.imageIDs).count, 1)
                XCTAssertEqual(f.session.sampledFramesForVerification, samples)
                XCTAssertEqual(f.source.resumeCalls, 0); XCTAssertEqual(f.source.pauseCalls, 1)
                XCTAssertEqual(f.ordinaryOutputs, 0); XCTAssertEqual(f.closes, 1)
                XCTAssertNil(f.session.retainedChainCapture)
                if let url = f.bridge.savedURLs.first {
                    XCTAssertEqual(try SaveWorkflowUIPreviewFixture.pixels(SaveWorkflowUIPreviewFixture.decode(url)), f.expectedPixels)
                }
            }
        }
    }

    func testSaveFailureCancelBackReopenAndContinueKeepsFrozenDefinitionPrefixAndFreshAttemptID() async throws {
        try await withSession(outputs: [.quickSavePNG, .copy, .pin]) { f in
            f.bridge.failCopy = true
            let original = f.bridge.definitions[0]
            XCTAssertTrue(f.session.startImageChain(definition: original))
            try await self.until { f.bridge.activeRunner?.status.canRetry == true }
            let runner = try XCTUnwrap(f.bridge.activeRunner), saved = runner.receipts
            XCTAssertEqual(saved.map(\.output), [.quickSavePNG])
            XCTAssertTrue(runner.cancel())
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            let checkpoint = try XCTUnwrap(f.session.chainTransaction)
            XCTAssertEqual(checkpoint.receipts, saved); XCTAssertEqual(checkpoint.definition, original)
            XCTAssertTrue(f.session.snapshotForVerification.status.contains("继续不会重复"))
            XCTAssertTrue(f.session.snapshotForVerification.chainContinueTitle.contains("1/3"))
            XCTAssertEqual(f.session.retainedChainCapture?.retainedBytes, checkpoint.capture.retainedBytes)
            let menu = try XCTUnwrap(f.toolbar().moreButton.menu)
            f.session.show()
            XCTAssertTrue(try f.toolbar().moreButton.menu === menu)
            XCTAssertEqual(f.session.chainTransaction?.receipts, saved)
            XCTAssertEqual(f.bridge.attempts.count, 1)

            // Continue uses frozen metadata even after catalog deletion. A
            // separately requested transaction must still revalidate the catalog.
            f.bridge.definitions = []
            XCTAssertFalse(f.session.startImageChain(definition: original, replacingTransactionID: checkpoint.transactionID))
            XCTAssertEqual(f.session.chainTransaction?.receipts, saved)
            f.bridge.failCopy = false
            try f.dispatch("imageChain.continue")
            XCTAssertFalse(f.session.continueImageChain(transactionID: checkpoint.transactionID))
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.bridge.attempts.count, 2)
            XCTAssertNotEqual(f.bridge.attempts[0].runID, f.bridge.attempts[1].runID)
            XCTAssertEqual(f.bridge.attempts[0].transactionID, f.bridge.attempts[1].transactionID)
            XCTAssertEqual(f.bridge.attempts[0].revisionID, f.bridge.attempts[1].revisionID)
            XCTAssertEqual(f.bridge.attempts[1].definition, original)
            XCTAssertEqual(f.bridge.attempts[1].receipts, saved)
            XCTAssertEqual(f.bridge.outputs, [.quickSavePNG, .copy, .copy, .pin])
            XCTAssertEqual(f.bridge.savedURLs.count, 1); XCTAssertEqual(f.bridge.pinIDs.count, 1)
            XCTAssertEqual(f.session.chainRenderCountForVerification, 1)
            XCTAssertEqual(Set(f.bridge.imageIDs).count, 1); XCTAssertEqual(f.bridge.acquisitions, 0)
            XCTAssertEqual(f.closes, 1)
        }
    }

    func testPendingCheckpointRejectsForcedOrdinaryOutputCaptureMoveAndAxisActions() async throws {
        try await withSession(outputs: [.pin, .quickSavePNG]) { f in
            f.bridge.cancelFirstSave = true
            let before = f.session.snapshotForVerification
            XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            let checkpoint = try XCTUnwrap(f.session.chainTransaction)
            XCTAssertEqual(checkpoint.receipts.map(\.output), [.pin])
            let controls = try XCTUnwrap(f.session.controlsForVerification)
            let toolbar = try f.toolbar(), initialAxis = f.session.snapshotForVerification.axis
            let pauses = f.source.pauseCalls, samples = f.session.sampledFramesForVerification
            for button in [toolbar.finishButton, toolbar.copyButton, toolbar.pauseButton] {
                controls.update(snapshot: before)
                try PortableSettingsUIPreviewFixture.click(button)
            }
            for suffix in ["quickSave", "pin", "moveRegion", "axis.horizontal", "imageChain"] {
                var stale = before
                stale.canQuickSave = true; stale.canPin = true; stale.canMoveRegion = true
                stale.canChangeAxis = true; stale.canImport = true; stale.canAutoScroll = true
                controls.update(snapshot: stale)
                try f.dispatch(suffix, requireEnabled: false)
            }
            f.session.show()
            XCTAssertEqual(f.session.chainTransaction?.transactionID, checkpoint.transactionID)
            XCTAssertEqual(f.session.chainTransaction?.receipts, checkpoint.receipts)
            XCTAssertEqual(f.bridge.outputs, [.pin, .quickSavePNG])
            XCTAssertEqual(f.bridge.attempts.count, 1); XCTAssertEqual(f.ordinaryOutputs, 0)
            XCTAssertEqual(f.source.resumeCalls, 0); XCTAssertEqual(f.source.moveCalls, 0)
            XCTAssertEqual(f.source.pauseCalls, pauses); XCTAssertEqual(f.session.sampledFramesForVerification, samples)
            XCTAssertEqual(f.session.snapshotForVerification.axis, initialAxis)
            XCTAssertNil(f.session.activeMoveViewForVerification)
            self.assertCheckpointBlocksMutation(f.session.snapshotForVerification)
            try f.dispatch("imageChain.continue")
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.bridge.pinIDs.count, 1); XCTAssertEqual(f.bridge.savedURLs.count, 1)
        }
    }

    func testReplacementWarningCancelAndInvalidSelectionPreserveCheckpointThenExplicitNewChainReusesRaster() async throws {
        try await withSession(outputs: [.pin, .quickSavePNG]) { f in
            f.bridge.cancelFirstSave = true
            XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            let old = try XCTUnwrap(f.session.chainTransaction)
            try f.dispatch("imageChain.replace")
            let alert = try XCTUnwrap(f.session.chainChoiceAlertForVerification)
            XCTAssertEqual(alert.buttons.first?.title, "开始新动作链")
            XCTAssertTrue(alert.informativeText.contains("可能再次保存、复制或贴图"))
            XCTAssertTrue(alert.informativeText.contains(try XCTUnwrap(f.bridge.pinIDs.first).uuidString))
            try f.dismissChoice(.alertSecondButtonReturn)
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            XCTAssertEqual(f.session.chainTransaction?.receipts, old.receipts)
            XCTAssertEqual(f.session.chainTransaction?.transactionID, old.transactionID)

            let changed = try CaptureChainDefinition(id: old.definition.id, name: "Edited catalog entry",
                source: old.definition.source, outputs: [.copy])
            f.bridge.definitions = [changed]
            XCTAssertFalse(f.session.startImageChain(definition: old.definition, replacingTransactionID: old.transactionID))
            XCTAssertEqual(f.session.chainTransaction?.receipts, old.receipts)
            let replacement = try CaptureChainDefinition(name: "Deliberately repeat Pin", source: .region, outputs: [.pin])
            f.bridge.definitions = [replacement]
            try f.dispatch("imageChain.replace")
            try f.dismissChoice(.alertFirstButtonReturn)
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.bridge.pinIDs.count, 2, "A deliberately new transaction may repeat a committed output")
            XCTAssertEqual(f.bridge.attempts.count, 2)
            XCTAssertNotEqual(f.bridge.attempts[1].transactionID, old.transactionID)
            XCTAssertEqual(f.bridge.attempts[1].revisionID, old.revisionID)
            XCTAssertTrue(f.bridge.attempts[1].receipts.isEmpty)
            XCTAssertEqual(f.session.chainRenderCountForVerification, 1)
            XCTAssertEqual(Set(f.bridge.imageIDs).count, 1)
        }
    }

    func testExplicitAbandonReleasesCheckpointBeforeResumeAndStaleTransactionCannotControlSuccessor() async throws {
        try await withSession(outputs: [.pin, .quickSavePNG]) { f in
            f.bridge.cancelFirstSave = true
            XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            let old = try XCTUnwrap(f.session.chainTransaction)
            let oldMenu = try XCTUnwrap(f.toolbar().moreButton.menu)
            let oldCommands = oldMenu.items.filter {
                ["scroll.live.imageChain.continue", "scroll.live.imageChain.replace", "scroll.live.imageChain.abandon"]
                    .contains($0.identifier?.rawValue ?? "")
            }
            XCTAssertEqual(oldCommands.count, 3)
            try f.dispatch("imageChain.abandon")
            let warning = try XCTUnwrap(f.session.chainChoiceAlertForVerification)
            XCTAssertTrue(warning.informativeText.contains("已保存的文件和贴图仍保留"))
            try f.dismissChoice(.alertSecondButtonReturn)
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            XCTAssertEqual(f.source.resumeCalls, 0)
            XCTAssertEqual(f.session.chainTransaction?.receipts, old.receipts)
            f.source.onResume = {
                XCTAssertNil(f.session.chainTransaction)
                XCTAssertNil(f.session.retainedChainCapture, "Release the frozen reservation before acquisition resumes")
            }
            try f.dispatch("imageChain.abandon")
            try f.dismissChoice(.alertFirstButtonReturn)
            try await self.until { f.source.resumeCalls == 1 && f.source.waiting && !f.session.snapshotForVerification.busy }
            f.source.onResume = nil
            XCTAssertNil(f.session.chainTransaction)
            XCTAssertEqual(f.bridge.pinIDs.count, 1)
            XCTAssertFalse(f.session.continueImageChain(transactionID: old.transactionID))
            XCTAssertFalse(f.session.abandonImageChain(transactionID: old.transactionID))
            f.bridge.cancelEverySave = true
            XCTAssertTrue(f.session.startImageChain(definition: old.definition))
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            let successor = try XCTUnwrap(f.session.chainTransaction)
            XCTAssertNotEqual(successor.transactionID, old.transactionID)
            XCTAssertNotEqual(successor.revisionID, old.revisionID)
            XCTAssertNotEqual(f.bridge.attempts[0].runID, f.bridge.attempts[1].runID)
            XCTAssertFalse(f.session.continueImageChain(transactionID: old.transactionID))
            XCTAssertFalse(f.session.abandonImageChain(transactionID: old.transactionID))
            XCTAssertFalse(f.session.startImageChain(definition: old.definition, replacingTransactionID: old.transactionID))
            XCTAssertEqual(f.session.chainTransaction?.transactionID, successor.transactionID)
            for item in oldCommands {
                XCTAssertEqual(item.representedObject as? String, old.transactionID.uuidString)
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            }
            XCTAssertEqual(f.session.chainTransaction?.transactionID, successor.transactionID)
            XCTAssertNil(f.session.chainChoiceAlertForVerification)
            XCTAssertEqual(f.bridge.attempts.count, 2)
            XCTAssertEqual(f.source.resumeCalls, 1)
            XCTAssertEqual(f.session.chainRenderCountForVerification, 2)
        }
    }

    func testActualPostDrainPixelCrossingRejectsSaveThenPinBeforeRenderAndAnyOutput() async throws {
        try await withSession(outputs: [.quickSavePNG, .pin], initialImage: { try self.largeTexture(origin: 0) }) { f in
            try await self.deliverLargeFrame(origin: 1_300, to: f)
            XCTAssertEqual(f.session.stateForVerification.width, 8_000)
            XCTAssertEqual(f.session.stateForVerification.height, 3_300)
            f.source.finalImageDuringPause = try self.largeTexture(origin: 2_001)
            XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
            try await self.until { !f.session.snapshotForVerification.busy }
            XCTAssertEqual(f.session.stateForVerification.height, 4_001)
            XCTAssertEqual(f.session.stateForVerification.acceptedObservations, 3)
            XCTAssertEqual(f.bridge.preflights.count, 1, "The real post-drain size gate precedes recipient preflight")
            XCTAssertEqual(f.source.pauseCalls, 1)
            XCTAssertEqual(f.session.chainRenderCountForVerification, 0)
            XCTAssertTrue(f.bridge.outputs.isEmpty); XCTAssertTrue(f.bridge.attempts.isEmpty)
            XCTAssertNil(f.session.retainedChainCapture)
            XCTAssertTrue(f.session.snapshotForVerification.status.contains("3200 万像素"))
            XCTAssertFalse(f.session.startImageChain(definition: f.bridge.definitions[0]),
                "The now-known above-limit draft must refuse before another source drain")
            XCTAssertEqual(f.source.pauseCalls, 1); XCTAssertEqual(f.session.chainRenderCountForVerification, 0)
            XCTAssertTrue(f.bridge.savedURLs.isEmpty); XCTAssertTrue(f.bridge.pinIDs.isEmpty)
        }
    }

    func testActualExactly32MillionPixelsPassesPostDrainAndRenderedImageChecksOnce() async throws {
        try await withSession(outputs: [.pin], initialImage: { try self.largeTexture(origin: 0) }) { f in
            try await self.deliverLargeFrame(origin: 1_300, to: f)
            f.source.finalImageDuringPause = try self.largeTexture(origin: 2_000)
            XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.bridge.preflights.map(\.width), [8_000, 8_000, 8_000])
            XCTAssertEqual(f.bridge.preflights.map(\.height), [3_300, 4_000, 4_000])
            XCTAssertEqual(f.bridge.outputs, [.pin]); XCTAssertEqual(f.bridge.pinIDs.count, 1)
            XCTAssertEqual(f.session.chainRenderCountForVerification, 1)
            XCTAssertEqual(f.bridge.attempts.count, 1); XCTAssertEqual(f.bridge.acquisitions, 0)
            XCTAssertEqual(f.closes, 1)
        }
    }

    func testPreflightRefusalAtEachPreparationBoundaryDispatchesNoOutputs() async throws {
        for refusedCall in 1...3 {
            try await withSession(outputs: [.quickSavePNG, .pin]) { f in
                f.bridge.refusePreflightCall = refusedCall
                let accepted = f.session.startImageChain(definition: f.bridge.definitions[0])
                XCTAssertEqual(accepted, refusedCall != 1)
                try await self.until { !f.session.snapshotForVerification.busy }
                XCTAssertEqual(f.bridge.preflights.count, refusedCall)
                XCTAssertTrue(f.bridge.outputs.isEmpty); XCTAssertTrue(f.bridge.attempts.isEmpty)
                XCTAssertEqual(f.bridge.acquisitions, 0)
                XCTAssertEqual(f.source.pauseCalls, refusedCall == 1 ? 0 : 1)
                XCTAssertEqual(f.session.chainRenderCountForVerification, refusedCall == 3 ? 1 : 0)
                XCTAssertFalse(f.session.isClosedForVerification)
                XCTAssertEqual(f.session.snapshotForVerification.statusKind, .error)
                XCTAssertTrue(f.bridge.preflights.allSatisfy { $0.committedCount == 0 })
                if refusedCall == 3 {
                    let rendered = try XCTUnwrap(f.session.retainedChainCapture?.image)
                    XCTAssertEqual(f.bridge.preflights.last?.width, rendered.width)
                    XCTAssertEqual(f.bridge.preflights.last?.height, rendered.height)
                }
            }
        }
    }

    func testContinuationPreflightChecksOnlyUncommittedOutputsAfterPinAlreadyCommitted() async throws {
        try await withSession(outputs: [.pin, .quickSavePNG]) { f in
            f.bridge.cancelFirstSave = true
            XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
            try await self.until { f.session.snapshotForVerification.canContinueImageChain }
            let before = f.bridge.preflights.count
            f.bridge.pinUnavailable = true
            try f.dispatch("imageChain.continue")
            try await self.until { f.session.isClosedForVerification }
            XCTAssertGreaterThan(f.bridge.preflights.count, before)
            for check in f.bridge.preflights.dropFirst(before) {
                XCTAssertEqual(check.committedCount, 1)
                XCTAssertEqual(Array(check.definition.outputs.dropFirst(check.committedCount)), [.quickSavePNG])
            }
            XCTAssertEqual(f.bridge.pinIDs.count, 1); XCTAssertEqual(f.bridge.savedURLs.count, 1)
        }
    }

    func testFullCloseWaitsForHeldPreparationAndLateCompletionCannotRenderOrOutput() async throws {
        try await withSession(outputs: [.copy]) { f in
            f.source.holdPause = true
            XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
            try await self.until { f.source.pausePending }
            f.session.cancel(); f.session.cancel()
            XCTAssertFalse(f.session.isClosedForVerification)
            XCTAssertEqual(f.closes, 0); XCTAssertNil(f.session.controlsForVerification)
            XCTAssertFalse(f.session.startImageChain(definition: f.bridge.definitions[0]))
            XCTAssertFalse(f.session.continueImageChain(transactionID: UUID()))
            f.source.releasePause()
            try await self.until { f.session.isClosedForVerification }
            XCTAssertEqual(f.closes, 1); XCTAssertEqual(f.session.chainRenderCountForVerification, 0)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertTrue(f.bridge.outputs.isEmpty)
            f.session.show(); f.source.releasePause()
            XCTAssertNil(f.session.controlsForVerification); XCTAssertEqual(f.closes, 1)
        }
    }

    func testFullCloseAndRunnerCancelAwaitOneOwnedSaveDrainBeforeReleasingProviderAndClosingOnce() async throws {
        let counter = CaptureTestProviderCounter()
        try await withSession(outputs: [.quickSavePNG, .copy], providerCounter: counter) { f in
            f.bridge.holdSave = true
            XCTAssertTrue(f.session.startImageChain(definition: f.bridge.definitions[0]))
            try await self.until { f.bridge.savePending }
            let runner = try XCTUnwrap(f.bridge.activeRunner)
            XCTAssertEqual(counter.liveBytes, 8 * 8 * 4)
            XCTAssertEqual(f.session.retainedChainCapture?.retainedBytes, 8 * 8 * 4)
            XCTAssertEqual(runner.retainedBytes, 8 * 8 * 4)
            XCTAssertTrue(runner.capture?.image === f.session.retainedChainCapture?.image)
            f.session.cancel(); _ = runner.cancel(); f.session.cancel()
            XCTAssertFalse(f.session.isClosedForVerification); XCTAssertEqual(f.closes, 0)
            XCTAssertEqual(f.bridge.saveCancels, 1)
            XCTAssertEqual(counter.liveBytes, 8 * 8 * 4); XCTAssertEqual(counter.deallocations, 0)
            XCTAssertFalse(f.session.startImageChain(definition: f.bridge.definitions[0]))
            f.bridge.completeSave(.cancelled)
            try await self.until { f.session.isClosedForVerification && counter.liveBytes == 0 }
            XCTAssertEqual(f.closes, 1); XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1)
            XCTAssertNil(f.session.retainedChainCapture); XCTAssertNil(f.bridge.activeRunner)
            XCTAssertEqual(f.bridge.outputs, [.quickSavePNG])
            XCTAssertEqual(f.bridge.terminalSnapshots.count, 1)
            XCTAssertEqual(f.bridge.terminalSnapshots[0].status, .cancelled)
            XCTAssertTrue(f.bridge.terminalSnapshots[0].receipts.isEmpty)
            f.bridge.completeSave(.cancelled)
            XCTAssertEqual(f.closes, 1)
        }
    }

    func testCancellationAtFinalCommitFinishesOwnerWithoutOfferingReplayForEveryOutputType() async throws {
        for output in [CaptureChainOutput.quickSavePNG, .copy, .pin] {
            try await withSession(outputs: [output]) { f in
                f.bridge.cancelOnOutput = output
                let definition = f.bridge.definitions[0]
                XCTAssertTrue(f.session.startImageChain(definition: definition))
                try await self.until { f.session.isClosedForVerification }
                XCTAssertEqual(f.bridge.terminalSnapshots.last?.status, .cancelled)
                XCTAssertEqual(f.bridge.terminalSnapshots.last?.receipts.map(\.output), [output])
                XCTAssertEqual(f.closes, 1); XCTAssertNil(f.session.chainTransaction)
                XCTAssertFalse(f.session.startImageChain(definition: definition))
                XCTAssertFalse(f.session.continueImageChain(transactionID: f.bridge.attempts[0].transactionID))
                XCTAssertEqual(f.bridge.outputs, [output])
                XCTAssertEqual(f.session.chainRenderCountForVerification, 1)
            }
        }
    }

    func testUnconfirmedStopAfterCompleteChainRemainsTerminalAndStaleMoreCannotReplay() async throws {
        try await withSession(outputs: [.copy]) { f in
            f.source.refusePause = true
            let stale = f.session.snapshotForVerification, definition = f.bridge.definitions[0]
            XCTAssertTrue(f.session.startImageChain(definition: definition))
            try await self.until { !f.session.snapshotForVerification.busy && f.session.snapshotForVerification.statusKind == .warning }
            XCTAssertFalse(f.session.isClosedForVerification)
            XCTAssertTrue(f.session.snapshotForVerification.status.contains("采集停止未确认"))
            XCTAssertNil(f.session.chainTransaction); XCTAssertNil(f.session.retainedChainCapture)
            let controls = try XCTUnwrap(f.session.controlsForVerification)
            controls.update(snapshot: stale)
            try f.dispatch("imageChain", requireEnabled: false)
            try f.dispatch("help")
            f.session.show()
            XCTAssertFalse(f.session.startImageChain(definition: definition))
            XCTAssertEqual(f.bridge.outputs, [.copy]); XCTAssertEqual(f.bridge.attempts.count, 1)
            XCTAssertFalse(f.session.snapshotForVerification.canApplyImageChain)
            XCTAssertFalse(f.session.snapshotForVerification.canContinueImageChain)
            self.assertCheckpointBlocksMutation(f.session.snapshotForVerification)
            XCTAssertNil(f.session.chainChoiceAlertForVerification)
        }
    }

    func testOwnedChoiceSelectionAndEscapeDoNotRunAndRetiredSheetCannotAffectReopenedSession() async throws {
        var retiredChoice: LiveScrollChainChoiceController?
        try await withSession(outputs: [.copy]) { f in
            let second = try CaptureChainDefinition(name: "Explicit second selection", source: .region, outputs: [.pin])
            f.bridge.definitions.append(second)
            try f.dispatch("imageChain")
            let first = try XCTUnwrap(f.session.chainChoiceAlertForVerification)
            let picker = try XCTUnwrap(first.accessoryView as? NSPopUpButton)
            XCTAssertEqual(picker.indexOfSelectedItem, 0)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertTrue(f.bridge.outputs.isEmpty)
            picker.selectItem(at: 1)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
            XCTAssertEqual(picker.indexOfSelectedItem, 1)
            XCTAssertTrue(f.bridge.attempts.isEmpty, "Changing the explicit selection does not run it")
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: first.window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertTrue(first.window.performKeyEquivalent(with: escape))
            try await self.until { f.session.chainChoiceAlertForVerification == nil && f.session.snapshotForVerification.canApplyImageChain }
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertNil(f.session.chainTransaction)
            XCTAssertEqual(f.source.pauseCalls, 0)

            try f.dispatch("imageChain")
            retiredChoice = try XCTUnwrap(f.session.chainChoiceAlertForVerification)
            f.session.cancel()
            try await self.until {
                f.session.isClosedForVerification && retiredChoice?.window.sheetParent == nil
                    && retiredChoice?.window.isVisible != true
            }
            XCTAssertNil(f.session.chainChoiceAlertForVerification)
            XCTAssertNil(retiredChoice?.window.sheetParent)
            XCTAssertFalse(retiredChoice?.window.isVisible ?? true)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertEqual(f.closes, 1)
        }
        try await withSession(outputs: [.copy]) { f in
            try f.dispatch("imageChain")
            let fresh = try XCTUnwrap(f.session.chainChoiceAlertForVerification)
            let old = try XCTUnwrap(retiredChoice)
            let oldReturn = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: old.window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            _ = old.window.performKeyEquivalent(with: oldReturn)
            if let button = old.buttons.first, let action = button.action {
                _ = NSApp.sendAction(action, to: button.target, from: button)
            }
            old.cancel()
            XCTAssertTrue(f.session.chainChoiceAlertForVerification === fresh)
            XCTAssertTrue(fresh.window.isVisible)
            XCTAssertTrue(f.bridge.attempts.isEmpty); XCTAssertTrue(f.bridge.outputs.isEmpty)
            XCTAssertNil(f.session.chainTransaction); XCTAssertEqual(f.source.pauseCalls, 0)
            fresh.cancel()
            try await self.until { f.session.chainChoiceAlertForVerification == nil }
            XCTAssertTrue(f.session.snapshotForVerification.canApplyImageChain)
        }
    }

    private func withSession(outputs: [CaptureChainOutput], providerCounter: CaptureTestProviderCounter? = nil,
                             initialImage: (() throws -> CGImage)? = nil,
                             _ body: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for scroll controls") }
        let root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-ScrollChain-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try Fixture(root: root, screen: screen, outputs: outputs)
        do {
            try await f.session.startForVerification(source: f.source, screen: screen)
            try await until { f.source.waiting }
            try autoreleasepool {
                let image = try initialImage?() ?? providerCounter.map { try CaptureTestProviderCounter.image(width: 8, height: 8, counter: $0) }
                    ?? SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8)
                if image.width * image.height <= 1_024 * 1_024 {
                    f.expectedPixels = try SaveWorkflowUIPreviewFixture.pixels(image)
                }
                f.source.offer(image)
            }
            try await until { f.session.snapshotForVerification.canApplyImageChain && f.source.waiting }
            try await body(f)
        } catch {
            f.source.onResume = nil
            f.source.releasePause(); f.bridge.completeSave(.cancelled)
            await f.session.closeForVerification()
            throw error
        }
        f.source.onResume = nil
        f.source.releasePause(); f.bridge.completeSave(.cancelled)
        await f.session.closeForVerification()
        XCTAssertTrue(f.session.isClosedForVerification)
        XCTAssertEqual(f.closes, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.spool.path).isEmpty)
    }

    private func assertCheckpointBlocksMutation(_ snapshot: LiveScrollCaptureSnapshot,
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(snapshot.canFinish, file: file, line: line); XCTAssertFalse(snapshot.canCopy, file: file, line: line)
        XCTAssertFalse(snapshot.canQuickSave, file: file, line: line); XCTAssertFalse(snapshot.canPin, file: file, line: line)
        XCTAssertFalse(snapshot.canPause, file: file, line: line); XCTAssertFalse(snapshot.canMoveRegion, file: file, line: line)
        XCTAssertFalse(snapshot.canAutoScroll, file: file, line: line); XCTAssertFalse(snapshot.canChangeAxis, file: file, line: line)
        XCTAssertFalse(snapshot.canImport, file: file, line: line)
    }
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "Scroll chain did not reach its explicit owner/output barrier")
    }
    private func deliverLargeFrame(origin: Int, to fixture: Fixture) async throws {
        try await until { fixture.source.waiting }
        let previous = fixture.session.sampledFramesForVerification
        fixture.source.offer(try largeTexture(origin: origin))
        try await until { fixture.session.sampledFramesForVerification > previous && fixture.source.waiting }
        XCTAssertTrue(fixture.session.stateForVerification.matched)
    }

    /// One-bit source providers keep each 16M-pixel input at 2MB. Matching and
    /// assembly still process the real dimensions and real pixels; no dimensions,
    /// limits or render return values are substituted for the product code.
    private func largeTexture(origin: Int) throws -> CGImage {
        let width = 8_000, height = 2_000, rowBytes = 1_000
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
    private enum Failure: Error { case output, unavailable, stop }

    @MainActor private final class Fixture {
        let spool: URL, source: Source, bridge: Bridge
        var session: LiveScrollSessionController!
        var expectedPixels = Data(), ordinaryOutputs = 0, closes = 0
        init(root: URL, screen: NSScreen, outputs: [CaptureChainOutput]) throws {
            spool = root.appendingPathComponent("spool")
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false)
            source = Source(screen: screen)
            bridge = Bridge(root: root, definition: try CaptureChainDefinition(name: "Existing long screenshot",
                source: .preset(UUID()), outputs: outputs))
            session = LiveScrollSessionController(onComplete: { [weak self] _ in self?.ordinaryOutputs += 1 },
                onImport: { [weak self] in self?.ordinaryOutputs += 1 },
                onCopy: { [weak self] _ in self?.ordinaryOutputs += 1 },
                onPin: { [weak self] _ in self?.ordinaryOutputs += 1 }, resourceStorageParent: spool,
                automaticScrollPermission: { false },
                automaticScrollInput: { _ in XCTFail("No OS input is permitted in an output test") },
                chainDependencies: .init(definitions: { [bridge] in bridge.definitions },
                    run: { [bridge] transaction, id in try await bridge.run(transaction, id: id) },
                    cancel: { [bridge] id in bridge.cancel(id) },
                    preflight: { [bridge] definition, committed, width, height in
                        try bridge.preflight(definition, committed: committed, width: width, height: height)
                    }))
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
        func dismissChoice(_ response: NSApplication.ModalResponse) throws {
            let alert = try XCTUnwrap(session.chainChoiceAlertForVerification)
            let parent = try XCTUnwrap(alert.window.sheetParent)
            parent.endSheet(alert.window, returnCode: response)
        }
    }

    @MainActor private final class Bridge {
        struct Attempt {
            let runID: UUID, transactionID: UUID, revisionID: UUID
            let definition: CaptureChainDefinition, receipts: [CaptureChainReceipt]
        }
        struct Preflight { let definition: CaptureChainDefinition; let committedCount: Int, width: Int, height: Int }
        let root: URL
        var definitions: [CaptureChainDefinition]
        var activeRunner: CaptureChainRunner?
        var attempts: [Attempt] = [], terminalSnapshots: [CaptureChainSnapshot] = []
        var outputs: [CaptureChainOutput] = [], imageIDs: [ObjectIdentifier] = [], savedURLs: [URL] = [], pinIDs: [UUID] = []
        var preflights: [Preflight] = [], acquisitions = 0, saveCancels = 0, saves = 0
        var failCopy = false, cancelFirstSave = false, cancelEverySave = false, holdSave = false, pinUnavailable = false
        var cancelOnOutput: CaptureChainOutput?, refusePreflightCall: Int?
        private var expectedImage: ObjectIdentifier?
        private var saveContinuation: CheckedContinuation<SaveWorkflowTerminalOutcome, Never>?
        var savePending: Bool { saveContinuation != nil }
        init(root: URL, definition: CaptureChainDefinition) { self.root = root; definitions = [definition] }
        func preflight(_ definition: CaptureChainDefinition, committed: Int, width: Int, height: Int) throws {
            preflights.append(.init(definition: definition, committedCount: committed, width: width, height: height))
            if preflights.count == refusePreflightCall { throw Failure.unavailable }
            if pinUnavailable && definition.outputs.dropFirst(committed).contains(.pin) { throw Failure.unavailable }
        }
        func run(_ transaction: LiveScrollChainTransaction, id: UUID) async throws -> CaptureChainSnapshot {
            XCTAssertNil(activeRunner)
            attempts.append(.init(runID: id, transactionID: transaction.transactionID, revisionID: transaction.revisionID,
                definition: transaction.definition, receipts: transaction.receipts))
            expectedImage = ObjectIdentifier(transaction.capture.image)
            let runner = try CaptureChainRunner(definition: transaction.definition, preparedCapture: transaction.capture,
                receipts: transaction.receipts, dependencies: .init(capture: {
                    self.acquisitions += 1; throw Failure.unavailable
                }, savePNG: { image in await self.save(image) }, copy: { image in
                    self.observe(image, output: .copy)
                    if self.failCopy { throw Failure.output }
                    if self.cancelOnOutput == .copy { _ = self.activeRunner?.cancel() }
                }, pin: { image in
                    self.observe(image, output: .pin)
                    let pinID = UUID(); self.pinIDs.append(pinID)
                    if self.cancelOnOutput == .pin { _ = self.activeRunner?.cancel() }
                    return pinID
                }, cancelSave: { self.saveCancels += 1 }), id: id)
            activeRunner = runner
            return await withCheckedContinuation { continuation in
                runner.onTerminal = { [weak self] snapshot in
                    guard let self, self.activeRunner?.id == snapshot.runID else { return }
                    self.terminalSnapshots.append(snapshot); self.activeRunner = nil
                    continuation.resume(returning: snapshot)
                }
                XCTAssertTrue(runner.start())
            }
        }
        func cancel(_ id: UUID) { if activeRunner?.id == id { _ = activeRunner?.cancel() } }
        private func observe(_ image: CGImage, output: CaptureChainOutput) {
            XCTAssertEqual(ObjectIdentifier(image), expectedImage)
            outputs.append(output); imageIDs.append(ObjectIdentifier(image))
        }
        private func save(_ image: CGImage) async -> SaveWorkflowTerminalOutcome {
            observe(image, output: .quickSavePNG); saves += 1
            if holdSave {
                return await withCheckedContinuation { continuation in
                    precondition(self.saveContinuation == nil); self.saveContinuation = continuation
                }
            }
            if cancelEverySave || (cancelFirstSave && saves == 1) { return .cancelled }
            do {
                let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init())
                let summary = SaveWorkflowSummary(try SaveWorkflowService.publish(artifact,
                    to: root.appendingPathComponent(UUID().uuidString + ".png")))
                savedURLs.append(summary.savedURL)
                if cancelOnOutput == .quickSavePNG { _ = activeRunner?.cancel() }
                return .committed(summary)
            } catch { return .failed(.operation(error)) }
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
        var pausePending: Bool { pauseContinuation != nil }
        var pauseCalls = 0, resumeCalls = 0, moveCalls = 0, holdPause = false, refusePause = false
        var onResume: (() -> Void)?
        var finalImageDuringPause: CGImage?
        private var generation: UInt64 = 0, sequence: UInt64 = 0, running = false
        private var reader: CheckedContinuation<LiveScrollScreenSource.Frame?, Error>?
        private var pauseContinuation: CheckedContinuation<Void, Never>?
        init(screen: NSScreen) { displayBounds = CGDisplayBounds(screen.displayID ?? 0) }
        func start() async throws { generation &+= 1; running = true }
        func resume() async throws { onResume?(); resumeCalls += 1; try await start() }
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
            if refusePause { throw Failure.stop }
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
