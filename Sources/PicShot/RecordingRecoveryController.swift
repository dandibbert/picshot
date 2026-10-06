import AppKit
import SwiftUI
import PicShotCore

/// Keep one coordinator for the lifetime of the app. Launch discovery is read-
/// only; even when only one take exists, Recover/Open/Discard require a click.
@MainActor
final class RecordingRecoveryCoordinator {
    let store: RecordingRecoveryStore
    var onOpenPreview: ((URL) -> Void)?
    private(set) var controller: RecordingRecoveryController?
    private(set) var lastError: String?

    init(outputDirectory: URL? = nil) throws {
        store = try RecordingRecoveryStore(root: outputDirectory ?? RecordingFileStorage.outputDirectory())
    }
    func presentPending(showIfEmpty: Bool = false) {
        if let controller {
            controller.model.refresh()
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
        }
        do {
            let scan = try store.discover()
            guard showIfEmpty || !scan.candidates.isEmpty || !scan.warnings.isEmpty || scan.reachedLimit else { return }
            let model = RecordingRecoveryModel(store: store, scan: scan)
            model.onOpenPreview = { [weak self] url in self?.onOpenPreview?(url) }
            let controller = RecordingRecoveryController(model: model)
            controller.onClose = { [weak self] in self?.controller = nil }
            self.controller = controller
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } catch { lastError = error.localizedDescription }
    }
    /// Call only for an intentional user close, never application termination.
    /// Closing a recovered copy has no effect on its preserved original.
    func previewDidClose(url: URL) {
        do {
            let scan = try store.discover()
            for candidate in scan.candidates where candidate.isPreview && candidate.sourceURL == url {
                let lease = try store.open(candidate)
                defer { lease.closeLease() }
                try lease.dismissPreview()
            }
        } catch { lastError = error.localizedDescription }
    }
}

@MainActor
final class RecordingRecoveryModel: ObservableObject {
    let store: RecordingRecoveryStore
    @Published private(set) var candidates: [RecordingRecoveryCandidate]
    @Published private(set) var warnings: [String]
    @Published private(set) var reachedLimit: Bool
    @Published private(set) var busyID: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "选择要恢复的录屏。录制设备保持关闭。"
    @Published private(set) var error: String?
    var onOpenPreview: ((URL) -> Void)?
    private var task: Task<Void, Never>?
    private var closed = false
    private var needsRefresh = false

