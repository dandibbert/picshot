import AppKit
import Vision

struct RecognitionResult: Sendable { let text: String; let barcodes: [String] }
enum RecognitionService {
    static func recognize(_ image: CGImage) async throws -> RecognitionResult {
        try await Task.detached(priority: .userInitiated) {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let barcodes = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([textRequest, barcodes])
            try Task.checkCancellation()
            let observations = (textRequest.results ?? []).sorted { a,b in
                if abs(a.boundingBox.midY-b.boundingBox.midY) > 0.015 { return a.boundingBox.midY > b.boundingBox.midY }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return RecognitionResult(text: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"), barcodes: (barcodes.results ?? []).compactMap(\.payloadStringValue))
        }.value
    }
}

@MainActor final class TextResultController: NSWindowController {
    private let textView = NSTextView()
    private let onTranslate: ((String)->Void)?
    init(text: String, title: String = "识别文字", onTranslate: ((String)->Void)? = nil) {
        self.onTranslate=onTranslate
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 600,height: 430), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = title; window.isReleasedWhenClosed = false; window.center()
        let root = NSView(); window.contentView = root
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        textView.isRichText = false; textView.font = .systemFont(ofSize: 15); textView.string = text; textView.isVerticallyResizable = true; textView.textContainerInset = NSSize(width: 16,height: 16); textView.autoresizingMask = [.width]
        scroll.documentView = textView
        let copy = NSButton(title:"复制全部",target:self,action:#selector(copyAll)); let save = NSButton(title:"导出文本…",target:self,action:#selector(saveText))
        let note = NSTextField(labelWithString:"本机 Apple Vision · 请核对识别结果")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11)
        let translate = NSButton(title:"翻译…",target:self,action:#selector(translateText));translate.isHidden = onTranslate == nil
        let bar = NSStackView(views:[note, NSView(), translate, save, copy]); bar.orientation = .horizontal
        root.addSubview(scroll); root.addSubview(bar); scroll.translatesAutoresizingMaskIntoConstraints=false; bar.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo:root.topAnchor),scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:bar.topAnchor,constant:-8),bar.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),bar.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),bar.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-12),bar.heightAnchor.constraint(equalToConstant:28)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc private func translateText(){onTranslate?(textView.string)}
    @objc private func copyAll(){ NSPasteboard.general.clearContents(); NSPasteboard.general.setString(textView.string,forType:.string) }
    @objc private func saveText(){ let panel=NSSavePanel(); panel.allowedContentTypes=[.plainText]; panel.nameFieldStringValue="识别文字.txt"; if panel.runModal() == .OK, let url=panel.url { do { try textView.string.write(to:url,atomically:true,encoding:.utf8) } catch { showError(error) } } }
}
