import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import PicShotCore
import PicShotFormulaRenderCore

extension PinLaTeXContent {
    init(_ request: FormulaRenderRequest) {
        self.init(source: request.latex, fontSize: request.fontSize, scale: request.scale, transparent: request.transparent)
    }
    var renderRequest: FormulaRenderRequest { FormulaRenderRequest(latex: source, fontSize: fontSize, scale: scale, transparent: transparent) }
}

enum LaTeXPinRaster {
    /// ImageIO checks type/dimensions before decoding; never hand a persisted SVG/PDF to AppKit.
    static func decode(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard data.count <= FormulaRenderLimits.resultBytes, width > 0, height > 0,
              width <= FormulaRenderLimits.dimension, height <= FormulaRenderLimits.dimension,
              width <= FormulaRenderLimits.pixels / height,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw FormulaRenderError.invalidOutput }
        return image
    }
}

/// A committed pin remains visible/exportable while a bounded draft is edited. Only a
/// successful renderer AND disk transaction replace it. History retains source, not rasters.
@MainActor final class LaTeXPinModel: ObservableObject {
    static let maximumUndoEntries = 10
    @Published var source: String { didSet { if source != oldValue { invalidateDraft() } } }
    @Published var fontSize: Double { didSet { if fontSize != oldValue { invalidateDraft() } } }
    @Published var scale: Int { didSet { if scale != oldValue { invalidateDraft() } } }
    @Published var transparent: Bool { didSet { if transparent != oldValue { invalidateDraft() } } }
    @Published private(set) var working = false
    @Published private(set) var saving = false
    @Published private(set) var status = "编辑后更新贴图；失败会保留上一次有效结果。"
    @Published private(set) var committed: PinLaTeXContent?
    @Published private(set) var undoSources: [PinLaTeXContent] = []
    var onCommit: ((PreparedRichPin) throws -> Void)?
    var onCancelSaving: (() -> Void)?
    private let renderer: @Sendable (FormulaRenderRequest) async throws -> FormulaRenderResult
    private var task: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    private var resettingDraft = false

    init(content: PinLaTeXContent,
         renderer: @escaping @Sendable (FormulaRenderRequest) async throws -> FormulaRenderResult = { try await FormulaRenderService.shared.render($0) }) {
        committed = content; source = content.source; fontSize = content.fontSize; scale = content.scale
        transparent = content.transparent; self.renderer = renderer
    }
    deinit { task?.cancel(); drainingTask?.cancel() }
    var draft: PinLaTeXContent { PinLaTeXContent(source: source, fontSize: fontSize, scale: scale, transparent: transparent) }
    var canApply: Bool { !closed && !working && !saving && draft.isValid && draft != committed }
    var canUndo: Bool { !closed && !working && !saving && !undoSources.isEmpty }
    var isClosed: Bool { closed }

