import AppKit
import Combine

/// The transport, expanded panel and keyboard route all use this same boundary.
/// Tests inject this service without streams, global input or permission prompts.
@MainActor
protocol RecordingCommandService: AnyObject {
    var controlState: RecordingControlState { get }
    var elapsed: TimeInterval { get }
    var error: String? { get }
    var commandChanges: AnyPublisher<Void, Never> { get }
    var commandOutput: AnyPublisher<URL?, Never> { get }
    func start(displayID: CGDirectDisplayID, region: CGRect?, options: RecordingOptions, delay: TimeInterval) async throws
    func pause() async throws
    func resume() async throws
    func closeInputAdmissionForStop()
    func stop() async throws -> URL
    func restart(discardUnfinished: Bool, delay: TimeInterval) async throws -> URL?
    func cancel() async
    func retryPendingTakePreservation(presentRecovery: Bool) async throws
}

extension RecordingService: RecordingCommandService {
    var commandChanges: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
    var commandOutput: AnyPublisher<URL?, Never> { $outputURL.eraseToAnyPublisher() }
    func closeInputAdmissionForStop() { inputMonitor.endSession() }
}

struct RecordingCommandTarget: Equatable {
    let displayID: CGDirectDisplayID
    /// Display-local, top-left coordinates, just like RecordingService.start.
    let region: CGRect?

    func appKitFrame(in displayFrame: CGRect) -> CGRect {
        guard let region else { return displayFrame }
        return CGRect(x: displayFrame.minX + region.minX, y: displayFrame.maxY - region.maxY,
                      width: region.width, height: region.height)
    }
}

@MainActor
final class RecordingCommandCoordinator: ObservableObject {
    @Published private(set) var state = RecordingControlState()
    @Published private(set) var routing = RecordingPreviewRoutingPolicy()
    @Published private(set) var message = "录屏直接写入磁盘，最长 10 分钟 / 1 GB"
    @Published private(set) var cancellingCountdown = false
    @Published private(set) var stopRequested = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var failure: String?
    private(set) var target: RecordingCommandTarget?
    private(set) var lastSaveResult: Result<URL, Error>?
    var onPreview: ((URL) -> Void)?
    var onRecordingBegan: (() -> Void)?
    var onChange: (() -> Void)?

    private enum Operation { case starting, restarting, preserving }
    private let service: any RecordingCommandService
    private var operation: Operation?
    private var isSelectingRegion = false
    private var startTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var stopTask: Task<URL, Error>?
    private var cancellationTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var observing = false
    private var retired = false
    private var commandFailure: String?

    init(service: any RecordingCommandService) {
        self.service = service
        refresh()
    }

    var controlState: RecordingControlState {
        var current = service.controlState
        current.isWorking = working
        current.isSelectingRegion = isSelectingRegion
        return current
    }
    var working: Bool { operation != nil || pauseTask != nil || stopRequested || cancellingCountdown }
    var canPause: Bool { !retired && controlState.canPauseOrStop }
    /// A Pause already admitted may finish, but never prevents accepting Stop.
    /// A duplicate Stop joins the existing save rather than enqueueing another.
    var canStop: Bool {
        guard !retired, operation == nil, !cancellingCountdown, !service.controlState.hasPendingTake else { return false }
        let current = service.controlState
        return stopTask != nil || stopRequested || (!current.isStarting && !current.isRestarting && (current.isRecording || current.isStopping))
    }
    var sessionStatus: String {
        if state.hasPendingTake { return "录屏等待安全保护" }
        if cancellingCountdown { return "正在取消倒计时…" }
        if let remaining = state.countdown { return "\(remaining) 秒后开始录制" }
        if stopRequested || state.isStopping { return "正在保存 MP4…" }
        if state.isRestarting { return "正在准备重新录制…" }
        if state.isStarting { return "正在准备录制…" }
        return "\(state.isPaused ? "已暂停" : "正在录制") · \(Int(elapsed)) 秒"
    }

