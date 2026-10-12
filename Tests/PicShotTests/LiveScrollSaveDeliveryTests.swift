import XCTest
import AppKit
import PicShotCore
@testable import PicShot

/// Synthetic images, isolated preferences and physically resolved temporary
/// directories only. No live capture, general pasteboard or folder picker.
@MainActor
final class LiveScrollSaveDeliveryTests: XCTestCase {
    func testAdmissionWaitsForActualPNGAndParentCloseOnlyDetaches() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try SaveWorkflowSettings(baseURL: fixture.root, filenameTemplate: "scroll", collisionBehavior: .keepBoth).save(to: fixture.defaults)
        let existing = fixture.root.appendingPathComponent("scroll.png"), sentinel = Data("existing-file".utf8)
        try sentinel.write(to: existing)
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults)
        var drainCalls = 0
        presenter.onPresent = { job in
            let previousDrained = job.onDrained
            job.onDrained = { previousDrained?(); drainCalls += 1 }
        }
        presenter.clipboardCopier = { _, _ in XCTFail("Save must not copy to the clipboard"); return false }
        let delivery = LiveScrollSaveDelivery(presenter: presenter)
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { delivery.cancel(); presenter.cancelAll(); parent.close(); ImageExportService.queue.isSuspended = false }
        let image = try source()
        ImageExportService.queue.isSuspended = true
        var finished = false
        let task = Task { defer { finished = true }; try await delivery.save(image: image, parent: parent) }
        try await until({ presenter.controllers.first?.state == .encoding }, "Save did not reach the suspended encoder")
        var job: SaveWorkflowController? = try XCTUnwrap(presenter.controllers.first)
        weak var weakJob = job
        XCTAssertFalse(finished, "A nonnil admitted job is not a successful save")
        XCTAssertTrue(job?.window?.parent === parent)
        XCTAssertFalse(try XCTUnwrap(job).quietAutomatic)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["scroll.png"])
        parent.close()
        XCTAssertNil(job?.window?.parent)
        XCTAssertEqual(job?.state, .encoding)
        XCTAssertFalse(finished)
        ImageExportService.queue.isSuspended = false
        try await until({ finished }, "Committed save did not deliver")
        try await task.value
        XCTAssertEqual(drainCalls, 1, "Successful callback must restore the presenter's drainage callback")
        let result = try XCTUnwrap(job?.result)
        XCTAssertEqual(result.savedURL.lastPathComponent, "scroll (1).png")
        XCTAssertEqual(result.clipboardOutcome, .notRequested)
        XCTAssertEqual(try SaveWorkflowUIPreviewFixture.pixels(SaveWorkflowUIPreviewFixture.decode(result.savedURL)),
                       try SaveWorkflowUIPreviewFixture.pixels(image))
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let committedBytes = try Data(contentsOf: result.savedURL)
        XCTAssertEqual(committedBytes.count, result.byteCount)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)), ["scroll.png", "scroll (1).png"])
        delivery.cancel()
        XCTAssertEqual(job?.state, .completed, "A later session cancel must not own the completed Save window")
        job?.cancel(); job = nil
        try await SaveWorkflowUIPreviewFixture.drained(presenter)
        try await until({ weakJob == nil }, "Delivery retained a completed job")
        XCTAssertEqual(drainCalls, 1)
        XCTAssertEqual(try Data(contentsOf: result.savedURL), committedBytes)
    }

    func testCancelOwnsOnlyItsQueuedJobAndPreservesPresenterCleanup() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults)
        let delivery = LiveScrollSaveDelivery(presenter: presenter)
        defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
        let image = try source()
        ImageExportService.queue.isSuspended = true
        let unrelated = try XCTUnwrap(presenter.save(image: image))
        var closeCalls = 0, drainCalls = 0
        presenter.onPresent = { job in
            let previousClose = job.onClose, previousDrained = job.onDrained
            job.onClose = { previousClose?(); closeCalls += 1 }
            job.onDrained = { previousDrained?(); drainCalls += 1 }
        }
        var finished = false
        let task = Task { defer { finished = true }; try await delivery.save(image: image, parent: nil) }
        try await until({ presenter.controllers.count == 2 && presenter.controllers.allSatisfy { $0.state == .encoding } }, "Queued saves did not start")
        let owned = try XCTUnwrap(presenter.controllers.last)
        delivery.cancel(); delivery.cancel()
        XCTAssertFalse(finished, "Cancellation must observe drainage before deciding whether publication won")
        XCTAssertEqual(owned.state, .closed)
        XCTAssertEqual(unrelated.state, .encoding)
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 0)
        XCTAssertEqual(presenter.activeJobCount, 2, "Queue drainage still owns the input reservations")
        unrelated.cancel()
        ImageExportService.queue.isSuspended = false
        try await until({ finished }, "Cancelled delivery did not resolve after drainage")
        await assertCancelled(task)
        try await SaveWorkflowUIPreviewFixture.drained(presenter)
        XCTAssertEqual(drainCalls, 1)
        XCTAssertEqual(presenter.retainedInputBytes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testTaskCancellationClosesTheOwnedSaveAndPublishesNothing() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults)
        let delivery = LiveScrollSaveDelivery(presenter: presenter)
        defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
        let image = try source()
        ImageExportService.queue.isSuspended = true
        var finished = false
        let task = Task { defer { finished = true }; try await delivery.save(image: image, parent: nil) }
        try await until({ presenter.controllers.first?.state == .encoding }, "Save did not reach the queue")
        let job = try XCTUnwrap(presenter.controllers.first)
        task.cancel()
        try await until({ job.state == .closed }, "Task cancellation did not close Save")
        XCTAssertFalse(finished)
        XCTAssertEqual(job.state, .closed)
        ImageExportService.queue.isSuspended = false
        try await until({ finished }, "Task cancellation did not resolve after drainage")
        await assertCancelled(task)
        try await SaveWorkflowUIPreviewFixture.drained(presenter)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testPostCommitCloseBeforeMainActorResultSucceedsAndDrainsOnce() async throws {
        _ = NSApplication.shared
        for cancelThroughDelivery in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let image = try source()
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init())
            let presenter = SaveWorkflowPresenter(defaults: fixture.defaults)
            var savedCallbacks = 0, closeCalls = 0, drainCalls = 0
            presenter.onPresent = { job in
                let previousClose = job.onClose, previousDrained = job.onDrained
                job.onClose = { previousClose?(); closeCalls += 1 }
                job.onDrained = { previousDrained?(); drainCalls += 1 }
            }
            // Pre-encoded owned input reaches the real publication path without
            // an intervening encoder operation or any writer-specific test hook.
            let delivery = LiveScrollSaveDelivery { _, parent, onSaved in
                presenter.save(artifact: artifact, copy: false, from: parent, onSaved: { _ in
                    savedCallbacks += 1
                    onSaved()
                })
            }
            defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
            ImageExportService.queue.isSuspended = true
            var finished = false
            let task = Task { defer { finished = true }; try await delivery.save(image: image, parent: nil) }
            try await until({ presenter.controllers.first?.state == .saving }, "Save did not queue publication")
            var job: SaveWorkflowController? = try XCTUnwrap(presenter.controllers.first)
            weak var weakJob = job
            do {
                let publicationDone = DispatchSemaphore(value: 0)
                let fence = BlockOperation { publicationDone.signal() }
                let queued = ImageExportService.queue.operations
                XCTAssertFalse(queued.isEmpty)
                queued.forEach { fence.addDependency($0) }
                ImageExportService.queue.addOperation(fence)
                ImageExportService.queue.isSuspended = false
                // Hold the main actor only for this bounded wait: the worker commits
                // and returns, but Save's main-actor continuation cannot set result.
                guard publicationDone.wait(timeout: .now() + 3) == .success else {
                    XCTFail("Real publication did not finish inside the bounded callback-gap test")
                    return
                }
            }
            let output = fixture.root.appendingPathComponent("scroll.png")
            XCTAssertEqual(try Data(contentsOf: output), artifact.data)
            XCTAssertNil(job?.result)
            XCTAssertFalse(try XCTUnwrap(job).jobDrained)
            XCTAssertEqual(savedCallbacks, 0)
            if cancelThroughDelivery { delivery.cancel() } else { job?.cancel() }
            XCTAssertEqual(job?.state, .closed)
            XCTAssertEqual(closeCalls, 1)
            XCTAssertEqual(drainCalls, 0)
            XCTAssertFalse(finished, "Close must wait for the actual publication outcome")
            try await until({ finished }, "Committed closed Save did not resolve after drainage")
            try await task.value
            XCTAssertNotNil(job?.result)
            XCTAssertEqual(savedCallbacks, 0, "Close suppressed onSaved; drainage must recover the committed outcome")
            XCTAssertEqual(drainCalls, 1)
            delivery.cancel(); job?.cancel()
            XCTAssertEqual(closeCalls, 1)
            XCTAssertEqual(drainCalls, 1)
            XCTAssertEqual(try Data(contentsOf: output), artifact.data)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["scroll.png"])
            job = nil
            try await SaveWorkflowUIPreviewFixture.drained(presenter)
            try await until({ weakJob == nil }, "Drained closed Save remained retained")
        }
    }

    func testWriteFailureKeepsSaveVisibleAndPendingUntilCloseThenAllowsRetry() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let blocked = fixture.root.appendingPathComponent("not-a-directory"), sentinel = Data("preserve".utf8)
        try sentinel.write(to: blocked)
        try SaveWorkflowSettings(baseURL: blocked, filenameTemplate: "scroll").save(to: fixture.defaults)
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults)
        let delivery = LiveScrollSaveDelivery(presenter: presenter)
        defer { delivery.cancel(); presenter.cancelAll() }
        let image = try source()
        var finished = false
        let task = Task { defer { finished = true }; try await delivery.save(image: image, parent: nil) }
        try await until({ presenter.controllers.first?.state == .failed && presenter.controllers.first?.jobDrained == true }, "Expected directory failure did not surface")
        let job = try XCTUnwrap(presenter.controllers.first)
        XCTAssertFalse(finished, "Failure feedback remains owned by the open Save window")
        XCTAssertTrue(job.window?.isVisible == true)
        XCTAssertTrue(job.statusLabel.stringValue.contains("原图仍然保留"))
        XCTAssertNil(job.result)
        XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
        job.closeButton.performClick(nil)
        try await until({ finished }, "Closing failed Save did not return the draft")
        await assertCancelled(task)
        XCTAssertTrue(presenter.controllers.isEmpty)

        try SaveWorkflowSettings(baseURL: fixture.root, filenameTemplate: "retry").save(to: fixture.defaults)
        finished = false
        let retry = Task { defer { finished = true }; try await delivery.save(image: image, parent: nil) }
        try await until({ finished }, "Save could not retry after the failed window closed")
        try await retry.value
        XCTAssertNotNil(presenter.controllers.first?.result)
        XCTAssertEqual(try SaveWorkflowUIPreviewFixture.pixels(SaveWorkflowUIPreviewFixture.decode(fixture.root.appendingPathComponent("retry.png"))),
                       try SaveWorkflowUIPreviewFixture.pixels(image))
        XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
        presenter.cancelAll()
        try await SaveWorkflowUIPreviewFixture.drained(presenter)
    }

    func testNilAdmissionThrowsDescriptiveErrorWithoutOpeningAPicker() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, isSmoke: true)
        let delivery = LiveScrollSaveDelivery(presenter: presenter)
        do {
            try await delivery.save(image: source(), parent: nil)
            XCTFail("Nil admission must not count as delivery")
        } catch LiveScrollSaveDeliveryError.notAdmitted {
            XCTAssertTrue(LiveScrollSaveDeliveryError.notAdmitted.localizedDescription.contains("草稿仍然保留"))
        }
        XCTAssertTrue(presenter.controllers.isEmpty)
    }

    func testSynchronousSuccessWinsOnceAndRestoresCloseOwnership() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source()
        var job: SaveWorkflowController?
        weak var weakJob: SaveWorkflowController?
        var closeCalls = 0, drainCalls = 0, savedCallback: (() -> Void)?
        // Scope native creation and close separately; no pool spans the await.
        try autoreleasepool {
            job = try fixture.makeUnstartedJob(image)
            weakJob = job
            job?.onClose = { closeCalls += 1 }
            job?.onDrained = { drainCalls += 1 }
        }
        let delivery = LiveScrollSaveDelivery { _, _, onSaved in
            savedCallback = onSaved
            onSaved(); onSaved()
            return job
        }
        try await delivery.save(image: image, parent: nil)
        autoreleasepool {
            delivery.cancel()
            XCTAssertEqual(job?.state, .ready)
            job?.cancel(); savedCallback?(); job?.cancel()
            XCTAssertEqual(closeCalls, 1)
            XCTAssertEqual(drainCalls, 1)
            job = nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !autoreleasepool(invoking: { weakJob == nil }), ProcessInfo.processInfo.systemUptime < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        withExtendedLifetime((delivery, savedCallback)) {
            XCTAssertNil(weakJob, "Completed delivery must release its returned controller after native close drainage")
            XCTAssertEqual(closeCalls, 1)
            XCTAssertEqual(drainCalls, 1)
        }
    }

    func testSynchronousCancelBeforeAdmissionClosesReturnedJobAndIgnoresLateSuccess() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source()
        let job = try fixture.makeUnstartedJob(image)
        var closeCalls = 0, savedCallback: (() -> Void)?
        job.onClose = { closeCalls += 1 }
        weak var current: LiveScrollSaveDelivery?
        let delivery = LiveScrollSaveDelivery { _, _, onSaved in
            savedCallback = onSaved
            current?.cancel(); onSaved()
            return job
        }
        current = delivery
        do {
            try await delivery.save(image: image, parent: nil)
            XCTFail("Cancellation must win before success")
        } catch is CancellationError { }
        savedCallback?(); delivery.cancel()
        XCTAssertEqual(job.state, .closed)
        XCTAssertEqual(closeCalls, 1)
    }

    func testAlreadyClosedPresentationCancelsAndRunsPresenterCleanup() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults)
        presenter.onPresent = { $0.cancel() }
        let delivery = LiveScrollSaveDelivery(presenter: presenter)
        do {
            try await delivery.save(image: source(), parent: nil)
            XCTFail("A synchronously closed Save must cancel")
        } catch is CancellationError { }
        XCTAssertTrue(presenter.controllers.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testStaleSuccessCannotCompleteANewPendingSaveAndConcurrentSaveIsRejected() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source()
        let jobs = try [fixture.makeUnstartedJob(image), fixture.makeUnstartedJob(image)]
        var callbacks: [() -> Void] = [], closeCalls = 0
        for job in jobs {
            job.onClose = {
                closeCalls += 1
                callbacks.first?() // A reentrant late success must not beat Close.
            }
        }
        let delivery = LiveScrollSaveDelivery { _, _, callback in
            callbacks.append(callback)
            return jobs[callbacks.count - 1]
        }
        defer { delivery.cancel(); jobs.forEach { $0.cancel() } }
        var firstFinished = false, secondFinished = false
        let first = Task { defer { firstFinished = true }; try await delivery.save(image: image, parent: nil) }
        try await until({ callbacks.count == 1 }, "First Save was not presented")
        do {
            try await delivery.save(image: image, parent: nil)
            XCTFail("Concurrent save should be rejected")
        } catch LiveScrollSaveDeliveryError.alreadySaving { }
        XCTAssertEqual(callbacks.count, 1)
        jobs[0].cancel()
        try await until({ firstFinished }, "Closing Save did not cancel the first delivery")
        await assertCancelled(first)
        let second = Task { defer { secondFinished = true }; try await delivery.save(image: image, parent: nil) }
        try await until({ callbacks.count == 2 }, "Second Save was not presented")
        callbacks[0]()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(secondFinished)
        callbacks[1](); callbacks[1](); jobs[1].cancel()
        try await until({ secondFinished }, "Current Save success did not deliver")
        try await second.value
        XCTAssertEqual(closeCalls, 2)
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Expected CancellationError", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line) }
    }

    private func until(_ condition: () -> Bool, _ message: String) async throws {
        try await SaveWorkflowUIPreviewFixture.until(condition, message)
    }

    private func source() throws -> CGImage { try SaveWorkflowUIPreviewFixture.sourceImage(width: 48, height: 80) }

    @MainActor
    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let root: URL

        init() throws {
            suite = "PicShot-LiveScrollSaveDeliveryTests-" + UUID().uuidString
            root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: suite)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            try SaveWorkflowSettings(baseURL: root, filenameTemplate: "scroll").save(to: defaults)
        }

        func makeUnstartedJob(_ image: CGImage) throws -> SaveWorkflowController {
            try SaveWorkflowController(image: image, artifact: nil, settings: .read(from: defaults),
                                       defaults: defaults, copyAfterSaving: false)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
