import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import PicShotCore

/// Passive, cropped ScreenCaptureKit input for the live scrolling session.
/// No Accessibility calls, input emission, full-display screenshot or raster digest.
/// The owner consumes frames serially and must release each Frame after processing it.
@MainActor
final class LiveScrollScreenSource {
    typealias Target = ManualScrollScreenDriver.Target

    struct Frame {
        /// Owned bytes: this image never borrows a callback/IOSurface's storage.
        let image: CGImage
        let sequence: UInt64
        let generation: UInt64
        let timestamp: TimeInterval
        let region: CGRect
    }

    enum State: Equatable { case idle, starting, running, pausing, paused, stopping, stopped, failed }
    static let operationTimeout: TimeInterval = 3

    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let screenSize: CGSize
    private(set) var region: CGRect
    private(set) var target: Target?
    private(set) var pixelSize: CGSize?
    private(set) var state: State = .idle
    private(set) var generation: UInt64 = 0
    private(set) var shareableContentRequests = 0
    private(set) var startedStreams = 0
    private(set) var confirmedStops = 0

    var counters: LiveScrollFrameCounters { mailbox.counters }

    private let displayIdentity: DisplayIdentity
    private let mailbox = LiveScrollFrameMailbox<LiveScrollPixelFrame>()
    private let outputQueue = DispatchQueue(label: "PicShot.LiveScroll.Screen", qos: .userInitiated)
    private var filter: SCContentFilter?
    private var displayPixels: CGSize?
    private var stream: SCStream?
    private var output: LiveScrollStreamOutput?
    private var starting: Task<Void, Error>?
    private var teardown: Task<Void, Error>?
    private var readInFlight = false
    private var readDrain: CheckedContinuation<Void, Never>?
    private var terminalRequested = false

    init(displayID: CGDirectDisplayID, region: CGRect, screenSize: CGSize,
         expectedPixelSize: CGSize? = nil, lockedTarget: Target? = nil) throws {
        let bounds = CGDisplayBounds(displayID)
        guard region.origin.x.isFinite, region.origin.y.isFinite,
              region.width.isFinite, region.height.isFinite,
              region.width >= 8, region.height >= 16,
              CGRect(origin: .zero, size: screenSize).contains(region), bounds.size == screenSize,
              let identity = DisplayIdentity.read(displayID) else { throw CaptureError.invalidRegion }
        self.displayID = displayID; displayBounds = bounds; self.screenSize = screenSize
        self.region = region; pixelSize = expectedPixelSize; target = lockedTarget
        displayIdentity = identity
    }

    deinit {
        mailbox.close(generation: generation)
        // The owning session awaits stop(). This is a best-effort safety net only.
        stream?.stopCapture(completionHandler: nil)
    }

