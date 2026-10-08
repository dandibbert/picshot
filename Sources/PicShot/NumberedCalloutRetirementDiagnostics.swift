#if PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS
import Foundation
import ObjectiveC
import Darwin

@MainActor
private var numberedCalloutRetirementAssociationKey: UInt8 = 0

/// Diagnostic only. This is association teardown plus a weak-nil observation,
/// not an exact last-release or heap-free timestamp. It never decides a gate.
struct NumberedCalloutRetirementEvent: Codable {
    let tokenDeinitUptime: Double
    let weakCheckFinishedUptime: Double
    let sourceWasWeakNil: Bool
    let callbackWasOnMainThread: Bool
}

/// Object -> associated token -> stamp; probe -> stamp. Neither the stamp nor
/// the token owns the object. One event per tracked object, no tasks or timers.
final class NumberedCalloutRetirementStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var event: NumberedCalloutRetirementEvent?

    @MainActor
    static func attach(to source: AnyObject) -> NumberedCalloutRetirementStamp {
        // Reuse the stamp if a framework object is shared across fixture cycles;
        // never replace a live token and turn replacement into a release event.
        if let token = objc_getAssociatedObject(source, &numberedCalloutRetirementAssociationKey)
            as? NumberedCalloutRetirementToken { return token.stamp }
        let stamp = NumberedCalloutRetirementStamp()
        objc_setAssociatedObject(source, &numberedCalloutRetirementAssociationKey,
            NumberedCalloutRetirementToken(source: source, stamp: stamp), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return stamp
    }

    fileprivate func record(_ value: NumberedCalloutRetirementEvent) {
        lock.lock(); defer { lock.unlock() }
        if event == nil { event = value }
    }

    func snapshot() -> NumberedCalloutRetirementEvent? {
        lock.lock(); defer { lock.unlock() }
        return event
    }
}

private final class NumberedCalloutRetirementToken: NSObject {
    private weak var source: AnyObject?
    fileprivate let stamp: NumberedCalloutRetirementStamp

    init(source: AnyObject, stamp: NumberedCalloutRetirementStamp) {
        self.source = source; self.stamp = stamp
        super.init()
    }

    deinit {
        let began = ProcessInfo.processInfo.systemUptime
        // A client can remove associations while an object is still live. Such
        // a callback must never be presented as evidence of object retirement.
        let wasNil = source == nil
        let checked = ProcessInfo.processInfo.systemUptime
        // Capture on the deallocating thread BEFORE taking our lock. Posting to
        // MainActor would introduce the very observer delay being investigated.
        stamp.record(NumberedCalloutRetirementEvent(tokenDeinitUptime: began,
            weakCheckFinishedUptime: checked, sourceWasWeakNil: wasNil,
            callbackWasOnMainThread: Thread.isMainThread))
    }
}

struct NumberedCalloutRetirementDiagnosticCycle: Codable {
    let cycle: Int
    let closedAtUptime: Double
    let contextWasTracked: Bool
    let input: NumberedCalloutRetirementEvent?
    let context: NumberedCalloutRetirementEvent?
}

struct NumberedCalloutRetirementDiagnosticReport: Codable {
    let schema = "callout-associated-token-diagnostic-v1"
    let acceptanceStatus: String
    let snapshotStartedAtUptime: Double
    let snapshotFinishedAtUptime: Double
    let monitorBeganAtUptime: Double
    let cycles: [NumberedCalloutRetirementDiagnosticCycle]
    let observedLifecycle: NumberedCalloutLifecycleEvidence
    let limitations = [
        "Diagnostic only: existing scheduled 10 ms ownership gate, 2000 ms observation deadline, six-cycle and 256-sample limits are unchanged",
        "Token callbacks record association teardown and a synchronous weak read, not exact last release, allocator free, CPU scheduling, run-loop cause, process memory or leak freedom",
        "Only sourceWasWeakNil=true makes weakCheckFinishedUptime a retirement upper bound; a late or missing callback alone cannot prove late last release",
        "Association instrumentation changes runtime work; results describe this instrumented execution only; original failed evidence remains failed"
    ]
}
/// Creates one new private sidecar. Existing entries (including dangling links)
/// are never replaced. All filesystem work happens after the original gate.
enum NumberedCalloutDiagnosticDestination {
    private static func invalid(_ reason: String) -> Error {
        NSError(domain: "PicShot.CalloutDiagnosticDestination", code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason])
    }

    private static func posixFailure() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else { throw posixFailure() }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    static func write(_ data: Data, absolutePath path: String, excluding roots: [URL]) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), !roots.isEmpty,
              let separator = path.lastIndex(of: "/"), separator != path.index(before: path.endIndex) else {
            throw invalid("Sidecar requires an absolute file path and protected evidence roots")
        }
        let name = String(path[path.index(after: separator)...])
        guard name != ".", name != ".." else { throw invalid("Sidecar destination must name a new file") }
        let parent = String(path[..<separator])
        let canonicalParent = try canonicalPath(parent.isEmpty ? "/" : parent)
        let destination = (canonicalParent as NSString).appendingPathComponent(name)
        let lexicalDestination = URL(fileURLWithPath: path).standardizedFileURL.path
        var protectedIdentities: [stat] = []
        for root in roots {
            let resolved = try canonicalPath(root.path)
            guard !isWithin(destination, root: resolved),
                  !isWithin(lexicalDestination, root: root.standardizedFileURL.path) else {
                throw invalid("Sidecar must be outside the accepted evidence subtree")
            }
            // Use the opened directory's identity; Darwin.stat can resolve to
            // the struct initializer in Swift. Each loop iteration owns one FD.
            let protectedDirectory = resolved.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard protectedDirectory >= 0 else { throw posixFailure() }
            defer { Darwin.close(protectedDirectory) }
            var identity = stat()
            guard Darwin.fstat(protectedDirectory, &identity) == 0 else { throw posixFailure() }
            protectedIdentities.append(identity)
        }
        // lstat deliberately rejects existing dangling symlinks too. O_EXCL
        // below also prevents replacement if a file appears after this check.
        var existing = stat()
        if path.withCString({ Darwin.lstat($0, &existing) }) == 0 {
            throw invalid("Sidecar destination already exists; choose a fresh filename")
        }
        guard errno == ENOENT else { throw posixFailure() }

        // Resolve first, then walk the canonical parent through directory FDs
        // without following replacement symlinks. Inode checks cover aliases on
        // case-insensitive filesystems as well as textual path comparisons.
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw posixFailure() }
        defer { Darwin.close(directory) }
        for component in ["."] + canonicalParent.split(separator: "/").map(String.init) {
            let next = component.withCString {
                Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw posixFailure() }
            Darwin.close(directory); directory = next
            var identity = stat()
            guard Darwin.fstat(directory, &identity) == 0 else { throw posixFailure() }
            guard !protectedIdentities.contains(where: { $0.st_dev == identity.st_dev && $0.st_ino == identity.st_ino }) else {
                throw invalid("Sidecar parent aliases the accepted evidence subtree")
            }
        }
        let descriptor = name.withCString {
            Darwin.openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixFailure() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            // Preserve a partial diagnostic rather than risk deleting a path
            // that another actor replaced; the error is reported by the caller.
            throw error
        }
    }
}

#endif
