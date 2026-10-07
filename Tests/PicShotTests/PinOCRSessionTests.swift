import XCTest
import AppKit
@testable import PicShot

/// Deterministic scheduler/lifetime tests. The gates deliberately ignore task cancellation
/// to model a native provider that has not returned yet. These are not Vision acceptance.
final class PinOCRSessionTests: XCTestCase {
    @MainActor func testTwentyRestoredPinsQueueIdentitiesAndFetchOnlyAdmittedRaster() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        var rasterReads = 0
        let sessions = (0..<20).map { _ in
            PinOCRSession(scheduler: scheduler, imageProvider: { rasterReads += 1; return image },
                          recognize: { _, options in await gate.wait(options) })
        }
        sessions.forEach { $0.scheduleAutomatic() }
        XCTAssertEqual(rasterReads, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.activeJobs, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 19)
        try await waitUntil { await gate.started == 1 }
        sessions.forEach { $0.close() }
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 0)
        XCTAssertEqual(scheduler.resourceSnapshot.activeJobs, 1, "Cancelled native work still owns its permit and raster")
        XCTAssertEqual(scheduler.resourceSnapshot.cancelledJobs, 1)
        await gate.finish(0)
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertEqual(rasterReads, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, scheduler.resourceSnapshot.releasedJobs)
        XCTAssertTrue(sessions.allSatisfy { $0.cachedResult == nil && $0.state == .closed })
    }

    @MainActor func testAutomaticSelectionCopyAndResultWindowShareOneResultAndCache() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        var rasterReads = 0, received: [PinOCRConsumer: String] = [:], changes: [PinOCRState] = []
        let session = PinOCRSession(revision: 7, scheduler: scheduler,
                                    imageProvider: { rasterReads += 1; return image },
                                    recognize: { _, options in await gate.wait(options) })
        session.onChange = { [weak session] in if let state = session?.state { changes.append(state) } }
        defer { session.close() }
        session.scheduleAutomatic()
        for consumer in [PinOCRConsumer.selection, .copyAll, .resultWindow] {
            session.request(consumer) { result in received[consumer] = try? result.get().text }
        }
        try await waitUntil { await gate.started == 1 }
        await gate.finish(0, text: "shared OCR")
        try await waitUntil { received.count == 3 }
        XCTAssertEqual(Set(received.values), ["shared OCR"])
        XCTAssertEqual(session.key.revision, 7)
        XCTAssertEqual(session.cachedResult?.text, "shared OCR")
        XCTAssertEqual(changes.last, .ready)
        let cached = try await session.result(for: .copyAll)
        XCTAssertEqual(cached.text, "shared OCR")
        XCTAssertEqual(rasterReads, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.releasedJobs, 1)
    }

    @MainActor func testExplicitRequestsUseReservedSlotAndOvertakeBackgroundQueue() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        var admissions: [String] = []
        func make(_ name: String) -> PinOCRSession {
            PinOCRSession(scheduler: scheduler, imageProvider: { admissions.append(name); return image },
                          recognize: { _, options in await gate.wait(options) })
        }
        let a = make("automatic A"), b = make("automatic B"), c = make("explicit C"), d = make("explicit D")
        defer { [a, b, c, d].forEach { $0.close() } }
        a.scheduleAutomatic(); b.scheduleAutomatic()
        c.request(.copyAll) { _ in }; d.request(.resultWindow) { _ in }
        XCTAssertEqual(admissions, ["automatic A", "explicit C"])
        XCTAssertEqual(scheduler.resourceSnapshot.activeJobs, 2)
        XCTAssertEqual(scheduler.resourceSnapshot.automaticJobs, 1)
        try await waitUntil { await gate.started == 2 }
        await gate.finish(0)
        try await waitUntil { await gate.started == 3 }
        XCTAssertEqual(admissions, ["automatic A", "explicit C", "explicit D"])
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 1)
        [a, b, c, d].forEach { $0.close() }
        await gate.finishAll()
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
    }

    @MainActor func testExplicitConsumerPromotesExistingAutomaticEntryWithoutDuplicateRaster() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        var reads = 0
        let a = PinOCRSession(scheduler: scheduler, imageProvider: { image }, recognize: { _, options in await gate.wait(options) })
        let b = PinOCRSession(scheduler: scheduler, imageProvider: { reads += 1; return image }, recognize: { _, options in await gate.wait(options) })
        defer { a.close(); b.close() }
        a.scheduleAutomatic(); b.scheduleAutomatic()
        XCTAssertEqual(reads, 0)
        b.request(.selection) { _ in }
        b.request(.copyAll) { _ in }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.activeJobs, 2)
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 0)
        try await waitUntil { await gate.started == 2 }
        a.close(); b.close(); await gate.finishAll()
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
    }

    @MainActor func testQueueBoundAndExplicitAdmissionEvictOnlyBackgroundIdentity() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        var reads = 0
        let sessions = (0..<40).map { _ in
            PinOCRSession(scheduler: scheduler, imageProvider: { reads += 1; return image },
                          recognize: { _, options in await gate.wait(options) })
        }
        sessions.forEach { $0.scheduleAutomatic() }
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, PinOCRScheduler.maximumWaitingSessions)
        XCTAssertEqual(scheduler.resourceSnapshot.rejectedJobs, 7)
        XCTAssertEqual(reads, 1)
        let explicit = PinOCRSession(scheduler: scheduler, imageProvider: { reads += 1; return image },
                                     recognize: { _, options in await gate.wait(options) })
        explicit.request(.copyAll) { _ in }
        XCTAssertEqual(explicit.state, .recognizing)
        XCTAssertEqual(scheduler.resourceSnapshot.rejectedJobs, 8)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, PinOCRScheduler.maximumWaitingSessions - 1)
        try await waitUntil { await gate.started == 2 }
        sessions.forEach { $0.close() }; explicit.close()
        await gate.finishAll()
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
    }

    @MainActor func testRevisionChangeCancelsImmediatelyButReleasesSlotOnlyAfterOldProviderExits() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        let a = PinOCRSession(scheduler: scheduler, imageProvider: { image }, recognize: { _, options in await gate.wait(options) })
        let b = PinOCRSession(scheduler: scheduler, imageProvider: { image }, recognize: { _, options in await gate.wait(options) })
        defer { a.close(); b.close() }
        var oldCancelled = false, newText: String?
        a.request(.selection) { if case .failure(let error) = $0 { oldCancelled = error is CancellationError } }
        // Wait for A before registering B to make the controlled completion index explicit.
        try await waitUntil { await gate.started == 1 }
        b.request(.copyAll) { _ in }
        try await waitUntil { await gate.started == 2 }
        a.update(revision: 1)
        XCTAssertTrue(oldCancelled)
        a.request(.selection) { newText = try? $0.get().text }
        XCTAssertEqual(scheduler.resourceSnapshot.activeJobs, 2)
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.cancelledJobs, 1)
        await gate.finish(0, text: "stale")
        try await waitUntil { await gate.started == 3 }
        XCTAssertNil(a.cachedResult); XCTAssertNil(newText)
        XCTAssertEqual(scheduler.resourceSnapshot.releasedJobs, 1)
        await gate.finish(2, text: "current")
        try await waitUntil { newText == "current" }
        XCTAssertEqual(a.key.revision, 1); XCTAssertEqual(a.cachedResult?.text, "current")
        b.close(); await gate.finish(1)
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, scheduler.resourceSnapshot.releasedJobs)
    }

    @MainActor func testLanguageKeyReplacesOneCacheAndSameKeyDoesNotRerun() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        let session = PinOCRSession(revision: 4, scheduler: scheduler, imageProvider: { image },
                                    recognize: { _, options in await gate.wait(options) })
        defer { session.close() }
        let first = Task { try await session.result(for: .resultWindow) }
        try await waitUntil { await gate.started == 1 }
        await gate.finish(0, text: "automatic language")
        _ = try await first.value
        let english = RecognitionOptions(language: "en-US")
        let second = Task { try await session.result(for: .resultWindow, options: english) }
        try await waitUntil { await gate.started == 2 }
        XCTAssertNil(session.cachedResult)
        XCTAssertEqual(session.key, PinOCRKey(revision: 4, options: english))
        await gate.finish(1, text: "English")
        _ = try await second.value
        session.update(revision: 4, options: english)
        let cached = try await session.result(for: .selection)
        XCTAssertEqual(cached.text, "English")
        let options = await gate.options
        XCTAssertEqual(options, [RecognitionOptions(), english])
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 2)
    }

    @MainActor func testSuspendResumeAndCloseRejectStaleAutomaticResults() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        let session = PinOCRSession(scheduler: scheduler, imageProvider: { image }, recognize: { _, options in await gate.wait(options) })
        session.scheduleAutomatic()
        try await waitUntil { await gate.started == 1 }
        session.suspend()
        XCTAssertEqual(session.state, .suspended)
        session.scheduleAutomatic()
        await gate.finish(0, text: "hidden result")
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertNil(session.cachedResult)
        session.resume()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 1)
        session.scheduleAutomatic()
        try await waitUntil { await gate.started == 2 }
        session.close(); session.resume(); session.scheduleAutomatic()
        await gate.finish(1, text: "closed result")
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertEqual(session.state, .closed)
        XCTAssertNil(session.cachedResult); XCTAssertNil(session.onChange)
    }

    @MainActor func testOldSubscriberCancellationCannotCancelNewSamePurposeSubscription() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        let session = PinOCRSession(scheduler: scheduler, imageProvider: { image }, recognize: { _, options in await gate.wait(options) })
        defer { session.close() }
        var cancellations = 0, newText: String?
        let old = session.request(.selection) { if case .failure(let error) = $0, error is CancellationError { cancellations += 1 } }
        session.request(.selection) { newText = try? $0.get().text }
        session.cancelRequest(old)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.cancelledJobs, 0)
        try await waitUntil { await gate.started == 1 }
        await gate.finish(0, text: "new subscriber")
        try await waitUntil { newText == "new subscriber" }
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 1)
    }

    @MainActor func testAlreadyCancelledAsyncConsumerDoesNotFetchRaster() async throws {
        let scheduler = PinOCRScheduler(), image = try raster()
        var reads = 0
        let session = PinOCRSession(scheduler: scheduler, imageProvider: { reads += 1; return image },
                                    recognize: { _, _ in RecognitionResult(text: "unexpected", barcodes: []) })
        defer { session.close() }
        let task = Task { try await session.result(for: .copyAll) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled consumer returned a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 0)
    }

    @MainActor func testAsyncConsumerCancellationPreservesAutomaticAndOtherConsumers() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        let session = PinOCRSession(scheduler: scheduler, imageProvider: { image }, recognize: { _, options in await gate.wait(options) })
        defer { session.close() }
        session.scheduleAutomatic()
        let selection = Task { try await session.result(for: .selection) }
        let resultWindow = Task { try await session.result(for: .resultWindow) }
        try await waitUntil { await gate.started == 1 }
        selection.cancel()
        do { _ = try await selection.value; XCTFail("Cancelled selection returned a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(scheduler.resourceSnapshot.cancelledJobs, 0)
        await gate.finish(0, text: "still current")
        let result = try await resultWindow.value
        XCTAssertEqual(result.text, "still current")
        XCTAssertEqual(session.cachedResult?.text, "still current")
    }

    @MainActor func testQueuedAndRunningSessionsHaveWeakOwnershipAndDeterministicRelease() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        var running: PinOCRSession? = PinOCRSession(scheduler: scheduler, imageProvider: { image },
                                                   recognize: { _, options in await gate.wait(options) })
        var queued: PinOCRSession? = PinOCRSession(scheduler: scheduler, imageProvider: { XCTFail("Queued raster was fetched"); return image },
                                                  recognize: { _, options in await gate.wait(options) })
        weak var weakRunning = running
        weak var weakQueued = queued
        running?.scheduleAutomatic(); queued?.scheduleAutomatic()
        try await waitUntil { await gate.started == 1 }
        running = nil; queued = nil
        XCTAssertNil(weakRunning); XCTAssertNil(weakQueued)
        try await waitUntil { scheduler.resourceSnapshot.cancelledJobs == 1 }
        XCTAssertEqual(scheduler.resourceSnapshot.waitingSessions, 0)
        XCTAssertEqual(scheduler.resourceSnapshot.activeJobs, 1)
        await gate.finish(0)
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.releasedJobs, 1)
    }

    @MainActor func testMissingRasterFailsWithoutOccupyingNativePermitAndCanRetry() async throws {
        let scheduler = PinOCRScheduler(), image = try raster()
        var sourceAvailable = false, failure = false, text: String?
        let session = PinOCRSession(scheduler: scheduler, imageProvider: { sourceAvailable ? image : nil },
                                    recognize: { _, _ in RecognitionResult(text: "retry", barcodes: []) })
        defer { session.close() }
        session.request(.copyAll) { if case .failure(let error) = $0 { failure = error is PinOCRError } }
        XCTAssertTrue(failure); XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 0)
        sourceAvailable = true
        session.request(.copyAll) { text = try? $0.get().text }
        try await waitUntil { text == "retry" }
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, 1)
        XCTAssertEqual(scheduler.resourceSnapshot.releasedJobs, 1)
    }

    @MainActor func testObserverImageChangeCannotDeliverOldGeometryToPendingConsumers() async throws {
        let scheduler = PinOCRScheduler(), gate = PinOCRTestGate(), image = try raster()
        let session = PinOCRSession(scheduler: scheduler, imageProvider: { image }, recognize: { _, options in await gate.wait(options) })
        defer { session.close() }
        var cancelled = 0, successes = 0
        session.onChange = { [weak session] in
            if session?.state == .ready { session?.update(revision: 1) }
        }
        for consumer in [PinOCRConsumer.selection, .copyAll, .resultWindow] {
            session.request(consumer) {
                switch $0 {
                case .success: successes += 1
                case .failure(let error): if error is CancellationError { cancelled += 1 }
                }
            }
        }
        try await waitUntil { await gate.started == 1 }
        await gate.finish(0, text: "old geometry")
        try await waitUntil { cancelled == 3 }
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(session.key.revision, 1)
        XCTAssertNil(session.cachedResult)
    }

    @MainActor func testCancellationDuringSynchronousRegistrationResumesExactlyOnce() async throws {
        let scheduler = PinOCRScheduler(), image = try raster()
        let session = PinOCRSession(scheduler: scheduler, imageProvider: { image },
                                    recognize: { _, _ in RecognitionResult(text: "completed", barcodes: []) })
        defer { session.close() }
        var task: Task<RecognitionResult, Error>?
        session.onChange = { [weak session] in if session?.state == .queued { task?.cancel() } }
        task = Task { try await session.result(for: .selection) }
        do { _ = try await task?.value; XCTFail("Cancellation during registration returned a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await waitUntil { scheduler.resourceSnapshot.activeJobs == 0 }
        XCTAssertNil(session.cachedResult)
        XCTAssertEqual(scheduler.resourceSnapshot.admittedJobs, scheduler.resourceSnapshot.releasedJobs)
    }

    @MainActor private func raster() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                              bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Bounded OCR test condition timed out")
        if !satisfied { throw PinOCRError.sourceUnavailable }
    }
}

private actor PinOCRTestGate {
    private var continuations: [Int: CheckedContinuation<RecognitionResult, Never>] = [:]
    private(set) var options: [RecognitionOptions] = []
    var started: Int { options.count }

    func wait(_ option: RecognitionOptions) async -> RecognitionResult {
        let index = options.count
        options.append(option)
        return await withCheckedContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, text: String = "recognized") {
        continuations.removeValue(forKey: index)?.resume(returning: RecognitionResult(text: text, barcodes: []))
    }
    func finishAll() {
        for index in Array(continuations.keys) { finish(index) }
    }
}
