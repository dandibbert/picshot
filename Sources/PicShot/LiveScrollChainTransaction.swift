import AppKit
import PicShotCore

/// Bounded in-memory checkpoint. Copies share this exact CGImage object; neither
/// runtime receipts nor the frozen pixels are written into the saved catalog.
struct LiveScrollChainTransaction {
    let sessionID: UUID
    let generation: UInt64
    let revisionID: UUID
    let transactionID: UUID
    let capture: ChainCapture
    let definition: CaptureChainDefinition
    private(set) var receipts: [CaptureChainReceipt]

    init(sessionID: UUID, generation: UInt64, revisionID: UUID = UUID(),
         transactionID: UUID = UUID(), capture: ChainCapture,
         definition: CaptureChainDefinition, receipts: [CaptureChainReceipt] = []) throws {
        try CaptureChainRunner.validateReceiptPrefix(receipts, definition: definition)
        self.sessionID = sessionID; self.generation = generation; self.revisionID = revisionID
        self.transactionID = transactionID; self.capture = capture; self.definition = definition
        self.receipts = receipts
    }

    var isComplete: Bool { receipts.count == definition.outputs.count }

    mutating func accept(_ snapshot: CaptureChainSnapshot, runID: UUID) throws {
        guard snapshot.runID == runID, snapshot.definition == definition,
              snapshot.isExistingScrollImage, snapshot.status.isTerminal,
              snapshot.receipts.starts(with: receipts) else { throw CaptureChainError.invalidOutputs }
        try CaptureChainRunner.validateReceiptPrefix(snapshot.receipts, definition: definition)
        receipts = snapshot.receipts
    }

    var committedDescription: String {
        guard !receipts.isEmpty else { return "尚未完成任何输出" }
        return receipts.map { receipt in
            switch receipt.value {
            case .saved(let url, _): return "PNG 已保存：" + url.path
            case .copied: return "已复制到剪贴板（当时的成功写入）"
            case .pinned(let id): return "贴图已保存：" + id.uuidString
            }
        }.joined(separator: "\n")
    }
}

/// AppMain owns the sole active runner. The scroll owner keeps the checkpoint
/// across terminal attempts, and calls run with a fresh UUID on every Continue.
@MainActor
struct LiveScrollChainDependencies {
    let definitions: () throws -> [CaptureChainDefinition]
    let run: (LiveScrollChainTransaction, UUID) async throws -> CaptureChainSnapshot
    let cancel: (UUID) -> Void
    let preflight: (CaptureChainDefinition, Int, Int, Int) throws -> Void

    init(definitions: @escaping () throws -> [CaptureChainDefinition],
         run: @escaping (LiveScrollChainTransaction, UUID) async throws -> CaptureChainSnapshot,
         cancel: @escaping (UUID) -> Void,
         preflight: @escaping (CaptureChainDefinition, Int, Int, Int) throws -> Void = { _, _, _, _ in }) {
        self.definitions = definitions; self.run = run; self.cancel = cancel; self.preflight = preflight
    }
}
