import XCTest
import Foundation
import AppKit
import Darwin
@testable import PicShot
import PicShotFormulaRenderCore

final class FormulaRenderCancellationTests: XCTestCase {
    func testCancellationBeforeProcessLaunchStartsNothing() {
        let control = FormulaRenderProcessControl(); control.cancel()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        XCTAssertThrowsError(try control.start(process)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(process.isRunning)
    }
    func testCancellationTerminatesOneRunningHelperAndIsIdempotent() throws {
        let control = FormulaRenderProcessControl()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        try control.start(process); XCTAssertTrue(process.isRunning)
        control.cancel(); control.cancel()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            control.stop(); Thread.sleep(forTimeInterval: 0.02)
        }
        let leaked = process.isRunning
        if leaked { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        XCTAssertFalse(leaked, "Cancellation must not leave an idle helper")
    }
    @MainActor
    func testEditDiscardsOldCompletionAndDisablesExport() async throws {
        let model = FormulaRenderModel(latex: "x") { request in
            try? await Task.sleep(nanoseconds: 40_000_000) // Deliberately simulate a renderer returning after cancellation.
            return Self.fixture(request.latex)
        }
        model.render(); XCTAssertTrue(model.working)
        model.latex = "y"
        XCTAssertFalse(model.canExport); XCTAssertNil(model.result)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(model.result); XCTAssertFalse(model.working); XCTAssertTrue(model.status.contains("修改"))
    }
    @MainActor
    func testCloseCannotPublishLateResultOrRestartRendering() async throws {
        let model = FormulaRenderModel(latex: "x") { request in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return Self.fixture(request.latex)
        }
        model.render(); model.close(); model.render()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertNil(model.result); XCTAssertNil(model.image); XCTAssertFalse(model.working)
    }
    @MainActor
    func testOptionsInvalidateRenderedFormatsTogether() async throws {
        let model = FormulaRenderModel(latex: "x") { request in Self.validPreviewFixture(request.latex) }
        model.render()
        for _ in 0..<50 { if !model.working { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(model.canExport); XCTAssertNotNil(model.image)
        model.fontSize = 48; XCTAssertFalse(model.canExport); XCTAssertNil(model.image); XCTAssertNil(model.result)
        model.scale = 3; XCTAssertFalse(model.canExport)
        model.transparent = true; XCTAssertFalse(model.canExport)
        model.latex = String(repeating: "x", count: FormulaRenderLimits.latexBytes + 1)
        XCTAssertFalse(model.canRender)
    }
    @MainActor
    func testRapidReplacementWaitsForCancelledRenderBeforeStartingAnother() async throws {
        let tracker = FormulaRenderTestConcurrency()
        let model = FormulaRenderModel(latex: "x") { request in
            await tracker.begin()
            // Simulate a helper needing time to unwind even after cancellation.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
            }
            await tracker.end()
            return Self.validPreviewFixture(request.latex)
        }
        model.render()
        for _ in 0..<50 { if await tracker.started > 0 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        model.latex = "y"; model.render()
        model.latex = "z"; model.render()
        for _ in 0..<100 { if !model.working { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(model.result?.latex, "z")
        let maximum = await tracker.maximum
        XCTAssertEqual(maximum, 1)
    }
    @MainActor
    func testRenderWindowCloseCallbackIsOneShot() {
        _ = NSApplication.shared
        let controller = FormulaRenderController(latex: "")
        var callbacks = 0
        controller.onClose = { callbacks += 1 }
        let notification = Notification(name: NSWindow.willCloseNotification, object: controller.window)
        controller.windowWillClose(notification); controller.windowWillClose(notification)
        XCTAssertEqual(callbacks, 1)
        controller.close()
    }
    @MainActor
    func testVerificationWaitUsesNormalInFlightRenderWithoutStartingAnother() async throws {
        let tracker = FormulaRenderTestConcurrency()
        let model = FormulaRenderModel(latex: "x") { request in
            await tracker.begin()
            try await Task.sleep(nanoseconds: 10_000_000)
            await tracker.end()
            return Self.validPreviewFixture(request.latex)
        }
        model.render()
        let result = try await model.renderAndWait()
        XCTAssertEqual(result.latex, "x"); XCTAssertTrue(model.canExport); XCTAssertNotNil(model.image)
        _ = try await model.renderAndWait()
        let started = await tracker.started
        XCTAssertEqual(started, 1)
    }
    private static func fixture(_ latex: String) -> FormulaRenderResult {
        FormulaRenderResult(latex: latex, svg: "<svg />", mathML: "<math />", png: Data(), pdf: Data(),
                            width: 1, height: 1, pointWidth: 1, pointHeight: 1)
    }
    private static func validPreviewFixture(_ latex: String) -> FormulaRenderResult {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let png = image.representation(using: .png, properties: [:])!
        // This stub exercises UI state only; FormulaRenderEngineTests validate actual image/PDF output.
        return FormulaRenderResult(latex: latex, svg: "<svg />", mathML: "<math />", png: png,
                                   pdf: Data("%PDF-stub".utf8), width: 2, height: 2, pointWidth: 1, pointHeight: 1)
    }
}

private actor FormulaRenderTestConcurrency {
    private var active = 0
    private(set) var started = 0
    private(set) var maximum = 0
    func begin() { active += 1; started += 1; maximum = max(maximum, active) }
    func end() { active -= 1 }
}
