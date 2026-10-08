import AppKit
import CryptoKit
import Darwin
import PicShotCore

/// Owned objects and byte reservations complement kernel observations. They do
/// not attribute CoreGraphics/WindowServer caches or prove allocator release.
@MainActor final class EditableAnnotationLifetime {
    static let roles = ["original", "base", "current", "canonical", "editor", "canvas", "content", "window", "pin", "store"]
    private final class Probe {
        weak var object: AnyObject?
        let bytes: Int
        init(_ object: AnyObject, bytes: Int) { self.object = object; self.bytes = bytes }
    }
    private var values: [String: [Probe]] = [:]
    private var peaks: [String: Int] = [:]
    private var bytePeaks: [String: Int] = [:]
    func observe(_ object: AnyObject, role: String, bytes: Int = 0) {
        precondition(Self.roles.contains(role))
        if values[role, default: []].contains(where: { $0.object === object }) { return }
        values[role, default: []].append(Probe(object, bytes: bytes))
        peaks[role] = max(peaks[role, default: 0], values[role, default: []].filter { $0.object != nil }.count)
        bytePeaks[role] = max(bytePeaks[role, default: 0], values[role, default: []].filter { $0.object != nil }.reduce(0) { $0 + $1.bytes })
    }
    func image(_ image: CGImage, role: String) { observe(image, role: role, bytes: image.bytesPerRow * image.height) }
    func editor(_ editor: ImageEditorController) {
        observe(editor, role: "editor"); observe(editor.annotationCanvas, role: "canvas")
        if let content = editor.window?.contentView { observe(content, role: "content") }
        if let window = editor.window { observe(window, role: "window") }
    }
    // AppKit may retain a closed NSWindow shell; only its detached graph is an
    // ownership failure. Shell counts stay visible in the report.
    var alive: Int { values.filter { $0.key != "window" }.values.flatMap { $0 }.filter { $0.object != nil }.count }
    var windowContentGraphs: Int {
        values["window", default: []].compactMap { $0.object as? NSWindow }
            .filter { $0.contentView != nil || $0.delegate != nil }.count
    }
    var report: [String: Any] {
        Dictionary(uniqueKeysWithValues: Self.roles.map { role in
            let probes = values[role, default: []]
            return (role, ["created": probes.count, "alive": probes.filter { $0.object != nil }.count,
                "peakConcurrent": peaks[role, default: 0], "peakKnownBytes": bytePeaks[role, default: 0]])
        })
    }
}

