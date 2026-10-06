import Foundation

/// One process-wide native export child (GIF, WebP, or AVIF). A cancelled
/// operation keeps its lease until child exit and private staging cleanup have
/// both been confirmed. Model helpers intentionally have a separate admission.
final class NativeExportAdmission: @unchecked Sendable {
    static let shared = NativeExportAdmission()
    private let lock = NSLock()
    private var owner: UUID?
    private var recover: (@Sendable () -> Bool)?

    func acquire() -> UUID? {
        lock.lock(); let old = owner, recovery = recover; lock.unlock()
        if let old, let recovery, recovery() { release(old) }
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return nil }
        let token = UUID(); owner = token; recover = nil; return token
    }
    func release(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard owner == token else { return }; owner = nil; recover = nil
    }
    func retainUntilRecovered(_ token: UUID, _ recovery: @escaping @Sendable () -> Bool) {
        lock.lock(); defer { lock.unlock() }
        guard owner == token else { return }; recover = recovery
    }
}
