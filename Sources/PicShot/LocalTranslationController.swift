import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

// Only the window and Apple Translation APIs require macOS 15. The application
// continues to launch on macOS 14; callers must guard creation of this window.
@available(macOS 15.0, *)
@MainActor
final class LocalTranslationController: NSWindowController, NSWindowDelegate {
    private let model: LocalTranslationModel

    init(text: String) {
        model = LocalTranslationModel(text: text)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "本机翻译"
        window.minSize = NSSize(width: 650, height: 410)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LocalTranslationView(model: model))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
    }
}

struct LocalTranslationLanguage: Identifiable {
    let language: Locale.Language
    var id: String { language.minimalIdentifier }
    var name: String {
        Locale(identifier: "zh-Hans").localizedString(forIdentifier: id) ?? id
    }
}

enum LocalTranslationInputError: LocalizedError, Equatable {
    case emptyText, missingTarget, missingSource, sameLanguage

    var errorDescription: String? {
        switch self {
        case .emptyText: return "请先输入或识别要翻译的文字。"
        case .missingTarget: return "请选择本机支持的目标语言。"
        case .missingSource: return "请选择本机支持的原文语言，或使用自动检测。"
        case .sameLanguage: return "原文和目标语言相同，请选择不同的目标语言。"
        }
    }
}

struct LocalTranslationRequest: Identifiable {
    let id: UUID
    let text: String
    let source: Locale.Language?
    let target: Locale.Language

    init(id: UUID = UUID(), text: String, sourceID: String, targetID: String,
         languages: [LocalTranslationLanguage]) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalTranslationInputError.emptyText
        }
        guard let target = languages.first(where: { $0.id == targetID })?.language else {
            throw LocalTranslationInputError.missingTarget
        }
        let source = languages.first(where: { $0.id == sourceID })?.language
        guard sourceID.isEmpty || source != nil else {
            throw LocalTranslationInputError.missingSource
        }
        guard source?.minimalIdentifier != target.minimalIdentifier else {
            throw LocalTranslationInputError.sameLanguage
        }
        self.id = id
        self.text = text // Preserve paragraph spacing in the actual translation.
        self.source = source
        self.target = target
    }
}

// A separate request identity is necessary: cancelling an Apple task may not
// immediately stop a download or its underlying service. Late replies must not
// overwrite newer input, another translation, or a cancelled/closed window.
struct LocalTranslationRequestGate {
    private(set) var currentID: UUID?
    mutating func begin(_ id: UUID) { currentID = id }
    mutating func cancel() { currentID = nil }
    func accepts(_ id: UUID) -> Bool { currentID == id }
}

