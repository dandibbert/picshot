import XCTest
import AppKit
import PicShotCodecCore
@testable import PicShot

@MainActor
final class ImageExportControllerTests: XCTestCase {
    func testFormatControlsExposeQualityAndPDFOptionsThroughNativeActions() throws {
        _ = NSApplication.shared
        let view = ExportFormatAccessory()
        var changes = 0; view.onChange = { changes += 1 }
        XCTAssertEqual(view.options.format, .png)
        view.picker.selectItem(at: ImageExportFormat.jpeg.rawValue); try send(view.picker)
        view.quality.doubleValue = 37; try send(view.quality)
        XCTAssertEqual(view.options.quality, 0.37, accuracy: 0.001)
        view.picker.selectItem(at: ImageExportFormat.pdf.rawValue); try send(view.picker)
        view.paper.selectItem(at: ImageExportPaper.letter.rawValue); try send(view.paper)
        view.orientation.selectItem(at: ImageExportOrientation.landscape.rawValue); try send(view.orientation)
        view.margin.selectItem(withTag: 36); try send(view.margin)
        view.pagination.selectItem(at: ImageExportPagination.horizontal.rawValue); try send(view.pagination)
        XCTAssertEqual(view.options.paper, .letter); XCTAssertEqual(view.options.orientation, .landscape)
        XCTAssertEqual(view.options.margin, 36); XCTAssertEqual(view.options.pagination, .horizontal)
        XCTAssertEqual(changes, 7)
        view.setControlsEnabled(false)
        XCTAssertFalse(view.picker.isEnabled); XCTAssertFalse(view.paper.isEnabled); XCTAssertFalse(view.margin.isEnabled)
    }
    func testBundledCodecControlsAreHonestAndDisableLossyKnobsInLosslessMode() throws {
        _ = NSApplication.shared
        let view = ExportFormatAccessory()
        for format in [ImageExportFormat.webp, .avif] {
            view.picker.selectItem(at: format.rawValue); try send(view.picker)
            view.lossless.state = .off; try send(view.lossless)
            view.preserveAlpha.state = .on; try send(view.preserveAlpha)
            view.alphaQuality.doubleValue = 72; try send(view.alphaQuality)
            XCTAssertEqual(view.options.format, format); XCTAssertEqual(view.options.alphaQuality, 0.72)
            XCTAssertTrue(view.options.retainsAlpha); XCTAssertTrue(view.alphaQuality.isEnabled); XCTAssertTrue(view.quality.isEnabled)
            view.lossless.state = .on; try send(view.lossless)
            XCTAssertTrue(view.options.lossless); XCTAssertFalse(view.alphaQuality.isEnabled); XCTAssertFalse(view.quality.isEnabled)
            view.preserveAlpha.state = .off; try send(view.preserveAlpha)
            XCTAssertFalse(view.options.retainsAlpha)
        }
        view.setControlsEnabled(false)
        XCTAssertFalse(view.lossless.isEnabled); XCTAssertFalse(view.preserveAlpha.isEnabled); XCTAssertFalse(view.alphaQuality.isEnabled)
    }

