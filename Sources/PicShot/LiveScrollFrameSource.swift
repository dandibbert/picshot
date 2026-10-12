import AppKit
import PicShotCore

/// The session consumes this interface identically for production SCStream input
/// and explicit synthetic verification. Injected frames are never capture evidence.
@MainActor
protocol LiveScrollFrameSource: AnyObject {
    var region: CGRect { get }
    var displayBounds: CGRect { get }
    var target: LiveScrollScreenSource.Target? { get }
    /// Producer callback fence, not a presentation-time or input-causality claim.
    var automaticScrollWatermark: LiveScrollFrameWatermark? { get }
    func start() async throws
    func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame?
    func pauseAndDrain() async throws
    func resume() async throws
    func stop() async throws
    func moveRegion(to proposed: CGRect) throws
    func validateTarget() throws
}

extension LiveScrollFrameSource {
    /// Sources without a producer fence remain available for manual capture.
    var automaticScrollWatermark: LiveScrollFrameWatermark? { nil }
}

extension LiveScrollScreenSource: LiveScrollFrameSource { }

/// Verification only: no screen discovery, TCC calls, OS input, or desktop reads.
/// At most one image-provider operation exists. A timed-out read reuses that
/// operation; it never starts additional tasks to outrun an uncooperative provider.
@MainActor
final class LiveScrollVerificationFrameSource: LiveScrollFrameSource {
    private(set) var region: CGRect
    let displayBounds: CGRect
    let target: LiveScrollScreenSource.Target?
    private let imageProvider: @MainActor () async throws -> CGImage?
    private let mailbox = LiveScrollFrameMailbox<LiveScrollScreenSource.Frame>()
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var expectedPixelSize: CGSize?
    private var state: State = .idle
    private var worker: Worker?
    private var teardown: Task<Void, Error>?
    private var terminalRequested = false
    private var readInFlight = false
    private var readDrain: CheckedContinuation<Void, Never>?

    var automaticScrollWatermark: LiveScrollFrameWatermark? { mailbox.frameWatermark }

    private enum State { case idle, running, draining, paused, stopped, failed }
    private struct Worker {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
        let drained: LiveScrollFrameMailbox<Bool>
    }

    init(region: CGRect, displayBounds: CGRect, target: LiveScrollScreenSource.Target? = nil,
         image: @escaping @MainActor () async throws -> CGImage?) throws {
        guard displayBounds.minX.isFinite, displayBounds.minY.isFinite,
              displayBounds.width.isFinite, displayBounds.height.isFinite,
              displayBounds.width > 0, displayBounds.height > 0,
              region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite,
              region.width >= 8, region.height >= 16,
              CGRect(origin: .zero, size: displayBounds.size).contains(region) else { throw CaptureError.invalidRegion }
        self.region = region; self.displayBounds = displayBounds; self.target = target; imageProvider = image
    }

    deinit {
        mailbox.close(generation: generation)
        worker?.task.cancel()
    }

    func validateTarget() throws {
        try Task.checkCancellation()
        guard !terminalRequested, state != .stopped else { throw LiveScrollSourceError.stopped }
        guard state != .failed else { throw LiveScrollSourceError.unconfirmedTeardown }
        guard CGRect(origin: .zero, size: displayBounds.size).contains(region) else { throw CaptureError.invalidRegion }
        if let target {
            _ = try ManualScrollScreenDriver.checkedTarget(target, locked: target, region: region,
                displayBounds: displayBounds, allowMovedWindow: false)
        }
    }

    func start() async throws {
        try validateTarget()
        guard (state == .idle || state == .paused), worker == nil, teardown == nil, !readInFlight else {
            throw LiveScrollSourceError.transitionInProgress
        }
        generation &+= 1
        mailbox.activate(generation: generation, width: Int(expectedPixelSize?.width ?? 0),
                          height: Int(expectedPixelSize?.height ?? 0))
        state = .running
    }

    func resume() async throws { try await start() }

