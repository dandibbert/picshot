import AppKit
import SwiftUI
import PicShotCore
import PicShotFormulaCore
import PicShotTableEngine

@MainActor
final class TableRecognitionController: NSWindowController, NSWindowDelegate {
    private let model: TableRecognitionModel

    init(image: CGImage, onRecognized: @escaping (StructuredTable, [String]) -> Void) {
        model = TableRecognitionModel(image: image, onRecognized: onRecognized)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "本机表格识别 · 可编辑 XLSX"
        window.minSize = NSSize(width: 640, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TableRecognitionView(model: model))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func windowWillClose(_ notification: Notification) { model.close() }
}

/// Injectable operations keep interruption tests independent of downloads and model weights.
@MainActor
struct TableRecognitionServices {
    var verifiedDirectory: @MainActor () async throws -> URL
    var install: @MainActor (@escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
    var recognize: @MainActor (CGImage, URL) async throws -> TableRecognitionResult

    static let live = TableRecognitionServices(
        verifiedDirectory: { try await ModelPackService.shared.verifiedDirectory(for: .table) },
        install: { progress in try await ModelPackService.shared.install(.table, progress: progress) },
        recognize: { image, directory in try await MLHelperService.shared.table(image: image, modelDirectory: directory) })
}

@MainActor
final class TableRecognitionModel: ObservableObject {
    static let reviewNotice = "合并单元格、行列数量与文字请人工核对，模型置信度不代表正确。"
    @Published private(set) var working = false
    @Published private(set) var cancelling = false
    @Published private(set) var installed = false
    @Published private(set) var installationChecked = false
    @Published private(set) var status = "正在检查可选表格模型…"
    @Published private(set) var progress: Double?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var unmatchedOCR: [TableOCRObservation] = []
    let image: CGImage
    private let services: TableRecognitionServices
    private let onRecognized: (StructuredTable, [String]) -> Void
    private var task: Task<Void, Never>?
    private var currentID: UUID?
    private var closed = false

    init(image: CGImage, services: TableRecognitionServices? = nil,
         onRecognized: @escaping (StructuredTable, [String]) -> Void) {
        self.image = image; self.services = services ?? .live; self.onRecognized = onRecognized
    }

    var modelSize: String { ByteCountFormatter.string(fromByteCount: ModelPackManifest.table.totalBytes, countStyle: .file) }
    var canRecognize: Bool { installed && !working && !closed }

    func checkInstallation() {
        guard !installationChecked else { return }
        begin { model, id in
            do {
                _ = try await model.services.verifiedDirectory()
                guard model.accepts(id) else { return }
                model.installed = true
                model.status = "模型已通过 SHA-256 校验。识别后会打开表格编辑器。"
            } catch {
                guard model.accepts(id) else { return }
                model.installed = false
                if let validation = error as? ModelValidationError, case .missing = validation {
                    model.status = "需先下载可选表格模型（\(model.modelSize)）。图片不会上传。"
                } else {
                    model.status = "模型暂不可用：\(error.localizedDescription)"
                }
            }
            guard model.accepts(id) else { return }
            model.installationChecked = true
        }
    }

    func checkInstallationAgain() {
        guard !working, !closed else { return }
        installationChecked = false; installed = false
        status = "正在检查可选表格模型…"
        checkInstallation()
    }

    func download() {
        guard !working, !closed else { return }
        let manifest = ModelPackManifest.table
        let alert = NSAlert()
        alert.messageText = "下载可选表格模型？"
        alert.informativeText = "来源：ModelScope / RapidAI / RapidTable v2.0.0\n模型：\(manifest.title)\n大小：\(modelSize)（\(manifest.totalBytes) 字节）\n许可证：\(manifest.license)\n\n下载后逐个校验固定 SHA-256，保存在本机 Application Support/PicShot/Models。下载需要联网；图片及识别结果不会上传。模型安装后可离线识别。"
        alert.addButton(withTitle: "下载模型")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installConfirmedModel()
    }

    /// Called only after the explicit download confirmation above.
    func installConfirmedModel() {
        begin { model, id in
            model.status = "正在下载并校验表格模型…"
            model.progress = 0
            do {
                _ = try await model.services.install { received, total in
                    Task { @MainActor [weak model] in
                        guard let model, model.accepts(id), total > 0 else { return }
                        model.progress = min(1, max(0, Double(received) / Double(total)))
                    }
                }
                guard model.accepts(id) else { return }
                model.installed = true; model.installationChecked = true
                model.status = "模型下载完成并通过校验。点击「识别并编辑表格」。"
            } catch { model.fail(error, id: id) }
        }
    }

