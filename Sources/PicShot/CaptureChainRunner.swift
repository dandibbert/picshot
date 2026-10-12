import AppKit
import PicShotCore

/// Only the already-detached selection crosses the acquisition boundary. In
/// particular, this owner cannot retain CapturedImage's full-desktop presentation.
struct ChainCapture: @unchecked Sendable {
    let image: CGImage
    let capturedAt: Date
    let encodedBackingBytes: Int
    let retainedBytes: Int

    init(image: CGImage, capturedAt: Date = Date(), encodedBackingBytes: Int = 0) throws {
        guard let bytes = CaptureRecoveryPolicy.retainedBytes(
            rasterBytes: EditorRasterEstimate.retainedBytes([image]), encodedBytes: encodedBackingBytes) else {
            throw CaptureRecoveryError.unsupportedBacking
        }
        self.image = image
        self.capturedAt = capturedAt
        self.encodedBackingBytes = encodedBackingBytes
        retainedBytes = bytes
    }
}

enum CaptureChainStatus: Equatable {
    case idle, capturing, running(index: Int), cancelling
    case failed(index: Int, message: String)
    case captureFailed(message: String)
    case completed, cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .captureFailed: return true
        default: return false
        }
    }

    var canRetry: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct CaptureChainReceipt: Equatable {
    enum Value: Equatable {
        case saved(URL, byteCount: Int), copied, pinned(UUID)
    }
    let output: CaptureChainOutput
    let value: Value
}

/// A value-only status surface: terminal windows never own images or callbacks
/// that can target a different run. Receipt count is bounded by three outputs.
struct CaptureChainSnapshot: Equatable {
    let runID: UUID
    let definition: CaptureChainDefinition
    let status: CaptureChainStatus
    let receipts: [CaptureChainReceipt]
    let capturedAt: Date?
    let retainedBytes: Int
}

/// One capture, one ordered ledger, and one retryable unfinished output. All
/// command reservations happen synchronously, before callbacks or suspension.
@MainActor
final class CaptureChainRunner {
    typealias Snapshot = CaptureChainSnapshot
    typealias Status = CaptureChainStatus
    typealias Receipt = CaptureChainReceipt

    struct Dependencies {
        let capture: @MainActor () async throws -> ChainCapture
        let savePNG: @MainActor (CGImage) async -> SaveWorkflowTerminalOutcome
        let copy: @MainActor (CGImage) throws -> Void
        let pin: @MainActor (CGImage) throws -> UUID
        let cancelSave: @MainActor () -> Void
        let cancelCapture: @MainActor () -> Void

        init(capture: @escaping @MainActor () async throws -> ChainCapture,
             savePNG: @escaping @MainActor (CGImage) async -> SaveWorkflowTerminalOutcome,
             copy: @escaping @MainActor (CGImage) throws -> Void,
             pin: @escaping @MainActor (CGImage) throws -> UUID,
             cancelSave: @escaping @MainActor () -> Void,
             cancelCapture: @escaping @MainActor () -> Void = {}) {
            self.capture = capture; self.savePNG = savePNG; self.copy = copy; self.pin = pin
            self.cancelSave = cancelSave; self.cancelCapture = cancelCapture
        }
    }

    let id: UUID
    var runID: UUID { id }
    let definition: CaptureChainDefinition
    private(set) var status: CaptureChainStatus = .idle
    private(set) var receipts: [CaptureChainReceipt] = []
    private(set) var capture: ChainCapture?
    private(set) var capturedAt: Date?
    var retainedBytes: Int { capture?.retainedBytes ?? 0 }
    var blocksCapture: Bool { !status.isTerminal }
    var isAttemptRunning: Bool { task != nil }
    var snapshot: CaptureChainSnapshot {
        CaptureChainSnapshot(runID: id, definition: definition, status: status,
            receipts: receipts, capturedAt: capturedAt, retainedBytes: retainedBytes)
    }
    var onChange: ((CaptureChainSnapshot) -> Void)?
    var onTerminal: ((CaptureChainSnapshot) -> Void)?

    private var dependencies: Dependencies?
    private var task: Task<Void, Never>?
    private var attemptID: UUID?
    private var cancellationRequested = false

    init(definition: CaptureChainDefinition, dependencies: Dependencies, id: UUID = UUID()) {
        self.definition = definition; self.dependencies = dependencies; self.id = id
    }

    @discardableResult func start() -> Bool {
        guard status == .idle, task == nil, dependencies != nil else { return false }
        beginAttempt(status: .capturing)
        return true
    }

    @discardableResult func retry() -> Bool {
        guard case .failed(let index, _) = status, index == receipts.count,
              task == nil, capture != nil, dependencies != nil, !cancellationRequested else { return false }
        beginAttempt(status: .running(index: index))
        return true
    }

