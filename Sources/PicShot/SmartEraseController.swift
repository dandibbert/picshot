import AppKit
import SwiftUI
import Security
import Darwin
import PicShotEraseCore
import PicShotFormulaCore

@MainActor
final class SmartEraseController: NSWindowController, NSWindowDelegate {
    private let model: SmartEraseEditorModel
    init(image: CGImage, onApply: @escaping (CGImage) -> Void) {
        model = SmartEraseEditorModel(image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "本机智能消除 · 涂抹物体"
        window.minSize = NSSize(width: 740, height: 580)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SmartEraseEditorView(model: model) { [weak self] image in
            onApply(image); self?.close()
        })
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}

@MainActor
final class SmartEraseEditorModel: ObservableObject {
    let image: CGImage
    @Published private(set) var strokes: [SmartEraseStroke] = []
    @Published private(set) var result: CGImage?
    @Published private(set) var working = false
    @Published private(set) var cancelling = false
    @Published private(set) var installed = false
    @Published private(set) var status = "涂抹要移除的物体，然后在本机生成修复预览。"
    @Published private(set) var progress: Double?
    @Published var brush: Double = 32
    @Published var showResult = false
    private var painting = false
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    init(image: CGImage) { self.image = image }

    func checkInstallation() {
        guard let manifest = SmartEraseModelPack.manifest else {
            status = "消除模型尚未完成下载与本机验证，暂未启用。可先涂抹预览；图片不会改变。"
            return
        }
        begin { model, id in
            do {
                _ = try await ModelPackService.shared.verifiedDirectory(for: manifest)
                guard model.requestID == id, !Task.isCancelled else { return }
                model.installed = true
                model.status = "模型已校验。涂抹物体后点击「智能消除」。"
            } catch {
                guard model.requestID == id, !Task.isCancelled else { return }
                model.installed = false
                model.status = "首次使用需下载可选 LaMa 模型。图片不会上传，之后可离线使用。"
            }
        }
    }

    func download() {
        guard let manifest = SmartEraseModelPack.manifest else { return }
        let alert = NSAlert()
        alert.messageText = "下载可选 LaMa 消除模型？"
        alert.informativeText = "来源：john-rocky/CoreML-Models 发布的 CoreMLaMa 转换版，原始模型为 Samsung Research / LaMa\n许可证：Apache-2.0\n大小：\(ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file))\n\n模型来自作者的 Google Drive，Google 因文件较大无法扫描模型权重；确认下载即允许继续获取这份作者发布的模型。每个文件会核对固定 SHA-256。图片与涂抹内容不会上传。模型仅在运行消除时加载，任务结束后退出辅助进程释放内存。\n\n权重 SHA-256：d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184"
        alert.addButton(withTitle: "下载并校验")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        begin { model, id in
            model.status = "正在下载并校验可选模型…"; model.progress = 0
            do {
                _ = try await ModelPackService.shared.install(manifest) { bytes, total in
                    Task { @MainActor [weak model] in
                        guard let model, model.requestID == id else { return }
                        model.progress = Double(bytes) / Double(total)
                    }
                }
                guard model.requestID == id, !Task.isCancelled else { return }
                model.installed = true
                model.status = "模型已下载并校验。请涂抹物体，再点击「智能消除」。"
            } catch { model.fail(error, id: id) }
        }
    }

    func paint(at point: CGPoint, in imageRect: CGRect) {
        guard !working, !showResult, imageRect.width > 0, imageRect.height > 0 else { return }
        if !painting {
            guard imageRect.contains(point), strokes.count < SmartEraseLimits.strokes else { return }
            strokes.append(SmartEraseStroke(points: [], width: brush)); painting = true
        }
        guard strokes.reduce(0, { $0 + $1.points.count }) < SmartEraseLimits.points else { return }
        let x = min(Double(image.width), max(0, Double((point.x - imageRect.minX) / imageRect.width) * Double(image.width)))
        let y = min(Double(image.height), max(0, Double((point.y - imageRect.minY) / imageRect.height) * Double(image.height)))
        let p = SmartErasePoint(x: x, y: y)
        if let previous = strokes.last?.points.last, hypot(previous.x - x, previous.y - y) < 0.5 { return }
        strokes[strokes.count - 1].points.append(p)
        result = nil
    }
    func endStroke() { painting = false }
    func undo() { guard !working, !strokes.isEmpty else { return }; painting = false; strokes.removeLast(); result = nil; showResult = false }
    func clear() { guard !working else { return }; painting = false; strokes.removeAll(); result = nil; showResult = false }

