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
    @MainActor static var diagnostic: EditableAnnotationObservationDiagnostic?
    @MainActor static func beginDiagnostic(includeResources: Bool) throws {
        diagnostic = nil
        let environment = ProcessInfo.processInfo.environment
        guard let selection = environment["PICSHOT_EDITABLE_HASH_DIAGNOSTIC"] else { return }
        try require(environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1" && environment["PICSHOT_SMOKE_TEST"] == "1",
                    "Hash diagnostics require the owned editable smoke entry point")
        let mode = try required(EditableAnnotationObservationDiagnostic.Mode(rawValue: selection), "Unknown editable hash diagnostic")
        try require(mode != .certify || !includeResources, "Byte certification is a separate functional-only process")
        diagnostic = EditableAnnotationObservationDiagnostic(mode: mode)
    }
    @MainActor static func digest(_ image: CGImage, lifetime: EditableAnnotationLifetime, label: String = "unlabeled") throws -> String {
        if let diagnostic { return try diagnostic.digest(image, lifetime: lifetime, label: label) }
        return try referenceDigest(image, lifetime: lifetime)
    }
    @MainActor static func referencePixels<Result>(_ image: CGImage, lifetime: EditableAnnotationLifetime,
        _ consume: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        try autoreleasepool {
            let context = try required(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Canonical allocation failed")
            lifetime.observe(context, role: "canonical", bytes: image.width * image.height * 4)
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let address = try required(context.data, "Canonical bytes missing")
            return try withExtendedLifetime(context) {
                try consume(UnsafeRawBufferPointer(start: address, count: image.width * image.height * 4))
            }
        }
    }
    @MainActor static func referenceDigest(_ image: CGImage, lifetime: EditableAnnotationLifetime) throws -> String {
        try referencePixels(image, lifetime: lifetime, hash)
    }
    static func hash(_ pixels: UnsafeRawBufferPointer) -> String {
        // The original scoped no-copy SHA256 input, shared by both diagnostic arms.
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pixels.baseAddress!), count: pixels.count, deallocator: .none)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

/// An opt-in observation experiment, never a product renderer or memory remedy.
/// Each vImage workspace lives for precisely one hash and is released on return.
/// The certification process deliberately does twice the conversion/hash work;
/// its memory observations must not be used as either comparison arm.
@MainActor final class EditableAnnotationObservationDiagnostic {
    typealias O = EditableAnnotationFixtureObservation
    enum Mode: String { case reference = "cgcontext", candidate = "vimage", certify = "certify" }
    let mode: Mode
    private var workload = "entry"
    private var hashes: [[String: Any]] = [], checkpoints: [[String: Any]] = []
    private var normalizedBytes = 0, snapshotCount = 0
    private let began = ProcessInfo.processInfo.systemUptime
    init(mode: Mode) { self.mode = mode }