    func testObsoleteBundledPreviewCannotReplaceLatestNativeOrEnableSaveAfterClose() async throws {
        let barrier = ImageExportTestBarrier()
        // Deliberately synthetic encoder verifies UI generation fences only.
        // Real codec bytes and signed-helper execution have separate native tests.
        let controller = try ImageExportController(image: fixture(), bundledEncoder: { snapshot, options in
            let png = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions())
            if barrier.claimFirst() { try await Task.detached { try barrier.pause() }.value }
            return ImageExportArtifact(data: png.data, options: options, width: png.width, height: png.height,
                                       pageCount: 1, firstPreview: png.firstPreview, sourceURL: nil)
        })
        defer { barrier.release(); controller.cancelExport() }
        controller.accessory.picker.selectItem(at: ImageExportFormat.webp.rawValue); try send(controller.accessory.picker)
        try await started(barrier)
        controller.accessory.picker.selectItem(at: ImageExportFormat.jpeg.rawValue); try send(controller.accessory.picker)
        let latest = try await ready(controller)
        XCTAssertEqual(latest.options.format, .jpeg)
        barrier.release(); try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.latestArtifact?.options.format, .jpeg)
        controller.accessory.picker.selectItem(at: ImageExportFormat.avif.rawValue); try send(controller.accessory.picker)
        controller.cancelExport(); try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(controller.latestArtifact); XCTAssertFalse(controller.saveButton.isEnabled)
    }

    func testBundledRetryWaitsForDelayedCleanupAndOnlyLatestChurnRequestWins() async throws {
        let probe = ImageExportDelayedAdmissionDouble()
        let controller = try ImageExportController(image: fixture(), bundledEncoder: { snapshot, options in
            try await ImageExportService.encodeBundled(snapshot: snapshot, options: options,
                prepare: { try await probe.prepare($0, $1) })
        })
        defer { probe.releaseFirst(); controller.cancelExport() }
        controller.accessory.picker.selectItem(at: ImageExportFormat.webp.rawValue); try send(controller.accessory.picker)
        try await until({ probe.state.accepted.count == 1 }, "First codec request did not start")
        controller.accessory.picker.selectItem(at: ImageExportFormat.avif.rawValue); try send(controller.accessory.picker)
        try await until({ probe.state.busyAttempts > 0 }, "Latest codec did not wait for cleanup")
        XCTAssertTrue(probe.state.firstCancellationObserved)
        XCTAssertNil(controller.latestArtifact); XCTAssertFalse(controller.saveButton.isEnabled)
        let priorBusy = probe.state.busyAttempts
        for value in 1...100 {
            controller.accessory.picker.selectItem(at: value % 2 == 0 ? ImageExportFormat.webp.rawValue : ImageExportFormat.avif.rawValue)
            try send(controller.accessory.picker)
            controller.accessory.quality.doubleValue = Double(value); try send(controller.accessory.quality)
        }
        controller.accessory.picker.selectItem(at: ImageExportFormat.avif.rawValue); try send(controller.accessory.picker)
        controller.accessory.quality.doubleValue = 27; try send(controller.accessory.quality)
        try await until({ probe.state.busyAttempts > priorBusy }, "Final debounced request did not wait")
        XCTAssertEqual(probe.state.accepted.count, 1, "No new encoder may enter before old cleanup finishes")
        XCTAssertEqual(probe.state.peakOwners, 1)
        probe.releaseFirst()
        let artifact = try await ready(controller)
        XCTAssertEqual(artifact.options.format, .avif); XCTAssertEqual(artifact.options.quality, 0.27)
        XCTAssertEqual(probe.state.accepted.map(\.format), [.webp, .avif])
        XCTAssertEqual(probe.state.accepted.last?.quality, 27)
        XCTAssertEqual(probe.state.peakOwners, 1); XCTAssertTrue(controller.saveButton.isEnabled)
        XCTAssertTrue(controller.retryButton.isHidden)
    }
    func testCloseCancelsLatestAdmissionWaiterAndReleasesControllerDuringOldCleanup() async throws {
        let probe = ImageExportDelayedAdmissionDouble()
        var controller: ImageExportController? = try ImageExportController(image: fixture(), bundledEncoder: { snapshot, options in
            try await ImageExportService.encodeBundled(snapshot: snapshot, options: options,
                prepare: { try await probe.prepare($0, $1) })
        })
        weak var weakController = controller
        defer { probe.releaseFirst(); controller?.cancelExport() }
        controller?.accessory.picker.selectItem(at: ImageExportFormat.webp.rawValue)
        try send(try XCTUnwrap(controller?.accessory.picker))
        try await until({ probe.state.accepted.count == 1 }, "First request did not enter")
        controller?.accessory.picker.selectItem(at: ImageExportFormat.avif.rawValue)
        try send(try XCTUnwrap(controller?.accessory.picker))
        try await until({ probe.state.busyAttempts > 0 }, "Replacement never waited")
        controller?.cancelExport()
        XCTAssertTrue(controller?.isClosed == true); XCTAssertNil(controller?.latestArtifact)
        XCTAssertFalse(controller?.saveButton.isEnabled ?? true)
        controller = nil
        try await until({ weakController == nil }, "Closed controller was retained by a waiting task")
        XCTAssertTrue(probe.state.firstCancellationObserved); XCTAssertEqual(probe.state.accepted.count, 1)
        probe.releaseFirst(); try await until({ probe.state.owners == 0 }, "Old cleanup did not drain")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(probe.state.accepted.count, 1, "Closed latest waiter must never be admitted later")
    }
    func testOtherOwnerBusyHasBoundedWaitAndVisibleWorkingRetry() async throws {
        let probe = ImageExportDelayedAdmissionDouble(blockFirst: false, externalOwner: true)
        let controller = try ImageExportController(image: fixture(), bundledEncoder: { snapshot, options in
            try await ImageExportService.encodeBundled(snapshot: snapshot, options: options,
                prepare: { try await probe.prepare($0, $1) }, admissionWaitSeconds: 0.15)
        })
        defer { probe.releaseExternal(); controller.cancelExport() }
        controller.accessory.picker.selectItem(at: ImageExportFormat.webp.rawValue); try send(controller.accessory.picker)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("5 分钟"))
        try await until({ !controller.retryButton.isHidden }, "Bounded admission wait never offered Retry")
        XCTAssertNil(controller.latestArtifact); XCTAssertFalse(controller.saveButton.isEnabled)
        XCTAssertEqual(probe.state.accepted.count, 0)
        probe.releaseExternal(); try send(controller.retryButton)
        let artifact = try await ready(controller)
        XCTAssertEqual(artifact.options.format, .webp); XCTAssertTrue(controller.retryButton.isHidden)
        XCTAssertEqual(probe.state.accepted.count, 1)
    }

    func testBundledCodecControlsKeepCompactWindowOnSmallDesktop() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.visibleFrame.width >= 600, screen.visibleFrame.height >= 500 else {
            throw XCTSkip("Native compact control layout needs a WindowServer display")
        }
        let controller = try makeController(); defer { controller.cancelExport() }
        controller.showWindow(nil); controller.requestPreview(); _ = try await ready(controller)
        for format in [ImageExportFormat.webp, .avif] {
            // Layout-only fixture: no asynchronous encoding request needed.
            controller.accessory.onChange = nil
            controller.accessory.picker.selectItem(at: format.rawValue); try send(controller.accessory.picker)
            controller.fitWindow(to: CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: 580, height: 480))
            let result = try ImageExportPreviewFixture.verifyLayout(controller,
                visibleFrame: CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: 580, height: 480))
            XCTAssertEqual(result["allControlsWithinVisibleFrame"] as? Bool, true)
            XCTAssertLessThanOrEqual(try XCTUnwrap(controller.window?.contentView).bounds.height, 550)
        }
    }

    func testRapidFormatAndQualityChangesDiscardStalePreview() async throws {
        let controller = try makeController(); defer { controller.cancelExport() }
        controller.requestPreview()
        for index in 0..<20 {
            controller.accessory.picker.selectItem(at: index % 2 == 0 ? 1 : 0)
            try send(controller.accessory.picker)
        }
        controller.accessory.picker.selectItem(at: 1); try send(controller.accessory.picker)
        controller.accessory.quality.doubleValue = 23; try send(controller.accessory.quality)
        let artifact = try await ready(controller)
        XCTAssertEqual(artifact.options.format, .jpeg); XCTAssertEqual(artifact.options.quality, 0.23)
        XCTAssertTrue(controller.saveButton.isEnabled); XCTAssertNotNil(controller.previewView.image)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("\(artifact.byteCount) 字节"))
    }
    func testCloseCancelsPendingEncodingAndNeverReenablesSave() async throws {
        let controller = try makeController()
        controller.requestPreview(); controller.cancelExport()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(controller.isClosed); XCTAssertNil(controller.latestArtifact); XCTAssertNil(controller.previewView.image)
        XCTAssertFalse(controller.saveButton.isEnabled)
    }
    func testCompletedInFlightPreviewCannotReplaceNewerRequest() async throws {
        let barrier = ImageExportTestBarrier()
        let controller = try ImageExportController(image: fixture(), encoder: { snapshot, options, _ in
            // Deliberately ignore the old cancellation token: this models a
            // native codec that already completed before its UI callback runs.
            let artifact = try ImageExportService.encode(snapshot: snapshot, options: options)
            if barrier.claimFirst() { try barrier.pause() }
            return artifact
        })
        defer { barrier.release(); controller.cancelExport() }
        controller.requestPreview(); try await started(barrier)
        controller.accessory.picker.selectItem(at: 1); try send(controller.accessory.picker)
        controller.accessory.quality.doubleValue = 23; try send(controller.accessory.quality)
        barrier.release()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertNil(controller.latestArtifact, "Completed old PNG must not beat the new JPEG debounce")
        XCTAssertFalse(controller.saveButton.isEnabled)
        let artifact = try await ready(controller)
        XCTAssertEqual(artifact.options.format, .jpeg); XCTAssertEqual(artifact.options.quality, 0.23)
    }
    func testClosingDuringInFlightEncodingRejectsItsLateCompletion() async throws {
        let barrier = ImageExportTestBarrier()
        let controller = try ImageExportController(image: fixture(), encoder: { snapshot, options, _ in
            let artifact = try ImageExportService.encode(snapshot: snapshot, options: options)
            if barrier.claimFirst() { try barrier.pause() }
            return artifact
        })
        defer { barrier.release(); controller.cancelExport() }
        controller.requestPreview(); try await started(barrier)
        controller.cancelExport(); barrier.release()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(controller.isClosed); XCTAssertNil(controller.latestArtifact)
        XCTAssertFalse(controller.saveButton.isEnabled); XCTAssertNil(controller.previewView.image)
    }

    func testParentCloseReleasesLiveSession() async throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let before = ImageExportController.activeSessionCount
        let controller = try XCTUnwrap(ImageExportController.present(image: fixture(), from: parent))
        XCTAssertEqual(ImageExportController.activeSessionCount, before + 1)
        parent.close()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(controller.isClosed); XCTAssertEqual(ImageExportController.activeSessionCount, before)
    }
    func testOnlyOneSessionPerParentWindow() throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; defer { parent.close() }
        let first = try XCTUnwrap(ImageExportController.present(image: fixture(), from: parent))
        let second = try XCTUnwrap(ImageExportController.present(image: fixture(), from: parent))
        XCTAssertTrue(first === second); first.cancelExport()
    }
    func testPickerRejectsExistingFilesBeforeCompletion() throws {
        let controller = try makeController(); defer { controller.cancelExport() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("existing.png"); try Data([1, 2, 3]).write(to: file)
        XCTAssertThrowsError(try controller.panel(NSSavePanel(), validate: file))
        XCTAssertNoThrow(try controller.panel(NSSavePanel(), validate: directory.appendingPathComponent("new.png")))
    }
    func testPreparedSaveUsesPreviewBytesAndClosesAfterCommit() async throws {
        let controller = try makeController(); defer { controller.cancelExport() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.requestPreview(); let artifact = try await ready(controller)
        let destination = directory.appendingPathComponent("result.png")
        try await controller.savePrepared(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), artifact.data)
        XCTAssertTrue(controller.isClosed)
    }
    func testPDFPageNavigationUsesEncodedPagesAndBoundsCache() async throws {
        let controller = try ImageExportController(image: fixture(width: 612, height: 1700)); defer { controller.cancelExport() }
        controller.accessory.picker.selectItem(at: 3); try send(controller.accessory.picker)
        controller.accessory.paper.selectItem(at: 2); try send(controller.accessory.paper)
        _ = try await ready(controller)
        XCTAssertGreaterThan(controller.latestArtifact?.pageCount ?? 0, 1)
        controller.showPage(1)
        let deadline = Date().addingTimeInterval(10)
        while controller.previewView.image == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(controller.previewView.image); XCTAssertEqual(controller.previewPage, 1)
        controller.showPage(0); XCTAssertEqual(controller.previewPage, 0); XCTAssertNotNil(controller.previewView.image)
        controller.showPage(-1); XCTAssertEqual(controller.previewPage, 0)
    }

    func testNavigatingThenClosingDoesNotRetainController() async throws {
        var controller: ImageExportController? = try ImageExportController(image: fixture(width: 612, height: 1700))
        weak var weakController = controller
        controller?.accessory.picker.selectItem(at: 3); try send(try XCTUnwrap(controller?.accessory.picker))
        controller?.accessory.paper.selectItem(at: 2); try send(try XCTUnwrap(controller?.accessory.paper))
        _ = try await ready(try XCTUnwrap(controller))
        controller?.showPage(1)
        let deadline = Date().addingTimeInterval(10)
        while controller?.previewView.image == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        controller?.cancelExport(); controller = nil
        // Drain queued weak completion callbacks; no closed session may keep a
        // full source raster alive through an operation/controller cycle.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(weakController)
    }

    func testDecodedLongImageDoesNotEnlargeWindowAndActionsFitSmallVisibleFrame() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.visibleFrame.width >= 600, screen.visibleFrame.height >= 500 else {
            throw XCTSkip("Native compact export layout needs a WindowServer display")
        }
        let controller = try ImageExportController(image: fixture(width: 612, height: 1711))
        defer { controller.cancelExport() }
        controller.showWindow(nil); controller.window?.center(); controller.fitWindow()
        XCTAssertEqual(controller.previewView.intrinsicContentSize, NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric))
        for format in [ImageExportFormat.jpeg, .pdf] {
            controller.accessory.picker.selectItem(at: format.rawValue); try send(controller.accessory.picker)
            if format == .pdf { controller.accessory.paper.selectItem(at: 2); try send(controller.accessory.paper) }
            let artifact = try await ready(controller)
            let bytesBeforeLayout = artifact.data
            let regular = try ImageExportPreviewFixture.verifyLayout(controller)
            XCTAssertEqual(regular["allControlsWithinVisibleFrame"] as? Bool, true)
            let small = CGRect(x: screen.visibleFrame.minX + 12, y: screen.visibleFrame.minY + 12, width: 580, height: 480)
            controller.fitWindow(to: small)
            let compact = try ImageExportPreviewFixture.verifyLayout(controller, visibleFrame: small)
            XCTAssertEqual(compact["allControlsWithinVisibleFrame"] as? Bool, true)
            XCTAssertEqual(compact["previewAspectRatioPreserved"] as? Bool, true)
            XCTAssertEqual(controller.latestArtifact?.data, bytesBeforeLayout, "Window adaptation must not alter encoded bytes")
            controller.fitWindow()
            _ = try ImageExportPreviewFixture.verifyLayout(controller)
        }
    }

    func testAttachedExportSheetKeepsAllActionsOnScreenAfterDecode() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, screen.visibleFrame.width >= 720, screen.visibleFrame.height >= 650 else {
            throw XCTSkip("Native attached-sheet layout needs a 720×650 usable desktop")
        }
        let parent = NSWindow(contentRect: CGRect(x: screen.visibleFrame.maxX - 370,
                              y: screen.visibleFrame.minY + 10, width: 360, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.makeKeyAndOrderFront(nil)
        defer { parent.close() }
        let controller = try XCTUnwrap(ImageExportController.present(image: fixture(width: 612, height: 1711), from: parent))
        defer { controller.cancelExport() }
        _ = try await ready(controller)
        // Allow AppKit's sheet attachment animation/repositioning to finish.
        // Do not manually repair its frame from the test.
        try await Task.sleep(nanoseconds: 350_000_000)
        let layout = try ImageExportPreviewFixture.verifyLayout(controller)
        XCTAssertEqual(layout["allControlsWithinVisibleFrame"] as? Bool, true)
        XCTAssertTrue(controller.window?.sheetParent === parent)
        XCTAssertLessThanOrEqual(try XCTUnwrap(controller.window?.contentView).bounds.height, 550)
    }

    private func until(_ condition: () -> Bool, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard condition() else { XCTFail(message); throw PicShotError.message(message) }
    }

    private func started(_ barrier: ImageExportTestBarrier) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !barrier.started && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(barrier.started, "Worker did not reach deterministic completion barrier")
    }

    private func makeController() throws -> ImageExportController { _ = NSApplication.shared; return try ImageExportController(image: fixture()) }
    private func fixture(width: Int = 128, height: Int = 80) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func send(_ control: NSControl) throws { XCTAssertTrue(control.sendAction(control.action, to: control.target)) }
    private func ready(_ controller: ImageExportController) async throws -> ImageExportArtifact {
        let deadline = Date().addingTimeInterval(15)
        while controller.latestArtifact == nil && !controller.isClosed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        return try XCTUnwrap(controller.latestArtifact, controller.statusLabel.stringValue)
    }
}

