import AppKit
import XCTest
import PicShotCore
@testable import PicShot

final class PendingCaptureControllerTests: XCTestCase {
    @MainActor func testNativeCloseEscapePickerCancelAndDiscardDeclineRetainOriginal() throws {
        _ = NSApplication.shared
        let recovery = try pending(), controller = PendingCaptureController(recovery: recovery)
        defer { controller.close() }
        let id = recovery.pending?.id, image = try XCTUnwrap(recovery.pending?.image)
        controller.showWindow(nil); controller.window?.performClose(nil)
        XCTAssertEqual(recovery.pending?.id, id)
        controller.showWindow(nil); try press("cancel", in: controller)
        XCTAssertEqual(recovery.pending?.id, id); XCTAssertFalse(controller.window?.isVisible ?? true)
        controller.showWindow(nil)
        controller.chooseDestination = { _, completion in completion(nil) }
        try press("save", in: controller)
        XCTAssertFalse(recovery.isSaving); XCTAssertTrue(recovery.pending?.image === image)
        controller.confirmDiscard = { false }; try press("discard", in: controller)
        XCTAssertEqual(recovery.pending?.id, id)
        controller.confirmDiscard = { true }; try press("discard", in: controller)
        XCTAssertNil(recovery.pending)
    }

    @MainActor func testNativeRetryUsesOriginalDatePixelsAndCannotClaimRefusalSucceeded() throws {
        _ = NSApplication.shared
        let recovery = try pending(), controller = PendingCaptureController(recovery: recovery)
        defer { controller.close() }
        let image = try XCTUnwrap(recovery.pending?.image), date = recovery.pending?.capturedAt
        var attempts = 0, allow = false
        controller.onRetry = { capture in
            attempts += 1; XCTAssertTrue(capture.image === image); XCTAssertEqual(capture.capturedAt, date); return allow
        }
        controller.showWindow(nil); try press("retry", in: controller)
        XCTAssertNotNil(recovery.pending); XCTAssertEqual(attempts, 1)
        allow = true; try press("retry", in: controller)
        XCTAssertNil(recovery.pending); XCTAssertEqual(attempts, 2)
        XCTAssertFalse(controller.window?.isVisible ?? true)
    }

    @MainActor func testNativeSaveFailureAndCancelRetainWhileSuccessResolves() async throws {
        _ = NSApplication.shared
        for mode in ["failure", "cancel", "success"] {
            let recovery = try pending(), controller = PendingCaptureController(recovery: recovery)
            defer { controller.close() }
            let id = recovery.pending?.id
            controller.chooseDestination = { _, completion in completion(URL(fileURLWithPath: "/synthetic.png")) }
            controller.write = { _, url, cancellation in
                try await Task.sleep(nanoseconds: 20_000_000)
                try cancellation.check()
                if mode == "failure" { throw CaptureRecoveryError.writeFailed }
                return url
            }
            let finished = expectation(description: mode)
            let refresh = recovery.didChange
            recovery.didChange = { refresh?(); if !recovery.isSaving { finished.fulfill() } }
            controller.showWindow(nil); try press("save", in: controller)
            XCTAssertTrue(recovery.isSaving)
            XCTAssertFalse(try button("retry", in: controller).isEnabled)
            XCTAssertFalse(try button("discard", in: controller).isEnabled)
            if mode == "cancel" { try press("cancel", in: controller) }
            await fulfillment(of: [finished], timeout: 3)
            XCTAssertFalse(recovery.isSaving)
            if mode == "success" { XCTAssertNil(recovery.pending) }
            else { XCTAssertEqual(recovery.pending?.id, id) }
        }
    }

