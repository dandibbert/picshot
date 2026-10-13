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
    func testQuietAutomaticCopyIsImmediateAndJobSurvivesEditorClose() async throws { try await checkQuietAutomaticCopyIsImmediateAndJobSurvivesEditorClose(.legacyPreview) }
    func testEncodedPayloadQuietAutomaticCopyIsImmediateAndJobSurvivesEditorClose() async throws { try await checkQuietAutomaticCopyIsImmediateAndJobSurvivesEditorClose(.encodedPayload) }

    private func checkQuietAutomaticCopyIsImmediateAndJobSurvivesEditorClose(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        let board = NSPasteboard.withUniqueName()
        defer { ImageExportService.queue.isSuspended = false; board.releaseGlobally(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try SaveWorkflowSettings(baseURL: root, filenameTemplate: "auto-{counter}", autoOnFinalizedAction: true).save(to: defaults)
        let presenter = SaveWorkflowPresenter(defaults: defaults, pngPreparationMode: mode)
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
    func testCancelledQueuedSnapshotsKeepAdmissionUntilQueueDrains() async throws { try await checkCancelledQueuedSnapshotsKeepAdmissionUntilQueueDrains(.legacyPreview) }
    func testEncodedPayloadCancelledQueuedSnapshotsKeepAdmissionUntilQueueDrains() async throws { try await checkCancelledQueuedSnapshotsKeepAdmissionUntilQueueDrains(.encodedPayload) }

    private func checkCancelledQueuedSnapshotsKeepAdmissionUntilQueueDrains(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { ImageExportService.queue.isSuspended = false; defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try SaveWorkflowSettings(baseURL: root).save(to: defaults)
        let presenter = SaveWorkflowPresenter(defaults: defaults, pngPreparationMode: mode)
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
    func testChooseAnotherCollisionPanelCancelPreservesOriginal() async throws { try await checkChooseAnotherCollisionPanelCancelPreservesOriginal(.legacyPreview) }
    func testEncodedPayloadChooseAnotherCollisionPanelCancelPreservesOriginal() async throws { try await checkChooseAnotherCollisionPanelCancelPreservesOriginal(.encodedPayload) }

    private func checkChooseAnotherCollisionPanelCancelPreservesOriginal(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try SaveWorkflowSettings(baseURL: root, filenameTemplate: "existing").save(to: defaults)
        let originalURL = root.appendingPathComponent("existing.png"), original = Data("do-not-replace".utf8)
        try original.write(to: originalURL)
        let presenter = SaveWorkflowPresenter(defaults: defaults, pngPreparationMode: mode)
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
    func testFixtureCanonicalDirectoryPassesNoFollowAndRawAliasStillFails() throws {
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try SaveWorkflowService.validateBaseDirectory(root)
        try SaveWorkflowSettings(baseURL: root).save(to: defaults)
        XCTAssertEqual(SaveWorkflowSettings.read(from: defaults).baseURL?.path, root.path)
        let target = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try SaveWorkflowService.validateBaseDirectory(alias))
        let canonical = try SaveWorkflowUIPreviewFixture.canonicalExistingDirectory(alias)
        XCTAssertEqual(canonical.path, target.path)
        try SaveWorkflowService.validateBaseDirectory(canonical)
    }
    func testLongASCIIAndUnicodeSavePathsKeepOutcomeVisibleAtBothWidths() async throws { try await checkLongASCIIAndUnicodeSavePathsKeepOutcomeVisibleAtBothWidths(.legacyPreview) }
    func testEncodedPayloadLongASCIIAndUnicodeSavePathsKeepOutcomeVisibleAtBothWidths() async throws { try await checkLongASCIIAndUnicodeSavePathsKeepOutcomeVisibleAtBothWidths(.encodedPayload) }

    private func checkLongASCIIAndUnicodeSavePathsKeepOutcomeVisibleAtBothWidths(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let presenter = SaveWorkflowPresenter(defaults: defaults, pngPreparationMode: mode)
        defer { presenter.cancelAll() }
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 32)
        for component in [String(repeating: "long-output-", count: 8), String(repeating: "截图资料-é-", count: 6)] {
            try SaveWorkflowSettings(baseURL: root, relativeFolderTemplate: component + "/" + component,
                filenameTemplate: component + "-{counter}").save(to: defaults)
            let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false; parent.orderFront(nil)
            defer { parent.close() }
            weak var observedJob: SaveWorkflowController?
            var callbacks = 0
            let job = try XCTUnwrap(presenter.save(image: image, from: parent, onSaved: { _ in
                callbacks += 1
                XCTAssertNil(observedJob?.window?.parent, "Successful feedback must detach before recipient retirement")
                // Match the real capture HUD: orderOut precedes willClose.
                parent.orderOut(nil); parent.close()
                XCTAssertTrue(observedJob?.window?.isVisible == true, "Parent retirement must not hide the saved outcome")
            }))
            observedJob = job
            try await SaveWorkflowUIPreviewFixture.until({ job.state == .completed || job.state == .failed }, "Long-path save did not finish")
            XCTAssertEqual(callbacks, 1); XCTAssertNil(job.window?.parent)
            XCTAssertTrue(job.window?.isVisible == true)
            let saved = try XCTUnwrap(job.result)
            XCTAssertEqual(saved.clipboardOutcome, .notRequested)
            XCTAssertEqual(job.statusLabel.stringValue, "文件已安全保存")
            XCTAssertEqual(job.detailLabel.stringValue, saved.savedURL.path)
            XCTAssertEqual(job.detailLabel.accessibilityLabel(), "保存位置")
            XCTAssertFalse(job.statusLabel.stringValue.contains(saved.savedURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.savedURL.path))
            try assertFeedbackAtBothWidths(job, detailIsLong: true)
            job.cancel(); try await SaveWorkflowUIPreviewFixture.drained(presenter)
        }
    }

    func testCopyFailureAndRetryKeepVisibleOutcomeAndExactSavedBytes() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let component = String(repeating: "复制结果-é-", count: 6)
        try SaveWorkflowSettings(baseURL: root, relativeFolderTemplate: component + "/" + component,
            filenameTemplate: component + "-{counter}").save(to: defaults)
        let presenter = SaveWorkflowPresenter(defaults: defaults)
        defer { presenter.cancelAll() }
        var copyCalls = 0
        presenter.clipboardCopier = { bytes, type in
            copyCalls += 1
            guard copyCalls > 1 else { return false }
            board.clearContents(); return board.setData(bytes, forType: .init(type))
        }
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.level = .floating; parent.orderFront(nil)
        defer { parent.close() }
        let job = try XCTUnwrap(presenter.save(image: SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 32), copy: true, from: parent))
        try await SaveWorkflowUIPreviewFixture.until({ job.state == .completed || job.state == .failed }, "Copy-failure save did not finish")
        XCTAssertTrue(job.window?.parent === parent)
        XCTAssertGreaterThan(try XCTUnwrap(job.window).level.rawValue, parent.level.rawValue)
        let saved = try XCTUnwrap(job.result), bytes = try Data(contentsOf: saved.savedURL)
        XCTAssertEqual(saved.clipboardOutcome, .failed); XCTAssertEqual(copyCalls, 1)
        XCTAssertEqual(job.statusLabel.stringValue, "复制失败，已保存的文件仍然保留，可重试复制")
        XCTAssertEqual(job.detailLabel.stringValue, saved.savedURL.path)
        XCTAssertEqual(job.retainedClipboardBytes, bytes.count)
        XCTAssertFalse(job.retryCopyButton.isHidden); XCTAssertTrue(job.retryCopyButton.isEnabled)
        try assertFeedbackAtBothWidths(job, detailIsLong: true)
        job.retryCopyButton.performClick(nil)
        XCTAssertEqual(copyCalls, 2); XCTAssertEqual(job.result?.clipboardOutcome, .copied)
        XCTAssertTrue(job.window?.parent === parent, "Retry must preserve its existing presentation lifecycle")
        XCTAssertGreaterThan(try XCTUnwrap(job.window).level.rawValue, parent.level.rawValue)
        XCTAssertEqual(job.statusLabel.stringValue, "已保存并复制同一份编码文件内容")
        XCTAssertEqual(job.detailLabel.stringValue, saved.savedURL.path)
        XCTAssertTrue(job.retryCopyButton.isHidden); XCTAssertEqual(job.retainedClipboardBytes, 0)
        XCTAssertEqual(try Data(contentsOf: saved.savedURL), bytes); XCTAssertEqual(board.data(forType: .png), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.savedURL.deletingLastPathComponent().path), [saved.savedURL.lastPathComponent])
        try assertFeedbackAtBothWidths(job, detailIsLong: true)
        job.cancel(); try await SaveWorkflowUIPreviewFixture.drained(presenter)
    }

    func testDiskFailureKeepsVisibleOutcomeAndFullAccessibleError() async throws { try await checkDiskFailureKeepsVisibleOutcomeAndFullAccessibleError(.legacyPreview) }
    func testEncodedPayloadDiskFailureKeepsVisibleOutcomeAndFullAccessibleError() async throws { try await checkDiskFailureKeepsVisibleOutcomeAndFullAccessibleError(.encodedPayload) }

    private func checkDiskFailureKeepsVisibleOutcomeAndFullAccessibleError(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing-save-directory", isDirectory: true)
        try SaveWorkflowSettings(baseURL: missing).save(to: defaults)
        let presenter = SaveWorkflowPresenter(defaults: defaults, pngPreparationMode: mode)
        defer { presenter.cancelAll() }
        var copyCalls = 0
        presenter.clipboardCopier = { _, _ in copyCalls += 1; return true }
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.orderFront(nil)
        defer { parent.close() }
        let job = try XCTUnwrap(presenter.save(image: SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 32), copy: true, from: parent))
        try await SaveWorkflowUIPreviewFixture.until({ job.state == .failed }, "Missing save directory did not fail")
        XCTAssertTrue(job.window?.parent === parent, "Failure remains attached to the active capture")
        XCTAssertNil(job.result); XCTAssertEqual(copyCalls, 0)
        XCTAssertEqual(job.statusLabel.stringValue, "保存失败；原图仍然保留，可关闭后重试。")
        XCTAssertEqual(job.statusLabel.textColor, .systemRed)
        XCTAssertEqual(job.detailLabel.stringValue, SaveWorkflowError.unsafeDirectory.localizedDescription)
        XCTAssertEqual(job.detailLabel.accessibilityLabel(), "错误详情")
        XCTAssertEqual(job.closeButton.title, "关闭"); XCTAssertTrue(job.retryCopyButton.isHidden)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try assertFeedbackAtBothWidths(job)
        job.cancel(); try await SaveWorkflowUIPreviewFixture.drained(presenter)
    }

    func testReadyAndQueuedProgressStayVisibleWithoutPathOrErrorDetail() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { ImageExportService.queue.isSuspended = false; defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 32)
        let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init())
        for prepared in [false, true] {
            let job = try SaveWorkflowController(image: prepared ? nil : image, artifact: prepared ? artifact : nil,
                settings: .init(baseURL: root), defaults: defaults, copyAfterSaving: false)
            defer { job.cancel() }
            job.revealForDecision()
            XCTAssertEqual(job.statusLabel.stringValue, "准备保存最终图片…")
            try assertFeedbackAtBothWidths(job)
            ImageExportService.queue.isSuspended = true; job.start()
            let expectedState: SaveWorkflowController.State = prepared ? .saving : .encoding
            try await SaveWorkflowUIPreviewFixture.until({ job.state == expectedState }, "Save did not reach queued progress")
            XCTAssertEqual(job.statusLabel.stringValue, prepared ? "正在保存完整文件…" : "正在编码最终 PNG…")
            XCTAssertTrue(job.detailLabel.stringValue.isEmpty); XCTAssertTrue(job.detailLabel.isHidden)
            try assertFeedbackAtBothWidths(job)
            job.cancel(); ImageExportService.queue.isSuspended = false
            try await SaveWorkflowUIPreviewFixture.until({ job.jobDrained }, "Cancelled progress job did not drain")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCancelledCopyAfterSaveKeepsPublishedFileMeaningInSeparateStatus() throws {
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 16, height: 12)
        let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init())
        let saved = try SaveWorkflowService.publish(artifact, to: root.appendingPathComponent("outcomes.png"))
        let cancellation = ImageExportCancellation(); cancellation.cancel()
        let outcome = SaveWorkflowService.copySaved(saved, cancellation: cancellation) { _, _ in
            XCTFail("Cancellation after publication must skip copying"); return false
        }
        let summary = SaveWorkflowSummary(outcome)
        XCTAssertEqual(summary.clipboardOutcome, .cancelledAfterSave)
        XCTAssertEqual(summary.statusText, "文件已完成保存；关闭操作取消了后续复制")
        XCTAssertFalse(summary.statusText.contains(root.path))
        XCTAssertEqual(summary.savedURL, saved.savedURL); XCTAssertEqual(summary.byteCount, artifact.byteCount)
        XCTAssertEqual(try Data(contentsOf: saved.savedURL), artifact.data)
    }

    func testFreshPNGCollisionKeepBothRetriesPublicationAndKeepsVisibleSuccess() async throws {
        _ = NSApplication.shared
        for mode in [SavePNGPreparationMode.legacyPreview, .encodedPayload] {
            let (defaults, name, root) = try isolated()
            defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
            try SaveWorkflowSettings(baseURL: root, filenameTemplate: "existing", collisionBehavior: .ask).save(to: defaults)
            let existing = root.appendingPathComponent("existing.png"), sentinel = Data("keep-existing".utf8)
            try sentinel.write(to: existing)
            let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 32)
            let expected = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init()).data
            let presenter = SaveWorkflowPresenter(defaults: defaults, pngPreparationMode: mode)
            defer { presenter.cancelAll() }
            var collisions = 0, savedCalls = 0, drainCalls = 0
            presenter.onPresent = { job in
                let drained = job.onDrained
                job.onDrained = { drained?(); drainCalls += 1 }
                job.onCollisionShown = { alert in collisions += 1; alert.buttons[0].performClick(nil) }
            }
            let job = try XCTUnwrap(presenter.save(image: image, onSaved: { _ in savedCalls += 1 }))
            try await SaveWorkflowUIPreviewFixture.until({ job.jobDrained }, "Keep Both retry did not drain")
            XCTAssertEqual(job.state, .completed)
            XCTAssertEqual(collisions, 1); XCTAssertEqual(savedCalls, 1); XCTAssertEqual(drainCalls, 1)
            XCTAssertEqual(presenter.retainedInputBytes, 0)
            let result = try XCTUnwrap(job.result)
            XCTAssertEqual(result.savedURL.lastPathComponent, "existing (1).png")
            XCTAssertEqual(try Data(contentsOf: result.savedURL), expected)
            XCTAssertEqual(try Data(contentsOf: existing), sentinel)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["existing.png", "existing (1).png"])
            XCTAssertEqual(job.statusLabel.stringValue, "文件已安全保存")
            XCTAssertEqual(job.detailLabel.stringValue, result.savedURL.path)
            XCTAssertTrue(job.window?.isVisible == true)
            try assertFeedbackAtBothWidths(job)
            job.cancel(); job.cancel()
            XCTAssertEqual(drainCalls, 1); XCTAssertTrue(presenter.controllers.isEmpty)
        }
    }

    func testPNGPreparationModeDefaultsToLegacyAndIsExplicitlyInherited() throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 32)
        let defaultPresenter = SaveWorkflowPresenter(defaults: defaults)
        XCTAssertEqual(defaultPresenter.pngPreparationMode, .legacyPreview)
        let defaultJob = try SaveWorkflowController(image: image, artifact: nil, settings: .init(baseURL: root),
            defaults: defaults, copyAfterSaving: false)
        defer { defaultJob.cancel() }
        XCTAssertEqual(defaultJob.pngPreparationMode, .legacyPreview)
        try SaveWorkflowSettings(baseURL: root).save(to: defaults)
        for mode in [SavePNGPreparationMode.legacyPreview, .encodedPayload] {
            let presenter = SaveWorkflowPresenter(defaults: defaults, pngPreparationMode: mode)
            defer { presenter.cancelAll() }
            // Close before start to assert mode propagation without scheduling I/O.
            presenter.onPresent = { $0.cancel() }
            let job = try XCTUnwrap(presenter.save(image: image))
            XCTAssertEqual(job.pngPreparationMode, mode)
            XCTAssertTrue(job.jobDrained); XCTAssertTrue(presenter.controllers.isEmpty)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testEncodedPayloadModeKeepsSuppliedArtifactsAndPreviewAdmissionForEveryFormat() async throws {
        _ = NSApplication.shared
        let (defaults, name, root) = try isolated()
        defer { ImageExportService.queue.isSuspended = false; defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try SaveWorkflowSettings(baseURL: root).save(to: defaults)
        let image = try SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 32)
        let preview = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init()).firstPreview
        for format in ImageExportFormat.allCases {
            let presenter = SaveWorkflowPresenter(defaults: defaults, pngPreparationMode: .encodedPayload)
            defer { presenter.cancelAll() }
            let artifact = ImageExportArtifact(data: Data("supplied-\(format.title)".utf8), options: .init(format: format),
                width: 48, height: 32, pageCount: 1, firstPreview: preview, sourceURL: nil)
            let expectedReservation = artifact.byteCount + preview.bytesPerRow * preview.height
            ImageExportService.queue.isSuspended = true
            let job = try XCTUnwrap(presenter.save(artifact: artifact, copy: false))
            try await SaveWorkflowUIPreviewFixture.until({ job.state == .saving }, "Supplied artifact must bypass PNG encoding")
            XCTAssertEqual(job.reservedInputBytes, expectedReservation)
            XCTAssertEqual(presenter.retainedInputBytes, expectedReservation)
            job.cancel()
            XCTAssertEqual(presenter.retainedInputBytes, expectedReservation, "Cancelled work keeps admission until drain")
            ImageExportService.queue.isSuspended = false
            try await SaveWorkflowUIPreviewFixture.drained(presenter)
            XCTAssertEqual(presenter.retainedInputBytes, 0); XCTAssertTrue(presenter.controllers.isEmpty)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func assertFeedbackAtBothWidths(_ job: SaveWorkflowController, detailIsLong: Bool = false,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let window = try XCTUnwrap(job.window, file: file, line: line), content = try XCTUnwrap(window.contentView, file: file, line: line)
        let previousAppearance = window.appearance
        defer { window.appearance = previousAppearance }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = try XCTUnwrap(NSAppearance(named: appearance), file: file, line: line)
            for width in [CGFloat(460), 320, 460] {
                window.setContentSize(CGSize(width: width, height: 190)); window.layoutIfNeeded(); content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                XCTAssertEqual(content.bounds.width, width, accuracy: 0.5, file: file, line: line)
                XCTAssertEqual(content.bounds.height, 190, accuracy: 0.5, file: file, line: line)
                XCTAssertFalse(job.statusLabel.isHiddenOrHasHiddenAncestor, file: file, line: line)
                XCTAssertEqual(job.statusLabel.accessibilityLabel(), "保存状态", file: file, line: line)
                XCTAssertEqual(job.statusLabel.accessibilityValue() as? String, job.statusLabel.stringValue, file: file, line: line)
                let needed = try XCTUnwrap(job.statusLabel.cell, file: file, line: line).cellSize(forBounds:
                    NSRect(x: 0, y: 0, width: job.statusLabel.bounds.width, height: 1_000))
                XCTAssertGreaterThanOrEqual(job.statusLabel.bounds.height + 0.5, needed.height, "Complete outcome must fit", file: file, line: line)
                XCTAssertEqual(job.noteLabel.identifier?.rawValue, "saveWorkflow.note", file: file, line: line)
                XCTAssertTrue(window.isVisible, "Outcome/progress must remain visible", file: file, line: line)
                XCTAssertTrue(job.noteLabel.isDescendant(of: content), file: file, line: line)
                XCTAssertFalse(job.noteLabel.isHiddenOrHasHiddenAncestor, file: file, line: line)
                let controls: [NSControl] = [job.statusLabel, job.detailLabel, job.noteLabel, job.retryCopyButton, job.closeButton]
                    .filter { !$0.isHiddenOrHasHiddenAncestor }
                let frames = controls.map { $0.convert($0.bounds, to: content) }
                for (index, frame) in frames.enumerated() {
                    XCTAssertGreaterThan(frame.width, 0, file: file, line: line); XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
                    XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Visible feedback/control must fit: \(controls[index])", file: file, line: line)
                    for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other), "Feedback and controls must not overlap", file: file, line: line) }
                }
                XCTAssertTrue(job.closeButton.isEnabled, file: file, line: line)
                if !job.detailLabel.stringValue.isEmpty {
                    XCTAssertFalse(job.detailLabel.isHiddenOrHasHiddenAncestor, file: file, line: line)
                    XCTAssertEqual(job.detailLabel.maximumNumberOfLines, 1, file: file, line: line)
                    XCTAssertEqual(job.detailLabel.lineBreakMode, .byTruncatingMiddle, file: file, line: line)
                    XCTAssertEqual(job.detailLabel.toolTip, job.detailLabel.stringValue, file: file, line: line)
                    XCTAssertEqual(job.detailLabel.accessibilityValue() as? String, job.detailLabel.stringValue, file: file, line: line)
                    let detailCell = try XCTUnwrap(job.detailLabel.cell, file: file, line: line)
                    XCTAssertGreaterThanOrEqual(job.detailLabel.bounds.height + 0.5, detailCell.cellSize.height, file: file, line: line)
                    if detailIsLong { XCTAssertGreaterThan(detailCell.cellSize.width, job.detailLabel.bounds.width, "Fixture must require visual truncation", file: file, line: line) }
                } else { XCTAssertTrue(job.detailLabel.isHidden, file: file, line: line) }
            }
        }
    }
    private func isolated() throws -> (UserDefaults, String, URL) {
        let name = "PicShot-SaveWorkflowUITests-" + UUID().uuidString
        let root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: name)
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name, root)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
