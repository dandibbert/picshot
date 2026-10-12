import AppKit
import PicShotCore
import XCTest
@testable import PicShot

/// Exercises the application's real admission, menu and manager wiring. Every
/// acquisition/output is injected; no screen, clipboard, pin session or global
/// input is used, and all persisted metadata belongs to the fixture directory.
@MainActor final class CaptureChainAppIntegrationTests: XCTestCase {
    func testNativeUnselectedDefaultAndExplicitSelectionDoNotAcquireOrRun() throws {
        try withApplicationLoop {
            let first = try self.definition("First"), second = try self.definition("Second")
            var dependencyRequests = 0
            let f = try self.fixture(definitions: [first, second]) { _ in
                dependencyRequests += 1
                return self.dependencies(capture: { throw CaptureError.cancelled })
            }
            defer { f.close() }
            let menu = f.app.captureChainsMenu()
            XCTAssertNil(f.store.selectedID)
            XCTAssertEqual(menu.items.filter { $0.representedObject != nil }.map(\.state), [.off, .off])
            let current = try self.currentItem(in: menu)
            XCTAssertEqual(current.title, "选择当前动作链…")
            XCTAssertTrue(current.keyEquivalent.isEmpty)
            try self.dispatch(current)
            let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertEqual(dependencyRequests, 0)
            XCTAssertTrue(manager.window?.isVisible == true)
            let guidance: NSTextField = try self.view("status", in: manager)
            XCTAssertTrue(guidance.stringValue.contains("请先保存动作链"))
            XCTAssertTrue(guidance.stringValue.contains("快捷键默认未分配"))

            let table: NSTableView = try self.view("list", in: manager)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try self.ready(manager)
            let select: NSButton = try self.view("select", in: manager)
            try PortableSettingsUIPreviewFixture.click(select)
            XCTAssertEqual(f.store.selectedID, second.id)
            XCTAssertEqual(dependencyRequests, 0, "Choosing a current chain must never run it")
            f.app.populateCaptureChainsMenu(menu)
            XCTAssertEqual(try self.currentItem(in: menu).title, "运行当前：Second")
            XCTAssertEqual(try self.item(first.id, in: menu).state, .off)
            XCTAssertEqual(try self.item(second.id, in: menu).state, .on)
            XCTAssertEqual(try CaptureChainStore(directory: f.store.directory).selectedID, second.id)
            XCTAssertTrue(f.app.history.records.isEmpty)
        }
    }