    func recognize() {
        guard canRecognize else { return }
        begin { model, id in
            model.warnings = []; model.unmatchedOCR = []
            model.status = "正在本机识别表格结构和文字；请稍候…"
            do {
                // Reverify every job, even if the window previously showed an available model.
                let directory: URL
                do { directory = try await model.services.verifiedDirectory() }
                catch {
                    if model.accepts(id) { model.installed = false }
                    throw error
                }
                guard model.accepts(id) else { return }
                let result = try await model.services.recognize(model.image, directory)
                guard model.accepts(id) else { return }
                model.warnings = result.warnings.contains(Self.reviewNotice) ? result.warnings : [Self.reviewNotice] + result.warnings
                model.unmatchedOCR = result.unmatchedOCR
                model.status = "已识别 \(result.table.rowCount) 行 × \(result.table.columnCount) 列。编辑器已打开，请对照原图核对文字和合并单元格。"
                // The editor callback also receives every unmatched string. Nothing is silently discarded.
                let review = model.warnings + result.unmatchedOCR.enumerated().map { index, observation in
                    "未分配文字 \(index + 1)：\n\(observation.text)"
                }
                model.onRecognized(result.table, review)
            } catch { model.fail(error, id: id) }
        }
    }

    private func accepts(_ id: UUID) -> Bool {
        currentID == id && !cancelling && !closed && !Task.isCancelled
    }

    private func begin(_ operation: @escaping @MainActor (TableRecognitionModel, UUID) async -> Void) {
        guard !working, !closed else { return }
        let id = UUID()
        currentID = id; working = true; cancelling = false; progress = nil
        task = Task { [weak self] in
            guard let self else { return }
            if self.accepts(id) { await operation(self, id) }
            guard self.currentID == id else { return }
            if self.cancelling { self.status = "已取消。" }
            self.currentID = nil; self.working = false; self.cancelling = false
            self.progress = nil; self.task = nil
        }
    }

    private func fail(_ error: Error, id: UUID) {
        guard accepts(id) else { return }
        status = error is CancellationError ? "已取消。" : error.localizedDescription
    }

    func cancel() {
        guard working, !cancelling else { return }
        cancelling = true; progress = nil
        status = "正在取消并清理临时文件…"
        task?.cancel()
        // Keep the slot occupied until the shared helper/download operation has actually unwound.
    }

    func close() {
        closed = true
        cancel()
    }
}

@MainActor
private struct TableRecognitionView: View {
    @ObservedObject var model: TableRecognitionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("表格截图").font(.headline)
                Spacer()
                Text("\(model.image.width) × \(model.image.height) px").font(.caption).foregroundStyle(.secondary)
            }
            Image(decorative: model.image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 240)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .accessibilityLabel("待识别的表格截图")
            Text("请只截取一张完整表格。结果可在编辑器中修改并导出 XLSX。\n\(TableRecognitionModel.reviewNotice)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: model.installed ? "checkmark.shield" : "shippingbox")
                Text(model.installed ? "表格模型已校验" : (model.installationChecked ? "表格模型未就绪" : "正在检查表格模型"))
                Spacer()
                Text("\(model.modelSize) · \(ModelPackManifest.table.license)")
            }.font(.caption).foregroundStyle(.secondary)
            if let progress = model.progress {
                ProgressView(value: progress).accessibilityLabel("模型下载进度")
            } else if model.working {
                ProgressView().controlSize(.small)
            }
            Text(model.status).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !model.warnings.isEmpty || !model.unmatchedOCR.isEmpty {
                review
            }
            Spacer(minLength: 0)
            HStack {
                if model.installed {
                    Button("识别并编辑表格") { model.recognize() }.disabled(!model.canRecognize)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("下载可选模型…") { model.download() }.disabled(model.working)
                    Button("重新检查") { model.checkInstallationAgain() }.disabled(model.working)
                }
                if model.working { Button(model.cancelling ? "正在取消…" : "取消") { model.cancel() }.disabled(model.cancelling) }
                Spacer()
                Link("模型来源", destination: ModelPackManifest.table.source)
                Link("许可证", destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
            }
            Text("SLANet-plus + Apple Vision · 本机运行 · 无图片上传 · 下载与识别均可取消")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(16).onAppear { model.checkInstallation() }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("需要核对", systemImage: "exclamationmark.triangle").font(.caption.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(model.unmatchedOCR.enumerated()), id: \.offset) { index, observation in
                        Text("未分配文字 \(index + 1)：\n\(observation.text)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(minHeight: 70, maxHeight: 150)
        }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
