import AppKit
import XCTest
@testable import PicShot

/// Real prepared provider ownership with deterministic time/suspension. These
/// tests do not establish AppKit's opaque holder or installed-app acceptance.
@MainActor final class EditableProductRetirementTests: XCTestCase {
    private typealias R = EditableProductRetirement
    private final class Clock { var time = 10.0 }
    private final class Hold { var provider: CGDataProvider? }

    private func state(_ tracker: DrawingRasterTracker) -> R.State {
        .init(ownership: .init(created: 1, aliveNonWindowObjects: 0, liveEditors: 0, livePins: 0,
            attachedWindowGraphs: 0, retainedWindowShells: 0),
            work: .init(appEditorCount: 0, pinCount: 0, pinEditorCount: 0, projectionBusy: false,
                projectionReservedBytes: 0, projectionQueueOperations: 0, projectionStarted: 0,
                projectionCompleted: 0, exportSessions: 0, exportQueueOperations: 0),
            drawing: tracker.snapshot())
    }

    /// Retain the actual detached provider independently of its cleared cache.
    /// The autorelease scope ends before observations begin; no test image or
    /// context can accidentally be the continuing owner.
    private func heldProvider() throws -> (DrawingRasterTracker, Hold, Int) {
        let hold = Hold(), width = 64, height = 32, byteCount = 64 * 32 * 4
        var providerObservations = 0
        let configuration = DrawingRasterConfiguration(strategy: .ownedSRGB8,
            providerObserverForTesting: { provider in
                providerObservations += 1
                hold.provider = provider
            })
        try autoreleasepool {
            let data = Data(repeating: 127, count: byteCount) as CFData
            let sourceProvider = try XCTUnwrap(CGDataProvider(data: data))
            let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: color, bitmapInfo: DrawingRaster.bitmapInfo,
                provider: sourceProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let cache = DrawingRasterPresentationCache(configuration: configuration)
            let prepared = cache.image(for: source)
            XCTAssertFalse(prepared === source)
            // Holding prepared.dataProvider would be ambiguous: CoreGraphics
            // may expose an eager copy instead of our original tracked provider.
            XCTAssertEqual(providerObservations, 1)
            XCTAssertNotNil(hold.provider)
            cache.clear()
            XCTAssertEqual(cache.retainedBytes, 0)
            XCTAssertNil(cache.representation)
        }
        let observed = configuration.tracker.snapshot()
        XCTAssertEqual(observed.ownedCount, 1)
        XCTAssertEqual(observed.activeBytes, byteCount, "This test requires the actual owned provider to remain held")
        XCTAssertEqual(observed.releaseCallbacks, 0)
        return (configuration.tracker, hold, byteCount)
    }

