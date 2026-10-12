import AppKit
import PicShotTextScriptCore
import PicShotTextScriptProcess

enum ChainTextPhase: Equatable { case recognize, transform, copy }

/// Diagnostics deliberately cannot carry source, OCR, returned text or an Error.
enum ChainTextFailure: Error, Equatable {
    case captureFailed, recognitionFailed, emptyRecognition, truncatedRecognition, oversizedRecognition
    case emptyOutput, oversizedOutput, clipboardRejected, invalidResult
    case script(TextScriptDiagnostic), runtime(TextScriptProcessOutcome)

    var message: String {
        switch self {
        case .captureFailed: return "区域截图未完成，请重新运行。"
        case .recognitionFailed: return "文字识别未完成，请重试。"
        case .emptyRecognition: return "未识别到文字，请取消后重新选择区域。"
        case .truncatedRecognition: return "识别结果被截断，请取消后选择更小的区域。"
        case .oversizedRecognition: return "识别文字超过限制，请取消后选择更小的区域。"
        case .emptyOutput: return "脚本返回了空文字，剪贴板未更改。"
        case .oversizedOutput: return "脚本返回的文字超过限制，剪贴板未更改。"
        case .clipboardRejected: return "无法将文字写入剪贴板，请重试。"
        case .invalidResult: return "脚本返回了无效结果，剪贴板未更改。"
        case .script(let diagnostic): return "脚本未完成（" + diagnostic.rawValue + "），剪贴板未更改。"
        case .runtime(let outcome): return "脚本运行未完成（" + outcome.rawValue + "），剪贴板未更改。"
        }
    }
}

struct ChainTextRecognition {
    let text: String
    let truncated: Bool
    init(text: String, truncated: Bool = false) { self.text = text; self.truncated = truncated }
}

enum ChainTextTransformResult {
    case succeeded(String)
    case failed(ChainTextFailure, cleanupPending: Bool)
    case cancelled(cleanupPending: Bool)
}

struct ChainTextCopyReceipt: Equatable {
    let characterCount: Int
}

/// One instance belongs to one runner. Only a result from our execute call can
/// establish cleanup ownership; an occupied global service is never borrowed.
@MainActor final class CaptureChainTextRuntime {
    private let service: TextScriptProcessService
    private let onMetrics: ((TextScriptProcessMetrics) -> Void)?
    private var pendingCleanupID: UUID?
    private var executing = false

    init(service: TextScriptProcessService = .shared, onMetrics: ((TextScriptProcessMetrics) -> Void)? = nil) {
        self.service = service; self.onMetrics = onMetrics
    }

    func transform(source: String, text: String, requestID: UUID) async -> ChainTextTransformResult {
        guard !executing, pendingCleanupID == nil else {
            return .failed(.runtime(.busy), cleanupPending: false)
        }
        executing = true
        let request = TextScriptRequest.transform(requestID: requestID, source: source, text: text)
        let result = await service.execute(request)
        executing = false
        // A busy result never acquired the service reservation. Every other
        // result owns its request until the service explicitly releases it.
        let pending = result.metrics.outcome != .busy && !result.metrics.admissionReleased
        if pending { pendingCleanupID = requestID }
        onMetrics?(result.metrics)
        guard result.metrics.requestID == requestID else {
            return .failed(.invalidResult, cleanupPending: pending)
        }
        if result.metrics.outcome == .cancelled { return .cancelled(cleanupPending: pending) }
        guard !pending else { return .failed(.runtime(result.metrics.outcome), cleanupPending: true) }
        switch result.metrics.outcome {
        case .succeeded:
            guard result.metrics.childExitConfirmed, result.metrics.pipesDrained,
                  let response = result.response,
                  (try? response.validate(for: request)) != nil,
                  response.status == .success, let output = response.output else {
                return .failed(.invalidResult, cleanupPending: false)
            }
            return .succeeded(output)
        case .helperRejected:
            guard let response = result.response, (try? response.validate(for: request)) != nil,
                  response.status == .failure, let diagnostic = response.diagnostic else {
                return .failed(.invalidResult, cleanupPending: false)
            }
            return .failed(.script(diagnostic), cleanupPending: false)
        default: return .failed(.runtime(result.metrics.outcome), cleanupPending: false)
        }
    }

    func cleanupComplete(requestID: UUID) -> Bool {
        guard pendingCleanupID == requestID, !executing else { return false }
        let snapshot = TextScriptProcessService.snapshot()
        // snapshot() may observe this owned helper exit and pipe EOFs. No late
        // output is returned or accepted, and another request never counts as
        // our release acknowledgement.
        guard !snapshot.occupied else { return false }
        pendingCleanupID = nil
        return true
    }
}

/// The only text clipboard writer for this route. Validation precedes clearing;
/// a true setString acknowledgement is required before a receipt can exist.
enum CheckedTextClipboard {
    static func validate(_ text: String) throws {
        guard !text.isEmpty else { throw ChainTextFailure.emptyOutput }
        guard text.utf16.count <= TextScriptLimits.outputUTF16Units,
              text.utf8.count <= TextScriptLimits.outputUTF8Bytes else { throw ChainTextFailure.oversizedOutput }
    }

    @MainActor static func copy(_ text: String) throws { try copy(text, pasteboard: .general) }

    @MainActor static func copy(_ text: String, pasteboard: NSPasteboard,
                               writer: (NSPasteboard, String) -> Bool = { $0.setString($1, forType: .string) }) throws {
        try validate(text)
        pasteboard.clearContents()
        guard writer(pasteboard, text) else { throw ChainTextFailure.clipboardRejected }
    }
}
