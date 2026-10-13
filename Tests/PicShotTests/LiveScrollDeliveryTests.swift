import XCTest
import AppKit
@testable import PicShot

/// Owned input, native compact controls and an isolated pasteboard only.
/// This is delivery/lifecycle evidence, not ScreenCaptureKit or TCC evidence.
@MainActor
final class LiveScrollDeliveryTests: XCTestCase {
    func testFinishWithUnconfirmedStopDeliversOnceAndRemainsTerminalAfterStaleActionsAndShow() async throws {
        try await verifyTerminalDelivery(copy: false)
    }

    func testCopyWithUnconfirmedStopOwnsOnlyOneIsolatedClipboardDelivery() async throws {
        try await verifyTerminalDelivery(copy: true)
    }

    private func verifyTerminalDelivery(copy: Bool) async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let source = FinishSource(image: try image(), screen: screen)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        var finishes = 0, copies = 0
        let controller = LiveScrollSessionController(onComplete: { _ in finishes += 1 }, onImport: {}, onCopy: { image in
            copies += 1
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            XCTAssertNotNil(data)
            board.clearContents()
            if let data { XCTAssertTrue(board.setData(data, forType: .png)) }
        })
        do {
            try await controller.startForVerification(source: source, screen: screen)
            try await wait { controller.snapshotForVerification.canFinish }
            let controls = try XCTUnwrap(controller.controlsForVerification)
            let toolbar = try XCTUnwrap(controls.toolbarWindow?.contentView as? LiveScrollToolbarView)
            let beforeDelivery = controller.snapshotForVerification
            try PortableSettingsUIPreviewFixture.click(copy ? toolbar.copyButton : toolbar.finishButton)
            try await wait { !controller.snapshotForVerification.busy && controller.snapshotForVerification.statusKind == .warning }
            let warning = controller.snapshotForVerification.status
            XCTAssertTrue(warning.contains(copy ? "长图已复制" : "长图已完成"))
            XCTAssertTrue(warning.contains("采集停止未确认"))
            XCTAssertFalse(controller.isClosedForVerification)
            assertTerminal(controller.snapshotForVerification)
            XCTAssertTrue(toolbar.cancelButton.isEnabled)
            XCTAssertEqual(finishes, copy ? 0 : 1); XCTAssertEqual(copies, copy ? 1 : 0)
            let clipboardChanges = board.changeCount

            // Replaying stale UI capabilities reaches the owner's action guards
            // through actual native mouse dispatch, rather than merely relying
            // on disabled buttons to suppress a second delivery.
            for _ in 0..<2 {
                for button in [toolbar.finishButton, toolbar.copyButton, toolbar.pauseButton] {
                    controls.update(snapshot: beforeDelivery)
                    try PortableSettingsUIPreviewFixture.click(button)
                    try await wait { !controller.snapshotForVerification.busy }
                }
                controller.show()
                assertTerminal(controller.snapshotForVerification)
                XCTAssertFalse(toolbar.finishButton.isEnabled); XCTAssertFalse(toolbar.copyButton.isEnabled)
                XCTAssertEqual(controller.snapshotForVerification.status, warning)
            }
            let help = try XCTUnwrap(controls.makeMoreMenu().items.first { $0.identifier?.rawValue == "scroll.live.help" })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(help.action), to: help.target, from: help))
            XCTAssertEqual(controller.snapshotForVerification.status, warning)
            XCTAssertEqual(finishes, copy ? 0 : 1); XCTAssertEqual(copies, copy ? 1 : 0)
            XCTAssertEqual(board.changeCount, clipboardChanges)
            XCTAssertEqual(source.resumeCalls, 0)
            XCTAssertEqual(source.pauseCalls, 1)
            try PortableSettingsUIPreviewFixture.click(toolbar.cancelButton)
            try await wait { controller.isClosedForVerification }
            controller.show()
            XCTAssertNil(controller.controlsForVerification)
            XCTAssertEqual(finishes, copy ? 0 : 1); XCTAssertEqual(copies, copy ? 1 : 0)
        } catch {
            await controller.closeForVerification()
            throw error
        }
    }

    func testFailedEditorDeliveryKeepsTheDraftAndNativeFinishCanRetry() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let source = FinishSource(image: try image(), screen: screen)
        var attempts = 0, delivered: CGImage?, copies = 0
        let controller = LiveScrollSessionController(onComplete: { image in
            attempts += 1
            if attempts == 1 { throw Self.problem("Injected editor delivery failure") }
            delivered = image
        }, onImport: {}, onCopy: { _ in copies += 1 })
        do {
            try await controller.startForVerification(source: source, screen: screen)
            try await wait { controller.snapshotForVerification.canFinish }
            let toolbar = try XCTUnwrap(controller.controlsForVerification?.toolbarWindow?.contentView as? LiveScrollToolbarView)
            let initial = controller.stateForVerification
            try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
            try await wait { attempts == 1 && !controller.snapshotForVerification.busy }
            XCTAssertNil(delivered); XCTAssertEqual(copies, 0)
            XCTAssertEqual(controller.snapshotForVerification.statusKind, .error)
            XCTAssertTrue(controller.snapshotForVerification.canFinish); XCTAssertTrue(controller.snapshotForVerification.canCopy)
            XCTAssertEqual(controller.stateForVerification.width, initial.width)
            XCTAssertEqual(controller.stateForVerification.height, initial.height)
            XCTAssertEqual(controller.stateForVerification.acceptedObservations, initial.acceptedObservations)
            try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
            try await wait { attempts == 2 && !controller.snapshotForVerification.busy }
            XCTAssertNotNil(delivered); XCTAssertEqual(delivered?.width, source.image.width)
            XCTAssertEqual(delivered?.height, source.image.height)
            XCTAssertTrue(delivered === source.image, "Retry must deliver the same retained first viewport")
            assertTerminal(controller.snapshotForVerification)
            XCTAssertEqual(copies, 0)
            await controller.closeForVerification()
        } catch {
            await controller.closeForVerification()
            throw error
        }
    }

    func testCancelDuringFinishIgnoresLatePauseCompletionAndDoesNotDeliver() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let source = FinishSource(image: try image(), screen: screen)
        source.holdPause = true
        var finishes = 0, copies = 0, closes = 0
        let controller = LiveScrollSessionController(onComplete: { _ in finishes += 1 }, onImport: {}, onCopy: { _ in copies += 1 })
        controller.onClose = { closes += 1 }
        do {
            try await controller.startForVerification(source: source, screen: screen)
            try await wait { controller.snapshotForVerification.canFinish }
            let toolbar = try XCTUnwrap(controller.controlsForVerification?.toolbarWindow?.contentView as? LiveScrollToolbarView)
            try PortableSettingsUIPreviewFixture.click(toolbar.finishButton)
            try await wait { source.pausePending }
            try PortableSettingsUIPreviewFixture.click(toolbar.cancelButton)
            XCTAssertNil(controller.controlsForVerification)
            XCTAssertFalse(controller.isClosedForVerification)
            XCTAssertEqual(closes, 0)
            XCTAssertEqual(finishes, 0); XCTAssertEqual(copies, 0)
            source.releasePause()
            try await wait { source.pauseReturned && controller.isClosedForVerification }
            XCTAssertEqual(closes, 1)
            for _ in 0..<20 { await Task.yield() }
            controller.show()
            XCTAssertEqual(finishes, 0); XCTAssertEqual(copies, 0)
            XCTAssertNil(controller.controlsForVerification)
            XCTAssertEqual(closes, 1)
        } catch {
            source.releasePause()
            await controller.closeForVerification()
            throw error
        }
    }

    private func assertTerminal(_ snapshot: LiveScrollCaptureSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(snapshot.canFinish, file: file, line: line); XCTAssertFalse(snapshot.canCopy, file: file, line: line)
        XCTAssertFalse(snapshot.canPause, file: file, line: line); XCTAssertFalse(snapshot.canMoveRegion, file: file, line: line)
        XCTAssertFalse(snapshot.canAutoScroll, file: file, line: line); XCTAssertFalse(snapshot.canChangeAxis, file: file, line: line)
        XCTAssertFalse(snapshot.canImport, file: file, line: line)
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw Self.problem("Delivery test condition timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 128, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.7, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 128))
        return try XCTUnwrap(context.makeImage())
    }

    private static func problem(_ text: String) -> NSError {
        NSError(domain: "LiveScrollDeliveryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    @MainActor
    private final class FinishSource: LiveScrollFrameSource {
        let region = CGRect(x: 80, y: 80, width: 320, height: 240)
        let displayBounds: CGRect
        let target: LiveScrollScreenSource.Target? = nil
        let image: CGImage
        var pauseCalls = 0, resumeCalls = 0, holdPause = false, pauseReturned = false
        var pausePending: Bool { pauseContinuation != nil }
        private var deliveredFrame = false, stopped = false
        private var frameContinuation: CheckedContinuation<LiveScrollScreenSource.Frame?, Error>?
        private var pauseContinuation: CheckedContinuation<Void, Never>?
        init(image: CGImage, screen: NSScreen) { self.image = image; displayBounds = CGDisplayBounds(screen.displayID ?? 0) }
        func start() async throws { }
        func validateTarget() throws { }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            if !deliveredFrame {
                deliveredFrame = true
                return .init(image: image, sequence: 1, generation: 1, timestamp: ProcessInfo.processInfo.systemUptime, region: region)
            }
            return try await withCheckedThrowingContinuation { frameContinuation = $0 }
        }
        func pauseAndDrain() async throws {
            pauseCalls += 1; drainFrame()
            if holdPause { await withCheckedContinuation { pauseContinuation = $0 } }
            pauseReturned = true
            throw LiveScrollDeliveryTests.problem("Injected unconfirmed stream stop")
        }
        func resume() async throws { resumeCalls += 1 }
        func stop() async throws { stopped = true; drainFrame() }
        func moveRegion(to proposed: CGRect) throws { }
        func releasePause() { let held = pauseContinuation; pauseContinuation = nil; held?.resume() }
        private func drainFrame() { let held = frameContinuation; frameContinuation = nil; held?.resume(throwing: CancellationError()) }
    }
}
