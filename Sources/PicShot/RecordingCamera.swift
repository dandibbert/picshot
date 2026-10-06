import AVFoundation
import Combine
import CoreVideo

struct RecordingCameraDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum RecordingCameraStatus: Equatable {
    case off, requestingPermission, starting, active, failed(String)
    var message: String {
        switch self {
        case .off: return "摄像头已关闭"
        case .requestingPermission: return "等待摄像头权限…"
        case .starting: return "正在连接摄像头…"
        case .active: return "摄像头画面会写入 MP4"
        case .failed(let message): return message
        }
    }
}

/// Revoked synchronously on the main actor before asynchronous queue hops.
/// A start that enters the provider after Disable cannot open hardware; a stale
/// stop names only its own lease and cannot close a newly selected camera.
final class RecordingCameraLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); defer { lock.unlock() }; valid = false }
}

/// Injectable so tests never request TCC access or touch camera hardware.
protocol RecordingCameraProviding: AnyObject, Sendable {
    func devices() async -> [RecordingCameraDevice]
    func permission() async -> AVAuthorizationStatus
    func requestPermission() async -> Bool
    func start(deviceID: String, lease: RecordingCameraLease, frame: @escaping @Sendable (CVPixelBuffer) -> Void,
               failed: @escaping @Sendable (String) -> Void) async throws
    func stop(lease: RecordingCameraLease?) async
}

@MainActor
final class RecordingCameraController: ObservableObject {
    @Published private(set) var devices: [RecordingCameraDevice] = []
    @Published private(set) var status: RecordingCameraStatus = .off
    @Published private(set) var requested = false
    @Published var selectedID = ""
    private let provider: RecordingCameraProviding
    private let composition: RecordingCompositionState
    private var generation: UUID?
    private var lease: RecordingCameraLease?

    init(composition: RecordingCompositionState, provider: RecordingCameraProviding = AVRecordingCameraProvider()) {
        self.composition = composition; self.provider = provider
    }

    /// Device enumeration cannot trigger a permission request or open a session.
    func refreshDevices() async {
        devices = await provider.devices()
        if !devices.contains(where: { $0.id == selectedID }) { selectedID = devices.first?.id ?? "" }
    }

    /// Call only from an explicit Camera toggle or a user-started recording that
    /// already opted into Camera. Permission denial never stops screen recording.
    func enable() async {
        requested = true
        let previousLease = lease
        previousLease?.invalidate()
        let currentLease = RecordingCameraLease()
        lease = currentLease
        let token = UUID(); generation = token
        composition.setCameraSession(token)
        status = .starting
        await provider.stop(lease: previousLease)
        guard await remainsCurrent(token) else { return }
        let permission = await provider.permission()
        guard await remainsCurrent(token) else { return }
        let permitted: Bool
        if permission == .notDetermined {
            status = .requestingPermission
            permitted = await provider.requestPermission()
        } else { permitted = permission == .authorized }
        guard await remainsCurrent(token) else { return }
        guard permitted else {
            fail("摄像头未获授权，可在系统设置 → 隐私与安全性 → 摄像头中允许 PicShot。", token: token)
            return
        }
        await refreshDevices()
        guard await remainsCurrent(token) else { return }
        guard !selectedID.isEmpty else { fail("没有可用摄像头；屏幕录制可继续。", token: token); return }
        status = .starting
        do {
            let state = composition
            try await withTaskCancellationHandler {
                try await provider.start(deviceID: selectedID, lease: currentLease, frame: { pixels in
                    state.receiveCamera(pixels, token: token)
                }, failed: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.fail(message, token: token)
                        await self.provider.stop(lease: currentLease)
                    }
                })
            } onCancel: { currentLease.invalidate() }
            guard generation == token else { return }
            if Task.isCancelled { await disable(); return }
            status = .active
        } catch {
            guard generation == token else { return }
            if Task.isCancelled { await disable(); return }
            fail("摄像头不可用：\(error.localizedDescription)。屏幕录制可继续。", token: token)
            await provider.stop(lease: currentLease)
        }
    }

    private func remainsCurrent(_ token: UUID) async -> Bool {
        guard generation == token else { return false }
        if Task.isCancelled { await disable(); return false }
        return true
    }

    private func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        lease?.invalidate(); lease = nil
        generation = nil; requested = false
        composition.setCameraSession(nil)
        status = .failed(message)
    }

    func disable() async {
        let previousLease = lease
        previousLease?.invalidate(); lease = nil
        requested = false; generation = nil
        composition.setCameraSession(nil); status = .off
        await provider.stop(lease: previousLease)
    }

    /// Preserve an explicit opt-in over Save-and-restart, but release hardware
    /// while no recording is active. Ordinary Stop disables Camera completely.
    func suspend() async {
        let previousLease = lease
        previousLease?.invalidate(); lease = nil
        generation = nil; composition.setCameraSession(nil); status = .off
        await provider.stop(lease: previousLease)
    }
}