    func apply() { guard canApply else { return }; renderAndCommit(draft, undo: false) }
    func undo() { guard canUndo, let previous = undoSources.last else { return }; renderAndCommit(previous, undo: true) }
    private func renderAndCommit(_ proposed: PinLaTeXContent, undo: Bool) {
        begin { [weak self] in
            guard let self else { throw CancellationError() }
            let result = try await self.renderer(proposed.renderRequest)
            return result
        } completion: { [weak self] result in
            guard let self, let old = self.committed, let commit = self.onCommit else { throw CancellationError() }
            let prepared = try PreparedRichPin(formula: proposed.renderRequest, result: result)
            try commit(prepared)
            // No throwing or asynchronous work after the store has accepted the edit.
            if undo { self.undoSources.removeLast() }
            else {
                self.undoSources.append(old)
                if self.undoSources.count > Self.maximumUndoEntries { self.undoSources.removeFirst() }
            }
            self.committed = proposed; self.resetDraft(to: proposed)
            self.status = undo ? "已撤销上次公式修改。" : "贴图已更新并保存。"
        }
    }
    /// Exports use the committed source, never an invalid draft or disk-supplied vector data.
    /// PNG can be copied directly by the controller from the displayed saved raster.
    func export(_ format: FormulaRenderFormat, deliver: @escaping (Data) -> Void) {
        guard !closed, !working, !saving, let content = committed else { return }
        if format == .latex { deliver(Data(content.source.utf8)); return }
        begin { [renderer] in
            let result = try await renderer(content.renderRequest)
            try result.validate(for: content.renderRequest)
            return result
        } completion: { [weak self] result in
            deliver(format.data(from: result))
            if self?.saving != true { self?.status = "已准备 \(format.label)。" }
        }
    }
    private func begin(_ operation: @escaping @MainActor () async throws -> FormulaRenderResult,
                       completion: @escaping @MainActor (FormulaRenderResult) throws -> Void) {
        guard !closed, !working, !saving else { return }
        let token = UUID(); generation = token; working = true
        status = "正在本机排版；原贴图保持不变…"
        let previous = drainingTask; drainingTask = nil
        task = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                guard self?.generation == token, self?.closed == false else { return }
                let result = try await operation()
                try Task.checkCancellation()
                guard self?.generation == token, self?.closed == false else { return }
                try completion(result)
            } catch {
                guard self?.generation == token, self?.closed == false else { return }
                self?.status = error is CancellationError ? "已取消，保留原贴图。" : error.localizedDescription
            }
            guard self?.generation == token else { return }
            self?.working = false; self?.task = nil
        }
    }
    private func invalidateDraft() {
        guard !resettingDraft else { return }
        cancelWork()
        status = draft.isValid ? "尚未应用；原贴图保持不变。" : "请输入 8 KiB 以内的非空 LaTeX（字号 12–96）。"
    }
    private func resetDraft(to content: PinLaTeXContent) {
        resettingDraft = true; defer { resettingDraft = false }
        source = content.source; fontSize = content.fontSize; scale = content.scale; transparent = content.transparent
    }
    private func cancelWork() {
        generation = UUID()
        if let task { task.cancel(); drainingTask = task }
        task = nil; working = false
    }
    func beginSaving() { guard !closed else { return }; saving = true; status = "正在安全保存新副本…" }
    func finishSaving(cancelled: Bool = false, error: String? = nil) {
        guard !closed else { return }; saving = false
        status = error ?? (cancelled ? "已取消；原贴图与已完成文件会保留。" : "已保存公式新副本。")
    }
    func cancel() {
        cancelWork(); if saving { onCancelSaving?() }; saving = false
        status = "已取消；原贴图与已完成文件会保留。"
    }
    func discardDraft() { cancel(); if let committed { resetDraft(to: committed) } }
    func close() {
        guard !closed else { return }; closed = true; cancelWork()
        onCancelSaving?(); onCancelSaving = nil; saving = false
        onCommit = nil; committed = nil; undoSources.removeAll()
        resettingDraft = true; source = ""; resettingDraft = false
        drainingTask = nil
    }
    func waitUntilIdle() async { let pending = task; await pending?.value }
    func copySource(to pasteboard: NSPasteboard = .general) {
        guard !closed, let committed else { return }
        pasteboard.clearContents(); pasteboard.setString(committed.source, forType: .string)
    }
}

@MainActor struct LaTeXPinEditorView: View {
    @ObservedObject var model: LaTeXPinModel
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("编辑 LaTeX · 本机排版").font(.headline)
            BoundedLaTeXEditor(text: $model.source).frame(height: 124)
                .border(Color.secondary.opacity(0.3)).accessibilityLabel("贴图 LaTeX 源码")
            HStack {
                Picker("字号", selection: $model.fontSize) {
                    ForEach([12.0, 16, 24, 32, 48, 72, 96], id: \.self) { Text("\(Int($0))").tag($0) }
                }.frame(width: 120)
                Picker("倍率", selection: $model.scale) { Text("1×").tag(1); Text("2×").tag(2); Text("3×").tag(3) }.frame(width: 110)
                Toggle("透明", isOn: $model.transparent)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("撤销修改") { model.undo() }.disabled(!model.canUndo)
                Spacer()
                if model.working || model.saving { ProgressView().controlSize(.small); Button("停止") { model.cancel() } }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("更新贴图") { model.apply() }.disabled(!model.canApply).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(14).frame(width: 460)
    }
}

