import AppKit
import SwiftUI
import ScreenCaptureKit
import Combine

/// UI and exit decisions are independent of ScreenCaptureKit so they can be
/// exercised without creating streams or requesting OS permissions.
struct RecordingControlState: Equatable {
    var isRecording = false
    var isPaused = false
    var isStarting = false
    var isRestarting = false
    var isStopping = false
    var hasPendingTake = false
    var countdown: Int?
    var isWorking = false
    var isSelectingRegion = false

    var hasSessionActivity: Bool { isRecording || isStarting || isRestarting || isStopping || hasPendingTake || isSelectingRegion }
    var blocksClosing: Bool { hasSessionActivity || isWorking }
    var optionsDisabled: Bool { blocksClosing }
    var canStart: Bool { !blocksClosing }
    var canPauseOrStop: Bool { isRecording && !isStarting && !isRestarting && !isStopping && !hasPendingTake && !isWorking && !isSelectingRegion }
    // Cancellation is deliberately available while start/restart is awaiting
    // the countdown; the ordinary busy guard must not disable this escape hatch.
    var canCancelCountdown: Bool { isStarting && countdown != nil && !isRecording && !isStopping && !hasPendingTake }
    var terminationAction: RecordingTerminationAction {
        if hasPendingTake { return .preserve }
        if isSelectingRegion { return .cancelPreparation }
        if !hasSessionActivity { return .none }
        return canCancelCountdown ? .cancelCountdown : .save
    }
}

enum RecordingTerminationAction: Equatable {
    case none, cancelCountdown, save, preserve, cancelPreparation
}

/// A pending Quit must drain the cancelled restart/start generation before
/// AppKit gets its reply. Injected operations keep the exit paths testable.
@MainActor
enum RecordingTerminationCoordinator {
    static func finish(snapshot: () -> RecordingControlState,
                       cancelCountdown: () async -> Void,
                       save: () async throws -> Void,
                       preserve: () async throws -> Void = { throw RecordingError.pendingTake },
                       cancelPreparation: () async throws -> Void = { throw RecordingError.busy }) async throws {
        do {
            switch snapshot().terminationAction {
            case .none: return
            case .cancelCountdown: await cancelCountdown()
            case .save: try await save()
            case .preserve: try await preserve()
            case .cancelPreparation: try await cancelPreparation()
            }
        } catch is CancellationError {
            // Stop racing countdown cancellation has no movie to finalize.
            // Do not approve Quit until the operation actually settles below.
        }
        while snapshot().isSelectingRegion || snapshot().isStarting || snapshot().isRestarting || snapshot().isStopping {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !snapshot().hasPendingTake else { throw RecordingError.pendingTake }
        guard !snapshot().isRecording else { throw RecordingError.busy }
    }
}

@MainActor
extension RecordingService {
    var controlState: RecordingControlState {
        RecordingControlState(isRecording: isRecording, isPaused: isPaused,
            isStarting: isStarting, isRestarting: isRestarting, isStopping: isStopping,
            hasPendingTake: hasPendingTake, countdown: countdown)
    }
}

/// Publishing the saved first take during restart must not open a window over
/// the second take. Keep the original accessible, and only replay an interrupted
/// restart's suppressed preview once no capture target remains active.
struct RecordingPreviewRoutingPolicy {
    private(set) var output: URL?
    private(set) var previousTake: URL?
    private(set) var pendingPreview: URL?
    private(set) var lastPresented: URL?

    mutating func receive(_ source: URL, suppressPreview: Bool) -> URL? {
        output = source
        if suppressPreview {
            pendingPreview = source
            return nil
        }
        pendingPreview = nil
        return presentOnce(source)
    }

    mutating func finishRestart(previous: URL?, captureRemainsActive: Bool) -> URL? {
        if let previous { previousTake = previous }
        else if let pendingPreview { previousTake = pendingPreview }
        let pending = pendingPreview
        pendingPreview = nil
        guard !captureRemainsActive, let pending else { return nil }
        return presentOnce(pending)
    }