/// Queue-confined generation gate. Removing a notification observer does not
/// cancel a callback already queued behind the next camera's start operation.
struct RecordingCameraEventGate {
    private var current: UUID?
    mutating func begin() -> UUID { let token = UUID(); current = token; return token }
    mutating func invalidate() { current = nil }
    func accepts(_ token: UUID) -> Bool { current == token }
}

/// AVCaptureSession and its inputs/outputs are confined to one serial queue.
/// Late camera frames are discarded by AVFoundation and replaced in one slot.
final class AVRecordingCameraProvider: NSObject, RecordingCameraProviding, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PicShot.Recording.Camera", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let session = AVCaptureSession()
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?
    private var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var eventGate = RecordingCameraEventGate()
    private var activeLease: RecordingCameraLease?

    func devices() async -> [RecordingCameraDevice] {
        await withCheckedContinuation { continuation in
            queue.async {
                let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
                    mediaType: .video, position: .unspecified)
                continuation.resume(returning: discovery.devices.map { RecordingCameraDevice(id: $0.uniqueID, name: $0.localizedName) })
            }
        }
    }

    func permission() async -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    func start(deviceID: String, lease: RecordingCameraLease, frame: @escaping @Sendable (CVPixelBuffer) -> Void,
               failed: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard lease.isValid else { continuation.resume(throwing: CancellationError()); return }
                self.tearDown()
                self.activeLease = lease
                do {
                    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                          let device = AVCaptureDevice(uniqueID: deviceID) else {
                        throw RecordingError.failed("The selected camera is disconnected or permission was denied.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.session.beginConfiguration()
                    guard self.session.canSetSessionPreset(.vga640x480) else {
                        self.session.commitConfiguration()
                        throw RecordingError.failed("This camera does not offer a bounded 640 × 480 capture format.")
                    }
                    self.session.sessionPreset = .vga640x480
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration()
                        throw RecordingError.failed("The selected camera format is unavailable.")
                    }
                    self.session.addInput(input); self.session.addOutput(output)
                    self.input = input; self.output = output
                    self.onFrame = frame; self.onFailure = failed
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                    }
                    self.session.commitConfiguration()
                    let token = self.eventGate.begin()
                    let center = NotificationCenter.default
                    self.observers.append(center.addObserver(forName: .AVCaptureDeviceWasDisconnected,
                        object: device, queue: nil) { [weak self] _ in
                        self?.queue.async { [weak self] in self?.cameraFailed("摄像头已断开；屏幕录制仍在继续。", token: token) }
                    })
                    self.observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError,
                        object: self.session, queue: nil) { [weak self] _ in
                        self?.queue.async { [weak self] in self?.cameraFailed("摄像头会话中断；屏幕录制仍在继续。", token: token) }
                    })
                    self.observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                        object: self.session, queue: nil) { [weak self] _ in
                        self?.queue.async { [weak self] in self?.cameraFailed("摄像头暂时被中断；可重新开启，屏幕录制仍在继续。", token: token) }
                    })
                    guard lease.isValid else { throw CancellationError() }
                    self.session.startRunning()
                    guard self.session.isRunning else { throw RecordingError.failed("The camera did not start.") }
                    guard lease.isValid else { throw CancellationError() }
                    continuation.resume()
                } catch {
                    self.tearDown(); continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop(lease: RecordingCameraLease?) async {
        guard let lease else { return }
        lease.invalidate()
        await withCheckedContinuation { continuation in
            queue.async {
                if self.activeLease === lease { self.tearDown() }
                continuation.resume()
            }
        }
    }

    private func cameraFailed(_ message: String, token: UUID) {
        guard eventGate.accepts(token) else { return }
        let callback = onFailure
        tearDown()
        callback?(message)
    }

    private func tearDown() {
        eventGate.invalidate()
        activeLease = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        onFrame = nil; onFailure = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if let output { session.removeOutput(output) }
        session.commitConfiguration()
        input = nil; output = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard activeLease?.isValid == true, output === self.output, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixels)
    }
}
