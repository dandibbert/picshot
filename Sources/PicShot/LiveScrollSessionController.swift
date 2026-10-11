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
    private var startedAt: TimeInterval?
    private var samples = 0
    private var lastAutoEvent: TimeInterval = 0
    private var sameViewportCount = 0
    private var previousApplication: NSRunningApplication?
    private let maximumDuration: TimeInterval = 180
    private let maximumSamples = 2400

    init(onComplete: @escaping (CGImage) throws -> Void, onImport: @escaping () -> Void,
         onCopy: ((CGImage) -> Void)? = nil) {
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
        self.assembler = LiveScrollAssembler(axis: axis, generation: token)
        installControls()
        setStatus("正在读取选区…", kind: .capturing)
        try await source.start()
        try Task.checkCancellation()
        guard generation == token, !retired else { throw CancellationError() }
        region = source.region
        placeControls()
        startedAt = ProcessInfo.processInfo.systemUptime
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

    var snapshotForVerification: LiveScrollCaptureSnapshot { snapshot }
    var stateForVerification: LiveScrollAssembler.State { lastState }
    var controlsForVerification: LiveScrollCaptureController? { controls }
    var activeMoveViewForVerification: ManualScrollRegionMoveView? { mover?.viewForVerification }
    var sampledFramesForVerification: Int { samples }
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
        actions.importImages = { [weak self] in self?.openImporter() }
        actions.help = { [weak self] in guard let self else { return }; self.setStatus("滚动页面自动接长；接不上时稍往回滚。暂停保留内容，完成进入编辑。", kind: self.snapshot.statusKind) }
        actions.cancel = { [weak self] in self?.cancel() }
        actions.onClose = { [weak self] in self?.cancel() }
        controls = LiveScrollCaptureController(actions: actions)
        snapshot.canChangeAxis = true
        snapshot.showsAutoScroll = true
        snapshot.canAutoScroll = AXIsProcessTrusted()
        placeControls()
    }

    private func placeControls() {
        guard let screen, let region else { return }
        let frame = CGRect(x: screen.frame.minX + region.minX,
                           y: screen.frame.maxY - region.maxY,
                           width: region.width, height: region.height)
        controls?.show(snapshot: snapshot, targetFrame: frame, visibleFrame: screen.visibleFrame)
    }

    private func startSampling() {
        guard sampling == nil, !retired, !paused, !finishing, let source, let assembler else { return }
        let token = generation
        sampling = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.sampling = nil } }
            while !Task.isCancelled, !self.retired, !self.paused, self.generation == token {
                if self.samples >= self.maximumSamples || ProcessInfo.processInfo.systemUptime - (self.startedAt ?? 0) >= self.maximumDuration {
                    self.paused = true; self.automatic = false
                    try? await source.pauseAndDrain()
                    self.setStatus("已达到本次捕获上限，可完成保存已有长图", kind: .paused)
                    break
                }
                do {
                    guard let frame = try await source.nextFrame(timeout: 0.75) else {
                        if self.automatic { self.sameViewportCount += 1; try self.performAutomaticStep(source: source) }
                        continue
                    }
                    self.samples += 1
                    let update = try await assembler.observe(frame.image)
                    try Task.checkCancellation()
                    guard self.generation == token, !self.retired else { break }
                    self.sameViewportCount = update.state.viewportOffset == self.lastState.viewportOffset ? self.sameViewportCount + 1 : 0
                    self.lastState = update.state
                    self.snapshot.pixelWidth = update.state.width; self.snapshot.pixelHeight = update.state.height
                    self.snapshot.acceptedFrames = update.state.acceptedObservations
                    self.snapshot.canFinish = update.state.width > 0
                    self.snapshot.canCopy = self.snapshot.canFinish
                    self.snapshot.canChangeAxis = update.state.acceptedObservations <= 1
                    if let image = update.preview { self.controls?.updatePreview(image: image, viewportFraction: update.viewport) }
                    self.setStatus(update.state.message, kind: update.state.matched && !update.state.previewUnavailable ? .capturing : .warning)
                    if self.automatic {
                        if update.state.matched { try self.performAutomaticStep(source: source) }
                        else { self.automatic = false; self.setStatus("自动滚动已停，稍往回滚接回长图", kind: .warning) }
                    }
                } catch is CancellationError { break }
                catch {
                    guard self.generation == token, !self.retired else { break }
                    self.paused = true; self.automatic = false
                    try? await source.pauseAndDrain()
                    self.setStatus("\(error.localizedDescription) 已保留当前长图，可继续或完成", kind: .error)
                    break
                }
            }
        }
    }

    private func setStatus(_ text: String, kind: LiveScrollCaptureSnapshot.StatusKind) {
        snapshot.status = deliveryWarning ?? text; snapshot.statusKind = deliveryWarning == nil ? kind : .warning
        snapshot.paused = paused; snapshot.busy = finishing || transition != nil
        snapshot.canPause = !deliveryCompleted && !finishing && transition == nil && source != nil
        snapshot.canMoveRegion = !deliveryCompleted && !finishing && transition == nil && source != nil
        snapshot.canImport = !deliveryCompleted && lastState.width == 0 && !finishing
        snapshot.autoScrolling = automatic; snapshot.axis = axis
        snapshot.canAutoScroll = !deliveryCompleted && !finishing && !paused && transition == nil && source != nil && AXIsProcessTrusted()
        if deliveryCompleted { snapshot.canFinish = false; snapshot.canCopy = false; snapshot.canChangeAxis = false }
        controls?.update(snapshot: snapshot)
    }

    private func togglePause() {
        guard transition == nil, !finishing, !retired, !deliveryCompleted, let source else { return }
        automatic = false
        snapshot.busy = true; snapshot.canPause = false; snapshot.canMoveRegion = false
        snapshot.status = paused ? "正在继续…" : "正在暂停…"; controls?.update(snapshot: snapshot)
        if !paused {
            paused = true
            transition = Task { [weak self] in
                guard let self else { return }; defer { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) }
                do {
                    try await source.pauseAndDrain()
                    await self.sampling?.value; self.sampling = nil
                    self.setStatus("已暂停 · 内容保留", kind: .paused)
                } catch { self.setStatus(error.localizedDescription, kind: .error) }
            }
        } else {
            transition = Task { [weak self] in
                guard let self else { return }; defer { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) }
                do {
                    await self.sampling?.value; self.sampling = nil
                    try await source.resume()
                    if self.startedAt == nil { self.startedAt = ProcessInfo.processInfo.systemUptime }
                    self.paused = false; self.setStatus("继续滚动，自动接回已捕获内容", kind: .capturing)
                    self.startSampling()
                } catch { self.setStatus(error.localizedDescription, kind: .error) }
            }
        }
    }

    private func finish(copyOnly: Bool) {
        guard !finishing, !retired, !deliveryCompleted, transition == nil, lastState.width > 0, let source, let assembler else { return }
        finishing = true; paused = true; automatic = false
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

    private func toggleAutomatic() {
        guard !deliveryCompleted, !finishing, !paused, source != nil else { return }
        guard AXIsProcessTrusted() else { setStatus("自动滚动需要辅助功能权限；仍可直接手动滚动", kind: .warning); return }
        automatic.toggle(); sameViewportCount = 0
        if automatic, let source { do { try performAutomaticStep(source: source) } catch { automatic = false; setStatus(error.localizedDescription, kind: .warning); return } }
        setStatus(automatic ? "自动滚动中 · 可随时暂停或完成" : "已停止自动滚动，可继续手动滚动", kind: .capturing)
    }
    private func performAutomaticStep(source: any LiveScrollFrameSource) throws {
        guard !paused, automatic, AXIsProcessTrusted(), let region else { automatic = false; return }
        try source.validateTarget()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAutoEvent >= 0.35 else { return }
        if sameViewportCount > 18 { automatic = false; setStatus("页面已无移动，可完成截图", kind: .paused); return }
        let amount = Int32(max(12, min(120, (axis == .vertical ? region.height : region.width) * 0.14)))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: axis == .vertical ? -amount : 0, wheel2: axis == .horizontal ? -amount : 0, wheel3: 0) else { return }
        event.location = CGPoint(x: source.displayBounds.minX + region.midX, y: source.displayBounds.minY + region.midY)
        event.post(tap: .cghidEventTap); lastAutoEvent = now
    }

    private func moveRegion() {
        guard transition == nil, !finishing, !retired, !deliveryCompleted, let source, let screen else { return }
        let wasPaused = paused
        paused = true; automatic = false
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
                if !wasPaused { try await source.resume(); self.paused = false }
                if let target = source.target { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
                self.placeControls(); self.setStatus("选区已移动，滚动后继续验证接缝", kind: self.paused ? .paused : .capturing)
                if !self.paused { self.startSampling() }
            } catch {
                self.mover = nil; self.region = source.region
                if !wasPaused { do { try await source.resume(); self.paused = false } catch { self.paused = true } }
                if let target = source.target { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
                self.placeControls()
                self.setStatus(applied ? "选区已移动，继续采集失败；长图仍保留" : "移动未应用，已保留原选区和长图", kind: self.paused ? .paused : .capturing)
                if !self.paused { self.startSampling() }
            }
        }
    }

    private func changeAxis(_ next: ScrollAxis) {
        guard !deliveryCompleted, next != axis, lastState.acceptedObservations <= 1, transition == nil, !finishing,
              let source, let original = assembler else { return }
        paused = true; automatic = false
        snapshot.busy = true; snapshot.status = "正在切换方向…"; controls?.update(snapshot: snapshot)
        transition = Task { [weak self] in
            guard let self else { return }
            defer { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) }
            var replacement: LiveScrollAssembler?
            do {
                try await source.pauseAndDrain(); await self.sampling?.value; self.sampling = nil
                guard let first = await original.initialImageForAxisChange() else { throw CaptureError.busy }
                let fresh = LiveScrollAssembler(axis: next, generation: self.generation); replacement = fresh
                let seed = try await fresh.observe(first)
                try await source.resume()
                self.axis = next; self.assembler = fresh; replacement = nil
                await original.close()
                self.lastState = seed.state; self.snapshot.axis = next
                if let image = seed.preview { self.controls?.updatePreview(image: image, viewportFraction: seed.viewport) }
                self.paused = false; self.setStatus("方向已切换，继续滚动", kind: .capturing)
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
        transition?.cancel(); sampling?.cancel(); mover?.cancel()
        Task { [weak self] in await self?.retire() }
    }
    private func retire() async {
        guard !retired else { return }
        retired = true; generation &+= 1; paused = true; automatic = false
        controls?.teardown(); controls = nil
        sampling?.cancel()
        try? await source?.stop()
        await sampling?.value; sampling = nil
        await assembler?.close(); assembler = nil; source = nil
        transition = nil; onClose?(); onClose = nil
    }
}
