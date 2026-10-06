import Foundation
import Darwin
import PicShotCodecCore

/// Writes at most 601 quantized progress lines and one terminal line. There is
/// no queued output array, unbounded stderr, source text or arbitrary error text.
final class CodecResponseWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var bytesWritten = 0
    private var terminal = false
    private var lastBucket = -1
    private var lastFraction = -1.0
    private var residentPeak: UInt64?, footprintPeak: UInt64?
    private var residentCount = 0, footprintCount = 0
    init(descriptor: Int32 = STDOUT_FILENO) { self.descriptor = descriptor }
    func progress(_ fraction: Double) throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        guard fraction.isFinite, (0...1).contains(fraction), fraction >= lastFraction else { throw CodecExportFailure(.protocolViolation) }
        lastFraction = fraction
        let bucket = Int(floor(fraction * 600))
        guard bucket > lastBucket else { return }
        try writeLocked(.init(kind: .progress, fraction: fraction)); lastBucket = bucket
    }
    func record(_ reading: CodecMemoryReading) {
        lock.lock(); defer { lock.unlock() }; recordLocked(reading)
    }
    private func recordLocked(_ reading: CodecMemoryReading) {
        if let bytes = reading.residentBytes, bytes > 0 { residentCount += 1; residentPeak = max(residentPeak ?? 0, bytes) }
        if let bytes = reading.physicalFootprintBytes, bytes > 0 { footprintCount += 1; footprintPeak = max(footprintPeak ?? 0, bytes) }
    }
    func finish(_ response: CodecExportResponse) throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }; terminal = true
        recordLocked(.current())
        var response = response
        response.sampledPeakResidentBytes = residentPeak; response.sampledPeakPhysicalFootprintBytes = footprintPeak
        response.residentSampleCount = residentCount > 0 ? residentCount : nil
        response.physicalFootprintSampleCount = footprintCount > 0 ? footprintCount : nil
        try writeLocked(response)
    }
    private func writeLocked(_ response: CodecExportResponse) throws {
        let data = try CodecExportProtocol.encodeResponseLine(response)
        let limit = CodecExportLimits.stdoutBytes - (terminal ? 0 : CodecExportLimits.responseBytes)
        guard data.count <= limit - bytesWritten else { throw CodecExportFailure(.tooLarge) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw CodecExportFailure(.protocolViolation) }
            var offset = 0
            while offset < data.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodecExportFailure(.protocolViolation) }
                let amount = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if amount > 0 { offset += amount; bytesWritten += amount; continue }
                if amount < 0, errno == EINTR { continue }
                guard amount < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw CodecExportFailure(.protocolViolation) }
                var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, 10)
            }
        }
    }
}

struct CodecMemoryReading {
    let residentBytes: UInt64?
    let physicalFootprintBytes: UInt64?
    static func current() -> Self {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        return Self(residentBytes: basicResult == KERN_SUCCESS ? basic.resident_size : nil,
                    physicalFootprintBytes: vmResult == KERN_SUCCESS ? vm.phys_footprint : nil)
    }
}