    @MainActor func testAppQuitRefusesPendingAndActualEditorAdmissionAccountsForTransfer() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try raster(), imageBytes = image.bytesPerRow * image.height
        let editorBytes = EditorRasterEstimate.openingBytes(image: image, presentation: nil)
        let app = AppDelegate(history: HistoryStore(directory: directory), isolatedDefaults: try defaults(),
                              editorAdmission: EditorAdmissionPolicy(maximumRasterBytes: editorBytes))
        defer { app.controllers.forEach { $0.close() } }
        let capture = try PendingCapture(CapturedImage(image: image, presentation: nil), title: "fixture")
        try app.pendingCaptureRecovery.retain(capture, error: CaptureRecoveryError.writeFailed)
        XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(app.pendingCaptureRecovery.retainedBytes, imageBytes)
        XCTAssertFalse(app.openEditor(image, showAdmissionNotice: false), "Unrelated editor includes the pending reservation")
        XCTAssertFalse(app.openEditor(image, transferringPendingID: UUID(), showAdmissionNotice: false))
        XCTAssertTrue(app.pendingCaptureRecovery.retryEditor { pending in
            app.openEditor(pending.image, captureDate: pending.capturedAt, transferringPendingID: pending.id, showAdmissionNotice: false)
        }, "Exact same-image handoff must not double-count pending pixels")
        XCTAssertNil(app.pendingCaptureRecovery.pending)
        XCTAssertFalse(app.openEditor(image, showAdmissionNotice: false), "The original editor budget remains unchanged")
        XCTAssertEqual(app.controllers.compactMap { $0 as? ImageEditorController }.count, 1)
        // Resolve the hidden recovery window created by the quit attempt.
        NSApplication.shared.windows.filter { $0.title == "PicShot · 未保存的截图" }.forEach { $0.close() }
    }

    @MainActor func testActualAppEditorCountReturnsFalseForSeventhWindow() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppDelegate(history: HistoryStore(directory: directory), isolatedDefaults: try defaults()), image = try raster()
        defer { Array(app.controllers).forEach { $0.close() } }
        for _ in 0..<6 { XCTAssertTrue(app.openEditor(image, showAdmissionNotice: false)) }
        XCTAssertFalse(app.openEditor(image, showAdmissionNotice: false))
        XCTAssertEqual(app.controllers.compactMap { $0 as? ImageEditorController }.count, 6)
    }

    @MainActor func testProductionEntryPointRejectsFullCountBeforeHideDelayOrAcquisition() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var notices = 0, acquisitions = 0
        let app = AppDelegate(history: HistoryStore(directory: directory), isolatedDefaults: try defaults(), admissionNotice: { notices += 1 })
        let image = try raster()
        app.mainWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        app.mainWindow.isReleasedWhenClosed = false; app.mainWindow.orderFront(nil)
        defer { Array(app.controllers).forEach { $0.close() }; app.mainWindow.close() }
        for _ in 0..<6 { XCTAssertTrue(app.openEditor(image, showAdmissionNotice: false)) }
        app.runCaptureForEditing {
            acquisitions += 1; return CapturedImage(image: image, presentation: nil)
        }
        XCTAssertEqual(notices, 1); XCTAssertEqual(acquisitions, 0)
        XCTAssertFalse(app.busy); XCTAssertTrue(app.mainWindow.isVisible)
        XCTAssertTrue(app.history.records.isEmpty)
    }

    @MainActor func testIsolatedAppNativeSaveCannotUseAutomaticOutputSettings() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("automatic-output")
        let suite = "PicShot.PendingCaptureTests." + UUID().uuidString
        let isolated = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { isolated.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try SaveWorkflowSettings(baseURL: output, autoOnFinalizedAction: true).save(to: isolated)
        let before = isolated.persistentDomain(forName: suite) as NSDictionary?
        let app = AppDelegate(history: HistoryStore(directory: root.appendingPathComponent("history")), isolatedDefaults: isolated)
        XCTAssertTrue(app.openEditor(try raster(), showAdmissionNotice: false))
        let editor = try XCTUnwrap(app.controllers.first as? ImageEditorController)
        defer { editor.close() }
        XCTAssertTrue(NSApp.sendAction(Selector(("saveResult")), to: editor, from: nil))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while app.history.records.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(app.history.records.count, 1, "Native history action still commits to isolated history")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        XCTAssertEqual(isolated.persistentDomain(forName: suite) as NSDictionary?, before)
    }
    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "PicShot.PendingCaptureTests." + UUID().uuidString))
    }

    @MainActor private func pending() throws -> PendingCaptureRecovery {
        let recovery = PendingCaptureRecovery()
        try recovery.retain(PendingCapture(CapturedImage(image: try raster(), presentation: nil,
            capturedAt: Date(timeIntervalSince1970: 12345)), title: "fixture"), error: CaptureRecoveryError.writeFailed)
        return recovery
    }
    @MainActor private func button(_ name: String, in controller: PendingCaptureController) throws -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if view.identifier?.rawValue == "pending-capture-" + name { return view as? NSButton }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(try XCTUnwrap(controller.window?.contentView)))
    }
    @MainActor private func press(_ name: String, in controller: PendingCaptureController) throws {
        let button = try button(name, in: controller)
        XCTAssertTrue(button.isEnabled); XCTAssertNotNil(button.target); XCTAssertNotNil(button.action)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
    }
    private func raster() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}