    func testRealMenuEntryReservesBeforeAcquisitionAndRefusesSecondRunAndCapture() async throws {
        let first = try definition("Selected"), second = try definition("Menu target")
        let gate = Gate<Void>()
        defer { gate.resolve(()) }
        var requests: [UUID] = [], acquisitions = 0, ordinaryAcquisitions = 0
        weak var delegate: AppDelegate?
        let f = try fixture(definitions: [first, second]) { definition in
            requests.append(definition.id)
            return self.dependencies(capture: {
                acquisitions += 1
                XCTAssertTrue(delegate?.hasActiveCaptureChain == true)
                XCTAssertEqual(delegate?.activeCaptureChain?.definition.id, definition.id)
                XCTAssertEqual(delegate?.activeCaptureChain?.status, .capturing)
                await gate.wait()
                throw CaptureError.cancelled
            })
        }
        delegate = f.app
        defer { f.close() }
        try f.store.select(id: first.id)
        f.app.mainWindow.orderFront(nil)
        let menu = f.app.captureChainsMenu()
        try dispatch(try item(second.id, in: menu))
        let runner = try XCTUnwrap(f.app.activeCaptureChain)
        XCTAssertEqual(runner.status, .capturing)
        XCTAssertTrue(runner.isAttemptRunning); XCTAssertTrue(f.app.hasActiveCaptureChain)
        XCTAssertEqual(acquisitions, 0, "The app reserves the run synchronously before its capture task executes")
        XCTAssertEqual(requests, [second.id]); XCTAssertEqual(f.store.selectedID, first.id)
        XCTAssertFalse(f.app.mainWindow.isVisible)
        XCTAssertFalse(f.app.runCaptureChain(id: first.id))
        f.app.populateCaptureChainsMenu(menu)
        XCTAssertFalse(try currentItem(in: menu).isEnabled)
        XCTAssertTrue(menu.items.filter { $0.representedObject != nil }.allSatisfy { !$0.isEnabled })
        f.app.mainWindow.orderFront(nil)
        f.app.runCaptureForEditing {
            ordinaryAcquisitions += 1
            return CapturedImage(image: try self.raster(), presentation: nil)
        }
        XCTAssertFalse(f.app.busy); XCTAssertTrue(f.app.mainWindow.isVisible)
        XCTAssertEqual(ordinaryAcquisitions, 0)
        try await until { gate.isWaiting }
        XCTAssertEqual(acquisitions, 1); XCTAssertEqual(requests, [second.id])
        XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertTrue(f.app.activeCaptureChain === runner)
        XCTAssertTrue(gate.resolve(()))
        try await until { runner.status == .cancelled && f.app.activeCaptureChain == nil }
        XCTAssertFalse(f.app.hasActiveCaptureChain); XCTAssertEqual(f.app.retainedChainBytes, 0)
        XCTAssertEqual(ordinaryAcquisitions, 0); XCTAssertTrue(f.app.history.records.isEmpty)
        f.app.populateCaptureChainsMenu(menu)
        XCTAssertTrue(try currentItem(in: menu).isEnabled)
        XCTAssertTrue(try item(second.id, in: menu).isEnabled)
        try dispatch(try currentItem(in: menu))
        let selectedRun = try XCTUnwrap(f.app.activeCaptureChain)
        XCTAssertEqual(selectedRun.definition.id, first.id)
        XCTAssertNotEqual(selectedRun.id, runner.id)
        XCTAssertEqual(requests, [second.id, first.id])
        try await until { gate.isWaiting }
        XCTAssertEqual(acquisitions, 2)
        XCTAssertTrue(gate.resolve(()))
        try await until { selectedRun.status == .cancelled && f.app.activeCaptureChain == nil }
        XCTAssertEqual(f.store.selectedID, first.id)
        XCTAssertEqual(ordinaryAcquisitions, 0); XCTAssertTrue(f.app.history.records.isEmpty)
    }

    func testRealRunRejectsFullEditorAdmissionBeforeDependenciesOrWindowHiding() throws {
        let definition = try definition()
        var notices = 0, requests = 0
        let f = try fixture(definitions: [definition], admission: .init(maximumEditors: 1),
                            notice: { notices += 1 }) { _ in
            requests += 1
            return self.dependencies(capture: { XCTFail("Admission must precede acquisition"); throw CaptureError.cancelled })
        }
        defer { f.close() }
        XCTAssertTrue(f.app.openEditor(try raster(), showAdmissionNotice: false))
        f.app.mainWindow.orderFront(nil)
        XCTAssertFalse(f.app.runCaptureChain(id: definition.id))
        XCTAssertEqual(notices, 1); XCTAssertEqual(requests, 0)
        XCTAssertNil(f.app.activeCaptureChain); XCTAssertFalse(f.app.busy)
        XCTAssertTrue(f.app.mainWindow.isVisible)
        XCTAssertNil(f.app.captureChainManagerForVerification)
        XCTAssertTrue(f.app.history.records.isEmpty)
    }

