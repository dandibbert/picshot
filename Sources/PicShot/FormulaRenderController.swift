import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PicShotFormulaRenderCore

/// Open with recognized or user-entered LaTeX. The owner retains this window controller.
@MainActor
final class FormulaRenderController: NSWindowController, NSWindowDelegate {
    private let model: FormulaRenderModel
    var onClose: (() -> Void)?
    init(latex: String) {
        model = FormulaRenderModel(latex: latex)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "公式预览与导出 · 本机 MathJax"
        window.minSize = NSSize(width: 680, height: 520)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: FormulaRenderView(model: model)); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func windowWillClose(_ notification: Notification) {
        model.close()
        let callback = onClose; onClose = nil; callback?()
    }
    override func close() { model.close(); super.close() }
    func update(latex: String) {
        if model.latex != latex { model.latex = latex }
        if model.result == nil { model.render() }
    }
    /// Smoke verification uses the exact normal UI/model/service pathway.
    /// The caller owns showing and capturing this real window.
    func renderForVerification() async throws -> FormulaRenderResult {
        let result = try await model.renderAndWait()
        await Task.yield()
        window?.contentView?.layoutSubtreeIfNeeded()
        return result
    }
}

@MainActor
final class FormulaRenderModel: ObservableObject {
    @Published var latex: String { didSet { if latex != oldValue { invalidate() } } }
    @Published var fontSize: Double = 24 { didSet { if fontSize != oldValue { invalidate() } } }
    @Published var scale = 2 { didSet { if scale != oldValue { invalidate() } } }
    @Published var transparent = false { didSet { if transparent != oldValue { invalidate() } } }
    @Published var format = FormulaRenderFormat.svg
    @Published private(set) var result: FormulaRenderResult?
    @Published private(set) var image: NSImage?
    @Published private(set) var working = false
    @Published private(set) var status = "输入 LaTeX 后点击「更新预览」。公式始终留在本机。"
    private var task: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    private let renderer: @Sendable (FormulaRenderRequest) async throws -> FormulaRenderResult

    init(latex: String, renderer: @escaping @Sendable (FormulaRenderRequest) async throws -> FormulaRenderResult = { try await FormulaRenderService.shared.render($0) }) {
        self.latex = latex; self.renderer = renderer
    }
    var canRender: Bool { !working && !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && latex.utf8.count <= FormulaRenderLimits.latexBytes }
    var canExport: Bool { !working && result != nil }

    func render() {
        guard canRender, !closed else { return }
        let request = FormulaRenderRequest(latex: latex, fontSize: fontSize, scale: scale, transparent: transparent)
        let id = UUID(); generation = id; working = true; result = nil; image = nil
        status = "正在本机排版，辅助进程完成后退出…"
        let previous = drainingTask; drainingTask = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // A replacement waits for this window's cancelled helper to exit.
                // This prevents rapid edits/update clicks from racing its global slot.
                await previous?.value
                try Task.checkCancellation()
                guard self.generation == id, !self.closed else { return }
                let rendered = try await self.renderer(request)
                try Task.checkCancellation()
                guard self.generation == id, !self.closed else { return }
                try rendered.validate(for: request)
                guard let preview = NSImage(data: rendered.png) else { throw FormulaRenderError.invalidOutput }
                self.result = rendered; self.image = preview
                self.status = "\(rendered.width) × \(rendered.height) 像素 · SVG / PDF 保留矢量轮廓 · MathML 保留公式结构"
            } catch {
                guard self.generation == id, !self.closed else { return }
                self.status = error is CancellationError ? "已取消。" : error.localizedDescription
            }
            guard self.generation == id else { return }
            self.working = false; self.task = nil
        }
    }
    func renderAndWait() async throws -> FormulaRenderResult {
        guard !closed else { throw CancellationError() }
        if result == nil && !working { render() }
        if let task { await task.value }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let result, image != nil else { throw FormulaRenderVerificationError.failed(status) }
        return result
    }
    private func invalidate() {
        generation = UUID()
        if let task { task.cancel(); drainingTask = task }
        task = nil
        result = nil; image = nil; working = false
        status = latex.utf8.count > FormulaRenderLimits.latexBytes ? "公式超过 8 KiB，请缩短后再预览。" : "内容已修改，请更新预览后再导出。"
    }
    func cancel() { invalidate(); status = "已取消。" }
    func close() { closed = true; invalidate(); drainingTask = nil }

    func copyLaTeX() {
        guard !latex.isEmpty, latex.utf8.count <= FormulaRenderLimits.latexBytes else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(latex, forType: .string)
    }
    func copy(_ format: FormulaRenderFormat) {
        guard canExport, let result else { return }
        let board = NSPasteboard.general; board.clearContents()
        switch format {
        case .latex: board.setString(result.latex, forType: .string)
        case .mathML:
            board.setString(result.mathML, forType: NSPasteboard.PasteboardType("public.mathml"))
            board.setString(result.mathML, forType: .string)
        case .svg:
            board.setData(Data(result.svg.utf8), forType: NSPasteboard.PasteboardType(UTType.svg.identifier))
            board.setString(result.svg, forType: .string)
        case .png: board.setData(result.png, forType: .png)
        case .pdf: board.setData(result.pdf, forType: .pdf)
        }
        status = "已复制 \(format.label)。"
    }
    func save() {
        guard canExport, let result else { return }
        let selected = format
        let panel = NSSavePanel(); panel.nameFieldStringValue = "公式.\(selected.fileExtension)"
        if let type = UTType(filenameExtension: selected.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try selected.data(from: result).write(to: url, options: .atomic); status = "已导出 \(selected.label)。" }
        catch { status = error.localizedDescription; NSAlert(error: error).runModal() }
    }
}

