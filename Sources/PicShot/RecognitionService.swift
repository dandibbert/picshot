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
    var barcodeDocument: RecognizedBarcodeDocument? = nil
    var displayText: String {
        var parts = [text]
        if !barcodes.isEmpty { parts.append("识别码：\n" + barcodes.joined(separator: "\n")) }
        if document?.isTruncated == true { parts.append("[识别已达本机结果上限，仅显示部分文字；请裁剪图片后再识别。]") }
        if omittedBarcodeCount > 0 { parts.append("[有 \(omittedBarcodeCount) 个识别码因结果上限或缺少可用文本而省略；未截短任何已列出的识别码内容。]") }
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

    static func supportedBarcodeSymbologies() throws -> [BarcodeSymbology] {
        try VNDetectBarcodesRequest().supportedSymbologies().map(BarcodeSymbology.init)
    }

    static func recognizeBarcodes(_ image: CGImage, options: RecognitionOptions = RecognitionOptions()) async throws -> RecognizedBarcodeDocument {
        let result = try await performRecognition(image, options: options, includeText: false)
        guard let document = result.barcodeDocument else { throw PicShotError.message("条码识别未返回结果。") }
        return document
    }

    static func recognize(_ image: CGImage, options: RecognitionOptions = RecognitionOptions()) async throws -> RecognitionResult {
        try await performRecognition(image, options: options, includeText: true)
    }

    private static func performRecognition(_ image: CGImage, options: RecognitionOptions, includeText: Bool) async throws -> RecognitionResult {
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
                if includeText {
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
                }
                let barcodes = VNDetectBarcodesRequest()
                let supported = try barcodes.supportedSymbologies()
                barcodes.symbologies = supported
                let requests: [VNRequest] = includeText ? [textRequest, barcodes] : [barcodes]
                try cancellation.install(requests)
                defer { cancellation.clear() }
                try VNImageRequestHandler(cgImage: image, orientation: options.orientation, options: [:]).perform(requests)
                try Task.checkCancellation()
                let document = includeText ? try makeDocument(textRequest.results ?? []) : nil
                let codes = makeBarcodeDocument(barcodes.results ?? [], supported: supported)
                return RecognitionResult(text: document?.text ?? "", barcodes: codes.results.map(\.payload), document: document,
                                         omittedBarcodeCount: codes.omittedCount, barcodeDocument: codes)
            }
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                cancellation.cancel(); task.cancel()
            })
            try Task.checkCancellation()
            await admission.release(id)
            return result
        } catch {
            await admission.release(id)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func makeBarcodeDocument(_ observations: [VNBarcodeObservation], supported: [VNBarcodeSymbology]) -> RecognizedBarcodeDocument {
        var missingText = 0
        let candidates = observations.sorted {
            let leftY = $0.boundingBox.midY, rightY = $1.boundingBox.midY
            let leftRow = leftY.isFinite ? Int((min(1, max(0, leftY)) * 50).rounded()) : 0
            let rightRow = rightY.isFinite ? Int((min(1, max(0, rightY)) * 50).rounded()) : 0
            if leftRow != rightRow { return leftRow > rightRow }
            if $0.boundingBox.minX != $1.boundingBox.minX { return $0.boundingBox.minX < $1.boundingBox.minX }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }.compactMap { observation -> RecognizedBarcode? in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { missingText += 1; return nil }
            return RecognizedBarcode(id: observation.uuid, symbology: BarcodeSymbology(observation.symbology), payload: payload,
                                     quad: quad(observation))
        }
        return RecognizedBarcodeDocument(candidates: candidates, supportedSymbologies: supported.map(BarcodeSymbology.init), missingTextCount: missingText)
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

@MainActor final class TextResultController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    typealias RecognitionProvider = @MainActor (RecognitionOptions) async throws -> RecognitionResult
    static let directCopyPreferenceKey = "ocr.copyDirectlyNextTime"
    static var copyDirectlyNextTime: Bool { UserDefaults.standard.bool(forKey: directCopyPreferenceKey) }
    static func copyToPasteboard(_ text: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }

    var onClose: (() -> Void)?
    /// Bind with a weak pin capture and its image revision; this callback never activates a window.
    var onSourceSelection: ((RecognizedTextDocument, [NSRange]) -> Void)?
    private let textView = NSTextView()
    private let languagePicker = NSPopUpButton()
    private let layoutPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let directCopy = NSButton(checkboxWithTitle: "下次直接复制文本", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let sourceStatus = NSTextField(labelWithString: "原图关联已暂停")
    private let sourceButton = NSButton(title: "原图", target: nil, action: nil)
    private let sourcePreview = TextResultSourcePreview()
    private var projection: RecognizedTextProjection
    private var synchronizingSelection = false
    private var replacingText = false
    private var onRecognize: RecognitionProvider?
    private var recognitionOptions: RecognitionOptions
    private var onTranslate: ((String) -> Void)?
    private var onBarcodes: (() -> Void)?
    private var sourceImage: CGImage?
    private let defaults: UserDefaults?
    private var recognitionTask: Task<Void, Never>?
    private var generation = UUID()
    private var exportPanel: NSSavePanel?
    private var closed = false
    var resultText: String { textView.string }
    var offersLanguageSelection: Bool { !languagePicker.isHidden }
    var resultDocument: RecognizedTextDocument? { projection.document }
    var selectedSourceRanges: [NSRange] { projection.sourceRanges(for: textView.selectedRanges.map(\.rangeValue)) }
    var sourceLinkingLimitReached: Bool { projection.mappingLimitReached }
    var isSourcePreviewVisible: Bool { !sourcePreview.isHidden }

    convenience init(result: RecognitionResult, title: String = "识别文字", sourceImage: CGImage? = nil,
                     options: RecognitionOptions = RecognitionOptions(), onRecognize: RecognitionProvider? = nil,
                     onTranslate: ((String) -> Void)? = nil, onBarcodes: (() -> Void)? = nil, defaults: UserDefaults? = .standard) {
        // Geometry is valid only for the exact OCR prefix, never for barcode/status appendices.
        let document = result.document.flatMap { $0.text.utf16.elementsEqual(result.text.utf16) ? $0 : nil }
        self.init(text: result.displayText, title: title, sourceImage: sourceImage, document: document,
                  options: options, onRecognize: onRecognize, onTranslate: onTranslate, onBarcodes: onBarcodes, defaults: defaults)
    }

    init(text: String, title: String = "识别文字", sourceImage: CGImage? = nil,
         document: RecognizedTextDocument? = nil, options: RecognitionOptions = RecognitionOptions(), onRecognize: RecognitionProvider? = nil,
         onTranslate: ((String) -> Void)? = nil, onBarcodes: (() -> Void)? = nil, defaults: UserDefaults? = .standard) {
        self.onTranslate = onTranslate; self.onBarcodes = onBarcodes; self.sourceImage = sourceImage; self.defaults = defaults
        self.onRecognize = onRecognize; recognitionOptions = options
        projection = RecognizedTextProjection(text: text, document: document)
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
        textView.delegate = self; textView.textStorage?.delegate = self
        sourcePreview.image = sourceImage; sourcePreview.orientation = options.orientation; sourcePreview.overlay.document = document
        sourcePreview.isHidden = true
        sourcePreview.overlay.onSelectionChange = { [weak self] ranges in
            guard let self, !self.closed, !self.synchronizingSelection, let document = self.projection.document else { return }
            self.selectSourceRanges(ranges, document: document)
            self.onSourceSelection?(document, ranges)
        }
        sourcePreview.overlay.onExit = { [weak self] in self?.setSourcePreviewVisible(false) }
        sourceButton.controlSize = .small; sourceButton.bezelStyle = .inline
        sourceButton.setButtonType(.toggle); sourceButton.target = self; sourceButton.action = #selector(toggleSourcePreview)
        sourceButton.setAccessibilityLabel("显示或隐藏原图文字位置")
        sourceButton.isHidden = sourceImage == nil || document == nil
        sourceStatus.font = .systemFont(ofSize: 10); sourceStatus.textColor = .secondaryLabelColor
        sourceStatus.toolTip = "编辑内容超过原图关联上限（131072 个 UTF-16 单元或 4096 段），文本仍可编辑和复制；重新识别可恢复关联。"
        sourceStatus.setAccessibilityLabel("编辑内容超过上限，原图关联已暂停")
        sourceStatus.isHidden = !projection.mappingLimitReached

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
        let options = NSStackView(views: [languagePicker, progress, sourceButton, sourceStatus, NSView(), layoutPicker])
        options.orientation = .horizontal; options.spacing = 6

        directCopy.controlSize = .small; directCopy.target = self; directCopy.action = #selector(changeDirectCopy)
        directCopy.state = (defaults?.bool(forKey: Self.directCopyPreferenceKey) ?? false) ? .on : .off
        directCopy.toolTip = "以后识别成功后直接复制；可在贴图的“识别”菜单中关闭"
        let more = NSPopUpButton(frame: .zero, pullsDown: true); more.controlSize = .small; more.bezelStyle = .inline
        more.addItem(withTitle: "更多")
        more.menu?.addItem(withTitle: "导出文本…", action: #selector(saveText), keyEquivalent: "").target = self
        if onBarcodes != nil { more.menu?.addItem(withTitle: "二维码 / 条码结果…", action: #selector(showBarcodes), keyEquivalent: "").target = self }
        if onTranslate != nil { more.menu?.addItem(withTitle: "翻译…", action: #selector(translateText), keyEquivalent: "").target = self }
        copyButton.target = self; copyButton.action = #selector(copyAll); copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"; copyButton.setAccessibilityLabel("复制识别文本")
        let bottom = NSStackView(views: [directCopy, NSView(), more, copyButton]); bottom.orientation = .horizontal; bottom.spacing = 8
        let body = NSStackView(views: [scroll, sourcePreview]); body.orientation = .horizontal
        body.alignment = .top; body.spacing = 8; body.detachesHiddenViews = true
        scroll.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        sourcePreview.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        sourcePreview.translatesAutoresizingMaskIntoConstraints = false
        sourcePreview.widthAnchor.constraint(equalToConstant: 260).isActive = true
        for view in [body, options, bottom] { root.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            body.bottomAnchor.constraint(equalTo: options.topAnchor, constant: -8),
            options.leadingAnchor.constraint(equalTo: body.leadingAnchor), options.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            options.heightAnchor.constraint(equalToConstant: 24), options.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: body.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16), bottom.heightAnchor.constraint(equalToConstant: 28),
            copyButton.widthAnchor.constraint(equalToConstant: 66), progress.widthAnchor.constraint(equalToConstant: 16)
        ])
        window.initialFirstResponder = textView
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func configureLanguages() {
        // Language selection is available for a retained image or an injected shared session.
        guard sourceImage != nil || onRecognize != nil, let languages = try? RecognitionService.supportedLanguages(), !languages.isEmpty else {
            languagePicker.isHidden = true; return
        }
        languagePicker.addItem(withTitle: "自动识别语言")
        let locale = Locale(identifier: "zh-Hans")
        for identifier in languages {
            languagePicker.addItem(withTitle: locale.localizedString(forIdentifier: identifier) ?? identifier)
            languagePicker.lastItem?.representedObject = identifier
        }
        if let language = recognitionOptions.language,
           let index = languagePicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == language }) { languagePicker.selectItem(at: index) }
    }
    @objc private func changeLanguage() {
        guard !closed else { return }
        let provider: RecognitionProvider
        if let onRecognize { provider = onRecognize }
        else if let sourceImage { provider = { try await RecognitionService.recognize(sourceImage, options: $0) } }
        else { return }
        recognitionTask?.cancel(); generation = UUID()
        let requestGeneration = generation
        recognitionOptions.language = languagePicker.selectedItem?.representedObject as? String
        let options = recognitionOptions
        setRecognizing(true)
        recognitionTask = Task { [weak self] in
            do {
                let result = try await provider(options)
                guard !Task.isCancelled, let self, !self.closed, self.generation == requestGeneration else { return }
                self.install(result); self.recognitionTask = nil; self.setRecognizing(false)
            } catch is CancellationError {
                guard let self, !self.closed, self.generation == requestGeneration else { return }
                self.recognitionTask = nil; self.setRecognizing(false)
            } catch {
                guard !Task.isCancelled, let self, !self.closed, self.generation == requestGeneration else { return }
                self.recognitionTask = nil; self.setRecognizing(false); showError(error)
            }
        }
    }
    private func setRecognizing(_ active: Bool) {
        textView.isEditable = !active; copyButton.isEnabled = !active; layoutPicker.isEnabled = !active
        if active { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }
    @objc private func changeDirectCopy() { defaults?.set(directCopy.state == .on, forKey: Self.directCopyPreferenceKey) }
    @objc private func joinLines() { synchronizeText(); projection.joinLines(); installProjectedText() }
    @objc private func removeEmptyLines() { synchronizeText(); projection.removeEmptyLines(); installProjectedText() }
    static func joinedLines(_ text: String) -> String {
        var projection = RecognizedTextProjection(text: text); projection.joinLines(); return projection.text
    }

    /// Used by shared pin sessions and by explicit language reruns. No window activation or copy.
    func applyRecognitionResult(_ result: RecognitionResult) {
        guard !closed else { return }
        generation = UUID(); recognitionTask?.cancel(); recognitionTask = nil; setRecognizing(false)
        install(result)
    }
    private func install(_ result: RecognitionResult) {
        let document = result.document.flatMap { $0.text.utf16.elementsEqual(result.text.utf16) ? $0 : nil }
        projection = RecognizedTextProjection(text: result.displayText, document: document)
        synchronizingSelection = true
        sourcePreview.overlay.document = document
        synchronizingSelection = false
        sourceButton.isHidden = sourceImage == nil || document == nil
        if sourceButton.isHidden { setSourcePreviewVisible(false) }
        installProjectedText()
    }
    private func installProjectedText() {
        replacingText = true; synchronizingSelection = true
        textView.string = projection.text; textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        replacingText = false; synchronizingSelection = false
        sourceStatus.isHidden = !projection.mappingLimitReached
        publishSelection()
    }
    private func synchronizeText() {
        if !projection.text.utf16.elementsEqual(textView.string.utf16) { projection.invalidate(to: textView.string) }
    }
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard !closed, !replacingText, editedMask.contains(.editedCharacters) else { return }
        let current = textStorage.string, newLength = current.utf16.count
        if projection.mappingLimitReached || newLength > RecognizedTextProjection.maximumMappedUTF16Count {
            projection.invalidate(to: current); publishSelection(); return
        }
        let oldLength = editedRange.length - delta
        guard editedRange.location >= 0, editedRange.length >= 0, editedRange.location <= newLength,
              editedRange.length <= newLength - editedRange.location, oldLength >= 0 else {
            projection.invalidate(to: current); return
        }
        let replacement = (current as NSString).substring(with: editedRange)
        if !projection.replace(NSRange(location: editedRange.location, length: oldLength), with: replacement) ||
            !projection.text.utf16.elementsEqual(current.utf16) { projection.invalidate(to: current) }
        // TextKit can adjust selection after this delegate; selection notification publishes later.
        sourcePreview.overlay.setLinkedSelection([])
        if let document = projection.document { onSourceSelection?(document, []) }
    }
    func textViewDidChangeSelection(_ notification: Notification) { publishSelection() }
    func textDidChange(_ notification: Notification) { synchronizeText(); publishSelection() }
    private func publishSelection() {
        guard !closed, !synchronizingSelection else { return }
        synchronizeText()
        sourceStatus.isHidden = !projection.mappingLimitReached
        let ranges = selectedSourceRanges
        sourcePreview.overlay.setLinkedSelection(ranges)
        if let document = projection.document { onSourceSelection?(document, ranges) }
    }
    /// Accepts only the exact document currently displayed. A stale pin revision cannot relink it.
    func selectSourceRanges(_ ranges: [NSRange], document: RecognizedTextDocument) {
        guard !closed, !synchronizingSelection, projection.document == document else { return }
        synchronizeText()
        let output = projection.outputRanges(for: ranges)
        synchronizingSelection = true
        textView.setSelectedRanges((output.isEmpty ? [NSRange(location: 0, length: 0)] : output).map { NSValue(range: $0) },
                                   affinity: .downstream, stillSelecting: false)
        if let first = output.first { textView.scrollRangeToVisible(first) }
        sourcePreview.overlay.setLinkedSelection(projection.sourceRanges(for: output))
        synchronizingSelection = false
    }
    @objc private func toggleSourcePreview() { setSourcePreviewVisible(!isSourcePreviewVisible) }
    func setSourcePreviewVisible(_ visible: Bool) {
        let show = visible && sourceImage != nil && projection.document != nil && !closed
        guard show != isSourcePreviewVisible else { return }
        sourcePreview.isHidden = !show; sourceButton.state = show ? .on : .off
        if let window {
            var frame = window.frame
            frame.size.width = max(show ? 658 : 390, frame.width + (show ? 268 : -268))
            window.contentMinSize = NSSize(width: show ? 658 : 390, height: 260)
            window.setFrame(frame, display: true)
        }
    }
    @objc private func showBarcodes() { guard !closed else { return }; onBarcodes?() }
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
        exportPanel?.cancel(nil); exportPanel = nil; sourceImage = nil; onTranslate = nil; onBarcodes = nil; onRecognize = nil
        if let document = projection.document { onSourceSelection?(document, []) }
        onSourceSelection = nil
        sourcePreview.releaseResources()
        textView.delegate = nil; textView.textStorage?.delegate = nil
        projection = RecognizedTextProjection(text: "")
        let callback = onClose; onClose = nil; callback?()
        window?.makeFirstResponder(nil); textView.string = ""
        window?.contentView = nil; window?.delegate = nil
    }
}


/// Small optional result-window preview. Geometry, hit testing, keyboard and drag behavior
/// remain in PinTextSelectionOverlay, shared with the existing pin selection surface.
@MainActor private final class TextResultSourcePreview: NSView {
    var image: CGImage? { didSet { needsLayout = true; needsDisplay = true } }
    var orientation: CGImagePropertyOrientation = .up { didSet { needsLayout = true; needsDisplay = true } }
    let overlay = PinTextSelectionOverlay()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); addSubview(overlay)
        setAccessibilityLabel("识别文字原图")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layout() {
        super.layout(); overlay.frame = bounds
        guard let image else { overlay.imageRect = .zero; return }
        let swapsAxes: Bool
        switch orientation { case .left, .right, .leftMirrored, .rightMirrored: swapsAxes = true; default: swapsAxes = false }
        let width = CGFloat(swapsAxes ? image.height : image.width), height = CGFloat(swapsAxes ? image.width : image.height)
        let scale = min(bounds.width / width, bounds.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        overlay.imageRect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = overlay.imageRect
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: rect.width, y: rect.height)
        // Orient during drawing, keeping a single retained raster and Vision's oriented coordinates.
        let transform: CGAffineTransform
        switch orientation {
        case .up: transform = .identity
        case .upMirrored: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
        case .down: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case .downMirrored: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        case .leftMirrored: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)
        case .right: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        case .rightMirrored: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        @unknown default: transform = .identity
        }
        context.concatenate(transform); context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    func releaseResources() { image = nil; overlay.releaseResources(); overlay.removeFromSuperview() }
}