@available(macOS 15.0, *)
@MainActor
final class LocalTranslationModel: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, downloadRequired, preparing, translating
        case complete(String), cancelled, failed(String)

        var isWorking: Bool {
            switch self {
            case .checking, .preparing, .translating: return true
            default: return false
            }
        }

        var message: String {
            switch self {
            case .idle: return "确认原文及语言后，点击「翻译」。"
            case .checking: return "正在检查本机语言支持与下载状态…"
            case .downloadRequired: return "需要下载 Apple 语言包。继续后由 macOS 请求下载许可；首次下载需要联网。"
            case .preparing: return "正在准备语言，请处理 macOS 的语言下载提示…"
            case .translating: return "正在本机翻译；如语言包已被移除，macOS 会提示重新下载…"
            case .complete(let detail): return "已完成 · \(detail) · 请核对译文"
            case .cancelled: return "已取消，本次结果已丢弃；系统已开始的语言下载可能继续。"
            case .failed(let detail): return "未生成译文：\(detail)"
            }
        }
    }

    struct Run: Identifiable {
        let request: LocalTranslationRequest
        let prepareLanguages: Bool
        var id: UUID { request.id }
    }

    @Published var original: String
    @Published var translated = ""
    @Published var sourceID = ""
    @Published var targetID = ""
    @Published private(set) var languages: [LocalTranslationLanguage] = []
    @Published private(set) var loadingLanguages = true
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var run: Run?

    private var pendingDownload: LocalTranslationRequest?
    private var availabilityTask: Task<Void, Never>?
    private var gate = LocalTranslationRequestGate()

    init(text: String) { original = text }

    var canTranslate: Bool {
        !loadingLanguages && !languages.isEmpty && !phase.isWorking
            && !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canExport: Bool {
        !phase.isWorking && !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadLanguages() async {
        // This checks the system catalog only. It never initiates a translation
        // or downloads models just because the window was opened.
        loadingLanguages = true
        let supported = await LanguageAvailability().supportedLanguages
        guard !Task.isCancelled else { return }
        var seen = Set<String>()
        languages = supported.map { LocalTranslationLanguage(language: $0) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !languages.contains(where: { $0.id == targetID }) {
            let preferred = Locale.current.language.minimalIdentifier
            targetID = languages.first(where: { $0.id == preferred })?.id
                ?? languages.first(where: { $0.language.languageCode?.identifier == "zh" })?.id
                ?? languages.first?.id ?? ""
        }
        loadingLanguages = false
        if languages.isEmpty {
            phase = .failed("当前系统未提供可用的 Apple 翻译语言。请检查系统设置或稍后重试。")
        }
    }

    func inputChanged() {
        invalidateRequest()
        translated = ""
        phase = .idle
    }

    func beginTranslation() {
        invalidateRequest()
        translated = ""
        do {
            let request = try LocalTranslationRequest(
                text: original, sourceID: sourceID, targetID: targetID, languages: languages
            )
            gate.begin(request.id)
            phase = .checking
            availabilityTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let availability = LanguageAvailability()
                    let status: LanguageAvailability.Status
                    if let source = request.source {
                        status = await availability.status(from: source, to: request.target)
                    } else {
                        status = try await availability.status(for: request.text, to: request.target)
                    }
                    guard !Task.isCancelled, self.gate.accepts(request.id) else { return }
                    switch status {
                    case .installed:
                        self.launch(request, prepareLanguages: false)
                    case .supported:
                        self.pendingDownload = request
                        self.phase = .downloadRequired
                    case .unsupported:
                        self.fail("Apple 翻译不支持这组语言，或原文与目标语言相同。请更换语言。", for: request.id)
                    @unknown default:
                        self.fail("无法确认这组语言的可用状态，请稍后重试。", for: request.id)
                    }
                } catch {
                    guard !Task.isCancelled, self.gate.accepts(request.id) else { return }
                    self.fail(Self.explanation(for: error), for: request.id)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func approveLanguageDownload() {
        guard let request = pendingDownload, gate.accepts(request.id) else { return }
        pendingDownload = nil
        launch(request, prepareLanguages: true)
    }

    private func launch(_ request: LocalTranslationRequest, prepareLanguages: Bool) {
        guard gate.accepts(request.id) else { return }
        phase = prepareLanguages ? .preparing : .translating
        // Creating the SwiftUI task is gated behind an explicit Translate click
        // and, if necessary, a second click to request the system download UI.
        run = Run(request: request, prepareLanguages: prepareLanguages)
    }

    func translate(_ run: Run, using session: TranslationSession) async {
        let request = run.request
        guard gate.accepts(request.id), !Task.isCancelled else { return }
        do {
            if run.prepareLanguages, request.source != nil {
                // prepareTranslation cannot identify a nil source without text.
                // For Auto, translate(text) performs Apple's detection and shows
                // the same system download permission UI when needed.
                try await session.prepareTranslation()
                guard gate.accepts(request.id), !Task.isCancelled else { return }
                phase = .translating
            }
            let response = try await session.translate(request.text)
            guard gate.accepts(request.id), !Task.isCancelled else { return }
            guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("系统返回了空白结果，请检查原文后重试。", for: request.id)
                return
            }
            translated = response.targetText
            let sourceName = LocalTranslationLanguage(language: response.sourceLanguage).name
            let targetName = LocalTranslationLanguage(language: response.targetLanguage).name
            phase = .complete("\(sourceName) → \(targetName)")
            self.run = nil
            gate.cancel()
        } catch {
            guard gate.accepts(request.id), !Task.isCancelled else { return }
            if error is CancellationError {
                cancel()
            } else {
                fail(Self.explanation(for: error), for: request.id)
            }
        }
    }

    private func fail(_ message: String, for id: UUID) {
        guard gate.accepts(id) else { return }
        translated = ""
        phase = .failed(message)
        pendingDownload = nil
        run = nil
        gate.cancel()
    }

    func cancel() {
        invalidateRequest()
        translated = ""
        phase = .cancelled
    }

    private func invalidateRequest() {
        gate.cancel()
        availabilityTask?.cancel()
        availabilityTask = nil
        pendingDownload = nil
        // Removing this task view cancels its SwiftUI translation task. Request
        // IDs also discard late results on macOS 15, where session.cancel() does
        // not exist (it was introduced in macOS 26).
        run = nil
    }

    static func explanation(for error: Error) -> String {
        switch error {
        case TranslationError.unableToIdentifyLanguage:
            return "无法自动识别原文语言。请手动选择语言，或提供更完整的原文（建议至少 20 个字符）。"
        case TranslationError.unsupportedSourceLanguage:
            return "系统不支持所选原文语言，请更换语言。"
        case TranslationError.unsupportedTargetLanguage:
            return "系统不支持所选目标语言，请更换语言。"
        case TranslationError.unsupportedLanguagePairing:
            return "系统不支持这组语言，请选择不同的原文或目标语言。"
        case TranslationError.nothingToTranslate:
            return "没有可翻译的文字，请检查原文。"
        default:
            return "\(error.localizedDescription) 若已取消下载，可点击「重试」，并在系统提示中允许下载。"
        }
    }

    func copyResult() {
        guard canExport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translated, forType: .string)
    }

    func saveResult() {
        guard canExport else { return }
        let text = translated
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "翻译结果.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法保存译文"
            alert.runModal()
        }
    }
}

@available(macOS 15.0, *)
@MainActor
private struct LocalTranslationView: View {
    @ObservedObject var model: LocalTranslationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                Picker("原文", selection: sourceSelection) {
                    Text("自动检测").tag("")
                    ForEach(model.languages) { Text($0.name).tag($0.id) }
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("译为", selection: targetSelection) {
                    if model.languages.isEmpty { Text("正在加载…").tag("") }
                    ForEach(model.languages) { Text($0.name).tag($0.id) }
                }
            }
            .disabled(model.loadingLanguages)

            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文 · 可编辑").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: originalBinding)
                        .font(.system(size: 14))
                        .accessibilityLabel("待翻译原文")
                        .border(Color.secondary.opacity(0.2))
                }.frame(minWidth: 245, maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text("译文 · 可编辑").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.translated)
                        .font(.system(size: 14))
                        .accessibilityLabel("翻译结果")
                        .disabled(model.phase.isWorking)
                        .border(Color.secondary.opacity(0.2))
                }.frame(minWidth: 245, maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(alignment: .top, spacing: 8) {
                if model.phase.isWorking || model.loadingLanguages {
                    ProgressView().controlSize(.small)
                }
                Text(model.loadingLanguages ? "正在读取系统支持的语言…" : model.phase.message)
                    .font(.caption).textSelection(.enabled)
                    .foregroundStyle(statusColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 30, alignment: .top)

            HStack {
                if model.phase == .downloadRequired {
                    Button("下载语言并翻译") { model.approveLanguageDownload() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(translateButtonTitle) { model.beginTranslation() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!model.canTranslate)
                }
                if model.phase.isWorking || model.phase == .downloadRequired {
                    Button("取消") { model.cancel() }.keyboardShortcut(.cancelAction)
                }
                if !model.loadingLanguages && model.languages.isEmpty {
                    Button("重新检查语言") { Task { await model.loadLanguages() } }
                }
                Spacer()
                Button("复制译文") { model.copyResult() }.disabled(!model.canExport)
                Button("导出译文…") { model.saveResult() }.disabled(!model.canExport)
            }
            Text("Apple 翻译在本机处理原文；语言包下载需要联网。PicShot 不使用云端翻译接口。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background {
            if let run = model.run {
                LocalTranslationTaskView(model: model, run: run).id(run.id)
            }
        }
        .task { await model.loadLanguages() }
    }

    private var originalBinding: Binding<String> {
        Binding(get: { model.original }, set: { model.original = $0; model.inputChanged() })
    }

    private var sourceSelection: Binding<String> {
        Binding(get: { model.sourceID }, set: { model.sourceID = $0; model.inputChanged() })
    }

    private var targetSelection: Binding<String> {
        Binding(get: { model.targetID }, set: { model.targetID = $0; model.inputChanged() })
    }

    private var translateButtonTitle: String {
        switch model.phase {
        case .failed, .cancelled: return "重试"
        case .complete: return "重新翻译"
        default: return "翻译"
        }
    }

    private var statusColor: Color {
        if case .failed = model.phase { return .red }
        return .secondary
    }
}

@available(macOS 15.0, *)
@MainActor
private struct LocalTranslationTaskView: View {
    let model: LocalTranslationModel
    let run: LocalTranslationModel.Run

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .translationTask(TranslationSession.Configuration(source: run.request.source, target: run.request.target)) { session in
                await model.translate(run, using: session)
            }
    }
}
