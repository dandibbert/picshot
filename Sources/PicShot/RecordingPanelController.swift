import AppKit
import SwiftUI
import ScreenCaptureKit

/// UI and exit decisions are independent of ScreenCaptureKit so they can be
/// exercised without creating streams or requesting OS permissions.
struct RecordingControlState: Equatable {
    var isRecording = false
    var isPaused = false
    var isStarting = false
    var isRestarting = false
    var isStopping = false
    var countdown: Int?
    var isWorking = false

    var hasSessionActivity: Bool { isRecording || isStarting || isRestarting || isStopping }
    var blocksClosing: Bool { hasSessionActivity || isWorking }
    var optionsDisabled: Bool { blocksClosing }
    var canStart: Bool { !blocksClosing }
    var canPauseOrStop: Bool { isRecording && !isStarting && !isRestarting && !isStopping && !isWorking }
    // Cancellation is deliberately available while start/restart is awaiting
    // the countdown; the ordinary busy guard must not disable this escape hatch.
    var canCancelCountdown: Bool { isStarting && countdown != nil && !isRecording && !isStopping }
    var terminationAction: RecordingTerminationAction {
        if !hasSessionActivity { return .none }
        return canCancelCountdown ? .cancelCountdown : .save
    }
}

enum RecordingTerminationAction: Equatable {
    case none, cancelCountdown, save
}

