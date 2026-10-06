import AppKit
import Vision
import UniformTypeIdentifiers

struct RecognitionResult: Sendable {
    let text: String
    let barcodes: [String]
    var displayText: String {
        guard !barcodes.isEmpty else { return text }
        return [text, "识别码：\n" + barcodes.joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct RecognitionOptions: Sendable, Equatable {
    /// nil selects automatic detection. Explicit identifiers must be supported by this OS.
    var language: String? = nil
}

enum RecognitionService {
    static func supportedLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    static func preferredLanguages(from supported: [String]) -> [String] {
        ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
    }

    static func recognize(_ image: CGImage, options: RecognitionOptions = RecognitionOptions()) async throws -> RecognitionResult {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            let supported = try textRequest.supportedRecognitionLanguages()
            if let language = options.language {
                guard supported.contains(language) else { throw PicShotError.message("当前 macOS 不支持所选识别语言，请选择其他语言。") }
                textRequest.automaticallyDetectsLanguage = false
                textRequest.recognitionLanguages = [language]
            } else {
                textRequest.automaticallyDetectsLanguage = true
                let preferred = preferredLanguages(from: supported)
                if !preferred.isEmpty { textRequest.recognitionLanguages = preferred }
            }
            let barcodes = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([textRequest, barcodes])
            try Task.checkCancellation()
            let observations = (textRequest.results ?? []).sorted { a, b in
                if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.015 { return a.boundingBox.midY > b.boundingBox.midY }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return RecognitionResult(text: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"),
                                     barcodes: (barcodes.results ?? []).compactMap(\.payloadStringValue))
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

@MainActor final class TextResultController: NSWindowController, NSWindowDelegate {
    static let directCopyPreferenceKey = "ocr.copyDirectlyNextTime"
    static var copyDirectlyNextTime: Bool { UserDefaults.standard.bool(forKey: directCopyPreferenceKey) }
    static func copyToPasteboard(_ text: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }

    var onClose: (() -> Void)?
    private let textView = NSTextView()
    private let languagePicker = NSPopUpButton()
    private let layoutPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let directCopy = NSButton(checkboxWithTitle: "下次直接复制文本", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var onTranslate: ((String) -> Void)?
    private var sourceImage: CGImage?
    private let defaults: UserDefaults
    private var recognitionTask: Task<Void, Never>?
    private var generation = UUID()
    private var exportPanel: NSSavePanel?
    private var closed = false
    var resultText: String { textView.string }
    var offersLanguageSelection: Bool { !languagePicker.isHidden }

    init(text: String, title: String = "识别文字", sourceImage: CGImage? = nil,
         onTranslate: ((String) -> Void)? = nil, defaults: UserDefaults = .standard) {
        self.onTranslate = onTranslate; self.sourceImage = sourceImage; self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 310),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentMinSize = NSSize(width: 390, height: 260); window.center()
        let root = NSView(); window.contentView = root
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder; scroll.drawsBackground = true
        textView.isRichText = false; textView.isEditable = true; textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13); textView.string = text
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 430, height: 194)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("识别结果，可编辑")
        scroll.documentView = textView

        languagePicker.controlSize = .small; languagePicker.bezelStyle = .inline
        languagePicker.target = self; languagePicker.action = #selector(changeLanguage)
        languagePicker.setAccessibilityLabel("识别语言")
        languagePicker.toolTip = "选择本机支持的语言并重新识别图片"
        configureLanguages()
        layoutPicker.controlSize = .small; layoutPicker.bezelStyle = .inline
        layoutPicker.addItem(withTitle: "排版")
        layoutPicker.menu?.addItem(withTitle: "合并换行", action: #selector(joinLines), keyEquivalent: "").target = self
        layoutPicker.menu?.addItem(withTitle: "删除多余空行", action: #selector(removeEmptyLines), keyEquivalent: "").target = self
        layoutPicker.setAccessibilityLabel("文本排版")
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let options = NSStackView(views: [languagePicker, progress, NSView(), layoutPicker])
        options.orientation = .horizontal; options.spacing = 6

        directCopy.controlSize = .small; directCopy.target = self; directCopy.action = #selector(changeDirectCopy)
        directCopy.state = defaults.bool(forKey: Self.directCopyPreferenceKey) ? .on : .off
        directCopy.toolTip = "以后识别成功后直接复制；可在贴图的“识别”菜单中关闭"
        let more = NSPopUpButton(frame: .zero, pullsDown: true); more.controlSize = .small; more.bezelStyle = .inline
        more.addItem(withTitle: "更多")
        more.menu?.addItem(withTitle: "导出文本…", action: #selector(saveText), keyEquivalent: "").target = self
        if onTranslate != nil { more.menu?.addItem(withTitle: "翻译…", action: #selector(translateText), keyEquivalent: "").target = self }
        copyButton.target = self; copyButton.action = #selector(copyAll); copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"; copyButton.setAccessibilityLabel("复制识别文本")
        let bottom = NSStackView(views: [directCopy, NSView(), more, copyButton]); bottom.orientation = .horizontal; bottom.spacing = 8
        for view in [scroll, options, bottom] { root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: options.topAnchor, constant: -8),
            options.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), options.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            options.heightAnchor.constraint(equalToConstant: 24), options.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16), bottom.heightAnchor.constraint(equalToConstant: 28),
            copyButton.widthAnchor.constraint(equalToConstant: 66), progress.widthAnchor.constraint(equalToConstant: 16)
        ])
        window.initialFirstResponder = textView
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func configureLanguages() {
        // A label that cannot change recognition is intentionally absent without its source image.
        guard sourceImage != nil, let languages = try? RecognitionService.supportedLanguages(), !languages.isEmpty else {
            languagePicker.isHidden = true; return
        }
        languagePicker.addItem(withTitle: "自动识别语言")
        let locale = Locale(identifier: "zh-Hans")
        for identifier in languages {
            languagePicker.addItem(withTitle: locale.localizedString(forIdentifier: identifier) ?? identifier)
            languagePicker.lastItem?.representedObject = identifier
        }
    }
    @objc private func changeLanguage() {
        guard let sourceImage, !closed else { return }
        recognitionTask?.cancel(); generation = UUID()
        let requestGeneration = generation
        let options = RecognitionOptions(language: languagePicker.selectedItem?.representedObject as? String)
        setRecognizing(true)
        recognitionTask = Task { [weak self] in
            do {
                let result = try await RecognitionService.recognize(sourceImage, options: options)
                guard !Task.isCancelled, let self, !self.closed, self.generation == requestGeneration else { return }
                self.textView.string = result.displayText; self.recognitionTask = nil; self.setRecognizing(false)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, !self.closed, self.generation == requestGeneration else { return }
                self.recognitionTask = nil; self.setRecognizing(false); showError(error)
            }
        }
    }
    private func setRecognizing(_ active: Bool) {
        textView.isEditable = !active; copyButton.isEnabled = !active; layoutPicker.isEnabled = !active
        if active { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }
    @objc private func changeDirectCopy() { defaults.set(directCopy.state == .on, forKey: Self.directCopyPreferenceKey) }
    @objc private func joinLines() { textView.string = Self.joinedLines(textView.string) }
    @objc private func removeEmptyLines() {
        textView.string = textView.string.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }
    static func joinedLines(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    @objc private func translateText() { onTranslate?(textView.string) }
    @objc private func copyAll() { Self.copyToPasteboard(textView.string); close() }
    @objc private func saveText() {
        guard !closed, exportPanel == nil, let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "识别文字.txt"
        exportPanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }; self.exportPanel = nil
            guard !self.closed, response == .OK, let url = panel?.url else { return }
            do { try self.textView.string.write(to: url, atomically: true, encoding: .utf8) } catch { showError(error) }
        }
    }
    func windowWillClose(_ notification: Notification) { finishClose() }
    override func close() { finishClose(); super.close() }
    private func finishClose() {
        guard !closed else { return }; closed = true
        generation = UUID(); recognitionTask?.cancel(); recognitionTask = nil
        exportPanel?.cancel(nil); exportPanel = nil; sourceImage = nil; onTranslate = nil
        let callback = onClose; onClose = nil; callback?()
        window?.makeFirstResponder(nil); textView.string = ""
        window?.contentView = nil; window?.delegate = nil
    }
}
