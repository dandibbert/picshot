import XCTest
import AppKit
import PicShotCore
@testable import PicShot

/// Real encoding/publication with isolated preferences and physically resolved
/// temporary roots. No capture, general pasteboard or user-selected directory.
@MainActor
final class SaveWorkflowDeliveryTests: XCTestCase {
    func testCommittedPNGDrainsClosesOnlyOwnedWindowAndReleasesAdmission() async throws { try await checkCommittedPNGDrainsClosesOnlyOwnedWindowAndReleasesAdmission(.legacyPreview) }
    func testEncodedPayloadCommittedPNGDrainsClosesOnlyOwnedWindowAndReleasesAdmission() async throws { try await checkCommittedPNGDrainsClosesOnlyOwnedWindowAndReleasesAdmission(.encodedPayload) }

    private func checkCommittedPNGDrainsClosesOnlyOwnedWindowAndReleasesAdmission(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: mode)
        let image = try source()
        let unrelated = try XCTUnwrap(presenter.save(image: image))
        defer { presenter.cancelAll() }
        try await until({ unrelated.jobDrained }, "Unrelated Save did not finish")
        var closeCalls = 0, drainCalls = 0
        presenter.onPresent = { job in
            let close = job.onClose, drained = job.onDrained
            job.onClose = { close?(); closeCalls += 1 }
            job.onDrained = { drained?(); drainCalls += 1 }
        }
        presenter.clipboardCopier = { _, _ in XCTFail("Explicit PNG Save must never copy"); return false }
        let delivery = SaveWorkflowDelivery(presenter: presenter)
        defer { delivery.cancel(); ImageExportService.queue.isSuspended = false }
        var receipts: [SaveWorkflowSummary] = []
        for index in 1...3 {
            ImageExportService.queue.isSuspended = true
            var finished = false
            let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
            try await until({ presenter.controllers.last?.state == .encoding }, "Owned Save did not queue")
            var job: SaveWorkflowController? = try XCTUnwrap(presenter.controllers.last)
            weak var weakJob = job
            XCTAssertNil(job?.terminalOutcome)
            XCTAssertFalse(finished)
            XCTAssertEqual(presenter.controllers.count, 2)
            XCTAssertFalse(try XCTUnwrap(job).quietAutomatic)
            ImageExportService.queue.isSuspended = false
            try await until({ finished }, "Owned Save did not finish")
            let receipt = try committed(await task.value)
            receipts.append(receipt)
            XCTAssertTrue(job?.jobDrained == true)
            XCTAssertEqual(job?.state, .closed)
            XCTAssertNil(job?.onDrained, "Consumed drainage callbacks must not be restored")
            XCTAssertEqual(presenter.controllers.count, 1)
            XCTAssertTrue(presenter.controllers.first === unrelated)
            XCTAssertEqual(unrelated.state, .completed)
            XCTAssertTrue(unrelated.window?.isVisible == true)
            XCTAssertEqual(closeCalls, index)
            XCTAssertEqual(drainCalls, index)
            XCTAssertEqual(presenter.retainedInputBytes, 0)
            XCTAssertEqual(receipt.clipboardOutcome, .notRequested)
            XCTAssertEqual(try Data(contentsOf: receipt.savedURL).count, receipt.byteCount)
            XCTAssertEqual(try SaveWorkflowUIPreviewFixture.pixels(SaveWorkflowUIPreviewFixture.decode(receipt.savedURL)),
                           try SaveWorkflowUIPreviewFixture.pixels(image))
            delivery.cancel()
            job = nil
            try await until({ weakJob == nil }, "Delivery retained its drained Save")
        }
        XCTAssertEqual(Set(receipts.map(\.savedURL)).count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count, 4)
        XCTAssertEqual(closeCalls, 3)
        XCTAssertEqual(drainCalls, 3)
    }

    func testDirectoryFailureWaitsForCloseReturnsTypedCauseAndCanRetry() async throws { try await checkDirectoryFailureWaitsForCloseReturnsTypedCauseAndCanRetry(.legacyPreview) }
    func testEncodedPayloadDirectoryFailureWaitsForCloseReturnsTypedCauseAndCanRetry() async throws { try await checkDirectoryFailureWaitsForCloseReturnsTypedCauseAndCanRetry(.encodedPayload) }

    private func checkDirectoryFailureWaitsForCloseReturnsTypedCauseAndCanRetry(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let blocked = fixture.root.appendingPathComponent("not-a-directory"), sentinel = Data("preserve".utf8)
        try sentinel.write(to: blocked)
        try SaveWorkflowSettings(baseURL: blocked, filenameTemplate: "chain").save(to: fixture.defaults)
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: mode)
        let delivery = SaveWorkflowDelivery(presenter: presenter)
        defer { delivery.cancel(); presenter.cancelAll() }
        var closeCalls = 0, drainCalls = 0
        presenter.onPresent = { job in
            let close = job.onClose, drained = job.onDrained
            job.onClose = { close?(); closeCalls += 1 }
            job.onDrained = { drained?(); drainCalls += 1 }
        }
        let image = try source()
        var finished = false
        let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
        try await until({ presenter.controllers.first?.jobDrained == true }, "Directory failure did not drain")
        let job = try XCTUnwrap(presenter.controllers.first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.window?.isVisible == true)
        XCTAssertFalse(finished, "The failed Save remains the decision surface until Close")
        assertDirectoryFailure(try XCTUnwrap(job.terminalOutcome))
        XCTAssertEqual(closeCalls, 0)
        XCTAssertEqual(drainCalls, 1)
        job.closeButton.performClick(nil)
        try await until({ finished }, "Failed Save did not return its typed error after Close")
        assertDirectoryFailure(await task.value)
        assertDirectoryFailure(try XCTUnwrap(job.terminalOutcome))
        XCTAssertTrue(presenter.controllers.isEmpty)
        XCTAssertNil(job.onDrained)
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 1)
        XCTAssertEqual(try Data(contentsOf: blocked), sentinel)

        try SaveWorkflowSettings(baseURL: fixture.root, filenameTemplate: "retry").save(to: fixture.defaults)
        let receipt = try committed(await delivery.save(image: image, parent: nil))
        XCTAssertEqual(receipt.savedURL.lastPathComponent, "retry.png")
        XCTAssertTrue(presenter.controllers.isEmpty)
        XCTAssertEqual(closeCalls, 2)
        XCTAssertEqual(drainCalls, 2)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)), ["not-a-directory", "retry.png"])
        XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
    }

    func testQueuedCancellationWaitsForDrainAndDoesNotCancelUnrelatedJob() async throws { try await checkQueuedCancellationWaitsForDrainAndDoesNotCancelUnrelatedJob(.legacyPreview) }
    func testEncodedPayloadQueuedCancellationWaitsForDrainAndDoesNotCancelUnrelatedJob() async throws { try await checkQueuedCancellationWaitsForDrainAndDoesNotCancelUnrelatedJob(.encodedPayload) }

    private func checkQueuedCancellationWaitsForDrainAndDoesNotCancelUnrelatedJob(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: mode)
        let delivery = SaveWorkflowDelivery(presenter: presenter)
        defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
        let image = try source()
        ImageExportService.queue.isSuspended = true
        let unrelated = try XCTUnwrap(presenter.save(image: image))
        var closeCalls = 0, drainCalls = 0
        presenter.onPresent = { job in
            let close = job.onClose, drained = job.onDrained
            job.onClose = { close?(); closeCalls += 1 }
            job.onDrained = { drained?(); drainCalls += 1 }
        }
        var finished = false
        let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
        try await until({ presenter.controllers.count == 2 && presenter.controllers.allSatisfy { $0.state == .encoding } }, "Saves did not queue")
        let owned = try XCTUnwrap(presenter.controllers.last)
        delivery.cancel(); delivery.cancel()
        XCTAssertEqual(owned.state, .closed)
        XCTAssertEqual(unrelated.state, .encoding)
        XCTAssertNil(owned.terminalOutcome)
        XCTAssertFalse(finished)
        XCTAssertEqual(presenter.activeJobCount, 2)
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 0)
        unrelated.cancel()
        ImageExportService.queue.isSuspended = false
        try await until({ finished }, "Cancelled Save did not drain")
        assertCancelled(await task.value)
        try await SaveWorkflowUIPreviewFixture.drained(presenter)
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 1)
        XCTAssertEqual(presenter.retainedInputBytes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testQueuedTimeoutRetainsFailureThroughCloseAndWaitsForDrain() async throws { try await checkQueuedTimeoutRetainsFailureThroughCloseAndWaitsForDrain(.legacyPreview) }
    func testEncodedPayloadQueuedTimeoutRetainsFailureThroughCloseAndWaitsForDrain() async throws { try await checkQueuedTimeoutRetainsFailureThroughCloseAndWaitsForDrain(.encodedPayload) }

    private func checkQueuedTimeoutRetainsFailureThroughCloseAndWaitsForDrain(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: mode)
        let delivery = SaveWorkflowDelivery(presenter: presenter)
        defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
        ImageExportService.queue.isSuspended = true
        let image = try source()
        var finished = false
        let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
        try await until({ presenter.controllers.first?.state == .encoding }, "Save did not queue")
        let job = try XCTUnwrap(presenter.controllers.first)
        job.expireDeadline()
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.window?.isVisible == true)
        XCTAssertNil(job.terminalOutcome)
        XCTAssertFalse(finished)
        ImageExportService.queue.isSuspended = false
        try await until({ job.jobDrained }, "Timed-out Save did not drain")
        assertTimedOut(try XCTUnwrap(job.terminalOutcome))
        XCTAssertFalse(finished)
        XCTAssertEqual(job.state, .failed)
        job.cancel(); job.cancel()
        try await until({ finished }, "Timed-out Save did not return after Close")
        assertTimedOut(await task.value)
        XCTAssertTrue(presenter.controllers.isEmpty)
        XCTAssertNil(job.onDrained)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testTaskCancellationClosesOwnedWindowButAwaitsDrainage() async throws { try await checkTaskCancellationClosesOwnedWindowButAwaitsDrainage(.legacyPreview) }
    func testEncodedPayloadTaskCancellationClosesOwnedWindowButAwaitsDrainage() async throws { try await checkTaskCancellationClosesOwnedWindowButAwaitsDrainage(.encodedPayload) }

    private func checkTaskCancellationClosesOwnedWindowButAwaitsDrainage(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: mode)
        let delivery = SaveWorkflowDelivery(presenter: presenter)
        defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
        ImageExportService.queue.isSuspended = true
        let image = try source()
        var finished = false
        let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
        try await until({ presenter.controllers.first?.state == .encoding }, "Save did not queue")
        let job = try XCTUnwrap(presenter.controllers.first)
        task.cancel()
        try await until({ job.state == .closed }, "Task cancellation did not reach Save")
        XCTAssertFalse(finished)
        XCTAssertNil(job.terminalOutcome)
        ImageExportService.queue.isSuspended = false
        try await until({ finished }, "Cancelled task did not await Save drainage")
        assertCancelled(await task.value)
        XCTAssertTrue(presenter.controllers.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testPhysicalCommitBeforeCancellationOrTimeoutReturnsReceiptExactlyOnce() async throws {
        try await checkPhysicalCommitBeforeCancellationOrTimeout(freshMode: nil)
    }

    func testFreshPNGPhysicalCommitBeforeCancellationOrTimeoutReturnsReceiptExactlyOnce() async throws {
        for mode in [SavePNGPreparationMode.legacyPreview, .encodedPayload] {
            try await checkPhysicalCommitBeforeCancellationOrTimeout(freshMode: mode)
        }
    }

    private func checkPhysicalCommitBeforeCancellationOrTimeout(freshMode: SavePNGPreparationMode?) async throws {
        _ = NSApplication.shared
        for timeout in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let image = try source()
            let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init())
            let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: freshMode ?? .legacyPreview)
            var closeCalls = 0, drainCalls = 0, savedCalls = 0
            presenter.onPresent = { job in
                let close = job.onClose, drained = job.onDrained
                job.onClose = { close?(); closeCalls += 1 }
                job.onDrained = { drained?(); drainCalls += 1 }
            }
            let delivery = SaveWorkflowDelivery { image, parent, onSaved in
                let callback: (SaveWorkflowResult) -> Void = { _ in savedCalls += 1; onSaved() }
                if freshMode != nil { return presenter.save(image: image, from: parent, onSaved: callback) }
                return presenter.save(artifact: artifact, copy: false, from: parent, onSaved: callback)
            }
            defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
            ImageExportService.queue.isSuspended = true
            var finished = false
            let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
            if freshMode != nil {
                try await until({ presenter.controllers.first?.state == .encoding }, "Fresh PNG did not queue")
                // Finish the real encoder while the MainActor cannot consume its result,
                // then suspend publication before yielding back to that continuation.
                try finishQueuedWorkerBeforeMainActor()
                ImageExportService.queue.isSuspended = true
            }
            try await until({ presenter.controllers.first?.state == .saving }, "Publication did not queue")
            let job = try XCTUnwrap(presenter.controllers.first)
            try finishQueuedWorkerBeforeMainActor()
            let output = fixture.root.appendingPathComponent("chain.png")
            XCTAssertEqual(try Data(contentsOf: output), artifact.data)
            XCTAssertNil(job.result)
            XCTAssertNil(job.terminalOutcome)
            if timeout { job.expireDeadline() } else { delivery.cancel() }
            XCTAssertFalse(finished)
            XCTAssertFalse(job.jobDrained)
            try await until({ finished }, "Committed Save did not return after drainage")
            let receipt = try committed(await task.value)
            XCTAssertEqual(receipt.savedURL, output)
            XCTAssertEqual(receipt.byteCount, artifact.byteCount)
            XCTAssertEqual(try committed(XCTUnwrap(job.terminalOutcome)).savedURL, output)
            XCTAssertEqual(job.state, .closed)
            XCTAssertTrue(job.jobDrained)
            XCTAssertNil(job.onDrained)
            XCTAssertEqual(savedCalls, timeout ? 1 : 0)
            XCTAssertEqual(closeCalls, 1)
            XCTAssertEqual(drainCalls, 1)
            delivery.cancel(); job.cancel(); job.expireDeadline()
            XCTAssertEqual(closeCalls, 1)
            XCTAssertEqual(drainCalls, 1)
            XCTAssertTrue(presenter.controllers.isEmpty)
            XCTAssertEqual(try Data(contentsOf: output), artifact.data)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["chain.png"])
        }
    }

    func testWorkerFailureArrivingAfterCloseRetainsTheActualError() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let blocked = fixture.root.appendingPathComponent("blocked")
        let sentinel = Data("preserve".utf8)
        try sentinel.write(to: blocked)
        try SaveWorkflowSettings(baseURL: blocked, filenameTemplate: "chain").save(to: fixture.defaults)
        let image = try source()
        let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: image), options: .init())
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults)
        let delivery = SaveWorkflowDelivery { _, parent, onSaved in
            presenter.save(artifact: artifact, copy: false, from: parent, onSaved: { _ in onSaved() })
        }
        defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
        ImageExportService.queue.isSuspended = true
        var finished = false
        let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
        try await until({ presenter.controllers.first?.state == .saving }, "Failing publication did not queue")
        let job = try XCTUnwrap(presenter.controllers.first)
        try finishQueuedWorkerBeforeMainActor()
        delivery.cancel()
        XCTAssertEqual(job.state, .closed)
        XCTAssertNil(job.terminalOutcome)
        XCTAssertFalse(finished)
        try await until({ finished }, "Closed failed job did not drain")
        assertDirectoryFailure(await task.value)
        XCTAssertTrue(presenter.controllers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["blocked"])
    }

    func testNilAdmissionIsFailureEvenAfterReentrantCancel() async throws {
        let image = try source()
        for cancelDuringPresentation in [false, true] {
            weak var active: SaveWorkflowDelivery?
            let delivery = SaveWorkflowDelivery { _, _, onSaved in
                if cancelDuringPresentation { active?.cancel() }
                onSaved(); onSaved()
                return nil
            }
            active = delivery
            let outcome = await delivery.save(image: image, parent: nil)
            guard case .failed(.operation(let error)) = outcome,
                  let deliveryError = error as? SaveWorkflowDeliveryError,
                  case .notAdmitted = deliveryError else {
                return XCTFail("Nil admission must be a typed delivery failure")
            }
        }
    }

    func testAlreadyCancelledTaskDoesNotPresent() async throws {
        let image = try source()
        let delivery = SaveWorkflowDelivery { _, _, _ in XCTFail("Cancelled task must not present"); return nil }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await delivery.save(image: image, parent: nil)
        }
        assertCancelled(await task.value)
    }

    func testUnstartedCloseExposesTerminalOutcomeBeforeCleanupCallbacks() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let job = try fixture.makeUnstartedJob(source())
        var closeCalls = 0, drainCalls = 0
        XCTAssertNil(job.terminalOutcome)
        job.onDrained = { [weak job] in
            drainCalls += 1
            guard let outcome = job?.terminalOutcome else { return XCTFail("Drain must expose the outcome first") }
            self.assertCancelled(outcome)
        }
        job.onClose = { [weak job] in
            closeCalls += 1
            guard let outcome = job?.terminalOutcome else { return XCTFail("Unstarted Close must drain first") }
            self.assertCancelled(outcome)
        }
        job.cancel(); job.cancel(); job.expireDeadline()
        assertCancelled(try XCTUnwrap(job.terminalOutcome))
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 1)
        XCTAssertNil(job.onClose)
        XCTAssertNil(job.onDrained)
    }

    func testCollisionAndChooseAnotherCancellationAreNotOutputFailures() async throws { try await checkCollisionAndChooseAnotherCancellationAreNotOutputFailures(.legacyPreview) }
    func testEncodedPayloadCollisionAndChooseAnotherCancellationAreNotOutputFailures() async throws { try await checkCollisionAndChooseAnotherCancellationAreNotOutputFailures(.encodedPayload) }

    private func checkCollisionAndChooseAnotherCancellationAreNotOutputFailures(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        for chooseAnother in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            try SaveWorkflowSettings(baseURL: fixture.root, filenameTemplate: "chain", collisionBehavior: .ask).save(to: fixture.defaults)
            let occupied = fixture.root.appendingPathComponent("chain.png"), sentinel = Data("keep-existing".utf8)
            try sentinel.write(to: occupied)
            let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: mode)
            var collisionShown = false, savePanelShown = false
            presenter.onPresent = { job in
                job.onCollisionShown = { alert in
                    collisionShown = true
                    alert.buttons[chooseAnother ? 1 : 2].performClick(nil)
                }
                job.onSavePanelShown = { panel in
                    savePanelShown = true
                    panel.cancel(nil)
                }
            }
            let delivery = SaveWorkflowDelivery(presenter: presenter)
            defer { delivery.cancel(); presenter.cancelAll() }
            let image = try source()
            var finished = false
            let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
            try await until({ finished }, "Collision cancellation did not drain")
            assertCancelled(await task.value)
            XCTAssertTrue(collisionShown)
            XCTAssertEqual(savePanelShown, chooseAnother)
            XCTAssertTrue(presenter.controllers.isEmpty)
            XCTAssertEqual(try Data(contentsOf: occupied), sentinel)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["chain.png"])
        }
    }

    func testOnPresentCloseBeforeReturnRunsBothCleanupCallbacksOnce() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults)
        var closeCalls = 0, drainCalls = 0
        presenter.onPresent = { job in
            let close = job.onClose, drained = job.onDrained
            job.onClose = { close?(); closeCalls += 1 }
            job.onDrained = { drained?(); drainCalls += 1 }
            job.cancel(); job.cancel()
        }
        let delivery = SaveWorkflowDelivery(presenter: presenter)
        let image = try source()
        assertCancelled(await delivery.save(image: image, parent: nil))
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 1)
        XCTAssertTrue(presenter.controllers.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testCancelBeforeJobAssignmentRestoresCloseAfterSynchronousDrain() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source()
        let job = try fixture.makeUnstartedJob(image)
        var closeCalls = 0, drainCalls = 0, savedCallback: (() -> Void)?
        job.onClose = { closeCalls += 1 }
        job.onDrained = { drainCalls += 1 }
        weak var active: SaveWorkflowDelivery?
        let delivery = SaveWorkflowDelivery { _, _, onSaved in
            savedCallback = onSaved
            active?.cancel(); onSaved(); onSaved()
            return job
        }
        active = delivery
        assertCancelled(await delivery.save(image: image, parent: nil))
        savedCallback?(); delivery.cancel(); job.cancel()
        XCTAssertEqual(job.state, .closed)
        XCTAssertTrue(job.jobDrained)
        XCTAssertNil(job.onClose)
        XCTAssertNil(job.onDrained)
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 1)
    }

    func testOnSavedSynchronousCloseStillReturnsCommittedAfterDrain() async throws { try await checkOnSavedSynchronousCloseStillReturnsCommittedAfterDrain(.legacyPreview) }
    func testEncodedPayloadOnSavedSynchronousCloseStillReturnsCommittedAfterDrain() async throws { try await checkOnSavedSynchronousCloseStillReturnsCommittedAfterDrain(.encodedPayload) }

    private func checkOnSavedSynchronousCloseStillReturnsCommittedAfterDrain(_ mode: SavePNGPreparationMode) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: mode)
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        var job: SaveWorkflowController?, savedCalls = 0, closeCalls = 0, drainCalls = 0
        presenter.onPresent = { presented in
            job = presented
            let close = presented.onClose, drained = presented.onDrained
            presented.onClose = { close?(); closeCalls += 1 }
            presented.onDrained = { drained?(); drainCalls += 1 }
        }
        let delivery = SaveWorkflowDelivery { image, parent, onSaved in
            presenter.save(image: image, from: parent, onSaved: { _ in
                savedCalls += 1
                XCTAssertNil(job?.window?.parent, "Successful feedback detaches before onSaved")
                XCTAssertNil(job?.terminalOutcome, "onSaved precedes input drainage")
                onSaved(); job?.cancel(); onSaved()
            })
        }
        defer { delivery.cancel(); presenter.cancelAll(); parent.close() }
        let receipt = try committed(await delivery.save(image: source(), parent: parent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.savedURL.path))
        XCTAssertEqual(job?.state, .closed)
        XCTAssertTrue(job?.jobDrained == true)
        XCTAssertEqual(savedCalls, 1)
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 1)
        XCTAssertTrue(presenter.controllers.isEmpty)
    }

    func testStaleCallbacksCannotResolveNewJobAndConcurrentAdmissionFails() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let image = try source()
        let jobs = try [fixture.makeUnstartedJob(image), fixture.makeUnstartedJob(image)]
        var savedCallbacks: [() -> Void] = [], closeCalls = 0, drainCalls = 0
        for job in jobs {
            job.onClose = { closeCalls += 1 }
            job.onDrained = { drainCalls += 1 }
        }
        let delivery = SaveWorkflowDelivery { _, _, callback in
            savedCallbacks.append(callback)
            return jobs[savedCallbacks.count - 1]
        }
        defer { delivery.cancel(); jobs.forEach { $0.cancel() } }
        var firstFinished = false, secondFinished = false
        let first = Task { defer { firstFinished = true }; return await delivery.save(image: image, parent: nil) }
        try await until({ savedCallbacks.count == 1 }, "First Save did not present")
        let staleClose = jobs[0].onClose, staleDrained = jobs[0].onDrained
        let concurrent = await delivery.save(image: image, parent: nil)
        guard case .failed(.operation(let error)) = concurrent,
              let deliveryError = error as? SaveWorkflowDeliveryError,
              case .alreadySaving = deliveryError else {
            return XCTFail("Concurrent Save must fail without replacing the owner")
        }
        savedCallbacks[0](); savedCallbacks[0]()
        XCTAssertFalse(firstFinished, "A notification without drained publication is not a receipt")
        jobs[0].cancel()
        try await until({ firstFinished }, "First Save did not cancel")
        assertCancelled(await first.value)
        let second = Task { defer { secondFinished = true }; return await delivery.save(image: image, parent: nil) }
        try await until({ savedCallbacks.count == 2 }, "Second Save did not present")
        savedCallbacks[0](); staleClose?(); staleDrained?(); staleClose?(); staleDrained?()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(secondFinished)
        XCTAssertEqual(jobs[1].state, .ready)
        XCTAssertEqual(closeCalls, 1)
        XCTAssertEqual(drainCalls, 1)
        delivery.cancel()
        try await until({ secondFinished }, "Second Save did not cancel")
        assertCancelled(await second.value)
        XCTAssertEqual(closeCalls, 2)
        XCTAssertEqual(drainCalls, 2)
    }

    func testFailureWithoutCleanupCallbacksStillObservesClose() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let blocked = fixture.root.appendingPathComponent("blocked"), sentinel = Data("preserve".utf8)
        try sentinel.write(to: blocked)
        try SaveWorkflowSettings(baseURL: blocked, filenameTemplate: "chain").save(to: fixture.defaults)
        let image = try source()
        let job = try fixture.makeUnstartedJob(image)
        var finished = false
        let delivery = SaveWorkflowDelivery { _, _, _ in job.start(); return job }
        defer { delivery.cancel(); job.cancel() }
        let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
        try await until({ job.jobDrained }, "Failed Save did not drain")
        XCTAssertEqual(job.state, .failed)
        XCTAssertFalse(finished)
        job.cancel()
        try await until({ finished }, "Close without prior callbacks did not settle")
        assertDirectoryFailure(await task.value)
        XCTAssertNil(job.onClose)
        XCTAssertNil(job.onDrained)
        XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
    }

    func testFreshPNGQueuedPublicationCancellationWaitsForDrainAndPublishesNothing() async throws {
        _ = NSApplication.shared
        for mode in [SavePNGPreparationMode.legacyPreview, .encodedPayload] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let presenter = SaveWorkflowPresenter(defaults: fixture.defaults, pngPreparationMode: mode)
            let delivery = SaveWorkflowDelivery(presenter: presenter)
            defer { delivery.cancel(); presenter.cancelAll(); ImageExportService.queue.isSuspended = false }
            var closeCalls = 0, drainCalls = 0
            presenter.onPresent = { job in
                let close = job.onClose, drained = job.onDrained
                job.onClose = { close?(); closeCalls += 1 }
                job.onDrained = { drained?(); drainCalls += 1 }
            }
            let image = try source()
            ImageExportService.queue.isSuspended = true
            var finished = false
            let task = Task { defer { finished = true }; return await delivery.save(image: image, parent: nil) }
            try await until({ presenter.controllers.first?.state == .encoding }, "Fresh PNG did not queue")
            try finishQueuedWorkerBeforeMainActor()
            ImageExportService.queue.isSuspended = true
            try await until({ presenter.controllers.first?.state == .saving }, "Fresh PNG publication did not queue")
            let job = try XCTUnwrap(presenter.controllers.first)
            delivery.cancel(); delivery.cancel()
            XCTAssertEqual(job.state, .closed); XCTAssertFalse(job.jobDrained)
            XCTAssertNil(job.terminalOutcome); XCTAssertFalse(finished)
            XCTAssertGreaterThan(presenter.retainedInputBytes, 0)
            ImageExportService.queue.isSuspended = false
            try await until({ finished }, "Cancelled publication did not drain")
            assertCancelled(await task.value)
            XCTAssertEqual(closeCalls, 1); XCTAssertEqual(drainCalls, 1)
            XCTAssertTrue(presenter.controllers.isEmpty); XCTAssertEqual(presenter.retainedInputBytes, 0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        }
    }

    private func finishQueuedWorkerBeforeMainActor() throws {
        let done = DispatchSemaphore(value: 0)
        let fence = BlockOperation { done.signal() }
        let queued = ImageExportService.queue.operations
        XCTAssertFalse(queued.isEmpty)
        queued.forEach { fence.addDependency($0) }
        ImageExportService.queue.addOperation(fence)
        ImageExportService.queue.isSuspended = false
        // Bounded, existing real-worker fence: the MainActor cannot consume
        // the queued result until this function returns to its caller.
        guard done.wait(timeout: .now() + 3) == .success else {
            XCTFail("Real publication worker did not finish inside the bounded callback gap")
            throw SaveWorkflowDeliveryError.notAdmitted
        }
    }

    private func committed(_ outcome: SaveWorkflowTerminalOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> SaveWorkflowSummary {
        let result: SaveWorkflowSummary?
        if case .committed(let summary) = outcome { result = summary } else { result = nil }
        return try XCTUnwrap(result, "Expected a committed Save receipt", file: file, line: line)
    }

    private func assertCancelled(_ outcome: SaveWorkflowTerminalOutcome, file: StaticString = #filePath, line: UInt = #line) {
        guard case .cancelled = outcome else { return XCTFail("Expected cancellation", file: file, line: line) }
    }

    private func assertTimedOut(_ outcome: SaveWorkflowTerminalOutcome, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(.timedOut) = outcome else { return XCTFail("Expected typed timeout", file: file, line: line) }
    }

    private func assertDirectoryFailure(_ outcome: SaveWorkflowTerminalOutcome, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(.operation(let error)) = outcome else { return XCTFail("Expected typed operation failure", file: file, line: line) }
        XCTAssertTrue(error is SaveWorkflowError, file: file, line: line)
        XCTAssertEqual(error.localizedDescription, SaveWorkflowError.unsafeDirectory.localizedDescription, file: file, line: line)
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
            suite = "PicShot-SaveWorkflowDeliveryTests-" + UUID().uuidString
            root = try SaveWorkflowUIPreviewFixture.makeTemporaryRoot(name: suite)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            try SaveWorkflowSettings(baseURL: root, filenameTemplate: "chain", collisionBehavior: .keepBoth).save(to: defaults)
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