    func checkPermission() throws {
        // Never requests or accepts an OS permission prompt.
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.screenPermission }
    }

    func validateTarget() throws {
        try Task.checkCancellation()
        try checkPermission()
        guard !terminalRequested else { throw LiveScrollSourceError.stopped }
        try validateDisplay()
        target = try ManualScrollScreenDriver.checkedTarget(windowAt(region: region), locked: target,
            region: region, displayBounds: displayBounds, allowMovedWindow: false)
    }

    /// The only content-discovery call is the first start. A paused move reuses the
    /// verified display/application filter and creates a fresh cropped stream.
    func start() async throws {
        guard !terminalRequested else { throw LiveScrollSourceError.stopped }
        guard (state == .idle || state == .paused), teardown == nil else {
            if state == .failed { throw LiveScrollSourceError.unconfirmedTeardown }
            throw LiveScrollSourceError.transitionInProgress
        }
        try validateTarget()
        state = .starting; generation &+= 1
        let token = generation
        do {
            if filter == nil {
                shareableContentRequests += 1
                let content: SCShareableContent = try await LiveScrollDeadline.run(operation: "准备", timeout: Self.operationTimeout) { finish in
                    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                        if let error { finish(.failure(error)) }
                        else if let content { finish(.success(content)) }
                        else { finish(.failure(CaptureError.noDisplay)) }
                    }
                }
                try checkActiveStart(token)
                try validateTarget()
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                guard !own.isEmpty else { throw CaptureError.failed("无法排除PicShot控制条，捕获已暂停。") }
                let preparedFilter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let geometry = try Self.captureGeometry(region: region, screenSize: screenSize,
                    contentRect: preparedFilter.contentRect, pointPixelScale: CGFloat(preparedFilter.pointPixelScale),
                    expectedPixelSize: pixelSize)
                region = geometry.region; pixelSize = geometry.pixelSize; displayPixels = geometry.displayPixels
                try validateTarget()
                filter = preparedFilter
            }
            try checkActiveStart(token)
            guard let filter, let pixelSize else { throw CaptureError.invalidRegion }
            let configuration = Self.configuration(region: region, pixelSize: pixelSize)
            mailbox.activate(generation: token, width: configuration.width, height: configuration.height)
            let mailbox = self.mailbox
            let sink = LiveScrollStreamOutput(mailbox: mailbox, generation: token,
                                             width: configuration.width, height: configuration.height)
            let created = SCStream(filter: filter, configuration: configuration, delegate: sink)
            try created.addStreamOutput(sink, type: .screen, sampleHandlerQueue: outputQueue)
            stream = created; output = sink
            let operation = Task {
                try await LiveScrollDeadline<Void>.run(operation: "启动", timeout: Self.operationTimeout) { finish in
                    created.startCapture { error in
                        // A late start completion after timeout/pause/stop must not resurrect capture.
                        if !mailbox.isAccepting(generation: token) { created.stopCapture(completionHandler: nil) }
                        finish(error.map { .failure($0) } ?? .success(()))
                    }
                }
            }
            starting = operation
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { mailbox.close(generation: token) }
            try checkActiveStart(token)
            try validateTarget()
            starting = nil; startedStreams += 1; state = .running
        } catch {
            if token == generation {
                // Close the slot before awaiting any ScreenCaptureKit callback.
                mailbox.close(generation: token, error: error)
                do { try await halt(terminal: error is CancellationError) }
                catch { throw error }
            }
            throw error
        }
    }

    func resume() async throws { try await start() }

    /// Nil is a normal idle result: ScreenCaptureKit need not produce complete
    /// frames for an unchanged desktop. Callers should not treat nil as a failure.
    func nextFrame(timeout: TimeInterval = 0.75) async throws -> Frame? {
        guard state == .running else {
            throw terminalRequested ? LiveScrollSourceError.stopped : LiveScrollSourceError.paused
        }
        guard !readInFlight else { throw LiveScrollSourceError.concurrentRead }
        let token = generation
        readInFlight = true
        do {
            try validateTarget()
            guard let pixels = try await mailbox.next(generation: token, timeout: timeout) else {
                try checkActiveRead(token); try validateTarget(); finishRead(); return nil
            }
            try checkActiveRead(token)
            try validateTarget()
            // Exactly one consumed buffer is copied. The mailbox can replace its
            // one pending buffer meanwhile; no callback enqueues a conversion task.
            let image = try autoreleasepool { try Self.ownedImage(pixels.buffer) }
            try checkActiveRead(token)
            try validateTarget()
            let frame = Frame(image: image, sequence: pixels.sequence, generation: token,
                              timestamp: pixels.timestamp, region: region)
            finishRead()
            return frame
        } catch {
            finishRead()
            if token == generation {
                mailbox.close(generation: token, error: error)
                try await halt(terminal: error is CancellationError)
            }
            throw error
        }
    }

    /// Invalidates delivery immediately, stops the stream, detaches its output and
    /// drains callbacks/read ownership. Each SDK operation has a 3s deadline; if
    /// start was already pending, its remainder plus stop is at most 6s. A timeout
    /// is reported and blocks resume rather than claiming teardown was confirmed.
    func pauseAndDrain() async throws { try await halt(terminal: false) }

    func stop() async throws { try await halt(terminal: true) }

    /// Call only after pauseAndDrain succeeds. Never changes dimensions or display.
    func moveRegion(to proposed: CGRect) throws {
        try Task.checkCancellation()
        guard state == .paused, !readInFlight, teardown == nil, !terminalRequested else { throw CaptureError.busy }
        try checkPermission(); try validateDisplay()
        let moved = try ManualScrollScreenDriver.movedRegion(proposed, original: region, screenSize: screenSize,
                                                             displayPixels: displayPixels, expectedPixels: pixelSize)
        let movedTarget = try ManualScrollScreenDriver.checkedTarget(windowAt(region: moved), locked: target,
            region: moved, displayBounds: displayBounds, allowMovedWindow: true)
        region = moved; target = movedTarget
    }

    private func halt(terminal: Bool) async throws {
        terminalRequested = terminalRequested || terminal
        if let teardown {
            try await teardown.value
            return
        }
        if state == .stopped { return }
        if state == .failed { throw LiveScrollSourceError.unconfirmedTeardown }
        let token = generation
        generation &+= 1
        mailbox.close(generation: token)
        state = terminalRequested ? .stopping : .pausing
        let oldStream = stream, oldOutput = output, oldStart = starting
        stream = nil; output = nil; starting = nil
        let queue = outputQueue
        let operation = Task {
            do {
                // Serialize stop behind a possibly pending start; both waits are bounded.
                if let oldStart { _ = await oldStart.result }
                if let oldStream {
                    try await LiveScrollDeadline<Void>.run(operation: "结束", timeout: Self.operationTimeout) { finish in
                        oldStream.stopCapture { error in
                            if let error { finish(.failure(error)); return }
                            do {
                                if let oldOutput { try oldStream.removeStreamOutput(oldOutput, type: .screen) }
                                // The stop, output removal and callback barrier share one deadline.
                                queue.async { finish(.success(())) }
                            } catch { finish(.failure(error)) }
                        }
                    }
                } else {
                    try await LiveScrollDeadline<Void>.run(operation: "清理", timeout: Self.operationTimeout) { finish in
                        queue.async { finish(.success(())) }
                    }
                }
                // Only this task owns the one drain waiter; repeated pause/stop callers
                // join the same task, including its reader drain and state publication.
                await self.awaitReadDrain()
                if oldStream != nil { self.confirmedStops += 1 }
                self.teardown = nil
                self.state = self.terminalRequested ? .stopped : .paused
            } catch {
                // Retain only the stream handle for deinit's final stop attempt.
                // Its mailbox is already closed; an uncertain teardown never
                // permits another stream or another delivered image.
                self.stream = oldStream; self.output = oldOutput
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

    private func awaitReadDrain() async {
        if readInFlight { await withCheckedContinuation { readDrain = $0 } }
    }

    private func checkActiveStart(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard generation == token, state == .starting, !terminalRequested else { throw CancellationError() }
    }

    private func checkActiveRead(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard generation == token, state == .running, !terminalRequested else { throw CancellationError() }
        try mailbox.checkAccepting(generation: token)
    }

    private func validateDisplay() throws {
        guard CGDisplayBounds(displayID) == displayBounds,
              DisplayIdentity.read(displayID) == displayIdentity,
              NSScreen.screens.contains(where: { $0.displayID == displayID && $0.frame.size == screenSize }) else {
            throw ManualScrollRecoveryError(message: "显示器已断开、布局或像素缩放改变。请停止后完成截图。")
        }
    }

    private func windowAt(region: CGRect) -> Target? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let global = region.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), bounds.intersects(global),
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01 else { continue }
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return Target(pid: pid, windowID: id, bounds: bounds)
        }
        return nil
    }

    struct CaptureGeometry {
        let region: CGRect
        let pixelSize: CGSize
        let displayPixels: CGSize
    }

    static func captureGeometry(region: CGRect, screenSize: CGSize, contentRect: CGRect,
                                pointPixelScale: CGFloat, expectedPixelSize: CGSize?) throws -> CaptureGeometry {
        guard pointPixelScale.isFinite, pointPixelScale > 0, pointPixelScale <= 8,
              contentRect.size == screenSize else { throw CaptureError.invalidRegion }
        let width = contentRect.width * pointPixelScale, height = contentRect.height * pointPixelScale
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= CGFloat(ScrollFrame.maximumDimension), height <= CGFloat(ScrollFrame.maximumDimension) else {
            throw ScrollStitchError.invalidPixels
        }
        let pixels = try AutomaticScrollGeometry.pixelRect(region: region, logicalSize: screenSize,
                                                          pixelWidth: Int(width.rounded()), pixelHeight: Int(height.rounded()))
        let outputSize = pixels.size
        guard pixels.width <= CGFloat(ScrollFrame.maximumDimension), pixels.height <= CGFloat(ScrollFrame.maximumDimension),
              pixels.width * pixels.height <= CGFloat(ScrollFrame.maximumPixels) else { throw ScrollStitchError.invalidPixels }
        if let expectedPixelSize, outputSize != expectedPixelSize { throw ScrollStitchError.differentDimensions }
        let sx = width.rounded() / screenSize.width, sy = height.rounded() / screenSize.height
        return CaptureGeometry(region: CGRect(x: pixels.minX / sx, y: pixels.minY / sy,
            width: pixels.width / sx, height: pixels.height / sy), pixelSize: outputSize,
            displayPixels: CGSize(width: width.rounded(), height: height.rounded()))
    }

    static func configuration(region: CGRect, pixelSize: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Display-relative logical points with a top-left origin; no global display offset.
        configuration.sourceRect = region
        configuration.width = Int(pixelSize.width); configuration.height = Int(pixelSize.height)
        configuration.destinationRect = CGRect(origin: .zero, size: pixelSize)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.showsCursor = false; configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    nonisolated static func ownedImage(_ buffer: CVPixelBuffer) throws -> CGImage {
        try Task.checkCancellation()
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(buffer), width > 0, height > 0,
              width <= ScrollFrame.maximumDimension, height <= ScrollFrame.maximumDimension,
              width <= ScrollFrame.maximumPixels / height, rowBytes >= width * 4,
              rowBytes <= Int.max / height else { throw ScrollStitchError.invalidPixels }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw ScrollStitchError.invalidPixels }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw ScrollStitchError.invalidPixels }
        // CFData owns a copy, so SCK can recycle the pixel buffer immediately after return.
        guard let data = CFDataCreate(kCFAllocatorDefault, address.assumingMemoryBound(to: UInt8.self), rowBytes * height),
              let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScrollStitchError.invalidPixels }
        try Task.checkCancellation()
        return image
    }

    private struct DisplayIdentity: Equatable {
        let uuid: String
        let bounds: CGRect
        let modeWidth: Int
        let modeHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let rotation: Double

        static func read(_ id: CGDirectDisplayID) -> Self? {
            guard CGDisplayIsActive(id) != 0, let mode = CGDisplayCopyDisplayMode(id),
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return Self(uuid: CFUUIDCreateString(kCFAllocatorDefault, uuid) as String, bounds: CGDisplayBounds(id),
                        modeWidth: mode.width, modeHeight: mode.height, pixelWidth: mode.pixelWidth,
                        pixelHeight: mode.pixelHeight, rotation: CGDisplayRotation(id))
        }
    }
}