    private mutating func presentOnce(_ source: URL) -> URL? {
        guard lastPresented != source else { return nil }
        lastPresented = source
        return source
    }
}

@MainActor
protocol RecordingTransportPresenting: AnyObject {
    func show(snapshot: RecordingTransportSnapshot, anchor: CGRect, visibleFrame: CGRect)
    func update(snapshot: RecordingTransportSnapshot, actions: RecordingTransportActions?)
    func updatePlacement(anchor: CGRect, visibleFrame: CGRect, preservePosition: Bool)
    func hide()
    func teardown()
}

extension RecordingTransportController: RecordingTransportPresenting { }

@MainActor
final class RecordingPanelController: NSWindowController, NSWindowDelegate {
    enum Presentation { case expanded, compact, hidden }
    private let service: RecordingService
    private let previews: RecordingPreviewWindowStore
    let commands: RecordingCommandCoordinator
    private var transport: (any RecordingTransportPresenting)?
    private var displayObserver: AnyCancellable?
    private var pauseShortcut: String?
    private var stopShortcut: String?
    private let presentWindows: Bool
    private(set) var presentation: Presentation = .hidden
    private var retired = false

    init(service: RecordingService, capture: CaptureService, previews: RecordingPreviewWindowStore? = nil,
         previewLayoutObserver: (([String: CGRect]) -> Void)? = nil,
         commands: RecordingCommandCoordinator? = nil,
         transportFactory: ((RecordingTransportActions) -> any RecordingTransportPresenting)? = nil,
         presentWindows: Bool = true) {
        self.service = service
        self.previews = previews ?? RecordingPreviewWindowStore()
        self.commands = commands ?? RecordingCommandCoordinator(service: service)
        self.presentWindows = presentWindows
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 490),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "录屏"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.contentView = NSHostingView(rootView: RecordingPanel(
            service: service, capture: capture, commands: self.commands,
            onCollapse: { [weak self] in self?.collapseToTransport() },
            previewLayoutObserver: previewLayoutObserver))
        let actions = RecordingTransportActions(
            pauseResume: { [weak self] in self?.pauseResumeFromShortcut() },
            stopSave: { [weak self] in self?.stopAndSaveFromShortcut() },
            expand: { [weak self] in self?.expandControls() })
        transport = transportFactory?(actions) ?? RecordingTransportController(actions: actions)
        self.commands.onPreview = { [weak self] url in self?.showPreview(for: url) }
        self.commands.onChange = { [weak self] in self?.synchronizePresentation() }
        self.commands.onRecordingBegan = { [weak self] in self?.showTransportForNewTake() }
        displayObserver = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.updateTransportPlacement() }
        self.commands.startObserving()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    deinit {
        MainActor.assumeIsolated {
            displayObserver?.cancel()
            commands.teardown()
            transport?.teardown()
            window?.delegate = nil
            window?.orderOut(nil)
            window?.contentView = nil
        }
    }

    var controlState: RecordingControlState { commands.controlState }
    func pauseResumeFromShortcut() { commands.pauseResume() }
    func stopAndSaveFromShortcut() { commands.stopAndSave() }
    func saveForTermination() async throws { try await commands.saveForTermination() }
    func cancelCountdownForTermination() async { await commands.cancelCountdownForTermination() }
    func cancelStartForTermination() async throws { try await commands.cancelStartForTermination() }

    func setTransportShortcutLabels(pause: String?, stop: String?) {
        pauseShortcut = pause
        stopShortcut = stop
        synchronizePresentation()
    }

    override func showWindow(_ sender: Any?) { expandControls() }

