import XCTest
import AVFoundation
@testable import PicShot

@MainActor
final class RecordingCameraTests: XCTestCase {
    func testEnumerationNeverRequestsPermissionOrStartsCapture() async {
        let provider = CameraProviderFixture(permission: .notDetermined)
        let controller = RecordingCameraController(composition: RecordingCompositionState(), provider: provider)
        await controller.refreshDevices()
        XCTAssertEqual(controller.devices.map(\.id), ["camera-1", "camera-2"])
        let calls = await provider.counts()
        XCTAssertEqual(calls.requests, 0); XCTAssertEqual(calls.starts, 0)
        XCTAssertFalse(controller.requested); XCTAssertEqual(controller.status, .off)
    }

    func testExplicitPermissionDenialLeavesScreenCompositionAvailable() async {
        let provider = CameraProviderFixture(permission: .denied)
        let state = RecordingCompositionState()
        let controller = RecordingCameraController(composition: state, provider: provider)
        await controller.enable()
        guard case .failed = controller.status else { return XCTFail("Denial must be visible") }
        XCTAssertNil(state.snapshot().camera); XCTAssertFalse(controller.requested)
        let calls = await provider.counts()
        XCTAssertEqual(calls.requests, 0); XCTAssertEqual(calls.starts, 0)
    }

    func testDisableDuringPermissionPromptRejectsLateGrant() async throws {
        let provider = CameraProviderFixture(permission: .notDetermined, delayPermission: true)
        let state = RecordingCompositionState()
        let controller = RecordingCameraController(composition: state, provider: provider)
        let enabling = Task { await controller.enable() }
        try await waitUntil { controller.status == .requestingPermission }
        await controller.disable()
        await provider.resolvePermission(true)
        await enabling.value
        XCTAssertEqual(controller.status, .off); XCTAssertFalse(controller.requested)
        XCTAssertNil(state.snapshot().camera)
        let calls = await provider.counts(); XCTAssertEqual(calls.starts, 0)
    }

    func testCancelledPermissionTaskDoesNotStartHardwareAfterGrant() async throws {
        let provider = CameraProviderFixture(permission: .notDetermined, delayPermission: true)
        let controller = RecordingCameraController(composition: RecordingCompositionState(), provider: provider)
        let enabling = Task { await controller.enable() }
        try await waitUntil { controller.status == .requestingPermission }
        enabling.cancel(); await provider.resolvePermission(true); await enabling.value
        XCTAssertEqual(controller.status, .off); XCTAssertFalse(controller.requested)
        let calls = await provider.counts(); XCTAssertEqual(calls.starts, 0)
    }

    func testSelectedDeviceSwitchAndDisconnectClearFrameAndStopOnlyCamera() async throws {
        let provider = CameraProviderFixture(permission: .authorized)
        let state = RecordingCompositionState()
        let controller = RecordingCameraController(composition: state, provider: provider)
        await controller.refreshDevices(); controller.selectedID = "camera-2"
        await controller.enable()
        XCTAssertEqual(controller.status, .active)
        let started = await provider.startedDevices(); XCTAssertEqual(started, ["camera-2"])
        let first = try RecordingOverlayFixtures.pixels(width: 32, height: 24, color: .red)
        await provider.emit(first)
        XCTAssertNotNil(state.snapshot().camera)
        controller.selectedID = "camera-1"; await controller.enable()
        XCTAssertNil(state.snapshot().camera, "Device switching must not leak the prior camera frame")
        await provider.disconnect()
        try await waitUntil { if case .failed = controller.status { return true }; return false }
        XCTAssertNil(state.snapshot().camera); XCTAssertFalse(controller.requested)
        await provider.emitStale(first)
        XCTAssertNil(state.snapshot().camera, "Disconnected callback generation must be rejected")
        let annotation = ImageAnnotation(tool: .rectangle, points: [.zero, CGPoint(x: 20, y: 20)])
        XCTAssertTrue(state.setAnnotations([annotation]), "Camera failure must not disable recording annotations")
    }

    func testDisableWhileStartIsSuspendedRevokesHardwareLeaseBeforeCompletion() async throws {
        let provider = CameraProviderFixture(permission: .authorized, delayStart: true)
        let controller = RecordingCameraController(composition: RecordingCompositionState(), provider: provider)
        let enabling = Task { await controller.enable() }
        try await waitForStart(provider)
        await controller.disable()
        await provider.resolveStart(); await enabling.value
        XCTAssertEqual(controller.status, .off); XCTAssertFalse(controller.requested)
        let device = await provider.activeDevice(); XCTAssertNil(device)
    }

    func testTaskCancellationRevokesLeaseWhileProviderStartIsSuspended() async throws {
        let provider = CameraProviderFixture(permission: .authorized, delayStart: true)
        let controller = RecordingCameraController(composition: RecordingCompositionState(), provider: provider)
        let enabling = Task { await controller.enable() }
        try await waitForStart(provider)
        enabling.cancel()
        await provider.resolveStart(); await enabling.value
        let device = await provider.activeDevice(); XCTAssertNil(device)
        XCTAssertEqual(controller.status, .off); XCTAssertFalse(controller.requested)
    }

    func testOlderStartCompletionCannotReplaceOrStopNewCameraLease() async throws {
        let provider = CameraProviderFixture(permission: .authorized, delayStart: true)
        let controller = RecordingCameraController(composition: RecordingCompositionState(), provider: provider)
        await controller.refreshDevices()
        let old = Task { await controller.enable() }
        try await waitForStart(provider)
        controller.selectedID = "camera-2"
        await controller.enable()
        await provider.resolveStart(); await old.value
        let device = await provider.activeDevice()
        XCTAssertEqual(device, "camera-2"); XCTAssertEqual(controller.status, .active)
        await controller.disable()
    }