struct LiveScrollPixelFrame {
    let buffer: CVPixelBuffer
    let sequence: UInt64
    let timestamp: TimeInterval
}

private final class LiveScrollStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let mailbox: LiveScrollFrameMailbox<LiveScrollPixelFrame>
    private let generation: UInt64
    private let width: Int
    private let height: Int
    // Only accessed by the one serial sampleHandlerQueue.
    private var sequence: UInt64 = 0

    init(mailbox: LiveScrollFrameMailbox<LiveScrollPixelFrame>, generation: UInt64, width: Int, height: Int) {
        self.mailbox = mailbox; self.generation = generation; self.width = width; self.height = height
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            mailbox.recordIncomplete(generation: generation); return
        }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            mailbox.close(generation: generation, error: ScrollStitchError.differentDimensions); return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isNumeric, time.seconds.isFinite else { mailbox.recordIncomplete(generation: generation); return }
        sequence &+= 1
        mailbox.offer(LiveScrollPixelFrame(buffer: buffer, sequence: sequence, timestamp: time.seconds), generation: generation)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        mailbox.close(generation: generation, error: error)
    }
}

/// A callback deadline does not wait forever for a cancelled child task. Late SDK
/// completions are ignored; start has its own late-completion stop safeguard.
private final class LiveScrollDeadline<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: DispatchSourceTimer?

    static func run(operation: String, timeout: TimeInterval,
                    begin: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let gate = LiveScrollDeadline()
            gate.continuation = continuation
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { gate.finish(.failure(LiveScrollSourceError.operationTimedOut(operation))) }
            gate.timer = timer; timer.resume()
            begin { gate.finish($0) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let waiting = continuation; continuation = nil
        timer?.cancel(); timer = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}