    func expandControls() {
        guard !retired else { return }
        presentation = .expanded
        transport?.hide()
        if presentWindows {
            super.showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    private func showTransportForNewTake() {
        guard !retired, let placement = transportPlacement else { expandControls(); return }
        // A new capture target gets a new anchor; explicit expand/collapse within
        // that take continues to preserve the user's dragged position.
        transport?.updatePlacement(anchor: placement.anchor, visibleFrame: placement.visible, preservePosition: false)
        collapseToTransport()
    }

    func collapseToTransport() {
        guard !retired, commands.controlState.isRecording || commands.controlState.isStopping || commands.stopRequested else { return }
        guard let placement = transportPlacement else { expandControls(); return }
        presentation = .compact
        // Never call close(): windowWillClose ends the input-monitor session.
        window?.orderOut(nil)
        transport?.show(snapshot: transportSnapshot, anchor: placement.anchor, visibleFrame: placement.visible)
    }

    private var transportSnapshot: RecordingTransportSnapshot {
        let state = commands.controlState
        let saving = commands.stopRequested || state.isStopping
        let kind: RecordingTransportSnapshot.StatusKind = commands.failure != nil || state.hasPendingTake
            ? .error : (saving ? .saving : (state.isPaused ? .paused : .recording))
        return RecordingTransportSnapshot(paused: state.isPaused, busy: commands.working || state.isStarting || state.isRestarting || state.isStopping,
            canPause: commands.canPause, canStop: commands.canStop, elapsed: commands.elapsed,
            status: commands.failure ?? (state.hasPendingTake ? "等待安全保护" : (saving ? "正在保存…" : (state.isPaused ? "已暂停" : "录制中"))),
            statusKind: kind, pauseShortcut: pauseShortcut, stopShortcut: stopShortcut)
    }

    private var transportPlacement: (anchor: CGRect, visible: CGRect)? {
        let selected = commands.target.flatMap { target in
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.displayID
            }
        }
        // If a display disappeared, relocate only the controls so Stop remains
        // reachable. This never changes the recording's source rectangle.
        guard let screen = selected ?? window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let anchor: CGRect
        if selected != nil, let target = commands.target {
            anchor = target.appKitFrame(in: screen.frame)
        } else { anchor = screen.frame }
        return (anchor, screen.visibleFrame)
    }

    private func updateTransportPlacement() {
        guard !retired, let placement = transportPlacement else { return }
        transport?.updatePlacement(anchor: placement.anchor, visibleFrame: placement.visible, preservePosition: true)
    }

    private func synchronizePresentation() {
        guard !retired else { return }
        transport?.update(snapshot: transportSnapshot, actions: nil)
        if commands.controlState.hasPendingTake {
            // A protection failure always exposes the existing recovery action.
            expandControls()
        } else if !commands.controlState.hasSessionActivity && !commands.working && presentation == .compact {
            transport?.hide()
            presentation = .hidden
            if commands.failure != nil { expandControls() }
        }
    }

    private func showPreview(for url: URL) {
        // A queued publication must never cover a newly started/paused take.
        let state = commands.controlState
        guard !state.isRecording, !state.isStarting, !state.isRestarting else { return }
        // The real service is also checked when a synthetic command owner is injected.
        guard !service.isRecording, !service.isStarting, !service.isRestarting else { return }
        previews.open(url: url)
        presentation = .hidden
        transport?.hide()
        window?.orderOut(nil)
        if presentWindows { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowWillClose(_ notification: Notification) {
        service.inputMonitor.endSession()
        presentation = .hidden
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let state = commands.controlState
        guard state.blocksClosing else {
            service.inputMonitor.endSession()
            service.overlay.hide()
            Task { await service.camera.disable() }
            return true
        }
        let alert = NSAlert()
        if state.hasPendingTake {
            alert.messageText = "录屏尚未安全保留"
            alert.informativeText = "录制和摄像头已停止。请先点击「重试保护并恢复录屏」；在成功前请保持 PicShot 打开。"
        } else if state.canCancelCountdown {
            alert.messageText = "录屏倒计时仍在进行"
            alert.informativeText = "请先点击「取消倒计时」，再关闭窗口。已保存的原片会保留。"
        } else if state.isRecording {
            alert.messageText = state.isPaused ? "录屏已暂停，尚未保存" : "录屏仍在进行"
            alert.informativeText = "请先点击「停止并保存 MP4」，保存完成后再关闭窗口。"
        } else {
            alert.messageText = "录屏正在准备或保存"
            alert.informativeText = "请等待当前操作完成，再关闭窗口。已保存的原片会保留。"
        }
        alert.runModal()
        return false
    }

    /// Permanent presentation disposal, distinct from collapse and ordinary Close.
    /// It detaches callbacks/observers without cancelling an accepted save.
    func teardown() {
        guard !retired else { return }
        retired = true
        displayObserver?.cancel(); displayObserver = nil
        commands.teardown()
        transport?.teardown(); transport = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        presentation = .hidden
    }
}

/// The recording panel can be reopened, but closed previews are single-use.
/// Keep only visible/open controllers; a closed window never retains a player
/// through this store. Previews remain usable if the recording controls close.
@MainActor
final class RecordingPreviewWindowStore {
    private(set) var controllers: [URL: RecordingPreviewController] = [:]
    var onIntentionalClose: ((URL) -> Void)?
    private let presentWindows: Bool

    init(presentWindows: Bool = true) { self.presentWindows = presentWindows }

    @discardableResult
    func open(url: URL) -> RecordingPreviewController {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = controllers[key] {
            if !existing.model.closed {
                if presentWindows {
                    if existing.window?.isMiniaturized == true { existing.window?.deminiaturize(nil) }
                    existing.showWindow(nil)
                    existing.window?.makeKeyAndOrderFront(nil)
                }
                return existing
            }
            existing.close()
        }
        let preview = RecordingPreviewController(url: url)
        controllers[key] = preview
        preview.onClose = { [weak self, weak preview] in
            guard let self, let preview, self.controllers[key] === preview else { return }
            self.controllers.removeValue(forKey: key)
            self.onIntentionalClose?(key)
        }
        if presentWindows { preview.showWindow(nil); preview.window?.makeKeyAndOrderFront(nil) }
        return preview
    }

    func closeAll() {
        // close() synchronously invokes callbacks that remove dictionary entries.
        let openControllers = Array(controllers.values)
        for controller in openControllers { controller.close() }
        controllers.removeAll()
    }
}

@MainActor
struct RecordingPanel: View {
    @ObservedObject var service: RecordingService
    let capture: CaptureService
    @ObservedObject var commands: RecordingCommandCoordinator
    let onCollapse: () -> Void
    // Optional read-only geometry for the owned synthetic panel fixture. Normal
    // panels do not install geometry readers or change interaction behavior.
    var previewLayoutObserver: (([String: CGRect]) -> Void)? = nil
    @State private var displays: [SCDisplay] = []
    @State private var selected: CGDirectDisplayID = CGMainDisplayID()
    @State private var audio = false
    @State private var microphone = false
    @State private var region = false
    @State private var frameRate = 30
    @State private var delay = 0
    @State private var displayError: String?

    private var working: Bool { commands.working }
    private var controls: RecordingControlState { commands.controlState }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controls.hasSessionActivity {
                sessionControls
            } else {
                recordingOptions.background(previewSectionGeometry("options"))
                Button(working ? "正在准备…" : "开始录制", action: startRecording)
                    .buttonStyle(.borderedProminent).disabled(!controls.canStart || displays.isEmpty)
                    .background(previewSectionGeometry("start"))
                if let output = commands.routing.output {
                    HStack {
                        Button("预览 / 裁剪 / GIF…") { commands.showPreview(output) }
                        Button("显示文件") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    }.disabled(working)
                }
            }
            if let previous = commands.routing.previousTake {
                HStack {
                    Text("上一段已保留").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("预览上一段") { commands.showPreview(previous) }
                        .disabled(controls.blocksClosing)
                    Button("显示上一段文件") { NSWorkspace.shared.activateFileViewerSelecting([previous]) }
                        .disabled(working || service.isStarting || service.isRestarting || service.isStopping)
                }
                .help(previous.lastPathComponent)
            }
            Divider().background(previewSectionGeometry("divider"))
            RecordingEffectsControls(camera: service.camera, overlay: service.overlay,
                inputMonitor: service.inputMonitor, isRecording: service.isRecording)
                .disabled(service.isStarting || service.isRestarting || service.isStopping || service.hasPendingTake || working)
                .background(previewSectionGeometry("effects"))
            Text(commands.failure ?? displayError ?? commands.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .background(previewSectionGeometry("status"))
            Text("停止后打开预览：逐帧、变速、音量、选段导出 MP4 / GIF，原片保留")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .background(previewSectionGeometry("previewHint"))
            Text("摄像头需主动开启；标注 / 画中画写入视频。PicShot 窗口不录入。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .background(previewSectionGeometry("privacyHint"))
            Spacer(minLength: 0)
        }
        .padding(18).frame(width: 480, height: 490)
        .coordinateSpace(name: RecordingPanelSectionFrames.coordinateSpace)
        .onPreferenceChange(RecordingPanelSectionFrames.self) { frames in previewLayoutObserver?(frames) }
        .task {
            do {
                displays = try await service.availableDisplays()
                displayError = nil
                if !displays.contains(where: { $0.displayID == selected }) {
                    selected = displays.first?.displayID ?? CGMainDisplayID()
                }
            } catch is CancellationError { }
            catch { displayError = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func previewSectionGeometry(_ section: String) -> some View {
        if previewLayoutObserver != nil {
            GeometryReader { proxy in
                Color.clear.preference(key: RecordingPanelSectionFrames.self,
                    value: [section: proxy.frame(in: .named(RecordingPanelSectionFrames.coordinateSpace))])
            }
        }
    }

    private var recordingOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("显示器", selection: $selected) {
                ForEach(displays, id: \.displayID) { display in
                    Text("显示器 \(display.displayID) · \(display.width) × \(display.height)").tag(display.displayID)
                }
            }
            HStack {
                Toggle("选择区域", isOn: $region)
                Spacer()
                Picker("帧率", selection: $frameRate) {
                    ForEach([5, 16, 24, 30, 60], id: \.self) { Text("\($0) FPS").tag($0) }
                }.frame(width: 150)
            }
            HStack {
                Toggle("系统声音", isOn: $audio)
                Toggle("麦克风 (macOS 15+)", isOn: $microphone)
                    .disabled(!RecordingService.supportsMicrophone)
            }
            Stepper(delay == 0 ? "开始倒计时：无" : "开始倒计时：\(delay) 秒", value: $delay, in: 0...30)
        }.disabled(controls.optionsDisabled)
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(service.isPaused ? Color.orange : Color.red).frame(width: 10, height: 10)
                Text(commands.sessionStatus).monospacedDigit()
            }
            if service.hasPendingTake {
                Text("录制已停止。请腾出磁盘空间或恢复文件夹访问后重试；成功保护前无法开始另一段录屏。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(working ? "正在保护…" : "重试保护并恢复录屏", action: { commands.retryPreservation() })
                    .buttonStyle(.borderedProminent).disabled(working || service.isStopping)
            } else if controls.canCancelCountdown {
                Text("倒计时结束后开始录制；重录沿用上一段的区域和声音设置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(commands.cancellingCountdown ? "正在取消…" : "取消倒计时") { commands.cancelCountdown() }
                    .disabled(commands.cancellingCountdown)
            } else if service.isRecording {
                Text(service.isPaused ? "暂停期间的画面和声音不写入文件。" : "可用悬浮控制条暂停或停止。录屏内容不会上传。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button(service.isPaused ? "继续录制" : "暂停录制") { commands.pauseResume() }
                        .disabled(!commands.canPause)
                    Button("停止并保存 MP4") { commands.stopAndSave() }
                        .buttonStyle(.borderedProminent).disabled(!commands.canStop)
                    Button("收起控制", action: onCollapse)
                        .accessibilityIdentifier("recording-panel-collapse")
                }
                HStack {
                    Button("保存本段并重录") { commands.restart(discard: false, delay: TimeInterval(delay)) }
                    Button("丢弃本段并重录…", role: .destructive, action: confirmDiscardAndRestart)
                }.disabled(!controls.canPauseOrStop)
                Text(delay == 0 ? "重录沿用当前区域和声音设置，立即开始。" : "重录沿用当前设置，等待 \(delay) 秒后开始。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text("请等待当前操作完成。已保存的原片会保留。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func startRecording() {
        let displayID = selected
        let selectRegion = region
        let options = RecordingOptions(frameRate: frameRate, capturesSystemAudio: audio, capturesMicrophone: microphone)
        commands.start(displayID: displayID, options: options, delay: TimeInterval(delay)) {
            selectRegion ? try await capture.selectRegion(displayID: displayID) : nil
        }
    }

    private func confirmDiscardAndRestart() {
        guard controls.canPauseOrStop else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "丢弃当前未保存的录屏并重录？"
        alert.informativeText = "当前这一段会标记为丢弃，不再提示恢复；原始文件会安全保留。此前已经保存的 MP4 不会删除。"
        alert.addButton(withTitle: "保留本段")
        alert.addButton(withTitle: "丢弃本段并重录")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        // Modal alerts run the event loop: an automatic stop may have completed.
        guard controls.canPauseOrStop else { return }
        commands.restart(discard: true, delay: TimeInterval(delay))
    }


}


/// Named sections of the recording panel only; this is not an accessibility
/// substitute. The fixture separately hits and presses its actual NSButtons.
private struct RecordingPanelSectionFrames: PreferenceKey {
    static let coordinateSpace = "recording-panel-content"
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