    func testRetryableAppRunBlocksQuitAndCaptureThenReusesAndReleasesItsExactRaster() async throws {
        let definition = try definition(outputs: [.pin, .copy]), counter = CaptureTestProviderCounter()
        let capturedAt = Date(timeIntervalSince1970: 12_345), pinID = UUID()
        var acquisitions = 0, copies = 0, pins = 0, ordinaryAcquisitions = 0
        var identity: ObjectIdentifier?, originalPixels: Data?, order: [CaptureChainOutput] = []
        let f = try fixture(definitions: [definition]) { _ in
            self.dependencies(capture: {
                acquisitions += 1
                let image = try CaptureTestProviderCounter.image(width: 8, height: 8, counter: counter)
                identity = ObjectIdentifier(image)
                originalPixels = try SaveWorkflowUIPreviewFixture.pixels(image)
                return try ChainCapture(image: image, capturedAt: capturedAt, encodedBackingBytes: 37)
            }, copy: { image in
                copies += 1; order.append(.copy)
                XCTAssertEqual(ObjectIdentifier(image), identity)
                XCTAssertEqual(try SaveWorkflowUIPreviewFixture.pixels(image), originalPixels)
                if copies == 1 { throw FixtureError.output }
            }, pin: { image in
                pins += 1; order.append(.pin)
                XCTAssertEqual(ObjectIdentifier(image), identity)
                return pinID
            })
        }
        defer { f.close() }
        let defaultsBefore = f.defaults.persistentDomain(forName: f.suite) as NSDictionary?
        let manifest = f.store.directory.appendingPathComponent(CaptureChainStore.manifestFilename)
        let definitionBytes = try Data(contentsOf: manifest)
        XCTAssertTrue(f.app.runCaptureChain(id: definition.id))
        let runner = try XCTUnwrap(f.app.activeCaptureChain)
        try await until { runner.status.canRetry }
        let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
        XCTAssertTrue(f.app.hasActiveCaptureChain)
        XCTAssertEqual(f.app.retainedChainBytes, 8 * 8 * 4 + 37)
        XCTAssertEqual(counter.liveBytes, 8 * 8 * 4); XCTAssertEqual(counter.deallocations, 0)
        XCTAssertEqual(runner.capturedAt, capturedAt)
        XCTAssertEqual(manager.displayedSnapshot?.capturedAt, capturedAt)
        XCTAssertEqual(runner.receipts, [.init(output: .pin, value: .pinned(pinID))])
        XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertFalse(f.app.runCaptureChain(id: definition.id))
        f.app.mainWindow.orderFront(nil)
        f.app.runCaptureForEditing {
            ordinaryAcquisitions += 1
            return CapturedImage(image: try self.raster(), presentation: nil)
        }
        XCTAssertFalse(f.app.busy); XCTAssertTrue(f.app.mainWindow.isVisible)
        XCTAssertEqual(ordinaryAcquisitions, 0); XCTAssertEqual(acquisitions, 1)
        try press("retry", in: manager)
        try await until { runner.status == .completed && f.app.activeCaptureChain == nil && counter.liveBytes == 0 }
        XCTAssertEqual(acquisitions, 1); XCTAssertEqual(pins, 1); XCTAssertEqual(copies, 2)
        XCTAssertEqual(order, [.pin, .copy, .copy]); XCTAssertEqual(ordinaryAcquisitions, 0)
        XCTAssertEqual(counter.callbacks, 1); XCTAssertEqual(counter.deallocations, 1)
        XCTAssertNil(runner.capture); XCTAssertEqual(f.app.retainedChainBytes, 0)
        XCTAssertFalse(f.app.hasActiveCaptureChain)
        XCTAssertEqual(manager.displayedSnapshot?.status, .completed)
        XCTAssertEqual(manager.displayedSnapshot?.retainedBytes, 0)
        XCTAssertEqual(manager.displayedSnapshot?.receipts,
            [.init(output: .pin, value: .pinned(pinID)), .init(output: .copy, value: .copied)])
        XCTAssertTrue(manager.window?.isVisible == true, "An open receipt window must not retain the completed raster")
        XCTAssertEqual(try Data(contentsOf: manifest), definitionBytes)
        XCTAssertEqual(f.defaults.persistentDomain(forName: f.suite) as NSDictionary?, defaultsBefore)
        XCTAssertTrue(f.app.history.records.isEmpty)
        XCTAssertEqual(f.app.applicationShouldTerminate(NSApp), .terminateNow)
    }

