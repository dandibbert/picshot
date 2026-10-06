import AppKit
import Vision
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers

struct RecognitionResult: Sendable {
    let text: String
    let barcodes: [String]
    var document: RecognizedTextDocument? = nil
    var omittedBarcodeCount = 0
    var displayText: String {
        var parts = [text]
        if !barcodes.isEmpty { parts.append("识别码：\n" + barcodes.joined(separator: "\n")) }
        if document?.isTruncated == true { parts.append("[识别已达本机结果上限，仅显示部分文字；请裁剪图片后再识别。]") }
        if omittedBarcodeCount > 0 { parts.append("[有 \(omittedBarcodeCount) 个识别码超过数量或长度上限，已省略；未截短任何识别码内容。]") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct RecognitionOptions: Sendable, Equatable {
    /// nil selects automatic detection. Explicit identifiers must be supported by this OS.
    var language: String? = nil
    var orientation: CGImagePropertyOrientation = .up
}

enum RecognitionService {
    static func supportedLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    static func preferredLanguages(from supported: [String]) -> [String] {
        ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
    }

    private static let admission = RecognitionAdmission()
    static func resourceSnapshot() async -> RecognitionResourceSnapshot { await admission.snapshot() }

    static func recognize(_ image: CGImage, options: RecognitionOptions = RecognitionOptions()) async throws -> RecognitionResult {
        guard PinImageRenderer.allowsRasterSize(width: image.width, height: image.height) else {
            throw PicShotError.message("本地识别最多支持 3200 万像素。请先裁剪图片。")
        }
        let id = UUID()
        try await withTaskCancellationHandler(operation: { try await admission.acquire(id) }, onCancel: {
            Task { await admission.cancelWaiting(id) }
        })
        do {
            try Task.checkCancellation()
            let cancellation = RecognitionCancellation()
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
                try cancellation.install([textRequest, barcodes])
                defer { cancellation.clear() }
                try VNImageRequestHandler(cgImage: image, orientation: options.orientation, options: [:]).perform([textRequest, barcodes])
                try Task.checkCancellation()
                let document = try makeDocument(textRequest.results ?? [])
                let payloads = (barcodes.results ?? []).compactMap(\.payloadStringValue)
                let included = Array(payloads.filter { $0.utf16.count <= 4096 }.prefix(128))
                return RecognitionResult(text: document.text, barcodes: included, document: document,
                                         omittedBarcodeCount: payloads.count - included.count)
            }
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                cancellation.cancel(); task.cancel()
            })
            try Task.checkCancellation()
            await admission.release(id)
            return result
        } catch {
            await admission.release(id)
            throw error
        }
    }