enum EditableAnnotationFixtureObservation {
    static func memory() throws -> [String: Any] {
        let value = ImageBackingMemoryReading.current(), counters = EditableAnnotationMemorySampler.flatten(value)
        try require(EditableAnnotationMemorySampler.required.allSatisfy { counters[$0] != nil }, "Missing RSS/backing field")
        return ["uptimeSeconds": ProcessInfo.processInfo.systemUptime, "counters": counters,
            "backingAccounting": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))]
    }
    @MainActor static func digest(_ image: CGImage, lifetime: EditableAnnotationLifetime) throws -> String {
        try autoreleasepool {
            let context = try required(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Canonical allocation failed")
            lifetime.observe(context, role: "canonical", bytes: image.width * image.height * 4)
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let address = try required(context.data, "Canonical bytes missing")
            // A scoped no-copy wrapper: no digest-sized Data or Array survives the hash.
            let data = Data(bytesNoCopy: address, count: image.width * image.height * 4, deallocator: .none)
            return withExtendedLifetime(context) {
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
    }
    static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw failure(message) }; return value
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    static func failure(_ text: String) -> Error { PicShotError.message("Editable annotation acceptance: " + text) }
    struct OwnedFileIdentity: Hashable { let device: Int64; let inode: UInt64 }
    static func ownedFileIdentities(_ root: URL) throws -> Set<OwnedFileIdentity> {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw failure("Cannot inspect owned files") }
        var children: [URL] = []
        for case let url as URL in enumerator {
            children.append(url); try require(children.count <= 512, "Owned fixture file count exceeded bound")
        }
        var identities: Set<OwnedFileIdentity> = []
        for url in [root] + children {
            var status = stat()
            guard url.path.withCString({ lstat($0, &status) }) == 0 else { throw failure("Cannot record owned file identity") }
            identities.insert(OwnedFileIdentity(device: Int64(status.st_dev), inode: UInt64(status.st_ino)))
        }
        return identities
    }
    static func ownedFileDescriptors(_ root: URL, identities: Set<OwnedFileIdentity>) throws -> [Int32] {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { throw failure("Cannot enumerate own file descriptors") }
        let capacity = max(32, Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32)
        guard capacity <= 16_384 else { throw failure("Own file descriptor inventory exceeds bound") }
        let buffer = UnsafeMutablePointer<proc_fdinfo>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let received = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
        guard received > 0, Int(received) < capacity * MemoryLayout<proc_fdinfo>.stride, Int(received) % MemoryLayout<proc_fdinfo>.stride == 0 else { throw failure("Own file descriptor inventory changed beyond bound") }
        var owned: [Int32] = []
        let prefixes = Set([root.path, root.resolvingSymlinksInPath().standardizedFileURL.path])
        for index in 0..<(Int(received) / MemoryLayout<proc_fdinfo>.stride) where buffer[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var status = stat()
            guard fstat(buffer[index].proc_fd, &status) == 0 else {
                if errno == EBADF { continue }; throw failure("Cannot inspect own descriptor identity")
            }
            if identities.contains(OwnedFileIdentity(device: Int64(status.st_dev), inode: UInt64(status.st_ino))) {
                owned.append(buffer[index].proc_fd); continue
            }
            var information = vnode_fdinfowithpath()
            let count = proc_pidfdinfo(getpid(), buffer[index].proc_fd, PROC_PIDFDVNODEPATHINFO, &information, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            // A descriptor can close while enumerating. Do not substitute another
            // process or print unrelated paths. Only this owned directory matters.
            guard count == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else {
                if errno == EBADF || errno == ENOENT { continue }
                throw failure("An own-process vnode descriptor could not be inspected")
            }
            let path = withUnsafePointer(to: &information.pvip.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { owned.append(buffer[index].proc_fd) }
        }
        return owned
    }
}

final class EditableAnnotationMemorySampler: @unchecked Sendable {
    static let interval: TimeInterval = 0.05
    static let required = ["resident_size", "phys_footprint", "purgeable_volatile_resident", "purgeable_volatile_virtual", "purgeable_volatile_pmap", "ledger_purgeable_volatile", "ledger_purgeable_volatile_compressed", "compressed"]
    private let lock = NSLock(), queue = DispatchQueue(label: "PicShot.MultiWindowResource.Memory")
    private var timer: DispatchSourceTimer?
    private var phase = "entry"
    private var total = Stats(), byPhase: [String: Stats] = [:]
    private struct Stats {
        var samples = 0, timerSamples = 0
        var peak: [String: Int64] = [:], minimum: [String: Int64] = [:], last: [String: Int64] = [:], missing: [String: Int] = [:]
        mutating func record(_ values: [String: Int64], timer: Bool) {
            samples += 1; if timer { timerSamples += 1 }; last = values
            for key in EditableAnnotationMemorySampler.required {
                if let value = values[key] { peak[key] = max(peak[key] ?? value, value); minimum[key] = min(minimum[key] ?? value, value) }
                else { missing[key, default: 0] += 1 }
            }
        }
        var report: [String: Any] { ["sampleCount": samples, "timerSampleCount": timerSamples, "sampledPeakBytes": peak, "sampledMinimumBytes": minimum, "lastBytes": last, "missingFieldCounts": missing] }
    }
    init() {
        sample(timer: false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample(timer: true) }; self.timer = timer; timer.resume()
    }
    func setPhase(_ value: String) { lock.lock(); phase = value; lock.unlock(); sample(timer: false) }
    private func sample(timer: Bool) {
        lock.lock(); let label = phase; lock.unlock()
        let values = Self.flatten(ImageBackingMemoryReading.current())
        lock.lock(); defer { lock.unlock() }
        total.record(values, timer: timer)
        let boundedLabel = byPhase[label] != nil || byPhase.count < 127 ? label : "overflow"
        byPhase[boundedLabel, default: Stats()].record(values, timer: timer)
    }
    func stop() { guard let timer else { return }; timer.cancel(); self.timer = nil; queue.sync {}; sample(timer: false) }
    deinit { timer?.cancel() }
    func phases(prefix: String) -> [String: Any] { lock.lock(); defer { lock.unlock() }; return byPhase.filter { $0.key.hasPrefix(prefix) }.mapValues(\.report) }
    var report: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["scope": "50ms self-task samples, not kernel lifetime peaks; phases label observations without proving allocation ownership",
                "sampleIntervalSeconds": Self.interval, "maximumPhaseAggregates": 128, "continuousSampleArraysRetained": false,
                "pairedTaskInfoCallsAreAtomic": false, "missingFieldsBecomeZero": false,
                "total": total.report, "phases": byPhase.mapValues(\.report)]
    }
    static func flatten(_ reading: ImageBackingMemoryReading) -> [String: Int64] {
        var values: [String: Int64] = [:]
        for key in ["resident_size", "phys_footprint", "compressed"] {
            if let value = reading.standard.bytes[key], value <= UInt64(Int64.max) { values[key] = Int64(value) }
        }
        for key in ["purgeable_volatile_resident", "purgeable_volatile_virtual", "purgeable_volatile_pmap"] {
            if let value = reading.purgeable.bytes[key], value <= UInt64(Int64.max) { values[key] = Int64(value) }
        }
        values["ledger_purgeable_volatile"] = reading.purgeable.ledgerBytes["ledger_purgeable_volatile"]
        values["ledger_purgeable_volatile_compressed"] = reading.purgeable.ledgerBytes["ledger_purgeable_volatile_compressed"]
        return values
    }
}
