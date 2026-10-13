import AppKit
import PicShotCore
import PicShotTextScriptCore

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
    case preparingText(ChainTextPhase), textFailed(ChainTextPhase, ChainTextFailure)
    case waitingForTextCleanup(ChainTextFailure)
    case completed, cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .captureFailed: return true
        default: return false
        }
    }

    var canRetry: Bool {
        if case .failed = self { return true }
        if case .textFailed = self { return true }
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
    let isTextScript: Bool
    let isExistingScrollImage: Bool
    let textReceipt: ChainTextCopyReceipt?
    let retainedTextBytes: Int

    // Default arguments preserve every existing image snapshot call site.
    init(runID: UUID, definition: CaptureChainDefinition, status: CaptureChainStatus,
         receipts: [CaptureChainReceipt], capturedAt: Date?, retainedBytes: Int,
         isTextScript: Bool = false, textReceipt: ChainTextCopyReceipt? = nil, retainedTextBytes: Int = 0,
         isExistingScrollImage: Bool = false) {
        self.runID = runID; self.definition = definition; self.status = status
        self.receipts = receipts; self.capturedAt = capturedAt; self.retainedBytes = retainedBytes
        self.isTextScript = isTextScript; self.textReceipt = textReceipt; self.retainedTextBytes = retainedTextBytes
        self.isExistingScrollImage = isExistingScrollImage
    }
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

    struct TextDependencies {
        let capture: @MainActor () async throws -> ChainCapture
        let recognize: @MainActor (CGImage) async throws -> ChainTextRecognition
        let transform: @MainActor (String, String, UUID) async -> ChainTextTransformResult
        let copy: @MainActor (String) throws -> Void
        let cleanupComplete: @MainActor (UUID) -> Bool
        let cancelCapture: @MainActor () -> Void

        init(capture: @escaping @MainActor () async throws -> ChainCapture,
             recognize: @escaping @MainActor (CGImage) async throws -> ChainTextRecognition,
             transform: @escaping @MainActor (String, String, UUID) async -> ChainTextTransformResult,
             copy: @escaping @MainActor (String) throws -> Void,
             cleanupComplete: @escaping @MainActor (UUID) -> Bool,
             cancelCapture: @escaping @MainActor () -> Void = {}) {
            self.capture = capture; self.recognize = recognize; self.transform = transform
            self.copy = copy; self.cleanupComplete = cleanupComplete; self.cancelCapture = cancelCapture
        }
    }

    let id: UUID
    var runID: UUID { id }
    let definition: CaptureChainDefinition
    private(set) var status: CaptureChainStatus = .idle
    private(set) var receipts: [CaptureChainReceipt] = []
    private(set) var capture: ChainCapture?
    private(set) var capturedAt: Date?
    let isTextScript: Bool
    private(set) var isExistingScrollImage = false
    private(set) var textReceipt: ChainTextCopyReceipt?
    // Byte counts describe retained payloads, not total process RSS or Swift's
    // allocator overhead. Images and each text phase are accounted separately.
    var retainedTextBytes: Int {
        (frozenSource?.utf8.count ?? 0) + (recognizedText?.utf8.count ?? 0) + (transformedText?.utf8.count ?? 0)
    }
    var retainedBytes: Int { (capture?.retainedBytes ?? 0) + retainedTextBytes }
    var blocksCapture: Bool { !status.isTerminal }
    var isAttemptRunning: Bool { task != nil || cleanupTask != nil }
    var snapshot: CaptureChainSnapshot {
        CaptureChainSnapshot(runID: id, definition: definition, status: status,
            receipts: receipts, capturedAt: capturedAt, retainedBytes: retainedBytes,
            isTextScript: isTextScript, textReceipt: textReceipt, retainedTextBytes: retainedTextBytes,
            isExistingScrollImage: isExistingScrollImage)
    }
    var onChange: ((CaptureChainSnapshot) -> Void)?
    var onTerminal: ((CaptureChainSnapshot) -> Void)?

    private var dependencies: Dependencies?
    private var textDependencies: TextDependencies?
    private var frozenSource: String?
    private var recognizedText: String?
    private var transformedText: String?
    private var pendingCleanupID: UUID?
    private var cleanupFailure: ChainTextFailure?
    private var cleanupTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var attemptID: UUID?
    private var cancellationRequested = false

    init(definition: CaptureChainDefinition, dependencies: Dependencies, id: UUID = UUID()) {
        self.definition = definition; self.dependencies = dependencies; self.id = id
        self.isTextScript = false
    }

    /// This route owns an existing immutable raster. Saved source metadata is
    /// deliberately not resolved and dependencies.capture is never called.
    convenience init(definition: CaptureChainDefinition, preparedCapture: ChainCapture,
                     receipts: [CaptureChainReceipt] = [], dependencies: Dependencies,
                     id: UUID = UUID()) throws {
        try Self.validateReceiptPrefix(receipts, definition: definition)
        self.init(definition: definition, dependencies: dependencies, id: id)
        capture = preparedCapture; capturedAt = preparedCapture.capturedAt
        self.receipts = receipts; isExistingScrollImage = true
    }

    nonisolated static func validateReceiptPrefix(_ receipts: [CaptureChainReceipt], definition: CaptureChainDefinition) throws {
        guard receipts.count <= definition.outputs.count,
              receipts.count <= CaptureChainDefinition.maximumOutputs else { throw CaptureChainError.invalidOutputs }
        for (index, receipt) in receipts.enumerated() {
            guard receipt.output == definition.outputs[index] else { throw CaptureChainError.invalidOutputs }
            switch (receipt.output, receipt.value) {
            case (.quickSavePNG, .saved(_, let count)) where count >= 0: break
            case (.copy, .copied), (.pin, .pinned): break
            default: throw CaptureChainError.invalidOutputs
            }
        }
    }

    /// The public metadata retains only the same region/copy shape; executable
    /// source is frozen privately and is dropped when the run drains.
    init(textScript: TextScriptDefinition, dependencies: TextDependencies, id: UUID = UUID()) throws {
        definition = try CaptureChainDefinition(id: textScript.id, name: textScript.name, source: .region, outputs: [.copy])
        self.textDependencies = dependencies; self.id = id; self.isTextScript = true
        frozenSource = textScript.source
    }

    /// Recognize an existing immutable raster through the same text pipeline;
    /// this route never resolves a source or acquires another screenshot.
    convenience init(textScript: TextScriptDefinition, preparedCapture: ChainCapture,
                     dependencies: TextDependencies, id: UUID = UUID()) throws {
        try self.init(textScript: textScript, dependencies: dependencies, id: id)
        capture = preparedCapture; capturedAt = preparedCapture.capturedAt
        isExistingScrollImage = true
    }

    @discardableResult func start() -> Bool {
        guard status == .idle, task == nil, dependencies != nil || textDependencies != nil else { return false }
        if isExistingScrollImage {
            guard capture != nil else { return false }
            if isTextScript { beginAttempt(status: .preparingText(.recognize)) }
            else if receipts.count == definition.outputs.count { retire(.completed) }
            else { beginAttempt(status: .running(index: receipts.count)) }
        } else { beginAttempt(status: .capturing) }
        return true
    }

    @discardableResult func retry() -> Bool {
        if isTextScript {
            guard case .textFailed(let phase, _) = status, task == nil, cleanupTask == nil,
                  pendingCleanupID == nil, textDependencies != nil, !cancellationRequested else { return false }
            switch phase {
            case .recognize: guard capture != nil else { return false }
            case .transform: guard recognizedText != nil, frozenSource != nil else { return false }
            case .copy: guard transformedText != nil, textReceipt == nil else { return false }
            }
            beginAttempt(status: .preparingText(phase))
            return true
        }
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
        if isTextScript {
            if previousStatus == .capturing { textDependencies?.cancelCapture() }
            clearTextBuffers()
            // The cleanup observer is intentionally not cancelled: admission
            // remains closed until the helper's owned exit and EOFs are real.
            if task == nil && pendingCleanupID == nil { retire(.cancelled) }
            else { onChange?(snapshot) }
            return true
        }
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
            if self.isTextScript { await self.runText(attempt: attempt) }
            else { await self.run(attempt: attempt) }
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

    private enum TextAttemptResult { case succeeded, cancelled, failed(ChainTextFailure) }

    private func runText(attempt: UUID) async {
        guard isCurrent(attempt) else { return }
        if cancellationRequested { retire(.cancelled); return }
        if capture == nil && recognizedText == nil && transformedText == nil {
            let result = await acquireText(attempt: attempt)
            guard isCurrent(attempt) else { return }
            if cancellationRequested { retire(.cancelled); return }
            switch result {
            case .succeeded: break
            case .cancelled: retire(.cancelled); return
            case .failed(let failure): retire(.captureFailed(message: failure.message)); return
            }
        }
        if recognizedText == nil && transformedText == nil {
            guard publishTextPhase(.recognize, attempt: attempt) else { return }
            let result = await recognizeText(attempt: attempt)
            guard isCurrent(attempt) else { return }
            if cancellationRequested { retire(.cancelled); return }
            switch result {
            case .succeeded: break
            case .cancelled: retire(.cancelled); return
            case .failed(let failure): failText(.recognize, failure: failure); return
            }
        }
        if transformedText == nil {
            guard publishTextPhase(.transform, attempt: attempt) else { return }
            let requestID = UUID()
            let result = await transformText(requestID: requestID)
            guard isCurrent(attempt) else { return }
            // Observe cleanup ownership before consulting cancellation. The
            // helper may have returned an unconfirmed exit after Cancel.
            switch result {
            case .failed(let failure, cleanupPending: true):
                waitForOwnedTextCleanup(requestID: requestID, failure: failure); return
            case .cancelled(cleanupPending: true):
                cancellationRequested = true; clearTextBuffers()
                waitForOwnedTextCleanup(requestID: requestID, failure: .runtime(.cancelled)); return
            default: break
            }
            if cancellationRequested { retire(.cancelled); return }
            switch result {
            case .succeeded(let output):
                do { try CheckedTextClipboard.validate(output) }
                catch let failure as ChainTextFailure { failText(.transform, failure: failure); return }
                catch { failText(.transform, failure: .invalidResult); return }
                transformedText = output
                recognizedText = nil; frozenSource = nil
            case .failed(let failure, _): failText(.transform, failure: failure); return
            case .cancelled: retire(.cancelled); return
            }
        }
        guard publishTextPhase(.copy, attempt: attempt) else { return }
        let result = copyText()
        guard isCurrent(attempt) else { return }
        if cancellationRequested { retire(.cancelled); return }
        switch result {
        case .succeeded: retire(.completed)
        case .cancelled: retire(.cancelled)
        case .failed(let failure): failText(.copy, failure: failure)
        }
    }

    private func publishTextPhase(_ phase: ChainTextPhase, attempt: UUID) -> Bool {
        guard isCurrent(attempt) else { return false }
        if cancellationRequested { retire(.cancelled); return false }
        status = .preparingText(phase)
        onChange?(snapshot)
        guard isCurrent(attempt) else { return false }
        if cancellationRequested { retire(.cancelled); return false }
        return true
    }

    private func acquireText(attempt: UUID) async -> TextAttemptResult {
        guard let dependencies = textDependencies else { return .cancelled }
        do {
            let selected = try await dependencies.capture()
            guard isCurrent(attempt), !cancellationRequested else { return .cancelled }
            capture = selected; capturedAt = selected.capturedAt
            return .succeeded
        } catch is CancellationError { return .cancelled }
        catch CaptureError.cancelled { return .cancelled }
        catch { return .failed(.captureFailed) }
    }

    private func recognizeText(attempt: UUID) async -> TextAttemptResult {
        guard let image = capture?.image, let dependencies = textDependencies else { return .cancelled }
        do {
            let result = try await dependencies.recognize(image)
            guard isCurrent(attempt), !cancellationRequested else { return .cancelled }
            guard !result.truncated else { return .failed(.truncatedRecognition) }
            guard !result.text.isEmpty else { return .failed(.emptyRecognition) }
            guard result.text.utf16.count <= TextScriptLimits.inputUTF16Units else { return .failed(.oversizedRecognition) }
            recognizedText = result.text
            capture = nil
            return .succeeded
        } catch is CancellationError { return .cancelled }
        catch { return .failed(.recognitionFailed) }
    }

    private func transformText(requestID: UUID) async -> ChainTextTransformResult {
        guard let source = frozenSource, let text = recognizedText, let dependencies = textDependencies else {
            return .cancelled(cleanupPending: false)
        }
        return await dependencies.transform(source, text, requestID)
    }

    private func copyText() -> TextAttemptResult {
        guard textReceipt == nil, let text = transformedText, let dependencies = textDependencies else { return .cancelled }
        do {
            try CheckedTextClipboard.validate(text)
            let count = text.count
            try dependencies.copy(text)
            // Synchronous commit ledger: no cancellation check, callback or
            // suspension between acknowledgement and recording this receipt.
            textReceipt = ChainTextCopyReceipt(characterCount: count)
            return .succeeded
        } catch is CancellationError { return .cancelled }
        catch { return .failed(.clipboardRejected) }
    }

    private func failText(_ phase: ChainTextPhase, failure: ChainTextFailure) {
        task = nil; attemptID = nil
        status = .textFailed(phase, failure)
        onChange?(snapshot)
    }

    private func waitForOwnedTextCleanup(requestID: UUID, failure: ChainTextFailure) {
        task = nil; attemptID = nil
        pendingCleanupID = requestID; cleanupFailure = failure
        status = cancellationRequested ? .cancelling : .waitingForTextCleanup(failure)
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.pendingCleanupID == requestID else { return }
                if self.checkTextCleanup() { return }
            }
        }
        onChange?(snapshot)
    }

    /// The timer and deterministic tests share this same identity-gated check.
    /// A released lease permits retry or cancellation only, never late success.
    @discardableResult func checkTextCleanup() -> Bool {
        guard let requestID = pendingCleanupID, let dependencies = textDependencies,
              dependencies.cleanupComplete(requestID) else { return false }
        // A dependency can reenter Cancel; the owned identity still decides
        // what drains, and the now-current cancellation flag decides retirement.
        guard pendingCleanupID == requestID else { return false }
        let failure = cleanupFailure ?? .invalidResult
        pendingCleanupID = nil; cleanupFailure = nil
        cleanupTask?.cancel(); cleanupTask = nil
        if cancellationRequested { retire(.cancelled) }
        else { failText(.transform, failure: failure) }
        return true
    }

    private func clearTextBuffers() {
        frozenSource = nil; recognizedText = nil; transformedText = nil
        if isTextScript { capture = nil }
    }

    private func retire(_ terminalStatus: CaptureChainStatus) {
        guard !status.isTerminal else { return }
        capture = nil; dependencies = nil; textDependencies = nil; task = nil; attemptID = nil
        clearTextBuffers()
        pendingCleanupID = nil; cleanupFailure = nil
        cleanupTask?.cancel(); cleanupTask = nil
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