private final class ImageExportTestBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var first = true
    private var reached = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    func claimFirst() -> Bool { lock.lock(); defer { lock.unlock() }; let result = first; first = false; return result }
    func pause() throws {
        lock.lock(); reached = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw PicShotError.message("Export test barrier timed out") }
    }
    func release() { semaphore.signal() }
}

/// Explicit sequencing double, not codec-output acceptance. The production
/// retry loop waits while the first operation holds admission through delayed
/// cancellation cleanup. Returned PNG is synthetic UI sequencing input only.
private final class ImageExportDelayedAdmissionDouble: @unchecked Sendable {
    struct State {
        let accepted: [CodecExportRequest]
        let busyAttempts: Int
        let owners: Int
        let peakOwners: Int
        let firstCancellationObserved: Bool
    }
    private let lock = NSLock()
    private let blockFirst: Bool
    private var held: Bool
    private var accepted: [CodecExportRequest] = []
    private var busyAttempts = 0, owners = 0, peakOwners = 0
    private var cancelled = false, released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(blockFirst: Bool = true, externalOwner: Bool = false) { self.blockFirst = blockFirst; held = externalOwner }
    var state: State {
        lock.lock(); defer { lock.unlock() }
        return State(accepted: accepted, busyAttempts: busyAttempts, owners: owners, peakOwners: peakOwners, firstCancellationObserved: cancelled)
    }
    func prepare(_ snapshot: ImageExportSnapshot, _ request: CodecExportRequest) async throws -> CodecPreparedArtifact {
        try Task.checkCancellation(); let first = try claim(request); defer { finish() }
        if first && blockFirst {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if released { lock.unlock(); continuation.resume() }
                    else { self.continuation = continuation; lock.unlock() }
                }
            } onCancel: { self.recordCancellation() }
        }
        let png = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions())
        return CodecPreparedArtifact(data: png.data, preview: png.firstPreview, width: png.width,
                                     height: png.height, frameCount: 1, duration: 0, destination: nil)
    }
    private func claim(_ request: CodecExportRequest) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !held else { busyAttempts += 1; throw CodecExportProcessError.busy }
        held = true; owners += 1; peakOwners = max(peakOwners, owners); accepted.append(request); return accepted.count == 1
    }
    private func finish() { lock.lock(); held = false; owners -= 1; lock.unlock() }
    private func recordCancellation() { lock.lock(); cancelled = true; lock.unlock() }
    func releaseFirst() {
        lock.lock(); released = true; let continuation = continuation; self.continuation = nil; lock.unlock(); continuation?.resume()
    }
    func releaseExternal() { lock.lock(); held = false; lock.unlock() }
}
