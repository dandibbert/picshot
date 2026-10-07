import AppKit
import Foundation
import PicShotCodecCore

struct ImageDecodeMainQueueStatistics: Encodable {
    var samples = 0, coalescedTicks = 0
    var maximumDelaySeconds = 0.0, totalDelaySeconds = 0.0
    var histogramTenMillisecondBins = [Int](repeating: 0, count: 64)
    var outstandingCallbacks = 0
    var timing: ImageDecodeQueueTiming?
}
final class ImageDecodeMainQueueProbe: @unchecked Sendable {
    private let lock = NSLock(), queue = DispatchQueue(label: "PicShot.DecodeDiagnostic.MainQueue")
    private let timingEnabled: Bool
    private var timer: DispatchSourceTimer?, pending = false, value = ImageDecodeMainQueueStatistics()
    init(timingEnabled: Bool = false) {
        self.timingEnabled = timingEnabled
        if timingEnabled { value.timing = .init(); value.timing?.transition(.setup, at: ProcessInfo.processInfo.systemUptime) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
    }
    private func tick() {
        lock.lock()
        guard !pending else { value.coalescedTicks += 1; lock.unlock(); return }
        pending = true
        let queuedPhase = value.timing?.currentPhase
        let timedQueued = queuedPhase == nil ? nil : ProcessInfo.processInfo.systemUptime
        lock.unlock()
        let queued = timedQueued ?? ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let acknowledged = ProcessInfo.processInfo.systemUptime
            let delay = max(0, acknowledged - queued)
            self.lock.lock(); self.pending = false; self.value.samples += 1
            self.value.maximumDelaySeconds = max(self.value.maximumDelaySeconds, delay); self.value.totalDelaySeconds += delay
            self.value.histogramTenMillisecondBins[min(63, Int(delay / 0.01))] += 1
            if let queuedPhase { self.value.timing?.acknowledge(queued: queued, acknowledged: acknowledged, phase: queuedPhase) }
            self.lock.unlock()
        }
    }
    func phase(_ phase: ImageDecodeUIPhase) {
        guard timingEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        if value.timing != nil { value.timing?.transition(phase, at: ProcessInfo.processInfo.systemUptime) }
    }
    func stop() { guard let timer else { return }; timer.cancel(); self.timer = nil; queue.sync { } }
    func snapshot() -> ImageDecodeMainQueueStatistics { lock.lock(); defer { lock.unlock() }; var result = value; result.outstandingCallbacks = pending ? 1 : 0; return result }
    deinit { timer?.cancel() }
}

