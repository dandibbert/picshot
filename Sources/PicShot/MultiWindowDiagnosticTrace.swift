import Darwin
import Foundation

// Isolated diagnostic control. Production callers leave the optional observer nil.
enum MultiWindowDiagnosticEvent: String, Sendable {
    case canvasBeforeAllocation, canvasAfterAllocation
    case decodeBefore, decodeImageCreated, decodeReturned
    case inputBeforeAppend, inputAfterAppendScope
    case appendBeforeDraws, drawBefore, drawAfter, appendAfterFlush
    case normalizationBefore, normalizationAfter, candidateBlendBefore, candidateBlendAfter
    case finishBefore, finishAfterOwnershipTransfer, outputAfterFinishScope
    case digestBefore, digestAfter, cycleAfterRelease, cancellationAfterRelease
}
typealias MultiWindowDiagnosticObserver = @Sendable (MultiWindowDiagnosticEvent, UInt32, Int) -> Void

/// Fixed-capacity scalar/raw-struct storage, allocated and touched before the
/// fixture-entry boundary. No per-event dictionary, array, JSON or file write.
/// Pairs remain non-atomic self-task observations, never allocation ownership.
final class MultiWindowDiagnosticTrace: @unchecked Sendable {
    private static let capacity = 2_048
    private struct Snapshot {
        var vm = task_vm_info_data_t()
        var requested: mach_msg_type_number_t = 0
        var returned: mach_msg_type_number_t = 0
        var result: kern_return_t = KERN_FAILURE
        var uptime: Double = 0
        static func current(_ flavor: task_flavor_t) -> Self {
            var vm = task_vm_info_data_t()
            let requested = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            var returned = requested
            let result = withUnsafeMutablePointer(to: &vm) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(requested)) {
                    task_info(mach_task_self_, flavor, $0, &returned)
                }
            }
            return Self(vm: vm, requested: requested, returned: returned, result: result,
                uptime: ProcessInfo.processInfo.systemUptime)
        }
        func report(_ flavor: task_flavor_t) -> [String: Any] {
            let decoded = ImageBackingTaskVMReading.decode(vm, flavor: flavor, result: result,
                requestedCount: requested, returnedCount: returned)
            var report: [String: Any] = ["flavor": decoded.flavor, "kernelReturn": result,
                "requestedNaturalCount": requested, "returnedNaturalCount": returned,
                "observedAtUptimeSeconds": uptime, "bytes": decoded.bytes, "ledgerBytes": decoded.ledgerBytes]
            let requiredBytes = flavor == task_flavor_t(TASK_VM_INFO_PURGEABLE)
                ? ["purgeable_volatile_resident", "purgeable_volatile_virtual"]
                : ["resident_size", "phys_footprint", "compressed"]
            var missing = requiredBytes.filter { decoded.bytes[$0] == nil }
            if flavor == task_flavor_t(TASK_VM_INFO_PURGEABLE),
               decoded.ledgerBytes["ledger_purgeable_volatile_compressed"] == nil {
                missing.append("ledger_purgeable_volatile_compressed")
            }
            report["missingRequiredFields"] = missing
            report["requiredCountersAvailable"] = result == KERN_SUCCESS && missing.isEmpty
            if let pageSize = decoded.pageSizeBytes { report["pageSizeBytes"] = pageSize }
            if let regions = decoded.regionCount { report["regionCount"] = regions }
            return report
        }
    }
    private struct Record {
        var phase: Int = 0, cycle: Int = 0
        var event: MultiWindowDiagnosticEvent = .canvasBeforeAllocation
        var window: UInt32 = 0
        var stripTop: Int = -1
        var standard = Snapshot(), purgeable = Snapshot()
    }
    private let lock = NSLock()
    private let records: UnsafeMutablePointer<Record>
    private var count = 0, overflow = 0, phase = 0, cycle = 0
    var allocatedBytes: Int { Self.capacity * MemoryLayout<Record>.stride }
    init() {
        records = .allocate(capacity: Self.capacity)
        records.initialize(repeating: Record(), count: Self.capacity)
    }
    deinit { records.deinitialize(count: Self.capacity); records.deallocate() }
    // 1 = warmup, 2 = measured, 3 = cancellation. No strings stored per event.
    func begin(phase: Int, cycle: Int) {
        lock.lock(); defer { lock.unlock() }
        self.phase = phase; self.cycle = cycle
    }
    func record(_ event: MultiWindowDiagnosticEvent, window: UInt32 = 0, stripTop: Int = -1) {
        lock.lock(); defer { lock.unlock() }
        guard count < Self.capacity else { overflow += 1; return }
        records[count] = Record(phase: phase, cycle: cycle, event: event, window: window, stripTop: stripTop,
            standard: .current(task_flavor_t(TASK_VM_INFO)), purgeable: .current(task_flavor_t(TASK_VM_INFO_PURGEABLE)))
        count += 1
    }
    // Call only after final cleanup counters and the transient sampler stop.
    var report: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let observations: [[String: Any]] = (0..<count).map { index in
            let row = records[index]
            return ["phase": row.phase, "cycle": row.cycle, "event": row.event.rawValue,
                "windowID": row.window, "stripTop": row.stripTop,
                "standard": row.standard.report(task_flavor_t(TASK_VM_INFO)),
                "purgeable": row.purgeable.report(task_flavor_t(TASK_VM_INFO_PURGEABLE))]
        }
        return ["scope": "Synchronous action boundaries; raw paired task_info reads are non-atomic and do not establish backing ownership. Fixed trace storage is touched before fixture entry; JSON conversion occurs after final cleanup observations.",
            "capacity": Self.capacity, "allocatedBytes": allocatedBytes, "recordCount": count,
            "overflowCount": overflow, "observations": observations]
    }
}