    @discardableResult func cancel() -> Bool {
        guard !status.isTerminal, !cancellationRequested else { return false }
        let previousStatus = status
        cancellationRequested = true
        status = .cancelling
        task?.cancel()
        // These hooks only reach the operations owned by this session. Task
        // cancellation also reaches the existing capture service's handler.
        if previousStatus == .capturing { dependencies?.cancelCapture() }
        if case .running(let index) = previousStatus,
           definition.outputs[index] == .quickSavePNG { dependencies?.cancelSave() }
        if task == nil { retire(.cancelled) }
        else { onChange?(snapshot) }
        return true
    }

    private func beginAttempt(status: CaptureChainStatus) {
        let attempt = UUID()
        attemptID = attempt
        self.status = status
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(attempt: attempt)
        }
        onChange?(snapshot)
    }

    private func isCurrent(_ attempt: UUID) -> Bool { attemptID == attempt && task != nil }

    private func run(attempt: UUID) async {
        guard isCurrent(attempt) else { return }
        if cancellationRequested { retire(.cancelled); return }
        if capture == nil {
            let acquired = await acquire(attempt: attempt)
            guard isCurrent(attempt) else { return }
            switch acquired {
            case .succeeded: break
            case .cancelled: retire(.cancelled); return
            case .failed(let message): retire(.captureFailed(message: message)); return
            }
        }
        while receipts.count < definition.outputs.count {
            guard isCurrent(attempt) else { return }
            if cancellationRequested { retire(.cancelled); return }
            let index = receipts.count
            status = .running(index: index)
            onChange?(snapshot)
            guard isCurrent(attempt) else { return }
            if cancellationRequested { retire(.cancelled); return }
            let result = await performOutput(index: index, attempt: attempt)
            guard isCurrent(attempt) else { return }
            // performOutput has already recorded any irreversible success. Its
            // image-bearing locals have drained before retirement drops ownership.
            if cancellationRequested { retire(.cancelled); return }
            switch result {
            case .succeeded: break
            case .cancelled: retire(.cancelled); return
            case .failed(let message):
                task = nil; attemptID = nil
                status = .failed(index: index, message: message)
                // Retry may be invoked here reentrantly. No old-attempt defer
                // may clear the newly reserved task after this callback returns.
                onChange?(snapshot)
                return
            }
        }
        retire(.completed)
    }

    private enum AttemptResult { case succeeded, cancelled, failed(String) }

    private func acquire(attempt: UUID) async -> AttemptResult {
        guard let dependencies else { return .cancelled }
        do {
            let selected = try await dependencies.capture()
            guard isCurrent(attempt), !cancellationRequested else { return .cancelled }
            capture = selected
            capturedAt = selected.capturedAt
            return .succeeded
        } catch is CancellationError {
            return .cancelled
        } catch CaptureError.cancelled {
            // The interactive region selector reports Escape through the
            // capture service's own cancellation case, without cancelling Task.
            return .cancelled
        } catch {
            return cancellationRequested ? .cancelled : .failed(Self.message(error))
        }
    }

    private func performOutput(index: Int, attempt: UUID) async -> AttemptResult {
        guard let image = capture?.image, let dependencies else { return .cancelled }
        let output = definition.outputs[index]
        do {
            let receipt: CaptureChainReceipt.Value
            switch output {
            case .quickSavePNG:
                let outcome = await dependencies.savePNG(image)
                guard isCurrent(attempt) else { return .cancelled }
                switch outcome {
                case .committed(let summary): receipt = .saved(summary.savedURL, byteCount: summary.byteCount)
                case .cancelled: return .cancelled
                case .failed(let failure): return .failed(Self.message(failure))
                }
            case .copy:
                try dependencies.copy(image)
                receipt = .copied
            case .pin:
                receipt = .pinned(try dependencies.pin(image))
            }
            // No checkCancellation, callback, or suspension is allowed between
            // side-effect success and ledger insertion, including reentrant Cancel.
            receipts.append(CaptureChainReceipt(output: output, value: receipt))
            return .succeeded
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(Self.message(error))
        }
    }

    private func retire(_ terminalStatus: CaptureChainStatus) {
        guard !status.isTerminal else { return }
        capture = nil; dependencies = nil; task = nil; attemptID = nil
        status = terminalStatus
        let change = onChange, terminal = onTerminal
        onChange = nil; onTerminal = nil
        let result = snapshot
        change?(result)
        terminal?(result)
    }

    private static func message(_ error: Error) -> String {
        // One current failure replaces the prior one; arbitrary NSError text
        // cannot grow a receipt window or keep an image-bearing Error alive.
        String(decoding: error.localizedDescription.utf8.prefix(4_096), as: UTF8.self)
    }
}
