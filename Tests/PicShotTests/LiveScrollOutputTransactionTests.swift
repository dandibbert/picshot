import XCTest
import AppKit
import PicShotCore
@testable import PicShot

/// Owned frames and native controls exercise recipient acceptance and draft
/// ownership. No user clipboard, pin store, save panel or permissions are used.
@MainActor
final class LiveScrollOutputTransactionTests: XCTestCase {
    func testCopyFailureRetainsVerticalPendingFrontierAndRetryDeliversIdenticalPixelsOnce() async throws {
        try await verifyCopyRetry(axis: .vertical)
    }

    func testCopyFailureRetainsHorizontalPendingFrontierAndRetryDeliversIdenticalPixelsOnce() async throws {
        try await verifyCopyRetry(axis: .horizontal)
    }

    private func verifyCopyRetry(axis: ScrollAxis) async throws {
        try await withSession(axis: axis) { fixture in
            try await fixture.extendPendingFrontier(axis: axis)
            let before = fixture.session.stateForVerification
            XCTAssertTrue(before.previewIsTransient)
            let durableBefore = try await fixture.document()
            XCTAssertEqual(durableBefore.sourceCount, 2)
            fixture.output.copyFailure = Failure.copy
            try PortableSettingsUIPreviewFixture.click(fixture.toolbar().copyButton)
            try await Self.wait { fixture.output.copyAttempts.count == 1 && !fixture.session.snapshotForVerification.busy }
            fixture.assertRecoverable(kind: .error)
            XCTAssertEqual(fixture.session.stateForVerification.width, before.width)
            XCTAssertEqual(fixture.session.stateForVerification.height, before.height)
            XCTAssertEqual(fixture.session.stateForVerification.acceptedObservations, before.acceptedObservations)
            XCTAssertTrue(fixture.output.copies.isEmpty)
            try Self.assertPixels(XCTUnwrap(fixture.output.copyAttempts.first), axis: axis, length: 243)
            let retained = try await fixture.document()
            XCTAssertEqual(retained.sourceCount, 3, "Finish must durably flush the last 19 pixels before recipient delivery")
            XCTAssertEqual(retained.width, before.width); XCTAssertEqual(retained.height, before.height)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)

            fixture.output.copyFailure = nil
            try PortableSettingsUIPreviewFixture.click(fixture.toolbar().copyButton)
            try await Self.wait { fixture.session.isClosedForVerification }
            XCTAssertEqual(fixture.output.copyAttempts.count, 2)
            XCTAssertEqual(fixture.output.copies.count, 1)
            XCTAssertEqual(try Self.pixels(fixture.output.copyAttempts[0]), try Self.pixels(fixture.output.copyAttempts[1]))
            try Self.assertPixels(XCTUnwrap(fixture.output.copies.first), axis: axis, length: 243)
            XCTAssertTrue(fixture.output.edits.isEmpty); XCTAssertTrue(fixture.output.pins.isEmpty)
            XCTAssertEqual(fixture.output.closes, 1)
        }
    }

    func testPinCapacityAndStorageRefusalsRetainDraftForAnotherOutput() async throws {
        for refusal in [Failure.pinCapacity, .pinStorage] {
            try await withSession { fixture in
                try await fixture.extendPendingFrontier(axis: .vertical)
                fixture.output.pinFailure = refusal
                try fixture.dispatch("pin")
                try await Self.wait { fixture.output.pinAttempts.count == 1 && !fixture.session.snapshotForVerification.busy }
                fixture.assertRecoverable(kind: .error)
                XCTAssertTrue(fixture.output.pins.isEmpty)
                try Self.assertPixels(XCTUnwrap(fixture.output.pinAttempts.first), axis: .vertical, length: 243)
                let retained = try await fixture.document()
                XCTAssertEqual(retained.height, 243); XCTAssertEqual(retained.sourceCount, 3)
                if refusal == .pinCapacity {
                    try PortableSettingsUIPreviewFixture.click(fixture.toolbar().copyButton)
                } else {
                    try PortableSettingsUIPreviewFixture.click(fixture.toolbar().finishButton)
                }
                try await Self.wait { fixture.session.isClosedForVerification }
                let delivered = refusal == .pinCapacity ? fixture.output.copies : fixture.output.edits
                XCTAssertEqual(delivered.count, 1)
                try Self.assertPixels(XCTUnwrap(delivered.first), axis: .vertical, length: 243)
                XCTAssertEqual(fixture.output.pinAttempts.count, 1)
                XCTAssertTrue(fixture.output.pins.isEmpty)
            }
        }
    }

    func testAsyncSaveCancellationAndWriteFailureKeepDraftUntilSuccessfulRetry() async throws {
        try await withSession { fixture in
            try await fixture.extendPendingFrontier(axis: .vertical)
            let controls = try XCTUnwrap(fixture.session.controlsForVerification)
            let toolbar = try fixture.toolbar()
            let originalMenu = try XCTUnwrap(toolbar.moreButton.menu)
            let failures: [Error] = [CancellationError(), Failure.save]
            for failure in failures {
                let expectedAttempts = fixture.save.images.count + 1
                try fixture.dispatch("quickSave")
                try await Self.wait { fixture.save.pending }
                XCTAssertEqual(fixture.save.images.count, expectedAttempts)
                let parent = try XCTUnwrap(fixture.save.parents.last ?? nil)
                XCTAssertTrue(parent === controls.toolbarWindow)
                XCTAssertTrue(fixture.session.snapshotForVerification.busy)
                XCTAssertFalse(try fixture.item("quickSave").isEnabled)
                XCTAssertFalse(try fixture.item("pin").isEnabled)
                XCTAssertFalse(toolbar.finishButton.isEnabled); XCTAssertFalse(toolbar.copyButton.isEnabled)
                XCTAssertTrue(toolbar.cancelButton.isEnabled)
                try Self.assertPixels(XCTUnwrap(fixture.save.images.last), axis: .vertical, length: 243)
                fixture.save.complete(throwing: failure)
                try await Self.wait { !fixture.session.snapshotForVerification.busy }
                fixture.assertRecoverable(kind: failure is CancellationError ? .paused : .error)
                XCTAssertTrue(fixture.save.accepted.isEmpty)
                XCTAssertTrue(toolbar.moreButton.menu === originalMenu)
                let retained = try await fixture.document()
                XCTAssertEqual(retained.sourceCount, 3); XCTAssertEqual(retained.height, 243)
            }
            try fixture.dispatch("quickSave")
            try await Self.wait { fixture.save.pending }
            fixture.save.complete()
            try await Self.wait { fixture.session.isClosedForVerification }
            XCTAssertEqual(fixture.save.images.count, 3); XCTAssertEqual(fixture.save.accepted.count, 1)
            for image in fixture.save.images { try Self.assertPixels(image, axis: .vertical, length: 243) }
            XCTAssertTrue(fixture.output.edits.isEmpty); XCTAssertTrue(fixture.output.copies.isEmpty)
            XCTAssertEqual(fixture.output.closes, 1)
        }
    }

    func testUnavailableManagedPinStoreUsesProductionRefusalAndPreservesDraftAndHistory() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-LiveOutput-App-Test-" + UUID().uuidString)
        let suite = "PicShot.LiveOutputTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(directory: root.appendingPathComponent("history"),
            policy: RetentionPolicy(maxItems: 10, maxBytes: 8_000_000, maxDays: 30))
        XCTAssertNil(history.loadError)
        let existing = try history.add(Self.image(axis: .vertical, origin: 100), title: "Owned history sentinel")
        let index = history.directory.appendingPathComponent("index.json")
        let catalogBefore = try Data(contentsOf: index)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: history.directory.path).sorted()
        let app = AppDelegate(history: history, isolatedDefaults: defaults)
        let refusal = NSError(domain: "LiveScrollOutputTransactionTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Injected persistent pin store unavailable"])
        app.pinSessionLoadError = refusal
        defer { app.pins.forEach { $0.close() } }
        XCTAssertNil(app.pinSession)

        try await withSession { fixture in
            try await fixture.extendPendingFrontier(axis: .vertical)
            fixture.output.pinRecipient = { try app.pinLongCapture($0) }
            try fixture.dispatch("pin")
            try await Self.wait { fixture.output.pinAttempts.count == 1 && !fixture.session.snapshotForVerification.busy }
            fixture.assertRecoverable(kind: .error)
            XCTAssertTrue(fixture.session.snapshotForVerification.status.contains(refusal.localizedDescription))
            XCTAssertTrue(app.pins.isEmpty, "A transient pin must not count as recoverable delivery")
            XCTAssertTrue(fixture.output.pins.isEmpty)
            XCTAssertEqual(history.records.map(\.id), [existing.id])
            XCTAssertEqual(try Data(contentsOf: index), catalogBefore)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.directory.path).sorted(), filesBefore)
            let retained = try await fixture.document()
            XCTAssertEqual(retained.height, 243)
            try PortableSettingsUIPreviewFixture.click(fixture.toolbar().copyButton)
            try await Self.wait { fixture.session.isClosedForVerification }
            XCTAssertEqual(fixture.output.copies.count, 1)
            try Self.assertPixels(XCTUnwrap(fixture.output.copies.first), axis: .vertical, length: 243)
            XCTAssertTrue(app.pins.isEmpty)
            XCTAssertEqual(history.records.map(\.id), [existing.id])
            XCTAssertEqual(try Data(contentsOf: index), catalogBefore)
        }
    }

    func testCaptureCancelRetiresDraftAndLateSaveCompletionCannotResurrectOrRedeliver() async throws {
        try await withSession { fixture in
            try await fixture.extendPendingFrontier(axis: .vertical)
            let controls = try XCTUnwrap(fixture.session.controlsForVerification)
            let toolbar = try fixture.toolbar()
            let ready = fixture.session.snapshotForVerification
            let saveItem = try fixture.item("quickSave"), pinItem = try fixture.item("pin")
            let saveAction = try XCTUnwrap(saveItem.action), pinAction = try XCTUnwrap(pinItem.action)
            let saveTarget = try XCTUnwrap(saveItem.target), pinTarget = try XCTUnwrap(pinItem.target)
            try fixture.dispatch("quickSave")
            try await Self.wait { fixture.save.pending }
            try PortableSettingsUIPreviewFixture.click(toolbar.cancelButton)
            try await Self.wait { fixture.session.isClosedForVerification }
            XCTAssertGreaterThan(fixture.save.cancelCalls, 0)
            XCTAssertEqual(fixture.output.closes, 1)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)

            // Deliberately ignore cancellation inside the injected recipient to
            // exercise the owner's generation guard after a late success.
            fixture.save.complete()
            try await Self.wait { fixture.save.returned == 1 }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNil(saveItem.action); XCTAssertNil(saveItem.target)
            XCTAssertNil(pinItem.action); XCTAssertNil(pinItem.target)
            XCTAssertTrue(controls.isRetired)
            controls.update(snapshot: ready)
            // Retirement disconnects the menu itself. Still deliver the exact
            // pre-retirement messages to their retained owner, while a fresh
            // session is active, to exercise the stale controller guard.
            try await self.withSession { successor in
                let successorReady = successor.session.snapshotForVerification
                XCTAssertTrue(NSApp.sendAction(saveAction, to: saveTarget, from: saveItem))
                XCTAssertTrue(NSApp.sendAction(pinAction, to: pinTarget, from: pinItem))
                for _ in 0..<20 { await Task.yield() }
                XCTAssertEqual(successor.session.snapshotForVerification, successorReady)
                XCTAssertFalse(successor.session.isClosedForVerification)
                XCTAssertTrue(successor.save.images.isEmpty)
                XCTAssertTrue(successor.output.edits.isEmpty); XCTAssertTrue(successor.output.copies.isEmpty)
                XCTAssertTrue(successor.output.pinAttempts.isEmpty)
                XCTAssertEqual(successor.output.closes, 0)
            }
            fixture.session.show()
            XCTAssertTrue(fixture.session.isClosedForVerification)
            XCTAssertNil(fixture.session.controlsForVerification)
            XCTAssertEqual(fixture.save.images.count, 1)
            XCTAssertEqual(fixture.output.closes, 1)
            XCTAssertTrue(fixture.output.edits.isEmpty); XCTAssertTrue(fixture.output.copies.isEmpty)
            XCTAssertTrue(fixture.output.pinAttempts.isEmpty)
        }
    }

    func testSuccessfulSaveWithStopWarningIsTerminalAndStaleMoreActionsCannotDuplicate() async throws {
        try await withSession { fixture in
            let controls = try XCTUnwrap(fixture.session.controlsForVerification)
            let toolbar = try fixture.toolbar()
            let ready = fixture.session.snapshotForVerification
            fixture.source.refusePause = true
            try fixture.dispatch("quickSave")
            try await Self.wait { fixture.save.pending }
            fixture.save.complete()
            try await Self.wait { !fixture.session.snapshotForVerification.busy }
            let warning = fixture.session.snapshotForVerification.status
            XCTAssertTrue(warning.contains("长图已保存")); XCTAssertTrue(warning.contains("采集停止未确认"))
            XCTAssertEqual(fixture.session.snapshotForVerification.statusKind, .warning)
            XCTAssertFalse(fixture.session.isClosedForVerification)
            XCTAssertEqual(fixture.save.accepted.count, 1)
            Self.assertTerminal(fixture.session.snapshotForVerification)
            XCTAssertFalse(try fixture.item("quickSave").isEnabled)
            XCTAssertFalse(try fixture.item("pin").isEnabled)

            for action in ["quickSave", "pin", "axis.horizontal", "import"] {
                controls.update(snapshot: ready)
                try fixture.dispatch(action, requireEnabled: false)
                fixture.session.show()
                Self.assertTerminal(fixture.session.snapshotForVerification)
                XCTAssertEqual(fixture.session.snapshotForVerification.status, warning)
            }
            for button in [toolbar.finishButton, toolbar.copyButton, toolbar.pauseButton] {
                controls.update(snapshot: ready)
                try PortableSettingsUIPreviewFixture.click(button)
                fixture.session.show()
            }
            try fixture.dispatch("help")
            XCTAssertEqual(fixture.session.snapshotForVerification.status, warning)
            XCTAssertEqual(fixture.save.images.count, 1); XCTAssertEqual(fixture.save.accepted.count, 1)
            XCTAssertTrue(fixture.output.pinAttempts.isEmpty)
            XCTAssertTrue(fixture.output.edits.isEmpty); XCTAssertTrue(fixture.output.copies.isEmpty)
            XCTAssertEqual(fixture.source.resumeCalls, 0); XCTAssertEqual(fixture.source.pauseCalls, 1)
            XCTAssertTrue(toolbar.cancelButton.isEnabled)
            try PortableSettingsUIPreviewFixture.click(toolbar.cancelButton)
            try await Self.wait { fixture.session.isClosedForVerification }
            XCTAssertEqual(fixture.output.closes, 1)
        }
    }

    func testNativeMoreItemsRequireConfiguredRecipientsAndIgnoreForcedUnavailableActions() async throws {
        try await withSession(outputsAvailable: false) { fixture in
            let controls = try XCTUnwrap(fixture.session.controlsForVerification)
            XCTAssertFalse(fixture.session.snapshotForVerification.canQuickSave)
            XCTAssertFalse(fixture.session.snapshotForVerification.canPin)
            XCTAssertFalse(try fixture.item("quickSave").isEnabled)
            XCTAssertFalse(try fixture.item("pin").isEnabled)
            var stale = fixture.session.snapshotForVerification
            stale.canQuickSave = true; stale.canPin = true
            controls.update(snapshot: stale)
            try fixture.dispatch("quickSave"); try fixture.dispatch("pin")
            XCTAssertFalse(fixture.session.snapshotForVerification.busy)
            XCTAssertEqual(fixture.source.pauseCalls, 0)
            XCTAssertTrue(fixture.save.images.isEmpty); XCTAssertTrue(fixture.output.pinAttempts.isEmpty)
            try PortableSettingsUIPreviewFixture.click(fixture.toolbar().finishButton)
            try await Self.wait { fixture.session.isClosedForVerification }
            XCTAssertEqual(fixture.output.edits.count, 1)
        }
    }

    func testPinPreflightAcceptsExactly32MillionPixelsAndRejectsOverflowWithoutAllocation() {
        for size in [(8_000, 4_000), (4_000, 8_000), (32_000_000, 1), (1, 32_000_000)] {
            XCTAssertTrue(LiveScrollSessionController.canPin(width: size.0, height: size.1))
        }
        for size in [(8_001, 4_000), (4_000, 8_001), (32_000_001, 1), (1, 32_000_001),
                     (0, 1), (1, 0), (-1, 1), (1, -1), (Int.max, Int.max), (Int.max, 2)] {
            XCTAssertFalse(LiveScrollSessionController.canPin(width: size.0, height: size.1))
        }
    }

    private func withSession(axis: ScrollAxis = .vertical, outputsAvailable: Bool = true,
                             _ body: (Fixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("A native macOS screen is required for session controls") }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-LiveOutput-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture(root: root, screen: screen, outputsAvailable: outputsAvailable)
        do {
            try await fixture.session.startForVerification(source: fixture.source, screen: screen)
            try await fixture.deliver(Self.image(axis: axis, origin: 0))
            if axis == .horizontal {
                try fixture.dispatch("axis.horizontal")
                try await Self.wait { fixture.session.snapshotForVerification.axis == axis && !fixture.session.snapshotForVerification.busy && fixture.source.waiting }
            }
            try await body(fixture)
        } catch {
            await fixture.session.closeForVerification()
            fixture.save.complete(throwing: CancellationError())
            throw error
        }
        await fixture.session.closeForVerification()
        fixture.save.complete(throwing: CancellationError())
        XCTAssertTrue(fixture.session.isClosedForVerification)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func dispatch(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    private static func assertTerminal(_ snapshot: LiveScrollCaptureSnapshot) {
        XCTAssertFalse(snapshot.canFinish); XCTAssertFalse(snapshot.canCopy)
        XCTAssertFalse(snapshot.canQuickSave); XCTAssertFalse(snapshot.canPin)
        XCTAssertFalse(snapshot.canPause); XCTAssertFalse(snapshot.canMoveRegion)
        XCTAssertFalse(snapshot.canAutoScroll); XCTAssertFalse(snapshot.canChangeAxis); XCTAssertFalse(snapshot.canImport)
    }

    /// Independent absolute-coordinate texture, shared only by owned input and
    /// expected output, never by the assembler or its strip serialization.
    private static func image(axis: ScrollAxis, origin: Int, length: Int = 200) throws -> CGImage {
        let width = axis == .vertical ? 64 : length, height = axis == .vertical ? length : 64
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let along = (axis == .vertical ? y : x) + origin + 10_000
            let across = axis == .vertical ? x : y
            var value = UInt64(along) &* 0x9e3779b185ebca87
            value ^= UInt64(across) &* 0xc2b2ae3d27d4eb4f; value ^= 7
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb; value ^= value >> 31
            let pixel = UInt8(value % 216 + 20), index = (y * width + x) * 4
            data[index] = pixel; data[index + 1] = pixel; data[index + 2] = pixel
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private static func assertPixels(_ output: CGImage, axis: ScrollAxis, length: Int) throws {
        let expected = try image(axis: axis, origin: 0, length: length)
        XCTAssertEqual(output.width, expected.width); XCTAssertEqual(output.height, expected.height)
        XCTAssertEqual(try pixels(output), try pixels(expected))
    }

    private enum Failure: Error, Equatable { case copy, pinCapacity, pinStorage, save, stop, timedOut }
    @MainActor private final class Output {
        var copyFailure: Error?, pinFailure: Error?
        var pinRecipient: ((CGImage) throws -> Void)?
        var copyAttempts: [CGImage] = [], pinAttempts: [CGImage] = []
        var copies: [CGImage] = [], pins: [CGImage] = [], edits: [CGImage] = []
        var closes = 0
    }

    @MainActor private final class Save: LiveScrollSaveDestination {
        var images: [CGImage] = [], accepted: [CGImage] = [], parents: [NSWindow?] = []
        var cancelCalls = 0, returned = 0
        var pending: Bool { continuation != nil }
        private var continuation: CheckedContinuation<Void, Error>?
        func save(image: CGImage, parent: NSWindow?) async throws {
            images.append(image); parents.append(parent)
            defer { returned += 1 }
            try await withCheckedThrowingContinuation { continuation = $0 }
            accepted.append(image)
        }
        func cancel() { cancelCalls += 1 }
        func complete(throwing error: Error? = nil) {
            let held = continuation; continuation = nil
            if let error { held?.resume(throwing: error) } else { held?.resume() }
        }
    }

    @MainActor private final class Fixture {
        let root: URL
        let source: Source
        let output: Output
        let save: Save
        let session: LiveScrollSessionController
        init(root: URL, screen: NSScreen, outputsAvailable: Bool) {
            let source = Source(displayBounds: CGDisplayBounds(screen.displayID ?? 0))
            let output = Output(), save = Save()
            self.root = root; self.source = source; self.output = output; self.save = save
            let pin: ((CGImage) throws -> Void)? = outputsAvailable ? { image in
                output.pinAttempts.append(image)
                if let error = output.pinFailure { throw error }
                try output.pinRecipient?(image)
                output.pins.append(image)
            } : nil
            session = LiveScrollSessionController(onComplete: { output.edits.append($0) },
                onImport: { XCTFail("An output transaction must not open an importer") }, onCopy: { image in
                    output.copyAttempts.append(image)
                    if let error = output.copyFailure { throw error }
                    output.copies.append(image)
                }, onPin: pin, saveDestination: outputsAvailable ? save : nil,
                resourceStorageParent: root, automaticScrollPermission: { false },
                automaticScrollInput: { _ in XCTFail("An output transaction must not send OS input") })
            session.onClose = { output.closes += 1 }
        }
        func toolbar() throws -> LiveScrollToolbarView {
            try XCTUnwrap(session.controlsForVerification?.toolbarWindow?.contentView as? LiveScrollToolbarView)
        }
        func item(_ suffix: String) throws -> NSMenuItem {
            try XCTUnwrap(toolbar().moreButton.menu?.items.first { $0.identifier?.rawValue == "scroll.live." + suffix })
        }
        func dispatch(_ suffix: String, requireEnabled: Bool = true) throws {
            let item = try item(suffix)
            if requireEnabled { XCTAssertTrue(item.isEnabled, suffix) }
            try LiveScrollOutputTransactionTests.dispatch(item)
        }
        func deliver(_ image: CGImage) async throws {
            try await LiveScrollOutputTransactionTests.wait { self.source.waiting }
            let previous = session.sampledFramesForVerification
            source.offer(image)
            try await LiveScrollOutputTransactionTests.wait { self.session.sampledFramesForVerification > previous && self.source.waiting }
        }
        func extendPendingFrontier(axis: ScrollAxis) async throws {
            try await deliver(LiveScrollOutputTransactionTests.image(axis: axis, origin: 24))
            try await deliver(LiveScrollOutputTransactionTests.image(axis: axis, origin: 43))
            XCTAssertTrue(session.stateForVerification.matched)
            XCTAssertEqual(session.stateForVerification.acceptedObservations, 3)
            XCTAssertTrue(session.stateForVerification.previewIsTransient)
        }
        func document() async throws -> LiveScrollDocument.Snapshot {
            let snapshot = await session.documentSnapshotForResourceVerification()
            return try XCTUnwrap(snapshot)
        }
        func assertRecoverable(kind: LiveScrollCaptureSnapshot.StatusKind) {
            let snapshot = session.snapshotForVerification
            XCTAssertTrue(snapshot.paused); XCTAssertFalse(snapshot.busy)
            XCTAssertEqual(snapshot.statusKind, kind)
            XCTAssertTrue(snapshot.canFinish); XCTAssertTrue(snapshot.canCopy)
            XCTAssertTrue(snapshot.canQuickSave); XCTAssertTrue(snapshot.canPin)
            XCTAssertFalse(session.isClosedForVerification)
        }
    }

    @MainActor private final class Source: LiveScrollFrameSource {
        let region = CGRect(x: 80, y: 80, width: 320, height: 240)
        let displayBounds: CGRect
        var target: LiveScrollScreenSource.Target? { nil }
        var waiting: Bool { reader != nil }
        var refusePause = false, pauseCalls = 0, resumeCalls = 0
        private var generation: UInt64 = 0, sequence: UInt64 = 0
        private var running = false
        private var reader: CheckedContinuation<LiveScrollScreenSource.Frame?, Error>?
        init(displayBounds: CGRect) { self.displayBounds = displayBounds }
        func start() async throws { generation &+= 1; running = true }
        func resume() async throws { resumeCalls += 1; try await start() }
        func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
            try Task.checkCancellation()
            guard running else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { reader = $0 }
        }
        func offer(_ image: CGImage) {
            sequence &+= 1
            let held = reader; reader = nil
            held?.resume(returning: .init(image: image, sequence: sequence, generation: generation,
                timestamp: TimeInterval(sequence), region: region))
        }
        func pauseAndDrain() async throws {
            pauseCalls += 1; drain()
            if refusePause { throw Failure.stop }
        }
        func stop() async throws { drain() }
        func validateTarget() throws { }
        func moveRegion(to proposed: CGRect) throws { }
        private func drain() {
            running = false
            let held = reader; reader = nil; held?.resume(throwing: CancellationError())
        }
    }
}