struct ImageDecodeUIDrawRecord: Encodable {
    let uptimeSeconds: Double, imageIdentity: String, backingScale: Double, windowVisible: Bool
    let bounds: [Double], displayedRect: [Double], backingRect: [Double]
    init(_ value: ImageExportPreviewDrawObservation) {
        func array(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
        uptimeSeconds = value.uptimeSeconds; imageIdentity = value.imageIdentity; backingScale = Double(value.backingScale)
        windowVisible = value.windowVisible; bounds = array(value.bounds); displayedRect = array(value.displayedImageRect); backingRect = array(value.backingRect)
    }
}
struct ImageDecodeUIConstruction: Encodable {
    let elapsedSeconds: Double
    let before: ImageDecodeMemoryReading, after: ImageDecodeMemoryReading
}
struct ImageDecodeUIWorkerRecord: Encodable {
    let index: Int, scenario: String, requestUptimeSeconds: Double, startedUptimeSeconds: Double
    var finishedUptimeSeconds: Double?, outcome = "running", imageIdentity: String?, pixelsSHA256: String?
    var stages: [String: Double] = [:]
    var process: ImageDecodeProcessMetrics?
}
final class ImageDecodeUIState: @unchecked Sendable {
    enum Scenario: String { case normal, burst, cancelActive, closeDecoded, lateResult }
    private let lock = NSLock()
    private var scenario = Scenario.normal, requestedAt = 0.0
    private var records: [ImageDecodeUIWorkerRecord] = [], lastDraw: ImageDecodeUIDrawRecord?, drawCount = 0
    private var constructions: [ImageDecodeUIConstruction] = []
    private var releaseLate = false
    func plan(_ value: Scenario, requestedAt: Double) { lock.lock(); scenario = value; self.requestedAt = requestedAt; releaseLate = false; lock.unlock() }
    func begin() throws -> (Int, Scenario) {
        lock.lock(); defer { lock.unlock() }
        guard records.count < 16 else { throw ImageDecodeDiagnosticError.invalidProtocol }
        let index = records.count
        records.append(.init(index: index + 1, scenario: scenario.rawValue, requestUptimeSeconds: requestedAt, startedUptimeSeconds: ProcessInfo.processInfo.systemUptime))
        return (index, scenario)
    }
    func stage(_ index: Int, _ name: String, _ time: Double = ProcessInfo.processInfo.systemUptime) { lock.lock(); records[index].stages[name] = time; lock.unlock() }
    func finish(_ index: Int, outcome: String, process: ImageDecodeProcessMetrics?, imageIdentity: String? = nil, pixelsSHA256: String? = nil) {
        lock.lock(); records[index].finishedUptimeSeconds = ProcessInfo.processInfo.systemUptime; records[index].outcome = outcome
        records[index].process = process; records[index].imageIdentity = imageIdentity; records[index].pixelsSHA256 = pixelsSHA256; lock.unlock()
    }
    func recordDraw(_ value: ImageDecodeUIDrawRecord) { lock.lock(); lastDraw = value; drawCount += 1; lock.unlock() }
    func recordConstruction(_ value: ImageDecodeUIConstruction) throws {
        lock.lock(); defer { lock.unlock() }
        guard constructions.count < 4 else { throw ImageDecodeDiagnosticError.invalidProtocol }; constructions.append(value)
    }
    func snapshot() -> (records: [ImageDecodeUIWorkerRecord], lastDraw: ImageDecodeUIDrawRecord?, drawCount: Int, constructions: [ImageDecodeUIConstruction]) {
        lock.lock(); defer { lock.unlock() }; return (records, lastDraw, drawCount, constructions)
    }
    func releaseLateResult() { lock.lock(); releaseLate = true; lock.unlock() }
    func lateResultReleased() -> Bool { lock.lock(); defer { lock.unlock() }; return releaseLate }
}

final class ImageDecodeLargeUIRasterVerifier: @unchecked Sendable {
    private let lock = NSLock(), destination: ImageDrawDestination
    let tracker: ImageDrawAllocationTracker
    init(profile: ImageDecodeDiagnosticProfile) throws {
        tracker = .init(maximumAllocations: 1, allocationBytes: profile.rasterBytes)
        destination = try .init(width: profile.previewWidth, height: profile.previewHeight, tracker: tracker)
    }
    func validate(_ image: CGImage, reference: Data) throws -> ImageDrawPixels { lock.lock(); defer { lock.unlock() }; return try destination.drawAndValidate(image, reference: reference, tolerance: 0) }
    func close() { lock.lock(); destination.close(); lock.unlock() }
}

/// The existing controller's encoder-injection seam runs this adapter on its
/// serial worker queue. It consumes prepared PNG; it is not a complete encoder.
final class ImageDecodeLargeUIAdapter: @unchecked Sendable {
    let input: ImageDecodeLargeInput, isolated: Bool, deadline: Double
    let timingEnabled: Bool
    let exitStrategy: ImageDecodeExitStrategy
    let state: ImageDecodeUIState, providers: ImageDrawAllocationTracker, verifier: ImageDecodeLargeUIRasterVerifier
    init(input: ImageDecodeLargeInput, isolated: Bool, deadline: Double, state: ImageDecodeUIState, timingEnabled: Bool = false, exitStrategy: ImageDecodeExitStrategy = .waitUntilExit) throws {
        self.input = input; self.isolated = isolated; self.deadline = deadline; self.state = state; self.timingEnabled = timingEnabled; self.exitStrategy = exitStrategy
        providers = .init(maximumAllocations: 16, allocationBytes: input.profile.rasterBytes)
        verifier = try .init(profile: input.profile)
    }
    func encode(_ snapshot: ImageExportSnapshot, options: ImageExportOptions, token: ImageExportCancellation) throws -> ImageExportArtifact {
        let (index, scenario) = try state.begin()
        var process: ImageDecodeDiagnosticProcess?
        func check() throws {
            guard !token.isCancelled else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ImageDecodeDiagnosticError.deadline }
            let reading = ImageDecodeMemoryReading.current()
            guard reading.usable, (reading.residentBytes ?? UInt64.max) <= 536_870_912, (reading.footprintBytes ?? UInt64.max) <= 536_870_912 else { throw ImageDecodeDiagnosticError.memoryLimit }
        }
        do {
            try check()
            guard options.format == .png, snapshot.image.width == input.profile.sourceWidth, snapshot.image.height == input.profile.sourceHeight else { throw ImageDecodeDiagnosticError.invalidInput }
            let image: CGImage
            if isolated {
                let child = ImageDecodeDiagnosticProcess(mode: scenario == .closeDecoded ? .holdForCancellation : .decode, profile: input.profile,
                    cancellationCheck: { token.isCancelled }, observer: { [state] name, time in state.stage(index, name, time) }, timingEnabled: timingEnabled, exitStrategy: exitStrategy)
                process = child
                let raw = try child.run(png: input.png, armDeadline: deadline), metrics = child.snapshot()
                guard metrics.cleanupConfirmed, metrics.admissionReleased, !metrics.childLaunched || metrics.exitConfirmed else { throw ImageDecodeDiagnosticError.exitUnconfirmed }
                if scenario == .closeDecoded {
                    guard metrics.sawPostDecodeReady, metrics.phases.first(where: { $0.child.kind == .ready })?.child.rawSHA256 == input.referenceSHA else { throw ImageDecodeDiagnosticError.outputMismatch }
                    throw CancellationError()
                }
                guard let raw, raw == input.reference else { throw ImageDecodeDiagnosticError.outputMismatch }
                image = try ImageDecodeLargeRaster.ownedImage(raw, profile: input.profile, tracker: providers)
            } else {
                state.stage(index, "directPreviewStarted")
                image = try ImageExportService.preview(data: input.png, format: .png)
            }
            try check()
            let pixels = try verifier.validate(image, reference: input.reference)
            guard pixels.maximumDifference == 0, pixels.sha256 == input.referenceSHA else { throw ImageDecodeDiagnosticError.outputMismatch }
            state.stage(index, "pixelsValidated")
            // Real completed result is held only for race placement, never in
            // the successful timing series. It will exercise controller guards.
            if scenario == .lateResult || (!isolated && (scenario == .cancelActive || scenario == .closeDecoded)) {
                state.stage(index, "resultHeld")
                let holdDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 1)
                while !state.lateResultReleased() && ProcessInfo.processInfo.systemUptime < holdDeadline { Thread.sleep(forTimeInterval: 0.005) }
                guard state.lateResultReleased() else { throw ImageDecodeDiagnosticError.deadline }
                // Deliberately return the already valid artifact after cancellation;
                // the unchanged controller must suppress publication of it.
            } else { try check() }
            let artifact = ImageExportArtifact(data: input.png, options: options, width: input.profile.sourceWidth, height: input.profile.sourceHeight,
                pageCount: 1, firstPreview: image, sourceURL: nil)
            state.finish(index, outcome: token.isCancelled ? "completed-after-cancel" : "completed", process: process?.snapshot(),
                imageIdentity: String(describing: ObjectIdentifier(image)), pixelsSHA256: pixels.sha256)
            return artifact
        } catch {
            state.finish(index, outcome: token.isCancelled || error is CancellationError ? "cancelled" : "failed", process: process?.snapshot())
            throw error
        }
    }
}
