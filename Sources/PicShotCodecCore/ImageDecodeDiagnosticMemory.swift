import Foundation
import Darwin

/// Exact self-task fields only. Separate Mach calls are not an atomic pair.
public struct ImageDecodeTaskVMReading: Codable, Sendable {
    public let flavor: String, kernelReturn: Int32
    public let returnedNaturalCount: UInt32, requestedNaturalCount: UInt32
    public let bytes: [String: UInt64], ledgerBytes: [String: Int64]
    public let uptimeSeconds: Double
    static func current(_ flavor: task_flavor_t) -> Self {
        var vm = task_vm_info_data_t()
        let requested = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        var returned = requested
        let result = withUnsafeMutablePointer(to: &vm) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(requested)) { task_info(mach_task_self_, flavor, $0, &returned) } }
        let valid = result == KERN_SUCCESS ? min(Int(requested), Int(returned)) * MemoryLayout<natural_t>.size : 0
        func field<T>(_ key: KeyPath<task_vm_info_data_t, T>) -> T? {
            guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: key), offset + MemoryLayout<T>.size <= valid else { return nil }; return vm[keyPath: key]
        }
        var bytes: [String: UInt64] = [:]
        let fields: [(String, KeyPath<task_vm_info_data_t, UInt64>)] = [("resident_size", \.resident_size), ("phys_footprint", \.phys_footprint),
            ("internal", \.`internal`), ("external", \.external), ("reusable", \.reusable), ("compressed", \.compressed)]
        for (name, key) in fields { bytes[name] = field(key) }
        if flavor == task_flavor_t(TASK_VM_INFO_PURGEABLE) {
            bytes["purgeable_volatile_resident"] = field(\.purgeable_volatile_resident)
            bytes["purgeable_volatile_virtual"] = field(\.purgeable_volatile_virtual)
            bytes["purgeable_volatile_pmap"] = field(\.purgeable_volatile_pmap)
        }
        var ledgers: [String: Int64] = [:]
        ledgers["ledger_purgeable_nonvolatile"] = field(\.ledger_purgeable_nonvolatile)
        ledgers["ledger_purgeable_novolatile_compressed"] = field(\.ledger_purgeable_novolatile_compressed)
        ledgers["ledger_purgeable_volatile"] = field(\.ledger_purgeable_volatile)
        ledgers["ledger_purgeable_volatile_compressed"] = field(\.ledger_purgeable_volatile_compressed)
        return Self(flavor: flavor == task_flavor_t(TASK_VM_INFO_PURGEABLE) ? "TASK_VM_INFO_PURGEABLE" : "TASK_VM_INFO", kernelReturn: result,
                    returnedNaturalCount: returned, requestedNaturalCount: requested, bytes: bytes, ledgerBytes: ledgers, uptimeSeconds: ProcessInfo.processInfo.systemUptime)
    }
}
public struct ImageDecodeMemoryReading: Codable, Sendable {
    public let standard: ImageDecodeTaskVMReading, purgeable: ImageDecodeTaskVMReading
    public var residentBytes: UInt64? { standard.bytes["resident_size"] }
    public var footprintBytes: UInt64? { standard.bytes["phys_footprint"] }
    public var usable: Bool {
        standard.kernelReturn == 0 && purgeable.kernelReturn == 0 && (residentBytes ?? 0) > 0 && (footprintBytes ?? 0) > 0 &&
        purgeable.bytes["purgeable_volatile_resident"] != nil && purgeable.bytes["purgeable_volatile_virtual"] != nil && purgeable.bytes["purgeable_volatile_pmap"] != nil
    }
    public static func current() -> Self { Self(standard: .current(task_flavor_t(TASK_VM_INFO)), purgeable: .current(task_flavor_t(TASK_VM_INFO_PURGEABLE))) }
}
public struct ImageDecodeMemoryPeaks: Codable, Sendable {
    public var residentBytes: UInt64 = 0, footprintBytes: UInt64 = 0
    public var residentSamples = 0, footprintSamples = 0
    public init() { }
    public mutating func record(_ reading: ImageDecodeMemoryReading) {
        if let n = reading.residentBytes { residentSamples += 1; residentBytes = max(residentBytes, n) }
        if let n = reading.footprintBytes { footprintSamples += 1; footprintBytes = max(footprintBytes, n) }
    }
}
public final class ImageDecodeMemorySampler: @unchecked Sendable {
    private let lock = NSLock(), queue = DispatchQueue(label: "PicShot.ImageDecodeDiagnostic.Memory")
    private var timer: DispatchSourceTimer?, peaks = ImageDecodeMemoryPeaks()
    public init() {
        record(.current())
        let t = DispatchSource.makeTimerSource(queue: queue); t.schedule(deadline: .now() + 0.01, repeating: 0.01)
        t.setEventHandler { [weak self] in self?.record(.current()) }; timer = t; t.resume()
    }
    public func record(_ reading: ImageDecodeMemoryReading) { lock.lock(); peaks.record(reading); lock.unlock() }
    public func snapshot() -> ImageDecodeMemoryPeaks { lock.lock(); defer { lock.unlock() }; return peaks }
    public func stop() { guard let t = timer else { return }; t.cancel(); timer = nil; queue.sync { }; record(.current()) }
    deinit { timer?.cancel() }
}
