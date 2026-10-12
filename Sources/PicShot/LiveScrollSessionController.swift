import AppKit
import ApplicationServices
import PicShotCore

/// Product owner for select → scroll → live preview → finish. It never activates
/// an inspector during capture or a recoverable alignment problem.
@MainActor
final class LiveScrollSessionController {
    var onClose: (() -> Void)?
    private let onComplete: (CGImage) throws -> Void
    private let onImport: () -> Void
    private let onCopy: (CGImage) -> Void
    private let capture = CaptureService()
    private let resourceStorageParent: URL
    private var source: (any LiveScrollFrameSource)?
    private var assembler: LiveScrollAssembler?
    private var controls: LiveScrollCaptureController?
    private var sampling: Task<Void, Never>?
    private var transition: Task<Void, Never>?
    private var mover: ManualScrollRegionMover?
    private var generation: UInt64 = 1
    private var axis: ScrollAxis = .vertical
    private var region: CGRect?
    private var screen: NSScreen?
    private var snapshot = LiveScrollCaptureSnapshot()
    private var lastState = LiveScrollAssembler.State()
    private var paused = false
    private var finishing = false
    private var deliveryCompleted = false
    private var deliveryWarning: String?
    private var retired = false
    private var automatic = false
    private let monotonicNow: () -> TimeInterval
    private var activeCaptureSeconds: TimeInterval = 0
    private var activeIntervalStartedAt: TimeInterval?
    private var captureLimitReached = false
    private enum RegionDragEnd { case cancelled, moved(CGRect) }
    private struct RegionDrag {
        let id: UUID
        let generation: UInt64
        let wasPaused: Bool
        let originalRegion: CGRect
        var drained = false
        var end: RegionDragEnd?
    }
    private var regionDrag: RegionDrag?
    private var samples = 0
    private var lastAutoEvent: TimeInterval = -.infinity
    private let automaticScrollPermission: () -> Bool
    private let automaticScrollInput: ((CGEvent) throws -> Void)?
    private let automaticProgressTimeout: TimeInterval = 3
    private struct AutomaticObservation {
        let frame: LiveScrollFrameWatermark
        let viewportOffset: Int
    }
    private struct PendingAutomaticStep {
        let fence: LiveScrollFrameWatermark
        let viewportOffset: Int
        let sentAt: TimeInterval
    }
    private var lastAutomaticObservation: AutomaticObservation?
    private var lastConsumedFrame: LiveScrollFrameWatermark?
    private var pendingAutomaticStep: PendingAutomaticStep?
    private var automaticStopMessage: String?
    private var previousApplication: NSRunningApplication?
    private let maximumDuration: TimeInterval = 180
    private let maximumSamples = 2400

    init(onComplete: @escaping (CGImage) throws -> Void, onImport: @escaping () -> Void,
         onCopy: ((CGImage) -> Void)? = nil,
         resourceStorageParent: URL = FileManager.default.temporaryDirectory,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticScrollPermission: @escaping () -> Bool = { AXIsProcessTrusted() },
         automaticScrollInput: ((CGEvent) throws -> Void)? = nil) {
        self.resourceStorageParent = resourceStorageParent
        self.monotonicNow = monotonicNow
        self.automaticScrollPermission = automaticScrollPermission
        self.automaticScrollInput = automaticScrollInput
        self.onComplete = onComplete; self.onImport = onImport
        self.onCopy = onCopy ?? { copyImage($0) }
    }