/// A pending Quit must drain the cancelled restart/start generation before
/// AppKit gets its reply. Injected operations keep the exit paths testable.
@MainActor
enum RecordingTerminationCoordinator {
    static func finish(snapshot: () -> RecordingControlState,
                       cancelCountdown: () async -> Void,
                       save: () async throws -> Void) async throws {
        do {
            switch snapshot().terminationAction {
            case .none: return
            case .cancelCountdown: await cancelCountdown()
            case .save: try await save()
            }
        } catch is CancellationError {
            // Stop racing countdown cancellation has no movie to finalize.
            // Do not approve Quit until the operation actually settles below.
        }
        while snapshot().isStarting || snapshot().isRestarting || snapshot().isStopping {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !snapshot().isRecording else { throw RecordingError.busy }
    }
}

@MainActor
extension RecordingService {
    var controlState: RecordingControlState {
        RecordingControlState(isRecording: isRecording, isPaused: isPaused,
            isStarting: isStarting, isRestarting: isRestarting, isStopping: isStopping,
            countdown: countdown)
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
final class RecordingPanelController: NSWindowController, NSWindowDelegate {
    private let service: RecordingService
    private let previews = RecordingPreviewWindowStore()
    private var operationInFlight = false

    init(service: RecordingService, capture: CaptureService) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "录屏"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.contentView = NSHostingView(rootView: RecordingPanel(
            service: service, capture: capture,
            onPreview: { [weak self] url in self?.showPreview(for: url) },
            onWorkingChanged: { [weak self] working in self?.operationInFlight = working }))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func showPreview(for url: URL) {
        // Also guard the actual window presentation: a queued callback must not
        // cover a newly started or paused recording with an older movie.
        guard !service.isRecording, !service.isStarting, !service.isRestarting else { return }
        previews.open(url: url)
        window?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        var state = service.controlState
        state.isWorking = operationInFlight
        guard state.blocksClosing else { return true }
        let alert = NSAlert()
        if state.canCancelCountdown {
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
}

/// The recording panel can be reopened, but closed previews are single-use.
/// Keep only visible/open controllers; a closed window never retains a player
/// through this store. Previews remain usable if the recording controls close.
@MainActor
final class RecordingPreviewWindowStore {
    private(set) var controllers: [URL: RecordingPreviewController] = [:]
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
    let onPreview: (URL) -> Void
    let onWorkingChanged: (Bool) -> Void
    @State private var displays: [SCDisplay] = []
    @State private var selected: CGDirectDisplayID = CGMainDisplayID()
    @State private var audio = false
    @State private var microphone = false
    @State private var region = false
    @State private var frameRate = 30
    @State private var delay = 0
    @State private var routing = RecordingPreviewRoutingPolicy()
    @State private var operationCount = 0
    @State private var restartInFlight = false
    @State private var cancellingCountdown = false
    @State private var message = "录屏直接写入磁盘，最长 10 分钟 / 1 GB"

    private var working: Bool { operationCount > 0 }
    private var controls: RecordingControlState {
        var state = service.controlState
        state.isWorking = working
        return state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controls.hasSessionActivity {
                sessionControls
            } else {
                recordingOptions
                Button(working ? "正在准备…" : "开始录制", action: startRecording)
                    .buttonStyle(.borderedProminent).disabled(!controls.canStart || displays.isEmpty)
                if let output = routing.output {
                    HStack {
                        Button("预览 / 裁剪 / GIF…") { onPreview(output) }
                        Button("显示文件") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    }.disabled(working)
                }
            }
            if let previous = routing.previousTake {
                HStack {
                    Text("上一段已保留").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("预览上一段") { onPreview(previous) }
                        .disabled(controls.blocksClosing)
                    Button("显示上一段文件") { NSWorkspace.shared.activateFileViewerSelecting([previous]) }
                        .disabled(working || service.isStarting || service.isRestarting || service.isStopping)
                }
                .help(previous.lastPathComponent)
            }
            Divider()
            Text(service.error ?? message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("停止后打开预览：逐帧、变速、音量、选段导出 MP4 / GIF，原片保留")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("开发预览：暂不含摄像头画中画与录制中标注")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(18).frame(width: 480, height: 430)
        // onChange can coalesce the old take's URL and the new start's nil.
        // Receive every publication so a failed restart still preserves its URL.
        .onReceive(service.$outputURL) { url in
            if let url { acceptOutput(url) }
        }
        .task {
            do {
                displays = try await service.availableDisplays()
                if !displays.contains(where: { $0.displayID == selected }) {
                    selected = displays.first?.displayID ?? CGMainDisplayID()
                }
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
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
                Text(sessionStatus).monospacedDigit()
            }
            if controls.canCancelCountdown {
                Text("倒计时结束后开始录制；重录沿用上一段的区域和声音设置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(cancellingCountdown ? "正在取消…" : "取消倒计时", action: cancelCountdown)
                    .disabled(cancellingCountdown)
            } else if service.isRecording {
                Text(service.isPaused ? "暂停期间的画面和声音不写入文件。" : "回到此窗口暂停或停止。录屏内容不会上传。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button(service.isPaused ? "继续录制" : "暂停录制", action: togglePause)
                    Button("停止并保存 MP4", action: stopRecording).buttonStyle(.borderedProminent)
                }.disabled(!controls.canPauseOrStop)
                HStack {
                    Button("保存本段并重录") { restartRecording(discard: false) }
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

    private var sessionStatus: String {
        if cancellingCountdown { return "正在取消倒计时…" }
        if let remaining = service.countdown { return "\(remaining) 秒后开始录制" }
        if service.isStopping { return "正在保存 MP4…" }
        if service.isRestarting { return "正在准备重新录制…" }
        if service.isStarting { return "正在准备录制…" }
        return "\(service.isPaused ? "已暂停" : "正在录制") · \(Int(service.elapsed)) 秒"
    }

    private func startRecording() {
        guard controls.canStart else { return }
        let displayID = selected
        let selectRegion = region
        let options = RecordingOptions(frameRate: frameRate, capturesSystemAudio: audio, capturesMicrophone: microphone)
        let startDelay = TimeInterval(delay)
        beginOperation()
        Task {
            defer { endOperation() }
            do {
                let rectangle = selectRegion ? try await capture.selectRegion(displayID: displayID) : nil
                try await service.start(displayID: displayID, region: rectangle, options: options, delay: startDelay)
                message = "录制中；暂停不计入视频时长，停止后保存原片。"
            } catch is CancellationError { message = "已取消开始录制。已保存的原片会保留。" }
            catch CaptureError.cancelled { message = "已取消选择录屏区域。" }
            catch { message = error.localizedDescription }
        }
    }

    private func stopRecording() {
        guard controls.canPauseOrStop else { return }
        beginOperation()
        Task {
            defer { endOperation() }
            do { acceptOutput(try await service.stop()) }
            catch is CancellationError { message = "录屏操作已取消。已保存的原片会保留。" }
            catch { message = error.localizedDescription }
        }
    }

    private func togglePause() {
        guard controls.canPauseOrStop else { return }
        let shouldResume = service.isPaused
        beginOperation()
        Task {
            defer { endOperation() }
            do {
                if shouldResume { try await service.resume() }
                else { try await service.pause() }
            } catch { message = error.localizedDescription }
        }
    }

    private func cancelCountdown() {
        guard controls.canCancelCountdown, !cancellingCountdown else { return }
        cancellingCountdown = true
        beginOperation()
        Task {
            defer { cancellingCountdown = false; endOperation() }
            guard service.controlState.canCancelCountdown else {
                message = "倒计时已结束；请点击「停止并保存 MP4」保存当前录屏。"
                return
            }
            await service.cancel()
            message = "已取消倒计时。已保存的原片会保留。"
        }
    }

    private func confirmDiscardAndRestart() {
        guard controls.canPauseOrStop else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "丢弃当前未保存的录屏并重录？"
        alert.informativeText = "当前这一段将无法恢复。此前已经保存的 MP4 不会删除。"
        alert.addButton(withTitle: "保留本段")
        alert.addButton(withTitle: "丢弃本段并重录")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        // Modal alerts run the event loop: an automatic stop may have completed.
        guard controls.canPauseOrStop else { return }
        restartRecording(discard: true)
    }

    private func restartRecording(discard: Bool) {
        guard controls.canPauseOrStop else { return }
        restartInFlight = true
        beginOperation()
        Task {
            var previous: URL?
            defer {
                restartInFlight = false
                endOperation()
                if let preview = routing.finishRestart(previous: previous,
                    captureRemainsActive: service.controlState.hasSessionActivity) {
                    onPreview(preview)
                }
            }
            do {
                previous = try await service.restart(discardUnfinished: discard, delay: TimeInterval(delay))
                message = previous == nil ? "已开始重新录制。" : "上一段已保存；新一段正在录制。"
            } catch is CancellationError { message = "已取消重录。已保存的原片会保留。" }
            catch { message = error.localizedDescription }
        }
    }

    private func beginOperation() {
        operationCount += 1
        onWorkingChanged(true)
    }

    private func endOperation() {
        operationCount = max(0, operationCount - 1)
        onWorkingChanged(working)
    }

    private func acceptOutput(_ source: URL) {
        let suppress = restartInFlight || service.isRestarting || service.isStarting || service.isRecording
        if let preview = routing.receive(source, suppressPreview: suppress) {
            message = "MP4 已保存在电影/PicShot，已打开预览。导出不会修改原片。"
            onPreview(preview)
        }
    }
}