    /// Install only after presentation callbacks exist. These two subscriptions
    /// are bounded for the controller's lifetime, independent of view visibility.
    func startObserving() {
        guard !observing, !retired else { return }
        observing = true
        service.commandChanges.sink { [weak self] in self?.scheduleRefresh() }.store(in: &subscriptions)
        service.commandOutput.sink { [weak self] url in
            if let url { self?.acceptOutput(url) }
        }.store(in: &subscriptions)
        refresh()
    }

    private func scheduleRefresh() {
        guard refreshTask == nil, !retired else { return }
        // ObservableObject changes arrive before their property assignment. One
        // coalesced main-actor turn reads the completed service transition.
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    func refresh() {
        guard !retired else { return }
        let current = controlState
        state = current
        elapsed = service.elapsed
        failure = service.error ?? commandFailure
        onChange?()
    }

    @discardableResult
    func start(displayID: CGDirectDisplayID, options: RecordingOptions, delay: TimeInterval,
               selectRegion: @escaping @MainActor () async throws -> CGRect?) -> Task<Void, Never>? {
        guard !retired, controlState.canStart else { return nil }
        operation = .starting
        isSelectingRegion = true
        commandFailure = nil
        let task = Task { @MainActor in
            defer { startTask = nil; isSelectingRegion = false; operation = nil; refresh() }
            do {
                try Task.checkCancellation()
                let rectangle = try await selectRegion()
                // A selector may complete successfully while its cancellation
                // callback is still queued. Never cross into capture after Quit.
                try Task.checkCancellation()
                isSelectingRegion = false
                target = RecordingCommandTarget(displayID: displayID, region: rectangle)
                refresh()
                try await service.start(displayID: displayID, region: rectangle, options: options, delay: delay)
                message = "录制中；暂停不计入视频时长，停止后保存原片。"
                if service.controlState.isRecording { onRecordingBegan?() }
            } catch is CancellationError { message = "已取消开始录制。已保存的原片会保留。" }
            catch CaptureError.cancelled { message = "已取消选择录屏区域。" }
            catch { recordFailure(error) }
        }
        startTask = task
        refresh()
        return task
    }

    /// Cancellation is safe only while no recording service operation has been
    /// entered. Awaiting the task also drains the selector's window teardown.
    func cancelStartForTermination() async throws {
        if isSelectingRegion, let startTask {
            startTask.cancel()
            await startTask.value
            return
        }
        // Selection may have finished while the Quit confirmation was open.
        // Re-read the service phase instead of cancelling an accepted take.
        try await RecordingTerminationCoordinator.finish(snapshot: { controlState },
            cancelCountdown: { await cancelCountdownForTermination() },
            save: { try await saveForTermination() })
    }

    @discardableResult
    func pauseResume() -> Task<Void, Never>? {
        guard canPause else { return nil }
        let resume = service.controlState.isPaused
        commandFailure = nil
        let task = Task { @MainActor in
            defer { pauseTask = nil; refresh() }
            // Stop can arrive before this queued Pause gets its actor turn.
            guard !stopRequested else { return }
            do {
                if resume { try await service.resume() } else { try await service.pause() }
            } catch { recordFailure(error) }
        }
        pauseTask = task
        refresh()
        return task
    }

    @discardableResult
    func stopAndSave() -> Task<URL, Error>? {
        if let stopTask { return stopTask }
        guard canStop else { return nil }
        return beginStop()
    }

    private func beginStop() -> Task<URL, Error> {
        if let stopTask { return stopTask }
        stopRequested = true
        // Close admission before waiting for a writer transition. Ending the
        // monitor session also prevents a late Resume from reinstalling it.
        service.closeInputAdmissionForStop()
        commandFailure = nil
        let pendingPause = pauseTask
        let task = Task { @MainActor () throws -> URL in
            defer { stopTask = nil; stopRequested = false; refresh() }
            // Never cancel a writer transition halfway through. The latch above
            // blocks new Pause commands, and the accepted transition drains first.
            await pendingPause?.value
            do {
                let url = try await service.stop()
                lastSaveResult = .success(url)
                acceptOutput(url)
                return url
            } catch {
                lastSaveResult = .failure(error)
                if error is CancellationError { message = "录屏操作已取消。已保存的原片会保留。" }
                else { recordFailure(error) }
                throw error
            }
        }
        stopTask = task
        refresh()
        return task
    }

    /// Quit has its own confirmation and may need to stop a starting/restarting
    /// session. It still drains this owner's Pause and joins its existing save.
    func saveForTermination() async throws {
        if isSelectingRegion { try await cancelStartForTermination(); return }
        _ = try await beginStop().value
    }

    @discardableResult
    func retryPreservation() -> Task<Void, Never>? {
        guard !retired, service.controlState.hasPendingTake, !working else { return nil }
        operation = .preserving
        commandFailure = nil
        refresh()
        return Task { @MainActor in
            defer { operation = nil; refresh() }
            do {
                try await service.retryPendingTakePreservation(presentRecovery: true)
                message = "原始录屏已安全保留，可在恢复窗口中尝试另存可播放片段。"
            } catch { recordFailure(error) }
        }
    }

    @discardableResult
    func cancelCountdown() -> Task<Void, Never>? {
        if let cancellationTask { return cancellationTask }
        guard !retired, service.controlState.canCancelCountdown else { return nil }
        cancellingCountdown = true
        let task = Task { @MainActor in
            defer { cancellationTask = nil; cancellingCountdown = false; refresh() }
            guard service.controlState.canCancelCountdown else {
                message = "倒计时已结束；请点击「停止并保存 MP4」保存当前录屏。"
                return
            }
            await service.cancel()
            message = "已取消倒计时。已保存的原片会保留。"
        }
        cancellationTask = task
        refresh()
        return task
    }

    func cancelCountdownForTermination() async {
        if let task = cancelCountdown() { await task.value }
        // The caller rechecks the service after an ended countdown; it must not
        // approve Quit if capture became active before cancellation was admitted.
    }

    @discardableResult
    func restart(discard: Bool, delay: TimeInterval) -> Task<Void, Never>? {
        guard canPause else { return nil }
        operation = .restarting
        commandFailure = nil
        refresh()
        return Task { @MainActor in
            var previous: URL?
            defer {
                operation = nil
                if let preview = routing.finishRestart(previous: previous,
                    captureRemainsActive: service.controlState.hasSessionActivity) {
                    present(preview)
                }
                refresh()
            }
            do {
                previous = try await service.restart(discardUnfinished: discard, delay: delay)
                message = previous == nil ? "已开始重新录制。" : "上一段已保存；新一段正在录制。"
                if service.controlState.isRecording { onRecordingBegan?() }
            } catch is CancellationError { message = "已取消重录。已保存的原片会保留。" }
            catch { recordFailure(error) }
        }
    }

    func showPreview(_ url: URL) {
        guard !retired, !service.controlState.blocksClosing, !working else { return }
        onPreview?(url)
    }

    private func acceptOutput(_ source: URL) {
        guard !retired else { return }
        let current = service.controlState
        let suppress = operation == .restarting || current.isRestarting || current.isStarting || current.isRecording
        if let preview = routing.receive(source, suppressPreview: suppress) { present(preview) }
    }

    private func present(_ source: URL) {
        let current = service.controlState
        guard !retired, !current.isRecording, !current.isStarting, !current.isRestarting else { return }
        message = "MP4 已保存在电影/PicShot，已打开预览。导出不会修改原片。"
        onPreview?(source)
    }

    private func recordFailure(_ error: Error) {
        commandFailure = error.localizedDescription
        message = error.localizedDescription
    }

    func teardown() {
        guard !retired else { return }
        retired = true
        if isSelectingRegion { startTask?.cancel() }
        refreshTask?.cancel(); refreshTask = nil
        subscriptions.removeAll()
        observing = false
        onChange = nil; onPreview = nil; onRecordingBegan = nil
        // Already accepted commands retain their owner until they settle. UI
        // teardown must never cancel a durable save or discard accepted media.
    }
}
