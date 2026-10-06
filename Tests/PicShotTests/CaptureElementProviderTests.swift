import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor final class CaptureElementProviderTests: XCTestCase {
    private let display = CGRect(x: -640, y: -180, width: 640, height: 400)
    private let frozenAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testNegativeDisplayGeometryUsesQuartzTopLeftAndActualRetinaPixels() throws {
        let global = CGRect(x: -599.75, y: -149.25, width: 92.5, height: 44.25)
        let local = try XCTUnwrap(CaptureElementGeometry.localFrame(global, displayBounds: display))
        XCTAssertEqual(local, CGRect(x: 40.25, y: 30.75, width: 92.5, height: 44.25))
        let geometry = try FrozenCaptureGeometry(pointSize: display.size, pixelWidth: 1280, pixelHeight: 800)
        XCTAssertEqual(try geometry.alignedSelection(local).pixelFrame, CGRect(x: 80, y: 61, width: 186, height: 89))
        XCTAssertNil(CaptureElementGeometry.localFrame(CGRect(x: -641, y: 0, width: 10, height: 10), displayBounds: display))
        XCTAssertNil(CaptureElementGeometry.localFrame(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), displayBounds: display))
    }

    func testSnapshotRejectsCyclesInconsistentEdgesOversizeAndForeignFrames() {
        let good = snapshot(point: CGPoint(x: -560, y: -100))
        XCTAssertTrue(good.validated(displayBounds: display))
        var nodes = good.nodes; nodes[1].parent = 0; nodes[0].children.append(1)
        XCTAssertFalse(copy(good, nodes: nodes).validated(displayBounds: display))
        nodes = good.nodes; nodes[1].children = []
        XCTAssertFalse(copy(good, nodes: nodes).validated(displayBounds: display))
        nodes = good.nodes; nodes[1].parent = 999
        XCTAssertFalse(copy(good, nodes: nodes).validated(displayBounds: display))
        nodes = (0..<13).map { index in
            CaptureElementNode(frame: good.nodes[0].frame, role: "AXGroup", parent: index == 12 ? nil : index + 1,
                               children: index == 0 ? [] : [index - 1])
        }
        XCTAssertFalse(copy(good, nodes: nodes).validated(displayBounds: display))
        XCTAssertFalse(copy(good, nodes: Array(repeating: good.nodes[0], count: 81)).validated(displayBounds: display))
        XCTAssertFalse(good.validated(displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
    }

    func testBudgetHasHardCallDeadlineAndCancellationBounds() {
        var budget = CaptureElementBudget(started: 10)
        for _ in 0..<CaptureElementLimits.maximumCalls { XCTAssertTrue(budget.admit(now: 10.01, cancelled: false)) }
        XCTAssertFalse(budget.admit(now: 10.01, cancelled: false))
        budget = CaptureElementBudget(started: 10)
        XCTAssertFalse(budget.admit(now: 10.21, cancelled: false))
        XCTAssertFalse(budget.admit(now: 9.9, cancelled: false))
        XCTAssertFalse(budget.admit(now: .nan, cancelled: false))
        XCTAssertFalse(budget.admit(now: 10.01, cancelled: true))
        XCTAssertEqual(budget.calls, 0)
    }

    func testParentChildUndoAndGenerationRaceRejectLateOldSnapshot() async throws {
        let provider = DeferredCaptureElements(), session = CaptureElementSession(provider: provider)
        var notifications = 0
        session.changed = { _ in notifications += 1 }
        let first = request(point: CGPoint(x: -560, y: -100)), second = request(point: CGPoint(x: -550, y: -90))
        session.request(first, debounceNanoseconds: 0)
        try await waitForRequests(provider, count: 1)
        session.request(second, debounceNanoseconds: 0)
        try await waitForRequests(provider, count: 2)
        await provider.complete(1, .snapshot(snapshot(point: second.point)))
        try await waitUntil { notifications == 1 }
        XCTAssertEqual(session.snapshot?.point, second.point)
        XCTAssertTrue(session.traverse(parent: true)); XCTAssertEqual(session.index, 1)
        XCTAssertTrue(session.traverse(parent: false)); XCTAssertEqual(session.index, 0)
        XCTAssertTrue(session.undoTraversal()); XCTAssertEqual(session.index, 1)
        await provider.complete(0, .snapshot(snapshot(point: first.point)))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(notifications, 1); XCTAssertEqual(session.snapshot?.point, second.point)
        session.stop(); XCTAssertNil(session.snapshot)
    }

    func testCancelManualDragOrCloseDiscardsUncooperativeProviderCompletion() async throws {
        let provider = DeferredCaptureElements(), session = CaptureElementSession(provider: provider)
        var notifications = 0; session.changed = { _ in notifications += 1 }
        let request = request(point: CGPoint(x: -560, y: -100))
        session.request(request, debounceNanoseconds: 0); try await waitForRequests(provider, count: 1)
        session.invalidate()
        await provider.complete(0, .snapshot(snapshot(point: request.point)))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(session.snapshot); XCTAssertEqual(notifications, 0)
    }

    func testUnsupportedPermissionAndMismatchedFrozenFrameNeverProduceSelection() async throws {
        for failure in [CaptureElementUnavailable.permission, .unsupported, .timedOut, .stale] {
            let provider = DeferredCaptureElements(), session = CaptureElementSession(provider: provider)
            var result: CaptureElementResult?
            session.changed = { result = $0 }
            let request = request(point: CGPoint(x: -560, y: -100))
            session.request(request, debounceNanoseconds: 0); try await waitForRequests(provider, count: 1)
            await provider.complete(0, .unavailable(failure)); try await waitUntil { result != nil }
            XCTAssertNil(session.selectedNode); session.stop()
        }
        let provider = DeferredCaptureElements(), session = CaptureElementSession(provider: provider)
        var wasStale = false
        session.changed = { if case .unavailable(.stale) = $0 { wasStale = true } }
        let request = request(point: CGPoint(x: -560, y: -100))
        session.request(request, debounceNanoseconds: 0); try await waitForRequests(provider, count: 1)
        let wrong = CaptureElementSnapshot(nodes: snapshot(point: request.point).nodes, hit: 0,
                                           sampledAt: Date(), frozenAt: frozenAt.addingTimeInterval(1), point: request.point)
        await provider.complete(0, .snapshot(wrong)); try await waitUntil { wasStale }
        XCTAssertNil(session.selectedNode)
    }

    func testNamedPresetCountdownCancellationNeverReachesCaptureWork() async throws {
        let display = try CapturePresetDisplay(uuid: UUID(), frame: self.display, pixelWidth: 1280, pixelHeight: 800, rotationDegrees: 0)
        let preset = try CapturePreset(name: "延时取消", delay: .tenSeconds, display: display,
                                       topLeftFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
                                       pixelFrame: CGRect(x: 20, y: 20, width: 40, height: 40))
        var wouldCapture = false
        let task = Task { @MainActor in
            try await preset.delay.wait()
            wouldCapture = true
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled countdown completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(wouldCapture)
    }

    func testCancelledPresetDoesNotAskForScreenAccess() async throws {
        let target = try CapturePresetDisplay(uuid: UUID(), frame: display, pixelWidth: 1280, pixelHeight: 800, rotationDegrees: 0)
        let preset = try CapturePreset(name: "取消测试", delay: .tenSeconds, display: target,
                                       topLeftFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
                                       pixelFrame: CGRect(x: 20, y: 20, width: 40, height: 40))
        let service = CaptureService()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.capturePreset(preset)
        }
        do { _ = try await task.value; XCTFail("Cancelled preset returned pixels") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func request(point: CGPoint) -> CaptureElementRequest {
        CaptureElementRequest(point: point, displayBounds: display, windows: [], frozenAt: frozenAt)
    }
    private func snapshot(point: CGPoint) -> CaptureElementSnapshot {
        CaptureElementSnapshot(nodes: [
            CaptureElementNode(frame: CGRect(x: -580, y: -120, width: 100, height: 60), role: "AXButton", parent: 1, children: []),
            CaptureElementNode(frame: CGRect(x: -620, y: -160, width: 300, height: 220), role: "AXGroup", parent: nil, children: [0])
        ], hit: 0, sampledAt: frozenAt.addingTimeInterval(0.1), frozenAt: frozenAt, point: point)
    }
    private func copy(_ snapshot: CaptureElementSnapshot, nodes: [CaptureElementNode]) -> CaptureElementSnapshot {
        CaptureElementSnapshot(nodes: nodes, hit: snapshot.hit, sampledAt: snapshot.sampledAt, frozenAt: snapshot.frozenAt, point: snapshot.point)
    }
    private func waitForRequests(_ provider: DeferredCaptureElements, count: Int) async throws {
        for _ in 0..<200 { if await provider.count >= count { return }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("Fake provider was not requested"); throw CaptureError.cancelled
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("Selection callback did not arrive"); throw CaptureError.cancelled
    }
}

private actor DeferredCaptureElements: CaptureElementProviding {
    var pending: [Int: CheckedContinuation<CaptureElementResult, Never>] = [:]
    private(set) var count = 0
    func snapshot(_ request: CaptureElementRequest, cancellation: CaptureElementCancellation) async -> CaptureElementResult {
        let index = count; count += 1
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, _ result: CaptureElementResult) { pending.removeValue(forKey: index)?.resume(returning: result) }
}