    func testFailedChainBytesRemainInEditorAdmissionIncludingExactPendingTransfer() async throws {
        let image = try raster(), differentImage = try raster()
        let definition = try definition(), chainEncoded = 83, pendingEncoded = 41
        let chainBytes = image.bytesPerRow * image.height + chainEncoded
        let incomingBytes = EditorRasterEstimate.openingBytes(image: image, presentation: nil) + pendingEncoded
        for oneByteShort in [true, false] {
            let f = try fixture(definitions: [definition],
                admission: .init(maximumRasterBytes: incomingBytes + chainBytes - (oneByteShort ? 1 : 0))) { _ in
                self.dependencies(capture: { try ChainCapture(image: image, encodedBackingBytes: chainEncoded) },
                                  copy: { _ in throw FixtureError.output })
            }
            defer { f.close() }
            XCTAssertTrue(f.app.runCaptureChain(id: definition.id))
            let runner = try XCTUnwrap(f.app.activeCaptureChain)
            try await until { runner.status.canRetry }
            XCTAssertEqual(f.app.retainedChainBytes, chainBytes)
            if oneByteShort {
                XCTAssertFalse(f.app.openEditor(image, encodedBackingBytes: pendingEncoded, showAdmissionNotice: false),
                    "Ordinary editor admission includes both the chain raster and encoded backing")
            }
            let pending = try PendingCapture(CapturedImage(image: image, presentation: nil,
                capturedAt: Date(timeIntervalSince1970: 987), encodedBackingBytes: pendingEncoded), title: "Pending fixture")
            try f.app.pendingCaptureRecovery.retain(pending, error: FixtureError.output)
            XCTAssertFalse(f.app.openEditor(image, encodedBackingBytes: pendingEncoded, showAdmissionNotice: false))
            XCTAssertFalse(f.app.openEditor(image, encodedBackingBytes: pendingEncoded,
                transferringPendingID: UUID(), showAdmissionNotice: false))
            XCTAssertFalse(f.app.openEditor(differentImage, encodedBackingBytes: pendingEncoded,
                transferringPendingID: pending.id, showAdmissionNotice: false), "A matching ID alone cannot remove a reservation")
            let transferred = f.app.pendingCaptureRecovery.retryEditor { capture in
                f.app.openEditor(capture.image, captureDate: capture.capturedAt,
                    encodedBackingBytes: capture.encodedBackingBytes, transferringPendingID: capture.id,
                    showAdmissionNotice: false)
            }
            XCTAssertEqual(transferred, !oneByteShort)
            XCTAssertEqual(f.app.retainedChainBytes, chainBytes, "Pending transfer must never subtract the chain reservation")
            XCTAssertTrue(f.app.activeCaptureChain === runner)
            if oneByteShort {
                XCTAssertEqual(f.app.pendingCaptureRecovery.pending?.id, pending.id)
                XCTAssertTrue(f.app.controllers.compactMap { $0 as? ImageEditorController }.isEmpty)
            } else {
                XCTAssertNil(f.app.pendingCaptureRecovery.pending)
                XCTAssertEqual(f.app.controllers.compactMap { $0 as? ImageEditorController }.count, 1)
            }
            XCTAssertTrue(runner.cancel())
            XCTAssertNil(f.app.activeCaptureChain); XCTAssertEqual(f.app.retainedChainBytes, 0)
            if oneByteShort {
                XCTAssertTrue(f.app.pendingCaptureRecovery.retryEditor { capture in
                    f.app.openEditor(capture.image, captureDate: capture.capturedAt,
                        encodedBackingBytes: capture.encodedBackingBytes, transferringPendingID: capture.id,
                        showAdmissionNotice: false)
                }, "Releasing the chain reopens the same pending handoff without changing its pixels")
                XCTAssertNil(f.app.pendingCaptureRecovery.pending)
            }
            XCTAssertTrue(f.app.history.records.isEmpty)
        }
    }

