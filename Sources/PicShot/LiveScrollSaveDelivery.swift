import AppKit

@MainActor
protocol LiveScrollSaveDestination: AnyObject {
    func save(image: CGImage, parent: NSWindow?) async throws
    func cancel()
}

enum LiveScrollSaveDeliveryError: LocalizedError {
    case alreadySaving, notAdmitted

    var errorDescription: String? {
        switch self {
        case .alreadySaving: return "长图正在保存，请完成或取消当前保存后重试。"
        case .notAdmitted: return "无法开始保存长图。请完成或取消其他保存任务后重试；长图草稿仍然保留。"
        }
    }
}

/// Admission is not delivery: the draft owner awaits the existing workflow's
/// successful publication callback. A failed Save window remains the decision
/// surface until it closes. Closing an active job waits for drainage so a file
/// committed before cancellation is still reported as successfully delivered.
@MainActor
final class LiveScrollSaveDelivery: LiveScrollSaveDestination {
    typealias Present = (CGImage, NSWindow?, @escaping () -> Void) -> SaveWorkflowController?

    private final class Pending {
        var continuation: CheckedContinuation<Void, Error>?
        var job: SaveWorkflowController?
        var previousClose: (() -> Void)?
        var previousDrained: (() -> Void)?
        var cancellationRequested = false
        var outcome: Result<Void, Error>?
    }

    private let present: Present
    private var pending: Pending?

    convenience init(presenter: SaveWorkflowPresenter) {
        self.init { image, parent, onSaved in
            presenter.save(image: image, copy: false, automatic: false, from: parent,
                           onSaved: { _ in onSaved() })
        }
    }

    /// A presentation-only seam permits deterministic callback-order tests;
    /// all production encoding and publication remain in SaveWorkflowPresenter.
    init(present: @escaping Present) { self.present = present }

    func save(image: CGImage, parent: NSWindow?) async throws {
        try Task.checkCancellation()
        guard pending == nil else { throw LiveScrollSaveDeliveryError.alreadySaving }
        let operation = Pending()
        pending = operation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.continuation = continuation
                guard !Task.isCancelled else {
                    complete(.failure(CancellationError()), operation: operation)
                    return
                }
                let job = present(image, parent) { [weak self, weak operation] in
                    guard let self, let operation, !operation.cancellationRequested else { return }
                    self.complete(.success(()), operation: operation)
                }
                // Success may arrive synchronously. Reentrant cancellation must
                // first receive the returned job and observe its actual outcome.
                guard operation.outcome == nil else { return }
                guard let job else {
                    let error: Error = operation.cancellationRequested
                        ? CancellationError() : LiveScrollSaveDeliveryError.notAdmitted
                    complete(.failure(error), operation: operation)
                    return
                }
                operation.job = job
                if job.state != .closed {
                    let previousClose = job.onClose
                    operation.previousClose = previousClose
                    job.onClose = { [weak self, weak operation] in
                        if let self, let operation {
                            operation.cancellationRequested = true
                            self.resolveDrained(operation)
                        }
                        previousClose?()
                    }
                } else { operation.cancellationRequested = true }
                if !job.jobDrained {
                    let previousDrained = job.onDrained
                    operation.previousDrained = previousDrained
                    job.onDrained = { [weak self, weak operation] in
                        if let self, let operation {
                            operation.previousDrained = nil
                            self.resolveDrained(operation)
                        }
                        previousDrained?()
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
        guard pending === operation else { return }
        operation.cancellationRequested = true
        operation.job?.cancel()
        resolveDrained(operation)
    }

    private func resolveDrained(_ operation: Pending) {
        guard pending === operation, let job = operation.job, job.jobDrained else { return }
        if job.result != nil {
            complete(.success(()), operation: operation)
        } else if operation.cancellationRequested || job.state == .closed {
            complete(.failure(CancellationError()), operation: operation)
        }
    }

    private func complete(_ outcome: Result<Void, Error>, operation: Pending) {
        guard pending === operation, operation.outcome == nil else { return }
        operation.outcome = outcome
        if let job = operation.job {
            if job.state != .closed { job.onClose = operation.previousClose }
            if !job.jobDrained { job.onDrained = operation.previousDrained }
        }
        operation.job = nil
        operation.previousClose = nil
        operation.previousDrained = nil
        pending = nil
        let continuation = operation.continuation
        operation.continuation = nil
        continuation?.resume(with: outcome)
    }
}