    /// Stable reading rows, then left-to-right observations. Within an observation Vision's
    /// logical string (including RTL runs) is preserved; geometric sorting never rewrites it.
    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in sorted {
            if let last = rows.last, let first = last.first,
               abs(first.boundingBox.midY - observation.boundingBox.midY) <= min(first.boundingBox.height, observation.boundingBox.height) * 0.45 {
                rows[rows.count - 1].append(observation)
            } else { rows.append([observation]) }
        }
        return rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }

    private static func quad(_ rectangle: VNRectangleObservation) -> RecognizedTextQuad? {
        RecognizedTextQuad(topLeft: rectangle.topLeft, topRight: rectangle.topRight,
                           bottomRight: rectangle.bottomRight, bottomLeft: rectangle.bottomLeft)
    }

    private static func makeDocument(_ observations: [VNRecognizedTextObservation]) throws -> RecognizedTextDocument {
        var text = "", lines: [RecognizedTextLine] = [], units: [RecognizedTextUnit] = []
        var truncated = observations.count > RecognizedTextDocument.maximumLines
        for observation in readingOrder(Array(observations.prefix(RecognizedTextDocument.maximumLines))) {
            try Task.checkCancellation()
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
            let original = candidate.string
            let separator = text.isEmpty ? "" : "\n"
            var lineText = "", remaining = RecognizedTextDocument.maximumUTF16Count - text.utf16.count - separator.utf16.count
            for character in original {
                let part = String(character), count = part.utf16.count
                guard count <= remaining else { truncated = true; break }
                lineText += part; remaining -= count
            }
            guard !lineText.isEmpty else { truncated = true; break }
            if lineText != original { truncated = true }
            let sourceEnd = original.index(original.startIndex, offsetBy: lineText.count)
            let sourceRange = original.startIndex..<sourceEnd
            let base = text.utf16.count + separator.utf16.count, lineIndex = lines.count
            text += separator + lineText
            // Text stays usable in the separate result panel even if Vision cannot supply a valid box.
            guard let lineQuad = quad(observation) else { continue }
            lines.append(RecognizedTextLine(range: NSRange(location: base, length: lineText.utf16.count), quad: lineQuad))

            // NaturalLanguage supplies real String.Index ranges for scripts without spaces.
            // Include punctuation/emoji omitted by word tokenization as whole composed characters.
            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = original
            var words: [Range<String.Index>] = []
            tokenizer.enumerateTokens(in: sourceRange) { range, _ in
                words.append(range); return words.count < RecognizedTextDocument.maximumUnits
            }
            var ranges: [Range<String.Index>] = [], cursor = original.startIndex
            for word in words {
                guard ranges.count < RecognizedTextDocument.maximumUnits else { truncated = true; break }
                while cursor < word.lowerBound, ranges.count < RecognizedTextDocument.maximumUnits {
                    let end = original.index(after: cursor)
                    if !original[cursor..<end].allSatisfy({ $0.isWhitespace }) { ranges.append(cursor..<end) }
                    cursor = end
                }
                guard ranges.count < RecognizedTextDocument.maximumUnits else { truncated = true; break }
                ranges.append(word); cursor = word.upperBound
            }
            while cursor < sourceEnd, ranges.count < RecognizedTextDocument.maximumUnits {
                let end = original.index(after: cursor)
                if !original[cursor..<end].allSatisfy({ $0.isWhitespace }) { ranges.append(cursor..<end) }
                cursor = end
            }
            if cursor < sourceEnd { truncated = true }
            let before = units.count
            for range in ranges {
                try Task.checkCancellation()
                guard units.count < RecognizedTextDocument.maximumUnits else { truncated = true; break }
                guard let rectangle = try? candidate.boundingBox(for: range), let bounds = quad(rectangle) else { continue }
                let local = NSRange(range, in: original)
                let global = NSRange(location: base + local.location, length: local.length)
                // .accurate may give the same word box for multiple tokenizer ranges.
                // Merge those ranges, preserving exact intervening text, instead of guessing widths.
                if let last = units.last, last.lineIndex == lineIndex, last.quad.approximatelyEquals(bounds) {
                    units[units.count - 1].range.length = NSMaxRange(global) - last.range.location
                } else { units.append(RecognizedTextUnit(range: global, quad: bounds, lineIndex: lineIndex)) }
            }
            if units.count == before, units.count < RecognizedTextDocument.maximumUnits {
                units.append(RecognizedTextUnit(range: lines[lineIndex].range, quad: lineQuad, lineIndex: lineIndex))
            }
            if units.count >= RecognizedTextDocument.maximumUnits { truncated = true; break }
        }
        return RecognizedTextDocument(text: text, lines: lines, units: units, isTruncated: truncated)
    }
}

/// At most two Vision requests execute and four wait. Queued cancellation drops its continuation;
/// an executing job keeps its permit until Vision returns, even when the UI has closed.
struct RecognitionResourceSnapshot: Sendable {
    let activeJobs: Int
    let waitingJobs: Int
}

private actor RecognitionAdmission {
    private var active = Set<UUID>()
    private var order: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
    func snapshot() -> RecognitionResourceSnapshot { RecognitionResourceSnapshot(activeJobs: active.count, waitingJobs: waiting.count) }
    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active.count < 2 { active.insert(id); return }
        guard waiting.count < 4 else { throw PicShotError.message("本地识别正在忙碌，请稍后重试。") }
        try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation; order.append(id)
        }
    }
    func cancelWaiting(_ id: UUID) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }; continuation.resume(throwing: CancellationError())
    }
    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        while !order.isEmpty {
            let next = order.removeFirst()
            guard let continuation = waiting.removeValue(forKey: next) else { continue }
            active.insert(next); continuation.resume(); break
        }
    }
}

private final class RecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var requests: [VNRequest] = []
    func install(_ values: [VNRequest]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        requests = values
    }
    func cancel() {
        lock.lock(); cancelled = true; let values = requests; lock.unlock()
        values.forEach { $0.cancel() }
    }
    func clear() { lock.lock(); requests.removeAll(); lock.unlock() }

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
