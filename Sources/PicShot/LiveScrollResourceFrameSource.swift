import AppKit
import Darwin

/// Diagnostic acquisition only: a fixed raw fixture, no SCK/TCC, decoder or draw.
/// Provider release callbacks account for bytes after handoff to the assembler.
final class LiveScrollResourceAllocationLedger: @unchecked Sendable {
    struct Snapshot: Encodable {
        var allocatedImages = 0, releasedImages = 0, liveImages = 0, peakLiveImages = 0
        var allocatedBytes = 0, releasedBytes = 0, liveBytes = 0, peakLiveBytes = 0
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func acquire(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        value.allocatedImages += 1; value.liveImages += 1; value.allocatedBytes += bytes; value.liveBytes += bytes
        value.peakLiveImages = max(value.peakLiveImages, value.liveImages)
        value.peakLiveBytes = max(value.peakLiveBytes, value.liveBytes)
    }
    func release(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        value.releasedImages += 1; value.liveImages -= 1; value.releasedBytes += bytes; value.liveBytes -= bytes
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class LiveScrollResourceFrameSource: LiveScrollFrameSource {
    struct Snapshot: Encodable {
        let generation: UInt64
        let state: String
        let readRequests: Int, successfulFrames: Int, idleResponses: Int
        let activeReads: Int, peakActiveReads: Int, stopRequests: Int, confirmedStops: Int
        let descriptorOpen: Bool
        let descriptorCloseConfirmed: Bool
    }
    private final class Allocation {
        let pointer: UnsafeMutableRawPointer
        let bytes: Int
        let ledger: LiveScrollResourceAllocationLedger
        init(bytes: Int, ledger: LiveScrollResourceAllocationLedger) throws {
            guard let pointer = malloc(bytes) else { throw CaptureError.invalidRegion }
            self.pointer = pointer; self.bytes = bytes; self.ledger = ledger
            ledger.acquire(bytes)
        }
        deinit { free(pointer); ledger.release(bytes) }
    }
    let region: CGRect
    let displayBounds: CGRect
    let target: LiveScrollScreenSource.Target? = nil
    let ledger: LiveScrollResourceAllocationLedger
    private var descriptor: Int32
    private var generation: UInt64 = 0
    private var state = "idle"
    private var terminal = false
    private var activeReads = 0, peakActiveReads = 0, readRequests = 0, nextIndex = 0, idleResponses = 0
    private var stopRequests = 0, confirmedStops = 0
    private var descriptorCloseConfirmed = false
    private var drain: CheckedContinuation<Void, Never>?
    private var teardown: Task<Void, Never>?

    init(input: URL, screen: NSScreen, ledger: LiveScrollResourceAllocationLedger) throws {
        guard let id = screen.displayID else { throw CaptureError.noDisplay }
        displayBounds = CGDisplayBounds(id)
        region = CGRect(x: 16, y: 16, width: 640, height: 480)
        guard CGRect(origin: .zero, size: screen.frame.size).contains(region) else { throw CaptureError.invalidRegion }
        self.ledger = ledger
        descriptor = input.withUnsafeFileSystemRepresentation { $0.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1 }
        guard descriptor >= 0 else { throw CaptureError.invalidRegion }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == Int64(LiveScrollResourceFixture.outputBytes) else {
            Darwin.close(descriptor); descriptor = -1; throw CaptureError.invalidRegion
        }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    var snapshot: Snapshot {
        Snapshot(generation: generation, state: state, readRequests: readRequests, successfulFrames: nextIndex,
            idleResponses: idleResponses, activeReads: activeReads, peakActiveReads: peakActiveReads,
            stopRequests: stopRequests, confirmedStops: confirmedStops, descriptorOpen: descriptor >= 0,
            descriptorCloseConfirmed: descriptorCloseConfirmed)
    }
    func validateTarget() throws {
        try Task.checkCancellation()
        guard !terminal, descriptor >= 0 else { throw LiveScrollSourceError.stopped }
    }
    func start() async throws {
        try validateTarget()
        guard (state == "idle" || state == "paused"), activeReads == 0, teardown == nil else {
            throw LiveScrollSourceError.transitionInProgress
        }
        generation &+= 1; state = "running"
    }
    func resume() async throws { try await start() }
    func moveRegion(to proposed: CGRect) throws { throw CaptureError.busy }

    func nextFrame(timeout: TimeInterval) async throws -> LiveScrollScreenSource.Frame? {
        try validateTarget()
        guard state == "running" else { throw LiveScrollSourceError.paused }
        guard activeReads == 0 else { throw LiveScrollSourceError.concurrentRead }
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw LiveScrollSourceError.invalidTimeout }
        let token = generation
        activeReads = 1; peakActiveReads = max(peakActiveReads, activeReads); readRequests += 1
        defer {
            activeReads = 0
            let continuation = drain; drain = nil; continuation?.resume()
        }
        let hasFrame = nextIndex < LiveScrollResourceFixture.offsets.count
        let delay = hasFrame ? min(timeout, 1.0 / 15.0) : timeout
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        try Task.checkCancellation()
        guard generation == token, state == "running", !terminal else { throw CancellationError() }
        guard hasFrame, timeout >= 1.0 / 15.0 else { idleResponses += 1; return nil }
        let image = try makeImage(offset: LiveScrollResourceFixture.offsets[nextIndex])
        try Task.checkCancellation()
        nextIndex += 1
        return LiveScrollScreenSource.Frame(image: image, sequence: UInt64(nextIndex), generation: token,
            timestamp: ProcessInfo.processInfo.systemUptime, region: region)
    }

    func pauseAndDrain() async throws {
        await halt(terminal: false)
        guard state != "failed" else { throw LiveScrollSourceError.unconfirmedTeardown }
    }
    func stop() async throws {
        stopRequests += 1; await halt(terminal: true)
        guard state == "stopped", descriptorCloseConfirmed else { throw LiveScrollSourceError.unconfirmedTeardown }
    }
    private func halt(terminal requested: Bool) async {
        terminal = terminal || requested
        if let teardown { await teardown.value; return }
        if state == "stopped" || state == "failed" { return }
        generation &+= 1; state = "draining"
        let operation = Task { @MainActor in
            if self.activeReads != 0 { await withCheckedContinuation { self.drain = $0 } }
            if self.terminal {
                if self.descriptor >= 0 {
                    self.descriptorCloseConfirmed = Darwin.close(self.descriptor) == 0
                    // Do not retry an uncertain close against a possibly reused descriptor.
                    self.descriptor = -1
                }
                self.state = self.descriptorCloseConfirmed ? "stopped" : "failed"
                if self.descriptorCloseConfirmed { self.confirmedStops += 1 }
            } else { self.state = "paused" }
            self.teardown = nil
        }
        teardown = operation
        await operation.value
    }

    private func makeImage(offset: Int) throws -> CGImage {
        let width = LiveScrollResourceFixture.width, height = LiveScrollResourceFixture.height
        let row = width * 4, headerBytes = LiveScrollResourceFixture.header * row
        let owner = try Allocation(bytes: width * height * 4, ledger: ledger)
        try read(into: owner.pointer, count: headerBytes, fileOffset: 0)
        try read(into: owner.pointer.advanced(by: headerBytes), count: (height - LiveScrollResourceFixture.header) * row,
                 fileOffset: (LiveScrollResourceFixture.header + offset) * row)
        let retained = Unmanaged.passRetained(owner)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: owner.pointer, size: owner.bytes,
            releaseData: { info, _, _ in
                if let info { Unmanaged<Allocation>.fromOpaque(info).release() }
            }) else { retained.release(); throw CaptureError.invalidRegion }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CaptureError.invalidRegion }
        return image
    }
    private func read(into destination: UnsafeMutableRawPointer, count: Int, fileOffset: Int) throws {
        var position = 0
        while position < count {
            try Task.checkCancellation()
            let amount = pread(descriptor, destination.advanced(by: position), min(1_024 * 1_024, count - position), off_t(fileOffset + position))
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw CaptureError.invalidRegion }
            position += amount
        }
    }
}