    func erase() {
        guard !strokes.isEmpty, let manifest = SmartEraseModelPack.manifest else { return }
        painting = false
        let strokes = self.strokes
        begin { model, id in
            model.status = "正在本机修复；较大的涂抹区域会缩放至模型的 800 × 800 上下文…"
            do {
                let directory = try await ModelPackService.shared.verifiedDirectory(for: manifest)
                let image = model.image
                let maskTask = Task.detached(priority: .userInitiated) {
                    try SmartEraseMask.rasterize(width: image.width, height: image.height, strokes: strokes)
                }
                let mask = try await withTaskCancellationHandler(operation: {
                    try await maskTask.value
                }, onCancel: { maskTask.cancel() })
                try Task.checkCancellation()
                let result = try await SmartEraseProcessService.shared.erase(image: image, mask: mask, modelDirectory: directory)
                guard model.requestID == id, !Task.isCancelled else { return }
                model.result = result; model.showResult = true
                model.status = "预览已完成。可切换原图检查，再点「应用」。涂抹外的像素保持原样。"
            } catch { model.fail(error, id: id) }
        }
    }
    private func begin(_ operation: @escaping @MainActor (SmartEraseEditorModel, UUID) async -> Void) {
        guard !working else { return }
        let id = UUID(); requestID = id; working = true; cancelling = false; progress = nil
        task = Task { [weak self] in
            guard let self else { return }
            await operation(self, id)
            guard self.requestID == id else { return }
            if Task.isCancelled { self.status = "已取消，辅助进程与临时文件已清理。" }
            self.working = false; self.cancelling = false; self.progress = nil; self.task = nil
        }
    }
    private func fail(_ error: Error, id: UUID) {
        guard requestID == id else { return }
        status = error is CancellationError ? "已取消。" : error.localizedDescription
    }
    func cancel() {
        guard working, !cancelling else { return }
        cancelling = true; task?.cancel(); progress = nil; painting = false
        status = "正在取消；等待辅助进程退出并清理临时图片…"
    }
}

@MainActor
private struct SmartEraseEditorView: View {
    @ObservedObject var model: SmartEraseEditorModel
    let apply: (CGImage) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("笔刷 \(Int(model.brush)) px").monospacedDigit().frame(width: 100, alignment: .leading)
                Slider(value: $model.brush, in: 2...256, step: 1).frame(maxWidth: 230)
                Button("撤销涂抹") { model.undo() }.disabled(model.strokes.isEmpty)
                Button("清空") { model.clear() }.disabled(model.strokes.isEmpty)
                Spacer()
                Picker("预览", selection: $model.showResult) {
                    Text("原图 / 涂抹").tag(false)
                    Text("修复结果").tag(true)
                }.pickerStyle(.segmented).frame(width: 210).disabled(model.result == nil)
            }.disabled(model.working)
            GeometryReader { geometry in
                let rect = imageRect(in: geometry.size)
                Canvas { context, _ in
                    context.clip(to: Path(rect))
                    let shown = model.showResult ? (model.result ?? model.image) : model.image
                    context.draw(Image(decorative: shown, scale: 1), in: rect)
                    if !model.showResult {
                        let scale = rect.width / CGFloat(model.image.width)
                        for stroke in model.strokes {
                            guard let first = stroke.points.first else { continue }
                            func point(_ p: SmartErasePoint) -> CGPoint { CGPoint(x: rect.minX + CGFloat(p.x) * scale, y: rect.minY + CGFloat(p.y) * scale) }
                            if stroke.points.count == 1 {
                                let p = point(first), radius = CGFloat(stroke.width) * scale / 2
                                context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)), with: .color(.pink.opacity(0.55)))
                            } else {
                                var path = Path(); path.move(to: point(first))
                                for p in stroke.points.dropFirst() { path.addLine(to: point(p)) }
                                context.stroke(path, with: .color(.pink.opacity(0.55)), style: StrokeStyle(lineWidth: CGFloat(stroke.width) * scale, lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { model.paint(at: $0.location, in: rect) }.onEnded { _ in model.endStroke() })
                .background(Color.black.opacity(0.07))
            }
            if let progress = model.progress { ProgressView(value: progress) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(minHeight: 30, alignment: .leading)
            HStack {
                if model.installed {
                    Button("智能消除") { model.erase() }.disabled(model.working || model.strokes.isEmpty)
                } else {
                    Button("下载可选模型…") { model.download() }.disabled(model.working || SmartEraseModelPack.manifest == nil)
                }
                if model.working { Button(model.cancelling ? "正在取消…" : "取消") { model.cancel() }.disabled(model.cancelling) }
                Spacer()
                Button("应用到编辑器") { if let result = model.result { apply(result) } }.disabled(model.result == nil || model.working)
            }
            HStack {
                Text("LaMa · 本机 Core ML · 可选下载 · 不上传图片").font(.system(size: 11))
                Link("模型来源", destination: SmartEraseModelPack.source).font(.system(size: 11))
                Link("Apache-2.0", destination: SmartEraseModelPack.license).font(.system(size: 11))
            }.foregroundStyle(.secondary)
            Text("修复会生成推测内容，复杂文字与纹理可能失真。保密信息请使用不透明遮挡。").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(16).onAppear { model.checkInstallation() }
    }
    private func imageRect(in size: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(model.image.width), size.height / CGFloat(model.image.height))
        let width = CGFloat(model.image.width) * scale, height = CGFloat(model.image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

actor SmartEraseProcessService {
    static let shared = SmartEraseProcessService()
    private var working = false
    func erase(image: CGImage, mask: Data, modelDirectory: URL) async throws -> CGImage {
        guard !working else { throw SmartEraseError.busy }
        working = true; defer { working = false }
        let control = SmartEraseProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try Self.run(image: image, mask: mask, directory: modelDirectory, control: control)
            }.value
        }, onCancel: { control.cancel() })
    }
    private nonisolated static func run(image: CGImage, mask: Data, directory: URL, control: SmartEraseProcessControl) throws -> CGImage {
        _ = try SmartEraseMask.crop(width: image.width, height: image.height, mask: mask)
        let executable = try verifiedHelper()
        let fm = FileManager.default
        let job = try SmartEraseTemporaryJob.create(in: fm.temporaryDirectory)
        defer { SmartEraseTemporaryJob.removeOwned(job) }
        let input = job.appendingPathComponent("input.png"), maskURL = job.appendingPathComponent("mask.bin")
        let output = job.appendingPathComponent("output.png"), errors = job.appendingPathComponent("error.txt")
        for (url, data) in [(input, try SmartEraseRaster.png(image)), (maskURL, mask), (errors, Data())] {
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteNoPermission) }
        }
        let errorHandle = try FileHandle(forUpdating: errors); defer { try? errorHandle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--input", input.path, "--mask", maskURL.path, "--output", output.path, "--model-dir", directory.path]
        process.currentDirectoryURL = job
        process.environment = ["HOME": job.path, "TMPDIR": job.path, "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errorHandle
        try control.start(process)
        let started = ProcessInfo.processInfo.systemUptime
        var failure: Error?
        while process.isRunning {
            if control.isCancelled { failure = CancellationError() }
            if ProcessInfo.processInfo.systemUptime - started > SmartEraseLimits.seconds { failure = SmartEraseError.timeout }
            var info = proc_taskinfo()
            let read = proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
            if read == Int32(MemoryLayout<proc_taskinfo>.size), info.pti_resident_size > SmartEraseLimits.residentBytes { failure = SmartEraseError.memory }
            if failure != nil { control.stop() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        if let failure { throw failure }
        if control.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            try errorHandle.seek(toOffset: 0)
            let data = try errorHandle.read(upToCount: 4_096) ?? Data()
            throw SmartEraseError.failed(String(data: data, encoding: .utf8) ?? "辅助进程异常退出。")
        }
        let result = try SmartEraseRaster.readImage(output)
        guard result.width == image.width, result.height == image.height else { throw SmartEraseError.invalidOutput }
        return result
    }
    private nonisolated static func verifiedHelper() throws -> URL {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app" else { throw SmartEraseError.unavailable }
        let helper = bundle.appendingPathComponent("Contents/Helpers/PicShotEraseHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SmartEraseError.unavailable }
        guard bundle.resolvingSymlinksInPath() == bundle, helper.resolvingSymlinksInPath() == helper else { throw SmartEraseError.signature }
        for url in [bundle, helper] {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw SmartEraseError.signature }
        }
        return helper
    }
}

private final class SmartEraseProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var stopTime: TimeInterval?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run(); self.process = process
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); stop() }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let process, process.isRunning else { return }
        if let time = stopTime {
            if ProcessInfo.processInfo.systemUptime - time > 1 { kill(process.processIdentifier, SIGKILL) }
        } else {
            stopTime = ProcessInfo.processInfo.systemUptime; process.terminate()
        }
    }
}