    private func waitForStart(_ provider: CameraProviderFixture) async throws {
        let end = Date().addingTimeInterval(5)
        while !(await provider.startIsWaiting()) {
            guard Date() < end else { throw RecordingError.failed("The camera start fixture did not settle.") }
            await Task.yield()
        }
    }

    func testQueuedOldProviderNotificationCannotInvalidateNewSession() {
        var gate = RecordingCameraEventGate()
        let old = gate.begin()
        XCTAssertTrue(gate.accepts(old))
        gate.invalidate()
        let current = gate.begin()
        XCTAssertFalse(gate.accepts(old), "An old queued failure must be dropped before accessing new-session handlers")
        XCTAssertTrue(gate.accepts(current))
        gate.invalidate(); XCTAssertFalse(gate.accepts(current))
    }

    func testLateFailureFromOldProviderCannotTurnOffNewSelectedDevice() async {
        let provider = CameraProviderFixture(permission: .authorized)
        let controller = RecordingCameraController(composition: RecordingCompositionState(), provider: provider)
        await controller.refreshDevices(); await controller.enable()
        controller.selectedID = "camera-2"; await controller.enable()
        await provider.emitStaleFailure()
        await Task.yield()
        XCTAssertEqual(controller.status, .active); XCTAssertTrue(controller.requested)
        await controller.disable()
    }

    func testCameraFrameSlotIsLatestOnlyAndRejectsOldSessionAfterDisable() throws {
        let state = RecordingCompositionState(), old = UUID(), current = UUID()
        let first = try RecordingOverlayFixtures.pixels(width: 16, height: 16, color: .red)
        let last = try RecordingOverlayFixtures.pixels(width: 16, height: 16, color: .blue)
        state.setCameraSession(old); state.receiveCamera(first, token: old)
        state.setCameraSession(current); state.receiveCamera(first, token: old)
        XCTAssertNil(state.snapshot().camera)
        for _ in 0..<1_000 { state.receiveCamera(first, token: current) }
        state.receiveCamera(last, token: current)
        XCTAssertTrue(state.snapshot().camera === last)
        state.setCameraSession(nil); state.receiveCamera(first, token: current)
        XCTAssertNil(state.snapshot().camera)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < end else { throw RecordingError.failed("The camera fixture did not settle.") }
            await Task.yield()
        }
    }
}

private actor CameraProviderFixture: RecordingCameraProviding {
    private let authorization: AVAuthorizationStatus
    private let delayPermission: Bool
    private var requests = 0, starts = 0, stops = 0
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private var permissionAnswer: Bool?
    private var frame: (@Sendable (CVPixelBuffer) -> Void)?
    private var staleFrame: (@Sendable (CVPixelBuffer) -> Void)?
    private var failure: (@Sendable (String) -> Void)?
    private var staleFailure: (@Sendable (String) -> Void)?
    private var ids: [String] = []
    private var activeLease: RecordingCameraLease?
    private var activeID: String?
    private var delayNextStart: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    init(permission: AVAuthorizationStatus, delayPermission: Bool = false, delayStart: Bool = false) {
        authorization = permission; self.delayPermission = delayPermission; delayNextStart = delayStart
    }
    func devices() async -> [RecordingCameraDevice] {
        [RecordingCameraDevice(id: "camera-1", name: "Synthetic A"), RecordingCameraDevice(id: "camera-2", name: "Synthetic B")]
    }
    func permission() async -> AVAuthorizationStatus { authorization }
    func requestPermission() async -> Bool {
        requests += 1
        if !delayPermission { return true }
        if let permissionAnswer { return permissionAnswer }
        return await withCheckedContinuation { permissionContinuation = $0 }
    }
    func resolvePermission(_ allowed: Bool) {
        permissionAnswer = allowed; permissionContinuation?.resume(returning: allowed); permissionContinuation = nil
    }
    func start(deviceID: String, lease: RecordingCameraLease, frame: @escaping @Sendable (CVPixelBuffer) -> Void,
               failed: @escaping @Sendable (String) -> Void) async throws {
        starts += 1
        if delayNextStart {
            delayNextStart = false
            await withCheckedContinuation { startContinuation = $0 }
        }
        guard lease.isValid else { throw CancellationError() }
        activeLease = lease; activeID = deviceID
        ids.append(deviceID); self.frame = frame; failure = failed
    }
    func resolveStart() { startContinuation?.resume(); startContinuation = nil }
    func startIsWaiting() -> Bool { startContinuation != nil }
    func activeDevice() -> String? { activeID }
    func stop(lease: RecordingCameraLease?) async {
        stops += 1
        guard let lease, activeLease === lease else { return }
        activeLease = nil; activeID = nil
        staleFrame = frame ?? staleFrame; staleFailure = failure ?? staleFailure; frame = nil; failure = nil
    }
    func emitStaleFailure() { staleFailure?("Synthetic old-camera failure") }
    func emit(_ pixels: CVPixelBuffer) { frame?(pixels) }
    func emitStale(_ pixels: CVPixelBuffer) { staleFrame?(pixels) }
    func disconnect() { staleFrame = frame; frame = nil; failure?("Synthetic disconnected camera") }
    func counts() -> (requests: Int, starts: Int, stops: Int) { (requests, starts, stops) }
    func startedDevices() -> [String] { ids }
}
