import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class ManualScrollIntegrationTests: XCTestCase {
    func testInstalledNativeContinuousCaptureFixture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Manual-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await ScrollManualCaptureSmokeFixture.verify(evidenceDirectory: directory, includeLargeFrames: false)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual((report["axes"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(report["lateCaptureClose"] as? Bool, true)
        XCTAssertEqual((report["lateWritePauseStopClose"] as? [[String: Any]])?.count, 3)
    }

    func testPausedRegionPolicyPreservesDisplaySizeAndPixels() throws {
        let original = CGRect(x: 10, y: 20, width: 100, height: 140)
        let moved = try ManualScrollScreenDriver.movedRegion(original.offsetBy(dx: 25.2, dy: 40.1),
            original: original, screenSize: CGSize(width: 800, height: 600),
            displayPixels: CGSize(width: 1600, height: 1200), expectedPixels: CGSize(width: 200, height: 280))
        XCTAssertEqual(moved, CGRect(x: 35, y: 60, width: 100, height: 140))
        XCTAssertThrowsError(try ManualScrollScreenDriver.movedRegion(CGRect(x: 10, y: 20, width: 101, height: 140),
            original: original, screenSize: CGSize(width: 800, height: 600), displayPixels: nil, expectedPixels: nil))
        XCTAssertThrowsError(try ManualScrollScreenDriver.movedRegion(original.offsetBy(dx: 800, dy: 0),
            original: original, screenSize: CGSize(width: 800, height: 600), displayPixels: nil, expectedPixels: nil))
    }

    func testPausedMoveRequiresSameTargetIdentityAndExplicitlyAcceptsItsNewBounds() throws {
        let display = CGRect(x: -800, y: -100, width: 800, height: 600)
        let region = CGRect(x: 20, y: 20, width: 100, height: 140)
        let old = ManualScrollScreenDriver.Target(pid: 42, windowID: 17, bounds: display)
        let changed = ManualScrollScreenDriver.Target(pid: 42, windowID: 17, bounds: display.insetBy(dx: 10, dy: 10))
        XCTAssertThrowsError(try ManualScrollScreenDriver.checkedTarget(changed, locked: old, region: region,
            displayBounds: display, allowMovedWindow: false))
        XCTAssertEqual(try ManualScrollScreenDriver.checkedTarget(changed, locked: old, region: region,
            displayBounds: display, allowMovedWindow: true), changed)
        let other = ManualScrollScreenDriver.Target(pid: 42, windowID: 18, bounds: display)
        XCTAssertThrowsError(try ManualScrollScreenDriver.checkedTarget(other, locked: old, region: region,
            displayBounds: display, allowMovedWindow: true))
        let covered = ManualScrollScreenDriver.Target(pid: 99, windowID: 10, bounds: CGRect(x: -780, y: -80, width: 20, height: 20))
        XCTAssertThrowsError(try ManualScrollScreenDriver.checkedTarget(covered, locked: old, region: region,
            displayBounds: display, allowMovedWindow: false))
    }

    func testColorConflictsRemainRecoverableAndRetryPreservesAcceptedBytes() async throws {
        for axis in ScrollAxis.allCases {
            for revisit in [false, true] {
                let controller = ScrollCaptureController { _ in }
                defer { controller.close() }
                try await controller.setAutoCropForVerification(false)
                for offset in [100, 147, 190] {
                    _ = try await controller.acceptForVerification(ScrollSequenceSmokeFixture.image(axis: axis, offset: offset), axis: axis)
                }
                let urls = controller.sourceURLsForVerification
                let originalBytes = try urls.map { try Data(contentsOf: $0) }
                let candidateOffset = revisit ? 147 : 190
                let candidate = try ScrollSequenceSmokeFixture.image(axis: axis, offset: candidateOffset, alteration: "stationaryColor")
                // Establish that this input reaches the native full-color conflict
                // branch, rather than passing only through a core alignment refusal.
                do {
                    _ = try await controller.acceptForVerification(candidate, axis: axis)
                    XCTFail("Color conflict was accepted")
                } catch ScrollSequenceImageError.changedSource { }
                catch { XCTFail("Expected full-color conflict, got \(error)") }
                XCTAssertEqual(controller.sourceURLsForVerification, urls)
                var recover = false
                var config = ManualScrollConfiguration()
                config.countdownSeconds = 0; config.sampleInterval = 0.05
                let coordinator = try controller.startManualForVerification(axis: axis,
                    region: CGRect(x: 0, y: 0, width: axis == .vertical ? 96 : 140, height: axis == .vertical ? 140 : 96),
                    screenSize: CGSize(width: 800, height: 600), configuration: config,
                    provider: {
                        if recover { return try ScrollSequenceSmokeFixture.image(axis: axis, offset: 230) }
                        return candidate
                    })
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while !coordinator.canResume && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard case .recoverable = coordinator.state else {
                    XCTFail("Color conflict should keep Retry/Move controls: \(coordinator.state)")
                    coordinator.cancel(); continue
                }
                XCTAssertEqual(controller.sourceURLsForVerification, urls)
                XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)
                let controls = allViews(controller.manualControlsForVerification?.window?.contentView)
                let retry = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "scroll.manual.pause" } as? NSButton)
                let move = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "scroll.manual.move" } as? NSButton)
                XCTAssertEqual(retry.title, "重试"); XCTAssertTrue(retry.isEnabled); XCTAssertTrue(move.isEnabled)
                recover = true; retry.performClick(nil)
                let resumedDeadline = ProcessInfo.processInfo.systemUptime + 15
                while controller.sourceURLsForVerification.count != 4 && ProcessInfo.processInfo.systemUptime < resumedDeadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                coordinator.stop()
                XCTAssertEqual(controller.sourceURLsForVerification.count, 4)
                XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)
                let output = try controller.currentOutputForVerification()
                let expected = try ScrollSequenceSmokeFixture.image(axis: axis, offset: 100, length: 270)
                XCTAssertEqual(try ScrollSequenceSmokeFixture.pixels(output), try ScrollSequenceSmokeFixture.pixels(expected))
            }
        }
    }

    private func allViews(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { allViews($0) }
    }

    func testDriverDoesNotCommitImageReturningAfterCancellation() async throws {
        let gate = ImageGate()
        var accepts = 0
        let driver = ManualScrollScreenDriver(region: CGRect(x: 0, y: 0, width: 96, height: 140),
            screenSize: CGSize(width: 800, height: 600), provider: {
                await gate.hold()
                return try ScrollSequenceSmokeFixture.image(axis: .vertical, offset: 100)
            }, accept: { _ in accepts += 1; return .accepted(totalFrames: accepts) })
        let task = Task { try await driver.capture() }
        for _ in 0..<100 where !gate.waiting { await Task.yield() }
        XCTAssertTrue(gate.waiting)
        task.cancel(); driver.invalidate(); gate.release()
        do { _ = try await task.value; XCTFail("Canceled capture installed a sample") }
        catch is CancellationError { }
        XCTAssertNil(driver.pendingImage)
        XCTAssertEqual(accepts, 0)
    }

    @MainActor private final class ImageGate {
        var waiting = false
        var continuation: CheckedContinuation<Void, Never>?
        func hold() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
}
