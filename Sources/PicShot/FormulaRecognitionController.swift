import AppKit
import SwiftUI
import Security
import Darwin
import PicShotFormulaCore
import PicShotTableEngine

@MainActor
final class FormulaRecognitionController: NSWindowController, NSWindowDelegate {
    private let model: FormulaRecognitionModel
    init(image: CGImage) {
        model = FormulaRecognitionModel(image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "本机公式识别 · LaTeX"
        window.minSize = NSSize(width: 600, height: 430)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: FormulaRecognitionView(model: model))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}

@MainActor
final class FormulaRecognitionModel: ObservableObject {
    @Published private(set) var working = false
    @Published private(set) var installed = false
    @Published private(set) var status = "正在检查可选模型包…"
    @Published private(set) var progress: Double?
    @Published var latex = ""
    let image: CGImage
    private var task: Task<Void, Never>?
    private var currentID: UUID?
    init(image: CGImage) { self.image = image }

    func checkInstallation() {
        begin { model, id in
            do {
                _ = try await ModelPackService.shared.verifiedDirectory(for: .formula)
                guard model.currentID == id else { return }
                model.installed = true
                model.status = "模型已校验。点击「识别公式」在本机生成 LaTeX。"
            } catch {
                guard model.currentID == id else { return }
                model.installed = false
                model.status = "需先下载可选公式模型包（约 120 MB）。下载只获取模型，不发送图片。"
            }
        }
    }

    func download() {
        let alert = NSAlert()
        alert.messageText = "下载可选公式模型？"
        alert.informativeText = "来源：Hugging Face / breezedeus（Pix2Text-MFR-1.5）\n大小：\(ByteCountFormatter.string(fromByteCount: ModelPackManifest.formula.totalBytes, countStyle: .file))\n许可证：作者发布为 MIT\n\n模型文件将保存在本机，并逐个校验 SHA-256。下载需要联网；图片及识别结果不会上传。下载后可离线识别。"
        alert.addButton(withTitle: "下载模型")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        begin { model, id in
            model.status = "正在下载并校验可选模型…"
            model.progress = 0
            do {
                _ = try await ModelPackService.shared.install(.formula) { received, total in
                    Task { @MainActor [weak model] in
                        guard let model, model.currentID == id else { return }
                        model.progress = Double(received) / Double(total)
                    }
                }
                guard model.currentID == id else { return }
                model.installed = true
                model.status = "下载完成并通过校验。点击「识别公式」。"
            } catch { model.fail(error, id: id) }
        }
    }

    func recognize() {
        begin { model, id in
            model.latex = ""
            model.status = "正在本机识别；辅助进程完成后会退出…"
            do {
                let directory = try await ModelPackService.shared.verifiedDirectory(for: .formula)
                let result = try await MLHelperService.shared.formula(image: model.image, modelDirectory: directory)
                guard model.currentID == id else { return }
                model.latex = result.latex
                model.status = result.warnings.joined(separator: " ")
            } catch { model.fail(error, id: id) }
        }
    }

    private func begin(_ operation: @escaping @MainActor (FormulaRecognitionModel, UUID) async -> Void) {
        guard !working else { return }
        let id = UUID(); currentID = id; working = true; progress = nil
        task = Task { [weak self] in
            guard let self else { return }
            await operation(self, id)
            guard self.currentID == id else { return }
            self.working = false; self.progress = nil; self.task = nil
        }
    }
    private func fail(_ error: Error, id: UUID) {
        guard currentID == id else { return }
        status = error is CancellationError ? "已取消。" : error.localizedDescription
    }
    func cancel() {
        currentID = nil; task?.cancel(); task = nil
        working = false; progress = nil; status = "已取消，临时图片将在辅助进程退出后清理。"
    }
    func copy() {
        guard !latex.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(latex, forType: .string)
    }
    func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "公式.tex"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try latex.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }
}

@MainActor
private struct FormulaRecognitionView: View {
    @ObservedObject var model: FormulaRecognitionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(decorative: model.image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 120).background(Color.white)
            Text("LaTeX · 可编辑，复制前请核对").font(.caption)
            TextEditor(text: $model.latex).font(.system(size: 15, design: .monospaced))
                .border(Color.secondary.opacity(0.3)).disabled(model.working)
            if let progress = model.progress { ProgressView(value: progress) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if model.installed {
                    Button("识别公式") { model.recognize() }.disabled(model.working)
                } else {
                    Button("下载可选模型…") { model.download() }.disabled(model.working)
                }
                if model.working { Button("取消") { model.cancel() } }
                Spacer()
                Button("复制 LaTeX") { model.copy() }.disabled(model.latex.isEmpty || model.working)
                Button("导出 .tex…") { model.save() }.disabled(model.latex.isEmpty || model.working)
            }
            HStack {
                Text("约 120 MB · MIT · 单公式识别 · 本机运行，无图片上传").font(.system(size: 11))
                Link("模型来源与许可证", destination: ModelPackManifest.formula.source).font(.system(size: 11))
            }.foregroundStyle(.secondary)
        }.padding(16).onAppear { model.checkInstallation() }
    }
}

