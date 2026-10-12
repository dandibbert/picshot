import AppKit
import PicShotCore
import XCTest
@testable import PicShot

@MainActor final class TextScriptAppIntegrationTests: XCTestCase {
    func testSavedMenuHasNoShortcutOrAutomaticExecutionAndKeepsImageCatalog() throws {
        var requested = 0
        let f = try fixture { _ in
            requested += 1
            return self.dependencies(capture: { throw CaptureError.cancelled })
        }
        defer { f.close() }
        let before = try Data(contentsOf: f.images.directory.appendingPathComponent(CaptureChainStore.manifestFilename))
        let menu = f.app.captureChainsMenu()
        let scriptItem = try XCTUnwrap(menu.items.first { $0.action == #selector(AppDelegate.runTextScriptItem(_:)) })
        XCTAssertEqual(scriptItem.representedObject as? String, f.script.id.uuidString)
        XCTAssertEqual(scriptItem.keyEquivalent, "")
        XCTAssertTrue(scriptItem.isEnabled)
        XCTAssertTrue(menu.items.contains { $0.action == #selector(AppDelegate.runCaptureChainItem(_:)) })
        XCTAssertEqual(requested, 0); XCTAssertNil(f.app.activeCaptureChain)
        XCTAssertNil(f.scripts.selectedID)
        XCTAssertEqual(try Data(contentsOf: f.images.directory.appendingPathComponent(CaptureChainStore.manifestFilename)), before)
        XCTAssertTrue(f.app.history.records.isEmpty)
    }

    func testTextRunReservesSameOwnerAndBlocksImageRunCaptureAndQuit() async throws {
        let gate = Gate()
        defer { gate.release() }
        var acquired = 0, imageDependencies = 0, ordinaryCapture = 0
        let f = try fixture(imageDependencies: { _ in
            imageDependencies += 1
            return self.imageDependencies()
        }) { _ in
            self.dependencies(capture: { acquired += 1; await gate.wait(); throw CaptureError.cancelled })
        }
        defer { f.close() }
        XCTAssertTrue(f.app.runTextScript(id: f.script.id))
        let runner = try XCTUnwrap(f.app.activeCaptureChain)
        XCTAssertTrue(runner.snapshot.isTextScript)
        XCTAssertEqual(runner.status, .capturing)
        XCTAssertEqual(acquired, 0)
        XCTAssertFalse(f.app.runTextScript(id: f.script.id))
        XCTAssertFalse(f.app.runCaptureChain(id: f.image.id))
        XCTAssertEqual(imageDependencies, 0)
        f.app.runCaptureForEditing {
            ordinaryCapture += 1
            return CapturedImage(image: try self.raster(), presentation: nil)
        }
        XCTAssertEqual(ordinaryCapture, 0)
        XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateCancel)
        try await until { gate.waiting }
        XCTAssertEqual(acquired, 1)
        XCTAssertTrue(runner.cancel())
        gate.release()
        try await until { runner.status == .cancelled && f.app.activeCaptureChain == nil }
        XCTAssertFalse(f.app.hasActiveCaptureChain)
        XCTAssertEqual(f.app.retainedChainBytes, 0)
        XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateNow)
        XCTAssertTrue(f.app.history.records.isEmpty)
    }

    func testCopyRetryUsesFrozenSourceAndCachedTextWithoutChangingImageCatalog() async throws {
        var captures = 0, ocr = 0, transforms = 0, copies = 0
        var sourceSeen: [String] = [], textSeen: [String] = []
        let f = try fixture { _ in
            .init(capture: { captures += 1; return try ChainCapture(image: self.raster()) },
                  recognize: { _ in ocr += 1; return ChainTextRecognition(text: "PIC-17 PIC-17 PIC-28") },
                  transform: { source, text, _ in
                      transforms += 1; sourceSeen.append(source); textSeen.append(text)
                      return .succeeded("PIC-17\nPIC-28")
                  }, copy: { text in
                      copies += 1; XCTAssertEqual(text, "PIC-17\nPIC-28")
                      if copies == 1 { throw FixtureError.copy }
                  }, cleanupComplete: { _ in true })
        }
        defer { f.close() }
        let before = try Data(contentsOf: f.images.directory.appendingPathComponent(CaptureChainStore.manifestFilename))
        XCTAssertTrue(f.app.runTextScript(id: f.script.id))
        let runner = try XCTUnwrap(f.app.activeCaptureChain)
        try await until { runner.status.canRetry }
        XCTAssertEqual([captures, ocr, transforms, copies], [1, 1, 1, 1])
        XCTAssertTrue(f.app.hasActiveCaptureChain)
        XCTAssertNil(runner.snapshot.textReceipt)
        XCTAssertGreaterThan(runner.snapshot.retainedTextBytes, 0)
        try f.scripts.update(try TextScriptDefinition(id: f.script.id, name: "Changed after capture", source: "return 'changed';"))
        XCTAssertTrue(runner.retry()); XCTAssertFalse(runner.retry())
        try await until { runner.status == .completed && f.app.activeCaptureChain == nil }
        XCTAssertEqual([captures, ocr, transforms, copies], [1, 1, 1, 2])
        XCTAssertEqual(sourceSeen, [f.script.source]); XCTAssertEqual(textSeen, ["PIC-17 PIC-17 PIC-28"])
        XCTAssertEqual(runner.snapshot.textReceipt?.characterCount, "PIC-17\nPIC-28".count)
        XCTAssertEqual(runner.snapshot.retainedTextBytes, 0); XCTAssertEqual(runner.snapshot.retainedBytes, 0)
        XCTAssertEqual(try Data(contentsOf: f.images.directory.appendingPathComponent(CaptureChainStore.manifestFilename)), before)
        XCTAssertTrue(f.app.history.records.isEmpty)
    }

    func testOriginalProgressCallbackCannotCancelOrRetryFreshTextRun() async throws {
        let nextGate = Gate()
        defer { nextGate.release() }
        var captureCount = 0, copies = 0
        let f = try fixture { _ in
            self.dependencies(capture: {
                captureCount += 1
                if captureCount == 2 { await nextGate.wait(); throw CaptureError.cancelled }
                return try ChainCapture(image: self.raster())
            }, copy: { _ in copies += 1; throw FixtureError.copy })
        }
        defer { f.close() }
        XCTAssertTrue(f.app.runTextScript(id: f.script.id))
        let first = try XCTUnwrap(f.app.activeCaptureChain)
        try await until { first.status.canRetry }
        let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
        let cancel = try XCTUnwrap(manager.onCancel), retry = try XCTUnwrap(manager.onRetry)
        let close = try XCTUnwrap(manager.onClose), generation = manager.commandGeneration
        close(first.id, generation)
        try await until { first.status == .cancelled && f.app.activeCaptureChain == nil }
        XCTAssertTrue(f.app.runTextScript(id: f.script.id))
        let second = try XCTUnwrap(f.app.activeCaptureChain)
        try await until { nextGate.waiting }
        cancel(first.id, generation); retry(first.id, generation); close(first.id, generation)
        XCTAssertTrue(f.app.activeCaptureChain === second)
        XCTAssertEqual(second.status, .capturing); XCTAssertEqual(copies, 1)
        nextGate.release()
        try await until { second.status == .cancelled && f.app.activeCaptureChain == nil }
        XCTAssertEqual(captureCount, 2); XCTAssertEqual(copies, 1)
    }

    func testQuitPreservesUnsavedScriptUntilExplicitDiscard() throws {
        let f = try fixture { _ in self.dependencies(capture: { throw CaptureError.cancelled }) }
        defer { f.close() }
        f.app.manageTextScripts()
        let editor = try XCTUnwrap(f.app.textScriptManagerForVerification)
        func button(_ suffix: String) throws -> NSButton {
            func find(_ view: NSView) -> NSButton? {
                if view.identifier?.rawValue == "text-script-" + suffix { return view as? NSButton }
                return view.subviews.lazy.compactMap(find).first
            }
            return try XCTUnwrap(find(try XCTUnwrap(editor.window?.contentView)))
        }
        let create = try button("create")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(create.action), to: create.target, from: create))
        XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(f.scripts.definitions, [f.script])
        XCTAssertTrue(editor.window?.isVisible == true)
        editor.window?.makeFirstResponder(nil)
        let discard = try button("discard")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(discard.action), to: discard.target, from: discard))
        XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateNow)
        XCTAssertEqual(f.scripts.definitions, [f.script])
    }

    func testRejectedNativeEditorStartReleasesCommandForNextAttempt() async throws {
        var requested = 0
        let f = try fixture { _ in
            requested += 1; return self.dependencies(capture: { throw CaptureError.cancelled })
        }
        defer { f.close() }
        try f.scripts.select(id: f.script.id)
        f.app.manageTextScripts()
        let editor = try XCTUnwrap(f.app.textScriptManagerForVerification)
        editor.window?.makeFirstResponder(nil)
        func findRun(_ view: NSView) -> NSButton? {
            if view.identifier?.rawValue == "text-script-run" { return view as? NSButton }
            return view.subviews.lazy.compactMap(findRun).first
        }
        let run = try XCTUnwrap(findRun(try XCTUnwrap(editor.window?.contentView)))
        XCTAssertTrue(run.isEnabled)
        f.app.busy = true
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(run.action), to: run.target, from: run))
        XCTAssertFalse(run.isEnabled)
        try await until { run.isEnabled }
        XCTAssertEqual(requested, 0); XCTAssertNil(f.app.activeCaptureChain)
        f.app.busy = false
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(run.action), to: run.target, from: run))
        try await until { requested == 1 && f.app.activeCaptureChain == nil }
        XCTAssertTrue(run.isEnabled)
    }

    func testUnavailableLegacyManagerFailsBeforeCaptureWithoutReadingUserCatalog() throws {
        var captureCount = 0
        let f = try fixture(provideImageStore: false) { _ in
            self.dependencies(capture: { captureCount += 1; return try ChainCapture(image: self.raster()) })
        }
        defer { f.close() }
        XCTAssertFalse(f.app.runTextScript(id: f.script.id))
        XCTAssertEqual(captureCount, 0); XCTAssertNil(f.app.activeCaptureChain)
        XCTAssertNotNil(f.app.textScriptManagerForVerification)
        XCTAssertEqual(f.scripts.definitions, [f.script])
        XCTAssertTrue(f.app.history.records.isEmpty)
    }

    func testEditorAdmissionRejectsTextBeforeDependenciesOrCapture() throws {
        var requested = 0, notices = 0
        let f = try fixture(admission: .init(maximumEditors: 1), notice: { notices += 1 }) { _ in
            requested += 1; return self.dependencies(capture: { throw CaptureError.cancelled })
        }
        defer { f.close() }
        XCTAssertTrue(f.app.openEditor(try raster(), showAdmissionNotice: false))
        XCTAssertFalse(f.app.runTextScript(id: f.script.id))
        XCTAssertEqual(notices, 1); XCTAssertEqual(requested, 0)
        XCTAssertNil(f.app.activeCaptureChain)
    }

    private struct Fixture {
        let root: URL, suite: String, defaults: UserDefaults
        let images: CaptureChainStore, scripts: TextScriptStore
        let image: CaptureChainDefinition, script: TextScriptDefinition, app: AppDelegate
        @MainActor func close() {
            _ = app.activeCaptureChain?.cancel()
            Array(app.controllers).forEach { $0.close() }; app.controllers.removeAll()
            app.mainWindow.close(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func fixture(provideImageStore: Bool = true, admission: EditorAdmissionPolicy = .init(), notice: @escaping () -> Void = {},
        imageDependencies: ((CaptureChainDefinition) throws -> CaptureChainRunner.Dependencies)? = nil,
        text: @escaping (TextScriptDefinition) throws -> CaptureChainRunner.TextDependencies) throws -> Fixture {
        _ = NSApplication.shared
        let root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: "PicShot-TextScriptApp-" + UUID().uuidString)
        let suite = "PicShot.TextScriptAppTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let images = try CaptureChainStore(directory: root.appendingPathComponent("image-chains"))
        let scripts = try TextScriptStore(directory: root.appendingPathComponent("text-scripts"))
        let image = try CaptureChainDefinition(name: "Saved image chain", source: .region, outputs: [.copy])
        let script = try TextScriptDefinition(name: "Saved text script", source: "return text;")
        try images.add(image); try scripts.add(script)
        let app = AppDelegate(history: HistoryStore(directory: root.appendingPathComponent("history")),
            isolatedDefaults: defaults, editorAdmission: admission, admissionNotice: notice,
            chainStore: provideImageStore ? images : nil, chainDependencies: imageDependencies,
            textScriptStore: scripts, textScriptDependencies: text)
        app.mainWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        app.mainWindow.isReleasedWhenClosed = false; app.mainWindow.animationBehavior = .none
        return Fixture(root: root, suite: suite, defaults: defaults, images: images, scripts: scripts,
                       image: image, script: script, app: app)
    }
    private func dependencies(capture: @escaping @MainActor () async throws -> ChainCapture,
                              copy: @escaping @MainActor (String) throws -> Void = { _ in }) -> CaptureChainRunner.TextDependencies {
        .init(capture: capture, recognize: { _ in ChainTextRecognition(text: "Generated OCR") },
              transform: { _, _, _ in .succeeded("Generated transformed text") }, copy: copy,
              cleanupComplete: { _ in true })
    }
    private func imageDependencies() -> CaptureChainRunner.Dependencies {
        .init(capture: { throw CaptureError.cancelled }, savePNG: { _ in .cancelled },
              copy: { _ in XCTFail("Unexpected image copy") }, pin: { _ in UUID() }, cancelSave: {})
    }
    private func raster() throws -> CGImage { try SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8) }
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "Text action did not reach its owned phase barrier")
    }
    private enum FixtureError: Error { case copy }
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var waiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { let pending = continuation; continuation = nil; pending?.resume() }
    }
}