    func testStaleManagerAndRunnerCallbacksCannotChangeOrCancelFreshAppRun() async throws {
        let definition = try definition(), gate = Gate<Void>()
        defer { gate.resolve(()) }
        var requests = 0, acquisitions = 0, copies = 0
        let f = try fixture(definitions: [definition]) { _ in
            requests += 1
            let attempt = requests
            return self.dependencies(capture: {
                acquisitions += 1
                if attempt == 2 { await gate.wait() }
                return try ChainCapture(image: self.raster())
            }, copy: { _ in copies += 1; throw FixtureError.output })
        }
        defer { f.close() }
        XCTAssertTrue(f.app.runCaptureChain(id: definition.id))
        let old = try XCTUnwrap(f.app.activeCaptureChain)
        try await until { old.status.canRetry }
        let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
        let staleRun = try XCTUnwrap(manager.onRun), staleRetry = try XCTUnwrap(manager.onRetry)
        let staleCancel = try XCTUnwrap(manager.onCancel), staleClose = try XCTUnwrap(manager.onClose)
        let staleChange = try XCTUnwrap(old.onChange), staleTerminal = try XCTUnwrap(old.onTerminal)
        let generation = manager.commandGeneration, oldFailure = old.snapshot
        try press("cancel", in: manager)
        XCTAssertEqual(old.status, .cancelled); XCTAssertNil(f.app.activeCaptureChain)
        XCTAssertFalse(manager.isCurrentCommand(generation))
        staleRun(definition.id, generation)
        XCTAssertNil(f.app.activeCaptureChain); XCTAssertEqual(requests, 1)
        XCTAssertTrue(f.app.runCaptureChain(id: definition.id))
        let fresh = try XCTUnwrap(f.app.activeCaptureChain)
        XCTAssertNotEqual(old.id, fresh.id)
        try await until { gate.isWaiting }
        let capturing = fresh.snapshot
        staleChange(oldFailure); staleTerminal(old.snapshot)
        staleCancel(fresh.id, generation); staleRetry(fresh.id, generation)
        staleClose(old.id, manager.commandGeneration)
        staleCancel(old.id, manager.commandGeneration)
        XCTAssertTrue(f.app.activeCaptureChain === fresh)
        XCTAssertEqual(fresh.status, .capturing); XCTAssertEqual(manager.displayedSnapshot, capturing)
        XCTAssertEqual(requests, 2); XCTAssertEqual(acquisitions, 2); XCTAssertEqual(copies, 1)
        XCTAssertTrue(gate.resolve(()))
        try await until { fresh.status.canRetry }
        let retryable = fresh.snapshot
        staleRetry(old.id, manager.commandGeneration); staleRetry(fresh.id, generation)
        staleClose(old.id, manager.commandGeneration); staleCancel(old.id, manager.commandGeneration)
        staleChange(oldFailure); staleTerminal(old.snapshot)
        XCTAssertEqual(fresh.snapshot, retryable); XCTAssertEqual(manager.displayedSnapshot, retryable)
        XCTAssertTrue(f.app.activeCaptureChain === fresh)
        XCTAssertEqual(copies, 2); XCTAssertEqual(requests, 2)
        try press("close", in: manager)
        XCTAssertEqual(fresh.status, .cancelled); XCTAssertNil(f.app.activeCaptureChain)
        XCTAssertEqual(f.app.retainedChainBytes, 0)
        XCTAssertFalse(manager.window?.isVisible ?? true)
        XCTAssertTrue(f.app.history.records.isEmpty)
    }