enum MLHelperError: LocalizedError {
    case busy, unavailable, signature, failed(String), memoryLimit
    var errorDescription: String? {
        switch self {
        case .busy: return "已有模型识别正在运行，请稍后再试。"
        case .unavailable: return "此安装包缺少原生识别辅助程序。请安装完整 PicShot 应用。"
        case .signature: return "识别辅助程序的签名或路径无效，已阻止启动。请重新安装可信安装包。"
        case .failed(let detail): return "识别失败：\(detail)"
        case .memoryLimit: return "识别进程超出 1 GiB 内存限制，已停止。请缩小截图范围。"
        }
    }
}

/// One process/job globally, shared by formula and (when enabled) table engines.
actor MLHelperService {
    static let shared = MLHelperService()
    private var working = false

    func formula(image: CGImage, modelDirectory: URL) async throws -> FormulaRecognitionResult {
        let data = try await run(mode: "formula", image: image, modelDirectory: modelDirectory)
        let result = try JSONDecoder().decode(FormulaRecognitionResult.self, from: data)
        guard !result.latex.isEmpty, result.latex.utf8.count <= MLJobLimits.formulaTextBytes,
              result.tokenCount >= 0, result.tokenCount <= MLJobLimits.formulaTokens,
              result.modelID == ModelPackManifest.formula.id else { throw FormulaError.invalidTensor }
        return result
    }

    func table(image: CGImage, modelDirectory: URL) async throws -> TableRecognitionResult {
        let data = try await run(mode: "table", image: image, modelDirectory: modelDirectory)
        return try JSONDecoder().decode(TableRecognitionResult.self, from: data)
    }

    func run(mode: String, image: CGImage, modelDirectory: URL) async throws -> Data {
        guard !working else { throw MLHelperError.busy }
        guard ["formula", "table"].contains(mode) else { throw FormulaError.invalidInput }
        working = true
        defer { working = false }
        let control = MLProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try Self.runSynchronously(mode: mode, image: image, modelDirectory: modelDirectory, control: control)
            }.value
        }, onCancel: { control.cancel() })
    }

    private nonisolated static func runSynchronously(mode: String, image: CGImage, modelDirectory: URL, control: MLProcessControl) throws -> Data {
        guard image.width <= MLJobLimits.inputDimension, image.height <= MLJobLimits.inputDimension,
              image.width * image.height <= MLJobLimits.inputPixels else { throw FormulaError.invalidInput }
        let executable = try verifiedHelper()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("picshot-ml-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.png")
        let output = folder.appendingPathComponent("output.json")
        let errors = folder.appendingPathComponent("error.txt")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              png.count <= MLJobLimits.inputBytes else { throw FormulaError.invalidInput }
        guard fm.createFile(atPath: input.path, contents: png, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteNoPermission) }
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--mode", mode, "--model-dir", modelDirectory.path, "--input", input.path, "--output", output.path]
        process.currentDirectoryURL = folder
        // Do not inherit DYLD injection, Python paths, proxy credentials, tokens,
        // or other ambient shell configuration into the model process.
        process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": folder.path, "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        try control.start(process)
        let started = Date()
        var failure: Error?
        while process.isRunning {
            if control.isCancelled { failure = CancellationError(); control.stop() }
            if Date().timeIntervalSince(started) > MLJobLimits.seconds { failure = FormulaError.timeLimit; control.stop() }
            if residentBytes(process.processIdentifier) > 1_073_741_824 { failure = MLHelperError.memoryLimit; control.stop() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        if let failure { throw failure }
        if control.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let data = (try? Data(contentsOf: errors)) ?? Data()
            throw MLHelperError.failed(String(data: data.prefix(4096), encoding: .utf8) ?? "辅助进程异常退出。")
        }
        let values = try output.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= MLJobLimits.outputBytes else { throw FormulaError.invalidTensor }
        return try Data(contentsOf: output)
    }

    private nonisolated static func residentBytes(_ pid: Int32) -> UInt64 {
        var info = proc_taskinfo()
        let count = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        return count == Int32(MemoryLayout<proc_taskinfo>.size) ? info.pti_resident_size : 0
    }

    private nonisolated static func verifiedHelper() throws -> URL {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app" else { throw MLHelperError.unavailable }
        let helper = bundle.appendingPathComponent("Contents/Helpers/PicShotMLHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw MLHelperError.unavailable }
        guard helper.resolvingSymlinksInPath().path == helper.path,
              bundle.resolvingSymlinksInPath().path == bundle.path else { throw MLHelperError.signature }
        for url in [bundle, helper] {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw MLHelperError.signature }
        }
        return helper
    }
}

private final class MLProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var stopDate: Date?
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
        if let stopDate {
            if Date().timeIntervalSince(stopDate) > 1 { kill(process.processIdentifier, SIGKILL) }
        } else {
            stopDate = Date(); process.terminate()
        }
    }
}
