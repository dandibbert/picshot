import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor
final class RecordingPanelController: NSWindowController, NSWindowDelegate {
    private let service: RecordingService
    private let previews = RecordingPreviewWindowStore()
    private var operationInFlight = false

    init(service: RecordingService, capture: CaptureService) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
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
        previews.open(url: url)
        // The recording controls float above normal windows while recording.
        // Hide them after saving so they do not obscure the new video preview.
        window?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard operationInFlight || service.isRecording || service.isStopping else { return true }
        let alert = NSAlert()
        alert.messageText = service.isRecording ? "录屏仍在进行" : "录屏正在准备或保存"
        alert.informativeText = "请先完成当前操作，并点击「停止并保存 MP4」，完成后再关闭窗口。"
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
    @State private var output: URL?
    @State private var lastSource: URL?
    @State private var working = false
    @State private var message = "录屏直接写入磁盘，最长 10 分钟 / 1 GB"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if service.isRecording || service.isStopping {
                HStack {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(service.isStopping ? "正在完成文件…" : "正在录制 · \(Int(service.elapsed)) 秒").monospacedDigit()
                }
                Text("回到此窗口停止录制。录屏内容不会上传。").foregroundStyle(.secondary)
                Button("停止并保存 MP4", action: stopRecording)
                    .buttonStyle(.borderedProminent).disabled(working || service.isStopping)
            } else {
                VStack(alignment: .leading, spacing: 14) {
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
                }.disabled(working)
                Button(working ? "正在准备…" : "开始录制", action: startRecording)
                    .buttonStyle(.borderedProminent).disabled(working || displays.isEmpty)
                if let output {
                    HStack {
                        Button("预览 / 裁剪 / GIF…") { onPreview(output) }
                        Button("显示文件") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    }.disabled(working)
                }
            }
            Divider()
            Text(service.error ?? message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("停止后打开预览：逐帧、变速、音量、选段导出 MP4 / GIF，原片保留")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("开发预览：暂不含录制暂停、摄像头画中画与录制中标注")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20).frame(width: 460, height: 360)
        .onChange(of: service.outputURL) { _, url in
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

    private func startRecording() {
        guard !working else { return }
        setWorking(true)
        Task {
            defer { setWorking(false) }
            do {
                let rectangle = region ? try await capture.selectRegion(displayID: selected) : nil
                try await service.start(displayID: selected, region: rectangle,
                    options: RecordingOptions(frameRate: frameRate, capturesSystemAudio: audio, capturesMicrophone: microphone))
            } catch { message = error.localizedDescription }
        }
    }

    private func stopRecording() {
        guard !working else { return }
        setWorking(true)
        Task {
            defer { setWorking(false) }
            do { acceptOutput(try await service.stop()) }
            catch { message = error.localizedDescription }
        }
    }

    private func setWorking(_ value: Bool) {
        working = value
        onWorkingChanged(value)
    }

    private func acceptOutput(_ source: URL) {
        // Manual stop and outputURL's automatic-stop publication can both report
        // the same movie. Open once, and keep an explicit button for reopening.
        guard lastSource != source else { return }
        lastSource = source
        output = source
        message = "MP4 已保存在电影/PicShot，已打开预览。导出不会修改原片。"
        onPreview(source)
    }
}