    private func counters() throws -> [String: Any] {
        let values = EditableAnnotationMemorySampler.flatten(ImageBackingMemoryReading.current())
        try O.require(EditableAnnotationMemorySampler.required.allSatisfy { values[$0] != nil }, "Missing diagnostic task-info field")
        return ["uptimeSeconds": ProcessInfo.processInfo.systemUptime, "counters": values]
    }
    func beginWorkload(_ label: String) throws {
        workload = label
        try checkpoint("workload-entry")
    }
    func checkpoint(_ label: String) throws {
        try O.require(checkpoints.count < 256, "Diagnostic checkpoint bound exceeded")
        checkpoints.append(["workload": workload, "label": label, "observation": try counters()])
        if label.hasPrefix("snapshot-before-") { snapshotCount += 1 }
    }
    func digest(_ image: CGImage, lifetime: EditableAnnotationLifetime, label: String) throws -> String {
        try O.require(hashes.count < 256 && label != "unlabeled", "Diagnostic hash bound or label invalid")
        let bytes = image.width * image.height * 4
        let colorSpace = image.colorSpace
        var input: [String: Any] = ["width": image.width, "height": image.height,
            "bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel,
            "bytesPerRow": image.bytesPerRow, "alphaInfo": image.alphaInfo.rawValue,
            "bitmapInfo": image.bitmapInfo.rawValue, "colorSpaceName": NSNull(),
            "colorSpaceModel": NSNull(), "colorSpaceICC_SHA256": NSNull(),
            "renderingIntent": image.renderingIntent.rawValue, "shouldInterpolate": image.shouldInterpolate]
        if let colorSpace {
            input["colorSpaceModel"] = colorSpace.model.rawValue
            if let name = colorSpace.name { input["colorSpaceName"] = name as String }
            if let profile = colorSpace.copyICCData() {
                input["colorSpaceICC_SHA256"] = SHA256.hash(data: profile as Data).map { String(format: "%02x", $0) }.joined()
            }
        }
        var item: [String: Any] = ["index": hashes.count + 1, "workload": workload, "label": label,
            "input": input,
            "normalizedBytes": bytes, "conversionCount": mode == .certify ? 2 : 1,
            "knownSimultaneousDestinationBytes": mode == .certify ? bytes * 2 : bytes,
            "before": try counters(), "status": "running"]
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            item["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
            // Missing counters remain missing and fail the offline checker; never zero-fill.
            item["after"] = try? counters()
            hashes.append(item)
        }
        let result: String
        switch mode {
        case .reference:
            result = try O.referenceDigest(image, lifetime: lifetime)
        case .candidate:
            result = try autoreleasepool {
                let workspace = ManualScrollVImageObservation()
                return try workspace.withNormalizedPixels(image) { pixels in
                    lifetime.observe(workspace, role: "canonical", bytes: workspace.allocatedByteCount)
                    return O.hash(pixels)
                }
            }
        case .certify:
            result = try O.referencePixels(image, lifetime: lifetime) { reference in
                let workspace = ManualScrollVImageObservation()
                return try workspace.withNormalizedPixels(image) { candidate in
                    let referenceHash = O.hash(reference), candidateHash = O.hash(candidate)
                    let equal = reference.count == candidate.count && memcmp(reference.baseAddress!, candidate.baseAddress!, reference.count) == 0
                    item["referenceSHA256"] = referenceHash; item["candidateSHA256"] = candidateHash
                    item["comparedBytes"] = reference.count; item["everyRGBAByteEqual"] = equal
                    try O.require(equal && referenceHash == candidateHash, "Exact RGBA equivalence failed at " + workload + "/" + label)
                    return referenceHash
                }
            }
        }
        normalizedBytes += bytes * (mode == .certify ? 2 : 1)
        item["sha256"] = result; item["status"] = "passed"
        return result
    }
    func write(native: [String: Any], nativeData: Data, directory: URL) throws {
        guard native["status"] as? String != "running" else { return }
        let report: [String: Any] = ["schemaVersion": 1, "status": native["status"] ?? "unknown", "mode": mode.rawValue,
            "sourceCommit": native["sourceCommit"] ?? "unknown", "executableSHA256": native["executableSHA256"] ?? "unknown",
            "architecture": native["architecture"] ?? "unknown", "processIdentifier": native["processIdentifier"] ?? 0,
            "nativeReportSHA256": SHA256.hash(data: nativeData).map { String(format: "%02x", $0) }.joined(),
            "resourcesRequested": native["resourcesRequested"] ?? false,
            "normalizedFormat": "sRGB / premultipliedLast / byteOrder32Big / tightly packed RGBA8, all bytes including alpha",
            "hashCount": hashes.count, "conversionCount": hashes.count * (mode == .certify ? 2 : 1),
            "totalNormalizedBytes": normalizedBytes, "snapshotCount": snapshotCount,
            "maximumHashes": 256, "maximumCheckpoints": 256, "hashes": hashes, "checkpoints": checkpoints,
            "elapsedSecondsBeforeSidecarWrite": ProcessInfo.processInfo.systemUptime - began,
            "certificationOnly": mode == .certify, "memoryStabilityAssessed": false, "productMemoryRemedyClaim": false,
            "scope": "Per-call synchronous hashes and task-info boundary readings are diagnostic overhead. All original functional inputs, native operations, snapshots and product lifetimes remain present. vImage allocates a fresh destination per hash; no normalization buffers survive a call. Certification additionally holds one candidate destination beside the reference and compares every RGBA byte; that extra workspace is explicitly counted here, not in the ordinary canonical weak-object inventory. Private framework backing remains in process counters. Counter pairs are not atomic, boundaries are not lifetime peaks; whole-process 50ms samples remain in the native report. Snapshot bracketing includes view capture, composition, hashing and PNG encoding; each after boundary is immediately before helper return and does not certify snapshot object release. Trace metadata is retained through endpoints and bounded by 256 hashes/checkpoints; its allocation and counter polling are part of both diagnostic arms. The sidecar is serialized once after the native final endpoint (or on failure); that file-write overhead is outside the native memory/time endpoints. No memory-pressure/purge request."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try O.require(data.count <= 2 * 1_024 * 1_024, "Diagnostic sidecar exceeds byte bound")
        try data.write(to: directory.appendingPathComponent("editable-annotation-observation.json"), options: .atomic)
    }
}