    init(store: RecordingRecoveryStore, scan: RecordingRecoveryScan) {
        self.store = store; candidates = scan.candidates; warnings = scan.warnings; reachedLimit = scan.reachedLimit
    }
    var isBusy: Bool { busyID != nil }
    func refresh() {
        guard !closed else { return }
        guard !isBusy else { needsRefresh = true; return }
        needsRefresh = false
        do {
            let scan = try store.discover()
            candidates = scan.candidates; warnings = scan.warnings; reachedLimit = scan.reachedLimit
        } catch { self.error = error.localizedDescription }
    }
    func recover(_ candidate: RecordingRecoveryCandidate) {
        guard !isBusy, !closed else { return }
        busyID = candidate.id; progress = 0; error = nil
        status = "正在恢复新副本，原始录屏会保留。"
        task = Task { [weak self, store] in
            do {
                let result = try await RecordingRecoveryEngine.recover(candidate, store: store) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, !self.closed, self.busyID == candidate.id else { return }
                        self.progress = progress
                    }
                }
                guard let self, !self.closed else { return }
                self.status = "已恢复 \(String(format: "%.1f", result.recoveredDuration)) 秒，原始录屏已保留。"
                if result.ignoredTailBytes > 0 { self.status += " 已略过未写完的末尾片段。" }
                self.error = result.journalWarning
                self.candidates.removeAll { $0.id == candidate.id }
                self.onOpenPreview?(result.url)
            } catch is CancellationError {
                guard let self, !self.closed else { return }
                self.status = "已取消恢复，原始录屏已保留。"
            } catch {
                guard let self, !self.closed else { return }
                self.error = error.localizedDescription; self.status = "原始录屏未被修改。"
            }
            guard let self else { return }
            self.busyID = nil; self.task = nil
            if self.needsRefresh { self.refresh() }
        }
    }
    func openPreview(_ candidate: RecordingRecoveryCandidate) {
        guard !isBusy, !closed, candidate.isPreview else { return }
        do {
            let lease = try store.open(candidate); defer { lease.closeLease() }
            try store.validateRootPath()
            onOpenPreview?(try lease.validatedSourceURL())
        } catch { self.error = error.localizedDescription }
    }
    func discardConfirmed(_ candidate: RecordingRecoveryCandidate) {
        guard !isBusy, !closed else { return }
        do {
            let lease = try store.open(candidate); defer { lease.closeLease() }
            try lease.discard(); candidates.removeAll { $0.id == candidate.id }
            status = "已忽略此恢复提示，原始文件仍保留在录屏文件夹中。"
        } catch { self.error = error.localizedDescription }
    }
    func cancel() { task?.cancel() }
    func close() { closed = true; task?.cancel(); onOpenPreview = nil }
    func reveal(_ candidate: RecordingRecoveryCandidate) {
        do {
            try store.validateRootPath()
            let lease = try store.open(candidate); defer { lease.closeLease() }
            NSWorkspace.shared.activateFileViewerSelecting([try lease.validatedSourceURL()])
        } catch { self.error = error.localizedDescription }
    }
    func revealFolder() {
        do { try store.validateRootPath(); NSWorkspace.shared.open(store.root) }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class RecordingRecoveryController: NSWindowController, NSWindowDelegate {
    let model: RecordingRecoveryModel
    var onClose: (() -> Void)?
    init(model: RecordingRecoveryModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "恢复录屏"
        window.minSize = NSSize(width: 660, height: 380)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: RecordingRecoveryView(model: model) { [weak self] candidate in
            self?.confirmDiscard(candidate)
        } keepForLater: { [weak self] in self?.close() })
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    private func confirmDiscard(_ candidate: RecordingRecoveryCandidate) {
        guard let window, !model.isBusy else { return }
        let alert = NSAlert()
        alert.messageText = "忽略这条录屏恢复提示？"
        alert.informativeText = "原始录屏及恢复记录会保留在录屏文件夹中。此操作只会移除恢复列表中的提示，不会永久删除录屏。"
        alert.addButton(withTitle: "稍后处理")
        alert.addButton(withTitle: "忽略提示")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.model.discardConfirmed(candidate) }
        }
    }
    func windowWillClose(_ notification: Notification) {
        model.close(); window?.contentView = nil; window?.delegate = nil
        let completion = onClose; onClose = nil; completion?()
    }
}

private struct RecordingRecoveryView: View {
    @ObservedObject var model: RecordingRecoveryModel
    let discard: (RecordingRecoveryCandidate) -> Void
    let keepForLater: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("中断的录屏").font(.title2.bold())
            Text("将完整保存的片段恢复为新的 MP4，未写完的末尾片段可能无法恢复。摄像头、麦克风和屏幕录制均保持关闭。")
                .font(.callout).foregroundStyle(.secondary)
            List(model.candidates) { candidate in
                VStack(alignment: .leading, spacing: 8) {
                    Text(candidate.journal.createdAt.formatted(date: .abbreviated, time: .standard)).font(.headline)
                    Text("\(candidate.isPreview ? "已保存的预览" : "中断的录屏") · \(ByteCountFormatter.string(fromByteCount: candidate.byteCount, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if candidate.isPreview { Button("打开预览") { model.openPreview(candidate) } }
                        Button("恢复副本") { model.recover(candidate) }
                        Button("显示文件") { model.reveal(candidate) }
                        Spacer()
                        Button("忽略…") { discard(candidate) }
                    }.disabled(model.isBusy)
                }.padding(.vertical, 5)
            }
            if model.candidates.isEmpty { Text("没有需要处理的录屏。").foregroundStyle(.secondary) }
            if model.reachedLimit { Text("The bounded scan limit was reached. Existing files were kept; use 显示文件 to inspect older recordings.").font(.caption) }
            if !model.warnings.isEmpty {
                Text("有 \(model.warnings.count) 个恢复文件夹无法安全打开，其中的文件均已保留。").font(.caption).foregroundStyle(.orange)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if model.isBusy { ProgressView(value: model.progress) }
            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开录屏文件夹") { model.revealFolder() }
                if model.isBusy { Button("取消恢复") { model.cancel() } }
                Button("稍后处理", action: keepForLater)
            }
        }.padding(20)
    }
}
