import Darwin
import Foundation

/// Diagnostic-only, self-task observations. These are kernel accounting fields,
/// not ownership evidence for a particular CGImage or a leak verdict.
///
/// Field layout and flavor behavior were checked against Apple's exported header
/// and implementation (2026-10-06):
/// https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/task_info.h
/// https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c
/// The installed SDK supplies the actual struct layout; returned-count checks
/// prevent unavailable fields from becoming misleading zero observations.
struct ImageBackingMemoryReading: Encodable, Sendable {
    let standard: ImageBackingTaskVMReading
    let purgeable: ImageBackingTaskVMReading

    var residentBytes: UInt64? { standard.bytes["resident_size"] }
    var physicalFootprintBytes: UInt64? { standard.bytes["phys_footprint"] }

    static func current() -> Self {
        Self(standard: .current(flavor: task_flavor_t(TASK_VM_INFO)),
             purgeable: .current(flavor: task_flavor_t(TASK_VM_INFO_PURGEABLE)))
    }
}

struct ImageBackingTaskVMReading: Encodable, Sendable {
    let flavor: String
    let kernelReturn: kern_return_t
    let requestedNaturalCount: mach_msg_type_number_t
    let returnedNaturalCount: mach_msg_type_number_t
    let observedAtUptimeSeconds: Double
    let pageSizeBytes: Int32?
    let regionCount: Int32?
    /// Unsigned mach_vm_size_t fields in bytes, using the SDK's exact names.
    let bytes: [String: UInt64]
    /// Signed ledger fields in bytes; a negative value is preserved verbatim.
    let ledgerBytes: [String: Int64]

    static let scope = "Two separate self-task calls, TASK_VM_INFO then TASK_VM_INFO_PURGEABLE; not atomic across flavors. Standard flavor does not query volatile resident/virtual/pmap fields, so those keys are omitted there. Purgeable flavor asks the kernel to query them; its internal query status is not separately exposed. Missing/failed/short fields are omitted, never converted to zero. Zero is a returned accounting value, not proof of release. No task_for_pid, security changes, memory pressure, purge request, or external process inspection."

    static func current(flavor: task_flavor_t) -> Self {
        var vm = task_vm_info_data_t()
        let requested = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        var returned = requested
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(requested)) {
                task_info(mach_task_self_, flavor, $0, &returned)
            }
        }
        return decode(vm, flavor: flavor, result: result, requestedCount: requested, returnedCount: returned)
    }

    /// Internal for deterministic layout/short-result tests, not fabricated run
    /// observations. Live reports call current(flavor:) exclusively.
    static func decode(_ vm: task_vm_info_data_t, flavor: task_flavor_t, result: kern_return_t,
                       requestedCount: mach_msg_type_number_t, returnedCount: mach_msg_type_number_t) -> Self {
        let validBytes = result == KERN_SUCCESS
            ? min(Int(returnedCount), Int(requestedCount)) * MemoryLayout<natural_t>.size : 0
        func field<T>(_ path: KeyPath<task_vm_info_data_t, T>) -> T? {
            guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: path),
                  offset + MemoryLayout<T>.size <= validBytes else { return nil }
            return vm[keyPath: path]
        }
        var bytes: [String: UInt64] = [:]
        let unsignedFields: [(String, KeyPath<task_vm_info_data_t, UInt64>)] = [
            ("virtual_size", \.virtual_size), ("resident_size", \.resident_size),
            ("resident_size_peak", \.resident_size_peak), ("device", \.device),
            ("device_peak", \.device_peak), ("internal", \.`internal`),
            ("internal_peak", \.internal_peak), ("external", \.external),
            ("external_peak", \.external_peak), ("reusable", \.reusable),
            ("reusable_peak", \.reusable_peak), ("compressed", \.compressed),
            ("compressed_peak", \.compressed_peak), ("compressed_lifetime", \.compressed_lifetime),
            ("phys_footprint", \.phys_footprint)
        ]
        for (name, path) in unsignedFields { bytes[name] = field(path) }
        // TASK_VM_INFO fills these fields with zero without querying them.
        // Including those zeros would incorrectly present absent observations.
        if flavor == task_flavor_t(TASK_VM_INFO_PURGEABLE) {
            bytes["purgeable_volatile_pmap"] = field(\.purgeable_volatile_pmap)
            bytes["purgeable_volatile_resident"] = field(\.purgeable_volatile_resident)
            bytes["purgeable_volatile_virtual"] = field(\.purgeable_volatile_virtual)
        }
        var ledgers: [String: Int64] = [:]
        let signedFields: [(String, KeyPath<task_vm_info_data_t, Int64>)] = [
            ("ledger_phys_footprint_peak", \.ledger_phys_footprint_peak),
            ("ledger_purgeable_nonvolatile", \.ledger_purgeable_nonvolatile),
            // "novolatile" is the spelling in Apple's ABI, not a typo here.
            ("ledger_purgeable_novolatile_compressed", \.ledger_purgeable_novolatile_compressed),
            ("ledger_purgeable_volatile", \.ledger_purgeable_volatile),
            ("ledger_purgeable_volatile_compressed", \.ledger_purgeable_volatile_compressed),
            ("ledger_tag_media_footprint", \.ledger_tag_media_footprint),
            ("ledger_tag_media_footprint_compressed", \.ledger_tag_media_footprint_compressed),
            ("ledger_tag_media_nofootprint", \.ledger_tag_media_nofootprint),
            ("ledger_tag_media_nofootprint_compressed", \.ledger_tag_media_nofootprint_compressed),
            ("ledger_tag_graphics_footprint", \.ledger_tag_graphics_footprint),
            ("ledger_tag_graphics_footprint_compressed", \.ledger_tag_graphics_footprint_compressed),
            ("ledger_tag_graphics_nofootprint", \.ledger_tag_graphics_nofootprint),
            ("ledger_tag_graphics_nofootprint_compressed", \.ledger_tag_graphics_nofootprint_compressed)
        ]
        for (name, path) in signedFields { ledgers[name] = field(path) }
        return Self(flavor: flavor == task_flavor_t(TASK_VM_INFO_PURGEABLE) ? "TASK_VM_INFO_PURGEABLE" : "TASK_VM_INFO",
                    kernelReturn: result, requestedNaturalCount: requestedCount, returnedNaturalCount: returnedCount,
                    observedAtUptimeSeconds: ProcessInfo.processInfo.systemUptime,
                    pageSizeBytes: field(\.page_size), regionCount: field(\.region_count), bytes: bytes, ledgerBytes: ledgers)
    }
}
