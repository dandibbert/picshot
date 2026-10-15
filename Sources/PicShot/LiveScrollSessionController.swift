import AppKit
import ApplicationServices
import PicShotCore

/// Product owner for select → scroll → live preview → finish. It never activates
/// an inspector during capture or a recoverable alignment problem.
@MainActor
final class LiveScrollSessionController {
    var onClose: (() -> Void)?
    let sessionID = UUID()
    private let chainDependencies: LiveScrollChainDependencies?
    private let textDependencies: LiveScrollTextDependencies?
    private(set) var textAttemptID: UUID?
    /// Exists only during synchronous runner adoption, never while awaiting OCR
    /// or a terminal result. AppMain uses this exact object for admission checks.
    private(set) var stagedTextCapture: ChainCapture?
    private var pendingTextDefinition: TextScriptDefinition?
    private var textChoiceID: UUID?
    private(set) var textChoiceAlertForVerification: LiveScrollChainChoiceController?
    private(set) var textRenderCountForVerification = 0
    private(set) var chainTransaction: LiveScrollChainTransaction?
    private(set) var chainAttemptID: UUID?
    private var chainTeardownWarning: String?
    private var chainChoiceID: UUID?
    private(set) var chainChoiceAlertForVerification: LiveScrollChainChoiceController?
    private(set) var chainRenderCountForVerification = 0
    private var retirement: Task<Void, Never>?
    var retainedChainCapture: ChainCapture? { chainTransaction?.capture }
    private let onComplete: (CGImage) throws -> Void
    private let onImport: () -> Void
    private let onCopy: (CGImage) throws -> Void
    private let onPin: ((CGImage) throws -> Void)?
    private let saveDestination: (any LiveScrollSaveDestination)?
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
    private var sourceTeardownDetail: String?
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
         onCopy: ((CGImage) throws -> Void)? = nil,
         onPin: ((CGImage) throws -> Void)? = nil,
         saveDestination: (any LiveScrollSaveDestination)? = nil,
         resourceStorageParent: URL = FileManager.default.temporaryDirectory,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticScrollPermission: @escaping () -> Bool = { AXIsProcessTrusted() },
         automaticScrollInput: ((CGEvent) throws -> Void)? = nil,
         chainDependencies: LiveScrollChainDependencies? = nil,
         textDependencies: LiveScrollTextDependencies? = nil) {
        self.chainDependencies = chainDependencies
        self.textDependencies = textDependencies
        self.resourceStorageParent = resourceStorageParent
        self.monotonicNow = monotonicNow
        self.automaticScrollPermission = automaticScrollPermission
        self.automaticScrollInput = automaticScrollInput
        self.onComplete = onComplete; self.onImport = onImport
        self.onCopy = onCopy ?? { try LiveScrollClipboard.copy($0) }
        self.onPin = onPin; self.saveDestination = saveDestination
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
            } catch CaptureError.cancelled { self.requestRetirement() }
            catch is CancellationError { }
            catch {
                if self.controls != nil { self.paused = true; self.setCaptureStatus(error.localizedDescription, kind: .error) }
                else { showError(error); self.requestRetirement() }
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
    func failNextPreviewForTesting(_ failure: LiveScrollAssembler.PreviewFailureForTesting = .unavailable) async {
        await assembler?.failNextPreviewForTesting(failure)
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
        saveDestination?.cancel()
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
        actions.finishEdit = { [weak self] in self?.finish(.edit) }
        actions.copy = { [weak self] in self?.finish(.copy) }
        actions.quickSave = { [weak self] in self?.finish(.save) }
        actions.pin = { [weak self] in self?.finish(.pin) }
        actions.applyTextScript = { [weak self] in self?.chooseTextScript() }
        actions.applyImageChain = { [weak self] in self?.chooseImageChain(replacingTransactionID: nil) }
        actions.replaceImageChain = { [weak self] id in self?.chooseImageChain(replacingTransactionID: id) }
        actions.continueImageChain = { [weak self] id in self?.continueImageChain(transactionID: id) }
        actions.abandonImageChain = { [weak self] id in self?.confirmAbandonImageChain(transactionID: id) }
        actions.pauseResume = { [weak self] in self?.togglePause() }
        actions.autoScroll = { [weak self] in self?.toggleAutomatic() }
        actions.changeAxis = { [weak self] axis in self?.changeAxis(axis) }
        actions.moveRegion = { [weak self] in self?.moveRegion() }
        actions.beginRegionDrag = { [weak self] id in self?.beginRegionDrag(id: id) ?? false }
        actions.endRegionDrag = { [weak self] id, frame in self?.endRegionDrag(id: id, frame: frame) }
        actions.importImages = { [weak self] in self?.openImporter() }
        actions.help = { [weak self] in guard let self else { return }; self.setStatus("滚动页面自动接长；接不上时按提示重试。暂停保留内容，完成进入编辑。", kind: self.snapshot.statusKind) }
        actions.cancel = { [weak self] in self?.cancel() }
        actions.onClose = { [weak self] in self?.cancel() }
        controls = LiveScrollCaptureController(actions: actions)
        snapshot.canChangeAxis = true
        snapshot.showsAutoScroll = true
        snapshot.canAutoScroll = false
        placeControls()
    }

    private func placeControls() {
        guard !retired, let screen, let region else { return }
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

    private var sourceTeardownUnconfirmed: Bool { source?.hasUnconfirmedTeardown == true }

    // These are the captured raster dimensions, not screen points or an assumed
    // Retina scale. A seed may be useful horizontally but impossible vertically.
    private var captureGeometryUnsupported: Bool {
        lastState.width > 0 && lastState.acceptedObservations <= 1 &&
            !LiveScrollMatcher.supportsCapture(width: lastState.width, height: lastState.height, axis: axis)
    }

    private var captureGeometryGuidance: String {
        let other: ScrollAxis = axis == .vertical ? .horizontal : .vertical
        if LiveScrollMatcher.supportsCapture(width: lastState.width, height: lastState.height, axis: other) {
            return other == .horizontal ? "请切横向或重选" : "请切纵向或重选"
        }
        return "选区过小，请重选"
    }

    private func captureGeometryDetail(for requestedAxis: ScrollAxis) -> String {
        let requirement = requestedAxis == .vertical ? "纵向至少需要24×48像素" : "横向至少需要48×24像素"
        return "当前选区为\(lastState.width)×\(lastState.height)实际像素，\(requirement)。" +
            "原图和当前方向保留；请选择适合的方向，或关闭后重选更大选区。不会自动缩放或重开Auto。"
    }

    /// Failed sources have already fenced off producer delivery, but cannot be
    /// restarted. Keep the short action visible and the original reason in help.
    private func setCaptureStatus(_ text: String, kind: LiveScrollCaptureSnapshot.StatusKind) {
        if sourceTeardownUnconfirmed {
            if sourceTeardownDetail == nil, kind == .error { sourceTeardownDetail = text }
            setStatus(lastState.width > 0 ? "停止未确认，请完成" : "停止未确认，请关闭", kind: .error)
        } else { setStatus(text, kind: kind) }
    }

    private func startSampling() {
        guard sampling == nil, !retired, !paused, !finishing, !captureLimitReached, !sourceTeardownUnconfirmed, !captureGeometryUnsupported,
              regionDrag == nil, let source, let assembler else { return }
        let token = generation
        sampling = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.sampling = nil } }
            while !Task.isCancelled, !self.retired, !self.paused, self.generation == token {
                if self.updateCaptureLimit() {
                    self.snapshot.previewPositionVerified = false
                    do { try await source.pauseAndDrain() }
                    catch {
                        self.setCaptureStatus(error.localizedDescription, kind: .error)
                        break
                    }
                    self.setCaptureStatus("已达到本次捕获上限，可完成保存已有长图", kind: .paused)
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
                    if self.captureGeometryUnsupported {
                        // Retain one exact seed for output or an explicit valid-axis
                        // switch, but never schedule Auto or keep sampling a region
                        // that cannot satisfy the unchanged matcher geometry.
                        self.paused = true; self.clearAutomaticState(); self.pauseCaptureClock()
                        self.snapshot.previewPositionVerified = false
                        self.setCaptureStatus(self.captureGeometryGuidance, kind: .warning)
                        try await source.pauseAndDrain()
                        try Task.checkCancellation()
                        guard self.generation == token, !self.retired else { break }
                        self.setCaptureStatus(self.captureGeometryGuidance, kind: .warning)
                        break
                    }
                    self.observeAutomaticProgress(frame: frame, previousOffset: previousOffset)
                    self.setCaptureStatus(self.automaticStopMessage ?? update.state.message,
                        kind: self.automaticStopMessage != nil ? .warning :
                            (update.state.matched && !update.state.previewUnavailable ? .capturing : .warning))
                    if self.automatic { self.performAutomaticStep(source: source) }
                } catch is CancellationError { break }
                catch {
                    guard self.generation == token, !self.retired else { break }
                    self.paused = true; self.clearAutomaticState()
                    self.pauseCaptureClock(); self.snapshot.previewPositionVerified = false
                    // Durable source slots cannot be reclaimed by pausing or
                    // revisiting old content. Keep accepted output available,
                    // but never offer a restart that must reject new pixels.
                    let exhaustedSources = (error as? LiveScrollDocument.Failure) == .sourceLimit
                    if exhaustedSources { self.captureLimitReached = true }
                    var recoveryError = error
                    let alreadyFailed = source.hasUnconfirmedTeardown
                    do { try await source.pauseAndDrain() }
                    catch { if !alreadyFailed { recoveryError = error } }
                    self.setCaptureStatus(self.sourceTeardownUnconfirmed ? recoveryError.localizedDescription :
                        (exhaustedSources ? "已满100段，请完成" :
                            "\(error.localizedDescription) 已保留当前长图，可继续或完成"),
                        kind: exhaustedSources && !self.sourceTeardownUnconfirmed ? .paused : .error)
                    break
                }
            }
        }
    }

    private func setStatus(_ text: String, kind: LiveScrollCaptureSnapshot.StatusKind) {
        guard !retired else { return }
        let sourceUnavailable = sourceTeardownUnconfirmed
        if sourceUnavailable {
            paused = true; clearAutomaticState(); pauseCaptureClock()
            snapshot.previewPositionVerified = false
        }
        snapshot.statusDetail = sourceUnavailable
            ? "采集停止未确认，不能继续采集、移动或识别文字。" +
                (lastState.width > 0 ? "已接好的长图仍保留；输出时会等待当前拼接完成。" : "尚无可输出的长图，请关闭本次捕获。") +
                (sourceTeardownDetail.map { "\n" + $0 } ?? "") :
            (captureGeometryUnsupported ? captureGeometryDetail(for: axis) : "")
        snapshot.status = deliveryWarning ?? text; snapshot.statusKind = deliveryWarning == nil ? kind : .warning
        snapshot.paused = paused; snapshot.busy = finishing || transition != nil || regionDrag != nil || chainChoiceID != nil || textChoiceID != nil || textAttemptID != nil
        snapshot.canPause = !deliveryCompleted && !finishing && !captureLimitReached && !sourceUnavailable && !captureGeometryUnsupported && transition == nil && regionDrag == nil && source != nil
        snapshot.canMoveRegion = !deliveryCompleted && !finishing && !captureLimitReached && !sourceUnavailable && !captureGeometryUnsupported && transition == nil && regionDrag == nil && source != nil
        snapshot.canImport = !deliveryCompleted && lastState.width == 0 && !finishing
        let outputReady = !deliveryCompleted && !finishing && transition == nil && regionDrag == nil && lastState.width > 0
        snapshot.canFinish = outputReady; snapshot.canCopy = outputReady
        snapshot.canChangeAxis = !captureLimitReached && !sourceUnavailable && lastState.width > 0 && lastState.acceptedObservations <= 1
        snapshot.canQuickSave = outputReady && saveDestination != nil
        snapshot.canPin = outputReady && onPin != nil && Self.canPin(width: lastState.width, height: lastState.height)
        snapshot.pinUnavailableReason = lastState.width == 0 || Self.canPin(width: lastState.width, height: lastState.height) ? "" : "贴图最多支持 3200 万像素；可完成并编辑或快速保存原尺寸长图"
        snapshot.autoScrolling = automatic; snapshot.axis = axis
        let automaticAllowed = automaticScrollPermission()
        let currentVerified = snapshot.previewPositionVerified && lastAutomaticObservation != nil
            && source?.automaticScrollWatermark != nil
        snapshot.canAutoScroll = !deliveryCompleted && !finishing && !captureLimitReached && !sourceUnavailable && !captureGeometryUnsupported && !paused
            && transition == nil && regionDrag == nil && source != nil && automaticAllowed
            && (automatic || currentVerified)
        snapshot.autoScrollUnavailableReason = sourceUnavailable ? "采集停止未确认，请完成已有长图" : captureGeometryUnsupported ? captureGeometryGuidance : captureLimitReached ? "本次捕获已达上限，可完成已有长图" :
            (!automaticAllowed ? "自动滚动需要辅助功能权限" :
                (paused ? "继续捕获并验证当前位置后可自动滚动" : "等待选区画面接上后可自动滚动"))
        if captureLimitReached { snapshot.canChangeAxis = false }
        if deliveryCompleted { snapshot.canFinish = false; snapshot.canCopy = false; snapshot.canChangeAxis = false }
        let chainReady = !retired && !deliveryCompleted && !finishing && transition == nil
            && regionDrag == nil && chainChoiceID == nil && textChoiceID == nil && textAttemptID == nil
            && lastState.width > 0 && chainDependencies != nil
        snapshot.canApplyImageChain = chainReady && chainTransaction == nil
        snapshot.canContinueImageChain = chainReady && chainTransaction != nil
        snapshot.canReplaceImageChain = snapshot.canContinueImageChain
        snapshot.canAbandonImageChain = snapshot.canContinueImageChain && !captureLimitReached && !captureGeometryUnsupported
        snapshot.chainTransactionID = chainTransaction?.transactionID
        snapshot.chainContinueTitle = chainTransaction.map {
            "继续「\($0.definition.name)」（\($0.receipts.count)/\($0.definition.outputs.count) 已完成）"
        } ?? ""
        let textSizeAllowed = PinImageRenderer.allowsRasterSize(width: lastState.width, height: lastState.height)
        snapshot.canApplyTextScript = canCommandTextScript && textSizeAllowed
        snapshot.textScriptUnavailableReason = sourceUnavailable ? "采集停止未确认，无法开始文字识别；可完成或保存已有长图" : lastState.width > 0 && !textSizeAllowed
            ? "本地识别最多支持 3200 万像素；可完成并编辑或保存原尺寸长图" : ""
        if chainTransaction != nil || chainChoiceID != nil || textChoiceID != nil || textAttemptID != nil {
            snapshot.canFinish = false; snapshot.canCopy = false; snapshot.canQuickSave = false; snapshot.canPin = false
            snapshot.canPause = false; snapshot.canMoveRegion = false; snapshot.canAutoScroll = false
            snapshot.canChangeAxis = false; snapshot.canImport = false
        }
        controls?.update(snapshot: snapshot)
    }

    private func togglePause() {
        guard chainTransaction == nil, chainChoiceID == nil, textChoiceID == nil, textAttemptID == nil, transition == nil, regionDrag == nil, !finishing, !retired, !deliveryCompleted, !captureLimitReached, !sourceTeardownUnconfirmed, !captureGeometryUnsupported, let source else { return }
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
                    self.setCaptureStatus(error.localizedDescription, kind: .error)
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
                    guard !source.hasUnconfirmedTeardown else {
                        self.setCaptureStatus(LiveScrollSourceError.unconfirmedTeardown.localizedDescription, kind: .error)
                        return
                    }
                    try await source.resume()
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == token else { return }
                    self.paused = false; self.resumeCaptureClock()
                    self.setStatus("继续滚动，自动接回已捕获内容", kind: .capturing)
                    self.startSampling()
                } catch is CancellationError { }
                catch {
                    guard !self.retired, self.generation == token else { return }
                    self.setCaptureStatus(error.localizedDescription, kind: .error)
                }
            }
        }
    }

    private var canCommandTextScript: Bool {
        !retired && !deliveryCompleted && !finishing && !sourceTeardownUnconfirmed && transition == nil && regionDrag == nil
            && chainTransaction == nil && chainChoiceID == nil && textChoiceID == nil && textAttemptID == nil
            && lastState.width > 0 && textDependencies != nil
    }

    private func chooseTextScript() {
        guard canCommandTextScript, let dependencies = textDependencies,
              let parent = controls?.toolbarWindow else { return }
        let token = generation, choice = UUID()
        textChoiceID = choice
        do {
            let definitions = try dependencies.definitions()
            guard !retired, generation == token, textChoiceID == choice else { return }
            guard !definitions.isEmpty else {
                throw PicShotError.message("尚未保存文字脚本，请在文字脚本管理中创建后再选择。")
            }
            let alert = LiveScrollChainChoiceController(textScripts: definitions)
            let picker = alert.accessoryView as? NSPopUpButton
            textChoiceAlertForVerification = alert
            setStatus(snapshot.status, kind: snapshot.statusKind)
            alert.beginSheetModal(for: parent) { [weak self, weak picker] response in
                guard let self, !self.retired, self.generation == token, self.textChoiceID == choice else { return }
                let index = picker?.indexOfSelectedItem
                self.textChoiceID = nil; self.textChoiceAlertForVerification = nil
                self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
                guard response == .alertFirstButtonReturn, let index, definitions.indices.contains(index) else { return }
                _ = self.startTextScript(definition: definitions[index])
            }
        } catch {
            if !retired, generation == token, textChoiceID == choice {
                textChoiceID = nil; setStatus(error.localizedDescription, kind: .error)
            }
        }
    }

    /// A saved definition must still match the catalog when the user explicitly
    /// presses Run. Opening or changing the picker never launches a script.
    @discardableResult func startTextScript(definition: TextScriptDefinition) -> Bool {
        guard canCommandTextScript, let dependencies = textDependencies, source != nil, assembler != nil else { return false }
        let token = generation
        finishing = true // Reserve before reentrant catalog callbacks.
        do {
            guard try dependencies.definitions().contains(definition) else { throw TextScriptCatalogError.missingDefinition }
        } catch {
            if !retired, generation == token { finishing = false; setStatus(error.localizedDescription, kind: .error) }
            return false
        }
        guard !retired, generation == token else { return false }
        guard PinImageRenderer.allowsRasterSize(width: lastState.width, height: lastState.height) else {
            finishing = false; setStatus(Self.textSizeMessage, kind: .warning)
            return false
        }
        paused = true; clearAutomaticState(); pauseCaptureClock()
        snapshot.previewPositionVerified = false
        let runID = UUID()
        textAttemptID = runID
        // Store preparation metadata only until the helper returns. The outer
        // task captures value IDs and a value-only completion cell, not pixels
        // or executable source that would remain alive during the terminal wait.
        pendingTextDefinition = definition
        let terminal = TextTerminal(runID: runID, definitionID: definition.id, definitionName: definition.name)
        setStatus("正在准备本次长截图的文字识别…", kind: .finishing)
        transition = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.textAttemptID == runID {
                    self.textAttemptID = nil; self.pendingTextDefinition = nil; self.stagedTextCapture = nil
                }
                if !self.retired, self.generation == token {
                    self.transition = nil; self.finishing = false
                    self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
                }
            }
            do {
                try await self.prepareTextScript(runID: runID, token: token, terminal: terminal)
                let result = await terminal.wait()
                guard !self.retired, self.generation == token, self.textAttemptID == runID else { return }
                if result.textReceipt != nil {
                    // A checked Copy followed by Cancel is a committed result.
                    self.deliveryCompleted = true
                    self.requestRetirement()
                } else {
                    self.setStatus("已停止文字处理，当前长图保持暂停；再次处理需重新选择文字脚本", kind: .paused)
                }
            } catch is CancellationError {
                if !self.retired, self.generation == token { self.setStatus("已停止文字处理，当前长图保持暂停", kind: .paused) }
            } catch {
                if !self.retired, self.generation == token {
                    self.setStatus(error.localizedDescription + "；当前长图保持暂停", kind: .error)
                }
            }
        }
        return true
    }

    func acceptsTextRun(runID: UUID) -> Bool {
        !retired && finishing && textAttemptID == runID
    }

    private static let textSizeMessage = "本地识别最多支持 3200 万像素；当前长图仍保留，可完成并编辑或保存原尺寸长图"

    /// This async scope must end before the outer terminal wait. In particular,
    /// no image local, prepared capture, or script definition can be retained by
    /// the scroll owner's suspended terminal task after runner adoption.
    private func prepareTextScript(runID: UUID, token: UInt64, terminal: TextTerminal) async throws {
        guard !retired, generation == token, textAttemptID == runID,
              let source, let assembler, let dependencies = textDependencies else { throw CancellationError() }
        defer { pendingTextDefinition = nil; stagedTextCapture = nil }
        // Unlike image delivery, OCR cannot begin after an unconfirmed drain.
        try await source.pauseAndDrain()
        await sampling?.value; sampling = nil
        try Task.checkCancellation()
        guard !retired, generation == token, textAttemptID == runID else { throw CancellationError() }
        guard let definition = pendingTextDefinition else { throw CancellationError() }
        guard PinImageRenderer.allowsRasterSize(width: lastState.width, height: lastState.height) else {
            throw PicShotError.message(Self.textSizeMessage)
        }
        let image = try await assembler.finish()
        textRenderCountForVerification += 1
        try Task.checkCancellation()
        guard !retired, generation == token, textAttemptID == runID else { throw CancellationError() }
        let prepared = try ChainCapture(image: image)
        stagedTextCapture = prepared
        setStatus("正在识别文字并执行所选脚本…", kind: .finishing)
        // Settlement deliberately has no self/generation guard. Close cancels
        // the owned runner, then awaits this task even after retiring its UI.
        try dependencies.start(sessionID, runID, definition, prepared) { result in terminal.accept(result) }
        stagedTextCapture = nil
    }

    /// Handles terminal-before-await, duplicate callbacks and old-run callbacks
    /// without making the session or its generation own continuation settlement.
    @MainActor private final class TextTerminal {
        let runID: UUID
        private let definitionID: UUID
        private let definitionName: String
        private var result: CaptureChainSnapshot?
        private var waiter: CheckedContinuation<CaptureChainSnapshot, Never>?
        init(runID: UUID, definitionID: UUID, definitionName: String) {
            self.runID = runID; self.definitionID = definitionID; self.definitionName = definitionName
        }
        func accept(_ snapshot: CaptureChainSnapshot) {
            guard result == nil, snapshot.runID == runID, snapshot.isTextScript,
                  snapshot.isExistingScrollImage, snapshot.status.isTerminal,
                  snapshot.definition.id == definitionID, snapshot.definition.name == definitionName,
                  snapshot.definition.source == .region, snapshot.definition.outputs == [.copy],
                  snapshot.receipts.isEmpty else { return }
            result = snapshot
            let pending = waiter; waiter = nil
            pending?.resume(returning: snapshot)
        }
        func wait() async -> CaptureChainSnapshot {
            if let result { return result }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    private var canCommandImageChain: Bool {
        !retired && !deliveryCompleted && !finishing && transition == nil && regionDrag == nil
            && chainChoiceID == nil && textChoiceID == nil && textAttemptID == nil
            && lastState.width > 0 && chainDependencies != nil
    }

    private func preflightImageChain(_ definition: CaptureChainDefinition, committedCount: Int,
                                     width: Int, height: Int) throws {
        guard committedCount >= 0, committedCount <= definition.outputs.count else { throw CaptureChainError.invalidOutputs }
        if definition.outputs.dropFirst(committedCount).contains(.pin), !Self.canPin(width: width, height: height) {
            throw PicShotError.message("贴图最多支持 3200 万像素；未开始任何后续输出，当前长图仍保留")
        }
        try chainDependencies?.preflight(definition, committedCount, width, height)
    }

    private func chooseImageChain(replacingTransactionID: UUID?) {
        guard canCommandImageChain, replacingTransactionID == chainTransaction?.transactionID,
              let dependencies = chainDependencies, let parent = controls?.toolbarWindow else { return }
        let expectedTransaction = replacingTransactionID
        let replacing = replacingTransactionID != nil
        let token = generation, choice = UUID()
        chainChoiceID = choice
        do {
            let definitions = try dependencies.definitions()
            guard !retired, generation == token, chainChoiceID == choice else { return }
            guard !definitions.isEmpty else { throw PicShotError.message("尚未保存截图链，请在截图链管理中创建后再选择。") }
            let prior = chainTransaction.map { "\n\n" + $0.committedDescription } ?? ""
            let consequenceWarning = replacing ? "开始新动作链会从第一步执行，可能再次保存、复制或贴图。" : nil
            let alert = LiveScrollChainChoiceController(
                title: replacing ? "选择其他动作链重新处理" : "使用截图链处理当前长图",
                informativeText: "来源：本次长截图。仅执行所选链的图片输出，按保存的顺序处理。" + prior,
                definitions: definitions,
                confirmTitle: replacing ? "开始新动作链" : "处理当前长图",
                confirmIdentifier: "scroll.live.imageChain.run",
                cancelIdentifier: "scroll.live.imageChain.choice.cancel",
                consequenceWarning: consequenceWarning)
            let picker = alert.accessoryView as? NSPopUpButton
            chainChoiceID = choice; chainChoiceAlertForVerification = alert
            setStatus(snapshot.status, kind: snapshot.statusKind)
            alert.beginSheetModal(for: parent) { [weak self, weak picker] response in
                guard let self, !self.retired, self.generation == token, self.chainChoiceID == choice else { return }
                let selectedIndex = picker?.indexOfSelectedItem
                self.chainChoiceID = nil; self.chainChoiceAlertForVerification = nil
                self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
                guard response == .alertFirstButtonReturn, self.chainTransaction?.transactionID == expectedTransaction,
                      let index = selectedIndex, definitions.indices.contains(index) else { return }
                _ = self.startImageChain(definition: definitions[index], replacingTransactionID: expectedTransaction)
            }
        } catch {
            if !retired, generation == token, chainChoiceID == choice {
                chainChoiceID = nil; setStatus(error.localizedDescription, kind: .error)
            }
        }
    }

    /// Called only by an explicit Apply/New action. Equality revalidates the
    /// picker snapshot, so stale selections cannot silently use edited metadata.
    @discardableResult func startImageChain(definition: CaptureChainDefinition,
                                            replacingTransactionID: UUID? = nil) -> Bool {
        guard canCommandImageChain, chainTransaction?.transactionID == replacingTransactionID,
              let dependencies = chainDependencies, let source, let assembler else { return false }
        let token = generation
        // Reserve before catalog/preflight callbacks, which may synchronously
        // cancel or try another command in an injected/native observer.
        finishing = true
        do {
            guard try dependencies.definitions().contains(definition) else { throw CaptureChainError.missingDefinition }
            let width = chainTransaction?.capture.image.width ?? lastState.width
            let height = chainTransaction?.capture.image.height ?? lastState.height
            try preflightImageChain(definition, committedCount: 0, width: width, height: height)
            guard !retired, generation == token else { return false }
            if let old = chainTransaction {
                // Validate the new transaction before discarding any old receipt.
                chainTransaction = try LiveScrollChainTransaction(sessionID: sessionID, generation: generation,
                    revisionID: old.revisionID, capture: old.capture, definition: definition)
            }
        } catch {
            if !retired, generation == token { finishing = false; setStatus(error.localizedDescription, kind: .error) }
            return false
        }
        paused = true; clearAutomaticState(); pauseCaptureClock()
        snapshot.previewPositionVerified = false
        setStatus("正在准备本次长截图…", kind: .finishing)
        transition = Task { [weak self] in
            guard let self else { return }
            defer {
                if !self.retired, self.generation == token {
                    self.transition = nil; self.finishing = false
                    self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
                }
            }
            do {
                if self.chainTransaction == nil {
                    do { try await source.pauseAndDrain() }
                    catch { self.chainTeardownWarning = error.localizedDescription }
                    await self.sampling?.value; self.sampling = nil
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == token else { return }
                    try self.preflightImageChain(definition, committedCount: 0,
                        width: self.lastState.width, height: self.lastState.height)
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == token else { return }
                    let image = try await assembler.finish()
                    self.chainRenderCountForVerification += 1
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == token else { return }
                    let captured = try ChainCapture(image: image)
                    self.chainTransaction = try LiveScrollChainTransaction(sessionID: self.sessionID,
                        generation: token, capture: captured, definition: definition)
                }
                guard let transaction = self.chainTransaction else { return }
                try await self.performImageChain(transaction, token: token)
            } catch is CancellationError {
                if !self.retired, self.generation == token { self.setStatus("已停止后续操作，长图保持暂停", kind: .paused) }
            } catch {
                if !self.retired, self.generation == token {
                    self.setStatus(error.localizedDescription + "；长图保持暂停", kind: .error)
                }
            }
        }
        return true
    }

    @discardableResult func continueImageChain(transactionID: UUID) -> Bool {
        guard canCommandImageChain, let transaction = chainTransaction,
              transaction.transactionID == transactionID else { return false }
        let token = generation
        finishing = true
        do {
            try preflightImageChain(transaction.definition, committedCount: transaction.receipts.count,
                width: transaction.capture.image.width, height: transaction.capture.image.height)
        } catch {
            if !retired, generation == token { finishing = false; setStatus(error.localizedDescription, kind: .error) }
            return false
        }
        guard !retired, generation == token else { return false }
        setStatus("正在继续未完成的操作…", kind: .finishing)
        transition = Task { [weak self] in
            guard let self else { return }
            defer {
                if !self.retired, self.generation == token {
                    self.transition = nil; self.finishing = false
                    self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
                }
            }
            do { try await self.performImageChain(transaction, token: token) }
            catch {
                if !self.retired, self.generation == token { self.setStatus(error.localizedDescription, kind: .error) }
            }
        }
        return true
    }

    private func performImageChain(_ transaction: LiveScrollChainTransaction, token: UInt64) async throws {
        guard !retired, generation == token, chainTransaction?.transactionID == transaction.transactionID,
              let dependencies = chainDependencies else { throw CancellationError() }
        try Task.checkCancellation()
        try preflightImageChain(transaction.definition, committedCount: transaction.receipts.count,
            width: transaction.capture.image.width, height: transaction.capture.image.height)
        try Task.checkCancellation()
        guard !retired, generation == token, chainTransaction?.transactionID == transaction.transactionID else { return }
        let runID = UUID()
        chainAttemptID = runID
        defer { if chainAttemptID == runID { chainAttemptID = nil } }
        let result = try await dependencies.run(transaction, runID)
        guard !retired, generation == token, chainAttemptID == runID,
              var current = chainTransaction, current.transactionID == transaction.transactionID,
              current.revisionID == transaction.revisionID else { return }
        try current.accept(result, runID: runID)
        chainTransaction = current
        // A final successful output followed by cancellation is still complete.
        if current.isComplete {
            deliveryCompleted = true
            if let warning = chainTeardownWarning {
                deliveryWarning = "长图动作链已全部完成，但采集停止未确认：\(warning)。请关闭本次捕获。"
                chainTransaction = nil
                setStatus(deliveryWarning!, kind: .warning)
            } else { requestRetirement() }
        } else {
            setStatus("已停止后续操作，长图保持暂停。已完成 \(current.receipts.count)/\(current.definition.outputs.count)；继续不会重复已完成操作。",
                      kind: .paused)
        }
    }

    private func confirmAbandonImageChain(transactionID: UUID) {
        guard canCommandImageChain, let transaction = chainTransaction, transaction.transactionID == transactionID,
              let parent = controls?.toolbarWindow, !captureLimitReached, !captureGeometryUnsupported else { return }
        let token = generation, choice = UUID()
        let alert = LiveScrollChainChoiceController(title: "放弃未完成操作并继续采集？",
            informativeText: transaction.committedDescription,
            confirmTitle: "放弃并继续采集", confirmIdentifier: "scroll.live.imageChain.abandon.confirm",
            cancelIdentifier: "scroll.live.imageChain.abandon.cancel",
            consequenceWarning: "已保存的文件和贴图仍保留。放弃后将清除本次续传记录，再次处理长图可能重复输出。")
        chainChoiceID = choice; chainChoiceAlertForVerification = alert
        setStatus(snapshot.status, kind: snapshot.statusKind)
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self, !self.retired, self.generation == token, self.chainChoiceID == choice else { return }
            self.chainChoiceID = nil; self.chainChoiceAlertForVerification = nil
            self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind)
            if response == .alertFirstButtonReturn { _ = self.abandonImageChain(transactionID: transactionID) }
        }
    }

    /// The warning's explicit action is the only product caller. Release the
    /// checkpoint before toggling acquisition; the next Finish is a new revision.
    @discardableResult func abandonImageChain(transactionID: UUID) -> Bool {
        guard canCommandImageChain, !captureLimitReached, !captureGeometryUnsupported,
              chainTransaction?.transactionID == transactionID else { return false }
        chainTransaction = nil; chainTeardownWarning = nil
        setStatus("已放弃未完成操作；已完成的外部结果仍保留", kind: .paused)
        togglePause()
        return true
    }

    private enum OutputDestination: Equatable {
        case edit, copy, save, pin
        var completedMessage: String {
            switch self {
            case .edit: return "长图已完成"
            case .copy: return "长图已复制"
            case .save: return "长图已保存"
            case .pin: return "长图已贴到屏幕"
            }
        }
    }

    static func canPin(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && height <= 32_000_000 && width <= 32_000_000 / height
    }

    private func finish(_ destination: OutputDestination) {
        guard chainTransaction == nil, chainChoiceID == nil, textChoiceID == nil, textAttemptID == nil, !finishing, !retired, !deliveryCompleted, transition == nil, regionDrag == nil,
              lastState.width > 0, let source, let assembler else { return }
        if destination == .save && saveDestination == nil { return }
        if destination == .pin {
            guard onPin != nil else { return }
            guard Self.canPin(width: lastState.width, height: lastState.height) else {
                setStatus("贴图最多支持 3200 万像素，当前长图仍保留，可完成并编辑或快速保存", kind: .warning)
                return
            }
        }
        finishing = true; paused = true; clearAutomaticState()
        pauseCaptureClock(); snapshot.previewPositionVerified = false
        setStatus("正在完成长截图…", kind: .finishing)
        let token = generation
        transition = Task { [weak self] in
            guard let self else { return }
            defer { if !self.retired { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) } }
            do {
                var teardownWarning: Error?
                do { try await source.pauseAndDrain() } catch { teardownWarning = error }
                await self.sampling?.value; self.sampling = nil
                try Task.checkCancellation()
                guard !self.retired, self.generation == token else { return }
                // A final observation may extend the accepted image while the
                // source drains. Recheck before allocating the full raster.
                if destination == .pin && !Self.canPin(width: self.lastState.width, height: self.lastState.height) {
                    throw PicShotError.message("贴图最多支持 3200 万像素，请快速保存原尺寸长图")
                }
                let image = try await assembler.finish()
                try Task.checkCancellation()
                guard !self.retired, self.generation == token else { return }
                switch destination {
                case .copy: try self.onCopy(image)
                case .edit: try self.onComplete(image)
                case .pin:
                    guard Self.canPin(width: image.width, height: image.height) else {
                        throw PicShotError.message("贴图最多支持 3200 万像素，请快速保存原尺寸长图")
                    }
                    try self.onPin?(image)
                case .save:
                    guard let saveDestination = self.saveDestination else { throw CancellationError() }
                    self.setStatus("等待保存完成，取消保存后仍可继续处理长图", kind: .finishing)
                    try await saveDestination.save(image: image, parent: self.controls?.toolbarWindow)
                }
                guard !self.retired, self.generation == token else { return }
                // Only the recipient's confirmed acceptance commits this result.
                // Save admission, cancelled panels and rejected clipboard/pin
                // writes leave the paused spool available for another route.
                self.deliveryCompleted = true
                if let teardownWarning {
                    self.finishing = false
                    let warning = "\(destination.completedMessage)，但采集停止未确认：\(teardownWarning.localizedDescription)。请关闭本次捕获。"
                    self.deliveryWarning = warning
                    self.setStatus(warning, kind: .warning)
                } else { self.requestRetirement() }
            } catch is CancellationError {
                guard !self.retired, self.generation == token else { return }
                self.finishing = false
                self.setStatus("已取消输出，当前长图仍保留，可重试或选择其他方式", kind: .paused)
            } catch {
                guard !self.retired, self.generation == token else { return }
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
        guard chainTransaction == nil, chainChoiceID == nil, textChoiceID == nil, textAttemptID == nil, !deliveryCompleted, !finishing, !paused, !captureLimitReached, !sourceTeardownUnconfirmed, !captureGeometryUnsupported,
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
            // A later rejected manual retry may have a different cause. Keep
            // that current advice visible while Auto remains stopped.
            if automatic || automaticStopMessage != nil { stopAutomatic("自动滚动已停：\(lastState.message)") }
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
        guard automatic, !paused, !finishing, !retired, !deliveryCompleted, !source.hasUnconfirmedTeardown,
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
            guard automatic, !paused, !finishing, !retired, !deliveryCompleted, !source.hasUnconfirmedTeardown,
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
        guard chainTransaction == nil, chainChoiceID == nil, textChoiceID == nil, textAttemptID == nil, transition == nil, regionDrag == nil, !finishing, !retired,
              !deliveryCompleted, !captureLimitReached, !sourceTeardownUnconfirmed, !captureGeometryUnsupported, let source, screen != nil else { return false }
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
                self.setCaptureStatus("移动未应用，长图仍保留：\(error.localizedDescription)", kind: .error)
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
                if !drag.wasPaused, !source.hasUnconfirmedTeardown, !self.updateCaptureLimit() {
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
                if !applied, !drag.wasPaused, !source.hasUnconfirmedTeardown, !self.updateCaptureLimit() {
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
                self.setCaptureStatus(applied ? "选区已移动，继续采集失败；长图仍保留" :
                    "移动未应用，原选区和长图保留：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func moveRegion() {
        guard chainTransaction == nil, chainChoiceID == nil, textChoiceID == nil, textAttemptID == nil, transition == nil, regionDrag == nil, !finishing, !retired, !deliveryCompleted,
              !captureLimitReached, !sourceTeardownUnconfirmed, !captureGeometryUnsupported, let source, let screen else { return }
        let wasPaused = paused
        let token = generation
        paused = true; clearAutomaticState()
        pauseCaptureClock(); snapshot.previewPositionVerified = false
        snapshot.busy = true; snapshot.status = "正在准备移动选区…"; controls?.update(snapshot: snapshot)
        transition = Task { [weak self] in
            guard let self else { return }
            defer { if !self.retired, self.generation == token { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) } }
            var applied = false
            do {
                try await source.pauseAndDrain(); await self.sampling?.value; self.sampling = nil
                try Task.checkCancellation()
                guard !self.retired, self.generation == token else { return }
                self.controls?.hide()
                let mover = ManualScrollRegionMover(); self.mover = mover
                let moved = try await mover.choose(screen: screen, region: source.region, movementAxis: wasPaused ? nil : self.axis)
                try Task.checkCancellation()
                guard !self.retired, self.generation == token else { return }
                try source.moveRegion(to: moved); applied = true
                self.region = source.region; self.mover = nil
                if !wasPaused, !source.hasUnconfirmedTeardown, !self.updateCaptureLimit() {
                    try await source.resume()
                    try Task.checkCancellation()
                    guard !self.retired, self.generation == token else { return }
                    self.paused = false; self.resumeCaptureClock()
                }
                if let target = source.target { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
                self.placeControls(); self.setStatus(self.captureLimitReached ? "已达到本次捕获上限，可完成保存已有长图" :
                    "选区已移动，滚动后继续验证接缝", kind: self.paused ? .paused : .capturing)
                if !self.paused { self.startSampling() }
            } catch {
                guard !self.retired, self.generation == token, !Task.isCancelled else { return }
                self.mover = nil; self.region = source.region
                if !wasPaused, !source.hasUnconfirmedTeardown, !self.updateCaptureLimit() {
                    do {
                        try await source.resume()
                        try Task.checkCancellation()
                        guard !self.retired, self.generation == token else { return }
                        self.paused = false; self.resumeCaptureClock()
                    } catch {
                        guard !self.retired, self.generation == token else { return }
                        self.paused = true
                    }
                }
                if let target = source.target { NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) }
                self.placeControls()
                self.setCaptureStatus(source.hasUnconfirmedTeardown ? error.localizedDescription :
                    (applied ? "选区已移动，继续采集失败；长图仍保留" : "移动未应用，已保留原选区和长图"),
                    kind: source.hasUnconfirmedTeardown ? .error : (self.paused ? .paused : .capturing))
                if !self.paused { self.startSampling() }
            }
        }
    }

    private func changeAxis(_ next: ScrollAxis) {
        guard chainTransaction == nil, chainChoiceID == nil, textChoiceID == nil, textAttemptID == nil, !retired, !deliveryCompleted, !captureLimitReached, !sourceTeardownUnconfirmed, regionDrag == nil, next != axis,
              lastState.width > 0, lastState.acceptedObservations <= 1, transition == nil, !finishing,
              let source, let original = assembler else { return }
        // Reject an impossible direction before draining, replacing the seed or
        // changing the user's current pause state. No resize or recapture occurs.
        if lastState.width > 0,
           !LiveScrollMatcher.supportsCapture(width: lastState.width, height: lastState.height, axis: next) {
            clearAutomaticState()
            setStatus("方向未改，选区过小", kind: .warning)
            snapshot.statusDetail = captureGeometryDetail(for: next)
            controls?.update(snapshot: snapshot)
            return
        }
        let token = generation
        let wasPaused = paused
        paused = true; clearAutomaticState()
        pauseCaptureClock(); snapshot.previewPositionVerified = false
        snapshot.busy = true; snapshot.status = "正在切换方向…"; controls?.update(snapshot: snapshot)
        transition = Task { [weak self] in
            guard let self else { return }
            defer { if !self.retired, self.generation == token { self.transition = nil; self.setStatus(self.snapshot.status, kind: self.snapshot.statusKind) } }
            var replacement: LiveScrollAssembler?
            do {
                try await source.pauseAndDrain(); await self.sampling?.value; self.sampling = nil
                try Task.checkCancellation()
                guard !self.retired, self.generation == token else { return }
                guard let first = await original.initialImageForAxisChange() else { throw CaptureError.busy }
                try Task.checkCancellation()
                guard !self.retired, self.generation == token else { return }
                // The actual retained seed is authoritative after drainage too.
                // Never replace or resume an assembler with an impossible axis.
                guard LiveScrollMatcher.supportsCapture(width: first.width, height: first.height, axis: next) else {
                    throw CaptureError.invalidRegion
                }
                let fresh = LiveScrollAssembler(axis: next, generation: self.generation, storageParent: self.resourceStorageParent); replacement = fresh
                let seed = try await fresh.observe(first)
                try Task.checkCancellation()
                if !wasPaused { try await source.resume() }
                try Task.checkCancellation()
                guard !self.retired, self.generation == token else { await fresh.close(); return }
                self.axis = next; self.assembler = fresh; replacement = nil
                await original.close()
                guard !self.retired, self.generation == token else { return }
                self.lastState = seed.state; self.snapshot.axis = next
                // The retained seed preserves pixels, not the resumed stream's
                // current position. Only a fresh accepted observation verifies it.
                self.snapshot.previewPositionVerified = false
                if let image = seed.preview { self.controls?.updatePreview(image: image, viewportFraction: seed.viewport) }
                self.paused = wasPaused
                if !wasPaused { self.resumeCaptureClock() }
                self.setStatus(wasPaused ? "方向已切换，仍暂停" : "方向已切换，继续滚动",
                    kind: wasPaused ? .paused : .capturing)
                if !wasPaused { self.startSampling() }
            } catch {
                await replacement?.close()
                guard !self.retired, self.generation == token else { return }
                self.setCaptureStatus("方向未切换，原长图仍保留：\(error.localizedDescription)", kind: .error)
            }
        }
    }
    private func openImporter() {
        guard chainTransaction == nil, chainChoiceID == nil, textChoiceID == nil, textAttemptID == nil, !retired, !finishing, transition == nil, !deliveryCompleted, lastState.width == 0 else { return }
        Task { [weak self] in guard let self else { return }; await self.retire(); self.onImport() }
    }
    func cancel() { requestRetirement() }

    private func requestRetirement() {
        guard retirement == nil, !retired else { return }
        retired = true; generation &+= 1; paused = true; clearAutomaticState()
        pauseCaptureClock(); regionDrag = nil
        let operation = transition
        operation?.cancel(); sampling?.cancel(); mover?.cancel()
        if let runID = chainAttemptID { chainDependencies?.cancel(runID) }
        if let runID = textAttemptID { textDependencies?.cancel(runID) }
        saveDestination?.cancel()
        // Invalidate and detach surfaces before observer callbacks can reenter.
        chainChoiceID = nil
        chainChoiceAlertForVerification?.cancel()
        chainChoiceAlertForVerification = nil
        textChoiceID = nil
        textChoiceAlertForVerification?.cancel()
        textChoiceAlertForVerification = nil
        controls?.teardown(); controls = nil
        retirement = Task { [self] in
            try? await source?.stop()
            await sampling?.value; sampling = nil
            // Includes preparation, runner terminal settlement, and owned Save
            // drainage. This separate task cannot be the captured operation.
            await operation?.value
            await assembler?.close(); assembler = nil; source = nil
            chainAttemptID = nil; chainTransaction = nil; chainTeardownWarning = nil
            textAttemptID = nil; pendingTextDefinition = nil; stagedTextCapture = nil
            transition = nil; retirement = nil
            let close = onClose; onClose = nil
            close?()
        }
    }

    private func retire() async {
        requestRetirement()
        await retirement?.value
    }
}