    func start(presentation: FrozenCapturePresentation? = nil) {
        guard transition == nil, source == nil, !retired else { return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        let token = generation
        transition = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) } }
            do {
                let chosenScreen: NSScreen
                let selected: CGRect
                if let presentation {
                    guard let current = NSScreen.screens.first(where: { $0.displayID == presentation.displayID }),
                          current.frame == presentation.displayFrame else { throw CaptureError.noDisplay }
                    chosenScreen = current
                    selected = CGRect(x: presentation.selectionFrame.minX,
                        y: current.frame.height - presentation.selectionFrame.maxY,
                        width: presentation.selectionFrame.width, height: presentation.selectionFrame.height)
                } else {
                    guard let current = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
                          let displayID = current.displayID else { throw CaptureError.noDisplay }
                    chosenScreen = current
                    try CaptureService.requireScreenPermission()
                    selected = try await self.capture.selectRegion(displayID: displayID)
                }
                try Task.checkCancellation()
                guard self.generation == token, let displayID = chosenScreen.displayID else { throw CancellationError() }
                let source = try LiveScrollScreenSource(displayID: displayID, region: selected, screenSize: chosenScreen.frame.size)
                try await self.beginSource(source, on: chosenScreen, token: token)
            } catch CaptureError.cancelled { await self.retire() }
            catch is CancellationError { }
            catch {
                if self.controls != nil { self.paused = true; self.setStatus(error.localizedDescription, kind: .error) }
                else { showError(error); await self.retire() }
            }
        }
    }

    /// Both real ScreenCaptureKit and the native owned-window demonstration use
    /// this exact lifecycle, sampling loop, assembler and completion callbacks.
    private func beginSource(_ source: any LiveScrollFrameSource, on screen: NSScreen, token: UInt64) async throws {
        self.screen = screen; self.region = source.region
        self.source = source
        self.assembler = LiveScrollAssembler(axis: axis, generation: token, storageParent: resourceStorageParent)
        installControls()
        setStatus("正在读取选区…", kind: .capturing)
        try await source.start()
        try Task.checkCancellation()
        guard generation == token, !retired else { throw CancellationError() }
        region = source.region
        placeControls()
        resumeCaptureClock()
        if let target = source.target {
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        } else { previousApplication?.activate(options: []) }
        startSampling()
    }

    // Verification substitutes acquisition only. It does not bypass production
    // sampling, pause/drain, incremental assembly, UI actions or Finish output.
    func startForVerification(targetFrame: CGRect, screen: NSScreen,
                              nextImage: @escaping @MainActor () async throws -> CGImage?) async throws {
        guard source == nil, transition == nil, !retired else { throw CaptureError.busy }
        let selected = CGRect(x: targetFrame.minX - screen.frame.minX,
            y: screen.frame.maxY - targetFrame.maxY, width: targetFrame.width, height: targetFrame.height)
        let input = try LiveScrollVerificationFrameSource(region: selected,
            displayBounds: CGDisplayBounds(screen.displayID ?? 0), image: nextImage)
        try await beginSource(input, on: screen, token: generation)
    }

    /// A permitted native stream run may inject an actual screen source after
    /// preparing a separately owned target window; no permission is requested.
    func startForVerification(source: any LiveScrollFrameSource, screen: NSScreen) async throws {
        guard self.source == nil, transition == nil, !retired else { throw CaptureError.busy }
        try await beginSource(source, on: screen, token: generation)
    }

    func documentSnapshotForResourceVerification() async -> LiveScrollDocument.Snapshot? {
        await assembler?.documentSnapshotForResourceVerification()
    }
    var snapshotForVerification: LiveScrollCaptureSnapshot { snapshot }
    var stateForVerification: LiveScrollAssembler.State { lastState }
    var controlsForVerification: LiveScrollCaptureController? { controls }
    var activeMoveViewForVerification: ManualScrollRegionMoveView? { mover?.viewForVerification }
    var sampledFramesForVerification: Int { samples }
    var activeCaptureDurationForVerification: TimeInterval { activeCaptureDuration }
    var captureLimitReachedForVerification: Bool { captureLimitReached }
    var isClosedForVerification: Bool { retired && source == nil && assembler == nil && controls == nil && sampling == nil }

    func closeForVerification() async {
        transition?.cancel(); sampling?.cancel(); mover?.cancel()
        await retire()
        // A Finish callback may already have started retirement. Keep the
        // observation owned and bounded without changing product deadlines.
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !isClosedForVerification, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func show() { placeControls() }

    private func installControls() {
        var actions = LiveScrollCaptureActions()
        actions.finishEdit = { [weak self] in self?.finish(copyOnly: false) }
        actions.copy = { [weak self] in self?.finish(copyOnly: true) }
        actions.pauseResume = { [weak self] in self?.togglePause() }
        actions.autoScroll = { [weak self] in self?.toggleAutomatic() }
        actions.changeAxis = { [weak self] axis in self?.changeAxis(axis) }
        actions.moveRegion = { [weak self] in self?.moveRegion() }
        actions.beginRegionDrag = { [weak self] id in self?.beginRegionDrag(id: id) ?? false }
        actions.endRegionDrag = { [weak self] id, frame in self?.endRegionDrag(id: id, frame: frame) }
        actions.importImages = { [weak self] in self?.openImporter() }
        actions.help = { [weak self] in guard let self else { return }; self.setStatus("滚动页面自动接长；接不上时稍往回滚。暂停保留内容，完成进入编辑。", kind: self.snapshot.statusKind) }
        actions.cancel = { [weak self] in self?.cancel() }
        actions.onClose = { [weak self] in self?.cancel() }
        controls = LiveScrollCaptureController(actions: actions)
        snapshot.canChangeAxis = true
        snapshot.showsAutoScroll = true
        snapshot.canAutoScroll = false
        placeControls()
    }

    private func placeControls() {
        guard let screen, let region else { return }
        let frame = CGRect(x: screen.frame.minX + region.minX,
                           y: screen.frame.maxY - region.maxY,
                           width: region.width, height: region.height)
        controls?.show(snapshot: snapshot, targetFrame: frame, visibleFrame: screen.visibleFrame,
                       movementBounds: screen.frame)
    }

    private var activeCaptureDuration: TimeInterval {
        activeCaptureSeconds + (activeIntervalStartedAt.map { max(0, monotonicNow() - $0) } ?? 0)
    }

    private func pauseCaptureClock() {
        guard let began = activeIntervalStartedAt else { return }
        activeCaptureSeconds += max(0, monotonicNow() - began)
        activeIntervalStartedAt = nil
    }

    private func resumeCaptureClock() {
        guard activeIntervalStartedAt == nil, !captureLimitReached, !retired else { return }
        activeIntervalStartedAt = monotonicNow()
    }

    private func updateCaptureLimit() -> Bool {
        if samples >= maximumSamples || activeCaptureDuration >= maximumDuration {
            pauseCaptureClock(); captureLimitReached = true
            paused = true; clearAutomaticState()
        }
        return captureLimitReached
    }

    private func startSampling() {
        guard sampling == nil, !retired, !paused, !finishing, !captureLimitReached,
              regionDrag == nil, let source, let assembler else { return }
        let token = generation
        sampling = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.sampling = nil } }
            while !Task.isCancelled, !self.retired, !self.paused, self.generation == token {
                if self.updateCaptureLimit() {
                    self.snapshot.previewPositionVerified = false
                    try? await source.pauseAndDrain()
                    self.setStatus("已达到本次捕获上限，可完成保存已有长图", kind: .paused)
                    break
                }
                do {
                    guard let frame = try await source.nextFrame(timeout: 0.75) else {
                        if self.automatic { self.performAutomaticStep(source: source) }
                        continue
                    }
                    self.samples += 1
                    guard self.acceptFrameIdentity(frame, source: source) else {
                        if self.automatic, self.pendingAutomaticStep != nil {
                            self.performAutomaticStep(source: source)
                        }
                        continue
                    }
                    let update = try await assembler.observe(frame.image)
                    try Task.checkCancellation()
                    guard self.generation == token, !self.retired else { break }
                    let previousOffset = self.lastState.viewportOffset
                    self.lastState = update.state
                    self.snapshot.pixelWidth = update.state.width; self.snapshot.pixelHeight = update.state.height
                    self.snapshot.acceptedFrames = update.state.acceptedObservations
                    self.snapshot.canFinish = update.state.width > 0
                    self.snapshot.canCopy = self.snapshot.canFinish
                    self.snapshot.canChangeAxis = update.state.acceptedObservations <= 1
                    self.snapshot.previewPositionVerified = update.state.matched && !update.state.previewUnavailable
                        && !self.paused && self.regionDrag == nil
                    if let image = update.preview { self.controls?.updatePreview(image: image, viewportFraction: update.viewport) }
                    self.observeAutomaticProgress(frame: frame, previousOffset: previousOffset)
                    self.setStatus(self.automaticStopMessage ?? update.state.message,
                        kind: self.automaticStopMessage != nil ? .warning :
                            (update.state.matched && !update.state.previewUnavailable ? .capturing : .warning))
                    if self.automatic { self.performAutomaticStep(source: source) }
                } catch is CancellationError { break }
                catch {
                    guard self.generation == token, !self.retired else { break }
                    self.paused = true; self.clearAutomaticState()
                    self.pauseCaptureClock(); self.snapshot.previewPositionVerified = false
                    try? await source.pauseAndDrain()
                    self.setStatus("\(error.localizedDescription) 已保留当前长图，可继续或完成", kind: .error)
                    break
                }
            }
        }
    }

    private func setStatus(_ text: String, kind: LiveScrollCaptureSnapshot.StatusKind) {
        guard !retired else { return }
        snapshot.status = deliveryWarning ?? text; snapshot.statusKind = deliveryWarning == nil ? kind : .warning
        snapshot.paused = paused; snapshot.busy = finishing || transition != nil || regionDrag != nil
        snapshot.canPause = !deliveryCompleted && !finishing && !captureLimitReached && transition == nil && regionDrag == nil && source != nil
        snapshot.canMoveRegion = !deliveryCompleted && !finishing && !captureLimitReached && transition == nil && regionDrag == nil && source != nil
        snapshot.canImport = !deliveryCompleted && lastState.width == 0 && !finishing
        snapshot.autoScrolling = automatic; snapshot.axis = axis
        let automaticAllowed = automaticScrollPermission()
        let currentVerified = snapshot.previewPositionVerified && lastAutomaticObservation != nil
            && source?.automaticScrollWatermark != nil
        snapshot.canAutoScroll = !deliveryCompleted && !finishing && !captureLimitReached && !paused
            && transition == nil && regionDrag == nil && source != nil && automaticAllowed
            && (automatic || currentVerified)
        snapshot.autoScrollUnavailableReason = captureLimitReached ? "本次捕获已达上限，可完成已有长图" :
            (!automaticAllowed ? "自动滚动需要辅助功能权限" :
                (paused ? "继续捕获并验证当前位置后可自动滚动" : "等待选区画面接上后可自动滚动"))
        if captureLimitReached { snapshot.canChangeAxis = false }
        if deliveryCompleted { snapshot.canFinish = false; snapshot.canCopy = false; snapshot.canChangeAxis = false }
        controls?.update(snapshot: snapshot)
    }

    private func togglePause() {
        guard transition == nil, regionDrag == nil, !finishing, !retired, !deliveryCompleted, let source else { return }
        if paused && updateCaptureLimit() {
            setStatus("已达到本次捕获上限，可完成保存已有长图", kind: .paused); return
        }
        let token = generation
        clearAutomaticState()
        snapshot.busy = true; snapshot.canPause = false; snapshot.canMoveRegion = false
        snapshot.previewPositionVerified = false
        snapshot.status = paused ? "正在继续…" : "正在暂停…"; controls?.update(snapshot: snapshot)
        if !paused {
            paused = true
            pauseCaptureClock(); snapshot.previewPositionVerified = false
            transition = Task { [weak self] in
                guard let self else { return }
                defer {
                    if !self.retired, self.generation == token {
                        self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
                    }
                }
                do {
                    try await source.pauseAndDrain()
                    await self.sampling?.value
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == token else { return }
                    self.sampling = nil
                    self.setStatus("已暂停 · 内容保留", kind: .paused)
                } catch is CancellationError { }
                catch {
                    guard !self.retired, self.generation == token else { return }
                    self.setStatus(error.localizedDescription, kind: .error)
                }
            }
        } else {
            transition = Task { [weak self] in
                guard let self else { return }
                defer {
                    if !self.retired, self.generation == token {
                        self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
                    }
                }
                do {
                    await self.sampling?.value
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == token else { return }
                    self.sampling = nil
                    try await source.resume()
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == token else { return }
                    self.paused = false; self.resumeCaptureClock()
                    self.setStatus("继续滚动，自动接回已捕获内容", kind: .capturing)
                    self.startSampling()
                } catch is CancellationError { }
                catch {
                    guard !self.retired, self.generation == token else { return }
                    self.setStatus(error.localizedDescription, kind: .error)
                }
            }
        }
    }

    private func finish(copyOnly: Bool) {
        guard !finishing, !retired, !deliveryCompleted, transition == nil, regionDrag == nil, lastState.width > 0, let source, let assembler else { return }
        finishing = true; paused = true; clearAutomaticState()
        pauseCaptureClock(); snapshot.previewPositionVerified = false
        setStatus("正在完成长截图…", kind: .finishing)
        transition = Task { [weak self] in
            guard let self else { return }
            defer { if !self.retired { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) } }
            do {
                var teardownWarning: Error?
                do { try await source.pauseAndDrain() } catch { teardownWarning = error }
                await self.sampling?.value; self.sampling = nil
                let image = try await assembler.finish()
                try Task.checkCancellation()
                guard !self.retired else { return }
                if copyOnly { self.onCopy(image) }
                else { try self.onComplete(image) }
                // Delivery is terminal even if stopping the source was not confirmed.
                // Set this only after the recipient returns successfully, so a
                // throwing editor/history callback retains the draft and retry.
                self.deliveryCompleted = true
                if let teardownWarning {
                    self.finishing = false
                    let warning = "\(copyOnly ? "长图已复制" : "长图已完成")，但采集停止未确认：\(teardownWarning.localizedDescription)。请关闭本次捕获。"
                    self.deliveryWarning = warning
                    self.setStatus(warning, kind: .warning)
                } else { await self.retire() }
            } catch {
                self.finishing = false
                self.setStatus("\(error.localizedDescription) 当前长图仍保留，可重试", kind: .error)
            }
        }
    }

    /// Source implementations reject retired generations before delivery. Keep
    /// the session boundary defensive too: stale metadata cannot mutate accepted
    /// pixels or acknowledge automatic progress in an injected/delayed source.
    private func acceptFrameIdentity(_ frame: LiveScrollScreenSource.Frame,
                                     source: any LiveScrollFrameSource) -> Bool {
        let mark = LiveScrollFrameWatermark(generation: frame.generation, sequence: frame.sequence)
        if let producer = source.automaticScrollWatermark {
            guard mark.generation == producer.generation, mark.sequence <= producer.sequence else { return false }
        }
        if let previous = lastConsumedFrame {
            guard mark.generation > previous.generation ||
                (mark.generation == previous.generation && mark.sequence > previous.sequence) else { return false }
        }
        lastConsumedFrame = mark
        return true
    }

    private func clearAutomaticState() {
        automatic = false; pendingAutomaticStep = nil
        lastAutomaticObservation = nil; automaticStopMessage = nil
    }

    private func stopAutomatic(_ message: String) {
        automatic = false; pendingAutomaticStep = nil
        automaticStopMessage = message
        setStatus(message, kind: .warning)
    }

    private func toggleAutomatic() {
        guard !deliveryCompleted, !finishing, !paused, !captureLimitReached,
              transition == nil, regionDrag == nil, !retired, let source else { return }
        if automatic {
            stopAutomatic("已停止自动滚动，可继续手动滚动")
            return
        }
        guard automaticScrollPermission() else {
            stopAutomatic("自动滚动需要辅助功能权限；仍可直接手动滚动")
            return
        }
        guard snapshot.previewPositionVerified, lastAutomaticObservation != nil,
              source.automaticScrollWatermark != nil else {
            stopAutomatic("等待选区画面接上后再开始自动滚动")
            return
        }
        automatic = true; pendingAutomaticStep = nil; automaticStopMessage = nil
        performAutomaticStep(source: source)
        if automatic { setStatus("自动滚动中 · 可随时暂停或完成", kind: .capturing) }
    }

    /// Matching establishes observed progress, not causal acknowledgement of an
    /// OS input event. A producer fence rejects frames already queued at emission;
    /// no comparison mixes SCK presentation timestamps with the session clock.
    private func observeAutomaticProgress(frame: LiveScrollScreenSource.Frame, previousOffset: Int) {
        guard !paused, regionDrag == nil, !finishing, !retired else {
            lastAutomaticObservation = nil; return
        }
        guard lastState.matched, !lastState.previewUnavailable else {
            lastAutomaticObservation = nil
            if automatic { stopAutomatic("自动滚动已停，稍往回滚接回长图；已有内容保留") }
            return
        }
        let mark = LiveScrollFrameWatermark(generation: frame.generation, sequence: frame.sequence)
        if let previous = lastAutomaticObservation {
            guard mark.generation == previous.frame.generation else {
                lastAutomaticObservation = nil
                if automatic { stopAutomatic("画面来源已变化，自动滚动已停；可手动继续") }
                return
            }
            guard mark.sequence > previous.frame.sequence else { return }
        }
        lastAutomaticObservation = AutomaticObservation(frame: mark, viewportOffset: lastState.viewportOffset)
        if automatic {
            if let pending = pendingAutomaticStep {
                guard monotonicNow() - pending.sentAt < automaticProgressTimeout else {
                    stopAutomatic("自动滚动已停：未确认页面移动；可手动继续或完成")
                    return
                }
                guard mark.generation == pending.fence.generation else {
                    stopAutomatic("画面来源已变化，自动滚动已停；可手动继续")
                    return
                }
                if lastState.viewportOffset < pending.viewportOffset {
                    stopAutomatic("检测到向回滚动，自动滚动已停；已有内容保留")
                } else if mark.sequence > pending.fence.sequence,
                          lastState.viewportOffset > pending.viewportOffset,
                          lastState.viewportOffset > previousOffset {
                    pendingAutomaticStep = nil
                }
            } else if lastState.viewportOffset < previousOffset {
                stopAutomatic("检测到向回滚动，自动滚动已停；已有内容保留")
            }
        } else if lastState.viewportOffset != previousOffset {
            // Manual recovery replaces a stale stop notice only after an actual
            // matched movement. Duplicate frames cannot erase its explanation.
            automaticStopMessage = nil
        }
    }

    private func performAutomaticStep(source: any LiveScrollFrameSource) {
        guard automatic, !paused, !finishing, !retired, !deliveryCompleted,
              transition == nil, regionDrag == nil, let region else { return }
        // Let the sampling loop perform its existing asynchronous drain at the
        // cap. Do not set paused here and skip that owned teardown boundary.
        guard samples < maximumSamples, activeCaptureDuration < maximumDuration else { return }
        guard automaticScrollPermission() else {
            stopAutomatic("辅助功能权限不可用，自动滚动已停；仍可手动继续")
            return
        }
        let now = monotonicNow()
        if let pending = pendingAutomaticStep {
            if now - pending.sentAt >= automaticProgressTimeout {
                stopAutomatic("自动滚动已停：未确认页面移动；可手动继续或完成")
            }
            return
        }
        guard snapshot.previewPositionVerified, let observation = lastAutomaticObservation,
              now - lastAutoEvent >= 0.35 else { return }
        do {
            try source.validateTarget()
            guard let before = source.automaticScrollWatermark,
                  before.generation == observation.frame.generation else {
                stopAutomatic("画面来源尚未就绪，自动滚动已停；可手动继续")
                return
            }
            let amount = Int32(max(12, min(120, (axis == .vertical ? region.height : region.width) * 0.14)))
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: axis == .vertical ? -amount : 0, wheel2: axis == .horizontal ? -amount : 0, wheel3: 0) else {
                stopAutomatic("无法创建滚动操作；仍可手动继续")
                return
            }
            event.location = CGPoint(x: source.displayBounds.minX + region.midX,
                                     y: source.displayBounds.minY + region.midY)
            let offset = lastState.viewportOffset
            if let automaticScrollInput { try automaticScrollInput(event) }
            else { event.post(tap: .cghidEventTap) }
            // A test sink or native callback can synchronously initiate closure.
            // Never install a pending operation after ownership/lifecycle changed.
            guard automatic, !paused, !finishing, !retired, !deliveryCompleted,
                  transition == nil, regionDrag == nil else { return }
            guard let fence = source.automaticScrollWatermark,
                  fence.generation == observation.frame.generation else {
                stopAutomatic("画面来源已变化，自动滚动已停；可手动继续")
                return
            }
            lastAutoEvent = now
            pendingAutomaticStep = PendingAutomaticStep(fence: fence, viewportOffset: offset, sentAt: now)
            snapshot.previewPositionVerified = false
            setStatus("自动滚动中 · 等待画面接上", kind: .capturing)
        } catch {
            stopAutomatic("自动滚动已停：\(error.localizedDescription)；已有长图保留，可手动继续或完成")
        }
    }

    /// Dragging moves only the visible proposal. Acquisition is drained once;
    /// an early mouse-up waits for that boundary before applying a new region.
    private func beginRegionDrag(id: UUID) -> Bool {
        guard transition == nil, regionDrag == nil, !finishing, !retired,
              !deliveryCompleted, !captureLimitReached, let source, screen != nil else { return false }
        let drag = RegionDrag(id: id, generation: generation, wasPaused: paused,
                              originalRegion: source.region)
        regionDrag = drag
        paused = true; clearAutomaticState(); pauseCaptureClock()
        snapshot.previewPositionVerified = false
        setStatus("拖动选区 · 松开后继续验证接缝，Esc 取消", kind: .paused)
        transition = Task { [weak self] in
            guard let self else { return }
            do {
                try await source.pauseAndDrain()
                await self.sampling?.value
                try Task.checkCancellation()
                guard !self.retired, self.generation == drag.generation,
                      self.regionDrag?.id == id else { return }
                self.sampling = nil; self.transition = nil
                self.regionDrag?.drained = true
                if self.regionDrag?.end != nil { self.completeRegionDrag(id: id) }
                else { self.setStatus("拖动选区 · 松开后继续验证接缝，Esc 取消", kind: .paused) }
            } catch {
                guard !self.retired, self.generation == drag.generation,
                      self.regionDrag?.id == id else { return }
                self.regionDrag = nil; self.transition = nil
                self.controls?.cancelRegionDrag()
                self.region = source.region; self.placeControls()
                self.setStatus("移动未应用，长图仍保留：\(error.localizedDescription)", kind: .error)
            }
        }
        return true
    }

    private func endRegionDrag(id: UUID, frame: CGRect?) {
        guard var drag = regionDrag, drag.id == id, drag.generation == generation,
              drag.end == nil, !retired else { return }
        drag.end = frame.map { .moved($0) } ?? .cancelled
        regionDrag = drag
        if drag.drained { completeRegionDrag(id: id) }
    }

    private func completeRegionDrag(id: UUID) {
        guard transition == nil, let drag = regionDrag, drag.id == id, drag.drained,
              let end = drag.end, let source, let screen, !retired else { return }
        transition = Task { [weak self] in
            guard let self else { return }
            var applied = false
            var cancelled = false
            defer {
                if !self.retired, self.generation == drag.generation, self.regionDrag?.id == id {
                    self.regionDrag = nil; self.transition = nil
                    self.placeControls()
                    self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
                    if !self.paused { self.startSampling() }
                }
            }
            do {
                try Task.checkCancellation()
                guard self.generation == drag.generation else { throw CancellationError() }
                switch end {
                case .cancelled: cancelled = true
                case .moved(let frame):
                    guard frame.minX.isFinite, frame.minY.isFinite,
                          frame.width.isFinite, frame.height.isFinite,
                          frame.size == drag.originalRegion.size else { throw CaptureError.invalidRegion }
                    var proposed = CGRect(x: frame.minX - screen.frame.minX,
                        y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
                    if !drag.wasPaused {
                        if self.axis == .vertical { proposed.origin.x = drag.originalRegion.minX }
                        else { proposed.origin.y = drag.originalRegion.minY }
                    }
                    try source.moveRegion(to: proposed)
                    applied = true; self.region = source.region
                }
                if !drag.wasPaused, !self.updateCaptureLimit() {
                    try await source.resume()
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == drag.generation else { return }
                    self.paused = false; self.resumeCaptureClock()
                }
                if let target = source.target { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
                let status = self.captureLimitReached ? "已达到本次捕获上限，可完成保存已有长图" :
                    (cancelled ? "已取消移动，原选区和长图保留" : "选区已移动，滚动后继续验证接缝")
                self.setStatus(status, kind: self.paused ? .paused : .capturing)
            } catch {
                guard !self.retired, self.generation == drag.generation else { return }
                guard !(error is CancellationError), !Task.isCancelled else { return }
                self.region = source.region
                // A rejected proposal leaves the original source paused. Try
                // resuming that source once; a failed resume remains visible.
                if !applied, !drag.wasPaused, !self.updateCaptureLimit() {
                    do {
                        try await source.resume()
                        try Task.checkCancellation()
                        guard !self.retired, self.generation == drag.generation else { return }
                        self.paused = false; self.resumeCaptureClock()
                    } catch {
                        guard !self.retired, self.generation == drag.generation else { return }
                        self.paused = true
                    }
                }
                self.setStatus(applied ? "选区已移动，继续采集失败；长图仍保留" :
                    "移动未应用，原选区和长图保留：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func moveRegion() {
        guard transition == nil, regionDrag == nil, !finishing, !retired, !deliveryCompleted,
              !captureLimitReached, let source, let screen else { return }
        let wasPaused = paused
        paused = true; clearAutomaticState()
        pauseCaptureClock(); snapshot.previewPositionVerified = false
        snapshot.busy = true; snapshot.status = "正在准备移动选区…"; controls?.update(snapshot: snapshot)
        transition = Task { [weak self] in
            guard let self else { return }; defer { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) }
            var applied = false
            do {
                try await source.pauseAndDrain(); await self.sampling?.value; self.sampling = nil
                self.controls?.hide()
                let mover = ManualScrollRegionMover(); self.mover = mover
                let moved = try await mover.choose(screen: screen, region: source.region, movementAxis: wasPaused ? nil : self.axis)
                try source.moveRegion(to: moved); applied = true
                self.region = source.region; self.mover = nil
                if !wasPaused, !self.updateCaptureLimit() {
                    try await source.resume(); self.paused = false; self.resumeCaptureClock()
                }
                if let target = source.target { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
                self.placeControls(); self.setStatus(self.captureLimitReached ? "已达到本次捕获上限，可完成保存已有长图" :
                    "选区已移动，滚动后继续验证接缝", kind: self.paused ? .paused : .capturing)
                if !self.paused { self.startSampling() }
            } catch {
                self.mover = nil; self.region = source.region
                if !wasPaused, !self.updateCaptureLimit() {
                    do { try await source.resume(); self.paused = false; self.resumeCaptureClock() }
                    catch { self.paused = true }
                }
                if let target = source.target { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
                self.placeControls()
                self.setStatus(applied ? "选区已移动，继续采集失败；长图仍保留" : "移动未应用，已保留原选区和长图", kind: self.paused ? .paused : .capturing)
                if !self.paused { self.startSampling() }
            }
        }
    }

    private func changeAxis(_ next: ScrollAxis) {
        guard !deliveryCompleted, !captureLimitReached, regionDrag == nil, next != axis,
              lastState.acceptedObservations <= 1, transition == nil, !finishing,
              let source, let original = assembler else { return }
        paused = true; clearAutomaticState()
        pauseCaptureClock(); snapshot.previewPositionVerified = false
        snapshot.busy = true; snapshot.status = "正在切换方向…"; controls?.update(snapshot: snapshot)
        transition = Task { [weak self] in
            guard let self else { return }
            defer { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) }
            var replacement: LiveScrollAssembler?
            do {
                try await source.pauseAndDrain(); await self.sampling?.value; self.sampling = nil
                guard let first = await original.initialImageForAxisChange() else { throw CaptureError.busy }
                let fresh = LiveScrollAssembler(axis: next, generation: self.generation, storageParent: self.resourceStorageParent); replacement = fresh
                let seed = try await fresh.observe(first)
                try await source.resume()
                self.axis = next; self.assembler = fresh; replacement = nil
                await original.close()
                self.lastState = seed.state; self.snapshot.axis = next
                self.snapshot.previewPositionVerified = seed.state.matched && !seed.state.previewUnavailable
                if let image = seed.preview { self.controls?.updatePreview(image: image, viewportFraction: seed.viewport) }
                self.paused = false; self.resumeCaptureClock(); self.setStatus("方向已切换，继续滚动", kind: .capturing)
                self.startSampling()
            } catch {
                await replacement?.close()
                self.setStatus("方向未切换，原长图仍保留：\(error.localizedDescription)", kind: .error)
            }
        }
    }
    private func openImporter() {
        guard !deliveryCompleted, lastState.width == 0 else { return }
        Task { [weak self] in guard let self else { return }; await self.retire(); self.onImport() }
    }
    func cancel() {
        guard !retired else { return }
        clearAutomaticState()
        transition?.cancel(); sampling?.cancel(); mover?.cancel()
        Task { [weak self] in await self?.retire() }
    }
    private func retire() async {
        guard !retired else { return }
        retired = true; generation &+= 1; paused = true; clearAutomaticState()
        pauseCaptureClock(); regionDrag = nil
        controls?.teardown(); controls = nil
        sampling?.cancel()
        try? await source?.stop()
        await sampling?.value; sampling = nil
        await assembler?.close(); assembler = nil; source = nil
        transition = nil; onClose?(); onClose = nil
    }
}
