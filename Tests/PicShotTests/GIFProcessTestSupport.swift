import Foundation
import Darwin
@testable import PicShot

/// A real, ad-hoc signed app containing only the executable. The helper hook
/// must run before AppDelegate, model lookup, capture, or any UI initialization.
/// A missing executable is a test failure, never a skipped integration test.
struct GIFProcessTestApplication: Sendable {
    let bundleURL: URL
    let root: URL

    static func make() throws -> GIFProcessTestApplication {
        let files = FileManager.default
        let executable = try builtExecutable()
        // macOS's /var and /tmp aliases must not make an otherwise genuine
        // fixture fail the production verifier's no-symlink path requirement.
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-GIF-Process-Test-" + UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("PicShot.app", isDirectory: true)
        let binaries = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try files.createDirectory(at: binaries, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        do {
            try files.copyItem(at: executable, to: binaries.appendingPathComponent("PicShot"))
            let info: [String: Any] = [
                "CFBundleExecutable": "PicShot", "CFBundleIdentifier": "local.picshot.app",
                "CFBundleName": "PicShot", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.0"
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"), options: .atomic)
            try codesign(["--force", "--sign", "-", "--identifier", "local.picshot.app", bundle.path])
            try codesign(["--verify", "--strict", bundle.path])
            _ = try GIFHelperExecutable.verified(bundleURL: bundle)
            return GIFProcessTestApplication(bundleURL: bundle, root: root)
        } catch {
            try? files.removeItem(at: root)
            throw error
        }
    }

    func service() -> GIFExportProcessService {
        let bundle = bundleURL
        return GIFExportProcessService(configuration: .init(
            executable: { try GIFHelperExecutable.verified(bundleURL: bundle) }, wallSeconds: 30))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func builtExecutable() throws -> URL {
        let files = FileManager.default
        var directory = Bundle(for: GIFProcessTestBundleAnchor.self).bundleURL.resolvingSymlinksInPath()
        // SwiftPM's XCTest bundle lives beside the built executable, possibly
        // beneath Contents/MacOS depending on the test runner's bundle layout.
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("PicShot")
            if directory.pathComponents.contains(".build"), files.isExecutableFile(atPath: candidate.path) {
                let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile == true, values.isSymbolicLink != true { return candidate }
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        throw GIFProcessTestSupportError.failed(
            "Built PicShot executable was not found beside the SwiftPM test bundle; run swift build --product PicShot before these tests")
    }

    /// Arguments go straight to Apple's codesign executable, never to a shell.
    /// Neither a wedged signing process nor a full stderr pipe can hang XCTest.
    private static func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if !process.isRunning { process.waitUntilExit() }
            throw GIFProcessTestSupportError.failed("Fixture codesign exceeded its 20-second deadline")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GIFProcessTestSupportError.failed("Fixture codesign failed with status \(process.terminationStatus)")
        }
    }
}

private final class GIFProcessTestBundleAnchor: NSObject { }

enum GIFProcessTestSupportError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

/// Thread-safe probes keep callbacks independent of the caller's executor.
final class GIFProcessTestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class GIFProcessTestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var cancel: (@Sendable () -> Void)?
    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); cancel = action; let shouldCancel = requested; lock.unlock()
        if shouldCancel { action() }
    }
    func request() {
        lock.lock(); requested = true; let action = cancel; lock.unlock()
        action?()
    }
    func clear() { lock.lock(); cancel = nil; lock.unlock() }
    var wasRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

final class GIFProcessTestCollision: @unchecked Sendable {
    private let lock = NSLock()
    private var didClaim = false
    private var storedFailure: Error?
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !didClaim else { return false }
        didClaim = true
        return true
    }
    func record(_ error: Error) { lock.lock(); storedFailure = error; lock.unlock() }
    var claimed: Bool { lock.lock(); defer { lock.unlock() }; return didClaim }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return storedFailure }
}