private enum FormulaRenderVerificationError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let detail): return detail } }
}

@MainActor
private struct FormulaRenderView: View {
    @ObservedObject var model: FormulaRenderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LaTeX · 可编辑；使用公式本身，无需 $…$ 或 \\[ … \\] 分隔符").font(.caption)
            TextEditor(text: $model.latex).font(.system(size: 15, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 170).border(Color.secondary.opacity(0.3))
                .accessibilityLabel("可编辑的 LaTeX 公式")
            HStack {
                Picker("字号", selection: $model.fontSize) {
                    ForEach([12.0, 16.0, 24.0, 32.0, 48.0, 72.0, 96.0], id: \.self) { size in Text("\(Int(size))").tag(size) }
                }.frame(width: 120)
                Picker("PNG 倍率", selection: $model.scale) { Text("1×").tag(1); Text("2×").tag(2); Text("3×").tag(3) }.frame(width: 150)
                Toggle("透明背景", isOn: $model.transparent)
                Spacer()
                if model.working { ProgressView().controlSize(.small); Button("取消") { model.cancel() } }
                Button("更新预览") { model.render() }.disabled(!model.canRender).keyboardShortcut(.return, modifiers: .command)
            }
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let image = model.image, let result = model.result {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: result.pointWidth, height: result.pointHeight)
                            .accessibilityLabel("渲染后的公式")
                    } else { Text("预览将在这里显示").foregroundStyle(.secondary).padding(32) }
                }.padding(12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
                .border(Color.secondary.opacity(0.3))
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("复制 LaTeX") { model.copyLaTeX() }.disabled(model.latex.isEmpty)
                Menu("复制排版结果") {
                    ForEach([FormulaRenderFormat.mathML, .svg, .png, .pdf]) { format in Button(format.label) { model.copy(format) } }
                }.disabled(!model.canExport)
                Spacer()
                Picker("格式", selection: $model.format) { ForEach(FormulaRenderFormat.allCases) { format in Text(format.label).tag(format) } }.frame(width: 150)
                Button("导出…") { model.save() }.disabled(!model.canExport)
            }
            Text("Office 可插入 PNG / SVG；MathML 是否能作为可编辑公式粘贴取决于目标软件。暂不提供 Office OMML、Typst 或 AsciiMath 转换。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("MathJax 3.2.2 · Apache-2.0 · 本机字体轮廓 · 支持基础 LaTeX 与 AMS；不支持外部资源、自定义宏及部分非数学字形")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(16).task { if model.result == nil && model.canRender { model.render() } }
    }
}