    func testClearedCacheAndWeakJobCompletionWaitForHeldProviderThenRecordNaturalRelease() async throws {
        let (tracker, hold, byteCount) = try heldProvider()
        let clock = Clock()
        var evidence: [R.Evidence] = [], pauses = 0
        let result = try await R.wait(cycle: 5, phase: "group-hidden-released", deadline: 310,
            clock: { clock.time }, pause: { nanos in
                XCTAssertEqual(nanos, 10_000_000)
                XCTAssertFalse(evidence.isEmpty, "Original weak/job state must be recorded before waiting")
                XCTAssertEqual(evidence[0].weakJobDrained.drawing.activeBytes, byteCount)
                XCTAssertNil(evidence[0].providerRetired)
                pauses += 1; clock.time += 0.01
                if pauses == 3 { autoreleasepool { hold.provider = nil } }
            }, observe: { self.state(tracker) }, record: { evidence.append($0) })
        XCTAssertEqual(pauses, 3)
        XCTAssertEqual(result.status, "retired")
        XCTAssertEqual(result.pollCount, 3)
        XCTAssertEqual(result.elapsedSeconds, 0.03, accuracy: 0.000000001)
        XCTAssertEqual(result.weakJobDrained.drawing.activeBytes, byteCount)
        let retired = try XCTUnwrap(result.providerRetired)
        XCTAssertTrue(R.balanced(retired.drawing))
        XCTAssertEqual(retired.drawing.releaseCallbacks, 1)
        XCTAssertEqual(retired.drawing.deallocations, 1)
        XCTAssertEqual(retired.drawing.callbackBytes, byteCount)
        XCTAssertEqual(retired.ownership, result.weakJobDrained.ownership)
        XCTAssertEqual(retired.work, result.weakJobDrained.work)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["cycle", "phase", "maximumWaitSeconds", "pollIntervalSeconds",
            "status", "pollCount", "elapsedSeconds", "weakJobDrained", "providerRetired"])
    }

    func testAlreadyBalancedReturnsWithoutSleepingAndChecksCancellationAndDeadline() async throws {
        let tracker = DrawingRasterTracker(), clock = Clock()
        XCTAssertNil(DrawingRasterConfiguration(strategy: .ownedSRGB8).providerObserverForTesting)
        XCTAssertNil(DrawingRasterConfiguration(environment: [:]).providerObserverForTesting)
        XCTAssertNil(DrawingRasterConfiguration.process.providerObserverForTesting)
        var checks = 0, pauses = 0
        let result = try await R.wait(cycle: 1, phase: "seed-closed", deadline: 310,
            clock: { clock.time }, cancellation: { checks += 1 },
            pause: { _ in pauses += 1 }, observe: { self.state(tracker) }, record: { _ in })
        XCTAssertGreaterThanOrEqual(checks, 3)
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(result.pollCount, 0)
        XCTAssertEqual(result.elapsedSeconds, 0)
        XCTAssertEqual(result.providerRetired, result.weakJobDrained)
        do {
            _ = try await R.wait(cycle: 1, phase: "seed-closed", deadline: 310,
                clock: { clock.time }, cancellation: { throw CancellationError() },
                pause: { _ in XCTFail("Cancelled entry must not sleep") },
                observe: { self.state(tracker) }, record: { _ in XCTFail("Cancelled entry cannot retire") })
            XCTFail("Cancellation was ignored for an immediately true condition")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await R.wait(cycle: 1, phase: "seed-closed", deadline: clock.time,
                clock: { clock.time }, pause: { _ in XCTFail("Expired entry must not sleep") },
                observe: { self.state(tracker) }, record: { _ in XCTFail("Expired entry cannot retire") })
            XCTFail("Expired deadline was ignored for an immediately true condition")
        } catch { XCTAssertEqual(error as? R.Failure, .deadlineExceeded) }
        enum RecordFailure: Error { case rejected }
        var failedRecord: R.Evidence?
        do {
            _ = try await R.wait(cycle: 1, phase: "seed-closed", deadline: 310,
                clock: { clock.time }, pause: { _ in XCTFail("Balanced entry must not sleep") },
                observe: { self.state(tracker) }, record: { evidence in
                    if evidence.status == "retired" { throw RecordFailure.rejected }
                    if evidence.status == "failed" { failedRecord = evidence }
                })
            XCTFail("A rejected evidence write must fail")
        } catch { XCTAssertTrue(error is RecordFailure) }
        XCTAssertEqual(failedRecord?.status, "failed")
        XCTAssertNil(failedRecord?.providerRetired)
        XCTAssertEqual(failedRecord?.weakJobDrained, result.weakJobDrained)
    }

    func testRetainedProviderFailsShortCapAndPreservesOriginalEvidence() async throws {
        let (tracker, hold, byteCount) = try heldProvider()
        defer { hold.provider = nil }
        let clock = Clock()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("retirement-failure-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var evidence: [R.Evidence] = []
        do {
            _ = try await R.wait(cycle: 5, phase: "group-hidden-released", deadline: 310,
                clock: { clock.time }, pause: { _ in clock.time += 0.01 },
                observe: { self.state(tracker) }, record: { value in
                    evidence.append(value)
                    try JSONEncoder().encode(value).write(to: file, options: .atomic)
                })
            XCTFail("A live prepared provider must not pass at a weak-owner endpoint")
        } catch { XCTAssertEqual(error as? R.Failure, .retirementTimedOut) }
        let first = try XCTUnwrap(evidence.first), last = try XCTUnwrap(evidence.last)
        XCTAssertEqual(last.status, "failed")
        XCTAssertEqual(last.weakJobDrained, first.weakJobDrained)
        XCTAssertEqual(last.weakJobDrained.drawing.activeBytes, byteCount)
        XCTAssertNil(last.providerRetired)
        XCTAssertGreaterThanOrEqual(last.elapsedSeconds, 2)
        XCTAssertLessThan(last.elapsedSeconds, 2.02)
        XCTAssertEqual(tracker.snapshot().activeBytes, byteCount)
        XCTAssertEqual(try JSONDecoder().decode(R.Evidence.self, from: Data(contentsOf: file)), last,
            "The failed record must be written before the error escapes")
    }

    func testFullDeadlineAndCancellationInterruptAnOutstandingProvider() async throws {
        for cancel in [false, true] {
            let (tracker, hold, byteCount) = try heldProvider()
            defer { hold.provider = nil }
            let clock = Clock()
            var cancelled = false, evidence: [R.Evidence] = []
            do {
                _ = try await R.wait(cycle: 1, phase: "cycle-released", deadline: 10.015,
                    clock: { clock.time }, cancellation: { if cancelled { throw CancellationError() } },
                    pause: { _ in
                        clock.time += 0.01
                        if cancel {
                            autoreleasepool { hold.provider = nil }
                            cancelled = true // Cancellation wins even when this poll also releases the provider.
                        }
                    },
                    observe: { self.state(tracker) }, record: { evidence.append($0) })
                XCTFail("Pending provider accepted after cancellation/deadline")
            } catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? R.Failure, .deadlineExceeded) }
            }
            XCTAssertEqual(evidence.last?.status, "failed")
            XCTAssertNil(evidence.last?.providerRetired)
            XCTAssertEqual(evidence.first?.weakJobDrained.drawing.activeBytes, byteCount)
            if cancel { XCTAssertTrue(R.balanced(tracker.snapshot())) }
        }
    }

    func testOwnerAndJobCompletionRemainRequiredEvenWhenDrawingIsBalanced() async throws {
        let tracker = DrawingRasterTracker(), clock = Clock()
        var pauses = 0, evidence: [R.Evidence] = []
        let result = try await R.wait(cycle: 1, phase: "seed-closed", deadline: 310,
            clock: { clock.time }, pause: { _ in
                XCTAssertTrue(evidence.isEmpty, "Do not mislabel active owners/jobs as drained")
                pauses += 1; clock.time += 0.01
            }, observe: {
                var value = self.state(tracker)
                if pauses == 0 { value.ownership.aliveNonWindowObjects = 1 }
                if pauses < 2 { value.work.projectionBusy = true; value.work.projectionStarted = 1 }
                else { value.work.projectionStarted = 1; value.work.projectionCompleted = 1 }
                return value
            }, record: { evidence.append($0) })
        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(result.pollCount, 0, "Provider polls exclude the preceding weak/job wait")
        XCTAssertEqual(result.weakJobDrained.uptimeSeconds, 10.02, accuracy: 0.000000001)
    }

    func testCorruptedObservationsNewWorkAndBackwardTimeFailClosed() async throws {
        for mutation in 0..<7 {
            let (tracker, hold, _) = try heldProvider()
            defer { hold.provider = nil }
            let clock = Clock()
            var polls = 0
            do {
                _ = try await R.wait(cycle: 1, phase: "cycle-released", deadline: 310,
                    clock: { clock.time }, pause: { _ in
                        polls += 1; clock.time += mutation == 4 ? -0.01 : 0.01
                        if mutation == 5 { clock.time = .nan }
                    },
                    observe: {
                        var value = self.state(tracker)
                        switch mutation {
                        case 0: value.drawing.activeBytes = -1
                        case 1: value.drawing.callbackSizesMatch = false
                        case 2 where polls > 0: value.work.projectionStarted = 1; value.work.projectionCompleted = 1
                        case 3 where polls > 0:
                            value.drawing.referenceCount = 1
                        case 6: value.drawing.eligibleCount += 1
                        default: break
                        }
                        return value
                    }, record: { value in XCTAssertNotEqual(value.status, "retired") })
                XCTFail("Corrupted or changed observation accepted: \(mutation)")
            } catch {
                XCTAssertEqual(error as? R.Failure,
                    mutation == 2 || mutation == 3 ? .workChangedDuringRetirement : .invalidObservation)
            }
        }
    }
}