    func testOpenAppManagerRefreshesInjectedPresetCreateRenameAndDelete() throws {
        let preset = try preset(), definition = try CaptureChainDefinition(name: "Preset chain",
            source: .preset(preset.id), outputs: [.copy])
        var requests = 0
        let f = try fixture(definitions: [definition]) { _ in
            requests += 1
            return self.dependencies(capture: { throw CaptureError.cancelled })
        }
        defer { f.close() }
        f.app.manageCaptureChains()
        let manager = try XCTUnwrap(f.app.captureChainManagerForVerification)
        let table: NSTableView = try view("list", in: manager)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let source: NSPopUpButton = try view("source", in: manager)
        let run: NSButton = try view("run", in: manager)
        XCTAssertFalse(run.isEnabled)
        XCTAssertEqual(source.selectedItem?.representedObject as? UUID, preset.id)
        try f.presets.add(preset)
        XCTAssertTrue(run.isEnabled)
        XCTAssertEqual(source.titleOfSelectedItem, "预设：" + preset.name)
        try f.presets.rename(id: preset.id, name: "Renamed source")
        XCTAssertEqual(source.titleOfSelectedItem, "预设：Renamed source")
        XCTAssertEqual(source.selectedItem?.representedObject as? UUID, preset.id)
        try f.presets.remove(id: preset.id)
        XCTAssertFalse(run.isEnabled); XCTAssertTrue(source.titleOfSelectedItem?.contains("不可用") == true)
        XCTAssertEqual(f.store.definition(id: definition.id)?.source, .preset(preset.id))
        f.app.manageCaptureChains()
        XCTAssertTrue(f.app.captureChainManagerForVerification === manager)
        XCTAssertFalse(run.isEnabled); XCTAssertEqual(requests, 0)
    }

