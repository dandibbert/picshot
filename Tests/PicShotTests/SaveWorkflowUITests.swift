import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class SaveWorkflowUITests: XCTestCase {
    func testRealSettingsPreviewInvalidTemplateAndUncommittedDraft() throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let original = SaveWorkflowSettings(baseURL: root, filenameTemplate: "Shot-{width}-{counter}")
        try original.save(to: defaults)
        let settings = SettingsController(onChange: {}, defaults: defaults, isSmoke: false)
        defer { settings.close() }
        settings.selectCategory(.save)
        let view = settings.saveWorkflowView
        XCTAssertEqual(view.automatic.state, .off)
        XCTAssertTrue(view.previewLabel.stringValue.contains("Shot-1920-1.png"))
        view.filenameTemplate.stringValue = "{invalid}"; XCTAssertTrue(view.filenameTemplate.sendAction(view.filenameTemplate.action, to: view.filenameTemplate.target))
        XCTAssertThrowsError(try settings.validateSaveWorkflowDraft())
        XCTAssertFalse(view.errorLabel.stringValue.isEmpty)
        settings.close()
        XCTAssertEqual(SaveWorkflowSettings.read(from: defaults), original)
    }
    func testNativeFolderPickerCancelPreservesDraftAndPreferences() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let original = SaveWorkflowSettings(baseURL: root); try original.save(to: defaults)
        let settings = SettingsController(onChange: {}, defaults: defaults, isSmoke: false)
        settings.selectCategory(.save); settings.showWindow(nil); defer { settings.close() }
        var presented = false
        settings.saveWorkflowView.onFolderPanelShown = { panel in presented = true; panel.cancel(nil) }
        settings.saveWorkflowView.chooseFolderButton.performClick(nil)
        try await SaveWorkflowUIPreviewFixture.until({ presented && settings.saveWorkflowView.folderPanel == nil }, "Folder cancel did not resolve")
        XCTAssertEqual(settings.saveWorkflowView.baseURL, root); XCTAssertEqual(SaveWorkflowSettings.read(from: defaults), original)
    }
    func testQuietAutomaticCopyIsImmediateAndJobSurvivesEditorClose() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        let board = NSPasteboard.withUniqueName()
        defer { ImageExportService.queue.isSuspended = false; board.releaseGlobally(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try SaveWorkflowSettings(baseURL: root, filenameTemplate: "auto-{counter}", autoOnFinalizedAction: true).save(to: defaults)
        let presenter = SaveWorkflowPresenter(defaults: defaults)
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 64, height: 48)
        let editor = ImageEditorController(image: image, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, saveWorkflow: presenter,
            copyAction: { image in
                board.clearContents()
                let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                _ = board.setData(bytes, forType: .png)
            })
        defer { editor.close(); for job in presenter.controllers { job.cancel() } }
        editor.showWindow(nil)
        ImageExportService.queue.isSuspended = true
        let copy = try XCTUnwrap(descendants(try XCTUnwrap(editor.window?.contentView)).first { $0.identifier?.rawValue == "editor.copy" } as? NSButton)
        copy.performClick(nil)
        XCTAssertNotNil(board.data(forType: .png), "Immediate copy must not wait for automatic save queue")
        let job = try XCTUnwrap(presenter.controllers.last)
        XCTAssertTrue(job.quietAutomatic); XCTAssertFalse(job.window?.isVisible ?? true)
        XCTAssertEqual(presenter.activeJobCount, 1); XCTAssertGreaterThan(presenter.retainedInputBytes, 0)
        editor.close(); ImageExportService.queue.isSuspended = false
        try await SaveWorkflowUIPreviewFixture.drained(presenter)
        XCTAssertNotNil(job.result); XCTAssertFalse(job.window?.isVisible ?? true)
        XCTAssertEqual(presenter.retainedInputBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(job.result).savedURL.path))
    }
    func testAutosaveOffAndNonFinalActionsDoNotCreateJobs() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let presenter = SaveWorkflowPresenter(defaults: defaults)
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 32, height: 24)
        XCTAssertNil(presenter.save(image: image, automatic: true))
        try SaveWorkflowSettings(baseURL: root, autoOnFinalizedAction: true).save(to: defaults)
        var recognized = 0
        let editor = ImageEditorController(image: image, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in recognized += 1 }, saveWorkflow: presenter)
        editor.showWindow(nil)
        let ocr = try XCTUnwrap(descendants(try XCTUnwrap(editor.window?.contentView)).first { $0.identifier?.rawValue == "editor.ocr" } as? NSButton)
        ocr.performClick(nil); XCTAssertEqual(recognized, 1)
        editor.close(); try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(presenter.activeJobCount, 0); XCTAssertTrue(presenter.controllers.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testCancelledQueuedSnapshotsKeepAdmissionUntilQueueDrains() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { ImageExportService.queue.isSuspended = false; defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try SaveWorkflowSettings(baseURL: root).save(to: defaults)
        let presenter = SaveWorkflowPresenter(defaults: defaults)
        XCTAssertFalse(presenter.canAdmit(inputBytes: SaveWorkflowPresenter.maximumRetainedInputBytes + 1))
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 64, height: 48)
        ImageExportService.queue.isSuspended = true
        let first = try XCTUnwrap(presenter.save(image: image)), second = try XCTUnwrap(presenter.save(image: image))
        try await SaveWorkflowUIPreviewFixture.until({ first.state == .encoding && second.state == .encoding }, "Jobs did not reach queue")
        XCTAssertFalse(presenter.canAdmit(inputBytes: 1))
        first.cancel(); second.cancel()
        XCTAssertEqual(presenter.activeJobCount, 2, "Cancelled queued work must keep reservations until its continuation drains")
        ImageExportService.queue.isSuspended = false; try await SaveWorkflowUIPreviewFixture.drained(presenter)
        XCTAssertEqual(presenter.retainedInputBytes, 0); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testChooseAnotherCollisionPanelCancelPreservesOriginal() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try SaveWorkflowSettings(baseURL: root, filenameTemplate: "existing").save(to: defaults)
        let originalURL = root.appendingPathComponent("existing.png"), original = Data("do-not-replace".utf8)
        try original.write(to: originalURL)
        let presenter = SaveWorkflowPresenter(defaults: defaults)
        var chooseAnotherPresented = false
        presenter.onPresent = { job in
            job.onCollisionShown = { $0.buttons[1].performClick(nil) }
            job.onSavePanelShown = { panel in chooseAnotherPresented = true; panel.cancel(nil) }
        }
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 32)
        let job = try XCTUnwrap(presenter.save(image: image))
        try await SaveWorkflowUIPreviewFixture.until({ job.state == .closed }, "Choose Another cancellation did not finish")
        try await SaveWorkflowUIPreviewFixture.drained(presenter)
        XCTAssertTrue(chooseAnotherPresented); XCTAssertNil(job.result)
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.png"])
    }

    func testApplicationPresenterReachesCurrentAndOriginalPinExportAndExactCopy() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        let board = NSPasteboard.withUniqueName(), previous = SaveWorkflowPresenter.application
        defer {
            SaveWorkflowPresenter.application = previous; board.releaseGlobally()
            defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root)
        }
        try SaveWorkflowSettings(baseURL: root, filenameTemplate: "pin-{counter}").save(to: defaults)
        let presenter = SaveWorkflowPresenter(defaults: defaults); SaveWorkflowPresenter.application = presenter
        presenter.clipboardCopier = { data, type in board.clearContents(); return board.setData(data, forType: .init(type)) }
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 128, height: 96)
        let pin = PinController(image: image); defer { pin.close(); for job in presenter.controllers { job.cancel() } }
        pin.bringForward(); try pin.cropImage(to: CGRect(x: 0, y: 0, width: 60, height: 40))
        let current = try XCTUnwrap(pin.actionMenu?.item(withTitle: "当前图像另存为…"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(current.action), to: current.target, from: current))
        let export = try XCTUnwrap(pin.imageExportController)
        try await SaveWorkflowUIPreviewFixture.until({ export.latestArtifact != nil }, "Current pin preview missing")
        let bytes = try XCTUnwrap(export.latestArtifact).data
        XCTAssertFalse(export.saveCopyButton.isHidden); XCTAssertTrue(export.saveCopyButton.isEnabled)
        export.saveCopyButton.performClick(nil)
        let saved = try XCTUnwrap(presenter.controllers.last)
        try await SaveWorkflowUIPreviewFixture.until({ saved.result != nil }, "Current pin save/copy failed")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.result).savedURL), bytes)
        XCTAssertEqual(board.data(forType: .png), bytes); saved.cancel(); try await SaveWorkflowUIPreviewFixture.drained(presenter)
        let original = try XCTUnwrap(pin.actionMenu?.item(withTitle: "原始图片")?.submenu?.item(withTitle: "原始图片另存为…"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(original.action), to: original.target, from: original))
        let originalExport = try XCTUnwrap(pin.imageExportController)
        try await SaveWorkflowUIPreviewFixture.until({ originalExport.latestArtifact != nil }, "Original pin preview missing")
        XCTAssertFalse(originalExport.saveCopyButton.isHidden); XCTAssertTrue(originalExport.saveCopyButton.isEnabled)
        XCTAssertEqual(originalExport.latestArtifact?.width, 128); XCTAssertEqual(originalExport.latestArtifact?.height, 96)
        originalExport.cancelExport()
    }

    func testNativeWorkflowControlsFilesAndInstalledEvidence() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Native save workflow visual fixture requires WindowServer") }
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let report = try await SaveWorkflowUIPreviewFixture.verify(evidenceDirectory: root)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual((report["resourceCycles"] as? [[String: Any]])?.count, 10)
    }
    private func isolated() throws -> (UserDefaults, String, URL) {
        let name = "PicShot-SaveWorkflowUITests-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name, root)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