/// Native input rejects oversized paste before insertion and has no unbounded NSTextView
/// undo stack. Pin undo is ten committed source/options entries (no retained render arrays).
@MainActor struct BoundedLaTeXEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 432, height: 124))
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = false; editor.allowsUndo = false
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 6, height: 6); editor.delegate = context.coordinator
        editor.string = text
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        if let editor = scroll.documentView as? NSTextView, editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            guard replacementString.utf8.count <= FormulaRenderLimits.latexBytes,
                  let range = Range(affectedCharRange, in: textView.string) else { NSSound.beep(); return false }
            let result = textView.string.replacingCharacters(in: range, with: replacementString)
            guard result.utf8.count <= FormulaRenderLimits.latexBytes, !result.contains("\0") else { NSSound.beep(); return false }
            return true
        }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { text.wrappedValue = editor.string } }
    }
}

/// Formula-specific contract over descriptor-bound create-only publication. Source,
/// SVG and MathML are kept in their actual types, never relabeled as image artifacts.
enum LaTeXPinExport {
    static func publish(_ data: Data, format: FormulaRenderFormat, to url: URL,
                        cancellation: ImageExportCancellation = ImageExportCancellation(),
                        beforeCommit: (() throws -> Void)? = nil) throws {
        try publish(data, format: format, to: RawPinArtifactDestination(url), cancellation: cancellation, beforeCommit: beforeCommit)
    }
    static func publish(_ data: Data, format: FormulaRenderFormat, to destination: RawPinArtifactDestination,
                        cancellation: ImageExportCancellation = ImageExportCancellation(),
                        beforeCommit: (() throws -> Void)? = nil) throws {
        guard destination.url.pathExtension.lowercased() == format.fileExtension,
              !data.isEmpty, data.count <= FormulaRenderLimits.resultBytes else {
            throw ImageExportError.invalidDestination
        }
        switch format {
        case .latex:
            guard data.count <= FormulaRenderLimits.latexBytes, let source = String(data: data, encoding: .utf8),
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !source.contains("\0") else {
                throw FormulaRenderError.invalidOutput
            }
        case .svg:
            guard data.count <= FormulaRenderLimits.svgBytes, let source = String(data: data, encoding: .utf8), source.hasPrefix("<svg ") else {
                throw FormulaRenderError.invalidOutput
            }
        case .mathML:
            guard data.count <= FormulaRenderLimits.mathMLBytes, let source = String(data: data, encoding: .utf8), source.hasPrefix("<math ") else {
                throw FormulaRenderError.invalidOutput
            }
        case .png:
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw FormulaRenderError.invalidOutput }
        case .pdf:
            guard data.starts(with: Data("%PDF-".utf8)) else { throw FormulaRenderError.invalidOutput }
        }
        try RawPinArtifactPublication.publish(data, to: destination, cancellation: cancellation, beforeCommit: beforeCommit)
    }
}

/// Queued formula saves are separate from source undo: at most two bounded encoded
/// payloads (24 MiB each). A cancelled owner releases bytes immediately, but its slot
/// remains occupied until the serial publication operation actually drains.
final class LaTeXPinSaveLease: @unchecked Sendable {
    static let maximumJobs = 2
    private static let lock = NSLock()
    private static var jobs = 0
    private var released = false
    private init() {}
    static func acquire() -> LaTeXPinSaveLease? {
        lock.lock(); defer { lock.unlock() }
        guard jobs < maximumJobs else { return nil }
        jobs += 1; return LaTeXPinSaveLease()
    }
    static var activeJobs: Int { lock.lock(); defer { lock.unlock() }; return jobs }
    func release() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard !released else { return }; released = true; Self.jobs -= 1
    }
    deinit { release() }
}
