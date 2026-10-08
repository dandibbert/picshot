import AppKit
import PicShotCore

struct PendingCapture: @unchecked Sendable {
    let id = UUID()
    let image: CGImage
    let capturedAt: Date
    let title: String
    let encodedBackingBytes: Int
    let retainedBytes: Int

    init(_ result: CapturedImage, title: String) throws {
        guard let bytes = CaptureRecoveryPolicy.retainedBytes(
            rasterBytes: EditorRasterEstimate.retainedBytes([result.image]), encodedBytes: result.encodedBackingBytes) else {
            throw CaptureRecoveryError.unsupportedBacking
        }
        // Never retain result/presentation: a region crop already owns detached
        // selected pixels, and only presentation owns its full frozen desktop.
        image = result.image; capturedAt = result.capturedAt; self.title = title
        encodedBackingBytes = result.encodedBackingBytes; retainedBytes = bytes
    }
}

enum CaptureRecoveryError: LocalizedError {
    case unsupportedBacking, alreadyPending, writeFailed, destinationExists, encodedLimit
    var errorDescription: String? {
        switch self {
        case .unsupportedBacking: return "截图格式超出保留上限（像素存储 512 MiB、编码数据 128 MiB）。请缩小截图或使用较低位深；本次截图未完成。"
        case .alreadyPending: return "请先保存、重新编辑或明确放弃上一张未保存截图。"
        case .writeFailed: return "图片未保存。原始截图仍已保留，请检查磁盘或选择其他位置后重试。"
        case .destinationExists: return "该位置已有文件。原始截图已保留，请选择一个新文件名。"
        case .encodedLimit: return "PNG 超出 640 MiB 文件上限。原始截图仍已保留，可重试编辑或选择其他保存位置。"
        }
    }
}

/// Single owner and handoff fence. UI dismissal/cancellation never removes pixels;
/// only a successful editor handoff, committed file, or explicit discard can do so.
@MainActor final class PendingCaptureRecovery {
    private(set) var pending: PendingCapture?
    private(set) var isSaving = false
    private(set) var message = ""
    var didChange: (() -> Void)?
    var retainedBytes: Int { pending?.retainedBytes ?? 0 }
    var blocksCapture: Bool { pending != nil }

    func retain(_ capture: PendingCapture, error: Error) throws {
        guard pending == nil else { throw CaptureRecoveryError.alreadyPending }
        pending = capture; message = error.localizedDescription; didChange?()
    }

    @discardableResult func retryEditor(_ open: (PendingCapture) -> Bool) -> Bool {
        guard !isSaving, let pending else { return false }
        guard open(pending) else {
            message = "暂时无法打开编辑器。请先关闭其他编辑窗口后重试，或保存为 PNG。"; didChange?(); return false
        }
        self.pending = nil; message = "已交给编辑器"; didChange?(); return true
    }

    func beginSave() -> PendingCapture? {
        guard !isSaving, let pending else { return nil }
        isSaving = true; message = "正在保存…关闭此窗口不会放弃原图。"; didChange?(); return pending
    }

    func finishSave(id: UUID, result: Result<URL, Error>) {
        guard isSaving, let pending, pending.id == id else { return }
        isSaving = false
        switch result {
        case .success(let url): self.pending = nil; message = "已保存到 \(url.path)"
        case .failure(let error):
            message = error is CancellationError ? "保存已取消，原始截图仍已保留。" : error.localizedDescription
        }
        didChange?()
    }

    func savePickerCancelled() {
        guard pending != nil, !isSaving else { return }
        message = "保存已取消，原始截图仍已保留。"; didChange?()
    }

    @discardableResult func discard() -> Bool {
        guard !isSaving, pending != nil else { return false }
        pending = nil; message = "已放弃未保存的截图"; didChange?(); return true
    }
}

/// Production completion and injected failure tests use the same transaction:
/// history success is independent of editor success, with one durable owner needed.
@MainActor enum CaptureCompletion {
    enum Outcome: Equatable { case editor, history, pending }
    static func finish(_ result: CapturedImage, title: String, recovery: PendingCaptureRecovery,
                       saveHistory: (CapturedImage, String) throws -> Void,
                       openEditor: (CapturedImage) -> Bool,
                       reportHistoryError: (Error) -> Void) throws -> Outcome {
        guard !recovery.blocksCapture else { throw CaptureRecoveryError.alreadyPending }
        let candidate = try PendingCapture(result, title: title)
        var historyError: Error?
        do { try saveHistory(result, title) } catch { historyError = error }
        if openEditor(result) {
            if let historyError { reportHistoryError(historyError) }
            return .editor
        }
        guard let historyError else { return .history }
        try recovery.retain(candidate, error: historyError)
        return .pending
    }
}