    private struct Fixture {
        let root: URL, suite: String, defaults: UserDefaults
        let store: CaptureChainStore, presets: CapturePresetStore, app: AppDelegate
        @MainActor func close() {
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
    private func fixture(definitions: [CaptureChainDefinition], admission: EditorAdmissionPolicy = .init(),
                         notice: @escaping () -> Void = { XCTFail("Unexpected editor admission notice") },
                         dependencies: @escaping (CaptureChainDefinition) throws -> CaptureChainRunner.Dependencies) throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-ChainApp-" + UUID().uuidString)
        let suite = "PicShot.ChainAppTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = try CaptureChainStore(directory: root.appendingPathComponent("chains"))
        let presets = try CapturePresetStore(directory: root.appendingPathComponent("presets"))
        for definition in definitions { try store.add(definition) }
        let app = AppDelegate(history: HistoryStore(directory: root.appendingPathComponent("history")),
            isolatedDefaults: defaults, editorAdmission: admission, admissionNotice: notice,
            chainStore: store, presetStore: presets, chainDependencies: dependencies)
        app.mainWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        app.mainWindow.isReleasedWhenClosed = false; app.mainWindow.animationBehavior = .none
        return Fixture(root: root, suite: suite, defaults: defaults, store: store, presets: presets, app: app)
    }
    private func definition(_ name: String = "Fixture chain", outputs: [CaptureChainOutput] = [.copy]) throws -> CaptureChainDefinition {
        try CaptureChainDefinition(name: name, source: .region, outputs: outputs)
    }
    private func dependencies(capture: @escaping @MainActor () async throws -> ChainCapture,
                              copy: @escaping @MainActor (CGImage) throws -> Void = { _ in XCTFail("Unexpected copy") },
                              pin: @escaping @MainActor (CGImage) throws -> UUID = { _ in XCTFail("Unexpected pin"); return UUID() }) -> CaptureChainRunner.Dependencies {
        .init(capture: capture, savePNG: { _ in XCTFail("Unexpected save"); return .cancelled },
              copy: copy, pin: pin, cancelSave: {})
    }
    private func raster() throws -> CGImage { try SaveWorkflowUIPreviewFixture.sourceImage(width: 8, height: 8) }
    private func preset() throws -> CapturePreset {
        let display = try CapturePresetDisplay(uuid: UUID(), frame: .init(x: 0, y: 0, width: 800, height: 600),
            pixelWidth: 800, pixelHeight: 600, rotationDegrees: 0)
        return try CapturePreset(name: "Fixture source", delay: .none, display: display,
            topLeftFrame: .init(x: 10, y: 20, width: 200, height: 100),
            pixelFrame: .init(x: 10, y: 20, width: 200, height: 100))
    }
    private func currentItem(in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.action == #selector(AppDelegate.runSelectedCaptureChain) })
    }
    private func item(_ id: UUID, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.representedObject as? String == id.uuidString })
    }
    private func dispatch(_ item: NSMenuItem) throws {
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
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
    private func until(_ condition: () -> Bool) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, "App integration did not reach its explicit capture/output barrier")
    }
    private enum FixtureError: LocalizedError {
        case output
        var errorDescription: String? { "Fixture output failed" }
    }
    @MainActor private final class Gate<Value> {
        private var continuation: CheckedContinuation<Value, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                precondition(self.continuation == nil); self.continuation = continuation
            }
        }
        @discardableResult func resolve(_ value: Value) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil; continuation.resume(returning: value); return true
        }
    }

    private func ready(_ manager: CaptureChainController) throws {
        let window = try XCTUnwrap(manager.window)
        window.animationBehavior = .none; manager.present(); NSApp.activate(ignoringOtherApps: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !window.isKeyWindow, ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        _ = try XCTUnwrap(window.isKeyWindow ? true : nil, "Owned manager did not become key")
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }

    /// Same bounded host contract as CaptureChainControllerTests: borrow a live
    /// application loop, or own/stop only this loop and restore activation policy.
    private func withApplicationLoop(_ body: @escaping @MainActor () throws -> Void) throws {
        _ = NSApplication.shared
        if NSApp.isRunning { try body(); return }
        _ = try XCTUnwrap(NSApp.modalWindow == nil && NSApp.delegate == nil ? true : nil,
            "Standalone UI host unexpectedly has a modal window or application delegate")
        _ = try XCTUnwrap(UserDefaults.standard.object(forKey: "NSOpen") == nil ? true : nil,
            "Standalone UI host unexpectedly has a file-open request")
        let originalPolicy = NSApp.activationPolicy(), state = CaptureChainAppTestApplicationLoop()
        defer {
            state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
            if NSApp.activationPolicy() != originalPolicy { _ = NSApp.setActivationPolicy(originalPolicy) }
            XCTAssertEqual(NSApp.activationPolicy(), originalPolicy)
        }
        if originalPolicy == .prohibited {
            _ = try XCTUnwrap(NSApp.setActivationPolicy(.accessory) ? true : nil,
                "Native chain integration requires an activatable owned application")
        }
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        func finish(_ result: Result<Void, Error>) {
            guard state.acceptsCallbacks, state.result == nil else { return }
            state.timer?.invalidate(); state.timer = nil; state.result = result
            NSApp.stop(nil); NSApp.postEvent(wake, atStart: true)
        }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                guard state.acceptsCallbacks else { return }
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard state.acceptsCallbacks, state.result == nil else { return }
                        if NSApp.isRunning && !state.activationRequested {
                            state.activationRequested = true; NSApp.activate(ignoringOtherApps: true)
                        }
                        if NSApp.isRunning && NSApp.isActive {
                            state.timer?.invalidate(); state.timer = nil; finish(Result { try body() })
                        } else if ProcessInfo.processInfo.systemUptime >= deadline {
                            finish(.failure(NSError(domain: "PicShot.CaptureChainAppTestHost", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Owned application loop did not become active within one second"])))
                        }
                    }
                }
                state.timer = timer; RunLoop.main.add(timer, forMode: .default)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain()); NSApp.run()
        state.acceptsCallbacks = false; state.timer?.invalidate(); state.timer = nil
        XCTAssertFalse(NSApp.isRunning)
        try XCTUnwrap(state.result, "Owned application loop exited before its test body completed").get()
    }
}

@MainActor private final class CaptureChainAppTestApplicationLoop {
    var result: Result<Void, Error>?
    var timer: Timer?
    var acceptsCallbacks = true
    var activationRequested = false
}
