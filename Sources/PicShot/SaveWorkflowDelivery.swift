import AppKit

enum SaveWorkflowDeliveryError: LocalizedError {
    case alreadySaving, notAdmitted

    var errorDescription: String? {
        switch self {
        case .alreadySaving: return "正在保存，请完成或取消当前保存后重试。"
        case .notAdmitted: return "无法开始保存。请完成或取消其他保存任务后重试；当前截图仍然保留。"
        }
    }
}

/// Awaits one explicitly requested PNG Save and releases only its own window.
/// Failed windows remain the decision surface until Close; all outcomes wait
/// for work drainage so publication cannot be lost to a late cancellation.
@MainActor
final class SaveWorkflowDelivery {
    typealias Present = (CGImage, NSWindow?, @escaping () -> Void) -> SaveWorkflowController?

    private final class Pending {
        var continuation: CheckedContinuation<SaveWorkflowTerminalOutcome, Never>?
        var job: SaveWorkflowController?
        var previousClose: (() -> Void)?
        var previousDrained: (() -> Void)?
        var closeObserved = false
        var drainObserved = false
        var cancellationRequested = false
        var settled = false
    }

    private let present: Present
    private var pending: Pending?

    convenience init(presenter: SaveWorkflowPresenter) {
        self.init { image, parent, onSaved in
            presenter.save(image: image, copy: false, automatic: false, from: parent,
                           onSaved: { _ in onSaved() })
        }
    }

    /// Only presentation is injectable. Encoding/publication stay in the
    /// existing workflow, and onSaved is never sufficient evidence of drainage.
    init(present: @escaping Present) { self.present = present }

    func save(image: CGImage, parent: NSWindow?) async -> SaveWorkflowTerminalOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard pending == nil else { return .failed(.operation(SaveWorkflowDeliveryError.alreadySaving)) }
        let operation = Pending()
        pending = operation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.continuation = continuation
                guard !Task.isCancelled else {
                    complete(.cancelled, operation: operation)
                    return
                }
                let job = present(image, parent) { [weak self, weak operation] in
                    guard let self, let operation else { return }
                    self.resolveDrained(operation)
                }
                guard let job else {
                    complete(.failed(.operation(SaveWorkflowDeliveryError.notAdmitted)), operation: operation)
                    return
                }
                operation.job = job
                // onPresent can close before returning the controller. Those
                // already-consumed callbacks must never be reinstalled.
                if job.state != .closed || job.onClose != nil {
                    operation.previousClose = job.onClose
                    job.onClose = { [weak self, weak operation] in
                        guard let self, let operation else { return }
                        self.closed(operation)
                    }
                }
                if !job.jobDrained {
                    operation.previousDrained = job.onDrained
                    job.onDrained = { [weak self, weak operation] in
                        guard let self, let operation else { return }
                        self.drained(operation)
                    }
                }
                if operation.cancellationRequested { job.cancel() }
                resolveDrained(operation)
            }
        } onCancel: {
            Task { @MainActor [weak self, weak operation] in
                guard let self, let operation else { return }
                self.cancel(operation)
            }
        }
    }

    func cancel() {
        guard let pending else { return }
        cancel(pending)
    }

    private func cancel(_ operation: Pending) {
        guard pending === operation, !operation.settled else { return }
        operation.cancellationRequested = true
        operation.job?.cancel()
        resolveDrained(operation)
    }

    private func closed(_ operation: Pending) {
        guard !operation.closeObserved, operation.job?.state == .closed else { return }
        operation.closeObserved = true
        let previous = operation.previousClose
        operation.previousClose = nil
        previous?()
        resolveDrained(operation)
    }

    private func drained(_ operation: Pending) {
        guard !operation.drainObserved, operation.job?.jobDrained == true else { return }
        operation.drainObserved = true
        let previous = operation.previousDrained
        operation.previousDrained = nil
        previous?()
        resolveDrained(operation)
    }

    private func resolveDrained(_ operation: Pending) {
        guard pending === operation, !operation.settled,
              let job = operation.job, let outcome = job.terminalOutcome else { return }
        switch outcome {
        case .committed:
            complete(outcome, operation: operation)
        case .cancelled, .failed:
            guard job.state == .closed else { return }
            complete(outcome, operation: operation)
        }
    }

    private func complete(_ outcome: SaveWorkflowTerminalOutcome, operation: Pending) {
        guard pending === operation, !operation.settled else { return }
        operation.settled = true
        let job = operation.job
        // cancel() drains an unstarted job before taking its onClose callback.
        // Restore that still-live callback even if state is already .closed.
        if let job, !operation.closeObserved { job.onClose = operation.previousClose }
        // A drained callback is consumed by the controller. Never resurrect it.
        if let job, !job.jobDrained { job.onDrained = operation.previousDrained }
        operation.job = nil
        operation.previousClose = nil
        operation.previousDrained = nil
        pending = nil
        let continuation = operation.continuation
        operation.continuation = nil
        // Retire identity before native Close calls can synchronously reenter.
        if case .committed = outcome, let job, job.state != .closed { job.cancel() }
        continuation?.resume(returning: outcome)
    }
}