    func nextFrame(timeout: TimeInterval = 0.75) async throws -> LiveScrollScreenSource.Frame? {
        guard state == .running else { throw terminalRequested ? LiveScrollSourceError.stopped : LiveScrollSourceError.paused }
        guard !readInFlight else { throw LiveScrollSourceError.concurrentRead }
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw LiveScrollSourceError.invalidTimeout }
        try validateTarget()
        let token = generation
        readInFlight = true
        do {
            if worker == nil, mailbox.counters.pendingFrames == 0 { beginImage(token: token) }
            let result = try await mailbox.next(generation: token, timeout: timeout)
            try Task.checkCancellation()
            guard state == .running, generation == token else { throw CancellationError() }
            try validateTarget()
            finishRead()
            return result
        } catch {
            finishRead()
            if generation == token {
                mailbox.close(generation: token, error: error)
                try await halt(terminal: error is CancellationError)
            }
            throw error
        }
    }

    func pauseAndDrain() async throws { try await halt(terminal: false) }
    func stop() async throws { try await halt(terminal: true) }

    func moveRegion(to proposed: CGRect) throws {
        try Task.checkCancellation()
        guard state == .paused, worker == nil, teardown == nil, !readInFlight, !terminalRequested else { throw CaptureError.busy }
        let displayPixels = expectedPixelSize.map {
            CGSize(width: displayBounds.width * $0.width / region.width,
                   height: displayBounds.height * $0.height / region.height)
        }
        let moved = try ManualScrollScreenDriver.movedRegion(proposed, original: region,
            screenSize: displayBounds.size, displayPixels: displayPixels, expectedPixels: expectedPixelSize)
        if let target {
            _ = try ManualScrollScreenDriver.checkedTarget(target, locked: target, region: moved,
                displayBounds: displayBounds, allowMovedWindow: true)
        }
        region = moved
    }

    private func beginImage(token: UInt64) {
        let id = UUID()
        let drained = LiveScrollFrameMailbox<Bool>()
        drained.activate(generation: token, width: 0, height: 0)
        let imageProvider = self.imageProvider
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                if let supplied = try await imageProvider() {
                    try Task.checkCancellation()
                    // This is the only raster copy, and no source image is kept by the provider.
                    let owned = try Self.ownedImage(supplied)
                    try Task.checkCancellation()
                    self?.receive(owned, token: token)
                }
            } catch {
                self?.mailbox.close(generation: token, error: error)
            }
            if self?.worker?.id == id { self?.worker = nil }
            drained.offer(true, generation: token)
        }
        worker = Worker(id: id, generation: token, task: task, drained: drained)
    }

    private func receive(_ image: CGImage, token: UInt64) {
        guard state == .running, generation == token, !terminalRequested else { return }
        let pixels = CGSize(width: image.width, height: image.height)
        guard expectedPixelSize == nil || expectedPixelSize == pixels else {
            mailbox.close(generation: token, error: ScrollStitchError.differentDimensions); return
        }
        expectedPixelSize = pixels
        sequence &+= 1
        mailbox.offer(LiveScrollScreenSource.Frame(image: image, sequence: sequence, generation: token,
            timestamp: ProcessInfo.processInfo.systemUptime, region: region), generation: token, sequence: sequence)
    }

    private func halt(terminal: Bool) async throws {
        terminalRequested = terminalRequested || terminal
        if let teardown { try await teardown.value; return }
        if state == .stopped { return }
        if state == .failed { throw LiveScrollSourceError.unconfirmedTeardown }
        let token = generation
        generation &+= 1; state = .draining
        mailbox.close(generation: token)
        let old = worker
        old?.task.cancel()
        // An independent teardown task can drain a cancelled nextFrame caller.
        let operation = Task {
            do {
                if let old {
                    guard try await old.drained.next(generation: old.generation,
                                                    timeout: LiveScrollScreenSource.operationTimeout) != nil else {
                        throw LiveScrollSourceError.operationTimedOut("验证帧清理")
                    }
                }
                if self.readInFlight { await withCheckedContinuation { self.readDrain = $0 } }
                self.teardown = nil
                self.state = self.terminalRequested ? .stopped : .paused
            } catch {
                self.teardown = nil; self.state = .failed
                throw error
            }
        }
        teardown = operation
        try await operation.value
    }

    private func finishRead() {
        readInFlight = false
        let drained = readDrain; readDrain = nil; drained?.resume()
    }

    private static func ownedImage(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= ScrollFrame.maximumDimension,
              height <= ScrollFrame.maximumDimension, width <= ScrollFrame.maximumPixels / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw ScrollStitchError.invalidPixels
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let owned = context.makeImage() else { throw ScrollStitchError.invalidPixels }
        return owned
    }
}
